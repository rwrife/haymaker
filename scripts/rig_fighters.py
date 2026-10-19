#!/usr/bin/env python3
"""Pack the rigged boxers: OBJ sculpt + HMS1 skin sidecar -> HMR2 `.fighter` (deterministic, stdlib only).

Joint fitting and skin weighting happen offline in Blender (scripts/blender/autorig.py), which writes
ArtDirection/Rigs/<name>.skin. This packer needs no Blender or numpy, so CI rebuilds every committed
`.fighter` byte-for-byte from the committed OBJ + sidecar. See ArtDirection/Rigs/README.md.

HMR2 (little endian): header "HMR2", u32 vertexCount, u32 indexCount, u32 boneCount (22);
22 x {i32 parent, f32 head[3], f32 aim[3]}; vertexCount x {f32 pos[3], f32 normal[3], f32 rgb[3],
f32 weight[4], u16 bone[4]} (60 bytes); indexCount x u32 triangle indices. Units are OBJ / sculpt height x 2.7.
"""
import argparse
import json
import math
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODELS = ROOT / 'ArtDirection' / 'Models'
RIGS = ROOT / 'ArtDirection' / 'Rigs'
NAMES = ('mack', 'bruiser', 'goldie', 'nico', 'atlas', 'duke', 'sylvie', 'cassian', 'vera', 'jaison', 'hunter')
# Fixed Mixamo bone order shared with the runtime and the clip library ("Left" = anatomical left = +X).
BONES = ('Hips', 'Spine', 'Spine1', 'Spine2', 'Neck', 'Head',
         'LeftShoulder', 'LeftArm', 'LeftForeArm', 'LeftHand',
         'RightShoulder', 'RightArm', 'RightForeArm', 'RightHand',
         'LeftUpLeg', 'LeftLeg', 'LeftFoot', 'LeftToeBase',
         'RightUpLeg', 'RightLeg', 'RightFoot', 'RightToeBase')
PARENTS = (-1, 0, 1, 2, 3, 4, 3, 6, 7, 8, 3, 10, 11, 12, 0, 14, 15, 16, 0, 18, 19, 20)
SCALE = 2.7
SKIN_MAGIC = b'HMS1'
WEIGHT_ONE = 65535


def read_obj(path):
    """Positions, colours (OBJ vertex order) and fan-triangulated indices."""
    positions, colors, triangles = [], [], []
    for line in Path(path).read_text().splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] == 'v':
            positions.append(tuple(map(float, parts[1:4])))
            colors.append(tuple(map(float, parts[4:7])))
        elif parts[0] == 'f':
            face = [int(t.split('/')[0]) - 1 for t in parts[1:]]
            for i in range(1, len(face) - 1):
                triangles.extend((face[0], face[i], face[i + 1]))
    return positions, colors, triangles


def read_skin(path):
    """HMS1 sidecar -> (heads, aims, bone id rows, u16 weight rows); joints in OBJ units."""
    data = Path(path).read_bytes()
    if len(data) < 16:
        raise ValueError(f'{path}: truncated skin sidecar')
    magic, count, bone_count, _ = struct.unpack_from('<4sIII', data)
    if magic != SKIN_MAGIC or bone_count != len(BONES):
        raise ValueError(f'{path}: expected {SKIN_MAGIC!r} with {len(BONES)} bones, got {magic!r}/{bone_count}')
    start = 16 + bone_count * 24
    if len(data) != start + count * 12:
        raise ValueError(f'{path}: size {len(data)} does not match {count} vertices')
    joints = [struct.unpack_from('<6f', data, 16 + i * 24) for i in range(bone_count)]
    ids, weights = [], []
    for i in range(count):
        row = struct.unpack_from('<4B4H', data, start + i * 12)
        ids.append(row[:4])
        weights.append(row[4:])
    return [j[:3] for j in joints], [j[3:] for j in joints], ids, weights


def pack(name, models=MODELS, rigs=RIGS):
    """HMR2 bytes for one model (pure function of the OBJ and its skin sidecar)."""
    positions, colors, triangles = read_obj(Path(models) / f'{name}.obj')
    heads, aims, ids, weights = read_skin(Path(rigs) / f'{name}.skin')
    if len(ids) != len(positions):
        raise ValueError(f'{name}: skin sidecar has {len(ids)} vertices but {name}.obj has {len(positions)}; '
                         're-run scripts/blender/autorig.py for this model')
    height = max(p[1] for p in positions)
    positions = [tuple(v / height for v in p) for p in positions]
    normals = [[0., 0., 0.] for _ in positions]
    for i in range(0, len(triangles), 3):
        a, b, c = (positions[j] for j in triangles[i:i + 3])
        u, v = [b[j] - a[j] for j in range(3)], [c[j] - a[j] for j in range(3)]
        n = (u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0])
        for j in triangles[i:i + 3]:
            for k in range(3):
                normals[j][k] += n[k]
    data = bytearray(struct.pack('<4sIII', b'HMR2', len(positions), len(triangles), len(BONES)))
    for parent, head, aim in zip(PARENTS, heads, aims):
        data.extend(struct.pack('<i6f', parent, *(v / height * SCALE for v in head), *(v / height * SCALE for v in aim)))
    for i, (p, n, color) in enumerate(zip(positions, normals, colors)):
        length = math.sqrt(sum(v * v for v in n)) or 1
        lanes, w = ids[i], weights[i]
        if sum(w) != WEIGHT_ONE or any(b >= len(BONES) for b in lanes):
            raise ValueError(f'{name}: invalid skin row {i}: bones {lanes} weights {w}')
        data.extend(struct.pack('<13f4H', *(v * SCALE for v in p), *(v / length for v in n), *color,
                                *(x / WEIGHT_ONE for x in w), *lanes))
    data.extend(struct.pack(f'<{len(triangles)}I', *triangles))
    return bytes(data)


def build(name, output, models=MODELS, rigs=RIGS):
    data = pack(name, models, rigs)
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    (output / f'{name}.fighter').write_bytes(data)
    vertices, indices, bones = struct.unpack_from('<III', data, 4)
    return dict(name=name, vertices=vertices, triangles=indices // 3, bones=bones)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('names', nargs='*', help='models to pack (default: all)')
    parser.add_argument('--output', type=Path, default=ROOT / 'Haymaker' / 'Models')
    parser.add_argument('--rigs', type=Path, default=RIGS, help='directory holding the <name>.skin sidecars')
    args = parser.parse_args()
    for name in args.names or NAMES:
        if name not in NAMES:
            parser.error(f'unknown model {name!r}')
        print(json.dumps(build(name, args.output, rigs=args.rigs)))
