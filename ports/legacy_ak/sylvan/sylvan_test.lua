-- Smoke harness for sylvan.lua: stubbed Mudlet/AK environment, no game required.
-- Run: lua ports/legacy_ak/sylvan/sylvan_test.lua  (works from any cwd)
local sent = {}
function send(s) sent[#sent + 1] = s end
function echo(_) end
local timer_id, timers = 0, {}
function tempTimer(t, fn)
    timer_id = timer_id + 1
    timers[timer_id] = { t = t, fn = fn }
    return timer_id
end
function killTimer(id) timers[id] = nil; return true end
function remainingTime(id) return timers[id] and timers[id].t or nil end
function getNetworkLatency() return 0.05 end

target = "victim"
gmcp = { Char = { Vitals = { bal = "1", eq = "1" } } }
ak = {}
affstrack = { score = {} }
lb = { victim = { hits = {} } }
targetparry = nil

local dir = (arg and arg[0] and arg[0]:match("^(.*[/\\])")) or ""
dofile(dir .. "sylvan.lua")

local failures = 0
local function check(name, cond, detail)
    if cond then
        print("PASS  " .. name)
    else
        failures = failures + 1
        print("FAIL  " .. name .. (detail and ("  :: " .. tostring(detail)) or ""))
    end
end

local function last_atk()
    for i = #sent, 1, -1 do
        local m = sent[i]:match("^SETALIAS SYLATK (.+)$")
        if m then return m end
    end
    return nil
end

local function fresh(mode)
    sent = {}
    sylvan.reset()
    sylvan.state.mode = mode
    ak = { ae = 0, currenthealth = "8000", disturbed = false, feedback = nil, defs = {} }
    affstrack = { score = {} }
    lb = { victim = { hits = {} } }
    targetparry = nil
end

-- Mid-lock environment: seal delivered, weather up, banked overcharge already spent.
local function midlock(mode)
    fresh(mode)
    lb.victim.hits = { ["left leg"] = 100, head = 100 }
    ak.disturbed = true
    ak.feedback = "victim"
    sylvan.state.oc_fired = 1
    affstrack.score = { anorexia = 100, slickness = 100 }
end

-- Step 1: prep, propagation-first, non-duplicate venom
fresh("ONELEGHEAD")
sylvan.dispatch()
local atk = last_atk()
check("step1 prep: herb venom + herb plant",
    atk and atk:find("THORNREND victim CURARE left leg BELLWORT", 1, true) and not atk:find("SWEEP", 1, true), atk)

fresh("ONELEGHEAD")
affstrack.score = { paralysis = 100, clumsiness = 100 }
sylvan.dispatch()
atk = last_atk()
check("step1 prep: venom excludes propagation aff",
    atk and atk:find("THORNREND victim PREFARAR left leg BELLWORT", 1, true), atk)

-- Steps 2-4: prepped at ae 28 must still BUILD (gate is 40): disturb, then synch
fresh("ONELEGHEAD")
lb.victim.hits = { ["left leg"] = 80, head = 80 }
ak.ae = 28
sylvan.dispatch()
atk = last_atk()
check("step2: disturb first, no execute below 40", atk and atk:find("CAST DISTURB", 1, true)
    and not atk:find("SYNCHRONISE", 1, true) and not atk:find("THORNREND", 1, true), atk)
ak.disturbed = true
sent = {}
sylvan.dispatch()
atk = last_atk()
check("step4 build: feedback + STATIC/HAILSTONE per WW_PRIO",
    atk and atk:find("CAST FEEDBACK AT victim", 1, true) and atk:find("SYNCHRONISE STATIC HAILSTONE victim", 1, true), atk)

-- Step 5: ae 40 -> break with LOBELIA + venom prio + SWEEP, latch set
fresh("ONELEGHEAD")
lb.victim.hits = { ["left leg"] = 80, head = 80 }
ak.ae = 40
sylvan.dispatch()
atk = last_atk()
check("step5 break: venom prio + LOBELIA + SWEEP",
    atk and atk:find("THORNREND victim CURARE left leg LOBELIA", 1, true)
    and atk:find("SWING QUARTERSTAFF victim", 1, true), atk)
check("step5: commit latch set", sylvan.state.commit_latch == true)

-- Step 6: leg broken, ae 40 -> banked overcharge once
lb.victim.hits = { ["left leg"] = 100, head = 80 }
ak.disturbed = true
ak.feedback = "victim"
sent = {}
sylvan.dispatch()
atk = last_atk()
check("step6: OVERCHARGE STATIC CYCLONE", atk and atk:find("OVERCHARGE STATIC CYCLONE", 1, true), atk)
check("step6: oc counter = 1", sylvan.state.oc_fired == 1)

-- Step 7: ae spent -> head seal (ONELEGHEAD)
ak.ae = 12
sent = {}
sylvan.dispatch()
atk = last_atk()
check("step7: head seal SLIKE/VALERIAN, no sweep",
    atk and atk:find("THORNREND victim SLIKE head VALERIAN", 1, true) and not atk:find("SWEEP", 1, true), atk)

-- Step 7 in ONELEG: head strike happens even though head is never prepped
fresh("ONELEG")
lb.victim.hits = { ["left leg"] = 100 }
ak.ae = 12
ak.disturbed = true
ak.feedback = "victim"
sylvan.state.oc_fired = 1
sylvan.dispatch()
atk = last_atk()
check("step7 ONELEG: unprepped head still gets the seal",
    atk and atk:find("THORNREND victim SLIKE head VALERIAN", 1, true), atk)

-- Step 8: seal delivered, ae < 28, impatience unconfirmed -> CYCLONE HAILSTONE synch
midlock("ONELEGHEAD")
ak.ae = 12
sylvan.dispatch()
atk = last_atk()
check("step8: SYNCHRONISE CYCLONE HAILSTONE", atk and atk:find("SYNCHRONISE CYCLONE HAILSTONE victim", 1, true), atk)

-- Step 8 alt: impatience confirmed -> STATIC + hinder
midlock("ONELEGHEAD")
ak.ae = 12
affstrack.score.impatience = 100
sylvan.dispatch()
atk = last_atk()
check("step8 alt: SYNCHRONISE STATIC + hinder", atk and atk:find("SYNCHRONISE STATIC HAILSTONE victim", 1, true), atk)

-- Step 9: ae >= 28, impatience/asthma gaps -> OVERCHARGE CYCLONE HAILSTONE
midlock("ONELEGHEAD")
ak.ae = 30
affstrack.score.impatience = 50
sylvan.dispatch()
atk = last_atk()
check("step9: OVERCHARGE CYCLONE HAILSTONE", atk and atk:find("OVERCHARGE CYCLONE HAILSTONE", 1, true), atk)

-- Step 9: seal slipping (delivered but unconfirmed) -> torso re-seal
midlock("ONELEGHEAD")
ak.ae = 30
affstrack.score = { anorexia = 100, slickness = 67, impatience = 100, asthma = 100 }
sylvan.dispatch()
atk = last_atk()
check("step9: torso re-seal SLIKE/VALERIAN", atk and atk:find("THORNREND victim SLIKE torso VALERIAN", 1, true), atk)

-- Step 10: lock holds, paralysis slipping -> CURARE torso
midlock("ONELEGHEAD")
ak.ae = 30
affstrack.score = { anorexia = 100, slickness = 100, impatience = 100, asthma = 100, paralysis = 40 }
sylvan.dispatch()
atk = last_atk()
check("step10: paralysis keepup CURARE torso", atk and atk:find("THORNREND victim CURARE torso BELLWORT", 1, true), atk)

-- Step 10: everything pinned -> generic class-block stacking on torso
affstrack.score.paralysis = 100
sent = {}
sylvan.dispatch()
atk = last_atk()
check("step10: generic torso stacking", atk and atk:find("THORNREND victim XENTIO torso BELLWORT", 1, true), atk)

-- Lock-first: restored leg mid-lock must NOT be struck
midlock("ONELEGHEAD")
lb.victim.hits = { ["left leg"] = 0, head = 0 }
ak.ae = 30
affstrack.score.impatience = 50
sylvan.dispatch()
atk = last_atk()
check("lock-first: restored leg ignored, lock continues",
    atk and not atk:find("left leg", 1, true) and atk:find("OVERCHARGE CYCLONE HAILSTONE", 1, true), atk)

-- Carried-over AP: no double overcharge, break uses recipe (not seal) in ONELEG
fresh("ONELEG")
lb.victim.hits = { ["left leg"] = 80 }
ak.ae = 80
ak.disturbed = true
ak.feedback = "victim"
sylvan.dispatch()
atk = last_atk()
check("oneleg break: recipe venom + LOBELIA (seal never rides legs)",
    atk and atk:find("THORNREND victim CURARE left leg LOBELIA", 1, true) and atk:find("SWING QUARTERSTAFF victim", 1, true), atk)
lb.victim.hits["left leg"] = 100
sent = {}
sylvan.dispatch()
check("oneleg: overcharge fires once", last_atk() and last_atk():find("OVERCHARGE STATIC CYCLONE", 1, true), last_atk())
ak.ae = 52
sent = {}
sylvan.dispatch()
atk = last_atk()
check("oneleg: no second overcharge, head seal next",
    atk and not atk:find("OVERCHARGE", 1, true) and atk:find("THORNREND victim SLIKE head VALERIAN", 1, true), atk)

-- Parry-aware prep (no-space targetparry variant)
fresh("ONELEGHEAD")
targetparry = "leftleg"
sylvan.dispatch()
atk = last_atk()
check("prep: parried leg skipped, head prepped instead",
    atk and atk:find("THORNREND victim CURARE head BELLWORT", 1, true), atk)

-- Shockwave interrupt
fresh("ONELEGHEAD")
ak.ae = 40
ak.currenthealth = "4500"
affstrack.score = { dizziness = 100, epilepsy = 100, healthleech = 100 }
sylvan.dispatch()
atk = last_atk()
check("interrupt: shockwave", atk and atk:find("CAST SHOCKWAVE AT victim", 1, true), atk)

-- Nil target health must not crash and must not shockwave
fresh("ONELEGHEAD")
ak.ae = 40
ak.currenthealth = nil
affstrack.score = { dizziness = 100, epilepsy = 100, healthleech = 100 }
local ok, err = pcall(sylvan.dispatch)
atk = last_atk()
check("nil health: no crash, no shockwave", ok and atk and not atk:find("SHOCKWAVE", 1, true), err or atk)

-- Seal keepalive: nothing broken, no latch, seal up -> still EXECUTE
fresh("ONELEGHEAD")
affstrack.score = { anorexia = 100, slickness = 100 }
local snap = sylvan.debug_snapshot()
check("seal keepalive: head mode stays committed", snap.phase == "EXECUTE", snap.phase)

-- Invalid mode rejected, no crash
fresh("ONELEGHEAD")
ok, err = pcall(sylvan.arm, "BOGUS")
check("invalid mode: rejected, mode unchanged", ok and sylvan.state.mode == "ONELEGHEAD", err or sylvan.state.mode)

print(failures == 0 and "ALL PASS" or (failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
