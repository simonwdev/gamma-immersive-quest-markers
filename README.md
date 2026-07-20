# Immersive Quest Markers

A "PDA-UI" style quest marker for STALKER GAMMA. Over the head of an NPC tied to one of your active tasks, it floats a small card (a header like `REPORT BACK` or `LOOKING FOR GUIDE`, plus the NPC's name) connected to the head by a thin diagonal **leader line**, the way TV and film UIs annotate a person or a phone on screen.

## Requirements
- MCM (optional) for in-game tuning; without it the built-in defaults apply.
- `demonized_geometry_ray` (optional) for line-of-sight culling. It ships with many GAMMA mods (both Catspaw addons, Weapon Cover Tilt, etc.), so it's effectively always present in GAMMA. Without it the LOS check is skipped and cards show through walls.
- No hard dependency: the marker is self-contained (own projection, own textures, own role glyphs); the utilities above only add optional polish.

## How it works
- **Projection is done by this mod**, with `game.world2ui` on the NPC's `bip01_head` bone. The node, leader line and card are all drawn from that one point, so they always agree.
- **Node picks the near shoulder:** so the leader line doesn't cross the torso, the anchor is placed on whichever shoulder sits on the card's side of the screen. Both shoulder candidates are projected to screen and the one toward the card is chosen, so it's correct at any camera angle and NPC facing. Auto by default; side and distance are tunable in MCM.
- **Smoothing:** the head point is eased with a framerate-independent exponential filter plus whole-pixel hysteresis, so the card sits steady while the NPC's head bobs. Big jumps snap.
- **Diagonal line:** the leader is a thin rotated strip from the head node to the card's nearest corner, extended slightly past the corner and drawn behind the plate so it tucks under the card with no gap. A slightly thicker black strip behind it keeps the line legible over bright backgrounds.
- The card flips to the other side of the head automatically near the screen edge, and fades in/out with distance.
- **Hidden while the PDA is open:** the whole overlay is suppressed when the fullscreen PDA (map / tasks / contacts) is up. Per-NPC state is kept, so closing the PDA resumes cleanly with no re-chirp or replayed entrance.
- **Line-of-sight culling:** a geometry ray is cast from the NPC's head toward the camera (via `demonized_geometry_ray`); if the head is behind a wall or other cover the card hides. It's polled per-NPC at a configurable rate with a short grace window so brief occlusions don't flicker. Without that utility the check is skipped and cards show whenever on-screen. Toggle in MCM.
- Up to 8 NPCs are carded at once; beyond that, extras are skipped for that scan (and noted in the log when diagnostic logging is on). Objective cards claim slots first, ambient role cards fill what's left.

## Card types
Headers follow two grammars on purpose. State cards use verb phrases: they mark something to act on right now, and they chirp on sighting. Ambient cards use a terse noun plus a role glyph: they state a standing fact about the NPC, and they stay silent. So the grammar alone tells you whether you are looking at an objective or at background information.

State cards (headers are written as the NPC broadcasting their own status on their PDA):
- **Quest objective**: the NPC the game is currently pointing you at. That covers a dynamic task (fetch/bounty) that has reached its hand-in stage, a storyline or mid-quest "go talk to X" step, and a delivery quest's "deliver to" NPC. Delivery targets are resolved directly from the delivery job's target functor (`task_functor.general_delivery`, ships with GAMMA), which the engine's own `current_target` can miss; they appear once you've travelled to that NPC's level and they're on-screen. All read `REPORT BACK`. Hostiles are never carded.
- **"Needs a guide" stalker**: the stalker currently looking for a guide to escort them somewhere (the GAMMA guide job). The guide squad is read from the job's own saved state, so the card matches exactly when that job is available, and it disappears the moment you accept the escort. Header reads `LOOKING FOR GUIDE`. Soft dependency on `tasks_guide` (ships with GAMMA); skipped if absent.
- **Recruitable companions**: nearby friendly stalkers you could hire as a companion right now. Header reads `LOOKING FOR WORK`. This scan is kept cheap: it skips entirely when your party is full, checks the cheapest conditions first per NPC, only keeps stalkers that project on-screen, and runs on a slow 3-second cadence with the result cached between scans. Eligibility uses GAMMA's actual recruit-dialog preconditions. Soft dependency on the companion system (ships with GAMMA); skipped if absent.

Ambient role cards are detected from the engine's own PDA map-spot registry (the same source as the map legend icons), polled per NPC on a slow cadence:
- **Guides**: NPCs offering fast-travel guide services (the PDA "Guide" icon). Header reads `GUIDE`.
- **Traders / technicians / barkeeps / medics**: service NPCs. The exact service is read from the NPC's actual trade file via `trader_autoinject`, so a technician whose level logic labels him a trader still reads `TECHNICIAN`. Headers read `TRADER` / `TECHNICIAN` / `BARKEEP` / `MEDIC`.
- **Important characters**: story/faction important NPCs (the PDA "Important Character" and quest-NPC icons). Header reads `VIP`.
- Role cards default to the noun header and name with the role glyph beside them, tinted to the accent colour. The glyphs are bundled with the mod (Tabler icons). An MCM style option (Advanced) switches them to a compact icon-only chip (just the glyph on a small plate, for quieter hubs) or to plain text with no glyph.

When one NPC qualifies for several cards, the most actionable wins: objective > guide job > recruitable > role. A quest giver who is also a trader reads `REPORT BACK` while they're your objective, then goes back to the `TRADER` chip.

## MCM (Options → Mod Configuration → Immersive Quest Markers)
Split across two tabs. **Core** holds the everyday switches; **Advanced** holds fine tuning, styling, colour, motion and performance rates.
- **Core:** enable · card quest targets · card the "needs a guide" stalker · card recruitable companions · card guide NPCs · card service NPCs (trader/technician/barkeep/medic) · card important characters · appear distance · line-of-sight check · PDA chirp on sighting.
- **Advanced (node):** show head node dot, pulse the node glow, node size, node min size (far).
- **Advanced (sound):** PDA chirp volume.
- **Advanced (cards):** service card style (icon chip / text + icon / text only).
- **Advanced (visibility):** full-opacity distance, line-of-sight check rate, line-of-sight grace (anti-flicker linger).
- **Advanced (anchor):** height above the shoulder, horizontal anchor nudge, auto shoulder side + distance.
- **Advanced (card & line):** card offset X/Y, leader line thickness & opacity, card opacity.
- **Advanced (motion):** smoothing (framerate-independent), snap distance.
- **Advanced (accent colour):** A/R/G/B for the line, edge bar, header and node. Defaults to a soft desaturated gold (224, 196, 122) on a warm charcoal plate.
- **Advanced (debug):** diagnostic logging (line-of-sight checks, card-slot overflow, sound playback). Off by default; the mod writes nothing to the log without it.

## Testing without quests
A card can be forced onto the stalker under your crosshair, bypassing the task/guide/companion detection. Two ways:

- **F7 debug menu → Target tab**: look at a stalker, press F7, and use the injected `IQM: Card as Quest Target / Guide / Companion / Guide NPC / Trader / Important` actions (plus `IQM: Clear Pinned Cards`). The menu closes and the card appears immediately. `Card as Trader` cycles a random service glyph (trader / technician / barkeep / medic) each press, so all four can be previewed from one button.
- **Lua execute box / script console**:

  ```lua
  iqm_markers.debug_card("target")     -- or "guide" / "companion" / "guider" / "trader" /
                                       -- "mechanic" / "barman" / "medic" / "important"
  ```

Repeating an action with the same role unpins that NPC; a different role switches the card style. `iqm_markers.debug_clear()` removes all pins. Pinned cards persist until unpinned (or the NPC dies), so you can test fade distances, line-of-sight culling, the shoulder picker and the chirp on any friendly NPC.

## My other projects
- [STALKER GAMMA Database](https://stalker-gamma-db.com/): a reference database of items, weapons and crafting for STALKER Anomaly GAMMA.
