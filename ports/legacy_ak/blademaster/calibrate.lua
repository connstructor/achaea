--[[
================================================================================
BLADEMASTER SLASH DAMAGE CALIBRATOR  (per-stance, primary / secondary)
================================================================================

Blademaster slash damage VARIES BY STANCE (doya / thyr / mir / arash / sanya)
and each slash hits TWO limbs — a PRIMARY (more damage) and a SECONDARY (less).
This script switches to a stance, fires each unique slash solo, measures BOTH
limb deltas from lb[target].hits, and records them keyed to that stance. After
calibrating each stance, paste the emitted table into blademaster.limbDamage.

  legslash <t> left   -> left leg (primary)  + right leg (secondary)
  armslash <t> left   -> left arm (primary)  + right arm (secondary)
  centreslash <t> up  -> torso    (primary)  + head      (secondary)
  compassslash <t>    -> one leg  (single-limb; vestigial — not used by dispatch)

In live combat the ported triggers keep blademaster.stanceLd() auto-calibrated
for whatever stance you're in. Use this once per stance to seed real numbers.

USAGE:
  tar <some-burly-mob-or-sparring-partner>
  lua bmcal("thyr")    -- switch to thyr, run 4 tests
  lua bmcal("arash")   -- (restore target first), then arash
  lua bmcal()          -- calibrate the CURRENT stance
  lua bmcalshow()      -- print accumulated results (paste-ready blademaster.limbDamage)
  lua bmcalstop()      -- abort mid-run
  lua bmcalreset()     -- clear results

NOTES:
  - Stance switch sends the stance name (`thyr`, `arash`, …) — adjust if your
    profile uses a different command.
  - No infuse is sent (base limb damage, not ice-on-frozen bonus).
  - One stance per run; restore / re-target between stances so limbs don't break.
  - Reads lb[target].hits directly — does NOT depend on the BM capture triggers.
================================================================================
]] --

bmCal = bmCal or {}

-- {cmd, primary-limb, secondary-limb, primary-key, secondary-key}
bmCal.tests = {
  {"legslash %t left",  "left leg",  "right leg", "legPrimaryDamage",  "legSecondaryDamage"},
  {"armslash %t left",  "left arm",  "right arm", "armPrimaryDamage",  "armSecondaryDamage"},
  {"centreslash %t up", "torso",     "head",      "torsoDamage",       "headDamage"},
  {"compassslash %t",   "left leg",  nil,         "compassDamage",     nil},
}

-- Stances printed in this order; matches blademaster.STANCES.
bmCal.stanceOrder = {"doya", "thyr", "mir", "arash", "sanya"}

-- Field print order within each stance subtable.
bmCal.keyOrder = {
  "legPrimaryDamage", "legSecondaryDamage",
  "armPrimaryDamage", "armSecondaryDamage",
  "torsoDamage", "headDamage", "compassDamage",
}

bmCal.delaySeconds = 5  -- between attacks; bump if your balance is slow

-- ── runtime state ────────────────────────────────────────────
bmCal.idx      = 0
bmCal.results  = bmCal.results or {}  -- results[stance][key] = delta (persists across runs)
bmCal.running  = false
bmCal._timer   = nil
bmCal._tgt     = nil
bmCal._cur     = nil
bmCal._stance  = nil
bmCal._beforeP = 0
bmCal._beforeS = 0

-- ── helpers ──────────────────────────────────────────────────
local function readLimb(limb)
  if not limb or not bmCal._tgt or not lb or not lb[bmCal._tgt]
    or not lb[bmCal._tgt].hits then
    return 0
  end
  return lb[bmCal._tgt].hits[limb] or 0
end

local function sendAtk(stack)
  send("SETALIAS ATK " .. stack)
  send("QUEUE ADDCLEARFULL FREESTAND ATK")
end

local function normalizeStance(s)
  if type(s) ~= "string" or s == "" then return nil end
  s = s:lower()
  for _, st in ipairs(bmCal.stanceOrder) do
    if st == s then return st end
  end
  return nil
end

-- Resolve current stance from charstats if no arg given.
local function currentStance()
  if gmcp and gmcp.Char and gmcp.Char.Vitals and gmcp.Char.Vitals.charstats then
    for _, entry in ipairs(gmcp.Char.Vitals.charstats) do
      local val = entry:match("^Stance:%s*(.+)$")
      if val then return normalizeStance(val) end
    end
  end
  return nil
end

-- ── core ─────────────────────────────────────────────────────
local function fireTest(t)
  local cmd, pLimb, sLimb = t[1], t[2], t[3]
  cmd = cmd:gsub("%%t", bmCal._tgt)

  bmCal._beforeP = readLimb(pLimb)
  bmCal._beforeS = readLimb(sLimb)
  bmCal._cur = t

  cecho(string.format(
    "\n<yellow>[bmCal:%s %d/%d] %s  (P:%s=%.2f%%  S:%s=%.2f%%)",
    bmCal._stance, bmCal.idx, #bmCal.tests, cmd,
    pLimb, bmCal._beforeP, tostring(sLimb), bmCal._beforeS))

  sendAtk(cmd)
end

local function recordAndNext()
  if not bmCal.running then return end

  -- Snapshot previous test into results[stance]
  if bmCal._cur then
    local t = bmCal._cur
    local pLimb, sLimb, pKey, sKey = t[2], t[3], t[4], t[5]
    bmCal.results[bmCal._stance] = bmCal.results[bmCal._stance] or {}
    local r = bmCal.results[bmCal._stance]

    local dP = readLimb(pLimb) - bmCal._beforeP
    if pKey then r[pKey] = dP end
    local line = string.format("<green>[bmCal %s] %s P %+.2f%%", bmCal._stance, pKey, dP)
    if sLimb and sKey then
      local dS = readLimb(sLimb) - bmCal._beforeS
      r[sKey] = dS
      line = line .. string.format("  %s S %+.2f%%", sKey, dS)
    end
    cecho("\n" .. line)
  end

  -- Next, or finish this stance
  bmCal.idx = bmCal.idx + 1
  local t = bmCal.tests[bmCal.idx]
  if not t then
    bmCal.running = false
    cecho("\n<cyan>[bmCal] " .. bmCal._stance .. " stance complete.")
    cecho("\n<cyan>[bmCal] Run bmcal(\"<other-stance>\") for the next stance,")
    cecho("\n<cyan>[bmCal] or bmcalshow() for the paste-ready table.")
    return
  end

  fireTest(t)
  bmCal._timer = tempTimer(bmCal.delaySeconds, recordAndNext)
end

-- ── public API ───────────────────────────────────────────────
function bmCal.run(stanceArg)
  if not target or target == "" then
    cecho("\n<red>[bmCal] No target set. Use: tar <name>")
    return
  end
  if bmCal.running then
    cecho("\n<red>[bmCal] Already running. bmcalstop() first.")
    return
  end

  local stance = normalizeStance(stanceArg) or currentStance()
  if not stance then
    cecho("\n<red>[bmCal] Specify a stance: doya, thyr, mir, arash, sanya.")
    cecho("\n<red>       Example: lua bmcal(\"thyr\")")
    return
  end

  bmCal._tgt    = target
  bmCal._stance = stance
  bmCal.idx     = 0
  bmCal._cur    = nil
  bmCal.running = true

  cecho(string.format(
    "\n<cyan>[bmCal] %d slash tests in <yellow>%s<cyan> stance, %ds delay, target = <yellow>%s",
    #bmCal.tests, stance, bmCal.delaySeconds, bmCal._tgt))
  cecho("\n<cyan>[bmCal] Switching to " .. stance .. "...")

  -- Switch stance first, then a short delay before the first test.
  sendAtk(stance)
  bmCal._timer = tempTimer(2, recordAndNext)
end

function bmCal.stop()
  bmCal.running = false
  if bmCal._timer then
    killTimer(bmCal._timer)
    bmCal._timer = nil
  end
  cecho("\n<cyan>[bmCal] Stopped at test " .. bmCal.idx .. "/" .. #bmCal.tests
    .. " (stance: " .. tostring(bmCal._stance) .. ")")
end

function bmCal.show()
  -- Emits a COMPLETE, valid Lua table. Stances measured this session use the
  -- freshly-captured deltas; the rest fall back to their current
  -- blademaster.limbDamage values (seed or trigger-calibrated). No "??" ever,
  -- and the header lines are Lua comments — so you can copy the whole block.
  cecho("\n<cyan>-- ===================================================")
  cecho("\n<cyan>--  Blademaster per-stance slash damage")
  cecho("\n<cyan>--  Paste into your profile AFTER the module loads to override seeds.")
  cecho("\n<cyan>-- ===================================================")
  cecho("\n<white>blademaster.limbDamage = {")

  for _, stance in ipairs(bmCal.stanceOrder) do
    local measured = bmCal.results[stance] or {}
    local live = (blademaster and blademaster.limbDamage and blademaster.limbDamage[stance]) or {}
    local note = (next(measured) ~= nil) and "" or "  -- not measured this session (current values)"
    cecho("\n<white>  " .. string.format("%-6s", stance) .. " = {" .. note)
    for _, key in ipairs(bmCal.keyOrder) do
      local v = measured[key] or live[key] or 0
      cecho(string.format("\n<white>    %-19s = %.1f,", key, v))
    end
    cecho("\n<white>  },")
  end

  cecho("\n<white>}")
  cecho("\n")
end

function bmCal.reset()
  bmCal.results = {}
  bmCal._stance = nil
  bmCal.idx = 0
  bmCal._cur = nil
  cecho("\n<cyan>[bmCal] Results reset.")
end

-- ── top-level aliases (typeable from the input line) ────────
function bmcal(stance) bmCal.run(stance) end
function bmcalshow()   bmCal.show() end
function bmcalstop()   bmCal.stop() end
function bmcalreset()  bmCal.reset() end
