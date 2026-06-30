class_dispatch = class_dispatch or {}
class_dispatch.current_class = class_dispatch.current_class
class_dispatch.current_spec = class_dispatch.current_spec
class_dispatch.modules =
  {
    Sentinel = "SysSentinel",
    Blademaster = "SysBlademaster",
    Sylvan = "SysSylvan",
    Runewarden =
      {
        base = "SysRunewarden",
        specs = {["Two Handed"] = "SysRunewarden2H", ["Sword and Shield"] = "SysRunewardenSnB"},
      },
    Monk = {base = "SysMonk", specs = {Shikudo = "SysShikudo", Tekura = "SysTekura"}},
    Psion = "SysPsion",
    ["air Elemental Lord"] = "SysAirLord",
  }

-- Mudlet script-group name -> combat adapter id (dotted module path). Lets
-- apply_class_modules() activate the right adapter as classes switch. Only ids
-- that are actually registered with combat.register divert from the legacy path;
-- the rest are forward-compatible placeholders (that class stays legacy until
-- its adapter lands). See utility/COMBAT_FRAMEWORK.md.
class_dispatch.adapters = class_dispatch.adapters or
  {
    SysSentinel = "sentinel",
    SysBlademaster = "blademaster",
    SysSylvan = "sylvan",
    SysRunewarden2H = "runewarden.twoh",
    SysRunewardenSnB = "runewarden.snb",
    SysShikudo = "monk.shikudo",
    SysTekura = "monk.tekura",
    SysPsion = "psion",
    SysAirLord = "airlord",
  }

local function charstat(name)
  local cs = gmcp and gmcp.Char and gmcp.Char.Vitals and gmcp.Char.Vitals.charstats
  if not cs then
    return nil
  end
  local prefix = name .. ": "
  for _, entry in ipairs(cs) do
    local val = entry:match("^" .. prefix .. "(.+)$")
    if val then
      val = val:gsub("%%", "")
      return tonumber(val) or val
    end
  end
  return nil
end

local function read_spec()
  if not (gmcp and gmcp.Char and gmcp.Char.Vitals and gmcp.Char.Vitals.charstats) then
    return nil
  end
  for _, stat in ipairs(gmcp.Char.Vitals.charstats) do
    local s = string.match(stat, "^Spec:%s*(.+)$")
    if s then
      return s
    end
  end
  if charstat("Form") then
    return "Shikudo"
  elseif charstat("Stance") then
    return "Tekura"
  end
  return nil
end

local function set_group(name, on)
  if on then
    enableTrigger(name)
    enableAlias(name)
    enableScript(name)
    enableKey(name)
  else
    disableTrigger(name)
    disableAlias(name)
    disableScript(name)
    disableKey(name)
  end
end

local function all_modules()
  local all = {}
  for _, entry in pairs(class_dispatch.modules) do
    if type(entry) == "string" then
      all[entry] = true
    else
      if entry.base then
        all[entry.base] = true
      end
      if entry.specs then
        for _, m in pairs(entry.specs) do
          all[m] = true
        end
      end
    end
  end
  return all
end

local function modules_for(class, spec)
  local entry = class_dispatch.modules[class]
  if not entry then
    return {}
  end
  if type(entry) == "string" then
    return {entry}
  end
  local out = {}
  if entry.base then
    out[#out + 1] = entry.base
  end
  if spec and entry.specs and entry.specs[spec] then
    out[#out + 1] = entry.specs[spec]
  end
  return out
end

function apply_class_modules()
  local class, spec = class_dispatch.current_class, class_dispatch.current_spec
  if not class or class == "" then
    return
  end
  local enabled_list = modules_for(class, spec)
  local enable = {}
  for _, name in ipairs(enabled_list) do
    enable[name] = true
  end
  for name in pairs(all_modules()) do
    set_group(name, enable[name] == true)
  end
  -- Drive the unified combat registry: activate the adapter for the most-specific
  -- enabled module (spec leaf wins over base, since modules_for appends spec last).
  -- Additive + guarded: a no-op until combat.lua is loaded. active() resolves
  -- lazily, so an adapter that registers slightly later still becomes active.
  if combat and combat.setActive then
    local active_adapter = nil
    for _, name in ipairs(enabled_list) do
      local id = class_dispatch.adapters[name]
      if id then
        active_adapter = id
      end
    end
    combat.setActive(active_adapter)
  end
  table.sort(enabled_list)
  local label = (spec and (spec .. " ") or "") .. class
  cecho(
    "\n<cyan>[Class] " ..
    label ..
    " -> " ..
    (#enabled_list > 0 and table.concat(enabled_list, ", ") or "(no module match)")
  )
end

function on_gmcp_char_status()
  local class = gmcp and gmcp.Char and gmcp.Char.Status and gmcp.Char.Status.class
  if not class or class == "" then
    return
  end
  if class == class_dispatch.current_class then
    return
  end
  class_dispatch.current_class = class
  apply_class_modules()
end

function on_gmcp_char_vitals()
  local spec = read_spec()
  if spec == class_dispatch.current_spec then
    return
  end
  class_dispatch.current_spec = spec
  apply_class_modules()
end

function force_class_modules()
  class_dispatch.current_class = gmcp and gmcp.Char and gmcp.Char.Status and gmcp.Char.Status.class
  class_dispatch.current_spec = read_spec()
  apply_class_modules()
end

deleteNamedEventHandler("Tannivh", "ClassDispatchStatus")
deleteNamedEventHandler("Tannivh", "ClassDispatchVitals")
registerNamedEventHandler(
  "Tannivh", "ClassDispatchStatus", "gmcp.Char.Status", "on_gmcp_char_status"
)
registerNamedEventHandler(
  "Tannivh", "ClassDispatchVitals", "gmcp.Char.Vitals", "on_gmcp_char_vitals"
)
force_class_modules()