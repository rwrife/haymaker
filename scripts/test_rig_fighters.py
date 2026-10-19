"""HMR2 fighter asset checks (stdlib only): byte-exact rebuild from OBJ + skin sidecar, the 22-bone
skeleton contract, and the skin-weight guarantees the Mixamo animations rely on (rigid gloves, boots
and head; no weight crossing between the left and right limbs)."""
import json
import math
import re
import struct
import subprocess
import unittest

from rig_fighters import BONES, NAMES, ROOT, pack

B = {name: i for i, name in enumerate(BONES)}
# Spec parent table (independent copy, so a packer edit cannot silently change the contract).
SPEC_PARENTS = (-1, 0, 1, 2, 3, 4, 3, 6, 7, 8, 3, 10, 11, 12, 0, 14, 15, 16, 0, 18, 19, 20)
SPEC_BONES = ('Hips', 'Spine', 'Spine1', 'Spine2', 'Neck', 'Head',
              'LeftShoulder', 'LeftArm', 'LeftForeArm', 'LeftHand',
              'RightShoulder', 'RightArm', 'RightForeArm', 'RightHand',
              'LeftUpLeg', 'LeftLeg', 'LeftFoot', 'LeftToeBase',
              'RightUpLeg', 'RightLeg', 'RightFoot', 'RightToeBase')
HEIGHT = 2.7  # runtime units: every sculpt is normalised to this height
SIDES = ((1, 'Left'), (-1, 'Right'))
LIMBS = ('Shoulder', 'Arm', 'ForeArm', 'Hand', 'UpLeg', 'Leg', 'Foot', 'ToeBase')


def parse(data):
    magic, count, index_count, bone_count = struct.unpack_from('<4sIII', data)
    bones = [struct.unpack_from('<i6f', data, 16 + i * 28) for i in range(bone_count)]
    start = 16 + bone_count * 28
    rows = list(struct.iter_unpack('<13f4H', data[start:start + count * 60]))
    return dict(magic=magic, count=count, index_count=index_count, bone_count=bone_count, size=len(data),
                parents=[b[0] for b in bones], heads=[b[1:4] for b in bones], aims=[b[4:7] for b in bones],
                rows=rows, indices=struct.unpack_from(f'<{index_count}I', data, start + count * 60))


def sub(a, b):
    return [x - y for x, y in zip(a, b)]


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def unit(v):
    n = math.sqrt(dot(v, v))
    return [x / n for x in v]


def weight(row, bone):
    return sum(w for w, j in zip(row[9:13], row[13:17]) if j == bone and w > 0)


def bones_of(row):
    return {j for w, j in zip(row[9:13], row[13:17]) if w > 0}


class FighterAssetsTests(unittest.TestCase):
    assets = {}

    @classmethod
    def setUpClass(cls):
        for name in NAMES:
            data = pack(name)
            cls.assets[name] = (data, parse(data))

    def test_roster_asset_contract(self):
        roster = (ROOT/'Packages'/'HaymakerKit'/'Sources'/'HaymakerKit'/'CharacterRoster.swift').read_text()
        pairs = set(re.findall(r'case "([^"]+)":\s*CharacterProfile\(asset: "([^"]+)"', roster))
        pairs.add(('mack', 'mack'))  # Mack is the player, outside the opponent roster.
        self.assertEqual(pairs, {
            ('mack', 'mack'), ('goldie', 'goldie'), ('nico', 'nico'),
            ('atlas', 'atlas'), ('vera', 'vera'), ('duke', 'duke'),
            ('sylvie', 'sylvie'), ('cassian', 'cassian'), ('baxter', 'bruiser'), ('jaison', 'jaison'), ('hunter', 'hunter'),
        })
        committed = set(subprocess.check_output(
            ['git', 'ls-files', 'Haymaker/Models/*.fighter'], cwd=ROOT, text=True
        ).splitlines())
        for character, asset in pairs:
            with self.subTest(character=character, asset=asset):
                path = f'Haymaker/Models/{asset}.fighter'
                self.assertIn(path, committed)
                self.assertTrue((ROOT/path).is_file())
        self.assertEqual(committed, {f'Haymaker/Models/{name}.fighter' for name in NAMES})

    def test_rebuild_is_byte_identical(self):
        for name in NAMES:
            with self.subTest(model=name):
                committed = (ROOT / 'Haymaker' / 'Models' / f'{name}.fighter').read_bytes()
                self.assertTrue(self.assets[name][0] == committed,
                                f'{name}.fighter is stale: run python3 scripts/rig_fighters.py')

    def test_defeated_portraits_cover_the_story_roster(self):
        roster = (ROOT/'Packages'/'HaymakerKit'/'Sources'/'HaymakerKit'/'CharacterRoster.swift').read_text()
        assets = set(re.findall(r'CharacterProfile\(asset: "([^"]+)"', roster))
        catalog = ROOT/'Haymaker'/'Assets.xcassets'
        self.assertEqual({p.stem.removesuffix('-defeated') for p in catalog.glob('*-defeated.imageset')}, assets)
        for asset in assets:
            with self.subTest(asset=asset):
                filename = f'{asset}-defeated.png'
                imageset = catalog/f'{asset}-defeated.imageset'
                contents = json.loads((imageset/'Contents.json').read_text())
                self.assertEqual(contents['images'], [{'filename': filename, 'idiom': 'universal'}])
                data = (imageset/filename).read_bytes()
                self.assertEqual(data, (ROOT/'ArtDirection'/'DefeatedPortraits'/filename).read_bytes())
                self.assertEqual(data[:8], b'\x89PNG\r\n\x1a\n')
                self.assertEqual(struct.unpack_from('>II', data, 16), (1024, 1536))

    def test_header_and_skeleton(self):
        self.assertEqual(BONES, SPEC_BONES)
        for name in NAMES:
            a = self.assets[name][1]
            with self.subTest(model=name):
                self.assertEqual(a['magic'], b'HMR2')
                self.assertEqual(a['bone_count'], 22)
                self.assertEqual(a['size'], 16 + 22 * 28 + a['count'] * 60 + a['index_count'] * 4)
                self.assertEqual(tuple(a['parents']), SPEC_PARENTS)
                for i, (head, aim) in enumerate(zip(a['heads'], a['aims'])):
                    self.assertTrue(all(math.isfinite(v) for v in head + aim))
                    self.assertGreater(math.dist(head, aim), 1e-3, BONES[i])
                # Mixamo convention: "Left" is the character's anatomical left = +X.
                for s, side in SIDES:
                    for limb in LIMBS:
                        self.assertGreater(s * a['heads'][B[side + limb]][0], 0, side + limb)
                self.assertEqual(a['index_count'] % 3, 0)
                self.assertLess(max(a['indices']), a['count'])

    def test_vertex_attributes_and_weights(self):
        for name in NAMES:
            a = self.assets[name][1]
            with self.subTest(model=name):
                for row in a['rows']:
                    self.assertTrue(all(math.isfinite(v) for v in row[:13]))
                    self.assertTrue(all(0 <= c <= 1 for c in row[6:9]))
                    norm = sum(v * v for v in row[3:6])
                    self.assertTrue(norm < 1e-4 or abs(norm - 1) < 1e-4)  # zero only for unreferenced vertices
                    weights, ids = row[9:13], row[13:17]
                    self.assertAlmostEqual(sum(weights), 1, delta=1e-4)
                    self.assertEqual(list(weights), sorted(weights, reverse=True))
                    self.assertTrue(all(j < 22 for j in ids))
                    self.assertTrue(all(j == 0 for w, j in zip(weights, ids) if w == 0))

    def test_gloves_are_rigid(self):
        # Mixamo's hand joint sits inside the glove; the glove cuff is ~7 % of the height before it. Past
        # 6.5 % of the height before the hand joint (along the forearm) the whole glove must follow the hand;
        # the ForeArm->Hand blend lives on the bare wrist before the cuff.
        for name in NAMES:
            a = self.assets[name][1]
            with self.subTest(model=name):
                for s, side in SIDES:
                    hand, elbow = a['heads'][B[side + 'Hand']], a['heads'][B[side + 'ForeArm']]
                    arm_x = s * a['heads'][B[side + 'Arm']][0]
                    axis = unit(sub(hand, elbow))
                    glove = [r for r in a['rows'] if s * r[0] > arm_x and dot(sub(r[:3], hand), axis) > -0.065 * HEIGHT]
                    self.assertGreater(len(glove), 0.025 * len(a['rows']))
                    worst = min(weight(r, B[side + 'Hand']) for r in glove)
                    self.assertGreaterEqual(worst, 0.98, f'{side} glove')

    def test_no_weight_crosses_sides(self):
        for name in NAMES:
            a = self.assets[name][1]
            with self.subTest(model=name):
                for s, side in SIDES:
                    other = {B[side + limb] for limb in LIMBS}
                    for row in a['rows']:
                        if s * row[0] < 0:
                            self.assertFalse(bones_of(row) & other, f'{side} limb weight at x={row[0]:.3f}')

    def test_feet_stay_on_the_foot_bones(self):
        for name in NAMES:
            a = self.assets[name][1]
            with self.subTest(model=name):
                for s, side in SIDES:
                    ankle_y = a['heads'][B[side + 'Foot']][1]
                    foot = {B[side + 'Foot'], B[side + 'ToeBase']}
                    below_ankle, sole = 0, 0
                    for row in a['rows']:
                        if s * row[0] > 0 and row[1] < ankle_y:
                            below_ankle += 1
                            self.assertLessEqual(bones_of(row), foot | {B[side + 'Leg']})
                            if row[1] < 0.5 * ankle_y:
                                sole += 1
                                self.assertLessEqual(bones_of(row), foot)
                    self.assertGreater(sole, 100)

    def test_head_is_rigid(self):
        # Face (front half above 40 % of the head bone) and cranium (above 60 %) move only with the Head.
        for name in NAMES:
            a = self.assets[name][1]
            with self.subTest(model=name):
                head, top = a['heads'][B['Head']], a['aims'][B['Head']]
                length = top[1] - head[1]
                region = [r for r in a['rows'] if abs(r[0]) < 0.4 * length and
                          (r[1] > head[1] + 0.6 * length or (r[1] > head[1] + 0.4 * length and r[2] > head[2]))]
                self.assertGreater(len(region), 0.05 * len(a['rows']))
                for row in region:
                    self.assertEqual(bones_of(row), {B['Head']})


if __name__ == '__main__':
    unittest.main()
