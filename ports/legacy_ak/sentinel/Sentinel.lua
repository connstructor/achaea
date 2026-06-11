------------------------------------------
-- Sentinel.lua — Legacy / AK port (Skirmishing offense)
------------------------------------------
-- Sentinel combat module by Tannivh and Kiryn.
--
-- One stateless dispatch, three selectable finishers. Every dispatch rebuilds
-- the command set from CURRENT target state (limb damage + afflictions); nothing
-- is latched. The only "memory" is sentinel.state.finisher -- a plain preference
-- set by the arm aliases (zz/xx/cc) and READ (never written) by the engine.
--
--   * skullbash (default, zz): prep both legs + the head, then break leg/leg/head
--     and SKULLBASH to death while they're prone with the head broken. The leg breaks
--     only exist to put them down -- once the kill window (prone + broken head) is
--     open, leg state is ignored; only standing or a healed head closes it.
--   * wrench    (xx):          break BOTH legs (TRIP the first, axe the second), then
--                              IMPALE and WRENCH once impaled.
--   * dismember (cc):          break BOTH legs (no head), then a fixed chain read from
--                              state -- SKULLBASH -> ENRAGE BUTTERFLY (clears OUR
--                              blindness) + ENSNARE (transfix) -> RATTLE (knockout) ->
--                              OUTR ROPE/TRUSS (bind) -> IMPALE -> DISMEMBER
--                              (MORPH JAGUAR first if needed).
--   * lock      (vv):          go for the lock, not a limb kill. Once imp+ast+wear are up:
--                              TRIP one leg (off-herb-balance opener) + handaxe anorexia +
--                              slickness inside the 4s tempslickness window, then SKULLBASH
--                              the prone-locked target. A separate path -- leaves zz/xx/cc
--                              and their break invariants untouched.
--
-- PETRIFY (>=5 mental affs, unblind, via a Basilisk precommand) -> EXTIRPATE, and a
-- prone-lock SKULLBASH, fire opportunistically under any finisher.
--
-- WHY THIS IS STATELESS: every finisher preps + breaks legs from one shared engine, then
-- diverges -- skullbash also breaks the head; wrench and dismember stop at both legs. At and
-- after the divergence every step is read from live target state -- transfixed / unconscious /
-- trussed / impaled / petrified (affstrack) and limb damage (lb) -- so the engine never needs
-- a self-continuing "mode" or progress counter. The chosen finisher is the single bit that
-- says which way to diverge, and it's a user preference, not an engine latch.
--
-- THE ONE EXCEPTION -- sentinel.on_skullbash():
-- In the dismember chain the SKULLBASH -> ENRAGE/ENSNARE step is the only transition not
-- visible in target state: the target stays prone with both legs broken and not yet
-- transfixed across both the SKULLBASH dispatch and the ENSNARE dispatch, and nothing in
-- affstrack/lb reports that the SKULLBASH connected, so two consecutive dispatches look
-- identical. There is no marker to read, so we self-signal: wire your "your skullbash lands"
-- trigger to sentinel.on_skullbash(), which stamps state.skullbash_at. It is read at exactly
-- one place (skullbash_landed()), is cleared on target change / reset, and never touches the
-- finisher. If AK ever starts tracking it, repoint skullbash_landed() at that and delete
-- on_skullbash().
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
--   * Alias  "^cc$"   ->  sentinel.arm_next_bal("dismember")   -- dismember
--   * Alias  "^vv$"   ->  sentinel.arm_next_bal("lock")        -- lock (single-leg truelock)
--   * Regex trigger  "^Balance used: (\d+\.\d+)s\.$"
--                     ->  sentinel.on_balance(tonumber(matches[2]))
--   * Regex trigger  (your "SKULLBASH lands" line -- only needed for dismember)
--                     ->  sentinel.on_skullbash()
--   * (optional)  "^sentstatus$" -> sentstatus()  /  "^sentreset$" -> sentreset()
------------------------------------------
sentinel = sentinel or {}

-- One source of truth per priority: the affliction, the ability that lands it, and
-- (optionally) a confidence threshold to count it as already landed, plus (optionally) a
-- `requires` list of affs that must be up before the entry is worth selecting (coupling
-- -- e.g. anorexia waits on slickness + impatience). How much each attack adds to a limb
-- is used to decide when one more hit breaks it.
sentinel.CONFIG =
{
  DEFAULT_AFF_THRESHOLD = 50,
  PARRY_AFF_THRESHOLD = 67,
  LOCK_PREP_THRESHOLD = 67,
  WEAPONS = { SPEAR = "spear452934", HANDAXE = "handaxe453711", SHIELD = "shield435542" },
  -- Limbs we prep and break, in order: left leg -> right leg -> head.
  LIMB_PRIO = { "left leg", "right leg", "head" },
  ATK_PRIO =
  {
    { aff = "haemophilia", atk = "LACERATE" },
    { aff = "impatience",  atk = "DOUBLESTRIKE" },
    { aff = "weariness",   atk = "GOUGE" },
    { aff = "epilepsy",    atk = "DOUBLESTRIKE" },
  },
  ENRAGE_PRIO =
  {
    { aff = "healthleech",    enrage = "FOX" },
    { aff = "sensitivity",    enrage = "RAVEN" },
    { aff = "addiction",      enrage = "BADGER" },
    { aff = "nausea",         enrage = "BADGER" },
    { aff = "hallucinations", enrage = "WOLF" },
  },
  -- Lock-driving order. PARALYSIS #1 (tempo/bait: forces a bloodroot eat, threatens tree).
  -- MENTALS RIDE HIGH -- stupidity especially: mental affs degrade their curing across the
  -- board, so softening the cure response early makes every seal stick harder. Stupidity also
  -- goldenseal-stacks with impatience (protecting it); recklessness/dizziness feed PETRIFY.
  -- Kelp deepeners (clumsiness/sensitivity) drop below the keystone to make room. Slickness
  -- mostly arrives free as tempslickness on a break. Impatience rides DOUBLESTRIKE in ATK_PRIO.
  VENOM_PRIO =
  {
    { aff = "paralysis",    venom = "CURARE" },     -- #1: tempo/bait, hardens every cure + tree
    { aff = "asthma",       venom = "KALMIA" },     -- kelp seal (blocks smoking): the foundation
    { aff = "anorexia",     venom = "SLIKE", },
    { aff = "slickness",    venom = "GECKO" },      -- apply-block; mostly arrives free as tempslickness on a break
    { aff = "weariness",    venom = "VERNALIUS" },  -- kelp depth + class blocker (Fitness)
    { aff = "stupidity",    venom = "ACONITE" },    -- mental cure-disruptor (ESP.) + goldenseal depth -> protects impatience
    { aff = "recklessness", venom = "EURYPTERIA" }, -- mental: lowers their cure chances + PETRIFY
    { aff = "dizziness",    venom = "LARKSPUR" },   -- mental + goldenseal depth + PETRIFY
    { aff = "clumsiness",   venom = "XENTIO" },     -- kelp depth: keeps asthma/weariness >=67 through a cure
    { aff = "sensitivity",  venom = "PREFARAR" },   -- kelp depth (+ damage amp)
    -- Off-plan / situational tail.
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
  -- Morphs. Default form for spear combat; Basilisk only to land a PETRIFY.
  DEFAULT_MORPH = "Jaguar",
  PETRIFY_MORPH = "Basilisk",
  -- Dismember finish (cc). DISMEMBER needs both legs broken, so the route breaks BOTH
  -- legs (no head) first, then walks this chain, one balance action per dispatch, each
  -- step read from state:
  --   ... break both legs -> SKULLBASH -> ENRAGE BUTTERFLY + ENSNARE (transfix) ->
  --   RATTLE (knockout) -> OUTR ROPE/TRUSS (bind) -> IMPALE -> DISMEMBER (MORPH JAGUAR
  --   first if not already in form). %s = target -- adjust exact syntax here. Match aff
  --   names to your affstrack keys. (SKULLBASH has no AK tracker -- on_skullbash() signals
  --   its landing, the cue to advance from SKULLBASH to ENSNARE.)
  DISMEMBER =
  {
    ENRAGE = "ENRAGE BUTTERFLY",  -- free; clears OUR blindness so DISMEMBER lands
    ENSNARE = "ENSNARE %s",       -- transfix
    SKULLBASH = "SKULLBASH %s",   -- no AK tracker; on_skullbash() signals it landed
    RATTLE = "RATTLE %s",         -- knock unconscious
    TRUSS = "OUTR ROPE/TRUSS %s", -- get rope from rift, then TRUSS (slash-split)
    IMPALE = "IMPALE %s",
    MORPH = "Jaguar",
    KILL = "DISMEMBER %s",
  },
  -- skullbash_landed() window (seconds): how long after on_skullbash() the dismember
  -- route treats its SKULLBASH as having connected (advance to RATTLE).
  SKULLBASH_FLAG_SECONDS = 10,
  -- Echo debounce window (seconds) for the debug echo.
  ECHO_DEBOUNCE = 0.3,
  -- Lag reduction: on_balance arms a timer for (interval - PREARM_INTERVAL); the
  -- arm alias sets next_bal_armed so it actually fires. nil uses getNetworkLatency().
  PREARM_INTERVAL = nil,
}

-- A full lock (all up = they can't cure). Prone + locked -> opportunistic SKULLBASH.
-- This is the weariness truelock: asthma/slickness/paralysis/impatience/anorexia, with
-- weariness as the class passive-blocker. Per-class blockers (voyria vs Apostate/Priest,
-- haemophilia vs Magi/Sylvan, stupidity vs Alchemist, ...) are a v2 item.
-- PETRIFY needs the target unblind with >=5 of the mental affs in PETRIFY_AFFS.
sentinel.DATA =
{
  LOCK_AFFS =
  { "impatience", "asthma", "weariness", "paralysis", "slickness", "anorexia" },
  PETRIFY_AFFS =
  { "hallucinations", "dizziness", "recklessness", "confusion", "paranoia", "epilepsy", "impatience" },
}

-- Minimal runtime state. finisher is a user preference (set ONLY by arm_next_bal);
-- the rest is lag-reduction bookkeeping, the isolated skullbash-landed signal, target
-- tracking, and the echo-debounce stamp. No engine-written route latch lives here --
-- e.g. the wrench "both legs have been broken" milestone is INFERRED from limb state,
-- never stored (see both_legs_were_broken).
sentinel.state =
{
  finisher = "skullbash",
  next_bal_timer = nil,
  next_bal_armed = false,
  skullbash_at = nil,
  last_target = nil,
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
-- Lock / petrify state
------------------------------------------

local function all_above(affs, threshold)
  for _, aff in ipairs(affs) do
    if score(aff) < threshold then
      return false
    end
  end
  return true
end

local function is_locked()
  return all_above(sentinel.DATA.LOCK_AFFS, CONFIG.LOCK_PREP_THRESHOLD)
end

local function petrify_aff_count()
  local n = 0
  for _, aff in ipairs(sentinel.DATA.PETRIFY_AFFS) do
    if has_aff(aff) then
      n = n + 1
    end
  end
  return n
end

local function can_petrify()
  return not has_aff("petrified") and not has_aff("blind") and petrify_aff_count() >= 5
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
-- Returns the chosen prio entry (with its .atk/.enrage/.venom field).

-- An entry is selectable only if its coupling prerequisites are all up. This is how the
-- keystone is sequenced: anorexia carries requires = {"slickness", "impatience"}, so we
-- don't throw it (and watch it get epidermal'd / focused straight back off) until both of
-- its cures are already blocked. Entries with no `requires` field are always selectable.
-- Prereqs are checked at the LOCK bar, not the default: under affstrack's ambiguity decay a
-- seal sitting at 50 is a coin flip, and that's exactly when we must NOT sink anorexia into
-- a maybe-open cure -- so demand the seal be genuinely up (>= LOCK_PREP_THRESHOLD).
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

-- The lock base: impatience (focus blocked) + asthma (smoke blocked) + weariness (passive
-- blocked). The vv lock path keys off it. Every finisher (lock or limb) selects venoms from the
-- same VENOM_PRIO -- the lock-driving set hinders any target and keeps the affs warm for an
-- opportunistic switch to vv. The only lock-specific venom logic lives in lock_step.
local function lock_base_ready()
  return has_aff("impatience") and has_aff("asthma") and has_aff("weariness")
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

local function select_morph()
  -- Petrified: the execute is WIELD SPEAR + EXTIRPATE as a humanoid, so don't morph.
  if has_aff("petrified") then
    return nil
  end
  -- Basilisk only to set up a PETRIFY (requires balance but doesn't consume it, so it
  -- rides as a precommand); otherwise the default spear-combat form.
  local intended = can_petrify() and CONFIG.PETRIFY_MORPH or CONFIG.DEFAULT_MORPH
  if current_morph() ~= intended then
    return "MORPH " .. intended:upper()
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

-- Petrified execute: we petrified as a Basilisk, so re-wield the spear and EXTIRPATE.
local function petrify_execute()
  return { string.format("WIELD %s %s", SPEAR, SHIELD), string.format("EXTIRPATE %s", target) }
end

------------------------------------------
-- Shared break engine (used by all three finishers: skullbash, wrench, dismember)
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

-- Break the next leg toward a both-legs-broken prone: if they're up, trip a prepped,
-- unparried leg (breaks it and drops them); once down, axe whichever leg still stands
-- (prone bypasses parry). nil when nothing is breakable right now -- the caller then
-- falls back to the prep engine to rebuild.
local function next_leg_break(venom)
  if not is_prone() then
    local leg = prepped_leg()
    return leg and trip_attack(leg, venom) or nil
  end
  for _, limb in ipairs(CONFIG.LIMB_PRIO) do
    if limb:match(" leg$") and not is_limb_broken(limb) then
      return is_limb_prepped(limb, "THROW") and axe_attack(limb, venom) or nil
    end
  end
  return nil
end

-- Trip one leg, axe the other, axe the head. Returns the next break command, or nil
-- once both legs AND the head are broken (caller proceeds to its kill). nil mid-break
-- means nothing is breakable right now -> caller falls back to the prep engine.
local function break_legs_and_head(venom)
  if not both_legs_broken() then
    return next_leg_break(venom)
  end
  if not is_limb_broken("head") then
    return axe_attack("head", venom)
  end
  return nil
end

------------------------------------------
-- Prep engine (shared by all finishers -- they prep identically, then diverge)
------------------------------------------
-- Build the next limb and stack affs/venoms. Breaking is the finisher's job.

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
  local venom = select_aff(CONFIG.VENOM_PRIO, venom_exclude).venom
  local attack = force_rivestrike and "RIVESTRIKE" or atk_entry.atk
  local limb = select_limb(attack)
  if limb then
    return { string.format("%s %s %s", attack, limb, venom) }
  end
  return { string.format("%s %s", attack, venom) }
end

------------------------------------------
-- Dismember state reads
------------------------------------------

-- Read a dismember marker from current state: afflictions, plus the prone/impaled
-- accessors. "unconscious" checks both affstrack keys RATTLE might land.
local function dismember_marker(aff)
  if aff == "prone" then
    return is_prone()
  end
  if aff == "impaled" then
    return is_impaled()
  end
  if aff == "unconscious" then
    return has_aff("unconsciousness") or has_aff("asleep")
  end
  return has_aff(aff)
end

-- The ONE out-of-band signal (see header). True for SKULLBASH_FLAG_SECONDS after
-- sentinel.on_skullbash() fires -- our cue that the chain's SKULLBASH connected
-- (nothing in affstrack/lb tracks it), so the route advances from SKULLBASH to RATTLE.
local function skullbash_landed()
  local at = sentinel.state.skullbash_at
  return at ~= nil and (getEpoch() - at) <= CONFIG.SKULLBASH_FLAG_SECONDS
end

------------------------------------------
-- Finisher step-selectors (each returns a command list, or nil to fall through to
-- the shared prep engine). All read live state only; none write state.finisher.
------------------------------------------

-- skullbash: break leg/leg/head, then SKULLBASH while they're prone with the head
-- broken. The kill window is prone + broken head ONLY -- the leg breaks just put them
-- down, so legs healing mid-bash must never pull us back into the break engine. Only
-- standing up or a healed head closes the window (back to breaking/prepping).
local function skullbash_step(exclude)
  if is_limb_broken("head") and is_prone() then
    return { string.format("SKULLBASH %s", target) }
  end
  local venom = select_aff(CONFIG.VENOM_PRIO, exclude).venom
  return break_legs_and_head(venom)
end

-- "Both legs have BEEN broken" -- the wrench milestone -- inferred from current state,
-- no latch. True when both are broken now, OR exactly one is broken while the other
-- isn't even prepped. The requirement is "break both legs," not "keep both broken," so
-- a leg that heals after the second break must not regress us. We can read that from
-- state alone because of the break invariant: we never trip the first leg until BOTH
-- are prepped (the gate in wrench_step), and we axe the second the instant the first
-- goes down -- so a broken leg sitting beside an un-prepped one can only mean the other
-- was broken too and has since healed past its prep. (Other still prepped = mid-break.)
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

-- wrench setup: break BOTH legs (next_leg_break TRIPs the first -- breaking it and
-- proning the target -- then axes the second), then IMPALE. The break only STARTS once
-- both legs are prepped (or we're already mid-break), which is the invariant that lets
-- both_legs_were_broken read the milestone from state. nil during prep -> shared prep
-- engine builds the legs. The actual WRENCH fires from the universal "impaled" branch.
local function wrench_step(exclude)
  if both_legs_were_broken() then
    return { string.format("IMPALE %s", target) }
  end
  if any_leg_broken() or both_legs_prepped() then
    return next_leg_break(select_aff(CONFIG.VENOM_PRIO, exclude).venom)
  end
  return nil
end

-- dismember: the committed chain, every step chosen purely from current state
-- (highest reached state first, so the latest-reached step wins). nil during the
-- break phase means nothing is breakable now -> fall through to the prep engine.
local function dismember_step()
  local D = CONFIG.DISMEMBER
  if has_aff("petrified") then
    return petrify_execute()
  end
  if is_impaled() then
    local cmds = {}
    if current_morph() ~= D.MORPH then
      table.insert(cmds, "MORPH " .. D.MORPH:upper())
    end
    table.insert(cmds, string.format(D.KILL, target))
    return cmds
  end
  if dismember_marker("trussed") then -- TRUSS landed -> IMPALE.
    return { string.format(D.IMPALE, target) }
  end
  if dismember_marker("unconscious") then -- RATTLE landed -> OUTR ROPE/TRUSS to bind.
    return { string.format(D.TRUSS, target) }
  end
  if dismember_marker("transfixed") then -- ENSNARE landed (transfixed) -> RATTLE (knockout).
    return { string.format(D.RATTLE, target) }
  end
  -- Both legs broken (no head): SKULLBASH first. Nothing tracks its landing, so
  -- on_skullbash() (skullbash_landed) is our cue to advance to ENRAGE BUTTERFLY (free,
  -- clears our blindness) + ENSNARE (transfix).
  if both_legs_broken() then
    if skullbash_landed() then
      return { D.ENRAGE, string.format(D.ENSNARE, target) }
    end
    return { string.format(D.SKULLBASH, target) }
  end
  -- Break phase -- break BOTH legs only (trip the first, axe the second), like wrench;
  -- no head. nil during prep -> shared prep engine builds the legs first.
  if any_leg_broken() or both_legs_prepped() then
    return next_leg_break(select_aff(CONFIG.VENOM_PRIO, {}).venom)
  end
  return nil
end

------------------------------------------
-- lock (vv): single-leg break + truelock path, isolated from the limb finishers
------------------------------------------
-- vv goes for the lock instead of a limb kill. Once the base (imp+ast+wear) is up:
--   1. TRIP one prepped leg (prone + a 4s tempslickness window). The trip rides the normal
--      venom priority -- paralysis #1 if not up, else the next herb-cured aff -- to keep them
--      burning herb balance, so the keystone lands while their eat is committed.
--   2. Inside that window the HANDAXE lands the keystone then the seal: anorexia (sealed by
--      tempslickness + the base's impatience), then slickness. One break's 4s tempslickness
--      covers both (anorexia ~t+2.2, slickness ~t+3.6), so there is no second break.
-- Then the opportunistic prone+lock SKULLBASH finishes. It never preps all three or breaks a
-- second leg, so the skullbash/wrench/dismember invariants are never touched. nil -> the shared
-- prep engine builds the base (and paralysis/mentals) first.
-- ("head" is just the venom-delivery target for the handaxe -- it won't break unless prepped;
-- change it if you'd rather sink the throws elsewhere.)
local function lock_step(exclude)
  if not lock_base_ready() then
    return nil
  end
  -- 1. TRIP a prepped leg with the normal-priority venom (off-herb-balance opener).
  if not is_prone() and not any_leg_broken() and prepped_leg() then
    return trip_attack(prepped_leg(), select_aff(CONFIG.VENOM_PRIO, exclude).venom)
  end
  -- 2. Inside the trip's tempslickness window: handaxe the keystone, then the seal.
  if is_prone() then
    if has_aff("tempslickness") and not has_aff("anorexia") then
      return axe_attack("head", "SLIKE") -- handaxe + anorexia (tempslickness + impatience seal it)
    end
    if has_aff("anorexia") and not has_aff("slickness") then
      return axe_attack("head", "GECKO") -- handaxe + slickness, solidify the apply-block
    end
  end
  return nil
end

------------------------------------------
-- Non-dismember routing (priority order; dismember is dispatched separately so its
-- self-supplied free actions aren't doubled -- see sentinel.dispatch).
------------------------------------------

local function select_commands(exclude)
  local finisher = sentinel.state.finisher or "skullbash"
  -- Petrified -> EXTIRPATE, regardless of route.
  if has_aff("petrified") then
    return petrify_execute()
  end
  -- Impaled -> WRENCH. (Dismember owns the impaled state itself -- impale ->
  -- DISMEMBER -- and never reaches here, so it's never hijacked.)
  if is_impaled() then
    return { string.format("WRENCH %s %s", target, select_aff(CONFIG.VENOM_PRIO, exclude).venom) }
  end
  if finisher == "wrench" then
    local w = wrench_step(exclude)
    if w then
      return w
    end
  elseif finisher == "skullbash" then
    -- Enter the committed break once all three limbs are prepped, and stay in it
    -- while any limb is broken. skullbash_step returns nil when the kill window
    -- (prone + broken head) is closed and nothing is breakable -> fall through to
    -- the prep engine to rebuild.
    if any_limb_broken() or (all_limbs_prepped("TRIP") and prepped_leg()) then
      local s = skullbash_step(exclude)
      if s then
        return s
      end
    end
  elseif finisher == "lock" then
    local l = lock_step(exclude)
    if l then
      return l
    end
  end
  -- Opportunistic finishers (any route): prone + fully locked -> SKULLBASH.
  if is_prone() and is_locked() then
    return { string.format("SKULLBASH %s", target) }
  end
  if can_petrify() then
    return { string.format("PETRIFY %s", target) }
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
  -- Target change: clear the isolated skullbash-landed signal so a bash that landed
  -- on the previous target can't advance a fresh dismember chain. The finisher
  -- preference intentionally persists across a target swap.
  if sentinel.state.last_target ~= target then
    sentinel.state.last_target = target
    sentinel.state.skullbash_at = nil
  end

  local finisher = sentinel.state.finisher or "skullbash"

  local ok, err =
      xpcall(
        function()
          local out = {}
          -- Spear loadout for the spear attacks; the petrified execute re-wields
          -- itself (we petrified as a Basilisk), so skip the preamble wield then.
          if not has_aff("petrified") then
            table.insert(out, string.format("WIELD %s %s", SPEAR, SHIELD))
            table.insert(out, string.format("WIPE %s", SPEAR))
          end
          table.insert(out, string.format("ORDER LOYALS KILL %s", target))

          -- The dismember chain supplies its own free actions (ENRAGE BUTTERFLY to
          -- clear our blindness, MORPH JAGUAR before the kill), so when it has a
          -- committed step this dispatch, use it and skip the generic enrage/morph.
          -- Otherwise (any other finisher, or dismember still in shared prep) run the
          -- generic path: opportunistic enrage + morph, then the routing tree.
          local dis = finisher == "dismember" and dismember_step() or nil
          if dis and #dis > 0 then
            for _, cmd in ipairs(dis) do
              table.insert(out, cmd)
            end
          else
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
              tostring(is_impaled()) ..
              " petrified=" ..
              tostring(has_aff("petrified")) ..
              " bashLanded=" ..
              tostring(skullbash_landed())
            )
            cecho(
              "\n<yellow>[Sentinel] LL=" ..
              tostring(limb_damage("left leg")) ..
              " RL=" ..
              tostring(limb_damage("right leg")) ..
              " head=" ..
              tostring(limb_damage("head")) ..
              " parrying=" ..
              tostring(targetparry) ..
              " canPetrify=" ..
              tostring(can_petrify())
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

-- Button handler -- call from the zz/xx/cc/vv aliases. finisher: "skullbash" (default),
-- "wrench", "dismember", or "lock". Backward compatible: false/nil -> skullbash, true ->
-- wrench. This is the ONLY write to state.finisher.
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

-- Balance-used trigger handler. Arms a tempTimer for (interval - latency), so we
-- dispatch the instant balance returns (combo built from CURRENT state) without
-- going full-auto. If we weren't armed, the timer expires harmlessly.
function sentinel.on_balance(interval)
  if type(interval) ~= "number" then
    return
  end
  local prearm = CONFIG.PREARM_INTERVAL or getNetworkLatency()
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

-- Wire to your "your skullbash lands" trigger. The ONE out-of-band signal: stamps
-- the time so the dismember route knows its SKULLBASH connected (see header).
function sentinel.on_skullbash()
  sentinel.state.skullbash_at = getEpoch()
end

function sentinel.reset()
  sentinel.state =
  {
    finisher = "skullbash",
    next_bal_timer = nil,
    next_bal_armed = false,
    skullbash_at = nil,
    last_target = nil,
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
  local dis = "<red>no"
  for _, m in ipairs({ "impaled", "trussed", "unconscious", "transfixed" }) do
    if dismember_marker(m) then
      dis = "<yellow>" .. m .. (m == "transfixed" and skullbash_landed() and " (bashed)" or "")
      break
    end
  end
  cecho("\n<yellow>|   <white>DISMEMBER: " .. dis)
  cecho(
    "    <white>PETRIFY: " ..
    (can_petrify() and "<green>READY" or ("<red>" .. petrify_aff_count() .. "/5" .. (has_aff("blind") and " blind" or "")))
  )
  cecho("    <white>LOCK: " .. (is_locked() and "<green>YES" or "<red>no"))
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
