--- Blademaster Combat Module — Legacy/AK port
---
--- Four strategies (set by the arming alias, see bottom):
---   double      — bmd      — prep both legs, double-break + KNEES (prone), ice mangle
---   quad        — bmdq     — prep arms+legs, flamefist, break arms, break legs, mangle
---   brokenstar  — bmbs     — prep+break upper & legs, impale → impaleslash → bladetwist → brokenstar
---   group       — bmgroup  — ice pommelstrike affliction-lock ladder
---
--- Less-fragile design (vs. the prior port):
---   * JIT dispatch — the alias ARMS (blademaster.arm); a balance/eq-USED trigger calls
---     blademaster.on_recover(interval), which schedules the attack for the instant balance
---     returns, built from CURRENT state. Replaces the old attackInFlight + GMCP handler.
---   * Brokenstar reads framework state — affstrack.impale=="Me" (impaled),
---     affstrack.score.impaleslash (slashed), and ak.bleeding — instead of a trigger-driven
---     isImpaled/impaleslashDone/withdraw/twist-count machine, so it needs NO custom triggers.
---     Target writhe needs no handling: AK flips impale off, the cascade re-impales.
---   * Self-registers NOTHING — no tempAlias / tempRegexTrigger / event handler. Wire the
---     aliases/triggers by hand to the exposed functions per MUDLET_SETUP.md.
---
--- Global environment (provided by Mudlet + AK + Legacy, NOT in repo):
---   target, ak.* (bleeding, defs.shield/rebounding, mounted, engaged, currenthealth/maxhealth),
---   affstrack.score[aff] / affstrack.impale, lb[target].hits[limb] (spaced limb names),
---   targetparry, Legacy.Curing.*, gmcp.Char.{Vitals,Status}, send/tempTimer/killTimer/etc.

blademaster = blademaster or {}

blademaster.CONFIG = blademaster.CONFIG or {
  AFF_THRESHOLD      = 33,          -- affstrack.score gate (0-100 confidence)
  PREP               = 90,          -- limb % considered "prepped"
  BREAK              = 100,         -- limb % considered "broken"
  BLEED_KILL         = 700,         -- ak.bleeding required for brokenstar
  AIRFIST_SHIN       = 25,          -- 20 shin + 5 infuse
  LOCKBREAK_COOLDOWN = 1.5,         -- seconds between self-lockbreak attempts
  PREARM_LEAD        = nil,         -- on_recover lead; nil = getNetworkLatency()
  DEFAULT_STANCE     = "thyr",      -- fallback when Legacy.Tannivh.stance is unknown/nil
  QUEUE              = "FREESTAND",
  ATK_ALIAS          = "ATK",
  ENGAGE_ON_FIRST    = true,
  PRECOMMANDS        = { "stand" }, -- ride along each attack
}

-- Self lock-break tables (shared cross-module pattern; the row for YOUR class is the one
-- that fires, since gmcp.Char.Status.class is the player). BLOCKER = aff that stops the
-- class's lock-break cure; BREAKER = the command that breaks the lock.
blademaster.CONFIG.LOCK = blademaster.CONFIG.LOCK or {
  BLOCKER = {
    Alchemist = "stupidity",  Blademaster = "weariness", Depthswalker = "recklessness",
    Druid     = "weariness",  Infernal    = "weariness", Jester       = "paralysis",
    Magi      = "haemophilia", Monk       = "weariness", Occultist    = "paralysis",
    Paladin   = "weariness",  Runewarden  = "weariness", Sentinel     = "weariness",
    Serpent   = "weariness",  Shaman      = "selarnia",
  },
  BREAKER = {
    Alchemist = "educe salt", Blademaster = "fitness", Depthswalker = "chrono accelerate boost",
    Druid     = "fitness",    Infernal    = "fitness", Jester       = "fling fool at me",
    Magi      = "cast bloodboil", Monk     = "fitness", Occultist   = "fling fool at me",
    Paladin   = "fitness",    Psion       = "psi expunge", Runewarden = "fitness",
    Sentinel  = "fitness",    Serpent     = "shrugging", Shaman      = "invoke purification",
    Unnamable = "fitness",
  },
}

-- getLockingAffliction() name -> pommelstrike location / real aff name (group mode)
blademaster.CONFIG.LOCK_STRIKE  = { paralyse="neck", weariness="shoulder", plague="eyes", stupid="temple", reckless="groin" }
blademaster.CONFIG.LOCK_AFFNAME = { paralyse="paralysis", weariness="weariness", plague="plague", stupid="stupidity", reckless="recklessness" }

-- Per-stance (TwoArts) slash damage — primary/secondary per hit. STATIC, selected by
-- Legacy.Tannivh.stance. Seeds are the Levi baseline (guesses); set real numbers per stance
-- by hand or via calibrate.lua. Unknown/nil stance falls back to CONFIG.DEFAULT_STANCE.
blademaster.CONFIG.DMG = blademaster.CONFIG.DMG or {
  doya  = { legP = 17.3, legS = 11.5, armP = 17.3, armS = 11.5, torso = 18.1, head = 12.1, compass = 14.9 },
  thyr  = { legP = 17.3, legS = 11.5, armP = 17.3, armS = 11.5, torso = 18.1, head = 12.1, compass = 14.9 },
  mir   = { legP = 17.3, legS = 11.5, armP = 17.3, armS = 11.5, torso = 18.1, head = 12.1, compass = 14.9 },
  arash = { legP = 17.3, legS = 11.5, armP = 17.3, armS = 11.5, torso = 18.1, head = 12.1, compass = 14.9 },
  sanya = { legP = 17.3, legS = 11.5, armP = 17.3, armS = 11.5, torso = 18.1, head = 12.1, compass = 14.9 },
}

blademaster.state = blademaster.state or { mode = "double" }

local C = blademaster.CONFIG

--------------------------------------------------------------------------------
-- STATE READERS (target affs/limbs, self affs, resources)
--------------------------------------------------------------------------------

local function aff_score(aff)
  return (affstrack and affstrack.score and affstrack.score[aff]) or 0
end

local function has(aff)
  return aff_score(aff) >= C.AFF_THRESHOLD
end

local function self_aff(name)
  return Legacy and Legacy.Curing and Legacy.Curing.Affs and Legacy.Curing.Affs[name]
end

local function my_class()
  return (gmcp and gmcp.Char and gmcp.Char.Status and gmcp.Char.Status.class) or ""
end

-- lb keys use spaced limb names ("left leg"); raw target key per AK convention.
local function limb_dmg(limb)
  return (lb and lb[target] and lb[target].hits and lb[target].hits[limb]) or 0
end

local function is_broken(limb)  return limb_dmg(limb) >= C.BREAK end
local function is_prepped(limb) return limb_dmg(limb) >= C.PREP end

-- AK reports parried limbs without spaces (leftleg); normalise to the spaced form.
local PARRY_SPACED = { leftarm = "left arm", rightarm = "right arm", leftleg = "left leg", rightleg = "right leg" }
local function parried()
  local p = targetparry
  if type(p) ~= "string" or p == "" then return "none" end
  return PARRY_SPACED[p] or p
end

local function charstat(name)
  local cs = gmcp and gmcp.Char and gmcp.Char.Vitals and gmcp.Char.Vitals.charstats
  if type(cs) == "table" then
    for _, entry in ipairs(cs) do
      local v = entry:match("^" .. name .. ":%s*(.+)$")
      if v then return v end
    end
  end
  return nil
end

local function shin()  return tonumber(charstat("Shin")) or 0 end
local function bleed() return tonumber(ak and ak.bleeding) or 0 end

-- affstrack.impale holds who is impaling; "Me" means the target is impaled by us.
local function impaled() return affstrack and affstrack.impale == "Me" or false end

-- AK tracks impaleslash as a condition: score hits 100 once it lands (drops when cured).
local function impaleslashed() return aff_score("impaleslash") >= 100 end
local function hamstrung()     return aff_score("hamstring") >= 100 end

local function has_shield()     return ak and ak.defs and ak.defs.shield and true or false end
local function has_rebounding() return ak and ak.defs and ak.defs.rebounding and true or false end
local function mounted()        return ak and ak.mounted and true or false end

local function target_hp()
  if not (ak and ak.currenthealth and ak.maxhealth) or ak.maxhealth == 0 then return 100 end
  return math.floor((ak.currenthealth / ak.maxhealth) * 100)
end

--------------------------------------------------------------------------------
-- FOCUS / DIRECTION
--------------------------------------------------------------------------------

-- Lower limb is the focus (gets primary damage); skip a parried focus when possible.
local function focus_of(left_limb, right_limb)
  local L, R = limb_dmg(left_limb), limb_dmg(right_limb)
  local pr = parried()
  if L >= C.PREP and R >= C.PREP then
    return pr == left_limb and "right" or "left"
  end
  local f = (L <= R) and "left" or "right"
  if pr == (f == "left" and left_limb or right_limb) then
    f = (f == "left") and "right" or "left"
  end
  return f
end

local function focus_leg() return focus_of("left leg", "right leg") end
local function focus_arm() return focus_of("left arm", "right arm") end

-- Centreslash hits the lower of torso/head as primary, balancing the two.
local function centreslash_dir()
  return (limb_dmg("head") <= limb_dmg("torso")) and "down" or "up"
end

--------------------------------------------------------------------------------
-- PREP / BREAK PREDICTION (wouldBreak guards; per-stance slash damage)
--------------------------------------------------------------------------------

-- Static per-stance slash damage, selected by Legacy.Tannivh.stance.
local function stance_dmg()
  local s = Legacy and Legacy.Tannivh and Legacy.Tannivh.stance
  s = type(s) == "string" and s:lower() or nil
  return C.DMG[s] or C.DMG[C.DEFAULT_STANCE]
end

-- Effectively prepped: at PREP, or a single primary hit would break it.
local function pair_prepped(left_limb, right_limb, prim)
  local function eff(limb)
    local d = limb_dmg(limb)
    return d >= C.PREP or (d + prim >= C.BREAK)
  end
  return eff(left_limb) and eff(right_limb)
end

-- Next focus-hit brings BOTH to `thresh` (focus gets primary, off-limb secondary).
local function pair_will_reach(left_limb, right_limb, prim, sec, thresh, focus)
  local L, R = limb_dmg(left_limb), limb_dmg(right_limb)
  if L >= thresh and R >= thresh then return false end
  if focus == "left" then return (L + prim >= thresh) and (R + sec >= thresh) end
  return (R + prim >= thresh) and (L + sec >= thresh)
end

local function legs_prepped()         return pair_prepped("left leg", "right leg", stance_dmg().legP) end
local function arms_prepped()         return pair_prepped("left arm", "right arm", stance_dmg().armP) end
local function will_prep_both_legs()  return pair_will_reach("left leg", "right leg", stance_dmg().legP, stance_dmg().legS, C.PREP,  focus_leg()) end
local function will_break_both_legs() return pair_will_reach("left leg", "right leg", stance_dmg().legP, stance_dmg().legS, C.BREAK, focus_leg()) end
local function will_prep_both_arms()  return pair_will_reach("left arm", "right arm", stance_dmg().armP, stance_dmg().armS, C.PREP,  focus_arm()) end

-- Upper uses torso=primary, head=secondary, with the lower limb taking primary.
local function will_prep_upper()
  local t, h = limb_dmg("torso"), limb_dmg("head")
  local p, s = stance_dmg().torso, stance_dmg().head
  if t >= C.PREP and h >= C.PREP then return false end
  if h <= t then return (h + p >= C.PREP) and (t + s >= C.PREP) end
  return (t + p >= C.PREP) and (h + s >= C.PREP)
end

local function will_break_upper()
  local t, h = limb_dmg("torso"), limb_dmg("head")
  local p, s = stance_dmg().torso, stance_dmg().head
  if h <= t then return (h + p >= C.BREAK) and (t + s >= C.BREAK) end
  return (t + p >= C.BREAK) and (h + s >= C.BREAK)
end

--------------------------------------------------------------------------------
-- STRIKE LADDERS + PARRY DECISION
--------------------------------------------------------------------------------

-- Lightning prep: lightning already gives clumsiness, so layer the rest.
local function prep_strike()
  if not hamstrung() then return "hamstring" end
  if not has("paralysis")    then return "neck" end
  if not has("hypochondria") then return "chest" end
  if not has("weariness")    then return "shoulder" end
  if not has("clumsiness")   then return "ears" end
  return "neck"
end

-- Ice phase: ice does NOT give clumsiness, so lead with it.
local function ice_strike()
  if not has("clumsiness") then return "ears" end
  return "neck"
end

local function is_parried_type(t)
  local p = parried()
  if t == "arm" then return p == "left arm" or p == "right arm" end
  if t == "leg" then return p == "left leg" or p == "right leg" end
  return false
end

-- 005 needsAirfist: airfist when shin allows, we're not already airfisted, and the
-- target is parrying that limb type. 005 only checks this on PREP phases; on a low-shin
-- parry it just slashes (the focus logic already steers off the parried limb).
local function needs_airfist(t)
  return shin() >= C.AIRFIST_SHIN and not has("airfisted") and is_parried_type(t)
end

local function infuse(kind) return "infuse " .. kind .. "/" end

local function precommands()
  local cmds = C.PRECOMMANDS or {}
  return (#cmds > 0) and (table.concat(cmds, "/") .. "/") or ""
end

--------------------------------------------------------------------------------
-- SELF LOCK-BREAK
--------------------------------------------------------------------------------

local function need_lockbreak()
  local a = (Legacy and Legacy.Curing and Legacy.Curing.Affs) or {}
  local cls = my_class()
  if a.asthma and a.anorexia and (a.slickness or a.bloodfire) and cls ~= "Psion" then return true end
  if a.asthma and a.anorexia and (a.slickness or a.bloodfire) and a.impatience and cls == "Psion" then return true end
  if a.whisperingmadness then return true end
  if a.slime then return true end
  return false
end

-- Can the lock-break cure actually fire right now?
local function lockbreak_ready()
  if not (Legacy and Legacy.Curing and Legacy.Curing.bal and Legacy.Curing.bal.active) then return false end
  local a = Legacy.Curing.Affs or {}
  local limbs = (Legacy.SLC and Legacy.SLC.limbs) or {}
  local blk = C.LOCK.BLOCKER[my_class()]

  -- Both arms broken stops most cures (weariness-blocked classes fall through to the aff check).
  if (limbs["left arm"] or 0) >= 100 and (limbs["right arm"] or 0) >= 100 and blk and blk ~= "weariness" then
    return false
  end
  if not blk then
    local cls = my_class()
    if cls:find("Dragon")   then return not (a.weariness and a.recklessness) end
    if cls:find("Elemental") then return a.weariness and true or false end
    return false
  end
  if a[blk] then return false end
  return true
end

local function do_lockbreak()
  local a = Legacy.Curing.Affs or {}
  local cls = my_class()
  if a.prone and not a.paralysis then send("stand", false) end
  if cls:find("Dragon")    then send("dragonheal", false)
  elseif cls:find("Earth") then send("terran eruption", false)
  else send(C.LOCK.BREAKER[cls], false) end
end

-- Returns true while we're locked (caller should skip the attack). Fires the break
-- on a self-clearing cooldown latch so it can never get stuck attempting.
local function try_lockbreak()
  if not need_lockbreak() then return false end
  if lockbreak_ready() and not blademaster.state.lockbreak_latch then
    blademaster.state.lockbreak_latch = true
    if blademaster.state.lockbreak_timer then killTimer(blademaster.state.lockbreak_timer) end
    blademaster.state.lockbreak_timer = tempTimer(C.LOCKBREAK_COOLDOWN, function()
      blademaster.state.lockbreak_latch = false
      blademaster.state.lockbreak_timer = nil
    end)
    do_lockbreak()
  end
  return true
end

--------------------------------------------------------------------------------
-- SEND
--------------------------------------------------------------------------------

local function send_commands(combo)
  local s = (type(combo) == "table") and table.concat(combo, "/") or combo
  s = s:gsub("/+", "/"):gsub("^/", ""):gsub("/$", "")
  if C.ENGAGE_ON_FIRST and not (ak and ak.engaged) then
    s = s .. "/ENGAGE"
  end
  send("SETALIAS " .. C.ATK_ALIAS .. " " .. s)
  send("QUEUE ADDCLEARFULL " .. C.QUEUE .. " " .. C.ATK_ALIAS)
end

local function send_attack(combo)
  if not combo or combo == "" then return end
  if try_lockbreak() then return end             -- locked: break out, don't attack
  send_commands(precommands() .. combo)
end

--------------------------------------------------------------------------------
-- STRATEGY 1: DOUBLE-PREP (legs only)
--   leg_prep (lightning) -> leg_break + KNEES (ice) -> mangle: legslash RIGHT + STERNUM (ice)
--------------------------------------------------------------------------------

-- COMPASSSLASH single-limb prep correction (COMPASSSLASH <t> <direction>; one limb each):
--   N=head  S=torso  E=left arm  W=right arm  SE=left leg  SW=right leg
-- A normal slash hits the focus limb (primary) AND the off limb (secondary). When the off
-- limb is high enough that the secondary would break it before the focus limb is prepped,
-- compassslash the focus limb alone instead, so prep stays balanced for a clean double-break.
local COMPASS_DIR = {
  ["left leg"] = "southeast", ["right leg"] = "southwest",
  ["left arm"] = "east",      ["right arm"] = "west",
  head = "north",             torso = "south",
}

-- Paired-limb prep (legs/arms): compassslash the focus limb if the paired slash's secondary
-- would break the off limb; otherwise the normal paired slash on the focus side.
local function prep_slash(verb, left_limb, right_limb, side, secondary)
  local off = (side == "left") and right_limb or left_limb
  if limb_dmg(off) + secondary >= C.BREAK then
    return "compassslash " .. target .. " " .. COMPASS_DIR[(side == "left") and left_limb or right_limb]
  end
  return verb .. " " .. target .. " " .. side
end

-- Upper prep (torso/head via centreslash): compassslash the lower limb if centreslash's
-- secondary would break the higher one; otherwise the normal centreslash.
local function prep_upper()
  local lower  = (limb_dmg("head") <= limb_dmg("torso")) and "head" or "torso"
  local higher = (lower == "head") and "torso" or "head"
  if limb_dmg(higher) + stance_dmg().head >= C.BREAK then
    return "compassslash " .. target .. " " .. COMPASS_DIR[lower]
  end
  return "centreslash " .. target .. " " .. centreslash_dir()
end

local function build_double()
  local phase
  if has("prone") then phase = "mangle"
  elseif legs_prepped() or will_break_both_legs() then phase = "leg_break"
  else phase = "leg_prep" end

  local strike
  if phase == "mangle" then strike = "sternum"
  elseif phase == "leg_break" then strike = "knees"
  elseif mounted() and hamstrung() and will_prep_both_legs() then strike = "knees" -- dismount before break
  else strike = prep_strike() end

  -- Ice for break/mangle and the final prep hit (strips caloric); lightning otherwise.
  local kind = "lightning"
  if phase == "leg_break" or phase == "mangle" or (phase == "leg_prep" and will_prep_both_legs()) then
    kind = "ice"
  end

  if has_shield() or has_rebounding() then
    return infuse(kind) .. "raze " .. target .. " " .. strike .. "/assess " .. target
  end

  -- 005: airfist only during leg prep; otherwise just slash.
  if phase == "leg_prep" and needs_airfist("leg") then
    return "airfist " .. target .. "/assess " .. target
  end

  if phase == "leg_prep" then
    return infuse(kind) .. prep_slash("legslash", "left leg", "right leg", focus_leg(), stance_dmg().legS) .. " " .. strike .. "/assess " .. target
  end

  local dir = (phase == "mangle") and ((limb_dmg("right leg") < 200) and "right" or "left") or focus_leg()
  return infuse(kind) .. "legslash " .. target .. " " .. dir .. " " .. strike .. "/assess " .. target
end

--------------------------------------------------------------------------------
-- STRATEGY 2: QUAD-PREP (arms + legs)
--   arm_prep -> leg_prep -> flamefist -> arm_break -> leg_break (RIGHT) -> mangle (RIGHT)
--------------------------------------------------------------------------------

local function quad_strike(phase)
  if phase == "mangle" then return "sternum" end
  if phase == "leg_break" then return "knees" end
  if phase == "arm_break" then return ice_strike() end
  return prep_strike()
end

local function build_quad()
  local arms_brk = is_broken("left arm") and is_broken("right arm")
  local legs_prep = legs_prepped()

  local phase
  if has("prone") then phase = "mangle"
  elseif arms_brk and legs_prep then phase = "leg_break"
  elseif arms_prepped() and legs_prep and not arms_brk and blademaster.state.flamefist_done then phase = "arm_break"
  elseif arms_prepped() and legs_prep and not blademaster.state.flamefist_done then phase = "flamefist"
  elseif arms_prepped() and not legs_prep then phase = "leg_prep"
  else phase = "arm_prep" end

  -- Flamefist negates rebounding (its whole point), so only raze a hard shield.
  if phase == "flamefist" then
    if has_shield() then return "raze " .. target .. "/assess " .. target end
    blademaster.state.flamefist_done = true
    return "flamefist " .. target .. "/assess " .. target
  end

  local strike = quad_strike(phase)

  if has_shield() or has_rebounding() then
    return "raze " .. target .. " " .. strike .. "/assess " .. target
  end

  -- 005: airfist only during arm/leg prep.
  if (phase == "arm_prep" and needs_airfist("arm")) or (phase == "leg_prep" and needs_airfist("leg")) then
    return "airfist " .. target .. "/assess " .. target
  end

  local kind = "lightning"
  if phase == "arm_break" or phase == "leg_break" or phase == "mangle" then kind = "ice"
  elseif phase == "arm_prep" and will_prep_both_arms() then kind = "ice"
  elseif phase == "leg_prep" and will_prep_both_legs() then kind = "ice" end

  local cmd
  if phase == "arm_prep"  then cmd = prep_slash("armslash", "left arm", "right arm", focus_arm(), stance_dmg().armS)
  elseif phase == "leg_prep"  then cmd = prep_slash("legslash", "left leg", "right leg", focus_leg(), stance_dmg().legS)
  elseif phase == "arm_break" then cmd = "armslash " .. target .. " " .. focus_arm()
  else cmd = "legslash " .. target .. " right" end -- leg_break / mangle: RIGHT (curing applies left first)

  return infuse(kind) .. cmd .. " " .. strike .. "/assess " .. target
end

--------------------------------------------------------------------------------
-- STRATEGY 3: BROKENSTAR (bleed kill)
--   prep+break upper & legs -> impale -> impaleslash -> bladetwist (to 700) -> brokenstar
--   Execute branch reads AK state (impaled + bleeding); writhe re-impales implicitly.
--------------------------------------------------------------------------------

local function build_brokenstar()
  local slashed     = impaleslashed()
  local bleed_ready = slashed and bleed() >= C.BLEED_KILL   -- impaleslash gate guards stale bleed

  -- Execute / impale chain (all framework state). Checked before the shield/raze guard
  -- below: shield bounces slashes, but never the bleed kill or an in-progress impale,
  -- so we don't waste the window razing here.
  if bleed_ready then
    return "withdraw blade/sheathe sword/brokenstar " .. target
  end
  if impaled() then
    if slashed then return "bladetwist/discern " .. target end
    return "impaleslash/discern " .. target
  end
  if is_broken("left leg") and is_broken("right leg") or has("prone") then
    return "impale " .. target
  end

  -- Prep / break upper + legs.
  local up_prepped = is_prepped("torso") and is_prepped("head")
  local up_broken  = is_broken("torso") and is_broken("head")
  local legs_prep  = legs_prepped()

  local phase
  if up_broken and (legs_prep or will_break_both_legs()) then phase = "leg_break"
  elseif legs_prep and (up_prepped or will_break_upper()) then phase = "upper_break"
  elseif up_prepped and not legs_prep then phase = "leg_prep"
  else phase = "upper_prep" end

  local strike
  if phase == "leg_break" then strike = "knees"
  elseif phase == "upper_break" then strike = ice_strike()
  elseif phase == "leg_prep" and mounted() and hamstrung() and will_prep_both_legs() then strike = "knees"
  else strike = prep_strike() end

  if has_shield() or has_rebounding() then
    return "raze " .. target .. " " .. strike .. "/assess " .. target
  end

  -- 005: airfist only during leg prep.
  if phase == "leg_prep" and needs_airfist("leg") then
    return "airfist " .. target .. "/assess " .. target
  end

  if phase == "upper_prep" then
    local kind = will_prep_upper() and "ice" or "lightning"
    return infuse(kind) .. prep_upper() .. " " .. strike .. "/assess " .. target
  elseif phase == "upper_break" then
    return infuse("ice") .. "centreslash " .. target .. " " .. centreslash_dir() .. " " .. strike .. "/assess " .. target
  elseif phase == "leg_prep" then
    local kind = will_prep_both_legs() and "ice" or "lightning"
    return infuse(kind) .. prep_slash("legslash", "left leg", "right leg", focus_leg(), stance_dmg().legS) .. " " .. strike .. "/assess " .. target
  else -- leg_break
    return infuse("ice") .. "legslash " .. target .. " " .. focus_leg() .. " " .. strike .. "/assess " .. target
  end
end

--------------------------------------------------------------------------------
-- STRATEGY 4: GROUP (pommelstrike affliction lock)
--   hamstring > paralysis > asthma > slickness > anorexia(gated) > class-lock > hypochondria > sternum
--------------------------------------------------------------------------------

local function group_strike()
  if not hamstrung() then return "hamstring" end
  if not has("paralysis") then return "neck" end
  if not has("asthma")    then return "throat" end
  if not has("slickness") then return "underarm" end
  if has("impatience") and has("slickness") and not has("anorexia") then return "stomach" end
  if getLockingAffliction then
    local la = getLockingAffliction()
    local strike = la and C.LOCK_STRIKE[la]
    if strike and not has(C.LOCK_AFFNAME[la] or la) then return strike end
  end
  if not has("hypochondria") then return "chest" end
  return "sternum"
end

local function build_group()
  local strike = group_strike()
  if has_shield() or has_rebounding() then
    return "raze " .. target .. " " .. strike .. "/assess " .. target
  end
  return infuse("ice") .. "pommelstrike " .. target .. " " .. strike .. "/assess " .. target
end

--------------------------------------------------------------------------------
-- DISPATCH + JIT ARMING
--------------------------------------------------------------------------------

local STRATEGY = { double = build_double, quad = build_quad, brokenstar = build_brokenstar, group = build_group }

local function eqbal_up()
  local v = gmcp and gmcp.Char and gmcp.Char.Vitals
  return v and v.bal == "1" and v.eq == "1" or false
end

function blademaster.set_mode(mode)
  if not mode then return end
  mode = tostring(mode):lower()
  if STRATEGY[mode] then blademaster.state.mode = mode
  else cecho("\n<red>[BM] unknown mode: " .. mode) end
end

-- Build and send one attack from CURRENT state.
function blademaster.dispatch(mode)
  blademaster.set_mode(mode)

  if not target or target == "" then
    cecho("\n<red>[BM] No target set! (tar <name>)")
    return
  end
  if self_aff("aeon") then return end            -- can't act under aeon/retardation

  if blademaster.state.last_target ~= target then -- new target: drop stale per-fight state
    blademaster.state.last_target = target
    blademaster.state.flamefist_done = false
  end

  local combo = (STRATEGY[blademaster.state.mode] or build_double)()
  send_attack(combo)
end

-- Arm the system: fire now if balance+eq are up, else wait for on_recover.
function blademaster.arm(mode)
  blademaster.set_mode(mode)
  if eqbal_up() then
    blademaster.state.armed = false
    if blademaster.state.fire_timer then
      killTimer(blademaster.state.fire_timer)
      blademaster.state.fire_timer = nil
    end
    blademaster.dispatch()
    return
  end
  blademaster.state.armed = true
end

-- Balance/eq-USED trigger feeds the recovery interval here; we schedule the dispatch
-- for the instant balance returns so the combo is built from fresh state.
function blademaster.on_recover(interval)
  interval = tonumber(interval)
  if not interval then return end

  local lead = C.PREARM_LEAD or (getNetworkLatency and getNetworkLatency()) or 0.1
  local wait = math.max(0, interval - lead)

  local cur = blademaster.state.fire_timer
  if cur and remainingTime(cur) and remainingTime(cur) >= wait then return end
  if cur then killTimer(cur) end

  blademaster.state.fire_timer = tempTimer(wait, function()
    blademaster.state.fire_timer = nil
    if blademaster.state.armed then
      blademaster.state.armed = false
      blademaster.dispatch()
    end
  end)
end

function blademaster.reset()
  if blademaster.state.fire_timer then killTimer(blademaster.state.fire_timer) end
  blademaster.state.fire_timer = nil
  blademaster.state.armed = false
  blademaster.state.flamefist_done = false
  cecho("\n<green>[BM] reset")
end

--------------------------------------------------------------------------------
-- INTROSPECTION
--------------------------------------------------------------------------------

function blademaster.debug_snapshot()
  return {
    mode = blademaster.state.mode,
    armed = blademaster.state.armed or false,
    target = target,
    hp = target_hp(),
    legs = { left = limb_dmg("left leg"), right = limb_dmg("right leg") },
    arms = { left = limb_dmg("left arm"), right = limb_dmg("right arm") },
    upper = { torso = limb_dmg("torso"), head = limb_dmg("head") },
    parried = parried(),
    shin = shin(),
    impaled = impaled(),
    impaleslash = impaleslashed(),
    bleed = bleed(),
    prone = has("prone"),
    flamefist_done = blademaster.state.flamefist_done or false,
    stance = (Legacy and Legacy.Tannivh and Legacy.Tannivh.stance) or nil,
    dmg = stance_dmg(),
  }
end

--------------------------------------------------------------------------------
-- ALIAS HANDLERS (point manually-created Mudlet aliases at these)
--------------------------------------------------------------------------------

function bm()      blademaster.arm() end
function bmd()     blademaster.arm("double") end
function bmdq()    blademaster.arm("quad") end
function bmbs()    blademaster.arm("brokenstar") end
function bmgroup() blademaster.arm("group") end
function bmreset() blademaster.reset() end

function bmstatus()
  local s = blademaster.debug_snapshot()
  cecho(string.format(
    "\n<cyan>[BM <yellow>%s<cyan>] tar <yellow>%s<cyan> (%d%%) | legs %.0f/%.0f | arms %.0f/%.0f | upper T%.0f H%.0f | shin %d | bleed %d%s%s%s",
    s.mode, tostring(s.target or "none"), s.hp,
    s.legs.left, s.legs.right, s.arms.left, s.arms.right, s.upper.torso, s.upper.head,
    s.shin, s.bleed,
    s.impaled and " | <green>IMPALED<cyan>" or "",
    s.impaleslash and " | <green>SLASHED<cyan>" or "",
    s.armed and " | <magenta>ARMED" or ""))
end

cecho("\n<green>[BM] Blademaster loaded<reset> (mode: " .. blademaster.state.mode .. " — self-registers nothing; wire per MUDLET_SETUP.md)")

-- ── Design notes ────────────────────────────────────────────────────────────
-- Killpath logic ported from Levi ataxia (005_CC_BM_Ice + 003_BrokenStar + 004_Group);
-- only the state model changed, to shed fragility:
--   * Brokenstar reads affstrack.impale ("Me"), affstrack.score.impaleslash, and ak.bleeding
--     rather than tracking isImpaled/impaleslashDone/withdraw/twist-count — so it needs NO
--     custom triggers. The kill is one string ("withdraw blade/sheathe sword/brokenstar"); a
--     writhe simply flips impale off and the cascade re-impales. The impaleslash gate also
--     guards brokenstar against stale ak.bleeding from a prior target.
--   * arm()/on_recover() JIT replaces the attackInFlight latch + GMCP balance handler.
--   * Parry handling matches 005: airfist only, prep phases only; on low shin we just
--     slash (the focus logic already steers off the parried limb). No pommelstrike fallback.
--   * Group mode is the pommelstrike lock ladder only; use bmbs for the bleed kill.
--     (Levi 004 also bleed-executes inside group; omitted here as the strategies are split.)
--   * Slash damage is a STATIC per-stance table (CONFIG.DMG, keyed on Legacy.Tannivh.stance);
--     no live calibration — fill it by hand or with calibrate.lua.
--   * AFF_THRESHOLD 33 and the lb raw-target key match the prior port; sibling modules
--     use 30 — adjust CONFIG.AFF_THRESHOLD if you want parity.
-- Decision parity with 005 is verified by blademaster_test.lua (34/34 scenarios: infuse
-- + action + strike identical across double / quad / brokenstar / group).
