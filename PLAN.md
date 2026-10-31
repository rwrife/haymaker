# Haymaker — PLAN

## Scope

Haymaker is a single-player, offline, boss-rush arcade boxing game built only in Godot 4.7.2. Windows and Android exports exist; iPhone and iPad will use Godot's iOS export from the same project. There is no separately maintained native game.

The game has a ten-opponent career ladder, endless sparring, local records, one-thumb and two-handed controls, deterministic seeded fights and zero runtime network. Backup/export and iOS distribution remain planned work.

Out of scope: accounts, cloud save, multiplayer, ads/IAP/loot, licensed or trademarked boxers and franchise assets, betting, fitness/medical claims, video capture, camera/microphone access.

## Architecture

```text
godot/
├── project.godot             single game project for all platforms
├── scenes/main.tscn          application entry scene
├── scripts/engine/           authoritative deterministic match simulation
│   ├── opponent_book.gd      opponent patterns and career ladder
│   ├── fight_engine.gd       fixed-tick round flow and input resolution
│   ├── hm.gd                 damage/stamina rules and shared engine types
│   ├── seeded_rng.gd         seed-driven random number generator
│   └── scoring.gd            deterministic scoring and personal bests
├── scripts/game/
│   ├── game.gd               career, settings and append-only local records
│   └── main.gd               home, versus, HUD, results, records and settings
├── scripts/arena/            rendering, fighter animation, crowd and camera
├── assets/                  runtime fighter/crowd binaries and portraits
├── tests/                   engine regressions and input/UI journeys
└── export_presets.cfg        Windows and Android; iOS preset still to be added
```

Rules:
- Gameplay truth lives in `godot/scripts/engine/`; arena and shell code are presentation/session adapters.
- Fight outcomes depend only on seed, captured configuration and player input ticks. Rendering timing and crowd randomness must not affect simulation.
- Bouts are appended to `user://bouts.jsonl`; records are derived from saved bouts. Settings use `user://settings.cfg`.
- No runtime networking or network export permissions.
- Godot is authoritative. Legacy source and Apple project files are not maintained targets, and engine changes do not need to be duplicated into them.
- Defeated portraits share the versus top-30% crop. The career finale loops Mack's victory clip without advancing the completed engine. Finale stats cover only the current ladder's saved career bouts; End game resets progress while preserving records.
- UI sizing is platform-specific: mobile retains a screen-adaptive 430-unit logical canvas and safe areas; desktop stops upscaling and bounds panel widths between 30% of the window and per-surface pixel caps, with the cap taking precedence.

## Technology choices

| Choice | Rationale |
|---|---|
| Godot 4.7.2 + GDScript | One game implementation across desktop and mobile, including the planned iOS export. |
| Fixed-tick integer simulation | Reproducible seeded fights, golden fixtures and input-log replays. |
| Godot 3D arena and shared binary assets | Preserve original rigs, motion-capture clips, textures and choreography. |
| Local JSON-lines ledger + ConfigFile | On-device records and settings without accounts or services. |
| Package/bundle `com.infinityball.haymaker` | Preserve the game's existing application identity. |

## Current state and remaining milestones

1. **Playable Godot game:** engine, arena, ten-opponent career, sparring, versus/countdown, results, records, settings and career finale are implemented.
2. **Godot validation and CI:** headless engine and input/UI suites exist. Migrate the existing legacy-target CI to Godot checks and relevant asset/privacy checks; no Godot CI coverage is claimed yet.
3. **Data and accessibility:** finish backup/restore/export and verify controls, reduced motion, tell readability and assistive technology on each supported platform.
4. **iOS via Godot:** add an iOS export preset and validate iPhone/iPad layout, touch, haptics, local persistence, privacy metadata and signing on an Apple build environment. Do not create a second game implementation.
5. **Distribution:** validate release exports, original icon and store copy against shipped features; configure iOS/TestFlight distribution from the Godot export when ready.

## Testing strategy

- **Engine:** `godot --headless --path godot --script res://tests/run_tests.gd` covers seeded RNG, damage, golden fixtures, replay determinism, controls/countdown, ladder, scoring, stamina and playable roster.
- **Input/UI:** `godot --headless --path godot --script res://tests/input_test.gd -- --isolated-store` exercises keyboard/gamepad journeys without appending to normal records.
- **Layout:** `godot --headless --path godot --script res://tests/layout_test.gd -- --isolated-store` checks desktop panel minima/caps, scrolling and control bounds from small windows through 4K, ultrawide and portrait, plus the resolution-independent mobile canvas rule. Run without `--headless` for rendered desktop journeys.
- **Assets:** run the existing Python rig, clip and crowd regression suites when changing their assets or generators. Tooling currently stages generated files in `Haymaker/Models/`; copy them into `godot/assets/models/` for the game.
- **Runtime/export:** inspect the actual Godot arena and exports on affected platforms. Headless tests are not visual, physical-device performance or store-submission evidence.
- **CI honesty:** `.github/workflows/ci.yml` still checks legacy targets. Those results do not verify Godot builds, and legacy toolchain configuration is not the current game's development contract.

## Packaging / distribution

- `godot/export_presets.cfg` contains Windows x86_64, Windows ARM64 and Android arm64-v8a/x86_64 presets. Builds go to ignored `godot/builds/`.
- Android export requires the Android SDK, JDK 17, matching Godot export templates and signing configured outside the repository.
- iOS distribution will use Godot's iOS export, followed by Apple's platform build/signing requirements. No configured iOS preset, verified IPA or TestFlight pipeline is claimed.
- Keep signing material and credentials out of git and logs.
- Review `AppStore/description.txt` and icon artwork against actual exported features before release.

## Risks and invariants

- **Determinism:** render interpolation, floating-point animation and wall-clock timing must not feed engine state.
- **Asset fidelity:** preserve original sources and HMR2 rig/contact geometry. Optional HMT1 `.fighteruv` sidecars duplicate render vertices at UV seams while retaining normals and bone weights; base-color JPEGs preserve supplied artwork. Vertex-colored meshes remain the fallback.
- **Mobile performance:** measure actual device frame times, memory and touch readability; do not infer them from desktop or headless checks.
- **Adaptive displays:** use Godot's viewport/layout support for portrait, landscape and resizing. Dual-screen/foldable layouts remain a design target, not a compatibility claim.
- **Legacy migration:** asset staging paths and existing CI need focused migration work, not ongoing parallel game maintenance.
