-- Full-detail debug run: drives the REAL sylvan.dispatch through a modeled syl1h
-- (ONELEGHEAD) fight, printing the authoritative debug_snapshot + emitted action + the
-- modeled game response each tick, until the lock seals.
--   run: lua sys/sylvan/sylvan_debug.lua   (from repo root)
--
-- The dispatch decisions are REAL (sylvan.lua). The game's *responses* are MODELED here;
-- the modeled numbers are marked [MODEL] and are the things to confirm against live play:
--   THORNREND -> +22 to the targeted limb (CONFIG.THORNREND_LIMB_DAMAGE) and lands its
--               venom-aff + plant-aff.   break at 100.
--   SYNCHRONISE -> +SYNCH_YIELD AP and lands its two weatherweave affs.
--   OVERCHARGE  -> -COMBO_COST AP (instant) and lands its 2 spell affs + a bonus aff.
local SYNCH_YIELD = tonumber(arg and arg[2]) or 14 -- [MODEL] AP per SYNCH (override via arg[2])
local CAST_YIELD  = 7  -- [MODEL] AP for a lone CAST (fallback when only one WW aff is castable)
local OC_BONUS = {     -- [MODEL] bonus aff each overcharge combo lands (memory: CYCLONE->asthma, WATERSPOUT/HAILSTONE->weariness)
  ["STATIC CYCLONE"] = "asthma",
  ["WATERSPOUT HAILSTONE"] = "weariness",
}

-- ---- host stubs -------------------------------------------------------------
target = "Bob"
local last_atk
function send(s) local a = s:match("^SETALIAS SYLATK (.*)$"); if a then last_atk = a end end
-- Latch timer stubs. The callback never fires here (no time advances in a trace), so once a
-- leg break sets commit_latch it stays set for the rest of the run -- exactly the intended
-- "stay committed through execute" behavior.
function tempTimer(_, _) return 1 end
function killTimer(_) return true end

ak = { ae = 0, disturbed = false, feedback = nil, currenthealth = 6000, defs = { shield = false } }
affstrack = { score = {} }
lb = { [target] = { hits = {} } }

dofile("sys/sylvan/sylvan.lua")
local MODE = (arg and arg[1]) or "ONELEGHEAD"
sylvan.state.mode = MODE

-- ---- reverse lookups (built from the module's own DATA) ----------------------
local function invert(t) local r = {}; for k, v in pairs(t) do r[v] = r[v] or k end; return r end
local venom_aff = invert(sylvan.DATA.AFFS.VENOM)
local plant_aff = invert(sylvan.DATA.AFFS.PROPAGATION) -- includes LOBELIA->vertigo
local spell_aff = {} -- spell -> aff it lands cast unconditionally (prefer the no-needs entry)
for aff, list in pairs(sylvan.DATA.AFFS.WEATHERWEAVING) do
  for _, sd in ipairs(list) do
    if not spell_aff[sd.spell] or not sd.needs or #sd.needs == 0 then spell_aff[sd.spell] = aff end
  end
end
local COST = sylvan.CONFIG.COMBO_COST
local THRESH = sylvan.CONFIG.AFF_THRESHOLD
local function present(a) return a and (affstrack.score[a] or 0) >= THRESH end
-- Mirror get_next_ww_spell to recover which fresh aff the module *intended* a SYNCH spell
-- for (the emitted command only carries the spell name). nil = an AP-only re-cast.
local function intended_aff(spell, exclude)
  for _, aff in ipairs(sylvan.CONFIG.WW_PRIO) do
    if aff ~= exclude and not present(aff) then
      for _, sd in ipairs(sylvan.DATA.AFFS.WEATHERWEAVING[aff] or {}) do
        if sd.spell == spell then
          local ok = true
          for _, n in ipairs(sd.needs or {}) do if not present(n) then ok = false break end end
          for _, a in ipairs(sd.avoids or {}) do if present(a) then ok = false break end end
          if ok then return aff end
        end
      end
    end
  end
  return nil
end

-- ---- model the game's response to an emitted SYLATK -------------------------
local function add_aff(a) if a then affstrack.score[a] = 100 end end
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local effects -- string describing what the tick's action changed
local function model(atk)
  local notes = {}
  for cmd in atk:gmatch("[^/]+") do
    cmd = trim(cmd)
    if cmd:match("^THORNREND ") then
      local body = cmd:gsub("^THORNREND %S+%s*", "")
      local limb
      for _, L in ipairs({ "left leg", "right leg", "head" }) do
        if body:find(L, 1, true) then limb = L; break end
      end
      local venom, plant
      if limb then
        local pre, post = body:match("^(.-)%s*" .. limb .. "%s*(.*)$")
        venom, plant = trim(pre), trim(post)
      else
        local toks = {}; for t in body:gmatch("%S+") do toks[#toks + 1] = t end
        venom, plant = toks[1], toks[2]
      end
      if limb and limb ~= "" then
        local before = lb[target].hits[limb] or 0
        lb[target].hits[limb] = before + sylvan.CONFIG.THORNREND_LIMB_DAMAGE
        notes[#notes + 1] = string.format("%s %d->%d", limb, before, lb[target].hits[limb])
      end
      local av, ap_ = venom_aff[venom or ""], plant_aff[plant or ""]
      if av then add_aff(av); notes[#notes + 1] = "+" .. av .. "(" .. venom .. ")" end
      if ap_ then add_aff(ap_); notes[#notes + 1] = "+" .. ap_ .. "(" .. plant .. ")" end
    elseif cmd == "SWING QUARTERSTAFF" then
      add_aff("prone"); notes[#notes + 1] = "+prone(SWING)"
    elseif cmd == "CAST DISTURB" then
      ak.disturbed = true; notes[#notes + 1] = "clouds up"
    elseif cmd:match("^CAST FEEDBACK AT") then
      ak.feedback = target; notes[#notes + 1] = "conduit->" .. target
    elseif cmd:match("^CAST SHEAR AT") then
      ak.defs.shield = false; notes[#notes + 1] = "shield stripped"
    elseif cmd:match("^CAST SHOCKWAVE AT") then
      notes[#notes + 1] = "*** SHOCKWAVE -- KILL ***"
    elseif cmd:match("^SYNCHRONISE ") then
      local s1, s2 = cmd:match("^SYNCHRONISE (%S+) (%S+)")
      ak.ae = ak.ae + SYNCH_YIELD
      local a1 = intended_aff(s1, nil)
      local a2 = intended_aff(s2, a1)
      add_aff(a1); add_aff(a2)
      local landed = {}
      if a1 then landed[#landed + 1] = a1 end
      if a2 then landed[#landed + 1] = a2 end
      notes[#notes + 1] = string.format("AP +%d->%d%s", SYNCH_YIELD, ak.ae,
        #landed > 0 and (", +" .. table.concat(landed, " +")) or " (AP only -- pool dry)")
    elseif cmd:match("^OVERCHARGE ") then
      local combo = cmd:match("^OVERCHARGE (.+)$")
      local s1, s2 = combo:match("^(%S+) (%S+)")
      ak.ae = math.max(0, ak.ae - COST)
      add_aff(spell_aff[s1]); add_aff(spell_aff[s2]); add_aff(OC_BONUS[combo])
      notes[#notes + 1] = string.format("AP -%d->%d, +%s +%s +%s[bonus]", COST, ak.ae,
        spell_aff[s1] or "?", spell_aff[s2] or "?", OC_BONUS[combo] or "?")
    elseif cmd:match("^CAST %u+ AT") then
      local sp = cmd:match("^CAST (%u+) AT")
      ak.ae = ak.ae + CAST_YIELD; add_aff(spell_aff[sp])
      notes[#notes + 1] = string.format("AP +%d->%d, +%s", CAST_YIELD, ak.ae, spell_aff[sp] or "?")
    end
  end
  effects = #notes > 0 and table.concat(notes, ", ") or "(no state change)"
end

-- ---- "why" string from the snapshot (mirrors dispatch's branch order) -------
local function why(s)
  if s.phase == "INTERRUPT/shield" then return "shield up -> strip it first" end
  if s.phase == "INTERRUPT/shockwave" then return "AP>=40 & >=3 shockwave affs & hp<=5000 -> blast" end
  if s.phase == "PREP" then
    return "not committed; " .. s.next_prep .. " still needs prep -> THORNREND it (pressure)"
  end
  if s.phase == "BUILD" then
    if not s.disturbed then return "all prepped, AP<gate; no clouds -> DISTURB" end
    if s.feedback ~= target then return "all prepped, AP<gate; conduit down -> FEEDBACK + SYNCH" end
    return string.format("all prepped, AP %d/%d -> SYNCH to bank", s.ap, s.gate)
  end
  -- EXECUTE
  local commit = s.any_broken and "a limb is broken" or
      (s.seal_present and "seal aff up") or
      string.format("all prepped & AP %d>=%d", s.ap, s.gate)
  for _, l in ipairs(s.limbs) do
    if l.name ~= "head" and not l.broken then
      return "committed(" .. commit .. "); leg " .. l.name .. " not broken -> break it + SWING"
    end
  end
  if s.next_overcharge then
    return string.format("committed(%s); legs broken, AP %d -> owed floor(%d/%d)=%d -> OVERCHARGE %s",
      commit, s.ap, s.ap, COST, math.floor(s.ap / COST), s.next_overcharge)
  end
  for _, l in ipairs(s.limbs) do
    if l.name == "head" and not l.broken then
      return "committed(" .. commit .. "); overcharges done, head not broken -> THORNREND head (SEAL)"
    end
  end
  return "committed(" .. commit .. "); breaks+overcharges done -> push next lock aff (blank-limb)"
end

-- ---- pretty print -----------------------------------------------------------
local function fmt_limbs(s)
  local out = {}
  for _, l in ipairs(s.limbs) do
    local tag = l.broken and "BROKEN" or (l.prepped and "prepped" or "raw")
    out[#out + 1] = string.format("%s=%d(%s)", l.name, l.dmg, tag)
  end
  return table.concat(out, "  ")
end

local function lock_done()
  for _, a in ipairs(sylvan.CONFIG.LOCK_AFFS) do
    if (affstrack.score[a] or 0) < sylvan.CONFIG.AFF_THRESHOLD then return false end
  end
  return true
end

print("============================================================")
print(" debug run -- mode " .. MODE .. " (SYNCH_YIELD=" .. SYNCH_YIELD .. ") -- gate " ..
  sylvan.CONFIG.REQUIRED_AP[MODE] .. ", overcharges {" ..
  table.concat(sylvan.DATA.OVERCHARGE[MODE], " | ") .. "}")
print("============================================================")

local stall = 0
for tick = 1, 40 do
  local s = sylvan.debug_snapshot()
  local affs = {}
  for a in pairs(affstrack.score) do affs[#affs + 1] = a end
  table.sort(affs)

  print(string.format("\nTICK %d  [%s]", tick, s.phase))
  print(string.format("  AP %d/%d   clouds=%s   conduit=%s   hp=%s   shield=%s",
    s.ap, s.gate, tostring(s.disturbed), tostring(s.feedback), tostring(s.health), tostring(s.shield)))
  print("  limbs: " .. fmt_limbs(s))
  print(string.format("  predicates: all_prepped=%s committed=%s(latch=%s) any_broken=%s seal=%s next_prep=%s next_oc=%s sw_affs=%d",
    tostring(s.all_prepped), tostring(s.committed), tostring(s.commit_latch), tostring(s.any_broken),
    tostring(s.seal_present), tostring(s.next_prep), tostring(s.next_overcharge), s.shockwave_affs))
  print("  affs:  " .. (#affs > 0 and table.concat(affs, ", ") or "(none)"))

  last_atk = nil
  sylvan.dispatch()
  print("  WHY:   " .. why(s))
  print("  FIRE:  " .. tostring(last_atk))
  model(last_atk)
  print("  ==>    " .. effects)

  if lock_done() then
    print(string.format("\n*** LOCK SEALED at tick %d: %s all >= threshold ***",
      tick, table.concat(sylvan.CONFIG.LOCK_AFFS, "+")))
    break
  end

  stall = (effects == "(no state change)") and (stall + 1) or 0
  if stall >= 2 then
    print(string.format("\n!!! STALLED at tick %d in phase %s (AP %d/%d) -- no state change two ticks running",
      tick, s.phase, s.ap, s.gate))
    break
  end
end
