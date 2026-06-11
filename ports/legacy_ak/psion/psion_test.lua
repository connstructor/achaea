--[[
  psion_test.lua — self-contained smoke test for Psion.lua

  No external dependencies: it stubs the Mudlet + Legacy/AK host globals, captures
  the command string the module queues (SETALIAS PSIATK/PSIUTIL <cmds>) and the status
  box (cecho), dofile()s the module, and asserts the emitted output for each kill route,
  key ladder branch, and the status readout.

  Run from this folder:  lua psion_test.lua
  (Local Lua is 5.4; the module is 5.1-style, so it loads/runs unchanged here.)
]]--

------------------------------------------
-- Capture + Mudlet/framework stubs
------------------------------------------
local last_setalias = nil   -- the "<cmds>" half of SETALIAS PSIATK/PSIUTIL
local last_notify = nil     -- last boxEcho.send(...) message
local sent = {}             -- every raw send() line this dispatch
local cechoed = {}          -- every cecho() line (the status box)

function send(s)
  sent[#sent + 1] = s
  local cmds = s:match("^SETALIAS %u+ (.+)$") -- PSIATK (attacks) or PSIUTIL (reactive)
  if cmds then last_setalias = cmds end
end

local timers = {}                           -- id -> {wait, fn, alive}; for the firing tests
local timer_seq = 0
function tempTimer(wait, fn)                 -- track; don't auto-fire (we invoke fn manually)
  timer_seq = timer_seq + 1
  timers[timer_seq] = {wait = wait, fn = fn, alive = true}
  return timer_seq
end
function killTimer(id) if timers[id] then timers[id].alive = false end return true end
function getEpoch() return 1000 end          -- constant clock (deadline = 1000 + wait)
function getNetworkLatency() return 0.1 end
function cecho(s) cechoed[#cechoed + 1] = s end -- capture the status box
boxEcho = {send = function(m) last_notify = m end}

-- Host-framework state globals (reset per scenario by fresh_state()).
target = "Bob"
affstrack = {score = {}}
ak = {defs = {}}
lb = {Bob = {hits = {}}}
gmcp = {Char = {Vitals = {bal = "1", eq = "1"}}}
Legacy = {Curing = {Affs = {}}, Settings = {Curing = {status = true}}}

dofile("Psion.lua")

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

-- Reset framework + module to a clean default target (Bob). Scenarios then plant AK /
-- affstrack state (uw / aff / set_mana / set_head) before calling dispatch / status.
local function fresh_state()
  target = "Bob"
  affstrack = {score = {}}
  ak = {defs = {}}
  lb = {Bob = {hits = {}}}
  gmcp = {Char = {Vitals = {bal = "1", eq = "1"}}}
  Legacy = {Curing = {Affs = {}}, Settings = {Curing = {status = true}}}
  psion.reset()
  last_setalias = nil
  last_notify = nil
  sent = {}
  cechoed = {}
  timers = {}
  timer_seq = 0
end

local function aff(name, conf)              -- generic affliction via affstrack
  affstrack.score[name] = conf or 100
end
local function set_head(n)
  lb.Bob.hits["head"] = n or 0
end
local function set_mana(pct)                 -- AK target mana %
  ak.manapercent = pct
end
local function uw(mind, body, spirit)        -- unweave levels via affstrack (level*100)
  affstrack.score["unweavingmind"]   = (mind   or 0) * 100
  affstrack.score["unweavingbody"]   = (body   or 0) * 100
  affstrack.score["unweavingspirit"] = (spirit or 0) * 100
end

------------------------------------------
-- Scenarios
------------------------------------------

print("\n[1] no target -> graceful skip, nothing queued")
fresh_state()
target = ""
psion.dispatch()
expect("notifies 'No target set'", last_notify == "No target set", last_notify)
expect("queues nothing", last_setalias == nil)

print("\n[2] opener (no affs, head 0, full mana) -> unweave body + muddle + disruption + framing")
fresh_state()
psion.dispatch()
expect_cmd("preamble WIELD RIGHT SHIELD", "WIELD RIGHT SHIELD")
expect_cmd("transcend slot -> MUDDLE", "PSI TRANSCEND MUDDLE Bob")
expect_cmd("prepare -> DISRUPTION (paralysis)", "WEAVE PREPARE DISRUPTION")
expect_cmd("weave -> open the body unweave", "WEAVE UNWEAVE Bob BODY")
expect_cmd("lightbind appended when not bound", "ENACT LIGHTBIND Bob")
expect_cmd("postamble ASSESS", "ASSESS")
expect_cmd("postamble CONTEMPLATE", "CONTEMPLATE Bob")
local saw_setalias, saw_queue = false, false
for _, s in ipairs(sent) do
  if s:find("^SETALIAS PSIATK ") then saw_setalias = true end
  if s == "QUEUE ADDCLEARFULL FREE PSIATK" then saw_queue = true end
end
expect("emits SETALIAS PSIATK", saw_setalias)
expect("emits QUEUE ADDCLEARFULL FREE PSIATK", saw_queue)

print("\n[3] shielded -> strip the shield first (CLEAVE), even at full mana")
fresh_state()
ak.defs.shield = true
psion.dispatch()
expect_cmd("WEAVE CLEAVE target", "WEAVE CLEAVE Bob")
expect("no excise (mana full)", not has_cmd("PSI EXCISE"))

print("\n[4] mana <= EXCISE_MANA -> PSI EXCISE kill")
fresh_state()
set_mana(25)
psion.dispatch()
expect_cmd("PSI TRANSCEND EXCISE", "PSI TRANSCEND EXCISE Bob")
expect_cmd("PSI EXCISE target", "PSI EXCISE Bob")
expect("no weave prepare on the excise turn", not has_cmd("WEAVE PREPARE"))

print("\n[5] two unweaves at critical (affstrack levels 3/3) -> WEAVE DECONSTRUCT kill")
fresh_state()
uw(3, 3)
psion.dispatch()
expect_cmd("WEAVE DECONSTRUCT target", "WEAVE DECONSTRUCT Bob")

print("\n[6] flurry mode, mind critical, no spirit -> INVERT MIND SPIRIT")
fresh_state()
psion.state.mode = "flurry"
uw(3, 0, 0)
psion.dispatch()
expect_cmd("WEAVE INVERT ... MIND SPIRIT", "WEAVE INVERT Bob MIND SPIRIT")
expect("not flurrying yet (no spirit set up)", not has_cmd("WEAVE FLURRY"))

print("\n[7] flurry mode, spirit at critical level -> SHATTER + WEAVE FLURRY kill")
fresh_state()
psion.state.mode = "flurry"
uw(0, 0, 3) -- spirit unweave at level 3 (flurry-ready)
psion.dispatch()
expect_cmd("PSI TRANSCEND SHATTER", "PSI TRANSCEND SHATTER Bob")
expect_cmd("WEAVE FLURRY target", "WEAVE FLURRY Bob")

print("\n[8] head prepped (one hit from break), no impatience -> WEAVE OVERHAND")
fresh_state()
set_head(80) -- 80 + WEAVE_DAMAGE(25) >= 100, not broken
psion.dispatch()
expect_cmd("WEAVE OVERHAND target", "WEAVE OVERHAND Bob")

print("\n[9] >=3 blast affs, not ravaged -> transcend slot picks BLAST")
fresh_state()
aff("impatience"); aff("stupidity"); aff("dizziness")
psion.dispatch()
expect_cmd("PSI TRANSCEND BLAST", "PSI TRANSCEND BLAST Bob")

print("\n[10] muddled (from affstrack) -> transcend filler picks SHATTER not MUDDLE")
fresh_state()
aff("muddled")
psion.dispatch()
expect_cmd("muddled -> SHATTER", "PSI TRANSCEND SHATTER Bob")
expect("muddled blocks re-muddle", not has_cmd("PSI TRANSCEND MUDDLE"))

print("\n[11] curing paused -> stand down, nothing queued")
fresh_state()
Legacy.Settings.Curing.status = false
psion.dispatch()
expect("queues nothing while paused", last_setalias == nil)

print("\n[12] self aeon -> one action per long balance, nothing queued")
fresh_state()
Legacy.Curing.Affs.aeon = true
psion.dispatch()
expect("queues nothing under aeon", last_setalias == nil)

print("\n[13] lightbind already up (from affstrack) -> ENACT LIGHTBIND suppressed")
fresh_state()
aff("lightbind")
psion.dispatch()
expect("no ENACT LIGHTBIND when already bound", not has_cmd("ENACT LIGHTBIND"))

print("\n[14] arm() with eq+bal up -> fires immediately")
fresh_state()
psion.arm()
expect("armed-and-ready dispatches now", last_setalias ~= nil)

print("\n[15] arm() without balance -> arms, fires nothing")
fresh_state()
gmcp.Char.Vitals.bal = "0"
psion.arm()
expect("nothing queued while off balance", last_setalias == nil)
expect("armed flag set", psion.state.next_bal_armed == true)
expect("notifies ARMED", last_notify == "ARMED", last_notify)

print("\n[16] broken head (lb>=100) + impatience + no asthma (mind) -> double-prep DEATHBLOW")
-- Regression: head_double_prepped must stay true once the head is broken, matching
-- the source isHeadDoublePrepped(). impatience present so P3 (overhand) is skipped;
-- damagedhead-equivalent (lb>=100) so P4 is skipped; P5 must fire deathblow.
fresh_state()
set_head(120)
aff("impatience")
psion.dispatch()
expect_cmd("broken-head double-prep -> WEAVE DEATHBLOW", "WEAVE DEATHBLOW Bob")
expect("did NOT fall through to unweave body", not has_cmd("WEAVE UNWEAVE Bob BODY"))

print("\n[17] only ONE unweave at critical (5/0/0) is NOT a deconstruct -> normal ladder")
fresh_state()
uw(5, 0, 0)
psion.dispatch()
expect("one critical is not a kill", not has_cmd("WEAVE DECONSTRUCT"))
expect_cmd("falls to the unweave ladder instead", "WEAVE UNWEAVE Bob BODY")

print("\n[18] AK ak.manapercent feeds the excise gate (no contemplate trigger)")
fresh_state()
ak.manapercent = 25
psion.dispatch()
expect_cmd("ak.manapercent <= EXCISE_MANA -> PSI EXCISE", "PSI EXCISE Bob")

print("\n[19] flurry mode, body critical, no spirit -> INVERT BODY SPIRIT")
fresh_state()
psion.state.mode = "flurry"
uw(0, 3, 0)
psion.dispatch()
expect_cmd("WEAVE INVERT ... BODY SPIRIT", "WEAVE INVERT Bob BODY SPIRIT")
expect("not flurrying yet (no spirit set up)", not has_cmd("WEAVE FLURRY"))

print("\n[20] FLURRY_MIN_SPIRIT gate holds flurry until the spirit level is high enough")
fresh_state()
psion.state.mode = "flurry"
psion.CONFIG.FLURRY_MIN_SPIRIT = 4
uw(0, 0, 3) -- critical, but below the burst threshold
psion.dispatch()
expect("spirit 3 < FLURRY_MIN 4 -> no flurry yet", not has_cmd("WEAVE FLURRY"))
last_setalias = nil
uw(0, 0, 4)
psion.dispatch()
expect_cmd("spirit 4 >= FLURRY_MIN 4 -> flurry", "WEAVE FLURRY Bob")
psion.CONFIG.FLURRY_MIN_SPIRIT = 3 -- restore (CONFIG isn't reset by fresh_state)

print("\n[21] cc anti-escape -> WEAVE LAUNCH + ENACT LIGHTBIND on the PSIUTIL queue")
fresh_state()
psion.antiescape()
expect_cmd("launches the flier", "WEAVE LAUNCH Bob")
expect_cmd("re-pins with lightbind", "ENACT LIGHTBIND Bob")
local saw_util = false
for _, s in ipairs(sent) do if s == "QUEUE ADDCLEARFULL FREE PSIUTIL" then saw_util = true end end
expect("queues on PSIUTIL, not the attack queue", saw_util)

print("\n[22] vv self-cure -> PSI EXPUNGE")
fresh_state()
psion.expunge()
expect_cmd("psi expunge clears a mental", "PSI EXPUNGE")

print("\n[23] affstrack level-1 (score 100) unweave mind+body + asthma -> open spirit")
fresh_state()
-- unweave mind+body present at level 1 (score 100), plus asthma to block the smoke cure.
aff("unweavingmind"); aff("unweavingbody"); aff("asthma")
psion.dispatch()
expect_cmd("affstrack presence drives the spirit-open (P8)", "WEAVE UNWEAVE Bob SPIRIT")

print("\n[24] affstrack level encoding (score 300 = lvl 3) -> two criticals -> DECONSTRUCT")
fresh_state()
affstrack.score["unweavingmind"] = 300 -- level 3 = critical
affstrack.score["unweavingbody"] = 300 -- level 3 = critical
psion.dispatch()
expect_cmd("affstrack 300/300 -> deconstruct", "WEAVE DECONSTRUCT Bob")

print("\n[25] affstrack score 200 = lvl 2 (NOT critical) -> no deconstruct yet")
fresh_state()
affstrack.score["unweavingmind"] = 200
affstrack.score["unweavingbody"] = 200
psion.dispatch()
expect("two level-2 unweaves are not a kill", not has_cmd("WEAVE DECONSTRUCT"))

print("\n[26] status() renders a box (title / target / mana% / EXCISE / kill routes)")
fresh_state()
set_mana(18)
uw(3, 1, 0)
psion.status()
local box = table.concat(cechoed, "\n")
expect("box title shows PSION", box:find("PSION", 1, true) ~= nil)
expect("box shows the target name", box:find("Bob", 1, true) ~= nil)
expect("box shows mana 18%", box:find("18%", 1, true) ~= nil)
expect("box flags EXCISE at <=30% mana", box:find("EXCISE", 1, true) ~= nil)
expect("box lists the kill routes", box:find("DECONSTRUCT", 1, true) ~= nil)
expect("box drew a border", box:find("╭", 1, true) ~= nil)

print("\n[27] double bal/eq used -> keep the LONGER timer; callback fires without re-gating eqbal")
fresh_state()
gmcp.Char.Vitals.bal = "0" -- off balance, so arm() just arms (no immediate fire)
psion.arm()
expect("armed while off balance", psion.state.next_bal_armed == true)
-- bal used (2.8s) then eq used (3.1s): the longer (eq) timer must replace the shorter.
psion.on_balance(2.8)
local short_id = psion.state.next_bal_timer
psion.on_balance(3.1)
local long_id = psion.state.next_bal_timer
expect("longer eq timer replaced the shorter bal timer", long_id ~= short_id)
expect("shorter (bal) timer was killed", timers[short_id].alive == false)
expect("longer (eq) timer is live", timers[long_id].alive == true)
-- reverse order: a SHORTER incoming request is ignored, the pending longer timer kept.
fresh_state()
gmcp.Char.Vitals.bal = "0"
psion.arm()
psion.on_balance(3.1)
local keep_id = psion.state.next_bal_timer
psion.on_balance(2.8) -- shorter -> ignored, no new timer
expect("shorter request did not replace the longer timer", psion.state.next_bal_timer == keep_id)
expect("longer timer still live", timers[keep_id].alive == true)
-- firing the timer dispatches even though eq/bal are NOT both up (FREE queue holds it).
last_setalias = nil
timers[keep_id].fn()
expect("timer fired the dispatch with no eqbal re-gate", last_setalias ~= nil)
expect("disarmed after firing", psion.state.next_bal_armed == false)

------------------------------------------
-- Summary
------------------------------------------
print(string.format("\n%d passed, %d failed", passes, failures))
os.exit(failures > 0 and 1 or 0)
