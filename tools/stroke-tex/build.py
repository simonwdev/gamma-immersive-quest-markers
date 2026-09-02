#!/usr/bin/env python3
"""Build the route stroke texture (gamedata/textures/ui/iqm_stroke.dds).

The route is drawn as a run of heading-rotated quads (IqmCards:place_seg). Until
R2.14 those quads sampled `iqm_white_box` -- a solid opaque region -- with a
second, larger black copy behind each one standing in for an outline. On screen
that is a flat sticker with a hard keyline: the long edges alias into visible
stair-steps, and the keyline's weight reads differently at every distance.

This texture replaces the solid fill. It is a CROSS-SECTION, not a picture:

  * horizontally uniform, so stretching it along a segment of any length
    changes nothing (the whole point of the quad trick);
  * vertically an alpha profile -- opaque core, smoothstep ramp to zero at the
    top and bottom edges. The rect's HEIGHT is the stroke's thickness, so the
    ramp lands on the two long edges and feathers them.

The feather is a FRACTION of the thickness rather than a fixed pixel count,
which is the one decision worth explaining. A fixed-px feather is what a
draughtsman wants, but the thickness here spans ~2.5 px at 60 m to ~90 px at
the near end of the stroke, and nothing in the UI layer can express "2 px of
this rect". Proportional turns out to be what you want anyway:

  * far, thin segments sample only a row or two either side of the centre, all
    of it inside the opaque core, so they stay crisp rather than dissolving;
  * near, wide segments get a soft shoulder, which is what a band of paint on
    wet concrete actually looks like -- and it is exactly where the old hard
    edge aliased worst.

The SHADOW copy samples the same texture at a slightly larger rect, tinted
black at low alpha, so the outline became a soft halo for free -- no second
asset, and the halo's softness tracks the stroke's weight automatically.

White RGB throughout: the alpha carries the shape and the colour comes from
SetTextureColor, the same contract iqm_circle / iqm_glow / iqm_shadow use.

Requires: Pillow, and ImageMagick (`magick`) on PATH for PNG->DDS.
Run from this directory:  python build.py
"""
import math
import os
import re
import subprocess
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
TEX = os.path.normpath(os.path.join(HERE, "..", "..", "gamedata", "textures", "ui"))

# 64x64. Width is irrelevant for the stroke (its profile is constant along it) but a
# square power-of-two keeps the engine's loader on its happy path; 64 steps is more
# than enough resolution for ramps this shallow.
W, H = 64, 64

# Fraction of the HEIGHT each edge's ramp occupies. 0.11 puts the half-alpha
# point about 5% in from the edge, so a 90 px near segment gets a ~10 px
# shoulder and a 3 px far one is untouched (its sample rows all land in the
# core). Raising this softens the near end and starts to thin the far end.
#
# 0.11 -> 0.04 (R2.26). The proportional argument above is still right -- what was
# wrong was the value. At 0.11 a near sprite carries a ~10 px shoulder on each long
# edge, which is most of what read as "the route is blurry": it is not the projection
# or the filtering, it is that the artwork's own edge is ten pixels wide by the time it
# is drawn a metre from your eye. 0.04 is a ~3 px shoulder there, still a full sample
# row or two of ramp on a far sprite, so the far end is no more prone to crawling than
# it was. Judged in tools/route-preview rather than in game, which is why it moved at
# all -- see the note in that tool about how many sessions the old loop cost.
#
# RTE.FPAD in iqm_core.script must match this. It is the margin place_mark leaves
# around the glyph's box, and the two are the same number for the same reason.
FEATHER = 0.04

# The CHEVRON ARM (iqm_arm) adds a taper along its LENGTH, which the stroke must not
# have -- a stroke segment butts against the next one and a taper would leave a gap at
# every joint. An arm butts against nothing: it ends in mid-air at the outer tip, and it
# meets its partner at the chevron's point. Both were square cuts, which is most of why
# a chevron read as two crossing slabs rather than as a mark.
#
# BOTH ends ramp. u = 0 is the chevron's POINT (place_arms draws tip -> outer end) and
# u = 1 is the outer end.
#
# The tip ramp came off in R2.18, on the argument that the apex should be where the mark is
# strongest and fading it there is what made it read as two bars meeting. Three attempts at
# filling the wedge between the two end cuts later (an overlap, an asymmetric mitre, and the
# whole mark as one texture) it goes back on, because it turns out to be the best of them:
# there is no way to make two rectangles meet cleanly at a point, and a SOFT end asks no
# questions about where exactly it stops. The tip ramp is smaller than the tail's -- enough
# to take the corner off the cut, not enough to hollow the point.
ARM_TIP = 0.14
ARM_TAIL = 0.34

# --------------------------------------------------------------------------- the mark
# iqm_mark is the WHOLE chevron as one picture (R2.20), which is what finally gets the
# apex right. Two arms drawn as two quads cannot meet cleanly at a point: overlap them
# and the doubled alpha reads as a light spot (a second pass over the same pixels leaves
# a(2-a), not a), butt them and the wedge between their end cuts reads as a notch. Both
# were shipped and both were visible. Inside one texture the two arms are unioned by
# max() before anything is blended, so the apex is a solid mitred point and there is no
# seam of either kind.
#
# The renderer lands this on the ground by measuring the mark's projected extent along
# travel and across it, and setting the rect to those two numbers (IqmCards:place_mark).
# A heading-rotated static is rotate-then-uniform-scale, so a non-square rect holding
# this picture IS "squash the mark along its own axis, then rotate" -- the foreshortening,
# in one quad. Which is why the artwork must be drawn in the MARK's own metric, not in
# pixels: the texture is stretched by whatever the projection says.
#
# These four mirror RTE.alen / awide / aw in iqm_core.script and the geometry below
# mirrors place_mark's box. Change one, change both -- there is no way to read the other
# from here, and a mismatch shows up as the glyph sitting slightly off its own box.
# Resized in R2.26, when the one-texture glyph stopped being an alternative rendering of
# the band's chevron and became a route design of its own (route_style 4, the marks with
# no stroke under them). Once the marks ARE the route they have to carry it alone, and
# the size that read as a decoration riding a line reads as too small without one.
#
#   MARK_ARM  0.22 -> 0.38   bolder. The two-quad styles cannot follow it there: their
#                            apex wedge scales with arm thickness, and by 0.38 it is a
#                            visible notch (R2.22's "best of the bad options" runs out).
#                            This glyph has no wedge -- the arms are unioned by max()
#                            inside one texture -- so thickness costs it nothing.
#   MARK_WIDE 1.15 -> 1.85   longer ARMS. Arm length is sqrt(hl^2 + hw^2), so the width
#                            across the back is what lengthens them; MARK_LEN is how far
#                            the mark reaches ALONG travel and is unchanged, which is
#                            what keeps this a chevron rather than a dart.
#   MARK_TAIL 0.34 -> 0.05   the outer ends stop dissolving. At 0.34 a third of each arm
#                            was ramp, and on arms this long that is most of what you
#                            look at. Effectively a square cut, with the feather above
#                            taking the corner off it.
# R2.30 scaled all three down 20% (0.85/1.85/0.38) after the size was judged in game.
# Because the SAME factor was applied to all three the box stays exactly similar, the
# picture drawn into it is unchanged, and iqm_mark.dds did not need regenerating -- but
# these still have to track RTE.alen/awide/aw in iqm_core.script or the next rebuild
# would draw the glyph into a box the game no longer measures.
# MARK_LEN alone was flattened 0.68 -> 0.50 in R2.31: it is the mark's depth along
# travel and so the only dimension the keystone error scales with. Revert = put 0.68
# back here and in RTE.alen, then re-run this script.
MARK_LEN = 0.50     # m, tip to the back of the arms, along travel
MARK_WIDE = 1.48    # m, across the back, tip to tip
MARK_ARM = 0.304    # m, thickness of an arm
MARK_TAIL = 0.05    # fraction of an arm's length the outer end fades over
MARK_PX = 256       # the mark is the biggest thing on screen at the near end

# The keyline's weight, as a fraction of an arm's thickness -- so it holds its PROPORTION
# at every distance instead of its pixel count, which is the reason for baking it at all.
# 0.09 of a 0.38 m arm is ~3.4 cm of ground -- about a sixth of the arm once both
# edges are counted, which is the weight iqm_dot's baked ring settled on. A definite edge
# on a near mark, and under a pixel on a far one, where it disappears rather than eating
# the glyph. Heavier than this and the mark stops being a coloured chevron with an
# outline and becomes an outline with some colour in it.
#
# RGB is NOT uniform in iqm_mark any more, so it no longer shares the "white ink, alpha
# carries the shape" contract of iqm_stroke and iqm_arm. It survives tinting because
# SetTextureColor MULTIPLIES: black times the route colour is still black.
MARK_RIM = 0.09

# --------------------------------------------------------------------------
# THE LOOK (R2.33) -- the five numbers that decide whether a mark reads as paint
# --------------------------------------------------------------------------
# All five are BAKED, so this block is the whole tuning surface: change a number, re-run
# this script, reload. Nothing in the mod reads them except SPAD (see below), and every
# one of them reverts to the pre-R2.33 flat sticker at the value in its comment.
#
# They exist because the R2.33 screenshot showed the geometry landing and the marks still
# reading as printed ON the image: flat interior, an edge that matches the floor, and
# nothing underneath. Chosen from tools/route-preview's comparison sheet -- the four
# together, at amber -- rather than one at a time in game.

# HOW MUCH THE PAINT IS WORN, 0 = the flat fill this replaced.
# Alpha is thinned only where the noise dips below MARK_WEAR_THR, so most of the mark
# stays solid and what you read is scuffing rather than a pattern laid over the glyph.
MARK_WEAR = 0.45
MARK_WEAR_THR = 0.44
MARK_WEAR_SEED = 11

# THE KEYLINE, AT BOTH ENDS. `ink` multiplies the route colour, so a rim of 0 is black
# whatever the colour is -- which is invisible on dark concrete, a black edge on a black
# floor, and was the actual reason the shipped keyline did not read. Inverted here: the
# rim goes to FULL colour and the BODY sinks, so the outline is the brightest part of the
# mark. Works on lit ground and dark ground both. Revert = RIM_INK 0, BODY_INK 1.
MARK_RIM_INK = 1.00
MARK_BODY_INK = 0.78

# THE CONTACT SHADOW, baked outside the outline at ink 0 -- black survives the tint,
# because SetTextureColor multiplies. It cannot be a second widget: R2.31 established
# that a scaled copy of a glyph whose box is deliberately asymmetric emerges on the
# leading edge only. Baked, it is concentric by construction.
#
# IT COSTS KEYSTONE. The halo has to live inside the mark's rect, so the footprint grows
# by MARK_SHADOW_W/2 of an arm on every side -- and the affine residual scales with
# footprint DEPTH and nothing else (R2.31). For chev50 that is a depth:width ratio of
# 0.50 -> 0.56, about 24% -> 27% of the mark's width at 5 m. Paid knowingly: R2.33's
# lead-in stopped that residual being SWEPT as you strafe, which is what made it visible.
# MARK_SHADOW_W is the dial if it ever reads as too much. Revert = MARK_SHADOW 0.
MARK_SHADOW = 0.45
MARK_SHADOW_W = 0.75

# THE CAMO PATTERN (R2.40), asked for directly and arriving with the olive tint it goes
# with. 0 = the flat fill this replaces; the mark then reads exactly as it did.
#
# IT IS BAKED INTO THE INK, NOT THE ALPHA, and that is the whole design. The mod paints
# every mark with ONE colour through SetTextureColor, which MULTIPLIES -- so the texture
# cannot introduce a second hue, only darker and lighter patches of whatever the player
# picked. That turns out to be what disruptive pattern is: real DPM is one garment dyed in
# several values, and the shape-breaking comes from the values, not from the hues. Baking
# it into alpha instead would have punched holes in the paint, which is the WEAR treatment
# above and reads as a worn stencil rather than as camouflage.
#
# WHY IT EARNS ITS COST. The route went back to olive in R2.40, and the objection to olive
# on record (see route_r in iqm_core.script) is that it sits at the ground's own value
# and so reads as a stain. A flat fill has nothing but its value to be found by. A patterned
# one has internal contrast at a scale the ground does not carry, and the keyline stays at
# full tint around the whole outline -- so the mark is found by its edge and its pattern
# first and its brightness second, which is the cue a wet concrete floor cannot imitate.
#
# THE THREE LEVELS are multipliers on the BODY ink only; the rim is untouched and stays the
# brightest thing on the mark. MARK_CAMO scales the whole spread toward flat, so it is the
# one dial. At 0.90 the darkest patch sits at about two thirds of the body and the pattern
# reads as pattern; the mark's mean ink is 0.85, so a distant mark -- a few pixels, with
# nothing on it to read -- comes out ~15% darker than a flat one and no more.
#
# 0.55 WAS TRIED FIRST AND WAS TOO TIMID: it compresses the three levels to 11% apart,
# which renders as mottling, i.e. as a dirty mark rather than a patterned one. Judged by
# compositing the built cell over dark ground at the route tint, which is the only way to
# see it -- the atlas itself is near-white ink on transparency and shows nothing.
#
# THE CELL COUNTS are the pattern's SCALE and are the number most worth getting right. The
# wear field above uses 22 and 64, which is grain; camo blobs have to be a fraction of the
# GLYPH, not of the surface, or the mark just looks dirty. At 6 and 13 over a 256 px cell
# the coarse blobs land at roughly a third of the mark's width and the fine ones at an
# eighth -- two scales, which is what stops it reading as a single splodge.
MARK_CAMO = 0.90
MARK_CAMO_LEVELS = (1.00, 0.80, 0.62)
MARK_CAMO_CELLS = (6, 13)
MARK_CAMO_SEED = 29
# Where the field is cut into those levels, and how hard the cut is. Camo has hard edges,
# but a hard edge in a texture that is then minified aliases -- EDGE is a narrow ramp in
# field units, about a pixel and a half at 256, which keeps the boundary crisp to look at
# and well-behaved under the mip filter.
MARK_CAMO_CUTS = (0.42, 0.66)
MARK_CAMO_EDGE = 0.030


def shadow_pad(arm=None):
    """How far outside the true outline the baked halo reaches, in mark metres.

    mark_alpha's edge ramp reaches pad/2 outside the boundary, so passing a fat pad IS a
    soft dilation -- the shape's own distance field reused, rather than a blur of the
    picture. RTE.SPAD in iqm_core.script mirrors this as a fraction of `aw`, because
    the renderer has to measure the same box it was drawn into; check_shapes_match_mod
    refuses to build on a disagreement.
    """
    arm = MARK_ARM if arm is None else arm
    return (MARK_SHADOW_W * 0.5 * arm) if MARK_SHADOW > 0 else 0.0


def noise_field(size, seed, cells):
    """One octave of value noise, as a `size` square of floats in 0..1."""
    import random
    from PIL import ImageFilter
    rnd = random.Random(seed)
    small = Image.new("L", (cells, cells))
    small.putdata([rnd.randrange(256) for _ in range(cells * cells)])
    big = small.resize((size, size), Image.BICUBIC).filter(ImageFilter.GaussianBlur(0.6))
    px = big.load()
    return [[px[i, j] / 255.0 for i in range(size)] for j in range(size)]


def wear_field(size, seed=None):
    """Two octaves, normalised to 0..1. Low values are where the paint has gone.

    The frequencies are the whole difference between worn paint and camouflage. At 9 and
    27 cells the first attempt gave soft blotches the size of the glyph's own arms, which
    read as moss; paint wears at the scale of the aggregate under it, so both octaves are
    far finer than the shape they sit on.
    """
    seed = MARK_WEAR_SEED if seed is None else seed
    a = noise_field(size, seed, 22)         # thin and thick across the stroke
    b = noise_field(size, seed + 1, 64)     # the grain of the aggregate under it
    lo, hi = 1e9, -1e9
    out = [[0.0] * size for _ in range(size)]
    for j in range(size):
        for i in range(size):
            v = 0.62 * a[j][i] + 0.38 * b[j][i]
            out[j][i] = v
            lo, hi = min(lo, v), max(hi, v)
    span = (hi - lo) or 1.0
    for j in range(size):
        for i in range(size):
            out[j][i] = (out[j][i] - lo) / span
    return out


def camo_field(size, seed=None):
    """The disruptive pattern, as a `size` square of BODY-INK MULTIPLIERS.

    Two octaves of the same value noise the wear field uses, at far coarser cells, cut
    into the three levels of MARK_CAMO_LEVELS. Returns the multiplier directly rather than
    a level index, so the caller has nothing to interpret.

    Also returns the area fraction each level covers, because "did the pattern come out"
    is not a thing you can see in a constant -- a cut in the wrong place gives a field
    that is 95% one level, which is a flat mark with a smudge on it and looks like a bad
    render rather than a bad number. build_marks prints them and refuses a degenerate one.
    """
    seed = MARK_CAMO_SEED if seed is None else seed
    c1, c2 = MARK_CAMO_CELLS
    a = noise_field(size, seed, c1)
    b = noise_field(size, seed + 1, c2)
    lo, hi = 1e9, -1e9
    v = [[0.0] * size for _ in range(size)]
    for j in range(size):
        for i in range(size):
            t = 0.60 * a[j][i] + 0.40 * b[j][i]
            v[j][i] = t
            lo, hi = min(lo, t), max(hi, t)
    span = (hi - lo) or 1.0
    l0, l1, l2 = MARK_CAMO_LEVELS
    t1, t2 = MARK_CAMO_CUTS
    e = MARK_CAMO_EDGE
    out = [[1.0] * size for _ in range(size)]
    area = [0, 0, 0]
    for j in range(size):
        for i in range(size):
            t = (v[j][i] - lo) / span
            # Two independent ramps, summed: below t1 the level is l0, between the cuts
            # l1, above t2 l2. Written as a blend rather than as a branch so the boundary
            # carries the ramp instead of a step.
            s1 = smoothstep((t - t1) / e + 0.5)
            s2 = smoothstep((t - t2) / e + 0.5)
            lv = l0 + (l1 - l0) * s1 + (l2 - l1) * s2
            out[j][i] = 1.0 + (lv - 1.0) * MARK_CAMO
            area[0 if t < t1 else (1 if t < t2 else 2)] += 1
    n = float(size * size)
    return out, [c / n for c in area]


def apply_look(av, ink, wear_v, halo, camo_v=1.0):
    """The four look treatments, in the order they physically happen.

    `halo` is the shadow's own coverage at this point -- the same distance field widened
    -- and is composited UNDER the paint, so a worn-through patch shows floor rather than
    shadow. Returns (alpha, ink) still in build.py's convention: ink in RGB, coverage in
    alpha, which is what survives SetTextureColor.
    """
    # The camo darkens the BODY and leaves the rim alone -- it is applied to the body's
    # end of the interpolation, not to the result, so the keyline stays at MARK_RIM_INK
    # whatever the pattern is doing underneath it. That is what keeps the outline the
    # brightest part of the mark, which is the thing the whole rim inversion above exists
    # to achieve; multiplying the finished ink would have dimmed it in the dark patches
    # and broken the outline into dashes.
    ink = MARK_RIM_INK + (MARK_BODY_INK * camo_v - MARK_RIM_INK) * ink
    if MARK_WEAR > 0 and wear_v is not None:
        t = max(0.0, (MARK_WEAR_THR - wear_v) / MARK_WEAR_THR)
        av *= max(0.0, 1.0 - MARK_WEAR * t ** 1.1)
    if MARK_SHADOW > 0:
        h = halo * MARK_SHADOW
        fa = av + h * (1 - av)
        ink = (av * ink) / fa if fa > 1e-6 else 0.0
        av = fa
    return av, ink


def smoothstep(t):
    if t <= 0:
        return 0.0
    if t >= 1:
        return 1.0
    return t * t * (3 - 2 * t)


def across(y):
    """Cross-section alpha at row y, 0..1. Symmetric about the middle."""
    # distance from the nearer edge, as a fraction of the height, sampled at the
    # row's CENTRE so the two edges come out symmetric
    d = (min(y, H - 1 - y) + 0.5) / H
    return smoothstep(d / FEATHER)


def along(x, tip, tail):
    """Longitudinal alpha at column x, 0..1. 1.0 everywhere when both ramps are 0."""
    u = (x + 0.5) / W
    a = smoothstep(u / tip) if tip > 0 else 1.0
    b = smoothstep((1 - u) / tail) if tail > 0 else 1.0
    return min(a, b)


def build(name, tip=0.0, tail=0.0):
    img = Image.new("RGBA", (W, H), (255, 255, 255, 0))
    px = img.load()
    for y in range(H):
        c = across(y)
        for x in range(W):
            a = int(round(255 * c * along(x, tip, tail)))
            px[x, y] = (255, 255, 255, a)
    png = os.path.join(HERE, name + ".png")
    dds = os.path.join(TEX, name + ".dds")
    img.save(png)
    # Uncompressed: the whole asset is shallow gradients, which is precisely what
    # DXT's 3-level alpha interpolation bands. It costs 16 KB each.
    subprocess.run(["magick", png, "-define", "dds:compression=none",
                    "-define", "dds:mipmaps=0", dds], check=True)
    print("wrote", dds)
    mid = H // 2
    print("  along the middle row:",
          " ".join(str(int(round(255 * across(mid) * along(x, tip, tail))))
                   for x in range(0, W, 6)))


def arm_len(hl, hw):
    """Tip to a back corner: the true length of one arm.

    An arm runs from (hl, 0) to (-hl, +/-hw), so its X span is 2*hl -- NOT hl. This was
    `sqrt(hl^2 + hw^2)` from R2.20 until R2.26, which is the length of a different
    triangle and 1.23x short at these proportions. Everything derived from the arm's
    direction inherited that error: the unit vector was not a unit vector, so `d` (across
    the arm) came out 1.23x too large and the arm drew ~19% thinner than MARK_ARM asked
    for, `s` (along it) put the tail cut in the wrong place, and the forward extent below
    was short enough to clip the chevron's own point off against the edge of the box.

    Invisible at the original proportions -- a 3 cm overrun on a mark that small reads as
    a point either way -- and not invisible at R2.26's, where it sawed 10 cm off the tip
    and left a flat wall. Found by rendering the texture itself rather than the route.
    """
    return math.hypot(2.0 * hl, hw)


def mark_box():
    """The mark's bounding box in MARK metres, origin at the chevron's centre.

    Returns (x0, x1, y0, y1). Not symmetric in x: the box has to hold the mitre, which
    sticks out past the tip. For arms whose axes each make an angle a with the bisector,
    their outer edges meet on the bisector at (arm/2) / tan(a) beyond the tip, and
    tan(a) = hw / hl -- the same identity place_arms used, put to better use here, where
    it decides the SHAPE instead of correcting two quads after the fact.
    """
    hl, hw = MARK_LEN * 0.5, MARK_WIDE * 0.5
    ha = MARK_ARM * 0.5
    pad = FEATHER * MARK_ARM          # room for the feather, so nothing clips at an edge
    L = arm_len(hl, hw)
    # An arm is a RECTANGLE about the tip-to-corner line, so the shape reaches half a
    # thickness beyond that line's endpoints, along the perpendicular n = (hw, 2*hl)/L.
    # The box used to allow only for the centreline -- fine while the un-normalised
    # direction was drawing the arms 19% thin, and immediately visible once it wasn't:
    # the back corners ran off the texture's own edges.
    return (-(hl + ha * hw / L + pad),          # back, past the corner by half an arm
            hl + ha * (L / hw) + pad,           # the mitre, where the two front edges meet
            -(hw + ha * 2.0 * hl / L + pad),
            hw + ha * 2.0 * hl / L + pad)


def mark_alpha(X, Y, hl, hw, ha, pad, want_ink=False):
    """Alpha of the chevron at mark-space point (X, Y) -- and, optionally, its INK.

    The union of two arms, taken as max() -- so where they overlap at the apex the result
    is the arm's own alpha and not twice it. That is the entire reason this is a texture
    and not two widgets.

    Each arm is an infinite strip about its centreline, cut by the mark's AXIS: arm 1 owns
    Y <= 0 and arm 2 owns Y >= 0. That cut is what makes the point sharp rather than
    round. A capped segment would round it off by the arm's half-thickness, and clipping
    the box instead would cut it flat; the half-plane is exact, and it is seamless because
    on the axis itself the two arms are equidistant from their own centrelines, so their
    alphas are equal there.

    THE INK (R2.26b). `want_ink` also returns 1 for the mark's interior and 0 for a band
    of MARK_RIM just inside its outline -- a keyline, baked into the RGB, exactly as
    iqm_dot bakes its own (see tools/dot-tex/build.py for the argument).

    It replaces the second widget, and that is a fix rather than a saving. The outline
    used to be a black copy of this picture drawn at a rect `edge` larger, which is a
    SCALED copy and not a dilation: enlarging a rect about its centre moves the glyph
    within it outward, and this glyph's box is deliberately asymmetric (it reaches
    further forward to hold the mitre), so the copy emerges on the leading edge and
    stays hidden behind the body everywhere else. A one-sided outline. R2.20 noted it as
    reading "a little heavier at the point"; at R2.26's larger, sharper mark it became a
    hard black bar across the top of every chevron, which is what the nineteenth
    session's screenshot shows. Baked, the keyline is concentric by construction and
    keeps its PROPORTION at every distance.

    Ink is measured on the same `inset` -- distance inside the mark's boundary -- for
    both the arm's long edges and its square outer end, so the rim goes all the way
    round rather than stopping where two different formulas met.
    """
    best, best_ink = 0.0, 1.0
    rim = MARK_RIM * MARK_ARM
    L = arm_len(hl, hw)                       # tip to a back corner
    # NO FRONT CUT IS NEEDED, once the box is the right size. Each arm is an infinite
    # strip clipped by the half-plane at Y = 0, and that clip alone closes the shape to a
    # point: forward of the tip an arm's coverage is widest ON the axis and narrows as |Y|
    # grows, so the union ends at (hl + ha*L/hw, 0) with the two arms' front edges meeting
    # there. Exactly the mitre R2.20 wanted, drawn by the construction rather than by a
    # correction on top of it. What was missing was only that mark_box stopped short of
    # that X, so the box -- not the geometry -- was ending the mark, with a flat wall.
    for side in (-1.0, 1.0):
        if Y * side < 0:                      # this half belongs to the other arm
            continue
        # unit vector from the tip (hl, 0) to this arm's corner (-hl, side*hw)
        dx, dy = (-hl - hl) / L, (side * hw) / L
        px, py = X - hl, Y
        s = px * dx + py * dy                 # along the arm, 0 at the tip
        d = abs(px * dy - py * dx)            # across it
        body = smoothstep((ha - d) / pad + 0.5)
        tail = smoothstep((L - s) / (MARK_TAIL * L)) if MARK_TAIL > 0 else 1.0
        a = body * tail
        if a > best:
            best = a
            if want_ink:
                # How far inside the outline this point is: the nearer of the long
                # edge and the outer end. Nothing for the tip end -- forward of the tip
                # the two arms overlap, and their long edges are what close the point, so
                # `ha - d` already wraps the rim round the mitre.
                inset = min(ha - d, L - s)
                best_ink = smoothstep((inset - rim) / pad + 0.5)
    if want_ink:
        return best, best_ink
    return best


# --------------------------------------------------------------------------
# THE FIVE GROUND-MARK SHAPES (R2.32)
# --------------------------------------------------------------------------
# The player picks one in MCM. They are not five arbitrary glyphs: each sits at a
# different point on the one trade that matters for a mark lying on the floor, which is
# how much DEPTH along travel its footprint spans. A CUIStatic is always a rotated
# rectangle and the true projection of ground is a trapezoid, so the keystone residual
# scales with that depth and nothing else -- measured over a 1.5 m strafe, as a fraction
# of the mark's own drawn width:
#
#     rung      depth 0.30, ratio 0.22   11% at 5 m    does not point
#     arrow     depth 0.50, ratio 0.34   17%           points
#     chev30    depth 0.30, ratio 0.38   19%           points
#     chev50    depth 0.50, ratio 0.50   24%           points   (the default)
#     square    depth 0.30, ratio 1.00   47%           does not point
#
# The square looks worst and is not: the percentage is a RATIO, so a square scores ~47%
# at every size, while 47% of a 0.30 m tile is 17 px where 24% of the chevron is 45 px.
# A compact symmetric shape also has no long straight edge for the skew to run along.
# See docs/ar-navigation.md R2.31-R2.32 and tools/route-preview.
#
# `alen` is the depth; the width is MARK_WIDE and the stroke weight MARK_ARM for all of
# them, so the family reads as one set. THESE MIRROR RTE.SHAPES in iqm_core.script --
# change one, change both, exactly as MARK_LEN mirrors RTE.alen.
#
# FIVE OF THE EIGHT ARE NO LONGER ON THE MENU (R2.43): chev50, chev30, rung, square and
# dart came off `route_shape`, leaving the arrowhead and the two chevrons. They are still
# DRAWN, and that is deliberate rather than laziness. This list is the atlas's layout as
# well as its content -- cell k*MARK_VARIANTS + v -- so deleting a row slides every cell
# after it, which would invalidate the committed iqm_marks.dds, every <texture> rect in
# gamedata/configs/ui/textures_descr/iqm_textures.xml, and iqm_strip's bands, which are
# carved out of cell 0 by pixel coordinates. Fifteen retired cells cost transparent pixels
# and nothing else. check_shapes_match_mod therefore checks the mod's shapes as a SUBSET
# of this list; the retired rows are unreferenced art, kept so the addresses hold still.
# Anyone who does want them gone should delete them here AND in RTE.SHAPES, repaste the
# region block this script prints, and rerun it -- it is a texture rebuild, not an edit.
#
# THE FOURTH AND FIFTH FIELDS are per-shape overrides of MARK_WIDE and MARK_ARM, None
# meaning "the family's". Only `chevtight` uses them -- see its note below -- and they
# exist because a chevron's APEX ANGLE is not a free parameter: it is set entirely by the
# width-to-depth ratio (the arm from the tip (hl,0) to a back corner (-hl,+/-hw) makes
# atan(hw / 2hl) with the axis), so there is no way to ask for a tighter point except by
# changing one of the two numbers this table was built to hold constant.
MARK_SHAPES = [
    ("chev50", "chevron", 0.50, None, None),
    ("chev30", "chevron", 0.30, None, None),
    ("arrow",  "arrow",   0.50, None, None),
    ("rung",   "rung",    0.50, None, None),   # alen unused: a rung is MARK_ARM deep
    ("square", "square",  0.30, None, None),   # alen IS the side
    ("dart",   "dart",    0.50, None, None),   # a TRUNCATED arrow; see DART_TAPER
    # SMALLER, WITH A TIGHTER POINT (R2.40), asked for after the conveyor made the marks
    # read as a moving run rather than as a row of signs -- at which point a big blunt
    # glyph is carrying more of the screen than it needs to.
    #
    # 0.90 m across against the family's 1.48, and 0.42 deep against chev50's 0.50: the
    # apex closes from 112 degrees to 94. The arm thins with it (0.22 against 0.304),
    # because arm length is what scales with width -- leaving the family weight on a mark
    # this size gives an arm aspect of 2:1, which is a blob with a notch in it rather than
    # a chevron.
    #
    # THE TRADE IT MAKES, stated because it goes the wrong way, and with the numbers this
    # script prints rather than the ones predicted for it: depth over width rises from
    # chev50's 0.56 to 0.68, and R2.31 measured that ratio as the whole of the keystone
    # residual. A tighter point IS more depth per width -- the two are the same fact --
    # so this shape lies LESS flat on the floor than the one it is a variant of, by about
    # a fifth. It is a choice on the menu, not a replacement for the default.
    #
    # The gap is wider than the bare geometry says (0.64 against 0.50) because the pad is
    # a fraction of the ARM, and a small sharp mark carries a thinner arm and so a smaller
    # margin, while the ratio it is added to is already the least favourable. Worth
    # knowing before anyone tries to buy the angle back by thinning the arm further.
    ("chevtight", "chevron", 0.42, 0.90, 0.22),
    # TIGHTER AGAIN (R2.42), asked for after chevtight was seen on the ground. 0.62 across
    # and 0.46 deep closes the apex to about 68 degrees -- a dart of a chevron rather than
    # an arrowhead of one.
    #
    # NOTE WHICH NUMBER MOVED. Getting a tighter point by making the mark DEEPER is the
    # wrong lever: depth is the keystone residual, and a 68-degree apex at chevtight's
    # width would need alen 0.62, deeper than anything else in the family. So the width
    # comes in instead and the depth barely moves.
    #
    # THAT STILL COSTS, AND BY MORE THAN EXPECTED -- read off this script's own output
    # rather than predicted: depth over width is 0.89, against chevtight's 0.68 and
    # chev50's 0.56. Narrowing the mark raises the ratio just as surely as deepening it,
    # because the ratio is depth over WIDTH, and only the numerator was being guarded.
    # 0.89 puts this second only to the square (1.00) for keystone residual, which is a
    # long way from where a chevron usually sits.
    #
    # It is also small: 0.62 m across is under half the family's width, so at distance it
    # reads as a tick rather than as a chevron. Both are the price of the angle, and both
    # are why this is the eighth entry on a menu and not a new default.
    ("chevsharp", "chevron", 0.46, 0.62, 0.18),
]

# THE DART'S BACK WIDTH OVER ITS FRONT WIDTH. An arrow is this shape with the front at
# zero, so the two differ in exactly one number -- and that number is the whole reason
# the dart exists.
#
# A chevron says "forward" with an APEX ANGLE, and the ground-to-screen map does not
# preserve angles: measured over 3-25 m and 0-90 degrees off-axis, the projected apex
# spans 11 to 175 degrees, reading as a plain bar at both ends. A taper is the ratio of
# two PARALLEL edges, and affine maps do preserve that; over the same sweep it moves
# 2.93 to 4.87.
#
# Truncated rather than a point because a point is not a width. The arrow's tip goes
# sub-pixel a few metres out and then aliases in and out along its two converging edges,
# so the cue it is carrying degrades exactly where it is needed. A flat front stays
# measurable, which is what keeps the RATIO meaningful at range.
#
# 3.6 is where the shape still reads as tapering hard without the front becoming a
# spike: at MARK_WIDE it puts the front edge at 0.41 m against a 1.48 m back.
DART_TAPER = 3.6

# HOW MANY PICTURES OF EACH SHAPE (R2.42). Every mark on the route used to be the same
# bitmap, so a run of them was the same scuff and the same camo blotch repeated at even
# spacing -- which is what a repeated texture always looks like once there is more than one
# on screen, and the conveyor put a lot of them on screen.
#
# Only the NOISE differs between variants: the geometry, the box, the keyline and the
# feather are identical, because the renderer measures ONE box per shape (RTE.SB) and a
# variant with its own outline would need its own. So a variant is the same glyph with a
# different patch of wear and a different patch of camo, which is exactly the difference
# between two marks painted a year apart on the same floor.
#
# THREE, and the count is a straight VRAM decision. Cells are 256 px because the nearest
# mark is the biggest thing the route draws, the atlas must be a power of two on both axes,
# and 7 shapes x 3 variants is 21 cells -- which needs an 8 x 4 grid, 2048 x 1024, 8 MB
# uncompressed against the 2 MB the single-variant atlas cost. Two variants would fit
# 4 x 4 (1024 x 1024, 4 MB) and is the fallback if that ever matters; one is exactly the
# old atlas back. Eleven cells of the 32 go unused, which is the price of the power-of-two
# rule and is transparent pixels rather than work.
#
# The renderer picks per mark by HASHING a stable id, not by cycling, so the sequence does
# not read as ABCABC -- see RTE.NVAR in iqm_core.script.
MARK_VARIANTS = 3
# Cell k*MARK_VARIANTS + v, so variant A of chev50 stays cell 0 at (0, 0). That is not
# cosmetic: iqm_strip carves its bands out of the chev50 cell by pixel coordinates, and
# a layout that moved it would silently re-cut them out of something else.
ATLAS_COLS, ATLAS_ROWS = 8, 4      # 2048 x 1024, 256px cells, both powers of two


def shape_box(kind, alen, wide=None, arm=None):
    """(back, fwd, half) in mark metres -- the box the shape is drawn into.

    Mirrors IqmCards:shape_box. Only the chevron's is asymmetric: it alone has a mitre
    sticking out past the tip, which is what mark_box() documents at length.

    `wide` and `arm` default to the family's MARK_WIDE / MARK_ARM. Note that the PAD
    scales with the arm too, on both sides of the mirror: the feather and the baked
    shadow are both expressed as fractions of the stroke weight, so a shape with a
    thinner arm gets a proportionally smaller margin and stays exactly similar.
    """
    wide = MARK_WIDE if wide is None else wide
    arm = MARK_ARM if arm is None else arm
    hl, hw, ha = alen * 0.5, wide * 0.5, arm * 0.5
    # The feather's margin PLUS the baked shadow's reach. Both are room the glyph does not
    # itself occupy, and both have to be in the box the renderer measures or the thing
    # drawn into them is cropped at the rect's edge.
    pad = FEATHER * arm + shadow_pad(arm)
    if kind == "chevron":
        L = arm_len(hl, hw)
        return hl + ha * hw / L + pad, hl + ha * (L / hw) + pad, hw + ha * 2.0 * hl / L + pad
    if kind in ("arrow", "dart"):
        # Same box: both span +/-hl along travel and are widest at the back, so the dart
        # inherits the arrow's depth exactly and with it the arrow's keystone residual.
        return hl + pad, hl + pad, hw + pad
    if kind == "rung":
        return ha + pad, ha + pad, hw + pad
    if kind == "square":
        return hl + pad, hl + pad, hl + pad
    raise ValueError("unknown mark shape %r" % kind)


def convex_edges(kind, alen, wide=None, arm=None):
    """Half-planes (nx, ny, c) with the shape as {p : n.p <= c for all}, or None.

    The three non-chevron shapes are convex, so the signed distance to the boundary is
    just the smallest slack across the edges -- which gives the feather and the inset
    keyline from one number, the same two things mark_alpha computes the hard way.
    """
    hl = alen * 0.5
    hw = (MARK_WIDE if wide is None else wide) * 0.5
    ha = (MARK_ARM if arm is None else arm) * 0.5
    if kind == "arrow":
        # tip at (+hl, 0), base corners at (-hl, +/-hw)
        m = math.hypot(2.0 * hl, hw)
        return [(-1.0, 0.0, hl), (2.0 * hl / m, hw / m, 2.0 * hl * hl / m),
                (2.0 * hl / m, -hw / m, 2.0 * hl * hl / m)]
    if kind == "dart":
        # A trapezoid: back edge at -hl of half-width hw, front edge at +hl of half-width
        # hwf. The two slanted sides run between them.
        #
        # Derived rather than adapted from the arrow's: an outward normal to the side
        # through (-hl, hw) and (hl, hwf) is (hw - hwf, 2*hl), and dotting it with either
        # endpoint gives the same hl*(hw + hwf), which is what makes the edge pass
        # through BOTH corners. build_marks reads the finished cell back and checks the
        # taper it actually drew, so an error here shows up as a failed build.
        hwf = hw / DART_TAPER
        m = math.hypot(hw - hwf, 2.0 * hl)
        c = hl * (hw + hwf) / m
        return [(-1.0, 0.0, hl), (1.0, 0.0, hl),
                ((hw - hwf) / m, 2.0 * hl / m, c),
                ((hw - hwf) / m, -2.0 * hl / m, c)]
    if kind == "rung":
        return [(1, 0, ha), (-1, 0, ha), (0, 1, hw), (0, -1, hw)]
    if kind == "square":
        return [(1, 0, hl), (-1, 0, hl), (0, 1, hl), (0, -1, hl)]
    return None


def check_shapes_match_mod():
    """Every row of RTE.SHAPES in iqm_core.script must match MARK_SHAPES here.

    This pair is the "change one, change both" hazard multiplied by five, and the failure
    is silent in the worst way: the game measures a box the artwork was not drawn into,
    so the glyph sits slightly off its own rect and looks like a rendering bug rather than
    a stale texture. Checked at the moment the drift would be introduced -- regenerating
    the atlas -- because that is the only moment anyone is looking.

    A SUBSET CHECK BY SLUG, not list equality, since R2.43. The mod's menu is down to
    three shapes and this file still draws eight, deliberately: MARK_SHAPES is the atlas's
    LAYOUT as well as its content, cell k*MARK_VARIANTS + v, so dropping the five retired
    rows would slide every surviving cell to a new address -- invalidating the committed
    iqm_marks.dds, every <texture> rect in iqm_textures.xml, and iqm_strip's bands, which
    are carved out of cell 0 by pixel coordinates. Eight retired cells of transparent-ish
    art cost nothing and keep all of that true. So what is checked is that each shape the
    mod still offers agrees with the picture drawn for it; the extras are unreferenced.
    """
    src = os.path.join(os.path.dirname(HERE), "..", "gamedata", "scripts", "iqm_core.script")
    src = os.path.normpath(src)
    if not os.path.exists(src):
        print("  (iqm_core.script not found; shape agreement unchecked)")
        return
    with open(src, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    # The two overrides are OPTIONAL in the mod's table and absent on every row that takes
    # the family's numbers, so they are matched as optional groups and compared as None --
    # which means a row that spells out `awide = 1.48` explicitly would be reported as a
    # disagreement. Deliberate: "the family's width" and "this width, which happens to
    # equal the family's" are different statements, and only the first survives a later
    # change to MARK_WIDE.
    rows = re.findall(r'\{\s*tex\s*=\s*"iqm_mark_(\w+)"\s*,\s*kind\s*=\s*"(\w+)"\s*,'
                      r'\s*alen\s*=\s*([\d.]+)\s*'
                      r'(?:,\s*awide\s*=\s*([\d.]+)\s*)?'
                      r'(?:,\s*aw\s*=\s*([\d.]+)\s*)?\}', text)

    def r4(v):
        return None if v in (None, "") else round(float(v), 4)

    mine = {s: (k, r4(a), r4(w), r4(t)) for s, k, a, w, t in MARK_SHAPES}
    theirs = {s: (k, r4(a), r4(w), r4(t)) for s, k, a, w, t in rows}
    if not theirs:
        raise SystemExit("no RTE.SHAPES rows parsed out of iqm_core.script -- the "
                         "pattern above and the table have drifted apart")
    for slug, there in sorted(theirs.items()):
        here = mine.get(slug)
        if here is None:
            raise SystemExit("iqm_core.script offers shape %r, which this atlas does "
                             "not draw -- add it to MARK_SHAPES" % slug)
        if here != there:
            raise SystemExit("build.py MARK_SHAPES disagrees with RTE.SHAPES for %r:\n"
                             "  here : %s\n  there: %s" % (slug, here, there))
    for name, here in (("awide", MARK_WIDE), ("aw", MARK_ARM)):
        m = re.search(r"\b%s\s*=\s*([\d.]+)" % name, text)
        if m and abs(float(m.group(1)) - here) > 1e-6:
            raise SystemExit("build.py MARK_%s = %s but RTE.%s = %s"
                             % (name.upper(), here, name, m.group(1)))
    # SPAD is the ONE look constant the mod has to know: the shadow's reach is part of
    # the box, and a renderer measuring the old box would crop the halo off at the rect's
    # edge -- a hard straight line across a soft shadow, on every mark.
    want = shadow_pad() / MARK_ARM
    m = re.search(r"\bSPAD\s*=\s*([\d.]+)", text)
    if not m:
        raise SystemExit("iqm_core.script has no RTE.SPAD; add SPAD = %.4f" % want)
    if abs(float(m.group(1)) - want) > 1e-4:
        raise SystemExit("the baked shadow and the drawn box disagree:\n"
                         "  build.py MARK_SHADOW_W = %s -> SPAD %.4f\n"
                         "  iqm_core RTE.SPAD    = %s\n"
                         "Set RTE.SPAD = %.4f (or 0 if MARK_SHADOW is 0)."
                         % (MARK_SHADOW_W, want, m.group(1), want))
    # The variant count is the third thing that has to exist twice, and its failure is the
    # loudest of the three: the renderer asks for a texture id per variant, so a mod
    # expecting more variants than the atlas holds is a MISSING TEXTURE on every third
    # mark -- which the engine draws as nothing at all.
    m = re.search(r"\bNVAR\s*=\s*(\d+)", text)
    if not m:
        raise SystemExit("iqm_core.script has no RTE.NVAR; add NVAR = %d" % MARK_VARIANTS)
    if int(m.group(1)) != MARK_VARIANTS:
        raise SystemExit("build.py MARK_VARIANTS = %d but RTE.NVAR = %s -- the mod would "
                         "ask for cells this atlas does not hold"
                         % (MARK_VARIANTS, m.group(1)))
    print("  shapes agree with RTE.SHAPES (%d offered, %d drawn), SPAD %.4f, %d variants"
          % (len(theirs), len(mine), want, MARK_VARIANTS))


def atlas_regions():
    """(id-suffix, x, y) for every cell, in the order build_marks writes them.

    Split out so the XML can be checked BEFORE a pixel is drawn -- the atlas takes the
    better part of a minute at three variants, and a run that fails at the end has already
    overwritten the texture it was checking against.
    """
    out = []
    for k, (slug, _kind, _alen, _wide, _arm) in enumerate(MARK_SHAPES):
        for v in range(MARK_VARIANTS):
            cell = k * MARK_VARIANTS + v
            if cell >= ATLAS_COLS * ATLAS_ROWS:
                raise SystemExit(
                    "the atlas holds %d cells and %d shapes x %d variants need %d"
                    % (ATLAS_COLS * ATLAS_ROWS, len(MARK_SHAPES), MARK_VARIANTS,
                       len(MARK_SHAPES) * MARK_VARIANTS))
            out.append((slug if v == 0 else "%s_%s" % (slug, chr(ord("b") + v - 1)),
                        (cell % ATLAS_COLS) * MARK_PX, (cell // ATLAS_COLS) * MARK_PX))
    return out


def build_marks(name="iqm_marks"):
    """Every shape into one atlas, one 256px cell each."""
    check_shapes_match_mod()
    check_regions_match_xml(atlas_regions())
    n = MARK_PX
    img = Image.new("RGBA", (n * ATLAS_COLS, n * ATLAS_ROWS), (255, 255, 255, 0))
    px = img.load()
    # ONE FIELD PER VARIANT, shared by every shape (R2.42). Both axes of that matter:
    #
    #   shared across SHAPES -- the shapes are views of the same painted surface, so
    #     re-seeding per shape would make the grain jump when the player switches shape.
    #   separate per VARIANT -- that difference IS the variant. Nothing else changes.
    wear = [wear_field(n, MARK_WEAR_SEED + v * 17) if MARK_WEAR > 0 else None
            for v in range(MARK_VARIANTS)]
    camo, camo_area = [None] * MARK_VARIANTS, None
    for v in range(MARK_VARIANTS):
        if MARK_CAMO > 0:
            camo[v], camo_area = camo_field(n, MARK_CAMO_SEED + v * 31)
            print("  variant %s camo levels cover %.0f%% / %.0f%% / %.0f%%"
                  % (chr(ord("A") + v), 100 * camo_area[0], 100 * camo_area[1],
                     100 * camo_area[2]))
            # A cut in the wrong place gives a field that is nearly all one level, which is
            # a flat mark with a smudge on it -- and it looks like a rendering fault rather
            # than a bad constant, so it is caught here instead of on the floor. Checked per
            # VARIANT: the cuts are fixed and each variant's field is a different draw, so
            # one of them landing lopsided is exactly the failure this can have.
            if min(camo_area) < 0.08:
                raise SystemExit("variant %s's camo pattern is degenerate (%s) -- one level "
                                 "covers almost nothing. Check MARK_CAMO_CUTS."
                                 % (chr(ord("A") + v),
                                    ", ".join("%.0f%%" % (100 * f) for f in camo_area)))
    regions = atlas_regions()
    ri = 0
    for k, (slug, kind, alen, wide, arm) in enumerate(MARK_SHAPES):
      for v in range(MARK_VARIANTS):
        ox, oy = regions[ri][1], regions[ri][2]
        ri = ri + 1
        back, fwd, half = shape_box(kind, alen, wide, arm)
        edges = convex_edges(kind, alen, wide, arm)
        # Per shape now, not once for the atlas: a row may override the family's width and
        # stroke weight, and every one of these five is derived from one or the other.
        awide = MARK_WIDE if wide is None else wide
        aw = MARK_ARM if arm is None else arm
        hl, hw, ha = alen * 0.5, awide * 0.5, aw * 0.5
        rim, pad, sw = MARK_RIM * aw, FEATHER * aw, MARK_SHADOW_W * aw
        for j in range(n):
            Y = -half + (j + 0.5) / n * (half * 2)
            for i in range(n):
                X = -back + (i + 0.5) / n * (back + fwd)
                if edges is None:
                    av, ink = mark_alpha(X, Y, hl, hw, ha, pad, want_ink=True)
                    halo = mark_alpha(X, Y, hl, hw, ha, sw) if MARK_SHADOW > 0 else 0.0
                else:
                    d = min(c - (nx * X + ny * Y) for nx, ny, c in edges)
                    av = smoothstep(d / pad + 0.5)
                    ink = smoothstep((d - rim) / pad + 0.5)
                    halo = smoothstep(d / sw + 0.5) if MARK_SHADOW > 0 else 0.0
                av, ink = apply_look(av, ink, wear[v][j][i] if wear[v] else None, halo,
                                     camo[v][j][i] if camo[v] else 1.0)
                px[ox + i, oy + j] = (int(round(255 * ink)),) * 3 + (int(round(255 * av)),)
        # The APEX is printed for the chevrons because it is the cue they carry and it is
        # not a constant anywhere -- it falls out of width over depth, so a shape asked for
        # by its point (chevtight) can only be checked by reading the angle back.
        apex = ("  apex %3.0f deg" % (2.0 * math.degrees(math.atan2(hw, 2.0 * hl))
                                      )) if kind == "chevron" else ""
        print("  %-9s %s %-8s box %.3f/%.3f/%.3f  depth %.2f  ratio %.2f%s"
              % (slug, chr(ord("A") + v), kind, back, fwd, half, back + fwd,
                 (back + fwd) / (half * 2), apex))
        # THE DART'S CUE, READ BACK OFF THE PIXELS just drawn, not off the constants.
        # Its four half-planes are hand-derived, and the way that goes wrong is a shape
        # that is still convex and still plausible -- a slightly wrong taper is invisible
        # in the cell and wrong on the ground at every distance. So measure the thing the
        # shape exists to carry, at the two edges, and fail the build if it drifted.
        if kind == "dart":
            def width_at(frac):
                X = -hl + frac * (2.0 * hl)
                i = int((X + back) / (back + fwd) * n)
                return sum(1 for j in range(n)
                           if px[ox + max(0, min(n - 1, i)), oy + j][3] > 127)
            wb, wf_ = width_at(0.08), width_at(0.92)
            got = wb / float(wf_) if wf_ else 0.0
            print("       taper %.2f measured off the cell (%s px back, %s px front)"
                  % (got, wb, wf_))
            # Loose: the readback samples inside the feather, which softens both edges by
            # the same absolute amount and so pulls any ratio toward 1. It is a guard
            # against a derivation error, not a calibration.
            if not (DART_TAPER * 0.6 <= got <= DART_TAPER * 1.4):
                raise SystemExit("the dart cell's taper is %.2f, wanted about %.2f -- "
                                 "check convex_edges('dart')" % (got, DART_TAPER))
    png = os.path.join(HERE, name + ".png")
    dds = os.path.join(TEX, name + ".dds")
    img.save(png)
    subprocess.run(["magick", png, "-define", "dds:compression=none",
                    "-define", "dds:mipmaps=0", dds], check=True)
    print("wrote", dds, img.size)


def check_regions_match_xml(regions):
    """The atlas's cells must be the regions configs/ui/textures_descr declares.

    Twenty-one hand-written rectangles is too many to keep right by reading, and the way
    they go wrong is silent: a wrong x/y draws a neighbouring cell, which is still a
    plausible mark, so the route looks fine and one shape is quietly another. Generated
    here and compared, with the correct block printed on a mismatch so there is nothing to
    transcribe by hand.
    """
    rel = os.path.join("gamedata", "configs", "ui", "textures_descr", "iqm_textures.xml")
    p = os.path.normpath(os.path.join(os.path.dirname(HERE), "..", rel))
    want = "\n".join(
        '\t\t<texture id="iqm_mark_%s"%s x="%d" y="%d" width="%d" height="%d" />'
        % (slug, " " * max(0, 14 - len(slug)), ox, oy, MARK_PX, MARK_PX)
        for slug, ox, oy in regions)
    if not os.path.exists(p):
        print("  (iqm_textures.xml not found; regions unchecked)")
        return
    with open(p, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    missing = []
    for slug, ox, oy in regions:
        pat = (r'<texture\s+id="iqm_mark_%s"\s+x="(\d+)"\s+y="(\d+)"' % re.escape(slug))
        m = re.search(pat, text)
        if not m or int(m.group(1)) != ox or int(m.group(2)) != oy:
            missing.append("iqm_mark_%s -> %d,%d (file says %s)"
                           % (slug, ox, oy,
                              m and "%s,%s" % (m.group(1), m.group(2)) or "absent"))
    if missing:
        raise SystemExit("iqm_textures.xml does not match the atlas just built:\n  %s\n\n"
                         "Replace the iqm_mark_* block with:\n%s"
                         % ("\n  ".join(missing), want))
    print("  all %d atlas regions agree with iqm_textures.xml" % len(regions))


def build_mark(name="iqm_mark"):
    x0, x1, y0, y1 = mark_box()
    hl, hw, ha = MARK_LEN * 0.5, MARK_WIDE * 0.5, MARK_ARM * 0.5
    pad = FEATHER * MARK_ARM
    n = MARK_PX
    img = Image.new("RGBA", (n, n), (255, 255, 255, 0))
    px = img.load()
    for j in range(n):
        Y = y0 + (j + 0.5) / n * (y1 - y0)
        for i in range(n):
            X = x0 + (i + 0.5) / n * (x1 - x0)
            av, ink = mark_alpha(X, Y, hl, hw, ha, pad, want_ink=True)
            a = int(round(255 * av))
            v = int(round(255 * ink))
            px[i, j] = (v, v, v, a)
    png = os.path.join(HERE, name + ".png")
    dds = os.path.join(TEX, name + ".dds")
    img.save(png)
    subprocess.run(["magick", png, "-define", "dds:compression=none",
                    "-define", "dds:mipmaps=0", dds], check=True)
    print("wrote", dds)
    print("  box %.3f..%.3f x %.3f..%.3f m" % (x0, x1, y0, y1))
    print("  down the axis:",
          " ".join(str(px[i, n // 2][3]) for i in range(0, n, n // 16)))


def main():
    # BEFORE anything is written. build_marks does its own call -- it is the function the
    # check is about -- but leaving it there alone means a disagreement fails the run
    # having already overwritten two textures that had nothing to do with it, and the
    # person reading the error then has a dirty tree to explain as well as a mismatch.
    check_shapes_match_mod()
    build("iqm_stroke")
    build("iqm_arm", tip=ARM_TIP, tail=ARM_TAIL)
    # build_mark() is gone from the default run: iqm_mark.dds was the single-shape
    # texture, and the atlas supersedes it. The function stays for rendering one shape
    # on its own when a proportion is being judged.
    build_marks()


if __name__ == "__main__":
    sys.exit(main())
