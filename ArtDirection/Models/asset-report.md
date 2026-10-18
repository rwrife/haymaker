# Offline fighter asset report

Generated deterministically by `python3 scripts/fighter_asset_report.py` from `Haymaker/Models/*.fighter` and `CharacterRoster.swift`.

| File | Bytes | Vertices | Triangles | Bones | Estimated GPU vertex + index buffer bytes | Roster mapping (character id) |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `atlas.fighter` | 1757084 | 21000 | 41371 | 22 | 2260452 | atlas |
| `bruiser.fighter` | 915404 | 10962 | 21421 | 22 | 1177860 | baxter |
| `cassian.fighter` | 1773284 | 21215 | 41646 | 22 | 2281812 | cassian |
| `duke.fighter` | 1805900 | 21581 | 42534 | 22 | 2323212 | duke |
| `goldie.fighter` | 874532 | 10418 | 20735 | 22 | 1123932 | goldie |
| `jaison.fighter` | 405800 | 4824 | 9644 | 22 | 520944 | jaison |
| `mack.fighter` | 924884 | 11057 | 21736 | 22 | 1189620 | mack (player) |
| `nico.fighter` | 905612 | 10864 | 21095 | 22 | 1165716 | nico |
| `sylvie.fighter` | 1756148 | 21038 | 41103 | 22 | 2260428 | sylvie |
| `vera.fighter` | 1818344 | 21821 | 42371 | 22 | 2341416 | vera |

HMR2 uses a 16-byte header, 22 28-byte bone records (parent index, joint head and aim point), 60-byte vertices (position, normal, RGB, four Float32 weights, four UInt16 bone indices), and UInt32 triangle indices; all fields are little endian. Every record is parsed and validated.

GPU estimates use `vertices × (60 + 16 + 8) + triangles × 3 × 4`: the interleaved vertex data plus the separate packed weight and bone-index sources created by the loader. These are buffer estimates, excluding CPU copies, driver allocation overhead, skeletons, materials and render targets; they are not measured GPU residency.

## Performance budget

- Total runtime fighter payload: **12936992 bytes** across 10 bundled rigs.
- Worst-case single-fighter payload: **1818344 bytes** (`vera.fighter`).
- A bout loads exactly two fighters: Mack (hero) and one rival. The rig verification harness (`scripts/verify_fighter_rigs.sh`) exercises all 10 rigs.
- On-device frame-time measurement is deferred to Apple hardware. No FPS or frame-time results are claimed by this offline report.
