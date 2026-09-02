# F3 — A GPS trail on the minimap

**Question (seventeenth session):** can the route be drawn on the HUD minimap, as a trail of
dots or small arrows rather than the AR stroke?

**Verdict: yes.** Nothing in the engine offers it directly, but every piece needed to build it
is reachable from Lua, the draw order already works in our favour, and the one genuinely
awkward part — knowing where the minimap is and how big a metre is on it — has a clean answer
that avoids parsing anyone's config.

---

## 0. State of play — read this first

**The feature is BUILT and WORKING in game** (2026-08-14). It is not finished — see "What is
left" below — but it draws correctly, follows the selected task, and needs no further
investigation to be usable.

### If you are picking this up cold

Read **§6a** (the design as built), **§6i** (when the trail shows) and **§6j** (manual
waypoints, and getting a goal onto the navmesh). Then this list.

**§6b–§6h are history**, not specification. They record how the design changed and why, which
is worth knowing, but they describe arrangements that no longer exist. Where they conflict
with §6a, §6a is right. The same goes for §4 and §8: valuable reasoning, several retractions,
and one question (F3c) whose recorded answer was later found to be wrong — see §8's table.

### Where it stands

| | |
|---|---|
| The renderer (`iqm_minimap.script`) | **working in game** — §6a is the authoritative description |
| Calibration | **works anywhere**, off the actor's own map spot; needs 4 m of walking and nothing else nearby (§6h) |
| Targeting | follows the **selected task's marker**, both views (§6c) |
| MCM | toggle plus two appearance options, eng + rus strings, independent of the AR route (§6b) |
| Tests | `check-lua.py` clean: 9 files, **minimap 50** / nav 153 / pathline 63 / route 57 |
| Manual waypoints | **followed like any other selected task** — §6j, which is also where the navmesh snap is |
| F3a, F3b, F3d | **answered** — §8 |
| F3c | **answered, and the first answer was wrong** — §8, §6h |
| F3e | superseded: the scale is measured at runtime, so no constant needs to be right |
| The probe (`iqm_mmprobe.script`) | **deleted at R2.44**, as §7 had asked — §7 |

### What is left

1. ~~**Delete `iqm_mmprobe.script`.**~~ **Done at R2.44.** It answered its questions and had
   become four dead F7 actions and two visible map spots in the launcher. Nothing depended
   on it.
2. **Confirm `UI_KX`'s direction in game.** The x axis scale is derived as `local × UI_KX`
   rather than measured (§6a). The harness proves the module is self-consistent, not that the
   constant is the right way up. If marks look stretched or squashed horizontally, invert it;
   `IQM: Minimap State` prints the local scale, both axis scales and `UI_KX` on one line.
3. **Watch the cull radius.** `SPAN_M` = 100 m is an engine reading, not a measurement. If the
   trail stops short of the map edge, or spills past it, that is the number to distrust — the
   screen-edge bound beside it is the factual one.
4. **Judge the mark pop at the cull edge.** Marks now vanish rather than fade (§6f). It
   happens short of the rim, so it should read as a pop in empty space; put a ramp back if not.
5. `README.md` does not mention this feature yet.

### What this feature is, and what it is not

This is **F3**, a second view of the route `iqm_nav` already computes — a trail of dots or
small arrows on the HUD minimap. It is not new pathing and not a change to the AR route.

* **F1** — the through-wall hand-in beacon
* **F2** — the AR ground route (`iqm_nav` + `iqm_route` + `IqmCards:draw_route`).
  Its own research log is **`docs/ar-navigation.md`**, which is long, and section references
  like *R2.13* or *R2.22* in this file point there
* **F3** — this

### Working in this repo

Conventions that are not obvious and that this feature has to obey:

* **Pre-ship gate, always:** `python tools/check-lua.py` from the repo root. It compiles every
  `.script` the way the engine loads them and runs all four offline harnesses. Current
  baseline: **8 files ok, nav 120 / pathline 63 / route 57 passed, "all good"**.
* **198 locals per `.script`.** The engine prepends two to Lua 5.1's 200-local function limit,
  and going over is a *load-time* failure that takes the whole module down. `check-lua.py`
  reports the headroom per file. `iqm_core` is the tight one at 180/198 — put new state in
  a table there, not in a new local.
* **`printf` substitutes the literal `%s` and nothing else.** A `%d` or `%.2f` prints raw *and*
  shifts every later argument. Pre-format numbers into strings. Three of the harnesses assert
  this over their own module.
* **F7 debug actions go in the launcher's `"action"` list**, which is the plain *Execute* tab —
  not `"target"`, which is *Execute on target*. Name them `IQM: <Subsystem> <verb>` so they
  group together: the existing ones are `IQM: Card as …`, `IQM: Cards …`, `IQM: Path …`,
  `IQM: Route …`, `IQM: Minimap Probe …`.
* **Read-only trees.** The engine source (`C:\Source\Gamma\xray-monolith-all-in-one-vs2022-wpo`),
  the mods tree, the unpacked vanilla base and the VFS manifest are lookup targets — never edit
  them. Resolve what the game actually loads with the `gamma-anomaly-debug` skill's
  `scripts/resolve.py`; searching the mods tree without it ignores load order and will mislead.
* **Log output** from the probe is prefixed `-IQM-MMP:` and lands in
  `D:\gamma0.9.5\Anomaly\appdata\logs\xray_<user>.log`.

---

## 1. What the engine offers, and why it does not fit

The only Lua route into the minimap is **map spots**:

```
level.map_add_object_spot(id, spot_type, hint)
level.map_add_object_spot_ser(id, spot_type, text)
level.map_remove_object_spot(id, spot_type)
level.map_change_spot_hint(id, spot_type, hint)      -- level_script.cpp:2456-2461
```

Every one of them is keyed on an **object id**. `CMapLocation` holds an object, and
`CUIMiniMap::UpdateSpots` (`ui/UIMap.cpp:595`) walks `Level().MapManager().Locations()` and
attaches one widget per location. There is no "spot at a position" and no polyline primitive
of any kind.

So a trail of N marks would need N objects. That is a non-starter — spawning alife objects to
draw a HUD element is worse than the problem.

**But there is a second door, and it turns out to be the useful one:**

```cpp
CUIStatic* map_get_minimap_spot_static(u16 id, LPCSTR spot_type)   // level_script.cpp:446
    -> def("map_get_object_minimap_spot_static", ...)              // level_script.cpp:2466
```

Lua can obtain a spot's actual **`CUIStatic`**. `CUIStatic` derives from `CUIWindow`, and the
bound surface includes everything the AR route already uses — `SetWndPos`, `SetWndSize`,
`SetHeading`, `SetTextureColor`, `Show` — plus `GetAbsoluteRect(Frect)`
(`ui/UIWindow_script.cpp:164-200`). That last one is the key to §4.

There is no `GetParent` and no child enumeration on `CUIWindow`, so we cannot walk from a spot
up to the minimap window and attach our own children to it. `get_hud():GetWindow()` returns the
HUD root (`UIGameCustom.h:123`) but the minimap is not reachable from it by name.

---

## 2. Draw order — already correct, by luck

This was the finding that could have killed the whole idea, and it goes the right way.

`CUIGameCustom::Render()` (`UIGameCustom.cpp:84-110`) draws in this order:

| # | What | Notes |
|---|---|---|
| 1 | `CustomStatics` | `AddCustomStatic` — the messages/pickup statics |
| 2 | `Window->Draw()` | the HUD root |
| 3 | per-slot `render_item_ui()` | detector screens, etc. |
| 4 | `UIMainIngameWnd->Draw()` | **the minimap lives here** (`CUIZoneMap`) |
| 5 | `m_pMessagesWnd->Draw()` | |
| 6 | `DoRenderDialogs()` | everything added via `AddDialogToRender` |

`iqm_core` attaches its window with `hud:AddDialogToRender(CARDS)`
(`iqm_core.script:3443`), which lands it in `m_dialogsToRender` and therefore in step **6**
(`UIDialogHolder.cpp:166-174`). So the card layer already draws *after* the minimap, and
anything we add to it appears on top of the map rather than under it.

Had we used `AddCustomStatic` or attached to the HUD root, we would have been drawing
underneath and would have had no way to fix it.

---

## 3. The transform

`CUIZoneMap::SetupCurrentMap` (`UIZoneMap.cpp:206-228`) gives the whole thing away:

```cpp
float zoom_factor = float(m_clipFrame.GetWidth()) / 100.0f;
if (pGameIni->line_exist(level_name, "minimap_zoom"))            // game.ltx
    zoom_factor *= pGameIni->r_float(level_name, "minimap_zoom");
else if (g_pGameLevel->pLevel->section_exist("minimap_zoom"))    // the level's own level.ltx
    zoom_factor *= g_pGameLevel->pLevel->r_float("minimap_zoom", "value");

wnd_size.x = m_activeMap->BoundRect().width() * zoom_factor;
wnd_size.y = m_activeMap->BoundRect().height() * zoom_factor;
```

`BoundRect` is the level's bounds **in world metres** (`game_maps_single.ltx`, `bound_rect`),
and the map window is sized to that times `zoom_factor`. Therefore:

> **pixels per metre = zoom_factor = minimap width / 100 × `minimap_zoom`**

`minimap_zoom` appears in no loose config — not in `_unpacked/configs`, not in any mod's
`.ltx` — so unless a packed per-level `level.ltx` sets it, the default holds and **the minimap
spans exactly 100 metres across**. Our route's default draw length is 50 m and its ceiling is
80 m, so a full route fits comfortably.

The other two terms:

* **Centre.** `UpdateRadar` calls `m_activeMap->SetActivePoint(Device.vCameraPosition)`
  (`UIZoneMap.cpp:189-194`), so the map is always centred on the camera. Route points are
  therefore positioned by their offset *from the actor*, and no level bound rect or absolute
  map origin is needed.
* **Rotation.** `SetHeading(-camera_heading)` each frame (`UIZoneMap.cpp:174-176`), applied only
  when `m_activeMap->Rotate()`. That flag comes from the minimap XML's `minimap:level_frame`
  `rotate` attribute, **defaulting to TRUE** (`UIZoneMap.cpp:44`, `:52`). None of the installed
  minimap mods set it, so it is on: the map is heading-up, not north-up. `device().cam_dir`
  gives us the same heading in Lua — but see §4, since this is one more thing that varies by
  which mod won and is better measured than assumed.

So the world→minimap map is a plain 2D similarity: rotate by the camera heading, scale by
pixels-per-metre, translate to the minimap centre. No perspective, no foreshortening, none of
the machinery R2.13–R2.22 needed. This is a much easier renderer than the AR one.

---

## 4. The awkward part, and the answer

**The minimap's screen rect is not what its XML says.** `CUIZoneMap::Init`
(`UIZoneMap.cpp:66-106`) takes the `level_frame` rect from `zone_map.xml` and then rescales it
by `UI_BASE_HEIGHT`, and by the `aspect`, `ratio_mode` and `rounded` attributes, with a
different branch per ratio mode. Reproducing that in Lua means reproducing display-option
arithmetic as well as parsing the XML.

**And it is not even one file.** `CUIZoneMap::Init` asks for `"zone_map.xml"`, but the UI
loader rewrites the name by aspect ratio before it hits the VFS (`ui_base.cpp:294-325`):
`zone_map_16.xml` on 16:9, `zone_map_21.xml` on 21:9, falling back to the bare name and, for
21:9, to the 16:9 file first. So *which* file supplies the rect depends on the player's
display, and each variant has its own load-order winner:

```
ui/zone_map_16.xml   WINNER: Sota UI EGUI Style HUD          (+4 other providers)
ui/zone_map.xml      WINNER: UI Rework G.A.M.M.A. Style - Sota (+3 other providers)
```

Five mods ship a minimap layout here. On this install a 16:9 player gets
`x="1.243" y="0.88" width="0.202" height="0.202"` and a 4:3 player gets
`x="1.214" ... width="0.152"` — a 33% difference in scale from the same install, before the
Init arithmetic and display options are applied at all. Any config-derived answer is a guess
about someone else's load order *and* their monitor.

**So measure it instead of computing it.** `map_get_object_minimap_spot_static` returns a
`CUIStatic`, and `GetAbsoluteRect(Frect())` reports where the engine actually put it — after
every rescale, on this machine, this frame. Given two objects at known world positions and
their two measured spot rects, the similarity transform is exactly determined: four unknowns
(scale, rotation, and a two-component translation), four equations. That single measurement
absorbs `UI_BASE_HEIGHT`, `aspect`, `ratio_mode`, `rounded`, the level's `bound_rect`, the
`minimap_zoom`, the mod's chosen position and size, and whether the map rotates at all.

It also self-corrects when the player changes HUD scale or resolution mid-session, which a
config read would not.

This is the same instinct as R2.13's measured stroke thickness: the projection already knows
the answer, so ask it rather than model it.

**Where the two reference objects come from** is the one open question. Options, best first:

1. **Our own invisible spot type on two online objects.** This mod already edits map spot
   definitions via DXML (`modxml_iqm_map_icons.script`), so adding an `iqm_probe` spot with a
   fully transparent texture is a known-good path. Attach it to the actor (which sits at the
   map centre by construction) and to the route target (whose world position we track anyway),
   read both rects, drop the spots. Needs verifying that a transparent spot still yields a
   `CUIStatic` rather than being skipped.
2. **Actor spot plus computed scale.** One measured point gives the centre; take
   pixels-per-metre from `minimap width / 100`, with the width recovered from the actor spot's
   own rect only if the layout is symmetric. Weaker — it reintroduces a config dependence.
3. **Any two spots that happen to exist** (a task target and a companion). Free when they are
   there and absent exactly when the route matters most.

### 4.1 The measurement is precise; the *reference* is what goes wrong

> **Corrected after probe run 2.** An earlier version of this section blamed pixel
> quantisation and tabulated an error budget against reference distance. **That was wrong**,
> and run 2 disproved it: two samples recovered the map's rotation to within **0.02°** and
> **0.05°**, which no integer-pixel measurement could do. The UI space is **float**, and spot
> placement is subpixel — the very first rect logged was `-4.12,-5.50 .. 4.12,5.50`, fractional
> on every edge. There is no quantisation floor to design around. The real fault was in the
> probe, and it is one line.

**The reference position goes stale.** `debug_calibrate` captures `ref_pos = obj:position()`
once (`iqm_mmprobe.script:162`) and `solve()` never re-reads it, while the *spot* it measures
tracks the object live. Point that at a walking NPC and the two halves of the solve describe
different worlds: the screen vector is where the NPC is now, the world vector is where it
stood at calibration. Both runs used `sim_default_duty_232063`, a Duty patrolman.

Run 2's four samples show the failure and its shape exactly:

| Sample | `rot` | `camera` | `rot + cam` | logged dist | `ppm` |
|---|---|---|---|---|---|
| 1 | 53.86° | −53.81° | **+0.05°** | 5.87 m | 1.551 |
| 2 | 173.57° | −145.30° | +28.27° | 3.58 m | 3.053 |
| 3 | −174.28° | 174.26° | **−0.02°** | 9.18 m | 1.352 |
| 4 | −174.33° | 167.18° | −7.15° | 16.27 m | 0.842 |

Samples 1 and 3 are near-exact; 2 and 4 are not. The difference is not distance — sample 2 is
the *closest* and the worst, sample 4 the farthest and still off. It is **which way the NPC
walked** between calibration and the sample:

* Move **tangentially** and the bearing changes → the rotation term is wrong (samples 2, 4).
* Move **radially**, straight toward or away → the bearing is preserved, so `rot` comes out
  perfect, but the distance is wrong → `ppm` is wrong (samples 1 and 3, whose rotations agree
  to a rounding error while their scales disagree by 15%).

That second case is the nasty one, because it looks like a good reading. It is why `ppm` still
is not measured after two runs: **every** sample so far has a corrupted distance term. The
logged `reference is N m away` is itself computed from the stale position, so it does not even
report the error honestly.

**Fixed.** `ref_position()` (`iqm_mmprobe.script`) resolves the reference through
`level.object_by_id` and returns its live position, falling back to `ref_pos` only when the
object has gone offline. `ref_pos` is now kept solely to measure drift, which `Sample` reports
on its own line — so a reference that wanders is visible in the log instead of silently
skewing the answer. With this in, the choice of reference object stops mattering.

Three consequences for the renderer, none of which the correction changes:

* **Take rotation from `device().cam_dir`, not from the solve.** Not because the solve is
  imprecise — it is not — but because §8.1 now shows `rot = −camera` exactly, so the camera
  gives the same number for free and needs no reference object at all. That drops the solve
  from four unknowns to two.
* **Solve for centre and scale only**, and cache them. The measured centre has been rock
  stable across both runs (`954.62, 675.84`–`675.91` across nine samples spanning two
  sessions), which is the strongest single number this probe has produced.
* **Re-solving per frame buys nothing** and needs a live reference spot every frame. Centre
  and scale change only on level change, resolution change or HUD rescale.

### 4.2 A freshly-added spot has no position for one frame

The calibrate action added both spots and read them back immediately. The actor's rect came
out `-4.12,-5.50 .. 4.12,5.50` — an 8×11 widget sitting at the **UI origin**, not on the
minimap — and both spots read identical, hence the logged `cannot solve: the two spots landed
on the same pixel`. One frame later the same call returned `954.62, 675.91`, the real centre.

`CMapLocation::Load` builds `m_minimap_spot` at construction (`map_location.cpp:179`) but
`CUIMiniMap::UpdateSpots` is what positions it (`ui/UIMap.cpp:595`). So the widget exists
before it is placed, and `GetAbsoluteRect` will happily report the unplaced rect.

**The renderer must reject a rect at the origin rather than trust it**, and must not calibrate
on the same frame it adds its spots. A rect whose centre is within a few px of (0,0) is the
tell; so is an actor-versus-reference separation under a pixel or two.

---

## 5. What "dots or small arrows" buys

The simplification is worth a lot, and it removes most of what made the AR route hard:

* **A dot needs no heading and no rotation.** One square `CUIStatic` per mark, `SetWndPos` and
  `SetWndSize`. A small arrow needs one `SetHeading` from the path direction, already published
  per chevron as `cdx`/`cdz` (§6).
* **No thickness measurement.** The minimap is orthographic, so a mark's size is constant. No
  `seg_width`, no ground-edge projection, no clamps.
* **No apex problem.** Five sessions (R2.18–R2.22 in `docs/ar-navigation.md`) went on two
  quads meeting at a point under perspective. A minimap arrow is a single glyph at a fixed
  size — the one case a billboard was always right for. The texture `iqm_route_arrow` already
  exists, is already declared in `iqm_textures.xml`, and is already drawn at 4–30 px by the
  `classic` route style, so the art question is settled before it is asked.
* **Culling replaces clipping.** Our marks are not children of the minimap's clip frame, so
  they inherit no clipping — but a dot is either inside the map circle or it is not. Drop the
  ones outside; there is no partial mark to trim. (A continuous line would have needed real
  segment-versus-circle clipping.)
* **Spacing is already solved.** `iqm_nav` publishes chevrons at exact arclength with a
  configurable gap; a minimap trail is that same list at a different spacing.

Cost estimate: one widget pair per mark, ~12–20 marks for 100 m at 5 m spacing. Against the
route's existing 36 segment pairs plus 16 mark pairs, this is small.

---

## 6. Proposed shape

A new `iqm_minimap.script`, a second consumer of the list `iqm_nav` already publishes. No
changes to pathing, occlusion, or the AR renderer.

```
iqm_nav.route_draw()          -- existing: world points + chevrons + eased alpha
   |
   +-- iqm_core  (existing)  -- AR stroke and ground chevrons
   +-- iqm_minimap  (new)       -- dots/arrows in minimap space
```

`route_draw()` (`iqm_nav.script:574`) hands back one persistent table, refilled in place — see
the comment on `RD` at `iqm_nav.script:277` for the full contract. What matters here:

| Field | |
|---|---|
| `n`, `p[i]` | vertex count and the world points of the stroke |
| `a[i]` | applied alpha multiplier, 0..1, already eased and occlusion-tested |
| `nc`, `cp[k]` | chevron count and their world positions, at exact arclength |
| `cdx[k]`, `cdz[k]` | unit direction of travel at each chevron — the arrow heading, free |
| `ci[k]` | index of the vertex whose alpha that chevron borrows |

So a minimap trail is `cp` transformed and drawn. Nothing needs computing that is not already
there, and the occlusion fade comes along for free if we want it.

Per frame, roughly:

1. Calibrate if the transform is stale (on level change, resolution change, or every N seconds
   — it is two engine calls and a solve, not per-frame work).
2. For each published chevron: offset from the actor → rotate by camera heading → scale →
   offset from the measured centre.
3. Drop marks outside the map radius; place the rest.
4. Fade the far end the same way the AR route does, so the two agree.

MCM: an on/off toggle at minimum. Plenty of GAMMA players run without a minimap at all, and
the feature must be invisible to them rather than drawing dots over empty screen.

---

## 6a. THE DESIGN AS BUILT — the authoritative description

**Read this section and §6i; everything from §6b to §6h is the history of how it got here.**
Those later sections record wrong turns that are worth knowing about, but they describe
designs that no longer exist. Where they conflict with this section, this section is right.

### Files

| | |
|---|---|
| `gamedata/scripts/iqm_minimap.script` | the whole renderer and its calibration |
| `gamedata/configs/ui/iqm_map_spots.xml` | the `iqm_calib` spot type |
| `gamedata/scripts/modxml_n_iqm_map_icons.script` | splices that file into `map_spots*.xml` |
| `gamedata/scripts/iqm_core.script` | config keys, and `active_task_target` / `route_goal` |
| `gamedata/scripts/iqm_nav.script` | publishes the route, the target distance and the goal |
| `gamedata/scripts/iqm_mcm.script`, `configs/text/{eng,rus}/st_mcm_iqm.xml` | the menu |
| `tools/minimap-harness/harness.lua` | 50 offline tests, run by `check-lua.py` |
| `tools/dot-tex/build.py` | builds `gamedata/textures/ui/iqm_dot.dds`, the dot style's glyph |

### Calibration — measured entirely off the actor

The transform is `absolute = C + (px·ex, py·ey)` where `(ex, ey)` is the world offset from the
actor rotated by the map's heading. Three quantities, all obtained from **the actor's own
`iqm_calib` map spot** and nothing else:

* **`C`, the centre** — the spot's `GetAbsoluteRect`. The actor is at the map centre by
  construction (`UpdateRadar` centres on the camera), so its spot is always inside the visible
  rect, always attached, and needs no movement. **Re-read every frame**, so a HUD rescale
  self-corrects.
* **The scale** — the same spot's `GetWndPos`, its **map-local** position. `SetWndPos` is
  called unconditionally and only `AttachChild` is gated on `IsRectVisible`
  (`map_location.cpp:396-414`), so local position never goes stale. Map-local space carries no
  rotation, so `|Δlocal| / |Δworld|` is a plain ratio of lengths. Needs `MOVE_SEP` = 4 m of
  walking **in any direction**. Solved once and cached per level + resolution.
* **`px`, `py`** — the local scale times `UI_KX` on x, times 1 on y. `UI_KX = (h/w)/(768/1024)`
  is the aspect correction the engine applies when it rotates the map: display arithmetic,
  known exactly, and the only computed part. §4's "measure, don't model" argument is about the
  map's rect and zoom varying by mod and load order; `UI_KX` does not vary that way.
* **Rotation** is `−atan2(cam.x, cam.z)` every frame — §8.1.

`iqm_calib` is a **1×1, `<mini_map>`-only** spot that stays on the actor while the trail is
on. One pixel rather than a transparent texture because there is no free transparent cell
(`iqm_map_icons.dds` is a 4×3 grid, all twelve used) and a spot's alpha comes from its
texture's pixels, not an attribute.

It is gated on `modxml_n_iqm_map_icons.iqm_calib_declared` — read **through the namespace**,
never as a bare global (§6a note below). Adding a spot of an undeclared type is not a soft
failure: `CMapLocation::Load` asserts and takes the game down. Without DXML the trail simply
never calibrates.

**Refusals, all tested offline:** a rect at the UI origin (§4.2), a scale outside 0.2–8.0,
under `MOVE_SEP` of walking, a missing spot, and an undeclared spot type. Each leaves the
transform invalid, and an invalid transform draws **nothing** rather than guessing.

### Rendering

Per frame, given a calibrated transform and a published route:

1. Hide entirely if the target is closer than `NEAR_HIDE` = 10 m (its own gate, well clear of
   `iqm_nav`'s `ARRIVE_D` of 4 m).
2. Walk the stroke vertices `rd.p[]` **in world metres**, starting at the actor, and appending
   `iqm_nav.status().gx/gz` — the goal — as one extra vertex.
3. Emit a mark every `size × 1.4` UI units of screen distance, converted to metres through the
   y scale. Not one mark per published chevron: `cp[]` is spaced for the AR view and would
   pile marks 2.5 px apart.
4. Always emit a **closing mark** on the end of the walk, unless one landed within 20% of a
   step of it. This is what puts a mark on the target.
5. Cull anything beyond `min(SPAN_M/2, screen-edge bound)` minus one mark's width. The
   screen-edge bound is a fact (the map cannot extend past the display); `SPAN_M` = 100 is an
   engine reading and the softer of the two.
6. Marks are **opaque**. No occlusion alpha, no rim ramp — see §6f, where getting this wrong
   twice is recorded.

Walking in metres rather than UI units is what makes spacing and culling rotation-independent
by construction rather than by arithmetic.

### Config

Through `iqm_core.DEFAULTS`, like everything else in this mod.

| Key | Tab | |
|---|---|---|
| `mark_minimap` | Core, under Route | **off by default**, and **independent of `mark_route`** (§6b) |
| `minimap_size` | Advanced | 4–16 px in the virtual UI, default 4 |
| `minimap_style` | Advanced | which glyph a mark is: `0` arrows (one `SetHeading` each), `1` dots |
| `minimap_r/g/b` | Advanced | the mark tint, **white by default** — what it drew before it had one |

**The tint is three tracks because MCM has no colour type.** `ui_mcm` registers
check / list / track / input / radio / key_bind / preset and nothing else
(`ui_mcm.script:1005-1046`), so an RGB option is three 0–255 sliders — the same shape the
ground route's `route_r/g/b` already had. It is the trail's **own** colour rather than a
share of those: the route's is picked to sit in the scene you walk through, and this one
is read off a map against terrain, the player arrow and every other mod's spots.

Two things it deliberately does not do. The **backing is not tinted with it** — that widget
is the mark's outline, and colouring it turns a dark rim into a second coloured sprite 2 px
larger, i.e. a halo. And there is **no alpha slider beside it**: §6f is three separate
attempts at fading these marks, and a tint reopens none of that. The keyline baked into both
glyphs survives any colour, because black times anything is black — the same property the
PDA map icons rely on.

Unlike the style, a colour change needs **no pool dump**: the tint is applied per mark in
`place()` rather than chosen at creation, so it lands on the next frame and the sliders
show the trail changing as they are dragged.

The style is a **list**, not the arrows/beads checkbox it started as, and the difference is
that a style is a whole little design rather than a flag: `iqm_minimap`'s `STYLES` table holds
the widgets each one is built from and whether it carries a direction, so a third style is one
row there, one entry in the MCM list and two strings.

**The two styles are not built the same way, and that is the interesting part.** Arrows are
`route_arrow` plus `route_arrow_sh`, the glyph-and-dark-backing pair every small mark in this
mod uses. Dots are **one widget**, `minimap_dot`, over a texture that carries its own keyline
(`tools/dot-tex/build.py` → `iqm_dot.dds`). The pair idiom fails at minimap scale for two
reasons, and only the first is obvious:

* The backing is a **fixed** 2 UI units larger. On a 1080p display the virtual UI is scaled
  1.875×, so an 8-unit dot is ~15 real pixels and its "keyline" is ~3.75 — a ring, not an
  outline. Scaling the backing with the mark would fix that, and not the next one.
* The two widgets are positioned independently, so their centres **round to screen pixels
  independently**. At this size half a pixel of disagreement is a visibly off-centre ring: the
  mark and its border stop reading as one object.

Baked, the keyline is concentric by construction and holds its proportion (~8% of the radius)
at every size the menu offers. `STYLES.sh` is therefore optional, and `ensure()` / `place()` /
`hide_from()` all treat a style with no backing as the ordinary case rather than a special one.
The arrows keep theirs: they are drawn larger, and a chevron has no fixed side for a keyline to
be concentric with anyway.

Two things the style has to get right, both pinned by the harness. A mark's widget is chosen
**once, at creation**, so `configure()` dumps the pool on any push — without that, switching
style would keep drawing the old glyph until the trail happened to want more marks than it had,
which reads as the option doing nothing. And an unrecognised value (a stale MCM entry, or one
written by a later version) falls back to the default instead of indexing `nil` and taking the
trail down.

The dot is deliberately its **own** element and its own texture rather than the card's
`card_node` over `iqm_circle`, which it borrowed at first. `place()` sets the size and the tint
itself, so before the keyline was baked the two drew identically — which is exactly the trap:
sharing it means the trail changing look whenever the card's head node is retuned.

Shared with the AR route, because they shape the route `iqm_nav` **publishes** rather than
either drawing of it: `route_dist`, `route_gap`, `route_xray`. Those show when *either* view
is on.

### Two engine facts worth not rediscovering

> **A spot TYPE is not the element name in `map_spots.xml`.** Type `secondary_task_location`
> draws element `secondary_task_spot_mini`. Asking for an element name returns nil with no
> error — indistinguishable from "the object has no spot".

> **A `.script` runs in its own environment table.** A bare `x = true` in one module sets
> `thatmodule.x` and creates **no global** of that name. The write succeeds, the read
> succeeds, and the value is nil. This cost a full debug round trip; the harness now pins it
> with a test that sets a bare global of the same name and asserts it does *not* count.

### 6b. The two views are independent

Either can be on without the other. That is not a one-line change, because "is there a route
to draw" and "which views want one" were the same question until now — three places had to
move:

1. **`iqm_nav`'s enable gate.** Now `mark_targets and ((bok and mark_route) or
   mark_minimap)`. The AR route projects, so it needs the `world2ui_with_depth` binding and
   is pointless without it; the trail measures its own transform off the map and does not
   care. Either consumer asking is reason enough to path. **A minimap-only player therefore
   gets a trail even on an install where the AR route could never draw.**
2. **The AR renderer's own gate.** `iqm_core` used to treat "`iqm_nav` published" as
   "draw the ground line". That is no longer true — `iqm_nav` may be publishing purely for
   the trail — so `C.mark_route` is now checked at the draw call as well as at configure
   time. Without this, switching the ground route off would not have switched it off.
3. **Which options belong to which view.** `route_dist`, `route_gap` and `route_xray` shape
   the route `iqm_nav` **publishes**, so they apply to both views and now show when either
   is on. `route_w`, `route_size`, `route_style`, `route_a` and the route colours are about
   the line on the ground and stay behind `mark_route`. Getting this wrong would have left a
   minimap-only player unable to change how much trail they get.

Strings are in both `eng` and `rus`. **The Russian file is `windows-1251` with CRLF** — it
cannot be edited with a UTF-8 editor without mangling every existing string, so it was
patched through a script that reads and writes that encoding. Both files parse and carry the
same 203 ids.

**Tests:** `tools/minimap-harness/harness.lua`, 22 assertions, run by `check-lua.py` with the
others. It builds a synthetic minimap at a known centre and scale and asserts the solve
recovers them, including at a non-zero heading — which is what proves rotation is re-derived
per frame rather than baked into the cache. Verified non-vacuous by mutation: flipping a sign
in `orient()` fails two assertions.

### 6c. What the first in-game session changed

It drew, and then four things were wrong. Three were AR decisions that do not survive the
change of view, and one was mine.

**The route now follows the SELECTED task's marker.** It used to lead to the nearest tracked
NPC with role `target`, which has no connection to the marker the player chose in the PDA —
a line going somewhere other than the bracketed marker reads as a bug however defensible the
choice was. Selection is engine-side (`map_location.cpp:376` compares against
`GameTaskManager().ActiveTask()`), and there is no "get active task" binding, so
`iqm_core.active_task_target()` walks `task_manager`'s list asking
`db.actor:is_active_task(t.t)` and returns that task's `current_target`.

**Both views follow it** — one search, two views, decided deliberately. It also fixes most of
the retarget latency for free: the old target came from an amortised NPC scan, so a new one
was not a candidate until a pass completed, whereas the active task is readable immediately.

That target is often **offline**, which broke an assumption baked into `iqm_nav`:
`level.object_by_id` failing meant "gone". Position resolution moved to
`iqm_core.route_goal()`, which returns id, position and an `online` flag — falling back to
the alife position, and returning nil for a target on another level, where no navmesh path
exists. `iqm_nav` skips the visibility ray for an offline target, since that ray asks about
geometry which is not loaded.

**The trail is resampled, not one mark per chevron.** `cp[]` is spaced for the AR view — 3 m,
which at ~0.85 px/m is 2.5 px between 8 px sprites. §5 said "that same list at a **different**
spacing" and the first build ignored it. `iqm_minimap` now walks the stroke vertices `p[]`
and emits a mark every `size × 1.4` **screen** pixels.

**The walk starts at the actor**, which is item 2 for free: `NEAR_TRIM = 3 m` (plus up to
`TRIM_FRAC` of the drawn length) is trimmed off the near end because a 45 cm ribbon a metre
from the eye is a slab across the screen — an argument about perspective that means nothing
from above, where it reads as the trail not starting at you.

**Occlusion alpha is gone.** The trail borrowed `a[]`, which is a *camera* occlusion test. With
`route_xray` off an occluded point eases to **zero**, so in a built-up area almost the entire
trail was invisible and a single chevron survived — which is exactly what the screenshot
showed. A map sees through walls, so occlusion has no meaning in this view. `minimap_fade`
now means *dissolve toward the map rim*.

### 6d. Two axis scales, not one — why marks swung with the camera

The second session's symptom was precise and worth recording: *the marks change position
depending on player rotation, and the trail does not leave the player toward the target.*

**The virtual UI is not square on screen.** A mark is placed in 1024×768 space, which is
drawn at `(dx · w/1024, dy · h/768)` — two different scales on any display that is not 4:3.
The minimap is a **circle on screen**, so in UI coordinates it is an **ellipse**, and one
metre east is a different number of UI units than one metre north.

A single scalar px/m is therefore wrong by a factor that depends on which way the route runs,
and because the map is heading-up that factor **changes as the player turns**. Hence marks
that swing, and a trail sitting off to one side instead of leaving the player's feet.

The relationship is computable — it is `UI_KX` — but §4's whole argument is that measuring
beats modelling, and measuring both axes costs nothing extra. With rotation known, each axis
is its own one-dimensional solve:

```
sx = cx + px * ex      ->   px = Δsx / Δex,   cx = sx - px * ex
sy = cy + py * ey      ->   py = Δsy / Δey,   cy = sy - py * ey
```

Two consequences for how calibration behaves:

* **Each axis solves separately, against a held anchor.** They rarely come good on the same
  frame — walking due north separates `ey` and barely moves `ex` — so the anchor observation
  is kept until both have landed rather than replaced each frame. `AX_SEP` is 4 m per axis.
* **Turning alone calibrates.** `e` is the world offset *rotated by the camera*, so it moves
  when the player looks around even standing still. A player who never walks in a straight
  line for long will complete both axes almost immediately.

Everything downstream got simpler rather than harder. The renderer now walks the route **in
world metres** and converts only at the final placement, so culling (`≤ SPAN_M/2 · EDGE`
metres) and mark spacing are rotation-independent by construction rather than by arithmetic,
and the arrow heading comes straight from the rotated world direction with no `UI_KX`
correction of its own — the two axis scales already carry it.

The harness now models the two scales as genuinely different (0.68 / 0.85, the `UI_KX` of a
16:10 display). A single-scalar synthetic map would have passed either implementation. Two
tests pin it: the same world route drawn at four headings must land on the same **ground**,
and an eastward route must step by the x scale. Mutation-verified — collapsing to one scalar
fails both.

One bug this turned up on the way: `debug_recalibrate` cleared `ok` but left the per-axis
flags set, so a stale half-transform would "complete" instantly using scales measured before
whatever invalidated them. `cal_clear()` now owns all three.

### 6e. F3c bites — the reference has to be ON the map

Following the selected task's marker (§6c) walked straight into the one question §8 had left
open. The marker is usually far away, therefore off the minimap, and:

> **An off-map spot does not degrade. It FREEZES.** `IsRectVisible` gates the reposition
> (`map_location.cpp:403`), so the rect keeps reporting wherever it was last placed however
> far the player walks. The geometry moves and the measurement does not, which is a scale of
> **zero** — `rejected x solve: -0.01 px/m`, forever.

The trail that was drawn came from an earlier solve made while the target still happened to
be near, which is why it appeared at all and why it appeared in the wrong place: compare the
good `centre 965.5, 675.8` against the bad `centre 674.40, 740.33` in the same log.

Two changes:

* **`REF_MAX_D` = 20 m.** A reference further than this is refused outright rather than
  measured and rejected afterwards. Deliberately well inside any plausible map, so it does
  not depend on `SPAN_M` being right.
* **A near object as fallback.** `iqm_core.nearest_reference(max_d)` returns the closest
  online object. The route target is used only while it is close; otherwise anything nearby
  serves, since the transform is a property of the HUD and the level, not of which object
  was measured.

  The first version of this asked for the nearest **carded** NPC and that was too narrow to
  be useful: cards are rare and situational, so the fallback almost never fired and the
  trail waited until the player walked within 20 m of the objective itself before appearing
  at all — which is exactly how it behaved in game. It now walks `db.storage`, every online
  NPC and creature, so any stalker or mutant standing nearby calibrates it. The result is
  cached for 500 ms, since while uncalibrated it is asked every frame and a full walk per
  frame is real work for a question whose answer changes slowly; once calibration lands it
  is never asked again for that level.

The transform is cached per level and resolution, so one near reference at any moment
calibrates for the rest of the level.

Also worth recording: the earlier logs show the module measuring **~1.53 px/m**, not the
probe's 0.85. The probe's figure came from a stale reference (§4.1) and was never
trustworthy; this one is measured live. It matters because `SPAN_M` is still an assumption —
which is why the cull now has a second, factual bound.

**The cull radius is bounded by the screen, not only by `SPAN_M`.** The map is centred at the
measured `(cx, cy)` and cannot extend past the display, so its radius is at most the distance
from that centre to the nearest edge of the 1024×768 UI, converted through the measured
scales. On a minimap tucked into a corner that is much tighter than `SPAN_M/2`, and it needs
no assumption at all. Whichever bound is smaller wins, and `IQM: Minimap State` prints both.

`SPAN_M = 100` stays a constant rather than an option: it is §3's engine reading, and it is
no longer the only thing standing between the trail and marks drawn outside the map circle.

### 6f. A near gate, and no alpha at all

Two changes once the trail was working and could be judged on how it reads rather than on
whether it appears.

**`NEAR_HIDE` = 10 m.** The trail is not drawn at all once the target is closer than this.
Its own gate, well clear of `iqm_nav`'s `ARRIVE_D` of 4 m, and the two are right to differ:
a ground line at 6 m is still something to walk along, while a trail at 6 m is three marks
in a smudge under the player arrow, on the part of the HUD where space is scarcest. It rides
a `dist` field `iqm_nav` now publishes from the distance it already computes, so it costs a
table read rather than a second target resolution.

**The alpha is gone — marks are opaque.** This is the third time the alpha here has been
wrong, and the pattern is worth keeping:

1. It borrowed `iqm_nav`'s `a[]`, a *camera occlusion* test. With `route_xray` off an
   occluded point eases to zero, so in a built-up area the trail vanished (§6c).
2. It was replaced by a ramp toward the map rim, which was defensible but solved a problem
   the cull already solves — marks are dropped before they reach the edge, so the ramp was
   dimming perfectly readable marks in the middle of the map for the sake of a boundary they
   never touch.
3. Now: nothing. `place()` takes no alpha parameter, and the `minimap_fade` option and its
   strings are gone.

What remains is the dark backing behind each mark, which is not fading — it is what keeps a
white chevron legible over pale terrain, and it is the same two-widget idiom the AR route's
chevrons use.

The cost is a mark popping rather than dissolving at the cull radius — worth watching, cheap
to put back if it reads badly.

### 6g. Closing the two gaps

The trail stopped short at both ends of the interesting bit, for two unrelated reasons.

**At the map's edge: the margin was the wrong shape.** It was a flat `0.86` of the radius,
which throws away 5.6 m on a 40 m map. But the reason to pull in from the rim is that a mark
is a *sprite with width* and one sitting exactly on the boundary reads as clipped — a reason
that scales with the **mark**, not with the map. It is now `0.75 × mark size`, converted to
metres through the measured y scale: half the sprite plus a little air, and nothing more.

**At the end of the trail: the walk stopped at the last whole step.** Marks are emitted every
`step_m`, so up to a full step of trail — 13 m at the defaults — went unmarked. There is now
always a **closing mark on the end**, skipped only when a mark was placed within 20% of a
step of it so the tail does not double into a blob.

**And a mark on the target.** The stroke stops at `draw_m`, so its last point is the
destination only when the route is short enough to reach it — a trail that peters out near
the objective without marking it makes the reader guess which of the last few marks meant
"here". `iqm_nav` now publishes the goal position (`status().gx/gz`) and the renderer appends
it as one extra vertex past the end of the stroke. The closing-mark rule then puts a mark on
it for free. If the stroke already ends there the extra vertex is a zero-length segment and
is dropped; if the target is off the map it is culled like anything else, never dragged onto
the rim.

### 6h. The reference was never the right question — measure off the actor

Everything from §6e onwards was spent widening the search for "an object near the player to
measure": the route target, then any carded NPC, then any online object. All three shared one
defect, and it is disqualifying for a navigation aid: **with nothing nearby, the trail never
calibrated and so never appeared.** Needing to already be next to something is the opposite
of what the feature is for.

The premise was wrong, and re-reading `CMapLocation::UpdateSpot` says why:

```cpp
m_position_on_map = map->ConvertRealToLocal(position, ...);
sp->SetWndPos(m_position_on_map);        // UNCONDITIONAL

Frect wnd_rect = sp->GetWndRect();
if (map->IsRectVisible(wnd_rect))
    map->AttachChild(sp);                 // only the ATTACH is gated
```

`SetWndPos` runs every update regardless of distance. What `IsRectVisible` gates is
`AttachChild`. So the "freeze" of §6e was never the engine refusing to move the spot — it was
this module reading `GetAbsoluteRect` on a spot that had been **detached from the map**, which
is a different failure wearing the same face. The spot's **map-local** position was correct
all along.

That makes the actor sufficient on its own, and nothing else necessary:

* **The centre** is the actor's spot read through `GetAbsoluteRect`. The actor is at the map
  centre by construction, so its spot is always inside the visible rect and always attached.
  No movement, no nearby object, and it is re-read every frame — so it now self-corrects
  through a HUD rescale instead of caching a stale centre.
* **The scale** is the same spot's `GetWndPos`, which never goes stale. Map-local space
  carries no rotation, so `|Δlocal| / |Δworld|` is a plain ratio of lengths — no trigonometry,
  no per-axis solve, no direction that has to be exercised, and no heading at which it fails.
  It needs `MOVE_SEP` = 4 m of walking in **any** direction.
* **The two axis scales** then differ from that local scale only by `UI_KX`, the aspect
  correction the engine applies when it rotates the map. That is display arithmetic, known
  exactly from the resolution, and is the one part of this computed rather than measured —
  which is consistent with §4, whose argument is about the map's rect and zoom varying by mod
  and load order. `UI_KX` does not.

`iqm_calib` now stays on the actor for as long as the trail is switched on, rather than being
added and removed around a solve, because it is the live centre and not a one-off probe.

`REF_MAX_D`, `AX_SEP`, the spot-type candidate list, the frozen-reference detector and
`iqm_core.nearest_reference` are all gone with the design that needed them.

### 6i. When the trail actually shows

Four conditions, and it is worth having them in one place because only one of them is
interesting:

| | |
|---|---|
| The option is on | `mark_targets` **and** `mark_minimap` |
| `iqm_nav` is publishing | there is a selected task with a target on this level, it is further than `VIS_NEAR` or out of sight, and the overlay is not suppressed |
| The target is further than `NEAR_HIDE` | 10 m — §6f |
| **The transform is calibrated** | 4 m of walking, in any direction, with nothing else required — §6h |

The last one used to be the one that surprised, because it also required a reference object
within 20 m and there frequently was none. Measuring off the actor removes that entirely: the
centre is known the moment the spot is placed, and the scale needs only 4 m of walking, which
happens within seconds of loading. The solved scale is still cached per level and resolution.

### 6j. Manual waypoints — the targeting was free, the navmesh was not

**Symptom.** A player-placed waypoint (Catspaw's *Personal Adjustable Waypoint*, which is
what "manual waypoint" means in GAMMA) got no trail and no ground route. The log says it
exactly, and it is the same three lines every time:

```
CRandomTask:give_task() task_id[task_placeable_waypoint]
[IQM-NAV] no route: an endpoint is off the navmesh          <- then every 5 s, forever
```

**Half of it was already working, and that half is worth writing down.** PAW does not
invent a marker type: it spawns a `script_zone` at the chosen spot and gives a real task,
`task_placeable_waypoint`, whose `waypoint_task_target_functor` sets `current_target` to
that object (`tasks_placeable_waypoints.script:1046`). And `GiveGameTaskToActor` calls
`SetActiveTask(t)` **unconditionally** (`GametaskManager.cpp:123`), so placing a waypoint
*selects* it. §6c's `active_task_target()` therefore picks it up with no special case, and
so does every consumer downstream. Following the selected task turns out to have bought
manual waypoints for nothing.

**What failed was the search.** `iqm_route.search_begin` refuses when either endpoint is
off the AI mesh, and a waypoint is off it far more often than a quest marker:

* **Placed on the PDA map.** The map is 2D — `ConvertLocalToReal` returns an `Fvector2` —
  so the y of the resulting object is whatever the exe chose for it.
* **Placed by aiming.** `get_target_spot` is a 100 m geometry ray, so the point sits on
  whatever was under the crosshair: a wall face, a rock, a rooftop, a tree.

Neither means unreachable, and the driver's response — back off for `FAIL_COOL` and retry
the identical doomed position — could only ever fail again.

**So the goal is snapped onto the mesh** (`mesh_goal` in `iqm_nav`). Two facts shape it:

* **Probe in XZ, never in Y.** `CLevelGraph::vertex_id` (`level_graph.cpp:226-247`) does a
  `lower_bound` on the **quantised xz cell** and returns `u32(-1)` when no node shares
  that cell; y only chooses among the nodes already in it. A wrong height cannot make a
  position invalid — it is always the xz that has no floor under it.
* **`level.get_nearby_vertices` is bound and is the wrong tool.** It answers this question
  exactly, and walks **every vertex on the level** to do it
  (`level_graph_vertex.cpp:581-594`). Rings of `vertex_id` probes, each a binary search,
  are cheaper by orders of magnitude.

The order is: the target's own **level vertex** first — for a map-placed waypoint that is
the honest half of a position whose height was invented, and `route_goal` now returns it
as a fourth value — then rings at 1.4 / 2.8 / 4.9 / 8.4 / 14 m, 8 directions on the near
two and 16 on the wider ones. Every direction on a ring is equidistant, so the first hit
wins and there is nothing to compare.

Three things that are easy to get wrong here, all pinned by the harness:

* **`goal` keeps the RAW target.** `GOAL_TOL` asks "has the thing I am routing to moved",
  and a snap is not movement. Storing the snapped point there is a repath on every tick,
  forever.
* **The answer is cached per target**, misses included — a waypoint does not move, and
  the miss is precisely the case that used to repeat every five seconds. `reset()` clears
  it, because which mesh lies under an id is a property of the level.
* **`level.vertex_position` returns a ZERO VECTOR for an id it dislikes**
  (`level_script.cpp:394-399`), so the vertex hint is re-tested rather than trusted. A
  stale id out of a save would otherwise route you to the corner of the level.

`IQM: Route Status` prints `snap=N.Nm aside`, or `snap=NO MESH NEAR IT` — which is now the
one remaining way a live objective ends up with no route at all.

Still true, and correct: **a waypoint on another level gets nothing.** `route_goal` returns
nil for it, because there is no navmesh path to another level to draw.

**The waypoint also carries a marker of its own** (`beacon_waypoint`, R2.33 in
`docs/ar-navigation.md`) — the same four-arc ring the map draws on it, through walls, at any
range. That one reads PAW directly rather than going through the selected task, because a
waypoint you placed is still standing there after you select a quest; the route, which can
only lead to one place at a time, follows the selection.

**The selected task now carries one too** (R2.46), wearing the full reticle
`iqm_mapspot_task` puts on the map. It reads `active_task_target()` — the same call this
section's route target starts from — but **not** `route_target()`, so it stops where the
selection stops and never inherits the nearest-turn-in fallback below. Two consequences worth
holding together:

* with **nothing selected** the two disagree on purpose: the route still draws to a nearest
  turn-in, which now carries no marker of its own;
* with a **waypoint placed** they are usually the same object, because placing one selects
  its own task (§6j). One mark is drawn for that and it is the task's.

### Debugging it in game

`IQM: Minimap State` (F7, Execute list) prints, in order: whether the option is on, whether
the actor carries the calibration spot, the last reason calibration did not proceed, whether
DXML declared `iqm_calib`, and — once solved — the centre, the local scale, both axis scales,
`UI_KX` for comparison, both cull bounds and the mark step. Between them those lines identify
which of the four conditions above is missing without any guesswork.

`IQM: Minimap Recalibrate` clears the transform so it re-solves.

The remaining open items are in §0's "What is left".

---

## 7. The probe — **DELETED at R2.44**

> `gamedata/scripts/iqm_mmprobe.script` did its job and is **gone**. Every question it existed
> to answer is answered (§8), the renderer measures its own transform and has its own `IQM:
> Minimap State` / `IQM: Minimap Recalibrate` actions, and nothing depended on the probe.
> Leaving it shipped meant four dead F7 actions and two **visible** map spots someone would
> eventually trip over — plus, found on the way out, an `AddDialogToRender` into a file
> `local` with no teardown, which orphans a rendering dialog on every save load (the R2.28
> bug). The rest of this section is kept in the past tense only so the logs quoted in §8 can
> still be read.

`gamedata/scripts/iqm_mmprobe.script` existed to answer §8's questions in game. It is a
**throwaway**.

It costs nothing when unused: no widgets are built and no per-frame work runs until the
overlay is switched on. Four actions, in the F7 launcher's **Execute** list (`inject("action",
...)`, not `"target"` — that one is Execute-on-target, and nothing here operates on the cursor
object through the launcher; `debug_calibrate` reads `level.get_target_obj()` itself, as the
other IQM actions always have):

| Action | What it does |
|---|---|
| `IQM: Minimap Probe Calibrate` | Aim at something 10–40 m away first. Puts a `green_location` spot on the actor and a `blue_location` spot on what you are aiming at, then reports whether each yields a `CUIStatic` and what the first solve says |
| `IQM: Minimap Probe Sample` | Re-measures and logs. Meant to be pressed repeatedly — F3b and F3c live in how the numbers *change* as you turn and walk, not in any single reading |
| `IQM: Minimap Probe Overlay` | Toggles five dots drawn from our own dialog-rendered window: red at the solved centre, green at 20 m north/east/south/west in WORLD space |
| `IQM: Minimap Probe Clear` | Removes the spots, hides the overlay |

Ordinary **visible** spot types on purpose. A probe you can see is a probe you can
sanity-check, and whether a fully transparent spot type still yields a widget is a separate
question that only matters once these are answered.

The overlay is the payoff: it uses the measured transform to place marks at fixed world
offsets, so if the transform is right they sit on the minimap, stay put on the ground as you
walk, and swing as you turn. Getting that picture answers F3d and validates §3 and §4 at once.

## 8. Open questions — **fill the answers in here**

**Run 1 — 2026-08-14, `k00_marsh`**, log `xray_sjwil.log:7248-7300`. Reference was
`sim_default_duty_232063` at 8.38 m, which was too close (§4.1) — so F3a, F3d and a first
reading of F3e came out of it, and F3b and F3c did not.

| # | Question | How | Answer |
|---|---|---|---|
| F3a | Does a spot produce a `CUIStatic` at all, and does a fully TRANSPARENT spot type still produce one? `CMapLocation::Load` builds `m_minimap_spot` from the spot XML (`map_location.cpp:179`), so it should — but "should" is not "does". **Go/no-go for the whole approach** | Calibrate; it logs `F3a … YES` with a rect, or `NO` | **YES** for a visible spot — `green_location` returned an 8.24 × 11 px static. The approach is go. **But the rect is not positioned on the frame the spot is added** (§4.2): it read as centred on the UI origin, and only on the next frame as `954.62, 675.91`. The transparent-spot half is still untested — the probe used visible types on purpose |
| F3b | Does `GetAbsoluteRect` report the position *after* the map's own heading rotation, or before it? The spot is `SetWndPos`'d in map-local coordinates (`map_location.cpp:396`) and the map is rotated as a whole, at draw time. **Decides whether the renderer applies the rotation itself** | Sample repeatedly while turning on the spot: does `map rotation` track `camera`? | **AFTER — the rect is post-rotation, and the map is heading-up.** Run 2 gives `rot = −camera` to within 0.05° and 0.02° at two headings 228° apart (**§8.1**). A cached transform re-applies `−atan2(cam.x, cam.z)` every frame and needs no reference object for the angle. Also settles that placement is **subpixel**, which corrected §4.1 |
| F3c | What happens to a spot whose object is off the minimap? `IsRectVisible` gates the update (`map_location.cpp:403`), so a distant reference may report a stale rect — which would mean keeping a reference on-map, or swapping between two | Sample while walking away from the reference; watch for frozen numbers | **ANSWERED — and the first answer recorded here was WRONG, which cost three rounds.** Observed: an off-map reference's measurement stops moving, so every solve comes out at a scale of zero (`rejected x solve: -0.01 px/m`, repeating). That was written up as "the engine stops repositioning the spot". It does not. `SetWndPos` is called **unconditionally**; only `AttachChild` is gated (`map_location.cpp:396-414`). So the spot's **map-local position is always current** and it is `GetAbsoluteRect` that breaks, because the widget has been detached from the map. The distinction is the whole feature: reading `GetWndPos` instead removes any need for the reference to be on the map, or near, or anything but present — see §6h. Lesson worth keeping: *"the measurement stopped changing" identifies a symptom, not a mechanism*, and the difference between them was three sessions of work |
| F3d | Does a dialog-rendered window really draw over the minimap in practice, not just in the source reading (§2)? | Overlay: are the dots visible ON the map? | **YES** — confirmed on screen. §2's draw-order reading holds: `AddDialogToRender` lands in `DoRenderDialogs`, step 6, after `UIMainIngameWnd`. No hook needed, and this was the other thing that could have killed the feature. **And the dots stayed ground-locked while turning and walking** — so §3's world→minimap similarity is right end to end, not just in the source reading. §6's renderer is now arithmetic on a validated transform |
| F3e | Is `minimap_zoom` ever set by a packed per-level `level.ltx`? It is in no loose config, so the default should hold and the map should span 100 m | Calibrate on several levels; compare the logged implied width | **Not yet measured — the scale readings so far are all corrupt.** Nine samples across two sessions on `k00_marsh` give `ppm` of 0.842, 0.891, 1.352, 1.551 and 3.053, spread over 3.6×, because every one of them carries a stale reference distance (§4.1). The two longest-range readings (0.842 at 16.3 m, 0.891 at 8.4 m) are the least corrupted and bracket a plausible ~0.85 px/m ≈ 85 UI units ≈ the 100 m default, but that is an inference, not a measurement. Fix `solve()` first, then re-read on two levels. **The centre, by contrast, is nailed down:** `954.62, 675.84`–`675.91` on every sample in both sessions |

### 8.1 The question F3b turned into — **ANSWERED: heading-up, and the rect is post-rotation**

The overlay held its dots on the ground through a full turn, which validated §3's transform
but could not distinguish heading-up from north-up: `Refresh` re-solves every frame and so
tracks either one. Run 2's logged angles settle it.

Across a turn spanning more than 200° of camera movement, two samples landed with the
reference on its calibration bearing, and both give the same result:

```
map rotation  53.86 deg   camera  -53.81 deg      sum  +0.05 deg
map rotation -174.28 deg   camera  174.26 deg      sum  -0.02 deg
```

`rot = −camera`, to a rounding error, at two headings 228° apart. So:

* **The minimap is heading-up.** `UIZoneMap.cpp:44`'s `rotate` default survives this install's
  five competing minimap layouts — the one thing §4 warned not to assume, now measured rather
  than assumed.
* **`GetAbsoluteRect` reports the spot position AFTER the map's rotation** — the original F3b,
  answered. A pre-rotation rect would have held `rot` constant while the camera swung through
  228°; instead `rot` tracked it exactly and inverted.
* **A cached transform must re-apply `device().cam_dir` every frame**, with the sign
  `rot = −cam_h` where `cam_h = atan2(cam.x, cam.z)`. That is the whole rotation term; no
  reference object is needed for it.
* **The measurement is subpixel**, which is the incidental finding that corrected §4.1. Two
  independent readings agreeing to 0.02° rules out integer-pixel placement.

For §5 this is the slightly worse of the two outcomes: minimap **arrows must be re-headed
every frame** by the camera, since a fixed world bearing rotates on a heading-up map. Dots are
unaffected. Cost is one `SetHeading` per mark, which the AR route already pays per chevron.

The two samples that *disagree* (`+28.27°`, `−7.15°`) are not counter-evidence — they are
§4.1's stale-reference bug, and their disagreement is what identified it.

### Run 3 — the test procedure  *(obsolete)*

> The probe this described is obsolete (§7) and the module it was meant to unblock is built
> and working. Kept only because §8's table quotes its logs. **Do not follow it.** To debug
> the live feature use `IQM: Minimap State`, described at the end of §6i.

---

## 9. Summary

**The feature works.** `iqm_minimap.script` draws the selected task's route as a trail of
marks on the HUD minimap, independently switchable from the AR ground route, calibrating
itself anywhere with no dependence on what happens to be standing nearby.

What the investigation established, in the order it matters:

* **A dialog-rendered window draws over the minimap** — `AddDialogToRender` lands in
  `DoRenderDialogs`, step 6 of `CUIGameCustom::Render`, after `UIMainIngameWnd`. No hook
  needed. Confirmed on screen.
* **Map spots cannot draw a route** — object-bound, one widget per object — but a spot is an
  excellent *instrument*: it tells you where the engine would put a known world position.
* **The transform is a 2D similarity**: centre on the actor, rotate by camera heading, scale
  by pixels per metre. No perspective, so none of the machinery the AR route needed.
* **The map is heading-up and the spot rect is post-rotation** — `rot = −camera` measured to
  0.02° at headings 228° apart (§8.1). Rotation is therefore free, from `cam_dir`.
* **Measure the map, do not compute it** (§4) — five mods ship a minimap layout, the file is
  chosen by aspect ratio so it has a *different winner per display*, and `CUIZoneMap::Init`
  then rescales it by display options. But `UI_KX` is display arithmetic and *is* computed;
  the rule is about what varies by mod, not about measurement for its own sake.
* **`SetWndPos` is unconditional; only `AttachChild` is gated** (`map_location.cpp:396-414`).
  This is the fact the whole design rests on: a spot's map-local position is always current,
  so the actor's own spot supplies centre and scale with nothing else present. Finding it late
  cost three rounds of building progressively wider searches for a nearby reference object.
* **Marks are resampled in world metres**, not one per published chevron, which makes spacing
  and culling rotation-independent by construction.

Three things this document got wrong along the way and later corrected — worth reading as a
set, because they share a shape: §4.1 (blamed pixel quantisation; it was a stale reference
position), §8's F3c (blamed the engine for freezing spots; it was reading the wrong accessor
on a detached widget), and §6f (twice gave the trail an alpha that belonged to the
first-person view). In each case a symptom was written down as a mechanism.

Remaining work is in §0's "What is left" — none of it blocks use.

---

## 10. Source references

Everything asserted above, in one place, so none of it has to be re-derived. Paths are relative
to `C:\Source\Gamma\xray-monolith-all-in-one-vs2022-wpo\src`.

| What | Where |
|---|---|
| Map spot Lua bindings | `xrGame/level_script.cpp:2456-2467` |
| `map_get_minimap_spot_static` | `xrGame/level_script.cpp:446` |
| `CUIWindow` Lua surface (`AttachChild`, `GetAbsoluteRect`, **`GetWndPos`**, `SetWndPos/Size`, no `GetParent`) | `xrGame/ui/UIWindow_script.cpp:164-203` |
| **`SetWndPos` unconditional, `AttachChild` gated on `IsRectVisible`** — the fact the design rests on | `xrGame/map_location.cpp:393-414` |
| The selected task (`ActiveTask`), and the border that marks it | `xrGame/map_location.cpp:376`, `xrGame/GametaskManager.cpp:239-257` |
| `is_active_task` / `set_active_task` Lua bindings | `xrGame/script_game_object_script3.cpp:225-226` |
| Guider spot types, placed on the task giver | `_unpacked/scripts/task_objects.script:322-326` |
| `scale="1"` rescales a spot with the LEVEL map only, never the minimap | `xrGame/map_spot.cpp:41-48`, `xrGame/ui/UIMap.cpp:396-423` |
| `CUIGameCustom` Lua surface, `get_hud` | `xrGame/UIGameCustom_script.cpp:18-40` |
| HUD draw order | `xrGame/UIGameCustom.cpp:84-110` |
| `AddDialogToRender` / `DoRenderDialogs` | `xrGame/UIDialogHolder.cpp:118-174` |
| Minimap init, rect rescaling, `rotate` flag | `xrGame/UIZoneMap.cpp:32-116` |
| Minimap heading per frame | `xrGame/UIZoneMap.cpp:147-190` |
| Minimap scale (`zoom_factor`, `BoundRect`) | `xrGame/UIZoneMap.cpp:206-228` |
| `CUIMiniMap` class, `Rotate()`, `IsRectVisible` | `xrGame/ui/UIMap.h:154-169`, `:69` |
| Spot placement into map-local coords | `xrGame/map_location.cpp:396-436` |
| Minimap spot construction | `xrGame/map_location.cpp:179` |
| UI xml name rewritten by aspect ratio (`_16` / `_21`) | `xrGame/ui_base.cpp:294-325` |
| `pGameIni` is `game.ltx` | `xrEngine/x_ray.cpp:224` |

And in this repo:

| What | Where |
|---|---|
| **The renderer** | `gamedata/scripts/iqm_minimap.script` |
| **Its tests** | `tools/minimap-harness/harness.lua` |
| **The calibration spot type** | `gamedata/configs/ui/iqm_map_spots.xml`, spliced by `modxml_n_iqm_map_icons.script` |
| Its config keys, and where it reads them | `gamedata/scripts/iqm_core.script` (`OPTIONS`, and the derived `DEFAULTS` / `PAGE_OF`); `iqm_minimap.apply_config`, which pulls them |
| Its menu | `gamedata/scripts/iqm_mcm.script`; strings in `gamedata/configs/text/{eng,rus}/st_mcm_iqm.xml`; tests in `tools/mcm-harness/harness.lua` |
| Its own drawn distance, and how one list serves both views | `iqm_nav.route_limit`, `iqm_core.route_draw_dist` |
| The probe | *deleted at R2.44 — was `gamedata/scripts/iqm_mmprobe.script`* |
| Route point list and its contract | `gamedata/scripts/iqm_nav.script:277`, `:574` |
| The card window, and how it reaches the HUD | `gamedata/scripts/iqm_core.script:3438-3444` |
| Widget definitions (`card_node`, `route_arrow`) | `gamedata/configs/ui/iqm_cards.xml` |
| Texture declarations | `gamedata/configs/ui/textures_descr/iqm_textures.xml` |
| The AR route's research log | `docs/ar-navigation.md` |
