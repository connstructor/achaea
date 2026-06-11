------------------------------------------
-- Psion.lua — Legacy / AK port (Idreth weaving offense)
------------------------------------------
-- Ported from the LEVI / Ataxia Psion module (`psion.*` namespace).
--
-- One stateless dispatch, three kill routes (+ a shield pre-empt), two modes. Every
-- dispatch rebuilds the whole command chain from CURRENT state -- unweave levels and
-- afflictions (affstrack.score), target mana (ak.manapercent), limb damage (lb).
-- Nothing target-specific is persisted; psion.state holds only the mode preference and
-- the firing latches (see STATE SOURCES below).
--
-- KILL ROUTES (priority order in build_attack):
--   1. cleave    -- target shielded -> strip the shield first (pre-empt).
--   2. excise    -- target mana <= EXCISE_MANA% -> PSI TRANSCEND EXCISE + PSI EXCISE (KILL).
--   3. flurry    -- flurry mode: invert a mind/body critical into spirit, then
--                   PSI TRANSCEND SHATTER + WEAVE FLURRY for a %-HP burst (KILL).
--   4. deconstruct -- inside the normal weave ladder: >=2 critical unweaves -> WEAVE
--                   DECONSTRUCT (KILL). Otherwise stack unweaves + affliction pressure
--                   toward a mana kill (mindravaged saps mana every hit -> excise).
--
-- STATE SOURCES: Psion offense pivots on class-specific target states, and affstrack
-- reports them -- unweave levels via affstrack.score.unweaving<kind> (encoded level*100;
-- >= CRITICAL_LEVEL*100 == "critical"), target mana via ak.manapercent, and mind-ravaged
-- / muddled / lightbind / generic affs via affstrack.score. So the whole offense reads
-- LIVE -- psion.state holds nothing target-specific, just the offense mode and firing
-- latches, and there are NO state-feed triggers to wire. (ak.psion.unweaving also tracks
-- unweaves but is unreliable; we read affstrack instead.)
------------------------------------------
-- Required globals (host frameworks -- Legacy curing + AK; not provided here)
------------------------------------------
-- Legacy: own curing/settings -- Legacy.Curing.Affs (self affs, the aeon guard),
--         Legacy.Settings.Curing.status (false = paused)
-- gmcp:   own vitals -- Char.Vitals.bal / Char.Vitals.eq ("1"/"0")
-- ak:     opponent state -- ak.defs.shield, ak.manapercent
-- affstrack: opponent affliction tracker -- score[aff] 0-100; unweaving<kind> = level*100
-- lb:     opponent limb damage -- lb[target].hits["head"] etc., 0-200
-- target: current target name (string)
-- boxEcho: status display sink (notify falls back to cecho/print if absent)
------------------------------------------
-- Wire-up (create by hand in Mudlet -- this module self-registers nothing; see
-- MUDLET_SETUP.md). With AK loaded the kill routes need NO state triggers; the whole
-- wiring is the arm aliases + the Balance/Equilibrium-used trigger.
--   * Alias  "^zz$"  -> psmind()    -- arm, mind mode (standard: auto excise/deconstruct)
--   * Alias  "^xx$"  -> psflurry()  -- arm, flurry mode (spirit burst)
--   * Alias  "^cc$"  -> pscatch()   -- anti-escape (launch flier + re-lightbind)
--   * Alias  "^vv$"  -> psheal()    -- self-cure (psi expunge: clear a mental)
--   * Regex  "^(Balance|Equilibrium) used: (\d+\.\d+)s\.$"
--                    -> psion.on_balance(tonumber(matches[3]))
--   That's the entire wiring -- no state-feed triggers (AK + affstrack supply it all).
------------------------------------------
-- DEPENDENCY MAPPING (Levi / Ataxia  ->  Legacy / AK)
--   haveAff("X") / tAffs.X            -> has_aff("X")  (affstrack.score[X] >= AFF_THRESHOLD)
--   pm (target mana %)               -> target_mana()  (ak.manapercent)
--   gmcp.Char.Vitals.bal == "1"      -> have_eqbal() (requires bal AND eq up)
--   ataxia.afflictions.aeon          -> self_aff("aeon")  (Legacy.Curing.Affs.aeon)
--   ataxia.settings.paused           -> is_paused()  (Legacy.Settings.Curing.status == false)
--   ataxia.settings.separator (";")  -> "/" hardcoded
--   send("queue addclear free X")    -> SETALIAS PSIATK ... + QUEUE ADDCLEARFULL FREE PSIATK
--   combatQueue() pre-attack prefix  -> removed (Legacy handles pre-attack hooks externally)
--   ataxiaNDB_getClass(target)       -> get_target_class()  (hardcode your matchup)
--   tAffs.unweavingmind / critical.. -> unweave_level()  (affstrack.score.unweaving*/100)
--   muddled / lightbind (on target)  -> has_aff()  (affstrack.score.{muddled,lightbind})
------------------------------------------
psion = psion or {}

------------------------------------------
-- CONFIG -- all tunables. Override AFTER this file loads.
------------------------------------------
psion.CONFIG =
{
  -- affstrack confidence (0-100) at/above which a generic aff counts as landed
  AFF_THRESHOLD = 50,
  -- target mana % at/below which Psi Excise is a kill
  EXCISE_MANA = 30,
  -- unweave level that counts as "critical" (deconstruct / flurry invert)
  CRITICAL_LEVEL = 3,
  -- spirit unweave level required to fire Flurry; raise to hold for a bigger burst
  FLURRY_MIN_SPIRIT = 3,
  -- per-hit limb damage of a weave strike, for head prep/break math (the Levi
  -- `psionweaves` value, which defaulted to 25). Calibrate to your own numbers --
  -- hit a fresh head solo a few times and divide the lb["head"] delta by the hits.
  WEAVE_DAMAGE = 25,
  -- prefix each turn with a shield wield (faithful to the source `wield right
  -- shield`). Set false, or change WIELD_COMMAND, to suit your kit.
  WIELD_SHIELD = true,
  WIELD_COMMAND = "WIELD RIGHT SHIELD",
  -- append ENACT LIGHTBIND <target> while the target isn't already lightbound
  LIGHTBIND = true,
  -- append CONTEMPLATE <target> each turn -- this command is what FEEDS AK's
  -- ak.manapercent, so the excise gate reads fresh mana. Don't disable it to save a
  -- command -- the primary kill goes blind without it.
  CONTEMPLATE = true,
  -- just-in-time fire lead time (seconds). nil -> getNetworkLatency().
  PREARM_INTERVAL = nil,
  DEBUG = false,
}

------------------------------------------
-- DATA -- static reference tables.
------------------------------------------
psion.DATA = {}

-- A "prepare" rider lands a free affliction on the same weave. name -> aff.
psion.DATA.PREPARE =
{
  disruption = "paralysis",
  laceration = "haemophilia",
  vapours    = "asthma",
  rattle     = "epilepsy",
  dazzle     = "clumsiness",
}

-- Psi Blast unlocks (applies mindravaged) once >= 3 of these are present.
psion.DATA.PSI_BLAST_AFFS =
  { "impatience", "stupidity", "blackout", "dizziness", "epilepsy", "unweavingmind" }

-- Classes vs which we lead fillers with weariness (blocks Fitness) over clumsiness.
psion.DATA.PRIEST_OCC_PARIAH = { Priest = true, Occultist = true, Pariah = true }

-- Lock tiers, for the status readout. Softlock is the affliction-kill base.
psion.DATA.LOCKS =
{
  SOFTLOCK = { "asthma", "anorexia", "slickness" },
  HARDLOCK = { "asthma", "anorexia", "slickness", "impatience" },
  TRUELOCK = { "asthma", "anorexia", "slickness", "impatience", "paralysis" },
}

------------------------------------------
-- STATE -- runtime. ALL target/combat state reads LIVE: unweave levels from
-- affstrack.score.unweaving<kind>, mana from ak.manapercent, and every affliction
-- (muddled, lightbind, mindravaged, ...) from affstrack.score. Nothing target-specific
-- is tracked here -- only the offense mode and the just-in-time firing latches.
------------------------------------------
psion.state = psion.state or
{
  mode = "mind",        -- "mind" (default) | "flurry"
  next_bal_armed = false,
  next_bal_timer = nil,
  next_bal_deadline = nil, -- epoch the pending timer fires (used to keep the longer one)
}

------------------------------------------
-- Status / debug sink
------------------------------------------
local function notify(msg)
  if boxEcho and type(boxEcho.send) == "function" then
    boxEcho.send(msg)
  elseif cecho then
    cecho("\n<cyan>[psion]:<white> " .. msg)
  else
    print("[psion] " .. msg)
  end
end

------------------------------------------
-- Opponent-state predicates
------------------------------------------

-- affstrack confidence 0-100 (nil-safe)
local function score(aff)
  return (affstrack and affstrack.score and affstrack.score[aff]) or 0
end

local UNWEAVE_KINDS = { mind = true, body = true, spirit = true }

-- Unweave level (0-N) for mind/body/spirit, read from affstrack.score.unweaving<kind>,
-- which encodes the level as level*100 (100=lvl1 ... 500=lvl5) -- NOT the 0-100
-- confidence a normal aff carries. (ak.psion.unweaving tracks the same thing but proved
-- unreliable, so we don't use it.) "critical" is ALWAYS level >= CRITICAL_LEVEL; there
-- is no critical<kind> affliction. If your affstrack uses a scale other than *100,
-- change the divisor below -- it's the only spot.
local function unweave_level(kind)
  return math.floor(score("unweaving" .. kind) / 100)
end

-- Unified affliction read. Unweave/critical come from the numeric unweave level;
-- everything else (muddled, lightbind, mindravaged, prone, asthma, ...) from
-- affstrack.score above threshold.
local function has_aff(aff)
  local kind = aff:match("^unweaving(%a+)$")
  if kind and UNWEAVE_KINDS[kind] then return unweave_level(kind) > 0 end
  kind = aff:match("^critical(%a+)$")
  if kind and UNWEAVE_KINDS[kind] then return unweave_level(kind) >= psion.CONFIG.CRITICAL_LEVEL end
  return score(aff) >= psion.CONFIG.AFF_THRESHOLD
end

local function has_shield()
  if ak and ak.defs and ak.defs.shield then
    return true
  end
  return has_aff("shield")
end

-- Target mana %: AK exposes it directly as ak.manapercent (kept fresh by the per-turn
-- CONTEMPLATE we send). Defaults to 100 (full -> no excise) until AK has read it.
local function target_mana()
  if ak and type(ak.manapercent) == "number" then return ak.manapercent end
  return 100
end

-- Limb damage 0-200 (head is the only limb the weave ladder preps).
local function limb_damage(limb)
  return (lb and lb[target] and lb[target].hits and lb[target].hits[limb]) or 0
end
local function is_limb_broken(limb)
  return limb_damage(limb) >= 100
end

local function weave_damage()
  return psion.CONFIG.WEAVE_DAMAGE or 25
end
-- "prepped": one more weave hit reaches the break threshold. Mirrors the source
-- isLimbPrepped("head") -- a raw threshold with NO broken-state exclusion; the call
-- site pairs it with `not head_damaged()` when it needs that.
local function head_prepped()
  return limb_damage("head") + weave_damage() >= 100
end
-- "double-prepped": two more weave hits reach the break threshold (mind-mode
-- deathblow window). Mirrors the source isHeadDoublePrepped() -- raw threshold,
-- intentionally STILL TRUE once the head is broken (lb >= 100).
local function head_double_prepped()
  return limb_damage("head") + 2 * weave_damage() >= 100
end
-- "damaged": the head is broken (lb >= 100) -- the source's `damagedhead` aff,
-- derived straight from lb so it never lags. overhand now lands impatience.
local function head_damaged()
  return is_limb_broken("head")
end

-- AK has no class feed. Hardcode your matchup here if you want class-aware fillers;
-- nil keeps the default order (clumsiness before weariness).
local function get_target_class()
  return nil
end
local function is_priest_occ_pariah()
  local c = get_target_class()
  return c ~= nil and psion.DATA.PRIEST_OCC_PARIAH[c] == true
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

-- balance AND equilibrium up (gmcp values are STRINGS). Psion combos spend both.
local function have_eqbal()
  return gmcp and gmcp.Char and gmcp.Char.Vitals
    and gmcp.Char.Vitals.bal == "1" and gmcp.Char.Vitals.eq == "1" or false
end

------------------------------------------
-- Kill-route gates
------------------------------------------

local function crit_count()
  local n = 0
  if has_aff("criticalmind") then n = n + 1 end
  if has_aff("criticalbody") then n = n + 1 end
  if has_aff("criticalspirit") then n = n + 1 end
  return n
end

-- Two criticals -> Deconstruct is an instant kill.
local function can_deconstruct()
  return crit_count() >= 2
end

-- >= 3 of the blast affs -> Psi Blast lands mindravaged.
local function can_psiblast()
  local n = 0
  for _, a in ipairs(psion.DATA.PSI_BLAST_AFFS) do
    if has_aff(a) then n = n + 1 end
  end
  return n >= 3
end

-- Spirit unweave high enough to fire Flurry. Gates on the real spirit level
-- (unweave_level, from affstrack); raise FLURRY_MIN_SPIRIT to hold for a bigger burst.
local function flurry_ready()
  return unweave_level("spirit") >= psion.CONFIG.FLURRY_MIN_SPIRIT
end

------------------------------------------
-- Selection -- prepare rider, transcend slot, and the weave.
------------------------------------------

-- The free affliction rider on this weave.
local function select_prepare()
  local mode = psion.state.mode
  if has_aff("mindravaged") and not has_aff("haemophilia") then return "laceration" end
  if mode == "flurry" and has_aff("impatience") and not has_aff("epilepsy") then return "rattle" end
  if not has_aff("paralysis") then return "disruption" end
  if not has_aff("haemophilia") then return "laceration" end
  if not has_aff("asthma") then return "vapours" end
  return "rattle"
end

-- The PSI TRANSCEND <type> resource slot.
local function select_transcend()
  if target_mana() <= psion.CONFIG.EXCISE_MANA then return "excise" end
  if can_psiblast() and not has_aff("mindravaged") then return "blast" end
  if not has_aff("muddled") then return "muddle" end
  return "shatter"
end

-- The weave attack, as a name. `prepare` is the rider chosen this turn (so we don't
-- pick a weave whose aff the rider already covers). Faithful to the Levi ladder.
local function select_weave(prepare)
  local mode = psion.state.mode

  -- 1. Two criticals -> Deconstruct (KILL).
  if can_deconstruct() then return "deconstruct" end
  -- 2. Flurry mode, spirit at burst level -> Flurry (KILL).
  if mode == "flurry" and flurry_ready() then return "flurry" end

  local impatience = has_aff("impatience")
  local stupdizzy  = has_aff("stupidity") and has_aff("dizziness")

  -- 3. Head broken -> overhand to land impatience.
  if head_damaged() and not impatience then return "overhand" end
  -- 4. Head one hit from breaking (not yet broken).
  if head_prepped() and not head_damaged() then
    if not impatience then return "overhand" end
    if not stupdizzy then return "backhand" end
    if not has_aff("asthma") and prepare ~= "vapours" then return "deathblow" end
  end
  -- 5. Mind mode, head two hits from breaking (or already broken) -> deathblow for asthma.
  if mode == "mind" and head_double_prepped() and not has_aff("asthma") then
    return "deathblow"
  end
  -- 6. Prone -> cheap head pressure.
  if has_aff("prone") then
    if not impatience then return "overhand" end
    if not stupdizzy then return "backhand" end
  end
  -- 7. Pre-ravage mental pressure.
  if not has_aff("mindravaged") and mode == "mind" and impatience and not stupdizzy then
    return "backhand"
  end
  -- 8. Asthma up, mind+body unweaves but no spirit -> open the spirit unweave.
  if not has_aff("mindravaged")
    and has_aff("unweavingmind") and has_aff("unweavingbody")
    and not has_aff("unweavingspirit") and has_aff("asthma") then
    return "unweave spirit"
  end
  -- 9. Both primary unweaves up (mindravaged makes the mind one redundant) ->
  --    class-aware fillers, then deathblow for asthma.
  local primaries = has_aff("unweavingbody")
    and (has_aff("unweavingmind") or has_aff("mindravaged"))
  if primaries then
    if is_priest_occ_pariah() then
      if not has_aff("weariness") then return "puncture" end
      if not has_aff("clumsiness") then return "sever" end
    else
      if not has_aff("clumsiness") then return "sever" end
      if not has_aff("weariness") then return "puncture" end
    end
    if not has_aff("asthma") and prepare ~= "vapours" then return "deathblow" end
  end
  -- 10. Stack the primary unweaves.
  if not has_aff("unweavingbody") then return "unweave body" end
  if not has_aff("unweavingmind") then return "unweave mind" end
  -- 11. Fallback.
  return "unweave mind"
end

------------------------------------------
-- Command building
------------------------------------------

-- weave name -> game command. The three unweaves carry a <type> argument; every
-- other weave is "WEAVE <VERB> <target>".
local function weave_command(weave)
  if weave == "unweave mind" then return "WEAVE UNWEAVE " .. target .. " MIND" end
  if weave == "unweave body" then return "WEAVE UNWEAVE " .. target .. " BODY" end
  if weave == "unweave spirit" then return "WEAVE UNWEAVE " .. target .. " SPIRIT" end
  return "WEAVE " .. weave:upper() .. " " .. target
end

-- Returns: the attack-chain command list, the prepare chosen, the transcend chosen.
local function build_attack()
  local transcend = select_transcend()
  local prepare = select_prepare()
  local mode = psion.state.mode
  local cmds = {}

  -- 1. Shielded -> strip it (pre-empt; bypasses the weave ladder).
  if has_shield() then
    cmds[1] = "PSI TRANSCEND " .. transcend:upper() .. " " .. target
    cmds[2] = "WEAVE PREPARE " .. prepare:upper()
    cmds[3] = "WEAVE CLEAVE " .. target
    return cmds, prepare, transcend
  end

  -- 2. Mana kill.
  if target_mana() <= psion.CONFIG.EXCISE_MANA then
    cmds[1] = "PSI TRANSCEND EXCISE " .. target
    cmds[2] = "PSI EXCISE " .. target
    return cmds, prepare, "excise"
  end

  -- 3. Flurry mode: invert a critical into spirit, then burst.
  if mode == "flurry" then
    if flurry_ready() then
      cmds[1] = "PSI TRANSCEND SHATTER " .. target
      cmds[2] = "WEAVE PREPARE " .. prepare:upper()
      cmds[3] = "WEAVE FLURRY " .. target
      return cmds, prepare, "shatter"
    elseif has_aff("criticalmind") and not has_aff("criticalspirit") then
      cmds[1] = "WEAVE PREPARE " .. prepare:upper()
      cmds[2] = "WEAVE INVERT " .. target .. " MIND SPIRIT"
      return cmds, prepare, nil
    elseif has_aff("criticalbody") and not has_aff("criticalspirit") then
      cmds[1] = "WEAVE PREPARE " .. prepare:upper()
      cmds[2] = "WEAVE INVERT " .. target .. " BODY SPIRIT"
      return cmds, prepare, nil
    end
    -- no spirit set-up yet -> fall through to the normal weave turn
  end

  -- 4. Normal weave turn.
  local weave = select_weave(prepare)
  cmds[1] = "PSI TRANSCEND " .. transcend:upper() .. " " .. target
  cmds[2] = "WEAVE PREPARE " .. prepare:upper()
  cmds[3] = weave_command(weave)
  return cmds, prepare, transcend
end

------------------------------------------
-- Dispatch
------------------------------------------

-- The Legacy queue contract: write the chain into a server-side alias, then
-- atomically replace the named queue. Separator is "/".
local function send_commands(cmd_table)
  local cmd_string = table.concat(cmd_table, "/"):gsub("/+", "/")
  send(string.format("SETALIAS PSIATK %s", cmd_string))
  send("QUEUE ADDCLEARFULL FREE PSIATK")
end

-- Reactive one-offs (anti-escape, self-cure) go out on a separate PSIUTIL alias so they
-- read as a deliberate "do this NOW" press, distinct from the attack queue. Same FREE
-- queue contract; tune the verb if you'd rather append than replace.
local function queue_now(cmds)
  local s = table.concat(cmds, "/"):gsub("/+", "/")
  send(string.format("SETALIAS PSIUTIL %s", s))
  send("QUEUE ADDCLEARFULL FREE PSIUTIL")
end

function psion.dispatch()
  if type(target) ~= "string" or target == "" then
    notify("No target set")
    return
  end
  if self_aff("aeon") then return end   -- one action per long balance
  if is_paused() then return end
  -- NO eq/bal gate here: the JIT timer fires us ~latency BEFORE balance returns and the
  -- FREE queue holds the combo server-side until it does. Re-checking eqbal here (it
  -- isn't back yet at fire time) is exactly what stops the attack from launching.

  local cmds = build_attack()

  local out = {}
  if psion.CONFIG.WIELD_SHIELD then
    out[#out + 1] = psion.CONFIG.WIELD_COMMAND
  end
  for _, c in ipairs(cmds) do
    out[#out + 1] = c
  end
  if psion.CONFIG.LIGHTBIND and not has_aff("lightbind") then
    out[#out + 1] = "ENACT LIGHTBIND " .. target
  end
  out[#out + 1] = "ASSESS"
  -- CONTEMPLATE feeds AK's ak.manapercent; the excise gate goes stale without it, so
  -- keep it even though AK "has" the mana.
  if psion.CONFIG.CONTEMPLATE then
    out[#out + 1] = "CONTEMPLATE " .. target
  end

  send_commands(out)

  if psion.CONFIG.DEBUG then
    notify(psion.state.mode .. ": " .. table.concat(cmds, " / "))
  end
end

------------------------------------------
-- Firing model -- just-in-time arm + resource-used timer (NEW-family). Pressing the arm
-- button is what lets anything fire; the timer dispatches ~latency BEFORE the resource
-- returns so the FREE-queued combo lands the instant it does -- never weaving into
-- rebounding, never going full-auto. A Psion combo spends balance AND equilibrium, so
-- wire on_balance to BOTH "Balance used" and "Equilibrium used"; it keeps the timer for
-- whichever resource returns LAST (the longer recovery).
------------------------------------------

-- Arm button -- call from the `zz` alias (via psmind/psflurry).
function psion.arm()
  if have_eqbal() then
    psion.state.next_bal_armed = false
    psion.dispatch()
    return
  end
  psion.state.next_bal_armed = true
  notify("ARMED")
end

-- Balance/Equilibrium-used handler -- pass the captured recovery seconds. A Psion combo
-- spends BOTH, so two used-lines arrive together and we must fire only once the LONGER
-- resource is back. Schedule a tempTimer for (interval - lead), but keep the one with the
-- LATER deadline: a shorter incoming request is ignored; a longer one replaces the pending
-- timer. On expiry, if still armed, disarm and dispatch -- the FREE queue holds the combo
-- until balance actually returns, so we do NOT re-check eq/bal here.
function psion.on_balance(interval)
  interval = tonumber(interval)
  if not interval then return end
  local lead = psion.CONFIG.PREARM_INTERVAL
    or (getNetworkLatency and getNetworkLatency()) or 0.1
  local wait = math.max(0, interval - lead)
  local deadline = ((getEpoch and getEpoch()) or 0) + wait
  -- A pending timer that fires no earlier than this one already covers us -> ignore.
  if psion.state.next_bal_timer and deadline <= (psion.state.next_bal_deadline or 0) then
    return
  end
  if psion.state.next_bal_timer then killTimer(psion.state.next_bal_timer) end
  psion.state.next_bal_deadline = deadline
  psion.state.next_bal_timer = tempTimer(wait, function()
    psion.state.next_bal_timer = nil
    psion.state.next_bal_deadline = nil
    if psion.state.next_bal_armed then
      psion.state.next_bal_armed = false
      psion.dispatch()
    end
  end)
end

------------------------------------------
-- Lifecycle
------------------------------------------

function psion.setMode(m)
  if m == "mind" or m == "flurry" then psion.state.mode = m end
end

function psion.reset()
  if psion.state.next_bal_timer then killTimer(psion.state.next_bal_timer) end
  psion.state.mode = "mind"
  psion.state.next_bal_armed = false
  psion.state.next_bal_timer = nil
  psion.state.next_bal_deadline = nil
  notify("System reset.")
end

------------------------------------------
-- Status
------------------------------------------

-- Visible width of a cecho line: strip <...> color tags, then count UTF-8 codepoints
-- (box-drawing / block glyphs are width 1) so colored + Unicode content still aligns.
local function vwidth(s)
  s = s:gsub("<[^>]+>", "")
  local w = 0
  for i = 1, #s do
    local b = s:byte(i)
    if b < 0x80 or b >= 0xC0 then w = w + 1 end
  end
  return w
end

local STATUS_W = 40 -- inner width between "│ " and " │"

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
  return "<dim_grey>╭" .. string.rep("─", left) .. "<cyan>" .. t
    .. "<dim_grey>" .. string.rep("─", span - vwidth(t) - left) .. "╮<reset>"
end

local function box_footer()
  return "<dim_grey>╰" .. string.rep("─", STATUS_W + 2) .. "╯<reset>"
end

-- A 0..max block bar; green once it's at/over the critical level, else cyan.
local function level_bar(level, max, crit)
  level = math.max(0, math.min(max, level))
  local color = (crit and level >= crit) and "<green>" or "<cyan>"
  return color .. string.rep("█", level) .. "<dim_grey>" .. string.rep("░", max - level) .. "<reset>"
end

local function mana_bar(pct)
  local w = 16
  local filled = math.max(0, math.min(w, math.floor(pct / 100 * w + 0.5)))
  local color = pct <= psion.CONFIG.EXCISE_MANA and "<red>" or (pct <= 50 and "<yellow>" or "<green>")
  return color .. string.rep("█", filled) .. "<dim_grey>" .. string.rep("░", w - filled) .. "<reset>"
end

local function current_lock()
  local function all_up(list)
    for _, a in ipairs(list) do
      if not has_aff(a) then return false end
    end
    return true
  end
  if all_up(psion.DATA.LOCKS.TRUELOCK) then return "TRUELOCK" end
  if all_up(psion.DATA.LOCKS.HARDLOCK) then return "HARDLOCK" end
  if all_up(psion.DATA.LOCKS.SOFTLOCK) then return "SOFTLOCK" end
  return "none"
end

function psion.status()
  local crit = psion.CONFIG.CRITICAL_LEVEL
  local mode = psion.state.mode
  local tname = (type(target) == "string" and target ~= "") and target or "—"
  local mana = target_mana()
  local excise = mana <= psion.CONFIG.EXCISE_MANA

  local function killtok(name, ready)
    return (ready and "<green>" or "<dim_grey>") .. name .. "<reset>"
  end
  local function uw_cell(label, lv)
    local mark = (lv >= crit) and "  <green>◆<reset>" or ""
    return string.format("%-6s %s <white>%d<reset>%s", label, level_bar(lv, 5, crit), lv, mark)
  end

  box_echo(box_title("PSION · " .. mode:upper()))
  box_echo(box_row("<dim_grey>Target<reset>   <white>" .. tname .. "<reset>"))
  box_echo(box_row("<dim_grey>Mana<reset>     " .. mana_bar(mana) .. "  <white>" .. mana .. "%<reset>"
    .. (excise and "  <red>EXCISE<reset>" or "")))
  box_echo(box_row("<dim_grey>Unweave<reset>  " .. uw_cell("mind", unweave_level("mind"))))
  box_echo(box_row("         " .. uw_cell("body", unweave_level("body"))))
  box_echo(box_row("         " .. uw_cell("spirit", unweave_level("spirit"))))
  box_echo(box_row("<dim_grey>Kills<reset>    "
    .. killtok("DECONSTRUCT", can_deconstruct()) .. "  "
    .. killtok("EXCISE", excise) .. "  "
    .. killtok("FLURRY", mode == "flurry" and flurry_ready())))
  box_echo(box_row("<dim_grey>Lock<reset>     <yellow>" .. string.format("%-8s", current_lock())
    .. "<reset>   <dim_grey>Lightbind<reset> "
    .. (has_aff("lightbind") and "<green>✓<reset>" or "<dim_grey>✗<reset>")))
  box_echo(box_footer())
end

------------------------------------------
-- Reactive utilities (cc / vv -- fire now, independent of the attack arm cycle)
------------------------------------------

-- Anti-escape: pull a flier down (Launch) and re-pin with Lightbind.
function psion.antiescape()
  if type(target) ~= "string" or target == "" then notify("No target set"); return end
  queue_now({ "WEAVE LAUNCH " .. target, "ENACT LIGHTBIND " .. target })
  notify("anti-escape: launch + lightbind " .. target)
end

-- Self-cure: Psi Expunge clears a mental affliction (impatience first; blocked by
-- confusion in-game).
function psion.expunge()
  queue_now({ "PSI EXPUNGE" })
  notify("expunge: cure mental affliction")
end

------------------------------------------
-- Top-level alias wrappers (typeable from Mudlet's input line)
------------------------------------------
function psmind()   psion.setMode("mind");   psion.arm() end
function psflurry() psion.setMode("flurry"); psion.arm() end
function pscatch()  psion.antiescape() end
function psheal()   psion.expunge() end
function psstatus() psion.status() end
function psreset()  psion.reset() end
