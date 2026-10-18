"""Landmark-based joint fitting for the 22-bone Mixamo skeleton (numpy only, no bpy).

Mack is the calibration subject: Mixamo auto-rigged mack.obj, so its rest skeleton
(ArtDirection/Rigs/mixamo-reference-skeleton.json) defines where joints sit relative to
measurable mesh landmarks (armpit, glove cuff, glove tip, crotch, chin, boot sole/toe ...).
Every other sculpt measures the same landmarks and places joints at the same relative
positions, centred in the limb cross-sections. Legs and feet are fitted geometrically for
every character (Mixamo put Mack's knees/ankles on the inner surface of his A-stance legs),
and the foot/toe bones are aimed along the Mixamo source directions so the retarget
correction leaves soles flat on the floor.
"""
import numpy as np

from autorig_common import B, BONES, PARENTS, AIM_CHILD, load_obj, reference_skeleton, surface_samples, triangulate

SIDES = ((1, 'Left'), (-1, 'Right'))


class Sculpt:
    def __init__(self, name):
        self.name = name
        self.V, self.C, self.faces = load_obj(name)
        self.T = triangulate(self.faces)
        self.P, self.Q = surface_samples(self.V, self.C, self.T)
        self.h = float(self.V[:, 1].max())


def _box(P, mask):
    S = P[mask]
    if len(S) < 12:
        return None
    return np.percentile(S, 2, axis=0), np.percentile(S, 98, axis=0)


def landmarks(m):
    P, Q = m.P, m.Q
    x, y, z = P.T
    skin = np.median(Q[(np.abs(x) > 0.17) & (np.abs(x) < 0.26) & (y > 0.6)], 0)
    dist = np.linalg.norm(Q - skin, axis=1)
    L = {'h': m.h, 'top': m.h}
    L['crotch'] = float(y[(np.abs(x) < 0.004) & (y > 0.2) & (y < 0.7)].min())
    for s, side in SIDES:
        sx = s * x
        xs = np.arange(0.06, 0.30, 0.005)
        ymin = np.array([np.percentile(y[k], 1) if k.sum() > 20 else np.nan
                         for k in ((sx >= a) & (sx < a + 0.005) & (y > 0.6) & (y < 0.95) for a in xs)])
        bottom = np.nanmedian(ymin[(xs >= 0.18) & (xs <= 0.26)])
        ok = ymin > bottom - 0.025
        end = int(np.searchsorted(xs, 0.2))
        armpit = next(float(xs[i]) for i in range(end + 1) if ok[i:end + 1].all())
        arm = (sx > 0.2) & (y > 0.6)
        xs = np.arange(0.24, 0.5, 0.005)
        md = np.array([np.median(dist[k]) if k.sum() > 20 else np.nan
                       for k in (arm & (sx >= a) & (sx < a + 0.005) for a in xs)])
        cuff = next(float(xs[i]) for i in range(len(xs) - 2)
                    if md[i] > 0.12 and md[i + 1] > 0.1 and md[i + 2] > 0.1)
        if cuff <= xs[0]:
            # Noisy baked-texture skin (Jaison) trips the per-sample test on the bare forearm:
            # compare each slab's median colour with the mid-forearm colour instead.
            fore = np.median(m.Q[arm & (sx > 0.26) & (sx < 0.30)], 0)
            mc = np.array([np.linalg.norm(np.median(m.Q[k], 0) - fore) if k.sum() > 20 else np.nan
                           for k in (arm & (sx >= a) & (sx < a + 0.005) for a in xs)])
            cuff = next(float(xs[i]) for i in range(len(xs) - 2) if (mc[i:i + 3] > 0.2).all())
        tip = float(np.max(s * m.V[(s * m.V[:, 0] > 0.2) & (m.V[:, 1] > 0.6), 0]))
        foot = (sx > 0) & (y < 0.03)
        L[side] = dict(armpit=armpit, cuff=cuff, tip=tip, heel=float(z[foot].min()), toe=float(z[foot].max()))
    # Chin: the largest forward jump of the front silhouette above the shoulder line.
    ys = np.arange(0.70, 0.95, 0.005)
    front = np.array([np.percentile(z[k], 98) if k.sum() > 20 else np.nan
                      for k in ((np.abs(x) < 0.03) & (y >= a) & (y < a + 0.005) for a in ys)])
    L['front'] = (ys, front)
    return L


def _chin(L, shoulder_y):
    ys, front = L['front']
    ok = (ys > shoulder_y - 0.03) & (ys < shoulder_y + 0.12)
    idx = np.where(ok)[0]
    jumps = front[idx[1:]] - front[idx[:-1]]
    return float(ys[idx[1:]][int(np.nanargmax(jumps))])


def _line(m, s, x0, x1, fy, fz):
    """Robust y(x), z(x) line through slab points placed at fractions (fy, fz) of each arm cross-section."""
    sx = s * m.P[:, 0]
    arm = m.P[:, 1] > 0.6
    rows = []
    for a in np.arange(x0, x1 + 1e-9, 0.005):
        box = _box(m.P, arm & (sx >= a - 0.005) & (sx < a + 0.005))
        if box is None:
            continue
        lo, hi = box
        rows.append((a, lo[1] + fy * (hi[1] - lo[1]), lo[2] + fz * (hi[2] - lo[2])))
    rows = np.array(rows)
    fits = []
    for col in (1, 2):
        keep = np.ones(len(rows), bool)
        for _ in range(2):
            coef = np.polyfit(rows[keep, 0], rows[keep, col], 1)
            res = np.abs(np.polyval(coef, rows[:, 0]) - rows[:, col])
            keep = res <= max(2.5 * np.median(res[keep]), 0.002)
        fits.append(coef)
    return lambda xv: np.array([s * xv, np.polyval(fits[0], xv), np.polyval(fits[1], xv)])


def _fraction(m, mask, value, axis):
    lo, hi = _box(m.P, mask)
    return (value - lo[axis]) / (hi[axis] - lo[axis])


def _at_fraction(m, mask, frac, axis):
    lo, hi = _box(m.P, mask)
    return lo[axis] + frac * (hi[axis] - lo[axis])


def _ybox(m, y, extra):
    return (np.abs(m.P[:, 1] - y) < 0.005) & extra


def calibrate(mack, Lm):
    """Express the Mixamo reference joints of Mack relative to Mack's landmarks."""
    H, Tl, E = reference_skeleton()
    cal = {'h': Lm['h']}
    P = mack.P
    for s, side in SIDES:
        lm = Lm[side]
        arm, el, wr = H[B[side + 'Arm']], H[B[side + 'ForeArm']], H[B[side + 'Hand']]
        c = {'arm_dx': s * arm[0] - lm['armpit'],
             'elbow_r': (s * el[0] - s * arm[0]) / (lm['cuff'] - s * arm[0]),
             'wrist_k': (s * wr[0] - lm['cuff']) / (lm['tip'] - lm['cuff'])}
        sx = s * P[:, 0]
        for key, x0, x1 in (('up', s * arm[0] + 0.02, s * el[0] - 0.01), ('fo', s * el[0] + 0.01, lm['cuff'] - 0.008)):
            fy, fz = [], []
            for a in np.arange(x0, x1 + 1e-9, 0.005):
                mask = (P[:, 1] > 0.6) & (sx >= a - 0.005) & (sx < a + 0.005)
                fy.append(_fraction(mack, mask, arm[1], 1))
                fz.append(_fraction(mack, mask, arm[2], 2))
            c['fy_' + key], c['fz_' + key] = float(np.median(fy)), float(np.median(fz))
        cal[side] = c
    shoulder_y = 0.5 * (H[B['LeftArm'], 1] + H[B['RightArm'], 1])
    chin = _chin(Lm, shoulder_y)
    cal['chin'] = chin
    hip_y = 0.5 * (H[B['LeftUpLeg'], 1] + H[B['RightUpLeg'], 1])
    cal['crotch'] = Lm['crotch']
    cal['hip_dy'] = hip_y - Lm['crotch']
    cal['hips_dy'] = H[B['Hips'], 1] - hip_y
    cal['neck_r'] = (H[B['Neck'], 1] - shoulder_y) / (chin - shoulder_y)
    cal['spine_f'] = [(H[B[n], 1] - H[B['Hips'], 1]) / (H[B['Neck'], 1] - H[B['Hips'], 1]) for n in ('Spine', 'Spine1', 'Spine2')]
    torso = np.abs(P[:, 0]) < 0.05
    cal['axial_fz'] = {n: _fraction(mack, _ybox(mack, H[B[n], 1], torso), H[B[n], 2], 2)
                       for n in ('Hips', 'Spine', 'Spine1', 'Spine2', 'Neck')}
    cal['head_top_r'] = (E['Head'][1] - H[B['Head'], 1]) / (Lm['top'] - H[B['Head'], 1])
    cal['knee_r'] = (hip_y - H[B['LeftLeg'], 1]) / (hip_y - H[B['LeftFoot'], 1])
    cal['footlen'] = Lm['Left']['toe'] - Lm['Left']['heel']
    for n in ('UpLeg', 'Leg', 'Foot'):
        fz = []
        for s, side in SIDES:
            j = H[B[side + n]]
            fz.append(_fraction(mack, _ybox(mack, j[1], s * P[:, 0] > 0), j[2], 2))
        cal[n + '_fz'] = float(np.mean(fz))
    cal['upleg_probe'] = hip_y - 0.5  # thigh width is measured just below the hip joint (y=0.50 on Mack)
    return cal


def fit(m, L, cal, is_reference=False):
    """Return (heads[22,3], aims[22,3], notes) in OBJ units."""
    H, Tl, E = reference_skeleton()
    heads = np.zeros((22, 3))
    P = m.P
    sc = L['h'] / cal['h']
    lines = {}
    # Arms
    for s, side in SIDES:
        lm, c = L[side], cal[side]
        ax = lm['armpit'] + c['arm_dx'] * sc
        ex = ax + c['elbow_r'] * (lm['cuff'] - ax)
        wx = lm['cuff'] + c['wrist_k'] * (lm['tip'] - lm['cuff'])
        up = _line(m, s, ax + 0.02, ex - 0.01, c['fy_up'], c['fz_up'])
        fo = _line(m, s, ex + 0.01, lm['cuff'] - 0.008, c['fy_fo'], c['fz_fo'])
        heads[B[side + 'Arm']] = up(ax)
        heads[B[side + 'ForeArm']] = 0.5 * (up(ex) + fo(ex))
        heads[B[side + 'Hand']] = fo(wx)
        lines[side] = (fo, lm['tip'])
    shoulder_y = 0.5 * (heads[B['LeftArm'], 1] + heads[B['RightArm'], 1])
    chin = _chin(L, shoulder_y)
    # Axial chain
    leg_scale = L['crotch'] / cal['crotch']
    hip_y = L['crotch'] + cal['hip_dy'] * leg_scale
    hips = hip_y + cal['hips_dy'] * leg_scale
    neck = shoulder_y + cal['neck_r'] * (chin - shoulder_y)
    torso = np.abs(P[:, 0]) < 0.05
    for n, yv in [('Hips', hips)] + [(n, hips + f * (neck - hips)) for n, f in zip(('Spine', 'Spine1', 'Spine2'), cal['spine_f'])] + [('Neck', neck)]:
        heads[B[n]] = (0.0, yv, _at_fraction(m, _ybox(m, yv, torso), cal['axial_fz'][n], 2))
    heads[B['Head']] = heads[B['Neck']] + (H[B['Head']] - H[B['Neck']])
    # Clavicles hang off the chest at Mack's proportions.
    for s, side in SIDES:
        arm = heads[B[side + 'Arm']]
        heads[B[side + 'Shoulder']] = (arm[0] * H[B[side + 'Shoulder'], 0] / H[B[side + 'Arm'], 0],
                                       arm[1] + (H[B[side + 'Shoulder'], 1] - H[B[side + 'Arm'], 1]) * sc,
                                       heads[B['Neck'], 2] + H[B[side + 'Shoulder'], 2] - H[B['Neck'], 2])
    # Legs: geometric centres; the foot chain follows the Mixamo source directions.
    toes = {}
    for s, side in SIDES:
        lm = L[side]
        sf = (lm['toe'] - lm['heel']) / cal['footlen']
        half = s * P[:, 0] > 0
        uy = hip_y
        probe = _box(P, _ybox(m, uy - cal['upleg_probe'] * leg_scale, half))
        ux = 0.5 * (probe[0][0] + probe[1][0])
        heads[B[side + 'UpLeg']] = (ux, uy, _at_fraction(m, _ybox(m, uy, half), cal['UpLeg_fz'], 2))
        fy = H[B[side + 'Foot'], 1] * sf
        ky = uy - cal['knee_r'] * (uy - fy)
        for n, yv in (('Leg', ky), ('Foot', fy)):
            lo, hi = _box(P, _ybox(m, yv, half))
            heads[B[side + n]] = (0.5 * (lo[0] + hi[0]), yv, lo[2] + cal[n + '_fz'] * (hi[2] - lo[2]))
        ankle = heads[B[side + 'Foot']]
        dF = H[B[side + 'ToeBase']] - H[B[side + 'Foot']]
        dF /= np.linalg.norm(dF)
        tb = ankle + dF * (ankle[1] - H[B[side + 'ToeBase'], 1] * sf) / -dF[1]
        heads[B[side + 'ToeBase']] = tb
        dT = E[side + 'ToeBase'] - H[B[side + 'ToeBase']]
        dT /= np.linalg.norm(dT)
        toes[side] = tb + dT * (lm['toe'] - tb[2]) / dT[2]
    if is_reference:
        # Mack keeps Mixamo's own fit for everything except the knee/ankle/toe chain, which Mixamo
        # placed on the inner surface of his legs (x is re-centred; heights and depths are kept).
        fitted = heads.copy()
        heads = H.copy()
        for side in ('Left', 'Right'):
            for n in ('Leg', 'Foot'):
                heads[B[side + n], 0] = fitted[B[side + n], 0]
            heads[B[side + 'ToeBase']] = fitted[B[side + 'ToeBase']]
    aims = np.zeros((22, 3))
    for i, n in enumerate(BONES):
        if n in AIM_CHILD:
            aims[i] = heads[B[AIM_CHILD[n]]]
    head = heads[B['Head']]
    aims[B['Head']] = (head[0], head[1] + cal['head_top_r'] * (L['top'] - head[1]),
                       head[2] + (E['Head'][2] - H[B['Head'], 2]))
    for s, side in SIDES:
        fo, tip = lines[side]
        hand = heads[B[side + 'Hand']]
        fdir = hand - heads[B[side + 'ForeArm']]
        fdir /= np.linalg.norm(fdir)
        aims[B[side + 'Hand']] = hand + fdir * (tip - s * hand[0]) / (s * fdir[0])
        aims[B[side + 'ToeBase']] = toes[side]
    notes = dict(chin=chin, crotch=L['crotch'], leg_scale=leg_scale, shoulder_y=shoulder_y,
                 **{side + '_' + k: v for side in ('Left', 'Right') for k, v in L[side].items()})
    return heads, aims, notes
