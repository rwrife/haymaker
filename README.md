# Haymaker

**Haymaker is a Godot-only, local-first boss-rush arcade boxing game: read telegraphed opponent patterns, throw one-thumb combos, and climb an original fighter career — no accounts, no cloud.**

The authoritative game is `godot/`, using Godot 4.7.2. Windows and Android export presets are available. iPhone and iPad will be supported through Godot's iOS export from the same project, not a separate native game. An iOS export preset and verified store build are not available yet.

## Playable arena

The game opens on Mack shadowboxing, with a career ladder and seeded sparring against eleven story opponents: Goldie Voltage, Nico “Nightshift” Navarro, Atlas “Undertow” Reed, Vera Velvet, Duke Doubletake, Sylvie “Slipstream” Sloane, Cassian “Saint” Sterling, Jaison “Black Tie” Mercer, Hunter “Redline” Mercer, Fruit Tycoon, and final boss Bruiser Baxter. The first ten opponents are shuffled each session; Bruiser always closes the ladder. Even the opener has more health than Mack, keeps a loose guard up between attacks and punishes punches thrown carelessly. Difficulty ramps on an easing curve, so each step up the ladder is a bigger jump than the last: later challengers have more health, a tighter idle guard, shorter tells and gaps, and heavier punishment when they catch Mack mid-punch. Throwing into an idle guard only chips damage and invites the next attack; only the first counter into each tell lands double. Mashing jab can take the early bouts, but late opponents require reading tells, dodging and punishing recoveries.

Before every bout, rematch and sparring round, a versus dialog shows the opponent's portrait, fighting identity and intimidation line. Portraits open zoomed 2× on the fighter's head and slowly ease out to 1.5× over twelve seconds (instantly with reduced motion), keeping the whole head in frame. In career mode the versus dialog also shows the challenger's trained stats, how their attributes match up against Mack's (favorable, even or tough) and which attributes clash. The clock and controls wait for **Ring the bell**. After a win, the results screen shows the matching defeated portrait with a prominent **Next fight** first and **Rematch** as a secondary action, followed by **Career ladder** and **Exit to title**. Keyboard/gamepad focus starts on Next fight when available; losses and draws keep Rematch primary. On results, Up/Down step through the actions in on-screen order, Left/Right move between Career ladder and Exit to title and across the fighter-stat upgrades, and focus never lands on a stat that can't be upgraded; after spending a token, focus stays on that stat while it can still be trained. Defeats show Mack's existing defeated portrait. The next opponent stays a surprise until their introduction.

**Fighter progression.** Each first career win against a ladder opponent, except the final one, earns Mack one **fight prize token**. Every career results screen shows his token total and fighter stats below the bout score. Tap an attribute there, or on the career screen, to spend a token. Tokens can also be banked; they never block the next fight:
- **Power:** +10% punch damage per point.
- **Dexterity:** dodge, block and parry windows 10% wider and punches about 8% cheaper on stamina, per point, plus 1 point of armor (damage shrugged off per hit, minimum 1) per two points.
- **Speed:** windups and recoveries about 8% faster per point.

Attributes work like rock–paper–scissors: **Speed beats Power** (out-tempos slow, heavy shots), **Power beats Dexterity** (breaks through guard and armor) and **Dexterity beats Speed** (a tight guard and counter-punching outlast flurries). In career bouts each attribute gains half the opponent's points in the attribute it beats and loses half their points in the attribute that beats it, limited by the points invested and capped at 7. So pouring every token into Speed against a high-Dexterity challenger leaves Mack slower and the challenger tougher, while the same Speed build gets faster and faces a weakened Power fighter. Mirrored builds shift both fighters alike.

Every challenger still on the ladder also trains one point in a random attribute, so they hit harder, show faster tells with shorter gaps, or hold their guard longer, tire less, gain armor and punish more (+10% per Dexterity point). Each attribute caps at 5 points for Mack and for every challenger; a token or training point with no open attribute is lost. The career screen shows Mack's attributes and each challenger's training. Training lasts for the current ladder only. Sparring always uses untrained, unscaled fighters with no matchup.

Each fighter uses their supplied model and an authored rhythm based on their bio. Sylvie slips punches before a quick reply. Jaison uses precision counters and The Final Fitting hook–uppercut sequence, with “Let’s get this sorted.” as his walkout line. Hunter's Closing Time chains two jabs, a hook and a committed right with a longer final recovery; his introduction says “Try keeping up.” Fruit Tycoon, a billionaire who has bought up the boxing industry and takes a cut of every purse, fights in deliberate greyscale; his Hostile Takeover opens with a feint and a guarded pause before two jabs, a hook and an exposed closing uppercut, and his introduction says “Nice gloves. I own the company that made them.”

Completing the ladder opens a victory screen with Mack's looping victory animation and fighter statistics: score, wins/bouts, landed/thrown punches, accuracy, knockouts and counters. Totals include rematches and losses on the current ladder but exclude sparring and earlier ladders. **End game** returns to the title screen and starts a fresh ladder without deleting local records. Reduced Motion uses a still victory pose. The finale waits until the final win is saved; a failed save keeps the retry action available.

The Godot arena uses real 3D meshes and an authoritative deterministic engine. All twelve fighters share the Mixamo-compatible 22-bone HMR2 skeleton and a motion-capture library covering guard idle, punches, blocks, slips, hit reactions, knockdown, get-up, victory and warm-up. The runtime cross-fades clips, separates arm and footwork timing, plants feet, steers punches until contact and preserves boxing distance. Knockdowns last three seconds, with a fall, opponent taunt and return to guard. The knockout and celebration play before the results card.

The stands hold 105 rigged spectators: four Tripo3D-generated bodies in ten outfits. Independent schedules drive sitting, clapping, yelling and cheering; heavy blows and knockdowns excite the crowd without affecting fight randomness. Reduced Motion pauses ambient crowd movement.

The supplied boxing-crowd recording loops quietly in the background from launch until exit, including menus, introductions, fights, pause screens, results and the career finale. Screen changes do not restart it. Every landed punch by either fighter also plays a six-second crowd reaction, cropped from seconds 3–9 of the second supplied recording and amplified by 50%. Rapid hits overlap instead of cutting off earlier reactions; blocked, dodged, parried and missed punches do not trigger it. Every thrown punch by either fighter whooshes as it starts, and every landed punch adds a glove impact: jabs swing and land light, while hooks, uppercuts and counters swing or land heavy. Opponent feints stay silent. These original effects are synthesized by `scripts/build_punch_sfx.py`, overlap freely and vary slightly in pitch. Player wins by knockout or decision play the supplied loud crowd cheer once when the winning screen appears, including the career finale; losses and draws do not. The cheer stops when leaving for the next bout or title screen. The supplied **Brisk Tread** song loops as title music and stops when a bout starts. The Music setting controls title music only; crowd ambience, punch sounds and reactions, and victory cheers continue independently.

Glove impacts use deep bass thumps with a soft leather slap rather than a ringing midrange knock. Power punches have a fuller, longer bass decay; the swing whooshes are unchanged.

Four show spotlights hang above the arena. Each has a hazy beam that softens at its edges and light that reaches the ring and crowd. On the title and victory screens they sweep the ring and stands like a pre-fight walkout, periodically converging on Mack. During bouts only the two overhead spotlights stay lit, sweeping at half speed and converging on the fighters. With Reduced Motion, they hold still and aim into the stands.

## Overview

Every fight is a boss fight: an original opponent with readable tells, guards, feints and a rhythm to learn. The core loop is short, one-handed and score-attack friendly: pick a bout, read the telegraphs, land combos, dodge and beat your own record.

The pitch is **a pocket arcade boxing cabinet** with skill-based 2–5 minute sessions, honest local records and no live-service grind.

### Features

- Ten-opponent career boss rush and seeded Endless Sparring.
- Deterministic GDScript match engine: fixed ticks, pattern scheduler, tell windows, damage/stamina state machine and scoring.
- One-thumb and two-handed control layouts, on-screen buttons and swipe controls.
- Godot 3D arena with articulated fighters, cinematic lighting, hit feedback and round flow.
- Local per-opponent records and career stats derived from an append-only bout ledger.
- Settings for control style, colorblind tell cues, haptics and reduced motion.
- Portrait/landscape layouts and resizable desktop windows.

Backup/restore, CSV export, a platform accessibility pass and iOS distribution remain planned work; see [`PLAN.md`](PLAN.md).

### Non-goals

- No separately maintained platform-specific game; all platforms use Godot.
- No accounts, cloud save, leaderboards, ads, IAP, loot boxes or runtime networking.
- No licensed fighters, gyms, footage, trademarks or names of real boxers or game franchises; all characters and art are original.
- No gambling, blood-gore realism, medical/fitness claims or online multiplayer in the MVP.

## Controls and screens

On Windows and macOS, the game opens in a centered, resizable 16:9 window fitted within 75% of the screen's usable width and height (with a 640 × 360 minimum); F11 toggles full screen. Resizing switches the UI between portrait and landscape layouts. Desktop panels have a minimum width of 30% of the game window, up to their hard pixel maximum; the maximum takes precedence when the limits conflict. Desktop typography, images and controls scale together from a 1280 × 720 reference up to a bounded 2× zoom, so 4K displays remain readable without unlimited growth. Compact windows shrink to fit. The title is larger on desktop. The 30% minimum affects width only, not height; the arena still fills the display.

Absolute desktop panel ceilings at maximum zoom are 1280 pixels wide for home actions, pause and career victory; 1280 × 1440 for career/settings/records; 1700 × 1040 for landscape versus; 1560 × 1040 for landscape results; and 1920 pixels wide for the HUD/control console. Smaller windows use proportionately smaller panels.

Mobile uses a separate rule based on the platform, not its pixel resolution: a 430-unit logical canvas scales to the screen and expands with its aspect ratio. Mobile menus retain their screen-filling layouts, scrolling and safe-area padding instead of applying desktop pixel limits, so high-resolution phones do not get tiny desktop controls.

| Input | Fight controls | Menus |
|---|---|---|
| Keyboard | Space/J jab; Left/A/K hook; Up/W/I uppercut; Right/D/L dodge; Down/S guard; Shift/P parry; Esc pause | Arrows move focus; Enter/Space select; Esc back |
| Xbox controller | A jab; X hook; Y uppercut; B dodge; LB/LT guard; RB/RT parry; Menu (Start) pause. D-pad also throws hook, uppercut, dodge and guard | D-pad/left stick move focus; A select; B back |
| Touch/mouse | On-screen one-thumb/two-handed controls and swipes | On-screen menu controls |

Both touch layouts show keyboard keycaps on desktop. Connecting a controller replaces them with colored Xbox-style A/B/X/Y glyphs and LB/LT, RB/RT and Menu hints; disconnecting the last controller restores keyboard hints. Compact layouts keep these hints visible too. Touch-only mobile keeps its touch labels until a keyboard is used or a controller connects. Trigger squeezes queue one move per press rather than repeating while held.

The Xbox Menu button, Esc or the on-screen pause button opens **Resume bout**, **Settings**, **Return to title** and **Quit game**. Return to title abandons the current bout without deleting saved records; Quit game closes the application.

Fight buttons do not take focus, so a punch cannot activate a menu button. Dual-screen/foldable battle layouts remain a design target: fight stage on one surface and controls on another. No special hardware compatibility is claimed.

## Privacy and local storage

There are no server calls, analytics, ads, trackers or accounts. The Android preset disables Internet and network-state permissions and requests only vibration.

Records are appended to `user://bouts.jsonl`; settings use `user://settings.cfg`. No camera, microphone, contacts, location or health access is requested. Any future backup/export must be user-initiated and file-based.

The package/bundle identifier remains `com.infinityball.haymaker`. Signing material and credentials must stay outside the repository.

## Development and builds

Install Godot 4.7.2 and matching export templates for builds. Open `godot/project.godot` in the editor, or run:

```sh
godot --path godot
godot --headless --path godot --script res://tests/run_tests.gd
godot --headless --path godot --script res://tests/input_test.gd -- --isolated-store
godot --headless --path godot --script res://tests/audio_test.gd -- --isolated-store
godot --headless --path godot --script res://tests/layout_test.gd -- --isolated-store
godot --headless --path godot --export-release "Windows Desktop" builds/windows/Haymaker.exe
godot --headless --path godot --export-debug "Android" builds/android/Haymaker.apk
```

`godot/export_presets.cfg` includes Windows x86_64, Windows ARM64 and Android arm64-v8a/x86_64 presets. Android builds need the Android SDK, JDK 17 and a debug keystore configured in Godot's editor settings. Build output goes to ignored `godot/builds/`.

The planned iOS port will add a Godot iOS preset and use Apple's platform build/signing tools for the exported project. It will share the same engine, arena and shell; no separate game needs to be maintained.

Windows Store listing copy, a 1920 x 1080 promotional wallpaper, square icons,
game poster/box art and real desktop screenshots are in
[`AppStore/Windows/`](AppStore/Windows/README.md).

To build the Microsoft Store package (Windows, needs the Windows SDK for
`makeappx`/`makepri`, Python with Pillow, and Godot on `PATH` or in `$env:GODOT`):

```powershell
pwsh scripts/build_msix.ps1 -Version 1.0.0
```

This exports both Windows presets and writes an unsigned
`Haymaker_1.0.0.0_x64_arm64.msixbundle` plus portable x64/ARM64 zips to
`godot/builds/store/`. Upload the bundle in Partner Center (Store ID
`9NHMLZ8842DJ`); the Store signs it. Bump `-Version` for every submission.

The **Windows Store build** GitHub Action (`.github/workflows/msix.yml`) runs the
same script on a Windows runner. Publishing a GitHub release tagged `vX.Y.Z`
builds version `X.Y.Z` and attaches the bundle, zips and `SHA256SUMS.txt` to
the release; it can also be run manually from the Actions tab with a version.

### Architecture and validation

- `godot/scripts/engine/` owns gameplay state, seeded RNG, opponent books and scoring. Engine changes belong here and in `godot/tests/`, without duplicate implementation work.
- `godot/scripts/arena/` loads fighter/crowd binaries and owns animation, choreography, camera and lighting.
- `godot/scripts/game/` owns the shell, career progression, settings and local records.
- Headless tests cover engine regressions and input/UI journeys. They do not establish visual fidelity, physical-device frame rate or store readiness.

Legacy source and Apple project files remain in the repository but are not maintained game targets. `.github/workflows/ci.yml` runs only platform-neutral repository checks and `.github/workflows/msix.yml` builds the Windows Store package; Swift and iOS builds and tests were removed from CI, and Godot suites are not yet run there. Legacy simulator screenshots are not evidence that a Godot export works on iOS.

## Asset workflow

Original character sources, rigs, portraits and provenance live in [`ArtDirection/README.md`](ArtDirection/README.md). Godot consumes runtime models from `godot/assets/models/`.

Rebuild generated assets rather than editing them by hand:

```sh
python3 scripts/rig_fighters.py
python3 scripts/test_rig_fighters.py
python3 scripts/test_fighter_clips.py
python3 scripts/test_crowd.py
python3 scripts/build_punch_sfx.py --check
python3 scripts/test_punch_sfx.py
```

Existing tooling stages generated models, textures, crowd assets and `fighter.clips` in `Haymaker/Models/`; copy the relevant output into `godot/assets/models/`. This staging path does not make the legacy app authoritative. Blender is needed only to refit skin weights, recover source textures or rebake clips; runtime play does not require it. Never commit raw Mixamo FBX downloads.

The punch sound checks cover reproducible WAVs, bass/midrange balance, impact weight and peak headroom. They complement the Godot audio journeys; a listening pass on the target speakers is still needed to judge the mix.

All twelve fighters use supplied base-color textures. HMT1 UV sidecars preserve the HMR2 rigs and contact geometry while duplicating render vertices at seams. The exporter converts OBJ's bottom-origin V to the image's top-origin convention once; runtime materials must not flip it again. See [fighter texture provenance and format](ArtDirection/Models/README.md#fighter-texture-fidelity).
