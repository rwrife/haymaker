"""Recover a supplied FBX's corner UVs onto the existing OBJ vertex/face order.

Run with Blender --background --python scripts/blender/recover_fighter_texture.py --
--name bruiser --fbx <source.fbx> --basecolor <image.jpg>.
Requires identical geometry; it never transfers weights or changes the rig source.
"""
import argparse
import collections
import itertools
import json
import math
from pathlib import Path
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[2]


def recover(name, raw, basecolor, output):
    source = ROOT / 'ArtDirection' / 'Models' / f'{name}.obj'
    positions, polygons = [], []
    for line in source.read_text().splitlines():
        if line.startswith('v '):
            positions.append(tuple(map(float, line.split()[1:4])))
        elif line.startswith('f '):
            polygons.append([int(v.split('/')[0]) - 1 for v in line.split()[1:]])
    if len(positions) != len(raw['vertices']):
        raise ValueError('FBX vertex count differs from rig source')
    buckets = collections.defaultdict(list)
    for i, vertex in enumerate(positions):
        buckets[tuple(math.floor(c * 1e5) for c in vertex)].append(i)
    candidates_by_vertex, converted = {}, []
    for index, (x, y, z) in enumerate(raw['vertices']):
        vertex = (x, z, -y)  # Blender imported Z-up -> original Y-up
        converted.append(vertex)
        cell = tuple(math.floor(c * 1e5) for c in vertex)
        candidates = {j for delta in itertools.product((-1, 0, 1), repeat=3)
                      for j in buckets[tuple(c + d for c, d in zip(cell, delta))]
                      if math.dist(vertex, positions[j]) < 2e-6}
        if not candidates:
            raise ValueError(f'{name}: FBX vertex {index} has no match')
        candidates_by_vertex[index] = candidates

    def adjacency(faces):
        result = collections.defaultdict(set)
        for face in faces:
            for i, vertex in enumerate(face):
                result[vertex].update((face[i - 1], face[(i + 1) % len(face)]))
        return result

    original_edges = adjacency(polygons)
    imported_edges = adjacency([[row[0] for row in face] for face in raw['faces']])
    # Some exports contain coincident vertices. Resolve those through mesh
    # connectivity, never through arbitrary nearest-neighbor tie breaking.
    while True:
        changed = False
        claimed = {next(iter(c)) for c in candidates_by_vertex.values() if len(c) == 1}
        for vertex, candidates in candidates_by_vertex.items():
            if len(candidates) == 1:
                continue
            remaining = {j for j in candidates if j not in claimed
                         and len(original_edges[j]) == len(imported_edges[vertex])
                         and all(candidates_by_vertex[n] & original_edges[j] for n in imported_edges[vertex])}
            if not remaining:
                raise ValueError(f'{name}: connectivity mismatch at vertex {vertex}')
            if remaining != candidates:
                candidates_by_vertex[vertex] = remaining
                changed = True
        if not changed:
            break
    if any(len(c) != 1 for c in candidates_by_vertex.values()):
        raise ValueError(f'{name}: unresolved coincident vertices')
    mapping = {i: next(iter(c)) for i, c in candidates_by_vertex.items()}
    errors = [math.dist(converted[i], positions[j]) for i, j in mapping.items()]
    if len(set(mapping.values())) != len(positions):
        raise ValueError('Vertex match is not bijective')
    faces = {}
    for face in raw['faces']:
        key = tuple(sorted(mapping[row[0]] for row in face))
        if key in faces:
            raise ValueError('Duplicate FBX polygon')
        faces[key] = {mapping[row[0]]: row[1:] for row in face}
    if set(faces) != {tuple(sorted(p)) for p in polygons} or len(faces) != len(polygons):
        raise ValueError('FBX polygons differ from rig source')
    lines = ['# Supplied FBX UVs in original rig source vertex/face order.',
             f'mtllib {name}.mtl', f'usemtl {name}']
    lines += ['v ' + ' '.join(map(str, p)) for p in positions]
    offset, face_lines = 1, []
    for polygon in polygons:
        uv = faces[tuple(sorted(polygon))]
        for vertex in polygon:
            lines.append('vt ' + ' '.join(map(str, uv[vertex])))
        face_lines.append('f ' + ' '.join(f'{vertex + 1}/{offset + i}' for i, vertex in enumerate(polygon)))
        offset += len(polygon)
    lines += face_lines
    files = {f'{name}.obj': ('\n'.join(lines) + '\n').encode(),
             f'{name}.mtl': f'newmtl {name}\nmap_Kd {name}_basecolor.jpg\n'.encode(),
             f'{name}_basecolor.jpg': Path(basecolor).read_bytes()}
    with zipfile.ZipFile(output, 'w') as archive:
        for filename, data in files.items():
            info = zipfile.ZipInfo(filename, date_time=(2026, 10, 21, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, data)
    return dict(name=name, vertices=len(positions), polygons=len(polygons), max_position_error=max(errors))


def main():
    import bpy
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--name', required=True)
    parser.add_argument('--fbx', type=Path, required=True)
    parser.add_argument('--basecolor', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args(sys.argv[sys.argv.index('--') + 1:])
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.fbx(filepath=str(args.fbx))
    meshes = [o for o in bpy.data.objects if o.type == 'MESH']
    if len(meshes) != 1 or not meshes[0].data.uv_layers:
        raise ValueError('Expected one mesh with UVs')
    mesh = meshes[0].data
    raw = dict(vertices=[list(v.co) for v in mesh.vertices],
               faces=[[[mesh.loops[i].vertex_index, *mesh.uv_layers.active.data[i].uv]
                       for i in p.loop_indices] for p in mesh.polygons])
    print(json.dumps(recover(args.name, raw, args.basecolor,
                             args.output or ROOT / 'ArtDirection' / 'Models' / f'{args.name}.zip')))


if __name__ == '__main__':
    main()
