# Route performance — the second pass, and the first one with numbers

A performance review of the ground-rendered pathing markers: the search that finds the
route, the driver that decides what to draw, and the two renderers that draw it. Held
2026-08-18, one day after the first pass landed in `ea3263b`.

The first pass reviewed `iqm_nav` and `iqm_minimap` by reading them. This one covers the
two layers that pass never touched — the A* in `iqm_route` and the sprite renderer in
`iqm_cards` — and then **measures** all four in a live session, which is the part that
had never been done. Several of the conclusions below contradict what reading alone had
concluded, including two in this document's own first draft.

Related: `docs/ar-navigation.md` (the research tracker the route was built out of),
`docs/minimap-route.md` (F3, the trail), `docs/decisions.md` (why each option is what it is).

---

## 0. State of play — read this first

**The route is not a frame-rate problem.** Measured, on a 60 fps budget of 16.7 ms, the
whole feature costs **0.42 ms of a visible frame** — around 2.5%. There is no stutter to
hunt and no emergency. What the review found instead is a body of waste that is real,
cheap to remove, and worth removing on its own terms: about 40% of the renderer's engine
calls compute values that are discarded or re-state values that did not change, and the
projection path generates roughly **600 KB/s of garbage**.

So read the findings as *headroom and hygiene*, not as a fix for a symptom. Nobody
reported a symptom.

**The one thing that was ranked wrongly by every reader, including this document's first
draft, is the search.** Reading said the A* and its tail were the biggest lever. Measured,
the steady-state cost of simply drawing the route outweighs everything search-related by
**about 20×**, because searches turn out to be rare (one per ~25 s) rather than
near-continuous. The search fixes are still correct; they are just not where the money is.

### The short version of what to do

| | | | |
|---|---|---|---|
| 1 | Delete the dead projection pass in `draw_route` | −41 projections/frame, −236 KB/s garbage | **DONE R2.50** |
| 2 | Stop re-stating `EnableHeading` / `Show` per mark per frame | −~16 engine calls/frame | **DONE R2.50** |
| 3 | Bind `world2ui_with_depth` once | one line, −12,600 hash lookups/s | **DONE R2.50** |
| 4 | Make the occlusion ray budget per-second, not per-frame | −58% rays at 144 fps, better fade at 30 | **DONE R2.61** |
| 5 | Hoist the frame-invariants out of the per-vertex and per-chevron loops | −~3,000 redundant calls/s | **DONE R2.61** |
| 6 | Defer the post-search tail by one frame | −3.9 ms from one frame per ~25 s | **DONE R2.61** |

Items 1–3 landed together, after `tools/route-render-harness` was built to make them provable
(§5). **Measured on the harness's fixture — 8 marks, 24 vertices, 16 chevrons:**

| | before | after |
|---|---|---|
| projections per visible frame | 64 | **32** |
| projections, route behind the camera | 32 | **0** |
| engine calls on a steady frame | 48 | **32** |
| allocation from projections | 6.1 KB/frame | **3.1 KB/frame** |

The mark snapshot — position, size, rotation and packed ARGB for all eight marks — is
**bit-identical before and after**, and the alpha mirrors in §4b/§4c/§4d pass unchanged, which
is what the harness existed to establish.

The colour cache (4.2's optional third part) was **deliberately not taken**: `SetTextureColor`
has a live input in the pulse, and caching it would need invalidation in three places for
~0.1 µs a mark.

**Items 4, 5 and 6 landed in R2.61** (§4.4, §4.5, §4.6), which closes the table. 4.4 retires the
largest single win in it: the ray budget is now spent per millisecond, so it is 360 rays/s at
every frame rate instead of 864 at 144 fps, and it falls further on the short routes that are
the common case. 4.5 is six hoists in `iqm_nav` worth ~3,000 redundant calls/s. 4.6 splits the
3.9 ms post-search frame in two and takes the string pull's own engine cost down by 5.75× on the
way, which changed what the right fix for the rest of it was — see the retraction there.

**§4.7 also landed, and is retracted as written** — the ~7 µs it reported was the profiler's own
wrapper overhead on a function that had been latched all along, and the unbounded park loop it
was reaching for turned out to be one level down in the beacon's glyph pool. It is the one item
here that came from the profile with no reading behind it, and it is the one that was wrong.

**All seven have now been exercised in game — see §8.** Five verify directly, including the two that
could fail loudly (4.6's deferral, caught in the act by a state combination only the new code can
produce, and 4.5's heading memo). **4.1 verifies too, by an unexpected route:** projections are the
only thing on this path that allocates, so the heap delta counts them — 64 a frame, every one
accounted for. **4.2 and 4.3 do not and cannot** from outside the module; their calls allocate
nothing and the callers are luabind userdata methods no wrapper can reach.

**And §8 changes the ranking at the top of this document.** Both remaining §7 questions are closed,
and the answer to the GC one is the largest number here: **garbage collection is ~43% of the route
renderer's true frame cost** — 116 µs of work against ~87 µs of collector charge for 6.000 KB/frame,
with a control proving the charge tracks allocation rather than elapsed time. So:

- **§4.1 was worth 75–130 µs/frame, not the ~16 µs credited** — the biggest fix in the table by a
  wide margin, and undersold twice.
- **A projection, not a ray, is the expensive primitive on this path** once collection is counted.
- **§4.10, new: `place_mark` spends four projections per mark**, and two of them exist only to
  measure thickness that an existing fallback already computes. That is the biggest thing left, it
  is a *look* decision rather than a perf one, and nothing in the original review saw it.
- `place_mark` costs **6.2 µs placing / 1.45 µs skipping**, so the profiler *over*stated it.

---

## 1. Method, and what it is worth

Two independent measurements, which is deliberate: they bracket the answer rather than
pretending to a single number.

**Bottom-up — engine primitives, timed directly.** `profile_timer()` around tight loops,
one fresh timer per measurement, an empty-loop baseline subtracted, and a warm-up pass
first so LuaJIT has compiled the loop. Allocation measured as a `collectgarbage("count")`
delta with the collector stopped across the interval.

**Top-down — CDEV Anomaly DevTools' Lua profiler**, wrapping 70 `iqm_*` functions across
59,571 frames of real play in `l05_bar`, with every IQM feature enabled.

### Three traps in this method, all of which bit — and two more the verification pass found

**`profile_timer():time()` accumulates.** It returns the total across every `start`/`stop`
pair on that timer, not the last interval. Benchmarking eight calls with one shared timer
produces eight monotonically rising numbers that look like a beautiful result and mean
nothing. One fresh timer per measurement, always.

Note the flip side, because §8 depends on it: accumulation is exactly what you want when the
thing being timed is *one* call repeated N times. One timer, every call, divide by N. The trap
is a shared timer across measurements, not a shared timer within one.

**`profile_timer():time()` returns MICROseconds.** Nothing says so, and reading it as
milliseconds makes a 6 µs function look like a 6 ms one. Confirmed against `os.clock()`:
6566.70 timer units across an interval `os.clock()` put at 6000 µs. §2's table is in µs and is
therefore right; the first `place_mark` figure taken in §8 was not, until this was pinned.

**`time_global()` cannot time anything inside a frame.** It is the *frame* clock, and it does
not advance within one — measured: it returned the same value either side of a twenty-million
iteration loop that `profile_timer` clocked at 15.9 ms. This matters because §7 proposed
"bracketing `place_mark` with `time_global()` deltas *without* the profiler running" as the way
to settle its cost. **That method cannot work.** `profile_timer` is the only sub-frame clock
here, with `os.clock()` as a millisecond-resolution cross-check.

**The profiler inflates what it measures, and by a knowable amount.** Two functions in the
profile are known to be near-free — `iqm_nav.route_draw` is three boolean reads and
`iqm_route.debug_active` is one flag read. They measure 1.43 µs and 1.61 µs. So **wrapper
overhead is ~1.5 µs per call**, and any small function called thousands of times per second
is inflated by that plus the loss of JIT trace compilation through the wrapper. Absolute
profiler values here are therefore **upper bounds**; call counts and rankings are exact.

**The profiler blinds `gamma_locals`.** While the wrappers are installed, walking a wrapped
module's upvalues returns DevTools' own state instead of the module's locals. Read a
script's real state before starting the profiler, or after stopping it — not during.

### And one engine footgun, recorded because it cost the session twice

`level.high_cover_in_direction` takes **(vertex_id, direction)** — see `iqm_route.script:340`.
Calling it with the arguments reversed passes a vertex id as a direction index into a baked
array. That is an engine-side assert: **`pcall` does not catch it, the game does not crash,
and the whole Lua call stack dies silently** — taking the DevKit bridge's handler with it.
The symptom is a listener stuck in `CloseWait` while the game runs on, perfectly healthy, at
normal CPU. Same family as the wallmark `R_ASSERT2` note: an engine fatal is not a Lua error.

The lesson generalises. **Do not bulk-benchmark engine primitives from `gamma_eval`.** Every
iteration runs inside one frame, so a misjudged cost stalls the game instead of returning a
bad number, and a mis-signatured call is unrecoverable. Measure at seams the shipping code
already proves correct, and let real frames do the driving.

---

## 2. What things cost

### Engine primitives (bottom-up, unwrapped)

| call | cost | allocates |
|---|---|---|
| `game.world2ui_with_depth` | **0.387 µs** | **96 B per call** |
| `_ray:query()` (via `iqm_util.point_occluded`) | **5.015 µs** | 0 |
| `SetWndPos` / `SetWndSize` | 0.136 / 0.135 µs | 0 |
| `Show(true)` | 0.113 µs | 0 |
| `SetTextureColor` | 0.099 µs | 0 |
| `EnableHeading` / `SetHeading` | 0.102 / 0.098 µs | 0 |
| `GetARGB` | 0.049 µs | 0 |
| `vector2:set` | 0.188 µs | 0 |

**A ray is 13× a projection and ~45× a widget call.** That ratio is the single most useful
number here, and it is why the ray budget (§4.4) outranks every widget-call finding despite
touching a twentieth as many calls.

**Re-priced by §8: what the renderer pays for a projection is ~0.95 µs, not 0.387.** The raw
engine call measures 0.53 µs when called through a closure (so 0.387 is credible as the bare
cost), and `project_off` — the wrapper every caller in `iqm_cards` actually goes through, with
its nil-safety, its first-use binding from 4.3 and its sign test — roughly doubles it. Four of
those are ~3.8 µs of `place_mark`'s measured 6.2, which is what finally makes its parts add up
to its whole.

**The consequence is that §4.1 was worth far more than it claimed.** It deleted 36 projections a
frame and was credited with ~16 µs. At the wrapped call cost that is already ~34 µs — and §8 then
measured what the *collector* charges for the garbage those projections make, which roughly doubles
it again. **Best estimate: 4.1 was worth 75–130 µs of a 60 fps frame, not 16.**

**Which makes a projection, not a ray, the expensive primitive on this path.** The ray/projection
ratio above (13×) compares call costs and is correct as far as it goes, but it omits that only one
of the two allocates. Priced with collection included, a projection costs roughly **0.95 µs of call
plus ~1.4 µs of eventual collector work**, and 64 of them a frame is a bigger line than the whole
occlusion ray budget. §4.4 is still the right fix; it was simply not the biggest one available.

**Projections allocate; nothing else does.** 96 B × ~105 projections/frame ≈ 10 KB/frame ≈
**600 KB/s at 60 fps.** This is the renderer's real cost, and it is invisible in wall-clock
timings. The Lua side of `iqm_cards` allocates nothing per frame — every scratch vector,
`vector2` and point table is hoisted and documented — so all of this garbage comes from
values the engine hands back.

### The frame (top-down, profiler; upper bounds)

| | per frame | note |
|---|---|---|
| `draw_route` incl. `place_mark` | **0.242 ms** | the renderer is the bigger half |
| `iqm_nav.update` | **0.175 ms** | |
| — of which `place_mark` | 0.100 ms | **~9 calls/frame**, hottest single function; §8 measures it directly at 6.2 µs placing / 1.45 µs skipping, so the profiler *over*stated it |
| `draw_beacon` | 0.054 ms | a different feature; not reviewed here |
| minimap `Refresh` | 0.019 ms | opt-in |

Bottom-up accounts for ~83 µs/frame of engine calls; top-down says ~420 µs. The difference
is Lua arithmetic the primitives never touched plus profiler distortion. **The truth is
between the two, and neither end changes any decision below.**

### The search

Ten searches (~9 live, ~1 from the F7 driver) over 15,103 frames / ~252 s.

| | |
|---|---|
| frames per search | **36.8** — the A* *is* already time-sliced |
| per stepping frame | **0.827 ms** |
| worst single step | **2.886 ms** — the `"done"` frame, which also carries `rebuild` + `string_pull` |
| the tail, same frame | **1.09 ms** — `smooth` 0.374 + `densify` 0.196 + `clearance` 0.477 |
| **worst frame, total** | **≈ 3.9 ms** |
| how often | **one search per ~25 s** |

### The ranking that follows, and the retraction

| | CPU per second of play |
|---|---|
| steady-state route (renderer + driver) | **~25 ms/s** |
| everything search-related | **~1.25 ms/s** |

**Retracted:** the first draft of this review, and every agent that read `iqm_route`, ranked
the search tail first on the strength of `ea3263b`'s note that "a moving target re-searches
near-continuously". Measured, it does not — one search per 25 s. The tail is a real 3.9 ms
single-frame spike and worth deferring, but the cross-search caching of `S.pos`/`S.cover`
proposed to fix it targets ~1.25 ms/s and is not worth its invalidation risk. **Dropped to
Tier 3.**

---

## 3. What `ea3029b`'s predecessor bought, now measured

`ea3263b` cached `iqm_core.route_goal` at 5 Hz with explicit invalidation. Measured:
**2,999 real task walks against 44,468 frames** — the `pairs` walk of `task_manager.task_info`
plus an `is_active_task` call per live task now runs 6.7% as often as it did. That fix is
doing exactly what it claimed, and this is the first evidence of it.

The `blanked` 4 Hz gate is also visible: `draw_route` runs on 51,718 of 59,571 frames, and
`route_goal` on 8,083 of the last 15,103 — the driver is returning early on a large fraction
of frames, as designed.

---

## 4. Findings

Ranked by measured cost × how often the path runs. Risk tags: **GREEN** safe,
**YELLOW** behaviour-affecting, **RED** needs judgement.

### 4.1 The renderer projects every vertex to compute one scalar it then throws away — GREEN/YELLOW

`iqm_cards.script:847-889`. `draw_route` projects every published route vertex through
`world2ui_with_depth` into `sx`/`sy`/`sd`, and then: **`sy[]` is never read anywhere in the
file**, `sx[]` is only nil-tested, and `sd[]` feeds one value — `d0`, the camera distance of
the nearest vertex in front of the camera. The stroke that used to consume these arrays no
longer exists; `local ns, na = 0, 0` at `:900` is dead and no `place_seg` exists in the tree.
`clip_front` (`:693`), which recovers the near-plane vertex and fires "on nearly every frame"
by its own comment, exists only to serve this.

**Two more dead writes, confirmed by mutation-testing the new harness.** Every read of the
scratch arrays is at `:851`, `:853`, `:869`, `:872`, `:877`, `:888`, and the highest index any
of them touches is `sx[n]` / `sd[n]` (the `i + 1` reads run to `i = n - 1`). So:

- **`sx[n + 1] = nil` at `:862` is written and never read.** Deleting it changes nothing and
  breaks no assertion. It guarded the stroke's neighbour lookup, which is gone.
- **`sy[]` is written twice (`:851`, `:872`) and read nowhere**, as above.

Both go with the pass. The `:862` comment still explains a stale-neighbour bug that the code
can no longer have.

**Cost:** ~25–41 projections/frame = ~1,500–2,500/s ≈ 16 µs/frame and **~236 KB/s of garbage**,
for one scalar.

**Fix:** `d0` needs only "is this vertex in front, and how far". A dot product against
`device().cam_dir` gives both. Delete the projection loop, `clip_front`, the `sx[n+1] = nil`
guard, `RTE.sx/sy/sd`, and `ns`/`na`.

**Risk:** the dot product tests the plane through `cam_pos`; the projection tests the true
near plane. Centimetres apart, against a 1.5 m fade ramp — under 1% of one mark's alpha.
Bonus: with the route behind the camera this path becomes free instead of costing 36 engine
calls.

### 4.2 Per-mark values re-stated to the engine every frame — GREEN, mostly

Three instances, ~960 engine calls/s each at the default 16 chevrons:

- `:1168` — `EnableHeading(true)` per mark per frame. A sticky flag. This is the *same call*
  `ea3263b` moved into `ensure()` for the minimap trail; the renderer's copy was missed.
  Set it in `InitControls`' pool loop and again after `InitTexture` in the variant re-point
  branch (which fires ~1/s per slot, not 60).
- `:1171` — `Show(true)` on slots `1..nm`, which are dense and stable frame to frame. Move it
  to `draw_route`'s tail as `for i = prev+1, nm do ... Show(true) end`, mirroring the existing
  hide loop. Both loops are empty when `nm == prev`.
- `:1170` — `SetTextureColor(GetARGB(...))`, two calls, bit-identical every frame with
  `route_pulse = 0` at rest. **YELLOW and lowest value of the three** — it is the only fix
  here that adds state, needing invalidation in `hide_route`, `apply_shape` and `apply_config`.
  Do it last or not at all.

The minimap has the same shape at `iqm_minimap.script:560/563/581/587/582/588` — size, colour
and visibility re-sent to marks that were already placed. Guard with `i > self.shown_n`, and
extend `set_config`'s existing pool dump to size and colour changes.

Note what is **not** wrong: the route pools already bound their park loops by `rg_used`, so
the `hide_from` high-water bug `ea3263b` fixed in the minimap genuinely does not exist here.

### 4.3 `game.world2ui_with_depth` resolved through two hash lookups per projection — GREEN

`iqm_cards.script:491`, in `project_off` — the hottest line in the renderer, and shared with
`iqm_beacon`'s markers via `project_offscreen`. ~210 lookups/frame, **12,600/s**.

**Fix:** `local world2ui = game.world2ui_with_depth` at file scope beside the existing
`local GetARGB, time_global`. `game` is an engine namespace present at load, so binding it
eagerly is safe. One local; `iqm_cards` is at 35/198. **The cheapest fix in the review.**

### 4.4 The occlusion ray budget was per frame, so it scaled with FPS — YELLOW, **DONE R2.61**

`iqm_nav.script`, constant block at `:512`. `occ_step` fired `OCC_RATE = 6` rays every frame,
so the sweep *period* was measured in frames and the ray *rate* rose with frame rate:

| FPS | rays/s | full 36-bead sweep | vs `OCC_TAU = 90 ms` |
|---|---|---|---|
| 30 | 180 | 400 ms | fade visibly lags |
| 60 | 360 | 100 ms | as intended |
| 144 | **864** | 42 ms | 2.4× the cost for latency nobody can see |

At 5.015 µs a ray this was ~30 µs/frame — **the largest single per-frame engine cost in the
driver**, larger than all ~112 of the renderer's widget calls combined.

**What shipped.** The budget is now `occ_owed = occ_owed + n * dt / OCC_SWEEP_MS` with
`OCC_SWEEP_MS = 100`, a fractional accumulator, and a per-frame cap of `OCC_MAX = 12`. The
quantity held fixed is the **sweep period**, which is the one `OCC_TAU` is tuned against; the
rate falls out of it. 360 rays/s at every frame rate — −58% at 144 fps, and at 30 fps the
sweep comes back to 100 ms instead of 400, so the fade stops lagging.

**A second saving the review had not counted.** Because the budget scales with `n`, short
routes get cheaper too. The old code cast `min(6, n)` rays regardless, so an eight-bead route
was swept in 1.3 frames — six rays' worth of work where 1.3 would do, refreshing verdicts
about 4× faster than `OCC_TAU` can render them. Routes are capped by `draw_m`, so `n` is
below 36 most of the time and this is the common case, not the corner.

**Which also means "identical at 60 fps by construction" was only true at `n = 36`,** and this
document said it without that qualifier. At any smaller bead count the new budget is
deliberately lower. The behaviour that changes is how often an occlusion verdict is
*refreshed* on a short route; what the player sees is governed by the ease, and the sweep is
now matched to it rather than running four times ahead of it.

**The cap discards, it does not bank.** `update()` already floors `dt` to 16 past 500 ms, but
500 ms still *earns* five whole sweeps. Paying that off over the frames after a hitch would
charge the cost of the hitch to the recovery, so the whole earned amount comes off the
accumulator before the cap is applied and the excess is dropped. The verdicts are stale
either way and the ease covers it.

**Coverage:** eight assertions in `tools/nav-harness`, all mutation-proved. The load-bearing
one drives 24 frames at `dt = 16` and 48 at `dt = 8` — the same 384 ms — and asserts the ray
totals are *equal*; against the old code they are 144 and 288.

**Mutation-proving found two holes in the first draft of this fix**, which is the whole reason
for doing it:

1. **`occ_owed = 0` inside the clamp was dead code.** The full earned amount was already
   subtracted a line earlier, so the assignment could not change anything, and a mutation that
   switched the code to *bank* the debt passed every assertion. Removing the redundant
   assignment and reordering so the deduction is visibly the thing that drops the debt made the
   mutation fail as it should.
2. **The sweep-period assertion was vacuous.** It computed its expectation from
   `OCC_SWEEP_MS`, read out of the module — so doubling the constant changed both sides of the
   comparison and went straight through. It is now pinned to the literal `100`, with the
   tuning reason recorded beside it. An expectation derived from the value it is checking
   tests nothing; this is the second time that shape has appeared in this review.

### 4.5 Frame-invariant work inside per-vertex and per-chevron loops — GREEN, **DONE R2.61**

All in `iqm_nav`. Six changes, ~3,000 redundant calls/s between them, and every one behaviour-
preserving by construction — which is the whole difficulty: **not one of them is visible to a
behavioural assertion.** The coverage had to be built out of call counters and a poisoned cache.

- **`stub_at` became `stub_frame`.** It was asked once *per vertex* from two loops in `occ_step`
  — 36 × 60/s = 2,160 calls a second — and none of its four early exits or two arclengths depend
  on `i`. On a partial route (the normal outcome) each call ran the full body including a `#` on
  a path of hundreds of 1 m samples. Only `RD.s[i]` was ever per-vertex, so the verdict is taken
  once a frame and the loops do the one subtraction themselves.
- **`heading_at` is memoised** by path index into two arrays, with `false` for "computed, and
  there is no heading here". A chevron only crosses a 1 m leg about twice a second, so ~95% of
  the ≤16 calls a frame were re-deriving last frame's answer by walking `path_s` out
  `CHEV_DIR_M` in each direction. **The YELLOW one, and the only cache in 4.5.**
- **`lead_apply` finds the ramp's cut once** instead of asking `lead_w` per vertex. `LEAD_M` is
  8 m against a route drawn to `draw_m` and `RD.s` is monotonic, so most vertices called it only
  to be told zero. Measured on the harness fixture: 30/frame down to 6 standing on the line, 14
  with a live 1.5 m offset. The *stores* still run for every vertex — skipping those needs a
  high-water index whose failure mode is one vertex stranded at last frame's offset.
- **`on_leg` is a file-scope function** taking the actor's x and z as floats. `actor_arclen`
  defined it as a closure inside itself: one allocation per frame of a route, for a function
  whose only per-frame input is two numbers.
- **The duplicate fetches are threaded down.** `device().cam_pos` was read by `build_draw_list`
  *and* `occ_step`; `db.actor:position()` by `actor_arclen` *and* `lead_apply`, back to back, on
  top of `update`'s own; `time_global()` by `flow_advance` after `update` had already been handed
  the clock it was called with. The camera is now read in `draw_tick` — deliberately there and
  not in `update`, so the blanked path, which skips `draw_tick` entirely, does not start paying
  for a value it never uses.
- **The alpha ease snaps** inside half an 8-bit alpha step. It is exponential, so it approached
  its target and never arrived: a route settled for a minute was still multiply-adding every
  vertex every frame for differences the packed ARGB cannot represent.

**Coverage: 17 new assertions in `tools/nav-harness`, and all 16 mutations against them fail.**
The interesting ones are the ones that had to be invented rather than written:

- **Counted stubs.** `ENV.device`, `db.actor.position` and `ENV.time_global` now count their
  calls, pinned over a 20-frame window rather than a single frame because `refresh_visibility` is
  throttled to `VIS_RATE` and lands on some frames and not others. 25 device() calls where it was
  45; 40 position() where it was 60; 0 time_global() where it was 20.
- **A swapped-in counting wrapper for `lead_w`**, reached through `lead_apply`'s upvalues, because
  disabling the cut is behaviour-preserving and nothing that looks at the drawn route can tell
  whether it is there. The counts are *pinned*, not bounded — "fewer than all of them" also passes
  a cut set one metre short, which silently drops the outer end of the ramp. Both the short and
  long mutations now fail (13.0 and 15.0 against 14.0).
- **A poisoned memo.** Counting calls to `heading_at` cannot see whether the memo works — the memo
  lives *inside* it, so the call count is identical either way, and the first draft of that
  assertion measured exactly nothing. What settles it is filling every entry with a heading
  pointing along +z and asserting the chevrons of a route that runs along +x follow it.
- **Convergence time pins the snap window.** Landing exactly on the target is the easy half; a
  window wide enough to be *seen* would pass that just as happily. A full 1 → 0 fade takes 13
  frames of 50 ms through the ease and 5 with a 100× wider window.

**And three things this pass got wrong first, all found by mutation-proving:**

1. **`debug.setupvalue` does not invalidate LuaJIT's compiled traces.** The `lead_w` wrapper
   installed cleanly, `debug.getupvalue` read it back, the route was still offset correctly — and
   the counter read **zero**, because the hot trace through `lead_apply` had specialised the call
   to the real function. The assertion passed at zero. Anything that swaps a *called function*
   through an upvalue mid-run has to `jit.flush()`, or it measures the interpreter while the code
   runs the trace.
2. **Two of the memo's three invalidation sites were dead.** `stop()` and the search's failure
   path assign `path = nil`, and a nil path cannot produce a wrong heading — `place_chevrons`
   returns on `not (path and path_s)` before `heading_at` is reached, and the next real path clears
   the memo on its way in. Deleting either clear left the whole suite green. Same shape as 4.4's
   dead `occ_owed = 0`; both are gone, and the install site is the single point of truth.
3. **The fixture could not see a two-axis projection.** Every route in `nav-harness` ran along
   +x, so a leg's `dz` is zero and deleting the z half of `on_leg`'s dot product passed all 264
   assertions. There is now a 45° route — and the first version of *that* put the actor at 8 m,
   which on a path densified at `PATH_STEP` lands exactly on a path point, where both residuals
   are zero and the mutation still passed. Half a metre further on it fails by 0.255 m.

### 4.6 The post-search tail landed entirely in one frame — YELLOW, **DONE R2.61**

The frame where `search_step` returned `"done"` paid its own expansions **plus** `rebuild` plus
`string_pull` (2.886 ms measured) and then `iqm_nav` ran `smooth` ×3, `densify`, `clearance`
and `snap_path` (1.09 ms) before that same frame ended. **≈3.9 ms**, once per ~25 s — the worst
single frame the feature has.

**What shipped, in two halves.**

**The two `string_pull` hoists first**, because they were free and they changed the shape of the
rest of the fix. `level.vertex_id(a)` was asked once per *candidate* inside the reach-ahead
though `a` is the span's origin and the same node for all of them; and the cover mean
re-derived `level.vertex_id(path[q])` for every interior node of every candidate, so its cost
grew with the square of the reach. Prefix sums of node cover, built in one linear pass, make
the mean O(1) per span. **Measured on `route-harness`'s hard 50-node route: 575
`level.vertex_id` calls for the pull, down to 100** — and the route that comes out is the same
four points.

The prefix carries a parallel valid **count** and not just a sum, because a node whose vid
comes back invalid is excluded from both. Dividing by the span's length instead would pull the
mean down at exactly the ragged patches of mesh where the exclusion happens, and a mean pulled
down is a pull wrongly allowed — the failure R2.23 exists to stop.

**Then the deferral.** `step_search` stashes the raw node list and hands back "still
searching", which is the truth: there is no route to draw until the tail has run. The tail runs
on the next frame. The whole of the resumption state is that list, because the tail is a pure
function of it — no cursor, no half-finished pass, nothing to restart mid-way, which is what
makes this the cheap version of slicing rather than the expensive one. One frame while the
route is on screen; up to one `HIDE_MS` slot while it is blanked, where nothing is drawn and
`update` is stepping the search at 4 Hz anyway.

**And a retraction of this section's own proposal.** It said to move `string_pull` out of the
finishing frame too. That was right when it was written and is not now: with the pull 5.75×
cheaper in the call it spends its budget on, the two halves are already about even, and moving
the pull as well would need a resumption state inside `iqm_route` to buy nothing. The order the
two halves landed in changed which fix was correct — worth remembering the next time a review
lists its items as independent.

**Three things the split has to get right.**

1. **The partial flags are read on the finding frame.** There is one search state in
   `iqm_route`, and anything that began another search between the two frames would have
   replaced `search_partial()` and `search_closest()`. The raw list itself is safe because the
   driver holds the array.
2. **They are written through to `partial`/`short_by` only when the tail runs.** For that one
   frame the *old* route is still the one on screen, and it must not wear the new route's
   dead-end fade.
3. **The raw list must not outlive the search that produced it.** `abort_search` drops it with
   `searching`, because a list that survived a teardown would be claimed by the *next* search's
   first frame — publishing the previous target's route and then stopping the live search,
   since claiming the list is what ends `searching`. Loud in game and invisible to every
   assertion that starts from a settled route.

**Coverage: 12 new assertions across `tools/route-harness` (4) and `tools/nav-harness` (8), 15
of 18 mutations caught.** Both halves were invisible to the suites as they stood, and for
opposite reasons.

- **The hoists are behaviour-preserving, so nothing behavioural can see them.** `level.vertex_id`
  is now counted alongside the probes — it is the only call they are visible in — and the pull's
  own cost is isolated as the *difference* between the same search with `pull` off and on, since
  `pull` is only consulted once the search has already finished. Pinned to the literal 100 and
  not derived from the node count, for the third time in this review.
- **Two of the mean's mutations needed a fixture that did not exist.** On an honest graph every
  node of a rebuilt path has a vid, so dividing the cover sum by the valid count and by the
  span's length are the same number, and sliding the window to include the chord's far end
  shifts the mean by too little to change a decision. Both passed all 74 assertions.
  `vid_blind` fixes it: one cell `level.vertex_id` refuses to name while the graph walks it
  perfectly well — a recorded quirk of this build rather than a contrivance. With it, both
  mutations produce a visibly different node list.
- **The deferral needed the frames driven one at a time.** `settle()` ticks until there is
  something to draw, and one frame later is still settled, so **all 271 existing `nav-harness`
  assertions passed the deferral unchanged.** The new ones name the frame each half lands on:
  the finding frame runs none of `smooth`/`densify`/`clearance` and publishes nothing while
  reporting `searching`; the next frame runs each exactly once and the route is up. All three
  passes are counted, not just `clearance` — a split that moved only the last of them would
  leave most of the 1.09 ms where it was.
- **`to_done()` waits for a search that has begun *and* finished.** `RT.state` stays `"done"`
  after a search completes, so waiting on that alone returns instantly on the second call and
  the frame-by-frame pins would be reading a settled route. The first draft did exactly that,
  and it is the same failure shape as an expectation derived from the value it checks.

**Three mutations that could not be caught, so the cover is not overstated:**

1. **Dropping the span origin's validity guard changes nothing.** The loop body breaks on its
   first candidate anyway, because `vertex_in_direction` off an invalid vid returns invalid.
   That is the *stub's* behaviour; the guard stays, because handing `INVALID_VID` to an engine
   navmesh call is the shape that has silently killed the Lua stack twice in this feature and
   the pre-hoist code never did it.
2. **Claiming the pending list after stepping the search instead of before** costs one no-op
   `search_step` call and is otherwise identical. A non-bug.
3. **Writing the partial flags through a frame early** is invisible: on the fixture the drawn
   tail's alpha is dominated by occlusion, and the worst the mistake does in game is one frame
   of slightly wrong fade on a route that is about to be replaced.

### 4.7 An unbounded park loop, one level down from where this looked — GREEN, **DONE R2.61**

**Retracted as written.** This said `hide_slot` runs ~6×/frame because "the card layer parks
unused slots unconditionally — the same shape `ea3263b` fixed in the minimap's `hide_from`", for
~7 µs/frame. Two things wrong with that, both of which a single read of the function would have
settled:

- **`hide_slot` has latched on `s.hidden` since long before this review.** Its own comment says
  so, and `iqm_core:2521` calls these "the same latched no-ops". The 355,974 calls are real; each
  one is a method dispatch, three table reads and a return.
- **The ~7 µs is the measurement, not the cost.** §1 establishes ~1.5 µs of profiler wrapper per
  call from two known-free functions. Six latched calls a frame × 1.5 µs *is* 7 µs. **There was
  nothing to recover** — the item was an artefact of the instrument, and it is the one finding in
  this review that came from the profile alone with no reading behind it.

**What was actually there,** found by reading every `Show(false)` in the file rather than by
following the profile: a beacon's range readout is four glyph widgets, and **two loops parked all
four every frame regardless of how many had ever been shown** — the tail of the layout
(`iqm_cards:1679`), and the early return taken when the readout is switched off (`:1653`), which
is per drawn beacon per frame in that configuration. That is the `hide_from` shape the finding
named, at the wrong address.

Both now carry a high-water mark, in the same form as the route marks' park loop three hundred
lines above that already does it (`:1157`, bounded by `prev`) and as `draw_beacons`' own `bhigh`
one level up. A steady beacon re-parks nothing; a readout dropping from 100 m to 99 m parks
exactly the one glyph it dropped. Worth ~1 µs/frame — genuinely hygiene, which is what the item
always claimed to be.

The mark is seeded at `MAX_RGLYPH` and not 0, so the init-time `hide_beacon` still walks the
whole pool: `InitStatic` hands back a **visible** widget, which is the only reason the init-time
hide calls at `:769`, `:819` and `:851` exist at all. Seeded at 0, four glyphs sit on the HUD
from the moment the dialog is built.

**Coverage: 11 assertions in `tools/route-render-harness`, 8 mutations, 8 caught.** Nothing
anywhere drove a beacon or a card slot through this harness, so the latch that *did* exist and
the bound that did not were both uncovered — the retraction above was only provable because the
first of those got an assertion. Counted per widget rather than off the global `Show(false)`
total: the badge's own if/else branches park six more, and a total including those would move
whenever the layout did.

**Two fixture changes worth more than the assertions they support:**

1. **`new_widget` now starts `shown = true`,** which is what the engine does. A stub that starts
   hidden certifies every init-time hide call in this file as unnecessary — and it is exactly
   what would have let the seed-at-zero mistake through. Same family as §5's startup-ordering
   case: the fixture was modelling the steady state and quietly disagreeing with the engine
   about the first frame.
2. **`hide_beacon` zeroing the mark was uncatchable on the first draft.** Leaving it stale only
   wastes a few `Show(false)` on the frame a beacon returns with a shorter readout, so no
   behavioural assertion moved. It is covered now by showing a beacon, hiding it, and showing it
   again with the readout *off* — the one frame that reads the mark `hide_beacon` left behind.

### 4.8 There is no distance LOD anywhere — noted, not recommended

A route vertex 200 m out gets the same ray, the same ease, the same four projections and the
same six widget calls as one under the player's nose, where its sprite is a few pixels wide.
`RD.n` is driven by `seg_allow`'s angular spacing and `MAX_CHEV`, never by range. This is the
largest remaining structural lever if the numbers above ever stop being acceptable — but
culling sub-pixel marks is a *look* decision, so it belongs to whoever owns the look, not to a
perf pass.

### 4.9 And no frustum pre-cull either — found in §8, not recommended for the same reason

Discovered while measuring `place_mark`: with the player facing away from the route, **16 of 16
chevrons took its early-return path.** Each one costs the first projection (~0.95 µs) purely to
discover that the mark is behind the camera and will not be drawn — ~15 µs/frame spent finding
out there is nothing to draw, and it is the *common* case, because a route is something you
glance at rather than stare down.

A cheap dot product against `cam_dir` before the first projection would answer it for a fraction
of the cost, and 4.1 already established that a dot product is an adequate substitute for a
projection when the question is only "is this in front". Unlike 4.1 this one changes nothing that
is drawn, so it is not a look decision — but it *is* the same family as 4.8: a cull that needs a
number chosen against how the route reads at the screen edge, where a mark half-clipped by the
frustum plane is a different case from one behind the camera.

**Priced by §8, and it is modest.** A skipping chevron costs exactly one projection (96 B measured),
so a fully-averted route spends 16 projections rather than the 64 it spends when faced — the case
this would optimise is already the cheap one. Worth ~15 µs of calls and ~20 µs of collector work at
16 chevrons. Real, but a fifth of what **§4.10** is worth, and 4.10 is where a next pass should
start.

### 4.10 `place_mark` spends four projections per mark — the biggest item left — RED, a look decision

**Full statement and numbers in §8**, where it was found; recorded here so §4 remains the complete
list of findings. In short: once collection is priced, the route render's 64 projections a frame are
the feature's dominant cost, two of `place_mark`'s four exist only to measure on-screen thickness,
and `seg_width` already computes thickness without them. Halving them is a matter of taking an
existing fallback — but that pair also feeds R2.28's angle mean, so it changes how every mark on
screen is *drawn*, which puts it with §4.8 and §4.9 rather than in a perf pass.

---

## 5. The coverage that had to exist first — now `tools/route-render-harness`

**`iqm_cards` had no frame-level test coverage at all, and it holds three of the top four
fixes.** No harness drew a frame through `IqmCards`: `marks-harness` loads the module but only
touches `RTE` and `shape_box`; slot, waypoint and name read it as source text. `ea3263b`'s own
message records that the R2.45 split "shipped three bugs it could not see" for exactly this
reason, and every fix in that commit lived on the same uncovered path. Findings 4.1, 4.2 and
4.3 were all in that position.

`tools/route-render-harness/harness.lua` closes it: **73 assertions**, drawing real frames
through the real project → fade → `place_mark` path against a pinhole-camera fixture, with the
whole widget surface counted. It needs no `iqm_core` — `RTE`'s load-time defaults carry
everything except `RTE.shape`, which arrives through a stubbed `iqm_core.config()` so
`apply_config` runs for real.

The findings above are written into it **as numbers that must change**:

| assertion | today | after the fix |
|---|---|---|
| projections per frame | 64 (32 real + 32 dead) | 32 |
| projections for a route behind the camera | 36 | 0 |
| `EnableHeading` on frame 2 | 8 | 0 |
| `Show(true)` on frame 2 | 8 | 0 |
| `SetTextureColor` on frame 2 | 8 | 0 (if 4.2's third part is taken) |

A fix that leaves those expectations untouched did not do anything, which is the point. **All
five moved when 4.1–4.3 landed**, and the harness's current expectations are the post-fix
numbers with the pre-fix ones recorded beside them in the assertion details.

### 4.3 took three goes, and the middle one shipped a crash

Worth the space, because the harness caught the first mistake and **missed the second entirely.**

**Attempt 1 — eager, at file scope.** `local world2ui = game.world2ui_with_depth`.
`marks-harness` failed instantly: its env is deliberately the thinnest thing that lets
`iqm_cards` load, and it has no `game`. Not a fixture problem — a grep of base Anomaly's whole
script tree finds **not one** file-scope binding of a `game.*` member, and the cost of being
wrong is the worst failure this file has: indexing a nil `game` at load is a parse failure that
takes the cards, the beacons, the route and the readout down together.

**Attempt 2 — assigned in `apply_config`. This shipped, and it crashed.**

```
iqm_cards.script:503: attempt to call upvalue 'world2ui' (a nil value)   ... from draw_beacons
```

The reasoning was that `iqm_core` calls `apply_config` at the end of `read_config`
(`iqm_core:963`), inside `on_game_start`, before `actor_on_update` is even registered — so
nothing could draw first. **On a fresh start that is true.** On a save load it is not: loading a
save re-reads the `.script` files, the upvalue is nil again in the fresh chunk, and on that path
a marker is drawn before `apply_config` runs. The exact mechanism is still unestablished and
wants one load with a probe at the binding site.

**Attempt 3 — bind on first use inside `project_off`.** One branch on an already-hot function,
the whole saving kept, and no lifecycle assumption at all: it cannot be wrong about when the
engine is ready because it asks. Nil-safe in both directions — an unbound call with no engine
returns nil, which every caller already treats as "did not project", and the binding is retried
rather than poisoned.

**What this says about the harness, which is the part worth keeping.** Twenty harnesses and
1,568 assertions passed attempt 2. `marks-harness` proves this module **loads**; nothing
anywhere proved a drawing function could be **called before configuration**, which is the entire
failure. The suite tested the steady state exhaustively and the *startup ordering* not at all.
There is now a case at the top of `route-render-harness` that calls `project_offscreen` before
`apply_config` and before `ensure()`, mutation-proved against attempt 2's code — it reproduces
the traceback above exactly. **Its value is entirely in its position:** moved below
`apply_config` it asserts nothing while continuing to pass.

The general form, for the next time: an ordering assumption about engine lifecycle reads as
obviously true, survives review, and cannot be caught by any test that starts from a configured
module. Prefer asking to assuming, at the cost of one branch.

**Every assertion was mutation-proved** — the behaviour broken, the failure observed, the
change reverted — and doing so found three holes in the harness's own first draft that are
worth more than the assertions they fixed:

1. **The frame-to-frame snapshot proved determinism, not correctness.** Rewriting `d0` to read
   vertex 1 passed all 60 assertions. A snapshot is stable whether or not it is right, so §4b
   now mirrors the fade formulas and checks alphas by value.
2. **Even then, `d0` was untestable in the original geometry.** With the route running straight
   away from the camera, vertex 1 *is* the nearest vertex, so "nearest drawn" and "vertex 1"
   are the same number. §4c puts the first three vertices behind the camera, where they differ
   by 2.7 m — 191 alpha correct against 215 broken.
3. **The along axis was never measured.** Looking down a straight route foreshortens it onto
   the `RTE.MLMIN` floor, so seven of eight marks had `w = 6.0` exactly and a projection
   regression could hide there. §7b views the same route from 45° off, where widths span
   7.85–21.02.

Mutations that could *not* be caught, recorded so the cover is not overstated: the `MNEAR` cut
(`fade = 0`) is redundant with the `MFADE` ramp over its own range — the ramp computes a
negative factor there, so the mark fails `a > 2` either way — and the two dead writes in §4.1
are dead, so breaking them breaks nothing.

One trap to carry into any fix: `local a, b, c = M.f and M.f()` truncates a multiple return to
one value. It has bitten this codebase twice, and `project_off` returns three values, so §8
asserts that arity directly.

---

## 6. Rejected, and why

Kept so nobody re-derives them.

**`iqm_pathline` — leave it entirely.** The scanner flags 11 RED `vector()` allocations in its
ribbon builder. All 11 are behind an F7 key, *and* they are the documented must-persist case:
each vector is stored into a `segs[i]` entry handed to the engine as `h.point_a`/`h.point_b`,
so no scratch vector can be reused. Two independent reasons to reject. Its idle
`actor_on_update` is two upvalue loads, a branch and a call — ~0.0004% of a frame. And it is
**not** dead code: `iqm_nav.debug_rawpath`, `iqm_route.debug_route` and `iqm_arms.debug_to_target`
all render through it, and `debug_rawpath`'s whole value is that both channels use the *same*
renderer. Unlike `iqm_mmprobe` at R2.44, this prototype has live consumers. `iqm_meshview` does
not even register a callback on an install without the debug launcher.

**The three known `iqm_nav` allocation false positives, re-verified.** `LP` (`:842`) and `RD.cp`
(`:1068`) are persistent pools bounded at 36 and 16, filled once per level; nothing clears them
and no index exceeds the bound. `mesh_goal`'s `vector()` (`:1546`) is on the once-per-target snap
path, itself cached by `snap_id`/`SNAP_HOLD_D`.

**`iqm_route`'s open set and closed set are already right.** The frontier is a real binary heap
with parallel `hv`/`hf` arrays and lazy deletion (`:243-272`) — no linear min-scan. Every
per-search map (`closed`, `g`, `came`, `pos`, `cover`) is keyed by integer vid; no string interning,
no `..` key building. Both were suspected by the review brief and both were wrong.

**`DIRS` at `:218`** memoises on first call and returns early forever after — eight vectors once
per process.

**`type` looked up 85× in `iqm_core:90`** is inside the file-scope `OPTIONS` registry table
literal: a load-time constant, zero per-frame cost. Likewise `tostring` ×8 at
`iqm_minimap:307` (inside `cal_key` and the F7 dump) and the `string.format` clusters, all inside
`say()` in cold paths.

**`A1-noamort` on four `actor_on_update`s and on `iqm_core.update`.** The scanner cannot see gates
that live in branches or in callers. `iqm_nav.update` has `blanked`/`HIDE_MS`, `vis_next`,
`next_try`, `REPATH_MIN` and `FAIL_COOL`; `iqm_core.update` is gated by
`if vis and tg >= next_scan` at `:2445`; `iqm_route`'s and `iqm_pathline`'s are one-flag early
returns. Throttling the *minimap* would be actively wrong — it draws on a heading-up map, so a
clock gate makes marks lag rotation.

**`SPAN_M = 100` (minimap cull radius) — unresolved, and partly circular.** The screen-edge bounds
work out at ~108–109 m against `SPAN_M * 0.5 = 50 m`, so `SPAN_M` is the binding bound and the
"factual" edge bound never fires. But those bounds derive from a `ppm` that was itself inferred
from the 100 m default, so the three numbers agree partly because they came from each other.
`MAX_MARKS = 26` is unreachable at every option combination the menu offers (worst case ~13), so
the pool ceiling does no culling. **The measurement that would settle it:** place one mark at
exactly `rad_m` and one at 1.15 × `rad_m` in a fixed world direction, screenshot, see which is
outside the rim — and repeat on a second level to rule out a per-level `minimap_zoom`, which is
`docs/minimap-route.md` §8 F3e's actual open question.

---

## 7. Still open

**Whether `gap_link` regressed the per-expansion cost.** `iqm_route`'s header states 7857
expansions in 24 ms, but the build is `R2.37b-linknone` and that figure was taken while
`gap_link` **never fired at all** — the header says so itself. It now runs on every mesh
boundary slot, ~2000×/search by the header's own `LINK_NONE` census, with up to 9
`level.vertex_id` calls and 3 rays each. Measured per-search total is ~29 ms, which is the same
*order* as 24 ms, but the routes measured here were not the header's "hard" one and the expansion
count is unknown, so **the header's number should be treated as stale rather than as refuted or
confirmed.**

To close it: a counter on `gap_link` entries and `_gray:query()` calls per search, plus the
expansion count, accumulated into module state and read out **after** stopping the profiler
(§1). Not via `gamma_eval` loops.

**~~The GC cost of 600 KB/s.~~ CLOSED by §8, and it is the largest number in this document.**
The route render allocates **6.000 KB/frame** — measured to the byte — and **LuaJIT's collector
charges ~87 µs/frame for it** against the 116 µs of work `draw_route` actually does. Garbage
collection is **~43% of the renderer's true cost**, and this section's guess that pricing it would
turn 4.1's justification "from an inference into a number" was right about the shape and wrong
about the size: the number is roughly 5–8× what 4.1 was credited with. Details and the control
that makes the attribution honest are in §8.

The first attempt at this failed and the failure is worth keeping: sampling
`collectgarbage("count")` every 500 ms for two minutes shows the heap oscillating between 58.7 and
62.0 MB with **no trend at all**. 6 KB/frame is invisible against GAMMA's own churn on a 60 MB heap
while the collector runs, and collections land between samples. Read-only sampling cannot price
this; stopping the collector can.

**~~Whether `place_mark` really costs ~9.6 µs.~~ CLOSED by §8: it does not.** Measured directly,
**6.2 µs when it places a mark and 1.45 µs when it early-returns**, reproducible across four runs
each. The profiler *over*stated it, which is the opposite of what this section expected — and the
missing cost was never mysterious once a projection was priced at what `project_off` really
charges (§2): four of them are ~3.8 µs of the 6.2, and the trig, widget calls and arithmetic are
the rest. The hypothesis that the luabind method dispatch dominated was tested and refuted —
`self:method()` on the class userdata costs 0.154 µs against 0.102 for a plain Lua call.

The question behind it — whether the remaining widget-call findings are worth anything — now has
an answer too, and it is **no**. A widget call is ~0.1 µs against a frame the whole feature costs
0.42 ms. §4.7 was the last of that family and turned out to be measuring the profiler.

---

## 8. The in-game pass — what was actually verified

Held 2026-08-19 in `l05_bar`, one session, live bridge, epoch 1. Everything above had been
measured on a harness or on the profile that *preceded* the fixes; nothing had drawn a real
frame. Seven changes had landed by then (4.1–4.3 in R2.50, 4.4–4.7 in R2.61).

### First: is the code that shipped the code that is running?

**Read sentinels out of the loaded chunks, never the DevKit epoch** — the epoch does not move on
a save load, so it cannot tell you whether a script edit went live. Seven markers, recovered by
walking `iqm_nav.update`'s closure tree with `debug.getupvalue`:

`pending` and `finish_route` (4.6) · `stub_frame` and `HDx` (4.5) · `OCC_SWEEP_MS = 100` and
`OCC_MAX = 12` (4.4, values read, not just presence) · `string_pull` at lines 605–684, 80 lines
where the pre-hoist version was 48 (4.6's first half) · `beacon.gs` present and maintained (4.7).

**And no IQM errors in the log at all.** Everything in it is other mods' MCM path complaints and
one vanilla `smart_terrain` respawn section.

### 4.6 — verified positively, by a fingerprint only the new code can leave

A 100 ms watch over 3926 ticks looked for `iqm_route.search_state() == "done"` **while**
`iqm_nav.status().searching == true`. That combination **cannot occur without this change**:
before it, `step_search` cleared `searching` on the same frame the search stopped reporting
"working". It appears three times, and each time the published point count moves on the *next*
sample rather than that one:

```
611300  done/true   pts=95   n=36    <- the pending frame: search done, list stashed, nothing published
611405  done/false  pts=110  n=36    <- the tail ran here, one frame later
```

Three catches across ~30 searches is what a ~10 ms window sampled at 100 ms should give. (The
bridge floors the interval at 100 ms; 50 ms was requested.)

**And no stale route, which is the loud failure mode.** Over the whole window the published count
only ever moves to a *new* value in step with the walk — 80 → 206 points as the target went 18 m
→ 80 m — and `n` stays 27–36. There is never a frame carrying a route from two searches ago.

### The rest, in one table

| item | how it was checked | result |
|---|---|---|
| **4.4** | `occ_owed` read live | **0.4800** — in `[0,1)`, carrying a fraction, never banking a debt |
| **4.5** alpha snap | every drawn vertex's `a` against its `t` | **36 of 36 exactly equal**, worst delta 0.000000 |
| **4.5** heading memo | each chevron located on the path *by world position*, its drawn direction against the path's own over ±`CHEV_DIR_M` | 14 of 16 under 0.01, worst 0.024 at one corner where the comparison window is wider than `heading_at`'s. **The memo is not stale** |
| **4.7** | `gs`/`gn` on all six live beacons | **3/3 on every one** → the park loop is `4..3`, empty every frame. Pre-fix: `4..4`, one wasted `Show(false)` per beacon per frame |
| **4.7**'s retraction | card slot state | `cards_shown = 0, cards_down = 8` → `hide_slot` called 8×/frame doing nothing each time, observed live |
| **4.1** | allocation per frame with the collector stopped — projections are the only thing that allocates, so the heap delta counts them | **verified.** 64 projections/frame, all 64 accounted for by 16 placing chevrons × 4. The deleted pass would have made it 100. See below |
| **4.2 / 4.3** | — | **not verified**, and not reachable from outside the module |

**Why 4.2 and 4.3 could not be verified.** Both are claims about how many *non-allocating* engine
calls a frame makes — `EnableHeading`, `Show`, `SetTextureColor`, and a hash lookup — so there is no
heap delta to count them by, and counting them needs a wrapper on the call. The route's drawing
functions are methods on a **luabind class userdata** (`iqm_cards.IqmCards` is userdata, not a
table), so they cannot be replaced by assignment the way a Lua function or an upvalue can —
`rawget` on it is an error, and patching the instance is not possible either. Their *effects* are
visible (the marks are placed correctly, nothing is re-stated) but the counts are not. Closing them
needs a counted stub inside `iqm_cards` itself, which is a code change rather than a measurement —
and given what §4.10 now says about where the cost is, it is not worth one.

### `place_mark`, measured properly — and how it was made measurable

§7 wanted this and proposed a method that cannot work (§1). What does work: `place_mark` is our
own Lua function with a known signature, so **call it directly**, N times, one accumulating timer,
a warm-up first. That is not the "do not bulk-benchmark engine primitives from `gamma_eval`" trap
— the objection there is that a misjudged cost stalls a frame and a mis-signatured engine call is
unrecoverable, and neither applies to replaying one of our own functions a few hundred times.

The thing that made it *correct* rather than merely repeatable was splitting the two paths.
`place_mark` returns `nm` unchanged when a projection puts the mark behind the camera and `nm + 1`
when it places one, so the return value classifies the call. Feeding it a point 10 m along
`cam_dir` guarantees the placing path; 10 m behind guarantees the early return. Four runs of 150
calls each, both paths:

| path | per call |
|---|---|
| places a mark | 6.67, 6.13, 6.15 µs (first run 9.24, still warming) |
| early-returns | 1.42, 1.40, 1.79 µs |

**The luabind dispatch hypothesis was tested and refuted.** `place_mark` is reached as
`self:place_mark(...)` on a class userdata, and if that indirection aborted LuaJIT's trace it would
explain the whole gap. It does not: `D:hide_slot(1)` on an already-latched slot — dispatch plus
three table reads — costs **0.154 µs** against **0.102** for a plain Lua function doing the same
reads, and a bare userdata field read is 0.038. Dispatch is ~0.05 µs. Worth recording as a null
result, because "it must be the luabind boundary" is the obvious answer and it is wrong.

**And a new finding fell out of it: 16 of 16 chevrons were taking the early-return path**, because
the player was not looking along the route. That is §4.9.

### The garbage counts the projections — which is how 4.1 got verified after all

§8's first draft said 4.1–4.3 could not be verified from outside `iqm_cards` because their claims
are engine-call *counts* and the callers are luabind userdata methods. That is true for 4.2 and
4.3, whose calls are free of allocation. It is **not** true for 4.1, and the reason is in §2: on
this path **projections are the only thing that allocates**, at 96 B each. So the heap delta *is* a
projection counter, and no stub is needed.

Measured with the collector stopped and the restart in the same chunk, over 10 and then 30
`draw_route` calls — the two blocks agreeing exactly:

| | |
|---|---|
| allocation per frame of route drawing | **6.000 KB**, from both block sizes |
| implied projections per frame | **64.0**, since 64 × 96 B = 6144 B exactly |
| `place_mark`, placing path | **384.0 B = exactly 4 projections** |
| `place_mark`, early-return path | **96.0 B = exactly 1 projection** |
| chevrons placing / skipping at the time | **16 / 0** |

16 placing chevrons × 4 projections = **64. Nothing is left over.** Had 4.1's deleted per-vertex
pass still been running it would have added one projection for each of the 36 drawn vertices — 100
projections, 9.375 KB/frame. **4.1 is verified quantitatively: the dead pass is provably absent,
and every projection in a frame is accounted for.**

That the numbers land on exact multiples of 96 B is itself the check on the model. A path that
allocated anything else would not.

### What the collector charges — and the control that makes it a real number

Timing the same 40 `draw_route` calls with the collector running and then stopped, three paired
runs alternating:

| | per frame |
|---|---|
| work only, collector stopped | **115.3, 114.6, 118.0 µs** — remarkably stable |
| with the collector running | 226.3, 221.5, 159.6 µs |
| **collector's share** | **~87 µs/frame mean**, 42–169 µs across all five runs taken |

So `draw_route` does ~116 µs of work and pays another ~87 µs for its garbage. **Garbage collection
is ~43% of the renderer's true frame cost**, and the total (~203 µs) is close enough to the
profiler's 242 µs to say the profiler was only ~20% high on this function.

**The control, which is the part that makes this attribution rather than coincidence.** Stopping
the collector speeds up *any* long loop if what it really does is let a process-wide backlog go
unserviced. So the same on/off comparison was run against a non-allocating arithmetic loop
calibrated to the same ~120 µs duration:

| workload | GC on | GC off | delta |
|---|---|---|---|
| `draw_route` (6 KB/frame) | 285.0 µs | 115.8 µs | **169.2 µs** |
| pure arithmetic, same duration, 0 B | 130.3 µs | 124.1 µs | **6.2 µs** |

**6.2 µs against 169.2.** The collector cost tracks allocation, not elapsed time. Without this
control the whole number would have been the same mistake as §4.7 — a measurement of the
instrument, reported as a property of the code.

The spread (42–169 µs) is not noise to be averaged away either: incremental collection charges
whatever its cycle happens to owe, so the route's contribution arrives unevenly. That is a
frame-time *variance* argument for reducing allocation, on top of the mean.

### 4.10 `place_mark` spends four projections per mark — the biggest thing left, and unpriced before now

Not a finding from the review proper; it falls out of the two sections above. At 16 marks the route
render's 64 projections are **the feature's dominant cost** once collection is included: ~61 µs of
calls plus ~87 µs of collector work, against 116 µs for everything `draw_route` does in total.

Two of the four exist to measure the mark's on-screen **thickness** — the `half`-offset pair either
side of the centre (`iqm_cards:1271-1272`). And there is already a code path that gets thickness
*without* them: `seg_width` (`:1282`), the fallback taken when either of that pair fails to project.
**Halving the projections per mark is therefore a matter of choosing the existing fallback, not of
inventing anything** — worth ~30 µs of calls and ~40 µs of collector work a frame.

**Why this is recorded rather than recommended.** The pair exists because it measures the true
projected thickness, and `seg_width` approximates it; R2.28's circular mean of two angle candidates
(`:1300-1309`) reads `cxk`/`cyy` from that same pair, so dropping them changes the mark's *angle*
as well as its width. That is a look change on every mark on screen, which belongs to whoever owns
the look — the same boundary as §4.8 and §4.9. It is listed here so the next perf pass starts from
the biggest item rather than rediscovering the widget calls.

### Three method findings, and two of my own errors

The method findings are folded into §1 and §2 where they belong; in short:
`profile_timer():time()` returns **microseconds**, `time_global()` **cannot time anything inside a
frame** (which invalidates §7's own proposed method for the `place_mark` question), and a
projection through `project_off` costs **~0.95 µs** rather than the raw call's 0.387.

Recorded because both were reported before they were checked, and both were caught by re-measuring
rather than by reasoning:

1. **The first `place_mark` figure was 13.9 µs and was wrong twice over** — the loop had not warmed
   and, worse, it was replaying chevron 1, which sits at the player's feet and fails the first
   projection. It was timing the early-return path while being labelled the placing path. The tell
   was arithmetic: the four projections measured *more* than the whole function they are inside.
   **If the parts exceed the whole, one of the two is measuring something else.**
2. **The first heading-memo check read a worst-case 0.87** — an apparent 66° error — because it
   indexed the 80-point `path` with `RD.ci[k]`, which is a *draw-list* index running 1–36. Locating
   each chevron by world position instead brought it to 0.024. A fixture that indexes one array
   with another array's index produces a confident wrong number rather than an error.

### What this pass did not do

- **`gap_link`'s per-expansion cost** (§7) — not attempted, and now clearly not worth attempting:
  §2's ranking puts everything search-related at ~1.25 ms/s against ~25 ms/s for drawing, and §8
  has since found a renderer line an order of magnitude larger than the whole search. The header's
  figure wants a footnote saying it is stale, not a measurement.
- **The save-load ordering mechanism** (§5) — the exact path by which a marker got drawn before
  `apply_config` is still unestablished. Attempt 3 made it moot, so this is curiosity rather than
  risk, and it wants a probe at the binding site across one load.
- **`SPAN_M` versus the screen-edge bound** (§6) — still circular, still wants two marks and a
  screenshot on two levels.

**Nothing was left installed.** No wrappers, no scratch globals, no watches; the collector was
never stopped, and the one intervention that touched game state — replaying `place_mark` a few
hundred times, which writes to the mark widgets — is undone by the next real `draw_route`. The
final check confirmed the route still drawing normally, `rg_used = 9`, and 4.7's `gs/gn = 3/3`
invariant still holding on all six beacons after everything above.
