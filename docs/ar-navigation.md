# AR navigation — research tracker

Working doc for two related features. Kept in the repo so settled facts don't get
re-researched and open questions don't get lost.

**F1 — Hand-in beacon.** A point marker for the NPC of the active task that is
ready to hand in. Draws **through walls**, at long range. Conventional: objective
markers are through-wall in essentially every shooter, because "it's behind that
building" is the whole message.

**F2 — Route.** Direction arrows laid along the ground toward that NPC, each scaled
by its distance so the run converges away from you, with the ones you cannot
actually see **faded rather than hidden**. Drawn out from the player for a fixed
distance rather than gated on how near the target is. Three convictions from the
original design did not survive contact and are worth stating as superseded:

- *strictly depth-tested*, because route lines read as paint on the ground (Dead
  Space's RIG line, The Division, Fable's trail). But the route only appears when
  the target is *out of sight*, so a hard cull blanks exactly the stretch that
  answers the question (R2.6). Occluded points now fade; `route_xray` restores the
  hard behaviour.
- *world-space wire, not projected sprites*, because a billboard cannot lie flat
  on the ground. True, and not the deciding factor: the wire renderer has no
  thickness, no alpha and rebuilds wholesale, which on screen read as thin and
  laggy, while distance-scaled sprites carry perspective perfectly well (R2.8).
- *proximity only, so as not to make the game materially easier*. That turned into
  a route that only appeared once you had already found the target. Showing the
  next stretch of walkable ground is not a waypoint — it never says where the
  destination is — so the limit is now on how much route you see, not on how near
  the target must be (R2.9).

Together these are the hybrid pattern: a beacon for the destination, a route for
the way there.

**The line is summoned, not standing (R2.58).** The RIG line is named above as the
parent of this route, and for fifty revisions the borrowing was one-sided: their line
is *asked for* — hold a button, it draws, it fades — and ours simply stood on the
ground. Taking the interaction as well as the look is now the default (`route_reveal`,
and see `docs/decisions.md#route_reveal`), which makes the third superseded conviction
above land properly at last: the reason a route is not a waypoint chase is not only
that it never says where the destination is, but that it is not there unless you asked
for it in the last two seconds. It was cheap in exactly the way the earlier lessons
made it cheap — the ribbon has always *blanked* rather than dropped, so a summon costs
no search, and the fade is one more multiplier on an alpha that already carried four.

Two things had to change underneath, both recorded here because they were the
non-obvious half. The mod's overlay gate folded the nameplates' hotkey into a single
answer every overlay took, so a summoned route could not come up while the nameplates
were toggled off — the PDA/HUD pair is now memoised apart from the reveal rule, and the
two views take it plus their own. And the summon needed a key of its own: with one key,
"nameplates up, route on demand" turned out to be unexpressible, and a tap on the
shared key toggles the cards whatever the route does with it.

Status: **F1 built, untested in game · F2 built end to end and wired to the quest
target; six in-game sessions, each of which found something real — restyled
(R2.6), near-edge and suppression-latch fixes (R2.7), moved off the wire renderer
onto textured sprites (R2.8), the range model inverted so the route is drawn out
from the player rather than gated on target proximity (R2.9), partial routes so a
distant target gets one at all (R2.10), and spaced marks abandoned for a
CONTINUOUS STROKE (R2.11). The stroke's first build broke the module outright by
exceeding Lua's 200-local limit, fixed with a verification tool that models the
engine's loader (R2.12). Needs re-testing.**

---

## Settled — do not re-research

Everything here is confirmed against the engine source at
`C:\Source\Gamma\xray-monolith-all-in-one-vs2022-wpo` and, where noted, against the
shipped GAMMA binary.

### Level graph (routing) is exposed to Lua

| Binding | Gives | Source |
|---|---|---|
| `level.vertex_id(pos)` | nearest navmesh node | `level_script.cpp:1110` |
| `level.vertex_position(vid)` | world pos; `(0,0,0)` if invalid | `level_script.cpp:394` |
| `level.vertex_link(vid, 0..3)` | the node's 4 grid neighbours | `level_script.cpp:311` → `NodeCompressed::link`, `xrLevel.h:237` |
| `level.vertex_in_direction(vid, dir, dist)` | engine-side "walk this way as far as the graph allows" | `level_script.cpp:379` → `farthest_vertex_in_direction` |
| `level.get_nearby_vertices(pos, r)` | node set in a radius | `level_script.cpp:1115` |

`vertex_link` is real navmesh adjacency, so a genuine A* is possible. All of the
above, plus `world2ui_with_depth`, verified present in `AnomalyDX11AVX.exe` by
string check.

### No cross-level routing is possible

`CGameGraph` binds `game_graph()`, `vertex()`, `level_id()`, `level_point()`,
`game_point()` — but **no edge access** (`game_graph_script.cpp:64-77`). There is no
way to walk the inter-level graph from Lua. Off-level targets need a different
answer (see R2.3).

### `world2ui_with_depth` solves behind-camera projection

`level_script.cpp:1658`. Returns `x, y, depth` where depth is a **sign only**
(`v_res.w < 0 ? -1 : 1`), not a distance. That's enough for near-plane culling and
off-screen edge clamping.

### `debug_render` works in release, but cannot be depth-tested

Registered unconditionally (`level_script.cpp:2331`); `CLevel::ScriptDebugRender()`
is called from `OnRender` **outside** the `#ifdef DEBUG` block (`Level.cpp:1304`);
`m_debug_renderer` is constructed in release (`Level.cpp:258`). Shipped GAMMA mods
use it in normal play (Hideout Furniture, Ledge Grabbing, Weapon Cover Tilt).

Its render state is fixed in C++ — `Blender_Editor_Wire.cpp:59`:

```cpp
C.r_Pass("editor", "simple_color", FALSE, FALSE, FALSE);
```

against `r_Pass(vs, ps, bFog, bZtest=TRUE, bZwrite=TRUE, bABlend=FALSE, …)`
(`Blender_Recorder.h:151`). So:

- **no depth test** — draws over all geometry (confirmed in-game: a walked loop
  around a building showed through the walls)
- **no depth write**
- **no alpha blending** — alpha is ignored, so `fade_steps` in the prototype is inert
- 1-px untextured line list only (`m_WireShader`, `D3DPT_LINELIST`, `dxDebugRender.cpp:55`)

`editor` / `simple_color` are the shader *programs*; the render state comes from the
C++ blender (`B_EDITOR_WIRE`), **not** from anything in `gamedata/shaders`. A
gamedata-only mod cannot change it. Exe recompile only → out of scope.

**Consequence: `debug_render` is a perfect fit for F1 and cannot satisfy F2's depth
requirement on its own.**

### The gizmo queue is wiped on save load

`CLevel::OnAlifeSimulatorLoaded` / `OnAlifeSimulatorUnLoaded` both call
`delete_data(m_debug_render_queue)` (`Level.cpp:1774,1781`). Lua-held handles dangle
→ writing through one is a crash. `iqm_pathline.script` already guards every
dereference behind a liveness probe; any new renderer must do the same.

*Not yet exercised in-game* — the test session never loaded a save with a ribbon up.
Covered by the harness only.

### NPCs stay online out to 450 m in GAMMA

`switch_distance = 450` — `G.A.M.M.A. Alife optimization/gamedata/configs/alife.ltx:11`
(base Anomaly is lower; GAMMA raises it). Inside that radius the target has a live
`game_object`: real position, bones, everything the existing card pipeline already
uses. **Any proximity feature under ~450 m never needs the offline path at all.**

### Offline positions are available anyway, but coarse

`cse_alife_object` exposes `position`, `m_game_vertex_id`, `m_level_vertex_id` and
`online` as properties (`lua_help.script:4514-4522`), readable via
`alife():object(id)` regardless of online state.

They do track migration: `sim_squad_scripted:set_squad_position` assigns
`k.object.position = position` for offline members (line 852) and maintains
`db.offline_objects[k.id].level_vertex_id`. But it updates on **squad relocation
between smart terrains**, not continuous walking — so an offline position is a
"roughly there" answer, not a live one.

### What GAMMA already draws for the active task target

Three indicators, **all 2D map/bearing abstractions — none world-anchored in the
3D scene**:

1. **PDA fullscreen map** — `storyline_task_location` → `storyline_task_spot`,
   `secondary_task_location` → `secondary_task_spot`
   (`map_spots_16.xml:1190-1215`, winner *Sota UI EGUI Style HUD*). Icon
   `ui_inGame2_PDA_icon_Primary_mission` plus a blinking `ui_pda2_stask_last_02`
   border. Requires opening the PDA.
2. **HUD minimap** — the same locations declare `<mini_map spot="..._spot_mini">`
   with `ui_mmap_stask_last_02`. The widget is `zone_map_16.xml` (contested by 5
   mods; winner *Sota UI EGUI Style HUD*, with SquareDOV and Modular Compass
   Minimap also installed). Top-down, small radius.
3. **Tactical Compass bar** — mod 420, active (it wins `axr_main.script`).
   `markers_definitions.script:3-4` maps `storyline_task_location` → "primary" and
   `secondary_task_location` → "secondary". A bearing strip: heading, not position.

Plus `quest_pointer` / `quest_pointer2` off-edge arrows on map and minimap
(`map_spots_16.xml:8-13`, texture `QuestArrowIcon`).

**The `map_spots` system has exactly two render targets — `<level_map>` and
`<mini_map>`.** There is no world or HUD target. Nothing GAMMA ships places a
marker at the NPC's actual on-screen position.

**No duplication risk.** Every existing indicator is *allocentric*: it asks the
player to translate "north-east, 60 m" into "that man behind the shed". F1 is
*egocentric* — it points at the person in the scene. Different job.

### The role-glyph atlas is full

**Superseded twice, 2026-08-13** — F2's route arrow later appended a fourth row
(`COLS=4, ROWS=4` = 16 cells, 13 used, three spare), again keeping every existing
cell's pixel coordinates. The rule below still holds and is why both growths were
cheap: append rows, never widen `COLS`.

This section used to read "exactly one free cell",
against a `COLS=4, ROWS=2` grid holding 7 names. F1 spent that cell on `chevron`
and then added four state glyphs, so `build.py:42-45` now holds **12 names in a
`COLS=4, ROWS=3` grid = 12 cells, and there are none left.**

The row was *appended*, which is why it was cheap: rows 0–1 kept their pixel
coordinates and no existing texture id had to move. A 13th glyph needs another row
(`ROWS` in `build.py`, a rerun, and one new `<texture .../>` line) — still cheap
for the same reason, as long as it appends. Widening `COLS` instead would
renumber every id in `iqm_textures.xml`; don't.

Note the card
renderer already does aspect-corrected rotation (`SetHeading` + `UI_KX`,
`iqm_core.script:1757-1783`), so one chevron glyph can serve every edge direction
rather than needing eight.

### A heading-rotated static may be NON-SQUARE — it stays a rigid rectangle

This is what makes a real line possible on the UI layer, and it is worth stating
separately from the `UI_KX` rule below because it is the part that is not obvious.

`CUIStatic::DrawTexture` (`ui/UIStatic.cpp:117-131`) passes the window rect's width
and height straight into `SetSize` when `stretch="1"`, with no squaring-up unless a
fixed-LT heading pivot is set. `CUIStaticItem::RenderInternal(float angle)`
(`UIStaticItem.cpp:110-181`) then builds the four corners in **local UI units** —
`(0,0)`, `(SZ.x,0)`, `(SZ.x,SZ.y)`, `(0,SZ.y)` — rotates each about the pivot
(defaulting to the rect's own centre), and only afterwards scales. `rotate_pt`
(`ui_base.cpp:11-19`) is a plain rotation followed by `pt.x *= kx`, and
`ClientToScreenScaled` then scales X by `w/1024` and Y by `h/768`.

So the composite local→screen map is **rotate, then uniform scale** (because
`UI_KX * w/1024 == h/768`), which means:

- a non-square strip rotates rigidly — it does not shear or change aspect with angle
- length and angle taken from `(dx / UI_KX, dy)` land the strip's two ends exactly on
  two given UI points
- the strip's centre lands at `SetWndPos + (w/2, h/2)`

`card_line` has relied on all three since the first version of the mod to join a
head point to a card corner, which is the strongest evidence available that it is
right. R2.11 applies the same geometry to the route.

**This is the only non-billboard shape this layer can draw.** Everything else is
axis-aligned or rotated-square. There is still no perspective warp: a quad's four
corners cannot be set independently, so a strip is a screen-space segment of
constant width, not a ground-projected trapezoid.

### Anomaly runs LuaJIT 2.0.4

Not PUC Lua 5.1, which is easy to assume because the exe also carries the string
`Lua 5.1` — that is only LuaJIT's compatibility `_VERSION`. Confirmed two ways:

- the exe contains `LuaJIT 2.0.4`, `luaJIT_BC_` and `jit.opt`
  (`AnomalyDX11AVX.exe`, string scan)
- the engine vendors the matching source at `src/3rd party/luajit-2`
  (`src/luajit.h`: `LUAJIT_VERSION "LuaJIT 2.0.4"`, `LUAJIT_VERSION_NUM 20004`),
  with `msvcbuild.bat` alongside it

A useful tell in logs: LuaJIT builds its limit errors from the template
`main function has more than %d %s`, where PUC 5.1 uses a literal
`...%d local variables`. So a message reading "more than 200 local variables" came
out of LuaJIT.

Anything validating scripts offline should therefore use **LuaJIT 2.0**, not 2.1 (a
separate branch with extra syntax) and not PUC 5.1 (a different implementation).
`pip install lupa` ships a prebuilt LuaJIT 2.0 as `lupa.luajit20`, which is what
`tools/check-lua.py` uses — no compiler and no Lua on PATH required.

### A `.script` gets 198 locals, not 200 — the engine prepends two

LuaJIT 2.0 implements Lua 5.1 and keeps its limit of **200 active locals** per
function, and a `.script` file's body IS a single function — so every top-level
`local` in the file competes for one budget. Exceeding it is not a warning and not a
slow path; the parser raises

    main function has more than 200 local variables

as a **syntax error at load time**, so the entire module fails and everything it
provides vanishes together.

**The file that fails is not the file on disk.** Before loading a script into its
namespace, `CScriptStorage::load_buffer` (`script_storage.cpp:714-762`) prepends
`file_header` (`script_storage.cpp:43-52`), which for a dot-free namespace expands to

```lua
local function script_name() return "iqm_markers" end
local this = {}
iqm_markers= this
setmetatable(this, {__index = _G})
setfenv(1, this)
```

`script_name` and `this` are **two more top-level locals**, charged to the same 200.
So the usable budget is **198**, and a file sitting at exactly 200 compiles perfectly
well on its own and is rejected by the game. (The header is a single line, because
the C string's backslash continuations leave no newlines — which is why a reported
error line still matches the file's own numbering.)

This cost a session: `iqm_markers` (the file since renamed `iqm_core`) was at 200, an offline `luajit -bl` pass over the
bare file was clean, and the game refused to load it — taking cards, beacon and route
down at once. Note what was NOT the cause, since it is the tempting conclusion: the
**compiler** was fine. Every Lua 5.1 implementation checked — LuaJIT 2.0, LuaJIT 2.1
and PUC 5.1 — enforces the same 200-local limit and rejects the header-wrapped file at
the same point. The check was compiling the wrong *source*, not using the wrong
compiler.

`tools/check-lua.py` now compiles each script with the header prepended, under LuaJIT
2.0 (via `lupa.luajit20`, so no compiler and no Lua on PATH), and reports each file's
exact remaining budget by binary-searching where it stops compiling. A static count of `local`
keywords is not good enough: it over-reports, because locals in a block — a top-level
`for`, say — are released at its `end` and never join the function's peak.

The practical upshot for a file near the limit: **group new state into one table**
rather than adding names. That is what `RTE` in `iqm_core` is for, and it bought
back 21 slots on its own.

### `printf` is not `string.format`

`_g.script:612` gsubs the literal token `%s` and nothing else. Other specifiers print
raw **and shift later arguments**. Pre-format numbers with real `string.format` and
pass `%s`. Bit us twice already. See `tools/pathline-harness/harness.lua` for the
check that enforces it.

---

## F1 — Hand-in beacon (through walls)

**Decided: extend the existing UI card layer. Not `debug_render`, and not a new
subsystem.** `debug_render` draws 1-px untextured wire with no text and no alpha —
wrong tool for a beacon that wants an icon, a distance readout and a direction
chevron. The existing `IqmCards` HUD dialog already gives textured statics,
aspect-corrected rotation (needed for a chevron), fade easing, slot priority,
PDA suppression and reveal-hotkey gating.

**Scope: F1 is mostly relaxing gates on a card that already exists.** The objective
NPC is already carded as `REPORT BACK`. `render()` (`iqm_core.script:1449-1487`)
applies four sequential gates:

| Gate | Code | F1 change |
|---|---|---|
| 1. online | `get_obj(id)` → `level.object_by_id`, nil when offline | **keep** — 450 m switch distance covers any sane proximity range |
| 2. range | `d2 < appear2` (`appear_dist`, 16 m) | **raise**, objective card only |
| 3. on-screen | `project_world(wpos)` → nil off-screen / behind camera | **replace** with edge clamping |
| 4. line of sight | `has_los(...)` | **bypass**, objective card only |

Through-wall is achieved by removing gate 4, not by changing renderer.

**Design constraint (2026-08-13): proximity only.** The goal is finding the target
when you're near them, not cross-map navigation — the feature must not make the game
materially easier. So the range cap is a *design* number, not a technical ceiling.
Suggest 50–80 m: enough to locate someone in a camp, across a rooftop, or through a
wall in a building; not enough to route across a map. Conveniently this is the same
cap F2 wants for legibility (R2.4), so the two agree.

### Resolved

- **Can we get offline positions?** Yes — but we don't need to. See the two settled
  sections above: 450 m switch distance means the target is online for any proximity
  range, and gate 1 can stay exactly as it is. No offline code path required.
- **Does this duplicate what GAMMA already shows?** No. All three existing
  indicators are map/bearing abstractions with no world-anchored target. See "What
  GAMMA already draws" above. Separately: `modxml_AL_QuestArrow.script` fails to
  load in all three variants (broken comment nesting in *Sota UI EGUI Style HUD* —
  the inner `[[ui\map_spots_16.xml]]` closes the `--[[` block early), so AlphaLion's
  arrow retexture is inactive. Cosmetic, not ours, unfixed.

### Built (2026-08-13) — needs in-game testing

R1.4/R1.5/R1.6/R1.8/R1.9 all resolved in the implementation:

- **Crossover** (R1.4): card and beacon are mutually exclusive, driven by one sticky
  `f.card_up` flag. The first cut blended the beacon against the card's alpha
  (`1 - card_a/255`), which read fine at the extremes but left **both** markers up
  across the whole `full_dist..appear_dist` band — at 12 m of a 9/16 fade, a card at
  ~145/255 and a beacon at ~97 on the same NPC, indefinitely. The flag suppresses on
  the card's **target** alpha (no lag, so a close NPC becoming tracked never flashes a
  beacon while the card eases up) and releases on its **actual** alpha (so the beacon
  waits for the card to really be gone). Asymmetric on purpose; it doubles as
  hysteresis at the fade boundary. The beacon carries its own eased alpha so the
  handover dissolves rather than pops.
- **Edge clamping** (R1.5): direction from screen centre, scaled onto a rect inset by
  `beacon_edge`. Behind the camera (`world2ui_with_depth` sign `-1`) the projection is
  mirrored through the origin, so the delta is negated first and clamping is forced.
- **Scoping** (R1.6): the wider gate is `beacon_on and t.role == "target" and d2 < beacon2`
  inside the existing card loop. No other role sees it; the card's own gates are untouched.
- **Readout** (R1.8): integer metres, passed as a number. The string is rebuilt only when
  the number changes, so the per-frame path allocates nothing. Unit suffix is a
  translated string (`ui_mcm_iqm_beacon_unit`), cached like the header cache.
- **One glyph** (R1.9): `chevron.svg` in the spare atlas cell, drawn pointing +X so
  `SetHeading(0)` means right — down at an on-screen target, outward when clamped.

Sizing gotcha worth keeping: a heading-rotated static must **not** be pre-squeezed by
`UI_KX` the way the node dot and role glyphs are. The engine scales a rotated element's
X by `UI_KX`, and the virtual UI then scales X by `w/1024`; `UI_KX * w/1024 == h/768`,
the Y factor, so the two combine to a uniform scale and a plain UI square renders as a
rotating screen square. Pre-squeezing double-corrects and the chevron visibly fattens
and thins as it sweeps the screen edge.

### Generalised to all roles (2026-08-13)

Beacons are no longer objective-only. Any card role can be beaconed, gated by
`beacon_roles[role]` — one hash lookup on the per-NPC render path. Each entry is
(feature available) AND (that role's card is being detected) AND (its beacon switch),
so a beacon can never mark a role the scan isn't finding, and turning a card off takes
its beacon with it. **Only the hand-in defaults on**; the other seven are opt-in on the
Waypoint markers page, and each MCM row hides itself when its card role is off.

Presentation is now **role glyph + chevron**: the glyph says what, the chevron says
which way, placed one gap behind it along the same direction. Four new state-role
glyphs (`handin`, `needguide`, `recruit`, `hire`) took the atlas from 4x2 to 4x3 —
appended rather than reordered, so rows 0-1 kept their pixel coordinates and no
existing texture id moved.

Two sizing rules that look contradictory and are both right, now that a beacon draws
one rotated and one unrotated element at the same size:

- **rotated** (chevron): no `UI_KX` squeeze. The engine's own X-scale on a
  heading-rotated element already combines with the virtual-UI stretch to a uniform
  scale.
- **unrotated** (role glyph): `UI_KX` squeeze as usual, like the node dot and card
  glyphs, or the 4:3 virtual UI stretches it into an oval.

Offsets between the two are in screen units and converted back to UI with `UI_KX` on
x only, otherwise the glyph-to-chevron gap would be visibly wider on the horizontal
screen edges than the vertical ones.

| # | Remaining | Status |
|---|---|---|
| R1.10 | In-game test: chevron direction at all four edges and directly behind; crossover feel; whether 60 m is the right default; whether glyph + chevron + readout reads at 24 px | open |
| R1.11 | Boundary flicker — addressed by the asymmetric `card_up` thresholds above, but confirm in game with an NPC parked right on the fade edge | needs confirming |
| R1.12 | `MAX_BEACONS = 4` against `MAX_CARDS = 8` tracked. Fine for the hand-in default; check it still feels right in a hub with service beacons on, where the nearest-4 rule starts actually discarding candidates | open |
| R1.13 | Handover timing. Ducking behind cover fades the card out (~300 ms from full to the release threshold) before the beacon fades in (~200 ms). Feels like a deliberate handover on paper; check it isn't a laggy gap in practice | open |
| R1.14 | Badge proportions. Width is floored at `bh * 0.7` so a short readout ("6 m") doesn't give a tall narrow slab. Arbitrary ratio, picked blind — check it against both a 1-digit and a 3-digit range | open |
| R1.15 | Second size pass (first badge shot read as too obtrusive): glyph 24 → 14, padding 6 → 4, gap 2 → 1, `BEACON_ABOVE` 18 → 12, readout `letterica16` → `arial_14`, plate 205 → 180, shadow 120 → 95. Roughly half the previous area. Confirm it is still legible at range, since this trades exactly against the contrast problem the badge was added to fix | open |

**Note on scaling:** everything on the badge derives from `beacon_size` *except* the
readout, whose font size is fixed by the engine (`arial_14` is the smallest registered
font — `fonts.ltx:24`). So at very small `beacon_size` the text starts to dominate the
badge. If beacons need to get smaller still, the readout has to go off or move outside
the plate; there is no smaller font to reach for.

### Badge treatment (2026-08-13)

First in-game shot showed the real problem was not the glyph but the **absence of a
contrast floor**: bare line art with a `size+4` dark halo vanishes against mid-tone
busy geometry, and the glyph, chevron and readout read as three floating objects
rather than one marker.

Fixed by giving the beacon the card's own language: a charcoal plate
(`iqm_panel_round`, tint 24/22/19) with `iqm_shadow` behind it, glyph over readout
inside, chevron hung off the badge edge as a tail. **No new art** — `iqm_panel_round`
had shipped with the mod since the start and was declared nowhere.

Layout moved into `draw_beacon`: the caller supplies the chevron anchor and a UI-space
unit direction, and the badge places *itself* behind that along the line, because only
it knows its own size (it's sized around the measured range string). Finding where the
chevron attaches reuses the screen-edge clamp's "scale the direction onto the rect
boundary" trick, one rectangle smaller.

---

## F2 — Route ribbon (depth-tested)

### R2.1 — Renderer choice · **RESOLVED (2026-08-13): (a) raycast-culled lines**

Resolved by research, without needing the particle prototype the earlier draft of
this section recommended — (b) turned out to fail on grounds a prototype would not
have surfaced (compatibility and crash safety), so building one would have been
wasted effort.

**(b) Particles — REJECTED.** Four independent blockers:

1. **No tint, no scale.** `particles_object` binds exactly `play`, `play_at_pos`,
   `stop`, `stop_deffered`, `playing`, `looped`, `move_to`, `set_position`,
   `set_direction`, `set_orientation`, `set_hud_mode`, `last_position` and the
   four path calls (`script_particles_script.cpp:19-40`). There is no colour and
   no size. An effect can only be used exactly as authored.
2. **Nothing in the library reads as a ground marker.** Both installed
   `particles.xr` files are combat/anomaly VFX — sparks, dust, blood, explosions.
   The nearest things to a marker are `_samples_particles_\orange_circles` and the
   `glow_0*` samples. There is no route/ribbon/decal effect to borrow.
3. **The library is one monolithic file, and it is contested.**
   `gamedata/particles.xr` is a single binary; *Boomsticks and Sharpsticks* and
   *Particles Cinematic VFX BOTZ* each ship a whole copy, and MO2 overlays whole
   files. Shipping ours would wipe out every effect the load-order winner adds.
   The two also **differ** (BOTZ ≈3033 ids, BaS ≈2509), so even the set of
   *borrowable* names depends on which mod won.
4. **A missing name is a hard fatal, not a catchable error.**
   `R_ASSERT3(SG, "Particle effect or group doesn't exist", name)`
   (`r4.cpp:743`, same in `r3.cpp:663`) — `R_ASSERT3` is live in release, and it
   fires from the `CScriptParticles` constructor. `pcall` does not catch it. So
   borrowing a name that isn't in *this* user's `particles.xr` crashes the game,
   and (3) means we cannot know which library that is.

Worth recording what would have been the *good* news, so it isn't re-derived: the
particle blender genuinely is depth-correct —
`r_Pass("particle", "particle", bFog=FALSE, bZtest=TRUE, bZwrite=FALSE, bABlend=TRUE, …)`
(`Blender_Particle.cpp:167`), plus an `s_position` sampler for soft-particle fade
at intersections. The rendering was never the problem; authorship and distribution
were.

**(c) Spawned world objects** — rejected as before: alife churn and save pollution.

**(a) Raycast-culled `debug_render` lines — CHOSEN, and built.** See below.

There is also no fourth option hiding in the exe: the complete `level` binding list
(`level_script.cpp:2303-2728`) has exactly one world-space drawing facility, the
`debug_render` gizmo queue. Nothing binds a textured world quad. Projecting sprites
onto the HUD via `world2ui` (what F1 does) was considered and is not a route
renderer — a screen-aligned billboard cannot lie on the ground, which is the entire
read of a route line.

### R2.1 implementation — occlusion culling (built and confirmed in game 2026-08-13)

In `iqm_pathline.script`, behind `opts.cull` (default off, so the prototype's
original look is unchanged).

- **Ray:** raw `ray_pick`, not `demonized_geometry_ray`. The wrapper's `:get()`
  allocates two vectors and a result table per call; this fires `cull_rate` times
  *every frame* rather than once per NPC per 150 ms. Also one fewer soft dep —
  `ray_pick` is stock Anomaly. One ray built once and re-aimed.
- **Flags = 2 (Statics only)**, deliberately unlike `has_los`'s 3. Walls, buildings
  and terrain occlude the ribbon; a stalker or crate standing on it does not. A
  route that flickered as people walked over it would read as a bug, and with
  Objects on, the actor's own body would cull the path at his feet.
- **Cast direction:** from the point toward the camera, with the ray's **range
  clamped to just short of the camera** (`dist - cull_tol`). Any hit at all then
  means something is in between — no distance comparison to get wrong, and no long
  ray wasted past the viewer.
- **`cull_lift` (0.25 m) raises the ray origin only.** The ribbon sits 10 cm off
  the floor; a ray from there to a camera at eye height grazes the ground it lies
  on, and on any downhill slope that self-hit reports the path as occluded by the
  very surface it is painted on. Costs a little accuracy at the foot of a low wall.
- **Both-ends rule:** a segment draws only when both its endpoints are visible, so
  the occlusion edge quantises to the point spacing. This is the documented
  approximation from the original (a) analysis, now explicit in the code.
- **Grace, asymmetric** (same shape as the F1 card/beacon crossover): coming into
  view is immediate, going out of view takes `cull_grace` (200 ms). Weapon sway,
  foliage edges and doorway strafing all produce sub-100 ms occlusions.
- **Sync pass on `show()`** so a new path never flashes through a wall for the few
  frames a round-robin sweep would take. Capped at 96 rays; beyond that the tail
  starts visible and the per-frame cursor catches up.
- **Cost when settled:** `cull_rate` (8) rays per frame and nothing else — gizmo
  writes happen only when a verdict actually flips.

Covered by 20 new harness tests (54 total), including the both-ends rule, grace in
both directions, cursor wrap, and the three interactions that would each have
silently un-culled the ribbon: HUD blank/restore, the save-load queue rebuild, and
a missing `ray_pick`.

**In-game A/B:** `iqm_pathline.debug_cull()` (F7 → Execute → "IQM: Path Cull
Toggle") flips culling and redraws the ribbon already up, so the same stretch of
ground can be seen both ways back to back.

### R2.1 follow-ups — open

| # | Question | Status |
|---|---|---|
| R2.1a | Does the both-ends approximation read acceptably? | **confirmed good in game (2026-08-13)** — F2's depth premise holds; the renderer question is closed |
| R2.1b | Is `cull_lift` = 0.25 m right? Too small and downhill stretches self-occlude on their own ground; too large and the ribbon shows over the top of low walls and crates | open |
| R2.1c | `cull_rate` = 8/frame against a ribbon of 15–25 points is a full sweep every 2–3 frames. Confirm that is fast enough when strafing past a doorway, and that 8 rays/frame doesn't show up in the frame budget alongside the card scanner (C3) | open |
| R2.1d | Grace is one-directional (200 ms to hide). Check it doesn't leave a visible tail hanging through a wall when you step behind cover | open |
| R2.1e | Terrain self-occlusion over distance: a ribbon crossing a shallow rise may cull the far side correctly (good) or strobe along the crest (bad). Worth walking a hill specifically | open |

### R2.2 — Routing · **built 2026-08-13, untested in game**

`gamedata/scripts/iqm_route.script` — coarse A* over the level graph, with an
offline harness (`tools/route-harness/harness.lua`, 30 tests).

**No engine path builder exists to borrow.** The whole `level` namespace exposes
the graph as data and nothing that searches it, and nothing in the modpack does
this either (Catspaw's Personal Adjustable Waypoint, the closest thing, does no
graph work at all). So: A* in Lua.

**Coarse probes, not `vertex_link`.** `vertex_link` is exact 4-way adjacency on
the 0.7 m grid — a 50 m disc is ~16000 cells and A* round a building can walk a
large fraction of them. `vertex_in_direction` covers metres per engine call
instead of centimetres. Safe because of how it is implemented: it steps node to
node along the line and stops where it cannot continue
(`level_graph_vertex.cpp:211-249`), so it **cannot tunnel through a wall**, and a
fully blocked probe returns the vertex it started from (`level_script.cpp:390-392`).

**The trick that makes coarse probing work in tight geometry:** a *truncated*
probe is a reliable "there is geometry this way" signal, so the short 2 m probe
is fired only in directions where the 8 m one could not run. Open ground stays at
8 engine calls per node; doorways get the resolution they need without paying for
it everywhere.

| # | Question | Status |
|---|---|---|
| R2.2a | Real A* cost | **resolved.** Measured in the harness on the hard case (50 m, round a wall, through a 1 m gap): **190 probes, 115 position reads, ~21 nodes expanded**. Open ground over 20 m: **34 probes**. Two orders of magnitude under the earlier worry |
| R2.2b | Does an 8 m probe squeeze through a 1 m doorway? | **resolved — yes**, via the truncation-triggered short probe above. Asserted by the harness, which verifies the route at 0.2 m resolution against the synthetic mesh so a route that jumped the wall between two legitimate nodes would fail |
| R2.2c | Frame budget + amortisation | **mostly resolved.** The search is resumable (`search_step(budget)`, 40 expansions/frame in the driver) and harness-verified to give the same answer sliced one node at a time. Given R2.2a the whole search fits in a frame or two anyway. Still wants an in-game confirmation alongside the card scanner (C3) |
| R2.2d | Actor or target off-mesh | **resolved.** `search_begin` refuses and reports `failed` when either end has no vertex — covers roofs, ladders and a target standing inside geometry. Harness-covered |
| R2.2e | Recompute triggers — actor drift off-route, target moved, level change | **resolved** — cursor-advance for walking, rate-limited repath for drift and goal movement, immediate for a new target, back-off on failure, and `on_level_changing` / `actor_on_first_update` drop the points outright. See R2.5; harness-covered |
| R2.2f | Level graph is the **AI** navmesh: no ladders/jumps, and it omits places the actor can walk but NPCs can't. Path will look wrong in a few spots | accepted |

Two more decisions worth recording:

- **Weighted A* (`h_weight` = 1.2).** A route only has to look sensible, not be
  shortest; the weight buys a materially smaller search.
- **String-pulling uses the probe, not a raycast.** "Can I walk straight from here
  to there" has to be answered by the navmesh — a route must follow ground, not
  line of sight, or it will cut across a railing or a drop that a ray sails over.

The output is coarse (the hard case reduces to **4 nodes** after pulling), so
`densify()` resamples each leg to the renderer's spacing before handing over; the
ribbon then snaps each point, which is what drapes it over ground that rises
between two nodes 8 m apart instead of cutting a chord through the hill.

**In-game test:** `iqm_route.debug_route()` (F7 → Execute → "IQM: Route To Aim
Point") routes from your feet to whatever you are aiming at and draws it
depth-culled. It runs the real budgeted search from the per-frame callback, not a
blocking convenience call, so what gets tested is the path the feature will use.

### R2.5 — The driver · **built 2026-08-13, untested in game**

`gamedata/scripts/iqm_nav.script` — the piece that joins the two halves, with an
offline harness (`tools/nav-harness/harness.lua`, 99 tests).

The split holds: `iqm_route` still knows nothing about quests, `iqm_pathline`
still knows nothing about graphs, and everything that needs both plus the marker
set lives in the driver. `iqm_core` gained exactly two public accessors —
`route_target()` (nearest tracked `role == "target"`) and `overlay_visible()` (the
PDA / HUD / reveal-hotkey gate every card already rides) — because both answers
were already computed there and would have been reimplemented, differently, in
the driver.

**Three gates, all of them about not being noise:**

| Gate | Rule | Why |
|---|---|---|
| Role | `role == "target"` only | One ribbon can be up at a time; a path that swings between a quest giver and a mechanic as you cross a hub reads as a bug |
| Band | `appear_dist .. route_dist` (16–50 m) | Below it the card is already up; above it this stops being "find them" and becomes cross-map navigation |
| Sight | target occluded | If you can see them the beacon is enough and a line to their feet is clutter |

The near edge is deliberately *not* its own option — it is `appear_dist`, so the
route and the card meet exactly and a user cannot open a gap or an overlap
between them.

**The visibility ray is the driver's own, not `iqm_core.has_los`.** That one
rides the `los_check` option (turning it off for cards would silently take the
route with it), needs `demonized_geometry_ray`, and caches per card on a path
that only refreshes *inside* `appear_dist` — which is precisely the band the
route does not operate in. One raw `ray_pick`, statics-only like the ribbon's own
cull, on the one NPC that matters. Grace is asymmetric the same way everything
else here is: losing sight brings the route up at once, regaining it must hold
for `VIS_GRACE` before the route comes down, so a glimpse through a doorway does
not tear it down and rebuild it.

**Keeping up (R2.2e), resolved.** Walking the route moves a *cursor* along the
existing points — a redraw, not a search — so the common case is one distance
test per frame and one `show()` every couple of metres. Searches happen only on:
a new target (immediate, ignoring the limit), the goal moving past `GOAL_TOL`
(3 m), or the actor straying past `DRIFT_TOL` (5 m); the last two are rate-limited
to `REPATH_MIN` (1.5 s), and a failed search backs off for `FAIL_COOL` (5 s)
rather than retrying every frame. The cursor scan looks **forward only**, which is
what turns backtracking into drift: walk back the way you came and the nearest
forward point recedes until it trips `DRIFT_TOL`. Scanning the whole array would
quietly follow you backwards and never notice you had left the route.

Two bugs the harness caught that in-game testing would have read as "feels
laggy sometimes" rather than as a defect:

- forgetting a target cleared the visibility *verdict* but not its *throttle*, so
  every change of objective inherited the old NPC's "asked recently" and sat at
  the default-visible verdict for up to `VIS_RATE` before the first search
- a `show()` landing on a frame where the PDA was open pushed the ribbon visible
  for one frame, because the blanking was only re-derived in the per-frame tick;
  `push()` now derives it itself

**Contention.** There is one ribbon and one search, and the F7 drivers in
`iqm_route` / `iqm_pathline` can both claim them. The search now carries an
`owner` (`search_owner()`), and both debug drivers raise a `debug_active()` flag
that parks the live route entirely until cleared — otherwise each driver finishes
the other's search and draws it as its own.

### R2.3 — Off-level targets

No game-graph edges, so no route. Fallback: point at the level changer heading that
way. Open: how to enumerate level changers on the current level cheaply — `CLevelChanger`
is a registered class (`class_registrator.script:23`, `se_level_changer`), and the PDA
map already renders their spots, so there may be a cheap registry to read rather than
walking the alife object list.

### R2.6 — First in-game session · **fixed 2026-08-13, needs re-testing**

Three reports: it draws, it is **slow to update**, and it **sometimes stops
showing**. Two of those turned out to be the same design mistake, and the third
was a units problem in the styling.

**"Sometimes stops showing" — two causes, both real.**

1. *The route was hiding itself exactly where it was needed.* The route only draws
   while the target is **out of sight**, and the ribbon was **occlusion-culled** —
   so the stretch that goes round the building, the only part that answers the
   question, was precisely the part being blanked. The feature was at its most
   useless in the case it exists for. Fixed with `cull_dim`: an occluded segment
   now switches to a darkened colour instead of vanishing. That keeps the depth
   cue and keeps the line, costs one extra draw call (the gizmo renderer batches
   by colour, so two colours is two batches however many segments), and needs no
   alpha — which matters, because the wire shader has blending compiled off and
   any fade-based treatment would have been inert.
   **This reverses the 2026-08-13 decision that the route must be strictly
   depth-respecting.** Kept switchable (`route_xray`, default on).
2. *Seeing the target destroyed the route rather than blanking it.* Every flicker
   of sight — a doorway, a passing tree, weapon sway — dropped the whole route,
   and getting it back meant a fresh search, which was rate-limited to 1.5 s. So a
   brief sighting could cost the better part of a second of empty screen. Now the
   visibility gate is a `suppress()`, the same mechanism the reveal hotkey and the
   PDA already used: geometry and cull verdicts are kept, the round trip is a pass
   of boolean writes, and losing sight again is instant.

**"Slow to update."** `REPATH_MIN` 1500 → 700 ms, `VIS_RATE` 300 → 200 ms,
`VIS_GRACE` 500 → 400 ms. The search can afford it — R2.2a measured the hard case
at ~21 node expansions, so the limit was never about cost, only about not
thrashing. On top of that, freezing (rather than dropping) a route while the
target is visible now clears the cooldown, so whatever went stale while you could
see them repaths on the very frame sight is lost instead of waiting one out.

**The look: a ribbon was the wrong shape.** Four rails spread over 70 cm reads as
four thin wandering lines with grass between them, not as a route. The renderer
has no line thickness — 1 px untextured wire — so spreading rails apart spends the
only tool available on *width* when what was wanted was *weight*.

So the rails are **clustered instead of spread**: three at 2 cm merge into one
bold, solid-reading stroke by a few metres out. That is the closest this renderer
gets to a painted line, and it needed no new code — `width` and `rails` already
did it, at a different scale. Direction is then carried by **chevrons** every 4 m,
lying flat on the ground and pointing the way to walk, the way a route is marked
on a military map. A chevron is two straight arms, which is exactly what a wire
renderer is good at; thickness comes from nesting a few copies 2.5 cm apart
*along* the path, so the arms stay parallel to themselves and the mark thickens
instead of smearing into a wedge.

Three styles ship (`route_style`): hairline, solid stroke, axis of advance
(default). Budget for the default at 50 m: ~25 points × 3 rails + ~12 chevrons ×
2 arms × 3 = **~150 of the 512 line cap**, so there is room to go bolder.

Both new controls are cycleable in place on the live route — **F7 → Execute →
"IQM: Route Style Cycle"** and **"IQM: Route X-Ray Toggle"** — because the only
honest way to judge a stroke against a hairline is the same stretch of ground
under each in turn.

### R2.7 — Second in-game session: it stopped showing entirely · **fixed 2026-08-13**

A screenshot settled it: beacon reading **9 m**, quest target round a corner, no
route. Two bugs, and the second explains the "*at all*".

**1. The near edge was the wrong number, and wrong in the one case that matters.**
It was `appear_dist` (16 m), on the reasoning that below it the card is up and
doing the job. But **the card needs line of sight, and the route only draws when
there is none** — so for a target behind a corner the card could not show and the
route refused to, across the whole band the feature was supposed to own. The gate
was a card-shaped answer to a question the card cannot answer.

There is no need for a card-shaped gate at all: whenever the card really is up the
target is visible by definition, and the visibility rule already blanks the route.
What is left is only "you are standing on top of them" — now a flat `ARRIVE_D` of
4 m, which also keeps the search out of the degenerate case where start and goal
collapse onto the same navmesh node. `iqm_core` no longer passes a near edge at
all, and the C1 note about the two features "meeting exactly" is withdrawn: they
overlap, and should.

**2. Suppression latched, permanently.** The blank lives in `iqm_pathline`
(`ext_blank`), but the distance-band check returned *before* the code that pushes
it. So walking from "target in view" (blanked) to "target too close" (band stop)
stranded the pathline suppressed with nobody left to release it — every route
after that was computed, drawn and invisible, for the rest of the session.
`reset()` could not clear it either, because the flag was in the other module.
Every write now goes through one `set_blank()` helper, and `undraw()` releases.

Mutation-tested: reinstating the old `undraw()` fails the two new harness
assertions, so the regression test actually catches the regression rather than
merely passing.

**Also fixed while in there:** a one-point search result was treated as a hard
failure and bought the 5 s `FAIL_COOL`. It is not the unreachable case — it is
start and goal collapsing just outside the arrival distance — so it now retries on
`REPATH_MIN`. Two steps back and it would have been a perfectly good route, and
waiting five seconds for it reads as the feature being slow.

### R2.8 — Third in-game session: moved off the wire renderer · **2026-08-13**

The route drew correctly and still looked wrong, and the report was the same two
words as before: laggy, and thin. Both trace to the renderer rather than to the
driver, and the fix was to stop using it.

**What `debug_render` could never do.** It is a 1 px untextured line list with no
alpha blending (settled facts, above). Three consequences, all of which were on
screen:

- **no line thickness**, so "bold" had to be faked by clustering rails 2 cm apart
  — which at close range is visibly three separate thin lines, exactly what the
  screenshot showed
- **no alpha**, so an occluded stretch could only pop between two solid colours,
  in batches of whatever the round-robin cull reached that frame
- **geometry is rebuilt wholesale**, so the route only updated when the actor
  crossed a route point — in 2 m steps, which is the "laggy"

None of these are tuning problems. They are the renderer.

**What was available instead, and was being overlooked.** The mod already ships a
textured, alpha-blended, rotatable sprite layer — the cards and the beacon — and
already ships the art for this (`iqm_circle`, `iqm_chevron`, `iqm_glow`,
`iqm_shadow`). Projecting route points onto that layer gives real thickness,
anti-aliased edges, per-sprite alpha, and — because it draws from the projection
every frame rather than from cached geometry — motion that is smooth instead of
stepped. The earlier R2.1 analysis had ruled out "projecting sprites via
`world2ui`" on the grounds that a screen-aligned billboard cannot lie flat on the
ground. True, and it turned out not to be the deciding factor: perspective is
carried perfectly well by **scaling each sprite with its distance**, and a
receding line of beads reads as a path running away from you without any of them
being flat.

**The shape now.** `iqm_nav` publishes a list of world points with a per-point
`chev` flag and a per-point alpha; `IqmCards:draw_route` projects them and draws
one sprite each. Three styles: beads, chevrons, beads with a chevron every third
(default). Two fixed sprite pools rather than one with a per-frame `InitTexture`,
because a point is either a bead or a chevron and never both — so no widget's
texture ever changes and the hottest path in the mod never touches one.

**Occlusion became a fade.** Per point, eased with a 90 ms time constant toward
the ray's verdict. The round-robin still spreads the ray cost over frames, but
what lands on screen is a fade rather than a batch of segments flipping together.
This is what `route_xray` now controls: occluded points ease to 22% alpha, or to
zero with it off.

**And the blanking bug class is gone entirely.** Not drawing is now simply not
publishing — there is no flag held in another module that an early return can
strand. Both of the R2.7 failures were instances of that shape.

`iqm_pathline` is no longer used by the route. It stays as the prototype and for
its F7 tools, which is what it was built as.

### R2.9 — Fourth in-game session: the range model was backwards · **2026-08-13**

Two reports. One is a look note; the other is the design being wrong in a way that
had survived four revisions because every fix had been aimed at the wrong end of it.

**"It only shows when close to the target."** Correct, and that was the design:
`route_dist` gated *how near the target had to be* before anything drew at all. So
the route appeared once you had essentially already found them — exactly when it
was no longer needed — and was absent for the whole approach, which is the only
part of the journey a route is for. The near-edge fix in R2.7 was the same mistake
at the other end of the band, and fixing it there did not prompt the obvious
question about the far edge.

**The range model is now inverted.** There is no target-distance gate: the route is
drawn whenever there is an objective on this level. What is limited is **how much
of it you get**, measured along the path **out from the player** — a target 200 m
away still gives you the next 40 m of ground; you simply cannot see the whole way
there. `route_dist` is now "route drawn ahead". The only remaining far limit is
`MAX_TARGET_D` (350 m), and that is a *search-cost* guard, not a design one; in
practice GAMMA's 450 m switch distance means a target further off is offline and
never offered anyway.

This retires the "proximity only, must not make the game materially easier"
constraint for F2, deliberately. Showing the next stretch of walkable ground is not
a waypoint: it never tells you where the destination is, only which way the ground
goes, and it runs out long before you get there. That is a weaker aid than the map
marker the game already gives you.

Also relaxed: the **visibility gate now only applies inside `VIS_NEAR` (25 m)**.
Being able to make out a figure across a field says nothing about how to walk
there, so suppressing the route on line-of-sight alone was wrong at range; up close
it is still right, because the marker over their head says the rest.

**"Remove the circles, use thicker chevrons in army green."** Done, and it needed
new art rather than a scale factor:

- **A dedicated glyph.** The beacon's `iqm_chevron` is a tabler icon at
  stroke-width 3, drawn once at badge size where a fine line reads as precision.
  The route draws a dozen marks at 5–44 px, so `routearrow.svg` carries
  stroke-width 5.5 and a shallower, wider spread, which keeps the two arms
  distinguishable instead of merging as it shrinks. It also **skips the atlas
  distress pass** (new `NO_DISTRESS` set in `build.py`) — at that scale the chips
  and cracks are the same size as the stroke, so a worn route arrow reads as
  speckle rather than as wear. The atlas grew to a 4x4 grid; rows 0–2 kept their
  pixel coordinates, so no existing texture id moved.
- **Its own colour**, army green (134, 152, 86), not the accent gold the cards and
  beacon share. Different kind of object: a marker is read once at a glance and
  wants to stand out, while the route is a dozen marks you walk along and live
  with, so it wants to sit in the scene. Exposed as three MCM tracks, since "army
  green" is a matter of taste.
- **Beads gone.** A round dot says "the path is here", which the arrows already
  say, and at 4 m spacing the two mark types crowded each other. One mark type also
  halves the widget pools and removes the only place the two contradictory UI_KX
  sizing rules both had to be implemented.

**One real bug found while doing it.** Moving the route off `iqm_pathline` (R2.8)
silently dropped its `snap()` call, which pulled every interpolated point onto the
navmesh. The A* answers in nodes up to 8 m apart and `densify` interpolates
straight lines between them, so without it a route crossing a rise or a dip floats
above or sinks below the ground it describes. Nothing about the symptom says
"snapping" — the marks just sit slightly wrong on slopes — so it is the kind of
thing that would have been lived with. Now in `iqm_nav.snap_path`, with the path
sampled at 1 m (arrows are then spaced by *arclength*, not by point index, so they
stay evenly spaced however unevenly the legs came out).

New F7 tools, replacing the style cycler: **"IQM: Route Spacing Cycle"** (2/3/4/6/8
m) and **"IQM: Route Length Cycle"** (20/30/40/60/80 m), both rebuilding the live
route in place.

### R2.10 — Fifth session: the route was being thrown away, not gated · **2026-08-13**

"It's not showing until I run right up to the target and then walk away from them."

Every previous round of this assumed a **gate** was closed and went looking for one.
This time it was the search: `iqm_route` gave up at `max_nodes` and returned
**failure**, discarding the path it had already found. So a distant target produced
nothing, while a close one — a short search that finished inside the budget — worked.
Walking up to the target and back is precisely the sequence that turns the second
case into the first, which is what made the symptom look like a range gate.

`max_nodes` was 1200, chosen when the route was capped at 50 m. A 200 m target needs
more expansions than that, and `route_dist` no longer bounds how far the *search*
has to reach (R2.9) — only how much gets drawn. So the budget started biting on
exactly the routes the R2.9 change had just made possible.

**The fix was already half-written.** `consider()` has maintained `S.best_vid` —
the closest node reached — since the first version, with a comment saying it is
"what a budget-exhausted search reports instead of nothing at all". It was never
wired up. Now on `max_nodes` the search rebuilds from `best_vid`, string-pulls it,
and returns `"done"` with `search_partial()` true. For a caller that only draws the
first 50 m, a path that stops short is indistinguishable from a complete one.

The budget is also scaled by distance now (`400 + 10·d`, capped at 4000), so the
partial reaches further before it runs out.

**A semantic change worth owning:** a genuinely unreachable goal reaches `max_nodes`
before it exhausts its frontier, so it now returns a partial too rather than
failing. I had intended to keep those cases apart and the route harness proved I
could not — the sealed-door test went green as `"done"`. On reflection that is the
better behaviour: being walked up to the building whose interior the AI mesh does
not cover is useful, and the beacon still marks where the target actually is. A
partial is always a real walkable path, so it can never cut through the geometry
that stopped it — the harness asserts exactly that.

**And the F7 dump now says why there is nothing.** Five sessions were spent guessing
which condition was closed, because `status()` could only report the symptom. It now
carries a `why` string naming the gate — `option off`, `no objective target`,
`arrived`, `target beyond the sanity ceiling`, `target in plain sight, up close`,
`searching`, `waiting out a search cooldown`, `drawing`, `drawing (partial route)`.
Seven of those are pinned by harness tests, each one a guess from a previous round.

**The two look notes, both defaults:**

- *Too sparse* → arrow spacing 4 m → **2 m**, and the sprite pool 24 → 28 so the
  full 50 m fits at that spacing (26 marks). The F7 spacing cycler now runs
  1.5/2/3/4/6 m rather than starting at 2.
- *Start from the player, extend 50 m* → `route_dist` 40 → **50**. It already
  started at the player (`path[1]` is the actor's own snapped position and the cursor
  keeps it there); the reason it did not look that way was the missing route from
  R2.10's first paragraph.

### R2.11 — Sixth session: spaced marks abandoned for a continuous stroke · **2026-08-13**

"Even with 2 m spacing it's not enough to indicate a path. Perhaps we should use a
line instead?"

Yes — and the mark design had now failed at 4 m (R2.9) and at 2 m (R2.10), which is
enough evidence that the problem was not the spacing. A run of separate glyphs says
"here are some points on the way"; the joining is left to the eye, and at a
distance, at low contrast, over broken ground, the eye does not do it. It is also
the wrong shape for the reference the look was drawn from in the first place: an
army map marks an axis of advance with one continuous stroke.

**What made this possible.** The route draws on the card/beacon sprite layer, which
was assumed to be billboards only — and mostly it is. But a heading-rotated static
does NOT have to be square (see the new Settled entry above): with `stretch="1"` the
window rect's width and height pass straight through, corners are built in local UI
units, and rotation happens *before* the aspect scale, so a strip rotates rigidly
and its ends can be landed on two arbitrary UI points. The mod's own leader line has
been doing exactly this since the first version. So a segment of the route is one
quad stretched between two projected path points, and the "route" is a run of them.

No new artwork: `iqm_white_box` is solid opaque white for well past the rect the
strip samples (checked texel by texel, including the half-texel-offset column the
engine's UV maths actually reaches), so the ends butt with no feather and the stroke
reads as continuous rather than dashed.

**Vertices moved from "evenly spaced" to "where the path bends."** For a set of
marks, even spacing was the whole point. For a line it is meaningless — a line's
vertex spacing is invisible and only its shape is not — so `build_draw_list` now
emits a vertex when the path has turned enough (`TURN_TOL`, accumulated as `1 - cos`
so no `acos` lands on the rebuild path) or when `SEG_MAX` = 4 m have passed. Corners
get vertices; straights stay cheap at 4 m instead of the path's own 1 m sampling.

Two details in that which are easy to get wrong and were:

- **The bend is at `path[i-1]`, not `path[i]`.** The turn is only detectable once the
  next leg's direction is known, so the naive `emit(i)` puts the vertex a full
  `PATH_STEP` past the corner and lets the chord from the previous vertex cut across
  it — through a doorway, that is the stroke crossing the jamb. Caught by the new
  bend fixture, which fails three assertions if it is reverted.
- **`SEG_MAX` has to be checked BEFORE overshooting.** Tested after the fact it is a
  threshold rather than a maximum, and since the path's legs are `PATH_STEP` long an
  overshoot of nearly a full metre is the normal case, not an edge one.

**Chevrons survive, on the stroke.** The one thing a plain line cannot tell you is
which way along it to walk, so chevrons ride on flagged vertices every `gap_m` of
arclength (default 10 m, was 2 m when they *were* the route). `route_gap`'s MCM range
moved from 2–8 m to 6–30 m accordingly, and the accumulator starts half a gap in debt
so the first one lands ~5 m out rather than a full 10 m out.

**The near end is now clipped rather than dropped.** Vertex 1 is the actor's own
feet, which in first person sits under the camera at essentially zero forward
distance — on or behind the near plane — so its projection fails on nearly every
frame and the first segment used to be discarded. That is the "it doesn't start at
the player" complaint in a different form, still present after R2.10 addressed the
other half of it. The straddling segment is now sampled on a fixed grid for the
nearest point that still projects; a grid rather than a bisection because the exact
clip point sits ON the near plane, where the perspective divide sends UI coordinates
towards infinity.

**One ordering subtlety worth keeping.** Every segment's dark outline copy is created
ahead of every segment body, not interleaved per segment. Widget draw order is fixed
at creation, so interleaving would let segment 3's outline draw over segment 2's
body wherever they overlap at a joint, and the stroke would come out with a dark
notch at every bend. Segments are also deliberately extended by their own thickness
so consecutive ones overlap by half a width — butted exactly, a bend leaves an open
wedge on the outside of the turn.

**And the chevron budget moved into `iqm_nav`.** The renderer capping its own pool
looked fine and was not: at the MCM's tightest spacing over the longest draw the
count reaches 20, and a pool of 10 would have silently dropped the far half's
chevrons. Caught by the harness. The cap now lives where the flags are set, so the
flags and the pool cannot disagree.

### R2.12 — The stroke shipped broken: the whole mod stopped loading · **2026-08-13**

"Now nothing from IQM is working."

Not a route bug: `iqm_core` had stopped loading altogether, so the cards and
beacon went with it. From the log —

    iqm_markers.script:2909: main function has more than 200 local variables
    ! [ERROR] --- Failed to load script iqm_markers

The route rewrite added nine top-level locals to a file already sitting at the limit.
Full mechanism, including the two locals the engine prepends that make the real
budget 198, in the new Settled entry above; the fix was to collapse the route's
constants, style mirrors and projection scratch into one `RTE` table, which freed 21
slots and left 18 spare.

**Why the pre-flight check missed it, which is the part worth keeping.** The check
was `luajit -bl` over each file, and it was clean. Two things were wrong with that,
one of which is not the obvious one:

- **It compiled the wrong source.** The engine prepends `file_header` before loading,
  so the game compiles the file plus two locals. Demonstrated directly: with 19
  padding locals added, the bare file compiles and the header-wrapped one is
  rejected. That two-local gap is the entire blind spot, and it is exactly where the
  file sat.
- **It was a different build from the game's.** Not the cause here — the local LuaJIT
  enforces the same limit — but the local one is 2.1 where the game ships 2.0.4, a
  separate branch, so it was never quite the right thing to be asking. (Establishing
  which Lua the game actually runs took its own detour, recorded in the Settled entry
  above; a first pass wrongly concluded PUC 5.1 from the error message alone.)

Both are now closed by `tools/check-lua.py`, which compiles what the engine compiles
under the Lua generation the engine embeds, and runs all four harnesses under it too.

The wider lesson is about the shape of the verification, not the tool: every harness
in this project tests *behaviour*, and none of them could have caught this, because
the module never got as far as running. A load-time check has to model the loader.

### R2.13 — Seventh session: the stroke was screen-space, not ground-space · **2026-08-13**

"The lines look ghastly."

With a screenshot, which is what made this diagnosable rather than a matter of taste.
Three separate faults, and only the third is a tuning question:

**1. The thickness never described the ground.** `place_seg` was handed one number,
`route_w * REF / d` clamped to `WMAX` = 22 px. Two things follow, both visible in the
shot:

- Inside about 3.8 m the clamp is always in force, so the near end is a *constant
  width bar*. There is no convergence at all in the bottom half of the frame, which
  is why it read as a stripe painted on the monitor rather than on the floor. The
  clamp existed to stop the near end swallowing the screen — i.e. it was fighting
  the perspective the same formula was trying to express.
- `w/d` is the apparent size of something *facing* the camera. A ribbon lying on the
  ground is not: its width runs along the ground plane, so it is foreshortened by the
  grazing angle, and the amount depends on which way the path runs. A stretch crossing
  left-to-right in front of you should be much thinner than one running away from you
  at the same distance. The old formula gave both the same thickness, and no amount of
  tuning `route_w` could have fixed it, because the error is not in the scale.

**The fix is to stop computing the thickness and start measuring it.** The ribbon's two
edges are real world positions — the segment midpoint ± the XZ perpendicular × half the
width — so projecting *those* and taking the perpendicular component of their separation
gives the on-screen thickness that the geometry actually has. Every perspective cue
comes out of that for free and correct: convergence with distance, foreshortening at a
grazing angle, and the widening of a path that crests a rise toward you. Two extra
projections per segment, no new widgets, no art.

It also means the width is now a **world** quantity, so `route_w` changed units from
px-at-12 m to centimetres of ground (default 45). That is not cosmetic churn: once the
thickness is measured, "thickness in pixels at 12 metres" no longer names anything the
renderer uses, and a knob that describes nothing is worse than a renamed one. The old
default of 7 px at 12 m works out at about 11 cm of ground — a hairline, not a path,
which is another way of saying the clamp had been doing all the visible work.

`WMAX` survives at 96 px as a sanity ceiling on a bad projection, not as a look control.
The `EDGE` outline now scales with the thickness (`th * 0.28`, clamped 1.5–6 px) —
a fixed 2 px keyline is invisible on a 90 px near segment and dominates a 3 px far one.

**2. The segments were 4 m of world, so they were megapixels near and sub-pixel far.**
`SEG_MAX` was a constant, which spends the widget budget in inverse proportion to how
much of the screen each widget covers. It is now `distance / SEG_DIV` (7), clamped to
1–5 m, so every segment subtends roughly the same *angle* — about 8°. A 50 m route comes
out as a ramp of 1 m segments at the near end through to 5 m at the far, which is the
same budget spent where the eye can use it.

`SEG_DIV` is a budget decision as much as a look one, because it fixes the *ratio*
between neighbouring segment lengths as well as their angular size. Thickness goes as
1/distance, so that ratio is also the thickness step across a joint: ~14% at 7, covered
by the half-thickness overlap the renderer already draws. The floor is 1 m because
`PATH_STEP` is 1 m — below that there is no intermediate point to cut a segment at, so a
smaller floor would buy nothing.

The vertex cap rose 28 → 36 (`MAX_DRAW`, and `RTE.SEGS` with it). Measured in the
harness: 24 vertices for the default 50 m, 30 for the 80 m the MCM allows, 31 for 80 m
round a right angle. At 28 the far end of a long route would have truncated, which is the
"breathing far end" bug R2.11 fixed once already. `SEG_DIV` = 8 was tried first and did
not fit. Corner emission (`TURN_TOL`) is unchanged and still runs ahead of the spacing
rule — a doorway gets its vertex on the jamb regardless.

**3. The near end is now trimmed rather than started at your feet.** `NEAR_TRIM` = 3 m
of path is skipped in front of the camera, bounded to 40% of the drawn length so a short
route is not eaten. This reverses R2.11c, deliberately: with honest perspective a 45 cm
ribbon one metre from the camera genuinely *is* a slab across the screen, and every
attempt to make it start at your feet was fighting that. Car HUD navigation starts the
ribbon past the bonnet for the same reason. `clip_front` is kept as a safety net but
should now almost never fire.

**What is NOT in this change**, having been proposed and deferred so the three above can
be judged on their own: smoothing the polyline (the A\* still turns in 45° steps), a
soft-edged stroke texture in place of the solid fill and hard keyline, flowing dashes,
and thinning occluded stretches as well as dimming them. See the new follow-ups.

**Untested offline.** (1) lives in `iqm_core`, which has no harness — the maths is a
projection, and stubbing the engine's projection would be testing the stub. (2) and (3)
are in `iqm_nav` and are covered: the adaptive rule, the trim, and the interaction with
the vertex cap and the chevron budget are asserted in `tools/nav-harness`, and the older
fixtures that asserted a 4 m ceiling and a stroke starting at `x < 1` were updated rather
than relaxed.

### R2.14 — Eighth session: smoothing what R2.13 left · **2026-08-13**

"OK it's looking better. Still needs to be much smoother."

With a second screenshot, of a straight run down an alley. R2.13's perspective is
working — the band converges, the near end is trimmed, the foreshortening is right — so
what is left is finish rather than geometry. Four things, three of them visible in that
shot and one that only shows at corners.

**1. Dark ticks across the stroke at two of the joints.** Not aliasing: geometry. The
halo copy was drawn `edge` px LONGER than the body it backs, so its end cap stuck out
past the body at every joint. Worse, the halo is also `edge` px WIDER on each side, and
neighbouring segments differ in thickness by only the `SEG_DIV` ratio (~14%) — so the
farther, thinner segment's halo was routinely wider than the nearer segment's body and
protruded along the overlap as well as past the end of it. At `EDGE` = 0.28 of a 40 px
thickness that is a 6 px dark shoulder against a 2.8 px step; it could not have looked
like anything but a notch.

Fixed three ways at once: the halo no longer overruns the body's length, `EDGE` came down
to 0.16 (with the px clamps to 1.25–5) so it stays inside the thickness step over most of
the range, and the feather below turns whatever is left into a gradient rather than an
edge. If ticks ever come back, the next lever is a round join — a disc at each interior
vertex, drawn between the halos and the bodies.

**2. The long edges were hard and aliased.** The stroke sampled `iqm_white_box`, a solid
opaque region, so its edges were a step function and stair-stepped along their length. It
now samples a new asset, `iqm_stroke` (`tools/stroke-tex/build.py`): horizontally uniform
so a segment still stretches to any length and butts cleanly against the next, and
vertically an alpha ramp — opaque core, smoothstep feather to zero at the two long edges.
Because a segment's rect HEIGHT *is* its thickness, that ramp lands exactly on the edges.

The feather is a fraction of the thickness (0.11) rather than a pixel count, which is
worth stating because it looks like the wrong choice. Nothing in the UI layer can express
"2 px of this rect", and proportional turns out to be what you want anyway: a far segment
2.5 px thick samples only rows inside the opaque core and stays crisp, while a near
segment 90 px thick gets a ~10 px shoulder — which is what a band of paint on wet
concrete looks like, and is exactly where the hard edge aliased worst. The halo copy
samples the same texture at a larger rect, so the outline became a soft glow for free: no
second asset, and its softness tracks the stroke's weight automatically.

**3. The near end stopped dead.** R2.13 trimmed the stroke to start 3 m out, at full
strength, so a wide band was cut off square across the bottom of the frame. There is now
a head fade mirroring the tail one (`HEAD` = 0.14 of the run, up from `HMIN` = 0.10), on
segments and chevrons alike, so the route rises out of the ground under you.

**4. The path itself still turned in 45° steps**, which the alley shot cannot show and
every corner can. `iqm_route.smooth` is Chaikin corner cutting over the coarse node list,
run before `densify`, with two things that are not in the textbook form:

- **The cut is capped in METRES, not taken as a fraction of the leg.** The legs here are
  8 m probes and string-pulled spans of up to 24 m, so the classic 25% would cut a corner
  by six metres. The walkability veto would pass it — open ground is open ground — but the
  drawn route would visibly ignore the corridor it exists to describe. At `SMOOTH_CUT` =
  1.5 m the arc leaves the true corner by `cut · |u + v| / 2`: ~1.06 m at a right angle,
  ~0.57 m at the 45° kink the probes actually produce.
- **A navmesh veto on the CHORD, not on the cut points.** Checking that the two generated
  points stand on walkable ground passes the doorway case and cuts through the wall
  anyway: at a corner turned in a 1 m gap, both points sit in open floor either side of
  the opening and the new leg between them crosses the jamb. The test is
  `level.vertex_in_direction` from one to the other — the same primitive `string_pull`
  uses, for the same reason — and a corner whose cut fails keeps its original vertex. Both
  halves are fixtures in `tools/route-harness`; the first version of the veto shipped the
  point-only check and the doorway fixture caught it immediately.

Two measurements that changed a decision. **Passes matter and `PATH_STEP` does not:** the
drawn arc can only bend where the smoothed node list bends, since `densify` merely
resamples the straight legs between those nodes. Halving `PATH_STEP` to 0.5 m was tried
first and moved the worst joint at a right angle not at all (0.207 both ways); going from
two smoothing passes to three took it to 0.107 (~26°), and the 45° kinks to ~0.06. So
`smooth` defaults to three passes and `PATH_STEP` stayed at 1 m. **Vertex cost:** 24 → 26
vertices for a 40 m route with a right angle in it, 33 for 80 m with one — still inside
the `MAX_DRAW` of 36 that R2.13 set.

One harness lesson worth keeping: **1 − cos does not add.** The first version of the
"turn is distributed" assertion summed the per-joint figures and expected ~1.0 for a right
angle; four 22° bends sum to 0.30, not to the 1.0 of the single fold they replace, so the
check failed on correct output. It now measures the heading change from the leg entering
the corner's neighbourhood to the leg leaving it.

### R2.15 — Ninth session: the smoothing was being re-corrugated by the snapping · **2026-08-13**

"It's better but still looks pretty bad. What about if we used bigger arrows/chevrons"
— with a screenshot of the route staircasing across a yard, and a Cyberpunk 2077
reference of large ground chevrons filling a lane.

**The staircase was `snap_path`, not the router.** From the engine source:

```cpp
// level_graph_inline.h:63-70 -- vertex_position's plan coordinates
x = float(_x) * header().cell_size() + header().box().min.x;
z = float(_z) * header().cell_size() + header().box().min.z;
// ...and line 88, its height
dest_position.y = (float(source_position.y()) / 65535) * header().factor_y() + box().min.y;
```

A node's **x and z are quantised to the AI grid** (0.7 m on Anomaly's levels); only its y
is a fine value. `snap_path` wrote all three, so every route point was slammed onto a grid
intersection, and a line at a shallow angle to that grid alternates between adjacent rows
— a sawtooth of up to a node's width, several times the stroke's own thickness. With
`SNAP_MAX_XZ` at 1.5 m a single point could be yanked over a metre sideways. The
occasional hook in the same screenshots is the same cause: where the nearest node to point
*i* sat slightly behind point *i−1* along the path, that segment reversed, and the
half-thickness overlap turned the reversal into a lump.

So every bit of R2.14's Chaikin smoothing was being undone one stage later. **Snapping now
takes the height only.** The XZ test survives with a different job — it no longer decides
where the point goes, only whether this node's height can be trusted for it — and is
tightened to 1.2 m, since half a cell diagonal on the 0.7 m grid is ~0.5 m.

The cost of the fix is a height taken at the node's centre rather than at our own x,z:
`vertex_plane_y(vertex, X, Z)` exists in C++ (`level_graph_inline.h:214`) but is **not**
bound to Lua — `level_script.cpp:2438-2455` exposes only `vertex_position`,
`vertex_in_direction`, `vertex_link` and the cover pair. That is a few centimetres of
error on ordinary ground and up to ~0.2 m on a steep ramp, against 0.7 m of lateral
sawtooth for the old version. A downward `ray_pick` per point is the exact alternative if
slopes ever look wrong: ~50 rays, once per search.

Note `iqm_pathline.snap` (the retired wire renderer) still snaps in XZ. It is prototype
code that nothing on the live path calls, and its harness asserts the old behaviour, so it
is deliberately left alone — but it has the same flaw, and anything reviving it should
port this fix first.

**The head fade was hiding the first six metres.** R2.13 trimmed the stroke to start 3 m
out and R2.14 faded its first `HEAD` = 0.14 *of the vertex list* up from `HMIN` = 0.10.
But with angle-based spacing the near vertices are the SHORT ones, so 14% of ~24 vertices
is about the first 3 m of path — at as little as a tenth of the stroke's alpha, on top of
the trim. Measured off the screenshot, the visible near end sat 8-9 m out rather than 3.
The fade is now in **metres of camera distance** (2 m, from the nearest drawn vertex) with
the floor raised to 0.35. A distance is also the honest variable: what wants softening is
the stroke's arrival at the near plane, which is a fact about the camera rather than about
how many vertices the route happens to have.

**On bigger chevrons — the arithmetic says no, but the look is still reachable.** A
chevron lying on the ground, seen from eye height *h* at distance *d*, is compressed along
the view direction by ≈ *h/d*: at 12 m with a 1.7 m eye height that is **7:1**. Our
chevrons are billboards, so they draw it uncompressed. At 20 px the eye reads them as
marks and forgives it; scaled up, they read as placards standing out of the path, and the
error grows with the size. This is the same class of mistake R2.13 fixed for the stroke's
width, and no amount of `route_size` will fix it.

The reference look needs **ground-space** chevrons — and a chevron is two straight arms,
which is exactly what `place_seg` draws (world endpoints, measured thickness, feathered
texture, halo). `iqm_pathline` already computed chevron arm geometry in world space
(`arrow_len` / `arrow_wide` / `arrow_bold` and the `perp` helper); that is the template.
Cost is 4 statics per chevron against 2 now. Three options, costed for a 40 m draw:

| | Design | Statics |
|---|---|---|
| A | Keep the stroke; ground-space chevrons, bigger and sparser (8-10 m) | 52 + ~20 |
| B | Drop the stroke; dense ground chevrons only, 2.5-3 m apart — the reference | ~52 (cost-neutral) |
| C | Thin base stroke + dense ground chevrons on it — what the reference actually has | ~70 |

B looks like re-litigating R2.9/R2.10, where spaced marks failed twice. It is not the same
design, and the difference is exactly why those failed: they were small screen-space glyphs
with ground visible between them, so the eye had to do the joining. The reference's
chevrons are large, ground-locked and nearly touching — they read as one continuous band
that happens to be made of arrows. Undecided; recorded as R2.15c.

**Also worth trying before any of that:** the colour. The reference is a bright saturated
yellow on dark asphalt with bloom; ours is a desaturated army green at 84% alpha on
mid-grey concrete of almost the same value, which reads as a smear whatever the geometry
does. The MCM already exposes route R/G/B and opacity, so this is tunable without code.

### R2.16 — Tenth session: chevrons moved into ground space, and became the route · **2026-08-13**

"Smoothing is looking better." — with a shot in which the stroke reads as one continuous
path, the corners are arcs, and the chevrons are now the loudest wrong thing in the frame:
the near one standing upright facing the camera, wider than the ribbon it sits on, while
the ribbon around it lies correctly on the floor. Exactly what R2.15's arithmetic
predicted; it was simply hidden while the line itself looked rough.

Asked to choose between the three designs, the answer was "make sure we can revert easily
if it's not correct" — so all three ship, selectable, with the pre-R2.16 look intact as one
of them.

**Chevrons are now drawn as two ground segments.** A chevron is two straight arms, and a
straight arm between two world points is what `place_seg` already draws — so
`IqmCards:place_arms` builds the tip and the two back corners in world space, projects
them, and hands each arm to the same machinery the stroke uses: thickness measured from
its own ground edges, the feathered cross-section, the soft halo. The mark is therefore
genuinely flat, and foreshortens with the view instead of standing out of it.

Arms are appended to the SEGMENT pool rather than given one of their own. They are
segments in every respect; the draw order that puts all halos behind all bodies is already
right for them; and taking the slots after the stroke's is what draws the mark ON the line
rather than under it. `RTE.SEGS` is therefore 36 (the stroke's `MAX_DRAW`) + 32 (two arms
each for 16 chevrons) = 68.

**Chevron placement moved off the vertices.** They used to be flags on the vertex list
(`rd.c[i]`), so a chevron could only ever land ON a vertex — fine at 10 m spacing, useless
at 3 m, where vertices 1-5 m apart would scatter them by up to half a gap. `iqm_nav` now
publishes them as their own list (`cp` / `cdx` / `cdz` / `ci`), placed at exact arclength
and interpolated onto the leg they fall on. The harness asserts the spacing to a
centimetre now, where it could only assert 8-14 m before.

**Three whole designs, not a pile of knobs** (`route_style`, and an F7 cycler that brings
each design's spacing with it):

| Style | What | Statics |
|---|---|---|
| `classic` (0) | The pre-R2.16 look: the 45 cm stroke with screen-facing chevrons every 10 m | as before |
| `band` (1, default) | A 30 cm stroke with ground chevrons every 3 m — the reference's arrangement | 36 + 32 |
| `arrows` (2) | No stroke at all; the dense run of ground chevrons IS the route | up to 32 |

The fourth arrangement worth having — a wide stroke with sparse ground chevrons — is
`band` with `route_w` and `route_gap` turned up, so it needs no style of its own.

`route_gap`'s default moved 10 → 3 and its range 6-30 → 2-30, with one meaning for every
style. That does mean `classic` at the default spacing is denser than the look it
reproduces: **`classic` with the gap at 10 is the exact pre-R2.16 route**, and the F7
cycler pairs them for you.

Worth being explicit that this is the *third* answer to "what does the route look like",
and it reverses the R2.11 decision that a continuous stroke should carry the path while
chevrons only say which way along it. It is not a re-run of R2.9/R2.10, where spaced marks
failed twice: those were small screen-facing glyphs with ground visible between them, so
the eye had to do the joining. These are large, ground-locked, and nearly touching at
distance. If it fails anyway, the note above says exactly which two settings undo it.

`MAX_CHEV` came down 22 → 16 and now binds routinely rather than only on a hand-edited
config: at 3 m spacing a route drawn past ~48 m stops getting chevrons, where the tail fade
has them at a third of their alpha in any case. Each one costs two widget pairs, which is
what makes it a real budget.

### R2.17 — Eleventh session: the chevron's own ends were the last hard edges · **2026-08-13**

"It's actually pretty good if we could smooth it further?" — with a close shot of the
`arrows` style, in which the marks lie correctly on the floor and every one of their five
ends is a square cut.

**Two of those cuts were a bug, not a limit.** `place_seg` extends a strip's length by its
own thickness so consecutive stroke segments overlap and a bend has no open wedge on the
outside. An arm has no neighbour to overlap: applied to one, the same extension overshoots
the outer end into mid-air and — at the chevron's point — pushes both arms half a thickness
PAST the tip, where their two square ends cross into a blob. That blob is what read as
blockiness. Arms are now drawn at exact length (`place_strip`'s `exact` flag, which is the
only difference between how a stroke segment and an arm are laid out).

**The remaining three are what a rectangle is.** So the arms stopped being rectangles:
a second texture, `iqm_arm`, carries the same cross-section feather as `iqm_stroke` plus a
taper along its LENGTH — a short ramp at the point (u = 0, enough to soften the seam where
the two arms cross without blunting the point) and a longer one at the outer end (which
turns a cut into a brush stroke). The stroke itself must never have that taper: a segment
butts against the next one and a longitudinal fade would open a gap at every joint. Same
build script, one more call.

That taper is also why arms now have a widget pool of their own rather than sharing the
stroke's, which R2.16 had just finished arranging: a widget's texture is fixed when it is
created. Being created after the stroke's widgets still puts them on top of the line.
Pools are now 36 stroke + 32 arms + 16 billboard chevrons = 168 statics allocated.

**And a tuning pass**, because the geometry was sized before anything was drawn flat:
arms 0.28 → 0.22 m thick, the mark 1.30 → 1.15 m across and 0.95 → 0.85 m long. The head
fade went 2 → 3.5 m and its floor 0.35 → 0.30: with ground chevrons the nearest mark is
the biggest thing on screen by a wide margin, and the fade is the only lever that holds it
back without shrinking the mark at every other distance too.

One thing that turned out not to be a bug: the screenshot had no line threading the
chevrons because it was the `arrows` style, not the default. The F7 cycler starts on the
design in force (`band`), so its first press lands on `arrows` and the third comes back —
worth knowing before reading anything into a shot.

### R2.18 — Twelfth session: a solid apex, and a lighter green · **2026-08-13**

"That is pretty good. Can we make the green lighter, and maybe move the two lines closer so
they overlap at the tips forming a more solid triangle" — with a close crop of one chevron
on yellow sand, in which the apex reads as two bars meeting rather than as one arrowhead.

**The apex needed geometry, not less gap.** Two rectangles sharing an endpoint at an angle
leave a wedge open between their end cuts however exactly they are placed, because the
corner that would fill it lies outside both. R2.17 had just removed the length extension
from arms — correctly, since it was overshooting the point — and the exact-length version
is what exposed the wedge underneath. The fill is the standard mitre: for arms whose axes
each make an angle *a* with the bisector, the two outer edges meet on the bisector at
`(th/2) / sin a` from the point, so extending each arm PAST the point by `(th/2) / tan a`
closes it. `tan a` is `hw / hl` straight off the mark's own geometry, so the overlap tracks
`alen` and `awide` instead of being a constant that has to be re-tuned with them.

`place_strip` grew an `over` argument for this: extend the A end only, which for an arm is
the point. It is not the same thing as the stroke's symmetric overlap, and conflating the
two is what made R2.17's tips blunt.

**And the tip taper came off** (`ARM_TIP` 0.14 → 0). It was added in R2.17 to soften the
seam where two arms cross, which was the right instinct and the wrong tool: fading the arms
exactly where the mark should be strongest is what left the apex looking hollow. The mitre
overlap hides the seam with geometry and leaves the point at full alpha. The tail taper
stays — that one is the reason the texture exists.

**The green.** (134, 152, 86) was chosen against the *idea* of the Zone rather than against
its ground, and the ground it is drawn on — wet grey concrete, the Garbage's yellow sand —
sits at almost the same value, so the route read as a stain rather than as a marking. Now
(176, 196, 124): the same olive cast, lifted clear. The MCM's three tracks were always the
authority here, so this is a default change and nothing else — **anyone whose config has
already saved the old values keeps them**, which is exactly why the colour also got an F7
cycler (`IQM: Route Colour Cycle`) stepping the live route through the new default, the
original army green, a pale lime and the cards' accent gold. Nothing it does is persisted;
`read_config` puts the menu's values back.

Both cyclers exist for the same reason, worth stating once: a colour and a shape can only
be judged against the ground they are drawn on, and going through the menu for each
candidate costs a route rebuild and the comparison along with it.

### R2.19 — Thirteenth session: the asymmetric mitre, marks at your feet, and "is there a better way?" · **2026-08-13**

"Overlap creates a light spot. The arrows need to start right on the player. Is there a
better way of doing this? A shader etc" — with a wide shot in which the nearest mark is
~10 m out and the whole near stretch of floor is bare.

**R2.18a: answered, against the overlap.** The prediction was that two bodies at 84% alpha
would compose to ~97% and read as solid. The arithmetic was right and the conclusion was
wrong. Alpha blending is `dst(1-a) + src·a`, so a second pass over the same pixels leaves
`dst(1-a)² + src·a(2-a)` — and against ground *darker* than the stroke that is a visibly
brighter patch, sitting exactly where the eye is aimed. "Nearly opaque" was the wrong thing
to measure; what matters is that the doubled region differs from its surroundings at all.

**The fix is an asymmetric mitre.** The wedge only needs filling once, so only one arm is
extended past the point (by `(th/2)/tan a`, as R2.18 derived) and the other is *pulled back*
along its own axis to where it leaves the first arm's band, at `(th/2)/sin 2a` from the
point. Both factors come from `tan a = hw/hl`, so with `L² = hl² + hw²` the pull-back is
`th · L² / (4·hw·hl)`. The union still covers the apex; neither coloured body covers any of
it twice. Two known approximations, both deliberate: the angles are ground angles applied to
a projected mark, and the pull-back is computed for the arm's *centreline*, so its outer edge
still crosses the first arm's end cut in a hairline. A hairline of double coverage is the
error to have — invisible at these widths, where a hairline *gap* would catch the light.
`MITRE` drops 1.35 → 1.15 with it: the surplus used to land inside the other arm and now
lands outside the mark, as a nub past the point, so the slack is only what the projection
error needs. Which arm carries the fill is fixed rather than alternating, so the few-px
asymmetry leans the same way on every mark instead of flickering between them.

**Why the marks started 10 m out** was two independent things, neither of them the trim
alone.

1. *Phase.* Chevron arclength was measured from the drawn start — which moves with the
   player. So the marks were never at fixed places on the floor: the whole train slid down
   the ground at walking pace, and a mark that slides is a HUD element drawn on the ground
   rather than one painted on it. Phase is now absolute arclength along the route
   (`path_s`, built once with the path), so a mark's position is a property of the *route*.
   You walk over them. They do jump once on a repath, which moves the ruler's origin — but a
   repath moves the whole line anyway.
2. *Two references, one of them wrong.* The near fade measured a chevron's distance against
   `d0`, the nearest drawn **vertex** — and the stroke starts `NEAR_TRIM` = 3 m out. Every
   mark inside the trim therefore measured as "at or before the reference" and was pinned at
   `HMIN` = 0.30 of the route's alpha. Marks now measure from `HMARK` = 1.2 m of camera
   distance, absolute: below that a mark is underfoot and genuinely wants holding back, above
   it the ramp is `HEAD` as before.

And the chevron pass now starts at the **cursor**, not at the trimmed stroke start. The trim
exists so the stroke's nearest segment is not a slab across the bottom of the screen (R2.13
E) — that is a fact about a wide band, not about a small mark, and the mark is precisely the
thing that has to be at your feet. So the two runs start in different places and share one
arclength frame by letting `acc` begin at `-trim`.

**"Is there a better way — a shader?"** Not from Lua, and the reason is worth recording once
so it is not re-asked. What the script layer can reach:

| Route | Verdict |
|---|---|
| UI statics (what we use) | Rotate-then-uniform-scale only, so a quad can be a rotated rectangle and never a trapezoid. This is *why* a chevron is two arms rather than one glyph, and why thickness has to be measured rather than mapped |
| World wire renderer | 1 px, untextured, no alpha blend. Rejected in R2.1 and still right |
| `DRender->dbg_DrawTRI` | Exists in C++ (`Actor_Network.cpp:1446`) and is **not** bound to Lua. Textured world triangles from a script would be the correct primitive, and there is no export for it |
| Particles (`particles_object`, `play_at_pos`, `set_orientation`) | Bound, and would give depth-tested ground-oriented quads for free — but effects come only from `$game_data$\particles.xr` (`PSLibrary.cpp:34`), one archive with no loose-file layer. Shipping a custom effect means shipping the whole archive, which every particle mod in GAMMA also does. Non-starter for load-order reasons, not technical ones |
| Spawned objects with a decal visual | No per-frame transform for a non-NPC object; `set_npc_position` is the only mover exposed. Spawning ~16 alife objects per frame's worth of marks is worse than the problem |
| An actual shader / projected decal pass | Needs a C++ addon exporting "draw this list of textured world quads" — i.e. a custom `xrGame.dll`. GAMMA ships shared binaries, so a fork would take the mod out of the pack it exists for |

So the sprite approach is not a workaround for not having found the shader; it is the only
primitive on this side of the engine boundary, and everything R2.13–R2.19 does (measured
thickness, angle-based subdivision, ground-space arms, mitring) is the work of getting a
painted-on-ground look out of rotated rectangles. Worth saying plainly: if the engine were
ours, one `dbg_DrawTRI`-style export would replace most of `iqm_core`'s route code.

### R2.20 — Fourteenth session: the mark becomes a picture · **2026-08-13**

"Still not ideal. Is there no way to render an actual image perhaps?" — with a close crop in
which one arm is cut visibly short of the other, a notch stepped out of the apex.

**First, the notch was a real bug and a bad one.** R2.19's corrections were derived from the
mark's *ground* angle and applied on screen, and I wrote off the difference as something a
safety factor covers. It is not a rounding error, it is a large error in a known direction: a
mark lying on the floor is flattened by the grazing angle, so the on-screen angle between the
arms is far *wider* than the ground one — `2a` heads toward 180° — and `sin 2a` grows with it.
The pull-back `(th/2)/sin 2a` was therefore several times what the screen needed, and it ate
a step out of one arm. Both corrections now come from the arms' projected directions: `cos 2a`
from the dot of the two screen unit vectors, `sin 2a` from the cross, and `tan a` from the
half-angle identity `sin 2a / (1 + cos 2a)`, which needs no `acos` and degenerates correctly
(collinear arms have no wedge, and both corrections go to zero).

**But the answer to the question is yes, and it is better than any correction.** A
heading-rotated static is rotate-then-uniform-scale — which is why a *strip* can be landed on
two points — but the rect's width and height are set **independently**, and `stretch="1"`
maps the texture onto whatever rect it is given. So a non-square rect holding a chevron
picture is exactly *squash the mark along its own axis by h/w, then rotate*: the
foreshortening comes out of the rect and the shape comes out of the artwork. One quad.

That kills the apex problem outright rather than managing it. Inside `iqm_mark.dds` the two
arms are unioned by `max()` **before** anything is blended, so overlap costs nothing — no
`a(2-a)` light spot, no wedge to notch. And the shape can now be drawn properly, by a tool
with real primitives: a sharp mitred point (each arm is an infinite strip about its centreline
cut by the mark's axis — exact, and seamless because on the axis the two arms are equidistant
from their own centrelines), tapered outer ends, a feather all round.

The artwork is drawn in the **mark's own metric**, not in pixels, because the renderer
stretches it by whatever the projection says. `mark_box()` in the builder and `place_mark` in
the renderer compute the same bounding box — which reaches further forward than back, since it
has to hold the mitre — and `FPAD` is the feather margin they share. A mismatch would show as
the glyph sitting slightly off its own rect, so this is the one number to keep in step.

The rect is measured, never computed: project the box's back-centre and front-centre for the
length and heading, and hand the across-travel extent to `seg_width`, the same ground-edge
measurement the stroke's thickness has used since R2.13. So the glyph foreshortens by the same
rule as everything else on the route and introduces no new tuning.

**What it gives up is the shear.** The true ground-to-screen map of a small patch is
`R' · S · R`, and a rect gives `R' · diag(w, h)` — it assumes the mark's own axis *is* the
compression axis. That is exact when the route runs away from the camera and when it runs
straight across, and wrong in between, where the mark should be a parallelogram. Walking a
route means looking down it, which is the exact case; the error peaks at 45° to the view on a
decoration a metre across. This is the same trade the strips make, one level up.

**One bug shipped with it, from reusing the stroke's clamp.** `seg_width` ends in a sanity
ceiling of `WMAX` = 96 px, and `place_mark` took it by default. But a px ceiling only means
anything against the width being measured: the mark's box is 1.2 m across where the band is
0.30, so a near mark passes 96 px *legitimately* at a couple of metres. Clamping there
squashed the glyph's **height** while its length went on being measured — and since the rect's
aspect is precisely what carries the mark's shape, the mark appeared to change its angle with
distance. `seg_width` now takes an optional cap and the glyph passes `MCAP` = 768, the UI
space's own height, which is a genuine sanity limit rather than a look control. Worth
generalising: any clamp expressed in px belongs to the quantity it was tuned against, and this
one had been tuned against a stroke.

Cheaper, too: one widget pair per chevron instead of two. The two-arm rendering survives as
`route_style = 3` ("arms") for comparison, with the screen-angle fix in it, and is documented
as superseded rather than broken — two quads cannot meet at a point, and every correction in
`place_arms` is an attempt to hide that.

### R2.21 — Fifteenth session: the near mark is where the affine fit runs out · **2026-08-13**

"The rotation left/right is weird depending on movement now. And it doesn't look good with
static chevrons" — with the near mark reading as a lopsided Λ, one arm long, the other stubby.

**The two complaints are one thing.** R2.20's rect is an *affine* fit: it can be rotated and
scaled on two axes, so it can be a parallelogram, and the true projection of a ground quad is
a **trapezoid**. That is fine while the patch is small enough for perspective to be locally
linear — and a mark 3 m from the eye is not. It spans real depth, its far edge genuinely is
narrower than its near edge, and a parallelogram cannot say so. The residual reads as skew,
and because it depends on where the mark sits relative to the vanishing point, it *swings as
you move*. That is the whole of "the rotation is weird depending on movement": not a rotation
bug, the keystone term going missing on the one mark big enough to show it.

R2.20 recorded shear as the price of the glyph and put it in R2.20b to check at 45°. That was
the wrong place to look. It is not worst across the view, it is worst **near**, where a mark
covers the most depth — and it is not the mark's angle to the view that drives it.

**And this is what made the static phase feel wrong.** R2.19 pinned the marks to the ground,
which means you now walk over each one in turn — so the badly-drawn regime, which used to be
somewhere the eye rarely rested, became somewhere every single mark visits on its way past.
The phase change did not cause the distortion; it put it on a conveyor belt.

**So marks now fade to nothing below `MNEAR` = 3 m** (ramping to full over `MFADE` = 2 m)
rather than being held at `HMIN` = 0.30 as R2.19 left them. Holding a mark at a third alpha
keeps it on screen; the honest move is not to draw it. Nothing is lost — a mark 3 m from your
eye has already told you which way to walk — and the marks stay world-anchored, so the
property the user noticed and liked ("they now seem static") is kept. This costs about one of
the sixteen chevron slots, since `iqm_nav` still builds a mark inside the cut-off without
knowing the renderer's limit.

Worth being plain about what is NOT fixed: the trapezoid. A rect cannot express it, and no
Lua-reachable primitive can (R2.19's table). Every remaining option is a trade of one error
for another — smaller marks, a nearer cut-off, or back to two quads with their own apex
problem. The cut-off is the cheapest, and `MNEAR` is one number to move if 3 m is too far out.

### R2.22 — Sixteenth session: back to two soft rectangles, and marks that slide · **2026-08-13**

"Still not good. Can we go back to when it was two separate rectangles with transparency at
the ends (i.e. not joined) and the chevrons moved."

So: back to R2.17, and this is the section to read before touching either thing again.

**The apex.** Four attempts, in order: butt the two arms and accept the wedge between their
end cuts (R2.17); extend both arms over it (R2.18 — the doubled alpha reads as a light spot,
because two passes of alpha `a` leave `a(2 - a)`); extend one and pull the other back (R2.19 —
the leftover asymmetry reads as a notch, made far worse by deriving the angle on the ground
instead of on screen); draw the whole mark as one texture (R2.20 — the apex is exactly right
and the quad's affine fit then shows up as a skew that swings as you move, R2.21). The one
that looks best in game is the first, with **both** ends tapered: `ARM_TIP` goes back to 0.14
alongside `ARM_TAIL`, so neither end of either arm is a cut. A soft end asks no question about
where exactly it stops, and two brush strokes crossing is a thing the eye accepts, where a
shape with a defective corner is not.

That is the lesson worth keeping: the wedge was never the problem. Every fix for it was
geometrically sound and each one traded the wedge for something the eye liked less. The
successful move was to stop drawing a hard edge there at all.

**The phase.** R2.19 anchored chevron spacing to arclength along the route so the marks would
stay put on the ground, on the argument that a mark painted on the floor does not slide. The
argument is right and the result was worse, for a reason the argument does not contain: pinning
the marks means you walk over each one in turn, so every mark in the route passes through the
near range where the drawing is least accurate and the mark is largest — and it turns out the
sliding reads as the route *flowing ahead of you*, which is what an AR overlay should do,
rather than as the marks being wrong.

Both halves stay as live code behind `PHASE_ABS` in `iqm_nav`, now `false`. This has been
flipped twice on in-game evidence; the next person to reason about it from first principles
will reach R2.19's conclusion again, and the flag plus this paragraph is the cheapest way to
say "that was tried".

**What survives from R2.19–R2.21.** The glyph, as `route_style = 3` — it is the right answer to
a different question (a perfect apex at middle distance) and its build is in the same script.
The projected-angle correction is gone with the mitre it corrected. `MCAP` stays, since the
clamp lesson is real regardless of which renderer uses it. `HMARK`/`MNEAR`/`MFADE` are gone:
chevrons take the stroke's own `HEAD`/`HMIN` fade again, which is all they needed once the near
mark stopped being a glyph.

### R2.23 — Seventeenth session: routes that keep to the middle · **2026-08-13**

"Can we make it favour pathing that is in the middle of areas rather than up against the side
of walls etc."

**The measurement is free, which decides the design.** The AI graph bakes a 4-bit cover value
per node per quadrant at level compile time, and `level.high_cover_in_direction(vid, dir)` is
bound to Lua — it interpolates between the two quadrants bracketing a direction and normalises
to 0..1 (`level_graph_vertex_inline.h:636`). So "how enclosed is this spot" costs eight table
lookups and no rays at all, which is what makes it affordable on every node the search touches
rather than on a sample.

It went in at **two scales**, because one cannot do the other's job.

**The search decides which way round.** A node's step cost is multiplied by
`1 + cover_w * cover`, where `cover` is the mean over the eight compass directions — 0 in the
middle of a courtyard, ~0.5 in a corridor, near 1 in a corner. At `cover_w` = 0.8 a route will
go up to ~1.4× further to cross a space rather than skirt it. Charged on the node being
*entered*, so it is a property of the ground and not of how the search arrived. Cached per
search per node; `cover_w = 0` restores shortest-path exactly.

Two things about it worth stating. A wall is never impassable — the surcharge is relative, so
a doorway with no alternative is still taken, and every doorway fixture in the route harness
now runs with it live, which is the guard on that. And `h_weight` is deliberately **not**
scaled up to compensate for the now-larger `g`. The arithmetic invites it (an unscaled weight
is a smaller fraction of the true remaining cost, so the search explores more), and it is the
wrong trade twice over: it spends path quality to buy expansions, and a greedier best-first
search beelines and then *follows whatever obstacle it hits* — precisely the behaviour being
removed.

**`string_pull` had to learn about it, and the harness caught that before the game did.** The
first version of this change did nothing measurable, because string-pulling is exactly the
operation that undoes a bow: the chord across it is shorter, straight, and perfectly walkable.
A pull now also has to not increase cover — sampled at the chord's midpoint against the mean of
the nodes it would delete. The midpoint alone is enough, since a pull spans at most three
probes and is straight: if its middle is not against something, neither are its thirds.

**The clearance pass decides where in the corridor.** The search only ever stands on graph
nodes and hops 8 m, so it cannot express "a metre further from that wall". A separate pass over
the DENSE point list pushes each point away from whatever crowds it, with the direction taken
as a gradient — the eight compass directions summed weighted by cover, negated. Two useful
properties fall out for free: a corridor is symmetric so the sum cancels and its midpoint is
left alone, and an inside corner pushes out along the bisector without anything having to
identify a corner.

Details that matter:

* **Permission is a destination-node test, not a directional probe** — the one place in this
  module that isn't `vertex_in_direction`. The push direction comes from cover, so it points
  away from geometry by construction and cannot be aimed at a wall; what it *can* be aimed at
  is a drop, since the open side of a catwalk has no cover either. R2.15's test (a node exists
  there, and its centre is within half a cell) is what catches a drop, and it saves the
  expensive call on every point of the path.
* **Offsets are computed for every point, smoothed along the path, then applied.** Cover is
  quantised to the 0.7 m grid, so raw per-point offsets step as points cross cell boundaries
  and the stroke picks up a ripple. A three-tap average removes it for nothing.
* **The ends never move.** A route that starts half a metre to the left of your feet, or that
  points at the wall beside the trader instead of at the trader, is worse than one that hugs a
  corner in the middle.
* **Order is smooth → densify → clear → snap.** Clearance needs the dense list (the sparse one
  has no point on the middle of an 8 m leg) and snapping goes last because both of the others
  move points in XZ.

Harness: the route harness gains a cover model built from the same wall grid, plus a *ledge* —
ground `cell_at` refuses while `blocked()` reports nothing there, which is the one configuration
this pass can get wrong. 45 → 57 tests; nav 118 → 120 for the pipeline order.

### R2.25 — Eighteenth session: the route starts at your feet again · **2026-08-14**

"The world view route needs to start at the player's feet" — with a screenshot looking straight
down at bare concrete and the first chevron several metres out.

Two separate offsets were stacking, and neither was visible from the code that caused it:

* **`NEAR_TRIM` = 3 m** (R2.13), skipping the head of the path in front of the *camera*.
* **A chevron phase of half a gap**, which at the dense styles' 3 m spacing adds another 1.5 m.

So in the `arrows` style — where the marks *are* the route and there is no stroke to show where
it begins — the route appeared to start ~4.5 m away. Both are now zero.

**Why the trim was the wrong instrument, given what exists now.** R2.13's reasoning was sound at
the time: once thickness is measured from the ground, a 45 cm ribbon a metre from the eye is a
slab across the screen. But the fix for that arrived separately and is still in the renderer —
the HEAD/HMIN fade (`RTE.HEAD` 3.5 m, `HMIN` 0.30), which ramps the stroke and its chevrons up
over the first few metres of *camera distance*. That softens the near plane where the trim
amputated it, and it is the honest variable: the problem is a fact about the camera, not about
how far along the path to start. With both live the first metres were paid for twice — faded
*and* missing. The comment above `HEAD` already said as much ("the route was invisible for its
first 6 m and looked like it started 8 m away, which is the complaint `NEAR_TRIM` was already
accused of"); the trim simply never got taken back out.

The renderer needs no change: `draw_route` already recovers a vertex behind the near plane by
clipping it forward (`clip_front`), and its own comment says that in practice this is "vertex 1
(the actor's feet) on nearly every frame" — a case a zero trim makes routine again rather than
a new one.

`NEAR_TRIM` and `TRIM_FRAC` stay as live machinery at 0, so reinstating the trim is one number.

**Both views now agree on where a route begins.** The minimap trail always walked from the
actor, deliberately ignoring the trim as a first-person argument that means nothing top-down
(`docs/minimap-route.md`, item 2). The two are no longer answering that question differently.

Harness: nav 140 → 141, with the R2.13 trim fixtures inverted rather than deleted — a
reinstated trim now fails a test instead of showing up in a screenshot.

### R2.26 — Nineteenth session: the route gets a preview, and a fifth style · **2026-08-14**

"Too much blur/opacity — ideally we want to render a sharp image."

**The tool came first, and it is the actual result of this session.** `tools/route-preview`
renders the route to a PNG out of game: the same textures (it imports `build.py` and calls
its own alpha functions), the same constants (parsed out of `iqm_core.script` and
`iqm_nav.script` at run time, so they cannot drift), and the drawing ported from `IqmCards`
— `seg_width` off the projected ground edges, `place_strip`'s rotate-then-uniform-scale,
the halo as the same texture at a larger rect, composited far to near. The projection is a
pinhole camera at an assumed FOV and the floor is procedural; both are stated in the file.

Why it matters more than any constant below: every look decision until now cost a launch, a
load, a walk to a quest giver and a squint. At minutes per comparison, the comparisons that
settle a design — this value against that one, same ground, same instant — were never
actually made. Eighteen sessions of judging one setting against a memory of the last is what
`--sweep` replaces.

It immediately paid for itself twice, both times by **contradicting a confident diagnosis**:

* The near stroke's banding was called as the joint overlap (`len + th`, which at the near
  end is as long as the segment). Rendering `full` / `capped` / `none` side by side showed
  the banding in all three. Measuring instead of squinting gave the real answer — alpha is
  per-widget and a quad cannot carry a gradient, so `HMIN` 0.30 → 1.0 over `HEAD` 3.5 m
  lands as 64, 79, 110, 148, 188 across five segments. A **staircase**, not a blur, and the
  two nearest also share a thickness because `WMAX` clamps them.
* "The blur is the feather" was half wrong. `FEATHER` 0.11 is a ~10 px shoulder on a near
  sprite and did need to come down, but the alpha stack was the larger term: 215 base ×
  0.30 near fade ≈ a quarter of full strength on exactly the marks that fill the screen.

**What changed.** Sharpness, in order of effect: `route_a` 215 → **255**; `HMIN` 0.30 →
**0.75** and `HEAD` 3.5 → **1.5 m** (both were sized against a `NEAR_TRIM` that R2.25
deleted — the gap became a ghost); `EDGE` 0.16 → **0.10** with `SHA` 0.55 → **0.75**, which
turns a glow into a keyline; `FEATHER` 0.11 → **0.04**, with `RTE.FPAD` following it.

**And a fifth style, `marks` (route_style 4), now the default.** Sweeping arm thickness
showed the wanted look was a *bolder* chevron — and that `arrows` cannot go there. Its apex
wedge scales with arm thickness, so by `aw` 0.38 the point has a visible notch; R2.18-R2.22
already established that wedge cannot be closed with two quads and settled on not trying.
The one-texture glyph has no wedge at any weight (its arms are unioned by `max()` before
anything blends) but existed only as `glyph`, which always draws a stroke. `marks` is that
glyph with `first_seg = 0` — three lines, and only worth finding out because the
combination could be tried in the preview before any of them were written.

Its geometry grew to suit being the whole route rather than a decoration on a line:
`aw` 0.22 → **0.38**, `awide` 1.15 → **1.85** (arm length is `sqrt(hl² + hw²)`, so the width
across the back is what lengthens the arms), `alen` unchanged at 0.85 so it stays a chevron
and not a dart, and `MARK_TAIL` 0.34 → **0.05** — an effectively square cut, with the
feather taking the corner off it, because on arms this long a third-of-an-arm ramp was most
of what you looked at.

### R2.26b — The same session, in game: three things the preview could not have told me · **2026-08-14**

The first in-game screenshot of `marks` was worse than what it replaced: a hard black bar
across the top of every chevron, a blunt tip, and marks that visibly rotated as the player
walked. Three separate causes, only one of them new.

**The black bar — a scaled copy is not a dilation.** `place_mark` drew the outline as the
same picture at a rect `edge` larger. Enlarging a rect about its centre *scales* the
picture inside it, and this glyph's box is deliberately asymmetric (it reaches forward to
hold the mitre), so the dark copy shifts along the mark's axis rather than surrounding it:
it emerged on the leading edge and hid behind the body everywhere else. A one-sided
outline at any `edge` — no tuning fixes a displaced copy. It was survivable while the
artwork was soft; R2.26's sharper, larger mark turned the same offset into a slab.

Fixed the way `iqm_dot` already had been: the keyline is **baked into the texture**
(`MARK_RIM`, 0.09 of an arm) and the second widget is parked. Concentric by construction,
proportional at every distance, and one fewer widget per mark. RGB is no longer uniform in
`iqm_mark`, so it leaves the "white ink, alpha carries the shape" contract — it survives
tinting because `SetTextureColor` multiplies and black times anything is black.

**The blunt tip — a latent geometry bug from R2.20, exposed by the new proportions.** An
arm runs from `(hl, 0)` to `(-hl, ±hw)`, so its X span is `2·hl`; the code used
`L = sqrt(hl² + hw²)`, the length of a different triangle. At these proportions that is
1.23× short, which made `(dx, dy)` **not a unit vector**, so every quantity derived from it
was wrong: `d` came out 1.23× too large and the arms drew ~19% thinner than `MARK_ARM`
asked, `s` put the tail cut in the wrong place, and `mark_box`'s forward extent stopped
short of where the shape actually ends — so the chevron's point was clipped off flat
against the edge of its own texture. At the original size the overrun was 3 cm and passed
for a point; at 1.85 m of span it is 10 cm of flat wall.

`arm_len()` is now `hypot(2·hl, hw)` and the box is measured to the arm's outer *corners*
rather than its centreline (it reaches `ha` further along the perpendicular at the back and
sides, and the two front edges meet `ha·L/hw` past the tip). No front cut is needed: the
half-plane clip closes the shape to an exact mitre on its own, which is what R2.20 intended
all along. `place_mark` computes the same three extents, since the box lives in two files.

Found by rendering the *texture* rather than the route — the preview draws what the
artwork says, so a shape bug inside the artwork looks like a design choice until you open
it. Worth remembering as the tool's blind spot.

**The rotation — a 1 m baseline for a heading.** Each chevron took its direction from the
single `PATH_STEP` leg it landed on. `densify()` lays points down every metre and
`clearance()` then pushes each up to 0.75 m sideways; a residual 0.2 m of disagreement
between neighbours is ordinary, and over a 1 m leg that is 11°. Invisible while a mark sat
still — but R2.22 made the marks *slide* along the path as you walk, so each one crosses
leg after leg and picks up each leg's error in turn. The bigger the mark, the more obvious
the swing, which is why R2.26's glyph surfaced it. `CHEV_DIR` now measures the heading
across ±3 path points.

None of the three could have come from the preview: its scenes are analytic curves with no
`clearance()` noise, it drew the same displaced halo faithfully without judging it, and the
clipped tip was in the artwork it was rendering.

### R2.26c — The rotation was R2.21 all along, and four styles go · **2026-08-14**

"They are still rotating when the player moves. Drop all styles other than this current
one, the others are terrible."

**The rotation is the keystone, and this is the second time it has been reported.** R2.26b
blamed a 1 m heading baseline and smoothed it; the marks still swung. The record already
had the answer — R2.21, verbatim: *"not a rotation bug, the keystone term going missing on
the one mark big enough to show it."* A mark is one quad and a quad's fit is affine, so it
can be a parallelogram where the true projection of a patch of ground is a trapezoid. A
near mark spans real depth, its far edge genuinely is narrower, and the residual skew
depends on where the mark sits relative to the vanishing point — so it swings as you move.
Smoothing the world direction could never touch it: the direction was right and the drawing
of it was wrong.

`MNEAR` = 3 m / `MFADE` = 2 m are therefore back, unchanged from R2.21. Below three metres a
mark is not drawn. R2.22 withdrew them along with the glyph; R2.26 made the glyph the only
design, so they return with it. The lesson worth keeping is procedural rather than
geometric: the same symptom had already been diagnosed correctly, in this file, and two
rounds went into re-deriving it. **Search the record for the symptom before theorising.**

`place_mark`'s angle now also comes from whichever of the mark's two axes projects LONGER.
Walking a route, the along-travel axis points away from you and projects short, so an angle
taken from it is hostage to a fraction of a pixel; the across axis lies broadside and is
well conditioned exactly then. A genuine improvement, and NOT what was causing the swing —
kept because a well-conditioned angle is worth having, not because it fixed anything.

**Four styles dropped.** `classic`, `band`, `arrows` and `glyph` are gone: the option, the
list, the strings, the F7 cycler, the `route_style` accessor, `route_w` and `route_size`
(which only ever sized a stroke and a billboard), and the render paths — `place_seg`,
`place_strip`, `place_arms`, `place_chev`, and three of the four widget pools. The route
now draws **16 statics where it used to create 152**, and `iqm_core` shed ~9,000
characters.

Worth stating what is lost, because two of those designs existed to be compared against:
the pre-R2.16 look and the two-quad chevron are no longer one keypress away, and R2.20b
(the shear A/B against `route_style = 3`) can no longer be run in game. The record of why
each lost is above; reviving one means reviving its widget pool with it.

### R2.27 — Twentieth session: the glyph never inherited a floor · **2026-08-14**

"Rotation is good. But now the angle changes. I feel we already fixed this in previous
styles as well."

Right on both counts, and the record found it this time before any theorising. R2.20 shipped
the rule: **a clamp expressed in px belongs to the quantity it was tuned against.** It was
written about `WMAX` — a sanity ceiling for a 30 cm stroke, applied by accident to a 1.2 m
mark, which squashed the glyph's height while its length went on being measured and made
"the mark appear to change its angle with distance". Same sentence, different clamp.

**Measured before changing anything**, which is what the preview is for:

```
  d(m)    ln(px)   th(px)   ln/th        artwork's own aspect: 0.598
    3.0    118.20   472.60   0.250
    9.0     15.88   175.69   0.090
   45.0      0.69    36.84   0.019
```

No clamp was biting. The mark's along-travel axis foreshortens with the grazing angle while
its across axis stays broadside, so the drawn aspect falls 13x between 3 m and 45 m: the
chevron opens out at your feet and flattens to a line in the distance. Physically exact — at
45 m you see the floor at 2 degrees — and unreadable, which is the complaint.

**Why no previous style showed it.** Not because they were more correct. In `place_arms`
each arm's thickness went through `seg_width`'s `WMIN` floor of 2.5 px, so a far arm kept a
minimum weight while its length stayed measured. The two-quad chevron had a floor on the
foreshortened quantity; the one-quad glyph never inherited one, because for a STROKE the
foreshortened quantity is the thickness and `WMIN` is about legibility. R2.20's rule, applied
to the case it did not anticipate.

So the glyph gets its own: `MSQUASH` = 0.4 floors the drawn aspect at that fraction of the
artwork's natural aspect, below which the mark stops foreshortening and holds its shape. A
deliberate cheat, and worth naming as one — past that angle the honest projection is a line,
and an unreadable direction mark is worse than a slightly-too-open one. It only ever adds
length, so a mark can never squash below recognition and never grows past its true footprint
the other way. Chosen from a sweep: at 0.25 the far half still visibly flattens, and past
~0.6 the distant marks stop reading as lying on the floor and start to look like billboards
standing out of it — the error that took the classic style down in R2.16.

One tool bug fixed on the way, worth recording because it is the failure mode a
constant-parsing preview is prone to: `tools/route-preview` reads the shipped constants with
`(-?[\d.]+)`, which happily matched the ellipsis in a COMMENT reading `--sweep MSQUASH=...`
and tried to make a float of "...". A number starts with a digit; the pattern now says so.

### R2.28 — Twenty-first session: the marks were being moved, not mis-drawn · **2026-08-14**

"What the fuck. The angle is still changing based on player movement. Take your time and
fix it."

Fair. Three sessions had been spent adjusting how a mark is DRAWN — the heading baseline
(R2.26b), the near cut-off (R2.26c), the aspect floor (R2.27) — and the complaint never
moved. So this time nothing was changed until the thing being complained about had been
measured directly: what happens to one mark, on the ground, while the player walks.

**Measured, walking 2 m in 0.05 m steps past a mark 9 m ahead:**

```
  drawn aspect   0.2392 -> 0.2392    0%   MSQUASH does pin the shape
  screen angle   worst step 0.29 deg      the rotation really is settled
  drawn size     161 px -> 181 px   12%   sawtooth, 1 m period
  world heading  -2.4 deg -> +1.2 deg     resampled, same period
```

And then the measurement that ended it — how far an individual mark moves between frames:

```
  sliding  (PHASE_ABS false)   biggest single-frame move: 1.000 m,  2 frames in 40
  anchored (PHASE_ABS true)    biggest single-frame move: 0.000 m,  0 frames in 40
```

**The marks were being moved.** A sliding mark is pinned to `path[cursor]`, and the cursor
advances in `PATH_STEP` jumps — so the whole train sits still while you walk up to it and
then snaps a metre forward onto different path points, with different local headings. Every
mark's distance sawtooths by half a step and its heading resamples, once per metre walked,
for as long as you are moving. Nothing in the renderer can settle that, which is exactly
why three rounds of renderer fixes did not.

`PHASE_ABS = true`, so the phase is absolute arclength along the route. R2.19's arrangement,
reverted in R2.22 on how it read, restored on what it measures. R2.21's `MNEAR` is its
companion and was already back in: world-anchored marks get walked over, so they have to
stop being drawn before they reach the range one quad cannot draw.

**Two supporting fixes in `place_mark`, both about not depending on a bad axis.**

* The rect is now the mark's **two projected axes measured separately** — height from the
  across vector, width from the along one — instead of going through `seg_width`. That is a
  STROKE measurement: it keeps only the component perpendicular to the segment's screen
  direction, because for a band the skew along its own length is not thickness. For a mark
  that skew is the shape, and routing the height through the along axis made the mark's
  size inherit the noise of the worst-conditioned direction for nothing.
* The angle is a **weighted circular mean** of both candidates rather than a pick of the
  longer. Picking has a switch-over, and at it the two disagree by the keystone the affine
  fit cannot express — so the mark would jump a degree or two exactly when the player
  crosses that geometry, which is one more thing changing as you move.

**What it cost.** R2.22 chose sliding because it read as the route flowing, and that is a
real loss — the marks are now still, and stillness is what was asked for. If the flow is
missed, `PHASE_ABS` is one line and everything above says what comes back with it.

The lesson is the same one R2.26c recorded and this session had to learn properly:
**measure the complaint before theorising about it.** Three rounds of plausible,
well-argued renderer fixes cost more than one measurement would have.

### R2.29 — Twenty-second session: the beacon becomes a waypoint marker · **2026-08-14**

"The font needs to be smaller. Use the same marker as the target." Then: rename beacon to
waypoint marker throughout MCM, drop the state roles, collapse the page.

**The readout was not "a font that is too big" — it was a font that is not in the layout.**
Measured rather than assumed:

```
  arial_14 draws        22 screen px   fixed per resolution BUCKET (GameFont.cpp:32)
  the XML box claims    14 UI units    = 26 screen px at 1440p
  the glyph beside it   14 UI units    = 26 screen px, scales with marker_size
```

So the number was drawn at 85% of the glyph's height while the badge was padded for a box
the text overflowed — and none of it moved when `marker size` did, because **a font's height
is screen pixels from a resolution bucket, not a UI size.** Nothing scales a font by widget
size; `CGameFont::SetHeight` exists and is not bound to Lua.

- **`font="small"`** (`stat_font` → `ui_font_hud_01`): 16 px against arial's 22 here, with
  `SetInterval(0.75, 1.0)` condensing the digits. It is the *only* step below `arial_14` —
  the engine hardcodes eleven font names and `R_ASSERT`s on a twelfth (`UIXmlInit.cpp:766`),
  so an invented name is a CTD, not a fallback. Precedent: Tactical Compass labels its world
  markers with it.
- **`AdjustHeightToText` beside the existing `AdjustWidthToText`.** The height was the one
  content metric the badge assumed instead of measuring. Now it asks the font, so the badge
  fits the readout on *this* screen and would fit a different font without a second edit.
- **The metre suffix is ASCII "m" in every locale now.** `ui_font_hud_01` is excluded from
  the localisation prefix (`GameFont.cpp:76-82`) — one atlas for all languages — so a
  Cyrillic "м" there would have drawn as the unassigned-character fallback glyph. This is the
  cost of the smaller font and the only real one.

**"The same marker as the target" meant the map's marker.** The waypoint badge showed a
tabler *flag* for a turn-in while the PDA map showed the diamond — two marks for one state,
which `tools/map-icons/README.md` had already flagged as a known divergence. Fixed at the
source rather than at the call site: `handin`, `trader`, `medic`, `mechanic` and `barman` in
`tools/role-icons/svg` are now the same SVGs `tools/map-icons/svg` uses, and they skip the
distress pass, because an eroded copy of the map's mark is not the map's mark. Pointing
`BEACON_ICON` straight at `iqm_mapspot_*` was the cheaper option and was rejected: those
cells carry the badge ring and a baked black keyline, which at 14 px on a charcoal plate is a
blob. Same ids, same atlas coordinates, re-sourced art — nothing in `iqm_textures.xml` moved.
`guide` keeps its tabler glyph: vanilla does not map-spot guides, so there is nothing to
match.

**Five roles lost their marker.** Needs-a-guide, recruitable, for-hire, important and
work-available are gone from the page; hand-in, guide NPCs and the four service trades
remain. The rule that replaces "any card role can be beaconed" is **a marker is for
somewhere you are going**: you seek out a medic or a guide, you do not seek out the stalker
who happens to want an escort. Their cards are untouched.

**And the page is one section.** Two captions over four rows was more furniture than page,
so the "Hand-in" and "Beacon roles" sections merged and `any_beaconable_role` — which
existed only to stop the second one captioning an empty group — went with them. Advanced
stays. Every storage id keeps its name (`mark_beacon`, `beacon_dist`, the `beacons` page):
the rename is captions only, because a settings path is a save-compatibility surface, and
`ui_mcm.get` on a path MCM has not been told about logs an error per call.

### R2.29 — Twenty-second session: there was a third option · **2026-08-14**

"The markers no longer move — they are static. We have been through this all before. What
is preventing you from getting this correct?"

**What was preventing it: treating a two-part requirement as a one-bit choice.** The record
held two arrangements, each shipped and each reverted, and every session picked one of
them:

* **phased on the drawn start** (R2.22) — the marks move, and lurch, because the drawn
  start is `path[cursor]` and the cursor advances in `PATH_STEP` jumps: 1.000 m at a time,
  a 12% size sawtooth, headings resampled with it;
* **phased on absolute route arclength** (R2.19 / R2.28) — nothing changes, because nothing
  moves.

Both were reported as broken within one session of shipping, for opposite reasons, and the
existence of exactly two documented options made it feel like the answer had to be one of
them. It never was. What was asked for is a mark that **flows over the ground AND keeps a
constant appearance**, and neither option gives both — because each one quantises or
freezes the very quantity that has to be continuous.

**The third option: phase on the ACTOR'S OWN ARCLENGTH, continuously.** A mark sits at
`s_actor + k * gap`, so it holds a fixed distance ahead of the player. It moves over the
ground exactly in step with him — and because its distance never changes, neither does its
size, its aspect or its angle. Measured, walking 2 m in 0.05 m steps, third mark:

```
                        R2.22 sliding   R2.28 anchored   R2.29 (this)
  moves over ground     1.000 m lurch   0.000 m          0.050 m per 0.05 m step
  size change / step    9.6%            n/a (still)      0.08%
  angle change / step   0.29 deg        n/a (still)      0.25 deg
  distance ahead        sawtooth ±0.5m  grows as you go  constant, 8.97 m
```

The mechanism is `actor_arclen()`, which projects the actor onto the leg he is actually
standing on instead of rounding to the nearest path point — both legs around the cursor,
since the nearest point can be just ahead of him as easily as just behind, and taking only
the forward one would quantise the other half-step. The cost is that the chevrons are
replaced **every frame** rather than only when the cursor moves, which is the entire point;
`place_chevrons` is bounded by `MAX_CHEV` and walks the path on a rolling index.

**The process failure is worth more than the fix.** Four sessions of "the marks change when
I move" were each answered by changing how a mark is DRAWN — the heading baseline, the near
cut-off, the aspect floor, the measurement axes. Every one of those was a real improvement
and none of them addressed the report, because the marks were being MOVED. The measurement
that settled it (how far does one mark travel between frames) took a few minutes and could
have been run in the first session. The rule R2.26c wrote down and this session finally
learned: **measure the thing being complained about, not the thing you suspect** — and when
the record offers two options that both failed, that is evidence the requirement was never
one of them.

### R2.30 — Twenty-third session: the readout stops being text · **2026-08-14**

"Font is still too big. Only show the chevron when the marker is pinned to the side of the
screen. Remove the background (keep the code though)."

**The font ladder was already at the bottom.** R2.29 moved the readout from `arial_14` (22
screen px here) to `small` (16), and `small` is the smallest of the eleven fonts the engine
has — `medium` and `di` are 32 px atlases, an unknown name in the XML is an `R_ASSERT`, and
`CGameFont::SetHeight` is not bound to Lua. Measured, not assumed:

```
  arial_14        ui_font_arial_14_1600     512px sheet, 22px cells
  small           ui_font_hud_01_2160       256px sheet, 16px cells   <- the floor
  medium/di       ui_font_hud_02/console    512px sheets, 32px cells
```

So "smaller" was not available as a font at all, and the deeper problem was the same one
R2.29 documented and could not fix: **a font's size is screen pixels from a resolution
bucket, so the readout never followed `marker size`.** Both go away if the readout is not
text. `tools/digit-tex/build.py` renders 0-9 and `m` from Bahnschrift (DIN 1451) semibold
condensed into `iqm_digits.dds`, and the readout is now one static per character.

- **Its height is `RD_G.f` × the glyph size** — a number, so any size is reachable and the
  readout scales with the badge. Exposed as `beacon_rsize`, a percent, in Advanced.
  Default 40% = ~10.5 screen px at 1440p, against 16 and 22 before it.
- **Digits are declared at one common width** — the tabular advance box, centred on each
  digit's ink — so a range counting down from 100 to 99 doesn't shuffle sideways. `m` is an
  x-height glyph, so it carries its own shorter box plus a baseline drop (`GLYPH_DY`).
- **The per-frame path now allocates nothing.** The old one concatenated `mtr .. suffix`
  once per metre walked and asked the font to measure itself; the new one pulls digits
  most-significant-first straight into the widget slots, so `b.gl[k].tex` *is* the string.
- The metre suffix is art now, so `ui_mcm_iqm_beacon_unit` is gone. That costs nothing that
  was not already lost: `ui_font_hud_01` is the one font with no per-language texture
  (`GameFont.cpp:76-82`), which is why R2.29 had already forced the suffix to ASCII.

**The chevron is now edge-only.** It answers "which way", and on screen the badge is already
over the NPC's head — an arrow pointing down at what it is attached to restates its own
position and costs a second mark to read. Clamped, it is the only thing carrying the answer.
`clamped` was already computed in `draw_beacons` for the parking logic and is now passed
through; the badge's back-off along the pointing direction becomes zero when there is no
chevron, so it sits ON the anchor rather than above where a chevron would have been.

**The plate is off, not deleted.** `BADGE_PLATE = false`; both widgets are still created and
still laid out, so the flag is the whole of putting it back. The padding it sized itself with
stays in the layout for the same reason (it also feeds the clamped chevron's stand-off). What
replaced it is the cheaper half of the argument that justified it: every part of the badge now
carries its own dark copy — the glyph gained `beacon_icon_sh` — which is what the route marks,
the chevron and the card text have always done. Checked against pale wood, grass and sky
before shipping; the outline holds on all three, which the plate was there to guarantee.
(**Superseded the same day by R2.31**: a dark copy *as a second widget* is the thing that
cannot stay aligned. The keylines are baked now. The conclusion above — that the badge needs
an outline once the plate is gone — stands; only the mechanism changed.)

### R2.30 — Twenty-third session: a floor that always binds is not a floor · **2026-08-14**

Two reports off the first in-game look at the R2.29 marks: they are **bigger than expected**,
and their **angle points upwards rather than lying along the ground toward the target**.

**The angle.** `MSQUASH` (R2.27) floored the drawn aspect at 0.4 of the artwork's own, to stop
distant marks flattening into lines. Measured at 55° FOV and the shipped sizes, what it
actually did:

```
  d(m)   true aspect   floor    drawn   floored?
   3.0        0.285    0.239    0.285    -
   4.0        0.218    0.239    0.239    YES
   8.0        0.113    0.239    0.239    YES
  17.0        0.054    0.239    0.239    YES
  40.0        0.023    0.239    0.239    YES
```

The floor binds at **every distance past 3.5 m**, so the whole visible run was drawn at one
fixed aspect — every mark holding the shape it has when seen from a fixed steep angle, no
matter where the ground under it really is. At 8 m that is twice the depth the ground has.
A shape that does not change with distance is a **billboard**, and R2.27's own comment named
that as the failure mode ("past ~0.6 they start to look like billboards standing up out of
it") without noticing 0.4 had already reached it.

Worse, R2.29's verification table *recorded this and read it as a pass*: "drawn aspect
0.2392 → 0.2392, 0%, MSQUASH does pin the shape". The measurement was right and the
interpretation was backwards — constancy was the property being checked (does the mark change
as the player moves?), and the same number is a defect against the property that was not being
checked (does the mark change with **distance**?). Constant-under-motion and
constant-under-distance are different requirements and one metric cannot serve both.

The replacement is the clamp the two-quad styles really had, in the units they had it in.
Those never showed the flattening because each arm's thickness went through `seg_width`'s
**`WMIN` = 2.5 px** — an absolute legibility guard, binding only where the quantity is about
to vanish. So `MSQUASH` is gone and `MLMIN = 6` px takes its place on the along axis. It binds
past ~15 m, where the mark is already under a tenth of its own width deep; from 3 to 13 m —
the range a route is actually walked in — the honest projection is drawn untouched, which is
the only thing that says the mark is painted on the floor rather than standing on it.

**The size.** `alen`/`awide`/`aw` scale down 20% to 0.68 / 1.48 / 0.304. R2.26 grew them by
eye in the preview, where nothing gives scale; 1.85 m across is a metre wider than the doorway
the route walks you through, which is what the in-game shot shows. All three take the **same**
factor deliberately: the glyph's box is then exactly similar, the artwork still fits its rect,
and `iqm_mark.dds` needs no rebuild. `tools/stroke-tex/build.py` tracks them anyway, or the
next rebuild would draw into a box the game no longer measures.

**The preview was stale** and had to be fixed first. Its `place_mark` still carried the
pre-R2.28 single-axis measurement, so tuning against it would have tuned against a renderer
the game stopped using — the two-axis rect and the weighted circular-mean angle are now ported
across. A preview that has drifted answers confidently and wrongly, which is worse than none.

### R2.31 — Twenty-fourth session: a dark copy is a second widget, and that is the bug · **2026-08-14**

"The waypoint markers seem to be out of sync with the border/background/shadow — this seems
to always happen?"

It does always happen, it is not this mod's arithmetic, and **this file has recorded the fix
twice without generalising it.** Two facts about the engine:

* `CUIStaticItem::RenderInternal` (`UIStaticItem.cpp:43-48`) converts a widget's top-left to
  screen coordinates and then calls `AlignPixel` — which is `iFloor` (`ui_base.cpp:148-151`).
  **Every widget is floored to a whole screen pixel independently.** A mark and its dark copy
  sit at different UI positions, so their fractional parts cross an integer at different
  moments as the marker moves: the gap between them flips by a whole pixel while you walk. At
  1440p one UI unit is 1.875 px, so a nominal 1-unit offset lands as 1 px or 2 px depending on
  where on screen the badge happens to be. That is the "out of sync" — it is not a constant
  misalignment, it wobbles, which is why it reads as the halo being *out of step* rather than
  simply off.
* The bottom-right is **not** aligned: `RBp = pos + scaled_size` (line 64-65) skips
  `AlignPixel`. So the overhang is snapped on two sides and fractional on the other two —
  uneven even standing still.

No script-side arithmetic can fix either one. The offsets are specified in UI units, which are
coarse (1.875 px) and integral, and the floor happens after everything script can influence.

**So the keyline goes in the art.** `tools/map-icons/build.py` already had the primitive — a
round-disk dilation of the alpha, which preserves the source's antialiasing at the outer edge
— and it is now in `role-icons/build.py` (as `keylined()`, with the reasoning) and
`digit-tex/build.py`. Baked, the keyline is part of the same quad: concentric by construction,
the same *fraction* of the glyph at every marker size, and impossible to desynchronise. It
survives `SetTextureColor` because the UI shader is `texture * I.Color` (`hud_default.ps:8`)
and black times anything is black; baking it at 0.70-0.72 alpha reproduces the 0.65-0.7 the
separate copies used, since that alpha then multiplies by the widget's own.

Gone as a result: `beacon_icon_sh`, `beacon_chevron_sh`, and one shadow widget per readout
character — **five widgets per marker, twenty across the four.** The chevron also stops needing
its rotation applied to two elements and kept in step.

**The two prior sightings, for the record.** `iqm_dot` (the minimap bead) bakes its keyline,
and its comment in `iqm_textures.xml` already describes this exact failure at 8 px: "rounds to
screen pixels independently of the mark it is meant to sit behind — a heavy ring, visibly off
centre." `iqm_mark` (the route's ground chevron) baked its keyline in R2.26b, and
`stroke-tex/build.py` says why in as many words: "a SCALED copy and not a dilation". Both were
treated as facts about *that* mark. They were facts about the renderer. The rule now is:
**anything drawn over the world without a plate behind it carries its keyline in its texture.**

Still a scaled copy, deliberately: the stroke and arm halos (`iqm_stroke`, `iqm_arm`). Those
are strips stretched to an arbitrary length per segment, so a baked keyline would stretch with
them and its thickness would vary segment to segment; a symmetric scaled strip is the right
answer there, as the note in `iqm_cards.xml` already argues.

One consequence to know about: a digit's declared rect now *includes* its keyline, so the
figures are 104/126 of the readout height — about 17% smaller at the same `beacon_rsize`. The
tabular box grew by the same amount for every digit, so alignment is unaffected, and
`build.py` prints the regenerated `RD_G` proportions to paste.

### R2.31 — The keystone, measured to the end · **2026-08-14**

Reported after R2.30: better, but the perspective still shifts when you strafe. This is the
affine residual `MNEAR`'s comment has described since R2.21 — a `CUIStatic` is a rotated
**rectangle**, the true projection of a patch of ground is a **trapezoid**, and the keystone
term between them depends on where the mark sits relative to the vanishing point, so it swings
as the camera translates. Four things were measured before anything was changed.

**1. The current fit is already optimal.** A least-squares rectangle through the four true
projected corners — both ends of the mark voting on the width instead of only the middle —
gains **0.6%** (82.7 → 82.1 px at 4 m). There is no better rectangle. Everything below is
about changing what is drawn, not how it is fitted.

**2. Slicing the mark works numerically and fails visually.** Cutting the footprint across
travel and fitting each piece its own rect is piecewise affine, and the error falls as ~1/N:

```
                 err @5 m   wobble        seam mismatch
  1 quad (now)     55.3       12.0             --
  2 along          30.1        6.5           54.9
  4 along          15.7        3.4           30.0
  2 across         58.7       14.8            (no help: wrong axis)
  2 arms          111.3       20.1            (worse: an arm is LONGER in depth)
```

The last column kills it. Each piece measures its width at its **own** centre, so neighbours
disagree at the shared edge by more than the error they were fixing — `tools/route-preview
--slices 4` renders the chevron as a stack of disconnected bars. Kept as a flag, because the
render is the argument.

**3. Only `alen` carries it.** The keystone comes from the footprint's near edge and far edge
being at different depths, and `alen` **is** that depth. Halving it cuts the worst corner error
a third; halving `awide` instead moves it **1%** and makes the error *worse* as a fraction of
the mark (37% → 48%), because the mark shrinks and the error does not.

**4. So the fix is a shallower chevron**, 0.68 → 0.50, and nothing else:

```
             err @5 m   as % of the mark   wobble
  alen 0.68    55.3            28%          12.0
  alen 0.50    45.1            24%           9.7
```

`iqm_mark.dds` is redrawn because the box shape changed (unlike R2.30's uniform scale, which
left it alone). **To revert:** put 0.68 back in `RTE.alen` and `MARK_LEN`, re-run
`tools/stroke-tex/build.py`. One number in two files and a regenerated texture — nothing else
in the change.

What is left is inherent. The residual falls off fast with distance — 24% of the mark's width
at 5 m, 20% at 6 m, 14% at 9 m, 10% at 13 m — so it lives entirely in the nearest mark or two,
and the only remaining lever is not drawing them (`MNEAR`), which trades against R2.25's
"start at the player's feet". That trade is R2.31a.

**5. Which SHAPE fits a rectangle best.** Since the error depends only on the footprint's
depth, any candidate can be judged by the box it needs, before any artwork exists. Worst
corner error as a fraction of the mark's own drawn width:

```
                            5 m    9 m
  chevron alen 0.68 (R2.30)  29%    17%
  chevron alen 0.50 (now)    24%    14%
  chevron alen 0.30          19%    11%
  filled triangle 0.50       16%    10%
  transverse BAR (a rung)    11%     7%
  disc, fitted to its box    46%    28%
```

A **rung** is the floor of this: it spans only its own thickness, so there is nothing left to
foreshorten wrongly — but it does not point, and the direction would have to come from the
sequence alone. A **filled triangle** is the middle: no interior gap means no mitre allowance,
so it spans ~40% less depth than a chevron of the same width while still pointing.

The disc row is the interesting one, and it is misleading as written. A projective map takes
conics to conics, so a ground circle is **exactly** an ellipse on screen — and a rotated rect
fitted to that ellipse's own axes would carry a disc with **zero** keystone error, the only
shape for which that is true. The 46% is what fitting it to its bounding BOX costs, which is
what the current code would do. Realising the exact fit needs the projected conic, not the
footprint, and a disc cannot point — recorded because it is the one exact answer, not because
it is a candidate. `tools/route-preview --sweep shape=chevron,arrow,bar` renders the three
that are (preview-only; they generate no assets).

**A stale asset, found and left alone.** `build.py` regenerates all three textures, and the
rebuild showed `iqm_stroke` differing from the committed copy by up to 181 of 255 in a
channel — so the shipped stroke has been out of step with `FEATHER` since R2.26 changed it
0.11 → 0.04 and only the mark was regenerated. It is invisible today (the `marks` design draws
no stroke) but `iqm_cards.xml` still points card rules at it. Reverted rather than shipped,
because this change is meant to be one number: R2.31c.

**A tooling bug worth recording:** `parse_rte` read the RTE table through a fixed 12000-char
window, and this session's comment pushed `PPM` past it. It failed loudly, but only by luck —
the window's far end lands wherever the prose happens to reach, and a preview that silently
reads the wrong constant is the one failure mode this tool must not have. It now parses to the
table's closing brace.

### R2.32 — The shape becomes a setting · **2026-08-14**

R2.31 established that the keystone residual scales with one thing — the depth the mark's
footprint spans along travel — and that the shapes which point best are exactly the ones that
sit worst. That is a trade with no correct answer, so it becomes `route_shape` in MCM rather
than another number picked here:

```
  1 chev50   depth 0.83   24% at 5 m   points   (default, unchanged)
  2 chev30   depth 0.63   19%          points
  3 arrow    depth 0.52   17%          points
  4 rung     depth 0.33   11%          does not point
  5 square   depth 0.32   47%          does not point
```

Ordered in the menu by how much each **points**, not by alignment, because pointing is what
the player is choosing between; the alignment trade runs the other way and is documented at
`RTE.SHAPES`. The square sits last and is not simply worst — the percentage is a ratio, so a
square scores ~47% at any size, and 47% of a 0.30 m tile is 17 px where 24% of the chevron is
45 px. It is in the list because it reads as stepping stones and is quiet underfoot.

**One atlas, one pool.** `ui\iqm_marks` is a 4x2 grid of 256 px cells and the 16-widget pool
is re-pointed with `InitTexture` on config change. Five pools would be R2.26c's mistake in a
new costume — four parked every frame for a setting the player changes once. A static's
texture is fixed at creation, which is why this is a re-point and not a rebuild.

**The box moved out of the draw path.** `place_mark` used to derive the chevron's box from
`alen`/`awide`/`aw` per mark. It now reads `RTE.SB`, filled by `shape_box()` on config change,
because the box depends only on which shape is selected. `shape_box()` is a file-scope
function rather than a method for one reason: `read_config` runs at `on_game_start` before the
dialog exists, so the geometry half must not need `self`. `IqmCards:apply_shape` is the other
half and is called again from `InitControls` once the pool is there.

**The five-row mirror is checked, not trusted.** `MARK_SHAPES` in the builder and `RTE.SHAPES`
in the mod are the "change one, change both" hazard multiplied by five, and the failure is
silent in the worst way — the game measures a box the artwork was not drawn into, so the glyph
sits off its own rect and looks like a rendering bug rather than a stale texture. `build.py`
now parses `RTE.SHAPES` out of `iqm_core.script` and refuses to build on a disagreement,
including `MARK_WIDE`/`MARK_ARM` against `awide`/`aw`. Checked at the moment drift would be
introduced, which is the only moment anyone is looking.

`iqm_mark.dds` is deleted — superseded by the atlas, and nothing references it. The MCM
harness's aggregate checks cover the new row; verified by breaking `ui_mcm_lst_iqm_shape_rung`
on purpose and watching the translation check fail.

### R2.32a — It compiled, and it killed the game · **2026-08-14**

The above shipped and the game did not reach the main menu:

```
! [LUA] ...iqm_markers.script:517: attempt to call global 'sqrt' (a nil value)
!   1 : shape_box   2 : read_config   3 : on_game_start
```

`shape_box` was placed just after the RTE table, and the file's
`local floor, max, min, sqrt = math.floor, ...` sits sixty lines BELOW that. A Lua local is
only in scope after its declaration, so `sqrt` inside the function compiled as a **global**
lookup, resolved to nil at `on_game_start`, and took the cards, the beacon and the route down
with it. Fixed by moving the function below the math locals.

**Why nothing caught it.** `check_lua` compiles the file with the engine's header, and there
was nothing wrong with the syntax — a global call to a nil value is valid Lua right up until
it runs. The four harnesses cover route solving, the menu, the minimap and nav; none of them
loads this module's render path. So the new function was, in the most literal sense, never
called by anything except the game.

**tools/marks-harness.** New, and it exists to close exactly that: it loads `iqm_core` and
RUNS `shape_box` for every shape. To make that possible the function became a module function
taking an index and returning its box — neither of which the renderer needs (`read_config`
still calls it bare and reads `RTE.SB`). *A thing no test can call is a thing no test will
catch*, and a file local taking no arguments and returning nothing is unreachable by
construction. It also checks the geometry against an independent recomputation, the chevron's
asymmetry (it alone has a mitre), the out-of-range fallback, and the three-way mirror between
`RTE.SHAPES`, `build.py`'s `MARK_SHAPES` and the texture ids in `iqm_textures.xml`.

Confirmed by reintroducing the fault: `check_lua` still says `ok`, the harness fails with the
same error on all five shapes. 43 checks.

**The lesson is about placement, not about `sqrt`.** Anything defined near the top of this
file cannot use the hot-math locals, and the file is 3800 lines with its `local` block a third
of the way down — so "define it next to the data it reads" is a trap here. New helpers go
below the math locals unless there is a reason they cannot.

### R2.39 — The marker slots were sorted by the wrong thing · **2026-08-15**

Reported as *"the barkeep's marker is inconsistent — it sometimes shows and doesn't, and
seems to show only when much closer than the others"*. Three rounds of static reading got
this wrong, and the live game settled it in about ten minutes. Both halves of that are the
point of the entry.

**What the reading concluded, and why it was wrong.** The Rostok barkeep carries
`level_spot = barman` (`bar_barman.ltx:7`, vanilla), so he sits in *both* classification
paths — the task branch and the amortized service scan. The service path has real
fragilities (no hysteresis anywhere, a spot attached to a job-assigned logic block, and a
logic that switches section as the *player* moves between four meet zones), so the flicker
looked like his classification dropping out. Plausible, coherent, and false.

**What the game said.** Reading the module's file-level locals straight out of its
exported closures' upvalues — `debug.getupvalue(iqm_core.route_target, …)` yields
`C`, `tracked`, and from there `beacon_roles`, `beacon2`, `_bcand` — showed the
classification was never in doubt:

```
19144 Barkeep  role=target  slot=3          beacon_roles.target = true
                                            beacon2 = 3600   extra2 = 3600
```

He was tracked correctly the whole time. **The marker was being dropped after it was
offered.** With five candidates in range and four slots:

```
mechanic   37.4 m  → slot 1     ambient; you walk past it
guide      39.7 m  → slot 2     ambient
turn-in    39.9 m  → slot 3
turn-in    45.2 m  → slot 4     the barkeep, clinging to the last slot
turn-in    59.9 m  → DROPPED    Petrenko, gone with nothing to say so
```

**The cause is one line.** `beacon_offer`'s sort was `(prio, distance)`, and `prio` was 0
for the placed waypoint and **1 for everything else** — so every marker the mod found for
you competed on metres alone. That is harmless until the slots are contended and then it is
exactly backwards: an ambient shop marker outranks the quest you are carrying, and the
eviction is silent. The barkeep sat on the boundary, so a few metres of drift flipped him in
and out; "only when much closer than the others" is him needing to out-*distance* two
ambient markers to earn a slot at all.

**The fix is to make `prio` mean something.** Callers pass `ROLE_PRIO[t.role]` — the same
table the *card* slots sort by, so the two orderings agree by construction and no new local
was spent (the file is at 191/198). Nearest-first still decides within a role class, so
nothing changes until the slots are actually contended. The waypoint keeps prio 0, ahead of
every role. `MAX_BEACONS` also went **4 → 6**: a real hub genuinely has five legitimate
markers, and the cap is a legibility limit rather than a budget one.

**`tools/slot-harness` (23 checks)** pins the Rostok set by name and distance, but the
assertion that matters is the sweep: over 400 mixed candidate sets, *no lower-`ROLE_PRIO`
candidate is ever dropped while a higher one is drawn*. The fixture also replays the
**shipped** rule — every candidate at prio 1, four slots, both numbers hard-coded rather
than read from the constants — and asserts it still drops Petrenko and still leaves the
barkeep in slot 4. Without that, raising the cap would have turned the whole file into a
tautology; mutation-testing caught exactly that (the first version of the check passed for
free at six slots) alongside reverting the call site and demoting `target` in `ROLE_PRIO`.

**The lesson is about which layer to suspect.** Every static theory was about
*classification*, because that is where the interesting code is. The fault was in
*selection* — twelve lines of insertion sort that had been correct while only one candidate
was special. A capped set with a silent drop needs its ordering justified, not just its
membership; and when a mod's internals are file-locals, the running game will still hand
them over through the upvalues of anything it exports.

### R2.38 — The marker that is also your waypoint · **2026-08-15**

Asked for: *if the active waypoint is one of our beacons, indicate it with an icon* — from a
screenshot of a medic marker that was also the placed waypoint.

**The data was already there, twice over.** PAW's `valid_waypoint_target` accepts
`IsStalker`, so a waypoint placed on an NPC stores that NPC's id and `get_current_waypoint()`
returns it; PAW even exports `is_current_waypoint(id)`. And `draw_beacons` already computed
`tracked[wid] and beacon_roles[...]` — the exact condition — to *suppress* the duplicate
waypoint marker. The feature is that condition, used a second time.

**The mark is the waypoint's own ring.** `iqm_role_waypoint`, the four-arc pulse generated
from the map atlas's `BLINK_R` / `BLINK_W` / `BLINK_GAP_DEG`, drawn at `RING_K` = 1.5 around
the role glyph. It is literally the mark the stood-down waypoint marker would have shown on
that body, so around a medic cross it reads "waypoint **and** medic" with nothing new to
learn — the same rule as R2.29's glyphs and R2.34's colours. Centred on the **glyph**, not
the badge: the badge is taller (it holds the readout), so centring there hangs the ring low.

**A second widget, deliberately, and this is the R2.31 boundary.** R2.31's rule is not "never
add a widget" — it is *anything that must be concentric to a hairline must be baked*, because
the engine floors each widget's top-left to a whole screen pixel independently. That failure
was a dark keyline hugging a glyph, where one pixel is the whole feature. A ring at 1.5× with
clear space around the glyph is a frame, not an outline; a pixel of play in it reads as
nothing. Baking ringed twins instead would cost **six** atlas cells against the two free in
`iqm_roles`, and would double the art maintenance for every role glyph forever.

**The bug found on the same line, which was the bigger half.** The suppression tested
`tracked[wid]`, and **tracked is not marked**. Quest targets are the one role tracked at any
range while their marker still stops at `beacon_dist`. So waypointing a quest giver 100 m off
suppressed the waypoint marker in favour of an NPC marker that was never drawn: **nothing on
screen at all**, from `beacon_dist` out to wherever that NPC goes offline — roughly a 60 →
150 m band, on the one marker explicitly exempt from the range rule (*"it marks at any range,
which is the whole reason to place one"*). Now a range test. Service roles never showed it:
since R2.35 they are only tracked within marker range, so the two coincide for them. The card
is still covered — inside `beacon_d` with the card up, the card marks that body.

**`draw_beacon`'s signature stopped growing.** It gained a parameter in each of R2.34, R2.37
and this change; it now takes the candidate record itself and unpacks `tex/col/nmt/wp` in one
place. Twelve parameters instead of fifteen, and the next thing a marker needs to know about
its subject costs none.

**R2.38a — the ring was too big, and the layout did not know it existed.** Reported from a
screenshot: the ring crowded the range readout. Two separate faults, and only one of them
was the size. `RING_K` 1.5 → **1.28** — at 1.5 the ring was the widest thing on the badge, so
a waypoint made the whole marker grow. But the collision was geometry: the readout sits
directly under the glyph with `BADGE_GAP` between them, and the ring is sized off the glyph,
so it reached *below* it into that gap. Shrinking `RING_K` alone would only have made the
overlap smaller. The overhang (`rox`/`roy`) is now part of the badge metrics — the glyph is
inset by it, the readout is pushed clear of it, and `bh`/`bw` include it, so the chevron's
attachment point is honest about what is actually inside the box. Both are zero when there
is no ring, so an unringed marker lays out exactly as before.

**`tools/waypoint-harness` (31 checks)** is mostly one property, swept over every range, role,
tracked-ness and card state: **something is always drawn on a waypointed NPC, and never two
things**. That is the invariant the dead band violated. Verified from both ends — reverting
the range test in the source fails it, and breaking the *model* the same way fails the
invariant itself, so the property is not vacuous.

### R2.37 — The name above the marker, and the one thing it cannot do · **2026-08-15**

`beacon_name`, Advanced on the Waypoint markers page, **off by default**. Prints the NPC's
name above the badge, reusing `name_from_obj` so it inherits `short_ranks`.

**The cost, stated plainly: the name is the only part of the marker that cannot scale.**
Since R2.30 the glyph, chevron and range digits are all sprites sized from `beacon_size`, so
one slider moves the whole badge. A name has to be real text — arbitrary, and localised, so
it cannot be pre-rendered the way the digits were. Engine text draws at a fixed pixel height
picked from a resolution bucket (`GameFont.cpp:31-38`) and `SetHeight` is not bound to Lua.
`beacon_size` runs 8 to 40, a **5× range**, so at one end the name towers over the glyph and
at the other it is a caption. There is no fix, only the choice of whether to have the
feature, which is why it is off by default and why the option's own description says so.

**The font is forced, and not by taste.** `small` is the obvious pick and is unusable: it
resolves `hud_font_small` → `stat_font` → `ui_font_hud_01`, and `CGameFont::Initialize`
excludes that texture from the localisation prefix (the `is_di` test, GameFont.cpp:76-80).
One ASCII atlas for every language — a Cyrillic name would not render, and this mod ships an
RU locale. `letterica16` is the smallest localised font (`fonts.ltx:69` has its `_russian`
section) and is what the cards already use. Worth recording because the constraint lives
entirely in the engine and is invisible from this repo: the next person to "tidy" that font
down to `small` breaks RU and nothing here would complain. The harness complains.

**A bug this would have shipped with.** `t.name` was resolved inside the branch that runs
only when the **card** is visible. The marker exists for exactly the case it is not, so a
name read from there would have been empty in every situation the option is for. One line
moved above the branch — and guarded on `obj`, or a despawning NPC caches `""` forever.

**One knowing step back.** Text cannot carry a baked keyline, so legibility over sky needs a
second black `CUITextWnd` offset a pixel — the very thing R2.31 removed everywhere else,
because two widgets are floored to whole screen pixels independently and shimmer against
each other. The cards have always done it this way; it is soft enough on text to pass where
it did not on a hard-edged glyph. Recorded so it reads as a decision, not an oversight.

Smaller calls: the name wears the **marker's own colour** — the accent, or whatever
`beacon_color` resolved for that role. It first shipped in the cards' warm off-white on the
grounds that the glyph already carries the colour coding; asked for and changed the same
day, and the request is the better call — two elements of one marker in two colours is a
distinction that means nothing to look at, and `beacon_color` should not tint half a marker.
The one thing to watch: the glyph survives a dark tint because R2.31 baked a keyline into
its art and **text cannot have one**, so the name has only its shadow copy and is the
element where a dark faction colour (army, ISG) has least help. The band flips **below** the
badge when the marker is parked at the top of the screen, since a marker is at an edge
exactly when it matters most. And the player-placed waypoint gets no name, having no NPC.

**`tools/name-harness` (36 checks)** covers the part that is testable — the band never
leaves the screen, stays centred when it can, favours the *start* of an over-wide name, and
flips only when it must. The rest are constraints pinned as source assertions: the font is
`letterica16` and not `small`, the shadow matches it, the name is measured only when it
changes, and the resolve still precedes both the offer and the card draw. Mutation-verified
both ways — switching the font to `small` fails it, and putting the name resolution back in
the card branch fails it.

### R2.36 — A relations bucket is not a job · **2026-08-15**

Reported from play: *NPC Arnie in Rostok is marked as a VIP but uses the trader waypoint
icon.* He is the Loner **arena manager**. He sells nothing.

**One signal, trusted too far.** `service_role` had five ways to call someone a shop, and
`<community>trader</community>` was one of them. That field is not a job — it is the
**relations bucket** meaning *neutral, in no faction* — and Arnie is neutral, so he has it.
Walk his evidence and every other signal is absent: section `bar_arena_manager` carries no
trade word, his logic block has no `trade =` because he has nothing to sell, and he is an
ordinary stalker rather than a trader clsid. The community field was the only thing
speaking, and it was enough.

Of the 23 vanilla profiles with `community = trader`, **about half sell nothing**: Arnie,
the Bar informant, `osoznanie`, and the seven Warlab pod stalkers plus the invisible one.

**What made it visible is that Arnie is authored as a VIP.** `bar_visitors_logic.ltx:457`:

```ini
;Arnie
[logic@bar_arena_manager]
level_spot = special          ; -> ui_pda2_special_location -> spot_role reads "important"
```

`spot_role` was right. But `extras_scan_one` asks `service_role` for a second opinion
whenever the answer is `important`, because a VIP spot genuinely can hide a real shop — and
that second opinion, resting on the community alone, overruled it.

**Nimble is the control case, and he settles the design.** `zat_a2_stalker_nimble.ltx:5-6`:

```ini
level_spot = special
trade = items\trade\trade_stalker_nimble.ltx
```

Same VIP spot, same `trader` community — and a real catalog. He is exactly why the override
exists, and he is caught by evidence about the **job**. Nothing in vanilla depends on the
bare community signal: every other genuine service NPC has a catalog, a trader clsid, or a
trade word in its section. Neither do the dialog-trade mercs the fallback was written for —
they are community `killer`, so the weak signal never caught them in the first place.

**Fix: tier the evidence, don't delete it.** `service_role` now returns a second value,
`weak`, true when the community was the only thing that spoke. `extras_scan_one` applies two
different bars, because these are two different acts:

- **`role == nil`** — nobody has said anything about this NPC. Any signal beats silence and
  the worst a wrong one costs is one stray card, so a weak verdict is accepted.
- **`role == "important"`** — the NPC's logic carries an authored `level_spot = special`, and
  replacing it means **declaring the game wrong about its own character**. That takes job
  evidence. A weak verdict is refused.

Arnie and the Bar informant (same shape: `level_spot = special`, no `trade =`) go back to
`important`, and since important has carried no marker since R2.29, *staying important* and
*losing the marker* are the same statement. Nimble, Cardan, the guides and the dialog-trade
mercs are untouched.

**Residual, knowingly kept:** a spot-less NPC with nothing but the community — the Warlab
pods — still gets a trader card. That is the accepted cost of the lower tier and it is
pinned as a fixture so it stays a decision rather than becoming a surprise. Deleting the
signal outright is a one-line change if it ever proves worth it.

**And a mismatch that is now always deliberate.** Even when the override is *correct*, the
two views disagree: Nimble is a purple VIP bust on the map and a gold trader glyph in the
world. That is the same species of complaint this entry started from, with a right answer
underneath it. Kept on purpose — the map says *who someone is*, the marker says *what you
can do here*, and "there is a shop" is the more actionable fact. Worth knowing, because
after this every remaining mismatch of this kind is intentional.

**`tools/service-harness` (31 checks)** drives the classifier over nine fixtures transcribed
from the shipped configs, each carrying the file and line it came from — so it tests against
the game rather than against a recollection of it. Arnie and Nimble are asserted as a
**pair**: they differ in exactly one field, and that field alone must separate them. It also
reads the guard back out of `iqm_core` — verified by mutation, relaxing the override
condition to `if sr then` fails it.

### R2.35 — Service markers had a quarter of the range they claimed · **2026-08-15**

Reported from play: *the service waypoint markers don't seem to show with the same
reliability as the turn in quest markers — they seem to only show when much closer.* They
did, and by roughly 4×.

**The two halves of the mod were answering different questions.** Quest targets arrive from
`task_manager.task_info` **already identified** — `collect_desired` iterates them, so there
is no distance filter anywhere in that path and the marker reaches `beacon_dist`, 60 m by
default. Service and guide NPCs have to be *found*: the engine binds map spots **by id
only** (`map_has_object_spot(id, spot)` — `map_manager.h` has the container but nothing
that enumerates it is exposed to Lua), so the mod runs the question backwards and asks each
NPC in turn. That scan needs a cap, and the cap was `appear2` — **16 m**.

| | tracked out to | marker reached |
|---|---|---|
| turn-in | no limit | `beacon_dist`, 60 m |
| guide + four trades | `appear_dist`, 16 m | 16 m |

**And the felt range was narrower still**, because a marker is suppressed while its card is
up — and inside 16 m the card *is* up whenever the NPC is visible. So a service marker could
only appear within 16 m **and** with the NPC behind cover or off-screen. A sliver of the
intended behaviour, which is why it read as unreliable rather than as short-ranged.

**Neither line is wrong where it sits, which is why this survived three releases.**
`<= ctx.appear2` is obviously right next to a card that fades to nothing at `appear_dist`.
`beacon_d = max(appear_d, C.beacon_dist)` is obviously right next to a marker meant to reach
past the card. Only the *relationship* between them was wrong, and no reading of either
function alone shows it. The cap was correct while the scanner fed cards only, and was never
revisited when markers were given a longer reach of their own.

**Fix:** `extra2` — the scan reaches `max(appear_d, beacon_d)` when a beaconable extras
role's switch is on, and stays at the card's range when neither is, so an install not using
service markers pays nothing. Two guards make the widening affordable:

- **The work probe stays home.** `tw_has_work` is the expensive cold check the whole of
  `iqm_taskwork` exists to ration, and work is a card with no marker. It is now gated on
  `near`, so the wider extras range cannot quadruple the population it probes to buy nothing
  drawable. `iqm_taskwork.apply_config` pulls `appear_dist` for the same reason.
- **The trim.** Past the card's range only roles that can carry a marker are kept. Otherwise
  the wider scan would spend `MAX_CARDS` slots and `FILT` records on cards drawn at alpha 0
  — and would scan `important`, which has carried no marker since R2.29, at four times the
  range for nothing.

**Considered and rejected: building the registry the engine won't give us.**
`stalker_generic.add_level_spot` / `remove_level_spot` are the functions that put these
spots on the map, they are globals in a vanilla script with a `data` winner, and **no mod in
the tree touches them** — a clean rung-2 monkey-patch, and it would make services work
exactly like turn-ins, registry and all. Two reasons not to: `map_spot` and `show_spot` are
*condlists* evaluated when logic is configured, so a registry caches an answer the current
code re-asks the engine for every pass — trading a live query for a stale one to solve a
range problem is the wrong trade. And it would not cover everyone anyway: `service_role`
exists precisely because dialog-injected traders and merc guides (Dushman, Leopard) carry no
service spot at all. Worth revisiting only if the scan itself ever shows up in a profile.

**`tools/reach-harness` (42 checks)** asserts the relationship rather than either half:
service reach equals marker reach with the switches on, the scan does *not* widen with them
off or on a bare exe, the trim drops the non-marker roles past `appear_dist`, and the work
probe stays on `appear_dist`. It also reads the three edits back out of `iqm_core` so a
revert fails here rather than in play — verified by mutation, putting `ctx.appear2` back in
the gate fails it.

### R2.34 — The marker takes the map's colour · **2026-08-15**

Asked for: faction colours on turn-in markers, and map-icon colours on markers generally.
Shipped as **one** MCM list (`beacon_color`) rather than two switches, because for a turn-in
the two are mutually exclusive and a pair of checkboxes would let both be ticked:

| mode | turn-in | trader / technician / barkeep / medic | guide, own waypoint |
|---|---|---|---|
| 0 accent (default) | gold | gold | gold |
| 1 map icon | the hand-in green | that trade's map colour | gold |
| 2 + faction turn-ins | the NPC's faction, else stalker amber | that trade's map colour | gold |

Mode 2 **layers on** mode 1 rather than replacing it. A medic has no meaningful faction
identity — *being a medic is the identity* — so the services keep their map colour in both.

**This reverses a decision, and the reversal has a cause.** `draw_beacon` said markers take
the accent *"and nothing else"*: one is read at a glance, often against sky, and a dark tint
would make it the least legible thing on screen. That was true when written. **R2.31 is what
changed it** — every part of the badge now carries a black keyline baked into its own
texture, so a dark tint keeps its edge against sky and foliage instead of dissolving. Army
(107,142,90) and ISG (122,139,106) are the test cases: before R2.31 they were unusable, and
they are the reason this stays opt-in with the accent as the default *and* the fallback.

**The turn-in is GREEN, and the first cut got it wrong — worth recording, because the
mistake was subtle and the fix is a rule.** R2.34 mirrored `storyline_task_spot` /
`secondary_task_spot` and so split the turn-in into a gold and a pale by task type. Those
are the wrong spots. They are the **go find it** mark, the reticle the map puts on an
objective. The `target` role is not that — every route into it reads REPORT BACK (see
`target_is_talk_to`) — and the map's mark for *that* is `iqm_mapspot_handin`, the green
diamond at 40,172,66, **which is already the glyph `BEACON_ICON.target` draws**. The glyph
mirror was right and the colour mirror was pointed one spot away from it.

`modxml_n_iqm_map_icons` states the grammar outright — *"reticle = go find it, green
diamond = done, go collect on it"* — so the answer was written down in the file the colours
were being copied out of. **The rule: mirror the spot the GLYPH came from, not the spot that
shares the role's name.** Two spots can both be about tasks and mean opposite things.

That collapses the two turn-in colours into one, since the map paints
`storyline_task_on_guider_spot`, `secondary_task_on_guider_spot` and ATUE's
`atue_return_task_spot` all the same green: handing in is handing in whatever kind of task
asked for it. `task.storyline` and the `story_targets` set it fed are gone with it.

**Two roles have no colour to match, for two different reasons.** Vanilla does not map-spot
guides at all. And PAW tints the placed waypoint with a *named* `color="blue"`, which
`color_defs.xml:6` resolves to **pure 0,0,255** — unreadable over the world, and the modxml
deliberately sets no r/g/b on that spot so as not to fight PAW's named attribute. Both fall
back to the accent, which is the right answer for the waypoint anyway: gold already reads as
*yours*. Their absence from `BEACON_RGB` is asserted, not just commented.

**A turn-in in mode 2 is always a faction colour, never the green.** A quest giver whose
community has no `FACTION_RGB` entry takes **stalker's** amber. That is aimed at the script
traders, which report the community `trader`: the loners' amber is the right read for a
neutral shopkeeper, and it keeps the mode from mixing its two vocabularies — a turn-in that
fell back to green would look like a faction colour the player could not place rather than
like a fallback.

The colour is a **reference** into `BEACON_RGB`/`FACTION_RGB` carried on the candidate
record, never a `{r,g,b}` built per marker — this runs per tracked NPC per frame, and a fresh
table there is garbage every frame. Resolved once per scan beside the glyph, for the same
reason the glyph is: role and community are both stable for a tracked entry's life.

**`tools/color-harness` (53 checks) exists for one failure that nothing else can see.** The
colours live in two files nothing connects — `BEACON_RGB` draws the world marker, `SPOTS` in
`modxml_n_iqm_map_icons` paints the map — and the entire promise of the feature is that they
agree. Edit one and not the other and nothing errors, nothing looks broken in isolation; the
two views just quietly stop matching. The harness mirrors them channel for channel (verified
by mutation: a one-channel drift fails it), asserts the two deliberate absentees, runs the
resolve over every mode × role × community × task-type combination to prove none of them can
reach `SetTextureColor` as black, and checks the menu's three values and both locales' strings.

### R2.62 — A colour of the marker's own · **2026-08-19**

Asked for: an RGB setting for the markers. They had never had one. `beacon_color`'s three
modes chose between the accent and the *map's* colours, and the accent is `col_r/g/b` on the
Nameplates page — so the only way to recolour a badge was to recolour the plates with it.
The route and the minimap trail have each carried their own three keys for exactly this
reason since R2.24; the marker had the same claim and nobody had made it.

**A fourth mode, not a fourth switch.** `{ 3, "iqm_bcol_custom" }` on the list that already
answers *what tints the marker*. A checkbox beside the list would let a player ask for the
map's colours and their own at the same time, which is the reason the list exists rather
than two flags (R2.34).

**Mode 3 is mode 0 with a different accent, and that is one line of behaviour.**
`draw_beacon` has exactly one place where a marker reaches for the accent, and everything on
the badge — glyph, chevron, waypoint ring, metre digits, the name — takes `cr/cg/cb` from
it. So the substitution goes there and nowhere else, ahead of the role colour rather than
after it, and the per-entry resolve in `iqm_core` is not touched at all: mode 3 is simply one
more mode that resolves to `nil`, because it asks for a colour that does not depend on the
NPC. The kind colours stay live, which is right — the mutant's lime is the *kind* speaking,
not the theme.

**The two `> 0` gates are the trap, and both are now `== 1 or == 2`.** The scan pass and
`offer_party` each tested "any mode above accent" for "take the map's colour". Left alone,
mode 3 would have inherited the map's role colours and the custom triple would have reached
only the roles the palette has no entry for — mode 1 wearing a custom fallback, which is not
what the row says. Two harness checks read those gates back out of the source, and a third
asserts the substitution sits *ahead* of the role colour rather than over it.

**The defaults are the accent's own 224/196/122**, so picking Custom changes nothing until a
channel moves: a starting position rather than a jump, and no colour change at the instant
the mode is chosen. The harness reads those three numbers out of the accent's rows instead of
restating them, so retuning the gold moves both. `tools/color-harness` is 165 checks now, up
from 127.

The honest cost, and it is a choice rather than an oversight: the head node and leader line
on the nameplate stay on the cards' accent, so a custom colour far from the gold means the
mark over a head and the badge through the wall are two colours. They are read at two
distances answering two questions. The alternative is that a marker setting silently
repaints the plates.

### R2.33 — The marker learns the one destination the mod did not choose · **2026-08-14**

Every waypoint marker so far has been on an NPC the *scan* found — a hand-in target, a
guide, a trade. This adds the one destination the player picked themselves: the waypoint
placed with Catspaw's **Personal Adjustable Waypoint**, marked through walls and off-screen
like the rest. `beacon_waypoint`, on by default, on the Waypoint markers page.

**It carries the map's own mark.** `modxml_n_iqm_map_icons` already re-skins PAW's
`paw_task_default_spot` to `iqm_mapspot_blink`, the four-arc pulse ring — so the marker draws
that ring, from `svg/waypoint.svg`, generated from the map atlas's own three constants
(`BLINK_R` 0.42, `BLINK_W` 2/25, `BLINK_GAP_DEG` 20). This is R2.29's rule (*the mark you
learn on the map is the mark you look for through a wall*) applied to the first cell whose
map counterpart is **not a pictogram**. Same treatment as the others: no distress, keyline
baked in (R2.31), `iqm_role_waypoint` at cell 13 of the 4×4 atlas.

> **librsvg refuses an SVG that opens with an XML comment.** `magick` reports it as
> `unable to read image data ... RenderRSVGImage`, which reads as a corrupt file rather than
> a rejected one. `svg/waypoint.svg` is therefore the only source here with no comment in it;
> its explanation lives in `build.py` and in `iqm_textures.xml` instead.

**Three rules it breaks, all for the same reason.** The constraints on this marker exist so
the overlay does not hand out positions the player has not earned. None of them is about a
position the player *chose*:

* **No `beacon_dist`.** A waypoint is marked at any range. That is the entire point of
  placing one, and marking it gives away nothing they did not already know.
* **No card, so no crossover.** The alpha `mult` is a flat 1 — there is nothing to hand over
  to. `WP_NEAR` (3 m) is its only gate: standing on the spot, a badge over your own head says
  less than the ground under your feet.
* **It rides no card role.** `mark_targets` gates the quest-marker family because the scan
  has to find them; nothing has to find this one. In MCM it rides PAW's *presence* instead —
  the only precondition in that menu that asks about the install rather than another setting,
  which is why the section caption now shows for `on_targets() or paw_here()`.

**It jumps the queue.** `beacon_offer` sorts by `(prio, distance)` now, and the waypoint is
the only candidate with prio 0. Nearest-first is right among markers the mod chose for you and
wrong for the one you chose yourself: four objectives in a camp would otherwise take all four
slots and drop it silently. Skipped entirely when the waypoint sits on an NPC already being
marked, so waypointing your quest giver leaves one marker on that body rather than two.

**And a bug fixed on the way in.** `render()` opened with `if next(tracked) == nil then
hide_route(); return end` — cheap and correct while everything drawn was a tracked NPC. It
stopped being correct when the route began following the *selected task* (§6c of
`docs/minimap-route.md`), because a task marker is frequently not a carded NPC and a placed
waypoint never is: **the ground route was being hidden whenever no NPC happened to be
carded.** The skip now asks all three consumers, with `route_draw()` hoisted to the top of
the function — it answers nil in one comparison when `iqm_nav` is not publishing, so the
cheap path stays cheap.

Waypoint resolution is `iqm_core.waypoint_goal()`, read straight from PAW rather than
through the selected task. Placing a waypoint *does* select its task, but select a quest
afterwards and the waypoint is still standing there — which is exactly when a marker on it
earns its keep. Position resolution is shared with the route's goal through the new public
`goal_pos(id)` (public, not local: this module has twelve of the engine's 198 locals left).

### R2.33 — The route comes from the player · **2026-08-15**

Reported after the shape work: *can we make the routing come from the player more — this
would avoid the strafed angle issues.* It is a better diagnosis than the one three sessions
have been working from.

**What was actually happening.** The route is an A\* path through the navmesh and the marks
sit **on** it. Strafe two metres to your right and nothing about the route changes: the whole
train stays two metres to your left, on the same ground, at the same headings, until you
stray past `DRIFT_TOL` (5 m) and it repaths. R2.31 measured the affine residual — a
`CUIStatic` is a rotated rectangle, the projection of a patch of ground is a trapezoid — and
concluded the swing was inherent. It is inherent; it is not *inert*. The keystone term
depends on where a mark sits relative to the vanishing point, so a mark that holds still in
the world while the camera slides sideways has its shape swept through the whole range of
that error. The residual was being **driven**, and what was driving it was the mark's bearing
on the camera changing — which is a fact about where the route is, not about how a quad is
fitted. Three sessions of work went into the fitting.

**The lead-in.** The near end of the drawn line is displaced laterally onto the actor and
decays back onto the search's answer over `LEAD_M` (8 m):

```
  offset(s) = clamp(actor - path(s_actor), LEAD_MAX) * max(0, 1 - (s - s_actor) / LEAD_M)
```

At the actor's own arclength that is the full residual, so the route starts at his feet
whatever he has done since the search; 8 m along, the line is exactly where A\* put it. It is
the same instrument `clearance()` already uses on this path — displace the points laterally,
smoothly, leave the shape alone — differing only in what is being avoided. Two consequences
worth stating:

* **The marks turn as well as move.** The blend adds `offset` to every point and the weight
  falls at exactly `1/LEAD_M`, so the blended curve's tangent picks up `-offset/LEAD_M`
  analytically — no differencing of neighbours, so it costs nothing and cannot pick up the
  lateral noise `CHEV_DIR` exists to average out. Bounded by `LEAD_MAX/LEAD_M`, about 14°.
  The near marks angle back toward the line, which is the turn you are actually being asked
  to make.
* **The stroke moves with them.** Both halves have to agree about where the line is on the
  frame it is drawn, or the marks float off it. That is why the blend runs in
  `place_chevrons` — per frame, like the marks — rather than in `build_draw_list`, which only
  runs when the cursor moves. `RD.p[i]` is a reference into `path` while the offset there is
  zero and a pooled vector when it is not, with `RD.src[i]` keeping the original: the common
  case allocates nothing and the search's answer is never mutated.

**`LEAD_MAX` = 2 m is the safety, and it is a real limit.** The drag has no mesh test on it,
so at some width it walks the head of the line through a wall. Two metres is inside the
corridor widths the Zone is built out of. Past it the head stops following rather than being
dragged further — the line no longer reaches your feet, which is the honest failure: it is
drawn where it can be walked. Between there and `DRIFT_TOL` a repath takes over anyway.

**To revert:** `LEAD_M = 0` disables it in one number, in both the stroke and the marks.

Harness-covered, and the checks are the argument: a strafe inside `DRIFT_TOL` does not
repath, the head arrives at the actor, the far end does not move, the offset decays
monotonically (a non-monotone blend is a kink, which reads as the route wobbling rather than
leading), it is fully back on the line by `LEAD_M`, the marks move and turn with it on unit
headings, a 4.5 m strafe clamps to 2 m, and stepping back onto the line hands out the path's
own points again rather than a copy of them.

**One bug found writing it.** The blend was first placed after `place_chevrons`' `gap_m > 0`
guard — but `gap_m` of 0 is *marks off*, not *route off*, so the stroke would have quietly
stopped following you the moment anyone turned the chevrons down. Hoisted above the guard.

### R2.33a — Paint, not a decal · **2026-08-15**

With the geometry landing, the remaining complaint was that the marks read as printed **on
the image** rather than painted on the ground. Four candidates were rendered as a
comparison sheet (`tools/route-preview`, ten panels, same scene and camera), and the sheet
refuted half of what proposed it — which is the argument for rendering them.

**What was wrong with my own diagnosis.** I read the shipped keyline as too thin. It is
not: `MARK_RIM` 0.09 is a strong black line in the texture. It is invisible in game because
a **black edge on dark concrete has nothing to separate** — the device only works against a
light background, and the Zone's floors are not one. Weight cannot fix that, and the
heavier-keyline panel shows it not fixing it. My first wear pass was wrong for a related
reason: the noise was at the scale of the chevron's own arms and read as moss. Paint wears
at the scale of the aggregate under it.

**What shipped — the amber set, all four together:**

| | | revert |
|---|---|---|
| `MARK_WEAR` 0.45 | alpha thinned only where the noise dips past `MARK_WEAR_THR`, so most of the mark stays solid and what reads is scuffing rather than a pattern laid over the glyph | `0` |
| `MARK_RIM_INK` 1.00 / `MARK_BODY_INK` 0.78 | the keyline **inverted**. Ink multiplies the route colour, so the device has two ends and both are free: sink the body instead of darkening the rim and the outline becomes the brightest part of the mark, which survives dark ground | `0` / `1` |
| `MARK_SHADOW` 0.45 | a contact shadow baked outside the outline at ink 0. Black survives the tint because `SetTextureColor` multiplies | `0` |
| `route_r/g/b` 232/196/92 | amber. Paint reads by being *brighter* than the ground; the olive sat so far into the Zone's palette it stopped announcing itself | `176/196/124` |

> **Superseded by R2.40 for the colour row only.** The default is the lifted olive
> 176/196/124 again, asked for directly and shipped alongside a baked camo pattern. The
> objection above still stands *against a flat fill* — and that is the half R2.40 changes:
> a flat mark has nothing but its value to be found by, while a patterned one carries
> internal contrast at a scale wet concrete does not, plus a full-strength keyline round
> the outside. The other three rows are untouched.

All five look constants live in **one block** in `tools/stroke-tex/build.py` and are baked,
so tuning is: change a number, re-run the script, reload. Nothing in the mod reads them.

**The shadow costs keystone, and it is the one thing here that is not free.** The halo has
to live inside the mark's rect, so the footprint grows by `MARK_SHADOW_W`/2 of an arm on
every side — and the affine residual scales with footprint **depth** and nothing else
(R2.31). `chev50` goes from a depth:width ratio of 0.50 to 0.56, about 24% → 27% of the
mark's width at 5 m. Paid knowingly: R2.33's lead-in stopped that residual being *swept* as
you strafe, which was what made it visible in the first place. `MARK_SHADOW_W` is the dial.

**`RTE.SPAD` is the one number that has to exist twice**, because the renderer must measure
the box the artwork was drawn into. Same contract as `FPAD`, louder failure — crop a soft
shadow at the rect's edge and every mark carries a hard straight line across it. Guarded at
both ends: `build.py` refuses to build on a disagreement and prints the value to paste, and
`tools/marks-harness` checks it at every run, because `build.py`'s check only fires when
someone rebuilds while the fault ships either way. Both were proved by reintroducing the
mismatch.

**A side effect worth naming.** Running `build.py` regenerates `iqm_stroke.dds` too, which
carries R2.31c's un-adopted feather change — so the rebuild silently adopts a card-underline
change nobody judged. Restored from git both times, and `check_shapes_match_mod()` is now
hoisted to the top of `main()` so a *failed* run does not leave two unrelated textures
rewritten either.

### Investigated — can the marks glow? · **2026-08-16**

Asked for luminescence on the ground marks. Four routes exist; one is dead, one is real, two
are cheap fakes. Nothing implemented — this is the survey.

**`script_glow` is a no-op stub on every renderer anyone runs.** The Lua class exists, takes
a texture, colour, radius, position and `lanim`, and constructs without error — and
`CGlow` in both `r2.cpp:19` and `r4.cpp:25` has an **empty body for every setter**. It stores
one `bActive` bool and discards the rest. Only R1 (`FStaticRender`) has a real
`CGlowManager`. So the primitive whose entire job is "a glow sprite in the world" does
nothing under DX9/10/11. Confirmed live: `script_glow ~= nil` is true, which is exactly what
makes this trap worth writing down — it fails by silently doing nothing, not by erroring.

Same shape as `debug_render.add_object` being wireframe-only (R2.30): the API is present,
the capability is not.

**`script_light` is real, and affordable if bounded.** `light_create()` returns
`Lights.Create()` in R2 and R4 alike. Full surface: `color`, `range`, `type`, `shadow`,
`lanim` (named flicker/pulse curves from the light-animation library), `lanim_brightness`,
`volumetric` + quality/distance/intensity, `hud_mode`. Precedent in GAMMA: `nta_utils`
(Tasks QoL / New Tasks) spawns one for its task pulse, FDDA's `ea_light`, ZCP's anomaly
fields.

Measured live, in the Bar at 17:14, 16 point lights at range 5 with `shadow = false`, spaced
3 m apart along the actor's facing — i.e. exactly `MAX_CHEV` marks' worth:

```
baseline, no lights   69.2 fps   (1323 frames / 19.1 s)
16 lights on          66.6 fps   (64-68 across 24 samples)
lights off again      68.2 fps   (drifting to ~71 as the player moved)
```

**Roughly 3-6%, about 0.5-1 ms a frame.** Noisy — it was measured in a live session with the
player moving, and deferred light cost scales with screen coverage, so a night interior with
all 16 in view would cost more than this. But it is not the order of magnitude that rules the
idea out.

**What a light can and cannot do here.** It lights the FLOOR; it cannot light the mark. The
mark is a `CUIStatic` drawn in the UI pass, so nothing in the scene's lighting reaches it.
That may be exactly right — paint does not emit, and a glowing patch of floor under a mark
reads as luminous paint — or it may read as disconnected, with a lit floor and a flat glyph
sitting on it. That is a judgement to make on screen, not on paper.

**The UI layer cannot bloom.** Marks are drawn by `CDialogHolder` after the scene's
post-process chain, which is why the 3D PDA needs an explicit `ps_r4_hdr10_pda = 1;
// !!! HACK !!!` (`Level.cpp:1238`) to interact with HDR at all. So any glow painted into a
UI sprite is only pixels: it will not spill light, will not respond to darkness, and in
daylight will read as a smudge rather than as a light. Source-indicated rather than traced
end to end, but the HACK is a strong tell.

**Two cheap fakes, both reusing machinery already proven here:**

- **A baked bright halo** — `MARK_SHADOW` inverted. The builder already bakes a soft dark
  halo outside the outline using the shape's own distance field; a bright one is the same
  code with the ink at 1 instead of 0. One texture rebuild, no new engine surface. It costs
  keystone the same way the shadow does, because the halo has to live inside the mark's rect
  and the residual scales with footprint depth (R2.31).
- **A pulse** — the per-mark tint is already computed every frame, so modulating it costs
  nothing, and `RD.cn` (R2.42) gives each mark a stable id to phase off, so a wave can run
  along the route rather than every mark breathing together.

`CUIStatic::SetColorAnimation` **is** bound to Lua (`UIStatic_script.cpp:42`, with
`ResetColorAnimation` / `RemoveColorAnimation`) and drives the engine's own blinking HUD
indicators. It is the wrong tool here anyway: the mod writes `SetTextureColor` every frame
for the near/far/occlusion fades, and an engine animator on `LA_TEXTURECOLOR` would fight it
every frame. A pulse in the mod's own tint arithmetic is simpler and fully controllable.

**If it gets built**, the lifecycle hazard is known and has already bitten this mod once: a
save load re-reads `.script` files, so a light held in a file-level `local` is orphaned while
the render object stays alive — the dialog bug of R2.28, with a light that cannot be turned
off instead of marks glued to the camera. Namespace-global pool plus a teardown on
`actor_on_net_destroy`, exactly as `HUD_STATE` does.

### R2.58 — A borrowed marker, and the frame as a verb · **2026-08-17**

**The hand-in marker was never ours.** Reported as *"the delivery icon shows green but the other
hand-in quests are not"* after uninstalling gamma-active-task-ui-enhancements. Two features looked like
one half-broken feature. The delivery green is ours — `iqm_scan` reads `delivery_task`'s status functor
and draws the envelope. The hand-in green was **ATUE's**: it set `atue_return_task_location` itself and
this mod only *re-textured* it. Remove ATUE and the marker vanishes, because the meaning lived over
there and only the picture lived here. Our diamond cell survived with nothing pointing at it.

Confirmed live rather than reasoned about — three tasks at `stage >= stage_complete` with
`current_target == task_giver_id` came back `kind=nil` and drew the plain white reticle. And the cause
was not a missing classifier but an explicit bail: `task_kind` opened with
`if target_is_talk_to(task) then return nil end`. It now returns `"handin"` there.

`handin_state` is deliberately **stricter** than the neighbouring `target_is_talk_to`. That one fails
*open* — no `stage_complete` counts as talk-to — which is right when the answer only suppresses a
marker and wrong when it paints one, so this fails *closed* and adds the second half: the marker must
be on the **giver**. Both halves are load-bearing; a delivery mid-run passes the giver test and fails
the stage test. It is also the one kind never cached, because unlike every entry in `kind_seen` it is a
property of the task's *progress*, not of its section.

**The frame carries the verb, not the noun.** New grammar, and it made the rest fall out:

| frame | meaning | marks |
|---|---|---|
| ring badge | someone is **here** | medic, trader, barman, mechanic, bed, VIP |
| task reticle | go and **find** this | mutant, bounty, open |
| bare glyph | go and **give** this to a named person | delivery, hand-in |

`static_border` is **not** part of that and both keep it. Dropping it from hand-in was a real mistake,
briefly shipped: it is the engine's active-task indicator (`show_static_border` against `ActiveTask`),
the only on-map answer to *which task am I following*. Removing it didn't simplify the mark, it deleted
a signal.

**The diamond → a tag.** Reported as hard to read, which sounds like size and wasn't: it inked 28.9% of
its cell against the envelope's 29.1% — identical mass. It failed on **structure**, that ink spread
over two thin concentric outlines so each ring was ~1 px at drawn size and they blurred together. A
tick tested at 19.4% ink and was the most legible thing on the sheet. **For a bare glyph at this size
the criterion is stroke width, not ink: solid regions beat concentric outlines.** The tick lost on
meaning — it reads "finished, nothing to do" where the mark means "go here and collect". A coin loses
its device by 26 px and becomes a disc that collides with the squad dots. `FIT_SCALE` 0.79 on both
hand-in and delivery equalises them at 29.1/29.2%.

**Barman.** Asked to join the other services' colour family. It can't: within the family's lightness
band every hue from 160–260° lands at dE 24–29 against trader, mechanic and bed — under the dE 28 floor.
The cool band is full, which is *why* the barman is magenta. What was actually wrong was tone — L\* 53 /
C 72, the darkest and most saturated badge against trader's L\*72/C46. Now (255,128,185), L\* 70 / C 55,
in the band and still clearing everything by dE 40. Its mug also moved 2 cell px right: the bbox was
dead centre but the *lit ink centroid* sat at 61.2, because the body is solid while the handle jutting
right is thin outline, and the eye centres on mass (`GLYPH_NUDGE`).

**Fast travel is no longer patched at all**, by request — back to AlphaLion's art. The cell and texture
id are kept, unused, the way `skull` is, and the legend row was released with it: a legend row is a
claim that the panel and the map show the same mark, and has to be given up the moment that stops being
true.

### R2.60a — The handover that was not invisible · **2026-08-19**

A review pass over R2.60, the same day. The `beacon_targets` fix was right about the bug and
wrong about where the two marks on a hand-in's body should meet.

**Inside `beacon_dist` the selected task's mark was standing down for the role's**, on the
argument that the two glyphs are identical so nobody could tell. Two things cross that
boundary with the glyph. Mode 2's faction tint and `beacon_name`'s caption are role-marker
business, so a selected hand-in's mark changed colour and grew a name at 60 m. And the mark
came back from the tracked loop at `ROLE_PRIO.target` — **prio 1, where it ties with every
other pending turn-in and ties break on metres**. Stand in a hub with six nearer turn-ins and
the task you selected on the PDA is the one dropped from the six slots: R2.39's silent
eviction, arriving through the one door prio 0 had always kept shut.

**So the precedence runs the other way now.** `offer_task` keeps prio 0 and asks a narrower
question — `carded`, the card on its own body, rather than `marked` — and the tracked loop
skips that id outright, the same skip `offer_party` already makes for `wid`/`tid`. Every other
pending hand-in is still the role's marker inside `beacon_dist`. The card still wins on that
body, which is the one thing that never changed.

**`marked` also had to ask whether the body is still there.** Its role clause answered on role
and range alone, while the loop that draws that marker needs a live object for its anchor —
and `tracked` keeps an NPC who died or went offline until the next scan prunes them. For up to
one scan interval the test claimed a mark nothing was drawing, which is the R2.38 dead band
reached from a third direction, and reached from one `goal_pos` used to cover: it answers for
offline ids and the tracked loop does not. One `level.object_by_id`, on a body that is tracked,
in range and markered — the case that was about to answer true anyway.

**The role harness was certifying the bug it was written to name.** Its `BEACON_ROLES` copy
still omitted `target`, so `merge{target, trader}` still asserted `mark == "trader"` — the
pre-R2.60 answer — and reported 41 green while production answered `target`. It now sweeps
*both* gates, because `beacon_targets` makes both shipped states: on, Petrenko draws his own
hand-in mark and the two views agree; off, he is back in the state `want_marker` was written
for and the fall-through must still hand him the trader glyph. 49 assertions. The waypoint
harness grew a `gone` axis for the dead-body clause and re-taught the merge: 74, green.

**Two stale mirror comments went with it** — `iqm_core`'s "three of the roles that win a card
carry no marker" (it names `target`, which now does) and the `br.target` note's claim that a
crowd of turn-ins can crowd out a shop but not each other (they can; they share a priority).

### R2.60 — One man, two answers · **2026-08-19**

Reported as *Col Petrenko is showing as a trader icon when he also has a hand-in task, which
should be the one displayed.* Confirmed live in `l05_bar` before touching anything, and the
two halves of the mod disagreed in exactly the way described:

```
iqm_scan.desired_set()  -> [19097] = "target"    <- the card: REPORT BACK
iqm_scan.marker_set()   -> [19097] = "trader"    <- the through-wall marker
task bar_dolg_general_petrenko_stalker_task_3
       kind = "handin", stage 1, map spot = iqm_task_handin
```

**The card and the map were right; only the marker was wrong**, so this was never a detection
failure. `task_kind` had him, `iqm_taskspot` had already moved his pin to `iqm_task_handin`,
and the card had picked `target` on priority. The marker alone said trader.

**Every rule in the chain was behaving as written, which is why nothing looked broken.**
`desired` keeps one role per NPC and the lowest `ROLE_PRIO` wins, so `target` (1) beat
`trader` (6) — correct. `want_marker` (R2.58) keeps a *separate* answer for the marker,
because a role that wins the card does not always carry one, and a markerless winner used to
take the marker away from a role the same body also qualified for. That rule is what stopped
Petrenko drawing *nothing* through a wall in R2.58 — the previous report on the same man — and
it did the only thing it could here: handed the marker down to `trader`.

**The fault was one rung below all of it: `target` had no marker to keep.** `br.target = nil`,
retired in R2.46 when the selected task got a mark of its own. That decision is still right
about what it was for — the marker had never asked which task was *selected*, so selecting one
on the PDA changed nothing on screen. What it missed is that **a hand-in you have not selected
is still a hand-in**, and on a body that also sells things it was now competing with a shop and
losing. Petrenko's hand-in was not the selection (`iqm_beacon._tk = {id = 19091, kind =
"delivery"}`), so nothing objective-shaped was ever offered for him.

**The fix is the one assignment R2.46's own note promised it would be** — `br.target` back, on
a new `beacon_targets` row, default on. Nothing else in the marker path changed, and
`want_marker` needed no edit at all: give a role a marker and it stops being handed down,
which is the property that keying exists to have.

**One mark per body still holds, by range rather than by precedence.** Inside `beacon_dist`
`marked` sees the role and `offer_task` stands the selected task's mark down; past it the role
is out of reach and the task's mark is what draws. Both glyphs are `iqm_role_handin`, so the
handover is invisible. The selected task keeps what only it can claim: prio 0, no range gate,
and the kind dressing. *(Superseded by R2.60a above: the handover was not invisible, and
standing the selected task's mark down cost it prio 0.)*

**What it costs is R2.46's complaint, now bounded and switchable.** Every pending hand-in
within `beacon_dist` can hold one of six slots — bounded by the distance, the slot count, and
prio, which sorts objectives ahead of the ambient band. Selecting a task still changes what is
drawn; it no longer changes whether anything is.

**`delivery` is the same hole, left open deliberately.** Also `ROLE_PRIO` 1, also unkeyed in
`beacon_roles`, so a courier drop on a shopkeeper still marks the shop. `BEACON_ICON.delivery`
exists and `br.delivery` is the same one line — held back because it would put an envelope over
every recipient in range, which is a change nobody asked for rather than a repair of one that
was reported.

**The waypoint harness caught the knock-on and had to be re-taught.** Its model keys
`BEACONABLE`, and R2.46's removal of `target` from that set was what forced the `card_up`
clause in `marked`. Putting `target` back moves the handover on a waypointed quest giver from
"the waypoint stays up all the way in" to "the NPC's marker takes over at `beacon_dist`,
wearing the ring" — the service-NPC case. The `card_up` clause **stays**: it was never only
about `target`, `work` and `important` have always been markerless, and switching
`beacon_targets` off has to return `target` to that set without returning the R2.38 dead band.
65 assertions, green.

### R2.57 — A skull and a bust are the same silhouette · **2026-08-17**

Asked for a better human-combat glyph so mutant hunts and firefights would be easy to tell apart on
the map. The glyph wasn't the problem.

**Both marks were the same silhouette class.** A skull is a round mass over a wider mass; so is a
bust. The eye sockets and the shoulders that distinguish them are sub-pixel at the 26 px a spot draws
at, so the two task kinds differed in **colour alone**. A military helmet was tested and fails for
exactly the same reason — round dome, same family — and paired rounds read as two bars.

**And colour cannot carry it.** Mutant lime (176,216,72) against bounty red (172,60,66) sits on the
red–green axis, the one red–green colour deficiency collapses. For those players the silhouette isn't
redundancy, it's the only channel separating a mutant hunt from a firefight — and two round-headed
figures gave them nothing. This is the palette rule in `modxml_n_iqm_map_icons` (shape carries the
red/green axis) failing in the one place it mattered most.

**Crossed swords** (Game-icons.net, CC BY 3.0), because it's the only candidate that changes the
silhouette *class*: hollow in the middle with four limbs to the corners, where every alternative is a
solid centred mass. It's also all long straight strokes, which is what survives the 8× downsample, and
square, so it fills the reticle's inner box. The bust is kept at `svg/bounty-bust.alt`.

Three weapon glyphs were measured against each other, and the measurement inverted the eyeball read —
the swords *look* spidery and the rifles *look* solid, but glyph-only lit pixels say otherwise:
skull 3395, **swords 1514**, mp5 1149, ak47u 998. A rifle is one thin diagonal with a lot of empty box;
the X spreads across the frame. A single pistol was rejected earlier on aspect: at 1.53:1 `fit()` sizes
the long axis, so it starts at two-thirds height before the frame takes its cut and collapses to a bar.

`RETICLE_FIT_SCALE["taskbounty"] = 1.15` closes the remaining ink gap (45% → 55% of the skull) with the
blade tips still clear of the reticle arcs; 1.30 puts them through it. Note this is a *different* kind
of correction from the hand-in diamond's 1.12, which fixes a bounding-box artefact — the swords aren't
mis-sized, they're thin.

**The keyline is in cell pixels, so it is only constant if every spot is the same size.** What reaches
the screen is `outline/128 × drawn_px`, and across the atlas that lands at 0.61–0.81 final px on almost
everything. The house fell through it: at 12 units it is the smallest bare glyph here, so
`GLYPH_OUTLINE = 3` arrived as **0.38 px** — half what sits beside it, and below one pixel a keyline
stops being an edge and becomes a grey blend with the terrain. No tint fixes that. New
`GLYPH_OUTLINE_BY_NAME = {"home": 7}` puts it at 0.88 px, matching the medic badge's 0.81. 9 was tried
and closes the doorway at the 13 px a zoomed-out map draws, which would cost the glyph the one feature
that stops it reading as a pentagon. The chroma objection that drove 6/4 → 4/3 applies least here of
anywhere: a solid silhouette inks 51% of its cell against a ring badge's 35%, so even at 7 the black
share is 24% — the same as the medic cross after that fix, and far from the 37–49% that caused it.

`squadmini` was already an override of exactly this kind, at twice `OUTLINE`, for exactly this reason.
It just wasn't generalised, so the next small spot repeated the bug.

**A pin was re-tested and reverted — but the no-circle rule fell anyway.** That rule said the
handheld 3D PDA squashes every spot to 0.75 width, and while a rectangle merely narrows, a circle
becomes an oval and the eye reports it. It's why this cell became a house in R2.55. What it missed is
that *the same is true of everything else in the atlas*: twelve ringed badges are circles, they oval in
exactly that view, and the pack has always accepted it. Rendering a squashed badge beside a squashed
pin settles it in one look — identical distortion. The real criterion was never "avoid circles" but
consistency with the other marks, and a pin passes it while a lone house is the one silhouette on the
map belonging to nothing else. (Checked against the live game rather than assumed: `g_3d_pda` reads
`on` here, so the squashed view isn't hypothetical.)

What was actually wrong with the pin the first time was **size and weight, not shape** — 30 units of
spot around 17 px of ink, with a keyline arriving at 0.38 px, so the head was a pale edgeless blob and
"the circle is squashed" was the explanation reached for. At 12 units with the keyline at 7 it reads as
a ring with a hole at every size down to 13 px.

**The house ships regardless**: the pin was reverted on preference, not on geometry. Both stand as
plausible marks and the call was which reads better, which is the only thing either swap ever turned
on. The tested pin is kept at `svg/home-pin.alt`. What survives is the correction — the squash argument
is spent and should not be re-litigated, and the two faults it was masking (a spot sized by footprint
instead of ink, and a keyline that never scaled with drawn size) were real and are fixed.

**Also: `_preview.png` was three releases stale**, still showing the bust and missing the delivery row,
because `write_preview` sits behind a `--preview` flag while the atlas and DDS rebuild unconditionally.
A contact sheet whose entire purpose is to be looked at should not be the one artefact a plain build
leaves behind.

### R2.56 — The fast-travel house: sized by the wrong quantity, and the zoom answer that was backwards · **2026-08-17**

Three reports on one mark — *"doesn't look very good"*, *"larger than the previous icon"*, *"doesn't
reduce in size as the PDA is zoomed out"*. All three were right and all three had been answered
wrongly first.

**Sized by footprint instead of ink.** R2.55 calibrated the house to 20 units by matching the medic
badge's rendered 26 px, and hit it exactly — measuring the teal component of a shipped screenshot
returns 26×26. The quantity was wrong. A badge spends 26 px on a ring stroke with a small glyph
inside; a bare house spends it on one solid mass. Tinted ink per cell, keyline excluded: reticle
24.7%, transition 27.5%, VIP 30.7%, medic 34.9%, **house 51.1%** — about 1.5× the badge's coloured
area in the same box, contiguous rather than seen through. **Size a bare glyph by ink, not by box.**

**And by the wrong baseline.** The note claiming AlphaLion's art is "a teal house on a dark rounded
square", and therefore that its 11×15 was a *box* that had to fit rather than the mark's true size,
was false — sampling rect 1,64,11,15 of `ui_MapSpots.dds` shows a hollow house *outline* with a solid
door, inking 11×12 of that rect at 30.9%, i.e. right in the badge band. It looked correct because it
was an outline at badge weight. Measuring both marks in one screenshot puts its teal at 0.625 of the
medic badge — ~11 units of visible mark against the 18.4 a 20-unit house produces. So R2.55 was 1.7×
linear and ~2.8× by area on what it replaced. Now **12×12**.

**The glyph.** Tabler `home-2-filled`, once its window came out in R2.55, was a rounded pentagon at
26 px — heavy corner rounding, almost no eave overhang. Replaced with Material Symbols `home`
*inverted* (its outer subpath alone), which fills the silhouette and leaves the doorway as a hole.
Eaves that read as a roof, and a feature that breaks the mass. Its door is 12.5% of the house width,
so its feet are ~11 px at drawn size — the failure that got `home-filled` rejected in R2.55, where
the doorway ran off the bottom edge and left ~2 px feet, does not recur. Check the feet, not the door.

**The zoom report, which was answered backwards twice.** Both earlier answers said no marker in this
pack scales with zoom, so the house was behaving like everything else. Auditing every element in the
merged spot files for `scale` attributes says the reverse: the anomalies, stashes and treasures, smart
terrains, faction and campfire circles, item spots, combat spots, ZCP's landmarks and the whole of
PAW's pin library all carry `scale="1"`, mostly 1→1.2 or 1→1.5. The marks that *don't* are almost
exactly the ones this mod patches. And the neighbour being compared against does something stronger:
the service badges carry `scale_min="3"` with no `scale`, which reaches `UIMap.cpp:436-437` and
**hides** them below zoom 3, as do the squad spots. Zoomed out, the medic badge isn't smaller than the
house — it's *gone*, along with every squad dot, leaving the house at full size.

**And it is still not ours to fix.** `scale="1" scale_min="1" scale_max="1.2"` was written, tested and
**reverted**. A real mechanism is not a mandate: that is a behaviour change to a marker rather than an
art swap, it would make this pack's fast-travel point behave unlike every other pack's, and the
symptom it addressed was a symptom of the 20-unit size. This file's rule — *sizes are left alone, this
is an art swap, not a layout change* — is what the whole of R2.56 is about, and the fix cannot itself
break it. The 12×12 square rect is not an exception to that rule but a consequence of the swap: our
atlas cell is square with the glyph letterboxed, so drawing it into AlphaLion's 11×15 with `stretch`
on would stretch the house vertically by 1.36. 12 is the square equivalent of their actual 11×12 of ink.

Two facts kept for whoever revisits this. `scale="1"` with a missing or non-positive bound is
`R_ASSERT2` at `map_spot.cpp:50` — an engine fatal at map load, uncatchable from Lua. And the whole
mechanism is **fullscreen-map only**: `m_bScale` and `m_scale_bounds` are read in exactly one place,
`CUILevelMap::Draw`, and `CUIMiniMap` never consults them — so every `_mini` element's `scale_min`,
vanilla's included, has never done anything.

### R2.55c — A task's own new-task pulse counted as coverage · **2026-08-17**

Reported as *"the custom waypoint marker over empty space doesn't show the cross — it shows
briefly then disappears; moving a waypoint does show the cross"*. Three theories were wrong
before the game was simply asked, and the answer was a spot type none of them had considered.

**Caught with a `gamma_watch` on the live session**, sampling the waypoint's spot list, its
kind and its map location every 400 ms while the waypoint was removed and re-placed:

```
id=58624 kind=nil      loc=secondary_task_location  spots=[secondary_task_location]
"no-waypoint"                                                    <- removed
id=62464 kind=waypoint loc=secondary_task_location  spots=[secondary_task_location ui_secondary_task_blink]
id=62464 kind=waypoint loc=iqm_task_waypoint        spots=[iqm_task_waypoint ui_secondary_task_blink]
```

**`ui_secondary_task_blink` is the engine's new-task pulse** — the "you just picked this up"
highlight, which is a **separate map location on the task's own target**, not a child of the
task spot. `target_covered` counted it, so a fresh task looked covered and wore the hollow
reticle. The brief cross is the ~750 ms between the task existing and `iqm_taskspot`'s first
sync; moving a waypoint re-opens that same window, which is why moving "showed the cross".

**Nothing about this was specific to waypoints.** The same self-trigger reached every task the
coverage test could answer for — since R2.52 that is all of them — so *every* newly taken task
briefly wore a hollow reticle. And because the pulse expires after ~15 s the mark healed
itself, which is precisely what made it read as intermittent and unreproducible. The live
sample above shows both halves: the older waypoint, whose pulse had long expired, sits at
`kind=nil` with the cross.

The fix is a `NOT_COVER` set replacing the single hard-coded `paw_task_default` test, holding
that name plus **both** blink variants — the storyline one matters too, or every fresh
storyline task keeps the bug. Both names were already known to this mod:
`modxml_n_iqm_map_icons` retextures `ui_storyline_task_blink_spot` and
`ui_secondary_task_blink_spot` to `iqm_mapspot_blink`. The fact needed to see the bug was
written down two files away.

**The rule for adding a fourth**, since the list is otherwise three arbitrary names: the
question is not *"did another mod draw this"* but *"is this mark here **because of** this
task"*. A mark that would still be on that object with the task cancelled is real coverage.

Harness: taskspot 188 → 192, with the captured live sample encoded verbatim as a fixture
(`[secondary_task_location, ui_secondary_task_blink]` on bare ground), the same case for an
ordinary task rather than a waypoint, and — the one that keeps the fix honest — the same pulse
laid **over a real stash**, which must still read as covered.

### R2.55b — Every mutant hunt turned red, and why ordering was not a fix · **2026-08-17**

R2.55's defend-task entry shipped broken and was reported within the hour: *"mutant quests are
showing as bounty"*. It was not a near miss, it hit **37 of the 88 assault sections in this
pack** — the whole mutant-hunt family. Two mistakes, and the second is the one worth keeping.

**The functor is not a kind.** `tasks_assault` runs the mutant hunts *and* the faction fights;
it picks its own news icon by asking `is_squad_monster` (`tasks_assault.script:174`). "Destroy
the Mutants" and "Defend Rostok" declare the **same** `status_functor`. So mapping that functor
to `bounty` was not weak evidence for "human" — it was no evidence at all.

**Ordering does not substitute for evidence, and this is the general lesson.** The entry was
put in a `LATE_STATUS_KIND` table consulted *after* the mutant tests, with a comment arguing
that this made it safe. The argument was true within a single call and irrelevant across
calls. Everything above the mutant tests answers from **permanent** state — a saved registry,
a config key. The mutant tests do not: `squad_comm` needs the squad alife-resolvable and
`load_var` needs the task to have stored it, and both legitimately answer nil before that
squad spawns. So on the first tick the mutant tests had nothing, the late table said "bounty",
and `kind_seen` **latched it forever**. It could never self-correct once the squad appeared.

> A positive-only cache must never be fed an answer derived from the **absence** of evidence.
> Ordering protects against a test that would answer *differently*; it does nothing about a
> test whose evidence has not *arrived* yet.

The `open` kind already knew this — its comment says "NOT STICKY… this one is a property of
the GROUND" — and the same rule reaches anything sitting downstream of a runtime-state test.

**The replacement is config, and it is exact.** `status_functor_params` is the declared
community list and it decides the species outright: with `P[6]` true the enemy set *is* that
list; with `P[6]` false the enemies are drawn from `tasks_assault`'s `factions_list`, which
holds the nine human factions and no monster communities (`:37-47`, `:395-416`). Squad
acceptance is exact string equality on `squad.player_id` (`:115`, `:138`), so nothing
downstream can widen the set.

Verified end-to-end against the running game's own merged config, not just the census:
**88 assault sections, 37 mutant, 51 human, zero mixed, zero missing the key.**

So the late table is deleted and the rule sits with the other declarations, where it is a
permanent fact and safe to cache like them. **This is now better than what it broke**: a
mutant assault used to be found only by the runtime squad tests, so it wore the wrong pin
until its squad spawned; it is answered from the section the moment the task exists. The
tokens are *behaviour* classes (`monster_predatory_night`), never species, so this says
mutant-or-not and never which mutant — which is all the map needs.

Two corrections to the R2.55 entries below:

- **The one-off defends moved up** into `STATUS_KIND` / `TARGET_KIND` with the other
  permanent declarations — `gd_task`, `hold_the_ground`, `no_step_back`, `barrier_defense`.
  Each is a single hand-written quest with its own functor and nothing to over-reach onto.
- **`faction_base_defense` lost its entry entirely, and R2.55 had it wrong.** It was
  hardcoded to `mutant` because the section is "Defend the Base Against Mutants" — but
  `task_functor.faction_base_defense_target` probes flesh/boar/dog story squads on most maps
  and **zombied** squads in the Yantar variant, and the section carries no community field.
  Hardcoding either answer is wrong half the time. Left out, its target resolves to the real
  enemy squad and the runtime tests answer correctly for both.

Harness: taskspot 185 → 188. The check that would have caught this is a mutant assault whose
**target tells the runtime tests nothing** — same functor, monster community list, unresolvable
target. R2.55 answered "bounty" there and latched it. There is also now an assertion that no
late declared-functor table exists at all, because reintroducing one is the specific mistake
this file exists to prevent.

### R2.55 — A dead click, a fifth colour retired, and the fast-travel house · **2026-08-17**

Six changes, of which two are real bugs and one is a deletion.

#### The stash tasks were not "unclickable" — they had no way to answer

Reported as *"capture encrypted documents doesn't seem to be clickable / show the active
marker"*. The click was landing the whole time.

`static_border` **is** the active-task indicator. `CMapLocation::UpdateSpot` compares the
location against `GameTaskManager().ActiveTask()` and calls `show_static_border` on the result
(`map_location.cpp:371-391`) — and `show_static_border` is a **silent no-op when the element
was never declared** (`map_spot.cpp:140-146`). `iqm_task_open` was the one IQM type without
one. So the spot took the click (`CMapSpot::OnMouseAction`, `map_spot.cpp:97-118`), the task
*did* become active (`UIMapWnd.cpp:1161-1181`), and nothing on screen changed. The engine's
other cue is no help: `level_map_spot_border` is declared `<texture a="0">` by Sota UI, fully
transparent.

**R2.49e's reasoning was sound and over-applied.** It dropped the border deliberately, because
PAW draws `paw_task_default` on the same object and two concentric pulsing rings is one too
many. True for PAW; false for a stash task, which supplies no animation of its own and so has
nothing to compete with. R2.52 then generalised the *type* from waypoints to "anything landing
on a drawn mark" and carried the borderless trade along with it, to cases the trade was never
argued for.

Fixed by splitting the type: `iqm_task_open` **with** the ring, `iqm_task_waypoint` **without**.
`iqm_taskspot`'s `SPOT` already had separate `waypoint` and `open` keys — kept apart for an
unrelated beacon-glyph reason — so the fix cost one string. The taskspot harness had a check
asserting the two were the *same* type; that check was pinning the defect in place and is now
the opposite assertion, plus one that the two differ in `static_border` and nothing else.

#### Rescues fold into the bounty, and the `hostage` kind is deleted

Raised as *"search and rescue can use same color and icon as bounty (you will have to fight
anyway)"*, which is the whole argument.

R2.51 gave rescues the bounty's reticle in azure `64,164,214` on the reasoning that a contract
and a rescue are the same sentence about the objective and differ only in the verb. **The verb
is the part the player does not act on**: getting the hostage back means killing whoever is
holding them, so the preparation, the approach and the fight are identical. A second colour
asked the player to distinguish two marks that call for exactly the same thing — a distinction
that was true and useless.

`STATUS_KIND.hostage_task` now answers `"bounty"` and the kind is gone: the location type, its
two spots, `iqm_pointer_hostage`, and `BEACON_RGB.hostage`. **What it costs, stated plainly:**
the map no longer says "someone is alive at this pin".

The colour harness lost its warm/cool opposition check with it. That check asserted the two
tints were a hue *opposition* (one `r > b`, the other `b > r`) rather than two shades — the
right test for two kinds sharing one atlas cell, and a `dE` floor is not a substitute for it.
Recorded in place rather than deleted silently, since the next kind that shares a cell needs it.

#### Defend tasks read as bounties, and the classifier grew a *late* table

Raised as *"'Defend Rostok' and similar should be marked same as bounty"*. A census of 892
sections across 43 task files found **no shared functor** — the group splits between
`assault_task_status_functor` and four one-offs. (`validate_assault_task`'s `P[6]` looked like
the flag and is not: it means "the listed factions are the enemy", `true` for Defend Rostok and
`false` for Defend Military Base, so it halves the group.)

**The interesting part is where the entry had to go.** `assault_task_status_functor` is
declared by *mutant* assaults as well as human ones — `tasks_assault` runs both families and
splits them with `is_squad_monster` (`tasks_assault.script:174`). Put in `STATUS_KIND`, it
would answer `"bounty"` **before** the mutant tests run and strip every mutant assault of its
skull: a declaration overruling a state test, the exact inversion the classifier's header
argues against. So it went into `LATE_STATUS_KIND` / `LATE_TARGET_KIND`, consulted after the
two community reads and the class test and before the coverage test. The "can only add a kind,
never claim one" property is bought by **ordering** here rather than asserted — and the harness
checks the ordering by source position, not just the names.

One entry answers `"mutant"`: `faction_base_defense_target` is *"Defend the Base Against
Mutants"*, where the enemy is named in the section but the target is the base, so no state test
can see it. Attack tasks come along with the assault entry, intentionally — the functor does
not distinguish defending Rostok from storming a camp, and both are "go here and fight people".

#### Fast travel gets IQM's house

Traced first: the spot is `fast_travel_spot`, declared by **Sota UI** as a 25×25
`ui_hud_icon_sleep` and then **overridden at runtime** by *AlphaLion's Reworked Stash Quest and
Map Markers* (`modxml_AL_MapSpots.script:454-464`) to an 11×15 `ui_AlphaLion_Location` — an
opaque teal house on a dark box. Spots are created by *Fair Fast Travel 2.7+*
(`game_fast_travel.script:1537`).

IQM has had a `home` cell built and declared since the badge work, **and deliberately did not
apply it.** That revert's argument was that vanilla's art is `ALPHA 128` — a half-transparent
ghost taking its colour from the PDA screen — and no opaque tint can reproduce it. **The
argument was about a spot this pack does not draw.** AlphaLion's override wins the load order,
and it is already opaque, so the thing actually being replaced is an opaque tinted glyph. The
revert rested on a fact about a file that loses.

Applied, at `80,229,202` **sampled from AlphaLion's `.dds`** rather than chosen, so the mark
changes shape without changing the colour the player reads as "fast travel". Glyph swapped to
Tabler `home-2-filled` with its window subpath removed — a solid silhouette. Nothing else in
the atlas is a house, so the outline alone is unambiguous, and every pixel the window spent was
ink taken off a 20-unit mark. It also makes the no-circle rule trivial where it used to need an
argument: there is no interior feature left to distort under the handheld PDA's 0.75 squash.
20×20 square rather than AlphaLion's 11×15, per the size derivation already in the file — their
art sized the *box*, ours sizes the house.

The legend row came with it. It had been held out for four releases *because* the spot was not
patched ("claiming it would be a lie"); it is claimed now for the one reason that licenses any
row there.

#### The delivery card said REPORT BACK, and delivery is now a role

Reported as *"deliver the package is still using the completed icon not the mail icon"*.
Two separate things were behind it, and the first is not a bug.

**The map spot needs a restart, not a fix.** `status_functor == "delivery_task"` selects
`simulation_task_47/48/49` exactly, `t.spot` is `secondary_task_location` throughout
(`task_objects.script:95-110` — `spot` is chosen in code from `storyline`, never a config
key), and `cur == base` matches, so nothing was blocking the swap. R2.54 was authored the
same day and `map_spots.xml` is only re-parsed on a real resolution change — so
`iqm_task_spots_declared` latches **false** the moment a new type is added without a fresh
parse, and `sync` correctly leaves every task alone. *(The `*_on_guider` theory was wrong and
is worth recording as wrong: those two types are only ever added as separate object spots on
a **guide NPC** when the target is on another level, never onto a task's own location.
Accepting them in the `OURS` predicate would have been dead code.)*

**The second thing is real.** `collect_desired` gave the deliver-to NPC the role `target`
— at every stage, ungated. `target` means *report back*: `HDR_KEYS.target` is `REPORT BACK`
and `BEACON_ICON.target` is `iqm_role_handin`, the hand-in diamond. So while the package was
still in your pack, the card and the marker both said the job was finished, and after R2.54
the map said envelope. Two views, two sentences, and the card's was the wrong one.

`delivery` is its own role now: `DELIVER TO`, and the envelope. That cost the **role atlas its
fifth row** — it was exactly full at 16 cells, and `iqm_role_skull`'s own note predicted this
("adding another glyph here now means adding a ROW"). Appended, never inserted, so every
existing `iqm_role_*` id keeps its origin.

**Adding a role touches five tables in three files and not one of them errors on a missing
entry.** `header_for` falls back to `st_iqm_hdr_target`, `icon_for` returns nil,
`CHIRP_ROLES` reads false, and `route_target` matches on the literal `"target"` — which
would have silently dropped every deliver-to NPC out of the ground route. A role can be
half-added and look like it works. The slot harness gained a section that enumerates
`ROLE_PRIO` and asserts each role is wired through all of them, so the next one cannot be.

#### The generic task crosshair

`TASK_TICK_R1` 0.196 → **0.28**. The clear radius inside the ring is 0.4115, so the old arms
filled 48% of it — the one mark in the atlas with no glyph had the least ink in it. 0.28 fills
68% and leaves ~3.4 px of gap at a 26 px icon. 0.32 was tried and rejected: the ring's gaps are
on the cardinals, which is exactly where the arms point, so at 0.32 they poke *through* and the
mark reads as a plus sign bursting out of a circle rather than a crosshair inside one.

Harnesses: colour 119 → 113 (the hostage checks retired), taskspot 180 → 185, legend 68 → 72,
slot 23 → 40. The **map** atlas is still 24 of 24 cells — fast travel reused the existing
`home` cell, so no row was needed there — while the **role** atlas went 4×4 → 4×5 for the
delivery envelope.

### R2.54 — Deliveries get an envelope · **2026-08-17**

`svg/mail.svg` (Tabler `mail-filled`) in the task reticle, in the hand-in green `40,172,66`,
as a fifth task kind. (It shipped violet `150,68,238` for one revision — see below.)

**Why it needed one.** `tasks_delivery` hands you a package and a person to take it to. Its
stage 1 target is that person (`tasks_delivery.script:188`) and its `stage_complete` is **2**,
so the pin sits on a *named NPC* while the job is outstanding — structurally the same mark as
a bounty and a hostage. Without a glyph the three were one reticle in three colours.

**The classifier line is the strongest entry `STATUS_KIND` has**, and worth recording as the
standard the other names should be held to. `tasks_delivery` builds its own registry by
walking `task_manager.task_ini` for exactly `status_functor == "delivery_task"`
(`:19-26`), and `is_delivery_task` answers out of that list. So this is not a name list
standing in for a state test — it *is* the state test, without the linear scan and without a
soft dependency on the module having loaded.

**It takes the hand-in green, `40,172,66`** — the one on both `on_guider` spots, on ATUE's
return spot, and mirrored by `BEACON_RGB.target`.

It shipped violet for one revision first, and that was the wrong instinct, cleanly. The
violet was arrived at by grid-searching for maximum distance from the other reticles, which
optimises for the mark being **distinct** when what it needed was to be **recognised**.
Walking a package to a named NPC is the same act as walking a finished job back to its giver,
and the map already has a colour that means exactly that; a fifth colour would have made the
player learn a new word for something they already knew.

**So this is the one place the palette's usual rule is inverted, on purpose.** Everywhere else
colour *separates* within a shape family. Here it *unifies* — green means "hand this to
somebody" and the glyph says which errand, envelope against hand-in diamond. Rendered side by
side in the same green at 20 / 26 / 35 units the two are unmistakable, which is the whole bet.
The colour harness gained the inverse of its usual assertion to protect it: an **identity**
check that delivery equals the hand-in green, because a drift there breaks a rhyme rather
than a rule and nothing else would notice.

**Stage 0 wears it too**, deliberately. There the target is the package, which
`tasks_delivery` creates in the actor's own inventory (`:217`), so the mark is on the player —
where vanilla already draws its own task pin. This only changes which glyph, and *you are
carrying the package* is a true thing for it to say.

**The atlas grid is now exactly full: 24 of 24.** The next mark added needs a fifth row
(`ROWS 6 → 7`, +128 px of texture) and must never widen `COLS`, for the reason in the growth
rule — widening renumbers every existing cell's origin while the texture ids stay valid, so
the game silently draws the wrong art. The build-time check added in R2.53 caught the missing
declaration for this cell on its first run, which is the second time in two changes.

Colour harness 108 → 119 checks, taskspot 169 → 180.

### R2.53 — The arrow at the edge of the map · **2026-08-17**

The soft yellow blob that appears when the active objective is off screen. It was traced in
R2.51 and left alone; this replaces it.

**What it is.** A location whose marker is off the map's edge does not vanish — the engine
draws that location's `pointer` there instead, rotated to face it (`CMapLocation::Update` →
`UpdateSpotPointer`, `map_location.cpp:427`). Vanilla's is an 11×24 sprite. GAMMA's winning
`map_spots.xml` is **Sota UI EGUI Style HUD**'s, which redefines all four pointer elements to
`ui\enhancedGUI\QuestArrow` — **68×43 px of inked art inside a 512×512 texture**, 98.9% of it
empty, drawn into a 172-unit rect. It is the softest mark on the map, and it is the one the
player looks at exactly when they cannot see their objective at all.

**Repointed, not redefined.** Those four names are shared — the level changers, the treasure
spots, the fourteen faction circles and the combat pointer all reference them. Redefining
`quest_pointer` would decide what every other mod's off-screen cue looks like on the strength
of this one caring about task markers. So `iqm_map_spots.xml` declares pointers of our own,
and the DXML moves exactly `storyline_task_location`, `primary_task_location` and
`secondary_task_location` onto them. The four IQM task-kind types set theirs in the spliced
XML directly.

**One cell, five elements, one per colour** — gold, bone, lime, red, azure, each mirroring the
pin it belongs to, so the arrow at the edge is already the colour of the mark it points at.
The art is white with a black keyline like every other cell, so the tint is the whole
difference; the same trick the 14 warfare spots use on one disk.

**Two geometry facts that had to be right.** The element is **square** (26×26) even though the
arrow is 11:24, because `heading="1"` makes the engine *rotate* the quad and rotating a
non-square rect shears its contents — the same reason the eight level_changer spots are forced
to 21×21. And `stretch="1"` is **required and not the default**: `CMapSpot::Load` only forces
`SetStretchTexture(true)` when a spot has no heading (`map_spot.cpp:37-41`), so a heading
element that omits it draws at the texture's pixel size and a 128 px cell would render 128
units across.

**The probe matters more here than anywhere else.** A missing pointer node is the same engine
assert as a missing spot type (`map_location.cpp:160-166`), but the blast radius is different:
an IQM task type only reaches locations this mod flagged, while a pointer named on
`storyline_task_location` reaches *every* story task the player holds. So the repoint is
guarded on the element being in the DOM, and a deployed XML older than the scripts leaves
Sota's arrow in place instead of taking the game down.

**And a guard for the thing that made this risky to add.** `build.py` now verifies every cell
against `iqm_textures.xml` after writing: right id, right origin, nothing declared that is no
longer drawn. The grid rule at the top of that file — *append, never widen* — existed because
a cell inserted mid-grid slides every origin after it while the ids stay valid, so the game
silently draws the wrong art and nothing errors. That was enforced by reading; it is now one
regex over a file we already ship. Atlas 22 → 23 of 24 cells.

Colour harness 91 → 108 checks.

### R2.52 — The hollow reticle was never really about waypoints · **2026-08-17**

Raised as "the encrypted-documents and search-the-stash tasks should use the variant without
the middle arrow, so the stash shows". Both are `nta_stash_task_target_functor` — the intel
documents, the Monolith plans, and the pilot's PDA, whose objective text is *Search the
stash*. But chasing them turned up the larger version of the same fault.

**R2.49e built exactly the right mechanism and scoped it to one mod.** The open reticle
existed because Personal Adjustable Waypoint puts its own pin and the task spot on the same
object and the solid crosshair buries the pin. That was never a fact about waypoints. The DRX
quest-item family points *straight at a stash the player has already found*
(`tasks_stash.script:159`, **21 sections**) and buries the stash icon in exactly the same way,
and so does anything else a mod aims at a marked object. So the coverage test moves out of the
PAW branch and becomes the **last** question `task_kind` asks, of every task.

Last is the whole safety argument. Every kind above it is about the *job* and outranks it, so
a bounty standing on a service badge is still a bounty; only a task that nothing else could
name gets dressed by its surroundings. That is also why it needs no list of "interesting"
targets — a wrong answer there can cost at most the middle of a reticle that had nothing else
to say.

**The type is renamed `iqm_task_waypoint` → `iqm_task_open`.** Leaving a type named for the
first thing that needed it, while it serves stash tasks, is the kind of drift this codebase
is otherwise careful about. `waypoint` survives as a *kind* key alongside `open`, both mapping
to the one type: they are one mark and two vocabulary words, kept apart only so `iqm_beacon`
can keep giving the player's own pin its own glyph (`BEACON_ICON.waypoint` is a real glyph;
`open` has no entry and falls through to the ordinary task one, which is right for a stash
task and would be wrong if it borrowed the waypoint's).

**The nta_stash family still needs naming, and the reason is worth recording.** It spawns the
quest item *inside* a rolled stash and points the task at the **item**
(`tasks_nta_stash.script:96`), while `treasure_manager`'s mark sits on the **stash**. Two
object ids, one screen position — so `level.map_get_object_spots_by_id` returns nothing on the
target however plainly the pin is sitting on a stash icon. The engine exposes no positional
query, so that one goes in `TARGET_KIND` under the same rule as the other two names: consulted
only after every derivable test has said no, so it can add a kind and never claim one.

**Two caching bugs fixed on the way.** The coverage answer must not latch in `kind_seen` —
everything cached there is a property of the job and cannot change, and this is a property of
the ground. And the negative throttle used to `return nil` between rechecks, which was only
safe while every kind latched; with a re-derived kind in play that would have flipped the
reticle solid every five seconds. It now hands back the last coverage answer, and re-tests
immediately when the target moves.

Colour harness 90 → 91 checks, taskspot harness 144 → 169.

### R2.51 — Three task families that were never being recognised · **2026-08-17**

A census of the merged task config — 44 LTX files, 889 sections, 563 carrying a
`target_functor` — against what `task_kind` actually answers. Three gaps, each failing for
its own reason, plus a colour pass.

**A target that is one creature rather than a squad.** `squad_comm` reads `player_id`, and
`player_id` is a field on a *squad*. `tasks_recover_mutant_data.script:121` returns
`M[task_id].mutant_id` — a single monster's object id — so the community test found nothing
and the pin stayed a plain reticle. The same shape recurs across the Sakharov research hunt,
the chimera scan and the COFG/iTheon hunt tasks. Fixed with `target_is_monster`, which asks
the engine's own class table (`IsMonster`, `_g.script:2845`) rather than matching a section
name, so it covers whatever creature any mod spawns. It answers only for the stage that
points at the creature: that hunt's later stage points at the *device* dropped on the corpse,
which is an item, and the pin correctly goes back to the ordinary reticle.

**A kind no runtime registry records.** Hostage rescues (`status_functor = hostage_task`,
`tasks_faction_control.script:34`, eight sections in the pack) and the Top 10 hit list
(`tasks_top_10.script`, which keeps its own saved list of marks and never calls
`setup_bounty_task`, so `bounties_by_id` has no row for it) have no state to read. These are
answered from what the section **declares**, via `task_manager.task_ini` — the same source
`stage_complete` already comes from, and the same question `tasks_assault.script:156` asks of
it to pick its own news copy.

Those two *are* name lists, which this file has rejected before and still rejects as a
primary test. What makes them admissible is **where they sit**: after the bounty registry and
before nothing, so they can only *add* a kind, never claim one. A modded task with an
unlisted functor comes out exactly as classified as it was before the table existed. The
rejected functor blocklist had to default to "not a bounty" and so failed open on the very
tasks it existed to catch; this fails to the status quo. The harness asserts the ordering by
source position, because the comment is what would survive a reorder.

**One thing I had wrong in the survey and corrected here:** `mutants_in_map_target` (clear
the level) looked like a miss and is not. `tasks_clear_map.script:78` filters
`SIMBOARD.squads` on `is_squad_monster[sob.player_id]` and returns a **squad** id, so the
existing test already caught it.

**Colour.** The bounty red moves from `214,44,60` to `172,60,66`. The original was picked to
sit close to the engine's enemy-relation dot on the reasoning that a bounty is a hostile
human; what that missed is that the enemy dot is an *alert* — unbidden, wanting to interrupt
— while this pin is a job you accepted and went looking for. Both of the things that make a
colour shout are pulled back rather than just lightness: L\* 47.5 → 41.8, and chroma 72.9 →
50.9, a 30% drop. It does not go darker than that: `question_location` at L\* 43.1 is the
darkest tint the atlas ships, and every mark here is drawn over a black keyline, so below
that a tint stops separating from its own outline at 26 px.

**Hostage** gets `64,164,214` and **reuses the bounty's atlas cell** — same bust, same
reticle, tint only. Not a saving; two cells from one SVG are two things that can drift, and
it is the trick the 14 warfare squad spots already use. Colour carries the whole difference
here, which is the failure the bounty redraw exists to remember, so the claim asserted is a
hue *opposition* rather than a distance: warm-dominant against cool-dominant, dE 55, the
conventional split of "kill this one" against "bring this one back". It collides with the
fast-travel bed (dE 11) and the mechanic badge (dE 13) and that is fine — neither is a
reticle, and the atlas's grammar is that shape separates categories while colour separates
within one. Against marks of its own shape the nearest is the secondary task's bone at dE 29,
over the dE 28 floor.

**A hole found by adding the fourth type.** `iqm_task_hostage` is a fourth save-poisoning
type name, closed the same way as the other three — `revert_for_save` puts every flagged task
back before the engine writes. But adding it exposed a flaw in the *other* guard. The DXML
callback verifies that the types are really in the parsed DOM before letting `iqm_taskspot`
hand any of them to `change_map_location`, and it did that by probing one representative
name, `iqm_task_bounty`. The case that guard exists for is a deployed `iqm_map_spots.xml`
that is a version behind — which is exactly a file that **has** the older types and not the
new one. It would have passed the probe and then handed the engine a name that file does not
carry, which is the one failure here that takes the game down. Now every type is probed, and
the list comes from `iqm_taskspot.spot_types` rather than being restated in the modxml, so
the thing that just went stale cannot go stale again.

Colour harness 81 → 90 checks, taskspot harness 108 → 144.

### R2.50 — The previews were lying about how these look · **2026-08-17**

Raised as "the old stash icons look smoother than ours, perhaps anti-aliasing". They do, and
the cause is not anti-aliasing in the art — it is the sampler, and it is a problem this tool
had been hiding from itself.

**A cell is 128 px and a 19-unit spot is ~27 px at 1080p**, so the GPU is minifying 4.7:1 —
and on the 8-to-14-unit spots, up to 9:1. With no mipmaps a sampler does 4-tap bilinear, which
reads four texels out of the ~22 that should contribute and discards the rest. On art with a
hard black keyline that is not a small error: the keyline breaks into a dotted, stair-stepped
fringe. Vanilla's stash mark is 27 coarse pixels in a 14-unit spot — roughly 1:1 — so it never
asks the sampler to do the thing it cannot do. Being *lower* resolution is exactly why it
looks smoother.

**Every preview this tool has ever drawn resized with PIL's LANCZOS**, a proper area filter,
so all of them — including every comparison sheet in this changelog — showed what the art
*could* look like rather than what the engine draws. Simulating true 4-tap sampling makes the
difference obvious immediately.

Two knobs, each revertible on its own line; set both to their off values and the output is
byte-identical to R2.49f.

**`MIPMAPS = True`** — the real fix. A mip chain hands the sampler a pre-filtered level near
the on-screen size. The usual objection to mipmapping an atlas is bleeding between cells, and
it was checked rather than assumed: the cells are 128 px, a power of two, on a grid whose
origins are multiples of 128, and a box filter at level *k* averages aligned 2^*k* blocks —
128 is divisible by 2^*k* down to one texel per cell, so **no block ever straddles a cell
edge**. That guarantee is a property of the box filter specifically, which is why the DDS is
now written directly instead of by `magick`; the writer's no-mip output was diffed against
magick's and is identical apart from magick's own stamp in the reserved field. 1.5 MB → 2.0 MB.

This departs from the pack, where every UI atlas is 1-mip. They can afford that: their cells
are close to their display size. Ours are deliberately not — a 128 px cell is what makes a spot
sharp at 4K, and this is the other half of that bargain.

**`PREFILTER = 1.0`** — insurance, in case the engine's UI path ignores mips entirely, which
cannot be verified outside the game. A gaussian applied to each finished cell *before* packing;
per-cell and pre-pack matters, because blurring the assembled atlas would pull neighbours into
each other, reintroducing by hand the bleeding `MIPMAPS` avoids by construction. At 1.0 it
costs ~0.4 px of edge softness at 4K, under the keyline's own antialiasing.

If the marks still read harsh in play, that means mips are not being sampled: raise `PREFILTER`
to ~1.6. If they read soft, drop it to 0.0 and keep the mip chain.

Not applied to `tools/role-icons` — those glyphs are drawn at card size, where minification is
mild and the same argument does not bite.

### R2.49f — ...but only when there is something under it · **2026-08-17**

R2.49e made every placed waypoint wear the hollow reticle. That is right on a service NPC or
a stash and wrong on bare ground, where the hole has nothing to show through it and the mark
is just a reticle with its middle missing. The `waypoint` kind is now **conditional on the
target already carrying another map mark**.

The test is asked of the engine rather than guessed: `level.map_get_object_spots_by_id`
(`level_script.cpp:485`, bound at `:2544`) returns *every* map location on an object as
`{spot_type=, text=}`. That is the difference between a rule that covers whatever any mod
happens to draw and one that covers the types we thought of.

Three exclusions, each of which would otherwise make the answer always yes:

- **the task's own spot**, which `change_map_location` has just put on the object;
- **`paw_task_default`**, PAW's animated highlight, added on the same line as the task and so
  present on every waypoint including the ones on bare dirt;
- **anything of ours**, so that once `iqm_taskspot` has moved the task onto
  `iqm_task_waypoint` the test does not start reading its own output back and latch on.

**It is not cached the way the other two kinds are**, and that distinction is the substance of
the change. `mutant` and `bounty` are properties of the *job* and never change, so they are
cached sticky against the task id. This one is a property of the *ground*, and the player moves
the waypoint (`func_wp_mov`) without the task id ever changing — so it is keyed on the target
and re-tested on the slow timer, which also picks up an icon pinned under an existing waypoint.

One case it cannot see: a waypoint dropped on the target of another *side* task, whose reticle
is the same spot type as this task's own and collapses onto one map location under
`SLocationKey`. That is the cheapest miss available — the mark underneath is an identical
reticle, so hollow and solid look near enough the same there.

Harness: taskspot 103 → 108, covering bare ground, a service NPC, the self-latch case, and the
absence of a sticky cache.

### R2.49e — A hole in the reticle, for the player's own pin · **2026-08-17**

Personal Adjustable Waypoint's waypoint *is* an Anomaly task (`task_placeable_waypoint`,
`storyline = false`), so its spot is `secondary_task` like every other side job — and PAW
puts **both** marks on the same object: `change_map_location` for the task, then
`map_add_object_spot` for its own pin (`tasks_placeable_waypoints.script:1547-1548`). The
player chooses that pin from a library of 85, and the task reticle lands squarely on top of
it. R2.49b made this a real problem rather than an overlap: the crosshair went to 2.0/23 and
its centre hole closed, so it stopped covering *part* of the pin and started covering it.

`iqm_mapspot_taskopen` is the same reticle with nothing inside it, and `iqm_task_waypoint` is
the location type that wears it. `iqm_scan.task_kind` returns a third kind, `waypoint`, and
`iqm_taskspot` moves the task onto it — the same machinery R2.48 built for mutant hunts and
bounties, used for a different reason: this kind is not about what the task *is*, it is about
what is already drawn underneath it.

Details worth having written down:

- **No `static_border`.** The other task types get the pulsing selection ring; this one already
  has PAW's own animated highlight on the same object (`paw_task_default`, 39 units, which the
  DXML re-textures to `iqm_mapspot_blink`). Two concentric animated rings around one pin is one
  too many.
- **The tint is the side-task bone**, not a colour of its own — this is the ordinary side-task
  marker minus its middle, and that is exactly what it should look like.
- **`BEACON_ICON.waypoint` is now both a role key and a kind key.** It was written as a role;
  a kind lookup now lands on it and draws the waypoint glyph, which is right by luck rather
  than design. Recorded in place, because renaming either vocabulary would break the agreement
  silently.
- **`BEACON_RGB.waypoint` stays absent**, and its *reason* changed without the assertion
  needing to: the player's own mark keeps the accent, and mirroring the new spot's bone would
  tell the player their pin is a side job.

**The colour harness had a hole and reported 81 where it had been reporting 72.** `MIRROR` and
`KIND_PAIRS` are both hand-written, so `iqm_task_waypoint` landed in neither and was checked by
nothing — the file still said "72 passed" with a brand-new spot type entirely unexamined. There
is now a check that every `iqm_task_*` type in the parsed XML appears in one of the two tables.

### R2.49d — The stash rebuild is reverted · **2026-08-17**

Backed out in full after testing: the ten `treasure_*` entries in `SPOTS`, the `stash` cell,
`svg/stash.svg`, and the `iqm_mapspot_stash` declaration. The `treasure_*` spots draw
vanilla's art again, and the legend's "stashes are not ours to explain" gap note is restored
with it.

The one thing worth carrying forward is the measurement R2.49 recorded, because it is the
reason any future attempt has to start somewhere else: **those spots are 8–12 UI units**,
smaller than anything else in the atlas and smaller than the squad marks, which needed a
dedicated per-view cell pair for exactly that reason. At the 11 px an 8-unit minimap spot
gets at 1080p, a ringed triforce is a blob no matter how it is drawn. Rebuilding this mark
means either bumping the spots' `width`/`height` through `el`, or splitting it stash/stashmini
the way `squad` is split — not simply pointing the existing badge machinery at it.

**The two task-kind cells moved up one slot**, `taskmutant` to (384,512) and `taskbounty` to
(0,640), and the grid is 21 cells over 6 rows. Removing a cell from the middle renumbers every
one after it, which is what the "append only" rule in `build.py` exists to prevent — it is safe
here only because `iqm_textures.xml` was edited in the same change and the origins are checked
against `SRCS` programmatically rather than by eye.

### R2.49c — The task family, finished · **2026-08-17**

Four changes from play-testing, all inside the task marks.

**Hand-in moved into the task family.** It was a ring badge with a diamond in it, which put
it visually among the services; it is a task marker — the pin that appears on the giver once
an objective is done — so it now wears the reticle frame like the mutant hunt and the bounty.
Only the frame changed; the glyph is the same. A reticle cell carries no centre crosshair, so
the diamond sits in a clear frame rather than on a cross.

New: `RETICLE_FIT_SCALE`, and the diamond is why it exists. `RETICLE_FIT` sizes a bounding
box, and how much of a box a glyph fills is a property of its shape — a rotated square puts
its points at the box's edge *midpoints*, not its corners, so it cleared the frame by 13.1 px
where the skull clears it by 7.4 and looked small for no reason but geometry. 1.12 brings it
to ~8 px.

**The centre cross is wider**, 1.2/23 → **2.0/23**, matching the outer ring at 3.04 px. With
the inner ring gone the crosshair carries the whole "aim here" half of the mark alone, and
vanilla's hairline was not enough for that. 2.4 was tried and closes the centre into a blob
at 26 px.

**The crosshair's centre hole is closed**, `TASK_TICK_R0` 0.043 → **0**. Vanilla leaves a gap
there, and at its 1.2/23 stroke it is a seam nobody sees. At 2.0/23 the same gap is a square
notch punched out of the middle of the mark — it is a radius, and four wider arms meet it from
four sides, so widening the arms widens the hole.

**The animated selection ring is thicker**, `SEL_W` back to **1.45/21** — the value it was
originally tuned to.

Worth recording that R2.49a's reason for keeping it thin was **wrong**, because the mistake is
easy to repeat. The argument was that 1.45/21 lands at 3.69 px against the reticle's 3.04, so
the frame would outweigh the thing it frames. That was reasoned from the two stroke widths
alone — and every preview behind it drew both marks *at the same size*. They are not the same
size: the border is 29 units against the icon's 19. Composited at the real ratio the frame
reads as the outer element at any of these widths, because being 1.5× larger is what makes it
outer. The "four fat blobs" failure it was afraid of was measured at 2.2/21, i.e. 5.6 px.

Final weights at a 35 px icon: selection ring 3.69, reticle and centre cross 3.04, badge ring
2.76.

### R2.49a — The thin ring was right for services and wrong for quests · **2026-08-17**

R2.49 thinned every ring with one decision, on the reasoning that one stroke weight should
run through the whole atlas. In play that split: the service badges were better thin, and
the quest reticle was not. `TASK_OUT_W` goes back to **2.0/23**, which restores the reticle
and both task-kind marks; `RING_W` stays at 1.5/19.

The reason the two want different answers is what they are for. A service badge is scenery
you consult — it should sit in the terrain politely. A quest marker is the one mark the
player is actively navigating *to*, and at 26 px it has to win against whatever is under it.

**`SEL_W` did NOT go back with it**, and that is measured rather than assumed. The selection
frame is drawn at 29 units against the icon's 19, so a fraction of a cell buys ~1.5× more
screen there than on the badge. At a 35 px icon:

| | on-screen |
|---|---|
| task reticle, outer ring | 3.04 px |
| service badge ring | 2.76 px |
| selection frame | 2.67 px |

Reverting the frame to 1.45/21 puts it at **3.69 px — heavier than the reticle it frames**,
which is the exact failure the original 2.2/21 attempt produced (four fat blobs on the
cardinals rather than a frame). A frame has to be lighter than its contents for one to
obviously contain the other. The centre ticks are unchanged at 1.83 px; they were never
thinned, so there was nothing to restore.

**The two task-kind glyphs shrank slightly and nothing had to be edited to make that happen.**
A thicker ring eats its own interior, and `RETICLE_FIT` is a fraction of `TASK_OUT_R` minus
`TASK_OUT_W`, not a pixel count — so the clear radius went 54.2 → 52.7, the glyph box 76 → 74,
and the clearance held at ~7.5 px. Writing that as a derived value rather than a constant is
what made this a one-line change.

### R2.49 — Thinner rings, and a mark that says which kind of task · **2026-08-17**

Five changes to the map atlas, all of them things the icons page was built to let you see
before committing to.

**The rings are thinner.** `RING_W` 2.1/19 → 1.5/19, `TASK_OUT_W` 2.0/23 → 1.45/23,
`SEL_W` 1.45/21 → 1.05/21, and the squad disks' keylines 6/9 → 4/6 with the disks growing
to match, so their footprint is unchanged and only the border weight moves. `RING_W` is one
constant for the whole badge system, so `question` and `alert` moved with the services even
though they sit in other sections — there is no per-cell ring width, and adding one would
give the atlas two badge weights, which is the opposite of what the ring is for.
`ui_pda2_stask_last_01a`, the 15 s new-task pulse, was excluded by request and is the one
ring in the task section left alone.

**The task reticle lost its inner circle.** `TASK_INNER = False`. The centre crosshair
stays; it was the complete inner ring between the two that went.

**A task's KIND is now a glyph, not just a colour.** Two new cells, `taskmutant` and
`taskbounty`: the reticle used as a frame — inner ring and crosshair both dropped — with a
skull or a bust in the space they leave. Both halves are needed. The bare skull that shipped
in R2.48 said "mutant" and dropped the fact that it was a task at all; the red reticle said
"task" and left hue to carry everything else, so a bounty and an ordinary task were the same
shape at 26 px. They are built by the same `draw_task` the plain reticle uses, so the frames
cannot drift apart on screen.

The two do not pay the same price. The bust is already drawn at ~70 px inside the badge ring
for the VIP, so 76 px inside the reticle is more room than the glyph is proven at. The skull
gives up 31% of its linear size and just over half its area against the bare cell, and at
26 px its sockets start to close — the failure that made that cell bare in the first place.
`iqm_mapspot_skull` is still built and still declared: backing it out is one texture id per
element in `iqm_map_spots.xml`.

**The trader and the barman left the caution band.** Measured rather than argued: CIEDE2000
put the trader at **dE 4.1 from the storyline task gold** and 8.6 from the alert amber, against
a palette floor of about 25 — not *similar to* the task marker, the same colour with a rounding
error. Four marks sat between hue 25 and 50. Sweeping HSV against the other twelve left exactly
two free bands, so trader → teal (0,198,176), barman → magenta (222,60,158); nearest existing
neighbours dE 20.0 and 21.5, and **dE 59.6 from each other**, which is the number that decided
the assignment since the two sit side by side in most hubs. 20–23 is the honest ceiling, not a
compromise — with twelve marks placed, nothing in the gamut scores better without going too
dark to read at 26 px. Mirrored into `BEACON_RGB` and the PDA legend table.

**The stash mark was rebuilt.** Anomaly already draws a triforce in a ring for the ten
`treasure_*` spots — one 27×27 cell in four baked colours, with PAW's five
`paw_vanilla_stash_icon_*` ids aliasing the same art — so this reproduces the glyph rather than
choosing one, and keeps the ring. One white cell replaces all four, because the state is an
r/g/b attribute; the four values are sampled from the vanilla art. That means they break the dE
floor on purpose (the player gold is ~4 from the task gold), and it stands because the shape
carries this mark completely: nothing else on the map is a triangle, let alone three.

**Worth knowing before testing it:** those spots are **8–12 UI units**, smaller than anything
else in the atlas and smaller than the squad marks, which needed a dedicated per-view cell pair
for exactly that reason. At the 11 px an 8-unit minimap spot gets at 1080p the triforce is a
blob — no worse than vanilla's, and clearly better from 24 px up, but not *good*. Two levers if
it reads badly in play: bump the spots' `width`/`height` through `el` in the SPOTS table, or
split it into stash/stashmini the way `squad` is split.

### R2.48a — Three reasons nothing happened, and one promise kept · **2026-08-17**

R2.48 shipped compiling, harness-green and completely inert. Two screenshots settled it in
a minute where the tests could not, which is the whole lesson: every check written for it
tested the model or the source text, and none of them could see that the module was never
reaching the config it gated on.

**`iqm_core.C` is nil.** `C` is a file LOCAL in that module (`:649`); the accessor is
`iqm_core.config()`, which is what every other module uses. So `on` was false for every
player, forever, with no error and no log line. Now asserted by name in both directions —
the accessor present, and no assignment from `iqm_core.C` — because the wrong version is
silent and would have shipped again.

**A second liveness test.** R2.48 invented `t.status == "selected"`. `iqm_scan` already had
`is_task_active`, written as a NEGATIVE test — not completed, not failed, not reversed, and
the actor still holds the task — which is the shape it is because that is how the field
behaves. Two tests for one question is one of them being wrong. It is published now and
there is one.

**The target is not the squad.** "Destroy the Mutant Lair" is an assault task, and
`assault_task_target_functor` returns `var.smart_id` — the smart terrain, not the squad
(`tasks_assault.script:240`). A smart has no `player_id`, so the community test found
nothing and every lair task in the game stayed on the plain reticle. The squad is in the
task's own stored var under its task id, so the fallback reads that. The cache had to go
asymmetric to match: positives sticky, negatives re-tested, because `squad_id` is nil for
the first frame and again every three seconds while the status functor rescans.

**And the save hazard is now closed rather than documented.** Asked directly whether
unticking and restarting would make removal safe — it does, and without the restart: the
revert is live, so untick, save, remove. But that only cleans saves made afterwards, so
`revert_for_save` now puts every flagged task back inside the engine's own pre-save
callback. `CALifeStorageManager_before_save` is called at `alife_storage_manager.cpp:75`
and `registry().save(stream)` runs on line 89 — fourteen lines later, same frame — so **no
save ever contains one of these type names** and the mod is removable at any moment. The
feature also refuses to run without marshal, since that is what fires the callback, and the
`declared` flag now VERIFIES the types are in the DOM instead of assuming the splice put
them there — the two come apart on a stale deployed XML, which is precisely the state a
half-updated install is in.

### R2.48 — Every task pin looked the same · **2026-08-17**

Six pins on the PDA map, one mark between them, so choosing which to walk to meant opening
each. A mutant hunt now carries a skull and a bounty a red reticle, while the objective is
still outstanding.

**Classified from state the game keeps for itself, not from functor names.** Bounties come
out of `axr_task_manager.bounties_by_id` (`axr_task_manager.script:14`), the registry
`xr_effects.setup_bounty_task` writes and the save carries; mutants out of the target
squad's community against `is_squad_monster` (`_g.script:2362`), which is the same test
`tasks_assault.script:174` uses to pick its own news icon. A `target_functor` allowlist was
rejected for R2.47's reason, in the same direction: GAMMA mods ship their own functors, so
an unknown name defaults to "not a bounty" and the list fails silently on the modded tasks
it exists to catch. Reading the TARGET rather than the task is also what makes it survive a
task script this mod has never heard of.

**The gate is R2.47's, reused rather than reinvented.** `iqm_scan.task_kind` returns nil
once `target_is_talk_to` is true, so the skull and the red come off the moment the job is
done and owed to somebody — which is also when the marker moves onto the person you report
to. One rule, in one place; the revert then needs no separate code path.

**New location types, because a map spot has no runtime tint.** Colour is an `r`/`g`/`b`
attribute read once at parse, shared by every task of that type, so "this pin is red" can
only be said by pointing the task at a different type. Only the mutant needed art — a
bounty is the reticle it already had. `CGameTask::ChangeMapLocation` is remove-then-recreate
and re-entrant (`GameTask.cpp:126-135`) and all three accessors are bound to Lua, so
`iqm_taskspot` is a poller, not a monkey-patch of `task_objects.script`.

**And these types go into saves, which is the real cost.** The type string is serialised
(`map_manager.cpp:62`) and rebuilt through a constructor that `R_ASSERT`s on a type
`map_spots.xml` does not declare (`map_location.cpp:105`) — an engine fatal no `pcall`
catches, so **a save taken with a bounty flagged red will not load with this mod removed**.
PAW carries the identical hazard for ~100 types of its own, so it is the pack's normal, but
it is why the names are gated on the DXML splice having actually run and why switching the
feature off REVERTS rather than merely stops. `tools/taskspot-harness` asserts both, plus
that the pass is silent once settled.

**The two halves do not overlap, and that reads like a bug until you see why.** With
`beacon_handin` at its default the kind is always nil by the time a world marker exists at
all, because `task_kind` and that gate are opposite halves of one stage test. So these
glyphs are a PDA-map feature at default settings and a marker feature only with the hand-in
gate off — which is exactly the configuration where knowing whether the objective is a
mutant or a man is worth something.

**`map_icons` came along with it**, since the kind spots needed a switch to ride. It turns
the mod's map art off wholesale, and it needs a game restart for a reason with no way
around it: `g_uiSpotXml` is parsed once and freed at DLL detach (`map_location.cpp:92-99`,
`xrgame_dll_detach.cpp:132`). Not even loading a save re-reads it.

### R2.47 — The marker was handing over the part that was the task · **2026-08-17**

Raised the moment R2.46 landed: *a beacon on a bounty task is pretty OP.* Correct, and it
was a regression rather than a new problem — the old `target` role had always run its
candidates through `target_is_talk_to`, and moving the marker onto the selection dropped
that gate without anyone noticing, because the failure looks like a feature.

**The bounty functor draws the line for us** (`tasks_bounty.script:228`): at stage 1 it
returns `task_giver_id`, at stage 0 the mark out of `axr_task_manager.bounties_by_id`, and
those sections declare `stage_complete = 1`. So `stage >= stage_complete` separates "walk
back to the barman" from "hunt a live stalker who is moving", using a key the game already
ships and the functors are already written around. Base Anomaly's 207 fetch and 79 assault
tasks have the same shape.

**Not a task-type blocklist**, which was the obvious alternative and is worse: 42 vanilla
sections name `general_bounty_task` outright, but GAMMA's mods add their own functors, so
an unknown name would have to default to *allow* — failing open on exactly the new OP cases
the list exists to catch.

**One gate, not two.** A "never mark a hostile" runtime test would also catch kill-steps
with no `stage_complete`, and is written up in `docs/decisions.md#beacon_handin` for if one
ever slips through. Held back because it suppresses briefed enemy positions too, and
because two interacting gates are harder to predict than one.

**The default is the load-bearing part.** `C.beacon_handin ~= false`, not a truth test: an
upgrading player has no stored value, and `nil` must read as *gated*. The other way round
hands every existing user the OP behaviour silently. The harness asserts the `~= false`
by name for that reason.

**The route stays ungated,** and that is a split rather than an oversight:
`active_task_target` now RETURNS the stage answer instead of applying it, because
`route_target` shares the call. A path along the ground is navigation; an exact position
through a wall is a reveal. During a bounty you get a line toward the area and nothing on
the body.

**Worth stating plainly**, since it was the first question asked: the waypoint-only case
needed no code at all. `mark_beacon` and `beacon_waypoint` were already independent
switches. What this adds is the middle position — task markers on, but only once you are
carrying a finished job back.

### R2.46 — The marker never knew which task you had picked · **2026-08-16**

Reported as *selecting the active task marker does not seem to update the beacon*, and it was
exactly true: **nothing in the marker path had ever asked which task was selected.**

The route had. `route_target()` walks the task manager asking `db.actor:is_active_task(t.t)`
— the engine's own notion of the bracketed marker (`map_location.cpp:376`) — and follows it.
The marker was driven entirely by `tracked`, the scan's role table, and marked *every*
in-progress hand-in NPC, up to six of them, ordered by distance. Two targeting systems, one
of them selection-aware, and the gap had been invisible because the selected task's turn-in
is usually among the nearest anyway.

**Two functions one letter apart mean opposite things**, which is most of why this survived:
`db.actor:is_active_task(task)` is *selected*; `is_task_active(task)` in `iqm_scan` is merely
*in progress* — not complete/failed/reversed, stage ≠ 255, still in the actor's list. The
scan loops the second and calls each result a `target`.

**A priority tweak could not have fixed it.** The selected task's target frequently never
reaches `tracked` at all, for three independent reasons, and no ordering rescues a candidate
that was never offered:

* `is_markable_npc` needs `level.object_by_id` to resolve, so an **offline** target is out —
  and a task marker sits wherever the objective is, not wherever you are;
* it demands a stalker or trader, and `iqm_nav`'s own note already said a task marker is
  routinely **a crate or a smart terrain**;
* `target_is_talk_to` drops any task below its `stage_complete`, so a selected **go-find-it**
  task is deliberately not a `target` in the first place.

So the marker is offered independently of `tracked`, the way the placed waypoint already was:
`task_goal()` / `offer_task()` twin `waypoint_goal()` / `offer_waypoint()` line for line, and
`goal_pos` answers all three cases plus "nil on another level" for free. The `target` role's
own marker is retired (`br.target = nil`) — one objective mark, and it is the one with the
bracket round it.

**Selection only, no fallback**, and the consequence is chosen rather than overlooked: the
route still falls back to the nearest tracked turn-in when nothing is selected, so with no
selection the ground line leads somewhere that now carries no marker. The alternative was
sourcing the marker from `route_goal()`, which would have kept the two agreeing by
construction at the cost of the marker sometimes pointing where the map's bracket is not.
The bracket won.

**The merge is the common case, not a corner.** Placing a waypoint *selects its own task*, so
`tid == wid` is the default state right after placing one. One mark is drawn and it is the
task's reticle; it inherits the waypoint's `WP_NEAR` suppression along with the identity,
because standing on your own waypoint the ground under your feet still says more than a badge
over your head.

**The art is a fifteenth role cell,** `iqm_role_task`, and it parts company with the map cell
it mirrors in one measured way. `iqm_mapspot_task` is a broken outer ring, an inner ring and a
centre crosshair. A marker draws at `beacon_size` — 14 UI units, ~20 px at 1080p — against a
map spot's 19, and at 20 px all three plus their keylines merge into a blob: the gap between
the outer arcs and the inner ring is 4.9 units of 100 and the baked keyline grows 7.1 into it
from each side. The map cell blurs the same way there — its inner ring and crosshair already
read as one filled centre — so the role copy drops the ring and grows the cross, reproducing
what the map *renders* at marker size rather than what it *contains*. Four variants were built
and looked at at 20 px before picking; the full-fidelity trace was the worst of them.

**A dead band moved rather than closing, and the harness caught it.** Retiring the target
role's marker broke the one-mark-per-body test in `tools/waypoint-harness`: `beacon_roles`
stopped answering for a quest giver, so a waypoint dropped on one would have drawn straight
over its card. The first fix was `or d < appear_d` — and *in card range* is not *has a card*.
An NPC off-screen or behind cover is tracked, in range and drawing nothing, so the proxy
blanked `work` and `important` at close range: the R2.38 bug in a new place. The test reads
`f.card_up`, the hysteresis-damped flag the loop already keeps, one frame late and safe
because it only turns true once the card is half opaque.

**And the trader glyph went back to Tabler.** Reported as *too many fine details*, which is
the *inner glyphs must be flat and simple* rule in `tools/map-icons/README.md` catching up
with a mark that predates it: the game-icons.net briefcase's latch, handle wrap and case
seams all sit below the resolution these are drawn at — half a badge cell for the map spot,
~20 px bare for the marker. The filled `briefcase-2` is one silhouette and holds down to
14 px. It also settles a licence the map-icons README had already argued against
(game-icons.net is mostly CC BY 3.0 with per-icon attribution; Tabler is MIT and bundled).
Shared source, so both atlases were rebuilt; old art kept as `svg/trader-gameicons.alt`.

**A note here was too broad and is corrected.** `role-icons/README.md` recorded that
librsvg refuses any SVG containing an XML comment. It refuses one placed *inside the opening
`<svg …>` tag*, which is malformed XML; a comment after that tag closes is fine, which is
how `task.svg` carries a long one. Both positions were probed rather than assumed.

**`beacon_dist` changed what it governs**, so it moved. It now sits under the guide and
service rows and rides them, because the objective marker it used to gate has no range gate
at all — hanging it off `mark_beacon` would have hidden the slider that still controls
guides and traders and shown one that controls nothing when they are off.

### R2.44 — Four prototypes retired, and what each one is owed · **2026-08-16**

A pass over the F7 actions found 46 of them, of which 24 answered questions this log records
as closed. Four whole files existed only to carry those actions, and are deleted here:
`iqm_decal`, `iqm_strip`, `iqm_dart`, `iqm_mmprobe` — with their harnesses, texture builders,
ui xml and the decals ltx.

The files were kept this long because each holds a **measured negative result**, and a
negative result that is deleted gets re-derived by the next person with the same good idea.
So the measurements move here first. None of the four had any inbound code reference; the
only mentions in shipping scripts were comments.

**`iqm_decal` — why the route is paint and not a wallmark.** A decal is made out of the
ground rather than approximating it, so it needs none of the projection machinery, gets
occlusion free against the real depth buffer, and cannot slide as you walk. It was rejected
for one reason that no amount of setup can reach: **a decal cannot cross a static-mesh
seam.** `CWallmarksEngine::RecurseTri` walks triangle *adjacency* from the triangle the ray
hit, and two static meshes do not share vertices, so the mark is cut by a clean straight line
at every slab edge. Confirmed against stock blood wallmarks, which are cut identically — it
is the engine, in C++, with no Lua reach. Blood survives it because a straight cut through an
irregular blob reads as where the stain ends; a chevron has an expected silhouette, so the
same cut reads as broken. **Decals are for organic shapes, not geometric ones.** Three
further costs, all real and none of them the reason: no removal (marks expire on their ttl,
so `hide` means "stop re-stamping"), no per-metre tint (`static_wm_render` writes one fixed
vertex colour, so colour is a second texture and a second ltx section), and static geometry
only. Plus the trap: **a missing wallmark section is an `R_ASSERT2`**, an engine fatal that
`pcall` does not catch — only `section_exist` ahead of the call avoids it.

**`iqm_strip` — uniform slicing fights diagonal artwork.** The shipped renderer draws a mark
as one heading-rotated rect: three degrees of freedom against the four the true
ground-to-screen map needs, the missing one being shear. Slicing the mark into strips that
run *along* travel supplies it — parallel world lines converge on screen, and that fan is the
shear. The geometry was right and the harness proved it. **The picture was worse.** A
chevron's arms run nearly parallel to the cut, so every strip slices an arm lengthwise and
rebuilds it as a stack of offset bars: band content spans ~48% of a strip's length while
consecutive bands shift by 15%, so the ends read as steps along both edges of every arm. 32
bands were still visibly stepped, at a widget each. Also worth keeping: cutting the *other*
way, across travel, does exactly nothing — projection maps straight lines to straight lines,
so all strips come out at the same heading. It measured 0.001° of fan at 45°. Both cuts look
equally plausible on paper.

What the measurement *does* support is decomposing by **shape** rather than by slice: a
chevron is two bars, a bar is the one figure a rotated rect represents well, and two bars
with independent headings carry the shear at two widgets rather than eight. That is the arms
style, dropped over the apex light spot at R2.19 — an alpha-overlap problem at the join, not
a geometry one. `iqm_arms.script` is therefore **kept**, since it is the subject of this
recommendation.

**`iqm_dart` — the chevron's cue is an angle, and projection does not preserve angles.** The
sharpest single measurement of the four. Swept over 3–25 m and 0–90° off axis, a chevron's
projected apex spans 11° to 175° — a ×16 swing — and reads as a plain bar at *both* ends:
near 180° the arms are collinear, near 0° they fold onto each other. This is not tunable.
Compress the along-travel axis by k and the apex obeys `tan(t') = hw / (2·hl·k)`, so every
chevron tends to a 180° apex as k → 0, whatever it starts at; looking across the path drives
it to 0 instead. Sharpening the glyph moves *where* on the range it looks good and cannot
remove the swing, **because the swing belongs to the cue, not to the artwork.** A dart's cue
is a taper — back edge over front edge, two *parallel* segments, and affine maps preserve the
length ratio of parallel segments. Same sweep: 3.28 to 4.87 against a world 3.60, a ×1.49
swing, residual pure keystone. The cue survives where the chevron's does not.

The dart lost the menu vote at R2.43 on how it looked, not on this. The measurement stands
and is the strongest argument on file against the shape the mod ships — if the chevron is
ever revisited, start here.

**`iqm_mmprobe` — already condemned in writing.** `docs/minimap-route.md` §7 has said "obsolete
and still shipped — should be deleted" for some time: F3a/b/d answered, F3c answered twice,
F3e superseded, and the shipping `iqm_minimap` carries its own state readout. It also
reproduced the R2.28 orphaned-dialog bug (`AddDialogToRender` into a file `local`, no
teardown), as did `iqm_strip` — so two of the four were leaking a HUD dialog per save load on
the way out.

**One consequence for R2.43.** That entry lists `iqm_strip`'s carved bands as one of three
things pinning the atlas layout to cell 0 (`chev50`). With the file gone, that reason gone
too — a relayout now costs only the `.dds` rebuild and the 24 rects in `iqm_textures.xml`.
Still not done here, and still not urgent; the retired cells cost transparent pixels.

### R2.43 — Eight shapes was a menu of one decision · **2026-08-16**

`route_shape` came out of R2.31 as a genuine trade — the shapes that point best sit worst —
and R2.32 put all five ends of it on the menu rather than picking one here. R2.40 and R2.42
added two more chevrons and R2.32 had already added the dart, which made eight. On the floor
the trade turned out to be one-sided: a mark that carries no heading is not a flatter mark, it
is decoration, and nobody was choosing the rung or the tile for its alignment. Five come off —
`chev50`, `chev30`, `rung`, `square`, `dart` — leaving the arrowhead and the two chevrons, and
the new default is `chevtight`, relabelled **Chevron - large** against shape 8's **small**.

**The numbers did not move, and that is the whole migration.** `route_shape` is an MCM list
value, so the number in a player's ltx is the only record of what they chose, and nothing in
it says which version of the list wrote it. Renumber the survivors 1-3 and a stored `3` means
`chevsharp` where it used to mean `arrow` — an unmigratable silent change, because both
readings are in range. So `RTE.SHAPES` becomes a table with **holes** in it, keyed `[3]`,
`[7]`, `[8]`, and the five retired numbers simply fail to resolve. `read_config` therefore
tests `RTE.SHAPES[n]` rather than `n <= #RTE.SHAPES`: a bounds test is exactly what would wave
a stored `5` through into a nil index. Nothing may use `ipairs` or `#` on that table again.

**The atlas keeps all eight cells, deliberately.** `MARK_SHAPES` in `tools/stroke-tex/build.py`
is the atlas's *layout* as well as its content — cell `k*MARK_VARIANTS + v` — so deleting five
rows slides every surviving cell onto different pixels, which invalidates the committed
`iqm_marks.dds`, all 24 rects in `iqm_textures.xml`, and `iqm_strip`'s bands, which are carved
out of cell 0 by pixel coordinate. Fifteen unreferenced cells cost transparent pixels; a
relayout costs a texture rebuild and a re-derived set of strip bands. So `build.py` still draws
eight, and `check_shapes_match_mod` became a **subset check by slug** — every shape the mod
offers must match the picture drawn for it, and the extras are ignored. **No texture rebuild is
needed for this change**, which was the point of doing it this way.

### R2.42 — Both ends of the belt-speed dial have now been complained about · **2026-08-16**

**The conveyor speed is one dial with a complaint at each end**, and after R2.40 both have
been made:

| | constant | varies | reported as |
|---|---|---|---|
| coupled 1:1 (pre-R2.40) | the gap to each mark | speed over the ground | "it speeds up when I move" |
| decoupled (R2.40) | speed over the ground | the gap to each mark | "you can catch up to them" |

No setting is both — constant ground speed and constant relative speed differ by exactly the
player's own, so pinning one varies the other. What breaks the deadlock is that **the two
complaints do not occupy the same speed range**: walking, the belt already outruns you, and
only a sprint is fast enough to run the marks down. So the belt holds its constant speed
until that is about to happen and is then floored at `player speed − CATCH_M`:

```
standing    belt = flow                 unchanged
walking     belt = flow                 unchanged (2 m/s walk against flow 2)
sprinting   belt = your speed − 1 m/s   you gain 1 m/s and no more
```

Nothing changes in the range that already looked right, and the coupling appears only where
the alternative was walking through the marks. At 1 m/s a mark 10 m out takes ten seconds to
reach — longer than any sprint in the Zone — so in practice they are not caught, they are
gained on slowly, which is what something moving away from you should look like.

The speed is the derivative of the **arclength the marks are already scheduled in**, not the
actor's velocity vector, so strafing and looking around contribute nothing and it costs no
engine call. The phase became an **integral** rather than `clock × speed`, since the speed is
no longer constant and recomputing the product would jump the whole run whenever it changed.

**The old "walks 3 m" fixture was a 6 m/s sprint** — 3 m in half a second. It passed anyway
while the belt was flat, because a flat belt does not care how fast you go, so the
mislabelling stayed invisible until the fast end got its own behaviour and the "walking" case
started reporting the sprint rule. The speed in a speed fixture has to be the speed it says.

**Three pictures of every shape** (`MARK_VARIANTS`). Every mark used to be the same bitmap,
so a run repeated one scuff and one camo blotch at even spacing — which is what a repeated
texture always looks like once a dozen are on screen, and the conveyor put a dozen on screen.
Only the noise differs: same geometry, same box, same keyline, because `place_mark` measures
**one box per shape** and a variant with its own outline would need its own.

Picked by **hashing** a stable id, not cycling it — three variants dealt in order read as
ABCABC, which is a pattern where the point was to break one. The id names the *mark*, not the
slot: while flowing that is the lattice index (a mark keeps its number as slots renumber
around it), and when still the slot *is* the identity. Each regime's id is the thing that
does not move in that regime. The texture is re-pointed only when it changes — about once a
second per slot while flowing, never when still.

Costs 8 MB against 2: 8 shapes × 3 variants is 24 cells, which needs a 2048×1024 atlas. Two
variants would fit 1024×1024 and is the fallback. **21 hand-written rectangles is too many to
keep right by reading**, and the failure is silent — a wrong x/y draws a neighbouring cell,
which is still a plausible mark — so `build.py` now generates the regions, refuses to build
on a mismatch, and prints the block to paste. `chev50` variant A stays at (0,0) deliberately:
`iqm_strip` carves its bands out of that cell by pixel coordinate.

**Shape 8, `chevsharp`** — apex 68°, against shape 7's 94° and `chev50`'s 112°. The **width**
closed it, not the depth: a 68° apex at shape 7's width would need `alen` 0.62, deeper than
anything else in the family. That still cost more than guarding the depth suggested — depth
over width came out **0.89**, against 0.68 and 0.56, because the ratio is depth over *width*
and only the numerator was being watched. It is second only to the square for keystone
residual, and at 0.62 m across it reads as a tick rather than a mark at distance. Both are
the price of the angle, and both are why it is the eighth entry on a menu.

### R2.41 — A comparison that was legal on tables and fatal on vectors · **2026-08-16**

**The crash.** `begin_search` asked `aim ~= to` to decide whether the goal had been snapped
onto the navmesh. `vector` is luabind userdata with **no `__eq`**, so comparing two of them
is not `false` — it is `No such operator [__eq] defined in class [vector]`, a script runtime
error and a CTD. `iqm_nav` has carried a note about exactly this since R2.11, in
`build_draw_list`, and this is the same mistake in the same file.

It survived several sessions of play because **Lua 5.1 answers `==` on two userdata by
primitive identity first** and only consults `__eq` when they are different objects.
`mesh_goal` returns `tpos` *itself* in the ordinary case, so `aim` and `to` are one object,
the metamethod is never reached, and the line is harmless on every route to a target
standing on the floor. The one path returning a *different* vector is the goal being off the
navmesh — so the line crashed the game precisely in the case it exists to report. Now
compared by distance, which is the honest question anyway.

**The harnesses could not express the failure, which is how it shipped.** Every stub built
`vector` as a plain table, where `==` is legal and answers by identity, so the faulty line
ran thousands of times per run and reported nothing. All eleven stubs now define an `__eq`
that raises, reproducing the engine exactly — including the identity short-circuit, which
means a fixture only proves anything if it drives the branch where the two are *different*
objects. The off-navmesh section does, and now says so under its own name; without the
`pcall` around it the failure aborts the run at that line, which reads as a broken harness
rather than a broken mod. No other instance turned up across the whole mod.

**`route_dist` now goes down to 1 m** (from 20), in steps of 1 (from 5) — the step has to
follow the floor or the slider lands on 1, 6, 11 and never a round number again. Twenty
metres is not a short route, it is a medium one, and there was no setting for "a nudge at my
feet". Nothing clamps it up; what needed pinning is that the *publisher* floors `draw_m` at
`SEG_MAX` (5 m) — a stroke needs both ends of a segment, and a list stopping at 1 m could be
a single vertex, which draws nothing while still reporting a live route. `route_limit` is
what honours the setting, and every view goes through it. My first version of that test
asserted against the publish and failed against correct behaviour.

**Investigated: smoothing the marks' side-to-side motion.** Two mechanisms, both measured in
`tools/route-harness`'s walled world, and neither is in the marks:

| | measured | when |
|---|---|---|
| `clearance` applies its push per point, all-or-nothing, behind a mesh-permission veto | **0.56 m** of lateral step between two points **1 m apart** | at a ledge or wall end, where the veto fires for some points and not their neighbours |
| a repath replaces `path` wholesale, with no blend | **0.38 m** of lateral disagreement at the same patch of ground, applied to every mark at once, in one frame | every `RETRY_D` (10 m) on a partial, or on any `DRIFT_TOL` stray |

The offsets are smoothed by exactly **one [1,2,1] pass over points 1 m apart** — a ~2 m
ramp — and steps of that size survive it. Nothing smooths mark position in *time* at all.
This matters more since R2.40: the belt now moves the marks over the ground at a constant
speed, so a **spatial** step converts directly into a **temporal** swerve — 0.75 m of
side-slip in about a second at `flow` 2.

**The fix belongs in the path, not in the marks**, and that is the useful half of the
answer. Temporally filtering mark positions fails three ways: marks are *slots*, not
objects, so a filter on slot *k* smears across the lattice wrap and slides a mark backward;
the stroke is not filtered, so the marks would float off the line they sit on during exactly
the motion being smoothed; and it would lag real curvature, which is the same failure as
widening `CHEV_DIR_M` (R2.35 — measured and rejected). Widening the offset smoothing costs
one array pass, is frame-rate independent, has no identity problem, and fixes the stroke and
the marks together. Not implemented — reported only.

### R2.40 — The belt ran at your speed plus its own · **2026-08-16**

Three things asked for together, and the first is the only one with a bug behind it.

**The conveyor was carrying the player's motion.** `flow` is a speed in metres per second
and the marks did not travel at it: they were scheduled at `s_actor + k * gap + phase`
(R2.29, arrangement 3), so each one held a fixed distance ahead of the player and its speed
*over the ground* was `flow` **plus his**. Standing still it ran at 2 m/s; at a sprint,
6 m/s. Reported as the markers speeding up as you move, which is exactly what it was.

R2.29 chose that arrangement for a real reason — a mark at a fixed distance never changes
its size, aspect or angle — and the fix gives that up on purpose. With `flow > 0` the marks
go back on the **absolute lattice** of arrangement 2, `n * gap + phase` in route arclength,
which is nailed to the ground; the only thing that moves them is `phase`, which is a clock.
Arrangement 2's own objection does not apply, because it was an objection to marks that
never move at all: at `flow = 0` nothing changes and arrangement 3 still stands.

The near end stays covered without `NEAR_FILL`: `n0` is the first lattice point at or ahead
of the actor, so the head of the run is always within one gap of his feet rather than at a
fixed multiple of it — and the wrap is seamless because at `phase = gap` the set
`{(n+1) * gap}` is the set `{n * gap}` the next frame starts from.

Measured in `tools/nav-harness` as the **lattice phase** rather than as one mark's
displacement, since marks enter and leave the run and "the same mark" does not survive a
wrap. Standing still: 1.000 m per 500 ms at `flow = 2`. Walking 3 m through the same half
second: 1.000 m. The old code gives 4.000 on the second, which is what the check is for.

**Camo, baked into the ink.** `SetTextureColor` multiplies, so a texture cannot introduce a
second hue — only darker and lighter patches of whatever colour the player picked. That is
what disruptive pattern actually is: real DPM is one garment in several *values*. Three
levels (1.00 / 0.80 / 0.62, scaled toward flat by `MARK_CAMO`), cut out of two octaves of
value noise at 6 and 13 cells — coarse enough to be a fraction of the *glyph* rather than
of the surface, which is what separates camo from the existing wear grain at 22 and 64.

Applied to the **body** end of the ink interpolation, not to the finished ink, so the
keyline stays at `MARK_RIM_INK` and the outline remains the brightest part of the mark.
Multiplying the result instead would have dimmed the rim inside the dark patches and broken
the outline into dashes. The build prints the area each level covers (33/46/21) and refuses
a field where any level is under 8% — a cut in the wrong place gives a flat mark with a
smudge on it, which reads as a rendering fault rather than as a bad constant.

**Back to olive**, 176/196/124, and the two changes are one decision: see the note under
R2.33's amber table.

**Shape 7, `chevtight`.** 0.90 m across against the family's 1.48 and 0.42 deep against
`chev50`'s 0.50, which closes the apex from 112° to 94°; the arm thins to 0.22, because arm
length scales with width and the family weight on a mark this size is a 2:1 blob rather than
a chevron. This needed the first per-shape overrides in `RTE.SHAPES` (`awide`, `aw`,
optional and absent everywhere else) — a chevron's apex is not a parameter of its own, it is
`atan(awide / 2·alen)`, so "the same mark with a tighter point" cannot be said without
moving one of the two numbers the family holds constant.

**The trade goes the wrong way and that is the entry, not a flaw in it.** Depth over width
rises from `chev50`'s 0.56 to 0.68 — a fifth less flat on the floor — and R2.31 measured
that ratio as the whole of the keystone residual. A tighter point *is* more depth per width;
they are the same fact. It is a menu choice, not a replacement for the default, and its row
in the shapes table carries no strafe percentage because that was measured per shape in
R2.31–R2.32 and this one has not been through it. An invented number in a measured table is
worse than a gap.

**The optional fields broke the mirror check silently, in the direction that says nothing is
wrong.** Lua patterns have no optional group, so `tools/marks-harness`'s fixed three-field
pattern skipped the new row entirely: the mod had seven shapes, the harness found six, and
the literal count passed because six was what it expected. Now the row's tail is captured
whole and its fields picked out afterwards. The Python side had the same shape of bug from
the other direction — `%w+` parses `None` and silently drops `0.90`.

### R2.33b — A ramp nothing walks up · **2026-08-15**

Reported off the amber build: *the marker closest to the player seems to have additional
fade.* It did, and by a lot. Measured across every spacing the menu offers:

```
  route_gap 2  ->  first drawn mark at 4.22 m,  61% alpha
  route_gap 3  ->                     3.29 m,   14%      <- the default
  route_gap 4  ->                     4.22 m,   61%
  route_gap 5+ ->  clear
```

At the default the nearest mark drew at **37 of 255** while the one behind it drew at 255.

**The cause is a guard whose premise expired.** `MNEAR` (3.0 m) is the near cut-off: below
it a mark cannot be drawn correctly by one quad, so it is not drawn. `MFADE` (2.0 m) ramped
it back to full, and the note justifying that width said why — *"ramped rather than
switched, because a world-anchored mark crosses this threshold as you walk and a hard edge
there would pop."*

Marks stopped being world-anchored in **R2.29**. Each one now holds a fixed distance ahead
of the player, so it does not cross the threshold: it **parks** wherever its own `k` puts
it and stays there. At 3 m spacing that parking spot is 3.29 m of camera distance, 14% of
the way up a ramp ending at 5.0 — so one mark was dimmed for as long as the route was up.
This is R2.30's `MSQUASH` again in a different constant: *a ramp that nothing ever walks up
is not a ramp, it is a dimmer on one mark.* Both times the constant was correct when
written and was invalidated by a change elsewhere that had no reason to look at it.

**The fix sizes the ramp for what still crosses it.** Marks do still cross the cut-off — a
mark 3 m along the path is nearer than 3 m in a straight line when the path bends, the
route ends, and the spacing changes under MCM — so a ramp survives, but as a transition
guard rather than a standing state: **`MNEAR` 3.0 → 2.4, `MFADE` 2.0 → 0.6**, clearing at
3.0 m, below every gap's first parking spot. Revert = 3.0 / 2.0.

**What the harness now asserts is the property, not the arithmetic.** "The ramp is 0.6 m"
is today's answer; "no spacing the menu offers parks a mark inside the ramp" is the thing
that must stay true, and it is checked across the whole slider — so changing `route_gap`'s
range, `MNEAR`, `MFADE` or `ARROW_LIFT` fails a test rather than a screenshot. Proved by
restoring 3.0 / 2.0: `gap 3 holds its first mark at 14% for ever`.

`HEAD`/`HMIN` was the other suspect and is innocent — it only bites within 1.5 m of the
nearest drawn vertex, i.e. below 2.85 m, which is under the cut-off. The two near fades
never multiply on a mark that is actually drawn.

### R2.33c — The hole is a schedule, not a fade · **2026-08-15**

Reported off the amber build: *under some circumstances and viewing angle it can appear we
are missing a marker near our feet.* Marks sit at whole multiples of the spacing ahead of
the player, so the floor between him and the first one is bare — exactly one gap wide,
permanently — and looking down puts more of it on screen.

**The obvious fix was measured, proposed, rendered and refuted.** The affine residual was
measured against lateral offset rather than distance alone, and the result was genuinely
interesting:

```
 dist   on-axis   0.5 m off   1.5 m off   3.0 m off
  1.5     12%        18%         30%         52%
  2.0      9%        13%         23%         40%
  3.0      6%         9%         16%         28%
  5.0      4%         6%         10%         18%
```

Lateral offset dominates distance — a mark 1.5 m from the eye on-axis fits better than one
5 m away and 1.5 m to the side — and R2.33's lead-in holds the near marks on-axis by
construction. So `MNEAR` gates on the wrong quantity, and lowering it should let a mark
through at the player's feet. **The render was pixel-identical to the baseline.** The
`k = 0` mark sits on the actor's own position, *directly beneath the camera*, and is
outside the frustum at any pitch short of straight down. Lowering the cut-off admits a mark
nobody can see. The measurement was sound; what it never asked was whether the mark it
would admit is on screen.

That is the second time this session a correct measurement produced a wrong conclusion
(R2.33b was the first, and R2.30 before it). The pattern is the same each time: the number
answered the question it was asked, and the question was not the one that decided the
outcome.

**So the fix is scheduling.** `mark_at(k, gap)` gives `0, gap/2, gap, 2*gap, …` — one extra
mark in the hole, which at the default 3 m spacing lands at 1.5 m, about where the visible
floor starts when you look down. Two costs, both taken deliberately:

* **The near end is denser.** Inserting between 0 and `gap` makes the first *two* intervals
  half-length, not one.
* **Half of a wide gap is still wide.** At 6 m spacing the extra mark lands at 3 m with a
  3 m hole in front of it again. This fixes the default and the settings near it, not the
  whole slider — the alternative (fill to a fixed near distance) works at every spacing and
  breaks even spacing at every spacing too. Revert = `NEAR_FILL = false`.

It costs one of `MAX_CHEV`, taken off the far end where the tail fade already has the marks
at a third of their alpha.

**The preview did not reproduce the near cut-off at all.** `tools/route-preview` applied
`FADE`/`TAIL`/`HEAD`/`HMIN` and simply never applied `MNEAR`/`MFADE`, so it drew marks the
game refuses to draw — meaning every near-field answer that tool has ever given was wrong
in exactly the direction that mattered here, and the first version of the comparison sheet
was rendered before I noticed. This is the same class of defect as R2.31's stale
`place_mark`: a preview that has drifted answers confidently and wrongly, which is worse
than no preview. Fixed, then re-rendered.

### R2.33d — The route is not going through the wall. It is giving up at it · **2026-08-15**

Reported with a screenshot: the marks run at a wall instead of through the doorway beside
it. Investigated from the player's log rather than the picture.

**The evidence.** `xray_sjwil.log` carries 107 `route up` lines. **95 of them say
`(partial)`.**

```
[IQM-NAV] route up (partial): 4 nodes -> 22 points -> 20 arrows
[IQM-NAV] route up (partial): 5 nodes -> 48 points -> 26 arrows
```

**The deduction.** `partial` is set in exactly one place in the whole codebase — the
`max_nodes` branch of `search_step`. So 89% of routes are running out of expansion budget.
When that happens the search hands back `rebuild(S, S.best_vid)`: the path to the node with
the **smallest straight-line distance to the goal** that it managed to reach. For a target
behind a wall, that node is pressed **against that wall**. The route then runs at the wall
and stops.

So the drawn line is not passing through geometry — `search_step`'s own comment is right
that a partial "is always a REAL walkable path, never a straight line at the goal". It is
walkable ground all the way. What it is not is a route to the target: it is a route to
*the closest the search got before it stopped looking*, and from the player's side those
are indistinguishable. The doorway was not rejected. It was never reached.

This is **R2.23b, confirmed** — logged when the cover surcharge went in: *"the surcharge
makes `h_weight` relatively weaker, so long routes expand more nodes and are likelier to
come back partial. Watch the F7 status dump for `partial=true` on routes that used to
complete."* Indoors every node is enclosed, so `g` is inflated by up to `1 + cover_w` =
1.8× fairly uniformly while `S.hw` is deliberately left at 1.2 — which makes the search
behave closer to Dijkstra exactly where the budget is tightest. `node_budget` is
`400 + 10·d`, linear in distance, against an explored area that grows with its square.

**What it is not.** Three plausible suspects ruled out:

* **The R2.33 lead-in.** It displaces laterally by at most `LEAD_MAX` = 2 m and decays to
  zero over `LEAD_M` = 8 m, so the far marks — the ones at the wall — carry none of it.
* **`clearance()`.** Capped at `CLR_MAX` = 0.75 m and, unlike the lead-in, every push is
  permissioned against the navmesh before it is taken.
* **The mesh.** Path points are navmesh vertices a metre apart; the marks are interpolated
  along them. Neither can be inside geometry.

**What could not be settled offline, and why.** `tools/route-harness`' fixture is 60 × 40
one-metre cells with a single wall, and the search expands with an 8 m probe falling back
to 2 m. Measured across that fixture, every case completes with room to spare:

```
  straight through the doorway    1-35 expansions   against a 480-840 budget
  with a real detour to reach it  191-313           against 520-800
```

The fixture cannot generate the pressure a real interior does, so this class of defect is
invisible to the harness. That is worth stating plainly rather than reading the numbers as
reassurance.

**The instrument was missing, and that is fixed.** `iqm_route` carries a `verbose` flag
whose only writer was the literal `false` at its declaration — nothing, including the MCM
diagnostic-logging option, ever set it. So `search_step`'s own narration has **never**
reached a log, including the one line that would end this investigation:

```
gave up after %s nodes; partial route of %s points (closest approach %s m)
```

`read_config` now pushes `DEBUG` into it. That push is the last one left in `read_config`:
`iqm_route` owns no config of its own and has no `apply_config` to pull with. With diagnostic
logging on, the next run states how far over budget the search actually ran and how close
it got — which decides between raising `node_budget`, compensating `h_weight` for the
surcharge, and drawing a partial route so that it does not point confidently at a wall.

### R2.33e — The aim is not where the target is · **2026-08-15**

With `iqm_route.verbose` finally reachable (R2.33d), the doorway case logged this:

```
gave up after 694 nodes; partial route of 4 points (closest approach 19.6 m)
              742                        2                          19.6
              790                        7                          19.6
              837                        3                          19.6
              877                        8                          12.2
```

**Two things fall straight out of it, and one wrong conclusion.**

**1. The goal is unreachable, not merely expensive.** Four searches with budgets from 694 to
877 nodes, all with a closest approach of *exactly* 19.6 m. A budget-limited search gets
closer when given more budget; this one does not move at all. That is a geometric barrier —
the mesh does not connect to within 19.6 m of the aim — and no budget change touches it.

**2. The budget is separately marginal.** The previous session's successes needed up to
**836** expansions against budgets of 570–900, with failures at 850/857/877 within a
whisker. `node_budget` is linear in distance while explored area grows with its square, and
it is *tightest at short range* — exactly where an indoor detour needs it most. R2.23b,
with numbers at last.

**3. And the conclusion I drew from the budgets was wrong.** `max_nodes` is
`node_budget(xz(from, aim))`, so a give-up count of 877 means the search was pointed at
something 47.7 m away — while the player's own LOS to the target read 11–16 m and *shrank*
as the budgets grew. I read that as the route aiming at a different marker from the beacon.
It was not: the beacon and the route are the same NPC. So the disagreement is the finding
rather than the explanation — something is resolving a 17 m goal to a point tens of metres
away, and the actor is walking away from it.

The candidate is `mesh_goal`'s cache. Its three computing branches each `say()` what they
did; **the cached early return says nothing**, so a goal snapped once to a bad point goes on
being used silently for as long as the target stays within `SNAP_HOLD_D` (5 m) — which for
an NPC standing at a turn-in is forever. The previous log carried exactly one
`goal off the navmesh: using the target's own level vertex`, which is what that would look
like.

**Instrumented rather than argued**, having already produced one confident wrong answer in
this investigation. `begin_search` now logs the target distance, the aim distance, whether
the aim was snapped and by how far, and the budget granted — it is their *disagreement*
that is the symptom, and neither distance alone shows it. `iqm_route.search_closest()` is
public alongside `search_partial()`, and the F7 dump carries `short_by=N m`: "partial"
never said whether a route ended early by a metre or by twenty, and those are different
answers to the player.

### R2.33f — The budget had the trade backwards · **2026-08-15**

R2.33e's instrumentation answered it on the first run:

```
aiming at the target itself: target 29.4 m away, aim 29.4 m away, budget 694 nodes (id 19097)
aiming at the target itself: target 33.5 m away, aim 33.5 m away, budget 735 nodes
aiming at the target itself: target 38.3 m away, aim 38.3 m away, budget 782 nodes
aiming at the target itself: target 19.6 m away, aim 19.6 m away, budget 596 nodes
    -> gave up after 596 nodes; partial route of 4 points (closest approach 6.0 m)
```

**`aim == target` every time**, so the snap-cache hypothesis is dead and the budget
arithmetic was right all along — the distances really were what they said. The last line is
the whole bug: a **19.6 m target, granted 596 expansions, giving up 6.0 m short of a 3.0 m
arrival.** Three metres from success, out of budget, and the best-effort path it handed back
is what was seen running at a wall instead of through the doorway beside it.

**`node_budget` had the trade backwards.** `400 + 10 * d` gives the *smallest* allowance to
the *nearest* target — and a short route is the one likeliest to need a real search. A
19.6 m target inside a factory has to find a doorway; a 60 m one across open ground is
nearly a straight line. Successful searches in the same logs ran to **836** expansions, so
596 was never going to be enough for anything but open ground.

Now `min(4000, max(1500, 300 + 0.6·d²))`: a floor comfortably above every observed success,
and a quadratic curve, because the region a search explores grows with the square of its
radius and not with the radius. The 4000 cap is unchanged and is what bounds the cost; at
`STEP_BUDGET` 40 expansions a frame the floor is ~0.6 s of resumable search against a
`REPATH_MIN` of 700 ms, so a route still settles before it can be asked for again.
Revert = `min(4000, 400 + floor(d * 10))`.

**Made public so a harness can call it**, and the harness asserts the *property* rather than
the formula: a near target gets at least as much room as the worst search anyone has watched
succeed, more distance never buys less budget, the number stays bounded, and the floor still
settles inside `REPATH_MIN`. That last one is the cost side of the same number and is the
one a future increase will trip first.

**What this does not fix.** Several searches to targets 29–67 m away stopped at a closest
approach pinned at exactly 19.6 m across budgets from 694 to 1072 — flat, where a
budget-limited search gets closer when given more. That is a real barrier and no budget
touches it. Those routes will still draw a confident line to a dead end until a partial is
drawn as one (R2.33j).

### R2.33g — The budget helped, and 6 metres of it were never budget · **2026-08-15**

Same walk, after R2.33f:

```
  target d   budget   closest approach
    33.5       735         19.6      <- old curve
    38.3       782         16.5
    19.6       596          6.0
    31.0      1500          6.0      <- new floor
    18.9      1500          6.0
    20.3      1500          6.0
    16.4      1500          6.0
    18.8      1500          6.0
```

**The budget change did what it was meant to** — the far targets came from 19.6 and 16.5
down to 6.0 — and then hit a floor. Six searches, targets from 16.4 to 31.0 m, 1500
expansions each, closest approach **exactly 6.0 m every time**. `arrive` is 3.0 m, so that
target cannot be reached at all. A number that flat across a 2.5× change in budget is a
barrier, and no further budget touches it.

**So the remaining defect is not the search, it is what we draw when the search is honest
about failing.** A partial that stops a metre short *is* the route: you walk it and you
arrive. A partial that stops six metres short is a confident line running up to a wall,
with nothing on screen to say "this is as far as I know" rather than "go through here" —
which is what was reported twice.

**The tail of such a route now fades out.** Not suppression: the first twenty metres of a
route toward an unreachable target are still the right way to walk, and the beacon still
marks where the target actually is. What goes is the false precision at the end. It is
applied to the occlusion *target* alpha rather than as a separate multiplier, so it eases
in over `OCC_TAU` with everything else and the chevrons inherit it through `RD.ci` for
free — no renderer change at all.

The condition has two halves, and the second is the one easy to get wrong: a **long** route
capped at `draw_m` also stops short of its target, and *its* drawn end is open path rather
than a barrier. Fading that would be a lie in the other direction. So the fade requires
both that the search stopped more than `STUB_TOL` (4 m) short **and** that the drawn line's
end is the path's end.

**And a note on the tests, which caught me out.** The first version of these checks passed
on *occlusion*: the fixture's wall eases the far end to `DIM_MIN` = 0.22, under every
threshold I had written, so "the tail is faded" was true before the feature existed — and
two of the negative cases failed for the same reason. The wall is now pushed out of the way
in these fixtures so the only thing that can dim a tail is the thing being tested. A test
that passes for the wrong reason is worse than no test, and it was two of five here.

**One diagnostic added while there.** The give-up line now reports the height difference
between the best node reached and the goal. A barrier that is purely horizontal is a
doorway the expansion probes never landed in; one with a step in it is stairs, a platform
or a ladder — ground the AI graph does not traverse (R2.2f), which no amount of search
budget or probing will ever cross.

### R2.33h — Two hypotheses refuted, and the target really is unreachable · **2026-08-15**

The height figure R2.33g added came back at **0.37 m** — flat. So the barrier is not stairs,
a platform or a ladder, and R2.2f is off the table. That left one suspect and one piece of
bad reasoning, and both had to go.

**Refuted: the angled doorway.** `expand()` probes eight *fixed world-axis* directions, and
the route harness's doorway fixture is a wall on a grid column — the one orientation those
eight are guaranteed to cross squarely. Real buildings are not axis-aligned. Built an angled
fixture and measured: the search crosses at 90°, 75°, 60°, 45°, 30° and 20°, through
doorways from 1.0 m to 6.0 m wide, in **3 to 31 expansions**. The probe scheme threads gaps
perfectly well.

**Refuted: my own argument.** R2.33g said "a closest approach flat across a 2.5× change in
budget is a barrier". That does not follow. Working *around* an obstacle initially increases
the straight-line distance to the goal, so the best-heuristic node stays pinned for the
entire time a detour is being explored — a long way round produces exactly the same flat
signature as a wall. Flatness never distinguished the two, and it was stated as proof.

**So the budget got the benefit of the doubt, properly this time.** The floor was derived
from crow-flight distance to the target, which is a poor proxy for how hard the search is: a
target 19 m away behind a wall can be a 60 m walk, and the near target that fails is
*precisely* the one hiding a long detour. Floor 1500 → **3000**, and `STEP_BUDGET` 40 → 80
so the wall-clock stays where it was instead of becoming 1.2 s of staring at nothing.

**And the answer came back the same.**

```
   596 nodes -> closest 6.0 m
  1500 nodes -> closest 6.0 m   (six searches)
  3000 nodes -> closest 6.0 m,  0.37 m of height
```

Three budgets spanning 5×, all pinned. At 3000 expansions the search has covered an enormous
area; if a detour existed it would have been found. **That target is unreachable on the AI
graph** — the nearest node the search can reach is 6 m from the goal vertex at the same
height — and nothing in this mod will cross it. The engine's own NPCs cannot path there
either. 1500 → 3000 bought nothing measurable here; it is kept because 596 → 1500 demonstrably
did, and the cost is bounded by the 4000 cap.

**Which makes the dead-end fade the answer, so it had better run.** It did not, for anyone
without `demonized_geometry_ray`: the fade was folded into the line that writes the occlusion
verdict, and that line only runs when a geometry ray is available. A route to an unreachable
target would have gone on drawing itself as a confident line for exactly the install least
able to tell. Moved into the easing loop, which also makes it per-vertex per frame rather
than round-robin, so it appears at once instead of over a sweep's worth of frames. Pinned by a
harness case that runs with `ray_pick` absent — nothing else in that harness does.

**The arrival gates were checked and are not involved**, since they were the obvious
suspects: `ARRIVE_D` (4 m) gates on the *actor's* distance to the target and cannot fire at
20 m, and the search's own `arrive` (3 m) is the radius it is failing to reach rather than
anything cutting it short. The goal is the goal *vertex's* position, so a reachable goal
reports 0.0 — exactly 6.0 means no node ever landed within 6 m of it.

### R2.33i — A band where nothing was drawn at all · **2026-08-15**

Reported alongside the fade confirmation: *lots of examples of no markers showing up at
all*, with a screenshot of a quest NPC in plain sight through a doorway and nothing on him.
The log had the answer without a repro:

```
[IQM-LOS] id=19112 los_check=true ray_ok=true dist=14.7 hit=14.5 -> clear=true
```

Visible, 14.7 m, line of sight confirmed. So the card was not being culled — it was being
drawn at 18%:

```
  alpha_for_dist(14.7) = (16 - 14.7)/(16 - 9) * 255 = 47      card at 18%
  card_up threshold    = target_a >= 24                       card_up = true
                                                              beacon suppressed
```

**The crossover thresholds were about non-zero rather than about legibility.** Card and
beacon are mutually exclusive by design (R2.20's note: blending them left both up across
the whole `full_dist`..`appear_dist` band). But the beacon stood down the moment the card
reached **9% opacity**, and did not return until it was under 2%. Over a 9/16 m fade that
hands over at 15.3 m and leaves roughly 14.0-15.3 m showing a card too faint to read and no
beacon at all — worst against the bright ground the screenshot was taken on.

Now `128` / `96`: the card takes over only once it is at least half opaque, which is the
point it can be read, and the beacon returns below 38%. The gap between the two numbers is
still the hysteresis that stops an NPC parked on the boundary flipping the pair every
frame, which is why they are not the same value. The handover moves from 15.3 m to ~12.5 m,
where the card is genuinely legible.

**Checked as a property, in the harness that reads this file's constants.** The card render
path has no harness of its own, and this is pure arithmetic off `alpha_for_dist` — so it can
be checked without one: walk `full_dist`..`appear_dist` and assert no distance is both
beacon-suppressed and below a legibility floor. Proved by restoring 24/6:
`at 15.3 m the card is 10% and the beacon is suppressed`.

**Also confirmed this session:** the dead-end fade (R2.33g) reads correctly in game. And
the route being absent in that second screenshot is *correct* — `VIS_NEAR` means a target
you can see from under 25 m gets no path, because seeing them tells you how to walk there.
The bug was only ever the missing card and beacon.

### R2.33j — Seeing a head is not knowing the way · **2026-08-15**

Reported: a quest NPC 18 m away through an open doorway, beacon up, **no route** — and
routes to the same NPC drawn correctly from elsewhere. The log has both halves:

```
target 55.7 m away  -> route found: 379 nodes explored, 13 points     (drawn)
id=19112 dist=15.8 hit=30.4 -> clear=true                             (suppressed)
```

`VIS_NEAR` suppresses the route for a target you can see from under 25 m, and its comment
justified that with *"being able to see one across a room means a line to their feet is
clutter."* True across a room. **False through a doorway** — the head is in view while the
walk is round two concrete slabs and in through the door, which is precisely when a route
earns its place.

**So the gate asks a second question now**: not only *can you see them* but *is the way a
straight walk*. One `vertex_in_direction` probe along the ground from the actor toward the
target, on the same throttle as the visibility ray beside it. The probe landing near the
target means the floor between you is open and the route stays suppressed as clutter; it
stopping short means the way round is not obvious and the route draws. Folded into
`refresh_visibility` rather than added as a second gate, so it inherits the grace that stops
a probe flipping on a boundary popping the whole route in and out as you step.

**And it caught R2.32a happening again, twice, in one change.**

1. `walk_direct` was written above the file's `local function on_mesh`, so `on_mesh`
   compiled as a global and was nil at run time — the identical failure that killed the
   game on load in R2.32a. The difference this time is that a **harness caught it**, because
   the harness now exercises the path: R2.32a's whole lesson, paying for itself.
2. Moving `on_mesh` up to fix that put it above `local INVALID_VID`, so its guard
   `vid ~= INVALID_VID` compared against a nil global — true for *every* id. `on_mesh` then
   answered yes for points with no navmesh under them at all, and the goal snap silently
   stopped working. **Seven checks** in the off-mesh section failed and named it.

The second one is the sharper lesson: a local is only in scope after its declaration, and
that applies to the *values* a moved function reads as much as to the functions it calls.
Moving code upward in this file is a hazard in both directions, and the only reason neither
of these shipped is that the paths were covered.

The harness gained a `vertex_in_direction` stub to make any of this testable — it walks the
world's one obstacle, the off-mesh hole, which models the doorway exactly: ground you can
see across and cannot cross.

### R2.33k — It was never about loading · **2026-08-15**

Reported: on a fresh load the route goes through a wall, moving about produces a good one,
and then *"it seems to stick to that."* Both halves are true and neither is about loading.
One target, one log:

```
right after load:  id 19112 at 59.1 m -> gave up after 3000 nodes (closest 32.9 m)
walking closer:              32.5 m -> route found, 222 nodes
                             21.8 m -> route found, 995 nodes
                             12.9 m -> route found, 477 nodes
```

**It is distance.** A fresh load puts the player 59 m out, where the search exhausts its
budget and hands back a partial that stops 32.9 m short — pointing at a wall. Close the
distance and it completes. The "fresh load" was a coincidence of where you happen to stand
when a save opens.

**Two separate causes, two fixes.**

**1. The curve was short by half.** The measured need really does grow with the square —
about 1000 expansions at 32 m — so the shape was right and the size was not: `0.6 * 59²` is
2090, under the 3000 floor, while the measured need at 59 m is over 3000. Coefficient
doubled to **1.2** (59 m → 4480) and the cap raised 4000 → **6000**, about 1.2 s of
resumable search at `STEP_BUDGET`, covering everything out to ~70 m.

**2. Nothing ever retried a partial.** This is the whole of "it sticks", and it is the more
interesting half. The repath triggers are drift off the line and the goal moving — and
walking *along* a route is neither: the cursor advances, `DRIFT_TOL` never trips, the goal
has not moved. So a route that came back short stayed short for as long as you walked it,
even though the thing that fixes it is the walking. Now a **partial** route is searched
again once the actor has covered `RETRY_D` (10 m) since the last attempt, rate-limited by
`REPATH_MIN`. Only a partial: a complete route is already the answer, and re-running the
search every ten metres to be told so is pure cost.

The two compose. Past ~70 m the cap binds and a partial is the honest answer — and the retry
turns it into a real route as you close the distance, which is what the player was doing
by hand.

**The cap is now checked as a wall-clock**, not as a number: the worst case is what someone
waits through before a route appears, so the harness asserts it stays under two seconds at
the configured step rate. That is also what stops the cap being raised again without the
step rate being thought about.

### R2.33l — The pause was the route holding its breath · **2026-08-15**

Reported straight after R2.33k: *"seems better pathing but now we get huge pauses where the
routes don't update then it jerks into a new position."* Caused by the fix before it, and
the mechanism is worth writing down because it was latent for six sessions.

`update()` returned the moment a search was in flight:

```lua
if searching then
    why = "searching"
    step_search(tg)
    return          -- <- and the whole per-frame route maintenance with it
end
```

The marks hold a fixed distance ahead of the player (R2.29), and that only happens because
`place_chevrons` runs **every frame**. Skipping it nails them to the ground while the player
keeps walking. At the old 596-node budget the freeze lasted a quarter of a second and nobody
ever saw it; R2.33k took the budget to 3000-6000 and added a retry every ten metres, and the
same line became a second of frozen route followed by a jump. **The jerk was the freeze
ending, not the new path arriving.** A resumable search exists so the work can be spread,
not so the route can stop.

**Two halves, and the second is the one that nearly got missed.** Restoring
`place_chevrons` alone moved the marks 1.49 m for 8 m of walking — because `advance()` was
skipped too, so the cursor never moved, and `actor_arclen` clamps the actor's arclength to
the end of the leg the cursor sits on. One leg is one metre. So the cursor advances during a
search as well, with a `build_draw_list` when it moves, exactly as the normal branch does.

The first version of the harness check asserted only that the marks "moved a bit" (> 4 m of
a possible 8) and **passed against the broken half**. It now asserts they moved with the
*player* — 8 m of walking, more than 6 m of marks — because holding station ahead of him is
the actual property and anything weaker is satisfied by a stall.

`why` also had to learn to say "drawing" while a search runs behind it: "searching" is only
the whole story when there is nothing on screen, and `searching` is in the same status table
for anyone who wants both.

### R2.33m — A shortfall is not a verdict · **2026-08-15**

Third report of routing into a wall, and the log shows the machinery working perfectly:

```
16.3 m  22.0 m  28.8 m  36.6 m  31.2 m  24.3 m  18.5 m  15.3 m  17.7 m
   -> every one: gave up after 3000 nodes, closest approach 6.0 m, height 0.37 m
```

Nine searches as the player walked — R2.33k's retry doing exactly its job — every one pinned
at 6.0 m against target 19097, the one established unreachable in R2.33h. There is no route
to that NPC and there never will be. So the remaining defect was not the pathing: it was
that a best-effort approach ending **behind a wall** is drawn as a path.

**And the shortfall cannot tell you that.** Stopping 6 m short in the same room is a route
that delivered you — walk it, you arrive, you see them. Stopping 6 m short *through a wall*
is a line of marks aimed at masonry. Same number, opposite meaning. R2.33g's fade was built
on the shortfall alone, which is why fading the tail never fixed the complaint: it changed
how the last marks looked and not what every mark on the route **pointed at**.

**One ray answers it.** From the route's last point to the target, on search completion.
Clear means "this is as close as the mesh goes and you can see them from here", which is a
real answer and is drawn. Blocked means the route ends behind something, and it is withheld
entirely — the beacon still marks the target, which is the honest thing to show for a
target that cannot be walked to. Cast once per search, not per frame: it can only change
when the route or the target does, and both of those start a search.

Three cases, all covered in the harness: withheld when the end is behind the wall; drawn
when the end is in the open with the same 8 m shortfall; and never withheld for a small
shortfall, which is the route regardless.

`point_occluded` took the target position as its second argument already — it was written
against the camera, and the camera was only ever a point. Nothing needed generalising.

### R2.33n — "Unreachable" was wrong, and a second path to prove it · **2026-08-15**

Challenged on the R2.33h conclusion — *"there is a clear path to that location"* — and the
challenge was right. Pulling the whole history for target 19097 rather than the tail of one
session:

```
  route found at:   4.0  7.4  8.1  8.4  10.0  10.8  11.1  11.8  12.3  14.0
                    43.4  46.2  48.1  48.7  50.8  51.4
  gave up at:       10.9 ... 16-45 (most) ... 92.5
  closest on failure:  2.9,  6.0,  11.9,  16.5,  19.6
```

**16 successes and 63 failures on the same NPC.** It paths from inside ~14 m, and again
from 43-51 m, and fails in the band between. The closest approach on failure is not a
constant either — 6.0 was the most common plateau in the narrow sample R2.33h looked at,
not a barrier. **The goal is reachable.** Three sessions of "unreachable" rested on reading
a repeated number as a property of the world instead of a property of one sample.

It is not effort, either: the entire failing band gets the same 3000-node budget as the
43-51 m successes. It is about **where the player stands** — the search commits to a
direction, ends up in the wrong pocket, and spends its allowance there. That is the shape
of an A\* with an inflated heuristic in concave geometry, which is R2.23b's territory.

**So the next question is which half is wrong**, and until now nothing could tell them
apart. Between the A\* node list and the marks on the floor sit five passes — string-pull,
smooth, densify, clearance, snap — plus the lead-in at draw time. Any of them could bend a
good route into a wall, and "the search is wrong" and "we mangled a good answer" have been
the same observation all along.

**`IQM: Raw Path vs Ours` (F7)** ends that. It cycles raw → ours → off, and two rules make
it a fair test rather than a second opinion:

* **Nothing is done to the raw list** — `pull = false` as well, so it is the bare A\*
  answer, and `snap = false` on the renderer so the points are drawn exactly where the
  search put them. The gizmo renderer has no depth test, so it draws over geometry anyway
  and there is nothing to gain by lifting it off the floor.
* **Both go through the same renderer**, with identical options. Drawing the raw path as a
  wire and ours as ground marks would confound a difference in geometry with a difference
  in how the two are drawn — which is exactly the confusion this exists to end.

`iqm_pathline` did the whole renderer half already: a real 3D world-space polyline through
`debug_render`, built in R2.1 and never wired to the live route. The action is forty lines
of plumbing on top of it.

**One more diagnostic**, on the give-up line: `mesh continues N m toward it`, one probe from
the best node straight at the goal. Zero means the level graph stops there; anything else
means the mesh continues and the search simply did not go that way. Given the above, the
expectation is now firmly the second.

### R2.33p — A diagnostic that hides the route is not a diagnostic · **2026-08-15**

Reported: the ground route **and** the minimap markers both stopped showing. Caused by
R2.33m, one session old, and it is worth writing down as three separate mistakes rather
than one.

**1. The ray was aimed at the target's feet.** `point_occluded(last, goal, OCC_LIFT)` casts
from 0.25 m above the route's last point at `goal` — and `goal` is the target's *position*,
which for a stalker is the ground under them. Over six metres that ray grazes the floor and
reports blocked **in open ground**. It also, on the occasions it clears the floor, hits the
NPC. `point_occluded` was written to cast at the CAMERA: a point in empty air, at eye
height, with nothing standing on it. Neither of those is true of a target on the ground, and
reusing it without asking what its second argument had always been was the whole error. It
now aims at `TARGET_LIFT`, the same height the visibility ray uses on the same NPC.

**2. It gated `publish`, and `publish` is shared.** The ground route and the minimap trail
are two views of one published list (R2.24), so anything that withholds it takes out both.
A diagnostic reached into the one place that silences every consumer at once.

**3. And it was built on a conclusion that was already wrong.** R2.33n had established the
targets are reachable; suppression was designed for a world where they were not.

`dead_end` is now **reported and never acted on** — it goes to `status()` and the F7 dump,
and the route draws either way. The harness pins both halves: the flag tracks the geometry,
*and* the route is still drawn when it is set. The check that encoded the withdrawn
behaviour failed the moment the gate came out, which is how it should read.

### R2.33q — Two channels, and a harness for the renderer that had none · **2026-08-15**

Both paths at once, asked for after the toggle version. `IQM: Raw Path vs Ours` now draws
the bare A\* answer in **red** and the path we actually draw in **green**, together, and
says out loud when either came back empty.

**The change was small, and why it was small is the interesting part.** `iqm_pathline` looked
single-instance — one `pts`, one gizmo id range — but its segment store has carried a
per-segment colour since R2.1, and `pa`/`pb` are *indices* rather than references. So
several channels can share one flat point list, each tinted separately, and the occlusion
cull, which walks `pts` and keys `vis` by index, needed **no change whatsoever**. The work
was extracting the builder into `emit_channel(o, src, rgb, cam, n, base)` and offsetting
every `pa`/`pb` by that `base`.

**An empty channel is skipped and reported, not refused.** With two paths on screen the
interesting case is exactly when one of them is missing, and failing the whole call would
hide the thing being looked for. `show_channels` returns how many were drawn, and the F7
action prints node counts, `partial`, `short_by` and an explicit line for each empty one —
*no red line is a result, not a glitch*. Otherwise "the search returned nothing" and "the
renderer did not draw it" look identical, which is the confusion the overlay exists to end,
reappearing one level down.

**And the module finally has a harness.** It had none, because it draws through
`debug_render` and "you cannot test a renderer offline" felt obviously true. It is not:
gizmo count, endpoint positions, per-segment colour and cull indices are all arithmetic, and
only `add_object` belongs to the engine. Nineteen checks against a stub of that one call —
including the property this change put at risk, which is that a green segment never indexes
a red point. That one is invisible in a screenshot until the cull is switched on, at which
point one path would be culled against the other's visibility.

Its first version was a **fake pass**: it asked for a `debug_segs()` accessor that did not
exist and returned `true` when it was absent. `debug_geometry()` is public now and the check
is real. Two regressions reached the player unverified in this session; this is the answer to
that rather than an apology for it.

### R2.5 follow-ups — open

| # | Question | Status |
|---|---|---|
| R2.33t | Showing the raw and the drawn path **at the same time** wants two independent polylines, and `iqm_pathline` is single-instance: one `pts`, one gizmo id range from `ID_BASE`. The segment store already carries a per-segment colour (`segs[i].col`), so a two-channel `show` is a contained change rather than a rewrite — the coupling to solve is the cull, which indexes back into `pts`. Not attempted in the same session as a regression, and untestable offline (no `debug_render` stub, no pathline harness) | open |
| R2.33s | R2.33m's `dead_end` suppression was built on the belief that these targets were unreachable. They are not — so it now withholds routes in exactly the band where a route exists and the search missed it. Still better than marks pointing into masonry, but it is hiding a bug rather than reporting one. Revisit once `IQM: Raw Path vs Ours` says whose bug it is | open |
| R2.33r | Withholding is a stronger call than fading, and it means a quest target you cannot reach now shows **no ground route at all** — only the beacon. That is the honest answer, but judge whether it reads as broken. `dead_end` is one flag; making it fade to nothing instead of vanishing is a two-line change if the disappearance is worse than the wrong line was | open |
| R2.33q | The drift branch still returns early — stray past `DRIFT_TOL` and the route freezes until the repath is allowed to start (`REPATH_MIN`, 700 ms). Shorter than a search, and it only happens when you leave the line, but it is the same defect in a smaller place. Watch for a stall when you cut a corner wide | open |
| R2.33p | `RETRY_D` = 10 m. Each retry is a real search (up to 6000 expansions at 80 a frame), so on a long approach to an unreachable target this now runs one every ten metres for ever. If that shows up as a hitch, the answer is to back off the retry as the closest approach stops improving — the number is already published as `short_by` | open |
| R2.33o | `WALK_TOL` is 3.0 m — how near the probe must land to count as a straight walk. Too tight and the route draws in open ground where it is clutter; too loose and the doorway case comes back. Watch a target across an open yard (route should stay off) against one just inside a building (route should draw) | open |
| R2.33n | The handover now happens at ~12.5 m instead of 15.3. Check the dissolve reads as one marker becoming the other rather than as a swap — and that a beacon at 13 m over an NPC you can plainly see is wanted rather than clutter. If it is clutter, the answer is a shorter `appear_dist`, not a lower threshold | open |
| R2.33m | ~~Judge the dead-end fade in game~~ **confirmed working.** "They do seem to fade" — kept as the answer for an unreachable target; suppression not needed | closed |
| R2.33l | ~~Read the height figure on the next give-up~~ **answered: 0.37 m, flat.** Not R2.2f, and not the probe scheme either — an angled-wall fixture crosses every angle and door width in 3-31 expansions. The goal is simply unreachable (R2.33h) | closed |
| R2.33k | ~~Reproduce the doorway case and read the `aiming at ...` line~~ **answered on the first run.** `aim == target` throughout, so the snap was never involved; `node_budget` was the bug and is fixed in R2.33f | closed |
| R2.33i | ~~Capture `gave up after N nodes ... closest approach X m`~~ **captured.** 596 nodes, 6.0 m short of a 3.0 m arrival on a 19.6 m target — the budget was short and the search was close, which chose the fix (R2.33f) | closed |
| R2.33j | A partial route is drawn exactly like a complete one, and the player cannot tell the difference — which is how "stopped looking here" reads as "walk through this wall". Whatever happens to the budget, the tail of a partial should probably say so: fade it out, or stop it short of the closest-approach node. Cheap, independent of the search, and it makes the failure honest rather than misleading | open |
| R2.33h | The near mark now lands at 1.5 m at default spacing, closer than anything has been drawn since R2.19b rejected a mark at your feet ("it dominated, and worse, it was visibly wrong"). Three things have changed since — the lead-in, `alen` 0.85 → 0.50, `MLMIN` — but it is the same verdict to re-earn. If it reads as too heavy, the taper (scale the near marks down, halving their footprint depth) is rendered and ready rather than `NEAR_FILL` off | open |
| R2.33g | `MNEAR` 2.4 draws marks from 3.0 m where the old ramp meant nothing was solid below 5. That is the closest a mark has been drawn at full strength, and the keystone residual there is the largest — roughly 39% of the mark's width once R2.33a's shadow is counted. Judge whether the nearest mark reads as lying flat or as sheared; if it fails, `MFADE` back up is the lever, not `MNEAR` | open |
| R2.33d | The amber is the mod's DEFAULT, and MCM stores what the player already set — so an existing install keeps whatever colour it has and sees none of this. There is no migration (MCM rejects undeclared paths). Worth a line in the readme rather than machinery | open |
| R2.33e | The wear pattern is one field shared by all five shapes, at 256 px a cell, and the mark is drawn anywhere from ~350 px to ~12 px. Check the grain does not turn into mush at the far end or into visible repetition on the near one — and that the rung, which is mostly edge, is not eaten by it | open |
| R2.33f | `MARK_SHADOW_W` 0.75 was chosen on a preview floor, not a real one. The halo is soft and the ground under it is not; watch it on the light concrete patches where a dark ring has the most to say, and against R2.31's keystone cost (0.50 → 0.56) | open |
| R2.33a | `LEAD_M` = 8 m against `MNEAR` = 3 m: the nearest *drawn* mark carries ~60% of the offset, not all of it. Walk a strafe and judge whether the head of the route reads as coming from you or as still slightly beside you — a shorter `LEAD_M` fixes it at the cost of a sharper bend back onto the line | open |
| R2.33b | The lead-in has no mesh test. `LEAD_MAX` = 2 m is chosen against typical corridor width, not measured; the case to watch is strafing behind a pillar or into a doorway alcove, where the head of the line will cut the corner between you and the path. If it looks wrong, the fix is a `level.vertex_id` check on the displaced head rather than a smaller clamp | open |
| R2.33c | Does the residual actually stop swinging? R2.31's measurement was of one mark at one place; the claim here is that holding a mark's bearing on the camera holds its shape. Strafe with the near mark in view and watch whether its aspect still breathes | open |
| R2.23a | `cover_w` = 0.8 in game: does a route cross a courtyard rather than skirt it, and does it still take sensible lines through Rostok's corridors? The failure mode to watch for is a detour that reads as the route not knowing the way | open |
| R2.23b | Search cost. The surcharge makes `h_weight` relatively weaker, so long routes expand more nodes and are likelier to come back partial (`max_nodes` = 1200). Watch the F7 status dump for `partial=true` on routes that used to complete | open |
| R2.23c | `CLR_MAX` = 0.75 m. Enough to matter beside a wall; check it does not push the line off a narrow catwalk or bridge, where the ledge test is the only thing holding it | open |
| R2.26d | ~~The arms draw ~19% bolder than the renders they were judged from~~ **overtaken by R2.30**, which took all three dimensions down 20% — `aw` is now 0.304, within 2% of the 0.31 the sweeps actually showed. Nothing left to pick | closed |
| R2.29a | The marks now hold station ahead of the player, so on a curve they slide sideways across the ground as the path bends under them. Measured at 0.25 deg of heading per 0.05 m step on ordinary wander; watch a real switchback, where the bend is the point and the heading should turn with it, not lag | open |
| R2.28a | ~~World-anchored marks are walked over~~ **withdrawn** with the absolute phase (R2.29) — marks are never approached now, so nothing crosses `MNEAR` by walking, so each one crosses `MNEAR` and vanishes as you reach it. Watch whether that reads as a mark going out under your feet or as the route thinning in front of you — R2.21b asked this of the same arrangement and never got answered in game | open |
| R2.28b | R2.22 preferred sliding for the sense of flow. Now that the marks are still, check the route does not read as inert — the one thing it has instead is that you visibly pass them | open |
| R2.27a | ~~`MSQUASH` = 0.4 is a lie about perspective~~ **answered in game, R2.30** — it was a lie at every distance past 3.5 m, not just the far ones, and it read exactly as this asked about: marks tipping up toward you. Replaced by `MLMIN`, a px floor. The question it becomes: does the far tail past ~15 m still read at 6 px deep, or does it want 8 | open |
| R2.32c | The four new shapes have only ever been seen in `tools/route-preview`, whose textures it generates itself — the shipped atlas has been eyeballed as artwork but never drawn by the engine (R2.32a's crash meant the game never loaded at all). Switch through all five in game and check each glyph sits ON its rect — a box mismatch shows as the picture nudged off-centre inside its own footprint, most visible on the nearest mark | open |
| R2.32d | The rung and the tile do not point, so on a switchback the route's direction has to come from the trail alone. Watch one: at `route_gap` 3 m the marks may read as a line of debris rather than a path. If it fails, the fix is likelier to be the gap than the shape | open |
| R2.31c | `iqm_stroke.dds` on disk does not match what `tools/stroke-tex/build.py` now draws (up to 181/255 in a channel), because R2.26's `FEATHER` change was never rebuilt into it. The card rules in `iqm_cards.xml` still use it. Rebuild and eyeball the card underlines before adopting it — a sharper stroke is a card change, not a route one | open |
| R2.31a | The keystone residual is now confined to the nearest mark or two (24% of the mark's width at 5 m, 10% by 13 m). The only lever left is `MNEAR`: at 6.5 m the nearest drawn mark moves from ~6 m to ~9 m and the residual there is 14%, at the cost of ~9 m of bare floor in front of you. Decide it by walking, against R2.25's "the route starts at your feet" | open |
| R2.31b | `alen` 0.50 flattens the chevron; 0.30 would halve the error again but is a different glyph (a shallow wide V rather than an arrowhead). Judge whether the flatter mark still reads as pointing, especially at 20-40 m where it is only a few px deep — `tools/route-preview --sweep alen=0.68,0.50,0.40,0.30` | open |
| R2.30a | `MLMIN` = 6 px was picked from the geometry, not from a sweep — it is where the honest projection stops being legible at 55° FOV, and the game's FOV is the player's own. On a wide FOV the marks shrink and the floor binds nearer. Watch a straight run at 20-40 m for the point where chevrons become dashes | open |
| R2.26e | `MNEAR` = 3 m is R2.21's number. R2.30 shrank the mark 20%, so it now spans LESS depth at a given range than when this was asked and the affine error at 3 m is correspondingly smaller — the cut-off may want to come IN, not out, which would put the nearest mark closer to your feet. Judge the nearest DRAWN mark, not the missing one | open |
| R2.26a | `MARK_TAIL` 0.05 leaves the arms' outer ends effectively square. The long edges keep their feather and the far fade dims the small marks, but a hard tip is the classic thing to crawl as you walk — check a mark at 30-40 m rather than the near one | open |
| R2.26b | `marks` draws no stroke, so between two chevrons there is nothing at all. At `route_gap` 3 m that reads as a band; at the 10-30 m the menu allows it becomes stepping stones with no line to say which way the path bends between them. Worth deciding whether the style should clamp its own gap | open |
| R2.25a | With the trim gone, the HEAD/HMIN fade is the only near-plane treatment left. Watch the nearest ground chevron when you look down: it is the biggest thing on screen by a wide margin, and if it dominates the frame the answer is a longer `HEAD` or a lower `HMIN`, not the trim back | open |
| R2.23d | Cover is baked per level at compile time and reflects the geometry the AI graph was built against. GAMMA's level edits are mostly clutter and structures, so spot-check somewhere heavily modded that the values still describe the walls that are actually there | open |
| R2.22a | The R2.17 look with both ends tapered, which has not been seen in game since R2.18 took the tip ramp off: does the apex read as two strokes crossing, or does the taper hollow the point the way R2.18 claimed? `ARM_TIP` = 0.14 is the number | open |
| R2.22b | Sliding marks again, now that they are the deliberate choice rather than the default nobody questioned: does the route read as flowing ahead of you? | open |
| R2.21a | ~~`MNEAR` / `MFADE`~~ | **withdrawn** with the glyph default (R2.22); the two-quad arms have no near-mark problem to hold back |
| R2.21b | ~~Do marks pop at the cut-off?~~ | **withdrawn** — no cut-off any more | `MNEAR` = 3 m / `MFADE` = 2 m: does the route still read as starting at your feet, or has the cut-off put the complaint from the thirteenth session back? These are the two numbers to move, and they trade directly against how much of the trapezoid error is on screen | open |
| R2.21b | Do the marks pop or slide into view at the cut-off? A world-anchored mark crosses `MNEAR` as you walk, so the ramp is doing real work there in a way it never had to when the phase moved with the player | open |
| R2.20b | ~~The shear at 45° to the view~~ | **superseded.** The dominant term is the missing keystone on NEAR marks, not the shear on oblique ones — see R2.21 |
| R2.20e | The near mark's aspect after the `MCAP` fix: does a chevron hold the same shape from your feet to the far end now? The fourteenth session's screenshot showed the nearest mark as a long thin V while the far ones were correct, which was the `WMAX` clamp | open |
| R2.20a | The glyph in game at the near end, where a mark is largest: apex solid, edges clean, taper reading as a brush stroke rather than a fade-out? | **answered — yes.** "Much better chevrons" on the fourteenth session's screenshot; the apex reads as one mark at every distance shown |
| R2.20b | The shear, which is the one thing the glyph is worse at than two quads. Stand so the route crosses your view at ~45° — a switchback, or looking sideways off a path — and see whether the marks look skewed. `route_style = 3` is the A/B | open |
| R2.20c | 256 px of uncompressed RGBA is 256 KB, against 16 KB for each strip texture. Fine on its own; worth a glance at the memory line if anything else grows | open |
| R2.20d | `MARK_TAIL` = 0.34 was inherited from the arm texture, where it faded ONE end of a strip. On the whole glyph it fades both outer ends of the chevron, which may now be too much of the mark's length. Rebuild with `python tools/stroke-tex/build.py` | open |
| R2.19a | The apex with the asymmetric mitre, on the near marks and against dark ground: solid, or is the hairline of double coverage visible after all? | **answered — no.** The notch was much larger than a hairline, because the corrections used the ground angle rather than the projected one. Fixed in `place_arms`, and superseded by the glyph (R2.20) |
| R2.19c2 | Absolute phase confirmed in game on the fourteenth session's screenshot ("the chevrons no longer seem to be moving with the player, they now seem static") — the remaining question is only R2.19c, the one jump on a repath | open |
| R2.19b | Marks at your feet: does the nearest one read as painted on the floor now that it stays put, or does its size at 2 m dominate the frame? | **answered — it dominated, and worse, it was visibly wrong.** `HMARK` is gone; a mark below `MNEAR` is not drawn (R2.21) |
| R2.19c | Absolute phase means the marks jump once on a repath (DRIFT_TOL, a moving target, arrival). Walk a route that repaths mid-stride and see whether the jump reads as a glitch or goes unnoticed under the line moving anyway | open |
| R2.19d | The nub past the point that `MITRE` = 1.15 leaves on one arm. Erring long now spills outside the mark rather than inside the other arm, so this is the value that wants checking from a shallow angle, where the ground-vs-projected error is largest | open, `arms` style only |
| R2.18a | The apex in game: one solid arrowhead now, or is the overlap visible as a deeper patch? Two bodies at 84% alpha overlap to ~97%, which should read as solid rather than as a bright spot — but the near marks are where it would show | **answered — no.** The doubled region read as a light spot. Superseded by the asymmetric mitre (R2.19) |
| R2.18b | `MITRE` = 1.35 is a safety factor on an overlap derived from the mark's GROUND angle and applied to its projected one. Check a chevron seen from a shallow angle and from nearly overhead (a rooftop, a slope above the route): the error is largest where the projection distorts the angle most | open |
| R2.18c | (176, 196, 124) against wet concrete, yellow sand, rust, and at night. Cycle all four presets on the same stretch with F7 — and note that an MCM config which already saved the old green will keep it, so judge on a config that has not | open |
| R2.17a | The soft-capped arms in game, at the near end where the marks are largest: does a chevron read as one mark now, or can the two arms still be seen crossing at the point? | open |
| R2.17b | `ARM_TIP` = 0.14 / `ARM_TAIL` = 0.34 of the arm's length. Too little tail and the outer ends are still cuts; too much and the mark loses its width and reads as a thin V. Rebuild with `python tools/stroke-tex/build.py` after changing either | open |
| R2.17c | Geometry after the trim (0.85 × 1.15 m, 0.22 m arms) at 3 m spacing: band or row of slabs? And does the longer head fade (3.5 m) hold the nearest mark back without making the route look like it starts late — R2.15b's question again, now with something much larger at the near end | open |
| R2.16a | **The three designs in game, back to back on the same ground: F7 → Execute → "IQM: Route Style Cycle".** Does the arrow band read as the reference does, and does `arrows` (no line at all) hold together or fall apart into marks the way R2.9/R2.10 did? | open |
| R2.16b | Ground chevron geometry: `alen` 0.95 m, `awide` 1.30 m, `aw` 0.28 m thick, at 3 m spacing. Too big and they merge into a smear; too small and the band breaks up. Judge at 5 m, 20 m and 40 m — the near ones are the risk now that they lie flat and get their full perspective size | open |
| R2.16c | Widget count: `band` allocates 136 segment statics plus 32 for the classic chevron pool. Confirm no frame cost in a hub with cards up (this supersedes R2.13e / R2.8d as the live number) | open |
| R2.16d | Arms are appended after the stroke's slots, so they draw over ALL of it — including a nearer stroke segment where the route doubles back over itself. Watch a switchback for a chevron sitting on top of a piece of line that should be in front of it | open |
| R2.16e | `MAX_CHEV` = 16 at 3 m spacing stops chevrons at ~48 m of drawn path. With `route_dist` at 80, does the far end look deliberately faded out, or truncated? | open |
| R2.15a | Height-only snapping in game: is the staircase gone, and does the stroke still sit ON sloped ground rather than cutting into or floating over it? The node-centre height is the compromise; a ramp or a rubble slope is where it would show | open |
| R2.15b | The head fade at 2 m / 0.35: does the stroke now visibly start at the 3 m trim rather than 8 m out? This is the fourth pass at "where does the route begin" — R2.11c, R2.13c, R2.14e and this | open |
| R2.15c | **Decide the chevron design: A (stroke + sparse ground chevrons), B (dense ground chevrons only, the Cyberpunk reference), or C (thin stroke + dense chevrons).** Ground-space either way — scaling the billboards up cannot work, see R2.15. Costed in the table above | open |
| R2.15d | Try the MCM colour first: alpha ~240 and a brighter green (~168, 188, 104) against the same wet concrete. Some of "looks pretty bad" is value contrast, not geometry, and this needs no code | open |
| R2.14a | The joints in game: are the dark ticks gone? Look at a near stretch specifically, where the thickness step and the halo are both largest. If any survive, add the round join (a disc per interior vertex, between the halos and the bodies) | open |
| R2.14b | `FEATHER` = 0.11 of the thickness. Does the near end read as a soft painted band, or as blurred? And is the far end still crisp rather than dissolving into the ground? The two ends pull this knob in opposite directions | open |
| R2.14c | Smoothed corners in game: walk a right-angle building corner and a doorway. The corner should read as an arc; the doorway should stay sharp, because the veto refused the cut. If a doorway looks rounded, the chord probe is passing something it should not | open |
| R2.14d | `SMOOTH_CUT` = 1.5 m puts the arc ~1 m inside a right-angle corner. Does the stroke still look like it is describing the corridor, or does it visibly clip the inside of turns? | open |
| R2.14e | Head fade `HEAD`/`HMIN` = 0.14/0.10: does the near end emerge, or does the route now look like it starts too far away? This interacts with `NEAR_TRIM` (R2.13c) — tune them together | open |
| R2.14f | The chevrons are now the hardest-edged thing on the route: flat billboards with a hard halo, sitting on a soft band. Worth reconsidering their treatment, or replacing them with flowing dashes (R2.13f) now that the stroke reads as a path | open |
| R2.13a | The measured thickness in game: does the stroke now converge into the distance, and does a stretch crossing your view read as thinner than one running away? That asymmetry is the whole point of (1) and the one thing the old formula could not do | open |
| R2.13b | `route_w` = 45 cm of ground. Wide enough to read as a path, narrow enough that the near end after the 3 m trim is not a slab? Tune with the MCM track; the useful range is likely 30–70 | open |
| R2.13c | `NEAR_TRIM` = 3 m. Does the stroke starting ahead of you read as deliberate, or as the "it doesn't start at the player" complaint for a fourth time? If the latter, the answer is a narrower ribbon, not a shorter trim | open |
| R2.13d | `SEG_DIV` = 7 (segments of ~8°, so a ~14% thickness step per joint). Watch a near corner specifically: does the bend curve, or is it still faceted? And is the step across a joint visible on a wide near segment? | open |
| R2.13e | Vertex cap 36 at `route_dist` = 80: confirm the far end still reaches the drawn length rather than truncating, and that 72 route statics show no frame cost in a hub (this is C3 / R2.8d with a bigger pool) | open |
| R2.13f | Deferred from the R2.13 proposal, in priority order: smooth the A\* polyline (Chaikin on the coarse nodes, re-snapped, reverted at any corner that leaves walkable ground); a soft-edged cross-section texture for the stroke plus a glow instead of the hard keyline; flowing dashes as the direction cue (possibly retiring the chevrons); occluded stretches thinned as well as dimmed | open |
| R2.5a | In-game test of the whole chain: walk to a hand-in target behind a building and check the route appears, drapes correctly, trims as you walk, and hands over to the card at 16 m | open |
| R2.5b | Is "only when you cannot see them" the right rule, or does the route flicker in broken cover — a fence, a treeline, a doorway you keep crossing? `VIS_GRACE` (500 ms) is the only thing damping it, and it is a guess | open |
| R2.5c | `REPATH_MIN` = 1.5 s against a walking quest giver. Too long and the ribbon points at where they were; too short and a pacing NPC re-searches constantly. Watch one on a patrol route | open |
| R2.5d | Cursor-advance redraws call `show()`, which re-snaps and re-syncs the cull (~25 rays at 2 m spacing over 50 m). That is one burst every ~2 m walked — confirm it does not show up as a periodic hitch alongside the card scanner (C3) | open |
| R2.5e | The route ends at the target's *navmesh node*, and the beacon marks the target itself. Check the two do not visibly disagree when the NPC is standing somewhere the mesh does not cover well (indoors, on a step) | open |
| R2.12a | `iqm_core` has 18 of its 198 locals left. The next feature to touch it should extend an existing table rather than declare names; `python tools/check-lua.py` reports the exact figure | open |
| R2.11a | Does the stroke read as a path where 26 marks did not? Specifically: does it stay continuous over broken ground and round corners, or do the joints show as notches | open |
| R2.11b | ~~`route_w` = 7 px at 12 m, clamped 2.5-22. Check the near end is not a slab across the screen and the far end has not collapsed to a shimmer~~ | **answered in game (2026-08-13): the near end WAS a slab**, and no value of this option could have fixed it — the thickness was screen-space. Superseded by R2.13a/R2.13b |
| R2.11c | Does the stroke visibly start at your feet now that the straddling segment is clipped? This is the third attempt at that complaint | open |
| R2.11d | `SEG_MAX` = 4 m: walk a doorway and a switchback specifically, and check the stroke goes through the gap rather than clipping the jamb | open |
| R2.11e | Segments overlap by half a thickness to close the joints, which double-blends a short band at each one. Confirm that reads as a slightly deeper green rather than as beading | open |
| R2.11f | Chevrons at 10 m on a continuous line: enough direction, or too sparse now the line carries the path? Cycle 6-25 m with F7 | open |
| R2.10a | Does the route now appear on a genuinely distant objective, and does the partial run out cleanly rather than pointing somewhere wrong? F7 -> "IQM: Route Status" reports `drawing (partial route)` when it is one | open |
| R2.10b | Arrow spacing 2 m at 50 m is 26 marks. Confirm that reads as a route rather than as clutter | **answered in game (2026-08-13): no.** It reads as neither a route nor clutter, just as unrelated points. This is what led to the stroke (R2.11) |
| R2.10c | Search cost at range: the budget is now up to 4000 expansions. Watch for a hitch on the frame a long route starts, given it is sliced 40 per frame (so ~100 frames worst case, which should be invisible but is untested) | open |
| R2.9a | The inverted range model in game: walk toward a target across a level and confirm the arrows keep leading correctly as the route repaths, and that running out at 40 m reads as "that way" rather than as a bug | open |
| R2.9b | A* cost to a genuinely distant target. R2.2a measured ~21 expansions over 50 m; a 300 m route round real geometry is untested, and `max_nodes` is 1200. Watch for `search failed` in the F7 dump on long routes | open |
| R2.9c | Is army green (134, 152, 86) legible against the Zone's own greens and browns? The black halo is doing a lot of work here. Tune with the three MCM tracks | open |
| R2.9d | Chevron size 16 px at 12 m, clamped 5-44. Check the nearest is not overbearing and the far ones have not collapsed. (Was "arrow size" when the arrows were the whole route; superseded in scope by R2.11, not in substance) | open |
| R2.9e | `VIS_NEAR` = 25 m: does the route bowing out as you come into sight of the target feel like a handover, or like it cutting out early? | open |
| R2.8a | The sprite route in game: does a receding line of beads read as a path, and do the chevrons read as direction? Cycle all three styles with F7 on the same stretch | open |
| R2.8b | Bead size: `ROUTE_BASE` 10 px at `ROUTE_REF` 12 m, clamped 3–26 px. Check the nearest bead is not a dinner plate and the far ones have not collapsed to scintillation | open |
| R2.8c | Billboards do not lie flat, so a route crossing a steep slope may read as floating. Worth walking a hill specifically — this is the trade the wire renderer was buying | open |
| R2.8d | Sprite count: 20 beads + 16 chevrons is up to 72 statics on top of the cards' own. Confirm no measurable frame cost in a busy hub (C3) | open |
| R2.6a | The restyle and both fixes, in game: does the bold stroke read as one line at 5 m and at 40 m, and do the chevrons read as direction rather than as clutter? Cycle all three with F7 on the same stretch | open |
| R2.6b | Is 30% the right dim for occluded stretches? Too dark and it is invisible against night or dark interiors; too bright and the route reads as through-wall navigation, which is the thing the depth cull was for. Check against a wall in daylight and in a dark interior | open |
| R2.6c | With `cull_dim` on, the whole route is always on screen — confirm the halved `REPATH_MIN` (700 ms) is enough to keep it from visibly lagging a walking target now that you can watch the far end of it the whole time | open |
| R2.5f | Interaction with the beacon in the shared band: between 16 m and 50 m out of sight, you get a beacon AND a ribbon. Intended (destination + next stretch, the hybrid pattern) but never seen together | open |

### R2.4 — Presentation · **partly resolved**

Range-limiting is in: `route_dist` caps both how far the target may be and the
length of path drawn at once (path length, not straight-line distance — a route
doubling back round a building is exactly where the two differ). Style is three
presets on Advanced (hairline / ribbon / track with ties) and the ribbon takes the
mod's accent colour, so there is nothing to set for it.

Still true and still unused: with `debug_render` there is no alpha, so a distance
fade would have to be done by **dropping segments**, not by dimming them. Not
attempted — the length cap does the same job more bluntly. There is deliberately
no opacity option, because an opacity slider on a renderer with alpha blending
compiled off is a control that does nothing.

---

### R2.34 — The search was never running · **2026-08-15**

Routing through walls, in every one of its reported forms, was one line of endpoint
validation in `iqm_route.search_begin`.

`level.vertex_id(p)` is an **exact cell lookup**. It returns `INVALID_VID` for any point
in a cell the AI map never got a node for — a doorway threshold, the lip of a step, the
strip of floor along a wall. The player walks over those constantly. The engine does not
lose the actor there: `actor:level_vertex_id()` still names the node it is standing on,
because that is sticky state, updated only when the actor reaches a mapped cell.

Only the wrong one of the two is answerable from a bare position. So `search_begin` was
refusing the **start** — on ground the actor was standing on.

Measured live over the devkit bridge on `l05_bar`, with the actor at
`(212.888, 0.429, 50.032)` and the target General Petrenko 12.9 m away:

```
level.vertex_id(actor:position())  ->  4294967295   INVALID
actor:level_vertex_id()            ->  52912        0.87 m away, perfectly good
level.vertex_id(goal position)     ->  51634        fine
BFS over level.vertex_link         ->  22 hops, 15.4 m, 64 expansions
search_begin(position, goal)       ->  false
search_begin(vertex,   goal)       ->  true, then `done` in 3 nodes, NOT partial
```

**Why it read as a pathing fault.** A refusal here leaves the previous path up, and that
one was searched from wherever the actor stood when it last worked. The marks therefore
cross whatever wall now lies between there and here — a perfectly good route to a place
you are no longer standing. The failure is positional and lasts exactly as long as the
player stands still, which accounts for every symptom reported over three sessions:

- *"on a fresh load it routes through a wall until you move around, then it sticks"* —
  the search fails where you spawned, succeeds a step later, and sticks because it is now
  succeeding.
- *"lots of examples of no markers at all"* — same refusal, with no old path to fall back
  on.
- *"a band of positions between 16 and 45 m"* — not a band of distances. A band of
  **cells**.
- Both channels of the R2.33q red/green overlay agreeing — neither was wrong. They were
  the same stale answer.

It also explains why the whole of R2.33f/h/k moved nothing. Budget curves, floors, retries
and cooldowns were all tuning a search that was never started. The give-up counts in the
log were real, but they came from the *other* positions, where it ran and genuinely fell
short; the failing ones printed "an endpoint is off the navmesh" and were read as the
known off-mesh-target case that R2.2f had already accepted as a limit.

**The fix** is in `search_begin` and nowhere else: when the start is invalid and only then,
fall back to `db.actor:level_vertex_id()`. One chokepoint covers all four callers,
including both F7 drivers. The goal end deliberately does **not** get this — an arbitrary
world point has no engine-blessed vertex to fall back on, which is what `mesh_goal`'s ring
walk is for.

Two things the fix must not become, both pinned in `tools/route-harness/harness.lua`:

- **It must not swallow the real case.** A ladder or a rooftop leaves the actor no usable
  vertex either, and there `search_begin` still returns false. Turning an honest "no route"
  into marks aimed at nothing would be worse than the bug.
- **It must not fire on mapped ground.** The stub throws if `level_vertex_id` is consulted
  when the position was valid, so a vertex that lags a frame behind the position can never
  override a good start.

One claim I made while writing those tests was wrong and is worth recording: a route does
**not** begin at the actor's exact position and never has. `rebuild()` walks `came` over
vertex ids and reads their positions back, so the first point has always been the start
node's centre. The fallback cannot introduce a snap that was not already there — it only
changes *which* node, and only when there was no node at all.

**Method note.** This was found in about fifteen minutes with the devkit MCP after three
sessions of log-reading got the diagnosis backwards twice ("the target is unreachable",
retracted; "flat closest approach means a barrier", retracted). What broke it open was not
cleverness but two live reads that a log cannot give: `debug.getupvalue` on an exported
function to dump the module's private state, which showed the drawn path starting 15 m from
the player; and calling `iqm_route.search_begin` directly on the two endpoints, which
returned `false` where every offline reconstruction said it should not. The BFS over
`level.vertex_link` — 64 expansions against a 6000-node budget — is what proved the graph
was innocent before any code changed. Reach for the bridge earlier.

Open: whether `walk_direct`'s `on_mesh(apos)` guard wants the same fallback. It currently
returns false for an off-mesh actor, which suppresses the "just walk at it" shortcut and
so fails **toward** drawing the route. Safe, but it means the shortcut silently stops
working in exactly the cells this section is about, and that has never been observed in
game either way.

---

### R2.35 — Sixteen metres away, a hundred and seventy-five on foot · **2026-08-15**

R2.34 was real but it was not the whole of "pathing into a wall". With that fixed and the
actor standing somewhere `level.vertex_id` accepts, the marks still ran at the masonry.
This is the other half, and it is not a bug in the search at all.

Actor at `(199.6, 49.2)` in the Bar, General Petrenko **16.0 m** away through the wall of
the room. BFS over `level.vertex_link` gives the real walk:

```
hop   0   199.5, 49.0     you
hop  44   168.7, 49.0     33 m WEST -- the wrong way
hop  71   166.6, 65.8     then north
hop 125   170.1, 100.1    56 m of it
hop 178   196.0, 105.0    then 42 m east
hop 214   208.6,  86.1    then back south
hop 258   208.6,  62.3    Petrenko
```

258 hops, roughly **175 m**, out of the room and the whole way round the block. This is the
worst case an A\* heuristic can be handed: `h` points straight through the wall for the
entire search, so every expansion presses against it before the frontier ever turns the
wrong way up the corridor. Sweeping the budget on that exact search, live:

```
 3000 ..  8000  ->  partial, 6.02 m short,  2 points, ending against the wall
 9000           ->  partial, 3.77 m short, 19 points
10000           ->  COMPLETE, 2.89 m (inside `arrive`), 20 points, round the block
```

`node_budget(16.0)` was **3000**. Not close. And the old cap of 6000 was never even
reached — `300 + 1.2·16²` is 607, so the floor was the only term doing anything at this
range and the cap was decorative.

**Why the floor was not simply raised.** `max_nodes` is a ceiling and A\* stops the instant
it succeeds, so a bigger budget costs nothing in CPU for a search that was going to succeed
— an easy 6.4 m target measures 0.0 ms at 12000. But it is not free in **wall clock**: the
budget is spent `STEP_BUDGET` nodes to a frame, so 12000 is ~2.4 s before anything can be
drawn, against 600 ms today. Paying that on every search to fix the rare trap is the wrong
trade, and the nav harness's wall-clock bound on `node_budget` is what said so — it failed
the moment the floor went up, which is exactly the mistake it was written to catch.

**First attempt: escalate rather than raise the floor.** Keep the 3000 floor, and on a
dead end buy one search at 12000. `dead_end` is not a vague failure — it is `partial`, plus
a ray from the route's far end that cannot see the target — so it looked like exactly the
right trigger, and it finally gave that flag a use that could not take anything off screen
(R2.33p made it report-only after it broke both route and minimap by gating `publish`).

**It was worse, and the way it failed is the point.** The retry was a one-shot, guarded by
`esc_id` so a genuinely unreachable target could not buy a ~2.5 s search every `FAIL_COOL`.
In play the single retry got spent at one position; once spent it could never re-arm, so an
ordinary 3000-node search a few metres later came back partial again and the wall route
returned **permanently**. Caught only by reading `esc_id` out of the live game and finding
it already consumed while the marks were still in the masonry. Consumable state guarding
something that has to keep working is the wrong shape.

**So the floor goes up after all: 12000, cap 15000.** The argument against it was a
miscount of who pays. `max_nodes` is a ceiling and A\* stops the instant it succeeds, so
measured live:

| search | cost at budget 12000 |
|---|---|
| easy — 6.4 m target | 0 ms, stops in a few nodes |
| goal off the navmesh | 0 ms, `search_begin` rejects it before budgeting |
| already succeeding | unchanged |
| **hard but solvable** | **spends what it needs — this is the trap case** |

The only search that genuinely pays the whole 12000 is a target inside the mesh that cannot
be reached at all, and that is rare: the common "unreachable" is an off-mesh goal, which is
free. So raising the floor costs almost exactly the cases it is meant to buy.

The cost where it does bite, measured: **30.3 µs per expansion**, and the trap route
explores 9382 of them. `STEP_BUDGET` went 80 → 120 in the same change, giving 3.6 ms a
frame for ~1.25 s before the route appears. R2.33l keeps the previous route drawn
throughout, so it is heat rather than a gap on screen.

From the same spot afterwards: `partial=false`, 17 points, ending 2.89 m from Petrenko.

**One harness check turned out to be wrong on its own terms**, and it is worth recording
rather than quietly deleting. It asserted the floor must fit inside `REPATH_MIN`, reasoning
"or a route can be asked for again before it has finished answering". Nothing can ask —
`update()` returns as soon as it sees `searching`, so a search in flight is never restarted
and `REPATH_MIN` gates only the interval *after* one finishes. It was a latency preference
wearing a correctness argument, and at 3000 nodes it happened to hold, so it was never
examined. It is replaced by the honest question (how long a player waits, still bounded at
two seconds), a per-frame cost bound, and a direct test of the invariant it claimed to
protect: a search in flight is never restarted however stale the clock.

Open: a route that still dead-ends at the raised floor is drawn, pointing at a wall.
That is now a much rarer case and it is the honest one — the mesh really does not go there —
but "draw nothing" versus "draw a stub that fades" is unresolved, and R2.33p is the reason
not to reach for suppression without care.

---

### R2.36 - The navmesh is not a map of where you can walk · **2026-08-15**

R2.35 got the route to the far side of the block. It was still 178 hops for a 17 m target,
and the reason turned out not to be the search at all.

Standing in front of an open doorway with a step up into it, in the Bar:

```
vid 50899  (206.5, 51.1)   9.3 m away straight,   16 hops on foot
vid 51376  (207.9, 51.8)  10.9 m away straight,  271 hops on foot
```

**1.58 m apart, 255 hops apart on the mesh.** Statics rays across that strip come back CLEAR
at 0.3 m, 0.9 m and 1.6 m. It is not a wall. It is a threshold nobody meshed - and it was
turning a 29 m walk into 178 m.

It is not one bad doorway either. In a 17x17 m box around that spot: 32 unmapped gaps of
~2 m with mesh on both sides, **18 of them with no geometry in them at all**. Walkable holes
in the AI map are the level's normal condition.

This also corrects R2.35's own conclusion. There I ray-tested the straight line to the
target, hit solid geometry at three points, and wrote that the walls were real and the long
route correct. Both true - of that line. The door was never on it, and the door is where the
mesh is broken. Testing the line the route wanted rather than the line the player would take
is the error worth remembering.

**The fix: bridge the gap.** Where both probes run out, look up to `gap` metres further in
the same direction; if there is mesh over there and a statics ray finds nothing between,
link across at a surcharge. Result from the same spot: **150.4 m of walking becomes 21.1 m**,
and the search drops from **292 ms to 9 ms** - because it now finishes at the doorway
instead of exploring the whole block. The bridged step shows up in the path as y 0.21 ->
0.42, which is the sill.

Three things keep it from becoming "walk through walls":

- **It only fires where the probes already failed.** Open ground still costs eight calls a
  node. A ray is ~2 us against a ~30 us expansion, so eight per node would be half the
  search again; on a 40 m open route it casts almost none.
- **One ray per direction, not per candidate.** A wall close enough to block the nearest
  candidate blocks every farther one, so the first blocked ray ends that direction.
- **The ray is cast from the HIGHER end.** A doorway sill sits between the two nodes, and a
  ray launched from the low side at a fixed height buries itself in the riser - which would
  refuse every stepped threshold in the game, i.e. exactly the case this exists for.

`gap_dy = 1.0` is the honest limit of what the test can know. A clear chest-height ray
proves there is no wall; it does not prove there is floor, and the difference is a ledge.
The far side's own height is the only cheap evidence available, so a big step up or down
refuses. Being wrong here walks the player off something, so it is deliberately tighter than
a survivable fall.

The route harness already had the right fixture: `in_hole` is unmeshed ground that
`blocked` says nothing stands on, so the mesh stub refuses it while the new ray stub passes
through. The two checks that matter are the negative ones - a solid wall is never bridged,
and a drop on the far side refuses - because if either ever passes, the feature is worse
than the bug it fixes.

**And a way to see the mesh.** `iqm_meshview` draws a tick at every node within ~11 m,
coloured by hop distance from the actor's own node over `level.vertex_link`. Colouring by
*which cells have nodes* would have been nearly useless - connectivity is what goes wrong,
and you cannot see it. Coloured by walking distance, a red tick a metre from a green one is
unmissable and means exactly one thing: those two patches of floor are not joined. That is
what an unmeshed doorway looks like. F7 -> "IQM: Navmesh Snapshot".

It is a snapshot, not a live overlay: the flood fill is one pass over up to 30000 vertices
on the game thread, and the answer does not change while you stand still. Grey is a separate
colour from red on purpose - a node past the BFS cap has no hop count, and drawing that red
would manufacture the exact false severance the tool exists to detect. "I stopped looking"
is not "unreachable", and its harness checks that it never says otherwise.

Open: `gap`, `gap_dy` and `gap_w` are set from one doorway. The surcharge in particular is
untested against a case where a bridge and a real route are close in cost - the case here
was 21 m against 150 m, which no plausible surcharge changes.

---

### Open questions on routing, as of R2.37b · **2026-08-15**

Carried forward deliberately, with what is already known about each so the next session does
not re-derive it.

**low_cover_in_direction as a cheap pre-filter - TESTED AND REFUTED.** The idea was
attractive: a railing is textbook low cover, the value is baked and costs 0.00 us against
~2 us for a ray, so cover could reject a bridge before gap_link casts anything. Measured
over 556 nodes and the 152 boundary directions where gap_link actually runs, comparing the
baked cover against what the rays say:

```
baked cover               rays say
low<0.2   hi<0.2      ->  CLEAR  x6     solid x57
low0.2-0.5 hi0.2-0.5  ->  CLEAR x13     solid x53
low>=0.5  hi>=0.5     ->  CLEAR  x6     solid  x5
```

Uncorrelated. "Looks completely open" is solid 90% of the time; "looks blocked" is clear
half the time. Cover measures how enclosed a NODE is, for shooting and hiding, not whether a
2.8 m span in one direction is traversable - and at a mesh boundary those are different
questions. As a pre-filter it would reject real doorways and admit walls. Do not retry this
without a different measurement; the free-ness was never the problem, the signal is.

**Caching bridges per level, which IS the available win.** A hole in the AI map is static
level geometry, so the answer for a given (vertex, direction) can never change. Within one
search `S.closed` already prevents re-expansion, so the waste is ACROSS searches: every
repath re-casts the same rays over the same boundary nodes. A per-level cache keyed on
(vid, link index) would pay for itself immediately - ~17% of boundary directions came back
bridgeable - and it is the small version of the precomputed-table idea below.

**Precomputed bridge tables** remain the strongest long-term answer. Detect the holes once
per level offline, validate each properly - or by eye - and ship a table. Runtime cost
becomes a lookup and a false bridge becomes impossible, which matters because every bridge
is currently an INFERENCE: a ray tells you what is not there, never that the floor is
walkable, and each height added to GAP_RAY_HS is another guess at what a barrier looks like.
Real work: ~30 levels, and a validation pass worth trusting.

**gap_w = 1.5 has never met a hard case.** The surcharge on an inferred edge was tuned
against 21 m versus 150 m, which no plausible value changes. Its behaviour where a bridge
and an honest route are close in cost is simply unknown.

**iqm_core is at 191/198 locals.** Seven to spare. The next feature touching that file
needs its state grouped into a table first; the budget is a load-time syntax error rather
than a warning.

**And the pattern behind three of this session's bugs**, worth stating on its own because it
was not a code failure: R2.36's railing bars, R2.37a's rectangular hole and R2.37b's link
sentinel were all FIXTURE bugs. Each made a green suite meaningless - a stub that severed
more cleanly than the engine, a shape that made every gap axis-aligned, a constant tidier
than the real one. When something passes offline and fails in game, suspect the stub before
the code, and prove a new check discriminates by running it against the broken build.

## Cross-cutting

- **C1** MCM options for both features, matching the existing two-tab layout.
  **Done for F2**: Core gets `mark_route` (on by default) and `route_dist`, both
  under the same `mark_targets` precondition the beacon section uses; Advanced
  gets `route_style` and `route_xray`. Four options, on the grounds that
  everything else is feel rather than preference and belongs in the code where it
  can be explained.
  *Withdrawn (R2.7):* the near edge is no longer `appear_dist`. Tying it to the
  card was not a saved knob, it was a bug — the route and the card overlap, and
  should, because the condition that hides one is the condition that shows the other.
- **C2** Save/load and level change: route cache invalidation, plus the gizmo-queue
  wipe (already handled in `iqm_pathline`; verify in-game — see settled facts).
  **Driver side done**: `on_level_changing` and `actor_on_first_update` both drop
  the points, which is a different problem from the queue wipe with the same
  triggers — the pathline keeps the *handles* valid, the driver drops the *points*.
- **C3** Overall frame budget. Two new systems on top of an existing per-frame
  scanner and the experimental work detector. See R2.5d.
- **C4** Consistency with existing behaviour: reveal hotkey gating, PDA-open
  suppression, hostile-NPC exclusion. **Done**: the driver rides
  `iqm_core.overlay_visible()` — the same three gates `render()` applies — and
  blanks the ribbon through `iqm_pathline.suppress()` rather than dropping the
  route, so letting go of the reveal key costs no re-search. Hostile exclusion
  comes free: the target can only be an NPC `iqm_core` already carded.

---

## Decisions log

| Date | Decision | Why |
|---|---|---|
| 2026-08-13 | Hybrid: through-wall beacon (F1) + depth-tested ground ribbon (F2) | Matches genre convention; markers and paths have opposite depth needs |
| 2026-08-13 | `debug_render` cannot serve F2 | No depth test, and the state is compiled into the exe, not moddable from gamedata |
| 2026-08-13 | Same-level routing only for v1 | No game-graph edges exposed to Lua |
| 2026-08-13 | F1 extends the existing UI card layer, not `debug_render` | A beacon needs texture, text and a chevron; the wire renderer has none of those |
| 2026-08-13 | F1 stays online-only (gate 1 unchanged) | GAMMA's 450 m switch distance covers any proximity range; the offline path buys nothing |
| 2026-08-13 | Both features capped at proximity range (~50–80 m) | Design: help the player find a nearby target, not make the game materially easier |
| 2026-08-13 | F2 depth = raycast culling on `debug_render`, not particles | Particles can't be tinted or scaled from Lua, no effect reads as a ground marker, `particles.xr` is one monolithic contested file, and a missing effect name is an uncatchable `R_ASSERT3` fatal |
| 2026-08-13 | Cull with `ray_pick` directly, flags = 2 (Statics only) | The wrapper allocates per call and this runs every frame; Statics-only stops NPCs and crates chopping the route as they walk over it |
| 2026-08-13 | Route with coarse `vertex_in_direction` probes, not the `vertex_link` grid | Metres per engine call instead of centimetres, and the primitive walks the graph so it cannot cut through a wall |
| 2026-08-13 | Fire the short probe only where the long one was truncated | Truncation *is* the "geometry here" signal; pays for doorway resolution only where doorways can be |
| 2026-08-13 | The route follows the objective target only, not every beaconed role | One ribbon can be up at a time; a path that swings between a quest giver and a mechanic across a hub reads as a bug rather than a feature |
| 2026-08-13 | The route shows only while the target is out of sight | If you can see them the beacon already answers the question; a line to the feet of someone standing in front of you is clutter |
| 2026-08-13 | Route on by default, unlike the non-hand-in beacons | It is the headline of this release and the proximity cap already keeps it honest; the beacon roles are opt-in because they multiply, and this does not |
| 2026-08-13 | ~~The near edge of the route band is `appear_dist`~~ **superseded (R2.7): a flat 4 m arrival distance** | The card needs line of sight and the route only draws when there is none, so handing the near band to the card turned BOTH off for a target round a corner |
| 2026-08-13 | The driver casts its own visibility ray instead of reusing `has_los` | `has_los` rides the `los_check` option, needs a soft dep, and caches on a path that only refreshes inside `appear_dist` — the band the route does not work in |
| 2026-08-13 | **Occluded stretches dim instead of vanishing** (reverses the strict-depth decision above) | The route only draws when the target is out of sight, so the culled stretch was exactly the useful one; dimming keeps the depth cue AND the line, and needs no alpha |
| 2026-08-13 | Seeing the target BLANKS the route instead of dropping it | Dropping made every flicker of sight cost a rate-limited re-search, which is what read in game as "sometimes stops showing" |
| 2026-08-13 | Rails clustered 2 cm apart (a stroke), not spread 70 cm (a ribbon) | The renderer has no line thickness, so spreading rails spends the only available tool on width when what is wanted is weight |
| 2026-08-13 | Direction carried by chevrons, not by the line itself | Two straight arms is what a wire renderer is good at, and it is how a route is marked on a military map |
| 2026-08-13 | **Scripts are verified by compiling them the way the ENGINE does** | An offline `luajit -bl` over the bare file is clean for a file the game refuses to load: the engine prepends two locals, so the real budget is 198 and the check must model the loader |
| 2026-08-13 | Offline validation runs on LuaJIT 2.0 (`lupa.luajit20`), matching the engine | The exe is LuaJIT 2.0.4; a PATH LuaJIT is 2.1 (different branch) and PUC 5.1 is a different implementation. A prebuilt wheel avoids needing a compiler |
| 2026-08-13 | State near the local limit is grouped into a table, not added as names | The alternative is a syntax error at load that takes the whole module down; `RTE` bought back 21 slots |
| 2026-08-13 | **The route is one CONTINUOUS STROKE, not spaced marks** | Marks failed at 4 m and again at 2 m; a run of separate glyphs leaves the joining to the eye, and an axis of advance is drawn with a continuous line |
| 2026-08-13 | Drawn as non-square heading-rotated statics, one quad per path segment | The layer was assumed billboard-only; it is not, and the mod's own leader line had been relying on this since v1 |
| 2026-08-13 | Line vertices go where the path BENDS, not at even spacing | A line's vertex spacing is invisible and its shape is not; corners get vertices and straights cost a quad per 4 m instead of per 1 m |
| 2026-08-13 | Chevrons kept, riding on the stroke every `gap_m` | The one thing a plain line cannot say is which way along it to walk |
| 2026-08-13 | The chevron budget lives in `iqm_nav`, not the renderer | The renderer's own pool cap would have silently dropped the far half's chevrons at the tightest reachable spacing |
| 2026-08-13 | **A budget-exhausted search returns its best-effort path, not failure** | `best_vid` had been maintained for this from the start and discarded; throwing it away is why a distant target produced no route while a close one worked |
| 2026-08-13 | An unreachable goal also returns a partial | It hits `max_nodes` before exhausting its frontier, so the two cannot be told apart in practice; being walked to the building is useful, and a partial is always a real walkable path |
| 2026-08-13 | Expansion budget scales with target distance | 1200 was picked when the route was capped at 50 m; after R2.9 the search has to reach much further than what gets drawn |
| 2026-08-13 | `status()` carries a `why` string naming the closed gate | Five sessions were spent guessing which condition was stopping the route because the dump could only report the symptom |
| 2026-08-13 | **Route drawn out from the PLAYER for `route_dist` metres, with no target-distance gate** | Gating on target proximity meant the route appeared only once you had already found them; what a navigation aid should limit is how far ahead you can see, not whether you get one |
| 2026-08-13 | The visibility gate applies only within 25 m | Seeing a figure across a field says nothing about how to walk there; seeing one across a room means a line to their feet is clutter |
| 2026-08-13 | A dedicated `routearrow` glyph, undistressed, in army green | The beacon chevron is a fine line drawn once at badge size; this is a dozen marks at 5-44 px, where a light stroke and atlas wear both read as noise |
| 2026-08-13 | Beads dropped; arrows are the only mark | A dot says "the path is here", which an arrow already says, and two mark types at 4 m spacing crowded each other |
| 2026-08-13 | Arrows spaced by ARCLENGTH, not by point index | The path is sampled at 1 m so it drapes over ground; spacing by index would bunch arrows wherever a leg came out short |
| 2026-08-13 | **Route moved from `debug_render` to the card layer's textured sprites** | The wire renderer has no thickness, no alpha and rebuilds wholesale; all three were visible on screen as "thin" and "laggy", and none is tunable |
| 2026-08-13 | Perspective carried by per-sprite distance scaling, not by lying flat | A billboard cannot be perspective-warped, but a receding line of shrinking beads reads as a path anyway — which is what R2.1 got wrong when it dismissed sprites |
| 2026-08-13 | Occlusion is a per-point eased fade, not a per-segment verdict | Real alpha makes the round-robin invisible; the ribbon's batched flips were the "changing" half of the complaint |
| 2026-08-13 | ~~All suppression writes go through one `set_blank()` helper~~ **superseded: there is no suppression flag any more** | Not drawing is not publishing; the whole bug class needed a flag held in another module, and there is no longer one |
| 2026-08-13 | **The chevron's apex is filled by a MITRE overlap, extending each arm past the point** | Two rectangles sharing an endpoint at an angle always leave a wedge between their end cuts — the corner that would fill it is outside both. Derived from `hw / hl`, so it tracks the mark's geometry rather than being a tuned constant |
| 2026-08-13 | ~~The arm texture fades at the tip to soften the seam~~ **superseded: solid to the point** | Fading the arms where the mark should be strongest left the apex hollow; the overlap hides the seam with geometry instead, at full alpha |
| 2026-08-13 | Route green lightened to (176, 196, 124) | The army green was picked against the idea of the Zone, not its ground: wet concrete and the Garbage's sand sit at nearly the same value, so the route read as a stain on them |
| 2026-08-13 | Style and colour both get F7 cyclers on the live route | Neither can be judged except against the ground it is drawn on, and going through the MCM for each candidate costs a route rebuild and the comparison with it |
| 2026-08-13 | **A chevron arm is drawn at EXACT length; only stroke segments get the joint overlap** | The overlap exists to close the wedge a bend leaves between consecutive segments. An arm has no neighbour: the same extension overshoots its outer end and pushes both arms past the chevron's point, where their square ends cross into a blob |
| 2026-08-13 | Arms sample their own texture (`iqm_arm`), tapered along its length | A rectangle has square ends and a chevron has five of them; the stroke cannot share the taper, because a segment butts against the next one and a longitudinal fade would open a gap at every joint |
| 2026-08-13 | ~~Chevron arms share the segment pool~~ **superseded: their own pool** | A widget's texture is fixed when it is created, so a differently-textured arm cannot come out of the stroke's pool. Created after it, which still draws the mark on the line |
| 2026-08-13 | **Chevrons are drawn as two GROUND segments, not as a billboard** | A billboard cannot express the ~7:1 grazing-angle compression of a mark lying on the floor, so it stands up out of the path; two arms drawn by `place_seg` inherit the stroke's measured thickness, feather and halo and are genuinely flat |
| 2026-08-13 | Chevron arms share the segment pool rather than getting one of their own | They are segments in every respect, the all-halos-then-all-bodies order is already right for them, and taking the slots after the stroke's is what draws the mark on the line instead of under it |
| 2026-08-13 | Chevrons are published as their own list, placed at exact arclength | As flags on the vertex list a chevron could only land ON a vertex, which at the dense spacing scattered them by up to half a gap |
| 2026-08-13 | ~~A continuous stroke carries the path; chevrons only say which way~~ **superseded: the marks may BE the route again (`route_style`)** | Three whole designs ship instead, with the pre-R2.16 look as one of them, because "which of these reads best on real ground" is not answerable from the code — and the user asked to be able to revert |
| 2026-08-13 | **Navmesh snapping takes the HEIGHT only, never the plan position** | A node's x/z are quantised to the AI grid and only its y is fine (`level_graph_inline.h:63-88`), so writing all three staircased every route point onto grid intersections — undoing the smoothing one stage later |
| 2026-08-13 | The head fade is measured in metres of camera distance, not as a fraction of the vertex list | Angle-based spacing makes the near vertices the short ones, so a 14% fraction covered the first 3 m of path at a tenth of the alpha; the route looked like it started 8 m away |
| 2026-08-13 | Chevrons cannot be fixed by making the billboards bigger | A ground mark at 12 m is foreshortened ~7:1 and a billboard draws it uncompressed; small marks hide that, large ones read as placards standing out of the path. Ground-space arms (two per chevron) are the only route to the reference look |
| 2026-08-13 | **The stroke samples a feathered CROSS-SECTION (`iqm_stroke`), not a solid box** | A segment's rect height is its thickness, so an alpha ramp across the texture lands on the two long edges and feathers them; the same asset at a larger rect turns the hard keyline into a soft halo, with no second texture |
| 2026-08-13 | The feather is a fraction of the thickness, not a pixel count | Nothing in the UI layer can express "2 px of this rect", and proportional is right anyway: a 2.5 px far segment samples only its opaque core and stays crisp, while the near end -- where the hard edge aliased worst -- gets a real shoulder |
| 2026-08-13 | The halo may not be longer than the body it backs, and `EDGE` is kept under the thickness step | A longer halo caps every joint with a dark tick, and a halo wider than the neighbouring body protrudes along the whole overlap; both were visible as notches in the eighth session's screenshot |
| 2026-08-13 | **The A\* node list is Chaikin-smoothed before it is drawn** | The probes quantise every corner to 45 degrees, and string-pulling can only remove nodes, not soften a corner that is real; drawn as a stroke that reads as a folded ribbon |
| 2026-08-13 | The corner cut is capped in METRES (1.5), not taken as a fraction of the leg | Legs are 8 m probes and pulls of up to 24 m, so the textbook 25% cuts a corner by six metres -- walkable, and still not describing the corridor the route was found in |
| 2026-08-13 | The smoothing veto tests the CHORD with `vertex_in_direction`, not the two cut points | At a corner turned in a 1 m doorway both cut points stand on open floor and the leg between them crosses the jamb; the point-only version shipped first and the doorway fixture caught it |
| 2026-08-13 | Arc smoothness comes from smoothing PASSES, not from a finer `PATH_STEP` | `densify` only resamples the straight legs between smoothed nodes, so it cannot add a bend; halving `PATH_STEP` moved the worst joint not at all, a third pass halved it |
| 2026-08-13 | **Stroke thickness is MEASURED by projecting the ribbon's two ground edges, not computed as `w/d`** | `w/d` is the apparent size of something facing the camera; a ribbon on the ground is foreshortened by the grazing angle, so a stretch crossing your view must be thinner than one running away. No tuning of a single scalar can express that |
| 2026-08-13 | ~~`route_w` is thickness in px at 12 m~~ **superseded: centimetres of ground width** | Once the thickness is measured, px-at-12 m names nothing the renderer uses; the old 7 px default was an 11 cm path, i.e. the `WMAX` clamp had been doing all the visible work |
| 2026-08-13 | The near-end width clamp is a sanity ceiling, not a look control | It was fighting the perspective the same formula was trying to express, and flattening the near half of the stroke into a constant-width bar |
| 2026-08-13 | Segment length is `distance / 7`, not a constant 4 m | A constant world length spends the widget budget in inverse proportion to the screen area each widget covers; equal angle puts the detail where it is visible, and is what makes a quad's untaperable thickness step invisibly |
| 2026-08-13 | ~~The stroke starts at the player's feet~~ **superseded: trimmed 3 m in front of the camera** | With honest perspective a 45 cm ribbon one metre away genuinely is a slab across the screen; three sessions of trying to start it at your feet were fighting the geometry, not a bug |
| 2026-08-13 | ~~Both arms are extended past the point to close the apex~~ **superseded: ONE arm is extended and the other pulled back** | Two alpha passes over the same pixels leave `a(2 - a)`, not `a`, so the doubled region read as a light spot on the point. The wedge only needs filling once; the second arm is cut back to where it leaves the first arm's band |
| 2026-08-13 | The apex mitre errs long by 15%, not 35% | With one arm carrying the fill the surplus lands OUTSIDE the mark as a nub past the point, rather than inside the other arm where it was free |
| 2026-08-13 | **Chevron phase is absolute arclength along the route, not measured from the drawn start** | The drawn start moves with the player, so every mark slid down the floor at walking pace — and a mark that slides is a HUD element drawn on the ground rather than one painted on it |
| 2026-08-13 | The chevron run starts at the CURSOR while the stroke keeps its 3 m trim | The trim answers a fact about a wide band at one metre, not about a small mark; the mark is precisely the thing that has to be at your feet |
| 2026-08-13 | Marks measure the near fade from a fixed camera distance (`HMARK`), not from the nearest drawn vertex | The stroke's reference sits 3 m out, so every mark inside the trim measured as "at or before it" and was pinned at `HMIN` — most of why the marks looked like they began 10 m away |
| 2026-08-13 | **A ground chevron is ONE textured quad, not two** | A rect's w and h are set independently and `stretch="1"` maps the texture onto it, so a non-square heading-rotated rect IS "squash along the mark's axis, then rotate" — the foreshortening. And the two arms are unioned by `max()` inside the texture, before any blending, which is the only way two arms can meet at a point without a light spot or a notch |
| 2026-08-13 | A px clamp belongs to the quantity it was tuned against; the glyph gets its own (`MCAP`) | `WMAX` = 96 is a sanity ceiling for a 30 cm stroke and a real limit on a 1.2 m mark. Clamping the height while the length stayed measured distorted the aspect, and the aspect IS the mark's shape |
| 2026-08-13 | The glyph's rect is MEASURED (`seg_width`), not computed from distance | Same rule as the stroke's thickness since R2.13; a computed size would be a second sizing model on the same route |
| 2026-08-13 | **Routes prefer open ground, via the AI graph's baked cover value** | `high_cover_in_direction` is eight table lookups and no rays, which is what makes "how enclosed is this spot" affordable on every node the search touches. A ray-based clearance measure would have been unaffordable and no more accurate |
| 2026-08-13 | The cover surcharge is charged on the node ENTERED, and is relative | A property of the ground rather than of the approach; and relative means a doorway with no alternative is still taken, because a wall is expensive rather than impassable |
| 2026-08-13 | `h_weight` is NOT scaled up to compensate for the larger `g` | It spends path quality to buy expansions, and a greedier best-first search beelines and then follows whatever obstacle it hits — the exact behaviour the surcharge removes |
| 2026-08-13 | **`string_pull` refuses a pull that increases cover** | Straightening a bow is exactly what string-pulling does, and the chord across a deliberate bow is shorter, straight and perfectly walkable. Without this the surcharge measurably bought nothing |
| 2026-08-13 | Clearance is a second pass on the DENSE list, not more search | The search stands only on graph nodes and hops 8 m, so it cannot express "a metre further from that wall"; and a cover gradient leaves a corridor's midpoint alone for free, where a rule about walls would need to identify one |
| 2026-08-13 | The clearance push is permissioned by a destination NODE test, not a probe | The direction comes from cover, so it cannot be aimed at a wall — but it can be aimed at a drop, which has no cover either, and R2.15's node test is what catches that |
| 2026-08-13 | **The apex is left alone: two exact-length arms, both ends tapered** | Four fixes for the wedge between the end cuts were each geometrically sound and each traded it for something the eye liked less — a light spot, a notch, a swinging skew. Not drawing a hard edge there is what works |
| 2026-08-13 | **Chevron phase slides with the player (`PHASE_ABS` = false)** | Route-anchored marks walk you over every one in turn, so each passes through the near range where the drawing is worst and the mark is largest; and the sliding reads as the route flowing ahead of you. Both halves kept as live code, since the first-principles argument favours the losing one |
| 2026-08-13 | ~~A ground mark nearer than `MNEAR` is not drawn at all~~ **reverted with the glyph default** | The glyph's rect is an affine fit and a near mark covers too much depth for that to hold — its true projection is a trapezoid, and the missing keystone term reads as a skew that swings as you move. Fading to a third alpha kept the wrong thing on screen |
| 2026-08-13 | ~~The glyph's error is worst at 45° to the view~~ **corrected: worst NEAR** | Depth spanned by the mark drives the keystone error, not the mark's angle to the view. The 45° shear is real and much the smaller term |
| 2026-08-13 | The glyph accepts SHEAR that two quads did not have | The true map is `R'·S·R` and a rect gives `R'·diag(w,h)`, exact only when the mark's axis is the compression axis. Walking a route means looking down it, which is that case; the 45° error is on a decoration a metre across, and the apex it buys is visible on every mark |
| 2026-08-13 | The mitre corrections in `place_arms` come from the PROJECTED arm directions | The ground angle is not an approximation of the screen angle: grazing perspective widens `2a` toward 180°, so a ground-derived pull-back was several times too large and cut a notch out of one arm |
| 2026-08-13 | The two-arm rendering is kept as a style rather than deleted | Same argument as `classic`: one keypress is a cheaper comparison than a rebuild, and it is the design the glyph has to beat |
| 2026-08-13 | **There is no shader route, and this is settled** | The only Lua-reachable world draws are the 1 px wire renderer and particles from the single contested `particles.xr`; `DRender->dbg_DrawTRI` exists in C++ and is not exported. Textured world quads would need a custom `xrGame.dll`, which takes the mod out of GAMMA |
| 2026-08-13 | Driver in its own module (`iqm_nav`), not folded into `iqm_core` or `iqm_route` | It is a state machine over time, which is exactly what an offline harness is good at and what walking the Zone once is bad at |

## Artefacts

- `gamedata/scripts/iqm_pathline.script` — polyline renderer prototype; through-wall
  by default, depth-respecting with `opts.cull`
- `tools/pathline-harness/harness.lua` — 63 offline tests,
  `python tools/check-lua.py`
- `gamedata/scripts/iqm_route.script` — coarse A* on the level graph, cover-weighted
  so it keeps to open ground, plus the navmesh-vetoed corner smoothing and the
  clearance pass that pushes the drawn line off the walls it runs along
- `gamedata/textures/ui/iqm_stroke.dds` — the stroke's feathered cross-section;
  `iqm_arm.dds` — the same plus a taper along its length, for the `arms` style; and
  `iqm_mark.dds` — a WHOLE chevron as one 256 px picture, mitred and tapered, which is
  what the dense styles draw. All three built by `tools/stroke-tex/build.py`, whose
  `MARK_*` constants mirror `RTE.alen` / `awide` / `aw`
- `tools/route-harness/harness.lua` — 57 offline tests on a synthetic navmesh
  with a wall, a 1 m doorway, a cover model and a ledge, `python tools/check-lua.py`
- `gamedata/scripts/iqm_nav.script` — the driver: who to route to, when, and when
  to redraw. F7 → Execute → "IQM: Route Status" dumps its state
- `tools/nav-harness/harness.lua` — 120 offline tests over a fake clock, stubbing
  the other three modules, `python tools/check-lua.py`
- `tools/slot-harness/harness.lua` — 23 offline tests on the marker slot ordering:
  the Rostok eviction by name and distance, plus the swept invariant that a more
  actionable role is never dropped for a less actionable one
