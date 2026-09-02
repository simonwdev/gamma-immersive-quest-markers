-- Harness: two-arm chevron (iqm_arms).
--
-- THE QUESTION THIS EXISTS TO ANSWER is not "does it draw" -- it is whether Option C's
-- known defect is small enough to accept, given that Option B's was not. R2.20 dropped
-- two-quad arms over the APEX WEDGE: two bars meeting at a point, each cut square
-- across its own axis, leave a wedge outside the joint that neither covers. Three
-- attempts to fill it were made and abandoned before the one-texture glyph replaced
-- the whole approach.
--
-- What is different now is that the wedge can be MEASURED instead of argued about, and
-- measured against the thing that has to hide it: iqm_arm's soft tip ramps the last
-- 14% of the arm, so a wedge comfortably inside that is covered by the fade and a
-- wedge much wider than it is not. That single number decides the renderer, so most
-- of this file is about pinning it down across the viewing range.
--
-- The other half is the payoff: two arms have two INDEPENDENT headings, and that is
-- the freedom the one-rect glyph lacks. The arms must genuinely diverge where the
-- projection says they should, and must stay symmetric where it says they should.
--
-- Usage:
--   python check_lua.py --run tools/arms-harness/harness.lua
--   VERBOSE=1 ... for the passing lines too

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

-- ---------------------------------------------------------------- engine env
local ENV = {}
ENV.pairs, ENV.ipairs, ENV.tostring, ENV.tonumber = pairs, ipairs, tostring, tonumber
ENV.type, ENV.string, ENV.table, ENV.math, ENV.os = type, string, table, math, os
ENV.setmetatable, ENV.print, ENV.pcall, ENV.select = setmetatable, print, pcall, select
ENV._G = ENV

local fmt_violations = {}
ENV.printf = function(fmt, ...)
	fmt = tostring(fmt)
	if fmt:find("%%[^s]") then fmt_violations[#fmt_violations + 1] = fmt end
end
ENV.callbacks = {}
ENV.RegisterScriptCallback = function(name, fn) ENV.callbacks[name] = fn end
ENV.ui_debug_launcher = { injected = {}, inject = function(_, t)
	ENV.ui_debug_launcher.injected[#ENV.ui_debug_launcher.injected + 1] = t
end }

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
ENV.vector2 = function() return { x = 0, y = 0 } end

local M
ENV.class = function(name) return function(_) rawset(M, name, {}) end end
ENV.CUIScriptWnd = {}
ENV.Frect = function() return { set = function(s) return s end } end
ENV.CScriptXmlInit = function() return {} end
ENV.get_hud = function() return nil end
ENV.db, ENV.game = {}, {}

-- ------------------------------------------------------------------ iqm_util
-- The REAL shared module, not a stub. Every IQM module that logs, injects an F7
-- action or casts an occlusion ray now reads those mechanics out of iqm_util, and
-- a stub here would be testing the stub. In game the lookup loads it by itself --
-- `_G` carries an __index metamethod that calls process_file_if_exists on any
-- missing name (script_engine.cpp:340-353) and every script env inherits from
-- `_G` -- so this block is only the harness doing by hand what the engine does on
-- its own.
ENV.iqm_util = setmetatable({}, { __index = ENV })
do
	local chunk = assert(loadfile("gamedata/scripts/iqm_util.script"))
	setfenv(chunk, ENV.iqm_util)
	chunk()
end

M = setmetatable({}, { __index = ENV })
do
	local f = assert(io.open("gamedata/scripts/iqm_arms.script", "r"))
	local src = f:read("*a")
	f:close()
	local chunk, err = loadstring(src, "@iqm_arms.script")
	assert(chunk, err)
	setfenv(chunk, M)
	local ok, perr = pcall(chunk)
	assert(ok, "iqm_arms failed to parse: " .. tostring(perr))
end

-- ------------------------------------------------------- a real pinhole camera
local EYE_Y, F = 1.6, 700
local function proj(x, y, z)
	if z < 0.1 then return nil, nil, false end
	return 512 + F * x / z, 384 - F * (y - EYE_Y) / z, true
end

local function mark(x, z, ux, uz)
	local L = math.sqrt(ux * ux + uz * uz)
	return { x = x, y = 0, z = z, ux = ux / L, uz = uz / L }
end

-- ==========================================================================
print("-- it produces two arms ------------------------------------------------")

local away = mark(0, 10, 0, 1)
do
	local r = M.arm_rects(away, proj)
	check("a mark gives exactly two arms", r and #r == 2, r and tostring(#r))
	check("both arms have real length", r[1].ln > 1 and r[2].ln > 1,
		string.format("%.2f, %.2f", r[1].ln, r[2].ln))
	check("both arms have real thickness", r[1].th > 1 and r[2].th > 1,
		string.format("%.2f, %.2f", r[1].th, r[2].th))
end

-- ==========================================================================
print("\n-- the apex is ONE point, shared -----------------------------------------")
-- The tip is a single world point and must be projected once. Projecting it per arm
-- would let the two copies differ by a rounding, and the apex is the one place on this
-- mark where a sub-pixel disagreement shows -- it is the feature the eye lands on.
do
	local r = M.arm_rects(mark(0, 6, 1, 1), proj)
	check("both arms report the identical projected tip",
		r[1].tipx == r[2].tipx and r[1].tipy == r[2].tipy,
		string.format("(%.4f,%.4f) vs (%.4f,%.4f)", r[1].tipx, r[1].tipy, r[2].tipx, r[2].tipy))

	-- Each arm must reach PAST the tip, not stop on it. Stopping on it leaves the
	-- wedge between the two end cuts bare, which straight-on the soft tip hides and
	-- obliquely it does not -- the mark breaks into two separate bars. So the test is
	-- an overshoot in the RIGHT DIRECTION, not coincidence with the apex.
	local over = {}
	for i = 1, 2 do
		local a = r[i]
		local ex = a.cx - math.cos(a.ang) * a.ln * 0.5 * M.UI_KX
		local ey = a.cy + math.sin(a.ang) * a.ln * 0.5
		-- component of (rect end - tip) along the direction away from the back corner
		local bx = a.cx + math.cos(a.ang) * a.ln * 0.5 * M.UI_KX
		local by = a.cy - math.sin(a.ang) * a.ln * 0.5
		local vx, vy = a.tipx - bx, a.tipy - by
		local vl = math.sqrt(vx * vx + vy * vy)
		over[i] = ((ex - a.tipx) * vx + (ey - a.tipy) * vy) / vl
	end
	check("both arms reach PAST the apex, so their cores meet there",
		over[1] > 0 and over[2] > 0,
		string.format("overshoot %.2f, %.2f px", over[1], over[2]))
	-- Far enough to clear the texture's own alpha ramp, or the cores still do not
	-- touch and only two fades meet; not so far that the point grows a spur.
	check("...by roughly the texture's tip ramp, not more",
		over[1] > r[1].ln * 0.05 and over[1] < r[1].ln * 0.30,
		string.format("%.2f px on a %.2f px arm", over[1], r[1].ln))
end

-- ==========================================================================
print("\n-- THE PAYOFF: two independent headings ---------------------------------")
-- What the one-texture glyph cannot do at all. The arms must diverge when the
-- projection says so, and stay mirror-symmetric when it says so -- a renderer that
-- diverged always would be inventing distortion rather than reproducing it.
do
	local sym = M.arm_rects(away, proj)
	check("running straight away, the two arms are mirror images",
		math.abs(sym[1].ln - sym[2].ln) < 0.01,
		string.format("%.3f vs %.3f px", sym[1].ln, sym[2].ln))

	local skew = M.arm_rects(mark(0, 6, 1, 1), proj)
	check("at 45 degrees the two arms have DIFFERENT lengths -- the shear",
		math.abs(skew[1].ln - skew[2].ln) > 1.0,
		string.format("%.2f vs %.2f px", skew[1].ln, skew[2].ln))
	check("...and different thicknesses",
		math.abs(skew[1].th - skew[2].th) > 0.1,
		string.format("%.2f vs %.2f px", skew[1].th, skew[2].th))
end

-- ==========================================================================
print("\n-- THE DEFECT: how big is the apex wedge? --------------------------------")
-- The number that decides this renderer. iqm_arm's tip ramp covers the last 14% of an
-- arm, so a wedge that stays modest is hidden by the fade; one that opens wide is the
-- notch R2.20 rejected. Reported across the range rather than at one convenient spot,
-- because the whole argument for Option C is that its defect and its benefit sit at
-- opposite ends of that range.
do
	local rows = {}
	for _, d in ipairs({ 3, 6, 12, 25 }) do
		local w = M.apex_wedge_deg(mark(0, d, 0, 1), proj)
		local w45 = M.apex_wedge_deg(mark(0, d, 1, 1), proj)
		rows[#rows + 1] = string.format("%dm: %.0f/%.0f", d, w, w45)
	end
	print("     wedge (deg) straight-on / at 45:  " .. table.concat(rows, "   "))

	local near = M.apex_wedge_deg(mark(0, 3, 0, 1), proj)
	local far  = M.apex_wedge_deg(mark(0, 25, 0, 1), proj)
	check("the wedge exists and is finite", near and far and near > 0 and far > 0,
		tostring(near) .. " / " .. tostring(far))
	-- The claim that makes Option C worth having: the wedge SHRINKS with distance,
	-- while the shear it competes with grows. If it grew with distance instead, the
	-- two defects would pile up at the same place and this approach would be dead.
	check("...and it NARROWS with distance, where the shear is worst", far < near,
		string.format("%.1f deg at 3 m vs %.1f deg at 25 m", near, far))
end

-- ==========================================================================
print("\n-- SLOPES: the mark lies in the ground plane, not a horizontal one -------")
-- ray_pick:get_normal() is new in MT-TEST_2026.5.15, and every renderer in this
-- project before it assumed the ground was flat. The claim to check is not "we call
-- the binding" but that the mark's three defining points end up IN THE GROUND PLANE
-- and that its long axis is the walked direction tilted into that plane, rather than
-- the horizontal direction used unchanged.
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function sub(a, b) return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z } end

do
	local flat = M.mark_corners(mark(0, 8, 0, 1))
	check("with no normal the mark stays horizontal -- nothing regresses",
		math.abs(flat.tip.y) < 1e-9 and math.abs(flat.back[1].y) < 1e-9,
		string.format("tip y=%.6f", flat.tip.y))

	-- a 20-degree ramp rising along +z
	local s = math.sin(math.rad(20))
	local c = math.cos(math.rad(20))
	local m = mark(0, 8, 0, 1)
	m.n = { x = 0, y = c, z = -s }
	local g = M.mark_corners(m)
	check("on a ramp the mark is no longer flat", math.abs(g.tip.y) > 0.05,
		string.format("tip y=%.4f", g.tip.y))

	local worst = 0
	for _, p in ipairs({ g.tip, g.back[1], g.back[2] }) do
		local d = math.abs(dot(sub(p, { x = m.x, y = m.y, z = m.z }), m.n))
		if d > worst then worst = d end
	end
	check("...and all three corners lie IN the ground plane", worst < 1e-9,
		string.format("worst out-of-plane %.2e m", worst))

	check("...with the long axis tilted INTO the slope, not left horizontal",
		math.abs(g.t.y - s) < 1e-6,
		string.format("axis y = %.4f, ramp sin = %.4f", g.t.y, s))

	-- The arms must stay the right size on a slope: measuring thickness with a
	-- horizontal perpendicular would shrink it as the tilt grows.
	local r_flat = M.arm_rects(mark(0, 8, 0, 1), proj)
	local r_ramp = M.arm_rects(m, proj)
	check("both arms still resolve on a slope", r_ramp and #r_ramp == 2)
	check("...and their thickness does not collapse with the tilt",
		r_ramp[1].th > r_flat[1].th * 0.8,
		string.format("%.2f px on the ramp vs %.2f px flat", r_ramp[1].th, r_flat[1].th))

	-- A vertical face has no in-plane travel direction; that must be nil, not NaN.
	local wall = mark(0, 8, 0, 1)
	wall.n = { x = 0, y = 0, z = -1 }        -- normal faces the camera: travel is along it
	check("travel parallel to the normal is refused, not NaN",
		M.mark_corners(wall) == nil)
	check("...and arm_rects refuses it too", M.arm_rects(wall, proj) == nil)
end

-- ==========================================================================
print("\n-- the aspect correction is live ----------------------------------------")
do
	ENV.device = function() return { width = 1920, height = 1080 } end
	check("16:9 gives kx = 0.75", math.abs(M.refresh_kx() - 0.75) < 1e-6,
		tostring(M.UI_KX))
	ENV.device = function() return { width = 1024, height = 768 } end
	check("4:3 gives kx = 1", math.abs(M.refresh_kx() - 1) < 1e-6, tostring(M.UI_KX))
	ENV.device = nil
end

-- ==========================================================================
print("\n-- degenerate cases ------------------------------------------------------")

check("a mark behind the camera gives nothing", M.arm_rects(mark(0, -4, 0, 1), proj) == nil)
check("...and so does its wedge", M.apex_wedge_deg(mark(0, -4, 0, 1), proj) == nil)
check("draw() with no HUD is a no-op, not a crash",
	(pcall(function() return M.draw({ away }) end)))

-- A mark that cannot project must not take its NEIGHBOURS down with it. Pool row mi
-- belongs to marks[mi], so counting successes and using that count as the parking
-- high-water mark blanks rows that were just drawn -- and because which mark fails
-- changes with the camera, the visible effect is marks winking out as you move.
do
	local mixed = { mark(0, 6, 0, 1), mark(0, -5, 0, 1), mark(0, 10, 0, 1) }
	local drew = M.draw(mixed)      -- no HUD offline, so this exercises the counting only
	check("a mid-list mark that fails to project is survivable",
		type(drew) == "number", tostring(drew))
end

-- ==========================================================================
print("\n-- the rect matches the arm's TRUE projected quad ------------------------")
-- The check that should have existed from the start, and did not: build the arm's four
-- real world corners, project them, and measure the quad's extent across its own screen
-- axis. That is the thickness the rect is supposed to carry.
--
-- Measuring the full screen distance between the two edge points instead -- the
-- obvious thing, and what this did originally -- charges the SHEAR to the thickness.
-- The in-plane perpendicular is perpendicular in the world, but the projection shears
-- it, so on screen part of it runs ALONG the arm. That made the rect up to 3.4x too
-- thick (9.7 px against a true 2.8 at 12 m), growing with distance and obliquity,
-- which is why marks read as blobs everywhere except close and head-on -- where the
-- error is 1.03x and nothing looked wrong.
local function true_quad(dist, yaw, side)
	local MARK_LEN, MARK_WIDE, MARK_ARM = 0.50, 1.48, 0.304
	local ux, uz = math.sin(yaw), math.cos(yaw)
	local ax, az = uz, -ux
	local hl, hw, ha = MARK_LEN * 0.5, MARK_WIDE * 0.5, MARK_ARM * 0.5
	local T = { x = ux * hl, z = dist + uz * hl }
	local B = { x = -ux * hl + ax * hw * side, z = dist - uz * hl + az * hw * side }
	local dx, dz = B.x - T.x, B.z - T.z
	local al = math.sqrt(dx * dx + dz * dz); dx, dz = dx / al, dz / al
	local px, pz = dz, -dx
	local t0x, t0y = proj(T.x, 0, T.z)
	local b0x, b0y = proj(B.x, 0, B.z)
	local vx, vy = b0x - t0x, b0y - t0y
	local vl = math.sqrt(vx * vx + vy * vy); vx, vy = vx / vl, vy / vl
	local lo, hi = 1e9, -1e9
	for _, e in ipairs({ { T, 1 }, { T, -1 }, { B, 1 }, { B, -1 } }) do
		local sx, sy = proj(e[1].x + px * ha * e[2], 0, e[1].z + pz * ha * e[2])
		local c = -(sx - t0x) * vy + (sy - t0y) * vx
		lo, hi = math.min(lo, c), math.max(hi, c)
	end
	return hi - lo
end
do
	local worst, worst_at = 0, nil
	for _, dist in ipairs({ 3, 6, 12, 25 }) do
		for _, deg in ipairs({ 0, 20, 40, 60 }) do
			local yaw = math.rad(deg)
			local r = M.arm_rects(mark(0, dist, math.sin(yaw), math.cos(yaw)), proj)
			for i = 1, 2 do
				local e = r[i].th / true_quad(dist, yaw, i == 1 and 1 or -1)
				local off = math.abs(math.log(e))
				if off > worst then worst, worst_at =
					off, string.format("%dm/%ddeg arm %d: x%.2f", dist, deg, i, e) end
			end
		end
	end
	-- Within 20%. Not tighter: a projected quad is a TRAPEZOID and a rect cannot be
	-- one, so close and oblique the rect is legitimately a little under the quad's
	-- bounding extent. The failure this guards against is the 3.4x kind.
	check("no arm's thickness is off the true quad by more than 20%",
		worst < math.log(1.20), tostring(worst_at))
end

-- ==========================================================================
print("\n-- no arm collapses along its own axis -----------------------------------")
-- An arm is 5:1 straight-on, but turn the mark off-axis and its length foreshortens
-- while its thickness does not. Unchecked, th/ln crosses 1 past about 40 degrees
-- (measured 1.07 at 6 m, 2.04 at 12 m, 3.31 at 25 m at 60 degrees) -- the rect is then
-- wider across than along, and since iqm_arm's tip ramp and tail taper both run
-- LENGTHWISE, SetStretchTexture crushes the whole glyph into a few pixels and splays
-- the thickness out. It reads as a blob with a sideways gradient, which is what the
-- first oblique screenshot showed. ARM_ASPECT_MIN floors the elongation.
do
	local worst, worst_at = 0, nil
	for _, dist in ipairs({ 3, 6, 12, 25 }) do
		for deg = 0, 90, 5 do
			local m = mark(0, dist, math.sin(math.rad(deg)), math.cos(math.rad(deg)))
			local r = M.arm_rects(m, proj)
			if r then
				for i = 1, 2 do
					local a = r[i].th / r[i].ln
					if a > worst then worst, worst_at = a, string.format("%dm/%ddeg", dist, deg) end
				end
			end
		end
	end
	-- 1/1.6 = 0.625, with a hair of slack for the LMIN/TMIN floors interacting.
	check("no arm is ever thicker than it is long", worst <= 0.63,
		string.format("worst th/ln %.2f at %s", worst, tostring(worst_at)))
end

-- The floor must not move the apex. It is the feature the eye lands on, and the whole
-- reason the tip is projected once and shared; buying elongation by sliding the arm
-- outward would trade one visible defect for a worse one.
do
	local m = mark(0, 25, math.sin(math.rad(60)), math.cos(math.rad(60)))
	local r = M.arm_rects(m, proj)
	local ok = true
	for i = 1, 2 do
		local a = r[i]
		-- the rect's apex-side end, in screen space
		local ex = a.cx - math.cos(a.ang) * a.ln * 0.5 * M.UI_KX
		local ey = a.cy + math.sin(a.ang) * a.ln * 0.5
		local bx = a.cx + math.cos(a.ang) * a.ln * 0.5 * M.UI_KX
		local by = a.cy - math.sin(a.ang) * a.ln * 0.5
		-- whichever end is nearer the apex must still be within the tip ramp of it
		local d = math.min(math.sqrt((ex - a.tipx) ^ 2 + (ey - a.tipy) ^ 2),
		                   math.sqrt((bx - a.tipx) ^ 2 + (by - a.tipy) ^ 2))
		if d > a.ln * 0.30 then ok = false end
	end
	check("...and the stretched arm still starts at the apex", ok)
end

-- ==========================================================================
print("\n-- housekeeping ---------------------------------------------------------")

M.on_game_start()
check("it registers its F7 actions", #ENV.ui_debug_launcher.injected == 2,
	tostring(#ENV.ui_debug_launcher.injected))
M.on_game_start()
check("...and never twice", #ENV.ui_debug_launcher.injected == 2,
	tostring(#ENV.ui_debug_launcher.injected))
check("it tears the dialog down on unload", ENV.callbacks
	and ENV.callbacks["actor_on_net_destroy"] ~= nil)
-- The dialog handle MUST be a namespace global. As a local it comes back nil on the
-- next save load, ensure_wnd builds a second dialog, and the first is never reclaimed
-- -- the engine only drops one via RemoveDialogToRender or CleanInternals, and a save
-- load calls neither. The orphan then draws forever at fixed SCREEN rects, which reads
-- as marks glued to the camera. Tidying this back into a local reintroduces that.
check("the dialog handle survives a script re-read", rawget(M, "HUD_STATE") ~= nil)

check("every format string uses only %s", #fmt_violations == 0,
	fmt_violations[1] and (#fmt_violations .. " bad, first: " .. fmt_violations[1]))

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
