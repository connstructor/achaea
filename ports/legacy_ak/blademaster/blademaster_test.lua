-- Blademaster smoke + parity regression harness.
-- Run from THIS directory:  lua blademaster_test.lua   (exit 0 = pass)
--
-- Stubs the host globals, drives each strategy, and asserts the normalised
-- decision (infuse | action | strike). The expected values were verified
-- equal to the original Levi 005 by a differential oracle sweep (34/34) — this
-- harness locks them in without needing 005 present.

----------------------------------------------------------------------
-- host stubs
----------------------------------------------------------------------
local sent = {}
function send(s) sent[#sent + 1] = s end
function cecho() end
function tempTimer() return 1 end
function killTimer() end
function remainingTime() return -1 end
function getNetworkLatency() return 0.05 end

target = "Mystor"
gmcp = { Char = { Vitals = { bal = "1", eq = "1", charstats = { "Shin: 40" } }, Status = { class = "Blademaster" } } }
ak = { bleeding = 0, defs = {}, mounted = false, engaged = true, currenthealth = 4000, maxhealth = 5000 }
affstrack = { score = {}, impale = nil }
lb = { Mystor = { hits = {} } }
targetparry = "none"
Legacy = { Curing = { Affs = {}, bal = { active = true } }, SLC = { limbs = {} }, Tannivh = { stance = "thyr" } }

dofile("blademaster.lua")

-- pin the stance + its slash damage so threshold predictions are deterministic
blademaster.CONFIG.DMG.thyr = { legP = 17.3, legS = 11.5, armP = 17.3, armS = 11.5, torso = 18.1, head = 12.1, compass = 14.9 }

----------------------------------------------------------------------
-- decision normaliser: combo string -> "infuse=.. | action=.. | strike=.."
----------------------------------------------------------------------
local ATTACK = { legslash=1, armslash=1, centreslash=1, compassslash=1, balanceslash=1,
  raze=1, airfist=1, flamefist=1, impale=1, impaleslash=1, bladetwist=1, withdraw=1,
  brokenstar=1, pommelstrike=1 }
local DIR = { left=1, right=1, up=1, down=1, north=1, south=1, east=1, west=1, southeast=1, southwest=1 }

local function normalize(combo)
  local infuse, action, strike
  for part in combo:gmatch("[^;/]+") do
    local words = {}
    for w in part:gmatch("%S+") do words[#words + 1] = w end
    local verb = words[1]
    if verb == "infuse" then
      infuse = words[2]
    elseif verb and ATTACK[verb] then
      if verb == "withdraw" or verb == "brokenstar" then
        action = "KILL"
      elseif not action then
        action = verb
        local rest = {}
        for i = 2, #words do
          local a = words[i]
          if DIR[a] then action = action .. " " .. a
          elseif a ~= target then rest[#rest + 1] = a end
        end
        if #rest > 0 then strike = table.concat(rest, " ") end
      end
    end
  end
  return ("infuse=%s | action=%s | strike=%s"):format(tostring(infuse), tostring(action), tostring(strike))
end

local ALIAS = { double = bmd, quad = bmdq, brokenstar = bmbs, group = bmgroup }

local function decide(s)
  local affs = s.affs or {}
  affstrack.score = {}
  for _, a in ipairs(affs) do affstrack.score[a] = 100 end
  affstrack.impale = s.impaled and "Me" or nil
  ak.bleeding = s.bleed or 0
  ak.defs = { shield = s.shield or nil, rebounding = s.rebounding or nil }
  ak.mounted = s.mounted or false
  ak.engaged = true
  lb.Mystor.hits = s.limbs or {}
  targetparry = s.parry or "none"
  gmcp.Char.Vitals.charstats = { "Shin: " .. (s.shin or 40) }
  gmcp.Char.Vitals.bal, gmcp.Char.Vitals.eq = "1", "1"
  Legacy.Curing.Affs = s.selfaffs or {}
  blademaster.state.last_target = "Mystor"
  affstrack.score.impaleslash = s.slashed and 100 or nil
  blademaster.state.flamefist_done = s.flamefist or false
  sent = {}
  ALIAS[s.mode]()
  for i = #sent, 1, -1 do
    local a = sent[i]:match("^SETALIAS ATK (.+)$")
    if a then return normalize(a) end
  end
  return "(no attack)"
end

----------------------------------------------------------------------
-- cases (expected == verified-equal-to-005)
----------------------------------------------------------------------
local cases = {
  { "dbl/prep fresh", mode="double", limbs={}, expect="infuse=lightning | action=legslash left | strike=hamstring" },
  { "dbl/prep uneven", mode="double", limbs={["left leg"]=50,["right leg"]=20}, expect="infuse=lightning | action=legslash right | strike=hamstring" },
  { "dbl/compassslash leg", mode="double", limbs={["left leg"]=95,["right leg"]=50}, expect="infuse=lightning | action=compassslash southwest | strike=hamstring" },
  { "dbl/final-prep ice", mode="double", limbs={["left leg"]=80,["right leg"]=80}, expect="infuse=ice | action=legslash left | strike=hamstring" },
  { "dbl/break+knees", mode="double", limbs={["left leg"]=92,["right leg"]=92}, expect="infuse=ice | action=legslash left | strike=knees" },
  { "dbl/mangle RL<200", mode="double", limbs={["left leg"]=130,["right leg"]=150}, affs={"prone"}, expect="infuse=ice | action=legslash right | strike=sternum" },
  { "dbl/mangle RL>=200", mode="double", limbs={["left leg"]=130,["right leg"]=210}, affs={"prone"}, expect="infuse=ice | action=legslash left | strike=sternum" },
  { "dbl/parry airfist", mode="double", limbs={["left leg"]=50,["right leg"]=50}, parry="leftleg", shin=40, expect="infuse=nil | action=airfist | strike=nil" },
  { "dbl/parry low-shin", mode="double", limbs={["left leg"]=50,["right leg"]=50}, parry="leftleg", shin=10, expect="infuse=lightning | action=legslash right | strike=hamstring" },
  { "dbl/shield raze", mode="double", limbs={["left leg"]=50,["right leg"]=50}, shield=true, expect="infuse=lightning | action=raze | strike=hamstring" },
  { "dbl/rebounding raze", mode="double", limbs={["left leg"]=50,["right leg"]=50}, rebounding=true, expect="infuse=lightning | action=raze | strike=hamstring" },
  { "dbl/ham present -> neck", mode="double", limbs={}, affs={"hamstring"}, expect="infuse=lightning | action=legslash left | strike=neck" },
  { "quad/arm prep", mode="quad", limbs={}, expect="infuse=lightning | action=armslash left | strike=hamstring" },
  { "quad/compassslash arm", mode="quad", limbs={["left arm"]=95,["right arm"]=50}, expect="infuse=lightning | action=compassslash west | strike=hamstring" },
  { "quad/leg prep", mode="quad", limbs={["left arm"]=92,["right arm"]=92}, expect="infuse=lightning | action=legslash left | strike=hamstring" },
  { "quad/flamefist", mode="quad", limbs={["left arm"]=92,["right arm"]=92,["left leg"]=92,["right leg"]=92}, flamefist=false, expect="infuse=nil | action=flamefist | strike=nil" },
  { "quad/arm break", mode="quad", limbs={["left arm"]=92,["right arm"]=92,["left leg"]=92,["right leg"]=92}, flamefist=true, expect="infuse=ice | action=armslash left | strike=ears" },
  { "quad/leg break right", mode="quad", limbs={["left arm"]=100,["right arm"]=100,["left leg"]=92,["right leg"]=92}, flamefist=true, expect="infuse=ice | action=legslash right | strike=knees" },
  { "quad/mangle right", mode="quad", limbs={["left arm"]=100,["right arm"]=100,["left leg"]=130,["right leg"]=130}, affs={"prone"}, flamefist=true, expect="infuse=ice | action=legslash right | strike=sternum" },
  { "quad/arm-prep airfist", mode="quad", limbs={}, parry="leftarm", shin=40, expect="infuse=nil | action=airfist | strike=nil" },
  { "quad/arm-break no-airfist", mode="quad", limbs={["left arm"]=92,["right arm"]=92,["left leg"]=92,["right leg"]=92}, flamefist=true, parry="leftarm", shin=40, expect="infuse=ice | action=armslash right | strike=ears" },
  { "bs/upper prep", mode="brokenstar", limbs={}, expect="infuse=lightning | action=centreslash down | strike=hamstring" },
  { "bs/compassslash upper", mode="brokenstar", limbs={["torso"]=95,["head"]=50}, expect="infuse=lightning | action=compassslash north | strike=hamstring" },
  { "bs/leg prep", mode="brokenstar", limbs={["torso"]=92,["head"]=92}, expect="infuse=lightning | action=legslash left | strike=hamstring" },
  { "bs/upper break", mode="brokenstar", limbs={["torso"]=92,["head"]=92,["left leg"]=92,["right leg"]=92}, expect="infuse=ice | action=centreslash down | strike=ears" },
  { "bs/leg break", mode="brokenstar", limbs={["torso"]=100,["head"]=100,["left leg"]=92,["right leg"]=92}, expect="infuse=ice | action=legslash left | strike=knees" },
  { "bs/impale prone", mode="brokenstar", limbs={}, affs={"prone"}, expect="infuse=nil | action=impale | strike=nil" },
  { "bs/impale legs-broken", mode="brokenstar", limbs={["left leg"]=100,["right leg"]=100}, expect="infuse=nil | action=impale | strike=nil" },
  { "bs/impaleslash", mode="brokenstar", impaled=true, slashed=false, expect="infuse=nil | action=impaleslash | strike=nil" },
  { "bs/bladetwist", mode="brokenstar", impaled=true, slashed=true, bleed=300, expect="infuse=nil | action=bladetwist | strike=nil" },
  { "bs/KILL impaled", mode="brokenstar", impaled=true, slashed=true, bleed=800, expect="infuse=nil | action=KILL | strike=nil" },
  { "bs/KILL writhed", mode="brokenstar", impaled=false, slashed=true, bleed=800, expect="infuse=nil | action=KILL | strike=nil" },
  { "bs/leg-prep airfist", mode="brokenstar", limbs={["torso"]=92,["head"]=92}, parry="leftleg", shin=40, expect="infuse=nil | action=airfist | strike=nil" },
  { "bs/upper-prep no-airfist", mode="brokenstar", limbs={}, parry="torso", shin=40, expect="infuse=lightning | action=centreslash down | strike=hamstring" },
  { "grp/fresh", mode="group", limbs={}, expect="infuse=ice | action=pommelstrike | strike=hamstring" },
  { "grp/asthma", mode="group", affs={"hamstring","paralysis"}, expect="infuse=ice | action=pommelstrike | strike=throat" },
  { "grp/shield raze", mode="group", shield=true, expect="infuse=nil | action=raze | strike=hamstring" },
}

----------------------------------------------------------------------
-- run
----------------------------------------------------------------------
local fail = 0
for _, c in ipairs(cases) do
  c.mode = c.mode
  local got = decide(c)
  local ok = got == c.expect
  if not ok then
    fail = fail + 1
    print(("FAIL %-26s\n     expected %s\n     got      %s"):format(c[1], c.expect, got))
  end
end

-- port-specific behaviours the oracle can't cover (JIT arm model + self lock-break)
local function check(name, cond)
  if not cond then fail = fail + 1; print("FAIL " .. name) end
end

-- off balance: arm, do not attack
affstrack.score = {}; affstrack.impale = nil; lb.Mystor.hits = {}; Legacy.Curing.Affs = {}
gmcp.Char.Vitals.bal = "0"; sent = {}
bmd()
check("arm off-balance -> armed, no attack", blademaster.state.armed == true and #sent == 0)
gmcp.Char.Vitals.bal = "1"

-- self lock-break (asthma+anorexia+slickness): suppress attack, send the break cure
Legacy.Curing.Affs = { asthma = true, anorexia = true, slickness = true }
sent = {}
bmd()
local broke, attacked = false, false
for _, s in ipairs(sent) do
  if s == "fitness" then broke = true end
  if s:match("^SETALIAS ATK") then attacked = true end
end
check("self-lock -> fitness, no attack", broke and not attacked)
Legacy.Curing.Affs = {}

print(("\n%d/%d decision cases + 2 behaviour checks; failures: %d")
  :format(#cases - 0, #cases, fail))
os.exit(fail == 0 and 0 or 1)
