-- Harness: exercise the iqm_nav route driver outside the game. Loads the REAL
-- gamedata/scripts/iqm_nav.script against stubbed versions of everything it talks
-- to -- iqm_core (who the target is), iqm_route (the search), ray_pick, device
-- and db.actor -- and drives it a tick at a time over a fake clock.
--
-- WHAT IS BEING TESTED. Not the drawing: iqm_nav no longer draws anything. It
-- decides which world points make up the route, how they are spaced, and how
-- visible each one is; iqm_core projects that list onto sprites. So everything
-- here is asserted through route_draw() and status().
--
-- WHY STUB iqm_route RATHER THAN LOAD IT. The A* itself already has its own
-- harness (tools/route-harness) over a synthetic navmesh; what is untested is the
-- POLICY on top -- when a search is allowed to start, what a walking actor costs,
-- whether losing and regaining sight of someone behaves, and whether any of that
-- survives the target moving. Every one of those is a state machine over time,
-- which is the thing that cannot be judged by walking around the Zone once.
--
-- Usage:
--   luajit tools/nav-harness/harness.lua
--   VERBOSE=1 luajit tools/nav-harness/harness.lua
--
-- Expected: "120 passed, 0 failed" and exit 0.

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

-- printf, faithful to Anomaly's (_g.script:612): it substitutes the literal token
-- "%s" and nothing else, so a stray "%.1f" prints raw AND shifts every later
-- argument left by one. Same check the other two harnesses run.
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
function VecMT:distance_to_sqr(o)
	local dx, dy, dz = o.x - self.x, o.y - self.y, o.z - self.z
	return dx * dx + dy * dy + dz * dz
end
function VecMT:distance_to(o)
	return math.sqrt(self:distance_to_sqr(o))
end
-- COMPARING TWO VECTORS IS A CRASH IN GAME, so it is a crash here (R2.41). luabind's
-- `vector` defines no __eq, and the engine's response to `a == b` on two of them is not
-- `false` -- it is "No such operator [__eq] defined in class [vector]", a SCRIPT RUNTIME
-- ERROR that takes the game down. R2.41 shipped one, in begin_search.
--
-- The stub used to be a plain table, where `==` is legal and quietly answers by identity,
-- so the harness ran the faulty line thousands of times and reported nothing. Worse than
-- silent: Lua 5.1 short-circuits userdata `==` on identity BEFORE consulting __eq, so even
-- in game the line only detonates when the two are different objects -- which for that
-- call site meant only when the goal was off the navmesh. A rare branch, in a stub that
-- could not express the failure, is how this reached a player.
--
-- This reproduces the engine exactly rather than being harsher than it: Lua applies the
-- same identity short-circuit to tables that it applies to userdata, so a stub comparing
-- an object with itself still answers true without reaching here. Which means the fixture
-- has to drive the branch where the two are genuinely different objects -- see the
-- off-navmesh goal section, which exists for that and would otherwise prove nothing.
VecMT.__eq = function()
	error("No such operator [__eq] defined in class [vector]" ..
	      " -- compare coordinates or a distance, never two vectors", 2)
end
local function V(x, y, z)
	return setmetatable({ x = x, y = y or 0, z = z or 0 }, VecMT)
end
ENV.vector = function() return V(0, 0, 0) end

-- ------------------------------------------------------------------ the world
local clock = 0
-- Counted, not just stubbed. Three of route-perf 4.5's findings were duplicate fetches of
-- exactly these -- the camera read twice a frame, the actor's position three times, the
-- clock again after update() had already been handed it -- and a fix that threads a value
-- down instead of refetching it is invisible to every behavioural assertion in this file.
-- So the calls are counted and the counts are asserted (see "one fetch per frame").
local n_clock, n_device, n_apos = 0, 0, 0
ENV.time_global = function() n_clock = n_clock + 1; return clock end

local actor_pos = V(0, 0, 0)
-- The engine's actor knows its navmesh node even when level.vertex_id refuses its
-- POSITION -- the node is sticky state, updated only when the actor reaches a mapped
-- cell. The stub models that divergence because the real thing has it; the behaviour it
-- drives lives in iqm_route.search_begin and is tested in the route harness (R2.34).
local actor_vid = nil
ENV.db = { actor = {
	position        = function() n_apos = n_apos + 1; return actor_pos end,
	level_vertex_id = function() return actor_vid end,
} }

local cam = V(0, 1.6, 0)
ENV.device = function() n_device = n_device + 1; return { cam_pos = cam } end

-- Two quest givers, because switching between them is its own case. `alive` and
-- presence are switchable per NPC: "the quest giver went offline / died" is a real
-- way for the driver to lose its target, and it must not leave a route behind.
local NPC_ID, NPC_ID2 = 4242, 4343
local npc = {
	[NPC_ID]  = { pos = V(30, 0, 0),   alive = true, here = true },
	[NPC_ID2] = { pos = V(-28, 0, 10), alive = true, here = true },
}
local function put(x, z, id) npc[id or NPC_ID].pos = V(x, 0, z or 0) end
local INVALID_VID = 4294967295
local BAD_VID     = 777777        -- in range, but not a vertex: see vertex_position below
-- Flat navmesh at y = 0 everywhere except a strip that has no vertex at all, so the
-- snapping path gets both of its branches exercised: nav pulls every interpolated
-- route point onto the mesh (a job iqm_pathline used to do, and which went missing
-- when the route moved to sprites), and has to pass through the ones it can't.
local hole_lo, hole_hi = 1e9, 1e9
local vid_queries = 0
-- Ground height as a function of x, so the height-snapping path has something to snap
-- TO. Flat by default (most fixtures only care about the 0.25 m lift); the slope fixture
-- swaps in a ramp. Note the stub reproduces the engine's key property: a node's x and z
-- are QUANTISED to the grid (0.1 m here) while its y is not -- which is the whole reason
-- snap_path may only take the y (see the note there, and R2.15).
local ground_y = function(x) return 0 end
ENV.level = {
	object_by_id = function(id)
		local n = npc[id]
		if not (n and n.here) then return nil end
		return {
			alive    = function() return n.alive end,
			position = function() return n.pos end,
			name     = function() return "stub_npc_" .. id end,
		}
	end,
	vertex_id = function(p)
		vid_queries = vid_queries + 1
		if p.x >= hole_lo and p.x <= hole_hi then return INVALID_VID end
		return 100000 + math.floor(p.x * 10)
	end,
	-- Walks the graph from `vid` along `dir` for at most `dist` metres and returns the
	-- furthest vertex it reaches -- stopping at the off-mesh hole, which is this world's
	-- only obstacle. That is what makes walk_direct testable: a target you can SEE across
	-- the hole is one you cannot walk straight to, which is the doorway case (R2.33j).
	vertex_in_direction = function(vid, dir, dist)
		local x = (vid - 100000) / 10
		local step = (dir.x >= 0) and 0.5 or -0.5
		local gone = 0
		while gone < dist do
			local nx = x + step
			if nx >= hole_lo and nx <= hole_hi then break end
			x, gone = nx, gone + 0.5
		end
		return 100000 + math.floor(x * 10)
	end,
	vertex_position = function(vid)
		-- The engine hands back a ZERO VECTOR for an id it does not like rather than
		-- failing (level_script.cpp:394-399), and an id can be disliked without being
		-- u32(-1) -- anything past the vertex count is. BAD_VID models that second case,
		-- which is the one a caller can mistake for a real position at the origin.
		if vid == INVALID_VID or vid == BAD_VID then return V(0, 0, 0) end
		local x = (vid - 100000) / 10
		return V(x, ground_y(x), 0)
	end,
}

-- The occlusion ray, modelled as a wall: anything cast from |x| >= wall_x is
-- blocked. Deliberately position-dependent rather than a single flag, because the
-- module uses ONE ray for two jobs -- "can I see the target" and "can I see this
-- bit of ground" -- and a route running through a wall has to be able to come back
-- partly visible and partly not.
local wall_x = 20
local ray_queries = 0
local RayMT = {}
RayMT.__index = RayMT
function RayMT:set_flags(f)     self.flags = f end
function RayMT:set_range(r)     self.range = r end
function RayMT:set_position(p)  self.px = p.x end
function RayMT:set_direction(d) end
function RayMT:query()
	ray_queries = ray_queries + 1
	if not wall_x then return false end
	if wall_x >= 0 then return self.px >= wall_x end
	return self.px <= wall_x
end
ENV.ray_pick = function() return setmetatable({}, RayMT) end

-- ------------------------------------------------------------------- iqm_core
local mk_target  = NPC_ID
local mk_overlay = true
-- The ground line's summon envelope, 0..1. 1 (fully summoned) for every fixture that
-- predates it, so those keep asking the question they were written to ask.
local mk_summon  = 1
-- The renderer owns which of the three route designs is drawn; the driver owns the
-- spacing that goes with it and pushes the choice across. Stubbed as the same
-- number-to-name mapping iqm_core has (RTE.NAMES).
local MK_STYLES  = { [0] = "classic", [1] = "band", [2] = "arrows", [3] = "glyph" }
local mk_style   = 1
local mk_tint    = { 176, 196, 124 }
-- Set true to model a target that is NOT online -- a task marker across the level rather
-- than a tracked NPC. iqm_nav must still route to it, and must skip the visibility ray,
-- which is asking about geometry that is not loaded.
local mk_online = true
-- The target's own level vertex, when it has one worth offering. nil for an ordinary
-- NPC fixture; set by the off-mesh fixtures, which are the only ones that consult it.
local mk_lvid = nil
ENV.iqm_core = {
	route_target    = function() return mk_target end,
	-- The contract iqm_nav actually consumes since the route began following the SELECTED
	-- task's marker: id, world position, and whether that object is online. iqm_core
	-- resolves the position now, because an offline marker still has an alife one and the
	-- old level.object_by_id path dropped it as "gone".
	route_goal      = function()
		local n = mk_target and npc[mk_target]
		if not n then return nil end
		-- The real one returns nil for a dead creature and for a target on another
		-- level; `here` models "online", and an offline target still yields a position
		-- because alife has one.
		if n.here and not n.alive then return nil end
		if not n.here and mk_online then return nil end
		-- Fourth return: the navmesh node the target claims. Only consulted when its
		-- POSITION turns out to be off the mesh -- a waypoint placed on the PDA map has
		-- an invented y and a real vertex, and this is how the real one gets across.
		return mk_target, n.pos, (n.here and mk_online) and true or false, mk_lvid
	end,
	overlay_visible = function() return mk_overlay end,
	-- The ground line's summon envelope (R2.58). MODELLED, not merely stubbed: the real
	-- route_alpha folds the PDA/HUD pair in and answers 0 whenever the world is not being
	-- drawn, so a stub that returned mk_summon on its own would hold the gate open through
	-- every existing test in section C4 and quietly stop them gating anything.
	route_alpha     = function() return (mk_overlay and mk_summon) or 0 end,
	route_style     = function(n)
		if n ~= nil then mk_style = n end
		return MK_STYLES[mk_style]
	end,
	route_tint      = function(r, g, b)
		if r then mk_tint = { r, g, b } end
		return mk_tint[1], mk_tint[2], mk_tint[3]
	end,
}

-- ------------------------------------------------------------------- iqm_route
-- A scripted stand-in for the real search: takes `latency` calls to search_step
-- before answering, then returns a straight line from `from` to `to`. Enough to
-- exercise every branch the driver has around a search without dragging the
-- navmesh in.
local RT = {
	begins = 0, aborts = 0, owner = nil, latency = 2, will_fail = false,
	refuse = false,      -- search_begin itself returns false (endpoint off-mesh)
	degenerate = false,  -- succeeds, but with a single collapsed node
	partial = false,     -- succeeded, but stopping short of the goal
	closest = nil,       -- ...by this many metres (iqm_route.search_closest)
	via = nil,           -- a waypoint, so the route can have a real CORNER in it
	from = nil, to = nil, left = 0, state = "idle",
	budgets = {},        -- max_nodes of every search begun, in order (R2.35 escalation)
}
ENV.iqm_route = {
	search_begin = function(from, to, opts)
		RT.begins = RT.begins + 1
		RT.budgets[#RT.budgets + 1] = opts and opts.max_nodes
		if RT.refuse then RT.state, RT.owner = "failed", nil; return false end
		RT.from, RT.to = V(from.x, from.y, from.z), V(to.x, to.y, to.z)
		RT.left, RT.state = RT.latency, "working"
		RT.owner = opts and opts.owner
		return true
	end,
	search_step = function()
		if RT.state ~= "working" then return RT.state end
		RT.left = RT.left - 1
		if RT.left > 0 then return "working" end
		RT.state = RT.will_fail and "failed" or "done"
		return RT.state
	end,
	search_state  = function() return RT.state end,
	search_owner  = function() return RT.owner end,
	search_result = function()
		if RT.state ~= "done" then return nil end
		if RT.degenerate then return { RT.to } end
		-- A whole node list, for fixtures that need more shape than one via point can
		-- express -- a run with lateral jitter on every node, which is what a real
		-- search returns off a grid-aligned navmesh.
		if RT.nodes then return RT.nodes end
		if RT.via then return { RT.from, V(RT.via.x, RT.via.y, RT.via.z), RT.to } end
		return { RT.from, RT.to }
	end,
	search_abort  = function()
		RT.aborts = RT.aborts + 1
		RT.state, RT.owner = "idle", nil
	end,
	search_partial = function() return RT.partial and true or false end,
	search_closest = function() return RT.closest end,
	debug_active  = function() return false end,
	-- Chaikin corner cutting with the metre-capped cut, near enough to the real thing
	-- (iqm_route.smooth) for the driver's purposes: what matters HERE is that the vertex
	-- placement and the chevron spacing behave on a rounded corner rather than a folded
	-- one, since the driver now sees smoothed nodes. The navmesh VETO -- the half that
	-- needs a real graph -- is covered in tools/route-harness instead.
	sm_calls = 0,
	smooth = function(nodes, passes)
		RT.sm_calls = RT.sm_calls + 1
		if not (nodes and #nodes >= 3) then return nodes end
		local CUT = 1.5
		for _ = 1, (passes or 3) do
			local out, m = { nodes[1] }, 1
			for i = 2, #nodes - 1 do
				local b = nodes[i]
				for _, p in ipairs({ nodes[i - 1], nodes[i + 1] }) do
					local dx, dz = p.x - b.x, p.z - b.z
					local len = math.sqrt(dx * dx + dz * dz)
					local t = math.min(0.25, len > 0 and CUT / len or 0.25)
					m = m + 1
					out[m] = V(b.x + dx * t, b.y, b.z + dz * t)
				end
			end
			m = m + 1
			out[m] = nodes[#nodes]
			nodes = out
		end
		return nodes
	end,
	-- the real densify, near enough: straight legs resampled every `step` metres
	dn_calls = 0,
	densify = function(nodes, step)
		RT.dn_calls = RT.dn_calls + 1
		local out, m = {}, 0
		for i = 1, #nodes - 1 do
			local a, b = nodes[i], nodes[i + 1]
			local dx, dz = b.x - a.x, b.z - a.z
			local len = math.sqrt(dx * dx + dz * dz)
			local n = math.max(1, math.ceil(len / step))
			for k = 0, n - 1 do
				m = m + 1
				out[m] = V(a.x + dx * (k / n), a.y, a.z + dz * (k / n))
			end
		end
		m = m + 1
		out[m] = V(nodes[#nodes].x, nodes[#nodes].y, nodes[#nodes].z)
		return out
	end,
	-- The clearance pass (R2.23) is the real module's business and has its own fixtures in
	-- the route harness. What is worth asserting HERE is only that the driver runs it, and
	-- runs it on the DENSE list rather than the sparse one -- the pass has no point on an
	-- 8 m leg with no interior point. So the stub counts calls and records what it saw.
	clr_calls = 0,
	clr_n = 0,
	clearance = function(pts)
		RT.clr_calls = RT.clr_calls + 1
		RT.clr_n = pts and #pts or 0
		return pts
	end,
}

ENV.RegisterScriptCallback = function() end
ENV.ui_debug_launcher = nil

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
local M = {}
ENV.iqm_nav = M
setmetatable(M, { __index = ENV })
local chunk = assert(loadfile("gamedata/scripts/iqm_nav.script"))
setfenv(chunk, M)
chunk()

-- ----------------------------------------------------------------- utilities
local function tick(ms, n)
	for _ = 1, (n or 1) do
		clock = clock + (ms or 50)
		M.update(clock)
	end
end

local function drawing()
	local rd = M.route_draw()
	return rd and rd.n or 0
end

--- Run until there is something to draw, or give up. Most tests want to start from
--  "the route is up", not from the frame-by-frame path to it.
local function settle(n)
	for _ = 1, (n or 20) do
		tick(50)
		if drawing() > 0 then return true end
	end
	return drawing() > 0
end

local function fresh(opts)
	clock = clock + 100000            -- clear every cooldown
	actor_pos = V(0, 0, 0)
	cam = V(0, 1.6, 0)                -- fixtures that walk the actor move this too
	npc[NPC_ID]  = { pos = V(30, 0, 0),   alive = true, here = true }
	npc[NPC_ID2] = { pos = V(-28, 0, 10), alive = true, here = true }
	mk_target, mk_overlay, wall_x = NPC_ID, true, 20
	mk_summon = 1                     -- fully summoned unless a fixture says otherwise
	mk_online, mk_lvid = true, nil
	RT.begins, RT.aborts, RT.latency = 0, 0, 2
	RT.budgets = {}
	RT.clr_calls, RT.clr_n = 0, 0
	RT.sm_calls, RT.dn_calls = 0, 0
	RT.will_fail, RT.refuse, RT.state = false, false, "idle"
	RT.degenerate = false
	RT.partial, RT.closest = false, nil
	RT.via, RT.nodes = nil, nil
	hole_lo, hole_hi = 1e9, 1e9
	actor_vid = nil
	ground_y = function(x) return 0 end
	local o = { on = true, draw = 40, gap = 10, xray = true }
	if opts then for k, v in pairs(opts) do o[k] = v end end
	M.configure(o)
end

-- ==========================================================================
print("-- the feature switch ------------------------------------------------")

fresh({ on = false })
tick(50, 10)
check("off draws nothing", drawing() == 0)
check("off starts no search", RT.begins == 0)

fresh()
check("configure resets to idle", M.status().target == nil and drawing() == 0)

-- ==========================================================================
-- The route follows the SELECTED task's marker now, and that marker is very often not a
-- tracked NPC standing next to you -- it is wherever the objective is, which means OFFLINE.
-- The old code resolved the id with level.object_by_id and treated a failure as "target
-- gone", so an offline marker drew nothing at all. iqm_core.route_goal resolves the
-- position instead (from alife when needed) and says whether the object is online.
print("\n-- an offline target (a task marker across the level) ----------------")

fresh()
npc[NPC_ID].here = false          -- not online: no rendered geometry, alife position only
mk_online = false
check("an offline target still routes", settle(), "nothing drawn")
check("...and is adopted as the target", M.status().target == NPC_ID)

-- The visibility gate exists to silence the route when you can SEE the target up close.
-- An offline target has nothing loaded to see, so the ray would be asking about empty
-- space; iqm_nav must treat it as hidden and draw unconditionally. Put it inside VIS_NEAR
-- with a clear line of sight -- the case that silences an ONLINE target -- and it must
-- still draw.
fresh()
npc[NPC_ID].here = false
mk_online = false
npc[NPC_ID].pos = V(12, 0, 0)     -- inside VIS_NEAR (25 m)
wall_x = nil                      -- nothing blocking: an online target would be silenced
check("an offline target is not silenced by line of sight", settle(), "nothing drawn")

fresh()
npc[NPC_ID].pos = V(12, 0, 0)
wall_x = nil
tick(50, 10)
check("...whereas a visible ONLINE target up close still is", drawing() == 0,
      "drew " .. tostring(drawing()))

fresh()
mk_target = nil
tick(50, 10)
check("no goal at all draws nothing", drawing() == 0)
check("...and starts no search", RT.begins == 0, tostring(RT.begins))

-- ==========================================================================
print("\n-- the happy path ----------------------------------------------------")

fresh()
tick(50)
check("the first tick adopts the target", M.status().target == NPC_ID)
check("...and starts exactly one search", RT.begins == 1, tostring(RT.begins))
check("...owned by iqm_nav, not the debug driver", RT.owner == "iqm_nav", tostring(RT.owner))
check("...without publishing anything yet", drawing() == 0)

check("points appear once the search finishes", settle())
local rd = M.route_draw()
check("...enough of them to read as a route", rd.n >= 6, tostring(rd.n))
-- NEAR_TRIM is 0 again (R2.25, reversing R2.13): the stroke starts at the cursor, i.e. at
-- the actor's feet, and the near plane is handled by the renderer's HEAD/HMIN fade rather
-- than by amputating the first few metres. The actor stub stands at the origin and the path
-- is sampled every metre, so the first vertex is the path's own head.
check("...starting at your feet, not a few metres ahead of you",
	rd.p[1].x < 1, tostring(rd.p[1].x))
check("...and ending near the target", rd.p[rd.n].x > 25, tostring(rd.p[rd.n].x))
check("...and every vertex carrying its own alpha", rd.a[1] ~= nil and rd.a[rd.n] ~= nil)

-- The list is a VERTEX list for one continuous stroke, so what matters is that no
-- segment is long enough to visibly cut a corner -- not that the spacing is even.
-- (It used to be a set of independent marks, and this asserted even arclength
-- spacing; a line's vertex spacing is invisible, only its shape is not.)
--
-- The ceiling is per-segment since R2.13: a segment may run as far as its own distance
-- from the camera over SEG_DIV, clamped to SEG_MIN..SEG_MAX. Checked against the
-- allowance at the segment's NEAR end, which is the one the emitter used, and with a
-- PATH_STEP of slack because a single path leg longer than the allowance still yields
-- one segment -- there is no intermediate point to cut it at.
local function allow_at(p)
	local dx, dy, dz = p.x, p.y - 1.6, p.z
	local s = math.sqrt(dx * dx + dy * dy + dz * dz) / 7.0   -- SEG_DIV
	return math.max(1.0, math.min(5.0, s))                   -- SEG_MIN .. SEG_MAX
end
local segs_ok = true
for i = 2, rd.n do
	local g = math.abs(rd.p[i].x - rd.p[i - 1].x)
	if g > math.max(1.0, allow_at(rd.p[i - 1])) + 0.001 then segs_ok = false end
end
check("...joined by segments no longer than their distance allows", segs_ok)

-- ...and the point of that rule: detail in proportion to the screen area it covers.
-- The near end of a long straight is cut finer than the far end, which is exactly what
-- a constant SEG_MAX could not do.
local near_g = math.abs(rd.p[2].x - rd.p[1].x)
local far_g  = math.abs(rd.p[rd.n].x - rd.p[rd.n - 1].x)
check("...cut finer near the camera than far from it", near_g < far_g - 0.5,
	string.format("%.2f m near vs %.2f m far", near_g, far_g))
check("...and snapped onto the navmesh, lifted clear of the floor",
	math.abs(rd.p[1].y - 0.25) < 1e-6, tostring(rd.p[1].y))

-- Chevrons are their own list since R2.16, placed at exact arclength and interpolated
-- onto the leg they fall on -- so they are no longer tied to a vertex, and their spacing
-- can be asserted exactly rather than within a vertex's slop.
check("...with direction chevrons on it", rd.nc > 0, tostring(rd.nc))
check("...counted in the status dump", M.status().chevs == rd.nc,
	tostring(M.status().chevs))
check("...each carrying a unit direction of travel", (function()
	for k = 1, rd.nc do
		local l = math.sqrt(rd.cdx[k] ^ 2 + rd.cdz[k] ^ 2)
		if math.abs(l - 1) > 1e-6 then return false end
	end
	return true
end)())
check("...and naming a vertex whose alpha it can borrow", (function()
	for k = 1, rd.nc do
		local i = rd.ci[k]
		if not (i and i >= 1 and i <= rd.n) then return false end
	end
	return true
end)())

-- EXACTLY the configured gap, on a straight route: gap = 10, so 10.000 m apart. The old
-- per-vertex flags could only manage 8-14 m here, because a chevron had to land on a
-- vertex and the vertices are 1-5 m apart.
--
-- ...from the THIRD mark on, since R2.33c. The schedule is 0, gap/2, gap, 2*gap, 3*gap --
-- one extra mark dropped into the near hole, which is one gap of bare floor the player
-- can never be closer to than the spacing. Inserting it between 0 and gap makes the first
-- TWO intervals half-length, not one: the near end is deliberately denser.
local worst_gap, prev = 0, nil
for k = 3, rd.nc do
	if prev then worst_gap = math.max(worst_gap, math.abs(math.abs(rd.cp[k].x - prev) - 10)) end
	prev = rd.cp[k].x
end
check("...spaced by arclength at exactly the configured gap", worst_gap < 0.01,
	string.format("%.3f m off", worst_gap))
check("...with one extra mark at HALF a gap, in the near hole (R2.33c)",
	rd.nc > 2 and math.abs(rd.cp[2].x - 5) < 0.01,
	rd.nc > 2 and string.format("%.2f, wanted 5.00", rd.cp[2].x) or "too few")
-- The mark this does NOT rely on. k = 0 sits on the actor's own position, under the
-- camera, and is outside the frustum at any pitch short of straight down -- which is why
-- lowering the renderer's near cut-off did not fill the hole and this does. Asserted so
-- that "the first mark is at the player" stays a fact about the schedule rather than
-- something anyone mistakes for the near fix.
check("...and the mark at the player's own feet is still there, still invisible",
	rd.nc > 0 and math.abs(rd.cp[1].x) < 0.01,
	rd.nc > 0 and string.format("%.2f", rd.cp[1].x) or "none")
-- ...and every one of them at a whole gap ahead of the ACTOR (R2.29), who is standing at
-- the origin in this fixture. That is what holds a mark's distance -- and so its drawn
-- size and angle -- constant while he walks.
check("...at whole gaps ahead of the actor", (function()
	for k = 1, rd.nc do
		if k ~= 2 and math.abs(rd.cp[k].x - math.floor(rd.cp[k].x / 10 + 0.5) * 10) > 0.01 then
			return false
		end
	end
	return rd.nc > 0
end)(), rd.nc > 0 and string.format("first at %.2f", rd.cp[1].x) or "none")

local begins_settled = RT.begins
tick(50, 20)
check("a settled route starts no further searches", RT.begins == begins_settled,
	tostring(RT.begins))
check("...and keeps publishing", drawing() > 0)

-- ==========================================================================
print("\n-- the lead-in: the head of the route follows you sideways (R2.33) ----")
-- The route is an A* path and the marks sit ON it, so before R2.33 a strafe left the whole
-- train off to one side, unchanged, until DRIFT_TOL repathed. Now the near end is pulled
-- laterally onto the actor and decays back onto the search's answer over LEAD_M.
--
-- The fixture's path runs along +x from the origin, so a strafe is a change in z and the
-- offset is readable straight off the drawn points. Baselines are copied as NUMBERS
-- first: rd.p[i] stops being a reference into `path` the moment the blend has anything to
-- say, which is the whole mechanism.
local base_z, base_cz = {}, {}
for i = 1, rd.n do base_z[i] = rd.p[i].z end
for k = 1, rd.nc do base_cz[k] = rd.cp[k].z end

actor_pos = V(0, 0, 1.5)          -- inside DRIFT_TOL, so this must NOT repath
tick(50)
check("a strafe does not repath", RT.begins == begins_settled, tostring(RT.begins))
check("...and the head of the line comes to meet you",
	math.abs(rd.p[1].z - (base_z[1] + 1.5)) < 0.05,
	string.format("z %.3f, wanted %.3f", rd.p[1].z, base_z[1] + 1.5))
check("...while the far end stays where the search put it",
	math.abs(rd.p[rd.n].z - base_z[rd.n]) < 1e-6,
	string.format("moved %.3f", rd.p[rd.n].z - base_z[rd.n]))
-- Monotone decay, and back on the line by LEAD_M. A blend that is not monotone is a kink
-- in the stroke, which reads as the route wobbling rather than leading.
check("...decaying monotonically along the route", (function()
	local prev = math.huge
	for i = 1, rd.n do
		local o = rd.p[i].z - base_z[i]
		if o < -1e-6 or o > prev + 1e-6 then return false end
		prev = o
	end
	return true
end)())
check("...and fully back on it 8 m along", (function()
	for i = 1, rd.n do
		if rd.s[i] > 8.0 and math.abs(rd.p[i].z - base_z[i]) > 1e-6 then return false end
	end
	return true
end)())
-- The marks have to move WITH the stroke or they float off it, and they have to turn with
-- it too: the blend adds a -lead/LEAD_M term to the tangent, so a mark inside the ramp
-- points back toward the line (negative z here) rather than straight down the old path.
check("the marks move with it", math.abs(rd.cp[1].z - (base_cz[1] + 1.5)) < 0.25,
	string.format("%.3f vs %.3f", rd.cp[1].z, base_cz[1] + 1.5))
check("...and turn back toward the line", rd.cdz[1] < -0.05, tostring(rd.cdz[1]))
check("...still on unit headings", (function()
	for k = 1, rd.nc do
		if math.abs(math.sqrt(rd.cdx[k] ^ 2 + rd.cdz[k] ^ 2) - 1) > 1e-6 then return false end
	end
	return true
end)())

-- LEAD_MAX. Past 2 m the head stops following rather than being dragged further, because
-- a wide drag is a line through a wall and there is no mesh test on it. 4.5 m is still
-- inside DRIFT_TOL, so this is a real state the game can sit in.
actor_pos = V(0, 0, 4.5)
tick(50)
check("a wide strafe clamps instead of dragging the line through the wall",
	math.abs(rd.p[1].z - (base_z[1] + 2.0)) < 0.05,
	string.format("z %.3f, wanted %.3f", rd.p[1].z, base_z[1] + 2.0))

actor_pos = V(0, 0, 0)
tick(50)
check("stepping back onto the line puts the route exactly back on it", (function()
	for i = 1, rd.n do
		if math.abs(rd.p[i].z - base_z[i]) > 1e-6 then return false end
	end
	return true
end)())
check("...as the path's own points, not a copy of them", rd.p[rd.n].z == base_z[rd.n])
check("...and still no repath from any of it", RT.begins == begins_settled,
	tostring(RT.begins))

-- ==========================================================================
print("\n-- the search budget has a shape, and the shape was wrong (R2.33f) ----")
-- `400 + 10 * d` gave the SMALLEST allowance to the NEAREST target. A player's log has a
-- 19.6 m target granted 596 expansions and giving up 6.0 m short of a 3.0 m arrival --
-- which is the route that was seen running at a wall instead of through the doorway.
-- Successful searches in the same logs ran to 836 expansions.
--
-- So the property is not the formula. It is that a near target gets at least as much room
-- as the worst search anyone has watched succeed, and that more distance never buys less.
local WORST_OBSERVED = 836
check("node_budget is callable, so its shape can be tested at all",
	type(M.node_budget) == "function")
if type(M.node_budget) == "function" then
	check("a near target gets more room than the worst successful search observed",
		M.node_budget(19.6) > WORST_OBSERVED,
		string.format("19.6 m -> %s nodes, worst success %s", M.node_budget(19.6), WORST_OBSERVED))
	check("...and so does a target close enough to touch", M.node_budget(4) > WORST_OBSERVED,
		tostring(M.node_budget(4)))
	check("distance never buys LESS budget", (function()
		local prev = -1
		for d = 0, 300, 2 do
			local b = M.node_budget(d)
			if b < prev then return false end
			prev = b
		end
		return true
	end)())
	-- Bounded, and bounded by a WALL-CLOCK rather than by a number anyone likes the look
	-- of. The cap is the worst case a player waits through before a route appears, so it
	-- is checked as time at the configured step rate -- which is also what stops the cap
	-- being raised without the step rate being thought about.
	-- A TRAP TOPOLOGY, which is what the floor is really for (R2.35). Measured in the Bar:
	-- General Petrenko 16.0 m away through a wall is a 258-hop, ~175 m walk round the whole
	-- block, and A* points h straight through that wall for the entire search. It explores
	-- 9382 nodes to find the way round -- against the 607 the curve grants at that distance,
	-- and the 3000 the old floor did. So the floor is not slack, it is the only term that
	-- covers topology, and topology does not scale with crow-flight distance at all.
	local TRAP_D, TRAP_NODES = 16.0, 9382
	check("a near target behind a wall gets enough room for the measured trap route",
		M.node_budget(TRAP_D) > TRAP_NODES,
		string.format("%.1f m -> %s nodes, trap needs %s", TRAP_D, M.node_budget(TRAP_D),
			TRAP_NODES))
	local cap = M.node_budget(1e6)
	check("...and it stays bounded, so a hopeless search cannot run for ever",
		cap <= 15000, tostring(cap))
	-- The cost side of the same number, as WALL CLOCK rather than a figure anyone likes the
	-- look of. STEP_BUDGET is read out of the source rather than written here, because
	-- raising the floor without raising it is exactly the mistake this is meant to catch.
	local nf = assert(io.open("gamedata/scripts/iqm_nav.script", "r"))
	local nav_src = nf:read("*a")
	nf:close()
	local step = tonumber(nav_src:match("\nlocal STEP_BUDGET%s*=%s*(%d+)"))
	local repath = tonumber(nav_src:match("\nlocal REPATH_MIN%s*=%s*(%d+)"))
	check("STEP_BUDGET and REPATH_MIN are readable", step and repath,
		tostring(step) .. "/" .. tostring(repath))
	if step and repath then
		-- THIS USED TO ASSERT THE FLOOR FITS INSIDE REPATH_MIN, and that was wrong on its
		-- own terms. Its stated reason was "or a route can be asked for again before it has
		-- finished answering" -- but nothing can ask: update() returns as soon as it sees
		-- `searching`, so a search in flight is never restarted and REPATH_MIN gates only
		-- the interval AFTER one finishes. The check was a latency preference wearing a
		-- correctness argument, and at 3000 nodes it happened to hold, so it was never
		-- examined. The invariant it claimed to protect is real and is tested directly
		-- below; what remains here is the honest question, which is how long a player
		-- waits.
		local cap_ms = M.node_budget(1e6) / step * 16
		check("the worst case is still under two seconds of waiting",
			cap_ms <= 2000, string.format("%.0f ms at %d nodes/frame", cap_ms, step))
		-- Worth stating plainly because it is the price of the floor: a hard search now
		-- occupies a real slice of the frame while it runs. 30.3 us an expansion, measured.
		local per_frame = step * 30.3 / 1000
		check("...and a frame spends under 5 ms on the search while one is live",
			per_frame < 5.0, string.format("%.2f ms/frame", per_frame))
	end
end

-- The invariant the REPATH_MIN check above was really reaching for, tested for what it is:
-- a search already in flight is never restarted, whatever the budget or the clock says.
-- With the floor at 12000 a search spans far more than REPATH_MIN, so this stopped being
-- academic the moment the floor moved.
fresh({ draw = 40, gap = 10 })
put(40)
RT.latency = 30                       -- a long search, deliberately outlasting REPATH_MIN
tick(50, 3)
local begun = RT.begins
check("a search is running", M.status().searching, tostring(M.status().searching))
clock = clock + 100000                -- every cooldown and repath interval well expired
actor_pos = V(20, 0, 0)               -- and the actor has drifted right off the line
cam = V(20, 1.6, 0)
tick(50, 20)
check("...and is never restarted while in flight, however stale the clock",
	RT.begins == begun and M.status().searching,
	string.format("%d searches vs %d, searching=%s", RT.begins, begun,
		tostring(M.status().searching)))
RT.latency = 2

-- ==========================================================================
print("\n-- the route keeps flowing while a search runs (R2.33l) ---------------")
-- The marks hold a fixed distance ahead of the player (R2.29), and that only happens
-- because place_chevrons runs EVERY frame. update() used to return as soon as a search was
-- in flight, which nailed them to the ground while the player kept walking. At the old
-- 596-node budget that froze the route for a quarter of a second and nobody saw it; at
-- R2.33k's 3000-6000 it is over a second, with a retry every ten metres -- reported as
-- "huge pauses where the routes don't update, then it jerks into a new position".
fresh({ draw = 40, gap = 10 })
put(30)
settle()

RT.latency = 200                      -- a search that will not finish while we watch
-- OFF the line, not along it: walking along a route advances the cursor and is not drift,
-- which is the whole of R2.33k. Eight metres to the side is past DRIFT_TOL.
actor_pos = V(6, 0, 8)
cam = V(6, 1.6, 8)
tick(50, 20)                          -- long enough to clear REPATH_MIN, which gates it
check("straying off the line starts a search", M.status().searching, M.status().why)
local before = M.route_draw().cp[2].x

actor_pos = V(14, 0, 8)               -- ...and keep walking while it runs
cam = V(14, 1.6, 8)
tick(50, 4)
-- Not "moved a bit": moved with the PLAYER. He covered 8 m, so the marks must too, since
-- holding a fixed distance ahead of him is the whole property. A weaker threshold passed
-- while the cursor was still frozen and the marks were sliding 1.49 m within one leg.
check("...and the marks still hold station ahead of you while it runs",
	M.status().searching and math.abs(M.route_draw().cp[2].x - before) > 6,
	string.format("mark at %.2f, was %.2f, searching=%s",
		M.route_draw().cp[2].x, before, tostring(M.status().searching)))
check("...with the route still published rather than blanked", drawing() > 0)
RT.latency = 2
-- Walking ALONG a route is not drift -- the cursor advances and DRIFT_TOL never trips --
-- and the goal has not moved, so before R2.33k nothing ever retried a route that came
-- back short. Reported exactly: a bad route on a fresh load, and once a good one appears
-- "it seems to stick to that". The search fails at 59 m and succeeds at 32 m, so walking
-- closer is the fix -- if anything asks again.
fresh({ draw = 40, gap = 10 })
put(60)
RT.partial, RT.closest = true, 20.0
settle()
local after_first = RT.begins
actor_pos = V(4, 0, 0)                -- four metres closer: not yet worth re-asking
cam = V(4, 1.6, 0)
tick(50, 30)
check("a partial is not retried for every step you take", RT.begins == after_first,
	string.format("%d vs %d", RT.begins, after_first))

actor_pos = V(14, 0, 0)               -- now well past RETRY_D
cam = V(14, 1.6, 0)
tick(50, 30)
check("...but it is retried once you have covered some ground",
	RT.begins > after_first, string.format("%d vs %d", RT.begins, after_first))

-- ...and a COMPLETE route is not re-run every ten metres to be told it is still complete.
fresh({ draw = 40, gap = 10 })
put(60)
settle()
local complete_begins = RT.begins
actor_pos = V(16, 0, 0)
cam = V(16, 1.6, 0)
tick(50, 30)
check("a complete route is left alone however far you walk along it",
	RT.begins == complete_begins,
	string.format("%d vs %d", RT.begins, complete_begins))
actor_pos = V(0, 0, 0)
cam = V(0, 1.6, 0)

-- ==========================================================================
print("\n-- the post-search tail waits a frame (route-perf 4.6) -----------------")

-- The frame the A* says "done" already pays its own expansions, the rebuild and the string
-- pull -- 2.886 ms measured in l05_bar -- and the driver used to run smooth x3, densify,
-- clearance and snap before that same frame ended, for ~3.9 ms once per 25 s. That is the
-- worst single frame this feature has, and the tail is a pure function of the raw node
-- list, so it can simply happen next frame.
--
-- Nothing in the 271 assertions above could see the split: settle() ticks until there is
-- something to draw, and one frame later is still settled. What follows drives the frames
-- one at a time and pins WHICH frame each half lands on.
-- Tick until a NEW search has finished. Both halves of the condition matter: RT.state stays
-- "done" after a search completes, so waiting on it alone returns instantly on the second
-- call and the frame-by-frame pins below would be reading a settled route.
local function to_done(limit)
	local b0, n = RT.begins, 0
	while not (RT.begins > b0 and RT.state == "done") and n < (limit or 40) do
		tick(50)
		n = n + 1
	end
	return n
end

fresh({ draw = 40, gap = 10 })
put(30)
RT.latency = 3
local found_on = to_done()
check("the search reaches \"done\" on a frame we can name", RT.state == "done" and found_on < 30,
	string.format("%d frames", found_on))
-- The finishing frame does the search and stops. Counted on all three passes and not just
-- clearance: a deferral that moved only the last of them would leave most of the 1.09 ms
-- exactly where it was.
check("...and that frame runs none of the tail",
	RT.sm_calls == 0 and RT.dn_calls == 0 and RT.clr_calls == 0,
	string.format("smooth %d, densify %d, clearance %d",
		RT.sm_calls, RT.dn_calls, RT.clr_calls))
check("...with nothing published yet, and the status still saying searching",
	drawing() == 0 and M.status().searching == true,
	string.format("%d drawn, why: %s", drawing(), tostring(M.status().why)))

tick(50)
check("the NEXT frame runs the tail, once",
	RT.sm_calls == 1 and RT.dn_calls == 1 and RT.clr_calls == 1,
	string.format("smooth %d, densify %d, clearance %d",
		RT.sm_calls, RT.dn_calls, RT.clr_calls))
check("...and the route is up on it", drawing() > 0 and M.status().searching == false,
	string.format("%d drawn, searching=%s", drawing(), tostring(M.status().searching)))

-- ...and the raw list must not outlive the search that produced it. A teardown between the
-- two frames leaves a node list with nobody to draw it, and the next search's FIRST frame
-- would claim it: the driver would publish the previous target's route and then stop
-- stepping the live search, because claiming the pending list is what ends `searching`.
-- Loud in game -- a route to where you were last going -- and invisible to every assertion
-- that starts from a settled route.
fresh({ draw = 40, gap = 10 })
put(30)
RT.latency = 3
to_done()
check("a route can be torn down between the search and its tail", RT.state == "done"
	and RT.clr_calls == 0, string.format("clearance %d", RT.clr_calls))
mk_target = nil
tick(50, 3)
check("...and nothing is drawn from the list it left behind",
	drawing() == 0 and RT.clr_calls == 0,
	string.format("%d drawn, clearance %d", drawing(), RT.clr_calls))


-- The new target is off the +x axis the old one sat on, so the drawn route names which
-- search it came from.
put(0, 40)
mk_target = NPC_ID
RT.latency = 2
settle()
local p2 = M.route_draw().p[2]
check("...and the next route is the new search's, not the abandoned one",
	drawing() > 0 and p2 and p2.z > 0.9 and p2.x < 0.4,
	string.format("second vertex at %.2f/%.2f -- the abandoned route ran along +x",
		p2 and p2.x or 0, p2 and p2.z or 0))
-- ==========================================================================
print("\n-- a route whose far end cannot see the target (R2.33m/p) -------------")
-- The shortfall alone cannot tell a good ending from a bad one: stopping 6 m short in the
-- same room is a route that delivered you, and stopping 6 m short through a wall is a line
-- of marks pointing into masonry. Same number, opposite meaning -- so one ray from the
-- route's last point to the target tells them apart.
--
-- It is REPORTED and never acted on. Gating `publish` on it shipped for one session and
-- took out the ground route AND the minimap trail together -- both read the same
-- route_draw() -- because the ray aimed at the target's FEET and so reported blocked in
-- open ground. These checks pin both halves: the flag tracks the geometry, and the route
-- is drawn either way.
fresh({ draw = 40, gap = 10 })
put(30)
RT.partial, RT.closest = true, 8.0
wall_x = 25                           -- the route's far end is past it
settle()
tick(50, 10)
check("a partial whose end cannot see the target is flagged", M.status().dead_end == true,
	tostring(M.status().dead_end))
check("...and is STILL DRAWN -- the flag is a diagnostic, not a gate", drawing() > 0,
	"why: " .. tostring(M.status().why))

fresh({ draw = 40, gap = 10 })
put(30)
RT.partial, RT.closest = true, 8.0
wall_x = nil                          -- nothing in the way
settle()
tick(50, 10)
check("...while an end that CAN see the target is not flagged",
	not M.status().dead_end, tostring(M.status().dead_end))
check("...and draws too", drawing() > 0, "why: " .. tostring(M.status().why))

fresh({ draw = 40, gap = 10 })
put(30)
RT.partial, RT.closest = true, 1.0
wall_x = 25
settle()
tick(50, 10)
check("a route that stops a metre short is never even tested", not M.status().dead_end,
	tostring(M.status().dead_end))

-- ==========================================================================
-- ==========================================================================
print("\n-- a route to nowhere stops pretending (R2.33g) -----------------------")
-- A partial that stops a metre short IS the route: you walk it and you arrive. One that
-- stops six metres short is a confident line up to a wall with nothing on screen saying
-- so -- reported twice, and no search budget fixes it (measured: a closest approach flat
-- at 6.0 m across budgets of 596 and 1500). So the tail of such a route fades out.
--
-- The property has two halves and the second is the one easy to get wrong: a LONG route
-- capped at draw_m also stops short of its target, and ITS drawn end is open path rather
-- than a barrier. Fading that would be a lie in the other direction.
-- The fixture's wall (wall_x = 20) occludes the far end and eases it to DIM_MIN = 0.22,
-- which is under every threshold below. The first version of these checks passed on
-- OCCLUSION rather than on the fade, and two of them failed on it -- so the wall is pushed
-- out of the way and the only thing that can dim a tail here is the thing being tested.
local function clear_view() wall_x = 1e9 end

local function tail_alpha()
	local rd = M.route_draw()
	if not (rd and rd.n > 1) then return nil end
	return rd.a[rd.n], rd.a[1]
end

fresh({ draw = 40, gap = 10 })
put(30)
clear_view()
RT.partial, RT.closest = true, 6.0
settle()
tick(50, 60)                     -- let the occlusion ease settle
local tail, head = tail_alpha()
check("a route that dead-ends fades its far end out", tail and tail < 0.4, tostring(tail))
check("...while its near end is untouched", head and head > 0.8, tostring(head))

fresh({ draw = 40, gap = 10 })
put(30)
clear_view()
RT.partial, RT.closest = true, 1.5
settle()
tick(50, 60)
tail = tail_alpha()
check("a route that stops a metre short does NOT fade -- it is the route",
	tail and tail > 0.8, tostring(tail))

fresh({ draw = 12, gap = 10 })
put(60)
clear_view()
RT.partial, RT.closest = true, 6.0
settle()
tick(50, 60)
tail = tail_alpha()
check("...and neither does one merely capped by the drawn length", tail and tail > 0.8,
	tostring(tail))

fresh({ draw = 40, gap = 10 })
put(30)
clear_view()
settle()
tick(50, 60)
tail = tail_alpha()
check("a complete route is never faded", tail and tail > 0.8, tostring(tail))

-- WITHOUT A GEOMETRY RAY. `demonized_geometry_ray` is an optional dependency, and the
-- fade was first folded into the line that writes the occlusion verdict -- which only runs
-- when a ray is available. So a route to an unreachable target would have gone on drawing
-- itself as a confident line for exactly the install least able to tell. Pinned here
-- because nothing else in this harness runs with the ray absent.
do
	local real_ray = ENV.ray_pick
	ENV.ray_pick = nil
	M.reset()                       -- drop the cached ray handle with the route
	fresh({ draw = 40, gap = 10 })
	put(30)
	clear_view()
	RT.partial, RT.closest = true, 6.0
	settle()
	tick(50, 60)
	local t2 = tail_alpha()
	check("...and the fade does not need the geometry ray mod to work",
		t2 and t2 < 0.4, tostring(t2))
	ENV.ray_pick = real_ray
	M.reset()
end

-- ==========================================================================
print("\n-- per-point occlusion (what replaced the hard cull) ------------------")

-- The wall is at x = 20 and the route runs 0 -> 30, so the far end is behind it.
-- The whole reason for moving to sprites is that this is now a FADE per point
-- rather than a hard on/off applied to whole segments in round-robin batches.
fresh()
settle()
tick(50, 40)                          -- let the round-robin sweep and the eases settle
rd = M.route_draw()
local near_a, far_a
for i = 1, rd.n do
	if rd.p[i].x < 15 then near_a = rd.a[i] end
	if rd.p[i].x > 24 then far_a = far_a or rd.a[i] end
end
check("points you can see reach full alpha", near_a and near_a > 0.9, tostring(near_a))
check("points behind the wall fade DOWN, not out", far_a and far_a > 0.05 and far_a < 0.5,
	tostring(far_a))

fresh({ xray = false })
settle()
tick(50, 40)
rd = M.route_draw()
far_a = nil
for i = 1, rd.n do if rd.p[i].x > 24 then far_a = far_a or rd.a[i] end end
check("with x-ray off they fade to nothing instead", far_a and far_a < 0.05, tostring(far_a))

-- The fade must be gradual: a single tick right after a verdict flips should move
-- alpha PART of the way, never all of it. That easing is the whole difference
-- between the sprite version and the ribbon's batched pop.
fresh()
settle()
tick(50, 40)
rd = M.route_draw()
local before_a
for i = 1, rd.n do if rd.p[i].x > 24 then before_a = before_a or rd.a[i] end end
wall_x = nil                          -- the wall is gone; everything is visible now
-- Wait for the round-robin to reach that point rather than assuming one tick does it:
-- the budget is one full sweep per OCC_SWEEP_MS, so at a 50 ms tick a sweep takes two
-- frames at the MAX_DRAW bead count and fewer below it. What is being tested is that the FIRST frame the verdict lands moves
-- the alpha part of the way and not all of it.
local mid_a
for _ = 1, 10 do
	tick(50)
	rd = M.route_draw()
	local a
	for i = 1, rd.n do if rd.p[i].x > 24 then a = a or rd.a[i] end end
	if a and a > (before_a or 0) + 1e-4 then mid_a = a; break end
end
check("a changed verdict eases rather than snapping",
	mid_a and mid_a > before_a and mid_a < 0.99,
	string.format("%.3f -> %.3f", before_a or -1, mid_a or -1))

-- ==========================================================================
print("\n-- the distance band -------------------------------------------------")

-- THE regression from the second in-game session. The near edge used to be the
-- card's appear distance (16 m), on the reasoning that the card owns that band.
-- It does not when the target is behind a corner -- the card needs line of sight
-- and the route only draws when there is none -- so a quest giver 9 m away round a
-- corner got a beacon and nothing else.
fresh()
put(9)
wall_x = 5                            -- ...and they are round a corner
check("a target 9 m away round a corner still gets a route", settle())
check("...which is short but real", M.status().points >= 3, tostring(M.status().points))

-- THE regression from the fourth session, and the opposite end of the same
-- mistake: a far target used to get nothing at all, because the target had to be
-- inside 50 m before anything drew. A route is a navigation aid; what should be
-- limited is how MUCH of it you see, not whether you get one.
fresh()
put(200)
check("a target 200 m away still gets a route", settle())
local far_rd = M.route_draw()
check("...drawn from the player, not from the target",
	far_rd.p[1].x < 6, tostring(far_rd.p[1].x))
local span = far_rd.p[far_rd.n].x - far_rd.p[1].x
check("...and only as far ahead as draw_m allows", span <= 42, tostring(span))
check("...so it stops well short of them", far_rd.p[far_rd.n].x < 60,
	tostring(far_rd.p[far_rd.n].x))

fresh()
put(2)                                -- you are standing on top of them
tick(50, 6)
check("no route once you have arrived", drawing() == 0 and RT.begins == 0)

fresh()
put(900)                              -- past the search-cost guard
tick(50, 6)
check("no route past the cost guard", drawing() == 0 and RT.begins == 0)

fresh()
settle()
put(2)                                -- they walked right up to you
tick(50, 3)
check("arriving stops the route", drawing() == 0)
check("...but keeps the target, so walking off resumes rather than restarts",
	M.status().target == NPC_ID)

-- ==========================================================================
print("\n-- visibility --------------------------------------------------------")

fresh()
put(12)
wall_x = nil                          -- in plain sight, and close
tick(50, 10)
check("a target you can see, up close, gets no route", drawing() == 0 and RT.begins == 0)
check("...and the ray is actually being cast", ray_queries > 0)

-- ...unless you cannot WALK straight to them (R2.33j). Seeing a head and knowing the way
-- are different facts, and the old rule only asked the first: an NPC 18 m away through an
-- open doorway, with the walk being round two slabs and in through it, got no route
-- because his head was in view. The hole between the actor and the target is this world's
-- doorway -- ground you can see across and cannot cross.
fresh()
put(12)
wall_x = nil                          -- still in plain sight...
hole_lo, hole_hi = 5, 7               -- ...but the floor between you is gone
tick(50, 20)
check("a target you can see but cannot walk straight to DOES get a route",
	drawing() > 0, "why: " .. tostring(M.status().why))

-- ...and the probe has to be the reason, not the ray. Same fixture, floor restored.
fresh()
put(12)
wall_x = nil
tick(50, 20)
check("...and putting the floor back suppresses it again", drawing() == 0,
	"why: " .. tostring(M.status().why))

-- ...but seeing a figure across a field tells you nothing about how to walk there,
-- so past VIS_NEAR the route is unconditional.
fresh()
put(90)
wall_x = nil                          -- in plain sight, and far
check("a target you can see, far off, still gets one", settle())

-- Seeing the target stops PUBLISHING; it does not throw the route away. The first
-- in-game session reported it "sometimes stops showing", and this was half of it:
-- every flicker of sight used to drop the route, and getting it back meant another
-- search, which was rate-limited.
fresh()
put(14)                               -- inside VIS_NEAR, so sight gates it
wall_x = 8
settle()
local begins_before = RT.begins
wall_x = nil                          -- you step out and can see them
tick(50, 4)                           -- < VIS_GRACE (400 ms)
check("a brief glimpse does not stop the route", drawing() > 0)
tick(50, 12)                          -- > VIS_GRACE
check("sustained sight does", drawing() == 0)
check("...but the route itself is still there", M.status().points > 0,
	tostring(M.status().points))
wall_x = 8
tick(50, 6)
check("losing sight again brings it back on the spot", drawing() > 0)
check("...with no re-search", RT.begins == begins_before,
	tostring(RT.begins - begins_before))

-- ==========================================================================
print("\n-- keeping up (R2.2e) ------------------------------------------------")

fresh()
settle()
local before = RT.begins
local head = M.route_draw().p[1].x
actor_pos = V(6, 0, 0)                -- a way along the route
tick(50)
check("walking the route needs no search", RT.begins == before)
check("...and the cursor has advanced", M.status().cursor > 1, tostring(M.status().cursor))
check("...trimming the drawn run behind you", M.route_draw().p[1].x > head,
	tostring(M.route_draw().p[1].x))

fresh()
settle()
before = RT.begins
actor_pos = V(4, 0, 12)               -- 12 m off the line: way past DRIFT_TOL
tick(50)
check("straying off the route does not repath inside the cooldown",
	RT.begins == before, tostring(RT.begins))
clock = clock + 2000                  -- past REPATH_MIN
tick(50)
check("...and does once the cooldown is up", RT.begins == before + 1)

fresh()
settle()
before = RT.begins
put(31)                               -- shuffled 1 m: inside GOAL_TOL
clock = clock + 2000
tick(50)
check("a target shuffling on the spot does not repath", RT.begins == before)
put(38)                               -- walked 8 m: past GOAL_TOL
tick(50)
check("a target that has walked off does", RT.begins == before + 1)

fresh()
settle()
npc[NPC_ID].here = false              -- went offline / died mid-route
mk_target = nil                       -- ...so iqm_core stops offering them
tick(50)
check("a target that vanishes stops the route", drawing() == 0)
check("...and forgets them, rather than holding a dead id",
	M.status().target == nil, tostring(M.status().target))

-- Switching quests is the one repath that must NOT wait: the cooldown exists to
-- stop a walking target re-searching every frame, not to make a new objective sit
-- behind the old one's timer. Tested one tick after a search started, i.e. deep
-- inside REPATH_MIN.
fresh()
settle()
before = RT.begins
mk_target = NPC_ID2
wall_x = -10                          -- the new one is round a corner too
tick(50)
check("a new objective repaths immediately, inside the cooldown",
	RT.begins == before + 1, tostring(RT.begins - before))
check("...and adopts it", M.status().target == NPC_ID2)
check("the route now runs to the new target", settle()
	and M.route_draw().p[M.route_draw().n].x < -20)

-- ==========================================================================
print("\n-- failure and back-off ----------------------------------------------")

fresh()
RT.refuse = true                      -- an endpoint off the navmesh (R2.2d)
tick(50, 4)
check("a refused search does not retry every frame", RT.begins == 1, tostring(RT.begins))
clock = clock + 6000                  -- past FAIL_COOL
tick(50)
check("...but does try again after the back-off", RT.begins == 2)

fresh()
RT.will_fail = true                   -- search runs, finds nothing
tick(50, 6)
check("an unreachable target draws nothing", drawing() == 0)
clock = clock + 1000                  -- past REPATH_MIN but well inside FAIL_COOL
tick(50)
check("...and backs off for the FULL window, not just the repath limit",
	RT.begins == 1, tostring(RT.begins))

-- A one-point answer is start and goal collapsing onto the same navmesh node just
-- outside the arrival distance. That is not "unreachable" and must not buy the 5 s
-- back-off: two steps back and it is a perfectly good route.
fresh()
RT.degenerate = true
tick(50, 6)
check("a collapsed route draws nothing either", drawing() == 0)
clock = clock + 1000                  -- past REPATH_MIN, inside FAIL_COOL
tick(50)
check("...but retries on the short limit, not the long one", RT.begins == 2,
	tostring(RT.begins))

-- ==========================================================================
print("\n-- a goal that is OFF the navmesh -------------------------------------")

-- The case a player-placed waypoint walks straight into. PAW spawns its waypoint
-- wherever you point -- a geometry ray, so a wall face or a rooftop -- or wherever you
-- right-click the PDA map, which is 2D and so invents the y. Either way the position can
-- land somewhere level.vertex_id refuses, and before the snap that meant a live objective
-- logged "an endpoint is off the navmesh" every five seconds and never drew.
--
-- The stub's hole is a band in x, so a probe along z stays in it and one along x escapes:
-- exactly the shape that tells a real ring walk from a lucky first guess.

fresh()
hole_lo, hole_hi = 29.4, 30.6         -- the target at x=30 sits in it; 1.4 m out does not
-- UNDER pcall, and named, because this is the ONE branch where the aim and the target are
-- different objects -- which is what made it the branch that crashed (R2.41). begin_search
-- compared them with `==`, legal on two tables and fatal on two luabind vectors, and the
-- stub's __eq now reproduces that. Without the pcall the failure aborts the whole run at
-- this line instead of reporting itself, which reads as a broken harness rather than as a
-- broken mod; with it, the crash is one named FAIL and the remaining sections still run.
local snap_ok, snap_err = pcall(tick, 50)
check("a snapped goal does not compare two vectors (a CTD in game)", snap_ok,
	not snap_ok and tostring(snap_err) or nil)
check("a target off the navmesh still starts a search", RT.begins == 1, tostring(RT.begins))
check("...aimed at mesh beside it, not at the target itself",
	RT.to and RT.to.x > hole_hi, RT.to and tostring(RT.to.x))
check("...and no further than the first ring out", RT.to and RT.to.x < 30 + 1.5,
	RT.to and tostring(RT.to.x))
check("...with the offset reported for the F7 dump",
	M.status().snap_d and M.status().snap_d > 1.3 and M.status().snap_d < 1.5,
	tostring(M.status().snap_d))
check("...and it draws", settle(), "nothing drawn")

-- The snap must not read as the target having MOVED: goal keeps the raw position, so
-- GOAL_TOL still asks about the waypoint and not about the point beside it. Getting this
-- wrong is a repath on every single tick, forever.
local begins_snapped = RT.begins
tick(50, 12)
check("...without repathing on every tick", RT.begins == begins_snapped,
	tostring(RT.begins - begins_snapped))

-- Cached per target: the ring walk is the expensive half and a waypoint does not move, so
-- a repath must not pay for it twice. Measured against the COLD cost rather than a
-- constant, since what is being asserted is that the walk did not happen again.
fresh()
hole_lo, hole_hi = 25, 40             -- wide enough that the escape is several rings out
vid_queries = 0
tick(50)
local probes_cold = vid_queries
check("the ring walk really does cost something when it is cold", probes_cold > 20,
	tostring(probes_cold))
check("...and finds its way out of a wide hole",
	RT.to and (RT.to.x < hole_lo or RT.to.x > hole_hi), RT.to and tostring(RT.to.x))
check("...and draws once the search lands", settle(), "nothing drawn")
local begins_wide = RT.begins
actor_pos = V(0, 0, 12)               -- shove the actor off the line to force a repath
cam = V(0, 1.6, 12)
clock = clock + 1000                  -- ...and past REPATH_MIN, so it is allowed to
vid_queries = 0
tick(50)
check("a repath re-uses the cached snap rather than walking the rings again",
	RT.begins == begins_wide + 1 and vid_queries < probes_cold / 4,
	tostring(vid_queries) .. " vs " .. tostring(probes_cold))

-- The map-placed case. A wide hole so no ring can escape it, and a level vertex that IS
-- on the mesh -- which is the whole point: the exe hands the placing mod a real vertex
-- alongside a position whose height it had to guess.
fresh()
hole_lo, hole_hi = 10, 60
mk_lvid = 100000 + 65 * 10            -- the stub's vid for x = 65, clear of the hole
tick(50)
check("a target with an invented position but a real level vertex routes anyway",
	RT.begins == 1 and RT.to and RT.to.x > 60, RT.to and tostring(RT.to.x))

-- ...and it is the VERTEX that is trusted, not merely its existence. An id the engine
-- does not like yields a ZERO VECTOR rather than an error (level_script.cpp:394-399), and
-- a stale one out of a save is exactly the way to get one -- so the corner of the level
-- must not be mistaken for a position.
fresh()
hole_lo, hole_hi = 10, 60
mk_lvid = BAD_VID
tick(50)
check("a level vertex the engine will not resolve is not mistaken for the origin",
	RT.to and RT.to.x ~= 0, RT.to and tostring(RT.to.x))
check("...and neither is the id it reserves for 'no vertex'", (function()
	fresh()
	hole_lo, hole_hi = 10, 60
	mk_lvid = INVALID_VID
	tick(50)
	return RT.to and RT.to.x ~= 0
end)(), RT.to and tostring(RT.to.x))

-- Nothing anywhere near it. The snap gives up, and says so in the dump rather than
-- leaving the reason to be guessed from a silent absence of route.
fresh()
hole_lo, hole_hi = -1000, 1000
tick(50)
check("a target with no mesh within reach gives up", M.status().snap_d == false,
	tostring(M.status().snap_d))

-- And the ordinary case pays none of it.
fresh()
tick(50)
check("a target ON the mesh is aimed at exactly, with no snap reported",
	RT.to and RT.to.x == 30 and M.status().snap_d == nil,
	RT.to and (tostring(RT.to.x) .. " / " .. tostring(M.status().snap_d)))

-- ==========================================================================
print("\n-- overlay gating (C4) -----------------------------------------------")

fresh()
settle()
mk_overlay = false                    -- PDA opened / reveal key released
tick(50)
check("the overlay gate stops publishing", drawing() == 0)
check("...and keeps the route, so there is nothing to recompute",
	M.status().points > 0, tostring(M.status().points))
local begins_gated = RT.begins
mk_overlay = true
tick(50)
check("...coming back is immediate", drawing() > 0)
check("...with no re-search", RT.begins == begins_gated)

-- ---------------------------------------------------------------------------
-- TWO VIEWS, TWO GATES (R2.58). The gate above used to be one answer for both
-- consumers. It cannot be any more: the ground line is summoned -- faded out for most of
-- the session by default -- while the minimap trail is a PDA readout that keeps the old
-- rule. So the tick's drawing half has to run when EITHER can see the route, and stop
-- when neither can.
--
-- The failure this pins is the quiet one. `overlay_visible()` is perfectly true for a
-- player with no minimap and no route summoned, so a gate that asked it alone would look
-- correct, publish nothing, and go on paying for six occlusion rays and a chevron refill
-- every frame -- on the commonest setup there is, and by default.
fresh()
settle()
check("summoned, trail off: the ground line keeps the tick working",
	drawing() > 0)

-- The target goes OFFLINE for the ray counts below, for the same reason the block above
-- does it: an offline target skips the visibility ray entirely, so every ray_pick left is
-- an occlusion ray and the counter means what it says.
fresh({ mm = false })
mk_online = false
put(60)
settle()
mk_summon = 0                         -- the dwell expired; the line has faded out
tick(50)
check("not summoned and no trail: nothing publishes", drawing() == 0)
local rays_unsummoned = ray_queries
tick(50, 6)
check("...and the drawing half stops entirely", ray_queries == rays_unsummoned,
	string.format("%d occlusion rays for a route nobody asked for", ray_queries - rays_unsummoned))
check("...while the route itself survives, so re-summoning costs no search",
	M.status().points > 0, tostring(M.status().points))
local begins_unsummoned = RT.begins
mk_summon = 1
tick(50)
check("...and it is back on the next frame", drawing() > 0)
check("...with no re-search", RT.begins == begins_unsummoned)

-- ...and the trail on its own is reason enough. A minimap player who never summons the
-- ground line must still get a trail: this is the direction that fails silently, because
-- the ground line is the view every other fixture here watches.
fresh({ mm = true })
mk_online = false
put(60)
settle()
mk_summon = 0
tick(50, 4)
check("the minimap trail alone keeps the route published", drawing() > 0,
	"the summon must not be able to switch off a view it does not own")
local rays_trail = ray_queries
tick(50)
check("...and the drawing half runs for it", ray_queries > rays_trail,
	string.format("%d rays with only the trail watching", ray_queries - rays_trail))
mk_summon = 1

-- ---------------------------------------------------------------------------
-- ...and it must cost nothing to HOLD. route_draw() returns nil for the whole of
-- this state, so every occlusion ray cast and every chevron placed in a hidden
-- frame is work no one can see -- and with reveal_mode 3 (hold to show) hidden is
-- the ordinary state of the overlay, not a corner of it.
--
-- The target is taken OFFLINE for these: an offline target skips the visibility
-- ray entirely, so every ray_pick the module makes here is an occlusion ray and
-- the counter means what it says.
--
-- RD is read through a reference captured while it WAS published. The list is one
-- persistent table refilled in place, so holding it is how the harness sees the
-- half of the state route_draw() stops handing out -- which is the whole point:
-- the route has to still be there.
fresh()
mk_online = false
put(60)
settle()
local RDref = M.route_draw()
check("the published list is readable while visible", RDref and RDref.n > 0)

tick(50)
local rays_before = ray_queries
tick(50)
check("a visible frame casts occlusion rays", ray_queries > rays_before,
	string.format("%d rays in one visible frame", ray_queries - rays_before))

local chev_x = RDref.cp[1] and RDref.cp[1].x
local alpha_lit = RDref.a[1]

mk_overlay = false
tick(50)
local rays_hidden = ray_queries
local cursor_hidden, begins_hidden = M.status().cursor, RT.begins
-- Ten hidden frames, walking the whole time: the actor covers ground the marks
-- would follow him across and the fade would keep easing over.
for i = 1, 10 do
	actor_pos = V(i, 0, 0)
	cam = V(i, 1.6, 0)
	tick(50)
end
check("a hidden frame casts no occlusion ray at all",
	ray_queries == rays_hidden, string.format("%d rays while hidden", ray_queries - rays_hidden))
check("...and places no chevrons, so the marks do not track the player",
	RDref.cp[1] and RDref.cp[1].x == chev_x,
	string.format("%s -> %s", tostring(chev_x), tostring(RDref.cp[1] and RDref.cp[1].x)))
check("...and the fade does not ease while nothing can see it",
	RDref.a[1] == alpha_lit,
	string.format("%s -> %s", tostring(alpha_lit), tostring(RDref.a[1])))

-- Throttled, not torn down. The list, the path and the target all survive, which is
-- what makes coming back free.
check("...the route survives the whole blank", RDref.n > 0 and M.status().points > 0,
	string.format("%d verts, %d points", RDref.n, M.status().points))
check("...as does the target", M.status().target ~= nil)
check("...and no search was started to hold it", RT.begins == begins_hidden)

-- The cadence keeps running underneath. Eleven metres of walking along the line is
-- the cursor's job, and the throttle must not be what stops it.
check("...but `advance` still runs, so the cursor keeps up with the player",
	M.status().cursor > cursor_hidden,
	string.format("%d -> %d", cursor_hidden, M.status().cursor))

-- Nor may it stall a repath. Off the line by well over DRIFT_TOL, still hidden: a
-- throttled tick is still a tick, and this one has to notice.
actor_pos = V(5, 0, 30)
cam = V(5, 1.6, 30)
tick(50, 8)                           -- 400 ms: past HIDE_MS, past REPATH_MIN
check("...and a repath still fires while hidden",
	RT.begins > begins_hidden, string.format("%d -> %d", begins_hidden, RT.begins))

-- Coming back must LAND, not fade in. The alphas frozen above were eased toward a
-- verdict computed where the player used to stand; playing that fade out now would
-- be a fade-in of stale occlusion over a route the player has just asked to see.
fresh()
mk_online = false
put(60)
settle()
local RD2 = M.route_draw()
mk_overlay = false
tick(50)
check("the alphas freeze mid-fade while hidden", RD2.a[1] < 0.99,
	tostring(RD2.a[1]))
mk_overlay = true
tick(50)
check("...and the first visible frame snaps them to target, not eases",
	RD2.a[1] == (RD2.t[1] or 1), string.format("%s vs %s", tostring(RD2.a[1]), tostring(RD2.t[1])))
check("...with the marks back on the same frame", RD2.nc > 0 and drawing() > 0,
	string.format("%d marks", RD2.nc))
mk_online = true

-- ==========================================================================
print("\n-- the ray budget is spent per millisecond ----------------------------")

-- R2.61 / route-perf 4.4. The sweep used to cast a flat OCC_RATE rays every FRAME, so
-- the ray rate was a function of frame rate: 360/s at 60 fps, 864/s at 144 for a sweep
-- period nobody can perceive, 180/s at 30 where the fade visibly lags. A ray is ~5 us
-- and ~13x a projection, which made this the largest single per-frame engine cost in the
-- driver. The budget is now n * dt / OCC_SWEEP_MS, so the SWEEP PERIOD is what is held
-- fixed and the rate falls out of it.
--
-- occ_owed is a fractional accumulator, so it carries state between the two runs below.
-- It is zeroed before each so the comparison is between two clean 384 ms windows rather
-- than between one window and the leftovers of the last. Reached through upvalues:
-- occ_owed is a chunk local captured by occ_step, which is captured by draw_tick, which
-- is captured by update -- the module exports none of them, and driving the REAL
-- accumulator is the whole point (see the same climb in reach-harness).
local function upget(fn, name)
	if type(fn) ~= "function" then return nil end
	for i = 1, 120 do
		local nm, v = debug.getupvalue(fn, i)
		if not nm then return nil end
		if nm == name then return v, i end
	end
end
local occ_fn = upget(upget(M.update, "draw_tick"), "occ_step")
check("occ_step is reachable through update's upvalues", type(occ_fn) == "function",
	"without it the four assertions below would test nothing at all")

local OCC_SWEEP_MS = upget(occ_fn, "OCC_SWEEP_MS")
local OCC_MAX      = upget(occ_fn, "OCC_MAX")
check("...as are the two constants the budget is written in",
	type(OCC_SWEEP_MS) == "number" and type(OCC_MAX) == "number",
	string.format("OCC_SWEEP_MS=%s OCC_MAX=%s", tostring(OCC_SWEEP_MS), tostring(OCC_MAX)))

--- Read occ_owed, and set it first if a value is given.
local function owed(v)
	local cur, i = upget(occ_fn, "occ_owed")
	if not i then return nil end
	if v then debug.setupvalue(occ_fn, i, v); return v end
	return cur
end

fresh()
mk_online = false                     -- so every ray cast here is an occlusion ray
put(60)
settle()
local RDbud = M.route_draw()
local nbud = RDbud and RDbud.n or 0
check("the budget fixture has beads to sweep", nbud > 0, string.format("%d beads", nbud))

-- 24 frames of 16 ms and 48 frames of 8 ms are the same 384 ms of play. Per-frame
-- budgeting buys twice as many rays in the second run; per-millisecond buys the same.
-- Exactly the same, not approximately: the owed total over a window is n * ms /
-- OCC_SWEEP_MS either way, and both runs start from a zeroed accumulator, so the
-- leftover fraction at the end is identical too.
owed(0)
local r0 = ray_queries
tick(16, 24)
local rays_60 = ray_queries - r0

owed(0)
r0 = ray_queries
tick(8, 48)
local rays_144 = ray_queries - r0

check("the same play time buys the same rays at double the frame rate",
	rays_60 == rays_144,
	string.format("%d rays over 24 frames at 16 ms, %d over 48 frames at 8 ms -- "
		.. "a per-frame budget would have made the second figure ~2x the first",
		rays_60, rays_144))
-- Pinned to the literal 100 rather than to OCC_SWEEP_MS, because an expectation computed
-- from the constant it is checking passes at any value of it -- the first draft did exactly
-- that and a mutation doubling the constant went straight through. 100 ms is a tuning
-- choice with a reason: at the 36-bead maximum and 60 fps it is the 6 rays a frame the flat
-- OCC_RATE used to cast, which is what makes the long-route case a no-op.
check("the sweep period is the tuned 100 ms", OCC_SWEEP_MS == 100,
	string.format("%s ms", tostring(OCC_SWEEP_MS)))
check("...and one sweep's worth of play buys exactly one visit per bead",
	rays_60 == math.floor(nbud * 384 / 100),
	string.format("%d rays for %d beads over 384 ms; expected %d",
		rays_60, nbud, math.floor(nbud * 384 / 100)))

-- The other half of the fix, and the reason the accumulator is not simply trusted:
-- update() floors dt to 16 past 500 ms, but 500 ms still EARNS five whole sweeps, and
-- firing them into a frame that is already stalling is the stutter this finding was
-- meant to remove. The cap DISCARDS the excess instead of banking it -- banking would
-- charge the cost of the hitch to the frames after the hitch, and the verdicts are
-- stale either way.
owed(0)
r0 = ray_queries
tick(500, 1)
local rays_hitch = ray_queries - r0
check("a stretched frame cannot fire a whole sweep at once",
	rays_hitch <= OCC_MAX,
	string.format("%d rays on a 500 ms frame (cap %d); the unclamped budget was %.1f",
		rays_hitch, OCC_MAX, nbud * 500 / OCC_SWEEP_MS))
check("...and the unspendable debt is dropped rather than banked",
	owed() == 0, string.format("%s owed after the hitch", tostring(owed())))
mk_online = true

-- ==========================================================================
print("\n-- one fetch per frame (route-perf 4.5) -------------------------------")

-- Three of 4.5's findings were the same shape: a value that cannot change inside a frame,
-- fetched again by the next function that wanted it. device().cam_pos was read by
-- build_draw_list AND occ_step; db.actor:position() by actor_arclen AND lead_apply, back to
-- back, on top of update()'s own; time_global() by flow_advance after update() had already
-- been handed the clock it was called with.
--
-- Nothing in the 254 assertions above can see any of that, because threading a value down
-- instead of refetching it is by construction behaviour-preserving -- which is exactly why
-- it needs a counting test rather than a behavioural one. The totals are pinned over a
-- WINDOW of frames rather than on a single frame, because refresh_visibility is throttled
-- by VIS_RATE and so contributes to some frames and not others; over a fixed window the
-- figure is deterministic, and a refetch that comes back per-frame moves it by the frame
-- count, which no throttle can hide.
local DEDUP_FRAMES = 20
fresh({ draw = 40, gap = 10 })
put(60)
settle()
tick(50, 3)                           -- past the first-frame specials
n_clock, n_device, n_apos = 0, 0, 0
tick(50, DEDUP_FRAMES)
local per_dev  = n_device / DEDUP_FRAMES
local per_apos = n_apos / DEDUP_FRAMES
local per_clk  = n_clock / DEDUP_FRAMES

-- 25 = one per frame from draw_tick, plus five from refresh_visibility, which is throttled
-- to VIS_RATE = 200 ms and so fires five times in this window's second of play. Before the
-- fix it was 45: build_draw_list and occ_step each fetched for themselves.
check("the camera is read once per drawing frame, not twice",
	n_device == 25,
	string.format("%d device() calls over %d frames = %.2f/frame; expected 25 (20 drawing "
		.. "+ 5 throttled visibility probes), and 45 before the fix",
		n_device, DEDUP_FRAMES, per_dev))
check("the actor is asked its position twice a frame, not three times",
	n_apos == 40,
	string.format("%d position() calls over %d frames = %.2f/frame; place_chevrons now "
		.. "fetches once for actor_arclen and lead_apply together",
		n_apos, DEDUP_FRAMES, per_apos))
check("the clock is not read again below update()",
	n_clock == 0,
	string.format("%d time_global() calls over %d frames = %.2f/frame; the harness drives "
		.. "update(clock) directly, so every one of these would be a refetch",
		n_clock, DEDUP_FRAMES, per_clk))

-- And the blanked path must not have started paying for the DRAWING fetch. draw_tick is
-- skipped entirely when nobody can see the route, so the fetch belongs there and not in
-- update() -- one level up would have been the easy version of this fix and would have
-- charged the throttled state for a value it never uses.
--
-- Not zero, and the first draft of this assertion wrongly said it would be: refresh_visibility
-- reads the camera too, and it has to keep running while the route is hidden because it is
-- what decides whether the route is WANTED at all. Its five throttled calls are the whole of
-- what a hidden second costs; a per-frame fetch leaking onto this path would read 20 more.
mk_overlay = false
tick(50, 4)                           -- settle into the blank
n_device = 0
tick(50, DEDUP_FRAMES)
check("...and a hidden frame pays only for the throttled visibility probe",
	n_device == 5,
	string.format("%d device() calls over %d hidden frames; 5 is refresh_visibility at "
		.. "VIS_RATE, and anything near %d would be a per-frame fetch on the blanked path",
		n_device, DEDUP_FRAMES, DEDUP_FRAMES))
mk_overlay = true

-- THE OTHER HALF of 4.5: lead_w was ASKED per vertex, and provably answers zero for every
-- arclength past lead_s + LEAD_M. LEAD_M is 8 m against a route drawn to draw_m, so ~30 of
-- 36 vertices called it only to be told nothing. RD.s is monotonic, so the vertex it stops
-- mattering at can be found once per frame instead.
--
-- Counted the only way it can be: lead_w is a chunk local with no exported surface, so a
-- counting wrapper is swapped in through lead_apply's upvalues and swapped back out. The
-- climb is update -> draw_tick -> place_chevrons -> lead_apply, and it is the reason this
-- assertion exists at all -- disabling the cut is behaviour-preserving by construction, so
-- nothing that looks only at the drawn route can tell whether it is there.
local lead_fn = upget(upget(upget(M.update, "draw_tick"), "place_chevrons"), "lead_apply")
local n_leadw = 0
local real_leadw, leadw_i = upget(lead_fn, "lead_w")
check("lead_w is reachable to be counted", type(real_leadw) == "function" and leadw_i ~= nil,
	"without this the two assertions below would test nothing")
--- Swap a function-valued upvalue, and FLUSH THE JIT.
--
--  debug.setupvalue does not invalidate LuaJIT's compiled traces. lead_apply is as hot as
--  anything in this file by the time these cases run, so its trace had already specialised
--  the call to the real lead_w: the wrapper installed cleanly, debug.getupvalue read it back,
--  the route was still offset correctly by 1.5 m -- and the counter read zero, because the
--  compiled path never went through it. The first draft of the assertion below PASSED at
--  zero for exactly that reason. Anything that swaps a called function through an upvalue
--  mid-run has to flush, or it is measuring the interpreter while the game runs the trace.
local function swap_leadw(fn)
	debug.setupvalue(lead_fn, leadw_i, fn)
	if jit and jit.flush then jit.flush() end
end
swap_leadw(function(sv) n_leadw = n_leadw + 1; return real_leadw(sv) end)

fresh({ draw = 40, gap = 10 })
put(60)
actor_pos = V(0, 0, 0)                -- standing ON the line: there is no lead-in to blend
cam = V(0, 1.6, 0)
settle()
tick(50, 2)
local nv = M.route_draw().n
n_leadw = 0
tick(50, 5)
-- 6 a frame of 24 vertices, not zero: snap_path moves the path onto navmesh cells, so even
-- an actor standing exactly on the search's answer has a few centimetres of residual and the
-- ramp is live. What the cut buys is that only the vertices INSIDE the 8 m ramp are asked.
check("a route standing on the line asks lead_w only inside the ramp",
	n_leadw == 30,
	string.format("%d calls over 5 frames on a %d-vertex route = %.1f/frame; without the "
		.. "cut it is %d", n_leadw, nv, n_leadw / 5, nv * 5))

actor_pos = V(0, 0, 1.5)              -- off the line, inside DRIFT_TOL: the ramp is live
tick(50, 2)
n_leadw = 0
tick(50, 5)
-- Pinned rather than merely bounded, and that is the point: "fewer than all of them" would
-- also pass a cut set one metre short, which silently drops the outer end of the ramp and is
-- the one way this optimisation can be wrong rather than merely absent.
check("...and a live 1.5 m offset widens the ramp without reaching the far end",
	n_leadw == 70,
	string.format("%d calls over 5 frames = %.1f/frame of %d vertices; without the cut it "
		.. "is %d", n_leadw, n_leadw / 5, nv, nv * 5))
swap_leadw(real_leadw)
actor_pos = V(0, 0, 0)

-- THE EASE ARRIVES (route-perf 4.5). `a = a + (t - a) * k` is exponential, so it approaches
-- its target and never reaches it: a route that has been settled for a minute was still
-- multiply-adding every vertex every frame, for differences far below one step of the 8-bit
-- alpha the packed ARGB can carry. Snapped inside half a step, the settled loop is n
-- compares -- and the test for it has to be EXACT equality, because "close enough" is what
-- the unsnapped version already was.
fresh({ draw = 40, gap = 10 })
put(60)
clear_view()
settle()
tick(50, 30)
do
	local rd = M.route_draw()
	local exact, worst, worst_i = 0, 0, nil
	for i = 1, rd.n do
		local d = rd.a[i] - (rd.t[i] or 1)
		if d == 0 then exact = exact + 1 end
		if d < 0 then d = -d end
		if d > worst then worst, worst_i = d, i end
	end
	check("a settled route's alphas land exactly on their targets",
		exact == rd.n,
		string.format("%d of %d exact; worst gap %.3g at vertex %s -- unsnapped this is "
			.. "every vertex off by a residual the 8-bit alpha cannot even represent",
			exact, rd.n, worst, tostring(worst_i)))
end

-- ...and the snap window is HALF AN ALPHA STEP, not a shortcut through the fade. Landing
-- exactly is the easy half to get right; a window wide enough to be seen would pass it just
-- as happily, so the width is pinned by how long a full fade takes to arrive. Occluding the
-- whole route drops every target from 1 to 0, and at OCC_TAU = 90 ms against a 50 ms tick
-- that gap takes 13 frames to close through the ease. A 0.2 window closes it in 5 and the
-- last step is a visible jump of a fifth of the alpha range.
wall_x = 0                            -- the +x route is entirely past it: every target goes to 0
local snap_frames = 0
for _ = 1, 40 do
	tick(50)
	snap_frames = snap_frames + 1
	local rd = M.route_draw()
	-- Landed means every verdict has ARRIVED (t has moved off 1, so the round-robin has
	-- reached that bead) AND every alpha sits exactly on it. Testing `a == t` alone passed on
	-- frame one, because it is trivially true for a bead the sweep has not visited yet.
	local landed = true
	for i = 1, rd.n do
		if (rd.t[i] or 1) == 1 or rd.a[i] ~= rd.t[i] then landed = false; break end
	end
	if landed then break end
end
check("...and it is half an alpha step wide, not a shortcut through the fade",
	snap_frames == 13,
	string.format("%d frames of 50 ms to land a full 1 -> 0 fade; a 100x wider window "
		.. "does it in 5", snap_frames))
clear_view()

-- ON_LEG PROJECTS IN BOTH AXES, and every route above this line runs along +x -- so a leg's
-- dz is zero, the z half of the projection is multiplied by nothing, and deleting it outright
-- passes all 262 other assertions in this file. A diagonal route is the only thing that can
-- see it. Worth a case rather than a shrug because route-perf 4.5 rewrote this function: the
-- closure actor_arclen defined per frame became a file-scope on_leg taking the actor's x and
-- z as floats, and "the logic is unchanged" is not an argument for leaving it unwitnessed.
fresh({ draw = 40, gap = 10 })
put(40, 40)                           -- a 45-degree route
actor_pos = V(0, 0, 0)
cam = V(0, 1.6, 0)
settle()
tick(50, 4)
do
	-- 8.5 m ALONG the diagonal, still exactly on it. His residual off the leg is zero, so the
	-- lead-in has nothing to blend; a projection that ignores z lands him somewhere else on
	-- the line and invents an offset out of the difference.
	--
	-- MID-LEG, deliberately. The first draft used 8 m, which on a 45-degree route densified at
	-- PATH_STEP lands exactly on a path point -- and there both (ax - a.x) and (az - a.z) are
	-- zero, so t is zero whichever terms you keep and dropping the z half changed nothing. Half
	-- a metre further on, t is 0.5 and dropping z halves it, walking the projected point a
	-- quarter of a metre back down the leg and inventing that much lead-in.
	local d = 8.5 / math.sqrt(2)
	actor_pos = V(d, 0, d)
	cam = V(d, 1.6, d)
	tick(50, 3)
	local rd = M.route_draw()
	local off, off_i = 0, nil
	for i = 1, rd.n do
		local dx = rd.p[i].x - rd.src[i].x
		local dz = rd.p[i].z - rd.src[i].z
		local l = math.sqrt(dx * dx + dz * dz)
		if l > off then off, off_i = l, i end
	end
	check("an actor standing on a DIAGONAL route has nothing to lead in",
		rd.n > 1 and off < 0.05,
		string.format("worst lead offset %.3f m at vertex %s of %d", off, tostring(off_i), rd.n))
end
actor_pos = V(0, 0, 0)
cam = V(0, 1.6, 0)


-- ==========================================================================
print("\n-- the heading memo must not outlive its path (route-perf 4.5) --------")

-- heading_at is a pure function of the path and an index, and a chevron only crosses a 1 m
-- leg about twice a second, so ~95% of its calls re-derived last frame's answer -- walking
-- path_s out CHEV_DIR_M in each direction to do it. It is now memoised by path index.
--
-- THIS IS THE YELLOW HALF OF 4.5 and the only cache in it. The memo is keyed by index, so a
-- new path reusing the same indices reads the OLD headings: chevrons pointing along the route
-- the player is no longer on. Loud rather than subtle, but nothing in the 264 assertions above
-- could see it -- every one of the three invalidation sites could be deleted with the whole
-- suite still green, which is what these cases are for.
local function chev_dir()
	local rd = M.route_draw()
	if not (rd and rd.nc > 0) then return nil end
	return rd.cdx[1], rd.cdz[1]
end

fresh({ draw = 40, gap = 10 })
put(60, 0)                            -- a route straight along +x
clear_view()
settle()
tick(50, 4)
local hx0, hz0 = chev_dir()
check("a route along +x points its chevrons along +x", hx0 and hx0 > 0.9,
	string.format("%s, %s", tostring(hx0), tostring(hz0)))

-- Same target id, moved through ninety degrees. A moved goal repaths without going through
-- the id-changed branch, so this exercises the install site specifically.
put(0, 60)
tick(50, 40)
local hx1, hz1 = chev_dir()
check("...and a route that turns ninety degrees turns its chevrons with it",
	hz1 and hz1 > 0.9 and hx1 and hx1 < 0.4,
	string.format("%s, %s -- a stale memo would still read %.2f, %.2f",
		tostring(hx1), tostring(hz1), hx0 or 0, hz0 or 0))

-- And through stop(): dropping the target tears the route down, and the NEXT route must not
-- inherit the headings of the one before it. Losing the target outright is the teardown that
-- goes through stop(); taking the giver merely OFFLINE does not -- the route is frozen and
-- kept, which is the whole point of that state, so it tests nothing here.
mk_target = nil
tick(50, 6)
check("...with the route torn down in between", drawing() == 0,
	string.format("%d drawn, why: %s", drawing(), tostring(M.status().why)))
put(60, 0)
mk_target = NPC_ID
tick(50, 40)
local hx2, hz2 = chev_dir()
check("...and a route rebuilt after a teardown derives its headings afresh",
	hx2 and hx2 > 0.9,
	string.format("%s, %s -- a memo surviving stop() would still read %.2f, %.2f",
		tostring(hx2), tostring(hz2), hx1 or 0, hz1 or 0))

-- ...and the memo has to actually BE what the chevrons read. No behavioural assertion can see
-- that: a memo that recomputes on every call draws exactly the same route as one that works.
-- Counting calls to heading_at cannot see it either, and the first draft of this tried --
-- the memo lives INSIDE heading_at, so the call count is identical either way. What settles it
-- is POISONING the memo: fill every entry with a heading that points somewhere the route does
-- not go, and the drawn chevrons must follow it. If they do not, the memo is not on the read
-- path and the whole change is a table nobody consults.
local head_fn = upget(upget(upget(M.update, "draw_tick"), "place_chevrons"), "heading_at")
check("heading_at is reachable, and its memo through it", type(head_fn) == "function"
	and type(upget(head_fn, "HDx")) == "table" and type(upget(head_fn, "HDz")) == "table",
	"without this the two assertions below would test nothing")

fresh({ draw = 40, gap = 10 })
put(60, 0)                            -- a route straight along +x again
clear_view()
actor_pos = V(0, 0, 0)
cam = V(0, 1.6, 0)
settle()
tick(50, 4)
do
	local HDx, HDz = upget(head_fn, "HDx"), upget(head_fn, "HDz")
	local filled = 0
	for _ in pairs(HDx) do filled = filled + 1 end
	check("a drawn frame leaves its headings in the memo",
		filled > 0, string.format("%d entries after 4 frames of a %d-chevron route",
			filled, M.route_draw().nc))

	-- Point every cached heading at +z, which this route never goes.
	for k in pairs(HDx) do HDx[k], HDz[k] = 0, 1 end
	if jit and jit.flush then jit.flush() end
	tick(50)
	local rd = M.route_draw()
	check("...and the drawn chevrons read their heading FROM it",
		rd.nc > 0 and rd.cdz[1] > 0.9,
		string.format("%.2f, %.2f after poisoning the memo to point along +z on a route "
			.. "that runs along +x", rd.cdx[1], rd.cdz[1]))
end
-- Poisoned state does not leave this block: the next section repaths, which goes through the
-- install site and drops the memo.
mk_target = nil
tick(50, 4)
mk_target = NPC_ID

-- ==========================================================================
print("\n-- the target accessor ------------------------------------------------")

-- The three fields of status() a per-frame consumer wants, without the ~20-entry
-- hash status() has to build to hand them over. iqm_minimap reads them every frame.
fresh()
put(45, 12)
settle()
-- Checked BEFORE it is called: `local function route_target` compiles and runs and
-- exports nothing, and the consumer's symptom is a nil field, not an error here.
check("route_target reaches the namespace at all", type(M.route_target) == "function")
-- Called on its own line, not as `M.route_target and M.route_target()`: `and`
-- truncates a multiple return to its first value, which would quietly drop gx/gz.
local td, tx, tz
if M.route_target then td, tx, tz = M.route_target() end
local st = M.status()
check("...and agrees with status(), field for field",
	td == st.dist and tx == st.gx and tz == st.gz,
	string.format("%s/%s/%s vs %s/%s/%s", tostring(td), tostring(tx), tostring(tz),
		tostring(st.dist), tostring(st.gx), tostring(st.gz)))
check("...and it is the live target's position", tx == 45 and tz == 12,
	string.format("%s, %s", tostring(tx), tostring(tz)))

-- nil until something resolves, and nil again once nothing does: the consumer is
-- built on that, so it is asserted rather than assumed.
fresh()
mk_target = nil
tick(50)
check("...and reports nil with no objective", M.route_target() == nil)

-- ==========================================================================
print("\n-- the debug driver wins ---------------------------------------------")

fresh()
settle()
local dbg_on = false
ENV.iqm_route.debug_active = function() return dbg_on end
dbg_on = true
tick(50)
check("an F7 route parks the live one", M.status().parked and drawing() == 0)
local begins_parked = RT.begins
tick(50, 10)
check("...and it stays out of the way", RT.begins == begins_parked)
dbg_on = false
tick(50)
check("clearing it hands the search back", not M.status().parked)
ENV.iqm_route.debug_active = function() return false end

-- ==========================================================================
print("\n-- the drawn-length cap (R2.4) ---------------------------------------")

fresh({ draw = 12 })
put(48)
settle()
rd = M.route_draw()
span = rd.p[rd.n].x - rd.p[1].x
check("the run is limited to draw_m of PATH", span <= 13, tostring(span))
-- ...and reaches it. The stroke's vertices land every SEG_MAX, which on its own
-- would stop up to 4 m short of draw_m -- and by a DIFFERENT amount each rebuild, so
-- the far end would visibly breathe in and out by four metres as you walked. The
-- last point actually walked is emitted to close it off.
check("...and runs right up to it rather than stopping a vertex short",
	span >= 11, tostring(span))
check("...while the route itself is still the full length",
	M.status().points >= 40, tostring(M.status().points))

fresh({ draw = 80, gap = 4 })
put(120)
settle()
check("and never exceeds the segment pool", M.route_draw().n <= 36,
	tostring(M.route_draw().n))
check("...nor the smaller chevron pool", M.status().chevs <= 16,
	tostring(M.status().chevs))

-- MAX_CHEV binds routinely since R2.16, not just on a hand-edited config: a chevron is
-- placed at an exact arclength and the default spacing is 3 m, so any route longer than
-- ~48 m drawn asks for more than the pool holds. Each ground chevron costs TWO segment
-- widgets, which is what makes this a real budget. It is enforced HERE, where the list is
-- built, so the list and the renderer's pool cannot disagree.
fresh({ draw = 200, gap = 3 })
put(300)
settle()
check("the chevron budget is enforced where the list is built",
	M.status().chevs <= 16, tostring(M.status().chevs))
check("...and this fixture really does reach it", M.status().chevs == 16,
	tostring(M.status().chevs))
check("...without disturbing the stroke's own cap", M.route_draw().n <= 36,
	tostring(M.route_draw().n))

-- The clearance pass runs on the dense list, between densify and snap (R2.23). Asserted
-- through the stub's counters, since the pass itself is the route module's business.
fresh({ draw = 50 })
put(40)
settle()
check("the driver runs the clearance pass", RT.clr_calls >= 1, tostring(RT.clr_calls))
check("...on the DENSE point list, not the sparse node list",
	RT.clr_n >= 30, tostring(RT.clr_n) .. " points")

-- Chevron phase is measured from the ACTOR'S OWN ARCLENGTH, continuously (R2.29). This
-- is THE fixture for four sessions of "the marks change when I move", and it asserts the
-- property that fixes it rather than the mechanism: every mark holds a FIXED DISTANCE
-- AHEAD OF THE PLAYER, so as he walks they flow over the ground without their distance --
-- and therefore their size, aspect and angle -- changing at all.
--
-- The two arrangements this replaces each fail it in opposite directions, and both were
-- shipped: phased on the drawn start the marks lurch a whole PATH_STEP at a time (the
-- distances change by up to half a step), and phased on absolute route arclength they do
-- not move at all (the distances change by however far you walked).
fresh({ draw = 40, gap = 10 })
put(40)
settle()
rd = M.route_draw()
local function mark_dists()
	local d = {}
	for k = 1, rd.nc do d[k] = rd.cp[k].x - actor_pos.x end
	return d
end
local was = mark_dists()
check("chevrons stand at fixed distances ahead of the player", rd.nc > 2
	and math.abs(was[1]) < 0.01 and math.abs((was[2] or 0) - 5) < 0.01
	and math.abs((was[3] or 0) - 10) < 0.01,
	rd.nc > 2 and string.format("%.2f, %.2f, %.2f", was[1], was[2] or -1, was[3] or -1)
	or "none")

-- A deliberate NON-multiple of the gap and NON-multiple of PATH_STEP: 7.35 m would land
-- on a path point under the old cursor phase and hide the quantisation.
actor_pos = V(7.35, 0, 0)
cam = V(7.35, 1.6, 0)
tick(50, 6)
rd = M.route_draw()
local now = mark_dists()
check("...and hold that distance exactly as he walks", (function()
	if rd.nc == 0 then return false end
	for k = 1, math.min(#was, #now) do
		if math.abs(now[k] - was[k]) > 0.01 then return false end
	end
	return true
end)(), rd.nc > 0 and string.format("%.3f vs %.3f", now[1] or -1, was[1]) or "none")

-- ...which means they DID move over the ground. Both halves matter: still marks were
-- the twenty-first session's complaint just as loudly as changing ones.
check("...which means the marks moved with him", rd.nc > 0
	and math.abs(rd.cp[1].x - 7.35) < 0.01,
	rd.nc > 0 and string.format("first mark now at %.2f", rd.cp[1].x) or "none")

actor_pos = V(0, 0, 0)
cam = V(0, 1.6, 0)

-- ==========================================================================
print("\n-- the near end starts at your feet (R2.25) ---------------------------")

-- R2.13's NEAR_TRIM skipped the first 3 m of path in front of the CAMERA. R2.25 takes it
-- to zero: the near plane is the renderer's HEAD/HMIN fade to soften, and the trim on top
-- of it left a visible gap between the player and the head of the route -- most obvious in
-- the arrows-only style, where the marks are the route and there is no stroke to say where
-- it began. These checks are the old ones inverted, and they exist so a reinstated trim
-- shows up here rather than in a screenshot.
fresh({ draw = 6 })
put(20)
settle()
rd = M.route_draw()
check("a short drawn length still starts at your feet", rd.p[1].x < 1, tostring(rd.p[1].x))
check("...and still leaves a stroke to draw", rd.n >= 2, tostring(rd.n))

fresh()
put(9)
wall_x = 5
settle()
rd = M.route_draw()
check("a target 9 m away round a corner keeps a stroke", rd.n >= 2, tostring(rd.n))
check("...that starts at your feet and still reaches most of the way",
	rd.p[1].x < 1 and rd.p[rd.n].x > 7,
	string.format("%.1f -> %.1f", rd.p[1].x, rd.p[rd.n].x))

-- The head is now anchored to the CURSOR -- where the actor is on the path -- and to
-- nothing about the camera. The old trim was measured from the camera, so moving the
-- camera back moved the start; this is the same fixture asserting it no longer does.
fresh()
cam = V(-2, 1.6, 0)
settle()
rd = M.route_draw()
check("moving the camera does not move where the route starts",
	rd.p[1].x < 1, tostring(rd.p[1].x))
cam = V(0, 1.6, 0)

-- The chevrons no longer start at the drawn head -- they sit where the ROUTE says
-- (R2.28) -- so the first one is within a gap of your feet rather than on them. That is
-- the trade the absolute phase makes, and MNEAR would have hidden a mark at your feet
-- anyway.
fresh({ draw = 40, gap = 10 })
put(40)
settle()
rd = M.route_draw()
check("the first chevron is within one gap of your feet", rd.nc > 0 and rd.cp[1].x <= 10.01,
	rd.nc > 0 and string.format("%.2f", rd.cp[1].x) or "none")

-- ==========================================================================
print("\n-- snapping takes the HEIGHT only (R2.15) -----------------------------")

-- The eighth session's staircase. snap_path used to write the node's x and z as well as
-- its y, and a node's x/z are quantised to the AI grid while its y is not -- so every
-- route point landed on a grid intersection and a line at a shallow angle to the grid
-- sawtoothed between adjacent rows. The stub reproduces that property: node x is
-- floor(p.x * 10) / 10 and node z is always 0.
--
-- So: a route running at a SHALLOW angle across the stub's mesh. Every point on it sits
-- within the old SNAP_MAX_XZ of z = 0, which means the old code flattened the whole
-- route onto z = 0 -- a lateral displacement of up to a metre.
ground_y = function(x) return x * 0.1 end   -- ...and a 10% ramp, to snap a height off
fresh()
put(30, 1.0)
settle()
rd = M.route_draw()
check("a shallow-angle route keeps its plan position",
	rd.p[rd.n].z > 0.8, string.format("z = %.3f at the far end", rd.p[rd.n].z))

-- ...and the height still comes from the mesh, which is the job snapping is actually
-- for. The node's y is ground_y at the node's own (quantised) x, plus ARROW_LIFT.
local worst_y, worst_i = 0, nil
for i = 1, rd.n do
	local want = ground_y(math.floor(rd.p[i].x * 10) / 10) + 0.25
	local err = math.abs(rd.p[i].y - want)
	if err > worst_y then worst_y, worst_i = err, i end
end
check("...while its height comes from the navmesh", worst_y < 0.02,
	worst_i and string.format("%.3f m off at vertex %d", worst_y, worst_i))

-- A point the mesh cannot vouch for keeps the height it was interpolated with, rather
-- than being given a distant node's. Same hole the flat fixtures use.
hole_lo, hole_hi = 12, 18
fresh()
hole_lo, hole_hi = 12, 18                   -- fresh() clears it; this fixture wants it
ground_y = function(x) return 5.0 end       -- ...and a mesh nowhere near the route's own y
settle()
rd = M.route_draw()
local through = false
for i = 1, rd.n do
	if rd.p[i].x >= 12 and rd.p[i].x <= 18 then through = true end
end
check("the stroke still crosses ground the mesh does not cover", through)
ground_y = function(x) return 0 end
hole_lo, hole_hi = 1e9, 1e9

-- ==========================================================================
print("\n-- vertices go on the corners (the point of an adaptive stroke) --------")

-- Everything above runs on a straight line, which cannot tell a turn-driven vertex
-- placement apart from a fixed one. So: a route with a genuine right angle in it.
-- The corner is far enough off the mesh strip that snap_path leaves it alone (the
-- stub's mesh runs along z = 0, and SNAP_MAX_XZ is 1.5).
fresh({ draw = 40 })
RT.via = V(15, 0, 15)
put(30)
settle()
rd = M.route_draw()

-- The stroke has to go ROUND the corner, close to it. It no longer puts a vertex
-- exactly on it: since R2.14 the node list is smoothed first, so the corner is an arc
-- and the vertices land along that arc. What still matters is the thing the old
-- on-the-corner assertion was protecting -- that the stroke does not cut across the
-- turn, which through a doorway is the stroke crossing the jamb. So: it must pass
-- within the smoother's own cut distance (SMOOTH_CUT, 1.5 m) plus a little snapping
-- slack, and the turn must be SPREAD rather than folded.
local best = 1e9
for i = 1, rd.n do
	local dx, dz = rd.p[i].x - 15, rd.p[i].z - 15
	local d = math.sqrt(dx * dx + dz * dz)
	if d < best then best = d end
end
check("the stroke passes close to the corner", best < 1.7, string.format("%.2f m", best))

-- The turn is DISTRIBUTED over the arc: the full 90 degrees still happens across the
-- corner's neighbourhood, but no single joint carries more than a fraction of it. Before
-- smoothing, one joint carried all of it.
--
-- The total is measured as the heading change from the leg entering the neighbourhood to
-- the leg leaving it -- NOT as a sum of the per-joint figures. 1 - cos is quadratic in
-- the angle for small angles, so it does not add: four 22 degree bends sum to 0.30, not
-- to the 1.0 of the single 90 degree fold they replace. Summing them was the first
-- version of this check and it failed on correct output.
local first, last, worst = nil, nil, 0
for i = 2, rd.n - 1 do
	local dx, dz = rd.p[i].x - 15, rd.p[i].z - 15
	if math.sqrt(dx * dx + dz * dz) < 8 then      -- joints in the corner's neighbourhood
		first = first or i
		last = i
		local ax, az = rd.p[i].x - rd.p[i - 1].x, rd.p[i].z - rd.p[i - 1].z
		local bx, bz = rd.p[i + 1].x - rd.p[i].x, rd.p[i + 1].z - rd.p[i].z
		local la = math.sqrt(ax * ax + az * az)
		local lb = math.sqrt(bx * bx + bz * bz)
		if la > 1e-6 and lb > 1e-6 then
			worst = math.max(worst, 1 - ((ax / la) * (bx / lb) + (az / la) * (bz / lb)))
		end
	end
end
local total = 0
if first and last and last < rd.n then
	local ax, az = rd.p[first].x - rd.p[first - 1].x, rd.p[first].z - rd.p[first - 1].z
	local bx, bz = rd.p[last + 1].x - rd.p[last].x, rd.p[last + 1].z - rd.p[last].z
	local la = math.sqrt(ax * ax + az * az)
	local lb = math.sqrt(bx * bx + bz * bz)
	if la > 1e-6 and lb > 1e-6 then
		total = 1 - ((ax / la) * (bx / lb) + (az / la) * (bz / lb))
	end
end
check("...turning through the whole corner", total > 0.8, string.format("%.2f", total))
-- 0.15 in 1 - cos units is about 32 degrees. Three smoothing passes measure 0.107 here
-- (~26 degrees) on the worst case there is, a true right angle; the 45 degree kinks the
-- probes actually produce come out near 0.06.
check("...spread over several joints, not folded at one", worst < 0.15,
	string.format("worst joint %.3f", worst))

-- The straight legs either side stay cheap: 42 m of path, not 42 vertices. The ceiling
-- moved 16 -> 28 with R2.13, because angle-based spacing deliberately buys extra
-- vertices in the near few metres, where each one is the largest thing on screen. This
-- fixture measures 24; the slack is for the snapping jitter in the stub's navmesh, which
-- trips TURN_TOL a few times along the diagonal.
check("...while the straight legs stay cheap", rd.n <= 28, tostring(rd.n))
check("...and no segment exceeds SEG_MAX", (function()
	for i = 2, rd.n do
		local dx, dz = rd.p[i].x - rd.p[i - 1].x, rd.p[i].z - rd.p[i - 1].z
		if math.sqrt(dx * dx + dz * dz) > 5.001 then return false end
	end
	return true
end)())

-- ==========================================================================
print("\n-- the tuning settings -------------------------------------------------")

-- These were once driven through F7 cyclers (debug_gap / debug_draw / debug_xray),
-- retired at R2.44 as MCM-shadowing conveniences: each wrote a value the next
-- read_config would silently overwrite, which is a confusing state to leave a tester
-- in. The BEHAVIOUR they guarded is the point and is kept, now asserted through
-- configure() -- the path MCM itself uses, so this covers the shipping route rather
-- than a debug-only one.
--
-- The target is put well out of range so the PATH is longer than any draw length used
-- here -- otherwise "draw further ahead" has nothing further to draw and the test
-- passes or fails on the fixture rather than on the code.
fresh()
put(200)
settle()
local before_n   = M.route_draw().n
local before_c   = M.status().chevs
local before_gap = M.status().gap

M.configure({ on = true, draw = 40, gap = 6, xray = true })
settle()
check("a tighter gap changes the chevron spacing", M.status().gap ~= before_gap,
	string.format("%s -> %s", tostring(before_gap), tostring(M.status().gap)))
-- Inverse, not merely different: tighter spacing over the same length is more
-- chevrons. And the STROKE must not move -- its vertices are decided by the shape of
-- the path, which a decoration setting has no business changing.
check("...and rebuilds the chevrons in step with it",
	(M.status().gap < before_gap) == (M.status().chevs > before_c),
	string.format("gap %s->%s, chevrons %d->%d", tostring(before_gap),
		tostring(M.status().gap), before_c, M.status().chevs))
check("...leaving the stroke itself alone", M.route_draw().n == before_n,
	string.format("%d -> %d", before_n, M.route_draw().n))

before_n = M.route_draw().n
local before_draw = M.status().draw
M.configure({ on = true, draw = 80, gap = 6, xray = true })
settle()
check("a longer draw distance changes the length", M.status().draw ~= before_draw,
	string.format("%s -> %s", tostring(before_draw), tostring(M.status().draw)))
check("...and draws more or less of it accordingly",
	(M.status().draw > before_draw) == (M.route_draw().n > before_n),
	string.format("draw %s->%s, vertices %d->%d", tostring(before_draw),
		tostring(M.status().draw), before_n, M.route_draw().n))

M.configure({ on = true, draw = 80, gap = 6, xray = false })
check("the x-ray setting flips", M.status().xray == false)
M.configure({ on = true, draw = 80, gap = 6, xray = true })
check("...and back", M.status().xray == true)

-- ==========================================================================
print("\n-- the status dump names the closed gate ------------------------------")

-- Three sessions were spent guessing which condition was stopping the route,
-- because the F7 dump could not say. Each of these is one of those guesses.
fresh({ on = false })
tick(50, 3)
check("off says so", M.status().why == "option off", M.status().why)

fresh()
mk_target = nil
tick(50, 3)
check("no objective says so", M.status().why == "no objective target", M.status().why)

fresh()
put(2)
tick(50, 3)
check("arrived says so", M.status().why == "arrived", M.status().why)

fresh()
put(900)
tick(50, 3)
check("beyond the ceiling says so",
	M.status().why == "target beyond the sanity ceiling", M.status().why)

fresh()
put(12)
wall_x = nil
tick(50, 12)
check("suppressed by sight says so",
	M.status().why == "target in plain sight, up close", M.status().why)

fresh()
settle()
check("and a working route says it is drawing", M.status().why == "drawing",
	M.status().why)

fresh()
RT.partial = true
settle()
check("...and says when the route is only partial",
	M.status().why == "drawing (partial route)", M.status().why)
check("...which status also reports as a flag", M.status().partial == true)

-- ==========================================================================
print("\n-- per-view drawn distance (R2.24) ------------------------------------")

-- The ground line and the minimap trail carry SEPARATE drawn distances, so the list is
-- built once at the longer of the two and each view takes its own share of it through
-- route_limit. That makes s[]/cs[] -- the arclength of every vertex and chevron -- load
-- bearing rather than bookkeeping: a wrong one silently gives a view the wrong length,
-- which in game looks like the setting simply not working.
fresh({ draw = 80, gap = 5 })
put(200)
settle()
rd = M.route_draw()

check("every vertex carries its arclength", (function()
	for i = 1, rd.n do if type(rd.s[i]) ~= "number" then return false end end
	return true
end)())
check("...starting at zero", rd.s[1] == 0, tostring(rd.s[1]))
check("...and rising monotonically", (function()
	for i = 2, rd.n do if rd.s[i] < rd.s[i - 1] then return false, i end end
	return true
end)())
check("...to no more than the published distance", rd.s[rd.n] <= 80.01,
	string.format("%.2f", rd.s[rd.n]))
check("every chevron carries one too", (function()
	for k = 1, rd.nc do if type(rd.cs[k]) ~= "number" then return false end end
	return true
end)())

-- The whole point: a shorter view gets less of the same list.
local full_n, full_nc = M.route_limit(nil)
check("no limit asks for the whole list", full_n == rd.n and full_nc == rd.nc,
	string.format("%d/%d vs %d/%d", full_n, full_nc, rd.n, rd.nc))

local half_n, half_nc = M.route_limit(40)
check("half the distance draws fewer vertices", half_n < rd.n,
	string.format("%d of %d", half_n, rd.n))
check("...and fewer chevrons with them", half_nc < rd.nc,
	string.format("%d of %d", half_nc, rd.nc))
check("...none of them past the limit", rd.s[half_n] <= 40.01,
	string.format("%.2f", rd.s[half_n]))
check("...and none dropped that was inside it", half_n == rd.n or rd.s[half_n + 1] > 40,
	string.format("%.2f", rd.s[half_n + 1] or -1))
check("...with every kept chevron inside it too", (function()
	for k = 1, half_nc do
		if rd.cs[k] > 40.01 then return false, k end
	end
	return true
end)())

-- A chevron borrows the eased alpha of the vertex at or before it, so one surviving a
-- cut that its vertex did not would index past the end of the drawn stroke.
check("...and none borrowing an alpha past the cut", (function()
	for k = 1, half_nc do
		if rd.ci[k] > half_n then return false, k end
	end
	return true
end)())

-- Longer than the list is not an error: the view simply gets everything there is. This
-- is the normal case for whichever view asked for the longer distance.
local over_n = M.route_limit(500)
check("asking for more than was published gives all of it", over_n == rd.n,
	string.format("%d vs %d", over_n, rd.n))

-- A stroke needs both ends of a segment, so an absurdly short view gets a stub rather
-- than a single point (which would draw nothing) or an empty list (which reads as "no
-- route" and would flicker the whole view off).
local tiny_n = M.route_limit(0)
check("an impossibly short distance still leaves a segment", tiny_n == 2,
	tostring(tiny_n))

-- ==========================================================================
print("\n-- reset -------------------------------------------------------------")

fresh()
settle()
M.reset()
check("reset drops the route", M.status().target == nil and M.status().points == 0)
check("...and stops publishing", drawing() == 0)

-- ==========================================================================
print("\n-- log format strings ------------------------------------------------")

check("every format string uses only %s", #fmt_violations == 0,
	fmt_violations[1] and (#fmt_violations .. " bad, first: " .. fmt_violations[1]))

-- ==========================================================================
print("\n-- heading steadiness vs corner response ------------------------------")
-- CHEV_DIR_M is the one number governing how a mark decides which way it points: the
-- half-width, in metres, of the chord its direction is averaged over. It is a straight
-- trade with no free side, so BOTH sides get measured here and both numbers print --
-- because the temptation, every time the marks look busy, is to widen it again.
--
--   too short  each mark inherits the error of whatever leg it sits on, so the run
--              fidgets as you walk. Logged as the nineteenth session's first complaint.
--   too long   a real corner stops turning the marks until you are past it, and a mark
--              that has not turned yet is pointing at the wall you are going around.
--
-- WIDENING IT WAS TRIED AND THESE NUMBERS ARE WHY IT WAS PUT BACK. The conveyor made the
-- marks' rotation read as motion rather than as an arrangement, which looks like fidget
-- and invites exactly that. Measured: 3.0 -> 6.0 buys 0.3 degrees of steadiness for 15.6
-- of corner error, and the steadiness column is not even monotonic -- there is almost no
-- fidget left to remove, because snap_path takes only the height and the node list is
-- smoothed before headings are computed. What is left is real curvature, and averaging
-- over real curvature does not steady a mark, it makes it turn late. See CHEV_DIR_M in
-- iqm_nav.script for the full table.
do
	-- A genuine right angle: out along +x to (25, 0), then away along +z. Both legs are
	-- axis-aligned so "which way should this mark point" has an exact answer, and the
	-- first leg is long enough to hold marks clear of BOTH the lead-in (LEAD_M = 8 m,
	-- which deliberately angles the near marks) and the smoother's arc at the corner.
	fresh({ draw = 60, gap = 4 })
	RT.via = V(25, 0, 0)
	put(25, 30)
	settle()
	local rd = M.route_draw()

	-- CORNER RESPONSE. Marks well past the bend must be committed to the outgoing leg.
	-- A mark that has not turned yet is pointing at the wall you are going around, which
	-- is the failure widening this trades against.
	local late, n_past = 0, 0
	for k = 1, rd.nc do
		local p, hz = rd.cp[k], rd.cdz[k]
		local past = p.z            -- metres along the outgoing leg, corner at z = 0
		if past > 3.0 and p.x > 22 then
			n_past = n_past + 1
			-- 3 m past the corner the mark should be committed to the new leg
			local off = math.deg(math.acos(math.max(-1, math.min(1, hz))))
			late = math.max(late, off)
		end
	end
	print(string.format("     corner: worst heading error 3 m past the bend  %.1f deg (%s marks)",
		late, n_past))
	-- Non-vacuity first. The earlier version of this fixture put the corner where no
	-- mark landed, so it measured nothing and reported a perfect 0.0 -- a passing test
	-- that could not fail is worse than no test.
	check("the corner fixture actually puts marks past the bend", n_past >= 2,
		tostring(n_past))
	check("a corner still turns the marks within 3 m of it", late < 30,
		string.format("%.1f deg", late))

	-- STEADINESS, and it needs a NOISE SOURCE to mean anything. The default fixture world
	-- is laterally perfect -- vertex_position always returns z = 0 and snap_path takes
	-- only the height -- so on it every baseline scores ~0 and the test would prove
	-- nothing while looking like proof. A real search returns nodes off a grid-aligned
	-- navmesh, so: a straight run with a deterministic lateral wobble on every node.
	--
	-- Disagreement between neighbouring marks on a straight stretch IS the fidget,
	-- caught in a still frame instead of over time.
	fresh({ draw = 45, gap = 4 })
	local wob = { 0.35, -0.30, 0.28, -0.35, 0.31, -0.26, 0.34, -0.33, 0.29, -0.35,
	              0.32, -0.28, 0.30, -0.31, 0.27, -0.34 }
	local nodes = {}
	for i = 1, 16 do nodes[i] = V((i - 1) * 3.0, 0, wob[i]) end
	RT.nodes = nodes
	put(45, 0)
	settle()
	rd = M.route_draw()
	local worst, n_str = 0, 0
	for k = 2, rd.nc do
		local a = rd.cp[k - 1]
		if a.x > 10 then          -- clear of the lead-in (LEAD_M = 8)
			n_str = n_str + 1
			worst = math.max(worst, math.deg(math.acos(math.max(-1, math.min(1,
				rd.cdx[k] * rd.cdx[k - 1] + rd.cdz[k] * rd.cdz[k - 1])))))
		end
	end
	print(string.format("     straight: worst turn between neighbours on a wobbly run  %.1f deg (%s pairs)",
		worst, n_str))
	check("the steadiness fixture actually compares marks", n_str >= 3, tostring(n_str))
	check("marks on a straight stretch agree with their neighbours", worst < 12,
		string.format("%.1f deg", worst))
end

-- ==========================================================================
print("\n-- the conveyor ------------------------------------------------------")
-- Marks flowing along the route rather than sitting on fixed ground. The schedule was
-- already by ARCLENGTH ahead of the actor, so this is one added term -- and the things
-- that can go wrong with it are all about the WRAP, which is what these check.
do
	fresh({ gap = 10, flow = 0 })
	tick(50, 40)
	local rd = M.route_draw()
	local held = {}
	for k = 1, rd.nc do held[k] = rd.cp[k].x end
	tick(50, 20)
	rd = M.route_draw()
	local moved = 0
	for k = 1, math.min(#held, rd.nc) do
		moved = math.max(moved, math.abs(rd.cp[k].x - held[k]))
	end
	check("flow 0 leaves the marks exactly where they were", moved < 1e-6,
		string.format("%.4f m", moved))

	-- ...and with flow on they move, at the speed asked for and no other.
	fresh({ gap = 10, flow = 2.0 })
	tick(50, 40)
	rd = M.route_draw()
	local before = rd.cp[1].x
	local t0 = clock
	tick(50, 10)                       -- 500 ms at 2 m/s = 1.0 m
	rd = M.route_draw()
	local want = (clock - t0) * 0.001 * 2.0
	check("flow moves the run at the configured speed",
		math.abs((rd.cp[1].x - before) - want) < 0.01,
		string.format("moved %.3f m, wanted %.3f", rd.cp[1].x - before, want))

	-- THE SEAM. At phase = gap the run has to land exactly where it started, or the loop
	-- shows as a jerk once per gap -- the one artefact that would make this unusable.
	fresh({ gap = 10, flow = 2.0 })
	tick(50, 40)
	rd = M.route_draw()
	local at0 = {}
	for k = 1, rd.nc do at0[k] = rd.cp[k].x end
	tick(50, 100)                      -- 5 s at 2 m/s = 50 m = exactly 5 gaps
	rd = M.route_draw()
	local seam = 0
	for k = 1, math.min(#at0, rd.nc) do
		seam = math.max(seam, math.abs(rd.cp[k].x - at0[k]))
	end
	check("a whole number of gaps later the picture is identical (the wrap is seamless)",
		seam < 0.01, string.format("%.4f m adrift", seam))

	-- Even spacing is what makes that wrap seamless, so NEAR_FILL -- which deliberately
	-- makes the first two intervals half-length -- must be off while the flow runs.
	fresh({ gap = 10, flow = 2.0 })
	tick(50, 40)
	rd = M.route_draw()
	local worst = 0
	for k = 2, rd.nc do
		worst = math.max(worst, math.abs(math.abs(rd.cp[k].x - rd.cp[k - 1].x) - 10))
	end
	check("the flowing run is EVENLY spaced (no near-fill mark)", worst < 0.01,
		string.format("%.3f m off", worst))

	-- A hand-edited config must not be able to run the marks backwards into the player,
	-- which says the opposite of what a route is for, nor strobe.
	fresh({ gap = 10, flow = -5 })
	tick(50, 20)
	rd = M.route_draw()
	local b = rd.cp[1].x
	tick(50, 10)
	rd = M.route_draw()
	check("a negative speed is clamped to held-still, not reversed",
		math.abs(rd.cp[1].x - b) < 1e-6, string.format("%.4f m", rd.cp[1].x - b))
	fresh({ gap = 10, flow = 500 })
	tick(50, 20)
	check("an absurd speed is clamped rather than obeyed", drawing() > 0)

	-- THE BELT'S SPEED IS THE BELT'S, NOT THE BELT'S PLUS YOURS (R2.40).
	--
	-- This is the fixture for "the conveyor speeds up when I move". The marks used to be
	-- scheduled from the actor's own arclength (R2.29, arrangement 3), so a mark held a
	-- fixed distance ahead of him and its speed over the GROUND was flow + his own: 2 m/s
	-- standing still and 6 m/s at a sprint. Now they sit on an absolute lattice and only
	-- the clock moves them.
	--
	-- Measured as the LATTICE PHASE rather than as one mark's displacement, because marks
	-- enter and leave the run as it slides and "the same mark" is not a thing that
	-- survives a wrap. Every mark sits at n*gap + phase, so any of them modulo the gap
	-- gives the phase, whichever ones happen to be drawn.
	local function belt_phase(gap)
		local rd = M.route_draw()
		if rd.nc == 0 then return nil end
		return rd.cp[1].x % gap
	end
	local function belt_moved(gap, before)
		local now = belt_phase(gap)
		if not (now and before) then return nil end
		return (now - before) % gap          -- forward only; the belt never reverses
	end

	fresh({ gap = 10, flow = 2.0, draw = 40 })
	put(60)
	settle()
	local p0 = belt_phase(10)
	tick(50, 10)                            -- 500 ms standing still
	local still = belt_moved(10, p0)
	check("the belt runs at `flow` while the player stands still",
		still and math.abs(still - 1.0) < 0.02,
		still and string.format("%.3f m in 500 ms, wanted 1.000", still) or "no marks")

	-- The same half-second, now with WALKING in it -- 2 m/s, which is what a walk is. Under
	-- the pre-R2.40 scheduling the belt would have carried 1.0 + 1.0 m over the ground.
	--
	-- 2 m/s and not the 6 m/s this fixture originally used, which was written as "walks 3 m"
	-- and is 3 m in half a second, i.e. a hard sprint. It passed anyway while the belt was
	-- flat, because a flat belt does not care how fast you go -- so the mislabelling was
	-- invisible until R2.42 gave the fast end its own behaviour and the "walking" case
	-- started reporting the sprint rule. The speed in a speed fixture has to be the speed
	-- it says it is.
	local function move_for(secs, vel)
		for _ = 1, math.floor(secs / 0.05) do
			actor_pos = V(actor_pos.x + vel * 0.05, 0, 0)
			cam = V(actor_pos.x, 1.6, 0)
			tick(50, 1)
		end
	end
	move_for(1.0, 2.0)                      -- let the speed estimate settle on the walk
	p0 = belt_phase(10)
	move_for(0.5, 2.0)
	local walked = belt_moved(10, p0)
	check("...and at exactly the same speed while he walks through it",
		walked and math.abs(walked - 1.0) < 0.02,
		walked and string.format("%.3f m in 500 ms, wanted 1.000", walked) or "no marks")

	-- ...UNTIL HE WOULD OVERTAKE IT (R2.42). A sprint is the one speed fast enough to run
	-- the marks down, so from there the belt is floored at (his speed - CATCH_M) and he
	-- gains at CATCH_M and no more. Both halves are asserted: that the belt speeds up, and
	-- that it speeds up by the RIGHT amount -- a floor that overshot would be the original
	-- "it accelerates when I move" complaint coming back in a new place.
	--
	-- The speed estimate is eased over 0.30 s, so the sprint is held long enough for it to
	-- arrive before anything is measured.
	fresh({ gap = 10, flow = 2.0, draw = 60 })
	put(80)
	settle()
	local SPRINT = 5.0
	local function run_for(secs)
		local n = math.floor(secs / 0.05)
		for _ = 1, n do
			actor_pos = V(actor_pos.x + SPRINT * 0.05, 0, 0)
			cam = V(actor_pos.x, 1.6, 0)
			tick(50, 1)
		end
	end
	run_for(1.5)                            -- let flow_v converge on the sprint
	p0 = belt_phase(10)
	run_for(0.5)
	local sprinted = belt_moved(10, p0)
	check("the belt keeps ahead of a sprint instead of being run down",
		sprinted and sprinted > 1.2,
		sprinted and string.format("%.3f m in 500 ms (a flat belt would do 1.000)", sprinted)
		or "no marks")
	-- 5 m/s sprint - 1 m/s allowance = 4 m/s belt = 2.0 m in 500 ms.
	check("...at the player's speed less the catch-up allowance, not faster",
		sprinted and math.abs(sprinted - 2.0) < 0.15,
		sprinted and string.format("%.3f m, wanted 2.000", sprinted) or "no marks")

	actor_pos = V(0, 0, 0)
	cam = V(0, 1.6, 0)

	-- A MARK KEEPS ITS ID FOR AS LONG AS IT EXISTS (R2.43b). RD.cn is what the renderer
	-- hashes to pick a texture variant, so an id that changes under a travelling mark is
	-- that mark visibly swapping picture as it slides -- reported off R2.42, where the
	-- bare lattice index gained 1 on every phase wrap.
	--
	-- Marks are matched frame to frame BY POSITION, not by slot, because the slot is
	-- exactly what is not stable: at a wrap every mark takes the slot of the one ahead.
	-- A mark moves flow*dt per tick, so nearest-position matching inside a tolerance well
	-- under the gap is unambiguous. A mark with no predecessor within tolerance was born
	-- this frame and is skipped -- it has no previous id to disagree with.
	fresh({ gap = 3, flow = 1.5, draw = 40 })
	put(60)
	settle()
	local prev = {}
	local checked, swaps, worst = 0, 0, nil
	local function snapshot()
		local rd, cur = M.route_draw(), {}
		for k = 1, rd.nc do
			cur[k] = { x = rd.cp[k].x, id = rd.cn and rd.cn[k] }
		end
		return cur
	end
	prev = snapshot()
	-- Well past one wrap: gap 3 at 1.5 m/s wraps every 2 s, and 6 s is three of them.
	for _ = 1, 120 do
		tick(50, 1)
		local cur = snapshot()
		for _, c in ipairs(cur) do
			local best, bd = nil, 0.9        -- tolerance well inside the 3 m gap
			for _, p in ipairs(prev) do
				local d = math.abs(c.x - p.x)
				if d < bd then best, bd = p, d end
			end
			if best then
				checked = checked + 1
				if best.id ~= c.id then
					swaps = swaps + 1
					worst = worst or string.format("id %s -> %s at x=%.2f",
						tostring(best.id), tostring(c.id), c.x)
				end
			end
		end
		prev = cur
	end
	check("the fixture actually tracked marks across several wraps", checked > 300,
		checked .. " matched pairs")
	check("a travelling mark keeps its id (its texture cannot swap under it)",
		swaps == 0, worst or (swaps .. " swaps"))

	actor_pos = V(0, 0, 0)
	cam = V(0, 1.6, 0)
end

-- ==========================================================================
print("\n-- the bottom of the route_dist slider (R2.41) ------------------------")
-- The MCM floor moved 20 m -> 1 m. Twenty metres had been the floor since the option
-- existed, so no code below it had ever been handed a draw shorter than a couple of
-- segments -- and SEG_MIN is 1 m, MAX_CHEV is 16, and the vertex emitter works by
-- accumulating arclength until it is allowed to place one. A length under the first
-- segment's own minimum is exactly the input that can produce a one-vertex list, which
-- draws nothing while still reporting a live route.
do
	for _, dm in ipairs({ 1, 2, 5 }) do
		fresh({ draw = dm, gap = 3 })
		put(40)
		local ok = settle()
		local rd = M.route_draw()
		check(string.format("a %d m draw still draws", dm), ok and rd.n >= 2,
			string.format("%d vertices", rd.n))
		-- THE PUBLISHED LIST IS NOT THE VIEW, and at these lengths the difference stops
		-- being academic. configure floors draw_m at SEG_MAX (5 m), so asking for 1 m
		-- still BUILDS 5 m -- a stroke needs both ends of a segment, and a list that
		-- stopped at 1 m could be a single vertex, which draws nothing while still
		-- reporting a live route. What honours the setting is route_limit, which every
		-- view goes through. Checked in that order, because the first assertion I wrote
		-- here measured the publish and failed against correct behaviour.
		local far = 0
		for i = 1, rd.n do far = math.max(far, rd.s[i] or 0) end
		check("...publishing at least a segment (floored at SEG_MAX)",
			far >= math.min(5, dm), string.format("reaches %.2f m", far))
		local kn, knc = M.route_limit(dm)
		check("...and the view clips to the metre asked for", (function()
			for k = 1, knc do
				if (rd.cs[k] or 0) > dm + 1e-6 then return false end
			end
			return kn >= 2
		end)(), string.format("%d vertices, %d marks kept", kn, knc))
	end

	-- ...and the conveyor at the floor, where the run is shorter than one gap. The
	-- lattice is anchored on the actor's own arclength, so this is the case where the
	-- head of the run can be the only mark there is.
	fresh({ draw = 1, gap = 3, flow = 2.0 })
	put(40)
	check("a 1 m draw with the belt running does not error", settle() ~= nil)
end

-- ==========================================================================
print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
