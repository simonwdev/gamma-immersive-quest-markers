-- Harness: the NAMED SERVICE PINS (option map_spot_names, iqm_spothint.script).
--
-- WHY THIS EXISTS. The module is small, but every one of its interesting properties is
-- a property of a MONKEY-PATCH on a vanilla function that eight other resets run
-- through, and none of them can be seen by reading the file:
--
--   1. WRAPPING MUST NOT STACK. The hint is composed FROM the hint's role word and
--      written back onto the same location, so a wrapper installed over a wrapper
--      composes a composed string -- "Sidorovich - Sidorovich - Trader", one name
--      longer every reload. Loading a save re-reads .script files, so "on_game_start
--      runs twice" is a real state, not a hypothetical, and the guard against it lives
--      on the PATCHED module rather than in a local here. Driven below.
--   2. VANILLA MUST STILL RUN, ALWAYS, AND ITS ERRORS MUST STILL RAISE. The wrapper
--      calls the original outside its own guard: swallowing an error from the game's
--      own reset would hide it somewhere nobody would look for it. Our half is inside
--      the guard, for the mirror-image reason.
--   3. REVERTING MUST RESTORE THE ID, NOT A TRANSLATION. A hint is stored raw and
--      translated at draw time, so writing back "st_ui_pda_legend_trader" gives
--      exactly the vanilla tooltip in every language, and writing back "Trader" gives
--      an English one to a Russian player. Only an assertion can tell those apart --
--      on screen, in English, they look identical.
--   4. THE SWITCH MUST WORK IN BOTH DIRECTIONS ON PINS ALREADY DRAWN. That is what
--      the `seen` table is for, and why it records service NPCs even while the option
--      is off. Get that wrong and switching the feature ON does nothing until each
--      NPC's logic happens to reset -- which, in the hub the player is standing in, is
--      "not this visit", i.e. it reads as a broken option.
--
-- The fixtures are the REAL vanilla decision table, transcribed from
-- stalker_generic.reset_show_spot (scripts/stalker_generic.script:95-125 in unpacked
-- Anomaly 1.5.3, which no GAMMA mod overrides): every location type it can set and the
-- legend string id the game pairs with each. If a future Anomaly renames one, the
-- assertion that our table matches this one is the thing that fails.
--
-- Usage:
--   python check_lua.py --run tools/spothint-harness/harness.lua
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

-- --------------------------------------------------------------- the engine
-- The map-location registry, as much of it as this module can see: a hint per
-- (object id, spot type). `writes` counts every map_change_spot_hint call, which is how
-- "left alone" is told apart from "rewritten with the same text".
local spots  = {}   -- [id] = { [spot_type] = hint }
local writes = 0

local function has_spot(id, spot)
	return (spots[id] and spots[id][spot]) and 1 or 0
end

local ENV = {}
ENV.pairs, ENV.ipairs, ENV.type, ENV.tostring = pairs, ipairs, type, tostring
ENV.string, ENV.table, ENV.math, ENV.os = string, table, math, os
ENV.pcall, ENV.setmetatable, ENV.print = pcall, setmetatable, print
ENV._G = ENV

-- The three string ids this harness cares about, "translated" the way the shipped
-- tables translate them. Everything else falls through unchanged, which is what
-- CStringTable::translate does for an id it does not hold (string_table.cpp:226-234)
-- and is the property the whole composed-hint approach rests on.
local TRANSLATIONS = {
	st_iqm_spot_named           = "%s - %s",
	st_ui_pda_legend_trader     = "Trader",
	st_ui_pda_legend_mechanic   = "Technician",
	st_ui_pda_legend_barman     = "Bartender",
	st_ui_pda_legend_medic      = "Medic",
	st_ui_pda_legend_scout      = "Guide",
	st_ui_pda_legend_special    = "Important Character",
	st_ui_pda_legend_vip        = "Important character",
	st_ui_pda_companion         = "Companion",
}
local translated = 0
ENV.game = {
	translate_string = function(s)
		translated = translated + 1
		return TRANSLATIONS[s] or s
	end,
}

local npcs = {}
local function make_npc(id, cname)
	local npc = {
		_id = id, _cname = cname,
		id = function(self) return self._id end,
		name = function(self) return "sim_stalker_" .. self._id end,
		character_name = function(self) return self._cname end,
	}
	npcs[id] = npc
	return npc
end

ENV.level = {
	object_by_id = function(id) return npcs[id] end,
	map_has_object_spot = has_spot,
	map_change_spot_hint = function(id, spot, text)
		if has_spot(id, spot) == 0 then return end   -- the engine no-ops on a missing location
		writes = writes + 1
		spots[id][spot] = text
	end,
}

-- iqm_core's seam: the module PULLS config through this, exactly as in game.
local CFG = { enabled = true, map_spot_names = true }
ENV.iqm_core = { config = function() return CFG end }

-- ----------------------------------------------------- vanilla, transcribed
-- stalker_generic.reset_show_spot's decision table. `level_spot` in the NPC's logic
-- picks the row; the row's two fields are what the real function passes to
-- level.map_add_object_spot. All eight rows are here, `ours` marking the seven the mod
-- names -- so "left alone" is tested against the real companion row rather than against
-- an invented spot type, and a row added to the module without one added here fails.
--
-- special and quest_npc BOTH draw an important-character pin and their legend strings
-- differ only in capitalisation. That is vanilla's, not a transcription slip: it is why
-- the module carries two rows for one pin instead of folding them together.
local VANILLA = {
	special   = { spot = "ui_pda2_special_location",   legend = "st_ui_pda_legend_special",  ours = true },
	trader    = { spot = "ui_pda2_trader_location",    legend = "st_ui_pda_legend_trader",   ours = true },
	mechanic  = { spot = "ui_pda2_mechanic_location",  legend = "st_ui_pda_legend_mechanic", ours = true },
	guider    = { spot = "ui_pda2_scout_location",     legend = "st_ui_pda_legend_scout",    ours = true },
	barman    = { spot = "ui_pda2_barman_location",    legend = "st_ui_pda_legend_barman",   ours = true },
	quest_npc = { spot = "ui_pda2_quest_npc_location", legend = "st_ui_pda_legend_vip",      ours = true },
	medic     = { spot = "ui_pda2_medic_location",     legend = "st_ui_pda_legend_medic",    ours = true },
	-- The player's own squad member: carded by this mod already, and the one pin whose
	-- identity nobody is in any doubt about. Deliberately not named.
	companion = { spot = "ui_pda2_companion_location", legend = "st_ui_pda_companion" },
}

local vanilla_calls = 0
ENV.stalker_generic = {}
-- The real function removes the old spot, then adds the one the logic asks for. Both
-- halves matter here: the removal is why a shop that stops being one loses its entry
-- in the module's `seen` table.
function ENV.stalker_generic.reset_show_spot(npc, scheme, st, section)
	vanilla_calls = vanilla_calls + 1
	if st and st.raise then error("vanilla exploded") end
	local id = npc:id()
	spots[id] = {}
	local row = st and st.level_spot and VANILLA[st.level_spot]
	if row then spots[id][row.spot] = row.legend end
	-- A pin some OTHER mod put on the same NPC, present before our wrapper looks.
	-- Vanilla only ever adds one, so this is the only way two can be there at once.
	local extra = st and st.extra and VANILLA[st.extra]
	if extra then spots[id][extra.spot] = extra.legend end
end

-- ------------------------------------------------------- load iqm_spothint
local function load_module()
	local env = setmetatable({}, { __index = ENV })
	local chunk, err = loadstring(slurp("gamedata/scripts/iqm_spothint.script"),
	                              "@iqm_spothint.script")
	assert(chunk, err)
	setfenv(chunk, env)
	chunk()
	ENV.iqm_spothint = env   -- visible as a script namespace, as in game
	return env
end

local M = load_module()
M.on_game_start()
M.apply_config()

-- ---------------------------------------------------------------- the drive
local function reset(id, level_spot, raise, extra)
	ENV.stalker_generic.reset_show_spot(npcs[id], "nil",
		{ level_spot = level_spot, raise = raise, extra = extra }, "logic")
end
local function hint(id, spot) return spots[id] and spots[id][spot] end

make_npc(1, "Sidorovich")
make_npc(2, "Cardan")
make_npc(3, "")             -- a spot-carrying NPC with no character name
make_npc(4, "Wolf")         -- an important character, and a guide later on
make_npc(5, "Beard")        -- a bartender, for the switch tests
make_npc(7, "Nimble")       -- the quest-NPC pin, the other half of "VIP"
make_npc(8, "Fanatic")      -- a companion: the one pin left alone

reset(1, "trader")
reset(2, "mechanic")
reset(3, "trader")
reset(4, "special")
reset(5, "barman")
reset(7, "quest_npc")
reset(8, "companion")

check("the trader's pin is named", hint(1, "ui_pda2_trader_location") == "Sidorovich - Trader",
	tostring(hint(1, "ui_pda2_trader_location")))
check("the technician's pin is named", hint(2, "ui_pda2_mechanic_location") == "Cardan - Technician",
	tostring(hint(2, "ui_pda2_mechanic_location")))
check("...and it uses the pin's OWN role word, not the mod's refined one",
	hint(2, "ui_pda2_mechanic_location"):find("Technician", 1, true) ~= nil)
check("a nameless NPC keeps the vanilla legend id",
	hint(3, "ui_pda2_trader_location") == "st_ui_pda_legend_trader",
	tostring(hint(3, "ui_pda2_trader_location")))
check("the important character's pin is named",
	hint(4, "ui_pda2_special_location") == "Wolf - Important Character",
	tostring(hint(4, "ui_pda2_special_location")))
check("the quest NPC's pin is named, and from its OWN legend id",
	hint(7, "ui_pda2_quest_npc_location") == "Nimble - Important character",
	tostring(hint(7, "ui_pda2_quest_npc_location")))
check("the companion's pin is left on its vanilla legend",
	hint(8, "ui_pda2_companion_location") == "st_ui_pda_companion",
	tostring(hint(8, "ui_pda2_companion_location")))
check("vanilla ran for every one of them", vanilla_calls == 7, tostring(vanilla_calls))

-- The guide pin, on the NPC who was an important character a moment ago: the pin type
-- follows the NPC's logic, and the tooltip has to follow the pin.
reset(4, "guider")
check("the guide's pin is named", hint(4, "ui_pda2_scout_location") == "Wolf - Guide",
	tostring(hint(4, "ui_pda2_scout_location")))
check("...and the important-character pin it replaced is gone",
	hint(4, "ui_pda2_special_location") == nil)

-- An NPC carrying two of ours at once, which only another mod can arrange: vanilla's
-- own if/elseif order decides, and `special` comes before `medic` in it.
do
	npcs[3]._cname = "Doc"
	reset(3, "medic", nil, "special")
	check("with two pins, the first vanilla row wins",
		hint(3, "ui_pda2_special_location") == "Doc - Important Character"
		and hint(3, "ui_pda2_medic_location") == "st_ui_pda_legend_medic",
		tostring(hint(3, "ui_pda2_special_location")) .. " / " ..
		tostring(hint(3, "ui_pda2_medic_location")))
	-- ...and it is the winner that gets remembered, so the switch reverts the pin it
	-- actually wrote rather than the other one.
	CFG.map_spot_names = false; M.apply_config()
	check("...and the switch reverts that same pin",
		hint(3, "ui_pda2_special_location") == "st_ui_pda_legend_special")
	CFG.map_spot_names = true;  M.apply_config()
	npcs[3]._cname = ""
	reset(3, "trader")
end

-- ------------------------------------------------- vanilla's errors still raise
do
	local before = vanilla_calls
	local ok = pcall(reset, 1, "trader", true)
	check("an error from vanilla is NOT swallowed", ok == false)
	check("...and it was vanilla that was called", vanilla_calls == before + 1)
	reset(1, "trader")   -- put NPC 1 back
end

-- --------------------------------------------------- our half never propagates
do
	local saved = npcs[1].character_name
	npcs[1].character_name = function() error("name lookup exploded") end
	local ok = pcall(reset, 1, "trader")
	check("an error in OUR half is contained", ok == true)
	check("...and the pin is left on the vanilla legend when it happens",
		hint(1, "ui_pda2_trader_location") == "st_ui_pda_legend_trader")
	npcs[1].character_name = saved
	reset(1, "trader")
end

-- ------------------------------------------------------------- the switch
do
	local w = writes
	CFG.map_spot_names = false
	M.apply_config()
	check("switching off reverts to the legend ID, not to English",
		hint(1, "ui_pda2_trader_location") == "st_ui_pda_legend_trader",
		tostring(hint(1, "ui_pda2_trader_location")))
	check("...for every service pin already drawn",
		hint(2, "ui_pda2_mechanic_location") == "st_ui_pda_legend_mechanic"
		and hint(5, "ui_pda2_barman_location") == "st_ui_pda_legend_barman")
	check("...and it took a write per remembered pin", writes > w)

	-- A service NPC first seen while the feature is OFF must still be remembered, or
	-- switching back on would not reach it.
	make_npc(6, "Ashot")
	reset(6, "medic")
	check("a pin seen while off is left vanilla",
		hint(6, "ui_pda2_medic_location") == "st_ui_pda_legend_medic")

	CFG.map_spot_names = true
	M.apply_config()
	check("switching on names the pins already drawn",
		hint(1, "ui_pda2_trader_location") == "Sidorovich - Trader")
	check("...including one first seen while it was off",
		hint(6, "ui_pda2_medic_location") == "Ashot - Medic",
		tostring(hint(6, "ui_pda2_medic_location")))

	-- The master switch is the same gate.
	CFG.enabled = false
	M.apply_config()
	check("the mod's master switch reverts them too",
		hint(1, "ui_pda2_trader_location") == "st_ui_pda_legend_trader")
	CFG.enabled = true
	M.apply_config()
end

-- ------------------------------------------------- re-applying is idempotent
do
	local w = writes
	M.apply_config()
	check("a no-change apply_config writes nothing", writes == w)
	reset(1, "trader")
	check("re-running the reset does not compound the name",
		hint(1, "ui_pda2_trader_location") == "Sidorovich - Trader",
		tostring(hint(1, "ui_pda2_trader_location")))
end

-- --------------------------------------------------- an NPC that stops being one
do
	reset(5, nil)   -- Beard's logic no longer asks for a spot; vanilla removed the pin
	CFG.map_spot_names = false
	M.apply_config()
	CFG.map_spot_names = true
	M.apply_config()
	check("a pin that has gone is forgotten rather than chased",
		spots[5] and next(spots[5]) == nil)
end

-- ------------------------------------------------- translations are cached
do
	local before = translated
	for _ = 1, 20 do reset(1, "trader") end
	check("the role word is not re-translated per NPC", translated == before,
		tostring(translated - before) .. " lookups for 20 resets")
	CFG.map_spot_names = false; M.apply_config()
	CFG.map_spot_names = true;  M.apply_config()
	reset(1, "trader")
	check("...but a config change re-reads them (covers a language change)",
		translated > before)
end

-- ------------------------------------------------------- wrapping never stacks
-- The save-load case: the .script files are re-read, so a SECOND module instance
-- installs itself over the first. The vanilla function it must end up calling is the
-- real one, not the first wrapper -- which is what the field on stalker_generic
-- carries across the reload.
--
-- LAST, AND IT HAS TO BE. Installing M2 makes M2 the live wrapper, with its own `seen`
-- and its own `on`, while `M` above keeps the handle the earlier blocks drive
-- apply_config through. Any behaviour test placed after this one would be asserting
-- against one instance's state while another instance's wrapper was doing the work --
-- which is not a bug in the module, only a harness driving two of them at once. The
-- translation-cache block above was written after this one, and failed for that reason.
do
	local M2 = load_module()
	M2.on_game_start()
	M2.apply_config()
	reset(1, "trader")
	check("a second install does not double-compose the hint",
		hint(1, "ui_pda2_trader_location") == "Sidorovich - Trader",
		tostring(hint(1, "ui_pda2_trader_location")))
	check("the vanilla original is still reachable underneath",
		ENV.stalker_generic.iqm_spothint_original ~= nil)
	check("...and it is reached exactly once per reset", (function()
		local before = vanilla_calls
		reset(2, "mechanic")
		return vanilla_calls == before + 1
	end)())

	local M3 = load_module()   -- a third, for luck: the guard is not a one-shot
	M3.on_game_start()
	M3.apply_config()
	reset(2, "mechanic")
	check("nor does a third", hint(2, "ui_pda2_mechanic_location") == "Cardan - Technician",
		tostring(hint(2, "ui_pda2_mechanic_location")))
end

-- --------------------------------------------------- the source still says so
do
	local src = slurp("gamedata/scripts/iqm_spothint.script")

	-- The four rows must be the vanilla pairs, spot AND legend. A typo in either is
	-- invisible in game: a wrong spot type simply never matches, and a wrong legend id
	-- reverts to a tooltip reading "st_ui_pda_legend_trder".
	for role, row in pairs(VANILLA) do
		local named = src:find(string.format('spot = "%s"', row.spot), 1, true) ~= nil
		if row.ours then
			check(role .. "'s spot type is in the table", named)
			check(role .. "'s legend id is the vanilla one",
				src:find(row.legend, 1, true) ~= nil)
		else
			check(role .. "'s spot type is NOT in the table", not named)
			check("...nor its legend id", src:find(row.legend, 1, true) == nil)
		end
	end

	-- The rows must stay in vanilla's if/elseif order, which is what makes first-hit-wins
	-- agree with the game rather than merely being deterministic.
	do
		local ORDER = { "special", "trader", "mechanic", "guider", "barman", "quest_npc", "medic" }
		local at, ok = 0, true
		for _, role in ipairs(ORDER) do
			local i = src:find(string.format('spot = "%s"', VANILLA[role].spot), 1, true)
			if not i or i < at then ok = false end
			at = i or at
		end
		check("the rows are in vanilla's own order", ok)
	end

	-- The original is called OUTSIDE the pcall. Written as a source check because the
	-- runtime test above ("an error from vanilla is NOT swallowed") passes just as well
	-- if the call is inside a pcall that rethrows -- and the next person to add a guard
	-- would have no way to know which shape was meant.
	local wrapper = src:match("local function reset_show_spot.-\nend\n")
	check("the wrapper exists to be inspected", wrapper ~= nil)
	if wrapper then
		local call_at  = wrapper:find("original(npc, scheme, st, section)", 1, true)
		local pcall_at = wrapper:find("pcall(", 1, true)
		check("vanilla is called before the guard opens",
			call_at ~= nil and pcall_at ~= nil and call_at < pcall_at)
	end

	-- The revert path must write the ID. `stamp` is the only writer, so the check is
	-- that its off-branch passes row.legend and not a translation of it.
	check("the off branch writes the legend id",
		src:find("level.map_change_spot_hint(id, row.spot, row.legend)", 1, true) ~= nil)

	-- The wrapper must record service NPCs whether or not it stamps them (see 4 above).
	check("seen is written outside the on/off test",
		src:find("seen%[id%] = row%s*\n%s*stamp%(id, row%)") ~= nil)

	-- iqm_core must actually pull this module's config, or the option is inert.
	check("iqm_core pulls this module's apply_config",
		slurp("gamedata/scripts/iqm_core.script")
			:find("iqm_spothint.apply_config()", 1, true) ~= nil)
	check("...and the option is registered",
		slurp("gamedata/scripts/iqm_core.script")
			:find('key = "map_spot_names"', 1, true) ~= nil)
end

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
