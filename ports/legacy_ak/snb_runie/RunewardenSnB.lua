------------------------------------------
-- Lean draft of NewSnB.lua — review before replacing.
------------------------------------------
-- Required globals
------------------------------------------
-- Legacy: Character, curing state
-- ak: Opponent state
-- affstrack: Opponent affliction state
-- lb: Opponent limb damage state
-- target / targetparry: current target and the limb they parry
------------------------------------------
-- This module self-registers NOTHING -- no tempAlias / tempRegexTrigger. Create
-- the aliases and triggers by hand in Mudlet; see MUDLET_SETUP.md in this folder.
-- (The on-demand tempTimer in on_balance_used is transient sequencing, not a hook.)
------------------------------------------
runewarden = runewarden or {}
runewarden.snb = runewarden.snb or {}
-- If set to nil, Mudlet's getNetworkLatency() function is used instead.
runewarden.snb.CONFIG = {
	WEAPON = { LONGSWORD = "longsword140408", BROADSWORD = "broadsword268400", SHIELD = "shield435542" },
	EMPOWER_PRIO_SET = "ISAZ SLEIZAK INGUZ",
	LIMB_DAMAGE = { longsword140408 = 7.3, broadsword268400 = 12.9 },
	-- Venom selection uses the hand-tuned softlock/limblock cascades; see
	-- select_venom(). "softlock" mirrors the legacy `scc` attack (snbsoftlock);
	-- "limblock" drops the lone-anorexia -> aconite branch (snblimblock).
	VENOM_STRATEGY = "softlock",
	AFF_THRESHOLD = 67.0,
	PREARM_INTERVAL = nil,
}
runewarden.snb.DATA =
	{ MENTAL_AFFS = { "stupidity", "anorexia", "dizziness", "recklessness", "confusion", "epilepsy" } }
runewarden.snb.state = { next_bal_timer = nil, next_bal_armed = false, falcon_tracking = false, falcon_slaying = false }
-- LONGSWORD is the break weapon; BROADSWORD is the prep weapon.
local LONGSWORD = runewarden.snb.CONFIG.WEAPON.LONGSWORD
local BROADSWORD = runewarden.snb.CONFIG.WEAPON.BROADSWORD
local SHIELD = runewarden.snb.CONFIG.WEAPON.SHIELD
------------------------------------------
-- Opponent-state predicates
------------------------------------------

local function has_aff(aff)
	-- Afflictions in the Legacy/AK environment are tracked as affstrack.score[aff]:
	-- a 0-100 confidence that the aff is present (or nil). AFF_THRESHOLD is the
	-- confidence at which we treat the affliction as present. (The ported 026_SNB
	-- venom cascade reads target affs through here, mapping its tAffs.X checks onto
	-- the AK tracker.)
	return affstrack
			and affstrack.score
			and affstrack.score[aff]
			and affstrack.score[aff] >= runewarden.snb.CONFIG.AFF_THRESHOLD
		or false
end

local function have_eqbal()
	return gmcp and gmcp.Char and gmcp.Char.Vitals and gmcp.Char.Vitals.bal == "1" and gmcp.Char.Vitals.eq == "1"
end

local function have_fury()
	return Legacy and Legacy.Tannivh and Legacy.Tannivh.def and Legacy.Tannivh.def.fury or false
end

local function is_prone()
	return has_aff("prone")
end

local function is_impaled()
	return affstrack and affstrack.impale or false
end

-- Whether a SLICE would fail to land. A hard shield blocks regardless of stance,
-- but rebounding only reflects while they're standing -- a prone target doesn't
-- reflect, so once they're down rebounding stops mattering. RAZE clears either.

local function slice_blocked()
	if not (ak and ak.defs) then
		return false
	end
	if ak.defs.shield then
		return true
	end
	return ak.defs.rebounding and not is_prone() or false
end

local function get_ferocity()
	return affstrack and affstrack.ferocity or 0
end

-- Execute opens at/below this opponent HP%.
local BISECT_HP_THRESHOLD = 25

-- Opponent HP%. ASSESS stores precise current/max health on ak, but
-- ak.healthpercent is a plain number that the framework keeps current, so
-- prefer it: it sidesteps both the division and the inconsistent typing of
-- ak.currenthealth (sometimes a string, sometimes a number). Fall back to the
-- tonumber-coerced current/max ratio only when healthpercent isn't populated.
local function target_hp_pct()
	if not ak then
		return 100
	end
	local pct = tonumber(ak.healthpercent)
	if pct then
		return pct
	end
	local current = tonumber(ak.currenthealth) or 0
	local max = tonumber(ak.maxhealth) or 0
	if max <= 0 then
		return 100
	end
	return current / max * 100
end

local function can_bisect()
	return target_hp_pct() <= BISECT_HP_THRESHOLD
end

-- The target parries one limb at a time, and can't parry at all while
-- nauseous or prone -- which is why nausea is the top venom priority.

local function can_parry(limb)
	if has_aff("nausea") or is_prone() then
		return false
	end
	return targetparry == limb:gsub(" ", "")
end

local function limb_available(limb)
	return not can_parry(limb)
end

------------------------------------------
-- Limb damage
------------------------------------------

local function get_limb_damage(limb)
	if lb and lb[target] and lb[target].hits and lb[target].hits[limb] then
		return lb[target].hits[limb]
	end
	return 0
end

local function weapon_damage(weapon)
	return runewarden.snb.CONFIG.LIMB_DAMAGE[weapon] or 0
end

local function is_limb_broken(limb)
	return get_limb_damage(limb) >= 100
end

local function would_break_limb(limb, weapon)
	return not is_limb_broken(limb) and get_limb_damage(limb) + weapon_damage(weapon) >= 100
end

-- One more hit with this weapon would break the limb.

local function is_limb_prepped(limb, weapon)
	if weapon_damage(weapon) <= 0 then
		return false
	end
	return would_break_limb(limb, weapon)
end

-- Prep/break targeting, all against the LONGSWORD break threshold.

local function breakable(limb)
	return is_limb_prepped(limb, LONGSWORD) and limb_available(limb)
end

local function preppable(limb)
	return not is_limb_prepped(limb, LONGSWORD) and not is_limb_broken(limb) and limb_available(limb)
end

local function any_leg_broken()
	return is_limb_broken("left leg") or is_limb_broken("right leg")
end

-- Prep with broadsword unless that would overshoot and break early.

local function select_prep_weapon(limb)
	if would_break_limb(limb, BROADSWORD) then
		return LONGSWORD
	end
	return BROADSWORD
end

------------------------------------------
-- Venom / shield selection
------------------------------------------

-- Priority matcher for the selectors below. Rules are tried in order; the first whose
-- conditions all hold wins. A rule may require afflictions (need), forbid afflictions
-- (deny), and/or supply an extra predicate (when, which receives the call context).
-- Returns the matching rule's `result`, or `fallback` if none match.
local function first_match(rules, fallback, ctx)
	for _, rule in ipairs(rules) do
		local ok = true
		if rule.need then
			for _, aff in ipairs(rule.need) do
				if not has_aff(aff) then
					ok = false
					break
				end
			end
		end
		if ok and rule.deny then
			for _, aff in ipairs(rule.deny) do
				if has_aff(aff) then
					ok = false
					break
				end
			end
		end
		if ok and rule.when and not rule.when(ctx) then
			ok = false
		end
		if ok then
			return rule.result
		end
	end
	return fallback
end

local function softlock_mode()
	return runewarden.snb.CONFIG.VENOM_STRATEGY ~= "limblock"
end

-- Venom cascade, ported from 026_SNB.lua snbsoftlock()/snblimblock(): build toward a
-- softlock (asthma/slickness/anorexia/impatience/weariness), topping out with voyria.
-- Order is priority order. The aconite rule is softlock-only (snblimblock omits it).
local VENOM_RULES = {
	{ result = "voyria", need = { "slickness", "asthma", "impatience", "anorexia", "weariness", "voyria" } },
	{ result = "eurypteria", need = { "slickness", "asthma", "impatience", "anorexia", "weariness" } },
	{ result = "eurypteria", need = { "slickness", "asthma", "anorexia", "weariness" } },
	{ result = "eurypteria", need = { "anorexia", "stupidity" } },
	{
		result = "aconite",
		need = { "anorexia" },
		when = softlock_mode,
	},
	{ result = "slike", need = { "slickness", "asthma" } },
	{
		result = "gecko",
		need = { "asthma" },
		deny = { "slickness" },
	},
	{
		result = "kalmia",
		need = { "weariness", "clumsiness" },
		deny = { "asthma" },
	},
	{
		result = "xentio",
		need = { "weariness" },
		deny = { "clumsiness" },
	},
	{ result = "vernalius", deny = { "weariness" } },
}

local function select_venom()
	-- darkshade is the defensive fallback: unreachable with the rules above, but it
	-- keeps select_venom from ever returning nil if the rules change.
	return first_match(VENOM_RULES, "darkshade")
end

-- The genuine SHIELDSTRIKE ability: a separate ferocity-4 stun spent alongside the
-- combination (NOT the SMASH direction; 026_SNB.lua has no SHIELDSTRIKE logic of its
-- own). No sensitivity -> MID; else stupidity -> LOW; else HIGH.
local SHIELDSTRIKE_RULES = {
	{ result = "MID", deny = { "sensitivity" } },
	{ result = "LOW", need = { "stupidity" } },
}

local function select_shieldstrike()
	return first_match(SHIELDSTRIKE_RULES, "HIGH")
end

-- SMASH direction, ported 1:1 from 026_SNB.lua shieldstrike() -- which, despite its
-- name, sets the `smash <dir>` target, NOT the SHIELDSTRIKE ability (see
-- SHIELDSTRIKE_RULES). `when` predicates receive the venom delivered this turn (nil
-- for RAZE). The curare-gated SMASH LOW is reachable only when the venom is curare,
-- which select_venom never emits today (so it is currently inert) -- kept for fidelity
-- since it is not provably dead. Fallback is SMASH HIGH.
local SMASH_RULES = {
	{ result = "SMASH HIGH", need = { "slickness", "asthma" } },
	{ result = "SMASH HIGH", need = { "anorexia" } },
	{
		result = "SMASH HIGH",
		when = function(venom)
			return venom == "slike"
		end,
	},
	{ result = "SMASH HIGH", need = { "prone" } },
	{ result = "SMASH HIGH", need = { "paralysis" } },
	{ result = "SMASH HIGH", need = { "slickness" } },
	{
		result = "SMASH MID",
		when = function(venom)
			return venom ~= "curare"
		end,
	},
	{ result = "SMASH LOW", deny = { "clumsiness" } },
}

local function select_shield_hit(venom)
	return first_match(SMASH_RULES, "SMASH HIGH", venom)
end

------------------------------------------
-- Command building
------------------------------------------

local function shieldstrike_command(strike)
	return string.format("SHIELDSTRIKE %s %s", target, strike)
end

-- At ferocity 4, spend it on a shieldstrike alongside the combination.
-- HIGH/MID lead the combo; LOW trails it.

local function with_strike(command)
	if get_ferocity() ~= 4 then
		return { command }
	end
	local strike = select_shieldstrike()
	if strike == "LOW" then
		return { command, shieldstrike_command(strike) }
	end
	return { shieldstrike_command(strike), command }
end

-- Returns: a list of commands, and the weapon to wield for them.

local function select_commands()
	local venom = select_venom()

	local function raze()
		-- RAZE carries no venom, so the smash picks purely on target state (nil).
		local cmd = string.format("COMBINATION %s RAZE %s", target, select_shield_hit(nil))
		return with_strike(cmd), BROADSWORD
	end

	-- Only SLICE is reflected by rebounding, so when they're shielded we strip it
	-- instead of slicing into it. DISEMBOWEL / BISECT / IMPALE don't route through
	-- here, so they're never blocked by rebounding.

	local function slice(limb, shield_hit, weapon)
		if slice_blocked() then
			return raze()
		end
		shield_hit = shield_hit or select_shield_hit(venom)
		local cmd
		if limb then
			cmd = string.format("COMBINATION %s SLICE %s %s %s", target, limb, venom, shield_hit)
		else
			-- Untargeted slice can't be parried; good for forcing venom/shield through.
			cmd = string.format("COMBINATION %s SLICE %s %s", target, venom, shield_hit)
		end
		return with_strike(cmd), weapon or LONGSWORD
	end

	-- A prepared leg break only fires at ferocity 4: stun with SHIELDSTRIKE HIGH,
	-- then break + trip. Still a SLICE, so raze first if shielded.

	local function break_leg(limb)
		if slice_blocked() then
			return raze()
		end
		local cmd = string.format("COMBINATION %s SLICE %s %s TRIP", target, limb, venom)
		return { shieldstrike_command("HIGH"), cmd }, LONGSWORD
	end

	-- Already impaled: finish. DISEMBOWEL ignores rebounding, so it goes first.
	if is_impaled() then
		return { "DISEMBOWEL" }, LONGSWORD
	end
	-- Opportunistic execute; broadsword for max initial damage. Ignores rebounding.
	if can_bisect() then
		return { string.format("BISECT %s %s", target, venom) }, BROADSWORD
	end
	-- Prone with a broken leg: the kill window is open.
	-- Break the torso if it's prepped, otherwise impale + club.
	if is_prone() and (any_leg_broken() or is_limb_broken("torso")) then
		if is_limb_prepped("torso", LONGSWORD) then
			return slice("TORSO", nil, LONGSWORD)
		end
		local impale = { string.format("COMBINATION %s IMPALE CLUB", target) }
		if not have_fury() then
			table.insert(impale, "FURY ON")
		end
		return impale, BROADSWORD
	end
	-- Torso prepped: break a prepared leg (tripping them), else prep a leg.
	if is_limb_prepped("torso", LONGSWORD) then
		if breakable("left leg") and get_ferocity() == 4 then
			return break_leg("LEFT LEG")
		end
		if breakable("right leg") and get_ferocity() == 4 then
			return break_leg("RIGHT LEG")
		end
		if preppable("left leg") then
			return slice("LEFT LEG", nil, select_prep_weapon("left leg"))
		end
		if preppable("right leg") then
			return slice("RIGHT LEG", nil, select_prep_weapon("right leg"))
		end
		-- Nothing targetable: push venom with the longsword.
		return slice(nil, nil, LONGSWORD)
	end
	-- Build the setup: torso prepped + one leg prepped.
	if preppable("torso") then
		return slice("TORSO", nil, select_prep_weapon("torso"))
	end
	if preppable("left leg") then
		return slice("LEFT LEG", nil, select_prep_weapon("left leg"))
	end
	if preppable("right leg") then
		return slice("RIGHT LEG", nil, select_prep_weapon("right leg"))
	end
	-- Nothing targetable: push venom with the longsword.
	return slice(nil, nil, LONGSWORD)
end

------------------------------------------
-- Dispatch
------------------------------------------

local function send_commands(cmd_table)
	local cmd_string = table.concat(cmd_table, "/"):gsub("/+", "/")
	send(string.format("SETALIAS SNBATK %s", cmd_string))
	send("QUEUE ADDCLEARFULL FREE SNBATK")
end

function runewarden.snb.dispatch()
	boxEcho.send("FIRE")
	local commands, weapon = select_commands()
	local out = {}
	if not runewarden.snb.state.falcon_tracking then
		table.insert(out, string.format("FALCON TRACK %s", target))
		runewarden.snb.state.falcon_tracking = true
	end
	if not runewarden.snb.state.falcon_slaying then
		table.insert(out, string.format("FALCON SLAY %s", target))
		runewarden.snb.state.falcon_slaying = true
	end
	table.insert(out, "FALCON REPORT")
	table.insert(out, string.format("WIELD %s %s", weapon, SHIELD))
	table.insert(out, string.format("EMPOWER PRIORITY SET %s", runewarden.snb.CONFIG.EMPOWER_PRIO_SET))
	for _, cmd in ipairs(commands) do
		table.insert(out, cmd)
	end
	-- Fury rides the impale window: select_commands turns it ON with the IMPALE,
	-- so only turn it OFF once the impale is gone and we aren't impaling again this
	-- turn -- otherwise FURY ON and FURY OFF could be queued together.
	local finishing = is_impaled()
	for _, cmd in ipairs(commands) do
		if cmd:find("IMPALE", 1, true) then
			finishing = true
			break
		end
	end
	if have_fury() and not finishing then
		table.insert(out, "FURY OFF")
	end
	if not ak.engaged then
		table.insert(out, string.format("ENGAGE %s", target))
	end
	table.insert(out, "ASSESS")
	send_commands(out)
end

-- Queueing / lag reduction (just-in-time dispatch). Two hooks you wire up in
-- Mudlet by hand drive this (see MUDLET_SETUP.md): the `zz` alias arms the
-- system, and the "Balance used" trigger schedules the actual fire on balance
-- return. Pressing the button is what lets anything fire -- if you don't press
-- it, the scheduled timer expires harmlessly. This keeps decisions as late as
-- possible (don't attack into rebounding) and prevents going full-auto.
--
-- Todo: Don't fuck yourself with eq.

-- Offensive trigger (combat API). `opts` is accepted for contract uniformity but
-- unused -- SnB has no modes (venom strategy is CONFIG). The `zz` alias calls
-- combat.arm(); a back-compat `arm_next_bal` alias is set at the bottom.
function runewarden.snb.arm(opts)
	-- Already on bal/eq: skip the timer and hit them now.
	if have_eqbal() then
		runewarden.snb.state.next_bal_armed = false
		runewarden.snb.dispatch()
		return
	end
	runewarden.snb.state.next_bal_armed = true
	boxEcho.send("ARMED")
end

-- Balance-used trigger handler -- call this from the "Balance used" trigger,
-- passing the captured recovery interval in seconds. Arms a tempTimer for
-- (interval - latency); if the button armed us, the timer dispatches the instant
-- balance returns, so the combo is built from CURRENT state. If we weren't
-- armed, the timer expires harmlessly.
function runewarden.snb.onBalanceUsed(interval)
	interval = tonumber(interval)
	if not interval then
		return
	end
	local prearm_interval = runewarden.snb.CONFIG.PREARM_INTERVAL or getNetworkLatency()
	local timer_interval = math.max(0, interval - prearm_interval)
	runewarden.snb.state.next_bal_timer = tempTimer(timer_interval, function()
		if runewarden.snb.state.next_bal_armed then
			runewarden.snb.state.next_bal_armed = false
			runewarden.snb.dispatch()
		end
	end)
end

function runewarden.snb.reset()
	-- Drop fury on teardown so it doesn't linger after a fight ends.
	if have_fury() then
		send("FURY OFF")
	end
	runewarden.snb.state =
		{ next_bal_timer = nil, next_bal_armed = false, falcon_tracking = false, falcon_slaying = false }
	boxEcho.send("System reset.")
end

-- =============================================================
-- Combat module API. SnB implements the standard combat contract directly on its
-- own namespace (see ports/legacy_ak/utility/COMBAT_FRAMEWORK.md); registering
-- hands this module table to the framework. The onTarget/onClearTarget bodies are
-- a verbatim port of the old Runewarden/SnB branch in utility/target.lua. (arm,
-- onBalanceUsed and reset are defined above as the module's real entry points.)
-- =============================================================
runewarden.snb.id = "runewarden.snb"
runewarden.snb.jitBalance = true

-- New valid target: soft reset, ask the falcon to report, set parry.
function runewarden.snb.onTarget(name)
	runewarden.snb.reset()
	send("FALCON REPORT")
	send("parry " .. (currentparry or "head"), false)
end

-- Target cleared (still SnB): stop pressuring, recall the falcon.
function runewarden.snb.onClearTarget()
	runewarden.snb.reset()
	send("DISENGAGE")
	send("FURY OFF")
	send("FALCON RECALL")
end

-- Switched away from SnB entirely: same teardown as clearing the target.
function runewarden.snb.deactivate()
	runewarden.snb.onClearTarget()
end

-- Back-compat aliases for the existing hand-wired Mudlet `zz` alias and "Balance
-- used" trigger. Remove once they call combat.arm() / combat.onBalanceUsed().
runewarden.snb.arm_next_bal = runewarden.snb.arm
runewarden.snb.on_balance_used = runewarden.snb.onBalanceUsed

-- Register with the framework. Load-order-safe: defers if the core isn't loaded.
do
	local function register()
		if combat and combat.register then
			combat.register(runewarden.snb)
		end
	end
	if combat and combat.register then
		register()
	else
		tempTimer(0, register)
	end
end
