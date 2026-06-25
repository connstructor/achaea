-- Runewarden Dual-Cutting (DWC) Combat Engine for Achaea (Mudlet)
-- ---------------------------------------------------------------------------
-- A decision engine that builds one batch per EQBAL window and submits it via
-- the server-side QUEUE. Ported VERBATIM (branch order, attack commands, venom
-- ladders) from the Levi/Ataxia DWC Runewarden source:
--   dwc_runie/001_RIFT.lua            -> plan "rift"        (runie_riftlock)
--   dwc_runie/002_BASIC_2.lua         -> plan "basic"       (dwcpriosbasic)
--   dwc_runie/003_Disembowel_Prep.lua -> plan "disembowel"  (dwcprioslimb)   [default]
--   dwc_runie/004_Head_Prep.lua       -> plan "head"        (dwcpriosheadprep)
-- The firing/arming spine (arm + JIT timer + SETALIAS/QUEUE dispatch) and the
-- limb model are reused from the sibling Runewarden ports (2h_runie, snb_runie).
--
-- STATE SOURCES (the "dead global" trap is why the prior DWC/Magi ports were
-- scrapped: every state READ below maps to a *proven* AK/Legacy accessor):
--   Levi symbol                       -> AK / Legacy equivalent
--   tAffs.<aff>                       -> aff_present(s,"<aff>") = affstrack.score[aff] >= threshold
--   tAffs.rebounding / .shield        -> ak.defs.rebounding / .shield (NOT affstrack)
--   tAffs.impaled / timpale           -> affstrack.impale == "Me"
--   tAffs.damaged<limb> / brokenarm   -> is_limb_broken(limb) = lb[target].hits[limb] >= 100
--   tAffs.mildtrauma                  -> is_limb_broken("torso")
--   lb[target].hits[limb]             -> same (spaced keys, raw target key)
--   php / ataxiaTemp.lastAssess       -> hp_pct(s) from ak.currenthealth(/.health) / ak.maxhealth
--   engaged                           -> ak.engaged
--   tAffs.bleed                       -> ak.bleeding  (DISPLAY ONLY; the ladder never branches on
--                                        it, refreshed by the optional DISCERN ridealong)
--   ataxia.getWeapon("weaponN")       -> M.config.weaponN
--   scimdamage = dwcSlash * 2         -> M.config.dwc_slash_damage * 2  (a DSL is two slashes)
--   tBals.salve                       -> not tracked by AK; see M.state.salve_down (rift only)
--
-- Required host globals (provided by Mudlet + Legacy/AK at runtime):
--   send, tempTimer, getNetworkLatency, boxEcho, echo, os.time
--   gmcp.Char.Vitals.bal/.eq ("1"/"0"), target, ak.*, affstrack.*, lb, ignoreShield
--
-- This module self-registers NOTHING. Wire the aliases/triggers by hand in
-- Mudlet (see MUDLET_SETUP.md / DEPENDENCIES.md).
-- ===========================================================================
runewarden = runewarden or {}
runewarden.dwc = runewarden.dwc or {}
local M = runewarden.dwc

-- =============================================================
-- Config (user-editable; preserved across reloads)
-- =============================================================
M.config =
  M.config or
  {
    -- The two cutting weapons wielded for dual-cutting. TODO: set to your item ids.
    weapon1 = "scimitar",
    weapon2 = "scimitar",
    -- Swap-in execute weapon for the dispatch-level BISECT in the disembowel/head
    -- plans (Levi: `wield bastard;grip`). TODO: set to your bastard/2H item id.
    bisect_weapon = "bastard",
    -- The basic/rift plans use a SnB-style bisect (`wield shield <this>`).
    basic_bisect_weapon = "longsword",
    -- EMPOWER PRIORITY SET runes for the head-prep plan (head crack via runelore).
    empower_runes = "KENA MANNAZ SLEIZAK",
    -- Per-slash limb damage (ataxiaTables.limbData.dwcSlash). scimdamage = 2x this,
    -- because a DSL lands two slashes; prep math predicts a one-DSL break.
    dwc_slash_damage = 6.6,
    -- Affliction "treat as present" threshold: affstrack.score[aff] >= aff_threshold.
    aff_threshold = 50,
    aff_threshold_overrides = {},
    -- Target values that mean "no real target."
    invalid_targets = {None = true, Dude = true},
    -- Append `DISCERN <target>` to each batch to keep ak.bleeding fresh (display
    -- only; the DWC decision tree never branches on bleed). Set false for a 1:1
    -- match with the Levi source (which does not discern).
    discern_ridealong = true,
    -- combatQueue() prefix analog (commands prepended before the attack body).
    precommands = {},
    -- Latency-based arming. nil => getNetworkLatency().
    prearm_interval = nil,
  }

-- =============================================================
-- State (engine-managed; preserved across reloads)
-- =============================================================
M.state =
  M.state or
  {
    armed = false,
    -- "disembowel" | "head" | "basic" | "rift"; selected by the user via dwcplan.
    plan = "disembowel",
    -- Levi `need_falcon`: emit FALCON SLAY on the first (un-engaged) batch.
    need_falcon = true,
    -- Levi `tBals.salve == false`: target's salve balance is down. AK can't see it,
    -- so it's a manual flag the rift plan's riftlock (epteth/epteth) branch reads.
    salve_down = false,
    last_fire_time = 0,
  }

-- =============================================================
-- State read + helpers
-- =============================================================
-- Both balance and equilibrium ready? GMCP reports balances as "1"/"0" strings.
local function on_eqbal()
  return gmcp and gmcp.Char and gmcp.Char.Vitals and gmcp.Char.Vitals.bal == "1" and
    gmcp.Char.Vitals.eq == "1"
end

-- A "real" target is non-empty and not in the invalid set ("None", "Dude", etc.)
local function is_valid_target(t)
  if not t or t == "" then
    return false
  end
  if M.config.invalid_targets and M.config.invalid_targets[t] then
    return false
  end
  return true
end

-- lb keys use spaced limb names ("left leg"); raw target key per AK convention.
local function get_limb_damage(limb)
  return (lb and lb[target] and lb[target].hits and lb[target].hits[limb]) or 0
end

-- Level-2 break (crippled) is 100%. Levi's tAffs.damaged<limb> / mildtrauma /
-- broken<arm> are all derived from this lb-backed read (the proven source).
local function is_limb_broken(limb)
  return get_limb_damage(limb) >= 100
end

-- Snapshot of all decision-relevant framework state at one moment.
local function read_state()
  return
    {
      target = target,
      aff = (affstrack and affstrack.score) or {},
      -- affstrack.impale holds who is impaling; "Me" => the target is impaled by us.
      impaled = (affstrack and affstrack.impale == "Me") or false,
      -- HP robust across AK builds: 2h/blademaster expose currenthealth/maxhealth,
      -- snb exposes health. Read whichever is populated.
      hp_current = tonumber(ak and ak.currenthealth) or tonumber(ak and ak.health) or 0,
      hp_max = tonumber(ak and ak.maxhealth) or 1,
      rebounding = (ak and ak.defs and ak.defs.rebounding and not ignoreShield) or false,
      shield = (ak and ak.defs and ak.defs.shield and not ignoreShield) or false,
      engaged = (ak and ak.engaged) or false,
      bleed = tonumber(ak and ak.bleeding) or 0, -- display only
    }
end

-- Treat affliction as present when confidence >= threshold (per-aff override wins).
local function aff_present(state, name)
  local th = (M.config.aff_threshold_overrides and M.config.aff_threshold_overrides[name]) or
    M.config.aff_threshold
  return (tonumber(state.aff[name]) or 0) >= th
end

local function hp_pct(state)
  return state.hp_current / state.hp_max
end

-- Derived per-tick limb math (Levi scimdamage / prepped_* / damaged_*). Reset every
-- call -- never share across plans (002's reliance on a stale prepped_torso global
-- was a Levi bug; we recompute it locally instead).
local function derive(state)
  local d = {}
  d.scimdamage = M.config.dwc_slash_damage * 2
  d.axedamage = d.scimdamage - 3
  local function prepped(limb)
    return get_limb_damage(limb) + d.scimdamage >= 100 and not is_limb_broken(limb)
  end
  d.prepped_leftleg = prepped("left leg")
  d.prepped_rightleg = prepped("right leg")
  d.prepped_leftarm = prepped("left arm")
  d.prepped_rightarm = prepped("right arm")
  d.prepped_head = prepped("head")
  d.prepped_torso = prepped("torso")
  d.damagedleftleg = is_limb_broken("left leg")
  d.damagedrightleg = is_limb_broken("right leg")
  d.damagedleftarm = is_limb_broken("left arm")
  d.damagedrightarm = is_limb_broken("right arm")
  d.damagedhead = is_limb_broken("head")
  d.damagedtorso = is_limb_broken("torso")
  return d
end

-- =============================================================
-- Command builders (shared)
-- =============================================================
local function extend(dst, src)
  for _, c in ipairs(src) do
    dst[#dst + 1] = c
  end
end

-- The DWC re-wield/wipe prefix that opens almost every attack branch:
--   wield W1 W2;wipe W1;wipe W2;assess <target>
local function ww(s)
  local w1, w2 = M.config.weapon1, M.config.weapon2
  return {"WIELD " .. w1 .. " " .. w2, "WIPE " .. w1, "WIPE " .. w2, "ASSESS " .. s.target}
end

-- DSL <target> [limb] <v..>  — skips empty/nil venom slots so a short venom list
-- never produces a malformed command.
local function dsl(s, limb, ...)
  local parts = {"DSL", s.target}
  if limb then
    parts[#parts + 1] = limb
  end
  for _, v in ipairs({...}) do
    if v and v ~= "" then
      parts[#parts + 1] = v
    end
  end
  return table.concat(parts, " ")
end

local function razeslash(s, limb, venom)
  local parts = {"RAZESLASH", s.target}
  if limb then
    parts[#parts + 1] = limb
  end
  if venom and venom ~= "" then
    parts[#parts + 1] = venom
  end
  return table.concat(parts, " ")
end

-- Dispatch-level BISECT (disembowel/head plans): `wield bastard;grip;assess;bisect;engage`.
-- Always engages; short-circuits the whole batch (the atk-string bisect branch is dead).
local function bisect_dispatch(s)
  return
    {
      "WIELD " .. M.config.bisect_weapon,
      "GRIP",
      "ASSESS " .. s.target,
      "BISECT " .. s.target .. " CURARE",
      "ENGAGE " .. s.target,
    }
end

-- SnB-style BISECT body (basic/rift plans): `wield shield <weapon>;assess;bisect`.
local function bisect_body(s)
  return
    {
      "WIELD SHIELD " .. M.config.basic_bisect_weapon,
      "ASSESS " .. s.target,
      "BISECT " .. s.target .. " CURARE",
    }
end

-- =============================================================
-- Venom ladders (ported VERBATIM, one per plan). Each walks top-to-bottom
-- building an ordered list; venoms[1]/[2] feed the DSL/RAZESLASH commands.
-- tBals.salve is untracked (treated absent); inc_imp is untracked (false).
-- =============================================================

-- 003_Disembowel_Prep
local function venoms_disembowel(s, d)
  local v = {}
  local function ins(x) v[#v + 1] = x end
  local function a(n) return aff_present(s, n) end
  if (d.prepped_leftleg and d.prepped_rightleg) and d.damagedtorso and not a("prone") and
    not s.rebounding and not s.shield then
    ins("DELPHINIUM"); ins("DELPHINIUM")
  end
  if (d.prepped_leftleg or d.prepped_rightleg) and d.prepped_head and not a("prone") and
    not s.rebounding and not s.shield then
    ins("DELPHINIUM"); ins("DELPHINIUM")
  end
  if a("impatience") and not a("anorexia") and not a("slickness") and a("asthma") then
    ins("SLIKE"); ins("GECKO")
  end
  if a("impatience") and not a("anorexia") then -- and not tBals.salve (untracked => true)
    ins("SLIKE")
  end
  if a("slickness") and not a("anorexia") and not a("stupidity") and a("asthma") then
    ins("ACONITE"); ins("SLIKE")
  end
  if a("anorexia") and not a("dizziness") then ins("LARKSPUR") end
  if a("anorexia") and not a("stupidity") then ins("ACONITE") end
  if a("anorexia") and not a("shyness") then ins("DIGITALIS") end
  if a("anorexia") and not a("recklessness") then ins("EURYPTERIA") end
  if not a("paralysis") then ins("CURARE") end
  if not a("nausea") then ins("VERNALIUS") end
  if not a("asthma") then ins("KALMIA") end
  if not a("clumsiness") then ins("XENTIO") end
  if not a("slickness") and a("asthma") and v[1] == "CURARE" then ins("GECKO") end
  if not a("addiction") then ins("VARDRAX") end
  if not a("sensitivity") and a("deaf") then ins("PREFARAR"); ins("PREFARAR") end
  if not a("sensitivity") and not a("deaf") then ins("PREFARAR") end
  if not a("recklessness") then ins("EURYPTERIA") end
  if not a("stupidity") then ins("ACONITE") end
  if not a("dizziness") then ins("LARKSPUR") end
  if not a("shyness") then ins("DIGITALIS") end
  if not d.damagedrightarm then ins("EPTETH") end -- not tAffs.brokenrightarm
  if not d.damagedleftarm then ins("EPTETH") end -- not tAffs.brokenleftarm
  if not a("darkshade") then ins("DARKSHADE") end
  return v
end

-- 004_Head_Prep
local function venoms_head(s, d)
  local v = {}
  local function ins(x) v[#v + 1] = x end
  local function a(n) return aff_present(s, n) end
  local inc_imp = false -- Levi self-tracks incoming impatience; no AK source.
  if a("impatience") and a("anorexia") and not a("slickness") and not a("paralysis") then
    ins("CURARE"); ins("GECKO")
  end
  if a("impatience") and not a("anorexia") and a("slickness") and not a("paralysis") then
    ins("CURARE"); ins("SLIKE")
  end
  if a("impatience") and not a("anorexia") and not a("slickness") then
    ins("GECKO"); ins("SLIKE")
  end
  if a("slickness") and not a("anorexia") and not a("stupidity") and a("asthma") then
    ins("ACONITE"); ins("SLIKE")
  end
  if a("impatience") and not a("anorexia") and not a("slickness") and a("asthma") then
    ins("SLIKE"); ins("GECKO")
  end
  if a("impatience") and not a("anorexia") then -- and not tBals.salve
    ins("SLIKE")
  end
  if inc_imp and not a("paralysis") then ins("CURARE") end
  if inc_imp and not a("asthma") then ins("KALMIA") end
  if a("anorexia") and not a("dizziness") then ins("LARKSPUR") end
  if a("anorexia") and not a("stupidity") then ins("ACONITE") end
  if a("anorexia") and not a("shyness") then ins("DIGITALIS") end
  if a("anorexia") and not a("recklessness") then ins("EURYPTERIA") end
  if not a("paralysis") then ins("CURARE") end
  if not a("nausea") then ins("VERNALIUS") end
  if not a("asthma") then ins("KALMIA") end
  if not a("clumsiness") then ins("XENTIO") end
  if not a("slickness") and a("asthma") and v[1] == "CURARE" then ins("GECKO") end
  if not a("sensitivity") and a("deaf") then ins("PREFARAR"); ins("PREFARAR") end
  if not a("sensitivity") and not a("deaf") then ins("PREFARAR") end
  if not a("addiction") then ins("VARDRAX") end
  if not a("recklessness") then ins("EURYPTERIA") end
  if not a("stupidity") then ins("ACONITE") end
  if not a("dizziness") then ins("LARKSPUR") end
  if not a("shyness") then ins("DIGITALIS") end
  if not d.damagedrightarm then ins("EPTETH") end
  if not d.damagedleftarm then ins("EPTETH") end
  if not a("darkshade") then ins("DARKSHADE") end
  return v
end

-- 002_BASIC_2
local function venoms_basic(s, d)
  local v = {}
  local function ins(x) v[#v + 1] = x end
  local function a(n) return aff_present(s, n) end
  if a("slickness") and not a("anorexia") and a("paralysis") and not a("stupidity") and
    a("asthma") and not s.rebounding then
    ins("ACONITE"); ins("SLIKE")
  end
  if a("impatience") and not a("anorexia") and not a("slickness") and a("asthma") then
    ins("SLIKE"); ins("GECKO")
  end
  if a("impatience") and not a("anorexia") then -- and not tBals.salve
    ins("SLIKE")
  end
  if a("anorexia") and not a("dizziness") then ins("LARKSPUR") end
  if a("anorexia") and not a("recklessness") then ins("EURYPTERIA") end
  if a("anorexia") and not a("shyness") then ins("DIGITALIS") end
  if not a("paralysis") then ins("CURARE") end
  if not a("weariness") then ins("VERNALIUS") end
  if not a("asthma") then ins("KALMIA") end
  if not a("clumsiness") then ins("XENTIO") end
  if not a("slickness") and a("asthma") and v[1] == "CURARE" then ins("GECKO") end
  if not a("recklessness") then ins("EURYPTERIA") end
  if not a("stupidity") then ins("ACONITE") end
  if not a("dizziness") then ins("LARKSPUR") end
  if a("asthma") and not a("disloyalty") then ins("MONKSHOOD") end
  if not a("shyness") then ins("DIGITALIS") end
  if not a("sensitivity") then ins("PREFARAR"); ins("PREFARAR") end
  if not a("addiction") then ins("VARDRAX") end
  if not a("darkshade") then ins("DARKSHADE") end
  return v
end

-- 001_RIFT
local function venoms_rift(s, d)
  local v = {}
  local function ins(x) v[#v + 1] = x end
  local function a(n) return aff_present(s, n) end
  if M.state.salve_down and a("addiction") then -- tBals.salve == false and tAffs.addiciton
    ins("EPTETH"); ins("EPTETH")
  end
  if (d.prepped_leftleg and d.prepped_rightleg) and d.damagedtorso and not a("prone") and
    not s.rebounding and not s.shield then
    ins("DELPHINIUM"); ins("DELPHINIUM")
  end
  if (d.prepped_leftleg or d.prepped_rightleg) and d.prepped_head and not a("prone") and
    not s.rebounding and not s.shield then
    ins("DELPHINIUM"); ins("DELPHINIUM")
  end
  -- Levi typo `not tAffs.stupid` (no such key) => always true; reproduced faithfully.
  if a("slickness") and not a("anorexia") and a("paralysis") and not a("stupid") then
    ins("ACONITE"); ins("SLIKE")
  end
  if a("impatience") and not a("anorexia") and not a("slickness") then
    ins("SLIKE"); ins("GECKO")
  end
  if a("impatience") and not a("anorexia") then -- and not tBals.salve
    ins("SLIKE")
  end
  if d.damagedhead and not a("stupidity") then ins("ACONITE") end
  if d.damagedhead and not a("dizziness") then ins("LARKSPUR") end
  if d.damagedhead and not a("recklessness") then ins("EURYPTERIA") end
  if d.damagedhead and not a("shyness") then ins("DIGITALIS") end
  if not a("paralysis") then ins("CURARE") end
  if not a("addiction") then ins("VARDRAX") end
  if not a("weariness") then ins("VERNALIUS") end
  if not a("asthma") then ins("KALMIA") end
  if not a("clumsiness") then ins("XENTIO") end
  if not a("slickness") and a("asthma") and v[1] == "CURARE" then ins("GECKO") end
  if not a("nausea") then ins("EUPHORBIA") end
  if not a("dizziness") then ins("LARKSPUR") end
  if not a("stupidity") then ins("ACONITE") end
  if not a("recklessness") then ins("EURYPTERIA") end
  if not a("shyness") then ins("DIGITALIS") end
  if not a("sensitivity") then ins("PREFARAR"); ins("PREFARAR") end
  if not a("darkshade") then ins("DARKSHADE") end
  return v
end

-- =============================================================
-- Plan: Disembowel-Prep (003 / dwcprioslimb) -- DEFAULT
-- =============================================================
local function plan_disembowel(s, d)
  local t = s.target
  local function a(n) return aff_present(s, n) end
  local venoms = venoms_disembowel(s, d)

  -- Limb target pick
  local targetlimb
  if not d.damagedtorso then
    targetlimb = "TORSO"
  elseif not d.prepped_rightleg then
    targetlimb = "RIGHT LEG"
  elseif d.prepped_rightleg and not d.prepped_leftleg then
    targetlimb = "LEFT LEG"
  else
    targetlimb = "TORSO" -- fallback (Levi leaves stale; default torso)
  end

  -- Raze flags (axedamage-vs-scimdamage margin: a slash would over/under-break)
  local rl, ra = get_limb_damage("right leg"), get_limb_damage("right arm")
  local ll, la = get_limb_damage("left leg"), get_limb_damage("left arm")
  local need_raze = s.rebounding or s.shield
  local need_raze2 =
    (rl + d.scimdamage >= 100 and rl + d.axedamage < 100 and targetlimb == "RIGHT LEG") or
    (ra + d.scimdamage >= 100 and ra + d.axedamage < 100 and targetlimb == "RIGHT ARM")
  local need_raze3 =
    (ll + d.scimdamage >= 100 and ll + d.axedamage < 100 and targetlimb == "LEFT LEG") or
    (la + d.scimdamage >= 100 and la + d.axedamage < 100 and targetlimb == "LEFT ARM")

  local use_bisect = hp_pct(s) <= 0.35
  local disembowel = s.impaled

  -- Bisect short-circuits the whole batch (dispatch form). The live Levi dispatch
  -- (003:333) fires on use_bisect alone -- BISECT ignores shield -- so no shield gate.
  if use_bisect then
    return bisect_dispatch(s)
  end

  -- Build the attack body.
  local atk
  if disembowel then
    atk = {"DISEMBOWEL " .. t}
  elseif a("prone") and d.damagedleftleg then
    atk = ww(s); extend(atk, {"IMPALE " .. t, "FURY ON"})
  elseif ll + d.scimdamage >= 101 or d.damagedleftleg then
    -- (Levi omits the ASSESS on this second impale branch.)
    local w1, w2 = M.config.weapon1, M.config.weapon2
    atk = {"WIELD " .. w1 .. " " .. w2, "WIPE " .. w1, "WIPE " .. w2, "IMPALE " .. t, "FURY ON"}
  elseif need_raze then
    atk = ww(s); atk[#atk + 1] = razeslash(s, targetlimb, venoms[1])
  elseif need_raze2 then
    atk = ww(s); atk[#atk + 1] = razeslash(s, targetlimb, venoms[1])
  elseif need_raze3 then
    atk = ww(s); atk[#atk + 1] = razeslash(s, targetlimb, venoms[1])
  elseif not d.damagedrightleg and a("nausea") and not s.rebounding and not s.shield and
    d.prepped_rightleg and d.prepped_leftleg and not a("prone") and d.damagedtorso then
    atk = ww(s); atk[#atk + 1] = dsl(s, "RIGHT LEG", "DELPHINIUM", "DELPHINIUM")
  elseif d.damagedrightleg and not s.rebounding and not s.shield and d.prepped_leftleg and
    d.damagedtorso and not a("slickness") then
    atk = ww(s); atk[#atk + 1] = dsl(s, "LEFT LEG", "GECKO", "CURARE")
  elseif d.damagedrightleg and not s.rebounding and not s.shield and d.prepped_leftleg and
    d.damagedtorso and a("slickness") then
    atk = ww(s); atk[#atk + 1] = dsl(s, "LEFT LEG", "EPTETH", "CURARE")
  elseif a("nausea") and (not d.prepped_leftleg or not d.prepped_rightleg) then
    atk = ww(s); atk[#atk + 1] = dsl(s, targetlimb, venoms[2], venoms[1])
  elseif a("nausea") and not d.damagedtorso then
    atk = ww(s); atk[#atk + 1] = dsl(s, "TORSO", venoms[2], venoms[1])
  else
    atk = ww(s); atk[#atk + 1] = dsl(s, nil, venoms[2], venoms[1])
  end

  -- Dispatch wrap (003): falcon (gated) -> atk -> engage -> assess.
  local out = {}
  if not s.engaged and M.state.need_falcon then
    out[#out + 1] = "FALCON SLAY " .. t
  end
  extend(out, atk)
  if not s.engaged then
    out[#out + 1] = "ENGAGE " .. t
  end
  out[#out + 1] = "ASSESS " .. t
  return out
end

-- =============================================================
-- Plan: Head-Prep (004 / dwcpriosheadprep)
-- =============================================================
local function plan_head(s, d)
  local t = s.target
  local function a(n) return aff_present(s, n) end
  local venoms = venoms_head(s, d)

  -- Limb target pick
  local targetlimb
  if not d.prepped_head then
    targetlimb = "HEAD"
  elseif not d.prepped_rightleg then
    targetlimb = "RIGHT LEG"
  elseif d.damagedrightleg and not d.damagedhead and d.prepped_head then
    targetlimb = "HEAD"
  elseif d.prepped_rightleg and not d.prepped_leftleg then
    targetlimb = "LEFT LEG"
  else
    targetlimb = "HEAD" -- fallback
  end

  local rl, ra = get_limb_damage("right leg"), get_limb_damage("right arm")
  local ll, la = get_limb_damage("left leg"), get_limb_damage("left arm")
  local need_raze = s.rebounding or s.shield
  local need_raze2 =
    (rl + d.scimdamage >= 100 and rl + d.axedamage < 100 and targetlimb == "RIGHT LEG") or
    (ra + d.scimdamage >= 100 and ra + d.axedamage < 100 and targetlimb == "RIGHT ARM")
  local need_raze3 =
    (ll + d.scimdamage >= 100 and ll + d.axedamage < 100 and targetlimb == "LEFT LEG") or
    (la + d.scimdamage >= 100 and la + d.axedamage < 100 and targetlimb == "LEFT ARM")

  local use_bisect = hp_pct(s) <= 0.35
  local disembowel = s.impaled

  -- BISECT ignores shield; the live Levi dispatch (004:363) fires on use_bisect alone.
  if use_bisect then
    return bisect_dispatch(s)
  end

  local atk
  if disembowel then
    atk = {"DISEMBOWEL " .. t}
  elseif need_raze then
    atk = ww(s); atk[#atk + 1] = razeslash(s, targetlimb, venoms[1])
  elseif need_raze2 then
    atk = ww(s); atk[#atk + 1] = razeslash(s, targetlimb, venoms[1])
  elseif need_raze3 then
    atk = ww(s); atk[#atk + 1] = razeslash(s, targetlimb, venoms[1])
  elseif a("prone") and d.damagedleftleg then
    atk = ww(s); extend(atk, {"FURY ON", "IMPALE " .. t})
  elseif not d.damagedrightleg and a("nausea") and not s.rebounding and not s.shield and
    d.prepped_rightleg then
    atk = ww(s); atk[#atk + 1] = dsl(s, "RIGHT LEG", "DELPHINIUM", "DELPHINIUM")
  elseif d.damagedrightleg and not s.rebounding and not s.shield and d.prepped_head then
    atk = ww(s); atk[#atk + 1] = dsl(s, "HEAD", "SLIKE", "ACONITE") -- the head crack
  elseif a("nausea") and not s.rebounding and not s.shield and d.damagedhead then
    atk = ww(s); atk[#atk + 1] = dsl(s, "HEAD", venoms[2], venoms[1])
  elseif d.damagedrightleg and not s.rebounding and not s.shield and d.prepped_leftleg and
    d.damagedtorso and not a("slickness") then
    atk = ww(s); atk[#atk + 1] = dsl(s, "LEFT LEG", "GECKO", "CURARE")
  elseif d.damagedrightleg and not s.rebounding and not s.shield and d.prepped_leftleg and
    d.damagedtorso and a("slickness") then
    atk = ww(s); atk[#atk + 1] = dsl(s, "LEFT LEG", "EPTETH", "CURARE")
  elseif a("nausea") and (not d.prepped_leftleg or not d.prepped_rightleg) then
    atk = ww(s); atk[#atk + 1] = dsl(s, targetlimb, venoms[2], venoms[1])
  elseif a("nausea") and not d.damagedtorso then
    atk = ww(s); atk[#atk + 1] = dsl(s, "TORSO", venoms[2], venoms[1])
  else
    atk = ww(s); atk[#atk + 1] = dsl(s, nil, venoms[2], venoms[1])
  end

  -- Dispatch wrap (004): EMPOWER -> falcon (gated) -> atk -> engage -> assess -> contemplate.
  local out = {"EMPOWER PRIORITY SET " .. M.config.empower_runes}
  if not s.engaged and M.state.need_falcon then
    out[#out + 1] = "FALCON SLAY " .. t
  end
  extend(out, atk)
  if not s.engaged then
    out[#out + 1] = "ENGAGE " .. t
  end
  out[#out + 1] = "ASSESS " .. t
  out[#out + 1] = "CONTEMPLATE " .. t
  return out
end

-- =============================================================
-- Plan: Basic (002 / dwcpriosbasic)
-- =============================================================
local function plan_basic(s, d)
  local t = s.target
  local function a(n) return aff_present(s, n) end

  -- Nausea hand-off to the disembowel-prep plan (Levi calls dwcprioslimb()).
  -- We return its result directly (Levi's fall-through double-sent a stray batch).
  if a("nausea") and not d.prepped_rightleg and not a("prone") then
    return plan_disembowel(s, d)
  elseif a("nausea") and not d.prepped_leftleg and not a("prone") then
    return plan_disembowel(s, d)
  elseif a("nausea") and not d.prepped_torso then
    return plan_disembowel(s, d)
  end

  local venoms = venoms_basic(s, d)
  local disembowel = s.impaled and is_limb_broken("torso")
  local need_raze = s.rebounding or s.shield
  local use_bisect = (hp_pct(s) <= 0.35 and not s.shield) or a("healthleech")

  local atk
  if use_bisect then
    atk = bisect_body(s)
  elseif disembowel then
    atk = ww(s); atk[#atk + 1] = "DISEMBOWEL " .. t
  elseif need_raze then
    atk = ww(s); atk[#atk + 1] = razeslash(s, nil, venoms[1])
  elseif a("prone") and d.damagedtorso and d.damagedrightleg and d.damagedleftleg then
    atk = ww(s); extend(atk, {"ASSESS " .. t, "IMPALE " .. t})
  elseif not s.rebounding and not s.shield and d.prepped_head and a("prone") then
    atk = ww(s); atk[#atk + 1] = dsl(s, "HEAD", "GECKO", "CURARE")
  elseif not d.damagedrightleg and a("nausea") and not s.rebounding and not s.shield and
    d.prepped_rightleg and d.prepped_leftleg and not a("prone") and d.prepped_torso then
    atk = ww(s); atk[#atk + 1] = dsl(s, "RIGHT LEG", "DELPHINIUM", "DELPHINIUM")
  elseif venoms[1] == "CURARE" then
    atk = ww(s); atk[#atk + 1] = dsl(s, nil, venoms[2], venoms[1])
  else
    atk = ww(s); atk[#atk + 1] = dsl(s, nil, venoms[1], venoms[2])
  end

  -- Dispatch wrap (002): falcon (always) -> atk -> engage -> assess.
  local out = {"FALCON SLAY " .. t}
  extend(out, atk)
  if not s.engaged then
    out[#out + 1] = "ENGAGE " .. t
  end
  out[#out + 1] = "ASSESS " .. t
  return out
end

-- =============================================================
-- Plan: Rift (001 / runie_riftlock)
-- =============================================================
local function plan_rift(s, d)
  local t = s.target
  local function a(n) return aff_present(s, n) end
  local venoms = venoms_rift(s, d)

  -- Levi never assigns targetlimb here (relied on a stale global); use the
  -- disembowel-prep pick so the raze/dsl branches have a valid limb.
  local targetlimb
  if not d.damagedtorso then
    targetlimb = "TORSO"
  elseif not d.prepped_rightleg then
    targetlimb = "RIGHT LEG"
  elseif d.prepped_rightleg and not d.prepped_leftleg then
    targetlimb = "LEFT LEG"
  else
    targetlimb = "TORSO"
  end

  local rl, ra = get_limb_damage("right leg"), get_limb_damage("right arm")
  local ll, la = get_limb_damage("left leg"), get_limb_damage("left arm")
  local need_raze = s.rebounding or s.shield
  local need_raze2 =
    (rl + d.scimdamage >= 100 and rl + d.axedamage < 100 and targetlimb == "RIGHT LEG") or
    (ra + d.scimdamage >= 100 and ra + d.axedamage < 100 and targetlimb == "RIGHT ARM")
  local need_raze3 =
    (ll + d.scimdamage >= 100 and ll + d.axedamage < 100 and targetlimb == "LEFT LEG") or
    (la + d.scimdamage >= 100 and la + d.axedamage < 100 and targetlimb == "LEFT ARM")

  local use_bisect = hp_pct(s) <= 0.35
  local disembowel = s.impaled and is_limb_broken("torso")

  local atk
  if use_bisect then
    atk = bisect_body(s)
  elseif disembowel then
    atk = ww(s); atk[#atk + 1] = "DISEMBOWEL " .. t
  elseif need_raze then
    atk = ww(s); atk[#atk + 1] = razeslash(s, targetlimb, venoms[1])
  elseif need_raze2 then
    atk = ww(s); atk[#atk + 1] = razeslash(s, targetlimb, venoms[1])
  elseif need_raze3 then
    atk = ww(s); atk[#atk + 1] = razeslash(s, targetlimb, venoms[1])
  elseif a("prone") and d.damagedtorso and d.damagedrightleg and d.damagedleftleg then
    atk = ww(s); atk[#atk + 1] = "IMPALE " .. t
  elseif M.state.salve_down and a("addiction") then -- tBals.salve == false and tAffs.addiction
    atk = ww(s); atk[#atk + 1] = dsl(s, targetlimb, "EPTETH", "EPTETH")
  else
    atk = ww(s); atk[#atk + 1] = dsl(s, targetlimb, venoms[1], venoms[2])
  end

  -- Dispatch wrap (001): atk -> engage (no falcon, no trailing assess).
  local out = {}
  extend(out, atk)
  if not s.engaged then
    out[#out + 1] = "ENGAGE " .. t
  end
  return out
end

-- =============================================================
-- Batch builder + fire
-- =============================================================
local PLAN = {
  disembowel = plan_disembowel,
  head = plan_head,
  basic = plan_basic,
  rift = plan_rift,
}

local function build_batch(s)
  local fn = PLAN[M.state.plan] or plan_disembowel
  local cmds = {}
  extend(cmds, M.config.precommands or {})
  extend(cmds, fn(s, derive(s)))
  -- DISCERN ridealong keeps ak.bleeding fresh for the GUI (display only).
  if M.config.discern_ridealong then
    cmds[#cmds + 1] = "DISCERN " .. s.target
  end
  return cmds
end

local function compute_and_fire()
  local s = read_state()
  if not is_valid_target(s.target) then
    return
  end
  local cmds = build_batch(s)
  if #cmds == 0 then
    return
  end
  boxEcho.send("FIRE")
  send("SETALIAS DWCATK " .. table.concat(cmds, "/"))
  send("QUEUE ADDCLEARFULL FREE DWCATK")
  M.state.last_fire_time = os.time()
end

-- =============================================================
-- Public surface (called from hand-wired Mudlet aliases / triggers)
-- =============================================================
-- Alias 'zz' (suggested): arm for the next balance window, or fire now if EQBAL ready.
function M.arm()
  if not is_valid_target(target) then
    boxEcho.send("[DWC] Not arming: target is '" .. tostring(target) .. "'.")
    return
  end
  if on_eqbal() then
    compute_and_fire()
  else
    boxEcho.send("ARMED")
    M.state.armed = true
  end
end

-- Alias 'dwcplan <name>': choose the active offense plan.
function M.set_plan(name)
  if not PLAN[name] then
    echo("[DWC] Unknown plan '" .. tostring(name) .. "'. Use: disembowel | head | basic | rift\n")
    return
  end
  M.state.plan = name
  echo("[DWC] Plan: " .. name .. "\n")
end

-- Toggle falcon usage (Levi need_falcon).
function M.toggle_falcon()
  M.state.need_falcon = not M.state.need_falcon
  echo("[DWC] Falcon: " .. (M.state.need_falcon and "on" or "off") .. "\n")
end

-- Toggle the salve-down flag (rift riftlock branch; AK can't see salve balance).
function M.set_salve_down(v)
  M.state.salve_down = v and true or false
  echo("[DWC] salve_down = " .. tostring(M.state.salve_down) .. "\n")
end

-- Balance-used trigger handler -- pass the captured recovery interval (seconds).
-- Schedules a one-shot dispatch for (interval - prearm) so the batch lands the
-- instant balance returns (the server-side QUEUE holds it). Fires only if armed.
local BALANCE_USED_COMBAT_WINDOW = 10
function M.on_balance_used(seconds)
  if os.time() - (M.state.last_fire_time or 0) > BALANCE_USED_COMBAT_WINDOW and not M.state.armed then
    return
  end
  if not is_valid_target(target) then
    return
  end
  local interval = tonumber(seconds)
  if not interval or interval <= 0 then
    return
  end
  local prearm = M.config.prearm_interval or getNetworkLatency()
  local fire_delay = math.max(0, interval - prearm)
  tempTimer(
    fire_delay,
    function()
      if M.state.armed then
        M.state.armed = false
        compute_and_fire()
      end
    end
  )
end

-- Alias 'dwcreset': teardown. Drop fury and disarm.
function M.reset()
  send("FURY OFF")
  M.state.armed = false
  M.state.last_fire_time = 0
  boxEcho.send("[DWC] System reset.")
end

-- gmcp.Char.Vitals handler -- firing is driven by the prearm dispatch timer, so
-- this is a no-op kept for parity with the sibling ports' wiring.
function M.on_gmcp_char_vitals(_event)
end

boxEcho.send("[DWC] Combat engine loaded.")
