# route-preview — see the world-view route without launching the game

```
python preview.py --compare          # current look beside the sharpened proposal
python preview.py --style arrows --scene bend --pitch -30
python preview.py --feather 0.04 --hmin 0.75 --head 1.5 --alpha 255
python preview.py --dump             # every constant it is using, and where from
```

Writes a PNG next to the script. Needs Pillow; nothing else, and no ImageMagick — the
textures are generated in memory.

## What it is for

Judging the *look*: feather, halo weight, the near fade, opacity, colour, and how a
style reads at a given camera pitch. Not behaviour — `tools/nav-harness` and
`tools/route-harness` own that, and nothing here should be used to decide whether the
route is *right*, only whether it *reads*.

The reason it exists is the loop it replaces. Every look decision so far cost a launch,
a load, a walk to a quest giver and a squint, which is minutes per comparison for a
judgement about a few dozen pixels. At that price the comparisons that actually settle
a design — this feather against that one, on the same ground, at the same moment —
never got made; each session judged one setting against a memory of the last.

## What is faithful, and what is not

Faithful, because it is read from the source rather than retyped:

* Every `RTE` constant is parsed out of `iqm_core.script` at run time, and the vertex
  spacing rules (`SEG_DIV`/`SEG_MIN`/`SEG_MAX`/`TURN_TOL`/`NEAR_TRIM`) out of
  `iqm_nav.script`. `--dump` prints the lot.
* The textures come from importing `tools/stroke-tex/build.py` and calling its own alpha
  functions, so the artwork is the shipped artwork — and `--feather` re-runs them at a
  different value **without touching the shipped assets**, which is the point of the tool.
* The drawing is ported line for line from `IqmCards`: `seg_width` measures thickness
  from the segment's own projected ground edges, `place_strip` builds the rect in UI
  units and rotate-then-**uniform**-scales it (x by `UI_KX` then `w/1024`, which together
  are `h/768`), the halo is the same texture at a larger rect, and everything composites
  far to near in the same order — so the joint double-blend shows up here too.

Approximated, and worth knowing before reading anything off a render:

* **The projection.** The game calls `game.world2ui_with_depth`, which uses the player's
  real FOV; this is a pinhole camera at `--fov` (default 55° vertical). Absolute
  on-screen sizes therefore rest on an assumption. Relative judgements do not.
* **The floor** is procedural concrete with a deliberately pale stretch and a deliberately
  dark one, because the route has to stay legible on both and a flat grey backdrop
  flatters a washed-out stroke.
* **Filtering** is PIL's bilinear where the GPU has its own; well under the effects being
  judged at these scales.
* **No occlusion** — every point draws lit.

## Scenes and styles

`--scene straight | bend | curve` — `bend` puts a rounded 90° corner 14 m out, which is
where vertex placement and the stroke's cornering can be seen; `curve` is a long S.

`--style marks | band | arrows | glyph | classic` — the same five `route_style` designs
the MCM offers, drawn by the same two primitives (`place_arms` for two-quad chevrons,
`place_mark` for the one-texture glyph). `--no-stroke` suppresses the line in a style that
normally has one; that flag is how `marks` was tried before it existed in the mod.

`--pitch` matters more than it looks. At `-12°` you see the route as you walk it; at
`-35°` you are looking at your feet, which is the view that shows what the near end is
really doing.
