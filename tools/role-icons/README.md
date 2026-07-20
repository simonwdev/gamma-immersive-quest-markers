# Role glyph atlas

Source art and build script for `gamedata/textures/ui/iqm_roles.dds`, the role
glyphs shown on the ambient service and important cards (trader, technician,
barkeep, medic, guide, important character).

## Source

`svg/<role>.svg` is one glyph per role from the [Tabler Icons](https://tabler.io/icons)
set (MIT licensed), a mix of outline and filled shapes. The white stroke/fill is
applied at build time; the SVGs themselves use `currentColor`. Filenames map
directly to the `iqm_role_<role>` texture ids.

## Build

```
python build.py
```

Needs Pillow and ImageMagick (`magick` on PATH). It renders each SVG white on
transparent, scales it to a consistent visual size, applies the worn look, packs
the six glyphs into a 4x2 grid of 128px cells, and writes the uncompressed DDS.
`iqm_roles.png` is the intermediate and doubles as a preview.

The glyphs are white so that `SetTextureColor` in `iqm_markers.script` can tint
them the accent colour and fade them with the card.

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
`iqm_markers.script`.

## Tuning the distress

The knobs are at the top of `build.py`: `DAMAGE_LVL` (higher means cleaner edges),
`EDGE_EAT` (how far in from the edge can be eaten), `SPECKLE` (higher means fewer
interior holes), and `CRACKS` (how many). `SEED` is fixed so the atlas comes out
the same every time.
