"""Headless Blender auto-rig for the boxer sculpts -> ArtDirection/Rigs/<name>.skin (+ <name>.joints.json).

Run from the repo root (Blender 5.x; its bundled Python provides numpy/mathutils/bmesh):

    /Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \\
        --python scripts/blender/autorig.py -- [mack bruiser ...] [--out ArtDirection/Rigs] [--fbx-dir ~/Downloads]

then pack the runtime assets with `python3 scripts/rig_fighters.py` (no Blender needed).

Pipeline per character (see ArtDirection/Rigs/README.md):
1. Joint fit (autorig_joints.py): Mack uses Mixamo's own fit (mixamo-reference-skeleton.json, legs re-centred
   in the limb cross-sections); everyone else is placed from measured mesh landmarks calibrated on Mack.
2. Bone heat on a watertight voxel proxy of the sculpt, transferred back by barycentric interpolation
   (autorig_weights.py). Heat failure is detected numerically and falls back to distance weights.
3. Anatomical post-processing (autorig_regions.py): rigid gloves/boots/head, analytic elbow/knee/ankle
   bands, strict left/right separation, pelvis/shoulder/neck fixes, smoothing, top-4.
4. HMS1 sidecar with joints (OBJ units) and quantized weights in OBJ vertex order.

--fbx-dir is optional: when <fbx-dir>/Idle.fbx exists the reference skeleton JSON is checked against the
Mixamo rest pose in it (FBX files are never copied into the repo).
"""
import argparse
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import numpy as np  # noqa: E402

from autorig_common import BONES, NAMES, PARENTS, RIGS, ROOT, quantize, reference_skeleton, write_skin  # noqa: E402
from autorig_joints import Sculpt, calibrate, fit, landmarks  # noqa: E402
import autorig_regions  # noqa: E402
import autorig_weights  # noqa: E402

VOXEL = 0.006  # voxel proxy resolution as a fraction of the sculpt height


def check_reference(fbx_dir):
    import bpy
    path = Path(fbx_dir).expanduser() / 'Idle.fbx'
    if not path.exists():
        print(f'reference check skipped ({path} not found)')
        return
    autorig_weights.reset_scene()
    bpy.ops.import_scene.fbx(filepath=str(path))
    arm = next(o for o in bpy.data.objects if o.type == 'ARMATURE')
    heads, _, _ = reference_skeleton()
    err = max(np.linalg.norm(np.array(arm.data.bones['mixamorig:' + b].head_local) - heads[i])
              for i, b in enumerate(BONES))
    print(f'reference check: max |FBX rest - mixamo-reference-skeleton.json| = {err:.2e}')
    if err > 1e-4:
        raise SystemExit('mixamo-reference-skeleton.json does not match the Mixamo rest pose in ' + str(path))


def joints_doc(name, heads, aims, notes, report):
    plain = {k: (round(float(v), 6) if isinstance(v, (float, np.floating)) else v) for k, v in notes.items()}
    return {
        'description': f'{name}: fitted 22-bone Mixamo skeleton in OBJ units (Y-up, +Z front, +X = anatomical left). '
                       'aim = head of the canonical child (leaves: head top, glove tip, toe tip). '
                       'Informational dump; the packer reads the .skin sidecar.',
        'notes': plain,
        'heat': report,
        'bones': [{'name': b, 'parent': PARENTS[i], 'head': [round(float(v), 6) for v in heads[i]],
                   'aim': [round(float(v), 6) for v in aims[i]]} for i, b in enumerate(BONES)],
    }


def rig(name, mack, cal, out):
    t0 = time.time()
    m = mack if name == 'mack' else Sculpt(name)
    heads, aims, notes = fit(m, landmarks(m), cal, is_reference=(name == 'mack'))
    V, faces, h = m.V, m.faces, m.h

    autorig_weights.reset_scene()
    proxy, islands = autorig_weights.voxel_proxy(V, faces, VOXEL * h)
    segments = autorig_weights.heat_segments(heads, aims)
    _, Wp, report = autorig_weights.heat_weights(proxy, segments)
    heat, dist = autorig_weights.transfer(proxy, Wp, V)
    report.update(proxy_islands=len(islands), transfer_p99=round(float(np.percentile(dist, 99)), 5))

    ids, w = autorig_regions.skin_weights(V, faces, heads, aims, heat, notes, h)
    if name == 'hunter':
        # Hunter's narrow jaw leaves a few face vertices outside the generic jaw
        # plane. Keep the central face/cranium rigid, matching the asset contract.
        head, top = heads[5], aims[5]
        length = top[1] - head[1]
        core = (np.abs(V[:, 0]) < 0.4 * length) & ((V[:, 1] > head[1] + 0.6 * length) |
                ((V[:, 1] > head[1] + 0.4 * length) & (V[:, 2] > head[2])))
        ids[core] = (5, 0, 0, 0)
        w[core] = (1, 0, 0, 0)
    bone_ids, weights = quantize(ids, w)
    write_skin(out / f'{name}.skin', heads, aims, bone_ids, weights)
    (out / f'{name}.joints.json').write_text(json.dumps(joints_doc(name, heads, aims, notes, report), indent=1) + '\n')
    lanes = np.bincount((weights > 0).sum(1), minlength=5)[1:].tolist()
    print(json.dumps({'name': name, 'vertices': len(V), 'heat': report, 'influences_1_to_4': lanes,
                      'seconds': round(time.time() - t0, 1)}), flush=True)


def main(argv):
    parser = argparse.ArgumentParser(description='Fit joints and skin weights; writes HMS1 sidecars.')
    parser.add_argument('names', nargs='*', help='characters to rig (default: all)')
    parser.add_argument('--out', type=Path, default=RIGS)
    parser.add_argument('--fbx-dir', default=os.path.expanduser('~/Downloads'))
    args = parser.parse_args(argv)
    unknown = sorted(set(args.names) - set(NAMES))
    if unknown:
        parser.error(f'unknown character(s) {unknown}; expected some of {list(NAMES)}')
    out = args.out if args.out.is_absolute() else ROOT / args.out
    out.mkdir(parents=True, exist_ok=True)
    check_reference(args.fbx_dir)
    mack = Sculpt('mack')
    cal = calibrate(mack, landmarks(mack))
    for name in args.names or NAMES:
        rig(name, mack, cal, out)


if __name__ == '__main__':
    main(sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else [])
