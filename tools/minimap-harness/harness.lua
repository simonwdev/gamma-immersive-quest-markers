-- Harness: exercise iqm_minimap's transform outside the game. Stubs the handful of engine
-- calls the module depends on -- level.map_get_object_minimap_spot_static, the spot's
-- GetAbsoluteRect / GetWndPos, and device().cam_dir -- over a SYNTHETIC minimap whose centre
-- and scale we choose, loads the REAL gamedata/scripts/iqm_minimap.script, and asserts that
-- the module recovers the numbers that were put in.
--
-- This is the test docs/minimap-route.md section 8 asks for, and it earns its keep: the
-- transform took several in-game sessions to pin down, and almost every one of those was
-- lost to a wrong assumption about the measurement rather than to anything the engine did.
-- Everything below is arithmetic on published data, so it tests offline exactly as iqm_nav
-- does, and a regression here would otherwise only show up as marks in the wrong place on
-- someone's HUD.
--
-- WHAT THE MODULE NOW MEASURES, and why the synthetic map is built the way it is:
--
--   * The CENTRE is the actor's own calibration spot, read from GetAbsoluteRect. The actor
--     sits at the map centre by construction, so this needs no movement and never freezes.
--   * The SCALE is the same spot's MAP-LOCAL position (GetWndPos), which the engine updates
--     unconditionally -- SetWndPos is called before the IsRectVisible test, and only
--     AttachChild is gated (map_location.cpp:396-414). Map-local space carries no rotation,
--     so walking N metres moves the local position by N * scale, whatever the heading.
--   * The two ABSOLUTE axis scales differ from that local scale, and from each other, only
--     by UI_KX -- the aspect correction the engine applies when it rotates the map. That is
--     display arithmetic, so it is COMPUTED rather than measured, and the fixture computes
--     it the same way to keep the expectation honest.
--
-- Usage:
--   luajit tools/minimap-harness/harness.lua
--   VERBOSE=1 luajit tools/minimap-harness/harness.lua
--
-- Expected: "0 failed" and exit 0.

-- ------------------------------------------------------------------- results
local passed, failed = 0, 0
local function check(label, cond, detail)
	if cond then
		passed = passed + 1
		print(string.format("  ok   %s", label))
	else
		failed = failed + 1
		print(string.format("  FAIL %s%s", label, detail and ("  -- " .. detail) or ""))
	end
end

local function near(a, b, eps)
	return a and b and math.abs(a - b) <= (eps or 0.01)
end

-- ---------------------------------------------------------------- engine env
local ENV = {}
ENV.pairs, ENV.ipairs, ENV.tostring, ENV.tonumber = pairs, ipairs, tostring, tonumber
ENV.type, ENV.string, ENV.table, ENV.math, ENV.os = type, string, table, math, os
ENV.setmetatable, ENV.print, ENV.pcall, ENV.select = setmetatable, print, pcall, select
ENV._G = ENV

-- printf, faithful to Anomaly's (_g.script:612): it substitutes the literal token "%s" and
-- nothing else, so a stray "%.2f" prints raw AND shifts every later argument. Same check the
-- nav, pathline and route harnesses run over their own modules.
local fmt_violations = {}
local printf_echo = os.getenv("VERBOSE") and true or false
ENV.printf = function(fmt, ...)
	fmt = tostring(fmt)
	if fmt:find("%%[^s]") then fmt_violations[#fmt_violations + 1] = fmt end
	local i, p = 0, { ... }
	local out = fmt:gsub("%%s", function() i = i + 1; return tostring(p[i]) end)
	if printf_echo then print(out) end
end

local VecMT = {}
VecMT.__index = VecMT
function VecMT:set(a, b, c)
	if type(a) == "table" then self.x, self.y, self.z = a.x, a.y, a.z
	else self.x, self.y, self.z = a, b, c end
	return self
end
-- Comparing two vectors is a CTD in game (R2.41): luabind's `vector` defines no __eq, so
-- `a == b` on two of them raises "No such operator [__eq] defined in class [vector]" and
-- takes the game down. A plain-table stub answers by identity instead and hides it, which
-- is how R2.41 reached a player. Reproduced here so the harness fails where the game does.
VecMT.__eq = function()
	error("No such operator [__eq] defined in class [vector]" ..
	      " -- compare coordinates or a distance, never two vectors", 2)
end
ENV.vector = function() return setmetatable({ x = 0, y = 0, z = 0 }, VecMT) end

local V2MT = {}
V2MT.__index = V2MT
function V2MT:set(x, y) self.x, self.y = x, y; return self end
ENV.vector2 = function() return setmetatable({ x = 0, y = 0 }, V2MT) end

local FrectMT = {}
FrectMT.__index = FrectMT
function FrectMT:set(a, b, c, d) self.x1, self.y1, self.x2, self.y2 = a, b, c, d; return self end
-- Counted, because one of the module's per-frame allocations was exactly this: a scratch
-- Frect built every frame for GetAbsoluteRect to overwrite. Nothing offline can SEE garbage,
-- so the only way to pin the hoist is to count the constructor.
local frect_calls = 0
ENV.Frect = function()
	frect_calls = frect_calls + 1
	return setmetatable({ x1 = 0, y1 = 0, x2 = 0, y2 = 0 }, FrectMT)
end

ENV.GetARGB = function(a, r, g, b) return { a = a, r = r, g = g, b = b } end

-- luabind's class(), enough of it for `class "X" (Base)` plus `super()` in __init.
ENV.super = function() end
ENV.CUIScriptWnd = { SetWndRect = function() end, Show = function() end }
ENV.class = function(name)
	return function(base)
		local c = {}
		for k, v in pairs(base or {}) do c[k] = v end
		c.__index = c
		ENV[name] = setmetatable(c, { __call = function(cls)
			local o = setmetatable({}, cls)
			if o.__init then o:__init() end
			return o
		end })
		return ENV[name]
	end
end

-- Every static the module builds, in creation order, recording what was done to it. The
-- module hands SetWndPos/SetWndSize a SHARED scratch vector2, so values are copied out here
-- rather than referenced -- referencing them would make every widget report the last one's
-- geometry, which is a bug this harness would then fail to see.
local statics = {}
local function new_static(kind)
	local w = { kind = kind, shown = false, x = 0, y = 0, w = 0, h = 0, hides = 0, heads = 0 }
	-- Show(false) is COUNTED, not just recorded. Re-hiding an already-hidden widget leaves the
	-- state identical, so a renderer doing it every frame for ever is invisible to any test
	-- that only reads `shown` -- which is precisely how it survived until someone profiled it.
	function w:Show(b)
		self.shown = b and true or false
		if not self.shown then self.hides = self.hides + 1 end
	end
	function w:SetWndSize(v) self.w, self.h = v.x, v.y end
	function w:SetWndPos(v) self.x, self.y = v.x, v.y end
	function w:SetTextureColor(c) self.argb = c end
	function w:EnableHeading(b)
		self.heading_on = b and true or false
		self.heads = self.heads + 1
	end
	function w:SetHeading(a) self.ang = a end
	statics[#statics + 1] = w
	return w
end

ENV.CScriptXmlInit = function()
	local x = {}
	function x:ParseFile() end
	function x:InitStatic(kind) return new_static(kind) end
	return x
end

local attached = 0
ENV.get_hud = function()
	return { AddDialogToRender = function() attached = attached + 1 end }
end

-- --------------------------------------------------------- synthetic minimap
-- The truth the module has to recover.
local CX, CY = 954.62, 675.84

-- The MAP-LOCAL scale: UI units per metre in the map window's own coordinates, which carry
-- no rotation. This is the one number the module measures, and it takes it off the ACTOR's
-- own spot as the player walks.
local MAP_S = 0.85

-- The two ABSOLUTE axis scales the module should end up with. They differ from MAP_S -- and
-- from each other -- only by UI_KX, the aspect correction applied when the map is rotated.
-- Computed here the same way the module computes it, from the screen size.
local screen = { w = 1920, h = 1080 }
local UI_KX = (screen.h / screen.w) / (768 / 1024)
local PPM_X, PPM_Y = MAP_S * UI_KX, MAP_S

local AC_ID = 1                       -- the actor, which carries the calibration spot
local TGT_ID = 7                      -- the route target, only ever used for its position
local world = { ax = 0, az = 0, tx = 0, tz = 10 }
local heading = 0                     -- camera heading, radians
local spot_mode = "ok"                -- ok | origin | none | huge

-- Where the map window's local origin sits. Deliberately an odd, large pair: the module only
-- ever DIFFERENCES two local readings, so the origin must cancel, and a fixture that used
-- 0,0 would hide any accidental dependence on it.
local L0X, L0Y = 1234.5, -678.9

local added, add_calls, remove_calls = {}, 0, 0
local wndpos_calls = 0
local level_name = "k00_marsh"

--- The actor's spot in MAP-LOCAL coordinates: a plain scale-and-translate of the world
--  position, with NO rotation, exactly as ConvertRealToLocal gives it.
local function local_pos()
	local k = (spot_mode == "huge") and (MAP_S * 60) or MAP_S
	return L0X + k * world.ax, L0Y - k * world.az
end

ENV.level = {
	name = function() return level_name end,
	object_by_id = function(id)
		if id == TGT_ID then
			return { position = function() return ENV.vector():set(world.tx, 0, world.tz) end }
		end
		return nil
	end,
	map_has_object_spot = function(id, spot)
		return (added[id] and added[id][spot]) and 1 or 0
	end,
	-- Adding a spot models the engine's one-frame delay (section 4.2): the widget exists
	-- immediately but has not been positioned, so the first read reports the unplaced rect at
	-- the origin. A stub that placed it instantly would hide the ordering rule entirely.
	map_add_object_spot = function(id, spot)
		added[id] = added[id] or {}
		added[id][spot] = "fresh"
		add_calls = add_calls + 1
	end,
	map_remove_object_spot = function(id, spot)
		if added[id] then added[id][spot] = nil end
		remove_calls = remove_calls + 1
	end,
	map_get_object_minimap_spot_static = function(id, spot)
		local own = added[id] and added[id][spot]
		if not own or spot_mode == "none" then return nil end

		local fresh = (own == "fresh")
		if fresh then added[id][spot] = "placed" end

		return {
			GetAbsoluteRect = function(_, r)
				-- "origin" holds the widget unplaced for ever, which is the section 4.2
				-- case stuck on: the module must never treat that rect as a measurement.
				if fresh or spot_mode == "origin" then
					r.x1, r.y1, r.x2, r.y2 = -0.5, -0.5, 0.5, 0.5
				else
					-- The actor sits at the map centre by construction, whatever it does.
					r.x1, r.y1, r.x2, r.y2 = CX - 0.5, CY - 0.5, CX + 0.5, CY + 0.5
				end
				return r
			end,
			-- Always current, even for a spot the engine would have detached: SetWndPos runs
			-- before the IsRectVisible test. This is the property the whole design rests on.
			--
			-- Counted too: it allocates a vector2, and once the scale is solved its value is
			-- dead -- calibrate() takes the centre and returns before it is looked at.
			GetWndPos = function()
				wndpos_calls = wndpos_calls + 1
				local lx, ly = local_pos()
				return ENV.vector2():set(lx, ly)
			end,
		}
	end,
}

ENV.db = { actor = {
	id = function() return AC_ID end,
	position = function() return ENV.vector():set(world.ax, 0, world.az) end,
} }

ENV.device = function()
	return {
		cam_dir = ENV.vector():set(math.sin(heading), 0, math.cos(heading)),
		width = screen.w, height = screen.h,
	}
end

-- The published route. Refilled per test; the contract is iqm_nav.script:277.
local RD = { n = 0, nc = 0, p = {}, a = {}, t = {}, cp = {}, cdx = {}, cdz = {}, ci = {} }
local route_on = false

-- Straight-line metres to the route target, and where it stands, as iqm_nav publishes them.
local nav_dist = 60
local nav_goal = nil

-- status() is still here, and it is still COUNTED, because the point is that the renderer no
-- longer calls it. It builds a fresh ~20-field hash per call and measures the snap distance on
-- the way through -- fine for the F7 dump, garbage once a frame.
local status_calls = 0
ENV.iqm_nav = {
	status = function()
		status_calls = status_calls + 1
		return { target = TGT_ID, dist = nav_dist,
		         gx = nav_goal and nav_goal[1], gz = nav_goal and nav_goal[2] }
	end,
	-- THREE return values, deliberately, and the same three fields the renderer used to dig
	-- out of status(). A consumer that reads this through `M.f and M.f()` gets only the first.
	route_target = function()
		return nav_dist, nav_goal and nav_goal[1], nav_goal and nav_goal[2]
	end,
	route_draw = function() return route_on and RD or nil end,
}

-- modxml_n_iqm_map_icons's namespace, carrying the flag it sets once it has spliced the
-- iqm_calib type into map_spots*.xml. The module refuses to add a spot of a type the engine
-- may not know, because that is an assert in CMapLocation::Load rather than a soft failure.
--
-- Modelled as a NAMESPACE TABLE and not as a bare global on purpose. Anomaly gives every
-- .script its own environment, so `x = true` in one module is `thatmodule.x` and is not
-- visible as `x` anywhere else. A harness that exposed this as a plain global would let the
-- module read it either way and would have passed while the game silently did nothing --
-- which is exactly what happened before this was fixed.
ENV.modxml_n_iqm_map_icons = { iqm_calib_declared = true }

local cb = {}
ENV.RegisterScriptCallback = function(name, fn) cb[name] = fn end

-- --------------------------------------------------------- load iqm_minimap
local here = arg and arg[0] and arg[0]:gsub("[^/\\]+$", "") or ""
local path = here .. "../../gamedata/scripts/iqm_minimap.script"
local f = io.open(path, "r")
if not f then error("cannot open " .. path .. " -- run via: luajit tools/minimap-harness/harness.lua") end
local src = f:read("*a")
f:close()

-- ------------------------------------------------------------------ iqm_util
-- The REAL shared module, not a stub. Every IQM module that logs, injects an F7
-- action or casts an occlusion ray now reads those mechanics out of iqm_util, and
-- a stub here would be testing the stub. In game the lookup loads it by itself --
-- `_G` carries an __index metamethod that calls process_file_if_exists on any
-- missing name (script_engine.cpp:340-353) and every script env inherits from
-- `_G` -- so this block is only the harness doing by hand what the engine does on
-- its own.
ENV.iqm_util = setmetatable({}, { __index = ENV })
do
	local chunk = assert(loadfile(here .. "../../gamedata/scripts/iqm_util.script"))
	setfenv(chunk, ENV.iqm_util)
	chunk()
end

local M = setmetatable({}, { __index = ENV })
local chunk, err = loadstring(src, "@iqm_minimap.script")
assert(chunk, err)
setfenv(chunk, M)
chunk()
ENV.iqm_minimap = M
M.on_game_start()

local tick = cb.actor_on_update
assert(tick, "iqm_minimap did not register actor_on_update")

-- ------------------------------------------------------------------ helpers
--- Publish a route. `pts` are the STROKE VERTICES (rd.p) -- what the minimap renderer
--  resamples. The chevron list is filled too, with a deliberately hostile alpha of 0, so
--  that any renderer which goes back to reading a[]/cp[] fails loudly here instead of
--  quietly drawing nothing in game (which is what it did).
local function set_route(pts, dirs)
	RD.n = #pts
	RD.nc = #pts
	for i = 1, #pts do
		RD.p[i] = ENV.vector():set(pts[i][1], 0, pts[i][2])
		RD.cp[i] = RD.p[i]
		RD.cdx[i] = dirs and dirs[i][1] or 0
		RD.cdz[i] = dirs and dirs[i][2] or 1
		RD.ci[i] = i
		RD.a[i] = 0        -- "fully occluded" -- must NOT reach the minimap trail
		RD.t[i] = 0
	end
	route_on = true
end

--- Every mark placed this frame, in creation order, as CENTRES plus colour.
--
--  Filtered by size, which is how the mark is told from its dark backing copy: the backing
--  is drawn 2 px larger. Pass the configured mark size.
local function marks_of(size)
	local out = {}
	for i = 1, #statics do
		local w = statics[i]
		if w.shown and near(w.w, size, 0.001) then
			out[#out + 1] = { x = w.x + w.w * 0.5, y = w.y + w.h * 0.5, a = w.argb }
		end
	end
	return out
end

local function marks() return marks_of(8) end

--- Turn a placed mark back into the world offset it claims to represent. Inverting the
--  renderer's own transform is what lets the tests assert in METRES, which is the only frame
--  in which "the trail is in the right place" is a rotation-independent claim.
local function to_world(mk)
	local ex, ey = (mk.x - CX) / PPM_X, (mk.y - CY) / PPM_Y
	local rot = -heading
	local c, s = math.cos(rot), math.sin(rot)
	-- orient() is an involution, so the same expression inverts it:
	--   ex = wx*c + wz*s,  ey = wx*s - wz*c
	return ex * c + ey * s, ex * s - ey * c
end

-- The mark styles, as iqm_minimap.STYLES keys them. Named here so a test reads as "dots" or
-- "arrows" rather than as a bare 0 or 1, and so adding a style makes the tests below fail to
-- resolve rather than silently keep testing the old one.
local ARROWS, DOTS = 0, 1

--- Read one of the module's file-scope locals through the upvalues of something it exports.
--  Nothing has to be unlocalised for a test to see it: status() closes over C, so C is
--  reachable live, and that is the only way to assert that a value is CACHED rather than
--  merely correct on screen.
local function upget(fn, name)
	for i = 1, 80 do
		local n, v = debug.getupvalue(fn, i)
		if not n then return nil end
		if n == name then return v end
	end
end

--- The overlay window itself, reached the same way: configure() closes over set_config, which
--  closes over WND. Nothing has to be unlocalised for a test to read the pool's own counters.
local function window()
	local set_cfg = upget(M.configure, "set_config")
	return set_cfg and upget(set_cfg, "WND") or nil
end

local function reset(opts)
	-- Switch off and run a frame FIRST, so the module takes its own spot back off and
	-- forgets it. Clearing `added` underneath a module that still believes its spot is
	-- placed would leave it reading a widget the fixture no longer has -- which looks
	-- exactly like a calibration bug and is not one.
	M.configure({ on = false })
	tick()

	statics = {}
	route_on = false
	RD.nc, RD.n = 0, 0
	spot_mode = "ok"
	added, add_calls, remove_calls = {}, 0, 0
	ENV.modxml_n_iqm_map_icons.iqm_calib_declared = true
	nav_dist = 60
	nav_goal = nil
	heading = 0
	world.ax, world.az, world.tx, world.tz = 0, 0, 0, 10
	M.configure(opts or { on = true, size = 8, style = DOTS })
	M.debug_recalibrate()
end

--- Walk far enough for the scale to solve. No direction matters and no other object need
--  exist -- which is the entire point of measuring off the actor.
local function calibrate_normally()
	world.ax, world.az = 0, 0
	tick()                       -- places the spot; its rect is not positioned yet
	tick()                       -- the anchor reading
	world.ax, world.az = 0, 6
	tick()                       -- 6 m walked -> solve
end

-- ------------------------------------------------------------------- tests
print("-- calibration off the actor ----------------------------------")

reset()
tick()
tick()
check("standing still does not solve the scale", M.status().ok == false)
check("...but the spot goes on the ACTOR", (added[AC_ID] or {})["iqm_calib"] ~= nil)
check("...and on nothing else", added[TGT_ID] == nil)

calibrate_normally()
local st = M.status()
check("solve recovers the map-local scale", near(st.s, MAP_S, 0.001),
      "got " .. tostring(st.s) .. " want " .. tostring(MAP_S))
check("...and derives the X axis scale", near(st.px, PPM_X, 0.001),
      "got " .. tostring(st.px) .. " want " .. tostring(PPM_X))
check("...and the Y axis scale", near(st.py, PPM_Y, 0.001),
      "got " .. tostring(st.py) .. " want " .. tostring(PPM_Y))
check("the two axis scales are kept apart", not near(st.px, st.py, 0.01))
check("centre comes straight off the actor's spot",
      near(st.cx, CX, 0.01) and near(st.cy, CY, 0.01),
      tostring(st.cx) .. "," .. tostring(st.cy))
check("transform is marked valid", st.ok == true)

-- The centre needs no movement at all: it IS the actor's spot. Only the scale waits.
reset()
tick()
tick()
check("the centre is known before the scale is",
      near(M.status().cx, CX, 0.01) and M.status().ok == false)

-- Walking in ANY direction solves it. Map-local space carries no rotation, so there is no
-- axis that has to be exercised separately and no heading that fails -- which is what makes
-- this work with nothing nearby.
for _, h in ipairs({ 0, 0.9, 2.5, -1.7 }) do
	reset()
	heading = h
	world.ax, world.az = 0, 0
	tick(); tick()
	world.ax, world.az = 5, 0      -- due east only
	tick()
	check("solves at heading " .. tostring(h) .. " walking one way only",
	      M.status().ok == true and near(M.status().s, MAP_S, 0.001),
	      tostring(M.status().s))
end

-- No nearby object exists in ANY of these fixtures: level.object_by_id only answers for the
-- route target, and that is never asked for a spot. Stated as its own assertion because it
-- is the property that was missing for the whole of the previous design.
reset()
calibrate_normally()
check("calibrated with no object near the player at all", M.status().ok == true)
check("...having read exactly one spot, the actor's own",
      add_calls == 1 and (added[AC_ID] or {})["iqm_calib"] ~= nil)

print("-- refusing bad measurements ----------------------------------")

reset()
spot_mode = "origin"
calibrate_normally()
check("an unplaced rect at the origin is refused (section 4.2)", M.status().ok == false)

reset()
spot_mode = "none"
calibrate_normally()
check("no spot means no solve, not a wrong one", M.status().ok == false)

reset()
spot_mode = "huge"
calibrate_normally()
check("a scale outside the sane band is refused", M.status().ok == false)

reset()
world.ax, world.az = 0, 0
tick(); tick()
world.ax, world.az = 0, 2      -- under MOVE_SEP
tick()
check("too little walking does not solve", M.status().ok == false)

-- Regression test for the namespace trap. modxml_n_iqm_map_icons sets its flag with a bare
-- assignment, which Anomaly scopes to that script's own environment table -- so the flag is
-- modxml_n_iqm_map_icons.iqm_calib_declared and NEVER a global of that name. Reading it bare
-- returned nil forever: DXML ran, logged success, and the trail silently never calibrated.
reset()
ENV.modxml_n_iqm_map_icons.iqm_calib_declared = false
ENV.iqm_calib_declared = true      -- a bare global of the same name, which must NOT count
calibrate_normally()
check("reads the flag from the script namespace, not a bare global", add_calls == 0)
check("...and so stays uncalibrated", M.status().ok == false)
ENV.iqm_calib_declared = nil

print("-- placement --------------------------------------------------")

-- The trail is RESAMPLED from the stroke vertices at a fixed screen spacing, not drawn one
-- mark per published chevron. Spacing is size * 1.4 = 11.2 UI units at the default size,
-- which at PPM_Y is 13.18 m of world per mark.
local STEP = 8 * 1.4

reset()
calibrate_normally()
statics = {}
world.ax, world.az = 0, 0
set_route({ { 0, 30 } })
tick()
local m = marks()
check("marks are drawn along the route", #m >= 2, "got " .. tostring(#m))

check("the first mark sits on the player",
      m[1] and near(m[1].x, CX, 0.01) and near(m[1].y, CY, 0.01),
      m[1] and (tostring(m[1].x) .. "," .. tostring(m[1].y)) or "no marks")

-- Even spacing. The route runs due north, so marks step in -y by exactly STEP. The LAST mark
-- is excluded: it is the closing mark placed on the end of the trail, which lands wherever
-- the trail ends rather than on the next whole step.
local spaced = #m >= 3
for i = 2, #m - 1 do
	if not near(m[i].y - m[i - 1].y, -STEP, 0.05) then spaced = false end
end
check("marks are evenly spaced in PIXELS, not at chevron spacing", spaced)

-- The published alpha is 0 (fully occluded) for every vertex. A trail that still borrowed it
-- would be invisible; the minimap ignores occlusion entirely and draws opaque, since marks
-- are culled before the map edge and there is no boundary left to soften.
local opaque = #m > 0
for i = 1, #m do
	if not (m[i].a and m[i].a.a and m[i].a.a == 255) then opaque = false end
end
check("marks are fully opaque -- no occlusion alpha, no rim ramp", opaque)

-- THE regression test for marks swinging with the camera. The same world route is drawn at
-- four headings; every mark must land on the same ground each time. A renderer using one
-- scalar for both axes passes at heading 0 (the route runs due north, so only y is
-- exercised) and drifts at every other heading.
local base, stable = nil, true
for _, h in ipairs({ 0, 0.7, 1.9, -2.4 }) do
	reset()
	heading = h
	calibrate_normally()
	statics = {}
	world.ax, world.az = 0, 0
	set_route({ { 0, 20 } })
	tick()
	local got = {}
	for _, mk in ipairs(marks()) do
		local wx, wz = to_world(mk)
		got[#got + 1] = { wx, wz }
	end
	if not base then
		base = got
		if #got < 2 then stable = false end
	elseif #got ~= #base then
		stable = false
	else
		for i = 1, #got do
			if not (near(got[i][1], base[i][1], 0.05) and near(got[i][2], base[i][2], 0.05)) then
				stable = false
			end
		end
	end
end
check("marks land on the same ground at every camera heading", stable)

-- The same claim from the other side: a route running due EAST must use the X scale.
reset()
calibrate_normally()
statics = {}
world.ax, world.az = 0, 0
heading = 0
set_route({ { 20, 0 } })
tick()
local em = marks()
local east_ok = #em >= 2
for i = 1, #em do
	if not near(em[i].y, CY, 0.01) then east_ok = false end
end
check("an eastward route uses the X scale, not the Y one", east_ok)
check("...and steps by the X scale",
      em[2] and near(em[2].x - em[1].x, (STEP / PPM_Y) * PPM_X, 0.05),
      em[2] and tostring(em[2].x - em[1].x) or "too few")

print("-- mark styles ------------------------------------------------")

-- Arrows are re-headed every frame: the map is heading-up, so a fixed world bearing rotates
-- under it (section 8.1). Dots have no direction to state and must not pay for one.
reset({ on = true, size = 8, style = ARROWS })
calibrate_normally()
statics = {}
set_route({ { 0, 30 } })
tick()
local headed, arrow_kind = false, true
for i = 1, #statics do
	if statics[i].shown then
		if statics[i].ang then headed = true end
		if not statics[i].kind:find("^route_arrow") then arrow_kind = false end
	end
end
check("arrow style sets a heading on the mark", headed)
check("...and builds its marks from the arrow widgets", arrow_kind)

reset({ on = true, size = 8, style = DOTS })
calibrate_normally()
statics = {}
set_route({ { 0, 30 } })
tick()
local dot_kind, dot_headed, dots = true, false, 0
for i = 1, #statics do
	if statics[i].shown then
		dots = dots + 1
		if not statics[i].kind:find("^minimap_dot") then dot_kind = false end
		if statics[i].ang or statics[i].heading_on then dot_headed = true end
	end
end
check("dot style builds its marks from the dot widgets", dot_kind and dots > 0,
      "shown " .. tostring(dots))
check("...and sets no heading on them at all", dot_headed == false)

-- ONE widget per mark, not the glyph-plus-backing pair. iqm_dot carries its keyline, and a
-- separate backing at this size is both oversized and independently pixel-rounded, which is
-- what made the ring read as heavy and off centre. Counted against the marks the renderer
-- says it drew, so a backing sneaking back in fails here rather than in a screenshot.
check("...and one widget per mark, with no separate backing", dots == #marks(),
      "shown " .. tostring(dots) .. " for " .. tostring(#marks()) .. " marks")

-- Switching style has to DUMP the widget pool. The widget a mark is built from is chosen once,
-- at creation, so a pool carried across a style change would keep drawing the old glyph until
-- the trail happened to want more marks than it had -- which reads as the option doing nothing.
M.configure({ on = true, size = 8, style = ARROWS })
statics = {}
tick()
local swapped = false
for i = 1, #statics do
	if statics[i].shown and statics[i].kind:find("^route_arrow") then swapped = true end
end
check("changing style rebuilds the marks in the new one", swapped)
check("...and status reports the style it was given",
      M.status().style == ARROWS and M.status().style_name == "arrows")

-- A value no style answers to -- a stale MCM entry, or one written by a later version -- must
-- fall back rather than index nil and take the whole trail down.
reset({ on = true, size = 8, style = 99 })
calibrate_normally()
statics = {}
set_route({ { 0, 30 } })
tick()
check("an unknown style falls back to the default instead of erroring", #marks() > 0)

print("-- mark colour ------------------------------------------------")

-- White unless asked otherwise: the trail drew white before it had an option, so a config
-- with no colour in it has to look exactly as it did.
reset({ on = true, size = 8, style = DOTS })
calibrate_normally()
statics = {}
set_route({ { 0, 30 } })
tick()
local m1 = marks()[1]
check("with no colour configured the marks are white",
	m1 and m1.a and m1.a.r == 255 and m1.a.g == 255 and m1.a.b == 255,
	m1 and m1.a and (m1.a.r .. "," .. m1.a.g .. "," .. m1.a.b))
check("...at full alpha, since the marks are opaque (section 6f)",
	m1 and m1.a and m1.a.a == 255, m1 and m1.a and tostring(m1.a.a))

-- ...and a configured tint reaches every mark, not just the first.
reset({ on = true, size = 8, style = DOTS, r = 40, g = 172, b = 66 })
calibrate_normally()
statics = {}
set_route({ { 0, 30 } })
tick()
local all_tinted, n_marks, alpha_ok = true, 0, true
for _, mk in ipairs(marks()) do
	n_marks = n_marks + 1
	if not (mk.a and mk.a.r == 40 and mk.a.g == 172 and mk.a.b == 66) then all_tinted = false end
	if not (mk.a and mk.a.a == 255) then alpha_ok = false end
end
check("a configured colour reaches every mark", all_tinted and n_marks > 1,
	tostring(n_marks) .. " marks")
check("...and does not touch their alpha", alpha_ok)

-- The arrow style's backing is the mark's OUTLINE, not part of it: tinting that too would
-- turn a dark rim into a second coloured sprite 2 px larger, i.e. a halo.
reset({ on = true, size = 8, style = ARROWS, r = 40, g = 172, b = 66 })
calibrate_normally()
statics = {}
set_route({ { 0, 30 } })
tick()
local backs, black = 0, true
for _, mk in ipairs(marks_of(10)) do      -- the backing is drawn size + 2
	backs = backs + 1
	if not (mk.a and mk.a.r == 0 and mk.a.g == 0 and mk.a.b == 0 and mk.a.a == 178) then
		black = false
	end
end
check("the arrow backing stays black behind a tinted mark", backs > 0 and black,
	tostring(backs) .. " backings")

-- A colour change takes effect on the NEXT FRAME and needs no pool dump, unlike a style
-- change: the tint is applied per mark in place() rather than baked in at creation. That is
-- what makes dragging the sliders in MCM show the trail changing as you drag.
local before = #marks_of(8)
M.configure({ on = true, size = 8, style = ARROWS, r = 246, g = 204, b = 0 })
statics = {}
tick()
local live = marks_of(8)[1]
check("a colour change applies on the next frame", live and live.a and live.a.r == 246
	and live.a.g == 204 and live.a.b == 0,
	live and live.a and (live.a.r .. "," .. live.a.g .. "," .. live.a.b))
check("...with the trail still drawn (no pool left empty by it)", #marks_of(8) == before,
	tostring(#marks_of(8)) .. " vs " .. tostring(before))

print("-- placement, continued ---------------------------------------")

reset({ on = true, size = 4, style = DOTS })
calibrate_normally()
statics = {}
world.ax, world.az = 0, 0
set_route({ { 0, 30 } })
tick()
local m4 = marks_of(4)
local ok4 = #m4 >= 3
for i = 2, #m4 - 1 do
	if not near(m4[i].y - m4[i - 1].y, -(4 * 1.4), 0.05) then ok4 = false end
end
check("spacing follows the mark size", ok4, "marks: " .. tostring(#m4))

reset({ on = false, size = 8, style = DOTS })
calibrate_normally()
statics = {}
set_route({ { 0, 30 } })
tick()
local off = true
for i = 1, #statics do if statics[i].shown then off = false end end
check("switched off draws nothing at all", off)
check("...and the actor's spot is taken back off", (added[AC_ID] or {})["iqm_calib"] == nil)

print("-- culling and the ends of the trail --------------------------")

reset()
calibrate_normally()
statics = {}
world.ax, world.az = 0, 0
set_route({ { 0, 200 }, { 0, 400 } })
tick()
local far = false
for _, mk in ipairs(marks()) do
	local wx, wz = to_world(mk)
	if math.sqrt(wx * wx + wz * wz) > 50 then far = true end
end
check("nothing is drawn beyond the map radius", far == false)

reset()
calibrate_normally()
statics = {}
world.ax, world.az = 0, 0
set_route({ { 0, 30 } })
tick()
local tail = marks()
local endz = select(2, to_world(tail[#tail]))
check("the last mark sits at the end of the trail, not a step short",
      near(endz, 30, 0.2), "ended at " .. tostring(endz) .. " m of 30")

reset()
calibrate_normally()
statics = {}
world.ax, world.az = 0, 0
set_route({ { 0, 20 } })
nav_goal = { 0, 34 }
tick()
tail = marks()
local gz = select(2, to_world(tail[#tail]))
check("a mark lands on the target itself", near(gz, 34, 0.2),
      "last mark at " .. tostring(gz) .. " m, target at 34")

reset()
calibrate_normally()
statics = {}
world.ax, world.az = 0, 0
set_route({ { 0, 20 } })
nav_goal = { 0, 400 }
tick()
local out = false
for _, mk in ipairs(marks()) do
	local wx, wz = to_world(mk)
	if math.sqrt(wx * wx + wz * wz) > 50 then out = true end
end
check("a target off the map is not marked at the rim", out == false)

-- A trail only a few metres long is a smudge under the player arrow. Its own gate, well
-- clear of iqm_nav's ARRIVE_D of 4 m, because the ground line at that range is still useful
-- and the trail is not.
reset()
calibrate_normally()
statics = {}
world.ax, world.az = 0, 0
set_route({ { 0, 30 } })
nav_dist = 6
tick()
check("the trail hides once the target is close", #marks() == 0)
nav_dist = 14
tick()
check("...and comes back once it is not", #marks() > 0)

print("-- cache invalidation -----------------------------------------")

reset()
calibrate_normally()
check("calibrated before the change", M.status().ok == true)
level_name = "l01_escape"
tick()
check("a level change drops the transform", M.status().ok == false)
level_name = "k00_marsh"

reset()
calibrate_normally()
screen.w, screen.h = 2560, 1440
tick()
check("a resolution change drops the transform", M.status().ok == false)
screen.w, screen.h = 1920, 1080

print("-- per-frame work: hiding --------------------------------------")

-- hide_from used to walk to `built`, the pool's HIGH-WATER MARK, which never shrinks. So once
-- a long trail had been drawn, every later frame re-hid every widget above the current count
-- -- including, for ever after, the idle frames where the count is zero. Nothing about the
-- rendered picture changes, which is why only a call COUNT can see it.
reset()
calibrate_normally()
statics = {}
world.ax, world.az = 0, 0
set_route({ { 0, 60 } })
tick()
local long_n = #marks()
check("a long trail is drawn, to fill the pool", long_n >= 3, tostring(long_n))

-- A SHORTER trail next. The marks above the new count were visible a frame ago, so they must
-- all be hidden exactly once.
for i = 1, #statics do statics[i].hides = 0 end
set_route({ { 0, 20 } })
tick()
local short_n = #marks()
local hides = 0
for i = 1, #statics do hides = hides + statics[i].hides end
check("a shorter trail hides exactly the marks that were showing",
      short_n > 0 and short_n < long_n and hides == long_n - short_n,
      tostring(hides) .. " hides for " .. tostring(long_n) .. " -> " .. tostring(short_n))

-- ...and the SAME trail again must hide nothing at all. This is the assertion the old code
-- fails: it would re-hide long_n - short_n already-hidden widgets, every frame, for ever.
for i = 1, #statics do statics[i].hides = 0 end
tick()
hides = 0
for i = 1, #statics do hides = hides + statics[i].hides end
check("...and re-drawing the same trail re-hides nothing", hides == 0,
      tostring(hides) .. " redundant Show(false) calls")

-- The idle case, which is the one that runs for ever: no route at all.
route_on = false
for i = 1, #statics do statics[i].hides = 0 end
tick()
hides = 0
local visible = 0
for i = 1, #statics do
	hides = hides + statics[i].hides
	if statics[i].shown then visible = visible + 1 end
end
check("going idle hides the marks that were showing, and only those", hides == short_n,
      tostring(hides) .. " hides for " .. tostring(short_n) .. " shown")
check("...leaving nothing visible", visible == 0, tostring(visible) .. " still shown")

for i = 1, #statics do statics[i].hides = 0 end
tick()
tick()
hides = 0
for i = 1, #statics do hides = hides + statics[i].hides end
check("...and two further idle frames touch nothing at all", hides == 0,
      tostring(hides) .. " Show(false) calls on an idle frame")

-- A pool dump throws the widgets away, so the shown counter has to go with them. Left behind,
-- it points into a pool that no longer exists: the next SHORTER trail walks it and indexes a
-- nil mark, and until it does the new pool's marks are stranded visible.
reset({ on = true, size = 8, style = DOTS })
calibrate_normally()
statics = {}
world.ax, world.az = 0, 0
set_route({ { 0, 60 } })
tick()
local WNDREF = window()
local before_dump = #marks()
M.configure({ on = true, size = 8, style = ARROWS })      -- dumps the pool

-- The dump has to hide the outgoing widgets before it lets go of them: nothing else holds a
-- reference, so anything left showing is orphaned on the HUD for the rest of the session.
local orphans = 0
for i = 1, #statics do if statics[i].shown then orphans = orphans + 1 end end
check("a pool dump hides the widgets it is throwing away", orphans == 0,
      tostring(orphans) .. " orphaned widgets left showing")

-- ...and the counter that indexes the pool goes with it. Stated directly rather than only
-- through behaviour: hide_from walks marks 1..shown_n, so a counter surviving a dump indexes
-- a nil mark on the very next shorter trail.
check("...and the shown counter goes back to zero with it",
      WNDREF ~= nil and WNDREF.shown_n == 0,
      WNDREF and tostring(WNDREF.shown_n) or "no window reachable")

statics = {}
set_route({ { 0, 20 } })
local dump_ok, dump_err = pcall(tick)
check("a style change resets the shown counter along with the pool", dump_ok,
      tostring(dump_err))
local after_dump = dump_ok and #marks() or -1
check("...and the shorter trail after it strands nothing visible",
      after_dump > 0 and after_dump < before_dump,
      tostring(after_dump) .. " of " .. tostring(before_dump))

print("-- per-frame work: the target read ----------------------------")

-- The renderer wants three fields -- distance, gx, gz -- and used to build a whole status()
-- hash once a frame to get them. route_target() returns exactly those three.
reset()
calibrate_normally()
statics = {}
world.ax, world.az = 0, 0
set_route({ { 0, 30 } })
nav_goal = { 0, 34 }
status_calls = 0
tick()
check("Refresh reads the target through route_target(), not status()", status_calls == 0,
      tostring(status_calls) .. " status() calls")
check("...and still marks the target with it", #marks() > 0 and
      near(select(2, to_world(marks()[#marks()])), 34, 0.2))

-- The multiple-return trap, checked in the SOURCE because it cannot be seen any other way:
-- `local a, b, c = M.f and M.f()` is an expression, and an expression truncates a multiple
-- return to ONE value. The distance would survive and the goal would silently vanish.
check("route_target is not called through an `and` expression",
      src:find("route_target%s+and") == nil and
      src:find("=%s*iqm_nav%s*and%s*iqm_nav%.route_target") == nil)

-- The near gate still fires, and it now fires FIRST -- before route_limit's scan, which was
-- being run for a trail that was about to be hidden.
nav_goal = nil
nav_dist = 6
tick()
check("the near gate still hides the trail, read through route_target()", #marks() == 0)
nav_dist = 14
tick()
check("...and releases it again", #marks() > 0)

-- nil distance is not the near case: it means no target has resolved yet, and the published
-- route is still worth drawing.
nav_dist = nil
tick()
check("a nil distance draws rather than hides", #marks() > 0)
nav_dist = 60

print("-- per-frame work: calibration --------------------------------")

-- cal_key() built and interned a string every frame to detect two events that never happen.
-- The three components are compared instead -- and all three, independently.
reset()
calibrate_normally()
check("the printable key survives for status() and the F7 dump",
      type(M.status().key) == "string", tostring(M.status().key))

reset()
calibrate_normally()
level_name = "l01_escape"
tick()
check("a level change alone drops the transform", M.status().ok == false)
level_name = "k00_marsh"

reset()
calibrate_normally()
screen.w = 2560                          -- width only; the height is untouched
tick()
check("a width-only resolution change drops the transform", M.status().ok == false)
screen.w = 1920

reset()
calibrate_normally()
screen.h = 1200                          -- height only; the width is untouched
tick()
check("a height-only resolution change drops the transform", M.status().ok == false)
screen.h = 1080

-- Once the scale is solved, actor_read stops reading the map-local position: calibrate() takes
-- the centre and returns before it would look at it, so the read was an allocated vector2 for
-- a dead value. The return ARITY changes with it, which is why the guard is keyed on the
-- centre and not on the local coordinates -- and the centre must still be live.
reset()
calibrate_normally()
wndpos_calls = 0
tick()
tick()
check("the map-local position is not read once the scale is solved", wndpos_calls == 0,
      tostring(wndpos_calls) .. " GetWndPos calls")

local saved_cx, saved_cy = CX, CY
CX, CY = 700.25, 400.5                   -- a HUD rescale, mid-session
tick()
check("...but the centre is still re-read every frame",
      near(M.status().cx, 700.25, 0.01) and near(M.status().cy, 400.5, 0.01),
      tostring(M.status().cx) .. "," .. tostring(M.status().cy))
check("...and the solved scale is untouched by that",
      M.status().ok == true and near(M.status().s, MAP_S, 0.001))
CX, CY = saved_cx, saved_cy

-- The scratch Frect. GetAbsoluteRect fills whatever it is handed and the edges are read on the
-- next line, so a fresh one per frame is pure garbage.
reset()
calibrate_normally()
statics = {}
set_route({ { 0, 30 } })
tick()
frect_calls = 0
tick()
tick()
check("no Frect is allocated on a drawing frame", frect_calls == 0,
      tostring(frect_calls) .. " Frect() calls over two frames")

print("-- per-frame work: per-mark constants -------------------------")

-- The tint is packed on the CONFIG, not per mark per frame: place() runs up to 26 times a
-- frame and GetARGB's answer cannot have changed between two of them.
local CFG = upget(M.status, "C")
check("the module's config is reachable for inspection", type(CFG) == "table")

reset({ on = true, size = 8, style = DOTS, r = 246, g = 204, b = 0 })
calibrate_normally()
check("the tint is packed once, on the config",
      CFG and CFG.argb and CFG.argb.r == 246 and CFG.argb.g == 204 and CFG.argb.b == 0
      and CFG.argb.a == 255,
      CFG and CFG.argb and (CFG.argb.r .. "," .. CFG.argb.g .. "," .. CFG.argb.b))

statics = {}
set_route({ { 0, 30 } })
tick()
local packed = CFG.argb
local same = #marks() > 0
for _, mk in ipairs(marks()) do
	if mk.a ~= packed then same = false end
end
check("...and place() hands out that same packed value rather than repacking", same)

-- A config change has to repack it, or the sliders would move and nothing would happen.
M.configure({ on = true, size = 8, style = DOTS, r = 1, g = 2, b = 3 })
check("a config change repacks the tint",
      CFG.argb.r == 1 and CFG.argb.g == 2 and CFG.argb.b == 3 and CFG.argb.a == 255,
      CFG.argb.r .. "," .. CFG.argb.g .. "," .. CFG.argb.b)
statics = {}
tick()
local live_mk = marks()[1]
check("...and it reaches the marks on the next frame",
      live_mk and live_mk.a and live_mk.a.r == 1 and live_mk.a.g == 2 and live_mk.a.b == 3)

-- EnableHeading is a property of the widget and of the style it was built from, so it is set
-- ONCE at creation. SetHeading stays per frame -- the map is heading-up.
reset({ on = true, size = 8, style = ARROWS })
calibrate_normally()
statics = {}
set_route({ { 0, 30 } })
tick()
local built_heads, arrows_n = 0, 0
for i = 1, #statics do
	if statics[i].shown then
		arrows_n = arrows_n + 1
		built_heads = built_heads + statics[i].heads
	end
end
check("arrows enable heading exactly once each, at creation",
      arrows_n > 0 and built_heads == arrows_n,
      tostring(built_heads) .. " EnableHeading calls for " .. tostring(arrows_n) .. " widgets")

local before_heads = built_heads
tick()
tick()
built_heads = 0
for i = 1, #statics do
	if statics[i].shown then built_heads = built_heads + statics[i].heads end
end
check("...and two further frames re-enable nothing", built_heads == before_heads,
      tostring(built_heads) .. " vs " .. tostring(before_heads))

local re_headed = true
for i = 1, #statics do
	if statics[i].shown and statics[i].ang == nil then re_headed = false end
end
check("...while SetHeading still runs per frame (the map is heading-up)", re_headed)

print("-- logging contract -------------------------------------------")

reset({ on = true, size = 8, style = DOTS, debug = true })
calibrate_normally()
M.debug_state()
M.debug_recalibrate()
M.debug_state()
check("printf uses only %s", #fmt_violations == 0,
      fmt_violations[1] and ("first offender: " .. fmt_violations[1]) or nil)

-- ------------------------------------------------------------------ summary
print("")
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed > 0 and 1 or 0)
