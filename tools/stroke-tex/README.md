# Route stroke texture

Builds `gamedata/textures/ui/iqm_stroke.dds` — the cross-section the route's
segment quads sample (`route_line` / `route_line_sh` in `configs/ui/iqm_cards.xml`).

Not a picture: horizontally uniform, vertically an alpha ramp — opaque core,
smoothstep feather to zero at the top and bottom edges. Because a segment's rect
height *is* the stroke's thickness, that ramp lands on the two long edges and
feathers them, and the same texture at a larger rect gives the dark backing copy
a soft halo instead of a hard keyline.

```
pip install pillow          # plus ImageMagick (`magick`) on PATH
python build.py
```

`FEATHER` (0.11) is the only knob: the fraction of the thickness each edge's ramp
occupies. Proportional rather than fixed-px on purpose — see the docstring in
`build.py`, and R2.14 in `docs/ar-navigation.md`.
