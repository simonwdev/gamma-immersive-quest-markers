-- Harness: FOCUS MODE -- the crosshair filter on the nameplates (R2.59).
--
-- WHY THIS EXISTS. Focus is a multiplier on a card's alpha, and a wrong multiplier does
-- not error: it draws a perfectly good overlay that is either always on (the feature
-- silently absent) or always off (every card gone, with the mod looking broken). Three
-- specific ways it can be wrong are invisible in code review and expensive in game:
--
--   1. THE ASPECT. The ring is measured in the 1024x768 virtual UI, which is stretched to
--      the real screen. Forget the kx correction and it is an ELLIPSE -- on 16:9 a card
--      33% further out horizontally still counts as focused, and the bug reads as "it
--      works, but it feels wrong at the sides", which nobody reports usefully.
--   2. THE ROLE TIERS. The mode picks which roles are exempt BY ROLE_PRIO, so a role
--      added at a new priority joins a tier without anyone deciding it should. The
--      tiers are asserted here against the real ROLE_PRIO table, by role NAME.
--   3. THE f.a TRAP, which is the one that would ship. f.a is control flow: `f.a < 96`
--      releases the through-wall marker and `f.a < 2` resets the entrance and the chirp.
--      Multiplying focus into it -- the obvious one-line implementation -- makes looking
--      away from an NPC SUMMON A BEACON for them, inverting the whole feature, and makes
--      sweeping the crosshair back re-fire the PDA chirp. Section 5 reads the draw path
--      back out of the source and fails if focus ever reaches f.a.
--
-- The geometry sections run the REAL function: iqm_core is loaded into a stub env and
-- iqm_core.card_focus is called directly, with its mirrors reached through
-- debug.getupvalue. So this cannot pass by agreeing with a transcription of itself.
--
-- Usage:
--   python tools/check-lua.py --run tools/focus-harness/harness.lua
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
local function close(a, b, tol)
	return a and b and math.abs(a - b) <= (tol or 1e-6)
end

local here = arg and arg[0] and arg[0]:gsub("[^/\\]+$", "") or ""
local ROOT = here .. "../../"
local function slurp(rel)
	local f = io.open(ROOT .. rel, "r")
	if not f then error("cannot open " .. ROOT .. rel .. " -- run from the mod root") end
	local s = f:read("*a") f:close() return s
end

local core_src = slurp("gamedata/scripts/iqm_core.script")
local scan_src = slurp("gamedata/scripts/iqm_scan.script")

-- ------------------------------------------------------------- the module
-- The same thinnest-possible env the mcm harness parses iqm_core under: the file body
-- allocates a few scratch vectors and registers callbacks, and touches nothing else at
-- parse time.
local ENV = {}
ENV.pairs, ENV.ipairs, ENV.tostring, ENV.tonumber = pairs, ipairs, tostring, tonumber
ENV.type, ENV.string, ENV.table, ENV.math, ENV.os = type, string, table, math, os
ENV.setmetatable, ENV.print, ENV.pcall, ENV.select = setmetatable, print, pcall, select
ENV.error, ENV.assert, ENV.unpack = error, assert, unpack
ENV._G = ENV
ENV.printf = function() end

local V2MT = {} V2MT.__index = V2MT
function V2MT:set(x, y) self.x, self.y = x, y return self end
ENV.vector2 = function() return setmetatable({ x = 0, y = 0 }, V2MT) end
local VecMT = {} VecMT.__index = VecMT
function VecMT:set(a, b, c)
	if type(a) == "table" then self.x, self.y, self.z = a.x, a.y, a.z
	else self.x, self.y, self.z = a, b, c end
	return self
end
ENV.vector = function() return setmetatable({ x = 0, y = 0, z = 0 }, VecMT) end
ENV.GetARGB = function(a, r, g, b) return { a = a, r = r, g = g, b = b } end
ENV.time_global = function() return 0 end
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

local MK = setmetatable({}, { __index = ENV })
do
	local chunk, err = loadstring(core_src, "@iqm_core.script")
	assert(chunk, err)
	setfenv(chunk, MK)
	local ok, perr = pcall(chunk)
	assert(ok, "iqm_core failed to parse: " .. tostring(perr))
end

local focus = MK.card_focus
check("iqm_core publishes card_focus", type(focus) == "function",
	"render() calls the local; this is the harness's only way in")
if type(focus) ~= "function" then
	print(string.format("\n%d passed, %d failed", passed, failed))
	os.exit(1)
end

-- ------------------------------------------------- its mirrors, by upvalue
-- FOC and ROLE_PRIO are file locals, so they are reached the way anything else in this
-- pack reaches a running script's private state: through the closure that closes over
-- them. FOC is a TABLE, so holding it is enough to drive the whole feature; ROLE_PRIO is
-- nil until on_game_start binds it, so it is set here instead.
local FOC, up_prio
for i = 1, 16 do
	local name, val = debug.getupvalue(focus, i)
	if not name then break end
	if name == "FOC" then FOC = val end
	if name == "ROLE_PRIO" then up_prio = i end
end
check("FOC is reachable from card_focus", type(FOC) == "table")
check("ROLE_PRIO is reachable from card_focus", up_prio ~= nil)

-- The REAL role ranks, parsed out of iqm_scan the way the slot harness parses them, then
-- bound into the module. Restating them here is the one thing that would let a role move
-- tier without this file noticing.
local ROLE_PRIO = {}
do
	local blk = scan_src:match("local ROLE_PRIO = {(.-)\n}")
	assert(blk, "ROLE_PRIO block not found in iqm_scan.script")
	for line in blk:gmatch("[^\n]+") do
		local code = line:gsub("%-%-.*$", "")
		for k, v in code:gmatch("([%w_]+)%s*=%s*(%d+)") do ROLE_PRIO[k] = tonumber(v) end
	end
end
check("ROLE_PRIO parsed", next(ROLE_PRIO) ~= nil)
debug.setupvalue(focus, up_prio, ROLE_PRIO)

-- FOCUS_PRIO, likewise read rather than restated: it IS the mapping under test in §3.
local FOCUS_PRIO = {}
do
	local blk = core_src:match("local FOCUS_PRIO = {(.-)}")
	assert(blk, "FOCUS_PRIO not found in iqm_core.script")
	for k, v in blk:gmatch("%[(%d+)%]%s*=%s*(%d+)") do FOCUS_PRIO[tonumber(k)] = tonumber(v) end
end
check("FOCUS_PRIO parsed", next(FOCUS_PRIO) ~= nil)

-- Set the mirrors the way read_config derives them, from the option values. Kept as one
-- function so every case states the SETTINGS it is about rather than the derived numbers.
local function configure(mode, size, soft, floor, aspect)
	FOC.prio  = FOCUS_PRIO[mode] or 0
	FOC.on    = FOCUS_PRIO[mode] ~= nil
	FOC.r     = size * 0.01 * 768
	FOC.r2    = FOC.r * FOC.r
	FOC.ri    = FOC.r * (1 - soft * 0.01)
	FOC.ri2   = FOC.ri * FOC.ri
	FOC.floor = floor * 0.01
	-- kxi is 1/UI_KX, and UI_KX is (h/w)/(768/1024) -- so for a 16:9 screen it is 0.75
	-- and kxi is 4/3. Derived from an aspect here for the same reason: the harness must
	-- not restate the number the renderer computes.
	local kx  = (1 / aspect) / (768 / 1024)
	FOC.kxi   = 1 / kx
end

-- The centre of the virtual UI, which is where the crosshair is.
local CX, CY = 512, 384

-- ------------------------------------------------------ 1. off is really off
do
	configure(0, 25, 40, 0, 16 / 9)
	check("mode 0 leaves FOC.on false", FOC.on == false)
	local all1 = true
	for _, p in ipairs({ { CX, CY }, { 0, 0 }, { 1023, 767 }, { CX + 300, CY } }) do
		if focus(p[1], p[2], "trader") ~= 1 then all1 = false end
	end
	check("with focus off every point is fully visible", all1,
		"the feature must be inert at its default, not merely wide")

	-- ...and the default IS off. Read off the registry, which is the same table
	-- read_config and the menu build from.
	check("focus_mode ships off", MK.DEFAULTS.focus_mode == 0)
	check("...and every focus row has a default", MK.DEFAULTS.focus_radius ~= nil
		and MK.DEFAULTS.focus_soft ~= nil and MK.DEFAULTS.focus_floor ~= nil)

	-- An off-screen NPC (hx nil) must answer 1 rather than 0: its card alpha is already
	-- 0 from the projection, and answering 0 here would write f.fon = false and demote a
	-- body from the slot rank for a reason that has nothing to do with focus.
	configure(1, 25, 40, 0, 16 / 9)
	check("an unprojected anchor is not treated as unfocused", focus(nil, nil, "trader") == 1)
end

-- --------------------------------------------------- 2. the ring's geometry
do
	configure(1, 25, 40, 0, 16 / 9)
	local R, RI = FOC.r, FOC.ri
	check("the radius is a percentage of HALF the UI's height", close(R, 0.50 * 384))
	check("the soft edge eats the outer 40% of it", close(RI, R * 0.6))

	check("dead centre is solid", focus(CX, CY, "trader") == 1)
	check("just inside the inner radius is solid", focus(CX, CY + RI - 1, "trader") == 1)
	check("just outside the outer radius is the floor",
		focus(CX, CY + R + 1, "trader") == FOC.floor)
	check("a corner of the screen is the floor", focus(4, 4, "trader") == FOC.floor)

	-- Monotone, and linear in DISTANCE across the soft edge (matching alpha_for_dist's
	-- ramp). Sampled along the vertical, where no aspect correction applies.
	local mono, last = true, 2
	for d = 0, R + 40, 2 do
		local v = focus(CX, CY + d, "trader")
		if v > last + 1e-9 then mono = false end
		last = v
	end
	check("the falloff never increases as you look away", mono)
	local mid = focus(CX, CY + (RI + R) * 0.5, "trader")
	check("the midpoint of the soft edge is half visible", close(mid, 0.5, 1e-6),
		string.format("got %.4f", mid or -1))

	-- THE ASPECT TEST. A horizontal offset must reach the same answer as the vertical
	-- one at the same distance ON SCREEN -- which is UI_KX times as many UI units, since
	-- X is the stretched axis. Checked at three aspects, because 4:3 is the one where a
	-- missing correction is invisible.
	for _, aspect in ipairs({ 4 / 3, 16 / 9, 21 / 9 }) do
		configure(1, 25, 40, 0, aspect)
		local kx = 1 / FOC.kxi
		local ok = true
		for _, frac in ipairs({ 0.3, 0.7, 0.9, 1.1 }) do
			local vert = focus(CX, CY + FOC.r * frac, "trader")
			local horz = focus(CX + FOC.r * frac * kx, CY, "trader")
			if not close(vert, horz, 1e-9) then ok = false end
		end
		check(string.format("the ring is a circle on screen at %.2f:1", aspect), ok,
			"drop the kx correction and this is an ellipse")
	end
	-- ...and the same test the other way round: WITHOUT the correction the answers must
	-- differ, or the check above would pass on a stubbed-out kxi and prove nothing.
	configure(1, 25, 40, 0, 16 / 9)
	check("...and equal UI offsets are NOT equal focus on a wide screen",
		not close(focus(CX, CY + FOC.r * 0.7, "trader"),
		          focus(CX + FOC.r * 0.7, CY, "trader"), 1e-9))
end

-- -------------------------------------------------- 3. the floor and the edge
do
	configure(1, 25, 40, 30, 16 / 9)
	check("an unfocused card keeps the floor opacity", close(focus(4, 4, "trader"), 0.30))
	check("...and a focused one is still fully opaque", focus(CX, CY, "trader") == 1)
	check("the ramp starts from the floor, not from zero",
		close(focus(CX, CY + (FOC.ri + FOC.r) * 0.5, "trader"), 0.30 + 0.70 * 0.5, 1e-6))

	-- soft 0 is a hard circle: the value must step, not ramp.
	configure(1, 25, 0, 0, 16 / 9)
	check("soft edge 0 gives a hard boundary",
		focus(CX, CY + FOC.r - 1, "trader") == 1 and focus(CX, CY + FOC.r + 1, "trader") == 0)
end

-- ------------------------------------------------------- 4. the role tiers
-- WHAT EACH MODE EXEMPTS, by role NAME. This is the check that would catch a role added
-- at a priority that quietly joins the wrong tier.
do
	local STATE   = { target = true, delivery = true, guide = true, companion = true, hire = true }
	local AMBIENT = { work = true, guider = true, trader = true, mechanic = true,
	                  barman = true, medic = true, important = true }
	check("the two role sets together are exactly ROLE_PRIO", (function()
		local n = 0
		for r in pairs(ROLE_PRIO) do
			n = n + 1
			if not (STATE[r] or AMBIENT[r]) then return false end
		end
		local m = 0
		for _ in pairs(STATE) do m = m + 1 end
		for _ in pairs(AMBIENT) do m = m + 1 end
		return n == m
	end)(), "a new role must be placed in a tier here deliberately")

	local FAR = { 4, 4 }   -- a corner: unfocused for any role that is subject to focus
	local function exempt(role) return focus(FAR[1], FAR[2], role) == 1 end

	configure(1, 25, 40, 0, 16 / 9)
	for role in pairs(STATE) do
		check("mode 1 exempts the state card " .. role, exempt(role))
	end
	for role in pairs(AMBIENT) do
		check("mode 1 focuses the ambient card " .. role, not exempt(role))
	end

	configure(2, 25, 40, 0, 16 / 9)
	for role in pairs(ROLE_PRIO) do
		local objective = (role == "target" or role == "delivery")
		check("mode 2 " .. (objective and "exempts " or "focuses ") .. role,
			exempt(role) == objective)
	end

	configure(3, 25, 40, 0, 16 / 9)
	local any = false
	for role in pairs(ROLE_PRIO) do if exempt(role) then any = true end end
	check("mode 3 exempts nothing at all", not any)

	-- An unknown role ranks last in slot_order_cmp (`or 9`); it must read the same way
	-- here, or the two halves of the same table disagree about a role neither knows.
	configure(1, 25, 40, 0, 16 / 9)
	check("an unknown role is focused, not exempted", not exempt("no_such_role"))
end

-- ------------------------------------------- 5. focus never reaches f.a (THE TRAP)
do
	local draw = core_src:match("CARDS:draw_slot%(t%.slot,[^\n]*")
	check("the draw path was found", draw ~= nil)
	check("focus is applied at the draw, beside the combat dim",
		draw and draw:find("f.a * SUP.fc * f.fa", 1, true) ~= nil,
		"the per-NPC focus factor must multiply the alpha handed to draw_slot")

	-- The two lines that must stay clean. Matched exactly as written, so any edit that
	-- folds focus into either one fails here rather than in play.
	check("the target alpha is untouched by focus",
		core_src:find("local target_a = (hx and vis and alpha_for_dist(dist)) or 0", 1, true) ~= nil,
		"multiplying focus in here makes looking away summon a through-wall marker")
	check("the eased alpha is untouched by focus",
		core_src:find("f.a      = f.a + (target_a - f.a) * kf", 1, true) ~= nil,
		"f.a is control flow: `< 96` releases the marker, `< 2` replays entrance + chirp")

	-- The handover thresholds themselves, which are what makes the above matter.
	check("the marker still releases on f.a, not on the drawn alpha",
		core_src:find("elseif f.a < 96 then", 1, true) ~= nil)
	check("the slot still hides on f.a", core_src:find("if f.a < 2 or not hx then", 1, true) ~= nil)

	-- The chirp defers rather than firing at a card the player cannot see.
	check("the chirp waits until the card is focused",
		core_src:find("if not f.seen and ftgt > 0.5 then", 1, true) ~= nil)

	-- AND THE HANDOVER IS DELIBERATELY *NOT* FOCUS-AWARE, which is the one place this
	-- feature declines to follow the README's "every reason a card hides brings the
	-- marker back". Making card_up read the focused alpha is a plausible-looking edit
	-- -- it even restores that sentence -- and it would hand the player a through-wall
	-- badge for every stalker they look away from, i.e. undo the feature. A marker is
	-- for a body geometry or distance took away; focus took it nowhere.
	check("the card/marker handover still reads the bare target alpha",
		core_src:find("elseif target_a >= 128 then", 1, true) ~= nil,
		"focus must not raise the marker for an NPC standing in plain sight")
	check("...and the bare eased alpha", core_src:find("elseif f.a < 96 then", 1, true) ~= nil)
	check("...so an unfocused card goes on suppressing its own marker",
		core_src:find("return (f and f.card_up) or false", 1, true) ~= nil)
end

-- --------------------------------------------------- 6. the slot rank
-- The REAL comparator, out of iqm_scan, driven with the entries iqm_core builds.
do
	local SC = setmetatable({}, { __index = ENV })
	SC.db = { actor = nil }
	local chunk, err = loadstring(scan_src, "@iqm_scan.script")
	assert(chunk, err)
	setfenv(chunk, SC)
	local ok, perr = pcall(chunk)
	check("iqm_scan parses", ok, tostring(perr))
	local cmp = SC.order_cmp
	check("iqm_scan publishes order_cmp", type(cmp) == "function")

	local function e(id, role, band, fb) return { id = id, role = role, band = band, fb = fb } end
	local function first(a, b) return cmp(a, b) and a or b end

	-- The whole point: focus outranks the role, and it outranks distance.
	check("a focused shop beats an unfocused turn-in",
		first(e(2, "trader", 9, 0), e(1, "target", 0, 1)).id == 2,
		"with focus on, a card the player asked not to see cannot hold a slot")
	check("a focused far NPC beats an unfocused near one",
		first(e(2, "trader", 40, 0), e(1, "trader", 0, 1)).id == 2)

	-- ...and WITHIN each side, nothing else changed.
	check("among focused cards the role still wins",
		first(e(1, "target", 9, 0), e(2, "trader", 0, 0)).id == 1)
	check("among unfocused cards the role still wins",
		first(e(1, "target", 9, 1), e(2, "trader", 0, 1)).id == 1)
	check("distance still breaks a role tie",
		first(e(1, "trader", 4, 0), e(2, "trader", 1, 0)).id == 2)

	-- THE REGRESSION GUARD. Entries with no fb at all -- which is every entry the marker
	-- path and the other harnesses build, and every entry at all with focus off -- must
	-- sort exactly as they did before this key existed.
	check("an entry with no fb ranks as entitled",
		first(e(1, "target", 0), e(2, "trader", 0, 1)).id == 1)
	check("...and two of them order by role then distance",
		first(e(1, "trader", 9), e(2, "target", 40)).id == 2
		and first(e(1, "trader", 9), e(2, "trader", 4)).id == 2)

	-- A total order, or table.sort is entitled to misbehave (and in LuaJIT can error).
	local set = {}
	for _, fb in ipairs({ 0, 1 }) do
		for _, role in ipairs({ "target", "guide", "trader" }) do
			for _, band in ipairs({ 0, 4 }) do
				set[#set + 1] = e(#set + 1, role, band, fb)
			end
		end
	end
	local strict = true
	for _, a in ipairs(set) do
		for _, b in ipairs(set) do
			if a ~= b and cmp(a, b) and cmp(b, a) then strict = false end
			if a == b and cmp(a, b) then strict = false end
		end
	end
	check("the comparator is a strict weak ordering", strict)
end

-- ------------------------------------- 7. the rank reads the render path's answer
do
	check("the rank key comes from FILT, not from a second projection",
		core_src:find("e.fb = (FOC.on and FILT[id] and FILT[id].fon == false) and 1 or 0", 1, true) ~= nil,
		"recomputing focus on the scan pass lets the rank and the pixels disagree")
	check("only a known-unfocused body is demoted",
		core_src:find("FILT[id].fon == false", 1, true) ~= nil,
		"nil means the render path has no opinion yet -- demoting it starves a newcomer")
	check("f.fon is only written while the feature is on",
		core_src:match("if FOC%.on then%s*\n%s*local fon = ftgt > 0%.5") ~= nil,
		"with focus off f.fon must stay nil so the rank behaves exactly as before")

	-- The early re-rank and both of its guards.
	check("crossing the ring can pull the rank forward",
		core_src:find("next_scan = 0", 1, true) ~= nil
		and core_src:find("if FOC.sat and tg >= FOC.next then", 1, true) ~= nil,
		"the rank is otherwise rebuilt on a 2 s interval, which a head turn outruns")
	check("...only when the slots were actually contended",
		core_src:find("FOC.sat = n > MAX_CARDS", 1, true) ~= nil)
	check("...and debounced",
		core_src:find("FOC.next  = tg + FOCUS_RERANK", 1, true) ~= nil
		and tonumber(core_src:match("local FOCUS_RERANK = (%d+)")) > 0)
	check("the saturation flag is stamped before the count is clamped",
		(core_src:find("FOC.sat = n > MAX_CARDS", 1, true) or 0)
		< (core_src:find("if n > MAX_CARDS then n = MAX_CARDS end", 1, true) or 0))
end

-- --------------------------------------------------------- 8. the config seam
do
	-- Every focus option must be on the cards page, or read_config forms a path the menu
	-- never wrote and the value reads as its default for ever (the PAGE_OF contract).
	for _, key in ipairs({ "focus_mode", "focus_radius", "focus_soft", "focus_floor" }) do
		check(key .. " stores under the cards page", MK.PAGE_OF[key] == nil,
			"PAGE_OF holds the exceptions; cards is the default")
	end
	check("read_config derives both radii",
		core_src:find("FOC.ri   = FOC.r * (1 - C.focus_soft * 0.01)", 1, true) ~= nil)
	check("turning it off clears the eased factor",
		core_src:find("for _, f in pairs(FILT) do f.fa, f.fon = 1, nil end", 1, true) ~= nil,
		"nothing but the per-frame ease moves f.fa, and with the feature off it stops running")
	check("the aspect reciprocal is hoisted once a frame",
		core_src:find("if FOC.on then FOC.kxi = 1 / cards_kx() end", 1, true) ~= nil)
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
