#!/usr/bin/env python3
"""Inventory every map spot the game actually loads, and who draws it.

Answers "what markers exist, on which of the two map views, with what art, and has
IQM replaced it yet" - the question you have to answer before deciding what else is
worth replacing. Writes docs/map-spot-inventory.md.

The three inputs are all resolved rather than assumed:

  * WHICH map_spots file wins is read from the VFS manifest, not guessed - the winner
    in GAMMA is Sota UI EGUI Style HUD's, and #include targets resolve separately
    (map_spots_campfires.xml comes from a different mod again).
  * WHICH spots exist is read from the parsed XML with includes inlined, because a
    location type in one file routinely points at a spot element defined in another.
  * WHO adds each spot at runtime is grepped out of the script trees, since the XML
    only declares a spot - something has to call level.map_add_object_spot with that
    type name for it ever to appear.

Spots other mods SPLICE IN via DXML are not reachable from map_spots_16.xml's #include
chain. Most are still on disk, in a file nothing includes until a modxml_* callback
inserts it - so they are DISCOVERED (see spliced_files) rather than listed. Only a spot
built element-by-element in Lua, with no file at all, still needs the hand table below.
Read-only: touches nothing outside this repo's docs/.
"""

import os
import re
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict

MANIFEST = r"D:\gamma0.9.5\manifest\vfs_manifest.tsv"
UNPACKED = r"D:\gamma0.9.5\Anomaly\tools\_unpacked"
MODS = r"D:\gamma0.9.5\GAMMA\mods"
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# The file the engine reads at the user's resolution. 16:9 -> screenmode 1 -> _16.
ROOT_XML = r"ui\map_spots_16.xml"


def load_manifest():
    """virtual path (normalised, lowercased) -> (winning_mod, real path)."""
    out = {}
    with open(MANIFEST, encoding="utf-8", errors="replace") as fh:
        next(fh)
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 3:
                continue
            vp, mod, real = parts[0], parts[1], parts[2]
            out.setdefault(vp.replace("/", "\\").lower(), (mod, real))
    return out


MAN = load_manifest()


def resolve(rel):
    """A configs-relative path -> (owner label, real file). Falls back to vanilla."""
    key = ("gamedata\\configs\\" + rel).replace("/", "\\").lower()
    if key in MAN:
        return MAN[key]
    cand = os.path.join(UNPACKED, "configs", rel)
    if os.path.exists(cand):
        return ("data (vanilla)", cand)
    return (None, None)


INCLUDE = re.compile(r'^\s*#include\s+"([^"]+)"', re.M)


def inline(rel, seen=None, owners=None):
    """Read a spot file with #includes recursively inlined, as the engine does."""
    seen = seen if seen is not None else set()
    owners = owners if owners is not None else {}
    if rel.lower() in seen:
        return ""
    seen.add(rel.lower())
    mod, real = resolve(rel)
    if not real:
        print(f"  ! unresolved include: {rel}", file=sys.stderr)
        return ""
    owners[rel] = mod
    with open(real, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    return INCLUDE.sub(lambda m: inline(m.group(1), seen, owners), text)


# ------------------------------------------------------------------ DXML splices

# rel path -> the modxml_ script that splices it in. Filled by spliced_files().
SPLICED_FROM = {}


def spliced_files():
    """Spot files that reach the DOM only because a modxml_* callback inserts them.

    `#include` is resolved by the XML parser, so a file nothing includes is a file this
    tool never sees - and two mods here ship exactly that, handing the engine their
    includes at load instead (`xml_obj:insertFromXMLString`). Reading map_spots_16.xml
    alone therefore missed Milspec PDA's squadmate and Kiltrak body marks and every one
    of PAW's ~85 icons, while reporting a complete inventory.

    Discovered, not listed, for the same reason the IQM coverage set is read from the
    shipping script: a hand table goes stale silently, and this one already had - it
    carried PAW's waypoint as a single entry when PAW splices five files.

    Only the includes a script INSERTS count. The `xml_file_name ==` guard also names a
    map_spots file, but that is the file being patched, not a new one, and it is not on
    an `#include` line so the regex never reaches it.

    Ordered by the modxml_ filename, which is dxml_core's own firing order (it sorts the
    names and fires in that order, last write winning) - so where two splices define the
    same element, this reproduces which one the engine keeps.
    """
    out = []
    for vp, (mod, real) in MAN.items():
        name = os.path.basename(vp)
        if not (name.startswith("modxml_") and name.endswith(".script")):
            continue
        try:
            with open(real, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        if "insertFromXMLString" not in text or "map_spots" not in text:
            continue
        out += [(name, rel, mod) for rel in INCLUDE.findall(text)]
    return sorted(out, key=lambda t: t[0])


def full_spot_xml(owners=None):
    """The whole spot DOM the engine ends up with: the #include chain on disk, then
    everything the modxml_* splices append.

    Appended rather than merged, and `seen` is shared, so a file already pulled in by a
    real #include is not read twice - which matters because PAW's map_spots_paw.xml is
    itself only a list of five further includes.
    """
    owners = owners if owners is not None else {}
    seen = set()
    text = inline(ROOT_XML, seen, owners)
    for script, rel, _mod in spliced_files():
        before = set(seen)
        extra = inline(rel, seen, owners)
        if extra:
            for got in seen - before:
                SPLICED_FROM.setdefault(got, script)
            text += "\n" + extra
    return text


# ---------------------------------------------------------------- spot call sites

SPOT_API = ("map_add_object_spot", "map_remove_object_spot", "map_has_object_spot",
            "change_level_spot")


def spot_scripts():
    """Every script that touches the map-spot API, as (label, source text).

    Matching the type name as a LITERAL rather than parsing the call is deliberate:
    plenty of mods never write the name at the call site at all - ZCP maps item
    classes to spot names through a table, Screen Space Shaders does the same for
    anomaly types - so a regex anchored on map_add_object_spot's second argument
    finds the vanilla callers and misses most of the interesting ones.
    """
    out = []
    for root, is_mods in ((MODS, True), (os.path.join(UNPACKED, "scripts"), False)):
        for dirpath, _, files in os.walk(root):
            for fn in files:
                if not fn.endswith(".script"):
                    continue
                path = os.path.join(dirpath, fn)
                try:
                    with open(path, encoding="utf-8", errors="replace") as fh:
                        text = fh.read()
                except OSError:
                    continue
                if not any(k in text for k in SPOT_API):
                    continue
                label = (os.path.relpath(path, MODS).split(os.sep)[0] if is_mods
                         else "data (vanilla)")
                out.append((label, text))
    return out


def find_adders(names):
    """spot type -> set of labels for mods whose spot-handling scripts name it."""
    files = spot_scripts()
    out = defaultdict(set)
    for name in names:
        for quoted in (f'"{name}"', f"'{name}'"):
            for label, text in files:
                if quoted in text:
                    out[name].add(label)
    return out


# ------------------------------------------------------------------ IQM coverage

def iqm_covered():
    """Spot ELEMENT names this mod already re-textures, from the DXML script itself,
    so this inventory cannot drift out of step with what actually ships."""
    src = os.path.join(REPO, "gamedata", "scripts", "modxml_n_iqm_map_icons.script")
    with open(src, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    # Strip Lua line comments FIRST. Without this a spot that has been reverted still
    # counts as covered, because the file keeps the old entry commented out as the
    # one-line way to restore it - which is exactly how fast_travel_spot read as patched
    # after it had been reverted. Comments in this file are prose, never code.
    live = "\n".join(ln.split("--", 1)[0] for ln in text.splitlines())
    return {m.group(1).split(" >")[0].strip()
            for m in re.finditer(r'\{\s*sel\s*=\s*"([^"]+)"', live)}


COVERED = iqm_covered()

# Spots with no file behind them at all - built element by element in Lua, so there is
# nothing for spliced_files() to find. Anything that lives in a real .xml belongs there,
# not here; entries already picked up by the parse are dropped when the doc is written.
SPLICED = [
    ("atue_return_task_spot", "gamma-active-task-ui-enhancements",
     "Task done, go and hand it in (green). Both views."),
    ("paw_task_default_spot", "Personal Adjustable Waypoint",
     "Pulse ring around a player-placed waypoint."),
]

# (prefix, section, what the PLAYER sees). Matched in order, so put the specific
# prefixes above the general ones. The point of the text is to say what the marker
# means in play, not to restate the element name.
SERVICES = "Service markers - the people you go to a hub for"
TASKS = "Task markers"
NAV = "Navigation and the world"
STASH = "Stashes, loot and items"
PEOPLE = "People, bodies and squads"
HAZARD = "Anomalies and hazards"
WARFARE = "Warfare and the faction overlay"
GENERIC = "Generic script-driven markers"
PAW = "Personal Adjustable Waypoint - the player-picked icon library"
INTERNAL = "Internal - pointers, borders, debug, multiplayer"

PURPOSE = [
    ("ui_pda2_medic_location", SERVICES, "Medic - someone who patches you up"),
    ("ui_pda2_trader_location", SERVICES, "Trader - general goods"),
    ("ui_pda2_mechanic_location", SERVICES, "Mechanic - repairs and upgrades"),
    ("ui_pda2_barman_location", SERVICES, "Barman - food, drink, rumours"),
    ("ui_pda2_actor_sleep_location", SERVICES, "A bed you can sleep in"),
    ("ui_pda2_scout_location", SERVICES, "Guide - paid fast travel between hubs"),
    ("ui_pda2_special_location", PEOPLE, "Story/faction important character"),
    ("ui_pda2_quest_npc_location", PEOPLE, "NPC a task points you at"),
    ("ui_pda2_companion_location", PEOPLE, "Your companion"),
    ("ui_pda2_actor_box_location", STASH, "Your own stash box"),
    ("ui_pda2_player_mine_location", HAZARD, "A mine you placed"),
    ("storyline_task_on_guider", TASKS, "Storyline task done - report back to the giver"),
    ("secondary_task_on_guider", TASKS, "Side task done - report back to the giver"),
    ("storyline_task", TASKS, "Active storyline task objective"),
    ("secondary_task", TASKS, "Active side task objective"),
    ("ui_storyline_task_blink", TASKS, "15 s pulse when a storyline task appears"),
    ("ui_secondary_task_blink", TASKS, "15 s pulse when a side task appears"),
    ("primary_object", TASKS, "Quest object a task sends you to (ZCP / quest rewrites)"),
    ("fast_travel", NAV, "Fast-travel point (Limited Fast Travel)"),
    ("actor_location_p", NAV, "You, with a facing arrow"),
    ("actor_location", NAV, "You"),
    ("level_changer", NAV, "Level transition - the way out of this map"),
    ("campfire", NAV, "Campfire you can rest and cook at (Display Campfires on Map)"),
    ("user_defined", GENERIC, "Generic user-placed marker"),
    ("treasure_all_opened", STASH, "Stash, already emptied"),
    ("treasure_searched", STASH, "Stash you have already searched"),
    ("treasure_unique", STASH, "Stash holding something unique"),
    ("treasure_player", STASH, "Stash you marked yourself"),
    ("treasure_all", STASH, "Stash (show-all-stashes view)"),
    ("treasure", STASH, "Stash from a found note"),
    ("artefact", STASH, "Detected artefact"),
    ("item_ammo", STASH, "Loose ammunition on the ground (ZCP)"),
    ("item_drink", STASH, "Loose drink (ZCP)"),
    ("item_food", STASH, "Loose food (ZCP)"),
    ("item_kit", STASH, "Loose toolkit/repair item (ZCP)"),
    ("item_medical", STASH, "Loose medical item (ZCP)"),
    ("item_misc", STASH, "Other loose item (ZCP)"),
    ("anom_zone", HAZARD, "Anomalous field"),
    ("anomaly_disabled", HAZARD, "Anomaly currently inactive (Screen Space Shaders / ZCP)"),
    ("anomaly_chemical", HAZARD, "Chemical anomaly"),
    ("anomaly_electric", HAZARD, "Electrical anomaly"),
    ("anomaly_gravitational", HAZARD, "Gravitational anomaly"),
    ("anomaly_radioactive", HAZARD, "Radioactive anomaly"),
    ("anomaly_thermal", HAZARD, "Thermal anomaly"),
    # Kiltrak's five selectable corpse styles, spliced in by Milspec PDA. Above the plain
    # deadbody_location line because classify() takes the first prefix that matches.
    ("deadbody_location_whtx", PEOPLE, "Corpse - white X, the Kiltrak default for your own kills"),
    ("deadbody_location_skul", PEOPLE, "Corpse - skull (Kiltrak style)"),
    ("deadbody_location_sdot", PEOPLE, "Corpse - small blue dot, the default for other people's kills"),
    ("deadbody_location_mdot", PEOPLE, "Corpse - medium blue dot (Kiltrak style)"),
    ("deadbody_location_ldot", PEOPLE, "Corpse - large blue dot (Kiltrak style)"),
    ("deadbody_location", PEOPLE, "A corpse (Body Dots on Minimap / Milspec PDA)"),
    ("enemy_location", PEOPLE, "Hostile stalker"),
    ("friend_location", PEOPLE, "Friendly stalker"),
    ("neutral_location", PEOPLE, "Neutral stalker"),
    ("squadmate_", PEOPLE, "One of your own squad, tinted to their faction (Milspec PDA)"),
    ("companion_spot", PEOPLE, "Companion, drawn as a squad marker"),
    ("alife_combat", PEOPLE, "A-life firefight in progress"),
    ("alife_presentation_squad", PEOPLE, "A-life squad, coloured by relation"),
    ("alife_presentation_faction", WARFARE, "Faction presence on the world map"),
    ("alife_presentation_smart", WARFARE, "Smart terrain (base/camp territory)"),
    ("alife_presentation_general_base", WARFARE, "Faction base, coloured by relation"),
    ("warfare_selected_target", WARFARE, "Warfare - the objective you picked"),
    ("warfare_friendly", WARFARE, "Warfare - friendly squad"),
    ("warfare_enemy", WARFARE, "Warfare - hostile squad"),
    ("warfare_neutral", WARFARE, "Warfare - neutral squad"),
    ("warfare_", WARFARE, "Warfare - squad of a named faction"),
    ("circle_", WARFARE, "Faction/status ring on the world map"),
    ("crlc_", WARFARE, "Warfare circle overlay (territory radius)"),
    ("blue_location", GENERIC, "Generic blue marker, script use"),
    ("green_location", GENERIC, "Generic green marker, script use"),
    ("red_location", GENERIC, "Generic red marker, script use"),
    ("explo_location", GENERIC, "Upgrade/explosive marker, script use"),
    ("paw_task_default", TASKS, "Pulse ring around a player-placed waypoint"),
    ("paw_npc_", PAW, "Service NPC, in PAW's own art"),
    ("paw_badge_", PAW, "Faction patch, at three source resolutions (plain / hr / uhr)"),
    ("paw_stash_", PAW, "Stash, by colour"),
    ("paw_bwhr_", PAW, "Black-on-white pictogram set"),
    ("paw_pin_", PAW, "Map pin"),
    ("paw_diamond_", PAW, "Diamond, coloured by relation"),
    ("paw_chevron_", PAW, "Chevron, coloured by relation"),
    ("paw_flag_", PAW, "Flag, coloured by relation"),
    ("paw_crosshair_", PAW, "Crosshair"),
    ("paw_obj_", PAW, "Object marker"),
    ("paw_", PAW, "Waypoint art the player can choose"),
    ("mp_", INTERNAL, "Multiplayer only - never drawn in single-player"),
    ("debug_", INTERNAL, "Debug dot"),
    ("quest_pointer", INTERNAL, "Off-screen arrow pointing at a marker"),
    ("combat_pointer", INTERNAL, "Off-screen arrow pointing at combat"),
    ("mini_map_spot_border", INTERNAL, "Highlight ring around a minimap marker"),
    ("level_map_spot_border", INTERNAL, "Highlight ring around a map marker"),
    ("complex_map_spot_border", INTERNAL, "Highlight ring on the multi-level map"),
]

SECTION_ORDER = [SERVICES, TASKS, NAV, STASH, PEOPLE, HAZARD, WARFARE, GENERIC, PAW,
                 INTERNAL, "Uncategorised"]


def classify(name):
    for pref, section, txt in PURPOSE:
        if name.startswith(pref):
            return section, txt
    return "Uncategorised", ""


def texture_sizes():
    """texture id -> set of (w, h) source cell sizes, from every winning descr file.

    This is the number that decides whether a spot is worth replacing at all: a spot
    is sized in UI units (resolution-relative) but its ART is a fixed cell in a DDS,
    so a 9x9 cell on a 19-unit spot is being magnified ~3x at 1440p. Sizes are
    collected as a SET because several descr files may declare the same id and the
    engine's merge order between them is not worth relying on - a disagreement is
    something to look at, not to silently pick a side in.
    """
    out = defaultdict(set)
    for vp, (mod, real) in MAN.items():
        if "\\textures_descr\\" not in vp or not vp.endswith(".xml"):
            continue
        try:
            with open(real, encoding="utf-8", errors="replace") as fh:
                body = fh.read()
            root = ET.fromstring("<w2>" + re.sub(r"&(?![a-z#])", "&amp;", body) + "</w2>")
        except (OSError, ET.ParseError):
            continue
        for t in root.iter("texture"):
            tid, w, h = t.get("id"), t.get("width"), t.get("height")
            if tid and w and h:
                out[tid].add((int(float(w)), int(float(h))))
    return out


TEXSIZE = texture_sizes()


def px(tid):
    """The source cell size for a texture id, as a string, or '?' if undeclared."""
    sizes = TEXSIZE.get(tid)
    if not sizes:
        return "?"
    return " / ".join(f"{w}x{h}" for w, h in sorted(sizes))


def art(el):
    """The texture id a spot element draws, with its source cell size, plus the
    off-level swaps the minimap substitutes when the target is on another floor."""
    bits = []
    for tag in ("texture", "texture_above", "texture_below"):
        for t in el.findall(tag):
            tid = (t.text or "").strip()
            if not tid:
                continue
            # An x/y on the element means the spot indexes into the sheet itself and
            # ignores any id-declared cell, so that inline rect IS the source size.
            if t.get("x") is not None:
                size = f"{t.get('width')}x{t.get('height')} @{t.get('x')},{t.get('y')}"
            else:
                size = px(tid)
            label = "" if tag == "texture" else f"{tag[8:]}: "
            bits.append(f"{label}`{tid}` ({size})")
    return "; ".join(bits)


def art_ids(el):
    """Just the texture ids, for grouping spots that share their art."""
    return tuple(sorted((t.text or "").strip()
                        for tag in ("texture", "texture_above", "texture_below")
                        for t in el.findall(tag) if (t.text or "").strip()))


def main():
    owners = {}
    text = full_spot_xml(owners)
    # The spot files are a bag of siblings with no single root and use bare & in places.
    root = ET.fromstring("<map_spots_all>" + re.sub(r"&(?![a-z#])", "&amp;", text) + "</map_spots_all>")

    elems = {}
    for el in root.iter():
        if el is not root:
            elems.setdefault(el.tag, el)

    # A "location type" is what script code names; it routes to one or two spot
    # elements, one per view. Everything else is a spot element or a pointer.
    locations = []
    for tag, el in elems.items():
        lm = el.find("level_map")
        mm = el.find("mini_map")
        if lm is None and mm is None:
            continue
        locations.append((tag,
                          lm.get("spot") if lm is not None else None,
                          mm.get("spot") if mm is not None else None))

    adders = find_adders([l[0] for l in locations])

    def cell(spot):
        if not spot:
            return "-", False
        sel = elems.get(spot)
        if sel is None:
            return f"`{spot}` **(declared but missing!)**", False
        size = f"{sel.get('width') or '?'}x{sel.get('height') or '?'}"
        border = " +sel.border" if sel.find("static_border") is not None else ""
        hit = spot in COVERED
        return (f"`{spot}` {size}{border}<br>{art(sel)}"
                + (" **[IQM]**" if hit else ""), hit)

    rows = []
    for loc, lms, mms in sorted(locations):
        section, why = classify(loc)
        map_cell, map_hit = cell(lms)
        mini_cell, mini_hit = cell(mms)
        views = "+".join(v for v, on in (("map", lms), ("minimap", mms)) if on) or "-"
        # Group key is the ART, because a texture is what you replace: the eight
        # level_changer_* types are one job, not eight, and the twelve
        # *_task_location_complex_* types are the same two files as the plain ones.
        ids = tuple(art_ids(elems[s]) for s in (lms, mms) if s and s in elems)
        rows.append(dict(loc=loc, section=section, why=why, views=views,
                         map=map_cell, mini=mini_cell, covered=map_hit or mini_hit,
                         art=ids, spots=tuple(s for s in (lms, mms) if s),
                         who=", ".join(sorted(adders.get(loc, []))) or "-"))

    done = sum(1 for r in rows if r["covered"])
    by_section = defaultdict(list)
    for r in rows:
        by_section[r["section"]].append(r)

    lines = [
        "# Map spot inventory",
        "",
        "Every marker the game can draw on the PDA map and the HUD minimap. Generated by",
        "`tools/map-icons/inventory.py` from the copy of `map_spots_16.xml` that actually",
        f"wins in this install (`{owners.get(ROOT_XML)}`), with all `#include`s inlined.",
        "",
        "**How to read this.** A *location type* is the name script code passes to",
        "`level.map_add_object_spot`. It routes to one or two *spot elements* - one per",
        "view - and each of those names the texture that gets drawn. A type with only a",
        "map column never appears on the minimap, and vice versa: that is a property of",
        "the XML, not a bug, and it is why some markers can only ever be fixed in one",
        "view. `**[IQM]**` marks a spot this mod already re-textures.",
        "",
        "*Added by* lists every mod whose spot-handling scripts mention the type. It is",
        "deliberately generous - it catches mods that only remove or query the spot, and",
        "mods shipping a script that loses its load-order fight - so read it as \"these are",
        "the mods in play here\", not as a single owner.",
        "",
        "Sizes are UI units, not pixels: they scale with resolution (19 units is ~27 px at",
        "1080p, ~36 at 1440p). Anything drawn from a 8-15 px source cell is being magnified",
        "at every common resolution, which is the case for replacing it.",
        "",
        f"**{len(rows)} location types across {len(elems)} elements; {done} already covered "
        f"by IQM.**",
        "",
    ]

    # The shortlist exists because 182 rows is not a decision aid. Internal plumbing and
    # multiplayer are excluded, so is anything already done, and the rest is collapsed by
    # shared art into one row per JOB.
    cands = [r for r in rows
             if not r["covered"] and r["section"] not in (INTERNAL, "Uncategorised")]
    jobs = defaultdict(list)
    for r in cands:
        jobs[(r["section"], r["art"])].append(r)

    lines += [
        "## Shortlist: one row per job",
        "",
        f"{len(cands)} uncovered types that get drawn in normal single-player, collapsed",
        f"into **{len(jobs)} jobs** by the art they share - the eight `level_changer_*`",
        "directions are one texture, and the twelve `*_task_location_complex_*` variants",
        "reuse the plain task spots. Pointers, borders, debug dots and the `mp_*`",
        "multiplayer set are left out entirely.",
        "",
        "*Source cell* is the size of the art in the DDS. Compare it against the spot's UI",
        "size in the sections below: where the cell is the smaller number, the game is",
        "magnifying it, and that gap is the whole quality argument. A `?` means no",
        "`textures_descr` entry declares that id, which normally means the id IS a whole",
        "DDS file rather than a cell in a sheet - so it is already at its native size and",
        "is a weaker candidate. Two sizes separated by `/` means two descr files disagree.",
        "",
        "| Job | Types | Views | Source cell(s) | Purpose |",
        "|---|---|---|---|---|",
    ]
    for (section, _), group in sorted(
            jobs.items(), key=lambda kv: (SECTION_ORDER.index(kv[0][0]),
                                          -len(kv[1]), kv[1][0]["loc"])):
        ids = sorted({tid for r in group for spot in r["spots"] if spot in elems
                      for tid in art_ids(elems[spot])})
        head = group[0]
        names = f"`{head['loc']}`"
        if len(group) > 1:
            names += f" +{len(group) - 1} more"
        views = "+".join(sorted({v for r in group for v in r["views"].split("+")}
                                - {"-"})) or "-"
        art_txt = "<br>".join(f"`{t}` {px(t)}" for t in ids) or "-"
        lines.append(f"| {section.split(' - ')[0]} | {names} | {views} | {art_txt} "
                     f"| {head['why']} |")
    lines.append("")

    for section in SECTION_ORDER:
        group = by_section.get(section)
        if not group:
            continue
        hit = sum(1 for r in group if r["covered"])
        lines += [
            f"## {section}",
            "",
            f"{len(group)} types, {hit} covered.",
            "",
            "| Location type | Views | Fullscreen map spot | Minimap spot | Purpose | Added by |",
            "|---|---|---|---|---|---|",
        ]
        for r in group:
            lines.append("| `%(loc)s` | %(views)s | %(map)s | %(mini)s | %(why)s | %(who)s |"
                         % r)
        lines.append("")

    # A location type routing to a spot element that no file defines. Worth calling out
    # rather than hiding: the engine asserts on the missing node when something actually
    # asks for that type, so it is a latent crash, not a cosmetic gap.
    broken = [(r["loc"], s) for r in rows for s in r["spots"] if s not in elems]
    if broken:
        lines += [
            "## Declared but missing",
            "",
            "These location types point at a spot element nothing defines. Harmless while",
            "no script asks for the type - `CMapLocation::Load` asserts on the missing node",
            "if one ever does, so it is a latent crash rather than a missing icon. Nothing",
            "for this mod to fix; noted because the parse found it.",
            "",
            "| Location type | Points at |",
            "|---|---|",
        ]
        for loc, spot in broken:
            lines.append(f"| `{loc}` | `{spot}` |")
        lines.append("")

    # Anything the splice discovery already parsed is in the tables above and does not
    # belong here as well. What survives is the genuinely file-less case.
    hand = [e for e in SPLICED if e[0] not in elems]
    if hand:
        lines += [
            "",
            "## Built in Lua, with no file behind them",
            "",
            "These spot elements are assembled in script at load, so no `.xml` declares",
            "them and nothing above can find them. Listed by hand.",
            "",
            "| Spot | From | Purpose | IQM |",
            "|---|---|---|---|",
        ]
        for name, mod, why in hand:
            lines.append(f"| `{name}` | {mod} | {why} | "
                         f"{'yes' if name in COVERED else 'no'} |")

    lines += [
        "",
        "## Files this was built from",
        "",
        "A file marked *spliced* is reached by no `#include`: the named `modxml_*` script",
        "hands it to the parser at load instead, so it is invisible to anything that only",
        "follows the include chain.",
        "",
        "| Spot file | Winning mod | How |",
        "|---|---|---|",
    ]
    for rel, mod in owners.items():
        via = SPLICED_FROM.get(rel.lower())
        lines.append(f"| `{rel}` | {mod} | {f'spliced by `{via}`' if via else 'include'} |")
    lines.append("")

    out = os.path.join(REPO, "docs", "map-spot-inventory.md")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines))
    print(f"wrote {out}: {len(rows)} location types, {done} covered by IQM")


if __name__ == "__main__":
    main()
