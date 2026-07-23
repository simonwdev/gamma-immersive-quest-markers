-- Harness: reproduce the iqm_taskwork cold-probe pipeline outside the game.
-- Stubs the engine API, loads the REAL gamedata/scripts/iqm_taskwork.script
-- and a 1:1 transcription of the GAMMA monkey-patched get_first_available_task
-- (Tasks QoL Pack), then drives scan passes + probe ticks over simulated time
-- and reports each NPC's verdict.
--
-- Usage (from anywhere; paths resolve relative to this file):
--   luajit tools/taskwork-harness/harness.lua vanilla   # working dialog cache (base Anomaly)
--   luajit tools/taskwork-harness/harness.lua gamma     # broken monkey -> taskboard-generator path
--   SLOW_PROBE=1 luajit ... gamma                       # simulate ~10ms probes (adaptive interval)
--
-- Expected: every scenario ends with work verdicts matching the comments at
-- the NPC definitions, zero generator calls after verdicts cache (no re-probe
-- loop), and zero generator calls for ah_sarik (named, familyless NPCs are
-- never sim-rolled).

local sim_ms = 1000          -- time_global() milliseconds
local sim_gs = 0             -- game-time seconds

-- ---------------------------------------------------------------- CTime stub
local CTimeMT = {}
CTimeMT.__index = CTimeMT
function CTimeMT:diffSec(other) return self.t - other.t end
local function ctime(t) return setmetatable({ t = t }, CTimeMT) end

-- ---------------------------------------------------------------- engine env
local ENV = {}   -- the "global namespace" both loaded scripts see

ENV.pairs, ENV.ipairs, ENV.tostring, ENV.tonumber = pairs, ipairs, tostring, tonumber
ENV.type, ENV.string, ENV.table, ENV.math, ENV.os = type, string, table, math, os
ENV.setmetatable, ENV.print, ENV.pcall, ENV.select = setmetatable, print, pcall, select
ENV._G = ENV

ENV.printf = function(fmt, ...) print(string.format(fmt, ...)) end
ENV.time_global = function() return sim_ms end
ENV.device = function() return { time_global = function() return sim_ms end } end
ENV.starts_with = function(s, prefix) return string.sub(s, 1, #prefix) == prefix end
ENV.character_community = function(npc) return "stalker" end
ENV.parse_list = function(ini, sec, field, as_set) return { stalker = true } end

ENV.game = {
	get_game_time = function() return ctime(sim_gs) end,
	translate_string = function(s) return s end,
}

-- pstor on the actor
local pstor = {}
ENV.save_var   = function(actor, k, v) pstor[k] = v end
ENV.load_var   = function(actor, k, d) local v = pstor[k]; if v == nil then return d end; return v end
ENV.save_ctime = function(actor, k, v) pstor[k] = v end
ENV.load_ctime = function(actor, k) return pstor[k] end

-- NPCs
local npcs = {}
local function make_npc(id, sec, dist)
	local npc
	npc = {
		_id = id, _sec = sec, _dist = dist,
		id = function(self) return self._id end,
		section = function(self) return self._sec end,
		name = function(self) return self._sec .. "_name" end,
		alive = function(self) return true end,
		position = function(self)
			return { distance_to_sqr = function(_, other) return npc._dist * npc._dist end }
		end,
	}
	npcs[id] = npc
	return npc
end

ENV.db = {
	actor = {
		position = function() return { } end,
		get_task = function(self, tid, x) return true end,
	},
	storage = {},
}
ENV.level = { object_by_id = function(id) return npcs[id] end }

ENV.xr_conditions = {
	has_completed_task_prerequisites = function(a, b, p)
		assert(p and p[1], "prereq called with no task id")
		return true
	end,
}

ENV.task_manager = {
	get_task_manager = function() return { task_info = {} } end,
	task_ini = { r_string_ex = function(self, sec, field) return nil end },
}

ENV.dialogs = { get_npc_task_limit = function() return 2 end }
ENV.blacklist_helper = { TaskBlacklist = {} }

-- axr_task_manager namespace with the REAL monkey get_first_available_task
-- (transcribed 1:1 from 463- Tasks QoL Pack, bare globals resolved via ENV)
ENV.axr_task_manager = {
	CFG_CACHE = {
		simulation_task_1 = true,
		simulation_task_2 = true,
		bar_visitors_barman_task_1 = true,   -- a dedicated family for the "ordered" case (npc 103)
	},
	skipped_tasks = {},
}

local RNG_ROLL = 50   -- math.random(100) result: <= 75 means "has task to give"
local monkey_env = setmetatable({
	math = { randomseed = function() end, random = function(n) if n == 100 then return RNG_ROLL end return 1 end },
}, { __index = ENV })

local monkey = loadstring([==[
function axr_task_manager.get_first_available_task(npc, skip, is_sim)
	local tm = task_manager.get_task_manager( )
	local task_info = tm.task_info
	local npc_stored_task = load_var( db.actor, ("drx_sl_npc_stored_task_" .. npc:id( )), nil )
	local time_last_checked = load_ctime( db.actor, ("drx_sl_npc_stored_task_time_" .. npc:id( )) )
	if ( time_last_checked and game.get_game_time( ):diffSec( time_last_checked ) < 5400 ) then
		if ( not npc_stored_task or blacklist_helper.TaskBlacklist[npc_stored_task[1]] ) then
			return
		elseif ( task_info[npc_stored_task] == nil and xr_conditions.has_completed_task_prerequisites( nil, nil, {npc_stored_task} ) ) then
			return npc_stored_task
		else
			return
		end
	end
	math.randomseed( device( ):time_global( ) )
	if ( math.random( 100 ) > 75 ) then
		save_var( db.actor, ("drx_sl_npc_stored_task_" .. npc:id( )), nil )
		save_ctime( db.actor, ("drx_sl_npc_stored_task_time_" .. npc:id( )), game.get_game_time( ) )
		return
	end
	local sec
	local st = db.storage[npc:id( )]
	if ( st and st.ini and st.section_logic ) then
		sec = st.ini:r_string_ex( st.section_logic, "task_section" )
		if ( sec ) then
			sec = (sec .. "_task_")
		end
	end
	if not ( sec ) then
		sec = (is_sim and "simulation_task_" or npc:section( ) ~= "m_trader" and (npc:section( ) .. "_task_") or (npc:name( ) .. "_task_"))
	end
	local npc_task_list = {}
	local size_t = 0
	for task_id in pairs(axr_task_manager.CFG_CACHE) do
		if starts_with(task_id, sec) then
			if ( axr_task_manager.skipped_tasks[task_id] ~= true and task_info[task_id] == nil and xr_conditions.has_completed_task_prerequisites( nil, nil, {task_id} ) ) then
				if ( skip ) then
					axr_task_manager.skipped_tasks[task_id] = true
					return
				else
					if ( is_sim ) then
						local p = parse_list( task_manager.task_ini, task_id, "sim_communities", true )
						if ( p[character_community( npc )] == true ) then
							size_t = size_t + 1
							npc_task_list[size_t] = task_id
						end
					else
						size_t = size_t + 1
						npc_task_list[size_t] = task_id
					end
				end
			end
		end
	end
	local new_task
	if ( #npc_task_list > 0 ) then
		new_task = npc_task_list[math.random( #npc_task_list )]
	end
	save_var( db.actor, ("drx_sl_npc_stored_task_" .. npc:id( )), new_task )
	save_ctime( db.actor, ("drx_sl_npc_stored_task_time_" .. npc:id( )), game.get_game_time( ) )
	return new_task
end
]==])
setfenv(monkey, monkey_env)
monkey()

-- ------------------------------------------------------- load iqm_taskwork
-- resolve relative to this file: <repo>/tools/taskwork-harness/harness.lua
local here = arg and arg[0] and arg[0]:gsub("[^/\\]+$", "") or ""
local path = here .. "../../gamedata/scripts/iqm_taskwork.script"
local f = io.open(path, "r")
if not f then error("cannot open " .. path .. " -- run via: luajit tools/taskwork-harness/harness.lua") end
local src = f:read("*a")
f:close()

local tw_env = setmetatable({}, { __index = ENV })
local chunk, err = loadstring(src, "@iqm_taskwork.script")
assert(chunk, err)
setfenv(chunk, tw_env)
chunk()
ENV.iqm_taskwork = tw_env   -- visible as a "script namespace"

-- ------------------------------------------------------------------- drive
make_npc(101, "sim_default_stalker_2", 5)   -- plain sim stalker, 5 m away
make_npc(102, "sim_default_bandit_1", 8)
make_npc(103, "bar_visitors_barman",  6)    -- has a dedicated task family
make_npc(104, "ah_sarik",             7)    -- named story NPC: no family, no sim pool -> must stay card-less

tw_env.configure(true, 16, true)   -- probing on, 16 m, debug on

local function scan_pass(label)
	print(("--- %s (tg=%d ms, gt=%d s) ---"):format(label, sim_ms, sim_gs))
	for _, id in ipairs({ 101, 102, 103, 104 }) do
		local w = tw_env.has_work(id, npcs[id], false)
		print(("has_work(%d) -> %s   kind=%s"):format(id, tostring(w), tostring(tw_env.work_kind(id))))
	end
end

local function advance(ms)
	local step = 16
	local target = sim_ms + ms
	while sim_ms < target do
		sim_ms = sim_ms + step
		sim_gs = sim_gs + (step / 1000) * 10   -- x10 game-time factor
		tw_env.probe_tick(sim_ms, true)        -- every frame, idle
	end
end

local MODE = arg and arg[1] or "vanilla"
if MODE == "gamma" then
	-- Reproduce GAMMA: the QoL monkey's cold path throws (bare CFG_CACHE is nil
	-- in its namespace), and work offers flow through the taskboard generator.
	local real_gfat = ENV.axr_task_manager.get_first_available_task
	ENV.axr_task_manager.get_first_available_task = function(npc, skip, is_sim)
		-- warm branch still works (it never touches CFG_CACHE)
		local t = pstor["drx_sl_npc_stored_task_time_" .. npc:id()]
		if t and (sim_gs - t.t) < 5400 then return real_gfat(npc, skip, is_sim) end
		error("monkey_axr_task_manager.script:49: bad argument #1 to 'pairs' (table expected, got nil)")
	end
	local probe_calls, calls_by_id = 0, {}
	ENV.axr_task_manager.available_tasks = {}
	ENV.axr_task_manager.generate_available_tasks = function(npc, is_sim)
		if os.getenv("SLOW_PROBE") then                 -- simulate a weak CPU: ~10ms per task walk
			local t0 = os.clock(); while (os.clock() - t0) < 0.010 do end
		end
		probe_calls = probe_calls + 1
		local id = npc:id()
		calls_by_id[id] = (calls_by_id[id] or 0) + 1
		local avail = ENV.axr_task_manager.available_tasks
		avail[id] = {}
		local st = ENV.db.storage[id] or {}
		ENV.db.storage[id] = st
		if is_sim then
			if st.dyn_quest_rand == nil then
				st.dyn_quest_rand = (id % 2 == 0) and "simulation_task_1" or "nil"  -- half get work, half rolled "no quests"
			end
			if st.dyn_quest_rand ~= "nil" then avail[id][1] = st.dyn_quest_rand end
		else
			if id == 103 then avail[id][1] = "bar_visitors_barman_task_1" end   -- the dedicated-family NPC
		end
	end
	ENV.get_probe_calls = function() return probe_calls end
	ENV.get_calls_for = function(id) return calls_by_id[id] or 0 end
end

scan_pass("pass 1: everything cold")
advance(2000)
scan_pass("pass 2: after 2 s of probe ticks")
advance(2000)
scan_pass("pass 3: after 4 s")
if MODE == "gamma" then
	local before = ENV.get_probe_calls()
	advance(10000)   -- ten more seconds: verdicts are cached, queue must stay dry
	scan_pass("pass 4: after 14 s")
	advance(2000)
	print(("generator calls in the last 12 s: %d (0 = no re-probe loop)"):format(ENV.get_probe_calls() - before))
	print(("generator calls for ah_sarik: %d (0 = named no-family NPC never sim-rolled)"):format(ENV.get_calls_for(104)))
else
	print("--- pstor ---")
	for k, v in pairs(pstor) do print(k, type(v) == "table" and ("ctime(" .. v.t .. ")") or tostring(v)) end
end
