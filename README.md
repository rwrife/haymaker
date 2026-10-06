# Haymaker

**Haymaker is a local-first iPhone boss-rush arcade boxing game: read telegraphed opponent patterns, throw one-thumb combos, and climb an original fighter career — with a dual-screen battle layout as the design target — no accounts, no cloud.**

Public repo under the Auto Tool Lab program (`auto-tool-lab`). M1 (skeleton + CI contract gates) has landed; M2 (pure-Swift match engine in `Packages/HaymakerKit`) is in progress. Gameplay, persistence, and release automation land in later milestones. No app build, store artifact, or device verification is claimed until the pinned Apple CI lane proves them.

## Overview

Haymaker is a single-player arcade boxing game for iPhone built in native Swift with SpriteKit for match gameplay and SwiftUI for everything around it. Every fight is a *boss fight*: an original opponent with a readable tell-driven move book (jabs, hooks, guards, feints), an exposure meter, and a rhythm the player learns. The core loop is short, one-handed, and score-attack friendly: pick a bout, read the telegraphs, land combos through the guard, dodge on the bell, and beat your own record.

The pitch: **a pocket arcade boxing cabinet** — every opponent is a distinct pattern puzzle, every session ends in a personal record, and all of it lives on your phone.

## Motivation

Chart-topping casual arcade games prove the appetite for one-thumb, session-short, progression-driven play, but most hide their depth behind energy systems, accounts, or ad loops. Readable arcade boxing is a pure expression of "learn the tell, execute the counter," and that genre is nearly extinct on mobile in a modern, privacy-first form. Haymaker builds an original boss-rush boxing loop as a deterministic, offline arcade game with honest local records.

The concept also maps naturally to the **iPhone Duo dual-screen** design target: opponent and fight read on one screen, player, stamina, and the big one-thumb control surface on the other (see the dual-screen section).

## Target users

- Players who want quick, skill-based arcade sessions (2–5 minutes) on one thumb.
- Fans of pattern-reading boss fights and score attack without live-service grind.
- People who want a game with zero network, zero accounts, zero ads.

## Concrete use cases

1. **Queue hop:** launch, tap the current career bout, play a 3-round fight, see the record board, close the app.
2. **Pattern practice:** replay a single opponent in Endless Sparring with the tell replay hints on, chasing a faster KO.
3. **Personal best chase:** compare today's run against the stored per-opponent bests (round, time, hit ratios) — all local.
4. **Career night:** fight the full roster ladder in one sitting with between-bout stat summaries.

## How to use / intended end-to-end workflow

1. First launch: pick a fighter name and difficulty preset (no account, no sign-in).
2. Career mode: bout ladder of original opponents with escalating pattern complexity.
3. In-bout: dodge/guard gestures or buttons, jab/hook/uppercut combo taps, stamina and opponent-tell meters always visible.
4. Bout end: results card with deterministic scoring (landed punch ratio, damage, round, time), saved locally; new personal bests marked.
5. Records wall: per-opponent bests, career stats, unlocked sparring presets.
6. Settings: controls layout, accessibility options, sound, and backup/export.

## MVP feature list

- Career boss-rush: 6 original opponents, each a distinct telegraph pattern book (v0 roster).
- Deterministic match engine in pure Swift (HaymakerKit package): pattern scheduler, tell windows, damage/stamina state machine — same input seed, same fight.
- One-thumb control scheme (tap combos + swipe guard/dodge) with a secondary two-handed scheme.
- SpriteKit match scene with modern vector/sprite art direction, hit feedback, and round flow.
- Endless Sparring mode (single-opponent loop with seeded patterns).
- Local records: per-opponent bests and career stats, append-only ledger, unknown-safe display (never invents missing history).
- Versioned JSON backup + CSV stats export via the Files app; restore with preview.
- Accessibility: large controls, colorblind-safe tell cues, haptics toggle, reduced motion, VoiceOver labels on shell UI.

## Non-goals

- No Flutter, React Native, Expo, Kotlin Multiplatform, .NET MAUI, Unity, or any cross-platform/hybrid framework — native Swift only.
- No Android and no native iPad support (iPhone-only; iPad requires explicit user opt-in).
- No accounts, cloud save, leaderboards, ads, IAP, or loot boxes; zero network at runtime.
- No licensed fighters, gyms, footage, trademarks, or names of real boxers or game franchises; all characters and art are original.
- No gambling/betting mechanics, no blood-gore realism, no medical/fitness claims.
- No online multiplayer versus mode in the MVP.

## Dual-screen (iPhone Duo) design target — build shape

Full dual-screen/foldable SDK support does not exist yet. Haymaker therefore scaffolds and ships as a **standard native Swift iPhone app with iPad support disabled by default**. The dual-screen experience is a documented design target with a single migration seam, never a dependency on unavailable fold APIs:

- **Battle split design target:** top/primary surface shows the opponent, tells, and the fight stage; the second surface becomes the persistent control deck — big one-thumb buttons, stamina, round clock, and read-hints — so the player never covers the fight to play it.
- **Career split design target:** roster/records wall as a control surface while the detail pane shows the selected opponent's pattern breakdown.
- **Migration seam:** a single `FightWorkspaceLayout` adapter decides single-screen vs spanned/two-surface layouts. Today it always resolves to the single-screen layout. When Apple ships fold/dual-screen APIs, only this seam changes. No iPhone Duo hardware compatibility is claimed until real API + device evidence exists.

## Privacy, permissions, and data storage

- **Zero network.** No server calls, no analytics, no ads, no trackers. A CI contract gate enforces an empty network allowlist (`toolchain.json: network_allowlist = []`).
- Data lives on-device (local SQLite via GRDB + app container). No accounts, no sign-in, no push notifications beyond optional local round/rest reminders if ever added (opt-in).
- Backups are user-initiated files (JSON archive, CSV export) shared via the system share sheet; nothing leaves the device unless the user exports it.
- No camera, microphone, contacts, location, or health permissions are requested. Motion input (if added post-MVP) is opt-in and never recorded.

## iOS platform facts

- Native Swift (SwiftUI shell + SpriteKit match scene), iPhone-only: `TARGETED_DEVICE_FAMILY = 1` in every app-target build configuration; built `UIDeviceFamily` must verify as `[1]` on an Apple build environment. Native iPad support is disabled; enabling it requires explicit user opt-in.
- iOS 26-or-newer SDK required; pinned in `toolchain.json` (Xcode 26.0.1 / 17A400 / iOS SDK 26.0 / Swift 6 mode).
- Bundle identifier: `com.infinityball.haymaker` (App Store Connect registration: `CREATED com.infinityball.haymaker`).
- Signing/TestFlight: `.github/workflows/release.yml` (packaging issue) builds, signs, and publishes via the App Store Connect API using the repository Actions secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `ASC_TEAM_ID` — secret names only, values never logged.
- App Store listing copy lives in `AppStore/description.txt`; a real generated icon will live at `AppStore/icon.png` (see backlog — placeholder icons and false "generated" claims are prohibited).

## Current status and milestones

Early build-out: the repository now carries the native Swift project skeleton — `Haymaker.xcodeproj` (app target `Haymaker`), the pure-domain match-engine package `Packages/HaymakerKit` (pattern books, fixed-tick fight engine, damage state machine, deterministic scoring), and the persistence package `HaymakerStore` — plus the pinned CI contract gates (iOS 26 toolchain pin, iPhone-only pre/post-build, zero-network allowlist, native-only framework scan). No SpriteKit scene, store artifact, icon, archive, or TestFlight binary exists yet.

1. ✅ **M1** — Xcode project + pure-Swift HaymakerKit package + CI (iOS 26 pin, iPhone-only gate, zero-network gate). (issue #1)
2. 🔄 **M2** — Match engine core: data-driven pattern books (first two opponents), fixed-tick FightEngine with tell-window resolution, stamina/damage state machine with KO/three-count rules, deterministic scoring + personal-best model, 49 swift-testing cases (golden-seed fixtures, replay determinism, state tables) proposed in issue #2; pending Apple CI.
3. 🔜 **M3** — SpriteKit fight scene + one-thumb controls + first opponent playable.
4. 🔜 **M4** — Career ladder (6 opponents), records ledger, stats derivations.
5. 🔜 **M5** — Backup/restore, CSV export, accessibility pass, `FightWorkspaceLayout` dual-screen seam (design target).
6. 🔜 **M6** — App Store copy finalization, generated icon wired into the asset catalog, TestFlight publish Action.

## Development / build quickstart

- macOS with Xcode 26.0.1 (17A400), iOS 26 SDK. Clone, open `Haymaker.xcodeproj`.
- Domain logic in `Packages/HaymakerKit` (Swift Package Manager, `swift test` runnable on Linux CI; UI/gameplay verification requires the pinned macOS CI runner):
  ```bash
  swift test --package-path Packages/HaymakerKit
  swift test --package-path Packages/HaymakerStore
  ```
- Run the contract gates locally:
  ```bash
  bash scripts/check_zero_network.sh
  bash scripts/check_native_only.sh
  ```
- CI on `macos-26` asserts the exact Xcode 26.0.1 (17A400) pin, iOS 26 SDK, `TARGETED_DEVICE_FAMILY = 1` pre- and post-build (`UIDeviceFamily == [1]` on the built app), the `com.infinityball.haymaker` bundle id, and privacy-manifest embedding.
