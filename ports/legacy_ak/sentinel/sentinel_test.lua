--[[
  sentinel_test.lua — self-contained smoke test for Sentinel.lua

  No external dependencies: it stubs the Mudlet + Legacy/AK host globals, captures
  the command string the module queues (SETALIAS SENTATK <cmds>), dofile()s the
  module, and asserts the emitted command for each killpath state. This pins the
  stateless behavior of the two killpaths (skullbash, wrench) and the venom rules.

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
  sentinel.reset() -- finisher -> skullbash, clear timers, etc. (notifies "reset")
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

print("\n[2] prep phase (limbs at 0) -> ATK_PRIO strike + priority venom + framing")
fresh_state()
sentinel.dispatch()
expect_cmd("preamble WIELD spear", "WIELD spear452934 shield435542")
expect_cmd("ORDER LOYALS KILL", "ORDER LOYALS KILL Bob")
expect_cmd("LACERATE left leg w/ CURARE (paralysis is venom #1)", "LACERATE left leg CURARE")
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
-- STATELESS MILESTONE: one leg broken, the other HEALED past prep -> IMPALE, inferred purely
-- from state (broken leg beside an un-prepped one => both went down). No latch.
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

print("\n[5] venom rules: break hits seal the lock when lacking, else ride priority")
-- TRIP break with no anorexia -> SLIKE (seal the eat-block).
fresh_state()
set_limbs(90, 90, 90)
sentinel.dispatch()
expect_cmd("trip break, no anorexia -> SLIKE", "TRIP LEFT SLIKE")
-- TRIP break with anorexia already up -> ride priority (CURARE), not SLIKE.
fresh_state()
set_limbs(90, 90, 90)
aff("anorexia")
sentinel.dispatch()
expect_cmd("trip break, anorexia up -> priority CURARE", "TRIP LEFT CURARE")
expect("trip break, anorexia up -> not SLIKE", not has_cmd("SLIKE"))
-- Second-leg axe with no slickness -> GECKO (seal the apply-block).
fresh_state()
set_limbs(120, 90, 90) -- left broken, right prepped, prone -> axe the right leg
aff("prone")
sentinel.dispatch()
expect_cmd("second-leg axe -> THROW at the right leg", "THROW handaxe453711 AT Bob right leg")
expect_cmd("second-leg axe, no slickness -> GECKO", "ENVENOM handaxe453711 WITH GECKO")
-- Second-leg axe with slickness already up -> ride priority, not GECKO.
fresh_state()
set_limbs(120, 90, 90)
aff("prone")
aff("slickness")
sentinel.dispatch()
expect("second-leg axe, slickness up -> not GECKO", not has_cmd("WITH GECKO"))
expect_cmd("second-leg axe, slickness up -> priority CURARE", "WITH CURARE")
-- Head break never takes a seal -> priority venom.
fresh_state()
set_limbs(120, 120, 90) -- both legs broken, head prepped, prone -> axe the head
aff("prone")
sentinel.dispatch()
expect_cmd("head break -> axe the head", "THROW handaxe453711 AT Bob head")
expect_cmd("head break -> priority CURARE (never a seal)", "WITH CURARE")

print("\n[6] shields: 2 -> RIVESTRIKE, 1 -> ENRAGE LEMMING")
fresh_state()
ak.defs.shield = true
ak.defs.rebounding = true
sentinel.dispatch()
expect_cmd("two shields -> RIVESTRIKE", "RIVESTRIKE")
fresh_state()
ak.defs.shield = true
sentinel.dispatch()
expect_cmd("one shield -> ENRAGE LEMMING", "ENRAGE LEMMING")

print("\n[7] guards: aeon + paused stand down")
fresh_state()
Legacy.Curing.Affs.aeon = true
sentinel.dispatch()
expect("aeon -> notify + no send", last_notify == "aeon - skipping" and last_setalias == nil, last_notify)
fresh_state()
Legacy.Settings.Curing.status = false
sentinel.dispatch()
expect("paused -> no send", last_setalias == nil and #sent == 0)

print("\n[8] arm_next_bal: preference coercion + arm-when-off-balance")
fresh_state()
sentinel.arm_next_bal(false)
expect("false -> skullbash", sentinel.state.finisher == "skullbash")
sentinel.arm_next_bal(true)
expect("true -> wrench", sentinel.state.finisher == "wrench")
fresh_state()
gmcp.Char.Vitals.eq = "0" -- off balance
last_setalias = nil
sentinel.arm_next_bal(false)
expect("off-balance -> arms instead of firing", sentinel.state.next_bal_armed == true and last_setalias == nil)
expect("off-balance -> notify 'armed'", last_notify == "armed", last_notify)

print("\n[9] no double-apply: the ATK/ENRAGE aff is excluded from venom selection")
-- haemophilia + impatience up -> ATK_PRIO picks weariness (GOUGE). asthma + clumsiness up too,
-- so the venom slot's next lacked aff WOULD be weariness (vernalius) -- but the atk's aff is
-- excluded from venom selection, so it skips to the next priority (CURARE). weariness lands once.
fresh_state()
for _, a in ipairs({"haemophilia", "impatience", "asthma", "clumsiness"}) do aff(a) end
sentinel.dispatch()
expect_cmd("atk lands weariness via GOUGE", "GOUGE")
expect("venom does NOT also land weariness (no VERNALIUS)", not has_cmd("VERNALIUS"))
expect_cmd("venom slot moves on past weariness (CURARE, paralysis #1)", "CURARE")
-- healthleech + hallucinations up -> ENRAGE_PRIO picks sensitivity (RAVEN). The enrage's aff is
-- excluded from venom selection, so the venom skips sensitivity (prefarar).
fresh_state()
for _, a in ipairs({"healthleech", "hallucinations", "asthma", "clumsiness", "weariness"}) do aff(a) end
sentinel.dispatch()
expect_cmd("enrage lands sensitivity via RAVEN", "ENRAGE RAVEN")
expect("venom does NOT also land sensitivity (no PREFARAR)", not has_cmd("PREFARAR"))
expect_cmd("venom slot moves on past sensitivity (CURARE, paralysis #1)", "CURARE")

print("\n[10] select_aff reinforce -> re-up the lowest-confidence aff; all at 100 -> first")
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

print("\n[11] smoke: status / on_balance run; finisher preference persists")
fresh_state()
set_limbs(50, 95, 0)
expect("status() runs", (pcall(sentinel.status)))
expect("on_balance() runs", (pcall(sentinel.on_balance, 2.5)))
fresh_state()
sentinel.state.finisher = "wrench"
set_limbs(120, 120, 0)
aff("prone")
sentinel.dispatch()
sentinel.dispatch()
expect("engine never rewrites the finisher preference", sentinel.state.finisher == "wrench")

------------------------------------------
-- Summary
------------------------------------------
print(string.format("\n==== %d passed, %d failed ====", passes, failures))
if failures > 0 then os.exit(1) end
