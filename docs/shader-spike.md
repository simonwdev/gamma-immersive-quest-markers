# Shaders for the route — the spike, and what is already settled

Working doc for one question: can the route markers do their occlusion per pixel
against the scene depth the engine has already computed, instead of casting rays?
Everything below except §5 was settled by reading the engine and GAMMA's shader
mods; §5 is the part that can only be answered by running it, and is what
`gamedata/shaders/r3/iqm_depthspike.*` and `iqm_shaderspike.script` exist to answer.

Related: `docs/ar-navigation.md` (F2, the route), `docs/route-perf.md` (what the
current renderer costs), `docs/decisions.md`.

Status: **spike run, 2026-09-02, l01_escape, DX11. All four modes pass — the
approach is viable and the design in §3 is confirmed end to end.** Results in §6.

---

## 0. Why bother

The route's occlusion today is `point_occluded` — a geometry ray per route point,
round-robin on a per-second budget, feeding a per-point eased alpha
(`iqm_nav.script:507-530`, `:1397-1400`). It costs little (`route-perf.md`: the whole
feature is 0.42 ms) but it buys a coarse answer: a mark is wholly lit or wholly dim,
the verdict lags the camera by however long the budget takes to come round, and the
route is **disabled outright** without `demonized_geometry_ray` (`:1951`).

A pixel shader that samples the deferred position target gets the exact answer for
free, per pixel: a mark slides under a rock edge with the rock's own silhouette. It
also retires the ray dependency and the easing machinery that exists to hide the
lag.

This is the same trick the mod that prompted the question described — depth-buffer
rejection so an effect lands on the world and not on the viewmodel in front of it.
(Worth recording: `dxshie/immersive_identification`, the repo named at the time,
ships no shaders at all — two `.script` files and five textures. Whatever did this
was something else.)

## 1. The hook: every UI element already draws through a script blender

`CUIStatic:InitTextureEx(texture, shader)` is bound to Lua
(`xrGame/ui/UIStatic_script.cpp:31`), and `<texture shader="...">` works from UI XML
too (`ui/UIXmlInit.cpp:974`) — which means the production change needs **no Lua at
all**, just an attribute in `iqm_cards.xml`.

On DX10/11 the engine resolves a shader name by looking for a Lua *script blender* at
`gamedata/shaders/r3/<name>.s` **before** consulting the C++ blender library
(`Layers/xrRender/ResourceManager.cpp:334`). Backslashes fold to underscores
(`dx10ResourceManager_Scripting.cpp:499`), so the stock `"hud\default"` every UI
element uses is literally `shaders/r3/hud_default.s`, and it is seven lines:

```lua
function normal(shader, t_base, t_second, t_detail)
  shader:begin("stub_notransform_t","hud_default")   -- vs, ps
        :blend(true,blend.srcalpha,blend.invsrcalpha)
        :zb(false,false):aref(true,0)
  shader:dx10texture("s_base", t_base)
  shader:dx10sampler("smp_base"):clamp()
end
```

Constraints found in the loader, all of which the spike obeys:

- The `.s` must sit **directly in `r3/`** — the scan is `FS_ListFiles | FS_RootOnly`
  (`dx10ResourceManager_Scripting.cpp:470`). No subfolder.
- R3 **and R4 both** read `shaders/r3/` (`r3.h:299`, `r4.h:324`), so one copy covers
  DX10 and DX11. DX9 reads `r2/` and has a different blender API.
- Script blenders load in `OnDeviceCreate` (`ResourceManager_Loader.cpp:60`), so
  `vid_restart` should pick up an edited `.s` without a full restart.
- A name that does not resolve **does not raise**. The engine substitutes
  `stub_default` and logs nothing (`ResourceManager.cpp:340`). This is the nastiest
  property of the whole approach and the reason the spike has a mode 0.

Because the name is new rather than an override of `hud_default`, nothing else in
GAMMA is touched — Enhanced Shaders, SSS, Atmospherics and the rest all ship their
own filenames.

## 2. The depth target is nameable

`r2_RT_P` is `"$user$position"` (`Layers/xrRenderPC_R3/r2_types.h:7`), and a blender
binds it with one line — SSS does exactly this in `effects_water.s:23`. Its `.z` is
view-space depth in metres; the sampling idiom, MSAA split included, is
`SSFX_get_depth` in SSS's `screenspace_common.h:70`.

The pixel shader must take **`v2p_TL`, not `p_TL`**: the two are the same struct
except that `p_TL` has `SV_Position` commented out (`common_iostructs.h:60`), and the
screen position is how a UI pixel finds itself in the depth target. The vertex shader
(`stub_notransform_t`) emits `v2p_TL` regardless.

## 3. There is no free `shader_param` slot in GAMMA

The engine exposes eight console-settable `float4`s bound as shader constants
(`xrRender_console.cpp:1322`, `Blender_Recorder_StandartBinding.cpp:1499`). In a
stock GAMMA install **all eight are taken**:

| slot | owner |
|---|---|
| 1–4 | Enhanced Shaders — ACES slope/offset/power/contrast, driven from `appdata/grading_*.ltx` |
| 5 | BAS laser control; GAMMA Watch also writes it |
| 6 | Laser Settings |
| 7–8 | Beef's NVG |

Writing any of them visibly breaks a shipped mod. So the design cannot use them, and
per-mark data has to travel on the quad itself. Two channels do:

- **Vertex colour**, 32 bits per quad, via `SetTextureColor`. Note the vertex shader
  swizzles `bgra`, so `GetARGB(a,r,g,b)` arrives in the pixel shader as `I.Color.rgba`
  the right way round.
- **The texture rect**, via `SetTextureRect`. The engine builds `Tex0` as
  `rect / texture-resolution` with **no clamp of any kind**
  (`UIStaticItem.cpp:95`), so offsetting the rect by whole multiples of the atlas
  width shifts the *integer part* of `u` while `frac(u)` still samples the right
  atlas cell. That is a free per-quad float channel, as long as the cell does not
  straddle an integer boundary.

Which settles the intended production packing: **tint and alpha stay in the vertex
colour exactly as they are today**, and **per-mark depth rides in `Tex0`'s integer
part**. Nothing about the existing renderer's colour handling has to change.

(An earlier draft of this section justified that split by saying the route is one
colour per frame and only alpha varies per mark. That is wrong — the pulse at
`iqm_cards.script:1136` modulates each mark's RGB by its own phase, so all four
colour channels are genuinely per-mark and already spoken for. The conclusion is
unchanged and in fact forced: depth has nowhere to go *but* `Tex0`.)

## 4. What the shader would then do

`world2ui_with_depth` already hands Lua each mark's depth, so the pixel shader only
needs the scene's: occluded ⇔ `scene_depth < mark_depth - bias`. Everything else the
route currently animates in Lua per frame — flow, edge feather, distance fade — is
cheaper as pixel work once the shader exists.

## 5. The open question, and how the spike answers it

**Is `$user$position` still bound, and still holding this frame's scene, when the UI
pass runs?** It should be — the back buffer is the render target by then, so the
position RT is free to be read and nothing has overwritten it since the combine — but
"should be" is doing real work in that sentence, and being one frame stale would be
invisible in a screenshot and obvious in motion.

Run it: **F7 → Execute → the `IQM Spike:` entries.** In order:

| mode | shows | passes if |
|---|---|---|
| **0** | flat quad, hardcoded magenta | it is **magenta**. If it looks like a normal white box the name lookup missed and `stub_default` is drawing — everything below would then be meaningless. Check this first, every time. |
| **1** | scene depth as greyscale over 60 m | a recognisable depth image of what you are looking at. Black or flat grey = the RT is not bound or is empty at UI time, and the whole approach is dead. |
| **2** | red tint over everything nearer than 10 m / 40 m | the red hugs real geometry edges, **and keeps hugging them while you spin the camera hard**. Trailing = one frame stale; recoverable (budget a frame of lag) but it must be known. |
| **3** | green readback of `floor(Tex0.x)` | green at the expected brightness (carry 30 over a range of 60 ⇒ half). Proves the per-quad transport of §3 survives the UI clipper's uv interpolation. Also check it at a screen edge, where `ClipPoly` re-interpolates. |

If 0–2 pass, the occlusion rewrite is on. If 3 also passes, it can be done without
touching the colour path or asking any other mod for a `shader_param` slot.

## 6. Results

Run 2026-09-02 on l01_escape, DX11, no MSAA, driven through the DevKit bridge.
Nothing from the spike appears in the error tap — the only entries are pre-existing
noise from other mods.

| mode | result |
|---|---|
| **0** | Magenta. The custom blender resolved; `stub_default` did not eat it. |
| **1** | **Pass.** A clean, correctly-scaled depth image — NPCs dark in the foreground, the far buildings near white at the 60 m range, individual leaves resolved. `$user$position` is bound and populated during the UI pass. |
| **2** | **Pass, pixel-exact.** The near-tint follows every NPC silhouette, individual grass blades, the barrel rim and the fence posts, alpha-tested foliage edges included. No offset, no half-pixel drift. |
| **3** | **Pass, exactly.** With `range` 255 the green byte reads back as the carried integer itself: carry 10 → green 10, uniform across the frame and identical in all four corners. |

So the answer to §5 is yes on both counts, and the §3 packing works as designed.

### The one thing the spike found that the design did not account for

**Sky reads as `z = 0`, not as `z = far`.** Nothing writes the position target where
there is no geometry, so a naive `scene_depth < mark_depth` test treats every sky
pixel as an occluder sitting at the camera. Mode 2 shows this plainly: the sky is
fully tinted while the distant treetops in front of it correctly are not. The real
shader needs `z <= 0` treated as "no geometry, infinitely far" before anything else.
Cheap to handle, ugly to discover late — a route mark drawn against the skyline would
have been invisible for no visible reason.

Two smaller notes from the run:

- Black in the depth view is ambiguous between "very near" and "nothing here". Do not
  build any heuristic on darkness alone.
- Latency was not separately provable from a screenshot, and after mode 2 it does not
  need to be: the mask registers exactly against geometry in a shot taken from a live
  session, and the target is written in the same frame's G-buffer pass long before UI.

### Still unanswered after this spike

- **MSAA.** The `#ifndef USE_MSAA` branch mirrors SSS verbatim but is untested here.
- **DX9.** `shaders/r2/` needs its own blender or the mod must fall back to
  `"hud\default"` on R2. Falling back is not automatic — the miss is silent.

Closed while writing this: **rotated marks are fine.** The route's marks draw through
`EnableHeading`, i.e. `CUIStaticItem::RenderInternal(float angle)` rather than the
overload read for §3, but it builds uv from the same unclamped
`ComputeRenderUV` / `rect / ts` (`UIStaticItem.cpp:169`), differing only by a half-texel
offset. And `ComputeRenderUV` passes the rect straight through unless the widget is in
`tfCover` fit mode (`:27`), which none of ours are.
