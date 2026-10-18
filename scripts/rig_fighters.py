#!/usr/bin/env python3
"""Build deterministic, vertex-colored skeletal assets from the supplied Y-up OBJs.

No Blender/runtime dependency. Each vertex has two nonzero bone influences in four Metal lanes.
Joint coordinates are fractions of each sculpt's height, calibrated to its T-pose.
"""
import argparse
import json
import math
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NAMES = ('mack', 'bruiser', 'goldie', 'nico', 'atlas', 'duke', 'sylvie', 'cassian', 'vera', 'jaison')
# name, parent, global bind position (normalized to source height)
BONES = [('hips', -1, (0, .50, 0)), ('spine', 0, (0, .64, 0)),
         ('neck', 1, (0, .805, 0)), ('head', 2, (0, .85, 0))]
for side, sign in [('left', -1), ('right', 1)]:
    BONES.extend([(side+'Shoulder', 1, (sign*.135, .78, 0)),
                  (side+'Elbow', len(BONES), (sign*.265, .78, 0)),
                  (side+'Hand', len(BONES)+1, (sign*.38, .78, 0))])
for side, sign in [('left', -1), ('right', 1)]:
    start = len(BONES)
    BONES.extend([(side+'Hip', 0, (sign*.065, .49, 0)),
                  (side+'Knee', start, (sign*.075, .28, 0)),
                  (side+'Foot', start+1, (sign*.085, .10, .015))])


def smooth(a, b, x):
    t = max(0., min(1., (x-a)/(b-a)))
    return t*t*(3-2*t)


def influences(p):
    x, y, z = p
    # Arms are separated from the jaw/neck by both lateral and height gates.
    if abs(x) > .13 and y > .69:
        base = 4 if x < 0 else 7
        if abs(x) < .20:
            return (1, base), smooth(.13, .175, abs(x))
        if abs(x) < .32:
            return (base, base+1), smooth(.235, .295, abs(x))
        return (base+1, base+2), smooth(.355, .395, abs(x))
    # Entire jaw belongs to the head; only the lower neck blends to the spine.
    if y >= .84:
        return (3, 3), 0.
    if y >= .805:
        return (2, 3), smooth(.805, .84, y)
    if y >= .76:
        return (1, 2), smooth(.76, .805, y)
    if y >= .52:
        return (0, 1), smooth(.52, .66, y)
    base = 10 if x < 0 else 13
    if y > .42:
        return (base, 0), smooth(.42, .52, y)
    if y > .19:
        return (base+1, base), smooth(.235, .325, y)
    return (base+2, base+1), smooth(.10, .19, y)


def build(name, output):
    positions, colors, triangles = [], [], []
    for line in (ROOT/'ArtDirection'/'Models'/f'{name}.obj').read_text().splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] == 'v':
            positions.append(tuple(map(float, parts[1:4])))
            colors.append(tuple(map(float, parts[4:7])))
        elif parts[0] == 'f':
            face = [int(t.split('/')[0])-1 for t in parts[1:]]
            for i in range(1, len(face)-1):
                triangles.extend((face[0], face[i], face[i+1]))
    height = max(p[1] for p in positions)
    positions = [tuple(v/height for v in p) for p in positions]
    normals = [[0., 0., 0.] for _ in positions]
    for i in range(0, len(triangles), 3):
        a, b, c = (positions[j] for j in triangles[i:i+3])
        u, v = [b[j]-a[j] for j in range(3)], [c[j]-a[j] for j in range(3)]
        n = (u[1]*v[2]-u[2]*v[1], u[2]*v[0]-u[0]*v[2], u[0]*v[1]-u[1]*v[0])
        for j in triangles[i:i+3]:
            for k in range(3):
                normals[j][k] += n[k]
    # Fixed little-endian layout: magic/counts, 16 bones, 60-byte vertices, indices.
    data = bytearray(struct.pack('<4sIII', b'HMR1', len(positions), len(triangles), len(BONES)))
    for _, parent, p in BONES:
        data.extend(struct.pack('<i3f', parent, *(v*2.7 for v in p)))
    for p, n, color in zip(positions, normals, colors):
        length = math.sqrt(sum(v*v for v in n)) or 1
        ids, blend = influences(p)
        data.extend(struct.pack('<13f4H', *(v*2.7 for v in p), *(v/length for v in n),
                                *color, 1-blend, blend, 0., 0., *ids, 0, 0))
    data.extend(struct.pack(f'<{len(triangles)}I', *triangles))
    output.mkdir(parents=True, exist_ok=True)
    (output/f'{name}.fighter').write_bytes(data)
    return dict(name=name, vertices=len(positions), triangles=len(triangles)//3, bones=len(BONES))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT/'Haymaker'/'Models')
    args = parser.parse_args()
    for name in NAMES:
        print(json.dumps(build(name, args.output)))
