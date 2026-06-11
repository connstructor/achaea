--[[
================================================================================
SHIKUDO UNIFIED OFFENSE — LEGACY / AK PORT
================================================================================

Consolidation of the four LEVI/Ataxia CC scripts:
  - 006_CC_Shikudo_Dispatch.lua     (limb-prep dispatch kill)
  - 007_CC_Shikudo_Lock.lua         (telepathy affliction lock)
  - 008_CC_Shikudo_Offense_ALL.lua  (the three-mode unifier — source of truth)
  - 009_CC_Shikudo_GodMode.lua      (5-limb prep -> 3-combo execute)

Four modes, one file:
  monk.shikudo.setMode("dispatch")   -- Limb-based kill (legs + head -> sweep -> dispatch)
  monk.shikudo.setMode("lock")       -- Pure affliction lock (soft -> venom -> hard -> true)
  monk.shikudo.setMode("riftlock")   -- Lock + blackout burst (Mystor strategy)
  monk.shikudo.setMode("godmode")    -- 5-limb prep, 3-combo execute, lock/maelstrom forks

Convenience aliases:
  skdispatch(), sklock(), skriftlock(), skgodmode(), skstatus(), skreset()

Public API (everything else is file-local):
  monk.shikudo.CONFIG               table — see CONFIG section
  monk.shikudo.state                table — runtime mutable state
  monk.shikudo.mode                 string — current mode
  monk.shikudo.{formAttacks, transitions, maxKata}  — reference data tables
  monk.shikudo.limbDamage           static table of per-attack % HP damage

  monk.shikudo.setMode(mode)        called by aliases
  monk.shikudo.dispatch()           main entry, called by aliases
  monk.shikudo.status()             called by aliases
  monk.shikudo.reset()              called by aliases
  monk.shikudo.startKaiSurgeWindow()  call from your kai-surge-fired trigger

  (Hyperfocus is read directly from `ak.limbs.hyperfocus` — no public
  setter needed. The dispatch logic emits `hyperfocus head` / `hyperfocus
  none` automatically when state differs from the rule: head iff Oak +
  targetparry=="head", otherwise none.)

  monk.shikudo.godmode.run()        delegate from dispatch when mode=godmode
  monk.shikudo.godmode.status()     called by skgmstatus alias and status()

  monk.telepathy.mindlocked         bool — set by your mindlock-confirmed trigger
  monk.telepathy.starting_mindlock  bool — set when issuing `mind lock X`

--------------------------------------------------------------------------------
DEPENDENCY MAPPING (see ports/legacy_ak/shikudo/DEPENDENCIES.md)
--------------------------------------------------------------------------------
AK (target state):
  tAffs.X                -> has("X")  (reads affstrack.score[X] >= AFF_THRESHOLD)
  haveAff("X")           -> has("X")
  lb[target].hits[limb]  -> unchanged
  ataxiaTemp.parriedLimb -> targetparry (global)
  ataxiaTemp.lastAssess  -> targetHpPct() (ak.currenthealth/maxhealth)
  ataxiaTemp.hyperLimb   -> ak.limbs.hyperfocus
  tCity / Mhaldor branch -> REMOVED (always dispatch)

Legacy (self state):
  ataxia.vitals.form     -> charstat("Form")
  ataxia.vitals.kata     -> charstat("Kata")
  ataxia.vitals.kai      -> charstat("Kai")
  ataxia.vitals.{hp,maxhp,mp,maxmp} -> vital("hp") etc (gmcp.Char.Vitals)
  ataxia.balances.eq     -> eqUp()  (gmcp.Char.Vitals.eq == "1")
  ataxia.settings.separator -> "/"  (hardcoded for SETALIAS ATK pattern)
  ataxia.settings.paused -> Legacy.Settings.Curing.status == false
  ataxia.afflictions.X   -> selfAff("X")  (Legacy.Curing.Affs[X])
  ataxia.defences.X      -> Legacy.Curing.Defs.current.X
  ataxia.shikudoLevel    -> REMOVED (limb damage is target-independent post-normalization)
  ataxiaBasher.enabled   -> Legacy.Settings.Basher.status (read-only)
  ataxiaTemp.kaiSurgeWindow -> monk.shikudo.state.kaiSurgeWindow (set by trigger ->
                              monk.shikudo.startKaiSurgeWindow())
  ataxia_needLockBreak() -> selfNeedLockBreak()  (Monk-collapsed port)
  ataxia_lockBreak()     -> selfLockBreak()      (sends "fitness")
  combatQueue()          -> REMOVED (Legacy handles pre-attack hooks externally)
  send("queue addclear free X")  -> sendAttack(X, "FREE")
  send("queue addclear eqbal X") -> sendAttack(X, "EQBAL")

Telepathy mindlock state:
  mindlocked        -> monk.telepathy.mindlocked
  startingMindlock  -> monk.telepathy.starting_mindlock
  (Triggers must drive these — see NAMESPACE INIT block for the events to bind.)

Namespace summary:
  monk.shikudo.*         — this module (state, config, modes, dispatch, godmode)
  monk.shikudo.limbDamage  — static per-attack % HP damage (post-normalization)
  monk.telepathy.*       — Telepathy mindlock state owned by this module
  External (unchanged):  gmcp, ak, Legacy, target, lb, affstrack, targetparry

================================================================================
]] --
-- ============================================================
--  NAMESPACE INIT
-- ============================================================
-- Module-owned state lives under `monk.*`:
--   monk.shikudo   — this offense module (state, config, modes, godmode)
--   monk.telepathy — Telepathy mindlock state, set by triggers (see below)
-- External dependencies (gmcp, ak, Legacy, target, lb, affstrack,
-- targetparry) remain top-level globals.
monk = monk or {}
monk.shikudo = monk.shikudo or {}
monk.telepathy = monk.telepathy or {}

-- Telepathy mindlock state. Set these from triggers in your profile:
--   "You complete the mind lock on X."   -> monk.telepathy.mindlocked = true
--   "X is no longer mind-locked."        -> monk.telepathy.mindlocked = false
--   send("mind lock X")                  -> monk.telepathy.starting_mindlock = true (with a 3s tempTimer auto-clear)
-- Until you wire those triggers up, lock/riftlock/godmode will redundantly
-- send `mind lock X` every tick — the server rejects duplicates so it's safe.
monk.telepathy.mindlocked = monk.telepathy.mindlocked or false
monk.telepathy.starting_mindlock = monk.telepathy.starting_mindlock or false

monk.shikudo.mode = monk.shikudo.mode or "dispatch"

-- Module-internal state. The pieces that were in `ataxiaTemp` but are really
-- ours (kick alternation flags, slot tracking) live here now. The pieces that
-- belong to other subsystems (parry, hyperfocus, basher) still live in their
-- respective globals.
monk.shikudo.state = monk.shikudo.state or {
    -- Selector state (was ataxiaTemp.*)
    kickTarget = nil, -- limb the kick will hit (for slot1 coordination)
    slot1Target = nil, -- limb the slot-1 staff strike hits
    lastFrontkickArm = "left",
    frontkickWasParried = false,
    lastFlashheelLeg = "left",
    flashheelWasParried = false,

    -- Dispatch state
    phase = "PREP",

    -- Lock state
    lockPhase = "SOFTLOCK",

    -- Riftlock state
    riftPhase = "OAK_SETUP",
    lastBlackout = 0,
    blackoutActive = false,

    -- Kai surge window (set by monk.shikudo.startKaiSurgeWindow(); auto-clears
    -- after 15s via tempTimer). Was ataxiaTemp.kaiSurgeWindow.
    kaiSurgeWindow = false,
    _kaiSurgeTimer = nil
}

-- ============================================================
--  CONFIG  (all tunables consolidated)
-- ============================================================
monk.shikudo.CONFIG = monk.shikudo.CONFIG or {
    -- AK affstrack confidence threshold (0-100). affstrack.score[aff] >= this
    -- counts as "present." 30 matches Levi V3; lean toward assume-present
    -- because false positives are cheap (re-apply) and false negatives are
    -- expensive (skip a kill).
    affThreshold = 30,

    -- Item ID for `wield` send. Replace with your staff's actual ID.
    staffId = "staff193401",

    -- Kai surge window duration in seconds (target can't remount).
    kaiSurgeWindowDuration = 15,

    -- Self lock-break cooldown (seconds) between `fitness` attempts.
    lockBreakCooldown = 2,

    -- ── GODMODE thresholds ─────────────────────────────────────
    -- Limb prep % required before godmode fires the execute combos.
    godmodePrepThreshold = 92,
    -- Lock affs (out of 8) required to fork into Rain lock path.
    godmodeLockForkMinAffs = 3,
    -- Target HP% to flip Gaital -> Maelstrom + crescent override.
    godmodeMaelstromHpThresh = 38
}

-- ============================================================
--  AK HELPERS
-- ============================================================
-- affstrack.score[aff] is a 0-100 confidence value: 100 = fresh apply,
-- lower = ambiguous cure reduced certainty, nil = no evidence.
local function has(aff)
    return affstrack and affstrack.score and (affstrack.score[aff] or 0) >= monk.shikudo.CONFIG.affThreshold
end

-- AK target HP%: was `ataxiaTemp.lastAssess` (already a 0-100 number).
local function targetHpPct()
    if not ak or not ak.maxhealth or ak.maxhealth <= 0 then
        return 100
    end
    return math.floor((ak.currenthealth or 0) / ak.maxhealth * 100)
end

-- ============================================================
--  GMCP HELPERS  (Legacy reads Char.Vitals + Char.Vitals.charstats)
-- ============================================================
-- charstats is a flat list of "Key: Value" strings, e.g.:
--   { "Bleed: 0", "Rage: 0", "Kai: 0%", "Form: None", "Kata: 0" }
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

-- Vitals shortcuts. gmcp.Char.Vitals fields are STRINGS — coerce.
local function vital(key)
    return tonumber(gmcp and gmcp.Char and gmcp.Char.Vitals and gmcp.Char.Vitals[key]) or 0
end

local function eqUp()
    return gmcp and gmcp.Char and gmcp.Char.Vitals and gmcp.Char.Vitals.eq == "1"
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
--  SELF LOCK-BREAK  (ported from Ataxia/can(x)/003_Lock_breakers.lua)
-- ============================================================
-- Monk-only collapse of the full Levi version. Triggers `fitness` when
-- softlocked (asthma + anorexia + slickness|bloodfire). Cooldowned to
-- avoid spamming.
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
    _lockBreakCooldown = os.time() + monk.shikudo.CONFIG.lockBreakCooldown
    return true
end

-- ============================================================
--  KAI SURGE WINDOW  (no AK/Legacy equivalent — module-local timer)
-- ============================================================
-- Call this from a trigger that matches "You unleash a brilliant burst
-- of kai" (or whatever line confirms kai surge fired). Clears after 15s.
function monk.shikudo.startKaiSurgeWindow()
    monk.shikudo.state.kaiSurgeWindow = true
    if monk.shikudo.state._kaiSurgeTimer then
        killTimer(monk.shikudo.state._kaiSurgeTimer)
    end
    monk.shikudo.state._kaiSurgeTimer = tempTimer(monk.shikudo.CONFIG.kaiSurgeWindowDuration, function()
        monk.shikudo.state.kaiSurgeWindow = false
        monk.shikudo.state._kaiSurgeTimer = nil
    end)
end

-- ============================================================
--  MODE SELECTION
-- ============================================================
function monk.shikudo.setMode(mode)
    local valid = {
        dispatch = true,
        lock = true,
        riftlock = true,
        godmode = true
    }
    if valid[mode] then
        monk.shikudo.mode = mode
        cecho("\n<cyan>[Shikudo] Mode set to: <yellow>" .. mode:upper())
    else
        cecho("\n<red>[Shikudo] Invalid mode. Use: dispatch, lock, riftlock, godmode")
    end
end

-- ============================================================
--  CONSTANTS
-- ============================================================
monk.shikudo.formAttacks = {
    Tykonos = {
        kicks = {"risingkick"},
        staff = {"thrust", "sweep"}
    },
    Willow = {
        kicks = {"flashheel"},
        staff = {"dart", "hiru", "hiraku", "sweep"}
    },
    Rain = {
        kicks = {"frontkick"},
        staff = {"ruku", "kuro", "hiru"}
    },
    Oak = {
        kicks = {"risingkick"},
        staff = {"livestrike", "nervestrike", "ruku", "kuro"}
    },
    Gaital = {
        kicks = {"spinkick", "flashheel", "dawnkick"},
        staff = {"needle", "sweep", "ruku", "jinzuku", "kuro"}
    },
    Maelstrom = {
        kicks = {"risingkick", "crescent"},
        staff = {"ruku", "livestrike", "jinzuku", "sweep"}
    }
}

monk.shikudo.transitions = {
    Tykonos = {"Willow"},
    Willow = {"Rain"},
    Rain = {"Tykonos", "Oak"},
    Oak = {"Willow", "Gaital"},
    Gaital = {"Rain", "Maelstrom"},
    Maelstrom = {"Oak"}
}

monk.shikudo.maxKata = {
    Tykonos = 12,
    Willow = 12,
    Rain = 24,
    Oak = 12,
    Gaital = 12,
    Maelstrom = 12
}

-- ============================================================
--  LIMB DAMAGE TABLE
-- ============================================================
-- Per-attack limb damage as a flat % of target HP. Post-normalization
-- values: target-independent, so this is a static table.
-- Calibrated via ports/legacy_ak/shikudo/calibrate.lua against a live
-- target. Read by getAttackDamage() and godmode's calcLimbs/shouldLight.
monk.shikudo.limbDamage = {
    -- Kicks
    flashheel = 9.2,
    frontkick = 9.2,
    risingkick = 9.2,
    spinkick = 27.0, -- not calibrated (requires prone)

    -- Staff strikes
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

-- ============================================================
--  SHARED UTILITIES
-- ============================================================
-- Limb damage lookup. AK and Levi both use lb[target].hits[limb].
local function getLimbDamage(limb)
    if not target or not lb or not lb[target] or not lb[target].hits then
        return 0
    end
    return lb[target].hits[limb] or 0
end

-- ============================================================
--  HYPERFOCUS
-- ============================================================
-- Hyperfocus halves limb damage but bypasses parry. Rule:
--   Set "hyperfocus head" iff we're in Oak AND target is parrying head.
--   Otherwise clear it.
-- `ak.limbs.hyperfocus` is the source of truth (AK tracks it). We never
-- mirror it locally; we just emit the appropriate command at the head of
-- each tick's command stack when desired ≠ current.

local function wantHyperfocus()
    -- The limb we want hyperfocused this tick, or nil for none.
    if charstat("Form") ~= "Oak" then
        return nil
    end
    if targetparry ~= "head" then
        return nil
    end
    return "head"
end

local function currentHyperfocus()
    -- AK's view of our current hyperfocus limb, or nil.
    return (ak and ak.limbs and ak.limbs.hyperfocus) or nil
end

-- Returns the hyperfocus command to inject at the start of the stack
-- (e.g. "hyperfocus head/" or "hyperfocus none/"), or "" if nothing
-- needs changing.
local function hyperfocusFix()
    local want = wantHyperfocus()
    local have = currentHyperfocus()
    if want == have then
        return ""
    end
    if want then
        return "hyperfocus " .. want .. "/"
    else
        return "hyperfocus none/"
    end
end

-- Per-attack % damage, with hyperfocus halving when attacking the focused
-- limb. Uses wantHyperfocus() because by the time the attack lands, the
-- queue will have applied any hyperfocus command emitted by hyperfocusFix().
local function getAttackDamage(attack, targetLimb)
    local baseDamage = monk.shikudo.limbDamage[attack] or 10
    if targetLimb and wantHyperfocus() == targetLimb then
        return baseDamage / 2
    end
    return baseDamage
end

-- Hits-to-prep: 0 = already prepped, 1 = one more lands break, 2+ = needs more.
local function hitsToPrep(limb, attack)
    local current = getLimbDamage(limb)
    local dmg = getAttackDamage(attack, limb)
    local threshold = 100 - dmg
    if current >= threshold then
        return 0
    end
    if current + dmg >= threshold then
        return 1
    end
    return 2
end

local function isLimbPrepped(limb, attack)
    return hitsToPrep(limb, attack) == 0
end

local function getLegPrepThreshold(leg)
    -- Hyperfocus is never on a leg under the new rule, so no halving applies.
    return 100 - monk.shikudo.limbDamage.kuro
end

local function getHeadPrepThreshold()
    local form = charstat("Form") or "Rain"
    local ld = monk.shikudo.limbDamage
    local dmg
    if form == "Oak" then
        dmg = ld.nervestrike
    elseif form == "Gaital" then
        dmg = ld.needle
    else
        dmg = ld.hiru
    end
    if wantHyperfocus() == "head" then
        dmg = dmg / 2
    end
    return 100 - dmg
end

local function isLegPreppedByName(leg)
    local limbName = (leg == "left" or leg == "LL") and "left leg" or "right leg"
    return getLimbDamage(limbName) >= getLegPrepThreshold(limbName)
end

local function areBothLegsPrepped()
    return getLimbDamage("left leg") >= getLegPrepThreshold("left leg") and getLimbDamage("right leg") >=
               getLegPrepThreshold("right leg")
end

local function isDynamicHeadPrepped()
    return getLimbDamage("head") >= getHeadPrepThreshold()
end

-- Lower-damage leg first (balanced prep) — same lesson as Blademaster
local function getFocusLeg()
    return getLimbDamage("left leg") <= getLimbDamage("right leg") and "left" or "right"
end

local function getOffLeg()
    return getLimbDamage("left leg") >= getLimbDamage("right leg") and "left" or "right"
end

-- ============================================================
--  LOCK CONDITION CHECKS
-- ============================================================
local function checkSoftlock()
    return has("asthma") and has("anorexia") and has("slickness")
end

local function checkVenomlock()
    return checkSoftlock() and has("paralysis")
end

local function checkHardlock()
    return checkVenomlock() and has("impatience")
end

local function checkTruelock()
    return checkHardlock() and has("weariness")
end

-- ============================================================
--  DISPATCH CONDITION CHECK
-- ============================================================
local function checkDispatchReady()
    local ll = getLimbDamage("left leg")
    local rl = getLimbDamage("right leg")
    local h = getLimbDamage("head")
    local legBroken = (ll >= 100 or rl >= 100)
    local headBroken = (h >= 100 or has("damagedhead"))
    local windpipe = (has("damagedwindpipe") or has("crushedthroat"))
    return has("prone") and legBroken and headBroken and windpipe
end

-- ============================================================
--  TELEPATHY SELECTION  (Rain-form gates the EQ-balance bonus)
-- ============================================================
local function selectTelepathy()
    local form = charstat("Form") or "Oak"
    local kata = charstat("Kata") or 0

    if not eqUp() then
        return nil
    end

    -- Mindlock can be set in any form. Reads from monk.telepathy.mindlocked,
    -- which a trigger must set to true on "You complete the mind lock on X".
    if not monk.telepathy.mindlocked and not monk.telepathy.starting_mindlock then
        return "mind lock " .. target
    end

    -- All other telepathy: Rain only (EQ balance discount).
    if form ~= "Rain" then
        return nil
    end

    -- RIFTLOCK MODE: blackout burst window
    if monk.shikudo.mode == "riftlock" then
        if kata >= 9 and not monk.shikudo.state.blackoutActive then
            local now = os.time()
            if (now - monk.shikudo.state.lastBlackout) >= 10 then
                monk.shikudo.state.lastBlackout = now
                monk.shikudo.state.blackoutActive = true
                return "mind blackout " .. target
            end
        end
        if monk.shikudo.state.blackoutActive and not has("paralysis") then
            return "mind paralyse " .. target
        end
    end

    if checkSoftlock() and not has("impatience") then
        return "mind impatience " .. target
    end
    if checkSoftlock() then
        return "mind batter " .. target
    end
    if not has("paralysis") and monk.telepathy.mindlocked then
        return "mind paralyse " .. target
    end

    return nil
end

-- ============================================================
--  KICK SELECTION
-- ============================================================
local function selectKick()
    local form = charstat("Form") or "Oak"
    local parried = targetparry or "none"
    monk.shikudo.state.kickTarget = nil

    if form == "Rain" then
        -- Frontkick targets arms; alternate on parry.
        local lastArm = monk.shikudo.state.lastFrontkickArm or "left"
        local wasParried = monk.shikudo.state.frontkickWasParried or false
        monk.shikudo.state.frontkickWasParried = false

        if wasParried then
            local newArm = lastArm == "left" and "right" or "left"
            monk.shikudo.state.kickTarget = newArm .. " arm"
            monk.shikudo.state.lastFrontkickArm = newArm
            return "frontkick " .. newArm
        end

        local la = getLimbDamage("left arm")
        local ra = getLimbDamage("right arm")
        local targetArm = la <= ra and "left" or "right"
        monk.shikudo.state.kickTarget = targetArm .. " arm"
        monk.shikudo.state.lastFrontkickArm = targetArm
        return "frontkick " .. targetArm

    elseif form == "Oak" then
        if has("prone") then
            monk.shikudo.state.kickTarget = "head"
            return "risingkick head"
        end
        if isDynamicHeadPrepped() then
            monk.shikudo.state.kickTarget = "torso"
            return "risingkick torso"
        end
        monk.shikudo.state.kickTarget = "head"
        return "risingkick head"

    elseif form == "Gaital" then
        if has("prone") then
            monk.shikudo.state.kickTarget = "head"
            return "spinkick"
        end
        local ll = getLimbDamage("left leg")
        local rl = getLimbDamage("right leg")
        local targetLeg = ll >= rl and "left" or "right"
        monk.shikudo.state.kickTarget = targetLeg .. " leg"
        return "flashheel " .. targetLeg

    elseif form == "Willow" then
        local lastLeg = monk.shikudo.state.lastFlashheelLeg or "left"
        local wasParried = monk.shikudo.state.flashheelWasParried or false
        monk.shikudo.state.flashheelWasParried = false

        if wasParried then
            local newLeg = lastLeg == "left" and "right" or "left"
            monk.shikudo.state.kickTarget = newLeg .. " leg"
            monk.shikudo.state.lastFlashheelLeg = newLeg
            return "flashheel " .. newLeg
        end

        monk.shikudo.state.kickTarget = "left leg"
        monk.shikudo.state.lastFlashheelLeg = "left"
        return "flashheel left"

    elseif form == "Maelstrom" then
        if has("prone") and targetHpPct() <= 50 then
            monk.shikudo.state.kickTarget = "torso"
            return "crescent"
        end
        monk.shikudo.state.kickTarget = "head"
        return "risingkick head"

    else -- Tykonos
        monk.shikudo.state.kickTarget = "torso"
        return "risingkick torso"
    end
end

-- ============================================================
--  STAFF SELECTION (per-form)
-- ============================================================
-- selectStaff() dispatcher lives after all the form-specific helpers so
-- the locals it references are in scope. See bottom of this section.

local function selectRainStaff(slot)
    local mode = monk.shikudo.mode
    local parried = targetparry or "none"
    local focusLeg = getFocusLeg()
    local offLeg = getOffLeg()

    -- Lock / Riftlock: stack afflictions instead of pure leg prep.
    if mode == "lock" or mode == "riftlock" then
        if slot == 1 then
            if not has("weariness") then
                return "kuro " .. focusLeg
            end
            if not has("clumsiness") then
                return "ruku left"
            end
            if not has("slickness") then
                return "ruku torso"
            end
            return "hiru"
        else
            if not has("lethargy") then
                return "kuro " .. offLeg
            end
            if not has("clumsiness") then
                return "ruku right"
            end
            return "hiru"
        end
    end

    -- Dispatch: leg prep is Rain's primary job.
    local leftHits = hitsToPrep("left leg", "kuro")
    local rightHits = hitsToPrep("right leg", "kuro")

    if slot == 1 then
        monk.shikudo.state.slot1Target = nil
        local focusLegHits = (focusLeg == "left") and leftHits or rightHits

        if focusLegHits >= 1 and parried ~= (focusLeg .. " leg") then
            monk.shikudo.state.slot1Target = focusLeg .. " leg"
            return "kuro " .. focusLeg
        end
        monk.shikudo.state.slot1Target = "torso"
        return "ruku torso"
    else
        local slot1Hit = monk.shikudo.state.slot1Target or "none"
        local offLegHits = (focusLeg == "left") and rightHits or leftHits

        if offLegHits >= 1 and slot1Hit ~= (offLeg .. " leg") and parried ~= (offLeg .. " leg") then
            return "kuro " .. offLeg
        end
        return "hiru"
    end
end

local function selectOakStaff(slot)
    local mode = monk.shikudo.mode
    local parried = targetparry or "none"
    local focusLeg = getFocusLeg()
    local headPrepped = isDynamicHeadPrepped()

    if mode == "lock" or mode == "riftlock" then
        if slot == 1 then
            if not has("paralysis") then
                return "nervestrike"
            end
            if not has("asthma") then
                return "livestrike"
            end
            if not has("slickness") then
                return "ruku torso"
            end
            if not has("weariness") then
                return "kuro " .. focusLeg
            end
            return "nervestrike"
        else
            if not has("clumsiness") then
                return "ruku left"
            end
            if not has("weariness") then
                return "kuro " .. getOffLeg()
            end
            return "livestrike"
        end
    end

    -- Dispatch: head prep is Oak's primary job.
    local headHits = hitsToPrep("head", "nervestrike")

    if slot == 1 then
        monk.shikudo.state.slot1Target = nil
        if headPrepped then
            monk.shikudo.state.slot1Target = focusLeg .. " leg"
            return "kuro " .. focusLeg
        end
        if headHits >= 1 and parried ~= "head" then
            monk.shikudo.state.slot1Target = "head"
            return "nervestrike"
        end
        monk.shikudo.state.slot1Target = "torso"
        return "livestrike"
    else
        local slot1Hit = monk.shikudo.state.slot1Target or "none"
        if headHits >= 2 and slot1Hit ~= "head" and parried ~= "head" then
            return "nervestrike"
        end
        if not has("asthma") then
            return "livestrike"
        end
        return "ruku torso"
    end
end

local function selectGaitalStaff(slot)
    local ll = getLimbDamage("left leg")
    local rl = getLimbDamage("right leg")
    local h = getLimbDamage("head")
    local bothLegsPrepped = areBothLegsPrepped()
    local headPrepped = isDynamicHeadPrepped()
    local parried = targetparry or "none"

    if slot == 1 then
        monk.shikudo.state.slot1Target = nil
    end

    -- Kai Surge window: target can't remount for 15s. Attack the parried limb.
    -- Kai surge window: set by monk.shikudo.startKaiSurgeWindow() from a trigger.
    if monk.shikudo.state.kaiSurgeWindow and parried ~= "none" then
        local isLeg = (parried == "left leg" or parried == "right leg")
        local side = isLeg and (parried == "left leg" and "left" or "right") or nil
        if not has("prone") then
            if slot == 1 then
                monk.shikudo.state.slot1Target = "sweep"
                return "sweep"
            else
                return isLeg and ("kuro " .. side) or "needle"
            end
        else
            if slot == 1 then
                monk.shikudo.state.slot1Target = parried
            end
            return isLeg and ("kuro " .. side) or "needle"
        end
    end

    -- Sweep when ready: all five conditions for prone-into-execute.
    if not has("prone") and bothLegsPrepped and headPrepped then
        if slot == 1 then
            monk.shikudo.state.slot1Target = "sweep"
            return "sweep"
        else
            return nil
        end
    end

    -- Prone: needle for head + windpipe damage.
    if has("prone") then
        if slot == 1 then
            monk.shikudo.state.slot1Target = "head"
            return "needle"
        else
            return "needle"
        end
    end

    -- Default: prep legs first, then head.
    if slot == 1 then
        if not isLegPreppedByName("left") then
            monk.shikudo.state.slot1Target = "left leg"
            return "kuro left"
        end
        monk.shikudo.state.slot1Target = "head"
        return "needle"
    else
        if not isLegPreppedByName("right") then
            return "kuro right"
        end
        return "needle"
    end
end

local function selectWillowStaff(slot)
    local headHits = hitsToPrep("head", "hiru")
    if slot == 1 then
        monk.shikudo.state.slot1Target = nil
        if headHits >= 1 then
            monk.shikudo.state.slot1Target = "head"
            return "hiru"
        end
        monk.shikudo.state.slot1Target = "torso"
        return "dart torso"
    else
        if headHits >= 2 then
            return "hiraku"
        end
        return "dart torso"
    end
end

local function selectMaelstromStaff(slot)
    if not has("prone") and areBothLegsPrepped() and isDynamicHeadPrepped() then
        if slot == 1 then
            return "sweep"
        else
            return nil
        end
    end
    if slot == 1 then
        if not has("asthma") then
            return "livestrike"
        end
        if not has("slickness") then
            return "ruku torso"
        end
        return "jinzuku"
    else
        if not has("slickness") then
            return "ruku torso"
        end
        if not has("addiction") then
            return "jinzuku"
        end
        return "livestrike"
    end
end

-- Dispatcher: routes to the form-specific selectors above.
local function selectStaff(slot)
    local form = charstat("Form") or "Oak"
    if form == "Rain" then
        return selectRainStaff(slot)
    end
    if form == "Oak" then
        return selectOakStaff(slot)
    end
    if form == "Gaital" then
        return selectGaitalStaff(slot)
    end
    if form == "Willow" then
        return selectWillowStaff(slot)
    end
    if form == "Maelstrom" then
        return selectMaelstromStaff(slot)
    end
    return "thrust torso"
end

-- ============================================================
--  TRANSITION LOGIC (mode-aware)
-- ============================================================
local function shouldTransition()
    local form = charstat("Form") or "Oak"
    local kata = charstat("Kata") or 0
    local mode = monk.shikudo.mode

    if kata < 5 then
        return nil
    end

    local maxKata = monk.shikudo.maxKata[form] or 12

    if mode == "dispatch" then
        local legsPrepped = areBothLegsPrepped()
        local headPrepped = isDynamicHeadPrepped()

        if legsPrepped and headPrepped then
            if form == "Oak" then
                return "Gaital"
            end
            if form == "Rain" then
                return "Oak"
            end
            if form == "Willow" then
                return "Rain"
            end
        end

        if kata >= maxKata - 3 then
            if form == "Willow" then
                return "Rain"
            end
            if form == "Rain" then
                return "Oak"
            end
            if form == "Oak" then
                return "Willow"
            end
            if form == "Gaital" then
                return "Maelstrom"
            end
            if form == "Maelstrom" then
                return "Oak"
            end
        end
    end

    if mode == "lock" or mode == "riftlock" then
        -- Prioritise Rain for the telepathy bonus.
        if form ~= "Rain" and form ~= "Willow" then
            if kata >= 5 then
                if form == "Oak" then
                    return "Willow"
                end
                if form == "Gaital" then
                    return "Rain"
                end
                if form == "Maelstrom" then
                    return "Oak"
                end
            end
        end
        if form == "Willow" and kata >= 5 then
            return "Rain"
        end
        if kata >= maxKata - 3 then
            if form == "Rain" then
                return "Oak"
            end
            if form == "Oak" then
                return "Willow"
            end
        end
    end

    return nil
end

-- ============================================================
--  COMBO BUILDER
-- ============================================================
local function buildCombo(transition)
    local form = charstat("Form") or "Oak"
    local kick = selectKick()
    local staff1 = selectStaff(1)
    local staff2 = selectStaff(2)

    -- Sweep uses both arm balances; no second staff strike.
    if staff1 == "sweep" then
        local combo = "combo $tar sweep"
        if kick then
            combo = combo .. " " .. kick
        end
        if transition then
            combo = combo .. " transition " .. transition:lower()
        end
        return combo
    end

    local combo = "combo $tar"

    -- Oak leads with staff (nervestrike paralysis blocks parry); other forms kick first.
    if form == "Oak" then
        if staff1 then
            combo = combo .. " " .. staff1
        end
        if staff2 then
            combo = combo .. " " .. staff2
        end
        if kick then
            combo = combo .. " " .. kick
        end
    else
        if kick then
            combo = combo .. " " .. kick
        end
        if staff1 then
            combo = combo .. " " .. staff1
        end
        if staff2 then
            combo = combo .. " " .. staff2
        end
    end

    if transition then
        combo = combo .. " transition " .. transition:lower()
    end

    return combo
end

-- ============================================================
--  MAIN DISPATCH
-- ============================================================
function monk.shikudo.dispatch()
    local form = charstat("Form") or "Oak"
    local kata = charstat("Kata") or 0
    local mode = monk.shikudo.mode

    cecho("\n<cyan>[Shikudo:" .. mode:upper() .. "] Target: <yellow>" .. tostring(target))
    cecho(" <cyan>| Form: <yellow>" .. form)
    cecho(" <cyan>| Kata: <yellow>" .. kata)

    if not target or target == "" then
        cecho("\n<red>[Shikudo] No target set! Use: tar <name>")
        return
    end

    -- GODMODE: delegate to the godmode subsystem (defined below).
    if mode == "godmode" then
        if monk.shikudo.godmode and monk.shikudo.godmode.run then
            return monk.shikudo.godmode.run()
        else
            cecho("\n<red>[Shikudo] God Mode not loaded!")
            return
        end
    end

    local cmd = ""
    local staffId = monk.shikudo.CONFIG.staffId

    -- Dispatch kill check (Mhaldor branch intentionally removed — always dispatch).
    if mode == "dispatch" and checkDispatchReady() then
        cmd = "wield " .. staffId .. "/dispatch " .. target
        cecho("\n<red>*** DISPATCH KILL ***")
        sendAttack(cmd, "FREE")
        return
    end

    -- Shield: shatter combo.
    if has("shield") then
        local kick = selectKick()
        cmd = "wield " .. staffId .. "/combo " .. target .. " shatter " .. kick
        sendAttack(cmd, "FREE")
        return
    end

    -- Hyperfocus management: prepend `hyperfocus head/` or `hyperfocus none/`
    -- only when the desired state differs from `ak.limbs.hyperfocus`. This is
    -- an eq-only action — safe to chain with whatever follows.
    cmd = cmd .. hyperfocusFix()

    -- TELEPATHY:
    --   `mind lock` is eq-only — prepended so the lock attempt fires
    --     during the same balance window as the combo.
    --   Other mind X (impatience / batter / paralyse / blackout) are
    --     bal+eq. They CAN chain after the combo — the server's queue
    --     waits for balance to recover, then fires the mind command on
    --     the next balance cycle. Order matters: combo first, then mind X.
    local trailingTelepathy = nil
    if mode == "lock" or mode == "riftlock" then
        local telepathy = selectTelepathy()
        if telepathy then
            if telepathy:find("^mind lock ") then
                cmd = cmd .. telepathy .. "/"
                cecho("\n<magenta>[Shikudo] Telepathy: " .. telepathy)
            else
                trailingTelepathy = telepathy
            end
        end
    end

    -- Mounted + Rain: kai surge dismount opportunity. Kai surge uses its
    -- own balance pool (kai + dedicated eq), so it chains safely with the
    -- combo at the end of the stack.
    if has("mounted") and form == "Rain" then
        local kai = charstat("Kai") or 0
        if kai >= 31 then
            cmd = cmd .. "kai surge " .. target .. "/"
            cecho("\n<magenta>[Shikudo] KAI SURGE (dismount)")
        end
    end

    local transition = shouldTransition()
    local attack = buildCombo(transition)
    attack = attack:gsub("%$tar", target)

    cmd = cmd .. "wield " .. staffId .. "/" .. attack

    if transition then
        cecho("\n<yellow>[Shikudo] Transitioning to " .. transition)
        if form == "Rain" and transition == "Oak" then
            monk.shikudo.state.blackoutActive = false
        end
    end

    -- Non-lock telepathy chains AFTER the combo. Server queue holds it
    -- until balance returns from the combo, then fires it.
    if trailingTelepathy then
        cmd = cmd .. "/" .. trailingTelepathy
        if trailingTelepathy:find("blackout") then
            cecho("\n<red>*** BLACKOUT - OPPONENT CANNOT SEE ***")
        elseif trailingTelepathy:find("paralyse") and monk.shikudo.state.blackoutActive then
            cecho("\n<red>*** HIDDEN PARALYSE (under blackout) ***")
        else
            cecho("\n<magenta>[Shikudo] Telepathy: " .. trailingTelepathy)
        end
    end

    cmd = cmd .. "/ASSESS"

    sendAttack(cmd, "FREE")
end

-- ============================================================================
--  GODMODE SUBSYSTEM  (folded in from 009_CC_Shikudo_GodMode.lua)
-- ============================================================================
-- 5-limb prep -> 3-combo execute. Preps both legs, both arms, head to 92+
-- then fires:
--   Combo 1: sweep + flashheel left    -> prone, left leg broken
--   Combo 2: ruku left + ruku right + flashheel right
--                                      -> both arms broken, right leg broken
--   Combo 3: needle + smart staff + flashheel left
--                                      -> head broken (needle+hyperfocus),
--                                         crushedthroat, aff
--
-- Combo 4 decision:
--   prone + damagedhead + crushedthroat -> DISPATCH
--   crushedthroat cured + 3+ lock affs  -> Rain, lock fork
--   target <= 38% HP + kata >= 5        -> MAELSTROM + crescent override
-- ============================================================================
monk.shikudo.godmode = monk.shikudo.godmode or {}

do
    -- ── FILE-SCOPE LOCAL STATE ───────────────────────────────────
    -- gm is reset at top of run() each tick. Closures below capture it.
    local gm = {}

    local GM_LOCK_AFFS = {"slickness", "asthma", "addiction", "weariness", "paralysis", "anorexia", "impatience",
                          "confusion"}

    local LIMB_NAMES = {
        LL = "left leg",
        RL = "right leg",
        LA = "left arm",
        RA = "right arm",
        H = "head",
        T = "torso"
    }

    local function getLimb(key)
        if not target or not lb or not lb[target] or not lb[target].hits then
            return 0
        end
        return lb[target].hits[LIMB_NAMES[key]] or 0
    end

    -- ── LIMB STATE CALCULATOR ────────────────────────────────────
    local function calcLimbs()
        -- Per-attack damage table is static (post-normalization, target-independent).
        local ld = monk.shikudo.limbDamage
        local thresh = monk.shikudo.CONFIG.godmodePrepThreshold

        gm.LL = getLimb("LL")
        gm.RL = getLimb("RL")
        gm.LA = getLimb("LA")
        gm.RA = getLimb("RA")
        gm.H = getLimb("H")
        gm.T = getLimb("T")

        -- Arms: prepped = at threshold; ruku would break if not light.
        gm.laRUK = (gm.LA + ld.ruku >= 100)
        gm.raRUK = (gm.RA + ld.ruku >= 100)
        gm.laPREP = (gm.LA >= thresh)
        gm.raPREP = (gm.RA >= thresh)

        -- Legs: prepped = one hit breaks; respects existing breaks.
        gm.llKUR = (gm.LL + (ld.kuro or 0) >= 100) and not has("damagedleftleg")
        gm.rlKUR = (gm.RL + (ld.kuro or 0) >= 100) and not has("damagedrightleg")
        gm.llFLASH = (gm.LL + ld.flashheel >= 100) and not has("damagedleftleg")
        gm.rlFLASH = (gm.RL + ld.flashheel >= 100) and not has("damagedrightleg")

        -- Head: needle breaks at 92+ with hyperfocus head.
        gm.hNEED = (gm.H + (ld.needle or 0) >= 100)
        gm.hPREP = (gm.H >= 86)
        gm.hNERV = (gm.H + ld.nervestrike >= 100)
        gm.hHIRU = (gm.H + (ld.hiru or 0) >= 100)
        gm.hHIRA = (gm.H + (ld.hiraku or 0) >= 100)
        gm.hHIHI = (gm.H + ld.hiru + ld.hiraku >= 100)
        gm.hNERVRIS = (gm.H + ld.nervestrike + ld.risingkick >= 100)

        -- Broken-limb checks. "broken" affs come from possibleStates; "damaged"
        -- comes from tAffs / score directly. Both route through has().
        gm.bothLegsBroken = (has("brokenleftleg") or has("damagedleftleg")) and
                                (has("brokenrightleg") or has("damagedrightleg"))
        gm.bothArmsBroken = (has("brokenleftarm") or has("damagedleftarm")) and
                                (has("brokenrightarm") or has("damagedrightarm"))

        -- All 5 prepped: ready to execute.
        gm.executeReady = gm.llFLASH and gm.rlFLASH and gm.laPREP and gm.raPREP and gm.hPREP

        -- Lock-fork eligibility: both arms broken + 3+ lock affs present.
        local lockCount = 0
        for _, aff in ipairs(GM_LOCK_AFFS) do
            if has(aff) then
                lockCount = lockCount + 1
            end
        end
        gm.lockCount = lockCount
        gm.lockForkReady = gm.bothArmsBroken and lockCount >= monk.shikudo.CONFIG.godmodeLockForkMinAffs

        -- Low-HP override (Maelstrom + crescent kill).
        gm.lowHp = targetHpPct() <= monk.shikudo.CONFIG.godmodeMaelstromHpThresh
    end

    -- ── LIGHT/NO-LIGHT CALCULATOR ────────────────────────────────
    -- Only protects limbs during BUILD phase. Never called during execute.
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
        return false -- torso: never light
    end

    -- ── FORM PRIOS ───────────────────────────────────────────────
    -- Each priorsfn sets gm.staff = {} and gm.kick string.

    -- TYKONOS ----------------------------------------------------
    local function tykonosPrios()
        gm.staff = {}
        gm.kick = "none"
        if not has("prone") then
            table.insert(gm.staff, "sweep")
        end
        gm.kick = gm.hNERVRIS and "risingkick torso" or "risingkick head"
    end

    -- WILLOW -----------------------------------------------------
    local function willowPrios()
        gm.staff = {}
        gm.kick = "none"

        -- Kick: flashheel for leg prep.
        if not gm.llFLASH and targetparry ~= "left leg" then
            gm.kick = "flashheel left"
        elseif not gm.rlFLASH then
            gm.kick = "flashheel right"
        else
            if not has("prone") then
                table.insert(gm.staff, "sweep")
            end
            gm.kick = "spinkick"
        end

        -- Staff: hiru + hiraku for head prep with light guards.
        if not gm.hHIHI then
            table.insert(gm.staff, gm.hHIRU and "hiru light" or "hiru")
            table.insert(gm.staff, gm.hHIRA and "hiraku light" or "hiraku")
        else
            table.insert(gm.staff, "hiru light")
            table.insert(gm.staff, "hiraku light")
        end
    end

    -- RAIN -------------------------------------------------------
    local function rainPrios()
        gm.staff = {}
        gm.kick = "none"
        local k = charstat("Kata") or 0
        local ld = monk.shikudo.limbDamage

        -- LOCK FORK: both arms broken + 3+ lock affs -> push lock.
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
            if not slot1 then
                slot1 = "kuro left"
            end
            if not slot2 then
                slot2 = "kuro right"
            end
            table.insert(gm.staff, slot1)
            if slot2 then
                table.insert(gm.staff, slot2)
            end
            return
        end

        -- Normal build: check prep status.
        local allLegsDone = gm.llFLASH and gm.rlFLASH
        local allArmsDone = gm.laPREP and gm.raPREP

        -- All 5 prepped: hold with lights.
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

        -- Legs+arms prepped but head not yet: hiru for head pressure.
        if allLegsDone and allArmsDone and not gm.hPREP then
            gm.kick = "none"
            table.insert(gm.staff, gm.hHIRU and "hiru light" or "hiru")
            table.insert(gm.staff, "kuro light left")
            return
        end

        -- Frontkick: targets arms. Don't kick a prepped arm (no light variant).
        local sim = {}
        local leftSafe = targetparry ~= "left arm" and not gm.laRUK
        local rightSafe = targetparry ~= "right arm" and not gm.raRUK
        if leftSafe and (not rightSafe or gm.LA <= gm.RA) then
            gm.kick = "frontkick left"
            sim.LA = (sim.LA or 0) + ld.frontkick
        elseif rightSafe then
            gm.kick = "frontkick right"
            sim.RA = (sim.RA or 0) + ld.frontkick
        else
            gm.kick = "none"
        end

        -- Slot pickers with cumulative simulation.
        local function pickKuro()
            if not gm.llKUR and (gm.rlKUR or gm.LL <= gm.RL) then
                local light = shouldLight("LL", ld.kuro or 0, sim.LL)
                local s = light and "kuro light left" or "kuro left"
                if not light then
                    sim.LL = (sim.LL or 0) + ld.kuro
                end
                return s
            elseif not gm.rlKUR then
                local light = shouldLight("RL", ld.kuro or 0, sim.RL)
                local s = light and "kuro light right" or "kuro right"
                if not light then
                    sim.RL = (sim.RL or 0) + ld.kuro
                end
                return s
            end
            return "kuro light left"
        end

        local function pickRuku()
            if gm.LA <= gm.RA then
                local light = shouldLight("LA", ld.ruku or 0, sim.LA)
                local s = light and "ruku light left" or "ruku left"
                if not light then
                    sim.LA = (sim.LA or 0) + ld.ruku
                end
                return s
            else
                local light = shouldLight("RA", ld.ruku or 0, sim.RA)
                local s = light and "ruku light right" or "ruku right"
                if not light then
                    sim.RA = (sim.RA or 0) + ld.ruku
                end
                return s
            end
        end

        local slot1, slot2 = nil, nil

        -- Priority 1: kuro@12+ for wea+leth.
        if k >= 12 and not has("lethargy") then
            slot1 = pickKuro()
        end
        -- Priority 2: ruku@10+ for clu+hleech.
        if k >= 10 and not has("healthleech") then
            if not slot1 then
                slot1 = pickRuku()
            elseif not slot2 then
                slot2 = pickRuku()
            end
        end
        -- Priority 3: clumsiness.
        if not has("clumsiness") then
            if not slot1 then
                slot1 = pickRuku()
            elseif not slot2 then
                slot2 = pickRuku()
            end
        end
        -- Priority 4: lethargy.
        if not has("lethargy") then
            if not slot1 then
                slot1 = pickKuro()
            elseif not slot2 and (not slot1 or not slot1:find("kuro")) then
                slot2 = pickKuro()
            end
        end
        -- Priority 5: leg prep.
        if not slot1 then
            slot1 = pickKuro()
        end
        -- Priority 6: arm prep.
        if not slot1 then
            slot1 = pickRuku()
        end
        if not slot2 then
            if slot1 and slot1:find("kuro") then
                slot2 = pickRuku()
            elseif slot1 and slot1:find("ruku") then
                slot2 = pickKuro()
            else
                slot2 = pickRuku()
            end
        end
        -- Priority 7: filler.
        if not slot1 then
            slot1 = "ruku torso"
        end
        if not slot2 then
            slot2 = gm.hHIRU and "hiru light" or "hiru"
        end

        table.insert(gm.staff, slot1)
        if slot2 then
            table.insert(gm.staff, slot2)
        end
    end

    -- OAK --------------------------------------------------------
    local function oakPrios()
        gm.staff = {}
        gm.kick = "none"
        local ld = monk.shikudo.limbDamage

        local allPrepped = gm.llFLASH and gm.rlFLASH and gm.laPREP and gm.raPREP and gm.hPREP

        if allPrepped then
            -- Light only to build kata.
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

        -- Kick selection with risingkick safety check.
        if not gm.hPREP then
            if gm.hNERVRIS then
                gm.kick = "risingkick torso"
            else
                gm.kick = "risingkick head"
            end
        else
            gm.kick = "risingkick torso"
        end

        -- Slot 1: nervestrike for head prep.
        if not gm.hPREP then
            local light = gm.hNERV
            table.insert(gm.staff, light and "nervestrike light" or "nervestrike")
        elseif not has("paralysis") then
            local light = shouldLight("H", ld.nervestrike or 0, 0)
            table.insert(gm.staff, light and "nervestrike light" or "nervestrike")
        else
            if not has("asthma") then
                table.insert(gm.staff, "livestrike")
            elseif not has("slickness") then
                table.insert(gm.staff, "ruku torso")
            end
        end

        -- Slot 2: leg or arm prep with light guard.
        if not gm.llKUR and (gm.rlKUR or gm.LL <= gm.RL) then
            local light = shouldLight("LL", ld.kuro or 0, 0)
            table.insert(gm.staff, light and "kuro light left" or "kuro left")
        elseif not gm.rlKUR then
            local light = shouldLight("RL", ld.kuro or 0, 0)
            table.insert(gm.staff, light and "kuro light right" or "kuro right")
        elseif not gm.laPREP then
            local light = shouldLight("LA", ld.ruku or 0, 0)
            table.insert(gm.staff, light and "ruku light left" or "ruku left")
        elseif not gm.raPREP then
            local light = shouldLight("RA", ld.ruku or 0, 0)
            table.insert(gm.staff, light and "ruku light right" or "ruku right")
        elseif not has("asthma") then
            table.insert(gm.staff, "livestrike")
        elseif not has("slickness") then
            table.insert(gm.staff, "ruku torso")
        end
    end

    -- GAITAL  (stateless execute: re-reads game state each tick) -
    local function gaitalPrios()
        gm.staff = {}
        gm.kick = "none"
        local k = charstat("Kata") or 0
        local ld = monk.shikudo.limbDamage

        -- LOW HP OVERRIDE: 38% or below -> Maelstrom for crescent.
        if gm.lowHp and k >= 5 then
            gm.staff[1] = "maelstrom_override"
            return
        end

        -- DISPATCH: prone + damagedhead + crushedthroat.
        if has("prone") and has("damagedhead") and has("crushedthroat") then
            gm.staff[1] = "dispatch"
            return
        end

        -- LOCK FORK: both arms broken + 3+ lock affs -> flow Rain.
        if gm.lockForkReady then
            gm.staff[1] = "lock_fork"
            return
        end

        -- COMBO 3: prone + both arms broken + right leg broken/damaged.
        --          needle + smart jab + flashheel left
        local rightLegBroken = has("damagedrightleg") or has("brokenrightleg")
        if has("prone") and gm.bothArmsBroken and rightLegBroken then
            gm.staff = {}
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

        -- RE-NEEDLE: prone + damagedhead + crushedthroat cured.
        if has("prone") and has("damagedhead") and not has("crushedthroat") then
            gm.staff = {}
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

        -- COMBO 2: prone + left leg broken/damaged + not both arms broken yet.
        local leftLegBroken = has("damagedleftleg") or has("brokenleftleg")
        if has("prone") and leftLegBroken and not gm.bothArmsBroken then
            gm.staff = {}
            table.insert(gm.staff, "ruku left")
            table.insert(gm.staff, "ruku right")
            gm.kick = "flashheel right"
            return
        end

        -- COMBO 1: all 5 prepped, not prone.
        if gm.executeReady and not has("prone") then
            gm.staff = {}
            table.insert(gm.staff, "sweep")
            gm.kick = "flashheel left"
            return
        end

        -- KATA GUARD: not in execute, kata deep -> filler only.
        if k >= 10 and not gm.executeReady then
            gm.kick = "none"
            table.insert(gm.staff, not has("slickness") and "ruku torso" or "jinzuku")
            table.insert(gm.staff, not has("addiction") and "jinzuku" or "ruku torso")
            return
        end

        -- STILL BUILDING in Gaital: flashheel legs, kuro/ruku staff.
        local simLL, simRL = 0, 0

        if not gm.llFLASH and not has("damagedleftleg") and (gm.rlFLASH or gm.LL <= gm.RL) and targetparry ~= "left leg" then
            gm.kick = "flashheel left"
            simLL = simLL + ld.flashheel
        elseif not gm.rlFLASH and not has("damagedrightleg") then
            gm.kick = "flashheel right"
            simRL = simRL + ld.flashheel
        else
            gm.kick = "none"
        end

        -- Staff jabs with cumulative damage tracking.
        local function gPickKuro()
            if not gm.llKUR and (gm.rlKUR or gm.LL <= gm.RL) then
                local light = shouldLight("LL", ld.kuro or 0, simLL)
                local s = light and "kuro light left" or "kuro left"
                if not light then
                    simLL = simLL + ld.kuro
                end
                return s
            elseif not gm.rlKUR then
                local light = shouldLight("RL", ld.kuro or 0, simRL)
                local s = light and "kuro light right" or "kuro right"
                if not light then
                    simRL = simRL + ld.kuro
                end
                return s
            end
            return nil
        end

        local simLA, simRA = 0, 0
        local function gPickRuku()
            if not gm.laPREP then
                local light = shouldLight("LA", ld.ruku or 0, simLA)
                local s = light and "ruku light left" or "ruku left"
                if not light then
                    simLA = simLA + ld.ruku
                end
                return s
            elseif not gm.raPREP then
                local light = shouldLight("RA", ld.ruku or 0, simRA)
                local s = light and "ruku light right" or "ruku right"
                if not light then
                    simRA = simRA + ld.ruku
                end
                return s
            end
            return gm.LA <= gm.RA and "ruku light left" or "ruku light right"
        end

        local j1, j2 = nil, nil
        if not has("clumsiness") then
            j1 = gPickRuku()
        elseif not has("lethargy") then
            j1 = gPickKuro()
        end
        if not j1 then
            j1 = gPickKuro()
        end
        if not j1 then
            j1 = gPickRuku()
        end
        if not j1 then
            j1 = not has("addiction") and "jinzuku" or "ruku torso"
        end

        if j1 and j1:find("kuro left") then
            j2 = not gm.rlKUR and gPickKuro() or gPickRuku()
        elseif j1 and j1:find("kuro right") then
            j2 = not gm.llKUR and gPickKuro() or gPickRuku()
        elseif j1 and j1:find("ruku") then
            j2 = gPickKuro()
        end
        if not j2 then
            j2 = not has("addiction") and "jinzuku" or "ruku torso"
        end

        table.insert(gm.staff, j1)
        if j2 then
            table.insert(gm.staff, j2)
        end
    end

    -- MAELSTROM --------------------------------------------------
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

    -- ── FORM SWAP (condition-based) ──────────────────────────────
    local function formswap()
        local f = charstat("Form") or "Rain"
        local k = charstat("Kata") or 0
        local targetForm = nil

        -- Low HP override: Gaital -> Maelstrom for crescent.
        if f == "Gaital" and gm.lowHp and k >= 5 then
            return "Maelstrom"
        end

        -- Lock fork: Gaital -> Rain to push lock.
        if f == "Gaital" and gm.lockForkReady then
            if k >= 5 then
                return "Rain"
            else
                return f
            end
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
            if gm.lockForkReady then
                return "Rain"
            end
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
            if k >= 10 and not gm.executeReady and not killReady and not gm.lockForkReady and not midExecute then
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

    -- ── MAIN GODMODE ENTRY ───────────────────────────────────────
    function monk.shikudo.godmode.run()
        local f = charstat("Form")
        local k = charstat("Kata") or 0

        -- Reset per-tick state.
        gm = {}

        if not target or target == "" then
            cecho("\n<red>[Shikudo GM] No target set! Use: tar <name>")
            return
        end

        -- Paused / stupidity / self lock break.
        if Legacy and Legacy.Settings and Legacy.Settings.Curing and Legacy.Settings.Curing.status == false then
            return
        end
        if selfAff("stupidity") then
            return
        end
        if selfNeedLockBreak() then
            selfLockBreak()
            return
        end

        -- Init form if none.
        if not f or f == "" or f == "None" or f == "none" then
            send("adopt rain form")
            return
        end

        -- Debug output (suppressed during autobashing).
        local basherOn = Legacy and Legacy.Settings and Legacy.Settings.Basher and Legacy.Settings.Basher.status
        if not basherOn then
            cecho("\n<cyan>[Shikudo:<yellow>GODMODE<cyan>] <yellow>" .. tostring(target))
            cecho(" <cyan>| <green>" .. f)
            cecho(" <cyan>| k:<yellow>" .. k)
        end

        -- Compute all limb state.
        calcLimbs()

        -- Build up the ATK command stack (`/`-separated).
        local atk = ""

        -- Mind lock if not already locked / a lock attempt isn't in flight.
        -- Mind lock is eq-only (unlike the other mind X attacks), so it
        -- chains safely with the combo at the end of the stack.
        if not monk.telepathy.mindlocked and not monk.telepathy.starting_mindlock then
            atk = atk .. "mind lock " .. target .. "/"
        end

        -- Transmute (HP <-> MP balancing).
        local maxhp = vital("maxhp")
        local hp = vital("hp")
        local mp = vital("mp")
        local maxmp = vital("maxmp")
        local xmute = math.ceil(maxhp * 0.80)
        local mpl = mp - (maxmp * 0.30)
        local hpl = xmute - hp
        if hpl > 1 then
            local tomute = (hpl < mpl and hpl or mpl)
            if tomute > 100 then
                atk = "transmute " .. tomute .. "/" .. atk
            end
        end

        -- Kai boost.
        local kai = charstat("Kai") or 0
        local hasKaiBoost = Legacy and Legacy.Curing and Legacy.Curing.Defs and Legacy.Curing.Defs.current and
                                Legacy.Curing.Defs.current.kaiboost
        if kai >= 11 and not hasKaiBoost then
            atk = atk .. "kai boost/"
        end

        -- HYPERFOCUS CHECK: only Oak + parrying head. Otherwise clear.
        -- The per-tick rule handles transitions automatically (e.g. dropping
        -- hyperfocus when we leave Oak or the target stops parrying head).
        local hyperFix = hyperfocusFix()
        if hyperFix ~= "" then
            sendAttack(atk .. hyperFix:gsub("/$", ""), "EQBAL")
            cecho(" <magenta>| HYPERFOCUS FIX: " .. hyperFix:gsub("/$", ""))
            return
        end

        -- DISPATCH CHECK (Mhaldor branch removed — always dispatch).
        if has("prone") and has("damagedhead") and has("crushedthroat") then
            atk = atk .. "dispatch " .. target
            cecho("\n<red>*** DISPATCH KILL ***")
            sendAttack(atk, "EQBAL")
            return
        end

        -- SHIELD CHECK.
        if has("shield") then
            atk = atk .. "combo " .. target .. " shatter"
            sendAttack(atk, "EQBAL")
            return
        end

        -- Dispatch to form prios.
        if f == "Tykonos" then
            tykonosPrios()
        elseif f == "Willow" then
            willowPrios()
        elseif f == "Rain" then
            rainPrios()
        elseif f == "Oak" then
            oakPrios()
        elseif f == "Gaital" then
            gaitalPrios()
        elseif f == "Maelstrom" then
            maelstromPrios()
        else
            send("adopt rain form")
            return
        end

        -- Form transition.
        local targetForm = formswap()
        local needTransition = (f ~= targetForm)

        if needTransition then
            if k >= 5 then
                sendAttack("cq all/transition to the " .. targetForm .. " form/" .. atk, "EQBAL")
                cecho(" <yellow>-> " .. targetForm)
            else
                sendAttack("cq all/adopt " .. targetForm .. " form", "EQBAL")
                cecho(" <yellow>-> adopt " .. targetForm)
            end
            return
        end

        -- Special actions from prios.
        if gm.staff[1] == "maelstrom_override" then
            sendAttack("cq all/transition to the Maelstrom form/" .. atk, "EQBAL")
            cecho(" <red>-> MAELSTROM (low HP)")
            return
        end

        if gm.staff[1] == "lock_fork" then
            if k >= 5 then
                sendAttack("cq all/transition to the Rain form/" .. atk, "EQBAL")
                cecho(" <magenta>-> RAIN (lock fork)")
            else
                sendAttack("cq all/adopt Rain form", "EQBAL")
                cecho(" <magenta>-> adopt Rain (lock fork)")
            end
            return
        end

        if gm.staff[1] == "dispatch" then
            atk = atk .. "dispatch " .. target
            cecho("\n<red>*** DISPATCH ***")
            sendAttack(atk, "EQBAL")
            return
        end

        -- Sweep handling: hyperfocus is auto-cleared by the per-tick rule
        -- when we leave Oak, so no explicit clear is needed here anymore.
        if gm.staff[1] == "sweep" then
            local c = gm.kick ~= "none" and "sweep " .. gm.kick or "sweep"
            atk = atk .. "combo " .. target .. " " .. c
            cecho(" <red>| EXECUTE C1: sweep")
            sendAttack(atk, "EQBAL")
            return
        end

        -- Standard combo assembly.
        local s1 = gm.staff[1] or ""
        local s2 = gm.staff[2] or ""
        local combo = ""

        -- Combo order: Rain or Oak+clumsiness lead with kick; others lead with staff.
        local kickFirst = (f == "Rain") or (f == "Oak" and has("clumsiness"))

        if kickFirst then
            if gm.kick ~= "none" and s1 ~= "" and s2 ~= "" then
                combo = gm.kick .. " " .. s1 .. " " .. s2
            elseif gm.kick ~= "none" and s1 ~= "" then
                combo = gm.kick .. " " .. s1
            elseif s1 ~= "" and s2 ~= "" then
                combo = s1 .. " " .. s2
            elseif s1 ~= "" then
                combo = s1
            end
        else
            if s1 ~= "" and s2 ~= "" and gm.kick ~= "none" then
                combo = s1 .. " " .. s2 .. " " .. gm.kick
            elseif s1 ~= "" and gm.kick ~= "none" then
                combo = s1 .. " " .. gm.kick
            elseif s1 ~= "" and s2 ~= "" then
                combo = s1 .. " " .. s2
            elseif gm.kick ~= "none" then
                combo = gm.kick
            elseif s1 ~= "" then
                combo = s1
            end
        end

        if combo ~= "" then
            atk = atk .. "combo " .. target .. " " .. combo
        end

        sendAttack(atk, "EQBAL")
    end

    -- ── GODMODE STATUS ───────────────────────────────────────────
    function monk.shikudo.godmode.status()
        local f = charstat("Form") or "Unknown"
        local k = charstat("Kata") or 0
        local thresh = monk.shikudo.CONFIG.godmodePrepThreshold

        local ll = getLimb("LL")
        local rl = getLimb("RL")
        local la = getLimb("LA")
        local ra = getLimb("RA")
        local h = getLimb("H")

        gm = {}
        calcLimbs()

        local function limbColor(v)
            if v >= 100 then
                return "<red>"
            elseif v >= thresh then
                return "<green>"
            elseif v >= 70 then
                return "<yellow>"
            else
                return "<grey>"
            end
        end

        local function checkMark(v)
            return v >= thresh and "<green>[X]" or "<red>[ ]"
        end

        cecho("\n<cyan>+==============================================+")
        cecho("\n<cyan>|         <white>SHIKUDO GOD MODE<cyan>                     |")
        cecho("\n<cyan>+==============================================+")
        cecho("\n<cyan>| <white>Target: <yellow>" .. tostring(target or "None"))
        cecho("\n<cyan>| <white>Form: <green>" .. f .. " <grey>(k:" .. k .. ")")
        cecho("\n<cyan>| <white>Hyper: " .. tostring(ak.limbs.hyperfocus or "none"))
        cecho("\n<cyan>+----------------------------------------------+")
        cecho("\n<cyan>| <white>5-LIMB PREP (" .. thresh .. "%+ threshold):")
        cecho("\n<cyan>|   " .. checkMark(ll) .. " <white>L Leg: " .. limbColor(ll) .. string.format("%.1f%%", ll))
        cecho("\n<cyan>|   " .. checkMark(rl) .. " <white>R Leg: " .. limbColor(rl) .. string.format("%.1f%%", rl))
        cecho("\n<cyan>|   " .. checkMark(la) .. " <white>L Arm: " .. limbColor(la) .. string.format("%.1f%%", la))
        cecho("\n<cyan>|   " .. checkMark(ra) .. " <white>R Arm: " .. limbColor(ra) .. string.format("%.1f%%", ra))
        cecho("\n<cyan>|   " .. checkMark(h) .. " <white>Head:  " .. limbColor(h) .. string.format("%.1f%%", h))

        local phase = "BUILD"
        if gm.executeReady then
            phase = "EXECUTE"
        end
        if gm.lockForkReady then
            phase = "LOCK FORK"
        end
        cecho("\n<cyan>| <white>Phase: <yellow>" .. phase)

        cecho("\n<cyan>+----------------------------------------------+")
        cecho("\n<cyan>| <white>KILL CONDITIONS:")
        cecho("\n<cyan>|   <white>Prone: " .. (has("prone") and "<green>YES" or "<red>NO"))
        cecho("\n<cyan>|   <white>Head Broken: " .. (has("damagedhead") and "<green>YES" or "<red>NO"))
        cecho("\n<cyan>|   <white>Windpipe: " ..
                  ((has("damagedwindpipe") or has("crushedthroat")) and "<green>YES" or "<red>NO"))
        cecho("\n<cyan>|   <white>Lock Affs: <yellow>" .. (gm.lockCount or 0) .. "/3")
        cecho("\n<cyan>+==============================================+")
    end

end -- end of godmode do-block

-- ============================================================================
--  MAIN STATUS DISPLAY
-- ============================================================================
function monk.shikudo.status()
    local form = charstat("Form") or "Unknown"
    local kata = charstat("Kata") or 0
    local maxKata = monk.shikudo.maxKata[form] or 12
    local mode = monk.shikudo.mode

    cecho("\n<cyan>+==============================================+")
    cecho("\n<cyan>|         <white>SHIKUDO STATUS<cyan>                       |")
    cecho("\n<cyan>+==============================================+")
    cecho("\n<cyan>| <white>Mode: <yellow>" .. mode:upper())
    cecho("\n<cyan>| <white>Target: <yellow>" .. tostring(target or "None"))
    cecho("\n<cyan>| <white>Form: <green>" .. form .. " <grey>(" .. kata .. "/" .. maxKata .. " kata)")
    cecho("\n<cyan>| <white>Hyperfocus: " .. (currentHyperfocus() or "none"))

    if mode == "godmode" then
        if monk.shikudo.godmode and monk.shikudo.godmode.status then
            monk.shikudo.godmode.status()
            return
        end
    end

    if mode == "dispatch" then
        cecho("\n<cyan>+----------------------------------------------+")
        cecho("\n<cyan>| <white>LIMB DAMAGE:")
        cecho("\n<cyan>|   <white>Head:  <yellow>" .. string.format("%.1f%%", getLimbDamage("head")))
        cecho("\n<cyan>|   <white>L Leg: <yellow>" .. string.format("%.1f%%", getLimbDamage("left leg")))
        cecho("\n<cyan>|   <white>R Leg: <yellow>" .. string.format("%.1f%%", getLimbDamage("right leg")))
        cecho("\n<cyan>| <white>KILL CONDITIONS:")
        cecho("\n<cyan>|   <white>Prone: " .. (has("prone") and "<green>YES" or "<red>NO"))
        cecho("\n<cyan>|   <white>Leg Broken: " ..
                  ((getLimbDamage("left leg") >= 100 or getLimbDamage("right leg") >= 100) and "<green>YES" or "<red>NO"))
        cecho("\n<cyan>|   <white>Head Broken: " ..
                  ((getLimbDamage("head") >= 100 or has("damagedhead")) and "<green>YES" or "<red>NO"))
        cecho("\n<cyan>|   <white>Windpipe: " ..
                  ((has("damagedwindpipe") or has("crushedthroat")) and "<green>YES" or "<red>NO"))
        cecho("\n<cyan>|   <white>DISPATCH READY: " .. (checkDispatchReady() and "<green>*** YES ***" or "<red>NO"))
    end

    if mode == "lock" or mode == "riftlock" then
        cecho("\n<cyan>+----------------------------------------------+")
        cecho("\n<cyan>| <white>LOCK STATUS:")
        cecho("\n<cyan>|   <white>Softlock: " .. (checkSoftlock() and "<green>LOCKED" or "<yellow>BUILDING"))
        cecho("\n<cyan>|     " .. (has("asthma") and "<green>[X]" or "<red>[ ]") .. " asthma")
        cecho("  " .. (has("anorexia") and "<green>[X]" or "<red>[ ]") .. " anorexia")
        cecho("  " .. (has("slickness") and "<green>[X]" or "<red>[ ]") .. " slickness")
        cecho("\n<cyan>|   <white>Venomlock: " .. (checkVenomlock() and "<green>LOCKED" or "<yellow>PENDING"))
        cecho("\n<cyan>|     " .. (has("paralysis") and "<green>[X]" or "<red>[ ]") .. " paralysis")
        cecho("\n<cyan>|   <white>Hardlock: " .. (checkHardlock() and "<green>LOCKED" or "<yellow>PENDING"))
        cecho("\n<cyan>|     " .. (has("impatience") and "<green>[X]" or "<red>[ ]") .. " impatience")
        cecho("\n<cyan>|   <white>Truelock: " .. (checkTruelock() and "<green>LOCKED" or "<yellow>PENDING"))
        cecho("\n<cyan>|     " .. (has("weariness") and "<green>[X]" or "<red>[ ]") .. " weariness")
    end

    if mode == "riftlock" then
        cecho("\n<cyan>+----------------------------------------------+")
        cecho("\n<cyan>| <white>RIFTLOCK:")
        cecho("\n<cyan>|   <white>Blackout Active: " ..
                  (monk.shikudo.state.blackoutActive and "<red>YES - OPPONENT BLIND" or "<grey>No"))
        cecho("\n<cyan>|   <white>Burst Ready: " ..
                  ((form == "Rain" and kata >= 9 and monk.telepathy.mindlocked) and "<green>YES" or "<yellow>NO"))
    end

    cecho("\n<cyan>+==============================================+")
end

-- ============================================================================
--  RESET
-- ============================================================================
function monk.shikudo.reset()
    monk.shikudo.state.blackoutActive = false
    monk.shikudo.state.lastBlackout = 0
    monk.shikudo.state.phase = "PREP"
    monk.shikudo.state.lockPhase = "SOFTLOCK"
    monk.shikudo.state.riftPhase = "OAK_SETUP"
    cecho("\n<cyan>[Shikudo] State reset")
end

-- ============================================================================
--  CONVENIENCE ALIASES
-- ============================================================================
function skdispatch()
    monk.shikudo.setMode("dispatch");
    monk.shikudo.dispatch()
end
function sklock()
    monk.shikudo.setMode("lock");
    monk.shikudo.dispatch()
end
function skriftlock()
    monk.shikudo.setMode("riftlock");
    monk.shikudo.dispatch()
end
function skgodmode()
    monk.shikudo.setMode("godmode");
    monk.shikudo.dispatch()
end

function skstatus()
    monk.shikudo.status()
end
function sklstatus()
    monk.shikudo.setMode("lock");
    monk.shikudo.status()
end
function srlstatus()
    monk.shikudo.setMode("riftlock");
    monk.shikudo.status()
end
function skgmstatus()
    monk.shikudo.setMode("godmode");
    monk.shikudo.godmode.status()
end

function skreset()
    monk.shikudo.reset()
end
function srlreset()
    monk.shikudo.reset()
end

