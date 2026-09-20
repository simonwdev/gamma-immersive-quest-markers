-- Harness: run the REAL DXML pipeline over the REAL PDA files and check that
-- modxml_n_iqm_map_icons rewrites them the way it claims to - the symbols panel in
-- pda_tasks_16.xml, and the squad markers, the S2 restyle and the task-marker size
-- slider in map_spots_16.xml.
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
-- Paths into the install are unavoidable here and are checked first: on a machine with
-- no GAMMA this SKIPS rather than fails, so check-lua.py stays green anywhere while still
-- proving the patch on a machine that has the game. The roots are DISCOVERED (env var,
-- then the layouts the installers produce) rather than typed, which they were until R2.65
-- -- see the note on first_file for why a hardcoded root is worse than no harness.
--
-- Usage:
--   luajit tools/legend-harness/harness.lua
--   VERBOSE=1 luajit tools/legend-harness/harness.lua
--   IQM_ANOMALY=<...>/anomaly IQM_MODS=<...>/mods luajit tools/legend-harness/harness.lua

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

local function slurp(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

--- The first of these paths that is actually readable, or nil.
--
--  VARARGS, not a table, and that is not a style choice: an unset env var makes the first
--  candidate nil, and ipairs over a table stops dead at the first hole -- so every
--  fallback after it would be skipped on exactly the machines the fallbacks are for.
--  select("#", ...) counts the nil.
local function first_file(...)
	for i = 1, select("#", ...) do
		local p = select(i, ...)
		if p and slurp(p) then return p end
	end
end

-- WHERE THE INSTALL IS. Two roots, both discovered rather than typed, and the reason is
-- worth recording because it is a failure this harness had rather than one it caught: the
-- paths were hardcoded to one machine's D:\gamma0.9.5 until R2.65, so everywhere else --
-- including the machine the mod moved to -- this skipped. A skip prints "0 passed, 0
-- failed" and check-lua.py reports it as ok, which means the ONE harness that runs the
-- real DXML pipeline over the real files spent that time green by not running. Env var
-- first, then the layouts the GAMMA installers produce.
local AL_PROBE = "AlphaLion's Reworked Stash Quest and Map Markers/gamedata/configs/ui/pda_tasks_16.xml"

local GAME = first_file(os.getenv("IQM_ANOMALY") and
                          os.getenv("IQM_ANOMALY") .. "/gamedata/scripts/dxml_core.script",
                        "D:/gamma0.9.5/Anomaly/gamedata/scripts/dxml_core.script",
                        "C:/games/gamma0.9.5/anomaly/gamedata/scripts/dxml_core.script")
GAME = GAME and GAME:gsub("gamedata/scripts/dxml_core%.script$", "") or ""

local MODS = first_file(os.getenv("IQM_MODS") and os.getenv("IQM_MODS") .. "/" .. AL_PROBE,
                        "D:/gamma0.9.5/GAMMA/mods/" .. AL_PROBE,
                        "C:/games/gamma0.9.5/gamma/mods/" .. AL_PROBE)
MODS = MODS and MODS:gsub("AlphaLion's.*$", "") or ""

local AL = MODS .. "AlphaLion's Reworked Stash Quest and Map Markers/"

local SRC = {
	slaxml  = GAME .. "gamedata/scripts/slaxml.script",
	dxml    = GAME .. "gamedata/scripts/dxml_core.script",
	al      = AL   .. "gamedata/configs/ui/pda_tasks_16.xml",
	vanilla = GAME .. "tools/_unpacked/configs/ui/pda_tasks_16.xml",
	-- The winning copy of the spot file, and WHICH MOD WINS IT DEPENDS ON THE MODLIST --
	-- Sota UI on one install, Display Campfires on Map on another; both ship one, and a
	-- list with neither falls back to the base game's. That is not a compromise here:
	-- what is asserted below is what OUR callback does to whatever file it is handed, and
	-- every candidate carries the same 28/20/2 squad elements, which the input check
	-- further down asserts rather than assumes.
	spots   = first_file(MODS .. "Sota UI EGUI Style HUD/gamedata/configs/ui/map_spots_16.xml",
	                     MODS .. "226- Display Campfires on Map - Maid/gamedata/configs/ui/map_spots_16.xml",
	                     GAME .. "tools/_unpacked/configs/ui/map_spots_16.xml")
	           or (GAME .. "tools/_unpacked/configs/ui/map_spots_16.xml"),
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
local MANIFEST = os.getenv("IQM_VFS_MANIFEST") or (GAME .. "../manifest/vfs_manifest.tsv")
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

-- THE ENGINE EXPANDS #include BEFORE OUR CALLBACK EVER SEES THE DOCUMENT, and a fixture
-- that does not do the same is testing a different string than the game hands us.
-- CXml::Load writes the fully expanded document into its own buffer and only then calls
-- XMLLuaCallback (xray-monolith xrXMLParser.cpp:130-143), so on_xml_read always receives
-- one flat file. DXML's parse of that string does NOT re-expand it - the r_open above
-- serves slaxml's own include handling, which is a different path - so feeding the raw
-- file here silently dropped every element living in an include. That included
-- secondary_task_complex_spot_mini_timer, the one id in TASK_SIZED that does, which meant
-- the size pass had a hole in its coverage that every assertion still passed through.
--
-- Resolved through the same manifest as r_open, so an included file is read from the copy
-- that actually WINS rather than the first one on disk. The prolog of an included file is
-- stripped: it is spliced mid-document, where a second <?xml?> is not legal.
local function expand(text, depth)
	depth = depth or 0
	if depth > 8 or not text then return text end
	return (text:gsub('#include%s*"([^"]+)"', function(path)
		local key = ("gamedata\\configs\\" .. path):gsub("/", "\\"):lower()
		local body = winner[key] and slurp(winner[key])
		           or slurp(UNPACKED .. path:gsub("\\", "/"))
		           or slurp(ROOT .. "gamedata/configs/" .. path:gsub("\\", "/"))
		if not body then return "" end
		return expand((body:gsub("<%?xml.-%?>", "")), depth + 1)
	end))
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
local spots_in = expand(slurp(SRC.spots))
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

print("\n-- the S.T.A.L.K.E.R. 2 style switch ----------------------------------")

-- Everything above ran with no ui_mcm at all, i.e. the default style, which is what a
-- player who has never opened the menu gets. Now answer 1 for iqm/general/map_icon_style
-- and run the SAME real files through the SAME callback again.
--
-- The one thing worth proving here is that the restyle is a PASS OVER THE DOM rather than
-- a second table of selectors: nothing below names a spot type that the s2 code knows
-- about, because it does not know about any. It keys on the id prefix, so these
-- assertions are about the ids that came out, not about a list somebody kept in sync.
ENV.ui_mcm = { get = function(path)
	if path == "iqm/general/map_icon_style" then return 1 end
	if path == "iqm/general/map_icons" then return true end
	return nil
end }

local s2_spots  = ENV.COnXmlRead([[ui\map_spots_16.xml]], spots_in)
local s2_legend = ENV.COnXmlRead([[ui\pda_tasks_16.xml]], al_in)

for label, out in pairs({ ["the spot file"] = s2_spots, ["the legend"] = s2_legend }) do
	local all, s2 = count(out, "iqm_mapspot_"), count(out, "iqm_mapspot_s2_")
	check(label .. ": every id this mod owns is the s2 one", all > 0 and all == s2,
		string.format("%d ids, %d of them s2", all, s2))
	-- The callback fires once per spot FILE and the aspect variants share includes, so a
	-- second rename of an already-renamed id is a real possibility rather than a
	-- hypothetical. It would produce a texture id nothing declares, i.e. a blank marker.
	check(label .. ": no id was renamed twice", count(out, "iqm_mapspot_s2_s2_") == 0)
end

-- WHITE ON EVERYTHING, because that is the half of the S2 look the frame does not carry.
local s2_medic = s2_spots:match("<ui_pda2_medic_location_spot[ >].-</ui_pda2_medic_location_spot>")
check("a service spot takes the s2 cell", s2_medic
	and s2_medic:find("iqm_mapspot_s2_medic", 1, true) ~= nil, s2_medic)
check("...and is tinted white, not its role colour", s2_medic
	and s2_medic:find('r="255"', 1, true) and s2_medic:find('g="255"', 1, true)
	and s2_medic:find('b="255"', 1, true) and not s2_medic:find('r="238"', 1, true),
	s2_medic and s2_medic:gsub("%s+", " "):sub(1, 160))

-- ...EXCEPT the squad disks. Fourteen warfare spots carry faction, relation and
-- moving/static in their own r/g/b over one white disk, so white would delete the
-- information rather than restyle it. The id still changes -- same art in both atlases.
local s2_duty = s2_spots:match("<warfare_duty_tex[ >].-</warfare_duty_tex>")
check("a squad disk takes the s2 cell too", s2_duty
	and s2_duty:find("iqm_mapspot_s2_squad", 1, true) ~= nil, s2_duty)
check("...but KEEPS its faction colour", s2_duty and s2_duty:find('r="192"', 1, true) ~= nil,
	s2_duty and s2_duty:gsub("%s+", " "):sub(1, 160))

-- The legend follows the map, or it is a key to marks that are not on it.
local s2_trader_row = row_with(s2_legend, CAPTION["ui_AlphaLion_Trader-large"]) or ""
check("the legend row takes the s2 cell",
	s2_trader_row:find("iqm_mapspot_s2_trader", 1, true) ~= nil,
	s2_trader_row:gsub("%s+", " "):sub(1, 160))
check("...and the row's tint is white as well",
	s2_trader_row:find('r="255"', 1, true) ~= nil and not s2_trader_row:find('g="198"', 1, true),
	s2_trader_row:gsub("%s+", " "):sub(1, 160))

-- ...AND THE MAIN-TASK ROW KEEPS ITS GOLD, which is the reason the storyline decision is
-- keyed on the tint rather than on a list of spot names. A legend row is an <image> in a
-- different FILE - it has no spot name to match on at all - so a spot-keyed rule would
-- have kept the gold on the map and dropped it in the key to the map.
local s2_main_row = row_with(s2_legend, CAPTION["ui_AlphaLion_PrimaryMission"]) or ""
check("the legend's main-task row keeps the storyline gold",
	s2_main_row:find("iqm_mapspot_s2_task", 1, true) ~= nil
	and s2_main_row:find('r="246"', 1, true) ~= nil,
	s2_main_row:gsub("%s+", " "):sub(1, 160))
local s2_add_row = row_with(s2_legend, CAPTION["ui_AlphaLion_SecondaryMission"]) or ""
check("...and the additional-task row, the same cell, does not",
	s2_add_row:find("iqm_mapspot_s2_task", 1, true) ~= nil
	and s2_add_row:find('r="246"', 1, true) == nil,
	s2_add_row:gsub("%s+", " "):sub(1, 160))

-- THE LEVEL CHANGER KEEPS ITS GREEN. It is the one mark held out of the whitening for a
-- reason that is not "the colour is the information": its SHAPE does not change between
-- the styles (the eight-heading arch never became a diamond), so whitening it would have
-- made a fixture harder to find without making it look any more like S2.
local s2_arch = s2_spots:match("<level_changer_up_spot[ >].-</level_changer_up_spot>")
check("the level changer takes the s2 cell", s2_arch
	and s2_arch:find("iqm_mapspot_s2_transition", 1, true) ~= nil, s2_arch)
check("...and KEEPS the transition green", s2_arch
	and s2_arch:find('r="102"', 1, true) ~= nil
	and s2_arch:find('g="173"', 1, true) ~= nil, s2_arch)

-- THE THREE TASK-KIND TINTS KEEP THEIR COLOUR TOO, by request after a play-test: the
-- hand-in green, the bounty red and the mutant olive answer a question the player asks
-- before reading the glyph (is anything finished, is anything hostile), which is the one
-- job a 26 px pin's colour does better than its drawing. Everything else went white.
local function block(out, tag)
	return out:match("<" .. tag .. "[ >].-</" .. tag .. ">")
end
local s2_handin = block(s2_spots, "iqm_task_handin_spot")
check("a hand-in keeps the green and takes the s2 cell", s2_handin
	and s2_handin:find("iqm_mapspot_s2_handin", 1, true) ~= nil
	and s2_handin:find('r="40"', 1, true) ~= nil
	and s2_handin:find('g="172"', 1, true) ~= nil, s2_handin)
local s2_mutant = block(s2_spots, "iqm_task_mutant_spot")
check("a mutant hunt keeps the olive", s2_mutant
	and s2_mutant:find('r="176"', 1, true) ~= nil
	and s2_mutant:find('g="216"', 1, true) ~= nil, s2_mutant)
local s2_delivery = block(s2_spots, "iqm_task_delivery_spot")
check("a delivery keeps the hand-in's green, which it shares on purpose", s2_delivery
	and s2_delivery:find('r="40"', 1, true) ~= nil, s2_delivery)
local s2_bounty_kind = block(s2_spots, "iqm_task_bounty_spot")
check("a bounty keeps the red", s2_bounty_kind
	and s2_bounty_kind:find('r="172"', 1, true) ~= nil
	and s2_bounty_kind:find('g="60"', 1, true) ~= nil, s2_bounty_kind)

-- ...AND SO DOES ITS SELECTION FRAME, which is the reverse of what shipped first. A white
-- diamond is the largest and brightest shape in the mark, so it read as a white marker with
-- something red inside it and the KIND lost to the STATE. Selection is carried by the
-- frame's presence and its blink; it does not need the colour channel as well.
--
-- The border's own id says nothing about this - iqm_mapspot_select is one cell under every
-- kind of pin - so the pass has to walk from the border up to the spot. That is the part
-- worth asserting: get the parent chain wrong and the frame silently falls back to white,
-- which is exactly what it used to be and so looks like nothing broke.
local s2_bk_border = s2_bounty_kind and s2_bounty_kind:match("<static_border[ >].-</static_border>")
check("...and its selection frame takes the same red", s2_bk_border
	and s2_bk_border:find("iqm_mapspot_s2_select", 1, true) ~= nil
	and s2_bk_border:find('r="172"', 1, true) ~= nil
	and s2_bk_border:find('g="60"', 1, true) ~= nil
	and s2_bk_border:find('r="255"', 1, true) == nil, s2_bk_border)
local s2_handin_border = s2_handin and s2_handin:match("<static_border[ >].-</static_border>")
check("...a hand-in's frame takes the green", s2_handin_border == nil
	or (s2_handin_border:find('r="40"', 1, true) ~= nil
	    and s2_handin_border:find('g="172"', 1, true) ~= nil), s2_handin_border)

-- STORYLINE GOLD SURVIVES THE WHITENING, and it cannot be kept by id: a storyline task and
-- a secondary task are the SAME cell (iqm_mapspot_task) and differ only in r/g/b, so the
-- pass keys that decision on the tint itself (S2_KEEP_RGB). Both halves are asserted here
-- because keeping both, or whitening both, are the two ways to get it wrong.
local s2_story = block(s2_spots, "storyline_task_spot")
check("a storyline task keeps its gold", s2_story
	and s2_story:find("iqm_mapspot_s2_task", 1, true) ~= nil
	and s2_story:find('r="246"', 1, true) ~= nil
	and s2_story:find('g="204"', 1, true) ~= nil, s2_story)
local s2_story_border = s2_story and s2_story:match("<static_border[ >].-</static_border>")
check("...and so does its selection frame", s2_story_border
	and s2_story_border:find('r="246"', 1, true) ~= nil, s2_story_border)
local s2_secondary = block(s2_spots, "secondary_task_spot")
check("...while a secondary task, the same cell, still goes white", s2_secondary
	and s2_secondary:find("iqm_mapspot_s2_task", 1, true) ~= nil
	and s2_secondary:find('r="255"', 1, true) ~= nil
	and s2_secondary:find('r="246"', 1, true) == nil, s2_secondary)
local s2_story_mini = block(s2_spots, "storyline_task_spot_mini")
local story_arrow = s2_story_mini and s2_story_mini:match("<texture_above.-</texture_above>")
check("...and the minimap pin's off-level arrow keeps it too", story_arrow
	and story_arrow:find('r="246"', 1, true) ~= nil, story_arrow)

-- THE OFF-LEVEL ARROWS CANNOT BE DECIDED BY THEIR OWN ID, and this is the pair of checks
-- that proves the pass does it by SPOT instead. iqm_mapspot_above is ONE cell shared by a
-- gold storyline task, a white secondary, a red alert and the coloured task kinds, so the
-- same id has to come out coloured under one parent and white under another.
local s2_mutant_mini = block(s2_spots, "iqm_task_mutant_spot_mini")
local mutant_arrow = s2_mutant_mini and s2_mutant_mini:match("<texture_above.-</texture_above>")
check("an off-level arrow inherits its spot's colour", mutant_arrow
	and mutant_arrow:find('r="176"', 1, true) ~= nil, mutant_arrow)
local s2_secondary_mini = block(s2_spots, "secondary_task_spot_mini")
local secondary_arrow = s2_secondary_mini and s2_secondary_mini:match("<texture_above.-</texture_above>")
check("...and the SAME cell under a whitened spot stays white", secondary_arrow
	and secondary_arrow:find('r="255"', 1, true) ~= nil
	and secondary_arrow:find('r="240"', 1, true) == nil, secondary_arrow)

-- The bare pair, same question: a hand-in that goes up a floor is still a finished job.
local s2_handin_mini = block(s2_spots, "iqm_task_handin_spot_mini")
local handin_arrow = s2_handin_mini and s2_handin_mini:match("<texture_above.-</texture_above>")
check("the BARE arrow inherits it as well", handin_arrow
	and handin_arrow:find("iqm_mapspot_s2_abovebare", 1, true) ~= nil
	and handin_arrow:find('r="40"', 1, true) ~= nil, handin_arrow)

-- THE SPOT RECTS GROW. A diamond of the same extent as a ring badge reads smaller - it
-- encloses 2/pi of the area, and only its four points reach further than the ring - and
-- the art has no room to answer it, the points being already at the cell edge. So the
-- correction is on the spot: S2_SPOT_SCALE 1.19, i.e. 19 -> 23 and 14 -> 17 units.
local function attr(block, key)
	return block and tonumber(block:match(key .. '="(%-?%d+)"'))
end
local s2_medic_mini = s2_spots:match(
	"<ui_pda2_medic_location_mini_spot[ >].-</ui_pda2_medic_location_mini_spot>")
check("the map spot grew from 19 to 23 units",
	attr(s2_medic, "width") == 23 and attr(s2_medic, "height") == 23,
	s2_medic and s2_medic:gsub("%s+", " "):sub(1, 120))
check("the minimap spot grew from 14 to 17 units",
	attr(s2_medic_mini, "width") == 17 and attr(s2_medic_mini, "height") == 17,
	s2_medic_mini and s2_medic_mini:gsub("%s+", " "):sub(1, 120))

-- Grown ONCE. A task spot carries texture, texture_above and texture_below, and the pass
-- walks all three tags - so an ungated scale would compound to 1.19^3 and hand that one
-- spot a 68% marker while its neighbours got 21%.
local s2_bounty = s2_spots:match("<iqm_task_bounty_spot[ >].-</iqm_task_bounty_spot>")
check("a spot with off-level swaps is grown exactly once",
	attr(s2_bounty, "width") == 23, s2_bounty and s2_bounty:gsub("%s+", " "):sub(1, 200))

-- THE SELECT BORDER FOLLOWS THE ICON. This is the bug that showed up on screen first: the
-- frame is a top-left child of a centre-aligned spot, so centring it means
-- x = -(border - icon)/2 - which is what the -5 in the SPOTS entries IS, for a 29-unit
-- border on a 19-unit spot. Grow the icon and leave -5 alone and the frame sits a unit up
-- and left of the marker it is supposed to be around.
--
-- Asserted as the RELATION rather than as numbers, so it holds if either scale is retuned.
local s2_border = s2_bounty and s2_bounty:match("<static_border[ >].-</static_border>")
local function centred(icon, border)
	local iw, ih = attr(icon, "width"), attr(icon, "height")
	local bw, bh = attr(border, "width"), attr(border, "height")
	if not (iw and ih and bw and bh) then return false, "missing geometry" end
	local x, y = attr(border, "x"), attr(border, "y")
	return x == -(bw - iw) / 2 and y == -(bh - ih) / 2,
		string.format("icon %dx%d, border %dx%d at %s,%s -- centred would be %g,%g",
			iw, ih, bw, bh, tostring(x), tostring(y), -(bw - iw) / 2, -(bh - ih) / 2)
end
do
	local ok, why = centred(s2_bounty, s2_border)
	check("the select border is centred on the grown icon", ok, why)
end
-- ...and it keeps air around the icon rather than closing onto it: the (border - icon)/2
-- gap scales with the icon, so the frame is still outside the diamond's points.
check("the select border kept air around the icon",
	attr(s2_border, "width") > attr(s2_bounty, "width"),
	s2_border and s2_border:gsub("%s+", " "):sub(1, 160))

-- THE TWO HOLLOW TYPES WERE ASSERTED HERE until R2.62 removed them: iqm_task_open and
-- iqm_task_waypoint, the pin that ringed a mark the map already drew. Their whole reason
-- for existing was a rule that is gone, so the size and clearance arithmetic that used to
-- live here has nothing left to measure. What replaced it is one line in the s2 pass -
-- every restyled spot now takes S2_SPOT_SCALE and nothing else - which the medic and
-- bounty checks above already cover.

-- The LEVEL CHANGER's rect, for the same reason its colour survives: its art is the same
-- arch in both styles, so it keeps the 19x19 this mod's own SPOTS entry gives it. Worth
-- asserting the exact number rather than "unchanged" - 19x19 is already a patched value
-- (vanilla is 19x21, and the entry squares it so the rotated quad does not shear the
-- arch), so a scale slipping through here would read as a plausible size rather than as
-- a bug.
check("the level changer's rect is left at the mod's own 19x19",
	attr(s2_arch, "width") == 19 and attr(s2_arch, "height") == 19,
	s2_arch and s2_arch:gsub("%s+", " "):sub(1, 160))

-- And the legend keeps its geometry: those swatches are rows in a list, and a 21% taller
-- one would push the panel's rows apart. Same pass, geometry off.
check("the legend swatch stays 19x19",
	(s2_trader_row:match('<image[ >].-/?>') or ""):find('width="19"', 1, true) ~= nil,
	s2_trader_row:gsub("%s+", " "):sub(1, 200))

-- And the switch switches: 0 puts the ring badges back on the same input, which is what
-- proves the s2 pass is reading the option rather than the atlas having been renamed
-- somewhere upstream.
ENV.ui_mcm = { get = function(path)
	if path == "iqm/general/map_icon_style" then return 0 end
	return nil
end }
local back = ENV.COnXmlRead([[ui\map_spots_16.xml]], spots_in)
check("style 0 draws the ring badges again", count(back, "iqm_mapspot_s2_") == 0
	and back:find("iqm_mapspot_medic", 1, true) ~= nil)
ENV.ui_mcm = nil

print("\n-- the task marker size slider ----------------------------------------")

-- The slider is a percentage of WHAT IS ON SCREEN, which is the whole reason it is
-- asserted at both styles rather than once: 67% of the ring badge's 19 units is 13, and
-- 67% of the S2 diamond's 23 is 15. Run the size pass before the S2 grow instead of after
-- it and both come out 13 -- a plausible number, the wrong one, and one nobody would
-- catch by looking at a minimap.
local function sized(style, pct, badge, exit)
	ENV.ui_mcm = { get = function(path)
		if path == "iqm/general/map_icon_style" then return style end
		if path == "iqm/general/map_task_size"  then return pct end
		if path == "iqm/general/map_badge_size" then return badge end
		if path == "iqm/general/map_exit_size"  then return exit end
		if path == "iqm/general/map_icons"      then return true end
		return nil
	end }
	local out = ENV.COnXmlRead([[ui\map_spots_16.xml]], spots_in)
	ENV.ui_mcm = nil
	return out
end

local small = sized(0, 67)
check("a task spot takes 67% of the ring badge's 19 units",
	attr(block(small, "storyline_task_spot"), "width") == 13,
	(block(small, "storyline_task_spot") or ""):gsub("%s+", " "):sub(1, 140))
check("...on the minimap as well as the map",
	attr(block(small, "storyline_task_spot_mini"), "width") == 13)
check("...and the other tier with it",
	attr(block(small, "secondary_task_spot"), "width") == 13)

-- The same pin under the other style. This is the ordering assertion.
local small_s2 = sized(1, 67)
check("...and 67% of the S2 diamond's 23 units is 15, not 13",
	attr(block(small_s2, "storyline_task_spot"), "width") == 15,
	(block(small_s2, "storyline_task_spot") or ""):gsub("%s+", " "):sub(1, 140))

-- THE SELECTION FRAME SHRINKS WITH THE PIN, which is the one place this pass deliberately
-- differs from the S2 grow above. That one holds the frame's air constant because the
-- mark changed SHAPE inside a frame tuned for the old one; this is the same picture at
-- another size, and a 13-unit mark left inside a 29-unit ring is not that picture -- the
-- frame stops reading as the mark's own and starts reading as a second mark around it.
local small_border = (block(small, "storyline_task_spot") or ""):match("<static_border[ >].-</static_border>")
check("the selection frame shrank too", attr(small_border, "width") == 19,
	small_border and small_border:gsub("%s+", " "):sub(1, 140))
do
	local ok, why = centred(block(small, "storyline_task_spot"), small_border)
	check("...and is still centred on the smaller icon", ok, why)
end
check("...with air left between the two", attr(small_border, "width") > 13)

-- AND UNDER THE S2 STYLE, where the icon is 23 before this pass and its frame 33. This is
-- the pair that forced the arithmetic: scaling the two rects independently gives 15 inside
-- 22, an odd difference, and no integer offset centres that. scale_spot scales the AIR
-- instead, so the border is icon + 2*air and the offset is exactly -air at any percentage.
do
	local s2b = (block(small_s2, "storyline_task_spot") or ""):match("<static_border[ >].-</static_border>")
	check("the S2 frame comes out an even difference from its icon",
		attr(s2b, "width") == 21, s2b and s2b:gsub("%s+", " "):sub(1, 140))
	local ok, why = centred(block(small_s2, "storyline_task_spot"), s2b)
	check("...so it is exactly centred, not a rounding away from it", ok, why)
end

-- THE REST OF THE TASK FAMILY. Each of these is here because it is a different SHAPE of
-- entry in TASK_SIZED, not for coverage's sake: a spot with no static_border, a pin that
-- is a halo rather than a mark, and one of the four types this mod declares itself and
-- splices into the DOM a few lines before the pass runs.
check("the turn-in pin scales (21 -> 14), and it has no frame to carry",
	attr(block(small, "storyline_task_on_guider_spot"), "width") == 14,
	(block(small, "storyline_task_on_guider_spot") or ""):gsub("%s+", " "):sub(1, 140))
check("the new-task pulse scales with the mark it rings (39 -> 26)",
	attr(block(small, "ui_storyline_task_blink_spot"), "width") == 26,
	(block(small, "ui_storyline_task_blink_spot") or ""):gsub("%s+", " "):sub(1, 140))
check("...and keeps the 0,0 its SPOTS entry gave it",
	attr(block(small, "ui_storyline_task_blink_spot"), "x") == 0)
check("this mod's own bounty type scales too",
	attr(block(small, "iqm_task_bounty_spot"), "width") == 13,
	(block(small, "iqm_task_bounty_spot") or ""):gsub("%s+", " "):sub(1, 140))
check("...including its minimap twin",
	attr(block(small, "iqm_task_bounty_spot_mini"), "width") == 13)

-- THE ONE TASK_SIZED ID THAT LIVES IN AN #include rather than in the top-level file
-- (map_spots_complex.xml). It is asserted separately because a fixture that quietly
-- stopped expanding includes would pass every other check in this section: the timer pin
-- would simply not be in the document, and a typo in its id would look exactly like a
-- pass. slaxml resolves the include itself through the r_open above, so this also guards
-- the VFS manifest lookup that picks WHICH copy of the included file gets read.
check("the timed-task pin is in the document at all, includes and all",
	block(small, "secondary_task_complex_spot_mini_timer") ~= nil)
check("...and takes 67% of the 19 units its SPOTS entry gave it",
	attr(block(small, "secondary_task_complex_spot_mini_timer"), "width") == 13,
	(block(small, "secondary_task_complex_spot_mini_timer") or "<absent>"):gsub("%s+", " "):sub(1, 140))

-- WHAT THE TASK SLIDER MUST NOT MOVE. Two of these three now have sliders of their own
-- (R2.66), so for the badge and the level changer this is an INDEPENDENCE assertion: the
-- three families are disjoint id lists, and one slider may never drag another's marks
-- along with it. For the squad dot it remains what it always was, a promise rather than a
-- behaviour -- no slider reaches it, because its size is not this mod's to pick (see the
-- squad note in SPOTS).
check("a service badge is left at 19", attr(block(small, "ui_pda2_medic_location_spot"), "width") == 19,
	(block(small, "ui_pda2_medic_location_spot") or ""):gsub("%s+", " "):sub(1, 140))
check("the level changer is left at 19", attr(block(small, "level_changer_up_spot"), "width") == 19)
check("a squad dot is left at 13", attr(block(small, "warfare_duty_tex"), "width") == 13,
	(block(small, "warfare_duty_tex") or ""):gsub("%s+", " "):sub(1, 140))

-- 100 IS A NO-OP, byte for byte, and not merely "close". The pass returns before it
-- queries anything at k == 1, so this also proves the default costs nothing on a load.
check("100% changes nothing at all", sized(0, 100) == sized(0, nil))
check("...and the same holds for the two sliders added after it",
	sized(0, nil, 100, 100) == sized(0, nil))

-- THE CLAMP. The value comes out of a settings file a player can edit by hand, and a
-- stale key can outlive a rename. 0 would be a marker with no rect, which the engine
-- draws as nothing and which looks exactly like this mod having broken.
check("0 is clamped to the registry's floor of 50, not taken literally",
	attr(block(sized(0, 0), "storyline_task_spot"), "width") == 10,
	(block(sized(0, 0), "storyline_task_spot") or ""):gsub("%s+", " "):sub(1, 140))
check("...and an absurd high value to 150",
	attr(block(sized(0, 9000), "storyline_task_spot"), "width") == 29)

print("")
print("-- the service badge and level transition sliders ----------------------")

-- SAME PASS, TWO MORE LISTS (R2.66). These cover the two things a second and third family
-- can get wrong that the first could not: that each slider moves its OWN marks, and that
-- it moves NOBODY ELSE'S. The arithmetic itself is already covered above -- one scale_spot
-- serves all three families, so there is nothing new to assert about the rects.
local badges = sized(0, nil, 67, nil)
check("a service badge takes 67% of its 19 units",
	attr(block(badges, "ui_pda2_medic_location_spot"), "width") == 13,
	(block(badges, "ui_pda2_medic_location_spot") or ""):gsub("%s+", " "):sub(1, 140))
check("...and its minimap twin 67% of 14, which is 9 and not 13",
	attr(block(badges, "ui_pda2_medic_location_mini_spot"), "width") == 9,
	(block(badges, "ui_pda2_medic_location_mini_spot") or ""):gsub("%s+", " "):sub(1, 140))
check("...across the whole family, not just the id under test",
	attr(block(badges, "ui_pda2_quest_npc_location_spot"), "width") == 13)
check("...while the task pins stay where they were",
	attr(block(badges, "storyline_task_spot"), "width") == 19)
check("...and the level changer with them",
	attr(block(badges, "level_changer_up_spot"), "width") == 19)

-- The level changer arrives at 19x21 in the shipped file and is squared to 19x19 by its
-- own SPOTS entry, so 67% of it is 13 on BOTH axes. That squaring happens upstream of this
-- pass, which is what the ordering note at the call site is about.
local exits = sized(0, nil, nil, 67)
check("the level changer takes 67% of the 19 units SPOTS squared it to",
	attr(block(exits, "level_changer_up_spot"), "width") == 13,
	(block(exits, "level_changer_up_spot") or ""):gsub("%s+", " "):sub(1, 140))
check("...on both axes, because it was square before the scale",
	attr(block(exits, "level_changer_up_spot"), "height") == 13)
check("...and the minimap mark with it",
	attr(block(exits, "level_changer_spot_mini"), "width") == 13)
check("...while the badges stay where they were",
	attr(block(exits, "ui_pda2_medic_location_spot"), "width") == 19)

-- All three at once, which is the combination a player actually runs.
local all3 = sized(0, 67, 67, 67)
check("three sliders at 67 move three families and collide nowhere",
	attr(block(all3, "storyline_task_spot"), "width") == 13
	and attr(block(all3, "ui_pda2_medic_location_spot"), "width") == 13
	and attr(block(all3, "level_changer_up_spot"), "width") == 13)
check("...and the squad dot is still 13, which no slider reaches",
	attr(block(all3, "warfare_duty_tex"), "width") == 13,
	(block(all3, "warfare_duty_tex") or ""):gsub("%s+", " "):sub(1, 140))

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
