# Changelog

All notable changes to Immersive Quest Markers are documented here.

## [0.11.0] - 2026-09-02

### :warning: Upgrading

`iqm_markers.script` is now `iqm_core.script`. If you install by **copying
`gamedata` over an existing install, delete the old
`gamedata/scripts/iqm_markers.script` first.** Copying will not remove it, and
with both present the mod loads and runs twice over. MO2 users are unaffected.

### Added

#### Waypoint markers *(on by default)*

A role glyph and direction chevron drawn **through walls**, with the range in
metres underneath. Glyphs are your PDA map's own art.

- Marks the selected task's objective, pending hand-ins, guide NPCs, the
  service trades (trader, technician, barkeep, medic) and any waypoint you
  placed. Companions are off by default.
- Range **60 m**. The selected task's mark and your own waypoint have no limit.
- Coloured like their PDA map spot, with turn-ins in the quest giver's faction
  colour. Set *Accent* for the mod's gold on everything.
- Never up on the same NPC as a card. When marks outnumber slots, your waypoint
  wins, then turn-ins, then shops and guides.
- Fades near the crosshair *(35% radius, 20% floor)*. The matching shrink is
  off by default.

#### Ground route *(off by default)*

A line of olive marks on walkable ground toward the selected task's objective,
thicker near you and thinner as it recedes, flowing with you as you walk.

- Switch it on under **Route: ground**. Draws **20 m** ahead with the
  **large chevron**.
- Drawn all the time by default. Set *Summoned* to draw only while a key is
  held, holding **3 s** after release. The summon key is unbound out of the
  box; unbound, it borrows the nameplate hotkey, and with neither bound the
  line stays drawn.
- Stretches behind cover fade rather than vanish. Within 25 m, seeing the
  target puts the route away.

#### Minimap trail *(off by default)*

The same route as small **white dots** on the HUD minimap, **50 m** ahead,
from your arrow to a mark on the objective when it is on the map.

- Measures your minimap rather than assuming a layout, so it works with any
  HUD and re-measures after a level or resolution change.
- Independent of the ground line.

#### PDA map icons *(on by default)*

The engine's map and minimap spots (tasks, the four trades, important
characters, companions, level transitions) are redrawn from the mod's own
128 px art at the overlay's tints. Three sub-options, all on:

- Task spots by kind: a skull on a mutant hunt, a red reticle on a bounty.
- NPC names in pin tooltips: `Sidorovich - Trader` instead of `Trader`.
- Companions no longer draw the faction squad dot.

Turning any of these off restores the original immediately.

#### Focus mode *(off by default)*

Cards follow your gaze rather than your whole view, so only the person under
the crosshair is named.

- Three levels: *Ambient only*, *All but objective*, *Everything*.
- Ring **50%** of half the screen height, **40%** soft edge, floor **0**
  (hidden; raise it to dim instead).
- Aiming down sights narrows the ring in the world.

#### Zone interference *(on by default)*

During an emission and inside a psi zone the overlay degrades: marks tear
sideways, outlines split into a coloured fringe, the range readout prints a
wrong digit. It follows the blowout's stages, eases off under cover and
recovers after a psi hit.

- Strength **100%**. The full cut-out is **off**; marks fade to just-visible
  instead.

#### Combat dim *(on by default)*

Overlays fade while your weapon is busy: aiming, firing, reloading, clearing a
jam, taking fire. Hold **1.5 s**, floor **35%**. Cards and markers each have a
switch.

### Changed

- `iqm_markers.script` renamed to `iqm_core.script`. See *Upgrading* above.
- MCM rebuilt into five pages: General, Nameplates, Waypoint markers,
  Route: ground, Route: minimap. No setting hides another's row.

### Fixed

- Guide offers now require the dialogue to exist, not just its preconditions.

## [0.10.0] - 2026-08-10

- Reveal hotkey: gate the cards behind a bindable key.

[0.11.0]: https://github.com/simonwdev/gamma-immersive-quest-markers/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/simonwdev/gamma-immersive-quest-markers/releases/tag/v0.10.0
