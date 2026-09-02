-- Harness: exercise the iqm_route level-graph A* outside the game. Stubs the
-- three graph bindings the module actually uses (vertex_id, vertex_position,
-- vertex_in_direction) over a synthetic navmesh with a wall and a narrow
-- doorway, loads the REAL gamedata/scripts/iqm_route.script, and asserts the
-- things that are miserable to debug in game: that a route goes round an
-- obstacle rather than through it, that a 1 m doorway is actually findable with
-- 8 m probes (R2.2b), that an unreachable goal fails instead of hanging, that
-- the budget makes the search resumable, and that string-pulling shortens the
-- node list without moving it off walkable ground.
--
-- The navmesh stub models the ENGINE's primitive faithfully, which is the whole
-- point: level.vertex_in_direction steps cell to cell along the straight line
-- and stops where it cannot continue (CLevelGraph::farthest_vertex_in_direction,
-- level_graph_vertex.cpp:211-249), returning the vertex it started from when it
-- cannot move at all. A stub that just teleported `dist` metres would make the
-- router look like it works and hide exactly the bug that matters -- a route
-- drawn straight through a wall.
--
-- Usage:
--   luajit tools/route-harness/harness.lua
--   VERBOSE=1 luajit tools/route-harness/harness.lua
--
-- Expected: "57 passed, 0 failed" and exit 0.

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

-- ---------------------------------------------------------------- engine env
local ENV = {}
ENV.pairs, ENV.ipairs, ENV.tostring, ENV.tonumber = pairs, ipairs, tostring, tonumber
ENV.type, ENV.string, ENV.table, ENV.math, ENV.os = type, string, table, math, os
ENV.setmetatable, ENV.print, ENV.pcall, ENV.select = setmetatable, print, pcall, select
ENV._G = ENV

-- printf, faithful to Anomaly's (_g.script:612): it substitutes the literal
-- token "%s" and nothing else, so a stray "%.1f" prints raw AND shifts every
-- later argument. Same check as the pathline harness.
local fmt_violations = {}
local printf_echo = true
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

-- ------------------------------------------------------------ synthetic mesh
-- 60 x 40 cells of 1 m, centres at (i + 0.5, j + 0.5), flat at y = 0.
-- A solid wall down column i = 30 with ONE open cell, so the only way across is
-- a 1 m doorway -- the hardest case for a coarse probe and the exact worry
-- logged as R2.2b.
local W, H = 60, 40
local INVALID_VID = 4294967295
-- vertex_link DOES NOT USE u32(-1). The level graph packs neighbour indices into 23 bits,
-- so its "no link this way" is 2^23 - 1, and level.vertex_position on it returns a zero
-- vector. Measured over 1136 real vertices as the only non-neighbour value it hands back.
--
-- This stub returned INVALID_VID here for one whole edit, and that single wrong constant
-- made 72 checks pass green against a build where gap_link never fired once and the search
-- was being fed a phantom vertex at the world origin -- reported from play as "still going
-- the long way and still going into walls". A stub that answers more tidily than the engine
-- is not a simplification; it is a different engine, and it certifies the wrong thing.
local LINK_NONE = 8388607
local DOOR_J = 19
local door_open = true

local function blocked(i, j)
	if i < 0 or j < 0 or i >= W or j >= H then return true end
	if i == 30 then
		return not (door_open and j == DOOR_J)
	end
	return false
end

local function vid_of(i, j) return 1000 + j * W + i end
local function ij_of(vid)
	local n = vid - 1000
	return n % W, math.floor(n / W)
end

-- A LEDGE: ground the AI mesh does not cover, with no geometry standing on it either. So
-- blocked() -- which is what the cover stub reads -- says there is nothing there, while
-- cell_at refuses it. That combination is the one thing the clearance pass can get wrong,
-- since it pushes toward whatever has no cover. Off the map by default.
local hole_i0, hole_i1, hole_j0, hole_j1 = 1e9, 1e9, 1e9, 1e9
-- An arbitrary unmeshed SHAPE, not just a rectangle. Rectangles make every gap axis-aligned,
-- and an axis-aligned gap can be bridged by a single ray straight down the direction the
-- mesh ran out in -- so a rectangle fixture certifies a single-lane bridge as working. Real
-- gaps are not axis-aligned: both ends are quantised to the AI grid independently, and the
-- Bar doorway this feature exists for sits at (+1.4, +0.7) from its near node, 27 degrees
-- off. A shape lets a test put the far side's opening where the near side has no node
-- opposite it, which is the case that actually needs lanes.
local hole_fn = nil
local function in_hole(i, j)
	if hole_fn then return hole_fn(i, j) end
	return i >= hole_i0 and i <= hole_i1 and j >= hole_j0 and j <= hole_j1
end

local function cell_at(px, pz)
	local i, j = math.floor(px), math.floor(pz)
	if blocked(i, j) or in_hole(i, j) then return nil end
	return vid_of(i, j)
end

local vpos_calls, probe_calls, link_calls = 0, 0, 0
-- level.vertex_id separately from the probes: it is the call string_pull spends its
-- budget on, and the two hoists in route-perf 4.6 are measurable in nothing else.
local vid_calls = 0
-- WHERE level.vertex_id LIES. The engine returns INVALID for cells the actor legitimately
-- stands in while the graph walks that same ground perfectly well through
-- vertex_in_direction -- a recorded quirk of this build, not a hypothetical. It is also
-- the only thing that exercises string_pull's parallel valid-COUNT: with every node's vid
-- valid, the cover mean divided by the count of valid nodes and divided by the length of
-- the span are the same number, so route-perf 4.6's prefix sums could drop the count
-- entirely and no assertion would move. Keyed by vid; nil for an honest graph.
local vid_blind = nil
local COVER_R = 3.0     -- m: range over which the cover stub falls to zero

ENV.level = {
	vertex_id = function(p)
		vid_calls = vid_calls + 1
		local v = cell_at(p.x, p.z)
		if v and vid_blind and vid_blind[v] then return INVALID_VID end
		return v or INVALID_VID
	end,
	vertex_position = function(vid)
		vpos_calls = vpos_calls + 1
		if vid == INVALID_VID then return ENV.vector():set(0, 0, 0) end
		local i, j = ij_of(vid)
		return ENV.vector():set(i + 0.5, 0, j + 0.5)
	end,
	-- Faithful to farthest_vertex_in_direction: march the straight line in small
	-- increments and stop at the last cell we could actually stand in. Returns
	-- the STARTING vertex when the very first step is blocked, which is what the
	-- Lua wrapper does (level_script.cpp:390-392) and what the router keys its
	-- "this direction is obstructed" logic off.
	vertex_in_direction = function(vid, dir, maxd)
		probe_calls = probe_calls + 1
		if vid == INVALID_VID then return INVALID_VID end
		local i, j = ij_of(vid)
		local sx, sz = i + 0.5, j + 0.5
		local len = math.sqrt(dir.x * dir.x + dir.z * dir.z)
		if len < 1e-6 then return vid end
		local ux, uz = dir.x / len, dir.z / len
		local last, t = vid, 0
		while t < maxd do
			t = math.min(t + 0.25, maxd)
			local v = cell_at(sx + ux * t, sz + uz * t)
			if not v then break end
			last = v
		end
		return last
	end,
	-- Cover in one direction, standing in for the value the AI graph bakes per node per
	-- quadrant. The engine's is a 4-bit occlusion measure; what matters to the router is
	-- only that it rises as geometry gets closer in the direction asked for, so this
	-- marches out to COVER_R and reports how early it hit something. Out-of-bounds counts
	-- as blocked, which is right -- the edge of a level IS a wall.
	high_cover_in_direction = function(vid, dir)
		if vid == INVALID_VID then return 0 end
		local i, j = ij_of(vid)
		local sx, sz = i + 0.5, j + 0.5
		local len = math.sqrt(dir.x * dir.x + dir.z * dir.z)
		if len < 1e-6 then return 0 end
		local ux, uz = dir.x / len, dir.z / len
		local t = 0
		while t < COVER_R do
			t = t + 0.25
			if blocked(math.floor(sx + ux * t), math.floor(sz + uz * t)) then
				return 1 - t / COVER_R
			end
		end
		return 0
	end,
	-- The level graph's OWN adjacency (R2.37). Four neighbours in the FIXED slot order the
	-- engine uses, measured in game across five adjacent vertices: 0 = -x, 1 = +z, 2 = +x,
	-- 3 = -z. The order is not decoration -- an invalid link names the direction the mesh
	-- stops in, and the gap bridge aims itself with it, so a stub that scrambled the slots
	-- would bridge sideways and still look like it worked.
	vertex_link = function(vid, k)
		link_calls = link_calls + 1
		if vid == INVALID_VID then return LINK_NONE end
		local di = ({ [0] = -1, [1] = 0, [2] = 1, [3] = 0 })[k]
		local dj = ({ [0] = 0, [1] = 1, [2] = 0, [3] = -1 })[k]
		if di == nil then return LINK_NONE end
		local i, j = ij_of(vid)
		local ni, nj = i + di, j + dj
		-- Same gate as cell_at: a blocked cell has no node, and neither has an unmeshed
		-- one. That is what makes a hole sever the graph rather than merely cost more.
		if blocked(ni, nj) or in_hole(ni, nj) then return LINK_NONE end
		return vid_of(ni, nj)
	end,
	get_target_obj = function() return nil end,
}

-- THE RAY, and the whole point of it: it sees `blocked` and is blind to `in_hole`.
-- That is the real distinction R2.36 turns on -- a wall has geometry, an unmeshed doorway
-- threshold does not -- and the fixture already had both, which is why the hole was worth
-- keeping around from the clearance work. Statics only, so flags are accepted and ignored.
--
-- A RAILING is modelled too, and it is the reason this stub knows about height at all.
-- A railing is not a wall: it is bars with air between them, so it blocks a ray at the
-- rail heights and passes one threaded between them. That is precisely how the first
-- version of the bridge came to hop railings in play (R2.36a) -- one ray at 1.0 m sailed
-- through the gap between a mid rail and a top rail. A stub that blocked at every height
-- would have called that fixed while it was still broken.
local rail_i0, rail_i1 = 1e9, 1e9      -- columns carrying a railing; off the map by default
-- The bar heights matter and must be chosen adversarially, or this fixture certifies a
-- broken bridge as fixed. Real railings run a mid rail near 0.55 and a top rail near 1.05,
-- so a ray at 1.00 threads the air between them -- and the FIRST version of this stub put a
-- bar across 0.95-1.15, which meant the single-ray build passed the railing check while
-- still hopping railings in play. These spans leave 1.00 clear on purpose: only a build
-- that also probes low catches it.
local RAIL_BARS = { { 0.50, 0.62 }, { 1.02, 1.12 } }   -- mid rail and top rail

local rays_cast = 0
local RayMT = {}
RayMT.__index = RayMT
function RayMT:set_flags(f) self.flags = f; return self end
function RayMT:set_position(p) self.pos = ENV.vector():set(p.x, p.y, p.z); return self end
function RayMT:set_direction(d) self.dir = ENV.vector():set(d.x, d.y, d.z); return self end
function RayMT:set_range(r) self.range = r; return self end
function RayMT:query()
	rays_cast = rays_cast + 1
	local t = 0
	while t < self.range do
		t = math.min(t + 0.1, self.range)
		local x = self.pos.x + self.dir.x * t
		local z = self.pos.z + self.dir.z * t
		local i = math.floor(x)
		if blocked(i, math.floor(z)) then return true end
		if i >= rail_i0 and i <= rail_i1 then
			-- the ground is flat at y = 0 here, so the ray's own y IS its height
			for b = 1, #RAIL_BARS do
				if self.pos.y >= RAIL_BARS[b][1] and self.pos.y <= RAIL_BARS[b][2] then
					return true
				end
			end
		end
	end
	return false
end
ENV.ray_pick = function() return setmetatable({ flags = 0, range = 0 }, RayMT) end

ENV.db = { actor = nil }
ENV.device = function() return { cam_pos = ENV.vector():set(0, 1.6, 0),
                                 cam_dir = ENV.vector():set(1, 0, 0) } end
local cb = {}
ENV.RegisterScriptCallback = function(name, fn) cb[name] = fn end

-- ------------------------------------------------------------ load iqm_route
local here = arg and arg[0] and arg[0]:gsub("[^/\\]+$", "") or ""
local path = here .. "../../gamedata/scripts/iqm_route.script"
local f = io.open(path, "r")
if not f then error("cannot open " .. path .. " -- run via: luajit tools/route-harness/harness.lua") end
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
local chunk, err = loadstring(src, "@iqm_route.script")
assert(chunk, err)
setfenv(chunk, M)
chunk()
ENV.iqm_route = M
M.verbose = os.getenv("VERBOSE") and true or false
M.on_game_start()

-- RUN THE WHOLE SUITE AGAINST BOTH GRAPHS (R2.37). The module can walk the level graph's
-- own adjacency or the older directional probes, and BOTH have to keep working: links is
-- what ships, probes is the fallback where level.vertex_link is missing and is what every
-- earlier session's behaviour was tuned against.
--
-- Injecting it here rather than at each call site is what makes that cheap -- one env var
-- re-runs every check below against the other expander. It also closes the hole that let
-- the link expander ship untested for a whole edit: the stub had no vertex_link, so
-- search_begin quietly fell back to probes and 71 checks passed without once entering the
-- new code. A silent fallback plus a green suite is the worst pair in this file.
local GRAPH = os.getenv("IQM_GRAPH") or "links"
do
	local _rn, _sb = M.route_now, M.search_begin
	local function with_graph(o)
		o = o or {}
		if o.graph == nil then o.graph = GRAPH end
		return o
	end
	M.route_now     = function(a, b, o) return _rn(a, b, with_graph(o)) end
	M.search_begin  = function(a, b, o) return _sb(a, b, with_graph(o)) end
end
print(string.format("== graph = %s ==", GRAPH))

-- ------------------------------------------------------------------ helpers
local function V(x, z) return ENV.vector():set(x, 0, z) end

local function on_mesh(p) return cell_at(p.x, p.z) ~= nil end

local function path_len(p)
	local d = 0
	for i = 1, #p - 1 do
		local dx, dz = p[i + 1].x - p[i].x, p[i + 1].z - p[i].z
		d = d + math.sqrt(dx * dx + dz * dz)
	end
	return d
end

-- Does any leg of the path jump the wall somewhere other than the doorway?
-- Checked by walking the leg finely, which catches a route that "teleports"
-- across geometry between two legitimate-looking nodes.
local function crosses_wall(p)
	for i = 1, #p - 1 do
		local a, b = p[i], p[i + 1]
		local n = math.max(1, math.ceil(math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2) / 0.2))
		for k = 0, n do
			local t = k / n
			local x, z = a.x + (b.x - a.x) * t, a.z + (b.z - a.z) * t
			if not cell_at(x, z) then return true, i, x, z end
		end
	end
	return false
end

-- ==========================================================================
print("\n-- open ground ------------------------------------------------------")

door_open = true
local p = M.route_now(V(5.5, 20.5), V(25.5, 20.5))
check("finds a route across open ground", p and #p >= 2, p and tostring(#p) or "nil")
check("the route starts at the start", p and math.abs(p[1].x - 5.5) < 1.5,
	p and tostring(p[1].x))
check("the route ends at the goal", p and math.abs(p[#p].x - 25.5) < 3.5,
	p and tostring(p[#p].x))
check("open-ground route is near straight", p and path_len(p) < 20 * 1.25,
	p and string.format("%.1f", path_len(p)))
check("every node is on walkable ground", (function()
	for _, q in ipairs(p or {}) do if not on_mesh(q) then return false end end
	return p ~= nil
end)())

-- ==========================================================================
print("\n-- the wall and the 1 m doorway (R2.2b) -----------------------------")

door_open = true
p = M.route_now(V(5.5, 20.5), V(55.5, 20.5))
check("finds a route to the far side of the wall", p and #p >= 2,
	p and tostring(#p) or "nil")
local crossed, leg, cx, cz = crosses_wall(p or {})
check("no leg of the route passes through the wall", not crossed,
	crossed and string.format("leg %d at %.1f,%.1f", leg, cx, cz) or nil)
-- Asked as "does a LEG pass through the doorway", not "is there a NODE at it". Those are
-- different claims and only the first is the property: string-pulling exists to delete the
-- intermediate nodes, so a perfectly good route through a 1 m gap can have its nearest
-- vertex metres away on either side. The node form passed for years on the probe graph by
-- luck of where 8 m landed, and failed the moment the link graph put its vertices
-- elsewhere -- a route that was threading the doorway exactly as asked.
check("the route actually threads the doorway", (function()
	for i = 2, #(p or {}) do
		local a, b = p[i - 1], p[i]
		if (a.x - 30) * (b.x - 30) <= 0 and a.x ~= b.x then
			local t = (30 - a.x) / (b.x - a.x)
			local z = a.z + (b.z - a.z) * t
			if math.abs(z - (DOOR_J + 0.5)) < 1.5 then return true end
		end
	end
	return false
end)(), "no leg crosses x=30 at the doorway")
check("the route reaches the far side", p and p[#p].x > 52, p and tostring(p[#p].x))

-- ==========================================================================
print("\n-- unreachable ------------------------------------------------------")

door_open = false
local st = M.search_begin(V(5.5, 20.5), V(55.5, 20.5))
check("a sealed goal still starts a search", st == true, tostring(st))
local guard = 0
while M.search_step(200) == "working" do
	guard = guard + 1
	if guard > 500 then break end
end
check("a sealed goal terminates instead of hanging", guard <= 500, tostring(guard))
-- Semantics changed 2026-08-13: a search that runs out of expansion budget hands
-- back the best-effort path it found instead of nothing, and a sealed region reaches
-- that budget before it exhausts its frontier -- so an unreachable goal now yields
-- "as close as the mesh gets", flagged as partial. Being walked up to the sealed
-- door is a useful answer; being told nothing is what four in-game sessions
-- complained about.
check("...and answers with a best-effort route", M.search_state() == "done",
	M.search_state())
check("...flagged as partial", M.search_partial() == true)
local sealed = M.search_result()
check("...that is a real walkable path, not a line at the goal",
	sealed and #sealed >= 2 and not crosses_wall(sealed))
check("...stopping short of the goal",
	sealed and sealed[#sealed].x < 45, sealed and tostring(sealed[#sealed].x))
door_open = true

-- and the ordinary case must NOT be flagged
M.route_now(V(5.5, 20.5), V(25.5, 20.5))
check("a route that reaches the goal is not partial", M.search_partial() == false)

-- ==========================================================================
print("\n-- off the navmesh --------------------------------------------------")

check("a start off the mesh refuses to search",
	M.search_begin(V(-50, -50), V(25.5, 20.5)) == false)
check("...and reports failure", M.search_state() == "failed", M.search_state())
check("a goal off the mesh refuses to search",
	M.search_begin(V(5.5, 20.5), V(-50, -50)) == false)
-- inside the wall itself is the realistic version of this: a target standing
-- somewhere the AI mesh does not cover (R2.2d)
check("a goal inside geometry refuses to search",
	M.search_begin(V(5.5, 20.5), V(30.5, 5.5)) == false)

-- ==========================================================================
print("\n-- budget and resumability ------------------------------------------")

M.search_begin(V(5.5, 20.5), V(55.5, 20.5))
local slices, saw_working = 0, false
while M.search_step(1) == "working" do
	slices = slices + 1
	saw_working = true
	if slices > 5000 then break end
end
check("a 1-node budget really does slice the search", saw_working and slices > 5,
	tostring(slices))
check("the sliced search reaches the same answer", M.search_state() == "done",
	M.search_state())
local sliced = M.search_result()
check("the sliced route is valid", sliced and not crosses_wall(sliced))

-- max_nodes has to bite, or a pathological level could stall a frame forever
M.search_begin(V(5.5, 20.5), V(55.5, 20.5), { max_nodes = 5 })
guard = 0
while M.search_step(10) == "working" do
	guard = guard + 1
	if guard > 100 then break end
end
check("max_nodes caps the search", M.search_state() == "done", M.search_state())
check("...handing back what it found so far", M.search_partial() == true)
local capped = M.search_result()
check("...as a valid partial", capped and #capped >= 2 and not crosses_wall(capped))

-- ==========================================================================
print("\n-- string pulling ---------------------------------------------------")

local raw    = M.route_now(V(5.5, 20.5), V(55.5, 20.5), { pull = false })
local pulled = M.route_now(V(5.5, 20.5), V(55.5, 20.5), { pull = true })
check("string pulling drops nodes", raw and pulled and #pulled < #raw,
	string.format("%s -> %s", raw and #raw, pulled and #pulled))
check("string pulling keeps the route off the wall", pulled and not crosses_wall(pulled))
check("string pulling keeps both ends", pulled
	and math.abs(pulled[1].x - 5.5) < 1.5 and pulled[#pulled].x > 52)

-- What the pull itself costs the engine, which is what route-perf 4.6's two hoists move.
-- Measured as the DIFFERENCE between the same search with the pull off and on: `pull` is
-- only consulted once the search has already finished, so everything before it is identical
-- between the two runs and the delta is the pull and nothing else.
--
-- level.vertex_id and not the probes, because that is the call the pull spends its budget
-- on: it asks the graph "which node is this point" for the span's origin, for the chord's
-- midpoint, and for every node the span would delete -- and that last group was re-derived
-- for every candidate k as the reach extended, which is the quadratic. 575 calls on this
-- 50-node route before the hoists, 100 after.
local function path_sig(p)
	if not p then return "nil" end
	local t = {}
	for i = 1, #p do t[i] = string.format("%.1f/%.1f", p[i].x, p[i].z) end
	return table.concat(t, " ")
end

vid_calls = 0
local unpulled = M.route_now(V(5.5, 20.5), V(55.5, 20.5), { pull = false })
local vid_off = vid_calls
vid_calls = 0
local repulled = M.route_now(V(5.5, 20.5), V(55.5, 20.5), { pull = true })
local vid_on = vid_calls
-- Pinned to the literal 100 rather than derived from #unpulled. An expectation computed
-- from the quantity it is checking moves with the mutation and tests nothing; this review
-- has already watched that happen twice (route-perf 4.4's sweep period, 4.5's lead cut).
-- The arithmetic behind it, for whoever changes the pull next: 50 nodes for the one linear
-- prefix pass, 3 span origins for the 3 outer iterations, and 47 chord midpoints.
check("the pull's cover mean is linear in the node count, not quadratic",
	vid_on - vid_off == 100,
	string.format("%d vertex_id calls to pull %d nodes -- 575 before route-perf 4.6's "
		.. "hoists; the search alone spends %d", vid_on - vid_off, #unpulled, vid_off))
-- ...and the route that comes out is the same route. Both hoists are behaviour-preserving
-- by construction, so this is the assertion that has to fail if they are not. "#pulled <
-- #raw" above cannot see it -- a wrongly refused pull still drops nodes.
check("...and the hoists change nothing about the route that comes out",
	path_sig(repulled) == "5.5/20.5 28.5/19.5 33.5/19.5 53.5/19.5", path_sig(repulled))

-- THE MEAN'S TWO EASY MISTAKES, both of which need a graph that lies to be visible at all.
-- On an honest fixture every node of a rebuilt path has a vid, so dividing the cover sum by
-- the count of valid nodes and by the length of the span are the same number, and including
-- the chord's far end in the window shifts the mean by too little to change any decision.
-- Deleting the count and sliding the window each passed all 74 assertions above. What makes
-- them visible is vid_blind -- one cell the engine names INVALID while the graph walks it
-- perfectly well, which is a recorded quirk of this build and not a contrivance.
--
-- Both routes below are the hard case with a single blind cell, and both expectations are
-- the CLEAN answer: the mutations do not fail to produce a route, they produce a different
-- one, which is exactly why nothing coarser than the node list catches them.
vid_blind = { [vid_of(31, 19)] = true }
local blind_mid = M.route_now(V(5.5, 20.5), V(55.5, 20.5))
vid_blind = { [vid_of(15, 20)] = true }
local blind_far = M.route_now(V(5.5, 20.5), V(55.5, 20.5))
vid_blind = nil
check("a node the graph will not name is left out of the pull's cover mean entirely",
	path_sig(blind_mid) == "5.5/20.5 28.5/19.5 32.5/19.5 53.5/19.5",
	path_sig(blind_mid) .. " -- dividing by the span's length instead of by the count of "
		.. "nodes that had a vid keeps 31.5/19.5")
check("...and the mean covers only the nodes the pull would delete, not the chord's far end",
	path_sig(blind_far) == "5.5/20.5 23.5/20.5 31.5/19.5 53.5/19.5",
	path_sig(blind_far) .. " -- a window of i+1..k instead of i+1..k-1 reaches 32.5/19.5")

-- ==========================================================================
print("\n-- smoothing, and its navmesh veto (R2.14) ---------------------------")

-- A synthetic right angle, well clear of the wall, is the clean case: two passes of
-- Chaikin should round it off without moving either end.
local corner = { V(10.5, 10.5), V(20.5, 10.5), V(20.5, 20.5) }
local round  = M.smooth(corner)
check("smoothing adds points", #round > #corner, string.format("%s -> %s", #corner, #round))
check("...keeps both ends", math.abs(round[1].x - 10.5) < 1e-6
	and math.abs(round[#round].z - 20.5) < 1e-6)

--- Sharpest turn anywhere in the list, as 1 - cos (0 is dead straight).
local function sharpest(p)
	local worst = 0
	for i = 2, #p - 1 do
		local ax, az = p[i].x - p[i - 1].x, p[i].z - p[i - 1].z
		local bx, bz = p[i + 1].x - p[i].x, p[i + 1].z - p[i].z
		local la, lb = math.sqrt(ax * ax + az * az), math.sqrt(bx * bx + bz * bz)
		if la > 1e-6 and lb > 1e-6 then
			local d = (ax / la) * (bx / lb) + (az / la) * (bz / lb)
			worst = math.max(worst, 1 - d)
		end
	end
	return worst
end
-- THE point of the exercise: a 90 degree fold (1 - cos = 1) has to come out as several
-- shallow bends, not one sharp one.
check("...and turns the corner into shallow bends", sharpest(round) < 0.35,
	string.format("%.3f", sharpest(corner)) .. " -> " .. string.format("%.3f", sharpest(round)))
check("...without wandering off walkable ground", not crosses_wall(round))

--- How close the polyline gets to (x, z).
local function nearest(p, x, z)
	local best = 1e9
	for i = 1, #p do
		local dx, dz = p[i].x - x, p[i].z - z
		best = math.min(best, math.sqrt(dx * dx + dz * dz))
	end
	return best
end
-- The cut is capped in METRES (SMOOTH_CUT), not taken as a fraction of the leg. The
-- textbook 25% form would cut a corner between two 24 m legs by six metres, and a route
-- that rounds a corner off by six metres is not describing the corridor any more. Same
-- corner, legs more than twice as long: the arc must still hug it.
local long_corner = { V(1.5, 10.5), V(25.5, 10.5), V(25.5, 34.5) }
local long_round  = M.smooth(long_corner)
-- The bound is SMOOTH_CUT itself (1.5 m): the arc leaves the corner by
-- cut * |u + v| / 2, which is ~1.06 m for the right angle here.
check("...cutting a fixed distance rather than a fraction of the leg",
	nearest(long_round, 25.5, 10.5) < 1.5,
	string.format("%.2f m from the corner", nearest(long_round, 25.5, 10.5)))
check("...on legs of any length", math.abs(nearest(long_round, 25.5, 10.5)
	- nearest(round, 20.5, 10.5)) < 0.35,
	string.format("%.2f vs %.2f", nearest(long_round, 25.5, 10.5), nearest(round, 20.5, 10.5)))

-- The veto. Chaikin cuts corners INWARD, so a corner turned in a doorway is cut into
-- the jamb -- which is the one case where smoothing must not happen. The route here
-- goes through the 1 m gap at (30.5, 19.5) and turns there.
local door = { V(25.5, 15.5), V(30.5, 19.5), V(35.5, 15.5) }
local vetoed = M.smooth(door)
check("a cut that would leave the mesh is vetoed", not crosses_wall(vetoed))
check("...and the doorway itself is still on the route", (function()
	for i = 1, #vetoed do
		local dx, dz = vetoed[i].x - 30.5, vetoed[i].z - 19.5
		if math.sqrt(dx * dx + dz * dz) < 0.6 then return true end
	end
	return false
end)())

-- Degenerate inputs: the driver calls this on every search result, including the ones
-- too short to have a corner at all.
check("two points are handed back untouched", (function()
	local two = { V(1.5, 1.5), V(2.5, 1.5) }
	return M.smooth(two) == two
end)())
check("nil is handed back untouched", M.smooth(nil) == nil)

-- ==========================================================================
print("\n-- densify ----------------------------------------------------------")

local dense = M.densify(pulled, 2.0)
check("densify preserves the endpoints", dense
	and math.abs(dense[1].x - pulled[1].x) < 1e-6
	and math.abs(dense[#dense].x - pulled[#pulled].x) < 1e-6)
local worst = 0
for i = 1, #dense - 1 do
	local dx, dz = dense[i + 1].x - dense[i].x, dense[i + 1].z - dense[i].z
	worst = math.max(worst, math.sqrt(dx * dx + dz * dz))
end
check("densify honours the spacing", worst <= 2.0 + 1e-6, string.format("%.3f", worst))
check("densify never emits a duplicate joint", (function()
	for i = 1, #dense - 1 do
		local dx, dz = dense[i + 1].x - dense[i].x, dense[i + 1].z - dense[i].z
		if math.sqrt(dx * dx + dz * dz) < 1e-9 then return false end
	end
	return true
end)())

-- ==========================================================================
print("\n-- cost of one search (feeds R2.2c) ---------------------------------")

-- The engine calls are what a real search actually costs; node count alone is
-- misleading because each expansion fires 8 long probes plus a short one per
-- obstructed direction. Measured on the hard case: 50 m, round a wall, through
-- a 1 m gap -- worse than any proximity-range route should ever be.
-- Counted as TOTAL engine calls rather than probes alone, because the two graphs spend
-- their budget on different bindings: probes on vertex_in_direction, links on vertex_link.
-- Counting only probes made this check meaningless the moment the link expander shipped --
-- it read 16 against 47 and failed on a search that was in fact enormously cheaper.
probe_calls, vpos_calls, link_calls = 0, 0, 0
local hard = M.route_now(V(5.5, 20.5), V(55.5, 20.5))
local hard_probes, hard_vpos, hard_calls = probe_calls, vpos_calls, probe_calls + link_calls
check("the hard case stays inside a sane engine-call budget", hard_calls < 60000,
	tostring(hard_calls))

probe_calls, vpos_calls, link_calls = 0, 0, 0
M.route_now(V(5.5, 20.5), V(25.5, 20.5))
local easy_calls = probe_calls + link_calls
-- The ratio, not a fixed multiple of it. On the link graph both searches are cheap enough
-- that per-search fixed costs matter, so the old "4x" was a probe-era number rather than a
-- property -- easy 84 against hard 279 is the same statement it was always making. Held to
-- half, plus an absolute bound, so this cannot pass by both numbers ballooning together.
check("open ground is much cheaper than the hard case",
	easy_calls * 2 < hard_calls and easy_calls < 2000,
	string.format("easy %d vs hard %d engine calls", easy_calls, hard_calls))

print(string.format("  ..  hard: %d engine calls (%d probes), %d position reads, %d nodes out",
	hard_calls, hard_probes, hard_vpos, hard and #hard or 0))
print(string.format("  ..  easy: %d engine calls", easy_calls))

-- ==========================================================================
print("\n-- clearance: preferring the middle of a space (R2.23) --------------")

-- The SEARCH side. A route hugging the level's own edge is the cleanest test case there
-- is: j = 0 has the boundary immediately to one side and open floor to the other, so the
-- cover surcharge has somewhere better to go and nothing else differs. Measured as the
-- mean z of the result, against the same route with the surcharge switched off.
local function mean_z(p)
	local s = 0
	for i = 1, #p do s = s + p[i].z end
	return s / #p
end
local hug = M.route_now(V(5.5, 0.5), V(25.5, 0.5), { cover_w = 0 })
local mid = M.route_now(V(5.5, 0.5), V(25.5, 0.5))
check("the cover surcharge pulls a route off the level edge",
	hug and mid and mean_z(mid) > mean_z(hug) + 1.0,
	string.format("%.2f -> %.2f", hug and mean_z(hug) or -1, mid and mean_z(mid) or -1))
check("...and still ends where it was asked to", mid
	and math.abs(mid[#mid].x - 25.5) < 3.0 and math.abs(mid[#mid].z - 0.5) < 3.0,
	mid and string.format("%.1f, %.1f", mid[#mid].x, mid[#mid].z) or "nil")
-- Every doorway fixture above ran with the surcharge live, which is the real guard on this:
-- a 1 m gap in a wall is the most covered ground on the map and has to stay passable.
check("...without making the doorway impassable (see above)", true)

-- The CLEARANCE side, which is what the search cannot do: it only ever stands on graph
-- nodes and hops 8 m, so where in a corridor the line runs is decided here.
local function line_z(x0, x1, z)
	local p, m = {}, 0
	for x = x0, x1, 1.0 do m = m + 1; p[m] = V(x + 0.5, z) end
	return p
end

local pts = line_z(10, 25, 0.5)
local before = pts[8].z
M.clearance(pts)
check("clearance pushes a line off the wall it runs along", pts[8].z > before + 0.2,
	string.format("%.2f -> %.2f", before, pts[8].z))
check("...by no more than the cap", pts[8].z - before <= 0.75 + 1e-6,
	string.format("%.3f m", pts[8].z - before))
check("...leaving both ends exactly where they were",
	pts[1].z == 0.5 and pts[2].z == 0.5
	and pts[#pts].z == 0.5 and pts[#pts - 1].z == 0.5,
	string.format("%.2f %.2f .. %.2f %.2f", pts[1].z, pts[2].z, pts[#pts - 1].z, pts[#pts].z))
-- No ripple: cover is quantised to the cell grid, so the raw offsets step as points cross
-- cell boundaries. The DEEP interior of a straight run along a straight wall must come out
-- flat -- deep, because the ends are pinned and the smoothing ramps out of them over the
-- next couple of points, which is a step the assertion must not mistake for a ripple.
local ripple = 0
for i = 6, #pts - 5 do ripple = math.max(ripple, math.abs(pts[i].z - pts[i - 1].z)) end
check("...and no per-cell ripple along a straight wall", ripple < 0.05,
	string.format("%.3f m worst step", ripple))

-- Open ground is left alone. Cover is zero on all eight sides, the gradient cancels, and
-- there is nothing to improve -- so this must be a no-op rather than a random drift.
pts = line_z(10, 25, 20.5)
local moved = 0
M.clearance(pts)
for i = 1, #pts do if math.abs(pts[i].z - 20.5) > 1e-9 then moved = moved + 1 end end
check("open ground is left alone", moved == 0, tostring(moved) .. " points moved")

-- A push must never be taken onto ground the mesh does not cover. The ledge sits on the
-- open side of the wall, so the gradient points straight at it: cover says "nothing there",
-- and only the destination node test stands between the route and a drop.
hole_i0, hole_i1, hole_j0, hole_j1 = 28, 29, 0, 39
pts = { V(29.5, 4.5), V(29.5, 5.5), V(29.5, 6.5), V(29.5, 7.5), V(29.5, 8.5),
        V(29.5, 9.5), V(29.5, 10.5) }
local sx0 = pts[4].x
M.clearance(pts)
check("a push onto unmapped ground is refused", math.abs(pts[4].x - sx0) < 1e-9,
	string.format("%.3f -> %.3f", sx0, pts[4].x))
hole_i0, hole_i1, hole_j0, hole_j1 = 1e9, 1e9, 1e9, 1e9

-- Degenerate inputs, the same three every other pass here takes.
check("clearance survives a short list", M.clearance({ V(1, 1), V(2, 1) }) ~= nil)
check("...an empty one", M.clearance({}) ~= nil or true)
check("...and nil", M.clearance(nil) == nil)

-- ==========================================================================
print("\n-- stepping over holes in the AI map (R2.36) -------------------------")
local OPT_ARRIVE = 3.0        -- iqm_route's own `arrive`: a route may stop this short
-- The navmesh is not a map of where the player can walk; it is a map of where the level's
-- AI nodes were baked. Measured in the Bar in front of an open doorway with a step up:
-- two vertices 1.58 m apart were 255 hops apart on the mesh, and statics rays across the
-- strip came back clear at 0.3, 0.9 and 1.6 m. Not a wall -- an unmeshed threshold, turning
-- a 29 m walk into 178 m. In a 17x17 m box around it, 18 such holes had no geometry at all.
--
-- The fixture already had exactly this shape: `in_hole` is unmeshed ground that `blocked`
-- says nothing stands on, so the mesh stub refuses it while the ray stub passes through.

door_open, hole_i0, hole_i1, hole_j0, hole_j1, hole_fn = true, 1e9, 1e9, 1e9, 1e9, nil
hole_fn = nil
-- A band of unmeshed floor right across the corridor, with nothing standing on it.
hole_i0, hole_i1, hole_j0, hole_j1 = 12, 13, 0, H
local bridged = M.route_now(V(5.5, 20.5), V(25.5, 20.5))
check("a route crosses an unmeshed strip that has nothing in it",
	bridged and #bridged >= 2, bridged and #bridged or "nil")
check("...arriving at the goal rather than stopping at the hole",
	bridged and (25.5 - bridged[#bridged].x) <= OPT_ARRIVE,
	bridged and string.format("%.1f", bridged[#bridged].x) or "no route")

-- Off by default-override: the old behaviour has to remain reachable, both as an escape
-- hatch and because it is what proves the bridge is what crossed the hole above.
local unbridged = M.route_now(V(5.5, 20.5), V(25.5, 20.5), { gap = 0 })
check("...and with gap = 0 it does NOT cross, so the bridge is what did it",
	(not unbridged) or (25.5 - unbridged[#unbridged].x) > OPT_ARRIVE,
	unbridged and string.format("reached %.1f", unbridged[#unbridged].x) or "no route")

-- THE SAFETY CASE, and the one that matters most: a real wall must still stop it. Same
-- geometry, but now the strip is `blocked` too, so the ray finds something. If this ever
-- passes, the feature has become "walk through walls" and is worse than the bug it fixes.
door_open, hole_i0, hole_i1, hole_j0, hole_j1, hole_fn = true, 1e9, 1e9, 1e9, 1e9, nil
hole_fn = nil
door_open = false                     -- the wall at i=30 is now solid all the way across
local walled = M.route_now(V(5.5, 20.5), V(45.5, 20.5))
check("a SOLID wall is never bridged",
	(not walled) or (45.5 - walled[#walled].x) > OPT_ARRIVE,
	walled and string.format("reached %.1f -- walked through a wall", walled[#walled].x)
	        or "no route (correct)")
door_open = true

-- A clear ray proves there is no wall; it does not prove there is floor. The far side
-- being much higher or lower is the only cheap evidence of a ledge, so it must refuse.
door_open, hole_i0, hole_i1, hole_j0, hole_j1, hole_fn = true, 1e9, 1e9, 1e9, 1e9, nil
hole_fn = nil
hole_i0, hole_i1, hole_j0, hole_j1 = 12, 13, 0, H
local saved_vp = ENV.level.vertex_position
ENV.level.vertex_position = function(vid)
	local v = saved_vp(vid)
	local i = ij_of(vid)
	if i > 13 then v.y = v.y + 6.0 end   -- everything past the hole is six metres up
	return v
end
local ledge = M.route_now(V(5.5, 20.5), V(25.5, 20.5))
check("a drop on the far side refuses the bridge",
	(not ledge) or (25.5 - ledge[#ledge].x) > OPT_ARRIVE,
	ledge and string.format("reached %.1f -- stepped off a ledge", ledge[#ledge].x)
	       or "no route (correct)")
ENV.level.vertex_position = saved_vp

-- A RAILING, reported from play (R2.36a). The unmeshed strip is real and there is floor on
-- both sides, but a barrier stands on it -- so a single chest-height ray threads the air
-- between the bars and the route hops it. This is the check that a bridge must be clear at
-- SEVERAL heights, and it fails against the one-ray version.
door_open, hole_i0, hole_i1, hole_j0, hole_j1, hole_fn = true, 1e9, 1e9, 1e9, 1e9, nil
hole_fn = nil
hole_i0, hole_i1, hole_j0, hole_j1 = 12, 13, 0, H
rail_i0, rail_i1 = 12, 13              -- a railing standing in the unmeshed strip
local railed = M.route_now(V(5.5, 20.5), V(25.5, 20.5))
check("a RAILING in the gap is never bridged",
	(not railed) or (25.5 - railed[#railed].x) > OPT_ARRIVE,
	railed and string.format("reached %.1f -- hopped a railing", railed[#railed].x)
	        or "no route (correct)")
-- ...and the same fixture without the railing still crosses, so the check above is failing
-- for the railing and not because the fixture stopped working.
rail_i0, rail_i1 = 1e9, 1e9
local unrailed = M.route_now(V(5.5, 20.5), V(25.5, 20.5))
check("...while the same gap without one still crosses",
	unrailed and (25.5 - unrailed[#unrailed].x) <= OPT_ARRIVE,
	unrailed and string.format("%.1f", unrailed[#unrailed].x) or "no route")

-- A gap whose far side is NOT straight across from its near side (R2.37a), built so that
-- the axis-aligned crossing does not exist at all:
--
--     i = 12, 13   unmeshed -- the strip
--     i = 14       meshed ONLY at j = 20 -- the far side opens in one place
--     i = 11       unmeshed at j = 20 -- and the near side has no node opposite it
--
-- So every bridge must run from (11.5, 19.5) or (11.5, 21.5) to (14.5, 20.5) -- offset by a
-- cell, exactly the shape of the real doorway. A single ray down +x lands on unmeshed ground
-- from either, and only a lane a cell to the side finds the floor.
--
-- Two earlier versions of this fixture passed against a single-lane build, both because the
-- search could reach some node where straight-across happened to work. A gap test that the
-- broken build also passes is worse than no gap test.
hole_fn = function(i, j)
	if i == 12 or i == 13 then return true end
	if i == 14 and j ~= 20 then return true end
	if i == 11 and j == 20 then return true end
	return false
end
-- Asserted per graph rather than skipped on the one that cannot do it. Probes sweep eight
-- directions but one lane each, and this offset is ~18 degrees -- not a multiple of 45 --
-- so it genuinely cannot reach the far side. That is a real capability difference and worth
-- stating; skipping the check there would let a links regression hide behind "not run here".
local offset = M.route_now(V(5.5, 19.5), V(25.5, 19.5))
local reached = offset and offset[#offset].x > 22 or false
if GRAPH == "links" then
	check("a gap whose far side is offset sideways is bridged (links)", reached,
		offset and string.format("reached %.1f", offset[#offset].x) or "no route")
else
	check("...and probes cannot bridge it, having one lane per direction", not reached,
		offset and string.format("reached %.1f -- unexpected", offset[#offset].x) or "no route")
end
hole_fn = nil

-- Cost. The bridge may only fire where the probes already ran out, or it becomes a ray per
-- direction per node on open ground -- and a ray is ~2 us against a ~30 us expansion, so
-- eight of them per node would be half the search again.
door_open, hole_i0, hole_i1, hole_j0, hole_j1, hole_fn = true, 1e9, 1e9, 1e9, 1e9, nil
hole_fn = nil
rays_cast = 0
M.route_now(V(5.5, 20.5), V(45.5, 20.5))
local open_rays = rays_cast
check("open ground casts few rays -- the bridge is not in the hot path",
	open_rays < 400, string.format("%d rays for a 40 m open route", open_rays))

-- ==========================================================================
print("\n-- the actor standing off the navmesh (R2.34) ------------------------")
-- THE ROUTING-THROUGH-WALLS BUG, and the reason it looked like everything except what it
-- was. level.vertex_id is an exact cell lookup: INVALID for any point in a cell the AI
-- map never got a node for -- a doorway threshold, the lip of a step, the strip along a
-- wall. The player crosses those constantly, and the engine does NOT lose the actor
-- there; actor:level_vertex_id() still names the node it stands on. Only the wrong one
-- of the two is answerable from a bare position, so search_begin was refusing the START
-- on ground the actor was standing on.
--
-- Measured live on l05_bar over the devkit bridge, actor at (212.888, 0.429, 50.032):
-- level.vertex_id(pos) -> INVALID while actor:level_vertex_id() -> 52912, 0.87 m away,
-- with a plain BFS over vertex_link joining actor to goal in 22 hops. Feeding the search
-- the vertex returned `done` where the position returned false.
--
-- What made it read as a PATHING fault rather than a refusal: a refusal here leaves the
-- previous path up, and that one was searched from wherever the actor stood when it last
-- worked -- so the marks cross whatever wall now lies between there and here. Positional,
-- lasting exactly as long as the player stands still. Hence "it fixes itself when I move",
-- hence a fresh load being stuck until you walk about, and hence no budget ever helping.

local saved_actor = ENV.db.actor
hole_i0, hole_i1, hole_j0, hole_j1 = 5, 5, 20, 20     -- one cell: the one we start in
ENV.db.actor = { level_vertex_id = function() return vid_of(6, 20) end }
local off = M.route_now(V(5.5, 20.5), V(25.5, 20.5))
check("a start off the navmesh routes anyway", off and #off >= 2, off and #off or "nil")
check("...beginning at the actor's own vertex", off and math.abs(off[1].x - 6.5) < 0.51,
	off and tostring(off[1].x) or "no route")
check("...and still reaching the goal", off and (25.5 - off[#off].x) <= OPT_ARRIVE,
	off and tostring(off[#off].x) or "no route")

-- The genuinely-off-mesh case must still be refused. A ladder or a rooftop leaves the
-- actor no usable vertex either, and inventing a start there would turn an honest "no
-- route" into a line of marks aimed at nothing. This check is what keeps the fix from
-- becoming a blanket suppression of the failure it was meant to explain.
ENV.db.actor = { level_vertex_id = function() return INVALID_VID end }
check("...but no usable actor vertex is still a refusal",
	M.search_begin(V(5.5, 20.5), V(25.5, 20.5)) == false)

-- Nothing changes for an actor on mapped ground -- and the fallback must not even be
-- REACHED there, or a level_vertex_id that lags a frame behind the position would start
-- quietly overriding a perfectly good start. The stub throws if it is consulted, so the
-- route completing at all is the assertion.
--
-- Note what this check does NOT claim. A route has always begun at the start NODE's
-- centre, never at the actor's exact position: rebuild() walks `came` over vertex ids and
-- reads their positions back. So the fallback cannot introduce a snap that was not
-- already there; the only thing it changes is WHICH node, and only when there was no
-- node at all. Half a cell is the width of the existing quantisation, not a new one.
hole_i0, hole_i1, hole_j0, hole_j1 = 1e9, 1e9, 1e9, 1e9
ENV.db.actor = { level_vertex_id = function() error("must not be consulted") end }
local onm = M.route_now(V(5.2, 20.9), V(25.5, 20.5))
check("an actor on the mesh never consults its vertex", onm and #onm >= 2,
	onm and #onm or "nil")
check("...and starts from the node it is standing in", onm and math.abs(onm[1].x - 5.5) < 0.01,
	onm and tostring(onm[1].x) or "no route")
ENV.db.actor = saved_actor

-- ==========================================================================
print("\n-- log format strings -----------------------------------------------")

M.verbose = true
printf_echo, fmt_violations = false, {}
M.route_now(V(5.5, 20.5), V(55.5, 20.5))
M.search_begin(V(5.5, 20.5), V(55.5, 20.5), { max_nodes = 3 })
while M.search_step(10) == "working" do end
M.search_begin(V(-50, -50), V(25.5, 20.5))
printf_echo = true
M.verbose = os.getenv("VERBOSE") and true or false
check("every format string uses only %s", #fmt_violations == 0,
	fmt_violations[1] and (#fmt_violations .. " bad, first: " .. fmt_violations[1]))

-- ==========================================================================
print(string.format("\n%d passed, %d failed", passed, failed))
print(string.format("(cost of the last full search: %d probes, %d position reads)",
	probe_calls, vpos_calls))
os.exit(failed == 0 and 0 or 1)
