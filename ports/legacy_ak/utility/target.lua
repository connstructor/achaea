function targetEcho(line, qty)
    qty = qty or 1
    for _ = 1, qty, 1 do
      cecho("\n<white>(<DodgerBlue>Targeting<white>): " .. line)
    end
  end
  
-- Example of gmcp.Char.Vitals
--  gmcp.Char.Vitals = {
--     bal = "1",
--     charstats = { "Bleed: 0", "Rage: 0", "Spec: Sword and Shield", "Ferocity: 0", "empower: 1" },
--     ep = "31430",
--     eq = "1",
--     hp = "7320",
--     maxep = "31430",
--     maxhp = "7320",
--     maxmp = "6213",
--     maxwp = "26615",
--     mp = "6213",
--     nl = "81.57",
--     string = "H:7320/7320 M:6213/6213 E:31430/31430 W:26615/26615 NL:81.57/100 ",
--     wp = "26615"
--   }

local function knight_spec()
  local cs = gmcp and gmcp.Char and gmcp.Char.Vitals and gmcp.Char.Vitals.charstats
  if not cs then
    return nil
  end
  for _, stat in ipairs(cs) do
    local s = stat:match("^Spec:%s*(.+)$")
    if s then
      return s
    end
  end
  return nil
end

  -- Combat-framework bridge. When a class adapter is registered and active,
  -- target.lua dispatches to it; otherwise it falls back to the legacy per-class
  -- branches below. Guarded so this works whether or not combat.lua is loaded.
  local function combat_busy()
    return combat and combat.active and combat.active() ~= nil
  end
  local function combat_handled(method, arg)
    if combat and combat[method] then
      return combat[method](arg)
    end
    return false
  end

  function processTarget()
    send("CLEARQUEUE ALL")
    send("SETTARGET " .. target)
    -- Legacy spec-gated reset; the SnB adapter does this inside onTarget/onClearTarget.
    if not combat_busy() and knight_spec() == "Sword and Shield" then
      runewarden.snb.reset()
    end
    if
      not target or
      target == "" or
      target == gmcp.Char.Status.name or
      target == "None" or
      target == "Dude" or
      target:match("^%d+$") or
      not endeeb.db[target]
    then
      ak.nodisplay = true
      ak.noDisplay()
      -- Migrated class: adapter owns its no-target teardown. Else legacy branch.
      if not combat_handled("onClearTarget") then
        if gmcp.Char.Status.class == "Sentinel" or gmcp.Char.Status.class == "Magi" then
          send("ORDER LOYALS PASSIVE")
        elseif gmcp.Char.Status.class == "Runewarden" then
          send("DISENGAGE")
          send("FURY OFF")
          send("FALCON RECALL")
          if runewarden and runewarden.twoh and runewarden.twoh.state then
            runewarden.twoh.state.falcon_tracking = false
            runewarden.twoh.state.falcon_slaying = false
          end
        elseif gmcp.Char.Status.class == "Monk" then
          send("MIND UNLOCK")
        end
      end
      if system.hunting.vars.hunting then
        send("COGNITION DISABLE ANEIRA")
      else
        send("COGNITION ENABLE ANEIRA")
      end
    else
      ak.nodisplay = false
      local found = false
      for _, entry in ipairs(gmcp.Room.Players) do
        if entry["name"] == target then
          targetEcho("TARGETING " .. target .. "!")
          found = true
          break
        end
      end
      if not found then
        targetEcho("TARGETING " .. target .. " FROM AFAR!")
      end
      ak.oresetparse()
      ak.scoreup()
      -- Migrated class: adapter owns its new-target side effects. Else legacy branch.
      if not combat_handled("onTarget", target) then
        if gmcp.Char.Status.class == "Runewarden" then
          -- send("FALCON TRACK " .. target)
          falconTracking = false
          falconFighting = false
          if runewarden and runewarden.twoh and runewarden.twoh.state then
            runewarden.twoh.state.falcon_tracking = false
            runewarden.twoh.state.falcon_slaying = false
          end
          send("FALCON REPORT")
          send("parry " .. (currentparry or "head"), false)
        elseif gmcp.Char.Status.class == "air Elemental Lord" then
          if AirLordSystem then AirLordSystem.init() end
        elseif gmcp.Char.Status.class == "Sentinel" then
          send("WIELD SPEAR SHIELD")
        elseif gmcp.Char.Status.class == "Monk" then
          send("MIND LOCK " .. target)
        elseif gmcp.Char.Status.class == "Magi" then
          magi.offense.reset()
        end
      end
      send("COGNITION DISABLE ANEIRA")
    end
  end
  
  function nextTarget()
    if not target or target == "" then
      cecho("<red>No current target set.\n")
      return
    end
    if not targetPriority or #targetPriority == 0 then
      cecho("<red>No targetPriority table available.\n")
      return
    end
    -- Check whether current target is in the room
    local targetInRoom = false
    if gmcp.Room and gmcp.Room.Players then
      for _, player in ipairs(gmcp.Room.Players) do
        local name = player.name or player
        if name and name:lower() == target:lower() then
          targetInRoom = true
          break
        end
      end
    end
    -- If the current target is still here, do nothing
    if targetInRoom then
      cecho("<green>Current target is still in room: " .. target .. "\n")
      return
    end
    -- If the first priority entry is the current target, discard it
    if targetPriority[1] and targetPriority[1]:lower() == target:lower() then
      table.remove(targetPriority, 1)
    end
    -- Take the next priority target
    if not targetPriority[1] then
      cecho("<red>No next target available.\n")
      return
    end
    target = targetPriority[1]
    boxEcho("<cyan>Switching target to: " .. target .. "\n")
    expandAlias("st " .. target)
  end