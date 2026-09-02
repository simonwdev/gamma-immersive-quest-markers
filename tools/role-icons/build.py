#!/usr/bin/env python3
"""Build the role-glyph atlas (gamedata/textures/ui/iqm_roles.dds) from the
source SVGs in ./svg.

Each glyph is rendered white-on-transparent (so SetTextureColor tints it the
accent colour in game), normalised to a consistent visual size, given a worn
"distressed stencil" look (alpha eroded by a procedural grunge field plus a few
scratches - faded spray-paint on metal), then packed into a grid of 128px
cells. The cell order below MUST match the texture ids in
gamedata/configs/ui/textures_descr/iqm_textures.xml and ROLE_ICONS in
iqm_core.script.

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

# grid cell order (row-major). The role glyphs match iqm_role_<name> texture ids;
# "chevron" is the odd one out -- it is not a role but the hand-in beacon's
# directional arrowhead (texture id iqm_chevron), sharing this atlas because the
# 4x2 grid had exactly one cell spare. It is drawn pointing RIGHT so that a
# SetHeading of 0 means +X, the same convention the leader line uses; the beacon
# rotates it to point down at an on-screen target or outward when clamped to a
# screen edge.
# Row 2 holds the STATE-role glyphs, the ones whose cards are verb phrases
# (REPORT BACK / LOOKING FOR GUIDE / LOOKING FOR WORK / FOR HIRE). Cards don't
# show these - state cards carry a faction emblem or nothing - but the beacon
# does, because with several roles beaconed at once the glyph is the only thing
# telling them apart.
#
# Appending rather than reordering is deliberate: rows 0-1 keep their pixel
# coordinates when the grid grows to 4x3, so every existing texture id in
# iqm_textures.xml stays valid and untouched.
#
# R2.29: handin, trader, medic, mechanic and barman are now rendered from the SAME
# SVGs as ../map-icons/svg, so a waypoint marker in the world carries the mark its
# role's PDA map spot carries - the price tag for a turn-in, and each trade's
# own pictogram. Only the source art is shared, not the rendering: the map atlas wraps
# each glyph in its badge ring with a baked keyline, because a map spot has to stand
# alone on the map, while these stay bare white-on-transparent for SetTextureColor,
# because the waypoint badge already supplies the ground. The tabler originals are kept
# beside them as svg/<name>-tabler.alt. "guide" has no map counterpart (vanilla does not
# map-spot guides), so it keeps its tabler glyph.
#
# R2.56 re-syncs "handin" to the price tag the map has drawn since R2.55, retiring the diamond
# as svg/handin-diamond.alt. It is the shared-source rule's one failure so far and the reason
# that rule is stated everywhere it is: the map's copy was replaced, this one was not, and only
# this build was not rerun -- so the map drew a tag and the beacon drew a diamond for one
# release. Nothing caught it because nothing DREW iqm_role_handin in between (the `target`
# marker went out in R2.46, the `handin` kind came in at R2.55), and no legend sheet covers
# these cells - ../map-icons/extract.py reads map-spot ids, so no iqm_role_* cell is pictured
# in docs/icons at all. ../color-harness now asserts the seven shared SVGs match on both
# sides, which is the check that replaces "remember to rerun both builds".
#
# R2.33 appends "waypoint": the player-placed waypoint's mark, and the first cell here
# whose map counterpart is not a pictogram but a RING -- the four-arc pulse
# modxml_n_iqm_map_icons puts on PAW's paw_task_default_spot. Same argument as R2.29 and
# the same treatment (no distress, keylined); the difference is that the ring is
# generated from the map atlas's own three constants rather than traced from an icon
# set, because no icon set has it. See svg/waypoint.svg.
# R2.46 appends "task": the SELECTED task's marker, and the second cell here whose map
# counterpart is a reticle rather than a pictogram. Same argument and the same treatment
# as "waypoint" -- generated from ../map-icons/build.py's own TASK_* constants, no
# distress, keylined -- and for the same reason: it is exactly the mark the PDA map draws
# on the task you picked (iqm_mapspot_task, which replaces
# ui_inGame2_PDA_icon_Secondary_mission), so the mark you look for through a wall is the
# mark with the bracket round it on the map.
#
# The pair reads as a pair on purpose. Both are broken rings and BOTH gap the CARDINALS;
# what separates them is the gap's WIDTH -- 11 degrees either side for the task, so long
# arcs, against the waypoint's 20, so short ones -- plus the task's inner ring and centre
# crosshair, which the waypoint has neither of. That is the map atlas's own grammar, so
# the two marks are told apart the same way in both views.
# THE WAYPOINT'S GAPS WERE DESCRIBED AS DIAGONAL HERE UNTIL R2.63a and never were: that is
# the map's SELECT frame, which is genuinely the inverse and is a third ring neither of
# these is. Harmless until the gap WIDTH turned out to decide whether a glyph's corners
# clear the arcs (see RING_GEOM in iqm_cards), at which point the note was actively
# misleading about the one property that mattered.
# R2.48 appends "skull": the MUTANT HUNT marker, and it takes the last cell of the
# 4x4 grid. Same argument as R2.29 and the same treatment (no distress, keylined) --
# it is rendered from the SAME svg/skull.svg as ../map-icons, so the mark you look for
# through a wall is the mark the PDA map puts on that task. There is no bounty cell for
# the same reason there is none in the map atlas: a bounty wears the ordinary task
# reticle in red, and the beacon's tint is a runtime table entry, not art.
# R2.55 appends "mail" and with it a FIFTH ROW, which the skull's note above predicted:
# the 4x4 grid was exactly full. It is the delivery role's glyph, shared with
# ../map-icons/svg/mail.svg on the R2.29 rule. The row is appended, never inserted, so
# rows 0-3 keep their origins and every existing iqm_role_* texture id stays valid.
# R2.57 appends "vip", the COMPANION marker's glyph, into the second cell of the row
# "mail" opened. Shared with ../map-icons/svg/vip.svg on the R2.29 rule, and named for the
# art rather than for the consumer because that is what the map calls it: the PDA draws a
# companion as the VIP bust in the companion green (modxml_n_iqm_map_icons points
# ui_pda2_companion_location_spot at iqm_mapspot_vip), so mirroring the map means wearing
# the same bust, not inventing a companion pictogram only this mod would use. Appended,
# never inserted, so every existing iqm_role_* origin is untouched; two cells of this row
# are still spare.
# R2.63 appends "ringtask" into the third cell of that same row: the SELECTED task's
# RING, worn AROUND whatever glyph its kind resolved rather than drawn as a mark of its
# own. It is svg/task.svg's outer arcs with the crosshair dropped, so it is the same
# ../map-icons TASK_* geometry the two cells above already mirror -- the R2.29 rule
# holding for a frame as it does for a glyph. Same treatment as the pair it joins (no
# distress, keylined) and for the same reason: it is a copy of a mark the PDA map draws,
# and a chipped copy of the map's mark is not the map's mark.
#
# WHY THE MARKER NEEDED IT. The selected task used to be told from an unselected one by
# COLOUR -- it wore its kind's green while its neighbour wore the accent -- which broke
# the rule the tint exists to serve (the marker's colour mirrors its map spot's, and the
# map does not tint the task you picked; it draws a BRACKET round it). The ring is that
# bracket, so the distinction moves to the axis that was always free. Appended, never
# inserted: rows 0-3 and the two cells before it keep their origins.
# One cell of this row is still spare.
SRCS = ["trader", "mechanic", "barman", "medic", "guide", "important", "work",
        "chevron",
        "handin", "needguide", "recruit", "hire",
        "routearrow", "waypoint", "task", "skull",
        "mail", "vip", "ringtask"]
CELL, COLS, ROWS, TARGET = 128, 4, 5, 98
W, H = CELL * COLS, CELL * ROWS

# THERE IS DELIBERATELY NO FIT_SCALE HERE, unlike ../map-icons/build.py, and the reason is
# worth writing down because copying that table over is the obvious move and it is wrong.
#
# Over there the hand-in tag needs 0.79 because it is a BARE glyph sitting beside an envelope
# that is wrapped in the task reticle: RETICLE_FIT shrinks the envelope inside its frame, so at
# equal cell size the tag came out 1.6x its weight, in the same green, with only the glyph
# separating them. Here BOTH are bare keylined glyphs rendered to the same TARGET, so that
# asymmetry does not exist and the weights already agree - measured on this atlas, the tag inks
# 46.0% of its cell against the envelope's 50.5% and the skull's 49.9%. Applying the map's
# 0.79 anyway takes the tag to 30.1% and makes it the lightest mark on the sheet, which is the
# very defect the correction exists to prevent, introduced by importing it.
#
# The rule, since this is the second time a per-cell size fudge has been reasoned about: a
# glyph's apparent weight is set by its FRAME, so a correction only transfers between atlases
# when the framing does too. Measure on the sheet you are building.

# Glyphs that skip the distress pass. The worn look is right for a marker drawn
# once at badge size, and wrong for one repeated a dozen times across the ground at
# 4-30 px: at that scale the chips and cracks are the same size as the stroke, so a
# distressed route arrow reads as speckle rather than as an arrow.
#
# The six waypoint-marker glyphs join it (R2.29). They are now the SAME marks the PDA
# map draws (see the note on SRCS), and the point of that is recognition: a chipped,
# eroded copy of the map's mark at 14 px is not the map's mark. The map atlas applies
# no distress either, so this is what keeps the two views actually identical rather
# than merely similar. "important" and "work" keep the worn look - they are card-only
# glyphs now, since neither role can carry a waypoint marker any more.
NO_DISTRESS = {"routearrow", "waypoint", "task", "skull", "mail", "vip",
               "handin", "guide", "trader", "mechanic", "barman", "medic",
               "ringtask"}

# Glyphs that get a BLACK KEYLINE baked into the art, replacing the separate dark-copy
# widget that used to be drawn behind them (R2.31 - see keylined() for why a separate
# copy can never stay aligned). This is the set drawn with no plate behind it: the
# waypoint marker's six role glyphs and its chevron. The cards draw four of these too,
# over their own plate, where a thin dark rim is harmless.
#
# KEY_R is in ATLAS pixels, so what matters is its ratio to the glyph: a role cell is
# 128 px and draws at ~26 screen px at the default marker size on a 1440p screen, i.e.
# ~4.9 atlas px per screen px, so 7 is a ~1.4 px keyline there - and being baked it
# stays that same fraction at every marker size, which the widget copy never did.
# 98 (TARGET) + 2*7 still leaves 8 px of margin inside the cell.
KEYLINE = {"handin", "guide", "trader", "mechanic", "barman", "medic", "chevron",
           "waypoint", "task", "skull", "mail", "vip", "ringtask"}
KEY_R = 7      # keyline radius, atlas px
KEY_A = 0.70   # its alpha, multiplied by the widget's own: matches the old dark copy

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


def disk(r):
    """Offsets inside a radius-r disk - a round dilation kernel. A square one
    (Pillow's MaxFilter) would put square corners on a round glyph's keyline."""
    return [(dx, dy) for dx in range(-r, r + 1) for dy in range(-r, r + 1)
            if dx * dx + dy * dy <= r * r]


def keyline(ga, r):
    """Dilate an alpha channel by r px: max of the alpha over a disk of offsets.
    Keeps the source's antialiasing at the outer edge, so the keyline is soft rather
    than stair-stepped. (Same primitive as ../map-icons/build.py, kept per-script so
    each one runs standalone.) ImageChops.offset WRAPS, so callers must pad first."""
    out = ga
    for dx, dy in disk(r):
        out = ImageChops.lighter(out, ImageChops.offset(ga, dx, dy))
    return out


def keylined(g, r, alpha):
    """A glyph with a black keyline baked around it, on a canvas padded by r.

    WHY BAKED (R2.31). The keyline used to be a second widget: a black copy of the
    glyph at a slightly larger rect, drawn behind. That can never line up, for two
    reasons in the engine, neither of them fixable from script:

      * CUIStaticItem::RenderInternal AlignPixels the top-left of EVERY widget to a
        whole screen pixel, and AlignPixel is iFloor (ui_base.cpp:148). Two widgets at
        different UI positions cross an integer at different moments as the marker
        moves, so the gap between mark and copy flips by a whole pixel while you walk.
      * The bottom-right corner is NOT aligned (RBp = pos + scaled size), so the
        overhang is snapped on two sides and fractional on the other two.

    Baked, the keyline is part of the same quad: concentric by construction, the same
    FRACTION of the glyph at every size, and impossible to desynchronise. It survives
    SetTextureColor because the UI shader multiplies (hud_default.ps:8) and black times
    anything is black; `alpha` here ends up multiplied by the widget's own alpha, so
    0.7 reproduces the 0.7 the separate dark copy used.

    This is the same conclusion iqm_dot reached for the minimap bead, one mod-version
    later than it should have been generalised."""
    pad = r + 2
    w, h = g.size
    canvas = Image.new("RGBA", (w + pad * 2, h + pad * 2), (255, 255, 255, 0))
    canvas.alpha_composite(g, (pad, pad))
    ga = canvas.split()[3]
    black = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ka = keyline(ga, r).point(lambda v: int(v * alpha))
    black.putalpha(ka)
    black.alpha_composite(canvas)      # white glyph over its own black dilation
    return black


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
        if name not in NO_DISTRESS:
            g.putalpha(distress(g.split()[3]))
        if name in KEYLINE:
            g = keylined(g, KEY_R, KEY_A)
            # re-centre: the keyline grew the canvas on all four sides
            ox = (i % COLS) * CELL + (CELL - g.size[0]) // 2
            oy = (i // COLS) * CELL + (CELL - g.size[1]) // 2
        atlas.alpha_composite(g, (ox, oy))
        im.close()
        os.remove(png)
    atlas.save(OUT_PNG)
    subprocess.run(["magick", OUT_PNG, "-define", "dds:compression=none",
                    "-define", "dds:mipmaps=0", OUT_DDS], check=True)
    print("wrote", OUT_DDS)


if __name__ == "__main__":
    sys.exit(main())
