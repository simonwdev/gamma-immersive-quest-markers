-- Harness: the service classifier's EVIDENCE TIERS, checked outside the game.
--
-- WHY THIS EXISTS. Reported from play (R2.36): Arnie, the Rostok arena manager, showed a
-- VIP icon on the PDA map and a TRADER glyph on his waypoint marker. He sells nothing.
--
-- The cause was one signal being trusted too far. `<community>trader</community>` in a
-- character profile is not a job -- it is the relations bucket meaning "neutral, in no
-- faction" -- and roughly half the vanilla profiles carrying it sell nothing at all.
-- service_role treated it as proof of a shop, and extras_scan_one let that proof overrule
-- the NPC's own authored `level_spot = special`.
--
-- The fix is a tier, not a deletion: the community signal still classifies an NPC nobody
-- else has said anything about (any signal beats silence, and a stray card is cheap), but
-- it may no longer contradict the game about its own character. That distinction lives in
-- two places -- a second return from service_role and one condition in extras_scan_one --
-- and neither is self-evident when read alone, which is why it is pinned here.
--
-- The fixtures are REAL. Every row is transcribed from the shipped configs, with the file
-- and line it came from, so this is a test against the game rather than against my memory
-- of it. Arnie and Nimble are the two that matter: both carry `level_spot = special`, both
-- are community `trader`, and exactly one of them runs a shop. Any rule that separates
-- them has to do it on the evidence in these rows.
--
-- Usage:
--   python check_lua.py --run tools/service-harness/harness.lua
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

-- The source under test, read ONE FILE PER NAME rather than concatenated.
--
-- The tier rule spans two files: service_role and extras_scan_one live in iqm_scan,
-- and BEACON_ICON (the "important carries no marker" half) lives in iqm_beacon.
-- Both moved out of the old iqm_markers when it was split.
--
-- They are kept SEPARATE deliberately. A harness that greps one file for something
-- living in another does not fail, it passes vacuously -- and concatenating the
-- sources reintroduces exactly that hazard from the other side: every pattern would
-- then match against every file, so a rule migrating between them would keep passing
-- and the harness would stop being able to say where the rule actually is. Naming
-- the file per assertion is what makes a move fail loudly.
--
-- This file previously also read the old iqm_markers/iqm_core source, for nothing:
-- every pattern below had already moved, so that read contributed no bytes any
-- assertion depended on. It went unnoticed because a redundant source in a
-- concatenation is invisible -- which is the argument above, learned the hard way.
local scan_src   = slurp("gamedata/scripts/iqm_scan.script")
local beacon_src = slurp("gamedata/scripts/iqm_beacon.script")

-- ------------------------------------------------------- the model under test
-- service_role's decision, transcribed. Returns role, weak.
local function service_role(f)
	local sec = f.section
	if sec:find("guid") then return "guider" end
	local name_mech  = sec:find("mechanic") or sec:find("_tech") or sec:find("mech_mlr") or sec:find("mechan")
	local name_medic = sec:find("medic") or sec:find("medik") or sec:find("doctor")
	-- job evidence...
	local name_trade = sec:find("trader") or sec:find("barm[ae]n") or f.trader_clsid
	-- ...and relations-bucket evidence, which is not the same thing
	local comm_trade = f.community == "trader"
	local cat = f.trade

	if cat and cat:find("companion") then return nil end
	if cat and cat:find("trade_generic_mechanic") then return "mechanic" end
	if cat and cat:find("trade_generic_barman")   then return "barman" end
	if cat and cat:find("trade_generic_medic")    then return "medic" end
	if name_mech  then return "mechanic" end
	if name_medic then return "medic" end
	if cat or name_trade then return "trader" end
	if comm_trade then return "trader", true end
	return nil
end

-- extras_scan_one's use of it: what role the NPC ends up with.
-- `spot` is what spot_role returned (nil, "important", or a real service role).
local function classify(f)
	local role = f.spot
	if role == nil or role == "important" then
		local sr, weak = service_role(f)
		if sr and not (weak and role == "important") then return sr end
	end
	return role
end

-- Roles that can carry a waypoint marker. "important" cannot, and has not since R2.29 --
-- which is what makes "Arnie stays important" the same statement as "Arnie gets no marker".
local BEACONABLE = { guider = true, trader = true, mechanic = true, barman = true, medic = true }

-- ------------------------------------------------------------- the fixtures
local NPCS = {
	{ who = "Arnie (arena manager)", section = "bar_arena_manager",
	  community = "trader", trade = nil, spot = "important",
	  -- bar_visitors_logic.ltx:457 `[logic@bar_arena_manager]` ... `level_spot = special`,
	  -- character_desc_bar.xml:467 `<community>trader</community>`, and no trade= anywhere.
	  want = "important", marker = false },

	{ who = "Bar informant", section = "bar_informator_mlr",
	  community = "trader", trade = nil, spot = "important",
	  -- bar_visitors_other_logic.ltx:41-47, same shape as Arnie: special spot, no trade=.
	  want = "important", marker = false },

	{ who = "Nimble", section = "zat_a2_stalker_nimble",
	  community = "trader", trade = "items\\trade\\trade_stalker_nimble.ltx", spot = "important",
	  -- zat_a2_stalker_nimble.ltx:5-6 -- special spot AND a real catalog. The control case:
	  -- the override must survive for him or the whole fallback was pointless.
	  want = "trader", marker = true },

	{ who = "Warlab pod stalker", section = "warlab_pod_1_stalker",
	  community = "trader", trade = nil, spot = nil,
	  -- character_desc_warlab.xml, community trader, no spot at all. Nobody has said
	  -- anything about this NPC, so the weak signal is still allowed to: a stray trader
	  -- card is the documented cost of that tier. Pinned so the behaviour is a decision
	  -- rather than a surprise.
	  want = "trader", marker = true },

	{ who = "Cardan (technician)", section = "bar_visitors_cardan_tech",
	  community = "stalker", trade = nil, spot = "important",
	  -- "_tech" is job evidence, so it may overrule a VIP spot.
	  want = "mechanic", marker = true },

	{ who = "Bar guide", section = "guid_bar_stalker_navigator",
	  community = "stalker", trade = nil, spot = "important",
	  want = "guider", marker = true },

	{ who = "dialog-trade merc", section = "dm_init_trader_merc",
	  community = "killer", trade = nil, spot = "important",
	  -- the case the fallback was built for: no catalog, no service spot, but "trader" in
	  -- the section. Job evidence, so it still wins. Note the community is killer, so the
	  -- weak signal was never what caught these.
	  want = "trader", marker = true },

	{ who = "plain VIP", section = "bar_dolg_leader",
	  community = "dolg", trade = nil, spot = "important",
	  want = "important", marker = false },

	{ who = "ordinary stalker", section = "bar_visitors_animp_01",
	  community = "stalker", trade = nil, spot = nil,
	  want = nil, marker = false },
}

for _, f in ipairs(NPCS) do
	local got = classify(f)
	check(f.who .. " -> " .. tostring(f.want), got == f.want,
	      "got " .. tostring(got))
	check(f.who .. (f.marker and " gets a marker" or " gets NO marker"),
	      (got ~= nil and BEACONABLE[got] == true) == f.marker)
end

-- --------------------------------------------------- the rule, stated directly
-- Arnie and Nimble differ in exactly one field. That is the whole fix, so assert it as a
-- pair rather than only as two independent rows.
do
	local arnie  = NPCS[1]
	local nimble = NPCS[3]
	check("Arnie and Nimble differ only in the catalog",
	      arnie.community == nimble.community and arnie.spot == nimble.spot
	      and arnie.trade == nil and nimble.trade ~= nil)
	check("...and that is enough to tell them apart",
	      classify(arnie) ~= classify(nimble))

	-- the community signal alone must never overrule a VIP spot...
	local weak_vip = { section = "someone", community = "trader", trade = nil, spot = "important" }
	check("community alone cannot overrule a VIP spot", classify(weak_vip) == "important")
	-- ...but must still fill a silence
	local weak_gap = { section = "someone", community = "trader", trade = nil, spot = nil }
	check("community alone still fills a gap", classify(weak_gap) == "trader")
	-- and service_role must report which it was
	check("the community verdict is flagged weak", select(2, service_role(weak_gap)) == true)
	check("a catalog verdict is not flagged weak", select(2, service_role(nimble)) == nil)
end

-- ------------------------------------------------ the source still says so
do
	check("service_role splits job evidence from the community",
	      scan_src:find("local comm_trade = char_comm(obj) == \"trader\"", 1, true) ~= nil,
	      "the community test is no longer separated out")
	-- An ABSENCE check, so it is the one assertion a wrong file makes weaker rather
	-- than louder: greping a source the code never lived in would pass it for free.
	check("the community signal no longer sits inside name_trade",
	      scan_src:find("or char_comm(obj) == \"trader\"", 1, true) == nil)
	check("the weak verdict is returned",
	      scan_src:find("elseif comm_trade then r = \"trader\"; weak = true", 1, true) ~= nil)
	check("weakness is cached alongside the role",
	      scan_src:find("_sweak[id] = weak", 1, true) ~= nil)
	check("the cached path returns it too",
	      scan_src:find("return r or nil, _sweak[id]", 1, true) ~= nil)
	check("the override is guarded",
	      scan_src:find("if sr and not (weak and role == \"important\") then", 1, true) ~= nil,
	      "extras_scan_one would let a weak verdict overrule a VIP spot again")
	-- and "important" must still carry no marker, or "Arnie stays important" stops
	-- meaning "Arnie loses his marker". Matched in iqm_beacon and nowhere else: the
	-- table is that module's, and finding it anywhere else would mean two copies.
	local icons = beacon_src:match("local BEACON_ICON = {(.-)\n}")
	check("BEACON_ICON is still where this harness thinks it is", icons ~= nil,
	      "the table moved or changed shape -- every check below it is now blind")
	check("important is still not a marker role",
	      icons ~= nil and icons:find("important") == nil)
end

-- ==================================================================== spot_role
-- The PDA-spot lookup, and the ONE THING ABOUT IT THAT IS EASY TO BREAK SILENTLY.
--
-- spot_role used to ask level.map_has_object_spot once per ROLE_SPOTS row and return on
-- the first yes, so precedence came free from the array order. It now asks
-- level.map_get_object_spots_by_id ONCE and matches the reply against the table -- seven
-- registry round trips per NPC down to one, which on a hub full of stalkers carrying no
-- service spot at all is seven misses per NPC per pass down to one.
--
-- The reply arrives in the ENGINE'S order, which says nothing about ours. Iterating it
-- and taking the first recognised hit would hand the precedence to the registry, and the
-- symptom -- a trader who also carries a quest_npc spot carding as a plain VIP -- would
-- depend on internal ordering and turn up for one player and not the next. So the code
-- takes the LOWEST ROLE_SPOTS index instead, and this section pins that by checking the
-- new form against the old loop for EVERY ordering the engine could produce.

-- ROLE_SPOTS, transcribed. Order is the precedence.
local ROLE_SPOTS = {
	{ spot = "ui_pda2_scout_location",     role = "guider",    opt = "mark_guiders" },
	{ spot = "ui_pda2_trader_location",    role = "trader",    opt = "mark_traders" },
	{ spot = "ui_pda2_mechanic_location",  role = "mechanic",  opt = "mark_traders" },
	{ spot = "ui_pda2_barman_location",    role = "barman",    opt = "mark_traders" },
	{ spot = "ui_pda2_medic_location",     role = "medic",     opt = "mark_traders" },
	{ spot = "ui_pda2_special_location",   role = "important", opt = "mark_important" },
	{ spot = "ui_pda2_quest_npc_location", role = "important", opt = "mark_important" },
}
local ROLE_BY_SPOT = {}
for i, e in ipairs(ROLE_SPOTS) do e.order = i; ROLE_BY_SPOT[e.spot] = e end

-- THE ORACLE: the old seven-query loop, driven by a set of the spots the NPC carries.
-- This is the behaviour being preserved, so it is written out independently rather than
-- expressed in terms of the new one.
local function spot_role_loop(has)
	for _, e in ipairs(ROLE_SPOTS) do
		if has[e.spot] then return e.role, e.opt end
	end
end

-- THE NEW FORM: fed the engine's reply, a list of {spot_type=, text=} in ITS order.
local function spot_role_one_call(list)
	local best
	for _, s in pairs(list) do
		local e = type(s) == "table" and s.spot_type and ROLE_BY_SPOT[s.spot_type]
		if e and (best == nil or e.order < best.order) then best = e end
	end
	if best then return best.role, best.opt end
end

-- ...and the dispatcher, including the fallback branch. A non-table `reply` models an
-- engine build with no map_get_object_spots_by_id at all.
local function spot_role(has, reply)
	if type(reply) ~= "table" then return spot_role_loop(has) end
	return spot_role_one_call(reply)
end

-- every ordering of a list
local function permutations(t)
	local out = {}
	local function go(prefix, rest)
		if #rest == 0 then out[#out + 1] = prefix; return end
		for i = 1, #rest do
			local nxt, sub = {}, {}
			for j = 1, #prefix do nxt[j] = prefix[j] end
			nxt[#nxt + 1] = rest[i]
			for j = 1, #rest do if j ~= i then sub[#sub + 1] = rest[j] end end
			go(nxt, sub)
		end
	end
	go({}, t)
	return out
end

local function reply_of(order)          -- spot types -> the engine's {spot_type=,text=} shape
	local r = {}
	for i, s in ipairs(order) do r[i] = { spot_type = s, text = "" } end
	return r
end
local function set_of(list)
	local h = {}
	for _, s in ipairs(list) do h[s] = true end
	return h
end

-- ---------------------------------------------------- ordering-independence
-- Multi-spot NPCs, each a real shape: a trader whose logic also flags him a story
-- character, a guide who is also a shopkeeper, a mechanic on a quest, and the
-- four-spot case nobody authored but the table permits.
local MULTI = {
	{ "ui_pda2_trader_location",   "ui_pda2_quest_npc_location" },
	{ "ui_pda2_special_location",  "ui_pda2_trader_location" },
	{ "ui_pda2_scout_location",    "ui_pda2_trader_location" },
	{ "ui_pda2_mechanic_location", "ui_pda2_quest_npc_location" },
	{ "ui_pda2_special_location",  "ui_pda2_quest_npc_location" },
	{ "ui_pda2_medic_location",    "ui_pda2_barman_location", "ui_pda2_special_location" },
	{ "ui_pda2_scout_location",    "ui_pda2_medic_location", "ui_pda2_trader_location",
	  "ui_pda2_quest_npc_location" },
}

for _, combo in ipairs(MULTI) do
	local has = set_of(combo)
	local want_role, want_opt = spot_role_loop(has)
	local label = table.concat(combo, "+"):gsub("ui_pda2_", ""):gsub("_location", "")
	local bad = nil
	for _, order in ipairs(permutations(combo)) do
		local r, o = spot_role(has, reply_of(order))
		if r ~= want_role or o ~= want_opt then
			bad = table.concat(order, ",") .. " -> " .. tostring(r)
			break
		end
	end
	check(label .. " -> " .. tostring(want_role) .. ", in every engine ordering",
	      bad == nil, bad)
	-- and the fallback branch of the same call must agree with itself
	local fr, fo = spot_role(has, nil)
	check(label .. " -> same answer with map_get_object_spots_by_id absent",
	      fr == want_role and fo == want_opt, "got " .. tostring(fr))
end

-- Both orderings of every PAIR of spot types, which is where a precedence bug would
-- actually live: 21 pairs, each way round.
do
	local bad, pairs_done = nil, 0
	for i = 1, #ROLE_SPOTS do
		for j = i + 1, #ROLE_SPOTS do
			local a, b = ROLE_SPOTS[i].spot, ROLE_SPOTS[j].spot
			local has = set_of({ a, b })
			local want_role, want_opt = spot_role_loop(has)
			pairs_done = pairs_done + 1
			for _, order in ipairs({ { a, b }, { b, a } }) do
				local r, o = spot_role(has, reply_of(order))
				if r ~= want_role or o ~= want_opt then
					bad = a .. "/" .. b .. " as " .. table.concat(order, ",")
					       .. " -> " .. tostring(r) .. " wanted " .. tostring(want_role)
				end
			end
		end
	end
	check("every pair of spots, both ways round, matches the old loop", bad == nil, bad)
	check("...and that was all 21 pairs", pairs_done == 21, tostring(pairs_done))
	-- The earlier row wins, stated directly rather than only through the oracle: a
	-- trader who is also a quest_npc is a TRADER, which is what the ordering is for.
	check("trader beats quest_npc whichever way the engine lists them",
	      spot_role_one_call(reply_of({ "ui_pda2_quest_npc_location", "ui_pda2_trader_location" })) == "trader"
	      and spot_role_one_call(reply_of({ "ui_pda2_trader_location", "ui_pda2_quest_npc_location" })) == "trader")
	check("guider outranks every trade spot", spot_role_one_call(reply_of(
	      { "ui_pda2_medic_location", "ui_pda2_scout_location" })) == "guider")
end

-- ------------------------------------------------------------ single + empty
for _, e in ipairs(ROLE_SPOTS) do
	local has = set_of({ e.spot })
	local r, o = spot_role(has, reply_of({ e.spot }))
	check(e.spot .. " alone -> " .. e.role, r == e.role and o == e.opt, tostring(r))
end
do
	-- The common case, and the whole reason for the change: an NPC with no service
	-- spot. One call, no answer -- and the same no-answer on both paths.
	check("no spots -> nil (one-call)", spot_role({}, {}) == nil)
	check("no spots -> nil (fallback)", spot_role({}, nil) == nil)
	-- Unknown spot types are ignored, not counted: the registry holds far more than
	-- the seven this table names (stashes, level changers, other mods' pins).
	check("unrecognised spot types are ignored",
	      spot_role_one_call(reply_of({ "treasure", "level_changer" })) == nil)
	check("...and do not shadow a real one",
	      spot_role_one_call(reply_of({ "treasure", "ui_pda2_medic_location" })) == "medic")
	-- The guard target_covered uses, and this now shares: a non-table reply is not a
	-- reply. An engine that returns something else must reach the loop, not error.
	check("a non-table reply takes the fallback",
	      spot_role(set_of({ "ui_pda2_medic_location" }), false) == "medic")
end

-- ------------------------------------- the tier rule, driven through the new path
-- The fixtures above set `spot` by hand. Here the same verdicts are reached with
-- spot_role actually resolving it from a spot list, in both orderings and on the
-- fallback -- so a precedence regression cannot hide behind a hand-written `spot`.
-- The VIP fixtures carry `special`, which is where their "important" came from, and a
-- second quest_npc spot is added so the pair has to resolve to the same VIP.
local SPOT_FOR = { important = "ui_pda2_special_location" }
for _, f in ipairs(NPCS) do
	local spots = f.spot and { SPOT_FOR[f.spot] or error("no spot type for " .. f.spot) } or {}
	if f.spot == "important" then spots[#spots + 1] = "ui_pda2_quest_npc_location" end
	local has = set_of(spots)
	local variants = { { "one-call", reply_of(spots) }, { "fallback", nil } }
	if #spots == 2 then
		variants[#variants + 1] = { "reversed", reply_of({ spots[2], spots[1] }) }
	end
	for _, v in ipairs(variants) do
		local g = { section = f.section, community = f.community, trade = f.trade,
		            trader_clsid = f.trader_clsid, spot = spot_role(has, v[2]) }
		local got = classify(g)
		check(f.who .. " -> " .. tostring(f.want) .. " (" .. v[1] .. ")",
		      got == f.want, "got " .. tostring(got))
		check(f.who .. (f.marker and " gets a marker" or " gets NO marker") .. " (" .. v[1] .. ")",
		      (got ~= nil and BEACONABLE[got] == true) == f.marker)
	end
end

-- Arnie, specifically, through the new path: he carries special AND quest_npc in the
-- registry, and the one thing that must not happen is the one-call form resolving him
-- to anything but "important" and handing his weak community verdict the win.
do
	local role = spot_role_one_call(reply_of(
		{ "ui_pda2_quest_npc_location", "ui_pda2_special_location" }))
	check("Arnie still reads important off the registry", role == "important")
	check("...so the weak community verdict still cannot overrule it",
	      classify({ section = "bar_arena_manager", community = "trader",
	                 trade = nil, spot = role }) == "important")
	-- ...while a trader spot on the same NPC would, because that is a service spot
	-- rather than a VIP one and never reaches service_role at all.
	check("a real trader spot beats the VIP spot on the same NPC",
	      spot_role_one_call(reply_of(
	          { "ui_pda2_special_location", "ui_pda2_trader_location" })) == "trader")
end

-- ------------------------------------------------- the source still says so
do
	check("spot_role reads the whole-object query",
	      scan_src:find("local list = map_get_spots and map_get_spots(id)", 1, true) ~= nil,
	      "the one-call form is gone -- back to seven queries per NPC?")
	check("...guarded exactly as target_covered guards it",
	      scan_src:find("if type(list) ~= \"table\" then", 1, true) ~= nil)
	check("the per-spot loop survives as the fallback",
	      scan_src:find("if map_has_spot(id, e.spot) ~= 0 then return e.role, e.opt end", 1, true) ~= nil,
	      "builds without map_get_object_spots_by_id now classify nobody")
	check("precedence is carried on the row, not on the iteration order",
	      scan_src:find("e.order = i", 1, true) ~= nil
	      and scan_src:find("ROLE_BY_SPOT[e.spot] = e", 1, true) ~= nil)
	check("...and the lowest-index row is what wins",
	      scan_src:find("if e and (best == nil or e.order < best.order) then best = e end", 1, true) ~= nil,
	      "first-hit-wins has been handed back to the engine's ordering")
	check("both return values survive",
	      scan_src:find("if best then return best.role, best.opt end", 1, true) ~= nil)
	check("the new engine function is bound like the others, not read at file scope",
	      scan_src:find("map_get_spots = level.map_get_object_spots_by_id", 1, true) ~= nil)
end

-- ============================================================ cache lifetimes
-- alife RECYCLES OBJECT IDS. Every cache in iqm_scan keyed by one therefore has to be
-- dropped when the level is, or a released squad's `_srole[id] = "medic"` is inherited
-- by whatever takes the id next -- and service_role answers from the cache before it
-- re-derives anything, so the wrong glyph comes back with nothing to notice it by.
--
-- The other half of the rule matters just as much: the TASK-keyed caches are keyed by
-- task section id, which is authored text, not a recycled handle. Wiping those would be
-- a self-inflicted cost -- re-running functor walks and stage probes for answers that
-- were already right -- so this asserts they are LEFT ALONE as firmly as it asserts the
-- others are cleared.
do
	local body = scan_src:match("local function drop_npc_caches%(%)\n(.-)\nend\n")
	check("drop_npc_caches is where this harness thinks it is", body ~= nil,
	      "the wipe moved or changed shape -- every check below it is now blind")

	local WIPE = { "recruit_static", "_ttype", "_srole", "_sweak" }
	for _, name in ipairs(WIPE) do
		check(name .. " is dropped on a level change",
		      body ~= nil and body:find(name .. "%s*[,=]") ~= nil,
		      "an id-keyed cache survives the transition that recycles its keys")
	end
	-- the placed waypoint's cached target is an object id too
	check("the waypoint's cached target is dropped with them",
	      body ~= nil and body:find("wp_target", 1, true) ~= nil)

	local KEEP = { "kind_seen", "kind_next", "functor_cache", "stage_complete_cache",
	               "open_kind", "open_tgt" }
	for _, name in ipairs(KEEP) do
		check(name .. " is task-keyed and survives",
		      body ~= nil and body:find(name, 1, true) == nil,
		      "a task-section-keyed cache is being thrown away for no reason")
	end

	check("the wipe is wired to the level change",
	      scan_src:find("RegisterScriptCallback(\"on_level_changing\", reset)", 1, true) ~= nil,
	      "iqm_scan registers nothing again, and the caches never clear")
	check("...and reset() is what runs it, so an option change clears them too",
	      scan_src:find("function reset()\n\tscanner_reset(companion_scanner)\n"
	                    .. "\tscanner_reset(extras_scanner)\n\tdrop_npc_caches()\nend", 1, true) ~= nil)
	-- The published scanner sets are [id] = role, so they are recycled state as well.
	check("the scanners are re-armed on the same event",
	      scan_src:find("scanner_reset(extras_scanner)", 1, true) ~= nil)
end

-- ------------------------------------------------------------------ verdict
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
