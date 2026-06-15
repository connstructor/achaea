--[[
================================================================================
SHIKUDO LIMB DAMAGE CALIBRATOR
================================================================================

Fires every unique Shikudo limb-damage attack once at the current target,
measures the delta in lb[target].hits[limb], and prints a paste-ready table
for monk.shikudo.limbDamage.

USAGE:
  tar <some-burly-mob-or-sparring-partner>
  lua skcal()           -- start
  lua skcalshow()       -- reprint last results
  lua skcalstop()       -- abort mid-run

WHAT IT DOES:
  1. Clears hyperfocus (so values aren't halved).
  2. For each test: adopt form, wait for the form-switch balance
     (default 4.1s), snapshot limb damage, fire `combo target <attack>`,
     wait 5s, read lb damage delta.
  3. Prints a Lua table at the end you can paste over the existing
     monk.shikudo.limbDamage definition.

NOTES:
  - Pick a target that won't die or fight back. Damage will accumulate
    across the run — that's fine, we measure deltas.
  - Spinkick is omitted (it requires prone). The dispatch system uses
    the historical 27% value for prone-head; calibrate manually if
    you want a precise number (sweep first, then spinkick).
  - If an attack is parried/missed/healed, its delta will be 0 or
    negative. Re-run that one manually with `skcal` after fixing.
================================================================================
]]--

skCalibrate = skCalibrate or {}

-- {form, full attack command, name-for-table-key, limb-where-damage-lands}
skCalibrate.tests = {
  -- Tykonos
  {"Tykonos",   "thrust right arm",   "thrust",       "right arm"},
  {"Tykonos",   "risingkick head",    "risingkick",   "head"},
  -- Willow
  {"Willow",    "hiru",               "hiru",         "head"},
  {"Willow",    "hiraku",             "hiraku",       "head"},
  {"Willow",    "dart torso",         "dart",         "torso"},
  {"Willow",    "flashheel right",    "flashheel",    "right leg"},
  -- Rain
  {"Rain",      "kuro right",         "kuro",         "right leg"},
  {"Rain",      "ruku torso",         "ruku",         "torso"},
  {"Rain",      "frontkick right",    "frontkick",    "right arm"},
  -- Oak
  {"Oak",       "nervestrike",        "nervestrike",  "head"},
  {"Oak",       "livestrike",         "livestrike",   "torso"},
  -- Gaital
  {"Gaital",    "needle",             "needle",       "head"},
  {"Gaital",    "jinzuku",            "jinzuku",      "torso"},
}

skCalibrate.formSwitchDelaySeconds = skCalibrate.formSwitchDelaySeconds or 4.1
skCalibrate.delaySeconds = skCalibrate.delaySeconds or 5  -- after each combo; bump if your eq is slow

skCalibrate.defaultDamage = skCalibrate.defaultDamage or {
  flashheel = 9.2,
  frontkick = 9.2,
  risingkick = 9.2,
  spinkick = 27.0,

  kuro = 9.2,
  ruku = 9.2,
  thrust = 14.5,
  needle = 14.6,
  nervestrike = 13.4,
  livestrike = 13.4,
  hiru = 9.4,
  hiraku = 9.4,
  dart = 7.3,
  jinzuku = 9.2,
}

skCalibrate.outputOrder = {
  kicks = {"flashheel", "frontkick", "risingkick", "spinkick"},
  staff = {"kuro", "ruku", "thrust", "needle", "nervestrike",
           "livestrike", "hiru", "hiraku", "dart", "jinzuku"}
}

-- ── runtime state ────────────────────────────────────────────
skCalibrate.idx     = 0
skCalibrate.results = {}
skCalibrate.running = false
skCalibrate._timer  = nil
skCalibrate._tgt    = nil
skCalibrate._before = 0
skCalibrate._cur    = nil

-- ── helpers ──────────────────────────────────────────────────
local function readLimb(limb)
  if not skCalibrate._tgt or not lb or not lb[skCalibrate._tgt]
  or not lb[skCalibrate._tgt].hits then
    return 0
  end
  return lb[skCalibrate._tgt].hits[limb] or 0
end

local function sendAtk(stack, queueType)
  send("SETALIAS ATK " .. stack)
  send("QUEUE ADDCLEARFULL " .. (queueType or "FREE") .. " ATK")
end

local function loadedDamage(name)
  local tableRef = monk and monk.shikudo and monk.shikudo.limbDamage
  local value = tableRef and tableRef[name]
  if type(value) == "number" then return value end
  return skCalibrate.defaultDamage[name]
end

local function outputDamage(name)
  local result = skCalibrate.results[name]
  if type(result) == "number" and result > 0 then
    return result, ""
  end

  local fallback = loadedDamage(name) or 0
  if result == nil then
    return fallback, " -- unchanged; no calibration result"
  end
  return fallback, " -- unchanged; invalid calibration result was " .. string.format("%.1f", result)
end

local function printDamageLine(name)
  local value, note = outputDamage(name)
  cecho(string.format("\n  %-12s = %.1f,%s", name, value, note))
end

-- ── core ─────────────────────────────────────────────────────
local recordAndNext

local function fireCombo()
  if not skCalibrate.running or not skCalibrate._cur then return end

  local cur = skCalibrate._cur
  skCalibrate._before = readLimb(cur.limb)

  cecho(string.format(
    "\n<yellow>[skCal %d/%d] %s | combo %s %s -> %s (before: %.2f%%)",
    skCalibrate.idx, #skCalibrate.tests, cur.form,
    skCalibrate._tgt, cur.cmd, cur.limb, skCalibrate._before))

  sendAtk("combo " .. skCalibrate._tgt .. " " .. cur.cmd, "FREE")
  skCalibrate._timer = tempTimer(skCalibrate.delaySeconds, recordAndNext)
end

local function fireTest(t)
  local form, cmd, name, limb = t[1], t[2], t[3], t[4]
  skCalibrate._cur = {form = form, cmd = cmd, name = name, limb = limb}

  cecho(string.format(
    "\n<yellow>[skCal %d/%d] switching to %s; firing %s in %.1fs",
    skCalibrate.idx, #skCalibrate.tests, form, cmd,
    skCalibrate.formSwitchDelaySeconds))

  -- Always adopt and wait; without enough kata, form switching costs balance.
  sendAtk("adopt " .. form .. " form", "EQBAL")
  skCalibrate._timer = tempTimer(skCalibrate.formSwitchDelaySeconds, fireCombo)
end

recordAndNext = function()
  if not skCalibrate.running then return end

  -- Snapshot previous test
  if skCalibrate._cur then
    local after = readLimb(skCalibrate._cur.limb)
    local delta = after - skCalibrate._before
    skCalibrate.results[skCalibrate._cur.name] = delta
    local color = (delta > 0) and "<green>" or "<red>"
    cecho(string.format(
      "\n" .. color .. "[skCal %s] delta %+.2f%% (after: %.2f%%)",
      skCalibrate._cur.name, delta, after))
  end

  -- Next, or finish
  skCalibrate.idx = skCalibrate.idx + 1
  local t = skCalibrate.tests[skCalibrate.idx]
  if not t then
    skCalibrate.running = false
    skCalibrate.show()
    return
  end

  fireTest(t)
end

-- ── public API ───────────────────────────────────────────────
function skCalibrate.run()
  if not target or target == "" then
    cecho("\n<red>[skCal] No target set. Use: tar <name>")
    return
  end
  if skCalibrate.running then
    cecho("\n<red>[skCal] Already running. skcalstop() first.")
    return
  end

  skCalibrate._tgt    = target
  skCalibrate.idx     = 0
  skCalibrate.results = {}
  skCalibrate._cur    = nil
  skCalibrate.running = true

  cecho(string.format(
    "\n<cyan>[skCal] %d tests, %.1fs form delay, %ds hit delay, target = <yellow>%s",
    #skCalibrate.tests, skCalibrate.formSwitchDelaySeconds,
    skCalibrate.delaySeconds, skCalibrate._tgt))
  cecho("\n<cyan>[skCal] Clearing hyperfocus...")

  -- Clear hyperfocus so damage isn't halved on the focused limb.
  send("hyperfocus none")

  -- Small startup delay so hyperfocus-none lands before the first attack.
  skCalibrate._timer = tempTimer(2, recordAndNext)
end

function skCalibrate.stop()
  skCalibrate.running = false
  if skCalibrate._timer then
    killTimer(skCalibrate._timer)
    skCalibrate._timer = nil
  end
  cecho("\n<cyan>[skCal] Stopped at test " .. skCalibrate.idx .. "/" .. #skCalibrate.tests)
end

function skCalibrate.show()
  cecho("\n<cyan>====================================================")
  cecho("\n<cyan>  Shikudo limb damage — paste into monk.shikudo.limbDamage")
  cecho("\n<cyan>====================================================")
  cecho("\nmonk = monk or {}")
  cecho("\nmonk.shikudo = monk.shikudo or {}")
  cecho("\nmonk.shikudo.limbDamage = {")
  cecho("\n  -- Kicks")
  for _, name in ipairs(skCalibrate.outputOrder.kicks) do
    if name == "spinkick" then
      local value = loadedDamage(name) or 27.0
      cecho(string.format("\n  %-12s = %.1f, -- unchanged; requires prone/manual calibration", name, value))
    else
      printDamageLine(name)
    end
  end
  cecho("\n  -- Staff strikes")
  for _, name in ipairs(skCalibrate.outputOrder.staff) do
    printDamageLine(name)
  end
  cecho("\n}")
  cecho("\n")
end

-- ── top-level aliases (typeable from the input line) ────────
function skcal()      skCalibrate.run()  end
function skcalshow()  skCalibrate.show() end
function skcalstop()  skCalibrate.stop() end
