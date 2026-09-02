# Role glyph atlas

Source art and build script for `gamedata/textures/ui/iqm_roles.dds`, the role
glyphs shown on the ambient service and important cards (trader, technician,
barkeep, medic, guide, important character).

## Source

`svg/<role>.svg` is one glyph per role from the [Tabler Icons](https://tabler.io/icons)
set (MIT licensed), a mix of outline and filled shapes. The white stroke/fill is
applied at build time; the SVGs themselves use `currentColor`. Filenames map
directly to the `iqm_role_<role>` texture ids.

**Six of them are shared with `../map-icons/svg` (R2.29)** — `handin`, `trader`, `medic`,
`mechanic`, `barman` — so a waypoint marker in the world carries the same mark that role's
PDA map spot carries. Those are copies, not symlinks: **edit one and rerun both build
scripts**, or the two views drift apart. The tabler originals are kept beside them as
`svg/<name>-tabler.alt`. They also skip the distress pass, for the reason in `build.py`:
an eroded copy of the map's mark is not the map's mark. `guide` is not shared — vanilla
does not map-spot guides, so there is nothing to match.

**`trader` went back to Tabler at R2.46** — the filled `briefcase-2` — because the
game-icons.net briefcase it had carried too much fine detail to survive the sizes these are
actually drawn at: a bare marker glyph is ~20 px and a badge's inner glyph gets half its
cell, so the latch, handle wrap and case seams all collapsed into noise. The replacement is
one solid silhouette and reads down to 14 px. It also settles the licence, which
`../map-icons/README.md` had already flagged: game-icons.net is mostly CC BY 3.0 with
per-icon attribution, Tabler is MIT and already bundled. Old art kept as
`svg/trader-gameicons.alt` in both folders.

**`waypoint` follows the same rule from the other direction (R2.33).** The player-placed
waypoint's map spot (PAW's `paw_task_default_spot`, re-skinned by
`modxml_n_iqm_map_icons`) is not a pictogram but the four-arc pulse **ring**
`iqm_mapspot_blink`, which `../map-icons/build.py` draws procedurally rather than from an
SVG. So this one is generated to match it: `svg/waypoint.svg` is four arcs computed from
that file's own `BLINK_R` / `BLINK_W` / `BLINK_GAP_DEG`. Change any of those three and
regenerate this SVG, or the ring in the world stops being the ring on the map.

**`task` is the same idea for the selected task (R2.46)** — `iqm_mapspot_task`, the reticle
that replaces `ui_inGame2_PDA_icon_Secondary_mission`. `svg/task.svg` takes its outer arcs
from that cell's `TASK_OUT_R` / `TASK_OUT_W` / `TASK_GAP_DEG`, and the same
regenerate-both rule applies.

It **deliberately drops the map cell's inner ring and grows its crosshair**, which is the one
place a shared mark is not pixel-identical across the two views. A marker draws at
`beacon_size` — 14 UI units, ~20 px at 1080p — against a map spot's 19, and at 20 px the
outer arcs, the inner ring and their baked keylines merge into a blob: the gap between arcs
and ring is 4.9 units of 100 and the keyline grows 7.1 into it from either side. The map cell
blurs the same way there, so this reproduces what the map *renders* at marker size rather
than what it contains. Judge any change to it at 20 px, never at 128.

Read together, `waypoint` and `task` are a pair: both broken rings, told apart the same way
in both views — both gap the **cardinals**, the task's narrowly (11° either side, long arcs)
and the waypoint's widely (20°, short arcs), with a crosshair on the task and nothing on the
waypoint. The README said the waypoint gapped the *diagonals* until R2.63a; it never did —
that is the map's `select` frame, a third ring. The gap width is load-bearing: it is why a
glyph's corners clear the waypoint ring and not the task ring (see `RING_GEOM`).

> **An XML comment must come after the opening `<svg …>` tag closes.** Inside the tag's
> attribute list ImageMagick's librsvg delegate reports `unable to read image data …
> RenderRSVGImage`, which reads as a corrupt file rather than as the malformed XML it is.
> An earlier note here recorded that as "no XML comment in `waypoint.svg`" — too broad:
> `task.svg` carries a long one and renders fine. Probed both positions to be sure.

## Build

```
python build.py
```

Needs Pillow and ImageMagick (`magick` on PATH). It renders each SVG white on
transparent, scales it to a consistent visual size, applies the worn look, packs
the glyphs into a grid of 128px cells, and writes the uncompressed DDS.
`iqm_roles.png` is the intermediate and doubles as a preview.

The grid is 4×5 as of R2.55, and one cell of the fifth row is spare (R2.63 took the
third for `ringtask`). Same
growth rule as `map-icons`: append cells, then append rows, never widen `COLS`, since
that renumbers every existing cell's pixel origin and invalidates the ids in
`iqm_textures.xml`. And check first whether a new mark really needs a cell: a marker's
tint is a runtime lookup in `iqm_beacon`'s `BEACON_RGB`, so a recolour of an existing
glyph — which is all the bounty marker is — costs nothing here.

`ringtask` (R2.63) is the counter-example worth reading beside that, because it is a cell
that *was* earned. It is `task.svg` with the crosshair dropped — a recolour would not have
done, because what had to change was not the mark's colour but whether it is a mark at all:
it draws UNDER another glyph and frames it, saying whose the mark is rather than what it
is. The distinction it carries used to be carried by tint (the selected turn-in wore its
kind's green while an unselected one wore the accent), which broke the rule the tint exists
to serve. See `beacon_color` in `docs/decisions.md`.

The glyphs are white so that `SetTextureColor` in `iqm_core.script` can tint
them the accent colour and fade them with the card.

## The keyline

The glyphs in `KEYLINE` (the six the waypoint marker draws, plus the chevron) get a black
outline **baked into the art** by `keylined()`, a round-disk dilation of the alpha. They used
to be drawn with a separate black widget behind them at a slightly larger rect, which can
never line up: the engine floors every widget's top-left to a whole screen pixel
independently (`AlignPixel` is `iFloor`) and does not align the bottom-right at all, so the
outline shifted by a pixel as the marker moved and was uneven when it stood still. Baked, it
is part of the same quad — concentric by construction, the same fraction of the glyph at
every size. It survives `SetTextureColor` because the UI shader multiplies.

`KEY_R` is in atlas pixels; what matters is its ratio to the 128px cell, since the cell is
what gets drawn at the marker size. The same trick, for the same reason, is in
`../digit-tex/build.py`, `../stroke-tex/build.py` (`iqm_mark`) and `../dot-tex/build.py`.

## The worn look

The distress comes from hard alpha cutouts, not from fading the alpha down (a fade
just reads as uneven brightness). The stroke's interior is protected and only a rim
is exposed to a thresholded grunge mask, which bites crisp chips out of the edges.
Sparse interior pinholes and a few thin cracks finish it off.

## Changing an icon

1. Drop the replacement `svg/<role>.svg` in, keeping the role filename.
2. Run `python build.py`.

The cell order in `build.py` (`SRCS`) has to match the `iqm_role_*` texture ids in
`gamedata/configs/ui/textures_descr/iqm_textures.xml` and `ROLE_ICONS` in
`iqm_core.script`.

## Tuning the distress

The knobs are at the top of `build.py`: `DAMAGE_LVL` (higher means cleaner edges),
`EDGE_EAT` (how far in from the edge can be eaten), `SPECKLE` (higher means fewer
interior holes), and `CRACKS` (how many). `SEED` is fixed so the atlas comes out
the same every time.
