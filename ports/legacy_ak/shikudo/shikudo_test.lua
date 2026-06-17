--[[
================================================================================
SHIKUDO GOD MODE — SMOKE TEST
================================================================================
Self-contained harness. Stubs the host globals (target / lb / affstrack /
gmcp.charstats / targetparry / Legacy / ak / send / cecho), drives
monk.shikudo.dispatch() through representative states, and asserts the command
queued into the SKATK alias.

Run from inside ports/legacy_ak/shikudo/ :   lua shikudo_test.lua
Non-zero exit on any failed assertion.
================================================================================
]] --

-- ── Host-global stubs ──────────────────────────────────────
local sent = {}
function send(s) sent[#sent + 1] = s end
function cecho(_) end
function getEpoch() return os.clock() end
function tempTimer(_, _) return 0 end
function killTimer(_) end

target = "dummy"
targetparry = "none"
lb = { dummy = { hits = {} } }
affstrack = { score = {} }
gmcp = { Char = { Vitals = { charstats = {} } } }
ak = { maxhealth = 6000, limbs = { hyperfocus = "head" } }
Legacy = {
    Curing = { Affs = {}, Defs = { current = {} } },
    Settings = { Curing = { status = true }, Basher = { status = false } }
}

-- ── Load the module under test ─────────────────────────────
dofile("shikudo.lua")
local mod = monk.shikudo
local ALIAS = mod.CONFIG.aliasName

-- ── Assertion framework ────────────────────────────────────
local fails = 0
local function check(name, cond, detail)
    if cond then
        print("PASS  " .. name)
    else
        fails = fails + 1
        print("FAIL  " .. name .. (detail and ("   -> got: " .. tostring(detail)) or ""))
    end
end

-- ── Scenario helpers ───────────────────────────────────────
-- Reset all mutable host state + module state to a clean baseline.
local function reset()
    sent = {}
    targetparry = "none"
    lb.dummy.hits = {}
    affstrack.score = {}
    gmcp.Char.Vitals.charstats = { "Form: Rain", "Kata: 0" }
    Legacy.Curing.Affs = {}
    Legacy.Settings.Curing.status = true
    ak.limbs.hyperfocus = "head" -- assume hyperfocus already on head unless a test changes it
end

local function setForm(form, kata)
    gmcp.Char.Vitals.charstats = { "Form: " .. form, "Kata: " .. tostring(kata or 0) }
end

-- limbs: { LL=.., RL=.., LA=.., RA=.., H=.., T=.. } as break-progress %
local function setLimbs(t)
    lb.dummy.hits = {
        ["left leg"] = t.LL or 0,
        ["right leg"] = t.RL or 0,
        ["left arm"] = t.LA or 0,
        ["right arm"] = t.RA or 0,
        head = t.H or 0,
        torso = t.T or 0
    }
end

-- affs: list of affstrack aff names to mark present (confidence 100)
local function setAffs(list)
    for _, a in ipairs(list or {}) do affstrack.score[a] = 100 end
end

-- Run one tick and return the SETALIAS payload, the QUEUE line, and any raw send.
local function fire()
    sent = {}
    mod.dispatch()
    local payload, queue, raw
    for _, s in ipairs(sent) do
        local p = s:match("^SETALIAS " .. ALIAS .. " (.+)$")
        if p then payload = p end
        if s:match("^QUEUE ADDCLEARFULL") then queue = s end
        if not s:match("^SETALIAS") and not s:match("^QUEUE") then raw = s end
    end
    return payload, queue, raw
end

local function contains(s, sub)
    return s ~= nil and s:find(sub, 1, true) ~= nil
end

-- ============================================================
--  SCENARIOS
-- ============================================================

-- 1) RAIN BUILD: kick-first, frontkick + staff prep.
do
    reset(); setForm("Rain", 0); setLimbs({})
    local p, q = fire()
    check("rain build: kick-first frontkick", p and p:find("^combo dummy frontkick") ~= nil, p)
    check("rain build: stacks a staff hit", contains(p, "ruku") or contains(p, "kuro"), p)
    check("rain build: queued EQBAL on SKATK", q == "QUEUE ADDCLEARFULL EQBAL " .. ALIAS, q)
end

-- 2) OAK BUILD (head unprepped): nervestrike head-prep + risingkick head.
do
    reset(); setForm("Oak", 3); setLimbs({ LL = 92, RL = 92, LA = 92, RA = 92, H = 0 })
    local p = fire()
    check("oak build: nervestrike for head prep", contains(p, "nervestrike"), p)
    check("oak build: risingkick head", contains(p, "risingkick head"), p)
    check("oak build: staff-first (kick last)", p and p:find("risingkick head$") ~= nil, p)
end

-- 3) GAITAL COMBO 1 (hyperfocus on head): drop hyperfocus, then sweep + flashheel left.
do
    reset(); setForm("Gaital", 0); setLimbs({ LL = 92, RL = 92, LA = 92, RA = 92, H = 88 })
    ak.limbs.hyperfocus = "head"
    local p = fire()
    check("combo1: drops hyperfocus then sweeps", p == "hyperfocus none/combo dummy sweep flashheel left", p)
end

-- 3b) GAITAL COMBO 1 (hyperfocus already off head): sweep with no hyperfocus-none prefix.
do
    reset(); setForm("Gaital", 0); setLimbs({ LL = 92, RL = 92, LA = 92, RA = 92, H = 88 })
    ak.limbs.hyperfocus = "none"
    local p = fire()
    check("combo1: no needless hyperfocus drop", p == "combo dummy sweep flashheel left", p)
end

-- 4) GAITAL COMBO 2: prone + left leg broken, arms intact -> ruku/ruku/flashheel right.
do
    reset(); setForm("Gaital", 1); setLimbs({ LL = 100, RL = 50, LA = 50, RA = 50, H = 50 })
    setAffs({ "prone" })
    local p = fire()
    check("combo2: ruku left ruku right flashheel right", p == "combo dummy ruku left ruku right flashheel right", p)
end

-- 5) GAITAL COMBO 3: prone + both arms + right leg broken -> needle + staff + flashheel left.
do
    reset(); setForm("Gaital", 2); setLimbs({ LL = 100, RL = 100, LA = 100, RA = 100, H = 88 })
    setAffs({ "prone" })
    local p = fire()
    check("combo3: leads with needle", p and p:find("^combo dummy needle") ~= nil, p)
    check("combo3: ends flashheel left", contains(p, "flashheel left"), p)
end

-- 6) DISPATCH: prone + head broken + crushedthroat.
do
    reset(); setForm("Gaital", 2); setLimbs({ H = 100 })
    setAffs({ "prone", "crushedthroat" })
    local p = fire()
    check("dispatch: kill move", p == "dispatch dummy", p)
end

-- 7) LOCK FORK (k>=5): both arms broken + 3 lock affs -> transition to Rain, bundled
--    with the first Rain lock combo (a clean transition doesn't consume balance).
do
    reset(); setForm("Gaital", 6); setLimbs({ LA = 100, RA = 100, H = 50 })
    setAffs({ "slickness", "asthma", "addiction" })
    local p = fire()
    check("lock fork: transition Rain + bundled lock combo",
        p == "transition to the Rain form/combo dummy frontkick left kuro left kuro right", p)
end

-- 7b) CLEAN TRANSITION (k>=5): Tykonos->Willow bundles the first Willow combo on the
--     same balance (transition needs balance but doesn't consume it).
do
    reset(); setForm("Tykonos", 6); setLimbs({})
    local p = fire()
    check("clean transition: Tykonos->Willow + bundled combo",
        p == "transition to the Willow form/combo dummy hiru hiraku flashheel left", p)
end

-- 7c) CLEAN TRANSITION INTO EXECUTE: Oak->Gaital (all 5 prepped) bundles combo 1 --
--     transition + hyperfocus drop + sweep, all on one balance.
do
    reset(); setForm("Oak", 6); setLimbs({ LL = 92, RL = 92, LA = 92, RA = 92, H = 88 })
    local p = fire()
    check("clean transition: Oak->Gaital + combo1 sweep (one balance)",
        p == "transition to the Gaital form/hyperfocus none/combo dummy sweep flashheel left", p)
end

-- 8) PARRY REDIRECT: Gaital building, target parries left leg -> flashheel RIGHT.
do
    reset(); setForm("Gaital", 0); setLimbs({}); targetparry = "left leg"
    local p = fire()
    check("parry: avoids parried left leg", contains(p, "flashheel right"), p)
    check("parry: does not flashheel the parried limb", not contains(p, "flashheel left"), p)
end

-- 9) SHIELD: shatter through it.
do
    reset(); setForm("Rain", 0); setLimbs({})
    setAffs({ "shield" })
    local p = fire()
    check("shield: combo shatter", p == "combo dummy shatter", p)
end

-- 10) HYPERFOCUS RAISE: not focused on head, non-Gaital form -> hyperfocus head first.
do
    reset(); setForm("Rain", 0); setLimbs({}); ak.limbs.hyperfocus = "none"
    local p = fire()
    check("hyperfocus: raises head when not focused", p == "hyperfocus head", p)
end

-- 10b) ALREADY ON HEAD: no raise, proceed straight to the build combo.
do
    reset(); setForm("Rain", 0); setLimbs({}); ak.limbs.hyperfocus = "head"
    local p = fire()
    check("hyperfocus: no raise when already on head", p ~= "hyperfocus head" and (p or ""):find("^combo dummy") ~= nil, p)
end

-- 11) NO TARGET: empty target -> no attack queued.
do
    reset(); setForm("Rain", 0); setLimbs({})
    target = ""
    local p = fire()
    target = "dummy"
    check("no target: nothing queued", p == nil, p)
end

-- 12) CURING PAUSED: stand down, queue nothing.
do
    reset(); setForm("Rain", 0); setLimbs({})
    Legacy.Settings.Curing.status = false
    local p, q = fire()
    check("paused: nothing queued", p == nil and q == nil, p or q)
end

-- 13) RELOAD SAFETY: stale CONFIG / limbDamage left by an earlier or older load
--     (e.g. the discarded port) must not survive — both are redefined fresh on load,
--     so the file is the source of truth.
do
    monk.shikudo.CONFIG = { aliasName = "OLD" }  -- stale: missing the keys this version needs
    monk.shikudo.limbDamage = { kuro = 999 }     -- stale: wrong / partial
    local ok, err = pcall(dofile, "shikudo.lua")
    check("reload: no crash with stale globals present", ok, err)
    check("reload: CONFIG redefined fresh", monk.shikudo.CONFIG.PREP_THRESHOLD == 92,
        monk.shikudo.CONFIG.PREP_THRESHOLD)
    check("reload: limbDamage redefined fresh", monk.shikudo.limbDamage.needle == 16.46,
        monk.shikudo.limbDamage.needle)
end

-- ============================================================
print(("="):rep(48))
if fails > 0 then
    print(fails .. " FAILED")
    os.exit(1)
else
    print("ALL TESTS PASSED")
end
