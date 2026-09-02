# map-icons — PDA map / minimap spot icons

Builds `gamedata/textures/ui/iqm_map_icons.dds` from `svg/`.

```
python build.py              # build the atlas
python build.py --preview    # also write _preview.png — every glyph at the sizes
                             # it is really drawn at (26 / 35 / 70 px), tinted
```

Needs Pillow and ImageMagick (`magick`) on PATH.

These are **not** the card glyphs — those are `tools/role-icons`. These replace the
icons the *engine* draws on the fullscreen PDA map and the HUD minimap. Three pieces
have to agree:

| Piece | File |
|---|---|
| the art | `gamedata/textures/ui/iqm_map_icons.dds` (this tool) |
| id → atlas cell | `gamedata/configs/ui/textures_descr/iqm_textures.xml` |
| spot → id + tint | `gamedata/scripts/modxml_n_iqm_map_icons.script` |
| the PDA's **Symbols** panel | same script, `LEGEND` — see below |
| proof that any of it fired | `tools/legend-harness/harness.lua` |

## The squad marker

Every NPC squad on either view — all fourteen `warfare_<faction>_spot` types plus the
`alife_presentation_squad_*` set, **fifty spot elements** — resolves to just two vanilla
textures in `ui\ui_common`: `ui_pda2_squad_leader` on the map and
`ui_minimap_squad_leader` on the minimap (plus `ui_mmap_squad_leader` for the two mutant
minis). Faction, relation and moving/static are carried entirely by `r`/`g`/`b` on the
element, so this is **one picture, not fifty**, and a white disk takes every colour.

These entries set **no tint**, the only block in the script that doesn't. The fifty
existing colours *are* the information the marker carries; overriding them would flatten
it. That needs a guard at the apply site — a table built from three nil fields is `{}`,
and `dxml_core:setElementAttr` treats an empty args table as a caller error, prints a
parser error and returns (`dxml_core.script:526-530`).

**Two cells for one mark**, which nothing else here needs. These are drawn at 11–13 and
9 units against 19 and 14 everywhere else, and at 9 units (~12.7 px at 1080p) a keyline
sized as a fraction of a shared cell comes out 1.44× thinner on the minimap and stops
reading as an outline. `iqm_mapspot_squadmini` is the same disk with a proportionally
heavier border, so the black ring lands at the same *final pixel* width in both views.
Both ink the same fraction of their cell (`SQUAD_EXTENT`), so on-screen size still comes
only from the spot. The cost is the mini cell carrying more black by area than the map
cell, in a fixed 1.47 ratio set by the two outlines; taken deliberately, since a 12.7 px
dot needs a guaranteed edge more than it needs the last of its chroma.

### The extent is set by ink mass, not by the cell

`SQUAD_EXTENT` was 60 of the 64 available — the disk filled its cell wall to wall, the
only limit being the margin a keyline needs so it cannot bleed across an atlas seam. That
is the wrong quantity to maximise, and it showed up as the squad dots reading **much too
big on both views**.

The *footprint* was never wrong. The spots stay at their declared 11/13/9 units and this
tool cannot change them — no squad entry in `SPOTS` sets `el`. What was wrong is that a
**solid** disk replaced two glyphs that were mostly holes, in a box of identical size.
Mean alpha over the cell, measured against the copy GAMMA loads (*UI Rework G.A.M.M.A.
Style*'s `ui\ui_common`, which wins that file at priority 838):

| Cell | Mean alpha | What it is |
|---|---|---|
| `ui_pda2_squad_leader` | 0.605 | a near-solid reticle |
| `ui_minimap_squad_leader` | 0.245 | a four-point star, ~75% air |
| this disk at extent 60 | 0.686 / 0.688 | wall-to-wall |

So the map view gained 13% ink and the minimap **2.8×**, both in an unchanged rect. A
mark's apparent size is its ink, not its rect.

**47** puts both cells at 0.42 — the mean of the two vanilla figures. That is the honest
split when one disk replaces two marks of different weight: lighter than vanilla on the
map, heavier on the minimap. A per-view target would have matched both exactly and cost
the single-extent invariant above, which is the more valuable of the two. Inked diameter
goes 18.0 → 14.3 px on the map and 12.5 → 9.9 px on the minimap at 1080p.

The keyline does **not** thin with it — its width is `SQUAD_*_OUTLINE` art px of a cell
still drawn at the same units, ~0.58 final px either way. What moves is black as a share
of the *mark*: 9.8% / 16.4% at extent 60, 12.3% / 20.6% at 47, i.e. the mini cell goes
from well under the badges' measured 23% to just under it. That is the number to watch if
this is pushed further — below about 40 the ring dominates a 9-unit dot rather than
edging it.

Which squads a player *sees* is not decided here — Milspec PDA gates that per PDA tier
(`item_milpda.actor_pda_can_see_mapspot`, from its `sim_squad_scripted.show`
monkeypatch): PDA 2.0 friendlies only, 3.0 adds neutrals, the Milspec adds enemies.

## Spliced spot files are found, not listed

`inventory.py` and `extract.py` both read the spot DOM through `full_spot_xml()`, which
is the `#include` chain from `map_spots_16.xml` **plus** every file a `modxml_*` script
hands the parser at load (`xml_obj:insertFromXMLString`). Nothing includes those, so a
plain include walk sees a complete-looking inventory that is missing them entirely —
which is what happened: Milspec PDA's 14 squadmate spots and 5 Kiltrak body styles, and
all ~85 of PAW's icons, were absent from both documents.

They are discovered by scanning the *winning* `modxml_*.script` files in the manifest for
one that mentions `map_spots` and inserts, then inlining the `#include`s it inserts. The
guard line (`xml_file_name == [[ui\map_spots_16.xml]]`) names the file being patched, not
a new one, and is not on an `#include` line, so it is never picked up. Splices are
inlined in `modxml_` filename order — dxml_core's own firing order, last write winning —
so where two splices define the same element this reproduces the engine's choice.

The old hand-maintained `SPLICED` table is down to the genuinely file-less case (an
element assembled in Lua). It had already gone stale: it carried PAW's waypoint as one
entry when PAW splices five files.

`docs/map-spot-inventory.md`'s *Files this was built from* table marks which route each
file took, and it is the fastest way to spot a load-order surprise — `map_spots_milpda.xml`
is spliced by Milspec PDA's script but the winning **copy** is PAW's.

## The legend

The PDA map has a Symbols panel, and re-skinning the spots leaves it describing art that
is no longer on the map. It is patched by the same script, and the two halves differ in
one interesting way: a spot is found **by its element name**, a legend row by **the
texture it already carries**.

That is not a style choice. A legend row is a plain `<item>` in `pda_tasks*.xml` with a
picture and a caption, and nothing in the engine connects it to the spot it explains — so
position is meaningless (AlphaLion's legend has 20 rows, vanilla's 15, in different
orders) and captions are worse, since half of AlphaLion's rows carry literal English text
rather than a string id. The texture id is the one field that says which mark the row is
for, and keying on it makes the patch **self-limiting**, which is the whole answer to
"can this be done without conflicts":

* a legend we do not recognise is a legend we do not touch;
* a row whose spot we do not re-skin is left alone even in a legend we do recognise —
  stashes, "Area", fast travel, the guide, the player arrow and the relation dots all
  keep their own art, because we do not own those spots either.

Two engine facts the patch turns on, both easy to get wrong silently:

> **A named colour beats `r`/`g`/`b` outright.** `CUIXmlInit::GetColor`
> (`UIXmlInit.cpp:1307-1323`) returns the named entry and never looks at the numbers.
> Vanilla's legend rows are `<texture color="pda_blue">`, so the attribute has to be
> *removed*, not overridden — left in place it would paint every one of our glyphs the
> same blue, which is the map's colour coding thrown away and worse than not patching.
> (`removeElementAttr` is DXML's, `dxml_core.script:543`.)

> **The rows are 15×19 with `stretch="1"`.** A square cell in that box is squashed 21%.
> The patched rows are set to 19×19 on the same centre — undistorted, and the exact size
> the fullscreen map draws these at, so the swatch is the mark at its real size.

`tools/legend-harness/harness.lua` runs Anomaly's own `slaxml` and `dxml_core` over the
real `pda_tasks_16.xml` — AlphaLion's copy *and* vanilla's — and asserts all of the
above. It exists because a DXML patch has no failure mode that says anything: a wrong
query, a mis-typed file name or a callback that runs too early all produce a game that
starts and the old art still on screen. On a machine with no GAMMA install it skips.

## What this reproduces

Anomaly's service spots are a **badge**, not a bare pictogram: a thin ring, four
crosshair ticks straddling it, and a flat glyph at half the footprint. Measured off
the vanilla 19×19 medic cell in `ui\ui_actor_hint_wnd` (x=66 y=543), the copy GAMMA
loads via *UI Rework G.A.M.M.A. Style*:

| Element | Source px (of 19) | Constant |
|---|---|---|
| Ring radius | 7.0 | `RING_R` |
| Ring stroke | ~1.35 | `RING_W` |
| Ticks | 3.2 long × 1.35 wide, straddling the ring | `TICK_LEN` / `TICK_W` |
| Inner glyph | 9 px, i.e. 0.71 of the ring's inner diameter | `GLYPH_FIT` |
| Colour | `(132, 199, 231)`, baked, untinted | — |

**The ticks are off** (`TICKS = False`) — a plain ring is cleaner, and the ring alone
still nests inside the game's ring-textured selection borders, which was the reason to
keep a circular footprint at all. Dropping them frees the margin they occupied, so
`RING_R` grows to `0.40` to land the ring's outer edge near where the tick tips used
to reach (0.40 rather than 0.41 so the keyline clears the cell edge and can't bleed
across the atlas seam); otherwise every marker would visibly shrink. The inner glyph grows with it,
since `GLYPH_FIT` is measured against the ring — legibility at minimap size improves
as a side effect. `TICKS = True` restores vanilla's geometry exactly.

The circular footprint is load-bearing. Task spots wrap their 19×19 icon in a
`static_border` — `storyline_task_spot` declares a 29×29 border at offset (-4,-5)
textured `ui_pda2_stask_last_02`, a ring. A round icon nests inside a round border; a
square one doesn't. So the vanilla *design* was never the problem — a 19-pixel source
being stretched across a 27–53 px draw was.

Set every tint in the script to `132,199,231` to get vanilla's exact look back. Per-
role colour is the one place this deliberately improves on the original: vanilla makes
every service spot the same cyan.

`BADGE = False` emits bare glyphs at `BARE_FIT` instead, for any spot type vanilla
itself draws without a ring.

## The task marker is two textures

A task spot draws an icon *and* a `static_border`, and `CMapSpot` shows that border
only while the task is the **selected** one (`show_static_border`, driven from
`CMapLocation`). Selecting a different task just moves the brackets — so the brackets
carry the whole "this one" signal and deserve to be the crisper of the two.

Both are **drawn as geometry**, not traced from SVG (`PROC` in `build.py`), because
they're rings, arcs and rectangles:

| Mark | Shape | Measured from |
|---|---|---|
| `task` | broken outer ring (four arcs, gaps on the cardinals), inner ring, centre crosshair | AlphaLion's 23×23 mission reticle |
| `select` | four arcs of a ring, on the **cardinals** (gaps on the diagonals — the inverse of `task` and `blink`) | vanilla's 21×21 `ui_pda2_stask_last_02` |
| `transition` | an arch — vertical sides, a 45° roof, a 3-wide flat apex — filled black, with a solid arrow through it, both corner-rounded | vanilla's 19×21 `ui_pda2_exit_point`, as AlphaLion recolours it |

`TRANS_ROUND` / `ARROW_ROUND` are the corner radii, and they are an addition rather than
a measurement. Vanilla's corners are as round as 19 source pixels allow, i.e. the
rounding *is* the antialiasing — so a faithful trace comes out hard-cornered and reads
more angular than the icon it copies. `round_poly` puts it back at a radius the cell can
resolve. It is quoted as a radius, not as a cut length, because the arch has 90° corners
at the bottom and 135° at the roof and equal cuts on those look like two different
amounts of rounding. 2.2 art units matches what is on screen today; 3.4 was tried and
softens the roof until the arch stops reading as an arch.

One pair serves storyline and secondary both — the only difference is the tint (gold
vs pale, matching the game's own split). `TASK_OUT_R` is pulled in from vanilla's
0.491 to 0.455 so the ring lands within a hair of the service badges' ring: a task
marker and a service badge then read as the same size on the map.

### The selection border needs x = −5, not vanilla's −4

The border is 29 units against the spot's 19, so symmetric is −(29−19)/2 = **−5 on both
axes**. Vanilla gets `y` right and `x` wrong by one unit.

The trap is that `-4` looks deliberate. The spot is `waCenter` (position = centre) while
the border is `waNone` (position = top-left, `uiabstract.h:87-96`) and `CMapSpot` scales
only the border's *width* by `kx` (`map_spot.cpp:60-63`) — exactly the shape of an aspect
compensation, `-5 × 0.75 ≈ -4`. It isn't one. In game the brackets sat **2.5 px right**
of the icon centre at `x=-4` and **2.5 px left** at `x=-6.2`; those two points put zero
at −5.1. Both textures were verified pixel-symmetric in their cells first, so none of the
offset was ours. `gamma-active-task-ui-enhancements` independently declares its own
return-task border at `x="-5" y="-5"`, and it sits centred.

One constant suffices at every zoom because these spots declare no `scale="1"` — see
below.

### The level transition is the one cell that needs `stretch="1"`

`ui_pda2_exit_point` is drawn by nine elements — eight `level_changer_*_spot`s that
differ only in `heading_angle`, plus `level_changer_spot_mini` — and that heading is
what makes them a special case.

`CMapSpot::Load` (`map_spot.cpp:35-39`) turns stretch on for every spot, but inside
`if (!Heading())`, alongside the `kx` width correction. These eight have a heading, so
they fall out of that branch and stretch stays **off** — and with it off,
`CUIStatic::DrawTexture` (`UIStatic.cpp:117-150`) sizes the quad from the **texture
rect** rather than from the spot. A 128 px cell would draw at 128 UI units, roughly
seven times too big.

That is also why vanilla's art is exactly 19×21 for a 19×21 spot and why every other
high-res spot atlas leaves these eight alone: the "spot size comes from the XML, not
the texture" rule that the rest of this file rests on is **false here**. The script
sets `stretch = 1` on the spot to put it back, which survives because `CMapSpot::Load`
only ever sets the flag true and never clears it.

Two knock-ons:

- **The spot must be square.** The engine rotates the *quad* (`S2DVert::rotate_pt`,
  `ui_base.cpp:11-19`), so a 19×21 rect at heading 45° is a rotated oblong and the arch
  inside it comes out sheared. The script sets 19×19; that is about shape, not size.
- **`kx` is not escaped**, only relocated — `rotate_pt` applies it after the rotation.
  So these behave like every other spot: exact on the fullscreen map, 0.75 wide in the
  handheld 3D PDA. The arch is all straight edges, so it passes the no-circles rule.

The arch's interior is **filled black at alpha 210**, the one place a frame here is not
left open. The measured argument against black area (see `OUTLINE`) is about keylines
merging across an ~11 px gap; the arch clears the arrow by ~13 px on every side, and
the fill is what stops a green arrow competing with a green arch at 27 px. Vanilla and
AlphaLion both do it. `TRANS_FILL = 0` opens it.

No icon library has this glyph, which is why it is drawn: a gateway seen head-on is a
mark nothing outside this game needs. Tabler's `door-exit` and Material's `exit_to_app`
are a door in perspective with the arrow beside it — a different mark.

### Glyph grammar

| Glyph | Means | Spots |
|---|---|---|
| Ring + pictogram | a service, by kind | `ui_pda2_*_location` |
| Reticle | go find it | `storyline`/`secondary_task_spot` |
| Ring + diamond, **companion green** | done — go collect on it | `*_task_on_guider_spot`, `atue_return_task_spot` |
| Ring + exclamation, hazard orange | …and the clock is running | `secondary_task_complex_spot_mini_timer` |
| Ring + question mark, red | an unknown hostile | `red_spot`, `red_mini_spot` |
| Ring of four arcs | this is the selected one | any `static_border` |
| Arch + arrow, **bare and rotated** | the way out of this map | the eight `level_changer_*_spot`s + mini |

The ring means "a marker of ours". Every patched spot now carries one — the `home` cell
is built and declared but **not currently applied**: `fast_travel_spot` was reverted to
vanilla's `ui_hud_icon_sleep`, which is a house at alpha 128, i.e. a half-transparent
ghost that takes its colour from the PDA screen behind it. An opaque tinted glyph cannot
reproduce that, which is the argument for leaving it. `NO_BADGE = {"home"}` and the
no-circles-bare rule stay as they are, since that is what the cell is drawn to.

**Before adding a spot, read its attributes, not its name.** `primary_object_spot` was
patched here once on the strength of its name and had to be reverted: it is ZCP's landmark
*discovery* ring, not a quest object, and `location_level="-3"` with `scale="1"
scale_max="6"` says so — drawn behind everything and growing to 6× with zoom. A 205 px
soft circle is correct for that; a reticle turned scenery into objectives. It is the only
spot in this file's orbit that rescales with the map, which is why the "these don't scale
with zoom" note elsewhere holds for everything actually patched.

The turn-in diamond and the companion bust share **exactly** the same green (`40,172,66`),
by request and against the ΔE≥25 rule the rest of the palette follows. It's affordable
because a bust and a diamond share no silhouette, and the two markers rarely compete —
a companion is beside you and moving, a turn-in is on an NPC you're walking towards. The
script records the lime that was there before (`146,222,0`) if the pair ever reads as one.

The ATUE entries are guarded like everything else — without that mod the block is a
silent no-op.

### The script's filename is load-bearing

`dxml_core` sorts the `modxml_*` filenames and fires the callbacks in that order, last
write winning. The `n_` puts this file in a window, not merely late:

| Must run | Against | Why |
|---|---|---|
| after | `modxml_AL_MapSpots`, `modxml_map_spots_milpda` | they re-point the same elements at their own low-res cells |
| after | `modxml_map_spots_paw` | PAW's spot doesn't exist until its callback splices the file in |
| before | `modxml_z_dart_*` | DART reads our `x`/`width` and rewrites them per aspect ratio |

Renaming it breaks one of those **silently**, and only for players who have that mod or
that resolution. PAW was exactly this: at `modxml_iqm_…` we ran ahead of `map_…`, so
`paw_task_default_spot` wasn't in the DOM yet, the query found nothing, and the
player-placed waypoint kept the old fuzzy pulse.

**`trader` is Tabler's filled `briefcase-2` as of R2.46.** The game-icons.net briefcase it
replaced lost its latch, handle wrap and case seams to the inner glyph's budget — half the
cell, so half a bare icon's detail, exactly what the *Inner glyphs must be flat and simple*
rule below is about. It is also the licence this file's own source guidance already
recommended against. Old art kept as `svg/trader-gameicons.alt` in both folders; rerun both
build scripts on any change, per the shared-source rule below.

**Resolved (R2.29).** The waypoint marker used to show a tabler *flag* for `REPORT BACK`
while the map showed the turn-in glyph. `role-icons/svg/handin.svg` is now this file's
`svg/handin.svg`, and `trader` / `medic` / `mechanic` / `barman` are shared the same way, so
the world marker and the map spot are the same mark for all six. **These SVGs now have two
consumers** — edit one and rerun *both* build scripts, or the two views drift apart again.

**And they did drift (R2.55 → R2.56), which is the one worked example of this rule failing.**
`svg/handin.svg` here became the price tag and `role-icons/svg/handin.svg` stayed the diamond,
so for a release the map drew a tag and the beacon drew a diamond for the same objective. Two
things hid it. Nothing *drew* `iqm_role_handin` in between — the `target` role's marker was
retired in R2.46 and the `handin` task kind that draws it now only arrived in R2.55 — so the
mirror was broken with no eye on either side. And a stale copy fails *silently*: both atlases
build, both cells are valid art, and only seeing the two views together says which is wrong.
The old art is kept as `role-icons/svg/handin-diamond.alt` next to this folder's
`svg/handin-diamond.alt`, and rerunning both builds is the whole fix.

**There is now a check, because "rerun both builds" is an instruction and instructions are
what got skipped.** `tools/color-harness` asserts that all seven shared SVGs have identical
`<path>` data on both sides (comments stripped — the two copies carry different headers on
purpose). It is in the colour harness rather than a new one because it is the same promise
that file already guards: the map and the marker are one mark, and a copy edited on one side
only fails silently in both directions. Note the legend sheet does **not** cover this —
`extract.py` reads map-spot ids, so no `iqm_role_*` cell appears in `docs/icons` at all, which
is part of why the diamond sat there unseen.
The role atlas renders them bare and undistressed (`NO_DISTRESS`); the ring and keyline are
this file's, because only a map spot has to stand alone.

## Why high-res sources help

A spot's on-screen size comes from its `width`/`height` in `map_spots*.xml` (UI units,
`stretch="1"`), not from the texture rect. Those are UI units, so they scale with the
player's **resolution**: a 19-unit spot is ~27 px at 1080p, ~36 px at 1440p, ~53 px at
4K — against the 15–23 px cells vanilla and the other spot addons supply. A 128 px cell
drawn into the same rect is minified at every resolution instead of magnified at most.

These spots do **not** grow with map zoom. Zoom rescaling requires `scale="1"` on the
spot (`m_bScale`, `map_spot.cpp:41-48`) and none of the ones patched here declare it;
`ScaleOrigin` at line 274 only reaches `CComplexMapSpot`'s `CUIStaticOrig` children.
(An earlier version of these notes claimed zoom was the driver — it isn't.) The useful
consequence: a `static_border` misalignment is a fixed pixel count, not a
zoom-dependent one, so a single constant can correct it at every zoom.

The other half of the gap is format: Milspec PDA's 1024×1024 spot atlas and
AlphaLion's are both **32-bit uncompressed**, and so is this one
(`dds:compression=none`, `dds:mipmaps=0`). DXT's 4×4 colour blocks are unkind to
hard-edged icons.

## Conventions

- **White ink, black keyline, transparent ground.** Colour comes from `r`/`g`/`b` on
  the spot's `<texture>` element — the engine *multiplies*, so white ink takes the
  tint and the keyline survives it (black × anything is black). Recolouring needs no
  rebuild.
- **The frame's keyline goes outward only.** The ring's inner edge and the glyph are
  only ~11 final px apart, so two keylines growing toward each other close the gap and
  the badge reads as a blob at minimap size. Keeping the interior clear also matches
  vanilla, which lets terrain through the ring.
- **Inner glyphs must be flat and simple.** The glyph gets half the cell, so its
  detail budget is half a bare icon's. Vanilla's own are brutal — its bed is two posts
  and a mattress bar, drawn flat side-on. Perspective drawings lose their legs and
  read as a smudge. Filled/solid beats outline; roughly square beats wide.
- **Declare the whole cell** in `iqm_textures.xml`, never a glyph's own bbox — with
  `stretch="1"` a tight bbox on a non-square glyph gets stretched by the square spot
  rect, and equal cells are what keep every badge the same size on screen.
- **No distress pass** (unlike `role-icons`). At 26–35 px the chips are the same size
  as the stroke and read as speckle.
- **Grid growth: append cells, then append rows. Never widen `COLS`** — that
  renumbers every cell's pixel origin and invalidates the ids in `iqm_textures.xml`.
  Now 4×5, **19 of 20 used** — one cell free at x=384 y=512 before the next row.
  A colour variant costs no cell at all: the tint is an `r`/`g`/`b` attribute on the
  spot, so the bounty reticle reuses `iqm_mapspot_task`. Reach for that first.
- **The map is drawn twice and the two views disagree about aspect.** `CMapSpot::Load`
  scales every spot's width by `kx` (0.75 at 16:9). On the **fullscreen 2D map**
  `ClientToScreenScaled` is anisotropic (`x·W/1024`, `y·H/768`), which cancels it
  exactly at any resolution — a square cell renders square. In the **handheld 3D PDA**
  (`pttLIT`, `g_3d_pda on`) that function does `dest.set(left, top)` — no scaling at
  all — so nothing cancels `kx` and **every spot renders 0.75 as wide as it is tall**.
  Measured both ways on the same art: medic badge 25×26 px fullscreen, pin 12×20 (0.75×
  its authored aspect) handheld.

  No texture is right in both, and there's nothing to hook — both views draw the same
  `CMapSpot`. `heading="1"` doesn't escape it either; that path just moves the same `kx`
  from load time into `rotate_pt` at render time.

  You *can* correct it on the spot — `width = height / 0.75` makes the handheld view
  exact (`width="40" height="30"`) — but only by making the fullscreen map a third too
  wide. Tried and reverted.

  **The fix is the glyph, not the geometry. No circles in a bare glyph.** The eye knows
  what a circle should be and has no expected value for a rectangle or a triangle, so a
  squashed house is just a narrower house while a squashed map pin is a defect. This is
  *not* about proportions — vanilla's house cell is 43×49 (0.878) and the Tabler pin
  84×96 (0.875), the same box. It's why vanilla drew this spot as a house *and* drew it
  frameless, and why the twelve ringed cells never showed the bug: a squashed ring is an
  ellipse, and an ellipse is a legitimate shape.

  So: **straight-edged glyphs can go bare; anything with a circle in it goes inside the
  ring**, where the surrounding ellipse gives the eye its context and the glyph is small
  enough for the distortion not to register. `svg/home-pin.alt` is the map-pin version,
  kept as the worked example of a glyph that cannot go bare.

  Corollary for debugging: **when judging a distorted glyph, say which view the
  screenshot came from.** Measuring one view and generalising cost several rounds here.

## Adding an icon

1. Drop `svg/<name>.svg` in (any fill — it gets colorized white).
2. Append `("<name>", (r,g,b))` to `SRCS` in `build.py`, rerun with `--preview`, and
   judge it at 26 px. Not at 128.
3. Add a `<texture id="iqm_mapspot_<name>" .../>` line to `iqm_textures.xml` at the
   new cell's pixel origin.
4. Add a `SPOTS` entry in `modxml_n_iqm_map_icons.script`, matching the tint you
   previewed. Find the spot element names by grepping the winning `map_spots_16.xml`
   for the role.

Good sources for inner glyphs, in rough order of fit: **Tabler** (MIT, already
bundled for the card glyphs), **Material Symbols** filled (Apache 2.0), **Phosphor**
fill (MIT), **Remix Icon** fill (Apache 2.0). Search across sets at
[icones.js.org](https://icones.js.org). Avoid game-icons.net here — it's drawn for
64–128 px ability buttons, has no shared design grid, and is mostly CC BY 3.0
(per-icon attribution).
