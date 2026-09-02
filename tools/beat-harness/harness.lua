-- Harness: WHEN this mod does its expensive work, checked outside the game.
--
-- WHY THIS EXISTS. Every other harness in this folder asks whether an answer is right.
-- This one asks when the work happens, because two of the mod's costs were correct on
-- average and wrong in their distribution -- which no assertion about an answer can see,
-- and which is exactly the shape a player reports as "it hitches every couple of
-- seconds" rather than "it is slow".
--
--   1. THE LOS CAST. has_los seeds f.los_next on the NPC's first qualifying frame and
--      then advances it by a constant forever. Constant increment means any NPCs seeded
--      on the SAME frame stay phase-locked for as long as they are all carded -- and a
--      squad crests a ridge, or a bar loads in, or a fast travel lands, and eight of
--      them are seeded on one frame. Eight head-bone pcalls and eight 1000-unit
--      ray_picks then recur together on one frame in nine while the eight frames either
--      side do none. The fix scatters the FIRST deadline only; the steady-state interval
--      must be untouched, which is the property that is easy to break and is asserted
--      here first.
--
--   2. THE MERGE. actor_on_update used to force update() onto the very frame the
--      amortized scanner published, so the two largest bursts the mod has -- the
--      scanner's final slice and the full collect_desired + rank + re-decorate -- were
--      GUARANTEED to land together, on a fixed ~2 s beat. It now runs on the next frame
--      instead. "Next", not "never", is the whole point, so both halves are asserted.
--
-- Nothing else can catch either. The compile gate sees valid Lua either way, and no
-- other harness draws a frame or turns the scan loop, so both regressions would revert
-- silently. So the real closures are driven here against a fake clock, the same way
-- reach-harness drives route_goal: iqm_core is loaded into a stub environment and its
-- file locals are reached through debug.getupvalue off what it exports.
--
-- Usage:
--   python check_lua.py --run tools/beat-harness/harness.lua
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

-- --------------------------------------------------------------- environment
-- Deliberately the same minimal stub set reach-harness uses, plus the three things
-- only the render/LOS path touches: a camera, a geometry ray and the card dialog.
local ENV = {}
ENV.pairs, ENV.ipairs, ENV.tostring, ENV.tonumber = pairs, ipairs, tostring, tonumber
ENV.type, ENV.string, ENV.table, ENV.math, ENV.os = type, string, table, math, os
ENV.setmetatable, ENV.print, ENV.pcall, ENV.select = setmetatable, print, pcall, select
ENV.error, ENV.assert, ENV.unpack, ENV.next = error, assert, unpack, next
ENV._G = ENV
ENV.printf = function() end

local V2MT = {}
V2MT.__index = V2MT
function V2MT:set(x, y) self.x, self.y = x, y; return self end
ENV.vector2 = function() return setmetatable({ x = 0, y = 0 }, V2MT) end

-- The LOS path does real vector arithmetic (set / sub / normalize / distance_to), so
-- unlike the other harnesses' stub these have to compute rather than merely exist:
-- the cast's clear/occluded verdict is a comparison of two distances.
local VecMT = {}
VecMT.__index = VecMT
function VecMT:set(a, b, c)
	if type(a) == "table" then self.x, self.y, self.z = a.x, a.y, a.z
	else self.x, self.y, self.z = a, b, c end
	return self
end
function VecMT:sub(o) self.x, self.y, self.z = self.x - o.x, self.y - o.y, self.z - o.z; return self end
function VecMT:normalize()
	local m = math.sqrt(self.x * self.x + self.y * self.y + self.z * self.z)
	if m > 0 then self.x, self.y, self.z = self.x / m, self.y / m, self.z / m end
	return self
end
function VecMT:distance_to(o)
	local dx, dy, dz = self.x - o.x, self.y - o.y, self.z - o.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end
function VecMT:distance_to_sqr(o)
	local dx, dy, dz = self.x - o.x, self.y - o.y, self.z - o.z
	return dx * dx + dy * dy + dz * dz
end
-- Same trap as the other harnesses: luabind's vector has no __eq, so comparing two of
-- them is a CTD in game. A stub that answered by identity would hide it.
VecMT.__eq = function() error("No such operator [__eq] defined in class [vector]", 2) end
local function vec(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, VecMT) end
ENV.vector = function() return vec(0, 0, 0) end

ENV.GetARGB = function(a, r, g, b) return { a = a, r = r, g = g, b = b } end
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

-- THE CLOCK, as in reach-harness: time_global is bound as a file local at parse time,
-- so a closure installed before the chunk runs is the clock the throttles read.
local CLOCK = 10000
ENV.time_global = function() return CLOCK end

-- THE CAMERA. Fixed at the origin; the NPCs below are placed at a known distance from
-- it so a cast's verdict is a matter of arithmetic rather than of luck.
local CAM = vec(0, 0, 0)
ENV.device = function() return { cam_pos = CAM } end

-- THE RAY. Counting gr:get is counting casts: los_cast builds the wrapper once and
-- calls get once per cast, and has_los reaches los_cast only on a cast frame. HITDIST
-- is what the world reports back -- 1000 for "nothing in the way", something nearer
-- than the NPC for "behind cover".
local CASTS, HITDIST, IGNORED = 0, 1000, nil
ENV.demonized_geometry_ray = {
	geometry_ray = function()
		return {
			ray = { set_ignore_object = function(_, o) IGNORED = o end },
			get = function(_, _, _) CASTS = CASTS + 1; return { distance = HITDIST } end,
		}
	end,
}

ENV.db = { actor = { position = function() return vec(0, 0, 0) end } }
ENV.iqm_cards = { ensure = function() return { invalidate_beacons = function() end } end }
ENV.IsStalker = function() return true end
ENV.IsMonster = function() return false end
ENV.level = { name = function() return "l01_escape" end }
ENV.alife = function() return { object = function() return nil end } end

local CORE = setmetatable({}, { __index = ENV })
do
	local chunk, err = loadstring(slurp("gamedata/scripts/iqm_core.script"), "@iqm_core.script")
	assert(chunk, err)
	setfenv(chunk, CORE)
	local ok, perr = pcall(chunk)
	assert(ok, "iqm_core failed to parse: " .. tostring(perr))
end

-- ---------------------------------------------------- reaching the file locals
local function upget(fn, name)
	for i = 1, 90 do
		local n, v = debug.getupvalue(fn, i)
		if not n then return nil end
		if n == name then return v, i end
	end
end
local function upset(fn, name, val)
	local _, i = upget(fn, name)
	if not i then return false end
	debug.setupvalue(fn, i, val)
	return true
end
local function climb(fn, ...)
	for _, name in ipairs({ ... }) do
		if type(fn) ~= "function" then return nil end
		fn = upget(fn, name)
	end
	return fn
end

local actor_on_update = climb(CORE.on_game_start, "actor_on_update")
local render          = climb(actor_on_update, "render")
local has_los         = climb(render, "has_los")
check("the real actor_on_update, render and has_los are reachable",
      type(actor_on_update) == "function" and type(render) == "function"
      and type(has_los) == "function",
      "without them the frame beat can only be grepped, not driven")

local C    = upget(has_los, "C")
local FILT = upget(has_los, "FILT")
check("iqm_core's C and FILT are reachable", type(C) == "table" and type(FILT) == "table")

-- ==========================================================================
-- 1. THE LOS CAST
-- ==========================================================================
-- An NPC has to have a filter entry before has_los will remember anything about it
-- (`if not f then return clear end`), which render guarantees and which is done here
-- by hand. Positions: every NPC sits LOS_D metres from the camera, and the bone fetch
-- is answered so the head-sample path is the one exercised.
local LOS_D = 10
local function npc(id)
	FILT[id] = { a = 0 }
	local p = vec(0, 0, LOS_D)
	return { bone_position = function(_, _) return p end,
	         alive = function() return true end,
	         position = function() return p end }
end
local function forget(id) FILT[id] = nil end

C.los_check = true
C.los_rate  = 150
C.los_grace = 400

-- ------------------------------------------------- 1a. the throttle still bounds
-- Drive one NPC across four seconds of 10 ms frames and record the frame of every
-- cast. The jitter is allowed to make the SECOND cast early; it is not allowed to
-- shorten the interval after that, which is the failure mode a "spread it out" change
-- most easily introduces (re-jittering on every deadline instead of the first).
do
	local o, id = npc(4001), 4001
	CASTS, HITDIST = 0, 1000
	local at = {}
	local t0 = CLOCK
	for _ = 1, 400 do
		local before = CASTS
		has_los(id, o, o:position(), CLOCK)
		if CASTS > before then at[#at + 1] = CLOCK end
		CLOCK = CLOCK + 10
	end
	local span = CLOCK - 10 - t0
	check("a lone NPC casts on its very first frame", at[1] == t0, tostring(at[1]))
	local worst, worst_gap = nil, nil
	for i = 3, #at do
		local gap = at[i] - at[i - 1]
		if gap < C.los_rate and (worst_gap == nil or gap < worst_gap) then
			worst, worst_gap = i, gap
		end
	end
	check("no steady-state gap is shorter than los_rate", worst == nil,
	      worst and string.format("cast %d came %d ms after the one before, rate is %d",
	                              worst, worst_gap, C.los_rate) or nil)
	-- ...and the same rule stated as a budget, so a change that casts every frame while
	-- keeping the gaps technically legal cannot slip through either.
	local ceiling = math.floor(span / C.los_rate) + 2   -- +1 for the first frame, +1 for the early second
	check("...and the total over four seconds stays inside the throttle's budget",
	      #at <= ceiling, string.format("%d casts over %d ms, ceiling %d", #at, span, ceiling))
	forget(id)
end

-- --------------------------------------------------- 1b. the first cast is spread
-- Eight NPCs qualifying on ONE frame: the corner-into-a-bar case. They must all cast
-- that frame (the fix must not delay a card's first verdict) and must NOT then all fall
-- due together. Consecutive ids on purpose -- a squad is created together and so carries
-- consecutive ids, and that is the case a bare `id % rate` fails, mapping them one
-- millisecond apart and back into a single 16 ms frame.
do
	local FRAME = 16
	local ids, objs = {}, {}
	for i = 1, 8 do ids[i] = 5000 + i; objs[i] = npc(ids[i]) end
	CASTS, HITDIST = 0, 1000
	local t0 = CLOCK
	for i = 1, 8 do has_los(ids[i], objs[i], objs[i]:position(), CLOCK) end
	check("all eight cast on the frame they arrive on", CASTS == 8, tostring(CASTS))

	-- Walk forward a frame at a time and record which frame each one's SECOND cast
	-- lands on, then count how many casts the busiest frame carries.
	local per_frame, second_of = {}, {}
	for _ = 1, 40 do
		CLOCK = CLOCK + FRAME
		local n = 0
		for i = 1, 8 do
			local before = CASTS
			has_los(ids[i], objs[i], objs[i]:position(), CLOCK)
			if CASTS > before and not second_of[i] then
				second_of[i] = CLOCK; n = n + 1
			end
		end
		if n > 0 then per_frame[#per_frame + 1] = n end
	end
	local done, busiest = 0, 0
	for i = 1, 8 do if second_of[i] then done = done + 1 end end
	for _, n in ipairs(per_frame) do if n > busiest then busiest = n end end
	check("every one of the eight does cast again", done == 8, tostring(done))
	check("...but not all on the same frame -- the phase lock is broken",
	      busiest < 8 and #per_frame > 1,
	      string.format("%d distinct frames, busiest carried %d of 8", #per_frame, busiest))
	-- The weak form above passes at 7-and-1. Ask for a real spread: eight NPCs at
	-- los_rate 150 with 16 ms frames have ten frames to land in, and a working spread
	-- puts at most a couple in any one of them.
	check("...and the spread is even, not merely non-degenerate",
	      #per_frame >= 5 and busiest <= 3,
	      string.format("%d distinct frames, busiest carried %d of 8", #per_frame, busiest))
	-- Whatever the spread, the first cast is still on the arrival frame, so nobody's
	-- card waits for its LOS verdict.
	local earliest = nil
	for i = 1, 8 do
		if earliest == nil or second_of[i] < earliest then earliest = second_of[i] end
	end
	check("...and no second cast came before the first deadline could",
	      earliest > t0, string.format("%d vs t0 %d", earliest, t0))
	for i = 1, 8 do forget(ids[i]) end
end

-- ------------------------------------------- 1c. the cached verdict is unchanged
-- Between deadlines has_los must answer from f.los and touch nothing. Both polarities,
-- because the cached path reads `f.los ~= false` and a nil there once showed cards
-- through walls.
do
	local o, id = npc(6001), 6001
	CASTS, HITDIST = 0, 1000
	check("a clear cast reports visible", has_los(id, o, o:position(), CLOCK) == true)
	local after = CASTS
	for _ = 1, 5 do
		CLOCK = CLOCK + 1
		check("...and the frames inside the window answer from the cache",
		      has_los(id, o, o:position(), CLOCK) == true and CASTS == after,
		      string.format("%d casts, expected %d", CASTS, after))
	end
	-- Occluded, past the grace window: a real false, cached as a real false.
	CLOCK = CLOCK + C.los_grace + C.los_rate
	HITDIST = 2                                   -- a wall two metres out, NPC at ten
	check("an occluded cast past the grace window reports hidden",
	      has_los(id, o, o:position(), CLOCK) == false)
	local after2 = CASTS
	CLOCK = CLOCK + 1
	check("...and THAT is cached too, not re-read as visible",
	      has_los(id, o, o:position(), CLOCK) == false and CASTS == after2)
	forget(id)
end

-- -------------------------------------------------- 1d. the grace window survives
-- A brief occlusion (a passer-by, a doorframe) must not flick the card off: within
-- los_grace of the last clear sighting the NPC stays visible even though the cast said
-- otherwise, and the moment the window lapses it does not.
do
	local o, id = npc(6002), 6002
	CASTS, HITDIST = 0, 1000
	has_los(id, o, o:position(), CLOCK)           -- seen clear: stamps los_good_t
	HITDIST = 2
	CLOCK = CLOCK + C.los_rate + 1
	check("an occlusion inside the grace window keeps the card up",
	      has_los(id, o, o:position(), CLOCK) == true,
	      "los_grace is what stops a doorframe flickering the card")
	CLOCK = CLOCK + C.los_grace
	check("...and once the window lapses the card goes",
	      has_los(id, o, o:position(), CLOCK) == false)
	-- The stamp is only refreshed by a CLEAR cast, so the window cannot renew itself
	-- off an occluded one.
	CLOCK = CLOCK + C.los_rate
	check("...and stays gone while the wall is still there",
	      has_los(id, o, o:position(), CLOCK) == false)
	forget(id)
end

-- ---------------------------------------------- 1e. the shoulder pick, in the source
-- render's auto-shoulder re-pick is the second constant-increment deadline and locks
-- the same way (two world2ui per pick, sixteen of them on one frame instead of two).
-- Driving render needs the whole card dialog, so this one is read: what is asserted is
-- that the site seeds its first deadline off the shared spreader and advances every
-- later one by the plain rate.
do
	local src = slurp("gamedata/scripts/iqm_core.script")
	check("PHASE_MUL is declared once, for both deadlines",
	      src:find("\nlocal PHASE_MUL = %d+") ~= nil)
	local side = src:match("f%.side_sign = shoulder_sign.-\n%s*end\n")
	check("the shoulder pick's first deadline is spread by the id",
	      side and side:find("(id * PHASE_MUL) % SIDE_RATE", 1, true) ~= nil,
	      "a constant seed re-locks the group the moment they are all carded")
	check("...and every later one is the plain SIDE_RATE",
	      side and side:find("f.side_next = tg + SIDE_RATE", 1, true) ~= nil,
	      "spreading on every deadline would shorten the interval, not just its phase")
end

-- ==========================================================================
-- 1f. THE VISIBILITY GATE'S ENGINE SIDE
-- ==========================================================================
-- Everything from here down needs overlay_visible() to answer, because the frame loop
-- now consults it before it does any work. Stubbed at the ENGINE crossings rather than
-- at the three Lua primitives on purpose: what section 3 measures is how many times a
-- frame the mod goes over to the exe to ask, which is the whole point of memoising it,
-- and stubbing pda_is_open / hud_is_shown themselves would count the wrong thing.
--
--   * the PDA menu: ActorMenu.get_pda_menu is resolved as a global at call time, so
--     installing it on ENV is enough. IsShown is the per-frame crossing (a pcall and,
--     before the method was hoisted, a luabind __index as well) and so is counted.
--   * the HUD: hud_shown_fn and axr are file locals written by on_game_start, which
--     this harness never runs, so they are written straight into the shared upvalue.
--     main_hud_shown() is the expensive half in game -- _HUD_STATE, actor_menu.last_mode,
--     pda.dialog_closed, a next() over _GUIs and a console lookup -- so it is counted too.
--   * the reveal hotkey: an unbound key (-1) means "always shown", which takes that
--     clause out of the experiment. Its own modes are the reveal harness's subject.
local PDA_OPEN, HUD_SHOWN = false, true
local PDA_CALLS, HUD_CALLS = 0, 0
local overlay_visible = CORE.overlay_visible
local pda_is_open  = upget(overlay_visible, "pda_is_open")
local hud_is_shown = upget(overlay_visible, "hud_is_shown")
check("overlay_visible and its two engine-facing primitives are reachable",
      type(overlay_visible) == "function" and type(pda_is_open) == "function"
      and type(hud_is_shown) == "function",
      "the frame gate cannot be driven without them")

ENV.ActorMenu = {
	get_pda_menu = function()
		return { IsShown = function() PDA_CALLS = PDA_CALLS + 1; return PDA_OPEN end }
	end,
}
check("the HUD query can be counted",
      upset(hud_is_shown, "hud_shown_fn", function() HUD_CALLS = HUD_CALLS + 1; return HUD_SHOWN end))
check("the zoom flags can be stubbed", upset(hud_is_shown, "axr", {}))
C.reveal_key = -1
-- ...and the summon's four options (R2.58), stated rather than left nil. In game
-- read_config guarantees every key in DEFAULTS is non-nil and the file's readers rely on
-- that ("no reader anywhere writes C.<key> or <literal>"), so a harness that drives the
-- frame path owes it the same table -- route_wanted compares two of these against 0 and
-- would error on a nil rather than telling us anything. Mode 0 ("always") for the sections
-- below, which are about the LOS beat and the overlay gate and want the route's own gate
-- out of the experiment; section 4 sets its own.
C.route_reveal, C.route_key, C.route_mod, C.route_dwell = 0, -1, 0, 20
C.reveal_mod = 0

local OVIS = upget(overlay_visible, "OVIS")
check("the per-frame memo is a table we can inspect", type(OVIS) == "table")

do
	-- The accessor answers before anything else touches it, and the memo is keyed on the
	-- frame clock rather than latched: a new frame re-asks.
	PDA_CALLS, HUD_CALLS = 0, 0
	check("with the PDA shut and the HUD up the overlay is visible", overlay_visible() and true)
	local p, h = PDA_CALLS, HUD_CALLS
	check("...and asking cost one crossing of each", p == 1 and h == 1,
	      string.format("pda %d, hud %d", p, h))
	CLOCK = CLOCK + 16
	check("a new frame re-asks rather than serving a latched answer",
	      overlay_visible() and PDA_CALLS == 2, tostring(PDA_CALLS))
	-- ...and it answers the PDA truthfully in both directions, since section 3 hides by
	-- opening it.
	PDA_OPEN = true
	CLOCK = CLOCK + 16
	check("the open PDA hides the overlay", overlay_visible() == false)
	PDA_OPEN = false
	CLOCK = CLOCK + 16
	HUD_SHOWN = false
	check("a hidden HUD hides it too", (overlay_visible() or false) == false)
	HUD_SHOWN = true
	CLOCK = CLOCK + 16
	check("...and closing the PDA with the HUD back brings it back", overlay_visible() and true)
end

-- ==========================================================================
-- 2. THE MERGE DOES NOT RIDE THE PUBLISH FRAME
-- ==========================================================================
-- actor_on_update is driven for real. Its collaborators are replaced through the same
-- upvalues on_game_start writes, so what is measured is this function's scheduling and
-- nothing else: update() and render() become counters, the scanner becomes a switch.
do
	local UPDATES, RENDERS, PUBLISH = 0, 0, false
	check("ensure_cards can be stubbed",
	      upset(actor_on_update, "ensure_cards", function() return true end))
	check("update can be counted", upset(actor_on_update, "update", function() UPDATES = UPDATES + 1 end))
	check("render can be counted", upset(actor_on_update, "render", function() RENDERS = RENDERS + 1 end))
	local TICKS = 0
	check("the scanner tick can be driven",
	      upset(actor_on_update, "scan_tick", function() TICKS = TICKS + 1; return PUBLISH end))
	upset(actor_on_update, "tw_tick", nil)        -- the taskwork probe is another harness's subject
	C.enabled = true

	local SCAN_INTERVAL = upget(actor_on_update, "SCAN_INTERVAL")
	check("the scan interval is a file local we can read", type(SCAN_INTERVAL) == "number",
	      tostring(SCAN_INTERVAL))

	local FRAME = 16
	local function frame() actor_on_update(); CLOCK = CLOCK + FRAME end

	-- Settle: one merge happens (next_scan starts at 0), and then the throttle holds.
	upset(actor_on_update, "next_scan", 0)
	frame()
	check("the merge runs when it is due", UPDATES == 1, tostring(UPDATES))
	local quiet = UPDATES
	for _ = 1, 20 do frame() end
	check("...and not again inside the interval", UPDATES == quiet,
	      string.format("%d merges in 20 frames", UPDATES - quiet))
	check("...while render ran on every one of those frames", RENDERS == 21, tostring(RENDERS))

	-- THE PUBLISH. One frame with the scanner completing a pass. The merge must NOT be
	-- on it: that frame already carries the scanner's final slice, and stacking the two
	-- is the periodic hitch this exists to stop.
	PUBLISH = true
	local before = UPDATES
	frame()
	PUBLISH = false
	check("the merge does NOT run on the frame the scanner publishes", UPDATES == before,
	      "the pass's last slice and the full re-decorate on one frame is the hitch")
	frame()
	check("...it runs on the very next frame", UPDATES == before + 1,
	      string.format("%d, expected %d -- promptness is the other half of the fix",
	                    tostring(UPDATES), before + 1))
	local after = UPDATES
	for _ = 1, 5 do frame() end
	check("...and exactly once, not once per frame from then on", UPDATES == after,
	      string.format("%d extra merges", UPDATES - after))

	-- Two publishes on consecutive frames (both scanners finishing a frame apart) must
	-- not compound into a merge per frame either.
	before = UPDATES
	PUBLISH = true
	frame(); frame()
	PUBLISH = false
	frame(); frame()
	check("back-to-back publishes still merge at most once a frame, and settle",
	      UPDATES - before <= 2 and UPDATES > before,
	      string.format("%d merges over four frames", UPDATES - before))

	-- The periodic beat is untouched: with no publish at all the merge still comes
	-- round on the interval. A "fix" that simply never re-armed would pass everything
	-- above and fail here.
	before = UPDATES
	local frames = math.floor(SCAN_INTERVAL / FRAME) + 2
	for _ = 1, frames do frame() end
	check("the plain interval still fires with no publish at all", UPDATES == before + 1,
	      string.format("%d merges over %d ms", UPDATES - before, frames * FRAME))

	-- And the disabled case still short-circuits the scanner without stalling render.
	C.enabled = false
	quiet = RENDERS
	local ticks_before = TICKS
	PUBLISH = true
	frame()
	PUBLISH = false
	check("a disabled mod does not tick the scanner at all", TICKS == ticks_before,
	      string.format("%d scanner ticks with the mod off", TICKS - ticks_before))
	check("...but render is still called, so the teardown path runs", RENDERS == quiet + 1,
	      tostring(RENDERS - quiet))
	C.enabled = true
end

-- ==========================================================================
-- 3. NO WORK IS DONE WHILE THE OVERLAY IS HIDDEN
-- ==========================================================================
-- The third distribution bug, and the largest: render() has always hidden everything
-- while the fullscreen PDA is up, the HUD is away or the reveal key is not held -- but
-- it hid it LAST, after actor_on_update had already advanced both amortized scanners at
-- full budget and rebuilt and re-ranked the desired set. Every frame of a PDA session,
-- and for reveal_mode 3 most frames of the session, that work was done and discarded.
--
-- The fix is a pause and NOT a teardown, so what is asserted here is both halves: that
-- the work stops, and that nothing is thrown away while it is stopped. Those pull in
-- opposite directions and a change that satisfies only the first (clear_all() at the
-- gate) would be a regression -- a full rescan, a replayed entrance and a fresh chirp
-- on every release -- that the frame counters alone would applaud.
--
-- Driven against the REAL render, unlike section 2, because three of the five things
-- asserted are properties of the hidden path inside it: the combat-dim ease that has to
-- keep running above every early return, the per-NPC state it must not touch, and the
-- gate call it must take from the memo rather than pay for again.
do
	local UPDATES, RENDERS, TICKS, TW, RESETS = 0, 0, 0, 0, 0
	local HIDDEN_SLOTS, HIDDEN_BEACONS, HIDDEN_ROUTE = 0, 0, 0

	upset(actor_on_update, "ensure_cards", function() return true end)
	upset(actor_on_update, "update", function() UPDATES = UPDATES + 1 end)
	upset(actor_on_update, "scan_tick", function() TICKS = TICKS + 1; return false end)
	upset(actor_on_update, "scan_idle", function() return true end)
	upset(actor_on_update, "tw_tick", function() TW = TW + 1 end)
	-- A rescan is the cost the pause exists to avoid, so make one loud. Shared upvalue:
	-- writing it through on_option_change writes the cell every closure in the file sees.
	check("the rescan can be counted", upset(CORE.on_option_change, "scan_reset", function() RESETS = RESETS + 1 end))

	-- The real render, and the three collaborators its hidden path calls.
	-- The real render, behind a counter: "render still ran" and "render did the right
	-- thing while hidden" are both wanted, and a bare swap would only give the second.
	check("the real render can be put back",
	      upset(actor_on_update, "render", function(tg) RENDERS = RENDERS + 1; return render(tg) end))
	local CARDS = {
		hide_slot  = function() HIDDEN_SLOTS = HIDDEN_SLOTS + 1 end,
		hide_route = function() HIDDEN_ROUTE = HIDDEN_ROUTE + 1 end,
	}
	check("the card dialog can be stubbed", upset(render, "CARDS", CARDS))
	check("the beacon teardown can be counted",
	      upset(render, "hide_beacons", function() HIDDEN_BEACONS = HIDDEN_BEACONS + 1 end))
	-- Interference (R2.59). render eases it ahead of every early return, exactly as it eases
	-- the combat dim, so both of these have to be here or the frame path dies on a nil call.
	-- SILENCED rather than driven: this harness is about WHEN work happens, and interference
	-- neither schedules nor skips any -- it has its own harness. `af` at 1 keeps the alpha
	-- arithmetic at the two draw sites exactly what it was before the feature existed.
	check("the interference ease can be silenced", upset(render, "noise_tick", function() end))
	check("...and its published state stubbed", upset(render, "NZ", { af = 1 }))

	-- READ LIVE, never held. clear_all() does not empty these two tables, it REBINDS them
	-- (`tracked, FILT = {}, {}`), so a reference taken once here would go on describing the
	-- set as it was while the module served a fresh empty one -- and every "nothing was
	-- torn down" assertion below would pass against the exact teardown it exists to
	-- forbid. Fetching the upvalue each time is what makes them non-vacuous.
	local function TRACKED() return upget(render, "tracked") end
	local function FILTS()   return upget(render, "FILT") end
	local SUP = upget(render, "SUP")
	check("tracked, FILT and SUP are reachable",
	      type(TRACKED()) == "table" and type(FILTS()) == "table" and type(SUP) == "table")

	-- The placed waypoint is another harness's subject and its absence is what lets a
	-- VISIBLE frame here stop at render's "nothing to draw" skip instead of walking into
	-- the projection path. The tracked set is therefore filled in AFTER 3a, below.
	check("the waypoint poll can be silenced", upset(render, "waypoint_goal", function() return nil end))

	local A, B = 7001, 7002
	local tA, tB, fA, fB

	local FRAME = 16
	local function frame() actor_on_update(); CLOCK = CLOCK + FRAME end

	C.enabled = true
	upset(actor_on_update, "next_scan", CLOCK + 1000000)   -- park the merge; the hidden span must not need it

	-- --------------------------------------------------- 3a. one gate per frame
	-- The gate used to be evaluated twice on every frame the mod ran: once by render's
	-- inline three-call expression and once by iqm_nav's driver, which asks for the same
	-- answer a few microseconds later in the same frame. Now the frame loop asks first
	-- and both of the others take the memo. Counted at the engine crossings, so the
	-- assertion is about round-trips to the exe and not about Lua calls.
	PDA_OPEN = false
	PDA_CALLS, HUD_CALLS = 0, 0
	frame()
	-- ...and here is iqm_nav, asking the same question later in the same frame. Same
	-- clock deliberately: `frame` has already advanced it, so wind it back.
	CLOCK = CLOCK - FRAME
	local nav_answer = overlay_visible()
	CLOCK = CLOCK + FRAME
	check("a visible frame crosses to the engine for the gate exactly once",
	      PDA_CALLS == 1 and HUD_CALLS == 1,
	      string.format("pda %d, hud %d -- the frame loop, render and iqm_nav all ask", PDA_CALLS, HUD_CALLS))
	check("...and iqm_nav's later ask gets the same answer the frame did",
	      nav_answer == true, tostring(nav_answer))

	PDA_OPEN = true
	PDA_CALLS, HUD_CALLS = 0, 0
	frame()
	CLOCK = CLOCK - FRAME
	local nav_hidden = overlay_visible()
	CLOCK = CLOCK + FRAME
	check("a hidden frame crosses exactly once too", PDA_CALLS == 1,
	      string.format("pda %d", PDA_CALLS))
	check("...and the hidden answer is shared, not recomputed", nav_hidden == false)
	check("...and the HUD is not asked at all once the PDA has answered",
	      HUD_CALLS == 0, tostring(HUD_CALLS))
	-- The memo must not outlive its frame: a latch here would leave the cards hidden
	-- until something else happened to invalidate it.
	PDA_OPEN = false
	CLOCK = CLOCK + FRAME
	check("the next frame re-asks rather than serving the hidden answer", overlay_visible() == true)

	-- Two live cards, both already fully faded in and already chirped -- which is the
	-- state a player is in when they open the PDA, and the state that has to survive it.
	TRACKED()[A] = { slot = 1, role = "target", name = "Sidorovich" }
	TRACKED()[B] = { slot = 2, role = "trader", name = "Barman" }
	FILTS()[A] = { a = 255, seen = true, appear = 1, chirp_t = 0 }
	FILTS()[B] = { a = 255, seen = true, appear = 1 }
	tA, tB, fA, fB = TRACKED()[A], TRACKED()[B], FILTS()[A], FILTS()[B]

	-- ------------------------------------------- 3b/3c. the hidden span does nothing,
	--                                              and throws nothing away
	-- Four seconds of PDA, which is several scan intervals: long enough that a merge
	-- would certainly have come round and a scan pass certainly have completed.
	PDA_OPEN = true
	CLOCK = CLOCK + FRAME                      -- 3a's last ask was AT this clock; the memo is per frame
	upset(actor_on_update, "next_scan", 0)     -- overdue on the very first hidden frame
	local u0, t0, w0, r0 = UPDATES, TICKS, TW, RENDERS
	local chirp_before = upget(render, "_chirp_last")
	HIDDEN_SLOTS, HIDDEN_BEACONS, HIDDEN_ROUTE = 0, 0, 0
	for _ = 1, 250 do frame() end
	check("no scan slice runs while the overlay is hidden", TICKS == t0,
	      string.format("%d slices over 250 hidden frames", TICKS - t0))
	check("no merge runs either, however overdue it is", UPDATES == u0,
	      string.format("%d merges over 250 hidden frames -- next_scan was left at 0", UPDATES - u0))
	check("...nor the taskwork probe, which would otherwise see every frame as idle",
	      TW == w0, string.format("%d probes", TW - w0))
	check("but render is still reached on every hidden frame", RENDERS == r0 + 250,
	      string.format("%d renders", RENDERS - r0))
	check("...and it hid the cards, the beacons and the route",
	      HIDDEN_SLOTS == 500 and HIDDEN_BEACONS == 250 and HIDDEN_ROUTE == 250,
	      string.format("%d slots, %d beacons, %d routes", HIDDEN_SLOTS, HIDDEN_BEACONS, HIDDEN_ROUTE))

	check("the tracked set is NOT cleared -- both entries survive, as the same tables",
	      TRACKED()[A] == tA and TRACKED()[B] == tB,
	      "clear_all() at the gate would make the saving free and the rescan visible")
	check("...and nothing was rescanned", RESETS == 0, tostring(RESETS))
	check("...and the smoothing state survives with it, so the entrance does not replay",
	      FILTS()[A] == fA and FILTS()[B] == fB and fA.appear == 1 and fB.appear == 1
	      and fA.a == 255 and fB.a == 255,
	      "f.appear reset to 0 is the entrance rise playing again on release")
	check("...and both cards are still marked SEEN, so neither re-chirps",
	      fA.seen == true and fB.seen == true)
	check("...and the global chirp throttle was not disturbed",
	      upget(render, "_chirp_last") == chirp_before)

	-- ------------------------------------------------- 3d. the combat dim keeps easing
	-- SUP.f and SUP.t live above every early return in render for exactly this case: a
	-- dim frozen at whatever it was when the PDA opened would restore the cards at that
	-- opacity and then ease from it, and a SUP.t minutes stale would ease from a dt
	-- measured in minutes on the first frame back.
	SUP.ms, SUP.lvl, SUP.f, SUP.ads = 4000, 0.35, 1, false
	SUP.till = CLOCK + 1000000                 -- in combat for the whole span
	SUP.t    = CLOCK
	local before_f = SUP.f
	for _ = 1, 30 do frame() end
	check("the combat dim still eases on hidden frames", SUP.f < before_f - 0.5,
	      string.format("f went %s -> %s over 30 hidden frames", tostring(before_f), tostring(SUP.f)))
	check("...and settles at the configured floor rather than drifting past it",
	      SUP.f > SUP.lvl - 0.01 and SUP.f < SUP.lvl + 0.05, tostring(SUP.f))
	check("...and SUP.t is stamped on every hidden frame, not left minutes stale",
	      SUP.t == CLOCK - FRAME, string.format("t %s, last frame %s", tostring(SUP.t), tostring(CLOCK - FRAME)))
	SUP.ms = 0

	-- ------------------------------------------ 3e. the first visible frame comes back
	-- Back to the counting render: what matters on this frame is the scheduling, and the
	-- draw path proper wants a device, a projection and a card dialog that draws.
	upset(actor_on_update, "render", function() RENDERS = RENDERS + 1 end)
	PDA_OPEN = false
	local u1, t1 = UPDATES, TICKS
	frame()
	check("the overdue merge runs on the very first visible frame", UPDATES == u1 + 1,
	      string.format("%d", UPDATES - u1))
	check("...and the scanner picks up on it too", TICKS == t1 + 1, tostring(TICKS - t1))
	check("...on the identical card set -- restored, not rebuilt",
	      TRACKED()[A] == tA and TRACKED()[B] == tB and FILTS()[A] == fA and FILTS()[B] == fB
	      and fA.seen == true and fA.appear == 1,
	      "a set that had to be rescanned would arrive empty on this frame")
	check("...and still with no rescan of any kind", RESETS == 0, tostring(RESETS))
	-- ...and having caught up, the merge goes back to its interval rather than running
	-- every frame from a next_scan left in the past.
	local u2 = UPDATES
	for _ = 1, 20 do frame() end
	check("...then the merge returns to its normal beat", UPDATES == u2,
	      string.format("%d merges in the 20 frames after the release", UPDATES - u2))

	TRACKED()[A], TRACKED()[B], FILTS()[A], FILTS()[B] = nil, nil, nil, nil
end

-- ==========================================================================
-- 4. THE SUMMON ENVELOPE (R2.58)
-- ==========================================================================
-- The ground route is drawn only in the seconds after the player asks for it, and this is
-- where that is asserted, because none of it can be seen from anywhere else: the gesture is
-- POLLED (so there is no callback a test could fire), the fade is a per-frame ease inside
-- render (so a static read of the state says nothing), and the fallbacks are a truth table
-- over two keys that either of two nil-tolerant reads would quietly flatten.
--
-- Three things here would revert silently without a test, and all three are the kind that
-- look right in the diff:
--
--   1. THE NEVER-STRAND RULE. An unbound key means "always drawn" -- and route_key's -1
--      means "borrow the nameplate key" while reveal_key's -1 means "always". Two
--      different meanings for the same sentinel, one line apart. Get it wrong and a
--      default install shows no route at all and offers no gesture that brings one back.
--   2. THE INDEPENDENCE. In Summoned mode the route must NOT consult the nameplates' own
--      reveal state -- being able to keep the nameplates up and pulse the route on its own
--      is the reason the mode has its own key. A `reveal_visible() and ...` slipped into
--      route_wanted would satisfy every other test in this file.
--   3. THE LANDING. The envelope has to REACH 0 and 1 rather than approach them: 0 is what
--      lets iqm_nav throttle its tick and render skip the draw entirely, so an asymptote
--      would leave both doing full work for ever, for a line at alpha 0.003.
local route_wanted   = upget(render, "route_wanted")
local reveal_visible = upget(route_wanted, "reveal_visible")
local key_is_down    = upget(route_wanted, "key_is_down")
local SMN            = upget(render, "SMN")
check("route_wanted, the envelope and the key poll are all reachable",
      type(route_wanted) == "function" and type(key_is_down) == "function"
      and type(reveal_visible) == "function" and type(SMN) == "table",
      "the summon cannot be driven without them")

-- THE PHYSICAL KEYBOARD, one entry per DIK. Two keys, because the configuration the
-- feature exists for needs them in opposite states at the same instant: the nameplate key
-- UP (so the cards are hidden) while the route's own key is DOWN.
local DOWN = {}
local KEY_POLLS = 0
local REVEAL_DIK, ROUTE_DIK = 30, 40
check("the key poll can be stubbed",
      upset(key_is_down, "key_state_fn", function(k)
	      KEY_POLLS = KEY_POLLS + 1
	      return DOWN[k] and 1 or 0
      end))
-- Old-MCM path deliberately: get_mod_key is MCM's business and not this file's, and with
-- no keybind support there is no modifier to honour, so the key alone decides.
check("the modifier path can be taken out", upset(key_is_down, "mcm_keybinds", false))
-- route_wanted holds its OWN reference to key_state_fn, for its "no engine poll at all"
-- guard; the same cell has to be live there or the guard answers first and nothing below
-- ever reaches the poll.
check("...on route_wanted's side of the guard too",
      upset(route_wanted, "key_state_fn", upget(key_is_down, "key_state_fn")))

-- Every case starts from a clean envelope: route_wanted STAMPS the dwell on the release
-- edge, so a leftover `down` from the previous case would hand the next one a two-second
-- grace it never asked for.
local function fresh()
	SMN.down, SMN.till, SMN.a = false, 0, 0
	DOWN[REVEAL_DIK], DOWN[ROUTE_DIK] = false, false
end

do  -- ------------------------------------------------- 4a. the three modes' truth table
	C.reveal_key, C.reveal_mode = REVEAL_DIK, 3   -- hold-to-show, so the cards follow the key
	C.route_key = ROUTE_DIK

	fresh(); C.route_reveal = 0
	check("mode 'always': the route is wanted with no key held", route_wanted(CLOCK) == true)

	fresh(); C.route_reveal = 1
	check("mode 'follow the nameplates': hidden cards mean no route",
	      route_wanted(CLOCK) == false)
	DOWN[REVEAL_DIK] = true
	check("...and the route comes up with them", route_wanted(CLOCK) == true)

	fresh(); C.route_reveal = 2
	check("mode 'summoned': nothing held, nothing drawn", route_wanted(CLOCK) == false)
	DOWN[REVEAL_DIK] = true
	check("...and the NAMEPLATE key does not summon it once the route has its own",
	      route_wanted(CLOCK) == false,
	      "the fallback must apply only while route_key is unbound")
	fresh()
	DOWN[ROUTE_DIK] = true
	check("...while its own key does", route_wanted(CLOCK) == true)
end

do  -- ------------------------------------------------- 4b. the never-strand rule
	fresh(); C.route_reveal = 2
	C.route_key, C.reveal_key = -1, -1
	check("summoned with no key bound anywhere draws the route always",
	      route_wanted(CLOCK) == true,
	      "a half-configured menu must not be able to leave a player with no route")

	fresh()
	C.route_key, C.reveal_key, C.reveal_mode = -1, REVEAL_DIK, 3
	check("...and an unbound route key borrows the nameplate key rather than meaning 'off'",
	      route_wanted(CLOCK) == false)
	DOWN[REVEAL_DIK] = true
	check("...which then summons it", route_wanted(CLOCK) == true)

	-- The guard for an engine with no key_state binding at all: hiding a route with no way
	-- to ask for one back is the one outcome worse than always showing it.
	fresh()
	C.route_key = ROUTE_DIK
	local poll = upget(route_wanted, "key_state_fn")
	upset(route_wanted, "key_state_fn", nil)
	check("with no key_state binding the route is drawn rather than hidden",
	      route_wanted(CLOCK) == true)
	upset(route_wanted, "key_state_fn", poll)
end

do  -- ------------------------------------------------- 4c. independence from the cards
	fresh(); C.route_reveal = 2
	C.route_key, C.reveal_key, C.reveal_mode = ROUTE_DIK, REVEAL_DIK, 0   -- press-to-toggle
	check("the nameplates can be toggled off", upset(reveal_visible, "reveal_on", false)
	      and reveal_visible() == false)
	DOWN[ROUTE_DIK] = true
	check("a summoned route ignores the nameplates being toggled off",
	      route_wanted(CLOCK) == true,
	      "this is the whole reason the summon has a key of its own")
	check("...and did not ask the nameplates' reveal rule at all",
	      reveal_visible() == false, "sanity: the toggle is still off")
	upset(reveal_visible, "reveal_on", true)
end

do  -- ------------------------------------------------- 4d. the dwell, the fade, the draw
	-- THE REAL render, driven frame by frame, because the ease lives inside it and the
	-- route-only branch it feeds is the code path this whole feature turns on: nameplates
	-- hidden by their own hotkey, ground line up because it was asked for.
	local DRAWN, LAST_AM, HIDDEN_ROUTE = 0, nil, 0
	local CARDS = {
		hide_slot  = function() end,
		hide_route = function() HIDDEN_ROUTE = HIDDEN_ROUTE + 1 end,
		draw_route = function(_, _, _, _, am) DRAWN = DRAWN + 1; LAST_AM = am end,
	}
	check("the card dialog can be stubbed for the route path", upset(render, "CARDS", CARDS))
	check("the beacon teardown can be silenced", upset(render, "hide_beacons", function() end))
	check("the waypoint poll can be silenced", upset(render, "waypoint_goal", function() return nil end))
	check("the aspect poke can be silenced", upset(render, "cards_kx_tick", function() end))
	-- The projection probe is set by read_config, which this harness never runs. Without it
	-- route_alpha answers 0 for the honest reason (the ground line cannot project at all)
	-- and every assertion below would pass vacuously.
	check("the projection probe can be set", upset(CORE.route_alpha, "w2u_ok", true))
	C.mark_route, C.route_dist = true, 50
	-- iqm_nav resolves as a global at call time, so a stub on ENV is the module.
	local RD = { n = 4, nc = 2 }
	ENV.iqm_nav = { route_draw = function() return RD end, route_limit = function() return 4, 2 end }

	C.route_reveal, C.route_key = 2, ROUTE_DIK
	C.reveal_key, C.reveal_mode = REVEAL_DIK, 3     -- cards follow their key; it stays up
	PDA_OPEN, HUD_SHOWN = false, true
	fresh()
	SMN.dwell = 300                                 -- shorter than the shipped 2 s, same code
	SMN.t = CLOCK

	local FRAME = 16
	local function frame() CLOCK = CLOCK + FRAME; render(CLOCK) end

	-- Nothing held: the nameplates are down (their key is up) and so is the route.
	frame()
	check("with neither key held nothing is drawn", DRAWN == 0 and HIDDEN_ROUTE > 0,
	      string.format("%d draws", DRAWN))
	check("...and the envelope is landed on exactly 0", SMN.a == 0, tostring(SMN.a))

	-- The summon, with the nameplates still hidden by their own hotkey.
	DOWN[ROUTE_DIK] = true
	frame()
	check("summoning draws the route while the nameplates stay hidden", DRAWN == 1,
	      string.format("%d draws", DRAWN))
	check("...fading in rather than appearing at full strength",
	      LAST_AM and LAST_AM > 0 and LAST_AM < 1, tostring(LAST_AM))
	local first = LAST_AM
	frame()
	check("...and rising frame on frame", LAST_AM > first, string.format("%s -> %s", tostring(first), tostring(LAST_AM)))

	for _ = 1, 40 do frame() end
	check("...landing on exactly 1, not approaching it", SMN.a == 1 and LAST_AM == 1,
	      tostring(SMN.a))

	-- The release. A TAP is the same code as a hold -- the edge is found by comparing two
	-- polls -- so the dwell is what makes the gesture usable at all.
	DOWN[ROUTE_DIK] = false
	frame()
	check("letting go does not drop the route", LAST_AM == 1, tostring(LAST_AM))
	-- Stops one frame SHORT of the deadline on purpose: `frame` advances the clock before it
	-- renders, so a loop that ran while CLOCK < till would render the first frame PAST it
	-- and measure the start of the fade as a failure to hold.
	local held = 0
	while CLOCK + FRAME < SMN.till do frame(); held = held + 1 end
	check("...it holds at full for the dwell", LAST_AM == 1 and held > 10,
	      string.format("%d frames at %s", held, tostring(LAST_AM)))

	frame(); frame()
	check("...then fades rather than switching off", LAST_AM < 1 and LAST_AM > 0,
	      tostring(LAST_AM))
	local drew = DRAWN
	local guard = 0
	while SMN.a > 0 and guard < 400 do frame(); guard = guard + 1 end
	check("...and reaches exactly 0", SMN.a == 0, tostring(SMN.a))
	check("...having kept drawing the whole way down", DRAWN > drew + 10,
	      string.format("%d frames of fade drawn", DRAWN - drew))
	local hid = HIDDEN_ROUTE
	frame()
	check("...after which the draw is skipped and the route hidden",
	      HIDDEN_ROUTE == hid + 1, tostring(HIDDEN_ROUTE - hid))

	-- ...and the way back is instant: the whole point of blanking rather than dropping.
	local before = DRAWN
	DOWN[ROUTE_DIK] = true
	frame()
	check("re-summoning draws on the very next frame", DRAWN == before + 1,
	      "the route is blanked, never dropped -- coming back must cost no search")

	-- The cheap-frame claim the perf story rests on: an unsummoned frame costs ONE poll of
	-- the route's key and nothing else of ours.
	--
	-- Counted PER KEY, and that is not pedantry. This fixture has reveal_mode 3, so the
	-- nameplates poll their own key on the same frame -- a total across both would read 2
	-- and say nothing about which feature spent it, and would go on reading 2 if the summon
	-- started polling twice while the cards stopped.
	local BY_KEY = {}
	upset(key_is_down, "key_state_fn", function(k)
		BY_KEY[k] = (BY_KEY[k] or 0) + 1
		return DOWN[k] and 1 or 0
	end)
	upset(route_wanted, "key_state_fn", upget(key_is_down, "key_state_fn"))
	DOWN[ROUTE_DIK] = false
	for _ = 1, 60 do frame() end
	BY_KEY[ROUTE_DIK], BY_KEY[REVEAL_DIK] = 0, 0
	frame()
	check("an idle frame polls the summon key exactly once",
	      BY_KEY[ROUTE_DIK] == 1, tostring(BY_KEY[ROUTE_DIK]))
	check("...and the nameplates' own hold poll is still the only other one",
	      BY_KEY[REVEAL_DIK] == 1, tostring(BY_KEY[REVEAL_DIK]))

	ENV.iqm_nav = nil
	C.mark_route = false
end

-- ------------------------------------------------------------------ verdict
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
