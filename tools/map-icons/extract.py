#!/usr/bin/env python3
"""Extract the actual art for every map spot, so you can LOOK at it before deciding.

Companion to inventory.py, which lists the spots but shows nothing. This crops each
spot's source cell out of the winning DDS and writes:

  docs/icons/<id>.png          every cell at native size, lossless
  docs/icons/sheet-<section>.png   labelled contact sheet per category
  docs/icons/index.html        the same, inline, for review in a browser

Two resolution problems have to be solved here that resolve.py cannot help with:

  * The manifest indexes TEXT FILES ONLY - it has no .dds rows at all - so the winning
    sheet cannot be looked up there. It is resolved instead by walking the mods tree
    for every copy of the file and picking the one whose mod sits latest in
    mod_priority.txt, which is the same rule MO2's VFS applies (later line = higher
    priority; verified against a known conflict, where Sota UI at line 840 beats
    Display Campfires at 215 for map_spots_16.xml exactly as the manifest reports).
  * A texture id names a CELL in a sheet, and which descr file declares it is itself a
    load-order fight. Same rule, applied to the descr files.

Cells are upscaled with NEAREST for the contact sheets so that what you are looking at
is the real pixel grid rather than an interpolation of it - the point of the exercise is
to judge how coarse the source actually is.

LIMIT worth knowing before you trust a gap in the output: base Anomaly's textures are
still inside the .db archives and the _unpacked tree carries configs, scripts and ai
only - there is no _unpacked\\textures at all. Every sheet found here therefore comes
from a mod, and a texture that NO mod ships cannot be seen by this script even though
the game loads it perfectly well. "Could not extract" means "no mod provides this",
which is not the same as missing. (In practice that is one id out of 86, since GAMMA's
UI mods replace nearly all of this art.)

Requires Pillow. Read-only outside docs/.
"""

import base64
import io
import os
import re
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict

from PIL import Image, ImageDraw, ImageFont

MODS = r"D:\gamma0.9.5\GAMMA\mods"
UNPACKED = r"D:\gamma0.9.5\Anomaly\tools\_unpacked"
PRIORITY = r"D:\gamma0.9.5\manifest\mod_priority.txt"
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(REPO, "docs", "icons")

sys.path.insert(0, HERE)
import inventory  # noqa: E402  - reuse its parse, so the two can never disagree


def load_priority():
    """mod folder name (lowercased) -> priority index. Later line wins."""
    with open(PRIORITY, encoding="utf-8", errors="replace") as fh:
        return {ln.strip().lower(): i
                for i, ln in enumerate(fh) if ln.strip()}


PRIO = load_priority()


def mod_of(path):
    rel = os.path.relpath(path, MODS)
    return rel.split(os.sep)[0]


def rank(path):
    """Priority of the mod owning a file. Unlisted mods rank below every listed one,
    and vanilla below that - an unlisted folder is usually disabled or a leftover."""
    return PRIO.get(mod_of(path).lower(), -1)


# ------------------------------------------------------------------ the DDS sheets

def index_sheets():
    """'ui\\ui_common' style sheet name -> winning .dds path on disk."""
    best = {}
    for root, is_mods in ((os.path.join(MODS), True),
                          (os.path.join(UNPACKED, "textures"), False)):
        if not os.path.isdir(root):
            continue
        for dirpath, _, files in os.walk(root):
            low = dirpath.lower()
            if is_mods and "gamedata\\textures" not in low:
                continue
            for fn in files:
                if not fn.lower().endswith(".dds"):
                    continue
                path = os.path.join(dirpath, fn)
                # key on the path below textures\, which is how XML names a sheet
                head, _, tail = low.partition("gamedata\\textures\\")
                if not tail:
                    _, _, tail = low.partition("\\textures\\")
                key = os.path.join(tail, fn.lower())[:-4] if tail else fn.lower()[:-4]
                key = key.replace("/", "\\")
                r = rank(path) if is_mods else -2
                if key not in best or r >= best[key][0]:
                    best[key] = (r, path)
    return {k: v[1] for k, v in best.items()}


SHEETS = index_sheets()


def sheet_path(name):
    return SHEETS.get(name.strip().lower().replace("/", "\\"))


# ------------------------------------------------------------- id -> cell in sheet

def index_cells():
    """texture id -> (sheet name, x, y, w, h), resolved by descr load order.

    A descr <file name="..."> groups <texture> children; an id may also carry its own
    x/y. Ids with no rect at all name a whole sheet, recorded with a None rect and
    measured from the image later.
    """
    best = {}
    for dirpath, _, files in os.walk(MODS):
        if "textures_descr" not in dirpath.lower():
            continue
        for fn in files:
            if not fn.lower().endswith(".xml"):
                continue
            path = os.path.join(dirpath, fn)
            _read_descr(path, rank(path), best)
    vdir = os.path.join(UNPACKED, "configs", "ui", "textures_descr")
    if os.path.isdir(vdir):
        for fn in os.listdir(vdir):
            if fn.lower().endswith(".xml"):
                _read_descr(os.path.join(vdir, fn), -2, best)
    return {k: v[1] for k, v in best.items()}


def _read_descr(path, r, best):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            body = fh.read()
        root = ET.fromstring("<w2>" + re.sub(r"&(?![a-z#])", "&amp;", body) + "</w2>")
    except (OSError, ET.ParseError):
        return
    for f in root.iter("file"):
        sheet = f.get("name")
        if not sheet:
            continue
        for t in f.findall("texture"):
            tid = t.get("id")
            if not tid:
                continue
            if t.get("width") and t.get("height"):
                rect = (int(float(t.get("x") or 0)), int(float(t.get("y") or 0)),
                        int(float(t.get("width"))), int(float(t.get("height"))))
            else:
                rect = None
            if tid not in best or r >= best[tid][0]:
                best[tid] = (r, (sheet, rect))


CELLS = index_cells()

_open = {}


def crop(tid, inline_rect=None):
    """The art for a texture id as an RGBA image, or None with a reason.

    inline_rect is a rect written on the spot's own <texture> element, which overrides
    the descr entry - several spots index straight into ui\\ui_common that way.
    """
    sheet, rect = CELLS.get(tid, (None, None))
    if inline_rect:
        rect = inline_rect
        if sheet is None:
            sheet = tid  # the element named the sheet directly, e.g. ui\ui_common
    if sheet is None:
        # No descr entry at all. The engine falls back to treating the id as a texture
        # PATH, so the id normally names a whole .dds under textures\ (usually ui\) -
        # which also means the art is already at its native size.
        sheet = next((c for c in (tid, "ui\\" + tid) if sheet_path(c)), None)
        if sheet is None:
            return None, "no descr entry, no matching .dds"
    path = sheet_path(sheet)
    if not path:
        return None, f"sheet {sheet}.dds not found"
    if path not in _open:
        try:
            _open[path] = Image.open(path).convert("RGBA")
        except Exception as exc:                       # noqa: BLE001 - report, not raise
            _open[path] = None
            print(f"  ! {os.path.basename(path)}: {exc}", file=sys.stderr)
    im = _open[path]
    if im is None:
        return None, "sheet unreadable"
    if rect is None:
        return im.copy(), None
    x, y, w, h = rect
    if w <= 0 or h <= 0 or x + w > im.width or y + h > im.height:
        return None, f"rect {x},{y} {w}x{h} outside {im.width}x{im.height}"
    return im.crop((x, y, x + w, y + h)), None


# ----------------------------------------------------------------------- rendering

CHECKER = (48, 48, 52), (58, 58, 63)


def plate(im, box):
    """An icon on a checkerboard, scaled up by an integer factor with NEAREST so the
    real pixel grid stays visible, then centred in a box-sized tile."""
    tile = Image.new("RGBA", (box, box))
    d = ImageDraw.Draw(tile)
    for gy in range(0, box, 8):
        for gx in range(0, box, 8):
            d.rectangle([gx, gy, gx + 7, gy + 7],
                        fill=CHECKER[((gx // 8) + (gy // 8)) % 2])
    k = max(1, min(box // max(im.width, im.height), 12))
    up = im.resize((im.width * k, im.height * k), Image.NEAREST)
    tile.alpha_composite(up, ((box - up.width) // 2, (box - up.height) // 2))
    return tile, k


def font(size):
    for name in ("consola.ttf", "arial.ttf", "DejaVuSans.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


F_ID, F_SUB = font(13), font(12)


# The ids share long boilerplate prefixes - eleven of the twelve service textures start
# "ui_inGame2_PDA_icon_" - so a label truncated from the right reads identically on every
# tile. Drop the boilerplate and wrap what is left instead.
BOILERPLATE = ("ui_inGame2_PDA_icon_", "ui_inGame2_PDA_", "ui_inGame2_", "ui_icons_",
               "ui_pda2_", "ui_mmap_", "ui_mini_", "ui_mm_", "ui_sm_", "ui_")


def label_lines(tid, width, lines=2):
    """The id with its shared prefix marked as an ellipsis and the rest word-wrapped,
    so neighbouring tiles differ in their FIRST characters, not their last."""
    short = tid
    for p in BOILERPLATE:
        if tid.startswith(p) and len(tid) > len(p) + 3:
            short = "…" + tid[len(p):]
            break
    out, cur = [], ""
    for ch in short:
        if F_ID.getlength(cur + ch) > width and cur:
            out.append(cur)
            cur = ""
            if len(out) == lines:
                return out[:-1] + [out[-1][:-1] + "…"]
        cur += ch
    out.append(cur)
    return out[:lines]


def contact_sheet(entries, cols=6, box=96):
    """A labelled grid: icon, texture id, source size, and whether IQM covers it."""
    pad, cap, gap = 12, 48, 8
    cw, ch = box + pad * 2, box + cap + pad
    rows = (len(entries) + cols - 1) // cols
    im = Image.new("RGBA", (cols * cw, rows * ch + gap), (26, 26, 29, 255))
    d = ImageDraw.Draw(im)
    for i, e in enumerate(entries):
        ox, oy = (i % cols) * cw + pad, (i // cols) * ch + pad // 2
        if e["img"] is None:
            d.rectangle([ox, oy, ox + box, oy + box], outline=(120, 60, 60), width=1)
            d.text((ox + 6, oy + box // 2 - 6), e["error"], font=F_SUB,
                   fill=(190, 120, 120))
            k = 0
        else:
            tile, k = plate(e["img"], box)
            im.alpha_composite(tile, (ox, oy))
            if e["covered"]:
                d.rectangle([ox, oy, ox + box - 1, oy + box - 1],
                            outline=(96, 190, 130), width=2)
        for j, line in enumerate(label_lines(e["id"], box + pad)):
            d.text((ox, oy + box + 4 + j * 13), line, font=F_ID, fill=(226, 226, 230))
        sub = e["size"] + (f"  x{k}" if k > 1 else "")
        d.text((ox, oy + box + 30), sub, font=F_SUB,
               fill=(140, 200, 160) if e["covered"] else (150, 150, 158))
    return im


DRAW_SIZES = (13, 18, 26, 35, 70)


def size_row(im, sizes=DRAW_SIZES):
    """One cell at every size the game really draws a spot at, as <figure> elements.

    Resampled with LANCZOS rather than shown at 128 and scaled by the browser: the
    browser would scale the ALREADY-scaled image again, and the whole point of this row
    is that a keyline three px wide at 128 is under one px at 26 and either survives the
    filter or does not. That is the thing being judged.
    """
    return "".join(
        f'<figure><img src="{data_uri(im.resize((s, s), Image.LANCZOS))}" '
        f'width="{s}" height="{s}" alt="{s}px"><figcaption>{s}</figcaption></figure>'
        for s in sizes)


def data_uri(im):
    buf = io.BytesIO()
    im.save(buf, "PNG")
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()


# ------------------------------------------------------------- IQM's own atlas

IQM_PNG = os.path.join(HERE, "iqm_map_icons.png")
IQM_DESCR = os.path.join(REPO, "gamedata", "configs", "ui", "textures_descr",
                         "iqm_textures.xml")
SCRIPT = os.path.join(REPO, "gamedata", "scripts", "modxml_n_iqm_map_icons.script")


def iqm_cells():
    """our texture id -> RGBA cell cropped from the built atlas."""
    out = {}
    if not (os.path.exists(IQM_PNG) and os.path.exists(IQM_DESCR)):
        return out
    sheet = Image.open(IQM_PNG).convert("RGBA")
    with open(IQM_DESCR, encoding="utf-8") as fh:
        root = ET.fromstring(re.sub(r"&(?![a-z#])", "&amp;", fh.read()))
    for f in root.iter("file"):
        if (f.get("name") or "").lower() != "ui\\iqm_map_icons":
            continue
        for t in f.findall("texture"):
            x, y = int(t.get("x")), int(t.get("y"))
            w, h = int(t.get("width")), int(t.get("height"))
            if x + w <= sheet.width and y + h <= sheet.height:
                out[t.get("id")] = sheet.crop((x, y, x + w, y + h))
    return out


IQM = iqm_cells()


# ------------------------------------------------- the mod's own task-kind spots

IQM_SPOTS = os.path.join(REPO, "gamedata", "configs", "ui", "iqm_map_spots.xml")


def rgb_of(el):
    if el.get("r") is None:
        return None
    return tuple(int(el.get(k)) for k in "rgb")


def task_kind_spots():
    """The spot types iqm_taskspot swaps a task onto, as
    [(location type, [(role, texture id, rgb), ...]), ...].

    Read from THIS REPO's iqm_map_spots.xml and kept out of the main walk above,
    because these replace nothing: they are location types the mod declares itself,
    with no vanilla counterpart, so there is no before-and-after pair to draw. They
    are also the only spots whose tint lives in that file rather than in the DXML
    script, so PATCH never sees them.
    """
    if not os.path.exists(IQM_SPOTS):
        return []
    with open(IQM_SPOTS, encoding="utf-8", errors="replace") as fh:
        body = fh.read()
    try:
        root = ET.fromstring("<w2>" + re.sub(r"&(?![a-z#])", "&amp;", body) + "</w2>")
    except ET.ParseError:
        return []
    elems = {el.tag: el for el in root}
    out = []
    for tag, el in elems.items():
        if not tag.startswith("iqm_task_") or el.find("level_map") is None:
            continue
        marks = []
        for view, attr in (("map", "level_map"), ("minimap", "mini_map")):
            node = el.find(attr)
            spot = elems.get((node.get("spot") if node is not None else None) or "")
            if spot is None:
                continue
            for sub, role in (("texture", "icon"), ("texture_above", "above"),
                              ("texture_below", "below")):
                for t in spot.findall(sub):
                    marks.append((f"{view} {role}", (t.text or "").strip(), rgb_of(t)))
            for bd in spot.findall("static_border"):
                for t in bd.findall("texture"):
                    marks.append((f"{view} selected", (t.text or "").strip(), rgb_of(t)))
        # A type draws the same id in both views; dedupe on (id, tint) so the section
        # shows four marks, not twelve copies of four.
        seen, keep = set(), []
        for role, tid, rgb in marks:
            if (tid, rgb) in seen:
                continue
            seen.add((tid, rgb))
            keep.append((role.split(" ", 1)[1], tid, rgb))
        out.append((tag, keep))
    return sorted(out)


def patches():
    """(spot element, sub-tag, is-selection-border) -> (our texture id, tint).

    Read from the DXML script itself so this page can never claim a replacement the mod
    does not actually apply. Comments are stripped first for the same reason inventory.py
    strips them: reverted entries are kept commented as the one-line way to restore them.
    """
    if not os.path.exists(SCRIPT):
        return {}
    with open(SCRIPT, encoding="utf-8", errors="replace") as fh:
        live = "\n".join(ln.split("--", 1)[0] for ln in fh.read().splitlines())
    # Brace-depth scan rather than a regex for the whole entry. An entry may contain a
    # NESTED table - `el = { width = 19, height = 19 }` - and a [^{}]* pattern silently
    # skips exactly those, which hid the timed-alert and pulse cells and reported them as
    # never applied. Anything that parses this table has to count braces.
    entries = []
    # +1 to step PAST the SPOTS table's own opening brace; starting on it makes the depth
    # scan treat the whole table as a single entry.
    i = live.find("{", live.find("{", live.find("local SPOTS")) + 1)
    while i != -1:
        depth, j = 0, i
        while j < len(live):
            if live[j] == "{":
                depth += 1
            elif live[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        entries.append(live[i:j + 1])
        i = live.find("{", j + 1)

    out = {}
    for body in entries:
        if "sel" not in body:
            continue
        sel = re.search(r'sel\s*=\s*"([^"]+)"', body)
        tex = re.search(r'tex\s*=\s*"(\w+)"', body)
        if not (sel and tex):
            continue
        # A chained selector ("<spot> > static_border") addresses the SELECTION FRAME, a
        # different element that happens to hang off the same spot. It must not share a key
        # with the spot's own icon or one silently overwrites the other - which it did, and
        # the corner brackets showed up as the replacement for the task reticle.
        raw = sel.group(1)
        spot = raw.split(" >")[0].strip()
        border = " >" in raw
        child = re.search(r'child\s*=\s*"(\w+)"', body)
        rgb = re.search(r"r\s*=\s*(\d+),\s*g\s*=\s*(\d+),\s*b\s*=\s*(\d+)", body)
        out[(spot, child.group(1) if child else "texture", border)] = (
            tex.group(1), tuple(int(rgb.group(i)) for i in (1, 2, 3)) if rgb else None)
    return out


PATCH = patches()


def tinted(im, rgb):
    """Apply the engine's tint: it MULTIPLIES the texture's RGB, which is what lets a
    baked black keyline survive any colour."""
    if rgb is None:
        return im
    r, g, b, a = im.split()
    t = Image.merge("RGB", [ch.point(lambda v, k=k: v * k // 255)
                            for ch, k in zip((r, g, b), rgb)])
    t.putalpha(a)
    return t


# ---------------------------------------------------------------------------- main

def main():
    os.makedirs(OUT, exist_ok=True)

    # Walk inventory's own parse so the two documents cannot drift apart. full_spot_xml
    # rather than inline: several spot files are handed to the engine by a modxml_*
    # callback instead of an #include, and reading the include chain alone silently drops
    # every marker they declare.
    text = inventory.full_spot_xml()
    root = ET.fromstring("<map_spots_all>"
                         + re.sub(r"&(?![a-z#])", "&amp;", text) + "</map_spots_all>")
    elems = {}
    for el in root.iter():
        if el is not root:
            elems.setdefault(el.tag, el)

    # texture id -> (section, inline rect, is it ours already, which spots use it)
    seen = {}
    for tag, el in elems.items():
        lm, mm = el.find("level_map"), el.find("mini_map")
        if lm is None and mm is None:
            continue
        section, _ = inventory.classify(tag)
        for spot in (lm.get("spot") if lm is not None else None,
                     mm.get("spot") if mm is not None else None):
            sel = elems.get(spot)
            if sel is None:
                continue
            covered = spot in inventory.COVERED
            for sub in ("texture", "texture_above", "texture_below"):
                for t in sel.findall(sub):
                    tid = (t.text or "").strip()
                    if not tid:
                        continue
                    rect = None
                    if t.get("x") is not None and t.get("width"):
                        rect = (int(float(t.get("x"))), int(float(t.get("y") or 0)),
                                int(float(t.get("width"))), int(float(t.get("height"))))
                    cur = seen.setdefault(tid, dict(section=section, rect=rect,
                                                    covered=False, users=set()))
                    # (spot, sub-tag) rather than just the spot: texture_above/below are
                    # separate vanilla ids AND separate patch entries, so the pairing has
                    # to carry both or an off-level arrow gets matched to the icon's tint.
                    cur["users"].add((spot, sub))
                    # Ours anywhere counts as ours: the same art is often shared, and
                    # what matters for "is this still fuzzy" is whether it got replaced.
                    cur["covered"] = cur["covered"] or covered
                    if cur["rect"] is None and rect is not None:
                        cur["rect"] = rect

    by_section = defaultdict(list)
    missing = []
    for tid, info in sorted(seen.items()):
        img, err = crop(tid, info["rect"])
        size = f"{img.width}x{img.height}" if img is not None else "-"
        if img is None:
            missing.append((tid, err))
        else:
            img.save(os.path.join(OUT, re.sub(r"[^\w.-]", "_", tid) + ".png"))
        # What IQM actually draws in this texture's place, deduplicated: one vanilla id can
        # serve several spots (ui_pda2_squad_leader serves twenty) and they need not share a
        # tint, so a texture can legitimately have more than one replacement.
        repl = []
        for key in sorted(info["users"]):
            hit = PATCH.get((key[0], key[1], False))
            if not hit or hit[0] not in IQM:
                continue
            our_tex, rgb = hit
            if (our_tex, rgb) not in [(r["tex"], r["rgb"]) for r in repl]:
                repl.append(dict(tex=our_tex, rgb=rgb,
                                 img=tinted(IQM[our_tex], rgb), spot=key[0]))
        by_section[info["section"]].append(
            dict(id=tid, img=img, error=err or "", size=size,
                 covered=bool(repl), users=sorted(info["users"]), repl=repl))

    html = [
        "<title>Map Spot Icons</title>",
        "<style>",
        ":root{--bg:#f6f6f4;--fg:#1a1a1c;--mut:#5d5d66;--card:#fff;--line:#dededa;",
        "--ok:#12794a}",
        "@media (prefers-color-scheme:dark){:root:not([data-theme=light]){",
        "--bg:#17171a;--fg:#e8e8ea;--mut:#a0a0aa;--card:#202024;--line:#33333a;",
        "--ok:#63c894}}",
        ":root[data-theme=dark]{--bg:#17171a;--fg:#e8e8ea;--mut:#a0a0aa;--card:#202024;",
        "--line:#33333a;--ok:#63c894}",
        "body{background:var(--bg);color:var(--fg);margin:0;padding:2rem 1.5rem;",
        "font:15px/1.55 system-ui,sans-serif}",
        "h1{font-size:1.6rem;margin:0 0 .3rem}h2{font-size:1.1rem;margin:2.2rem 0 .2rem;",
        "padding-bottom:.3rem;border-bottom:1px solid var(--line)}",
        "p{color:var(--mut);max-width:64ch}",
        ".g{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));",
        "gap:.7rem;margin-top:.9rem}",
        ".c{background:var(--card);border:1px solid var(--line);border-radius:8px;",
        "padding:.5rem;text-align:center;overflow:hidden}",
        ".c.ok{border-color:var(--ok)}",
        ".row{display:flex;align-items:center;justify-content:center;gap:.3rem}",
        ".c img{image-rendering:pixelated;width:60px;height:60px;object-fit:contain;",
        "background:repeating-conic-gradient(#8884 0 25%,#0000 0 50%) 0 0/14px 14px}",
        ".ar{color:var(--mut);font-size:15px;flex:0 0 auto}",
        ".n{font:11px/1.3 ui-monospace,monospace;word-break:break-all;margin-top:.4rem}",
        ".s{font-size:10px;color:var(--mut)}.c.ok .s{color:var(--ok)}",
        ".t{font:10px/1.3 ui-monospace,monospace;color:var(--mut)}",
        ".px{display:flex;align-items:flex-end;gap:1.1rem;flex-wrap:wrap;margin:.35rem 0 0}",
        ".px figure{margin:0;text-align:center}",
        ".px img{image-rendering:pixelated;display:block;margin:0 auto;",
        "background:repeating-conic-gradient(#8884 0 25%,#0000 0 50%) 0 0/8px 8px}",
        ".px figcaption{font:10px/1.4 ui-monospace,monospace;color:var(--mut)}",
        ".d{background:var(--card);border:1px solid var(--line);border-radius:8px;",
        "padding:.6rem .8rem;margin-top:.9rem}",
        ".d h3{font:600 13px/1.4 ui-monospace,monospace;margin:0 0 .35rem}",
        ".e{color:#c46;font-size:11px}",
        ".sw{display:inline-block;width:8px;height:8px;border-radius:2px;",
        "vertical-align:-1px;margin-right:3px;border:1px solid #0004}",
        "</style>",
        "<h1>Map spot icons</h1>",
        "<p>Every texture the PDA map and HUD minimap draw, cropped from the winning DDS "
        "in this install and shown at its native pixel grid — upscaled without "
        "interpolation, so coarse art looks coarse. Where Immersive Quest Markers replaces "
        "one, its own cell is shown after the arrow <span class=\"ar\">&rarr;</span> "
        "<strong>with the tint the mod actually applies</strong>, so the pair is a true "
        "before-and-after. Both are read from the shipped files — the atlas and the DXML "
        "script — so this page cannot claim a replacement that is not really applied.</p>",
        "<p>Sizes under each icon are the source cell in pixels. Compare them against the "
        "spot's UI size in <code>docs/map-spot-inventory.md</code>: where the cell is the "
        "smaller number, the game is magnifying it.</p>",
        "<p>Includes the spots no <code>#include</code> reaches — Milspec PDA's squadmate "
        "and Kiltrak body marks, and PAW's icon library, all handed to the parser by a "
        "<code>modxml_*</code> callback at load.</p>",
    ]

    for section in inventory.SECTION_ORDER:
        group = by_section.get(section)
        if not group:
            continue
        sheet = contact_sheet(group)
        fn = "sheet-" + re.sub(r"[^\w]+", "-", section.split(" - ")[0].lower()) + ".png"
        sheet.save(os.path.join(OUT, fn))
        hit = sum(1 for e in group if e["covered"])
        html += [f"<h2>{section}</h2>",
                 f"<p>{len(group)} textures, {hit} already replaced.</p>", '<div class="g">']
        for e in group:
            cls = "c ok" if e["covered"] else "c"
            body = (f'<img src="{data_uri(e["img"])}" alt="{e["id"]}">'
                    if e["img"] is not None else f'<div class="e">{e["error"]}</div>')
            for r in e["repl"]:
                body += ('<span class="ar">&rarr;</span>'
                         f'<img src="{data_uri(r["img"])}" alt="{r["tex"]}">')
            tints = "".join(
                f'<div class="t"><span class="sw" style="background:rgb'
                f'{r["rgb"] or (255, 255, 255)}"></span>{r["tex"].replace("iqm_mapspot_", "")}'
                f' {r["rgb"][0] if r["rgb"] else ""}'
                f'{"," + str(r["rgb"][1]) + "," + str(r["rgb"][2]) if r["rgb"] else ""}</div>'
                for r in e["repl"])
            html.append(f'<div class="{cls}"><div class="row">{body}</div>'
                        f'<div class="n">{e["id"]}</div>'
                        f'<div class="s">{e["size"]}</div>{tints}</div>')
        html.append("</div>")
        print(f"  {fn}: {len(group)} textures, {hit} covered")

    # The task-KIND spots. Their own section rather than cards in "Task markers"
    # above, because they replace nothing: iqm_taskspot moves a task onto a new location
    # type while the job is outstanding, so there is no vanilla art for the first column.
    # See the header of iqm_taskspot.script for why a type swap is the only way to say
    # "this pin is a mutant hunt" - a spot's tint is an XML attribute read once at parse,
    # and there is no runtime tint on a map spot.
    #
    # The count is read off the XML rather than written here, because that file is where
    # types get added and a hardcoded "two" is exactly the sort of prose that goes stale
    # the first time one does.
    kinds = task_kind_spots()
    if kinds and IQM:
        html += ["<h2>What kind of job is that pin?</h2>",
                 f"<p>{len(kinds)} location types this mod declares itself, in "
                 "<code>gamedata/configs/ui/iqm_map_spots.xml</code>. A task wears one "
                 "of them only while its objective is outstanding; once it is done and "
                 "owed to somebody it goes back to the game's own task marker, and no "
                 "save ever contains one of these type names.</p>",
                 "<p>Every pin is the task reticle used as a <em>frame</em> — inner "
                 "ring and centre crosshair dropped — with a glyph in the space they "
                 "leave, so the reticle still says <em>a task, go and find it</em> while "
                 "the glyph says which kind. Rescues share the bounty's mark outright "
                 "cell and differ only in tint: both mean <em>the objective is a "
                 "particular person</em>, and only the verb differs. The label "
                 "under a card says which: <strong>icon</strong> is the pin itself; "
                 "<strong>selected</strong> is the <code>static_border</code>, a larger "
                 "texture the engine draws around the icon <em>only while that task is "
                 "the one selected in the PDA</em>; <strong>above</strong> and "
                 "<strong>below</strong> replace the icon on the HUD minimap when the "
                 "target is on another floor and never appear on the fullscreen map."
                 "</p>", '<div class="g">']
        for tag, marks in kinds:
            for role, tid, rgb in marks:
                cur = IQM.get(tid)
                if cur is None:
                    continue
                sw = (f'<span class="sw" style="background:rgb{rgb}"></span>'
                      f"{rgb[0]},{rgb[1]},{rgb[2]}" if rgb else "no tint")
                html.append(
                    f'<div class="c ok"><div class="row">'
                    f'<img src="{data_uri(tinted(cur, rgb))}" alt="{tid}"></div>'
                    f'<div class="n">{tag}</div><div class="s">{role}</div>'
                    f'<div class="t">{sw}</div>'
                    f'<div class="t">{tid.replace("iqm_mapspot_", "")}</div></div>')
        html.append("</div>")
        for tag, marks in kinds:
            icon = next((m for m in marks if m[0] == "icon"), None)
            if icon and IQM.get(icon[1]) is not None:
                html += ['<div class="d">', f"<h3>{tag} &mdash; at the sizes it is "
                         "actually drawn at</h3>",
                         '<div class="px">'
                         + size_row(tinted(IQM[icon[1]], icon[2])) + "</div></div>"]
        print(f"  task kinds: {len(kinds)} types")

    # Our own atlas, in full. Two reasons this is worth its own section: a cell can exist
    # and be declared while nothing applies it (iqm_mapspot_home, after fast_travel_spot
    # was reverted), which no before/after pair above would ever show; and seeing the cells
    # untinted is how you check the ART rather than the colour.
    if IQM:
        used = {}
        for tex, rgb in PATCH.values():
            used.setdefault(tex, set()).add(rgb)
        html += ["<h2>The IQM atlas</h2>",
                 f"<p>All {len(IQM)} cells as built, white and untinted, with every tint "
                 "the script applies to each. A cell marked <em>not applied</em> is built "
                 "and declared but nothing currently points at it.</p>", '<div class="g">']
        for tex, im in sorted(IQM.items()):
            tints = used.get(tex)
            cls = "c ok" if tints else "c"
            body = f'<img src="{data_uri(im)}" alt="{tex}">'
            for rgb in sorted(t for t in (tints or set()) if t):
                body += f'<img src="{data_uri(tinted(im, rgb))}" alt="{tex} tinted">'
            note = ("".join(f'<div class="t"><span class="sw" style="background:rgb{rgb}">'
                            f'</span>{rgb[0]},{rgb[1]},{rgb[2]}</div>'
                            for rgb in sorted(t for t in tints if t))
                    if tints else '<div class="t">not applied</div>')
            html.append(f'<div class="{cls}"><div class="row">{body}</div>'
                        f'<div class="n">{tex.replace("iqm_mapspot_", "")}</div>{note}</div>')
        html.append("</div>")
        print(f"  IQM atlas: {len(IQM)} cells, {len(used)} applied")

    if missing:
        html += ["<h2>Could not extract</h2>",
                 "<p>Base Anomaly's textures are still packed in the <code>.db</code> "
                 "archives - the unpacked tree has configs and scripts only - so every "
                 "sheet above came from a mod. A texture no mod ships cannot be read "
                 "here even though the game draws it fine. Read this as <em>no mod "
                 "provides this art</em>, not as missing.</p>",
                 '<div class="g">']
        for tid, err in missing:
            html.append(f'<div class="c"><div class="e">{err}</div>'
                        f'<div class="n">{tid}</div></div>')
        html.append("</div>")

    page = os.path.join(OUT, "index.html")
    with open(page, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(html))
    ok = sum(1 for g in by_section.values() for e in g if e["img"] is not None)
    print(f"wrote {OUT}: {ok} icons extracted, {len(missing)} failed -> {page}")


if __name__ == "__main__":
    main()
