-- Harness: build the REAL MCM menu outside the game and check the three contracts it
-- has to satisfy but that nothing in the game will ever tell you it broke.
--
-- The menu is declarative, so it always "works": a wrong page id, a stale precondition
-- path or a missing translation all produce a menu that draws perfectly and simply
-- does the wrong thing forever. Specifically:
--
--   1. PAGE AGREEMENT. MCM stores an option at "iqm/<page>/<id>", and
--      iqm_core.read_config rebuilds that path from iqm_core.PAGE_OF. If the two
--      disagree by one key, that option reads its DEFAULT for every user, for good,
--      with no error anywhere. This is the contract the per-feature page split
--      (R2.24) put most at risk, since it moved every option at once.
--
--   2. LIVE PRECONDITIONS. Every precondition closure reads a storage path by hand
--      ("iqm/cards/mark_targets"). ui_mcm.get returns nil for a path that does not
--      exist, nil reads as false, and the row silently never draws. So each one is
--      called here against a menu whose options are all ON: anything still hidden is
--      reading a path that is not there.
--
--   3. TRANSLATIONS. Every caption, description, section header and list value the
--      menu names must exist in the shipped string table, or MCM draws the raw id.
--
-- Usage:
--   luajit tools/mcm-harness/harness.lua
--   VERBOSE=1 luajit tools/mcm-harness/harness.lua
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
	if not f then error("cannot open " .. ROOT .. rel ..
		" -- run via: luajit tools/mcm-harness/harness.lua") end
	local s = f:read("*a")
	f:close()
	return s
end

-- ---------------------------------------------------------------- engine env
local ENV = {}
ENV.pairs, ENV.ipairs, ENV.tostring, ENV.tonumber = pairs, ipairs, tostring, tonumber
ENV.type, ENV.string, ENV.table, ENV.math, ENV.os = type, string, table, math, os
ENV.setmetatable, ENV.print, ENV.pcall, ENV.select = setmetatable, print, pcall, select
ENV.error, ENV.assert, ENV.unpack = error, assert, unpack
ENV._G = ENV
ENV.printf = function() end

-- iqm_core allocates its scratch vectors and binds a few engine globals in its own
-- body, so parsing it needs these to exist. Nothing here is exercised -- the menu only
-- reads DEFAULTS and PAGE_OF out of that module -- so they are the thinnest stubs that
-- let the chunk run to the end.
local V2MT = {}
V2MT.__index = V2MT
function V2MT:set(x, y) self.x, self.y = x, y; return self end
ENV.vector2 = function() return setmetatable({ x = 0, y = 0 }, V2MT) end

local VecMT = {}
VecMT.__index = VecMT
function VecMT:set(a, b, c)
	if type(a) == "table" then self.x, self.y, self.z = a.x, a.y, a.z
	else self.x, self.y, self.z = a, b, c end
	return self
end
-- Comparing two vectors is a CTD in game (R2.41): luabind's `vector` defines no __eq, so
-- `a == b` on two of them raises "No such operator [__eq] defined in class [vector]" and
-- takes the game down. A plain-table stub answers by identity instead and hides it, which
-- is how R2.41 reached a player. Reproduced here so the harness fails where the game does.
VecMT.__eq = function()
	error("No such operator [__eq] defined in class [vector]" ..
	      " -- compare coordinates or a distance, never two vectors", 2)
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

-- ------------------------------------------------------- the string table(s)
-- Parsed straight out of the shipped XML rather than listed here, so a caption added
-- to the menu and forgotten in the translation is a failure rather than a second
-- place to forget it.
local function string_ids(rel)
	local ids, src = {}, slurp(rel)
	for id in src:gmatch('<string%s+id="([^"]+)"') do ids[id] = true end
	return ids
end
local ENG = string_ids("gamedata/configs/text/eng/st_mcm_iqm.xml")
local RUS = string_ids("gamedata/configs/text/rus/st_mcm_iqm.xml")

-- MCM ships these itself (its own Key Binds page owns the modifier and mode labels),
-- so this mod must NOT carry them -- shipping a copy would silently override every
-- other mod's. They are excluded from the "must be translated" check for that reason.
local function mcm_own(id) return id:sub(1, 4) == "mcm_" end

-- ------------------------------------------------------------------- ui_mcm
-- Storage, keyed the way MCM keys it. Filled from the menu itself once it is built,
-- so `get` answers for exactly the paths the menu declares -- which is what makes a
-- precondition reading a stale path come back nil, as it would in game.
local STORE = {}
ENV.ui_mcm = {
	get = function(path) return STORE[path] end,
	key_hold = function() end,     -- MCM >= 1.6.0 present, so the key_bind rows draw
	kb_mod_radio = "kb_mod_radio",
}

-- Personal Adjustable Waypoint, present. The placed-waypoint row is preconditioned on
-- the mod being INSTALLED rather than on a setting, so with no stub here that row would
-- read as unreachable -- which is exactly right in a PAW-less install and exactly wrong
-- as an assertion about the menu. Stubbed to the one call iqm_core makes of it.
ENV.tasks_placeable_waypoints = { get_current_waypoint = function() return nil end }

-- The companion system, present, for exactly the reason PAW is stubbed above: the party
-- marker's row is preconditioned on axr_companions being INSTALLED rather than on a
-- setting, so without a stub the row reads as unreachable -- right in an install that has
-- no companion system, wrong as an assertion about the menu. Stubbed to the one call
-- iqm_beacon makes of it.
ENV.axr_companions = { list_actor_squad_by_id = function() return {} end }

-- iqm_core, as the menu sees it: only DEFAULTS and PAGE_OF are read from there.
local markers_src = slurp("gamedata/scripts/iqm_core.script")
local MK = setmetatable({}, { __index = ENV })
do
	local chunk, err = loadstring(markers_src, "@iqm_core.script")
	assert(chunk, err)
	setfenv(chunk, MK)
	-- The module body only defines things; nothing in it touches the engine at parse
	-- time. If that ever stops being true this assert is where it will say so.
	local ok, perr = pcall(chunk)
	assert(ok, "iqm_core failed to parse: " .. tostring(perr))
end
ENV.iqm_core = MK

-- ---------------------------------------------------------------- build it
local mcm_src = slurp("gamedata/scripts/iqm_mcm.script")
local MCM = setmetatable({}, { __index = ENV })
do
	local chunk, err = loadstring(mcm_src, "@iqm_mcm.script")
	assert(chunk, err)
	setfenv(chunk, MCM)
	chunk()
end

local menu = MCM.on_mcm_load()
check("the menu builds", type(menu) == "table" and menu.id == "iqm")
check("...as a folder of subpages, not a leaf page", menu.sh == nil,
	"a top-level sh makes MCM treat gr as options rather than pages")

-- Every option row, with the page it landed on. Support elements (line/title/slide/
-- desc) carry no val and so no storage; they are collected separately for the
-- translation pass.
local opts, support, pages = {}, {}, {}
for _, page in ipairs(menu.gr) do
	check("page '" .. tostring(page.id) .. "' is a leaf page", page.sh == true)
	pages[#pages + 1] = page.id
	for _, o in ipairs(page.gr) do
		if o.val then
			opts[#opts + 1] = { id = o.id, page = page.id, o = o }
		else
			support[#support + 1] = { id = o.id, page = page.id, o = o }
		end
	end
end

check("every feature has a page", #pages == 5, table.concat(pages, ", "))
check("...and there are options on all of them", (function()
	local seen = {}
	for _, e in ipairs(opts) do seen[e.page] = true end
	for _, p in ipairs(pages) do if not seen[p] then return false, p end end
	return true
end)())

-- ------------------------------------------------- section rules
-- A "line" separates one captioned group from the one above it, so it is only correct
-- where a group is actually above it. Two placements are wrong and neither shows up in
-- any other check -- the menu draws them perfectly:
--
--   * a rule directly under the page banner, which rules off the title art. This is the
--     shape that got the rules removed at R2.44; they came back at R2.60 without it.
--   * a rule between two adjacent captions, which rules off an empty group.
--
-- ...and the inverse, since a rule that is simply missing is the same kind of silent:
-- every caption with rows above it on its page must have one.
do
	local misplaced, missing = {}, {}
	for _, page in ipairs(menu.gr) do
		for i, o in ipairs(page.gr) do
			local prev = page.gr[i - 1]
			if o.type == "line" then
				if not prev or prev.type == "slide" or prev.type == "title" then
					misplaced[#misplaced + 1] = page.id .. "/" .. tostring(o.id) ..
						" (above it: " .. (prev and prev.type or "nothing") .. ")"
				end
			elseif o.type == "title" and prev and prev.type ~= "slide"
			       and prev.type ~= "title" and prev.type ~= "line" then
				missing[#missing + 1] = page.id .. "/" .. tostring(o.id)
			end
		end
	end
	check("no section rule sits above the banner or an empty group", #misplaced == 0,
		table.concat(misplaced, "; "))
	check("...and every caption with a group above it has one", #missing == 0,
		table.concat(missing, "; "))
end

-- A rule left behind by a hidden caption separates two groups that are adjacent. They
-- are built as a pair, so the pairing is what to check: same precondition list, both
-- present or neither.
do
	local unpaired = {}
	for _, page in ipairs(menu.gr) do
		for i, o in ipairs(page.gr) do
			if o.type == "line" then
				local cap = page.gr[i + 1]
				local a = (o.precondition or {})[1]
				local b = (cap and cap.precondition or {})[1]
				if not cap or cap.type ~= "title" or a ~= b then
					unpaired[#unpaired + 1] = page.id .. "/" .. tostring(o.id)
				end
			end
		end
	end
	check("every rule shares its caption's precondition", #unpaired == 0,
		table.concat(unpaired, "; "))
end

-- ------------------------------------------------- 1. menu vs PAGE_OF
-- The one that silently resets everyone's settings when it breaks.
local page_of = MK.PAGE_OF
check("iqm_core exports PAGE_OF", type(page_of) == "table")

local mismatched = {}
for _, e in ipairs(opts) do
	local want = page_of[e.id] or "cards"
	if want ~= e.page then
		mismatched[#mismatched + 1] = string.format("%s: menu=%s PAGE_OF=%s", e.id, e.page, want)
	end
end
check("every option is stored where read_config looks for it", #mismatched == 0,
	table.concat(mismatched, "; "))

-- ...and the other way: a PAGE_OF entry naming a page that does not exist is a key
-- read_config will look for at a path the menu never writes.
local orphan_pages = {}
for key, page in pairs(page_of) do
	local found = false
	for _, p in ipairs(pages) do if p == page then found = true end end
	if not found then orphan_pages[#orphan_pages + 1] = key .. " -> " .. page end
end
check("PAGE_OF names no page the menu does not have", #orphan_pages == 0,
	table.concat(orphan_pages, "; "))

-- Every DEFAULTS key should be reachable from the menu, and every menu option should
-- be a real DEFAULTS key. The first catches a setting that became unconfigurable; the
-- second catches a row whose value nothing reads.
local d = MK.DEFAULTS
local in_menu = {}
for _, e in ipairs(opts) do in_menu[e.id] = true end
local unreachable, phantom = {}, {}
for key in pairs(d) do
	if not in_menu[key] then unreachable[#unreachable + 1] = key end
end
for _, e in ipairs(opts) do
	if d[e.id] == nil then phantom[#phantom + 1] = e.id end
end
table.sort(unreachable)
table.sort(phantom)
check("every default has a menu row", #unreachable == 0, table.concat(unreachable, ", "))
check("every menu row has a default", #phantom == 0, table.concat(phantom, ", "))

-- ...AND THE ROW CAN ACTUALLY REACH THAT DEFAULT (R2.43). "Reachable from the menu" above
-- means a row exists; this asks the harder question, which is whether the value the mod
-- ships with is one of the values the slider can produce. A track only lands on
-- min + k*step, so a default off that grid is a setting the player can leave and never
-- return to except by resetting the page.
--
-- Not hypothetical: every colour channel was step 5, and not one channel of the accent
-- (224/196/122) or the route (176/196/124) is a multiple of five. Six sliders, none of
-- which could reproduce what they started at.
do
	local off = {}
	for _, e in ipairs(opts) do
		local o = e.o
		if o.type == "track" and type(o.def) == "number" and o.step and o.min then
			local k = (o.def - o.min) / o.step
			if math.abs(k - math.floor(k + 0.5)) > 1e-6 then
				off[#off + 1] = string.format("%s (def %s, min %s, step %s)",
					e.id, tostring(o.def), tostring(o.min), tostring(o.step))
			end
			-- ...and inside its own range, which is the same question at the ends.
			if o.def < o.min or (o.max and o.def > o.max) then
				off[#off + 1] = string.format("%s (def %s outside %s..%s)",
					e.id, tostring(o.def), tostring(o.min), tostring(o.max))
			end
		end
	end
	table.sort(off)
	check("every track can land on its own default", #off == 0,
		off[1] and (#off .. " cannot: " .. table.concat(off, "; ")) or nil)
end

-- Colour channels are 8-bit quantities and their sliders should have 8-bit resolution.
-- Asserted by NAME rather than by range, since the alpha tracks share the 0..255 range
-- and are deliberately coarser -- opacity is a continuum where 2% is a real increment,
-- a colour channel is 256 discrete values and quantising it just removes most of them.
do
	local coarse = {}
	for _, e in ipairs(opts) do
		if e.id:match("_[rgb]$") and e.o.type == "track" and (e.o.step or 1) ~= 1 then
			coarse[#coarse + 1] = e.id .. " step " .. tostring(e.o.step)
		end
	end
	table.sort(coarse)
	check("every colour channel steps by 1", #coarse == 0, table.concat(coarse, ", "))
end

-- ------------------------------------------------- 2. live preconditions
-- Fill storage the way MCM would, from the menu's own declarations, with every
-- boolean ON. A precondition that still hides its row under those conditions is
-- reading a path that does not exist -- which is exactly what a page rename does to
-- a hand-written "iqm/core/mark_targets".
--
-- NOT EVERY SWITCH IS A BOOLEAN, which "every boolean ON" quietly assumed. A KEY BIND'S
-- "on" IS A BOUND KEY, not its default: both hotkeys default to -1 (unbound), which is a
-- real state with real consequences -- "always shown" for the nameplates, "always drawn"
-- for the route -- but it is the OFF end of that row, and rows that exist only once a key
-- is bound (route_mod) would be unreachable for ever without this. R2.58: the summon's
-- modifier row was the first one it could not see.
--
-- A LIST whose off is one of its values (focus_mode's 0) would be the same gap, and R2.59
-- briefly carried a per-key table for it. Nothing needs it now: no row is gated on a list.
-- If one ever is, this is where its "on" value belongs -- not in the type rules above,
-- because which value of a list means on is a fact about that option and nothing else.
for _, e in ipairs(opts) do
	local path = "iqm/" .. e.page .. "/" .. e.id
	local def = e.o.def
	if e.o.type == "check" then def = true end
	if e.o.type == "key_bind" then def = 42 end   -- any bound DIK; nothing reads which
	STORE[path] = def
end

local hidden = {}
local function eval(o, id, page)
	if not o.precondition then return true end
	for _, fn in ipairs(o.precondition) do
		local ok, res = pcall(fn)
		if not ok then
			hidden[#hidden + 1] = string.format("%s/%s errored: %s", page, id, tostring(res))
			return false
		end
		if not res then return false end
	end
	return true
end

for _, e in ipairs(opts) do
	if not eval(e.o, e.id, e.page) then
		hidden[#hidden + 1] = e.page .. "/" .. e.id
	end
end
-- The notes are the deliberate exception: they are shown only when something is OFF or
-- MISSING, which is the opposite of everything else. "route_summon_unbound" joined them at
-- R2.58 -- it says what a summoned route with no key bound anywhere does, so a state with
-- every key bound is exactly when it should NOT be there.
for _, e in ipairs(support) do
	local inverted = e.id == "reveal_no_mcm" or e.id == "route_summon_unbound"
	                 or e.id:find("no_targets")
	if not inverted and not eval(e.o, e.id, e.page) then
		hidden[#hidden + 1] = e.page .. "/" .. e.id .. " (section)"
	end
end
check("with everything switched on, every row is reachable", #hidden == 0,
	table.concat(hidden, "; "))

-- ...AND THE INVERSE IS NOW THE POINT (R2.59). This block used to assert that switching a
-- gate off HID what rode it -- "no quest target cards hides the route pages' controls",
-- "no work cards hides the work probe", and five more. Every one of those is now the
-- opposite assertion, because setting-gated rows are gone: MCM evaluates a precondition
-- when it BUILDS the page, so a row a gate reveals does not appear until the menu is
-- closed and reopened, and a menu you cannot read at a glance is a worse failure than a
-- slider sitting inert. The gates that remain are about the INSTALL or are NOTES, neither
-- of which this loop can switch off.
--
-- Written as a sweep rather than as named pairs so it cannot rot into a list that happens
-- to name only the rows somebody remembered: EVERY option row is checked against EVERY
-- feature switch turned off, one at a time.
local SWITCHES = {
	"iqm/cards/mark_targets", "iqm/cards/mark_work", "iqm/cards/mark_guiders",
	"iqm/cards/mark_traders", "iqm/worldview/mark_route", "iqm/minimap/mark_minimap",
	"iqm/beacons/mark_beacon", "iqm/beacons/beacon_range", "iqm/general/map_icons",
}
-- The four rows gated on the INSTALL, which this sweep must not expect to be visible: the
-- stubs above make them present, but they are not what is being switched, and listing them
-- keeps the sweep honest about what it is not covering.
local INSTALL_GATED = { reveal_key = true, reveal_mod = true, reveal_mode = true,
                        beacon_waypoint = true, beacon_party = true,
                        route_key = true, route_mod = true }
for _, path in ipairs(SWITCHES) do
	local was = STORE[path]
	local gone = {}
	for _, off in ipairs({ false, 0 }) do
		STORE[path] = off
		for _, e in ipairs(opts) do
			if not INSTALL_GATED[e.id] and not eval(e.o, e.id, e.page) then
				gone[#gone + 1] = e.page .. "/" .. e.id
			end
		end
	end
	STORE[path] = was
	check("every control is still reachable with " .. path .. " off", #gone == 0,
		table.concat(gone, "; "))
end

-- ...including the two numeric switches, whose off is a value rather than a false, and
-- which are the ones a `nil > 0` gate would error on. focus_mode is checked UNSET as well:
-- that is a first run, before the player has opened the page at all.
for _, path in ipairs({ "iqm/cards/focus_mode", "iqm/general/dim_hold",
                        "iqm/beacons/beacon_ctr", "iqm/worldview/route_reveal" }) do
	local was = STORE[path]
	local gone = {}
	for _, off in ipairs({ 0, false }) do
		STORE[path] = off
		for _, e in ipairs(opts) do
			if not INSTALL_GATED[e.id] and not eval(e.o, e.id, e.page) then
				gone[#gone + 1] = e.page .. "/" .. e.id
			end
		end
	end
	STORE[path] = nil                       -- never written: a first run
	for _, e in ipairs(opts) do
		if not INSTALL_GATED[e.id] and not eval(e.o, e.id, e.page) then
			gone[#gone + 1] = e.page .. "/" .. e.id .. " (unset)"
		end
	end
	STORE[path] = was
	check("every control is still reachable with " .. path .. " off or unset", #gone == 0,
		table.concat(gone, "; "))
end

-- The shared chevron spacing was the one route setting that had to survive EITHER view
-- being off, since it shapes the published route both of them read. It now survives both
-- being off as well, along with everything else -- so what is left worth pinning is that
-- it never had a gate of its own to lose.
do
	local gap = (function()
		for _, e in ipairs(opts) do if e.id == "route_gap" then return e.o end end
	end)()
	check("chevron spacing carries no precondition at all", gap and gap.pre == nil,
		"a minimap-only player unable to reach it is the bug this replaces")
end

-- ------------------------------------------------- 3. translations
local missing_eng, missing_rus, wanted = {}, {}, {}
local function want(id)
	if not id or mcm_own(id) or wanted[id] then return end
	wanted[id] = true
	if not ENG[id] then missing_eng[#missing_eng + 1] = id end
	if not RUS[id] then missing_rus[#missing_rus + 1] = id end
end

for _, e in ipairs(opts) do
	-- on_mcm_load's own loop points every value option's hint at the flat id -- UNLESS
	-- the row already set one, which is how the reveal modifier borrows MCM's caption
	-- and description wholesale (see the note on reveal_mod). Those rows deliberately
	-- ship no strings of their own, so asking for them would fail on purpose.
	if e.o.hint == "iqm_" .. e.id then
		want("ui_mcm_iqm_" .. e.id)
	end
	for _, pair in ipairs(e.o.content or {}) do
		local v = pair[2]
		if not mcm_own(v) then want("ui_mcm_lst_" .. v) end
	end
end
for _, e in ipairs(support) do want(e.o.text) end
for _, page in ipairs(menu.gr) do want(page.text) end

table.sort(missing_eng)
table.sort(missing_rus)
check("every id the menu names is in the English string table", #missing_eng == 0,
	table.concat(missing_eng, ", "))
check("...and in the Russian one", #missing_rus == 0, table.concat(missing_rus, ", "))

-- Descriptions are separate ids and just as easy to forget; MCM shows an empty
-- tooltip rather than complaining.
local missing_desc = {}
for _, e in ipairs(opts) do
	if e.o.hint == "iqm_" .. e.id and not ENG["ui_mcm_iqm_" .. e.id .. "_desc"] then
		missing_desc[#missing_desc + 1] = e.id
	end
end
table.sort(missing_desc)
check("every option has a description", #missing_desc == 0, table.concat(missing_desc, ", "))

-- ...AND BOTH HALVES OF THE PAIR, IN BOTH LOCALES, FOR EVERY KEY IN THE REGISTRY.
--
-- The one drift class the R2.46 collapse could not close by construction. Three of the
-- four places an option used to be declared are now one table, but the strings are in
-- two XML files that no Lua reads, so a key added to the registry with no caption draws
-- its raw id, and a key with no DESCRIPTION draws an empty tooltip -- which looks like a
-- description nobody wrote rather than one nobody added, and so survives review.
--
-- Asserted off iqm_core.OPTIONS rather than off the built menu, which is the stricter
-- direction: the menu is what the registry produced, so a key that never reached a page
-- would drop out of the loops above and be checked by nothing. The two rows that borrow
-- MCM's own strings (reveal_mod's caption and description are "mcm_kb_modifier") are the
-- deliberate exception, and are recognised by their explicit hint, not by name.
--
-- The Russian file is cp1251, not UTF-8. It is read as BYTES here, which is all the id
-- scan needs -- and never written, because a text-mode write through a wrong codec
-- truncates the file to zero bytes and takes the deployed copy with it.
do
	local gaps = {}
	for _, o in ipairs(MK.OPTIONS) do
		if o.key and not o.hint then
			for _, pair in ipairs({ { "eng", ENG }, { "rus", RUS } }) do
				local base = "ui_mcm_iqm_" .. o.key
				if not pair[2][base] then
					gaps[#gaps + 1] = pair[1] .. ":" .. o.key
				end
				if not pair[2][base .. "_desc"] then
					gaps[#gaps + 1] = pair[1] .. ":" .. o.key .. "_desc"
				end
			end
		end
	end
	table.sort(gaps)
	check("every registry key has a label AND a description in eng AND rus",
		#gaps == 0, #gaps .. " missing: " .. table.concat(gaps, ", "))
end

-- Every `pre` the registry names must resolve to a closure in iqm_mcm. It cannot resolve
-- to nothing quietly: an empty precondition list reads as "always show", so a typo would
-- UN-GATE a row rather than break it, and every check above would still pass.
do
	local unknown = {}
	for _, o in ipairs(MK.OPTIONS) do
		if o.pre and MCM.PRE and MCM.PRE[o.pre] == nil then
			unknown[#unknown + 1] = tostring(o.key or o.id or o.section) .. " -> " .. o.pre
		end
	end
	check("iqm_mcm has a closure for every precondition the registry names",
		MCM.PRE ~= nil and #unknown == 0,
		MCM.PRE == nil and "iqm_mcm.PRE is not readable" or table.concat(unknown, ", "))
end

-- Ids are per PAGE in MCM's storage, so a duplicate within one page is a collision:
-- two rows writing the same key. Across pages it is fine.
local dupes = {}
do
	local seen = {}
	for _, e in ipairs(opts) do
		local k = e.page .. "/" .. e.id
		if seen[k] then dupes[#dupes + 1] = k end
		seen[k] = true
	end
	for _, e in ipairs(support) do
		local k = e.page .. "/" .. e.id
		if seen[k] then dupes[#dupes + 1] = k end
		seen[k] = true
	end
end
check("no two rows on a page share an id", #dupes == 0, table.concat(dupes, ", "))

-- ------------------------------------------------- no legacy fallback
-- The page split deliberately does NOT carry pre-split settings over: everyone starts
-- from defaults on the new pages. That is a decision, so it is worth one check that it
-- has not been half-undone later by a fallback that cannot work.
--
-- ui_mcm.get refuses any path the current menu does not declare -- `if not opt_val[id]
-- then printe("!MCM given bad path") return end` (ui_mcm.script:711) -- so reading an old
-- "iqm/core/..." path through it returns nil AND writes an error line to the log for
-- every key, on every option change. Reaching an orphaned value at all would mean going
-- around MCM to axr_options.ltx directly. Neither belongs here.
local legacy = {}
for _, pat in ipairs({ "iqm/core/", "iqm/advanced/", "WAS_CORE", "axr_options" }) do
	if markers_src:find(pat, 1, true) then legacy[#legacy + 1] = pat end
end
check("iqm_core reads no pre-split storage path", #legacy == 0,
	table.concat(legacy, ", ") .. " -- unreachable through ui_mcm.get")

-- Every option therefore resolves through exactly one live path, built from PAGE_OF.
check("read_config builds the path from PAGE_OF and nothing else",
	markers_src:find('PAGE_OF[key] or "cards"', 1, true) ~= nil)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
