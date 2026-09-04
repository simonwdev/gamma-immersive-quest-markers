# Plan — shaders in the overlay

**Phase 1 (§1-5)** replaces the route's geometry-ray occlusion with a per-pixel test
against the scene depth the engine has already computed. It is the one with a mechanism
proven end to end, and it is what establishes the shader as a normal part of the mod.

**Phase 2 (§6)** is everything else the same hook unlocks, ranked. Do not start it
before phase 1 is living in the game.

Read `docs/shader-spike.md` first — it holds the engine facts and the spike results
this plan stands on, and none of that needs re-deriving. This document is only the
work.

**Status: not started, either phase.** The spike passed on 2026-09-02 (all four modes)
and nothing in the mod has changed yet. The spike files are still in the tree and still
debug-only — §6.5 wants one more question asked of them before §3.6 removes them.

Related: `docs/ar-navigation.md` (F2, why the route is what it is), `docs/route-perf.md`
(what it costs today), `docs/decisions.md`.

---

## 1. What is already proven, in one paragraph

A UI element can be drawn through a custom shader by name — `InitTextureEx` from Lua
or `<texture shader="...">` from UI XML — and on DX10/11 the engine resolves that name
to a Lua script blender at `gamedata/shaders/r3/<name>.s`. A blender can bind the
deferred position target as `"$user$position"`, and the spike confirmed in a live
session that the target is **bound, populated, and pixel-exactly registered** during
the UI pass. Per-mark data reaches the shader through the texture rect's integer part,
verified exact. No `shader_param` slot is needed, which matters because GAMMA has none
free.

## 2. The design

**Per mark, in Lua:** compute the mark's view-space depth and put it in the integer
part of the texture rect's `x`; leave the vertex colour exactly as it is.

**Per pixel, in the shader:** sample `s_position.z` at this pixel, compare against the
carried depth, and scale alpha by the verdict.

```
occluded  =  scene_z > 0  &&  scene_z < mark_z - BIAS
alpha    *=  occluded ? DIM_MIN : 1        // DIM_MIN 0 when route_xray is off
```

The `scene_z > 0` guard is not optional — see §4.1.

Everything the ray path does today (the round-robin budget, the per-point eased alpha,
the snap-on-reveal handling) exists to hide the latency of an answer that arrived a
sweep late. A per-pixel answer has no latency, so all of it goes.

## 3. Work items, in order

Each is independently landable and independently revertible. Do not batch them: the
failure mode of a wrong shader is silent (`stub_default` substitutes and logs nothing),
so each step wants its own look at the screen.

### 3.1 — Depth into Lua, no shader yet

`place_mark` already receives `cd` (`iqm_cards.script:1242`), but `cd` is the
**euclidean** camera distance (`:1101`), not view-space Z. Those differ by the cosine
of the off-axis angle — up to ~20% at the screen edge on a wide FOV, which is far more
than any sensible bias. So compute the real thing:

```lua
mark_z = (p.x-cam.x)*dir.x + (p.y-cam.y)*dir.y + (p.z-cam.z)*dir.z
```

`device().cam_pos` and `device().cam_dir` are both already read in this path; hoist
them per frame, not per mark (`route-perf.md` finding 5 is exactly this lesson).

Note `world2ui_with_depth` is **not** a source for this: its third return is a sign,
`+1` or `-1`, not a distance (`level_script.cpp:1765`) — as `iqm_cards.script:663`
already records.

*Acceptance:* log `mark_z` for the nearest and furthest drawn mark and sanity-check
against the on-screen range readout. Nothing renders differently yet.

### 3.2 — The shader and the blender

Two new files, copied from the spike, which was written to be the template:

- `gamedata/shaders/r3/iqm_route.s` — the spike's `.s` with the ps name changed
- `gamedata/shaders/r3/iqm_route.ps` — the occlusion logic of §2, plus the HDR10 tail
  copied verbatim from `hud_default.ps`

Constraints, all from `shader-spike.md` §1 and non-negotiable: the `.s` sits directly
in `r3/` (the scan is `FS_RootOnly`), takes `v2p_TL` not `p_TL`, and samples with
`frac(I.Tex0)` because the integer part is now payload.

*Acceptance:* marks draw exactly as they do today with `mark_z` wired but the occlusion
term forced to 1. Any visual difference at this point is a bug in the port, not in the
idea, and is much easier to find now than after 3.3.

### 3.3 — Switch the occlusion over

Point the route marks at the new shader — `<texture shader="iqm_route">` on
`route_mark` in `gamedata/configs/ui/iqm_cards.xml` is the whole change, no Lua
(`UIXmlInit.cpp:974`). Then enable the occlusion term.

*Acceptance:* stand so a route runs behind a rock, a fence and a building corner.
The ribbon should dim with each object's real silhouette, and hold registration while
you strafe and turn. Compare against the ray build side by side if you still can.

### 3.4 — Delete the ray path

Once 3.3 holds up in a real session, remove from `iqm_nav.script`:

- `OCC_SWEEP_MS`, `OCC_MAX`, `OCC_TAU`, `OCC_LIFT`, `OCC_TOL` and the round-robin
  block at `:1390-1401`
- the per-point ease and its `occ_snap` first-frame-back special case (`:1412-1426`)
- `occ_owed`, `occ_i`, and `RD.t` throughout
- the `ray_ready(RAY_WARN)` gate at `:1951` that currently **disables the route
  outright** without `demonized_geometry_ray`

Keep `point_occluded` in `iqm_util` — the cards' LOS culling and the dead-end test at
`:1846` both still use it. This is a route change only.

Then: `demonized_geometry_ray` stops being a route dependency. Update the dependency
table in `README.md` accordingly — it currently says the route needs it.

`DIM_MIN` and the `route_xray` MCM option survive unchanged; they just become shader
inputs rather than Lua multipliers.

### 3.5 — Fallback for installs the shader cannot serve

DX9 reads `shaders/r2/` and will not find the blender. The miss is **silent** — the
engine substitutes `stub_default` and logs nothing — so this cannot be left to chance.

Decide between: ship an `r2/` blender, or detect the renderer at startup and keep the
existing ray path as the DX9 branch. Recommendation: **detect and fall back to
`hud\default` with occlusion simply off**, because keeping two occlusion
implementations alive to serve a configuration GAMMA does not ship is a bad trade, and
a DX9 user losing the dim-under-cover effect still has a working route.

Whatever is chosen, log it once at startup. A silent wrong-looking route is the
expensive outcome here.

### 3.6 — Remove the spike

Delete `gamedata/shaders/r3/iqm_depthspike.*` and
`gamedata/scripts/iqm_shaderspike.script`. They are debug scaffolding and were never
meant to ship. `docs/shader-spike.md` stays — it is the record.

**Before deleting, run the §6.5 probe.** It is one line in the `.s` and one mode in the
`.ps`, it answers whether phase 2's legibility work exists at all, and the spike is the
cheapest place it will ever be asked. Deleting first means rebuilding the harness to ask
a question that was free while it stood.

## 4. Known traps

### 4.1 Sky is `z = 0`, not `z = far`

Nothing writes the position target where there is no geometry, so every sky pixel
reads zero and a naive `scene_z < mark_z` treats it as an occluder at the camera. The
spike showed this plainly: sky fully masked, distant treetops in front of it correctly
not. **Guard `scene_z > 0` before anything else.** A route mark drawn against the
skyline would otherwise vanish for no visible reason — and on a ridge line that is
exactly where the route is most wanted.

Corollary: black in a depth view is ambiguous between "very near" and "nothing here".
Never key a heuristic on darkness alone.

### 4.2 The bias needs picking against real ground, not reasoning

The marks lie *on* the ground, so the scene depth under an unoccluded mark is the
ground it is painted on — the comparison is against itself and z-fighting is the
default state. `OCC_LIFT` (0.25 m) and `OCC_TOL` (0.30 m) are the ray path's answers to
the same problem and are the right starting numbers, but the shader's version is a
depth bias in metres along the view axis, not a lifted ray origin, so they will not
transfer exactly. Expect to tune this on a slope, which is the case that will break a
value tuned on flat ground.

### 4.3 Silent failure is the whole risk profile

Worth repeating because it is the difference between an hour and a day: a shader that
does not resolve, does not compile, or binds a name the blender never declared will
not raise, will not log, and will draw *something plausible*. Keep the spike's mode 0
trick in mind — when a change makes no visible difference, first prove the shader is
running at all.

### 4.4 The colour channels are full

All four are per-mark: alpha carries the distance and reveal fades, and RGB carries the
pulse (`iqm_cards.script:1136`), which phases per mark. Nothing can be borrowed from
the vertex colour, which is why depth goes in `Tex0`. Do not "just pack it in the blue
channel" later.

### 4.5 Keep the cell inside one integer span

The `Tex0` trick works because both `u` endpoints of a cell share an integer part, so
the clipper's interpolation cannot change it. A cell that straddled an integer boundary
would break silently at the screen edge. Our atlas cells are sub-rects, so this holds —
but it is a constraint on any future atlas change, not a property of the engine.

## 5. What this is not

- **Not a performance fix.** The route costs 0.42 ms of a 16.7 ms frame
  (`route-perf.md`); nobody reported a symptom. The wins are fidelity, one fewer
  dependency, and a large amount of latency-hiding machinery deleted.
- **Not a post-process pass.** We own our own quads, which is a much better position
  than recolouring someone else's geometry.
- **Not for the cards or the beacon, in phase 1.** They are through-wall by design
  (`ar-navigation.md` F1), and phase 1 stays route-only so that a regression has one
  possible cause. Phase 2 does touch the cards — see §6.

## 6. Phase 2 — the rest of what the hook unlocks

Nothing here starts before §3.4 is in and stable. Each item is independent of the
others; the order below is by value, not by dependency.

### 6.0 The constraint that decides what belongs here

**There is no readback.** A shader changes pixels; it cannot tell Lua anything. So
every *decision* stays in Lua no matter how good the shader gets — which NPCs get one
of the 8 card slots, whether the PDA chirps, marker priority, whether a card frees its
slot for someone you turned to face. Check any new idea against this first. It is what
rules out two otherwise obvious candidates in §6.6.

### 6.1 The chromatic split in interference — do this one first

`iqm_cards.script:561` states the problem in its own words: *"this is the one
interference effect that normally needs a compositing pass we do not have."* We have
one now.

Today the fringe is **one-sided**, borrowed from the black copy that text and the
leader line already draw. That costs two real compromises the comment records: the
effect only reaches elements that happen to have such a copy, and the soft drop shadows
have to stay black and stay on `P()` so they do not read as a cyan glow rather than a
fringe.

A pixel shader samples `s_base` at two offsets and produces a true two-sided split on
the ink itself, on every element, and hands the black copies back to being shadows. The
band tear — `P()`/`PS()` and the per-element `NZ.B` lookup every frame — becomes a
y-banded UV offset in the same shader.

This ranks first because it removes a documented workaround rather than adding a
feature, and because `iqm_noise`'s envelope/effect seam (one published number, read by
`iqm_cards`) already puts the amplitude exactly where a shader input wants to be.

*Carries:* the tear amplitude and fringe width are per-frame globals, not per-mark — but
there is still no `shader_param` slot, so they ride the same `Tex0` integer channel as
§2, or a second one in `Tex0.y`.

### 6.2 Waypoint markers, depth-aware instead of binary

They are through-wall by design and stay that way. But with depth per pixel they can do
what shooters actually do: the **occluded portion** of the glyph dims or hatches while
the visible part stays solid, so the marker reads its own distance instead of flipping
between two states. Same shader and same `Tex0` carry as the route; `iqm_arms` is the
file.

Small change, disproportionate effect on how placed-in-the-world the overlay reads.

### 6.3 Outline and keyline in one pass

The leader line draws a thicker black strip behind it, and every text draws a shadow
copy — roughly a doubling of widgets on a card for something a shader does per pixel.
The line and plate are straightforward (`CUIStatic`). **Text is not**: it goes through
`hud_font.ps` and is a separate job with its own risks; do not fold the two together.

This is hygiene, not frame time — same category as most of `route-perf.md`. Rank it
accordingly.

### 6.4 Route polish, once the route shader is stable

Work the route currently does per frame in Lua that is cheaper as pixel work and needs
no new plumbing: the flow animation as a UV scroll on time, the edge feather, and the
distance fade. Each is separate, small and revertible, and none of them is a reason to
do any of this.

### 6.5 Unproven, and one spike mode from an answer: the other render targets

`r2_types.h` names far more than depth — `$user$albedo`, `$user$normal`,
`$user$generic0`, `$user$bloom1`/`2`, and the auto-exposure luminance chain. If any of
the scene-colour ones are still readable at UI time, a card can **measure what is behind
it and adapt**: the plate darkening only over bright ground, the accent lifting against
a background it would otherwise disappear into. That answers a real problem the mod
currently answers with a constant (a fixed 180 alpha at `iqm_cards.script:1610`).

Whether they are valid during the UI pass is **not inferable** — exactly the position
`$user$position` was in before the spike. Finding out is one `dx10texture` line in
`iqm_depthspike.s` and one more mode in the `.ps`, so do it opportunistically the next
time the spike is wired up, before §3.6 deletes it. If the answer is no, this whole item
disappears and costs nothing.

Note `bloom1`/`2` is bright-pass filtered, so it is a glow source, not a usable blur —
do not plan a frosted-glass plate on it without looking first.

### 6.6 Considered and rejected

- **Card LOS culling.** Looks like the route's twin and is not. The ray answer decides
  whether the card gets one of the 8 slots — a Lua decision, and §6.0 means the shader
  cannot supply it. You would keep the ray *and* add a shader.
- **Distance fade and focus-mode falloff.** Already cheap in Lua, and moving them breaks
  the thing that makes focus mode work: an unfocused card gives up its slot. A shader can
  only make it invisible while it still holds one.

### 6.7 Parked: SDF marks

Route marks render at anything from 5 to 44 px. An analytically drawn chevron stays
crisp at every size and would retire the three texture variants and much of
`iqm_marks.dds`. A real quality win, but it is a rewrite of the mark artwork pipeline
rather than a shader swap. Leave it until the route shader has been in the game a while.
