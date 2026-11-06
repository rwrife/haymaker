#!/usr/bin/env python3
"""Bake base-colour texture samples into a vertex-coloured rig source OBJ.

Some supplied sculpts are textured exports without per-vertex colours. The auto-rig measures glove cuffs
and skin from vertex colours, so this writes `ArtDirection/Models/<name>.obj` with the export's exact
position tokens, vertex order and faces, plus each vertex's mean bilinear texture colour over its UV
corners. Normals and UVs are dropped; the unchanged export stays in `<name>.zip` for runtime UVs.

    python3 scripts/bake_obj_vertex_colors.py --name tycoon --obj export.obj --basecolor basecolor.jpg

Requires Pillow (offline tooling only; the runtime and CI need neither this script nor Pillow).
"""
import argparse
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def sample(pixels, width, height, u, v):
    """Bilinear RGB in 0..1 at OBJ UV (bottom-left origin), wrapping like a repeat sampler."""
    x = (u % 1.0) * width - 0.5
    y = (1.0 - v % 1.0) * height - 0.5
    x0, y0 = int(x // 1), int(y // 1)
    fx, fy = x - x0, y - y0
    out = [0.0, 0.0, 0.0]
    for dx, dy, w in ((0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)), (0, 1, (1 - fx) * fy), (1, 1, fx * fy)):
        px = pixels[(x0 + dx) % width, (y0 + dy) % height]
        for k in range(3):
            out[k] += w * px[k] / 255.0
    return out


def bake(obj_path, image_path):
    lines = Path(obj_path).read_text().splitlines()
    image = Image.open(image_path).convert('RGB')
    pixels, (width, height) = image.load(), image.size
    positions, uvs, faces = [], [], []
    for line in lines:
        parts = line.split()
        if not parts:
            continue
        if parts[0] == 'v':
            positions.append(parts[1:4])
        elif parts[0] == 'vt':
            uvs.append((float(parts[1]), float(parts[2])))
        elif parts[0] == 'f':
            faces.append([tuple(int(x) - 1 for x in t.split('/')[:2]) for t in parts[1:]])
    totals = [[0.0, 0.0, 0.0, 0] for _ in positions]
    for face in faces:
        for vertex, texcoord in face:
            rgb = sample(pixels, width, height, *uvs[texcoord])
            row = totals[vertex]
            for k in range(3):
                row[k] += rgb[k]
            row[3] += 1
    out = [f'# Vertex colours baked from {Path(image_path).name} by scripts/bake_obj_vertex_colors.py']
    for p, (r, g, b, n) in zip(positions, totals):
        n = n or 1
        out.append('v {} {} {} {:.4f} {:.4f} {:.4f}'.format(*p, r / n, g / n, b / n))
    for face in faces:
        out.append('f ' + ' '.join(str(v + 1) for v, _ in face))
    return '\n'.join(out) + '\n'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--name', required=True)
    parser.add_argument('--obj', type=Path, required=True, help='supplied textured OBJ export')
    parser.add_argument('--basecolor', type=Path, required=True, help='its base-colour image')
    parser.add_argument('--out', type=Path, default=ROOT / 'ArtDirection' / 'Models')
    args = parser.parse_args()
    (args.out / f'{args.name}.obj').write_text(bake(args.obj, args.basecolor), newline='\n')
