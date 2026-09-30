# Haymaker — PLAN

## Scope

Haymaker is a single-player, offline, boss-rush arcade boxing game for iPhone (native Swift). MVP = 6-opponent career ladder + endless sparring + local records + backup/export, playable one-handed, deterministic seeded fights, zero network. Dual-screen battle layout is a documented design target behind one layout seam (iPhone Duo focus); it is not implemented or claimed until fold APIs exist.

Out of scope (explicit): accounts, cloud save, multiplayer, ads/IAP/loot, licensed/trademarked boxers or franchise assets, betting, Android, native iPad support, fitness/medical claims, video capture, camera/mic.

## Architecture

```
Haymaker.xcodeproj (M1)
├── App/                      SwiftUI shell: career, records, settings, results
│   └── FightWorkspaceLayout  single seam: today single-screen; future two-surface split
├── MatchScene/               SpriteKit view + actor sprites + HUD bindings (thin)
├── Packages/HaymakerKit/     pure Swift 6 package (no UIKit/SpriteKit imports)
│   ├── PatternBook           per-opponent telegraph sequences, seed-driven scheduler
│   ├── FightEngine           round flow, tell windows, guard/dodge/parry resolution
│   ├── DamageModel           stamina + damage state machine, KO/KD rules
│   ├── Scoring               deterministic bout score, PB comparison
│   └── BackupCodec           versioned JSON archive + restore preview model
└── Packages/HaymakerStore/   GRDB store: bouts ledger (append-only), records, settings
```

Rules:
- All gameplay truth lives in HaymakerKit; SpriteKit/SwiftUI are presentation adapters.
- Fight outcomes are a pure function of (seed, player inputs) — replayable, testable, cheat-checkable.
- Append-only bout ledger; records are derived, never edited.
- Zero network by construction; CI grep gate enforces the empty allowlist.

## Technology choices and rationale

| Choice | Rationale |
|---|---|
| Swift 6 + SwiftUI (shell) | Fleet policy: native Swift only; no Flutter, React Native, Expo, Kotlin Multiplatform, .NET MAUI, Unity. |
| SpriteKit (match) | First-party 2D game framework on iOS 26; physics-light, deterministic update loop, no third-party engine dependency. |
| GRDB (SQLite) | Proven fleet data layer with versioned migrations + fixture DB pattern. |
| Xcode 26.0.1 (17A400) / iOS SDK 26 pin | Fleet toolchain contract in `toolchain.json`, enforced by CI. |
| iPhone-only (`TARGETED_DEVICE_FAMILY = 1`) | User directive; simplifies build + submission; iPad requires explicit opt-in. |
| Bundle `com.infinityball.haymaker` | Fleet `com.infinityball.` prefix convention; registered in ASC. |

## Milestones and dependency order

1. **M1 Skeleton + CI** (#1) — project, targets, HaymakerKit/Store package stubs, pinned macos-26 CI with iOS-26 SDK assert, iPhone-only pre/post-build gates, zero-network gate. Everything else depends on this.
2. **M2 Engine core** (#2) — PatternBook + FightEngine + DamageModel with seeded determinism, property-style tests, golden-seed fixtures. Depends on M1.
3. **M3 Playable fight** (#3) — SpriteKit scene, one-thumb controls, one opponent end-to-end, hit-feedback, round flow. Depends on M2.
4. **M4 Career + records** (#4) — 6-opponent ladder, endless sparring, append-only ledger, PB derivations, results cards. Depends on M2 (UI needs M3).
5. **M5 Data & accessibility** (#5) — backup/restore/export, accessibility pass, `FightWorkspaceLayout` seam documenting the dual-screen target. Depends on M4.
6. **M6 Release** (#6, #7) — App Store copy final review, generated icon wired into the asset catalog, `.github/workflows/release.yml` TestFlight publish Action. Depends on M1–M5.

## Testing strategy

- **HaymakerKit:** swift-testing suites on Linux CI + macOS lane: scheduler determinism (same seed → same sequence), tell-window resolution tables, damage/stamina state transitions, scoring, backup codec round-trips.
- **HaymakerStore:** migration tests with committed fixture DB.
- **UI/gameplay:** XCUITest journeys on pinned macOS runner (launch → start bout → land punches → results card → records visible). Simulator evidence only — never claimed as real-device or iPhone Duo compatibility.
- **Contract gates:** iPhone-only (`UIDeviceFamily == [1]` post-build), bundle-ID assert, zero-network allowlist grep.
- Honesty rule: Linux CI green ≠ the game compiles on Apple; the Apple lane is authoritative for SpriteKit/UIKit code.

## Packaging / distribution

- Ad hoc/simulator builds in PR CI; TestFlight via `.github/workflows/release.yml` ported from the proven fleet template (rwrife/cook-console, green in rise-log, split-slip, catch-tally): `v*` tag or manual dispatch → macos-26 → iOS 26+ SDK enforcement → signed IPA archive → TestFlight upload via the App Store Connect API using `ASC_KEY_ID`/`ASC_ISSUER_ID`/`ASC_KEY_P8`/`ASC_TEAM_ID` → wait for ASC processing → GitHub release. Never a new signing flow; values never logged.
- App Store copy: `AppStore/description.txt` reviewed against shipped features before release.
- Icon: real generated artwork at `AppStore/icon.png` (fleet creative brief via `hermes-image-gen`), wired into the Xcode app-icon asset catalog; no placeholders.

## Risks

- **SpriteKit determinism:** float timing in the render loop must not feed the engine; fixed-tick simulation in HaymakerKit with render interpolation only. (Mitigated by design — engine tick is integer-based and seed-driven.)
- **Art scope:** original fighters need real art. Mitigation: geometric/vector style, 6 opponents in MVP, programmatic animation from a small pose set.
- **Dual-screen SDK gap:** managed by the single `FightWorkspaceLayout` seam; no compatibility claims.
- **Runner flake:** simctl boot timeouts are known fleet flake; bounded retries + honest disclosure, never silent skip.

## Non-goals

Restate explicitly for executors: no Flutter, React Native, Expo, Kotlin Multiplatform, .NET MAUI, or Unity anywhere; no Android; no native iPad support; no accounts/cloud/ads/IAP; no licensed names or assets; no betting; no medical/fitness claims; no multiplayer in MVP.
