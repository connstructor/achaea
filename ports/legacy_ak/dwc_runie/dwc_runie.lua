--[[
================================================================================
RUNEWARDEN DWC (DUAL CUTTING) — LEGACY / AK PORT
================================================================================

Consolidation of the seven LEVI/Ataxia CC scripts in
  src_new/scripts/levi_ataxia/levi/levi_scripts/dwc_runie/

Source files (preserved combat logic — restructured, not cloned):
  001_RIFT.lua             -> runewarden.dwc.riftlock()
  002_BASIC_2.lua          -> runewarden.dwc.basic()
  003_Disembowel_Prep.lua  -> runewarden.dwc.disembowel()
  004_Head_Prep.lua        -> runewarden.dwc.headprep()
  005_DWCLogic.lua    \
  006_Attack_DWC.lua   } -> runewarden.dwc.kelpstack()   (was envenom1+envenom2+dwcattack chain)
  007_LeviDWCDisembowel.lua -> runewarden.dwc.lockprep() (lock-aware head prep)

Six callable entries — pick the one matching the situation, or set a default
and call dispatch():
  rrift()    – Riftlock (anti-Restore: epteth on no-salve + addiction). Auto-picks
               the salvelock arm (R arm → L arm → torso → legs).
  rbasic()   – DWC pressure along the disembowel limb path: slashes the picked limb
               (torso → R leg → L leg); delegates to disembowel under nausea+unprepped.
  rdism()    – Torso-focused kill prep, auto-picks targetlimb (torso → R leg → L leg)
  rhead()    – Head-focused mental stack, auto-picks targetlimb (head → R leg → ...)
  rkelp()    – Kelp-stack venom selection, single-venom raze/dsl
  rlock()    – Lock-aware disembowel + raze + prep w/ empower runes (was 007)

Public API (everything else is file-local):
  runewarden.dwc.CONFIG            table — tunables (item IDs, damage, thresholds)
  runewarden.dwc.state             table — runtime state (engaged, falcon flags, targetLimb)
  runewarden.dwc.mode              string — default mode for dispatch()

  runewarden.dwc.setMode(m)        called by aliases (one of: riftlock|basic|disembowel|headprep|kelpstack|lockprep)
  runewarden.dwc.setLimb(limb)     set the focus limb ("torso"/"head"/"left leg"/etc.)
  runewarden.dwc.dispatch()        delegates to current mode handler
  runewarden.dwc.status()          print current state
  runewarden.dwc.reset()           clear runtime state

  runewarden.dwc.riftlock()        | each callable directly so the user can
  runewarden.dwc.basic()           | bind a key/alias straight to the mode
  runewarden.dwc.disembowel()      | without going through setMode + dispatch.
  runewarden.dwc.headprep()        |
  runewarden.dwc.kelpstack()       |
  runewarden.dwc.lockprep()        |

--------------------------------------------------------------------------------
DEPENDENCY MAPPING (see DEPENDENCIES.md for the full table)
--------------------------------------------------------------------------------
AK (target state):
  tAffs.X                -> has("X")               (affstrack.score[X] >= 30)
  lb[target].hits[limb]  -> unchanged
  tBals.salve            -> targetBalDown("salve") (ak.bals.salve == false / nil)
  ataxiaTemp.lastAssess  -> targetHpPct()          (ak.currenthealth/maxhealth)
  ataxiaNDB_getClass(t)  -> DROPPED (was guarding the dead add_dedication branch)

Legacy (self state):
  ataxia.afflictions.X   -> selfAff("X")           (Legacy.Curing.Affs[X])
  ataxia.settings.paused -> Legacy.Settings.Curing.status == false
  ataxia.settings.separator -> "/" (hardcoded — SETALIAS ATK requires it)
  ataxia.vitals.class    -> charstat("Class")      (only used for impale_blackout, dropped)
  ataxia.vitals.hp/maxhp/mp/maxmp -> vital("hp") etc.
  gmcp.Char.Vitals.hp/mp -> vital("hp") / vital("mp")    (string -> number coerced)
  ataxia.getWeapon(slot) -> CONFIG.weapon1Id / CONFIG.weapon2Id (hardcoded; configurable)
  ataxiaTables.limbData.dwcSlash -> CONFIG.dwcSlashDamage (per-swing slash %)
  combatQueue()          -> REMOVED (Legacy handles pre-attack hooks externally)
  reboundHold.gate(fn)   -> reboundGate(fn) (stub — user can hook in their own gate)
  send("queue addclear free X") -> sendAttack(X, "FREE")
  send("queue addclear freestand X") -> sendAttack(X, "FREESTAND")  (used by lockprep)

Lock detection (was checkTargetLocks + getLockingAffliction in Levi):
  softlock = anorexia + asthma + slickness|bloodfire   (3-of-4)
  hardlock = softlock + impatience|sandfever
  truelock = hardlock + paralysis
  getLockingAffliction(target) -> DROPPED (required NDB class lookup;
    the truelock-specific venom branch falls through to the standard
    softlock/hardlock curare path)

Dead-code dropped (computed but never read in original files):
  add_dedication, partyrelay, impale_blackout, treelock, softlock (in 001-004)

Module-owned state (was bare globals or ataxiaTemp.*):
  engaged           -> runewarden.dwc.state.engaged
  need_falcon       -> runewarden.dwc.state.needFalcon
  falconattack      -> runewarden.dwc.state.falconAttack
  inc_imp           -> runewarden.dwc.state.incImpatience
  targetlimb        -> manual override via runewarden.dwc.state.targetLimb / global;
                       absent either, each mode auto-picks (autoPickLimb/resolveLimb)
  prepped_*         -> file-local per tick (recomputed every call)
  venoms            -> file-local per tick
  envenom1/envenom2 -> file-local per tick (kelpstack mode only)

External (unchanged): gmcp, ak, Legacy, target, lb, affstrack
================================================================================
]] --

-- ============================================================
--  NAMESPACE INIT
-- ============================================================
runewarden = runewarden or {}
runewarden.dwc = runewarden.dwc or {}

runewarden.dwc.mode = runewarden.dwc.mode or "basic"

runewarden.dwc.state = runewarden.dwc.state or {
    engaged = false,
    needFalcon = false,
    falconAttack = false,
    incImpatience = false,
    targetLimb = nil -- nil means "use auto-pick logic" or fallback to global `targetlimb`
}

-- ============================================================
--  CONFIG  (all tunables — replace item IDs with your own)
-- ============================================================
runewarden.dwc.CONFIG = runewarden.dwc.CONFIG or {
    -- AK affstrack confidence threshold (0-100). >= this counts as "present".
    affThreshold = 30,

    -- Per-strike DWC slash damage as a flat % of target HP. Was
    -- ataxiaTables.limbData.dwcSlash. Calibrate against a live target if needed.
    -- Used in `scim = dwc * 2` (two slashes per dsl) and `axe = scim - 3` (raze
    -- threshold detection for axe-damage-undershoots-100% case).
    dwcSlashDamage = 16,

    -- Axe-vs-scim differential (axe deals dwcSlashDamage - axeDelta per swing).
    -- Drives the need_raze2 / need_raze3 limb-prep raze branches.
    axeDelta = 3,

    -- Weapon item IDs for `wield` sends. The runie code originally pulled
    -- these from ataxia.getWeapon("weapon1"|"weapon2"). Hardcoded here for
    -- portability; override with your scimitar/axe IDs.
    weapon1Id = "scimitar1",
    weapon2Id = "scimitar2",

    -- Two-handed item ID for bisect kill (was `bastard` in 003/004, `longsword`
    -- in 001/002, `bastard` in 006). Use whatever you bisect with.
    bisectWeaponId = "bastard",

    -- Bisect HP% threshold. <= this triggers bisect kill if no shield.
    bisectHpThresh = 35,

    -- Empower rune priority for lockprep mode (Runelore).
    empowerRunes = "kena mannaz sleizak",

    -- Self lock-break cooldown (seconds) between `tree` attempts.
    lockBreakCooldown = 2
}

-- ============================================================
--  AK HELPERS
-- ============================================================
-- affstrack.score[aff] is a 0-100 confidence value: 100 = fresh apply,
-- lower = ambiguous cure reduced certainty, nil = no evidence.
local function has(aff)
    return affstrack and affstrack.score and (affstrack.score[aff] or 0) >=
               runewarden.dwc.CONFIG.affThreshold
end

-- Bulk check: returns true iff at least `n` of the listed affs are present.
-- Equivalent to Levi's checkAffList({...}, n).
local function hasN(list, n)
    local c = 0
    for _, a in ipairs(list) do
        if has(a) then
            c = c + 1
            if c >= n then
                return true
            end
        end
    end
    return false
end

-- Target HP%. Was ataxiaTemp.lastAssess (already a 0-100 number).
local function targetHpPct()
    if not ak or not ak.maxhealth or ak.maxhealth <= 0 then
        return 100
    end
    return math.floor((ak.currenthealth or 0) / ak.maxhealth * 100)
end

-- Target balance tracking. Levi's `tBals.salve == false` meant "salve is on
-- cooldown" (target recently applied a salve). AK convention used here:
-- ak.bals[name] = true means up, false means down. Returns true iff the
-- balance is known to be down (Levi's == false semantics).
local function targetBalDown(name)
    if not ak or not ak.bals then
        return false
    end
    return ak.bals[name] == false
end

-- Limb damage lookup. AK and Levi both use lb[target].hits[limb].
local function getLimbDamage(limb)
    if not target or not lb or not lb[target] or not lb[target].hits then
        return 0
    end
    return lb[target].hits[limb] or 0
end

-- ============================================================
--  GMCP / VITALS HELPERS
-- ============================================================
local function vital(key)
    return tonumber(gmcp and gmcp.Char and gmcp.Char.Vitals and
                        gmcp.Char.Vitals[key]) or 0
end

-- ============================================================
--  LEGACY (SELF) HELPERS
-- ============================================================
local function selfAff(name)
    local a = Legacy and Legacy.Curing and Legacy.Curing.Affs
    return a and a[name] or false
end

local function isPaused()
    return not (Legacy and Legacy.Settings and Legacy.Settings.Curing and
               Legacy.Settings.Curing.status)
end

-- ============================================================
--  SELF LOCK-BREAK  (collapsed Knight version)
-- ============================================================
-- Runewarden has TREE tattoo for random aff cure. Fitness is Monk-only;
-- knights use `touch tree` instead. The shikudo port's `fitness` send is
-- not appropriate here — replaced with `touch tree`.
local _lockBreakCooldown = 0

local function selfNeedLockBreak()
    return selfAff("asthma") and selfAff("anorexia") and
               (selfAff("slickness") or selfAff("bloodfire"))
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
    send("touch tree", false)
    _lockBreakCooldown = os.time() + runewarden.dwc.CONFIG.lockBreakCooldown
    return true
end

-- ============================================================
--  REBOUND HOLD GATE  (stub — was reboundHold.gate(fn) in Levi)
-- ============================================================
-- The Levi reboundHold subsystem defers attacks while we have rebounding
-- against physical-attack classes. It's not part of AK/Legacy. Provide a
-- stub the user can override:
--   runewarden.dwc.reboundGate = function(fn) return false end  -- never hold
-- Default returns false (never holds), which preserves attack flow.
runewarden.dwc.reboundGate = runewarden.dwc.reboundGate or function(_)
    return false
end

-- ============================================================
--  SEND HELPER  (Legacy SETALIAS ATK / QUEUE ADDCLEARFULL pattern)
-- ============================================================
-- Commands inside the ATK alias are `/`-separated, then queued.
-- queueType: "FREE" (most modes), "FREESTAND" (lockprep, was "queue
-- addclear freestand" in 007), or "EQBAL".
local function sendAttack(cmd, queueType)
    send("SETALIAS ATK " .. cmd)
    send("QUEUE ADDCLEARFULL " .. (queueType or "FREE") .. " ATK")
end

-- ============================================================
--  WEAPON / WIELD HELPERS
-- ============================================================
local function w1()
    return runewarden.dwc.CONFIG.weapon1Id
end
local function w2()
    return runewarden.dwc.CONFIG.weapon2Id
end

-- Standard wield-and-wipe prefix used by every DSL/raze command.
-- "wield w1 w2/wipe w1/wipe w2/"
local function wieldPrefix()
    return "wield " .. w1() .. " " .. w2() .. "/wipe " .. w1() .. "/wipe " ..
               w2() .. "/"
end

-- The dwcattack-style left/right split (was used by 006 only).
local function wieldLRPrefix()
    return "wield left " .. w1() .. "/wield right " .. w2() .. "/grip/"
end

-- ============================================================
--  LIMB-PREP CALCULATION
-- ============================================================
-- Per-call snapshot table. Computed at the top of each mode function.
-- Mirrors the prepped_leftleg / prepped_rightleg / prepped_torso / ... block
-- repeated near-verbatim in every source file.
--
-- "Prepped" = next dsl (two slashes) will break the limb AND it's not already
-- broken. "Raze-prepped" (prepped2_*) = one slash through raze would still
-- break, used in 007's raze-against-rebounding branches.
local function calcPrepped()
    local scim = runewarden.dwc.CONFIG.dwcSlashDamage * 2 -- dsl = two slashes
    local axe = scim - runewarden.dwc.CONFIG.axeDelta -- raze-undershoot detection
    local scim1 = runewarden.dwc.CONFIG.dwcSlashDamage -- single slash (raze)

    local p = {}
    local hits = {
        ll = getLimbDamage("left leg"),
        rl = getLimbDamage("right leg"),
        la = getLimbDamage("left arm"),
        ra = getLimbDamage("right arm"),
        h = getLimbDamage("head"),
        t = getLimbDamage("torso")
    }

    p.scim = scim
    p.axe = axe
    p.scim1 = scim1
    p.hits = hits

    p.leftleg = (hits.ll + scim >= 100) and not has("damagedleftleg")
    p.rightleg = (hits.rl + scim >= 100) and not has("damagedrightleg")
    p.leftarm = (hits.la + scim >= 100) and not has("damagedleftarm")
    p.rightarm = (hits.ra + scim >= 100) and not has("damagedrightarm")
    p.head = (hits.h + scim >= 100) and not has("damagedhead")
    p.torso = (hits.t + scim >= 100) and not has("mildtrauma")

    -- Raze-prepped (single-slash threshold under rebounding/shield).
    -- NOTE: source has a precedence bug — `and X or Y` mixed with `and Z` —
    -- preserved here. The intent appears to be "limb at single-slash prep
    -- and (shielded or rebounding)" but the original reads as "(... not
    -- damaged and shielded) or rebounding". Kept exact for fidelity.
    local sob = has("shield") or has("rebounding")
    p.razeLeftleg = (hits.ll + scim1 >= 100) and not has("damagedleftleg") and
                        sob
    p.razeRightleg = (hits.rl + scim1 >= 100) and not has("damagedrightleg") and
                         sob
    p.razeLeftarm = (hits.la + scim1 >= 100) and not has("damagedleftarm") and
                        sob
    p.razeRightarm = (hits.ra + scim1 >= 100) and not has("damagedrightarm") and
                         sob
    p.razeHead = (hits.h + scim1 >= 100) and not has("damagedhead") and sob
    p.razeTorso = (hits.t + scim1 >= 100) and not has("mildtrauma") and sob

    return p
end

-- "need_raze2 / need_raze3" — limb is dsl-prepped but axe-undershoots, i.e.
-- we need to raze first (one slash of raze + one of axe < 100, but two
-- scimitar slashes >= 100). Used by 001-004's raze branches.
local function needRazeForLimb(limb, p)
    if not p then
        return false
    end
    local d = getLimbDamage(limb)
    return (d + p.scim >= 100) and (d + p.axe < 100)
end

-- ============================================================
--  LOCK DETECTION
-- ============================================================
-- Was checkTargetLocks() — sets softlock / hardlock / truelock.
-- Returns them in a small struct rather than mutating globals.
local function checkLocks()
    local softlock = hasN({"anorexia", "asthma", "slickness", "bloodfire"}, 3)
    local hardlock = softlock and hasN({"impatience", "sandfever"}, 1)
    local truelock = hardlock and has("paralysis")
    return {soft = softlock, hard = hardlock, true_ = truelock}
end

-- ============================================================
--  TARGET LIMB RESOLUTION
-- ============================================================
-- The original code expects a global `targetlimb`. We read from
-- runewarden.dwc.state.targetLimb first, then fall back to the legacy
-- global, then to a default.
local function getTargetLimb(default)
    return runewarden.dwc.state.targetLimb or rawget(_G, "targetlimb") or
               default or "right leg"
end

-- Per-mode automatic limb selection. In Levi, `targetlimb` was a shared global
-- that the disembowel picker (dwcprioslimb) wrote and basic/riftlock read; the
-- consolidation turned each mode's pick into a function-local, so basic and
-- riftlock lost their auto-target and fell back to a fixed "right leg". This
-- restores per-mode auto-targeting (user choice: "pick based on the mode it's
-- running in", keep per-mode routes):
--   basic    -> disembowel route: torso -> right leg -> left leg
--   riftlock -> salvelock route:  right arm -> left arm, then torso -> legs
--     (epteth breaks arms; two broken arms + slickness + asthma = salvelock,
--      which is the whole point of riftlock — so drive the arms, not a leg.)
-- disembowel/headprep/lockprep keep their own inline pickers and do NOT route
-- through here. Returns nil when no limb applies (caller uses the default).
local function autoPickLimb(mode, p)
    if mode == "riftlock" then
        if not has("damagedrightarm") then return "right arm" end
        if not has("damagedleftarm") then return "left arm" end
        if not has("damagedtorso") then return "torso" end
        if not p.rightleg then return "right leg" end
        if not p.leftleg then return "left leg" end
        return nil
    end
    -- basic (and any future caller): disembowel prep order, matching the
    -- original dwcprioslimb() limb logic (003_Disembowel_Prep.lua:265-268).
    if not has("damagedtorso") then return "torso" end
    if not p.rightleg then return "right leg" end
    if p.rightleg and not p.leftleg then return "left leg" end
    return nil
end

-- Limb resolution with manual override priority:
--   manual setLimb (state.targetLimb) -> legacy global -> per-mode auto-pick -> default
-- This is what lets basic/riftlock target a limb on their own instead of
-- waiting for `rdwclimb`, while still honouring an explicit manual choice.
local function resolveLimb(mode, p, default)
    return runewarden.dwc.state.targetLimb or rawget(_G, "targetlimb") or
               autoPickLimb(mode, p) or default
end

function runewarden.dwc.setLimb(limb)
    runewarden.dwc.state.targetLimb = limb
    cecho("\n<cyan>[DWC] Target limb set to <yellow>" .. tostring(limb))
end

-- ============================================================
--  COMMAND HELPERS (build dsl / raze / impale / disembowel / bisect strings)
-- ============================================================
-- All return the full "wield...wipe...assess...action" tail. Caller prepends
-- any pre-attack chain (e.g. falcon slay/, contemplate, empower).
local function cmdAssess()
    return "assess " .. target
end

local function cmdDsl(limb, v1, v2)
    if limb then
        return wieldPrefix() .. cmdAssess() .. "/dsl " .. target .. " " .. limb ..
                   " " .. v1 .. " " .. v2
    end
    return wieldPrefix() .. cmdAssess() .. "/dsl " .. target .. " " .. v1 ..
               " " .. v2
end

local function cmdRazeslash(limb, v1)
    return wieldPrefix() .. cmdAssess() .. "/razeslash " .. target .. " " ..
               limb .. " " .. v1
end

local function cmdRazeslashNoLimb(v1)
    -- 002 BASIC's razeslash variant (no limb arg).
    return wieldPrefix() .. cmdAssess() .. "/razeslash " .. target .. " " .. v1
end

local function cmdImpale(furyOn)
    local s = wieldPrefix() .. cmdAssess() .. "/impale " .. target
    if furyOn then
        s = wieldPrefix() .. cmdAssess() .. "/fury on/impale " .. target
    end
    return s
end

local function cmdDisembowel()
    return wieldPrefix() .. "wipe " .. w1() .. "/wipe " .. w2() .. "/" ..
               cmdAssess() .. "/disembowel " .. target
end

local function cmdBisect()
    return "wield shield " .. runewarden.dwc.CONFIG.bisectWeaponId .. "/" ..
               cmdAssess() .. "/bisect " .. target .. " curare"
end

-- ============================================================
--  PRE-DISPATCH GATES (shared by every mode)
-- ============================================================
-- Returns true if the tick should be skipped.
local function preGate(fn)
    if not target or target == "" then
        return true
    end
    if isPaused() then
        return true
    end
    if runewarden.dwc.reboundGate(fn) then
        return true
    end
    if selfLockBreak() then
        return true
    end -- handled lock break; skip this tick
    if selfAff("stupidity") then
        return true
    end -- can't dispatch a stupid build
    return false
end

-- Build the appropriate engage suffix and queue type, then send.
local function dispatchAttack(atk, opts)
    opts = opts or {}
    local queueType = opts.queueType or "FREE"
    local engaged = runewarden.dwc.state.engaged
    local tail = ""

    if opts.bisect then
        -- 003/004 bisect path always reissues engage
        tail = "/engage " .. target
        sendAttack(atk .. tail, queueType)
        return
    end

    if not engaged then
        local pre = opts.falconPrefix or ""
        local post = opts.engageSuffix or ("/engage " .. target)
        sendAttack(pre .. atk .. post, queueType)
    else
        sendAttack(atk, queueType)
    end
end

-- ============================================================
--  ============== MODE 1: RIFTLOCK (was 001_RIFT.lua) ==========
-- ============================================================
-- Riftlock = anti-Restore lock build. When target lost salve balance AND
-- has addiction (vardrax landed, blocking dust/herb rifting), spam
-- epteth/epteth to break both arms, completing salvelock.
--
-- Venom priority cascade (later overrides earlier — matches original):
--   1.  !addiction              -> vardrax
--   2.  !weariness              -> vernalius
--   3.  !asthma                 -> kalmia
--   4.  !clumsiness             -> xentio
--   5.  !slickness + asthma + venoms[1]==curare  -> gecko (2nd slot)
--   6.  !nausea                 -> euphorbia
--   7.  !dizziness              -> larkspur
--   8.  !stupidity              -> aconite
--   9.  !recklessness           -> eurypteria
--   10. !shyness                -> digitalis
--   11. !sensitivity            -> prefarar x2
--   12. !darkshade              -> darkshade
--
-- Plus precondition inserts at the top of the table for the riftlock setup:
--   - !salve_bal + addiction    -> epteth, epteth   (the kill route)
--   - both legs prepped + dmg torso + ...sleeplock conditions -> delphinium x2
--   - one leg + head prepped + ...sleeplock conditions        -> delphinium x2
--   - slickness + !anorexia + paralysis + !stupidity          -> aconite, slike
--   - impatience + !anorexia + !slickness                     -> slike, gecko
--   - impatience + !anorexia + !salve_bal                     -> slike
--   - dmgHead + !stupidity                                    -> aconite
--   - dmgHead + !dizziness                                    -> larkspur
--   - dmgHead + !recklessness                                 -> eurypteria
--   - dmgHead + !shyness                                      -> digitalis
--
-- The first two slots of the venoms[] table feed dsl <v1> <v2>.
function runewarden.dwc.riftlock()
    if preGate(runewarden.dwc.riftlock) then
        return
    end

    local p = calcPrepped()
    local targetlimb = resolveLimb("riftlock", p, "right arm")
    local venoms = {}

    -- Precondition inserts (highest priority — head of table)
    if targetBalDown("salve") and has("addiction") then
        table.insert(venoms, "epteth")
        table.insert(venoms, "epteth")
    end

    if p.leftleg and p.rightleg and has("damagedtorso") and not has("prone") and
        not has("rebounding") and not has("shield") then
        table.insert(venoms, "delphinium")
        table.insert(venoms, "delphinium")
    end

    if (p.leftleg or p.rightleg) and p.head and not has("prone") and
        not has("rebounding") and not has("shield") then
        table.insert(venoms, "delphinium")
        table.insert(venoms, "delphinium")
    end

    if has("slickness") and not has("anorexia") and has("paralysis") and
        not has("stupidity") then
        table.insert(venoms, "aconite")
        table.insert(venoms, "slike")
    end

    if has("impatience") and not has("anorexia") and not has("slickness") then
        table.insert(venoms, "slike")
        table.insert(venoms, "gecko")
    end

    if has("impatience") and not has("anorexia") and not targetBalDown("salve") then
        table.insert(venoms, "slike")
    end

    if has("damagedhead") and not has("stupidity") then
        table.insert(venoms, "aconite")
    end
    if has("damagedhead") and not has("dizziness") then
        table.insert(venoms, "larkspur")
    end
    if has("damagedhead") and not has("recklessness") then
        table.insert(venoms, "eurypteria")
    end
    if has("damagedhead") and not has("shyness") then
        table.insert(venoms, "digitalis")
    end

    -- Standard venom cascade (lock/pressure builders)
    if not has("paralysis") then
        table.insert(venoms, "curare")
    end
    if not has("addiction") then
        table.insert(venoms, "vardrax")
    end
    if not has("weariness") then
        table.insert(venoms, "vernalius")
    end
    if not has("asthma") then
        table.insert(venoms, "kalmia")
    end
    if not has("clumsiness") then
        table.insert(venoms, "xentio")
    end
    if not has("slickness") and has("asthma") and venoms[1] == "curare" then
        table.insert(venoms, "gecko")
    end
    if not has("nausea") then
        table.insert(venoms, "euphorbia")
    end
    if not has("dizziness") then
        table.insert(venoms, "larkspur")
    end
    if not has("stupidity") then
        table.insert(venoms, "aconite")
    end
    if not has("recklessness") then
        table.insert(venoms, "eurypteria")
    end
    if not has("shyness") then
        table.insert(venoms, "digitalis")
    end
    if not has("sensitivity") then
        table.insert(venoms, "prefarar")
        table.insert(venoms, "prefarar")
    end
    if not has("darkshade") then
        table.insert(venoms, "darkshade")
    end

    -- Attack selection
    local useBisect = (targetHpPct() <= runewarden.dwc.CONFIG.bisectHpThresh)
    local disembowel = has("impaled") and getLimbDamage("torso") >= 100
    local needRaze = has("rebounding") or has("shield")
    local needRaze2 = needRazeForLimb(targetlimb, p) and
                          (targetlimb == "right leg" or targetlimb == "right arm")
    local needRaze3 = needRazeForLimb(targetlimb, p) and
                          (targetlimb == "left leg" or targetlimb == "left arm")

    local atk
    if useBisect then
        atk = cmdBisect()
    elseif disembowel then
        atk = cmdDisembowel()
    elseif needRaze or needRaze2 or needRaze3 then
        atk = cmdRazeslash(targetlimb, venoms[1])
    elseif has("prone") and has("damagedtorso") and has("damagedrightleg") and
        has("damagedleftleg") then
        atk = cmdImpale(false)
    elseif targetBalDown("salve") and has("addiction") then
        -- Riftlock kill route
        atk = cmdDsl(targetlimb, "epteth", "epteth")
    else
        -- Original 001_RIFT.lua:349 slashes the resolved targetlimb here; the
        -- first port pass dropped it to a no-limb dsl. With per-mode auto-pick,
        -- targetlimb is now the salvelock arm, so restore the limbed dsl.
        atk = cmdDsl(targetlimb, venoms[1] or "curare", venoms[2] or "kalmia")
    end

    dispatchAttack(atk)
end

-- ============================================================
--  ============== MODE 2: BASIC (was 002_BASIC_2.lua) ==========
-- ============================================================
-- Neutral DWC pressure. Falls back to disembowel mode when nausea is up and
-- legs/torso aren't prepped (i.e. we need to build limb damage first).
-- Healthleech bumps the bisect threshold (treated as low-HP for kill purposes).
function runewarden.dwc.basic()
    if preGate(runewarden.dwc.basic) then
        return
    end

    local p = calcPrepped()
    local targetlimb = resolveLimb("basic", p, "torso")
    local venoms = {}

    -- Setup venom inserts (high priority — head of table)
    if has("slickness") and not has("anorexia") and has("paralysis") and
        not has("stupidity") and has("asthma") and not has("rebounding") then
        table.insert(venoms, "aconite")
        table.insert(venoms, "slike")
    end
    if has("impatience") and not has("anorexia") and not has("slickness") and
        has("asthma") then
        table.insert(venoms, "slike")
        table.insert(venoms, "gecko")
    end
    if has("impatience") and not has("anorexia") and not targetBalDown("salve") then
        table.insert(venoms, "slike")
    end

    if has("anorexia") and not has("dizziness") then
        table.insert(venoms, "larkspur")
    end
    if has("anorexia") and not has("recklessness") then
        table.insert(venoms, "eurypteria")
    end
    if has("anorexia") and not has("shyness") then
        table.insert(venoms, "digitalis")
    end

    -- Standard cascade
    if not has("paralysis") then
        table.insert(venoms, "curare")
    end
    if not has("weariness") then
        table.insert(venoms, "vernalius")
    end
    if not has("asthma") then
        table.insert(venoms, "kalmia")
    end
    if not has("clumsiness") then
        table.insert(venoms, "xentio")
    end
    if not has("slickness") and has("asthma") and venoms[1] == "curare" then
        table.insert(venoms, "gecko")
    end
    if not has("recklessness") then
        table.insert(venoms, "eurypteria")
    end
    if not has("stupidity") then
        table.insert(venoms, "aconite")
    end
    if not has("dizziness") then
        table.insert(venoms, "larkspur")
    end
    if has("asthma") and not has("disloyalty") then
        table.insert(venoms, "monkshood")
    end
    if not has("shyness") then
        table.insert(venoms, "digitalis")
    end
    if not has("sensitivity") then
        table.insert(venoms, "prefarar")
        table.insert(venoms, "prefarar")
    end
    if not has("addiction") then
        table.insert(venoms, "vardrax")
    end
    if not has("darkshade") then
        table.insert(venoms, "darkshade")
    end

    -- Delegation: nausea up + unprepped torso/legs -> defer to disembowel mode
    -- (the original dwcprioslimb() recurses into 003's logic).
    if has("nausea") and not p.rightleg and not has("prone") then
        return runewarden.dwc.disembowel()
    end
    if has("nausea") and not p.leftleg and not has("prone") then
        return runewarden.dwc.disembowel()
    end
    if has("nausea") and not p.torso then
        return runewarden.dwc.disembowel()
    end

    -- Attack selection
    local useBisect = ((targetHpPct() <= runewarden.dwc.CONFIG.bisectHpThresh) and
                         not has("shield")) or has("healthleech")
    local disembowel = has("impaled") and getLimbDamage("torso") >= 100
    local needRaze = has("rebounding") or has("shield")
    local needRaze2 = needRazeForLimb(targetlimb, p) and
                          (targetlimb == "right leg" or targetlimb == "right arm")
    local needRaze3 = needRazeForLimb(targetlimb, p) and
                          (targetlimb == "left leg" or targetlimb == "left arm")

    local atk
    if useBisect then
        atk = cmdBisect()
    elseif disembowel then
        atk = cmdDisembowel()
    elseif needRaze or needRaze2 or needRaze3 then
        -- Follow the disembowel limb path: raze the picked limb. (002 originally
        -- dropped the limb arg; basic now aims it, like disembowel/riftlock.)
        atk = cmdRazeslash(targetlimb, venoms[1] or "curare")
    elseif has("prone") and has("damagedtorso") and has("damagedrightleg") and
        has("damagedleftleg") then
        atk = cmdImpale(false)
    elseif not has("rebounding") and not has("shield") and p.head and
        has("prone") then
        atk = cmdDsl("head", "gecko", "curare")
    elseif not has("damagedrightleg") and has("nausea") and not has("rebounding") and
        not has("shield") and p.rightleg and p.leftleg and not has("prone") and
        p.torso then
        atk = cmdDsl("right leg", "delphinium", "delphinium")
    elseif venoms[1] == "curare" then
        -- Follow the disembowel limb path: slash the picked limb (was no-limb).
        atk = cmdDsl(targetlimb, venoms[2] or "kalmia", venoms[1])
    else
        atk = cmdDsl(targetlimb, venoms[1] or "curare", venoms[2] or "kalmia")
    end

    -- 002's send prepends `falcon slay <target>;` always
    local falcon = "falcon slay " .. target .. "/"
    dispatchAttack(atk, {falconPrefix = falcon, engageSuffix = "/engage " .. target .. "/" .. cmdAssess()})
end

-- ============================================================
--  ============== MODE 3: DISEMBOWEL (was 003_Disembowel_Prep) ==
-- ============================================================
-- Torso-focused limb prep with auto-pick of targetlimb (torso → right leg →
-- left leg). Aggressive impale on prone+single-leg. Used as both a standalone
-- mode and the fallback for basic() under nausea+unprepped.
function runewarden.dwc.disembowel()
    if preGate(runewarden.dwc.disembowel) then
        return
    end

    local p = calcPrepped()
    local venoms = {}

    -- Setup inserts (head of table)
    if p.leftleg and p.rightleg and has("damagedtorso") and not has("prone") and
        not has("rebounding") and not has("shield") then
        table.insert(venoms, "delphinium")
        table.insert(venoms, "delphinium")
    end
    if (p.leftleg or p.rightleg) and p.head and not has("prone") and
        not has("rebounding") and not has("shield") then
        table.insert(venoms, "delphinium")
        table.insert(venoms, "delphinium")
    end
    if has("impatience") and not has("anorexia") and not has("slickness") and
        has("asthma") then
        table.insert(venoms, "slike")
        table.insert(venoms, "gecko")
    end
    if has("impatience") and not has("anorexia") and not targetBalDown("salve") then
        table.insert(venoms, "slike")
    end
    if has("slickness") and not has("anorexia") and not has("stupidity") and
        has("asthma") then
        table.insert(venoms, "aconite")
        table.insert(venoms, "slike")
    end
    if has("anorexia") and not has("dizziness") then
        table.insert(venoms, "larkspur")
    end
    if has("anorexia") and not has("stupidity") then
        table.insert(venoms, "aconite")
    end
    if has("anorexia") and not has("shyness") then
        table.insert(venoms, "digitalis")
    end
    if has("anorexia") and not has("recklessness") then
        table.insert(venoms, "eurypteria")
    end

    -- Standard cascade
    if not has("paralysis") then
        table.insert(venoms, "curare")
    end
    if not has("nausea") then
        table.insert(venoms, "vernalius")
    end
    if not has("asthma") then
        table.insert(venoms, "kalmia")
    end
    if not has("clumsiness") then
        table.insert(venoms, "xentio")
    end
    if not has("slickness") and has("asthma") and venoms[1] == "curare" then
        table.insert(venoms, "gecko")
    end
    if not has("addiction") then
        table.insert(venoms, "vardrax")
    end
    if not has("sensitivity") and has("deaf") then
        table.insert(venoms, "prefarar")
        table.insert(venoms, "prefarar")
    end
    if not has("sensitivity") and not has("deaf") then
        table.insert(venoms, "prefarar")
    end
    if not has("recklessness") then
        table.insert(venoms, "eurypteria")
    end
    if not has("stupidity") then
        table.insert(venoms, "aconite")
    end
    if not has("dizziness") then
        table.insert(venoms, "larkspur")
    end
    if not has("shyness") then
        table.insert(venoms, "digitalis")
    end
    if not has("brokenrightarm") then
        table.insert(venoms, "epteth")
    end
    if not has("brokenleftarm") then
        table.insert(venoms, "epteth")
    end
    if not has("darkshade") then
        table.insert(venoms, "darkshade")
    end

    -- Auto-pick target limb (torso → right leg → left leg)
    local targetlimb
    if not has("damagedtorso") then
        targetlimb = "torso"
    elseif not p.rightleg then
        targetlimb = "right leg"
    elseif p.rightleg and not p.leftleg then
        targetlimb = "left leg"
    else
        targetlimb = getTargetLimb("torso")
    end

    -- Attack selection
    local php = vital("hp") > 0 and
                    math.floor(vital("hp") / vital("maxhp") * 100) or 100
    local useBisect = php <= runewarden.dwc.CONFIG.bisectHpThresh
    local disembowel = has("impaled") or rawget(_G, "timpale") == true
    local needRaze = has("rebounding") or has("shield")
    local needRaze2 = needRazeForLimb(targetlimb, p) and
                          (targetlimb == "right leg" or targetlimb == "right arm")
    local needRaze3 = needRazeForLimb(targetlimb, p) and
                          (targetlimb == "left leg" or targetlimb == "left arm")

    local atk
    local queueType = "FREE"
    local engaged = runewarden.dwc.state.engaged
    local needFalcon = runewarden.dwc.state.needFalcon

    if useBisect and not has("shield") then
        atk = cmdBisect()
    elseif disembowel then
        atk = ";disembowel " .. target
    elseif has("prone") and has("damagedleftleg") then
        atk = wieldPrefix() .. cmdAssess() .. "/impale " .. target .. "/fury on"
    elseif p.hits.ll + p.scim >= 101 or has("damagedleftleg") then
        atk = wieldPrefix() .. "impale " .. target .. "/fury on"
    elseif needRaze or needRaze2 or needRaze3 then
        atk = cmdRazeslash(targetlimb, venoms[1])
    elseif not has("damagedrightleg") and has("nausea") and not has("rebounding") and
        not has("shield") and p.rightleg and p.leftleg and not has("prone") and
        has("damagedtorso") then
        atk = cmdDsl("right leg", "delphinium", "delphinium")
    elseif has("damagedrightleg") and not has("rebounding") and not has("shield") and
        p.leftleg and has("damagedtorso") and not has("slickness") then
        atk = cmdDsl("left leg", "gecko", "curare")
    elseif has("damagedrightleg") and not has("rebounding") and not has("shield") and
        p.leftleg and has("damagedtorso") and has("slickness") then
        atk = cmdDsl("left leg", "epteth", "curare")
    elseif has("nausea") and (not p.leftleg or not p.rightleg) then
        atk = cmdDsl(targetlimb, venoms[2] or "kalmia", venoms[1] or "curare")
    elseif has("nausea") and not has("damagedtorso") then
        atk = cmdDsl("torso", venoms[2] or "kalmia", venoms[1] or "curare")
    else
        atk = cmdDsl(nil, venoms[2] or "kalmia", venoms[1] or "curare")
    end

    -- 003's dispatch has its own send variants
    if useBisect then
        -- Specifically: "wield bastard;grip;assess;bisect;engage" (no DSL prefix)
        sendAttack("wield " .. runewarden.dwc.CONFIG.bisectWeaponId ..
                       "/grip/" .. cmdAssess() .. "/bisect " .. target ..
                       " curare/engage " .. target, queueType)
        return
    end
    if not engaged and needFalcon then
        sendAttack("falcon slay " .. target .. "/" .. atk .. "/engage " ..
                       target .. "/" .. cmdAssess(), queueType)
    elseif not engaged then
        sendAttack(atk .. "/engage " .. target .. "/" .. cmdAssess(), queueType)
    else
        sendAttack(atk .. "/" .. cmdAssess(), queueType)
    end
end

-- ============================================================
--  ============== MODE 4: HEADPREP (was 004_Head_Prep.lua) =====
-- ============================================================
-- Head-focused mental stack: prep head + one leg, then DSL head with
-- slike/aconite for impatience setup. Uses empower runes (Runelore).
-- Bound to the `xxx` alias in the original profile.
function runewarden.dwc.headprep()
    if preGate(runewarden.dwc.headprep) then
        return
    end

    local p = calcPrepped()
    local incImp = runewarden.dwc.state.incImpatience
    local venoms = {}

    -- Setup inserts
    if has("impatience") and has("anorexia") and not has("slickness") and
        not has("paralysis") then
        table.insert(venoms, "curare")
        table.insert(venoms, "gecko")
    end
    if has("impatience") and not has("anorexia") and has("slickness") and
        not has("paralysis") then
        table.insert(venoms, "curare")
        table.insert(venoms, "slike")
    end
    if has("impatience") and not has("anorexia") and not has("slickness") then
        table.insert(venoms, "gecko")
        table.insert(venoms, "slike")
    end
    if has("slickness") and not has("anorexia") and not has("stupidity") and
        has("asthma") then
        table.insert(venoms, "aconite")
        table.insert(venoms, "slike")
    end
    if has("impatience") and not has("anorexia") and not has("slickness") and
        has("asthma") then
        table.insert(venoms, "slike")
        table.insert(venoms, "gecko")
    end
    if has("impatience") and not has("anorexia") and not targetBalDown("salve") then
        table.insert(venoms, "slike")
    end

    if incImp and not has("paralysis") then
        table.insert(venoms, "curare")
    end
    if incImp and not has("asthma") then
        table.insert(venoms, "kalmia")
    end

    if has("anorexia") and not has("dizziness") then
        table.insert(venoms, "larkspur")
    end
    if has("anorexia") and not has("stupidity") then
        table.insert(venoms, "aconite")
    end
    if has("anorexia") and not has("shyness") then
        table.insert(venoms, "digitalis")
    end
    if has("anorexia") and not has("recklessness") then
        table.insert(venoms, "eurypteria")
    end

    -- Standard cascade
    if not has("paralysis") then
        table.insert(venoms, "curare")
    end
    if not has("nausea") then
        table.insert(venoms, "vernalius")
    end
    if not has("asthma") then
        table.insert(venoms, "kalmia")
    end
    if not has("clumsiness") then
        table.insert(venoms, "xentio")
    end
    if not has("slickness") and has("asthma") and venoms[1] == "curare" then
        table.insert(venoms, "gecko")
    end
    if not has("sensitivity") and has("deaf") then
        table.insert(venoms, "prefarar")
        table.insert(venoms, "prefarar")
    end
    if not has("sensitivity") and not has("deaf") then
        table.insert(venoms, "prefarar")
    end
    if not has("addiction") then
        table.insert(venoms, "vardrax")
    end
    if not has("recklessness") then
        table.insert(venoms, "eurypteria")
    end
    if not has("stupidity") then
        table.insert(venoms, "aconite")
    end
    if not has("dizziness") then
        table.insert(venoms, "larkspur")
    end
    if not has("shyness") then
        table.insert(venoms, "digitalis")
    end
    if not has("brokenrightarm") then
        table.insert(venoms, "epteth")
    end
    if not has("brokenleftarm") then
        table.insert(venoms, "epteth")
    end
    if not has("darkshade") then
        table.insert(venoms, "darkshade")
    end

    -- Auto-pick limb (head → right leg → ...)
    local targetlimb
    if not p.head then
        targetlimb = "head"
    elseif not p.rightleg then
        targetlimb = "right leg"
    elseif has("damagedrightleg") and not has("damagedhead") and p.head then
        targetlimb = "head"
    elseif p.rightleg and not p.leftleg then
        targetlimb = "left leg"
    else
        targetlimb = getTargetLimb("head")
    end

    -- Attack selection
    local useBisect = targetHpPct() <= runewarden.dwc.CONFIG.bisectHpThresh
    local disembowel = has("impaled")
    local needRaze = has("rebounding") or has("shield")
    local needRaze2 = needRazeForLimb(targetlimb, p) and
                          (targetlimb == "right leg" or targetlimb == "right arm")
    local needRaze3 = needRazeForLimb(targetlimb, p) and
                          (targetlimb == "left leg" or targetlimb == "left arm")

    local atk
    if useBisect and not has("shield") then
        atk = cmdBisect()
    elseif disembowel then
        atk = ";disembowel " .. target
    elseif needRaze or needRaze2 or needRaze3 then
        atk = cmdRazeslash(targetlimb, venoms[1])
    elseif has("prone") and has("damagedleftleg") then
        atk = wieldPrefix() .. cmdAssess() .. "/fury on/impale " .. target
    elseif not has("damagedrightleg") and has("nausea") and not has("rebounding") and
        not has("shield") and p.rightleg then
        atk = cmdDsl("right leg", "delphinium", "delphinium")
    elseif has("damagedrightleg") and not has("rebounding") and not has("shield") and
        p.head then
        atk = cmdDsl("head", "slike", "aconite")
    elseif has("nausea") and not has("rebounding") and not has("shield") and
        has("damagedhead") then
        atk = cmdDsl("head", venoms[2] or "kalmia", venoms[1] or "curare")
    elseif has("damagedrightleg") and not has("rebounding") and not has("shield") and
        p.leftleg and has("damagedtorso") and not has("slickness") then
        atk = cmdDsl("left leg", "gecko", "curare")
    elseif has("damagedrightleg") and not has("rebounding") and not has("shield") and
        p.leftleg and has("damagedtorso") and has("slickness") then
        atk = cmdDsl("left leg", "epteth", "curare")
    elseif has("nausea") and (not p.leftleg or not p.rightleg) then
        atk = cmdDsl(targetlimb, venoms[2] or "kalmia", venoms[1] or "curare")
    elseif has("nausea") and not has("damagedtorso") then
        atk = cmdDsl("torso", venoms[2] or "kalmia", venoms[1] or "curare")
    else
        atk = cmdDsl(nil, venoms[2] or "kalmia", venoms[1] or "curare")
    end

    -- 004's send wires empower runes + contemplate
    local queueType = "FREE"
    local engaged = runewarden.dwc.state.engaged
    local needFalcon = runewarden.dwc.state.needFalcon
    local empower = "empower priority set " ..
                        runewarden.dwc.CONFIG.empowerRunes
    local contemplate = "contemplate " .. target

    if useBisect then
        sendAttack("wield " .. runewarden.dwc.CONFIG.bisectWeaponId ..
                       "/grip/" .. cmdAssess() .. "/bisect " .. target ..
                       " curare/engage " .. target, queueType)
        return
    end
    if not engaged and needFalcon then
        sendAttack(empower .. "/falcon slay " .. target .. "/" .. atk ..
                       "/engage " .. target .. "/" .. cmdAssess() .. "/" ..
                       contemplate, queueType)
    elseif not engaged then
        sendAttack(empower .. "/" .. atk .. "/engage " .. target .. "/" ..
                       cmdAssess() .. "/" .. contemplate, queueType)
    else
        sendAttack(empower .. "/" .. atk .. "/" .. cmdAssess() .. "/" ..
                       contemplate, queueType)
    end
end

-- ============================================================
--  ============== MODE 5: KELPSTACK (was 005+006) ===============
-- ============================================================
-- Kelp-stack single-venom selection. The original had three functions
-- (runiedwckelpstack2 -> envenom2dwc -> dwcattack); collapsed here into
-- one. envenom1 uses a cascading-IF priority (LAST match wins); envenom2
-- uses an elseif chain (FIRST match wins). Both behaviors preserved.
--
-- The attack uses `rsl` (raze-slash with one venom) when target is
-- rebounding/shielded, otherwise `dsl <v1> <v2>` with no limb arg.
-- Wield is split L/R (was `wield left X/wield right Y/grip`).
function runewarden.dwc.kelpstack()
    if preGate(runewarden.dwc.kelpstack) then
        return
    end

    local locks = checkLocks()
    local softlock = locks.soft
    -- envenom1 — cascading priority (LAST wins, matches original)
    local envenom1
    if softlock and not has("recklessness") then
        envenom1 = "eurypteria"
    end
    if softlock and not has("stupidity") then
        envenom1 = "aconite"
    end
    if softlock and not has("brokenleftarm") then
        envenom1 = "epteth"
    end
    if softlock and not has("brokenrightarm") then
        envenom1 = "epteth"
    end

    local envenom2 -- envenom2 may be set early if envenom1 takes the prone branch
    if has("prone") then
        envenom1 = "epseth"
        envenom2 = "epseth"
    end
    if has("prone") and not has("anorexia") and not targetBalDown("salve") then
        envenom1 = "slike"
    end
    if has("slickness") and not has("anorexia") and has("asthma") then
        envenom1 = "slike"
    end
    if has("asthma") and not has("slickness") then
        envenom1 = "gecko"
    end
    if not has("addiction") and has("weariness") then
        envenom1 = "vardrax"
    end
    if not has("weariness") then
        envenom1 = "vernalius"
    end
    if not has("asthma") then
        envenom1 = "kalmia"
    end
    if not has("clumsiness") then
        envenom1 = "xentio"
    end

    -- envenom2 — elseif chain (FIRST match wins), unless prone above already set it
    if not envenom2 then
        if not has("paralysis") then
            envenom2 = "curare"
        elseif has("asthma") and not has("slickness") and not has("paralysis") then
            envenom2 = "curare"
        elseif softlock and not has("recklessness") and envenom1 ~= "eurypteria" then
            envenom2 = "eurypteria"
        elseif softlock and not has("stupidity") and envenom1 ~= "aconite" then
            envenom2 = "aconite"
        elseif softlock and not has("brokenleftarm") and not has("brokenrightarm") and
            envenom1 == "epteth" then
            envenom2 = "epteth"
        elseif has("prone") and envenom1 == "epseth" then
            envenom2 = "epseth"
        elseif has("prone") and not has("anorexia") and not targetBalDown("salve") and
            envenom1 ~= "slike" then
            envenom2 = "slike"
        elseif not has("paralysis") and envenom1 ~= "curare" then
            envenom2 = "curare"
        elseif has("slickness") and not has("anorexia") and has("asthma") and
            envenom1 ~= "slike" then
            envenom2 = "slike"
        elseif has("asthma") and not has("slickness") and envenom1 ~= "slike" then
            envenom2 = "slike"
        elseif not has("addiction") and has("weariness") and envenom1 ~= "vardrax" then
            envenom2 = "vardrax"
        elseif not has("paralysis") and envenom1 ~= "curare" then
            envenom2 = "curare"
        elseif not has("weariness") and envenom1 ~= "vernalius" then
            envenom2 = "vernalius"
        elseif not has("asthma") and envenom1 ~= "kalmia" then
            envenom2 = "kalmia"
        elseif not has("clumsiness") and envenom1 ~= "xentio" then
            envenom2 = "xentio"
        end
    end

    -- Fallbacks (original may leave envenom1/2 nil under extreme states)
    envenom1 = envenom1 or "kalmia"
    envenom2 = envenom2 or "curare"

    -- Attack selection (was dwcattack)
    local useBisect = targetHpPct() <= runewarden.dwc.CONFIG.bisectHpThresh
    local engaged = runewarden.dwc.state.engaged

    if has("rebounding") or has("shield") then
        local atk = wieldLRPrefix() .. "falcon slay " .. target .. "/" ..
                        cmdAssess() .. "/rsl " .. target .. " " .. envenom2
        if not engaged then
            sendAttack(atk .. "/engage " .. target, "FREE")
        else
            sendAttack(atk, "FREE")
        end
    elseif useBisect then
        sendAttack("wield " .. runewarden.dwc.CONFIG.bisectWeaponId ..
                       "/grip/" .. cmdAssess() .. "/bisect " .. target ..
                       " curare/engage " .. target, "FREE")
    else
        local atk = wieldLRPrefix() .. "falcon slay " .. target .. "/" ..
                        cmdAssess() .. "/dsl " .. target .. " " .. envenom1 ..
                        " " .. envenom2
        if not engaged then
            sendAttack(atk .. "/engage " .. target, "FREE")
        else
            sendAttack(atk, "FREE")
        end
    end
end

-- ============================================================
--  ============== MODE 6: LOCKPREP (was 007_LeviDWCDisembowel) ==
-- ============================================================
-- Lock-aware disembowel prep with empower runes. Uses two-pass venom
-- selection (each pass aware of lock state), per-limb raze under
-- rebounding/shield, and double-break detection. Queue type is FREESTAND.
--
-- The original referenced getLockingAffliction(target) for class-specific
-- truelock venoms — that required NDB. Here the truelock branch falls
-- through to the standard softlock/hardlock curare path (still kills the
-- target, just without the per-class optimization).
function runewarden.dwc.lockprep()
    if preGate(runewarden.dwc.lockprep) then
        return
    end

    local p = calcPrepped()
    local locks = checkLocks()

    -- Venoms[1] — first pass priority
    local venoms = {}
    if locks.true_ then
        -- DROPPED: per-class locking-aff branch (no NDB). Falls through.
    elseif locks.hard and not has("paralysis") then
        table.insert(venoms, "curare")
    elseif locks.soft and not has("paralysis") then
        table.insert(venoms, "curare")
    elseif has("asthma") and has("impatience") and not has("anorexia") and
        has("slickness") then
        table.insert(venoms, "slike")
    elseif has("asthma") and has("impatience") and has("anorexia") and
        not has("slickness") then
        table.insert(venoms, "gecko")
    elseif has("asthma") and has("impatience") and not has("anorexia") and
        not has("slickness") then
        table.insert(venoms, "slike")
    elseif not has("paralysis") then
        table.insert(venoms, "curare")
    elseif has("paralysis") then
        if has("slickness") and has("asthma") and has("impatience") and
            not has("anorexia") then
            table.insert(venoms, "slike")
        elseif not has("slickness") and has("asthma") and has("impatience") then
            table.insert(venoms, "gecko")
        elseif not has("slickness") and has("asthma") then
            table.insert(venoms, "gecko")
        elseif not has("nausea") then
            table.insert(venoms, "vernalius")
        elseif not has("clumsiness") then
            table.insert(venoms, "xentio")
        elseif not has("asthma") then
            table.insert(venoms, "kalmia")
        elseif not has("weariness") then
            table.insert(venoms, "vernalius")
        end
    end

    -- Venoms[2] — second pass priority
    if locks.true_ then
        -- DROPPED: per-class locking-aff branch
    elseif locks.hard and not has("paralysis") and venoms[1] ~= "curare" then
        table.insert(venoms, "curare")
    elseif locks.soft and not has("paralysis") and venoms[1] ~= "curare" then
        table.insert(venoms, "curare")
    elseif has("asthma") and has("impatience") and not has("anorexia") and
        not has("slickness") and venoms[1] == "slike" then
        table.insert(venoms, "gecko")
    elseif has("asthma") and has("impatience") and not has("anorexia") and
        not has("slickness") and venoms[1] == "gecko" then
        table.insert(venoms, "slike")
    elseif not has("paralysis") and venoms[1] ~= "curare" then
        table.insert(venoms, "curare")
    elseif not has("nausea") and venoms[1] ~= "vernalius" then
        table.insert(venoms, "vernalius")
    elseif has("slickness") and has("asthma") and has("impatience") and
        not has("anorexia") and venoms[1] ~= "slike" then
        table.insert(venoms, "slike")
    elseif not has("slickness") and has("asthma") and has("impatience") and
        venoms[1] ~= "gecko" then
        table.insert(venoms, "gecko")
    elseif not has("slickness") and has("asthma") and venoms[1] ~= "gecko" then
        table.insert(venoms, "gecko")
    elseif has("clumsiness") and not has("asthma") and venoms[1] ~= "kalmia" then
        table.insert(venoms, "kalmia")
    elseif not has("clumsiness") and venoms[1] ~= "xentio" then
        table.insert(venoms, "xentio")
    elseif not has("weariness") and venoms[1] ~= "vernalius" then
        table.insert(venoms, "vernalius")
    elseif not has("addiction") and venoms[1] ~= "vardrax" then
        table.insert(venoms, "vardrax")
    elseif not has("darkshade") and venoms[1] ~= "darkshade" then
        table.insert(venoms, "darkshade")
    elseif not has("stupidity") and venoms[1] ~= "aconite" then
        table.insert(venoms, "aconite")
    else
        table.insert(venoms, "prefarar")
    end

    venoms[1] = venoms[1] or "curare"
    venoms[2] = venoms[2] or "prefarar"

    -- Auto-pick limb (torso → right leg → left leg)
    local targetlimb
    if not p.torso then
        targetlimb = "torso"
    elseif not p.rightleg then
        targetlimb = "right leg"
    elseif not p.leftleg then
        targetlimb = "left leg"
    else
        targetlimb = getTargetLimb("torso")
    end

    -- Attack selection
    local useBisect = targetHpPct() <= runewarden.dwc.CONFIG.bisectHpThresh
    local disembowel = has("impaled")
    local empower = "empower priority set " ..
                        runewarden.dwc.CONFIG.empowerRunes
    local contemplate = "/" .. cmdAssess() .. "/contemplate " .. target

    local atk
    if useBisect and not has("shield") then
        atk = "wield " .. runewarden.dwc.CONFIG.bisectWeaponId .. "/" ..
                  cmdAssess() .. "/bisect " .. target .. " curare"
    elseif disembowel then
        atk = ";disembowel " .. target
    elseif has("rebounding") and not has("shield") then
        local limbForRaze
        if has("nausea") then
            if p.torso then
                limbForRaze = "torso"
            elseif p.leftleg then
                limbForRaze = "left leg"
            elseif p.rightleg then
                limbForRaze = "right leg"
            end
        end
        if limbForRaze then
            atk = wieldPrefix() .. empower .. "/razeslash " .. target .. " " ..
                      limbForRaze .. " " .. venoms[1] .. contemplate
        else
            atk = wieldPrefix() .. empower .. "/razeslash " .. target .. " " ..
                      venoms[1] .. contemplate
        end
    elseif not has("rebounding") and has("shield") then
        local limbForRaze
        if has("nausea") then
            if p.torso then
                limbForRaze = "torso"
            elseif p.leftleg then
                limbForRaze = "left leg"
            elseif p.rightleg then
                limbForRaze = "right leg"
            end
        end
        if limbForRaze then
            atk = wieldPrefix() .. empower .. "/razeslash " .. target .. " " ..
                      limbForRaze .. " " .. venoms[1] .. contemplate
        else
            atk = wieldPrefix() .. empower .. "/razeslash " .. target .. " " ..
                      venoms[1] .. contemplate
        end
    elseif has("shield") and has("rebounding") then
        atk = wieldPrefix() .. empower .. "/raze " .. target .. contemplate
    elseif has("prone") and has("damagedleftleg") and has("damagedrightleg") then
        atk = wieldPrefix() .. cmdAssess() .. "/fury on/impale " .. target
    elseif (has("damagedrightleg") and p.leftleg and has("mildtrauma")) or
        (getLimbDamage("torso") >= 100 and has("prone")) then
        atk = wieldPrefix() .. cmdAssess() .. "/dsl " .. target ..
                  " left leg " .. venoms[2] .. " " .. venoms[1] .. contemplate
    elseif has("nausea") then
        if (p.rightleg and p.leftleg and has("mildtrauma")) or
            (getLimbDamage("torso") >= 100 and not has("prone")) then
            atk = wieldPrefix() .. cmdAssess() .. "/dsl " .. target ..
                      " right leg delphinium delphinium" .. contemplate
        elseif p.rightleg and p.leftleg and p.torso and not has("mildtrauma") then
            atk = wieldPrefix() .. cmdAssess() .. "/dsl " .. target ..
                      " torso " .. venoms[2] .. " " .. venoms[1] .. contemplate
        elseif p.rightleg and p.torso and not p.leftleg and not p.razeLeftleg then
            atk = wieldPrefix() .. cmdAssess() .. "/dsl " .. target ..
                      " left leg " .. venoms[2] .. " " .. venoms[1] ..
                      contemplate
        elseif p.leftleg and p.torso and not p.rightleg and not p.razeRightleg then
            atk = wieldPrefix() .. cmdAssess() .. "/dsl " .. target ..
                      " right leg " .. venoms[2] .. " " .. venoms[1] ..
                      contemplate
        elseif not p.torso then
            atk = wieldPrefix() .. cmdAssess() .. "/dsl " .. target ..
                      " torso " .. venoms[2] .. " " .. venoms[1] .. contemplate
        elseif not p.rightleg then
            atk = wieldPrefix() .. cmdAssess() .. "/dsl " .. target ..
                      " right leg " .. venoms[2] .. " " .. venoms[1] ..
                      contemplate
        elseif not p.leftleg then
            atk = wieldPrefix() .. cmdAssess() .. "/dsl " .. target ..
                      " left leg " .. venoms[2] .. " " .. venoms[1] ..
                      contemplate
        else
            -- All prepped, no specific case — fall through to default
            atk = wieldPrefix() .. cmdAssess() .. "/dsl " .. target .. " " ..
                      venoms[2] .. " " .. venoms[1] .. contemplate
        end
    else
        atk = wieldPrefix() .. cmdAssess() .. "/dsl " .. target .. " " ..
                  venoms[2] .. " " .. venoms[1] .. contemplate
    end

    -- 007's send uses FREESTAND queue with optional falcon append
    local queueType = "FREESTAND"
    local engaged = runewarden.dwc.state.engaged
    local falconAttack = runewarden.dwc.state.falconAttack

    if falconAttack then
        if not engaged then
            sendAttack(atk .. "/engage " .. target, queueType)
        else
            sendAttack(atk, queueType)
        end
    else
        if not engaged then
            sendAttack(atk .. "/falcon slay " .. target .. "/engage " ..
                           target, queueType)
        else
            sendAttack(atk .. "/falcon slay " .. target, queueType)
        end
    end
end

-- ============================================================
--  MODE ROUTER
-- ============================================================
local MODE_FNS = {
    riftlock = runewarden.dwc.riftlock,
    basic = runewarden.dwc.basic,
    disembowel = runewarden.dwc.disembowel,
    headprep = runewarden.dwc.headprep,
    kelpstack = runewarden.dwc.kelpstack,
    lockprep = runewarden.dwc.lockprep
}

function runewarden.dwc.setMode(mode)
    if MODE_FNS[mode] then
        runewarden.dwc.mode = mode
        cecho("\n<cyan>[DWC] Mode set to: <yellow>" .. mode)
    else
        cecho("\n<red>[DWC] Invalid mode: <yellow>" .. tostring(mode))
        cecho(
            "\n<red>[DWC] Valid: riftlock, basic, disembowel, headprep, kelpstack, lockprep")
    end
end

function runewarden.dwc.dispatch()
    local fn = MODE_FNS[runewarden.dwc.mode]
    if not fn then
        cecho("\n<red>[DWC] No handler for mode: " ..
                  tostring(runewarden.dwc.mode))
        return
    end
    fn()
end

function runewarden.dwc.status()
    local s = runewarden.dwc.state
    cecho("\n<cyan>[DWC] Status")
    cecho("\n<cyan>| <white>Mode: <yellow>" .. tostring(runewarden.dwc.mode))
    cecho("\n<cyan>| <white>Target: <yellow>" .. tostring(target))
    cecho("\n<cyan>| <white>Target limb: <yellow>" ..
              tostring(s.targetLimb or rawget(_G, "targetlimb") or "(auto per-mode)"))
    cecho("\n<cyan>| <white>Engaged: <yellow>" .. tostring(s.engaged))
    cecho("\n<cyan>| <white>Need falcon: <yellow>" .. tostring(s.needFalcon))
    cecho("\n<cyan>| <white>Falcon attack: <yellow>" ..
              tostring(s.falconAttack))
    cecho("\n<cyan>| <white>Inc impatience: <yellow>" ..
              tostring(s.incImpatience))
    cecho("\n<cyan>| <white>Target HP%: <yellow>" .. targetHpPct())
end

function runewarden.dwc.reset()
    runewarden.dwc.state = {
        engaged = false,
        needFalcon = false,
        falconAttack = false,
        incImpatience = false,
        targetLimb = nil
    }
    cecho("\n<cyan>[DWC] State reset")
end

-- ============================================================
--  TOP-LEVEL ALIAS WRAPPERS  (keep input-line typeable)
-- ============================================================
function rrift()
    runewarden.dwc.riftlock()
end
function rbasic()
    runewarden.dwc.basic()
end
function rdism()
    runewarden.dwc.disembowel()
end
function rhead()
    runewarden.dwc.headprep()
end
function rkelp()
    runewarden.dwc.kelpstack()
end
function rlock()
    runewarden.dwc.lockprep()
end
function rdwc()
    runewarden.dwc.dispatch()
end
function rdwcstatus()
    runewarden.dwc.status()
end
function rdwcreset()
    runewarden.dwc.reset()
end
function rdwcmode(m)
    runewarden.dwc.setMode(m)
end
function rdwclimb(l)
    runewarden.dwc.setLimb(l)
end
