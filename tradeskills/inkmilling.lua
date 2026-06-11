--[[
  TRADESKILLS — Inkmilling (Unified Batch Script)
  
  This script automates inkmilling in batches, managing outrifting, loading
  reagents into the mill, balance-paced milling, and retrieval of finished inks.
  It also supports direct milling of pigments from the rift/inventory.

  WIRING (do in Mudlet UI - see Inkmilling_Setup.md for details):
    - Alias:  ^im(?:\s+(.*))?$           → inkmilling.dispatch(matches[2])
    - Trigger: Milling Complete:
              ^With a satisfying rattle, you note that the milling is complete\.$
              → inkmilling.onMillingComplete()
    - Trigger: Ink Taken:
              ^You take (\d+|a) (\w+) ink(?:s)? from (.+)\.$
              → inkmilling.onInkTaken(matches[2], matches[3], matches[4])
    - Trigger: Failure:
              ^Your mill does not hold the required amount of reagents to mill that\.$
              → inkmilling.finish(false)
    - Hook your balance-recovered trigger to:
              inkmilling.onBalance()
--]] inkmilling = inkmilling or {}

inkmilling.config = inkmilling.config or {
    commandDelay = 0.5, -- delay for non-balance commands (outr, put, get)
    minBalanceDelay = 1.0, -- min wait after sending mill before checking balance
    balanceTimeout = 10, -- abort if balance hasn't recovered in 10s
    betweenBatchDelay = 1.0, -- pause between batches in a bulk run
    mill = "mill", -- keyword or ID of the mill to put reagents into
    maxBatchSize = 10, -- default max batch size
    safety = true -- check gmcp.IRE.Rift.List before running
}

inkmilling.state = inkmilling.state or {
    running = false,
    current = nil,
    queue = {},
    step = 0,
    timer = nil,
    pollTimer = nil,
    debug = false,
    awaitingBalance = false,
    minDelayElapsed = false,
    balanceReady = false,
    balanceWaitedAt = 0,
    bulkName = nil,
    bulkTotal = 0,
    bulkRemaining = 0,
    currentBatch = 0
}

-- Reagent category mapping to candidates in gmcp.IRE.Rift.List
inkmilling.reagentCategories = {
    red = {"red clay", "red chitin"},
    blue = {"lumic moss", "ink bladder"},
    yellow = {"yellow chitin"},
    gold = {"gold flakes"},
    common = {"fish scales"},
    uncommon = {"buffalo horn"},
    scarce = {"shark tooth"},
    rare = {"wyrm tongue"}
}

-- Maps a reagent's GMCP name to the command noun used in outr/put commands.
-- If an entry is missing, it defaults to stripping spaces from the name.
inkmilling.reagentNouns = inkmilling.reagentNouns or {
    ["lumic moss"] = "lumic",
    ["red clay"] = "redclay",
    ["fish scales"] = "scales",
    ["ink bladder"] = "bladder",
    ["buffalo horn"] = "buffalohorn",
    ["shark tooth"] = "tooth",
    ["wyrm tongue"] = "tongue",
    ["red chitin"] = "redchitin",
    ["yellow chitin"] = "yellowchitin",
    ["gold flakes"] = "goldflakes"
}

-- Recipe definitions
inkmilling.recipes = {
    -- Inks
    red = {
        type = "ink",
        reagents = {
            red = 1,
            common = 1
        }
    },
    blue = {
        type = "ink",
        reagents = {
            blue = 1,
            uncommon = 1
        }
    },
    yellow = {
        type = "ink",
        reagents = {
            yellow = 1,
            scarce = 1
        }
    },
    green = {
        type = "ink",
        reagents = {
            blue = 2,
            yellow = 1,
            uncommon = 2,
            scarce = 1
        }
    },
    purple = {
        type = "ink",
        reagents = {
            red = 2,
            blue = 2,
            common = 2,
            uncommon = 2,
            rare = 1
        }
    },
    gold = {
        type = "ink",
        reagents = {
            gold = 1,
            common = 2,
            uncommon = 2,
            scarce = 2,
            rare = 1
        }
    },
    black = {
        type = "ink",
        reagents = {
            red = 1,
            blue = 1,
            yellow = 1,
            gold = 1,
            common = 2,
            uncommon = 2,
            scarce = 2,
            rare = 3
        }
    },

    -- Pigments
    redpigment = {
        type = "pigment",
        reagents = {
            red = 1
        }
    },
    yellowpigment = {
        type = "pigment",
        reagents = {
            yellow = 1
        }
    },
    bluepigment = {
        type = "pigment",
        reagents = {
            blue = 1
        }
    }
}

----------------------------------------------------------------
-- Helpers
----------------------------------------------------------------

function inkmilling.echo(text)
    cecho("\n<dark_orchid>[<violet>Inkmilling<dark_orchid>]<wheat> " .. text)
end

function inkmilling.debugEcho(text)
    if inkmilling.state.debug then
        inkmilling.echo("<dim_grey>" .. text)
    end
end

local function cleanKeyword(name)
    if inkmilling.reagentNouns and inkmilling.reagentNouns[name] then
        return inkmilling.reagentNouns[name]
    end
    return name:gsub("%s+", "")
end

function inkmilling.getRiftAmount(name)
    if not (Legacy and Legacy.Rift and Legacy.Rift.Reagents) then
        return 0
    end
    for _, item in ipairs(Legacy.Rift.Reagents) do
        if item.name == name then
            return tonumber(item.amount) or 0
        end
    end
    return 0
end

-- Displays current stock of all reagents in the Rift
function inkmilling.showRift()
    inkmilling.echo("Rift Reagent Stock:")
    for category, candidates in pairs(inkmilling.reagentCategories) do
        local candStr = {}
        for _, candidate in ipairs(candidates) do
            local amt = inkmilling.getRiftAmount(candidate)
            table.insert(candStr, string.format("<yellow>%s<wheat> (%d)", candidate, amt))
        end
        cecho(string.format("\n  <cyan>%-10s<wheat>: %s", category:upper(), table.concat(candStr, ", ")))
    end
    cecho("\n")
end

-- Evaluates the best reagent to use for each category in the recipe
function inkmilling.selectReagentsForRun(recipe, totalQty)
    local selected = {}
    for category, qtyPerItem in pairs(recipe.reagents) do
        local candidates = inkmilling.reagentCategories[category]
        if not candidates or #candidates == 0 then
            return nil, "No candidates configured for category: " .. tostring(category)
        end

        if inkmilling.config.safety then
            local needed = qtyPerItem * totalQty
            local bestCandidate = nil
            local bestAmount = -1
            for _, candidate in ipairs(candidates) do
                local amt = inkmilling.getRiftAmount(candidate)
                if amt > bestAmount then
                    bestAmount = amt
                    bestCandidate = candidate
                end
            end

            if not bestCandidate or bestAmount < needed then
                return nil, string.format(
                    "Insufficient %s reagents. Need %d of '%s', but only have %d in rift. (Disable safety check with 'im config safety off' if needed.)",
                    category, needed, bestCandidate or candidates[1], bestAmount or 0)
            end
            selected[category] = bestCandidate
        else
            -- Safety off: just pick the first candidate
            selected[category] = candidates[1]
        end
    end
    return selected
end

----------------------------------------------------------------
-- Production Runner
----------------------------------------------------------------

function inkmilling.startRecipe(name, total)
    local recipe = inkmilling.recipes[name]
    if not recipe then
        inkmilling.echo("<red>No recipe named '" .. tostring(name) .. "'. Type 'im list' to see recipes.")
        return
    end
    if inkmilling.state.running or (inkmilling.state.bulkRemaining or 0) > 0 then
        inkmilling.echo("<red>Already running '" .. tostring(inkmilling.state.current or inkmilling.state.bulkName) ..
                            "'. Use 'im abort' first.")
        return
    end

    total = tonumber(total) or 1
    if total < 1 then
        inkmilling.echo("<red>Quantity must be >= 1.")
        return
    end

    -- Run pre-validation for the entire bulk amount
    local selected, err = inkmilling.selectReagentsForRun(recipe, total)
    if not selected then
        inkmilling.echo("<red>Validation failed: " .. tostring(err))
        return
    end

    inkmilling.state.bulkName = name
    inkmilling.state.bulkTotal = total
    inkmilling.state.bulkRemaining = total

    if total > inkmilling.config.maxBatchSize then
        local batches = math.ceil(total / inkmilling.config.maxBatchSize)
        inkmilling.echo(string.format("Starting bulk run of <yellow>%d %s<wheat> in %d batch(es) of up to %d", total,
            name, batches, inkmilling.config.maxBatchSize))
    end

    inkmilling.startNextBatch()
end

function inkmilling.startNextBatch()
    local st = inkmilling.state
    if (st.bulkRemaining or 0) <= 0 then
        if (st.bulkTotal or 0) > 1 then
            inkmilling.echo("<green>Bulk complete: <yellow>" .. tostring(st.bulkTotal) .. " " .. tostring(st.bulkName))
        end
        st.bulkName = nil
        st.bulkTotal = 0
        st.bulkRemaining = 0
        st.currentBatch = 0
        return
    end

    local recipe = inkmilling.recipes[st.bulkName]
    local batch = math.min(st.bulkRemaining, inkmilling.config.maxBatchSize)

    -- Dynamic validation for this specific batch
    local selected, err = inkmilling.selectReagentsForRun(recipe, batch)
    if not selected then
        inkmilling.echo("<red>Reagent validation failed for batch: " .. tostring(err))
        inkmilling.abort()
        return
    end

    local queue = {}
    if recipe.type == "ink" then
        -- 1. Outrift reagents
        for category, qtyPerItem in pairs(recipe.reagents) do
            local totalNeeded = qtyPerItem * batch
            local reagentName = selected[category]
            local keyword = cleanKeyword(reagentName)
            table.insert(queue, {
                cmd = "outr " .. totalNeeded .. " " .. keyword,
                pace = "delay"
            })
        end
        -- 2. Put reagents in mill
        for category, qtyPerItem in pairs(recipe.reagents) do
            local totalNeeded = qtyPerItem * batch
            local reagentName = selected[category]
            local keyword = cleanKeyword(reagentName)
            local putCmd = (totalNeeded > 1) and ("put group " .. keyword .. " in " .. inkmilling.config.mill) or
                               ("put " .. keyword .. " in " .. inkmilling.config.mill)
            table.insert(queue, {
                cmd = putCmd,
                pace = "delay"
            })
        end
        -- 3. Mill
        local millCmd = (batch > 1) and ("mill for " .. batch .. " " .. st.bulkName) or ("mill for " .. st.bulkName)
        table.insert(queue, {
            cmd = millCmd,
            pace = "balance"
        })
    else
        -- Pigment: mill directly from inventory/rift
        local color = st.bulkName:match("^(%a+)pigment$") or st.bulkName
        local millCmd = (batch > 1) and ("mill " .. batch .. " " .. color .. " pigment") or
                            ("mill " .. color .. " pigment")
        table.insert(queue, {
            cmd = millCmd,
            pace = "balance"
        })
    end

    st.running = true
    st.current = st.bulkName
    st.queue = queue
    st.step = 0
    st.currentBatch = batch
    st.bulkRemaining = st.bulkRemaining - batch
    st.awaitingBalance = false

    local progress = ""
    if st.bulkTotal > batch then
        progress = string.format(" [%d/%d]", st.bulkTotal - st.bulkRemaining, st.bulkTotal)
    end

    local detail = ""
    if recipe.type == "ink" then
        local parts = {}
        for cat, name in pairs(selected) do
            local clean = cleanKeyword(name)
            local qty = recipe.reagents[cat] * batch
            table.insert(parts, qty .. "x " .. clean)
        end
        detail = " <dim_grey>(using: " .. table.concat(parts, ", ") .. ")"
    end

    inkmilling.echo(string.format("Starting batch: <yellow>%s x%d<wheat>%s%s", st.bulkName, batch, progress, detail))

    inkmilling.nextStep()
end

local function killPaceTimers(st)
    if st.timer then
        killTimer(st.timer)
        st.timer = nil
    end
    if st.pollTimer then
        killTimer(st.pollTimer)
        st.pollTimer = nil
    end
end

function inkmilling.nextStep()
    local st = inkmilling.state
    if not st.running then
        return
    end
    killPaceTimers(st)
    st.awaitingBalance = false
    st.minDelayElapsed = false
    st.balanceReady = false
    st.step = st.step + 1
    local entry = st.queue[st.step]
    if not entry then
        inkmilling.debugEcho("Queue exhausted; awaiting milling complete / retrieval")
        return
    end

    inkmilling.debugEcho(string.format("step %d/%d [%s]: %s", st.step, #st.queue, entry.pace, entry.cmd))
    send(entry.cmd)

    if entry.pace == "balance" then
        st.awaitingBalance = true
        st.balanceWaitedAt = os.time()

        -- Gate 1: floor timer
        st.timer = tempTimer(inkmilling.config.minBalanceDelay, function()
            inkmilling.state.timer = nil
            inkmilling.state.minDelayElapsed = true
            inkmilling.debugEcho("balance: min delay elapsed")
            inkmilling.tryAdvanceBalance()
        end)

        -- Gate 2: polling timer
        st.pollTimer = tempTimer(0.1, function()
            inkmilling.state.pollTimer = nil
            inkmilling.pollBalance()
        end)
    else
        st.timer = tempTimer(inkmilling.config.commandDelay, function()
            inkmilling.nextStep()
        end)
    end
end

function inkmilling.tryAdvanceBalance()
    local st = inkmilling.state
    if not (st.running and st.awaitingBalance) then
        return
    end
    if not (st.minDelayElapsed and st.balanceReady) then
        return
    end
    killPaceTimers(st)
    st.awaitingBalance = false
    inkmilling.nextStep()
end

function inkmilling.pollBalance()
    local st = inkmilling.state
    if not (st.running and st.awaitingBalance) then
        return
    end
    if st.balanceReady then
        return
    end

    if os.time() - (st.balanceWaitedAt or 0) > inkmilling.config.balanceTimeout then
        inkmilling.echo("<red>Balance recovery timed out (" .. inkmilling.config.balanceTimeout .. "s) — aborting")
        inkmilling.abort()
        return
    end

    local balActive = true
    if gmcp and gmcp.Char and gmcp.Char.Vitals then
        balActive = tonumber(gmcp.Char.Vitals.bal) == 1
    end
    if balActive then
        st.balanceReady = true
        inkmilling.debugEcho("balance: recovered (poll)")
        inkmilling.tryAdvanceBalance()
    else
        st.pollTimer = tempTimer(0.1, function()
            inkmilling.state.pollTimer = nil
            inkmilling.pollBalance()
        end)
    end
end

function inkmilling.onBalance()
    local st = inkmilling.state
    if not (st.running and st.awaitingBalance) then
        return
    end
    st.balanceReady = true
    inkmilling.debugEcho("balance: recovered (onBalance hook)")
    inkmilling.tryAdvanceBalance()
end

----------------------------------------------------------------
-- Mudlet Trigger Callbacks
----------------------------------------------------------------

-- Trigger pattern: ^With a satisfying rattle, you note that the milling is complete
function inkmilling.onMillingComplete()
    local st = inkmilling.state
    if not st.running or not st.current then
        return
    end

    local recipe = inkmilling.recipes[st.current]
    if not recipe then
        return
    end

    if recipe.type == "ink" then
        inkmilling.debugEcho("Milling complete. Retrieving inks...")
        -- Issue command delay timer then send GET
        tempTimer(inkmilling.config.commandDelay, function()
            send("get 50 ink from " .. inkmilling.config.mill)
        end)
    else
        -- Pigment is complete immediately
        inkmilling.finish(true)
    end
end

-- Trigger pattern: ^You take (\d+|a) (\w+) ink(?:s)? from (.+)\.$
function inkmilling.onInkTaken(qty, color, container)
    local st = inkmilling.state
    if not st.running or not st.current then
        return
    end

    local parsedQty = tonumber(qty) or 1
    if qty == "a" or qty == "an" then
        parsedQty = 1
    end

    inkmilling.finish(true, parsedQty .. " " .. color .. " ink")
end

-- Finalize a batch
function inkmilling.finish(success, itemNameCreated)
    local st = inkmilling.state
    if not st.running and not st.current then
        return
    end
    killPaceTimers(st)
    local name = st.current or "?"

    st.running = false
    st.current = nil
    st.queue = {}
    st.step = 0
    st.currentBatch = 0
    st.awaitingBalance = false
    st.minDelayElapsed = false
    st.balanceReady = false

    if success then
        local detail = itemNameCreated and (" — " .. itemNameCreated) or ""
        inkmilling.echo("<green>Batch complete: <yellow>" .. name .. detail)

        if (st.bulkRemaining or 0) > 0 then
            local delay = inkmilling.config.betweenBatchDelay or 1.0
            inkmilling.echo("Next batch in " .. delay .. "s (" .. st.bulkRemaining .. " remaining)")
            st.timer = tempTimer(delay, function()
                inkmilling.state.timer = nil
                inkmilling.startNextBatch()
            end)
        else
            if (st.bulkTotal or 0) > 1 then
                inkmilling.echo("<green>Bulk complete: <yellow>" .. st.bulkTotal .. " " .. name)
            end
            st.bulkName = nil
            st.bulkTotal = 0
            st.bulkRemaining = 0
        end
    else
        inkmilling.echo("<red>Milling failed/aborted: <yellow>" .. name)
        if (st.bulkRemaining or 0) > 0 then
            inkmilling.echo("<red>Bulk aborted: " .. st.bulkRemaining .. " of " .. st.bulkTotal .. " remaining.")
        end
        st.bulkName = nil
        st.bulkTotal = 0
        st.bulkRemaining = 0
    end
end

function inkmilling.abort()
    local st = inkmilling.state
    if not st.running and (st.bulkRemaining or 0) == 0 then
        inkmilling.echo("Nothing running.")
        return
    end
    killPaceTimers(st)
    local name = st.current or st.bulkName or "?"
    local pending = (st.bulkRemaining or 0) + (st.currentBatch or 0)
    inkmilling.echo("Aborting <yellow>" .. name .. (pending > 1 and (" (" .. pending .. " pending)") or ""))
    st.running = false
    st.current = nil
    st.queue = {}
    st.step = 0
    st.currentBatch = 0
    st.awaitingBalance = false
    st.minDelayElapsed = false
    st.balanceReady = false
    st.bulkName = nil
    st.bulkTotal = 0
    st.bulkRemaining = 0
end

----------------------------------------------------------------
-- CLI Dispatcher
----------------------------------------------------------------

function inkmilling.list()
    inkmilling.echo("Recipes:")

    -- Inks
    cecho("\n  <cyan>── Inks ──")
    local sortedInks = {}
    for name, r in pairs(inkmilling.recipes) do
        if r.type == "ink" then
            table.insert(sortedInks, name)
        end
    end
    table.sort(sortedInks)
    for _, name in ipairs(sortedInks) do
        local r = inkmilling.recipes[name]
        local req = {}
        for cat, qty in pairs(r.reagents) do
            table.insert(req, qty .. "x " .. cat)
        end
        cecho(string.format("\n    <yellow>%-15s<wheat>Reagents: %s", name, table.concat(req, ", ")))
    end

    -- Pigments
    cecho("\n  <cyan>── Pigments ──")
    local sortedPigments = {}
    for name, r in pairs(inkmilling.recipes) do
        if r.type == "pigment" then
            table.insert(sortedPigments, name)
        end
    end
    table.sort(sortedPigments)
    for _, name in ipairs(sortedPigments) do
        local r = inkmilling.recipes[name]
        local req = {}
        for cat, qty in pairs(r.reagents) do
            table.insert(req, qty .. "x " .. cat)
        end
        cecho(string.format("\n    <yellow>%-15s<wheat>Reagents: %s", name, table.concat(req, ", ")))
    end
    cecho("\n")
end

function inkmilling.status()
    local st = inkmilling.state
    if st.running then
        local progress = ""
        if (st.bulkTotal or 0) > 1 then
            local doneAfter = st.bulkTotal - st.bulkRemaining
            progress = string.format(" [%d/%d, %d in flight]", doneAfter, st.bulkTotal, st.currentBatch or 0)
        end
        inkmilling.echo("Running: <yellow>" .. tostring(st.current) .. "<wheat>" .. progress .. " (step " .. st.step ..
                            "/" .. #st.queue .. ")")
    elseif (st.bulkRemaining or 0) > 0 then
        inkmilling.echo("Between batches: <yellow>" .. tostring(st.bulkName) .. "<wheat> (" .. st.bulkRemaining ..
                            " of " .. st.bulkTotal .. " remaining)")
    else
        inkmilling.echo("Idle.")
    end
end

function inkmilling.dispatch(rest)
    rest = rest and rest:match("^%s*(.-)%s*$") or ""
    if rest == "" or rest == "help" then
        inkmilling.echo("Commands:")
        cecho("\n  <yellow>im make [N] <recipe><wheat>       — mill N inks/pigments in batches")
        cecho("\n  <yellow>im status<wheat>                  — show current queue state")
        cecho("\n  <yellow>im abort<wheat>                   — cancel the current run")
        cecho("\n  <yellow>im list<wheat>                    — list all recipes and requirements")
        cecho("\n  <yellow>im where<wheat>                   — show reagent quantities in rift")
        cecho("\n  <yellow>im config mill <id/name><wheat>   — set mill identifier (default: mill)")
        cecho("\n  <yellow>im config batch <size><wheat>     — set max batch size (default: 10)")
        cecho("\n  <yellow>im config delay <secs><wheat>     — set command delay (default: 0.5s)")
        cecho("\n  <yellow>im config pause <secs><wheat>     — set batch pause delay (default: 1.0s)")
        cecho("\n  <yellow>im config safety on|off<wheat>    — toggle reagent checks (default: on)")
        cecho("\n  <yellow>im config debug on|off<wheat>     — toggle debug output (default: off)")
        cecho("\n")
        return
    end

    local cmd, args = rest:match("^(%S+)%s*(.*)$")
    cmd = cmd:lower()
    args = args or ""

    if cmd == "make" or cmd == "mill" then
        local n, recipe = args:match("^(%d+)%s+(.+)$")
        if n then
            inkmilling.startRecipe(recipe:lower():match("^%s*(.-)%s*$"), tonumber(n))
        else
            inkmilling.startRecipe(args:lower():match("^%s*(.-)%s*$"), 1)
        end
    elseif cmd == "status" then
        inkmilling.status()
    elseif cmd == "abort" or cmd == "stop" then
        inkmilling.abort()
    elseif cmd == "list" then
        inkmilling.list()
    elseif cmd == "where" or cmd == "rift" then
        inkmilling.showRift()
    elseif cmd == "config" or cmd == "set" then
        local key, val = args:match("^(%S+)%s*(.*)$")
        if not key then
            inkmilling.echo("<red>Usage: im config <key> <value>")
            return
        end
        key = key:lower()
        val = val:match("^%s*(.-)%s*$")

        if key == "mill" then
            if val == "" then
                inkmilling.echo("<red>Mill cannot be empty.")
            else
                inkmilling.config.mill = val
                inkmilling.echo("Config: mill set to <yellow>" .. val)
            end
        elseif key == "batch" then
            local n = tonumber(val)
            if not n or n < 1 then
                inkmilling.echo("<red>Batch size must be >= 1.")
            else
                inkmilling.config.maxBatchSize = n
                inkmilling.echo("Config: maxBatchSize set to <yellow>" .. n)
            end
        elseif key == "delay" then
            local n = tonumber(val)
            if not n or n < 0 then
                inkmilling.echo("<red>Delay must be >= 0.")
            else
                inkmilling.config.commandDelay = n
                inkmilling.echo("Config: commandDelay set to <yellow>" .. n .. "s")
            end
        elseif key == "pause" then
            local n = tonumber(val)
            if not n or n < 0 then
                inkmilling.echo("<red>Pause must be >= 0.")
            else
                inkmilling.config.betweenBatchDelay = n
                inkmilling.echo("Config: betweenBatchDelay set to <yellow>" .. n .. "s")
            end
        elseif key == "safety" then
            local state = val:lower()
            if state == "on" or state == "true" then
                inkmilling.config.safety = true
                inkmilling.echo("Config: reagent safety check <green>ON")
            elseif state == "off" or state == "false" then
                inkmilling.config.safety = false
                inkmilling.echo("Config: reagent safety check <red>OFF")
            else
                inkmilling.echo("<red>Usage: im config safety on|off")
            end
        elseif key == "debug" then
            local state = val:lower()
            if state == "on" or state == "true" then
                inkmilling.state.debug = true
                inkmilling.echo("Config: debug mode <green>ON")
            elseif state == "off" or state == "false" then
                inkmilling.state.debug = false
                inkmilling.echo("Config: debug mode <red>OFF")
            else
                inkmilling.echo("<red>Usage: im config debug on|off")
            end
        else
            inkmilling.echo("<red>Unknown config key: " .. key)
        end
    else
        inkmilling.echo("<red>Unknown command: '" .. cmd .. "'. Type 'im help' for commands.")
    end
end
