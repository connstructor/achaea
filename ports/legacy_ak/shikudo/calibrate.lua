--[[
================================================================================
SHIKUDO LIMB-DAMAGE CALIBRATOR
================================================================================
Limb damage scales with your stats + staff artifact, so monk.shikudo.limbDamage
must be MEASURED, not guessed. This fires each limb-damaging Shikudo attack solo,
reads the delta from lb[target].hits, and records it. The attacks live in
different forms, so run it once per form (it only fires the attacks available in
your CURRENT form), then paste skcalshow()'s output over the table in shikudo.lua.

  flashheel   -> leg    (Willow, Gaital)
  kuro        -> leg    (Rain, Oak, Gaital)
  frontkick   -> arm    (Rain)
  ruku        -> arm    (Rain, Oak, Gaital, Maelstrom)
  risingkick  -> head   (Tykonos, Oak, Maelstrom)
  nervestrike -> head   (Oak)
  hiru        -> head   (Willow, Rain)
  hiraku      -> head   (Willow)
  needle      -> head   (Gaital)

USAGE:
  tar <a sturdy sparring partner / mob>   -- fresh, limbs near 0%
  <adopt a form> ; skcal()                -- measures that form's attacks
  <adopt next form> ; skcal()             -- repeat across Willow / Rain / Oak / Gaital
  skcalshow()                             -- print a paste-ready limbDamage table
  skcalstop()                             -- abort a run

To cover all 9: Willow (flashheel, hiru, hiraku), Rain (kuro, ruku, frontkick),
Oak (nervestrike, risingkick), Gaital (needle).

NOTES:
  - Sends `hyperfocus none` first: hyperfocus HALVES damage to the focused limb,
    which would skew the head numbers. The engine's break math assumes UNFOCUSED
    damage, so that's what we measure.
  - Reads lb[target].hits directly. Re-target / use a fresh limb between forms so
    nothing is already near 100% (a broken limb stops registering new damage).
================================================================================
]]
--

skCal = skCal or {}

-- {key, combo command (%t = target), limb measured, set of forms where available}
skCal.tests = {
	{ "flashheel", "combo %t flashheel left", "left leg", { Willow = true, Gaital = true } },
	{ "kuro", "combo %t kuro left", "left leg", { Rain = true, Oak = true, Gaital = true } },
	{ "frontkick", "combo %t frontkick left", "left arm", { Rain = true } },
	{
		"ruku",
		"combo %t ruku left",
		"left arm",
		{ Rain = true, Oak = true, Gaital = true, Maelstrom = true },
	},
	{ "risingkick", "combo %t risingkick head", "head", { Tykonos = true, Oak = true, Maelstrom = true } },
	{ "nervestrike", "combo %t nervestrike", "head", { Oak = true } },
	{ "hiru", "combo %t hiru", "head", { Willow = true, Rain = true } },
	{ "hiraku", "combo %t hiraku", "head", { Willow = true } },
	{ "needle", "combo %t needle", "head", { Gaital = true } },
}

skCal.keyOrder = { "flashheel", "kuro", "frontkick", "ruku", "risingkick", "nervestrike", "hiru", "hiraku", "needle" }
skCal.delaySeconds = 3 -- between attacks; bump if your balance is slow

skCal.results = skCal.results or {} -- results[key] = delta %, persists across per-form runs
skCal.queue = {}
skCal.idx = 0
skCal.running = false
skCal._timer = nil
skCal._tgt = nil
skCal._cur = nil
skCal._before = 0

local function calForm()
	local cs = gmcp and gmcp.Char and gmcp.Char.Vitals and gmcp.Char.Vitals.charstats
	if not cs then
		return nil
	end
	for _, entry in ipairs(cs) do
		local v = tostring(entry):match("^Form: (.+)$")
		if v then
			return (v:gsub("%s+$", ""))
		end
	end
	return nil
end

local function readLimb(limb)
	if not limb or not skCal._tgt or not lb or not lb[skCal._tgt] or not lb[skCal._tgt].hits then
		return 0
	end
	return lb[skCal._tgt].hits[limb] or 0
end

local function sendAtk(stack)
	send("SETALIAS SKCAL " .. stack)
	send("QUEUE ADDCLEARFULL EQBAL SKCAL")
end

local function fireTest(t)
	skCal._cur = t
	skCal._before = readLimb(t[3])
	local cmd = t[2]:gsub("%%t", skCal._tgt)
	cecho(
		string.format("\n<yellow>[skcal %d/%d] %s  (%s now %.2f%%)", skCal.idx, #skCal.queue, cmd, t[3], skCal._before)
	)
	sendAtk(cmd)
end

local function recordAndNext()
	if not skCal.running then
		return
	end

	if skCal._cur then
		local key, limb = skCal._cur[1], skCal._cur[3]
		local delta = readLimb(limb) - skCal._before
		skCal.results[key] = delta
		cecho(string.format("\n<green>[skcal] %-11s %+.2f%%  (%s)", key, delta, limb))
	end

	skCal.idx = skCal.idx + 1
	local t = skCal.queue[skCal.idx]
	if not t then
		skCal.running = false
		cecho("\n<cyan>[skcal] done. Switch form + skcal() again, or skcalshow() to print.")
		return
	end
	fireTest(t)
	skCal._timer = tempTimer(skCal.delaySeconds, recordAndNext)
end

function skCal.run()
	if not target or target == "" then
		cecho("\n<red>[skcal] No target set. Use: tar <name>")
		return
	end
	if skCal.running then
		cecho("\n<red>[skcal] Already running. skcalstop() first.")
		return
	end
	local form = calForm()
	if not form then
		cecho("\n<red>[skcal] Can't read your Form from gmcp charstats — adopt a form first.")
		return
	end

	-- Only the attacks available in the current form.
	skCal.queue = {}
	for _, t in ipairs(skCal.tests) do
		if t[4][form] then
			skCal.queue[#skCal.queue + 1] = t
		end
	end
	if #skCal.queue == 0 then
		cecho(
			"\n<yellow>[skcal] No measurable attacks in <cyan>" .. form .. "<yellow>. Try Willow / Rain / Oak / Gaital."
		)
		return
	end

	skCal._tgt = target
	skCal.idx = 0
	skCal._cur = nil
	skCal.running = true

	send("hyperfocus none") -- measure UNFOCUSED damage (hyperfocus halves the focused limb)
	cecho(
		string.format(
			"\n<cyan>[skcal] %d attack(s) in <yellow>%s<cyan>, %ds apart, target = <yellow>%s",
			#skCal.queue,
			form,
			skCal.delaySeconds,
			skCal._tgt
		)
	)
	recordAndNext() -- fires the first test (nothing to record yet)
end

function skCal.stop()
	skCal.running = false
	if skCal._timer then
		killTimer(skCal._timer)
		skCal._timer = nil
	end
	cecho("\n<cyan>[skcal] Stopped at " .. skCal.idx .. "/" .. #skCal.queue)
end

function skCal.show()
	cecho("\n<cyan>-- Paste over the mod.limbDamage table in shikudo.lua. Measured attacks use")
	cecho("\n<cyan>-- this session's deltas; the rest keep their current value.")
	cecho("\n<white>mod.limbDamage = {")
	local live = (monk and monk.shikudo and monk.shikudo.limbDamage) or {}
	for _, key in ipairs(skCal.keyOrder) do
		local measured = skCal.results[key]
		local v = measured or live[key] or 0
		local note = measured and "" or "   -- not measured this session"
		cecho(string.format("\n<white>    %-11s = %5.2f,%s", key, v, note))
	end
	cecho("\n<white>}\n")
end

-- top-level aliases (typeable from the input line)
function skcal()
	skCal.run()
end
function skcalshow()
	skCal.show()
end
function skcalstop()
	skCal.stop()
end
