#!/usr/bin/env python3
"""Build the App Store header and search-results banners.

Both are generated at the large size App Store Connect accepts (5244x2950) and
downscaled to 1280x720, since Apple takes either and the large one scales
cleanly rather than the reverse.

Kept consistent with the icon and the screenshot panels: same green, same
hanger mark, same oversized lowercase voice. A banner that looks like a
different product than the icon beside it is worse than no banner.

    python3 apps/ios/marketing/make_header.py
"""
from __future__ import annotations

import pathlib
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = pathlib.Path(__file__).resolve().parent
ICON_SVG = HERE.parent / "icon" / "icon.svg"
OUT = HERE / "asc-header"

LARGE = (5244, 2950)
SMALL = (1280, 720)

ACCENT = (24, 92, 76)
ACCENT_DEEP = (11, 54, 44)
CREAM = (246, 245, 241)


def font(size: int) -> ImageFont.FreeTypeFont:
    for path in (
        "/System/Library/Fonts/SFCompact.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/Library/Fonts/Arial Bold.ttf",
    ):
        if pathlib.Path(path).exists():
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    return ImageFont.load_default()


def render_mark(size: int) -> Image.Image | None:
    """Reuse the app icon's own SVG so the mark cannot drift from the icon."""
    if not ICON_SVG.exists():
        return None
    tmp = OUT / f"_mark-{size}.png"
    OUT.mkdir(parents=True, exist_ok=True)
    try:
        subprocess.run(
            ["rsvg-convert", "-w", str(size), "-h", str(size), str(ICON_SVG), "-o", str(tmp)],
            check=True, capture_output=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    mark = Image.open(tmp).convert("RGBA")
    tmp.unlink(missing_ok=True)
    return mark


def rounded(image: Image.Image, radius: int) -> Image.Image:
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, *image.size], radius=radius, fill=255)
    out = image.copy()
    out.putalpha(mask)
    return out


def build(headline: str, sub: str, wide: bool) -> Image.Image:
    w, h = LARGE
    canvas = Image.new("RGB", (w, h), ACCENT)

    glow = Image.new("RGB", (w, h), ACCENT)
    ImageDraw.Draw(glow).ellipse([-w * 0.25, -h * 0.4, w * 0.75, h * 0.9], fill=ACCENT_DEEP)
    canvas = Image.blend(canvas, glow.filter(ImageFilter.GaussianBlur(420)), 0.6)
    draw = ImageDraw.Draw(canvas)

    mark_size = int(h * 0.44)
    mark = render_mark(mark_size)
    if mark:
        mark = rounded(mark, int(mark_size * 0.22))
        mx = int(w * 0.60)
        my = (h - mark_size) // 2
        shadow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        ImageDraw.Draw(shadow).rounded_rectangle(
            [mx + 30, my + 60, mx + mark_size + 30, my + mark_size + 60],
            radius=int(mark_size * 0.22), fill=(0, 0, 0, 120),
        )
        canvas = Image.alpha_composite(
            canvas.convert("RGBA"), shadow.filter(ImageFilter.GaussianBlur(90))
        ).convert("RGB")
        canvas.paste(mark, (mx, my), mark)
        draw = ImageDraw.Draw(canvas)

    x = int(w * 0.075)
    y = int(h * 0.30)
    for line in headline.split("\n"):
        draw.text((x, y), line, font=font(int(h * 0.145)), fill=CREAM)
        y += int(h * 0.165)

    draw.text((x + 6, y + int(h * 0.03)), sub, font=font(int(h * 0.052)), fill=(196, 224, 214))
    return canvas


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)

    variants = [
        ("header", "crease", "dry cleaning, picked up and delivered"),
        # Search results sit next to competitors in a dense list, so this one
        # leads with what the product does rather than the name.
        ("search", "pickup &\ndelivery", "for the dry cleaner you already use"),
    ]

    for name, headline, sub in variants:
        image = build(headline, sub, wide=(name == "header"))
        large = OUT / f"{name}-5244x2950.png"
        small = OUT / f"{name}-1280x720.png"
        image.save(large, "PNG", optimize=True)
        image.resize(SMALL, Image.LANCZOS).save(small, "PNG", optimize=True)
        print(f"  {large.name}")
        print(f"  {small.name}")

    print("\nReview these before uploading — App Store creative assets are")
    print("outward-facing and go live on the product page.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
