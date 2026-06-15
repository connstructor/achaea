-- Runewarden Two-Handed Combat Engine for Achaea (Mudlet)
-- Decision engine that builds one batch per EQBAL window and submits it via
-- the server-side QUEUE system. See pseudocode.md for the design model.
runewarden = runewarden or {}
runewarden.twoh = runewarden.twoh or {}
local M = runewarden.twoh
-- =============================================================
-- Config (user-editable; preserved across reloads)
-- =============================================================
-- Weapon item names as they appear to WIELD
-- Static rune priority for EMPOWER PRIORITY SET (defensive re-emit each batch)
-- Affliction "treat as present" threshold: affstrack.score[aff] >= aff_threshold
-- Per-aff overrides win when present.
-- e.g., nausea = 60,
-- Target values that mean "no real target." Pressing arm/override/devastate
-- while target matches one of these is a no-op; the on_balance_used pre-fetch
-- is also skipped. Add/remove keys as needed.
-- Affliction priority for venom selection. Each entry: { aff = "...", venom = "..." }
-- Walked top-to-bottom; first entry whose affliction is not already present is used.
-- Limb stacking priority. Entries walked in order; per-entry tuning:
--   min  — keep prioritizing this limb until count >= min
--   max  — ignore this limb when count >= max
-- attack and parry are game-mechanic and shouldn't normally need to change.
--
-- Selection logic:
--   1. Filter out maxed (count >= max) and parry-blocked (no nausea bypass)
--   2. If any remaining are under-min (count < min) → pick by config order
--   3. Otherwise round-robin: fewest count first, config order as tiebreak
M.config =
  M.config or
  {
    bastard_sword = "bastard537498",
    warhammer = "warhammer542360",
    rune_priority = {"ISAZ", "SLEIZAK", "SOWULU"},
    aff_threshold = 50,
    aff_threshold_overrides = {},
    -- Latency-based arming: the dispatch is scheduled for (balance interval -
    -- prearm) so it lands the instant balance returns (the server-side QUEUE
    -- holds it). nil => getNetworkLatency() * 2.
    prearm_interval = nil,
    invalid_targets = {None = true, Dude = true},
    aff_priority =
      {
        {aff = "nausea", venom = "EUPHORBIA"},
        {aff = "darkshade", venom = "DARKSHADE"},
        {aff = "addiction", venom = "VARDRAX"},
        {aff = "paralysis", venom = "CURARE"},
        {aff = "clumsiness", venom = "XENTIO"},
        {aff = "anorexia", venom = "SLIKE"},
        {aff = "dizziness", venom = "LARKSPUR"},
        {aff = "stupidity", venom = "ACONITE"},
        {aff = "weariness", venom = "VERNALIUS"},
        {aff = "asthma", venom = "KALMIA"},
        {aff = "slickness", venom = "GECKO"},
        {aff = "sensitivity", venom = "PREFARAR"},
        {aff = "recklessness", venom = "EURYPTERIA"},
        {aff = "disloyalty", venom = "MONKSHOOD"},
        {aff = "voyria", venom = "VOYRIA"},
        {aff = "asleep", venom = "DELPHINIUM"},
        {aff = "scytherus", venom = "SCYTHERUS"},
        {aff = "shivering", venom = "NECHAMANDRA"},
      },
    limb_priority =
      {
        {loc = "tendons", min = 5, max = 7, attack = "HEW", parry = nil},
        {loc = "skull", min = 6, max = 7, attack = "OVERHAND", parry = "head"},
        {loc = "wrist", min = 1, max = 1, attack = "HEW", parry = nil},
        {loc = "ribs", min = 4, max = 7, attack = "UNDERHAND", parry = "torso"},
      },
  }
-- =============================================================
-- State (engine-managed; preserved across reloads)
-- =============================================================
-- "sword" | "warhammer"
-- "skull" | "wrist" | "tendons" | "ribs" | nil; one-shot
-- "LEFT" | "RIGHT" | nil; only meaningful for wrist/tendons
-- "ARMS" | "LEGS" | nil; one-shot manual DEVASTATE
-- os.time() of most recent batch fire; used to
-- gate on_balance_used so it doesn't spam outside combat
M.state =
  M.state or
  {
    armed = false,
    focus_mode = "precision",
    falcon_tracking = false,
    falcon_slaying = false,
    weapon_mode = "sword",
    override_loc = nil,
    override_side = nil,
    devastate_pending = nil,
    last_fire_time = 0,
  }
-- Note: overwhelm follow-up state lives in ak.didOverwhelm (framework-maintained).
-- =============================================================
-- State read + helpers
-- =============================================================
-- Both balance and equilibrium ready? GMCP reports balances as "1"/"0" strings.

local function on_eqbal()
  return gmcp.Char.Vitals.bal == "1" and gmcp.Char.Vitals.eq == "1"
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

-- Snapshot of all decision-relevant framework state at one moment.
-- Numeric framework values are tonumber()'d defensively — some arrive as strings
-- (e.g., GMCP "1"/"0"), and downstream math/comparisons will throw if mixed.

local function read_state()
  -- Fractures
  -- Afflictions: confidence table, accessed via aff_present()
  -- affstrack.impale holds the name of who's doing the impaling, or "Me"
  -- when it's us. We only care about our own impale chain.
  -- Target HP (updated by FALCON REPORT / ASSESS)
  -- Target defenses
  -- Parry limb: lowercase, no spaces (e.g., "leftleg", "head", or nil)
  -- Engagement (auto-clears on target switch, so truthy ⇒ engaged on current target)
  -- OVERWHELM → BRAIN follow-up flag
  -- Our state
  return
    {
      target = target,
      skull = tonumber(ak.twoh.skull) or 0,
      ribs = tonumber(ak.twoh.ribs) or 0,
      wrist = tonumber(ak.twoh.wrist) or 0,
      tendons = tonumber(ak.twoh.tendons) or 0,
      aff = affstrack.score,
      impaled = affstrack.impale == "Me",
      hp_current = tonumber(ak.currenthealth) or 0,
      hp_max = tonumber(ak.maxhealth) or 1,
      rebounding = ak.defs.rebounding and not ignoreShield,
      shield = ak.defs.shield and not ignoreShield,
      targetparry = targetparry,
      engaged = ak.engaged,
      did_overwhelm = ak.didOverwhelm == true,
      weapon_mode = M.state.weapon_mode,
    }
end

-- Treat affliction as present when confidence ≥ threshold (per-aff override wins)

local function aff_present(state, name)
  local th = M.config.aff_threshold_overrides[name] or M.config.aff_threshold
  return (tonumber(state.aff[name]) or 0) >= th
end

local function hp_pct(state)
  return state.hp_current / state.hp_max
end

local function nausea_bypass(state)
  return aff_present(state, "nausea")
end

-- Path B kill math: OVERWHELM+BRAIN damage ≈ 9% of target max HP per skull fracture

local function can_brain_kill(state)
  return state.skull * 0.09 * state.hp_max >= state.hp_current
end

-- =============================================================
-- Phase selection
-- =============================================================
-- follow-up BRAIN (OVERWHELM was last batch)
-- target impaled
-- target prone, not impaled
-- target ≤ 25% HP
-- new Path B commit
-- tendons ≥ 5
-- target has shield/rebounding
-- default
-- user triggered xx
-- user triggered cc
local PHASE =
  {
    PATH_B_BRAIN = "path_b_brain",
    PATH_A_DISEMBOWEL = "path_a_disembowel",
    PATH_A_IMPALE = "path_a_impale",
    PATH_C_BISECT = "path_c_bisect",
    PATH_B_OVERWHELM = "path_b_overwhelm",
    PATH_A_DEVASTATE = "path_a_devastate",
    CARVE = "carve",
    STACK = "stack",
    MANUAL_DEVASTATE_ARMS = "manual_devastate_arms",
    MANUAL_DEVASTATE_LEGS = "manual_devastate_legs",
  }

local function select_phase(state)
  -- 1. Continuation/execute phases that BYPASS shield+rebounding.
  --    Order:
  --      DISEMBOWEL — already committed to the impale chain, finish it
  --      BISECT     — kill priority, beats IMPALE (don't waste prone window
  --                   re-impaling when we can execute right now)
  --      IMPALE     — set up the prone chain
  if state.impaled then
    return PHASE.PATH_A_DISEMBOWEL
  end
  if hp_pct(state) <= 0.25 then
    return PHASE.PATH_C_BISECT
  end
  if (tonumber(state.aff.prone) or 0) >= 80 then
    return PHASE.PATH_A_IMPALE
  end
  -- 2. Defense break — everything below bounces/fails on shield/rebound.
  if state.rebounding or state.shield then
    return PHASE.CARVE
  end
  -- 3. BRAIN follow-up (would bounce off rebound, so handled after CARVE)
  if state.did_overwhelm then
    return PHASE.PATH_B_BRAIN
  end
  -- 4. New finisher commits
  if can_brain_kill(state) then
    return PHASE.PATH_B_OVERWHELM
  end
  if state.tendons >= 5 then
    return PHASE.PATH_A_DEVASTATE
  end
  -- 5. Stack
  return PHASE.STACK
end

-- =============================================================
-- Stacking phase: pick location + attack + limb
-- =============================================================

local function select_stack_attack(state)
  local nausea = nausea_bypass(state)
  local count_for =
    {skull = state.skull, wrist = state.wrist, tendons = state.tendons, ribs = state.ribs}
  -- Build viable list with under-min flag. Sorted to balance attacks:
  --   1. under-min entries first (preference for limbs that haven't reached their floor)
  --   2. within same under-min status, fewest count first (round-robin)
  --   3. config order as final tiebreak (so equal-count entries follow priority list)
  local viable = {}
  for order, entry in ipairs(M.config.limb_priority) do
    local count = count_for[entry.loc]
    if count >= entry.max then
      -- skip — at or above max
    elseif entry.parry and (not nausea) and state.targetparry == entry.parry then
      -- skip — parried and no nausea bypass
    else
      viable[#viable + 1] =
        {
          loc = entry.loc,
          count = count,
          attack = entry.attack,
          parry = entry.parry,
          order = order,
          under_min = count < entry.min,
        }
    end
  end
  table.sort(
    viable,
    function(a, b)
      if a.under_min ~= b.under_min then
        return a.under_min
      end
      -- under-min first
      if a.count ~= b.count then
        return a.count < b.count
      end
      -- fewest count first
      return a.order < b.order
      -- priority tiebreak
    end
  )
  if #viable == 0 then
    return nil
    -- caller emits no main attack (should be unreachable in practice)
  end
  local pick = viable[1]
  local out = {loc = pick.loc, attack = pick.attack, limb = nil}
  if pick.attack == "HEW" then
    local body = (pick.loc == "wrist") and "ARM" or "LEG"
    local side = (math.random() < 0.5) and "LEFT" or "RIGHT"
    -- Side-swap if matches parry (targetparry is concatenated lowercase: "leftleg" etc.)
    if state.targetparry == (side:lower() .. body:lower()) then
      side = (side == "LEFT") and "RIGHT" or "LEFT"
    end
    out.limb = side .. " " .. body
  end
  return out
end

-- Override pick: user has explicitly chosen a limb (and optionally a side).
-- HEW side-swaps if the chosen side matches parry (pooled fractures = same result).
-- M.override() does the parry/defense safety checks; this builder just constructs.

local function build_override_pick(state, loc, side)
  local entry
  for _, e in ipairs(M.config.limb_priority) do
    if e.loc == loc then
      entry = e
      break
    end
  end
  if not entry then
    echo("[2H] Override: unknown limb '" .. tostring(loc) .. "'\n")
    return nil
  end
  local out = {loc = entry.loc, attack = entry.attack, limb = nil}
  if entry.attack == "HEW" then
    local body = (entry.loc == "wrist") and "ARM" or "LEG"
    local chosen_side = side or ((math.random() < 0.5) and "LEFT" or "RIGHT")
    -- Side-swap if matches parry
    if state.targetparry == (chosen_side:lower() .. body:lower()) then
      chosen_side = (chosen_side == "LEFT") and "RIGHT" or "LEFT"
    end
    out.limb = chosen_side .. " " .. body
  end
  return out
end

-- =============================================================
-- Venom + weapon selection
-- =============================================================

local function pick_venom(state)
  -- Venom availability assumed always-on; only gate on aff presence.
  for _, entry in ipairs(M.config.aff_priority) do
    if not aff_present(state, entry.aff) then
      return entry.venom
    end
  end
  return nil
end

local function weapon_for_mode(state)
  return (state.weapon_mode == "sword") and M.config.bastard_sword or M.config.warhammer
end

-- For phases where weapon_mode applies (STACK, DEVASTATE flavors), this returns
-- the venom we'd apply IF the current weapon supports it (sword only). Warhammer
-- can't carry venom, so we return nil there even if pick_venom would pick one —
-- respects the user's mode preference rather than silently overriding to sword.

local function venom_if_carryable(state, weapon)
  if weapon ~= M.config.bastard_sword then
    return nil
  end
  return pick_venom(state)
end

-- Some attack commands rename based on the wielded weapon. This resolver maps
-- an internal attack name (sword-equivalent) to the correct command for the
-- current weapon. Add entries as new equivalences are confirmed.
local HAMMER_ATTACK_NAME = {HEW = "PULVERISE", CARVE = "SPLINTER"}

local function attack_command(attack, weapon)
  if weapon == M.config.warhammer and HAMMER_ATTACK_NAME[attack] then
    return HAMMER_ATTACK_NAME[attack]
  end
  return attack
end

-- =============================================================
-- Batch builder
-- =============================================================

local function build_batch(state, phase)
  local cmds = {}
  local cfg = M.config

  local function add(c)
    cmds[#cmds + 1] = c
  end

  -- Prefix (always emitted)
  add("RECOVER FOOTING")
  add("EMPOWER PRIORITY SET " .. table.concat(cfg.rune_priority, " "))
  if not M.state.falcon_tracking then
    add("FALCON TRACK " .. target)
    runewarden.twoh.state.falcon_tracking = true
  end
  if not M.state.falcon_slaying then
    add("FALCON SLAY " .. target)
    runewarden.twoh.state.falcon_slaying = true
  end
  add("FALCON REPORT")
  add("BATTLEFURY PERCEIVE " .. state.target)
  -- Body (phase-dispatched)
  if phase == PHASE.PATH_B_BRAIN then
    add("WIELD " .. cfg.warhammer)
    add("BRAIN " .. state.target)
  elseif phase == PHASE.PATH_A_DISEMBOWEL then
    add("WIELD " .. cfg.bastard_sword)
    add("DISEMBOWEL " .. state.target)
  elseif phase == PHASE.PATH_A_IMPALE then
    add("WIELD " .. cfg.bastard_sword)
    add("IMPALE " .. state.target)
  elseif phase == PHASE.PATH_C_BISECT then
    add("WIELD " .. cfg.bastard_sword)
    local venom = pick_venom(state)
    -- BISECT venom is inline (per help: `BISECT <target> [venom]`), not via ENVENOM
    add("BISECT " .. state.target .. (venom and (" " .. venom) or ""))
  elseif phase == PHASE.PATH_B_OVERWHELM then
    add("WIELD " .. cfg.warhammer)
    add("BATTLEFURY OVERWHELM " .. state.target)
  elseif phase == PHASE.PATH_A_DEVASTATE then
    -- DEVASTATE takes inline venom — only carried by sword. weapon_mode wins.
    local weapon = weapon_for_mode(state)
    local venom = venom_if_carryable(state, weapon)
    add("WIELD " .. weapon)
    add("DEVASTATE " .. state.target .. " LEGS" .. (venom and (" " .. venom) or ""))
    add("BATTLEFURY UPSET " .. state.target)
  elseif phase == PHASE.CARVE then
    -- CARVE/SPLINTER name depends on weapon. WIPE+ENVENOM only when sword.
    local weapon = weapon_for_mode(state)
    local venom = venom_if_carryable(state, weapon)
    add("WIELD " .. weapon)
    if venom then
      add("WIPE " .. weapon)
      add("ENVENOM " .. weapon .. " WITH " .. venom)
    end
    add(attack_command("CARVE", weapon) .. " " .. state.target)
  elseif phase == PHASE.MANUAL_DEVASTATE_ARMS then
    local weapon = weapon_for_mode(state)
    local venom = venom_if_carryable(state, weapon)
    add("WIELD " .. weapon)
    add("DEVASTATE " .. state.target .. " ARMS" .. (venom and (" " .. venom) or ""))
  elseif phase == PHASE.MANUAL_DEVASTATE_LEGS then
    local weapon = weapon_for_mode(state)
    local venom = venom_if_carryable(state, weapon)
    add("WIELD " .. weapon)
    add("DEVASTATE " .. state.target .. " LEGS" .. (venom and (" " .. venom) or ""))
    add("BATTLEFURY UPSET " .. state.target)
  elseif phase == PHASE.STACK then
    local pick
    if M.state.override_loc then
      pick = build_override_pick(state, M.state.override_loc, M.state.override_side)
    else
      pick = select_stack_attack(state)
    end
    if pick then
      local weapon = weapon_for_mode(state)
      local venom = venom_if_carryable(state, weapon)
      add("WIELD " .. weapon)
      if venom then
        add("WIPE " .. weapon)
        add("ENVENOM " .. weapon .. " WITH " .. venom)
      end
      add("BATTLEFURY FOCUS " .. M.state.focus_mode)
      if pick.attack == "HEW" then
        add(attack_command("HEW", weapon) .. " " .. state.target .. " " .. pick.limb)
      else
        add(attack_command(pick.attack, weapon) .. " " .. state.target)
      end
    end
    -- If pick is nil (everything blocked or bad override), no main attack
  end
  -- Suffix (always emitted)
  add("ASSESS")
  if not state.engaged then
    add("ENGAGE " .. state.target)
  end
  return cmds
end

-- =============================================================
-- Fire: build and submit a batch
-- =============================================================
-- Look up a limb_priority entry by loc (for parry/safety checks). Returns nil if unknown.

local function find_limb_entry(loc)
  for _, e in ipairs(M.config.limb_priority) do
    if e.loc == loc then
      return e
    end
  end
  return nil
end

-- Minimum fractures to commit a manual DEVASTATE. 4 = level-2 break; below that
-- the break level is too weak to be worth the cooldown.
local DEVASTATE_MIN_FRACTURES = 4
-- Phases that always win over manual modes:
--   - Continuation finishers (IMPALE, DISEMBOWEL) — mid-chain commitment
--   - Execute (BISECT) — kill priority
--   - CARVE — clearing defenses (any attack-based manual mode would bounce)
--   - BRAIN follow-up — we already committed to the kill via OVERWHELM
local OVERRIDE_PROTECTED =
  {
    [PHASE.PATH_A_DISEMBOWEL] = true,
    [PHASE.PATH_A_IMPALE] = true,
    [PHASE.PATH_C_BISECT] = true,
    [PHASE.CARVE] = true,
    [PHASE.PATH_B_BRAIN] = true,
  }

local function compute_and_fire()
  local state = read_state()
  if not is_valid_target(state.target) then
    -- No usable target → clear any queued operating mode so we don't carry stale intent
    M.state.override_loc = nil
    M.state.override_side = nil
    M.state.devastate_pending = nil
    return
  end
  -- Compute the auto-cascade choice first. Manual modes can only override
  -- when the auto choice isn't a continuation/execute/CARVE phase.
  local auto_phase = select_phase(state)
  local phase
  if OVERRIDE_PROTECTED[auto_phase] then
    phase = auto_phase
  elseif M.state.devastate_pending == "ARMS" then
    if state.wrist >= DEVASTATE_MIN_FRACTURES then
      phase = PHASE.MANUAL_DEVASTATE_ARMS
    else
      boxEcho.send(
        "[2H] DEVASTATE ARMS BLOCKED: only " ..
        state.wrist ..
        " wrist fractures (need " ..
        DEVASTATE_MIN_FRACTURES ..
        "+). FALLING BACK TO AUTO."
      )
      phase = auto_phase
    end
  elseif M.state.devastate_pending == "LEGS" then
    if state.tendons >= DEVASTATE_MIN_FRACTURES then
      phase = PHASE.MANUAL_DEVASTATE_LEGS
    else
      boxEcho.send(
        "[2H] DEVASTATE LEGS BLOCKED: only " ..
        state.tendons ..
        " tendon fractures (need " ..
        DEVASTATE_MIN_FRACTURES ..
        "+). FALLING BACK TO AUTO."
      )
      phase = auto_phase
    end
  elseif M.state.override_loc then
    -- Late parry check on head/torso. (Arms/legs HEW side-swaps naturally.)
    local entry = find_limb_entry(M.state.override_loc)
    if
      entry and entry.parry and (not nausea_bypass(state)) and state.targetparry == entry.parry
    then
      boxEcho.send(
        "[2H] OVERRIDE BLOCKED: " ..
        string.upper(entry.parry) ..
        " IS PARRIED AND NO NAUSEA. FALLING BACK TO AUTO."
      )
      phase = auto_phase
    else
      phase = PHASE.STACK
    end
  else
    phase = auto_phase
  end
  local cmds = build_batch(state, phase)
  send("SETALIAS TWOHATK " .. table.concat(cmds, "/"))
  send("QUEUE ADDCLEARFULL FREE TWOHATK")
  -- Record fire time so on_balance_used can tell combat balance use from
  -- non-combat (chopping wood, eating, etc.) and skip the pre-fetch when idle.
  M.state.last_fire_time = os.time()
  -- One-shot: clear all manual flags after firing
  M.state.override_loc = nil
  M.state.override_side = nil
  M.state.devastate_pending = nil
end

-- =============================================================
-- Public surface (called from Mudlet aliases / GMCP events)
-- =============================================================
-- Alias 'zz' — arm for next balance window, or fire immediately if EQBAL ready

function M.arm()
  if not is_valid_target(target) then
    echo("[2H] Not arming: target is '" .. tostring(target) .. "'.\n")
    return
  end
  if on_eqbal() then
    compute_and_fire()
  else
    M.state.armed = true
  end
end

-- Alias 'ww' — toggle weapon mode between sword and warhammer

function M.toggle_weapon_mode()
  M.state.weapon_mode = (M.state.weapon_mode == "sword") and "warhammer" or "sword"
  echo("[2H] Weapon mode: " .. M.state.weapon_mode .. "\n")
end

function M.toggle_focus_mode()
  M.state.focus_mode = (M.state.focus_mode == "precision") and "speed" or "precision"
  echo("[2H] Focus mode: " .. M.state.focus_mode .. "\n")
end

-- Override: queue an operating mode. The actual fire (and all safety checks) happen
-- on the next compute_and_fire — when balance returns or, if already on EQBAL,
-- immediately. Aliases are pure state-setters; they don't read or evaluate state.
--   loc:  must match a `loc` in config.limb_priority (e.g., "skull", "tendons")
--   side: optional "LEFT" | "RIGHT", only meaningful for wrist/tendons

function M.override(loc, side)
  -- Only validation done here is "is this a known limb keyword?" That's
  -- programmer-error, not state-dependent.
  local known = false
  for _, e in ipairs(M.config.limb_priority) do
    if e.loc == loc then
      known = true;
      break
    end
  end
  if not known then
    echo("[2H] Override: '" .. tostring(loc) .. "' is not a configured limb.\n")
    return
  end
  M.state.devastate_pending = nil
  M.state.override_loc = loc
  M.state.override_side = side
  M.arm()
end

-- Alias 'xx' — queue DEVASTATE ARMS as the operating mode. Safety/fracture checks
-- happen at fire time in compute_and_fire.

function M.devastate_arms()
  M.state.override_loc = nil
  M.state.override_side = nil
  M.state.devastate_pending = "ARMS"
  M.arm()
end

-- Alias 'cc' — queue DEVASTATE LEGS as the operating mode.

function M.devastate_legs()
  M.state.override_loc = nil
  M.state.override_side = nil
  M.state.devastate_pending = "LEGS"
  M.arm()
end

-- =============================================================
-- PERCEIVE display
--
-- Triggers (configured in Mudlet UI) capture lines from
-- BATTLEFURY PERCEIVE output and call into these functions. The display
-- itself is rendered via cecho into the main window, debounced 0.1s so
-- the multiple fragments of a single PERCEIVE response collapse into one
-- render.
-- =============================================================
M.perceive = M.perceive or {target = nil, parry = nil, timer_id = nil}

local function schedule_perceive_render()
  if M.perceive.timer_id then
    killTimer(M.perceive.timer_id)
  end
  M.perceive.timer_id =
    tempTimer(
      0.1,
      function()
        M.perceive.timer_id = nil
        M.perceive_render()
      end
    )
end

-- Called by any of the 4 fracture-line triggers. We only need the target name;
-- the actual counts are read off ak.twoh.* at render time (framework-maintained).

function M.perceive_fracture(target_name)
  M.perceive.target = target_name
  schedule_perceive_render()
end

function M.perceive_parry(target_name, limb)
  M.perceive.target = target_name
  M.perceive.parry = limb
  schedule_perceive_render()
end

function M.perceive_no_parry(target_name)
  M.perceive.target = target_name
  M.perceive.parry = nil
  schedule_perceive_render()
end

local function frac_color(count)
  if count >= 6 then
    return "<red>"
  elseif count >= 4 then
    return "<yellow>"
  else
    return "<green>"
  end
end

local function hp_color(pct)
  if pct <= 25 then
    return "<red>"
  elseif pct <= 50 then
    return "<yellow>"
  else
    return "<green>"
  end
end

local function bar(filled, total)
  return string.rep("|", filled) .. string.rep("-", total - filled)
end

function M.perceive_render()
  local p = M.perceive
  local hp_max = tonumber(ak.maxhealth) or 1
  local hp_cur = tonumber(ak.currenthealth) or 0
  local hp_pct = math.floor(hp_cur / hp_max * 100)
  local hp_n = math.floor(hp_pct / 10)

  local function frac_line(label, count)
    return
      string.format(
        "<cyan>%-7s<white>: %s%s<reset> %d/7\n", label, frac_color(count), bar(count, 7), count
      )
  end

  cecho("\n")
  cecho(string.format("<cyan>Target <white>: <orange>%s\n", read_state().target or "?"))
  cecho(
    string.format(
      "<yellow>HP     <white>: %s%s<reset> %3d%%\n", hp_color(hp_pct), bar(hp_n, 10), hp_pct
    )
  )
  cecho(frac_line("Skull", tonumber(ak.twoh.skull) or 0))
  cecho(frac_line("Ribs", tonumber(ak.twoh.ribs) or 0))
  cecho(frac_line("Wrist", tonumber(ak.twoh.wrist) or 0))
  cecho(frac_line("Tendons", tonumber(ak.twoh.tendons) or 0))
  cecho(string.format("<yellow>Parry  <white>: <orange>%s\n", read_state().targetparry or "none"))
end

-- Trigger handler for "Balance used: <N>s." This is the latency-based arming
-- system: off the reported balance interval it schedules TWO one-shot timers --
--   * dispatch  @ interval - prearm        -> fires the batch (if still armed)
--   * perceive  @ dispatch_delay - 0.5     -> FALCON REPORT + BATTLEFURY PERCEIVE
-- The dispatch lands the instant balance returns (server-side QUEUE holds it),
-- and the perceive runs 0.5s ahead so that dispatch builds its batch on FRESH
-- target intel (HP, parry, fractures) instead of state as of last balance.
--
-- Gated on "we recently fired a batch" so it ignores balance-consuming non-combat
-- actions (chopping wood, eating, etc.). Threshold ~10s covers ~3 combat batches.
local BALANCE_USED_COMBAT_WINDOW = 10
-- How far ahead of the dispatch the intel pre-fetch runs.
local PERCEIVE_LEAD = 0.5

function M.on_balance_used(seconds)
  if os.time() - (M.state.last_fire_time or 0) > BALANCE_USED_COMBAT_WINDOW then
    return
  end
  if not is_valid_target(target) then
    return
  end
  local interval = tonumber(seconds) or 0
  if interval <= 0 then
    return
  end
  local prearm = M.config.prearm_interval or (getNetworkLatency() * 2)
  local fire_delay = math.max(0, interval - prearm)
  local perceive_delay = math.max(0, fire_delay - PERCEIVE_LEAD)

  -- Intel pre-fetch: refresh target state 0.5s before the dispatch, but only if
  -- we're actually committed to firing (armed) -- no PERCEIVE spam otherwise.
  tempTimer(
    perceive_delay,
    function()
      if M.state.armed and is_valid_target(target) then
        send("FALCON REPORT")
        send("BATTLEFURY PERCEIVE " .. target)
      end
    end
  )

  -- Dispatch: fire the batch as balance returns, from current (just-refreshed)
  -- state. One-shot arm, mirroring Sentinel: disarm before firing.
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

-- gmcp.Char.Vitals handler — fires on bal/eq/hp/mana updates

function M.on_gmcp_char_vitals(_event)
  -- Firing is driven entirely by the prearm dispatch timer (see on_balance_used),
  -- so vitals updates no longer trigger the batch. Kept as a registered handler
  -- in case non-firing vitals work is added later.
end

-- All aliases, keys, and event handlers are configured as permanent objects in
-- the Mudlet UI (see project README / setup notes). The script provides only
-- the engine logic and namespace; UI objects call into runewarden.twoh.*.
echo("[2H] Combat engine loaded.\n")