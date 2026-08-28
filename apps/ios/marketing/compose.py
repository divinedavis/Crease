#!/usr/bin/env python3
"""Compose App Store panels from raw simulator captures.

Marketing pages, not raw UI dumps. The layout follows what the top of the
store actually ships in 2026 — Instagram, Uber, Airbnb and DoorDash were all
pulled down and measured before this was rewritten:

  * One background across the whole set. Instagram is navy on all five, Uber
    black, DoorDash red. A carousel of alternating light and dark panels
    reads as five unrelated images; a single ground reads as one strip. The
    previous version of this file alternated cream and green, and the cream
    panels put a white screenshot on a near-white field, so the phone
    dissolved into the page.
  * No device bezel. Nobody frames screenshots in a titanium mockup any more —
    the screenshot itself gets rounded corners, a hairline and a shadow.
  * The screenshot bleeds off the bottom edge. A fully contained device
    floating in the middle of a panel is the 2018 look; every set measured
    runs the screen off the bottom so the panel feels like a window onto
    something larger.
  * A fixed horizon. Every headline starts at the same y and every screenshot
    starts at the same y, so the five panels line up when the shopper swipes.

Output is 1320x2868 — the 6.9" size, which is the one Apple asks for first and
scales down from for every smaller iPhone. It is also the iPhone 17 Pro Max's
own resolution, so the captured screen is pasted at its native aspect.

    python3 apps/ios/marketing/compose.py
"""
from __future__ import annotations

import pathlib
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = pathlib.Path(__file__).resolve().parent
RAW = HERE / "raw"
OUT = HERE / "panels"

W, H = 1320, 2868

# One ground for the whole set, deep enough that a white app screen sitting on
# it separates without needing a border to do the work.
FOREST = (12, 58, 47)
FOREST_LIFT = (22, 88, 71)
CREAM = (246, 245, 241)
SUB = (162, 197, 185)

MARGIN = 96
HEADLINE_TOP = 196
HEADLINE_SIZE = 112
HEADLINE_LEAD = 118
SHOT_TOP = 900           # the fixed horizon every panel shares

# Copy is unchanged from the 2026-08-27 rewrite, which checked every claim
# against the screen underneath it and against the App Store description. Only
# the layout is new here; re-litigating the words would undo that work.
PANELS = [
    dict(shot="01-home", headline="laundry,\nwithout the\nerrand",
         sub="Wash & fold and dry cleaning, collected in Brooklyn.",
         focus=0.00, zoom=0.82),
    # The keyboard is left in deliberately. It was the first instinct to crop
    # it away as clutter, but Uber's own "your destination is at your
    # fingertips" panel shows a raised keyboard for the same reason: it is what
    # tells the shopper the next step is typing, not choosing.
    dict(shot="02-address", headline="book it in\nthree taps",
         sub="Your address is already saved.",
         focus=0.00, zoom=0.82),
    # The tier list is the whole point of this screen and it sits below the
    # halfway line, so the window starts a fifth of the way down: a strip of
    # map for context, then every price.
    dict(shot="03-booking", headline="one price\nbefore the bag\nleaves",
         sub="A courier both ways, plus the shop's own cleaning prices.",
         focus=0.20, zoom=0.82),
    # Wash & fold is the only service the live partner has switched on, so the
    # headline says pound and not garment.
    #
    # The one panel that cannot bleed. The sheet holds a single service line, so
    # the screen is empty from 35% down to the footer at 92% — bleeding it would
    # fill half the panel with blank app background, and cropping to the card
    # alone leaves the bottom of the panel empty instead.
    #
    # So it is cut into the two regions that carry the story and stacked with
    # the dead space between them removed: what the shop charges per pound, and
    # what that comes to. Both are on screen at the same moment in the real app
    # — this is a crop, not a composite of two different screens. Uber and
    # Instagram both build a panel this way when one control is the point.
    dict(shot="04-menu", headline="priced by\nthe pound",
         sub="The shop's own rate. They weigh the bag, and that weight is the bill.",
         zoom=0.86, stack=[(0.015, 0.375), (0.900, 0.972)]),
    # Cropped to the four-step track, which is the thing the headline promises.
    #
    # It also has to stop above the order card, because the live partner's
    # `cleaners.phone` is a personal mobile number and the detail screen renders
    # it as a tappable row. Whether the app should dial that number is a real
    # question — it is what every customer sees today — but a globally
    # published App Store panel is not the place to settle it.
    dict(shot="05-tracking", headline="every step,\nin one place",
         sub="Collected, at the shop, cleaned, on the way back.",
         zoom=0.94, stack=[(0.000, 0.283), (0.425, 0.628)]),
]


def font(size: int, weight: int = 700, optical: int = 96) -> ImageFont.FreeTypeFont:
    """SF Pro at a real weight and optical size.

    SFNS.ttf is a variable font, so asking for the display optical size at 96
    gets the tighter apertures and smaller sidebearings Apple uses for large
    text — the difference between a headline that looks set and one that looks
    like body copy enlarged. Falls back to whatever static face exists if the
    Pillow build has no variable-font support.
    """
    sfns = pathlib.Path("/System/Library/Fonts/SFNS.ttf")
    if sfns.exists():
        try:
            f = ImageFont.truetype(str(sfns), size)
            f.set_variation_by_axes([100, optical, 400, weight])
            return f
        except (OSError, AttributeError):
            pass
    for path in (
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
    ):
        if pathlib.Path(path).exists():
            return ImageFont.truetype(path, size)
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


def wrap(draw: ImageDraw.ImageDraw, text: str, f: ImageFont.FreeTypeFont, width: int) -> list[str]:
    lines: list[str] = []
    words = text.split()
    line = ""
    for word in words:
        trial = f"{line} {word}".strip()
        if draw.textlength(trial, font=f) <= width:
            line = trial
        else:
            if line:
                lines.append(line)
            line = word
    if line:
        lines.append(line)
    return lines


def ground() -> Image.Image:
    """The shared background: one green, lifted behind the headline.

    A flat fill photographs as a slide. The lift is a very large, very soft
    ellipse behind the top-left corner, where the type sits, so the headline
    has something to stand on and the bottom of the panel stays dark enough for
    a white screenshot to separate from it.
    """
    canvas = Image.new("RGB", (W, H), FOREST)
    glow = Image.new("RGB", (W, H), FOREST)
    ImageDraw.Draw(glow).ellipse(
        [-W * 0.55, -H * 0.30, W * 1.05, H * 0.62], fill=FOREST_LIFT
    )
    return Image.blend(canvas, glow.filter(ImageFilter.GaussianBlur(220)), 0.75)


def place(canvas: Image.Image, shot: Image.Image, top: int, radius: int,
          all_corners: bool) -> Image.Image:
    """Drop a screenshot onto the panel with a shadow under it."""
    x = (W - shot.width) // 2
    card = rounded(shot, radius)
    if not all_corners:
        # The bottom is off-canvas, so only the top corners can be seen —
        # rounding the bottom ones as well would cut a visible notch out of a
        # shot that is meant to run off the edge.
        square = shot.crop((0, radius, shot.width, shot.height))
        card.paste(square, (0, radius))

    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [x + 10, top + 26, x + shot.width + 10, top + shot.height + 26],
        radius=radius, fill=(0, 0, 0, 150),
    )
    canvas = Image.alpha_composite(
        canvas.convert("RGBA"), shadow.filter(ImageFilter.GaussianBlur(52))
    )
    canvas.alpha_composite(card.convert("RGBA"), (x, top))

    # A hairline stops a white screenshot from looking like a hole punched in
    # the panel. Drawn on top rather than as a border on the image so it does
    # not eat a pixel of the screen.
    edge = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle(
        [x, top, x + shot.width - 1, top + shot.height - 1],
        radius=radius, outline=(*CREAM, 46), width=3,
    )
    canvas.alpha_composite(edge)
    return canvas.convert("RGB")


def build(panel: dict) -> Image.Image:
    canvas = ground()
    draw = ImageDraw.Draw(canvas)

    # Wordmark on a rail every panel shares, so a shopper halfway along the
    # carousel still knows whose app this is.
    draw.text((MARGIN, 92), "crease", font=font(50, weight=600, optical=28), fill=(*CREAM,))

    y = HEADLINE_TOP
    head_font = font(HEADLINE_SIZE, weight=730)
    for line in panel["headline"].split("\n"):
        draw.text((MARGIN, y), line, font=head_font, fill=CREAM)
        y += HEADLINE_LEAD

    # Wrap rather than shrink. The old composer shrank the sub until it fitted
    # on one line, which silently set one panel's caption four points smaller
    # than its neighbours' — invisible in the composer, obvious in a row.
    sub_font = font(43, weight=420, optical=28)
    y += 40
    for line in wrap(draw, panel["sub"], sub_font, W - MARGIN * 2)[:2]:
        draw.text((MARGIN, y), line, font=sub_font, fill=SUB)
        y += 56

    shot_path = find_shot(panel["shot"])
    if shot_path is None:
        print(f"  !! no capture for {panel['shot']} — run scripts/marketing-shots.sh")
        return canvas

    source = Image.open(shot_path).convert("RGB")
    target_w = int(W * panel["zoom"])
    scale = target_w / source.width

    if "stack" in panel:
        cards = []
        for top_frac, bottom_frac in panel["stack"]:
            region = source.crop((0, int(top_frac * source.height),
                                  source.width, int(bottom_frac * source.height)))
            cards.append(region.resize(
                (target_w, max(1, int(region.height * scale))), Image.LANCZOS))
        # Spread the pair over the space one bleeding screenshot would fill, so
        # this panel carries the same weight as its neighbours instead of
        # trailing off into green.
        slack = (H - SHOT_TOP) - sum(c.height for c in cards)
        gap = max(80, int(slack * 0.42))
        top = SHOT_TOP
        for card in cards:
            canvas = place(canvas, card, top, radius=56, all_corners=True)
            top += card.height + gap
        return canvas

    # The window onto the screen: where it starts, and how much of it fits
    # between the horizon and the bottom edge. Clamped to the end of the
    # capture — a focus deep enough to run the window past the bottom of the
    # screen used to leave the shot short of the edge, so the one panel meant
    # to show a list of prices was the one that stopped in mid-air.
    window = int((H - SHOT_TOP) / scale) + 2
    start = min(int(panel["focus"] * source.height), max(0, source.height - window))
    shot = source.crop((0, start, source.width, min(source.height, start + window)))
    shot = shot.resize((target_w, max(1, int(shot.height * scale))), Image.LANCZOS)
    return place(canvas, shot, SHOT_TOP, radius=76, all_corners=False)


def main() -> int:
    if not RAW.exists():
        print(f"no captures in {RAW} — run scripts/marketing-shots.sh first")
        return 1
    OUT.mkdir(parents=True, exist_ok=True)
    for i, panel in enumerate(PANELS, start=1):
        image = build(panel)
        path = OUT / f"panel-{i}.png"
        image.save(path, "PNG", optimize=True)
        print(f"  {path.name}  {image.size[0]}x{image.size[1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
