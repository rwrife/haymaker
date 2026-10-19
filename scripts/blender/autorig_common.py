"""Shared constants and numpy helpers for the Blender auto-rig (no bpy imports here)."""
import json
import struct
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
MODELS = ROOT / 'ArtDirection' / 'Models'
RIGS = ROOT / 'ArtDirection' / 'Rigs'
NAMES = ('mack', 'bruiser', 'goldie', 'nico', 'atlas', 'duke', 'sylvie', 'cassian', 'vera', 'jaison', 'hunter')

# Fixed 22-bone Mixamo order shared with the runtime and the clip library (see ArtDirection/Rigs/README.md).
BONES = ('Hips', 'Spine', 'Spine1', 'Spine2', 'Neck', 'Head',
         'LeftShoulder', 'LeftArm', 'LeftForeArm', 'LeftHand',
         'RightShoulder', 'RightArm', 'RightForeArm', 'RightHand',
         'LeftUpLeg', 'LeftLeg', 'LeftFoot', 'LeftToeBase',
         'RightUpLeg', 'RightLeg', 'RightFoot', 'RightToeBase')
PARENTS = (-1, 0, 1, 2, 3, 4, 3, 6, 7, 8, 3, 10, 11, 12, 0, 14, 15, 16, 0, 18, 19, 20)
B = {n: i for i, n in enumerate(BONES)}
# Canonical child used as the aim point of every non-leaf bone.
AIM_CHILD = {'Hips': 'Spine', 'Spine': 'Spine1', 'Spine1': 'Spine2', 'Spine2': 'Neck', 'Neck': 'Head'}
for _s in ('Left', 'Right'):
    AIM_CHILD.update({_s + 'Shoulder': _s + 'Arm', _s + 'Arm': _s + 'ForeArm', _s + 'ForeArm': _s + 'Hand',
                      _s + 'UpLeg': _s + 'Leg', _s + 'Leg': _s + 'Foot', _s + 'Foot': _s + 'ToeBase'})

SKIN_MAGIC = b'HMS1'


def load_obj(name):
    """Vertices (OBJ order), colours and polygons exactly as rig_fighters.py reads them."""
    positions, colors, faces = [], [], []
    for line in (MODELS / f'{name}.obj').read_text().splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] == 'v':
            positions.append(tuple(map(float, parts[1:4])))
            colors.append(tuple(map(float, parts[4:7])))
        elif parts[0] == 'f':
            faces.append([int(t.split('/')[0]) - 1 for t in parts[1:]])
    return np.array(positions), np.array(colors), faces


def triangulate(faces):
    return np.array([(f[0], f[i], f[i + 1]) for f in faces for i in range(1, len(f) - 1)], dtype=np.int64)


def surface_samples(V, C, T, count=400000, seed=7):
    """Area-uniform surface samples with interpolated colours (deterministic)."""
    a, b, c = V[T[:, 0]], V[T[:, 1]], V[T[:, 2]]
    area = 0.5 * np.linalg.norm(np.cross(b - a, c - a), axis=1)
    rng = np.random.default_rng(seed)
    idx = rng.choice(len(T), count, p=area / area.sum())
    u, v = rng.random(count), rng.random(count)
    flip = u + v > 1
    u[flip], v[flip] = 1 - u[flip], 1 - v[flip]
    w = 1 - u - v
    P = a[idx] * w[:, None] + b[idx] * u[:, None] + c[idx] * v[:, None]
    Q = C[T[idx, 0]] * w[:, None] + C[T[idx, 1]] * u[:, None] + C[T[idx, 2]] * v[:, None]
    return P, Q


def reference_skeleton():
    doc = json.loads((RIGS / 'mixamo-reference-skeleton.json').read_text())
    bones = doc['bones']
    assert [b['name'] for b in bones] == list(BONES)
    assert [b['parent'] for b in bones] == list(PARENTS)
    heads = np.array([b['head'] for b in bones], dtype=float)
    tails = np.array([b['tail'] for b in bones], dtype=float)
    ends = {b['name']: np.array(b['end'], dtype=float) for b in bones if b['end'] is not None}
    return heads, tails, ends


def write_skin(path, heads, aims, bone_ids, weights_u16):
    """HMS1 sidecar: header, 22 x (head, aim) in OBJ units, then per-vertex u8 bone[4] + u16 weight[4]."""
    count = len(bone_ids)
    data = bytearray(struct.pack('<4sIII', SKIN_MAGIC, count, len(BONES), 0))
    for h, a in zip(heads, aims):
        data.extend(struct.pack('<6f', *map(float, h), *map(float, a)))
    rows = np.zeros(count, dtype=[('b', 'u1', 4), ('w', '<u2', 4)])
    rows['b'] = bone_ids
    rows['w'] = weights_u16
    data.extend(rows.tobytes())
    Path(path).write_bytes(bytes(data))


def read_skin(path):
    data = Path(path).read_bytes()
    magic, count, nb, _ = struct.unpack_from('<4sIII', data)
    assert magic == SKIN_MAGIC and nb == len(BONES)
    joints = np.frombuffer(data, '<f4', nb * 6, 16).reshape(nb, 6).astype(float)
    rows = np.frombuffer(data, dtype=[('b', 'u1', 4), ('w', '<u2', 4)], count=count, offset=16 + nb * 24)
    return joints[:, :3], joints[:, 3:], rows['b'].astype(int), rows['w'].astype(int)


def quantize(ids, weights):
    """Top-4 influences -> (u8 ids, u16 weights summing exactly to 65535, descending, unused lanes 0/0)."""
    n = len(ids)
    out_w = np.zeros((n, 4), dtype=np.int64)
    out_b = np.zeros((n, 4), dtype=np.int64)
    for i in range(n):
        pairs = sorted(((w, b) for b, w in zip(ids[i], weights[i]) if w > 0), key=lambda p: (-p[0], p[1]))[:4]
        total = sum(w for w, _ in pairs)
        q = [int(round(w / total * 65535)) for w, _ in pairs]
        q[0] += 65535 - sum(q)
        order = sorted(range(len(pairs)), key=lambda k: (-q[k], pairs[k][1]))
        for lane, k in enumerate(order):
            if q[k] > 0:
                out_w[i, lane] = q[k]
                out_b[i, lane] = pairs[k][1]
    return out_b, out_w
