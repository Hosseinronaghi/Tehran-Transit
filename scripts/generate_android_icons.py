#!/usr/bin/env python3
"""Build launcher icons for Android from the original Raha Tehran vector logo.

Update the checked-in Android drawable resources from the source artwork.
"""
from __future__ import annotations

from io import BytesIO
from pathlib import Path
import xml.etree.ElementTree as ET

import cairosvg
from PIL import Image

SOURCE = Path("assets/branding/raha_launcher.svg")
RES = Path("android/app/src/main/res")
SIZES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}


def main() -> None:
    if not SOURCE.is_file() or not RES.is_dir():
        raise SystemExit("Missing SVG logo or Android project")

    svg = SOURCE.read_bytes()
    png = cairosvg.svg2png(
        bytestring=svg, output_width=1024, output_height=1024
    )
    master = Image.open(BytesIO(png)).convert("RGBA")
    if master.size != (1024, 1024):
        raise SystemExit("Invalid icon master size")

    for density, size in SIZES.items():
        folder = RES / ("mipmap-" + density)
        folder.mkdir(parents=True, exist_ok=True)
        target = folder / "ic_launcher.png"
        master.resize((size, size), Image.Resampling.LANCZOS).save(
            target, "PNG", optimize=True
        )
        if target.stat().st_size < 1000:
            raise SystemExit(f"Empty or invalid Android launcher icon: {target}")
        print(f"{target}: {size}x{size}, {target.stat().st_size} bytes")

    # Keep all artwork in the 66% adaptive-icon safe central region.
    canvas = Image.new("RGBA", (432, 432), (0, 0, 0, 0))
    logo = master.resize((282, 282), Image.Resampling.LANCZOS)
    canvas.alpha_composite(logo, (75, 75))
    drawables = RES / "drawable-nodpi"
    drawables.mkdir(parents=True, exist_ok=True)
    canvas.save(drawables / "raha_launcher_foreground.png", "PNG", optimize=True)

    values = RES / "values"
    values.mkdir(parents=True, exist_ok=True)
    (values / "raha_launcher_colors.xml").write_text(
        '<resources><color name="raha_launcher_background">'
        "#052e40</color></resources>\n",
        encoding="utf-8",
    )
    adaptive = """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
  <background android:drawable="@color/raha_launcher_background" />
  <foreground android:drawable="@drawable/raha_launcher_foreground" />
</adaptive-icon>
"""
    ET.fromstring(adaptive)
    target_dir = RES / "mipmap-anydpi-v26"
    target_dir.mkdir(parents=True, exist_ok=True)
    (target_dir / "ic_launcher.xml").write_text(adaptive, encoding="utf-8")

    # Guard against misconfigured or renamed Flutter manifest icon references.
    manifest = Path("android/app/src/main/AndroidManifest.xml").read_text(
        encoding="utf-8"
    )
    if 'android:icon="@mipmap/ic_launcher"' not in manifest:
        raise SystemExit("AndroidManifest launcher icon reference changed")

    print("Raha Tehran: legacy Android density icons and adaptive icon generated")


if __name__ == "__main__":
    main()
