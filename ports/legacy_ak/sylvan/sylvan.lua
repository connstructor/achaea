--- Sylvan Combat Module
--- by Tannivh (coding) and Kiryn (combat logic)
---
--- Global environment:
--- - `target`: the current target of the player.
--- - `ak`: the current state of the player's character, provided by the AK package.
--- - `affstrack`: the current affliction tracking data, provided by the AK package.
--- - `lb`: the current limb-breaking tracking data, provided by the Limb package.

sylvan = sylvan or {}

sylvan.CONFIG = sylvan.CONFIG or {
    AFF_THRESHOLD = 30, -- affstrack.score is AK 0-100 confidence (100 = fresh apply)
    DEFAULT_MODE = "ONELEGHEAD",
    THORNREND_LIMB_DAMAGE = 22.0,
    PREARM_INTERVAL = nil,
    PREP_ORDER = {
        ONELEG = { "left leg" },
        ONELEGHEAD = { "left leg", "head" },
        TWOLEG = { "left leg", "right leg" },
        TWOLEGHEAD = { "left leg", "right leg", "head" }
    },
    -- 40 = overcharge cost (28) + margin that keeps the shockwave option (40) open.
    REQUIRED_AP = {
        ONELEG = 40,
        ONELEGHEAD = 40,
        TWOLEG = 56,
        TWOLEGHEAD = 56,
    }
}

sylvan.CONFIG.COMBO_COST = 28
sylvan.CONFIG.SEAL_AFFS = { anorexia = true, slickness = true }
-- Lock confirmation set (steps 8-9): driven to score 100. Paralysis is kept up separately.
sylvan.CONFIG.LOCK_AFFS = { "asthma", "slickness", "anorexia", "impatience" }
sylvan.CONFIG.BUILD_SYNCH = { "STATIC", "CYCLONE" }

sylvan.CONFIG.COMMIT_LATCH = 6

sylvan.CONFIG.WEAPON = "QUARTERSTAFF"

sylvan.CONFIG.SHOCKWAVE_AP = 40
sylvan.CONFIG.SHOCKWAVE_MIN_AFFS = 3
sylvan.CONFIG.SHOCKWAVE_MAX_HEALTH = 5000

-- Venom prio for the first TWOLEG break: affs the target must eat kelp to cure.
sylvan.CONFIG.KELP_PRIO = { "asthma", "clumsiness", "weariness" }

sylvan.CONFIG.HERB_PRIO = {
    "paralysis",
    "clumsiness",
    "weariness",
    "sensitivity",
    "asthma",
    "addiction",
    "darkshade",
    "healthleech",
    "lethargy",
    "nausea",
    "scytherus"
}

sylvan.CONFIG.FOCUS_PRIO = {
    "dizziness",
    "epilepsy",
    "vertigo",
    "stupidity",
    "recklessness",
    "masochism",
    "confusion",
    "anorexia",
}

sylvan.CONFIG.WW_PRIO = {
    "paralysis",
    "clumsiness",
    "healthleech",
    "dizziness",
    "epilepsy",
    "sensitivity",
}

sylvan.DATA = sylvan.DATA or {}

sylvan.DATA.AFFS = sylvan.DATA.AFFS or {}

sylvan.DATA.AFFS.VENOM = {
    addiction = "VARDRAX",
    anorexia = "SLIKE",
    asthma = "KALMIA",
    clumsiness = "XENTIO",
    darkshade = "DARKSHADE",
    disloyalty = "MONKSHOOD",
    dizziness = "LARKSPUR",
    nausea = "EUPHORBIA",
    paralysis = "CURARE",
    recklessness = "EURYPTERIA",
    scytherus = "SCYTHERUS",
    sensitivity = "PREFARAR",
    shyness = "DIGITALIS",
    sleep = "DELPHINIUM",
    slickness = "GECKO",
    stupidity = "ACONITE",
    voyria = "VOYRIA",
    weariness = "VERNALIUS",
}

sylvan.DATA.AFFS.PROPAGATION = {
    asleep = "KOLA",
    dizziness = "ELM",
    epilepsy = "GOLDENSEAL",
    healthleech = "KELP",
    sensitivity = "HAWTHORN",
    slickness = "VALERIAN",
    vertigo = "LOBELIA",
    weariness = "BELLWORT",
}

sylvan.DATA.AFFS.WEATHERWEAVING = {
    clumsiness = {
        { spell = "HAILSTONE", avoids = { "epilepsy" } },
    },
    confusion = {
        { spell = "WATERSPOUT" }
    },
    dizziness = {
        { spell = "CYCLONE" },
        { spell = "WATERSPOUT", needs = { "confusion" } }
    },
    epilepsy = {
        { spell = "HAILSTONE", needs = { "clumsiness" } }
    },
    healthleech = {
        { spell = "RAZORWIND" }
    },
    impatience = {
        { spell = "CYCLONE",   needs = { "dizziness" } },
        { spell = "HAILSTONE", needs = { "epilepsy" } },
    },
    paralysis = {
        { spell = "STATIC" }
    },
    sensitivity = {
        { spell = "THUNDERCLAP" }
    },
    transfixed = {
        { spell = "FLASH" }
    },
    vertigo = {
        { spell = "WATERSPOUT", needs = { "dizziness", "confusion" } }
    }
}

sylvan.DATA.AFFS.SHOCKWAVE = {
    "dizziness", "epilepsy", "healthleech", "impatience"
}

sylvan.DATA.OVERCHARGE = {
    ONELEG     = { "STATIC CYCLONE" },
    ONELEGHEAD = { "STATIC CYCLONE" },
    TWOLEG     = { "WATERSPOUT HAILSTONE", "STATIC CYCLONE" },
    TWOLEGHEAD = { "WATERSPOUT HAILSTONE", "STATIC CYCLONE" },
}

sylvan.state = sylvan.state or {
    mode = sylvan.CONFIG.DEFAULT_MODE
}

local function aff_score(aff)
    return (affstrack and affstrack.score and affstrack.score[aff]) or 0
end

local function has_aff(aff)
    return aff_score(aff) >= sylvan.CONFIG.AFF_THRESHOLD
end

-- targetparry format differs across AK versions ("left leg" vs "leftleg") — compare space-blind.
local function is_parried(limb)
    if type(targetparry) ~= "string" then
        return false
    end
    return targetparry:gsub("%s+", "") == limb:gsub("%s+", "")
end

local function limb_damage(limb)
    return (lb and lb[target] and lb[target].hits and lb[target].hits[limb]) or 0
end

local function is_limb_broken(limb)
    return limb_damage(limb) >= 100
end

local function is_limb_prepped(limb)
    local ls = limb_damage(limb)
    return ls < 100 and ls + sylvan.CONFIG.THORNREND_LIMB_DAMAGE >= 100
end

local function needs_prep(limb)
    local ls = limb_damage(limb)
    return ls < 100 and ls + sylvan.CONFIG.THORNREND_LIMB_DAMAGE < 100
end

local function mode_limbs()
    return sylvan.CONFIG.PREP_ORDER[sylvan.state.mode] or {}
end

local function mode_legs()
    local legs = {}
    for _, limb in ipairs(mode_limbs()) do
        if limb ~= "head" then
            legs[#legs + 1] = limb
        end
    end
    return legs
end

local function mode_has_head()
    for _, limb in ipairs(mode_limbs()) do
        if limb == "head" then
            return true
        end
    end
    return false
end

local function get_next_limb_to_prep()
    local fallback
    for _, limb in ipairs(mode_limbs()) do
        if needs_prep(limb) then
            if not is_parried(limb) then
                return limb
            end
            fallback = fallback or limb
        end
    end

    return fallback
end

local function all_prepped()
    return get_next_limb_to_prep() == nil
end

local function any_limb_broken()
    for _, limb in ipairs(mode_limbs()) do
        if is_limb_broken(limb) then
            return true
        end
    end
    return false
end

local function seal_present()
    for aff in pairs(sylvan.CONFIG.SEAL_AFFS) do
        if has_aff(aff) then
            return true
        end
    end
    return false
end

-- Both seal affs delivered (>= threshold): head strike done its job, re-seals go to torso.
local function seal_delivered()
    for aff in pairs(sylvan.CONFIG.SEAL_AFFS) do
        if not has_aff(aff) then
            return false
        end
    end
    return true
end

-- Both seal affs confirmed at full confidence.
local function seal_confirmed()
    for aff in pairs(sylvan.CONFIG.SEAL_AFFS) do
        if aff_score(aff) < 100 then
            return false
        end
    end
    return true
end

local function has_shield()
    return ak and ak.defs and ak.defs.shield
end

local function get_ap()
    return tonumber(ak and ak.ae) or 0
end

local function ap_gate()
    return sylvan.CONFIG.REQUIRED_AP[sylvan.state.mode] or 28
end

local function committed()
    if sylvan.state.commit_latch then
        return true
    end
    if any_limb_broken() then
        return true
    end
    if all_prepped() and get_ap() >= ap_gate() then
        return true
    end
    -- Seal affs on the target keep us locked into execute (any mode) until they cure.
    return seal_present()
end

local function get_next_propagation_plant_for_herb_aff(exclude)
    for _, herb_aff in ipairs(sylvan.CONFIG.HERB_PRIO) do
        if herb_aff ~= exclude and not sylvan.CONFIG.SEAL_AFFS[herb_aff] then
            local plant = sylvan.DATA.AFFS.PROPAGATION[herb_aff]
            if plant and not has_aff(herb_aff) then
                return plant, herb_aff
            end
        end
    end

    return nil
end

local function get_next_venom_for_herb_aff(exclude)
    for _, herb_aff in ipairs(sylvan.CONFIG.HERB_PRIO) do
        if herb_aff ~= exclude and not sylvan.CONFIG.SEAL_AFFS[herb_aff] then
            local venom = sylvan.DATA.AFFS.VENOM[herb_aff]
            if venom and not has_aff(herb_aff) then
                return venom, herb_aff
            end
        end
    end

    return nil
end

local function get_next_kelp_venom()
    for _, aff in ipairs(sylvan.CONFIG.KELP_PRIO) do
        if not has_aff(aff) then
            local venom = sylvan.DATA.AFFS.VENOM[aff]
            if venom then
                return venom, aff
            end
        end
    end

    return nil
end

local function get_next_focus_venom(exclude)
    for _, aff in ipairs(sylvan.CONFIG.FOCUS_PRIO) do
        if aff ~= exclude and not sylvan.CONFIG.SEAL_AFFS[aff] and not has_aff(aff) then
            local venom = sylvan.DATA.AFFS.VENOM[aff]
            if venom then
                return venom, aff
            end
        end
    end

    return nil
end

-- Prop slot for breaking strikes: LOBELIA by spec default, other focus affs as fallback.
local function get_next_focus_plant(exclude)
    if exclude ~= "vertigo" and not has_aff("vertigo") then
        return sylvan.DATA.AFFS.PROPAGATION.vertigo, "vertigo"
    end

    for _, aff in ipairs(sylvan.CONFIG.FOCUS_PRIO) do
        if aff ~= exclude and not sylvan.CONFIG.SEAL_AFFS[aff] and not has_aff(aff) then
            local plant = sylvan.DATA.AFFS.PROPAGATION[aff]
            if plant then
                return plant, aff
            end
        end
    end

    return nil
end

local function get_next_ww_spell(exclude_aff)
    for _, aff in ipairs(sylvan.CONFIG.WW_PRIO) do
        if aff ~= exclude_aff and not has_aff(aff) then
            for _, spell_data in ipairs(sylvan.DATA.AFFS.WEATHERWEAVING[aff] or {}) do
                local needs = spell_data.needs or {}
                local avoids = spell_data.avoids or {}

                local can_cast = true

                for _, need in ipairs(needs) do
                    if not has_aff(need) then
                        can_cast = false
                        break
                    end
                end

                for _, avoid in ipairs(avoids) do
                    if has_aff(avoid) then
                        can_cast = false
                        break
                    end
                end

                if can_cast then
                    return spell_data.spell, aff
                end
            end
        end
    end

    return nil
end

local function get_shockwave_aff_count()
    local count = 0

    for _, aff in ipairs(sylvan.DATA.AFFS.SHOCKWAVE) do
        if has_aff(aff) then
            count = count + 1
        end
    end

    return count
end

local function send_commands(cmds)
    local cmd_table = type(cmds) == "string" and { cmds } or cmds
    local cmd_string = table.concat(cmd_table, "/"):gsub("/+", "/")

    send("SETALIAS SYLATK " .. cmd_string)
    send("QUEUE ADDCLEARFULL FREE SYLATK")
end

local function pre_commands()
    local cmds = {}

    table.insert(cmds, "WIELD " .. (sylvan.CONFIG.WEAPON or "QUARTERSTAFF"))
    return cmds
end

-- Weatherweaving prerequisites. Returns true if the balance had to go to CAST DISTURB
-- (commands already sent); otherwise stacks FEEDBACK if needed and returns false.
local function ensure_weather(cmds)
    if not (ak and ak.disturbed) then
        table.insert(cmds, "CAST DISTURB")
        send_commands(cmds)
        return true
    end
    if ak.feedback ~= target then
        table.insert(cmds, "CAST FEEDBACK AT " .. target)
    end
    return false
end

-- Venom/prop pair for a breaking leg strike (the head seal-rides instead).
-- TWOLEG first break: kelp-cured venom + any herb prop. Second break: focus venom +
-- LOBELIA-first focus prop. Single-leg head modes: herb venom + LOBELIA-first focus prop.
local function break_recipe()
    local legs = mode_legs()
    local venom, venom_aff, plant

    if #legs >= 2 then
        local broken = 0
        for _, leg in ipairs(legs) do
            if is_limb_broken(leg) then
                broken = broken + 1
            end
        end

        if broken == 0 then
            venom, venom_aff = get_next_kelp_venom()
            if not venom then
                venom, venom_aff = get_next_venom_for_herb_aff()
            end
            plant = get_next_propagation_plant_for_herb_aff(venom_aff)
            return venom, plant
        end

        venom, venom_aff = get_next_focus_venom()
        if not venom then
            venom, venom_aff = get_next_venom_for_herb_aff()
        end
        plant = get_next_focus_plant(venom_aff) or get_next_propagation_plant_for_herb_aff(venom_aff)
        return venom, plant
    end

    venom, venom_aff = get_next_venom_for_herb_aff()
    plant = get_next_focus_plant(venom_aff) or get_next_propagation_plant_for_herb_aff(venom_aff)
    return venom, plant
end

local function thornrend(cmds, limb, breaking)
    local venom, plant

    if breaking and limb == "head" then
        venom = sylvan.DATA.AFFS.VENOM.anorexia
        plant = sylvan.DATA.AFFS.PROPAGATION.slickness
    elseif limb and breaking then
        venom, plant = break_recipe()
    else
        local prop_aff
        plant, prop_aff = get_next_propagation_plant_for_herb_aff()
        venom = get_next_venom_for_herb_aff(prop_aff)
    end

    -- The venom slot must never be empty: with later args present the server would
    -- misparse the limb/plant as the venom. CURARE re-stick is the harmless floor.
    venom = venom or get_next_focus_venom() or sylvan.DATA.AFFS.VENOM.paralysis

    local parts = { "THORNREND", target, venom }
    if limb then
        parts[#parts + 1] = limb
    end
    if plant then
        parts[#parts + 1] = plant
    end
    table.insert(cmds, table.concat(parts, " "))

    if breaking and limb and limb ~= "head" then
        table.insert(cmds, "SWEEP " .. (sylvan.CONFIG.WEAPON or "QUARTERSTAFF") .. " " .. target)
    end

    return send_commands(cmds)
end

local function do_prep(cmds)
    local limb = get_next_limb_to_prep()
    if not limb then
        return
    end

    return thornrend(cmds, limb, false)
end

local function do_build(cmds)
    if ensure_weather(cmds) then
        return
    end

    local first_spell, first_aff = get_next_ww_spell()
    local second_spell = get_next_ww_spell(first_aff)

    first_spell = first_spell or sylvan.CONFIG.BUILD_SYNCH[1]
    if not second_spell or second_spell == first_spell then
        second_spell = nil
        for _, spell in ipairs(sylvan.CONFIG.BUILD_SYNCH) do
            if spell ~= first_spell then
                second_spell = spell
                break
            end
        end
    end

    table.insert(cmds, string.format("SYNCHRONISE %s %s %s", first_spell, second_spell, target))
    return send_commands(cmds)
end

local function get_next_overcharge()
    local list = sylvan.DATA.OVERCHARGE[sylvan.state.mode] or {}
    local fired = sylvan.state.oc_fired or 0

    if fired >= #list then
        return nil
    end
    if get_ap() < sylvan.CONFIG.COMBO_COST then
        return nil
    end

    return list[fired + 1]
end

-- Set + refresh the commit latch (see CONFIG.COMMIT_LATCH). A self-clearing tempTimer
-- means the flag can never get stuck set the way a bare flag would.
local function latch_commit()
    sylvan.state.commit_latch = true
    if sylvan.state.commit_timer then
        killTimer(sylvan.state.commit_timer)
    end
    sylvan.state.commit_timer = tempTimer(sylvan.CONFIG.COMMIT_LATCH or 6, function()
        sylvan.state.commit_latch = false
        sylvan.state.commit_timer = nil
    end)
end

local function do_execute(cmds)
    -- Step 5: break window — prepped, unbroken legs while the AP bank is full.
    -- The prep + AP gates mean a restored (0%) leg can never hijack the lock.
    if get_ap() >= ap_gate() then
        local parried_leg
        for _, leg in ipairs(mode_legs()) do
            if not is_limb_broken(leg) and is_limb_prepped(leg) then
                if not is_parried(leg) then
                    latch_commit() -- the six-second break-window flag
                    return thornrend(cmds, leg, true)
                end
                parried_leg = parried_leg or leg
            end
        end
        if parried_leg then
            latch_commit()
            return thornrend(cmds, parried_leg, true)
        end
    end

    -- Step 6: banked overcharges for this mode, fired in sequence once each.
    local overcharge = get_next_overcharge()
    if overcharge then
        if ensure_weather(cmds) then
            return
        end
        sylvan.state.oc_fired = (sylvan.state.oc_fired or 0) + 1
        table.insert(cmds, "OVERCHARGE " .. overcharge)
        return send_commands(cmds)
    end

    -- Step 7: deliver the seal via the head in ANY mode (it only breaks if prepped;
    -- ONELEG simply never prepped it — the venom/propagation still land).
    if not seal_delivered() then
        return thornrend(cmds, "head", true)
    end

    -- Step 8: seal down but no AP — synchronise rebuilds AP while driving impatience
    -- (CYCLONE and HAILSTONE are both impatience routes), else paralysis + hinder.
    if get_ap() < sylvan.CONFIG.COMBO_COST then
        if ensure_weather(cmds) then
            return
        end
        if aff_score("impatience") < 100 then
            table.insert(cmds, "SYNCHRONISE CYCLONE HAILSTONE " .. target)
        else
            local spell = get_next_ww_spell("paralysis") or "CYCLONE"
            table.insert(cmds, string.format("SYNCHRONISE STATIC %s %s", spell, target))
        end
        return send_commands(cmds)
    end

    -- Step 9: confirm the lock set at full confidence. Overcharge covers
    -- impatience/asthma(/weariness); the torso re-seal covers slickness/anorexia.
    if aff_score("impatience") < 100 or aff_score("asthma") < 100 then
        if ensure_weather(cmds) then
            return
        end
        table.insert(cmds, "OVERCHARGE CYCLONE HAILSTONE")
        return send_commands(cmds)
    end

    if not seal_confirmed() then
        table.insert(cmds, string.format("THORNREND %s %s torso %s",
            target, sylvan.DATA.AFFS.VENOM.anorexia, sylvan.DATA.AFFS.PROPAGATION.slickness))
        return send_commands(cmds)
    end

    -- Step 10: lock holds — keep paralysis pinned, then stack class-block affs.
    if aff_score("paralysis") < 100 then
        local plant = get_next_propagation_plant_for_herb_aff("paralysis")
        local parts = { "THORNREND", target, sylvan.DATA.AFFS.VENOM.paralysis, "torso" }
        if plant then
            parts[#parts + 1] = plant
        end
        table.insert(cmds, table.concat(parts, " "))
        return send_commands(cmds)
    end

    return thornrend(cmds, "torso", false)
end

local function set_mode(mode)
    if not mode then
        return
    end
    mode = tostring(mode):upper()
    if sylvan.CONFIG.PREP_ORDER[mode] then
        sylvan.state.mode = mode
    else
        echo("\n[sylvan] unknown mode: " .. mode .. "\n")
    end
end

function sylvan.dispatch(mode)
    set_mode(mode)

    if not target or target == "" then
        return
    end

    local cmds = pre_commands()

    -- Cowardice is unbecoming.
    if has_shield() then
        table.insert(cmds, "CAST SHEAR AT " .. target)
        return send_commands(cmds)
    end

    -- So anyway, I started blasting.
    local hp = tonumber(ak and ak.currenthealth)
    if get_ap() >= sylvan.CONFIG.SHOCKWAVE_AP
        and get_shockwave_aff_count() >= sylvan.CONFIG.SHOCKWAVE_MIN_AFFS
        and hp and hp <= sylvan.CONFIG.SHOCKWAVE_MAX_HEALTH then
        table.insert(cmds, "CAST SHOCKWAVE AT " .. target)
        return send_commands(cmds)
    end

    if committed() then
        return do_execute(cmds)
    end

    sylvan.state.oc_fired = 0

    if not all_prepped() then
        return do_prep(cmds)
    end

    return do_build(cmds)
end

local function have_eqbal()
    return gmcp and gmcp.Char and gmcp.Char.Vitals
        and gmcp.Char.Vitals.bal == "1"
        and gmcp.Char.Vitals.eq == "1"
        or false
end

function sylvan.arm(mode)
    set_mode(mode)

    if have_eqbal() then
        sylvan.state.armed = false
        if sylvan.state.fire_timer then
            killTimer(sylvan.state.fire_timer)
            sylvan.state.fire_timer = nil
        end
        sylvan.dispatch()
        return
    end

    sylvan.state.armed = true
end

function sylvan.on_recover(interval)
    interval = tonumber(interval)
    if not interval then
        return
    end

    local lead = sylvan.CONFIG.PREARM_INTERVAL or (getNetworkLatency and getNetworkLatency()) or 0.1
    local wait = math.max(0, interval - lead)

    local current = sylvan.state.fire_timer
    local remaining = current and remainingTime(current) or -1
    if remaining >= wait then
        return
    end

    if current then
        killTimer(current)
    end

    sylvan.state.fire_timer = tempTimer(wait, function()
        sylvan.state.fire_timer = nil
        if sylvan.state.armed then
            sylvan.state.armed = false
            sylvan.dispatch()
        end
    end)
end

function sylvan.reset()
    if sylvan.state.fire_timer then
        killTimer(sylvan.state.fire_timer)
    end
    sylvan.state.fire_timer = nil
    sylvan.state.armed = false
    if sylvan.state.commit_timer then
        killTimer(sylvan.state.commit_timer)
    end
    sylvan.state.commit_timer = nil
    sylvan.state.commit_latch = false
    sylvan.state.oc_fired = 0
end

function sylvan.debug_snapshot()
    local hp = tonumber(ak and ak.currenthealth)
    local phase
    if has_shield() then
        phase = "INTERRUPT/shield"
    elseif get_ap() >= sylvan.CONFIG.SHOCKWAVE_AP
        and get_shockwave_aff_count() >= sylvan.CONFIG.SHOCKWAVE_MIN_AFFS
        and hp and hp <= sylvan.CONFIG.SHOCKWAVE_MAX_HEALTH then
        phase = "INTERRUPT/shockwave"
    elseif committed() then
        phase = "EXECUTE"
    elseif not all_prepped() then
        phase = "PREP"
    else
        phase = "BUILD"
    end

    local limbs = {}
    for _, limb in ipairs(mode_limbs()) do
        limbs[#limbs + 1] = {
            name = limb,
            dmg = limb_damage(limb),
            prepped = is_limb_prepped(limb),
            broken = is_limb_broken(limb),
            parried = is_parried(limb),
        }
    end

    local lock = { paralysis = aff_score("paralysis") }
    for _, aff in ipairs(sylvan.CONFIG.LOCK_AFFS) do
        lock[aff] = aff_score(aff)
    end

    return {
        mode = sylvan.state.mode,
        phase = phase,
        armed = sylvan.state.armed or false,
        ap = get_ap(),
        gate = ap_gate(),
        disturbed = (ak and ak.disturbed) or false,
        feedback = ak and ak.feedback or nil,
        shield = has_shield() and true or false,
        health = ak and ak.currenthealth,
        limbs = limbs,
        all_prepped = all_prepped(),
        committed = committed(),
        commit_latch = sylvan.state.commit_latch or false,
        any_broken = any_limb_broken(),
        seal_present = seal_present(),
        seal_delivered = seal_delivered(),
        seal_confirmed = seal_confirmed(),
        lock = lock,
        next_prep = get_next_limb_to_prep(),
        next_overcharge = get_next_overcharge(),
        oc_fired = sylvan.state.oc_fired or 0,
        shockwave_affs = get_shockwave_aff_count(),
        parried = (type(targetparry) == "string") and targetparry or nil,
    }
end

-- ONELEG / ONELEGHEAD state machine (Kiryn, 2026-06-10):
--  1. PREP leg (and head if ONELEGHEAD): thornrend, hindering/herb affs on both
--     slots, propagation prioritized, non-duplicate venom after.
--  2. CAST DISTURB once prepped.
--  3. BUILD AP via SYNCHRONISE until ae >= 40; CAST FEEDBACK rides the synch;
--     spell prio = CONFIG.WW_PRIO.
--  4. BREAK leg + SWEEP on the same balance (prone), LOBELIA prop, venom prio.
--     Sets the 6s commit latch. Breaks only fire while ae >= gate AND the leg is
--     prepped — a restored 0% leg can never hijack the lock.
--  5. OVERCHARGE STATIC CYCLONE (exactly; expected to grant focusextend).
--  6. THORNREND HEAD SLIKE VALERIAN in ANY mode (only breaks if prepped) until
--     both seal affs are delivered (>= threshold).
--  7. ae < 28: SYNCHRONISE CYCLONE HAILSTONE (both impatience routes) until
--     impatience is confirmed; otherwise SYNCHRONISE STATIC + next hinder spell.
--  8. ae >= 28: drive the lock set to 100 — impatience/asthma via OVERCHARGE
--     CYCLONE HAILSTONE (grants weariness too); slickness/anorexia via
--     THORNREND TORSO SLIKE VALERIAN.
--  9. Lock holds: keep paralysis at 100 (CURARE torso), then stack class-block
--     affs via generic torso thornrends.
-- At any point: shield -> CAST SHEAR; ae >= 40 + 3 shockwave affs + low hp ->
-- CAST SHOCKWAVE.



-- 2 leg / 2 leg + head logic
-- Use thornrend to prep both legs (and head). Focus on herb afflictions via venoms and propagation. Prioritize propagation for affliction selection, choose non-duplicate venom after.
-- CAST DISTURB if not ak.disturbed
-- CAST FEEDBACK if ak.feedback ~= target
-- Build AP via SYNCH, follow affliction priority for this phase.
-- When AP >= 56:
--   1. THORNREND first leg, prioritize kelp for venom, for prop any herb / SWING QUARTERSTAFF on same balance for prone
--   2. THORNREND second leg, any missing mental aff for venom, LOBELIA for prop
--   3. OVERCHARGE WATERSPOUT HAILSTONE
--   4. OVERCHARGE STATIC CYCLONE
--   5. THORNREND head, anorexia + slickness
--   6. Continue with SYNCH/THORNREND to seal lock.
-- OR... Check for Shockwave aff buildup and blow them the fuck up if I can


-- Port decisions (2026-06-10):
-- - affstrack.score is AK 0-100 confidence; AFF_THRESHOLD = 30 per sibling modules.
-- - committed() keepalive: seal_present() in ALL modes — the lock continues until the
--   seal affs cure, then falls back to prep. Latch covers the break->seal window.
-- - Breaks are double-gated (ae >= REQUIRED_AP and limb prepped), so execute never
--   flails at a restored limb; re-prep happens only after commitment drops.
-- - The seal never rides a leg: head thornrend (any mode) delivers it, torso
--   thornrend re-confirms it (step 8) — head = delivery, torso = reinforcement.
-- - Step-8 routing interpretation: OVERCHARGE CYCLONE HAILSTONE only for
--   impatience/asthma gaps; SLIKE/VALERIAN torso only for seal gaps. (The raw spec's
--   "any < 100 -> overcharge" would shadow the torso branch.)
-- - focusextend is expected from the banked overcharge but nothing routes on it —
--   its only source is already spent by the time it could be checked.
-- - TWOLEG/TWOLEGHEAD: stepwise re-spec pending. Breaks keep the kelp/focus recipes
--   (break 1: kelp-cured venom + herb prop; break 2: focus venom + LOBELIA prop),
--   gate stays 56, and they share the new seal/lock-confirmation pipeline.
-- - Overcharges tracked per commit cycle (state.oc_fired, AP-gated, reset when
--   commitment drops) so carried-over AP can't double-fire the same overcharge.
-- - Limb choice (prep + break) prefers unparried limbs via targetparry, space-blind.
-- - Thornrend args emitted as clean tokens, venom slot never empty (herb -> focus ->
--   CURARE floor) so the server can't read the limb/plant as a venom.
