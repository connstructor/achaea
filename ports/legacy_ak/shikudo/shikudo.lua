--[[
SHIKUDO GOD MODE - LEGACY / AK PORT

Fresh port of LEVI/Ataxia:
  src_new/scripts/levi_ataxia/levi/levi_scripts/shikudo/009_CC_Shikudo_GodMode.lua

This intentionally replaces the older consolidated Shikudo port. Dispatch, lock,
and riftlock modes are gone; this file owns one offense path: God Mode.

Host state mappings:
  haveAff/tAffs.X              -> affstrack.score[X] >= CONFIG.affThreshold
  lb[target].hits[limb]        -> unchanged
  ataxiaTemp.parriedLimb       -> targetparry
  ataxiaTemp.lastAssess        -> ak.currenthealth / ak.maxhealth
  ataxiaTemp.hyperLimb         -> ak.limbs.hyperfocus
  ataxia.vitals.form/kata/kai  -> gmcp.Char.Vitals.charstats
  ataxia.vitals hp/mp/max*     -> gmcp.Char.Vitals
  ataxia.defences.kaiboost     -> Legacy.Curing.Defs.current.kaiboost
  ataxia.afflictions.X         -> Legacy.Curing.Affs[X]
  ataxia.settings.paused       -> Legacy.Settings.Curing.status == false
  combatQueue()                -> removed; Legacy hooks live outside this file
  queue addclear free X       -> SETALIAS ATK X / QUEUE ADDCLEARFULL FREE ATK

Public entry points:
  monk.shikudo.arm()
  monk.shikudo.on_balance(interval)
  monk.shikudo.dispatch()
  monk.shikudo.godmode.run()
  monk.shikudo.status()
  monk.shikudo.godmode.status()
  monk.shikudo.reset()
  skgodmode(), skstatus(), skgmstatus(), skreset()
]]

monk = monk or {}
monk.shikudo = monk.shikudo or {}
monk.shikudo.godmode = monk.shikudo.godmode or {}
monk.telepathy = monk.telepathy or {}

-- Source compatibility for ad-hoc Mudlet aliases that call shikudo.* directly.
shikudo = monk.shikudo

local mod = monk.shikudo
local gmapi = monk.shikudo.godmode
local telepathy = monk.telepathy

mod.mode = "godmode"

mod.CONFIG = mod.CONFIG or {}
mod.CONFIG.affThreshold = mod.CONFIG.affThreshold or 30
mod.CONFIG.separator = mod.CONFIG.separator or "/"
mod.CONFIG.aliasName = mod.CONFIG.aliasName or "ATK"
mod.CONFIG.lockBreakCooldown = mod.CONFIG.lockBreakCooldown or 2
mod.CONFIG.godmodePrepThreshold = mod.CONFIG.godmodePrepThreshold or 92
mod.CONFIG.godmodeHeadPrepThreshold = mod.CONFIG.godmodeHeadPrepThreshold or 86
mod.CONFIG.godmodeLockForkMinAffs = mod.CONFIG.godmodeLockForkMinAffs or 3
mod.CONFIG.godmodeMaelstromHpThresh = mod.CONFIG.godmodeMaelstromHpThresh or 38
mod.CONFIG.mindlockStartWindow = mod.CONFIG.mindlockStartWindow or 3
mod.CONFIG.prearmInterval = mod.CONFIG.prearmInterval or nil
if mod.CONFIG.debug == nil then mod.CONFIG.debug = true end

mod.state = mod.state or {}
mod.state.kaiSurgeWindow = mod.state.kaiSurgeWindow or false
mod.state.next_bal_armed = mod.state.next_bal_armed or false
mod.state.next_bal_timer = mod.state.next_bal_timer or nil
mod.state.next_bal_deadline = mod.state.next_bal_deadline or nil

telepathy.mindlocked = telepathy.mindlocked or false
telepathy.starting_mindlock = telepathy.starting_mindlock or false

mod.limbDamage = mod.limbDamage or {
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
  jinzuku = 9.2
}

local gm = {}
local kataOverride = nil
local lockBreakCooldownUntil = 0

local GM_LOCK_AFFS = {
  "slickness", "asthma", "addiction", "weariness",
  "paralysis", "anorexia", "impatience", "confusion"
}

local LIMB_NAMES = {
  LL = "left leg",
  RL = "right leg",
  LA = "left arm",
  RA = "right arm",
  H = "head",
  T = "torso"
}

local FORM_NAMES = {
  tykonos = "Tykonos",
  willow = "Willow",
  rain = "Rain",
  oak = "Oak",
  gaital = "Gaital",
  maelstrom = "Maelstrom"
}

local function notify(msg)
  if cecho then
    cecho(msg)
  elseif print then
    local plain = tostring(msg):gsub("<[^>]->", "")
    print(plain)
  end
end

local function has(aff)
  if aff == "shield" and ak and ak.defs and (ak.defs.shield or ak.defs.shielded) then
    return true
  end
  local scores = affstrack and affstrack.score
  return scores and (scores[aff] or 0) >= mod.CONFIG.affThreshold
end

local function targetHpPct()
  if not ak or not ak.maxhealth or ak.maxhealth <= 0 then
    return 100
  end
  return math.floor(((ak.currenthealth or 0) / ak.maxhealth) * 100)
end

local function charstat(name)
  local vitals = gmcp and gmcp.Char and gmcp.Char.Vitals
  local cs = vitals and vitals.charstats
  if not cs then return nil end

  local wanted = name:lower()
  for _, entry in ipairs(cs) do
    local key, val = tostring(entry):match("^([^:]+):%s*(.+)$")
    if key and key:lower() == wanted then
      val = val:gsub("%%", "")
      return tonumber(val) or val
    end
  end
  return nil
end

local function currentForm()
  local f = charstat("Form")
  if type(f) ~= "string" then return nil end
  return FORM_NAMES[f:lower()] or f
end

local function currentKata()
  if kataOverride ~= nil then return kataOverride end
  return tonumber(charstat("Kata")) or 0
end

local function currentKai()
  return tonumber(charstat("Kai")) or 0
end

local function vital(key)
  local vitals = gmcp and gmcp.Char and gmcp.Char.Vitals
  return tonumber(vitals and vitals[key]) or 0
end

local function haveEqBal()
  local vitals = gmcp and gmcp.Char and gmcp.Char.Vitals
  return vitals and vitals.bal == "1" and vitals.eq == "1" or false
end

local function selfAff(name)
  local affs = Legacy and Legacy.Curing and Legacy.Curing.Affs
  return affs and affs[name] or false
end

local function selfDef(name)
  local defs = Legacy and Legacy.Curing and Legacy.Curing.Defs
  return defs and defs.current and defs.current[name] or false
end

local function isPaused()
  return Legacy
     and Legacy.Settings
     and Legacy.Settings.Curing
     and Legacy.Settings.Curing.status == false
end

local function isBashing()
  return Legacy
     and Legacy.Settings
     and Legacy.Settings.Basher
     and Legacy.Settings.Basher.status
end

local function selfNeedLockBreak()
  return selfAff("asthma")
     and selfAff("anorexia")
     and (selfAff("slickness") or selfAff("bloodfire"))
end

local function selfLockBreak()
  if os.time() < lockBreakCooldownUntil then return false end
  if not selfNeedLockBreak() then return false end

  if selfAff("prone") and not selfAff("paralysis") then
    send("stand", false)
  end
  send("fitness", false)
  lockBreakCooldownUntil = os.time() + mod.CONFIG.lockBreakCooldown
  return true
end

local function getLimb(key)
  if not target or not lb or not lb[target] or not lb[target].hits then
    return 0
  end
  return lb[target].hits[LIMB_NAMES[key]] or 0
end

local function normalizeLimb(limb)
  if not limb then return nil end
  limb = tostring(limb):lower():gsub("_", " ")
  limb = limb:gsub("^%s+", ""):gsub("%s+$", "")
  if limb == "" or limb == "none" or limb == "false" then return nil end
  if limb == "leftarm" then return "left arm" end
  if limb == "rightarm" then return "right arm" end
  if limb == "leftleg" then return "left leg" end
  if limb == "rightleg" then return "right leg" end
  return limb
end

local function parriedLimb()
  return normalizeLimb(targetparry) or "none"
end

local function currentHyperfocus()
  return normalizeLimb(ak and ak.limbs and ak.limbs.hyperfocus)
end

local function add(cmds, cmd)
  if cmd and cmd ~= "" then table.insert(cmds, cmd) end
end

local function copyCommands(cmds)
  local out = {}
  for i = 1, #cmds do out[i] = cmds[i] end
  return out
end

local function joined(cmds)
  return table.concat(cmds, mod.CONFIG.separator)
end

local function sendAttack(cmd, queueType)
  cmd = tostring(cmd or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if cmd == "" then return end
  send("SETALIAS " .. mod.CONFIG.aliasName .. " " .. cmd)
  send("QUEUE ADDCLEARFULL " .. (queueType or "FREE") .. " " .. mod.CONFIG.aliasName)
end

local function setStartingMindlock()
  telepathy.starting_mindlock = true
  if tempTimer then
    tempTimer(mod.CONFIG.mindlockStartWindow, function()
      telepathy.starting_mindlock = false
    end)
  end
end

local function sendCommands(cmds, queueType)
  for _, cmd in ipairs(cmds) do
    if cmd:match("^mind lock%s+") then
      setStartingMindlock()
    end
  end
  sendAttack(joined(cmds), queueType)
end

local function buildPrefixCommands()
  local cmds = {}

  local maxhp = vital("maxhp")
  local hp = vital("hp")
  local mp = vital("mp")
  local maxmp = vital("maxmp")
  local xmute = math.ceil(maxhp * 0.80)
  local mpl = mp - (maxmp * 0.30)
  local hpl = xmute - hp
  if hpl > 1 then
    local tomute = hpl < mpl and hpl or mpl
    if tomute > 100 then
      add(cmds, "transmute " .. math.floor(tomute))
    end
  end

  if target
     and not telepathy.mindlocked
     and not telepathy.starting_mindlock then
    add(cmds, "mind lock " .. target)
  end

  if currentKai() >= 11 and not selfDef("kaiboost") then
    add(cmds, "kai boost")
  end

  return cmds
end

function mod.startKaiSurgeWindow()
  mod.state.kaiSurgeWindow = true
  if mod.state._kaiSurgeTimer and killTimer then
    killTimer(mod.state._kaiSurgeTimer)
  end
  if tempTimer then
    mod.state._kaiSurgeTimer = tempTimer(15, function()
      mod.state.kaiSurgeWindow = false
      mod.state._kaiSurgeTimer = nil
    end)
  end
end

function mod.setMode(mode)
  if mode and mode ~= "godmode" then
    notify("\n<yellow>[Shikudo] Only godmode is implemented in this fresh Legacy/AK port.")
  end
  mod.mode = "godmode"
  return true
end

function gmapi.calcLimbs()
  local ld = mod.limbDamage
  local thresh = mod.CONFIG.godmodePrepThreshold
  local headThresh = mod.CONFIG.godmodeHeadPrepThreshold

  gm.LL = getLimb("LL")
  gm.RL = getLimb("RL")
  gm.LA = getLimb("LA")
  gm.RA = getLimb("RA")
  gm.H = getLimb("H")
  gm.T = getLimb("T")

  gm.laRUK = (gm.LA + ld.ruku >= 100)
  gm.raRUK = (gm.RA + ld.ruku >= 100)
  gm.laPREP = (gm.LA >= thresh)
  gm.raPREP = (gm.RA >= thresh)

  gm.llKUR = (gm.LL + ld.kuro >= 100) and not has("damagedleftleg")
  gm.rlKUR = (gm.RL + ld.kuro >= 100) and not has("damagedrightleg")
  gm.llFLASH = (gm.LL + ld.flashheel >= 100) and not has("damagedleftleg")
  gm.rlFLASH = (gm.RL + ld.flashheel >= 100) and not has("damagedrightleg")

  gm.hNEED = (gm.H + ld.needle >= 100)
  gm.hPREP = (gm.H >= headThresh)
  gm.hNERV = (gm.H + ld.nervestrike >= 100)
  gm.hHIRU = (gm.H + ld.hiru >= 100)
  gm.hHIRA = (gm.H + ld.hiraku >= 100)
  gm.hHIHI = (gm.H + ld.hiru + ld.hiraku >= 100)
  gm.hNERVRIS = (gm.H + ld.nervestrike + ld.risingkick >= 100)

  gm.bothLegsBroken = (has("brokenleftleg") or has("damagedleftleg"))
                   and (has("brokenrightleg") or has("damagedrightleg"))
  gm.bothArmsBroken = (has("brokenleftarm") or has("damagedleftarm"))
                   and (has("brokenrightarm") or has("damagedrightarm"))

  gm.executeReady = gm.llFLASH
                 and gm.rlFLASH
                 and gm.laPREP
                 and gm.raPREP
                 and gm.hPREP

  local lockCount = 0
  for _, aff in ipairs(GM_LOCK_AFFS) do
    if has(aff) then lockCount = lockCount + 1 end
  end
  gm.lockCount = lockCount
  gm.lockForkReady = gm.bothArmsBroken
                  and lockCount >= mod.CONFIG.godmodeLockForkMinAffs

  gm.lowHp = targetHpPct() <= mod.CONFIG.godmodeMaelstromHpThresh
end

local function shouldLight(limb, damageValue, simulated)
  local current = (gm[limb] or 0) + (simulated or 0)
  if limb == "LL" then
    return (current + damageValue >= 100) and not has("damagedleftleg")
  elseif limb == "RL" then
    return (current + damageValue >= 100) and not has("damagedrightleg")
  elseif limb == "LA" then
    return (current + damageValue >= 100) and not has("damagedleftarm")
  elseif limb == "RA" then
    return (current + damageValue >= 100) and not has("damagedrightarm")
  elseif limb == "H" then
    return (current + damageValue >= 100) and gm.hPREP
  end
  return false
end

local function tykonosPrios()
  gm.staff = {}
  gm.kick = "none"
  if not has("prone") then table.insert(gm.staff, "sweep") end
  gm.kick = gm.hNERVRIS and "risingkick torso" or "risingkick head"
end

local function willowPrios()
  gm.staff = {}
  gm.kick = "none"
  local ld = mod.limbDamage

  if not gm.llFLASH and parriedLimb() ~= "left leg" then
    gm.kick = "flashheel left"
  elseif not gm.rlFLASH then
    gm.kick = "flashheel right"
  else
    if not has("prone") then table.insert(gm.staff, "sweep") end
    gm.kick = "spinkick"
  end

  if not gm.hHIHI then
    table.insert(gm.staff, gm.hHIRU and "hiru light" or "hiru")
    table.insert(gm.staff, gm.hHIRA and "hiraku light" or "hiraku")
  else
    table.insert(gm.staff, "hiru light")
    table.insert(gm.staff, "hiraku light")
  end
end

local function rainPrios()
  gm.staff = {}
  gm.kick = "none"
  local k = currentKata()
  local ld = mod.limbDamage

  if gm.lockForkReady then
    gm.kick = "frontkick left"
    local slot1, slot2 = nil, nil
    if not has("weariness") then
      slot1 = "kuro left"
    elseif not has("lethargy") then
      slot1 = "kuro right"
    elseif not has("clumsiness") then
      slot1 = "ruku torso"
    end
    if not has("slickness") and not slot1 then
      slot1 = "ruku torso"
    elseif not has("slickness") then
      slot2 = "ruku torso"
    end
    if not slot1 then slot1 = "kuro left" end
    if not slot2 then slot2 = "kuro right" end
    table.insert(gm.staff, slot1)
    if slot2 then table.insert(gm.staff, slot2) end
    return
  end

  local allLegsDone = gm.llFLASH and gm.rlFLASH
  local allArmsDone = gm.laPREP and gm.raPREP

  if allLegsDone and allArmsDone and gm.hPREP then
    gm.kick = "none"
    if not has("slickness") then
      table.insert(gm.staff, "ruku torso")
    else
      table.insert(gm.staff, gm.hHIRU and "hiru light" or "hiru")
    end
    table.insert(gm.staff, "kuro light left")
    return
  end

  if allLegsDone and allArmsDone and not gm.hPREP then
    gm.kick = "none"
    table.insert(gm.staff, gm.hHIRU and "hiru light" or "hiru")
    table.insert(gm.staff, "kuro light left")
    return
  end

  local sim = {}
  local leftSafe = parriedLimb() ~= "left arm" and not gm.laRUK
  local rightSafe = parriedLimb() ~= "right arm" and not gm.raRUK
  if leftSafe and (not rightSafe or gm.LA <= gm.RA) then
    gm.kick = "frontkick left"
    sim.LA = (sim.LA or 0) + ld.frontkick
  elseif rightSafe then
    gm.kick = "frontkick right"
    sim.RA = (sim.RA or 0) + ld.frontkick
  else
    gm.kick = "none"
  end

  local function pickKuro()
    if not gm.llKUR and (gm.rlKUR or gm.LL <= gm.RL) then
      local light = shouldLight("LL", ld.kuro, sim.LL)
      local s = light and "kuro light left" or "kuro left"
      if not light then sim.LL = (sim.LL or 0) + ld.kuro end
      return s
    elseif not gm.rlKUR then
      local light = shouldLight("RL", ld.kuro, sim.RL)
      local s = light and "kuro light right" or "kuro right"
      if not light then sim.RL = (sim.RL or 0) + ld.kuro end
      return s
    end
    return "kuro light left"
  end

  local function pickRuku()
    if gm.LA <= gm.RA then
      local light = shouldLight("LA", ld.ruku, sim.LA)
      local s = light and "ruku light left" or "ruku left"
      if not light then sim.LA = (sim.LA or 0) + ld.ruku end
      return s
    else
      local light = shouldLight("RA", ld.ruku, sim.RA)
      local s = light and "ruku light right" or "ruku right"
      if not light then sim.RA = (sim.RA or 0) + ld.ruku end
      return s
    end
  end

  local slot1, slot2 = nil, nil

  if k >= 12 and not has("lethargy") then
    slot1 = pickKuro()
  end
  if k >= 10 and not has("healthleech") then
    if not slot1 then slot1 = pickRuku()
    elseif not slot2 then slot2 = pickRuku() end
  end
  if not has("clumsiness") then
    if not slot1 then slot1 = pickRuku()
    elseif not slot2 then slot2 = pickRuku() end
  end
  if not has("lethargy") then
    if not slot1 then
      slot1 = pickKuro()
    elseif not slot2 and (not slot1 or not slot1:find("kuro")) then
      slot2 = pickKuro()
    end
  end
  if not slot1 then slot1 = pickKuro() end
  if not slot1 then slot1 = pickRuku() end
  if not slot2 then
    if slot1 and slot1:find("kuro") then
      slot2 = pickRuku()
    elseif slot1 and slot1:find("ruku") then
      slot2 = pickKuro()
    else
      slot2 = pickRuku()
    end
  end
  if not slot1 then slot1 = "ruku torso" end
  if not slot2 then slot2 = gm.hHIRU and "hiru light" or "hiru" end

  table.insert(gm.staff, slot1)
  if slot2 then table.insert(gm.staff, slot2) end
end

local function oakPrios()
  gm.staff = {}
  gm.kick = "none"
  local ld = mod.limbDamage
  local allPrepped = gm.llFLASH and gm.rlFLASH and gm.laPREP and gm.raPREP and gm.hPREP

  if allPrepped then
    gm.kick = "risingkick torso"
    if not has("paralysis") then
      table.insert(gm.staff, "nervestrike light")
    else
      table.insert(gm.staff, "livestrike light")
    end
    if not has("asthma") then
      table.insert(gm.staff, "livestrike light")
    elseif not has("slickness") then
      table.insert(gm.staff, "ruku torso")
    else
      table.insert(gm.staff, "nervestrike light")
    end
    return
  end

  if not gm.hPREP then
    gm.kick = gm.hNERVRIS and "risingkick torso" or "risingkick head"
  else
    gm.kick = "risingkick torso"
  end

  if not gm.hPREP then
    table.insert(gm.staff, gm.hNERV and "nervestrike light" or "nervestrike")
  elseif not has("paralysis") then
    local light = shouldLight("H", ld.nervestrike, 0)
    table.insert(gm.staff, light and "nervestrike light" or "nervestrike")
  else
    if not has("asthma") then
      table.insert(gm.staff, "livestrike")
    elseif not has("slickness") then
      table.insert(gm.staff, "ruku torso")
    end
  end

  if not gm.llKUR and (gm.rlKUR or gm.LL <= gm.RL) then
    local light = shouldLight("LL", ld.kuro, 0)
    table.insert(gm.staff, light and "kuro light left" or "kuro left")
  elseif not gm.rlKUR then
    local light = shouldLight("RL", ld.kuro, 0)
    table.insert(gm.staff, light and "kuro light right" or "kuro right")
  elseif not gm.laPREP then
    local light = shouldLight("LA", ld.ruku, 0)
    table.insert(gm.staff, light and "ruku light left" or "ruku left")
  elseif not gm.raPREP then
    local light = shouldLight("RA", ld.ruku, 0)
    table.insert(gm.staff, light and "ruku light right" or "ruku right")
  elseif not has("asthma") then
    table.insert(gm.staff, "livestrike")
  elseif not has("slickness") then
    table.insert(gm.staff, "ruku torso")
  end
end

local function gaitalPrios()
  gm.staff = {}
  gm.kick = "none"
  local k = currentKata()
  local ld = mod.limbDamage

  if gm.lowHp and k >= 5 then
    gm.staff[1] = "maelstrom_override"
    return
  end

  if has("prone") and has("damagedhead") and has("crushedthroat") then
    gm.staff[1] = "dispatch"
    return
  end

  if gm.lockForkReady then
    gm.staff[1] = "lock_fork"
    return
  end

  local rightLegBroken = has("damagedrightleg") or has("brokenrightleg")
  if has("prone") and gm.bothArmsBroken and rightLegBroken then
    table.insert(gm.staff, "needle")
    if not has("clumsiness") then
      table.insert(gm.staff, gm.LA <= gm.RA and "ruku left" or "ruku right")
    elseif not has("lethargy") then
      table.insert(gm.staff, "kuro right")
    elseif not has("slickness") then
      table.insert(gm.staff, "ruku torso")
    elseif not has("addiction") then
      table.insert(gm.staff, "jinzuku")
    else
      table.insert(gm.staff, gm.LA <= gm.RA and "ruku left" or "ruku right")
    end
    gm.kick = "flashheel left"
    return
  end

  if has("prone") and has("damagedhead") and not has("crushedthroat") then
    table.insert(gm.staff, "needle")
    if not has("clumsiness") then
      table.insert(gm.staff, gm.LA <= gm.RA and "ruku left" or "ruku right")
    elseif not has("lethargy") then
      table.insert(gm.staff, "kuro right")
    elseif not has("slickness") then
      table.insert(gm.staff, "ruku torso")
    else
      table.insert(gm.staff, "jinzuku")
    end
    if not has("damagedleftleg") and not has("brokenleftleg") then
      gm.kick = "flashheel left"
    elseif not has("damagedrightleg") and not has("brokenrightleg") then
      gm.kick = "flashheel right"
    else
      gm.kick = "none"
    end
    return
  end

  local leftLegBroken = has("damagedleftleg") or has("brokenleftleg")
  if has("prone") and leftLegBroken and not gm.bothArmsBroken then
    table.insert(gm.staff, "ruku left")
    table.insert(gm.staff, "ruku right")
    gm.kick = "flashheel right"
    return
  end

  if gm.executeReady and not has("prone") then
    table.insert(gm.staff, "sweep")
    gm.kick = "flashheel left"
    return
  end

  if k >= 10 and not gm.executeReady then
    gm.kick = "none"
    table.insert(gm.staff, not has("slickness") and "ruku torso" or "jinzuku")
    table.insert(gm.staff, not has("addiction") and "jinzuku" or "ruku torso")
    return
  end

  local simLL, simRL = 0, 0
  if not gm.llFLASH
     and not has("damagedleftleg")
     and (gm.rlFLASH or gm.LL <= gm.RL)
     and parriedLimb() ~= "left leg" then
    gm.kick = "flashheel left"
    simLL = simLL + ld.flashheel
  elseif not gm.rlFLASH and not has("damagedrightleg") then
    gm.kick = "flashheel right"
    simRL = simRL + ld.flashheel
  else
    gm.kick = "none"
  end

  local function pickKuro()
    if not gm.llKUR and (gm.rlKUR or gm.LL <= gm.RL) then
      local light = shouldLight("LL", ld.kuro, simLL)
      local s = light and "kuro light left" or "kuro left"
      if not light then simLL = simLL + ld.kuro end
      return s
    elseif not gm.rlKUR then
      local light = shouldLight("RL", ld.kuro, simRL)
      local s = light and "kuro light right" or "kuro right"
      if not light then simRL = simRL + ld.kuro end
      return s
    end
    return nil
  end

  local simLA, simRA = 0, 0
  local function pickRuku()
    if not gm.laPREP then
      local light = shouldLight("LA", ld.ruku, simLA)
      local s = light and "ruku light left" or "ruku left"
      if not light then simLA = simLA + ld.ruku end
      return s
    elseif not gm.raPREP then
      local light = shouldLight("RA", ld.ruku, simRA)
      local s = light and "ruku light right" or "ruku right"
      if not light then simRA = simRA + ld.ruku end
      return s
    end
    return gm.LA <= gm.RA and "ruku light left" or "ruku light right"
  end

  local j1, j2 = nil, nil
  if not has("clumsiness") then j1 = pickRuku()
  elseif not has("lethargy") then j1 = pickKuro() end
  if not j1 then j1 = pickKuro() end
  if not j1 then j1 = pickRuku() end
  if not j1 then j1 = not has("addiction") and "jinzuku" or "ruku torso" end

  if j1 and j1:find("kuro left") then
    j2 = not gm.rlKUR and pickKuro() or pickRuku()
  elseif j1 and j1:find("kuro right") then
    j2 = not gm.llKUR and pickKuro() or pickRuku()
  elseif j1 and j1:find("ruku") then
    j2 = pickKuro()
  end
  if not j2 then j2 = not has("addiction") and "jinzuku" or "ruku torso" end

  table.insert(gm.staff, j1)
  if j2 then table.insert(gm.staff, j2) end
end

local function maelstromPrios()
  gm.staff = {}
  gm.kick = "none"
  local killReady = has("damagedhead") and has("crushedthroat")

  if gm.lowHp and has("prone") and killReady then
    gm.kick = "crescent"
  elseif has("prone") and killReady then
    gm.kick = "risingkick torso"
    table.insert(gm.staff, "livestrike")
  elseif not has("prone") then
    table.insert(gm.staff, "sweep")
    gm.kick = "risingkick torso"
  else
    gm.kick = "risingkick torso"
    table.insert(gm.staff, "livestrike")
  end
end

function gmapi.formswap()
  local f = currentForm()
  local k = currentKata()
  local targetForm = nil

  if f == "Gaital" and gm.lowHp and k >= 5 then
    return "Maelstrom"
  end

  if f == "Gaital" and gm.lockForkReady then
    if k >= 5 then return "Rain" end
    return f
  end

  if f == "Tykonos" then
    targetForm = k >= 5 and "Willow" or "Tykonos"
  elseif f == "Willow" then
    local legsWorked = gm.llFLASH or gm.rlFLASH or gm.llKUR or gm.rlKUR
    if (k >= 5 and legsWorked) or k >= 8 then
      targetForm = "Rain"
    else
      targetForm = "Willow"
    end
  elseif f == "Rain" then
    if gm.lockForkReady then return "Rain" end
    local legsPrepped = gm.llKUR and gm.rlKUR
    local armsAndLegs = legsPrepped and gm.laPREP and gm.raPREP
    if k >= 5 and armsAndLegs and gm.hPREP then
      targetForm = "Oak"
    elseif k >= 5 and legsPrepped and (has("weariness") or has("lethargy")) then
      targetForm = "Oak"
    elseif k >= 22 then
      targetForm = "Oak"
    else
      targetForm = "Rain"
    end
  elseif f == "Oak" then
    local allPrepped = gm.llFLASH and gm.rlFLASH and gm.laPREP and gm.raPREP and gm.hPREP
    local partialDone = (gm.llFLASH or gm.rlFLASH) and gm.hPREP
    local affsCooking = has("paralysis") or has("asthma")
    if k >= 5 and allPrepped then
      targetForm = "Gaital"
    elseif k >= 5 and partialDone and affsCooking then
      targetForm = "Gaital"
    elseif k >= 10 then
      targetForm = "Gaital"
    else
      targetForm = "Oak"
    end
  elseif f == "Gaital" then
    local killReady = has("damagedhead") and has("crushedthroat")
    local midExecute = has("prone") and (has("damagedhead") or gm.bothLegsBroken or gm.bothArmsBroken)
    if k >= 10
       and not gm.executeReady
       and not killReady
       and not gm.lockForkReady
       and not midExecute then
      targetForm = "Rain"
    else
      targetForm = "Gaital"
    end
  elseif f == "Maelstrom" then
    local killReady = has("damagedhead") and has("crushedthroat")
    if (k >= 5 and not gm.lowHp and not killReady) or k >= 8 then
      targetForm = "Oak"
    else
      targetForm = "Maelstrom"
    end
  end

  return targetForm or f
end

local function dispatchReady()
  return has("prone") and has("damagedhead") and has("crushedthroat")
end

local COMBO_LIMBS = {
  ["left leg"] = {
    "flashheel left", "kuro left", "kuro light left",
    "thrust left leg", "dart left leg"
  },
  ["right leg"] = {
    "flashheel right", "kuro right", "kuro light right",
    "thrust right leg", "dart right leg"
  },
  ["left arm"] = {
    "frontkick left", "ruku left", "ruku light left",
    "thrust left arm", "dart left arm"
  },
  ["right arm"] = {
    "frontkick right", "ruku right", "ruku light right",
    "thrust right arm", "dart right arm"
  },
  head = {
    "risingkick head", "needle", "nervestrike", "hiru", "hiraku",
    "thrust head", "dart head"
  },
  torso = {
    "risingkick torso", "ruku torso", "livestrike", "jinzuku",
    "spinkick", "crescent", "thrust torso", "dart torso"
  }
}

local function comboTouchesLimb(combo, limb)
  combo = tostring(combo or ""):lower()
  limb = normalizeLimb(limb)
  local needles = limb and COMBO_LIMBS[limb]
  if not needles then return false end

  for _, needle in ipairs(needles) do
    if combo:find(needle, 1, true) then
      return true
    end
  end
  return false
end

local function neededHyperfocus(combo)
  local parry = normalizeLimb(parriedLimb())
  if parry and comboTouchesLimb(combo, parry) then
    return parry
  end
  return nil
end

local function applyHyperfocusForCombo(cmds, combo)
  local want = neededHyperfocus(combo)
  local have = currentHyperfocus()

  if want then
    if have ~= want then
      add(cmds, "hyperfocus " .. want)
    end
  elseif have then
    add(cmds, "hyperfocus none")
  end
end

local function runPriosForForm(form)
  if form == "Tykonos" then
    tykonosPrios()
  elseif form == "Willow" then
    willowPrios()
  elseif form == "Rain" then
    rainPrios()
  elseif form == "Oak" then
    oakPrios()
  elseif form == "Gaital" then
    gaitalPrios()
  elseif form == "Maelstrom" then
    maelstromPrios()
  else
    return false
  end
  return true
end

local function appendCombo(cmds, combo)
  local out = copyCommands(cmds)
  applyHyperfocusForCombo(out, combo)
  add(out, "combo " .. target .. " " .. combo)
  return out
end

local function sendTransition(targetForm, prefix)
  local cmds = {}
  add(cmds, "transition to the " .. targetForm .. " form")
  for i = 1, #prefix do add(cmds, prefix[i]) end
  sendCommands(cmds, "FREE")
end

local function standardCombo(form)
  local s1 = gm.staff[1] or ""
  local s2 = gm.staff[2] or ""
  local kick = gm.kick or "none"
  local combo = ""
  local kickFirst = (form == "Rain") or (form == "Oak" and has("clumsiness"))

  if kickFirst then
    if kick ~= "none" and s1 ~= "" and s2 ~= "" then
      combo = kick .. " " .. s1 .. " " .. s2
    elseif kick ~= "none" and s1 ~= "" then
      combo = kick .. " " .. s1
    elseif s1 ~= "" and s2 ~= "" then
      combo = s1 .. " " .. s2
    elseif s1 ~= "" then
      combo = s1
    end
  else
    if s1 ~= "" and s2 ~= "" and kick ~= "none" then
      combo = s1 .. " " .. s2 .. " " .. kick
    elseif s1 ~= "" and kick ~= "none" then
      combo = s1 .. " " .. kick
    elseif s1 ~= "" and s2 ~= "" then
      combo = s1 .. " " .. s2
    elseif kick ~= "none" then
      combo = kick
    elseif s1 ~= "" then
      combo = s1
    end
  end

  return combo
end

local function appendSelectedOffense(form, cmds)
  if gm.staff[1] == "dispatch" then
    add(cmds, "dispatch " .. target)
    return "\n<red>*** DISPATCH ***", true
  end

  if gm.staff[1] == "sweep" then
    local combo = gm.kick ~= "none" and "sweep " .. gm.kick or "sweep"
    applyHyperfocusForCombo(cmds, combo)
    add(cmds, "combo " .. target .. " " .. combo)
    return " <red>| EXECUTE C1: sweep", true
  end

  if gm.staff[1] == "maelstrom_override" or gm.staff[1] == "lock_fork" then
    return nil, false
  end

  local combo = standardCombo(form)
  if combo ~= "" then
    applyHyperfocusForCombo(cmds, combo)
    add(cmds, "combo " .. target .. " " .. combo)
    return nil, true
  end

  return nil, false
end

function gmapi.run()
  gm = {}

  if not target or target == "" then
    notify("\n<red>[Shikudo GM] No target set. Use: tar <name>")
    return
  end

  if isPaused() or selfAff("stupidity") then return end
  if selfNeedLockBreak() then
    selfLockBreak()
    return
  end

  local f = currentForm()
  local k = currentKata()

  if not f or f == "" or f:lower() == "none" then
    send("adopt rain form")
    return
  end

  gmapi.calcLimbs()

  local prefix = buildPrefixCommands()

  if mod.CONFIG.debug and not isBashing() then
    notify("\n<cyan>[Shikudo:<yellow>GODMODE<cyan>] <yellow>" .. tostring(target))
    notify(" <cyan>| <green>" .. tostring(f))
    notify(" <cyan>| k:<yellow>" .. tostring(k))
  end

  if dispatchReady() then
    local cmds = copyCommands(prefix)
    add(cmds, "dispatch " .. target)
    notify("\n<red>*** DISPATCH KILL ***")
    sendCommands(cmds, "FREE")
    return
  end

  if has("shield") then
    sendCommands(appendCombo(prefix, "shatter"), "FREE")
    return
  end

  if not runPriosForForm(f) then
    send("adopt rain form")
    return
  end

  local targetForm = gmapi.formswap()
  if f ~= targetForm then
    if k >= 5 then
      local cmds = {}
      add(cmds, "transition to the " .. targetForm .. " form")
      for i = 1, #prefix do add(cmds, prefix[i]) end

      kataOverride = 0
      gm = {}
      gmapi.calcLimbs()
      if runPriosForForm(targetForm) then
        local offenseEcho = appendSelectedOffense(targetForm, cmds)
        if offenseEcho then notify(offenseEcho) end
      end
      kataOverride = nil

      sendCommands(cmds, "FREE")
      notify(" <yellow>-> " .. targetForm)
    else
      send("adopt " .. targetForm .. " form")
      notify(" <yellow>-> adopt " .. targetForm)
    end
    return
  end

  if gm.staff[1] == "maelstrom_override" then
    sendTransition("Maelstrom", prefix)
    notify(" <red>-> MAELSTROM (low HP)")
    return
  end

  if gm.staff[1] == "lock_fork" then
    if k >= 5 then
      sendTransition("Rain", prefix)
      notify(" <magenta>-> RAIN (lock fork)")
    else
      send("adopt Rain form")
      notify(" <magenta>-> adopt Rain (lock fork)")
    end
    return
  end

  if gm.staff[1] == "dispatch" then
    local cmds = copyCommands(prefix)
    add(cmds, "dispatch " .. target)
    notify("\n<red>*** DISPATCH ***")
    sendCommands(cmds, "FREE")
    return
  end

  if gm.staff[1] == "sweep" then
    local cmds = copyCommands(prefix)
    local combo = gm.kick ~= "none" and "sweep " .. gm.kick or "sweep"
    applyHyperfocusForCombo(cmds, combo)
    add(cmds, "combo " .. target .. " " .. combo)
    notify(" <red>| EXECUTE C1: sweep")
    sendCommands(cmds, "FREE")
    return
  end

  local combo = standardCombo(f)
  if combo ~= "" then
    sendCommands(appendCombo(prefix, combo), "FREE")
  elseif #prefix > 0 then
    sendCommands(prefix, "FREE")
  end
end

function gmapi.status()
  gm = {}
  gmapi.calcLimbs()

  local f = currentForm() or "Unknown"
  local k = currentKata()
  local limbThresh = mod.CONFIG.godmodePrepThreshold
  local headThresh = mod.CONFIG.godmodeHeadPrepThreshold

  local function limbColor(val, thresh)
    if val >= 100 then return "<red>" end
    if val >= thresh then return "<green>" end
    if val >= 70 then return "<yellow>" end
    return "<grey>"
  end

  local function mark(val, thresh)
    return val >= thresh and "<green>[X]" or "<red>[ ]"
  end

  local phase = "BUILD"
  if gm.executeReady then phase = "EXECUTE" end
  if gm.lockForkReady then phase = "LOCK FORK" end

  notify("\n<cyan>--- SHIKUDO GOD MODE ---")
  notify("\n<cyan>Target: <yellow>" .. tostring(target or "None"))
  notify("\n<cyan>Form: <green>" .. tostring(f) .. " <grey>(k:" .. tostring(k) .. ")")
  notify("\n<cyan>Hyper: <white>" .. tostring(currentHyperfocus() or "none"))
  notify("\n<cyan>Armed: " .. (mod.state.next_bal_armed and "<green>YES" or "<grey>no"))
  notify("\n<cyan>Phase: <yellow>" .. phase)
  notify("\n<cyan>5-limb prep:")
  notify("\n  " .. mark(gm.LL, limbThresh) .. " <white>L Leg: " .. limbColor(gm.LL, limbThresh) .. string.format("%.1f%%", gm.LL))
  notify("\n  " .. mark(gm.RL, limbThresh) .. " <white>R Leg: " .. limbColor(gm.RL, limbThresh) .. string.format("%.1f%%", gm.RL))
  notify("\n  " .. mark(gm.LA, limbThresh) .. " <white>L Arm: " .. limbColor(gm.LA, limbThresh) .. string.format("%.1f%%", gm.LA))
  notify("\n  " .. mark(gm.RA, limbThresh) .. " <white>R Arm: " .. limbColor(gm.RA, limbThresh) .. string.format("%.1f%%", gm.RA))
  notify("\n  " .. mark(gm.H, headThresh) .. " <white>Head:  " .. limbColor(gm.H, headThresh) .. string.format("%.1f%%", gm.H))
  notify("\n<cyan>Kill checks:")
  notify("\n  <white>Prone: " .. (has("prone") and "<green>YES" or "<red>NO"))
  notify("\n  <white>Head broken: " .. (has("damagedhead") and "<green>YES" or "<red>NO"))
  notify("\n  <white>Windpipe: " .. ((has("damagedwindpipe") or has("crushedthroat")) and "<green>YES" or "<red>NO"))
  notify("\n  <white>Lock affs: <yellow>" .. tostring(gm.lockCount or 0) .. "/" .. tostring(mod.CONFIG.godmodeLockForkMinAffs))
end

function mod.dispatch()
  return gmapi.run()
end

function mod.arm()
  mod.setMode("godmode")
  if haveEqBal() then
    mod.state.next_bal_armed = false
    if mod.state.next_bal_timer and killTimer then
      killTimer(mod.state.next_bal_timer)
    end
    mod.state.next_bal_timer = nil
    mod.state.next_bal_deadline = nil
    return mod.dispatch()
  end

  mod.state.next_bal_armed = true
  notify("\n<green>[Shikudo GM] armed")
end

function mod.on_balance(interval)
  interval = tonumber(interval)
  if not interval then return end

  local lead = mod.CONFIG.prearmInterval
    or (getNetworkLatency and getNetworkLatency()) or 0.1
  local wait = math.max(0, interval - lead)
  local deadline = ((getEpoch and getEpoch()) or 0) + wait

  if mod.state.next_bal_timer
     and deadline <= (mod.state.next_bal_deadline or 0) then
    return
  end

  if mod.state.next_bal_timer and killTimer then
    killTimer(mod.state.next_bal_timer)
  end

  mod.state.next_bal_deadline = deadline
  if tempTimer then
    mod.state.next_bal_timer = tempTimer(wait, function()
      mod.state.next_bal_timer = nil
      mod.state.next_bal_deadline = nil
      if mod.state.next_bal_armed then
        mod.state.next_bal_armed = false
        mod.dispatch()
      end
    end)
  elseif mod.state.next_bal_armed then
    mod.state.next_bal_armed = false
    mod.dispatch()
  end
end

function mod.status()
  return gmapi.status()
end

function mod.reset()
  gm = {}
  if mod.state.next_bal_timer and killTimer then
    killTimer(mod.state.next_bal_timer)
  end
  mod.state.next_bal_armed = false
  mod.state.next_bal_timer = nil
  mod.state.next_bal_deadline = nil
  mod.mode = "godmode"
  notify("\n<cyan>[Shikudo GM] State reset")
end

function skgodmode()
  mod.setMode("godmode")
  return mod.arm()
end

function skgmstatus()
  mod.setMode("godmode")
  return gmapi.status()
end

function skstatus()
  return mod.status()
end

function skreset()
  return mod.reset()
end

function skdispatch()
  notify("\n<yellow>[Shikudo] skdispatch now runs GodMode in this fresh port.")
  return skgodmode()
end

function sklock()
  notify("\n<yellow>[Shikudo] sklock was removed; running GodMode instead.")
  return skgodmode()
end

function skriftlock()
  notify("\n<yellow>[Shikudo] skriftlock was removed; running GodMode instead.")
  return skgodmode()
end
