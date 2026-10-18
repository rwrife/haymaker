# Offline fighter asset report

Generated deterministically by `python3 scripts/fighter_asset_report.py` from `Haymaker/Models/*.fighter` and `CharacterRoster.swift`.

| File | Bytes | Vertices | Triangles | Bones | Estimated GPU vertex + index buffer bytes | Roster mapping (character id) |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `atlas.fighter` | 1756724 | 21000 | 41371 | 16 | 2260452 | atlas |
| `bruiser.fighter` | 915044 | 10962 | 21421 | 16 | 1177860 | baxter |
| `cassian.fighter` | 1772924 | 21215 | 41646 | 16 | 2281812 | cassian |
| `duke.fighter` | 1805540 | 21581 | 42534 | 16 | 2323212 | duke |
| `goldie.fighter` | 874172 | 10418 | 20735 | 16 | 1123932 | goldie |
| `jaison.fighter` | 405440 | 4824 | 9644 | 16 | 520944 | jaison |
| `mack.fighter` | 924524 | 11057 | 21736 | 16 | 1189620 | mack (player) |
| `nico.fighter` | 905252 | 10864 | 21095 | 16 | 1165716 | nico |
| `sylvie.fighter` | 1755788 | 21038 | 41103 | 16 | 2260428 | sylvie |
| `vera.fighter` | 1817984 | 21821 | 42371 | 16 | 2341416 | vera |

HMR1 uses a 16-byte header, 16-byte bone records, 60-byte vertices (position, normal, RGB, four Float32 weights, four UInt16 bone indices), and UInt32 triangle indices; all fields are little endian. Every record is parsed and validated.

GPU estimates use `vertices × (60 + 16 + 8) + triangles × 3 × 4`: the interleaved vertex data plus the separate packed weight and bone-index sources created by the loader. These are buffer estimates, excluding CPU copies, driver allocation overhead, skeletons, materials and render targets; they are not measured GPU residency.

## Performance budget

- Total runtime fighter payload: **12933392 bytes** across 10 bundled rigs.
- Worst-case single-fighter payload: **1817984 bytes** (`vera.fighter`).
- A bout loads exactly two fighters: Mack (hero) and one rival. The rig verification harness (`scripts/verify_fighter_rigs.sh`) exercises all 10 rigs.
- On-device frame-time measurement is deferred to Apple hardware. No FPS or frame-time results are claimed by this offline report.
