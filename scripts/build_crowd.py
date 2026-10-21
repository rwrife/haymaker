#!/usr/bin/env python3
"""Bake the Tripo3D crowd sources in ArtDirection/Crowd into runtime assets (issue #42).

    python3 scripts/build_crowd.py          # needs Pillow (texture downscale); everything else is stdlib

Inputs  ArtDirection/Crowd/crowd.json        bodies, looks and the four runtime clips
        ArtDirection/Crowd/source/<body>.glb  Tripo text-to-model -> rig (mixamo) -> retarget, one GLB per body
        ArtDirection/Crowd/source/<look>.jpg  re-textured looks (Tripo models/texture, same mesh and UVs);
                                              each body's own look uses the texture embedded in its GLB
Outputs Haymaker/Models/<body>.crowd          CRW1 skinned mesh + baked clips (format: ArtDirection/Crowd/README.md)
        Haymaker/Models/crowd-<look>.jpg      512 px runtime texture
"""
import io
import json
import math
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CROWD = ROOT / 'ArtDirection' / 'Crowd'
MODELS = ROOT / 'Haymaker' / 'Models'

# Runtime bone order: Root + the 22-bone Mixamo skeleton the fighters use.
BONES = ['Root', 'Hips', 'Spine', 'Spine1', 'Spine2', 'Neck', 'Head',
         'LeftShoulder', 'LeftArm', 'LeftForeArm', 'LeftHand',
         'RightShoulder', 'RightArm', 'RightForeArm', 'RightHand',
         'LeftUpLeg', 'LeftLeg', 'LeftFoot', 'LeftToeBase',
         'RightUpLeg', 'RightLeg', 'RightFoot', 'RightToeBase']
PARENT = [-1, 0, 1, 2, 3, 4, 5, 4, 7, 8, 9, 4, 11, 12, 13, 1, 15, 16, 17, 1, 19, 20, 21]
HIPS, SPINE = 1, 2
LOWER = {0, 1, 15, 16, 17, 18, 19, 20, 21, 22}   # kept from the seated clip in composites
TEXTURE_SIZE = 512


# ---- tiny quaternion / matrix kit (x, y, z, w); matrices are row-major 4x4 lists ----
def qmul(a, b):
    ax, ay, az, aw = a; bx, by, bz, bw = b
    return (aw*bx + ax*bw + ay*bz - az*by, aw*by - ax*bz + ay*bw + az*bx,
            aw*bz + ax*by - ay*bx + az*bw, aw*bw - ax*bx - ay*by - az*bz)


def qinv(q):
    return (-q[0], -q[1], -q[2], q[3])


def qnorm(q):
    n = math.sqrt(sum(c*c for c in q)) or 1
    return tuple(c/n for c in q)


def qrot(q, v):
    x, y, z, _ = qmul(qmul(q, (v[0], v[1], v[2], 0)), qinv(q))
    return (x, y, z)


def qslerp(a, b, t):
    d = sum(x*y for x, y in zip(a, b))
    if d < 0:
        b, d = tuple(-c for c in b), -d
    if d > 0.9995:
        return qnorm(tuple(x + (y - x)*t for x, y in zip(a, b)))
    th = math.acos(d); s = math.sin(th)
    return tuple(x*math.sin((1-t)*th)/s + y*math.sin(t*th)/s for x, y in zip(a, b))


def trs(t, q, s=(1, 1, 1)):
    x, y, z, w = q
    r = [[1-2*(y*y+z*z), 2*(x*y-z*w), 2*(x*z+y*w)],
         [2*(x*y+z*w), 1-2*(x*x+z*z), 2*(y*z-x*w)],
         [2*(x*z-y*w), 2*(y*z+x*w), 1-2*(x*x+y*y)]]
    return [[r[i][0]*s[0], r[i][1]*s[1], r[i][2]*s[2], t[i]] for i in range(3)] + [[0, 0, 0, 1]]


def mmul(a, b):
    return [[sum(a[i][k]*b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def mpoint(m, p):
    return tuple(m[i][0]*p[0] + m[i][1]*p[1] + m[i][2]*p[2] + m[i][3] for i in range(3))


def mdir(m, d):
    return tuple(m[i][0]*d[0] + m[i][1]*d[1] + m[i][2]*d[2] for i in range(3))


def minv_rigid(m):
    r = [[m[j][i] for j in range(3)] for i in range(3)]
    t = [-sum(r[i][k]*m[k][3] for k in range(3)) for i in range(3)]
    return [r[i] + [t[i]] for i in range(3)] + [[0, 0, 0, 1]]


# ---- GLB reading ----
class Glb:
    def __init__(self, data):
        assert data[:4] == b'glTF', 'not a GLB'
        jl, = struct.unpack_from('<I', data, 12)
        self.j = json.loads(data[20:20+jl])
        bl, = struct.unpack_from('<I', data, 20+jl)
        self.bin = data[28+jl:28+jl+bl]

    def view(self, index):
        v = self.j['bufferViews'][index]
        o = v.get('byteOffset', 0)
        return self.bin[o:o+v['byteLength']]

    def read(self, accessor):
        a = self.j['accessors'][accessor]
        n = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4, 'MAT4': 16}[a['type']]
        fmt = {5126: 'f', 5121: 'B', 5123: 'H', 5125: 'I'}[a['componentType']]
        v = self.j['bufferViews'][a['bufferView']]
        stride = v.get('byteStride') or n*struct.calcsize(fmt)
        base = v.get('byteOffset', 0) + a.get('byteOffset', 0)
        return [struct.unpack_from('<' + fmt*n, self.bin, base + i*stride) for i in range(a['count'])]

    def image(self):
        return self.view(self.j['images'][0]['bufferView'])


def bake_body(path):
    g = Glb(path.read_bytes())
    nodes = g.j['nodes']
    by_name = {n.get('name', '').removeprefix('mixamorig:'): i for i, n in enumerate(nodes)}
    order = [by_name[b] for b in BONES]
    skin = g.j['skins'][0]
    joint_slot = {node: slot for slot, node in enumerate(skin['joints'])}
    ibm_src = [list(m) for m in g.read(skin['inverseBindMatrices'])]
    for bone, node in enumerate(order):
        parent = PARENT[bone]
        assert parent < 0 or order[parent] in [i for i, n in enumerate(nodes) if node in n.get('children', [])], BONES[bone]
    rest_t = [tuple(nodes[n].get('translation', (0, 0, 0))) for n in order]
    rest_r = [qnorm(tuple(nodes[n].get('rotation', (0, 0, 0, 1)))) for n in order]
    glb_root_r, glb_root_t = rest_r[0], rest_t[0]
    rest_s = [tuple(nodes[n].get('scale', (1, 1, 1))) for n in order]
    assert all(abs(c - 1) < 1e-4 for s in rest_s for c in s), 'unexpected bone scale'
    mesh_node = next(n for n in nodes if 'mesh' in n)
    assert not any(k in mesh_node for k in ('translation', 'rotation', 'scale', 'matrix')), 'mesh node must be identity'

    # Clips: per bone sampled rotations, plus the hips translation.
    clips = {}
    for anim in g.j['animations']:
        tracks = {}
        frames = 0
        for ch in anim['channels']:
            node, path_ = ch['target']['node'], ch['target']['path']
            s = anim['samplers'][ch['sampler']]
            times = [t[0] for t in g.read(s['input'])]
            values = g.read(s['output'])
            tracks[(node, path_)] = (times, values, s.get('interpolation', 'LINEAR'))
            frames = max(frames, len(times))
        clips[anim['name']] = (tracks, frames)

    def sample(track, t):
        times, values, interp = track
        if t <= times[0] or len(times) == 1:
            return values[0]
        if t >= times[-1]:
            return values[-1]
        i = next(k for k in range(1, len(times)) if times[k] >= t)
        if interp == 'STEP':
            return values[i-1]
        u = (t - times[i-1]) / (times[i] - times[i-1])
        a, b = values[i-1], values[i]
        return qslerp(a, b, u) if len(a) == 4 else tuple(x + (y-x)*u for x, y in zip(a, b))

    def clip_frames(name):
        tracks, frames = clips[name]
        dur = max(max(tr[0]) for tr in tracks.values())
        fps = (frames - 1) / dur
        out = []
        for f in range(frames):
            t = f / fps
            rot = []
            for bone, node in enumerate(order):
                tr = tracks.get((node, 'rotation'))
                rot.append(qnorm(tuple(sample(tr, t))) if tr and bone else rest_r[bone])
            tr = tracks.get((order[HIPS], 'translation'))
            hips = tuple(sample(tr, t)) if tr else rest_t[HIPS]
            root_turn = tracks.get((order[0], 'rotation'))
            if root_turn:
                # Runtime Root is static: fold its animated turn into the hips (same Root translation).
                fold = qnorm(qmul(qinv(glb_root_r), qnorm(tuple(sample(root_turn, t)))))
                rot[HIPS] = qnorm(qmul(fold, rot[HIPS]))
                hips = qrot(fold, hips)
            out.append((rot, hips))
            for bone, node in enumerate(order):
                if bone == HIPS or (node, 'translation') not in tracks:
                    continue
                moved = max(abs(a - b) for a, b in zip(sample(tracks[(node, 'translation')], t),
                                                       glb_root_t if bone == 0 else rest_t[bone]))
                assert moved < 1e-3, f'{name}: {BONES[bone]} translates'
        return fps, out

    def globals_(rot, hips):
        g_ = []
        for bone in range(len(BONES)):
            local = trs(hips if bone == HIPS else rest_t[bone], rot[bone])
            g_.append(mmul(g_[PARENT[bone]], local) if PARENT[bone] >= 0 else local)
        return g_

    # Fighter frame: Y up, +Z forward (+X = anatomical left), feet on y = 0, rest hips over the origin.
    # Tripo rigs face +X, so turn them -90 degrees about Y.
    rest = globals_(rest_r, rest_t[HIPS])
    joint = lambda gm, b: tuple(gm[b][i][3] for i in range(3))  # noqa: E731
    up = [joint(rest, 6)[i] - joint(rest, HIPS)[i] for i in range(3)]
    fwd = [(joint(rest, 18)[i] + joint(rest, 22)[i] - joint(rest, 17)[i] - joint(rest, 21)[i]) / 2 for i in range(3)]
    left = [joint(rest, 8)[i] - joint(rest, 12)[i] for i in range(3)]
    assert up[1] > 0.8*math.hypot(*up), f'{path.name}: not Y-up {up}'
    assert fwd[0] > 0.7*math.hypot(*fwd), f'{path.name}: not facing +X {fwd}'
    assert left[2] < -0.7*math.hypot(*left), f'{path.name}: left arm not on -Z {left}'
    turn = (0, -math.sin(math.pi/4), 0, math.cos(math.pi/4))
    positions = g.read(g.j['meshes'][0]['primitives'][0]['attributes']['POSITION'])
    floor = min(p[1] for p in positions)
    hx, _, hz = qrot(turn, joint(rest, HIPS))
    correction = trs((-hx, -floor, -hz), turn)
    uncorrect = minv_rigid(correction)
    rest_t[0] = mpoint(correction, rest_t[0])
    rest_r[0] = qnorm(qmul(turn, rest_r[0]))

    prim = g.j['meshes'][0]['primitives'][0]
    attr = prim['attributes']
    normals = g.read(attr['NORMAL'])
    uvs = g.read(attr['TEXCOORD_0'])
    joints = g.read(attr['JOINTS_0'])
    weights = g.read(attr['WEIGHTS_0'])
    indices = [i[0] for i in g.read(prim['indices'])]
    slot_to_bone = {joint_slot[node]: bone for bone, node in enumerate(order) if node in joint_slot}
    ibm = [None]*len(BONES)
    for slot, node in enumerate(skin['joints']):
        m = ibm_src[slot]
        rows = [[m[c*4 + r] for c in range(4)] for r in range(4)]   # glTF is column-major
        ibm[slot_to_bone[slot]] = mmul(rows, uncorrect)
    for bone in range(len(BONES)):
        if ibm[bone] is None:   # unweighted bone: bind = rest
            ibm[bone] = minv_rigid(globals_(rest_r, rest_t[HIPS])[bone])
    vertices = []
    for p, n, uv, js, ws in zip(positions, normals, uvs, joints, weights):
        total = sum(ws) or 1
        vertices.append((mpoint(correction, p), mdir(correction, n), uv, tuple(w/total for w in ws),
                         tuple(slot_to_bone[j] for j in js)))

    def skinned(rot, hips):
        gm = globals_(rot, hips)
        skin_m = [mmul(gm[b], ibm[b]) for b in range(len(BONES))]
        out = []
        for p, _, _, ws, js in vertices:
            acc = [0.0, 0.0, 0.0]
            for w, j in zip(ws, js):
                if w:
                    q = mpoint(skin_m[j], p)
                    acc = [a + w*c for a, c in zip(acc, q)]
            out.append(acc)
        return out, gm

    # Bind pose must reproduce the corrected mesh.
    bind, _ = skinned(rest_r, rest_t[HIPS])
    err = max(math.dist(a, v[0]) for a, v in zip(bind, vertices))
    assert err < 1e-3, f'{path.name}: bind pose error {err}'
    height = max(v[0][1] for v in vertices)

    baked = {}
    for name in clips:
        baked[name] = clip_frames(name)
    return dict(rest_t=rest_t, rest_r=rest_r, ibm=ibm, vertices=vertices, indices=indices, height=height,
                clips=baked, skinned=skinned, globals=globals_, texture=g.image())


def composite(seated, upper):
    """Seated legs and hips from `seated`; spine and above from `upper`, keeping the
    upper body's orientation relative to the root so chests stay upright on a tilted pelvis."""
    fps_s, sit = seated
    fps_u, up = upper
    frames = max(1, round(len(up) * fps_s / fps_u))
    out = []
    for f in range(frames):
        srot, ships = sit[f % len(sit)]
        urot, _ = up[min(len(up) - 1, round(f * fps_u / fps_s))]
        rot = [srot[b] if b in LOWER else urot[b] for b in range(len(BONES))]
        rot[SPINE] = qnorm(qmul(qinv(srot[HIPS]), qmul(urot[HIPS], urot[SPINE])))
        out.append((rot, ships))
    return fps_s, out


def loopable(clip):
    """Smooth the loop seam (the last frames ease into frame 0) and keep every bone's
    quaternions on one hemisphere so the runtime's per-component interpolation never flips."""
    fps, frames = clip
    frames = [([tuple(q) for q in rot], tuple(hips)) for rot, hips in frames]
    n = min(10, len(frames) // 4)
    first_rot, first_hips = frames[0]
    for k in range(n):
        i = len(frames) - n + k
        w = (k + 1) / (n + 1)
        rot, hips = frames[i]
        frames[i] = ([qslerp(a, b, w) for a, b in zip(rot, first_rot)],
                     tuple(x + (y - x) * w for x, y in zip(hips, first_hips)))
    for i in range(1, len(frames)):
        prev = frames[i - 1][0]
        frames[i] = ([q if sum(a*b for a, b in zip(q, p)) >= 0 else tuple(-c for c in q) for q, p in zip(frames[i][0], prev)],
                     frames[i][1])
    return fps, frames


def pack(body, runtime_clips):
    v, idx = body['vertices'], body['indices']
    assert len(v) < 65535 and len(idx) % 3 == 0
    seat = body['seat']
    head = struct.pack('<4sIIIIff', b'CRW1', len(v), len(idx), len(BONES), len(runtime_clips), body['height'], seat)
    bones = b''
    for b in range(len(BONES)):
        m = body['ibm'][b]
        bones += struct.pack('<i3f4f', PARENT[b], *body['rest_t'][b], *body['rest_r'][b])
        bones += struct.pack('<16f', *[m[r][c] for c in range(4) for r in range(4)])   # column-major
    verts = b''.join(struct.pack('<3f3f2f4f4H', *p, *n, *uv, *w, *j) for p, n, uv, w, j in v)
    tris = struct.pack(f'<{len(idx)}H', *idx)
    tris += b'\0' * (-len(tris) % 4)
    clips = b''
    for name, (fps, frames) in runtime_clips.items():
        clips += struct.pack('<16sfI', name.encode(), fps, len(frames))
        clips += b''.join(struct.pack('<4f', *q) for rot, _ in frames for q in rot)
        clips += b''.join(struct.pack('<3f', *hips) for _, hips in frames)
    return head + bones + verts + tris + clips


def main():
    from PIL import Image   # offline tool dependency; CI only verifies the committed outputs
    spec = json.loads((CROWD / 'crowd.json').read_text())
    report = {}
    textures = {look: (CROWD / 'source' / f'{look}.jpg').read_bytes() for look in spec['tripo']['textures']}
    for name in spec['bodies']:
        body = bake_body(CROWD / 'source' / f'{name}.glb')
        clips = body['clips']
        seated = clips[spec['clips']['sit']]
        runtime = {'sit': seated,
                   'sit_clap': composite(seated, clips[spec['clips']['sit_clap']]),
                   'sit_yell': composite(seated, clips[spec['clips']['sit_yell']]),
                   'cheer': clips[spec['clips']['cheer']]}
        # Stand up in front of the bench: move the standing clip so its feet land where the seated feet rest.
        feet_z = lambda frame: sum(body['globals'](*frame)[b][2][3] for b in (17, 21)) / 2  # noqa: E731
        step = feet_z(seated[1][0]) - feet_z(runtime['cheer'][1][0])
        shift = qrot(qinv(body['rest_r'][0]), (0, 0, step))   # hips translation is in Root space
        fps, frames = runtime['cheer']
        runtime['cheer'] = (fps, [(rot, tuple(h + d for h, d in zip(hips, shift))) for rot, hips in frames])
        runtime = {k: loopable(v) for k, v in runtime.items()}
        # Bench height: the lowest seat point under the pelvis in the seated pose.
        rot, hips = seated[1][0]
        pts, gm = body['skinned'](rot, hips)
        pelvis = tuple(gm[HIPS][i][3] for i in range(3))
        feet = min(gm[b][1][3] for b in (17, 18, 21, 22))
        under = [p[1] for p in pts if abs(p[0] - pelvis[0]) < 0.08 and abs(p[2] - pelvis[2]) < 0.08 and p[1] < pelvis[1]]
        body['seat'] = min(under)
        report[name] = dict(height=round(body['height'], 4), seat=round(body['seat'], 4), seated_feet=round(feet, 4),
                            stand_step=round(step, 4),
                            seated_pelvis=[round(c, 3) for c in pelvis], vertices=len(body['vertices']),
                            triangles=len(body['indices']) // 3,
                            clips={k: dict(fps=round(f, 2), frames=len(fr), seconds=round((len(fr) - 1) / f, 2)) for k, (f, fr) in runtime.items()})
        (MODELS / f'{name}.crowd').write_bytes(pack(body, runtime))
        base = next(look for look, b in spec['looks'].items() if b == name and look not in textures)
        textures[base] = body['texture']
    for look in spec['looks']:
        img = Image.open(io.BytesIO(textures[look])).convert('RGB').resize((TEXTURE_SIZE, TEXTURE_SIZE), Image.LANCZOS)
        out = io.BytesIO()
        img.save(out, 'JPEG', quality=85, optimize=True)
        (MODELS / f'crowd-{look}.jpg').write_bytes(out.getvalue())
    print(json.dumps(report, indent=1))


if __name__ == '__main__':
    main()
