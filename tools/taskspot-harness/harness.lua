-- Harness: the task-KIND map spots (R2.48).
--
-- WHY THIS EXISTS. This is the first thing the mod does that WRITES INTO THE SAVE.
-- A task's map location type is a string the engine serialises (SLocationKey::save,
-- map_manager.cpp:62) and rebuilds through CMapLocation's constructor on load, which
-- R_ASSERTs on a type map_spots.xml does not declare (map_location.cpp:105) -- an engine
-- fatal that no pcall catches. Everything else in this mod fails soft; this can leave a
-- save that will not open. So the rules about WHEN a type name may be handed out are
-- worth more than a comment, and they are what most of this file checks.
--
-- What it checks:
--   1. THE OWNERSHIP GUARD. A task's spot is touched only when it currently carries the
--      type the task itself declares, or one of ours. Another mod's type is left alone.
--      Without this the very first pass would overwrite ATUE's return-task marker.
--   2. THE DECLARED GATE. With the DXML splice absent -- an install without the modded
--      exes' DXML support -- no IQM type name is ever passed to change_map_location.
--      That is the difference between "vanilla icons" and a CTD.
--   3. THE REVERT. Switching the feature off, or the mod off, puts every task still
--      wearing one of ours back onto its own type. Not merely "stops applying new ones":
--      a save full of iqm_task_* types is the hazard above, so ceasing quietly is the
--      one behaviour that is not allowed.
--   4. IDEMPOTENCE. A settled pass issues no calls at all, in every configuration. This
--      runs at 1.3 Hz forever, and change_map_location is remove-then-recreate.
--   5. THE HAND-IN GATE. task_kind goes nil once the objective is done, so a finished
--      bounty is back on the ordinary marker before the player walks to the giver.
--   6. THE CLASSIFIER. bounty from the registry, mutant from the squad community OR from
--      the target's own creature class, the rescue/defend families and the Top 10 from
--      what the section
--      DECLARES -- and the ordering that makes the last of those admissible, since a
--      declared-functor list may only add a kind after every state test has said no.
--   7. THE SOURCE. The guards, the gate and the option wiring read back out of the real
--      files, since 1-6 only prove the model.
--
-- Usage:
--   python check_lua.py --run tools/taskspot-harness/harness.lua
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
	local s = f:read("*a") f:close() return s
end

-- One string across the four files this rule spans, for the reason the waypoint harness
-- reads four: the CLASSIFIER is iqm_scan's, the SWAP is iqm_taskspot's, the OPTIONS are
-- iqm_core's and the TYPE DECLARATIONS are the modxml's. Grepping one for another's half
-- passes vacuously.
local spot_src  = slurp("gamedata/scripts/iqm_taskspot.script")
local scan_src  = slurp("gamedata/scripts/iqm_scan.script")
local core_src  = slurp("gamedata/scripts/iqm_core.script")
local modxml_src = slurp("gamedata/scripts/modxml_n_iqm_map_icons.script")
local spots_xml = slurp("gamedata/configs/ui/iqm_map_spots.xml")

-- ------------------------------------------------------- the model under test
-- iqm_taskspot.sync, reimplemented. Returns the list of change_map_location calls the
-- pass would issue, so "no calls" is an assertable outcome rather than an absence.
-- Five kinds, five types as of R2.55. `waypoint` and `open` draw the SAME hollow reticle
-- and were one type until the static_border split; they are kept apart now because that
-- border is the engine's active-task ring, and only PAW brings an animated ring of its own.
local SPOT = { mutant = "iqm_task_mutant", bounty = "iqm_task_bounty",
               delivery = "iqm_task_delivery", handin = "iqm_task_handin",
               waypoint = "iqm_task_waypoint", open = "iqm_task_open" }
local OURS = {}
for _, v in pairs(SPOT) do OURS[v] = true end

-- iqm_scan.task_kind, reimplemented against a fake world.
--   world.bounties : task_id -> npc_id  (axr_task_manager.bounties_by_id)
--   world.squads   : object_id -> community
--   world.monsters : community -> true  (is_squad_monster)
--   world.beasts   : object_id -> true  (IsMonster on the target's own clsid)
--   world.vars     : task_id -> { smart_id, squad_id }  (load_var on the actor)
--   world.ini      : task_id -> { status =, target = }  (task_manager.task_ini)
local STATUS_KIND = { hostage_task = "bounty", delivery_task = "delivery",
                      gd_task_status_functor = "bounty",
                      hold_the_ground_task_status_functor = "bounty",
                      no_step_back_task_status_functor = "bounty" }
local TARGET_KIND = { top_10_task_target_functor = "bounty",
                      nta_stash_task_target_functor = "open",
                      barrier_defense_target_functor = "bounty" }
-- R2.55b. THE ASSAULT SPECIES RULE, which replaced a LATE table that shipped broken. The
-- functor is shared by mutant hunts and faction fights alike, so the KIND comes from the
-- declared community list: monster community -> mutant, faction -> bounty. Config only, so
-- it sits with the other declarations and is safe to cache like them.
-- R2.55c. Spot types that are the TASK'S OWN presentation, not coverage. The two blinks are
-- the engine's new-task pulse: a separate map location on the same object, alive for ~15 s
-- after the task is taken, which made every fresh task look covered.
local NOT_COVER = {
	paw_task_default        = true,
	ui_storyline_task_blink = true,
	ui_secondary_task_blink = true,
}

local ASSAULT = "assault_task_status_functor"
local function assault_kind(world, ini)
	if ini.status ~= ASSAULT then return nil end
	if not world.monsters then return nil end
	local first = ini.params and tostring(ini.params):match("^%s*([%w_]+)")
	if not first then return nil end
	return world.monsters[first] and "mutant" or "bounty"
end

local function task_kind(world, t)
	if not (t and t.id) then return nil end
	-- The hand-in gate, iqm_scan.target_is_talk_to, now with iqm_scan.handin_state behind
	-- it. Two predicates, not one, and the difference is the whole point: talk_to FAILS
	-- OPEN (no stage_complete counts as talk-to, so the kind is suppressed) while
	-- handin_state FAILS CLOSED and additionally demands the marker be sitting on the
	-- GIVER. A task with no stage_complete therefore still answers nil, exactly as it did
	-- before R2.58 -- painting the "collect your pay" diamond on every task whose config we
	-- cannot read would be worse than drawing nothing.
	local function handin_state()
		if not t.stage_complete then return false end
		if not (t.stage and t.stage >= t.stage_complete) then return false end
		return t.task_giver_id ~= nil and t.current_target ~= nil
		       and t.current_target == t.task_giver_id
	end
	if not t.stage_complete then return nil end
	if t.stage ~= nil and t.stage >= t.stage_complete then
		return handin_state() and "handin" or nil
	end
	-- PAW's waypoint, answered from what is DRAWN on the target rather than from what the
	-- task is. world.spots[id] is the list level.map_get_object_spots_by_id returns; the
	-- three exclusions are the task's own spot, PAW's own highlight, and anything of ours.
	if t.id == "task_placeable_waypoint" then
		for _, sp in ipairs(t.current_target and world.spots[t.current_target] or {}) do
			if sp ~= t.spot and not NOT_COVER[sp] and not sp:find("^iqm_") then
				return "waypoint"
			end
		end
		return nil
	end
	if world.bounties[t.id] then return "bounty" end
	-- ...then what the task DECLARES, for the kinds no registry records
	local ini = world.ini[t.id]
	local declared = ini and (STATUS_KIND[ini.status] or TARGET_KIND[ini.target]
	                          or assault_kind(world, ini))
	if declared then return declared end
	-- the target itself, for a task pointing straight at a squad...
	local comm = t.current_target and world.squads[t.current_target]
	-- ...or the squad the task stored under its own id, for one pointing at a SMART
	if not (comm and world.monsters[comm]) then
		local var = world.vars[t.id]
		comm = var and var.squad_id and world.squads[var.squad_id] or nil
	end
	if comm and world.monsters[comm] then return "mutant" end
	-- ...or the target is ONE CREATURE rather than a squad of them, which is a different
	-- alife shape entirely: player_id lives on a squad, so a monster object reads as nil
	-- through the two tests above however plainly it is a mutant
	if t.current_target and world.beasts[t.current_target] then return "mutant" end
	-- LAST: nothing named the job, so ask what is already DRAWN on the target. Same query
	-- and same three exclusions as the waypoint branch above, generalised in R2.52.
	for _, sp in ipairs(t.current_target and world.spots[t.current_target] or {}) do
		if sp ~= t.spot and not NOT_COVER[sp] and not sp:find("^iqm_") then
			return "open"
		end
	end
	return nil
end

local function sync(world, cfg, tasks)
	local calls = {}
	for _, t in ipairs(tasks) do
		local base = t.spot
		if t.gt_present and base and t.current_target and t.status == "selected" then
			local cur = t.map_location
			if type(cur) == "string" and (OURS[cur] or cur == base) then
				local kind = (cfg.on and cfg.declared) and task_kind(world, t) or nil
				local want = (kind and SPOT[kind]) or base
				if want ~= cur then
					calls[#calls + 1] = { id = t.id, from = cur, to = want }
					t.map_location = want          -- the engine would; so does the model
				end
			end
		end
	end
	return calls
end

-- ------------------------------------------------------------------ the world
local WORLD = {
	bounties = { bounty_live = 700, bounty_done = 701 },
	-- 900 is a SMART TERRAIN: present as an alife object, but with no community. This is
	-- the shape that broke R2.48 -- assault_task_target_functor returns the smart, not the
	-- squad, so every "Destroy the Mutant Lair" stayed on the plain reticle.
	squads   = { [800] = "boar", [801] = "stalker", [802] = "flesh", [803] = "boar" },
	-- The REAL is_squad_monster is keyed on the seven BEHAVIOUR communities (_g.script:2293),
	-- not on species -- a monster squad's player_id is "monster_predatory_night", never
	-- "boar". The species names here predate that being understood and are kept because the
	-- squad fixtures above use them; the real communities are added alongside because the
	-- assault rule reads status_functor_params, where only the real ones ever appear.
	monsters = { boar = true, flesh = true, dog = true, snork = true,
	             monster = true, monster_predatory_day = true,
	             monster_predatory_night = true, monster_vegetarian = true,
	             monster_zombied_day = true, monster_zombied_night = true,
	             monster_special = true, zoo_monster = true },
	-- 820 is ONE CREATURE, not a squad: an alife object whose clsid is a monster class and
	-- which therefore has no player_id at all. This is the shape that made every
	-- recover-mutant-data / research-hunt / chimera-scan task wear the plain reticle.
	-- 821 is the ITEM that hunt's later stage points at - a monster's corpse device - and
	-- it must NOT read as a mutant, because collecting it is not hunting.
	beasts   = { [820] = true },
	vars     = { lair = { smart_id = 910, squad_id = 803 } },
	-- What task_manager.task_ini declares for a section, for the two kinds no runtime
	-- registry records. `snitch` is the Top 10 hit list, which keeps its own saved list of
	-- marks and never registers in bounties_by_id.
	ini      = {
		rescue = { status = "hostage_task", target = "simulation_task_target" },
		-- R2.55. The defend family, and the PAIR that matters is the last two: both declare
		-- the SAME assault status functor, and one of them points at a mutant squad. They
		-- exist to prove the late table cannot outrank the mutant tests.
		-- THE ASSAULT PAIR, and it is the most important fixture in this file. Both declare
		-- the SAME status functor and differ only in the community list -- which is exactly
		-- the case R2.55 got wrong by treating the functor itself as the answer.
		defend  = { status = "assault_task_status_functor", target = "assault_task_target_functor",
		            params = "killer, bandit" },                       -- Defend Rostok
		mutdef  = { status = "assault_task_status_functor", target = "assault_task_target_functor",
		            params = "monster, monster_predatory_day, monster_special" },  -- Destroy the Mutants
		-- ...and one with the list missing entirely, which must answer NOTHING rather than
		-- guessing. An assault section with no params is malformed; a guess here is how the
		-- shipped bug happened.
		nodef   = { status = "assault_task_status_functor", target = "assault_task_target_functor" },
		-- faction_base_defense has no declared entry at all any more: its species is runtime
		-- (flesh/boar/dog, or ZOMBIED in the Yantar variant), so the state tests must answer.
		basedef = { target = "faction_base_defense_target" },
		snitch = { status = "top_10_task_status_functor",
		           target = "top_10_task_target_functor" },
		fetch  = { status = "actor_has_fetch_item", target = "general_fetch_task" },
		-- The nta_stash family, whose stash mark is on a DIFFERENT object from its target
		-- (the quest item inside the stash), so the coverage query can never see it. Its
		-- target 703 is deliberately given NO spots, to prove the name is what answers.
		ntastash = { status = "nta_stash_task_status", target = "nta_stash_task_target_functor" },
		-- A delivery. Its stage 1 target is the person you take the package to, and its
		-- stage_complete is 2, so the pin is live on a named NPC exactly like a bounty's.
		parcel = { status = "delivery_task", target = "general_delivery" },
		-- The same functor on the fixture that proves a delivery mid-run is not a hand-in.
		delivery_running = { status = "delivery_task", target = "general_delivery" },
	},
	-- What level.map_get_object_spots_by_id returns per object id, for the waypoint test.
	-- 700 is bare ground - only the waypoint's own two marks; 701 is a medic, i.e. a pin
	-- dropped on somebody the map already draws; 702 already wears one of OUR types.
	-- 704 is a STASH the player has already found, which is what a DRX quest-item task
	-- points straight at - the case that generalised this test off waypoints in R2.52.
	spots    = {
		[700] = { "secondary_task", "paw_task_default" },
		[701] = { "secondary_task", "paw_task_default", "ui_pda2_medic_location" },
		[702] = { "secondary_task", "paw_task_default", "iqm_task_open" },
		[704] = { "treasure" },
		-- R2.55c. Bare ground carrying ONLY the engine's new-task pulse, which every task
		-- wears for ~15 s after it is taken. This is the fixture the bug needed: the
		-- captured live sample was exactly
		--   spots=[secondary_task_location ui_secondary_task_blink]  -> kind=waypoint
		-- on a waypoint dropped in an empty field.
		[705] = { "secondary_task_location", "ui_secondary_task_blink" },
		-- ...and the same pulse over a REAL mark, so excluding it cannot blind the test.
		[706] = { "secondary_task_location", "ui_secondary_task_blink", "treasure" },
	},
}

-- One of each shape the pass has to deal with. `stage_complete`/`stage` drive the
-- hand-in gate: stage < stage_complete is "still to do", >= is "go and report".
local function fresh()
	return {
		-- a bounty with the mark still walking around
		{ id = "bounty_live", spot = "secondary_task_location", status = "selected",
		  gt_present = true, current_target = 801, stage = 0, stage_complete = 1,
		  map_location = "secondary_task_location" },
		-- ...and one whose mark is dead: the marker has moved to the barman
		{ id = "bounty_done", spot = "secondary_task_location", status = "selected",
		  gt_present = true, current_target = 900, stage = 1, stage_complete = 1,
		  map_location = "secondary_task_location" },
		-- HAND-IN (R2.58). Identical to bounty_done except that the giver is KNOWN and the
		-- marker is sitting on him -- which is the whole predicate. Encoded from a live
		-- save: simulation_task_142 read stage=1 stage_complete=1 giver=21478 tgt=21478.
		{ id = "handin", spot = "secondary_task_location", status = "selected",
		  gt_present = true, current_target = 21478, task_giver_id = 21478,
		  stage = 1, stage_complete = 1, map_location = "secondary_task_location" },
		-- ...and the case that must NOT be flagged: at the hand-in stage, but the marker is
		-- on something that is not the giver. bounty_done above is the no-giver-known half
		-- of the same guard; this is the giver-known-but-elsewhere half.
		{ id = "handin_elsewhere", spot = "secondary_task_location", status = "selected",
		  gt_present = true, current_target = 900, task_giver_id = 21478,
		  stage = 1, stage_complete = 1, map_location = "secondary_task_location" },
		-- A DELIVERY STILL RUNNING, which is the case that made this look like one bug and
		-- not two: stage 1 of 2, marker on the recipient rather than the giver, so it is not
		-- a hand-in and keeps its envelope. Live: simulation_task_48, stage=1
		-- stage_complete=2 giver=29189 tgt=19091.
		{ id = "delivery_running", spot = "secondary_task_location", status = "selected",
		  gt_present = true, current_target = 19091, task_giver_id = 29189,
		  stage = 1, stage_complete = 2, map_location = "secondary_task_location" },
		-- a mutant hunt: target squad's community is a monster one
		{ id = "hunt", spot = "secondary_task_location", status = "selected",
		  gt_present = true, current_target = 800, stage = 0, stage_complete = 1,
		  map_location = "secondary_task_location" },
		-- a storyline mutant hunt -- same skull, different tier (one type per KIND)
		{ id = "hunt_story", spot = "storyline_task_location", status = "selected",
		  gt_present = true, current_target = 802, stage = 0, stage_complete = 1,
		  map_location = "storyline_task_location" },
		-- THE LAIR TASK. Its target is a SMART TERRAIN (910, no community); the mutant
		-- squad is only reachable through the var it stored under its own id.
		{ id = "lair", spot = "secondary_task_location", status = "selected",
		  gt_present = true, current_target = 910, stage = 0, stage_complete = 1,
		  map_location = "secondary_task_location" },
		-- A SEARCH AND RESCUE. Nothing at runtime records it -- axr_task_manager.hostages_by_id
		-- is keyed the other way round and is empty until the hostage exists -- so the only
		-- signal is the section's own declared status functor. It answers "bounty" as of
		-- R2.55: the fight on arrival is the same one, so it takes the same mark.
		{ id = "rescue", spot = "secondary_task_location", status = "selected",
		  gt_present = true, current_target = 801, stage = 0, stage_complete = 1,
		  map_location = "secondary_task_location" },
		-- THE TOP 10 HIT LIST: a bounty in every sense except the one the registry sees.
		{ id = "snitch", spot = "secondary_task_location", status = "selected",
		  gt_present = true, current_target = 801, stage = 0, stage_complete = 10,
		  map_location = "secondary_task_location" },
		-- A HUNT FOR ONE CREATURE. Target 820 is a monster OBJECT, not a squad.
		{ id = "beasthunt", spot = "secondary_task_location", status = "selected",
		  gt_present = true, current_target = 820, stage = 0, stage_complete = 2,
		  map_location = "secondary_task_location" },
		-- A DRX QUEST ITEM. Points straight at a stash the player has already found, so the
		-- coverage query sees the treasure mark and the reticle goes hollow.
		{ id = "drxitem", spot = "secondary_task_location", status = "selected",
		  gt_present = true, current_target = 704, stage = 0, stage_complete = 1,
		  map_location = "secondary_task_location" },
		-- ...and the nta_stash twin, whose mark is on the stash while its target is the item
		-- inside it. Nothing is drawn on 703; only the declared functor can answer.
		{ id = "ntastash", spot = "secondary_task_location", status = "selected",
		  gt_present = true, current_target = 703, stage = 0, stage_complete = 1,
		  map_location = "secondary_task_location" },
		-- A DELIVERY at its deliver-to stage: stage 1 of 2, so still outstanding.
		{ id = "parcel", spot = "secondary_task_location", status = "selected",
		  gt_present = true, current_target = 801, stage = 1, stage_complete = 2,
		  map_location = "secondary_task_location" },
		-- an ordinary fetch: neither kind
		{ id = "fetch", spot = "secondary_task_location", status = "selected",
		  gt_present = true, current_target = 801, stage = 0, stage_complete = 1,
		  map_location = "secondary_task_location" },
		-- a task another mod has moved onto its own spot type
		{ id = "atue", spot = "secondary_task_location", status = "selected",
		  gt_present = true, current_target = 800, stage = 0, stage_complete = 1,
		  map_location = "atue_return_task" },
		-- a task with no stage_complete at all: fails open to talk-to, so never flagged
		{ id = "story", spot = "storyline_task_location", status = "selected",
		  gt_present = true, current_target = 800, stage = 0, stage_complete = nil,
		  map_location = "storyline_task_location" },
		-- finished: must never be touched, because get_map_location on a task whose
		-- locations are gone is not a road worth walking
		{ id = "done", spot = "secondary_task_location", status = "completed",
		  gt_present = true, current_target = 800, stage = 0, stage_complete = 1,
		  map_location = "secondary_task_location" },
		-- in timeout: no CGameTask yet
		{ id = "pending", spot = "secondary_task_location", status = "selected",
		  gt_present = false, current_target = 800, stage = 0, stage_complete = 1,
		  map_location = "secondary_task_location" },
	}
end

local function by_id(tasks, id)
	for _, t in ipairs(tasks) do if t.id == id then return t end end
end
local function called_for(calls, id)
	for _, c in ipairs(calls) do if c.id == id then return c end end
end

local ON  = { on = true,  declared = true }
local OFF = { on = false, declared = true }
local NODXML = { on = true, declared = false }

-- ----------------------------------------------------- 1. the ownership guard
do
	local tasks = fresh()
	local calls = sync(WORLD, ON, tasks)
	check("bounty flagged",      (called_for(calls, "bounty_live") or {}).to == "iqm_task_bounty")
	check("mutant flagged",      (called_for(calls, "hunt") or {}).to == "iqm_task_mutant")
	check("storyline hunt flagged too",
	      (called_for(calls, "hunt_story") or {}).to == "iqm_task_mutant",
	      "one type per KIND, not per kind x tier")
	check("lair flagged through the stored squad",
	      (called_for(calls, "lair") or {}).to == "iqm_task_mutant",
	      "an assault task points at the SMART, not the squad -- the R2.48 miss")
	check("rescue flagged as a bounty",
	      (called_for(calls, "rescue") or {}).to == "iqm_task_bounty",
	      "no registry records a rescue; the section declares it, and it wears the bounty")
	check("delivery flagged",    (called_for(calls, "parcel") or {}).to == "iqm_task_delivery",
	      "stage 1 of 2 is the deliver-to step, not the hand-in")
	check("top 10 flagged as a bounty",
	      (called_for(calls, "snitch") or {}).to == "iqm_task_bounty",
	      "it never registers in bounties_by_id")
	check("single-creature hunt flagged",
	      (called_for(calls, "beasthunt") or {}).to == "iqm_task_mutant",
	      "player_id lives on a squad; this target is one monster object")
	check("stash task on a found stash goes hollow",
	      (called_for(calls, "drxitem") or {}).to == "iqm_task_open",
	      "the solid crosshair covers the stash icon completely")
	check("...and so does the one whose mark is on a sibling object",
	      (called_for(calls, "ntastash") or {}).to == "iqm_task_open",
	      "named in TARGET_KIND because no query can reach it")
	check("fetch untouched",     called_for(calls, "fetch") == nil,
	      "nothing is drawn on its target, so the reticle keeps its middle")
	check("another mod's spot untouched", called_for(calls, "atue") == nil,
	      "atue_return_task is neither ours nor the task's own type")
	check("atue still on its own spot", by_id(tasks, "atue").map_location == "atue_return_task")
	check("completed task untouched",   called_for(calls, "done") == nil)
	check("task with no CGameTask untouched", called_for(calls, "pending") == nil)
end

-- ------------------------------------------------------- 2. the declared gate
do
	local tasks = fresh()
	local calls = sync(WORLD, NODXML, tasks)
	check("no calls at all without the splice", #calls == 0,
	      "an undeclared type is an engine fatal, not a missing icon")
	for _, t in ipairs(tasks) do
		check("no IQM type on " .. t.id, not OURS[t.map_location])
	end
end

-- ------------------------------------------------------------- 3. the revert
do
	local tasks = fresh()
	sync(WORLD, ON, tasks)                       -- flag them
	check("flagged before revert", by_id(tasks, "hunt").map_location == "iqm_task_mutant")
	local calls = sync(WORLD, OFF, tasks)        -- ...then switch the feature off
	check("mutant reverted", (called_for(calls, "hunt") or {}).to == "secondary_task_location")
	check("bounty reverted", (called_for(calls, "bounty_live") or {}).to == "secondary_task_location")
	check("storyline hunt reverts to ITS OWN type",
	      (called_for(calls, "hunt_story") or {}).to == "storyline_task_location",
	      "the revert target is t.spot, not a hardcoded secondary")
	for _, t in ipairs(tasks) do
		check("nothing left flagged: " .. t.id, not OURS[t.map_location])
	end
end

-- ...and the revert must survive a reload, which is the whole reason the pass runs even
-- when the feature is off. Simulated by starting from a world where the spots are
-- already ours and no in-memory state says so.
do
	local tasks = fresh()
	by_id(tasks, "hunt").map_location = "iqm_task_mutant"
	by_id(tasks, "bounty_live").map_location = "iqm_task_bounty"
	local calls = sync(WORLD, OFF, tasks)
	check("reverts spots inherited from a save", #calls == 2,
	      "a flag that does not survive a save cannot gate this pass")
end

-- --------------------------------------------------------- 4. idempotence
do
	for name, cfg in pairs({ on = ON, off = OFF, nodxml = NODXML }) do
		local tasks = fresh()
		sync(WORLD, cfg, tasks)
		local again = sync(WORLD, cfg, tasks)
		check("settled pass is silent (" .. name .. ")", #again == 0,
		      "change_map_location is remove-then-recreate; this runs forever")
	end
end

-- ------------------------------------------------------- 5. the hand-in gate
do
	local tasks = fresh()
	local calls = sync(WORLD, ON, tasks)
	check("finished bounty not flagged", called_for(calls, "bounty_done") == nil,
	      "stage >= stage_complete means the marker is on the person you report to")
	check("task with no stage_complete not flagged", called_for(calls, "story") == nil,
	      "fails open to talk-to, same as the card and marker gates")

	-- R2.58: the gate now has an exit as well as a stop. Until this release EVERY task past
	-- stage_complete answered nil and drew the plain reticle; the green "go and collect"
	-- diamond came from gamma-active-task-ui-enhancements, and uninstalling that mod removed
	-- the marker outright because this mod owned only the artwork for it.
	check("hand-in flagged", (called_for(calls, "handin") or {}).to == "iqm_task_handin",
	      "stage >= stage_complete AND the marker is on the task giver")
	check("hand-in not flagged when the marker is not on the giver",
	      called_for(calls, "handin_elsewhere") == nil,
	      "past the stage but pointing elsewhere -- both halves of the predicate are needed")
	check("running delivery keeps its envelope",
	      (called_for(calls, "delivery_running") or {}).to == "iqm_task_delivery",
	      "stage 1 of 2 with the marker on the recipient is not a hand-in")

	-- ...and a bounty that finishes mid-session goes back on its own
	local t = by_id(tasks, "bounty_live")
	check("flagged while live", t.map_location == "iqm_task_bounty")
	t.stage = 1
	local after = sync(WORLD, ON, tasks)
	check("unflagged on completion",
	      (called_for(after, "bounty_live") or {}).to == "secondary_task_location")
end

-- --------------------------------------------------------- 6. the classifier
do
	local T = function(o)
		o.stage, o.stage_complete = o.stage or 0, o.stage_complete or 1
		return o
	end
	check("bounty from the registry",
	      task_kind(WORLD, T{ id = "bounty_live", current_target = 801 }) == "bounty")
	check("mutant from the squad community",
	      task_kind(WORLD, T{ id = "x", current_target = 800 }) == "mutant")
	check("mutant through the stored squad when the target is a smart",
	      task_kind(WORLD, T{ id = "lair", current_target = 910 }) == "mutant")
	check("a smart with no stored squad is neither",
	      task_kind(WORLD, T{ id = "x", current_target = 910 }) == nil,
	      "the fallback must not guess when the task stored nothing")
	check("human squad is not a mutant",
	      task_kind(WORLD, T{ id = "x", current_target = 801 }) == nil)
	check("unknown target is neither",
	      task_kind(WORLD, T{ id = "x", current_target = 999 }) == nil)
	check("no target is neither",
	      task_kind(WORLD, T{ id = "x" }) == nil)
	-- The bounty registry wins over the community test, and cannot lose to it: a bounty
	-- target is a human by construction (tasks_bounty's faction_list is the ten human
	-- factions), so the two can never both answer.
	check("registry is checked first",
	      task_kind(WORLD, T{ id = "bounty_live", current_target = 800 }) == "bounty")

	-- The coverage fixes. Each of these was a REAL task family wearing the plain reticle,
	-- and each fails for its own reason -- which is why one test would not have caught all
	-- three.
	check("mutant from the target's own clsid",
	      task_kind(WORLD, T{ id = "x", current_target = 820 }) == "mutant",
	      "recover_mutant_data returns one monster's object id, which has no player_id")
	check("...but the item that hunt later points at is not a mutant",
	      task_kind(WORLD, T{ id = "x", current_target = 821 }) == nil,
	      "collecting the device off the corpse is not hunting")
	check("rescue answers bounty from the declared status functor",
	      task_kind(WORLD, T{ id = "rescue", current_target = 801 }) == "bounty")
	check("delivery from the declared status functor",
	      task_kind(WORLD, T{ id = "parcel", current_target = 801,
	                          stage = 1, stage_complete = 2 }) == "delivery")
	check("...and it stops at the hand-in, like every other kind",
	      task_kind(WORLD, T{ id = "parcel", current_target = 801,
	                          stage = 2, stage_complete = 2 }) == nil)
	check("top 10 from the declared target functor",
	      task_kind(WORLD, T{ id = "snitch", current_target = 801 }) == "bounty")
	check("a declared functor nobody listed is still neither",
	      task_kind(WORLD, T{ id = "fetch", current_target = 801 }) == nil,
	      "the two name lists may only ADD a kind, never claim one")
	-- ORDER: the declared tests run AFTER the registry and BEFORE the squad walk, so a
	-- rescue whose captive squad happens to read as anything else still reads as a rescue.
	check("rescue outranks the mutant tests",
	      task_kind(WORLD, T{ id = "rescue", current_target = 800 }) == "bounty")
	-- R2.55b. THE ASSAULT SPECIES RULE. These four are the regression test for the bug that
	-- shipped in R2.55, where every mutant hunt in the game turned red.
	check("a human assault answers bounty",
	      task_kind(WORLD, T{ id = "defend", current_target = 801 }) == "bounty",
	      "params are factions -> the enemy is people")
	-- THE ONE THAT WOULD HAVE CAUGHT IT. Same functor, monster community list, and -- the
	-- part that matters -- a target that tells the runtime tests NOTHING (801 is a human
	-- squad in this world, and no var is stored for this id). R2.55 answered "bounty" here
	-- and latched it. The species must come from the section, not from the target.
	check("a mutant assault answers mutant from CONFIG ALONE",
	      task_kind(WORLD, T{ id = "mutdef", current_target = 801 }) == "mutant",
	      "the functor is shared; only status_functor_params separates the two families")
	check("...and still does when the target is not resolvable at all",
	      task_kind(WORLD, T{ id = "mutdef", current_target = 999 }) == "mutant",
	      "a mutant hunt must not wear the wrong pin until its squad happens to spawn")
	check("an assault with no community list answers nothing",
	      task_kind(WORLD, T{ id = "nodef", current_target = 999 }) == nil,
	      "no evidence must mean no answer -- never a guess that then latches")
	check("faction_base_defense falls through to the state tests",
	      task_kind(WORLD, T{ id = "basedef", current_target = 800 }) == "mutant"
	      and task_kind(WORLD, T{ id = "basedef", current_target = 801 }) == nil,
	      "its species is runtime (mutants, or zombied on Yantar) -- config cannot say")
	check("the registry still outranks a declared functor",
	      task_kind(WORLD, T{ id = "bounty_live", current_target = 820 }) == "bounty")

	-- R2.52: the coverage test is no longer PAW-only. It is the last question asked, so
	-- everything that can name the job outranks it -- which is the entire safety argument
	-- for letting it apply to every task rather than to a list of them.
	check("a task pointing at a found stash goes hollow",
	      task_kind(WORLD, T{ id = "x", current_target = 704 }) == "open")
	check("a task on bare ground keeps its middle",
	      task_kind(WORLD, T{ id = "x", current_target = 700, spot = "secondary_task" }) == nil)
	check("nothing drawn there at all is not coverage",
	      task_kind(WORLD, T{ id = "x", current_target = 999 }) == nil)
	check("our own type still does not count as coverage",
	      task_kind(WORLD, T{ id = "x", current_target = 702, spot = "secondary_task" }) == nil,
	      "otherwise the general test latches on its own output too")
	check("a bounty standing on a marked object is still a bounty",
	      task_kind(WORLD, T{ id = "bounty_live", current_target = 704 }) == "bounty",
	      "every answer about the JOB outranks one about the ground")
	check("a mutant hunt on a marked object is still a mutant hunt",
	      task_kind(WORLD, T{ id = "x", current_target = 800 }) == "mutant")
	-- R2.55c. THE NEW-TASK PULSE IS NOT COVERAGE. 705 is bare ground carrying only the
	-- engine's own blink, which every task wears for ~15 s after it is taken. Counting it
	-- hollowed the reticle on empty ground -- reported on placed waypoints, but it reached
	-- every task this test can answer for, and it healed itself when the pulse expired,
	-- which is what made it look intermittent.
	check("a waypoint on bare ground with only its own new-task pulse stays solid",
	      task_kind(WORLD, T{ id = "task_placeable_waypoint", current_target = 705,
	                          spot = "secondary_task_location" }) == nil,
	      "ui_secondary_task_blink is the task's own highlight, not another mark")
	check("...and the same for an ordinary task's coverage test",
	      task_kind(WORLD, T{ id = "x", current_target = 705,
	                          spot = "secondary_task_location" }) == nil,
	      "nothing about this was specific to waypoints")
	check("...while a REAL mark under the pulse still counts",
	      task_kind(WORLD, T{ id = "x", current_target = 706,
	                          spot = "secondary_task_location" }) == "open",
	      "excluding the blink must not blind the test to the stash beside it")
	check("nta_stash answers even with nothing drawn on its target",
	      task_kind(WORLD, T{ id = "ntastash", current_target = 703 }) == "open")
	-- R2.55. THE TWO HOLLOW TYPES ARE DISTINCT, AND DIFFER IN EXACTLY ONE ELEMENT. This
	-- replaced a check asserting they were the SAME type, which is precisely the bug: with
	-- one shared borderless type, selecting a stash task moved the active task and drew
	-- nothing, because show_static_border is a no-op when the element is absent
	-- (map_spot.cpp:140-146). So the old check was pinning the defect in place.
	check("the two hollow types are separate",
	      SPOT.waypoint == "iqm_task_waypoint" and SPOT.open == "iqm_task_open")
	do
		local o = spots_xml:match("<iqm_task_open_spot[ >].-</iqm_task_open_spot>") or ""
		local w = spots_xml:match("<iqm_task_waypoint_spot[ >].-</iqm_task_waypoint_spot>") or ""
		check("...open carries the active-task ring", o:find("<static_border"),
		      "without it a selected stash task gives the player no feedback at all")
		check("...and waypoint deliberately does not", not w:find("<static_border"),
		      "PAW draws paw_task_default on the same object; two pulsing rings is one too many")
		-- ...and they are otherwise the same mark, which is the half a reader has to trust
		-- unless it is asserted: the texture is what makes them read as one shape.
		check("...but both draw the same hollow reticle",
		      o:find("iqm_mapspot_taskopen") and w:find("iqm_mapspot_taskopen"))
	end

	-- THE WAYPOINT KIND IS ABOUT THE GROUND, NOT THE JOB (R2.49f). It answers "waypoint"
	-- only when something else is already drawn on the target, because the hollow reticle
	-- exists to let that something show through - on bare ground it would just be a
	-- marker with its middle missing.
	local WP = function(tgt)
		return T{ id = "task_placeable_waypoint", current_target = tgt,
		          spot = "secondary_task" }
	end
	check("waypoint on bare ground keeps the full reticle",
	      task_kind(WORLD, WP(700)) == nil,
	      "its own spot and PAW's highlight are not 'something underneath'")
	check("waypoint on a service NPC goes hollow",
	      task_kind(WORLD, WP(701)) == "waypoint")
	check("our own type does not count as coverage",
	      task_kind(WORLD, WP(702)) == nil,
	      "otherwise the test reads its own output back and latches on")
	check("waypoint with no target is neither",
	      task_kind(WORLD, WP(nil)) == nil)
end

-- ------------------------------------------------- 6b. no save carries our types
-- The promise that makes the mod removable at any moment. revert_for_save flips `on` off
-- for one pass inside the engine's pre-save callback, so what reaches disk is vanilla.
do
	local tasks = fresh()
	sync(WORLD, ON, tasks)
	local flagged = 0
	for _, t in ipairs(tasks) do if OURS[t.map_location] then flagged = flagged + 1 end end
	check("something is flagged to begin with", flagged > 0)

	-- revert_for_save, transcribed: one pass with the feature forced off, then restore
	local was = ON
	sync(WORLD, OFF, tasks)
	for _, t in ipairs(tasks) do
		check("save would be clean: " .. t.id, not OURS[t.map_location],
		      "this string goes on disk and the engine aborts on it without the mod")
	end
	-- ...and the flags come straight back on the next pass, so the revert is invisible
	local back = sync(WORLD, was, tasks)
	check("re-flagged immediately after the save", #back == flagged,
	      "the pins must not stay plain until the next throttle tick")
end

-- ------------------------------------------------------------- 7. the source
-- 1-6 prove the MODEL. These prove the model is the code.

check("src: ownership guard is OURS-or-own-type",
      spot_src:find("OURS%[cur%]%s*or%s*cur%s*==%s*base"),
      "the guard that leaves other mods' spots alone")
check("src: OURS is derived from SPOT, not restated",
      spot_src:find("for%s+_,%s*v%s+in%s+pairs%(SPOT%)%s+do%s+OURS%[v%]%s*=%s*true"),
      "two hand-written lists of the same names is one edit from a save-breaking hole")
check("src: declared flag gates the type names",
      spot_src:find("iqm_task_spots_declared"),
      "no splice, no type names")
check("src: declared is read per pass, not cached",
      spot_src:find("local declared = modxml_n_iqm_map_icons"),
      "the splice fires long after on_game_start")
check("src: revert target is the task's own spot",
      spot_src:find("local want = %(kind and SPOT%[kind%]%) or base"))
-- Against the CALL, `gt:get_map_location`, not the bare name: the name appears in prose
-- above it, and matching that would compare the guard's position against a comment and
-- fail on a file that is perfectly correct.
check("src: liveness guard precedes get_map_location",
      spot_src:find("task_active%(t%)") and
      spot_src:find("task_active%(t%)") < spot_src:find("gt:get_map_location"),
      "a removed location holds a null shared_str")
-- R2.48a. The bug that made the whole feature a no-op on the first build: `C` is a file
-- LOCAL in iqm_core, so iqm_core.C is nil and every gate built on it is false. Asserted
-- by name in both directions, because the wrong version is silent -- no error, no log
-- line, just nothing ever happening.
-- The negative half matches an ASSIGNMENT, not the bare name: the comment above the fix
-- names iqm_core.C to explain why it is wrong, and a plain search would fail on the very
-- file that documents the bug correctly.
check("src: config comes from the ACCESSOR, not iqm_core.C",
      spot_src:find("iqm_core%.config%(%)") and not spot_src:find("=%s*iqm_core%.C%f[%W]"),
      "iqm_core.C is nil -- C is a file local there (iqm_core.script:649)")
check("src: no other module reads iqm_core.C either",
      not core_src:find("^C = ") and core_src:find("local C%s+= {}"),
      "if C ever becomes public this assertion should be revisited, not deleted")
check("src: both option keys gate the feature",
      spot_src:find("C%.enabled and C%.map_icons and C%.map_task_kinds"))

-- R2.48a: the removability promise.
check("src: the pre-save revert is registered",
      spot_src:find('RegisterScriptCallback%("save_state", revert_for_save%)'),
      "without this a save carries type names that abort the engine on a mod-less load")
check("src: it reverts by flipping the feature off, not by a second routine",
      spot_src:find("local was = on\n\ton = false\n\tsync%(%)\n\ton = was"),
      "two ways to say 'put everything back' is one of them being wrong")
check("src: ...and re-applies on the next frame, not the next tick",
      spot_src:match("function revert_for_save.-\nend"):find("next_t = 0"))
check("src: the feature refuses to run without marshal",
      spot_src:find("and USE_MARSHAL"),
      "save_state only fires when marshal is present (alife_storage_manager.script:162)")

check("src: task_kind gates on target_is_talk_to",
      scan_src:find("function task_kind") and
      scan_src:match("function task_kind.-\nend"):find("target_is_talk_to"),
      "one hand-in rule, not two that can drift")
check("src: bounty read from the registry",
      scan_src:find("axr_task_manager%.bounties_by_id"))
check("src: mutant read from is_squad_monster",
      scan_src:find("is_squad_monster%[comm%]"))
check("src: mutant resolved through alife_object, not level.object_by_id",
      scan_src:find("local function squad_comm") and
      scan_src:match("local function squad_comm.-\nend"):find("alife_object"),
      "these targets are usually offline")
-- R2.48a: the lair miss.
check("src: falls back to the task's stored squad",
      scan_src:match("function task_kind.-\nend"):find("load_var%(db%.actor, id%)"),
      "an assault task points at the SMART; the squad is in its own stored var")
-- The three coverage fixes, asserted in the source as well as in the model.
check("src: a target that is ITSELF a monster counts",
      scan_src:find("local function target_is_monster") and
      scan_src:match("local function target_is_monster.-\nend"):find("IsMonster"),
      "player_id is a squad field; a one-creature hunt returns an object without it")
check("src: ...via the engine's class table, not a section-name match",
      scan_src:match("local function target_is_monster.-\nend"):find("clsid%(%)"),
      "IsMonster covers whatever creature any mod spawns")
check("src: the declared-functor fallbacks are read from task_ini",
      scan_src:find("local function task_functors") and
      scan_src:match("local function task_functors.-\nend"):find("task_manager%.task_ini"),
      "same source as stage_complete, and the same standing")
check("src: the rescue functor answers bounty",
      scan_src:find('hostage_task = "bounty"'),
      "R2.55 folded the hostage kind into the bounty")
-- R2.55. The late tables are only correct BECAUSE of where they are consulted, so that is
-- what is asserted -- a name check alone would pass on the bug this ordering exists to
-- prevent (assault answering before the mutant tests, stripping every mutant hunt of its
-- skull). Position is the invariant; the table contents are checked by the model above.
check("src: the assault kind is read from the declared community list",
      scan_src:find("local function assault_kind") and
      scan_src:find('status_functor_params'),
      "the functor alone cannot separate a mutant hunt from a faction fight")
check("src: ...and answers NOTHING when is_squad_monster is unavailable",
      scan_src:match("local function assault_kind.-\nend"):find("if not is_squad_monster then return nil end"),
      "defaulting to bounty here is the R2.55 bug in miniature")
-- The LATE table is gone, and its absence is asserted rather than assumed: reintroducing one
-- is the specific mistake this file now exists to prevent.
check("src: there is no late declared-functor table any more",
      not scan_src:find("LATE_STATUS_KIND") and not scan_src:find("LATE_TARGET_KIND"),
      "a declaration consulted after a runtime test still latches an answer built on no evidence")
check("src: the assault rule sits WITH the other declarations, before the state tests",
      (function()
      	local decl = scan_src:find("local declared = f and %(STATUS_KIND")
      	local mut  = scan_src:find('kind_seen%[id%] = "mutant"')
      	return decl and mut and decl < mut
      end)(),
      "it is config, so it belongs where the other config answers are")
-- R2.54. The strongest entry in that table: tasks_delivery builds its OWN registry by
-- walking task_ini for this exact string (tasks_delivery.script:19-26), so this is not a
-- name list standing in for a state test, it is the same test without the linear scan.
check("src: delivery is keyed on the status functor",
      scan_src:find('delivery_task = "delivery"'))
check("src: top 10 is keyed on the target functor",
      scan_src:find('top_10_task_target_functor = "bounty"'))
-- THE ORDER IS THE ARGUMENT. A name list is only admissible here because it runs after
-- the registry, so it can add a kind and never take one away. Written down as a position
-- check rather than a comment, because the comment is what would survive a reorder.
check("src: the declared lists are consulted AFTER the bounty registry",
      scan_src:find("bounties_by_id%[id%]") < scan_src:find("local declared = f and"),
      "a name list ahead of the state tests is the design this file rejects")
check("src: ...and before the squad community walk",
      scan_src:find("local declared = f and") < scan_src:find("is_squad_monster%[comm%]"))

check("src: positive kinds are cached, negatives are re-tested",
      scan_src:find("kind_seen%[id%] = \"mutant\"") and scan_src:find("KIND_RECHECK"),
      "squad_id is nil for the first frame and again every 3 s while the status "
      .. "functor rescans -- caching that would freeze a lair on the plain reticle")
check("src: the liveness test is published for iqm_taskspot",
      scan_src:find("task_active = is_task_active"))

-- The waypoint kind is the one that must NOT be cached the way the others are: the other
-- two are properties of the job and never change, this one is a property of the ground and
-- the player moves the waypoint without the task id changing.
check("src: the waypoint kind is keyed on the TARGET, not the task id",
      scan_src:find("wp_target") ~= nil and scan_src:find("kind_seen%[id%] = \"waypoint\"") == nil,
      "a sticky cache here would freeze the first ground it was tested on")
-- R2.52: the general one must not latch either, for the same reason, and it must survive
-- the negative throttle -- returning nil between rechecks would flap the pin every 5 s.
check("src: the general coverage answer is not latched in kind_seen",
      scan_src:find("kind_seen%[id%] = \"open\"") == nil and scan_src:find("open_kind%[id%]"),
      "coverage is a property of the ground, not of the job")
check("src: ...and the throttle hands back that answer rather than nil",
      scan_src:find("return open_kind%[id%]\n\tend"),
      "nil here would flip the reticle solid for the whole recheck interval")
check("src: ...and a target change re-tests at once",
      scan_src:find("open_tgt%[id%] == tgt"))
check("src: the coverage test runs LAST, after every test about the job",
      scan_src:find("target_is_monster%(tgt%)") < scan_src:find("open_kind%[id%] = %(tgt"),
      "this is the whole safety argument for applying it to every task")
check("src: coverage is asked of the engine, not guessed from a list",
      scan_src:find("map_get_object_spots_by_id") ~= nil)
check("src: the stash family whose mark is on a sibling object is named instead",
      scan_src:find("nta_stash_task_target_functor = \"open\""),
      "no positional query exists, so this one cannot be derived")
check("src: the task's own spot does not count as coverage",
      scan_src:find("t ~= own") ~= nil)
check("src: PAW's own highlight does not count either",
      scan_src:find("NOT_COVER%[t%]") and scan_src:find("paw_task_default%s*= true"))
-- R2.55c. The engine's NEW-TASK PULSE is the third exclusion, and the one whose absence was
-- a live bug: a separate map location on the task's own target, alive ~15 s after the task
-- is taken. Both variants must be listed -- storyline tasks carry the other one, so naming
-- only the secondary would leave every fresh storyline task hollow.
check("src: ...nor does the engine's new-task pulse, in either variant",
      scan_src:find("ui_secondary_task_blink%s*= true")
      and scan_src:find("ui_storyline_task_blink%s*= true"),
      "a task's own 'you just got this' highlight is not another mark on the ground")
check("src: nor does anything of ours",
      scan_src:find('find%("%^iqm_"%)') ~= nil,
      "otherwise the test reads its own output back")

check("src: map_icons option declared", core_src:find('key = "map_icons"'))
check("src: map_task_kinds option declared", core_src:find('key = "map_task_kinds"'))
-- R2.59: the MENU no longer hides this row when map_icons is off -- setting-gated
-- preconditions went, because MCM evaluates them at page BUILD time and a row that
-- reappears only after reopening the menu cannot be read at a glance. Nothing is lost
-- here, and this check now names the gate that was always the load-bearing one: hiding a
-- row never changed its stored value, so it was iqm_taskspot's own test that kept an
-- acid-green skull off a vanilla map, and it is still there.
check("src: map_task_kinds rides map_icons IN CODE, which is the gate that matters",
      spot_src:find("C%.map_icons and C%.map_task_kinds"),
      "the menu row is unconditional by design; this is what reverts the spots live")
check("src: ...and the menu row carries no precondition",
      -- Bounded to the row's OWN record with [^}]*: Lua's `.` matches newlines, so a
      -- `.-pre =` here would happily reach the next gated row further down the file.
      core_src:find('key = "map_task_kinds"[^}]*pre =') == nil,
      "re-gating it would make the row vanish until the menu is reopened")
check("src: iqm_taskspot gets its apply_config",
      core_src:find("iqm_taskspot%.apply_config%(%)"))
check("src: active_task_target returns the kind",
      core_src:find("scan_task_kind and scan_task_kind%(t%)"))

check("src: the modxml VERIFIES the declared flag against the DOM",
      modxml_src:find("local probe = xml_obj:query%(name%)"),
      "'the splice ran' and 'the types are there' come apart on a stale deployed XML")
-- R2.51. The single-probe version passed on the one case the probe is for: an XML a version
-- behind carries the OLD types and not the new one.
check("src: ...for every type, not one representative",
      modxml_src:find("for _, name in pairs%(types or") and
      modxml_src:find("iqm_taskspot%.spot_types"),
      "probing iqm_task_bounty alone certifies a file that is missing iqm_task_waypoint")
check("src: ...and the list is owned by the module that hands the names out",
      spot_src:find("\nspot_types = SPOT"),
      "a second hand-written list is the thing that goes stale next")
check("src: ...and latches false across the three spot files",
      modxml_src:find("elseif iqm_task_spots_declared ~= false then"),
      "only the engine knows which aspect variant g_uiSpotXml loaded")
check("src: the vanilla-icons switch returns BEFORE the retexture loop",
      modxml_src:find("if not icons_on%(%) then") and
      modxml_src:find("if not icons_on%(%) then") < modxml_src:find("for _, s in ipairs%(SPOTS%)"),
      "the splice must still happen; only the replacement is optional")
check("src: icons_on defaults to TRUE on every failure",
      modxml_src:find("if not %(ui_mcm and ui_mcm%.get%) then return true end") and
      modxml_src:find("if not ok or v == nil then return true end"),
      "a shrug must not silently undo the mod")

-- The XML has to actually declare what the script hands out. This is the check that
-- stands between a typo and an unopenable save.
for kind, want in pairs(SPOT) do
	check("xml declares " .. want, spots_xml:find("<" .. want .. ">"),
	      "iqm_taskspot names it; map_spots.xml must carry it or the engine aborts")
	for _, suffix in ipairs({ "_spot", "_spot_mini" }) do
		check("xml declares " .. want .. suffix,
		      spots_xml:find("<" .. want .. suffix .. "[ >]"))
	end
	-- ...and the type must point AT those two, not at vanilla's
	local body = spots_xml:match("<" .. want .. ">(.-)</" .. want .. ">") or ""
	check("xml " .. want .. " has both views",
	      body:find('level_map spot="' .. want .. '_spot"') and
	      body:find('mini_map spot="' .. want .. '_spot_mini"'),
	      kind .. " must draw on the fullscreen map AND the minimap")
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
