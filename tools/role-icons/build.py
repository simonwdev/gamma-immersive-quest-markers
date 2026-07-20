#!/usr/bin/env python3
"""Build the role-glyph atlas (gamedata/textures/ui/iqm_roles.dds) from the
source SVGs in ./svg.

Each glyph is rendered white-on-transparent (so SetTextureColor tints it the
accent colour in game), normalised to a consistent visual size, given a worn
"distressed stencil" look (alpha eroded by a procedural grunge field plus a few
scratches - faded spray-paint on metal), then packed into a 4x2 grid of 128px
cells. The cell order below MUST match the texture ids in
gamedata/configs/ui/textures_descr/iqm_textures.xml and ROLE_ICONS in
iqm_markers.script.

Requires: Pillow, and ImageMagick (`magick`) on PATH for SVG->PNG and PNG->DDS.
Run from this directory:  python build.py
Tune the look with the DISTRESS / FLOOR / SCRATCHES constants.
"""
import math, os, random, subprocess, sys
from PIL import Image, ImageFilter, ImageChops, ImageOps, ImageDraw

HERE   = os.path.dirname(os.path.abspath(__file__))
SVGDIR = os.path.join(HERE, "svg")
OUT_PNG = os.path.join(HERE, "iqm_roles.png")
OUT_DDS = os.path.normpath(os.path.join(
    HERE, "..", "..", "gamedata", "textures", "ui", "iqm_roles.dds"))

# grid cell order (row-major). Matches iqm_role_<name> texture ids.
SRCS = ["trader", "mechanic", "barman", "medic", "guide", "important"]
CELL, COLS, ROWS, TARGET = 128, 4, 2, 98
W, H = CELL * COLS, CELL * ROWS

# --- distress controls -------------------------------------------------------
# The worn look comes from HARD alpha cutouts (chipped/flaked paint), not from
# fading alpha down - smooth fades just read as uneven brightness. Edges are
# chewed by a grunge field, and a few cracks are cut clean through the strokes.
EDGE_EAT   = 3     # how far in from the stroke edge can be eaten (odd px; larger = more)
DAMAGE_LVL = 190   # grunge threshold: lower = more/bigger chips bitten out of the edges
SPECKLE    = 246   # interior pinhole threshold: higher = fewer tiny holes (sparse on filled shapes)
CRACKS     = 7     # thin cracks cut clean across the sheet
SEED       = 1917  # fixed so the atlas is reproducible


def render_svg(name):
    """SVG -> white-on-transparent 128px PNG via ImageMagick."""
    src = os.path.join(SVGDIR, name + ".svg")
    dst = os.path.join(HERE, "_" + name + ".png")
    subprocess.run(["magick", "-background", "none", "-density", "400", src,
                    "-resize", "128x128", "-channel", "RGB",
                    "-fill", "white", "-colorize", "100", "+channel", dst],
                   check=True)
    return dst


def value_noise(cells_x):
    cy = max(1, round(cells_x * H / W))
    small = Image.new("L", (cells_x, cy))
    small.putdata([random.randint(0, 255) for _ in range(cells_x * cy)])
    return small.resize((W, H), Image.BILINEAR)


def bites_mask():
    """Hard 'chip' mask (255 = paint gone). High-freq grunge, thresholded so the
    holes have crisp edges - only lightly softened so they don't turn to fuzz."""
    n = ImageOps.autocontrast(Image.blend(value_noise(70), value_noise(150), 0.5))
    m = n.point(lambda v: 255 if v > DAMAGE_LVL else 0)
    return m.filter(ImageFilter.GaussianBlur(0.5))


def speckle_mask():
    """Sparse interior pinholes (255 = hole), independent of the edge bites."""
    n = ImageOps.autocontrast(value_noise(200))
    return n.point(lambda v: 255 if v > SPECKLE else 0)


def crack_mask():
    """A few thin cracks (255 = cut) that break clean through the strokes."""
    cr = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(cr)
    for _ in range(CRACKS):
        x1, y1 = random.randint(0, W), random.randint(0, H)
        ang, ln = random.uniform(0, math.pi), random.randint(16, 70)
        d.line([x1, y1, int(x1 + math.cos(ang) * ln), int(y1 + math.sin(ang) * ln)],
               fill=255, width=random.choice((1, 1, 2)))
    return cr.filter(ImageFilter.GaussianBlur(0.4))


def distress(ga):
    """Chew the edges and cut cracks out of one glyph's alpha (hard, not faded)."""
    box = ga.getbbox()
    if not box:
        return ga
    x0, y0, x1, y1 = box
    # protect the stroke's core; expose only a rim EDGE_EAT px wide to the bites
    core = ga.filter(ImageFilter.MinFilter(EDGE_EAT))
    rim = ImageChops.subtract(ga, core)
    bites = ImageChops.multiply(bites_mask().crop((x0, y0, x1, y1)), rim)
    speck = ImageChops.multiply(speckle_mask().crop((x0, y0, x1, y1)),
                                ga.crop((x0, y0, x1, y1)))
    crack = ImageChops.multiply(crack_mask().crop((x0, y0, x1, y1)),
                                ga.crop((x0, y0, x1, y1)))
    dmg = ImageChops.lighter(ImageChops.lighter(bites, speck), crack)
    out = ga.copy()
    out.paste(ImageChops.subtract(ga.crop((x0, y0, x1, y1)), dmg), (x0, y0))
    return out


def main():
    random.seed(SEED)
    atlas = Image.new("RGBA", (W, H), (255, 255, 255, 0))
    for i, name in enumerate(SRCS):
        png = render_svg(name)
        im = Image.open(png).convert("RGBA")
        g = im.crop(im.split()[3].getbbox())
        w, h = g.size
        s = TARGET / max(w, h)
        g = g.resize((max(1, round(w * s)), max(1, round(h * s))), Image.LANCZOS)
        ox = (i % COLS) * CELL + (CELL - g.size[0]) // 2
        oy = (i // COLS) * CELL + (CELL - g.size[1]) // 2
        g.putalpha(distress(g.split()[3]))
        atlas.alpha_composite(g, (ox, oy))
        im.close()
        os.remove(png)
    atlas.save(OUT_PNG)
    subprocess.run(["magick", OUT_PNG, "-define", "dds:compression=none",
                    "-define", "dds:mipmaps=0", OUT_DDS], check=True)
    print("wrote", OUT_DDS)


if __name__ == "__main__":
    sys.exit(main())
