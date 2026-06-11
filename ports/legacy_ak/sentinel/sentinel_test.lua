--[[
  sentinel_test.lua — self-contained smoke test for Sentinel.lua

  No external dependencies: it stubs the Mudlet + Legacy/AK host globals, captures
  the command string the module queues (SETALIAS SENTATK <cmds>), dofile()s the
  module, and asserts the emitted command for each killpath state. This pins the
  stateless killpath behavior route-by-route.

  Run from this folder:  lua sentinel_test.lua
  (Local Lua is 5.4; the module is 5.1-style, so it loads/runs unchanged here.)
]]--

------------------------------------------
-- Capture + Mudlet/framework stubs
------------------------------------------
local last_setalias = nil   -- the "<cmds>" half of SETALIAS SENTATK
local last_notify = nil     -- last boxEcho.send(...) message
local sent = {}             -- every raw send() line this dispatch

function send(s)
  sent[#sent + 1] = s
  local cmds = s:match("^SETALIAS SENTATK (.+)$")
  if cmds then last_setalias = cmds end
end

function tempTimer(_, _) return 0 end        -- don't auto-fire; we call dispatch directly
function killTimer(_) return true end
function getEpoch() return 1000 end           -- constant clock
function getNetworkLatency() return 0.1 end
function cecho(_) end                          -- swallow debug/status output
boxEcho = {send = function(m) last_notify = m end}

-- Host-framework state globals (reset per scenario by fresh_state()).
target = "Bob"
targetparry = nil
affstrack = {score = {}, impale = false}
ak = {defs = {}}
lb = {Bob = {hits = {}}}
gmcp = {Char = {Vitals = {bal = "1", eq = "1"}, Status = {name = "Me"}}}
Legacy = {Curing = {Affs = {}}, Settings = {Curing = {status = true}}, Me = {morph = "Jaguar"}}

dofile("Sentinel.lua")

------------------------------------------
-- Test harness
------------------------------------------
local passes, failures = 0, 0

local function expect(name, cond, detail)
  if cond then
    passes = passes + 1
    print("  PASS  " .. name)
  else
    failures = failures + 1
    print("  FAIL  " .. name .. (detail and ("  -- " .. tostring(detail)) or ""))
  end
end

local function has_cmd(substr)
  return last_setalias ~= nil and last_setalias:find(substr, 1, true) ~= nil
end

local function expect_cmd(name, substr)
  expect(name, has_cmd(substr), "got: " .. tostring(last_setalias))
end

-- Reset all framework state and the module to a clean default target.
local function fresh_state()
  target = "Bob"
  targetparry = nil
  affstrack = {score = {}, impale = false}
  ak = {defs = {}}
  lb = {Bob = {hits = {}}}
  gmcp = {Char = {Vitals = {bal = "1", eq = "1"}, Status = {name = "Me"}}}
  Legacy = {Curing = {Affs = {}}, Settings = {Curing = {status = true}}, Me = {morph = "Jaguar"}}
  sentinel.reset() -- finisher -> skullbash, clear skullbash_at, etc. (notifies "reset")
  last_setalias = nil
  last_notify = nil
  sent = {}
end

local function set_limbs(ll, rl, head)
  lb[target].hits["left leg"] = ll or 0
  lb[target].hits["right leg"] = rl or 0
  lb[target].hits["head"] = head or 0
end

local function aff(name, conf)
  affstrack.score[name] = conf or 100
end

------------------------------------------
-- Scenarios
------------------------------------------

print("\n[1] no target -> graceful skip, nothing queued")
fresh_state()
target = ""
sentinel.dispatch()
expect("notifies 'no target set'", last_notify == "no target set", last_notify)
expect("queues nothing", last_setalias == nil)

print("\n[2] prep phase (limbs at 0) -> ATK_PRIO strike + venom + framing")
fresh_state()
sentinel.dispatch()
expect_cmd("preamble WIELD spear", "WIELD spear452934 shield435542")
expect_cmd("ORDER LOYALS KILL", "ORDER LOYALS KILL Bob")
expect_cmd("LACERATE left leg w/ CURARE (paralysis is #1)", "LACERATE left leg CURARE")
expect_cmd("postamble ASSESS", "ASSESS")
expect_cmd("postamble DISCERN", "DISCERN")
local saw_setalias, saw_queue = false, false
for _, s in ipairs(sent) do
  if s:find("^SETALIAS SENTATK ") then saw_setalias = true end
  if s == "QUEUE ADDCLEARFULL FREE SENTATK" then saw_queue = true end
end
expect("emits SETALIAS SENTATK", saw_setalias)
expect("emits QUEUE ADDCLEARFULL FREE SENTATK", saw_queue)

print("\n[3] skullbash kill window: prone + broken head (leg state irrelevant)")
fresh_state()
set_limbs(120, 120, 120)
aff("prone")
sentinel.dispatch()
expect_cmd("all three broken + prone -> SKULLBASH", "SKULLBASH Bob")
-- THE WINDOW IGNORES LEGS: legs fully healed mid-bash -> keep bashing, never re-break.
fresh_state()
set_limbs(0, 0, 120)
aff("prone")
sentinel.dispatch()
expect_cmd("legs healed, still prone + head broken -> STILL SKULLBASH", "SKULLBASH Bob")
expect("no leg re-break while the window is open", not has_cmd("TRIP") and not has_cmd("THROW"))
-- Window closed by standing: head broken but not prone -> break engine re-prones them.
fresh_state()
set_limbs(90, 0, 120)
sentinel.dispatch()
expect("stood up -> no SKULLBASH", not has_cmd("SKULLBASH"))
expect_cmd("stood up -> TRIP the prepped leg to re-prone", "TRIP LEFT")
-- Window closed by head heal: prone with legs broken but head healed -> re-break the head.
fresh_state()
set_limbs(120, 120, 0)
aff("prone")
sentinel.dispatch()
expect("head healed -> no SKULLBASH", not has_cmd("SKULLBASH"))
expect_cmd("head healed -> axe the head", "THROW handaxe453711 AT Bob head")

print("\n[4] wrench: prep BOTH legs, TRIP first + axe second, THEN IMPALE -> WRENCH")
-- Gate: only ONE leg prepped -> don't break yet, prep the other first.
fresh_state()
sentinel.state.finisher = "wrench"
set_limbs(90, 0, 0)
sentinel.dispatch()
expect_cmd("one leg prepped -> prep the other (right leg)", "right leg")
expect("gate: no break until both legs prepped", not has_cmd("TRIP"))
-- Both legs prepped -> TRIP the first (breaks it, prones them).
fresh_state()
sentinel.state.finisher = "wrench"
set_limbs(90, 90, 0)
sentinel.dispatch()
expect_cmd("both legs prepped -> TRIP first leg", "TRIP LEFT")
-- First broken + prone, second still prepped (mid-break) -> axe it, not impale.
fresh_state()
sentinel.state.finisher = "wrench"
set_limbs(120, 90, 0)
aff("prone")
sentinel.dispatch()
expect_cmd("second leg still prepped -> axe (THROW)", "THROW")
expect("mid-break (other still prepped) -> not impaling yet", not has_cmd("IMPALE Bob"))
-- Both broken now -> IMPALE.
fresh_state()
sentinel.state.finisher = "wrench"
set_limbs(120, 120, 0)
aff("prone")
sentinel.dispatch()
expect_cmd("both legs broken -> IMPALE", "IMPALE Bob")
-- STATELESS MILESTONE: one leg broken, the other HEALED past prep -> IMPALE, inferred
-- purely from state (broken leg beside an un-prepped one => both went down). No latch,
-- no prior dispatches -- just the constructed limb state.
fresh_state()
sentinel.state.finisher = "wrench"
set_limbs(120, 30, 0)
aff("prone")
sentinel.dispatch()
expect_cmd("one broken + other healed -> STILL IMPALE", "IMPALE Bob")
expect("inferred milestone, no re-break", not has_cmd("TRIP") and not has_cmd("THROW"))
-- Impaled -> WRENCH (universal branch).
fresh_state()
sentinel.state.finisher = "wrench"
affstrack.impale = true
sentinel.dispatch()
expect_cmd("impaled -> WRENCH", "WRENCH Bob")

print("\n[5] dismember chain walks purely from state")
-- Both legs broken, skullbash not yet landed -> SKULLBASH first (head is not part of the route).
fresh_state()
sentinel.state.finisher = "dismember"
set_limbs(120, 120, 0)
sentinel.dispatch()
expect_cmd("both legs broken (not bashed) -> SKULLBASH", "SKULLBASH Bob")
expect("no ENSNARE before the skullbash lands", not has_cmd("ENSNARE"))

-- Skullbash lands -> advance to ENRAGE BUTTERFLY + ENSNARE (transfix).
fresh_state()
sentinel.state.finisher = "dismember"
set_limbs(120, 120, 0)
sentinel.dispatch()     -- engage (sets last_target) -> SKULLBASH
sentinel.on_skullbash() -- "skullbash lands" signal fires mid-combat
sentinel.dispatch()
expect_cmd("skullbash landed -> ENRAGE BUTTERFLY", "ENRAGE BUTTERFLY")
expect_cmd("skullbash landed -> ENSNARE", "ENSNARE Bob")

fresh_state()
sentinel.state.finisher = "dismember"
aff("transfixed")
sentinel.dispatch()
expect_cmd("transfixed -> RATTLE", "RATTLE Bob")

fresh_state()
sentinel.state.finisher = "dismember"
aff("unconsciousness")
sentinel.dispatch()
expect_cmd("unconscious -> OUTR ROPE/TRUSS (slash-split)", "OUTR ROPE/TRUSS Bob")

fresh_state()
sentinel.state.finisher = "dismember"
aff("trussed")
sentinel.dispatch()
expect_cmd("trussed -> IMPALE", "IMPALE Bob")

fresh_state()
sentinel.state.finisher = "dismember"
affstrack.impale = true
Legacy.Me.morph = "Jaguar"
sentinel.dispatch()
expect_cmd("impaled (already Jaguar) -> DISMEMBER", "DISMEMBER Bob")
expect("no redundant MORPH when already Jaguar", not has_cmd("MORPH JAGUAR"))

fresh_state()
sentinel.state.finisher = "dismember"
affstrack.impale = true
Legacy.Me.morph = "Basilisk"
sentinel.dispatch()
expect_cmd("impaled (wrong form) -> MORPH JAGUAR", "MORPH JAGUAR")
expect_cmd("impaled (wrong form) -> DISMEMBER", "DISMEMBER Bob")

print("\n[6] petrify: PETRIFY (via Basilisk) then EXTIRPATE when petrified")
fresh_state()
for _, a in ipairs({"hallucinations", "dizziness", "recklessness", "confusion", "paranoia"}) do aff(a) end
sentinel.dispatch()
expect_cmd("PETRIFY when 5 mental affs up", "PETRIFY Bob")
expect_cmd("morph to Basilisk to set up petrify", "MORPH BASILISK")
fresh_state()
aff("petrified")
sentinel.dispatch()
expect_cmd("petrified -> EXTIRPATE", "EXTIRPATE Bob")
expect("petrified skips preamble WIELD (ORDER is first cmd)",
  last_setalias ~= nil and last_setalias:find("^ORDER LOYALS KILL Bob") ~= nil, last_setalias)

print("\n[7] shields: 2 -> RIVESTRIKE, 1 -> ENRAGE LEMMING")
fresh_state()
ak.defs.shield = true
ak.defs.rebounding = true
sentinel.dispatch()
expect_cmd("two shields -> RIVESTRIKE", "RIVESTRIKE")
fresh_state()
ak.defs.shield = true
sentinel.dispatch()
expect_cmd("one shield -> ENRAGE LEMMING", "ENRAGE LEMMING")

print("\n[8] guards: aeon + paused stand down")
fresh_state()
Legacy.Curing.Affs.aeon = true
sentinel.dispatch()
expect("aeon -> notify + no send", last_notify == "aeon - skipping" and last_setalias == nil, last_notify)
fresh_state()
Legacy.Settings.Curing.status = false
sentinel.dispatch()
expect("paused -> no send", last_setalias == nil and #sent == 0)

print("\n[9] statelessness invariants")
fresh_state()
sentinel.dispatch()          -- engage Bob (sets last_target = Bob)
sentinel.on_skullbash()
expect("on_skullbash stamps skullbash_at", sentinel.state.skullbash_at ~= nil)
target = "Carl"
lb["Carl"] = {hits = {}}
sentinel.dispatch()          -- Bob -> Carl change clears the skullbash-landed signal
expect("target change clears the skullbash-landed signal", sentinel.state.skullbash_at == nil)
fresh_state()
sentinel.state.finisher = "dismember"
set_limbs(120, 120, 120)
sentinel.dispatch()          -- both legs broken -> SKULLBASH step
aff("transfixed"); sentinel.dispatch()  -- transfixed -> RATTLE step
sentinel.dispatch()          -- still RATTLE
expect("engine never rewrites the finisher preference", sentinel.state.finisher == "dismember")

print("\n[10] arm_next_bal: preference coercion + arm-when-off-balance")
fresh_state()
sentinel.arm_next_bal(false)
expect("false -> skullbash", sentinel.state.finisher == "skullbash")
sentinel.arm_next_bal(true)
expect("true -> wrench", sentinel.state.finisher == "wrench")
sentinel.arm_next_bal("dismember")
expect("string -> dismember", sentinel.state.finisher == "dismember")
fresh_state()
gmcp.Char.Vitals.eq = "0" -- off balance
last_setalias = nil
sentinel.arm_next_bal(false)
expect("off-balance -> arms instead of firing", sentinel.state.next_bal_armed == true and last_setalias == nil)
expect("off-balance -> notify 'armed'", last_notify == "armed", last_notify)

print("\n[11] smoke: status() and on_balance() don't error")
fresh_state()
set_limbs(50, 95, 0)
local ok_status = pcall(sentinel.status)
expect("status() runs", ok_status)
local ok_bal = pcall(sentinel.on_balance, 2.5)
expect("on_balance() runs", ok_bal)

print("\n[12] venom priority: anorexia rides early (#3, uncoupled)")
-- paralysis + asthma up -> anorexia (SLIKE) is the next lacked venom aff, no coupling gate.
fresh_state()
for _, a in ipairs({"paralysis", "asthma"}) do aff(a) end
sentinel.dispatch()
expect_cmd("paralysis + asthma up -> anorexia (SLIKE) next", "SLIKE")
-- anorexia up too -> selection moves on to slickness (GECKO).
fresh_state()
for _, a in ipairs({"paralysis", "asthma", "anorexia"}) do aff(a) end
sentinel.dispatch()
expect_cmd("anorexia up -> slickness (GECKO) next", "GECKO")

print("\n[13] weariness truelock registers (recklessness not required) -> SKULLBASH")
fresh_state()
for _, a in ipairs({"asthma", "slickness", "paralysis", "impatience", "anorexia", "weariness"}) do aff(a) end
aff("prone")
sentinel.dispatch()
expect_cmd("prone + 6-aff weariness truelock -> opportunistic SKULLBASH", "SKULLBASH Bob")

print("\n[14] all finishers share VENOM_PRIO on breaks (no special combo)")
-- A skullbash break rides the normal priority -- paralysis #1 -- not a hardcoded combo venom.
fresh_state()
set_limbs(90, 90, 90) -- all prepped -> skullbash enters the break
sentinel.dispatch()
expect_cmd("skullbash break -> VENOM_PRIO #1 (paralysis/CURARE)", "CURARE")
-- The break's venom slot walks the same list: paralysis + asthma already up -> the
-- TRIP rides anorexia (SLIKE), same selection as a prep hit.
fresh_state()
set_limbs(90, 90, 90)
for _, a in ipairs({"paralysis", "asthma"}) do aff(a) end
sentinel.dispatch()
expect_cmd("skullbash break venom walks VENOM_PRIO too (SLIKE)", "SLIKE")

print("\n[15] no double-apply: weariness from GOUGE OR vernalius, never both in one hit")
-- haemophilia + impatience up -> ATK_PRIO picks weariness (GOUGE). asthma + clumsiness up too,
-- so the venom slot's next lacked aff WOULD be weariness (vernalius) -- but the atk's aff is
-- excluded from venom selection, so it skips to sensitivity. weariness lands once.
fresh_state()
for _, a in ipairs({"haemophilia", "impatience", "asthma", "clumsiness"}) do aff(a) end
sentinel.dispatch()
expect_cmd("atk lands weariness via GOUGE", "GOUGE")
expect("venom does NOT also land weariness (no VERNALIUS)", not has_cmd("VERNALIUS"))
expect_cmd("venom slot moves on past weariness (CURARE, paralysis #1)", "CURARE")

print("\n[16] no double-apply: sensitivity from RAVEN OR prefarar, never both in one hit")
-- healthleech + hallucinations up -> ENRAGE_PRIO picks sensitivity (RAVEN). asthma/clumsiness/
-- weariness up, so the venom slot's next lacked aff WOULD be sensitivity (prefarar) -- but the
-- enrage's aff is excluded from venom selection, so it skips to slickness.
fresh_state()
for _, a in ipairs({"healthleech", "hallucinations", "asthma", "clumsiness", "weariness"}) do aff(a) end
sentinel.dispatch()
expect_cmd("enrage lands sensitivity via RAVEN", "ENRAGE RAVEN")
expect("venom does NOT also land sensitivity (no PREFARAR)", not has_cmd("PREFARAR"))
expect_cmd("venom slot moves on past sensitivity (CURARE, paralysis #1)", "CURARE")

print("\n[17] lock (vv): TRIP off-herb-balance -> handaxe anorexia -> slickness, single break")
-- Step 1: base up + a prepped leg, standing -> TRIP it with the normal-priority venom
-- (paralysis #1, the off-herb-balance opener).
fresh_state()
sentinel.state.finisher = "lock"
for _, a in ipairs({"impatience", "asthma", "weariness"}) do aff(a) end
set_limbs(90, 0, 0)
sentinel.dispatch()
expect_cmd("step 1: TRIP the prepped leg", "TRIP LEFT")
expect_cmd("step 1: off-herb-balance opener (paralysis/CURARE)", "CURARE")
-- Step 2: prone, inside the tempslickness window, no anorexia -> handaxe + anorexia (no re-break).
fresh_state()
sentinel.state.finisher = "lock"
for _, a in ipairs({"impatience", "asthma", "weariness", "tempslickness"}) do aff(a) end
set_limbs(120, 0, 0)
aff("prone")
sentinel.dispatch()
expect("step 2: no second leg break", not has_cmd("TRIP"))
expect_cmd("step 2: handaxe lands anorexia (SLIKE)", "SLIKE")
-- Step 3: prone, anorexia up, no slickness -> handaxe + slickness (solidify the apply-block).
fresh_state()
sentinel.state.finisher = "lock"
for _, a in ipairs({"impatience", "asthma", "weariness", "tempslickness", "anorexia"}) do aff(a) end
set_limbs(120, 0, 0)
aff("prone")
sentinel.dispatch()
expect_cmd("step 3: handaxe solidifies slickness (GECKO)", "GECKO")
-- Prone + full truelock -> SKULLBASH (opportunistic kill, finisher-agnostic).
fresh_state()
sentinel.state.finisher = "lock"
for _, a in ipairs({"impatience", "asthma", "weariness", "anorexia", "slickness", "paralysis"}) do aff(a) end
aff("prone")
sentinel.dispatch()
expect_cmd("prone + truelock -> SKULLBASH", "SKULLBASH Bob")

print("\n[18] full atk list -> re-up the lowest-confidence aff; all at 100 -> LACERATE")
-- All ATK affs up but at different confidences -> reinforce the least certain (weariness 60).
fresh_state()
aff("haemophilia", 100)
aff("impatience", 80)
aff("weariness", 60)
aff("epilepsy", 90)
sentinel.dispatch()
expect_cmd("lowest-confidence atk aff re-upped (weariness 60 -> GOUGE)", "GOUGE")
-- All ATK affs maxed -> nothing to reinforce -> fall back to prio_list[1] = LACERATE (bleeding).
fresh_state()
aff("haemophilia", 100)
aff("impatience", 100)
aff("weariness", 100)
aff("epilepsy", 100)
sentinel.dispatch()
expect_cmd("all atk affs at 100 -> LACERATE for the bleeding", "LACERATE")

------------------------------------------
-- Summary
------------------------------------------
print(string.format("\n==== %d passed, %d failed ====", passes, failures))
if failures > 0 then os.exit(1) end
