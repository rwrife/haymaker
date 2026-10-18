"""Anatomical post-processing of the bone-heat weights (numpy only, no bpy).

Heat weights are kept where they are good (torso gradient, shoulders, hips/trunks) and replaced by
analytic weights where the rig must be exact:

* arms   - Arm/ForeArm blend in a band around the elbow bisector plane; the whole glove (everything
           past the cuff plane) is rigidly RightHand/LeftHand, blending into ForeArm only on the bare
           wrist just before the cuff.
* legs   - UpLeg/Leg band at the knee, Leg/Foot band at the ankle, Foot/ToeBase band at the ball of
           the foot, so boots stay rigid apart from the ankle and toe creases.
* head   - rigid Head above a jaw plane within the head's width; the neck blends Neck->Head by height
           and the trapezius behind/beside it fades Head out with distance from the rigid head.
* sides  - no left-leg weight on the right half and vice versa; the trunks' crotch seam blends only
           with Hips.

All distances are scaled by the sculpt height so the same constants work for every boxer.
"""
import numpy as np

from autorig_common import B, BONES

# Band half-widths as fractions of sculpt height.
ELBOW_BAND = 0.024
WRIST_BAND = 0.028      # bare wrist skin before the glove cuff (ForeArm -> Hand)
KNEE_BAND = 0.030
ANKLE_BAND = (0.022, 0.012)  # above / below the ankle along the shin (boot heel stays rigid Foot)
BALL_BAND = 0.014
JAW_BAND = 0.014
CROTCH_BAND = 0.040     # |x| band at the crotch seam that blends only with Hips
SMOOTH_ITERS = 6
NECK_SMOOTH_ITERS = 16  # extra smoothing of the neck/trapezius zone after the head and shoulder gates
TRAP_FALLOFF = 0.07     # distance from the rigid head over which Head weight fades out on the traps
PRUNE = 0.01


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def unit(v):
    return v / np.linalg.norm(v)


def edges(faces):
    pairs = set()
    for f in faces:
        for i in range(len(f)):
            a, b = f[i], f[(i + 1) % len(f)]
            if a != b:
                pairs.add((min(a, b), max(a, b)))
    return np.array(sorted(pairs), dtype=np.int64)


def laplacian(W, E, iters, alpha=0.5, mobility=None):
    """Umbrella smoothing over mesh edges; `mobility` (0..1 per vertex) pins vertices where it is 0."""
    n = len(W)
    cnt = np.bincount(E[:, 0], minlength=n) + np.bincount(E[:, 1], minlength=n)
    has = cnt > 0
    for _ in range(iters):
        acc = np.zeros_like(W)
        np.add.at(acc, E[:, 0], W[E[:, 1]])
        np.add.at(acc, E[:, 1], W[E[:, 0]])
        avg = acc[has] / cnt[has, None]
        W = W.copy()
        a = alpha if mobility is None else alpha * mobility[has, None]
        W[has] = (1 - a) * W[has] + a * avg
    return W


def _move(W, rows, src, dst, amount=None):
    """Move weight of bones `src` on `rows` (bool mask) into bone `dst` (optionally only a fraction)."""
    for b in src:
        take = W[rows, b] if amount is None else W[rows, b] * amount[rows]
        W[rows, b] -= take
        W[rows, dst] += take


def _chain(V, joints, bands, normals=None):
    """Weights along a limb chain separated by joint planes; joints = [j0, j1, ..., tip].

    Each plane passes through an inner joint; its normal is the bisector of the adjacent bone directions
    unless overridden in `normals`. bands[k] = (lo, hi) signed-distance range of the blend.
    """
    w = np.ones((len(V), len(joints) - 1))
    frac = []
    for k in range(1, len(joints) - 1):
        n = (normals or {}).get(k)
        if n is None:
            n = unit(unit(joints[k] - joints[k - 1]) + unit(joints[k + 1] - joints[k]))
        lo, hi = bands[k - 1]
        frac.append(smoothstep(lo, hi, (V - joints[k]) @ n))
    for k, f in enumerate(frac):
        w[:, k] *= 1 - f
        w[:, k + 1:] *= f[:, None]
    return w


def regions(V, heads, aims, notes, h):
    """Signed distances / masks describing the anatomical regions (shared with the tests' logic)."""
    x, y = V[:, 0], V[:, 1]
    R = {}
    for s, S in ((1, 'Left'), (-1, 'Right')):
        el, wr = heads[B[S + 'ForeArm']], heads[B[S + 'Hand']]
        d_fore = unit(wr - el)
        cuff = el + d_fore * ((s * notes[S + '_cuff'] - el[0]) / d_fore[0])
        R[S + '_cuff_d'] = (V - cuff) @ d_fore
        R[S + '_cuff'] = cuff
        R[S + '_arm'] = s * x > heads[B[S + 'Arm'], 0] * s
    R['jaw_n'] = unit(np.array([0.0, 1.0, 0.25]))
    R['jaw_p'] = np.array([0.0, notes['chin'] - 0.004 * h, 0.0])
    R['jaw_d'] = (V - R['jaw_p']) @ R['jaw_n']
    # Lateral head gate from the head's own half-width at cheek/ear level (above the trapezius, which on
    # the heavier boxers rises past the chin); soft so the traps blend instead of tearing at the edge.
    cheek = (y > notes['chin'] + 0.035 * h) & (y < notes['chin'] + 0.07 * h)
    R['head_hw'] = float(np.abs(x[cheek]).max())
    R['head_col'] = smoothstep(R['head_hw'] + 0.03 * h, R['head_hw'] + 0.005 * h, np.abs(x))
    return R


def skin_weights(V, faces, heads, aims, heat, notes, h):
    n = len(V)
    x, y = V[:, 0], V[:, 1]
    E = edges(faces)
    W = heat / np.maximum(heat.sum(1, keepdims=True), 1e-12)
    W[heat.sum(1) <= 1e-12, B['Hips']] = 1.0
    W = laplacian(W, E, SMOOTH_ITERS)
    R = regions(V, heads, aims, notes, h)
    crotch = notes['crotch']

    legs = {S: [B[S + k] for k in ('UpLeg', 'Leg', 'Foot', 'ToeBase')] for S in ('Left', 'Right')}
    arms = {S: [B[S + k] for k in ('Shoulder', 'Arm', 'ForeArm', 'Hand')] for S in ('Left', 'Right')}

    # 1. Strict sides: a vertex never carries weight from the other side's limbs.
    _move(W, x < 0, legs['Left'], B['Hips'])
    _move(W, x > 0, legs['Right'], B['Hips'])
    _move(W, x < 0, arms['Left'], B['Spine2'])
    _move(W, x > 0, arms['Right'], B['Spine2'])

    for s, S in ((1, 'Left'), (-1, 'Right')):
        side = s * x > 0
        L = legs[S]
        # 2. Pelvis: UpLeg influence ramps in along the thigh axis from the hip joint to just below the
        #    crotch; the remainder is torso weight with everything below the Hips joint going to Hips, so
        #    the waistband never follows a lifted thigh and the trunks stretch smoothly over the buttock.
        up, kn = heads[L[0]], heads[L[1]]
        t = (V - up) @ unit(kn - up)
        u = smoothstep(-0.015 * h, (up[1] - crotch) + 0.02 * h, t)
        rows = side & (y > crotch - 0.1 * h) & (y < heads[B['Spine1'], 1])
        rest = W[rows].copy()
        rest[:, L] = 0.0
        low = 1 - smoothstep(heads[B['Hips'], 1] - 0.02 * h, heads[B['Hips'], 1] + 0.02 * h, y[rows])
        for b in (B['Spine'], B['Spine1'], B['Spine2']):
            rest[:, B['Hips']] += rest[:, b] * low
            rest[:, b] *= 1 - low
        tot = rest.sum(1)
        rest[tot <= 1e-9, B['Hips']] = 1.0
        rest /= rest.sum(1, keepdims=True)
        W[rows] = rest * (1 - u[rows])[:, None]
        W[rows, L[0]] = u[rows]

        # 3. Legs: analytic chain below the crotch, blended into the pelvis weights above it.
        joints = [heads[L[0]], heads[L[1]], heads[L[2]], heads[L[3]], aims[L[3]]]
        bands = [(-KNEE_BAND * h, KNEE_BAND * h), (-ANKLE_BAND[0] * h, ANKLE_BAND[1] * h), (-BALL_BAND * h, BALL_BAND * h)]
        # The ankle plane is perpendicular to the shin (not the shin/foot bisector) so the boot heel,
        # which sits just below and behind the ankle, is entirely Foot.
        chain = _chain(V, joints, bands, {2: unit(joints[2] - joints[1])})
        mix = smoothstep(crotch + 0.02 * h, crotch - 0.05 * h, y) * side
        A = np.zeros_like(W)
        A[:, L] = chain
        W = W * (1 - mix[:, None]) + A * mix[:, None]

        # 4. Arms: analytic Arm/ForeArm/Hand past the shoulder joint, glove rigid from the cuff.
        Ab = arms[S]
        el, wr = heads[Ab[2]], heads[Ab[3]]
        d_up, d_fore = unit(el - heads[Ab[1]]), unit(wr - el)
        ne = unit(d_up + d_fore)
        w_fore = smoothstep(-ELBOW_BAND * h, ELBOW_BAND * h, (V - el) @ ne)
        w_hand = smoothstep(-WRIST_BAND * h, 0.0, R[S + '_cuff_d'])
        A = np.zeros_like(W)
        A[:, Ab[1]] = 1 - w_fore
        A[:, Ab[2]] = w_fore * (1 - w_hand)
        A[:, Ab[3]] = w_fore * w_hand
        # Ramp from heat (Spine2/Shoulder/Arm around the deltoid) to analytic past the shoulder joint;
        # the height gate keeps wide feet/trunks (|x| beyond the shoulder on bulky boxers) out of the arm.
        sx, sy = heads[Ab[1], 0] * s, heads[Ab[1], 1]
        mix = smoothstep(sx, sx + 0.05 * h, s * x) * smoothstep(sy - 0.14 * h, sy - 0.10 * h, y)
        W = W * (1 - mix[:, None]) + A * mix[:, None]

        # 5. Crotch seam: legs fade into Hips within CROTCH_BAND of the mid-plane near the crotch.
        fade = (1 - smoothstep(0.0, CROTCH_BAND * h, s * x)) * smoothstep(crotch - 0.06 * h, crotch, y)
        _move(W, side, L, B['Hips'], fade)

    # 6. Shoulder (clavicle) bones stay off the neck, sternum and spine: the Mixamo Shoulder head sits at
    #    the neck base, so heat bleeds it onto the neck, which then collapses when both arms go up.
    base_y, sp2_y = heads[B['Neck'], 1], heads[B['Spine2'], 1]
    upper = smoothstep(sp2_y - 0.03 * h, sp2_y, y)
    to_neck = smoothstep(base_y - 0.01 * h, base_y + 0.02 * h, y)
    for s, S in ((1, 'Left'), (-1, 'Right')):
        sh_x = heads[B[S + 'Shoulder'], 0] * s
        lat = smoothstep(sh_x, sh_x + 0.04 * h, s * x)
        high = smoothstep(base_y + 0.015 * h, base_y + 0.045 * h, y) * (1 - smoothstep(sh_x + 0.04 * h, sh_x + 0.08 * h, s * x))
        cut = upper * (1 - lat * (1 - high))
        side = s * x > 0
        b = B[S + 'Shoulder']
        take = W[:, b] * cut * side
        W[:, b] -= take
        W[:, B['Neck']] += take * to_neck
        W[:, B['Spine2']] += take * (1 - to_neck)

    # 7. Neck: inside the neck cylinder spread each vertex's Neck+Head weight by height between the
    #    neck base and the jaw, so head turns twist the whole neck instead of shearing one ring of
    #    edges. Hair hanging behind the neck (outside the cylinder) keeps its heat weights.
    neck_len = max(notes['chin'] - base_y, 0.02 * h)
    zc = heads[B['Neck'], 2]
    r = np.hypot(x, V[:, 2] - zc)
    inside = smoothstep(0.075 * h, 0.06 * h, r) * (R['jaw_d'] < 0) * (y > base_y - 0.02 * h)
    nh = W[:, B['Neck']] + W[:, B['Head']]
    share = smoothstep(-neck_len, 0.0, R['jaw_d'])
    W[:, B['Head']] = W[:, B['Head']] * (1 - inside) + nh * share * inside
    W[:, B['Neck']] = W[:, B['Neck']] * (1 - inside) + nh * (1 - share) * inside

    # 8. Head: rigid above the jaw plane (head column only, so raised gloves are never caught).
    w_head = smoothstep(-JAW_BAND * h, 0.0, R['jaw_d']) * R['head_col']
    A = np.zeros_like(W)
    A[:, B['Head']] = 1.0
    W = W * (1 - w_head[:, None]) + A * w_head[:, None]

    zone = smoothstep(sp2_y - 0.02 * h, sp2_y + 0.01 * h, y)
    for s, S in ((1, 'Left'), (-1, 'Right')):
        zone = zone * (1 - (s * x > heads[B[S + 'Arm'], 0] * s) * smoothstep(0.0, 0.02 * h, s * x - heads[B[S + 'Arm'], 0] * s))

    # 9. Trapezius: beside the head (outside the neck cylinder) Head weight falls off smoothly with the
    #    distance from the rigid head over TRAP_FALLOFF, replacing heat's narrow band. On the neckless
    #    boxers the traps meet the head below the ears, and a narrow band folds into a ridge when a hit
    #    reaction tilts the head ~50 degrees. Back half only: in front the clavicles already carry
    #    Shoulder/Arm weight, and adding Head there would exceed four influences.
    rigid = w_head >= 0.999
    behind = smoothstep(zc + 0.06 * h, zc + 0.02 * h, V[:, 2])
    lateral = smoothstep(R['head_hw'] - 0.01 * h, R['head_hw'] + 0.01 * h, np.abs(x)) * (1 - inside) * zone * behind
    cand = np.nonzero((lateral > 0) & ~rigid)[0]
    if len(cand) and rigid.any():
        d = _nearest(V[cand], V[rigid])
        hs = smoothstep(TRAP_FALLOFF * h, 0.0, d)
        rest = W[cand].copy()
        rest[:, B['Head']] = 0.0
        tot = rest.sum(1)
        rest[tot <= 1e-9, B['Neck']] = 1.0
        rest /= rest.sum(1, keepdims=True)
        target = rest * (1 - hs)[:, None]
        target[:, B['Head']] = hs
        a = lateral[cand][:, None]
        W[cand] = W[cand] * (1 - a) + target * a

    # 10. Neck/trapezius smoothing: the gates above leave steep Head/Neck/Shoulder gradients where the
    #     heavier boxers' traps rise to the ears; diffuse them (rigid head interior and arms pinned).
    W = laplacian(W, E, NECK_SMOOTH_ITERS, mobility=zone * (w_head < 0.999))
    _move(W, x < 0, arms['Left'], B['Spine2'])
    _move(W, x > 0, arms['Right'], B['Spine2'])
    return finalize(W)


def _nearest(P, Q, chunk=512):
    """Distance from each point of P to its nearest point of Q (brute force, chunked)."""
    q2 = (Q * Q).sum(1)
    out = np.empty(len(P))
    for i in range(0, len(P), chunk):
        p = P[i:i + chunk]
        d2 = (p * p).sum(1)[:, None] + q2[None, :] - 2.0 * p @ Q.T
        out[i:i + chunk] = np.sqrt(np.maximum(d2.min(1), 0.0))
    return out


def finalize(W):
    """Top-4, prune tiny weights, renormalise. Returns (ids[n,4], weights[n,4]) with zero lanes unused."""
    order = np.argsort(-W, axis=1, kind='stable')[:, :4]
    w = np.take_along_axis(W, order, 1)
    w[w < PRUNE] = 0.0
    w /= w.sum(1, keepdims=True)
    ids = np.where(w > 0, order, 0)
    return ids, w


def dense(ids, w, nb=len(BONES)):
    W = np.zeros((len(ids), nb))
    np.add.at(W, (np.repeat(np.arange(len(ids)), 4), ids.ravel()), w.ravel())
    return W
