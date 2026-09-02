-- Harness: the placed waypoint's HANDOVER to an NPC marker (R2.38).
--
-- WHY THIS EXISTS. Two things share one condition, and getting it wrong is invisible.
--
-- PAW lets you place a waypoint directly on an NPC (valid_waypoint_target accepts
-- IsStalker), and get_current_waypoint() then returns that NPC's id. So the waypoint and
-- one of this mod's own markers can land on the same body. The mod stands the waypoint
-- marker down in that case -- one mark per body -- and, since R2.38, rings the NPC's own
-- marker so the information is not simply lost.
--
-- The condition deciding that used to be `tracked[wid] and beacon_roles[role]`, and it was
-- wrong in a way nothing would report as a crash: TRACKED is not MARKED. Quest targets are
-- tracked at any range while their marker still stops at beacon_dist, so waypointing a
-- quest giver 100 m off suppressed the waypoint marker in favour of an NPC marker that was
-- never drawn -- NOTHING on screen, from beacon_dist out to wherever that NPC goes offline,
-- on the one marker that is explicitly exempt from the range rule. The invariant below
-- ("something is always drawn") is the real subject of this file; the ring is the easy half.
--
-- What it checks:
--   1. NEVER NOTHING. Over every combination of range, role and tracked-ness, a placed
--      waypoint on an NPC always produces either the NPC's marker or the waypoint's own.
--   2. NEVER TWO. ...and never both at once on the same body.
--   3. THE RING. It appears on exactly the waypointed NPC's marker and nowhere else.
--   4. THE CARD STILL WINS. Inside marker range with the card up, the waypoint marker
--      stays down -- the card is what marks that body, and that has not changed.
--   5. THE SELECTED TASK OUTRANKS THE ROLE on its own body (R2.60a). Its mark is prio 0,
--      dressed by task KIND and exempt from beacon_dist, and none of that can be said by
--      the role marker -- so the role marker is the one that stands down there.
--   6. A DEAD OR OFFLINE BODY MARKS NOTHING. The suppression asks whether the role marker
--      can actually be drawn, not merely whether the role and the range allow it.
--   7. THE SOURCE. The range test, the ring flag and the ring's own geometry are read
--      back out of iqm_core, since 1-6 only prove the model.
--
-- Usage:
--   python check_lua.py --run tools/waypoint-harness/harness.lua
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

-- Read as ONE string across the files the handover now spans. R2.45's split put the
-- two halves of this rule in different places: the suppression test and the ring FLAG
-- are decided in the per-NPC loop (iqm_core), and the ring's geometry -- RING_K,
-- the badge metrics it is folded into, draw_beacon's signature -- is drawn by
-- iqm_cards. Grepping one file for the other's half passes vacuously, which is the
-- one way a mirror check can fail silently.
-- iqm_scan joins the span at R2.47: the hand-in gate's actual TEST is its
-- target_is_talk_to, while the switch that applies it is iqm_beacon's and the option is
-- iqm_core's. Three files, one rule -- which is exactly the shape this note is about.
local src = slurp("gamedata/scripts/iqm_core.script")
         .. slurp("gamedata/scripts/iqm_cards.script")
         .. slurp("gamedata/scripts/iqm_beacon.script")
         .. slurp("gamedata/scripts/iqm_scan.script")
local xml = slurp("gamedata/configs/ui/iqm_cards.xml")

-- ------------------------------------------------------- the model under test
local WP_NEAR  = 3.0
local BEACON_D = 60      -- beacon_d, the marker's own reach
local APPEAR_D = 16      -- appear_dist: where a card can be drawn at all
local OFFLINE  = 150     -- roughly where level.object_by_id stops answering

-- R2.60: `target` IS here again, on the beacon_targets switch (default on). R2.46 had
-- retired the turn-in role's marker when the SELECTED task got one of its own, which made
-- a quest giver a body the mod tracks and cards but does not mark -- exactly the shape
-- that opens the dead band, which is why this file had to change with it both times.
-- It came back because an UNSELECTED hand-in was handing its marker down to whatever
-- ambient role the same NPC had, so a quest giver who trades drew the trader glyph
-- through the wall while his card read REPORT BACK (iqm_scan's want_marker note).
--
-- `work` and `important` are still absent and always were, which is why §1 keeps sweeping
-- them: the dead band this file guards is a property of a markerless carded role, not of
-- `target` specifically, and switching beacon_targets back off returns `target` to that
-- set without returning the bug.
local BEACONABLE = { guider = true, trader = true, target = true,
                     mechanic = true, barman = true, medic = true }

-- What gets drawn on the waypointed NPC's body. `tracked` says the mod knows the NPC,
-- `card_up` that its card is currently showing, `is_task` that this body is also the
-- SELECTED task's target (so the two navigation marks have collapsed to one), and `gone`
-- that the body itself no longer answers -- dead, or off this level.
local function drawn(dist, role, tracked, card_up, is_task, gone)
	local out = { wp_marker = false, npc_marker = false, ring = false,
	              card = false, task_marker = false }
	-- A card cannot be up outside its own range, whatever the caller asked for, and a body
	-- that no longer answers has nothing to hang one on either.
	card_up = card_up and tracked and dist < APPEAR_D and not gone

	-- The ROLE marker's own preconditions, from the tracked loop. Its anchor comes from the
	-- live object, so `gone` withholds it; a card on the same body eases its alpha to zero and
	-- beacon_offer drops it, so `card_up` does; and `is_task` withholds it too, since R2.60a
	-- yields that body to the selected task's own mark (see 2b).
	local role_mark = (tracked and role and BEACONABLE[role] and dist < BEACON_D
	                   and not gone and not is_task and not card_up) or false

	-- `marked`, transcribed. The second clause is R2.46's: with no marker on the target
	-- role, beacon_roles alone stopped answering for a quest giver, and without an
	-- explicit card test the waypoint would draw straight over the card. It reads the
	-- CARD'S OWN STATE rather than `dist < APPEAR_D`, because in range is not the same as
	-- on screen -- the proxy blanked `work` and `important` at close range, which is how
	-- this file found it.
	--
	-- `not gone` IS THE R2.60a CLAUSE, and it is the R2.38 dead band arriving from a third
	-- direction: `tracked` keeps a body until the next scan prunes it, so a role marker in
	-- range could be claimed here for one scan interval after the NPC it belongs to stopped
	-- being drawable. `is_task` is deliberately NOT folded in -- the waypoint asks about
	-- every mark on the body, and the task's mark is one.
	local owned = (tracked and role
	               and ((BEACONABLE[role] and dist < BEACON_D and not gone) or card_up)) or false

	-- The selected task's marker, and the merge. Placing a waypoint selects its own task,
	-- so is_task is the COMMON case, not a corner: one mark is drawn and it is this one.
	--
	-- `card_up` ALONE for the task's mark, which is `carded` rather than `marked` (R2.60a):
	-- the role marker on this body has stood down for it, so consulting the role clause here
	-- would leave the body unmarked or, worse, hand the objective back at the role's priority.
	if is_task then
		if not card_up and dist >= WP_NEAR then out.task_marker = true end
	elseif not owned and dist >= WP_NEAR then
		out.wp_marker = true
	end

	-- ...and the NPC's own marker, from the tracked loop
	if role_mark then
		out.npc_marker = true
		out.ring = true                          -- id == wid, so it wears the ring
	elseif card_up then
		out.card = true                          -- the card marks the body instead
	end
	return out
end

-- --------------------------------------- 1 + 2. never nothing, and never two
do
	local none, both = nil, nil
	for dist = 4, OFFLINE, 2 do
		for _, role in ipairs{ "target", "medic", "trader", "guider", "important", "work" } do
			for _, tracked in ipairs{ true, false } do
				for _, card_up in ipairs{ true, false } do
					for _, is_task in ipairs{ true, false } do
						-- `gone` joins the sweep at R2.60a. A body the mod still tracks but can no
						-- longer anchor on is the case where the suppression and the draw disagree,
						-- and it is the one axis of this model that is not about the ROLE at all.
						for _, gone in ipairs{ true, false } do
							local d = drawn(dist, role, tracked, card_up, is_task, gone)
							local marks = (d.wp_marker and 1 or 0) + (d.npc_marker and 1 or 0)
							            + (d.card and 1 or 0) + (d.task_marker and 1 or 0)
							local where = string.format("%dm %s tracked=%s card=%s task=%s gone=%s",
							                            dist, role, tostring(tracked),
							                            tostring(card_up), tostring(is_task),
							                            tostring(gone))
							if marks == 0 then none = where end
							if marks > 1 then both = where end
						end
					end
				end
			end
		end
	end
	check("something is always drawn on a waypointed NPC", none == nil, none)
	check("never two marks on one body", both == nil, both)
end

-- the specific regression, called out by name so a failure names the bug
do
	local d = drawn(100, "target", true, false)
	check("a waypointed quest giver past marker range still shows something",
	      d.wp_marker, "the R2.38 dead band is back: tracked but not marked, so nothing draws")
	check("...and it is the waypoint's own marker", d.wp_marker and not d.npc_marker)

	-- R2.46 moved this case out and R2.60 moved it back. A quest giver carries a marker
	-- of its own again, so inside beacon_d the handover happens exactly as it does for a
	-- service NPC below -- the waypoint stands down and that NPC's marker wears the ring.
	-- Still exactly one mark at every distance, which is what the sweep above asserts.
	local n = drawn(30, "target", true, false)
	check("inside marker range a tracked quest giver takes over from the waypoint",
	      n.npc_marker and not n.wp_marker,
	      "beacon_targets should give the turn-in role a marker of its own again")
	check("...wearing the ring", n.ring)

	-- ...and the handover that DOES still happen, on a role that kept its marker
	local m = drawn(30, "medic", true, false)
	check("inside marker range a service NPC's marker takes over",
	      m.npc_marker and not m.wp_marker)
	check("...wearing the ring", m.ring)

	-- R2.60a: the same body, no longer answering. `tracked` outlives the NPC by up to one
	-- scan interval, and the role marker's anchor does not -- so a suppression that asked
	-- only about role and range claimed a mark nothing was drawing, which is the R2.38 dead
	-- band with a corpse in it instead of a distance.
	local g = drawn(30, "medic", true, false, false, true)
	check("a waypoint on a body that stopped answering still shows something",
	      g.wp_marker, "the marker's anchor needs a live object; the suppression must ask")
	check("...and the NPC's own marker is not the one claimed", not g.npc_marker)
end

-- ------------------------------------------ 2b. the waypoint / task merge (R2.46)
do
	-- Placing a waypoint SELECTS its own task, so these two are the same body by
	-- default. Exactly one mark must come out of that, and it must be the task's.
	local d = drawn(40, "target", false, false, true)
	check("merged: one mark, and it is the task's reticle",
	      d.task_marker and not d.wp_marker)

	-- WP_NEAR rides across with the identity: standing on your own waypoint still
	-- stands the mark down, selected task or not.
	check("merged: WP_NEAR still suppresses it",
	      not drawn(1.5, "target", false, false, true).task_marker)
	check("unmerged: WP_NEAR still suppresses the waypoint",
	      not drawn(1.5, "target", false, false, false).wp_marker)

	-- and the merge never resurrects the double-mark it exists to prevent -- though which
	-- of the two survives it changed at R2.60a. The SELECTED task's mark is now the one
	-- kept on a body that also holds a markered role: it is prio 0, it carries the task
	-- kind's dress, and it has no range gate, so letting the role's glyph win meant the
	-- mark changed colour and grew a name as the player walked in past beacon_dist -- and
	-- meant the objective competing on metres with every other turn-in in the hub.
	check("merged on a marked service NPC: exactly one mark",
	      (function() local m = drawn(18, "medic", true, false, true)
	                  return (m.task_marker and not m.npc_marker and not m.wp_marker) end)())
	check("...and it is the task's, not the role's",
	      drawn(18, "medic", true, false, true).task_marker,
	      "a role marker cannot state prio 0, the task kind or the range exemption")
	-- ...and the one thing it still yields to, on its own body: the card.
	check("the task's mark still stands down for the card on its body",
	      (function() local m = drawn(10, "medic", true, true, true)
	                  return m.card and not m.task_marker and not m.npc_marker end)())
	-- The selected task's target, dead or off-level, is exactly why `carded` is the test:
	-- goal_pos answers for an offline id and the tracked loop does not.
	check("...and is drawn even when the tracked loop can no longer anchor on the body",
	      drawn(40, "target", true, false, true, true).task_marker,
	      "asking the role clause here would blank the objective for a scan interval")
end

-- ------------------------------------- 2c. how the task marker is DRESSED (R2.48)
do
	-- offer_task's two lookups, transcribed. Both fall back independently, which is what
	-- makes a kind added later safe by default: it draws the ordinary reticle in the
	-- accent until somebody gives it art, rather than drawing nothing.
	local ICON = { task = "iqm_role_task", mutant = "iqm_role_skull" }
	local RGB  = { mutant = {176, 216, 72}, bounty = {214, 44, 60} }
	local function dress(kind)
		return (kind and ICON[kind]) or ICON.task, kind and RGB[kind] or nil
	end

	local i, c = dress(nil)
	check("no kind: the plain reticle in the accent", i == "iqm_role_task" and c == nil)
	i, c = dress("mutant")
	check("mutant: skull, acid lime", i == "iqm_role_skull" and c[1] == 176)
	i, c = dress("bounty")
	check("bounty: the SAME reticle, in red", i == "iqm_role_task" and c[1] == 214,
	      "a bounty is the go-find-it mark; only its colour differs")
	i, c = dress("something_new")
	check("unknown kind falls back on BOTH halves", i == "iqm_role_task" and c == nil,
	      "a kind with no art must draw the old mark, not an empty one")

	-- WORTH KNOWING, and not assertable here because it is a property of two rules
	-- meeting rather than of either: with the hand-in gate at its default the kind is
	-- always nil by the time a marker exists at all, since task_kind and the gate are
	-- opposite halves of one stage test. These glyphs are therefore a PDA-map feature at
	-- default settings (see tools/taskspot-harness) and a MARKER feature only with the
	-- gate switched off. Both halves earn their keep; neither is dead code.
end

-- ------------------------------------------------------------- 3. the ring
do
	-- only where the mod is actually drawing the NPC's marker
	check("no ring when the waypoint marker is the one drawn", not drawn(100, "target", true, false).ring)
	check("no ring on an untracked NPC", not drawn(30, "target", false, false).ring)
	check("no ring on a role that cannot be marked", not drawn(30, "important", true, false).ring)
	check("ring on a marked service NPC", drawn(18, "medic", true, false).ring)
	check("no ring on the selected task's own body", not drawn(18, "medic", true, false, true).ring,
	      "the role marker stands down there (R2.60a), and a ring belongs to a marker")
end

-- ------------------------------------------------------- 4. the card still wins
do
	local d = drawn(10, "medic", true, true)
	check("card up: no waypoint marker", not d.wp_marker)
	check("card up: no NPC marker either", not d.npc_marker)
	check("card up: the card is the mark", d.card)
end

-- -------------------------------------------------- 5. the source still says so
do
	check("the suppression is a range test, not just tracked-ness",
	      src:find("if beacon_roles[t.brole] and d < beacon_d then", 1, true) ~= nil,
	      "reverting this reopens the dead band")
	-- R2.60a: ...and the range test asks whether that marker can be DRAWN. The tracked loop
	-- anchors the role marker on the live object, so role-and-range alone claims a mark for a
	-- body that stopped answering, for as long as it takes the next scan to prune it.
	check("...and whether the body is still there to be marked",
	      src:find("local obj = get_obj(id)\n\t\tif obj and obj:alive() then return true end",
	               1, true) ~= nil,
	      "tracked outlives the NPC; the marker's anchor does not")
	-- R2.58: and it asks about the MARKER's role. Keyed on t.role this would answer "no
	-- marker" for a trader whose card role is target/work and let the waypoint draw over
	-- a marker that is in fact there -- the R2.38 bug arriving a third time.
	check("...on the marker's role, not the card's",
	      src:find("beacon_roles[t.role]", 1, true) == nil,
	      "see iqm_scan.want_marker: the card's role is not always the marker's")
	check("...and it asks about the CARD ITSELF, not about range",
	      src:find("return (f and f.card_up) or false", 1, true) ~= nil,
	      "without a card test a waypoint draws over the card of a body whose role carries "
	      .. "no marker -- work and important always, and target too whenever "
	      .. "beacon_targets is off; with `d < appear_d` instead of card_up it blanks "
	      .. "work/important at close range, which is the same dead band moved")
	check("the old tracked-only test is gone",
	      src:find("not (tracked[wid] and beacon_roles[tracked[wid].role])", 1, true) == nil)

	-- R2.46: the two navigation marks and their merge
	-- R2.60 reversed R2.46 here: the turn-in role has a marker again, on its own switch,
	-- so that an UNSELECTED hand-in stops handing its marker down to an ambient role on
	-- the same body. Asserted as the GATED form rather than merely "not nil" -- a bare
	-- `br.target = true` would mark every in-progress turn-in with no way to switch it
	-- off, which is the R2.46 complaint returning unswitched.
	check("the target role has a marker again, on beacon_targets",
	      src:find("br.target    = (bok and C.mark_targets and C.beacon_targets ~= false) or nil",
	               1, true) ~= nil,
	      "without it an unselected hand-in draws whatever else that NPC is -- a trader "
	      .. "glyph through the wall under a REPORT BACK card")
	check("...defaulting ON for players whose settings predate it",
	      src:find("C.beacon_targets ~= false", 1, true) ~= nil,
	      "a plain truth test reads nil as off and withholds the fix from every upgrader")
	check("the selected task has a marker of its own", src:find("function offer_task", 1, true) ~= nil)
	check("...sourced from the SELECTION, not the route's fallback",
	      src:find("task_target = iqm_core.active_task_target", 1, true) ~= nil
	      and src:find("task_target = iqm_core.route_target", 1, true) == nil,
	      "route_target falls back to the nearest turn-in, which is not the selected task")
	check("...and it wears the map's task reticle",
	      src:find('task     = "iqm_role_task"', 1, true) ~= nil)
	check("the merge is by id", src:find("local merged = (tid ~= nil and tid == wid)", 1, true) ~= nil)
	check("...and the task's mark is the one kept",
	      src:find("if not merged then offer_waypoint", 1, true) ~= nil,
	      "the waypoint offer must be the one skipped, not the task's")
	check("the merged mark keeps WP_NEAR",
	      src:find("if merged and td < WP_NEAR then return end", 1, true) ~= nil)
	-- R2.47: the hand-in gate. A difficulty setting, so the DEFAULT matters as much as the
	-- mechanism -- a player upgrading has no stored value for it.
	check("the task marker can be gated to hand-in stage",
	      src:find("_tk.id = (id and (handin or kind == \"delivery\" or not task_handin) and id) or false",
	               1, true) ~= nil)
	-- R2.56: the one kind the gate must NOT hold, and the reason it is asserted rather than
	-- left to the expression above. A delivery declares stage_complete = 2 and tasks_delivery
	-- only ever flips stage 0 and 1 -- it completes through dialog -- so `handin` is false for
	-- the whole life of every delivery and the gate could never open for one. Without this
	-- clause the marker was not late, it was unreachable: verified live in Rostok with two
	-- deliveries at stage 1, the recipient 18 m away and tracked, and no marker at any range.
	-- Deleting the clause silently restores that, which is exactly the shape of bug a source
	-- assertion is for.
	check("...but a DELIVERY is exempt, because that gate can never open for one",
	      src:find("kind == \"delivery\"", 1, true) ~= nil,
	      "a delivery never reaches its stage_complete, so gating it hides the marker for good")
	-- The exemption is only half an answer if the mark it lets through has no dress of its
	-- own: iqm_scan gave the deliver-to NPC its own role in R2.55 precisely so it would stop
	-- reading REPORT BACK, and a beacon falling back to BEACON_ICON.task would undo that in
	-- the other view.
	check("...and the exempt mark has an envelope to wear",
	      src:find('delivery  = "iqm_role_mail"', 1, true) ~= nil)
	check("...from the task's own stage_complete, not a functor blocklist",
	      src:find("talk_to = target_is_talk_to", 1, true) ~= nil
	      and src:find("task.stage >= sc", 1, true) ~= nil)
	check("...and the gate DEFAULTS ON for a player with no stored value",
	      src:find("task_handin  = C.beacon_handin ~= false", 1, true) ~= nil,
	      "a plain truth test reads nil as OFF and hands every existing user the OP behaviour")
	check("the gate is exposed in MCM", src:find('key = "beacon_handin"', 1, true) ~= nil)

	-- R2.48: the kind rides through to the marker's dress, and both lookups fall back.
	check("the kind reaches offer_task",
	      src:find("local tid, tpos, tkind, tcomm = task_goal()", 1, true) ~= nil
	      and src:find("offer_task(tid, tpos, td, carded(tid), merged, tkind, tcomm)",
	                   1, true) ~= nil)
	-- R2.60a, the two halves of the precedence on the selected task's own body. Either one
	-- alone is a bug: `marked` here demotes the objective to the role's priority, and a loop
	-- that does not skip the body draws a second mark on it.
	check("...and it defers to the CARD on its body, not to the role marker there",
	      src:find("local function carded(id)", 1, true) ~= nil
	      and src:find("offer_task(tid, tpos, td, marked(tid, td)", 1, true) == nil,
	      "with `marked` the role clause answers for that body since R2.60, so this offer "
	      .. "stands down and the mark comes back from the tracked loop at ROLE_PRIO.target "
	      .. "-- prio 1, tied with every other pending turn-in and broken on metres, which "
	      .. "is the eviction R2.39's ordering exists to prevent")
	check("...and the tracked loop yields that body to it",
	      src:find("if bpos and id ~= tid then", 1, true) ~= nil,
	      "without the skip both marks are offered for one body")
	check("...cached on the same tick as the id, not per frame",
	      src:find("_tk.kind = kind", 1, true) ~= nil,
	      "which task is selected changes when the player says so; where it stands does not")
	check("...and dresses the mark without gating it",
	      src:find("(kind and BEACON_ICON[kind]) or BEACON_ICON.task", 1, true) ~= nil,
	      "an unknown kind must draw the old mark, not suppress it")
	-- ...and the COLOUR half of that dressing is no longer resolved here (R2.63): it comes
	-- from the one shared resolver, because this was the path that did not consult
	-- beacon_color and so drew a selected hand-in green beside an unselected one in the
	-- accent. The colour harness owns the rule; what is asserted here is only that this
	-- call site no longer has an opinion of its own.
	check("...and takes its colour from the shared resolver",
	      src:find("beacon_tint(kind, fcomm)", 1, true) ~= nil
	      and src:find("kind and BEACON_RGB[kind] or nil", 1, true) == nil,
	      "offer_task must not resolve a tint of its own")
	-- The SELECTED mark is told from an unselected one by its RING instead, which is what
	-- freed the colour to obey the mode. Suppressed on the reticle alone: BEACON_RING.sel
	-- IS that glyph's outer arcs, so ringing it draws the same four arcs twice.
	check("...and wears the selected-task ring",
	      src:find("tex ~= BEACON_ICON.task and BEACON_RING.sel or nil", 1, true) ~= nil,
	      "nothing else on screen says which turn-in the player picked")
	check("...whose art is a ring and not a second glyph",
	      src:find('sel = "iqm_role_ringtask"', 1, true) ~= nil)
	check("bounty has no glyph of its own",
	      src:find("mutant    = \"iqm_role_skull\"", 1, true) ~= nil
	      and src:find("bounty%s*=%s*\"iqm_role") == nil,
	      "a bounty IS the ordinary reticle; keying one would make it a different mark")
	-- R2.56, and the counterpart to the check above rather than a repeat of it: `bounty` is
	-- unkeyed ON PURPOSE and `handin` was unkeyed BY OMISSION. task_kind started answering
	-- "handin" in R2.55 and neither table followed, so a selected hand-in beaconed as the gold
	-- go-find-it reticle while the map drew the green tag. The fall-through that makes an
	-- unknown kind safe is what made this invisible, so the presence of the pair is asserted.
	check("the hand-in KIND is dressed, not left to fall through",
	      src:find('handin    = "iqm_role_handin"', 1, true) ~= nil
	      and src:find("handin   = { 40, 172,  66}", 1, true) ~= nil,
	      "an unkeyed handin draws the go-find-it reticle over a finished job")
	check("...wearing the same green and glyph as the target ROLE that means the same thing",
	      src:find('target    = "iqm_role_handin"', 1, true) ~= nil
	      and src:find("target   = { 40, 172,  66}", 1, true) ~= nil,
	      "handing in is handing in; the kind and the role must not drift apart")
	check("the ROUTE is not gated by it",
	      src:find("return t.current_target, (not scan_talk_to) or scan_talk_to(t)", 1, true) ~= nil,
	      "active_task_target must RETURN the stage answer, not apply it -- route_target "
	      .. "shares this call and a path along the ground is navigation, not a reveal")

	check("both throttles re-poll on a config change",
	      src:find("_wp.t = 0\n\t_tk.t = 0", 1, true) ~= nil,
	      "turning the marker back on would leave it blank for up to 250 ms")
	check("the ring flag is the waypointed id",
	      src:find("wid ~= nil and id == wid", 1, true) ~= nil)
	-- The flag became the RING TEXTURE at R2.63 (there are two rings now), and `true` is
	-- kept as the sentinel for the waypoint's -- not for tidiness but because the caller,
	-- iqm_core's actor_on_update, sits at exactly LuaJIT's 60 upvalues: naming the table
	-- over there costs a load failure that takes every feature with it.
	check("the ring rides the candidate record",
	      src:find("e.ring = (ring == true) and BEACON_RING.wp or ring or nil", 1, true) ~= nil)

	-- the ring's own art and geometry
	check("the ring reuses the waypoint mark",
	      xml:match("<beacon_ring.-<texture[^>]*>([%w_]+)</texture>") == "iqm_role_waypoint",
	      "got " .. tostring(xml:match("<beacon_ring.-<texture[^>]*>([%w_]+)</texture>")))
	local RING_K = tonumber(src:match("local RING_K%s*=%s*([%d%.]+)"))
	check("RING_K found", RING_K ~= nil)
	check("the ring is larger than the glyph it frames", RING_K and RING_K > 1.15,
	      "too close to the glyph to be a frame rather than an outline")
	check("...and not so large it becomes the mark", RING_K and RING_K <= 1.35,
	      "1.5 was reported as too big and as the widest thing on the badge")
	-- ...and the SELECTED TASK's ring, which carries its own pair (R2.63a). Its arcs gap
	-- only +-11 degrees where the waypoint's gap +-20, so the tag's corners -- which sit at
	-- 15 and 75 degrees -- pass through the waypoint's openings and land on this one's
	-- arcs. It buys the clearance from both sides instead: a bigger ring AND a smaller
	-- glyph, because either alone was worse at the size this draws (see RING_GEOM).
	local SEL_K   = tonumber(src:match('%["iqm_role_ringtask"%]%s*=%s*{%s*k%s*=%s*([%d%.]+)'))
	local SEL_FIT = tonumber(src:match('%["iqm_role_ringtask"%]%s*=%s*{[^}]-fit%s*=%s*([%d%.]+)'))
	check("the selected ring's geometry is found", SEL_K ~= nil and SEL_FIT ~= nil)
	-- The measured constraint, restated so a future tweak to either number cannot quietly
	-- put the tag back through the arcs: the ring's clear interior is 0.266 of its own
	-- drawn width (inner ink radius 34 of the 128 cell) and the hand-in tag reaches 0.430
	-- of its own (max ink radius 55). Both measured off the atlas, both in tools/.
	if SEL_K and SEL_FIT then
		check("the selected ring clears the tag it frames",
		      0.266 * SEL_K > 0.430 * SEL_FIT,
		      string.format("interior %.3f vs tag %.3f -- the corners cross the arcs",
		                    0.266 * SEL_K, 0.430 * SEL_FIT))
		check("...without the glyph going unreadable",  SEL_FIT >= 0.8,
		      "below ~0.8 a 14-unit marker draws a tag too small to read as one")
		check("...and without the ring becoming the mark", SEL_K <= 1.65,
		      "1.81 makes the selected mark conspicuously bigger than its neighbours")
	end
	-- THE READOUT'S HEIGHT IS NOT THE RING'S, and nothing else in this file will notice if
	-- they are ever spelt the same again (R2.63a). `rh` is the range readout's glyph height
	-- and it is read on both sides of the ring metrics: `dw`/`mw`/`trk`/`spg` come off it
	-- ABOVE them and the digit draw comes off it BELOW. A second `local rh` for the ring
	-- shadowed it, so the digits drew at the RING's height against widths meant for the
	-- readout's -- tall and thin on a ringed marker, and drawn at height 0, i.e. INVISIBLE,
	-- on every marker without a ring, which is nearly all of them.
	--
	-- Asserted by COUNTING the declaration rather than by naming the culprit: what must
	-- stay true is that this name is declared once in the file, whatever the next local
	-- that wants it is called. The same goes for `rw`, which was the other half of the
	-- pair and is only safe today because nothing else happens to use it.
	for _, nm in ipairs{ "rh", "rw" } do
		local n = 0
		for _ in src:gmatch("local%s+" .. nm .. "%s*=") do n = n + 1 end
		for _ in src:gmatch("local%s+" .. nm .. "%s*,") do n = n + 1 end
		check("`" .. nm .. "` is declared at most once in iqm_cards", n <= 1,
		      "a second `local " .. nm .. "` shadows the range readout's metrics -- "
		      .. "name the ring's box rgw/rgh")
	end
	check("the ring is drawn from its own box, not the readout's",
	      src:find("b.ring:SetWndSize(S(rgw, rgh))", 1, true) ~= nil)
	check("the ring is centred on the GLYPH, not the badge",
	      src:find("icon_y + ih * 0.5 - rgh * 0.5", 1, true) ~= nil,
	      "centring on the badge hangs the ring low, since the badge also holds the readout")

	-- The reported collision: the ring reaches below the glyph, and the readout sits
	-- directly under the glyph. The overhang has to be in the METRICS or they close on
	-- each other at any RING_K.
	check("the ring's overhang is in the badge height",
	      src:find("local bh  = ih + roy * 2 + gap + th + BADGE_PAD * 2", 1, true) ~= nil)
	check("...and in the badge width", src:find("max(iw + rox * 2, tw)", 1, true) ~= nil)
	check("...and the readout is pushed clear of it",
	      src:find("local gy = bt + BADGE_PAD + roy + ih + roy + gap", 1, true) ~= nil,
	      "the range text would sit under the ring again")
	check("the glyph is inset by the overhang too",
	      src:find("local icon_y = bt + BADGE_PAD + roy", 1, true) ~= nil)
	check("the overhang is zero without a ring",
	      src:find("local roy = (rgh > 0) and (rgh - ih) * 0.5 or 0", 1, true) ~= nil,
	      "an unringed marker must lay out exactly as it did before")

	-- THE RING-vs-READOUT CLEARANCE IS NOT CHECKED HERE, and a numeric sweep that looked
	-- like it was stood in this spot until R2.63b. It recomputed both edges from roy and
	-- compared them -- but with roy = (rh - ih) / 2 the two sides expand to the same
	-- expression and their difference is identically -BADGE_GAP, for every size, every k
	-- and every fit. It could not have failed if the ring sat squarely on the digits,
	-- and extending it to the new, larger ring made it read as evidence that the bigger
	-- ring had been checked. It had not been.
	--
	-- What replaces it measures the two widgets after a real draw_beacon, in
	-- ../route-render-harness -- the only harness that builds the dialog and can see a
	-- drawn rect. What stays HERE is the source shape the derivation depends on (roy off
	-- the ring box, the readout placed past ih + 2*roy), which the checks above assert
	-- and which is all this harness can honestly speak to.

	check("the ring is hidden when there is no glyph",
	      src:find("b.icon:Show(false)\n\t\tb.ring:Show(false)", 1, true) ~= nil)

	-- the signature that stopped growing
	check("draw_beacon takes the candidate record",
	      src:find("function IqmCards:draw_beacon(i, ax, ay, ndx, ndy, ang, a, mtr, cfg, size, clamped, e)", 1, true) ~= nil)
	check("...and unpacks it in one place",
	      src:find("local tex, col, nmt, ring = e.tex, e.col, e.nmt, e.ring", 1, true) ~= nil)
	-- WHICH ring is drawn is the caller's word, re-pointed through the same one-compare
	-- cache the glyph uses -- a static's texture is settable but not creatable on the
	-- draw path, and a marker changes ring about as often as it changes NPC.
	check("...and the ring texture is re-pointed, not fixed in the xml",
	      src:find("if b.rtex ~= ring then b.rtex = ring; b.ring:InitTexture(ring) end",
	               1, true) ~= nil)
end

-- ------------------------------------------------------------------ verdict
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
