-- Harness: the recruit offer has to EXIST before its preconditions matter.
--
-- WHY THIS EXISTS. Reported from play (R2.60): the Bar's guide showed the GUIDE nameplate
-- for a second or two and then flipped to LOOKING FOR WORK and stayed there. Talking to
-- him confirmed there was no recruit line in his dialogue at all.
--
-- The cause was a category error in npc_recruitable_impl. It reproduces every
-- `<precondition>` of GAMMA's recruit dialogues faithfully -- and a precondition only
-- decides whether an ATTACHED dialogue is offered. Attachment is per PROFILE, via
-- `<actor_dialog>` entries in the NPC's `specific_character` block: generic stalkers pick
-- friendly_companion_dialog up from the shared include character_dialogs.xml, and a
-- hand-authored profile names its dialogues itself and never includes that file. For such
-- an NPC there is no recruit dialogue, so not one of the mirrored preconditions ever runs,
-- and every squad-level gate we do check passes on its own merits.
--
-- The damage was not merely a stray card. ROLE_PRIO.companion is 3 and `guider` is 6, so
-- the phantom offer EVICTED the true GUIDE card -- the one fact you walk up to a guide for.
-- That is why the fix belongs in the predicate and not in the ranking: ranking `guider`
-- above `companion` would have hidden this symptom while leaving the phantom in place for
-- every other bespoke profile.
--
-- THE FIXTURES ARE REAL, and two of them are transcribed from the LIVE game rather than
-- from config, which matters here: the engine hands the profile's dialogue list to Lua at
-- load time and writes back whatever comes out (specific_character.cpp:130-154), so mods
-- add and remove entries. Navigator's row carries northern_news_dialog, which is in no
-- character_desc file -- COFG injects it through on_specific_character_dialog_list. A
-- fixture taken only from the xml would have missed that the list is mutable, and with it
-- the reason profile_offers reads the engine's list instead of the config.
--
-- Usage:
--   python check_lua.py --run tools/recruit-harness/harness.lua
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

local scan_src = slurp("gamedata/scripts/iqm_scan.script")

-- ------------------------------------------------------- the model under test
-- profile_offers, transcribed: which recruit dialogues this NPC's profile carries.
-- Only the BASE ids are read. G_FLAT's IRC adds friendly_companion_dialog_individually
-- only `if dialog_list:has("friendly_companion_dialog")` and the paid variant only off
-- paid_companion_dialog, so the base id is present whenever either variant is --
-- necessary and sufficient for both, and still correct with IRC absent.
local DLG_FREE, DLG_PAID = "friendly_companion_dialog", "paid_companion_dialog"

local function profile_offers(dialogs)
	local free, paid = false, false
	for _, d in ipairs(dialogs) do
		if d == DLG_FREE then free = true elseif d == DLG_PAID then paid = true end
	end
	return free, paid
end

-- actor_strong_enough, transcribed. BOTH free variants gate on actor strength (R2.63) --
-- the solo one on IRC's get_is_actor_stronger_if_script_is_available, the whole-squad one
-- on grok_get_companions.is_actor_stronger, which GAMMA's winning dialogs.xml (Quests
-- Rebalance) lists and stock Anomaly's does not. The two functions compute the same rank
-- comparison, so one `stronger` field per fixture drives either shape; what differs is
-- which mod's absence removes the gate, and `gate_absent` is how a row says that.
local function actor_strong_enough(f)
	if f.gate_absent then return true end
	return f.stronger ~= false            -- fixtures that predate the gate are strong
end

-- npc_recruitable_impl's branch selection, reduced to the part under test: the two
-- feature switches and relation gates decide which branches are eligible, the profile
-- decides which ones can exist at all, free beats paid when both survive, and the free
-- branch must still clear the strength gate for the variant it would be offered through.
-- `squad_ok` folds together every gate this harness is not about (story, room, shape,
-- tier, affordability) so a row can say "everything else passed" in one field.
local function recruit_role(f)
	local free = f.mark_companions and f.rel == "friend"
	local paid = f.mark_hires and f.rel == "neutral"
	if not (free or paid) then return nil end
	local dlg_free, dlg_paid = profile_offers(f.dialogs)
	if free and not dlg_free then free = false end
	if paid and not dlg_paid then paid = false end
	if not (free or paid) then return nil end
	if not f.squad_ok then return nil end
	if free and actor_strong_enough(f) then return "companion" end
	if paid then return "hire" end
	return nil
end

-- ------------------------------------------------------------- the fixtures
-- The shared include every generic stalker profile pulls in:
-- _unpacked\configs\gameplay\character_dialogs.xml -- both recruit dialogues.
local GENERIC = { "dm_init_stalker_trade", "dm_sim_ordered_task_cancel_dialog",
                  "dm_sim_ordered_task_completed_dialog", "dm_sim_ordered_task_dialog",
                  "dm_delivery_dialog", "dm_guide_job", "friendly_companion_dialog",
                  "friendly_companion_dialog_hostage_version", "dm_is_actor_companion_dialog",
                  "dm_companion_patrol", "dm_companion_leave", "dm_universal_dialog",
                  "paid_companion_dialog", "actor_break_dialog" }

-- ...and its sibling, character_dialogs_no_guide.xml, which carries the FREE recruit
-- dialogue and NOT the paid one (included by e.g. character_desc_bar.xml:195). This is
-- why the gate is per branch rather than one "is recruitable at all" boolean: a profile
-- really can carry one offer and not the other, so a single flag would either invent the
-- paid card for these NPCs or suppress their genuine free one.
local NO_GUIDE = { "friendly_companion_dialog", "friendly_companion_dialog_hostage_version",
                   "dm_is_actor_companion_dialog", "dm_companion_patrol", "dm_companion_leave",
                   "dm_universal_dialog", "actor_break_dialog" }

-- The Bar guide, read out of the running game (id 19176, l05_bar) rather than the xml.
-- character_desc_bar.xml lists the first three and actor_break_dialog; northern_news_dialog
-- is COFG's, injected at load. Neither recruit dialogue is present by either route.
local NAVIGATOR = { "meet_guid_bar", "travel_guid_bar", "meet_guid_bar_list",
                    "northern_news_dialog", "actor_break_dialog" }

local NPCS = {
	{ who = "Bar guide (guid_bar_stalker_navigator)", dialogs = NAVIGATOR,
	  mark_companions = true, mark_hires = true, rel = "friend", squad_ok = true,
	  -- THE REGRESSION. Every squad gate passes -- non-story squad, friendly, room, solo,
	  -- actor stronger -- and the answer must still be nil, because there is no dialogue.
	  want = nil },

	{ who = "Bar guide, offered as paid", dialogs = NAVIGATOR,
	  mark_companions = true, mark_hires = true, rel = "neutral", squad_ok = true,
	  want = nil },

	{ who = "generic stalker, friendly", dialogs = GENERIC,
	  mark_companions = true, mark_hires = true, rel = "friend", squad_ok = true,
	  -- The control case. If the gate suppresses this one the fix has eaten the feature.
	  want = "companion" },

	{ who = "generic stalker, neutral", dialogs = GENERIC,
	  mark_companions = true, mark_hires = true, rel = "neutral", squad_ok = true,
	  want = "hire" },

	{ who = "no_guide profile, friendly", dialogs = NO_GUIDE,
	  mark_companions = true, mark_hires = true, rel = "friend", squad_ok = true,
	  want = "companion" },

	{ who = "no_guide profile, neutral (no paid dialogue)", dialogs = NO_GUIDE,
	  mark_companions = true, mark_hires = true, rel = "neutral", squad_ok = true,
	  -- The per-branch split, asserted where it bites: free is attached, paid is not.
	  want = nil },

	{ who = "generic stalker, squad gates fail", dialogs = GENERIC,
	  mark_companions = true, mark_hires = true, rel = "friend", squad_ok = false,
	  -- The dialogue gate must not become the ONLY gate.
	  want = nil },

	{ who = "generic stalker, feature off", dialogs = GENERIC,
	  mark_companions = false, mark_hires = false, rel = "friend", squad_ok = true,
	  want = nil },

	-- ---------------------------------------------------------------- R2.63
	-- Yury Ryazansky, read out of the running game (id 28815, l07_military): a merc in a
	-- multi-member squad, friendly, non-story, room for him, every mirrored gate green --
	-- and actor rank 6314 against his 9905 * 1.5, so grok_get_companions.is_actor_stronger
	-- is false and neither free variant is offered. He was carded LOOKING FOR WORK, and
	-- talking to him had no recruit line, because the strength gate was applied to the
	-- solo variant only.
	{ who = "whole-squad recruit, actor weaker", dialogs = GENERIC, shape = "squad",
	  mark_companions = true, mark_hires = false, rel = "friend", squad_ok = true,
	  stronger = false, want = nil },

	{ who = "whole-squad recruit, actor stronger", dialogs = GENERIC, shape = "squad",
	  mark_companions = true, mark_hires = false, rel = "friend", squad_ok = true,
	  stronger = true,
	  -- The control: fixing the gate must not cost the card everyone else gets.
	  want = "companion" },

	{ who = "solo recruit, actor weaker", dialogs = GENERIC, shape = "solo",
	  mark_companions = true, mark_hires = false, rel = "friend", squad_ok = true,
	  -- Never broken; here so a fix that moved the gate rather than widening it fails.
	  stronger = false, want = nil },

	{ who = "whole-squad recruit, grok absent (no such precondition)", dialogs = GENERIC,
	  shape = "squad", mark_companions = true, mark_hires = false, rel = "friend",
	  squad_ok = true,
	  -- Without Quests Rebalance the dialogue has no strength line and the function that
	  -- would answer it is gone with it. A missing gate passes; it must not block.
	  stronger = false, gate_absent = true, want = "companion" },

	{ who = "paid escort is not strength-gated", dialogs = GENERIC, shape = "squad",
	  mark_companions = true, mark_hires = true, rel = "neutral", squad_ok = true,
	  -- paid_companion_dialog lists no is_actor_stronger, in either variant. A gate
	  -- applied to the whole recruit predicate rather than its free branch fails here.
	  stronger = false, want = "hire" },
}

for _, f in ipairs(NPCS) do
	local got = recruit_role(f)
	check(f.who .. " -> " .. tostring(f.want), got == f.want, "got " .. tostring(got))
end

-- ------------------------------------------- the eviction this actually prevented
-- Restated from iqm_scan's ROLE_PRIO, because the bug's damage was a PRECEDENCE outcome
-- and "returns nil" does not say it. The guide is found by both scanners; whichever role
-- survives the recruit predicate is the one that takes the card.
do
	local PRIO = { companion = 3, guider = 6 }
	local function card_role(recruit, service)
		if recruit and PRIO[recruit] <= PRIO[service] then return recruit end
		return service
	end
	check("guide keeps GUIDE once the phantom is gone",
	      card_role(recruit_role(NPCS[1]), "guider") == "guider")
	check("...and a real recruit offer still outranks a service role",
	      card_role("companion", "guider") == "companion")
end

-- ----------------------------------------------- the rule lives where we claim
-- Source-text assertions, for the failure mode a transcribed model cannot catch: the
-- model above stays green if the gate is deleted from the real file. These pin that
-- iqm_scan reads the engine's dialogue list and gates BOTH branches on the result.
do
	check("iqm_scan reads the engine's dialogue list",
	      scan_src:find("character_dialogs", 1, true) ~= nil,
	      "profile_offers must ask game_object:character_dialogs()")
	check("...and checks both base dialogue ids",
	      scan_src:find("friendly_companion_dialog", 1, true) ~= nil
	      and scan_src:find("paid_companion_dialog", 1, true) ~= nil)
	check("free branch is gated on the profile",
	      scan_src:find("if free and not f%.dlg_free then") ~= nil)
	check("paid branch is gated on the profile",
	      scan_src:find("if paid and not f%.dlg_paid then") ~= nil)
	-- The gate is memoized in recruit_static, not re-asked per pass: the list is
	-- per-profile shared data the engine parses once per process, so re-reading it every
	-- 3 seconds would build a throwaway Lua table per candidate for an unchanging answer.
	check("the answer is memoized with the other static facts",
	      scan_src:find("dlg_free%s*=%s*dlg_free") ~= nil)

	-- R2.63: the strength gate. Its whole failure mode was being reachable on one shape
	-- only, so "the function is called" is not the assertion -- the old code called it too.
	check("the whole-squad variant's precondition is named",
	      scan_src:find("grok_get_companions", 1, true) ~= nil,
	      "the base friendly_companion_dialog gates on grok_get_companions.is_actor_stronger")
	check("the free branch is gated unconditionally on strength",
	      scan_src:find("if free and actor_strong_enough%(actor, obj, shape%) then") ~= nil,
	      "the gate must not sit behind a shape test at the call site")
	-- The gate reads the actor's rank, which climbs, so caching it would strand the card.
	check("the strength answer is NOT memoized with the static facts",
	      scan_src:find("stronger%s*=") == nil)
end

-- ------------------------------------------------------------------- summary
print(string.format("  %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
