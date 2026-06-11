-- Self-contained smoke test for sylvan.lua. Stubs the host globals (target, ak,
-- affstrack, lb, send) and captures the SYLATK alias each dispatch emits.
--   run: lua sys/sylvan/sylvan_test.lua   (from repo root)

-- ---- host stubs -------------------------------------------------------------
target = "Bob"
local last_atk = nil

function send(s)
  local atk = s:match("^SETALIAS SYLATK (.*)$")
  if atk then last_atk = atk end
end

-- Mudlet timer stubs (shared by the latch + firing tests; also keep latch_commit happy
-- in the execute phase-walk scenarios). fire(id) runs a scheduled timer's callback.
local timers, tseq = {}, 0
function tempTimer(wait, fn) tseq = tseq + 1; timers[tseq] = { wait = wait, fn = fn, alive = true }; return tseq end
function killTimer(id) if timers[id] then timers[id].alive = false end; return true end
function remainingTime(id) local t = timers[id]; return (t and t.alive) and t.wait or -1 end
function getNetworkLatency() return 0 end
local function fire(id) local t = timers[id]; if t and t.alive then t.alive = false; t.fn() end end

local function reset()
  last_atk = nil
  ak = { ae = 0, disturbed = false, feedback = nil, currenthealth = 50000,
         defs = { shield = false } }
  affstrack = { score = {} }
  lb = { [target] = { hits = {} } }
  if sylvan and sylvan.reset then sylvan.reset() end -- clears latch/armed/timers between scenarios
end

local function set_limb(limb, n) lb[target].hits[limb] = n end
local function set_aff(aff) affstrack.score[aff] = 100 end -- >= AFF_THRESHOLD

reset()
dofile("sys/sylvan/sylvan.lua")

-- ---- assert helpers ---------------------------------------------------------
local passed, failed = 0, 0
local function check(label, cond)
  if cond then passed = passed + 1; print("  ok   " .. label)
  else failed = failed + 1; print("  FAIL " .. label .. "  -> got: " .. tostring(last_atk)) end
end
local function has(s) return last_atk and last_atk:find(s, 1, true) ~= nil end

-- ============================================================================
print("[ONELEGHEAD] phase walk")
reset(); sylvan.state.mode = "ONELEGHEAD"

-- PREP: nothing prepped -> thornrend left leg (no swing yet)
sylvan.dispatch()
check("prep leg: THORNREND ... left leg", has("THORNREND Bob") and has("left leg"))
check("prep leg: no SWING", not has("SWING"))

-- PREP head: leg prepped (85), head fresh -> thornrend head
reset(); sylvan.state.mode = "ONELEGHEAD"; set_limb("left leg", 85)
sylvan.dispatch()
check("prep head: THORNREND ... head", has("THORNREND Bob") and has("head"))

-- BUILD: both prepped, no clouds -> DISTURB
reset(); sylvan.state.mode = "ONELEGHEAD"; set_limb("left leg", 85); set_limb("head", 85)
sylvan.dispatch()
check("build: CAST DISTURB", has("CAST DISTURB"))

-- BUILD: clouds up, conduit wrong -> FEEDBACK + SYNCHRONISE
reset(); sylvan.state.mode = "ONELEGHEAD"; set_limb("left leg", 85); set_limb("head", 85)
ak.disturbed = true; ak.feedback = "SomeoneElse"
sylvan.dispatch()
check("build: CAST FEEDBACK", has("CAST FEEDBACK AT Bob"))
check("build: SYNCHRONISE", has("SYNCHRONISE"))

-- EXECUTE entry: both prepped, AP at gate -> break leg + SWING
reset(); sylvan.state.mode = "ONELEGHEAD"; set_limb("left leg", 85); set_limb("head", 85)
ak.disturbed = true; ak.feedback = target; ak.ae = 28
sylvan.dispatch()
check("execute: break leg THORNREND ... left leg", has("THORNREND Bob") and has("left leg"))
check("execute: SWING rides leg break", has("SWING QUARTERSTAFF"))

-- OVERCHARGE: leg broken, head prepped, AP at gate -> OVERCHARGE STATIC CYCLONE
reset(); sylvan.state.mode = "ONELEGHEAD"; set_limb("left leg", 100); set_limb("head", 85)
ak.disturbed = true; ak.feedback = target; ak.ae = 28
sylvan.dispatch()
check("execute: OVERCHARGE STATIC CYCLONE", has("OVERCHARGE STATIC CYCLONE"))

-- HEAD SEAL: leg broken, overcharge spent (AP 0), head not broken -> seal head, no swing
reset(); sylvan.state.mode = "ONELEGHEAD"; set_limb("left leg", 100); set_limb("head", 85)
ak.disturbed = true; ak.feedback = target; ak.ae = 0
sylvan.dispatch()
check("execute: head seal THORNREND ... head", has("THORNREND Bob") and has("head"))
check("execute: seal = SLIKE + VALERIAN", has("SLIKE") and has("VALERIAN"))
check("execute: head break has no SWING", not has("SWING"))

-- ============================================================================
print("[TWOLEG] overcharge AP bands")
-- both legs broken, full gate -> first combo
reset(); sylvan.state.mode = "TWOLEG"; set_limb("left leg", 100); set_limb("right leg", 100)
ak.disturbed = true; ak.feedback = target; ak.ae = 56
sylvan.dispatch()
check("band 56: OVERCHARGE WATERSPOUT HAILSTONE", has("OVERCHARGE WATERSPOUT HAILSTONE"))

-- one combo spent -> second combo
reset(); sylvan.state.mode = "TWOLEG"; set_limb("left leg", 100); set_limb("right leg", 100)
ak.disturbed = true; ak.feedback = target; ak.ae = 28
sylvan.dispatch()
check("band 28: OVERCHARGE STATIC CYCLONE", has("OVERCHARGE STATIC CYCLONE"))

-- both spent -> lock completion (no head in TWOLEG), blank-limb thornrend
reset(); sylvan.state.mode = "TWOLEG"; set_limb("left leg", 100); set_limb("right leg", 100)
ak.disturbed = true; ak.feedback = target; ak.ae = 0
sylvan.dispatch()
check("band 0: lock THORNREND (no overcharge/head)", has("THORNREND Bob") and not has("OVERCHARGE") and not has("head"))

-- TWOLEG breaks second leg before overcharging
reset(); sylvan.state.mode = "TWOLEG"; set_limb("left leg", 100); set_limb("right leg", 85)
ak.disturbed = true; ak.feedback = target; ak.ae = 56
sylvan.dispatch()
check("execute: second leg breaks before OC", has("right leg") and not has("OVERCHARGE"))

-- ============================================================================
print("[ONELEG] heal robustness -- seal co-signs commitment")
-- leg was broken then healed back to 50, but seal aff is up -> still EXECUTE, not PREP
reset(); sylvan.state.mode = "ONELEG"; set_limb("left leg", 50)
ak.disturbed = true; ak.feedback = target; ak.ae = 0; set_aff("anorexia")
sylvan.dispatch()
check("healed leg + seal: re-break with seal, not prep-phase", has("THORNREND Bob") and has("left leg") and has("SLIKE"))

-- without the seal and with AP gone, a fully-healed lone leg DOES fall back to prep
reset(); sylvan.state.mode = "ONELEG"; set_limb("left leg", 50)
ak.disturbed = true; ak.feedback = target; ak.ae = 0
sylvan.dispatch()
check("healed leg, no seal, no AP: falls back to prep (expected)", has("left leg"))

-- ============================================================================
print("[guards]")
-- shield interrupts everything
reset(); ak.defs.shield = true
sylvan.dispatch()
check("shield: CAST SHEAR", has("CAST SHEAR AT Bob"))

-- shockwave when AP+affs+hp align
reset(); ak.ae = 40; ak.currenthealth = 4000
set_aff("dizziness"); set_aff("epilepsy"); set_aff("healthleech")
sylvan.dispatch()
check("shockwave: CAST SHOCKWAVE", has("CAST SHOCKWAVE AT Bob"))

-- ============================================================================
print("[firing] resource-used max-timer (the 'keep the later recovery' trick)")
-- (timer stubs are defined at the top, shared with the latch tests)

reset(); sylvan.state.armed = false; sylvan.state.fire_timer = nil

sylvan.on_recover(3.0)
local t1 = sylvan.state.fire_timer
check("recover 3.0 schedules a timer", t1 ~= nil and timers[t1].wait == 3.0)

sylvan.on_recover(2.5)
check("recover 2.5 (sooner) is ignored, keeps 3.0 timer", sylvan.state.fire_timer == t1 and timers[t1].alive)

sylvan.on_recover(4.0)
local t2 = sylvan.state.fire_timer
check("recover 4.0 (later) kills 3.0 timer and replaces it", t2 ~= t1 and not timers[t1].alive and timers[t2].wait == 4.0)

-- unarmed: the timer fires but must not dispatch
reset(); last_atk = nil; sylvan.state.armed = false; sylvan.state.fire_timer = nil
sylvan.on_recover(3.0)
local idu = sylvan.state.fire_timer
fire(idu)
check("unarmed: timer fires, no dispatch", last_atk == nil)

-- armed: the timer fires and dispatches (fresh ONELEGHEAD -> a prep THORNREND)
reset(); last_atk = nil; sylvan.state.mode = "ONELEGHEAD"; sylvan.state.armed = true; sylvan.state.fire_timer = nil
sylvan.on_recover(3.0)
local ida = sylvan.state.fire_timer
fire(ida)
check("armed: timer fires and dispatches", last_atk ~= nil and sylvan.state.armed == false)

-- arm() with eq+bal already up dispatches immediately
reset(); last_atk = nil; sylvan.state.fire_timer = nil
gmcp = { Char = { Vitals = { bal = "1", eq = "1" } } }
sylvan.arm("ONELEGHEAD")
check("arm with eqbal fires immediately", last_atk ~= nil and sylvan.state.armed == false)

-- arm() without eq+bal just arms (no immediate fire)
reset(); last_atk = nil; sylvan.state.fire_timer = nil
gmcp = { Char = { Vitals = { bal = "0", eq = "1" } } }
sylvan.arm("TWOLEG")
check("arm without eqbal just arms", last_atk == nil and sylvan.state.armed == true and sylvan.state.mode == "TWOLEG")

-- ============================================================================
print("[commit latch] leg break holds commitment through a mend (the snap-back fix)")
reset(); sylvan.state.mode = "ONELEGHEAD"
set_limb("left leg", 88); set_limb("head", 88)
ak.disturbed = true; ak.feedback = target; ak.ae = 28
sylvan.dispatch() -- EXECUTE: breaks the leg, which latches commitment
check("leg break sets commit_latch", sylvan.state.commit_latch == true)

-- the gap: target mends the leg (un-broken) after the overcharge spent AP, head not broken
set_limb("left leg", 50); ak.ae = 0
local slatch = sylvan.debug_snapshot()
check("mended leg mid-execute stays EXECUTE via latch", slatch.phase == "EXECUTE" and slatch.committed == true)
check("...and the latch (not a broken limb) is holding it", slatch.any_broken == false and slatch.commit_latch == true)

-- when the 6s timer fires, the latch self-clears and we correctly fall back
fire(sylvan.state.commit_timer)
local sexp = sylvan.debug_snapshot()
check("latch expiry -> drops out of EXECUTE", sexp.phase ~= "EXECUTE" and sexp.commit_latch == false)

-- ============================================================================
print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
