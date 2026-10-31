# Windows Store listing kit

English (en-US) listing materials for the Godot game. These are ready for listing
upload/review, not a certified Windows package or a completed Store submission.
No account, signing, permissions or Store submission has been configured.

## Deliverables and Partner Center fields

All images are opaque RGB PNGs. Paths below are relative to this directory.

| File | Dimensions | Use |
|---|---|---|
| `short-description.txt` | Plain text | Short description |
| `long-description.txt` | Plain text | Description |
| `wallpaper-1920x1080.png` | 1920 x 1080 | Wallpaper / text-free 16:9 Super hero art |
| `icons/icon-300.png` | 300 x 300 | Requested square icon / 1:1 app tile where offered |
| `icons/icon-150.png` | 150 x 150 | Requested square icon; packaging source, not a listing screenshot |
| `icons/icon-71.png` | 71 x 71 | Requested square icon; packaging source, not a listing screenshot |
| `poster-720x1080.png` | 720 x 1080 | Recommended 2:3 game poster / main game Store logo |
| `box-art-1080x1080.png` | 1080 x 1080 | 1:1 game box art |
| `screenshots/01-home.png` | 1920 x 1080 | Desktop screenshot |
| `screenshots/02-versus.png` | 1920 x 1080 | Desktop screenshot |
| `screenshots/03-fight.png` | 1920 x 1080 | Desktop screenshot |
| `screenshots/04-results.png` | 1920 x 1080 | Desktop screenshot |
| `screenshots/05-knockdown.png` | 1920 x 1080 | Desktop screenshot |

Suggested screenshot order is the numbered order above. Paste these captions in
the corresponding caption fields; do not burn them into the screenshots:

| Screenshot | Caption |
|---|---|
| 01 | Step into the ring as Mack and start your next career bout. |
| 02 | Meet Goldie Voltage before the bell: every challenger has an original fighting identity. |
| 03 | Read the tell, manage stamina and choose your next punch, guard or dodge in the 3D arena. |
| 04 | Review your real bout score, landed punches and counters, then choose Next fight or Rematch. |
| 05 | Land a counter and watch the knockdown count while the crowd reacts. |

## Microsoft requirements checked October 31, 2026

Primary sources:

- [Listing text and fields](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/add-and-edit-store-listing-info)
- [Screenshots, Store logos and promotional images](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/screenshots-and-images)
- [Package icons and logos](https://learn.microsoft.com/en-us/windows/apps/design/iconography/app-icons)

Description accepts up to 10,000 plain-text characters. Short description has a
1,000-character limit; Microsoft recommends fewer than 270 for the common views.
Our short copy is also below 200 characters. Screenshot captions have a
200-character limit.

Desktop screenshots must be PNG, at least 1366 x 768 and no larger than 50 MB
each. Up to ten desktop screenshots are supported; Microsoft recommends at least
four. This set contains five native 1920 x 1080 captures, with no added marketing
text, device frames, compositing, resizing or overlays. Existing in-game UI is
retained. Store text can overlay the bottom third: the fight's HUD and fighters
remain visible above it, although some normal game controls sit below it.

The Super hero image must be 1920 x 1080 or 3840 x 2160, with no title, other text,
device imagery or app UI. The wallpaper is an art-only composition, not a
gameplay screenshot. Fighter faces and gloves sit within the central/top
two-thirds; bottom cropping can remove feet and floor without removing those
details. Game poster and box art include the title in the top two-thirds on a
dark background, separate from the text-free hero.

**Listing graphics are not manifest assets.** The user-requested 300, 150 and
71 square icons are preserved exactly. For games, Microsoft recommends poster
art as the main Store logo, with box art as another game-listing surface; the
300 square app tile is not a replacement for those. A future MSIX package needs
its own correctly named manifest resources, appropriate scale/target-size
variants, and certification checks. These three PNGs do not establish that an
MSIX manifest, Windows executable icon or Start-menu tiles are configured.
Confirm fields against the chosen EXE/MSI or MSIX submission route in Partner
Center before upload; this kit follows the documented MSIX listing image sizes.
It does not claim Xbox support.

## Capture evidence and refreshing screenshots

Captured on Windows using Godot 4.7.2, Vulkan Forward Mobile, from the real
`godot/scenes/main.tscn` at main commit
`3b0b556453e8c80ba2e8f8aa816b936423b35e64` (merged PR #53). No gameplay,
presentation or engine source was changed for capture.

An external session-only Godot driver instantiated that scene, resized its real
window to 1920 x 1080, sent normal keyboard events and saved the rendered root
viewport after `RenderingServer.frame_post_draw`. It entered the opening career
bout, rang the bell, threw uppercuts, and waited for a naturally computed win and
the normal result screen. No engine state, HP, outcomes, stats or saved bouts
were injected. The game verified its own replay. `--isolated-store` uses the
authored ladder and an in-memory bout ledger, so Goldie is first and the user's
normal records are neither loaded nor written. The driver did not save settings.

To refresh from a later release, import and launch that exact project version:

```powershell
godot --headless --path godot --editor --import --quit
godot --path godot -- --isolated-store
```

Resize the content area to 1920 x 1080 and follow the same home, introduction,
fight, knockdown and result journey. Capture the game content only, not window
chrome. Keep naturally produced results; never reuse the synthetic results in
`godot/tests/input_test.gd` or `layout_test.gd` as Store evidence. Recapture after
player-visible changes and review against the final release export.

## Artwork provenance

- Requested icons: Lanczos downscales of the unchanged original
  [`../icon.png`](../icon.png). No new artwork or external stock was acquired.
- Poster and box art: crop/resize of that icon, a dark upper gradient and a
  Haymaker title rasterized with the locally installed Windows Impact font.
  Font binaries are not redistributed.
- Wallpaper: the repository's existing original
  `ArtDirection/arena-reference.png`, `player-reference.png` and
  `baxter-reference.png`, resized and alpha-composited over a subtle navy
  gradient. These are promotional concept assets, not runtime models or a claim
  of rendered game fidelity. Their original generation prompts remain in
  [`ArtDirection/README.md`](../../ArtDirection/README.md).
- Screenshots: actual Godot fighters, portraits, scene geometry and crowd; their
  source/animation provenance is recorded in the same ArtDirection document.

The existing `AppStore/description.txt` is historical Apple-targeted copy and
includes obsolete platform/rendering claims. Do not use it for Windows; use the
two Windows description files here. No verified iOS availability, accessibility
certification or specific hardware performance is claimed in this copy.
