#!/usr/bin/env python3
"""App Store creative assets (the fall-2026 Asset Library) for Crease.

Apple's three canvases:

    header    3840x1646  product page header (and each custom product page's)
    search    3840x2560  search results slot
    universal 5244x2950  16:9 master Apple can crop into either

The look is the app icon's: its green gradient (#2E876F -> #15503C) as the
field, the white hanger from apps/web/public/assets/icon.svg beside a white
"Crease" in SF Pro, and real pieces of the app floating around it — the map
with the pickup pin, the four-stage order track, the wash & fold row — cut
from the raw simulator shots in marketing/raw-ios. No stock imagery, nothing
drawn that the app does not show.

Every word and every focal piece sits inside the centre ~60% x 70% of the
canvas, because Apple crops the edges on some devices; only decoration
reaches the edges. The App Store draws the icon, name and subtitle under the
header itself, so each page carries the name plus one short line and lets
the art do the rest.

Apple's rules for these assets, and this repo's: no prices or discounts (the
crops stop above every dollar figure), no URLs, no (c), no awards or claims,
no other stores. And no dry cleaning — growth/facts.py: "Dry cleaning is not
offered yet — only wash and fold." (T006 in growth/techniques.json.)

One set per page: "default" for the main product page (all three canvases),
then one header per custom product page.

Usage: ~/.venvs/spendcap/bin/python scripts/make_creative_assets.py [OUT_DIR]
       (default OUT_DIR: ~/Downloads/ASC-creative-assets/crease)
Needs Pillow and rsvg-convert (Homebrew librsvg) on PATH.
"""
from __future__ import annotations

import math
import os
import pathlib
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
RAW = ROOT / "marketing/raw-ios"
ICON = ROOT / "apps/ios/Crease/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
SF = "/System/Library/Fonts/SFNS.ttf"

CANVASES = {"header": (3840, 1646), "search": (3840, 2560), "universal": (5244, 2950)}

# Brand colours: the icon's gradient stops, the web app's accents.
TOP = (46, 135, 111)        # #2E876F
DEEP = (21, 80, 60)         # #15503C
INK = (23, 33, 30)          # #17211E
MINT = (231, 241, 237)      # #E7F1ED
ACCENT = (31, 112, 92)      # #1F705C
WHITE = (255, 255, 255)

# Two fields. "dark" is the icon itself; "light" is the pale mint of the
# Pinterest screenshot set (marketing/asc-screenshots-pinterest/01-brand.png),
# deep-green wordmark on mint, so a custom product page reads as a sibling of
# the main one rather than a copy.
THEMES = {
    "dark": {"top": TOP, "deep": DEEP, "glow": (120, 200, 170, 70), "word": WHITE,
             "mark": "#FFFFFF", "tag": (214, 236, 227), "halo": (8, 50, 38, 150), "shadow": 110},
    "light": {"top": (236, 245, 241), "deep": (217, 235, 227), "glow": (246, 251, 249, 110),
              "word": DEEP, "mark": "#15503C", "tag": (58, 92, 82), "halo": None, "shadow": 70},
}

# The hanger paths, copied from apps/web/public/assets/icon.svg (rsvg does
# not resolve <use> across files), white on transparent, viewBox trimmed to
# the mark.
HANGER_SVG = """<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="216 272 592 464">
<g fill="none" stroke="{color}" stroke-linecap="round" stroke-linejoin="round">
<path d="M 512 452 L 512 348 A 70 70 0 0 0 372 348 L 372 396" stroke-width="50"/>
<path d="M 512 452 L 258 694 L 766 694 Z" stroke-width="72"/>
</g></svg>"""

# Pieces of the app, as (file, box) in the 1320x2868 simulator shots. Every
# box stops short of the dollar figures on the same screen.
CROPS = {
    "map": ("03-choose-service.png", (420, 395, 1120, 1095)),       # route + bag pin, Williamsburg/Greenpoint
    "track": ("05-track-order.png", (52, 400, 1270, 784)),         # Ready for delivery, 4-stage track
    "cleaning": ("01-orders-history.png", (50, 2516, 1270, 2832)),  # Being cleaned, 3 of 4 done
    "washrow": ("03-choose-service.png", (52, 2222, 1270, 2394)),   # Wash & fold row
}

# Layouts in canvas fractions (x, y) plus sizes in "u" = canvas height/720.
# Wordmark and tagline are always centred; these place the floating art.
LAYOUTS = {
    "header": {
        "word_y": 0.43, "word_w": 0.36,
        "tile": (0.235, 0.22, 118, -10),
        "map": (0.115, 0.62, 250),
        "card": (0.835, 0.38, 420, 4),
        "card2": (0.835, 0.79, 380, -3),
        "chips": [(0.5, 0.79), (0.63, 0.21)],
    },
    "search": {
        "word_y": 0.45, "word_w": 0.44,
        "tile": (0.20, 0.17, 110, -10),
        "map": (0.15, 0.70, 270),
        "card": (0.80, 0.24, 390, 4),
        "card2": (0.81, 0.77, 380, -3),
        "chips": [(0.5, 0.79), (0.45, 0.20)],
    },
    "universal": {
        "word_y": 0.45, "word_w": 0.40,
        "tile": (0.20, 0.19, 110, -10),
        "map": (0.13, 0.66, 250),
        "card": (0.81, 0.29, 380, 4),
        "card2": (0.82, 0.78, 360, -3),
        "chips": [(0.5, 0.79), (0.47, 0.20)],
    },
}

PAGES = {
    "default": {
        "tagline": "Laundry, picked up and delivered",
        "card": "track", "card2": "washrow",
        "chips": ["Picked up at your door", "Washed & folded"],
    },
    # Wash & fold: for people who lose a weekend morning to the laundromat.
    "cpp-wash-fold": {
        "tagline": "Wash & fold, without the laundromat trip",
        "card": "washrow", "card2": "cleaning",
        "chips": ["Bedding & towels too", "Folded and brought back"],
        "theme": "light",
    },
    # Brooklyn: the neighbourhoods around Clinton Hill the service covers
    # (apps/web/lib/neighborhoods.ts; marketing/gbp/description.txt).
    "cpp-brooklyn": {
        "tagline": "Brooklyn laundry, done on your block",
        "card": "track", "card2": "cleaning",
        "chips": [], "tile": False,
        "map": {"header": (0.13, 0.50, 330)},
        "hoods": [("Fort Greene", 0.37, 0.21), ("Bed-Stuy", 0.63, 0.21),
                  ("Clinton Hill", 0.37, 0.79), ("Park Slope", 0.63, 0.79)],
    },
}


# ---------- primitives ----------

def font(weight: str, size: float) -> ImageFont.FreeTypeFont:
    f = ImageFont.truetype(SF, max(8, int(size)))
    f.set_variation_by_name(weight)
    return f


def background(w: int, h: int, th: dict) -> Image.Image:
    """The icon's diagonal gradient, with a soft lift behind the wordmark."""
    sw, sh = 96, max(2, int(96 * h / w))
    small = Image.new("RGB", (sw, sh))
    px = small.load()
    for y in range(sh):
        for x in range(sw):
            # icon: x1=0 y1=0 -> x2=0.35 y2=1
            t = (x / sw * 0.35 + y / sh) / 1.35
            t = min(1.0, max(0.0, t * 1.15))
            px[x, y] = tuple(int(th["top"][i] + (th["deep"][i] - th["top"][i]) * t) for i in range(3))
    img = small.resize((w, h), Image.BICUBIC).convert("RGBA")
    # Blur only the alpha: blurring an RGBA layer drags the transparent
    # pixels' black into the edge and leaves a grey ring on the light field.
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).ellipse([w * 0.22, h * 0.12, w * 0.78, h * 0.80], fill=th["glow"][3])
    glow = Image.new("RGBA", (w, h), th["glow"][:3] + (0,))
    glow.putalpha(mask.filter(ImageFilter.GaussianBlur(int(h * 0.12))))
    img.alpha_composite(glow)
    return img


def hanger(width: int, color: str = "#FFFFFF") -> Image.Image:
    h = int(width * 464 / 592)
    with tempfile.TemporaryDirectory() as tmp:
        svg = pathlib.Path(tmp, "h.svg")
        png = pathlib.Path(tmp, "h.png")
        svg.write_text(HANGER_SVG.format(w=width, h=h, color=color))
        subprocess.run(["rsvg-convert", "-w", str(width), "-h", str(h), str(svg), "-o", str(png)],
                       check=True, capture_output=True)
        return Image.open(png).convert("RGBA")


def shadow(base: Image.Image, mask: Image.Image, pos, blur: float, alpha=90, dy=0.0) -> None:
    sh = Image.new("RGBA", base.size, (0, 0, 0, 0))
    layer = Image.new("RGBA", mask.size, (6, 40, 30, 255))
    layer.putalpha(mask.point(lambda v: int(v * alpha / 255)))
    sh.alpha_composite(layer, (int(pos[0]), int(pos[1] + dy)))
    base.alpha_composite(sh.filter(ImageFilter.GaussianBlur(max(1, int(blur)))))


def wordmark(base: Image.Image, page: dict, lay: dict, u: float, th: dict) -> None:
    w, h = base.size
    d = ImageDraw.Draw(base)
    text = "Crease"
    size = 230 * u
    f = font("Bold", size)
    asc, desc = f.getmetrics()
    cap = f.getbbox("C")[3] - f.getbbox("C")[1]
    mark_w = lambda: int(cap * 1.32 * 592 / 464)
    gap = lambda: cap * 0.30
    total = lambda: mark_w() + gap() + d.textlength(text, font=f)
    while total() > w * lay["word_w"]:
        size -= 4
        f = font("Bold", size)
        cap = f.getbbox("C")[3] - f.getbbox("C")[1]
    x0 = (w - total()) / 2
    cy = h * lay["word_y"]
    cap_top_off = f.getbbox("C")[1]
    ty = cy - cap / 2 - cap_top_off

    # soft dark glow keeps the letters crisp over the lighter centre
    glow = Image.new("RGBA", base.size, (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    mk = hanger(mark_w(), th["mark"])
    mx, my = int(x0), int(cy - mk.height / 2 - cap * 0.06)
    if th["halo"]:
        gd.text((x0 + mark_w() + gap(), ty), text, font=f, fill=th["halo"])
        base.alpha_composite(glow.filter(ImageFilter.GaussianBlur(int(18 * u))))
    base.alpha_composite(mk, (mx, my))
    ImageDraw.Draw(base).text((x0 + mark_w() + gap(), ty), text, font=f, fill=th["word"])

    tag = page["tagline"]
    ts = 46 * u
    tf = font("Semibold", ts)
    while d.textlength(tag, font=tf) > w * 0.56:
        ts -= 2
        tf = font("Semibold", ts)
    tw = d.textlength(tag, font=tf)
    ImageDraw.Draw(base).text(((w - tw) / 2, cy + cap / 2 + cap * 0.42), tag, font=tf, fill=th["tag"])


def rounded(img: Image.Image, radius: int) -> Image.Image:
    m = Image.new("L", img.size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, img.width - 1, img.height - 1], radius=radius, fill=255)
    out = img.convert("RGBA")
    out.putalpha(m)
    return out


def crop(name: str) -> Image.Image:
    f, box = CROPS[name]
    return Image.open(RAW / f).convert("RGB").crop(box)


def place(base: Image.Image, piece: Image.Image, center, u: float, angle=0.0, blur=22, alpha=110) -> None:
    if angle:
        piece = piece.rotate(angle, resample=Image.BICUBIC, expand=True)
    x, y = int(center[0] - piece.width / 2), int(center[1] - piece.height / 2)
    shadow(base, piece.split()[3], (x, y), blur * u, alpha=alpha, dy=12 * u)
    base.alpha_composite(piece, (x, y))


def card(base: Image.Image, name: str, center, width: float, angle: float, u: float) -> None:
    src = crop(name)
    wpx = int(width * u)
    src = src.resize((wpx, int(src.height * wpx / src.width)), Image.LANCZOS)
    place(base, rounded(src, int(wpx * 0.045)), center, u, angle)


def map_disc(base: Image.Image, center, diam: float, u: float) -> None:
    d = int(diam * u)
    ring = int(8 * u)
    src = crop("map").resize((d, d), Image.LANCZOS).convert("RGBA")
    m = Image.new("L", (d, d), 0)
    ImageDraw.Draw(m).ellipse([0, 0, d - 1, d - 1], fill=255)
    src.putalpha(m)
    disc = Image.new("RGBA", (d + 2 * ring, d + 2 * ring), (0, 0, 0, 0))
    ImageDraw.Draw(disc).ellipse([0, 0, disc.width - 1, disc.height - 1], fill=WHITE + (255,))
    disc.alpha_composite(src, (ring, ring))
    place(base, disc, center, u)


def icon_tile(base: Image.Image, center, size: float, angle: float, u: float) -> None:
    s = int(size * u)
    ic = Image.open(ICON).convert("RGB").resize((s, s), Image.LANCZOS)
    t = rounded(ic, int(s * 0.225))
    # thin light rim so the green tile separates from the green field
    rim = Image.new("RGBA", (s + int(6 * u), s + int(6 * u)), (0, 0, 0, 0))
    ImageDraw.Draw(rim).rounded_rectangle([0, 0, rim.width - 1, rim.height - 1],
                                          radius=int(s * 0.235), fill=(255, 255, 255, 90))
    rim.alpha_composite(t, (int(3 * u), int(3 * u)))
    place(base, rim, center, u, angle, blur=18, alpha=130)


def chip(base: Image.Image, text: str, center, u: float, size=30, check=True, pin=False) -> None:
    f = font("Semibold", size * u)
    d0 = ImageDraw.Draw(base)
    tw = d0.textlength(text, font=f)
    asc, desc = f.getmetrics()
    th = asc + desc
    pad = 22 * u
    icon_w = th * 0.86 + 12 * u if (check or pin) else 0
    w, h = int(tw + 2 * pad + icon_w), int(th + 1.05 * pad)
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(layer).rounded_rectangle([0, 0, w - 1, h - 1], radius=h // 2, fill=WHITE + (255,))
    x, y = int(center[0] - w / 2), int(center[1] - h / 2)
    shadow(base, layer.split()[3], (x, y), 14 * u, alpha=95, dy=7 * u)
    base.alpha_composite(layer, (x, y))
    d = ImageDraw.Draw(base)
    tx = x + pad
    r = th * 0.43
    cx, cy = tx + r, y + h / 2
    if check:
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=ACCENT)
        d.line([(cx - r * 0.45, cy + r * 0.02), (cx - r * 0.1, cy + r * 0.38), (cx + r * 0.48, cy - r * 0.36)],
               fill=WHITE, width=max(2, int(4.2 * u)), joint="curve")
    elif pin:
        pr = r * 0.62
        py = cy - r * 0.28
        d.ellipse([cx - pr, py - pr, cx + pr, py + pr], fill=ACCENT)
        d.polygon([(cx - pr * 0.86, py + pr * 0.5), (cx + pr * 0.86, py + pr * 0.5), (cx, py + pr * 2.2)], fill=ACCENT)
        d.ellipse([cx - pr * 0.4, py - pr * 0.4, cx + pr * 0.4, py + pr * 0.4], fill=WHITE)
    if check or pin:
        tx += icon_w
    d.text((tx, y + (h - th) / 2 - 1 * u), text, font=f, fill=INK)


# ---------- page ----------

def render(kind: str, page: dict) -> Image.Image:
    w, h = CANVASES[kind]
    lay = LAYOUTS[kind]
    u = h / 720.0
    if kind == "search":
        u = w / 1280.0 * 0.86
    th = THEMES[page.get("theme", "dark")]
    base = background(w, h, th)
    P = lambda fx, fy: (fx * w, fy * h)

    if page.get("tile", True):
        tx, ty, ts, ta = lay["tile"]
        icon_tile(base, P(tx, ty), ts, ta, u)
    mx, my, md = page.get("map", {}).get(kind, lay["map"])
    map_disc(base, P(mx, my), md, u)
    cx, cy, cw, ca = lay["card"]
    card(base, page["card"], P(cx, cy), cw, ca, u)
    if page.get("card2"):
        cx, cy, cw, ca = lay["card2"]
        card(base, page["card2"], P(cx, cy), cw, ca, u)

    wordmark(base, page, lay, u, th)

    for text, (fx, fy) in zip(page.get("chips", []), lay["chips"]):
        chip(base, text, P(fx, fy), u)
    for text, fx, fy in page.get("hoods", []):
        # keep neighbourhood chips inside the safe band on every canvas
        chip(base, text, P(fx, fy), u, size=26, check=False, pin=True)
    return base.convert("RGB")


def preview(banner: Image.Image) -> Image.Image:
    """The banner as the product page shows it: header, then the band where
    the App Store draws the icon, name and subtitle itself, with the crop
    Apple may apply outlined."""
    w = 1280
    banner = banner.resize((w, int(w * banner.height / banner.width)), Image.LANCZOS)
    band = 260
    img = Image.new("RGB", (w, banner.height + band), (0, 0, 0))
    img.paste(banner, (0, 0))
    d = ImageDraw.Draw(img)
    bh = banner.height
    d.rectangle([w * 0.2, bh * 0.15, w * 0.8, bh * 0.85], outline=(255, 80, 80), width=2)
    ic = Image.open(ICON).convert("RGB").resize((180, 180), Image.LANCZOS)
    m = Image.new("L", ic.size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, 179, 179], radius=40, fill=255)
    img.paste(ic, (50, bh + 40), m)
    d.text((260, bh + 60), "Crease", font=font("Bold", 54), fill=WHITE)
    d.text((260, bh + 130), "Laundry pickup and delivery", font=font("Regular", 32), fill=(150, 150, 155))
    return img


def main() -> int:
    out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1
                       else os.path.expanduser("~/Downloads/ASC-creative-assets/crease"))
    for name, page in PAGES.items():
        kinds = CANVASES if name == "default" else {"header": CANVASES["header"]}
        for kind in kinds:
            w, h = CANVASES[kind]
            img = render(kind, page)
            assert img.mode == "RGB" and img.size == (w, h)
            p = out / name / f"{kind}-{w}x{h}.png"
            p.parent.mkdir(parents=True, exist_ok=True)
            img.save(p, optimize=True)
            print("wrote", p)
            if kind == "header":
                preview(img).save(out / name / "preview-product-page.png")
    return 0


if __name__ == "__main__":
    sys.exit(main())
