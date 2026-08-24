#!/usr/bin/env python3
"""Print-ready artwork for the two physical QR pieces.

    python3 scripts/make-signage.py

Writes SVG (the editable master), PDF (what a printer wants) and a 300 dpi PNG
(what a proof looks like) into marketing/signage/. Everything here is vector;
the PNG exists only so the artwork can be looked at without a PDF viewer.

Why generated rather than drawn once and committed as a binary:

  * The URL is the whole point of the object, and it is the one thing that
    must never be wrong. Encoding it from the same string that is printed
    underneath the code removes the class of mistake where the artwork says
    one address and the code goes to another.
  * A QR code cannot be edited. Nudging a module in a design tool silently
    destroys it, and the damage is invisible until a stranger's phone fails
    to scan a sticker already on a window.

Two decisions worth keeping:

  ERROR CORRECTION IS 'H' ON BOTH.  The URLs are short enough that the highest
  level still fits in a 29-module version-3 code, so the robustness is free —
  no denser than level M would be. Thirty percent of the code can be lost to
  glare, a thumbprint, a sun-faded corner or a strip of tape and it still
  reads. There is no reason to print a fragile code when the sturdy one is
  the same size.

  THE MODULES ARE PURE BLACK, NOT BRAND GREEN.  Green on white clears the
  contrast a scanner needs, but the window piece is read through glass, often
  with the sky reflected in it, by a phone held at arm's length. Reflection
  eats contrast, and the last thing worth spending it on is a colour nobody
  registers as a colour at that size. The green is everywhere else on the
  piece; the code itself is black.
"""
from __future__ import annotations

import pathlib
import subprocess
import sys

import segno

PT = 72.0  # points per inch — SVG user units throughout, so the PDF is exact.
BLEED = 0.125 * PT  # 9pt. Every printer asks for it; none complain about it.

GREEN = "#1F705C"
GREEN_DEEP = "#15503C"
GREEN_SOFT = "#E7F1ED"
INK = "#17211E"
MUTED = "#5C6B66"
WHITE = "#FFFFFF"
BLACK = "#000000"

FONT = "Helvetica Neue, Helvetica, Arial, sans-serif"

OUT = pathlib.Path(__file__).resolve().parent.parent / "marketing" / "signage"


# --------------------------------------------------------------------------
# pieces of drawing
# --------------------------------------------------------------------------
def esc(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text(x, y, s, size, *, fill=INK, weight=400, anchor="middle", spacing=0.0):
    return (
        f'<text x="{x:.2f}" y="{y:.2f}" font-family="{FONT}" font-size="{size:.2f}" '
        f'font-weight="{weight}" fill="{fill}" text-anchor="{anchor}" '
        f'letter-spacing="{spacing:.2f}">{esc(s)}</text>'
    )


def rect(x, y, w, h, *, fill, rx=0.0, stroke=None, sw=1.0):
    s = f' stroke="{stroke}" stroke-width="{sw}"' if stroke else ""
    return f'<rect x="{x:.2f}" y="{y:.2f}" width="{w:.2f}" height="{h:.2f}" rx="{rx:.2f}" fill="{fill}"{s}/>'


def hanger(cx: float, top: float, height: float, colour: str = WHITE) -> str:
    """The app-icon hanger, lifted from apps/web/public/assets/icon.svg.

    Its ink sits in a 580 x 477 box inside that file's 1024 square (the strokes
    push past the path coordinates, which is why these numbers are not the ones
    in the `d` attributes). Mapping that box explicitly means the mark lands
    where it is asked to land instead of wherever the padding puts it.
    """
    s = height / 477.0
    tx = cx - s * 512.0
    ty = top - s * 253.0
    return (
        f'<g transform="translate({tx:.2f},{ty:.2f}) scale({s:.5f})" fill="none" '
        f'stroke="{colour}" stroke-linecap="round" stroke-linejoin="round">'
        '<path d="M 512 452 L 512 348 A 70 70 0 0 0 372 348 L 372 396" stroke-width="50"/>'
        '<path d="M 512 452 L 258 694 L 766 694 Z" stroke-width="72"/>'
        "</g>"
    )


QUIET_MODULES = 4  # the spec minimum, and the thing an eye never catches


def check_quiet(name: str, gap: float, module: float) -> None:
    """Refuse to write artwork whose code is boxed in too tightly.

    A short quiet zone is the one defect that survives every human review: the
    code looks perfect, decodes on the designer's phone held an inch away in
    good light, and then fails against a dark shop interior or a printed edge.
    Asserting it here means a later nudge to the layout breaks the build
    instead of a thousand stickers.
    """
    have = gap / module
    if have < QUIET_MODULES - 0.01:
        raise SystemExit(
            f"{name}: quiet zone is {have:.2f} modules, needs {QUIET_MODULES}. "
            f"Give the code {QUIET_MODULES * module:.1f}pt of clear space, or make it smaller."
        )


def qr(url: str, cx: float, top: float, size: float) -> tuple[str, float, int]:
    """One <path>, one module per subpath, snapped to a whole-unit grid.

    Drawn as a single filled path rather than a grid of <rect>s so that no
    renderer can leave hairline seams between neighbouring modules — the
    artefact that turns a valid code into an unreadable one at print
    resolution. Returns the markup, the module size, and the module count so
    the caller can report the real printed dimensions.
    """
    code = segno.make(url, error="h", micro=False)
    matrix = [list(row) for row in code.matrix]
    n = len(matrix)
    m = size / n
    parts = []
    for r, row in enumerate(matrix):
        for c, on in enumerate(row):
            if on:
                x = cx - size / 2 + c * m
                y = top + r * m
                parts.append(f"M{x:.3f},{y:.3f}h{m:.3f}v{m:.3f}h-{m:.3f}z")
    return f'<path d="{"".join(parts)}" fill="{BLACK}" shape-rendering="crispEdges"/>', m, n


def svg(w: float, h: float, body: str, title: str, *, mirror: bool = False) -> str:
    """Wrap a body in a document sized in inches, optionally flipped.

    `mirror` exists for decals applied to the inside of glass — see MIRROR_WHY
    at the bottom of this file. It is a transform on the whole drawing rather
    than a second layout, so the two files can never drift apart.
    """
    open_g = f'<g transform="translate({w:.2f},0) scale(-1,1)">' if mirror else ""
    close_g = "</g>" if mirror else ""
    return (
        f'<?xml version="1.0" encoding="UTF-8"?>\n'
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w / PT:.4f}in" height="{h / PT:.4f}in" '
        f'viewBox="0 0 {w:.2f} {h:.2f}">\n<title>{esc(title)}</title>\n'
        f'{open_g}{body}{close_g}\n</svg>\n'
    )


# --------------------------------------------------------------------------
# the two pieces
# --------------------------------------------------------------------------
def register_card(url: str) -> tuple[str, float, float, dict]:
    """4 x 6in card for an acrylic counter holder.

    Portrait 4x6 because that is the size every stock sign holder on the shelf
    takes, which means the object can be replaced for a few dollars and
    reprinted from a photo lab in an hour. A custom size means a custom holder.
    """
    tw, th = 4 * PT, 6 * PT
    w, h = tw + 2 * BLEED, th + 2 * BLEED
    cx = w / 2
    b = [rect(0, 0, w, h, fill=WHITE)]

    # Header, bled off three edges so no white sliver can survive a bad trim.
    b.append(rect(0, 0, w, 90, fill=GREEN))
    b.append(hanger(cx - 52, 26, 40))
    b.append(text(cx - 22, 62, "Crease", 27, fill=WHITE, weight=700, anchor="start", spacing=-0.4))

    b.append(text(cx, 128, "Laundry, picked up", 23, weight=700, spacing=-0.5))
    b.append(text(cx, 154, "and delivered.", 23, weight=700, spacing=-0.5))
    b.append(text(cx, 176, "$2.00 a pound  ·  $20 minimum  ·  Brooklyn", 10.5, fill=MUTED))

    # Tinted band bled off the bottom, with the code on a white panel inside
    # it: the tint is what makes the panel read as "the thing to point at",
    # and the panel is what gives the code its quiet zone.
    b.append(rect(0, 192, w, h - 192, fill=GREEN_SOFT))
    panel = 188.0
    px, py = cx - panel / 2, 204.0
    b.append(rect(px, py, panel, panel, fill=WHITE, rx=18))
    side = 144.0
    code, module, n = qr(url, cx, py + (panel - side) / 2, side)
    check_quiet("counter card", (panel - side) / 2, module)
    b.append(code)

    b.append(text(cx, 414, "Scan to book a pickup", 15, weight=700))
    b.append(text(cx, 431, "creasenyc.com", 11.5, fill=GREEN, weight=700))

    meta = {
        "trim": "4 x 6 in", "bleed": "0.125 in", "canvas": f"{w / PT:.3f} x {h / PT:.3f} in",
        "qr_in": side / PT, "quiet_modules": ((panel - side) / 2) / module, "modules": n,
    }
    return "\n".join(b), w, h, meta


def window_cling(url: str) -> tuple[str, float, float, dict]:
    """5 x 5in die-cut decal for a shop window.

    Square, not portrait: a window sticker is read side-on by somebody walking
    past, and a square puts the maximum code inside the minimum footprint a
    shop owner has to agree to give up.
    """
    tw = th = 5 * PT
    w = h = tw + 2 * BLEED
    cx = w / 2
    r = 34.0
    b = [
        # White flood over the whole bleed area. On clear vinyl this is the
        # layer the printer lays white ink into — see the README. Without it
        # the code is transparent over whatever is inside the shop, and no
        # phone on earth will read it.
        rect(0, 0, w, h, fill=WHITE, rx=r),
        rect(0, 0, w, 70, fill=GREEN),
    ]
    # The header is a straight band over a rounded card, so its own top
    # corners have to be rounded to match or the ink overhangs the die line.
    b[1] = (
        f'<path d="M0,{r:.1f} A{r:.1f},{r:.1f} 0 0 1 {r:.1f},0 H{w - r:.1f} '
        f'A{r:.1f},{r:.1f} 0 0 1 {w:.1f},{r:.1f} V70 H0 Z" fill="{GREEN}"/>'
    )
    # The lockup is centred as a lockup, not as two centred things: the mark
    # sits left of the word, so both offsets are measured from the middle of
    # the pair (mark ~41pt wide, "Crease" ~92pt at this size).
    b.append(hanger(cx - 50, 17, 34))
    b.append(text(cx - 23, 49, "Crease", 24, fill=WHITE, weight=700, anchor="start", spacing=-0.4))

    # The quiet zone here is the white card itself. Vertically it is the
    # tightest dimension on either piece — the band above and the caption
    # below both crowd it — so both gaps are measured, not eyeballed.
    band, size, top = 70.0, 180.0, 100.0
    code, module, n = qr(url, cx, top, size)
    check_quiet("window cling, above code", top - band, module)
    b.append(code)

    caption = 17.0
    scan_baseline = 320.0
    # Cap height is about 0.72 of the point size for this family; the top of
    # the capital S is what actually encroaches, not the baseline.
    check_quiet("window cling, below code", (scan_baseline - caption * 0.72) - (top + size), module)
    b.append(text(cx, scan_baseline, "Scan to book a pickup", caption, weight=700))
    b.append(text(cx, 339, "Wash & fold, collected and returned", 11, fill=MUTED))
    b.append(text(cx, 358, "creasenyc.com", 13, fill=GREEN, weight=700))
    meta = {
        "trim": "5 x 5 in", "bleed": "0.125 in", "canvas": f"{w / PT:.3f} x {h / PT:.3f} in",
        "qr_in": size / PT, "quiet_modules": (top - band) / module, "modules": n,
    }
    return "\n".join(b), w, h, meta


MIRROR_WHY = """Why a mirrored file exists.

Second-surface application — the decal stuck to the inside of the glass, ink
pressed against the pane — is what a shop owner does by default. It cannot be
picked at by a passer-by and the weather never touches it. It also mirrors
everything seen from the street, and a mirrored QR code does not scan: the
finder patterns are the scanner's coordinate system and reversing them
reverses the reading order of every bit. There is no setting on a phone that
undoes it. So the flip has to be in the file, and the file has to say which
one it is, because the two are indistinguishable on a screen at thumbnail
size and identical in every way that a print shop checks."""


def render(stem: str, markup: str) -> None:
    p = OUT / f"{stem}.svg"
    p.write_text(markup)
    for fmt, extra in (("pdf", []), ("png", ["--dpi-x", "300", "--dpi-y", "300"])):
        subprocess.run(
            ["rsvg-convert", "-f", fmt, *extra, "-o", str(OUT / f"{stem}.{fmt}"), str(p)],
            check=True,
        )


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    reg_url = "https://creasenyc.com/r"
    win_url = "https://creasenyc.com/w"

    card, cw, ch, card_meta = register_card(reg_url)
    cling, ww, wh, cling_meta = window_cling(win_url)

    render("crease-counter-card-4x6", svg(cw, ch, card, "Crease counter card 4x6"))
    render("crease-window-cling-5x5", svg(ww, wh, cling, "Crease window cling 5x5"))
    render(
        "crease-window-cling-5x5-reverse",
        svg(ww, wh, cling, "Crease window cling 5x5 (reversed for inside-glass)", mirror=True),
    )

    for name, url, meta in (
        ("counter card", reg_url, card_meta),
        ("window cling", win_url, cling_meta),
    ):
        print(f"{name}: {url}")
        print(f"  trim {meta['trim']} + {meta['bleed']} bleed  ->  {meta['canvas']} artwork")
        print(f"  code {meta['modules']}x{meta['modules']} modules, {meta['qr_in']:.2f} in wide, "
              f"ECC H, {meta['quiet_modules']:.1f}-module quiet zone")
    print(f"\nwritten to {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
