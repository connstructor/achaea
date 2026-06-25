------------------------------------------
-- magi.lua — Legacy / AK port (Magi / Elementalism offense)
------------------------------------------
-- Ported from the LEVI / Ataxia Magi modules (`magi.*` namespace):
--   mage/001_Resonance.lua            (self resonance state, from GMCP charstats)
--   mage/004_Magi_Offense.lua         (the unified 5-mode decision tree)
--   mage/005_Stormhammer_Targeting.lua(3-target stormhammer selector)
-- The decision tree itself is ported VERBATIM; only the state READS are re-pointed.
--
-- STATE SOURCING (read this): the Magi cast-states the decision tree pivots on are read
-- LIVE from AK `affstrack` -- BURNS via `aflame` (100 per stack), plus `conflagrate`,
-- `scalded`, `calcifiedtorso`, `calcifiedhead`, `frozen`, `hypothermia` -- alongside the
-- ordinary afflictions (asthma, frostbite, weariness, nausea, paralysis, anorexia,
-- clumsiness, prone, ...). AK owns the decay/clear, so there is no per-target bookkeeping
-- and nothing to reset. Only state AK genuinely cannot see is self-tracked here:
--   * SHALESTORM (our channel is active on them)   -- magi.state.shalestorm
--   * SCINTILLA over-cast spark (our 4s cooldown)  -- magi.state.scintillaSpark
-- plus an OPTIONAL `magi.affs` fallback layer (OR'd with affstrack) for affs Magi applies
-- via class-specific cast lines AK may not parse (waterbond/blistered, the fulminate
-- chain, the nocaloric/shivering freeze buildup). (The prior port was scrapped for reading
-- these cast-states from affstrack keys that did not yet exist; AK now tracks them.)
--
-- KILL ROUTES (priority order, see select_spell):
--   fire   -> burns -> conflagrate -> destroy / stormhammer        (default)
--   water  -> freeze -> hypothermia -> glaciate   (lives in the shared spine; any mode)
--   lock   -> kelp/resonance affliction stack via fulminate/horripilation/scintilla
--   salve  -> earth/fire resonance + scalded/calcify salve-balance pressure
--   group  -> stormhammer multi-target + emanation damage
--
-- FIRING MODEL: arm + just-in-time timer (house "new-family", like Psion). A Magi
-- combo spends BOTH equilibrium (casts) and balance (staffcasts), so wire on_balance
-- to BOTH the Balance- and Equilibrium-used lines; it keeps the timer for whichever
-- resource returns LAST. The FREE(STAND) server queue holds the chain until balance
-- actually returns, so dispatch does NOT re-gate eq/bal at fire time.
------------------------------------------
-- Required globals (host frameworks -- Legacy curing + AK + Mudlet; not provided here)
------------------------------------------
-- Legacy:  Legacy.Curing.Affs (self affs -- the aeon guard),
--          Legacy.Settings.Curing.status (false = paused)
-- gmcp:    Char.Vitals.bal / Char.Vitals.eq ("1"/"0"),
--          Char.Vitals.charstats (flat "Key: Value" list -- holds Rfire/Rair/.. resonance),
--          Char.Status.class (own class -- the Magi guard), Char.Status.name (self-exclusion),
--          Room.Players (stormhammer candidate list)
-- ak:      ak.defs.shield / ak.defs.rebounding, ak.currenthealth / ak.maxhealth (target HP%)
-- affstrack: opponent affliction tracker -- affstrack.score[aff] 0-100
-- lb:      opponent limb damage -- lb[target].hits["left leg"] etc., 0-200 (>=100 broken)
-- target:  current target name (string)
-- boxEcho: status sink (notify falls back to cecho/print if absent)
-- send / tempTimer / killTimer / getEpoch / getNetworkLatency : Mudlet built-ins
------------------------------------------
-- Wire-up (create by hand in Mudlet -- this module self-registers NOTHING; full list
-- with patterns in MUDLET_SETUP.md). Two groups:
--   FIRING:  the arm aliases (mfire/mwater/mlock/msalve/mgroup) + ONE regex
--            "^(Balance|Equilibrium) used: (\d+\.\d+)s\.$" -> magi.on_balance(tonumber(matches[3]))
--            + a target-change handler -> magi.reset()
--   STATE:   only a few thin triggers -> magi.track.* (scintilla spark/ignite, shalestorm
--            start/end, and the optional applied-aff fallbacks). AK supplies the rest.
------------------------------------------
-- DEPENDENCY MAPPING (Levi / Ataxia  ->  Legacy / AK)
--   haveAff("X") / tAffs.X              -> has_aff("X")  (affstrack.score[X] >= AFF_THRESHOLD)
--   getAffProbabilityV3("X")           -> prob("X")     (affstrack.score[X] / 100)
--   magi.offense.state.burns (0-5)     -> floor(affstrack.score.aflame / 100)  (AK; 100/stack)
--   magi.offense.state.{conflagrated,  -> has_aff("conflagrate"/"scalded"/"calcifiedtorso"/
--     scalded,calcified*,frozen,hypo}     "calcifiedhead"/"frozen"/"hypothermia")  (AK affstrack)
--   magi.resonance (V3-fed)            -> magi.resonance (parsed from gmcp charstats, unchanged)
--   targetHealth / php                 -> target_hp()   (ak.currenthealth/maxhealth*100)
--   hasAff("brokenleftleg") ...        -> is_limb_broken("left leg") (lb[target].hits, >=100)
--   haveAff("shield")/("rebounding")   -> ak.defs.shield / ak.defs.rebounding
--   ataxia.afflictions.aeon            -> self_aff("aeon")   (Legacy.Curing.Affs.aeon)
--   ataxia.settings.paused (n/a)       -> is_paused()        (Legacy.Settings.Curing.status==false)
--   gmcp.Char.Status.class guard       -> my_class() (lenient: blocks only a KNOWN non-Magi class)
--   ataxia.settings.separator ("::")   -> CONFIG.SEPARATOR ("/", house SETALIAS convention)
--   send("queue addclearfull freestand X") -> SETALIAS MAGIATK ... + QUEUE ADDCLEARFULL FREESTAND MAGIATK
--   ataxia.playersHere                 -> gmcp.Room.Players (soul-of- prefix stripped)
--   ataxiaTemp.enemies                 -> magi.storm.is_enemy() (override / CONFIG.storm.enemies)
--   ataxiaNDB_getCitizenship           -> guarded; "city" mode degrades to "all" if absent
--   tprio.list ("priority" mode)       -> guarded; degrades to "all" (tprio not ported)
--   partyrelay (global)                -> CONFIG.partyRelay (off by default; pt via queue_now)
--   getAffProb("burning")==0 reset     -> DROPPED (AK has no "burning" aff; self-tracked burns
--                                         counter is authoritative, cleared by magi.track.*)
------------------------------------------
magi = magi or {}

------------------------------------------
-- CONFIG -- all tunables. Override AFTER this file loads.
------------------------------------------
magi.CONFIG = magi.CONFIG or
{
  -- affstrack confidence (0-100) at/above which a boolean aff (haveAff) counts as landed.
  -- Levi's haveAff routed V3 at 30%; the prob()>=0.5 gates use the 0-1 form directly.
  AFF_THRESHOLD = 30,

  -- target HP% gates (verbatim from the source)
  destroyThreshold = 35,          -- conflagrated + hp < this -> cast destroy (kill)
  stormhammerThreshold = 25,      -- hp <= this -> stormhammer (kill), any mode
  groupStormhammerThreshold = 50, -- group mode opens stormhammer at this HP%

  -- self-tracked latch durations (seconds; client-side, verify vs live Achaea)
  blisteredDuration = 15,         -- blistered (fire-major resonance) fallback latch lifetime
  scintillaDuration = 4,          -- scintilla over-cast spark window before ignite/fade

  -- artefact prefixes (free actions; off by default)
  useArachnideye = false,         -- "arachnideye trample <t>" prefix when target not prone
  useWebbomb = false,             -- "webbomb <t>" prefix when target not entangled

  -- party callout relay (off by default; AK has no `partyrelay` global)
  partyRelay = false,

  -- weapon item IDs -- OVERRIDE THESE per character (wield <staff> <shield> each turn).
  -- A still-placeholder staff is warned about on load.
  WEAPONS = { STAFF = "staff569815", SHIELD = "shield" },

  -- server-side queue contract
  ATK_ALIAS = "MAGIATK",          -- attacks
  UTIL_ALIAS = "MAGIUTIL",        -- reactive one-offs
  QUEUE = "FREESTAND",            -- Magi stands before casting (source used freestand)
  SEPARATOR = "/",                -- SETALIAS chain join (house convention)

  -- just-in-time fire lead time (seconds). nil -> getNetworkLatency().
  PREARM_INTERVAL = nil,

  -- only enforce the Magi class guard when gmcp reports a *different* known class
  classGuard = "Magi",

  DEBUG = false,
}

------------------------------------------
-- Resonance -- the self-Magi's OWN elemental buildup (air/fire/earth/water at 0-3),
-- parsed from gmcp.Char.Vitals.charstats (entries like "Rfire: Major"). Read directly
-- by every selector. This is the one piece the prior port sourced correctly.
------------------------------------------
magi.resonance = magi.resonance or { earth = 0, water = 0, air = 0, fire = 0 }

local RESO_LEVEL = { major = 3, moderate = 2, minor = 1 }
local RESO_ELEMENT = { air = true, fire = true, earth = true, water = true }

function magi.refreshResonance()
  local cs = gmcp and gmcp.Char and gmcp.Char.Vitals and gmcp.Char.Vitals.charstats
  if type(cs) ~= "table" then return end
  -- Each charstat is a "Key: Value" string; resonance entries contain the token
  -- r<element> (e.g. "Rfire: Major"). Match it as a substring (as the Levi source did)
  -- so a prefix on the entry doesn't break the parse, then read the level after the ":".
  for _, entry in ipairs(cs) do
    local low = tostring(entry):lower()
    for elem in pairs(RESO_ELEMENT) do
      if low:find("r" .. elem, 1, true) then
        magi.resonance[elem] = RESO_LEVEL[low:match(":%s*(%a+)") or ""] or 0
      end
    end
  end
end
-- convenience global for an optional gmcp.Char.Vitals event hookup (see MUDLET_SETUP.md)
get_resonance = magi.refreshResonance

------------------------------------------
-- STATE -- the offense mode, the few latches that are genuinely OURS (AK can't see them),
-- and the just-in-time firing latches. The Magi cast-states AK DOES track (burns/aflame,
-- conflagrate, scalded, calcifiedtorso, calcifiedhead, frozen, hypothermia) are read live
-- from affstrack -- see the accessors below -- not tracked here.
------------------------------------------
magi.state = magi.state or
{
  mode = "fire",            -- "fire" (default) | "water" | "lock" | "salve" | "group"

  -- our own ability state, which no opponent tracker carries:
  shalestorm = false,       -- our shalestorm channel is active on the target
  scintillaSpark = false,   -- our scintilla over-cast cooldown is pending
  scintillaTimer = nil,

  -- firing latches (arm + JIT timer)
  next_bal_armed = false,
  next_bal_timer = nil,
  next_bal_deadline = nil,  -- epoch the pending timer fires (keep the longer one)
}

-- Magi-APPLIED opponent afflictions (name -> true). A fallback latch for affs our own
-- spells inflict via class-specific game lines AK's generic affstrack may not parse
-- (waterbond/blistered for lock, clumsiness from bombard, slickness/prone from mudslide,
-- the fulminate chain, resonance affs). Fed by magi.track.*; OR'd with affstrack on read;
-- cleared by magi.track.curedAff and wiped on target change (magi.reset).
magi.affs = magi.affs or {}

------------------------------------------
-- Status / debug sink
------------------------------------------
local function notify(msg)
  if boxEcho and type(boxEcho.send) == "function" then
    boxEcho.send(msg)
  elseif cecho then
    cecho("\n<dark_orchid>[<cornflower_blue>magi<dark_orchid>]:<reset> " .. msg)
  else
    print("[magi] " .. msg)
  end
end

local function debug_echo(msg)
  if magi.CONFIG.DEBUG then notify("<dim_grey>" .. msg) end
end

------------------------------------------
-- Opponent-state predicates (affstrack / ak / lb -- all nil-safe, read LIVE)
------------------------------------------

-- affstrack confidence 0-100, OR'd with our magi-applied latch (treated as 100)
local function score(aff)
  local s = (affstrack and affstrack.score and affstrack.score[aff]) or 0
  if magi.affs[aff] then s = math.max(s, 100) end
  return s
end
-- 0.0-1.0 probability (mirrors getAffProbabilityV3)
local function prob(aff)
  return score(aff) / 100
end
-- boolean presence (mirrors haveAff)
local function has_aff(aff)
  return score(aff) >= magi.CONFIG.AFF_THRESHOLD
end

-- target shield / rebounding via AK
local function target_shielded()
  if ak and ak.defs and ak.defs.shield then return true end
  return has_aff("shield")
end
local function has_block()
  if ak and ak.defs and (ak.defs.shield or ak.defs.rebounding) then return true end
  return has_aff("shield") or has_aff("rebounding")
end

-- limb damage 0-200 (spaced keys: "left leg","right arm","head","torso")
local function limb_damage(limb)
  return (lb and lb[target] and lb[target].hits and lb[target].hits[limb]) or 0
end
local function is_limb_broken(limb)
  return limb_damage(limb) >= 100
end

-- target HP%: AK exposes current/max health (refreshed by the per-turn ASSESS).
-- Defaults to 100 (no kill) until AK has read it.
local function target_hp()
  if ak and type(ak.currenthealth) == "number"
     and type(ak.maxhealth) == "number" and ak.maxhealth > 0 then
    return math.floor(ak.currenthealth / ak.maxhealth * 100)
  end
  return 100
end

-- Magi cast-states read LIVE from AK affstrack (these were self-tracked before AK gained
-- them). `aflame` is 100 per burn stack; the rest are standard 0-100 confidence keys.
local function burns_count()        return math.min(math.floor(score("aflame") / 100), 5) end
local function is_conflagrated()    return has_aff("conflagrate") end
local function is_scalded()         return has_aff("scalded") end
local function is_calcified_torso() return has_aff("calcifiedtorso") end
local function is_calcified_skull() return has_aff("calcifiedhead") end
local function is_frozen()          return prob("frozen") >= 0.5 end
local function is_hypothermia()     return prob("hypothermia") >= 0.5 end

-- Count afflictions occupying the target's mending/salve balance. Magi is a salve-pressure
-- class: freeze is stronger when mending is busy. Broken limbs come from lb (AK canonical),
-- burns/calcify from AK affstrack via the accessors above.
local function count_mending_affs()
  local n = 0
  local limbs = { "left leg", "right leg", "left arm", "right arm" }
  for _, l in ipairs(limbs) do
    if is_limb_broken(l) then n = n + 1 end
  end
  n = n + burns_count()
  if is_calcified_torso() then n = n + 1 end
  if is_calcified_skull() then n = n + 1 end
  return n
end

------------------------------------------
-- Self / framework predicates
------------------------------------------

local function self_aff(name)
  local a = Legacy and Legacy.Curing and Legacy.Curing.Affs
  return (a and a[name]) or false
end

local function is_paused()
  return Legacy and Legacy.Settings and Legacy.Settings.Curing
    and Legacy.Settings.Curing.status == false or false
end

-- balance AND equilibrium up (gmcp values are STRINGS). Magi spends both.
local function have_eqbal()
  return gmcp and gmcp.Char and gmcp.Char.Vitals
    and gmcp.Char.Vitals.bal == "1" and gmcp.Char.Vitals.eq == "1" or false
end

local function my_class()
  return (gmcp and gmcp.Char and gmcp.Char.Status and gmcp.Char.Status.class) or ""
end

local function my_name()
  return (gmcp and gmcp.Char and gmcp.Char.Status and gmcp.Char.Status.name) or ""
end

------------------------------------------
-- Meteorite shield-strip selector (4 variants -- source selectMeteorite)
------------------------------------------
local function select_meteorite()
  local r = magi.resonance
  local fireWillBurn = (r.fire > 0) and (r.fire < 3)
  if fireWillBurn then
    return "cast meteorite at " .. target .. " flaming 4"
  elseif r.earth < 3 or is_calcified_torso() then
    return "cast meteorite at " .. target .. " pure 4"
  elseif r.water < 3 then
    return "cast meteorite at " .. target .. " frozen 4"
  else
    return "cast erode at " .. target .. " maintain"
  end
end

------------------------------------------
-- Burning sub-tree (source selectBurningSpell)
------------------------------------------
local function select_burning_spell()
  local r = magi.resonance
  local burning = burns_count()
  local fireWillBurn = (r.fire > 0) and (r.fire < 3)
  local frostbite = prob("frostbite")
  local weariness = prob("weariness")
  local nausea = prob("nausea")
  local caloric = not has_aff("nocaloric")
  local dehydrateWillFreeze = (nausea >= 0.5) and (weariness < 0.5)

  -- Conflagrate when ready (burns >= 2, fire >= 2)
  if burning >= 2 and r.fire >= 2 and not is_conflagrated() then
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
  -- Dehydrate if weariness present (stacks burns)
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

------------------------------------------
-- Lock sub-tree (source selectLockSpell)
------------------------------------------
local function select_lock_spell()
  local r = magi.resonance

  -- Horripilation for waterbond/blistered if not present
  if not has_aff("waterbond") and not has_aff("blistered")
     and not is_calcified_torso() and not has_aff("paralysis")
     and not has_aff("anorexia") then
    if r.fire == 2 then
      return "cast fulminate at " .. target
    else
      return "staffcast horripilation " .. target  -- NOTE: no "at" (source verbatim)
    end
  end
  -- Scalded path for calcify
  if not is_scalded() then
    return "cast magma at " .. target
  end
  -- Scintilla for calcify at earth major
  if r.earth == 3 and not is_calcified_torso() then
    return "staffcast scintilla at " .. target
  end
  -- Emanation earth at cap (if calcified)
  if r.earth == 3 and is_calcified_torso() then
    return "cast emanation at " .. target .. " earth"
  end
  -- Build earth
  if r.earth < 2 then
    if not has_aff("clumsiness") then
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

------------------------------------------
-- Salve sub-tree (source selectSalveSpell)
------------------------------------------
local function select_salve_spell()
  local r = magi.resonance

  -- Emanation earth at cap (salve-curable: broken limbs, cracked ribs)
  if r.earth == 3 then
    return "cast emanation at " .. target .. " earth"
  end
  -- Scalded for salve pressure
  if not is_scalded() then
    return "cast magma at " .. target
  end
  -- Scintilla for calcified torso (blocks restoration salve)
  if r.earth >= 2 and not is_calcified_torso() then
    return "staffcast scintilla at " .. target
  end
  -- Build earth resonance
  if r.earth < 3 then
    return "cast bombard at " .. target
  end
  -- Emanation fire at cap
  if r.fire == 3 then
    return "cast emanation at " .. target .. " fire"
  end
  -- Build fire for scalded pressure
  return "cast dehydrate at " .. target
end

------------------------------------------
-- Group sub-tree (source selectGroupSpell) -- stormhammer + damage emanations
------------------------------------------
local function select_group_spell()
  local r = magi.resonance
  local hp = target_hp()

  if hp <= magi.CONFIG.groupStormhammerThreshold then
    return magi.storm.command()
  end
  if r.fire == 3 then return "cast emanation at " .. target .. " fire" end
  if r.earth == 3 then return "cast emanation at " .. target .. " earth" end
  if not magi.state.shalestorm and r.earth >= 2 then
    return "cast shalestorm at " .. target
  end
  if not is_scalded() then return "cast magma at " .. target end
  return "cast dehydrate at " .. target
end

------------------------------------------
-- Fallback sub-tree (source selectFallback)
------------------------------------------
local function select_fallback()
  local r = magi.resonance

  if not magi.state.shalestorm then
    if r.earth >= 2 then
      return "cast shalestorm at " .. target
    else
      return "cast bombard at " .. target
    end
  end
  if r.fire == 3 then return "cast emanation at " .. target .. " fire" end
  if r.earth < 3 and r.fire < 3 then return "cast magma at " .. target end
  return "cast dehydrate at " .. target
end

------------------------------------------
-- Unified decision tree (source selectSpell). The shared spine (P1-P8) runs for ALL
-- modes; then lock/salve/group branch; fire & water share the P9-P13 + fallback tail
-- (water is a label -- its kill route is glaciate/hypothermia in the spine).
------------------------------------------
function magi.select_spell()
  local r = magi.resonance
  local st = magi.state
  local mode = st.mode
  local hp = target_hp()

  local fireWillBurn = (r.fire > 0) and (r.fire < 3)
  local freso = (r.water >= 2) and (r.air >= 2)   -- freeze resonance threshold
  local asthma = prob("asthma")
  local scalded = is_scalded()
  local burning = burns_count()
  local caloric = not has_aff("nocaloric")
  local frostbite = prob("frostbite")
  local shivering = prob("shivering")
  local weariness = prob("weariness")
  local nausea = prob("nausea")
  local dehydrateWillFreeze = (nausea >= 0.5) and (weariness < 0.5)

  local emearth = (not is_calcified_torso()) and (r.earth == 3)
    and (frostbite >= 0.5 or burning > 1 or shivering >= 0.5 or not caloric)

  --=== P1: DESTROY (conflagrated + low HP) ===--
  if is_conflagrated() and hp < magi.CONFIG.destroyThreshold then
    return "cast destroy at " .. target
  end

  --=== P2: SHIELD STRIP (meteorite variants) ===--
  if target_shielded() then
    return select_meteorite()
  end

  --=== P3: GLACIATE (hypothermia + dual resonance) ===--
  if is_hypothermia() and freso then
    return "cast glaciate at " .. target
  end

  --=== P4: STORMHAMMER (low HP kill) ===--
  if hp <= magi.CONFIG.stormhammerThreshold then
    return magi.storm.command()
  end

  --=== P5: SHALESTORM+SCINTILLA (free calcify while shalestorm active) ===--
  if st.shalestorm and not is_calcified_torso() and not st.scintillaSpark
     and r.earth >= 2
     and burning < 5
     and not (burning >= 2 and r.fire >= 2) then
    return "staffcast scintilla at " .. target
  end

  --=== P6: EMANATION EARTH (earth capped + conditions) ===--
  if emearth then
    return "cast emanation at " .. target .. " earth"
  end

  --=== P7: HYPOTHERMIA setup (frozen + dual resonance) ===--
  if is_frozen() and not is_hypothermia() and freso then
    return "cast hypothermia at " .. target
  end

  --=== P8: MUDSLIDE (asthma + water==2) ===--
  if asthma >= 0.5 and r.water == 2 then
    return "cast mudslide at " .. target
  end

  --=== MODE-SPECIFIC BRANCHES ===--
  if mode == "lock" then return select_lock_spell() end
  if mode == "salve" then return select_salve_spell() end
  if mode == "group" then return select_group_spell() end

  --=== P9: MAGMA (not scalded) ===--
  if not scalded then
    return "cast magma at " .. target
  end

  --=== P10: FREEZE (shivering + broken limb) ===--
  if shivering >= 0.5 and count_mending_affs() >= 1 then
    return "cast freeze at " .. target
  end

  --=== P11: CALCIFIED PATH ===--
  if is_calcified_torso() and (frostbite >= 0.5 or not caloric) then
    if dehydrateWillFreeze and fireWillBurn then
      return "cast dehydrate at " .. target
    else
      return "cast freeze at " .. target
    end
  end

  --=== P12: BURNING PATH (burns management) ===--
  if burning > 0 then
    return select_burning_spell()
  end

  --=== P13: SHALESTORM (earth >= 2, not active) ===--
  if not st.shalestorm and r.earth >= 2 then
    return "cast shalestorm at " .. target
  end

  --=== FALLBACK ===--
  return select_fallback()
end

------------------------------------------
-- Stormhammer multi-target selector (source 005_Stormhammer_Targeting)
------------------------------------------
magi.storm = magi.storm or {}
magi.storm.mode = magi.storm.mode or "city"   -- "city" | "all" | "priority"
magi.storm.targets = magi.storm.targets or {}
magi.storm.enemies = magi.storm.enemies or {} -- hand-populated enemy set (name -> true), optional

-- Override point: return true if `name` is a hostile you want stormhammered. Default:
-- the current target, plus any name in magi.storm.enemies. Wire to your own enemy list
-- (or populate magi.storm.enemies) to get real 3-target sweeps.
function magi.storm.is_enemy(name)
  if name == target then return true end
  return magi.storm.enemies[name] == true
end

-- Optional citizenship hook (NDB-style). Return a city string or nil. Default nil ->
-- "city" mode degrades to "all".
function magi.storm.citizenship(_name)
  return nil
end

function magi.storm.setMode(m)
  if m == "city" or m == "all" or m == "priority" then
    magi.storm.mode = m
    notify("Stormhammer mode: " .. m)
  else
    notify("Invalid stormhammer mode: " .. tostring(m) .. " (city/all/priority)")
  end
end

-- Players in the room (gmcp.Room.Players: list of {name=..}). "the soul of " stripped.
local function room_players()
  local out = {}
  if gmcp and gmcp.Room and gmcp.Room.Players and type(gmcp.Room.Players) == "table" then
    for _, p in ipairs(gmcp.Room.Players) do
      local n = type(p) == "table" and p.name or p
      if type(n) == "string" then
        n = n:gsub("^the soul of ", "")
        out[#out + 1] = n
      end
    end
  end
  return out
end

local function storm_candidates()
  local mode = magi.storm.mode
  local me = my_name()
  local cands = {}

  if mode == "city" then
    local targetCity = magi.storm.citizenship(target)
    if not targetCity or targetCity == "" then
      mode = "all"   -- degrade: no citizenship info
    else
      for _, p in ipairs(room_players()) do
        if p ~= me and magi.storm.is_enemy(p)
           and magi.storm.citizenship(p) == targetCity then
          cands[#cands + 1] = p
        end
      end
      return cands
    end
  end

  if mode == "priority" and tprio and tprio.list then
    local inRoom = {}
    for _, p in ipairs(room_players()) do
      if p ~= me and magi.storm.is_enemy(p) then inRoom[p:lower()] = p end
    end
    for _, name in ipairs(tprio.list) do
      local key = tostring(name):lower()
      if inRoom[key] then cands[#cands + 1] = inRoom[key]; inRoom[key] = nil end
    end
    for _, p in pairs(inRoom) do cands[#cands + 1] = p end
    return cands
  end

  -- "all" (and priority without tprio)
  for _, p in ipairs(room_players()) do
    if p ~= me and magi.storm.is_enemy(p) then cands[#cands + 1] = p end
  end
  return cands
end

-- Pick up to 3 targets, primary forced to slot 1.
function magi.storm.selectTargets()
  local cands = storm_candidates()
  if target and target ~= "" then
    for i, name in ipairs(cands) do
      if name == target then
        if i ~= 1 then
          table.remove(cands, i)
          table.insert(cands, 1, target)
        end
        break
      end
    end
  end
  magi.storm.targets = {}
  for i = 1, math.min(3, #cands) do
    magi.storm.targets[i] = cands[i]
  end
  return magi.storm.targets
end

-- Build the stormhammer command (multi-target if available, else single-target safe).
function magi.storm.command()
  magi.storm.selectTargets()
  local t = magi.storm.targets
  if #t == 0 then
    return "cast stormhammer at " .. target
  end
  local cmd = "cast stormhammer at " .. t[1]
  if t[2] then cmd = cmd .. " and " .. t[2] end
  if t[3] then cmd = cmd .. " and " .. t[3] end
  if #t > 1 then debug_echo("Stormhammer: " .. table.concat(t, ", ")) end
  return cmd
end

------------------------------------------
-- Command building
------------------------------------------

-- Build the attack chain: [arachnideye/webbomb prefix] / stand / wield <staff> shield /
-- <spell> / assess <target>. (assess at the tail refreshes ak.currenthealth for the HP gates.)
local function build_attack(spell)
  if not spell then return nil end
  local cmds = {}
  if magi.CONFIG.useArachnideye and not has_aff("prone") then
    cmds[#cmds + 1] = "arachnideye trample " .. target
  elseif magi.CONFIG.useWebbomb and not has_aff("entangled") then
    cmds[#cmds + 1] = "webbomb " .. target
  end
  cmds[#cmds + 1] = "stand"
  cmds[#cmds + 1] = "wield " .. magi.CONFIG.WEAPONS.STAFF .. " " .. magi.CONFIG.WEAPONS.SHIELD
  cmds[#cmds + 1] = spell
  cmds[#cmds + 1] = "assess " .. target
  return cmds
end

-- Legacy queue contract: write the chain into a server-side alias, then atomically
-- replace the named queue.
local function send_commands(cmd_table)
  local sep = magi.CONFIG.SEPARATOR
  local s = table.concat(cmd_table, sep):gsub("%" .. sep .. "+", sep)
  send(string.format("SETALIAS %s %s", magi.CONFIG.ATK_ALIAS, s))
  send(string.format("QUEUE ADDCLEARFULL %s %s", magi.CONFIG.QUEUE, magi.CONFIG.ATK_ALIAS))
end

-- Reactive one-offs go on a separate UTIL alias (a deliberate "do this NOW" press).
local function queue_now(cmds)
  local sep = magi.CONFIG.SEPARATOR
  local s = table.concat(cmds, sep):gsub("%" .. sep .. "+", sep)
  send(string.format("SETALIAS %s %s", magi.CONFIG.UTIL_ALIAS, s))
  send(string.format("QUEUE ADDCLEARFULL %s %s", magi.CONFIG.QUEUE, magi.CONFIG.UTIL_ALIAS))
end

------------------------------------------
-- Dispatch
------------------------------------------
function magi.dispatch()
  if type(target) ~= "string" or target == "" then
    notify("No target set")
    return
  end
  if self_aff("aeon") then return end       -- one action per long balance
  if is_paused() then return end
  local c = my_class()
  if magi.CONFIG.classGuard and c ~= "" and c ~= magi.CONFIG.classGuard then return end
  -- NO eq/bal gate here: the JIT timer fires us ~latency before balance returns and the
  -- FREE(STAND) queue holds the chain server-side until it does.

  magi.refreshResonance()

  local spell = magi.select_spell()
  local cmds = build_attack(spell)
  if not cmds then return end
  send_commands(cmds)

  if magi.CONFIG.DEBUG then notify(magi.state.mode .. ": " .. tostring(spell)) end
end

------------------------------------------
-- Firing model -- arm + just-in-time resource-used timer (dual-resource: a Magi combo
-- spends balance AND equilibrium, so wire on_balance to BOTH used-lines; we keep the
-- timer for whichever resource returns LAST).
------------------------------------------
function magi.arm(mode)
  if mode then magi.setMode(mode) end
  if have_eqbal() then
    magi.state.next_bal_armed = false
    magi.dispatch()
    return
  end
  magi.state.next_bal_armed = true
  notify("ARMED")
end

function magi.on_balance(interval)
  interval = tonumber(interval)
  if not interval then return end
  local lead = magi.CONFIG.PREARM_INTERVAL
    or (getNetworkLatency and getNetworkLatency()) or 0.1
  local wait = math.max(0, interval - lead)
  local deadline = ((getEpoch and getEpoch()) or 0) + wait
  -- a pending timer that fires no earlier than this already covers us -> ignore
  if magi.state.next_bal_timer and deadline <= (magi.state.next_bal_deadline or 0) then
    return
  end
  if magi.state.next_bal_timer then killTimer(magi.state.next_bal_timer) end
  magi.state.next_bal_deadline = deadline
  magi.state.next_bal_timer = tempTimer(wait, function()
    magi.state.next_bal_timer = nil
    magi.state.next_bal_deadline = nil
    if magi.state.next_bal_armed then
      magi.state.next_bal_armed = false
      magi.dispatch()
    end
  end)
end
magi.on_eq = magi.on_balance   -- wire both Balance- and Equilibrium-used lines here

------------------------------------------
-- Tracking handlers (magi.track.*) -- wire thin Mudlet triggers to these. AK affstrack now
-- supplies the Magi cast-states (aflame/conflagrate/scalded/calcify/frozen/hypothermia), so
-- only OUR-OWN state (scintilla cooldown, shalestorm channel) and an OPTIONAL applied-aff
-- fallback live here. Every handler that takes `tgt` no-ops unless tgt == target.
------------------------------------------
magi.track = magi.track or {}
local T = magi.track

-- OUR-OWN-STATE handlers (AK has no visibility into these): the scintilla over-cast
-- cooldown and the shalestorm channel.

-- "You sense a combustive spark take hold of <t>." -> scintilla spark + window.
function T.scintillaSpark(tgt)
  if tgt ~= target then return end
  magi.state.scintillaSpark = true
  if magi.state.scintillaTimer then killTimer(magi.state.scintillaTimer) end
  magi.state.scintillaTimer = tempTimer(magi.CONFIG.scintillaDuration, function()
    magi.state.scintillaSpark = false
    magi.state.scintillaTimer = nil
  end)
  debug_echo("scintilla spark (" .. magi.CONFIG.scintillaDuration .. "s)")
end

-- "Flames ignite all over the body of <t>..." -> clear the spark. (The burn it adds shows
-- up in AK's aflame, so we don't count it here.)
function T.scintillaIgnite(tgt)
  if tgt ~= target then return end
  magi.state.scintillaSpark = false
  if magi.state.scintillaTimer then
    killTimer(magi.state.scintillaTimer)
    magi.state.scintillaTimer = nil
  end
end

-- Shalestorm (023): start / end (our channel; anti-illusion: ignore end while earth
-- resonance is still up).
function T.shalestormStart(tgt)
  if tgt ~= target then return end
  magi.state.shalestorm = true
  debug_echo("shalestorm active")
end
function T.shalestormEnd(tgt)
  if magi.resonance and magi.resonance.earth > 0 then
    debug_echo("shalestorm-end ignored (earth resonance still up)")
    return
  end
  if tgt ~= target then return end
  magi.state.shalestorm = false
  debug_echo("shalestorm ended")
end

----------------------------------------------------------------
-- APPLIED-AFFLICTION FALLBACK latches (magi.affs). For affs Magi inflicts via class-
-- specific cast lines that AK's affstrack may not parse. OR'd with affstrack on read,
-- cleared by curedAff / target change. OPTIONAL -- wire only the ones AK misses. (Pending
-- confirmation of which of these AK tracks natively; drop the redundant ones once known.)
----------------------------------------------------------------

-- Fulminate mental chain: fulminated -> epilepsy -> paralysis (the burn lands in AK's aflame).
function T.fulminate(tgt)
  if tgt and tgt ~= target then return end
  if has_aff("epilepsy") and has_aff("fulminated") and not has_aff("paralysis") then
    magi.affs.paralysis = true
  elseif not has_aff("epilepsy") and has_aff("fulminated") then
    magi.affs.epilepsy = true
  else
    magi.affs.fulminated = true
  end
end

-- Bombard -> clumsiness ; Mudslide -> slickness + prone.
function T.bombard(tgt)
  if tgt and tgt ~= target then return end
  magi.affs.clumsiness = true
end
function T.mudslide(tgt)
  if tgt and tgt ~= target then return end
  magi.affs.slickness = true
  magi.affs.prone = true
end

-- Fire-resonance major: blistered first ("...command <t> to burn from within.") -> 15s latch.
function T.resFireBlistered(tgt)
  if tgt and tgt ~= target then return end
  magi.affs.blistered = true
  tempTimer(magi.CONFIG.blisteredDuration, function() magi.affs.blistered = false end)
end

-- Freeze-chain intermediates ("You rip the heat from <t>"): AK owns `frozen`/`hypothermia`,
-- but the nocaloric->shivering buildup it may not -- latch those so the caloric/shiver gates
-- and the P10 freeze-pressure cast work. (Drop once AK tracks nocaloric/shivering.)
function T.freezeRip(tgt)
  if tgt and tgt ~= target then return end
  if not has_aff("shivering") and has_aff("nocaloric") then
    magi.affs.weariness = true; magi.affs.shivering = true; magi.affs.nausea = true
  elseif not has_aff("nocaloric") then
    magi.affs.weariness = true; magi.affs.nocaloric = true; magi.affs.nausea = true
  end
end

-- Generic applied-affliction latch + cure (resonance affs etc.). Optional.
function T.resAff(name, tgt)
  if tgt and tgt ~= target then return end
  if name and name ~= "" then magi.affs[name] = true end
end
function T.curedAff(name, tgt)
  if tgt and tgt ~= target then return end
  if name then magi.affs[name] = nil end
end

------------------------------------------
-- Lifecycle
------------------------------------------
function magi.setMode(m)
  local valid = { fire = true, water = true, lock = true, salve = true, group = true }
  if valid[m] then
    if magi.state.mode ~= m then notify("Mode: " .. m) end
    magi.state.mode = m
  else
    notify("Invalid mode: " .. tostring(m) .. " (fire/water/lock/salve/group)")
  end
end

-- Reset our own per-target state (call on target change / death) and firing latches.
-- The AK-tracked cast-states (aflame/conflagrate/scalded/calcify/frozen/hypothermia) reset
-- themselves with the target via affstrack -- nothing to clear here.
function magi.reset()
  local st = magi.state
  st.shalestorm = false
  st.scintillaSpark = false
  if st.scintillaTimer then killTimer(st.scintillaTimer); st.scintillaTimer = nil end
  if st.next_bal_timer then killTimer(st.next_bal_timer); st.next_bal_timer = nil end
  st.next_bal_armed = false
  st.next_bal_deadline = nil
  magi.affs = {}
  magi.storm.targets = {}
  notify("Reset.")
end

------------------------------------------
-- Status
------------------------------------------
local function vwidth(s)
  s = s:gsub("<[^>]+>", "")
  local w = 0
  for i = 1, #s do
    local b = s:byte(i)
    if b < 0x80 or b >= 0xC0 then w = w + 1 end
  end
  return w
end

local STATUS_W = 42

local function box_echo(line)
  if cecho then cecho("\n" .. line) else print((line:gsub("<[^>]+>", ""))) end
end
local function box_row(content)
  local pad = STATUS_W - vwidth(content)
  if pad < 0 then pad = 0 end
  return "<dim_grey>│<reset> " .. content .. string.rep(" ", pad) .. " <dim_grey>│<reset>"
end
local function box_title(text)
  local span, t = STATUS_W + 2, " " .. text .. " "
  local left = math.floor((span - vwidth(t)) / 2)
  return "<dim_grey>╭" .. string.rep("─", left) .. "<cornflower_blue>" .. t
    .. "<dim_grey>" .. string.rep("─", span - vwidth(t) - left) .. "╮<reset>"
end
local function box_footer()
  return "<dim_grey>╰" .. string.rep("─", STATUS_W + 2) .. "╯<reset>"
end
local function onoff(b, on, off)
  return b and ("<green>" .. (on or "YES")) or ("<dim_grey>" .. (off or "no"))
end

function magi.status()
  magi.refreshResonance()
  local st = magi.state
  local r = magi.resonance
  local tname = (type(target) == "string" and target ~= "") and target or "—"

  box_echo(box_title("MAGI · " .. st.mode:upper()))
  box_echo(box_row("<dim_grey>Target<reset>     <white>" .. tname .. "<reset>   <dim_grey>HP<reset> <white>"
    .. target_hp() .. "%<reset>"))
  box_echo(box_row("<dim_grey>Resonance<reset>  <red>F:" .. r.fire .. "<reset> <dodger_blue>W:" .. r.water
    .. "<reset> <saddle_brown>E:" .. r.earth .. "<reset> <light_sky_blue>A:" .. r.air .. "<reset>"))
  box_echo(box_row("<dim_grey>Burns<reset>      <orange_red>" .. burns_count() .. "/5<reset>"
    .. (is_conflagrated() and "  <red>CONFLAGRATED<reset>" or "")))
  box_echo(box_row("<dim_grey>Scalded<reset>    " .. onoff(is_scalded()) .. "<reset>   <dim_grey>Shale<reset> "
    .. onoff(st.shalestorm, "ON", "off") .. "<reset>"))
  box_echo(box_row("<dim_grey>Calcify<reset>    " .. onoff(is_calcified_torso(), "TORSO", "-") .. "<reset> "
    .. onoff(is_calcified_skull(), "SKULL", "-") .. "<reset>"))
  box_echo(box_row("<dim_grey>Freeze<reset>     <dim_grey>frz<reset> " .. onoff(is_frozen()) .. "<reset>  <dim_grey>hypo<reset> "
    .. onoff(is_hypothermia()) .. "<reset>"))
  box_echo(box_footer())
end

------------------------------------------
-- Top-level alias wrappers (typeable from Mudlet's input line)
------------------------------------------
function mfire()  magi.arm("fire")  end
function mwater() magi.arm("water") end
function mlock()  magi.arm("lock")  end
function msalve() magi.arm("salve") end
function mgroup() magi.arm("group") end
function magiarm() magi.arm() end
function magistatus() magi.status() end
function magireset() magi.reset() end

if cecho then cecho("\n<dark_orchid>[magi]<reset> loaded — arm with <cornflower_blue>mfire/mwater/mlock/msalve/mgroup<reset>, status <cornflower_blue>magistatus<reset>") end
