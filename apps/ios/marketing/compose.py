#!/usr/bin/env python3
"""Compose App Store panels from raw simulator captures.

Marketing pages, not raw UI dumps: an oversized lowercase headline carries each
panel, the device sits below it, and the accent colour alternates so the five
read as a sequence rather than five screenshots in a row.

Output is 1284x2778 — one of the sizes App Store Connect accepts for the 6.5"
slot, and close enough to the simulator's own aspect that the device image is
not visibly distorted.

    python3 apps/ios/marketing/compose.py
"""
from __future__ import annotations

import pathlib
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = pathlib.Path(__file__).resolve().parent
RAW = HERE / "raw"
OUT = HERE / "panels"

W, H = 1284, 2778

ACCENT = (24, 92, 76)
ACCENT_DEEP = (14, 62, 50)
CREAM = (246, 245, 241)
INK = (22, 24, 23)

# Ordered so the panels tell the story the product actually tells: the errand
# disappears, booking is trivial, and — the part nobody else does — the
# customer picks the return time once the clothes are genuinely ready.
PANELS = [
    dict(shot="01-home", headline="dry cleaning\nwithout the\nerrand",
         sub="A driver collects. A shop cleans. It comes back.", dark=True),
    dict(shot="02-address", headline="book it in\nthree taps",
         sub="Your address is already saved.", dark=False),
    dict(shot="03-booking", headline="one price,\nno surprises",
         sub="Delivery only. You pay the shop for the cleaning.", dark=True),
    dict(shot="04-cleaners", headline="your shop,\nnot ours",
         sub="Choose any cleaner near you.", dark=False),
    # The headline has to describe the screen underneath it. This one shows
    # tracking and a cancel button, so promising the return-scheduling moment
    # here would be a caption that does not match its picture.
    dict(shot="05-tracking", headline="in control,\nstart to\nfinish",
         sub="Track it, or cancel before a driver sets off.", dark=True),
]


def font(size: int, bold: bool = True) -> ImageFont.FreeTypeFont:
    candidates = [
        "/System/Library/Fonts/SFCompact.ttf",
        "/System/Library/Fonts/HelveticaNeue.ttc",
        "/Library/Fonts/Arial Bold.ttf" if bold else "/Library/Fonts/Arial.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
    ]
    for path in candidates:
        if pathlib.Path(path).exists():
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    return ImageFont.load_default()


def find_shot(stem: str) -> pathlib.Path | None:
    """The exporter leaves UUID-suffixed names alongside the clean ones."""
    exact = RAW / f"{stem}.png"
    if exact.exists():
        return exact
    matches = sorted(RAW.glob(f"{stem}*.png"))
    return matches[0] if matches else None


def rounded(image: Image.Image, radius: int) -> Image.Image:
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, *image.size], radius=radius, fill=255)
    out = image.copy()
    out.putalpha(mask)
    return out


def build(panel: dict, index: int) -> Image.Image:
    dark = panel["dark"]
    bg = ACCENT if dark else CREAM
    text_colour = CREAM if dark else INK
    sub_colour = (215, 232, 226) if dark else (110, 116, 112)

    canvas = Image.new("RGB", (W, H), bg)
    draw = ImageDraw.Draw(canvas)

    # A soft off-centre glow keeps the flat panels from looking like slides.
    glow = Image.new("RGB", (W, H), bg)
    ImageDraw.Draw(glow).ellipse(
        [-W * 0.3, -H * 0.15, W * 0.9, H * 0.5],
        fill=ACCENT_DEEP if dark else (236, 234, 228),
    )
    canvas = Image.blend(canvas, glow.filter(ImageFilter.GaussianBlur(160)), 0.55)
    draw = ImageDraw.Draw(canvas)

    # Wordmark, small, top-left — present on every panel so a shopper scrolling
    # the row always knows whose app they are looking at.
    draw.text((84, 96), "crease", font=font(52), fill=text_colour)

    y = 210
    for line in panel["headline"].split("\n"):
        draw.text((84, y), line, font=font(120), fill=text_colour)
        y += 132

    draw.text((88, y + 26), panel["sub"], font=font(44, bold=False), fill=sub_colour)

    shot_path = find_shot(panel["shot"])
    if shot_path:
        shot = Image.open(shot_path).convert("RGB")
        target_w = int(W * 0.72)
        target_h = int(shot.height * (target_w / shot.width))
        shot = shot.resize((target_w, target_h), Image.LANCZOS)
        shot = rounded(shot, 56)

        x = (W - target_w) // 2
        top = y + 190

        # Drop shadow so the device reads as sitting on the panel.
        shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        ImageDraw.Draw(shadow).rounded_rectangle(
            [x + 14, top + 24, x + target_w + 14, top + target_h + 24],
            radius=56, fill=(0, 0, 0, 110),
        )
        canvas = Image.alpha_composite(
            canvas.convert("RGBA"), shadow.filter(ImageFilter.GaussianBlur(40))
        ).convert("RGB")
        canvas.paste(shot, (x, top), shot)

    return canvas


def main() -> int:
    if not RAW.exists():
        print(f"no captures in {RAW} — run scripts/marketing-shots.sh first")
        return 1
    OUT.mkdir(parents=True, exist_ok=True)
    for i, panel in enumerate(PANELS, start=1):
        image = build(panel, i)
        path = OUT / f"panel-{i}.png"
        image.save(path, "PNG", optimize=True)
        print(f"  {path.name}  {image.size[0]}x{image.size[1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
