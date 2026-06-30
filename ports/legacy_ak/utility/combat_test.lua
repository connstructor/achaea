-- Smoke test for the combat framework core. Stubs the one host global it needs
-- (cecho) and asserts the registry/dispatch state machine. Run from this folder:
--   lua combat_test.lua
-- Exit code is non-zero on any failed assertion.

-- ---- host stubs ----
_G.cecho = function() end

-- Load the core under test.
dofile("combat.lua")

local failures = 0
local function check(name, cond)
	if cond then
		print("  ok   " .. name)
	else
		failures = failures + 1
		print("  FAIL " .. name)
	end
end

-- Fresh registry per run (the module guards with `or {}`, so reset explicitly).
combat._modules = {}
combat._activeId = nil

-- A combat module implements the standard API directly. Functions are plain
-- (no `self`): the dispatched arg is the FIRST parameter.
local calls = {}
local function rec(tag)
	return function(arg)
		calls[#calls + 1] = { tag = tag, arg = arg }
	end
end

local alpha = {
	id = "test.alpha",
	jitBalance = true,
	arm = rec("arm"),
	onTarget = rec("onTarget"),
	onClearTarget = rec("onClearTarget"),
	onBalanceUsed = rec("onBalanceUsed"),
	reset = rec("reset"),
	activate = rec("activate"),
	deactivate = rec("deactivate"),
	-- intentionally NO status(): a module need not implement every method.
}

local ret = combat.register(alpha)
check("register returns the module table itself", ret == alpha)
check("get resolves by id", combat.get("test.alpha") == alpha)
check("register rejects a non-table", not pcall(function() combat.register("x") end))
check("register rejects missing id", not pcall(function() combat.register({}) end))
check("jitBalance is read as-is (no default injection)", alpha.jitBalance == true)

-- ---- inactive: fan-out is a no-op returning false (=> legacy fallback) ----
check("active() nil before setActive", combat.active() == nil)
check("onTarget returns false when inactive", combat.onTarget("Bob") == false)
check("no module method fired while inactive", #calls == 0)

-- ---- setActive to an UNREGISTERED id => still legacy (active() nil) ----
combat.setActive("test.ghost")
check("active() nil for unregistered id", combat.active() == nil)
check("activeId tracks the set id", combat.activeId() == "test.ghost")
check("arm returns false (no registered active)", combat.arm({}) == false)

-- ---- activate the real module; late-resolves because active() is lazy ----
combat.setActive("test.alpha")
check("active() resolves the registered module", combat.active() == alpha)
check("isActive true for current id", combat.isActive("test.alpha"))
check("activate fired on switch-in", calls[#calls] and calls[#calls].tag == "activate")

-- ---- dispatch routes to the active module, arg as first parameter ----
calls = {}
check("onTarget returns true when active", combat.onTarget("Bob") == true)
check("onTarget routed name arg", calls[1] and calls[1].tag == "onTarget" and calls[1].arg == "Bob")

combat.arm({ mode = "fire", limb = "arms" })
check("arm routed the opts table", calls[2] and calls[2].tag == "arm" and calls[2].arg.mode == "fire" and calls[2].arg.limb == "arms")

combat.arm()
check("arm with no opts passes an empty table", calls[3] and calls[3].tag == "arm" and type(calls[3].arg) == "table")

combat.onBalanceUsed("2.45")
check("onBalanceUsed coerces to number", calls[4] and calls[4].tag == "onBalanceUsed" and calls[4].arg == 2.45)

combat.reset()
check("reset routed", calls[5] and calls[5].tag == "reset")

-- ---- a method the module does NOT implement: still 'handled', no error ----
calls = {}
check("status() returns true even though module omits it", combat.status() == true)
check("status() fired nothing (no-op)", #calls == 0)

-- ---- switching away tears down the previous module ----
calls = {}
combat.setActive(nil)
check("deactivate fired on switch-out", calls[1] and calls[1].tag == "deactivate")
check("active() nil after setActive(nil)", combat.active() == nil)

-- ---- re-registration (module reload) overwrites and stays usable ----
combat.setActive("test.alpha")
local alpha2 = { id = "test.alpha", onTarget = rec("onTarget2") }
combat.register(alpha2)
check("re-register overwrites", combat.get("test.alpha") == alpha2)
check("active() reflects new registration", combat.active() == alpha2)

-- ---- a throwing method is caught; dispatch still reports handled ----
combat.register({ id = "test.boom", onTarget = function() error("boom") end })
combat.setActive("test.boom")
local ok = pcall(function() return combat.onTarget("X") end)
check("dispatch swallows module error (pcall)", ok)
check("onTarget still returns true despite error", combat.onTarget("X") == true)

print(string.rep("-", 40))
if failures == 0 then
	print("ALL PASS")
	os.exit(0)
else
	print(failures .. " FAILURE(S)")
	os.exit(1)
end
