-- Harness: run the REAL DXML pipeline over the REAL PDA files and check that
-- modxml_n_iqm_map_icons rewrites them the way it claims to - the symbols panel in
-- pda_tasks_16.xml, and the squad markers in map_spots_16.xml.
--
-- WHY THIS ONE EXISTS. A DXML patch has no failure mode that says anything. A query that
-- matches nothing, a callback registered too early, a file name spelled with the wrong
-- separator -- all of them produce a game that starts, a menu that draws, and the old art
-- still on screen. This module's own header records that happening once already (the PAW
-- entry was a silent no-op until the file was renamed to sort after PAW's own script).
-- So the only way to know is to run the actual parser over the actual file.
--
-- WHAT IT LOADS. Anomaly's own slaxml.script and dxml_core.script from the installed
-- game, plus AlphaLion's pda_tasks_16.xml (the winning copy in this pack) and base
-- Anomaly's own, and then calls COnXmlRead exactly as the engine does
-- (dxml_core.script:977, "Called from ScriptXMLInit.cpp"). No mocking of the parser, the
-- query engine or the serializer -- those are the parts most likely to be misunderstood.
--
-- Paths into the install are unavoidable here and are checked first: on a machine
-- without GAMMA at D:\gamma0.9.5 this SKIPS rather than fails, so check-lua.py stays
-- green anywhere while still proving the patch on the machine that has the game.
--
-- Usage:
--   luajit tools/legend-harness/harness.lua
--   VERBOSE=1 luajit tools/legend-harness/harness.lua

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

local GAME = "D:/gamma0.9.5/Anomaly/"
local AL   = "D:/gamma0.9.5/GAMMA/mods/AlphaLion's Reworked Stash Quest and Map Markers/"

local function slurp(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

local SRC = {
	slaxml  = GAME .. "gamedata/scripts/slaxml.script",
	dxml    = GAME .. "gamedata/scripts/dxml_core.script",
	al      = AL   .. "gamedata/configs/ui/pda_tasks_16.xml",
	vanilla = GAME .. "tools/_unpacked/configs/ui/pda_tasks_16.xml",
	-- The winning copy of the spot file in this pack, per the VFS manifest. Sota UI
	-- beats Display Campfires on Map for it; both ship one.
	spots   = "D:/gamma0.9.5/GAMMA/mods/Sota UI EGUI Style HUD/gamedata/configs/ui/map_spots_16.xml",
}
for _, p in pairs(SRC) do
	if not slurp(p) then
		print("  skip  legend: DXML core or the PDA layouts are not on this machine")
		print("0 passed, 0 failed")
		os.exit(0)
	end
end

-- ---------------------------------------------------------------- engine env
-- Only what dxml_core and slaxml actually touch. The _g helpers are reimplemented
-- rather than loaded, because _g.script is an engine-dependent 2000-line module and
-- these four functions are the whole of what is used.
local ENV = {}
ENV.pairs, ENV.ipairs, ENV.tostring, ENV.tonumber = pairs, ipairs, tostring, tonumber
ENV.type, ENV.string, ENV.table, ENV.math, ENV.os, ENV.io = type, string, table, math, os, io
ENV.setmetatable, ENV.getmetatable = setmetatable, getmetatable
ENV.print, ENV.pcall, ENV.select, ENV.error, ENV.assert = print, pcall, select, error, assert
ENV.unpack, ENV.rawget, ENV.rawset, ENV.next = unpack, rawget, rawset, next
ENV.loadstring, ENV.setfenv, ENV.tostring = loadstring, setfenv, tostring
ENV._G = ENV

local chatter = os.getenv("VERBOSE") and true or false
ENV.printf = function(fmt, ...)
	if not chatter then return end
	local i, p = 0, { ... }
	print((tostring(fmt):gsub("%%s", function() i = i + 1; return tostring(p[i]) end)))
end
ENV.printf_me = ENV.printf
ENV.printe    = ENV.printf
ENV.callstack = function() end

local function trim(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end
ENV.trim = trim
-- slaxml:73 normalises whitespace inside a tag with this; it is _g_patches.script:104,
-- not base _g, which is why it is easy to miss when reading the parser alone.
ENV.one_space = function(s) return (s:gsub("  *", " ")) end

-- str_explode / str_explode_lim, faithful to _g.script:897 and _g_patches.script:71 --
-- both trim each piece, and both return { str } when the separator is absent.
local function explode(str, sep, n, plain)
	if not (sep ~= "" and str:find(sep, 1, plain)) then return { str } end
	local t, size, pos = {}, 0, 1
	while true do
		if n and size >= n then
			t[size + 1] = trim(str:sub(pos))
			return t
		end
		local a, b = str:find(sep, pos, plain)
		if not a then
			t[size + 1] = trim(str:sub(pos))
			return t
		end
		size = size + 1
		t[size] = trim(str:sub(pos, a - 1))
		pos = b + 1
	end
end
ENV.str_explode     = function(str, sep, plain) return explode(str, sep, nil, plain) end
ENV.str_explode_lim = function(str, sep, n, plain) return explode(str, sep, n, plain) end

ENV.is_empty = function(t)
	if not t then return true end
	for _ in pairs(t) do return false end
	return true
end
ENV.is_not_empty = function(t) return not ENV.is_empty(t) end
ENV.try = function(fn, ...)
	local ok, res = pcall(fn, ...)
	if not ok then print("  (try caught) " .. tostring(res)) return nil end
	return res
end
ENV.k2t_table = function(t)
	local n = 0
	for k in pairs(t) do t[k] = nil; n = n + 1; t[n] = k end
	return t
end

-- Callback plumbing. dxml_core REPLACES _G.RegisterScriptCallback at load time to
-- capture on_xml_read, so these only have to exist and be well behaved.
ENV.AddScriptCallback  = function() end
ENV.SendScriptCallback = function() end
ENV.RegisterScriptCallback   = function() end
ENV.UnregisterScriptCallback = function() end

-- The modxml gather block walks the scripts folder at load time. An empty file list
-- makes it a no-op, and our module is registered by hand below instead -- which is the
-- honest simulation anyway, since what is being tested is the callback, not dxml's
-- ability to find files.
ENV.bit_or = function(a, b) return a end
ENV.FS = { FS_ListFiles = 1, FS_RootOnly = 2 }

-- r_open has to be real, not a stub. slaxml resolves #include itself (slaxml:83-121)
-- rather than leaving it to the caller, and the spot files are nothing but includes -
-- so without this the parse dies the moment anything splices one in, which is what our
-- own patch does. It must return an IReader: r_eof/r_u8, byte at a time.
--
-- The path is resolved through the VFS MANIFEST, the same oracle tools/map-icons uses,
-- so the harness reads the copy that actually wins rather than the first one on disk -
-- map_spots_milpda.xml is shipped by Milspec PDA and won by Personal Adjustable
-- Waypoint, and a naive search would read the loser.
local MANIFEST = "D:/gamma0.9.5/manifest/vfs_manifest.tsv"
local UNPACKED = GAME .. "tools/_unpacked/configs/"

local winner = {}
do
	local fh = io.open(MANIFEST, "rb")
	if fh then
		for line in fh:lines() do
			local vp, _, real = line:match("^([^\t]+)\t([^\t]*)\t([^\t]+)")
			if vp then winner[vp:gsub("/", "\\"):lower()] = real end
		end
		fh:close()
	end
end

local function reader(text)
	local i = 0
	return {
		r_eof = function() return i >= #text end,
		r_u8  = function() i = i + 1; return text:byte(i) end,
	}
end

ENV.getFS = function()
	return {
		file_list_open_ex = function() return { Size = function() return 0 end } end,
		update_path = function() return "" end,
		r_open = function(_, _, path)
			local key = ("gamedata\\configs\\" .. path):gsub("/", "\\"):lower()
			local body = winner[key] and slurp(winner[key])
			           or slurp(UNPACKED .. path:gsub("\\", "/"))
			           -- our own spliced file lives in this repo, not the install
			           or slurp(ROOT .. "gamedata/configs/" .. path:gsub("\\", "/"))
			if not body then return nil end
			return reader(body)
		end,
	}
end

local function load_module(path, name)
	local src = slurp(path)
	local M = setmetatable({}, { __index = ENV })
	M._G = ENV
	local chunk = assert(loadstring(src, "@" .. name))
	setfenv(chunk, M)
	assert(pcall(chunk))
	ENV[name] = M
	return M
end

load_module(SRC.slaxml, "slaxml")
-- dxml_core writes COnXmlRead and the RegisterScriptCallback replacement into _G, so it
-- has to see ENV as its global table.
local DXML = load_module(SRC.dxml, "dxml_core")
check("dxml_core loaded and exported COnXmlRead", type(ENV.COnXmlRead) == "function")

-- ...and our patch, registered through the same replaced RegisterScriptCallback the
-- game uses. If the callback never lands, every assertion below fails -- which is the
-- point: that is the failure mode that is silent in game.
local MOD = load_module(ROOT .. "gamedata/scripts/modxml_n_iqm_map_icons.script",
                        "modxml_n_iqm_map_icons")
MOD.on_xml_read()

-- ------------------------------------------------------------------- helpers
--- The <item> block containing `needle`, as raw text, so assertions can be made about
--  one row without matching another's attributes.
local function row_with(xml, needle)
	local from = 1
	while true do
		local s, e = xml:find("<item.-</item>", from)
		if not s then return nil end
		local block = xml:sub(s, e)
		if block:find(needle, 1, true) then return block end
		from = e + 1
	end
end

local function count(xml, needle)
	local n, from = 0, 1
	while true do
		local s, e = xml:find(needle, from, true)
		if not s then return n end
		n, from = n + 1, e + 1
	end
end

-- ============================================================ AlphaLion's legend
print("-- AlphaLion's legend (the winning copy in this pack) -----------------")

local al_in  = slurp(SRC.al)
local al_out = ENV.COnXmlRead([[ui\pda_tasks_16.xml]], al_in)

check("the file came back changed at all", al_out ~= al_in,
	"the callback did not fire, or matched nothing")

-- DUMP=1 prints the panel as the engine would receive it. The one thing worth looking
-- at by eye here, and the fastest way to see what a failing assertion below is failing
-- against, since DXML re-serializes attributes in table order.
if os.getenv("DUMP") then
	local s = al_out:find("<legend_list", 1, true)
	local e = al_out:find("</legend_list>", 1, true)
	print(al_out:sub(s, e))
end

-- Nine rows, one per mark we re-skin on the map itself.
local ROWS = {
	{ "ui_AlphaLion_PrimaryMission",   "iqm_mapspot_task",       'r="246"' },
	{ "ui_AlphaLion_SecondaryMission", "iqm_mapspot_task",       'r="240"' },
	{ "ui_AlphaLion_Trader-large",     "iqm_mapspot_trader",     'g="198"' },
	{ "ui_AlphaLion_Mechanic-large",   "iqm_mapspot_mechanic",   'r="120"' },
	{ "ui_AlphaLion_Barman-large",     "iqm_mapspot_barman",     'r="255"' },
	{ "ui_AlphaLion_Medic-large",      "iqm_mapspot_medic",      'r="238"' },
	{ "ui_AlphaLion_Companion",        "iqm_mapspot_vip",        'r="40"' },
	{ "ui_AlphaLion_Special-large",    "iqm_mapspot_vip",        'r="190"' },
	{ "ui_AlphaLion_Transition",       "iqm_mapspot_transition", 'r="102"' },
}
-- The rows are found in the OUTPUT by the caption they still carry, since the texture
-- they were found by is exactly what has been replaced.
local CAPTION = {
	["ui_AlphaLion_PrimaryMission"]   = "st_ui_pda_legend_main_task",
	["ui_AlphaLion_SecondaryMission"] = "st_ui_pda_legend_additional_task",
	["ui_AlphaLion_Trader-large"]     = "st_ui_pda_legend_trader",
	["ui_AlphaLion_Mechanic-large"]   = "st_ui_pda_legend_mechanic",
	["ui_AlphaLion_Barman-large"]     = "st_ui_pda_legend_barman",
	["ui_AlphaLion_Medic-large"]      = "st_ui_pda_legend_medic",
	["ui_AlphaLion_Companion"]        = "Companion",
	["ui_AlphaLion_Special-large"]    = "st_ui_pda_legend_special",
	["ui_AlphaLion_Transition"]       = "Map transition",
	-- Fast travel is kept here, unused by ROWS above, because the NEGATIVE check below
	-- needs to find the row in order to prove we left it alone. A hardcoded English
	-- literal, not a string id -- AlphaLion typed it straight into pda_tasks_16.xml:305.
	-- Matching on prose is acceptable here and only here: this table exists to FIND a row,
	-- and a caption that stops matching fails loudly rather than silently passing.
	["ui_AlphaLion_Location"]         = "Fast travel location",
}

for _, r in ipairs(ROWS) do
	local old, tex, tint = r[1], r[2], r[3]
	local block = row_with(al_out, CAPTION[old])
	check(old .. " -> " .. tex, block and block:find(tex, 1, true) ~= nil,
		block and block:gsub("%s+", " "):sub(1, 120))
	check("...tinted (" .. tint .. ")", block and block:find(tint, 1, true) ~= nil)
	check("...and its swatch squared to 19x19",
		block and block:find('width="19"', 1, true) and block:find('height="19"', 1, true))
	check("...with the old texture gone", not al_out:find(old, 1, true))
end

-- The gaps are as deliberate as the entries: a row whose spot we do not re-skin has to
-- come through with its art untouched.
for _, keep in ipairs({ "ui_AlphaLion_Stash-regular", "ui_AlphaLion_Stash-valuable",
                        "ui_AlphaLion_Stash-UNISG", "ui_AlphaLion_Stash-self",
                        "ui_AlphaLion_Area-small",
                        "ui_AlphaLion_PlayerPDAtip", "ui_AlphaLion_Storage-large",
                        "ui_AlphaLion_Important-large", "ui_AlphaLion_SquadLeader",
                        -- FAST TRAVEL, and this one is a regression test rather than a
                        -- gap that was always there. The row was claimed in R2.55 when
                        -- SPOTS patched fast_travel_spot and released again when that was
                        -- reverted, so it has been on both sides of this check. A legend
                        -- row is a claim that the panel and the map show the same mark;
                        -- leaving it patched while the map went back to AlphaLion's house
                        -- would make the panel lie. If someone re-adds the SPOTS entry,
                        -- THIS is the assertion that will fail and tell them the legend
                        -- row has to move with it -- move the id back up to ROWS then.
                        "ui_AlphaLion_Location" }) do
	check("left alone: " .. keep, count(al_out, keep) == count(al_in, keep),
		count(al_in, keep) .. " -> " .. count(al_out, keep))
end

-- ...and the row survives intact, not merely unreplaced: a legend row whose <image> we had
-- squared to 19x19 but whose texture we then stopped changing would be the worst of both.
check("fast travel row keeps AlphaLion's own 11x19 swatch",
	(function()
		local b = row_with(al_out, CAPTION["ui_AlphaLion_Location"])
		return b and b:find('width="11"', 1, true) ~= nil
	end)())

-- Nothing outside the legend may be re-pointed. It cannot be asserted by comparing the
-- text: DXML re-serializes the WHOLE document, so whitespace and attribute order differ
-- everywhere even in a file it did not mean to touch. What can be asserted is the thing
-- that matters -- the sequence of texture ids outside the panel is identical, and none
-- of ours has appeared among them.
local function textures_outside(xml)
	local s = xml:find("<legend_list", 1, true)
	local e = xml:find("</legend_list>", 1, true)
	local rest = xml:sub(1, s - 1) .. xml:sub(e)
	local out = {}
	-- The separator capture is what keeps <texture_e> and <texture_t> (the button
	-- states elsewhere in this file) out of the list: after "texture" they have a "_",
	-- which is neither a space nor a ">".
	for sep, t in rest:gmatch("<texture([ >])(.-)</texture>") do
		out[#out + 1] = sep .. t
	end
	return table.concat(out, "|")
end
do
	local a, b = textures_outside(al_in), textures_outside(al_out)
	local d = ""
	if a ~= b then
		for i = 1, math.max(#a, #b) do
			if a:sub(i, i) ~= b:sub(i, i) then
				d = "at " .. i .. ": in=[" .. a:sub(i - 60, i + 40) .. "] out=[" .. b:sub(i - 60, i + 40) .. "]"
				break
			end
		end
	end
	check("no texture outside the symbols panel was re-pointed", a == b, d)
end

-- ================================================================ base Anomaly
print("\n-- base Anomaly's legend (no AlphaLion) -------------------------------")

local v_in  = slurp(SRC.vanilla)
local v_out = ENV.COnXmlRead([[ui\pda_tasks_16.xml]], v_in)

check("the vanilla panel is patched too", v_out ~= v_in)
check("...the trader row takes our badge", (row_with(v_out, "st_ui_pda_legend_trader") or "")
	:find("iqm_mapspot_trader", 1, true) ~= nil)

-- The one that would have gone wrong quietly: vanilla's rows carry color="pda_blue",
-- and a NAMED colour beats r/g/b outright in CUIXmlInit::GetColor. Left in place it
-- would paint every one of our glyphs the same blue -- the map's colour coding thrown
-- away, and worse than not patching at all.
local vtrader = row_with(v_out, "st_ui_pda_legend_trader") or ""
check("...with the named colour REMOVED, so the tint is ours",
	not vtrader:find("pda_blue", 1, true), vtrader:gsub("%s+", " "):sub(1, 140))
-- g rather than r: the trader teal has r=0, and 'r="0"' is not a distinctive
-- enough literal to be worth asserting on.
check("...and r/g/b set instead", vtrader:find('g="198"', 1, true) ~= nil)
check("a row we have no art for keeps its named colour",
	(row_with(v_out, "st_ui_pda_actor_box") or ""):find("pda_blue", 1, true) ~= nil)

-- =================================================================== no false positives
-- ============================================================ the squad markers
print("\n-- squad markers in the real spot file ---------------------------------")

-- The squad block is 50 selectors, the largest in the mod by a wide margin, and the
-- only one whose element names were not typed out by hand - they were generated from a
-- parse of this same file by Python's ElementTree. Two different parsers agreeing on a
-- name is exactly the assumption that is worth checking, because dxml's query engine is
-- what has to resolve them in game and a query matching nothing is silent.
--
-- These entries also set NO r/g/b, which is load-bearing rather than an omission: the
-- faction and relation colours already on those elements are the whole information the
-- marker carries. So the tint surviving the patch is asserted too.
local spots_in = slurp(SRC.spots)
local spots_out = ENV.COnXmlRead([[ui\map_spots_16.xml]], spots_in)

check("the spot file came back changed at all", spots_out ~= spots_in)

local mod_src = slurp(ROOT .. "gamedata/scripts/modxml_n_iqm_map_icons.script")
local wanted, n_squad = {}, 0
for sel, tex in mod_src:gmatch('{ sel = "([%w_]+)",%s+tex = "(iqm_mapspot_squad%w*)" }') do
	wanted[sel] = tex
	n_squad = n_squad + 1
end
check("the script still declares the squad block", n_squad == 50,
	"found " .. n_squad .. " squad entries, expected 50")

-- Asserted against the OUTPUT rather than by re-querying the DOM: what the engine gets
-- is the serialized text, so this also catches a patch that edits a detached node.
local missing = {}
for sel in pairs(wanted) do
	if not spots_out:find("<" .. sel .. "[ >]") then missing[#missing + 1] = sel end
end
check("every squad element still exists in the output", #missing == 0,
	table.concat(missing, ", "))

-- Guard against the two assertions below passing for the wrong reason. "the vanilla id
-- is absent from the output" is only evidence of a patch if it was present in the input,
-- and a rename upstream would otherwise turn both into silent green.
--
-- COMMENTS STRIPPED FIRST, and that is not tidiness. Sota UI's copy carries four
-- commented-out copies of each map id - 32 and 24 raw against the 28 and 20 elements
-- that really exist. slaxml drops comments before the DOM is built, so counting the raw
-- text here would assert against four marks that cannot be patched because they are not
-- there, and the failure would look exactly like four missed selectors.
local live_in = spots_in:gsub("<!%-%-.-%-%->", "")
check("the input really did carry vanilla's squad art",
	count(live_in, "ui_pda2_squad_leader") == 28
		and count(live_in, "ui_minimap_squad_leader") == 20
		and count(live_in, "ui_mmap_squad_leader") == 2,
	string.format("input had %d/%d/%d, expected 28/20/2",
		count(live_in, "ui_pda2_squad_leader"),
		count(live_in, "ui_minimap_squad_leader"),
		count(live_in, "ui_mmap_squad_leader")))

check("no squad element still draws vanilla's map art",
	not spots_out:find("ui_pda2_squad_leader", 1, true),
	"ui_pda2_squad_leader survived the patch somewhere")
check("no squad element still draws vanilla's minimap art",
	not spots_out:find("ui_minimap_squad_leader", 1, true)
		and not spots_out:find("ui_mmap_squad_leader", 1, true),
	"a minimap squad texture survived the patch")

check("28 elements took the map cell",
	count(spots_out, "iqm_mapspot_squad<") == 28)
check("22 elements took the minimap cell",
	count(spots_out, "iqm_mapspot_squadmini<") == 22)

-- The tints. One per source of colour, so a regression in any of the three shows up.
local TINTS = {
	{ "warfare_duty_tex",                    'r="192"', 'g="32"' },   -- faction
	{ "warfare_stalker_spot_mini",           'r="255"', 'g="255"' },  -- faction, mini
	{ "alife_presentation_squad_friend_spot", nil,      nil },        -- A-life relation
}
for _, t in ipairs(TINTS) do
	local block = spots_out:match("<" .. t[1] .. "[ >].-</" .. t[1] .. ">")
	check(t[1] .. " kept a tint", block and block:find('r="') ~= nil,
		"the patch cleared r/g/b on " .. t[1])
	if t[2] then
		check(t[1] .. " kept its exact colour",
			block and block:find(t[2], 1, true) and block:find(t[3], 1, true))
	end
end

print("\n-- files this must not touch ------------------------------------------")

-- Again not a text comparison: every file that reaches COnXmlRead is re-serialized
-- whether or not a callback edited it, so "unchanged" has to mean "none of our art
-- ended up in it".
local other = ENV.COnXmlRead([[ui\pda_dialog.xml]], al_in)
check("a file that is not a legend gets none of our art",
	count(other, "iqm_mapspot_") == 0)
check("...and keeps the art it had", count(other, "ui_AlphaLion_PrimaryMission") == 1)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
