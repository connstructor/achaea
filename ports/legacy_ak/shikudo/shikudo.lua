--[[
================================================================================
SHIKUDO GOD MODE — LEGACY / AK PORT (5-limb monk offense)
================================================================================

Fresh port of the LEVI/Ataxia Shikudo god-mode script
(`009_CC_Shikudo_GodMode.lua`). Lean offense: the limb-prep engine, form
management, the 3-combo execute, and the two finisher forks (DISPATCH and the
soft-LOCK fork). Self-sustain that lived in the Levi run() — transmute, kai
boost, mind lock (Telepathy) and the Maelstrom low-HP crescent fork — is
intentionally dropped (see DEPENDENCIES.md).

THE PLAN
  BUILD (Tykonos -> Willow -> Rain -> Oak): prep both legs, both arms and the
  head to PREP_THRESHOLD (92%). `hyperfocus head` rides during prep so stray
  hits don't break the head early. Light any hit that would break a prepped
  limb. Affs ride along on the staff (kuro -> weariness/lethargy,
  ruku -> slickness/healthleech/clumsiness, hiru -> dizziness,
  hiraku -> anorexia, nervestrike -> paralysis, livestrike -> asthma).

  EXECUTE (Gaital, all 5 at 92+): a stateless 3-combo read from live state —
    C1: sweep + flashheel left      -> prone, left leg broken (drop hyperfocus)
    C2: ruku left + ruku right + flashheel right -> both arms + right leg broken
    C3: needle + [staff] + flashheel left        -> head broken, crushedthroat

  FINISH
    prone + head-broken + crushedthroat  -> DISPATCH
    both arms broken + >=3 lock affs     -> flow Rain (soft-lock fork)

USAGE
  sk()         dispatch one tick (bind to your attack key / balance trigger)
  skstatus()   status panel
  skreset()    clear runtime state
  skdebug()    toggle the per-tick debug echo
  skcal() / skcalshow() / skcalstop()   measure + print the limb-break table (calibrate.lua)

PUBLIC API (everything else is file-local)
  monk.shikudo.CONFIG / .state / .limbDamage  -- limbDamage is the measured lookup table
  monk.shikudo.dispatch() / .run() / .status() / .reset()
  monk.shikudo.calcLimbs() / .formswap()

DEPENDENCY SUMMARY (full mapping in DEPENDENCIES.md)
  target / lb[target].hits[limb] / targetparry / affstrack.score  -- AK globals
  gmcp.Char.Vitals.charstats  -- "Form: X" / "Kata: N" (monk form + combo count)
  Legacy.Curing.Affs / Legacy.Settings.Curing  -- self affs / curing-paused
  ak.limbs.hyperfocus  -- the limb we currently have hyperfocused (read live)
  send / cecho / getEpoch / tempTimer  -- Mudlet host
  Queue dispatch:  SETALIAS SKATK <cmd> ; QUEUE ADDCLEARFULL EQBAL SKATK

HYPERFOCUS (no tracking, no trigger)
  Read live from ak.limbs.hyperfocus. We issue `hyperfocus head` only during prep
  (non-Gaital) when it isn't already on the head, and combo 1's sweep drops it with
  `hyperfocus none`. Nothing is latched — every tick re-reads the live focus.
================================================================================
]]
--

monk = monk or {}
monk.shikudo = monk.shikudo or {}
local mod = monk.shikudo

-- ============================================================
--  CONFIG
-- ============================================================
-- Defined fresh on every (re)load — CONFIG is the file's source of truth, so
-- editing a value here and reloading takes effect, and we never inherit a stale
-- CONFIG from an earlier/older load of this script (a `CONFIG or {...}` keeps the
-- old table; if it predates a key this version needs, the threshold comparisons
-- nil-crash). Runtime mutable state lives in mod.state, not here.
mod.CONFIG = {
	-- Limb is "prepped" at 92%+ (one shaping hit from a break).
	PREP_THRESHOLD = 92,
	-- Head counts as prep-ready at 86%+ (needle ~16% breaks it).
	HEAD_PREP_THRESHOLD = 86,
	-- Soft-lock fork triggers at >= this many lock affs (with both arms broken).
	LOCK_FORK_MIN_AFFS = 3,
	-- affstrack confidence (0-100) at/above which an aff counts as present.
	AFF_THRESHOLD = 30,
	-- Command separator inside the SETALIAS body, and the queue plumbing.
	separator = "/",
	aliasName = "SKATK",
	queueType = "EQBAL",
	-- Per-tick debug echo (skdebug() toggles).
	debug = false,
	-- Self lock-break cooldown (seconds) between `fitness` attempts.
	lockBreakCooldown = 2,
	-- Echo debounce window (seconds).
	echoDebounce = 0.3,
}

-- ============================================================
--  STATE
-- ============================================================
mod.state = mod.state
	or {
		-- Nothing combat-related is latched: limbs (lb), affs (affstrack), form/kata
		-- (charstats) and hyperfocus (ak.limbs.hyperfocus) are all read live each tick.
		lastEcho = nil, -- echo-debounce stamp (cosmetic, debug only)
	}

-- Per-tick scratch state (reset at the top of run()/status()). Declared here so
-- calcLimbs / the form prios / formswap all close over the SAME upvalue.
local gm = {}

-- The lock-fork aff set (hoisted; matches Levi's GM_LOCK_AFFS).
local GM_LOCK_AFFS = {
	"slickness",
	"asthma",
	"addiction",
	"weariness",
	"paralysis",
	"anorexia",
	"impatience",
	"confusion",
}

local _lockBreakCooldown = 0

-- ============================================================
--  AK / LEGACY HELPERS
-- ============================================================
-- Target affliction: affstrack.score[aff] is 0-100 confidence.
local function has(aff)
	return affstrack and affstrack.score and (affstrack.score[aff] or 0) >= mod.CONFIG.AFF_THRESHOLD
end

-- The limb we currently have hyperfocused. AK tracks it live (ak.limbs.hyperfocus),
-- so we never store it — read it and act only when it isn't already what we need.
local function hyperFocus()
	local h = ak and ak.limbs and ak.limbs.hyperfocus
	return h and tostring(h):lower() or "none"
end

-- Parse gmcp.Char.Vitals.charstats ("Form: Rain", "Kata: 7", ...). Returns a
-- number when numeric (% stripped), the raw string otherwise, or nil.
local function charstat(name)
	local cs = gmcp and gmcp.Char and gmcp.Char.Vitals and gmcp.Char.Vitals.charstats
	if not cs then
		return nil
	end
	local prefix = name .. ": "
	for _, entry in ipairs(cs) do
		local val = tostring(entry):match("^" .. prefix .. "(.+)$")
		if val then
			val = val:gsub("%%", "")
			return tonumber(val) or val
		end
	end
	return nil
end

local function currentForm()
	return charstat("Form")
end

local function currentKata()
	return tonumber(charstat("Kata")) or 0
end

-- Self affliction (drives aeon / stupidity / lock-break gates).
local function selfAff(name)
	local a = Legacy and Legacy.Curing and Legacy.Curing.Affs
	return a and a[name] or false
end

-- Curing paused -> stand down.
local function isPaused()
	return Legacy and Legacy.Settings and Legacy.Settings.Curing and Legacy.Settings.Curing.status == false or false
end

-- Limb-break progress (0-200). AK feeds lb[target].hits[limb] from triggers.
local function getLimbDamage(limb)
	if not target or target == "" then
		return 0
	end
	if not lb or not lb[target] or not lb[target].hits then
		return 0
	end
	return lb[target].hits[limb] or 0
end

-- Long limb name -> the affstrack key suffix used for damaged/broken affs.
local LIMB_KEY = {
	["left leg"] = "leftleg",
	["right leg"] = "rightleg",
	["left arm"] = "leftarm",
	["right arm"] = "rightarm",
	head = "head",
	torso = "torso",
}

-- A limb counts as broken if its damage hit 100, or affstrack reports it
-- damaged/broken. Collapses Levi's tAffs.damagedX / haveAff("brokenX") duality.
local function limbBroken(limb)
	if getLimbDamage(limb) >= 100 then
		return true
	end
	local k = LIMB_KEY[limb]
	if k and (has("damaged" .. k) or has("broken" .. k)) then
		return true
	end
	return false
end

-- Legacy SETALIAS / QUEUE dispatch (shared house pattern; "/" joins commands).
local function sendAttack(cmd, queueType)
	if not cmd or cmd == "" then
		return
	end
	send("SETALIAS " .. mod.CONFIG.aliasName .. " " .. cmd)
	send("QUEUE ADDCLEARFULL " .. (queueType or mod.CONFIG.queueType) .. " " .. mod.CONFIG.aliasName)
end

-- Monk soft-lock breaker (asthma + anorexia + slickness|bloodfire -> stand+fitness).
local function selfNeedLockBreak()
	return selfAff("asthma") and selfAff("anorexia") and (selfAff("slickness") or selfAff("bloodfire")) or false
end

local function selfLockBreak()
	local now = (getEpoch and getEpoch()) or os.time()
	if now < _lockBreakCooldown then
		return false
	end
	if not selfNeedLockBreak() then
		return false
	end
	if selfAff("prone") and not selfAff("paralysis") then
		send("stand")
	end
	send("fitness")
	_lockBreakCooldown = now + mod.CONFIG.lockBreakCooldown
	return true
end

local function shouldEcho()
	local now = (getEpoch and getEpoch()) or os.time()
	if not mod.state.lastEcho or (now - mod.state.lastEcho) > mod.CONFIG.echoDebounce then
		mod.state.lastEcho = now
		return true
	end
	return false
end

-- ============================================================
--  LIMB-DAMAGE TABLE  (static, measured per character)
-- ============================================================
-- "% of a limb break each attack lands" — the engine looks these up to decide
-- prep / break / light. Limb damage scales with your stats and staff artifact, so
-- these are MEASURED, not computed: run calibrate.lua's `skcal` against a fresh
-- target in each form, then paste `skcalshow()`'s output over this table.
--
-- Seeds below are rough (Levi's old formula at 5000 health) so the engine works
-- out of the box; calibrate for accuracy. Defined fresh on load (file = truth).
mod.limbDamage = {
	flashheel = 9.72, -- kick  -> leg
	kuro = 9.72, -- staff -> leg   (weariness / lethargy)
	frontkick = 9.72, -- kick  -> arm
	ruku = 9.72, -- staff -> arm   (slickness / healthleech / clumsiness)
	risingkick = 9.72, -- kick  -> head / torso
	nervestrike = 14.94, -- staff -> head  (paralysis)
	hiru = 10.06, -- staff -> head  (dizziness)
	hiraku = 10.06, -- staff -> head  (anorexia)
	needle = 16.46, -- staff -> head  (crushedthroat)
}

-- ============================================================
--  LIMB STATE CALCULATOR  (fresh each tick into gm)
-- ============================================================
function mod.calcLimbs()
	local ld = mod.limbDamage
	local thresh = mod.CONFIG.PREP_THRESHOLD

	gm.LL = getLimbDamage("left leg")
	gm.RL = getLimbDamage("right leg")
	gm.LA = getLimbDamage("left arm")
	gm.RA = getLimbDamage("right arm")
	gm.H = getLimbDamage("head")
	gm.T = getLimbDamage("torso")

	-- Arms: prepped = at threshold; ruku-ready = one ruku breaks.
	gm.laRUK = (gm.LA + ld.ruku >= 100)
	gm.raRUK = (gm.RA + ld.ruku >= 100)
	gm.laPREP = (gm.LA >= thresh)
	gm.raPREP = (gm.RA >= thresh)

	-- Legs: kuro/flashheel-ready = one hit breaks, and not already broken.
	gm.llKUR = (gm.LL + ld.kuro >= 100) and not limbBroken("left leg")
	gm.rlKUR = (gm.RL + ld.kuro >= 100) and not limbBroken("right leg")
	gm.llFLASH = (gm.LL + ld.flashheel >= 100) and not limbBroken("left leg")
	gm.rlFLASH = (gm.RL + ld.flashheel >= 100) and not limbBroken("right leg")

	-- Head: needle breaks at the head-prep threshold with hyperfocus dropped.
	gm.hNEED = (gm.H + ld.needle >= 100)
	gm.hPREP = (gm.H >= mod.CONFIG.HEAD_PREP_THRESHOLD)
	gm.hNERV = (gm.H + ld.nervestrike >= 100)
	gm.hHIRU = (gm.H + ld.hiru >= 100)
	gm.hHIRA = (gm.H + ld.hiraku >= 100)
	gm.hHIHI = (gm.H + ld.hiru + ld.hiraku >= 100)
	gm.hNERVRIS = (gm.H + ld.nervestrike + ld.risingkick >= 100)

	gm.bothLegsBroken = limbBroken("left leg") and limbBroken("right leg")
	gm.bothArmsBroken = limbBroken("left arm") and limbBroken("right arm")

	gm.executeReady = gm.llFLASH and gm.rlFLASH and gm.laPREP and gm.raPREP and gm.hPREP

	local lockCount = 0
	for _, aff in ipairs(GM_LOCK_AFFS) do
		if has(aff) then
			lockCount = lockCount + 1
		end
	end
	gm.lockCount = lockCount
	gm.lockForkReady = gm.bothArmsBroken and lockCount >= mod.CONFIG.LOCK_FORK_MIN_AFFS
end

-- ============================================================
--  LIGHT GUARD  (BUILD phase only — never break a prepped limb early)
-- ============================================================
local SHORT_TO_LONG = {
	LL = "left leg",
	RL = "right leg",
	LA = "left arm",
	RA = "right arm",
}

local function shouldLight(key, damageValue, simulated)
	local current = (gm[key] or 0) + (simulated or 0)
	if key == "H" then
		return (current + damageValue >= 100) and gm.hPREP
	end
	local limb = SHORT_TO_LONG[key]
	if limb then
		return (current + damageValue >= 100) and not limbBroken(limb)
	end
	return false -- torso: never light
end

-- ============================================================
--  FORM-SPECIFIC PRIORITIES  (each sets gm.staff = {} and gm.kick)
-- ============================================================

-- ── TYKONOS ──────────────────────────────────────────────
local function tykonosPrios()
	gm.staff = {}
	gm.kick = "none"
	if not has("prone") then
		table.insert(gm.staff, "sweep")
	end
	gm.kick = gm.hNERVRIS and "risingkick torso" or "risingkick head"
end

-- ── WILLOW ───────────────────────────────────────────────
local function willowPrios()
	gm.staff = {}
	gm.kick = "none"

	-- Kick: flashheel to prep legs (avoid a parried left leg).
	if not gm.llFLASH and targetparry ~= "left leg" then
		gm.kick = "flashheel left"
	elseif not gm.rlFLASH then
		gm.kick = "flashheel right"
	else
		if not has("prone") then
			table.insert(gm.staff, "sweep")
		end
		gm.kick = "spinkick"
	end

	-- Staff: hiru + hiraku for head pressure, lit if they'd break the head.
	if not gm.hHIHI then
		table.insert(gm.staff, gm.hHIRU and "hiru light" or "hiru")
		table.insert(gm.staff, gm.hHIRA and "hiraku light" or "hiraku")
	else
		table.insert(gm.staff, "hiru light")
		table.insert(gm.staff, "hiraku light")
	end
end

-- ── RAIN ─────────────────────────────────────────────────
local function rainPrios()
	gm.staff = {}
	gm.kick = "none"
	local ld = mod.limbDamage
	local k = gm.kata or 0

	-- LOCK FORK: both arms broken + >=3 lock affs -> drive the soft-lock.
	if gm.lockForkReady then
		gm.kick = "frontkick left"
		local slot1, slot2 = nil, nil
		if not has("weariness") then
			slot1 = "kuro left"
		elseif not has("lethargy") then
			slot1 = "kuro right"
		elseif not has("clumsiness") then
			slot1 = "ruku torso"
		end
		if not has("slickness") and not slot1 then
			slot1 = "ruku torso"
		elseif not has("slickness") then
			slot2 = "ruku torso"
		end
		if not slot1 then
			slot1 = "kuro left"
		end
		if not slot2 then
			slot2 = "kuro right"
		end
		table.insert(gm.staff, slot1)
		if slot2 then
			table.insert(gm.staff, slot2)
		end
		return
	end

	local allLegsDone = gm.llFLASH and gm.rlFLASH
	local allArmsDone = gm.laPREP and gm.raPREP

	-- All 5 prepped: hold with lights.
	if allLegsDone and allArmsDone and gm.hPREP then
		gm.kick = "none"
		if not has("slickness") then
			table.insert(gm.staff, "ruku torso")
		else
			table.insert(gm.staff, gm.hHIRU and "hiru light" or "hiru")
		end
		table.insert(gm.staff, "kuro light left")
		return
	end

	-- Legs + arms prepped, head not yet: hiru for head pressure.
	if allLegsDone and allArmsDone and not gm.hPREP then
		gm.kick = "none"
		table.insert(gm.staff, gm.hHIRU and "hiru light" or "hiru")
		table.insert(gm.staff, "kuro light left")
		return
	end

	-- Frontkick targets arms; never kick a ruku-ready arm (kicks can't go light).
	local sim = {}
	local leftSafe = targetparry ~= "left arm" and not gm.laRUK
	local rightSafe = targetparry ~= "right arm" and not gm.raRUK
	if leftSafe and (not rightSafe or gm.LA <= gm.RA) then
		gm.kick = "frontkick left"
		sim.LA = (sim.LA or 0) + ld.frontkick
	elseif rightSafe then
		gm.kick = "frontkick right"
		sim.RA = (sim.RA or 0) + ld.frontkick
	else
		gm.kick = "none"
	end

	local function pickKuro()
		if not gm.llKUR and (gm.rlKUR or gm.LL <= gm.RL) then
			local light = shouldLight("LL", ld.kuro, sim.LL)
			local s = light and "kuro light left" or "kuro left"
			if not light then
				sim.LL = (sim.LL or 0) + ld.kuro
			end
			return s
		elseif not gm.rlKUR then
			local light = shouldLight("RL", ld.kuro, sim.RL)
			local s = light and "kuro light right" or "kuro right"
			if not light then
				sim.RL = (sim.RL or 0) + ld.kuro
			end
			return s
		end
		return "kuro light left"
	end

	local function pickRuku()
		if gm.LA <= gm.RA then
			local light = shouldLight("LA", ld.ruku, sim.LA)
			local s = light and "ruku light left" or "ruku left"
			if not light then
				sim.LA = (sim.LA or 0) + ld.ruku
			end
			return s
		else
			local light = shouldLight("RA", ld.ruku, sim.RA)
			local s = light and "ruku light right" or "ruku right"
			if not light then
				sim.RA = (sim.RA or 0) + ld.ruku
			end
			return s
		end
	end

	local slot1, slot2 = nil, nil
	-- P1: kuro@12+ kata for weariness+lethargy.
	if k >= 12 and not has("lethargy") then
		slot1 = pickKuro()
	end
	-- P2: ruku@10+ kata for clumsiness+healthleech.
	if k >= 10 and not has("healthleech") then
		if not slot1 then
			slot1 = pickRuku()
		elseif not slot2 then
			slot2 = pickRuku()
		end
	end
	-- P3: clumsiness.
	if not has("clumsiness") then
		if not slot1 then
			slot1 = pickRuku()
		elseif not slot2 then
			slot2 = pickRuku()
		end
	end
	-- P4: lethargy.
	if not has("lethargy") then
		if not slot1 then
			slot1 = pickKuro()
		elseif not slot2 and (not slot1 or not slot1:find("kuro")) then
			slot2 = pickKuro()
		end
	end
	-- P5/P6: leg prep, then arm prep.
	if not slot1 then
		slot1 = pickKuro()
	end
	if not slot1 then
		slot1 = pickRuku()
	end
	if not slot2 then
		if slot1 and slot1:find("kuro") then
			slot2 = pickRuku()
		elseif slot1 and slot1:find("ruku") then
			slot2 = pickKuro()
		else
			slot2 = pickRuku()
		end
	end
	-- P7: filler.
	if not slot1 then
		slot1 = "ruku torso"
	end
	if not slot2 then
		slot2 = gm.hHIRU and "hiru light" or "hiru"
	end

	table.insert(gm.staff, slot1)
	if slot2 then
		table.insert(gm.staff, slot2)
	end
end

-- ── OAK ──────────────────────────────────────────────────
local function oakPrios()
	gm.staff = {}
	gm.kick = "none"
	local ld = mod.limbDamage

	local allPrepped = gm.llFLASH and gm.rlFLASH and gm.laPREP and gm.raPREP and gm.hPREP

	if allPrepped then
		-- Light only, to build kata while affs cook.
		gm.kick = "risingkick torso"
		if not has("paralysis") then
			table.insert(gm.staff, "nervestrike light")
		else
			table.insert(gm.staff, "livestrike light")
		end
		if not has("asthma") then
			table.insert(gm.staff, "livestrike light")
		elseif not has("slickness") then
			table.insert(gm.staff, "ruku torso")
		else
			table.insert(gm.staff, "nervestrike light")
		end
		return
	end

	-- Kick with the risingkick+nervestrike head-safety check.
	if not gm.hPREP then
		gm.kick = gm.hNERVRIS and "risingkick torso" or "risingkick head"
	else
		gm.kick = "risingkick torso"
	end

	-- Slot 1: nervestrike for head prep / paralysis.
	if not gm.hPREP then
		table.insert(gm.staff, gm.hNERV and "nervestrike light" or "nervestrike")
	elseif not has("paralysis") then
		local light = shouldLight("H", ld.nervestrike, 0)
		table.insert(gm.staff, light and "nervestrike light" or "nervestrike")
	else
		if not has("asthma") then
			table.insert(gm.staff, "livestrike")
		elseif not has("slickness") then
			table.insert(gm.staff, "ruku torso")
		end
	end

	-- Slot 2: leg or arm prep with a light guard.
	if not gm.llKUR and (gm.rlKUR or gm.LL <= gm.RL) then
		local light = shouldLight("LL", ld.kuro, 0)
		table.insert(gm.staff, light and "kuro light left" or "kuro left")
	elseif not gm.rlKUR then
		local light = shouldLight("RL", ld.kuro, 0)
		table.insert(gm.staff, light and "kuro light right" or "kuro right")
	elseif not gm.laPREP then
		local light = shouldLight("LA", ld.ruku, 0)
		table.insert(gm.staff, light and "ruku light left" or "ruku left")
	elseif not gm.raPREP then
		local light = shouldLight("RA", ld.ruku, 0)
		table.insert(gm.staff, light and "ruku light right" or "ruku right")
	elseif not has("asthma") then
		table.insert(gm.staff, "livestrike")
	elseif not has("slickness") then
		table.insert(gm.staff, "ruku torso")
	end
end

-- ── GAITAL ───────────────────────────────────────────────
-- Stateless execute: read live state, pick the right combo. (Levi's dispatch
-- sentinel is removed here — run()'s early DISPATCH check owns that path.)
local function gaitalPrios()
	gm.staff = {}
	gm.kick = "none"
	local k = gm.kata or 0
	local ld = mod.limbDamage

	-- LOCK FORK: both arms broken + >=3 lock affs -> flow Rain.
	if gm.lockForkReady then
		gm.staff[1] = "lock_fork"
		return
	end

	-- COMBO 3: prone + both arms broken + right leg broken
	-- needle + smart staff + flashheel left.
	if has("prone") and gm.bothArmsBroken and limbBroken("right leg") then
		gm.staff = {}
		table.insert(gm.staff, "needle")
		if not has("clumsiness") then
			table.insert(gm.staff, gm.LA <= gm.RA and "ruku left" or "ruku right")
		elseif not has("lethargy") then
			table.insert(gm.staff, "kuro right")
		elseif not has("slickness") then
			table.insert(gm.staff, "ruku torso")
		elseif not has("addiction") then
			table.insert(gm.staff, "jinzuku")
		else
			table.insert(gm.staff, gm.LA <= gm.RA and "ruku left" or "ruku right")
		end
		gm.kick = "flashheel left"
		return
	end

	-- RE-NEEDLE: prone + head broken + crushedthroat cured.
	if has("prone") and limbBroken("head") and not has("crushedthroat") then
		gm.staff = {}
		table.insert(gm.staff, "needle")
		if not has("clumsiness") then
			table.insert(gm.staff, gm.LA <= gm.RA and "ruku left" or "ruku right")
		elseif not has("lethargy") then
			table.insert(gm.staff, "kuro right")
		elseif not has("slickness") then
			table.insert(gm.staff, "ruku torso")
		else
			table.insert(gm.staff, "jinzuku")
		end
		if not limbBroken("left leg") then
			gm.kick = "flashheel left"
		elseif not limbBroken("right leg") then
			gm.kick = "flashheel right"
		else
			gm.kick = "none"
		end
		return
	end

	-- COMBO 2: prone + left leg broken + arms not both broken yet.
	if has("prone") and limbBroken("left leg") and not gm.bothArmsBroken then
		gm.staff = {}
		table.insert(gm.staff, "ruku left")
		table.insert(gm.staff, "ruku right")
		gm.kick = "flashheel right"
		return
	end

	-- COMBO 1: all 5 prepped, not prone.
	if gm.executeReady and not has("prone") then
		gm.staff = {}
		table.insert(gm.staff, "sweep")
		gm.kick = "flashheel left"
		return
	end

	-- KATA GUARD: not in execute, kata deep -> torso filler only.
	if k >= 10 and not gm.executeReady then
		gm.kick = "none"
		table.insert(gm.staff, not has("slickness") and "ruku torso" or "jinzuku")
		table.insert(gm.staff, not has("addiction") and "jinzuku" or "ruku torso")
		return
	end

	-- STILL BUILDING in Gaital: flashheel legs + kuro/ruku staff.
	local simLL, simRL = 0, 0
	if
		not gm.llFLASH
		and not limbBroken("left leg")
		and (gm.rlFLASH or gm.LL <= gm.RL)
		and targetparry ~= "left leg"
	then
		gm.kick = "flashheel left"
		simLL = simLL + ld.flashheel
	elseif not gm.rlFLASH and not limbBroken("right leg") then
		gm.kick = "flashheel right"
		simRL = simRL + ld.flashheel
	else
		gm.kick = "none"
	end

	local function gPickKuro()
		if not gm.llKUR and (gm.rlKUR or gm.LL <= gm.RL) then
			local light = shouldLight("LL", ld.kuro, simLL)
			local s = light and "kuro light left" or "kuro left"
			if not light then
				simLL = simLL + ld.kuro
			end
			return s
		elseif not gm.rlKUR then
			local light = shouldLight("RL", ld.kuro, simRL)
			local s = light and "kuro light right" or "kuro right"
			if not light then
				simRL = simRL + ld.kuro
			end
			return s
		end
		return nil
	end

	local simLA, simRA = 0, 0
	local function gPickRuku()
		if not gm.laPREP then
			local light = shouldLight("LA", ld.ruku, simLA)
			local s = light and "ruku light left" or "ruku left"
			if not light then
				simLA = simLA + ld.ruku
			end
			return s
		elseif not gm.raPREP then
			local light = shouldLight("RA", ld.ruku, simRA)
			local s = light and "ruku light right" or "ruku right"
			if not light then
				simRA = simRA + ld.ruku
			end
			return s
		end
		return gm.LA <= gm.RA and "ruku light left" or "ruku light right"
	end

	local j1, j2 = nil, nil
	if not has("clumsiness") then
		j1 = gPickRuku()
	elseif not has("lethargy") then
		j1 = gPickKuro()
	end
	if not j1 then
		j1 = gPickKuro()
	end
	if not j1 then
		j1 = gPickRuku()
	end
	if not j1 then
		j1 = not has("addiction") and "jinzuku" or "ruku torso"
	end

	if j1 and j1:find("kuro left") then
		j2 = (not gm.rlKUR and gPickKuro()) or gPickRuku()
	elseif j1 and j1:find("kuro right") then
		j2 = (not gm.llKUR and gPickKuro()) or gPickRuku()
	elseif j1 and j1:find("ruku") then
		j2 = gPickKuro()
	end
	if not j2 then
		j2 = not has("addiction") and "jinzuku" or "ruku torso"
	end

	table.insert(gm.staff, j1)
	if j2 then
		table.insert(gm.staff, j2)
	end
end

-- ============================================================
--  FORM SWAP  (condition-based; Maelstrom branches dropped)
-- ============================================================
function mod.formswap()
	local f = gm.form
	local k = gm.kata or 0
	local targetForm = nil

	-- Lock fork: Gaital -> Rain to push the lock (needs kata to transition).
	if f == "Gaital" and gm.lockForkReady then
		if k >= 5 then
			return "Rain"
		else
			return f
		end
	end

	if f == "Tykonos" then
		targetForm = k >= 5 and "Willow" or "Tykonos"
	elseif f == "Willow" then
		local legsWorked = gm.llFLASH or gm.rlFLASH or gm.llKUR or gm.rlKUR
		if (k >= 5 and legsWorked) or k >= 8 then
			targetForm = "Rain"
		else
			targetForm = "Willow"
		end
	elseif f == "Rain" then
		if gm.lockForkReady then
			return "Rain"
		end
		local legsPrepped = gm.llKUR and gm.rlKUR
		local armsAndLegs = legsPrepped and gm.laPREP and gm.raPREP
		if k >= 5 and armsAndLegs and gm.hPREP then
			targetForm = "Oak"
		elseif k >= 5 and legsPrepped and (has("weariness") or has("lethargy")) then
			targetForm = "Oak"
		elseif k >= 22 then
			targetForm = "Oak"
		else
			targetForm = "Rain"
		end
	elseif f == "Oak" then
		local allPrepped = gm.llFLASH and gm.rlFLASH and gm.laPREP and gm.raPREP and gm.hPREP
		local partialDone = (gm.llFLASH or gm.rlFLASH) and gm.hPREP
		local affsCooking = has("paralysis") or has("asthma")
		if k >= 5 and allPrepped then
			targetForm = "Gaital"
		elseif k >= 5 and partialDone and affsCooking then
			targetForm = "Gaital"
		elseif k >= 10 then
			targetForm = "Gaital"
		else
			targetForm = "Oak"
		end
	elseif f == "Gaital" then
		local killReady = limbBroken("head") and has("crushedthroat")
		local midExecute = has("prone") and (limbBroken("head") or gm.bothLegsBroken or gm.bothArmsBroken)
		if k >= 10 and not gm.executeReady and not killReady and not gm.lockForkReady and not midExecute then
			targetForm = "Rain"
		else
			targetForm = "Gaital"
		end
	end

	return targetForm or f
end

-- ============================================================
--  COMBO ASSEMBLY HELPERS
-- ============================================================
-- Run a form's priority function (sets gm.staff / gm.kick). Returns false for an
-- unrecognised form so the caller can re-adopt.
local function runPrios(formName)
	if formName == "Tykonos" then
		tykonosPrios()
	elseif formName == "Willow" then
		willowPrios()
	elseif formName == "Rain" then
		rainPrios()
	elseif formName == "Oak" then
		oakPrios()
	elseif formName == "Gaital" then
		gaitalPrios()
	else
		return false
	end
	return true
end

-- Assemble the queued command from the already-computed gm.staff / gm.kick for the
-- given form. Returns the command string ("" if there's nothing to send), or nil
-- for the lock_fork sentinel (which the caller turns into its own form change).
local function buildComboString(formName)
	if gm.staff[1] == "lock_fork" then
		return nil
	end

	-- Combo 1 (sweep): drop hyperfocus first so needle can break the head.
	if gm.staff[1] == "sweep" then
		local prefix = (hyperFocus() == "head") and ("hyperfocus none" .. mod.CONFIG.separator) or ""
		local c = (gm.kick ~= "none") and ("sweep " .. gm.kick) or "sweep"
		return prefix .. "combo " .. target .. " " .. c
	end

	-- Standard: Rain (and Oak+clumsiness) kick first, everything else staff first.
	local s1 = gm.staff[1] or ""
	local s2 = gm.staff[2] or ""
	local combo = ""
	local kickFirst = (formName == "Rain") or (formName == "Oak" and has("clumsiness"))
	if kickFirst then
		if gm.kick ~= "none" and s1 ~= "" and s2 ~= "" then
			combo = gm.kick .. " " .. s1 .. " " .. s2
		elseif gm.kick ~= "none" and s1 ~= "" then
			combo = gm.kick .. " " .. s1
		elseif s1 ~= "" and s2 ~= "" then
			combo = s1 .. " " .. s2
		elseif s1 ~= "" then
			combo = s1
		end
	else
		if s1 ~= "" and s2 ~= "" and gm.kick ~= "none" then
			combo = s1 .. " " .. s2 .. " " .. gm.kick
		elseif s1 ~= "" and gm.kick ~= "none" then
			combo = s1 .. " " .. gm.kick
		elseif s1 ~= "" and s2 ~= "" then
			combo = s1 .. " " .. s2
		elseif gm.kick ~= "none" then
			combo = gm.kick
		elseif s1 ~= "" then
			combo = s1
		end
	end

	if combo == "" then
		return ""
	end
	return "combo " .. target .. " " .. combo
end

-- ============================================================
--  MAIN ENTRY  (assemble + queue)
-- ============================================================
function mod.run()
	local sp = mod.CONFIG.separator

	if not target or target == "" then
		cecho("\n<red>[Shikudo GM] No target set! Use: tar <name>")
		return
	end
	if not mod.limbDamage then
		cecho("\n<red>[Shikudo GM] Limb data not initialized")
		return
	end

	-- Self gates.
	if selfAff("aeon") then
		if shouldEcho() then
			cecho("\n<yellow>[Shikudo] <red>AEON - skipping")
		end
		return
	end
	if isPaused() then
		return
	end
	if selfAff("stupidity") then
		return
	end
	if selfNeedLockBreak() then
		selfLockBreak()
		return
	end

	local f = currentForm()
	local k = currentKata()

	-- Reset per-tick scratch (prevents stale sentinels from a prior tick).
	gm = {}
	gm.form = f
	gm.kata = k

	-- No form yet -> adopt Rain to bootstrap.
	if not f or f == "" or f == "none" or f == "None" then
		send("adopt rain form")
		return
	end

	mod.calcLimbs()

	if mod.CONFIG.debug and shouldEcho() then
		cecho(
			"\n<cyan>[Shikudo:<yellow>GM<cyan>] <yellow>"
				.. tostring(target)
				.. " <cyan>| <green>"
				.. f
				.. " <cyan>| k:<yellow>"
				.. k
				.. " <cyan>| exec:"
				.. tostring(gm.executeReady)
				.. " lock:"
				.. tostring(gm.lockForkReady)
		)
	end

	local atk = ""

	-- HYPERFOCUS: keep it on the head during prep so stray hits don't break the
	-- head early. ak.limbs.hyperfocus is the live truth — only act if it isn't
	-- already on the head. Skip in Gaital, where combo 1 drops it so needle breaks.
	if f ~= "Gaital" and hyperFocus() ~= "head" then
		sendAttack("hyperfocus head", mod.CONFIG.queueType)
		return
	end

	-- DISPATCH: prone + head broken + crushedthroat -> kill.
	if has("prone") and limbBroken("head") and has("crushedthroat") then
		atk = atk .. "dispatch " .. target
		cecho("\n<red>*** DISPATCH KILL ***")
		sendAttack(atk, mod.CONFIG.queueType)
		return
	end

	-- SHIELD: shatter through it.
	if has("shield") then
		atk = atk .. "combo " .. target .. " shatter"
		sendAttack(atk, mod.CONFIG.queueType)
		return
	end

	-- Form-specific priorities for the CURRENT form.
	if not runPrios(f) then
		send("adopt rain form")
		return
	end

	-- Form change.
	local targetForm = mod.formswap()
	if f ~= targetForm then
		if k >= 5 then
			-- Clean transition: needs balance but does NOT consume it, so we transition
			-- AND combo on the same balance. The prios above were for the old form (moves
			-- are form-specific), so rebuild them for the target form. A clean transition
			-- spends our kata, so the new form starts fresh -> compute its combo at kata 0.
			gm.form = targetForm
			gm.kata = 0
			runPrios(targetForm)
			local combo = buildComboString(targetForm)
			local cmd = "transition to the " .. targetForm .. " form"
			if combo and combo ~= "" then
				cmd = cmd .. sp .. combo
			end
			sendAttack(cmd, mod.CONFIG.queueType)
		else
			-- Not enough kata for a clean transition: ADOPT consumes the balance, so the
			-- combo lands on the next balance.
			sendAttack("adopt " .. targetForm .. " form", mod.CONFIG.queueType)
		end
		return
	end

	-- No transition. A lock_fork sentinel that stays in Gaital only happens at k<5
	-- (k>=5 routes through the clean-transition path above) -> adopt Rain.
	if gm.staff[1] == "lock_fork" then
		sendAttack("adopt Rain form", mod.CONFIG.queueType)
		return
	end

	-- Build + queue the combo for the current form.
	local combo = buildComboString(f)
	if combo and combo ~= "" then
		sendAttack(combo, mod.CONFIG.queueType)
	end
end

-- ============================================================
--  STATUS DISPLAY
-- ============================================================
function mod.status()
	local f = currentForm() or "Unknown"
	local k = currentKata()
	local thresh = mod.CONFIG.PREP_THRESHOLD

	gm = {}
	gm.form = f
	gm.kata = k
	if mod.limbDamage then
		mod.calcLimbs()
	end

	local ll, rl = getLimbDamage("left leg"), getLimbDamage("right leg")
	local la, ra = getLimbDamage("left arm"), getLimbDamage("right arm")
	local h = getLimbDamage("head")

	local function check(val)
		return val >= thresh and "<green>[X]" or "<red>[ ]"
	end
	local function colour(val)
		if val >= 100 then
			return "<red>"
		elseif val >= thresh then
			return "<green>"
		elseif val >= 70 then
			return "<yellow>"
		else
			return "<grey>"
		end
	end

	cecho("\n<cyan>+==============================================+")
	cecho("\n<cyan>|         <white>SHIKUDO GOD MODE<cyan>")
	cecho("\n<cyan>+==============================================+")
	cecho("\n<cyan>| <white>Target: <yellow>" .. tostring(target or "None"))
	cecho("\n<cyan>| <white>Form: <green>" .. f .. " <grey>(k:" .. k .. ")")
	cecho("\n<cyan>| <white>Hyper: <cyan>" .. tostring(hyperFocus()))
	cecho("\n<cyan>+----------------------------------------------+")
	cecho("\n<cyan>| <white>5-LIMB PREP (" .. thresh .. "%+):")
	cecho("\n<cyan>|   " .. check(ll) .. " <white>L Leg: " .. colour(ll) .. string.format("%.1f%%", ll))
	cecho("\n<cyan>|   " .. check(rl) .. " <white>R Leg: " .. colour(rl) .. string.format("%.1f%%", rl))
	cecho("\n<cyan>|   " .. check(la) .. " <white>L Arm: " .. colour(la) .. string.format("%.1f%%", la))
	cecho("\n<cyan>|   " .. check(ra) .. " <white>R Arm: " .. colour(ra) .. string.format("%.1f%%", ra))
	cecho("\n<cyan>|   " .. check(h) .. " <white>Head:  " .. colour(h) .. string.format("%.1f%%", h))

	local phase = "BUILD"
	if gm.executeReady then
		phase = "EXECUTE"
	end
	if gm.lockForkReady then
		phase = "LOCK FORK"
	end
	cecho("\n<cyan>| <white>Phase: <yellow>" .. phase)
	cecho("\n<cyan>+----------------------------------------------+")
	cecho("\n<cyan>| <white>KILL CONDITIONS:")
	cecho("\n<cyan>|   <white>Prone: " .. (has("prone") and "<green>YES" or "<red>NO"))
	cecho("\n<cyan>|   <white>Head Broken: " .. (limbBroken("head") and "<green>YES" or "<red>NO"))
	cecho("\n<cyan>|   <white>Crushedthroat: " .. (has("crushedthroat") and "<green>YES" or "<red>NO"))
	cecho("\n<cyan>|   <white>Lock Affs: <yellow>" .. (gm.lockCount or 0) .. "/" .. mod.CONFIG.LOCK_FORK_MIN_AFFS)
	cecho("\n<cyan>+==============================================+\n")
end

-- ============================================================
--  LIFECYCLE / PUBLIC HOOKS
-- ============================================================
function mod.dispatch()
	mod.run()
end

function mod.reset()
	mod.state.lastEcho = nil
	cecho("\n<yellow>[Shikudo] State reset")
end

-- ============================================================
--  CONVENIENCE ALIASES (typeable from the Mudlet input line)
-- ============================================================
function sk()
	monk.shikudo.dispatch()
end

function skstatus()
	monk.shikudo.status()
end

function skreset()
	monk.shikudo.reset()
end

function skdebug()
	monk.shikudo.CONFIG.debug = not monk.shikudo.CONFIG.debug
	cecho("\n<yellow>[Shikudo] Debug: " .. (monk.shikudo.CONFIG.debug and "<green>ON" or "<red>OFF"))
end
