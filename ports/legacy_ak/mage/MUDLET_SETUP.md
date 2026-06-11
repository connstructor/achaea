# Magi — Mudlet Setup (manual aliases & triggers)

`magi.lua` self-registers **nothing** — no `tempAlias`, no `tempRegexTrigger`, no
event handlers. You create those by hand. This system is small to wire: **six
aliases** (one per mode + status/reset) and **one optional GMCP handler** for
live resonance. There are **no required triggers** — `dispatch()` reads all
opponent state live from AK at fire time.

All regex below is in **Mudlet UI form** (single backslash). In Mudlet,
`matches[1]` is the whole match and `matches[2]`, … are the capture groups.

---

## 0. Load order

1. Add `magi.lua` as a **Script** (Scripts → Add Item → paste the file). It
   defines the `magi` table when the profile loads.
2. Add the aliases below. They reference `magi.*` (and the top-level `mfire`…
   wrappers), which exist after the script runs, so ordering doesn't matter.
3. Set your item IDs in `magi.offense.CONFIG.WEAPONS` (`STAFF`, `SHIELD`).
4. Make sure the host-framework globals the module reads are present — see §4.
5. **Confirm the AK affstrack keys** for Magi-mechanic states — see §5. This is
   the one thing most likely to need tuning.

---

## 1. Mode aliases (set mode + dispatch)

Each press sets the mode (a sticky preference) and dispatches once. Re-pressing
re-dispatches with current state; dispatch no-ops unless balance + eq are up.

| Pattern | Script | Mode |
|---|---|---|
| `^mfire$`  | `mfire()`  | **fire** — burns → conflagrate → destroy/stormhammer (default) |
| `^mwater$` | `mwater()` | **water** — freeze → hypothermia → glaciate |
| `^mlock$`  | `mlock()`  | **lock** — kelp stack → truelock via resonance affs |
| `^msalve$` | `msalve()` | **salve** — earth/fire salve-pressure |
| `^mgroup$` | `mgroup()` | **group** — stormhammer multi-target + damage |
| `^mm$`     | `mm()`     | dispatch in the **current** mode (no mode change) |

Rename the patterns to whatever keys you bind. You normally never call
`magi.offense.dispatch()` directly; go through a mode alias (or `mm`).

> **Want JIT "queue during recovery, fire on balance return"?** Add a
> balance-used trigger that calls `mm()` (or `magi.offense.dispatch()`). Because
> dispatch reads live state and self-gates on balance+eq, calling it on balance
> return fires the freshest attack. No code change needed.

---

## 2. Convenience aliases (optional)

| Pattern | Script | What it does |
|---|---|---|
| `^mstatus$` | `mstatus()` | Read-only status: mode, resonance, burns, scalded, calcify, shalestorm, hypo/frozen. |
| `^mreset$`  | `mreset()`  | Clear runtime state (storm targets + last spell). Use on target change / fight end. |
| `^mstorm (city\|all\|priority)$` | `magi.storm.setMode(matches[2])` | Switch stormhammer target-selection mode. |

---

## 3. OPTIONAL — live resonance handler

`dispatch()` and `status()` already call `get_resonance()` before they read it,
so resonance is always fresh at decision time. If you also want it updated
continuously (e.g. for a GUI), register a GMCP handler:

- Type: **Script** with an event handler on `gmcp.Char.Vitals`, script:
  ```lua
  get_resonance()
  ```

Not required for combat.

---

## 4. Prerequisites — host-framework globals (not configured here)

The module is pure offense logic; it **reads** opponent/self state from the
Legacy + AK framework, populated by that framework's own triggers/GMCP. If
missing, the system runs on zeros / single-target.

| Global | Provides |
|---|---|
| `Legacy.Curing.Affs` | self afflictions (`aeon` gate) |
| `Legacy.Settings.Curing.status` | combat-paused gate |
| `ak.defs` | opponent shield / rebounding |
| `ak.currenthealth` / `ak.maxhealth` | opponent HP% (kill thresholds) |
| `affstrack.score[aff]` (0-100) | opponent afflictions — incl. Magi states (§5) |
| `lb[target].hits[limb]` (0-200) | opponent limb damage (broken = >= 100) |
| `target` | current target name |
| `gmcp.Char.Vitals` | `bal` / `eq` (fire gate), `charstats` (resonance) |
| `gmcp.Char.Status` | `class` (class guard), `name` |
| `gmcp.Char.Name` | self-exclusion for stormhammer |
| `gmcp.Room.Players` | room players for stormhammer multi-target |

---

## 5. ⭐ Confirm AK tracks the Magi-mechanic states

This port reads **all** Magi-mechanic opponent states from AK `affstrack`
(instead of the source's self-tracking). If your AK doesn't track a given key,
that branch silently runs on zero. Confirm these `affstrack.score` keys exist —
and adjust the helper or `CONFIG` if the names/scale differ:

| State | `affstrack.score` key | Notes |
|---|---|---|
| burns (0-5) | `aflame` | scaled: `burns = floor(aflame / CONFIG.aflameScale)`, default scale **100** (200 == 2 burns). Set `aflameScale = 1` if your AK stores the raw count. |
| conflagrated | `conflagrate` | present when `>= CONFIG.fullThreshold` (100) |
| scalded | `scalded` | `>= 100` |
| calcified torso | `calcifiedtorso` | `>= 100` |
| calcified head | `calcifiedhead` | `>= 100` |
| shalestorm | `shalestorm` | `>= CONFIG.affThreshold` (30) |
| hypothermia | `hypothermia` | `prob >= 0.5` (score >= 50) |
| frozen | `frozen` | `prob >= 0.5` |

If a key name differs in your AK, either rename it there or edit the one matching
helper in `magi.lua` (`getBurns` / `isConflagrated` / `isScalded` /
`isCalcifiedTorso` / `isCalcifiedSkull`, or the inline `has("shalestorm")` /
`prob("hypothermia")` / `prob("frozen")` reads).

---

## 6. Stormhammer multi-target (group mode + low-HP kill)

Out of the box, stormhammer fires at the single primary target (safe default).
For real 3-target sweeps you must tell the module who the enemies are:

- **Simple:** populate the set — `magi.storm.enemies = {Bob = true, Sue = true}`.
- **Better:** override the predicate to read your framework's enemy list, e.g.:
  ```lua
  function magi.storm.isEnemy(name)
    if name == target then return true end
    return Legacy.Enemies and Legacy.Enemies[name] == true  -- adjust to your API
  end
  ```
- `magi.storm.mode`: `"all"` (default) = every enemy in room; `"city"` = same-city
  as target (needs `ataxiaNDB_getCitizenship`, else degrades to all); `"priority"`
  = degrades to all (tprio not ported).

`magi.storm.replaceDead(name)` is available if you wire a "target died without a
starburst" trigger, but it's optional.

---

## Quick checklist

- [ ] `magi.lua` loaded as a Script
- [ ] Staff/shield IDs set in `magi.offense.CONFIG.WEAPONS`
- [ ] `mfire` / `mwater` / `mlock` / `msalve` / `mgroup` / `mm` aliases
- [ ] *(optional)* `mstatus` / `mreset` / `mstorm <mode>` aliases
- [ ] *(optional)* GMCP `Char.Vitals` → `get_resonance()` handler
- [ ] **AK affstrack keys for Magi states confirmed** (§5) — esp. `aflameScale`
- [ ] *(group mode)* `magi.storm.enemies` populated or `isEnemy` overridden
- [ ] Host-framework globals present (§4): `Legacy`, `ak`, `affstrack`, `lb`,
      `target`, `gmcp`
