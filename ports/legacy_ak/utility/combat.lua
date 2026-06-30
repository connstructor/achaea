-- =============================================================
-- combat.lua -- Unified combat framework core (SysCombatCore).
--
-- Load this FIRST (top of the Mudlet script tree). It owns:
--   * the registry (id -> module table),
--   * exactly one active module,
--   * dispatch of the standard combat API to that module.
--
-- A "combat module" is a namespace table that implements the standard API
-- directly (arm/onTarget/onClearTarget/onBalanceUsed/reset/status/...) plus an
-- `id` field. Registering hands that table itself to the registry -- there is no
-- separate adapter type; the module IS the contract. See COMBAT_FRAMEWORK.md.
--
-- Until a module is active, combat.active() is nil and every dispatch returns
-- false, so target.lua falls back to its legacy per-class branches.
-- =============================================================

combat = combat or {}
combat._modules = combat._modules or {} -- id -> module table
combat._activeId = combat._activeId -- string id, or nil
if combat.debug == nil then
	combat.debug = false
end

local function dbg(msg)
	if combat.debug then
		cecho("\n<grey>[combat] " .. msg)
	end
end

-- Call a standard API function on a module, if it implements one by that name.
-- Wrapped in pcall so a buggy module can't abort target.lua mid-flow; errors are
-- always surfaced (red), regardless of debug. Called positionally -- standard API
-- functions are plain (dot-defined) and close over their own namespace, so they
-- take no `self`.
local function call_method(mod, method, arg)
	local fn = mod[method]
	if type(fn) ~= "function" then
		return
	end
	local ok, err = pcall(fn, arg)
	if not ok then
		cecho("\n<red>[combat] " .. tostring(method) .. " error (" .. tostring(combat._activeId) .. "): " .. tostring(err))
	end
end

-- -------------------------------------------------------------
-- Registry
-- -------------------------------------------------------------

-- Register (or replace) a combat module by its id. Idempotent: re-registering
-- the same id overwrites, so reloading a module file refreshes it cleanly (and
-- keeps it active if it was active -- same id).
function combat.register(mod)
	assert(type(mod) == "table", "combat.register: module must be a table")
	assert(
		type(mod.id) == "string" and mod.id ~= "",
		"combat.register: module.id must be a non-empty string"
	)
	local replacing = combat._modules[mod.id] ~= nil
	combat._modules[mod.id] = mod
	dbg((replacing and "re-registered " or "registered ") .. mod.id)
	return mod
end

function combat.get(id)
	return id and combat._modules[id] or nil
end

function combat.active()
	return combat._activeId and combat._modules[combat._activeId] or nil
end

function combat.activeId()
	return combat._activeId
end

function combat.isActive(id)
	return combat._activeId == id
end

-- Switch the active module (driven by class_switch). Tears down the outgoing
-- module, then sets up the incoming one. id may be nil: "no module for this
-- class" => target.lua uses the legacy path.
function combat.setActive(id)
	if id == combat._activeId then
		return
	end
	local prev = combat.active()
	if prev then
		call_method(prev, "deactivate", nil)
	end
	combat._activeId = id
	local now = combat.active()
	if now then
		call_method(now, "activate", nil)
	end
	dbg("active -> " .. tostring(id))
end

-- -------------------------------------------------------------
-- Dispatch
--
-- Each forwards to the active module's same-named function and returns true if a
-- module is active (it OWNS the behavior, even if it doesn't implement that
-- particular method -- absent means no-op, NOT legacy fallback). Returns false
-- only when no module is active, so the caller runs its legacy branch.
-- -------------------------------------------------------------

local function fanout(method, arg)
	local a = combat.active()
	if not a then
		return false
	end
	call_method(a, method, arg)
	return true
end

function combat.arm(opts)
	return fanout("arm", opts or {})
end

function combat.onTarget(name)
	return fanout("onTarget", name)
end

function combat.onClearTarget()
	return fanout("onClearTarget", nil)
end

function combat.onBalanceUsed(interval)
	return fanout("onBalanceUsed", tonumber(interval) or interval)
end

function combat.reset()
	return fanout("reset", nil)
end

function combat.status()
	return fanout("status", nil)
end

dbg("core loaded")
