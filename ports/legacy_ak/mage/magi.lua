--[[
================================================================================
MAGI UNIFIED OFFENSE — LEGACY / AK PORT  (Elementalism)
================================================================================

Consolidation of the LEVI/Ataxia Magi combat scripts:
  - mage/001_Resonance.lua          (resonance state engine)
  - mage/004_Magi_Offense.lua       (unified 5-mode decision tree)
  - mage/005_Stormhammer_Targeting.lua (3-target stormhammer selector)

NOT ported (per the port decision):
  - mage/004_Mizik_Bullshit.lua     (legacy/foreign MagiFire loop — superseded)
  - mage/006_Target_Priority.lua    (tprio — class-agnostic targeting queue,
                                      heavily Levi-coupled; omitted like the other
                                      ports, which "trust the user's `tar X`")

Five modes, one file (mode is a preference, re-read live every dispatch):
  fire   → burns → conflagrate → destroy / stormhammer        (default)
  water  → freeze → hypothermia → glaciate
  lock   → kelp stack → truelock via resonance affs
  salve  → salve-pressure via earth/fire resonance
  group  → stormhammer multi-target + damage

Convenience handlers (point manually-created Mudlet aliases at these):
  mfire()    set fire mode  + dispatch        (default)
  mwater()   set water mode + dispatch
  mlock()    set lock mode  + dispatch
  msalve()   set salve mode + dispatch
  mgroup()   set group mode + dispatch
  mm()       dispatch in the CURRENT mode
  mstatus()  read-only status
  mreset()   reset runtime state (mode-local + storm targets)

This module self-registers NOTHING — no tempAlias, no tempRegexTrigger, no
registerAnonymousEventHandler. Wire everything by hand; see MUDLET_SETUP.md.

--------------------------------------------------------------------------------
DEPENDENCY MAPPING  (see ports/legacy_ak/mage/DEPENDENCIES.md)
--------------------------------------------------------------------------------
AK (target state) — opponent afflictions live in affstrack.score[aff] (0-100):
  haveAff("X") / getAffProbabilityV3("X")  -> has("X") / prob("X")
  tAffs.X belt-and-suspenders fallback     -> dropped (no V1 table in AK)
  haveAff("shield") / haveAff("rebounding")-> ak.defs.shield / ak.defs.rebounding
  targetHealth / php                       -> targetHpPct() (ak.currenthealth/maxhealth)
  lb[target].hits[limb] (0-200)            -> unchanged (broken = >= breakThreshold)

  Magi-mechanic opponent states — the source SELF-TRACKED these in
  magi.offense.state, fed by Levi triggers. This port reads them ALL from AK
  affstrack instead (the chosen strategy). Confirm these keys exist in YOUR AK:
    state.burns (0-5)        -> floor(affstrack.score.aflame / CONFIG.aflameScale)
    state.conflagrated       -> affstrack.score.conflagrate  >= CONFIG.fullThreshold
    state.scalded            -> affstrack.score.scalded       >= CONFIG.fullThreshold
    state.calcifiedTorso     -> affstrack.score.calcifiedtorso>= CONFIG.fullThreshold
    state.calcifiedSkull     -> affstrack.score.calcifiedhead >= CONFIG.fullThreshold
    state.shalestorm         -> has("shalestorm")
    state.hypothermia        -> prob("hypothermia") >= 0.5
    state.frozen             -> prob("frozen") >= 0.5
    state.scintillaSpark     -> DROPPED (internal cooldown marker, not an AK aff)
    state.firestorm          -> DROPPED (referenced a removed legacy global)

Legacy (self state):
  ataxia.afflictions.aeon       -> selfAff("aeon")  (Legacy.Curing.Affs.aeon)
  ataxia.settings.separator     -> CONFIG.separator ("/" — SETALIAS ATK pattern)
  ataxia.settings.paused        -> isPaused()  (Legacy.Settings.Curing.status == false)
  partyrelay (global)           -> CONFIG.partyRelay (toggle)
  send("queue addclearfull freestand X") -> sendAttack(X) (SETALIAS ATK / QUEUE ADDCLEARFULL FREESTAND)
  magi.staff / "shield"         -> CONFIG.WEAPONS.STAFF / .SHIELD
  gmcp.Char.Status.class        -> unchanged (class guard)
  gmcp.Char.Vitals.bal / .eq    -> balUp() / eqUp()

Stormhammer multi-target (005) — Levi room/enemy/NDB infra is absent in AK, so:
  ataxia.playersHere            -> gmcp.Room.Players  (standard IRE GMCP)
  ataxiaTemp.enemies            -> magi.storm.isEnemy() (override point; safe
                                   default = current target only)
  ataxiaNDB_getCitizenship      -> guarded; "city" mode degrades to "all" if absent
  tprio.list ("priority" mode)  -> guarded; degrades to "all" (tprio not ported)
  gmcp.Char.Name                -> unchanged (self-exclusion)
================================================================================
]] --

-- ============================================================
--  NAMESPACE INIT
-- ============================================================
magi = magi or {}
magi.offense = magi.offense or {}
magi.storm = magi.storm or {}
magi.resonance = magi.resonance or { earth = 0, water = 0, air = 0, fire = 0 }

magi.offense.mode = magi.offense.mode or "fire"

-- ============================================================
--  CONFIG  (all tunables)
-- ============================================================
magi.offense.CONFIG = magi.offense.CONFIG or {
  -- AK affstrack confidence threshold (0-100). affstrack.score[aff] >= this
  -- counts as "present" for boolean has() checks. 30 matches Levi V3.
  affThreshold = 30,
  -- Threshold for FULLY-applied binary class states (conflagrate/scalded/calcify).
  -- The source treated these as 100 = present (Mizik used == 100 / >= 100).
  fullThreshold = 100,
  -- AK stores burns as `aflame`. Source/Mizik scale: aflame 200 == 2 burns,
  -- i.e. burns = aflame / 100. Set to 1 if YOUR AK stores the raw 0-5 count.
  aflameScale = 100,

  destroyThreshold = 35,       -- conflagrated + HP% below this -> DESTROY
  stormhammerThreshold = 25,   -- HP% at/below this -> stormhammer kill
  groupStormThreshold = 50,    -- group mode stormhammers earlier
  breakThreshold = 100,        -- lb[target].hits[limb] >= this == "broken"

  separator = "/",             -- command separator (SETALIAS ATK pattern)
  partyRelay = true,           -- send "pt <msg>" route callouts (off in aeon)
  classGuard = true,           -- bail if gmcp says we aren't Magi
  debugEcho = false,           -- verbose per-decision echo

  useArachnideye = false,      -- artefact: prefix "arachnideye trample <t>"
  useWebbomb = false,          -- artefact: prefix "webbomb <t>"

  WEAPONS = {
    STAFF = "staff569815",     -- your Artificing staff item id
    SHIELD = "shield",         -- shield item id (or literal "shield")
  },
}

-- ============================================================
--  RUNTIME STATE  (minimal — opponent state is read live from AK)
-- ============================================================
magi.offense.state = magi.offense.state or {
  lastSpell = nil,
}

-- ============================================================
--  AK / GMCP / LEGACY HELPERS  (file-local)
-- ============================================================
local C = magi.offense.CONFIG

-- Raw 0-100 confidence for an opponent affliction (nil-safe).
local function score(aff)
  return (affstrack and affstrack.score and affstrack.score[aff]) or 0
end

-- 0.0-1.0 probability (source's getAffProbabilityV3 analogue).
local function prob(aff)
  return score(aff) / 100
end

-- Boolean presence at the configured confidence threshold.
local function has(aff)
  return score(aff) >= C.affThreshold
end

-- Opponent defenses (shield / rebounding) from AK.
local function akDef(def)
  return ak and ak.defs and ak.defs[def]
end

-- Opponent HP percent (display + kill thresholds).
local function targetHpPct()
  if ak and ak.currenthealth and ak.maxhealth and tonumber(ak.maxhealth) and tonumber(ak.maxhealth) > 0 then
    return (tonumber(ak.currenthealth) / tonumber(ak.maxhealth)) * 100
  end
  return 100
end

-- Limb damage (0-200). AK and Levi both use lb[target].hits[limb].
local function limbDmg(limb)
  if not target or target == "" then return 0 end
  if not (lb and lb[target] and lb[target].hits) then return 0 end
  return lb[target].hits[limb] or 0
end

local function limbBroken(limb)
  return limbDmg(limb) >= C.breakThreshold
end

-- Self afflictions (Legacy curing domain).
local function selfAff(name)
  local a = Legacy and Legacy.Curing and Legacy.Curing.Affs
  return a and a[name]
end

-- Combat paused? (parity with the other ports.)
local function isPaused()
  return Legacy and Legacy.Settings and Legacy.Settings.Curing and Legacy.Settings.Curing.status == false
end

local function balUp()
  return gmcp and gmcp.Char and gmcp.Char.Vitals and gmcp.Char.Vitals.bal == "1"
end

local function eqUp()
  return gmcp and gmcp.Char and gmcp.Char.Vitals and gmcp.Char.Vitals.eq == "1"
end

local function gmcpClass()
  return gmcp and gmcp.Char and gmcp.Char.Status and gmcp.Char.Status.class
end

local function myName()
  return (gmcp and gmcp.Char and gmcp.Char.Name) or (gmcp and gmcp.Char and gmcp.Char.Status and gmcp.Char.Status.name)
end

-- Legacy SETALIAS ATK / QUEUE ADDCLEARFULL pattern (separator-joined chain).
local function sendAttack(cmd, queueType)
  send("SETALIAS ATK " .. cmd)
  send("QUEUE ADDCLEARFULL " .. (queueType or "FREESTAND") .. " ATK")
end

-- ============================================================
--  RESONANCE  (GMCP charstats — self-owned, gmcp is shared)
-- ============================================================
-- Parses gmcp.Char.Vitals.charstats for rair/rfire/rearth/rwater levels.
-- minor=1, moderate=2, major=3, else 0. Kept faithful to 001_Resonance.lua.
function get_resonance()
  if not (gmcp and gmcp.Char and gmcp.Char.Vitals and gmcp.Char.Vitals.charstats) then return end
  local function level(v)
    local lvl = v:split(":")[2]
    if not lvl then return 0 end
    lvl = lvl:trim():lower()
    if lvl == "major" then return 3
    elseif lvl == "moderate" then return 2
    elseif lvl == "minor" then return 1
    else return 0 end
  end
  for _, v in pairs(gmcp.Char.Vitals.charstats) do
    if string.match(v, "rair") then magi.resonance.air = level(v) end
    if string.match(v, "rfire") then magi.resonance.fire = level(v) end
    if string.match(v, "rearth") then magi.resonance.earth = level(v) end
    if string.match(v, "rwater") then magi.resonance.water = level(v) end
  end
end

-- ============================================================
--  MAGI-MECHANIC OPPONENT STATE  (read live from AK affstrack)
-- ============================================================
-- Burns count 0-5.
function magi.offense.getBurns()
  return math.min(math.floor(score("aflame") / C.aflameScale), 5)
end

function magi.offense.isConflagrated()  return score("conflagrate") >= C.fullThreshold end
function magi.offense.isScalded()       return score("scalded") >= C.fullThreshold end
function magi.offense.isCalcifiedTorso() return score("calcifiedtorso") >= C.fullThreshold end
function magi.offense.isCalcifiedSkull() return score("calcifiedhead") >= C.fullThreshold end

-- ============================================================
--  ECHO HELPERS
-- ============================================================
function magi.offense.echo(text)
  cecho("\n<dark_orchid>[<cornflower_blue>Magi<dark_orchid>]<lavender> " .. text)
end

function magi.offense.debugEcho(text)
  if C.debugEcho then
    magi.offense.echo("<dim_grey>" .. text)
  end
end

function magi.offense.ptRelay(msg)
  if C.partyRelay and not selfAff("aeon") then
    send("pt " .. msg, false)
  end
end

-- ============================================================
--  TARGET-STATE HELPERS
-- ============================================================
function magi.offense.hasShield()
  return akDef("rebounding") or akDef("shield")
end

function magi.offense.targetShielded()
  return akDef("shield")
end

function magi.offense.getTargetHP()
  return targetHpPct()
end

-- Count afflictions consuming the target's mending/salve balance. Magi is a
-- salve-pressure class: freeze is stronger when mending is occupied.
function magi.offense.countMendingAffs()
  local count = 0
  for _, limb in ipairs({ "left leg", "right leg", "left arm", "right arm" }) do
    if limbBroken(limb) then count = count + 1 end
  end
  count = count + magi.offense.getBurns()
  if magi.offense.isCalcifiedTorso() then count = count + 1 end
  if magi.offense.isCalcifiedSkull() then count = count + 1 end
  return count
end

-- ============================================================
--  METEORITE SHIELD-BREAKING  (4 variants — xMagi reference)
-- ============================================================
function magi.offense.selectMeteorite()
  local r = magi.resonance
  local fireWillBurn = (r.fire > 0) and (r.fire < 3)

  if fireWillBurn then
    return "cast meteorite at " .. target .. " flaming 4"
  elseif r.earth < 3 or magi.offense.isCalcifiedTorso() then
    return "cast meteorite at " .. target .. " pure 4"
  elseif r.water < 3 then
    return "cast meteorite at " .. target .. " frozen 4"
  else
    return "cast erode at " .. target .. " maintain"
  end
end

-- ============================================================
--  UNIFIED DECISION TREE  (xMagi reference)
-- ============================================================
function magi.offense.selectSpell()
  local r = magi.resonance
  local mode = magi.offense.mode
  local hp = magi.offense.getTargetHP()

  -- Pre-compute conditions
  local fireWillBurn = (r.fire > 0) and (r.fire < 3)
  local freso = (r.water >= 2) and (r.air >= 2) -- freeze resonance threshold
  local asthma = prob("asthma")
  local scalded = magi.offense.isScalded()
  local burning = magi.offense.getBurns()
  local caloric = not has("nocaloric") -- nocaloric aff up == caloric defence down
  local frostbite = prob("frostbite")
  local shivering = prob("shivering")
  local weariness = prob("weariness")
  local nausea = prob("nausea")
  local dehydrateWillFreeze = (nausea >= 0.5) and (weariness < 0.5)

  local emearth = (not magi.offense.isCalcifiedTorso()) and (r.earth == 3)
    and (frostbite >= 0.5 or burning > 1 or shivering >= 0.5 or not caloric)

  --=== PRIORITY 1: DESTROY (conflagrated + low HP) ===--
  if magi.offense.isConflagrated() and hp < C.destroyThreshold then
    return "cast destroy at " .. target
  end

  --=== PRIORITY 2: SHIELD STRIP (meteorite variants) ===--
  if magi.offense.targetShielded() then
    return magi.offense.selectMeteorite()
  end

  --=== PRIORITY 3: GLACIATE (hypothermia + dual resonance) ===--
  local frozen = prob("frozen") >= 0.5
  local hypothermia = prob("hypothermia") >= 0.5
  if hypothermia and freso then
    return "cast glaciate at " .. target
  end

  --=== PRIORITY 4: STORMHAMMER (low HP kill) ===--
  if hp <= C.stormhammerThreshold then
    magi.storm.selectTargets()
    magi.storm.fire()
    return nil -- storm.fire sends directly
  end

  --=== PRIORITY 5: SHALESTORM+SCINTILLA (free calcify when shalestorm active) ===--
  -- (scintillaSpark gate dropped — internal cooldown marker, not an AK aff)
  if has("shalestorm") and not magi.offense.isCalcifiedTorso()
     and r.earth >= 2
     and burning < 5
     and not (burning >= 2 and r.fire >= 2) then
    return "staffcast scintilla at " .. target
  end

  --=== PRIORITY 6: EMANATION EARTH (earth capped + conditions met) ===--
  if emearth then
    return "cast emanation at " .. target .. " earth"
  end

  --=== PRIORITY 7: HYPOTHERMIA (frozen + dual resonance) ===--
  if frozen and not hypothermia and freso then
    return "cast hypothermia at " .. target
  end

  --=== PRIORITY 8: MUDSLIDE (asthma + water==2) ===--
  if asthma >= 0.5 and r.water == 2 then
    return "cast mudslide at " .. target
  end

  --=== MODE-SPECIFIC BRANCHES ===--
  if mode == "lock" then return magi.offense.selectLockSpell() end
  if mode == "salve" then return magi.offense.selectSalveSpell() end
  if mode == "group" then return magi.offense.selectGroupSpell() end

  --=== PRIORITY 9: MAGMA (not scalded) ===--
  if not scalded then
    return "cast magma at " .. target
  end

  --=== PRIORITY 10: FREEZE (shivering + broken limb) ===--
  if shivering >= 0.5 and magi.offense.countMendingAffs() >= 1 then
    return "cast freeze at " .. target
  end

  --=== PRIORITY 11: CALCIFIED PATH ===--
  if magi.offense.isCalcifiedTorso() and (frostbite >= 0.5 or not caloric) then
    if dehydrateWillFreeze and fireWillBurn then
      return "cast dehydrate at " .. target
    else
      return "cast freeze at " .. target
    end
  end

  --=== PRIORITY 12: BURNING PATH (burns management) ===--
  if burning > 0 then
    return magi.offense.selectBurningSpell()
  end

  --=== PRIORITY 13: SHALESTORM (earth >= 2, not active) ===--
  if not has("shalestorm") and r.earth >= 2 then
    return "cast shalestorm at " .. target
  end

  --=== FALLBACK ===--
  return magi.offense.selectFallback()
end

-- ============================================================
--  BURNING SUB-TREE  (xMagi reference)
-- ============================================================
function magi.offense.selectBurningSpell()
  local r = magi.resonance
  local burning = magi.offense.getBurns()
  local fireWillBurn = (r.fire > 0) and (r.fire < 3)
  local frostbite = prob("frostbite")
  local weariness = prob("weariness")
  local nausea = prob("nausea")
  local caloric = not has("nocaloric")
  local dehydrateWillFreeze = (nausea >= 0.5) and (weariness < 0.5)

  -- Conflagrate when ready (requires burns >= 2, fire >= 2)
  if burning >= 2 and r.fire >= 2 and not magi.offense.isConflagrated() then
    return "cast conflagrate at " .. target
  end

  -- Dehydrate for freeze + burn combo
  if (not caloric or frostbite >= 0.5) and dehydrateWillFreeze and fireWillBurn then
    return "cast dehydrate at " .. target
  end

  -- Fulminate to build air+fire
  if r.air == 0 and r.water == 2 and fireWillBurn then
    return "cast fulminate at " .. target
  end

  -- Dehydrate if weariness is present (stacks burns)
  if fireWillBurn and weariness >= 0.5 then
    return "cast dehydrate at " .. target
  end

  -- Emanation fire at cap
  if r.fire == 3 then
    return "cast emanation at " .. target .. " fire"
  end

  -- Earth building
  if r.earth == 1 then
    if fireWillBurn then
      return "cast magma at " .. target
    else
      return "cast bombard at " .. target
    end
  end

  -- Emanation water at cap
  if r.water == 3 then
    return "cast emanation at " .. target .. " water"
  end

  -- Default: dehydrate (builds burns + water)
  return "cast dehydrate at " .. target
end

-- ============================================================
--  LOCK SUB-TREE
-- ============================================================
function magi.offense.selectLockSpell()
  local r = magi.resonance

  -- Horripilation for waterbond/blistered if not present
  if not has("waterbond") and not has("blistered")
     and not magi.offense.isCalcifiedTorso() and not has("paralysis")
     and not has("anorexia") then
    if r.fire == 2 then
      return "cast fulminate at " .. target
    else
      return "staffcast horripilation " .. target
    end
  end

  -- Scalded path for calcify
  if not magi.offense.isScalded() then
    return "cast magma at " .. target
  end

  -- Scintilla for calcify at earth major
  if r.earth == 3 and not magi.offense.isCalcifiedTorso() then
    return "staffcast scintilla at " .. target
  end

  -- Emanation earth at cap (if calcified)
  if r.earth == 3 and magi.offense.isCalcifiedTorso() then
    return "cast emanation at " .. target .. " earth"
  end

  -- Build earth
  if r.earth < 2 then
    if not has("clumsiness") then
      return "cast bombard at " .. target
    else
      return "cast mudslide at " .. target
    end
  end

  -- Build air
  if r.air < 3 then
    return "cast fulminate at " .. target
  end

  -- Emanation air at cap
  if r.air == 3 then
    return "cast emanation at " .. target .. " air"
  end

  return "cast dehydrate at " .. target
end

-- ============================================================
--  SALVE SUB-TREE  (earth/fire resonance for salve-curable affs)
-- ============================================================
function magi.offense.selectSalveSpell()
  local r = magi.resonance

  -- Emanation earth at cap (salve-curable: broken limbs, cracked ribs)
  if r.earth == 3 then
    return "cast emanation at " .. target .. " earth"
  end

  -- Scalded for salve pressure (salve balance lock)
  if not magi.offense.isScalded() then
    return "cast magma at " .. target
  end

  -- Scintilla for calcified torso (blocks restoration salve)
  if r.earth >= 2 and not magi.offense.isCalcifiedTorso() then
    return "staffcast scintilla at " .. target
  end

  -- Build earth resonance (earth affs are salve-cured)
  if r.earth < 3 then
    return "cast bombard at " .. target
  end

  -- Emanation fire at cap (scalded/ablaze are salve-pressure)
  if r.fire == 3 then
    return "cast emanation at " .. target .. " fire"
  end

  -- Build fire for scalded pressure
  return "cast dehydrate at " .. target
end

-- ============================================================
--  GROUP SUB-TREE  (damage + stormhammer multi-target)
-- ============================================================
function magi.offense.selectGroupSpell()
  local r = magi.resonance
  local hp = magi.offense.getTargetHP()

  -- Stormhammer at higher threshold for group
  if hp <= C.groupStormThreshold then
    magi.storm.selectTargets()
    magi.storm.fire()
    return nil
  end

  if r.fire == 3 then return "cast emanation at " .. target .. " fire" end
  if r.earth == 3 then return "cast emanation at " .. target .. " earth" end

  if not has("shalestorm") and r.earth >= 2 then
    return "cast shalestorm at " .. target
  end

  if not magi.offense.isScalded() then
    return "cast magma at " .. target
  end

  return "cast dehydrate at " .. target
end

-- ============================================================
--  FALLBACK SUB-TREE
-- ============================================================
function magi.offense.selectFallback()
  local r = magi.resonance

  if not has("shalestorm") then
    if r.earth >= 2 then
      return "cast shalestorm at " .. target
    else
      return "cast bombard at " .. target
    end
  end

  if r.fire == 3 then
    return "cast emanation at " .. target .. " fire"
  end

  if r.earth < 3 and r.fire < 3 then
    return "cast magma at " .. target
  end

  return "cast dehydrate at " .. target
end

-- ============================================================
--  SEND ATTACK
-- ============================================================
function magi.offense.sendAttack(spell)
  if not spell then return end

  local sep = C.separator
  local staff = C.WEAPONS.STAFF
  local shield = C.WEAPONS.SHIELD
  local prefix = ""

  -- Optional utility prefix (free actions, don't consume spell balance)
  if C.useArachnideye and not has("prone") then
    prefix = "arachnideye trample " .. target .. sep
  elseif C.useWebbomb and not has("entangled") then
    prefix = "webbomb " .. target .. sep
  end

  local cmd = prefix .. "stand" .. sep .. "wield " .. staff .. " " .. shield
  cmd = cmd .. sep .. spell .. sep .. "assess " .. target

  sendAttack(cmd, "FREESTAND")

  magi.offense.state.lastSpell = spell
  magi.offense.debugEcho("Sent: " .. spell)
end

-- ============================================================
--  MAIN DISPATCH
-- ============================================================
function magi.offense.dispatch()
  -- Guard: class
  if C.classGuard and gmcpClass() and gmcpClass() ~= "Magi" then return end

  -- Guard: paused
  if isPaused() then return end

  -- Guard: balance + equilibrium (fire-when-ready; harmless to re-press)
  if not balUp() or not eqUp() then return end

  -- Guard: aeon
  if selfAff("aeon") then
    magi.offense.echo("<red>In aeon - cannot attack")
    return
  end

  -- Guard: no target
  if not target or target == "" then
    magi.offense.echo("<red>No target set")
    return
  end

  -- Refresh resonance from GMCP, then select + send
  get_resonance()
  magi.offense.sendAttack(magi.offense.selectSpell())
end

-- ============================================================
--  MODE MANAGEMENT / STATUS / RESET
-- ============================================================
function magi.offense.setMode(mode)
  local valid = { fire = true, water = true, lock = true, salve = true, group = true }
  if valid[mode] then
    if magi.offense.mode ~= mode then
      magi.offense.echo("<gold>Mode set to: <white>" .. mode)
    end
    magi.offense.mode = mode
  else
    magi.offense.echo("<red>Invalid mode: " .. tostring(mode) .. " (fire/water/lock/salve/group)")
  end
end

function magi.offense.reset()
  magi.storm.targets = {}
  magi.storm.starbursted = {}
  magi.offense.state.lastSpell = nil
end

function magi.offense.status()
  get_resonance()
  local r = magi.resonance
  magi.offense.echo("<gold>--- Magi Offense Status ---")
  cecho("\n <cornflower_blue>Mode: <white>" .. magi.offense.mode)
  cecho("\n <cornflower_blue>Resonance: <red>F:" .. r.fire .. " <dodger_blue>W:" .. r.water ..
        " <saddle_brown>E:" .. r.earth .. " <light_sky_blue>A:" .. r.air)
  cecho("\n <cornflower_blue>Burns: <orange_red>" .. magi.offense.getBurns() ..
        (magi.offense.isConflagrated() and " <red>[CONFLAGRATED]" or ""))
  cecho("\n <cornflower_blue>Scalded: " .. (magi.offense.isScalded() and "<orange_red>YES" or "<dim_grey>no"))
  cecho("\n <cornflower_blue>Calcify: " .. (magi.offense.isCalcifiedTorso() and "<red>TORSO" or "<dim_grey>-") ..
        " " .. (magi.offense.isCalcifiedSkull() and "<red>SKULL" or "<dim_grey>-"))
  cecho("\n <cornflower_blue>Shalestorm: " .. (has("shalestorm") and "<green>ACTIVE" or "<dim_grey>no"))
  cecho("\n <cornflower_blue>Hypothermia: " .. (prob("hypothermia") >= 0.5 and "<dodger_blue>YES" or "<dim_grey>no"))
  cecho("\n <cornflower_blue>Frozen: " .. (prob("frozen") >= 0.5 and "<dodger_blue>YES" or "<dim_grey>no"))
  cecho("\n <cornflower_blue>Arachnideye: " .. (C.useArachnideye and "<green>ON" or "<dim_grey>off"))
  cecho("\n <cornflower_blue>Webbomb: " .. (C.useWebbomb and "<green>ON" or "<dim_grey>off"))
  echo("\n")
end

-- ============================================================
--  STORMHAMMER MULTI-TARGET  (ported from 005)
-- ============================================================
magi.storm.targets = magi.storm.targets or {}
magi.storm.starbursted = magi.storm.starbursted or {}
magi.storm.mode = magi.storm.mode or "all" -- "city" | "all" | "priority"
-- User-populated enemy set for multi-target. Names are case-sensitive and must
-- match the room-player names. Override magi.storm.isEnemy() for richer logic.
magi.storm.enemies = magi.storm.enemies or {}

function magi.storm.setMode(mode)
  local valid = { city = true, all = true, priority = true }
  if valid[mode] then
    magi.storm.mode = mode
    magi.offense.echo("Stormhammer mode set to: " .. mode)
  else
    magi.offense.echo("<red>Invalid stormhammer mode: " .. tostring(mode) .. " (city/all/priority)")
  end
end

function magi.storm.getMode()
  return magi.storm.mode
end

-- Override point. Default: the current target is always an enemy; otherwise a
-- name is an enemy only if it's in magi.storm.enemies. This is the SAFE default
-- (never hits allies). Wire in your framework's enemy list to enable real
-- multi-target sweeps.
function magi.storm.isEnemy(name)
  if name == target then return true end
  return magi.storm.enemies[name] == true
end

-- Players in room from standard IRE GMCP (Room.Players). Returns {name,...}.
local function roomPlayers()
  local out = {}
  local players = gmcp and gmcp.Room and gmcp.Room.Players
  if type(players) ~= "table" then return out end
  for _, entry in pairs(players) do
    local name
    if type(entry) == "table" then
      name = entry.name or entry.fullname
    elseif type(entry) == "string" then
      name = entry
    end
    if name then
      name = name:gsub("^the soul of ", "")
      table.insert(out, name)
    end
  end
  return out
end

-- Enemies in room from the same city as the target (degrades to "all" if no
-- citizenship lookup is available in this framework).
local function findTargetsCity()
  local candidates = {}
  local me = myName()
  if not ataxiaNDB_getCitizenship then return nil end -- signal: degrade to all
  local targetCity = ataxiaNDB_getCitizenship(target)
  if not targetCity or targetCity == "" then return candidates end
  for _, person in ipairs(roomPlayers()) do
    if person ~= me and magi.storm.isEnemy(person)
       and ataxiaNDB_getCitizenship(person) == targetCity then
      table.insert(candidates, person)
    end
  end
  return candidates
end

local function findTargetsAll()
  local candidates = {}
  local me = myName()
  for _, person in ipairs(roomPlayers()) do
    if person ~= me and magi.storm.isEnemy(person) then
      table.insert(candidates, person)
    end
  end
  return candidates
end

-- "priority" mode used tprio (not ported) — degrade to "all".
local function findTargetsPriority()
  return findTargetsAll()
end

function magi.storm.findTargets()
  local mode = magi.storm.mode
  if mode == "city" then
    local c = findTargetsCity()
    if c == nil then return findTargetsAll() end -- no NDB -> all
    return c
  elseif mode == "priority" then
    return findTargetsPriority()
  else
    return findTargetsAll()
  end
end

-- Pick up to 3 targets, guaranteeing the primary target is slot 1.
function magi.storm.selectTargets()
  magi.storm.targets = {}
  magi.storm.starbursted = {}
  local candidates = magi.storm.findTargets()

  if target and target ~= "" then
    for i, name in ipairs(candidates) do
      if name == target then
        if i ~= 1 then
          table.remove(candidates, i)
          table.insert(candidates, 1, target)
        end
        break
      end
    end
    -- Ensure the primary target is present even if isEnemy/room missed it.
    if candidates[1] ~= target then
      table.insert(candidates, 1, target)
    end
  end

  for i = 1, math.min(3, #candidates) do
    table.insert(magi.storm.targets, candidates[i])
  end
end

-- Replace a dead target (no starburst) with the next available enemy.
function magi.storm.replaceDead(deadName)
  if magi.storm.starbursted[deadName] then
    magi.storm.starbursted[deadName] = nil
    return
  end
  for i, name in ipairs(magi.storm.targets) do
    if name == deadName then
      local candidates = magi.storm.findTargets()
      for _, c in ipairs(candidates) do
        if not table.contains(magi.storm.targets, c) then
          magi.storm.targets[i] = c
          magi.offense.echo("Stormhammer: replaced " .. deadName .. " with " .. c)
          return
        end
      end
      table.remove(magi.storm.targets, i)
      magi.offense.echo("Stormhammer: " .. deadName .. " died, no replacement available")
      return
    end
  end
end

-- Build and send the stormhammer command (1-3 targets joined with "and").
function magi.storm.fire()
  if #magi.storm.targets == 0 then
    magi.storm.selectTargets()
  end
  if #magi.storm.targets == 0 then
    magi.offense.echo("<gold>No enemies in room for stormhammer")
    return
  end
  local cmd = "cast stormhammer at " .. magi.storm.targets[1]
  if magi.storm.targets[2] then cmd = cmd .. " and " .. magi.storm.targets[2] end
  if magi.storm.targets[3] then cmd = cmd .. " and " .. magi.storm.targets[3] end
  magi.offense.echo("Stormhammer: " .. table.concat(magi.storm.targets, ", "))
  sendAttack(cmd, "FREESTAND")
end

-- ============================================================
--  TOP-LEVEL ALIAS HANDLERS  (point manually-created aliases here)
-- ============================================================
function mfire()  magi.offense.setMode("fire");  magi.offense.dispatch() end
function mwater() magi.offense.setMode("water"); magi.offense.dispatch() end
function mlock()  magi.offense.setMode("lock");  magi.offense.dispatch() end
function msalve() magi.offense.setMode("salve"); magi.offense.dispatch() end
function mgroup() magi.offense.setMode("group"); magi.offense.dispatch() end
function mm()     magi.offense.dispatch() end
function mstatus() magi.offense.status() end
function mreset() magi.offense.reset() end
