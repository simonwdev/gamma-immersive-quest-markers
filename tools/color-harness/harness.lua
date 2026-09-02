-- Harness: the waypoint marker's COLOUR, checked outside the game.
--
-- WHY THIS EXISTS. beacon_color (R2.34) makes a marker take the colour of that role's
-- PDA map spot. Those colours live in TWO files that nothing connects: BEACON_RGB in
-- iqm_core.script is what the world marker draws, SPOTS in
-- modxml_n_iqm_map_icons.script is what actually paints the map. The whole point of the
-- option is that the two agree, and a colour edited in one file and not the other is
-- invisible -- nothing errors, nothing looks broken in isolation, the two views just
-- quietly stop matching, which is exactly the thing the feature promises they never do.
-- No amount of compiling catches that. This does.
--
-- What it checks:
--
--   1. THE MIRROR. Every colour in BEACON_RGB equals the one SPOTS gives that role's
--      map spot, channel for channel, resolved through the spot id each role maps to.
--   2. THE ABSENTEES. guider and waypoint have no entry, deliberately (no vanilla guide
--      spot; PAW's waypoint is a named pure blue). A colour appearing for either means
--      someone added one without reading why it was left out.
--   3. THE RESOLVE. The mode/role/faction/fallback chain reimplemented here and run over
--      every combination, so the layering rule (mode 2 = mode 1 plus a faction override
--      on turn-ins only) is asserted rather than just commented.
--   4. NEVER BLACK. No mode/role/community combination may resolve to a colour the mod
--      does not have -- a nil indexed as col[1] would draw a black marker, and black on
--      a keylined badge is the one tint that vanishes completely.
--   5. THE MENU. The list values in the option registry match the modes the resolve handles,
--      the default is one of them (and is still the accent), and every list string exists in
--      BOTH locales. Since R2.62 that includes mode 3's own three channels: they must live on
--      the beacons page, step by 1, and DEFAULT TO THE ACCENT'S OWN VALUES -- read out of the
--      accent's rows rather than restated here, so retuning the gold moves both together.
--
-- Usage:
--   python check_lua.py --run tools/color-harness/harness.lua
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

-- Read as ONE string across the files the palette now spans. R2.45 split iqm_core:
-- BEACON_RGB (the marker's tint per role) went to iqm_beacon, while FACTION_RGB and
-- the beacon_color option itself stayed with the card pass that resolves them. Both
-- have to be in scope, or the half that moved would come back nil -- which reads as
-- "nothing to check" rather than as a failure.
local markers_src = slurp("gamedata/scripts/iqm_core.script")
                 .. slurp("gamedata/scripts/iqm_beacon.script")
local modxml_src  = slurp("gamedata/scripts/modxml_n_iqm_map_icons.script")

-- One OPTIONS record's raw text, by key. R2.46 collapsed DEFAULTS, PAGE_OF and the MCM
-- widget list into a single registry in iqm_core, so an option's default, its storage
-- page and its list values are three fields of ONE row now rather than three files --
-- which is why this reads iqm_core and no longer reads iqm_mcm at all (that file
-- writes no beacon_color literal to disagree with).
--
-- Stops at a line starting with `{`, `-` or a blank one: registry rows sit at column 0
-- and are separated by exactly those, so this captures a one-line row and a row with a
-- braced content list alike without needing to count braces.
local function opt_row(key)
	return markers_src:match('\n({ key = "' .. key .. '",.-)\n[%-{\n]')
end

-- --------------------------------------------------- what the two files declare
-- Read from the SOURCE TEXT, not off a loaded module: both tables are file locals, and
-- more to the point what a reviewer reads is the text. A harness that agreed with a
-- computed value while disagreeing with the literal would be checking the wrong thing.

-- BEACON_RGB { key = {r, g, b} }
local BRGB = {}
do
	local blk = markers_src:match("local BEACON_RGB%s*=%s*{(.-)\n}")
	assert(blk, "BEACON_RGB block not found in iqm_core.script")
	-- [%w_] and not %w: Lua's %w has no underscore in it, so an underscored key would be
	-- captured from its last part on and silently mirror nothing.
	for k, r, g, b in blk:gmatch("([%w_]+)%s*=%s*{%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*}") do
		BRGB[k] = { tonumber(r), tonumber(g), tonumber(b) }
	end
end

-- SPOTS: [selector] = {r, g, b}. Entries with no r/g/b (the PAW waypoint) are skipped.
local SPOT = {}
for sel, rest in modxml_src:gmatch('{%s*sel%s*=%s*"([^"]+)"%s*,(.-)}') do
	local r = rest:match("r%s*=%s*(%d+)")
	local g = rest:match("g%s*=%s*(%d+)")
	local b = rest:match("b%s*=%s*(%d+)")
	if r and g and b then SPOT[sel] = { tonumber(r), tonumber(g), tonumber(b) } end
end

-- ...plus the task-KIND spots (R2.48), which are NOT in the SPOTS retexture table. They
-- are IQM's own location types, authored whole in ui/iqm_map_spots.xml rather than
-- patched onto one of the game's elements, so their colours live in XML attributes and
-- nothing above would ever see them. Folded into the SAME table so the mirror check
-- below does not need to know which of the two files a colour came from.
--
-- EVERY r/g/b INSIDE ONE SPOT ELEMENT MUST AGREE, and that is checked rather than
-- assumed: each of these elements hand-writes the tint up to four times (the icon, the
-- selection border, and the minimap's above/below swaps), which is four chances for one
-- of them to be edited and the others forgotten. A spot whose off-level arrow is a
-- different green from its skull is the kind of thing nobody notices until they are two
-- floors up.
local spots_xml = slurp("gamedata/configs/ui/iqm_map_spots.xml")
for name, body in spots_xml:gmatch("<(iqm_task_[%w_]+_spot[%w_]*)[^>]*>(.-)</%1>") do
	local first, mixed = nil, false
	for r, g, b in body:gmatch('r="(%d+)"%s+g="(%d+)"%s+b="(%d+)"') do
		local c = { tonumber(r), tonumber(g), tonumber(b) }
		if not first then
			first = c
		elseif c[1] ~= first[1] or c[2] ~= first[2] or c[3] ~= first[3] then
			mixed = true
		end
	end
	check("one tint throughout " .. name, first ~= nil and not mixed,
	      name .. " carries more than one r/g/b, or none at all")
	if first then SPOT[name] = first end
end

-- THE OFF-SCREEN POINTERS -- REVERTED (R2.59), and this block is kept as an ASSERTION THAT
-- THEY STAY GONE rather than deleted. R2.53 gave the task locations arrows of our own, one
-- per pin colour; R2.59 took them back out because an off-screen arrow is a shared
-- vocabulary even when the element is private -- the player learns one arrow, and a second
-- one that means "but this is a task" splits it at exactly the moment the pin cannot be
-- seen. The reasoning is in ui/iqm_map_spots.xml and modxml_n_iqm_map_icons.
--
-- Deleting the check would let the elements come back silently; a colour invented at the
-- edge of the map is the single hardest thing in this mod to notice by eye, which is why it
-- had a harness in the first place.
local PTR = {}
for name, body in spots_xml:gmatch("<(iqm_pointer_[%w_]+)[^>]*>(.-)</%1>") do
	local r, g, b = body:match('r="(%d+)"%s+g="(%d+)"%s+b="(%d+)"')
	if r then PTR[name] = { tonumber(r), tonumber(g), tonumber(b) } end
end

-- FACTION_RGB, for the mode-2 override
local FRGB = {}
do
	local blk = markers_src:match("local FACTION_RGB%s*=%s*{(.-)\n}")
	assert(blk, "FACTION_RGB block not found")
	-- [%w_] and not %w: Lua's %w has no underscore in it, so an underscored key would be
	-- captured from its last part on and silently mirror nothing.
	for k, r, g, b in blk:gmatch("([%w_]+)%s*=%s*{%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*}") do
		FRGB[k] = { tonumber(r), tonumber(g), tonumber(b) }
	end
end

check("BEACON_RGB parsed", next(BRGB) ~= nil)
check("SPOTS parsed", next(SPOT) ~= nil)
check("FACTION_RGB parsed", next(FRGB) ~= nil)

-- ------------------------------------------------------------- 1. the mirror
-- Which map spot each marker colour is claiming to match. This mapping is the harness's
-- own assertion about intent -- it is the sentence "the turn-in marker matches the task
-- spot" written where it can be checked.
local MIRROR = {
	-- The turn-in mirrors the HAND-IN spot, not the task spot. storyline_task_spot is the
	-- "go find it" reticle; storyline_task_on_guider_spot is "done, go collect on it",
	-- which is what the target role means and what its glyph already draws. R2.34a fixed
	-- this after shipping it wrong, so the mapping is asserted rather than assumed.
	target       = "storyline_task_on_guider_spot",
	trader       = "ui_pda2_trader_location_spot",
	mechanic     = "ui_pda2_mechanic_location_spot",
	barman       = "ui_pda2_barman_location_spot",
	medic        = "ui_pda2_medic_location_spot",
	-- The two TASK KINDS (R2.48). These are keys in BEACON_RGB but not roles: the marker
	-- reads them off iqm_scan.task_kind rather than off a tracked NPC's role. They mirror
	-- the location types IQM declares for itself, which is the same promise as every row
	-- above -- the mark you look for through a wall is the colour the pin wears.
	mutant       = "iqm_task_mutant_spot",
	bounty       = "iqm_task_bounty_spot",
	delivery     = "iqm_task_delivery_spot",
	-- `handin` is the KIND whose colour the `target` ROLE above already carries, and it
	-- mirrors IQM's OWN hand-in spot rather than target's vanilla on-guider one. Both greens
	-- are the same green -- HANDIN_ALL below is the assertion that they stay so, and the
	-- "hand-in wears the hand-in green" check ties target to iqm_task_handin_spot directly --
	-- so the two rows can point at different spot ids without disagreeing. Pointed here on
	-- purpose: this is the type IQM declares and paints itself, so it is the one a kind
	-- should be measured against, while target keeps the vanilla pointer it was written for.
	handin       = "iqm_task_handin_spot",
	-- `party` is a THIRD vocabulary again (R2.57) -- neither a role nor a task kind, but
	-- the companion marker's own key -- and it mirrors the spot the map already draws on a
	-- companion. Note the value it lands on: the modxml paints that spot 40,172,66, THE
	-- SAME GREEN AS THE THREE TURN-IN SPOTS, on purpose and by request ("the companion
	-- green, byte for byte"). So this row and `target` agreeing is the mirror working, not
	-- two rows drifting into each other, and asserting it here is what keeps a later tidy-up
	-- of one from silently moving the other.
	party        = "ui_pda2_companion_location_spot",
}

-- ...and each kind's MAP and MINIMAP spots must agree with each other, for the reason
-- HANDIN_ALL exists: one mark, several carriers, hand-written in each. The fullscreen
-- map and the handheld minimap showing a bounty in two different reds is a bug the
-- player would read as two different kinds of task.
local KIND_PAIRS = {
	{ "iqm_task_mutant_spot", "iqm_task_mutant_spot_mini" },
	{ "iqm_task_bounty_spot", "iqm_task_bounty_spot_mini" },
	{ "iqm_task_delivery_spot", "iqm_task_delivery_spot_mini" },
	{ "iqm_task_open_spot", "iqm_task_open_spot_mini" },
	{ "iqm_task_waypoint_spot", "iqm_task_waypoint_spot_mini" },
	{ "iqm_task_handin_spot", "iqm_task_handin_spot_mini" },
}

--- iqm_task_waypoint is iqm_task_open with the static_border removed and NOTHING else
--- changed (R2.55 split the two so a stash task could keep the engine's active-task ring
--- while PAW's pin, which brings its own animated ring, does not get a second one). Colour
--- is one of the things that must not change, so it is asserted rather than left to the
--- two entries above happening to hold the same literal. This is the same shape of check as
--- "delivery wears the hand-in green" below: an IDENTITY, where the rest of this file
--- checks differences, and it fails on a drift no separation test would notice.
local SAME_TINT = {
	{ "iqm_task_open_spot", "iqm_task_waypoint_spot" },
}

-- EVERY iqm_task_* TYPE IS IN ONE OF THE TWO LISTS ABOVE, checked below rather than by
-- eye. Both MIRROR and KIND_PAIRS are hand-written, so a type added to iqm_map_spots.xml
-- lands in neither and is silently unchecked - which is exactly what happened when
-- iqm_task_waypoint was added and this whole file still reported 72 passed.

-- ...and the hand-in colour has FOUR carriers on the map, which must not drift apart:
-- both vanilla on-guider spots and ATUE's return spot. Handing in is handing in whatever
-- kind of task asked for it, so one of these picking up a different green is a bug in the
-- map before it is a bug here.
local HANDIN_ALL = {
	"storyline_task_on_guider_spot", "secondary_task_on_guider_spot",
	"atue_return_task_spot", "atue_return_task_spot_mini",
}

local function same(a, b)
	return a and b and a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end
local function show(c)
	return c and string.format("%d,%d,%d", c[1], c[2], c[3]) or "nil"
end

for key, sel in pairs(MIRROR) do
	local mine, theirs = BRGB[key], SPOT[sel]
	check("mirror " .. key,
	      same(mine, theirs),
	      string.format("BEACON_RGB.%s = %s but %s = %s", key, show(mine), sel, show(theirs)))
end

for _, sel in ipairs(HANDIN_ALL) do
	check("hand-in carrier " .. sel, same(SPOT[sel], BRGB.target),
	      string.format("%s = %s, marker = %s", sel, show(SPOT[sel]), show(BRGB.target)))
end

for _, pair in ipairs(SAME_TINT) do
	check("same tint " .. pair[1] .. " / " .. pair[2], same(SPOT[pair[1]], SPOT[pair[2]]),
	      string.format("%s = %s, %s = %s", pair[1], show(SPOT[pair[1]]),
	                    pair[2], show(SPOT[pair[2]])))
end

for _, pair in ipairs(KIND_PAIRS) do
	check("map/minimap agree " .. pair[1], same(SPOT[pair[1]], SPOT[pair[2]]),
	      string.format("%s = %s, %s = %s", pair[1], show(SPOT[pair[1]]),
	                    pair[2], show(SPOT[pair[2]])))
end

-- The bounty is the ORDINARY reticle in red, so its colour is the only thing telling it
-- from an unflagged task. Assert the separation the design rests on rather than trusting
-- that nobody nudges one of the three toward the others.
check("bounty is not the task-spot gold", not same(SPOT["iqm_task_bounty_spot"], SPOT["storyline_task_spot"]))
check("bounty is not the task-spot pale", not same(SPOT["iqm_task_bounty_spot"], SPOT["secondary_task_spot"]))

-- THE WARM/COOL OPPOSITION CHECK THAT SAT HERE IS GONE (R2.55), with the hostage kind it
-- guarded. It asserted that iqm_task_bounty and iqm_task_hostage - the same bust in the
-- same reticle, told apart by tint alone - were a hue OPPOSITION (one r > b, the other
-- b > r) rather than two shades of one colour, because a plain distance floor would pass
-- for two reds far apart in lightness. That was the right check for that design.
--
-- Rescues now answer "bounty" outright, so there is no second tint on that cell and nothing
-- left to oppose. Worth recording rather than deleting silently: if any kind is ever again
-- given a colour on a cell another kind already uses, this is the check it needs, and a dE
-- floor is NOT a substitute for it.

-- ...and the ONE PAIR THAT MUST MATCH rather than separate (R2.54a). Every other check
-- here asserts a difference; this asserts an identity, because the delivery mark takes the
-- HAND-IN's green on purpose. Walking a package to a named NPC is the same act as walking a
-- finished job back to its giver, so the colour says "hand this to somebody" and the glyph
-- (envelope against price tag) says which errand. Nudge either green and that sentence stops
-- being true, silently and in the direction nobody looks for: two marks that were supposed
-- to rhyme quietly stop rhyming.
check("delivery wears the hand-in green", same(SPOT["iqm_task_delivery_spot"], BRGB.target),
      string.format("delivery = %s, hand-in = %s",
                    show(SPOT["iqm_task_delivery_spot"]), show(BRGB.target)))

--- ...and so does the hand-in mark itself, which is the same identity asserted from the
--- other end. The two are one statement to the player -- "walk to a person and give them
--- something" -- separated by glyph and not by colour, so a drift in either would quietly
--- turn one idea back into two. R2.58 added the type; before it, this state was
--- atue_return_task_location and its colour lived in another mod entirely.
check("hand-in wears the hand-in green", same(SPOT["iqm_task_handin_spot"], BRGB.target),
      string.format("hand-in spot = %s, beacon = %s",
                    show(SPOT["iqm_task_handin_spot"]), show(BRGB.target)))
check("hand-in and delivery are the same green",
      same(SPOT["iqm_task_handin_spot"], SPOT["iqm_task_delivery_spot"]))

-- The wrong turn R2.34a fixed: the turn-in must NOT be wearing the go-find-it reticle's
-- colour. Cheap to assert, and it is the one mistake this table has actually made.
check("turn-in is not the task-spot gold", not same(BRGB.target, SPOT["storyline_task_spot"]))
check("turn-in is not the task-spot pale", not same(BRGB.target, SPOT["secondary_task_spot"]))

-- ...and no colour in BEACON_RGB that mirrors nothing: an entry added without a map spot
-- behind it is a colour invented here, which is the one thing this table must not hold.
for key in pairs(BRGB) do
	check("mirrored " .. key, MIRROR[key] ~= nil, "BEACON_RGB." .. key .. " matches no map spot")
end

-- ------------------------------------------------------- 1b. the GLYPH mirror
-- The colour mirror above has a twin nobody was checking, and R2.55 broke it: the two
-- atlases render the SAME SVGs for seven marks (the R2.29 rule), so the art has two
-- consumers and two build scripts, and editing one copy without the other silently gives
-- the map and the marker different glyphs for one objective. That is what happened to the
-- hand-in -- ../map-icons/svg/handin.svg became a price tag, role-icons kept the diamond,
-- and for a release the PDA said tag while the beacon said diamond.
--
-- IT SURVIVED FOR THE SAME REASON THE COLOUR DRIFT WOULD: nothing errors. Both atlases
-- build, both cells hold valid art, and only seeing the two views side by side says which
-- one is stale. This cell had nobody looking at it either -- the `target` role's marker was
-- retired in R2.46 and the `handin` KIND that draws it now only arrived in R2.55 -- and,
-- unlike the map spots, the role atlas has no legend sheet (extract.py reads map-spot ids
-- only), so there was no picture of it anywhere to notice. Exactly the shape of bug this
-- whole file exists for, in the other half of the same promise.
--
-- The shared list is hand-written for the same reason MIRROR is: it is the sentence "these
-- seven are one piece of art" written where it can fail. Lua 5.1 cannot list a directory
-- anyway, so an enumeration was never on offer -- but a name added to both folders and not
-- to this list is unchecked, which is the one hole and is worth knowing about.
--
-- COMMENTS ARE STRIPPED before comparing: the two copies deliberately carry different
-- headers (each explains its own atlas's rendering), so only the <path> data is the shared
-- artefact. Comparing whole files would fail on every pair and check nothing.
-- "vip" is the eighth (R2.57), shared for the companion marker: the map draws a companion
-- as the VIP bust, so the marker renders the map's own vip.svg rather than a companion
-- glyph of its own. Same name on both sides precisely so it lands in this list.
local SHARED_SVG = {"handin", "trader", "medic", "mechanic", "barman", "skull", "mail",
                    "vip"}

local function svg_paths(dir, name)
	local f = io.open(ROOT .. "tools/" .. dir .. "/svg/" .. name .. ".svg", "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	s = s:gsub("<!%-%-.-%-%->", "")            -- drop the per-atlas header
	local out = {}
	for p in s:gmatch("<path.->") do out[#out + 1] = p end
	return table.concat(out, "\n")
end

for _, name in ipairs(SHARED_SVG) do
	local m = svg_paths("map-icons", name)
	local r = svg_paths("role-icons", name)
	check("shared art exists both sides: " .. name, m ~= nil and r ~= nil,
	      "one of the two copies is missing -- the R2.29 rule needs both")
	if m and r then
		check("same glyph in both atlases: " .. name, m == r,
		      "map and role copies of " .. name .. ".svg have different path data; the PDA "
		      .. "and the marker will draw different glyphs for one thing. Sync them and "
		      .. "rerun BOTH build scripts")
	end
end
check("guider has no map colour",   BRGB.guider   == nil, "vanilla does not map-spot guides")
-- The waypoint's reason CHANGED in R2.49e without the check needing to: iqm_task_open
-- now gives it a spot of ours, in the secondary task's bone. It still gets no marker
-- colour, because the player's own mark keeping the accent is the point ("gold already
-- reads as yours"), and because that spot's colour is the SIDE-TASK bone rather than a
-- colour chosen for waypoints - mirroring it would tell the player their own pin is a
-- side job. R2.52 generalised that type to every task landing on an existing mark, which
-- makes the bone MORE right rather than less: it is the side-task colour and these are
-- side tasks. `open`, the second kind that wears it, is absent here for the same reason.
check("waypoint has no map colour", BRGB.waypoint == nil, "the player's own mark keeps the accent")
check("open has no map colour",     BRGB.open     == nil,
      "it wears the side-task bone, which is not a colour chosen to mean anything")

-- ...and no arrow of ours is declared or referenced anywhere.
do
	check("no iqm_pointer_* elements are declared", next(PTR) == nil,
	      "R2.59 removed them; a redeclared pointer is a colour nothing can be compared to")
	check("no task type names one", spots_xml:find('pointer="iqm_pointer', 1, true) == nil,
	      "our task types must name the game's own quest_pointer")
	-- Matched at COLUMN 0, so the commented-out reinstate recipe in that file (which is
	-- indented behind a `--`) does not read as a live table. Checking for the declaration
	-- rather than for the string "iqm_pointer" is the point: the reinstate note is meant to
	-- survive, and a test that forbids mentioning the thing would force it to be deleted.
	check("modxml declares no POINTERS table", modxml_src:find("\nlocal POINTERS") == nil,
	      "the repointing loop was removed with the elements")
end

-- Nothing new may slip past the two hand-written tables above.
do
	local covered = {}
	for _, sel in pairs(MIRROR) do covered[sel] = true end
	for _, pair in ipairs(KIND_PAIRS) do covered[pair[1]] = true; covered[pair[2]] = true end
	for sel in pairs(SPOT) do
		if sel:match("^iqm_task_") then
			check("checked somewhere " .. sel, covered[sel] == true,
			      sel .. " is in neither MIRROR nor KIND_PAIRS")
		end
	end
end

-- ---------------------------------------------------------- 3. the resolve
-- The chain from iqm_core' scan pass, reimplemented. Returns nil for "accent".
--
-- MODE 3 RESOLVES LIKE MODE 0 (R2.62), i.e. to nil for everything. It asks for the
-- marker's own colour rather than for one that depends on the NPC, and draw_beacon
-- substitutes that colour wherever this pass left nil -- so the custom colour reaching
-- every mark and the map's role colours staying out of mode 3 are the SAME assertion,
-- and it is this one. The gate in iqm_core is read back below so a `> 0` creeping back
-- into it (which would make mode 3 into mode 1 with a custom fallback) fails here.
-- THE KEY IS A ROLE *OR* A TASK KIND (R2.63). They share BEACON_RGB's namespace, and
-- that sharing is what lets one resolver answer for all three marker paths -- the role
-- pass, the selected task and the party. The turn-in set is what mode 2 overrides, and
-- it is three keys and not one: the `target` ROLE and the `handin` / `delivery` KINDS
-- all mean REPORT BACK, so a mode that colours one of them and not the others puts two
-- colours on two marks that say the same thing -- which is exactly the defect R2.63
-- fixed, arriving from the other direction.
local TURN_IN = { target = true, handin = true, delivery = true }
-- ...and the two keys that are not a theme and so do not follow the mode at all (R2.63a).
-- No ROLE draws a skull or a red reticle, so these can never stand beside a
-- differently-coloured mark meaning the same thing -- the defect the mode gate exists for
-- cannot arise here. And the bounty has no glyph of its own on purpose, so gating its red
-- does not dim that mark, it deletes it.
local DRESSING = { mutant = true, bounty = true }
local function resolve(mode, key, comm)
	if DRESSING[key] then return BRGB[key] end
	if mode == 0 or mode == 3 then return nil end
	if mode == 2 and TURN_IN[key] then
		-- nil = nobody looked (no tracked entry); false = looked, community unlisted.
		if comm == nil then return BRGB[key] end
		return FRGB[comm] or FRGB.stalker
	end
	return BRGB[key]
end

check("mode 0 is accent for every role", (function()
	for _, role in ipairs{"target", "guider", "trader", "mechanic", "barman", "medic"} do
		if resolve(0, role, "dolg") ~= nil then return false end
	end
	return true
end)())

-- mode 1: the turn-in is the map's hand-in green, whatever the quest giver's faction
check("mode 1 turn-in is the hand-in green", same(resolve(1, "target", "dolg"), BRGB.target))
check("mode 1 never consults the faction",   same(resolve(1, "target", "dolg"), resolve(1, "target", "army")))

-- mode 2 layers ON mode 1: only the turn-in is overridden
check("mode 2 turn-in takes the faction", same(resolve(2, "target", "dolg"), FRGB.dolg))
for _, role in ipairs{"trader", "mechanic", "barman", "medic"} do
	check("mode 2 leaves " .. role .. " on its map colour", same(resolve(2, role, "dolg"), BRGB[role]))
	check("mode 1 gives " .. role .. " its map colour",     same(resolve(1, role, "dolg"), BRGB[role]))
end

-- The trader rule (R2.34a): script traders report the community "trader", which has no
-- FACTION_RGB entry. In mode 2 they take STALKER's amber, not the green -- a turn-in in
-- that mode is always A FACTION COLOUR, so the mode never mixes its two vocabularies.
check("mode 2 trader turn-in takes the stalker colour", same(resolve(2, "target", "trader"), FRGB.stalker))
check("mode 2 unknown community takes the stalker colour", same(resolve(2, "target", "nosuchfaction"), FRGB.stalker))
check("mode 2 with a resolved but unlisted community takes the stalker colour",
      same(resolve(2, "target", false), FRGB.stalker))
-- ...and the case that is NOT that one, which read as it for the length of one review
-- (R2.63b). The selected task's giver can be outside the scan's reach entirely -- there
-- is no range gate on that marker and the tracked set stops at beacon_dist -- so its
-- community is not "unlisted", it is UNASKED. Amber there is a positive claim about a
-- faction, and it was wrong often enough to be visible: a Duty giver drew loner amber at
-- 150 m and snapped to Duty red as the player crossed 60 m, which makes this option's
-- colour a function of RANGE -- the same defect as the one this whole file guards,
-- arriving through the fallback instead of through the mode.
check("mode 2 with NO community resolved yet stays the turn-in green",
      same(resolve(2, "target", nil), BRGB.target),
      "an unscanned giver has no faction to claim; green claims only what is known")
check("...which is exactly mode 1's answer, the base mode 2 layers on",
      same(resolve(2, "target", nil), resolve(1, "target", "dolg")))
check("...and the two unknowns are told apart",
      not same(resolve(2, "target", nil), resolve(2, "target", false)),
      "`or nil` at the call site folds false into nil and loses the distinction")
-- ...AND THE SOURCE, because every assertion above this one is against `resolve`, which is
-- a REIMPLEMENTATION of the rule and not the rule. Deleting the nil branch from
-- iqm_core.beacon_tint leaves all of them passing -- verified by doing it -- so on its own
-- the mirror is a model test wearing a regression test's clothes. These two tie it down.
check("the resolver distinguishes an unasked community from an unlisted one",
      markers_src:find("if fcomm == nil then return BEACON_RGB[key] end", 1, true) ~= nil,
      "without it an unscanned giver claims the loner amber, and the mark changes "
      .. "colour as the player walks into beacon_dist")
-- ...and that the community reaching it is not read off `tracked` at all (R2.63c). That
-- was the original defect and the nil branch above only softened it: the selected task's
-- marker has NO range gate, the tracked set stops at beacon_dist, so a community taken
-- from there is present or absent depending on how far away the player is standing --
-- i.e. mode 2's colour became a function of RANGE. Resolved from the SERVER object it is
-- the same answer at every distance, which is the actual fix; the nil branch stays as the
-- honest answer for a lookup that genuinely fails.
check("...and the call site does not read the community off the tracked set",
      markers_src:find("tracked[tid].fcomm or nil", 1, true) == nil
      and markers_src:find("te and te.fcomm", 1, true) == nil
      and markers_src:find("merged, tkind, tcomm)", 1, true) ~= nil,
      "a community that only exists inside the scan's reach makes the tint distance-dependent")
check("...and task_goal resolves it from the server object, on its own tick",
      markers_src:find("local se = alife():object(_tk.id)", 1, true) ~= nil
      and markers_src:find("return id, pos, _tk.kind, _tk.comm", 1, true) ~= nil,
      "the server object exists whether or not the NPC is spawned -- that is the point")
check("...and a failed lookup stays nil rather than becoming false",
      markers_src:find('(okc and type(comm) == "string" and comm ~= "") and comm or nil',
                       1, true) ~= nil,
      "false means ASKED-and-unlisted, which is the amber; a failed ask must not claim it")
check("mode 2 turn-in is never the hand-in green", not same(resolve(2, "target", "trader"), BRGB.target))

-- mode 3: the marker's own colour, so no role and no community may reach a palette here
do
	local roles = {"target", "guider", "trader", "mechanic", "barman", "medic", "party"}
	local bad = nil
	for _, role in ipairs(roles) do
		for _, comm in ipairs{"dolg", "army", "trader", "stalker"} do
			if resolve(3, role, comm) ~= nil then
				bad = role .. " / " .. comm
			end
		end
	end
	check("mode 3 leaves every role on the marker's own colour", bad == nil, bad)
end
-- ...and the gate that makes that true in the game rather than only here. It was `> 0`
-- before R2.62, which is the one edit that would silently turn mode 3 into mode 1, and
-- it lived in three copies until R2.63 -- one per marker path.
check("the resolver gates the map colours on modes 1 and 2",
      markers_src:find("if bm ~= 1 and bm ~= 2 then return nil end", 1, true) ~= nil,
      "beacon_tint must not gate on `beacon_color > 0`")

-- THERE IS EXACTLY ONE RESOLVER, and this is the assertion that keeps it that way
-- (R2.63). Three paths draw markers -- the role pass, offer_task and offer_party -- and
-- each used to resolve its own colour. Two consulted beacon_color and the third did
-- not, so a SELECTED hand-in wore the map's green in the mode whose entire promise is
-- that everything is the accent, standing beside an unselected hand-in wearing the
-- accent: the same glyph, the same meaning, two colours. What is checked is therefore
-- not "the third one now has the test too" -- that would pass again the next time a
-- fourth path is written -- but that NO path outside the resolver reaches a palette.
do
	local NL = string.char(10)   -- spelt out: an escape here would end up in the pattern
	local beacon_src = slurp("gamedata/scripts/iqm_beacon.script")
	-- The offers may name BEACON_RGB in COMMENTS (they explain at length why they no
	-- longer read it), so this looks for the INDEXING, which is the thing that would
	-- resolve a colour: `BEACON_RGB[` or `BEACON_RGB.<key>` in code.
	local function body(name)
		local i = beacon_src:find("function " .. name .. "%(")
		if not i then return nil end
		local j = beacon_src:find(NL .. "end", i, true)
		return beacon_src:sub(i, j or #beacon_src)
	end
	for _, fn in ipairs{"offer_task", "offer_party"} do
		local src = body(fn)
		check(fn .. " is found", src ~= nil)
		local hit = src and (src:find("BEACON_RGB%[") or src:find("BEACON_RGB%.%a"))
		check(fn .. " resolves no colour of its own", hit == nil,
		      fn .. " must call the shared resolver, not index a palette")
		check(fn .. " calls the shared resolver",
		      src ~= nil and src:find("beacon_tint(", 1, true) ~= nil,
		      fn .. " must read iqm_core.tint()'s resolver")
	end
	-- ...and it is bound across the seam rather than reimplemented on this side.
	check("iqm_beacon binds the resolver from iqm_core",
	      beacon_src:find("beacon_tint = iqm_core.tint()", 1, true) ~= nil)
end
-- ...and the substitution itself, in the ONE place a marker reaches for the accent.
do
	local cards_src = slurp("gamedata/scripts/iqm_cards.script")
	check("draw_beacon substitutes the custom colour for the accent",
	      cards_src:find("if cfg.beacon_color == 3 then cr, cg, cb = cfg.beacon_r, cfg.beacon_g, cfg.beacon_b end",
	                     1, true) ~= nil)
	-- ...BEFORE the role colour is applied, not after: reversing the two lines would let a
	-- custom colour overwrite the map colour a role resolved, which is mode 1's job.
	local i_own = cards_src:find("cfg.beacon_color == 3", 1, true)
	local i_col = cards_src:find("if col then cr, cg, cb = col[1]", 1, true)
	check("...ahead of the resolved role colour", i_own and i_col and i_own < i_col)
end

-- THE TURN-IN FAMILY AGREES IN EVERY MODE (R2.63), which is the regression this whole
-- section exists for now. `target` is the role a pending hand-in wears; `handin` is the
-- KIND the SELECTED task wears when it is one of those hand-ins; `delivery` is the same
-- errand from the other end. All three mean REPORT BACK, the map draws ONE spot for
-- them, and the two of them that can be on screen together routinely are the first two
-- -- the task you picked, and the four other hand-ins standing around the same hub.
--
-- The bug this replaces: offer_task resolved BEACON_RGB[kind] with no mode test, so in
-- mode 0 the selected hand-in was GREEN and its neighbours were the accent. Reported
-- from play as "why are these turn-in markers different colours".
for mode = 0, 3 do
	local want = resolve(mode, "target", "dolg")
	for _, kind in ipairs{"handin", "delivery"} do
		local got = resolve(mode, kind, "dolg")
		-- `same` is false for two nils, and two nils is AGREEMENT here -- both marks take
		-- the accent, which is what modes 0 and 3 mean. Agreeing on nothing is agreeing.
		check("mode " .. mode .. ": " .. kind .. " matches the turn-in role",
		      (got == nil and want == nil) or same(got, want),
		      "a selected turn-in must not differ in colour from an unselected one")
	end
end
-- ...and specifically that mode 0 leaves the kinds on the accent, which is the exact
-- assertion that was false before R2.63 (a `nil` here is the accent).
for _, kind in ipairs{"handin", "delivery"} do
	check("mode 0 leaves " .. kind .. " on the accent", resolve(0, kind, "dolg") == nil)
end
-- The KINDS THAT ARE NOT TURN-INS keep their dressing in EVERY MODE, including the two
-- that resolve to the accent for everything else. They are the task kind speaking, not
-- the theme, and beacon_color chooses between themes.
--
-- THIS IS A REGRESSION TEST, and for a regression that shipped inside the fix for the
-- one above. R2.63 routed every key through the new mode gate, which took the bounty's
-- red away in mode 0 -- the shipped default -- and the bounty has no glyph of its own
-- on purpose ("only its colour differs"), so what was left was byte-for-byte an
-- ordinary go-find-it marker. The mutant survived it only because it has a skull.
-- Mode 3 lost the same two, contradicting a promise iqm_cards had held in writing
-- since R2.62: "a selected mutant hunt keeps its lime reticle".
for mode = 0, 3 do
	check("mode " .. mode .. " keeps the mutant lime",
	      same(resolve(mode, "mutant", "dolg"), BRGB.mutant))
	check("mode " .. mode .. " keeps the bounty red",
	      same(resolve(mode, "bounty", "dolg"), BRGB.bounty),
	      "the bounty has no glyph of its own -- gating its colour deletes the mark")
	check("mode " .. mode .. " never faction-overrides the dressing",
	      same(resolve(mode, "bounty", "dolg"), resolve(mode, "bounty", "army")))
end
-- ...and the source shape that makes it true in the game, ahead of the mode test.
do
	local i_dress = markers_src:find("if DRESSING[key] then return BEACON_RGB[key] end", 1, true)
	local i_gate  = markers_src:find("if bm ~= 1 and bm ~= 2 then return nil end", 1, true)
	check("the dressing bypasses the mode gate", i_dress ~= nil and i_gate ~= nil and i_dress < i_gate,
	      "a kind colour resolved after the gate is a kind colour the default mode eats")
end

-- guide has no colour in any mode, so it lands on the accent rather than on nil-indexed black
for mode = 0, 2 do
	check("guider stays accent in mode " .. mode, resolve(mode, "guider", "dolg") == nil)
end

-- ------------------------------------------------------------ 4. never black
-- Every combination the game can produce: a resolve must return either nil (accent) or
-- three real channels. A table with a nil in it would reach SetTextureColor as black.
do
	local roles = {"target", "guider", "trader", "mechanic", "barman", "medic"}
	local comms = {"stalker", "bandit", "dolg", "freedom", "csky", "ecolog", "killer",
	               "army", "monolith", "renegade", "greh", "isg", "zombied",
	               "trader", "actor", "monster", nil}
	local bad = nil
	for mode = 0, 2 do
		for _, role in ipairs(roles) do
			for ci = 1, #comms + 1 do
				local comm = comms[ci]           -- the last pass is deliberately nil
				local c = resolve(mode, role, comm)
				if c ~= nil then
					if type(c) ~= "table" or type(c[1]) ~= "number"
					   or type(c[2]) ~= "number" or type(c[3]) ~= "number" then
						bad = string.format("mode %d role %s comm %s", mode, role, tostring(comm))
					end
				end
			end
		end
	end
	check("no combination resolves to a partial colour", bad == nil, bad)
end

-- --------------------------------------------------------------- 5. the menu
do
	local rec = opt_row("beacon_color")
	check("beacon_color has a registry record", rec ~= nil)
	-- to "}}" and not "}": the content list's own rows are braced, so a non-greedy stop at
	-- the first brace would capture the opening of row one and none of the rows.
	local blk = rec and rec:match('content = {(.-)}%s*}')
	check("...carrying the list of modes", blk ~= nil)
	local vals, strs = {}, {}
	if blk then
		for v, s in blk:gmatch("{%s*(%d+)%s*,%s*\"([%w_]+)\"%s*}") do
			vals[#vals + 1] = tonumber(v)
			strs[#strs + 1] = s
		end
	end
	check("four modes offered", #vals == 4, "got " .. #vals)
	for i = 1, 4 do
		check("mode " .. (i - 1) .. " offered", vals[i] == i - 1)
	end

	local def = rec and rec:match("def = (%d+)")
	check("beacon_color has a default", def ~= nil)
	check("the default is a mode the list offers", def and tonumber(def) >= 0 and tonumber(def) <= 3,
	      "def = " .. tostring(def))
	-- The default is NOT the custom colour, which is the half of R2.62 that has to stay
	-- true: mode 3 ships with the accent's own channels, so a default of 3 would be
	-- invisible today and would silently become the shipped colour the first time somebody
	-- edited one of them. WHICH of the other three ships is a taste decision and has
	-- changed once already (0 until the marks got their baked keyline, 2 since -- see
	-- docs/decisions.md#beacon_color), so this does not pin it.
	check("the default is not the custom colour", def and tonumber(def) ~= 3,
	      "def = " .. tostring(def))

	-- the option is on the beacons page, or MCM writes it to a path read_config never reads
	check("beacon_color is mapped to the beacons page",
	      rec and rec:match('page = "beacons"') ~= nil)

	-- ---- the custom colour's three channels (R2.62) ----
	-- Defaults MUST equal the accent's, or choosing mode 3 would change the marker's colour
	-- by the act of choosing it -- see the note on these rows in iqm_core. Read out of the
	-- accent's own rows rather than written here twice, so retuning the gold moves both.
	local acc = {}
	for _, ch in ipairs{"r", "g", "b"} do
		local row = opt_row("col_" .. ch)
		acc[ch] = row and tonumber(row:match("def = (%d+)"))
		check("the accent's " .. ch .. " channel has a default", acc[ch] ~= nil)
	end
	for _, ch in ipairs{"r", "g", "b"} do
		local row = opt_row("beacon_" .. ch)
		check("beacon_" .. ch .. " has a registry record", row ~= nil)
		check("beacon_" .. ch .. " is mapped to the beacons page",
		      row and row:match('page = "beacons"') ~= nil)
		check("beacon_" .. ch .. " defaults to the accent's " .. ch,
		      row and tonumber(row:match("def = (%d+)")) == acc[ch],
		      "accent has " .. tostring(acc[ch]) .. ", marker has "
		      .. tostring(row and row:match("def = (%d+)")))
		-- step 1, the rule every colour channel in this mod follows
		-- (docs/decisions.md#colour-channel-step)
		check("beacon_" .. ch .. " steps by 1", row and row:match("step = 1%s*}") ~= nil)
		check("beacon_" .. ch .. " covers the full byte",
		      row and row:match("min = 0,") ~= nil and row:match("max = 255,") ~= nil)
	end

	-- both locales, caption + description + every list value, and the same for the channels
	for _, loc in ipairs{"eng", "rus"} do
		local xml = slurp("gamedata/configs/text/" .. loc .. "/st_mcm_iqm.xml")
		check(loc .. ": caption string", xml:find('"ui_mcm_iqm_beacon_color"', 1, true) ~= nil)
		check(loc .. ": description string", xml:find('"ui_mcm_iqm_beacon_color_desc"', 1, true) ~= nil)
		for _, s in ipairs(strs) do
			check(loc .. ": list string " .. s,
			      xml:find('"ui_mcm_lst_' .. s .. '"', 1, true) ~= nil)
		end
		for _, ch in ipairs{"r", "g", "b"} do
			check(loc .. ": beacon_" .. ch .. " caption",
			      xml:find('"ui_mcm_iqm_beacon_' .. ch .. '"', 1, true) ~= nil)
			check(loc .. ": beacon_" .. ch .. " description",
			      xml:find('"ui_mcm_iqm_beacon_' .. ch .. '_desc"', 1, true) ~= nil)
		end
	end
end

-- ------------------------------------------------------------------ verdict
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
