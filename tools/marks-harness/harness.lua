-- Harness: RUN the ground-mark geometry outside the game.
--
-- WHY THIS EXISTS. iqm_core compiles clean and still cannot load: R2.32 shipped a
-- shape_box() that called `sqrt` from above the file's `local sqrt = math.sqrt`, so it
-- compiled as a global lookup, resolved to nil, and took the game down at on_game_start
-- with the cards, the beacon and the route. check_lua caught nothing -- there was nothing
-- to catch, the syntax was fine -- and the four existing harnesses never load this
-- module's render path, so nothing anywhere CALLED the function. This one does.
--
-- What it checks:
--
--   1. IT RUNS. shape_box(i) for every shape, and the returned box is three finite
--      positive numbers. That alone is the whole of the R2.32a crash.
--   2. THE GEOMETRY. Each box recomputed here from the same formulas, so a typo in one
--      of the four branches shows up as a mismatch rather than as a glyph sitting
--      slightly off its rect in game.
--   3. THE THREE-WAY MIRROR. RTE.SHAPES, MARK_SHAPES in tools/stroke-tex/build.py and
--      the texture ids in configs/ui/textures_descr/iqm_textures.xml all describe the
--      same set of shapes. build.py checks itself against the mod when it runs; this
--      checks all three whether or not anyone rebuilds the atlas.
--   4. The default index is in range.
--
-- Usage:
--   python check_lua.py --run tools/marks-harness/harness.lua
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
	if not f then error("cannot open " .. ROOT .. rel ..
		" -- run from the mod root") end
	local s = f:read("*a")
	f:close()
	return s
end

-- ---------------------------------------------------------------- engine env
-- The thinnest stubs that let iqm_core' body run to the end. It allocates scratch
-- vectors and binds a few engine globals as it parses; none of that is exercised here.
local ENV = {}
ENV.pairs, ENV.ipairs, ENV.tostring, ENV.tonumber = pairs, ipairs, tostring, tonumber
ENV.type, ENV.string, ENV.table, ENV.math, ENV.os = type, string, table, math, os
ENV.setmetatable, ENV.print, ENV.pcall, ENV.select = setmetatable, print, pcall, select
ENV.error, ENV.assert, ENV.unpack = error, assert, unpack
ENV._G = ENV
ENV.printf = function() end

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

-- THE MODULE THAT IS RUN is iqm_cards: RTE, shape_box and the whole ground-mark
-- render path moved there at R2.45 when iqm_core was split, and shape_box being
-- CALLED rather than read is the entire point of this file (see the header). The
-- options it is measured against -- appear_dist, full_dist, route_shape, the
-- card/marker crossover -- stayed with the config in iqm_core, so the SOURCE TEXT
-- below is both files read as one string. Anything grepped here that ended up in
-- neither would return nil rather than fail, so both halves have to be in scope.
local markers_src = slurp("gamedata/scripts/iqm_core.script")
                 .. slurp("gamedata/scripts/iqm_cards.script")
local cards_src = slurp("gamedata/scripts/iqm_cards.script")
local MK = setmetatable({}, { __index = ENV })
do
	local chunk, err = loadstring(cards_src, "@iqm_cards.script")
	assert(chunk, err)
	setfenv(chunk, MK)
	local ok, perr = pcall(chunk)
	assert(ok, "iqm_cards failed to parse: " .. tostring(perr))
end

-- --------------------------------------------------------- what the mod declares
-- RTE is a file local, so the SHAPES table is read out of the source text rather than
-- off the module. That is not a workaround: it means the harness is checking what the
-- file says, which is what a reviewer reads, rather than a value the file could have
-- computed from something else.
-- The TAIL of each row is captured whole and its fields picked out afterwards, rather
-- than matched field by field. Lua patterns have no optional group, and R2.40 added two
-- optional ones (awide, aw) -- so a fixed three-field pattern SILENTLY SKIPS any row that
-- carries them. It did, on the run that added shape 7: the mod had seven shapes, this
-- found six, and the literal count below passed because six was what it used to expect.
-- A parser that drops what it does not recognise fails in the direction of saying nothing
-- is wrong, which is the worst direction available to a mirror check.
-- The row's KEY is captured too, and it is not the row's position. R2.43 cut five shapes
-- off the menu and left the survivors on their original numbers -- 3, 7, 8 -- because
-- those numbers are already in players' ltx files and renumbering them would silently
-- turn a saved arrow into a chevron. So RTE.SHAPES is a table with holes, `shapes[i].key`
-- is what shape_box takes, and anything here that used `i` as the index would be testing
-- the fallback shape three times over.
local shapes = {}
for key, tex, kind, tail in markers_src:gmatch(
	'%[(%d+)%]%s*=%s*{%s*tex%s*=%s*"iqm_mark_(%w+)"%s*,%s*kind%s*=%s*"(%w+)"%s*,%s*(.-)%s*}') do
	shapes[#shapes + 1] = {
		key = tonumber(key), tex = tex, kind = kind,
		alen  = tonumber(tail:match("alen%s*=%s*([%d%.]+)")),
		awide = tonumber(tail:match("awide%s*=%s*([%d%.]+)")),
		aw    = tonumber(tail:match("[^%w]aw%s*=%s*([%d%.]+)")),
	}
end
check("RTE.SHAPES parses", #shapes > 0, "found none")
check("...and every row yielded an alen", (function()
	for _, s in ipairs(shapes) do if not s.alen then return false end end
	return true
end)(), "a row parsed without one")
-- A literal count, deliberately. The three-way mirror below proves the sources AGREE
-- with each other, which a shape deleted from all of them would still satisfy.
check("...and holds three shapes", #shapes == 3, tostring(#shapes))
-- The keys are the contract with every ltx already written. Spelled out rather than
-- derived: this is the one thing in the file that must not be tidied up later.
check("...on numbers 3, 7 and 8, which must not be renumbered",
	shapes[1] and shapes[1].key == 3 and shapes[2] and shapes[2].key == 7
	and shapes[3] and shapes[3].key == 8,
	table.concat({ tostring(shapes[1] and shapes[1].key),
		tostring(shapes[2] and shapes[2].key),
		tostring(shapes[3] and shapes[3].key) }, "/"))

local function num(src, key)
	local v = src:match("\n%s*" .. key .. "%s*=%s*([%d%.]+)")
	return tonumber(v)
end
-- One OPTIONS record's raw text, by key. R2.46 collapsed DEFAULTS, PAGE_OF and the MCM
-- widget list into a single registry in iqm_core, so an option's default AND its
-- slider range are fields of one row -- which is why the range checks below no longer
-- read iqm_mcm. Stops at a line starting with `{`, `-` or a blank one: registry rows sit
-- at column 0 and are separated by exactly those.
local function opt_row(key)
	return markers_src:match('\n({ key = "' .. key .. '",.-)\n[%-{\n]')
end
-- A named field off that row, as a number. Returns nil for a row or field that is not
-- there, which every caller checks -- a silent nil here would make the arithmetic below
-- vacuous rather than wrong.
local function optnum(key, field)
	local rec = opt_row(key)
	return rec and tonumber(rec:match(field .. " = (%-?[%d%.]+)"))
end
local AWIDE = num(markers_src, "awide")
local AW    = num(markers_src, "aw")
local FPAD  = num(markers_src, "FPAD")
local SPAD  = num(markers_src, "SPAD")
check("RTE.awide / aw / FPAD all read", AWIDE and AW and FPAD,
	tostring(AWIDE) .. "/" .. tostring(AW) .. "/" .. tostring(FPAD))
check("...and RTE.SPAD, the baked shadow's reach", SPAD ~= nil, tostring(SPAD))

-- ------------------------------------------------------------ 1 + 2. it runs
check("shape_box is reachable from outside the module", type(MK.shape_box) == "function",
	"a file local cannot be tested, which is how R2.32a shipped")

local function expect_box(s)
	-- A row may carry its own width and stroke weight (R2.40, shape 7). The PAD scales
	-- with the arm on both sides of this mirror, so a shape with a thinner arm gets a
	-- proportionally smaller margin -- get that wrong here and the harness would demand a
	-- box the mod is right not to produce.
	local aw = s.aw or AW
	local hl, hw, ha = s.alen * 0.5, (s.awide or AWIDE) * 0.5, aw * 0.5
	local pad = (FPAD + (SPAD or 0)) * aw
	if s.kind == "chevron" then
		local L = math.sqrt(4 * hl * hl + hw * hw)
		return hl + ha * hw / L + pad, hl + ha * L / hw + pad, hw + ha * 2 * hl / L + pad
	elseif s.kind == "arrow" or s.kind == "dart" then
		-- The dart is the arrow with its point cut off: same box, same depth. Listed
		-- explicitly rather than left to the fall-through below -- an unknown kind
		-- silently getting the SQUARE's box is how this test would pass a shape whose
		-- artwork was drawn into a different rectangle than the renderer measures, which
		-- is exactly the failure the three-way mirror exists to prevent.
		return hl + pad, hl + pad, hw + pad
	elseif s.kind == "rung" then
		return ha + pad, ha + pad, hw + pad
	end
	return hl + pad, hl + pad, hl + pad          -- square (and nothing else: see above)
end

local function close(a, b) return a and b and math.abs(a - b) < 1e-6 end

for _, s in ipairs(shapes) do
	local ok, back, fwd, half = pcall(MK.shape_box, s.key)
	check("shape " .. s.key .. " (" .. s.tex .. ") computes without erroring", ok,
		not ok and tostring(back) or nil)
	if ok then
		local finite = function(v)
			return type(v) == "number" and v == v and v > 0 and v < math.huge
		end
		check("...returns three positive finite extents",
			finite(back) and finite(fwd) and finite(half),
			tostring(back) .. "/" .. tostring(fwd) .. "/" .. tostring(half))
		local eb, ef, eh = expect_box(s)
		check("...and they are the " .. s.kind .. " box",
			close(back, eb) and close(fwd, ef) and close(half, eh),
			string.format("got %.4f/%.4f/%.4f want %.4f/%.4f/%.4f",
				back or -1, fwd or -1, half or -1, eb, ef, eh))
	end
end

-- The chevron alone has a mitre, so it alone is asymmetric along travel. If that ever
-- stops being true the artwork and the renderer have disagreed about where the mark's
-- centre is, which reads as the glyph sitting forward or back inside its own footprint.
for _, s in ipairs(shapes) do
	local _, back, fwd = pcall(MK.shape_box, s.key)
	if s.kind == "chevron" then
		check("shape " .. s.key .. " is asymmetric, as a mitre requires", fwd > back)
	else
		check("shape " .. s.key .. " is symmetric along travel", close(back, fwd))
	end
end

-- An unresolvable number must fall back rather than index nil. Two ways to get one and
-- both of them ship: MCM can hand us a stale value from a NEWER list after a downgrade,
-- and since R2.43 it can hand us a RETIRED one -- 1, 2, 4, 5 or 6 -- out of any ltx
-- written before the menu was cut. The retired numbers are the interesting case, because
-- they sit inside the old range and a bounds test would have waved them through.
local ok_hi = pcall(MK.shape_box, 99)
local ok_lo = pcall(MK.shape_box, 0)
check("an out-of-range shape index falls back instead of erroring", ok_hi and ok_lo)
do
	local bad = {}
	for _, n in ipairs({ 1, 2, 4, 5, 6 }) do
		local ok, back = pcall(MK.shape_box, n)
		if not (ok and type(back) == "number" and back > 0) then bad[#bad + 1] = n end
	end
	check("...and so does a shape number retired in R2.43", #bad == 0,
		"failed on " .. table.concat(bad, ", "))
end

-- ------------------------------------------- 2b. no mark parks inside the ramp
-- R2.33b: MNEAR's ramp exists for marks CROSSING the cut-off -- a bend that brings one
-- nearer than its arclength, the route ending, the spacing changing. Since R2.29 a mark
-- otherwise holds a fixed distance ahead of the player, so any mark whose parking spot
-- lands mid-ramp is dimmed for as long as the route is up. That is what shipped: 37 of
-- 255 on the nearest mark at the default spacing, against 255 on the next one.
--
-- So the property is not "the ramp is 0.6 m" -- that is today's arithmetic -- but that no
-- spacing the menu offers parks a mark inside it. Checked across the whole slider.
do
	local MNEAR = num(markers_src, "MNEAR")
	local MFADE = num(markers_src, "MFADE")
	check("RTE.MNEAR / MFADE read", MNEAR and MFADE,
		tostring(MNEAR) .. "/" .. tostring(MFADE))

	local nav_src = slurp("gamedata/scripts/iqm_nav.script")
	local LIFT = tonumber(nav_src:match("\nlocal ARROW_LIFT%s*=%s*([%d%.]+)"))
	-- The actor's eye above the mark. Not parsed from anywhere because the engine owns
	-- it; 1.6 m is the stock camera height and the number the preview tool assumes, and
	-- the test is insensitive to a few centimetres of it.
	local dy = 1.6 - (LIFT or 0.25)

	local gmin, gmax = optnum("route_gap", "min"), optnum("route_gap", "max")
	check("the route_gap slider's range is readable", gmin and gmax,
		tostring(gmin) .. ".." .. tostring(gmax))

	local worst, worst_gap
	if gmin and gmax and MNEAR and MFADE then
		for gap = gmin, gmax do
			-- The first mark that is drawn at all: k = 0 sits on the actor, and each k
			-- adds one gap of arclength, which on the straight the near end always is
			-- equals ground distance.
			for k = 1, 4 do
				local cd = math.sqrt((gap * k) ^ 2 + dy * dy)
				if cd >= MNEAR then
					local f = (cd < MNEAR + MFADE) and (cd - MNEAR) / MFADE or 1
					-- Fully faded in, or so near the cut-off it is invisible either way.
					-- Anything between is a mark permanently at partial alpha.
					if f > 0.03 and f < 0.97 and (not worst or f < worst) then
						worst, worst_gap = f, gap
					end
					break
				end
			end
		end
	end
	check("no route_gap parks a mark part-way up the near ramp",
		worst == nil,
		worst and string.format("gap %d holds its first mark at %.0f%% for ever",
			worst_gap, worst * 100) or nil)
end

-- ------------------------------------- 2c. no distance shows nothing at all
-- R2.33i. The card fades out with distance and the beacon covers the range past it, and
-- the two are mutually exclusive -- so the handover threshold decides whether there is a
-- band where the card is present but unreadable and the beacon has already stood down.
-- There was: it handed over at 9% card opacity, leaving ~14.0-15.3 m with an 18% card and
-- no beacon, on a target in plain sight.
--
-- It lives in this harness because this is the one that reads iqm_core' constants, and
-- the card render path has no harness of its own. The property is pure arithmetic off
-- alpha_for_dist, which is why it can be checked at all without one.
do
	local APPEAR = optnum("appear_dist", "def")
	local FULL   = optnum("full_dist", "def")
	-- The two sides of the crossover, read out of the branch that sets card_up.
	local up   = tonumber(markers_src:match("elseif target_a >= (%d+) then"))
	local down = tonumber(markers_src:match("elseif f%.a < (%d+) then"))
	check("the card fade and the crossover thresholds all parse",
		APPEAR and FULL and up and down,
		string.format("%s/%s %s/%s", tostring(APPEAR), tostring(FULL),
			tostring(up), tostring(down)))

	if APPEAR and FULL and up then
		-- Below this a card is present but cannot be read against bright ground, which is
		-- the same as not being there.
		local LEGIBLE = 96
		local worst_d, worst_a
		local d = FULL
		while d <= APPEAR do
			local a = ((APPEAR - d) / math.max(0.1, APPEAR - FULL)) * 255
			-- The beacon is suppressed at or above `up`; the card is unreadable below
			-- LEGIBLE. Any distance in both sets shows the player nothing.
			if a >= up and a < LEGIBLE and (not worst_a or a < worst_a) then
				worst_d, worst_a = d, a
			end
			d = d + 0.1
		end
		check("no distance leaves an unreadable card AND no beacon", worst_d == nil,
			worst_d and string.format(
				"at %.1f m the card is %.0f%% and the beacon is suppressed",
				worst_d, worst_a / 255 * 100) or nil)
		check("...and the beacon returns before the card is unreadable, with hysteresis",
			down and down < up and down >= 64,
			string.format("up %s, down %s", tostring(up), tostring(down)))
	end
end

-- ----------------------------------------------------- 3. the three-way mirror
local build_src = slurp("tools/stroke-tex/build.py")
-- Five fields since R2.40, the last two being `None` on every row that takes the family's
-- width and weight. Matched as [%w%.]+ -- letters for `None`, digits and a dot for a real
-- override -- so tonumber turns the word into nil, which is exactly what the mod's absent
-- field reads as, and the two sides compare equal without either special-casing the
-- other. (%w+ alone parses `None` and silently drops `0.90`, which cost a run.)
local bshapes = {}
for slug, kind, alen, wide, arm in build_src:gmatch(
	'%("(%w+)",%s*"(%w+)",%s*([%d%.]+),%s*([%w%.]+),%s*([%w%.]+)%)') do
	bshapes[#bshapes + 1] = { tex = slug, kind = kind, alen = tonumber(alen),
	                          awide = tonumber(wide), aw = tonumber(arm) }
end
-- MATCHED BY SLUG AND AS A SUBSET, not row for row, since R2.43. build.py still draws
-- the five retired shapes on purpose: MARK_SHAPES is the atlas's LAYOUT as well as its
-- content (cell k*MARK_VARIANTS + v), so deleting a row slides every cell after it and
-- invalidates the committed iqm_marks.dds, the rects in iqm_textures.xml, and iqm_strip's
-- bands, which are carved out of cell 0 by pixel coordinates. What still has to hold is
-- that every shape the mod OFFERS was drawn with the numbers the mod measures.
local bindex = {}
for _, b in ipairs(bshapes) do bindex[b.tex] = b end
check("build.py MARK_SHAPES parses", #bshapes > 0, "found none")
check("...and draws at least the shapes the mod offers", #bshapes >= #shapes,
	#bshapes .. " vs " .. #shapes)
local function same_opt(a, b) return (a == nil and b == nil) or close(a, b) end
for _, s in ipairs(shapes) do
	local b = bindex[s.tex]
	check("shape " .. s.key .. " (" .. s.tex .. ") matches build.py", b and
		b.kind == s.kind and close(b.alen, s.alen)
		and same_opt(b.awide, s.awide) and same_opt(b.aw, s.aw),
		b and string.format("%s/%s/%s w=%s a=%s", b.tex, b.kind, b.alen,
			tostring(b.awide), tostring(b.aw)) or "missing")
end
check("build.py MARK_WIDE matches RTE.awide",
	close(tonumber(build_src:match("MARK_WIDE%s*=%s*([%d%.]+)")), AWIDE))
check("build.py MARK_ARM matches RTE.aw",
	close(tonumber(build_src:match("MARK_ARM%s*=%s*([%d%.]+)")), AW))
-- THE SHADOW'S REACH, mirrored (R2.33). build.py checks this too, but only when someone
-- rebuilds the atlas; the failure it guards against -- a soft shadow cut off by a hard
-- straight line at the rect's edge, on every mark -- is introduced by editing either
-- number and shows up at the next game load either way.
do
	local sa = tonumber(build_src:match("\nMARK_SHADOW%s*=%s*([%d%.]+)"))
	local sw = tonumber(build_src:match("\nMARK_SHADOW_W%s*=%s*([%d%.]+)"))
	local want = (sa and sa > 0) and (sw * 0.5) or 0
	check("build.py's baked shadow reach matches RTE.SPAD", close(want, SPAD),
		string.format("build %.4f vs mod %s", want, tostring(SPAD)))
	-- ...and it is actually IN the box, which the expected-box check above would also
	-- catch -- but only by failing every shape at once with no hint as to why.
	local _, back = pcall(MK.shape_box, shapes[1].key)
	check("...and the drawn box includes it",
		(SPAD or 0) == 0 or back > shapes[1].alen * 0.5 + FPAD * AW,
		tostring(back))
end

local tex_src = slurp("gamedata/configs/ui/textures_descr/iqm_textures.xml")
for _, s in ipairs(shapes) do
	check("texture id iqm_mark_" .. s.tex .. " is declared",
		tex_src:find('id="iqm_mark_' .. s.tex .. '"', 1, true) ~= nil)
end
-- ...and the atlas they all come from.
check("the atlas file is declared", tex_src:find('name="ui\\iqm_marks"', 1, true) ~= nil)
check("the superseded single-shape id is gone",
	tex_src:find('id="iqm_mark"', 1, true) == nil)

-- ------------------------------------------------------- the texture variants (R2.42)
-- Every shape now has RTE.NVAR pictures, and place_mark re-points a widget at
-- `<tex> .. RTE.VSUF[v]`. So the ids the renderer can ask for are a CROSS PRODUCT, and a
-- missing one is not a subtle fault: the engine draws a missing texture as nothing, and
-- with a hash spreading marks evenly across the variants it would blank (NVAR-1)/NVAR of
-- the route. Checked here rather than only in build.py, whose own check fires only when
-- somebody rebuilds the atlas -- while the fault ships either way.
local NVAR = tonumber(markers_src:match("\n%s*NVAR%s*=%s*(%d+)"))
check("RTE.NVAR reads", NVAR and NVAR >= 1, tostring(NVAR))
local VSUF = {}
do
	local list = markers_src:match("\n%s*VSUF%s*=%s*{(.-)}")
	if list then for q in list:gmatch('"([%w_]*)"') do VSUF[#VSUF + 1] = q end end
end
check("...and RTE.VSUF has a suffix for each of them", #VSUF >= (NVAR or 0),
	string.format("%d suffixes for %d variants", #VSUF, NVAR or -1))
check("...the first of which is the bare id", VSUF[1] == "",
	"variant 1 must be the unsuffixed cell, or iqm_strip's carved bands move")
if NVAR and #VSUF >= NVAR then
	local missing = {}
	for _, s in ipairs(shapes) do
		for v = 1, NVAR do
			local id = "iqm_mark_" .. s.tex .. VSUF[v]
			if not tex_src:find('id="' .. id .. '"', 1, true) then
				missing[#missing + 1] = id
			end
		end
	end
	check("every shape x variant cell is declared", #missing == 0,
		missing[1] and (#missing .. " missing, first: " .. missing[1]) or nil)
end
-- The hash must actually reach every variant, or the extra cells are dead weight and the
-- run is as repetitive as it was before. Run over the ids iqm_nav really publishes --
-- consecutive integers -- which is the case a weak hash fails on.
if NVAR and NVAR > 1 then
	local seen, runs, prev = {}, 0, nil
	for mid = 0, 199 do
		local h = (mid * 2654435761) % 4294967296
		local v = 1 + math.floor(h / 65536) % NVAR
		seen[v] = (seen[v] or 0) + 1
		if v == prev then runs = runs + 1 end
		prev = v
	end
	local lo = 1e9
	for v = 1, NVAR do lo = math.min(lo, seen[v] or 0) end
	check("the variant hash reaches every cell over 200 consecutive marks",
		lo > 200 / NVAR * 0.5, string.format("rarest gets %d of 200", lo))
	-- A cycle would give zero adjacent repeats, which is its own visible pattern (ABCABC).
	-- Some repetition is what makes a run look unordered rather than dealt.
	check("...without dealing them in a visible cycle", runs > 10,
		string.format("%d adjacent repeats in 200", runs))
end

-- The card xml names one of them as the pool's starting texture; if that id is stale
-- every mark draws as a missing texture until the first config change.
local cards_src = slurp("gamedata/configs/ui/iqm_cards.xml")
local start_tex = cards_src:match("<route_mark [^>]->%s*<texture[^>]*>([%w_]+)</texture>")
check("route_mark starts on a real atlas cell",
	start_tex ~= nil and tex_src:find('id="' .. tostring(start_tex) .. '"', 1, true) ~= nil,
	tostring(start_tex))

-- ------------------------------------------------------------- 4. the default
local def = optnum("route_shape", "def")
check("DEFAULTS.route_shape is set", def ~= nil)
-- A LOOKUP, not a range test. RTE.SHAPES has holes in it, so "between the first and last
-- key" is exactly the check that would pass a default of 5 -- a number that was a shape
-- once and now silently resolves to the fallback on every load.
check("...and names a shape that exists", (function()
	for _, s in ipairs(shapes) do if s.key == tonumber(def) then return true end end
	return false
end)(), tostring(def))

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
