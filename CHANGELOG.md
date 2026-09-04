# Changelog

All notable changes to Immersive Quest Markers are documented here.

## [0.12.0] - 2026-09-04

### Added

- **A STALKER 2 style for the PDA map icons**, off by default: a white glyph in
  a thin white diamond, no colour coding. *MCM → General → Icon style →
  STALKER 2 diamonds*. Same glyph set and the same atlas layout as the ring
  badges — a second texture file plus a white tint — so switching it costs an id
  rename at parse time and nothing at runtime. Read once at startup, like *Enable
  icons*, so it applies at the next launch.
  - Colour and the frame mostly stop carrying information: a medic and a trader
    differ by glyph alone, and one frame is used for a person, a place to search
    and a job to hand in. That is the look; see
    [`docs/decisions.md#map_icon_style`](docs/decisions.md#map_icon_style).
  - **What keeps its colour**: the squad dots' faction colours, the level
    transition arch's green — the same arch in both styles, so whitening it would
    have made a fixture harder to find without looking any more like S2 — and the
    three task-kind tints: the **hand-in green** (deliveries included, which share
    that green on purpose), the **bounty red** and the **mutant olive**. Colour
    stays where it answers a question asked before the glyph is read — is anything
    finished, is anything hostile — and goes where it was only telling two nouns
    apart. A tracked task's selection frame is white on every pin, since a
    selection is a state rather than a kind.
  - A selected task's frame is **re-centred** on the larger icon. The frame is a
    top-left child of a centre-aligned spot, so its offset is
    `-(border - icon)/2` — a constant that stops being right the moment the icon
    changes size, and a frame sitting a unit up and left of its marker is what
    that looks like. It is derived from the geometry now, and the border grows
    by the same number of units the icon does so the air between them holds.
  - The **hollow frame** — the mark for a task or waypoint whose target already
    carries an icon of its own, such as a waypoint dropped on a service pin —
    is drawn larger than the badge, so it rings that icon rather than landing on
    its outline. It stays a whole diamond: corner brackets are the *selected
    task* frame, and nothing else may wear them.
  - Spots are drawn **19% larger** in this style (19 → 23 units on the map,
    14 → 17 on the minimap). A diamond of the same extent as a ring badge reads
    smaller — only its four points reach as far, and everywhere else it sits
    inside the circle — and the art has nowhere to grow, since the points are
    already at the edge of the cell. The number is silhouette parity: a diamond
    of half-diagonal `d` encloses `2d²` where a circle of radius `r` encloses
    `πr²`, so they match at `d = r·√(π/2)`. Marks whose art is the same in both
    styles (the squad dots, the pulse, the off-screen pointer, the transition
    arch) keep their size.
  - The frame's stroke is **1.5 units against the ring badge's 1.8**, which is what
    puts the same *drawn* line weight on screen: the spot is 19% larger here and a
    diamond has 10% more perimeter than a circle of the same extent. It is derived
    from the spot scale rather than tuned alongside it, since the two multiply.
  - Every marker is framed, the off-level arrows included — they are drawn bare in
    the ring style because there the frame is the verb, and with no verb to protect
    a bare glyph just reads as a marker missing its diamond.
  - The trader draws a **bag** rather than the briefcase here — the diamond
    gives a glyph ~25% more linear size than a ring badge does, which is enough
    for a drawing the ring style had to reject.

### Removed

- **A task pin no longer avoids covering what it points at.** A waypoint dropped
  on a bed, a stash task on a stash, a pin on a level changer &mdash; all of them
  used to swap to a hollow reticle and ring the mark underneath instead of
  covering it. That is gone by request, for vanilla behaviour: a pin now draws
  over what it points at, the way every other task marker in the game does.
  The `open` and `waypoint` kinds, the two location types they drove, and the
  engine query behind them all went with it. **Known cost:** the DRX quest-item
  family (21 sections) points at a stash you have already found, so its pin now
  sits on top of the stash icon.

### Fixed

- **The hand-in and delivery pins were the two smallest marks on the map**, in
  both styles. The hand-in tag is now 25% larger in linear size and the delivery
  envelope 21%. Both are sized against their own *ink* rather than their bounding
  box — two marks that differ only by glyph must not also differ by weight, or the
  heavier reads as the more important — but that correction had been applied to
  **both** halves of the pair, and two equal scales equalise nothing: it cancelled
  out and left only a shared 21% shrink. The tag's lit box measured 97 px against
  the skull's 118 and 128 for every badge and reticle. It now measures 120, the
  same as the skull, and the pair's weights match within 1.3% (they were 9% apart,
  in the opposite direction to what the old note claimed — the tag was the
  *lighter* of the two, so the envelope was the one that needed correcting).
- **A waypoint on a bed, trader or fast-travel point drew a diamond around a
  diamond.** The waypoint pin wore the same closed hollow reticle a stash task
  does, which in the STALKER 2 style meant a second diamond ringing the service
  badge's own. It now draws *nothing* of its own: a waypoint is the service badge
  alone until it is the task you are tracking, and the badge inside the
  active-marker cut diamond once it is. The ring was only saying "this pin is on
  top of something", which the badge underneath already says.

### Changed

- **The Map icons options are renamed** to say what each switch does rather than
  what it is: *Enable icons*, *Icon style*, *Mark hunts and bounties*, *Show NPC
  names* and *Hide companion squad dots*, with *Badges (this mod)* becoming
  *Colourised circles* — the look as it appears on the map, against *STALKER 2
  diamonds*. The section header already says *Map icons*, so the rows stop
  repeating it. *Icon style* also gains the *(restart required)* note it always
  needed: it is read when the engine parses `map_spots.xml`, once per process,
  exactly like *Enable icons*, and saying so on only one of the two implied the
  other was live. Display strings only — no stored setting moves.
- **Storyline tasks keep their gold in the STALKER 2 style**, and a tracked
  task's selection frame now takes the colour of the mark it is around instead of
  being white on every pin. Two corrections to the same all-white first cut. The
  gold could not be kept by icon id — a storyline task and a secondary task are
  the *same* cell and differ only in tint — so the pass keys that decision on the
  tint itself, which also carries it through the minimap pin, its off-level
  arrows, the new-task pulse and the legend swatch in one rule. The white frame
  was the larger mistake: it is the biggest, brightest shape in the mark, so a
  white diamond around a red bounty read as a white marker with something red
  inside it, and the *kind* lost to the *state*. Selection is already carried by
  the frame's presence and its blink.
- **A bounty task now draws a blast** instead of crossed swords, in both styles:
  four long spikes with shorter rays between them, at unequal lengths. The swords
  were chosen because an X changes the *silhouette class* away
  from the mutant hunt's skull — which matters more than it sounds, since the two
  marks' red and lime sit on the red–green axis and shape is the only channel a
  player with red–green deficiency has to tell a firefight from a mutant hunt. The
  X was never the problem; thin blades were. A spike is the same X with a fat
  middle, so it keeps the silhouette and stops smudging to a blob at the 26 px a
  map spot is really drawn at — it inks 60% of the skull against the swords' 42%.
  The four long arms are what carry the silhouette argument; the shorter rays are
  what make it read as a blast rather than as crossed weapons.
  - Its **long arms point at the cardinals**, which is what lets it be drawn
    larger than any glyph this cell has held. Both frames leave the most room
    there and for unrelated reasons: the ring reticle's *gaps* are on the
    cardinals, and the s2 diamond's *vertices* are. Every crossed glyph before it
    pointed at the diagonals, into the arcs.
  - The two styles now take **different fit scales** (`S2_RETICLE_FIT_SCALE`),
    because the s2 diamond is closed and has no gaps to reach through — the ring's
    number would drive the glyph 284 px through that frame.
  - **Known cost:** at the 18 px the minimap draws, the plain four-spike version
    resolved as four distinct limbs where this condenses to a dense star. It is
    kept at `tools/map-icons/svg/bounty-spikes4.alt`; the swords are at
    `bounty-swords.alt` and the rounds at `bounty-rounds.alt`.
- **Fixed: the bounty glyph was drawn touching the reticle's arcs.** The reticle's
  gaps sit on the *cardinals*, so its four arcs are centred on the *diagonals* —
  exactly where a crossed glyph points, with no gap for a tip to pass through. The
  swords had run since R2.58 at a fit that reached 59.0 px into a ring stroke
  spanning 52.7–63.8. The overlap is invisible at 70 px, which is how it survived.
  Any crossed glyph in this cell is now capped at 0.95.

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

[0.12.0]: https://github.com/simonwdev/gamma-immersive-quest-markers/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/simonwdev/gamma-immersive-quest-markers/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/simonwdev/gamma-immersive-quest-markers/releases/tag/v0.10.0
