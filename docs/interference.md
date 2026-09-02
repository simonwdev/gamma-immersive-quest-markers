# Interference: the overlay under psi pressure

The investigation this feature was built from, kept as the record of what the game will tell
us, where in this mod the effect attaches, and what the widget palette can be made to do.

**IT IS BUILT NOW (R2.59).** This document was written before any of it existed and has been
left as it was, because what it is useful for is the evidence -- the signal reads, the
`sr_psy_antenna` and `surge_manager` findings, the `P()` census, the pixel-flooring
constraint. The design decisions that came out of it, and the arguments for them, are in
`docs/decisions.md` under [`noise`](decisions.md#noise); the code is `iqm_noise.script` (the
envelope) and `iqm_cards.script` (the displacement, under "INTERFERENCE"). What shipped
against what is proposed below:

| §3 effect | shipped as |
|---|---|
| band tear | `P()` in `iqm_cards`, 9 bands on a 90 ms beat |
| chroma split on the existing dark copies | `PS()` + `SHC()`, on the four ink copies |
| digit corruption | folded into the readout's `b.m ~= mtr` cache key via `NZ.ce` |
| dropout | `NZ.af`, applied beside the combat dim's multiplier |
| giving up | same multiplier; floored unless `noise_giveup` |
| heading wobble | **dropped** -- route marks rotate to show direction, so noise there destroys information rather than adding character |
| minimap | **dropped**, as proposed |

Two things in §1 were resolved by building it. The psi-antenna target is read as
`sound_intensity_base` and smoothed locally rather than reading `sound_intensity`, for the
`no_mumble` reason given below -- so open question 3 no longer gates anything. And the four
sources are combined with `max`, which was not in this document at all.

The four §5 questions still want a live session; `tools/noise-harness/harness.lua` covers
the envelope, the tier transitions, the band index and the sources offline (32 checks), but
no harness can tell you what a psi field looks like on screen.

Three things came out of it that decide the shape:

1. **The signals are already computed and free.** `_EVENT` carries the emission and the psi
   storm as live scalars, and `sr_psy_antenna.psy_antenna` carries the psi zone's own
   smoothly-ramped intensity. Nothing has to be polled, measured or spatially tested.
2. **The whole overlay draws through one two-line function.** Every world-space
   `SetWndPos` in the mod goes through `P(x, y)` in `iqm_cards.script`. A displacement
   written there reaches the cards, the markers and the route at once, and costs one
   compare per widget when the feature is off.
3. **The second draw is already paid for.** Every text and every leader line already has a
   black shadow copy behind it. Retinting and offsetting those copies gives a chromatic
   split out of widgets that already exist -- the one interference effect that normally
   needs a compositing pass we do not have.

---

## 1. The signals

### The event bus

`_g.script` keeps a plain global table `_EVENT` (`_g.script:2736`) with `GetEvent`/`SetEvent`
around it. Both managers write to it on every update, so the state is always current and the
read is two table lookups. Bind the table once, the way `beacon_roles` is bound -- never a
copy, and never `GetEvent`, which is a function call for a lookup:

```lua
local EV = nil                    -- bound in on_game_start
...
local sg = EV.surge
if sg and sg.state then ... sg.time ... end
```

| what | read | shape |
|---|---|---|
| emission running | `_EVENT.surge.state` | bool, written every `CSurgeManager:update` before its early return |
| emission clock | `_EVENT.surge.time` | seconds since start, 0..`surge_time`, rewritten once per **real** second |
| psi storm running | `_EVENT.psi_storm.state` | bool, same contract |
| psi storm clock | `_EVENT.psi_storm.time` | seconds, 1 Hz |
| nearest vortex | `_EVENT.psi_storm.vortex` | the vortex's sound position, or `false` when it ends |

**`.time` is only written while `.state` is true.** Read it ungated and you get the last
emission's clock, frozen, for the whole quiet period between them. Gate on `.state`.

The clock updates at 1 Hz, which is the right cadence for an *envelope* and far too coarse
for anything that moves. The envelope is the thing to drive from it; the per-frame motion
comes from a local clock, as it does everywhere else in this mod.

### The emission's own timeline

`surge_manager.script` (winner: `11- Preblowout Murder - Ethylia`) sets `surge_time = 222`
and hangs its stages off `diff_sec`, which is what lands in `_EVENT.surge.time`:

| `.time` | stage |
|---|---|
| 0 | begins; `fx_blowout_day` / `_night` weather |
| 25 | siren |
| 30 | rockets, hide task given |
| 47 | impact |
| 50-75 | rumble fading in |
| 80 | first earthquake (`earthquake_20`) |
| 100, 102, 104, 106 | quake ramp to `earthquake_100` |
| 108, 120 | first wave |
| 156, 168 | second wave |
| 200-209 | quakes fading out |
| 222 | ends |

That is a ready-made intensity curve with a real shape to it -- a long build, an impact, two
waves, a decay -- and it is the game's own curve, so an overlay that follows it is in step
with the weather, the sound and the camera shake rather than running its own private drama
alongside them.

Whether the player is **sheltered** is
`surge_manager.get_surge_manager():pos_in_cover(db.actor:position())`. It walks the level's
cover restrictors calling `:inside()`, so it is a once-a-second read and not a per-frame one.
Worth having: an overlay that comes back when you get underground is the fiction working.

### The psi zone

`sr_psy_antenna.script` (winner: `19- Horror Overhaul - DesmanMetzger`, and it keeps every
vanilla name) exposes its singleton as a namespace global:

```lua
local pa = sr_psy_antenna.psy_antenna     -- false, or the PsyAntenna instance
```

`false` when the actor is in no psi-antenna restrictor, an instance when they are. On it:

- `sound_intensity_base` -- the **target**, accumulated across overlapping zones. Steps on
  `zone_enter` and steps back down on `zone_leave`.
- `sound_intensity` -- `_base` chased with inertia (`intensity_inertion = 0.05`), clamped
  0..1. Already a ramped envelope on both entry and exit.
- `hit_intensity` -- same accumulation, no smoothing.
- `global_state` -- 1 inside, otherwise not.

`sound_intensity` is the obvious driver and it has one catch: its update is gated on
`not self.no_mumble` (`:199`), so a zone that suppresses the psi mumble freezes it. The
robust choice is to read `sound_intensity_base` (and/or `hit_intensity`) as the target and
run our own one-pole smoother over it. That is a few lines, it removes the dependency
entirely, and it wants doing anyway: interference should attack and release on its own curve,
not on the curve the game picked for an audio fade.

`PsyAntenna:update` returns early while `device().precache_frame > 1`, so the envelope must
hold at 0 across a load rather than reading a stale value through it.

### Psi anomaly fields, and everything else that hits you

Anything that does telepathic damage arrives as an actor hit, and the callback is free --
`arszi_psy`'s own handler is *commented out of its registration* in GAMMA's `Psy rework`, so
nothing owns it. `psy_damage.script` (`158- ABF`, live in the manifest) shows the exact shape:

```lua
RegisterScriptCallback("actor_on_before_hit", function(s_hit, bone_id, flags)
    if s_hit.type ~= hit.telepatic then return end
    local src = s_hit.draftsman        -- the zone, or the controller
    -- src:section() is e.g. "zone_field_psychic_average"
end)
```

This is the one signal that covers *every* source at once -- Dynamic Anomalies' spawned
`zone_field_psychic*` fields (`234- Dynamic Anomalies Overhaul`, live), a controller's tube, a
burer, the Brain Scorcher, a psi storm vortex. It is event-driven, so it costs nothing
between hits. It is a **spike**, not an envelope: the right use is to kick the envelope up and
let the release curve carry it down, which is also what it should look like -- the overlay
takes a knock and recovers.

### The psi-hostile North

`G.A.M.M.A. Psy Fields in the North` sets a namespace global on first update:

```lua
grok_psy_fields_in_the_north.psy_damage   -- 1 on a psi-hostile level, 0 otherwise
```

1 on Limansk, Red Forest, Zaton, Jupiter, Pripyat, the hospital, Stancia, Generators, Warlab
and the rest, unless the player's faction is psi-immune (monolith / isg / greh / zombied) or
the story switches are off. Read it and a whole level is "noisy".

Be careful what is built on it: that mod is a **death timer**, not an ambience. Twenty-three
seconds after it fires it subtracts 999 psy health. So it is a good source of a *baseline*
hum on those maps and a bad source of a sustained heavy effect -- the player will not be
alive long enough to see one.

---

## 2. Where the effect attaches

### One function

`iqm_cards.script:512`:

```lua
local _p = vector2()
local function P(x, y) return _p:set(x, y) end   -- scratch position
```

Every world-space position in the mod goes through it. `SetWndPos` counts by file:

| file | sites | what |
|---|---|---|
| `iqm_cards.script` | 24 | the cards, the markers, the route marks -- **all through `P`** |
| `iqm_minimap.script` | 3 | its own widget space |
| `iqm_arms.script` | 1 | |
| everything else | 0 | |

So the displacement is one edit in one function:

```lua
local function P(x, y) return _p:set(x + tear(y), y) end
```

and it reaches the cards, the markers, the route and every shadow copy at once. When the
feature is off, `tear` is a compare against a zeroed intensity.

Two properties fall out of this for free and both are wanted:

- **The offset can be a function of the row.** Every widget hands `P` its own `y`. A
  displacement keyed on `y` and time is a horizontal band tear -- the analogue-video
  signature -- and it needs no knowledge of who is being drawn.
- **Shadows tear with their owners.** The shadow offsets go through `P` too, so a torn card
  keeps its shadow attached instead of shedding it.

`S(w, h)` is a separate scratch, so sizes are untouched unless we choose to touch them.

Leave `iqm_minimap` out, at least at first. It is PDA furniture in its own widget space; the
argument for interference is that the overlay is a *rendered thing in the world*, and the
minimap is a map.

### Envelope in a new module, displacement in `iqm_cards`

That split is the one the codebase already draws, in `iqm_beacon`'s own words: *"WHAT IS NOT
OURS: the drawing."* A marker is laid out in `iqm_beacon` and drawn by `iqm_cards`. So:

- a new `iqm_noise.script` owns the **signals and the envelope** -- read `_EVENT`, read the
  antenna, take the hit spikes, run the smoother, publish one 0..1 intensity (and perhaps a
  phase) that everything else binds;
- `iqm_cards` owns the **displacement** -- it already owns the drawing.

Local budget is not a constraint anywhere near this: `iqm_cards` uses 35 of 198 and
`iqm_beacon` 43. (`iqm_core` at 124 and `iqm_nav` at 135 are the tight ones; neither needs to
change.) A new file also has no budget risk at all, and the existing "bind in
`on_game_start`" seam means load order does not matter.

---

## 3. What interference can be made of here

The palette a widget gives us is position, size, texture, ARGB, heading and `Show` -- plus
`SetText` on the two text windows. That is less than a shader and more than it looks:

1. **Band tear.** `x` displaced as a function of `y` and time. The signature effect, one
   place, free. See the two caveats in §4.

2. **Dropout.** Alpha driven toward 0, or `Show(false)` for a few frames. There is already a
   multiplier path for exactly this -- `ctr_fade` in `iqm_beacon:354` returns an alpha and a
   size multiplier and the draw call applies them -- so this is a second multiplier through
   existing plumbing, not new plumbing.

3. **Chromatic split -- and this is the find.** There is no second compositing pass to do a
   real RGB split with, but the mod already draws a **black shadow copy behind every text,
   every leader line and every plate** (`head_sh`, `name_sh`, `line_sh`, `shadow`,
   `beacon_name_sh`). Retint those copies toward a hue and displace them *opposite* the tear,
   and the fringe comes out of widgets that are already created, already positioned and
   already costing a draw. The second draw is paid for; only the colour and the offset are
   new.

4. **Glyph corruption, cheaply.** The marker's range readout is already **sprite digits** --
   one widget per character, texture chosen from `DIGIT_TEX` and only re-pointed when the
   metre count changes (`iqm_cards:1315`). A corrupted readout is therefore a texture swap in
   a pool that already exists: substitute a wrong digit or a blank. Do it on the existing
   change boundary (`b.m ~= mtr`), not per frame.

   The NPC name is a real text window and `SetText` measures the string, so corrupt it on the
   existing `b.nmt ~= nmt` cache boundary -- a few times a second at most. Never per frame:
   that cache exists precisely because the text path was the expensive one.

5. **Heading wobble.** The chevron and every route mark already call `SetHeading`. A few
   degrees of noise reads as a mark losing its lock, and it is one extra add.

6. **Giving up.** At peak, the overlay stops drawing. This is the part that turns the whole
   feature from an effect into characterisation: the marker is not glitchy, it is *outmatched*.
   It also has to be the part with a switch on it -- see §4.

---

## 4. Constraints, in the order they will bite

**Whole-pixel quantisation.** `iqm_beacon`'s `CTR_Q` note records that the engine floors
every widget's position to a whole screen pixel, independently per widget. So a displacement
under one screen pixel lands on some widgets and not others, and reads as shimmer rather than
tear. UI space is 1024x768 scaled to the screen, so at 1440p one UI unit is a little under
two vertical pixels -- amplitudes want to be stated in UI units with that in mind, and
probably quantised deliberately the way the centre falloff quantises its size multiplier for
the same reason.

The compensating good news, from the same source: since R2.31 every glyph carries its keyline
baked into its own texture instead of drawing a second widget behind it. The art is already
built to survive being displaced -- a torn badge keeps its outline.

**Aspect.** UI x-space is stretched by `UI_KX`; `ctr_fade` converts with `sx = ax / kx`. A
horizontal displacement intended to be N true units must be written `N * UI_KX`, or the tear
is wider on an ultrawide than on 16:9.

**Do not use `math.random` per widget per frame.** It shimmers -- every band re-rolls every
frame, which is not what interference looks like and not what a harness can test. A cheap
hash of (row, time quantised to a few frames) holds a band still for a beat, which is both
truer to the reference and reproducible.

**The mod must not lie.** Interference that hides a marker means the player cannot find the
objective, and this codebase has already had this argument and settled it, twice, in the same
direction -- `ctr_fade`: *"A FLOOR AND NOT A HIDE ... the default should be the behaviour
that cannot flicker."* Dropout and give-up need a floor by default and a switch for anyone
who wants the full thing, following the `beacon_ctr_size` shape: a knob whose 0 is the off
switch, plus one explicit check for the half that changes geometry.

**Options go in one place.** `iqm_core.OPTIONS` is the single registry -- key, page, default,
widget, range, precondition -- from which `DEFAULTS`, `PAGE_OF` and the whole MCM menu are
derived (see `iqm_mcm.script`'s header). Storage paths are `iqm/<page>/<id>`, so choosing the
page is choosing where the value lives for ever; a later move needs a migration.

**Nothing to persist.** Every signal is live. No save state, no `load_state`, no migration.

---

## 5. What only the running game can answer

The game was closed for this pass, so these are static reads. Four things want a
`gamma_watch` before any of it is built:

1. `_EVENT.surge.state` and `.time` -- confirm the cadence and the range live, and confirm
   `.time` really does freeze between emissions (it should, and the envelope has to be
   written as though it does).
2. `sr_psy_antenna.psy_antenna and sr_psy_antenna.psy_antenna.sound_intensity_base` -- which
   GAMMA zones actually carry an antenna, and what intensities they hand over. This decides
   whether a psi zone is a strong signal or a rare one.
3. Whether those zones set `no_mumble`. It decides whether `sound_intensity` is usable
   directly or we smooth `_base` ourselves. (Smoothing it ourselves is probably right
   regardless.)
4. How often Dynamic Anomalies' `zone_field_psychic*` fields fire `actor_on_before_hit` while
   the player stands in one -- `psy_damage.script` throttles its own handling to one hit per
   7 s, which hints the underlying hits are frequent. If they are, the fields are an envelope
   source and not just a spike source.
