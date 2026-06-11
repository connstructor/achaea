--[[
================================================================================
BLADEMASTER UNIFIED OFFENSE — LEGACY / AK PORT
================================================================================

Port of the LEVI/Ataxia Blademaster Ice-Dispatch system:
  - src_new/scripts/.../blademaster/005_CC_BM_Ice.lua  (source of truth)

The legacy 001-004 files (bmstriking / bm_attack / bm_brokenstarroute /
bm_groupfighting + bmgrouplock / levibmtruelock) are the pre-consolidation
implementation. 001/002/003 are isActive:'no'; 004 is active but depends on
001's inactive bmgrouplock(). All four are superseded by 005's four strategies
and are NOT ported (see DEPENDENCIES.md).

Four strategies, one file (set via blademaster.state.mode, routed by run()):
  bmd   / bmdispatch      -> "double"     legs only: prep both legs -> double-break + KNEES -> mangle
  bmdq  / bmdispatchquad  -> "quad"       arms+legs: prep arms -> prep legs -> flamefist -> break arms -> break legs -> mangle
  bmbs  / bmdispatchbs    -> "brokenstar" upper+legs -> impale -> impaleslash -> bladetwist -> withdraw -> BROKENSTAR (bleed kill)
  bmgroup                 -> "group"      pommelstrike affliction lock (ice infuse)

Alias handlers (create the matching Mudlet aliases by hand — see MUDLET_SETUP.md):
  bm()                    -- arm in current mode (fires now if eqbal up, else on bal/eq return)
  bmd() / bmdq() / bmbs() / bmgroup()
  bmstatus() / bmstatusq()
  bmreset()

Trigger model: aliases ARM the system; a balance/equilibrium-used trigger calls
blademaster.scheduleDispatch(<recover time>), which fires the dispatch on a
tempTimer timed to balance/eq return (so it runs with current state). This module
self-registers NOTHING — all aliases, triggers, and that one required used-trigger
are created manually in Mudlet per MUDLET_SETUP.md.

Public API (everything else is file-local):
  blademaster.CONFIG       table  — tunables (thresholds, durations, lock-break cmd, debug)
  blademaster.state        table  — runtime mutable state (phase tracking, brokenstar state)
  blademaster.limbDamage   table  — per-STANCE per-hit damage subtables (doya/thyr/mir/arash/sanya);
                                    self-calibrated from triggers, calibrate with `bmcal`
  blademaster.dispatch     table  — namespace for run*/status* functions
  blademaster.getStance()         — current stance name (lowercased) or defaultStance
  blademaster.stanceLd()          — current stance's damage subtable (all dmg reads route here)
  blademaster.setMode(m)          — set "double"|"quad"|"brokenstar"|"group"
  blademaster.run()               — unified entry (guards + mode routing)
  blademaster.fullReset()         — reset all state
  blademaster.on*/capture* (...)  — trigger callbacks (point Mudlet triggers here)

--------------------------------------------------------------------------------
DEPENDENCY MAPPING (see ports/legacy_ak/blademaster/DEPENDENCIES.md)
--------------------------------------------------------------------------------
Tier 1 — AK (target state):
  haveAff("X")                  -> has("X")  (affstrack.score[X] >= CONFIG.affThreshold)
  getAffProbabilityV3 / getTrackingSystem -> dropped (getTrackingSystem() now returns "AK")
  lb[target].hits[limb]         -> unchanged (raw target key, AK convention)
  tparrying / ataxiaTemp.parriedLimb -> targetparry (global; AK reports no-space
                                        limb names, normalized to spaced in getParried)
  tmounted                      -> has("mounted")
  ataxiaTemp.targetHP           -> targetHpPct()  (ak.currenthealth/maxhealth*100)
  tAffs / tAffs.shield fallback -> dropped (no V1 table in AK; has() reads affstrack)
  ataxia.playersHere            -> dropped (trust the user's `tar X`)

Tier 2 — Legacy (self state):
  ataxia.afflictions.aeon       -> selfAff("aeon")  (Legacy.Curing.Affs.aeon)
  ataxia_needLockBreak/Break    -> selfNeedLockBreak()/selfLockBreak()  (CONFIG.lockBreakCommand)
  reboundHold.gate(fn)          -> blademaster.reboundGate(fn) (stub; user-override)
  combatQueue()                 -> removed (Legacy handles pre-attack hooks externally)
  send("queue addclear freestand "..cmd) -> sendAttack(cmd, "FREESTAND")  (SETALIAS/QUEUE pattern)
  engaged (global)              -> blademaster.state.engaged (reset on target change)
  gmcp Char.Vitals.charstats "Shin:" -> getShin() (unchanged; pure GMCP)
  getLockingAffliction()        -> kept, guarded (graceful no-op if absent — group mode only)

External globals (unchanged): gmcp, ak, Legacy, target, lb, affstrack, targetparry, matches
================================================================================
]] --

-- ============================================================
--  NAMESPACE INIT
-- ============================================================
blademaster = blademaster or {}
blademaster.dispatch = blademaster.dispatch or {}

blademaster.state = {
  -- Mode & dispatch state
  mode = "double",            -- "double", "quad", "brokenstar", "group"
  armed = false,              -- JIT dispatch: alias arms; timer fires on bal/eq return
  dispatchTimer = nil,        -- tempTimer id for the pending dispatch
  engaged = false,            -- Engage-on-first-attack flag (reset on target change)
  lastTarget = nil,           -- Target-change detection
  lastEchoTime = nil,         -- Debounced echo timestamp
  -- Leg / arm tracking (per-hit damage now lives in blademaster.limbDamage[stance])
  focusLeg = nil,
  lastPrimaryLeg = nil,
  focusArm = nil,
  lastPrimaryArm = nil,
  -- Prone timer tracking (Double-Prep mangle phase; vestigial — balanceslash removed)
  proneTimerStart = nil,
  proneAttackCount = 0,
  proneTimerActive = false,
  -- Brokenstar tracking
  isImpaled = false,
  impaleslashDone = false,
  secondImpale = false,
  bleedingReady = false,
  targetBleeding = 0,
  withdrawDone = false,
  bladetwistCount = 0,
  -- Flamefist tracking (Quad-Prep ice path)
  flamefistDone = false,
  -- Other
  lastHamstringTime = 0,
}

-- ============================================================
--  CONFIG  (all tunables consolidated)
-- ============================================================
blademaster.CONFIG = blademaster.CONFIG or {
  -- AK affstrack confidence threshold (0-100).
  affThreshold = 30,

  -- Limb damage thresholds.
  breakThreshold = 100,
  prepThreshold = 90,

  -- Misc combat tunables.
  killHealthThreshold = 30,
  hamstringDuration = 10,          -- seconds; re-strike hamstring after this
  proneTimerDuration = 9,          -- seconds (vestigial prone window)
  balanceslashThreshold = 4,       -- vestigial (balanceslash never selected)
  brokenstarBleedThreshold = 700,  -- bleeding level for brokenstar execution

  -- Airfist requirement: 20 shin + 5 for infuse = 25.
  airfistShinCost = 25,

  -- Self lock-break (asthma+anorexia+slickness). Blademaster's Striking
  -- Fitness cures asthma; override to a tree-tattoo etc. if you prefer.
  lockBreakCommand = "fitness",
  lockBreakCooldown = 2,           -- seconds between lock-break attempts

  -- Echo debounce window (seconds) + debug toggle.
  echoDebounce = 0.3,
  debugEcho = true,

  -- Legacy queue dispatch.
  queueType = "FREESTAND",
  engageOnFirst = true,            -- append ";engage <target>" on first attack

  -- Just-in-time dispatch (arm -> fire on balance/eq return).
  latencyMultiplier = 2,           -- dispatch delay = recoverTime - getNetworkLatency()*this
  minDispatchDelay  = 0.1,         -- floor for the dispatch timer (seconds)
  fireWhenReady     = true,        -- arm() fires now if eqbal (balance AND eq) is up
}

-- ============================================================
--  AK HELPERS  (target state)
-- ============================================================
local function has(aff)
  return affstrack and affstrack.score
    and (affstrack.score[aff] or 0) >= blademaster.CONFIG.affThreshold
end

local function targetHpPct()
  if not ak or not ak.maxhealth or ak.maxhealth <= 0 then return 100 end
  return math.floor((ak.currenthealth or 0) / ak.maxhealth * 100)
end

-- ============================================================
--  GMCP HELPERS  (Char.Vitals + Char.Vitals.charstats)
-- ============================================================
local function charstat(name)
  local cs = gmcp and gmcp.Char and gmcp.Char.Vitals and gmcp.Char.Vitals.charstats
  if not cs then return nil end
  local prefix = name .. ":"
  for _, entry in ipairs(cs) do
    local val = entry:match("^" .. prefix .. "%s*(.+)$")
    if val then
      val = val:gsub("%%", "")
      return tonumber(val) or val
    end
  end
  return nil
end

local function vital(key)
  return tonumber(gmcp and gmcp.Char and gmcp.Char.Vitals and gmcp.Char.Vitals[key]) or 0
end

local function eqUp()
  return gmcp and gmcp.Char and gmcp.Char.Vitals and gmcp.Char.Vitals.eq == "1"
end

local function balUp()
  return gmcp and gmcp.Char and gmcp.Char.Vitals and gmcp.Char.Vitals.bal == "1"
end

-- Both balance AND equilibrium up = fully ready to act ("eqbal").
local function eqbalUp()
  return balUp() and eqUp()
end

-- ============================================================
--  STANCE-AWARE PER-HIT LIMB DAMAGE
--  Blademaster slash damage VARIES BY STANCE (doya/thyr/mir/arash/sanya):
--  thyr reduced < mir/sanya normal < doya increased < arash highest. Each
--  stance has its own P/S (primary/secondary) damage subtable. Values seed
--  identically and self-calibrate per stance from the capture triggers; run
--  `bmcal` (ports/.../calibrate.lua) in each stance to set real numbers.
--  Keyed by lowercased charstat("Stance"); falls back to defaultStance.
--  `or`-guarded so calibrated values survive a script reload.
-- ============================================================
do
  local function seed()
    return {
      legPrimaryDamage = 17.3, legSecondaryDamage = 11.5,
      armPrimaryDamage = 17.3, armSecondaryDamage = 11.5,
      torsoDamage      = 18.1, headDamage         = 12.1,
      compassDamage    = 14.9,
    }
  end
  blademaster.limbDamage = blademaster.limbDamage or {
    doya  = seed(),  -- increased limb damage
    thyr  = seed(),  -- reduced (primary 1v1 stance)
    mir   = seed(),  -- normal (defensive)
    arash = seed(),  -- highest per hit (burst)
    sanya = seed(),  -- normal (shin generation)
  }
end

blademaster.STANCES = {"doya", "thyr", "mir", "arash", "sanya"}
blademaster.defaultStance = "thyr"  -- fallback when stance is unknown / unstanced

-- Current stance name (lowercased), or the default fallback.
function blademaster.getStance()
  local s = charstat("Stance")
  s = (type(s) == "string" and s:lower()) or nil
  if s and blademaster.limbDamage[s] then return s end
  return blademaster.defaultStance
end

-- Current stance's per-hit damage subtable. All damage reads/writes route here,
-- so prep/break/path math uses the active stance's numbers.
function blademaster.stanceLd()
  return blademaster.limbDamage[blademaster.getStance()]
    or blademaster.limbDamage[blademaster.defaultStance]
end

-- ============================================================
--  SELF STATE  (Legacy domain)
-- ============================================================
local _lockBreakCooldown = 0

local function selfAff(name)
  local a = Legacy and Legacy.Curing and Legacy.Curing.Affs
  return a and a[name]
end

local function selfNeedLockBreak()
  return selfAff("asthma")
    and selfAff("anorexia")
    and (selfAff("slickness") or selfAff("bloodfire"))
end

local function selfLockBreak()
  if os.time() < _lockBreakCooldown then return false end
  if not selfNeedLockBreak() then return false end
  if selfAff("prone") and not selfAff("paralysis") then
    send("stand", false)
  end
  send(blademaster.CONFIG.lockBreakCommand, false)
  _lockBreakCooldown = os.time() + blademaster.CONFIG.lockBreakCooldown
  return true
end

-- Rebound-hold gate. Default never holds; override to delegate to your own
-- rebound-hold module:  blademaster.reboundGate = function(fn) ... end
function blademaster.reboundGate(_)
  return false
end

-- Paused check (Legacy curing toggle).
local function isPaused()
  return Legacy and Legacy.Settings and Legacy.Settings.Curing
    and Legacy.Settings.Curing.status == false
end

-- ============================================================
--  SEND HELPER  (Legacy SETALIAS ATK / QUEUE ADDCLEARFULL pattern)
--  Folds in self lock-break gate + engage-on-first (source sendAttack).
-- ============================================================
local function sendAttack(cmd, queueType)
  if not cmd or cmd == "" then return end

  -- Self lock-break gate (was ataxia_needLockBreak/ataxia_lockBreak).
  if selfNeedLockBreak() then
    selfLockBreak()
    return
  end

  -- Engage on first attack (source behavior; configurable).
  if blademaster.CONFIG.engageOnFirst and not blademaster.state.engaged and target and target ~= "" then
    cmd = cmd .. ";engage " .. target
    blademaster.state.engaged = true
  end

  send("SETALIAS ATK " .. cmd)
  send("QUEUE ADDCLEARFULL " .. (queueType or blademaster.CONFIG.queueType) .. " ATK")
end

-- ============================================================
--  AFFLICTION TRACKING (routes to AK has())
-- ============================================================
function blademaster.hasAff(aff)
  return has(aff)
end

-- Tracking system label (was V3; AK now).
function blademaster.getTrackingSystem()
  return "AK"
end

-- ============================================================
--  ECHO DEBOUNCE (0.3s guard prevents spam on rapid mashing)
-- ============================================================
function blademaster.shouldEcho()
  if not blademaster.CONFIG.debugEcho then return false end
  local now = getEpoch()
  if not blademaster.state.lastEchoTime
    or (now - blademaster.state.lastEchoTime) > blademaster.CONFIG.echoDebounce then
    blademaster.state.lastEchoTime = now
    return true
  end
  return false
end

-- ============================================================
--  INFUSE COMMAND (consumed per attack — re-send every round)
-- ============================================================
function blademaster.infuseCmd(infuseType)
  return "infuse " .. infuseType .. ";"
end

-- ============================================================
--  FULL RESET
-- ============================================================
function blademaster.fullReset()
  blademaster.state.mode = "double"
  blademaster.state.armed = false
  if blademaster.state.dispatchTimer then
    killTimer(blademaster.state.dispatchTimer)
    blademaster.state.dispatchTimer = nil
  end
  blademaster.state.engaged = false
  blademaster.state.lastTarget = nil
  blademaster.state.lastEchoTime = nil
  blademaster.state.flamefistDone = false
  blademaster.resetBrokenstarState()
  blademaster.resetProneTimer()
  cecho("\n<green>[BM] Full state reset!")
end

function blademaster.setMode(mode)
  local valid = {double = true, quad = true, brokenstar = true, group = true}
  if valid[mode] then
    blademaster.state.mode = mode
    cecho("\n<yellow>[BM] Mode set to: <cyan>" .. mode)
  else
    cecho("\n<red>[BM] Invalid mode. Use: double, quad, brokenstar, group")
  end
end

-- ============================================================
--  LB LIMB TRACKING HELPERS
--  AK keys lb by the raw target string (no capitalization).
-- ============================================================
function blademaster.getLimbDamage(limb)
  if not lb or not target or target == "" then return 0 end
  if not lb[target] or not lb[target].hits then return 0 end
  return lb[target].hits[limb] or 0
end

function blademaster.getLL() return blademaster.getLimbDamage("left leg") end
function blademaster.getRL() return blademaster.getLimbDamage("right leg") end
function blademaster.getLA() return blademaster.getLimbDamage("left arm") end
function blademaster.getRA() return blademaster.getLimbDamage("right arm") end
function blademaster.getTorso() return blademaster.getLimbDamage("torso") end
function blademaster.getHead() return blademaster.getLimbDamage("head") end

-- ============================================================
--  CONDITION CHECKS — ARMS
-- ============================================================
function blademaster.checkBothArmsPrepped()
  return blademaster.isArmEffectivelyPrepped("left") and
         blademaster.isArmEffectivelyPrepped("right")
end

-- wouldBreak guard: treat arm as prepped if a single hit would break it
function blademaster.isArmEffectivelyPrepped(side)
  local dmg = (side == "left") and blademaster.getLA() or blademaster.getRA()
  if dmg >= blademaster.CONFIG.prepThreshold then return true end
  return (dmg + blademaster.stanceLd().armPrimaryDamage) >= blademaster.CONFIG.breakThreshold
end

function blademaster.checkBothArmsBroken()
  return blademaster.getLA() >= blademaster.CONFIG.breakThreshold and
         blademaster.getRA() >= blademaster.CONFIG.breakThreshold
end

function blademaster.checkAnyArmBroken()
  return blademaster.getLA() >= blademaster.CONFIG.breakThreshold or
         blademaster.getRA() >= blademaster.CONFIG.breakThreshold
end

function blademaster.checkWillDoubleBreakArms()
  local LA = blademaster.getLA()
  local RA = blademaster.getRA()
  local P = blademaster.stanceLd().armPrimaryDamage
  local S = blademaster.stanceLd().armSecondaryDamage
  local focusArm = blademaster.getFocusArm()

  if focusArm == "left" then
    return (LA + P >= 100) and (RA + S >= 100)
  else
    return (RA + P >= 100) and (LA + S >= 100)
  end
end

function blademaster.checkWillPrepBothArms()
  local LA = blademaster.getLA()
  local RA = blademaster.getRA()
  local P = blademaster.stanceLd().armPrimaryDamage
  local S = blademaster.stanceLd().armSecondaryDamage
  local threshold = blademaster.CONFIG.prepThreshold
  local focusArm = blademaster.getFocusArm()

  if LA >= threshold and RA >= threshold then
    return false
  end

  if focusArm == "left" then
    return (LA + P >= threshold) and (RA + S >= threshold)
  else
    return (RA + P >= threshold) and (LA + S >= threshold)
  end
end

-- ============================================================
--  CONDITION CHECKS — LEGS
-- ============================================================
function blademaster.checkBothLegsPrepped()
  return blademaster.isLegEffectivelyPrepped("left") and
         blademaster.isLegEffectivelyPrepped("right")
end

-- wouldBreak guard: treat limb as prepped if a single hit would break it
function blademaster.isLegEffectivelyPrepped(side)
  local dmg = (side == "left") and blademaster.getLL() or blademaster.getRL()
  if dmg >= blademaster.CONFIG.prepThreshold then return true end
  return (dmg + blademaster.stanceLd().legPrimaryDamage) >= blademaster.CONFIG.breakThreshold
end

function blademaster.checkBothLegsBroken()
  return blademaster.getLL() >= blademaster.CONFIG.breakThreshold and
         blademaster.getRL() >= blademaster.CONFIG.breakThreshold
end

function blademaster.checkAnyLegBroken()
  return blademaster.getLL() >= blademaster.CONFIG.breakThreshold or
         blademaster.getRL() >= blademaster.CONFIG.breakThreshold
end

function blademaster.checkWillDoubleBreakLegs()
  local LL = blademaster.getLL()
  local RL = blademaster.getRL()
  local P = blademaster.stanceLd().legPrimaryDamage
  local S = blademaster.stanceLd().legSecondaryDamage
  local focusLeg = blademaster.getFocusLeg()

  if focusLeg == "left" then
    return (LL + P >= 100) and (RL + S >= 100)
  else
    return (RL + P >= 100) and (LL + S >= 100)
  end
end

function blademaster.checkWillPrepBothLegs()
  local LL = blademaster.getLL()
  local RL = blademaster.getRL()
  local P = blademaster.stanceLd().legPrimaryDamage
  local S = blademaster.stanceLd().legSecondaryDamage
  local threshold = blademaster.CONFIG.prepThreshold
  local focusLeg = blademaster.getFocusLeg()

  if LL >= threshold and RL >= threshold then
    return false
  end

  if focusLeg == "left" then
    return (LL + P >= threshold) and (RL + S >= threshold)
  else
    return (RL + P >= threshold) and (LL + S >= threshold)
  end
end

-- ============================================================
--  CONDITION CHECKS — UPPER BODY (Torso + Head via Centreslash)
-- ============================================================
function blademaster.checkUpperPrepped()
  return blademaster.getTorso() >= blademaster.CONFIG.prepThreshold and
         blademaster.getHead() >= blademaster.CONFIG.prepThreshold
end

function blademaster.checkUpperBroken()
  return blademaster.getTorso() >= blademaster.CONFIG.breakThreshold and
         blademaster.getHead() >= blademaster.CONFIG.breakThreshold
end

function blademaster.checkWillPrepUpper()
  local torso = blademaster.getTorso()
  local head = blademaster.getHead()
  local primaryDmg = blademaster.stanceLd().torsoDamage
  local secondaryDmg = blademaster.stanceLd().headDamage
  local threshold = blademaster.CONFIG.prepThreshold

  if torso >= threshold and head >= threshold then
    return false
  end

  if head <= torso then
    -- DOWN: head gets primary, torso gets secondary
    return (head + primaryDmg >= threshold) and (torso + secondaryDmg >= threshold)
  else
    -- UP: torso gets primary, head gets secondary
    return (torso + primaryDmg >= threshold) and (head + secondaryDmg >= threshold)
  end
end

function blademaster.checkWillBreakUpper()
  local torso = blademaster.getTorso()
  local head = blademaster.getHead()
  local primaryDmg = blademaster.stanceLd().torsoDamage
  local secondaryDmg = blademaster.stanceLd().headDamage
  local breakThreshold = blademaster.CONFIG.breakThreshold

  if head <= torso then
    return (head + primaryDmg >= breakThreshold) and (torso + secondaryDmg >= breakThreshold)
  else
    return (torso + primaryDmg >= breakThreshold) and (head + secondaryDmg >= breakThreshold)
  end
end

function blademaster.getCentreslashDirection()
  -- Hit the LOWER limb as primary (like getFocusLeg).
  -- UP: torso = primary (18.1%), head = secondary (12.1%)
  -- DOWN: head = primary (18.1%), torso = secondary (12.1%)
  local torso = blademaster.getTorso()
  local head = blademaster.getHead()
  if head <= torso then
    return "down"  -- Hit head as primary
  else
    return "up"    -- Hit torso as primary
  end
end

-- ============================================================
--  FOCUS DIRECTION HELPERS
-- ============================================================
-- AK reports parried limbs WITHOUT spaces (leftleg, rightarm, ...). Normalize
-- to the spaced form the dispatch logic compares against ("left leg", etc.).
-- (lb[target].hits keys remain spaced and are unaffected.)
local PARRY_SPACED = {
  leftleg  = "left leg",  rightleg = "right leg",
  leftarm  = "left arm",  rightarm = "right arm",
}

function blademaster.getParried()
  local parried = targetparry or "none"
  if parried == false or parried == "" then
    parried = "none"
  end
  return PARRY_SPACED[parried] or parried
end

function blademaster.getFocusArm()
  local LA = blademaster.getLA()
  local RA = blademaster.getRA()
  local parried = blademaster.getParried()

  if LA >= blademaster.CONFIG.prepThreshold and RA >= blademaster.CONFIG.prepThreshold then
    return parried == "left arm" and "right" or "left"
  end

  local focus = (LA <= RA) and "left" or "right"

  if parried == focus .. " arm" then
    return focus == "left" and "right" or "left"
  end

  return focus
end

function blademaster.getFocusLeg()
  local LL = blademaster.getLL()
  local RL = blademaster.getRL()
  local parried = blademaster.getParried()

  if LL >= blademaster.CONFIG.prepThreshold and RL >= blademaster.CONFIG.prepThreshold then
    return parried == "left leg" and "right" or "left"
  end

  local focus = (LL <= RL) and "left" or "right"

  if parried == focus .. " leg" then
    return focus == "left" and "right" or "left"
  end

  return focus
end

-- ============================================================
--  PATH CALCULATIONS
-- ============================================================
function blademaster.calculateArmPath()
  local LA = blademaster.getLA()
  local RA = blademaster.getRA()
  local P = blademaster.stanceLd().armPrimaryDamage
  local S = blademaster.stanceLd().armSecondaryDamage
  local threshold = blademaster.CONFIG.prepThreshold

  if LA >= threshold and RA >= threshold then
    return { hitsToDouble = 0, explanation = "Both arms ready for double-break!" }
  end

  local simLA, simRA = LA, RA
  local hits = 0
  local sequence = {}

  while simLA < threshold or simRA < threshold do
    hits = hits + 1
    if hits > 20 then break end

    if simLA <= simRA then
      simLA = simLA + P
      simRA = simRA + S
      table.insert(sequence, "L")
    else
      simLA = simLA + S
      simRA = simRA + P
      table.insert(sequence, "R")
    end
  end

  return {
    hitsToDouble = hits,
    explanation = string.format("%d hits to arm double-break (sequence: %s)", hits, table.concat(sequence, ""))
  }
end

function blademaster.calculateLegPath()
  local LL = blademaster.getLL()
  local RL = blademaster.getRL()
  local P = blademaster.stanceLd().legPrimaryDamage
  local S = blademaster.stanceLd().legSecondaryDamage
  local threshold = blademaster.CONFIG.prepThreshold

  if LL >= threshold and RL >= threshold then
    return { hitsToDouble = 0, explanation = "Both legs ready for double-break!" }
  end

  local simLL, simRL = LL, RL
  local hits = 0
  local sequence = {}

  while simLL < threshold or simRL < threshold do
    hits = hits + 1
    if hits > 20 then break end

    if simLL <= simRL then
      simLL = simLL + P
      simRL = simRL + S
      table.insert(sequence, "L")
    else
      simLL = simLL + S
      simRL = simRL + P
      table.insert(sequence, "R")
    end
  end

  return {
    hitsToDouble = hits,
    explanation = string.format("%d hits to leg double-break (sequence: %s)", hits, table.concat(sequence, ""))
  }
end

-- ============================================================
--  SHIN & AIRFIST
-- ============================================================
function blademaster.getShin()
  return tonumber(charstat("Shin")) or 0
end

function blademaster.needsAirfist(targetLimbType)
  local parried = blademaster.getParried()
  local shin = blademaster.getShin()
  local cost = blademaster.CONFIG.airfistShinCost

  if shin < cost then
    return false, "not enough shin (" .. shin .. "/" .. cost .. ")"
  end

  if blademaster.hasAff("airfisted") then
    return false, "already airfisted"
  end

  if targetLimbType == "arm" then
    if parried == "left arm" or parried == "right arm" then
      return true, "parrying arm (" .. parried .. ")"
    end
  elseif targetLimbType == "leg" then
    if parried == "left leg" or parried == "right leg" then
      return true, "parrying leg (" .. parried .. ")"
    end
  end

  return false, "not parrying target limb"
end

-- ============================================================
--  STRIKE SELECTION (shared)
-- ============================================================
function blademaster.selectPrepStrike()
  -- Prep phase strikes: Hamstring first, then afflictions.
  local now = os.time()
  local hamstringExpired = (now - (blademaster.state.lastHamstringTime or 0)) >= blademaster.CONFIG.hamstringDuration
  if not blademaster.hasAff("hamstring") or hamstringExpired then
    return "hamstring"
  end

  -- Lightning prep: paralysis > hypochondria > weariness > clumsiness.
  if not blademaster.hasAff("paralysis") then
    return "neck"
  end
  if not blademaster.hasAff("hypochondria") then
    return "chest"
  end
  if not blademaster.hasAff("weariness") then
    return "shoulder"
  end
  if not blademaster.hasAff("clumsiness") then
    return "ears"
  end

  return "neck"
end

function blademaster.selectIceStrike()
  -- Ice phase: clumsiness first (ice doesn't give it), then others.
  if not blademaster.hasAff("clumsiness") then
    return "ears"
  end
  if not blademaster.hasAff("paralysis") then
    return "neck"
  end
  return "neck"
end

-- ============================================================
--  JIT DISPATCH  (the TIMER fires the dispatch — never the alias)
--
--  The alias only flips `armed` (a boolean — idempotent, mash all you want).
--  A balance/equilibrium-used trigger calls scheduleDispatch(<recover time>),
--  which (re)starts a SINGLE tempTimer for
--  (recoverTime - getNetworkLatency()*latencyMultiplier). On expiry, if still
--  armed, the timer runs the dispatch with fresh state and disarms — one shot
--  per arm. Fire-when-ready (arm while eqbal — balance AND eq — is up) just
--  kicks a minimal timer when none is pending, so it ALSO goes through the timer.
--  Net result: no matter how many times you arm, exactly ONE command set is
--  emitted per balance cycle, computed at balance return.
-- ============================================================

-- Alias entry point. Idempotent: sets the armed boolean, and — only if eqbal
-- (balance AND equilibrium) is up NOW and nothing is scheduled — kicks a single
-- minimal timer so the dispatch still goes through onDispatchTimer (never
-- straight from the alias). So N arms still yield exactly one command set.
function blademaster.arm()
  blademaster.state.armed = true
  if blademaster.CONFIG.fireWhenReady and eqbalUp() and not blademaster.state.dispatchTimer then
    blademaster.scheduleDispatch(0)
  end
end

-- Balance/eq-used trigger entry point. `duration` = seconds until recovery.
-- (Re)starts the single dispatch timer, pulled earlier by network latency so
-- the queued attack lands the instant balance/eq actually returns.
function blademaster.scheduleDispatch(duration)
  duration = tonumber(duration)
  if not duration then return end
  if blademaster.state.dispatchTimer then
    killTimer(blademaster.state.dispatchTimer)
    blademaster.state.dispatchTimer = nil
  end
  local lat = (getNetworkLatency and getNetworkLatency()) or 0
  local delay = duration - lat * blademaster.CONFIG.latencyMultiplier
  if delay < blademaster.CONFIG.minDispatchDelay then
    delay = blademaster.CONFIG.minDispatchDelay
  end
  blademaster.state.dispatchTimer = tempTimer(delay, blademaster.onDispatchTimer)
end

-- The ONLY thing that fires a dispatch. On expiry: if still armed, run with
-- current state and disarm (one shot per arm); otherwise it's a noop.
function blademaster.onDispatchTimer()
  blademaster.state.dispatchTimer = nil
  if blademaster.state.armed then
    blademaster.state.armed = false
    blademaster.run()
  end
end

-- ============================================================
--  UNIFIED DISPATCH (single entry point with shared guards)
--  Called by the dispatch timer (and by arm() when balance is already up).
-- ============================================================
function blademaster.run()
  -- Target validation.
  if not target or target == "" then
    cecho("\n<red>[BM] No target set! Use: tar <name>")
    return
  end

  -- Self-aeon: skip dispatch.
  if selfAff("aeon") then return end

  -- Paused?
  if isPaused() then return end

  -- Rebound hold gate (user-override; default never holds).
  if blademaster.reboundGate(blademaster.run) then return end

  -- Target-change reset (prevents stale Brokenstar state on a new target).
  if blademaster.state.lastTarget ~= target then
    blademaster.state.lastTarget = target
    blademaster.state.engaged = false
    blademaster.state.flamefistDone = false
    blademaster.resetBrokenstarState()
    blademaster.resetProneTimer()
  end

  -- Mode routing.
  local mode = blademaster.state.mode
  if mode == "double" then
    blademaster.dispatch.runDoublePrep()
  elseif mode == "quad" then
    blademaster.dispatch.runQuadPrep()
  elseif mode == "brokenstar" then
    blademaster.dispatch.runBrokenstar()
  elseif mode == "group" then
    blademaster.dispatch.runGroup()
  end
end

--------------------------------------------------------------------------------
--  STRATEGY 1: DOUBLE-PREP (LEGS ONLY)
--------------------------------------------------------------------------------

function blademaster.getPhaseDoublePrep()
  -- 1. leg_prep: Both legs < 90% (Lightning)
  -- 2. leg_break: Legs prepped, not broken (Ice)
  -- 3. mangle: PRONE (Ice + Sternum)
  local legsPrepped = blademaster.checkBothLegsPrepped()

  if blademaster.hasAff("prone") then
    return "mangle"
  end

  if legsPrepped or blademaster.checkWillDoubleBreakLegs() then
    return "leg_break"
  end

  return "leg_prep"
end

function blademaster.getPhaseLabelDoublePrep()
  local phase = blademaster.getPhaseDoublePrep()
  local labels = {
    leg_prep = "<yellow>Leg Prep",
    leg_break = "<blue>Leg Break",
    mangle = "<red>Mangle",
  }
  return labels[phase] or "<grey>Unknown"
end

function blademaster.selectStrikeDoublePrep()
  local phase = blademaster.getPhaseDoublePrep()

  if phase == "mangle" then
    return "sternum"
  end

  if phase == "leg_break" then
    return "knees"
  end

  if phase == "leg_prep" then
    -- Dismount during final prep hit if mounted + hamstrung, so KNEES on
    -- double-break will prone (not just dismount).
    if has("mounted") and blademaster.hasAff("hamstring") and blademaster.checkWillPrepBothLegs() then
      return "knees"
    end
    return blademaster.selectPrepStrike()
  end

  return blademaster.selectPrepStrike()
end

function blademaster.selectAttackDoublePrep()
  local phase = blademaster.getPhaseDoublePrep()

  if blademaster.hasAff("shield") or blademaster.hasAff("rebounding") then
    return "raze", nil
  end

  -- Airfist is its own full-balance attack (prep phase).
  if phase == "leg_prep" then
    local needsAF, _ = blademaster.needsAirfist("leg")
    if needsAF then
      return "airfist", nil
    end
  end

  -- MANGLE: Right leg first to 200%+ (mangled), then left leg.
  if phase == "mangle" then
    local RL = blademaster.getRL()
    if RL < 200 then
      return "legslash", "right"
    else
      return "legslash", "left"
    end
  end

  return "legslash", blademaster.getFocusLeg()
end

function blademaster.buildComboDoublePrep()
  local attack, direction = blademaster.selectAttackDoublePrep()
  local strike = blademaster.selectStrikeDoublePrep()
  local phase = blademaster.getPhaseDoublePrep()
  local combo = ""

  if attack == "airfist" then
    return "airfist " .. target .. ";assess " .. target
  end

  -- Infuse: Ice for break/mangle + final prep (strip caloric), Lightning otherwise.
  if phase == "leg_break" or phase == "mangle" then
    combo = blademaster.infuseCmd("ice")
  elseif phase == "leg_prep" and blademaster.checkWillPrepBothLegs() then
    combo = blademaster.infuseCmd("ice")
  else
    combo = blademaster.infuseCmd("lightning")
  end

  if attack == "raze" then
    combo = combo .. "raze " .. target
    if strike then combo = combo .. " " .. strike end
  elseif attack == "balanceslash" then
    combo = combo .. "balanceslash " .. target
    if strike then combo = combo .. " " .. strike end
  elseif attack == "legslash" then
    combo = combo .. "legslash " .. target .. " " .. direction
    if strike then combo = combo .. " " .. strike end
  end

  return combo
end

function blademaster.dispatch.runDoublePrep()
  local phase = blademaster.getPhaseDoublePrep()
  local phaseLabel = blademaster.getPhaseLabelDoublePrep()
  local targetHP = targetHpPct()

  if phase ~= "mangle" or not blademaster.hasAff("prone") then
    blademaster.resetProneTimer()
  end

  if blademaster.shouldEcho() then
    cecho("\n<cyan>[BM " .. phaseLabel .. "<cyan>] Target: " .. tostring(target) .. " | HP: " .. targetHP .. "% | Track: " .. blademaster.getTrackingSystem())
    cecho("\n<cyan>[BM " .. phaseLabel .. "<cyan>] Legs: LL=" .. string.format("%.1f", blademaster.getLL()) .. "% RL=" .. string.format("%.1f", blademaster.getRL()) .. "%")
    cecho("\n<cyan>[BM " .. phaseLabel .. "<cyan>] Stance: <yellow>" .. blademaster.getStance() .. "<cyan> | Dmg: P=" .. string.format("%.1f", blademaster.stanceLd().legPrimaryDamage) .. "% S=" .. string.format("%.1f", blademaster.stanceLd().legSecondaryDamage) .. "%")

    if phase == "leg_prep" then
      local legPath = blademaster.calculateLegPath()
      if blademaster.checkWillPrepBothLegs() then
        if has("mounted") and blademaster.hasAff("hamstring") then
          cecho("\n<magenta>*** DISMOUNT - KNEES to dismount before double-break! ***")
        else
          cecho("\n<blue>*** FINAL PREP - ICE infuse to strip caloric! ***")
        end
      elseif legPath.hitsToDouble > 0 then
        cecho("\n<yellow>" .. legPath.explanation)
      end
    elseif phase == "leg_break" then
      cecho("\n<blue>*** LEG BREAK - ICE infuse + KNEES for prone! ***")
    elseif phase == "mangle" then
      local RL = blademaster.getRL()
      local LL = blademaster.getLL()
      if RL < 200 then
        cecho("\n<red>*** MANGLE - Legslash RIGHT + STERNUM (RL=" .. string.format("%.1f", RL) .. "%/200%) ***")
      else
        cecho("\n<red>*** MANGLE - Legslash LEFT + STERNUM (RL mangled, LL=" .. string.format("%.1f", LL) .. "%) ***")
      end
    end

    local parried = blademaster.getParried()
    local shin = blademaster.getShin()
    local attack, _ = blademaster.selectAttackDoublePrep()
    cecho("\n<cyan>[BM " .. phaseLabel .. "<cyan>] Parried: " .. parried .. " | Shin: " .. shin)
    if attack == "airfist" then
      cecho(" | <green>AIRFIST!")
    end
  end

  if phase == "mangle" and blademaster.state.proneTimerActive then
    blademaster.state.proneAttackCount = blademaster.state.proneAttackCount + 1
  end

  local cmd = blademaster.buildComboDoublePrep()
  cmd = cmd .. ";assess " .. target
  sendAttack(cmd, blademaster.CONFIG.queueType)
end

--------------------------------------------------------------------------------
--  STRATEGY 2: QUAD-PREP (ARMS + LEGS)
--------------------------------------------------------------------------------

function blademaster.getPhaseQuadPrep()
  -- 1. arm_prep -> 2. leg_prep -> 3. flamefist -> 4. arm_break ->
  -- 5. leg_break (RIGHT) -> 6. mangle (RIGHT + sternum)
  local armsPrepped = blademaster.checkBothArmsPrepped()
  local armsBroken = blademaster.checkBothArmsBroken()
  local legsPrepped = blademaster.checkBothLegsPrepped()

  if blademaster.hasAff("prone") then
    return "mangle"
  end

  if armsBroken and legsPrepped then
    return "leg_break"
  end

  if armsPrepped and legsPrepped and not armsBroken and blademaster.state.flamefistDone then
    return "arm_break"
  end

  if armsPrepped and legsPrepped and not blademaster.state.flamefistDone then
    return "flamefist"
  end

  if armsPrepped and not legsPrepped then
    return "leg_prep"
  end

  return "arm_prep"
end

function blademaster.getPhaseLabelQuadPrep()
  local phase = blademaster.getPhaseQuadPrep()
  local labels = {
    arm_prep = "<yellow>Arm Prep",
    leg_prep = "<yellow>Leg Prep",
    flamefist = "<orange>Flamefist",
    arm_break = "<blue>Arm Break",
    leg_break = "<blue>Leg Break",
    mangle = "<red>Mangle",
  }
  return labels[phase] or "<grey>Unknown"
end

function blademaster.selectStrikeQuadPrep()
  local phase = blademaster.getPhaseQuadPrep()

  if phase == "flamefist" then
    return nil
  end

  if phase == "mangle" then
    return "sternum"
  end

  if phase == "leg_break" then
    return "knees"
  end

  if phase == "arm_break" then
    return blademaster.selectIceStrike()
  end

  return blademaster.selectPrepStrike()
end

function blademaster.selectAttackQuadPrep()
  local phase = blademaster.getPhaseQuadPrep()

  -- FLAMEFIST: Negates rebounding — use even through rebounding, but raze shield.
  if phase == "flamefist" then
    if blademaster.hasAff("shield") then
      return "raze", nil
    end
    return "flamefist", nil
  end

  if blademaster.hasAff("shield") or blademaster.hasAff("rebounding") then
    return "raze", nil
  end

  if phase == "arm_prep" then
    local needsAF, _ = blademaster.needsAirfist("arm")
    if needsAF then
      return "airfist", nil
    end
    return "armslash", blademaster.getFocusArm()
  end

  if phase == "leg_prep" then
    local needsAF, _ = blademaster.needsAirfist("leg")
    if needsAF then
      return "airfist", nil
    end
    return "legslash", blademaster.getFocusLeg()
  end

  if phase == "arm_break" then
    return "armslash", blademaster.getFocusArm()
  end

  -- LEG BREAK: Always RIGHT (curing applies to left first, so right stays broken longer).
  if phase == "leg_break" then
    return "legslash", "right"
  end

  -- MANGLE: Always RIGHT + STERNUM.
  if phase == "mangle" then
    return "legslash", "right"
  end

  return "legslash", blademaster.getFocusLeg()
end

function blademaster.buildComboQuadPrep()
  local attack, direction = blademaster.selectAttackQuadPrep()
  local strike = blademaster.selectStrikeQuadPrep()
  local phase = blademaster.getPhaseQuadPrep()
  local combo = ""

  if attack == "airfist" then
    return "airfist " .. target .. ";assess " .. target
  end

  if attack == "flamefist" then
    blademaster.state.flamefistDone = true
    return "flamefist " .. target .. ";assess " .. target
  end

  -- Infuse: Ice for break/mangle + final prep, Lightning for normal prep.
  if phase == "arm_break" or phase == "leg_break" or phase == "mangle" then
    combo = blademaster.infuseCmd("ice")
  elseif phase == "arm_prep" and blademaster.checkWillPrepBothArms() then
    combo = blademaster.infuseCmd("ice")
  elseif phase == "leg_prep" and blademaster.checkWillPrepBothLegs() then
    combo = blademaster.infuseCmd("ice")
  else
    combo = blademaster.infuseCmd("lightning")
  end

  if attack == "raze" then
    combo = combo .. "raze " .. target
    if strike then combo = combo .. " " .. strike end
  elseif attack == "balanceslash" then
    combo = combo .. "balanceslash " .. target
    if strike then combo = combo .. " " .. strike end
  elseif attack == "armslash" then
    combo = combo .. "armslash " .. target .. " " .. direction
    if strike then combo = combo .. " " .. strike end
  elseif attack == "legslash" then
    combo = combo .. "legslash " .. target .. " " .. direction
    if strike then combo = combo .. " " .. strike end
  end

  return combo
end

function blademaster.dispatch.runQuadPrep()
  local phase = blademaster.getPhaseQuadPrep()
  local phaseLabel = blademaster.getPhaseLabelQuadPrep()
  local targetHP = targetHpPct()

  if phase ~= "mangle" or not blademaster.hasAff("prone") then
    blademaster.resetProneTimer()
  end

  if blademaster.shouldEcho() then
    cecho("\n<cyan>[BMQ " .. phaseLabel .. "<cyan>] Target: " .. tostring(target) .. " | HP: " .. targetHP .. "% | Track: " .. blademaster.getTrackingSystem())
    cecho("\n<cyan>[BMQ " .. phaseLabel .. "<cyan>] Arms: LA=" .. string.format("%.1f", blademaster.getLA()) .. "% RA=" .. string.format("%.1f", blademaster.getRA()) .. "%")
    cecho("\n<cyan>[BMQ " .. phaseLabel .. "<cyan>] Legs: LL=" .. string.format("%.1f", blademaster.getLL()) .. "% RL=" .. string.format("%.1f", blademaster.getRL()) .. "%")

    if phase == "arm_prep" then
      local armPath = blademaster.calculateArmPath()
      if blademaster.checkWillPrepBothArms() then
        cecho("\n<blue>*** FINAL ARM PREP - ICE infuse to strip caloric! ***")
      elseif armPath.hitsToDouble > 0 then
        cecho("\n<yellow>" .. armPath.explanation)
      else
        cecho("\n<green>*** ARMS READY ***")
      end
    elseif phase == "leg_prep" then
      local legPath = blademaster.calculateLegPath()
      if blademaster.checkWillPrepBothLegs() then
        cecho("\n<blue>*** FINAL LEG PREP - ICE infuse to strip caloric! ***")
      elseif legPath.hitsToDouble > 0 then
        cecho("\n<yellow>" .. legPath.explanation)
      else
        cecho("\n<green>*** LEGS READY ***")
      end
    elseif phase == "flamefist" then
      cecho("\n<orange>*** FLAMEFIST - Negate rebounding before breaks! ***")
    elseif phase == "arm_break" then
      cecho("\n<blue>*** ARM BREAK - ICE infuse, break both arms! ***")
    elseif phase == "leg_break" then
      cecho("\n<blue>*** LEG BREAK - ICE infuse + KNEES, always RIGHT! ***")
    elseif phase == "mangle" then
      local RL = blademaster.getRL()
      cecho("\n<red>*** MANGLE - Legslash RIGHT + STERNUM (RL=" .. string.format("%.1f", RL) .. "%) ***")
    end

    local parried = blademaster.getParried()
    local shin = blademaster.getShin()
    local attack, _ = blademaster.selectAttackQuadPrep()
    cecho("\n<cyan>[BMQ " .. phaseLabel .. "<cyan>] Parried: " .. parried .. " | Shin: " .. shin)
    if attack == "airfist" then
      cecho(" | <green>AIRFIST!")
    elseif attack == "flamefist" then
      cecho(" | <orange>FLAMEFIST!")
    end
  end

  if phase == "mangle" and blademaster.state.proneTimerActive then
    blademaster.state.proneAttackCount = blademaster.state.proneAttackCount + 1
  end

  local cmd = blademaster.buildComboQuadPrep()
  cmd = cmd .. ";assess " .. target
  sendAttack(cmd, blademaster.CONFIG.queueType)
end

--------------------------------------------------------------------------------
--  STRATEGY 3: BROKENSTAR (INSTANT KILL)
--------------------------------------------------------------------------------

function blademaster.resetBrokenstarState()
  blademaster.state.isImpaled = false
  blademaster.state.impaleslashDone = false
  blademaster.state.secondImpale = false
  blademaster.state.bleedingReady = false
  blademaster.state.targetBleeding = 0
  blademaster.state.withdrawDone = false
  blademaster.state.bladetwistCount = 0
end

function blademaster.getPhaseBrokenstar()
  -- 1. upper_prep -> 2. leg_prep -> 3. upper_break -> 4. leg_break ->
  -- 5. impale -> 6. impaleslash -> 7. bladetwist -> 8. withdraw -> 9. brokenstar
  local upperPrepped = blademaster.checkUpperPrepped()
  local upperBroken = blademaster.checkUpperBroken()
  local legsPrepped = blademaster.checkBothLegsPrepped()
  local legsBroken = blademaster.checkBothLegsBroken()

  -- Phase 9: BROKENSTAR — withdrew blade OR target not impaled (writhed + stood).
  if blademaster.state.bleedingReady and (blademaster.state.withdrawDone or not blademaster.state.isImpaled) then
    return "brokenstar"
  end

  -- Phase 8: WITHDRAW — only if still impaled.
  if blademaster.state.bleedingReady and blademaster.state.isImpaled then
    return "withdraw"
  end

  -- Phase 7: BLADETWIST — requires being impaled.
  if blademaster.state.impaleslashDone and blademaster.state.isImpaled then
    return "bladetwist"
  end

  -- Phase 6: IMPALESLASH.
  if blademaster.state.isImpaled and not blademaster.state.impaleslashDone then
    return "impaleslash"
  end

  -- Phase 5: IMPALE (first or re-impale after writhe) — prone OR both legs broken.
  local targetProne = blademaster.hasAff("prone")
  local canImpale = legsBroken or targetProne
  if canImpale and not blademaster.state.isImpaled then
    return "impale"
  end

  -- Phase 4: LEG BREAK (upper must be broken first).
  if upperBroken and (legsPrepped or blademaster.checkWillDoubleBreakLegs()) then
    return "leg_break"
  end

  -- Phase 3: UPPER BREAK (legs must be prepped first).
  if legsPrepped and (upperPrepped or blademaster.checkWillBreakUpper()) then
    return "upper_break"
  end

  -- Phase 2: LEG PREP (upper must be prepped first).
  if upperPrepped and not legsPrepped then
    return "leg_prep"
  end

  -- Phase 1: UPPER PREP (default).
  return "upper_prep"
end

function blademaster.getPhaseLabelBrokenstar()
  local phase = blademaster.getPhaseBrokenstar()
  local labels = {
    upper_prep = "<yellow>Upper Prep",
    leg_prep = "<yellow>Leg Prep",
    upper_break = "<blue>Upper Break",
    leg_break = "<blue>Leg Break",
    impale = "<cyan>Impale",
    impaleslash = "<magenta>Impaleslash",
    bladetwist = "<red>Bladetwist",
    withdraw = "<yellow>Withdraw",
    brokenstar = "<green>BROKENSTAR",
  }
  return labels[phase] or "<grey>Unknown"
end

function blademaster.selectStrikeBrokenstar()
  local phase = blademaster.getPhaseBrokenstar()

  if phase == "upper_prep" then
    return blademaster.selectPrepStrike()
  end

  if phase == "upper_break" then
    return blademaster.selectIceStrike()
  end

  if phase == "leg_break" then
    return "knees"
  end

  if phase == "leg_prep" then
    if has("mounted") and blademaster.hasAff("hamstring") and blademaster.checkWillPrepBothLegs() then
      return "knees"
    end
    return blademaster.selectPrepStrike()
  end

  return nil
end

function blademaster.selectAttackBrokenstar()
  local phase = blademaster.getPhaseBrokenstar()

  if blademaster.hasAff("shield") or blademaster.hasAff("rebounding") then
    return "raze"
  end

  if phase == "leg_prep" then
    local needsAF, _ = blademaster.needsAirfist("leg")
    if needsAF then
      return "airfist"
    end
  end

  return phase  -- phase name doubles as the attack type
end

function blademaster.buildComboBrokenstar()
  local phase = blademaster.getPhaseBrokenstar()
  local attack = blademaster.selectAttackBrokenstar()
  local strike = blademaster.selectStrikeBrokenstar()
  local combo = ""

  if attack == "raze" then
    combo = "raze " .. target
    if strike then combo = combo .. " " .. strike end
    combo = combo .. ";assess " .. target
    return combo
  end

  if attack == "airfist" then
    return "airfist " .. target .. ";assess " .. target
  end

  if phase == "upper_prep" then
    local direction = blademaster.getCentreslashDirection()
    if blademaster.checkWillPrepUpper() then
      combo = blademaster.infuseCmd("ice")
    else
      combo = blademaster.infuseCmd("lightning")
    end
    combo = combo .. "centreslash " .. target .. " " .. direction
    if strike then combo = combo .. " " .. strike end

  elseif phase == "upper_break" then
    local direction = blademaster.getCentreslashDirection()
    combo = blademaster.infuseCmd("ice") .. "centreslash " .. target .. " " .. direction
    if strike then combo = combo .. " " .. strike end

  elseif phase == "leg_prep" then
    if blademaster.checkWillPrepBothLegs() then
      combo = blademaster.infuseCmd("ice")
    else
      combo = blademaster.infuseCmd("lightning")
    end
    local focusLeg = blademaster.getFocusLeg()
    combo = combo .. "legslash " .. target .. " " .. focusLeg
    if strike then combo = combo .. " " .. strike end

  elseif phase == "leg_break" then
    combo = blademaster.infuseCmd("ice")
    local focusLeg = blademaster.getFocusLeg()
    combo = combo .. "legslash " .. target .. " " .. focusLeg
    if strike then combo = combo .. " " .. strike end

  elseif phase == "impale" then
    combo = "impale " .. target

  elseif phase == "impaleslash" then
    combo = "impaleslash " .. target

  elseif phase == "bladetwist" then
    -- On 3rd+ bladetwist, add discern to check bleeding.
    if blademaster.state.bladetwistCount >= 2 then
      combo = "bladetwist;discern " .. target
    else
      combo = "bladetwist;assess " .. target
    end
    return combo  -- already has assess/discern

  elseif phase == "withdraw" then
    combo = "withdraw " .. target

  elseif phase == "brokenstar" then
    combo = "brokenstar " .. target
  end

  if phase ~= "bladetwist" then
    combo = combo .. ";assess " .. target
  end

  return combo
end

function blademaster.dispatch.runBrokenstar()
  local phase = blademaster.getPhaseBrokenstar()
  local phaseLabel = blademaster.getPhaseLabelBrokenstar()
  local targetHP = targetHpPct()

  if blademaster.shouldEcho() then
    cecho("\n<cyan>[BMBS " .. phaseLabel .. "<cyan>] Target: " .. tostring(target) .. " | HP: " .. targetHP .. "% | Track: " .. blademaster.getTrackingSystem())
    cecho("\n<cyan>[BMBS " .. phaseLabel .. "<cyan>] Upper: T=" .. string.format("%.1f", blademaster.getTorso()) .. "% H=" .. string.format("%.1f", blademaster.getHead()) .. "%")
    cecho("\n<cyan>[BMBS " .. phaseLabel .. "<cyan>] Legs: LL=" .. string.format("%.1f", blademaster.getLL()) .. "% RL=" .. string.format("%.1f", blademaster.getRL()) .. "%")

    if phase == "upper_prep" then
      local direction = blademaster.getCentreslashDirection()
      if blademaster.checkWillPrepUpper() then
        cecho("\n<blue>*** FINAL UPPER PREP - ICE infuse + centreslash " .. direction .. "! ***")
      else
        cecho("\n<yellow>*** UPPER PREP - Centreslash " .. direction .. " (hitting " .. (direction == "up" and "torso" or "head") .. " as primary) ***")
      end
    elseif phase == "upper_break" then
      local direction = blademaster.getCentreslashDirection()
      cecho("\n<blue>*** UPPER BREAK - Centreslash " .. direction .. " to break torso/head! ***")
    elseif phase == "leg_prep" then
      local legPath = blademaster.calculateLegPath()
      if blademaster.checkWillPrepBothLegs() then
        if has("mounted") and blademaster.hasAff("hamstring") then
          cecho("\n<magenta>*** DISMOUNT - KNEES to dismount before double-break! ***")
        else
          cecho("\n<blue>*** FINAL LEG PREP - ICE infuse to strip caloric! ***")
        end
      elseif legPath.hitsToDouble > 0 then
        cecho("\n<yellow>" .. legPath.explanation)
      end
    elseif phase == "leg_break" then
      cecho("\n<blue>*** LEG BREAK - Double-break legs + KNEES to prone! ***")
    elseif phase == "impale" then
      cecho("\n<cyan>*** IMPALE - Impale the prone target! ***")
    elseif phase == "impaleslash" then
      cecho("\n<magenta>*** IMPALESLASH - Slash arteries for bleeding! ***")
    elseif phase == "bladetwist" then
      local bleedColor = blademaster.state.targetBleeding >= 700 and "<green>" or "<yellow>"
      local twistNum = blademaster.state.bladetwistCount + 1
      local discernNote = twistNum >= 3 and " <cyan>(+discern)" or ""
      cecho("\n<red>*** BLADETWIST #" .. twistNum .. " - Building bleeding (" .. bleedColor .. blademaster.state.targetBleeding .. "/700<red>)" .. discernNote .. " ***")
    elseif phase == "withdraw" then
      cecho("\n<yellow>*** WITHDRAW - Pull blade out! ***")
    elseif phase == "brokenstar" then
      cecho("\n<green>*** BROKENSTAR - EXECUTE INSTANT KILL! ***")
    end

    cecho("\n<cyan>[BMBS " .. phaseLabel .. "<cyan>] Impaled: " .. (blademaster.state.isImpaled and "<green>YES" or "<red>NO"))
    cecho("<cyan> | Slashed: " .. (blademaster.state.impaleslashDone and "<green>YES" or "<red>NO"))
    local bleedColor = blademaster.state.targetBleeding >= 700 and "<green>" or (blademaster.state.targetBleeding >= 300 and "<yellow>" or "<red>")
    cecho("<cyan> | Bleed: " .. bleedColor .. blademaster.state.targetBleeding)
    cecho("<cyan> | Withdrawn: " .. (blademaster.state.withdrawDone and "<green>YES" or "<red>NO"))

    local parried = blademaster.getParried()
    local shin = blademaster.getShin()
    local attack = blademaster.selectAttackBrokenstar()
    cecho("\n<cyan>[BMBS " .. phaseLabel .. "<cyan>] Parried: " .. parried .. " | Shin: " .. shin)
    if attack == "airfist" then
      cecho(" | <green>AIRFIST!")
    end
  end

  local cmd = blademaster.buildComboBrokenstar()
  sendAttack(cmd, blademaster.CONFIG.queueType)
end

--------------------------------------------------------------------------------
--  STRATEGY 4: GROUP (POMMELSTRIKE LOCK)
--
--  1. Hamstring  2. Paralysis(neck)  3. Asthma(throat)  4. Slickness(underarm,
--  if asthma)  5. Anorexia(stomach, if impatience+slickness)  6. class lock aff
--  7. Hypochondria(chest)  8. Sternum (damage / maintain lock)
--------------------------------------------------------------------------------

-- getLockingAffliction() return value -> pommelstrike location.
blademaster.lockAffToStrike = {
  paralyse  = "neck",
  weariness = "shoulder",
  plague    = "eyes",
  stupid    = "temple",
  reckless  = "groin",
}

function blademaster.selectStrikeGroup()
  local hasAff = blademaster.hasAff

  if not hasAff("hamstring") then
    return "hamstring"
  end

  if not hasAff("paralysis") then
    return "neck"
  end

  if not hasAff("asthma") then
    return "throat"
  end

  if not hasAff("slickness") then
    return "underarm"
  end

  if hasAff("impatience") and hasAff("slickness") and not hasAff("anorexia") then
    return "stomach"
  end

  -- Class locking affliction (optional — guarded; no-op if helper absent).
  if getLockingAffliction then
    local lockAff = getLockingAffliction()
    if lockAff then
      local strike = blademaster.lockAffToStrike[lockAff]
      if strike then
        local affName = ({
          paralyse = "paralysis", weariness = "weariness", plague = "plague",
          stupid = "stupidity", reckless = "recklessness",
        })[lockAff] or lockAff
        if not hasAff(affName) then
          return strike
        end
      end
    end
  end

  if not hasAff("hypochondria") then
    return "chest"
  end

  return "sternum"
end

function blademaster.buildComboGroup()
  local combo = ""

  if blademaster.hasAff("shield") or blademaster.hasAff("rebounding") then
    local strike = blademaster.selectStrikeGroup()
    combo = "raze " .. target
    if strike then combo = combo .. " " .. strike end
    combo = combo .. ";assess " .. target
    return combo
  end

  local strike = blademaster.selectStrikeGroup()
  combo = blademaster.infuseCmd("ice") .. "pommelstrike " .. target .. " " .. strike .. ";assess " .. target
  return combo
end

function blademaster.dispatch.runGroup()
  local targetHP = targetHpPct()
  local strike = blademaster.selectStrikeGroup()

  if blademaster.shouldEcho() then
    cecho("\n<cyan>[BM <magenta>Group<cyan>] Target: " .. tostring(target) .. " | HP: " .. targetHP .. "% | Track: " .. blademaster.getTrackingSystem())
    cecho("\n<cyan>[BM <magenta>Group<cyan>] Strike: <yellow>" .. strike .. "<cyan> | Pommelstrike + Ice")

    local hasAff = blademaster.hasAff
    local function affTag(aff, label)
      return (hasAff(aff) and "<green>" or "<red>") .. label
    end
    cecho("\n<cyan>[BM <magenta>Group<cyan>] " ..
      affTag("paralysis", "PAR") .. " " ..
      affTag("asthma", "AST") .. " " ..
      affTag("slickness", "SLI") .. " " ..
      affTag("anorexia", "ANO") .. " " ..
      affTag("impatience", "IMP") .. " " ..
      affTag("hypochondria", "HYP"))
  end

  local cmd = blademaster.buildComboGroup()
  sendAttack(cmd, blademaster.CONFIG.queueType)
end

--------------------------------------------------------------------------------
-- STATUS DISPLAYS
--------------------------------------------------------------------------------

local function progressBar(pct, width)
  width = width or 10
  local filled = math.floor((pct / 100) * width)
  if filled > width then filled = width end
  if filled < 0 then filled = 0 end
  return string.rep("#", filled) .. string.rep("-", width - filled)
end

function blademaster.dispatch.statusDoublePrep()
  local phaseLabel = blademaster.getPhaseLabelDoublePrep()
  local targetHP = targetHpPct()
  local LL, RL = blademaster.getLL(), blademaster.getRL()
  local threshold = blademaster.CONFIG.prepThreshold

  cecho("\n<cyan>+============================================+")
  cecho("\n<cyan>|     <white>BLADEMASTER DOUBLE-PREP (LEGS)<cyan>        |")
  cecho("\n<cyan>+============================================+")
  cecho("\n<cyan>| <white>Target: <yellow>" .. tostring(target or "None") .. " <grey>(HP: " .. targetHP .. "%)<cyan>")
  cecho("\n<cyan>| <white>Phase: " .. phaseLabel .. " <grey>| Track: " .. blademaster.getTrackingSystem() .. "<cyan>")
  cecho("\n<cyan>+--------------------------------------------+")
  cecho("\n<cyan>| <white>LEG STATUS:<cyan>")
  cecho("\n<cyan>|   <white>L Leg: " .. (LL >= 100 and "<green>BROKEN " or (LL >= threshold and "<yellow>READY  " or "<red>       ")) .. string.format("%5.1f%%", LL) .. " [" .. progressBar(LL) .. "]")
  cecho("\n<cyan>|   <white>R Leg: " .. (RL >= 100 and "<green>BROKEN " or (RL >= threshold and "<yellow>READY  " or "<red>       ")) .. string.format("%5.1f%%", RL) .. " [" .. progressBar(RL) .. "]")
  cecho("\n<cyan>+--------------------------------------------+")
  cecho("\n<cyan>| <white>STRATEGY:<cyan>")
  cecho("\n<cyan>|   <grey>1. LEG PREP: Legslash alternating (Lightning)")
  cecho("\n<cyan>|   <grey>2. LEG BREAK: Double-break legs + KNEES (Ice)")
  cecho("\n<cyan>|   <grey>3. MANGLE: Legslash right + STERNUM (Ice)")
  cecho("\n<cyan>+============================================+\n")
end

function blademaster.dispatch.statusQuadPrep()
  local phaseLabel = blademaster.getPhaseLabelQuadPrep()
  local targetHP = targetHpPct()
  local LA, RA = blademaster.getLA(), blademaster.getRA()
  local LL, RL = blademaster.getLL(), blademaster.getRL()
  local threshold = blademaster.CONFIG.prepThreshold

  cecho("\n<cyan>+============================================+")
  cecho("\n<cyan>|     <white>BLADEMASTER QUAD-PREP (ARMS+LEGS)<cyan>     |")
  cecho("\n<cyan>+============================================+")
  cecho("\n<cyan>| <white>Target: <yellow>" .. tostring(target or "None") .. " <grey>(HP: " .. targetHP .. "%)<cyan>")
  cecho("\n<cyan>| <white>Phase: " .. phaseLabel .. " <grey>| Track: " .. blademaster.getTrackingSystem() .. "<cyan>")
  cecho("\n<cyan>+--------------------------------------------+")
  cecho("\n<cyan>| <white>ARM STATUS:<cyan>")
  cecho("\n<cyan>|   <white>L Arm: " .. (LA >= 100 and "<green>BROKEN " or (LA >= threshold and "<yellow>READY  " or "<red>       ")) .. string.format("%5.1f%%", LA) .. " [" .. progressBar(LA) .. "]")
  cecho("\n<cyan>|   <white>R Arm: " .. (RA >= 100 and "<green>BROKEN " or (RA >= threshold and "<yellow>READY  " or "<red>       ")) .. string.format("%5.1f%%", RA) .. " [" .. progressBar(RA) .. "]")
  cecho("\n<cyan>+--------------------------------------------+")
  cecho("\n<cyan>| <white>LEG STATUS:<cyan>")
  cecho("\n<cyan>|   <white>L Leg: " .. (LL >= 100 and "<green>BROKEN " or (LL >= threshold and "<yellow>READY  " or "<red>       ")) .. string.format("%5.1f%%", LL) .. " [" .. progressBar(LL) .. "]")
  cecho("\n<cyan>|   <white>R Leg: " .. (RL >= 100 and "<green>BROKEN " or (RL >= threshold and "<yellow>READY  " or "<red>       ")) .. string.format("%5.1f%%", RL) .. " [" .. progressBar(RL) .. "]")
  cecho("\n<cyan>+--------------------------------------------+")
  cecho("\n<cyan>| <white>STRATEGY (Ice Path):<cyan>")
  cecho("\n<cyan>|   <grey>1. ARM PREP: Armslash alternating (Lightning)")
  cecho("\n<cyan>|   <grey>2. LEG PREP: Legslash alternating (Lightning)")
  cecho("\n<cyan>|   <grey>3. FLAMEFIST: Negate rebounding before breaks")
  cecho("\n<cyan>|   <grey>4. ARM BREAK: Double-break arms (Ice)")
  cecho("\n<cyan>|   <grey>5. LEG BREAK: Double-break legs + KNEES, RIGHT (Ice)")
  cecho("\n<cyan>|   <grey>6. MANGLE: Legslash RIGHT + STERNUM (Ice)")
  cecho("\n<cyan>+============================================+\n")
end

--------------------------------------------------------------------------------
-- PRONE TIMER (vestigial — balanceslash mechanic removed; fed by leg-salve trigger)
--------------------------------------------------------------------------------

function blademaster.resetProneTimer()
  blademaster.state.proneTimerStart = nil
  blademaster.state.proneAttackCount = 0
  blademaster.state.proneTimerActive = false
end

function blademaster.onLegSalveDetected()
  if not blademaster.checkBothLegsBroken() then return end
  if not blademaster.hasAff("prone") then return end

  if not blademaster.state.proneTimerActive then
    blademaster.state.proneTimerStart = os.time()
    blademaster.state.proneAttackCount = 0
    blademaster.state.proneTimerActive = true
    cecho("\n<magenta>[BM] Prone timer started - " .. blademaster.CONFIG.proneTimerDuration .. " second window")
  end
end

--------------------------------------------------------------------------------
-- DAMAGE TRACKING + BROKENSTAR STATE CALLBACKS
--------------------------------------------------------------------------------

blademaster.damageCapture = {
  pendingPrimary = nil,
  pendingLimb = nil,
  pendingType = nil,
  lastCaptureTime = 0,
}

function blademaster.onHamstringApplied()
  blademaster.state.lastHamstringTime = os.time()
end

function blademaster.captureLegDamage(damage, side)
  damage = tonumber(damage) or 0
  local now = os.time()

  if blademaster.damageCapture.pendingPrimary and
     blademaster.damageCapture.pendingType == "leg" and
     (now - blademaster.damageCapture.lastCaptureTime) < 2 then
    blademaster.stanceLd().legSecondaryDamage = damage
    blademaster.stanceLd().legPrimaryDamage = blademaster.damageCapture.pendingPrimary
    blademaster.state.lastPrimaryLeg = blademaster.damageCapture.pendingLimb
    blademaster.damageCapture.pendingPrimary = nil
    blademaster.damageCapture.pendingLimb = nil
    blademaster.damageCapture.pendingType = nil
  else
    blademaster.damageCapture.pendingPrimary = damage
    blademaster.damageCapture.pendingLimb = side
    blademaster.damageCapture.pendingType = "leg"
    blademaster.damageCapture.lastCaptureTime = now
  end
end

function blademaster.captureArmDamage(damage, side)
  damage = tonumber(damage) or 0
  local now = os.time()

  if blademaster.damageCapture.pendingPrimary and
     blademaster.damageCapture.pendingType == "arm" and
     (now - blademaster.damageCapture.lastCaptureTime) < 2 then
    blademaster.stanceLd().armSecondaryDamage = damage
    blademaster.stanceLd().armPrimaryDamage = blademaster.damageCapture.pendingPrimary
    blademaster.state.lastPrimaryArm = blademaster.damageCapture.pendingLimb
    blademaster.damageCapture.pendingPrimary = nil
    blademaster.damageCapture.pendingLimb = nil
    blademaster.damageCapture.pendingType = nil
  else
    blademaster.damageCapture.pendingPrimary = damage
    blademaster.damageCapture.pendingLimb = side
    blademaster.damageCapture.pendingType = "arm"
    blademaster.damageCapture.lastCaptureTime = now
  end
end

function blademaster.captureUpperDamage(damage, limb)
  -- Centreslash hits torso and head with DIFFERENT damage values.
  damage = tonumber(damage) or 0
  if limb == "torso" then
    blademaster.stanceLd().torsoDamage = damage
  elseif limb == "head" then
    blademaster.stanceLd().headDamage = damage
  end
end

function blademaster.onImpaleSuccess()
  local wasImpaled = blademaster.state.isImpaled
  blademaster.state.isImpaled = true

  if blademaster.state.impaleslashDone then
    cecho("\n<green>[BM] RE-IMPALE confirmed! Continuing bladetwists...")
  elseif not wasImpaled then
    cecho("\n<cyan>[BM] First impale confirmed!")
  end
end

function blademaster.onImpaleslashSuccess()
  blademaster.state.impaleslashDone = true
  blademaster.state.bladetwistCount = 0
  cecho("\n<magenta>[BM] Impaleslash confirmed - arteries slashed!")
end

function blademaster.onBleedingReady()
  blademaster.state.bleedingReady = true
  cecho("\n<green>[BM] BLEEDING AT 700+ - BROKENSTAR READY!")
end

function blademaster.onBleedingUpdate(bleedValue)
  bleedValue = tonumber(bleedValue) or 0
  blademaster.state.targetBleeding = bleedValue
  if bleedValue >= blademaster.CONFIG.brokenstarBleedThreshold then
    blademaster.state.bleedingReady = true
  end
end

function blademaster.onTargetUnimpaled()
  -- Target escaped impale. Prone => FREE re-impale. Standing + legs broken =>
  -- re-impale. Standing + legs healed => back to leg prep.
  blademaster.state.isImpaled = false
  blademaster.state.withdrawDone = false
  -- Keep bleedingReady / targetBleeding / impaleslashDone — we built that progress.

  local targetProne = blademaster.hasAff("prone")
  local legsBroken = blademaster.checkBothLegsBroken()

  if targetProne then
    cecho("\n<green>[BM] Target writhed free but STILL PRONE - FREE RE-IMPALE!")
  elseif legsBroken then
    cecho("\n<red>[BM] Target writhed free and standing - RE-IMPALE! (legs still broken)")
  else
    cecho("\n<red>[BM] Target writhed free and standing - back to leg prep")
    blademaster.state.impaleslashDone = false
    blademaster.state.bleedingReady = false
    blademaster.state.targetBleeding = 0
  end
end

function blademaster.onWithdrawSuccess()
  blademaster.state.withdrawDone = true
  blademaster.state.isImpaled = false
  cecho("\n<yellow>[BM] Blade withdrawn - BROKENSTAR READY!")
end

function blademaster.onBladetwistSuccess()
  blademaster.state.bladetwistCount = blademaster.state.bladetwistCount + 1
end

function blademaster.onTargetStandUp(who)
  if who == target and blademaster.state.impaleslashDone then
    local bleedColor = blademaster.state.targetBleeding >= 700 and "<green>" or "<yellow>"
    cecho("\n<yellow>[BM] Target stood up! Bleed: " .. bleedColor .. blademaster.state.targetBleeding .. "<yellow> | Twists: " .. blademaster.state.bladetwistCount)
  end
end

--------------------------------------------------------------------------------
-- ALIAS HANDLERS  (point your manually-created Mudlet aliases at these)
--
-- This module self-registers NOTHING — no tempAlias, no tempRegexTrigger, no
-- event handler. Create the aliases, triggers and the one GMCP balance event
-- handler by hand in Mudlet, per:  ports/legacy_ak/blademaster/MUDLET_SETUP.md
--
--   * Your ALIASES call the bm*() functions below (they ARM the system).
--   * Your TRIGGERS call the blademaster.on*/capture* functions defined above
--     (onImpaleSuccess, captureLegDamage, onBleedingUpdate, etc.).
--   * A balance/equilibrium-USED trigger calls blademaster.scheduleDispatch(
--     <recover time>) — REQUIRED for just-in-time firing. It arms a tempTimer
--     that runs run() the instant balance/eq returns. Without it, only arm()'s
--     fire-when-ready path works (one attack when you arm with balance up).
--------------------------------------------------------------------------------

function bm()              blademaster.arm() end
function bmd()             blademaster.state.mode = "double"; blademaster.arm() end
function bmdispatch()      blademaster.state.mode = "double"; blademaster.arm() end
function bmdq()            blademaster.state.mode = "quad"; blademaster.arm() end
function bmdispatchquad()  blademaster.state.mode = "quad"; blademaster.arm() end
function bmbs()            blademaster.state.mode = "brokenstar"; blademaster.arm() end
function bmdispatchbs()    blademaster.state.mode = "brokenstar"; blademaster.arm() end
function bmgroup()         blademaster.state.mode = "group"; blademaster.arm() end
function bmreset()         blademaster.fullReset() end
function bmstatus()        blademaster.dispatch.statusDoublePrep() end
function bmstatusq()       blademaster.dispatch.statusQuadPrep() end

cecho("\n<green>[BM] Blademaster Dispatch loaded<reset> (mode: " .. blademaster.state.mode .. ")")
cecho("\n<yellow>[BM] Aliases / triggers / balance-handler are MANUAL — see MUDLET_SETUP.md")