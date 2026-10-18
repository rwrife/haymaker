"""Skin weights for the auto-rig (runs inside Blender: bpy, bmesh, mathutils, numpy).

1. Bone heat (ARMATURE_AUTO) on a watertight voxel-remeshed proxy of the sculpt (the raw Tripo
   meshes are non-manifold, so heat fails on them directly), transferred back to the sculpt by
   barycentric interpolation at the nearest proxy surface point.
2. Anatomical post-processing on the sculpt (autorig_regions.py): rigid gloves/boots/head,
   analytic elbow/knee/ankle bands, strict left/right leg separation, smoothing, top-4.
"""
import bpy
import numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree

from autorig_common import BONES


def reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def mesh_object(name, V, faces):
    me = bpy.data.meshes.new(name)
    me.from_pydata([tuple(map(float, v)) for v in V], [], faces)
    me.update()
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def _armature(segments):
    arm = bpy.data.armatures.new('heat')
    ob = bpy.data.objects.new('heat', arm)
    bpy.context.scene.collection.objects.link(ob)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.mode_set(mode='EDIT')
    for name, (h, t) in zip(BONES, segments):
        eb = arm.edit_bones.new(name)
        eb.head, eb.tail = Vector(h), Vector(t)
        eb.use_deform = True
    bpy.ops.object.mode_set(mode='OBJECT')
    return ob


def voxel_proxy(V, faces, voxel):
    import bmesh
    src = mesh_object('proxy', V, faces)
    # The Tripo sculpts have open boundaries (shorts hems, boot collars, mouth/eyes); close them so the
    # voxeliser sees a solid instead of leaking the interior to the outside.
    bm = bmesh.new()
    bm.from_mesh(src.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bmesh.ops.holes_fill(bm, edges=bm.edges, sides=0)
    bm.to_mesh(src.data)
    bm.free()
    mod = src.modifiers.new('remesh', 'REMESH')
    mod.mode = 'VOXEL'
    mod.voxel_size = voxel
    mod.adaptivity = 0.0
    mod.use_smooth_shade = False
    bpy.context.view_layer.objects.active = src
    src.select_set(True)
    bpy.ops.object.modifier_apply(modifier=mod.name)
    # Keep only the largest connected shell (voxel remesh can leave tiny floating islands).
    bm = bmesh.new()
    bm.from_mesh(src.data)
    bm.verts.ensure_lookup_table()
    seen, islands = set(), []
    for v in bm.verts:
        if v.index in seen:
            continue
        stack, island = [v], []
        seen.add(v.index)
        while stack:
            cur = stack.pop()
            island.append(cur)
            for e in cur.link_edges:
                o = e.other_vert(cur)
                if o.index not in seen:
                    seen.add(o.index)
                    stack.append(o)
        islands.append(island)
    islands.sort(key=len, reverse=True)
    for island in islands[1:]:
        bmesh.ops.delete(bm, geom=island, context='VERTS')
    bm.to_mesh(src.data)
    bm.free()
    src.data.update()
    return src, [len(i) for i in islands]


def heat_segments(heads, aims):
    """Bone segments used for bone heat. Mixamo's Neck bone is ~1 mm long (Neck and Head pivots coincide
    at the neck base), so for heating the neck segment runs from the neck base to 35 % up the head."""
    segments = [(np.asarray(h, float), np.asarray(a, float)) for h, a in zip(heads, aims)]
    neck, head = BONES.index('Neck'), BONES.index('Head')
    mid = segments[head][0] + 0.35 * (segments[head][1] - segments[head][0])
    segments[neck] = (segments[neck][0], mid)
    segments[head] = (mid, segments[head][1])
    return segments


def distance_weights(P, segments, power=4.0):
    """Fallback weights: inverse distance to each bone segment (only used where bone heat fails)."""
    W = np.zeros((len(P), len(segments)))
    for i, (a, b) in enumerate(segments):
        ab = b - a
        t = np.clip(((P - a) @ ab) / max(ab @ ab, 1e-12), 0, 1)
        d = np.linalg.norm(P - (a + t[:, None] * ab), axis=1)
        W[:, i] = 1.0 / np.maximum(d, 1e-4) ** power
    return W / W.sum(1, keepdims=True)


def heat_weights(proxy, segments):
    """Run Blender bone heat on the proxy; returns (proxy vertex array, weights [n,22], report).

    Blender does not report heat failures in background mode, so failure is detected numerically:
    vertices that received no weight get distance-falloff weights, and if heat produced an empty bone
    or left more than 2 % of the proxy unweighted the whole proxy falls back to distance weights."""
    arm = _armature(segments)
    bpy.ops.object.select_all(action='DESELECT')
    proxy.select_set(True)
    arm.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.parent_set(type='ARMATURE_AUTO')
    n = len(proxy.data.vertices)
    W = np.zeros((n, len(BONES)))
    gi = {g.index: BONES.index(g.name) for g in proxy.vertex_groups}
    for v in proxy.data.vertices:
        for g in v.groups:
            W[v.index, gi[g.group]] = g.weight
    P = np.array([v.co[:] for v in proxy.data.vertices])
    zero = W.sum(1) <= 1e-6
    empty = [BONES[i] for i in range(len(BONES)) if W[:, i].max() <= 1e-6]
    report = {'proxy_vertices': n, 'unweighted': int(zero.sum()), 'empty_bones': empty, 'fallback': 'none'}
    if empty or zero.mean() > 0.02:
        W = distance_weights(P, segments)
        report['fallback'] = 'all'
    elif zero.any():
        W[zero] = distance_weights(P[zero], segments)
        report['fallback'] = 'unweighted rows'
    return P, W, report


def transfer(proxy, Wp, V):
    """Barycentric interpolation of proxy weights at the nearest proxy surface point of each sculpt vertex."""
    me = proxy.data
    me.calc_loop_triangles()
    tris = np.array([t.vertices[:] for t in me.loop_triangles])
    Pp = np.array([v.co[:] for v in me.vertices])
    bvh = BVHTree.FromPolygons([tuple(p) for p in Pp], [tuple(t) for t in tris], all_triangles=True)
    out = np.zeros((len(V), Wp.shape[1]))
    dist = np.zeros(len(V))
    for i, p in enumerate(V):
        loc, _, idx, d = bvh.find_nearest(Vector(p))
        a, b, c = Pp[tris[idx]]
        # barycentric coordinates of loc in triangle abc
        v0, v1, v2 = b - a, c - a, np.array(loc) - a
        d00, d01, d11 = v0 @ v0, v0 @ v1, v1 @ v1
        d20, d21 = v2 @ v0, v2 @ v1
        den = d00 * d11 - d01 * d01
        if den <= 1e-20:
            bw = np.array([1.0, 0.0, 0.0])
        else:
            v_ = (d11 * d20 - d01 * d21) / den
            w_ = (d00 * d21 - d01 * d20) / den
            bw = np.clip(np.array([1 - v_ - w_, v_, w_]), 0, 1)
            bw /= bw.sum()
        out[i] = bw @ Wp[tris[idx]]
        dist[i] = d
    return out, dist
