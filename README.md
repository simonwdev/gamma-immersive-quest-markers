# Immersive Quest Markers

A "PDA-UI" style quest marker for STALKER GAMMA. Over the head of an NPC tied to one of your active tasks, it floats a small card (a header like `REPORT BACK` or `LOOKING FOR GUIDE`, plus the NPC's name) connected to the head by a thin diagonal **leader line**, the way TV and film UIs annotate a person or a phone on screen.

## Requirements
- MCM (optional) for in-game tuning; without it the built-in defaults apply.
- `demonized_geometry_ray` (optional) for line-of-sight culling. It ships with many GAMMA mods (both Catspaw addons, Weapon Cover Tilt, etc.), so it's effectively always present in GAMMA. Without it the LOS check is skipped and cards show through walls.
- No hard dependency: the marker is self-contained (own projection + own textures); the two utilities above only add optional polish.

## How it works
- **Projection is done by this mod**, with `game.world2ui` on the NPC's `bip01_head` bone. The node, leader line and card are all drawn from that one point, so they always agree.
- **Node picks the near shoulder:** so the leader line doesn't cross the torso, the anchor is placed on whichever shoulder sits on the card's side of the screen. Both shoulder candidates are projected to screen and the one toward the card is chosen, so it's correct at any camera angle and NPC facing. Auto by default; side and distance are tunable in MCM.
- **Smoothing:** the head point is eased with a framerate-independent exponential filter plus whole-pixel hysteresis, so the card sits steady while the NPC's head bobs. Big jumps snap.
- **Diagonal line:** the leader is a thin rotated strip from the head node to the card's nearest corner, extended slightly past the corner and drawn behind the plate so it tucks under the card with no gap. A slightly thicker black strip behind it keeps the line legible over bright backgrounds.
- The card flips to the other side of the head automatically near the screen edge, and fades in/out with distance.
- **Hidden while the PDA is open:** the whole overlay is suppressed when the fullscreen PDA (map / tasks / contacts) is up. Per-NPC state is kept, so closing the PDA resumes cleanly with no re-chirp or replayed entrance.
- **Line-of-sight culling:** a geometry ray is cast from the NPC's head toward the camera (via `demonized_geometry_ray`); if the head is behind a wall or other cover the card hides. It's polled per-NPC at a configurable rate with a short grace window so brief occlusions don't flicker. Without that utility the check is skipped and cards show whenever on-screen. Toggle in MCM.
- Up to 6 NPCs are carded at once; beyond that, extras are skipped for that scan (and noted in the log when diagnostic logging is on).

## Card types
- **Quest targets**: the NPC the game is currently pointing you at, i.e. the "go talk to X" step and "return to the giver" turn-ins. Most dynamic tasks (fetch/bounty) are only carded once they reach `stage_complete`, i.e. once there's actually someone to talk to. Hostiles are never carded. Header reads `REPORT BACK`.
- **Delivery targets**: the "deliver to" NPC of a delivery quest. The engine's `current_target` can miss these, so it's resolved directly from the delivery job's target functor (`task_functor.general_delivery`). The card only appears once you've travelled to that NPC's level and they're on-screen. Soft dependency on `tasks_delivery` (ships with GAMMA).
- **"Needs a guide" stalker**: the stalker currently looking for a guide to escort them somewhere (the GAMMA guide job). The guide squad is read from the job's own saved state, so the card matches exactly when that job is available, and it disappears the moment you accept the escort. Header reads `LOOKING FOR GUIDE`. Soft dependency on `tasks_guide` (ships with GAMMA); skipped if absent.
- **Recruitable companions**: nearby friendly stalkers you could hire as a companion right now. Header reads `LOOKING FOR WORK`. This is the one case that must scan NPCs, so it's kept cheap: it skips entirely when your party is full, checks the cheapest conditions first per NPC, only keeps stalkers that project on-screen, and runs on a slow 3-second cadence with the result cached between scans. Eligibility uses GAMMA's actual recruit-dialog preconditions. Quest/guide NPCs always claim card slots first; recruitables fill what's left. Soft dependency on the companion system (ships with GAMMA); skipped if absent.

## MCM (Options → Mod Configuration → Immersive Quest Markers)
Split across two tabs. **Core** holds the everyday switches; **Advanced** holds fine tuning, styling, colour, motion and performance rates.
- **Core:** enable · card quest targets · card the "needs a guide" stalker · card recruitable companions · appear distance · line-of-sight check · PDA chirp on sighting.
- **Advanced (node):** show head node dot, pulse the node glow, node size, node min size (far).
- **Advanced (sound):** PDA chirp volume.
- **Advanced (visibility):** full-opacity distance, line-of-sight check rate, line-of-sight grace (anti-flicker linger).
- **Advanced (anchor):** height above the shoulder, horizontal anchor nudge, auto shoulder side + distance.
- **Advanced (card & line):** card offset X/Y, leader line thickness & opacity, card opacity.
- **Advanced (motion):** smoothing (framerate-independent), snap distance.
- **Advanced (accent colour):** A/R/G/B for the line, edge bar, header and node. Defaults to a soft desaturated gold (224, 196, 122) on a warm charcoal plate.
- **Advanced (debug):** diagnostic logging (line-of-sight checks, card-slot overflow, sound playback). Off by default; the mod writes nothing to the log without it.

## Testing without quests
A card can be forced onto the stalker under your crosshair, bypassing the task/guide/companion detection. Two ways:

- **F7 debug menu → Target tab**: look at a stalker, press F7, and use the injected `IQM: Card as Quest Target / Guide / Companion` actions (plus `IQM: Clear Pinned Cards`). The menu closes and the card appears immediately.
- **Lua execute box / script console**:

  ```lua
  iqm_markers.debug_card("target")     -- or "guide" / "companion"
  ```

Repeating an action with the same role unpins that NPC; a different role switches the card style. `iqm_markers.debug_clear()` removes all pins. Pinned cards persist until unpinned (or the NPC dies), so you can test fade distances, line-of-sight culling, the shoulder picker and the chirp on any friendly NPC.

## My other projects
- [STALKER GAMMA Database](https://stalker-gamma-db.com/): a reference database of items, weapons and crafting for STALKER Anomaly GAMMA.
