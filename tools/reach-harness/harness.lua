-- Harness: HOW FAR each marker role is found, checked outside the game.
--
-- WHY THIS EXISTS. Two halves of this mod disagreed for three releases and nothing
-- noticed. Quest targets arrive from task_manager.task_info already identified, so they
-- are tracked at any range and their marker reaches beacon_dist (60 m default). Service
-- and guide NPCs have to be FOUND -- the engine binds map spots by id only, so the mod
-- asks each NPC in turn -- and that scan was capped at appear_dist (16 m). The cap was
-- correct while the scanner only fed cards, which fade to nothing at appear_dist, and
-- became wrong the moment markers were given a longer reach of their own. Result: a
-- service marker could not appear past 16 m whatever beacon_dist said, and since a
-- marker is also suppressed while its card is up, it only ever showed inside 16 m AND
-- behind cover. Reported from play as "services only show when much closer".
--
-- Nothing catches that class of bug by itself. It is not a crash, not a syntax error,
-- and each half is defensible read alone: `<= ctx.appear2` looks obviously right next to
-- a card, and `max(appear_d, beacon_d)` looks obviously right next to a marker. Only the
-- RELATIONSHIP between them is wrong, so the relationship is what gets asserted here.
--
-- What it checks:
--
--   1. PARITY. With the service/guide marker switches on, the extras scan reaches exactly
--      as far as the marker gate does -- the property the bug violated.
--   2. NO WIDENING WHEN UNUSED. Switches off, the scan stays at the card's range. The fix
--      must not make every install pay for a feature it is not running.
--   3. THE TRIM. Past the card's range, only roles that can carry a marker are kept, so
--      the wider scan cannot spend MAX_CARDS slots on cards drawn at alpha 0.
--   4. THE WORK PROBE STAYS HOME. tw_has_work is the expensive check iqm_taskwork exists
--      to ration, and work is a card with no marker. It must remain on appear_dist.
--   5. THE SOURCE STILL SAYS SO. The gate, the trim and the work condition are read out
--      of iqm_core itself, so reverting any of them fails here rather than in play.
--   6. THE ROUTE GOAL'S THROTTLE, RUN. iqm_core.route_goal is asked every frame by
--      iqm_nav and costs a walk of task_info plus an is_active_task per live task, so it
--      resolves at ~5 Hz and hands back the cached tuple in between. That is a
--      time-dependent behaviour and no other harness calls the function at all, let alone
--      twice, so it is DRIVEN here against a fake clock rather than grepped: repeats
--      inside the window must do no work, the window expiring must re-resolve, and the
--      explicit reset must beat the timer. See its own section header below.
--   7. goal_pos's OFFLINE CACHE, RUN. route_goal's throttle covered one of goal_pos's
--      three callers; the other two (iqm_beacon's waypoint and task markers) throttle the
--      ID and ask for the POSITION every frame, which is eight engine crossings a frame
--      while the object is offline -- the normal state of both. The offline half is now
--      cached on the same 250 ms tick those callers already use and the ONLINE half is
--      deliberately not, so what is asserted is the SPLIT: crossings counted per stub,
--      the online branch live frame by frame, all three returns preserved, both negative
--      answers cached, and neither surviving a level change or an object coming online.
--
-- Usage:
--   python check_lua.py --run tools/reach-harness/harness.lua
--   VERBOSE=1 ... for the passing lines too
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

local here = arg and arg[0] and arg[0]:gsub("[^/\\]+$", "") or ""
local ROOT = here .. "../../"

local function slurp(rel)
	local f = io.open(ROOT .. rel, "r")
	if not f then error("cannot open " .. ROOT .. rel .. " -- run from the mod root") end
	local s = f:read("*a")
	f:close()
	return s
end

-- Read as ONE string across the files the rule now spans. This check is about the
-- RELATIONSHIP between two numbers, and R2.45's split put them in different files:
-- beacon_d is still read_config's (iqm_core) and the taskwork reach is now
-- iqm_taskwork.apply_config's (R2.47, when the push adapters were turned round), while
-- extra2, the scan context and extras_scan_one went to iqm_scan. Reading only one of
-- them would leave half the assertions grepping for text that is simply elsewhere --
-- which passes rather than fails, and would hide exactly the drift this file exists
-- to catch.
local src = slurp("gamedata/scripts/iqm_core.script")
         .. slurp("gamedata/scripts/iqm_scan.script")
         .. slurp("gamedata/scripts/iqm_taskwork.script")

-- ------------------------------------------------------- the model under test
-- read_config's two range rules, transcribed. Kept as plain arithmetic on the option
-- values so the harness states the RULE, not a number: change a default in DEFAULTS and
-- these still hold, change the relationship and they do not.
local function ranges(cfg)
	local appear_d = cfg.appear_dist or 16
	local beacon_d = math.max(appear_d, cfg.beacon_dist or 60)
	-- br.guider / br.trader from read_config. Note neither rides mark_beacon: that gates
	-- the turn-in only. bok is the modded-exe projection binding.
	local bok      = cfg.w2u ~= false
	local br_guide = bok and cfg.mark_guiders and cfg.beacon_guiders or nil
	local br_svc   = bok and cfg.mark_traders and cfg.beacon_traders or nil
	local extra_d  = (br_guide or br_svc) and beacon_d or appear_d
	return appear_d, beacon_d, extra_d, (br_guide or br_svc) ~= nil
end

-- extras_scan_one's keep/drop decision, transcribed. Returns the role kept, or nil.
local BEACONABLE = { guider = true, trader = true, mechanic = true, barman = true, medic = true }
local function classify(role, dist, cfg)
	local appear_d, _, extra_d = ranges(cfg)
	if dist > extra_d then return nil end                        -- never looked at
	local near = dist <= appear_d
	if not near and not (role and BEACONABLE[role]) then return nil end   -- the trim
	return role
end

-- and whether a tracked entry actually draws a marker at that distance
local function marks(role, dist, cfg)
	local _, beacon_d = ranges(cfg)
	if classify(role, dist, cfg) == nil then return false end
	return BEACONABLE[role] == true and dist < beacon_d
end

local ON = { mark_guiders = true, beacon_guiders = true,
             mark_traders = true, beacon_traders = true,
             mark_targets = true, mark_beacon = true }
local function with(over)
	local c = {}
	for k, v in pairs(ON) do c[k] = v end
	for k, v in pairs(over or {}) do c[k] = v end
	return c
end

-- ------------------------------------------------------------- 1. the parity
do
	local cfg = with()
	local appear_d, beacon_d, extra_d = ranges(cfg)
	check("extras scan reaches the marker gate", extra_d == beacon_d,
	      string.format("extra %s vs beacon %s", extra_d, beacon_d))
	check("...which is wider than the card", extra_d > appear_d)

	-- the reported symptom, as a test: a trader partway out must now be found AND marked
	for _, d in ipairs{ 17, 25, 40, 59 } do
		check("trader found at " .. d .. " m", classify("trader", d, cfg) == "trader")
		check("trader marked at " .. d .. " m", marks("trader", d, cfg))
	end
	check("trader not marked past beacon_dist", not marks("trader", 61, cfg))
	check("guide marked at 40 m", marks("guider", 40, cfg))

	-- ...and matches the turn-in, which is the thing that was actually asked for
	check("service reach equals turn-in reach", extra_d == beacon_d)

	-- raising beacon_dist must carry the services with it; that it did NOT was the bug
	local far = with{ beacon_dist = 150 }
	check("service follows a raised beacon_dist", marks("trader", 120, far))
	check("...and the scan widened to match", select(3, ranges(far)) == 150)
end

-- ------------------------------------------- 2. no widening when unused
do
	-- both marker switches off: cards only, so the scan must not reach further than it
	-- did before the fix. An install not using service markers pays nothing.
	local off = with{ beacon_guiders = false, beacon_traders = false }
	local appear_d, _, extra_d, any = ranges(off)
	check("no beaconable extras role", not any)
	check("scan stays at the card range", extra_d == appear_d)
	check("far trader not classified", classify("trader", 40, off) == nil)
	check("near trader still classified", classify("trader", 10, off) == "trader")

	-- one switch is enough to widen it
	local guides_only = with{ beacon_traders = false }
	check("guides alone widen the scan", select(3, ranges(guides_only)) > appear_d)

	-- and on a bare exe (no projection binding) nothing beacons, so nothing widens
	local bare = with{ w2u = false }
	check("no widening without the modded exes", select(3, ranges(bare)) == appear_d)
end

-- ------------------------------------------------------------- 3. the trim
do
	local cfg = with()
	-- "important" has carried no marker since R2.29; a work card has none either. Neither
	-- may be tracked past the card's range, where it would hold a slot to draw nothing.
	for _, role in ipairs{ "important", "work" } do
		check(role .. " kept inside card range",   classify(role, 10, cfg) == role)
		check(role .. " dropped past card range",  classify(role, 40, cfg) == nil)
	end
	-- an unclassified NPC is dropped either way, and must not error on the nil role
	check("nil role dropped far", classify(nil, 40, cfg) == nil)
	check("nil role dropped near", classify(nil, 10, cfg) == nil)
	-- every beaconable role survives the trim
	for role in pairs(BEACONABLE) do
		check(role .. " survives the trim", classify(role, 40, cfg) == role)
	end
end

-- ------------------------------------------------- 5. the source still says so
-- Read out of the file, because the model above is only worth anything if it is still
-- describing the code. Each of these is one of the three edits the fix consists of.
do
	local body = src:match("local function extras_scan_one.-\nend\n")
	check("extras_scan_one found", body ~= nil)
	if body then
		check("the scan gates on extra2", body:find("d2 <= ctx.extra2", 1, true) ~= nil,
		      "the range gate is not reading ctx.extra2")
		check("the old appear2 gate is gone", body:find("distance_to_sqr(ctx.apos) <= ctx.appear2", 1, true) == nil)
		check("`near` is measured against appear2", body:find("local near = d2 <= ctx.appear2", 1, true) ~= nil)
		check("the work probe is gated on near", body:find("if near and C.mark_work", 1, true) ~= nil,
		      "tw_has_work would run out to the wider extras range")
		check("the trim is present",
		      body:find("if not near and not (out and beacon_roles[out]) then return end", 1, true) ~= nil)
	end

	check("extra2 is derived from the marker switches",
	      src:find("extra2 = (br.guider or br.trader) and beacon2 or appear2", 1, true) ~= nil)
	check("the marker gate still takes the wider of the two",
	      src:find("beacon_d     = max(appear_d, C.beacon_dist)", 1, true) ~= nil)
	check("extra2 is published to the scan context",
	      src:find("_scan_ctx.extra2  = extra2", 1, true) ~= nil)
	-- iqm_taskwork is configured with appear_dist, and must stay that way: it is the
	-- other half of "the work probe does not follow the markers out". The line moved
	-- into iqm_taskwork's own apply_config at R2.47, when the last push adapters were
	-- turned round -- so the file it is read out of moved with it, and the rule did not.
	check("taskwork is still configured with appear_dist",
	      src:find("configure(C.work_probe, C.appear_dist", 1, true) ~= nil)
end

-- =====================================================================
-- 6. route_goal's throttle, RUN against a fake clock
-- =====================================================================
-- WHY THIS IS DRIVEN RATHER THAN GREPPED. iqm_nav asks route_goal on every frame,
-- unconditionally. Each real resolve walks task_manager.task_info, asks the engine
-- `is_active_task` once per live task, may walk `tracked` measuring every entry, and then
-- pays an alife() lookup and a game_graph() level test in goal_pos. On a full GAMMA save
-- that is a dozen engine round-trips per frame for a position that moves centimetres
-- between them, so the tuple is cached for 200 ms.
--
-- A cache is exactly the kind of change that passes every static check and is still
-- wrong: the failure mode is not a crash or a bad number but a RIGHT number arriving
-- LATE -- a quest that appears and is not routed to for a fifth of a second, or worse, a
-- cached nil that is never re-examined because nothing in the module told it to look
-- again. None of that is visible in the text of the function, so the module is loaded and
-- the function is CALLED, with time under this file's control and with the underlying
-- engine work counted.
--
-- The module's file locals (C, tracked, get_obj) and its file-local writers of `tracked`
-- (ensure_entry) are reached through debug.getupvalue off the functions it exports. That
-- is not a trick played on the module: an upvalue read is the only way to drive the REAL
-- ensure_entry, and driving the real one is the difference between proving the hook is
-- wired and proving a hook exists.
do
	local ENV = {}
	ENV.pairs, ENV.ipairs, ENV.tostring, ENV.tonumber = pairs, ipairs, tostring, tonumber
	ENV.type, ENV.string, ENV.table, ENV.math, ENV.os = type, string, table, math, os
	ENV.setmetatable, ENV.print, ENV.pcall, ENV.select = setmetatable, print, pcall, select
	ENV.error, ENV.assert, ENV.unpack, ENV.next = error, assert, unpack, next
	ENV._G = ENV
	ENV.printf = function() end

	local V2MT = {}
	V2MT.__index = V2MT
	function V2MT:set(x, y) self.x, self.y = x, y; return self end
	ENV.vector2 = function() return setmetatable({ x = 0, y = 0 }, V2MT) end

	local VecMT = {}
	VecMT.__index = VecMT
	function VecMT:set(a, b, c)
		if type(a) == "table" then self.x, self.y, self.z = a.x, a.y, a.z
		else self.x, self.y, self.z = a, b, c end
		return self
	end
	-- Same trap as the other harnesses: luabind's vector has no __eq, so comparing two of
	-- them is a CTD in game. A stub that answered by identity would hide it.
	VecMT.__eq = function()
		error("No such operator [__eq] defined in class [vector]", 2)
	end
	ENV.vector = function() return setmetatable({ x = 0, y = 0, z = 0 }, VecMT) end
	ENV.GetARGB = function(a, r, g, b) return { a = a, r = r, g = g, b = b } end
	ENV.RegisterScriptCallback = function() end
	ENV.super = function() end
	ENV.CUIScriptWnd = {}
	ENV.class = function(name)
		return function(base)
			local c = {}
			for k, v in pairs(base or {}) do c[k] = v end
			c.__index = c
			ENV[name] = setmetatable(c, { __call = function(cls) return setmetatable({}, cls) end })
			return ENV[name]
		end
	end

	-- THE CLOCK. iqm_core binds `time_global` as a file local from the global at parse
	-- time (iqm_core.script:729), so a closure installed here before the chunk runs is the
	-- clock the throttle reads -- no upvalue surgery needed for this half.
	local CLOCK = 10000
	ENV.time_global = function() return CLOCK end

	-- THE WORK COUNTER. get_task_manager is called exactly once per real resolve
	-- (active_task_target's first line) and never on the cached path, so counting it counts
	-- resolves. TASKS is the live task list; SEL says which one the player has selected.
	local WORK, TASKS, SEL = 0, {}, {}
	ENV.task_manager = {
		get_task_manager = function()
			WORK = WORK + 1
			return { task_info = TASKS }
		end,
	}

	-- Positions are plain tables, not ENV.vector: route_target measures with
	-- distance_to_sqr and nothing here compares two of them.
	local function pt(x, z)
		return { x = x, y = 0, z = z,
			distance_to_sqr = function(self, o)
				local dx, dz = self.x - o.x, self.z - o.z
				return dx * dx + dz * dz
			end }
	end

	ENV.db = { actor = {
		position = function() return pt(0, 0) end,
		is_active_task = function(_, t) return SEL[t] == true end,
	} }
	ENV.IsStalker = function() return true end
	ENV.IsMonster = function() return false end

	-- OFFLINE objects, which is what a task marker halfway across the level usually is:
	-- get_obj answers nil and goal_pos falls through to alife(). No m_game_vertex_id, so
	-- the game_graph level test is skipped -- it is not what this section is about.
	local SE = {}
	local ALIFE_HITS = 0
	ENV.alife = function()
		return { object = function(_, id) ALIFE_HITS = ALIFE_HITS + 1; return SE[id] end }
	end
	ENV.level = { name = function() return "l01_escape" end }

	-- ONLINE objects, for the `tracked` fallback path (route_target's nearest "target").
	local WORLD = {}
	local function online_obj(x, z, lvid)
		local p = pt(x, z)
		return { position = function() return p end,
		         alive = function() return true end,
		         level_vertex_id = function() return lvid end }
	end

	local CORE = setmetatable({}, { __index = ENV })
	do
		local chunk, err = loadstring(slurp("gamedata/scripts/iqm_core.script"),
			"@iqm_core.script")
		assert(chunk, err)
		setfenv(chunk, CORE)
		local ok, perr = pcall(chunk)
		assert(ok, "iqm_core failed to parse: " .. tostring(perr))
	end

	-- ------------------------------------------------ reaching the file locals
	local function upget(fn, name)
		for i = 1, 80 do
			local n, v = debug.getupvalue(fn, i)
			if not n then return nil end
			if n == name then return v, i end
		end
	end
	local function upset(fn, name, val)
		local _, i = upget(fn, name)
		if not i then return false end
		debug.setupvalue(fn, i, val)
		return true
	end
	-- ...and down through the ones that are only reachable via another local. ensure_entry
	-- is a local of the chunk captured by `update`, which is captured by `actor_on_update`,
	-- which on_game_start hands to RegisterScriptCallback.
	local function climb(fn, ...)
		for _, name in ipairs({ ... }) do
			if type(fn) ~= "function" then return nil end
			fn = upget(fn, name)
		end
		return fn
	end

	check("route_goal is public", type(CORE.route_goal) == "function")
	check("route_goal_reset is exported, not a file local", type(CORE.route_goal_reset) == "function",
	      "a hook nothing outside the function can call is not an invalidation hook")

	local C = upget(CORE.route_target, "C")
	local tracked = upget(CORE.route_target, "tracked")
	check("iqm_core's C and tracked are reachable", type(C) == "table" and type(tracked) == "table")
	-- get_obj is nil until on_game_start binds level.object_by_id; goal_pos CALLS it, so
	-- the harness binds it here. Shared upvalue, so setting it through goal_pos sets it
	-- for route_target too.
	check("get_obj bound into the module",
	      upset(CORE.goal_pos, "get_obj", function(id) return WORLD[id] end))
	C.enabled, C.mark_targets = true, true

	local ensure_entry = climb(CORE.on_game_start, "actor_on_update", "update", "ensure_entry")
	check("the real ensure_entry is reachable", type(ensure_entry) == "function",
	      "without it the tracked-set hook can only be grepped, not driven")

	local TTL = upget(CORE.route_goal_reset, "GOALC")
	TTL = TTL and TTL.ttl
	check("the throttle window is declared on GOALC", type(TTL) == "number" and TTL > 0,
	      tostring(TTL))
	-- The window has to be short enough that iqm_nav's own repath rules cannot notice it:
	-- REPATH_MIN is how often it is allowed to re-search at all.
	local REPATH_MIN = tonumber(slurp("gamedata/scripts/iqm_nav.script")
		:match("\nlocal REPATH_MIN%s*=%s*(%d+)"))
	check("...and is well inside iqm_nav's repath cooldown", REPATH_MIN and TTL and TTL < REPATH_MIN,
	      string.format("ttl %s vs REPATH_MIN %s", tostring(TTL), tostring(REPATH_MIN)))

	local function reset_world()
		TASKS, SEL, SE, WORLD = {}, {}, {}, {}
		for id in pairs(tracked) do tracked[id] = nil end
		ENV.task_manager.get_task_manager = function()
			WORK = WORK + 1
			return { task_info = TASKS }
		end
		CORE.route_goal_reset()
		WORK, ALIFE_HITS = 0, 0
	end
	-- A selected task whose marker sits on an offline object at (x, z).
	local function select_task(name, target_id, x, z)
		TASKS[name] = { t = name, current_target = target_id }
		SEL[name] = true
		SE[target_id] = { position = pt(x, z), m_level_vertex_id = 900 + target_id }
	end

	-- ---------------------------------------------- 6a. a repeat does no work
	reset_world()
	select_task("task_a", 1001, 30, 40)
	local id1, pos1 = CORE.route_goal()
	check("route_goal resolves the selected task's target", id1 == 1001 and pos1 and pos1.x == 30,
	      tostring(id1))
	local after_first, alife_first = WORK, ALIFE_HITS
	check("...and that cost exactly one resolve", after_first == 1, tostring(after_first))

	-- Every frame of a 200 ms window at 60 fps, plus the boundary frame itself.
	for _ = 1, 12 do CLOCK = CLOCK + 16; CORE.route_goal() end
	check("twelve more frames inside the window do NO further work", WORK == after_first,
	      string.format("%d resolves, expected %d", WORK, after_first))
	check("...and no further alife lookups either", ALIFE_HITS == alife_first,
	      string.format("%d vs %d", ALIFE_HITS, alife_first))
	local id2, pos2, online2, lvid2 = CORE.route_goal()
	check("...and the cached tuple keeps its shape and arity",
	      id2 == 1001 and pos2 == pos1 and online2 == false and lvid2 == 1901,
	      string.format("%s/%s/%s", tostring(id2), tostring(online2), tostring(lvid2)))

	-- ------------------------------------------- 6b. the window does expire
	-- The target moves while the cache holds. Inside the window the OLD position is
	-- served -- that is the trade, and it is under GOAL_TOL at any walking pace -- and
	-- past it the new one arrives without anyone having to ask.
	SE[1001].position = pt(35, 44)
	local _, held = CORE.route_goal()
	check("a moved target is not seen inside the window", held.x == 30, tostring(held.x))
	CLOCK = CLOCK + TTL
	local _, fresh = CORE.route_goal()
	check("...and IS seen once the window expires", fresh.x == 35, tostring(fresh.x))
	check("...which took exactly one more resolve", WORK == after_first + 1, tostring(WORK))

	-- A clock that jumps BACKWARDS (a load, another harness's stub) must re-resolve
	-- rather than serve the cache until real time catches up.
	local before_back = WORK
	CLOCK = CLOCK - 5000
	CORE.route_goal()
	check("a clock that went backwards re-resolves", WORK == before_back + 1, tostring(WORK))

	-- ------------------------------- 6c. an objective CHANGE beats the timer
	-- The tracked-set hook. A new objective NPC appearing must be routed to on the next
	-- frame, not at the end of a window the player cannot see -- and the case that makes
	-- this matter is the one where the cached answer is nil, because a cached nil that
	-- only the timer can clear is a quest that silently does not draw.
	reset_world()
	local none = CORE.route_goal()
	check("no objective resolves to nil", none == nil)
	local nil_work = WORK
	CLOCK = CLOCK + 16
	CORE.route_goal()
	check("...and the nil is CACHED, like any other answer", WORK == nil_work,
	      "re-walking task_info to find nothing again is the expensive case, not the cheap one")

	-- ...now one appears, through the module's own writer of `tracked`.
	WORLD[2002] = online_obj(12, 9, 77)
	ensure_entry(2002, "target")
	CLOCK = CLOCK + 16                       -- next frame, far inside the window
	local nid, npos, nonline, nlvid = CORE.route_goal()
	check("a newly-tracked objective is picked up on the NEXT frame, not at the window's end",
	      nid == 2002 and npos and npos.x == 12,
	      tostring(nid) .. " (a cached nil held it out)")
	check("...with the online flag and vertex the fresh resolve found",
	      nonline == true and nlvid == 77,
	      string.format("%s/%s", tostring(nonline), tostring(nlvid)))

	-- A ROLE CHANGE on an id already tracked is the same event wearing a different hat:
	-- the fallback only picks "target", so demoting the one it picked changes the answer
	-- without adding or removing anything.
	CLOCK = CLOCK + 16
	ensure_entry(2002, "trader")
	CLOCK = CLOCK + 16
	check("a role change on a tracked id re-resolves too", CORE.route_goal() == nil,
	      "the demoted NPC is still being routed to")

	-- ...and a re-assertion of the SAME role must NOT reset, or the scan pass that
	-- re-asserts every carded NPC would clear the cache several times a second and the
	-- throttle would be worth nothing.
	ensure_entry(2002, "trader")
	ensure_entry(2002, "trader")
	local steady = WORK
	CLOCK = CLOCK + 16
	CORE.route_goal()
	check("re-asserting an unchanged role does NOT reset the cache", WORK == steady,
	      "every scan pass would clear it")

	-- The explicit hook, on its own: this is what the level-change and option-change
	-- callbacks lean on.
	reset_world()
	select_task("task_b", 3003, 5, 5)
	CORE.route_goal()
	local pre = WORK
	CLOCK = CLOCK + 16
	CORE.route_goal_reset()
	local rid = CORE.route_goal()
	check("route_goal_reset forces a resolve inside the window",
	      WORK == pre + 1 and rid == 3003, string.format("%d -> %d", pre, WORK))

	-- ------------------------------------------------ 6d. the wiring, in the source
	-- The behaviour above is driven through ensure_entry and the exported hook. The
	-- REMAINING call sites are callbacks the harness cannot fire, so they are read.
	local core_src = slurp("gamedata/scripts/iqm_core.script")
	check("clear_all drops the cached goal",
	      core_src:match("local function clear_all.-\nend"):find("route_goal_reset()", 1, true) ~= nil)
	check("remove_entry drops it as well",
	      core_src:match("local function remove_entry.-\nend"):find("route_goal_reset()", 1, true) ~= nil)
	check("a level change drops it",
	      core_src:find('RegisterScriptCallback("on_level_changing", route_goal_reset)', 1, true) ~= nil,
	      "goal_pos's answers are level-relative; a cached position outlives its level")
	check("...and so does an option change",
	      core_src:match("function on_option_change.-\nend"):find("route_goal_reset()", 1, true) ~= nil,
	      "enabled / mark_targets gate route_target outright")

	-- =====================================================================
	-- 7. goal_pos's OFFLINE cache, RUN against the same clock
	-- =====================================================================
	-- WHY THIS IS DRIVEN TOO, and why it is a separate section from route_goal's throttle.
	-- goal_pos has THREE callers and only one of them (route_goal, above) was throttled.
	-- iqm_beacon.waypoint_goal and iqm_beacon.task_goal both throttle the ID they ask
	-- about to 4 Hz and then ask goal_pos for the POSITION on every single frame -- which
	-- is cheap while the object is online and is eight engine round-trips and four
	-- allocations while it is not, and OFFLINE is the normal state of both a waypoint
	-- dropped across the map and a hand-in target. So the offline half is now cached and
	-- the online half is deliberately not.
	--
	-- That split is the entire behaviour, and none of it is visible in the text of the
	-- function: a cache that also swallowed the online branch would drag a marker behind
	-- a moving quest giver, a cache that outlived a level change would point at a
	-- position on the level you just left, and a cached nil that nothing clears is a
	-- quest that silently never draws. So the crossings are COUNTED (alife(),
	-- game_graph(), level.name(), each through its own stub) and the transitions are
	-- walked frame by frame.
	local GG_HITS, LNAME_HITS = 0, 0
	local CURLVL = "l01_escape"
	ENV.level = { name = function() LNAME_HITS = LNAME_HITS + 1; return CURLVL end }

	local GG_LEVEL = {}                       -- game vertex id -> level id
	ENV.game_graph = function()
		GG_HITS = GG_HITS + 1
		return { vertex = function(_, gvid)
			return { level_id = function() return GG_LEVEL[gvid] or 1 end }
		end }
	end
	local LEVEL_OF = { [1] = "l01_escape", [2] = "l02_garbage" }
	-- Same object counter as section 6, now with the level_name the game_graph test
	-- needs. Section 6's simulator had none, so its `sim.level_name and ...` clause
	-- short-circuited and the level test never ran there; here it must.
	ENV.alife = function()
		return { object     = function(_, id) ALIFE_HITS = ALIFE_HITS + 1; return SE[id] end,
		         level_name = function(_, lid) return LEVEL_OF[lid] end }
	end

	local OFFC = upget(CORE.goal_pos, "OFFC")
	check("the offline cache is a file local of goal_pos, not of a caller",
	      type(OFFC) == "table" and type(OFFC.ttl) == "number" and type(OFFC.e) == "table",
	      "caching in one caller would let the route and the marker disagree about one id")
	local OTTL = OFFC and OFFC.ttl or 250
	-- It exists to make the callers' per-frame position ask cost what their per-frame id
	-- ask already costs, so the two windows have to be the same window.
	local wp_poll = tonumber(slurp("gamedata/scripts/iqm_beacon.script")
		:match("_wp%.t%s*=%s*tg%s*%+%s*(%d+)"))
	check("the offline tick matches iqm_beacon's id poll", wp_poll == OTTL,
	      string.format("ttl %s vs waypoint poll %s", tostring(OTTL), tostring(wp_poll)))

	-- --------------------------------- 7a. once per tick, not once per frame
	reset_world()
	GG_HITS, LNAME_HITS = 0, 0
	SE[4001] = { position = pt(100, 200), m_level_vertex_id = 555, m_game_vertex_id = 7 }
	GG_LEVEL[7] = 1                                        -- same level as the actor
	local p1, on1, lv1 = CORE.goal_pos(4001)
	check("an offline target resolves to position/false/vertex",
	      p1 and p1.x == 100 and on1 == false and lv1 == 555,
	      string.format("%s/%s", tostring(on1), tostring(lv1)))
	check("...at one alife lookup, one game_graph and one level.name",
	      ALIFE_HITS == 1 and GG_HITS == 1 and LNAME_HITS == 1,
	      string.format("%d/%d/%d", ALIFE_HITS, GG_HITS, LNAME_HITS))

	for _ = 1, 12 do CLOCK = CLOCK + 16; CORE.goal_pos(4001) end   -- 192 ms of frames
	check("twelve more frames inside the tick cross into the engine NOT ONCE",
	      ALIFE_HITS == 1 and GG_HITS == 1 and LNAME_HITS == 1,
	      string.format("%d/%d/%d", ALIFE_HITS, GG_HITS, LNAME_HITS))
	local p2, on2, lv2 = CORE.goal_pos(4001)
	check("...and ALL THREE returns survive the cache, at the same arity",
	      p2 == p1 and on2 == false and lv2 == 555,
	      "iqm_nav's mesh_goal falls back on the third one when the position is off-mesh")

	-- The tick expiring re-reads the POSITION -- but not the level test, which cannot
	-- have changed while m_game_vertex_id has not.
	SE[4001].position = pt(101, 201)
	CLOCK = CLOCK + OTTL
	local p3 = CORE.goal_pos(4001)
	check("the tick expiring re-reads the alife position",
	      p3 and p3.x == 101 and ALIFE_HITS == 2, tostring(p3 and p3.x))
	check("...but NOT game_graph or level.name, keyed on an unchanged game vertex",
	      GG_HITS == 1 and LNAME_HITS == 1,
	      string.format("%d/%d -- the level test is being redone for nothing", GG_HITS, LNAME_HITS))
	SE[4001].m_game_vertex_id = 9
	GG_LEVEL[9] = 1
	CLOCK = CLOCK + OTTL
	CORE.goal_pos(4001)
	check("a CHANGED game vertex does re-test the level", GG_HITS == 2, tostring(GG_HITS))
	check("...and still not level.name(), which only a level change can invalidate",
	      LNAME_HITS == 1, tostring(LNAME_HITS))

	-- ------------------------------- 7b. the ONLINE branch is not cached
	-- The case the cache must not swallow: PAW allows a waypoint placed on an NPC, and
	-- that NPC walks. Online is one object_by_id and one position() -- cheap, and live.
	reset_world()
	GG_HITS, LNAME_HITS = 0, 0
	local walker = { x = 0 }
	WORLD[5005] = { position        = function() return pt(walker.x, 0) end,
	                alive           = function() return true end,
	                level_vertex_id = function() return 42 end }
	for i = 1, 6 do
		walker.x = i
		CLOCK = CLOCK + 16                              -- every frame, deep inside a tick
		local q, qon, qlv = CORE.goal_pos(5005)
		check("a moving online target is live on frame " .. i,
		      q and q.x == i and qon == true and qlv == 42,
		      string.format("%s at %s", tostring(qon), tostring(q and q.x)))
	end
	check("...and the online branch never touched alife or game_graph",
	      ALIFE_HITS == 0 and GG_HITS == 0,
	      string.format("%d/%d", ALIFE_HITS, GG_HITS))

	-- ------------------------------ 7c. the negative answers, and the level change
	reset_world()
	GG_HITS, LNAME_HITS = 0, 0
	check("an id with no alife object answers nil", CORE.goal_pos(6006) == nil)
	check("...having paid one lookup to find that out", ALIFE_HITS == 1, tostring(ALIFE_HITS))
	CLOCK = CLOCK + 16
	check("...and that nil is CACHED like any other answer",
	      CORE.goal_pos(6006) == nil and ALIFE_HITS == 1,
	      "reaching 'no such object' is the expensive case, not the cheap one")
	CLOCK = CLOCK + OTTL
	CORE.goal_pos(6006)
	check("...but only for a tick", ALIFE_HITS == 2, tostring(ALIFE_HITS))

	-- "on another level" is the other expensive nil, and the one a stale cache would get
	-- catastrophically wrong: the level it was cached ON is the thing that changed.
	SE[6007] = { position = pt(1, 2), m_level_vertex_id = 3, m_game_vertex_id = 21 }
	GG_LEVEL[21] = 2                                        -- l02_garbage; actor is on l01
	ALIFE_HITS, GG_HITS = 0, 0
	check("a target on ANOTHER level answers nil", CORE.goal_pos(6007) == nil)
	CLOCK = CLOCK + 16
	check("...and that nil is cached too",
	      CORE.goal_pos(6007) == nil and ALIFE_HITS == 1 and GG_HITS == 1,
	      string.format("%d/%d", ALIFE_HITS, GG_HITS))

	local lname_pre = LNAME_HITS
	CURLVL = "l02_garbage"                                  -- the player walks the transition
	CORE.route_goal_reset()                                 -- what on_level_changing calls
	check("route_goal_reset empties the offline cache outright", next(OFFC.e) == nil,
	      "a cached position belongs to the level it was read on")
	CLOCK = CLOCK + 16                                      -- the very next frame
	local lp, lon, llv = CORE.goal_pos(6007)
	check("a level change drops the cached nil on the NEXT frame, not at the tick's end",
	      lp and lp.x == 1 and lon == false and llv == 3, tostring(lp))
	check("...and the remembered level name was re-read with it", LNAME_HITS > lname_pre,
	      "level.name() is cached to the level change, so the change must clear it")

	-- ---------------------- 7d. offline -> online is picked up, then served live
	reset_world()
	CURLVL = "l01_escape"
	CORE.route_goal_reset()
	SE[7007] = { position = pt(50, 60), m_level_vertex_id = 111, m_game_vertex_id = 7 }
	local fp, fon = CORE.goal_pos(7007)
	check("the target starts offline", fp and fp.x == 50 and fon == false, tostring(fon))
	-- ...and now the actor walks into range of it, mid-tick.
	local risen = { x = 51 }
	WORLD[7007] = { position        = function() return pt(risen.x, 61) end,
	                alive           = function() return true end,
	                level_vertex_id = function() return 222 end }
	CLOCK = CLOCK + 16                                      -- deep inside the offline tick
	local op, oon, olv = CORE.goal_pos(7007)
	check("an object COMING ONLINE is picked up at once, not at the tick's end",
	      op and op.x == 51 and oon == true and olv == 222,
	      string.format("%s at %s -- the stale offline answer was served", tostring(oon), tostring(op and op.x)))
	local hits_at_online = ALIFE_HITS
	for i = 1, 4 do
		risen.x = 60 + i
		CLOCK = CLOCK + 16
		local q, qon = CORE.goal_pos(7007)
		check("...and is served LIVE from then on, frame " .. i,
		      q and q.x == 60 + i and qon == true, tostring(q and q.x))
	end
	check("...without ever falling back into alife again", ALIFE_HITS == hits_at_online,
	      string.format("%d vs %d", ALIFE_HITS, hits_at_online))

	-- A dead creature is nil on the ONLINE branch, and that nil must not be answered out
	-- of the offline entry this id still has sitting in the cache from before it rose.
	WORLD[7007].alive = function() return false end
	CLOCK = CLOCK + 16
	check("a dead online creature is nil, not its stale offline position",
	      CORE.goal_pos(7007) == nil)
end

-- ------------------------------------------------------------------ verdict
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
