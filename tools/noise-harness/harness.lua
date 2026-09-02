-- Harness: interference -- the envelope, and the geometry the tear is built from.
--
-- WHY THIS EXISTS. Nothing else in the mod can see any of it. The compile gate sees valid
-- Lua whatever the numbers say; no other harness reads iqm_noise at all; and in game the
-- feature only runs during an emission or inside a psi zone, so a regression here would
-- next be noticed by a player standing in a psi field twenty minutes into a session --
-- which is also the worst possible place to be told that a range readout is lying.
--
-- Seven properties, in the order they would go wrong (6 and 7 arrived with the bugs and the
-- features that prompted them; see their own banners below):
--
--   1. THE SURGE CURVE reads the game's own clock. surge_level lerps between knots taken
--      from surge_manager's stage list, and the two ends have to be pinned: before the
--      first knot and past the last are both reachable (an emission's clock starts at 0
--      and ends at surge_time) and an off-by-one at either end is a divide by zero or an
--      index past the table.
--
--   2. THE GATE ON .state. _EVENT.surge.time is only WRITTEN while an emission runs, so it
--      keeps the last emission's final second for the hours between them. An ungated read
--      pins the overlay at full pressure for ever, from a missing `and`, and it is the
--      single most likely way this file breaks.
--
--   3. MAX, NOT SUM. Two mild sources must not add up to a severe reading.
--
--   4. THE BAND INDEX STAYS IN THE TABLE for every y a widget can be placed at -- which
--      includes NEGATIVE y, because a marker clamped to the top edge and a route mark
--      behind the camera both project off-screen. An index of 0 or nil there multiplies
--      nil by a number on the draw path: not a misdrawn card, every widget in the mod
--      gone on the same frame.
--
--   5. ce RETURNS TO ZERO on the way down. It is a monotonic counter that only advances
--      while the corruption tier holds; left alone it keeps its last value, and because a
--      stuck ce is a STABLE cache key the range readout would go on lying the same way
--      permanently. A wrong number that never corrects itself is the one failure this
--      feature must not have.
--
-- Usage:
--   python check_lua.py --run tools/noise-harness/harness.lua
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
local ENV = {}
ENV.pairs, ENV.ipairs, ENV.tostring, ENV.tonumber = pairs, ipairs, tostring, tonumber
ENV.type, ENV.string, ENV.table, ENV.math, ENV.os = type, string, table, math, os
ENV.setmetatable, ENV.print, ENV.pcall, ENV.select = setmetatable, print, pcall, select
ENV.error, ENV.assert, ENV.unpack, ENV.next = error, assert, unpack, next
ENV._G = ENV
ENV.printf = function() end
ENV.RegisterScriptCallback = function() end

-- THE CLOCK. time_global is bound as a file local at parse time, so the closure has to be
-- in place before the chunk runs -- the same arrangement beat-harness and reach-harness use.
local CLOCK = 10000
ENV.time_global = function() return CLOCK end

-- The event bus, as _g.script publishes it: a plain global table. Writing straight into it
-- is exactly what surge_manager and psi_storm_manager do through SetEvent.
ENV._EVENT = {}

-- Positions, for the vortex distance. Only distance_to is reached.
local VecMT = {}
VecMT.__index = VecMT
function VecMT:distance_to(o)
	local dx, dy, dz = self.x - o.x, self.y - o.y, self.z - o.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end
local function vec(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, VecMT) end
local ACTOR_POS = vec(0, 0, 0)
ENV.db = { actor = { position = function() return ACTOR_POS end } }

-- The three optional signal sources, each switchable to absent so the soft-dependency
-- paths are exercised rather than assumed.
local COVER = false
ENV.surge_manager = {
	get_surge_manager = function()
		return { pos_in_cover = function() return COVER end }
	end,
}
ENV.sr_psy_antenna = { psy_antenna = false }
ENV.grok_psy_fields_in_the_north = { psy_damage = 0 }
ENV.iqm_util = { dbg_out = function() end }

-- The config this file pulls. iqm_core is NOT loaded -- iqm_noise reads exactly three keys
-- off it, and a stub keeps the harness measuring one file.
local CFG = { debug_log = false, noise = true, noise_amt = 100, noise_giveup = false }
ENV.iqm_core = { config = function() return CFG end }

local NOISE = setmetatable({}, { __index = ENV })
do
	local chunk, err = loadstring(slurp("gamedata/scripts/iqm_noise.script"), "@iqm_noise.script")
	assert(chunk, err)
	setfenv(chunk, NOISE)
	local ok, perr = pcall(chunk)
	assert(ok, "iqm_noise failed to parse: " .. tostring(perr))
end
NOISE.on_game_start()
NOISE.apply_config()

-- ---------------------------------------------------- reaching the file locals
local function upget(fn, name)
	for i = 1, 90 do
		local n, v = debug.getupvalue(fn, i)
		if not n then return nil end
		if n == name then return v, i end
	end
end

-- A local is an upvalue only of the functions that actually MENTION it, so this is a
-- climb and not a flat lookup: tick calls poll, poll calls surge_level, and only
-- surge_level names the knot table. Reading them off tick directly answers nil.
local N        = NOISE.state()
local poll     = upget(NOISE.tick, "poll")
local surge_lv = poll and upget(poll, "surge_level")
local SURGE    = surge_lv and upget(surge_lv, "SURGE")
local T_TEAR   = upget(NOISE.tick, "T_TEAR")
local T_CHROMA = upget(NOISE.tick, "T_CHROMA")
local T_GIVE   = upget(NOISE.tick, "T_GIVE")
check("state(), surge_level and the tier constants are reachable",
      type(N) == "table" and type(surge_lv) == "function" and type(SURGE) == "table"
      and T_TEAR and T_CHROMA and T_GIVE,
      "without them this harness can only grep, not drive")
-- Hard stop rather than a cascade of confusing failures: every section below indexes at
-- least one of these, and a nil here means the file was restructured, not that a number
-- drifted.
assert(type(N) == "table" and type(surge_lv) == "function" and type(SURGE) == "table"
       and T_TEAR and T_CHROMA and T_GIVE,
       "iqm_noise's internals moved -- fix the upvalue climb above before reading further")
check("state() returns the SAME table every call -- iqm_cards binds it once and keeps it",
      NOISE.state() == N)

-- Drive `ms` milliseconds of frames at 60 fps, so the ease is exercised the way it runs
-- rather than in one jump. The poll is on its own 250 ms clock inside tick.
local function run(ms)
	local step = 16
	for _ = 1, math.floor(ms / step) do
		CLOCK = CLOCK + step
		NOISE.tick(CLOCK)
	end
end

local function rest()
	-- Back to a quiet world, then long enough for the release curve to land on the floor.
	ENV._EVENT.surge, ENV._EVENT.psi_storm = nil, nil
	ENV.sr_psy_antenna.psy_antenna = false
	ENV.grok_psy_fields_in_the_north.psy_damage = 0
	COVER = false
	N.spike = 0
	run(8000)
end

-- ==========================================================================
-- 1. The surge curve
-- ==========================================================================
local n = #SURGE
check("surge_level clamps below the first knot", surge_lv(-50) == SURGE[1][2])
check("surge_level clamps past the last knot", surge_lv(9999) == SURGE[n][2])
check("surge_level lands exactly on a knot", surge_lv(SURGE[1][1]) == SURGE[1][2])
check("surge_level is nil-safe (a .time that was never written)", surge_lv(nil) == 0)
do
	-- Between two knots it must interpolate, not step: a stepped curve is what the 1 Hz
	-- clock would give on its own, and the whole point of the knots is a continuous ramp
	-- underneath it.
	local a, b = SURGE[2], SURGE[3]
	local mid = surge_lv((a[1] + b[1]) / 2)
	check("surge_level interpolates between knots",
	      mid > a[2] and mid < b[2],
	      string.format("mid=%.3f not strictly between %.3f and %.3f", mid, a[2], b[2]))
end
do
	-- Monotonic up to the peak and back down after it, sampled every second across the
	-- whole emission. Not a style check: a knot list entered out of order lerps backwards
	-- and the overlay would calm down at the impact.
	local worst, at = -1, nil
	for t = 0, SURGE[n][1] do
		local v = surge_lv(t)
		if v > worst then worst, at = v, t end
	end
	check("the curve peaks at the waves, not at the start or the end",
	      at > 100 and at < 200, "peak at t=" .. tostring(at))
end

-- ==========================================================================
-- 2. The gate on .state
-- ==========================================================================
rest()
check("a quiet world publishes nothing", N.p < 0.01 and N.amp == 0 and N.af == 1,
      string.format("p=%.3f amp=%.2f af=%.2f", N.p, N.amp, N.af))

-- An emission that has ENDED, with its clock left at the value surge_manager stopped
-- writing. This is the exact state the bus sits in between emissions.
ENV._EVENT.surge = { state = false, time = 168 }
run(4000)
check("a FINISHED emission leaves its stale .time alone", N.p < 0.01,
      string.format("p=%.3f -- the .state gate is missing or inverted", N.p))

ENV._EVENT.surge.state = true
run(4000)
check("a running emission at its peak drives pressure high", N.p > 0.9,
      string.format("p=%.3f", N.p))
check("...which is past the give-up tier", N.p >= T_GIVE)
check("...and with noise_giveup off it FLOORS rather than hides", N.af > 0 and N.af < 1,
      string.format("af=%.3f -- 0 would be a hide, which is not the default", N.af))

-- Cover has to damp it, and damp it without switching it off: being underground during an
-- emission is not the same as the emission not happening.
-- COVER DAMPS, AND MUST NOT SUPPRESS. The bound here is deliberately tight and the reason is
-- a design correction from play (R2.59b): outside during an emission you die, so sheltering
-- is not a choice and the sheltered case IS the emission case. At the original 0.3 damping a
-- whole emission spent correctly indoors never crossed T_CHROMA -- a one-pixel wobble and
-- nothing else, at the one event the feature exists for. So assert that a sheltered PEAK
-- still reaches the corruption tiers, which is the property that was wrong.
-- rest() clears COVER along with everything else, so it goes FIRST -- setting the flag before
-- the reset is a test that silently measures the uncovered case.
rest()
COVER = true
ENV._EVENT.surge = { state = true, time = 168 }      -- the waves: uncovered pressure 1.0
run(6000)
check("a sheltered emission peak still reaches the chroma tier", N.p >= T_CHROMA,
      string.format("p=%.3f -- cover is suppressing the feature, not damping it", N.p))
check("...and is still damped below the uncovered peak", N.p < 1.0,
      string.format("p=%.3f -- shelter should mean something", N.p))
check("...and the give-up tier stays OUT of reach when sheltered", N.p < T_GIVE,
      string.format("p=%.3f -- being safe should not blank the overlay", N.p))
COVER = false
run(6000)
check("stepping out of cover raises it to the full peak", N.p > 0.95,
      string.format("p=%.3f", N.p))

-- ==========================================================================
-- 3. Max, not sum
-- ==========================================================================
rest()
ENV.grok_psy_fields_in_the_north.psy_damage = 1
ENV.sr_psy_antenna.psy_antenna = { sound_intensity_base = 0.3, hit_intensity = 0 }
run(4000)
local both = N.p
rest()
ENV.sr_psy_antenna.psy_antenna = { sound_intensity_base = 0.3, hit_intensity = 0 }
run(4000)
local one = N.p
check("two mild sources do not add up to more than the worst of them",
      math.abs(both - one) < 0.02,
      string.format("both=%.3f alone=%.3f -- this is a sum, not a max", both, one))

-- The antenna's own reading is clamped: the base accumulates across overlapping zones and
-- three strong zones would otherwise hand over a target above 1.
rest()
ENV.sr_psy_antenna.psy_antenna = { sound_intensity_base = 4.5, hit_intensity = 0 }
run(6000)
check("an accumulated antenna intensity is clamped to 1", N.p <= 1.0001,
      string.format("p=%.3f", N.p))

-- A telepathic hit is a spike that the release curve carries down, not a state.
rest()
NOISE.on_hit({ type = 4 })
run(300)
local spiked = N.p
run(4000)
check("a telepathic hit spikes the envelope", spiked > T_TEAR,
      string.format("p=%.3f right after the hit", spiked))
check("...and then decays on its own", N.p < spiked * 0.5,
      string.format("%.3f -> %.3f", spiked, N.p))
rest()
NOISE.on_hit({ type = 6 })   -- fire_wound: the environment/combat hits must be ignored
run(300)
check("a non-telepathic hit is ignored", N.p < 0.01,
      string.format("p=%.3f -- the type filter is missing", N.p))

-- ==========================================================================
-- 4. The band index
-- ==========================================================================
-- The index iqm_cards builds, restated here from the published geometry. If this walks off
-- the end of N.B the draw path multiplies nil by a number.
local NB, INV_BH = NOISE.band_geom()
check("band_geom publishes a usable count and reciprocal",
      NB and NB >= 1 and INV_BH and INV_BH > 0)
do
	-- Get the bands populated first: at rest they are all zero and an out-of-range index
	-- would read nil without anything noticing.
	rest()
	ENV._EVENT.surge = { state = true, time = 168 }
	run(4000)
	local bad = nil
	-- Every y a widget can be handed: well above the 768-unit screen, well below zero
	-- (clamped markers and points behind the camera both project off-screen), and the
	-- fractional values the projection actually produces.
	for y = -4000, 4000, 0.5 do
		local i = math.floor(y * INV_BH) % NB + 1
		if type(N.B[i]) ~= "number" then bad = y; break end
		if i < 1 or i > NB then bad = y; break end
	end
	check("the band index stays inside N.B for every y, negative included",
	      bad == nil, "first bad y = " .. tostring(bad))
	local nz = 0
	for i = 1, NB do if N.B[i] ~= 0 then nz = nz + 1 end end
	check("under pressure the bands are actually displaced", nz > 0)
end

-- ==========================================================================
-- 5. ce returns to zero
-- ==========================================================================
rest()
ENV._EVENT.surge = { state = true, time = 168 }
run(4000)
check("the corruption epoch advances while the tier holds", N.ce > 0,
      "the readout would never corrupt")
check("...and pressure really is in that tier", N.p >= T_CHROMA)
rest()
check("the corruption epoch RETURNS TO ZERO once it is clear", N.ce == 0,
      "ce=" .. tostring(N.ce) .. " -- a stuck ce is a range readout that lies for ever")

-- ...and the same on the option being switched off mid-effect, which is a different path
-- (apply_config, not tick).
ENV._EVENT.surge = { state = true, time = 168 }
run(4000)
check("switching the feature off mid-effect...", N.amp > 0)
CFG.noise = false
NOISE.apply_config()
check("...puts the published state back to rest immediately",
      N.amp == 0 and N.fr == 0 and N.af == 1 and N.ce == 0 and N.p == 0,
      "a stale amp leaves the last frame's tear frozen on screen")
NOISE.tick(CLOCK + 16)
check("...and tick does nothing while it is off", N.amp == 0 and N.p == 0)
CFG.noise = true
NOISE.apply_config()

-- ==========================================================================
-- 6. noise_amt scales WHAT IS DRAWN, never the pressure
-- ==========================================================================
-- The bug this replaces (R2.59a, found in game): tick eased toward `N.tgt * N.amt`, so the
-- slider scaled the pressure -- and every tier threshold is a comparison against pressure.
-- The check that used to sit here asserted only that amt 10 and amt 200 gave DIFFERENT p,
-- which the bug satisfies perfectly. It endorsed the defect instead of catching it, which is
-- the failure mode a harness has: a test can be green and be measuring the wrong axis.
--
-- So assert the axis. p is a measurement of the world and must not move with the setting;
-- amp and af are what the setting is for.
local function peak_emission()
	rest()
	ENV._EVENT.surge = { state = true, time = 168 }   -- the waves: true pressure 1.0
	run(5000)
end

CFG.noise_amt = 100
NOISE.apply_config()
peak_emission()
local p100, amp100, af100 = N.p, N.amp, N.af

CFG.noise_amt = 10
NOISE.apply_config()
peak_emission()
local p10, amp10 = N.p, N.amp
check("the pressure is IDENTICAL at amt 10 and amt 100", math.abs(p10 - p100) < 1e-9,
      string.format("%.4f vs %.4f -- noise_amt is in the envelope again", p10, p100))
check("...and at amt 10 the tear is still nonzero", amp10 > 0,
      "the bottom of the slider is dead, which is the R2.59a bug exactly")
check("...but much smaller than at 100", amp10 < amp100 * 0.2,
      string.format("amp %.3f vs %.3f", amp10, amp100))
check("...and the alpha barely dips", N.af > 0.85,
      string.format("af=%.3f -- a 10%% player should not blink fully out", N.af))

CFG.noise_amt = 200
NOISE.apply_config()
peak_emission()
check("the pressure is IDENTICAL at amt 200", math.abs(N.p - p100) < 1e-9,
      string.format("%.4f vs %.4f", N.p, p100))
check("...the tear is bigger", N.amp > amp100)
check("...and af is clamped at the floor rather than driven negative", N.af >= 0,
      string.format("af=%.3f -- a negative alpha reaches GetARGB", N.af))
check("...which is the same floor amt 100 gives", math.abs(N.af - af100) < 1e-9,
      string.format("%.3f vs %.3f", N.af, af100))

-- The tier ORDER must be untouched by the slider: at every setting, the pressure at which
-- each threshold is crossed is the same, because the thresholds are on true pressure. Walk
-- the emission's own clock and record where each effect first appears.
--
-- The third probe is `p >= T_GIVE` and NOT `af < 1`, which is what it was first written as
-- and which fails here for a reason worth recording: below the give-up tier, af is driven by
-- the DROPOUT ROLL, and that roll is deliberately probabilistic (see beat). So the first
-- frame with af < 1 depends on which beat the hash landed on, it moves between two runs of
-- this very function as the beat counter advances, and it marks nothing. af is the effect;
-- the threshold is the tier.
local function first_crossings()
	local t_tear, t_fringe, t_give
	for t = 0, 222, 2 do
		rest()
		ENV._EVENT.surge = { state = true, time = t }
		run(6000)
		if not t_tear   and N.amp > 0    then t_tear = t end
		if not t_fringe and N.fr  > 0    then t_fringe = t end
		if not t_give   and N.p >= T_GIVE then t_give = t end
	end
	return t_tear, t_fringe, t_give
end
CFG.noise_amt = 100
NOISE.apply_config()
local a1, b1, c1 = first_crossings()
CFG.noise_amt = 200
NOISE.apply_config()
local a2, b2, c2 = first_crossings()
check("the slider does not move where the tear starts", a1 == a2,
      string.format("amt100 t=%s, amt200 t=%s", tostring(a1), tostring(a2)))
check("...nor where the fringe starts", b1 == b2,
      string.format("amt100 t=%s, amt200 t=%s", tostring(b1), tostring(b2)))
check("...nor where the give-up tier is entered", c1 == c2,
      string.format("amt100 t=%s, amt200 t=%s -- the tier ORDER moved", tostring(c1), tostring(c2)))
check("and they arrive in the documented order", a1 and b1 and c1 and a1 <= b1 and b1 <= c1,
      string.format("tear %s, fringe %s, stand-down %s", tostring(a1), tostring(b1), tostring(c1)))

CFG.noise_amt = 100
NOISE.apply_config()
-- ==========================================================================
-- 7. Text and icon corruption: resolve-on-beat, and the duty cycles
-- ==========================================================================
-- The safety property of this whole tier is that the mark spends MOST of its beats correct.
-- A header stuck on "REP0RT BACK" is the overlay asserting something false and looking like a
-- bug; one alternating with the truth eleven times a second is a signal fighting through.
-- So the duty cycle is the thing to assert, not merely that corruption happens.
rest()
ENV._EVENT.surge = { state = true, time = 168 }     -- full pressure
run(4000)
do
	-- Sample over many beats and count. run() advances the clock past BEAT repeatedly, so
	-- each sample is a fresh roll.
	local tx_on, ic_on, both_on, samples = 0, 0, 0, 0
	local last_bi = -1
	for _ = 1, 600 do
		run(100)                       -- >= BEAT (90 ms), so a new roll each pass
		if N.bi ~= last_bi then
			last_bi = N.bi
			samples = samples + 1
			if N.txk ~= 0 then tx_on = tx_on + 1 end
			if N.ick ~= 0 then ic_on = ic_on + 1 end
			if N.txk ~= 0 and N.ick ~= 0 then both_on = both_on + 1 end
		end
	end
	check("enough beats sampled to mean anything", samples > 300, "samples=" .. samples)
	local txd, icd = tx_on / samples, ic_on / samples
	check("the text is CORRECT on most beats even at full pressure", txd < 0.5,
	      string.format("duty=%.2f -- past half it stops reading as a signal fighting through", txd))
	check("...but corrupt on a decent share of them", txd > 0.2,
	      string.format("duty=%.2f -- too rare to notice", txd))
	check("the icon's duty is lower than the text's", icd < txd,
	      string.format("icon=%.2f text=%.2f -- a wrong glyph has no spelling to give it away", icd, txd))
	check("...and the icon is correct on the large majority of beats", icd < 0.3,
	      string.format("duty=%.2f", icd))
	-- Independence: sharing a hash row would make the two flip together, which reads as one
	-- event. If they were identical, both_on would equal min(tx_on, ic_on) exactly.
	check("text and icon roll independently", both_on < ic_on,
	      string.format("both=%d icon=%d -- they are flipping in lockstep", both_on, ic_on))
end

-- Both keys must clear on the way out, for the reason ce does: a stuck key is a header that
-- goes on lying, and because the key is also the cache key, lying the SAME way for ever.
rest()
check("the text key clears once it is quiet", N.txk == 0, "txk=" .. tostring(N.txk))
check("the icon key clears too", N.ick == 0, "ick=" .. tostring(N.ick))
ENV._EVENT.surge = { state = true, time = 168 }
run(3000)
CFG.noise = false
NOISE.apply_config()
check("...and both clear when the feature is switched off mid-effect",
      N.txk == 0 and N.ick == 0,
      string.format("txk=%s ick=%s", tostring(N.txk), tostring(N.ick)))
CFG.noise = true
NOISE.apply_config()

-- Below the chroma tier neither may fire: the tier order is the design.
rest()
NOISE.on_hit({ type = 4 })
run(60)                                  -- caught early, while p is still climbing
check("neither key fires below the chroma tier",
      (N.p >= T_CHROMA) or (N.txk == 0 and N.ick == 0),
      string.format("p=%.3f txk=%s ick=%s", N.p, tostring(N.txk), tostring(N.ick)))


-- A world with none of the optional mods present at all: every source is soft, and the
-- absent case must publish a flat rest rather than erroring on the frame path.
rest()
ENV.sr_psy_antenna = nil
ENV.grok_psy_fields_in_the_north = nil
ENV.surge_manager = nil
NOISE.on_game_start()
ENV._EVENT.surge = { state = true, time = 168 }
local ok, err = pcall(run, 2000)
check("with every optional source absent it still runs", ok, tostring(err))
check("...and the emission alone still drives it (surge_manager only gates cover)",
      N.p > 0.5, string.format("p=%.3f", N.p))

-- ------------------------------------------------------------------- summary
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
