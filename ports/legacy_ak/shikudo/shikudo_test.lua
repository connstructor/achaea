local sent = {}
local timer_log = {}

function send(cmd)
  table.insert(sent, cmd)
end

function cecho(_) end

function tempTimer(delay, cb)
  table.insert(timer_log, {delay = delay, cb = cb})
  return #timer_log
end

function killTimer(id)
  timer_log[id] = nil
end

function getNetworkLatency()
  return 0.1
end

function getEpoch()
  return 100
end

local function reset_sent()
  sent = {}
end

local function reset_timers()
  timer_log = {}
end

local function assert_eq(actual, expected, label)
  if actual ~= expected then
    error((label or "assertion failed") ..
      "\nexpected: " .. tostring(expected) ..
      "\nactual:   " .. tostring(actual), 2)
  end
end

local function last_alias()
  for i = #sent, 1, -1 do
    if sent[i]:match("^SETALIAS ATK ") then return sent[i] end
  end
  return nil
end

local function set_form(form, kata, kai)
  gmcp.Char.Vitals.charstats = {
    "Form: " .. form,
    "Kata: " .. tostring(kata or 0),
    "Kai: " .. tostring(kai or 0) .. "%"
  }
end

Legacy = {
  Settings = {
    Curing = { status = true },
    Basher = { status = false }
  },
  Curing = {
    Affs = {},
    Defs = { current = {} }
  }
}

gmcp = {
  Char = {
    Vitals = {
      hp = "10000",
      maxhp = "10000",
      mp = "10000",
      maxmp = "10000",
      bal = "1",
      eq = "1",
      charstats = {}
    }
  }
}

target = "Testtarget"
targetparry = "none"
ak = {
  currenthealth = 10000,
  maxhealth = 10000,
  defs = {},
  limbs = { hyperfocus = nil }
}
affstrack = { score = {} }
lb = {
  Testtarget = {
    hits = {
      ["left leg"] = 0,
      ["right leg"] = 0,
      ["left arm"] = 0,
      ["right arm"] = 0,
      head = 0,
      torso = 0
    }
  }
}

dofile("ports/legacy_ak/shikudo/shikudo.lua")

local function ready()
  reset_sent()
  reset_timers()
  affstrack.score = {}
  ak.currenthealth = 10000
  ak.maxhealth = 10000
  ak.defs = {}
  ak.limbs = { hyperfocus = nil }
  targetparry = "none"
  gmcp.Char.Vitals.bal = "1"
  gmcp.Char.Vitals.eq = "1"
  monk.telepathy.mindlocked = true
  monk.telepathy.starting_mindlock = false
  monk.shikudo.state.next_bal_armed = false
  monk.shikudo.state.next_bal_timer = nil
  monk.shikudo.state.next_bal_deadline = nil
  lb.Testtarget.hits["left leg"] = 0
  lb.Testtarget.hits["right leg"] = 0
  lb.Testtarget.hits["left arm"] = 0
  lb.Testtarget.hits["right arm"] = 0
  lb.Testtarget.hits.head = 0
  lb.Testtarget.hits.torso = 0
end

ready()
set_form("None", 0, 0)
monk.shikudo.godmode.run()
assert_eq(sent[1], "adopt rain form", "adopts Rain when form is missing")

ready()
set_form("Rain", 0, 0)
monk.shikudo.godmode.run()
assert_eq(last_alias(), "SETALIAS ATK combo Testtarget frontkick left ruku left kuro left", "does not hyperfocus without parry")

ready()
set_form("Rain", 0, 0)
targetparry = "left arm"
monk.shikudo.godmode.run()
assert_eq(last_alias(), "SETALIAS ATK hyperfocus left arm/combo Testtarget frontkick right ruku left kuro left", "focuses only the parried limb in the selected combo")

ready()
set_form("Rain", 0, 0)
ak.limbs.hyperfocus = "left arm"
monk.shikudo.godmode.run()
assert_eq(last_alias(), "SETALIAS ATK hyperfocus none/combo Testtarget frontkick left ruku left kuro left", "clears stale hyperfocus when no selected limb is parried")

ready()
set_form("Gaital", 0, 0)
lb.Testtarget.hits["left leg"] = 91
lb.Testtarget.hits["right leg"] = 91
lb.Testtarget.hits["left arm"] = 92
lb.Testtarget.hits["right arm"] = 92
lb.Testtarget.hits.head = 86
monk.shikudo.godmode.run()
assert_eq(last_alias(), "SETALIAS ATK combo Testtarget sweep flashheel left", "Gaital execute combo 1")

ready()
set_form("Oak", 5, 0)
lb.Testtarget.hits["left leg"] = 91
lb.Testtarget.hits["right leg"] = 91
lb.Testtarget.hits["left arm"] = 92
lb.Testtarget.hits["right arm"] = 92
lb.Testtarget.hits.head = 86
monk.shikudo.godmode.run()
assert_eq(last_alias(), "SETALIAS ATK transition to the Gaital form/combo Testtarget sweep flashheel left", "transitions and attacks on same balance")

ready()
set_form("Gaital", 2, 0)
affstrack.score.prone = 100
affstrack.score.damagedhead = 100
affstrack.score.crushedthroat = 100
monk.shikudo.godmode.run()
assert_eq(last_alias(), "SETALIAS ATK dispatch Testtarget", "dispatch kill")

ready()
set_form("Gaital", 0, 0)
monk.telepathy.mindlocked = false
affstrack.score.brokenleftarm = 100
affstrack.score.brokenrightarm = 100
affstrack.score.asthma = 100
affstrack.score.slickness = 100
affstrack.score.addiction = 100
monk.shikudo.godmode.run()
assert_eq(sent[1], "adopt Rain form", "low-kata lock fork adopts Rain")
assert_eq(monk.telepathy.starting_mindlock, false, "discarded prefix does not latch mindlock")

ready()
set_form("Rain", 0, 0)
skgodmode()
assert_eq(last_alias(), "SETALIAS ATK combo Testtarget frontkick left ruku left kuro left", "armed alias fires immediately when balance is up")
assert_eq(monk.shikudo.state.next_bal_armed, false, "immediate arm does not leave system armed")

ready()
set_form("Rain", 0, 0)
gmcp.Char.Vitals.bal = "0"
gmcp.Char.Vitals.eq = "0"
skgodmode()
assert_eq(last_alias(), nil, "off-balance arm waits for recovery")
assert_eq(monk.shikudo.state.next_bal_armed, true, "off-balance arm latches one hit")
monk.shikudo.on_balance(4.1)
assert(math.abs(timer_log[1].delay - 4.0) < 0.0001, "balance hook schedules with latency lead")
timer_log[1].cb()
assert_eq(last_alias(), "SETALIAS ATK combo Testtarget frontkick left ruku left kuro left", "armed timer fires GodMode")
assert_eq(monk.shikudo.state.next_bal_armed, false, "timer dispatch disarms")

local captured = {}
function cecho(msg)
  table.insert(captured, msg)
end

dofile("ports/legacy_ak/shikudo/calibrate.lua")
skCalibrate.results = {
  flashheel = 9.24,
  kuro = 0,
}
skCalibrate.show()

local cal_output = table.concat(captured)
assert(cal_output:find("monk.shikudo.limbDamage = {", 1, true), "calibrator emits the table used by shikudo.lua")
assert(cal_output:find("flashheel%s+= 9%.2,"), "calibrator prints numeric flashheel damage")
assert(cal_output:find("kuro%s+= 9%.2, %-%- unchanged; invalid calibration result was 0%.0"), "calibrator keeps a valid fallback for bad results")
assert(not cal_output:find("??", 1, true), "calibrator output must be pasteable Lua, not ?? placeholders")

local timers = {}
function tempTimer(delay, cb)
  table.insert(timers, {delay = delay, cb = cb})
  return #timers
end

function killTimer(id)
  timers[id] = nil
end

ready()
captured = {}
sent = {}
timers = {}
skCalibrate.run()
assert_eq(sent[1], "hyperfocus none", "calibrator clears hyperfocus before starting")
assert_eq(timers[1].delay, 2, "calibrator waits for hyperfocus clear")

timers[1].cb()
assert_eq(last_alias(), "SETALIAS ATK adopt Tykonos form", "calibrator switches form before attack")
assert_eq(sent[#sent], "QUEUE ADDCLEARFULL EQBAL ATK", "calibrator queues form switch on eqbal")
assert_eq(timers[2].delay, skCalibrate.formSwitchDelaySeconds, "calibrator waits for form switch balance")

timers[2].cb()
assert_eq(last_alias(), "SETALIAS ATK combo Testtarget thrust right arm", "calibrator attacks only after form delay")
lb.Testtarget.hits["right arm"] = 14.5
timers[3].cb()
assert_eq(skCalibrate.results.thrust, 14.5, "calibrator records attack delta after combo delay")

print("shikudo_test.lua: ok")
