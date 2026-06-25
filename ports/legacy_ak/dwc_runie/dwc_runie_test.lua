-- Smoke harness for the DWC Runewarden engine. Stubs the Mudlet/AK host globals,
-- loads the module, drives the real arm()/compute_and_fire() path, and asserts the
-- emitted batch matches the Levi DWC decision tree across all four plans.
--
-- Run from inside ports/legacy_ak/dwc_runie/:  lua dwc_runie_test.lua
-- Exit code is non-zero on any failed assertion.

-- ----------------------------------------------------------------------------
-- Host-global stubs
-- ----------------------------------------------------------------------------
local sent = {}
local boxout = {}
function send(s) sent[#sent + 1] = s end
function echo(_) end
function cecho(_) end
local last_timer_fn = nil
function tempTimer(_, fn) last_timer_fn = fn; return 0 end
function killTimer(_) end
function getNetworkLatency() return 0.05 end

boxEcho = {send = function(s) boxout[#boxout + 1] = s end}

gmcp = {Char = {Vitals = {bal = "1", eq = "1"}}}

ak = {
  currenthealth = 1000,
  maxhealth = 1000,
  defs = {},
  engaged = true,
  bleeding = 0,
}
affstrack = {score = {}, impale = nil}
lb = {Enemy = {hits = {}}}
ignoreShield = nil
target = "Enemy"

dofile("dwc_runie.lua")
local M = runewarden.dwc

-- Deterministic config for assertions.
M.config.weapon1 = "scimitar"
M.config.weapon2 = "scimitar"
M.config.bisect_weapon = "bastard"
M.config.basic_bisect_weapon = "longsword"
M.config.dwc_slash_damage = 6.6 -- scimdamage = 13.2
M.config.aff_threshold = 50

-- ----------------------------------------------------------------------------
-- Harness helpers
-- ----------------------------------------------------------------------------
local failures = 0
local function check(name, cond, extra)
  if cond then
    print("  PASS  " .. name)
  else
    failures = failures + 1
    print("  FAIL  " .. name .. (extra and ("\n        " .. extra) or ""))
  end
end

-- Reset per-scenario world state, fire one batch, return its command list + raw alias.
local function fire(opts)
  opts = opts or {}
  ak.currenthealth = opts.hp_current
  ak.health = opts.health
  if opts.hp_current == nil and opts.health == nil then
    ak.currenthealth = 1000
  end
  ak.maxhealth = opts.hp_max or 1000
  ak.defs = {rebounding = opts.rebounding, shield = opts.shield}
  ak.engaged = (opts.engaged ~= false) -- default engaged = true
  ak.bleeding = opts.bleeding or 0
  affstrack.score = opts.aff or {}
  affstrack.impale = opts.impale or nil
  lb.Enemy.hits = opts.limbs or {}

  M.state.armed = false
  M.state.plan = opts.plan or "disembowel"
  if opts.need_falcon == nil then M.state.need_falcon = true else M.state.need_falcon = opts.need_falcon end
  M.state.salve_down = opts.salve_down or false
  M.config.discern_ridealong = (opts.discern ~= false) -- default on

  sent = {}
  M.arm() -- EQBAL is ready, so this fires synchronously

  for _, s in ipairs(sent) do
    local alias = s:match("^SETALIAS DWCATK (.+)$")
    if alias then
      local cmds = {}
      for c in (alias .. "/"):gmatch("([^/]*)/") do cmds[#cmds + 1] = c end
      return cmds, alias
    end
  end
  return nil, nil
end

local function index_of(cmds, pred)
  for i, c in ipairs(cmds) do
    if (type(pred) == "string" and c == pred) or (type(pred) == "function" and pred(c)) then
      return i, c
    end
  end
  return nil, nil
end

local function has(cmds, str) return index_of(cmds, str) ~= nil end
local function has_match(cmds, pat)
  return index_of(cmds, function(c) return c:match(pat) ~= nil end) ~= nil
end

-- ----------------------------------------------------------------------------
-- Scenarios
-- ----------------------------------------------------------------------------
print("disembowel (default): bare DSL stack on a clean target")
do
  local cmds, alias = fire({plan = "disembowel"})
  check("disembowel: WIELD scimitar scimitar", has(cmds, "WIELD scimitar scimitar"), alias)
  check("disembowel: DSL with venoms (v2 then v1)", has(cmds, "DSL Enemy VERNALIUS CURARE"), alias)
  check("disembowel: no EMPOWER (only head plan empowers)", not has_match(cmds, "^EMPOWER"), alias)
  check("disembowel: DISCERN ridealong present", has(cmds, "DISCERN Enemy"), alias)
  check("disembowel: trailing ASSESS", has(cmds, "ASSESS Enemy"), alias)
end

print("disembowel: impaled -> DISEMBOWEL, no re-wield")
do
  local cmds, alias = fire({plan = "disembowel", impale = "Me"})
  check("disembowel: DISEMBOWEL Enemy", has(cmds, "DISEMBOWEL Enemy"), alias)
  check("disembowel: DISEMBOWEL skips WIELD", not has(cmds, "WIELD scimitar scimitar"), alias)
end

print("disembowel: low HP -> dispatch BISECT (wield bastard;grip;...;engage)")
do
  local cmds, alias = fire({plan = "disembowel", hp_current = 100, hp_max = 1000})
  check("bisect: WIELD bastard", has(cmds, "WIELD bastard"), alias)
  check("bisect: GRIP", has(cmds, "GRIP"), alias)
  check("bisect: BISECT Enemy CURARE", has(cmds, "BISECT Enemy CURARE"), alias)
  check("bisect: ENGAGE Enemy", has(cmds, "ENGAGE Enemy"), alias)
  check("bisect: no DSL", not has_match(cmds, "^DSL"), alias)
end

print("disembowel: low HP while SHIELDED still bisects (BISECT ignores shield)")
do
  local cmds, alias = fire({plan = "disembowel", hp_current = 100, hp_max = 1000, shield = true})
  check("shield-bisect: BISECT present despite shield", has(cmds, "BISECT Enemy CURARE"), alias)
  check("shield-bisect: WIELD bastard", has(cmds, "WIELD bastard"), alias)
end

print("disembowel: HP via ak.health fallback (snb-style AK build) still bisects")
do
  local cmds, alias = fire({plan = "disembowel", health = 100, hp_max = 1000})
  check("bisect via ak.health: BISECT present", has(cmds, "BISECT Enemy CURARE"), alias)
end

print("disembowel: prone + broken left leg -> IMPALE + FURY ON")
do
  local cmds, alias = fire({plan = "disembowel", aff = {prone = 100}, limbs = {["left leg"] = 100}})
  check("impale: IMPALE Enemy", has(cmds, "IMPALE Enemy"), alias)
  check("impale: FURY ON", has(cmds, "FURY ON"), alias)
end

print("disembowel: rebounding -> RAZESLASH targetlimb")
do
  local cmds, alias = fire({plan = "disembowel", rebounding = true})
  check("raze: RAZESLASH Enemy TORSO CURARE", has(cmds, "RAZESLASH Enemy TORSO CURARE"), alias)
end

print("disembowel: not engaged -> FALCON SLAY + ENGAGE")
do
  local cmds, alias = fire({plan = "disembowel", engaged = false})
  check("falcon: FALCON SLAY Enemy", has(cmds, "FALCON SLAY Enemy"), alias)
  check("engage: ENGAGE Enemy", has(cmds, "ENGAGE Enemy"), alias)
  local fi = index_of(cmds, "FALCON SLAY Enemy")
  local wi = index_of(cmds, "WIELD scimitar scimitar")
  check("falcon precedes wield", fi and wi and fi < wi, "falcon@" .. tostring(fi) .. " wield@" .. tostring(wi))
end

print("disembowel: need_falcon=false + not engaged -> ENGAGE but no FALCON")
do
  local cmds, alias = fire({plan = "disembowel", engaged = false, need_falcon = false})
  check("no-falcon: FALCON SLAY absent", not has(cmds, "FALCON SLAY Enemy"), alias)
  check("no-falcon: ENGAGE still present", has(cmds, "ENGAGE Enemy"), alias)
end

print("head: EMPOWER + CONTEMPLATE wrap")
do
  local cmds, alias = fire({plan = "head"})
  check("head: EMPOWER PRIORITY SET KENA MANNAZ SLEIZAK",
    has(cmds, "EMPOWER PRIORITY SET KENA MANNAZ SLEIZAK"), alias)
  check("head: CONTEMPLATE Enemy", has(cmds, "CONTEMPLATE Enemy"), alias)
  local ei = index_of(cmds, "EMPOWER PRIORITY SET KENA MANNAZ SLEIZAK")
  check("head: EMPOWER is first command", ei == 1, "empower@" .. tostring(ei))
end

print("head: damaged right leg + prepped head -> head crack (DSL HEAD SLIKE ACONITE)")
do
  local cmds, alias = fire({plan = "head", limbs = {["right leg"] = 100, head = 90}})
  check("head-crack: DSL Enemy HEAD SLIKE ACONITE", has(cmds, "DSL Enemy HEAD SLIKE ACONITE"), alias)
end

print("basic: nausea + unprepped -> delegates to disembowel plan (identical output)")
do
  local opts = {plan = "disembowel", aff = {nausea = 100}}
  local dis_cmds = fire(opts)
  opts.plan = "basic"
  local bas_cmds = fire(opts)
  check("delegate: basic == disembowel under nausea",
    table.concat(dis_cmds, "/") == table.concat(bas_cmds, "/"),
    "dis=" .. table.concat(dis_cmds, "/") .. "\n        bas=" .. table.concat(bas_cmds, "/"))
end

print("basic: no nausea, engaged -> FALCON SLAY still emitted (002 always falcons)")
do
  local cmds, alias = fire({plan = "basic", engaged = true})
  check("basic: FALCON SLAY Enemy even when engaged", has(cmds, "FALCON SLAY Enemy"), alias)
  check("basic: DSL present", has_match(cmds, "^DSL Enemy"), alias)
  check("basic: no EMPOWER", not has_match(cmds, "^EMPOWER"), alias)
end

print("basic: low HP + not shielded -> SnB bisect (wield shield longsword)")
do
  local cmds, alias = fire({plan = "basic", hp_current = 100, hp_max = 1000})
  check("basic-bisect: WIELD SHIELD longsword", has(cmds, "WIELD SHIELD longsword"), alias)
  check("basic-bisect: BISECT Enemy CURARE", has(cmds, "BISECT Enemy CURARE"), alias)
end

print("rift: bare stack -> DSL targetlimb v1 v2, no falcon, no trailing assess")
do
  local cmds, alias = fire({plan = "rift"})
  check("rift: DSL Enemy TORSO CURARE VARDRAX", has(cmds, "DSL Enemy TORSO CURARE VARDRAX"), alias)
  check("rift: no FALCON SLAY", not has(cmds, "FALCON SLAY Enemy"), alias)
  -- 001 wrap adds no trailing ASSESS; the ww prefix's ASSESS is the only one.
  local assess_count = 0
  for _, c in ipairs(cmds) do if c == "ASSESS Enemy" then assess_count = assess_count + 1 end end
  check("rift: exactly one ASSESS (from ww prefix only)", assess_count == 1, "got " .. assess_count)
end

print("rift: salve_down + addiction -> riftlock EPTETH EPTETH")
do
  local cmds, alias = fire({plan = "rift", salve_down = true, aff = {addiction = 100}})
  check("rift-lock: DSL Enemy TORSO EPTETH EPTETH", has(cmds, "DSL Enemy TORSO EPTETH EPTETH"), alias)
end

print("dispatch: SETALIAS + QUEUE pair always emitted")
do
  fire({plan = "disembowel"})
  local setalias, queue = false, false
  for _, s in ipairs(sent) do
    if s:match("^SETALIAS DWCATK ") then setalias = true end
    if s == "QUEUE ADDCLEARFULL FREE DWCATK" then queue = true end
  end
  check("dispatch: SETALIAS DWCATK", setalias)
  check("dispatch: QUEUE ADDCLEARFULL FREE DWCATK", queue)
end

print("config: discern_ridealong=false suppresses DISCERN")
do
  local cmds, alias = fire({plan = "disembowel", discern = false})
  check("no-discern: DISCERN absent", not has(cmds, "DISCERN Enemy"), alias)
end

print("JIT path: arm off-balance -> on_balance_used schedules -> timer fires + disarms")
do
  -- Quiet baseline; arm while NOT on EQBAL so arm() defers instead of firing.
  ak.currenthealth = 1000; ak.maxhealth = 1000; ak.defs = {}; ak.engaged = true
  affstrack.score = {}; affstrack.impale = nil; lb.Enemy.hits = {}
  M.state.plan = "disembowel"; M.state.armed = false; M.state.need_falcon = true
  M.config.discern_ridealong = true
  gmcp.Char.Vitals.bal = "0" -- off balance => arm() defers
  last_timer_fn = nil
  sent = {}
  M.arm()
  check("jit: no immediate fire when off-balance", #sent == 0, "sent=" .. #sent)
  check("jit: armed after arm()", M.state.armed == true)
  M.on_balance_used(2.0) -- schedules a tempTimer; harness captures its callback
  check("jit: timer scheduled", last_timer_fn ~= nil)
  gmcp.Char.Vitals.bal = "1" -- balance returns; the scheduled callback now fires
  if last_timer_fn then last_timer_fn() end
  local fired = false
  for _, s in ipairs(sent) do if s:match("^SETALIAS DWCATK ") then fired = true end end
  check("jit: batch fired on timer expiry", fired)
  check("jit: disarmed after fire (one shot per arm)", M.state.armed == false)
end

print("reset: FURY OFF + disarm")
do
  M.state.armed = true
  sent = {}
  M.reset()
  check("reset: FURY OFF emitted", index_of(sent, "FURY OFF") ~= nil)
  check("reset: disarmed", M.state.armed == false)
end

-- ----------------------------------------------------------------------------
print(string.rep("-", 60))
if failures == 0 then
  print("ALL ASSERTIONS PASSED")
  os.exit(0)
else
  print(failures .. " ASSERTION(S) FAILED")
  os.exit(1)
end
