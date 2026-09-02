-- Harness: DRAW A FRAME of the ground route, outside the game.
--
-- WHY THIS EXISTS. Sixteen harnesses and 396 assertions, and until this one none of them
-- had ever drawn a frame through IqmCards. marks-harness loads iqm_cards, but only to call
-- shape_box and read RTE; slot, waypoint and name read it as source TEXT. So the renderer --
-- the single hottest thing in the feature, ~9 place_mark calls a frame -- had no coverage of
-- any kind, which is the same hole that let the R2.45 split ship three bugs it could not see.
--
-- The 2026-08-18 perf review (docs/route-perf.md) then found three fixes that all live on
-- exactly this uncovered path, and all three are of a shape no test that reads widget STATE
-- can catch: they remove engine calls whose result is already correct. Re-issuing
-- EnableHeading(true) on a widget whose heading is already enabled leaves the state
-- identical, so only a CALL COUNTER can tell the fixed renderer from the unfixed one. That
-- is what this file is for, and it is why nearly every stub below counts.
--
-- What it checks:
--
--   1. IT RUNS. draw_route with a real rd, through the real project/fade/place path, and
--      places the marks it should. That alone would have caught a nil upvalue in the render
--      path, which is how R2.32a took the game down.
--   2. THE CALL BUDGET. Exactly how many projections and how many widget calls one frame
--      costs, asserted as numbers. These are the review's findings 4.1 and 4.2 expressed as
--      tests: they pass on today's code and MUST be edited by whoever applies those fixes,
--      which is the point -- the number moving is the evidence the fix worked.
--   3. THE STEADY STATE. Frame 2 with identical input must produce identical geometry. The
--      counts it re-issues while doing so are recorded, because that is the waste.
--   4. THE OUTPUT IS UNCHANGED. A geometry+colour snapshot of every placed mark, compared
--      frame to frame. This is the safety net for finding 4.1: the dot-product replacement
--      for the projected `d0` must leave every mark's alpha where it was.
--   5. THE TAIL PARKS. A shrinking route hides exactly the slots it stopped using, and no
--      more -- the hide_from high-water bug (ea3263b) in its route-pool form.
--   6. BEHIND THE CAMERA. A route entirely behind the viewer places nothing, and the cost of
--      discovering that is recorded (today it is ~36 projections; after 4.1 it should be 0).
--
-- Usage:
--   python check_lua.py --run tools/route-render-harness/harness.lua
--   VERBOSE=1 ... for the passing lines, the per-mark snapshot and the call table
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
local function eq(label, got, want, detail)
	check(label, got == want,
		string.format("got %s, want %s%s", tostring(got), tostring(want),
			detail and ("  (" .. detail .. ")") or ""))
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

-- ---------------------------------------------------------------- engine env
local ENV = {}
ENV.pairs, ENV.ipairs, ENV.tostring, ENV.tonumber = pairs, ipairs, tostring, tonumber
ENV.type, ENV.string, ENV.table, ENV.math, ENV.os = type, string, table, math, os
ENV.setmetatable, ENV.print, ENV.pcall, ENV.select = setmetatable, print, pcall, select
ENV.error, ENV.assert, ENV.unpack = error, assert, unpack
ENV._G = ENV
ENV.printf = function() end

local V2MT = {}; V2MT.__index = V2MT
function V2MT:set(x, y) self.x, self.y = x, y; return self end
ENV.vector2 = function() return setmetatable({ x = 0, y = 0 }, V2MT) end

local VecMT = {}; VecMT.__index = VecMT
function VecMT:set(a, b, c)
	if type(a) == "table" then self.x, self.y, self.z = a.x, a.y, a.z
	else self.x, self.y, self.z = a, b, c end
	return self
end
-- Same trap marks-harness sets: luabind's `vector` has no __eq, so comparing two of them is
-- a CTD in game (R2.41). A plain-table stub would answer by identity and hide it.
VecMT.__eq = function()
	error("No such operator [__eq] defined in class [vector]" ..
	      " -- compare coordinates or a distance, never two vectors", 2)
end
ENV.vector = function() return setmetatable({ x = 0, y = 0, z = 0 }, VecMT) end

local FRMT = {}; FRMT.__index = FRMT
function FRMT:set(a, b, c, d) self.x1, self.y1, self.x2, self.y2 = a, b, c, d; return self end
ENV.Frect = function() return setmetatable({ x1 = 0, y1 = 0, x2 = 0, y2 = 0 }, FRMT) end

-- ARGB is packed to a single comparable value on purpose. The renderer's colour push is two
-- calls -- GetARGB then SetTextureColor -- and finding 4.2's optional third part caches the
-- result, so the snapshot has to compare colours by VALUE. A table would compare by identity
-- and every frame would look like a change.
ENV.GetARGB = function(a, r, g, b)
	return ((a % 256) * 16777216) + ((r % 256) * 65536) + ((g % 256) * 256) + (b % 256)
end

local now_ms = 0
ENV.time_global = function() return now_ms end
ENV.RegisterScriptCallback = function() end

-- ------------------------------------------------------------------- counters
local C = {}
local function zero_calls()
	C.proj, C.init_tex = 0, 0
	C.size, C.pos, C.colour = 0, 0, 0
	C.head_enable, C.head_set = 0, 0
	C.show_true, C.show_false = 0, 0
end
zero_calls()

-- ------------------------------------------------------------------- widgets
-- Every static, recording what was done to it AND how often. The module hands
-- SetWndPos/SetWndSize a SHARED scratch vector2, so values are copied out rather than
-- referenced -- referencing them would make every widget report the last one's geometry,
-- which is a bug this harness would then fail to see (minimap-harness learned this).
local statics = {}
local function new_widget(kind)
	-- shown = TRUE to start, because that is what the engine does: InitStatic hands back a
	-- visible widget, and every pool in this file parks itself at init for exactly that
	-- reason (iqm_cards:769, :819, :851). A stub that started hidden would certify those
	-- init-time hide calls as unnecessary, and route-perf 4.7's bound on the glyph park loop
	-- depends on one of them running in full.
	local w = { kind = kind, shown = true, x = 0, y = 0, w = 0, h = 0 }
	-- Per-widget park count as well as the global one, so a claim about ONE pool's park loop
	-- can be made without the rest of the badge's Show(false) calls in the total (4.7).
	w.nfalse = 0
	function w:Show(b)
		b = b and true or false
		if b then
			C.show_true = C.show_true + 1
		else
			C.show_false = C.show_false + 1
			self.nfalse = self.nfalse + 1
		end
		self.shown = b
	end
	function w:SetWndSize(v) C.size = C.size + 1; self.w, self.h = v.x, v.y end
	function w:SetWndPos(v)  C.pos  = C.pos  + 1; self.x, self.y = v.x, v.y end
	function w:SetTextureColor(c) C.colour = C.colour + 1; self.argb = c end
	function w:EnableHeading(b)
		C.head_enable = C.head_enable + 1
		self.heading_on = b and true or false
	end
	function w:SetHeading(a) C.head_set = C.head_set + 1; self.ang = a end
	function w:InitTexture(t) C.init_tex = C.init_tex + 1; self.tex = t end
	function w:SetText(s) self.text = s end
	function w:SetTextColor(c) self.textcol = c end
	statics[#statics + 1] = w
	return w
end

local parsed_files = {}
ENV.CScriptXmlInit = function()
	local x = {}
	function x:ParseFile(f) parsed_files[#parsed_files + 1] = f end
	function x:InitStatic(kind)  return new_widget(kind) end
	function x:InitTextWnd(kind) return new_widget(kind) end
	return x
end

local attached = 0
ENV.get_hud = function()
	return { AddDialogToRender = function() attached = attached + 1 end }
end

-- The dialog base. `class "X" (CUIScriptWnd)` copies these in, and __init must actually be
-- called or InitControls never runs and there is no pool to draw into.
ENV.CUIScriptWnd = {}
function ENV.CUIScriptWnd:SetWndRect(r) self.rect = r end
function ENV.CUIScriptWnd:SetAutoDelete(b) self.autodel = b end
ENV.super = function() end
ENV.class = function(name)
	return function(base)
		local c = {}
		for k, v in pairs(base or {}) do c[k] = v end
		c.__index = c
		ENV[name] = setmetatable(c, { __call = function(cls, ...)
			local o = setmetatable({}, cls)
			if o.__init then o:__init(...) end
			return o
		end })
		return ENV[name]
	end
end

-- ------------------------------------------------------------------- camera
-- UI space is the dialog's own 1024x768 (InitControls sets that rect); the screen is 16:9 so
-- UI_KX is a real correction rather than 1, which is the only way place_mark's /UI_KX divides
-- are exercised at all.
local SCREEN = { w = 1920, h = 1080 }
local UI_W, UI_H = 1024, 768
local FOCAL = 700

local cam = { x = 0, y = 1.6, z = -5 }
local fwd = { x = 0, y = 0, z = 1 }

ENV.device = function()
	return {
		cam_pos = ENV.vector():set(cam.x, cam.y, cam.z),
		cam_dir = ENV.vector():set(fwd.x, fwd.y, fwd.z),
		width = SCREEN.w, height = SCREEN.h,
	}
end

-- A pinhole camera, counted. The engine's real one returns a vector whose z is a SIGN, not a
-- distance: -1 when the point is behind the camera (level_script.cpp:1691, and the note above
-- project_off in iqm_cards). Callers only ever test `s > 0`, so a sign is all this owes them --
-- but the x/y must be a genuine perspective divide, because that is what place_mark measures
-- the mark's two axes with and what finding 4.1's replacement has to leave alone.
ENV.game = {
	world2ui_with_depth = function(v)
		C.proj = C.proj + 1
		local rx, ry, rz = v.x - cam.x, v.y - cam.y, v.z - cam.z
		local s = rx * fwd.x + ry * fwd.y + rz * fwd.z
		if s <= 0.001 then return ENV.vector():set(0, 0, -1) end
		-- right = up x fwd, with up = +Y. For fwd = +Z this is +X.
		local rgt = { x = fwd.z, y = 0, z = -fwd.x }
		local dr = rx * rgt.x + rz * rgt.z
		return ENV.vector():set(
			UI_W * 0.5 + (dr / s) * FOCAL,
			UI_H * 0.5 - (ry / s) * FOCAL,
			1)
	end,
}

-- ------------------------------------------------------------------- config
-- apply_config PULLS from iqm_core (the seam note at the top of iqm_cards), and it is the only
-- thing that sets RTE.shape -- without it InitControls' apply_shape indexes RTE.SHAPES[nil]
-- and dies. So this is not a convenience stub: the real config path is the only way in.
local CFG = {
	debug_log    = false,
	beacon_rsize = 100,
	route_shape  = 7,
	route_a      = 215,
	route_r      = 134,
	route_g      = 152,
	route_b      = 86,
	route_pulse  = 0,     -- OFF: a travelling wave makes every frame differ, and findings
	                      -- 4.2/4.4 are about frames that should be identical. Pulse gets
	                      -- its own case at the end.
}
ENV.iqm_core = { config = function() return CFG end }

-- ...and iqm_noise, which apply_config also pulls from (R2.59): iqm_cards binds the
-- interference state table there, and P() indexes it on every widget it places. AT REST --
-- amp 0 -- so the route's geometry here is the undisplaced geometry, which is what findings
-- 4.2/4.4 are about. Interference has its own harness; this one must not have a tear in it.
local NOISE_REST = { amp = 0, fr = 0, af = 1, ce = 0, txk = 0, ick = 0,
                     B = { 0, 0, 0, 0, 0, 0, 0, 0, 0 } }
ENV.iqm_noise = {
	state      = function() return NOISE_REST end,
	band_geom  = function() return 9, 1 / 71 end,
	fringe_rgb = function() return 90, 210, 225 end,
}

-- The two glyph tables apply_config flattens into the corruption pools. Stubbed with the
-- SHAPE the real ones have -- keyed by role and by faction, not by index -- because the
-- flatten has to use pairs and an ipairs would silently produce an empty pool on a hash
-- table. Which is the bug these exist to catch; see the pool assertions after apply_config.
ENV.iqm_beacon = {
	beacon_icon = { target = "iqm_role_handin", guider = "iqm_role_guide",
	                trader = "iqm_role_trader", medic  = "iqm_role_medic" },
}
ENV.iqm_core.faction_tex = function()
	return { stalker = "ui_mm_faction_stalker", dolg = "ui_mm_faction_dolg",
	         freedom = "ui_mm_faction_freedom" }
end

-- ------------------------------------------------------------------- module
local MK = setmetatable({}, { __index = ENV })
do
	local chunk, err = loadstring(slurp("gamedata/scripts/iqm_cards.script"), "@iqm_cards.script")
	assert(chunk, err)
	setfenv(chunk, MK)
	local ok, perr = pcall(chunk)
	assert(ok, "iqm_cards failed to parse: " .. tostring(perr))
end
ENV.iqm_cards = MK

-- ------------------------------------------- BEFORE ANY CONFIGURATION HAS RUN
-- THIS CASE EXISTS BECAUSE R2.50 SHIPPED A CRASH. Finding 4.3 first bound the projection
-- inside apply_config, reasoning that iqm_core calls it at the end of read_config (iqm_core:963)
-- inside on_game_start, before actor_on_update is even registered -- so nothing could possibly
-- draw first. On a fresh start that is true. On a SAVE LOAD it is not, and the game died with
--
--     iqm_cards.script:503: attempt to call upvalue 'world2ui' (a nil value)   ... draw_beacons
--
-- because loading a save re-reads the .script files and something drew a marker before
-- apply_config ran in the fresh chunk.
--
-- Every harness passed. marks-harness proves this module LOADS; nothing anywhere proved a
-- drawing function could be CALLED before configuration -- which is the entire failure. So the
-- projection is exercised here, first, deliberately ahead of apply_config and ensure().
--
-- Keep this case FIRST. Its value is entirely in its position: moved below apply_config it
-- asserts nothing, and would go on passing while the bug it exists for came back.
do
	local ok, x, y, s = pcall(MK.project_offscreen, 0, 1.6, 20)
	check("project_offscreen works before apply_config", ok and x ~= nil and s ~= nil,
		string.format("ok=%s x=%s s=%s -- a drawing path must not depend on read_config "
			.. "having run; a save load re-reads this file and draws before it does",
			tostring(ok), tostring(x), tostring(s)))
	-- NOT TESTED HERE, deliberately: the `game and` guard inside project_off, which makes an
	-- UNBOUND call with no engine return nil instead of erroring. Two attempts, both worse than
	-- the gap they closed. Clearing ENV.game after the call above proves nothing, because the
	-- binding is already cached in an upvalue -- that version passed while testing air. Loading
	-- a second cold chunk to get an unbound copy does not work either: `class` writes into the
	-- shared ENV, so the second load replaces ENV.IqmCards and breaks every case below it, and
	-- a per-load env cannot simply shadow `game` to nil because __index falls through to ENV.
	-- Isolating properly means a second class factory and a copied env for one defensive
	-- branch. The branch stays in the code as belt and braces; the assertion above is the one
	-- that guards the actual crash.
end

do
	local ok, err = pcall(MK.apply_config)
	check("apply_config runs", ok, tostring(err))
end

-- ---------------------------------------------------- the corruption glyph pools
-- WHY THESE ARE ASSERTED AT ALL. Interference's icon flicker shipped doing nothing for
-- faction emblems (R2.59b): iqm_core's faction_tex accessor sat ABOVE the local table it
-- returns, so it read the name as a namespace key and answered nil. Then three soft guards
-- in a row -- `if ft then` here, `n < 2` in corrupt_icon, `it or icon` at the draw site --
-- turned a scope error into a feature that silently did not exist. Nothing errored, nothing
-- logged, and role glyphs flickered while emblems never did.
--
-- A non-empty pool is the one cheap invariant that catches the whole chain, whichever link
-- breaks: a renamed accessor, a moved declaration, an ipairs over a hash table, or a stub
-- that forgot to provide the table at all.
do
	local function up(fn, want)
		if type(fn) ~= "function" then return nil end
		for i = 1, 80 do
			local n, v = debug.getupvalue(fn, i)
			if not n then return nil end
			if n == want then return v end
		end
	end
	-- apply_config ASSIGNS both pools, so it is the function that closes over them. Reading
	-- them off draw_slot instead answers nil -- draw_slot closes over corrupt_icon, and only
	-- corrupt_icon names the pools. That mistake cost a diagnostic round in game.
	local RP = up(MK.apply_config, "ROLE_POOL")
	local FP = up(MK.apply_config, "FACT_POOL")
	check("the role glyph pool is reachable and non-empty",
	      type(RP) == "table" and #RP > 0,
	      "corrupt_icon would return nil for every role glyph and flicker nothing")
	check("the faction emblem pool is reachable and non-empty",
	      type(FP) == "table" and #FP > 0,
	      "this is the R2.59b bug exactly -- emblems silently never corrupt")
	check("...and both hold more than one entry, or there is nothing to swap TO",
	      type(RP) == "table" and #RP > 1 and type(FP) == "table" and #FP > 1,
	      string.format("role=%s fact=%s", tostring(RP and #RP), tostring(FP and #FP)))
	-- Rebuilt, not appended: apply_config runs again on every load.
	MK.apply_config()
	local RP2 = up(MK.apply_config, "ROLE_POOL")
	check("a second apply_config does not grow the pools",
	      type(RP2) == "table" and #RP2 == #RP,
	      string.format("%s -> %s: the pools are appended to rather than rebuilt",
	                    tostring(#RP), tostring(RP2 and #RP2)))
end

local D
do
	local ok, err = pcall(MK.ensure)
	check("ensure() builds the dialog", ok, tostring(err))
	D = MK.get()
	check("get() hands it back", D ~= nil)
	eq("dialog attached to the HUD", attached, 1)
	eq("route pool built", D and #D.rmarks or 0, 16, "RTE.MARKS")
end
if not D then
	print(string.format("\n%d passed, %d failed", passed, failed))
	os.exit(failed > 0 and 1 or 0)
end

-- ------------------------------------------------------------------- the route
-- A straight run along +Z, which is where the camera is looking. Chevron k sits at
-- z = k * GAP, all of them past RTE.MNEAR (2.4 m) so none is cut by the near ramp, and all
-- within the fade window so their alphas differ -- an all-equal set of alphas would make the
-- snapshot check in case 4 pass no matter what the fade did.
local NV, NC, GAP = 24, 8, 4
local function make_rd()
	local rd = { p = {}, s = {}, a = {}, cp = {}, cdx = {}, cdz = {}, ci = {}, cn = {} }
	for i = 1, NV do
		rd.p[i] = ENV.vector():set(0, 0, (i - 1) * 2)
		rd.s[i] = (i - 1) * 2
		rd.a[i] = 1
	end
	for k = 1, NC do
		rd.cp[k]  = ENV.vector():set(0, 0, k * GAP)
		rd.cdx[k], rd.cdz[k] = 0, 1        -- unit direction of travel, +Z
		rd.ci[k]  = math.min(NV, k * 2)    -- the vertex whose eased alpha it borrows
		rd.cn[k]  = k                      -- stable id (pulse phase / texture variant)
	end
	rd.n, rd.nc = NV, NC
	return rd
end
local rd = make_rd()

local function snapshot()
	local out = {}
	for i = 1, (D.rg_used or 0) do
		local w = D.rmarks[i]
		out[i] = string.format("%.4f,%.4f,%.4f,%.4f,%.6f,%s",
			w.x, w.y, w.w, w.h, w.ang or 0, tostring(w.argb))
	end
	return table.concat(out, " | ")
end

local function frame()
	zero_calls()
	local ok, err = pcall(function() D:draw_route(rd, rd.n, rd.nc) end)
	return ok, err
end

-- ------------------------------------------------------------ 1. it runs at all
local ok1, err1 = frame()
check("draw_route runs", ok1, tostring(err1))
if not ok1 then
	print(string.format("\n%d passed, %d failed", passed, failed))
	os.exit(1)
end
local placed = D.rg_used or 0
check("marks were placed", placed > 0, "rg_used = " .. tostring(placed))
eq("every chevron placed", placed, NC,
	"all NC are in front, past MNEAR, inside MARKS")

do -- geometry sanity: a mark with a non-finite or non-positive rect is invisible or a CTD
	local bad = nil
	for i = 1, placed do
		local w = D.rmarks[i]
		if not (w.w > 0 and w.h > 0 and w.w == w.w and w.h == w.h
		        and w.x == w.x and w.y == w.y) then
			bad = string.format("mark %d: %sx%s at %s,%s", i,
				tostring(w.w), tostring(w.h), tostring(w.x), tostring(w.y))
			break
		end
	end
	check("every placed mark has a finite positive rect", bad == nil, bad)
	local shown = 0
	for i = 1, 16 do if D.rmarks[i].shown then shown = shown + 1 end end
	eq("exactly the placed marks are shown", shown, placed)
end

do -- the height floor and the cap actually bind the way place_mark says they do
	local capped, floored = false, false
	for i = 1, placed do
		local w = D.rmarks[i]
		if w.h > 768 then capped = true end
		if w.w < 6 - 1e-9 then floored = true end   -- RTE.MLMIN
	end
	check("no mark exceeds RTE.MCAP in height", not capped)
	check("no mark is under RTE.MLMIN along travel", not floored)
end

-- ------------------------------------------------------- 2. the call budget
-- THESE NUMBERS ARE THE POINT OF THE FILE. They are what today's renderer costs, and
-- docs/route-perf.md findings 4.1 and 4.2 both reduce them. Whoever applies those fixes must
-- edit the expectations here -- that edit IS the evidence, and a fix that leaves them alone
-- did not do anything.
--
--   projections = 4 per placed mark, and nothing else: t1, t2 and the two across points,
--                 all of which place_mark actually measures the rect from.
--
-- Before R2.50 it was that PLUS n for a vertex pass whose only product was the scalar d0
-- (sy never read, sx only nil-tested) PLUS nc for a chevron-centre front test whose x and y
-- were never read -- 64 where 32 would do, on this fixture. Finding 4.1 replaced both with a
-- dot product against cam_dir. If this number goes back up, the scaffolding has regrown.
local PROJ_REAL = 4 * placed
eq("projections per frame", C.proj, PROJ_REAL,
	string.format("%d marks x 4 axes points; was %d before finding 4.1",
		placed, PROJ_REAL + NV + NC))
check("no projection is spent on anything but a placed mark", C.proj % 4 == 0,
	string.format("%d is not a multiple of 4", C.proj))

-- InitTexture is NOT one per mark, and the first draft of this harness asserted that it was.
-- apply_shape leaves every slot on variant 1, so a slot is only re-pointed when its mark
-- hashes to something else -- and at NVAR 3 roughly a third of them do not. Mirroring the
-- hash here rather than hard-coding the count is deliberate: it documents which slots SHOULD
-- move, and it fails if the hash or NVAR changes, which is exactly when a silent count would
-- have gone on passing. Marks are placed far-to-near, so slot nm carries mid = nc - nm + 1;
-- the count is order-independent either way.
local NVAR = 3
local function variant_of(mid)
	local h = (mid * 2654435761) % 4294967296
	return 1 + math.floor(h / 65536) % NVAR
end
local want_tex = 0
for k = 1, NC do if variant_of(k) ~= 1 then want_tex = want_tex + 1 end end
eq("InitTexture calls", C.init_tex, want_tex,
	string.format("%d of %d marks hash off the default variant", want_tex, NC))
check("the variant hash is not degenerate", want_tex > 0 and want_tex < NC,
	string.format("%d of %d -- all or nothing means the hash is not spreading", want_tex, NC))

eq("SetWndSize calls",      C.size,        placed)
eq("SetWndPos calls",       C.pos,         placed)
eq("SetHeading calls",      C.head_set,    placed, "correct per frame: the mark rotates")
eq("SetTextureColor calls", C.colour,      placed,
	"stays per frame -- the pulse is a live input; 4.2's third part was not taken")
eq("Show(true) calls",      C.show_true,   placed,
	"first frame only: prev = 0, so every slot is newly shown")
eq("Show(false) calls",     C.show_false,  0,      "nothing to park on the first frame")

-- EnableHeading is now COUPLED TO InitTexture, not to the frame (finding 4.2 applied). It is
-- set once at pool build, and re-asserted only where a texture is re-pointed -- apply_shape
-- and place_mark's variant branch -- because that is the only thing that could plausibly clear
-- the flag. So frame 1 issues exactly as many as re-point, and a steady frame issues none.
-- Before the fix this was `placed`, every frame, for ever.
eq("EnableHeading calls", C.head_enable, want_tex,
	"one per re-pointed texture, NOT one per mark (finding 4.2)")

-- ------------------------------------------------- 3+4. the steady state
local snap1 = snapshot()
local ok2 = frame()
check("draw_route runs again", ok2)
local snap2 = snapshot()

check("geometry is identical frame to frame", snap1 == snap2,
	"pulse is off and nothing moved, so every mark must land where it did")
eq("same marks placed", D.rg_used, placed)

-- THE STEADY FRAME, which is what finding 4.2 was about. A route that is up and stays up now
-- issues nothing to re-state what the widgets already hold. These four zeros were `placed`,
-- every frame, before R2.50 -- ~2,900 engine calls a second between them at 60 fps.
eq("frame 2 re-issues no EnableHeading", C.head_enable, 0, "was placed, every frame")
eq("frame 2 re-issues no Show(true)",    C.show_true,   0, "was placed, every frame")
eq("frame 2 re-issues no InitTexture",   C.init_tex,    0,
	"the rmvar cache already did the right thing -- 4.2 done right, in the same file, "
	.. "and the model the other two now follow")
eq("frame 2 re-issues no Show(false)",   C.show_false,  0, "nm == prev, so both loops are empty")

-- What legitimately still runs every frame, asserted so a later 'optimisation' cannot quietly
-- take it away: the marks ride the projection, so geometry and rotation are live, and the
-- colour carries the pulse.
eq("frame 2 still moves the marks",    C.pos,      placed,
	"positions are NOT waste: the marks ride the projection")
eq("frame 2 still sizes the marks",    C.size,     placed, "perspective height, per frame")
eq("frame 2 still rotates the marks",  C.head_set, placed, "heading-up: correct per frame")
eq("frame 2 still pushes the colour",  C.colour,   placed,
	"4.2's third part deliberately NOT taken -- the pulse is a live input")

-- ------------------------------------------- 4b. the alphas are RIGHT, not just stable
-- The frame-to-frame check above proves the renderer is deterministic. It does NOT prove it is
-- correct, and for finding 4.1 that distinction is the whole game: swapping the projected `d0`
-- for a dot product against cam_dir could be WRONG and still be perfectly stable, so a
-- stability test would pass it through. This recomputes every mark's alpha from the same
-- formulas draw_route uses -- the two-ended fade, the head ramp measured from d0, and the
-- MNEAR cut -- so a change to how d0 is obtained has to land on the same numbers or say so.
--
-- Mirrored, in the idiom marks-harness uses for shape_box: a typo in one branch shows up here
-- as a mismatch rather than in game as a route that fades wrongly.
do
	local A, FADE, TAIL = 215, 0.72, 0.30
	local HEAD, HMIN = 1.5, 0.75
	local MNEAR, MFADE = 2.4, 0.6

	local function dist(x, y, z)
		local dx, dy, dz = x - cam.x, y - cam.y, z - cam.z
		return math.sqrt(dx * dx + dy * dy + dz * dz)
	end

	-- d0: the nearest DRAWN vertex, not vertex 1. Every vertex is in front of this camera, so
	-- the min is over all of them -- which is the case the dot-product replacement must match.
	local d0 = 1e9
	for i = 1, NV do
		local p = rd.p[i]
		local d = dist(p.x, p.y, p.z)
		if d < d0 then d0 = d end
	end

	local function want_alpha(k)
		local cp = rd.cp[k]
		local cd = dist(cp.x, cp.y, cp.z)
		local am = rd.a[rd.ci[k] or 1] or 1
		local t = (NC > 1) and ((k - 1) / NC) or 0
		local fade = 1
		if t > FADE then
			fade = 1 - (t - FADE) / (1 - FADE) * (1 - TAIL)
		else
			local near = (cd - d0) / HEAD
			if near < 1 then fade = HMIN + (1 - HMIN) * math.max(0, near) end
		end
		if cd < MNEAR then fade = 0
		elseif cd < MNEAR + MFADE then fade = fade * (cd - MNEAR) / MFADE end
		local a = math.floor(A * am * fade)
		if a > 255 then a = 255 end
		return a
	end

	-- Marks are placed FAR TO NEAR: slot i carries chevron k = NC - i + 1.
	local bad, shown_a = nil, {}
	for i = 1, placed do
		local got = math.floor(D.rmarks[i].argb / 16777216)
		local k = NC - i + 1
		local want = want_alpha(k)
		shown_a[#shown_a + 1] = got
		if got ~= want and not bad then
			bad = string.format("slot %d (chevron %d): got alpha %d, want %d",
				i, k, got, want)
		end
	end
	check("every mark's alpha matches the fade formula", bad == nil, bad)

	-- And the fade is actually DOING something: a run of identical alphas would satisfy the
	-- mirror above while proving nothing about d0 at all.
	local lo, hi = 255, 0
	for _, a in ipairs(shown_a) do
		if a < lo then lo = a end
		if a > hi then hi = a end
	end
	check("the fade spreads the alphas", hi - lo > 10,
		string.format("alphas %d..%d -- too flat to detect a d0 error", lo, hi))
	check("no mark is drawn below the a>2 cut", lo > 2, tostring(lo))
	if os.getenv("VERBOSE") then
		print("  -- alphas far..near: " .. table.concat(shown_a, ", ")
			.. string.format("   (d0 = %.4f)", d0))
	end

	-- THE HEAD RAMP, which the route above never exercises: every chevron there sits more
	-- than HEAD (1.5 m) beyond d0, so `near > 1` and the ramp is skipped on all eight. That
	-- makes the eight assertions above blind to d0 -- they would pass with d0 wrong by metres.
	-- The ramp is the ONLY consumer of d0, so this is the case finding 4.1 has to survive.
	local save_z = rd.cp[1].z
	rd.cp[1].z = 0.6                    -- just past MNEAR, well inside HEAD of vertex 1
	D:draw_route(rd, rd.n, rd.nc)
	local near_slot = D.rg_used or 0
	local got = math.floor(D.rmarks[near_slot].argb / 16777216)
	local want = want_alpha(1)
	eq("the head ramp's alpha matches", got, want,
		string.format("d0 = %.4f, chevron 1 now %.4f away", d0,
			math.sqrt((rd.cp[1].z - cam.z) ^ 2 + cam.y ^ 2)))
	check("and the ramp actually bound", want < 215,
		string.format("want %d -- if this is full alpha the ramp was skipped again "
			.. "and d0 is still untested", want))
	rd.cp[1].z = save_z
	D:draw_route(rd, rd.n, rd.nc)
end

-- --------------------------------- 4b'. the summon envelope (R2.58)
-- The fade that makes the route a SUMMONED thing rather than a standing one is a single
-- multiplier handed in by iqm_core, and this is the only place it can be seen landing on a
-- widget. What has to be true of it: it scales every mark by the same factor, it is applied
-- ON TOP of the per-mark fades rather than instead of them, and an absent argument is 1 --
-- which is what keeps every other fixture in this file, and the two debug drivers, honest.
do
	local function alphas()
		local out = {}
		for i = 1, (D.rg_used or 0) do out[i] = math.floor(D.rmarks[i].argb / 16777216) end
		return out
	end

	D:draw_route(rd, rd.n, rd.nc, 1)
	local full = alphas()
	D:draw_route(rd, rd.n, rd.nc)
	local absent = alphas()
	local same = #full == #absent
	for i = 1, #full do if full[i] ~= absent[i] then same = false end end
	check("no envelope draws exactly as an envelope of 1", same,
		"a nil argument must not change a single mark")

	D:draw_route(rd, rd.n, rd.nc, 0.5)
	local half = alphas()
	local bad = nil
	for i = 1, #full do
		-- floor() at each stage, so a mark can land one below the halved value. Anything
		-- further out means the multiplier missed a term -- which is the shape of the bug
		-- where the envelope reaches the stroke and not the chevrons, or the other way.
		local want = math.floor(full[i] * 0.5)
		if half[i] and (half[i] > want or half[i] < want - 1) and not bad then
			bad = string.format("mark %d: %d at full, %d at half, wanted ~%d",
				i, full[i], half[i], want)
		end
	end
	check("half the envelope is half of every mark's alpha", bad == nil and #half == #full, bad)

	-- ...and 0 draws nothing at all, which is the state the route spends most of the session
	-- in once the summon is the default: the a > 0.02 cut has to swallow the whole list
	-- rather than leaving a row of marks at alpha 0 on the widget pool.
	D:draw_route(rd, rd.n, rd.nc, 0)
	check("a zero envelope places no mark", (D.rg_used or 0) == 0, tostring(D.rg_used))
	D:draw_route(rd, rd.n, rd.nc)
	check("...and the next full frame puts them all back", (D.rg_used or 0) == #full,
		string.format("%d of %d", D.rg_used or 0, #full))
end

-- --------------------------------- 4c. d0 is the nearest DRAWN vertex, not vertex 1
-- Mutation-proving 4b found this hole: with the route running straight away from the camera,
-- vertex 1 IS the nearest, so `d0 = sd[1]` and `d0 = min(all drawn)` are the same number and
-- the assertions above cannot tell them apart -- a d0 rewritten to read vertex 1 passed all
-- sixty. The distinction draw_route documents ("a vertex that failed to project is not on
-- screen, so measuring from it would fade the stretch that IS on screen against a reference
-- the viewer cannot see") only bites when the near vertices are BEHIND the camera, which is
-- the ordinary case of a route you have already walked part of.
--
-- So: camera part-way along the run, looking forward. Vertices 1-3 are behind it, vertex 3 is
-- recovered by clip_front with a borrowed depth, and d0 must come from what is actually drawn.
do
	local save = { y = cam.y, z = cam.z }
	cam.y, cam.z = 3.0, 5.0            -- raised, which widens the head ramp's usable band

	local r2 = { p = {}, s = {}, a = {}, cp = {}, cdx = {}, cdz = {}, ci = {}, cn = {} }
	for i = 1, 7 do
		r2.p[i] = ENV.vector():set(0, 0, (i - 1) * 2)   -- z = 0,2,4 behind; 6,8,10,12 in front
		r2.s[i] = (i - 1) * 2
		r2.a[i] = 1
	end
	-- One chevron, placed so its camera distance sits INSIDE HEAD of the true d0 but clear of
	-- the MNEAR+MFADE ramp, so the head ramp is the only thing shaping its alpha.
	r2.cp[1] = ENV.vector():set(0, 0, 7.6458)
	r2.cdx[1], r2.cdz[1] = 0, 1
	r2.ci[1], r2.cn[1] = 4, 1
	r2.n, r2.nc = 7, 1

	local function dist2(z) return math.sqrt((z - cam.z) ^ 2 + cam.y ^ 2) end

	-- d0 as the code defines it: over vertices that PROJECTED. z <= cam.z is behind.
	local d0 = 1e9
	for i = 1, r2.n do
		local z = r2.p[i].z
		if z > cam.z + 0.001 then
			local d = dist2(z)
			if d < d0 then d0 = d end
		end
	end
	local d_vertex1 = dist2(r2.p[1].z)          -- what the broken version would measure
	check("the fixture makes d0 and vertex 1 differ", math.abs(d0 - d_vertex1) > 1.0,
		string.format("d0 = %.4f, vertex 1 = %.4f -- if these are close the case proves "
			.. "nothing", d0, d_vertex1))

	D:draw_route(r2, r2.n, r2.nc)
	eq("the chevron is drawn", D.rg_used, 1)

	local cd = dist2(r2.cp[1].z)
	local near = (cd - d0) / 1.5
	check("the head ramp binds in this fixture", near < 1 and cd > 3.0,
		string.format("cd = %.4f, near = %.4f", cd, near))
	local want = math.floor(215 * (0.75 + 0.25 * math.max(0, near)))
	local got = math.floor(D.rmarks[1].argb / 16777216)
	eq("alpha is measured from the nearest DRAWN vertex", got, want,
		string.format("d0 = %.4f (vertex %d), not %.4f (vertex 1)", d0, 4, d_vertex1))

	-- And state the counter-value explicitly: what the broken version would have produced.
	local wrong = math.floor(215 * math.min(1, 0.75 + 0.25 * math.max(0, cd / 1.5)))
	check("the broken reading would give a different alpha", wrong ~= want,
		string.format("both give %d -- the case cannot discriminate", want))
	if os.getenv("VERBOSE") then
		print(string.format("  -- d0 case: alpha %d (correct), %d if read off vertex 1",
			want, wrong))
	end

	cam.y, cam.z = save.y, save.z
	D:draw_route(rd, rd.n, rd.nc)
end

-- ------------------------------------------------- 4d. the near cut and its ramp
-- Also found by mutation-proving: disabling the MNEAR cut entirely changed nothing, because no
-- fixture above puts a mark inside 2.4 m. That cut is not cosmetic -- place_mark's one quad
-- cannot draw a mark correctly at that range (RTE.MNEAR's own comment), and the ramp over
-- MFADE exists because a world-anchored mark crosses the threshold as the player walks and a
-- hard edge there pops.
do
	local MNEAR, MFADE, A = 2.4, 0.6, 215
	local function dist_to(z)
		local dz, dy = z - cam.z, -cam.y
		return math.sqrt(dz * dz + dy * dy)
	end
	local save_z = rd.cp[1].z

	-- Inside the cut: not drawn at all.
	rd.cp[1].z = -3.5
	check("the fixture puts the mark inside MNEAR", dist_to(rd.cp[1].z) < MNEAR,
		string.format("%.4f", dist_to(rd.cp[1].z)))
	D:draw_route(rd, rd.n, rd.nc)
	eq("a mark inside MNEAR is not drawn", D.rg_used, NC - 1,
		"one quad cannot draw a mark at that range, so it is dropped")
	-- HONEST LIMIT of the assertion above: it proves the mark is dropped, not WHICH branch
	-- drops it. Disabling the `cd < MNEAR then fade = 0` cut does not change the outcome,
	-- because the MFADE elseif then catches the same range and computes a NEGATIVE factor --
	-- (cd - MNEAR) is below zero there -- so alpha goes negative and the a > 2 test rejects
	-- the mark anyway. The cut is defensive rather than load-bearing over its own range, and
	-- no alpha-level assertion can tell the two enforcement paths apart. Recorded so nobody
	-- reads this case as mutation-proved cover for that line: it is not, and cannot be.

	-- In the ramp: drawn, but dimmed in proportion.
	rd.cp[1].z = -2.825
	local cd = dist_to(rd.cp[1].z)
	check("the fixture puts the mark in the MFADE ramp",
		cd > MNEAR and cd < MNEAR + MFADE, string.format("%.4f", cd))
	D:draw_route(rd, rd.n, rd.nc)
	eq("a mark in the ramp is drawn", D.rg_used, NC)
	-- Nearest chevron is placed last (far to near), so it is the highest slot.
	--
	-- BOTH fades apply, which the first draft of this assertion got wrong. Pulling the mark
	-- inside MNEAR also pulls it NEARER than every route vertex, so `near` in the head ramp
	-- goes negative, clamps at 0, and leaves fade at HMIN -- and the MFADE ramp then
	-- multiplies that. Expecting the ramp alone predicted 107 where the code gives 80, and
	-- the 0.75 ratio between them is HMIN saying so. The two are composed, not alternatives.
	local HEAD, HMIN = 1.5, 0.75
	local d0 = 1e9
	for i = 1, rd.n do
		local p = rd.p[i]
		local dz, dy, dx = p.z - cam.z, p.y - cam.y, p.x - cam.x
		local d = math.sqrt(dx * dx + dy * dy + dz * dz)
		if d < d0 then d0 = d end
	end
	local head = HMIN + (1 - HMIN) * math.max(0, (cd - d0) / HEAD)
	local ramp = (cd - MNEAR) / MFADE
	local got = math.floor(D.rmarks[D.rg_used].argb / 16777216)
	local want = math.floor(A * 1 * head * ramp)
	eq("and is dimmed by the ramp, not switched", got, want,
		string.format("cd = %.4f, head %.4f x ramp %.4f", cd, head, ramp))
	check("the ramp is a real reduction", want < A * 0.9, tostring(want))
	check("this mark is nearer than any vertex, so the head fade is at its floor",
		cd < d0, string.format("cd %.4f vs d0 %.4f", cd, d0))

	rd.cp[1].z = save_z
	D:draw_route(rd, rd.n, rd.nc)
	eq("the route recovers", D.rg_used, NC)
end

-- --------------------------------------------------------- 5. the tail parks
do
	local full = D.rg_used
	rd.nc = 3
	zero_calls()
	D:draw_route(rd, rd.n, rd.nc)
	eq("shrinking the route places fewer marks", D.rg_used, 3)
	eq("it parks exactly what it stopped using", C.show_false, full - 3,
		"not the pool high-water mark -- that was ea3263b's hide_from bug")
	local still = false
	for i = 4, 16 do if D.rmarks[i].shown then still = true end end
	check("no stale mark is left shown", not still)

	zero_calls()
	D:draw_route(rd, rd.n, rd.nc)
	eq("a steady short route parks nothing", C.show_false, 0,
		"the high-water bug's signature is a nonzero count here, for ever")
	rd.nc = NC
	D:draw_route(rd, rd.n, rd.nc)
	eq("the route comes back", D.rg_used, NC)
end

-- ------------------------------------------------- 6. behind the camera
do
	local save_z = cam.z
	cam.z = 1e4                       -- camera far past the end, still looking +Z
	zero_calls()
	local ok3 = pcall(function() D:draw_route(rd, rd.n, rd.nc) end)
	check("a route behind the camera draws without error", ok3)
	eq("nothing is placed", D.rg_used, 0)
	eq("no mark is sized", C.size, 0)
	-- THE BEST CASE FOR FINDING 4.1, and the one the review predicted: with the route behind
	-- the viewer the renderer now costs ZERO engine calls, where it used to spend a projection
	-- on every vertex and every chevron to discover there was nothing to draw. Turning round
	-- used to cost 36 projections a frame, for ever.
	eq("discovering it costs no projections at all", C.proj, 0,
		"a dot product rejects a point behind the camera without touching the engine")
	eq("and no widget calls", C.pos + C.size + C.head_set + C.colour, 0)
	cam.z = save_z
	D:draw_route(rd, rd.n, rd.nc)
	eq("it comes back when the camera does", D.rg_used, NC)
end

-- ------------------------------------------------------------- 7. the pulse
-- The one thing that SHOULD differ frame to frame. Guards the optional colour cache in
-- finding 4.2: cache the colour and this case goes red, which is the correct outcome for a
-- cache that ignored the clock.
do
	CFG.route_pulse = 10
	MK.apply_config()
	now_ms = 0
	D:draw_route(rd, rd.n, rd.nc)
	local a = snapshot()
	now_ms = 200                      -- ~half a cycle at PULSE_HZ 2.4
	zero_calls()
	D:draw_route(rd, rd.n, rd.nc)
	local b = snapshot()
	check("the pulse changes the marks over time", a ~= b,
		"if this passes only because geometry moved, the colour is not pulsing")
	eq("the pulse still pushes one colour per mark", C.colour, D.rg_used)
	CFG.route_pulse = 0
	MK.apply_config()
end

-- ------------------------------------------------- 7b. off the route's axis
-- The straight-down-the-route view above is DEGENERATE for one of the two axes place_mark
-- measures: looking along travel foreshortens the along axis to almost nothing, so `ln` lands
-- on RTE.MLMIN for nearly every mark and the width stops depending on the projection at all.
-- A snapshot taken only in that view would therefore not notice a change to the along
-- measurement -- which is precisely what finding 4.1 touches. So: the same route, viewed from
-- the side and front, where both axes are genuinely measured.
do
	local save = { x = cam.x, y = cam.y, z = cam.z, fx = fwd.x, fz = fwd.z }
	cam.x, cam.y, cam.z = -26, 6, -14
	local k = 1 / math.sqrt(2)
	fwd.x, fwd.z = k, k                -- 45 degrees across the run

	zero_calls()
	local okA = pcall(function() D:draw_route(rd, rd.n, rd.nc) end)
	check("draws from off-axis", okA)
	local shown_off = D.rg_used or 0
	check("marks are placed off-axis", shown_off > 0, tostring(shown_off))

	local floored, widths, xs = 0, {}, {}
	for i = 1, shown_off do
		local w = D.rmarks[i]
		if w.w <= 6 + 1e-9 then floored = floored + 1 end
		widths[#widths + 1] = w.w
		xs[w.x] = true
	end
	check("the along axis is genuinely measured off-axis", floored < shown_off * 0.5,
		string.format("%d of %d marks still on the MLMIN floor -- the view is still too "
			.. "end-on to test the along axis", floored, shown_off))
	local distinct_x = 0
	for _ in pairs(xs) do distinct_x = distinct_x + 1 end
	check("marks spread across the screen off-axis", distinct_x > 1,
		string.format("%d distinct x", distinct_x))
	eq("projection budget is unchanged by the view", C.proj, 4 * shown_off)

	local a = snapshot()
	zero_calls()
	D:draw_route(rd, rd.n, rd.nc)
	check("off-axis geometry is stable frame to frame", a == snapshot())
	eq("and a steady off-axis frame re-states nothing", C.head_enable, 0,
		"the 4.2 saving is not an artefact of the head-on view")
	eq("nor re-shows", C.show_true, 0)

	if os.getenv("VERBOSE") then
		print("  -- off-axis widths: " .. table.concat(widths, ", "))
	end

	cam.x, cam.y, cam.z = save.x, save.y, save.z
	fwd.x, fwd.z = save.fx, save.fz
	D:draw_route(rd, rd.n, rd.nc)
end

-- ------------------------------------------- 7c. the park loops (route-perf 4.7)
-- 4.7 was reported as the card layer parking unused slots UNCONDITIONALLY, ~6 hide_slot
-- calls a frame for ~7 us. That diagnosis was wrong twice over. hide_slot has latched on
-- `s.hidden` since before the review -- its own comment says so, and iqm_core's says "the
-- same latched no-ops" -- so the 355,974 calls in the profile each cost a dispatch, three
-- reads and a return. At the ~1.5 us of profiler wrapper per call established in section 1
-- of route-perf.md, six latched calls a frame ARE the 7 us that was measured. There was no
-- 7 us to recover.
--
-- What IS unbounded is one level down, in the beacon's four range-glyph widgets, and nothing
-- anywhere drove a beacon or a card slot through this harness -- so both the latch that does
-- exist and the bound that did not were uncovered.
do
	local BCFG = { col_r = 200, col_g = 210, col_b = 180 }
	-- `ring` since R2.63: the candidate record carries the ring's TEXTURE now, not a flag,
	-- and nil is "no ring". Left nil here on purpose -- this harness measures the route,
	-- and an unringed marker is the layout the ring's overhang is measured against; the
	-- ringed geometry is the waypoint harness's subject.
	local BE   = { tex = "iqm_role_handin", col = nil, nmt = nil, ring = nil }
	--- One beacon frame at the given range readout (nil = readout off), returning how many of
	--  the four GLYPH widgets it parked. Counted per widget rather than off C.show_false: the
	--  badge's own if/else branches park six more (the plate and its shadow, which
	--  BADGE_PLATE has left off since R2.30, the ring, and the name pair), and a total that
	--  included those would move whenever the badge layout did.
	local GL = D.beacons[1].gl
	-- FIRST, before anything draws: the pool must have parked itself. The bound added in 4.7
	-- is seeded at MAX_RGLYPH precisely so this one hide_beacon walks the whole pool -- seed
	-- it at 0 and four visible glyph widgets sit on the HUD from the moment the dialog is
	-- built, which is the failure mode the optimisation can have and the reason the widget
	-- stub starts `shown = true`.
	do
		local up_at_init = 0
		for i = 1, 6 do
			for k = 1, 4 do
				if D.beacons[i].gl[k].g.shown then up_at_init = up_at_init + 1 end
			end
		end
		eq("every beacon glyph is parked before anything draws", up_at_init, 0,
			"InitStatic returns them visible; the init-time hide_beacon is what takes "
				.. "them down, and it must not be bounded away")
	end
	local function beacon(mtr)
		for k = 1, 4 do GL[k].g.nfalse = 0 end
		D:draw_beacon(1, 500, 300, 0, -1, 0, 255, mtr, BCFG, 20, false, BE)
		local n = 0
		for k = 1, 4 do n = n + GL[k].g.nfalse end
		return n
	end

	-- 120 m is three digits and the metre suffix: the whole pool, so there is nothing above
	-- it to park. This is also the assertion that proves the fixture reaches the loop at all.
	eq("a full-width readout parks nothing", beacon(120), 0,
		"three digits and the suffix fill all four glyph widgets")
	-- ...and dropping to two digits parks the one widget that fell out of use, not the whole
	-- tail of the pool.
	eq("a readout that loses a digit parks exactly that digit", beacon(99), 1,
		"100 m -> 99 m frees one glyph")
	-- THE POINT OF THE FIX. Before it this was 1 every frame, for as long as the beacon was
	-- up, on a widget that had been hidden since the frame the readout shrank.
	eq("...and the frame after that parks nothing at all", beacon(99), 0,
		"the glyph is already down; re-parking it is the waste 4.7 was reaching for")

	-- With the range readout switched off, draw_beacon takes its early return -- and that is
	-- the branch that used to walk the whole pool on every frame of every drawn beacon.
	eq("switching the readout off parks the glyphs that were showing", beacon(nil), 3,
		"two digits and a suffix come down")
	eq("...and every frame after it parks nothing", beacon(nil), 0,
		"4 every frame before the fix, for every beacon on screen")

	-- THE READOUT ACTUALLY HAS A SIZE, which every assertion above this took on trust: they
	-- count PARKING calls, and a digit drawn at height 0 is still a shown widget, so the
	-- whole block passes unchanged while the readout is invisible on screen. That is not
	-- hypothetical -- R2.63a shipped exactly it. `local rh` for the ring's height shadowed
	-- the readout's `rh` for the rest of draw_beacon, so the digits took the RING's height:
	-- zero on an unringed marker (which is this fixture, and nearly every marker in play)
	-- and 1.58x the marker size on a ringed one, against digit WIDTHS computed before the
	-- shadow from the right number. Tall and thin, or gone.
	--
	-- So the geometry is asserted against RD_G, read out of the source rather than
	-- restated, and asserted for a RINGED marker too -- the two differ by exactly the
	-- local that was shadowed, so one case alone would not have caught it.
	do
		-- RD_G.f is NOT the 0.40 in the source: read_config overwrites it from beacon_rsize,
		-- and CFG above sets that to 100. So the expectation comes from the config this
		-- harness actually applied, which is also the only honest source for it -- reading
		-- the file default would assert against a number the module stopped holding the
		-- moment apply_config ran.
		local RD_F = CFG.beacon_rsize / 100
		local SIZE = 20                       -- the size every draw_beacon call here passes
		local want = math.max(2, SIZE * RD_F)
		local RINGED = { tex = BE.tex, col = BE.col, nmt = BE.nmt,
		                 ring = "iqm_role_ringtask" }
		for _, case in ipairs{ {"unringed", BE}, {"ringed", RINGED} } do
			D:draw_beacon(3, 500, 300, 0, -1, 0, 255, 120, BCFG, SIZE, false, case[2])
			local g = D.beacons[3].gl[1].g
			check("the " .. case[1] .. " readout draws a digit of the readout's height",
			      g.h and math.abs(g.h - want) < 1e-6,
			      string.format("digit height %s, want %.3f -- the ring's height has been "
			                    .. "shadowed over the readout's", tostring(g.h), want))
			check("...and a digit wider than it is nothing",
			      g.w and g.w > 0 and g.h and g.h > 0,
			      "a zero-sized glyph is still a SHOWN glyph, which is why the parking "
			      .. "counts above cannot see this")
			-- ...AND THE RING CLEARS THE READOUT, measured off the two widgets rather than
			-- re-derived. The waypoint harness had a numeric sweep for this whose two sides
			-- both expanded to the same expression, so it read as evidence while being
			-- identically true for every k and fit -- it could not have failed if the ring
			-- sat on top of the digits. This can: the ring's overhang is folded into the
			-- badge metrics precisely so the readout is pushed below it, and that collision
			-- is a bug that was REPORTED once already, against a ring smaller than this one.
			if case[2].ring then
				local rg = D.beacons[3].ring
				check("the ring is drawn with a real box",
				      rg.w and rg.w > 0 and rg.h and rg.h > 0)
				check("...and its bottom edge clears the readout's top",
				      rg.y and rg.h and g.y and (rg.y + rg.h) <= g.y + 1e-6,
				      string.format("ring bottom %s vs digit top %s",
				                    tostring(rg.y and rg.y + rg.h), tostring(g.y)))
				check("...and the ring is wider than the glyph it frames",
				      rg.w > D.beacons[3].icon.w,
				      "a ring no bigger than its glyph is an outline, not a frame")
			end
		end
		D:hide_beacon(3)
	end

	-- The latch on hide_beacon, which is real and was equally uncovered. The glyphs are
	-- already down from the two frames above, so what this parks is the seven badge widgets.
	zero_calls()
	D:hide_beacon(1)
	eq("hide_beacon parks the badge once", C.show_false, 7,
		"shadow, plate, icon, chevron, ring, name and its shadow")
	zero_calls()
	D:hide_beacon(1)
	eq("...and is free every time after", C.show_false, 0, "b.hidden short-circuits it")

	-- ...and it has to leave the high-water mark saying what is true, or the three loops
	-- above are reasoning off a number that lies. A second beacon, so the sequence is clean:
	-- shown with a readout, hidden, then shown with the readout off. The last of those parks
	-- from 1, so it is the frame that reads the mark hide_beacon left behind.
	local GL2 = D.beacons[2].gl
	D:draw_beacon(2, 400, 300, 0, -1, 0, 255, 99, BCFG, 20, false, BE)
	D:hide_beacon(2)
	for k = 1, 4 do GL2[k].g.nfalse = 0 end
	D:draw_beacon(2, 400, 300, 0, -1, 0, 255, nil, BCFG, 20, false, BE)
	local after_hide = 0
	for k = 1, 4 do after_hide = after_hide + GL2[k].g.nfalse end
	eq("a beacon shown after being hidden parks nothing that is already down", after_hide, 0,
		"hide_beacon took the glyphs down, so its high-water mark must say zero")

	-- And the same latch on hide_slot -- the thing 4.7 actually named. `hidden` is set
	-- directly rather than by driving draw_slot's whole body: the claim under test is about
	-- hide_slot, and draw_slot's only contribution to it is that one assignment.
	D.slots[1].hidden = false
	zero_calls()
	D:hide_slot(1)
	eq("hide_slot parks a shown card once", C.show_false, 13, "the card's thirteen widgets")
	zero_calls()
	D:hide_slot(1)
	eq("...and is a no-op on every frame after", C.show_false, 0,
		"which it already was -- 4.7's premise, tested rather than assumed")
end

-- --------------------------------------------------------------- 8. contract
do
	eq("the dialog parsed its own xml", parsed_files[1], "iqm_cards.xml")
	-- project_off returns THREE values and the codebase has twice been bitten by
	-- `local a, b, c = M.f and M.f()` truncating a multiple return to one. The public alias
	-- is the one other modules bind, so its arity is a contract.
	local x, y, s = MK.project_offscreen(0, 1.6, 20)
	check("project_offscreen returns three values",
		x ~= nil and y ~= nil and s ~= nil,
		string.format("%s %s %s", tostring(x), tostring(y), tostring(s)))
	check("and a sign, not a distance, in the third", s == 1 or s == -1, tostring(s))
	local _, _, bs = MK.project_offscreen(0, 1.6, -100)
	check("behind the camera it reports -1", bs == -1, tostring(bs))
	check("kx() is a real aspect correction at 16:9", math.abs(MK.kx() - 0.75) < 1e-6,
		tostring(MK.kx()))
end

if os.getenv("VERBOSE") then
	print("\n  -- one frame, by the numbers ---------------------------------")
	print(string.format("  marks placed        %d", placed))
	print(string.format("  projections         %d  (all real; was %d before R2.50)",
		PROJ_REAL, PROJ_REAL + NV + NC))
	print(string.format("  widget calls        %d on a first frame, %d on a steady one",
		placed * 5 + want_tex * 2, placed * 4))
	print(string.format("  statics built       %d  (route %d + cards + beacons)",
		#statics, 16))
	print("\n  -- marks (x,y,w,h,ang,argb) ---------------------------------")
	print("  " .. snap1:gsub(" | ", "\n  "))
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed > 0 and 1 or 0)
