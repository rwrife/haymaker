# Haymaker

**Haymaker is a local-first iPhone boss-rush arcade boxing game: read telegraphed opponent patterns, throw one-thumb combos, and climb an original fighter career — with a dual-screen battle layout as the design target — no accounts, no cloud.**

Public repo under the Auto Tool Lab program (`auto-tool-lab`). M1 (skeleton + CI contract gates), M2 (pure-Swift match engine in `Packages/HaymakerKit`), and the playable Metal arena have landed; career persistence and release automation remain later milestones. The pinned Apple CI lane verifies a simulator app build, not a store artifact or physical-device run.

## Playable Metal arena

The app opens on Mack shadowboxing, with a career ladder and seeded sparring against ten story opponents: Goldie Voltage, Nico “Nightshift” Navarro, Atlas “Undertow” Reed, Vera Velvet, Duke Doubletake, Sylvie “Slipstream” Sloane, Cassian “Saint” Sterling, Jaison “Black Tie” Mercer, Hunter “Redline” Mercer, and final boss Bruiser Baxter. The career ladder is reshuffled each session: the first nine opponents appear in random order, Bruiser Baxter always closes it, and early opponents are passive and easy to hit, and each bout after is more aggressive and harder (shorter gaps, tells and recoveries, heavier hits). After a win, the results screen shows the defeated opponent's portrait, zoomed into the top 30% of the image, with **Rematch** and **Next fight** underneath. The next opponent stays a surprise until their versus introduction. All ten opponents have bundled defeated portraits. Each bout uses the matching supplied model and an authored fighting rhythm based on the character bio. Sylvie's evasive patterns slip punches before a quick reply.

Beating the entire ladder opens a separate victory screen: Mack repeats his victory animation in the arena behind a fighter-stats dialog. The totals cover the current ladder's career bouts, including rematches and losses, but exclude sparring and earlier ladders: score, wins/bouts, landed/thrown punches, accuracy, knockouts and counters. **End game** returns to the shadowboxing title screen and starts a fresh ladder without deleting local records. Reduced Motion shows Mack holding a still victory pose instead. The finale waits until the final win is saved; a failed save keeps the retry action available.

Before every bout, rematch, and sparring round, a versus dialog shows a close-up cropped to the top 30% of the supplied character PNG, their fighting identity, and a character-specific intimidation line. The clock and controls stay frozen until **Ring the bell**. The dialog supports portrait, landscape, VoiceOver, and scrolling at larger text sizes; closing it returns without starting a bout.

The arena and articulated fighters are real meshes rendered through Metal. The deterministic engine remains authoritative. Historical prototype books and recorded bouts remain available for replay and records, while the ten-opponent story ladder has its own progression.

The supplied character sculpts replace the prototype fighters. Mack and the selected opponent are used in each bout. All eleven models in `Haymaker/Models` are skinned to one shared Mixamo-compatible 22-bone skeleton (`HMR2`), with rigid gloves, boots and head. They all play one motion-capture clip library, `Haymaker/Models/fighter.clips`, baked from Mixamo boxing animations. It covers guard idle, jab, hook, uppercut, blocks, slips, head and body hit reactions, knockdown, get-up, victory and the title-screen warm-up. The runtime cross-fades between clips. The legs and arms run on separate clocks, so short engine windups speed up the punch rather than rushing the footwork. Feet stay planted between deliberate steps. Punches are steered onto the target only until contact and then snap back to guard. The fighters keep boxing distance, so gloves land without bodies passing through each other. A knockdown lasts three seconds: the fighter falls, the opponent taunts with both gloves raised, and the downed fighter is back in guard as the 3-2-1 count ends. After a knockout the finish and celebration play out before the results card. Reduced motion suppresses the ambient movement while keeping strikes readable. Pack the rigs with `python3 scripts/rig_fighters.py`; no external art tool is needed for that. Blender is only needed to re-fit skin weights or re-bake clips (see [`ArtDirection/Rigs`](ArtDirection/Rigs/README.md) and [`ArtDirection/Animations`](ArtDirection/Animations/README.md)). Run `python3 scripts/test_rig_fighters.py` and `python3 scripts/test_fighter_clips.py` for asset checks. The stands hold 105 rigged spectators generated with Tripo3D: four ~5,000-triangle bodies in ten outfits (casual tees and polos, business suits and blazers). Each one sits, claps, yells or stands up to cheer on its own random schedule, and the crowd rises with heavy blows and knockdowns. See [`ArtDirection/Crowd`](ArtDirection/Crowd/README.md); `python3 scripts/test_crowd.py` checks those assets. On macOS with full Xcode, `bash scripts/verify_fighter_rigs.sh` runs the animation checks and renders contact sheets. The supplied intro PNGs are bundled as versus portraits; the 3D arena uses the rigged models. See `ArtDirection/README.md` for asset provenance and prompts.

Earlier validation for the eight-opponent story roster and versus flow: 60 domain tests, 5 store tests, and simulator UI playthroughs covering all eight introductions, pre-fight waiting, rematches, sparring, settings, punches, records, both orientations and paused timing. Native-only and zero-network gates pass. Local verification uses Xcode 27 / iOS 27 simulator; the repository's separate pinned CI toolchain remains unchanged. Physical-device frame rate has not been measured.

Jaison “Black Tie” Mercer joins career and sparring with his supplied model and portrait, Vera-trained precision counters, and The Final Fitting hook–uppercut sequence. His walkout line is “Let’s get this sorted.” The story roster extends the deterministic engine and introduction checks.

## Overview

Haymaker is a single-player arcade boxing game for iPhone and iPad built in native Swift with a Metal-backed SceneKit 3D renderer for match gameplay and SwiftUI for everything around it. Every fight is a *boss fight*: an original opponent with a readable tell-driven move book (jabs, hooks, guards, feints), an exposure meter, and a rhythm the player learns. The core loop is short, one-handed, and score-attack friendly: pick a bout, read the telegraphs, land combos through the guard, dodge on the bell, and beat your own record.

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

- Career boss-rush: 10 story opponents, each with a distinct telegraph pattern book and matching portrait/model.
- Deterministic match engine in pure Swift (HaymakerKit package): pattern scheduler, tell windows, damage/stamina state machine — same input seed, same fight.
- One-thumb control scheme (tap combos + swipe guard/dodge) with a secondary two-handed scheme.
- Metal-backed 3D match scene with articulated fighters, cinematic lighting, hit feedback, and round flow.
- Endless Sparring mode (single-opponent loop with seeded patterns).
- Local records: per-opponent bests and career stats, append-only ledger, unknown-safe display (never invents missing history).
- Versioned JSON backup + CSV stats export via the Files app; restore with preview.
- Accessibility: large controls, colorblind-safe tell cues, haptics toggle, reduced motion, VoiceOver labels on shell UI.

## Non-goals

- No Flutter, React Native, Expo, Kotlin Multiplatform, .NET MAUI, Unity, or any cross-platform/hybrid framework — native Swift only.
- No Android support.
- No accounts, cloud save, leaderboards, ads, IAP, or loot boxes; zero network at runtime.
- No licensed fighters, gyms, footage, trademarks, or names of real boxers or game franchises; all characters and art are original.
- No gambling/betting mechanics, no blood-gore realism, no medical/fitness claims.
- No online multiplayer versus mode in the MVP.

## Dual-screen (iPhone Duo) design target — build shape

Full dual-screen/foldable SDK support does not exist yet. Haymaker therefore scaffolds and ships as a **standard native Swift iPhone and iPad app with native iPad support**. The dual-screen experience is a documented design target with a single migration seam, never a dependency on unavailable fold APIs:

- **Battle split design target:** top/primary surface shows the opponent, tells, and the fight stage; the second surface becomes the persistent control deck — big one-thumb buttons, stamina, round clock, and read-hints — so the player never covers the fight to play it.
- **Career split design target:** roster/records wall as a control surface while the detail pane shows the selected opponent's pattern breakdown.
- **Migration seam:** a single `FightWorkspaceLayout` adapter decides single-screen vs spanned/two-surface layouts. Today it always resolves to the single-screen layout. When Apple ships fold/dual-screen APIs, only this seam changes. No iPhone Duo hardware compatibility is claimed until real API + device evidence exists.

## Privacy, permissions, and data storage

- **Zero network.** No server calls, no analytics, no ads, no trackers. A CI contract gate enforces an empty network allowlist (`toolchain.json: network_allowlist = []`).
- Data lives on-device (local SQLite via GRDB + app container). No accounts, no sign-in, no push notifications beyond optional local round/rest reminders if ever added (opt-in).
- Backups are user-initiated files (JSON archive, CSV export) shared via the system share sheet; nothing leaves the device unless the user exports it.
- No camera, microphone, contacts, location, or health permissions are requested. Motion input (if added post-MVP) is opt-in and never recorded.

## iOS platform facts

- Native Swift (SwiftUI shell + SpriteKit match scene), iPhone and iPad: `TARGETED_DEVICE_FAMILY = "1,2"` in every app-target build configuration; built `UIDeviceFamily` must verify as `[1, 2]` on an Apple build environment. Native iPad support is enabled by explicit user request.
- iOS 26-or-newer SDK required; pinned in `toolchain.json` (Xcode 26.0.1 / 17A400 / iOS SDK 26.0 / Swift 6 mode).
- Bundle identifier: `com.infinityball.haymaker` (App Store Connect registration: `CREATED com.infinityball.haymaker`).
- Signing/TestFlight: `.github/workflows/release.yml` (packaging issue) builds, signs, and publishes via the App Store Connect API using the repository Actions secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `ASC_TEAM_ID` — secret names only, values never logged.
- App Store listing copy lives in `AppStore/description.txt`; a real generated icon will live at `AppStore/icon.png` (see backlog — placeholder icons and false "generated" claims are prohibited).

## Current status and milestones

Early build-out: the repository now carries the native Swift project skeleton — `Haymaker.xcodeproj` (app target `Haymaker`), the pure-domain match-engine package `Packages/HaymakerKit` (pattern books, fixed-tick fight engine, damage state machine, deterministic scoring), and the persistence package `HaymakerStore` — plus the pinned CI contract gates (iOS 26 toolchain pin, iPhone and iPad pre/post-build, zero-network allowlist, native-only framework scan). A playable Metal-backed 3D scene now exists. No store archive or TestFlight binary has been verified.

1. ✅ **M1** — Xcode project + pure-Swift HaymakerKit package + CI (iOS 26 pin, iPhone and iPad gate, zero-network gate). (issue #1)
2. ✅ **M2** — Match engine core: data-driven pattern books (first two opponents), fixed-tick FightEngine with tell-window resolution, stamina/damage state machine with KO/three-count rules, deterministic scoring + personal-best model, 51 swift-testing cases (golden-seed fixtures, replay determinism, state tables). (issue #2)
3. ✅ **M3 gameplay** — Metal-backed 3D fight scene + one-thumb controls + Bruiser Baxter playable.
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
- CI on `macos-26` asserts the exact Xcode 26.0.1 (17A400) pin, iOS 26 SDK, `TARGETED_DEVICE_FAMILY = "1,2"` pre- and post-build (`UIDeviceFamily == [1, 2]` on the built app), the `com.infinityball.haymaker` bundle id, and privacy-manifest embedding.

Hunter “Redline” Mercer joins the shuffled career ladder and is available in seeded sparring. His Closing Time pattern chains two jabs, a hook and a committed right, with a longer final recovery to punish overcommitment. His supplied portrait introduces the bout with “Try keeping up.” The defeat portrait is archived with the other future cut-scene art.

## Adaptive screens

Native iPad support uses the entire window for the Metal arena. Its vertical camera field of view reveals more of the arena as the window widens, without stretching fighters. Controls stay inside safe areas: two-handed controls reflow from two rows to one at 780 points of available width, with taller buttons in windows at least 600 points high. The control deck is capped at 960 points to keep buttons readable on large displays. Rotation and iPad window resizing update the layout automatically. These layouts also accommodate unusual phone aspect ratios; iPhone Duo hardware and separate fold surfaces remain unverified design targets.

### Making an existing iPad window full screen

After upgrading from an iPhone-only build, iPadOS may restore Haymaker in a narrow window even though the installed app supports iPad. If you can see the iPad wallpaper beside the rounded app window, open the iPad window menu and select **Enter Full Screen** (or **Window → Enter Full Screen** from the menu bar). The arena and controls adapt to the expanded window immediately; reinstalling the app or deleting records is unnecessary. iPadOS owns the restored window size, so native iPad support alone does not force a full-screen launch.

This was verified with the existing universal build on an iPad mini (A17 Pro) simulator running iPadOS 27: the narrow title window expanded to fill the display. This is simulator evidence, not a physical-device or pinned-toolchain build claim. Apple's [iPad multitasking instructions](https://support.apple.com/en-us/125309) describe the system's full-screen controls.

The built-app display gate checks both device families, all four iPad orientations, a launch-screen declaration, and absence of the fixed-size `UIRequiresFullScreen` compatibility mode. Run `python3 scripts/test_device_families.py` for its regression checks. Do not add `UIRequiresFullScreen` as a workaround for a restored narrow window; see Apple's [iPad compatibility-mode migration guidance](https://developer.apple.com/documentation/technotes/tn3192-migrating-your-app-from-the-deprecated-uirequiresfullscreen-key).
