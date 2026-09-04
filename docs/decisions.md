# Option decisions — why each setting is what it is

The design journal for the MCM options, one entry per option key. It used to live in
the option registry itself, in `gamedata/scripts/iqm_core.script`, where forty-seven
lines of argument about one colour sat between two rows of a table. That made the
registry unreadable for the job it is actually for -- looking up what an option *is* --
so the histories moved here and the registry kept a line each.

Nothing was rewritten on the way across. Every entry below is the comment as it stood
in the code, revision markers, measured tables, engine citations and all.

**What is still in the code, and should stay there:** what an option does, its units,
its range and any clamp, and any warning about engine behaviour or failure modes. Those
are things a reader needs in order not to break something. What is here is history and
justification: why a value was chosen, what it was before, what was tried and rejected.

Each option in `OPTIONS` carries a `-- rationale: docs/decisions.md#<key>` pointer to
its entry here. Related: `docs/ar-navigation.md` (the research tracker the route and
waypoint marker were built out of) and `docs/minimap-route.md` (F3, the trail).

## Index

**General**

- [`route_gap`](#route_gap) — metres between direction chevrons
- [`route_flow`](#route_flow) — conveyor speed
- [`map_icons`](#map_icons) — why it needs a restart and cannot not
- [`map_icon_style`](#map_icon_style) — the STALKER 2 diamonds, and the two things they stop saying
- [`map_task_kinds`](#map_task_kinds) — the skull and the red reticle, and what they cost
- [`map_spot_names`](#map_spot_names) — the NPC's name in a map pin's tooltip
- [`map_hide_companions`](#map_hide_companions) — the one map row that removes a mark instead of redrawing one
- [`noise`](#noise) — interference: why it is on by default, and why the tiers are not options
- [`noise_amt`](#noise_amt) — strength, and why 100 rather than something cautious
- [`noise_giveup`](#noise_giveup) — the one tier that can take a marker away

**Nameplates (cards)**

- [`focus_mode`](#focus_mode) — card only what you are looking at, and why it ships off
- [Colour channel step](#colour-channel-step) — `col_r` / `col_g` / `col_b`, and both route pages

**Waypoint markers**

- [Which roles get a marker](#which-roles-get-a-marker) — the page's scope, and its one section
- [`beacon_waypoint`](#beacon_waypoint) — the placed waypoint, exempt from `beacon_dist`
- [`beacon_party`](#beacon_party) — the one mark that is not a destination
- [`beacon_handin`](#beacon_handin) — a difficulty gate, and why it is not a task-type list
- [`beacon_targets`](#beacon_targets) — the hand-in that has to outrank the shop on the same body
- [`beacon_color`](#beacon_color) — one list rather than two switches
- [`beacon_r` / `beacon_g` / `beacon_b`](#beacon_r--beacon_g--beacon_b) — a colour of the marker's own
- [`beacon_rsize`](#beacon_rsize) — where the row sits

**Route: ground**

- [`mark_route`](#mark_route) — why the route is opted into
- [`route_reveal`](#route_reveal) — summoning the line, and why it is not the default
- [`route_dwell`](#route_dwell) — the seconds that make a tap work
- [`route_key`](#route_key) — why the summon needed a key of its own
- [`route_dist`](#route_dist) — the range that moved twice
- [`route_shape`](#route_shape) — the shapes that were cut
- [`route_pulse`](#route_pulse) — four revisions, and a measured table
- [`route_a`](#route_a) — why it is fully opaque
- [`route_r` / `route_g` / `route_b`](#route_r--route_g--route_b) — five revisions of one colour

**Route: minimap**

- [`minimap_dist`](#minimap_dist) — why the two views' distances are separate
- [`minimap_style`](#minimap_style) — a list rather than a flag
- [`minimap_r` / `minimap_g` / `minimap_b`](#minimap_r--minimap_g--minimap_b) — its own three keys

**The menu itself**

- [Preconditions](#preconditions) — why almost no row is conditional any more

---

## The menu itself

### Preconditions

Around forty rows used to be gated on another *setting*: the route and minimap pages rode
their own on/off switch and the quest-target nameplates, the combat dim's three rows rode
`dim_hold`, each marker row rode its card role, the centre falloff's floor rode its
radius, and focus mode's three sliders rode its mode. R2.59 removed all of them.

**The reason is when MCM evaluates a precondition: at page BUILD time, not while the
player is on the page.** So a row a gate reveals does not appear when its gate is
satisfied — it appears the next time the menu is opened. Switch the ground route on and
its dozen controls are still missing; the only way to see what a feature offers is to set
it, back out of MCM entirely, and come back in. Multiply that by five pages and the menu
cannot be read at a glance and cannot be trusted: you are never sure whether a feature has
no settings or whether you simply have not earned them yet.

**What the gating bought was never correctness.** A hidden row keeps its stored value, and
every feature gates on its own switch in code regardless — `iqm_taskspot` re-tests
`map_icons` before it places a spot, precisely because hiding the `map_task_kinds` row
never stopped the value being set. So the rows were tidiness, and the trade is badly
priced: an inert slider costs one line of reading, while a page that changes shape between
visits costs a trip out through the menu and back.

**Two kinds of gate survived, and neither is a setting.**

*The install.* `paw_here`, `party_here`, `has_keybinds`, `no_keybinds`. A row for Personal
Adjustable Waypoint's marker in an install without PAW is a switch on nothing, and a
`key_bind` row cannot be drawn at all on MCM below 1.6.0. None of these can change while
the player is in the menu, so gating on them has no cost — the row is absent on every
visit, consistently, which reads as "this mod does not have that" rather than as a menu
that moved.

*The notes.* `no_targets`, `route_summon_unbound`. A note's text is a *claim*, and each of
these is only true in one state — "the route has nothing to point at", "the summon has no
key of its own". Showing one unconditionally would make the menu assert something false.
Hiding a sentence that does not apply is a different act from hiding a control: the
sentence has no value to lose and nothing to configure.

The mcm harness enforces the rule from both ends — every option row must stay reachable
with each feature switch turned off, unset, or zero, swept rather than listed so it cannot
rot into naming only the rows somebody remembered.

---

## General

### `route_gap`

Metres between direction chevrons along the route. 3 by default since R2.16: at that
spacing the ground-space marks nearly touch at distance and read as one band of
arrows, which is the look this is drawn from. Raise it to ~10 for widely spaced
direction marks instead -- that, with route_style 0, is the pre-R2.16 route.

The slider has ranged 2-8 m (when the marks WERE the route), then 6-30 (when the
stroke took that job over and they were only sparse direction hints), and now 2-30:
they are ground-space marks again and want to be dense enough to read as a band. 0 is
deliberately not offered, since the one thing a plain line cannot tell you is which
way along it to go.

### `route_flow`

CONVEYOR SPEED for the route marks, in tenths of a metre per second (MCM tracks are
integers, and 0.1 m/s is finer than anyone can see). 0 holds them still, which is what
the route used to do and is still a legitimate setting -- a moving element in the corner
of the eye is a comfort question, not only a taste one.

**The default is the cap, 40** (4 m/s, a fast walk), which is also where the range stops:
past that the run reads as a strobe rather than a direction -- the marks cross a gap
quicker than the eye tracks one of them. Flow at the top of its range is what makes the
line read as paint moving with you rather than as a row of glyphs on the floor, which is
the whole claim the ground route makes about itself, so the shipped value is the one that
demonstrates it rather than the one that withholds it.

### `map_icons`

**The mod's map art had no switch until R2.48**, on the reasoning that art with no
behaviour attached needs none. Two things changed that: some players want the rest of
their setup's icons back, and the task-kind spots below are art that *does* carry
behaviour, so they needed something to ride.

**The restart is not caution, it is the mechanism.** `g_uiSpotXml` is a process-lifetime
static: the engine parses `map_spots.xml` on the first map location created and frees it
only at DLL detach (`map_location.cpp:92-99`, `xrgame_dll_detach.cpp:132`). There is no
reparse to hook, so there is no live toggle at any price -- and not even returning to the
main menu and loading a save re-reads it. The label says "needs restart" because that is
the only place the fact can be told.

**Read at parse time, not through `iqm_core.C`.** `modxml_n_iqm_map_icons.icons_on` calls
`ui_mcm.get` directly. The modxml has no `apply_config` and no `on_game_start`, and it
fires on whatever frame the engine first wants the file; routing through `iqm_core` would
make the answer depend on two modules' relative readiness at that instant, which is a race
with no visible losing side.

**Defaults ON at every failure** -- no MCM, no registered menu, no stored key. All three
mean "the player has not asked for vanilla", and turning the art off on a shrug would
silently undo the mod for anyone without MCM.

**It governs the PDA symbols legend too.** The legend is a key to the map's marks; leaving
it patched while the map reverted would make it a key to marks that are no longer there,
which is worse than either consistent state.

### `map_icon_style`

**The same marks in S.T.A.L.K.E.R. 2's clothes**: a white glyph in a thin white diamond,
no colour coding. Off by default; `0` is the ring badges the mod has always drawn.

**It is one atlas's worth of art, framed twice.** `ui\iqm_map_icons_s2` has the same 26
cells at the same origins as the ring atlas, under `iqm_mapspot_s2_*` ids, so the runtime
switch is a rename plus a white tint — `modxml_n_iqm_map_icons.restyle_s2`, one pass over
the DOM it has just patched, keyed on the id *prefix* rather than on a list of spot names.
That is what makes it cheap and what makes it complete: the pass also catches the mod's
own spot types in `iqm_map_spots.xml`, which carry their ids and tints in XML and are in
the same document by then. A per-entry branch in the `SPOTS` loop would have restyled the
vanilla spots and left IQM's task-kind pins in the ring style — the two halves of one map
disagreeing.

**What the player gives up is colour — most of it.** A medic and a trader differ by glyph
alone at the ~26 px the minimap draws these at, where the ring style separates every
within-family pair by dE 28 in CIELAB (see the palette note in
`modxml_n_iqm_map_icons`). That is the look rather than a bug, but it is not absolute:
`S2_KEEP_COLOUR` is a list, white is only its default, and three task tints came back to
it after a play-test.

**The three that came back are the hand-in green, the bounty red and the mutant olive**,
and the line they draw is worth having written down: colour stays where it answers a
question the player asks *before* reading the glyph — "is anything finished?", "is
anything going to shoot at me?" — and goes where it was only telling two nouns apart. A
medic and a trader are both "a person who is here", and the glyph settles which; a
finished job is a different *kind of thing* to look at the map for. At 26 px a pin is read
as a colour first and a drawing second, so those three lost a filter in the all-white
pass while everything else lost a decoration.

The delivery envelope keeps the same green, because it already shares it deliberately —
walking a package to a named NPC is the same act as walking a finished job back to its
giver. Splitting the pair here would have made the style contradict the palette.

**The selection frame stays white on every pin.** A selection is a state, not a kind, so
the `static_border`'s tint is not the mark's; it also keeps a coloured mark and its frame
from reading as one two-tone shape.

**The off-level arrows cannot be decided by their own id, and that is a real constraint
rather than a wrinkle.** `iqm_mapspot_above` is *one* cell shared by a gold storyline
task, a white secondary, a red alert and the coloured task kinds, so "does this arrow keep
its tint" is a question about the SPOT. `restyle_s2` walks `S2_TAGS` in tag order, so a
spot's own `<texture>` is always settled before its swaps and they inherit its answer
(`kept`, keyed by parent element, the same trick `grown` uses); a spot with no texture of
its own gets the default. The harness asserts both directions on the same id, which is the
only way to prove the decision is per-spot.

**The frame also stops carrying the verb, and one attempt to give it back was wrong.** In
the ring style the frame is a verb: a ring means someone is standing here, a reticle means
go and find this, a bare glyph means hand this to a named person. Here every marker's own
frame is a whole diamond (`DIA_GAP = 0`), as S2 draws it.

*Every* marker's: the off-level arrows (`abovebare` / `belowbare`) were exempt from
that in the first build of this style, and it was simply a miss. They are bare in the ring style because
the frame is the verb there and a hand-in that goes up a floor must not come back
claiming to be a badge — but with no verb to protect, a bare glyph on this map has
nothing to mean and reads as a marker that lost its diamond, which is how it was
spotted (minimap, one arrow with no frame among seven diamonds). Framing them makes
them identical art to the ringed `above` / `below` pair in the s2 atlas. That is the
same collapse as a medic and a trader differing by glyph alone, and the cells stay
separate because the two atlases have to match origin for origin.

Cutting the task class's diamonds at their points (0.32) was tried, to get that
distinction back, and backed out. The arithmetic is what makes it look reasonable and what
makes it fail: the cut removes `g/d` of *every* edge, so 0.32 leaves each arm at 68% of its
edge — and with the keyline wrapping each arm's new ends, a bounty stopped reading as a
diamond with nicks in it and started reading as four separate bars around a glyph. Judge a
cut by the fraction of the *edge* it eats, not by how far into the cell it reaches.

What that attempt was really after — a hollow frame has to be visible over a badge's own
frame — is answered by SIZE instead, below (`S2_SPOT_SCALE_BY`). Brackets were the other
candidate and are worse; the paragraph after next says why.

**The squad dots keep their faction colours in both styles**, for the strongest version of
the same rule. Fifty spot elements carry
faction, relation and moving/static in their own `r`/`g`/`b` over one white disk; there the
colour *is* the information, so white would delete it rather than restyle it. Their id is
still renamed, which keeps the two atlases interchangeable.

**So does the level changer, and for a different reason.** It is not a marker in the sense
the rest of the table is — it is a fixture, the arch that says the map ends here — and it
is the same eight-heading arch in *both* styles, because a diamond would have said "go
here" about a thing that is simply there. Whitening a mark whose shape did not change would
have made a fixture harder to find without making it look any more like S2. It keeps its
green, its 19×19 rect and its art; only the atlas it reads from changes.

**The spots are drawn 19% larger in this style, and the number is silhouette parity.** A
diamond of half-diagonal `d` encloses `2d²` where a circle of radius `r` encloses `πr²`, so
the two match at `d = r·√(π/2) = 1.2533·r`. At `DIA_R` 60/128 against the badge ring's outer
0.4455 that is k = 1.19, and the mean distance from centre to outline — averaged over all
angles rather than taken at the extremes — agrees to within 1% at the same number. The
steps the file actually uses are 19 → 23 and 14 → 17 units, `grow_spot` writing integers,
so the applied scale is 1.211.

**This shipped at 1.12 first and read small, and the reason is worth keeping because the
original reasoning was careful and measured the wrong quantity.** It counted *ink* — frame,
keyline and glyph over both built atlases — found the diamond at 90% of the ring style's,
put area parity at k = 1.05, and rounded up from there for the way a diamond's mass sits on
its axes. But ink is not what the eye sizes a mark by; the outline it *encloses* is.
Measured on the shipped pair, at 21 units against 19:

| from centre to the outline | ring | s2 @ 1.12 | | s2 @ 1.19 | |
|---|---|---|---|---|---|
| at the four points | 8.46 | 9.84 | +16.3% | 10.78 | +27.4% |
| at the diagonals | 8.46 | 6.96 | −17.8% | 7.62 | −9.9% |
| mean over all angles | 8.46 | 7.81 | **−7.7%** | 8.56 | **+1.1%** |
| enclosed area (units²) | 225.1 | 193.8 | **−13.9%** | 232.5 | **+3.3%** |

Only the four tips reached further than the ring badge; everywhere else the diamond sat
inside it. A mark that is wider than its neighbour at four angles and narrower at every
other one reads as the smaller of the two, and it came back from play as exactly that.
Integer rounding had quietly taken a slice off as well — `19 × 1.12 = 21.28 → 21`, an
effective 1.105 rather than 1.12.

The correction is on the **spot**, not in the art, because the art has nowhere to go — the
diamond's points are already at the cell edge, and the keyline needs the last 4 px. Marks
whose art did not change (`S2_SAME_ART`) do not grow: resizing the engine's own squad dot
is not something a restyle should be doing, and it has no diamond problem to fix.

**Growing a spot moves its selection frame, and that has to be recomputed rather than
left.** `static_border` is a top-left child (`waNone`) of a centre-aligned spot, so
centring it means `x = -(border - icon)/2` — which is exactly what the `-5` in the `SPOTS`
entries *is*, for a 29-unit border on a 19-unit spot. Grow the icon to 23 and leave `-5`
alone and the frame sits a unit up and left of the marker it is meant to be around, which
is what it looks like on screen. `grow_spot` derives the offset from the geometry and grows
the border by the same *number of units* the icon grew, so the gap between the two shapes
is the one the ring style was tuned to. Scaling the border proportionally was tried first
and opens that gap ~30%: not because 1.19 is wrong, but because this style's selection
diamond sits at 0.484 of its cell where the ring style's arcs sit at 0.455, and multiplying
an already-wider gap compounds the two.

**The hollow frame is a whole diamond drawn bigger than a badge, and the distinction is
SIZE — deliberately not shape.** Its job is to ring a mark somebody *else* drew — a task
whose target already carries a spot (a stash, a service NPC, a level changer) and Personal
Adjustable Waypoint's pin. The ring style got away with a reticle at the same 19-unit
footprint because the two shapes differed: a thick broken ring at 8.64 units over a thin
closed badge ring at 8.46. Here both are diamonds, so at equal size the frame lands on the
badge's own outline and disappears. `S2_SPOT_SCALE_BY = 1.58` puts it at 14.1 units against
the badge's 10.8 — 3.3 units of clear space, about the air the ring reticle had. Both spots
are `alignment="c"` on the same object, so they are concentric for free, and S2's own art
nests diamonds this way. The override **tracks** `S2_SPOT_SCALE`, because what is tuned is
that 3.3 units of air and not the multiplier: when the badge went 21 → 23 this went 28 → 30
with it, and left at 1.45 the gap would have closed to 2.3 and put the frame back on the
outline it exists to clear.

**Brackets were tried for it and are wrong, for a reason worth keeping written down: in
this mod brackets already mean one thing.** They are the `static_border` the engine shows
on the task you are tracking (`show_static_border`, driven from `CMapLocation` against
`ActiveTask`), so a spot whose *own* art is brackets claims to be selected every time it
is drawn. Reported on the first play-test of the style — a waypoint on a sleep icon
and an unrelated bounty both wearing brackets, reading as two active tasks at once. The
mechanism is still in `build.py` (`S2_BRACKET_FRAME`) and must stay empty for every spot
cell; the `select` cell is the only thing entitled to that shape. **A new frame shape here
needs a free *meaning*, not just a free shape.**

The one thing to expect and not chase: the pin arrives with its **base** type and is
re-classified within 750 ms (`SYNC_MS` in `iqm_taskspot`), so a waypoint dropped on a
service icon shows the plain marker for up to three quarters of a second and then becomes
the bracket frame. That is the sync pass doing what it is documented to do, not a flicker
to fix — what made it look like a bug was the state it used to settle into.

**A pin covers what it points at, and the rule that stopped it doing so is gone** (R2.62).
Until then, `iqm_scan.task_kind` asked the engine what else was drawn on a task's target and
answered `open` — or `waypoint`, for PAW's pin — when anything was, so the task swapped onto
a hollow reticle and ringed that mark instead of covering it. Removed by request: vanilla
behaviour is that a pin sits on top of what it marks, and the player dropping a waypoint on
a bed already knows the bed is there.

Removed with it: the two location types (`iqm_task_open`, `iqm_task_waypoint`), the
`target_covered` query and its `NOT_COVER` exclusion list, the `wp_target` / `open_kind`
caches and `KIND_RECHECK`, the `nta_stash_task_target_functor` entry in `TARGET_KIND`, and
the two S2 rules that existed only to size those marks (`S2_SPOT_SCALE_BY` and
`S2_NO_GROW`) — so every restyled spot now takes the one scale.

**What it costs, on the record rather than rediscovered.** The DRX quest-item family — 21
sections — points straight at a stash the player has already found, and its pin now sits on
top of the stash icon. That was the case that justified generalising the rule beyond PAW's
waypoint in the first place. The NTA stash family is the same, by a different route: its
mark sits on a *sibling* object no positional query can reach, which is why it had to be
named in `TARGET_KIND` rather than detected.

**What survives, and why the removal is safe.** Every kind that is about the *job* —
registry bounty, declared functor, mutant — answered before coverage ever ran. Dropping the
last question in the chain therefore changes nothing about any of them; a bounty standing on
a service badge was already a bounty. `iqm_beacon` also keeps `BEACON_ICON.waypoint`: that
is `offer_waypoint`'s glyph, a separate feature with its own switch that was never reached
through `task_kind`, so the through-wall mark for your own pin is unaffected.

**The frame's stroke is 1.5 units where the ring badge's is 1.8, and matching the ring on
paper was the mistake.** Reported as "the diamond is slightly too thick", and two things
push that way at once: the spot is drawn larger in this style, which scales the stroke with
it, and a diamond's perimeter is `4√2·r` against a circle's `2π·r` — 10% more line at the
same extent. `DIA_W` is therefore **derived from `S2_SPOT_SCALE` rather than tuned beside
it**: it is a fraction of the cell and the cell is drawn at that scale, so the two multiply
and what has to stay fixed is the product. `1.8/1.12 = 1.607` gave 1.6 while the spot was
21 units; at 23 the same drawn line is `1.6 × 21/23 = 1.46`, and 1.5 is that rounded onto
`RING_W`'s own numerator — 2.55 px at 1080p against the 2.48 the old pairing drew. Move one
without the other and the frame arrives back at the equivalent of 1.75/21, most of the way
to the weight that was reported, as a side effect of a *size* change nobody would think to
re-check the stroke for. It is also close to a floor — `OUTLINE`'s keyline is a fixed
dilation in atlas px, so thinning the stroke raises the keyline's share of the mark, and
below ~1.4 the frame reads as a dark line with a white core at minimap size.

**Glyphs are sized by their diagonal extent, not their bounding box** — the one thing that
had to be worked out rather than ported. A diamond is the line `|x| + |y| = d`, so at equal
bounding box a cross clears the frame by 14 px while an envelope goes straight through it
(`l1_radius` / `fit_diamond` in `tools/map-icons/build.py`). Sized that way the diamond's
glyphs come out *larger* than the ring's: 40 px of L1 radius against 32 px of box
half-extent.

**The trader is the one glyph that differs between the styles.** The ring badge keeps
Tabler's `briefcase-2`; the diamond draws game-icons.net's `swap-bag`. Not a
reconsideration of R2.46, which sent the trader *back* to Tabler because the game-icons
briefcase's latch and case seams closed up in half a cell — the diamond hands its glyph
~25% more linear size, and a bag with a strap is a coarser silhouette than a briefcase with
hardware. `S2_GLYPH_SRC` is where a style disagrees with `GLYPH_SRC`.

**Needs a restart, for `map_icons`' reason exactly** — the value is read when the engine
parses `map_spots.xml`, which happens once per process. Same read path, same
default-to-off-at-every-failure, same label.

### `map_task_kinds`

**In the S2 style, four things are held out of the whitening and the frame follows its
mark.** The three task-kind tints and the squad disks are kept by icon id, but storyline
gold cannot be: a storyline task and a secondary task are the same cell (`iqm_mapspot_task`)
and differ only in `r`/`g`/`b`, so keying on the id would keep both or whiten both. It is
keyed on the *tint* instead (`S2_KEEP_RGB`), which is also what carries it through the five
places it has to survive — map pin, minimap pin, that pin's off-level arrows, the new-task
pulse, and the legend swatch, which lives under `<image>` in another file and has no spot
name to match on at all. The selection frame's colour reverses the first cut: it was white
on every pin on the reasoning that a selection is a *state* rather than a kind, and on
screen the frame is the largest and brightest shape in the mark, so a white diamond around a
red bounty read as a white marker with something red inside it. Selection is carried by the
frame's presence and its blink; it does not need the colour channel too. That decision is
made in `restyle_s2` rather than in a keep-list, because a border's own id says nothing
about it — `iqm_mapspot_select` is one cell under every kind of pin — so the pass walks from
the border up to the spot and copies what the mark resolved to.

**A skull on a mutant hunt, a red reticle on a bounty**, while the objective is still
outstanding. The problem it solves is that every task pin on the PDA looks the same, so
deciding which of six to walk to means opening each one.

**Neither test is a name list**, and that is the whole design. Bounties come from
`axr_task_manager.bounties_by_id` -- a registry `xr_effects.setup_bounty_task` writes and
the save carries -- and mutants from the target squad's community against
`is_squad_monster`, which is the same test `tasks_assault.script:174` uses to pick its own
news icon. A `target_functor` allowlist was rejected for the reason it was rejected in
[`beacon_handin`](#beacon_handin): GAMMA mods ship their own functors, an unknown name has
to default to "not a bounty", and the list then fails silently on exactly the modded tasks
it exists to catch. Reading state the game maintains for itself survives task scripts this
mod has never heard of.

**The target is often not the squad**, which R2.48 missed and "Destroy the Mutant Lair"
exposed: `assault_task_target_functor` returns `var.smart_id`, the smart terrain the
mutants sit on (`tasks_assault.script:240`), and a smart has no `player_id`, so every lair
task stayed on the plain reticle. The squad it actually tracks is in the task's own stored
var, keyed by task id, so the fallback reads that — still not a name list, since any task
built on the assault machinery is covered whoever wrote it. The kind cache is
**asymmetric** as a direct consequence: a positive answer is sticky (a section's kind is a
property of the section), a negative is re-tested every 5 s, because a nil there is
routinely just *early* — `setup_assault_task` assigns `squad_id` a frame later, and the
status functor nils it every three seconds while it rescans (`:313-316`). Caching the nil
would freeze a lair on the plain reticle for ever; not caching would flicker it.

**New location types, because a spot has no runtime tint.** Colour is an `r`/`g`/`b`
attribute on the spot's `<texture>`, read once at parse; every task sharing a type shares
its appearance. So "this pin is red" can only be said by pointing the task at a different
type -- hence `iqm_task_mutant` / `iqm_task_bounty` in `ui/iqm_map_spots.xml`. Only the
mutant needed art at first; a bounty was the reticle it already had, in red. Both carry
their own glyph now (a skull and two rifle rounds), and for a reason worth keeping in view
here rather than only in the art files: the two tints sit on the red-green axis, so colour
alone was never telling those players the two kinds apart.

**No monkey-patching.** `CGameTask::ChangeMapLocation` is remove-then-recreate and
re-entrant (`GameTask.cpp:126-135`), and the three accessors are bound to Lua
(`GameTask_script.cpp:41-59`), so `iqm_taskspot` is a poller that compares wanted against
actual. The alternative was wrapping `CGeneralTask:check_task`, which every other task mod
also wants to wrap. Vanilla re-applies the task's own type on a target change, so ours is
clobbered for up to one pass -- not worth chasing, because the target change that matters
is the one at hand-in, where vanilla's answer and ours already agree.

**THE HAZARD, and why it is closed rather than documented.** The type string is serialised
(`SLocationKey::save`, `map_manager.cpp:62`) and rebuilt through `CMapLocation`'s
constructor on load, which `R_ASSERT`s on a type `map_spots.xml` does not declare
(`map_location.cpp:105`) -- an engine fatal no `pcall` catches. Left alone that means a
save taken while a bounty is flagged red would not load with this mod removed, which is
where R2.48 left it.

**It is not left alone.** `iqm_taskspot.revert_for_save` puts every flagged task back on
its own type inside the engine's own pre-save callback, so **no save ever contains one of
these names** and the mod can be deleted at any moment. The ordering is checkable rather
than hopeful: the engine calls `CALifeStorageManager_before_save` at
`alife_storage_manager.cpp:75` and serialises the registry at `registry().save(stream)` on
line 89 — fourteen lines later, same function, same frame. It covers both carriers of the
string, `SLocationKey` and `CGameTask::m_map_location`, since both are downstream of that
call. The pins are plain for one frame during an autosave and come straight back.

Three guards back it up, all asserted in `tools/taskspot-harness`: the names are never
handed out unless the splice actually **put them in the DOM** (verified by querying, not by
assuming the splice ran — those come apart on a stale deployed XML); the feature refuses to
run at all without marshal, since that is what fires the pre-save callback; and switching
the option off *reverts* every task still wearing one instead of merely ceasing to apply
new ones. That last one is also the manual escape hatch, and it is simpler than it looks:
untick, save, remove — no restart, because the restart belongs to
[`map_icons`](#map_icons) and has nothing to do with save safety.

Personal Adjustable Waypoint carries the same hazard for its own ~100 types and does not
close it, so this is stricter than the pack's normal rather than looser.

**Rides `map_icons`**, in the menu and again in code. Hiding a row does not change its
stored value, so the menu gate alone would leave an acid-green skull among vanilla icons.

**Both halves of the mod use the kind, and they do not overlap.** `iqm_scan.task_kind`
goes nil once the objective is done, and the marker's [`beacon_handin`](#beacon_handin)
gate hides the marker *until* it is. So at default settings these glyphs are a PDA-map
feature; with the hand-in gate off they also dress the world marker, which is exactly when
knowing whether the objective is a mutant or a man is worth something.

---

### `map_spot_names`

**The tooltip on a PDA pin used to say only what the NPC does.** In a hub that is four
pins saying "Trader" and no way to tell Sidorovich from the merc who also sells, without
walking to each. Hovering a mark is the one moment the map has room to answer "who", so
it answers. The important-character pin gains most: "Important Character" is the least
informative thing the map says about anybody.

**The hint is the only per-NPC state a map spot has.** Art, tint and size are attributes of
the location TYPE in `map_spots.xml`, shared by every spot wearing it, so a name could
never be drawn on the pin itself -- and the type is already spoken for
([`map_task_kinds`](#map_task_kinds) moves tasks between types for exactly that reason).
That is not a limitation worked around here; it is why the feature is a string and not art.

**It rewrites rather than re-decides.** `stalker_generic.reset_show_spot` is wrapped, its
original called first and unchanged, and only then is the spot it chose looked up and its
hint replaced. Every rule about which NPCs carry a service pin -- the `level_spot`
condlist, `show_spot`, the goodwill test -- stays the game's. The alternative, re-deriving
the decision from the NPC's logic, would be a second copy of a table that already exists
and would drift from it silently.

**Off writes the string ID back, not English.** A hint is stored raw and translated at draw
time (`CStringTable::translate`, `string_table.cpp:226-234`), so restoring
`st_ui_pda_legend_trader` gives the exact vanilla tooltip in every language while restoring
"Trader" would give an English one to a Russian player. The same property is what makes a
composed literal safe to store in the first place: an id the table does not hold comes back
unchanged.

**Live in both directions**, unlike [`map_icons`](#map_icons) above, and not gated on it.
The pins already on the map are re-stamped or reverted when the option changes, because the
alternative -- waiting for each NPC's logic to reset -- means "nothing happens in the hub
you are standing in", which reads as a broken switch rather than a slow one. Service NPCs
are therefore remembered even while the option is off; that table is what the ON direction
sweeps.

**Every pin the game puts on a PERSON, which is seven of vanilla's eight.** The four trade
services, the fast-travel guide and BOTH important-character spots -- `special` (faction and
story) and `quest_npc`, which draw the same pin from two different legend strings that
differ only in capitalisation. Transcribing them separately rather than folding them
together is deliberate: collapsing the two would quietly change what one of the pins says,
and nobody would see it on screen.

The eighth, the companion pin, is left alone. That is not the same kind of omission -- a
companion is in the player's own squad and already carded by this mod, so their name is the
one thing about that mark nobody is in any doubt about. Adding it is one row if that ever
stops being true.

**The rows are in vanilla's own if/elseif order**, not grouped by kind. An NPC can only
carry one of these from `reset_show_spot`, but another mod can add a second, and matching
the game's order means "first row wins" reaches the verdict the game would rather than
being a second opinion that has to be kept in step with one.

**The tooltip agrees with the ICON, which sometimes means it is coarser than the card.**
Vanilla gives a technician whose logic only says `level_spot = trader` the plain trader pin;
the nameplates refine that from the trade catalog (`iqm_scan.refine_trader`), so a card can
read TECHNICIAN over a pin whose tooltip says "Trader". A tooltip explains the mark under
the cursor, and one disagreeing with the glyph it is attached to would be worse than one
agreeing with a coarse glyph.

---

### `map_hide_companions`

**A companion draws two marks and only one of them says anything.** The mod already puts
a companion bust on the map and, optionally, a waypoint marker through the wall
([`beacon_party`](#beacon_party)) — and underneath both, the simulation keeps drawing the
ordinary faction squad dot, because a companion's squad is still a squad. It trails your
own actor arrow by a step, on the map and the minimap, answering a question nobody asked:
where is the person walking beside you.

**It is the only row in this section that changes who gets a mark.** Everything else the
mod does to the PDA map is a retexture ([`map_icons`](#map_icons)), a type swap
([`map_task_kinds`](#map_task_kinds)) or a tooltip rewrite
([`map_spot_names`](#map_spot_names)) — three ways of changing what an existing mark looks
like or says. None of them help here. The dot is not drawn wrong; it is drawn redundantly,
and the only fix for redundant is absent. That is why it is a switch rather than a colour.

**It is not "hide friendly squads".** Every other squad in the Zone keeps its dot, enemy
and friendly alike, and the PDA tier still decides which ones you see at all. The narrow
scope is the argument: a friendly patrol's dot is information you would otherwise not have,
and a companion's is information you are looking straight at.

**The predicate is the game's own registry**, `axr_companions.companion_squads` — the same
table `sim_squad_scripted` tests when it decides whether a squad may teleport to you. It
answers for G_FLAT's Individually Recruitable Companions too, which clones a stalker out of
his squad into the player's companion squad rather than inventing a second notion of party.
Tested for `nil` and not for truth, because `load_state` writes `false` for every saved
companion until its squad object is re-attached; a truthiness test would put the dots back
for the first seconds after every save load, which is the hardest kind of bug to see.

**The hook is the one the game uses on itself.** `sim_squad_scripted.show` is wrapped
through the class table on the script namespace — which is exactly the handle base
Anomaly's own `sim_squad_warfare.script:341` uses to replace that method wholesale. So the
method that is live is not the one in the file named after the class: script bodies run in
filename order, `sim_squad_warfare` sorts after `sim_squad_scripted`, and the warfare copy
wins. The two disagree about which object id the spot is placed on (`self.id` against the
commander), so the cleanup asks the engine which one actually carries it rather than
betting on a load order that could change.

**The original is not called for a companion**, unlike `map_spot_names`' wrapper, which
always calls through. There the original's side effects were load-bearing for NPCs the
wrapper then left alone. Here the original's whole job is the spot being refused, and
letting it place one so it could be removed again would add and drop a map location on
every squad update, for every companion, forever.

**Live in both directions.** The registry is swept when the option changes, rather than
waiting for each squad's next simulation tick. The wait would be under a second for an
online companion, but a switch that visibly lags reads as a broken switch, and the sweep is
a handful of table lookups on a table that holds single digits.

---

### `noise`

Interference: during an emission and inside a psi zone the marks tear sideways in bands,
their dark copies retint and lean the other way, the range readout starts printing a wrong
digit, and at the worst of it the whole overlay drops out a beat at a time. The signals and
the envelope behind it are `iqm_noise`; how it becomes pixels is `iqm_cards`.

**Why the feature exists at all**, since it is the only thing in this mod that makes the
overlay objectively *worse* to read. Everything else here is an argument about legibility —
where a card sits, how far a marker reaches, what colour survives against sky. This one is
an argument about what the overlay *is*. A mark that can be interfered with is a mark that
is being rendered by something inside the fiction; a mark that is always perfect is a UI
convention drawn on top of the game. The imperfection is the characterisation, which is why
it is not a toggle for a cosmetic extra but the default behaviour.

**On by default**, and that follows from the above: a mod whose whole case is that the
overlay is a rendered thing in the world should behave that way out of the box. It is also
the safe default, because the tier that can actually take a mark away is a separate switch
and that one is off — see [`noise_giveup`](#noise_giveup).

**On the General page** because it is not any one feature's. It reaches the nameplates, the
waypoint markers and the ground route together, which is what that page is for. (The
minimap trail is deliberately excluded — it is drawn in its own widget space, and the
argument for interference is that the overlay is a thing in the *world*. A map is a map.)

**Its two shaping rows are NOT gated on this switch**, so `noise_amt` and `noise_giveup` are
visible whether interference is on or off. That is the rule now, not an oversight here — see
[Preconditions](#preconditions) for why a row that a setting reveals does not appear until
the next time the menu is opened. These rows were written with `pre = "noise_on"` on the
`dim_hold` pattern and lost it before they shipped. The feature gates on its own switch in
code regardless, in `iqm_noise.apply_config`, which is where it was always load-bearing.

**THE TIERS ARE CONSTANTS, NOT OPTIONS**, and this is the decision most likely to be
questioned. Four thresholds stage the effects — tear at 0.15, the chromatic fringe at 0.40,
dropout at 0.70, giving up at 0.90 — and each keeps the ones below it.

The alternative, which was considered first, is to scale every effect together with
pressure. That is simpler and it is wrong: scaled together, the marks are merely *less
steady* than they were at every level of pressure, and the result reads as a wobbly UI
rather than as degradation. Staged, each threshold adds a new KIND of failure, and the
sequence — noisy, then noisy and mistinted, then intermittent, then gone — is the thing
being depicted. So the ORDER is the design, in the same way the combat dim's rates are
fixed and only its depth and duration are settings. `noise_amt` moves the amplitudes and
deliberately cannot move the thresholds; a setting that could would let a player reorder
the tiers into something that no longer reads as anything.

**Following the game's own curve, not a private one.** The emission's pressure comes from
knots on `surge_manager`'s stage timeline, which arrives on the event bus as
`_EVENT.surge.time`. Those knots are that script's own boundaries — impact at 47, the quake
ramp to 106, the waves at 120 and 168, the fade from 200. An overlay that peaks at the waves
is in step with the weather, the rumble and the camera shake; one on a curve of its own
would be a second unrelated drama running alongside them.

**Cover damps it and does not silence it** (75%), **and that number was 30% until play
corrected it** (R2.59b). The mistake was treating cover as a choice the player makes to opt
out of the weather, which made hard damping look like shelter working. It is not a choice:
*outside during an emission you die.* Sheltering is the only survivable state, so the
uncovered branch is essentially unreachable in ordinary play — and the feature had been tuned
around a state players never occupy.

Measured in game at the 100 Rads bar during a live emission: uncovered pressure 0.77, damped
to 0.23. At the emission's *peak*, sheltered, that is 1.0 × 0.3 = 0.30 — above the tear
threshold and below the chroma tier. So an entire emission spent correctly, indoors, was a
one-pixel wobble and nothing else: no fringe, no corruption, ever. The feature's showcase
event was the one time it was suppressed to nothing.

So the **sheltered case is the normal case** and gets the real thing — a peak of 0.75 reaches
tear, chroma and dropout — while being caught outside is the rare extreme and the only route
to the give-up tier. That is the right place for it: the overlay failing completely while the
Zone kills you is not a usability problem. Still not 1.0, because the gap between 0.75 and
1.0 is the difference between "the marks are struggling" and "the marks are gone", and
shelter should mean something.

This is the clearest case in the file of a number that could only be wrong in play. Nothing
about 0.3 is wrong on paper; it is wrong because of a game mechanic that sits outside the
code entirely.

**The psi-hostile North is a floor and nothing more** (12%). `G.A.M.M.A. Psy Fields in the
North` flags a whole level, and it is tempting to hang something heavy off it. It is a DEATH
TIMER, not an ambience — it subtracts 999 psy health twenty-three seconds after it fires —
so anything heavier would be an effect the player is never alive long enough to watch.

**A telepathic hit is a spike, not a state.** `actor_on_before_hit` filtered to type 4 is
the widest net available: every psi source in the game arrives through it — an anomaly
field, a controller's tube, a burer, the Brain Scorcher, a storm vortex. It kicks the
envelope and the release curve carries it down, so the overlay takes a knock and recovers.
Note this is the exact complement of the combat dim's `SUP.HIT`, which lists the five ways a
*fight* hurts you and excludes telepatic as "the environment, not combat". This is the
feature that cares about precisely what that one throws away.

**Sources are combined with MAX, not a sum.** Max means "whatever is worst right now", it
cannot compound past 1, and it needs no normalising. A sum would let a hostile level and a
distant field add up to a reading neither of them justifies, and would then need a clamp
that hides exactly that.

### `noise_amt`

How hard it pushes, as a percent, 10–200.

**100 rather than something cautious**, and this is the R2.26 lesson that `dim_level`
restates: the amplitudes are already sized against the engine's whole-pixel flooring, which
`ctr_fade`'s `CTR_Q` note records — every widget's position is floored to a screen pixel
independently, so a displacement worth less than a pixel lands on some widgets and not
others and reads as *shimmer* rather than tear. Peak amplitude is 7 UI units, about 10 px at
1080p. A default of 60 would put the tear back under the pixel it has to clear to be legible
at all, so a timid default here does not produce a subtle effect — it produces a broken one.

**Scales amplitudes, not thresholds** — see the tier argument under [`noise`](#noise). **It
shipped doing the opposite for one revision** (R2.59, fixed in R2.59a), and the shape of that
mistake is worth keeping. The envelope eased toward `target * amt`, which scaled the
*pressure* — and every tier threshold is a comparison against pressure, so the slider moved
all four of them.

Both ends were broken and the low end was worse. At 10, no source could push pressure past
0.1 while the tear begins at 0.15, so **the bottom quarter of the slider turned the feature
off** rather than making it subtle. At 200, the emission's impact read as 0.90 and the
overlay gave up there instead of at the waves — the tier order destroyed by the one setting
that is documented as unable to touch it.

It was found by reading the live state in game, not by the harness, which had a check named
"noise_amt scales the pressure" asserting only that 10 and 200 produced *different* pressure.
That is true of the bug. The check was measuring the wrong axis, and a green test that
measures the wrong axis is worse than no test, because it is evidence. The replacement
asserts pressure is **identical** across settings and walks the emission's clock to prove
each tier is entered at the same second at 100 and at 200; re-introducing the bug fails six
of them.

**The alpha side takes it as a depth, not a floor.** `1 - (1 - floor) * amt`, clamped at 1 on
the way up, so a 10% player barely dips where a 100% one reaches the floor, and 200% cannot
drive the multiplier negative into `GetARGB`. Without this the slider would move the geometry
and leave the overlay blinking fully out at every setting, which is not what strength means.

**Reaches 200** because the amplitudes are tuned for "an emission is happening", and some
players will want the Zone to be louder than that. There is no correctness argument against
it — the marks stay on their own bands and the readout stays a readout.

### `noise_giveup`

At full pressure, let the overlay stop drawing altogether instead of fading to a floor.

**Off by default**, and this is the third time this project has had this argument and the
third time it has landed in the same place. `ctr_fade`: *a floor and not a hide, because the
default should be the behaviour that cannot flicker.* `dim_level`: 0 is reachable and is
deliberately not the default. The reason is the same each time and it is not timidity — **a
marker that is gone is indistinguishable from a marker the mod failed to draw.** The player
cannot tell an atmospheric effect from a bug in the one thing they are relying on to find
the objective, and the report that comes back is "the markers vanish sometimes", which is
the least debuggable sentence in the language.

Off, the tier fades to 15% instead. That says the same thing — the overlay has been beaten
— and cannot be mistaken for a fault.

**A separate switch rather than a value on a slider**, unlike `dim_level` where 0 is the
full hide. The difference is that `dim_level` 0 is the end of a continuum the player is
already dragging through; this is a categorical change in what the feature is allowed to do,
and it should require saying so.

**Dropout is whole-overlay, not per-mark**, at every tier. Marks blinking independently
reads as some of them being broken, where the whole set cutting out together reads as the
feed cutting out — which is what is being described. It also cannot hide one specific
objective while its neighbours show, which per-mark dropout can, and which would be
genuinely misleading rather than atmospheric.

---

## Nameplates (cards)

### `focus_mode`

The idea is Red Dead Redemption 2's: nameplates there follow your *gaze*, not your view
frustum — it names the person you are actually looking at, not everyone in front of you.
This mod cards up to eight at once and ranks them, so a focus filter was one more key on
a rank that already existed, and it is the real answer to "a busy hub is noisy" — an
answer that is not "turn the roles off".

**Off by default, and that is not timidity.** It is a different reading of what the
overlay is *for*. As shipped, a card is a standing annotation on a body: it is there
because that stalker has a job for you, and it stays there while you look elsewhere.
With focus on, a card is an *answer to where you point*. Both are coherent designs and
only one can be the default; the shipped one is the one the mod was built around, and
the README's promise that "the world stays clean until you ask" is satisfied by the
distance fade and the LOS cull already.

**Why the modes are tiers and not a checklist.** The obvious menu is a checkbox per
role — seven of them, on the page that already has seven role checkboxes above. But
the question a player is answering is not "which roles", it is *how much of the overlay
do I want to be conditional*, which has a natural order: the ambient noun cards first
(they are the ones that make a hub busy), then the state cards for people you happen to
walk past, then the objective. So the mode is that order, cut in three, and it is
implemented as a `ROLE_PRIO` threshold rather than a role list — the same table the slot
rank sorts by, so the tiers cannot drift from the precedence the cards already have.

**Why it is not applied to the waypoint markers.** A marker exists precisely for the
NPC you *cannot* see — behind a wall, off screen, beyond card range. Gating it on
looking at them would leave it drawing only in the situations it was built not to be
needed in. The interaction is better than neutral: because focus never touches `f.a`,
an unfocused card still counts as "up" for the card/marker handover and goes on
suppressing its own marker. Looking away gives you *nothing*, which is the RDR2
reading, rather than a beacon popping in to replace the card that just faded.

**Why it does not touch `f.a`** is the implementation note that matters most, and it is
stated at the ease site in `iqm_core.script` as well: `f.a` is control flow. `f.a < 96`
releases the marker and `f.a < 2` resets the entrance rise and the chirp — so the
one-line version of this feature (multiply the eased alpha) summons a through-wall
marker for every NPC you look away from and re-fires the PDA chirp every time you sweep
back across them. Focus rides the draw-time multiply the combat dim already established.

**Why the ring is measured in screen space** rather than as an angle off `device().cam_dir`,
when both are available and the two order identically (screen radius is `f·tan θ`, which
is monotone in θ): it costs no engine call at all — the anchor is already projected for
the draw — and it follows the FOV instead of fighting it. Aiming down sights magnifies
the world into the same ring, so the cone it describes in world terms tightens exactly as
much as the view narrowed, which is what someone scoping a distant figure means by "the
one I am looking at".

**The other crosshair feature, and why they are opposites.** [`beacon_ctr`](#beacon_ctr)
fades a *marker* as it approaches the crosshair — Cyberpunk's move, get out of the way of
what the player is looking at. This *reveals a card* there. That is not a contradiction,
it is the same premise read against two different objects: a marker is furniture over the
thing you are looking at, and a card is a statement about it. Running both, they
cooperate — look at a stalker and the nameplate comes up while a badge sitting over them
stands aside.

They are deliberately **not** refactored onto shared code. The overlap is two lines
(divide the X delta, take the magnitude), they live in different modules on different
subjects, and the shapes differ for reasons of their own: `ctr_fade` smoothsteps in space
and quantises its size multiplier because it is a static function of position with no
temporal ease behind it, whereas focus eases in time (`f.fa`, on the fade's own 90 ms
constant) and so wants a plain linear ramp in space, matching `alpha_for_dist`. Coupling
two modules to share a `sqrt` would trade a real seam for an imaginary saving.

What they DO share is the **unit**, and that is worth the alignment: `focus_radius` is a
percentage of *half the screen height*, exactly as `beacon_ctr` is, so 50 on one page is
the same circle as 50 on the other. They are the only two crosshair-radius sliders in the
menu and they are read against the same crosshair; measuring them against different
denominators would be a papercut with no upside. Height and never width, because the
1024x768 virtual UI is stretched to the real window — the X delta is divided by `UI_KX`
for the same reason, or the ring draws as an ellipse, wide and squat on 16:9 and worse on
21:9.

`focus_floor` defaults to 0 (unfocused cards are simply gone), which is the strict
reading. Above 0 the feature becomes "quieten the rest" rather than "hide the rest".
That is a genuinely different thing to want, it costs one multiply, and shipping only
the strict version would have left the softer one unreachable.

### Colour channel step

Applies to `col_r` / `col_g` / `col_b` here, and to the colour channels on both route
pages.

EVERY COLOUR CHANNEL IS step 1 (R2.43), here and on both route pages. They were
step 5, which is not a coarse control -- it is a control that cannot reach most
colours, INCLUDING THE MOD'S OWN DEFAULTS. Not one channel of the accent
(224/196/122) or of the route (176/196/124) is a multiple of five, so a player who
nudged a slider could not get back to the value the mod shipped with except by
resetting the whole page. A channel is 8 bits because 8 bits is the resolution the
thing has; quantising the slider to a fifth of it buys nothing and silently removes
four values in five.

The ALPHA tracks beside them are still step 5, deliberately: they are opacity, where
2% is a real increment and the range is meaningfully continuous. Different quantity,
different answer -- which is why they sit at a different step in the same group.

---

## Waypoint markers

### Which roles get a marker

Only THREE things get a marker (R2.29): the hand-in target, which is the one you are
actively looking for, and the two kinds of NPC you go somewhere specific to USE -- guides
and the service trades. **All three are on by default**, guides and the trades having been
opted into until now: the test a marker has to pass is "you have a reason to want to know
where that body is and geometry keeps taking it away from you", and a trader you are walking
to across a hub passes it exactly as a turn-in does. What kept them off was the worry that a
hub would fill with badges, and `beacon_dist` (60 m) is what actually answers that -- the
switches were answering it a second time. The state roles
(needs-a-guide / recruitable / for hire) used to be markable too and no longer are:
they are people you happen to walk past, not destinations, and marking them turned
the screen into an objective list.

**R2.57 added a fourth thing and it is not a destination**, so the argument above has to
be restated rather than quietly widened. Your own companions can be marked. A companion
is not somewhere you are going; they are usually behind you. What they share with the
three above is the thing the rule was really about -- you have a specific reason to want
to know where that body is, and geometry keeps taking it away from you. The state roles
fail that test (you have no reason to care where a recruitable stalker went once you have
walked past him); a companion passes it hardest of anything on the list, because it is
your own asset and losing it behind a building is the exact failure the marker exists to
cover. It is off by default, it ranks behind every role so it can never cost another mark
a slot, and it is the only entry here that would be wrong to turn on for everyone.

**R2.60 put the hand-in target back on the list**, which reads like a reversal and is not
one. It was never off it — the sentence above still names it first — but between R2.46 and
R2.60 its marker came only from the task you had SELECTED, and an unselected hand-in was a
destination with nothing on it. See [`beacon_targets`](#beacon_targets) for why that turned
out to be worse than nothing rather than merely quieter.

ONE section for everything that isn't Advanced (R2.29). The page used to open with a
two-row "Hand-in" section and then a second captioned section for seven role
switches; with the state roles retired there are four rows in total, and two captions
over four rows is more furniture than page.

### `beacon_handin`

**A difficulty setting, not a tidiness one.** Once the selected task got a marker of its
own (R2.46) it followed `current_target` at every stage — and on a bounty that stage-0
target is a live stalker who is moving. An exact position through a wall is the part of
that task which *was* the task, so the marker was handing over the challenge. Raised as
"a beacon on a bounty task is pretty OP", and it is.

**Gated on the task's own `stage_complete`**, via `iqm_scan.target_is_talk_to`, rather
than on a list of task types. The task functors are already written around that key: the
bounty one (`tasks_bounty.script:228`) returns `task_giver_id` at stage 1 and the mark
itself at stage 0, and its sections declare `stage_complete = 1`. So one test the game
already ships separates "walk back to the barman" from "hunt someone", and the 207 fetch
and 79 assault tasks in base Anomaly have the same shape.

**A `target_functor` blocklist was considered and rejected.** It is more precise on
vanilla — 42 sections name `general_bounty_task` outright — but GAMMA's mods add their
own functors, so an unrecognised name would have to default to *allow*, which fails open
on exactly the newly-added OP cases. Rejecting a rule that fails open in the direction of
the bug it exists to prevent.

**It fails open in the other direction, knowingly.** A task declaring no `stage_complete`
counts as a hand-in and is marked. That is right for the storyline "go and speak to X"
tasks it mostly catches; the alternative — never mark an unknown task — would drop most of
the storyline. If a modded bounty omits the key it would be marked, and the fix for that
would be the hostile-target test (see below), not a blocklist.

**Considered and held back: "never mark a hostile".** A runtime check on the target's
community would catch any kill-step regardless of functor, including the storyline ones
with no `stage_complete`. It is mod-agnostic and cheap enough. Held back because it also
suppresses cases where an enemy position is legitimately already known — a briefed
defend-the-base assault target — and one gate is easier to reason about than two. Build it
if something visibly slips through.

**The ground route is deliberately NOT gated.** `active_task_target` RETURNS the stage
answer rather than applying it, because `route_target` shares that call. A path along the
ground is navigation; a badge through a wall is a reveal. During a bounty you get a line
toward the area and nothing on the body.

**Defaults ON, and the default is load-bearing.** The switch reads `C.beacon_handin ~=
false`, not a plain truth test: a player upgrading has no stored value, so `nil` has to
mean *gated*. Read the other way it would hand every existing user the OP behaviour
silently on upgrade. The waypoint harness asserts the `~= false` specifically.

### `beacon_waypoint`

...and on the waypoint the PLAYER placed (Personal Adjustable Waypoint). The one
marker here that is not about an NPC, and the one exempt from beacon_dist: the range
rule above is about not handing out NPC positions, and a waypoint has no position to
hand out that the player did not choose themselves. So it marks at any range, which
is the whole reason to place one.

### `beacon_party`

**Off by default, and it is the only switch on this page that would be wrong to default
on.** The other three mark things you are trying to reach. This one marks people who are
already with you, which for most players most of the time is a badge on the screen saying
something they already know. For the player who has lost a companion behind a warehouse it
is the most useful mark the mod draws. That split is what a default-off switch is for.

**It rides none of the card roles, because there is no companion card.** Every other role
marker is gated `(feature available) AND (the role's card is being detected) AND (the
marker switch)`, so a marker can never point at something the scan is not finding. A
companion is not something the scan finds -- `iqm_scan` looks for people you could act on,
and a companion is someone you already acted on -- so the gate has no middle term. Modelled
on `beacon_waypoint` instead: a standalone switch over its own source of truth, riding the
presence of `axr_companions` the way that one rides PAW's.

**The source is `axr_companions.list_actor_squad_by_id`**, which is the same party table
the game's own PDA reads, so the marked set can never disagree with your contacts list. The
id list is polled at 1 Hz and each position resolved live -- the split `waypoint_goal`
makes, for the same reason and more so: which bodies are in your party changes when you
recruit or dismiss one, and where they are standing changes every step they take, which is
the entire point of marking them.

**Prio 7: behind every role, not merely behind the objective.** The ambient band is 6, so a
companion is the last candidate offered a slot and cannot evict anything. That is stronger
than the rule R2.39 established (a turn-in must outrank a shop) and deliberately so: the
ambient marks answer *where do I go* and can be the only answer on screen, while a
companion can be recalled by whistling at it. A feature that ships off has no business
being able to reintroduce the flickering-marker fault, so it is ranked where it cannot.

**Range: `beacon_dist`, like the ambient roles.** The waypoint's and the selected task's
exemptions do not transfer. Those are positions the *player chose*; a companion is a body
the mod found, so "don't hand out positions you have not earned" applies to it the way it
applies to a trader -- even though, in this one case, you have in fact earned it. 60 m
covers the case the feature is for (the companion who went round the far side of a
building) without turning the party into a cross-map minimap.

**`beacon_party`, not `beacon_companions`.** `mark_companions` on the cards page means a
stalker you could *recruit* and have not, which is the disjoint set. Two keys a letter
apart meaning opposite things is a support question waiting to happen and, worse, a live
collision in code: `ROLE_PRIO.companion` is 3, so a marker keyed `companion` would silently
rank above every service. The whole feature says `party` in code -- option key, glyph key,
colour key -- and the slot harness asserts the two vocabularies stay apart.

**The glyph is the map's, which here means the VIP bust.** `modxml_n_iqm_map_icons` points
`ui_pda2_companion_location_spot` (and Warfare's `companion_tex`) at `iqm_mapspot_vip` in
40,172,66, on the stated ground that a companion must not look like two different things
depending on which path drew it. Mirroring the map means mirroring that, rather than
inventing a companion pictogram this mod would be the only view to draw. Note the green is
the *turn-in* green byte for byte -- that collision is the map's, by request, and copying
it is the mirror rule working rather than two colours drifting together.

**No name above it**, even with `beacon_name` on. The name cache lives on the tracked entry
and a companion is never tracked, so a caption would mean a second cache for text the
engine cannot scale with the marker anyway. Worth revisiting for a party big enough that
telling two apart matters.

### `beacon_targets`

**The bug it fixes is two views disagreeing about one man, not a missing marker.** Col
Petrenko in Rostok is a trader who is also the hand-in for an active task. His card read
`REPORT BACK` and his through-wall marker was the trader glyph — the same person, the same
frame, two different answers. Reported exactly that way.

**Neither half was wrong on its own, which is why it survived.** `desired` keeps one role
per NPC and the lowest `ROLE_PRIO` wins it, so `target` (1) beat `trader` (6) and the card
was right. The marker keeps its own answer (`want_marker`, R2.58) because a role that wins
the card does not always carry a marker, and a markerless winner used to take the marker
away from a role the same NPC also qualified for — which is how Petrenko once drew
*nothing* at all. So the marker fell to `trader`, correctly by its own rule. The thing that
was wrong sat under both of them: `target` had no marker to keep.

**It had none because of R2.46, and that decision is still right about what it was for.**
The marker had never asked which task was *selected*; it marked every in-progress turn-in
in range, so selecting a task on the PDA changed nothing on screen. Giving the selected
task a mark of its own (`task_goal` / `offer_task`) fixed that, and retiring the role's
marker was how "there is exactly one objective mark" got enforced. What it missed is that a
hand-in you have not selected is *still* a hand-in, and on a body that also sells things it
was now competing with a shop for the same pixels — and losing.

**So the rule is one mark per body, not one objective on screen** — and the body it applies
hardest to is the one you selected. The role's marker never fires there: `iqm_core`'s tracked
loop skips that id and `offer_task` keeps it. Every *other* pending hand-in is the role's,
inside `beacon_dist`. What the selected task keeps for itself is what only it can claim: prio
0, no range gate, and the kind dressing (skull, red reticle).

**R2.60 shipped that boundary the other way round and R2.60a inverted it.** The first version
let the role's marker win inside `beacon_dist` and the selected task's win outside it — one
mark either way, and both glyphs are `iqm_role_handin`, so the handover looked invisible. It
was not. Mode 2's faction tint and `beacon_name`'s caption are both *role*-marker business, so
the selected task's mark changed colour and grew a name as the player walked in past 60 m. And
the mark lost prio 0 on the way: re-offered from the role loop it ranked `ROLE_PRIO.target`,
tied with every other turn-in, broken on metres — so six nearer hand-ins could evict the task
the player had actually selected, which is the R2.39 eviction this ordering exists to prevent.
Precedence, not range, is what keeps one mark on that body.

**The cost is R2.46's complaint, now bounded and switchable rather than structural.** Every
pending hand-in within `beacon_dist` can hold one of the six slots. Three things bound it:
the distance, the slot count, and prio — objectives sort ahead of the ambient band, so what a
crowd of turn-ins can crowd out is a shop. They can crowd out *each other*, on metres, since
they share a priority; what they cannot crowd out is the selected one. Selecting a task still
changes what is drawn; it just no longer changes *whether* anything is.

**On by default, via `~= false` rather than a truth test.** A settings file predating the
option reads `nil`, and `nil` has to mean the shipped behaviour — the fix is the answer to a
bug report, and withholding it from everyone who already has the mod installed would be the
wrong way round. Gated on `mark_targets` like every other role marker, and deliberately not
on `mark_beacon`, which is the selected task's own row and stays about the mark this one
defers to.

**`delivery` is the same hole and is deliberately still open.** It is also `ROLE_PRIO` 1,
also an objective role, and also unkeyed in `beacon_roles`, so a courier drop on a
shopkeeper still marks the shop. `BEACON_ICON.delivery` exists and keying `br.delivery` is
the same one line — held back because it would put an envelope over every recipient in
range, which is a behaviour change nobody has asked for, rather than the repair of one that
was reported.

### `beacon_color`

One list rather than two switches, because "map colour" and "faction colour" are
mutually exclusive for a turn-in and a pair of checkboxes would let the player tick
both. Mode 2 is mode 1 plus a faction override on turn-ins only.

**Mode 2 is the default**, where the accent (0) used to be. The accent was the safe choice
while a marker was a flat glyph read against sky, and it stopped being the necessary one when
each mark started carrying its own baked keyline -- an outline is what lets a colour keep its
edge. What mode 2 buys is that a marker and the PDA spot for the same body are the same
colour, so the two views stop having to be reconciled by the player; mode 0 remains one list
entry away for anyone who wants the overlay in one voice.

Mode 3, the marker's own colour (R2.62), is a fourth entry on the same list for the same
reason rather than a checkbox beside it: what is being chosen is one thing — what decides
a marker's colour — and a flag crossed with the modes would let the player ask for the
map's colours and their own at once. See
[`beacon_r` / `beacon_g` / `beacon_b`](#beacon_r--beacon_g--beacon_b).

**One resolver, three callers (R2.63).** Three paths draw markers — the per-NPC role pass,
the selected task's own offer, and the party — and each used to work the mode out for
itself. Two consulted this option and the third did not, so a *selected* hand-in wore the
map's green in mode 0, whose entire promise is that everything is the accent, standing two
metres from an unselected hand-in wearing the accent: the same glyph, the same meaning,
two colours. Reported from play as exactly that question.

The fix is not a fourth mode test in the third path. It is that the rule lives in one
function (`beacon_tint` in `iqm_core`) and no path is permitted a private copy — including
the copy that was *correct*, since one that happens to agree is the same hazard one edit
later. The colour harness asserts the absence rather than the presence: no offer outside
the resolver may index a palette at all.

**What the mode does *not* choose between (R2.63a).** The mutant hunt's lime and the
bounty's red answer the same in all four modes, and gating them was a regression inside the
fix above — caught in review, shipped nowhere. Everything else in `BEACON_RGB` mirrors a
map spot, which is what this option chooses to wear or not; those two are the task *kind*
speaking, and no role draws a skull or a red reticle, so they can never sit beside a
differently-coloured mark meaning the same thing. The bounty is what makes it a bug rather
than a preference: it has no glyph of its own on purpose — "a bounty IS the ordinary
go-find-it reticle and only its colour differs" — so gating its red does not dim the mark,
it deletes it, leaving something byte-identical to an ordinary objective in the accent
mode. [`beacon_r`](#beacon_r--beacon_g--beacon_b) had promised exactly this in
writing since R2.62 and was made false in passing, which is the argument for the regression
test now sitting in the colour harness.

The resolver crosses the seam *into* `iqm_beacon` rather than the colours crossing back,
and that is a budget decision rather than a taste one: `actor_on_update` sits at exactly
LuaJIT's 60 upvalues, so naming the resolver at those two call sites does not compile.
`iqm_core` passes the one input only it holds — the giver's community, for mode 2 — and
the offer resolves on its own side.

**What tells the selected mark apart instead is its shape.** The turn-in the player picked
wears a ring (`BEACON_RING.sel`), in every mode and at every range. That is the map's own
grammar rather than a new one: the PDA does not tint the task you selected either, it draws
a bracket round it. Colour was never free to carry that distinction — it is spoken for by
the mirror rule, which says a marker's colour is its map spot's colour.

The ring is suppressed on one glyph, the reticle, because `BEACON_RING.sel` *is* that
glyph's outer arcs: ringing it draws the same four arcs twice at two radii, which at 20 px
is a hoop. Nothing is lost — the reticle is already the selected task's own mark and no
other path draws it — and it is the same ground on which the placed waypoint's glyph never
wears the waypoint ring.

### `beacon_r` / `beacon_g` / `beacon_b`

The marker gets a colour of its own (R2.62), asked for directly. Until then its only
colour that was not the map's was `col_r/g/b`, the **cards'** accent — so the one way to
recolour a marker was to recolour the nameplates with it, and the two are not the same
object: a nameplate is read while you stand in front of somebody, a marker is a badge
found against sky and foliage at 200 m. That is the argument
[`route_r`](#route_r--route_g--route_b) and [`minimap_r`](#minimap_r--minimap_g--minimap_b)
already make for their own three keys, and the marker had the weaker claim of the three
only because nobody had asked yet.

**It is a mode, not an override.** Mode 3 is mode 0 with a different accent: no role
colours, no faction turn-ins, and the task-kind colours (the mutant's lime, the bounty's
red) behave exactly as they do in mode 0, because they are the *kind* speaking rather than
the theme. One consequence worth stating: the head node and its leader line on the
nameplate stay on the cards' accent, so with mode 3 set to something far from the gold the
mark over an NPC's head and the badge through the wall are deliberately two colours. They
are answering two questions at two distances; the alternative is that setting the marker's
colour silently repaints the nameplates.

**The defaults are the accent's own 224/196/122**, so choosing mode 3 changes nothing on
screen until a channel is moved. The mode is then a starting position rather than a jump to
some other colour — a player who came to shift the gold a little does not have to rebuild
it first — and the marker cannot change colour at the instant the mode is picked, which
would read as the option doing something other than what it says. The colour harness reads
those defaults *out of the accent's own rows* rather than restating them, so retuning the
gold moves both together.

Channels are step 1, as everywhere else ([Colour channel step](#colour-channel-step)).
There is no fourth alpha slider: `beacon_a` is already the marker's opacity, and a second
one would be two names for one multiply.

### `beacon_rsize`

Directly under the switch it modifies, rather than two rows below it as it was until
R2.44. The original reason was that a row which *disappears* when the one above it is
turned off should be adjacent to it, or the disappearance reads as the menu losing a
setting. R2.59 removed the disappearing (see [Preconditions](#preconditions)) and the
adjacency stays on the plainer argument that outlived it: a setting belongs next to the
thing it adjusts.

### `beacon_ctr`

Cyberpunk's move, and the reason it belongs here rather than being argued as taste: the
markers are already plate-less and keyline-baked precisely so they sit over live gameplay
without owning it, and a distance-from-centre multiplier is the same instinct one step
further. The thing under the crosshair is the thing the player wants to see.

Stored as a PERCENT OF THE HALF SCREEN HEIGHT rather than in pixels. A pixel radius is a
different circle on every monitor, and this is a "how much of my view" setting -- the same
reasoning `beacon_rsize` uses for expressing the readout as a percentage of the glyph
instead of a size of its own.

0 = OFF, so there is no separate switch, which is `dim_hold`'s arrangement one page over.
On by default because getting out of the way of the crosshair is the whole point of the
feature, and because the floor below means nothing ever disappears.

Only ever applies to an UNCLAMPED marker, and that is a consequence rather than a
limitation: one parked at a screen edge is by definition far from the centre. What is left
is exactly the cases where a marker can sit under the crosshair -- an NPC on screen but
behind a wall, one on screen but past card range, and the objective dead ahead.

**One exemption, the placed waypoint.** It is the mark most likely to sit dead centre for
minutes at a stretch, because it is the thing the player is walking toward: fading it
there removes the mark they placed by hand at the moment it is confirming they are on
course. Cyberpunk can fade its centre marks because they are ambient points of interest,
not a chosen destination. Already exempt from `beacon_dist` and from `beacon_color` for the
same shape of reason.

**The selected task's marker is NOT exempt**, and the two are one line apart in the code,
which is the trap: `offer_waypoint` and `offer_task` both pass prio 0, so an exemption
written against priority silently takes the objective with it -- removing the feature from
the marker it matters most on. It is tested on the texture instead. The objective can
afford the fade: it never disappears, and the route line on the ground is already saying
the same thing from a different angle.

### `beacon_ctr_a`

20 rather than 0 for the reason `dim_level` gives at length: the default should be the
behaviour that cannot flicker, and a quest marker that vanishes outright at the centre
reads as a bug the first time it happens. 0 is a full hide and is deliberately reachable.

Judge it against a sunlit wall rather than on paper. Alpha on a marker is three
multipliers deep by the time this one lands -- the card/marker handover, the combat dim,
then the falloff -- and R2.26 is the standing lesson about what that compounding does.

**The size FLOOR is not offered as a setting** (the shrink itself can be turned off --
see `beacon_ctr_size`), and is 3/4 in `iqm_beacon` (`CTR_SMIN`).
It is not a taste choice: much below that the badge stops reading as a glyph and the metre
readout collapses into `draw_beacon`'s `max(2, ...)` clamp and pops back out of it. Alpha
is what does the getting-out-of-the-way; the shrink is there to say the mark has stood
down. It is exactly 3/4 and not 0.7 because it has to land on the size quantisation grid
(`CTR_Q`, sixteenths) -- 0.7 rounds to 11/16, so the constant would not be the floor the
code applies, and every expectation written against it would be a step out.

### `beacon_ctr_size`

Asked for from play, and the request is a better read of the feature than the first cut
was. The falloff is doing two things at once, and only one of them is about clearing the
view: the fade is what actually gets the marker out of the way, and the shrink is what
makes it *read* as standing down rather than as the game dimming. Those are separable, and
someone who wants the first without the second is not asking for half a feature -- a mark
that changes size is a mark whose position the eye has to find again, which is a real cost
paid for what is essentially a flourish.

So the fade is not optional and the shrink is. **OFF by default** -- the fade is the half
that actually clears the view, and a mark that changes size is a mark whose position the eye
has to find again. On restores the behaviour the feature shipped with, where the marker
visibly stands down as well as going quiet.

It shipped default-on and was flipped when the shrink turned out to be the half that got
noticed and disliked. The read is still `~= false` rather than a truth test, which is now
belt-and-braces rather than load-bearing: `read_config` starts every key at its registry
default, so `C.beacon_ctr_size` is never `nil` and a settings file predating the option now
lands on *off* with everything else.

**A check, not a size-floor slider**, and not a floor of 100 folded into `beacon_ctr_a`'s
neighbour. The only interesting values are the two ends -- shrink, or do not -- and a slider
in between invites tuning a number that has no good answer, while also implying the floor
and the fade are the same kind of setting. They are not: one is a quantity of getting out of
the way, the other is a yes/no about how the getting out of the way looks.

It returns early inside `ctr_fade` rather than clamping the size floor to 1, which sounds
like the same thing and is not: both multipliers come out of one smoothstep, so the clamp
written as one expression flattens the OPACITY ramp along with the size. That mistake is
mutation-tested in `tools/center-falloff-harness`.

---

## Route: ground

### `mark_route`

**Off by default.** Of everything the mod draws this is the one that answers *how do I get
there* rather than *who is that*, and that is a larger change to how the Zone is read than a
nameplate is -- a line on the floor is the closest this mod comes to the waypoint chase its
own rules are written against. So it is the aid a player decides about rather than one they
are handed, and the mod out of the box is the nameplates and the markers.

It is not a statement that the route is a lesser feature: the two things that follow from
this default -- [`route_reveal`](#route_reveal) standing rather than summoned, and
[`route_flow`](#route_flow) at the top of its range -- both exist to make the feature show
what it is the moment it *is* switched on. The minimap trail ships off for the same reason
and independently; either view works without the other.

### `route_reveal`

**Default 0, standing.** Added R2.58 and defaulted to 2, summoned, until the route itself
went default-off: a player who goes looking for the feature and switches `mark_route` on has
asked for a route, and answering that with a line visible only while a key they may not have
bound is held reads as the switch not working. The summon is what you move to once the
standing line is more than you want -- not the thing you have to find before you see
anything at all.

The route's acknowledged parent is Dead Space's RIG line (`docs/ar-navigation.md`), and
until this option the mod had taken the *look* of it and not the *interaction*: their line
is summoned by a button, holds for a moment and fades; ours stood there. Extending the
reveal hotkey to the route closes that, and mode 2 is still the strongest answer the mod has
to its own "don't turn the Zone into a waypoint chase" rule — a route that exists only in the
two seconds you asked for it cannot be followed mindlessly. That argument is about which mode
is *best*, and the default is about which is *discoverable*; they no longer give the same
answer now that the feature is opted into.

It was also nearly free, which is why it happened as one option rather than a rewrite.
`iqm_nav` has blanked the ribbon rather than dropping it since the first version, so
bringing it back costs no search and no repath; the fade is one multiplier on an alpha that
was already the product of four others.

**Why "follow the nameplates" (1) is kept rather than removed.** It is not a compatibility
shim. The route has always been gated on `overlay_visible()`, so a player using the reveal
hotkey in hold-to-show mode already had a summoned route and a coupled one — the cards and
the line came up together. That is a coherent thing to want and the option preserves it
exactly.

**Why there is no fourth value for "off".** `mark_route` is the switch. A mode that turned
the feature off would be a second way to do the same thing, and the two would disagree the
first time either was changed.

**The gate had to be split to make this work at all.** `overlay_visible()` folded the
nameplates' reveal rule into the answer every overlay took, so a player who toggled the
cards off and then summoned the route got nothing. `iqm_core` now memoises the PDA/HUD pair
separately (`OVIS.b`) and the two views take it plus their own rule.

### `route_dwell`

Default 30 (3.0 s), added R2.58 at 20.

Tenths of a second, for the reason `dim_hold` is: MCM tracks are integers and 0.1 s is
finer than anyone can judge. 0 is a pure hold-to-show and a legitimate setting, not a
disabled one.

**Why the default is whole seconds and not tenths of one.** The gesture has to survive a
*tap*. Dead Space's is a tap, and the whole appeal is glancing at the route rather than
holding a button through it — a dwell under a second turns the feature into a hold, which is
a worse thing to ask of a player who is being shot at. A dwell measured in seconds is also
what makes the tap and the hold *one* gesture in code: the dwell is stamped on the release
edge, so nothing has to tell them apart. Three rather than two because a glance at a route
is followed by walking it, and the line going out while you are still turning onto it asks
for the key again immediately.

### `route_key`

Default -1, meaning **use the nameplate key** — not "off". Added R2.58.

One key looked like enough and was not, for two reasons that only turned up when the
combinations were written out.

**The unreachable configuration.** `reveal_key = -1` means "nameplates always shown", and
under a shared key that same -1 has to mean "no summon gesture exists" — which the
never-strand rule then resolves to "route always drawn". So *nameplates permanently up with
the route pulsed on demand* — the most obvious way to want this feature — was the one
configuration that could not be expressed at all.

**The tap drags the nameplates with it.** `ui_mcm.simple_press` schedules its action for
`dtaptime` later and fires it only if the key has been released (`ui_mcm.script:549-567`),
so a *hold* on the shared key never toggles the cards. A *tap* always does. Since the tap
is the gesture, the shared key cannot give you the route without also flipping the
nameplates.

Its own key removes both, and takes the `reveal_mode 2` (long-press-toggles) collision with
it — there, one hold would otherwise do both jobs. Defaulting to the shared key keeps the
zero-configuration case working: bind nothing new and the nameplate key summons the route,
with the tap side effect documented on the row.

`route_mod` rides `route_key` being bound rather than sitting beside it always: while the
fallback is in force the gesture borrows `reveal_mod` too, so a second modifier control
would be configuring nothing.

### `route_dist`

**Default 20 m.** The range is what makes the route a weaker aid than the map marker the
game already gives you, so the shipped value is at the short end deliberately: 20 m is the
next stretch of ground -- the way round the building in front of you -- and not a line laid
most of the way to a destination you have not found yet. Nothing about the feature needs a
longer draw to make sense, and every metre past this one is a metre of navigation done for
the player.

1..80 in steps of 1 since R2.41, from 20..80 in steps of 5. The floor moved because
20 m is not a short route, it is a medium one -- a player who wants the next few
metres of ground and nothing else had no setting for it, and the bottom of the slider
was still a line running most of the way across a room. The step follows the floor: at
5 a minimum of 1 lands on 1, 6, 11 and never on a round number again, so the two have
to move together.

### `route_shape`

All three point. The flatter shapes that did
not -- the rung, the tile -- are gone: a mark that carries no direction reads as
decoration on the floor, and the alignment they bought is documented at RTE.SHAPES in
iqm_cards.script for anyone who wants it back.

### `route_pulse`

HOW HARD THE MARKS PULSE, 0-10, as a fraction of their own brightness (R2.43). A LOOK
option rather than a motion one, so it sits with the colour here rather than with the
conveyor on the General page -- and on this page rather than General for the same
reason the minimap trail does not take it (an 8 px blob on a map has no brightness to
spare).

The nearest thing to luminescence this layer can actually do, and the reason is worth
stating because it rules out the obvious alternatives. Marks are CUIStatics drawn
AFTER the scene's post-process, so nothing painted into one can bloom, spill light or
respond to darkness -- and `script_glow`, the engine primitive whose entire job would
be this, is a no-op stub on every renderer since R1 (CGlow in r2.cpp / r4.cpp has an
empty body for every setter). A real script_light works and lights the FLOOR, but it
cannot light the mark and costs 3-6% of frame time at sixteen of them. See
docs/ar-navigation.md, "can the marks glow?".

What is left is the tint, which is already recomputed per mark per frame -- so this
costs one sine and a multiply and nothing else. It brightens rather than fading: the
tint MULTIPLIES the artwork, so scaling it up drives the glyph toward its own colour
at full strength, which reads as the paint catching light. Modulating ALPHA instead
reads as blinking, which is a warning light rather than a glow.

IT IS A TRAVELLING WAVE, not a synchronised breath, phased off each mark's stable id
(RD.cn, R2.42) so the crest runs ALONG the route toward the target. Every mark
brightening at once reads as the whole HUD flashing; a wave reads as direction, which
is the one thing the route is for -- and it reinforces the conveyor rather than
competing with it.

6, AND THE AMPLITUDE IS A FRACTION OF THE COLOUR'S HEADROOM, not of the colour
(R2.43a). 10 is "as bright as this colour goes with its hue intact"; 0 is off.

The first version multiplied the colour directly and was invisible in game, which was
caught by reading the live mark widgets rather than by looking: at a route colour of
45/95/50 the crest reached 57/121/64, a lift of +12/+26/+14 out of 255 on a small
glyph against sunlit concrete. The wave was running perfectly and could not be seen.

A multiply gives the SMALLEST absolute lift to the DARKEST colour -- and a dark mark
is already the one with least contrast against the ground, so the effect faded out
exactly where it was needed most. Measured either way, at this default:

        route colour      old (x of colour)        new (x of headroom)
        176/196/124       +31/+35/+22              +31/+35/+22
         45/ 95/ 50       +12/+26/+14              +45/+95/+50

Identical where it was tuned, four times the lift where it had gone missing. Hue is
exact at every setting, because it is still one multiplier across all three channels,
and it can no longer clip at any amplitude.

The honest limit: a colour already at 255 in some channel has no headroom and cannot
pulse. Unavoidable for a multiply, and the right failure -- the alternative drifts the
hue on precisely the colours somebody chose deliberately.

### `route_a`

Route opacity (0-255), fully opaque since R2.26. 215 was 84% of an alpha that then
gets multiplied by the near fade, the far fade and the occlusion verdict, and the
product is what reaches the screen: a near mark was landing at a quarter of full
strength. The multipliers are the ones that should be doing the work -- they are
saying something -- and taking a flat 16% off the top before them says nothing.

### `route_r` / `route_g` / `route_b`

The route carries its own colour rather than the cards' accent: it is scenery you walk
along rather than a marker you glance at, so it wants to sit in the scene instead of
standing out of it.

The route gets its OWN colour rather than the accent the cards and beacon share,
because it is a different kind of object: a marker is read once, at a glance, and
wants to stand out, while the route is a dozen marks you walk along and live with, so
it wants to sit in the scene.

Lightened from the army green (134, 152, 86) after the twelfth session. That value
was picked against the idea of the Zone rather than against its ground, and the
ground it is actually drawn on -- wet grey concrete, and the yellow sand of the
Garbage -- sits at almost the same value, so the route read as a stain on it. This
keeps the olive cast and lifts it clear. F7 -> "IQM: Route Colour Cycle" steps
through this and three alternatives on the live route.

AMBER from R2.33, 176/196/124 -> 232/196/92, chosen off the comparison sheet
against the olive above, an ice blue and the saturated blue the twenty-fifth
session was running. The argument that picked it is the one in the paragraph
above, followed to its end: paint reads by being brighter than the ground, and
warm paint on a cold interior is what floor markings actually are -- so it is the
only candidate that reads as PAINT rather than as light. The olive lost for
exactly the reason it was chosen, sitting so far into the Zone's palette that it
stopped announcing itself.

AND BACK TO THE OLIVE IN R2.40, asked for directly, alongside the camo pattern now
baked into the glyphs (tools/stroke-tex, MARK_CAMO). The two go together and the
second is what answers the objection above: what made the olive read as a stain was
that it was one flat value sitting at the ground's own, and a flat fill has nothing
but its value to be found by. A camo'd mark carries its own internal contrast --
three levels of the tint, plus the full-strength keyline round the outside -- so it
is found by PATTERN as well as by brightness, which is the one cue a wet concrete
floor cannot imitate.

176/196/124 rather than the original 134/152/86: this is the lifted olive R2.19
measured against the Garbage's sand and the concrete of the interiors, and the camo
only ever multiplies the tint DOWNWARD, so the base has to be the bright end of the
range rather than the middle of it. Set 134/152/86 in MCM for the deeper drab.

---

## Route: minimap

### `minimap_dist`

The trail's OWN drawn distance (R2.24), separate from route_dist. The two views want
different amounts of route for a reason that is about the view rather than the route:
the ground line runs out where you can no longer usefully see it, while the trail is
read at a glance off a map and can carry further without getting in the way. iqm_nav
publishes one list at the longer of the two and each stops at its own (see route_limit
there).

### `minimap_style`

A list rather than a checkbox because what is being chosen is one thing -- the mark --
and a third style should be another entry here rather than a second flag crossed with
the first.

### `minimap_r` / `minimap_g` / `minimap_b`

Its own three keys rather than a share of the ground line's (route_r/g/b) for the
reason the two views are split everywhere else: those colours are chosen to sit IN the
scene you walk through, and this one is read off a map against terrain, a player arrow
and everyone else's spots.
