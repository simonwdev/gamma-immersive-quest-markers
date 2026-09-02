-- Harness: the marker's NAME BAND (option beacon_name, R2.37).
--
-- WHY THIS EXISTS. The name is the only thing on the marker drawn as TEXT, and text drags
-- in three constraints that no other part of the badge has:
--
--   1. A FONT THAT CANNOT BE CHOSEN FREELY. `small` looks like the obvious pick and is
--      unusable: it resolves to ui_font_hud_01, which CGameFont::Initialize excludes from
--      the localisation prefix (GameFont.cpp:76-80), so it is one ASCII atlas for every
--      language and a Cyrillic name would not render. This mod ships an RU locale. That
--      is a fact about the engine, invisible in this repo, and exactly the kind of thing
--      someone "tidies up" to a smaller font a year from now. Pinned.
--   2. NO SCALING. Engine text renders at a fixed pixel height picked from a resolution
--      bucket and SetHeight is not bound to Lua, so the name ignores beacon_size while
--      everything else follows it. Not testable offline -- recorded here and in the
--      option's own description so it is a known cost rather than a bug report.
--   3. A MEASURED WIDTH, hence a layout that can run off screen. That part IS testable,
--      and it is what most of this file does.
--
-- Plus one bug this feature would have shipped with: the NPC name used to be resolved
-- inside the branch that runs only when the CARD is visible. The marker exists precisely
-- for when the card is not, so a name read from there would have been empty in every
-- situation the option was turned on for. The fix moved one line; this pins where it went.
--
-- Usage:
--   python check_lua.py --run tools/name-harness/harness.lua
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

-- Read as ONE string across the two files the name now spans: R2.45 moved draw_beacon
-- (which lays the name band out) to iqm_cards, while the per-NPC loop that RESOLVES the
-- name -- and the ordering check below, which compares source offsets inside it --
-- stayed in iqm_core. iqm_core is read first so those offsets keep their meaning:
-- all three needles `once()` looks for live in that file and in that one loop.
local src = slurp("gamedata/scripts/iqm_core.script")
         .. slurp("gamedata/scripts/iqm_cards.script")
         .. slurp("gamedata/scripts/iqm_beacon.script")
local xml = slurp("gamedata/configs/ui/iqm_cards.xml")

-- ------------------------------------------------------- the model under test
local NAME_H, NAME_GAP = 16, 2
local L, R = 4, 1020            -- the on-screen band, in the 1024-wide virtual UI

-- draw_beacon's name placement, transcribed.
local function band(bcx, bt, bh, nw)
	local nx = bcx - nw * 0.5
	if nx < L then nx = L elseif nx + nw > R then nx = R - nw end
	local ny = bt - NAME_H - NAME_GAP
	if ny < 2 then ny = bt + bh + NAME_GAP end
	return nx, ny
end

-- ------------------------------------------------------------ 1. it stays on screen
do
	local bad = nil
	for bcx = -200, 1200, 7 do
		for _, nw in ipairs{ 12, 40, 90, 180, 400 } do
			local nx = band(bcx, 300, 40, nw)
			-- an over-wide name cannot satisfy both edges; left must win (see below)
			if nw <= (R - L) and (nx < L or nx + nw > R) then
				bad = string.format("bcx=%d nw=%d -> nx=%.1f", bcx, nw, nx)
			end
		end
	end
	check("the name never leaves the screen", bad == nil, bad)
end

-- ------------------------------------------------------- 2. centred when it can be
do
	local nw = 80
	for _, bcx in ipairs{ 200, 512, 800 } do
		local nx = band(bcx, 300, 40, nw)
		check("centred on the badge at bcx=" .. bcx, math.abs((nx + nw * 0.5) - bcx) < 1e-9)
	end
end

-- --------------------------------------- 3. clamping the MEASURED box, not a fixed one
-- The reason the width is measured at all. A short name near the screen edge must stay
-- next to its own marker; clamping a fixed-width box would shove it inboard by the
-- box's half-width regardless of how little text there was.
do
	local FIXED = 300      -- the placeholder width in iqm_cards.xml
	local bcx = 10         -- marker parked hard against the left edge
	for _, nw in ipairs{ 12, 30, 60 } do
		local nx = band(bcx, 300, 40, nw)
		local drift = math.abs((nx + nw * 0.5) - bcx)
		-- what a fixed box would have cost at the same spot
		local fixed_nx = math.max(L, bcx - FIXED * 0.5)
		local fixed_drift = math.abs((fixed_nx + FIXED * 0.5) - bcx)
		check("short name (" .. nw .. ") stays near its marker", drift < fixed_drift,
		      string.format("measured drift %.1f vs fixed %.1f", drift, fixed_drift))
		-- and the drift is only ever what the edge actually demanded
		check("drift is only what the edge demands (" .. nw .. ")",
		      math.abs(drift - math.max(0, L - (bcx - nw * 0.5))) < 1e-9)
	end
end

-- ------------------------------------------------- 4. an over-wide name favours its start
do
	local nw = 1200        -- wider than the screen: both edges cannot be satisfied
	local nx = band(512, 300, 40, nw)
	check("an over-wide name keeps its START visible", nx == L,
	      "got " .. nx .. " -- the end of the name would be readable and the start cut off")
end

-- ------------------------------------------------------ 5. the flip at the top edge
do
	local bh = 40
	-- room above: the band sits over the badge
	local _, ny = band(512, 300, bh, 80)
	check("above the badge when there is room", ny == 300 - NAME_H - NAME_GAP)
	check("...and clear of it", ny + NAME_H <= 300)

	-- parked against the top: it has to go under, or it is clipped in the one case the
	-- marker is at an edge, which is when it matters most
	local _, ny2 = band(512, 4, bh, 80)
	check("below the badge when there is not", ny2 == 4 + bh + NAME_GAP)
	check("...and on screen", ny2 >= 2)

	-- the flip happens only when needed: find the boundary and check both sides of it
	local bt_ok   = NAME_H + NAME_GAP + 2
	local _, a1 = band(512, bt_ok, bh, 80)
	local _, a2 = band(512, bt_ok - 1, bh, 80)
	check("no flip with exactly enough room", a1 < bt_ok)
	check("flip one pixel further up",        a2 > bt_ok)
end

-- ------------------------------------------------ 6. the source still says so
do
	-- the font constraint, in both files that carry it
	check("the name uses letterica16", xml:find('beacon_name">%s*\n?%s*<text font="letterica16"') ~= nil
	      or xml:match('<beacon_name>%s*<text font="([%w_]+)"') == "letterica16",
	      "font is " .. tostring(xml:match('<beacon_name>%s*<text font="([%w_]+)"')))
	check("the shadow copy matches the name's font",
	      xml:match('<beacon_name_sh>%s*<text font="([%w_]+)"')
	      == xml:match('<beacon_name>%s*<text font="([%w_]+)"'))
	check("`small` is not used for the name", xml:match('<beacon_name>%s*<text font="small"') == nil)
	check("the ASCII-atlas reason is written down", xml:find("ui_font_hud_01", 1, true) ~= nil)

	-- The name must be resolved for the MARKER path, not only the card path. Each of these
	-- three statements occurs exactly once in the file and all three sit in the same
	-- per-NPC loop, so their order in the source IS their order at runtime -- which is why
	-- comparing file offsets is sound here and not a shortcut.
	local function once(needle)
		local a = src:find(needle, 1, true)
		local b = a and src:find(needle, a + 1, true)
		return (a and not b) and a or nil          -- nil if missing OR ambiguous
	end
	local at_name  = once("if obj and not t.name then t.name = name_from_obj(obj) end")
	local at_offer = once("beacon_offer(id, bdist")
	local at_card  = once("CARDS:draw_slot(")
	check("the resolve, the offer and the card draw each appear once",
	      at_name and at_offer and at_card,
	      string.format("name=%s offer=%s card=%s", tostring(at_name), tostring(at_offer), tostring(at_card)))
	check("the name is resolved before the marker is offered",
	      at_name and at_offer and at_name < at_offer,
	      "a marker would show an empty name")
	check("...and before the card draws too", at_name and at_card and at_name < at_card)
	check("it is no longer resolved inside the card branch",
	      src:find("if not t.name then t.name = name_from_obj(obj) end", 1, true) == nil)

	-- The name wears the marker's colour, not a fixed one: the two elements of one marker
	-- must not drift into two colours, and beacon_color has to reach the name as well as
	-- the glyph or the option only half applies.
	check("the name takes the marker's tint",
	      src:find("b.nm:SetTextColor(GetARGB(a, cr, cg, cb))", 1, true) ~= nil,
	      "the name is on a fixed colour again -- beacon_color would only tint half the marker")
	-- ...and the shadow does NOT take that tint. It goes through SHC now (R2.59) rather than
	-- a literal black: SHC is black at rest and the interference fringe hue while the ink is
	-- separating, which is one deliberate exception and not a drift. What this check is
	-- actually defending is unchanged -- the shadow must never be `cr, cg, cb`, or beacon_color
	-- would paint both halves of the name the same colour and the dark copy would stop being
	-- a dark copy. So assert the call shape AND that the marker's tint is not in it.
	check("...and the shadow goes through SHC, not the marker's tint",
	      src:find("b.nm_sh:SetTextColor(SHC(floor(a * 0.7)))", 1, true) ~= nil,
	      "the name's shadow was re-pointed -- if it is on cr,cg,cb the name is one flat colour")

	-- measured once per name, not per frame
	check("the name is measured only when it changes",
	      src:find("if b.nmt ~= nmt then", 1, true) ~= nil)
	check("...using the same three calls the cards use",
	      src:find("b.nm:AdjustWidthToText()", 1, true) ~= nil
	      and src:find("b.nmw = b.nm:GetWidth()", 1, true) ~= nil)

	-- the option gates the name at the offer, so draw_beacon just draws what it is given
	check("beacon_name gates the name",
	      src:find("C.beacon_name and t.name or nil", 1, true) ~= nil)
	check("the placed waypoint is offered no name",
	      src:find("BEACON_ICON.waypoint, 0)", 1, true) ~= nil,
	      "the waypoint offer grew a name argument -- there is no NPC there to name")

	-- Default off, declared, on the right page, and drawn as a checkbox -- one registry
	-- record since R2.46, where those were a DEFAULTS entry, a PAGE_OF entry and a row
	-- in iqm_mcm that nothing held to the other two.
	local rec = src:match('\n({ key = "beacon_name",.-)\n[%-{\n]')
	check("beacon_name has a registry record", rec ~= nil)
	check("beacon_name defaults off", rec and rec:find("def = false", 1, true) ~= nil)
	check("beacon_name is mapped to the beacons page",
	      rec and rec:find('page = "beacons"', 1, true) ~= nil)
	check("...and the MCM row is a checkbox", rec and rec:find('type = "check"', 1, true) ~= nil)

	for _, loc in ipairs{ "eng", "rus" } do
		local t = slurp("gamedata/configs/text/" .. loc .. "/st_mcm_iqm.xml")
		check(loc .. ": caption string",     t:find('"ui_mcm_iqm_beacon_name"', 1, true) ~= nil)
		check(loc .. ": description string", t:find('"ui_mcm_iqm_beacon_name_desc"', 1, true) ~= nil)
	end
end

-- ------------------------------------------------------------------ verdict
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
