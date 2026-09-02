-- Harness: the navmesh snapshot (R2.36).
--
-- WHY BOTHER TESTING A DEBUG TOOL. Because this one's whole job is to be BELIEVED. It is
-- what we now look at to decide whether a route is wrong or the mesh is, and a visualiser
-- that lies sends you to fix code that was never broken -- which has already happened
-- twice in this project from bad readings. The two claims it makes are "these nodes are
-- near you on foot" and "these are not", and both are arithmetic.
--
-- The trap it must not fall into is its own: reporting "unreachable" when the truth is
-- "I stopped looking". The BFS is capped, so a node past the cap has no hop count -- and
-- if that were drawn red, the tool would manufacture exactly the false severance it exists
-- to detect. Grey is a separate colour for a separate claim, and that is checked here.
--
-- Usage:
--   python check_lua.py --run tools/meshview-harness/harness.lua
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
ENV._G = ENV

local fmt_violations = {}
ENV.printf = function(fmt, ...)
	fmt = tostring(fmt)
	if fmt:find("%%[^s]") then fmt_violations[#fmt_violations + 1] = fmt end
end
ENV.RegisterScriptCallback = function() end
ENV.ui_debug_launcher = { injected = {}, inject = function(kind, t)
	ENV.ui_debug_launcher.injected[#ENV.ui_debug_launcher.injected + 1] = t
end }

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

local ColMT = {}
ColMT.__index = ColMT
function ColMT:set(r, g, b, a) self.r, self.g, self.b, self.a = r, g, b, a; return self end
ENV.fcolor = function() return setmetatable({ r = 0, g = 0, b = 0, a = 1 }, ColMT) end

-- ------------------------------------------------------------ synthetic mesh
-- TWO ROOMS, side by side, with a one-cell unmeshed strip between them -- the Bar doorway
-- in miniature. Both rooms have nodes; nothing links across; so the right side must come
-- out a different colour from the left however close the two are in metres.
local INVALID_VID = 4294967295
-- vertex_link's own sentinel is 2^23 - 1, not u32(-1) -- the level graph packs neighbour
-- indices into 23 bits (R2.37b). Modelled here because a tool whose entire claim is "these
-- two rooms are not joined" must not be tested against a stub that severs them more tidily
-- than the engine does.
local LINK_NONE = 8388607
local W, H = 24, 12
local GAP_I = 12                    -- the unmeshed column

local function meshed(i, j)
	if i < 0 or j < 0 or i >= W or j >= H then return false end
	return i ~= GAP_I
end
local function vid_of(i, j) return 5000 + j * W + i end
local function ij_of(vid)
	local n = vid - 5000
	return n % W, math.floor(n / W)
end

local link_cap = nil     -- when set, vertex_link refuses past this many calls (BFS cap test)
local link_calls = 0

ENV.level = {
	vertex_id = function(p)
		local i, j = math.floor(p.x), math.floor(p.z)
		if not meshed(i, j) then return INVALID_VID end
		return vid_of(i, j)
	end,
	vertex_position = function(vid)
		if vid == INVALID_VID then return ENV.vector():set(0, 0, 0) end
		local i, j = ij_of(vid)
		return ENV.vector():set(i + 0.5, 0, j + 0.5)
	end,
	-- The real adjacency: four neighbours, and NOTHING crosses the unmeshed column.
	vertex_link = function(vid, k)
		link_calls = link_calls + 1
		if link_cap and link_calls > link_cap then return LINK_NONE end
		local i, j = ij_of(vid)
		local di = ({ [0] = 1, [1] = -1, [2] = 0, [3] = 0 })[k]
		local dj = ({ [0] = 0, [1] = 0, [2] = 1, [3] = -1 })[k]
		local ni, nj = i + di, j + dj
		if not meshed(ni, nj) then return LINK_NONE end
		return vid_of(ni, nj)
	end,
}

local actor_pos = ENV.vector():set(4.5, 0, 5.5)
ENV.db = { actor = {
	position        = function() return actor_pos end,
	level_vertex_id = function()
		return ENV.level.vertex_id(actor_pos)
	end,
} }

-- The gizmo queue.
local gizmos = {}
local LineMT = {}
LineMT.__index = LineMT
function LineMT:cast_dbg_line() return self end
ENV.DBG_ScriptObject = { line = "line" }
ENV.debug_render = {
	add_object = function(id) local g = setmetatable({ id = id, visible = false }, LineMT)
		gizmos[id] = g; return g end,
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
	local f = assert(io.open("gamedata/scripts/iqm_meshview.script", "r"))
	local src = f:read("*a")
	f:close()
	local chunk, err = loadstring(src, "@iqm_meshview.script")
	assert(chunk, err)
	setfenv(chunk, M)
	local ok, perr = pcall(chunk)
	assert(ok, "iqm_meshview failed to parse: " .. tostring(perr))
end

local function colours()
	local c = { green = 0, amber = 0, red = 0, grey = 0, hidden = 0 }
	for _, g in pairs(gizmos) do
		if not g.visible then c.hidden = c.hidden + 1
		elseif g.color.g > 0.9 and g.color.r < 0.5 then c.green = c.green + 1
		elseif g.color.r > 0.9 and g.color.g > 0.5 then c.amber = c.amber + 1
		elseif g.color.r > 0.9 then c.red = c.red + 1
		else c.grey = c.grey + 1 end
	end
	return c
end
-- Which side of the gap a drawn tick sits on, by its own x.
local function side_colours(left)
	local n = { green = 0, amber = 0, red = 0, grey = 0 }
	for _, g in pairs(gizmos) do
		if g.visible then
			local on_left = g.point_a.x < GAP_I
			if on_left == left then
				local c = g.color
				if c.g > 0.9 and c.r < 0.5 then n.green = n.green + 1
				elseif c.r > 0.9 and c.g > 0.5 then n.amber = n.amber + 1
				elseif c.r > 0.9 then n.red = n.red + 1
				else n.grey = n.grey + 1 end
			end
		end
	end
	return n
end

-- ==========================================================================
print("-- it draws something at all -----------------------------------------")

check("show() is available", type(M.show) == "function")
local n = M.show(11.0)
check("a snapshot draws ticks", n and n > 0, tostring(n))
check("...and they are visible", colours().green > 0, tostring(colours().green))
check("...standing upright, so they read at a grazing angle", (function()
	for _, g in pairs(gizmos) do
		if g.visible then
			if not (g.point_b.y > g.point_a.y
			        and g.point_a.x == g.point_b.x and g.point_a.z == g.point_b.z) then
				return false
			end
		end
	end
	return true
end)())

-- ==========================================================================
print("\n-- the severed room reads as severed ----------------------------------")
-- THE WHOLE POINT. The actor's room is green. The room one cell away across the unmeshed
-- strip is not connected to it at all, so it must NOT be green -- if it were, the tool
-- would be showing metres when it claims to show walking, and the unmeshed doorway that
-- cost 150 m in the Bar would be invisible in the picture meant to reveal it.

local ours   = side_colours(true)
local theirs = side_colours(false)
check("the room you are standing in is green", ours.green > 0, tostring(ours.green))
check("...and the severed room has NO green in it", theirs.green == 0,
	string.format("%d green ticks across an unmeshed strip", theirs.green))
check("...it is drawn, not simply omitted -- absence is not a finding",
	(theirs.red + theirs.grey + theirs.amber) > 0,
	"nothing drawn on the far side at all")

-- ==========================================================================
print("\n-- 'I stopped looking' is not 'unreachable' ---------------------------")
-- The BFS is capped. A node past the cap has no hop count, and drawing that red would
-- manufacture the exact false severance this tool exists to detect. Grey is a different
-- claim and must stay a different colour.

M.clear()
link_calls, link_cap = 0, 8          -- starve the flood fill almost immediately
M.show(11.0)
local starved = colours()
check("a starved flood fill leaves most nodes GREY, not red", starved.grey > starved.red,
	string.format("%d grey vs %d red", starved.grey, starved.red))
link_cap = nil

-- ==========================================================================
print("\n-- hide, clear, re-show ----------------------------------------------")

M.clear()
link_calls = 0
M.show(11.0)
check("re-showing draws again", colours().green > 0)
M.hide()
check("hide() blanks every tick", colours().green == 0 and colours().red == 0,
	tostring(colours().green))
check("...without dropping the gizmos", next(gizmos) ~= nil)
check("is_shown() follows", M.is_shown() == false)
M.clear()
check("clear() drops them entirely", next(gizmos) == nil)

-- A shrinking snapshot must not leave the previous, larger one on screen behind it.
link_calls = 0
M.show(11.0)
local wide = 0
for _, g in pairs(gizmos) do if g.visible then wide = wide + 1 end end
link_calls = 0
M.show(2.0)
local narrow = 0
for _, g in pairs(gizmos) do if g.visible then narrow = narrow + 1 end end
check("a smaller snapshot parks the leftovers of a bigger one", narrow < wide,
	string.format("%d visible after 2 m vs %d after 11 m", narrow, wide))

-- ==========================================================================
print("\n-- housekeeping -------------------------------------------------------")

M.clear()
M.on_game_start()
check("it registers an F7 action", #ENV.ui_debug_launcher.injected == 1,
	tostring(#ENV.ui_debug_launcher.injected))
check("...named so it sorts with the rest",
	(ENV.ui_debug_launcher.injected[1] or {}).name == "IQM: Navmesh Snapshot",
	tostring((ENV.ui_debug_launcher.injected[1] or {}).name))
M.on_game_start()
check("...and never twice", #ENV.ui_debug_launcher.injected == 1,
	tostring(#ENV.ui_debug_launcher.injected))

-- Soft on an exe without the gizmo queue, like every other renderer here.
local saved = ENV.debug_render
ENV.debug_render = nil
local ok = pcall(function() return M.show(11.0) end)
check("no debug_render is a no-op, not a crash", ok)
ENV.debug_render = saved

check("every format string uses only %s", #fmt_violations == 0,
	fmt_violations[1] and (#fmt_violations .. " bad, first: " .. fmt_violations[1]))

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
