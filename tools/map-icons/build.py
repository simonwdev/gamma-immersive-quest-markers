#!/usr/bin/env python3
"""Build the PDA map/minimap spot atlas (gamedata/textures/ii/iqm_map_icons.dds)
from the source SVGs in ./svg.

These are NOT the card glyphs (that's tools/role-icons). These replace the icons
the engine draws on the fullscreen PDA map and the HUD minimap, via the DXML patch
in gamedata/scripts/modxml_n_iqm_map_icons.script.

    python build.py              # build the atlas
    python build.py --preview    # also write _preview.png: every glyph at the
                                 # sizes it is actually drawn at, tinted

WHAT THIS REPRODUCES
--------------------
Anomaly's own service spots are a BADGE, not a bare pictogram: a thin ring, four
crosshair ticks at N/E/S/W straddling that ring, and a flat glyph at half the
footprint. Measured off the vanilla 19x19 medic cell in ui\\ui_actor_hint_wnd
(x=66 y=543), which is the copy G.A.M.M.A. loads via UI Rework G.A.M.M.A. Style:

    ring radius 7.0/19    ring stroke ~1.3/19    ticks 3.2 long x 1.3 wide
    inner glyph box 9.5/19 (half the cell)       colour (132,199,231), baked

That circular footprint is load-bearing, not decoration: task spots wrap their
19x19 icon in a static_border - storyline_task_spot declares a 29x29 border at
offset (-4,-5) textured ui_pda2_stask_last_02, a ring. A round icon nests inside a
round border; a square one does not. Rebuilding the badge at 128px keeps us inside
the game's own visual system while fixing the thing that was actually wrong with
it, which was never the design - it was 19 source pixels being magnified by the
map's zoom.

WHY HIGH-RES SOURCES HELP
-------------------------
A spot's on-screen size comes from its width/height in map_spots*.xml (UI units,
with stretch="1"), NOT from the texture rect. Those are UI units, so they scale with
the player's RESOLUTION: a 19-unit spot is ~27px at 1080p, ~36px at 1440p and ~53px
at 4K, against the 15-23px source cells vanilla and the other spot addons supply.
A 128px cell drawn into the same rect is minified at every resolution instead of
magnified at most of them.

These spots do NOT grow with map zoom: zoom rescaling needs scale="1" on the spot
(m_bScale, map_spot.cpp:41-48) and none of the ones patched here declare it, while
ScaleOrigin at line 274 only reaches CComplexMapSpot's CUIStaticOrig children. That
also means a static_border's misalignment is a fixed pixel count rather than a
zoom-dependent one, which is what makes the one BORDER_X constant in the DXML script
able to fix it at every zoom level.

CONVENTIONS
-----------
Everything is drawn WHITE with a BLACK keyline around the finished badge. Colour
comes from the r/g/b attributes the DXML script sets on the spot's <texture>
element, so recolouring is a one-line edit there with no rebuild -- and the keyline
survives it for free, because the engine *multiplies* the texture's RGB by the
tint: white x red = red, black x anything = still black. (Vanilla bakes its light
blue in and tints nothing, so every service spot is the same colour; per-role
colour is the one place this deliberately improves on the original rather than
reproducing it. Set every tint to 132,199,231 to get vanilla's look back.)

No distress pass (unlike role-icons): the worn look is right for a glyph drawn once
at badge size on a card, and wrong at 26-35px, where chips are the same size as the
stroke and read as speckle.

INNER GLYPHS
------------
The glyph sits in half the cell, so its detail budget is HALF what a bare icon
would have. Vanilla's own glyphs are correspondingly brutal: the bed is two posts
and a mattress bar, drawn flat side-on. Flat orthographic shapes only - a
perspective drawing loses its legs and reads as a smudge at this size.

Grid growth rule (same as role-icons): APPEND cells, and when a row fills, add a
ROW. Never widen COLS -- that renumbers every existing cell's pixel origin and
invalidates the texture ids in iqm_textures.xml.

Requires: Pillow, and ImageMagick (`magick`) on PATH for SVG->PNG and PNG->DDS.
Run from this directory.
"""
import os, struct, subprocess, sys
from PIL import Image, ImageChops, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
SVGDIR = os.path.join(HERE, "svg")
OUT_PNG = os.path.join(HERE, "iqm_map_icons.png")
PREVIEW = os.path.join(HERE, "_preview.png")
OUT_DDS = os.path.normpath(os.path.join(
    HERE, "..", "..", "gamedata", "textures", "ui", "iqm_map_icons.dds"))

# Cell order (row-major). MUST match the texture ids in
# gamedata/configs/ui/textures_descr/iqm_textures.xml. The tint is preview-only,
# mirroring the SPOTS table in modxml_n_iqm_map_icons.script - the game reads its
# colour from there, never from here.
# A name in PROC (below) is DRAWN, not loaded from svg/ - the two task marks are
# rings, arcs and brackets, which are cheaper and sharper as geometry than as art.
SRCS = [("medic",     (238, 106, 94)),
        ("trader",    (0, 198, 176)),
        ("bed",       (110, 154, 234)),
        ("vip",       (190, 140, 240)),
        ("mechanic",  (120, 206, 236)),
        ("task",      (246, 204, 0)),
        ("select",    (246, 204, 0)),
        ("handin",    (40, 172, 66)),
        ("barman",    (255, 128, 185)),
        ("blink",     (246, 204, 0)),
        ("above",     (246, 204, 0)),
        ("below",     (246, 204, 0)),
        # Fast travel. The teal is SAMPLED from AlphaLion's ui_MapSpots.dds rather than
        # picked, because that art - not vanilla's - is what this spot actually draws in
        # this pack, and the point of R2.55 is to change the glyph without changing the
        # colour the player already reads as "fast travel". See svg/home.svg.
        ("home",      (80, 229, 202)),
        ("question",  (206, 0, 32)),
        ("alert",    (240, 184, 92)),
        ("transition", (102, 173, 88)),
        # The two squad marks open row 4. Their preview tint is stalker yellow purely
        # so they are visible here; unlike every other cell these carry NO tint in the
        # SPOTS table, because each of the 14 warfare spots already sets its own faction
        # colour and overriding that would throw the colour coding away.
        ("squad",     (255, 255, 128)),
        ("squadmini", (255, 255, 128)),
        # The MUTANT HUNT mark (R2.48). Bare, not ringed - see NO_BADGE and the note
        # in svg/skull.svg. Acid lime because a mutant is not a faction and has no
        # colour of its own to borrow; it clears the turn-in green by dE 36 and the
        # storyline gold by dE 39, both over the dE 28 floor, and the SHAPE does most
        # of the work here anyway - nothing else in the atlas is a skull.
        #
        # SUPERSEDED as the mutant-hunt pin by taskmutant below, and kept because it is
        # still the right mark if the reticle composite is ever backed out - point
        # iqm_task_mutant_spot at this id again and nothing else has to change.
        ("skull",     (176, 216, 72)),

        # --- row 5 -------------------------------------------------------------

        # THE TWO TASK-KIND RETICLES (R2.49). Not badges and not bare glyphs - the task
        # reticle used as a FRAME, with the inner ring and the centre crosshair dropped
        # and a glyph in the space they leave. See RETICLE below for the geometry and
        # for what the trade costs each of them.
        #
        # Tints mirror iqm_map_spots.xml, which is where these two actually get their
        # colour - unlike every other entry here, whose colour is in the SPOTS table.
        #
        # taskbounty was drawn by TWO location types until R2.55 - iqm_task_bounty in its
        # dulled red and iqm_task_hostage in azure - on the reasoning that a contract and a
        # rescue are the same statement about the objective and differ only in the verb.
        # They now share the type as well as the cell: the verb turned out to be the part
        # the player never acts on, so rescues simply answer "bounty". One type, one tint.
        ("taskmutant", (176, 216, 72)),
        ("taskbounty", (172, 60, 66)),

        # THE OPEN FRAME (R2.49e): the same reticle with NOTHING in it, for a task whose
        # marker sits on top of art somebody else already chose - specifically Personal
        # Adjustable Waypoint's, where the player picks their own pin from a library of 85.
        # PAW puts BOTH spots on the same object (tasks_placeable_waypoints.script:1547-48:
        # change_map_location for the task, then map_add_object_spot for its own highlight),
        # so the reticle lands squarely over that pin - and since R2.49b the crosshair is
        # 2.0/23 and solid through the middle, which covers it completely. An empty frame
        # rings the player's icon instead of replacing it.
        ("taskopen",   (240, 244, 248)),

        # THE OFF-SCREEN POINTER (R2.53). Not a spot at all - a <quest_pointer>-style
        # element, which the engine draws at the map's edge, rotated to face a marker that
        # is off screen (CMapLocation::Update -> UpdateSpotPointer, map_location.cpp:427).
        # Preview tint is the task gold; six pointer elements share this one cell and each
        # takes its pin's colour, the same way the 14 warfare spots share one disk.
        ("pointer",    (246, 204, 0)),

        # DELIVERY (R2.54): the envelope in the same reticle frame, in the HAND-IN GREEN.
        # Not a colour of its own: walking a package to a named NPC is the same act as
        # walking a finished job back to its giver, so it takes the green the map already
        # uses for that (the on_guider spots, ATUE's return spot, BEACON_RGB.target) and the
        # GLYPH carries the difference from the hand-in diamond. This is the one place the
        # palette's usual rule is inverted on purpose - colour unifying rather than
        # separating - and iqm_map_spots.xml has the argument.
        #
        ("taskdelivery", (40, 172, 66)),

        # --- row 7 -------------------------------------------------------------
        # Cell 24 filled the 4x6 grid exactly, so these two cost a ROW (6 -> 7, +128 px of
        # texture). Appending is what keeps that cheap: every existing cell's origin is
        # unchanged and iqm_textures.xml needed two new lines rather than twenty edited
        # ones. Widening COLS would have renumbered the lot - see the growth rule at the
        # top of this file.
        #
        # THE OFF-LEVEL ARROWS, BARE. CMiniMapSpot REPLACES a marker with these when its
        # target is on another floor, so the swap has to say both "marker" and "other
        # level" on its own - which is why the originals are ringed badges with a big arrow
        # where a pictogram would go.
        #
        # That ring is now wrong for half the marks that use it. The grammar the task marks
        # follow is that the FRAME is the verb: a ring means someone is here, a reticle
        # means go and find this, a bare glyph means go and give this to a named person. A
        # hand-in or a delivery that goes up a floor and comes back as a RINGED badge has
        # changed what it claims to be, purely because the player walked upstairs.
        #
        # Same art as above/below (GLYPH_SRC), so the arrow itself cannot drift between the
        # two pairs; the only difference is the missing ring. The ringed pair stays exactly
        # as it was for the reticle-class marks and for the mods this file patches.
        ("abovebare",  (40, 172, 66)),
        ("belowbare",  (40, 172, 66))]
CELL, COLS, ROWS = 128, 4, 7
W, H = CELL * COLS, CELL * ROWS

# Badge geometry, as fractions of the cell, measured off the vanilla 19x19 cell.
# Set BADGE = False to emit bare glyphs at BARE_FIT instead (what this tool built
# before the badge frame existed - kept because a bare glyph is the right call for
# any spot type that vanilla itself draws without a ring).
BADGE = True

# Cells that get NO ring: the glyph is drawn bare at BARE_FIT, for any spot type
# vanilla itself draws without a frame, or whose glyph already supplies one.
#
# The fast-travel point is bare, as vanilla draws it - and vanilla's choice of a HOUSE
# for it is the reason that works. Worth spelling out, because it is the rule for
# picking any future bare glyph.
#
# The handheld 3D PDA squashes every map spot to 0.75 of its width (full derivation
# under PRESTRETCH below). A bare map pin does not survive that: its head is a circle,
# and a circle with a circular hole in it becomes a visibly wrong oval. A bare house
# survives it fine - it just becomes a slightly narrower house.
#
# That is NOT a difference in proportions, which was the obvious wrong guess. Vanilla's
# ui_hud_icon_sleep house measures 43x49 (0.878) and the Tabler map pin 84x96 (0.875) -
# the same shape of box. What differs is that the eye knows what a circle should be and
# has no expected value for a rectangle or a triangle. So:
#
#   RULE: a bare glyph must contain no circle. Straight edges, corners and triangles
#   tolerate the squash; circles, rings and dots report it. If a glyph must have a
#   circle in it, put it inside the badge ring, where a surrounding ellipse gives the
#   eye its context and the glyph is small enough for the distortion not to register.
#
# svg/home-pin.alt is the map-pin version, kept because it took a while to establish
# that it could not work bare. Copy it over svg/home.svg and add "home" to NO_BADGE's
# complement (i.e. remove it here) to use it ringed instead.
#
# NO_BADGE also briefly held "handin", while that cell was circle-check - which carries
# its own circular frame, so the badge ring around it gave two concentric circles a
# hairline apart and squeezed the check to nothing. The shield glyph there now has no
# frame of its own, so it sits inside the ring with everything else.
# The mutant skull joins it (R2.48), and it is the first cell here chosen for
# LEGIBILITY rather than for matching what vanilla draws - there is no vanilla mutant
# spot to match. The badge ring costs a glyph half the cell (GLYPH_FIT of the ring's
# inner diameter, ~62 px against BARE_FIT's 110), and a task spot is drawn at 19 units,
# ~27 px at 1080p. Ringed, the skull's sockets and teeth close up and it reads as a
# green blob - the same failure the trader briefcase had before it was replaced.
#
# THE NO-CIRCLE RULE ABOVE IS THE INTERESTING PART, because this glyph breaks it on
# paper: its eye sockets are true circles. Tested rather than argued (R2.48b) - rendered
# at the 0.75 the handheld PDA applies, the sockets go slightly oval and the mark still
# reads as a skull. The rule holds where a circle IS the shape, as it is on a map pin's
# head; it does not reach a pair of small features inside a silhouette that gives the eye
# its context. Same latitude vanilla's bare house gets. Re-check it if the glyph is ever
# swapped again: the first skull tried here passed for a different reason (it had no
# circles at all) and the second passes on this one.
NO_BADGE = {"home", "skull", "handin", "taskdelivery", "abovebare", "belowbare"}

# Optical centring, in CELL pixels, applied to the glyph only - the frame stays put.
#
# fit() centres a glyph by its BOUNDING BOX, which is right for a symmetric shape and wrong
# for one whose mass is not where its extents are. The barman mug is the case: its bbox is
# dead centre (8..119, midpoint 63.5) while its LIT INK centroid sits at x=61.2, because the
# body is solid and the handle sticking out to the right is a thin outline. The eye centres
# on mass, so the mug reads as sitting left in its badge.
#
# 2 px here, from that measurement rather than from taste - it is 0.46 px at the 26 px a
# minimap spot draws and ~1.3 px in the preview's 70 px column, which is where it is visible
# and where it was spotted. Sub-pixel at map size, but it moves the antialiasing, and that
# is what the eye actually reads at these sizes.
#
# Measure before adding an entry: centroid minus 63.5, over the LIT pixels only (the keyline
# is symmetric and would dilute it). Do not nudge a glyph whose bbox and centroid agree.
GLYPH_NUDGE = {"barman": (2, 0)}

# Cell name -> source svg, for the cells whose art is not svg/<name>.svg.
#
# Only needed for a cell that USED to be a RETICLE composite: those name their glyph in the
# RETICLE table, so the cell and the file never had to agree. taskdelivery became a bare
# glyph when delivery and hand-in left the reticle family (the frame encodes the verb: a ring
# means "someone is here", a reticle means "go and find this", and a bare glyph means "go and
# give this to a named person" -- neither delivery nor hand-in involves searching for
# anything). Mapping it is better than renaming svg/mail.svg, which would make the source
# file's name describe where it is used rather than what it draws.
GLYPH_SRC = {"taskdelivery": "mail",
             # The bare off-level arrows draw the SAME art as the ringed pair, so the two
             # cannot drift apart in shape - the ring is the only difference, which is the
             # whole point of the second pair.
             "abovebare": "above", "belowbare": "below"}

# Cells whose CONTENT is pre-stretched horizontally before packing.
#
# THE MAP IS DRAWN TWICE, AND THE TWO VIEWS DISAGREE ABOUT ASPECT. This is the single
# most confusing thing about this atlas, so the whole derivation is here.
#
# CMapSpot::Load multiplies every spot's WIDTH by kx = (h/w)/(768/1024), which is 0.75
# at 16:9 (map_spot.cpp:35-39). Whether that is a correction or a distortion depends
# on which of two render paths the map is going through:
#
#   FULLSCREEN 2D MAP (m_currentPointType == pttTL). ClientToScreenScaled multiplies
#   x by W/1024 and y by H/768 (ui_base.cpp:113,122-127) - anisotropic. Work it out:
#       (w*kx*W/1024) / (h*H/768) = (w/h) * (H/W)*(1024/768) * (W/H)*(768/1024) = w/h
#   The kx is exactly cancelled, at ANY resolution. A square cell renders square.
#
#   3D PDA IN HAND (pttLIT, i.e. g_3d_pda on). ClientToScreenScaled does
#   `dest.set(left, top)` - NO scaling at all; raw UI units go to a quad that a 3D
#   transform maps onto the PDA's screen. Nothing cancels the kx, so every map spot
#   renders 0.75 AS WIDE AS IT IS TALL.
#
# Both were measured on the same art: a medic badge from a square cell lands 25x26 px
# on the fullscreen map, and the pin from a 104x118 cell lands 12x20 in the handheld
# PDA - 0.75x its authored aspect. The "house came out 0.750 wide" note from the first
# round of this tool was a handheld-PDA measurement and was right; the "there is no
# squish" note that replaced it was a fullscreen measurement and was also right. Both
# generalised from one view.
#
# Dynamic Aspect Ratio Tweaks is aimed at exactly this (parsePDAMarkers is gated on
# isUsing3DPDA) but cannot help here: its factor is device_ratio / the ratio the XML
# was authored for, and for a 16:9 player reading map_spots_16.xml that is 1.0.
#
# So no single texture is right in both views, and there is nothing to hook - both
# views draw the SAME CMapSpot object. heading="1" does not escape it either: that path
# skips the load-time width multiply and applies kx inside rotate_pt at render time
# instead (UIStaticItem.cpp:144-165), which comes to the same thing.
#
# EMPTY, and the correction is done on the SPOT instead - see fast_travel_spot in
# modxml_n_iqm_map_icons.script. The two are mathematically identical (pre-widening the
# art by 4/3 and setting width to 25/0.75 produce the same pixels), but doing it on the
# spot keeps the art honest, costs no cell resolution to a stretch, and puts the
# aspect decision next to the size decision, which is the same decision.
#
# A midpoint was tried here first - sqrt(4/3), ~13% wrong in each view instead of 32%
# wrong in one - and rejected: 13% narrow still reads as squished on a pin, and the
# handheld PDA is the view that gets used.
PRESTRETCH = {}
# Ring stroke, WIDER than the 1.35/19 measured off vanilla, and this is the one place the
# rebuild deliberately departs from the original's geometry. Reason is measurable: see the
# note on OUTLINE below. A thin ring plus a fat keyline means most of a badge's area at
# 26px is BLACK, and a marker's apparent colour is its mean over that area, so the icons
# came out looking washed no matter what tint they were given. More ink per unit of edge
# is the fix; 2.1/19 lifts the medic badge's effective chroma from 88 to 110 while the
# black share falls from 37% to 23%.
RING_W = 1.5 / 19
TICK_LEN = 3.2 / 19     # tick length, centred on the ring centreline
TICK_W = 1.35 / 19      # tick width
BARE_FIT = 110.0 / 128  # non-badge glyph box

# Vanilla's crosshair ticks are OFF: a plain ring is cleaner, and the ring alone
# still nests inside the game's ring-textured selection borders, which was the
# reason to keep the circular footprint in the first place.
#
# Dropping them frees the margin they occupied, so the ring grows to keep the badge's
# apparent size on the map unchanged - otherwise removing the ticks would shrink every
# marker. Vanilla's ticks reached 8.6/19 from centre; RING_R is set so the ring's
# outer edge lands there instead, leaving just enough for the keyline inside the cell
# (0.4455 * 128 + 6 = 63 of the 64 available). Growing the ring also grows the inner
# glyph, since GLYPH_FIT is measured against the ring - the icons gain legibility at
# minimap size as a side effect. Set TICKS = True to get vanilla's geometry back.
TICKS = False
RING_R = 7.0 / 19 if TICKS else 0.40

# Inner glyph box on its long axis, as a fraction of the ring's INNER DIAMETER -
# not of the cell. The ring is the constraint the glyph has to live inside, so
# tying it to the ring means changing RING_R or RING_W cannot silently push the
# glyph through the ring. Vanilla's 9px plus inside a 12.7px inner diameter is
# 0.71; 0.70 leaves the ~9 final px the glyph's own keyline needs.
GLYPH_FIT = 0.70

# Per-cell fudge on the glyph box. Below 1 for glyphs whose CORNERS, not their edges,
# are the binding constraint: GLYPH_FIT sizes the bounding box, so a square filling it
# has its diagonal reach 1.41x further than its sides. Round and cross-shaped glyphs
# don't care.
#
# Above 1 to claim margin a glyph doesn't need - nothing needs that at the moment.
# The pin briefly did, but only to offset the height PRESTRETCH was costing it; with
# that gone, BARE_FIT alone puts it at ~92% of its cell, in line with the ringed
# badges' ~96%.
# Per-cell scale on the fitted glyph box. Same principle as GLYPH_NUDGE above: fit() works
# on the bounding BOX, and two glyphs with the same box are not the same apparent size.
#
# taskdelivery 0.79 makes the envelope match the hand-in diamond it now sits beside in the
# grammar (both bare, both the same green, separated only by glyph). Measured: at equal fit
# their lit bboxes are both 108 wide, but the envelope fills 82% of its box while the
# diamond -- an outline, rotated, with a hole -- fills 41%. Twice the ink in the same box,
# and the envelope read as the larger mark. sqrt(28.9/46.7) = 0.787 equalises the INK, which
# is what the eye sizes a mark by; this is the same rule that mis-sized the fast-travel
# house at 20 units by matching a badge's footprint instead of its ink.
#
# handin 0.79 for the same reason and by the same arithmetic: the tag is solid and inks 46.9%
# of its cell, against the 29.1% of the envelope it sits beside in the same green. Two marks
# that differ only by glyph must not also differ by weight, or the heavier one reads as the
# more important. sqrt(29.1/46.9) = 0.788.
FIT_SCALE = {"taskdelivery": 0.79, "handin": 0.79}

# Supersample factor for the vector work. The ring is a 1-unit stroke at final
# size, so drawing it directly would alias badly; 8x down to 1x is indistinguishable
# from an SVG render and needs no extra dependency.
SS = 8

# Keyline thickness in FINAL pixels, for the badge frame and the inner glyph
# separately. Scale: a spot draws its cell into 19 UI units on the map and 14 on the
# minimap, ~35 and ~26 physical px at 1080p, so one final pixel is 3-5 source px. 6
# lands a 1-2px keyline across that range.
#
# The frame's keyline is applied OUTWARD ONLY - black from the ring's inner edge
# outward, never across the badge interior. That is not a detail: the frame and the
# glyph are only ~11 final px apart (ring inner edge 42.7, glyph half-extent 32), so
# two keylines growing toward each other close the gap and the badge reads as a blob
# at minimap size. Keeping the interior clear also matches vanilla, which has no
# keyline at all and lets terrain through the ring.
#
# 4 and 3, down from 6 and 4, because the keyline turned out to be the thing making these
# look muted - and that was found by measuring, after a first attempt at the problem which
# only pushed the tints around. Take a finished cell, tint it, scale it to the 26px the
# minimap actually draws, and average its colour over the non-transparent pixels: at 6/4
# the badges were 37-49% BLACK by area, so their apparent colour carried only about half
# the chroma of the tint they were given. No tint can fix that, because the tint is not
# what is on screen - the mean of tint-and-black is. At 4/3 the black share drops by
# roughly a quarter and the chroma comes back, and the keyline still does its actual job,
# which is guaranteeing an edge against terrain of any brightness.
#
# Thin-stroked glyphs suffer this worst (all edge, little fill), which is also an argument
# for FILLED source icons over outline ones wherever both exist - the bed, an outline
# drawing, sat at 42% black against the solid medic cross's 37%.
OUTLINE = 4
GLYPH_OUTLINE = 3

# Per-cell keyline override, for a glyph whose SPOT is drawn smaller than the rest.
#
# The width above is in cell pixels, so what reaches the screen is outline/128 * drawn_px
# -- which means a constant here is only constant if every spot is the same size, and they
# are not. Measured across the atlas the keyline lands at 0.61-0.81 final px on almost
# everything (task reticle 3 at 26 units-worth, medic frame 4 at 26, squadmini 6 at 13 --
# note that one is ALREADY an override for exactly this reason, at twice OUTLINE, because
# a 9-unit spot is the smallest thing here).
#
# The house fell through that. It is drawn at 12 units, the smallest bare glyph in the
# atlas, so GLYPH_OUTLINE 3 arrives as 0.38 px -- half what everything beside it gets, and
# below one pixel it stops being an edge at all and becomes a grey blend with the terrain.
# That is not a tint problem and no amount of chroma fixes it.
#
# 7 puts it at 0.88 px, matching the medic badge's 0.81. 9 was tried and is too far: at the
# 13 px the zoomed-out map draws, the black starts closing the doorway, and the doorway is
# the whole reason the glyph reads as a house rather than a pentagon (see svg/home.svg).
# The usual objection to thick keylines -- that black area drains the mark's apparent
# chroma, which is why 6/4 went to 4/3 in the first place -- applies least here of anywhere
# in the atlas: a solid silhouette inks ~51% of its cell against a ring badge's 35%, so the
# black share stays low even at 7.
GLYPH_OUTLINE_BY_NAME = {"home": 7}

# --- the two task marks -------------------------------------------------------
# The active task spot is TWO textures, not one: an icon, plus a static_border that
# CMapSpot shows only while that task is the selected one (show_static_border, driven
# from CMapLocation). Both are rebuilt here from measurements off what GAMMA actually
# draws today - the icon off AlphaLion's 23x23 reticle, the border off vanilla's 21x21
# ui_pda2_stask_last_02 - as fractions of their own cell.
#
# TASK: a broken outer ring (four arcs, gaps on the cardinals), a complete inner ring,
# and a four-tick centre crosshair. TASK_OUT_R is pulled in slightly from vanilla's
# 0.491, which runs to the cell edge and leaves no room for a keyline; 0.455 puts the
# outer edge within a hair of the service badges' ring, so a task marker and a service
# badge read as the same size on the map.
TASK_OUT_R = 0.455
# THICKER THAN THE BADGE RING ON PURPOSE, as of R2.49a. R2.49 thinned this to 1.45/23
# alongside RING_W, on the reasoning that one weight should run through the whole atlas.
# In play the thinner ring was right for the service badges and wrong here: a quest
# marker is the one mark the player is actively navigating TO, and at 26 px it has to
# win against terrain rather than sit politely in it. At a 35 px icon this is 3.04 px
# against the badge ring's 2.76 - heavier, but by a quarter of a pixel, so the two still
# read as one family.
TASK_OUT_W = 2.0 / 23
TASK_GAP_DEG = 11.0     # half-width of the gap at each cardinal
TASK_IN_R = 7.6 / 23
TASK_IN_W = 1.5 / 23
# Whether the complete inner ring is drawn at all. A switch rather than a constant
# because "drop it" is a shape decision, not a width one - set TASK_IN_W to 0 instead
# and PIL's max(1, round(w)) still lays down a hairline that survives the downsample.
# True is what ships; propose.py flips it to preview the reticle without it.
TASK_INNER = False
# 0.0: the crosshair is SOLID through the middle (R2.49b). Vanilla leaves a small hole
# here, and at its 1.2/23 stroke that reads as a hairline seam nobody sees. At 2.0/23 the
# same hole is a square notch punched out of the centre of the mark - the wider the arms,
# the bigger the hole, because it is a radius and they meet it from four sides. Set this
# back to 0.043 to get vanilla's gap, but only alongside a thinner TASK_TICK_W.
TASK_TICK_R0 = 0.0      # centre crosshair, inner and outer radius
# GROWN from 0.196 (R2.55). The clear radius inside the outer ring is
# TASK_OUT_R - TASK_OUT_W/2 = 0.4115, so 0.196 filled only 48% of it and left the plain
# task mark reading as a big empty hoop with a speck in it - the one mark in the atlas
# with no glyph had the least ink. 0.28 fills 68% of the clear radius and leaves a
# 0.13-cell gap to the ring, which is ~3.4 px at a 26 px icon: still visibly a crosshair
# INSIDE a ring rather than a plus sign wedged into one. Do not push past ~0.32; beyond
# that the arm tips touch the ring's blur at 20 units and the two shapes fuse.
TASK_TICK_R1 = 0.28
# WIDENED from vanilla's measured 1.2/23 (R2.49b). With the complete inner ring gone the
# crosshair is the only thing left inside the frame, so it carries the whole "aim here"
# half of the mark on its own and vanilla's hairline was not enough weight for that. 2.0
# lands it at 3.04 px at a 35 px icon - the SAME as the outer ring, so the mark reads as
# one stroke width throughout. 2.4 was tried and closes the centre gap into a blob at
# 26 px, which is the ceiling this is set just under.
TASK_TICK_W = 2.0 / 23
# Whether the centre crosshair is drawn. A switch for the same reason TASK_INNER is
# one, and it exists so the reticle can be used as an empty FRAME with a glyph inside
# it - see propose.mutant_reticle. True is what ships.
TASK_CROSSHAIR = True

# SELECT: four arcs of a CIRCLE, not the four corner brackets this used to draw. Every
# other mark in this atlas is round - the badge ring, the task reticle, the pulse - and a
# square bracket frame around a round badge was the one thing that did not belong.
#
# The arcs sit on the CARDINALS with the gaps on the diagonals, which is deliberately the
# INVERSE of the task reticle and the pulse ring: both of those put their gaps on the
# cardinals. That single difference is what keeps three concentric ring-ish marks legible
# as three different things when a selected task also happens to be a new one.
#
# Radius is in the border cell's own fraction, and the border is drawn LARGER than the
# icon it frames - 29 units against the spot's 19 - so 0.43 here lands at 12.5 units
# against the badge ring's 8.5, i.e. clearly outside it with air between the two.
SEL_R = 0.455
SEL_ARC = 30.0          # half-length of each arc, degrees either side of its cardinal
# Stroke, and the constraint here is HIERARCHY rather than ink. The border is drawn at 29
# units against the icon's 19, so the same fraction of a cell is ~1.5x thicker on screen
# here than on the badge. 2.2/21 was tried first, on the ink-area reasoning that widened
# the badge ring, and came out heavier than the ring it frames - four fat blobs on the
# cardinals rather than a frame. 1.45/21 lands at ~3.8px against the badge ring's ~3.9px
# at a 35px icon, so frame and badge read as the same weight, which is what makes one
# obviously contain the other.
# BACK TO 1.45/21 (R2.49c), the value this was originally tuned to. R2.49 thinned it to
# 1.05 with everything else and R2.49a left it there on an argument that turned out to be
# wrong, so it is worth recording what the mistake was.
#
# The argument was: at a 35 px icon 1.45/21 lands at 3.69 px against the reticle's 3.04,
# so the frame would be HEAVIER than the thing it frames and stop reading as a container.
# That was reasoned from the two stroke widths alone, and every preview behind it drew the
# two marks at the SAME size. They are not the same size - the border is 29 units against
# the icon's 19. Composited at that real ratio the frame reads as the outer element at any
# of these widths, because being 1.5x larger is what makes it outer; the stroke is free to
# be heavier. The "four fat blobs" failure this was afraid of was measured at 2.2/21, i.e.
# 5.6 px, not at 3.69.
#
# 1.70/21 (4.32 px) is the next step up and still clean if this needs to shout louder; the
# blobs start somewhere above that. This ring is also the ANIMATED one - the iqm_task_*
# spots give it light_anim="ui_slow_blinking_alpha" - so it is pulsing while it is on
# screen, which costs it apparent weight that a static preview does not show.
SEL_W = 1.45 / 21

# Thin-stroke marks need a thinner keyline than a solid glyph: the strokes are only
# ~10 final px wide, so 6 either side would nearly double their weight. Trimmed from 4
# to 3 with OUTLINE, for the same measured reason.
PROC_OUTLINE = 3

# BLINK: the ring that pulses and scales around a marker for 15 s after a task
# appears (ui_storyline_task_blink / ui_secondary_task_blink, ttl="15"). The bounce
# is the engine's xform_anim and the pulse its light_anim - neither is ours to
# change - but the art under them was a 25px source (ui_pda2_stask_last_01a) drawn
# into a 39-unit rect and then scaled UP again by that animation, which is why it
# reads as a soft halo. Four arcs on the diagonals like the task reticle, but with
# much wider cardinal gaps; measured off that 25px cell, pulled in from 0.46 so the
# stroke and keyline clear the cell edge.
BLINK_R = 0.42
BLINK_W = 2.0 / 25
BLINK_GAP_DEG = 20.0

# TRANSITION: the level changer - an ARCH with an arrow going through it. Drawn, not
# traced, for the same reason as the task marks and for one more: there is no icon set
# with this glyph in it. It is a gateway seen head-on, which no pictogram library draws
# because outside S.T.A.L.K.E.R. nothing needs one; Tabler's door-exit and Material's
# exit_to_app are both a door in perspective with an arrow beside it, a different mark.
#
# So this reproduces vanilla's, measured pixel by pixel off the 19x21
# ui_pda2_exit_point cell as AlphaLion's Reworked Map Markers recolours it (the copy
# GAMMA actually draws - modxml_AL_MapSpots re-points all nine level_changer elements
# at ui_AlphaLion_Transition and strips their r/g/b, so the green is baked, not tinted).
# Its art occupies 15x17 of that cell:
#
#   sides       vertical, x = 0 and x = 15, from y = 6 to the flat bottom at y = 17
#   roof        45 degrees, (0,6) to (6,0), a 3-wide flat apex, then (9,0) to (15,6)
#   stroke      ~1.2 px, i.e. a single source pixel down the sides
#   arrow       solid, 7 wide x 7 tall, centred on x and sitting in the body
#
# The stroke goes to 1.9 rather than that measured 1.2, the same 1.55x and for the same
# measured reason as RING_W: at 26px most of a thin-stroked mark's area is its keyline,
# and a mark's apparent colour is its mean over that area.
#
# ARROW_* are a little larger than vanilla's 7x7 - the interior is a wide flat-bottomed
# box and vanilla left most of it empty. The clearance that matters is the one between
# the arrow's keyline and the arch's, and at these numbers that is ~13 final px against
# the 7 the two keylines take, so they never merge into a blob.
#
# THIS CELL IS ROTATED IN GAME. There are eight level_changer_*_spot elements, one per
# compass point, differing only in heading_angle, and CMapSpot turns the quad by it.
# Two consequences: the art must point UP (heading_angle="1" is the up variant), and the
# spot must be SQUARE, because rotating a 19x21 rect by 45 degrees shears whatever is in
# it. The script sets width = height = 21 for that reason, not to resize the marker.
TRANS_W, TRANS_H = 15.0, 17.0   # art box, in source px of the vanilla 19x21 cell
TRANS_CHAMFER = 6.0             # 45-degree roof: rises 6 over 6 from each side
TRANS_STROKE = 1.9
TRANS_FIT = 108.0 / 128         # inked extent (stroke included) on the long axis
# Corner radii, art units. Vanilla's corners are as round as 19 source pixels let them
# be, which is to say the rounding is entirely the antialiasing - so a faithful trace
# gives hard corners and reads sharper and more angular than the icon it copies. These
# put the roundness back deliberately, at a radius the cell can actually resolve.
# Quoted as a RADIUS rather than a cut length: the arch's corners are 90 degrees at the
# bottom and 135 at the roof, and equal cuts on those would look like two different
# amounts of rounding.
TRANS_ROUND = 2.2
ARROW_ROUND = 0.9               # smaller: the arrow is half the size and has a point
ARROW_TIP = 4.8                 # arrow, in the same art units, from the art box top
ARROW_BASE = 10.2               # where the head meets the shaft
ARROW_HW = 4.2                  # half-width of the head
ARROW_SHAFT_HW = 1.7
ARROW_FOOT = 13.9

# SQUAD: the mark an NPC squad actually gets on the map. All 14 warfare_<faction>_spot
# types resolve to one pair of textures - ui_pda2_squad_leader on the map and
# ui_minimap_squad_leader on the minimap, both 11x11 cells in vanilla ui\ui_common -
# with the faction carried entirely by r/g/b on the spot. So this is ONE mark, and a
# white disk takes all 14 colours for free.
#
# TWO CELLS FOR ONE MARK, which nothing else in this atlas needs. Everywhere else a spot
# and its mini share a cell, because they are drawn at 19 and 14 units - close enough
# that one cell reads right at both. These are drawn at 13 and 9, and at that size the
# keyline is what breaks: as a FRACTION of the cell it would come out 1.44x thinner on
# the minimap, which at ~12.7 physical px (9 units at 1080p) is the difference between an
# outlined dot and a dot with a grey smudge round it. The radii and keylines below are
# picked so the black ring lands at the SAME FINAL PIXEL WIDTH in both views (~0.85 px at
# 1080p, matching the service badges), rather than the same fraction of a cell.
#
# The cost is that the minimap cell is ~28% black by area against the map cell's ~19%,
# where the badges were tuned to 23% (see OUTLINE). Taken deliberately: a 12.7 px dot
# needs a guaranteed edge against terrain more than it needs the last of its chroma, and
# a solid disk has far more ink per unit of edge than the thin-stroked badges that
# measurement came from. Lower SQUAD_MINI_OUTLINE to 8 to trade back the other way.
# (Those two figures were measured at the old extent of 60. Both rise as the extent
# shrinks - the ring keeps its width while the disk inside it gets smaller - but their
# RATIO is fixed at 1.47 by the two outlines, which is the part the sentence is about.)
#
# Both radii are derived from ONE inked extent so the two marks fill their cells by the
# same fraction: on-screen size then comes purely from the spot's 13 vs 9 units, and the
# only thing that differs between the cells is border weight - which is the entire point
# of there being two. Set the radii directly and that guarantee is one edit away from
# being lost.
#
# THE EXTENT IS SET BY INK MASS, NOT BY THE CELL (R2.61). It was 60 of the 64 available,
# i.e. wall to wall, the only limit being the 4 px of margin a keyline needs so it cannot
# bleed across an atlas seam - the same reason RING_R sits at 0.40 rather than 0.41. That
# is the wrong quantity to maximise, and it was reported as the dots being "much too big"
# on both views.
#
# THE FOOTPRINT WAS NEVER WRONG. The spots' 11/13/9 units are untouched, and this file
# cannot change them: no squad entry in the SPOTS table sets `el`. What was wrong is that
# a SOLID disk replaced two glyphs that were mostly holes, in a box of identical size.
# Mean alpha over the cell, measured on the copy GAMMA actually loads (UI Rework
# G.A.M.M.A. Style's ui\ui_common, which wins that file at priority 838):
#
#   ui_pda2_squad_leader     0.605   a near-solid reticle
#   ui_minimap_squad_leader  0.245   a four-point star, ~75% air
#   this disk at extent 60   0.686 / 0.688
#
# So the map view gained 13% ink and the minimap 2.8x, both in an unchanged rect. A
# mark's apparent size is its ink, not its rect, and that is the whole of the bug.
#
# 47 puts both cells at 0.42, the mean of the two vanilla figures. That is the honest
# split when ONE disk replaces two marks of different weight - lighter than vanilla on
# the map, heavier on the minimap - and it costs nothing that a per-view target would
# have bought, since a second extent would break the invariant above. Inked diameter goes
# 18.0 -> 14.3 px on the map and 12.5 -> 9.9 px on the minimap at 1080p.
#
# THE KEYLINE DOES NOT THIN WITH IT, which is what makes this the cheap fix: its width is
# SQUAD_*_OUTLINE art px of a cell still drawn at the same units, ~0.58 final px either
# way. What moves is black as a share of the MARK (alpha>128 and value<64): 9.8% / 16.4%
# at extent 60, 12.3% / 20.6% at 47, i.e. the mini cell goes from well under the badges'
# 23% to just under it. That is the number to watch if this is pushed further - below
# about 40 the ring starts to dominate a 9-unit dot rather than edge it.
SQUAD_EXTENT = 47.0         # inked radius incl. keyline, of the 64 available; see above
SQUAD_OUTLINE = 4           # map cell, drawn at 13 units
SQUAD_MINI_OUTLINE = 6      # minimap cell, drawn at 9 units
SQUAD_R = (SQUAD_EXTENT - SQUAD_OUTLINE) / 128
SQUAD_MINI_R = (SQUAD_EXTENT - SQUAD_MINI_OUTLINE) / 128

# THESE TWO CELLS ARE SHADED (R2.64) - see SHADE_CELLS and shade_bevel below. The disk was
# flat, one white value wall to wall, so every faction colour came out as a plain sticker.
# It is the roundest thing in the atlas and takes the ramp best; the measured cost, and
# the reason the ramp cannot be directional at 9 units, are both recorded down there.
#
# IT DOES NOT DISTURB R2.61. The ramp is RGB only, so the mean-alpha figures this section
# argues from (0.420 / 0.422, against the 0.42 target) still hold to the byte.


# Alpha of the black plate filling the arch, and the one place this mark departs from
# the rest of the atlas. Everywhere else the interior of a frame is left OPEN, because
# black area is what was measured to be washing the badges out - a mark's apparent
# colour is its mean over its own area, and at 26px a thin-stroked badge is mostly
# keyline. That argument does not reach here, for two reasons:
#
#   The gap is real. On the ring badges the frame and the glyph are ~11 final px apart,
#   so an interior fill IS the two keylines merging and the badge goes to a blob. The
#   arch's interior is ~13px clear on every side of the arrow, wide enough to read as a
#   plate with a mark on it.
#   The arrow needs it. Open, a green arrow sits on terrain inside a green arch and the
#   two greens compete; filled, it sits on black and the arch is the only thing the
#   terrain touches. Rendered at the 27px a 19-unit spot gets at 1080p, that is the
#   difference between legible and a small green smudge - and it is what vanilla and
#   AlphaLion both do, so it is also the more faithful of the two.
#
# 210/255 is AlphaLion's measured value, not opaque: the PDA screen still shows faintly
# through. Set to 0 for an open arch.
TRANS_FILL = 210




# ============================================================== SMOOTHING (R2.50)
# TWO KNOBS, BOTH REVERTIBLE ON THEIR OWN LINE. Set MIPMAPS = False and PREFILTER = 0.0
# and this file emits exactly what R2.49 emitted, byte for byte.
#
# THE PROBLEM THEY SOLVE. A cell is 128 px and a 19-unit spot is ~27 px at 1080p, so the
# GPU is minifying 4.7:1 - and on the 8-to-14-unit spots, up to 9:1. A sampler with no
# mipmaps does 4-tap bilinear, which reads FOUR texels out of the ~22 that should
# contribute; everything else is thrown away. On art with a hard black keyline that is not
# a small error, it is the keyline breaking into a dotted, stair-stepped fringe.
#
# This was invisible for a long time because every preview this tool draws - and every
# comparison sheet - resizes with PIL's LANCZOS, a proper area filter. The previews were
# showing what the art COULD look like, not what the engine draws. Simulate real 4-tap
# sampling and the difference is not subtle.
#
# It is also why vanilla's stash mark reads smoother than a rebuilt one despite being 27
# coarse pixels: 27 px into a 14-unit spot is roughly 1:1, so vanilla is never asking the
# sampler to do the thing it cannot do.

# --- MIPMAPS: the real fix -----------------------------------------------------
# A mip chain gives the sampler a pre-filtered level near the on-screen size, which is
# exactly the missing information. The usual objection to mipmapping an ATLAS is bleeding
# between cells, and it does not apply here - checked rather than assumed:
#
#   the cells are 128 px, a power of two, on a grid whose origins are multiples of 128,
#   and a box filter at level k averages aligned 2^k blocks. 128 is divisible by 2^k for
#   every k down to a single texel per cell, so no block ever straddles a cell edge.
#
# That guarantee holds for a BOX filter and not necessarily for whatever ImageMagick would
# use, which is why the DDS is written here instead (write_dds below) rather than by
# `magick`. The no-mip output of that writer was diffed against magick's and is identical
# apart from magick's "IMAGEMAGICK" stamp in the reserved field.
#
# The pack's other UI atlases are all 1-mip, so this is a departure from local convention.
# They can afford to be: their cells are close to their display size. Ours are not, on
# purpose - a 128 px cell is what makes a 19-unit spot sharp at 4K, and this is the other
# half of that bargain. Cost is 1.5 MB -> 2.0 MB.
MIPMAPS = True

# --- PREFILTER: insurance, in case the engine's UI path ignores mips ------------
# A gaussian applied to each finished cell BEFORE it is packed, sigma in cell pixels.
# Per-cell and pre-pack is the important part: a blur applied to the assembled atlas would
# pull neighbouring cells into each other, which is the bleeding MIPMAPS avoids by
# construction and this would reintroduce by hand.
#
# 1.0 is deliberately mild. It removes the highest frequencies the 4-tap sampler cannot
# represent at all, and at 4K - where a spot is ~53 px and mip 0 is what gets sampled - it
# costs about 0.4 px of edge softness, which is under the keyline's own antialiasing.
# Raise to ~1.6 if the marks still read harsh in game, which would mean the UI path is not
# sampling mips; drop to 0.0 to keep mip 0 exactly as authored.
PREFILTER = 1.0


# ================================================================ SHADING (R2.64)
# The marks were FLAT: one white value across the whole of a mark, so a tinted spot came
# out as a sticker of solid colour. This gives the solid ones a modelled surface, bright
# where the ink is deep and falling to SHADE_RIM at its edge.
#
# IT COSTS NOTHING IN COLOUR, which is the whole reason it is done in RGB. Every spot in
# this atlas is TINTED - the 14 warfare_<faction>_spot entries each set their own r/g/b,
# and the rest take a colour from the SPOTS table - and the engine applies that as a
# MULTIPLY. So RGB below 255 is a pure VALUE change: hue and saturation are untouched, and
# one ramp is correct for every colour a cell can be drawn in, with no per-tint art. It is
# the same property the black keyline runs on -- black times anything is black -- used at
# the other end of the range. tools/dot-tex/build.py makes the same argument.
#
# IT CANNOT ADD A HIGHLIGHT, only take brightness away, because multiply's ceiling is the
# tint itself. A specular pip would mean dropping the whole mark to ~200 so a 255 dot
# could read as brighter than it: 20% off everything to buy two pixels. Not taken. The
# core stays at 255 and the modelling is entirely in the falloff.
#
# WHY IT IS NOT DIRECTIONAL, which is the obvious thing to want and the wrong thing to
# build here. A light source from the upper left models a sphere convincingly at 128 px
# and has nowhere to happen at the sizes these are drawn: the squad disk's inked diameter
# is 14.3 px on the map and 9.9 px on the minimap at 1080p, of which the outer ~0.6 px is
# already keyline, so the highlight's offset would be ~2 px on one and sub-pixel on the
# other. That is precisely the off-centre-ring failure tools/dot-tex/build.py exists to
# avoid. A ramp that is symmetric about the shape cannot fail that way: it shares the
# keyline's centre by construction, so at the size where it stops resolving it degrades
# into "slightly darker mark" rather than into a defect.
#
# WHY EDGE DISTANCE AND NOT A RADIAL RAMP. A radial dome is only meaningful for a disk,
# and only the squad cells are one. Shading by the shape's OWN distance from its boundary
# generalises it: for a disk it IS the dome, and for a house or a skull it models the same
# surface without the code having to know the shape. One rule, so the marks cannot drift.
#
# DISTANCE IS A BLUR, deliberately. An iterative-erosion distance field is octagonally
# biased, which would show as flat spots on exactly the round marks this matters most for;
# a Gaussian is isotropic by construction. It also SATURATES deep inside a shape, which is
# the bright core plateau, so that falls out instead of needing its own knob.
#
# WHICH CELLS, and this is the part that is measured rather than chosen. A ramp needs an
# INTERIOR to live in - ink that is not already within a drawn pixel of its own edge. Erode
# each cell's ink (opaque AND lit: the keyline and the arch's plate are opaque but black,
# and a multiply does nothing to black, so they are not interior) by one drawn pixel at
# 1080p, as a share of that cell's ink:
#
#   home 72%  squad 61%  handin 57%  above/belowbare 54%  skull 50%  taskdelivery 49%
#   squadmini 45%  |  pointer 32%  trader 30%  medic 23%  transition 12%  |  task 5%
#   taskbounty 0.2%  taskopen / select / question / blink / alert 0%
#
# SHADE_CELLS is the first group. The last group is all edge, where a ramp can only darken
# the stroke - which is the "a mark's apparent colour is its mean over its own area" rule
# the badge sizes are tuned to, and the reason their interiors are left open at all. The
# MIDDLE group measures better than it renders, and that is the useful warning: a bevel
# eats a thin stroke from BOTH sides at once, so at 26 px it takes the medic ring from a
# bright keyline to a muddy one for -34% mean value, against -16% on the disk. Interior
# percentage predicts the cost almost exactly; anything under ~45% is not worth it.
#
# transition is the one to remember: 79% interior by total alpha and 12% by ink. What
# filled it was TRANS_FILL's black plate, not the mark. It looks like a candidate and is
# not one, which is why the measurement above is on ink and not on alpha.
#
# APPLIED TO THE FINISHED CELL, not inside compose(), and that is exact rather than
# approximate. A composited pixel is ink*ia + black*(1-ia) = ink*ia, so scaling the result
# by s gives ink*ia*s, which is what scaling the ink first and then compositing gives.
# Multiplying the whole cell is therefore identical to multiplying only its ink, and it
# costs one call site that covers all three kinds of cell instead of three.
#
# REVERTIBLE ON ONE LINE, like MIPMAPS and PREFILTER: SHADE_RIM = 255 makes shade_bevel a
# no-op and this file emits exactly what R2.63 emitted.
SHADE_RIM = 150         # RGB at a mark's edge, of 255. 255 = flat, i.e. off
SHADE_DEPTH = 14.0      # how far in the ramp reaches, in cell px; the blur's radius
SHADE_GAMMA = 1.5       # >1 holds the core bright and crowds the falloff onto the edge
SHADE_CELLS = {"squad", "squadmini", "home", "handin", "abovebare", "belowbare",
               "skull", "taskdelivery"}


def shade_bevel(cell, name):
    """Multiply a finished cell's RGB by an edge-distance ramp over its own ink.

    The mask is the cell's LIT and opaque pixels, so the keyline is not part of the shape
    whose distance is being measured - otherwise the ramp would peak on the keyline's
    centreline and put a bright band around the mark rather than a dark one.

    Outside the ink the ramp floors at SHADE_RIM rather than continuing down to black. It
    has to: alpha is 0 out there, but write_dds box-filters RGB and alpha independently,
    so RGB from fully transparent pixels DOES bleed into the mip chain. Flooring keeps
    what bleeds identical to the rim value it is bleeding into.
    """
    if SHADE_RIM >= 255 or name not in SHADE_CELLS:
        return cell
    r, g, b, a = cell.split()
    ink = ImageChops.multiply(a.point(lambda v: 255 if v > 128 else 0),
                              r.point(lambda v: 255 if v > 128 else 0))
    d = ink.filter(ImageFilter.GaussianBlur(SHADE_DEPTH))
    # The blur reads ~0.5 on the boundary and rises toward 1.0 deep inside, so the useful
    # signal is the upper half of the range. NORMALISED TO THE SHAPE'S OWN DEEPEST POINT
    # rather than to 1.0: a thin mark never reaches 1.0, so a fixed scale would leave its
    # core short of white and take the whole mark down with it. Measured over the eight
    # shaded cells, that fixed scale costs -17% of mean value on the disk against -27% on
    # the envelope; normalising pulls the spread from 10.2 points to 5.2 and centres it on
    # the disk. It is the same principle as SQUAD_OUTLINE's: hold the PROPORTION of the
    # mark, not a fixed measure, so shapes of different weight read alike.
    #
    # The exponent is 1/GAMMA because t counts DEPTH here, where a radial ramp would count
    # distance from the centre - the same curve, read from the other end.
    top = max(0.05, d.getextrema()[1] / 255.0 - 0.5)
    lut = []
    for v in range(256):
        t = max(0.0, min(1.0, (v / 255.0 - 0.5) / top))
        lut.append(int(round(SHADE_RIM + (255 - SHADE_RIM) * t ** (1.0 / SHADE_GAMMA))))
    s = d.point(lut)
    return Image.merge("RGBA", [ImageChops.multiply(ch, s) for ch in (r, g, b)] + [a])


def prefilter(cell):
    """PREFILTER applied to one finished cell. No-op at 0.0."""
    return cell.filter(ImageFilter.GaussianBlur(PREFILTER)) if PREFILTER > 0 else cell


def write_dds(img, path):
    """Uncompressed 32-bit A8R8G8B8 DDS, with a box-filtered mip chain when MIPMAPS.

    Written by hand rather than shelled out to `magick` for one reason: the no-bleed
    guarantee above is a property of the BOX filter, and this is the only way to know
    which filter built the chain.
    """
    levels = [img]
    while MIPMAPS and (levels[-1].width > 1 or levels[-1].height > 1):
        w, h = max(1, levels[-1].width // 2), max(1, levels[-1].height // 2)
        levels.append(levels[-1].resize((w, h), Image.BOX))

    n = len(levels)
    flags = 0x1 | 0x2 | 0x4 | 0x8 | 0x1000 | (0x20000 if n > 1 else 0)
    caps = 0x1000 | ((0x400000 | 0x8) if n > 1 else 0)
    hdr = b"DDS " + struct.pack("<7I", 124, flags, img.height, img.width,
                                img.width * 4, 0, n)
    hdr += bytes(44)                                    # dwReserved1[11]
    hdr += struct.pack("<8I", 32, 0x41, 0, 32,           # DDPF_RGB | DDPF_ALPHAPIXELS
                       0x00ff0000, 0x0000ff00, 0x000000ff, 0xff000000)
    hdr += struct.pack("<5I", caps, 0, 0, 0, 0)
    with open(path, "wb") as fh:
        fh.write(hdr)
        for m in levels:
            r, g, b, a = m.convert("RGBA").split()
            fh.write(Image.merge("RGBA", (b, g, r, a)).tobytes())   # A8R8G8B8 is BGRA
    return n


def disk(r):
    """Offsets inside a radius-r disk - a round dilation kernel. A square one
    (Pillow's MaxFilter) would put corners on the keyline of a round badge."""
    return [(dx, dy) for dx in range(-r, r + 1) for dy in range(-r, r + 1)
            if dx * dx + dy * dy <= r * r]


def keyline(a, r):
    """Dilate an alpha channel by r px: max of the alpha over a disk of offsets.
    Keeps the source's antialiasing at the outer edge, so the keyline is soft-edged
    rather than stair-stepped. ImageChops.offset wraps, which is harmless because
    the badge is inset inside the cell."""
    out = a
    for dx, dy in disk(r):
        out = ImageChops.lighter(out, ImageChops.offset(a, dx, dy))
    return out


def render_svg(name, px):
    """SVG -> white-on-transparent PNG of px on its long axis, via ImageMagick."""
    src = os.path.join(SVGDIR, name + ".svg")
    dst = os.path.join(HERE, "_" + name + ".png")
    subprocess.run(["magick", "-background", "none", "-density", "800", src,
                    "-resize", "%dx%d" % (px, px), "-channel", "RGB",
                    "-fill", "white", "-colorize", "100", "+channel", dst],
                   check=True)
    return dst


def fit(g, box):
    """Scale a trimmed glyph so its LONG axis is `box` px. Aspect is preserved and
    the short axis is left short - the caller centres it in a square cell, which is
    what keeps a wide glyph from being stretched by the square spot rect."""
    w, h = g.size
    s = box / max(w, h)
    return g.resize((max(1, round(w * s)), max(1, round(h * s))), Image.LANCZOS)


def badge_frame():
    """The ring and its four ticks, white on transparent, at final cell size --
    plus the filled disk of the ring's inner area, which the keyline pass uses to
    keep black out of the badge interior."""
    n = CELL * SS
    c = n / 2.0
    layer = Image.new("L", (n, n), 0)
    hole = Image.new("L", (n, n), 0)
    d = ImageDraw.Draw(layer)

    r = RING_R * n
    hw = RING_W * n / 2.0
    d.ellipse([c - r - hw, c - r - hw, c + r + hw, c + r + hw], fill=255)
    d.ellipse([c - r + hw, c - r + hw, c + r - hw, c + r - hw], fill=0)
    ImageDraw.Draw(hole).ellipse([c - r + hw, c - r + hw, c + r - hw, c + r - hw],
                                fill=255)

    # ticks straddle the ring centreline, so they read as crosshair marks crossing
    # the ring rather than as spokes touching it
    if TICKS:
        tl, tw = TICK_LEN * n / 2.0, TICK_W * n / 2.0
        for horiz in (True, False):
            for sign in (-1, 1):
                along = (c + sign * r - tl, c + sign * r + tl)
                across = (c - tw, c + tw)
                box = (along[0], across[0], along[1], across[1]) if horiz else \
                      (across[0], along[0], across[1], along[1])
                d.rectangle(box, fill=255)

    out = Image.new("RGBA", (n, n), (255, 255, 255, 0))
    out.putalpha(layer)
    return (out.resize((CELL, CELL), Image.LANCZOS),
            hole.resize((CELL, CELL), Image.LANCZOS))


def draw_task(n):
    """The task reticle: broken outer ring, inner ring, centre crosshair."""
    m = Image.new("L", (n, n), 0)
    d = ImageDraw.Draw(m)
    c = n / 2.0

    def ring(r, w, arcs=None):
        box = [c - r, c - r, c + r, c + r]
        if arcs is None:
            d.ellipse(box, outline=255, width=max(1, round(w)))
        else:
            for a0, a1 in arcs:
                d.arc(box, a0, a1, fill=255, width=max(1, round(w)))

    # gaps sit on the cardinals, so the four arcs are centred on the diagonals
    g = TASK_GAP_DEG
    ring(TASK_OUT_R * n, TASK_OUT_W * n,
         [(k + g, k + 90 - g) for k in (0, 90, 180, 270)])
    if TASK_INNER:
        ring(TASK_IN_R * n, TASK_IN_W * n)

    if TASK_CROSSHAIR:
        r0, r1, hw = TASK_TICK_R0 * n, TASK_TICK_R1 * n, TASK_TICK_W * n / 2.0
        for horiz in (True, False):
            for s in (-1, 1):
                lo, hi = sorted((c + s * r0, c + s * r1))
                box = (lo, c - hw, hi, c + hw) if horiz else (c - hw, lo, c + hw, hi)
                d.rectangle(box, fill=255)
    return m


def draw_select(n):
    """The selection frame: four arcs on the cardinals, gaps on the diagonals."""
    m = Image.new("L", (n, n), 0)
    d = ImageDraw.Draw(m)
    c = n / 2.0
    r = SEL_R * n
    for k in (0, 90, 180, 270):
        d.arc([c - r, c - r, c + r, c + r], k - SEL_ARC, k + SEL_ARC,
              fill=255, width=max(1, round(SEL_W * n)))
    return m


def draw_blink(n):
    """The new-task pulse ring: four arcs on the diagonals, wide cardinal gaps."""
    m = Image.new("L", (n, n), 0)
    d = ImageDraw.Draw(m)
    c = n / 2.0
    r = BLINK_R * n
    g = BLINK_GAP_DEG
    for k in (0, 90, 180, 270):
        d.arc([c - r, c - r, c + r, c + r], k + g, k + 90 - g,
              fill=255, width=max(1, round(BLINK_W * n)))
    return m








def round_poly(pts, r, steps=14):
    """Round every corner of a closed polygon to radius `r`, returning a denser point
    list. Each corner becomes a quadratic Bezier from one tangent point to the other
    with the original vertex as its control - close enough to a circular arc at these
    radii, and it needs no arc-direction bookkeeping, so reflex corners (the arrow's
    shoulders) round correctly with the same code as convex ones.

    The cut back along each edge is r/tan(theta/2), not r, so a 90-degree corner and a
    135-degree one come out looking equally round. Clamped to half an edge so a short
    edge between two corners cannot be consumed twice."""
    import math
    out = []
    m = len(pts)
    for i in range(m):
        c = pts[i]
        p, q = pts[(i - 1) % m], pts[(i + 1) % m]
        v1 = (p[0] - c[0], p[1] - c[1])
        v2 = (q[0] - c[0], q[1] - c[1])
        l1 = math.hypot(*v1) or 1e-9
        l2 = math.hypot(*v2) or 1e-9
        u1 = (v1[0] / l1, v1[1] / l1)
        u2 = (v2[0] / l2, v2[1] / l2)
        theta = math.acos(max(-1.0, min(1.0, u1[0] * u2[0] + u1[1] * u2[1])))
        if theta < 1e-6 or abs(theta - math.pi) < 1e-6:
            out.append(c)
            continue
        cut = min(r / math.tan(theta / 2.0), l1 / 2.0, l2 / 2.0)
        t1 = (c[0] + u1[0] * cut, c[1] + u1[1] * cut)
        t2 = (c[0] + u2[0] * cut, c[1] + u2[1] * cut)
        for s in range(steps + 1):
            t = s / steps
            w = (1 - t) ** 2, 2 * (1 - t) * t, t ** 2
            out.append((w[0] * t1[0] + w[1] * c[0] + w[2] * t2[0],
                        w[0] * t1[1] + w[1] * c[1] + w[2] * t2[1]))
    return out


def draw_transition(n):
    """The level-transition arch with its arrow, pointing up.

    Returns three masks rather than one, because this mark is a FRAME around a
    GLYPH and the two need different keylines - exactly the split build_cell makes
    for the badge ring. The frame's keyline is clipped to the arch's outside (the
    third mask is the interior), so the interior stays open and lets terrain
    through, as vanilla does; the arrow keeps its own keyline all the way round.
    Grown toward each other instead, at 26px the two would close the ~13px gap
    between them and the mark would read as a solid blob."""
    s = TRANS_STROKE
    # the stroke is centred on the path, so it reaches s/2 outside the art box
    k = TRANS_FIT * n / max(TRANS_W + s, TRANS_H + s)
    ox = (n - (TRANS_W + s) * k) / 2.0 + s / 2.0 * k
    oy = (n - (TRANS_H + s) * k) / 2.0 + s / 2.0 * k
    P = lambda x, y: (ox + x * k, oy + y * k)

    c = TRANS_CHAMFER
    # rounded in ART units, then mapped, so the radii read as the drawing's own
    arch = [P(*pt) for pt in round_poly(
        [(0, c), (c, 0), (TRANS_W - c, 0), (TRANS_W, c),
         (TRANS_W, TRANS_H), (0, TRANS_H)], TRANS_ROUND)]

    frame = Image.new("L", (n, n), 0)
    ImageDraw.Draw(frame).line(arch + [arch[0]], fill=255,
                               width=max(1, round(s * k)), joint="curve")
    # the interior is the filled outline MINUS the stroke, so it is exact whatever
    # the stroke width - no polygon offsetting, which a 45-degree mitre makes fiddly
    solid = Image.new("L", (n, n), 0)
    ImageDraw.Draw(solid).polygon(arch, fill=255)
    hole = ImageChops.subtract(solid, frame)

    cx = TRANS_W / 2.0
    glyph = Image.new("L", (n, n), 0)
    ImageDraw.Draw(glyph).polygon(
        [P(*pt) for pt in round_poly(
            [(cx, ARROW_TIP),
             (cx + ARROW_HW, ARROW_BASE), (cx + ARROW_SHAFT_HW, ARROW_BASE),
             (cx + ARROW_SHAFT_HW, ARROW_FOOT), (cx - ARROW_SHAFT_HW, ARROW_FOOT),
             (cx - ARROW_SHAFT_HW, ARROW_BASE), (cx - ARROW_HW, ARROW_BASE)],
            ARROW_ROUND)],
        fill=255)
    return frame, glyph, hole


# POINTER: the arrow the engine parks at the map's edge, rotated to face a marker that is
# off screen. Vanilla's ui_hud_map_arrow is an 11x24 cell and GAMMA's winning map_spots.xml
# (Sota UI EGUI Style HUD) replaces it with ui\enhancedGUI\QuestArrow - whose inked art is
# 68x43 px inside a 512x512 texture, 98.9% of it empty, drawn into a 172-unit rect. That is
# why it reads as a soft yellow blob: the mark is a fraction of a texture built for
# something else, and its edges were never sharp to begin with.
#
# Rebuilt at vanilla's own 11:24 proportions rather than Sota's, because that shape is what
# an arrow at ~20 units needs: long enough to read as a direction, narrow enough not to be
# mistaken for a spot. The concave base is what separates it from the level-changer's arrow
# (which is a solid shaft inside an arch) at a glance.
PTR_W, PTR_H = 11.0, 24.0       # art box, in vanilla ui_hud_map_arrow's own units
PTR_NOTCH = 17.0                # where the concave base meets the centreline
PTR_ROUND = 1.1                 # corner radius, same art units
PTR_FIT = 112.0 / 128           # inked extent on the long axis, keyline excluded
#
# THE CELL IS SQUARE AND SO IS THE SPOT, which is not a detail. A pointer element carries
# heading="1", so the engine ROTATES the quad (CMapSpot::Load skips the load-time kx multiply
# and rotate_pt applies it at render time instead, UIStaticItem.cpp:144-165). Rotating a
# non-square rect shears whatever is in it - the same reason the eight level_changer spots
# are forced to 21x21 in modxml_n_iqm_map_icons. So the ARROW is 11:24 and the CELL it lives
# in is 1:1, and the spot element declares equal width and height.
#
# It also means this mark takes the handheld PDA's 0.75 width squash (see PRESTRETCH), and a
# triangle is exactly the shape NO_BADGE's rule says survives that: straight edges and
# corners tolerate the squash, circles report it.


def draw_pointer(n):
    """The off-screen pointer: a narrow arrowhead with a concave base, pointing UP."""
    k = PTR_FIT * n / max(PTR_W, PTR_H)
    ox, oy = (n - PTR_W * k) / 2.0, (n - PTR_H * k) / 2.0
    P = lambda x, y: (ox + x * k, oy + y * k)
    pts = [(PTR_W / 2.0, 0.0), (PTR_W, PTR_H), (PTR_W / 2.0, PTR_NOTCH), (0.0, PTR_H)]
    m = Image.new("L", (n, n), 0)
    # round_poly handles the reflex corner at the notch with the same code as the convex
    # ones, which is the whole reason it is written as Beziers rather than as arcs.
    ImageDraw.Draw(m).polygon([P(*p) for p in round_poly(pts, PTR_ROUND)], fill=255)
    return m


def draw_disk(r):
    """A solid disk of radius r (a fraction of the cell). compose() then grows the
    keyline outward from its edge, which is the whole mark: a filled circle with a
    black border."""
    def fn(n):
        m = Image.new("L", (n, n), 0)
        c = n / 2.0
        rr = r * n
        ImageDraw.Draw(m).ellipse([c - rr, c - rr, c + rr, c + rr], fill=255)
        return m
    return fn


PROC = {"task": draw_task, "select": draw_select, "blink": draw_blink,
        "transition": draw_transition, "pointer": draw_pointer,
        "squad": draw_disk(SQUAD_R), "squadmini": draw_disk(SQUAD_MINI_R)}

# --- the task-KIND reticles ---------------------------------------------------
# cell name -> the svg/ glyph that goes inside it. These are the task reticle used as
# a FRAME: TASK_INNER and TASK_CROSSHAIR are both forced off while the frame is drawn,
# and the glyph takes the space they leave.
#
# WHY A COMPOSITE RATHER THAN A BARE GLYPH OR A TINT. The reticle keeps saying "a task,
# go and find it" and the glyph says which kind - the same grammar as the service
# badges, where the ring is the category and the glyph is the member. The two things it
# replaces each said only half of that: the bare skull said "mutant" and dropped the
# fact that it was a task at all, and the plain red reticle said "task" and left the
# colour to carry the rest, which meant a bounty and a storyline task differed only in
# hue at 26 px.
#
# THE SPACE, measured, because this is the same trade NO_BADGE was written about. With
# the inner ring and the crosshair gone the frame's clear interior is a 52.7 px radius,
# of which a glyph's keyline takes 3, so RETICLE_FIT lands the glyph in a 74 px box with
# ~7.5 px of clearance - against the ~10 px the ring badges are tuned to, and against
# 110 px for a bare cell. Both numbers are DERIVED from TASK_OUT_R and TASK_OUT_W rather
# than written down, which is why RETICLE_FIT survived the reticle stroke going back to
# 2.0/23 in R2.49a: a thicker ring eats its own interior and the glyph follows it in.
#
# The two do not pay the same price for that. The BUST is already drawn at ~70 px inside
# the badge ring for the VIP, so 74 px inside the reticle is still slightly MORE room than
# the glyph is proven at and the bounty gives up nothing. The SKULL gives up 31% of its
# linear size and just over half its area against the bare cell it replaces, and at
# 26 px its sockets start to close - the failure that made that cell bare in the first
# place. Accepted because the grammar is worth it and the minimap is the smaller of the
# two views; svg/skull.svg and the "skull" cell above are both still here if it needs
# backing out.
#
# HANDIN IS HERE TOO (R2.49b), and it is the one entry that is a RE-CLASSIFICATION rather
# than a new mark. It was a ring badge with a diamond in it, which put it in the services'
# visual family; but it is a TASK marker - the pin that appears on the giver once an
# objective is done - so it belongs in the task family, and the reticle frame is what says
# so. Its glyph does not change, only the frame around it. Note the consequence: a reticle
# cell has no centre crosshair (build_reticle_cell forces TASK_CROSSHAIR off), so the
# diamond sits in a clear frame rather than on top of a cross.
# A value of None is a frame with NO glyph - see the taskopen note in SRCS.
RETICLE = {"taskmutant": "skull", "taskbounty": "bounty", "taskopen": None}
RETICLE_FIT = 0.70      # glyph box as a fraction of the frame's clear inner diameter

# Per-cell fudge on that, and it exists for the same reason FIT_SCALE does: RETICLE_FIT
# sizes a bounding BOX, and how much of the box a glyph actually uses depends on its shape.
# The hand-in diamond is a rotated square, so its points sit at its box's edge MIDPOINTS
# rather than its corners - it clears the frame by 13.1 px at 1.0 where the skull clears it
# by 7.4, i.e. it looks small next to the other two for no reason but geometry. 1.12 brings
# it to ~8 px, matching them.
#
# taskbounty 1.15 is a DIFFERENT correction from the diamond's, and the distinction is
# the useful part. The diamond's 1.12 fixes a bounding-box artefact: it looked small
# because its points sit at its box's edge midpoints. The swords are not sized wrongly,
# they are simply THIN - an X is strokes where the skull opposite it is a solid mass, so
# at equal box size the human mark carries 45% of the mutant mark's lit pixels and reads
# dimmer for it (the mean-over-area rule, per skull.svg and the palette note in
# modxml_n_iqm_map_icons). 1.15 takes that to 55%, measured, with the blade tips still
# clear of the reticle arcs. 1.30 was tried and puts them through it - that is the
# ceiling, and it is why this does not simply close the gap to 100%.
RETICLE_FIT_SCALE = {"handin": 1.12, "taskbounty": 1.15}

# Keyline width for a drawn cell, where PROC_OUTLINE is wrong for it. The squad marks
# are the only cells whose keyline is set per VIEW rather than per mark - see SQUAD_R.
# The pointer takes the badges' 4 rather than the thin-stroke 3: it is a SOLID shape, so it
# has the ink to carry a full keyline, and it is the one mark that is guaranteed to be drawn
# against unknown terrain at the very edge of the map rather than over the area the player is
# already looking at. Same reasoning as SQUAD_OUTLINE.
PROC_OUTLINE_BY = {"squad": SQUAD_OUTLINE, "squadmini": SQUAD_MINI_OUTLINE,
                   "pointer": OUTLINE}


def compose(frame, glyph, hole, frame_outline, fill=0):
    """White ink over a black keyline, all at final cell size. `hole` is subtracted
    from the frame's keyline so it grows outward only; pass a blank one for a mark
    with nothing to protect. `fill` re-adds the interior at that alpha, which is how
    the arch gets its plate - one black layer carries keyline and plate both, so the
    two cannot seam against each other. Ink is flat white here; a mark's modelling is
    applied to the finished cell by shade_bevel, which is exact - see its note."""
    at = ImageChops.subtract(keyline(frame, frame_outline), hole)
    if fill:
        at = ImageChops.lighter(at, hole.point(lambda v: v * fill // 255))
    at = ImageChops.lighter(at, keyline(glyph, GLYPH_OUTLINE))
    ink = Image.new("RGBA", (CELL, CELL), (255, 255, 255, 0))
    ink.putalpha(ImageChops.lighter(frame, glyph))
    black = Image.new("RGBA", (CELL, CELL), (0, 0, 0, 255))
    black.putalpha(at)
    cell = Image.new("RGBA", (CELL, CELL), (255, 255, 255, 0))
    cell.alpha_composite(black)
    cell.alpha_composite(ink)
    return cell


def build_proc_cell(name):
    """A drawn cell: geometry at SS, downsampled, then keylined. A draw fn returns
    either one mask (uniform keyline, no interior to protect) or the frame / glyph /
    interior triple that a frame-around-a-glyph mark needs."""
    n = CELL * SS
    parts = PROC[name](n)
    down = lambda m: m.resize((CELL, CELL), Image.LANCZOS)
    if isinstance(parts, tuple):
        frame, glyph, hole = (down(m) for m in parts)
        return compose(frame, glyph, hole, OUTLINE,
                       TRANS_FILL if name == "transition" else 0)
    blank = Image.new("L", (CELL, CELL), 0)
    return compose(down(parts), blank, blank,
                   PROC_OUTLINE_BY.get(name, PROC_OUTLINE))


def build_reticle_cell(name):
    """A task-kind cell: the reticle as an empty frame with RETICLE[name] inside it.

    Shares draw_task and compose with the ordinary reticle rather than reimplementing
    the arcs, so the two can never drift apart on screen - a mutant hunt and a plain
    task have to read as the same mark wearing different content, and that is only
    guaranteed if the frame is literally the same code.
    """
    global TASK_INNER, TASK_CROSSHAIR
    n = CELL * SS
    keep = (TASK_INNER, TASK_CROSSHAIR)
    try:
        TASK_INNER, TASK_CROSSHAIR = False, False
        frame = draw_task(n).resize((CELL, CELL), Image.LANCZOS)
    finally:
        TASK_INNER, TASK_CROSSHAIR = keep

    # The interior of the outer ring, so compose() grows the frame's keyline OUTWARD
    # only. Without it the ring blacks inward and eats the clearance measured above.
    c, rr = n / 2.0, (TASK_OUT_R - TASK_OUT_W / 2) * n
    hole = Image.new("L", (n, n), 0)
    ImageDraw.Draw(hole).ellipse([c - rr, c - rr, c + rr, c + rr], fill=255)
    hole = hole.resize((CELL, CELL), Image.LANCZOS)

    glyph = RETICLE[name]
    if glyph is None:
        # An empty frame. compose() still needs a glyph layer, and a blank one is not a
        # special case anywhere downstream: keyline(blank) is blank, so the mark is just
        # the ring - which is the whole point, since what shows through the middle is
        # whatever the map already drew there.
        return compose(frame, Image.new("L", (CELL, CELL), 0), hole, OUTLINE)

    box = round(RETICLE_FIT_SCALE.get(name, 1.0)
              * RETICLE_FIT * 2 * (TASK_OUT_R - TASK_OUT_W / 2) * CELL)
    png = render_svg(glyph, box * 4)
    im = Image.open(png).convert("RGBA")
    g = fit(im.crop(im.split()[3].getbbox()), box)
    im.close()
    os.remove(png)
    layer = Image.new("RGBA", (CELL, CELL), (255, 255, 255, 0))
    layer.alpha_composite(g, ((CELL - g.size[0]) // 2, (CELL - g.size[1]) // 2))
    return compose(frame, layer.split()[3], hole, OUTLINE)


def build_cell(name):
    """One finished cell: badge frame (optional) + inner glyph + black keyline."""
    ringed = BADGE and name not in NO_BADGE
    inner_d = 2 * (RING_R - RING_W / 2) * CELL
    fit_k = FIT_SCALE.get(name, 1.0)
    box = round(fit_k * (GLYPH_FIT * inner_d if ringed else BARE_FIT * CELL))
    # a pre-stretched glyph has to be sized down first or the stretch clips on the cell
    box = round(box / PRESTRETCH.get(name, 1.0))
    png = render_svg(GLYPH_SRC.get(name, name), box * 4)
    im = Image.open(png).convert("RGBA")
    g = fit(im.crop(im.split()[3].getbbox()), box)
    if name in PRESTRETCH:
        g = g.resize((max(1, round(g.size[0] * PRESTRETCH[name])), g.size[1]),
                     Image.LANCZOS)
    im.close()
    os.remove(png)

    blank = Image.new("RGBA", (CELL, CELL), (255, 255, 255, 0))
    if ringed:
        frame, hole = badge_frame()
    else:
        frame, hole = blank.copy(), Image.new("L", (CELL, CELL), 0)

    # Keylines are built per part and unioned, so the frame's can be clipped to
    # "outside the ring" while the glyph keeps its own all the way round.
    at = ImageChops.subtract(keyline(frame.split()[3], OUTLINE), hole)
    glyph_layer = blank.copy()
    nx, ny = GLYPH_NUDGE.get(name, (0, 0))
    glyph_layer.alpha_composite(g, ((CELL - g.size[0]) // 2 + nx,
                                    (CELL - g.size[1]) // 2 + ny))
    at = ImageChops.lighter(at, keyline(glyph_layer.split()[3],
                                       GLYPH_OUTLINE_BY_NAME.get(name, GLYPH_OUTLINE)))

    ink = frame.copy()
    ink.alpha_composite(glyph_layer)

    # black under white, sharing the unioned keyline alpha
    black = Image.new("RGBA", (CELL, CELL), (0, 0, 0, 255))
    black.putalpha(at)
    cell = blank.copy()
    cell.alpha_composite(black)
    cell.alpha_composite(ink)
    return cell


def write_preview(cells):
    """Contact sheet at the sizes these are really drawn at: ~26px minimap, ~35px
    map at 1x, ~70px map zoomed. Judge an icon here, never at 128.

    13 and 18 are the squad marks' own sizes - 9 and 13 units at 1080p, the smallest
    anything in this atlas is drawn at, and small enough that a mark can pass at 26px
    and still fail there."""
    sizes = (13, 18, 26, 35, 70)
    pad, gap = 12, 10
    row_h = max(sizes) + gap
    sheet = Image.new("RGBA", (pad * 2 + sum(sizes) + gap * len(sizes),
                               pad * 2 + row_h * len(cells)), (176, 172, 158, 255))
    for i, ((name, tint), cell) in enumerate(zip(SRCS, cells)):
        r, g, b, a = cell.split()
        t = Image.merge("RGB", [ch.point(lambda v, k=k: v * k // 255)
                                for ch, k in zip((r, g, b), tint)])
        t.putalpha(a)
        x = pad
        for s in sizes:
            sheet.alpha_composite(t.resize((s, s), Image.LANCZOS),
                                  (x, pad + i * row_h + (max(sizes) - s) // 2))
            x += s + gap
    sheet.convert("RGB").resize((sheet.width * 3, sheet.height * 3),
                                Image.LANCZOS).save(PREVIEW)
    print("wrote", PREVIEW)


TEXDESCR = os.path.normpath(os.path.join(
    HERE, "..", "..", "gamedata", "configs", "ui", "textures_descr", "iqm_textures.xml"))


def verify_declarations():
    """Every SRCS cell is declared at the origin this layout actually put it at.

    The grid growth rule at the top of this file says APPEND, never widen -- because a cell
    inserted mid-grid slides every origin after it while the texture ids stay valid, so the
    game silently draws the wrong art and nothing errors anywhere. That rule was enforced by
    reading, which is exactly the kind of enforcement that lasts until somebody is in a
    hurry. This is one regex over a file we already ship and it makes the rule mechanical.

    Returns a list of complaints; empty means the atlas and the declarations agree.
    """
    import re
    try:
        with open(TEXDESCR, encoding="utf-8") as fh:
            src = fh.read()
    except OSError as exc:
        return ["cannot read %s: %s" % (TEXDESCR, exc)]
    seen = {}
    for m in re.finditer(r'<texture\s+id="(iqm_mapspot_[\w]+)"\s+x="(\d+)"\s+y="(\d+)"'
                         r'\s+width="(\d+)"\s+height="(\d+)"', src):
        seen[m.group(1)] = tuple(int(v) for v in m.groups()[1:])
    bad = []
    for i, (name, _tint) in enumerate(SRCS):
        tid = "iqm_mapspot_" + name
        want = ((i % COLS) * CELL, (i // COLS) * CELL, CELL, CELL)
        got = seen.get(tid)
        if got is None:
            bad.append("%s is not declared in iqm_textures.xml" % tid)
        elif got != want:
            bad.append("%s declared at %s, atlas puts it at %s" % (tid, got, want))
    extra = [k for k in seen if k[len("iqm_mapspot_"):]
             not in {n for n, _ in SRCS}]
    for k in sorted(extra):
        bad.append("%s is declared but this build draws no such cell" % k)
    return bad


def main():
    atlas = Image.new("RGBA", (W, H), (255, 255, 255, 0))
    cells = []
    for i, (name, _tint) in enumerate(SRCS):
        cell = (build_reticle_cell(name) if name in RETICLE else
                build_proc_cell(name) if name in PROC else build_cell(name))
        cell = prefilter(shade_bevel(cell, name))
        cells.append(cell)
        atlas.alpha_composite(cell, ((i % COLS) * CELL, (i // COLS) * CELL))
    atlas.save(OUT_PNG)
    # Uncompressed still: DXT's 4x4 blocks are unkind to hard-edged icons, which is a
    # large part of why the pack's better UI atlases read cleaner than vanilla's DXT ones.
    # Mipmapped now, unlike them - see the MIPMAPS note above for why they can afford not
    # to be and this one cannot.
    n = write_dds(atlas, OUT_DDS)
    print("wrote %s (%d mip level%s, prefilter %.1f)"
          % (OUT_DDS, n, "" if n == 1 else "s", PREFILTER))
    if "--preview" in sys.argv:
        write_preview(cells)

    bad = verify_declarations()
    for b in bad:
        print("  ! " + b)
    if bad:
        print("%d declaration mismatch(es) -- the game will draw the wrong cells" % len(bad))
        return 1
    print("%d cells, all declared at the right origins" % len(SRCS))


if __name__ == "__main__":
    sys.exit(main())
