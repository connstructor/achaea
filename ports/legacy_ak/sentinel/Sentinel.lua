------------------------------------------
-- Sentinel.lua — Legacy / AK port (Skirmishing offense)
------------------------------------------
-- Sentinel combat module by Tannivh and Kiryn.
--
-- One stateless dispatch, two selectable killpaths. Every dispatch rebuilds the command
-- set from CURRENT target state (limb damage + afflictions); nothing is latched. The only
-- "memory" is sentinel.state.finisher -- a plain preference set by the arm aliases (zz/xx)
-- and READ (never written) by the engine.
--
--   * skullbash (default, zz): prep both legs + the head, then break leg/leg/head and
--     SKULLBASH to death while they're prone with the head broken. The leg breaks only
--     exist to put them down -- once the kill window (prone + broken head) is open, leg
--     state is ignored; only standing or a healed head closes it.
--   * wrench    (xx):          prep both legs, TRIP the first (breaking it + proning them),
--     axe the second, then IMPALE while prone and WRENCH once impaled.
--
-- Both killpaths prep + break from one shared engine. A free ENRAGE (shield-strip / aff)
-- and a MORPH-to-default precommand ride on every dispatch.
--
-- AFFLICTION PLAN: a simple priority. Each hit lands two affs -- one from the attack (ATK_PRIO)
-- and one from the venom (VENOM_PRIO) -- always the highest-priority aff they still lack, with the
-- attack's aff excluded from the venom pick so we never double-apply. Priority is haemophilia,
-- then the impatience / focus affs, then the asthma / kelp affs. We DON'T chase anorexia and
-- slickness in prep -- they're sealed for free on the breaks (see below), so they sit at the
-- bottom of VENOM_PRIO as a fallback only. When a whole list is up, select_aff reinforces the
-- least-certain aff.
--
-- BREAK SEALS (the one special-case): a break hit seals the lock when it can, else rides
-- VENOM_PRIO.
--   * the TRIP break          -> SLIKE (anorexia) while they still lack anorexia, else priority.
--   * the second-leg axe break -> GECKO (slickness) while they still lack slickness, else priority.
--   * the head break, and every prep hit -> priority venom (VENOM_PRIO).
--
-- WHY THIS IS STATELESS: both killpaths prep + break legs from one shared engine, then
-- diverge -- skullbash also breaks the head and SKULLBASHes; wrench stops at both legs,
-- impales, and wrenches. Every step is read from live target state (prone / impaled via
-- affstrack, limb damage via lb), so the engine never needs a self-continuing "mode" or
-- progress counter. The chosen killpath is the single bit that says which way to diverge,
-- and it's a user preference, not an engine latch.
------------------------------------------
-- Required globals (host frameworks -- Legacy curing + AK; not provided here)
------------------------------------------
-- Legacy: own curing/settings/morph + Legacy.Curing.Affs (self affs)
-- gmcp:   own vitals (Char.Vitals.bal/eq) and Char.Status.name
-- ak:     opponent vitals/defenses (defs.shield / defs.rebounding)
-- affstrack: opponent affliction tracker (score[aff] 0-100 confidence, .impale)
-- lb:     opponent limb damage (lb[target].hits[limb], 0-200)
-- target / targetparry: current target and the limb they're parrying
-- boxEcho: status display sink (notify falls back to cecho/print if absent)
------------------------------------------
-- Wire-up (create by hand in Mudlet -- this module self-registers nothing; see
-- MUDLET_SETUP.md in this folder):
--   * Alias  "^zz$"   ->  sentinel.arm_next_bal(false)         -- skullbash (default)
--   * Alias  "^xx$"   ->  sentinel.arm_next_bal(true)          -- wrench
--   * Regex trigger  "^Balance used: (\d+\.\d+)s\.$"
--                     ->  sentinel.on_balance(tonumber(matches[2]))
--   * (optional)  "^sentstatus$" -> sentstatus()  /  "^sentreset$" -> sentreset()
------------------------------------------
sentinel = sentinel or {}

-- One source of truth per priority: the affliction, the ability that lands it, and
-- (optionally) a confidence threshold to count it as already up.
sentinel.CONFIG =
{
  DEFAULT_AFF_THRESHOLD = 50,
  PARRY_AFF_THRESHOLD = 67,
  LOCK_PREP_THRESHOLD = 67,
  WEAPONS = { SPEAR = "spear452934", HANDAXE = "handaxe453711", SHIELD = "shield435542" },
  -- Limbs we prep and break, in order: left leg -> right leg -> head.
  LIMB_PRIO = { "left leg", "right leg", "head" },
  -- Attack-slot affs, highest priority first: bleeding (haemophilia), then the focus affs
  -- (impatience, epilepsy), then the kelp aff weariness. The atk slot also builds limb damage.
  ATK_PRIO =
  {
    { aff = "haemophilia", atk = "LACERATE" },
    { aff = "impatience",  atk = "DOUBLESTRIKE" },
    { aff = "epilepsy",    atk = "DOUBLESTRIKE" },
    { aff = "weariness",   atk = "GOUGE" },
  },
  ENRAGE_PRIO =
  {
    { aff = "healthleech",    enrage = "FOX" },
    { aff = "sensitivity",    enrage = "RAVEN" },
    { aff = "addiction",      enrage = "BADGER" },
    { aff = "nausea",         enrage = "BADGER" },
    { aff = "hallucinations", enrage = "WOLF" },
  },
  -- Venom-slot affs, highest priority first: the focus affs (dizziness, stupidity), then the
  -- asthma/kelp stack (asthma is the foundation; clumsiness/weariness/sensitivity deepen it).
  -- anorexia/slickness sit low -- they're sealed on the trip/axe breaks (see header), not chased
  -- in prep -- and the off-plan tail is purely situational. Break hits override the top with
  -- SLIKE/GECKO while those seals are still open.
  VENOM_PRIO =
  {
    { aff = "stupidity",    venom = "ACONITE" },    -- focus
    { aff = "dizziness",    venom = "LARKSPUR" },   -- focus
    { aff = "asthma",       venom = "KALMIA" },     -- kelp seal (blocks smoking): the foundation
    { aff = "weariness",    venom = "VERNALIUS" },  -- kelp depth (also ATK GOUGE; deduped)
    { aff = "clumsiness",   venom = "XENTIO" },     -- kelp depth
    { aff = "sensitivity",  venom = "PREFARAR" },   -- kelp depth
    { aff = "anorexia",     venom = "SLIKE" },      -- sealed by the TRIP break; low prep fallback
    { aff = "slickness",    venom = "GECKO" },      -- sealed by the axe break; low prep fallback
    { aff = "paralysis",    venom = "CURARE" },     -- final lock aff
    -- Off-plan / situational tail.
    { aff = "recklessness", venom = "EURYPTERIA" },
    { aff = "darkshade",    venom = "DARKSHADE" },
    { aff = "voyria",       venom = "VOYRIA" },
    { aff = "nausea",       venom = "EUPHORBIA" },
    { aff = "asleep",       venom = "DELPHINIUM" },
  },
  -- How much each attack adds to a limb (% of break); used by is_limb_prepped.
  LIMB_DAMAGE =
  {
    THRUST = 21.0,
    LACERATE = 14.7,
    GOUGE = 14.7,
    DOUBLESTRIKE = 14.7,
    RIVESTRIKE = 14.7,
    TRIP = 14.7,
    THROW = 14.7,
  },
  -- Default spear-combat morph (kept in form via a free MORPH precommand).
  DEFAULT_MORPH = "Jaguar",
  -- Echo debounce window (seconds) for the debug echo.
  ECHO_DEBOUNCE = 0.3,
  -- Lag reduction: on_balance arms a timer for (interval - PREARM_INTERVAL); the arm alias
  -- sets next_bal_armed so it actually fires. nil uses getNetworkLatency().
  PREARM_INTERVAL = nil,
}

-- Minimal runtime state. finisher is a user preference (set ONLY by arm_next_bal); the rest
-- is lag-reduction bookkeeping and the echo-debounce stamp. No engine-written route latch
-- lives here -- e.g. the wrench "both legs have been broken" milestone is INFERRED from limb
-- state, never stored (see both_legs_were_broken).
sentinel.state =
{
  finisher = "skullbash",
  next_bal_timer = nil,
  next_bal_armed = false,
  last_echo_at = nil,
}

local CONFIG = sentinel.CONFIG
local SPEAR = CONFIG.WEAPONS.SPEAR
local HANDAXE = CONFIG.WEAPONS.HANDAXE
local SHIELD = CONFIG.WEAPONS.SHIELD

------------------------------------------
-- Framework helpers
------------------------------------------

local function _env_check()
  local checks =
  {
    { Legacy ~= nil,    "Legacy system not found." },
    { ak ~= nil,        "Opponent state (ak) not found." },
    { affstrack ~= nil, "Affliction tracker (affstrack) not found." },
    { lb ~= nil,        "Limb damage data (lb) not found." },
    { target ~= nil,    "No target defined." },
    { gmcp ~= nil,      "GMCP not found." },
  }
  local errors = {}
  for _, c in ipairs(checks) do
    if not c[1] then
      errors[#errors + 1] = c[2]
    end
  end
  if #errors > 0 then
    error("Environment check failed:\n  " .. table.concat(errors, "\n  "), 0)
  end
end

-- Status sink: boxEcho when present (matches the sibling ports), else cecho/print.
local function notify(msg)
  if boxEcho and type(boxEcho.send) == "function" then
    boxEcho.send(tostring(msg))
  elseif type(cecho) == "function" then
    cecho("\n<cyan>[Sentinel] " .. tostring(msg) .. "<reset>")
  else
    print("[Sentinel] " .. tostring(msg))
  end
end

local function contains(list, value)
  for _, v in ipairs(list) do
    if v == value then
      return true
    end
  end
  return false
end

-- Debounced debug echo (at most once per CONFIG.ECHO_DEBOUNCE seconds).
local function should_echo()
  local now = getEpoch()
  local last = sentinel.state.last_echo_at
  if not last or (now - last) > CONFIG.ECHO_DEBOUNCE then
    sentinel.state.last_echo_at = now
    return true
  end
  return false
end

-- Self affliction (drives the aeon guard).
local function self_aff(name)
  local a = Legacy and Legacy.Curing and Legacy.Curing.Affs
  return a and a[name] or false
end

------------------------------------------
-- Opponent-state predicates
------------------------------------------

local function score(aff)
  return affstrack and affstrack.score and affstrack.score[aff] or 0
end

local function has_aff(aff, threshold)
  return score(aff) >= (threshold or CONFIG.DEFAULT_AFF_THRESHOLD)
end

local function is_prone()
  return score("prone") >= 80
end

local function is_impaled()
  return affstrack and affstrack.impale or false
end

local function have_eqbal()
  return
      gmcp and
      gmcp.Char and
      gmcp.Char.Vitals and
      gmcp.Char.Vitals.bal == "1" and
      gmcp.Char.Vitals.eq == "1" or
      false
end

local function shield_count()
  local n = 0
  if ak and ak.defs then
    if ak.defs.shield then
      n = n + 1
    end
    if ak.defs.rebounding then
      n = n + 1
    end
  end
  return n
end

------------------------------------------
-- Limb damage / targeting
------------------------------------------

local function limb_damage(limb)
  return lb and lb[target] and lb[target].hits and lb[target].hits[limb] or 0
end

local function attack_damage(attack)
  return CONFIG.LIMB_DAMAGE[attack] or 0
end

local function is_limb_broken(limb)
  return limb_damage(limb) >= 100
end

-- One more hit with this attack would break the limb (and it isn't already broken).
-- This is the "treat near-break as prepped" guard -- prevents an accidental break
-- during the prep phase.
local function is_limb_prepped(limb, attack)
  local dmg = attack_damage(attack)
  if dmg <= 0 then
    return false
  end
  return not is_limb_broken(limb) and limb_damage(limb) + dmg >= 100
end

-- Can we actually land on this limb: high haemophilia, they're not parrying it, or
-- they're prone.
local function is_parry_bypassed(limb)
  return
      has_aff("haemophilia", CONFIG.PARRY_AFF_THRESHOLD) or
      targetparry ~= (limb:gsub(" ", "")) or
      is_prone()
end

local function all_limbs_prepped(attack)
  for _, limb in ipairs(CONFIG.LIMB_PRIO) do
    if not is_limb_prepped(limb, attack) then
      return false
    end
  end
  return true
end

local function any_limb_broken()
  for _, limb in ipairs(CONFIG.LIMB_PRIO) do
    if is_limb_broken(limb) then
      return true
    end
  end
  return false
end

-- First limb in priority that still needs prepping and that we can reach.
local function select_limb(attack)
  for _, limb in ipairs(CONFIG.LIMB_PRIO) do
    if not is_limb_prepped(limb, attack) and is_parry_bypassed(limb) then
      return limb
    end
  end
  return nil
end

-- A leg a trip would break and that we can land on -- the prone setup for wrench's
-- impale and for the first leg break.
local function prepped_leg()
  for _, limb in ipairs(CONFIG.LIMB_PRIO) do
    if limb:match(" leg$") and is_limb_prepped(limb, "TRIP") and is_parry_bypassed(limb) then
      return limb
    end
  end
  return nil
end

------------------------------------------
-- Affliction selection
------------------------------------------
-- Returns the chosen prio entry (with its .atk/.enrage/.venom field). An entry with a
-- `requires` list is only selectable once those affs are up (>= LOCK_PREP_THRESHOLD); no
-- current entry uses it, but the mechanism stays for coupling future keystones.

local function requires_met(entry)
  if not entry.requires then
    return true
  end
  for _, req in ipairs(entry.requires) do
    if not has_aff(req, CONFIG.LOCK_PREP_THRESHOLD) then
      return false
    end
  end
  return true
end

local function select_aff(prio_list, exclude)
  exclude = exclude or {}
  -- First aff they don't already have, whose coupling prereqs are met.
  for _, entry in ipairs(prio_list) do
    if not has_aff(entry.aff, entry.threshold) and not contains(exclude, entry.aff) and requires_met(entry) then
      return entry
    end
  end
  -- Everything selectable is up: reinforce whichever we're least sure of.
  local min_entry, min_conf = nil, 100
  if affstrack and affstrack.score then
    for _, entry in ipairs(prio_list) do
      local conf = affstrack.score[entry.aff]
      if conf and conf < min_conf and not contains(exclude, entry.aff) and requires_met(entry) then
        min_entry, min_conf = entry, conf
      end
    end
  end
  return min_entry or prio_list[1]
end

-- The next lacked VENOM_PRIO aff's venom -- used by prep and the head break. Break hits override
-- this with SLIKE/GECKO while those seals are still open (see next_leg_break).
local function priority_venom(exclude)
  return select_aff(CONFIG.VENOM_PRIO, exclude).venom
end

------------------------------------------
-- Setup actions (free; need bal/eq but don't consume it)
------------------------------------------
-- Returns the enrage command and the aff it lands (to exclude downstream).

local function select_enrage()
  if shield_count() == 1 then
    return "ENRAGE LEMMING", nil
  end
  local entry = select_aff(CONFIG.ENRAGE_PRIO)
  if entry and entry.enrage then
    return "ENRAGE " .. entry.enrage, entry.aff
  end
  return nil, nil
end

-- Legacy[<character>].morph holds the form we're currently in
-- (e.g. Legacy.Tannivh.morph == "Jaguar").
local function current_morph()
  local name = gmcp and gmcp.Char and gmcp.Char.Status and gmcp.Char.Status.name
  return name and Legacy and Legacy[name] and Legacy[name].morph or nil
end

-- Stay in the default spear-combat form (free precommand; needs bal/eq but doesn't spend it).
local function select_morph()
  if current_morph() ~= CONFIG.DEFAULT_MORPH then
    return "MORPH " .. CONFIG.DEFAULT_MORPH:upper()
  end
  return nil
end

------------------------------------------
-- Command fragments
------------------------------------------

local function trip_attack(leg, venom)
  return { string.format("TRIP %s %s", leg:match("^(%a+) leg$"):upper(), venom) }
end

local function axe_attack(limb, venom)
  return
  {
    string.format("WIELD LEFT %s", HANDAXE),
    string.format("WIPE %s", HANDAXE),
    string.format("ENVENOM %s WITH %s", HANDAXE, venom),
    string.format("THROW %s AT %s %s", HANDAXE, target, limb),
  }
end

------------------------------------------
-- Break engine (shared by both killpaths)
------------------------------------------

local function both_legs_broken()
  for _, limb in ipairs(CONFIG.LIMB_PRIO) do
    if limb:match(" leg$") and not is_limb_broken(limb) then
      return false
    end
  end
  return true
end

local function any_leg_broken()
  for _, limb in ipairs(CONFIG.LIMB_PRIO) do
    if limb:match(" leg$") and is_limb_broken(limb) then
      return true
    end
  end
  return false
end

local function both_legs_prepped()
  for _, limb in ipairs(CONFIG.LIMB_PRIO) do
    if limb:match(" leg$") and not is_limb_prepped(limb, "TRIP") then
      return false
    end
  end
  return true
end

-- Break the next leg toward both-legs-broken-and-prone. Standing -> TRIP a prepped, unparried
-- leg (breaks it + drops them), sealing anorexia with SLIKE while they still lack it. Down ->
-- axe whichever leg still stands (prone bypasses parry), sealing slickness with GECKO while
-- they still lack it. Either seal falls back to the ladder venom once that aff is up. nil when
-- nothing is breakable right now -- the caller then falls back to the prep engine to rebuild.
local function next_leg_break(exclude)
  if not is_prone() then
    local leg = prepped_leg()
    if not leg then
      return nil
    end
    local venom = (not has_aff("anorexia")) and "SLIKE" or priority_venom(exclude)
    return trip_attack(leg, venom)
  end
  for _, limb in ipairs(CONFIG.LIMB_PRIO) do
    if limb:match(" leg$") and not is_limb_broken(limb) then
      if not is_limb_prepped(limb, "THROW") then
        return nil
      end
      local venom = (not has_aff("slickness")) and "GECKO" or priority_venom(exclude)
      return axe_attack(limb, venom)
    end
  end
  return nil
end

-- Trip a leg, axe the other, axe the head (ladder venom on the head). Returns the next break
-- command, or nil once both legs AND the head are broken (caller proceeds to its kill). nil
-- mid-break means nothing is breakable right now -> caller falls back to the prep engine.
local function break_legs_and_head(exclude)
  if not both_legs_broken() then
    return next_leg_break(exclude)
  end
  if not is_limb_broken("head") then
    return axe_attack("head", priority_venom(exclude))
  end
  return nil
end

------------------------------------------
-- Prep engine (shared; both killpaths prep identically, then diverge)
------------------------------------------
-- Build the next limb and stack affs/venoms. Breaking is the killpath's job.

local function select_prep_commands(exclude)
  -- Two shields up: strip them with RIVESTRIKE.
  local force_rivestrike = shield_count() == 2
  local venom_exclude = {}
  for _, aff in ipairs(exclude) do
    table.insert(venom_exclude, aff)
  end
  local atk_entry
  if not force_rivestrike then
    atk_entry = select_aff(CONFIG.ATK_PRIO, exclude)
    table.insert(venom_exclude, atk_entry.aff)
  end
  local venom = priority_venom(venom_exclude)
  local attack = force_rivestrike and "RIVESTRIKE" or atk_entry.atk
  local limb = select_limb(attack)
  if limb then
    return { string.format("%s %s %s", attack, limb, venom) }
  end
  return { string.format("%s %s", attack, venom) }
end

------------------------------------------
-- Killpath step-selectors (each returns a command list, or nil to fall through to the
-- shared prep engine). All read live state only; none write state.finisher.
------------------------------------------

-- skullbash: break leg/leg/head, then SKULLBASH while they're prone with the head broken. The
-- kill window is prone + broken head ONLY -- the leg breaks just put them down, so legs healing
-- mid-bash must never pull us back into the break engine. Only standing up or a healed head
-- closes the window (back to breaking/prepping).
local function skullbash_step(exclude)
  if is_limb_broken("head") and is_prone() then
    return { string.format("SKULLBASH %s", target) }
  end
  return break_legs_and_head(exclude)
end

-- "Both legs have BEEN broken" -- the wrench milestone -- inferred from current state, no
-- latch. True when both are broken now, OR exactly one is broken while the other isn't even
-- prepped. The requirement is "break both legs," not "keep both broken," so a leg that heals
-- after the second break must not regress us. We can read that from state alone because of the
-- break invariant: we never trip the first leg until BOTH are prepped, and we axe the second
-- the instant the first goes down -- so a broken leg sitting beside an un-prepped one can only
-- mean the other was broken too and has since healed past its prep. (Other still prepped =
-- mid-break.)
local function both_legs_were_broken()
  if both_legs_broken() then
    return true
  end
  if is_limb_broken("left leg") and not is_limb_prepped("right leg", "TRIP") then
    return true
  end
  if is_limb_broken("right leg") and not is_limb_prepped("left leg", "TRIP") then
    return true
  end
  return false
end

-- wrench setup: break BOTH legs (next_leg_break TRIPs the first -- breaking it and proning the
-- target -- then axes the second), then IMPALE. The break only STARTS once both legs are
-- prepped (or we're already mid-break), which is the invariant that lets both_legs_were_broken
-- read the milestone from state. nil during prep -> shared prep engine builds the legs. The
-- actual WRENCH fires from the universal "impaled" branch.
local function wrench_step(exclude)
  if both_legs_were_broken() then
    return { string.format("IMPALE %s", target) }
  end
  if any_leg_broken() or both_legs_prepped() then
    return next_leg_break(exclude)
  end
  return nil
end

------------------------------------------
-- Routing
------------------------------------------

local function select_commands(exclude)
  local finisher = sentinel.state.finisher or "skullbash"
  -- Impaled -> WRENCH (the wrench kill; skullbash never impales).
  if is_impaled() then
    return { string.format("WRENCH %s", target) }
  end
  if finisher == "wrench" then
    local w = wrench_step(exclude)
    if w then
      return w
    end
  else
    -- skullbash (default). Enter the committed break once all three limbs are prepped, and
    -- stay in it while any limb is broken. skullbash_step returns nil when the kill window
    -- (prone + broken head) is closed and nothing is breakable -> fall through to the prep
    -- engine to rebuild.
    if any_limb_broken() or (all_limbs_prepped("TRIP") and prepped_leg()) then
      local s = skullbash_step(exclude)
      if s then
        return s
      end
    end
  end
  -- Otherwise build the next limb / stack affs.
  return select_prep_commands(exclude)
end

------------------------------------------
-- Dispatch
------------------------------------------

local function send_commands(cmd_set)
  if #cmd_set == 0 then
    return
  end
  local cmd_string = table.concat(cmd_set, "/"):gsub("/+", "/")
  send("SETALIAS SENTATK " .. cmd_string)
  send("QUEUE ADDCLEARFULL FREE SENTATK")
end

function sentinel.dispatch()
  _env_check()
  if type(target) ~= "string" or target == "" then
    notify("no target set")
    return
  end
  -- Self-aeon: one action at a time on a long balance -- don't dispatch.
  if self_aff("aeon") then
    notify("aeon - skipping")
    return
  end
  -- Curing paused -> stand down.
  if Legacy and Legacy.Settings and Legacy.Settings.Curing and Legacy.Settings.Curing.status == false then
    return
  end

  local finisher = sentinel.state.finisher or "skullbash"

  local ok, err =
      xpcall(
        function()
          local out = {}
          -- Spear loadout for the spear attacks.
          table.insert(out, string.format("WIELD %s %s", SPEAR, SHIELD))
          table.insert(out, string.format("WIPE %s", SPEAR))
          table.insert(out, string.format("ORDER LOYALS KILL %s", target))

          -- Free precommands: opportunistic ENRAGE (shield-strip / aff) + stay in form. The
          -- enrage's aff is excluded from venom selection so we don't double-apply it.
          local enrage_cmd, enrage_aff = select_enrage()
          if enrage_cmd then
            table.insert(out, enrage_cmd)
          end
          local morph_cmd = select_morph()
          if morph_cmd then
            table.insert(out, morph_cmd)
          end
          local exclude = {}
          if enrage_aff then
            table.insert(exclude, enrage_aff)
          end
          for _, cmd in ipairs(select_commands(exclude)) do
            table.insert(out, cmd)
          end

          table.insert(out, "ASSESS")
          table.insert(out, "DISCERN")

          if sentinel.debug and should_echo() then
            -- Set sentinel.debug = true to see why a dispatch picked what it did.
            cecho(
              "\n<yellow>[Sentinel] finisher=" ..
              tostring(finisher) ..
              " prone=" ..
              tostring(is_prone()) ..
              " anyBroken=" ..
              tostring(any_limb_broken()) ..
              " allPrepped(TRIP)=" ..
              tostring(all_limbs_prepped("TRIP")) ..
              " impaled=" ..
              tostring(is_impaled())
            )
            cecho(
              "\n<yellow>[Sentinel] LL=" ..
              tostring(limb_damage("left leg")) ..
              " RL=" ..
              tostring(limb_damage("right leg")) ..
              " head=" ..
              tostring(limb_damage("head")) ..
              " parrying=" ..
              tostring(targetparry)
            )
            cecho("\n<yellow>[Sentinel] -> " .. table.concat(out, " / "))
          end

          send_commands(out)
        end,
        function(e)
          return debug.traceback(tostring(e), 2)
        end
      )
  if not ok then
    notify("dispatch failed: " .. tostring(err))
  end
end

------------------------------------------
-- Firing / lifecycle
------------------------------------------
-- On bal/eq we hit now; otherwise arm so the balance timer fires us as late as
-- possible (don't commit into rebounding, don't go full-auto).

-- Button handler -- call from the zz/xx aliases. finisher: "skullbash" (default) or "wrench".
-- Backward compatible: false/nil -> skullbash, true -> wrench. This is the ONLY write to
-- state.finisher.
function sentinel.arm_next_bal(finisher)
  if finisher == true then
    finisher = "wrench"
  elseif finisher == false or finisher == nil then
    finisher = "skullbash"
  end
  sentinel.state.finisher = finisher
  if have_eqbal() then
    sentinel.state.next_bal_armed = false
    sentinel.dispatch()
    return
  end
  sentinel.state.next_bal_armed = true
  notify(finisher == "skullbash" and "armed" or ("armed (" .. finisher .. ")"))
end

-- Balance-used trigger handler. Arms a tempTimer for (interval - latency * 2), so we
-- dispatch the instant balance returns (combo built from CURRENT state) without
-- going full-auto. If we weren't armed, the timer expires harmlessly.
function sentinel.on_balance(interval)
  if type(interval) ~= "number" then
    return
  end
  local prearm = CONFIG.PREARM_INTERVAL or (getNetworkLatency() * 2)
  sentinel.state.next_bal_timer =
      tempTimer(
        math.max(0, interval - prearm),
        function()
          if sentinel.state.next_bal_armed then
            sentinel.state.next_bal_armed = false
            sentinel.dispatch()
          end
        end
      )
end

function sentinel.reset()
  sentinel.state =
  {
    finisher = "skullbash",
    next_bal_timer = nil,
    next_bal_armed = false,
    last_echo_at = nil,
  }
  notify("reset")
end

------------------------------------------
-- Status display (read-only)
------------------------------------------

function sentinel.status()
  local function bar(pct, width)
    width = width or 15
    local filled = math.floor((math.min(pct, 100) / 100) * width)
    if filled < 0 then
      filled = 0
    end
    return string.rep("#", filled) .. string.rep("-", width - filled)
  end
  local function limb_state(limb)
    local dmg = limb_damage(limb)
    if dmg >= 100 then
      return "<green>BROKEN "
    end
    if is_limb_prepped(limb, "TRIP") then
      return "<yellow>PREPPED"
    end
    return "<red>       "
  end

  cecho("\n<yellow>+================================================+")
  cecho("\n<yellow>| <white>SENTINEL OFFENSE<yellow>")
  cecho("\n<yellow>+================================================+")
  cecho("\n<yellow>| <white>Finisher: <cyan>" .. tostring(sentinel.state.finisher))
  cecho("  <white>Target: <cyan>" .. tostring(target or "None"))
  cecho("  <white>Morph: <cyan>" .. tostring(current_morph() or "?"))
  cecho("\n<yellow>+------------------------------------------------+")
  for _, limb in ipairs(CONFIG.LIMB_PRIO) do
    local dmg = limb_damage(limb)
    cecho(
      "\n<yellow>|   <white>" ..
      string.format("%-9s", limb) ..
      " " .. limb_state(limb) .. string.format(" %5.1f%% ", dmg) .. "<reset>[<cyan>" .. bar(dmg) .. "<reset>]"
    )
  end
  cecho("\n<yellow>+------------------------------------------------+")
  cecho("\n<yellow>| <white>KILL ROUTES:")
  cecho(
    "\n<yellow>|   <white>SKULLBASH: " ..
    ((is_prone() and is_limb_broken("head")) and "<green>READY" or "<red>no")
  )
  cecho(
    "    <white>WRENCH: " ..
    (is_impaled() and "<green>IMPALED" or (both_legs_were_broken() and "<yellow>impale" or "<red>no"))
  )
  cecho("\n<yellow>+------------------------------------------------+")
  cecho("\n<yellow>| <white>Prone: " .. (is_prone() and "<green>YES" or "<red>no"))
  cecho("  <white>Parry: <cyan>" .. tostring(targetparry or "none"))
  cecho("  <white>Shields: <cyan>" .. shield_count())
  cecho("  <white>Armed: " .. (sentinel.state.next_bal_armed and "<green>YES" or "<grey>no"))
  cecho("\n<yellow>+================================================+\n")
end

------------------------------------------
-- Convenience wrappers (top-level for the Mudlet input line)
------------------------------------------

function sentstatus()
  sentinel.status()
end

function sentreset()
  sentinel.reset()
end
