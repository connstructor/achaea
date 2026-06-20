-- Smoke harness for the 2H Runewarden engine. Stubs the Mudlet/AK host globals,
-- loads the module, drives the real arm()/compute_and_fire() path, and asserts the
-- emitted batch wields the correct weapon and empowers the matching rune set.
--
-- Run from inside ports/legacy_ak/2h_runie/:  lua 2h_runie_test.lua
-- Exit code is non-zero on any failed assertion.

-- ----------------------------------------------------------------------------
-- Host-global stubs
-- ----------------------------------------------------------------------------
local sent = {}
local boxout = {}
function send(s) sent[#sent + 1] = s end
function echo(_) end
function cecho(_) end
function tempTimer(_, _) return 0 end
function killTimer(_) end
function getNetworkLatency() return 0.05 end

boxEcho = {send = function(s) boxout[#boxout + 1] = s end}

gmcp = {Char = {Vitals = {bal = "1", eq = "1"}}}

ak = {
  twoh = {skull = 0, ribs = 0, wrist = 0, tendons = 0},
  currenthealth = 1000,
  maxhealth = 1000,
  defs = {},
  engaged = true,
  overwhelmed = false,
}
affstrack = {score = {}, impale = nil}
targetparry = nil
ignoreShield = nil
target = "Enemy"

dofile("2h_runie.lua")
local M = runewarden.twoh

-- Distinct test rune sets so sword vs warhammer empower is unambiguous.
M.config.rune_priority = {
  sword = {"INGUZ", "SLEIZAK", "WUNJO"},
  warhammer = {"ISAZ", "NAUTHIZ"},
}
M.config.bisect_weapon = "bisectblade999"
local SWORD_ID = M.config.bastard_sword
local HAMMER_ID = M.config.warhammer
local BISECT_ID = M.config.bisect_weapon

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

-- Reset per-scenario world state, fire one batch, and return its command list.
local function fire(opts)
  -- Reset framework state to a quiet baseline, then apply overrides.
  ak.twoh = {skull = 0, ribs = 0, wrist = 0, tendons = 0}
  ak.currenthealth = opts.hp_current or 1000
  ak.maxhealth = opts.hp_max or 1000
  ak.defs = {}
  ak.engaged = true
  ak.overwhelmed = opts.overwhelmed or false
  affstrack.score = opts.aff or {}
  affstrack.impale = opts.impale or nil
  targetparry = nil
  for k, v in pairs(opts.twoh or {}) do ak.twoh[k] = v end

  -- Operating-mode state.
  M.state.weapon_mode = opts.weapon_mode or "sword"
  M.state.override_loc = nil
  M.state.override_side = nil
  M.state.devastate_pending = nil

  sent = {}
  M.arm() -- EQBAL is ready, so this fires synchronously

  for _, s in ipairs(sent) do
    local alias = s:match("^SETALIAS TWOHATK (.+)$")
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
    if pred(c) then return i, c end
  end
  return nil, nil
end

-- Assert: the batch wields `weaponId`, then IMMEDIATELY empowers `runesStr`,
-- there is exactly one EMPOWER line, and (if given) the attack follows empower.
local function assert_wield_empower(label, cmds, alias, weaponId, runesStr, attackPred)
  local empCount = 0
  for _, c in ipairs(cmds) do
    if c:match("^EMPOWER PRIORITY SET") then empCount = empCount + 1 end
  end
  check(label .. ": exactly one EMPOWER", empCount == 1, "got " .. empCount .. " | " .. tostring(alias))

  local wi = index_of(cmds, function(c) return c == "WIELD " .. weaponId end)
  check(label .. ": WIELD " .. weaponId, wi ~= nil, alias)

  local ei = index_of(cmds, function(c) return c == "EMPOWER PRIORITY SET " .. runesStr end)
  check(label .. ": EMPOWER = '" .. runesStr .. "'", ei ~= nil, alias)

  if wi and ei then
    check(label .. ": EMPOWER immediately follows WIELD", ei == wi + 1,
      "wield@" .. wi .. " empower@" .. ei .. " | " .. alias)
  end

  if attackPred and ei then
    local ai = index_of(cmds, attackPred)
    check(label .. ": attack follows EMPOWER", ai ~= nil and ai > ei, alias)
  end
end

-- ----------------------------------------------------------------------------
-- Scenarios
-- ----------------------------------------------------------------------------
print("STACK / sword mode -> sword weapon + sword runes")
do
  local cmds, alias = fire({weapon_mode = "sword"})
  assert_wield_empower("stack-sword", cmds, alias, SWORD_ID, "INGUZ SLEIZAK WUNJO")
end

print("STACK / warhammer mode -> warhammer weapon + warhammer runes")
do
  local cmds, alias = fire({weapon_mode = "warhammer"})
  assert_wield_empower("stack-hammer", cmds, alias, HAMMER_ID, "ISAZ NAUTHIZ")
end

print("BRAIN follow-up (overwhelmed) -> warhammer pinned, even in sword mode")
do
  local cmds, alias = fire({weapon_mode = "sword", overwhelmed = true})
  assert_wield_empower("brain", cmds, alias, HAMMER_ID, "ISAZ NAUTHIZ",
    function(c) return c == "BRAIN Enemy" end)
end

print("BISECT (<=25% HP) -> dedicated bisect weapon, no empower (swap-in execute)")
do
  local cmds, alias = fire({weapon_mode = "warhammer", hp_current = 100, hp_max = 1000})
  check("bisect: WIELD dedicated bisect weapon",
    index_of(cmds, function(c) return c == "WIELD " .. BISECT_ID end) ~= nil, alias)
  check("bisect: no EMPOWER line emitted",
    index_of(cmds, function(c) return c:match("^EMPOWER PRIORITY SET") ~= nil end) == nil, alias)
  check("bisect: BISECT attack present",
    index_of(cmds, function(c) return c:match("^BISECT Enemy") ~= nil end) ~= nil, alias)
end

print("IMPALE (prone>=80) -> sword pinned, even in warhammer mode")
do
  local cmds, alias = fire({weapon_mode = "warhammer", aff = {prone = 90}})
  assert_wield_empower("impale", cmds, alias, SWORD_ID, "INGUZ SLEIZAK WUNJO",
    function(c) return c == "IMPALE Enemy" end)
end

print("No weapon-agnostic EMPOWER leaks into the prefix (before WIELD)")
do
  local cmds = fire({weapon_mode = "sword"})
  local wi = index_of(cmds, function(c) return c:match("^WIELD ") ~= nil end)
  local ei = index_of(cmds, function(c) return c:match("^EMPOWER PRIORITY SET") ~= nil end)
  check("empower-after-wield", wi and ei and ei > wi, "wield@" .. tostring(wi) .. " empower@" .. tostring(ei))
end

print("Unset warhammer runes -> EMPOWER skipped + one-time warning; WIELD/attack intact")
do
  M.config.rune_priority = {sword = {"INGUZ", "SLEIZAK", "WUNJO"}, warhammer = {"TODO_RUNE_1", "TODO_RUNE_2"}}
  boxout = {}
  local cmds, alias = fire({weapon_mode = "sword", overwhelmed = true}) -- BRAIN -> warhammer
  local empI = index_of(cmds, function(c) return c:match("^EMPOWER PRIORITY SET") ~= nil end)
  check("guard: EMPOWER skipped when runes unset", empI == nil, tostring(alias))
  check("guard: WIELD warhammer still emitted",
    index_of(cmds, function(c) return c == "WIELD " .. HAMMER_ID end) ~= nil, alias)
  check("guard: BRAIN attack still emitted",
    index_of(cmds, function(c) return c == "BRAIN Enemy" end) ~= nil, alias)
  local warned = 0
  for _, b in ipairs(boxout) do if b:match("warhammer") then warned = warned + 1 end end
  check("guard: warned exactly once", warned == 1, "warned=" .. warned)
  -- A second warhammer fire must NOT repeat the warning (once per kind per load).
  boxout = {}
  fire({weapon_mode = "sword", overwhelmed = true})
  local warned2 = 0
  for _, b in ipairs(boxout) do if b:match("warhammer") then warned2 = warned2 + 1 end end
  check("guard: no duplicate warning on second fire", warned2 == 0, "warned2=" .. warned2)
  M.config.rune_priority = {sword = {"INGUZ", "SLEIZAK", "WUNJO"}, warhammer = {"ISAZ", "NAUTHIZ"}}
end

print("Back-compat: an old flat-array rune_priority applies to both weapons")
do
  M.config.rune_priority = {"AAA", "BBB"}
  local c1 = fire({weapon_mode = "sword"})
  local _, e1 = index_of(c1, function(c) return c:match("^EMPOWER PRIORITY SET") ~= nil end)
  check("flat-config sword", e1 == "EMPOWER PRIORITY SET AAA BBB", tostring(e1))
  local c2 = fire({weapon_mode = "sword", overwhelmed = true}) -- BRAIN -> warhammer
  local _, e2 = index_of(c2, function(c) return c:match("^EMPOWER PRIORITY SET") ~= nil end)
  check("flat-config warhammer (BRAIN)", e2 == "EMPOWER PRIORITY SET AAA BBB", tostring(e2))
  -- restore
  M.config.rune_priority = {sword = {"INGUZ", "SLEIZAK", "WUNJO"}, warhammer = {"ISAZ", "NAUTHIZ"}}
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
