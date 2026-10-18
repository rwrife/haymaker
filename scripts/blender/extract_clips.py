"""Bake the Mixamo boxing animations into Haymaker's HMC1 clip library.

Run headless (Blender 5.x bundles numpy + mathutils):

  /Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup --python-exit-code 1 \
      --python scripts/blender/extract_clips.py -- \
      [--fbx-dir ~/Downloads] [--out Haymaker/Models/fighter.clips] [--report stats.json]

Inputs are the user's Mixamo FBX downloads ("Without Skin", "No Fingers" skeleton, native 24/30 fps).
Raw FBX files are never copied into the repo (Mixamo licence); only this derived bake is committed.
The output is byte-for-byte deterministic for the same inputs. See ArtDirection/Animations/README.md
for the format, markers and every cleanup step performed here.
"""
import argparse
import json
import math
import os
import struct
import sys

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REFERENCE = os.path.join(ROOT, 'ArtDirection', 'Rigs', 'mixamo-reference-skeleton.json')

ORDER = ['Hips', 'Spine', 'Spine1', 'Spine2', 'Neck', 'Head',
         'LeftShoulder', 'LeftArm', 'LeftForeArm', 'LeftHand',
         'RightShoulder', 'RightArm', 'RightForeArm', 'RightHand',
         'LeftUpLeg', 'LeftLeg', 'LeftFoot', 'LeftToeBase',
         'RightUpLeg', 'RightLeg', 'RightFoot', 'RightToeBase']
PARENT = [-1, 0, 1, 2, 3, 4, 3, 6, 7, 8, 3, 10, 11, 12, 0, 14, 15, 16, 0, 18, 19, 20]
CHILD = {0: 1, 1: 2, 2: 3, 3: 4, 4: 5, 6: 7, 7: 8, 8: 9, 10: 11, 11: 12, 12: 13,
         14: 15, 15: 16, 16: 17, 18: 19, 19: 20, 20: 21}
END_BONE = {5: 'HeadTop_End', 17: 'LeftToe_End', 21: 'RightToe_End'}
NB = len(ORDER)
SPINE2, HEAD = 3, 5
L_HAND, R_HAND = 9, 13
LEFT_ARM_CHAIN = (6, 7, 8, 9)
RIGHT_ARM_CHAIN = (10, 11, 12, 13)
UPPER_BODY = (3, 4, 5, 7, 8, 9, 11, 12, 13)

LEGS = ((14, 15, 16), (18, 19, 20))           # UpLeg, Leg, Foot
ARMS = ((7, 8, 9), (11, 12, 13))              # Arm, ForeArm, Hand

# (clip name, FBX basename) in file order = the runtime contract; `cross` is an extra (appended last) that the
# runtime may ignore. Boxing.fbx is deliberately unused: it is the UpperCut motion re-exported at 30 fps (see
# ArtDirection/Animations/README.md).
CLIPS = [('idle', 'Idle'), ('jab', 'LeftPunch'), ('hook', 'Hook Punch'), ('uppercut', 'UpperCut'),
         ('block', 'Center Block'), ('bodyBlock', 'Body Block'), ('slip', 'Left Block'),
         ('hitHead', 'Head Hit'), ('hitBody', 'Kidney Hit'), ('hitSide', 'Side Hit'),
         ('knockdown', 'Falling Down'), ('getUp', 'Getting Up'), ('victory', 'Victory'),
         ('warmup', 'WarmingUp'), ('cross', 'RightPunch')]
# (clip, FBX, punching hand, reach axis, arc): `arc` punches wind up before a sweeping strike, so their chamber is the
# cocked pose where the glove stalls between wind-up and sweep instead of the start of the drive along `axis`.
PUNCHES = (('jab', 'LeftPunch', L_HAND, (0, 0, 1), False), ('hook', 'Hook Punch', R_HAND, (0, 0, 1), True),
           ('uppercut', 'UpperCut', L_HAND, (0, 1, 0), False), ('cross', 'RightPunch', R_HAND, (0, 0, 1), False))
# Hook Punch.fbx was captured in a squarer stance (~8 deg): re-root it onto the idle guard's feet so planted feet barely
# move and the hook lands on the same target line as the other punches.
ALIGN_STANCE = ('hook',)
LOOP_BIT = 1

GLOVE_FLOOR = 0.07      # min glove-centre height: Mack's glove is ~0.06-0.09 around its centre (OBJ units)
ELBOW_FLOOR = 0.035     # min elbow-joint height (forearm thickness)
ELBOW_FLEX = (3., 155.)  # elbow flex range (deg) the glove-floor fix may bend/unbend within
PLANT_SPEED = 0.12      # foot (ankle) speed below which a low foot counts as planted, units/s
PLANT_HEIGHT = 0.15
BODY_BLOCK_KEEP = (19, 51)  # 0-based source frames of Body Block that contain the cover
GETUP_SEAM_FADE = 16        # frames over which getUp's own start pose takes over from the knockdown's last pose
OFF_HAND_DRIFT = 0.12   # max chest-relative drift of a punch's non-punching glove from its idle-guard spot (units)
OFF_HAND_HOLD = 0.88    # weight pulling a drifting off-hand arm onto its guard pose (chest-relative) until contact
OFF_HAND_TOP = 0.03     # the off-hand glove centre must stay at least this far below the top of the head (units)
# Boot sole model (OBJ units, rest pose, left foot; mirrored in x for the right): (bone, dx, dz) points on the floor
# under the heel corners (Foot, relative to the ankle), the ball (Foot, relative to the ball joint) and the toe tip
# (ToeBase, relative to the toe end). Mack's boot spans ~0.05 behind the ankle to the toe end and ~-0.02..+0.05 in x.
SOLE = ((0, -0.025, -0.05), (0, 0.035, -0.05), (1, -0.025, 0.), (1, 0.035, 0.), (2, -0.02, 0.), (2, 0.03, 0.))
POST_CONTACT_DRIFT = 0.012  # soft cap on how much further the hips may travel forward after a punch's contact (units)
# Max |twist| (deg) of a bone's local rotation about its own rest axis, with the soft-clamp margin below it: twist up to
# limit - margin is kept as authored, beyond that it saturates smoothly at the limit; the excess goes to the child bone.
TWIST_LIMITS = {7: (85., 10.), 11: (85., 10.), 8: (80., 10.), 12: (80., 10.),     # Arm, ForeArm
                14: (27., 8.), 18: (27., 8.), 15: (27., 8.), 19: (27., 8.)}       # UpLeg, Leg


# --------------------------------------------------------------------------- quaternion math (xyzw)

def qmul(a, b):
    ax, ay, az, aw = np.moveaxis(a, -1, 0)
    bx, by, bz, bw = np.moveaxis(b, -1, 0)
    return np.stack([aw * bx + ax * bw + ay * bz - az * by,
                     aw * by - ax * bz + ay * bw + az * bx,
                     aw * bz + ax * by - ay * bx + az * bw,
                     aw * bw - ax * bx - ay * by - az * bz], -1)


def qinv(q):
    return q * np.array([-1., -1., -1., 1.])


def qnorm(q):
    return q / np.linalg.norm(q, axis=-1, keepdims=True)


def qrot(q, v):
    u, w = q[..., :3], q[..., 3:4]
    t = 2. * np.cross(u, v)
    return v + w * t + np.cross(u, t)


def qangle(a, b):
    return 2. * np.arccos(np.clip(np.abs(np.sum(a * b, -1)), 0., 1.))


def qpow(q, w):
    """Rotation q scaled to fraction w of its angle (shortest path); q (...,4), w broadcastable."""
    q = np.where(q[..., 3:4] < 0, -q, q)
    s = np.linalg.norm(q[..., :3], axis=-1, keepdims=True)
    half = np.arctan2(s, q[..., 3:4])
    axis = np.where(s > 1e-12, q[..., :3] / np.maximum(s, 1e-12), 0.)
    w = np.asarray(w, dtype=float)[..., None]
    return np.concatenate([axis * np.sin(half * w), np.cos(half * w)], -1)


def qslerp(a, b, w):
    b = np.where(np.sum(a * b, -1, keepdims=True) < 0, -b, b)
    return qnorm(qmul(qpow(qmul(b, qinv(a)), w), a))


def qbetween(u, v):
    u = u / np.linalg.norm(u, axis=-1, keepdims=True)
    v = v / np.linalg.norm(v, axis=-1, keepdims=True)
    q = np.concatenate([np.cross(u, v), 1. + np.sum(u * v, -1, keepdims=True)], -1)
    return qnorm(q)


def qyaw(angle):
    return np.array([0., math.sin(angle / 2.), 0., math.cos(angle / 2.)])


def make_continuous(D):
    D = D.copy()
    D[0] = np.where(D[0, :, 3:4] < 0, -D[0], D[0])
    for t in range(1, len(D)):
        D[t] = np.where(np.sum(D[t] * D[t - 1], -1, keepdims=True) < 0, -D[t], D[t])
    return D


def smoother(x):
    x = np.clip(x, 0., 1.)
    return x * x * x * (x * (x * 6. - 15.) + 10.)


def ramp(T, a, b):
    """Weights over frames 0..T-1: 0 up to frame a, smootherstep to 1 at frame b, 1 afterwards."""
    t = np.arange(T, dtype=float)
    if b <= a:
        return (t >= b).astype(float)
    return smoother((t - a) / float(b - a))


# --------------------------------------------------------------------------- skeleton helpers

def to_local(D):
    L = D.copy()
    for b in range(1, NB):
        L[:, b] = qmul(qinv(D[:, PARENT[b]]), D[:, b])
    return L


def to_global(L):
    D = L.copy()
    for b in range(1, NB):
        D[:, b] = qmul(D[:, PARENT[b]], L[:, b])
    return qnorm(D)


def fk(D, hips, heads):
    T = len(D)
    P = np.zeros((T, NB, 3))
    P[:, 0] = hips
    for b in range(1, NB):
        p = PARENT[b]
        P[:, b] = P[:, p] + qrot(D[:, p], np.broadcast_to(heads[b] - heads[p], (T, 3)))
    return P


class Clip:
    def __init__(self, name, fps, L, H, loops=False):
        self.name, self.fps, self.L, self.H, self.loops = name, fps, L, H, loops
        self.markers = []
        self.notes = []

    @property
    def T(self):
        return len(self.L)

    def D(self):
        return to_global(self.L)

    def P(self, src):
        return fk(self.D(), self.H, src.heads)

    def trim(self, a, b):
        """Keep source frames a..b inclusive."""
        self.L, self.H = self.L[a:b + 1].copy(), self.H[a:b + 1].copy()
        self.notes.append('trimmed to source frames %d-%d' % (a + 1, b + 1))


def glove(D, P, src, hand):
    """Glove centre: midway along the hand bone (wrist -> Mixamo glove tip)."""
    return P[:, hand] + qrot(D[:, hand], 0.5 * (src.aims[hand] - src.heads[hand]))


def offset_blend(clip, ref, target_L, target_H, weights):
    """Additive pose offset: frame `ref` is mapped onto the target pose with weight 1, fading per `weights`.

    Local (parent-relative) offsets are left-multiplied, so the clip's own motion is preserved while the
    pose is steered onto the target; hips translation is shifted by the same weighted offset."""
    O = qmul(target_L, qinv(clip.L[ref]))
    clip.L = qnorm(qmul(qpow(O[None], weights[:, None]), clip.L))
    clip.H = clip.H + weights[:, None] * (target_H - clip.H[ref])[None]


def pose_distance(La, Ha, Lb, Hb, src):
    """(max bone angle deg between two single poses (local), max joint distance after FK)."""
    Da, Db = to_global(La[None]), to_global(Lb[None])
    ang = np.degrees(qangle(Da[0], Db[0])).max()
    dist = np.linalg.norm(fk(Da, Ha[None], src.heads) - fk(Db, Hb[None], src.heads), axis=-1).max()
    return float(ang), float(dist)


def two_bone_ik(D, P, chain, target, heads, mask, iterations=3):
    """Rotate the upper/lower bones of `chain` (global deltas) so the end joint reaches `target` on frames in `mask`.

    Minimal-change solve: the elbow/knee only bends about its own hinge axis (measured from the clip, so it bends the
    anatomical way even from a straight limb), then the limb swings about the shoulder/hip onto the target. With the
    target at the current joint it is the identity, so pinned frames blend seamlessly into untouched ones. The end
    bone keeps its global rotation."""
    a, b, c = chain
    oa, ob = heads[b] - heads[a], heads[c] - heads[b]
    l1, l2 = np.linalg.norm(oa), np.linalg.norm(ob)
    bend = np.cross(qrot(D[:, a], oa), qrot(D[:, b], ob))
    hinge = qrot(qinv(D[:, a]), bend).sum(0)
    hinge /= np.linalg.norm(hinge)
    s = P[:, a]
    dist = np.linalg.norm(target - s, axis=-1)
    cos_goal = np.clip((np.clip(dist, abs(l1 - l2) + 1e-4, (l1 + l2) * 0.9995) ** 2 - l1 * l1 - l2 * l2)
                       / (2. * l1 * l2), -1., 1.)
    goal = np.arccos(cos_goal)
    Da, Db = D[:, a].copy(), D[:, b].copy()
    for _ in range(iterations):
        up, lo = qrot(Da, oa), qrot(Db, ob)
        n = qrot(Da, hinge)
        n = n - np.sum(n * up, -1, keepdims=True) * up / (l1 * l1)
        n /= np.linalg.norm(n, axis=-1, keepdims=True)
        cur = np.arccos(np.clip(np.sum(up * lo, -1) / (l1 * l2), -1., 1.))
        cur = np.where(np.sum(np.cross(up, lo) * n, -1) < 0, -cur, cur)  # signed bend about the hinge
        half = 0.5 * (goal - cur)[:, None]
        Db = qnorm(qmul(np.concatenate([n * np.sin(half), np.cos(half)], -1), Db))
        swing = qbetween(qrot(Da, oa) + qrot(Db, ob), target - s)
        Da, Db = qnorm(qmul(swing, Da)), qnorm(qmul(swing, Db))
    out = D.copy()
    out[mask, a] = Da[mask]
    out[mask, b] = Db[mask]
    return out


def plant_intervals(P, fps, foot):
    """[start, end] frame runs where the ankle is low and (nearly) still."""
    p = P[:, foot]
    v = np.linalg.norm(np.diff(p, axis=0), axis=-1) * fps
    still = np.r_[v[:1], np.minimum(v[1:], v[:-1]), v[-1:]] < PLANT_SPEED
    planted = still & (p[:, 1] < PLANT_HEIGHT)
    runs, t = [], 0
    while t < len(p):
        if planted[t]:
            s = t
            while t + 1 < len(p) and planted[t + 1]:
                t += 1
            if t - s >= 2:
                runs.append((s, t))
        t += 1
    return runs


def root_edit(clip, src, yaw, hxz, plants, release=4):
    """Re-root a clip: per-frame extra yaw (about the clip's own hips) and new hips XZ path.

    Feet that are planted (runs from `plants`, computed on the unedited motion) are pinned where they touched down in
    the edited motion and the legs are solved with two-bone IK, so re-rooting slides the body, not the feet. After a
    plant the pin is released over `release` frames of the swing."""
    D = clip.D()
    R = np.stack([qyaw(a) for a in yaw])
    D = qnorm(qmul(R[:, None], D))
    H = np.stack([hxz[:, 0], clip.H[:, 1], hxz[:, 1]], 1)
    P = fk(D, H, src.heads)
    for chain, runs in zip(LEGS, plants):
        foot = chain[2]
        off = np.zeros((clip.T, 3))
        for s, e in runs:
            off[s:e + 1] = P[s, foot] - P[s:e + 1, foot]
            off[s:e + 1, 1] = 0.
            for k in range(1, release + 1):
                t = e + k
                if t >= clip.T or any(s2 <= t <= e2 for s2, e2 in runs):
                    break
                off[t] = off[e] * (1. - smoother(k / float(release + 1)))
        mask = np.linalg.norm(off, axis=-1) > 1e-7
        if mask.any():
            D = two_bone_ik(D, P, chain, P[:, foot] + off, src.heads, mask)
            P = fk(D, H, src.heads)
    clip.L, clip.H = to_local(D), H


def pin_feet(clip, src, plants, orient=True):
    """Keep feet planted where the source plants them (runs from `plants`, computed on the unedited motion).

    Guard-matching blends local-rotation offsets, which drags planted feet around and tilts them into the floor. Each
    run is pinned to the foot's position and orientation at its anchor frame (frame 0 / T-1 when the run touches a clip
    end, else its middle frame); the offsets are eased across the swings between runs and fade to zero at unplanted clip
    ends, and the legs are re-solved with two-bone IK. Frames 0/T-1 (the guard pose) are unchanged."""
    D = clip.D()
    P = fk(D, clip.H, src.heads)
    T, ident = clip.T, np.array([0., 0., 0., 1.])
    for chain, runs in zip(LEGS, plants):
        foot = chain[2]
        keys = {0: (np.zeros(3), ident), T - 1: (np.zeros(3), ident)}
        for s, e in runs:
            k = 0 if s == 0 else (T - 1 if e == T - 1 else (s + e) // 2)
            for t in range(s, e + 1):
                keys[t] = (P[k, foot] - P[t, foot], qnorm(qmul(D[k, foot], qinv(D[t, foot]))) * np.sign(
                    np.sum(D[k, foot] * D[t, foot]) or 1.))
        at = sorted(keys)
        off, rot = np.zeros((T, 3)), np.zeros((T, 4))
        for t in range(T):
            j = int(np.searchsorted(at, t))
            if at[j] == t:
                off[t], rot[t] = keys[t]
                continue
            a, b = at[j - 1], at[j]
            w = float(smoother((t - a) / float(b - a)))
            off[t] = keys[a][0] * (1. - w) + keys[b][0] * w
            rot[t] = qslerp(keys[a][1], keys[b][1], w)
        mask = np.linalg.norm(off, axis=-1) > 1e-7
        if mask.any():
            D = two_bone_ik(D, P, chain, P[:, foot] + off, src.heads, mask)
        if orient:
            for b in (foot, CHILD[foot]):
                D[:, b] = qnorm(qmul(rot, D[:, b]))
        P = fk(D, clip.H, src.heads)
    clip.L = to_local(D)
    clip.notes.append('planted feet pinned (runs %s)' % '; '.join(
        '%s %s' % (ORDER[c[2]], ','.join('%d-%d' % r for r in runs)) for c, runs in zip(LEGS, plants)))


def align_stance(clip, src, guard_P):
    """Rigidly re-root a clip (yaw about Y + XZ shift) so its frame-0 feet best match the idle guard's feet."""
    feet = [16, 17, 20, 21]
    th, t = procrustes_yaw(guard_P[feet], clip.P(src)[0, feet])
    clip.L[:, 0] = qnorm(qmul(qyaw(th)[None], clip.L[:, 0]))
    xz = yaw_xz(th, clip.H[:, [0, 2]]) + t
    clip.H = np.stack([xz[:, 0], clip.H[:, 1], xz[:, 1]], 1)
    clip.notes.append('stance aligned to the idle guard feet (yaw %.1f deg, shift %.3f, %.3f)'
                      % (math.degrees(th), t[0], t[1]))


def ease_envelope(x, radius=4):
    """Smooth non-negative envelope >= x: max-filter over +-radius, then two box passes of +-radius/2."""
    pad = np.pad(x, radius, mode='edge')
    m = np.max(np.stack([pad[k:k + len(x)] for k in range(2 * radius + 1)]), 0)
    return box_smooth(m, radius // 2)


def box_smooth(x, h=2, passes=2):
    for _ in range(passes):
        pad = np.pad(x, [(h, h)] + [(0, 0)] * (x.ndim - 1), mode='edge')
        x = np.mean(np.stack([pad[k:k + len(x)] for k in range(2 * h + 1)]), 0)
    return x


def lift_above(D, P, pivot, bones, point, floor, outward, smooth):
    """Swing `bones` about joint `pivot` so `point` stays at or above height `floor`.

    The swing is about a horizontal axis, perpendicular to a heading taken from the limb's own horizontal direction.
    A limb hanging straight down has no heading of its own, so each frame's heading is weighted by how horizontal the
    limb is (|v_xz|^2 / |v|^2) and smoothed over +-8 frames, with a tiny `outward` bias as the last resort. With
    `smooth` the swing angle also eases in/out over a few frames (never below what is needed), so lifts don't pop."""
    v = point - P[:, pivot]
    r = np.linalg.norm(v, axis=-1)
    u = v / r[:, None]
    ty = (floor - P[:, pivot, 1]) / r
    if not (u[:, 1] < ty - 1e-6).any():
        return D, 0.
    flat = np.hypot(u[:, 0], u[:, 2])
    heading = u * flat[:, None] + 0.02 * outward
    heading[:, 1] = 0.
    if smooth:
        heading = box_smooth(heading, 8)
    heading /= np.maximum(np.linalg.norm(heading, axis=-1, keepdims=True), 1e-9)
    # Rotating about axis = heading x up lifts the in-plane part (along heading, up) of u by the swing angle.
    along = np.sum(u * heading, -1)
    phi = np.arctan2(u[:, 1], along)
    angle = np.maximum(0., np.arcsin(np.clip(ty / np.hypot(along, u[:, 1]), -1., 1.)) - phi)
    angle[angle < 1e-5] = 0.
    if not angle.any():
        return D, 0.
    if smooth:
        angle = np.minimum(ease_envelope(angle), np.maximum(angle, 0.5 * np.pi - phi))
    axis = np.cross(heading, np.array([0., 1., 0.]))
    half = 0.5 * angle[:, None]
    swing = np.concatenate([axis * np.sin(half), np.cos(half)], -1)
    D = D.copy()
    for b in bones:
        D[:, b] = qnorm(qmul(swing, D[:, b]))
    return D, float(np.degrees(angle.max()))


def hinge_axis(D, chain, heads):
    """Elbow/knee hinge in the upper bone's frame, measured from the clip (bend-weighted mean)."""
    a, b, c = chain
    bend = np.cross(qrot(D[:, a], heads[b] - heads[a]), qrot(D[:, b], heads[c] - heads[b]))
    hinge = qrot(qinv(D[:, a]), bend).sum(0)
    return hinge / np.linalg.norm(hinge)


def signed_envelope(x, cap):
    """Eased version of a signed per-frame correction `x` (0 = none): |x| is widened/smoothed with ease_envelope, each
    eased run takes the sign of its strongest frame, and the result never exceeds `cap` (>= |x|, same sign as x)."""
    env = ease_envelope(np.abs(x))
    out = np.zeros_like(x)
    on = env > 1e-7
    t = 0
    while t < len(x):
        if not on[t]:
            t += 1
            continue
        s = t
        while t + 1 < len(x) and on[t + 1]:
            t += 1
        k = s + int(np.argmax(np.abs(x[s:t + 1])))
        sign = 1. if x[k] >= 0 else -1.
        out[s:t + 1] = sign * np.minimum(env[s:t + 1], np.where(np.sign(cap[s:t + 1]) == sign, np.abs(cap[s:t + 1]),
                                                                np.abs(x[s:t + 1])))
        t += 1
    return np.where(np.abs(x) > np.abs(out), x, out)


def hinge_lift(D, P, src, chain, floor, smooth):
    """Bend/unbend the elbow about its anatomical hinge (forearm + hand) so the glove centre clears `floor`.

    The hinge is fixed in the upper arm's frame, so the forearm never twists or bends sideways. Each frame takes the
    smallest flex change that lifts the glove onto `floor`, within ELBOW_FLEX; frames that can't get there take the
    highest reachable glove and leave the rest to the shoulder (see glove_floor)."""
    arm, fore, hand = chain
    heads = src.heads
    n = qrot(D[:, arm], np.broadcast_to(hinge_axis(D, chain, heads), (len(D), 3)))
    up = qrot(D[:, arm], heads[fore] - heads[arm])
    lo = qrot(D[:, fore], heads[hand] - heads[fore])
    theta = np.arctan2(np.sum(np.cross(up, lo) * n, -1), np.sum(up * lo, -1))   # signed flex about the hinge
    r = glove(D, P, src, hand) - P[:, fore]
    rn = np.sum(r * n, -1, keepdims=True) * n
    rp = r - rn
    c = P[:, fore, 1] + rn[:, 1]
    A, B = rp[:, 1], np.cross(n, rp)[:, 1]       # glove height after a flex change b: c + A cos b + B sin b
    M = np.maximum(np.hypot(A, B), 1e-9)
    psi = np.arctan2(B, A)                       # flex change giving the highest glove
    lo_b, hi_b = np.radians(ELBOW_FLEX[0]) - theta, np.radians(ELBOW_FLEX[1]) - theta

    def wrap(x):
        return (x + np.pi) % (2. * np.pi) - np.pi

    need = c + A < floor - 1e-6
    if not need.any():
        return D, 0.
    beta = np.zeros(len(D))
    best = np.clip(wrap(psi), lo_b, hi_b)
    alpha = np.arccos(np.clip((floor - c) / M, -1., 1.))
    reach = (floor - c) / M <= 1.
    for t in np.nonzero(need)[0]:
        ends = [e for e in (wrap(psi[t] - alpha[t]), wrap(psi[t] + alpha[t])) if lo_b[t] <= e <= hi_b[t]]
        beta[t] = min(ends, key=abs) if reach[t] and ends else best[t]
    if smooth:
        beta = np.clip(signed_envelope(beta, best), lo_b, hi_b)
    beta[np.abs(beta) < 1e-6] = 0.
    half = 0.5 * beta[:, None]
    rot = np.concatenate([n * np.sin(half), np.cos(half)], -1)
    D = D.copy()
    for b in (fore, hand):
        D[:, b] = qnorm(qmul(rot, D[:, b]))
    return D, float(np.degrees(np.abs(beta).max()))


def glove_floor(clip, src, smooth=True):
    """Keep Mack's big gloves and forearms on top of the mat.

    Mixamo's lying poses prop the skeleton on elbows/hands that sit under the floor once Mack's gloves are on. Each
    arm is fixed anatomically, so no bone twists:
    1. the whole arm swings about the shoulder (ball joint) until the elbow clears ELBOW_FLOOR;
    2. the elbow bends/unbends about its own hinge until the glove centre clears GLOVE_FLOOR;
    3. if the hinge alone can't get there, the whole arm swings about the shoulder for the rest.
    Poses that already satisfy the contact are untouched (apart from the short ease in/out around contacts when
    `smooth`); with smooth=False it is a hard clamp that leaves valid frames bit-identical."""
    D = clip.D()
    lifted = 0.
    for chain in ARMS:
        arm, fore, hand = chain
        for _ in range(4):     # a shoulder swing that lifts the glove can lower the elbow: repeat until both clear
            P = fk(D, clip.H, src.heads)
            lateral = P[:, arm] - P[:, SPINE2]
            outward = lateral / np.maximum(np.linalg.norm(lateral, axis=-1, keepdims=True), 1e-9)
            D, a = lift_above(D, P, arm, chain, P[:, fore], ELBOW_FLOOR, outward, smooth)
            P = fk(D, clip.H, src.heads)
            D, b = hinge_lift(D, P, src, chain, GLOVE_FLOOR, smooth)
            P = fk(D, clip.H, src.heads)
            D, c = lift_above(D, P, arm, chain, glove(D, P, src, hand), GLOVE_FLOOR, outward, smooth)
            lifted = max(lifted, a, b, c)
            if max(a, b, c) == 0.:
                break
    clip.L = to_local(D)
    if lifted > 0:
        clip.notes.append('elbows/gloves kept above the mat (max swing %.0f deg)' % lifted)


def procrustes_yaw(A, B):
    """Yaw angle + XZ translation mapping joint set B onto A (least squares on XZ): A ~ qyaw(angle)*B + t."""
    a, b = A[:, [0, 2]], B[:, [0, 2]]
    ca, cb = a.mean(0), b.mean(0)
    a0, b0 = a - ca, b - cb
    # qyaw(th): x' = x cos + z sin, z' = -x sin + z cos
    th = math.atan2(float(np.sum(a0[:, 0] * b0[:, 1] - a0[:, 1] * b0[:, 0])), float(np.sum(a0 * b0)))
    c, s = math.cos(th), math.sin(th)
    t = ca - np.array([cb[0] * c + cb[1] * s, -cb[0] * s + cb[1] * c])
    return th, t


def yaw_xz(th, xz):
    c, s = np.cos(th), np.sin(th)
    return np.stack([xz[..., 0] * c + xz[..., 1] * s, -xz[..., 0] * s + xz[..., 1] * c], -1)


# --------------------------------------------------------------------------- FBX sampling (Blender only)

class Source:
    """Rest skeleton (armature space, OBJ units) shared by every FBX."""

    def __init__(self, heads, aims, rest_q):
        self.heads, self.aims, self.rest_q = heads, aims, rest_q


def sample_fbx(path):
    import bpy
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.fbx(filepath=path)
    arm = [o for o in bpy.data.objects if o.type == 'ARMATURE'][0]
    scene = bpy.context.scene
    f0, f1 = (int(round(v)) for v in arm.animation_data.action.frame_range)
    fps = scene.render.fps / scene.render.fps_base
    bones = [arm.data.bones['mixamorig:' + n] for n in ORDER]
    pose = [arm.pose.bones['mixamorig:' + n] for n in ORDER]
    heads = np.array([b.head_local[:] for b in bones])
    aims = np.zeros((NB, 3))
    for b in range(NB):
        if b in CHILD:
            aims[b] = heads[CHILD[b]]
        elif b in END_BONE:
            aims[b] = arm.data.bones['mixamorig:' + END_BONE[b]].head_local[:]
        else:  # hands: Mixamo's synthetic tail = glove tip along the forearm
            aims[b] = bones[b].tail_local[:]
    rest = [b.matrix_local.to_quaternion() for b in bones]
    rest_q = np.array([(q.x, q.y, q.z, q.w) for q in rest])
    T = f1 - f0 + 1
    D = np.zeros((T, NB, 4))
    H = np.zeros((T, 3))
    for i, f in enumerate(range(f0, f1 + 1)):
        scene.frame_set(f)
        for b in range(NB):
            q = pose[b].matrix.to_quaternion() @ rest[b].inverted()
            D[i, b] = (q.x, q.y, q.z, q.w)
        H[i] = pose[0].head[:]
    return Source(heads, aims, rest_q), fps, make_continuous(qnorm(D)), H


# --------------------------------------------------------------------------- marker detection

def speed(P, fps):
    """Max joint speed (units/s) between frame t and t+1, length T (last repeats)."""
    v = np.linalg.norm(np.diff(P, axis=0), axis=-1).max(1) * fps
    return np.r_[v, v[-1:]]


def excursion(P, ref=0, joints=UPPER_BODY):
    """RMS displacement of upper-body joints (hips-relative) from frame `ref`."""
    rel = P[:, joints] - P[:, :1]
    return np.sqrt(np.mean(np.sum((rel - rel[ref]) ** 2, -1), -1))


def first(cond, default):
    idx = np.nonzero(cond)[0]
    return int(idx[0]) if len(idx) else default


def last(cond, default):
    idx = np.nonzero(cond)[0]
    return int(idx[-1]) if len(idx) else default


def punch_markers(clip, src, hand, axis, arc=False):
    """chamber = start of the fast drive run, contact = glove's peak reach after it, recovered = glove home.

    arc: chamber is instead the cocked frame where the glove's 3D speed bottoms out before the sweep (wind-up end)."""
    D = clip.D()
    P = fk(D, clip.H, src.heads)
    g = glove(D, P, src, hand)
    drive = g @ np.asarray(axis, dtype=float)
    v = np.diff(drive) * clip.fps  # v[k]: step k -> k+1
    peak = int(np.argmax(v))
    contact = peak + 1
    while contact + 1 < clip.T and drive[contact + 1] > drive[contact]:
        contact += 1
    chamber = peak
    if arc:
        s = np.linalg.norm(np.diff(g, axis=0), axis=-1)
        while chamber > 0 and s[chamber - 1] < s[chamber]:
            chamber -= 1
        chamber += 1
    while not arc and chamber > 0 and v[chamber - 1] >= 0.25 * v[peak]:
        chamber -= 1
    home = np.linalg.norm(g - g[0], axis=-1)
    root = np.linalg.norm((P[:, 0] - P[0, 0])[:, [0, 2]], axis=-1)
    recovered = first((np.arange(clip.T) > contact) & (home < 0.03) & (root < 0.03), clip.T - 1)
    return [('chamber', chamber), ('contact', contact), ('recovered', recovered)]


def hold_markers(clip, src, a, b, frac=0.85):
    P = clip.P(src)
    e = excursion(P)
    peak = int(np.argmax(e))
    on = e >= frac * e[peak]
    return [(a, first(on, peak)), (b, last(on, peak))], peak


def hit_markers(clip, src):
    P = clip.P(src)
    sp = speed(P[:, :6], clip.fps)
    e = excursion(P)
    impact = max(0, first(sp >= 0.35 * sp.max(), 0))
    peak = int(np.argmax(e))
    recovered = first((np.arange(clip.T) > peak) & (e < 0.15 * e[peak]), clip.T - 1)
    return [('impact', impact), ('recovered', recovered)]


# --------------------------------------------------------------------------- clip processing

def suppress_lead_jab(clip, src):
    """RightPunch is a 1-2: freeze the lead (left) arm in its guard so `cross` reads as a single rear straight."""
    D = clip.D()
    P = fk(D, clip.H, src.heads)
    rel = glove(D, P, src, L_HAND) - P[:, SPINE2]
    out = np.nonzero(np.linalg.norm(rel - rel[0], axis=-1) > 0.03)[0]
    contact = int(np.argmax(glove(D, P, src, R_HAND)[:, 2]))
    out = out[out < contact]
    if not len(out):
        return
    a, b = max(0, int(out[0]) - 2), min(clip.T - 1, int(out[-1]) + 3)
    s = smoother((np.arange(a, b + 1) - a) / float(b - a))
    for bone in LEFT_ARM_CHAIN:
        clip.L[a:b + 1, bone] = qslerp(np.repeat(clip.L[a:a + 1, bone], len(s), 0),
                                       np.repeat(clip.L[b:b + 1, bone], len(s), 0), s)
    clip.notes.append('lead-arm jab of the 1-2 replaced by a guard hold over frames %d-%d' % (a, b))


def off_hand_drift(D, P, src, guard, off):
    """Per-frame distance the off-hand glove has left its guard spot, measured in the chest (Spine2) frame.

    Frames where the glove is no farther from the head than at guard count as 0: when the torso turns into a cross
    the lead glove tucks in to the cheek, which moves it relative to the chest but is still a tight guard."""
    gD = to_global(guard[0][None])
    gP = fk(gD, guard[1][None], src.heads)

    def in_chest(D, P):
        return qrot(qinv(D[:, SPINE2]), glove(D, P, src, off) - P[:, SPINE2])

    def reach(D, P):
        return np.linalg.norm(glove(D, P, src, off) - P[:, HEAD], axis=-1)

    drift = np.linalg.norm(in_chest(D, P) - in_chest(gD, gP), axis=-1)
    return np.where(reach(D, P) > reach(gD, gP), drift, 0.)


def hold_off_hand(clip, src, guard, hand, arc=False):
    """Keep a punch's non-punching glove at the chin when the source lets it wander off (> OFF_HAND_DRIFT) or lifts
    it to within OFF_HAND_TOP of the top of the head.

    The off-hand chain's chest-relative locals are slerped onto the idle guard's with weight OFF_HAND_HOLD up to
    `contact`, easing back to the clip's own pose by `recovered` (arc punches: held through the wind-up up to
    `chamber`, released by `contact`, so the glove keeps the source's tuck to the cheek as the torso turns into the
    hook). Globals are re-derived from the locals, so the arm stays attached and continuous. Frames 0/T-1 are already
    the guard pose, so the clip still starts/ends on it."""
    off, chain = (R_HAND, RIGHT_ARM_CHAIN) if hand == L_HAND else (L_HAND, LEFT_ARM_CHAIN)

    def measure():
        D = clip.D()
        P = fk(D, clip.H, src.heads)
        top = P[:, HEAD] + qrot(D[:, HEAD], src.aims[HEAD] - src.heads[HEAD])
        return off_hand_drift(D, P, src, guard, off).max(), (glove(D, P, src, off)[:, 1] - top[:, 1]).max()

    drift, rise = measure()
    if drift <= OFF_HAND_DRIFT and rise <= -OFF_HAND_TOP:
        clip.notes.append('off-hand glove kept as authored (max drift from its guard %.3f, %.3f below the head top)'
                          % (drift, -rise))
        return
    m = dict(clip.markers)
    a, b = (m['chamber'], m['contact']) if arc else (m['contact'], m['recovered'])
    w = OFF_HAND_HOLD * (1. - ramp(clip.T, a, b))
    for bone in chain:
        clip.L[:, bone] = qslerp(clip.L[:, bone], np.broadcast_to(guard[0][bone], clip.L[:, bone].shape), w)
    drift2, rise2 = measure()
    clip.notes.append('off-hand arm held %.2f on its guard until frame %d, released by %d (max drift from its guard '
                      '%.3f -> %.3f, glove vs head top %+.3f -> %+.3f)' % (OFF_HAND_HOLD, a, b, drift, drift2, rise, rise2))


def damp_post_contact(clip):
    """After contact the hips may only drift a little further forward (+Z, toward the opponent): soft cap
    POST_CONTACT_DRIFT.

    Mixamo lunges keep carrying the body forward after the glove lands, which drives the attacker into the defender.
    Past contact c the forward offset x = hips_z - hips_z[c] is replaced by s*tanh(x/s) when positive (identity when
    the body is already settling back), so velocity is continuous at contact and the end pose is untouched."""
    c = dict(clip.markers)['contact']
    axis = np.array([0., 0., 1.])
    x = (clip.H[c:] - clip.H[c]) @ axis
    s = POST_CONTACT_DRIFT
    y = np.where(x > 0., s * np.tanh(np.maximum(x, 0.) / s), x)
    clip.H[c:] += (y - x)[:, None] * axis[None]
    clip.notes.append('hips forward drift after contact soft-capped (%.3f -> %.3f)' % (max(0., x.max()), max(0., y.max())))


def sole_heights(D, P, src, foot):
    """(T, len(SOLE)) heights of the boot-sole points of `foot` (16 left / 20 right); all 0 in the rest pose."""
    toe = CHILD[foot]
    sx = 1. if foot == 16 else -1.
    anchors = (src.heads[foot], src.heads[toe], src.aims[toe])
    out = []
    for k, dx, dz in SOLE:
        b = foot if k < 2 else toe
        pt = anchors[k] + np.array([dx * sx, -anchors[k][1], dz])
        out.append(P[:, b, 1] + qrot(D[:, b], pt - src.heads[b])[:, 1])
    return np.stack(out, 1)


def floor_feet(clip, src):
    """Lift any boot sole that dips below the floor (y < 0) back onto it with leg IK (ankle raised, foot orientation
    kept), so no clip pushes the feet through the mat. The lift is eased over a few frames (circularly for loops) and
    tapered off towards the first/last frame (loops: frame 0), so clips that start/end on the idle guard still do
    exactly; frames that sink themselves are always lifted fully."""
    D = clip.D()
    P = fk(D, clip.H, src.heads)
    worst = []
    for chain in LEGS:
        foot = chain[2]
        h = np.maximum(0., -sole_heights(D, P, src, foot).min(1))
        worst.append(float(h.max()))
        if h.max() < 1e-6:
            continue
        if clip.loops:
            r = 6
            env = ease_envelope(np.r_[h[-r:], h, h[:r]])[r:-r]
            env = env * np.minimum(ramp(clip.T, 0, 3), 1. - ramp(clip.T, clip.T - 3, clip.T))
        else:
            env = ease_envelope(h) * np.minimum(ramp(clip.T, 0, 3), 1. - ramp(clip.T, clip.T - 4, clip.T - 1))
        lift = np.maximum(h, env)
        target = P[:, foot] + lift[:, None] * np.array([0., 1., 0.])
        D = two_bone_ik(D, P, chain, target, src.heads, lift > 1e-7)
        P = fk(D, clip.H, src.heads)
    after = [float(np.maximum(0., -sole_heights(D, P, src, c[2]).min(1)).max()) for c in LEGS]
    if max(worst) > 1e-6:
        clip.L = to_local(D)
        clip.notes.append('boot soles kept on the floor (max sink L %.4f R %.4f -> %.4f %.4f)' % (*worst, *after))


def twist_angles(L, src, bone):
    """Signed twist (rad) of local rotations L[:, bone] about the bone's rest axis (swing-twist decomposition)."""
    a = src.aims[bone] - src.heads[bone]
    a = a / np.linalg.norm(a)
    return np.arctan2(L[:, bone, :3] @ a, L[:, bone, 3]) * 2.


def limit_twist(clip, src):
    """Soft-clamp limb twist (TWIST_LIMITS) so linear-blend skins don't candy-wrap.

    Each limited bone's local rotation q = swing * twist(a) has its twist about its rest axis `a` saturated smoothly
    (identity up to limit - margin, tanh-saturating to the limit); the removed twist is handed to the child bone
    (child local pre-multiplied by the same rotation about `a`), so the child's global rotation and every joint
    position stay exactly as they were: nothing moves, feet stay planted, only the twist is redistributed down the
    limb (arm -> forearm -> rigid glove; thigh -> shin -> boot). Per-frame and deterministic, so loops, guard ends and
    the knockdown -> getUp seam are preserved."""
    before, after = {}, {}
    for bone in sorted(TWIST_LIMITS):
        limit, margin = (math.radians(v) for v in TWIST_LIMITS[bone])
        tw = twist_angles(clip.L, src, bone)
        tw = (tw + np.pi) % (2. * np.pi) - np.pi
        knee = limit - margin
        mag = np.abs(tw)
        soft = np.where(mag > knee, knee + margin * np.tanh((mag - knee) / margin), mag)
        e = np.sign(tw) * (mag - soft)        # twist removed from this bone
        before[bone] = math.degrees(float(mag.max()))
        if np.abs(e).max() < 1e-7:
            after[bone] = before[bone]
            continue
        a = src.aims[bone] - src.heads[bone]
        a = a / np.linalg.norm(a)
        r = np.concatenate([a[None] * np.sin(0.5 * e)[:, None], np.cos(0.5 * e)[:, None]], -1)
        clip.L[:, bone] = qnorm(qmul(clip.L[:, bone], qinv(r)))
        child = CHILD[bone]
        clip.L[:, child] = qnorm(qmul(r, clip.L[:, child]))
        after[bone] = math.degrees(float(np.abs((twist_angles(clip.L, src, bone) + np.pi) % (2. * np.pi) - np.pi)
                                         .max()))
    changed = ['%s %.0f->%.0f' % (ORDER[b], before[b], after[b]) for b in sorted(before) if before[b] != after[b]]
    if changed:
        clip.notes.append('limb twist soft-limited (deg): ' + ', '.join(changed))


def close_loop(clip, src):
    """Mixamo loops repeat frame 0 at the end: drop it and spread any residual so last->first is seamless."""
    resid_L = qmul(clip.L[0], qinv(clip.L[-1]))
    resid_H = clip.H[0] - clip.H[-1]
    ang, dist = pose_distance(clip.L[0], clip.H[0], clip.L[-1], clip.H[-1], src)
    w = np.linspace(0., 1., clip.T)
    clip.L = qnorm(qmul(qpow(resid_L[None], w[:, None]), clip.L))
    clip.H = clip.H + w[:, None] * resid_H[None]
    clip.L, clip.H = clip.L[:-1].copy(), clip.H[:-1].copy()
    clip.loops = True
    clip.notes.append('loop closed (duplicate end frame dropped; residual %.2f deg / %.4f spread)' % (ang, dist))


def guard_match(clip, guard, start=None, end=None):
    """Steer the first/last frame onto the idle guard with additive offsets fading over the given windows.

    start: frame by which the start offset has faded out, or (hold, fade_end) to keep it fully on until `hold`."""
    gL, gH = guard
    if start is not None:
        a, b = start if isinstance(start, tuple) else (0, start)
        offset_blend(clip, 0, gL, gH, 1. - ramp(clip.T, a, b))
        clip.notes.append('start guard-matched (offset fades over frames %d-%d)' % (a, b))
    if end is not None:
        offset_blend(clip, clip.T - 1, gL, gH, ramp(clip.T, end, clip.T - 1))
        clip.notes.append('end guard-matched (offset fades in from frame %d)' % end)


def process(raw, src):
    clips = {}

    def get(name, fbx):
        fps, D, H = raw[fbx]
        return Clip(name, fps, to_local(D), H.copy())

    idle = get('idle', 'Idle')
    close_loop(idle, src)
    floor_feet(idle, src)
    guard = (idle.L[0].copy(), idle.H[0].copy())
    clips['idle'] = idle

    # Punches: start and end on the idle guard, untouched around contact, feet planted.
    for name, fbx, hand, axis, arc in PUNCHES:
        c = get(name, fbx)
        plants = [plant_intervals(c.P(src), c.fps, chain[2]) for chain in LEGS]
        if name in ALIGN_STANCE:
            align_stance(c, src, idle.P(src)[0])
        if name == 'cross':
            suppress_lead_jab(c, src)
        m = dict(punch_markers(c, src, hand, axis, arc))
        guard_match(c, guard, start=m['contact'], end=m['contact'])
        c.markers = punch_markers(c, src, hand, axis, arc)
        hold_off_hand(c, src, guard, hand, arc)
        damp_post_contact(c)
        pin_feet(c, src, plants)
        c.markers = punch_markers(c, src, hand, axis, arc)
        clips[name] = c

    block = get('block', 'Center Block')
    block.markers, _ = hold_markers(block, src, 'guardUp', 'holdEnd')
    clips['block'] = block

    # Body Block holds its cover only briefly mid-clip and dips the gloves below guard afterwards: keep the cover
    # (source frames BODY_BLOCK_KEEP) and steer both ends onto the idle guard.
    bb = get('bodyBlock', 'Body Block')
    bb.trim(*BODY_BLOCK_KEEP)
    m, _ = hold_markers(bb, src, 'guardUp', 'holdEnd', frac=0.8)
    guard_match(bb, guard, start=m[0][1], end=m[1][1])
    bb.markers, _ = hold_markers(bb, src, 'guardUp', 'holdEnd', frac=0.8)
    clips['bodyBlock'] = bb

    slip = get('slip', 'Left Block')
    (s0, s1), peak = hold_markers(slip, src, 'slipped', 'holdEnd')
    slip.markers = [('slipped', peak), s1]
    clips['slip'] = slip

    for name, fbx in (('hitHead', 'Head Hit'), ('hitBody', 'Kidney Hit'), ('hitSide', 'Side Hit')):
        c = get(name, fbx)
        impact = dict(hit_markers(c, src))['impact']
        if impact > 2:
            c.trim(impact - 2, c.T - 1)
            guard_match(c, guard, start=8)
        c.markers = hit_markers(c, src)
        clips[name] = c

    kd = get('knockdown', 'Falling Down')
    gu = get('getUp', 'Getting Up')
    knockdown_getup(kd, gu, src, guard)
    clips['knockdown'], clips['getUp'] = kd, gu

    vic = get('victory', 'Victory')
    vplants = [plant_intervals(vic.P(src), vic.fps, chain[2]) for chain in LEGS]
    P = vic.P(src)
    D = vic.D()
    top = P[:, HEAD, 1] + 0.05
    up = (glove(D, P, src, L_HAND)[:, 1] > top) & (glove(D, P, src, R_HAND)[:, 1] > top)
    a, b = first(up, 0), last(up, vic.T - 1)
    guard_match(vic, guard, start=a, end=b)
    pin_feet(vic, src, vplants, orient=False)
    vic.markers = [('armsUp', a), ('armsDown', b)]
    clips['victory'] = vic

    warm = get('warmup', 'WarmingUp')
    close_loop(warm, src)
    clips['warmup'] = warm
    for name, c in clips.items():
        if name != 'idle':
            floor_feet(c, src)
        limit_twist(c, src)
    return clips


def knockdown_getup(kd, gu, src, guard):
    """Knockdown and get-up are authored as one continuous, in-place-ending sequence.

    knockdown: starts on the idle guard, falls straight back (yaw-corrected, travel shortened, planted feet pinned)
    and ends in the same propped-up sitting pose that `getUp` starts from.
    getUp: frame 0 == knockdown's last frame (position + facing); while the body is off the mat its root is walked
    back (feet pinned) so it stands up over the rest hips XZ facing +Z, then it settles into the idle guard."""
    # ---- knockdown
    sp = speed(kd.P(src), kd.fps)
    react = max(0, first(sp > 0.3, 0) - 1)
    a = max(0, react - 3)
    kd.trim(a, kd.T - 1)
    react -= a
    plants = [plant_intervals(kd.P(src), kd.fps, chain[2]) for chain in LEGS]
    guard_match(kd, guard, start=(react, react + 12))
    H = kd.H
    ground = first(H[:, 1] <= H[:, 1].min() + 0.01, kd.T - 1)
    # Turn the fall so the final sprawl faces the way the get-up starts (Mixamo twists ~55 deg to the side):
    # the fall then goes straight back, away from the opponent at +Z.
    turn, _ = procrustes_yaw(gu.P(src)[0], kd.P(src)[-1])
    yaw = turn * ramp(kd.T, react + 2, ground + 14)
    scale = 0.6 + (0.25 - 0.6) * ramp(kd.T, ground - 2, ground + 2)
    step = yaw_xz(yaw[1:], np.diff(H[:, [0, 2]], axis=0)) * scale[1:, None]
    hxz = H[0, [0, 2]] + np.r_[np.zeros((1, 2)), np.cumsum(step, 0)]
    root_edit(kd, src, yaw, hxz, plants)
    glove_floor(kd, src)
    fall = kd.H[ground, [0, 2]] - kd.H[react, [0, 2]]
    kd.notes.append('fall turned %.0f deg (lands %.0f deg off straight back), hips travel x0.6 while falling / '
                    'x0.25 sliding on the mat, planted feet pinned with leg IK'
                    % (math.degrees(turn), math.degrees(math.atan2(-fall[0], -fall[1]))))
    torso = speed(kd.P(src)[:, :6], kd.fps)
    calm = np.array([torso[t:].max() < 0.25 * torso.max() for t in range(kd.T)])
    settled = first(calm & (np.arange(kd.T) > ground), kd.T - 1)
    kd.markers = [('react', react), ('ground', ground), ('settled', settled)]

    # ---- getUp
    sp = speed(gu.P(src), gu.fps)
    rise = max(0, first(sp > 0.3, 0) - 1)
    standing = first(gu.H[:, 1] >= 0.97 * gu.H[-1, 1], gu.T - 1)
    gu.trim(0, min(gu.T - 1, standing + 18))
    plants = [plant_intervals(gu.P(src), gu.fps, chain[2]) for chain in LEGS]
    P = gu.P(src)
    turn, shift = procrustes_yaw(kd.P(src)[-1], P[0])
    # Walk the root home only while the hips are off the mat, in proportion to how much the body is moving.
    energy = np.linalg.norm(np.diff(P, axis=0), axis=-1).sum(1) * smoother((P[1:, 0, 1] - 0.10) / 0.10)
    energy[standing:] = 0.
    energy = np.convolve(energy, np.ones(5) / 5., mode='same')
    w = np.r_[0., np.cumsum(energy)] / energy.sum()
    yaw = turn * (1. - w)
    H = gu.H
    start = yaw_xz(turn, H[0, [0, 2]]) + shift
    path = start + np.r_[np.zeros((1, 2)), np.cumsum(yaw_xz(yaw[1:], np.diff(H[:, [0, 2]], axis=0)), 0)]
    home = guard[1][[0, 2]] - path[-1]
    root_edit(gu, src, yaw, path + w[:, None] * home, plants)
    guard_match(gu, guard, end=standing)
    seam = pose_distance(kd.L[-1], kd.H[-1], gu.L[0], gu.H[0], src)
    glove_floor(gu, src)
    offset_blend(gu, 0, kd.L[-1], kd.H[-1], 1. - ramp(gu.T, 0, GETUP_SEAM_FADE))
    glove_floor(gu, src, smooth=False)
    gu.notes.append('aligned to the knockdown end (turn %.1f deg, residual %.0f deg / %.3f blended out over %d '
                    'frames); root walked home %.3f units while rising, planted feet pinned'
                    % (math.degrees(turn), seam[0], seam[1], GETUP_SEAM_FADE, float(np.linalg.norm(home))))
    gu.markers = [('rise', rise), ('standing', standing)]


# --------------------------------------------------------------------------- output

def write_hmc1(path, src, clips):
    out = [struct.pack('<4sIII', b'HMC1', NB, len(clips), 0)]
    for b in range(NB):
        out.append(struct.pack('<6f', *src.heads[b], *src.aims[b]))
    for c in clips:
        D = make_continuous(qnorm(c.D()))
        out.append(struct.pack('<24sfIII', c.name.encode('ascii'), c.fps, c.T,
                               LOOP_BIT if c.loops else 0, len(c.markers)))
        for name, frame in c.markers:
            out.append(struct.pack('<16sf', name.encode('ascii'), float(frame)))
        frames = np.concatenate([c.H, D.reshape(c.T, NB * 4)], 1).astype('<f4')
        out.append(frames.tobytes())
    data = b''.join(out)
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + '.tmp'
    with open(tmp, 'wb') as f:
        f.write(data)
    os.replace(tmp, path)
    return len(data)


def check_reference(src):
    with open(REFERENCE) as f:
        ref = {b['name']: b for b in json.load(f)['bones']}
    worst = 0.
    for b, name in enumerate(ORDER):
        r = ref[name]
        worst = max(worst, float(np.abs(np.array(r['head']) - src.heads[b]).max()))
    return worst


def main():
    argv = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--fbx-dir', default='~/Downloads')
    ap.add_argument('--out', default=os.path.join(ROOT, 'Haymaker', 'Models', 'fighter.clips'))
    ap.add_argument('--report', help='optional JSON with per-clip stats')
    args = ap.parse_args(argv)
    fbx_dir = os.path.expanduser(args.fbx_dir)

    raw, src = {}, None
    for _, fbx in CLIPS:
        s, fps, D, H = sample_fbx(os.path.join(fbx_dir, fbx + '.fbx'))
        if src is None:
            src = s
        elif np.abs(s.heads - src.heads).max() > 1e-5 or np.degrees(qangle(s.rest_q, src.rest_q)).max() > 0.1:
            raise SystemExit('%s.fbx has a different rest skeleton (re-download from the same Mixamo character)' % fbx)
        raw[fbx] = (fps, D, H)
        print('sampled %-14s %3d frames @ %g fps' % (fbx, len(D), fps))
    drift = check_reference(src)
    if drift > 1e-4:
        print('WARNING: FBX rest differs from %s by %.6f' % (REFERENCE, drift))

    clips = process(raw, src)
    ordered = [clips[name] for name, _ in CLIPS]
    size = write_hmc1(args.out, src, ordered)
    print('wrote %s (%d bytes, %d clips)' % (args.out, size, len(ordered)))
    for c in ordered:
        print('  %-10s %4.0f fps %4d frames %-5s %s' % (c.name, c.fps, c.T, 'loop' if c.loops else '',
                                                       ' '.join('%s=%g' % m for m in c.markers)))
    if args.report:
        rep = {c.name: dict(fps=c.fps, frames=c.T, loops=c.loops, markers=c.markers, notes=c.notes)
               for c in ordered}
        with open(args.report, 'w') as f:
            json.dump(rep, f, indent=1, sort_keys=True)


if __name__ == '__main__':
    main()
