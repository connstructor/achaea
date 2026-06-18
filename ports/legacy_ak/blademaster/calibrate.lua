--[[
================================================================================
BLADEMASTER SLASH DAMAGE CALIBRATOR  (per stance)
================================================================================
Slash damage varies by TwoArts stance (doya / thyr / mir / arash / sanya) and each
slash hits TWO limbs — a PRIMARY (more) and a SECONDARY (less). This fires each
unique slash solo in your CURRENT stance (read from Legacy.Tannivh.stance), measures
both limb deltas from lb[target].hits, and records them keyed to that stance.

  legslash <t> left   -> left leg (primary)  + right leg (secondary)   legP / legS
  armslash <t> left   -> left arm (primary)  + right arm (secondary)   armP / armS
  centreslash <t> up  -> torso    (primary)  + head      (secondary)   torso / head
  compassslash <t> southeast -> left leg (single limb; dispatch uses it for prep correction)  compass

blademaster.CONFIG.DMG is a STATIC table (no live auto-calibration). Use this once
per stance to fill real numbers, then paste bmcalshow()'s output into your profile.

USAGE:
  tar <some-burly-mob-or-sparring-partner>
  <switch to the stance you want to measure>
  bmcal()       -- measure the 4 slashes in the CURRENT stance
  <switch stance, bmcal() again>  -- repeat per stance
  bmcalshow()   -- print a paste-ready blademaster.CONFIG.DMG (all stances)
  bmcalstop()   -- abort mid-run

NOTES:
  - No infuse is sent (base limb damage, not the ice-on-frozen bonus).
  - Reads lb[target].hits directly; switch/re-target between stances so limbs reset.
================================================================================
]]
--

bmCal = bmCal or {}

-- {cmd, primary-limb, secondary-limb, primary-key, secondary-key}
bmCal.tests = {
	{ "legslash %t left", "left leg", "right leg", "legP", "legS" },
	{ "armslash %t left", "left arm", "right arm", "armP", "armS" },
	{ "centreslash %t up", "torso", "head", "torso", "head" },
	{ "compassslash %t southeast", "left leg", nil, "compass", nil },
}

bmCal.stances = { "doya", "thyr", "mir", "arash", "sanya" }
bmCal.keyOrder = { "legP", "legS", "armP", "armS", "torso", "head", "compass" }
bmCal.delaySeconds = 5 -- between attacks; bump if your balance is slow

bmCal.results = bmCal.results or {} -- results[stance][key] = delta (persists across runs)
bmCal.idx = 0
bmCal.running = false
bmCal._timer = nil
bmCal._tgt = nil
bmCal._stance = nil
bmCal._cur = nil
bmCal._beforeP = 0
bmCal._beforeS = 0

local function currentStance()
	local f = Legacy and Legacy.Tannivh and Legacy.Tannivh.stance
	return (type(f) == "string" and f:lower()) or nil
end

local function readLimb(limb)
	if not limb or not bmCal._tgt or not lb or not lb[bmCal._tgt] or not lb[bmCal._tgt].hits then
		return 0
	end
	return lb[bmCal._tgt].hits[limb] or 0
end

local function sendAtk(stack)
	send("SETALIAS ATK " .. stack)
	send("QUEUE ADDCLEARFULL FREESTAND ATK")
end

local function fireTest(t)
	local cmd = t[1]:gsub("%%t", bmCal._tgt)
	bmCal._beforeP = readLimb(t[2])
	bmCal._beforeS = readLimb(t[3])
	bmCal._cur = t
	cecho(
		string.format(
			"\n<yellow>[bmCal:%s %d/%d] %s  (P:%s=%.2f%%  S:%s=%.2f%%)",
			bmCal._stance,
			bmCal.idx,
			#bmCal.tests,
			cmd,
			t[2],
			bmCal._beforeP,
			tostring(t[3]),
			bmCal._beforeS
		)
	)
	sendAtk(cmd)
end

local function recordAndNext()
	if not bmCal.running then
		return
	end

	if bmCal._cur then
		local pLimb, sLimb, pKey, sKey = bmCal._cur[2], bmCal._cur[3], bmCal._cur[4], bmCal._cur[5]
		bmCal.results[bmCal._stance] = bmCal.results[bmCal._stance] or {}
		local r = bmCal.results[bmCal._stance]
		local dP = readLimb(pLimb) - bmCal._beforeP
		r[pKey] = dP
		local line = string.format("<green>[bmCal %s] %s P %+.2f%%", bmCal._stance, pKey, dP)
		if sLimb and sKey then
			local dS = readLimb(sLimb) - bmCal._beforeS
			r[sKey] = dS
			line = line .. string.format("  %s S %+.2f%%", sKey, dS)
		end
		cecho("\n" .. line)
	end

	bmCal.idx = bmCal.idx + 1
	local t = bmCal.tests[bmCal.idx]
	if not t then
		bmCal.running = false
		cecho("\n<cyan>[bmCal] " .. bmCal._stance .. " done. bmcal() in another stance, or bmcalshow() to print.")
		return
	end

	fireTest(t)
	bmCal._timer = tempTimer(bmCal.delaySeconds, recordAndNext)
end

function bmCal.run()
	if not target or target == "" then
		cecho("\n<red>[bmCal] No target set. Use: tar <name>")
		return
	end
	if bmCal.running then
		cecho("\n<red>[bmCal] Already running. bmcalstop() first.")
		return
	end
	local stance = currentStance()
	if not stance then
		cecho("\n<red>[bmCal] Can't read Legacy.Tannivh.stance — switch into a stance first.")
		return
	end

	bmCal._tgt = target
	bmCal._stance = stance
	bmCal.idx = 0
	bmCal._cur = nil
	bmCal.running = true

	cecho(
		string.format(
			"\n<cyan>[bmCal] %d slash tests in <yellow>%s<cyan>, %ds delay, target = <yellow>%s",
			#bmCal.tests,
			stance,
			bmCal.delaySeconds,
			bmCal._tgt
		)
	)
	recordAndNext() -- fires the first test (nothing to record yet)
end

function bmCal.stop()
	bmCal.running = false
	if bmCal._timer then
		killTimer(bmCal._timer)
		bmCal._timer = nil
	end
	cecho(
		"\n<cyan>[bmCal] Stopped at test "
			.. bmCal.idx
			.. "/"
			.. #bmCal.tests
			.. " (stance: "
			.. tostring(bmCal._stance)
			.. ")"
	)
end

function bmCal.show()
	-- Complete, valid table: stances measured this session use captured deltas; the rest
	-- fall back to the current blademaster.CONFIG.DMG values. Header lines are comments.
	cecho("\n<cyan>-- paste AFTER the module loads to override the static seeds:")
	cecho("\n<white>blademaster.CONFIG.DMG = {")
	for _, stance in ipairs(bmCal.stances) do
		local measured = bmCal.results[stance] or {}
		local live = (blademaster and blademaster.CONFIG and blademaster.CONFIG.DMG and blademaster.CONFIG.DMG[stance])
			or {}
		local note = (next(measured) ~= nil) and "" or "  -- not measured this session (current values)"
		cecho("\n<white>  " .. string.format("%-6s", stance) .. " = {" .. note)
		for _, key in ipairs(bmCal.keyOrder) do
			local v = measured[key] or live[key] or 0
			cecho(string.format("\n<white>    %-8s = %.1f,", key, v))
		end
		cecho("\n<white>  },")
	end
	cecho("\n<white>}\n")
end

-- top-level aliases (typeable from the input line)
function bmcal()
	bmCal.run()
end
function bmcalshow()
	bmCal.show()
end
function bmcalstop()
	bmCal.stop()
end
