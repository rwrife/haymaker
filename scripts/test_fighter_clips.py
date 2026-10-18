"""Contract checks for Haymaker/Models/fighter.clips, the HMC1 clip library baked by scripts/blender/extract_clips.py.

Stdlib only (CI runs it with the system python3):  python3 scripts/test_fighter_clips.py
Format, clip names and markers: ArtDirection/Animations/README.md.
"""
import json
import math
import struct
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIBRARY = ROOT/'Haymaker'/'Models'/'fighter.clips'
REFERENCE = ROOT/'ArtDirection'/'Rigs'/'mixamo-reference-skeleton.json'

ORDER = ['Hips', 'Spine', 'Spine1', 'Spine2', 'Neck', 'Head',
         'LeftShoulder', 'LeftArm', 'LeftForeArm', 'LeftHand',
         'RightShoulder', 'RightArm', 'RightForeArm', 'RightHand',
         'LeftUpLeg', 'LeftLeg', 'LeftFoot', 'LeftToeBase',
         'RightUpLeg', 'RightLeg', 'RightFoot', 'RightToeBase']
PARENT = [-1, 0, 1, 2, 3, 4, 3, 6, 7, 8, 3, 10, 11, 12, 0, 14, 15, 16, 0, 18, 19, 20]
CHILD = {0: 1, 1: 2, 2: 3, 3: 4, 4: 5, 6: 7, 7: 8, 8: 9, 10: 11, 11: 12, 12: 13,
         14: 15, 15: 16, 16: 17, 18: 19, 19: 20, 20: 21}
HANDS, TOES = (9, 13), (17, 21)
SPINE2, HEAD = 3, 5

# Spec contract: clip name -> (loops, required markers in ascending order).
CONTRACT = {
    'idle': (True, ()),
    'jab': (False, ('chamber', 'contact', 'recovered')),
    'hook': (False, ('chamber', 'contact', 'recovered')),
    'uppercut': (False, ('chamber', 'contact', 'recovered')),
    'block': (False, ('guardUp', 'holdEnd')),
    'bodyBlock': (False, ('guardUp', 'holdEnd')),
    'slip': (False, ('slipped', 'holdEnd')),
    'hitHead': (False, ('impact', 'recovered')),
    'hitBody': (False, ('impact', 'recovered')),
    'hitSide': (False, ('impact', 'recovered')),
    'knockdown': (False, ('react', 'ground', 'settled')),
    'getUp': (False, ('rise', 'standing')),
    'victory': (False, ('armsUp', 'armsDown')),
    'warmup': (True, ()),
    'cross': (False, ('chamber', 'contact', 'recovered')),  # extra (RightPunch straight right); runtime may ignore it
}
# Clips the runtime blends in and out of the idle guard: they must start and end on idle's first frame.
GUARD_ENDS = ('jab', 'hook', 'uppercut', 'cross', 'block', 'bodyBlock', 'slip', 'hitHead', 'hitBody', 'hitSide', 'victory')
IN_PLACE = ('idle', 'block', 'bodyBlock', 'slip', 'hitHead', 'hitBody', 'hitSide', 'victory', 'warmup')

MAX_BYTES = 1500000
MAX_DEG_PER_S = 1600.      # fastest legit motion is hitHead's head snap (~1370 deg/s)
POP_DEG, POP_RATIO = 25., 3.  # a single-frame step this big and this much above both neighbours is a pop
GLOVE_FLOOR = 0.065        # Mack's glove centre sits >= 0.07 above the mat (OBJ units)
OFF_HAND = {'jab': 13, 'hook': 9, 'uppercut': 13, 'cross': 9}  # the glove that is not punching must stay in its guard
OFF_HAND_DRIFT = 0.125     # max chest-relative drift of that glove from its idle-guard spot (units)
PUNCHES = ('jab', 'hook', 'uppercut', 'cross')
POST_CONTACT_DRIFT = 0.08  # max further forward (+Z) hips travel after a punch's contact (units)
MAX_TWIST = 90.            # max |twist| of any bone's local rotation about its own rest axis (deg): candy-wrap guard
LEG_BONES, MAX_LEG_TWIST = (14, 15, 18, 19), 30.  # UpLeg/Leg twist stays small (knees and thighs wrap visibly)
# Boot sole points, as in extract_clips.SOLE: (anchor: 0 ankle/Foot, 1 ball/Foot, 2 toe end/ToeBase, dx, dz), left foot
# (x mirrored for the right). Each sits on the floor in the rest pose.
SOLE = ((0, -0.025, -0.05), (0, 0.035, -0.05), (1, -0.025, 0.), (1, 0.035, 0.), (2, -0.02, 0.), (2, 0.03, 0.))
FLOOR_TOLERANCE = 0.002    # boot soles may not dip further below the mat (y = 0) than this, in any clip (units)


def qmul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (aw*bx + ax*bw + ay*bz - az*by, aw*by - ax*bz + ay*bw + az*bx,
            aw*bz + ax*by - ay*bx + az*bw, aw*bw - ax*bx - ay*by - az*bz)


def qrot(q, v):
    x, y, z, w = qmul(qmul(q, (v[0], v[1], v[2], 0.)), (-q[0], -q[1], -q[2], q[3]))
    return (x, y, z)


def qconj(q):
    return (-q[0], -q[1], -q[2], q[3])


def angle(a, b):
    return math.degrees(2.*math.acos(min(1., abs(sum(x*y for x, y in zip(a, b))))))


def dist(a, b):
    return math.sqrt(sum((x - y)**2 for x, y in zip(a, b)))


class Clip:
    def __init__(self, name, fps, flags, markers, hips, quats):
        self.name, self.fps, self.flags, self.markers, self.hips, self.quats = name, fps, flags, markers, hips, quats
        self.T = len(hips)

    def pose_delta(self, i, other, j):
        """(max bone angle in degrees, hips distance) between frame i of self and frame j of other."""
        return (max(angle(a, b) for a, b in zip(self.quats[i], other.quats[j])), dist(self.hips[i], other.hips[j]))

    def steps(self):
        """Per frame t>=1: per-bone rotation (degrees) from t-1 to t."""
        return [[angle(a, b) for a, b in zip(self.quats[t - 1], self.quats[t])] for t in range(1, self.T)]

    def yaw(self, t):
        f = qrot(self.quats[t][0], (0., 0., 1.))
        return math.degrees(math.atan2(f[0], f[2]))

    def joints(self, t, source):
        """Posed heads (spec QA rule: head'(b) = head'(parent) + G(parent)*(head(b) - head(parent)), G = delta)."""
        heads, q = [s[0] for s in source], self.quats[t]
        out = [self.hips[t]]
        for b in range(1, len(heads)):
            p = PARENT[b]
            off = qrot(q[p], [heads[b][k] - heads[p][k] for k in range(3)])
            out.append(tuple(out[p][k] + off[k] for k in range(3)))
        return out

    def local(self, t, b):
        q = self.quats[t]
        return q[b] if PARENT[b] < 0 else qmul(qconj(q[PARENT[b]]), q[b])

    def twist(self, t, source, b):
        """|twist| (deg) of bone b's local rotation about its rest axis (swing-twist decomposition)."""
        head, aim = source[b]
        axis = [aim[k] - head[k] for k in range(3)]
        n = math.sqrt(sum(v*v for v in axis))
        q = self.local(t, b)
        tw = abs(2.*math.atan2(sum(q[k]*axis[k] for k in range(3))/n, q[3]))
        return math.degrees(min(tw, 2.*math.pi - tw))

    def soles(self, t, source):
        """Heights of the boot-sole points of both feet."""
        joints, out = self.joints(t, source), []
        for foot, sx in ((16, 1.), (20, -1.)):
            toe = CHILD[foot]
            anchors = (source[foot][0], source[toe][0], source[toe][1])
            for k, dx, dz in SOLE:
                b = foot if k < 2 else toe
                a = anchors[k]
                pt = (a[0] + dx*sx, 0., a[2] + dz)
                off = qrot(self.quats[t][b], [pt[i] - source[b][0][i] for i in range(3)])
                out.append(joints[b][1] + off[1])
        return out

    def tip(self, t, source, b, frac):
        head, aim = source[b]
        joints = self.joints(t, source)
        off = qrot(self.quats[t][b], [(aim[k] - head[k])*frac for k in range(3)])
        return tuple(joints[b][k] + off[k] for k in range(3))


def cstr(raw):
    text, _, pad = raw.partition(b'\0')
    assert not pad.strip(b'\0'), 'garbage after NUL in %r' % raw
    return text.decode('ascii')


def load(data):
    magic, bones, count, reserved = struct.unpack_from('<4sIII', data, 0)
    offset = 16
    source = []
    for _ in range(bones):
        row = struct.unpack_from('<6f', data, offset)
        source.append((row[:3], row[3:]))
        offset += 24
    clips = []
    for _ in range(count):
        name, fps, frames, flags, nmarkers = struct.unpack_from('<24sfIII', data, offset)
        offset += 40
        markers = []
        for _ in range(nmarkers):
            mname, frame = struct.unpack_from('<16sf', data, offset)
            markers.append((cstr(mname), frame))
            offset += 20
        stride = 3 + 4*bones
        values = struct.unpack_from('<%df' % (frames*stride), data, offset)
        offset += 4*frames*stride
        hips = [values[t*stride:t*stride + 3] for t in range(frames)]
        quats = [[values[t*stride + 3 + 4*b:t*stride + 7 + 4*b] for b in range(bones)] for t in range(frames)]
        clips.append(Clip(cstr(name), fps, flags, markers, hips, quats))
    return (magic, bones, count, reserved), source, clips, offset


class FighterClipsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = LIBRARY.read_bytes()
        cls.header, cls.source, clips, cls.parsed = load(cls.data)
        cls.clips = {c.name: c for c in clips}
        cls.names = [c.name for c in clips]

    def test_header_and_layout(self):
        self.assertEqual(self.header, (b'HMC1', 22, len(self.names), 0))
        self.assertEqual(self.parsed, len(self.data), 'trailing or missing bytes')
        self.assertLess(len(self.data), MAX_BYTES)
        self.assertEqual(len(set(self.names)), len(self.names), 'duplicate clip names')

    def test_source_matches_reference_skeleton(self):
        ref = {b['name']: b for b in json.loads(REFERENCE.read_text())['bones']}
        for b, name in enumerate(ORDER):
            r = ref[name]
            self.assertEqual(r['parent'], PARENT[b])
            if b in CHILD:
                aim = ref[ORDER[CHILD[b]]]['head']
            elif b in HANDS:
                aim = r['tail']   # glove tip along the forearm
            else:
                aim = r['end']    # HeadTop_End / Toe_End
            head, src_aim = self.source[b]
            for got, want in zip(head + src_aim, list(r['head']) + list(aim)):
                self.assertAlmostEqual(got, want, delta=1e-4, msg=name)

    def test_contract_clips_and_markers(self):
        for name, (loops, required) in CONTRACT.items():
            with self.subTest(clip=name):
                self.assertIn(name, self.clips)
                c = self.clips[name]
                self.assertIn(c.fps, (24., 30.))
                self.assertGreaterEqual(c.T, 10)
                self.assertEqual(bool(c.flags & 1), loops)
                self.assertEqual(c.flags & ~1, 0)
                names = [m for m, _ in c.markers]
                self.assertEqual([m for m in names if m in required], list(required))
                frames = [f for _, f in c.markers]
                self.assertEqual(frames, sorted(frames), 'markers must ascend')
                self.assertTrue(all(0 <= f <= c.T - 1 for f in frames), frames)
                if required:
                    self.assertLess(frames[0], frames[-1])

    def test_samples_are_clean(self):
        for c in self.clips.values():
            with self.subTest(clip=c.name):
                for t in range(c.T):
                    self.assertTrue(all(math.isfinite(v) for v in c.hips[t]))
                    for q in c.quats[t]:
                        self.assertTrue(all(math.isfinite(v) for v in q))
                        self.assertAlmostEqual(sum(v*v for v in q), 1., delta=1e-4)
                    if t:
                        for a, b in zip(c.quats[t - 1], c.quats[t]):
                            self.assertGreaterEqual(sum(x*y for x, y in zip(a, b)), 0., 'hemisphere flip at %d' % t)

    def test_no_pops(self):
        for c in self.clips.values():
            with self.subTest(clip=c.name):
                steps = c.steps()
                fastest = max(max(s) for s in steps)*c.fps
                self.assertLess(fastest, MAX_DEG_PER_S)
                for t in range(1, len(steps) - 1):
                    for b in range(len(ORDER)):
                        if b in TOES:
                            continue  # Mixamo slaps the toes flat in one frame at foot plant (ground contact)
                        s = steps[t][b]
                        if s > POP_DEG:
                            self.assertLess(s, POP_RATIO*max(steps[t - 1][b], steps[t + 1][b], 1.),
                                            'single-frame pop on %s at frame %d' % (ORDER[b], t + 1))

    def test_loops_wrap_seamlessly(self):
        for name in ('idle', 'warmup'):
            with self.subTest(clip=name):
                c = self.clips[name]
                steps = sorted(max(s) for s in c.steps())
                hip_steps = sorted(dist(c.hips[t - 1], c.hips[t]) for t in range(1, c.T))
                wrap_angle, wrap_hips = c.pose_delta(c.T - 1, c, 0)
                self.assertLessEqual(wrap_angle, 1.5*steps[len(steps)//2] + 1.)
                self.assertLessEqual(wrap_hips, 2.*hip_steps[len(hip_steps)//2] + 1e-3)

    def test_guard_ends(self):
        idle = self.clips['idle']
        for name in GUARD_ENDS + ('knockdown',):
            with self.subTest(clip=name):
                c = self.clips[name]
                ends = (0,) if name == 'knockdown' else (0, c.T - 1)
                for t in ends:
                    ang, hips = c.pose_delta(t, idle, 0)
                    self.assertLess(ang, 3., 'frame %d is %.1f deg off the idle guard' % (t, ang))
                    self.assertLess(hips, 0.01)

    def test_root_stays_put(self):
        idle = self.clips['idle']
        home = idle.hips[0]
        for c in self.clips.values():
            with self.subTest(clip=c.name):
                wander = max(math.hypot(h[0] - home[0], h[2] - home[2]) for h in c.hips)
                self.assertLess(wander, 0.2 if c.name in IN_PLACE else 0.45)
                if c.name != 'knockdown':
                    self.assertLess(math.hypot(c.hips[-1][0] - c.hips[0][0], c.hips[-1][2] - c.hips[0][2]),
                                    0.01 if c.name != 'getUp' else 0.4)

    def test_knockdown_into_getup(self):
        kd, gu, idle = self.clips['knockdown'], self.clips['getUp'], self.clips['idle']
        ang, hips = kd.pose_delta(kd.T - 1, gu, 0)
        self.assertLess(ang, 0.5)
        self.assertLess(hips, 1e-3)
        markers = dict(kd.markers)
        ground = int(markers['ground'])
        self.assertLess(kd.hips[ground][1], 0.5*kd.hips[0][1], 'ground marker before the landing')
        self.assertLess(kd.hips[ground][2] - kd.hips[0][2], -0.1, 'knockdown should fall backwards (-Z)')
        rest = self.source[0][0]
        end = gu.hips[-1]
        self.assertLess(math.hypot(end[0] - rest[0], end[2] - rest[2]), 0.02, 'getUp must end over the rest hips')
        self.assertLess(abs(gu.yaw(gu.T - 1) - idle.yaw(0)), 2.)
        ang, hips = gu.pose_delta(gu.T - 1, idle, 0)
        self.assertLess(ang, 3.)
        self.assertLess(hips, 0.01)
        standing = int(dict(gu.markers)['standing'])
        self.assertGreater(gu.hips[standing][1], 0.9*idle.hips[0][1])

    def test_gloves_and_feet_above_mat(self):
        for c in self.clips.values():
            with self.subTest(clip=c.name):
                for t in range(c.T):
                    for b in HANDS:
                        self.assertGreater(c.tip(t, self.source, b, 0.5)[1], GLOVE_FLOOR, 'frame %d' % t)
                    for b in TOES:
                        self.assertGreater(c.tip(t, self.source, b, 1.)[1], -0.02, 'frame %d' % t)

    def test_boots_stay_on_the_mat(self):
        for c in self.clips.values():
            with self.subTest(clip=c.name):
                low = min((min(c.soles(t, self.source)), t) for t in range(c.T))
                self.assertGreater(low[0], -FLOOR_TOLERANCE, 'boot sole %.4f below the mat at frame %d' % low)

    def test_limb_twist_is_limited(self):
        """No bone twists far about its own axis (linear-blend skins candy-wrap): knockdown's forearm used to reach
        ~178 deg, hitHead's thigh ~55 deg."""
        for c in self.clips.values():
            with self.subTest(clip=c.name):
                for b in range(1, len(ORDER)):
                    worst = max((c.twist(t, self.source, b), t) for t in range(c.T))
                    limit = MAX_LEG_TWIST if b in LEG_BONES else MAX_TWIST
                    self.assertLess(worst[0], limit, '%s twists %.1f deg at frame %d' % ((ORDER[b],) + worst))

    def test_punches_do_not_drive_through_contact(self):
        """After the glove lands the body may not keep lunging forward into the opponent."""
        for name in PUNCHES:
            with self.subTest(clip=name):
                c = self.clips[name]
                contact = int(dict(c.markers)['contact'])
                drift = max(h[2] for h in c.hips[contact:]) - c.hips[contact][2]
                self.assertLess(drift, POST_CONTACT_DRIFT)

    def test_punch_off_hand_stays_in_guard(self):
        """The non-punching glove stays at the chin: within OFF_HAND_DRIFT of its idle spot in the chest frame unless
        it is tucked in closer to the head than at guard (a cross turns the torso under a lead glove held at the
        cheek), and never above the top of the head."""
        idle = self.clips['idle']

        def spot(c, t, hand):
            joints = c.joints(t, self.source)
            g = c.tip(t, self.source, hand, 0.5)
            chest = qrot(qconj(c.quats[t][SPINE2]), [g[k] - joints[SPINE2][k] for k in range(3)])
            return g, chest, dist(g, joints[HEAD])

        for name, hand in OFF_HAND.items():
            with self.subTest(clip=name):
                c = self.clips[name]
                _, home, home_reach = spot(idle, 0, hand)
                for t in range(c.T):
                    g, chest, reach = spot(c, t, hand)
                    if reach > home_reach:
                        self.assertLess(dist(chest, home), OFF_HAND_DRIFT, 'frame %d: off-hand left its guard' % t)
                    self.assertLess(g[1], c.tip(t, self.source, HEAD, 1.)[1], 'frame %d: off-hand above the head' % t)


if __name__ == '__main__':
    unittest.main()
