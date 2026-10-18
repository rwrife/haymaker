#!/usr/bin/env python3
"""Print and regenerate the offline HMR1 manifest using only the standard library."""
import math
import re
import struct
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT/'ArtDirection'/'Models'/'asset-report.md'


def measure(path):
    data = path.read_bytes()
    if len(data) < 16:
        raise ValueError(f'{path.name}: truncated header')
    magic, vertices, indices, bones = struct.unpack_from('<4sIII', data)
    vertex_start = 16 + bones * 16
    index_start = vertex_start + vertices * 60
    if (magic != b'HMR1' or bones != 16 or not vertices or not indices
            or indices % 3 or len(data) != index_start + indices * 4):
        raise ValueError(f'{path.name}: invalid HMR1 layout')
    for i, (parent, *position) in enumerate(struct.iter_unpack('<i3f', data[16:vertex_start])):
        if not -1 <= parent < i or not all(map(math.isfinite, position)):
            raise ValueError(f'{path.name}: invalid bone {i}')
    for i, row in enumerate(struct.iter_unpack('<13f4H', data[vertex_start:index_start])):
        weights, bone_ids = row[9:13], row[13:]
        if (not all(map(math.isfinite, row[:13]))
                or any(not 0 <= weight <= 1 for weight in weights)
                or abs(sum(weights) - 1) >= 0.001
                or any(bone >= bones for bone in bone_ids)):
            raise ValueError(f'{path.name}: invalid vertex {i}')
    if any(index >= vertices for (index,) in struct.iter_unpack('<I', data[index_start:])):
        raise ValueError(f'{path.name}: out-of-range triangle index')
    # Runtime uses the 60-byte interleaved vertex buffer plus packed skinning
    # sources (16 bytes of weights + 8 bytes of bone indices per vertex).
    gpu_bytes = vertices * (60 + 16 + 8) + indices * 4
    return len(data), vertices, indices // 3, bones, gpu_bytes


def main():
    roster = (ROOT/'Packages'/'HaymakerKit'/'Sources'/'HaymakerKit'/'CharacterRoster.swift').read_text()
    pairs = re.findall(r'case "([^"]+)":\s*CharacterProfile\(asset: "([^"]+)"', roster)
    mapping = {'mack': ['mack (player)']}
    for character, asset in pairs:
        mapping.setdefault(asset, []).append(character)
    paths = sorted((ROOT/'Haymaker'/'Models').glob('*.fighter'))
    if not paths or set(mapping) - {path.stem for path in paths}:
        raise ValueError('Missing runtime fighter assets')
    rows = [(path, measure(path)) for path in paths]
    lines = [
        '# Offline fighter asset report',
        '',
        'Generated deterministically by `python3 scripts/fighter_asset_report.py` from '
        '`Haymaker/Models/*.fighter` and `CharacterRoster.swift`.',
        '',
        '| File | Bytes | Vertices | Triangles | Bones | Estimated GPU vertex + index buffer bytes | Roster mapping (character id) |',
        '| --- | ---: | ---: | ---: | ---: | ---: | --- |',
    ]
    for path, values in rows:
        lines.append(f'| `{path.name}` | ' + ' | '.join(map(str, values))
                     + ' | ' + ', '.join(sorted(mapping.get(path.stem, ['unmapped']))) + ' |')
    total = sum(values[0] for _, values in rows)
    worst_path, worst = max(rows, key=lambda row: row[1][0])
    lines += [
        '',
        'HMR1 uses a 16-byte header, 16-byte bone records, 60-byte vertices '
        '(position, normal, RGB, four Float32 weights, four UInt16 bone indices), '
        'and UInt32 triangle indices; all fields are little endian. Every record is parsed and validated.',
        '',
        'GPU estimates use `vertices × (60 + 16 + 8) + triangles × 3 × 4`: '
        'the interleaved vertex data plus the separate packed weight and bone-index '
        'sources created by the loader. These are buffer estimates, excluding '
        'CPU copies, driver allocation overhead, skeletons, materials and render targets; '
        'they are not measured GPU residency.',
        '',
        '## Performance budget',
        '',
        f'- Total runtime fighter payload: **{total} bytes** across {len(rows)} bundled rigs.',
        f'- Worst-case single-fighter payload: **{worst[0]} bytes** (`{worst_path.name}`).',
        '- A bout loads exactly two fighters: Mack (hero) and one rival. '
        f'The rig verification harness (`scripts/verify_fighter_rigs.sh`) exercises all {len(rows)} rigs.',
        '- On-device frame-time measurement is deferred to Apple hardware. '
        'No FPS or frame-time results are claimed by this offline report.',
        '',
    ]
    report = '\n'.join(lines)
    REPORT.write_text(report, encoding='utf-8')
    print(report, end='')


if __name__ == '__main__':
    main()
