--[[
================================================================================
TEKURA UNIFIED OFFENSE — LEGACY / AK PORT
================================================================================

Consolidation of the two LEVI/Ataxia Tekura combat scripts:
  - 001_Tekura_Offense.lua        (3-limb backbreaker — "tkd")
  - 002_Tekura_6Limb_Offense.lua  (6-limb backbreaker — "tk6")

Two modes, one file:
  monk.tekura.setMode("tkd")   -- 3-limb: torso prep -> leg prep -> break torso
                               --   (HRS) -> double break (BRS) -> BBT / SCYTHE
  monk.tekura.setMode("tk6")   -- 6-limb: prep all 6 -> break arms+torso (HRS)
                               --   -> wrench torso + break legs (BRS) -> BBT

Convenience aliases (typeable from the Mudlet input line):
  tk()        dispatch in the current mode
  tkd()       set mode tkd + dispatch
  tk6()       set mode tk6 + dispatch
  tkstatus()  status for the current mode
  tkreset()   reset runtime state
  tkscythe()  toggle the TKD SCYTHE (Telepathy) kill route
  tk6debug()  toggle the TK6 debug echo

Public API (everything else is file-local):
  monk.tekura.CONFIG          table — tunables (thresholds, kai mode, debug, …)
  monk.tekura.state           table — runtime mutable state
  monk.tekura.mode            string — "tkd" or "tk6"
  monk.tekura.PHASES.TKD      phase enum for the 3-limb mode
  monk.tekura.PHASES.TK6      phase enum for the 6-limb mode
  monk.tekura.LIMB_ATTACKS    per-limb kick/punch abbreviations (tk6)
  monk.tekura.ALL_LIMBS       limb iteration order (tk6)

  monk.tekura.setMode(mode)        called by aliases
  monk.tekura.dispatch()           main entry (delegates to the active mode)
  monk.tekura.status()             called by aliases
  monk.tekura.reset()              called by aliases
  monk.tekura.toggleScythe()       tkscythe alias (tkd SCYTHE route)
  monk.tekura.startKaiSurgeWindow()  call from your kai-surge-fired trigger (tk6)
  monk.tekura.onLimbHitUpdated(...)  bound to the "limb hits updated" event (tk6)

--------------------------------------------------------------------------------
DEPENDENCY MAPPING (see ports/legacy_ak/tekura/DEPENDENCIES.md)
--------------------------------------------------------------------------------
AK (target state):
  tAffs.X / haveAff("X")        -> has("X")  (reads affstrack.score[X] >= affThreshold)
  lb[target].hits[limb]         -> unchanged
  ataxiaTemp.parriedLimb        -> targetparry (global)
  target                        -> unchanged
  tmounted                      -> has("mounted")
  tCity / Mhaldor branch        -> REMOVED (always proceed)
  ataxia.playersHere check      -> REMOVED (trust the user's `tar X`)

Legacy (self state):
  ataxia.vitals.stance          -> charstat("Stance")  (Cat/Scorpion/Horse/Bear)
  ataxia.afflictions.X          -> selfAff("X")  (reads Legacy.Curing.Affs[X])
  ataxia.settings.separator     -> "/"  (hardcoded for the SETALIAS ATK pattern)
  combatQueue()                 -> REMOVED (Legacy handles pre-attack hooks externally)
  send("queue addclear free X") -> sendAttack(X, "FREE")  (SETALIAS ATK / QUEUE ADDCLEARFULL)
  ataxia_needLockBreak()        -> selfNeedLockBreak()
  ataxia_lockBreak()            -> selfLockBreak()  (Monk: stand-if-prone + fitness)

Tekura-specific:
  "battered" global (TKD SCYTHE) -> has("stupidity") and has("epilepsy") and has("dizziness")
  ataxiaTemp.kaiSurgeWindow      -> monk.tekura.state.kaiSurgeWindow
                                    (set via monk.tekura.startKaiSurgeWindow())

Dynamic limb damage (TK6):
  The source learned kick/punch damage from the "limb hits updated" event and
  stored it in state.kickDamage / state.punchDamage. That handler is PRESERVED
  here verbatim — only the namespace changes. Until/unless AK raises that event,
  the seeded defaults (kick 25%, punch 14%) apply, which match the source.

Removed Levi parry-tracking subsystem:
  tekura.parry.* (parseCombo/onAttack/onParry/onHit/clear/registerTriggers) is
  GONE — AK supplies the parried limb directly via the `targetparry` global, so
  the ~230-line queue tracker that existed only to populate ataxiaTemp.parriedLimb
  is redundant. Every read of the parried limb now reads `targetparry`.

Namespace summary:
  monk.tekura.*        — this module (state, config, modes, dispatch)
  External (unchanged): gmcp, ak, Legacy, target, lb, affstrack, targetparry

================================================================================
]] --

-- ============================================================
--  NAMESPACE INIT
-- ============================================================
-- Module-owned state lives under `monk.tekura.*`. External dependencies
-- (gmcp, ak, Legacy, target, lb, affstrack, targetparry) remain top-level
-- globals.
monk = monk or {}
monk.tekura = monk.tekura or {}

-- Default mode: tk6 (the newer, more capable 6-limb route). Switch with
-- monk.tekura.setMode("tkd") / tk6() / tkd().
monk.tekura.mode = monk.tekura.mode or "tk6"

-- ============================================================
--  CONFIG  (all tunables consolidated)
-- ============================================================
monk.tekura.CONFIG = monk.tekura.CONFIG or {
    -- AK affstrack confidence threshold (0-100). affstrack.score[aff] >= this
    -- counts as "present." 30 matches Levi V3.
    affThreshold = 30,

    -- TKD: "prepped" means one HFP punch (14%) away from breaking.
    prepThreshold = 86, -- 86 + 14 = 100
    breakThreshold = 100,

    -- TK6: debug echo toggle (tk6debug()).
    debugEcho = true,

    -- TK6: kai dismount mode used by the parry-bypass route.
    --   "surge"   (31 kai, 3.2s eq)
    --   "cripple" (41 kai, 4s eq, L1 breaks all limbs)
    kaiMode = "surge",

    -- Self lock-break cooldown (seconds) between `fitness` attempts.
    lockBreakCooldown = 2,

    -- TK6: kai surge window duration (seconds) — target can't remount.
    kaiSurgeWindowDuration = 15
}

-- ============================================================
--  RUNTIME STATE
-- ============================================================
monk.tekura.state = monk.tekura.state or {
    -- Shared
    lastAttackTime = 0,
    attackInFlight = false, -- Anti-desync: true while off-balance (DWC pattern)
    lastTarget = nil, -- Target-change detection (DWB pattern)
    lastEchoTime = nil, -- Debounced echo timestamp (DWB pattern)

    -- TKD
    preferScythe = false,

    -- TK6: kick/punch damage, learned from the "limb hits updated" event.
    -- Seeded with the source defaults; overwritten when the event fires.
    kickDamage = 25,
    punchDamage = 14,
    lastKickLimb = nil, -- Direct parry tracking: stores kick target for parry trigger

    -- TK6: "target can't remount" window (set by startKaiSurgeWindow(); auto-clears).
    kaiSurgeWindow = false,
    _kaiSurgeTimer = nil
}

-- ============================================================
--  PHASE ENUMS
-- ============================================================
monk.tekura.PHASES = {
    TKD = {
        TORSO_PREP = 1, -- SDK HFP HFP to prep torso
        LEG_PREP = 2, -- SNK HFP HFP to prep legs (handle parry)
        TORSO_BREAK = 3, -- Break torso when all prepped, switch to HRS
        DOUBLE_BREAK = 4, -- WRT arm + HFP legs, prones + breaks legs, switch to BRS
        KILL = 5, -- BBT until dead (in Bear stance)
        SCYTHE = 6 -- Alternative: Telepathy kill
    },
    TK6 = {
        PREP = 1,
        BREAK_UPPER = 2,
        BREAK_LOWER = 3,
        KILL = 4
    }
}

monk.tekura.PHASE_NAMES = {
    TKD = {
        [1] = "TORSO PREP",
        [2] = "LEG PREP",
        [3] = "TORSO BREAK",
        [4] = "DOUBLE BREAK",
        [5] = "*** KILL ***",
        [6] = "*** SCYTHE ***"
    },
    TK6 = {
        [1] = "PREP (6-Limb)",
        [2] = "BREAK UPPER",
        [3] = "BREAK LOWER",
        [4] = "*** KILL ***"
    }
}

-- TK6: maps each limb to its kick and punch abbreviation.
monk.tekura.LIMB_ATTACKS = {
    head = {kick = "wwk", punch = "ucp"},
    torso = {kick = "sdk", punch = "hkp"},
    ["left arm"] = {kick = "mnk left", punch = "spp left"},
    ["right arm"] = {kick = "mnk right", punch = "spp right"},
    ["left leg"] = {kick = "snk left", punch = "hfp left"},
    ["right leg"] = {kick = "snk right", punch = "hfp right"}
}

-- TK6: all 6 limb names for iteration.
monk.tekura.ALL_LIMBS = {"head", "torso", "left arm", "right arm", "left leg", "right leg"}

-- ============================================================
--  AK HELPERS
-- ============================================================
-- affstrack.score[aff] is a 0-100 confidence value: 100 = fresh apply,
-- lower = ambiguous cure reduced certainty, nil = no evidence.
local function has(aff)
    return affstrack and affstrack.score and (affstrack.score[aff] or 0) >= monk.tekura.CONFIG.affThreshold
end

-- ============================================================
--  GMCP HELPER  (Legacy reads Char.Vitals.charstats)
-- ============================================================
-- charstats is a flat list of "Key: Value" strings, e.g.:
--   { "Bleed: 0", "Rage: 0", "Kai: 0%", "Form: None", "Stance: Cat" }
-- Returns a number if the value is numeric (with `%` stripped), the raw
-- string otherwise, or nil if the key is absent.
local function charstat(name)
    local cs = gmcp and gmcp.Char and gmcp.Char.Vitals and gmcp.Char.Vitals.charstats
    if not cs then
        return nil
    end
    local prefix = name .. ": "
    for _, entry in ipairs(cs) do
        local val = entry:match("^" .. prefix .. "(.+)$")
        if val then
            val = val:gsub("%%", "")
            return tonumber(val) or val
        end
    end
    return nil
end

-- ============================================================
--  SELF AFFLICTIONS / LOCK-BREAK  (Legacy.Curing domain)
-- ============================================================
-- Monk-only collapse of the full Levi lock-breaker. Triggers `fitness` when
-- softlocked (asthma + anorexia + slickness|bloodfire). Cooldowned to avoid
-- spamming. Was ataxia_needLockBreak() / ataxia_lockBreak().
local _lockBreakCooldown = 0

local function selfAff(name)
    local a = Legacy and Legacy.Curing and Legacy.Curing.Affs
    return a and a[name]
end

local function selfNeedLockBreak()
    return selfAff("asthma") and selfAff("anorexia") and (selfAff("slickness") or selfAff("bloodfire"))
end

local function selfLockBreak()
    if os.time() < _lockBreakCooldown then
        return false
    end
    if not selfNeedLockBreak() then
        return false
    end
    if selfAff("prone") and not selfAff("paralysis") then
        send("stand", false)
    end
    send("fitness", false)
    _lockBreakCooldown = os.time() + monk.tekura.CONFIG.lockBreakCooldown
    return true
end

-- ============================================================
--  SEND HELPER  (Legacy SETALIAS ATK / QUEUE ADDCLEARFULL pattern)
-- ============================================================
-- Legacy command stacks are `/`-separated inside an ATK alias, then queued.
-- Levi's old `send("queue addclear free <cmd>")` becomes two sends:
--   SETALIAS ATK cmd1/cmd2/cmd3
--   QUEUE ADDCLEARFULL FREE ATK
local function sendAttack(cmd, queueType)
    send("SETALIAS ATK " .. cmd)
    send("QUEUE ADDCLEARFULL " .. (queueType or "FREE") .. " ATK")
end

-- ============================================================
--  SHARED UTILITIES
-- ============================================================
-- Limb damage lookup. AK and Levi both use lb[target].hits[limb].
local function getLimbDamage(limb)
    if not target or target == "" then
        return 0
    end
    lb = lb or {}
    if not lb[target] then
        return 0
    end
    if not lb[target].hits then
        return 0
    end
    return lb[target].hits[limb] or 0
end

-- ============================================================
--  MODULE METHODS (shared across modes)
-- ============================================================

-- Echo debounce (DWB pattern: 0.3s guard prevents spam on rapid mashing).
function monk.tekura.shouldEcho()
    local now = getEpoch()
    if not monk.tekura.state.lastEchoTime or (now - monk.tekura.state.lastEchoTime) > 0.3 then
        monk.tekura.state.lastEchoTime = now
        return true
    end
    return false
end

-- Centralized send: self-lock-break gate + attackInFlight + queue dispatch.
-- (The Levi target-presence check via ataxia.playersHere is intentionally
-- dropped — we trust that the user only issued `tar X` against a present
-- target.) The bare `sendAttack` below is the file-local SETALIAS/QUEUE helper.
function monk.tekura.sendAttack(cmd)
    if not cmd or cmd == "" then
        return
    end

    -- Lock break check (shared system)
    if selfNeedLockBreak() then
        selfLockBreak()
        return
    end

    monk.tekura.state.attackInFlight = true
    sendAttack(cmd, "FREE")
end

-- Kai surge window (TK6). Call from a trigger that confirms kai surge fired
-- ("target can't remount"). Clears after CONFIG.kaiSurgeWindowDuration seconds.
function monk.tekura.startKaiSurgeWindow()
    monk.tekura.state.kaiSurgeWindow = true
    if monk.tekura.state._kaiSurgeTimer then
        killTimer(monk.tekura.state._kaiSurgeTimer)
    end
    monk.tekura.state._kaiSurgeTimer = tempTimer(monk.tekura.CONFIG.kaiSurgeWindowDuration, function()
        monk.tekura.state.kaiSurgeWindow = false
        monk.tekura.state._kaiSurgeTimer = nil
    end)
end

-- Bear stance is set after the double-break (via ;brs -> /brs). Was
-- ataxia.vitals.stance == "Bear".
function monk.tekura.isInBearStance()
    return charstat("Stance") == "Bear"
end

-- ============================================================
--  MODE SELECTION
-- ============================================================
function monk.tekura.setMode(mode)
    local valid = {
        tkd = true,
        tk6 = true
    }
    if valid[mode] then
        monk.tekura.mode = mode
        cecho("\n<cyan>[Tekura] Mode set to: <yellow>" .. mode:upper())
    else
        cecho("\n<red>[Tekura] Invalid mode. Use: tkd, tk6")
    end
end

-- ============================================================
--  TK6 DYNAMIC LIMB DAMAGE  ("limb hits updated" event)
-- ============================================================
-- Captures actual kick/punch damage from combat. Kicks do ~18-25%, punches
-- do ~14-15%; classify at the 16% boundary. Preserved verbatim from the
-- source — depends on AK's limb triggers raising "limb hits updated".
function monk.tekura.onLimbHitUpdated(event, name, limb, amount)
    if not target or type(target) ~= "string" or name:lower() ~= target:lower() then
        return
    end
    if not amount or type(amount) ~= "number" then
        return
    end
    if amount > 16 then
        monk.tekura.state.kickDamage = amount
    else
        monk.tekura.state.punchDamage = amount
    end
end

if monk.tekura._eventHandler then
    killAnonymousEventHandler(monk.tekura._eventHandler)
end
monk.tekura._eventHandler = registerAnonymousEventHandler("limb hits updated", "monk.tekura.onLimbHitUpdated")

-- ============================================================================
-- ============================================================================
--  TKD MODE  (3-limb backbreaker — from 001_Tekura_Offense.lua)
--  Kill Route: Torso Prep -> Leg Prep -> Break Torso (HRS)
--              -> WRT Double Break (BRS) -> BBT
--  Alternative: SCYTHE kill via Telepathy
-- ============================================================================
-- ============================================================================
local tkdMode = {}

-- ── WOULD-BREAK GUARD (DWC pattern: prevents accidental breaks during PREP) ──
-- Check if next combo attack would break a limb prematurely.
-- punchDamage = HFP (14%), kickDamage varies by attack (SDK=25, SNK=25)
function tkdMode.wouldBreakLimb(limb, attackDamage)
    local damage = getLimbDamage(limb)
    if damage <= 0 then
        return false
    end
    attackDamage = attackDamage or 14 -- default to HFP punch damage
    return (damage + attackDamage) >= monk.tekura.CONFIG.breakThreshold
end

-- ── CONDITION CHECKS ─────────────────────────────────────────
-- Check if torso is prepped (one punch away from breaking, or wouldBreak)
function tkdMode.checkTorsoPrepped()
    local torsoDmg = getLimbDamage("torso")
    if torsoDmg >= monk.tekura.CONFIG.prepThreshold and torsoDmg < monk.tekura.CONFIG.breakThreshold then
        return true
    end
    -- Treat near-break limbs as prepped to prevent accidental breaks during PREP
    return tkdMode.wouldBreakLimb("torso", 14)
end

-- Check if torso is broken
function tkdMode.checkTorsoBroken()
    local torsoDmg = getLimbDamage("torso")
    return torsoDmg >= monk.tekura.CONFIG.breakThreshold or has("damagedtorso")
end

-- Check if a specific leg is prepped (one punch away from breaking, or wouldBreak)
function tkdMode.checkLegPrepped(leg)
    local limbName = leg .. " leg"
    local legDmg = getLimbDamage(limbName)
    if legDmg >= monk.tekura.CONFIG.prepThreshold and legDmg < monk.tekura.CONFIG.breakThreshold then
        return true
    end
    -- Treat near-break limbs as prepped to prevent accidental breaks during PREP
    return tkdMode.wouldBreakLimb(limbName, 14)
end

-- Check if both legs are prepped
function tkdMode.checkBothLegsPrepped()
    return tkdMode.checkLegPrepped("left") and tkdMode.checkLegPrepped("right")
end

-- Check if both legs are broken
function tkdMode.checkBothLegsBroken()
    local llDmg = getLimbDamage("left leg")
    local rlDmg = getLimbDamage("right leg")
    return llDmg >= monk.tekura.CONFIG.breakThreshold and rlDmg >= monk.tekura.CONFIG.breakThreshold
end

-- Check if ALL are prepped (torso + both legs)
function tkdMode.checkAllPrepped()
    return tkdMode.checkTorsoPrepped() and tkdMode.checkBothLegsPrepped()
end

-- Check if SCYTHE kill route is ready.
-- "battered" was a never-reliably-set global in Levi; replaced with the
-- composite affliction check that `mind batter` lands.
function tkdMode.checkScytheReady()
    local hasBattered = has("stupidity") and has("epilepsy") and has("dizziness")
    local hasDamagedHead = has("damagedhead")
    local isProne = has("prone")
    return hasBattered and hasDamagedHead and isProne
end

-- Check if target has shield
function tkdMode.checkShield()
    return has("shield") or false
end

-- Check if target has rebounding
function tkdMode.checkRebounding()
    return has("rebounding") or false
end

-- Check if target is parrying legs
function tkdMode.checkParryingLegs()
    local parried = targetparry or "none"
    return parried == "left leg" or parried == "right leg"
end

-- Get parried limb
function tkdMode.getParried()
    return targetparry or "none"
end

-- Check if parrying head (for SCYTHE route)
function tkdMode.checkParryingHead()
    return targetparry == "head"
end

-- Check if parrying torso
function tkdMode.checkParryingTorso()
    return targetparry == "torso"
end

-- Check if parrying any arm
function tkdMode.checkParryingArms()
    local parried = targetparry or "none"
    return parried == "left arm" or parried == "right arm"
end

-- ── PHASE DETECTION ──────────────────────────────────────────
function tkdMode.getPhase()
    -- SCYTHE: Alternative kill (if enabled and ready)
    if monk.tekura.state.preferScythe and tkdMode.checkScytheReady() then
        return monk.tekura.PHASES.TKD.SCYTHE
    end

    -- KILL: In Bear stance AND target is prone → BBT
    -- Bear stance means we already completed break phases
    if monk.tekura.isInBearStance() and has("prone") then
        return monk.tekura.PHASES.TKD.KILL
    end

    -- DOUBLE_BREAK: Torso is broken, both legs prepped, in Horse stance
    -- WRT arm will prone AND break legs
    if tkdMode.checkTorsoBroken() and tkdMode.checkBothLegsPrepped() then
        return monk.tekura.PHASES.TKD.DOUBLE_BREAK
    end

    -- TORSO_BREAK: ALL are prepped (torso + both legs), break torso and go to Horse
    if tkdMode.checkAllPrepped() then
        return monk.tekura.PHASES.TKD.TORSO_BREAK
    end

    -- LEG_PREP: Torso is prepped but legs need prep
    if tkdMode.checkTorsoPrepped() and not tkdMode.checkBothLegsPrepped() then
        return monk.tekura.PHASES.TKD.LEG_PREP
    end

    -- TORSO_PREP: Default - prep torso first
    return monk.tekura.PHASES.TKD.TORSO_PREP
end

function tkdMode.getPhaseName(phase)
    return monk.tekura.PHASE_NAMES.TKD[phase] or "UNKNOWN"
end

-- ── TARGETING ────────────────────────────────────────────────
-- Get focus leg (lower damage, avoid parry)
function tkdMode.getFocusLeg()
    local parried = targetparry or "none"

    -- If target is prone or paralyzed, parry doesn't matter
    if has("prone") or has("paralysis") then
        parried = "none"
    end

    -- Get leg damage from lb[target].hits
    local llDmg = getLimbDamage("left leg")
    local rlDmg = getLimbDamage("right leg")

    -- Focus the leg with LESS damage (to balance prep)
    local focusLeft = llDmg <= rlDmg

    -- But if that leg is parried, switch
    if focusLeft and parried == "left leg" then
        return "right"
    elseif not focusLeft and parried == "right leg" then
        return "left"
    end

    return focusLeft and "left" or "right"
end

-- Get other leg
function tkdMode.getOtherLeg(leg)
    return leg == "left" and "right" or "left"
end

-- Get arm to WRT (avoid parried arm)
function tkdMode.getWrtArm()
    local parried = targetparry or "none"

    if parried == "left arm" then
        return "right"
    elseif parried == "right arm" then
        return "left"
    end
    return "left" -- default to left arm
end

-- ── ATTACK BUILDERS ──────────────────────────────────────────
-- PHASE 1: Torso Prep - SDK HKP HKP (or handle parry)
-- Break guard: simulated damage prevents accidental breaks within a single combo
function tkdMode.buildTorsoPrepAttack()
    local parried = tkdMode.getParried()
    local breakAt = monk.tekura.CONFIG.breakThreshold

    -- If they're parrying torso or a leg, prep legs with SWK + break-guarded punches
    if parried == "torso" or parried == "left leg" or parried == "right leg" then
        local p1 = tkdMode.wouldBreakLimb("left leg", 14) and "jbp" or "hfp left"
        local p2 = tkdMode.wouldBreakLimb("right leg", 14) and "jbp" or "hfp right"
        return "combo " .. target .. " swk " .. p1 .. " " .. p2
    end

    -- Normal torso prep with simulated damage guard
    local sim = getLimbDamage("torso")

    -- SDK (25% to torso)
    local kickStr
    if (sim + 25) < breakAt then
        kickStr = "sdk"
        sim = sim + 25
    else
        kickStr = "rhk"
    end

    -- HKP punch 1 (14% to torso)
    local p1Str
    if (sim + 14) < breakAt then
        p1Str = "hkp"
        sim = sim + 14
    else
        p1Str = "jbp"
    end

    -- HKP punch 2 (14% to torso)
    local p2Str
    if (sim + 14) < breakAt then
        p2Str = "hkp"
    else
        p2Str = "jbp"
    end

    return "combo " .. target .. " " .. kickStr .. " " .. p1Str .. " " .. p2Str
end

-- PHASE 2: Leg Prep - SNK HFP HFP (or handle parry)
-- Break guard: simulated damage prevents accidental breaks within a single combo
function tkdMode.buildLegPrepAttack()
    local parried = tkdMode.getParried()
    local focus = tkdMode.getFocusLeg()
    local other = tkdMode.getOtherLeg(focus)
    local focusLimb = focus .. " leg"
    local otherLimb = other .. " leg"
    local breakAt = monk.tekura.CONFIG.breakThreshold

    -- If parrying a leg, use SWK with break-guarded punches
    if parried == "left leg" or parried == "right leg" then
        local p1 = tkdMode.wouldBreakLimb("left leg", 14) and "jbp" or "hfp left"
        local p2 = tkdMode.wouldBreakLimb("right leg", 14) and "jbp" or "hfp right"
        return "combo " .. target .. " swk " .. p1 .. " " .. p2
    end

    -- Normal leg prep with simulated damage guard
    local simFocus = getLimbDamage(focusLimb)
    local simOther = getLimbDamage(otherLimb)

    -- SNK kick (25% damage) — pick safe target, prefer focus
    local kickStr
    if (simFocus + 25) < breakAt then
        kickStr = "snk " .. focus
        simFocus = simFocus + 25
    elseif (simOther + 25) < breakAt then
        kickStr = "snk " .. other
        simOther = simOther + 25
    else
        kickStr = "rhk"
    end

    -- HFP punch 1 (14% damage) — prefer focus
    local p1Str
    if (simFocus + 14) < breakAt then
        p1Str = "hfp " .. focus
        simFocus = simFocus + 14
    elseif (simOther + 14) < breakAt then
        p1Str = "hfp " .. other
        simOther = simOther + 14
    else
        p1Str = "jbp"
    end

    -- HFP punch 2 (14% damage) — prefer other for balance
    local p2Str
    if (simOther + 14) < breakAt then
        p2Str = "hfp " .. other
    elseif (simFocus + 14) < breakAt then
        p2Str = "hfp " .. focus
    else
        p2Str = "jbp"
    end

    return "combo " .. target .. " " .. kickStr .. " " .. p1Str .. " " .. p2Str
end

-- PHASE 3: Torso Break - SDK HKP HKP;HRS (break torso, switch to Horse)
function tkdMode.buildTorsoBreakAttack()
    local parried = tkdMode.getParried()

    -- If they're parrying torso, sweep to prone (can't parry) then break torso
    if parried == "torso" then
        return "combo " .. target .. " swk hkp hkp/hrs"
    end

    -- Normal / leg parry: break torso and switch to Horse
    return "combo " .. target .. " sdk hkp hkp/hrs"
end

-- PHASE 4: Double Break - WRT arm HFP left HFP right;BRS
-- This prones AND breaks both legs, then switches to Bear
function tkdMode.buildDoubleBreakAttack()
    local wrtArm = tkdMode.getWrtArm()

    -- WRT arm throws to ground (prones) + HFP breaks both legs
    -- Then switch to Bear stance for BBT
    return "combo " .. target .. " wrt " .. wrtArm .. " arm hfp left hfp right/brs"
end

-- PHASE 5: Kill - BBT until dead (in Bear stance)
function tkdMode.buildKillAttack()
    -- BBT requires Bear stance for great modifier
    -- NEVER BBT unless in Bear stance
    return "bbt " .. target
end

-- PHASE 6: SCYTHE - Telepathy kill alternative
function tkdMode.buildScytheAttack()
    return "mind scythe " .. target
end

-- Select attack based on current phase
function tkdMode.selectAttack()
    local phase = tkdMode.getPhase()

    if phase == monk.tekura.PHASES.TKD.TORSO_PREP then
        return tkdMode.buildTorsoPrepAttack()
    elseif phase == monk.tekura.PHASES.TKD.LEG_PREP then
        return tkdMode.buildLegPrepAttack()
    elseif phase == monk.tekura.PHASES.TKD.TORSO_BREAK then
        return tkdMode.buildTorsoBreakAttack()
    elseif phase == monk.tekura.PHASES.TKD.DOUBLE_BREAK then
        return tkdMode.buildDoubleBreakAttack()
    elseif phase == monk.tekura.PHASES.TKD.KILL then
        return tkdMode.buildKillAttack()
    elseif phase == monk.tekura.PHASES.TKD.SCYTHE then
        return tkdMode.buildScytheAttack()
    end

    -- Default fallback
    return tkdMode.buildTorsoPrepAttack()
end

-- ── MAIN DISPATCH (TKD) ──────────────────────────────────────
function tkdMode.run()
    -- Safety check for target
    if not target or target == "" then
        cecho("\n<red>[TKD] No target set! Use: tar <name>")
        return
    end

    -- Aeon check: don't dispatch under aeon (DWB pattern)
    if selfAff("aeon") then
        cecho("\n<yellow>[TKD] <red>AEON - skipping dispatch")
        return
    end

    -- Target-change detection: auto-reset on new target (DWB pattern)
    if monk.tekura.state.lastTarget ~= target then
        monk.tekura.state.attackInFlight = false
        monk.tekura.state.lastTarget = target
    end

    -- Get current phase
    local phase = tkdMode.getPhase()
    local phaseName = tkdMode.getPhaseName(phase)

    -- Get parry status
    local parried = tkdMode.getParried()

    -- Debounced echo (0.3s guard prevents spam on rapid mashing)
    if monk.tekura.shouldEcho() then
        local torsoDmg = getLimbDamage("torso")
        local llDmg = getLimbDamage("left leg")
        local rlDmg = getLimbDamage("right leg")

        cecho("\n<yellow>[TKD " .. phaseName .. "]<reset> ")
        cecho("T:<cyan>" .. string.format("%.0f", torsoDmg) .. "%<reset> ")
        cecho("LL:<cyan>" .. string.format("%.0f", llDmg) .. "%<reset> ")
        cecho("RL:<cyan>" .. string.format("%.0f", rlDmg) .. "%<reset> ")
        cecho("Prone:<" .. (has("prone") and "green>YES" or "red>NO") .. "<reset>")
        if parried ~= "none" then
            cecho(" <red>PARRY:" .. parried .. "<reset>")
        end
    end

    -- Build command (combatQueue prefix removed — Legacy handles pre-attack hooks)
    local cmd = ""

    -- Handle shield (raze with RHK - roundhouse kick; monk bypasses rebounding)
    if tkdMode.checkShield() then
        cmd = cmd .. "unwield all/dismount/combo " .. target .. " rhk hkp hkp"
        monk.tekura.sendAttack(cmd)
        if monk.tekura.shouldEcho() then
            cecho("\n<yellow>[TKD] RAZING SHIELD")
        end
        return
    end

    -- Build attack based on phase
    local attack = tkdMode.selectAttack()

    -- Construct full command
    cmd = cmd .. "unwield all/dismount/" .. attack

    -- Queue command via centralized send
    monk.tekura.sendAttack(cmd)

    -- Update state
    monk.tekura.state.lastAttackTime = os.time()
end

-- ── STATUS DISPLAY (TKD) ─────────────────────────────────────
function tkdMode.status()
    local phase = tkdMode.getPhase()
    local phaseName = tkdMode.getPhaseName(phase)
    local hfpDamage = 14

    -- Get limb damage from lb[target].hits
    local torsoDmg = getLimbDamage("torso")
    local llDmg = getLimbDamage("left leg")
    local rlDmg = getLimbDamage("right leg")
    local headDmg = getLimbDamage("head")

    -- Progress bar helper
    local function progressBar(pct, width)
        width = width or 10
        local filled = math.floor((pct / 100) * width)
        if filled > width then
            filled = width
        end
        if filled < 0 then
            filled = 0
        end
        return string.rep("#", filled) .. string.rep("-", width - filled)
    end

    -- Prep status helper (prepped = one HFP away from breaking)
    local function prepStatus(pct)
        if pct >= 100 then
            return "<green>BROKEN "
        elseif pct + hfpDamage >= 100 then
            return "<yellow>PREPPED"
        else
            return "<red>       "
        end
    end

    cecho("\n<yellow>+============================================+")
    cecho("\n<yellow>|       <white>TEKURA BACKBREAKER DISPATCH<yellow>        |")
    cecho("\n<yellow>+============================================+")
    cecho("\n<yellow>| <white>Target: <cyan>" .. string.format("%-16s", tostring(target or "None")))
    cecho("<white>Phase: <green>" .. phaseName)
    cecho("\n<yellow>+--------------------------------------------+")
    cecho("\n<yellow>| <white>LIMB STATUS (prepped = 1 punch from break):<yellow>")
    cecho("\n<yellow>|   <white>Torso: " .. prepStatus(torsoDmg) .. string.format("%5.1f%%", torsoDmg) ..
              "<reset> [<cyan>" .. progressBar(torsoDmg) .. "<reset>]")
    cecho("\n<yellow>|   <white>L Leg: " .. prepStatus(llDmg) .. string.format("%5.1f%%", llDmg) .. "<reset> [<cyan>" ..
              progressBar(llDmg) .. "<reset>]")
    cecho("\n<yellow>|   <white>R Leg: " .. prepStatus(rlDmg) .. string.format("%5.1f%%", rlDmg) .. "<reset> [<cyan>" ..
              progressBar(rlDmg) .. "<reset>]")
    cecho("\n<yellow>|   <white>Head:  " .. prepStatus(headDmg) .. string.format("%5.1f%%", headDmg) ..
              "<reset> [<magenta>" .. progressBar(headDmg) .. "<reset>] <grey>(SCYTHE)")
    cecho("\n<yellow>+--------------------------------------------+")
    cecho("\n<yellow>| <white>CONDITIONS:<yellow>")
    cecho("\n<yellow>|   <white>Prone: " .. (has("prone") and "<green>YES" or "<red>NO"))
    cecho("      <white>Parried: <cyan>" .. (targetparry or "none"))
    cecho("\n<yellow>|   <white>All Prepped: " .. (tkdMode.checkAllPrepped() and "<green>YES" or "<red>NO"))
    cecho("  <white>Torso Broken: " .. (tkdMode.checkTorsoBroken() and "<green>YES" or "<red>NO"))
    cecho("\n<yellow>|   <white>Tracking: <cyan>AK")
    cecho("\n<yellow>+--------------------------------------------+")
    cecho("\n<yellow>| <white>KILL ROUTES:<yellow>")
    cecho("\n<yellow>|   <white>BBT Ready: " ..
              (monk.tekura.isInBearStance() and has("prone") and "<green>YES" or "<red>NO"))
    cecho("    <white>SCYTHE Ready: " .. (tkdMode.checkScytheReady() and "<magenta>YES" or "<grey>NO"))
    cecho("\n<yellow>|   <white>SCYTHE Mode: " ..
              (monk.tekura.state.preferScythe and "<magenta>ENABLED" or "<grey>DISABLED"))
    cecho("\n<yellow>+--------------------------------------------+")
    cecho("\n<yellow>| <white>STRATEGY:<yellow>")
    cecho("\n<yellow>|   " .. (phase == 1 and "<white>" or "<grey>") .. "1. TORSO_PREP: SDK HKP HKP")
    cecho("\n<yellow>|   " .. (phase == 2 and "<white>" or "<grey>") .. "2. LEG_PREP: SNK HFP HFP (SWK if parry)")
    cecho("\n<yellow>|   " .. (phase == 3 and "<white>" or "<grey>") .. "3. TORSO_BREAK: SDK HKP HKP -> HRS")
    cecho("\n<yellow>|   " .. (phase == 4 and "<white>" or "<grey>") .. "4. DOUBLE_BREAK: WRT arm HFP HFP -> BRS")
    cecho("\n<yellow>|   " .. (phase == 5 and "<green>" or "<grey>") .. "5. KILL: BBT until dead (BRS)")
    cecho("\n<yellow>|   " .. (phase == 6 and "<magenta>" or "<grey>") .. "ALT: SCYTHE if head prepped + battered")
    cecho("\n<yellow>+============================================+\n")
end

-- ============================================================================
-- ============================================================================
--  TK6 MODE  (6-limb backbreaker — from 002_Tekura_6Limb_Offense.lua)
--  Kill Route: Prep ALL 6 limbs -> Break Arms+Torso (HRS)
--              -> WRT Torso + Break Legs (BRS) -> BBT
--  Parry Avoidance:
--    - During PREP: skip parried limb, target others
--    - Last limb parried: kai surge (dismount) -> sweep (prones) -> punch last limb
-- ============================================================================
-- ============================================================================
local tk6Mode = {}

-- ── WOULD-BREAK GUARD (DWC pattern) ──────────────────────────
function tk6Mode.wouldBreakLimb(limb, attackDamage)
    local damage = getLimbDamage(limb)
    if damage <= 0 then
        return false
    end
    attackDamage = attackDamage or monk.tekura.state.punchDamage
    return (damage + attackDamage) >= monk.tekura.CONFIG.breakThreshold
end

-- ── HELPERS ──────────────────────────────────────────────────
-- Dynamic prep threshold based on actual punch damage
function tk6Mode.getPrepThreshold()
    return monk.tekura.CONFIG.breakThreshold - monk.tekura.state.punchDamage
end

-- Check if a specific limb is prepped (one punch from break, dynamic threshold)
function tk6Mode.isLimbPrepped(limb)
    return getLimbDamage(limb) >= tk6Mode.getPrepThreshold()
end

-- Check if a specific limb is broken (100%+)
function tk6Mode.isLimbBroken(limb)
    return getLimbDamage(limb) >= monk.tekura.CONFIG.breakThreshold
end

-- Check if ALL 6 limbs are prepped (86%+)
function tk6Mode.checkAllSixPrepped()
    for _, limb in ipairs(monk.tekura.ALL_LIMBS) do
        if not tk6Mode.isLimbPrepped(limb) then
            return false
        end
    end
    return true
end

-- Get list of unprepped limbs (below 86%)
function tk6Mode.getUnpreppedLimbs()
    local unprepped = {}
    for _, limb in ipairs(monk.tekura.ALL_LIMBS) do
        if not tk6Mode.isLimbPrepped(limb) then
            table.insert(unprepped, limb)
        end
    end
    return unprepped
end

-- Get parried limb from existing tracking
function tk6Mode.getParried()
    return targetparry or "none"
end

-- Check if target can parry (cannot parry while prone or paralyzed)
function tk6Mode.canTargetParry()
    if has("prone") or has("paralysis") then
        return false
    end
    return true
end

-- Get effective parried limb (accounts for prone/paralysis)
function tk6Mode.getEffectiveParry()
    if not tk6Mode.canTargetParry() then
        return "none"
    end
    return tk6Mode.getParried()
end

-- Check if target has shield
function tk6Mode.checkShield()
    return has("shield") or false
end

-- Check if target has rebounding
function tk6Mode.checkRebounding()
    return has("rebounding") or false
end

-- Check if target is mounted
function tk6Mode.isMounted()
    return has("mounted") or false
end

-- Echo helper with tag
function tk6Mode.echo(text)
    cecho("\n<yellow>[TK6]<reset> " .. text)
end

-- ── PHASE DETECTION ──────────────────────────────────────────
function tk6Mode.getPhase()
    local armsBroken = tk6Mode.isLimbBroken("left arm") and tk6Mode.isLimbBroken("right arm")
    local torsoBroken = tk6Mode.isLimbBroken("torso")
    local bothLegsBroken = tk6Mode.isLimbBroken("left leg") and tk6Mode.isLimbBroken("right leg")

    -- KILL: In Bear stance AND target is prone → BBT
    -- Bear stance means we already completed break phases
    if monk.tekura.isInBearStance() and has("prone") then
        return monk.tekura.PHASES.TK6.KILL
    end

    -- BREAK_LOWER: Both arms + torso broken (from BREAK_UPPER), legs NOT yet both broken
    if armsBroken and torsoBroken and not bothLegsBroken then
        return monk.tekura.PHASES.TK6.BREAK_LOWER
    end

    -- BREAK_UPPER: All 6 prepped (86%+), need to break arms + torso
    if tk6Mode.checkAllSixPrepped() then
        return monk.tekura.PHASES.TK6.BREAK_UPPER
    end

    -- PREP: Default
    return monk.tekura.PHASES.TK6.PREP
end

function tk6Mode.getPhaseName(phase)
    return monk.tekura.PHASE_NAMES.TK6[phase] or "UNKNOWN"
end

-- ── COMBO BUILDERS ───────────────────────────────────────────
-- PREP: Dynamic combo builder with parry avoidance and overflow prevention
-- RULE: Never break a limb before all 6 are prepped.
-- Priority: non-parried unprepped > parried unprepped > non-parried prepped (safe overflow) > parried prepped
-- SPREAD: Kick and punches target different limbs when possible (opponent can only parry 1 of 3)
function tk6Mode.buildPrepAttack()
    -- Use raw parry (not effective parry) during PREP — always avoid the parried limb
    -- regardless of prone/paralysis tracking. Zero cost: we just prep a different limb instead.
    local parried = tk6Mode.getParried()
    local unprepped = tk6Mode.getUnpreppedLimbs()
    local kickDmg = monk.tekura.state.kickDamage
    local punchDmg = monk.tekura.state.punchDamage
    local breakAt = monk.tekura.CONFIG.breakThreshold

    -- KAI SURGE WINDOW: target can't remount for 15s — sweep + double-punch the parried limb
    -- Parry bypassed because sweep prones them; use the window to prep the stuck limb.
    if monk.tekura.state.kaiSurgeWindow and parried ~= "none" then
        return tk6Mode.buildParryBypassAttack(parried)
    end

    -- EDGE CASE: Only 1 unprepped limb and it's parried
    if #unprepped == 1 and unprepped[1] == parried then
        return tk6Mode.buildParryBypassAttack(unprepped[1])
    end

    -- EDGE CASE: No unprepped limbs (shouldn't reach here, phase would be BREAK)
    if #unprepped == 0 then
        return "combo " .. target .. " sdk hkp hkp"
    end

    -- Build TWO candidate lists + simulated damage for ALL non-broken limbs
    local unprepCandidates = {} -- unprepped limbs (priority targets)
    local overflowCandidates = {} -- prepped-but-not-broken limbs (safe overflow)
    local simDmg = {}
    for _, limb in ipairs(monk.tekura.ALL_LIMBS) do
        if not tk6Mode.isLimbBroken(limb) then
            simDmg[limb] = getLimbDamage(limb)
            if not tk6Mode.isLimbPrepped(limb) then
                table.insert(unprepCandidates, limb)
            else
                table.insert(overflowCandidates, limb)
            end
        end
    end

    -- Helper: find the best safe limb for an attack of given damage
    -- Searches preferred list first, then fallback list
    -- Within each list: non-parried first, then parried
    -- skipLimb: optional limb to deprioritize (for attack spread)
    local function findSafeLimb(preferred, fallback, atkDmg, skipLimb)
        -- Sort both lists by simulated damage ascending (lowest first)
        -- Tiebreaker: prefer right limbs when damage is equal (right gets prepped last,
        -- so restoration heals left first and right stays broken longer)
        local function limbSort(a, b)
            local da, db = (simDmg[a] or 0), (simDmg[b] or 0)
            if da == db then
                return a:find("right") and not b:find("right")
            end
            return da < db
        end
        table.sort(preferred, limbSort)
        table.sort(fallback, limbSort)

        -- Pass 1: non-parried, non-skipped preferred (best targets)
        for _, limb in ipairs(preferred) do
            if limb ~= parried and limb ~= skipLimb and (simDmg[limb] or 0) + atkDmg < breakAt then
                return limb
            end
        end
        -- Pass 2: non-parried, skipped preferred (spread failed, same limb is ok)
        if skipLimb then
            for _, limb in ipairs(preferred) do
                if limb ~= parried and limb == skipLimb and (simDmg[limb] or 0) + atkDmg < breakAt then
                    return limb
                end
            end
        end
        -- Pass 3: parried preferred (better to waste on parried than break)
        for _, limb in ipairs(preferred) do
            if limb == parried and (simDmg[limb] or 0) + atkDmg < breakAt then
                return limb
            end
        end
        -- Pass 4: non-parried, non-skipped overflow (prepped, safe waste)
        for _, limb in ipairs(fallback) do
            if limb ~= parried and limb ~= skipLimb and (simDmg[limb] or 0) + atkDmg < breakAt then
                return limb
            end
        end
        -- Pass 5: non-parried, skipped overflow
        if skipLimb then
            for _, limb in ipairs(fallback) do
                if limb ~= parried and limb == skipLimb and (simDmg[limb] or 0) + atkDmg < breakAt then
                    return limb
                end
            end
        end
        -- Pass 6: parried overflow
        for _, limb in ipairs(fallback) do
            if limb == parried and (simDmg[limb] or 0) + atkDmg < breakAt then
                return limb
            end
        end
        return nil
    end

    -- KICK: Find safe kick target
    local kickStr
    local kickLimb = findSafeLimb(unprepCandidates, overflowCandidates, kickDmg)
    if kickLimb then
        kickStr = monk.tekura.LIMB_ATTACKS[kickLimb].kick
        simDmg[kickLimb] = (simDmg[kickLimb] or 0) + kickDmg
        monk.tekura.state.lastKickLimb = kickLimb -- Direct parry tracking (bypasses queue)
    else
        -- No safe kick target (all limbs would break) — use RHK as filler (no limb damage)
        kickStr = "rhk"
        monk.tekura.state.lastKickLimb = nil
    end

    -- PUNCHES: Find two safe punch targets, spread across different limbs than kick
    -- skipLimb = kickLimb forces punches to different limbs when alternatives exist
    local punchA, punchB -- raw targets (nil = filler)

    local punchALimb = findSafeLimb(unprepCandidates, overflowCandidates, punchDmg, kickLimb)
    if punchALimb then
        punchA = monk.tekura.LIMB_ATTACKS[punchALimb].punch
        simDmg[punchALimb] = (simDmg[punchALimb] or 0) + punchDmg
    end

    -- Second punch also tries to avoid kick limb AND first punch limb for max spread
    local skipForPunchB = kickLimb
    if punchALimb and punchALimb ~= kickLimb then
        -- First punch already spread from kick — try to spread from punch1 too
        skipForPunchB = punchALimb
    end
    local punchBLimb = findSafeLimb(unprepCandidates, overflowCandidates, punchDmg, skipForPunchB)
    if punchBLimb then
        punchB = monk.tekura.LIMB_ATTACKS[punchBLimb].punch
    end

    -- Order: JBP filler always goes first (disables parry for the following real punch)
    local punch1Str, punch2Str
    if punchA and punchB then
        -- Both real punches — no reorder needed
        punch1Str, punch2Str = punchA, punchB
    elseif punchA and not punchB then
        -- One real, one filler — jbp first, real punch second (benefits from parry disable)
        punch1Str, punch2Str = "jbp", punchA
    elseif not punchA and punchB then
        punch1Str, punch2Str = "jbp", punchB
    else
        -- Both fillers
        punch1Str, punch2Str = "jbp", "jbp"
    end

    return "combo " .. target .. " " .. kickStr .. " " .. punch1Str .. " " .. punch2Str
end

-- PARRY BYPASS: Kai surge (dismount) + sweep (prone) + punch last limb
-- Break guard: if 2 punches would break, use 1 real punch + overflow/filler
function tk6Mode.buildParryBypassAttack(parriedLimb)
    local cmd = ""
    local punchDmg = monk.tekura.state.punchDamage
    local breakAt = monk.tekura.CONFIG.breakThreshold
    local currentDmg = getLimbDamage(parriedLimb)

    -- Kai dismount if mounted (required for sweep)
    if tk6Mode.isMounted() then
        cmd = "kai " .. monk.tekura.CONFIG.kaiMode .. " " .. target .. "/"
    end

    monk.tekura.state.lastKickLimb = nil -- Sweep doesn't target a specific limb

    local punch = monk.tekura.LIMB_ATTACKS[parriedLimb].punch

    -- Check if TWO punches would break the limb
    if (currentDmg + 2 * punchDmg) >= breakAt then
        -- Only 1 punch on the parried limb; find overflow for 2nd punch
        local overflow = nil
        for _, limb in ipairs(monk.tekura.ALL_LIMBS) do
            if limb ~= parriedLimb and not tk6Mode.isLimbBroken(limb) and (getLimbDamage(limb) + punchDmg) < breakAt then
                overflow = limb
                break
            end
        end

        if overflow then
            -- Sweep prones (no parry), so real punch first, overflow second
            cmd = cmd .. "combo " .. target .. " swk " .. punch .. " " .. monk.tekura.LIMB_ATTACKS[overflow].punch
        else
            -- No safe overflow — use filler for 2nd punch
            cmd = cmd .. "combo " .. target .. " swk " .. punch .. " jbp"
        end
    else
        -- Safe to double-punch (won't break)
        cmd = cmd .. "combo " .. target .. " swk " .. punch .. " " .. punch
    end

    return cmd
end

-- BREAK_UPPER: Break torso + both arms in Scorpion stance, then switch to Horse
-- SDK (torso kick) + SPP left + SPP right: all 3 upper limbs break in one combo.
-- Stay in Scorpion stance for the combo — hrs fires after to transition.
function tk6Mode.buildBreakUpperAttack()
    monk.tekura.state.lastKickLimb = "torso"
    return "combo " .. target .. " sdk spp left spp right/hrs"
end

-- BREAK_LOWER: Wrench torso (prones) + break both legs, switch to Bear stance
function tk6Mode.buildBreakLowerAttack()
    -- WRT torso (Horse stance, prones target) + HFP left + HFP right (break both legs)
    monk.tekura.state.lastKickLimb = "torso"
    return "combo " .. target .. " wrt torso hfp left hfp right/brs"
end

-- KILL: Backbreaker in Bear stance
function tk6Mode.buildKillAttack()
    monk.tekura.state.lastKickLimb = nil -- No combo kick
    return "bbt " .. target
end

-- Safe raze punches: during PREP, pick punch targets that won't break any limb
function tk6Mode.safeRazePunches()
    if tk6Mode.getPhase() ~= monk.tekura.PHASES.TK6.PREP then
        return "hkp", "hkp"
    end
    local punchDmg = monk.tekura.state.punchDamage
    local breakAt = monk.tekura.CONFIG.breakThreshold
    local simDmg = {}
    for _, limb in ipairs(monk.tekura.ALL_LIMBS) do
        simDmg[limb] = getLimbDamage(limb)
    end
    local function safePunch()
        for _, limb in ipairs(monk.tekura.ALL_LIMBS) do
            if not tk6Mode.isLimbBroken(limb) and (simDmg[limb] + punchDmg) < breakAt then
                simDmg[limb] = simDmg[limb] + punchDmg
                return monk.tekura.LIMB_ATTACKS[limb].punch
            end
        end
        return "jbp"
    end
    return safePunch(), safePunch()
end

-- ── MAIN DISPATCH (TK6) ──────────────────────────────────────
function tk6Mode.run()
    -- Safety check
    if not target or target == "" then
        cecho("\n<red>[TK6] No target set! Use: tar <name>")
        return
    end

    -- Aeon check: don't dispatch under aeon (DWB pattern)
    if selfAff("aeon") then
        cecho("\n<yellow>[TK6] <red>AEON - skipping dispatch")
        return
    end

    -- Target-change detection: auto-reset on new target (DWB pattern)
    if monk.tekura.state.lastTarget ~= target then
        monk.tekura.state.attackInFlight = false
        monk.tekura.state.lastTarget = target
    end

    -- Get current phase
    local phase = tk6Mode.getPhase()
    local phaseName = tk6Mode.getPhaseName(phase)

    -- Get parry status (raw parry — always show what opponent is parrying)
    local parried = tk6Mode.getParried()

    -- Debounced echo (0.3s guard prevents spam on rapid mashing)
    if monk.tekura.CONFIG.debugEcho and monk.tekura.shouldEcho() then
        local h = getLimbDamage("head")
        local t = getLimbDamage("torso")
        local la = getLimbDamage("left arm")
        local ra = getLimbDamage("right arm")
        local ll = getLimbDamage("left leg")
        local rl = getLimbDamage("right leg")

        cecho("\n<yellow>[TK6 " .. phaseName .. "]<reset> ")
        cecho("H:<cyan>" .. string.format("%.0f", h) .. "%<reset> ")
        cecho("T:<cyan>" .. string.format("%.0f", t) .. "%<reset> ")
        cecho("LA:<cyan>" .. string.format("%.0f", la) .. "%<reset> ")
        cecho("RA:<cyan>" .. string.format("%.0f", ra) .. "%<reset> ")
        cecho("LL:<cyan>" .. string.format("%.0f", ll) .. "%<reset> ")
        cecho("RL:<cyan>" .. string.format("%.0f", rl) .. "%<reset> ")
        cecho("Prone:<" .. (has("prone") and "green>YES" or "red>NO") .. "<reset>")
        cecho(" K:<yellow>" .. string.format("%.1f", monk.tekura.state.kickDamage) .. "<reset>")
        cecho(" P:<yellow>" .. string.format("%.1f", monk.tekura.state.punchDamage) .. "<reset>")
        if parried ~= "none" then
            cecho(" <red>PARRY:" .. parried .. "<reset>")
        end
    end

    -- Build command (combatQueue prefix removed — Legacy handles pre-attack hooks)
    local cmd = ""

    -- SHIELD CHECK: raze with RHK (break-guarded punches during PREP; monk bypasses rebounding)
    if tk6Mode.checkShield() then
        local p1, p2 = tk6Mode.safeRazePunches()
        cmd = cmd .. "unwield all/dismount/combo " .. target .. " rhk " .. p1 .. " " .. p2
        monk.tekura.state.lastKickLimb = nil -- RHK raze, no limb target
        monk.tekura.sendAttack(cmd)
        if monk.tekura.shouldEcho() then
            cecho("\n<yellow>[TK6] RAZING SHIELD")
        end
        return
    end

    -- Build attack based on phase
    local attack
    if phase == monk.tekura.PHASES.TK6.PREP then
        attack = tk6Mode.buildPrepAttack()
    elseif phase == monk.tekura.PHASES.TK6.BREAK_UPPER then
        attack = tk6Mode.buildBreakUpperAttack()
    elseif phase == monk.tekura.PHASES.TK6.BREAK_LOWER then
        attack = tk6Mode.buildBreakLowerAttack()
    elseif phase == monk.tekura.PHASES.TK6.KILL then
        attack = tk6Mode.buildKillAttack()
    else
        attack = tk6Mode.buildPrepAttack()
    end

    -- Construct full command
    if phase == monk.tekura.PHASES.TK6.KILL then
        cmd = cmd .. attack
    else
        cmd = cmd .. "unwield all/dismount/" .. attack
    end

    -- Queue command via centralized send
    monk.tekura.sendAttack(cmd)

    -- Update state
    monk.tekura.state.lastAttackTime = os.time()
end

-- ── STATUS DISPLAY (TK6) ─────────────────────────────────────
function tk6Mode.status()
    local phase = tk6Mode.getPhase()
    local phaseName = tk6Mode.getPhaseName(phase)

    -- Progress bar helper
    local function progressBar(pct, width)
        width = width or 15
        local filled = math.floor((pct / 100) * width)
        if filled > width then
            filled = width
        end
        if filled < 0 then
            filled = 0
        end
        return string.rep("#", filled) .. string.rep("-", width - filled)
    end

    -- Prep status helper (dynamic threshold)
    local prepThresh = tk6Mode.getPrepThreshold()
    local function prepStatus(pct)
        if pct >= 100 then
            return "<green>BROKEN "
        elseif pct >= prepThresh then
            return "<yellow>PREPPED"
        else
            return "<red>       "
        end
    end

    cecho("\n<yellow>+================================================+")
    cecho("\n<yellow>|       <white>TEKURA 6-LIMB BACKBREAKER DISPATCH<yellow>       |")
    cecho("\n<yellow>+================================================+")
    cecho("\n<yellow>| <white>Target: <cyan>" .. string.format("%-16s", tostring(target or "None")))
    cecho("<white>Phase: <green>" .. phaseName)
    cecho("\n<yellow>+------------------------------------------------+")
    cecho("\n<yellow>| <white>Kick: <cyan>" .. string.format("%.1f%%", monk.tekura.state.kickDamage))
    cecho("  <white>Punch: <cyan>" .. string.format("%.1f%%", monk.tekura.state.punchDamage))
    cecho("  <white>Prep@: <cyan>" .. string.format("%.1f%%", prepThresh))
    cecho("\n<yellow>+------------------------------------------------+")
    cecho("\n<yellow>| <white>LIMB STATUS (prepped = 1 punch from break):<yellow>")

    for _, name in ipairs(monk.tekura.ALL_LIMBS) do
        local dmg = getLimbDamage(name)
        local label = string.format("%-10s", name:sub(1, 1):upper() .. name:sub(2))
        cecho("\n<yellow>|   <white>" .. label .. " " .. prepStatus(dmg) .. string.format("%5.1f%%", dmg) ..
                  "<reset> [<cyan>" .. progressBar(dmg) .. "<reset>]")
    end

    cecho("\n<yellow>+------------------------------------------------+")
    cecho("\n<yellow>| <white>CONDITIONS:<yellow>")
    cecho("\n<yellow>|   <white>Prone: " .. (has("prone") and "<green>YES" or "<red>NO"))
    cecho("      <white>Parried: <cyan>" .. (targetparry or "none"))
    cecho("\n<yellow>|   <white>Mounted: " .. (tk6Mode.isMounted() and "<red>YES" or "<green>NO"))
    cecho("    <white>Shield: " .. (tk6Mode.checkShield() and "<red>YES" or "<green>NO"))
    cecho("\n<yellow>|   <white>Tracking: <cyan>AK")
    cecho("\n<yellow>+------------------------------------------------+")
    cecho("\n<yellow>| <white>ALL 6 PREPPED: " .. (tk6Mode.checkAllSixPrepped() and "<green>YES" or "<red>NO"))
    local unprepped = tk6Mode.getUnpreppedLimbs()
    if #unprepped > 0 then
        cecho("  <white>Remaining: <cyan>" .. #unprepped)
    end
    cecho("\n<yellow>+------------------------------------------------+")
    cecho("\n<yellow>| <white>STRATEGY:<yellow>")
    cecho("\n<yellow>|   " .. (phase == 1 and "<white>" or "<grey>") ..
              "1. PREP: All 6 limbs to 86%+ (kick+punch+punch)")
    cecho("\n<yellow>|   " .. (phase == 2 and "<white>" or "<grey>") ..
              "2. BREAK UPPER: MNK arm + SPP arm + HKP torso -> HRS")
    cecho("\n<yellow>|   " .. (phase == 3 and "<white>" or "<grey>") ..
              "3. BREAK LOWER: WRT torso + HFP left + HFP right -> BRS")
    cecho("\n<yellow>|   " .. (phase == 4 and "<green>" or "<grey>") .. "4. KILL: BBT until dead (Bear Stance)")
    cecho("\n<yellow>+================================================+\n")
end

-- ============================================================
--  UNIFIED ENTRY POINTS (delegate to the active mode)
-- ============================================================
function monk.tekura.dispatch()
    if monk.tekura.mode == "tk6" then
        tk6Mode.run()
    else
        tkdMode.run()
    end
end

function monk.tekura.status()
    if monk.tekura.mode == "tk6" then
        tk6Mode.status()
    else
        tkdMode.status()
    end
end

-- Reset runtime state for a new engagement (superset of both modes' resets).
function monk.tekura.reset()
    monk.tekura.state.preferScythe = false
    monk.tekura.state.attackInFlight = false
    monk.tekura.state.lastTarget = nil
    monk.tekura.state.lastAttackTime = 0
    cecho("\n<yellow>[Tekura] State reset<reset>")
end

-- Toggle the TKD SCYTHE (Telepathy) kill route.
function monk.tekura.toggleScythe()
    monk.tekura.state.preferScythe = not monk.tekura.state.preferScythe
    cecho("\n<yellow>[TKD] SCYTHE mode: " ..
              (monk.tekura.state.preferScythe and "<magenta>ENABLED" or "<grey>DISABLED") .. "<reset>")
end

-- ============================================================
--  CONVENIENCE ALIASES (typeable from the Mudlet input line)
-- ============================================================
function tk()
    monk.tekura.dispatch()
end

function tkd()
    monk.tekura.setMode("tkd")
    monk.tekura.dispatch()
end

function tk6()
    monk.tekura.setMode("tk6")
    monk.tekura.dispatch()
end

function tkstatus()
    monk.tekura.status()
end

function tkreset()
    monk.tekura.reset()
end

function tkscythe()
    monk.tekura.toggleScythe()
end

function tk6debug()
    monk.tekura.CONFIG.debugEcho = not monk.tekura.CONFIG.debugEcho
    cecho("\n<yellow>[TK6] Debug: " .. (monk.tekura.CONFIG.debugEcho and "<green>ON" or "<red>OFF") .. "<reset>")
end
