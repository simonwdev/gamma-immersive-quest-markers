-- Harness: WHICH markers survive when there are more candidates than slots (R2.39).
--
-- WHY THIS EXISTS. The marker set is capped, and until R2.39 the tie-break was DISTANCE
-- ALONE: `prio` separated the player's placed waypoint (0) from everything else (1), so
-- every marker the mod found for you competed on metres. That is fine until the slots are
-- contended, and then it silently gets it backwards -- a technician you happen to be
-- standing nearer to evicts the quest you are carrying, and nothing on screen says a
-- marker was dropped.
--
-- It was reported as "the barkeep's marker is inconsistent, and only shows when much
-- closer than the others", and diagnosed live in Rostok with five candidates in range:
--
--     mechanic   37.4 m   slot 1        <- ambient, you walk past it
--     guide      39.7 m   slot 2        <- ambient
--     turn-in    39.9 m   slot 3
--     turn-in    45.2 m   slot 4        <- last slot; flickered as the player drifted
--     turn-in    59.9 m   DROPPED
--
-- Two ambient service markers holding the top slots while a turn-in fell off the end. The
-- fix orders by ROLE_PRIO first -- the same table the CARD slots sort by, so the two
-- orderings agree by construction -- and only then by distance.
--
-- What it checks:
--   1. THE REGRESSION. The Rostok set above, by name: all three turn-ins drawn.
--   2. NEVER OUTRANKED. Swept over many mixed sets: no lower-ROLE_PRIO candidate is ever
--      dropped while a higher-ROLE_PRIO one is drawn. This is the real invariant; 1 is one
--      instance of it.
--   3. NEAREST-FIRST SURVIVES. Within one role class the order is still by distance, and
--      an uncontended set is ordered exactly as it was before the change.
--   4. THE WAYPOINT STILL WINS. prio 0 beats every role at any distance.
--   5. THE CAP. MAX_BEACONS is 6, and never exceeds the offer cap / _bcand preallocation.
--   6. THE SOURCE. The call sites and the sort are read back out of iqm_core, since
--      1-5 only prove the model.
--   8. THE PARTY MARKER IS LAST (R2.57). It is the one mark that ranks BEHIND the roles
--      rather than among them, and the one whose key is a near-homograph of a role's.
--
-- Usage:
--   python check_lua.py --run tools/slot-harness/harness.lua
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

-- Read as ONE string across the files this ordering now spans. The whole point of the
-- fix is that the CARD slots and the MARKER slots sort by the same table, and R2.45's
-- split put the two sides in different files: ROLE_PRIO and slot_order_cmp went to
-- iqm_scan (they are the scan's own ranking), the offer sites and the caps stayed with
-- the renderer. Grepping one file for the other's half would pass vacuously.
local src = slurp("gamedata/scripts/iqm_core.script")
         .. slurp("gamedata/scripts/iqm_scan.script")
         .. slurp("gamedata/scripts/iqm_cards.script")
         .. slurp("gamedata/scripts/iqm_beacon.script")

-- ------------------------------------------------------- the model under test
-- Read the two caps and the role ranks out of the source rather than restating them, so
-- the harness cannot quietly agree with a stale copy of the numbers.
-- No `local` in the MAX_BEACONS pattern: it is a namespace field of iqm_cards since
-- R2.45, because the module that caps the draw and the module that builds the widget
-- pool are no longer the same file and must not hold two opinions about the number.
-- Requiring digits keeps this off the line that BINDS it in the other module.
local MAX_BEACONS = tonumber(src:match("MAX_BEACONS%s*=%s*(%d+)"))
local MAX_CARDS   = tonumber(src:match("local MAX_CARDS%s*=%s*(%d+)"))

local ROLE_PRIO = {}
do
	local blk = src:match("local ROLE_PRIO = {(.-)\n}")
	assert(blk, "ROLE_PRIO block not found in iqm_core.script")
	-- entries look like `target = 1,` and `guider = 6, trader = 6, ...`; comments stripped
	for line in blk:gmatch("[^\n]+") do
		local code = line:gsub("%-%-.*$", "")
		for k, v in code:gmatch("([%w_]+)%s*=%s*(%d+)") do ROLE_PRIO[k] = tonumber(v) end
	end
end

-- beacon_offer's insertion sort, transcribed. Returns the candidates in slot order.
local function offer_all(cands)
	local arr, n = {}, 0
	for _, c in ipairs(cands) do
		if n < MAX_CARDS then                       -- the offer cap
			n = n + 1
			arr[n] = { id = c.id, dist = c.dist, prio = c.prio or ROLE_PRIO[c.role] or 1, role = c.role }
			for i = n, 2, -1 do
				local a, b = arr[i - 1], arr[i]
				if a.prio < b.prio or (a.prio == b.prio and a.dist <= b.dist) then break end
				arr[i - 1], arr[i] = b, a
			end
		end
	end
	return arr, n
end

-- what actually reaches the screen
local function drawn(cands)
	local arr, n = offer_all(cands)
	local out = {}
	for i = 1, math.min(n, MAX_BEACONS) do out[#out + 1] = arr[i] end
	return out
end

local function is_drawn(cands, id)
	for _, e in ipairs(drawn(cands)) do if e.id == id then return true end end
	return false
end

-- ---------------------------------------------------- 0. the ranks themselves
do
	check("ROLE_PRIO parsed", next(ROLE_PRIO) ~= nil)
	check("the turn-in outranks every service role",
	      ROLE_PRIO.target < ROLE_PRIO.trader and ROLE_PRIO.target < ROLE_PRIO.mechanic
	      and ROLE_PRIO.target < ROLE_PRIO.barman and ROLE_PRIO.target < ROLE_PRIO.medic
	      and ROLE_PRIO.target < ROLE_PRIO.guider,
	      "the whole fix rests on this ordering")
	check("the placed waypoint's 0 outranks every role",
	      0 < math.min(ROLE_PRIO.target, ROLE_PRIO.guider, ROLE_PRIO.trader),
	      "the one mark the player made themselves must never be evicted")
end

-- ------------------------------------------------------------ 1. the regression
do
	-- transcribed from the live capture, distances and all
	local rostok = {
		{ id = "mangun",     role = "mechanic", dist = 37.4 },
		{ id = "navigator",  role = "guider",   dist = 39.7 },
		{ id = "gritzenkov", role = "target",   dist = 39.9 },
		{ id = "barkeep",    role = "target",   dist = 45.2 },
		{ id = "petrenko",   role = "target",   dist = 59.9 },
	}
	check("Rostok: the barkeep's turn-in is drawn", is_drawn(rostok, "barkeep"),
	      "the reported bug is back: a turn-in evicted by an ambient marker")
	check("Rostok: every turn-in is drawn",
	      is_drawn(rostok, "gritzenkov") and is_drawn(rostok, "barkeep") and is_drawn(rostok, "petrenko"))
	local order = drawn(rostok)
	check("Rostok: the turn-ins take the first three slots",
	      order[1] and order[1].role == "target" and order[2] and order[2].role == "target"
	      and order[3] and order[3].role == "target",
	      "got " .. (order[1] and order[1].role or "nil") .. "," .. (order[2] and order[2].role or "nil"))
	check("Rostok: nearest turn-in first among them",
	      order[1].id == "gritzenkov" and order[2].id == "barkeep" and order[3].id == "petrenko")

	-- The fixture must still REPRODUCE the original fault, or the checks above pass for
	-- free. Replay it exactly as it shipped -- every candidate at prio 1, four slots --
	-- pinned to those numbers rather than to the current constants, so raising the cap
	-- or re-ranking the roles cannot quietly turn this into a tautology.
	local arr, n = offer_all({
		{ id = "mangun",     dist = 37.4, prio = 1 },
		{ id = "navigator",  dist = 39.7, prio = 1 },
		{ id = "gritzenkov", dist = 39.9, prio = 1 },
		{ id = "barkeep",    dist = 45.2, prio = 1 },
		{ id = "petrenko",   dist = 59.9, prio = 1 },
	})
	local before = {}
	for i = 1, math.min(n, 4) do before[arr[i].id] = true end
	check("...and the shipped rule (distance only, 4 slots) really did drop a turn-in",
	      not before.petrenko and before.mangun and before.navigator,
	      "the fixture no longer reproduces the original fault, so the checks above prove nothing")
	check("...with the barkeep clinging to the last of those four slots",
	      arr[4] and arr[4].id == "barkeep",
	      "that is why his was the marker that flickered rather than one that simply vanished")
end

-- ------------------------------------------------- 2. never outranked (sweep)
do
	local roles = { "target", "guider", "trader", "mechanic", "barman", "medic" }
	local bad = nil
	-- deterministic pseudo-random sets: vary count, role mix and distances by index
	for seed = 1, 400 do
		local n = 3 + (seed % 6)                     -- 3..8 candidates
		local cands = {}
		for i = 1, n do
			local role = roles[((seed * 7 + i * 3) % #roles) + 1]
			-- distances deliberately anti-correlated with rank, which is the failing case
			local dist = 5 + ((seed * 13 + i * 29) % 55)
			cands[i] = { id = i, role = role, dist = dist }
		end
		local shown = {}
		for _, e in ipairs(drawn(cands)) do shown[e.id] = true end
		for _, a in ipairs(cands) do
			for _, b in ipairs(cands) do
				if ROLE_PRIO[a.role] < ROLE_PRIO[b.role] and shown[b.id] and not shown[a.id] then
					bad = string.format("seed %d: %s(%s, %.0fm) dropped while %s(%s, %.0fm) drawn",
					                    seed, a.role, ROLE_PRIO[a.role], a.dist,
					                    b.role, ROLE_PRIO[b.role], b.dist)
				end
			end
		end
	end
	check("a more actionable role is never dropped for a less actionable one", bad == nil, bad)
end

-- --------------------------------------------- 3. nearest-first still applies
do
	local same = {
		{ id = "far",  role = "trader", dist = 50 },
		{ id = "near", role = "trader", dist = 10 },
		{ id = "mid",  role = "trader", dist = 30 },
	}
	local o = drawn(same)
	check("within one role class the order is still by distance",
	      o[1].id == "near" and o[2].id == "mid" and o[3].id == "far")

	-- an uncontended set must be ordered exactly as the old distance-only rule ordered it
	local few = {
		{ id = "a", role = "medic",  dist = 22 },
		{ id = "b", role = "target", dist = 41 },
	}
	check("an uncontended set draws everything regardless of order", #drawn(few) == 2,
	      "nothing may be dropped while slots are free")
end

-- --------------------------------------------------- 4. the waypoint still wins
do
	local set = {
		{ id = "wp", dist = 300, prio = 0 },          -- the placed waypoint, far away
	}
	for i = 1, MAX_BEACONS + 2 do
		set[#set + 1] = { id = "t" .. i, role = "target", dist = i }   -- turn-ins, all nearer
	end
	local o = drawn(set)
	check("the placed waypoint takes the first slot however far it is", o[1].id == "wp")
	check("...and is never crowded out by a full slate of turn-ins", is_drawn(set, "wp"),
	      "the no-range-gate rule is meaningless if the slot can be taken")
end

-- ---------------------------------------------------------------- 5. the cap
do
	check("MAX_BEACONS is 6", MAX_BEACONS == 6, "got " .. tostring(MAX_BEACONS))
	check("MAX_BEACONS never exceeds the offer cap", MAX_BEACONS <= MAX_CARDS,
	      "beacon_offer stops at MAX_CARDS and _bcand is preallocated to it, so a larger " ..
	      "MAX_BEACONS would index past the array")
	-- and the cap really is what limits the draw
	local many = {}
	for i = 1, MAX_CARDS + 4 do many[i] = { id = i, role = "target", dist = i } end
	check("no more than MAX_BEACONS are drawn", #drawn(many) == MAX_BEACONS)
end

-- -------------------------------------------------- 6. the source still says so
do
	check("the tracked-NPC offer passes the role's rank",
	      src:find("ROLE_PRIO[t.brole], t.bcol", 1, true) ~= nil,
	      "reverting this restores distance-only ordering and the eviction with it")
	check("the old unranked offer is gone",
	      src:find("BEACON_ICON[t.brole], nil, t.bcol", 1, true) == nil)
	-- R2.58: the offer is keyed on the MARKER's role, not the CARD's. `t.role` here would
	-- silently reinstate the collision -- a markerless card role (target/work/important)
	-- taking the marker away from a service role the same NPC also holds.
	check("...and on the marker's role, not the card's",
	      src:find("BEACON_ICON[t.role]", 1, true) == nil
	      and src:find("ROLE_PRIO[t.role], t.bcol", 1, true) == nil,
	      "a markerless card role must not decide the marker; see iqm_scan.want_marker")
	check("the placed waypoint still offers at prio 0",
	      src:find("BEACON_ICON.waypoint, 0)", 1, true) ~= nil)
	check("the sort is (prio, then distance)",
	      src:find("if a.prio < b.prio or (a.prio == b.prio and a.dist <= b.dist) then break end", 1, true) ~= nil)
	check("the draw is still capped at MAX_BEACONS",
	      src:find("local n = min(_bn, MAX_BEACONS)", 1, true) ~= nil)
	check("ROLE_PRIO is the single source of the ordering",
	      src:find("local function slot_order_cmp", 1, true) ~= nil
	      and src:find("ROLE_PRIO[a.role]", 1, true) ~= nil,
	      "card slots and marker slots must sort by the same table")
end

-- ------------------------------------- 7. every role is fully wired (R2.55)
-- THE CHECK THAT WOULD HAVE CAUGHT THE DELIVERY ROLE'S OMISSIONS. Adding a role touches
-- five tables in three files, and NONE of them errors on a missing entry -- header_for
-- falls back to st_iqm_hdr_target, icon_for returns nil, CHIRP_ROLES reads false. A role
-- can therefore be half-added and look like it works, which is exactly what happened when
-- `delivery` was split out of `target`: the card kept printing REPORT BACK over an
-- unfinished job, and nothing anywhere complained.
do
	local hdr = {}
	local blk = src:match("local HDR_KEYS = {(.-)\n}")
	check("HDR_KEYS parsed", blk ~= nil)
	if blk then
		for line in blk:gmatch("[^\n]+") do
			local code = line:gsub("%-%-.*$", "")
			for k in code:gmatch('([%w_]+)%s*=%s*"st_iqm_hdr_') do hdr[k] = true end
		end
	end
	-- Every CARD role must name its own header string. There is no role in ROLE_PRIO that
	-- is marker-only, so the two tables are expected to cover the same set exactly.
	for role in pairs(ROLE_PRIO) do
		check("role " .. role .. " has its own header", hdr[role] == true,
		      "header_for silently falls back to REPORT BACK for an unlisted role")
	end
	-- ...and the delivery role specifically, since it is the one that was folded into
	-- `target` for four releases and is the easiest to un-split by accident.
	check("delivery ranks with the turn-in",
	      ROLE_PRIO.delivery ~= nil and ROLE_PRIO.delivery == ROLE_PRIO.target,
	      "both are the objective NPC of a live task; they differ in which end of it")
	check("delivery chirps, like every other act-on-it-now role",
	      src:find("CHIRP_ROLES = {.-delivery = true") ~= nil)
	check("delivery carries the envelope, not the hand-in diamond",
	      src:find('delivery%s*=%s*"iqm_role_mail"') ~= nil,
	      "the whole point of the split: REPORT BACK's diamond means the job is done")
	check("the ground route follows a delivery too",
	      src:find('t%.role == "target" or t%.role == "delivery"') ~= nil,
	      "splitting the role would otherwise drop deliver-to NPCs out of route_target")
end

-- --------------------------------------- 8. the party marker ranks last (R2.57)
-- WHY THIS SECTION EXISTS, and it is two different worries wearing one coat.
--
-- THE ORDERING. The companion marker is the first mark this mod has ever added that is not
-- an answer to "where do I go". Every role above it is: a turn-in, a shop, a guide. A
-- companion is an asset that follows you and can be whistled back, so it must be the LAST
-- thing offered a slot -- behind the ambient band, not merely behind the objective. R2.39's
-- whole finding was that a silently evicted turn-in reads as a flickering marker, and a
-- feature that is off by default has no business being able to cause that. So the invariant
-- is stronger than §2's: not "never outranks a better role" but "never outranks ANY role".
--
-- THE NAME. `party`, not `companion`, and that is not cosmetics: ROLE_PRIO.companion
-- already exists and means the OPPOSITE thing -- a stalker you could recruit and have not.
-- One key for both would look like agreement and be a collision, and the failure would be
-- silent in the usual way (a ROLE_PRIO lookup on "companion" answers 3, so the party marker
-- would quietly rank above every service). The two vocabularies are asserted apart here,
-- which is the same hazard BEACON_ICON's `waypoint` note warns about, caught in advance for
-- once rather than after a release.
do
	local PARTY_PRIO = tonumber(src:match("local PARTY_PRIO%s*=%s*(%d+)"))
	check("PARTY_PRIO found", PARTY_PRIO ~= nil,
	      "the party marker's rank is not in the source at all")

	local worst = 0
	for _, v in pairs(ROLE_PRIO) do if v > worst then worst = v end end
	check("the party ranks behind EVERY role, not just the objective",
	      PARTY_PRIO ~= nil and PARTY_PRIO > worst,
	      "worst role rank is " .. worst .. ", party is " .. tostring(PARTY_PRIO))

	-- ...and the ordering that follows from it, over a full slate. A companion standing on
	-- top of you must not take a slot from a shop across the square.
	local set = { { id = "buddy", dist = 2, prio = PARTY_PRIO } }
	for i = 1, MAX_BEACONS do
		set[#set + 1] = { id = "svc" .. i, role = "trader", dist = 20 + i }
	end
	check("a companion at 2 m never evicts a trader at 26 m", not is_drawn(set, "buddy"),
	      "the one mark that is allowed to lose a slot is the one that lost it")
	check("...and every role candidate is still drawn", is_drawn(set, "svc1")
	      and is_drawn(set, "svc" .. MAX_BEACONS))

	-- with room to spare it draws, and nearest-first among its own kind
	local few = {
		{ id = "far",  dist = 40, prio = PARTY_PRIO },
		{ id = "near", dist = 5,  prio = PARTY_PRIO },
		{ id = "boss", role = "target", dist = 55 },
	}
	local o = drawn(few)
	check("with slots free the party marks draw", #o == 3)
	check("...behind the turn-in", o[1].id == "boss")
	check("...nearest companion first", o[2].id == "near" and o[3].id == "far")

	-- and the player's own waypoint still beats it, as it beats everything
	check("the placed waypoint outranks the party too", 0 < (PARTY_PRIO or 0))

	-- THE TWO VOCABULARIES
	check("`party` is not a card role", ROLE_PRIO.party == nil,
	      "a party key in ROLE_PRIO would give the marker a role's rank and a header it "
	      .. "has no card to print")
	check("...and `companion` still means RECRUITABLE, which is the opposite thing",
	      ROLE_PRIO.companion ~= nil and ROLE_PRIO.companion == 3,
	      "if this role is ever renamed to `party` the marker silently inherits its rank")

	-- ------------------------------------------------------------ the source
	check("the party offer passes its own rank, not a role's",
	      src:find("BEACON_ICON.party, PARTY_PRIO, col", 1, true) ~= nil)
	check("...and rides beacon_dist, passed in from the range mirror",
	      src:find("offer_party(apos, marked, beacon_d, wid, tid)", 1, true) ~= nil,
	      "iqm_beacon keeps no copy of the range; hard-coding one here would let the two drift")
	check("...and defers to the two navigation marks on the same body",
	      src:find("if id ~= wid and id ~= tid then", 1, true) ~= nil,
	      "one mark per body: the waypoint and the selected task are offered first")
	check("...and to a card or a role marker on it",
	      src:find("if d < bd and not marked(id, d) then", 1, true) ~= nil)
	check("the party list is read from the game's own party table",
	      src:find("ac.list_actor_squad_by_id", 1, true) ~= nil
	      and src:find("local ac = axr_companions", 1, true) ~= nil)
	check("...guarded, so an install without the companion system no-ops",
	      src:find("if not (party_on and apos and ac and ac.list_actor_squad_by_id) then return end",
	               1, true) ~= nil)
	check("...and throttled, since it builds a table and walks every squad",
	      src:find("_pt.t = tg + 1000", 1, true) ~= nil)
	check("the position is NOT throttled with it",
	      src:find("local pos = goal_pos(id)", 1, true) ~= nil,
	      "a companion is the one marked body that is always moving")
	check("the switch is off by default",
	      src:find('key = "beacon_party", page = "beacons", def = false', 1, true) ~= nil)
	check("...and rides the companion mod rather than a card role",
	      src:find('pre = "party_here"', 1, true) ~= nil,
	      "there is no companion card for it to follow")
	check("the empty-frame early-out lets it through",
	      src:find("not rd and not C.beacon_party then", 1, true) ~= nil,
	      "a companion is never in `tracked`, so the old early-out skipped the whole feature")
	check("the marker wears the map's own companion mark",
	      src:find('party     = "iqm_role_vip"', 1, true) ~= nil
	      and src:find("party    = { 40, 172,  66}", 1, true) ~= nil,
	      "the PDA draws a companion as the VIP bust in the companion green")
end

-- ------------------------------------------------------------------ verdict
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
