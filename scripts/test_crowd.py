"""Contract checks for the Tripo3D crowd (issue #42): Haymaker/Models/*.crowd and crowd-*.jpg.

Stdlib only (CI runs it with the system python3):  python3 scripts/test_crowd.py
Format: ArtDirection/Crowd/README.md. Rebuild with scripts/build_crowd.py (needs Pillow).
"""
import json
import math
import struct
import unittest
from pathlib import Path

import build_crowd as bc

ROOT = Path(__file__).resolve().parent.parent
SPEC = json.loads((ROOT / 'ArtDirection' / 'Crowd' / 'crowd.json').read_text())
CLIPS = ['sit', 'sit_clap', 'sit_yell', 'cheer']
SWIFT = (ROOT / 'Haymaker' / 'CrowdModel.swift').read_text()


def load(name):
    d = (ROOT / 'Haymaker' / 'Models' / f'{name}.crowd').read_bytes()
    magic, vc, ic, nb, nc, height, seat = struct.unpack_from('<4sIIIIff', d, 0)
    o = 28
    bones = []
    for _ in range(nb):
        parent, *trs = struct.unpack_from('<i3f4f', d, o)
        ibm = struct.unpack_from('<16f', d, o + 32)
        bones.append((parent, trs[:3], trs[3:], ibm))
        o += 96
    verts = [struct.unpack_from('<3f3f2f4f4H', d, o + i * 56) for i in range(vc)]
    o += vc * 56
    idx = struct.unpack_from(f'<{ic}H', d, o)
    o += ic * 2
    o += -o % 4
    clips = {}
    for _ in range(nc):
        cname, fps, frames = struct.unpack_from('<16sfI', d, o)
        o += 24
        rot = [struct.unpack_from('<4f', d, o + i * 16) for i in range(frames * nb)]
        o += frames * nb * 16
        hips = [struct.unpack_from('<3f', d, o + i * 12) for i in range(frames)]
        o += frames * 12
        clips[cname.rstrip(b'\0').decode()] = (fps, frames, rot, hips)
    return dict(magic=magic, size=len(d), end=o, height=height, seat=seat, bones=bones, verts=verts, idx=idx, clips=clips)


def column_major(m):
    return [[m[c * 4 + r] for c in range(4)] for r in range(4)]


def skin(a, clip, frame):
    """CPU-skin one frame exactly as SceneKit will (bone world x inverse bind)."""
    _, _, rot, hips = a['clips'][clip]
    nb = len(a['bones'])
    world = []
    for b, (parent, t, _, _) in enumerate(a['bones']):
        local = bc.trs(hips[frame] if b == bc.HIPS else t, rot[frame * nb + b])
        world.append(bc.mmul(world[parent], local) if parent >= 0 else local)
    mats = [bc.mmul(world[b], column_major(a['bones'][b][3])) for b in range(nb)]
    out = []
    for v in a['verts']:
        p = [0.0, 0.0, 0.0]
        for w, j in zip(v[8:12], v[12:16]):
            if w:
                q = bc.mpoint(mats[j], v[:3])
                p = [x + w * y for x, y in zip(p, q)]
        out.append(p)
    return out, world


class CrowdAssets(unittest.TestCase):
    def test_spec_matches_runtime(self):
        self.assertEqual(len(SPEC['looks']), 10, 'issue #42 asks for ~10 characters')
        self.assertEqual(sorted(SPEC['bodies']), sorted(set(SPEC['looks'].values())))
        for body in SPEC['bodies']:
            looks = [k for k, v in SPEC['looks'].items() if v == body]
            # CrowdBody.looks in Swift lists the same looks, in spec order.
            listed = '[' + ', '.join(f'"{look}"' for look in looks) + ']'
            self.assertTrue(listed in SWIFT, f'CrowdBody.looks must list {listed} for {body}')
            self.assertTrue(f'"{body}"' in SWIFT, body)
        for clip in CLIPS:
            self.assertTrue(clip in SWIFT, clip)

    def test_textures_are_small_jpegs(self):
        for look in SPEC['looks']:
            data = (ROOT / 'Haymaker' / 'Models' / f'crowd-{look}.jpg').read_bytes()
            self.assertEqual(data[:2], b'\xff\xd8', look)
            self.assertLess(len(data), 80_000, look)
            o = 2   # find the SOF0/SOF2 frame size
            while data[o] == 0xFF and data[o + 1] not in (0xC0, 0xC2):
                o += 2 + struct.unpack_from('>H', data, o + 2)[0]
            h, w = struct.unpack_from('>HH', data, o + 5)
            self.assertEqual((w, h), (bc.TEXTURE_SIZE, bc.TEXTURE_SIZE), look)

    def test_bodies(self):
        for body in SPEC['bodies']:
            with self.subTest(body=body):
                a = load(body)
                self.assertEqual(a['magic'], b'CRW1')
                self.assertEqual(a['end'], a['size'], 'trailing bytes')
                tris = len(a['idx']) // 3
                self.assertLessEqual(tris, 5_200, 'issue #42 budget is ~5,000 triangles')
                self.assertGreater(tris, 3_000)
                self.assertEqual([b[0] for b in a['bones']], bc.PARENT)
                self.assertTrue(all(i < len(a['verts']) for i in a['idx']))
                for v in a['verts']:
                    self.assertAlmostEqual(sum(v[8:12]), 1, delta=0.01)
                    self.assertTrue(all(j < len(a['bones']) for j in v[12:16]))
                    self.assertTrue(0 <= v[6] <= 1 and 0 <= v[7] <= 1, 'uv')
                ys = [v[1] for v in a['verts']]
                self.assertAlmostEqual(min(ys), 0, delta=1e-4)
                self.assertAlmostEqual(max(ys), a['height'], delta=1e-4)
                self.assertTrue(0.15 < a['seat'] < 0.35, a['seat'])
                self.assertEqual(sorted(a['clips']), sorted(CLIPS))

    def test_bind_pose_and_clips(self):
        for body in SPEC['bodies']:
            a = load(body)
            nb = len(a['bones'])
            # Rest skeleton + inverse binds reproduce the mesh exactly.
            world = []
            for b, (parent, t, r, _) in enumerate(a['bones']):
                local = bc.trs(t, r)
                world.append(bc.mmul(world[parent], local) if parent >= 0 else local)
            for b in range(nb):
                m = bc.mmul(world[b], column_major(a['bones'][b][3]))
                for i in range(4):
                    for j in range(4):
                        self.assertAlmostEqual(m[i][j], float(i == j), delta=1e-3, msg=f'{body} bone {b}')
            for clip in CLIPS:
                with self.subTest(body=body, clip=clip):
                    fps, frames, rot, hips = a['clips'][clip]
                    self.assertTrue(24 <= fps <= 31 and frames >= 60, (fps, frames))
                    self.assertTrue(all(abs(math.sqrt(sum(c * c for c in q)) - 1) < 1e-3 for q in rot))
                    # Root is static; quaternions stay on one hemisphere frame to frame.
                    for f in range(1, frames):
                        self.assertEqual(rot[f * nb], rot[0])
                        for b in range(nb):
                            q, p = rot[f * nb + b], rot[(f - 1) * nb + b]
                            self.assertGreaterEqual(sum(x * y for x, y in zip(q, p)), 0)
                    # Loops close: last frame is near the first.
                    seam = max(math.dist(hips[-1], hips[0]), *(1 - abs(sum(x * y for x, y in zip(rot[(frames - 1) * nb + b], rot[b])))
                                                              for b in range(nb)))
                    self.assertLess(seam, 0.02)
                    pts, world = skin(a, clip, frames // 2)
                    pelvis_y = world[bc.HIPS][1][3]
                    lowest = min(p[1] for p in pts)
                    if clip == 'cheer':
                        self.assertGreater(pelvis_y, 0.4 * a['height'], 'standing')
                        self.assertLess(abs(lowest), 0.06, 'feet on the floor')
                    else:
                        self.assertAlmostEqual(pelvis_y, 0.31 * a['height'], delta=0.05, msg='seated')
                        self.assertGreater(lowest, -0.06, 'not through the floor')
                    head = world[6]
                    self.assertGreater(head[2][2], 0.5, 'head faces +Z (toward the ring)')


if __name__ == '__main__':
    unittest.main()
