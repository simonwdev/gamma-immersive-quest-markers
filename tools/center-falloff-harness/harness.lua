-- Harness: THE CENTRE FALLOFF (R2.58) -- markers get out of the way of the crosshair.
--
-- WHY THIS EXISTS. The feature is fifteen lines of arithmetic, and every way it can be
-- wrong is invisible on screen:
--
--   * THE ELLIPSE. The 1024x768 virtual UI is stretched to the real window, so a radius
--     measured in UI units traces an ellipse on screen rather than a circle round the
--     crosshair. On a 16:9 monitor the horizontal reach comes out a third short. Both
--     versions look plausible in play -- markers do fade near the middle either way --
--     and nothing but a numeric comparison of two markers at equal SCREEN radius can
--     tell them apart. That is case 5, and it is the reason this file exists.
--   * THE RADIUS READ AFTER THE BRANCH. draw_beacons overwrites dx/dy inside both arms
--     of its clamp (the on-screen arm sets them to a straight-down (0, 1)), so a radius
--     taken one line too late is a constant. The whole feature would then be a flat
--     dim on every unclamped marker, which again looks like a working fade.
--   * THE EXEMPTION TESTED ON prio. prio 0 is shared by the placed waypoint AND by the
--     selected task's marker, so the obvious test silently exempts the objective too --
--     removing the feature from the marker it matters most on. Case 6.
--   * THE BEHIND-CAMERA RADIUS. There the perspective divide by a negative w has already
--     mirrored the point through the origin, so its projected magnitude is noise; read it
--     and a marker parked at the screen edge fades because the NPC is behind you. Case 7.
--
-- It loads iqm_beacon FOR REAL -- no transcription -- and reads the falloff back out of
-- what draw_beacon was handed, which is the only place the two multipliers are observable.
--
-- Usage:
--   python check_lua.py --run tools/center-falloff-harness/harness.lua
--   VERBOSE=1 ... for the passing lines and the swept curve
--
-- Expected: "0 failed" and exit 0.

-- ------------------------------------------------------------------- results
local passed, failed = 0, 0
local function check(label, cond, detail)
	if cond then
		passed = passed + 1
		if os.getenv("VERBOSE") then print(string.format("  ok   %s", label)) end
	else
		failed = failed + 1
		print(string.format("  FAIL %s%s", label, detail and ("  -- " .. detail) or ""))
	end
end
local function eq(label, got, want, detail)
	check(label, got == want,
		string.format("got %s, want %s%s", tostring(got), tostring(want),
			detail and ("  (" .. detail .. ")") or ""))
end
-- Floats, compared the way a UI multiplier has to be.
local function near(label, got, want, tol, detail)
	check(label, type(got) == "number" and math.abs(got - want) <= (tol or 1e-9),
		string.format("got %s, want %s+-%s%s", tostring(got), tostring(want),
			tostring(tol or 1e-9), detail and ("  (" .. detail .. ")") or ""))
end

local here = arg and arg[0] and arg[0]:gsub("[^/\\]+$", "") or ""
local ROOT = here .. "../../"
local function slurp(rel)
	local f = io.open(ROOT .. rel, "r")
	if not f then error("cannot open " .. ROOT .. rel .. " -- run from the mod root") end
	local s = f:read("*a") f:close() return s
end

-- ---------------------------------------------------------------- engine env
local ENV = {}
ENV.pairs, ENV.ipairs, ENV.tostring, ENV.tonumber = pairs, ipairs, tostring, tonumber
ENV.type, ENV.string, ENV.table, ENV.math, ENV.os = type, string, table, math, os
ENV.setmetatable, ENV.print, ENV.pcall, ENV.select = setmetatable, print, pcall, select
ENV.error, ENV.assert, ENV.unpack = error, assert, unpack
ENV._G = ENV
ENV.printf = function() end
ENV.time_global = function() return 1000 end
ENV.RegisterScriptCallback = function() end

-- ------------------------------------------------------------------ the space
-- 1024x768 virtual UI, and a 16:9 screen -- so UI_KX is a REAL correction (0.75) rather
-- than 1. On a 4:3 screen it is exactly 1 and case 5 could not fail, which is the one
-- way this file could pass while testing nothing.
local HALF_W, HALF_H = 512, 384
local UI_KX = 0.75
-- iqm_beacon's own lift: draw_beacons projects (e.x, e.y + BEACON_LIFT, e.z), so a
-- fixture that wants a marker AT a given screen y has to subtract it.
local LIFT = 2.0

-- The projection stub is a PASS-THROUGH, deliberately, and not a pinhole camera: this file
-- is about what happens to a marker at a given point ON SCREEN, so the fixture states that
-- point directly instead of solving for a world position that lands there. So a candidate's
-- world triple means (screen x, screen y - LIFT, depth sign).
local projections = 0
local function project_off(x, y, z)
	projections = projections + 1
	return x, y, z            -- z is the SIGN, as the engine's own third component is
end

-- ------------------------------------------------------------------- the sink
-- What draw_beacon was handed, which is where the two multipliers become observable.
local drew, hid = {}, {}
local CARDS = {}
function CARDS:hide_beacon(i) hid[#hid + 1] = i end
function CARDS:draw_beacon(i, ax, ay, ndx, ndy, ang, a, mtr, cfg, size, clamped, e)
	drew[#drew + 1] = { i = i, ax = ax, ay = ay, a = a, size = size,
	                    clamped = clamped and true or false, id = e.id, tex = e.tex }
end
local function reset() drew, hid, projections = {}, {}, 0 end

-- ------------------------------------------------------------------- config
local A_FULL, SZ_FULL = 225, 24        -- beacon_a and beacon_size for every case here
local CFG = {
	beacon_color = 0,
	mark_targets = true,  mark_beacon    = true,  beacon_handin = true,
	mark_guiders = true,  beacon_guiders = true,
	mark_traders = true,  beacon_traders = true,
	beacon_waypoint = true, beacon_party = false,
	beacon_dist  = 60,
	beacon_edge  = 46,
	beacon_size  = SZ_FULL,
	beacon_a     = A_FULL,
	beacon_range = true,
	beacon_ctr   = 35,     -- radius, percent of the half screen height
	beacon_ctr_a = 20,     -- opacity floor, percent
	beacon_ctr_size = true, -- ...and whether it shrinks as well as fading
}
local R    = CFG.beacon_ctr / 100      -- the radius as the module holds it
local AMIN = CFG.beacon_ctr_a / 100
-- Mirrored from iqm_beacon, and checked against the source at the foot of this file so
-- the mirror cannot rot silently.
local CTR_IN, CTR_SMIN, CTR_Q = 0.25, 0.75, 16

ENV.iqm_core = {
	config              = function() return CFG end,
	w2u                 = function() return true end,
	-- The marker tint resolver iqm_beacon binds in apply_config (R2.63). Colour is not
	-- this harness's subject, so the stub answers the accent for everything -- which is
	-- what the real one answers in the default mode this CFG describes.
	tint                = function() return function() return nil end end,
	goal_pos            = function() return nil end,
	active_task_target  = function() return nil end,
}
ENV.iqm_cards = { project_offscreen = project_off,
                  kx = function() return UI_KX end,
                  MAX_BEACONS = 6 }

-- ------------------------------------------------------------------- module
local B = setmetatable({}, { __index = ENV })
local SRC = slurp("gamedata/scripts/iqm_beacon.script")
do
	local chunk, err = loadstring(SRC, "@iqm_beacon.script")
	assert(chunk, err)
	setfenv(chunk, B)
	local ok, perr = pcall(chunk)
	assert(ok, "iqm_beacon failed to parse: " .. tostring(perr))
end
ENV.iqm_beacon = B

do
	local ok, err = pcall(B.on_game_start)
	check("on_game_start binds the drawing space", ok, tostring(err))
	local ok2, err2 = pcall(B.apply_config)
	check("apply_config runs", ok2, tostring(err2))
end

-- ------------------------------------------------------------------ fixtures
--- Offer one marker at (sx, sy) on screen and draw the frame. Returns the draw_beacon
--  record, or nil if the marker was hidden.
local function at(sx, sy, opts)
	opts = opts or {}
	reset()
	if opts.waypoint then
		-- Through the REAL entry point, so the exemption is tested against the texture
		-- offer_waypoint actually picks rather than one this file names.
		B.offer_waypoint(9, { x = sx, y = sy - LIFT, z = opts.sign or 1 }, 40, false)
	else
		B.beacon_offer(opts.id or 1, opts.dist or 40, 1, sx, sy - LIFT, opts.sign or 1,
		               "iqm_test_glyph", opts.prio or 2, nil, nil, opts.ring or nil)
	end
	B.draw_beacons(ENV.time_global(), CARDS, opts.dim or 1)
	return drew[1]
end

-- What the module should compute, restated as arithmetic rather than transcribed control
-- flow: the point is to pin the CURVE, so the expectation has to come from the formula.
local function want_at(sx, sy)
	local dx, dy = sx - HALF_W, sy - HALF_H
	local sx2 = dx / UI_KX
	local r = math.sqrt(sx2 * sx2 + dy * dy) / HALF_H
	if r >= R then return 1, 1 end
	local inner = R * CTR_IN
	local t = (r <= inner) and 0 or ((r - inner) / (R - inner))
	t = t * t * (3 - 2 * t)
	local sz = CTR_SMIN + (1 - CTR_SMIN) * t
	return AMIN + (1 - AMIN) * t, math.floor(sz * CTR_Q + 0.5) / CTR_Q
end

-- -------------------------------------------------- 1. it runs, and it bites
do
	local d = at(HALF_W, HALF_H)
	check("a marker at the screen centre is drawn", d ~= nil)
	if d then
		eq("...unclamped", d.clamped, false)
		eq("...at the opacity floor", d.a, math.floor(A_FULL * AMIN))
		near("...and at the size floor", d.size, SZ_FULL * CTR_SMIN, 1e-9)
		check("the floor is a floor, not a hide", d.a > 2, tostring(d.a))
	end
	-- ...and the same marker well out of the radius is untouched, which is what makes the
	-- case above a comparison rather than an absolute.
	local f = at(HALF_W + 300, HALF_H)
	check("a marker far from the centre is drawn", f ~= nil)
	if f then
		eq("...at full opacity", f.a, A_FULL)
		eq("...and full size", f.size, SZ_FULL)
	end
end

-- ----------------------------------------------------- 2 + 3. the whole curve
-- Swept along X and along Y, against the formula. A sweep rather than three points
-- because the failure modes above are all SHAPE errors: a constant, an ellipse, a
-- reversed ramp. Any of them matches at some individual point.
do
	local bad_a, bad_s, n = nil, nil, 0
	local prev_a, prev_s = -1, -1
	local mono_a, mono_s = true, true
	for off = 0, 380, 4 do
		local d = at(HALF_W, HALF_H + off)          -- straight up the Y axis
		if not d then bad_a = "hidden at dy=" .. off break end
		n = n + 1
		local wa, ws = want_at(HALF_W, HALF_H + off)
		if d.a ~= math.floor(A_FULL * wa) then
			bad_a = string.format("dy=%d got a=%d want %d", off, d.a, math.floor(A_FULL * wa))
			break
		end
		if math.abs(d.size - SZ_FULL * ws) > 1e-9 then
			bad_s = string.format("dy=%d got size=%s want %s", off, tostring(d.size),
			                      tostring(SZ_FULL * ws))
			break
		end
		if d.a < prev_a then mono_a = false end
		if d.size < prev_s then mono_s = false end
		prev_a, prev_s = d.a, d.size
		if os.getenv("VERBOSE") then
			print(string.format("       dy=%3d  a=%3d  size=%6.3f", off, d.a, d.size))
		end
	end
	check("the alpha curve matches the formula along Y", bad_a == nil, bad_a)
	check("the size curve matches the formula along Y", bad_s == nil, bad_s)
	check("alpha never decreases as the marker leaves the centre", mono_a)
	check("...nor does size", mono_s)
	check("the sweep actually swept", n > 80, tostring(n))
end
do
	local bad = nil
	for off = 0, 500, 4 do
		local d = at(HALF_W + off, HALF_H)          -- ...and out along X
		local wa = select(1, want_at(HALF_W + off, HALF_H))
		if not d or d.a ~= math.floor(A_FULL * wa) then
			bad = string.format("dx=%d got a=%s want %d", off,
			                    d and tostring(d.a) or "hidden", math.floor(A_FULL * wa))
			break
		end
	end
	check("the alpha curve matches the formula along X", bad == nil, bad)
end

-- ----------------------------------------------------------- 4. the plateau
-- Everything inside CTR_IN of the radius is AT the floor, so a marker crossing the exact
-- centre does not spike through a minimum and back out.
do
	local flat = true
	local a0 = at(HALF_W, HALF_H).a
	for off = 0, math.floor(HALF_H * R * CTR_IN) - 1, 2 do
		if at(HALF_W, HALF_H + off).a ~= a0 then flat = false break end
	end
	check("the inner plateau is flat", flat)
end

-- ------------------------------------------ 5. A CIRCLE ON SCREEN, NOT AN ELLIPSE
-- THE CASE THIS FILE IS FOR. Two markers at the SAME screen radius and different angles
-- must come out identical. In UI units those two points are at different distances from
-- the centre (dx = UI_KX * dy for the same screen radius), so the ellipse bug -- reading
-- sqrt(dx^2+dy^2) without the aspect correction -- gives them different multipliers.
do
	local dy = HALF_H * R * 0.5                    -- half way out along the ramp
	local dx = UI_KX * dy                          -- the same distance, on screen
	local up   = at(HALF_W, HALF_H + dy)
	local side = at(HALF_W + dx, HALF_H)
	check("both equal-radius markers drew", up ~= nil and side ~= nil)
	if up and side then
		eq("equal screen radius gives equal opacity", side.a, up.a,
		   "the radius is being measured in UI units -- an ELLIPSE on screen, a third "
		   .. "short horizontally on 16:9. Divide dx by UI_KX first.")
		near("...and equal size", side.size, up.size, 1e-9)
		-- ...and the two points really are different in UI space, or the case above is
		-- comparing a point with itself and would pass under the bug.
		check("the fixture is not degenerate", math.abs(dx - dy) > 10,
		      string.format("dx=%.1f dy=%.1f", dx, dy))
	end
end

-- ------------------------------------------------------- 6. THE ONE EXEMPTION
do
	-- The player's own placed waypoint, dead centre, through offer_waypoint's own icon.
	local w = at(HALF_W, HALF_H, { waypoint = true })
	check("the placed waypoint is drawn at the centre", w ~= nil)
	if w then
		eq("...at FULL opacity", w.a, A_FULL,
		   "the waypoint is the mark the player placed and the one thing meant to sit "
		   .. "dead centre while they walk to it")
		eq("...and full size", w.size, SZ_FULL)
	end
	-- A waypoint dropped ON a body: that NPC's marker wearing the waypoint ring. Same
	-- mark, same exemption.
	local r = at(HALF_W, HALF_H, { ring = true })
	check("a ringed marker is drawn", r ~= nil)
	if r then eq("...and is exempt too", r.a, A_FULL) end
	-- ...and the SELECTED TASK'S marker is NOT, which is the trap: it shares prio 0 with
	-- the waypoint, so an exemption written against prio would take the objective with it.
	local t = at(HALF_W, HALF_H, { prio = 0 })
	check("a prio-0 objective marker is drawn", t ~= nil)
	if t then
		check("...and is NOT exempt", t.a < A_FULL,
		      "prio 0 is shared by offer_waypoint AND offer_task -- test the texture, "
		      .. "not the priority, or the objective marker loses the feature silently")
	end
end

-- -------------------------------------------------- 7. behind, and off screen
do
	-- Behind the camera: projected dead centre, sign negative. The magnitude there is
	-- noise, so the marker must clamp to the screen edge and take no falloff at all.
	local b = at(HALF_W, HALF_H, { sign = -1 })
	check("a marker behind the camera is drawn", b ~= nil)
	if b then
		eq("...clamped", b.clamped, true)
		eq("...at full opacity", b.a, A_FULL,
		   "the behind-camera projection is mirrored through the origin, so its radius "
		   .. "is meaningless -- reading it fades an edge marker because the NPC is behind you")
		eq("...and full size", b.size, SZ_FULL)
	end
	-- ...and an ordinary off-screen marker, parked at the edge inset.
	local o = at(HALF_W + 900, HALF_H)
	if o then
		eq("an off-screen marker is clamped", o.clamped, true)
		eq("...and untouched", o.a, A_FULL)
	end
end

-- ---------------------------------------------- 8 + 9. quantised, and only size
-- The size multiplier steps on a 1/CTR_Q grid so the badge's fractional digit tracking is
-- not re-floored against itself every frame while the player pans (the engine floors every
-- widget position to a whole screen pixel independently). Alpha is deliberately NOT
-- quantised: it has no geometry to re-floor, and stepping it is the popping the floor
-- exists to prevent.
do
	local sizes, alphas, ns, na = {}, {}, 0, 0
	local off_grid = nil
	for off = 0, math.floor(HALF_H * R) do
		local d = at(HALF_W, HALF_H + off)
		local k = d.size / SZ_FULL * CTR_Q
		if math.abs(k - math.floor(k + 0.5)) > 1e-9 then
			off_grid = string.format("dy=%d size=%s is not a %d-th of %d", off,
			                         tostring(d.size), CTR_Q, SZ_FULL)
			break
		end
		if not sizes[d.size] then sizes[d.size] = true ns = ns + 1 end
		if not alphas[d.a]   then alphas[d.a]   = true na = na + 1 end
	end
	check("every size lands on the quantisation grid", off_grid == nil, off_grid)
	check("the size takes only a few steps", ns <= CTR_Q + 1, tostring(ns))
	check("alpha is not quantised with it", na > ns * 2,
	      string.format("%d distinct alphas, %d distinct sizes", na, ns))
end

-- ------------------------------------------------------- 10. off, and hidden
do
	CFG.beacon_ctr = 0
	B.apply_config()
	local d = at(HALF_W, HALF_H)
	check("with the radius at 0 a centre marker is drawn", d ~= nil)
	if d then
		eq("...at full opacity", d.a, A_FULL, "0 must turn the whole feature off")
		eq("...and full size", d.size, SZ_FULL)
	end
	-- ...and a floor of 0 IS reachable as a full hide, which is what makes the 20 default
	-- a choice rather than a limit.
	CFG.beacon_ctr, CFG.beacon_ctr_a = 35, 0
	B.apply_config()
	reset()
	B.beacon_offer(1, 40, 1, HALF_W, HALF_H - LIFT, 1, "iqm_test_glyph", 2)
	B.draw_beacons(ENV.time_global(), CARDS, 1)
	eq("a floor of 0 hides the marker outright", #drew, 0)
	eq("...through hide_beacon, not a zero-alpha draw", #hid, 1)
	CFG.beacon_ctr_a = 20
	B.apply_config()
end

-- ------------------------------------------- 10b. fade without the shrink
-- beacon_ctr_size off: the opacity curve must be COMPLETELY unaffected and the size must
-- not move at all. Both halves matter -- an implementation that clamped the size floor to 1
-- would pass the size half while quietly flattening the alpha ramp with it, since the two
-- come out of one smoothstep.
do
	CFG.beacon_ctr_size = false
	B.apply_config()
	local held, curve_moved = true, nil
	for off = 0, math.floor(HALF_H * R), 3 do
		local d = at(HALF_W, HALF_H + off)
		if not d then held = false break end
		if d.size ~= SZ_FULL then held = false break end
		local wa = select(1, want_at(HALF_W, HALF_H + off))
		if d.a ~= math.floor(A_FULL * wa) then
			curve_moved = string.format("dy=%d got a=%s want %d", off, tostring(d.a),
			                            math.floor(A_FULL * wa))
			break
		end
	end
	check("with the shrink off the size never moves", held)
	check("...and the opacity curve is untouched", curve_moved == nil, curve_moved)
	-- ...and the centre is still at the floor, or "no shrink" has turned the whole thing off.
	local c = at(HALF_W, HALF_H)
	if c then
		eq("...the centre is still at the opacity floor", c.a, math.floor(A_FULL * AMIN))
		eq("...at full size", c.size, SZ_FULL)
	end
	-- The exemption still holds with the shrink off, since it is decided before either
	-- multiplier is computed rather than inside one of them.
	local w = at(HALF_W, HALF_H, { waypoint = true })
	if w then eq("...and the waypoint is still exempt", w.a, A_FULL) end
	CFG.beacon_ctr_size = true
	B.apply_config()
	eq("the shrink comes back", at(HALF_W, HALF_H).size, SZ_FULL * CTR_SMIN)
end

-- ---------------------------------------------- 11. it composes with the dim
-- The combat dim and the falloff are two independent multipliers on the same alpha, and
-- they must MULTIPLY rather than one winning: aiming at a marker near the crosshair is the
-- exact case both were written for, so it is the one that must not double-count or clamp.
do
	local d = at(HALF_W, HALF_H, { dim = 0.35 })
	if d then
		eq("the combat dim and the falloff compose", d.a,
		   math.floor(A_FULL * 0.35 * AMIN))
	end
end

-- ----------------------------------------------------- 12. the mirror holds
-- Cases 2-9 compute their expectations from constants restated at the top of this file. If
-- iqm_beacon's own change and this file's does not, every one of them goes on passing
-- against the wrong curve -- so the constants are read back out of the source.
do
	local function const(name)
		local v = SRC:match("local " .. name .. "%s*=%s*([%d%.]+)")
		return v and tonumber(v) or nil
	end
	eq("CTR_IN still matches the source",   const("CTR_IN"),   CTR_IN)
	eq("CTR_SMIN still matches the source", const("CTR_SMIN"), CTR_SMIN)
	eq("CTR_Q still matches the source",    const("CTR_Q"),    CTR_Q)
	-- The size floor has to sit ON the grid or CTR_SMIN is not the floor the code applies
	-- (0.7 rounds to 11/16), and every size expectation above would be a step out.
	local k = CTR_SMIN * CTR_Q
	check("the size floor lands on the quantisation grid",
	      math.abs(k - math.floor(k + 0.5)) < 1e-9,
	      string.format("CTR_SMIN * CTR_Q = %s", tostring(k)))
	-- The radius must be read BEFORE the clamp branch overwrites dx/dy. Source-level,
	-- because a radius read after it is a CONSTANT and every curve above would flatten
	-- into a uniform dim that still looks like a working fade in play.
	local i_read  = SRC:find("ctr_fade(ax, ay, UI_KX)", 1, true)
	local i_write = SRC:find("dx, dy = 0, 1", 1, true)
	check("the radius is read before the branch overwrites dx/dy",
	      i_read and i_write and i_read < i_write,
	      "ctr_fade must be called while dx/dy are still the raw offset from centre")
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed > 0 and 1 or 0)
