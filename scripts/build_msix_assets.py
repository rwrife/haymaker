#!/usr/bin/env python3
"""Generate MSIX manifest images for Haymaker from godot/icon.png.

Writes scale-qualified tiles and target-size app-list icons into
<out>/Assets. scripts/build_msix.ps1 indexes them into resources.pri.

Usage: python3 scripts/build_msix_assets.py <package-dir>
"""
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
ICON = ROOT / "godot" / "icon.png"
# Dark navy matching the icon's lower edge, used to letterbox the wide tile.
WIDE_BACKGROUND = (6, 22, 48)
SCALES = (100, 125, 150, 200, 400)
SQUARE_TILES = {"Square150x150Logo": 150, "Square44x44Logo": 44, "SmallTile": 71, "LargeTile": 310, "StoreLogo": 50}
TARGET_SIZES = (16, 24, 32, 48, 256)


def square(icon: Image.Image, size: int) -> Image.Image:
    return icon.resize((size, size), Image.LANCZOS)


def wide(icon: Image.Image, width: int, height: int) -> Image.Image:
    tile = Image.new("RGB", (width, height), WIDE_BACKGROUND)
    tile.paste(square(icon, height), ((width - height) // 2, 0))
    return tile


def build(out: Path) -> list[Path]:
    icon = Image.open(ICON).convert("RGB")
    assets = out / "Assets"
    assets.mkdir(parents=True, exist_ok=True)
    written = []

    def save(image: Image.Image, name: str) -> None:
        path = assets / name
        image.save(path, optimize=True)
        written.append(path)

    for name, base in SQUARE_TILES.items():
        for scale in SCALES:
            save(square(icon, round(base * scale / 100)), f"{name}.scale-{scale}.png")
    for scale in SCALES:
        save(wide(icon, round(310 * scale / 100), round(150 * scale / 100)), f"Wide310x150Logo.scale-{scale}.png")
    for size in TARGET_SIZES:
        save(square(icon, size), f"Square44x44Logo.targetsize-{size}.png")
        save(square(icon, size), f"Square44x44Logo.targetsize-{size}_altform-unplated.png")
        save(square(icon, size), f"Square44x44Logo.targetsize-{size}_altform-lightunplated.png")
    return written


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    written = build(Path(sys.argv[1]))
    print(f"Wrote {len(written)} MSIX images to {Path(sys.argv[1]) / 'Assets'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
