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
    AFF_THRESHOLD = 0.5,
    DEFAULT_MODE = "ONELEGHEAD",
    THORNREND_LIMB_DAMAGE = 22.0,
    PREARM_INTERVAL = nil,
    PREP_ORDER = {
        ONELEG = { "left leg" },
        ONELEGHEAD = { "left leg", "head" },
        TWOLEG = { "left leg", "right leg" },
        TWOLEGHEAD = { "left leg", "right leg", "head" }
    },
    REQUIRED_AP = {
        ONELEG = 28,
        ONELEGHEAD = 28,
        TWOLEG = 56,
        TWOLEGHEAD = 56,
    }
}

sylvan.CONFIG.COMBO_COST = 28
sylvan.CONFIG.SEAL_AFFS = { anorexia = true, slickness = true }
sylvan.CONFIG.LOCK_AFFS = { "anorexia", "slickness", "asthma", "paralysis", "weariness" }
sylvan.CONFIG.BUILD_SYNCH = { "STATIC", "CYCLONE" }

sylvan.CONFIG.COMMIT_LATCH = 6

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

-- Alphabetical for now, I'll reorder these based on priority later.
sylvan.CONFIG.WW_PRIO = {
    "clumsiness",
    "confusion",
    "dizziness",
    "epilepsy",
    "healthleech",
    "impatience",
    "paralysis",
    "sensitivity",
    "transfixed",
    "vertigo",
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

local function has_aff(aff)
    return ((affstrack and affstrack.score and affstrack.score[aff]) or 0) >= sylvan.CONFIG.AFF_THRESHOLD
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
    for _, limb in ipairs(mode_limbs()) do
        if needs_prep(limb) then
            return limb
        end
    end

    return nil
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

local function has_shield()
    return ak and ak.defs and ak.defs.shield
end

local function get_ap()
    return ak and ak.ae or 0
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
    return seal_present() and not mode_has_head() and #mode_legs() == 1
end

local function get_next_propagation_plant_for_herb_aff()
    for _, herb_aff in ipairs(sylvan.CONFIG.HERB_PRIO) do
        if not sylvan.CONFIG.SEAL_AFFS[herb_aff] then
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

local function get_next_lock_venom()
    for _, aff in ipairs(sylvan.CONFIG.LOCK_AFFS) do
        if not has_aff(aff) then
            local venom = sylvan.DATA.AFFS.VENOM[aff]
            if venom then
                return venom, aff
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

local function seal_rides(limb, breaking)
    if not breaking then
        return false
    end
    if limb == "head" then
        return true
    end
    return not mode_has_head() and #mode_legs() == 1
end

local function thornrend(cmds, limb, breaking)
    local venom, plant

    if seal_rides(limb, breaking) then
        venom = sylvan.DATA.AFFS.VENOM.anorexia
        plant = sylvan.DATA.AFFS.PROPAGATION.slickness
    elseif limb then
        if breaking then
            plant = "LOBELIA"
        else
            plant = get_next_propagation_plant_for_herb_aff()
        end
        venom = get_next_venom_for_herb_aff()
    else
        local prop_aff
        plant, prop_aff = get_next_propagation_plant_for_herb_aff()
        venom = get_next_venom_for_herb_aff(prop_aff)
    end

    table.insert(cmds, string.format("THORNREND %s %s %s %s", target, venom or "", limb or "", plant or ""))

    if breaking and limb and limb ~= "head" then
        table.insert(cmds, "SWING QUARTERSTAFF")
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
    if not ak.disturbed then
        table.insert(cmds, "CAST DISTURB")
        return send_commands(cmds)
    end

    if ak.feedback ~= target then
        table.insert(cmds, "CAST FEEDBACK AT " .. target)
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
    local n = #list
    if n == 0 then
        return nil
    end

    local owed = math.floor(get_ap() / sylvan.CONFIG.COMBO_COST)
    if owed > n then
        owed = n
    end

    local fired = n - owed
    if fired >= n then
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
    for _, leg in ipairs(mode_legs()) do
        if not is_limb_broken(leg) then
            latch_commit() -- breaking a leg commits us for COMMIT_LATCH seconds
            return thornrend(cmds, leg, true)
        end
    end

    local overcharge = get_next_overcharge()
    if overcharge then
        if not ak.disturbed then
            table.insert(cmds, "CAST DISTURB")
            return send_commands(cmds)
        end
        if ak.feedback ~= target then
            table.insert(cmds, "CAST FEEDBACK AT " .. target)
        end
        table.insert(cmds, "OVERCHARGE " .. overcharge)
        return send_commands(cmds)
    end

    if mode_has_head() and not is_limb_broken("head") then
        return thornrend(cmds, "head", true)
    end

    local venom = get_next_lock_venom()
    if venom then
        local plant = get_next_propagation_plant_for_herb_aff()
        table.insert(cmds, string.format("THORNREND %s %s  %s", target, venom, plant or ""))
        return send_commands(cmds)
    end

    return thornrend(cmds, nil, false)
end

function sylvan.dispatch(mode)
    if mode then
        sylvan.state.mode = mode
    end

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
    if get_ap() >= 40 and get_shockwave_aff_count() >= 3 and tonumber(ak.currenthealth) <= 5000 then
        table.insert(cmds, "CAST SHOCKWAVE AT " .. target)
        return send_commands(cmds)
    end

    if committed() then
        return do_execute(cmds)
    end

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
    if mode then
        sylvan.state.mode = mode
    end

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
end

function sylvan.debug_snapshot()
    local phase
    if has_shield() then
        phase = "INTERRUPT/shield"
    elseif get_ap() >= 40 and get_shockwave_aff_count() >= 3 and tonumber(ak and ak.currenthealth or 0) <= 5000 then
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
        }
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
        next_prep = get_next_limb_to_prep(),
        next_overcharge = get_next_overcharge(),
        shockwave_affs = get_shockwave_aff_count(),
    }
end

-- 1 leg / 1 leg + head logic
-- Use thornrend to prep a single leg (and head, optionally). Focus on herb afflictions via venoms and propagation. Prioritize propagation for affliction selection, choose non-duplicate venom after.
-- CAST DISTURB if not ak.disturbed
-- CAST FEEDBACK if ak.feedback ~= target
-- Build AP via SYNCH, follow affliction priority for this phase.
-- When AP >= 28:
--   1. THORNREND leg, herb affliction via venom, LOBELIA (or other focus affliction) via propagation / SWING QUARTERSTAFF on same balance for prone
--   2. OVERCHARGE STATIC CYCLONE
--   3. THORNREND head, anorexia + slickness
--   4. SYNCH/THORNREND HEAD, whatever is needed to complete lock afflictions (or drive low-confidence lock affs to 100) - assume weariness for dev, add class selector later
-- OR... Check for Shockwave aff buildup and blow them the fuck up if I can



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
