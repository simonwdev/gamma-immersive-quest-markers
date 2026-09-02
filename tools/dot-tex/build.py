#!/usr/bin/env python3
"""Build the minimap trail's dot (gamedata/textures/ui/iqm_dot.dds).

A white disc with its dark keyline BAKED IN, which is the whole reason this
texture exists rather than reusing iqm_circle.

Every other small mark this mod draws is a PAIR of widgets: the glyph, and a
black copy of it a couple of pixels larger sitting behind, which stands in for
an outline. That works for the AR route's chevrons, which are large and drawn
over scenery, and it does not work for an 8 px dot on the minimap:

  * The backing is a FIXED 2 px larger, so at 8 px it is 25% oversized -- a
    heavy ring around a small dot rather than a keyline on it. Scaling with the
    mark instead would fix the weight but not the second problem.
  * Two widgets are positioned independently, so their centres round to screen
    pixels independently. At this size a half-pixel disagreement is a visibly
    off-centre ring -- the mark and its border stop looking like one object.

One texture has neither failure: the keyline is part of the art, so it is
concentric by construction and its weight is a fixed FRACTION of the dot at
every size the menu offers.

RGB is NOT uniform here, unlike iqm_stroke / iqm_arm / iqm_mark, whose contract
is "white ink, alpha carries the shape, colour comes from SetTextureColor". The
keyline has to be dark, so it is black in the RGB. It survives tinting because
SetTextureColor MULTIPLIES -- black times anything is still black -- which is
the same trick the map-spot icons use (tools/map-icons/build.py).

Requires: Pillow, and ImageMagick (`magick`) on PATH for PNG->DDS.
Run from this directory:  python build.py
"""
import os
import subprocess

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
TEX = os.path.normpath(os.path.join(HERE, "..", "..", "gamedata", "textures", "ui"))

# 64x64, like the other single-glyph textures. The dot is drawn at 4-16 px in the
# virtual UI, so this is minified at every size and at every resolution -- which is
# the same reason the map icons are 128px cells.
SIZE = 64

# Supersample factor. The disc is drawn at SIZE*SS and box-filtered down, which is
# what puts a clean antialiased edge on both the rim and the white/black boundary.
SS = 8

# Radii as a fraction of the half-size. R_OUT leaves a little air inside the cell so
# the rim's feather has somewhere to land and is never clipped by the cell edge.
#
# R_IN sets the keyline's weight: the ring is (R_OUT - R_IN) of the radius, so at an
# 8 px dot it is about 0.7 px and at 16 px about 1.4 px. That is the point of baking
# it -- the border keeps its PROPORTION instead of its pixel count, so it reads the
# same at every size the menu offers.
R_OUT = 0.94
R_IN = 0.76


def build(name="iqm_dot"):
    n = SIZE * SS
    half = n * 0.5
    # Black everywhere, transparent everywhere, and then the shape is drawn into it.
    # The RGB OUTSIDE the disc matters: downsampling blends it into the rim, so
    # leaving it black keeps the edge dark rather than fringing it grey.
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    def disc(frac, fill):
        r = half * frac
        # Centred on the cell's true centre, not on a pixel: an offset of even half a
        # supersampled pixel shows up as a ring that is thicker on one side.
        d.ellipse([half - r, half - r, half + r, half + r], fill=fill)

    disc(R_OUT, (0, 0, 0, 255))          # the keyline, as a filled black disc...
    disc(R_IN, (255, 255, 255, 255))     # ...with the white core laid over it

    # BOX, not LANCZOS: a box filter over SS x SS samples IS the supersample average.
    # LANCZOS overshoots at a hard black/white boundary, and the one boundary here is
    # exactly that -- the overshoot would put a bright fringe just inside the keyline.
    img = img.resize((SIZE, SIZE), Image.BOX)

    png = os.path.join(HERE, name + ".png")
    img.save(png)
    dds = os.path.join(TEX, name + ".dds")
    # Uncompressed, no mipmaps: same call as the other builders. DXT on a 64px disc
    # puts block artefacts exactly on the keyline, which is the one edge that matters.
    subprocess.run(["magick", png, "-define", "dds:compression=none",
                    "-define", "dds:mipmaps=0", dds], check=True)
    print("wrote", dds)


if __name__ == "__main__":
    build()
