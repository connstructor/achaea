--[[
================================================================================
TARGET LOCK BOX — LEGACY / AK PORT
================================================================================

Class-agnostic display utility. Prints an ASCII textbox showing, for each lock
type, which constituent locking afflictions the current target has — and how
confident AK is about each (green = certain, yellow = present-but-soft, gray =
absent). A lock whose every requirement is met is flagged "<< LOCKED".

Ported from the LEVI/Ataxia helper `ataxia_showTargetLocks()`.

Aliases (self-registering, reload-safe):
  tlocks  /  locks            -- locks.show() for the current `target`
  tlocks <name> / locks <name>-- box for a specific name
  locks.show("name")          -- direct call

Public API (everything else is file-local):
  locks.CONFIG                table — affThreshold (present), certainThreshold (green)
  locks.lockDefs              table — lock-type definitions (all = every aff; anyOf = >=1)
  locks.show(name)            main entry, called by the alias

--------------------------------------------------------------------------------
DEPENDENCY MAPPING (see ports/legacy_ak/locks/DEPENDENCIES.md)
--------------------------------------------------------------------------------
  haveAff("X")            -> has("X")        (affstrack.score[X] >= CONFIG.affThreshold)
  getAffProbabilityV3(X)  -> score("X")      (AK's 0-100 affstrack.score[X])
  cecho / target          -> unchanged       (Mudlet builtin + AK target global)

Dropped (vs original Levi):
  ataxia.lockDefs         -> locks.lockDefs  (self-contained, no ataxia.* refs)
  V3 0.0-1.0 probability  -> AK 0-100 confidence score (100 = fresh apply)

Namespace summary:
  locks.*                 — this module
  External (unchanged):   cecho, target, affstrack

================================================================================
]] --

-- ============================================================
--  NAMESPACE INIT
-- ============================================================
locks = locks or {}

-- ============================================================
--  CONFIG
-- ============================================================
locks.CONFIG = locks.CONFIG or {
    -- AK affstrack confidence (0-100) at/above which an aff counts as present.
    affThreshold = 30,
    -- At/above this score the aff is shown "certain" (green); affThreshold-89 = yellow.
    certainThreshold = 90,
}

-- ============================================================
--  LOCK DEFINITIONS
--    all   = every aff required for the lock
--    anyOf = at least one required (e.g. Focuslock's mental stack)
--  Data-driven: add Riftlock/Salvelock/etc. here once AK limb-state keys are settled.
-- ============================================================
locks.lockDefs = locks.lockDefs or {
    { name = "Softlock",  all = { "asthma", "anorexia", "slickness" } },
    { name = "Venomlock", all = { "paralysis", "asthma", "anorexia", "slickness" } },
    { name = "Truelock",  all = { "paralysis", "asthma", "anorexia", "slickness", "impatience" } },
    { name = "Focuslock", all = { "paralysis", "asthma", "anorexia", "slickness" },
                          anyOf = { "stupidity", "dizziness", "epilepsy", "shyness", "depression" } },
    { name = "Aeonlock",  all = { "aeon", "asthma" } },
}

-- ============================================================
--  FILE-LOCAL HELPERS
-- ============================================================
-- Visible width = UTF-8 code points (box chars and check/cross are 1 col, not 3 bytes).
local function vlen(s)
    local _, n = s:gsub("[^\128-\191]", "")
    return n
end

-- AK confidence score 0-100 for an affliction (0 if untracked).
local function score(aff)
    return (affstrack and affstrack.score and affstrack.score[aff]) or 0
end

local function has(aff)
    return score(aff) >= locks.CONFIG.affThreshold
end

local function affColour(sc)
    if sc < locks.CONFIG.affThreshold then return "gray" end
    if sc >= locks.CONFIG.certainThreshold then return "green" end
    return "yellow"
end

-- ============================================================
--  MAIN
-- ============================================================
function locks.show(name)
    name = (name and name ~= "" and name) or target
    if not name or name == "" then
        cecho("\n<orange>[Locks]<reset> No target set.")
        return
    end

    -- Build content rows as lists of {t = text, c = colour} segments.
    local rows = {}
    local function row(segs) rows[#rows + 1] = segs end

    row({ { t = "TARGET LOCKS: ", c = "white" }, { t = tostring(name), c = "orange" } })
    row({ { t = "", c = "white" } }) -- spacer

    for _, lock in ipairs(locks.lockDefs) do
        local haveCount, total = 0, #lock.all
        local detail = { { t = "  ", c = "white" } }
        for i, aff in ipairs(lock.all) do
            local sc = score(aff)
            if sc >= locks.CONFIG.affThreshold then haveCount = haveCount + 1 end
            detail[#detail + 1] = { t = (sc >= locks.CONFIG.affThreshold and "✓ " or "✗ ") .. aff, c = affColour(sc) }
            if i < #lock.all then detail[#detail + 1] = { t = "  ", c = "white" } end
        end

        -- anyOf group (e.g. Focuslock mental stack): satisfied by any one member.
        if lock.anyOf then
            total = total + 1
            local hit
            for _, aff in ipairs(lock.anyOf) do
                if has(aff) then hit = aff; break end
            end
            if hit then haveCount = haveCount + 1 end
            detail[#detail + 1] = { t = "  ", c = "white" }
            detail[#detail + 1] = { t = hit and ("✓ mental:" .. hit) or "✗ mental", c = hit and "green" or "gray" }
        end

        local complete = (haveCount == total)
        row({
            { t = string.format("%-10s", lock.name), c = complete and "green" or "white" },
            { t = string.format(" %d/%d", haveCount, total), c = "cyan" },
            { t = complete and "  << LOCKED" or "", c = "red" },
        })
        row(detail)
    end

    -- Size the box to the widest content line (visible columns).
    local width = 0
    for _, segs in ipairs(rows) do
        local len = 0
        for _, s in ipairs(segs) do len = len + vlen(s.t) end
        if len > width then width = len end
    end

    local function rule(l, r) return "<gray>" .. l .. string.rep("─", width + 2) .. r end
    cecho("\n" .. rule("┌", "┐"))
    for _, segs in ipairs(rows) do
        local body, len = "", 0
        for _, s in ipairs(segs) do
            body = body .. "<" .. s.c .. ">" .. s.t
            len = len + vlen(s.t)
        end
        cecho("\n<gray>│ " .. body .. "<gray>" .. string.rep(" ", width - len) .. " │")
    end
    cecho("\n" .. rule("└", "┘") .. "<reset>")
end

-- ============================================================
--  ALIAS (self-registering, reload-safe)
--  Manual-setup variant: delete this block and bind `locks.show()` by hand.
-- ============================================================
if locks._aliasId then pcall(killAlias, locks._aliasId) end
locks._aliasId = tempAlias([[^t?locks(?:\s+(\S+))?$]], [[locks.show(matches[2])]])
