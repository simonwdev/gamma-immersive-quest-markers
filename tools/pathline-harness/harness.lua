-- Harness: the world-space polyline, and specifically its TWO CHANNELS.
--
-- WHY THIS EXISTS. iqm_pathline had no harness at all, because it draws through
-- debug_render and "you cannot test a renderer offline" felt obviously true. It is not:
-- everything that decides what appears on screen -- how many gizmos, where their endpoints
-- are, what colour each one is, which point each is culled against -- is arithmetic, and
-- only the final add_object is the engine's. A stub for that one call makes the rest
-- testable, and the two-channel change (R2.33q) is exactly the kind that needs it: it
-- rewrites every pa/pb index in the segment builder, and an off-by-base there would cull
-- one path against the other path's visibility -- invisible in a screenshot, and wrong.
--
-- Two regressions reached the player unverified in this session. This is the answer to
-- that, not an apology for it.
--
-- Usage:
--   python check_lua.py --run tools/pathline-harness/harness.lua
--   VERBOSE=1 ... for the passing lines too

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

-- ---------------------------------------------------------------- engine env
local ENV = {}
ENV.pairs, ENV.ipairs, ENV.tostring, ENV.tonumber = pairs, ipairs, tostring, tonumber
ENV.type, ENV.string, ENV.table, ENV.math, ENV.os = type, string, table, math, os
ENV.setmetatable, ENV.print, ENV.pcall, ENV.select = setmetatable, print, pcall, select
ENV.error, ENV.assert, ENV.unpack = error, assert, unpack
ENV._G = ENV
ENV.printf = function() end
ENV.RegisterScriptCallback = function() end

local VecMT = {}
VecMT.__index = VecMT
function VecMT:set(a, b, c)
	if type(a) == "table" then self.x, self.y, self.z = a.x, a.y, a.z
	else self.x, self.y, self.z = a, b, c end
	return self
end
function VecMT:distance_to(o)
	local dx, dy, dz = o.x - self.x, o.y - self.y, o.z - self.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
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

-- fcolor: the engine's float colour. Recorded by VALUE so a check can ask what colour a
-- segment came out, which is the whole of "are the two channels tinted apart".
local ColMT = {}
ColMT.__index = ColMT
function ColMT:set(r, g, b, a) self.r, self.g, self.b, self.a = r, g, b, a; return self end
ENV.fcolor = function() return setmetatable({ r = 0, g = 0, b = 0, a = 1 }, ColMT) end

ENV.device = function() return { cam_pos = ENV.vector():set(0, 1.6, -10) } end
ENV.time_global = function() return 0 end
ENV.main_hud_shown = function() return true end

-- THE GIZMO QUEUE. add_object hands back a line object; the module writes endpoints, a
-- colour and a visibility flag through it. Everything drawn is observable here.
local gizmos = {}
local LineMT = {}
LineMT.__index = LineMT
function LineMT:cast_dbg_line() return self end
function LineMT:set_matrix() end
ENV.DBG_ScriptObject = { line = "line" }
ENV.debug_render = {
	add_object = function(id, kind)
		local g = setmetatable({ id = id, visible = false, hud = false }, LineMT)
		gizmos[id] = g
		return g
	end,
	get_object = function(id) return gizmos[id] end,
	remove_object = function(id) gizmos[id] = nil end,
}

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
	local chunk = assert(loadfile("gamedata/scripts/iqm_util.script"))
	setfenv(chunk, ENV.iqm_util)
	chunk()
end

-- ------------------------------------------------------------------ load it
local M = setmetatable({}, { __index = ENV })
do
	local f = assert(io.open("gamedata/scripts/iqm_pathline.script", "r"))
	local src = f:read("*a")
	f:close()
	local chunk, err = loadstring(src, "@iqm_pathline.script")
	assert(chunk, err)
	setfenv(chunk, M)
	local ok, perr = pcall(chunk)
	assert(ok, "iqm_pathline failed to parse: " .. tostring(perr))
end

local function V(x, z) return ENV.vector():set(x, 0, z) end
local function line(x0, x1, z, n)
	local t = {}
	for i = 0, n - 1 do t[i + 1] = V(x0 + (x1 - x0) * i / (n - 1), z) end
	return t
end

-- Colours actually written to gizmos, as a set of "r,g,b" keys.
local function drawn_colours()
	local seen = {}
	for _, g in pairs(gizmos) do
		if g.visible and g.color then
			seen[string.format("%.2f,%.2f,%.2f", g.color.r, g.color.g, g.color.b)] = true
		end
	end
	return seen
end
local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
local function visible_gizmos()
	local n = 0
	for _, g in pairs(gizmos) do if g.visible then n = n + 1 end end
	return n
end

local OPTS = { snap = false, rails = 2, width = 0.3, cull = false, arrows = 0, ties = 0 }

-- ==========================================================================
print("-- one channel still behaves ----------------------------------------")

check("show() is available", type(M.show) == "function")
local ok1 = M.show(line(0, 20, 0, 5), OPTS)
check("a single polyline draws", ok1 and ok1 > 0, tostring(ok1))
check("...and puts gizmos in the queue", visible_gizmos() > 0, tostring(visible_gizmos()))
check("...in exactly one colour", count(drawn_colours()) == 1,
	tostring(count(drawn_colours())))
local one_ch = visible_gizmos()

-- ==========================================================================
print("\n-- two channels at once (R2.33q) -------------------------------------")

local RED   = { r = 1.0, g = 0.30, b = 0.15 }
local GREEN = { r = 0.35, g = 0.95, b = 0.45 }

local n = M.show_channels({
	{ points = line(0, 20, 0, 5), r = RED.r,   g = RED.g,   b = RED.b },
	{ points = line(0, 20, 4, 5), r = GREEN.r, g = GREEN.g, b = GREEN.b },
}, OPTS)
check("both channels report as drawn", n == 2, tostring(n))
check("...and put out about twice the geometry of one", visible_gizmos() >= one_ch * 2 - 2,
	string.format("%d vs %d for one", visible_gizmos(), one_ch))

local cols = drawn_colours()
check("...in TWO distinct colours", count(cols) == 2, tostring(count(cols)))
check("...one of them red", cols[string.format("%.2f,%.2f,%.2f", RED.r, RED.g, RED.b)] == true)
check("...and one green", cols[string.format("%.2f,%.2f,%.2f", GREEN.r, GREEN.g, GREEN.b)] == true)

-- The index rewrite this change turns on. Every segment must reference points that belong
-- to ITS OWN channel: the two lists sit end to end in one array, so a missed `base` would
-- have channel two's segments culled against channel one's visibility. Nothing on screen
-- would look wrong until the cull was switched on, which is the worst kind of bug.
local gpts, gsegs = M.debug_geometry()
check("...sharing ONE flat point list", #gpts == 10, tostring(#gpts))
check("...with every segment indexing a point inside it", (function()
	for i = 1, #gsegs do
		local sg = gsegs[i]
		if not (sg.pa >= 1 and sg.pa <= #gpts and sg.pb >= 1 and sg.pb <= #gpts) then
			return false
		end
	end
	return true
end)())
-- The base offset itself. Channel one owns points 1-5 and channel two 6-10, so a segment
-- tinted green must never index a point below 6 -- that is precisely the off-by-base that
-- would cull one path against the other's visibility.
check("...and no channel's segments reach into the other channel's points", (function()
	local gk = string.format("%.2f,%.2f,%.2f", GREEN.r, GREEN.g, GREEN.b)
	local saw_green = false
	for i = 1, #gsegs do
		local sg = gsegs[i]
		local key = string.format("%.2f,%.2f,%.2f", sg.col.r, sg.col.g, sg.col.b)
		if key == gk then
			saw_green = true
			if sg.pa < 6 or sg.pb < 6 then return false end
		elseif sg.pa > 5 or sg.pb > 5 then
			return false
		end
	end
	return saw_green
end)())

-- ==========================================================================
print("\n-- a channel that came back empty ------------------------------------")
-- The case the whole overlay exists for: one of the two paths returned nothing. That must
-- be REPORTED and the other one still drawn -- refusing the call would hide exactly the
-- thing being looked for.

n = M.show_channels({
	{ points = {},                          r = RED.r,   g = RED.g,   b = RED.b },
	{ points = line(0, 20, 4, 5),           r = GREEN.r, g = GREEN.g, b = GREEN.b },
}, OPTS)
check("an empty channel does not stop the other one drawing", n == 1, tostring(n))
check("...and only the surviving colour is on screen",
	count(drawn_colours()) == 1 and
	drawn_colours()[string.format("%.2f,%.2f,%.2f", GREEN.r, GREEN.g, GREEN.b)] == true)

n = M.show_channels({
	{ points = {} },
	{ points = { V(0, 0) } },               -- one point is not a line either
}, OPTS)
check("two empty channels draw nothing and say so", n == 0, tostring(n))
check("...and leave nothing on screen", visible_gizmos() == 0, tostring(visible_gizmos()))

-- ==========================================================================
print("\n-- hide and clear still work ------------------------------------------")
M.show_channels({
	{ points = line(0, 20, 0, 5), r = RED.r, g = RED.g, b = RED.b },
	{ points = line(0, 20, 4, 5), r = GREEN.r, g = GREEN.g, b = GREEN.b },
}, OPTS)
check("...two channels are up again", visible_gizmos() > 0)
M.hide()
check("hide() blanks both channels", visible_gizmos() == 0, tostring(visible_gizmos()))
M.clear()
check("clear() drops the gizmos entirely", next(gizmos) == nil)

-- ==========================================================================
print("\n-- headings survive the navmesh snap -------------------------------------")
-- snap() moves every point up to SNAP_MAX_XZ sideways to land on a navmesh vertex, so a
-- straight route arrives here with an uncorrelated lateral wobble on each point. Taking
-- a heading from one point to the NEXT puts that wobble on a one-step baseline, which
-- at a 3 m step is roughly +/-13 degrees of alternating noise on a dead-straight path.
--
-- It hid behind the chevron for the whole life of this project: a blunt 112 degree apex
-- that projection pushes toward 180 does not visibly change when you rotate it 13
-- degrees. The tapered dart is a 16 degree half-angle pointer and rendered the noise
-- exactly, which is how it finally surfaced -- as marks that would not line up.
do
	-- a straight run along +z with a deterministic +/-0.35 m lateral wobble, which is
	-- about what a 0.7 m node grid produces
	local pts, wob = {}, { 0.35, -0.30, 0.28, -0.35, 0.31, -0.26, 0.34, -0.33, 0.29, -0.35 }
	for i = 1, 10 do
		pts[i] = { x = wob[i], y = 0, z = (i - 1) * 3.0 }
	end

	local function spread(dirs)
		local lo, hi = 1e9, -1e9
		for i = 1, #dirs do
			local a = math.deg(math.atan2(dirs[i].x, dirs[i].z))
			lo, hi = math.min(lo, a), math.max(hi, a)
		end
		return hi - lo
	end

	-- what the drivers used to do, reproduced here so the comparison is real
	local naive = {}
	for i = 1, #pts - 1 do
		local dx, dz = pts[i + 1].x - pts[i].x, pts[i + 1].z - pts[i].z
		local L = math.sqrt(dx * dx + dz * dz)
		naive[i] = { x = dx / L, z = dz / L }
	end
	local wide = M.headings(pts)
	local sn, sw = spread(naive), spread(wide)
	print(string.format("     heading spread: next-point %.1f deg, 6 m baseline %.1f deg",
		sn, sw))
	check("the wide baseline cuts the heading noise by at least 3x", sw * 3 < sn,
		string.format("%.1f vs %.1f deg", sw, sn))
	check("...and leaves a straight route genuinely straight", sw < 6.0,
		string.format("%.1f deg", sw))
	check("one heading per point", #wide == #pts, tostring(#wide))
	check("every heading is a unit vector", (function()
		for i = 1, #wide do
			local l = math.sqrt(wide[i].x ^ 2 + wide[i].z ^ 2)
			if math.abs(l - 1) > 1e-6 then return false end
		end
		return true
	end)())
	-- Degenerate inputs must not produce a nil or a NaN: a mark pointing nowhere is
	-- worse than one pointing where its neighbour does.
	check("an empty route gives no headings", #M.headings({}) == 0)
	check("a single point still gives a heading", #M.headings({ { x = 0, y = 0, z = 0 } }) == 1)
	local same = M.headings({ { x = 1, y = 0, z = 1 }, { x = 1, y = 0, z = 1 } })
	check("two identical points give a usable heading",
		same[1] and math.abs(math.sqrt(same[1].x ^ 2 + same[1].z ^ 2) - 1) < 1e-6)
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
