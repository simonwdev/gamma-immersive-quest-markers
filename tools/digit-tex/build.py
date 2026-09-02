#!/usr/bin/env python3
"""Build the waypoint marker's range readout as SPRITES (gamedata/textures/ui/iqm_digits.dds).

WHY this exists rather than a font
---------------------------------
A CGameFont renders at a height picked from a resolution BUCKET and nothing scales it
per widget: `Out()` takes screen coordinates, the virtual-UI scale is not applied to the
glyphs, and CGameFont::SetHeight is not bound to Lua. So an engine font's readout cannot
follow the marker's own size, and the size it does have is one of eleven fixed values --
`small` (stat_font -> ui_font_hud_01) is the smallest of them, and at >=1440p that is a
16 px cell, which is still too big beside a 14-unit glyph. There is no twelfth font: an
unknown name in the XML is an R_ASSERT, i.e. a CTD.

Drawn as sprites the readout is just more statics, so it scales with `marker size` like
everything else on the badge and can be as small as the player asks for.

Layout: 64x128 cells, eight per row, in a 512x256 sheet.
  row 0   digits 0-7
  row 1   digits 8, 9, then the metre suffix "m" in a 128-wide cell at x=128

Every digit is declared with the SAME rect size -- the tabular advance box, centred on
the digit's own ink -- so the numbers align like text and a 3-digit range does not jitter
as it counts down. "m" gets its own narrower-and-shorter box plus a baseline offset,
because it is an x-height glyph sitting on the same baseline as the figures.

The script prints the textures_descr rects and the Lua width table; both are pasted, not
read at runtime. Rerun it and re-paste if the font or the metrics change.

Requires: Pillow, and ImageMagick (`magick`) on PATH for the PNG->DDS step.
Run from this directory:  python build.py
"""
import os, subprocess, sys
from PIL import Image, ImageChops, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_PNG = os.path.join(HERE, "iqm_digits.png")
OUT_DDS = os.path.normpath(os.path.join(
    HERE, "..", "..", "gamedata", "textures", "ui", "iqm_digits.dds"))

CELL, COLS, ROWS = 128, 4, 4
W, H = CELL * COLS, CELL * ROWS
CAP = 104          # px of cap height a digit is rendered to
BASELINE = 116     # px from the render canvas top to the baseline

# Black keyline baked around every glyph, replacing the separate shadow widget the
# readout used to draw behind each character (R2.31). A second widget can never stay
# aligned with the first: CUIStaticItem::RenderInternal AlignPixels each widget's
# top-left to a whole screen pixel with iFloor (ui_base.cpp:148), so the offset between
# a glyph and its copy flips by a pixel as the marker moves, and the bottom-right corner
# is not aligned at all, so the overhang is uneven even standing still. Baked, the
# keyline is part of the same quad. It survives the accent tint because the UI shader
# multiplies (hud_default.ps:8).
#
# KEY_R is atlas px and what matters is its ratio to the DECLARED RECT, since that rect
# is what gets drawn at the readout height: a digit's rect is CAP + 2*KEY_R = 126 px tall
# and draws at ~10 screen px, so 11 atlas px is a ~0.9 px keyline. The keyline is inside
# the rect, so the figures themselves are 104/126 of the readout height.
KEY_R = 11
KEY_A = 0.72

# Bahnschrift is DIN 1451 - condensed, geometric, and what a range readout on a military
# HUD is actually set in. consola/arialbd are fallbacks so the build works on a machine
# without it; both are wider, which only loosens the number a little.
FONTS = ("bahnschrift.ttf", "consola.ttf", "arialbd.ttf", "DejaVuSans-Bold.ttf")
GLYPHS = "0123456789m"


def load_font(px):
    for name in FONTS:
        try:
            f = ImageFont.truetype(name, px)
        except OSError:
            continue
        try:  # Bahnschrift is variable; ask for the condensed instance explicitly
            f.set_variation_by_name("SemiBold Condensed")
        except Exception:
            pass
        return f, name
    raise SystemExit("no usable font found")


def fit_cap_height(target):
    """Point size whose CAP height (measured on '0') is `target` px."""
    px = target
    for _ in range(40):
        f, name = load_font(px)
        box = f.getbbox("0")           # (x0, y0, x1, y1) from the text origin
        cap = box[3] - box[1]
        if abs(cap - target) <= 1:
            return f, name, px
        px = max(4, round(px * target / max(1, cap)))
    return f, name, px


def render(ch, font):
    """One glyph, white on transparent, on its own canvas with a known baseline."""
    pad = 40
    im = Image.new("RGBA", (CELL * 2 + pad * 2, CELL * 2), (255, 255, 255, 0))
    d = ImageDraw.Draw(im)
    # anchor "ls" = left, baseline: puts the glyph's baseline exactly on BASELINE
    d.text((pad, BASELINE), ch, font=font, fill=(255, 255, 255, 255), anchor="ls")
    return im, im.split()[3].getbbox()


def disk(r):
    """Offsets inside a radius-r disk - a round dilation kernel."""
    return [(dx, dy) for dx in range(-r, r + 1) for dy in range(-r, r + 1)
            if dx * dx + dy * dy <= r * r]


def keyline(ga, r):
    """Dilate an alpha channel by r px: max over a disk of offsets, so the source's
    antialiasing survives at the outer edge. (Same primitive as ../map-icons/build.py
    and ../role-icons/build.py, copied so each script runs standalone. offset() WRAPS,
    so the caller pads first.)"""
    out = ga
    for dx, dy in disk(r):
        out = ImageChops.lighter(out, ImageChops.offset(ga, dx, dy))
    return out


def main():
    font, fname, px = fit_cap_height(CAP)
    print("font: %s at %d px" % (fname, px))

    inks = {}
    for ch in GLYPHS:
        im, box = render(ch, font)
        inks[ch] = (im, box)

    # The tabular advance box: widest digit ink plus a little side bearing, and the full
    # cap height. Every digit is declared at this size (plus the keyline), which is what
    # keeps a counting-down range from shuffling sideways as its digits change.
    dw = max(inks[c][1][2] - inks[c][1][0] for c in "0123456789")
    adv_w, adv_h = dw + 8, CAP
    # the DECLARED rect is the ink box grown by the keyline on all four sides
    box_w, box_h = adv_w + KEY_R * 2, adv_h + KEY_R * 2
    print("digit ink %dx%d -> declared %dx%d (keyline %d)"
          % (adv_w, adv_h, box_w, box_h, KEY_R))

    atlas = Image.new("RGBA", (W, H), (255, 255, 255, 0))
    rects, ratios = [], {}

    def place(ch, idx, bw, bh, ink_w, ink_h):
        cx, cy = (idx % COLS) * CELL, (idx // COLS) * CELL
        rx, ry = cx + (CELL - bw) // 2, cy + (CELL - bh) // 2   # rect, centred in cell
        im, ink = inks[ch]
        # The ink is centred in its own ink box, which is centred in the declared rect
        # (the keyline is symmetric), so centring the ink in the rect IS both. Baseline
        # alignment between the figures and the shorter "m" is carried by the rect
        # HEIGHTS and by GLYPH_DY in script, not by padding here.
        gx = rx + (bw - ink_w) // 2 - ink[0]
        gy = ry + (bh - ink_h) // 2 - ink[1]
        glyph = Image.new("RGBA", (W, H), (255, 255, 255, 0))
        glyph.alpha_composite(im, (gx, gy))
        ga = glyph.split()[3]
        black = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        black.putalpha(keyline(ga, KEY_R).point(lambda v: int(v * KEY_A)))
        black.alpha_composite(glyph)          # white glyph over its own black dilation
        atlas.alpha_composite(black)
        rects.append((ch, rx, ry, bw, bh))

    for i, ch in enumerate("0123456789"):
        place(ch, i, box_w, box_h, adv_w, adv_h)
        ratios[ch] = (box_w / box_h, 0.0)

    # "m" has no ascender, so it gets its own shorter box and is dropped to the shared
    # baseline in script. Its keyline is the same width, so the two read as one line.
    mi = inks["m"][1]
    mw, mh = mi[2] - mi[0], mi[3] - mi[1]
    mbw, mbh = mw + KEY_R * 2, mh + KEY_R * 2
    place("m", 10, mbw, mbh, mw, mh)
    # How far DOWN the m's rect starts, as a fraction of a digit's rect height. Both
    # rects are the ink box grown by the same KEY_R, so the keylines cancel and the drop
    # is just the gap between the cap top and the x-height top.
    ratios["m"] = (mbw / box_h, mbh / box_h, (CAP - mh) / box_h)

    atlas.save(OUT_PNG)
    subprocess.run(["magick", OUT_PNG, "-define", "dds:compression=none",
                    "-define", "dds:mipmaps=0", OUT_DDS], check=True)
    print("wrote", OUT_DDS)

    print("\n--- paste into gamedata/configs/ui/textures_descr/iqm_textures.xml ---")
    print('\t<file name="ui\\iqm_digits">')
    for ch, x, y, w, h in rects:
        tid = '"iqm_digit_%s"' % ch
        print('\t\t<texture id=%-16s x="%d" y="%d" width="%d" height="%d" />'
              % (tid, x, y, w, h))
    print("\t</file>")

    print("\n--- paste into iqm_core.script (RD_G) ---")
    print("\tw   = %.4f,  -- a digit's width / the readout height" % ratios["0"][0])
    print("\tmw  = %.4f,  -- the suffix's width" % ratios["m"][0])
    print("\tmh  = %.4f,  -- ...and its height" % ratios["m"][1])
    print("\tmdy = %.4f,  -- ...so it drops by this to share the baseline" % ratios["m"][2])


if __name__ == "__main__":
    sys.exit(main())
