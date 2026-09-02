-- Harness: THE CARD'S ROLE IS NOT ALWAYS THE MARKER'S (R2.58).
--
-- WHY THIS EXISTS. Reported from play: Col Petrenko in Rostok, behind a wall, drew nothing
-- at all -- no card, no marker -- while the PDA map showed both his hand-in tag and his
-- trader spot the whole time.
--
-- He qualifies for three roles at once. He is a TRADER (a marker role), he has a task to
-- give (`work`, prio 5), and he is the hand-in for an active task (`target`, prio 1).
-- `desired` holds ONE role per NPC and `want` keeps the lowest ROLE_PRIO, which is right
-- for the card: the most actionable fact is the one worth the words. It was wrong for the
-- marker, because some of the roles that win that contest carry no marker at all --
-- `work`, `important`, `delivery`, and `target` for as long as it was retired (R2.46 to
-- R2.60). So a markerless winner took the marker away from a role the same NPC also held
-- and which would have drawn one.
--
-- R2.60 IS WHY THIS FILE SWEEPS TWO GATES. Petrenko came back from the other side once the
-- fall-through worked: with `target` markerless he drew his TRADER glyph through the wall
-- while his card read REPORT BACK -- one man, two views, two answers -- so `target` was
-- given a marker of its own on the beacon_targets switch. That does not retire the
-- fall-through, it moves it behind a setting: with beacon_targets ON his marker is his own
-- hand-in mark and the two views agree, and with it OFF he is back in exactly the state
-- want_marker was written for. Both are shipped states, so both are asserted below --
-- modelling only one of them is how this file would come to certify the bug it names.
--
-- The failure was invisible in the open, because there the work card covers for the
-- missing marker. It was total behind a wall, which is the one place the marker was all
-- there was: the card hides when line of sight fails, and there was nothing to hand over
-- to. That is also why the map and the HUD disagreed -- map spots stack per NPC, and
-- `desired` does not.
--
-- THE FIX IS TWO HALVES IN TWO PLACES, and neither is self-evident read alone:
--   1. `want_marker` (iqm_scan) keeps a SECOND answer per NPC -- the best-priority role
--      offered that actually carries a marker -- published as marker_set() and read by
--      iqm_core beside desired_set().
--   2. `extras_scan_one` returns the service role ALONGSIDE the work card, because both
--      come out of one scanner slot and only one of them was ever published. `want` never
--      saw the trader role at all in that case, so half 1 does not reach it.
--
-- What it checks:
--   1. THE MERGE. Over every combination of roles an NPC can be offered, the card takes
--      the most actionable and the marker takes the best MARKERED one -- and the marker
--      is never lost merely because a markerless role outranked it.
--   2. PETRENKO. The reported case by name, at both ranges and on both settings of
--      beacon_targets, so a regression names the bug -- either bug.
--   3. NO MARKER FROM NOWHERE. An NPC with only markerless roles still gets none, and one
--      whose card role already carries a marker is unchanged.
--   4. THE SWITCH STILL WINS. A role whose marker option is off contributes no marker.
--   5. THE SOURCE. Both halves, plus every consumer keyed on the marker's role rather
--      than the card's, read back out of iqm_scan and iqm_core -- since 1-4 only prove
--      the model.
--
-- Usage:
--   python check_lua.py --run tools/role-harness/harness.lua
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

-- ONE FILE PER NAME, not concatenated: half 1 lives in iqm_scan and every consumer of it
-- lives in iqm_core, so a grep across the join would pass vacuously -- which is the one
-- way a mirror check fails silently. The service-harness makes the same point at length.
local scan_src   = slurp("gamedata/scripts/iqm_scan.script")
local core_src   = slurp("gamedata/scripts/iqm_core.script")
-- ...and the gate itself, which is a third name for the same reason: the two tables above
-- are a transcription of it, and R2.60 moved a role between them.
local beacon_src = slurp("gamedata/scripts/iqm_beacon.script")

-- ------------------------------------------------------- the model under test
-- ROLE_PRIO, transcribed from iqm_scan. Parsed back out of the real table at the bottom,
-- so this copy cannot quietly go stale -- including when a NEW role is added, which is
-- the case that would otherwise slip through untested.
local ROLE_PRIO = {
	target = 1, delivery = 1, guide = 2, companion = 3, hire = 4, work = 5,
	guider = 6, trader = 6, mechanic = 6, barman = 6, medic = 6, important = 6,
}

-- iqm_beacon's live role gate with the marker rows on: the four services, the guide
-- profession, and -- since R2.60, on the beacon_targets switch -- the hand-in. `work` and
-- `important` have no marker assigned and never have; `delivery` has none either, which is
-- deliberate (an envelope over every recipient in range is what keying it would mean); and
-- `guide`, `companion` and `hire` are close-range card business.
local BEACON_ROLES = { guider = true, trader = true, target = true,
                       mechanic = true, barman = true, medic = true }

-- ...and the same gate with beacon_targets switched OFF, which is the R2.46 state and the
-- one want_marker was written against: `target` wins the card and has no marker to hand
-- over, so the fall-through is all that stands between that body and nothing at all. A
-- shipped state rather than a historical one -- it is one checkbox away.
local NO_TARGETS   = { guider = true, trader = true,
                       mechanic = true, barman = true, medic = true }

-- `want` + `want_marker`, transcribed. Returns the CARD's role and the MARKER's role for
-- an NPC offered `roles` in that order. Both keep the incumbent on an equal priority,
-- exactly as the real pair does.
local function merge(roles, gate)
	gate = gate or BEACON_ROLES
	local card, mark = nil, nil
	for _, role in ipairs(roles) do
		if gate[role] and not (mark and ROLE_PRIO[mark] <= ROLE_PRIO[role]) then mark = role end
		if not (card and ROLE_PRIO[card] <= ROLE_PRIO[role]) then card = role end
	end
	return card, mark
end

-- ------------------------------------------------------------- 1. the merge
do
	local ROLES = { "target", "delivery", "guide", "companion", "hire", "work",
	                "guider", "trader", "mechanic", "barman", "medic", "important" }
	-- every ordered triple, which is more roles than one NPC realistically holds -- and each
	-- of them against BOTH gates, since beacon_targets moves one role between them and the
	-- merge must hold either way. The gate is named in the failure so a regression says which
	-- setting it belongs to.
	local lost, invented, wrong_card = nil, nil, nil
	for _, g in ipairs{ { name = "targets on", gate = BEACON_ROLES },
	                    { name = "targets off", gate = NO_TARGETS } } do
	for _, a in ipairs(ROLES) do
		for _, b in ipairs(ROLES) do
			for _, c in ipairs(ROLES) do
				local set = { a, b, c }
				local card, mark = merge(set, g.gate)
				local where = table.concat(set, "+") .. " (" .. g.name .. ")"
				local any = false
				for _, r in ipairs(set) do if g.gate[r] then any = true end end
				if any and mark == nil then lost = where end
				if not any and mark ~= nil then invented = where end
				-- ...and the card is still the most actionable role offered
				local best = set[1]
				for _, r in ipairs(set) do
					if ROLE_PRIO[r] < ROLE_PRIO[best] then best = r end
				end
				if ROLE_PRIO[card] ~= ROLE_PRIO[best] then wrong_card = where end
			end
		end
	end
	end
	check("a markered role offered always yields a marker", lost == nil, lost)
	check("...and one never appears from nowhere", invented == nil, invented)
	check("...while the card still takes the most actionable role", wrong_card == nil, wrong_card)
end

-- --------------------------------------------------- 2. Petrenko, by name
do
	-- WITH beacon_targets ON, the shipped default since R2.60. FAR (past appear_dist):
	-- extras_scan_one's work branch is gated on `near`, so the scanner publishes `trader`
	-- and the quest system adds `target`.
	local card, mark = merge{ "target", "trader" }
	check("Petrenko far: the card reads REPORT BACK", card == "target")
	check("Petrenko far: ...and the marker is his OWN hand-in mark", mark == "target",
	      "R2.60 keyed br.target, so the best MARKERED role on him is the hand-in itself: "
	      .. "this is the second half of the report, where the card said REPORT BACK and "
	      .. "the marker showed a shop -- one man, two views, two answers")

	-- NEAR (inside appear_dist): the scanner returns `work` for the card and `trader` as
	-- its second value, and the quest system still adds `target`.
	card, mark = merge{ "target", "work", "trader" }
	check("Petrenko near: the card still reads REPORT BACK", card == "target")
	check("Petrenko near: ...and the marker is still his hand-in", mark == "target")

	-- WITH beacon_targets OFF -- one checkbox, and he is back in the state that found the
	-- fall-through. `target` still wins the card and now has no marker to give, so the
	-- marker must come from the trader role rather than being taken away by the winner.
	card, mark = merge({ "target", "trader" }, NO_TARGETS)
	check("targets off, far: the card reads REPORT BACK", card == "target")
	check("targets off, far: ...and the marker falls through to the trader", mark == "trader",
	      "this is the reported bug: a hand-in role with no marker of its own taking "
	      .. "the trader marker away, leaving nothing at all through a wall")

	card, mark = merge({ "target", "work", "trader" }, NO_TARGETS)
	check("targets off, near: the card still reads REPORT BACK", card == "target")
	check("targets off, near: ...and the marker is still the trader's", mark == "trader",
	      "extras_scan_one must return `out` beside \"work\", or want_marker never "
	      .. "sees the trader role at all")

	-- ...and the plain shopkeeper-with-a-job, the same collision without a quest in it.
	-- Far more common than Petrenko: any trader inside appear_dist with work to give.
	card, mark = merge{ "work", "trader" }
	check("a trader with a job to give keeps his marker", mark == "trader")
	check("...and still cards as work", card == "work",
	      "the marker fix must not float an ambient service card over a work card")
end

-- ------------------------------------------------- 3. no marker from nowhere
do
	-- `delivery` STANDS IN FOR `target` HERE since R2.60. It is the remaining objective role
	-- with no marker of its own -- a courier drop on a shopkeeper still marks the shop -- so
	-- it is now the case this section is about, and using `target` would have quietly turned
	-- this into an assertion that the R2.60 fix is absent.
	local _, mark = merge{ "delivery", "work", "important" }
	check("markerless roles alone still draw no marker", mark == nil,
	      "a body with nothing markered must stay a card-only body")
	check("...and `target` rejoins that set when its switch is off",
	      select(2, merge({ "target", "work", "important" }, NO_TARGETS)) == nil,
	      "beacon_targets off must take the hand-in's marker with it, like every other row")

	local card, m2 = merge{ "trader", "medic" }
	check("an already-markered card role is unchanged (card)", card == "trader")
	check("...and its marker agrees with its card", m2 == "trader",
	      "with no collision the two answers must be the same role, so iqm_core "
	      .. "never needs a fallback of its own")

	local c3, m3 = merge{ "guide", "guider" }
	check("guide (the job offer) cards over guider (the profession)", c3 == "guide")
	check("...and the guider marker survives it", m3 == "guider",
	      "the same collision as Petrenko's, one tier down")
end

-- ------------------------------------------------ 4. the switch still wins
do
	-- iqm_beacon.apply_config drops a role from the gate when its marker option is off.
	-- want_marker keys on that same live table, so the marker must vanish with it.
	local off = { guider = true }          -- services and the hand-in off, the guide left on
	local card, mark = merge({ "target", "work", "trader" }, off)
	check("a role whose marker switch is off contributes no marker", mark == nil,
	      "want_marker must key on iqm_beacon's live gate, not on a role list of its own")
	check("...and its card is untouched by that", card == "target")
end

-- ------------------------------------------------------ 5. the source says so
do
	-- half 1: want_marker exists, is keyed on the live gate, and every offer goes through it
	check("want_marker exists",
	      scan_src:find("local function want_marker(id, role)", 1, true) ~= nil)
	check("...keyed on iqm_beacon's live role gate",
	      scan_src:find("if not beacon_roles[role] then return end", 1, true) ~= nil,
	      "a role list of its own would drift from the marker switches")
	check("...ranked by the same comparator as the card",
	      scan_src:find("if cur and ROLE_PRIO[cur] <= ROLE_PRIO[role] then return end", 1, true) ~= nil)
	check("...and every offer passes through it",
	      scan_src:find("local function want(desired, id, role)\n\twant_marker(id, role)", 1, true) ~= nil,
	      "a want() that skips it loses the role that would have carried the marker")
	check("the set is published for iqm_core",
	      scan_src:find("function marker_set()", 1, true) ~= nil)
	check("...and wiped per pass, in desired_set",
	      scan_src:find("for id in pairs(_mrole) do _mrole[id] = nil end", 1, true) ~= nil,
	      "a set that is never cleared serves last pass's roles, and object ids recycle")

	-- half 2: the work branch carries the displaced service role out with it
	check("the work card carries the service role out beside it",
	      scan_src:find('return "work", out', 1, true) ~= nil,
	      "returning \"work\" alone throws `out` away inside the scanner, where want() "
	      .. "cannot see it -- half 1 does not reach this case")
	check("...the scanner has somewhere to put it",
	      scan_src:find("if m ~= nil and m ~= v then partial2[id] = m end", 1, true) ~= nil)
	check("...it is published with the pass",
	      scan_src:find("sc.live, sc.live2 = partial, partial2", 1, true) ~= nil)
	check("...cleared with the pass on a reset",
	      scan_src:find("sc.live, sc.live2, sc.next_due, sc.ids, sc.cursor = EMPTY, EMPTY, 0, nil, 0",
	                    1, true) ~= nil,
	      "a stale live2 hands a recycled object id the last level's marker role")
	check("...and merged as MARKER-ONLY",
	      scan_src:find("for id, role in pairs(extras_scanner.live2) do want_marker(id, role) end",
	                    1, true) ~= nil,
	      "putting it through want() would float an ambient service card over the work card")

	-- the transcription above, checked against the real table
	local blk = scan_src:match("local ROLE_PRIO = {(.-)\n}")
	check("ROLE_PRIO parsed", blk ~= nil)
	if blk then
		local seen = {}
		for line in blk:gmatch("[^\n]+") do
			local code = line:gsub("%-%-.*$", "")
			for k, v in code:gmatch("([%w_]+)%s*=%s*(%d+)") do seen[k] = tonumber(v) end
		end
		local bad = nil
		for k, v in pairs(ROLE_PRIO) do
			if seen[k] ~= v then bad = k .. " (prio moved or gone)" end
		end
		for k in pairs(seen) do
			if ROLE_PRIO[k] == nil then bad = k .. " (new role, untested here)" end
		end
		check("...and this file's copy of it is current", bad == nil, bad)
	end

	-- The GATE the two tables above transcribe, and the one role in it that moves. Asserted
	-- as the gated form: a bare `br.target = true` would mark every in-progress turn-in with
	-- no way to switch it off (the R2.46 complaint, returning unswitched), while a missing
	-- line would leave §2 asserting the wrong half of the switch and calling it a pass.
	check("`target` carries a marker again, on beacon_targets",
	      beacon_src:find("br.target    = (bok and C.mark_targets and C.beacon_targets ~= false) or nil",
	                      1, true) ~= nil,
	      "without it an unselected hand-in hands its marker down to whatever else that NPC "
	      .. "is -- the second half of the Petrenko report")
	check("...and the row exists to switch it with",
	      core_src:find('key = "beacon_targets"', 1, true) ~= nil)
	check("...while `delivery` is still deliberately unkeyed",
	      beacon_src:find("br.delivery", 1, true) == nil,
	      "keying it would put an envelope over every recipient in range; if that is now "
	      .. "wanted, §3 is the section that has to change with it")

	-- iqm_core: the marker set is read, cached, and every consumer keyed on it
	check("iqm_core binds marker_set",
	      core_src:find("scan_marker = iqm_scan.marker_set", 1, true) ~= nil)
	check("...and reads it on the same pass as desired_set",
	      core_src:find("local marker  = scan_marker()", 1, true) ~= nil,
	      "the set is wiped by the next desired_set, so a held reference goes stale")
	check("...stamped on the ranking entry, with the debug pin overriding it",
	      core_src:find("e.brole = (pins and pins[id]) or marker[id]", 1, true) ~= nil,
	      "a pin never goes through want(), so want_marker has not seen it")
	check("...and cached on the tracked entry for the render path",
	      core_src:find("t.brole = e.brole", 1, true) ~= nil)

	-- THE CHECK THAT WOULD HAVE CAUGHT THE BUG. Every marker consumer must read the
	-- MARKER's role. `t.role` at any of these reinstates the collision silently: all
	-- three tables return nil for a role they lack, so nothing errors -- the marker just
	-- stops being drawn, which is precisely how this shipped.
	-- The tint moved behind a shared resolver at R2.63 (iqm_core.beacon_tint), so the
	-- colour entry in both lists is now the CALL rather than the palette lookup it made.
	-- Same assertion, same failure mode: keyed on the card's role it returns a colour for
	-- the wrong mark, or nil, and nil is the accent -- so nothing errors and the marker
	-- merely wears the wrong colour, which is how the original shipped.
	for _, expr in ipairs{ "beacon_roles[t.role]", "BEACON_ICON[t.role]",
	                       "ROLE_PRIO[t.role], t.bcol", "beacon_tint(e.role" } do
		check("no marker consumer is keyed on the card's role: " .. expr,
		      core_src:find(expr, 1, true) == nil,
		      "a markerless card role must not decide the marker; see want_marker")
	end
	for _, expr in ipairs{ "beacon_roles[t.brole]", "BEACON_ICON[t.brole]",
	                       "ROLE_PRIO[t.brole], t.bcol", "beacon_tint(e.brole" } do
		check("...it is keyed on the marker's: " .. expr,
		      core_src:find(expr, 1, true) ~= nil)
	end
end

-- ------------------------------------------------------------------ verdict
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
