# Unified Combat Framework

A single registry that every class module plugs into, so the orchestration glue
(`target.lua`, `class_switch.lua`) stops hard-coding per-class behavior.

A **combat module** is a namespace table that implements a fixed **standard API**
directly (`arm`, `onTarget`, `onClearTarget`, …). Registering hands that table to
the registry — **the module *is* the contract**; there is no separate adapter or
wrapper layer. The framework tracks one active module and dispatches target /
balance / lifecycle events to it.

The framework **defaults to legacy behavior**: until a module is active,
`combat.active()` is `nil` and every dispatch returns `false`, so the old
per-class branches in `target.lua` run unchanged. Migration is one module at a
time; the system is shippable at every step.

---

## Files

| File | Role |
|---|---|
| `utility/combat.lua` | **Framework core.** Registry, active-module tracking, dispatch. **Must load before `target.lua`.** |
| `utility/target.lua` | Orchestrator. `processTarget()` dispatches to the active module, falls back to legacy per-class branches. |
| `utility/class_switch.lua` | Drives `combat.setActive(id)` via a `class_dispatch.adapters` group→id map. |
| `<class>/<Module>.lua` | Each module implements the standard API on its namespace and calls `combat.register(<namespace>)` at the bottom. |

Load order is enforced defensively (every caller guards `combat and …`, and
registration defers via `tempTimer(0, …)` if the core isn't loaded yet), so a
wrong script-tree position degrades to legacy rather than erroring. Still: **put
`combat.lua` at the top of the tree.**

---

## The standard combat-module API

Implement these on the module's own namespace. Every function is **optional**;
the registry calls each by name and treats an absent one as a no-op (NOT a
fallback to legacy — an active module owns its behavior). Functions are plain
(dot-defined) and close over their own namespace, so **they take no `self`** —
the dispatched argument is the first parameter.

```
-- descriptor
M.id            string          -- registry key, the dotted module path ('runewarden.snb')
M.jitBalance    boolean         -- latency-timed off the Balance trigger? (false/absent => pull-style)
M.modes         table?          -- optional: valid mode names for arm{}, for validation/help

-- offense
M.arm(opts)                     -- the attack alias. opts = { mode=?, limb=?, side=?, finisher=?, ... }.
M.onBalanceUsed(interval)       -- JIT modules schedule their fire here; pull modules omit it.

-- target lifecycle
M.onTarget(name)                -- new valid target: wield / falcon report / mind-lock / parry / reset.
M.onClearTarget()               -- target gone, still this class: stop offense, neutralize pet, disengage.

-- class lifecycle
M.activate()                    -- became the active class. idempotent. usually nothing.
M.deactivate()                  -- left this class: teardown (recall pet, disengage). often = onClearTarget().

-- misc
M.reset()                       -- soft reset of offensive state between targets. clear armed/timers/latches; KEEP user modes.
M.status()                      -- render the status box. bound to the unified `cstatus` alias.
```

### `arm(opts)` — one rich entry point

`opts` is a table so a single entry can carry a mode plus module-specific extras,
each module reading the keys it understands:

```lua
combat.arm{}                          -- default: arm with current mode
combat.arm{ mode = "fire" }           -- magi fire mode
combat.arm{ mode = "devastate", limb = "arms" }   -- 2H devastate-arms
combat.arm{ finisher = true }         -- a finisher swing
```

This is why 2H's `xx`/`cc`/override don't need private aliases — they're just
`arm{...}` calls with extra keys. Modules ignore keys they don't use; a module
with no modes (e.g. SnB) ignores `opts` entirely.

### `deactivate` vs `onClearTarget`

- **`onClearTarget`** = *still this class, no valid target* → stop offense,
  recall/passive the pet, `DISENGAGE`.
- **`deactivate`** = *no longer this class* → full teardown so the incoming class
  doesn't inherit a live pet. Usually just `M.onClearTarget()`.

They can both fire on a class-switch-that-also-clears-target, double-sending
`DISENGAGE` — idempotent and harmless, a deliberate accept.

### `jitBalance`

The end state is every module latency-timed off **one** Balance trigger
(`jitBalance = true`). Pull-style modules (magi, dwc, shikudo, tekura) start
`jitBalance = false` with no `onBalanceUsed`; converting one to balance-timed
firing just sets the flag and adds the method. Pets stay 100% in-module — no API
method, no flag.

---

## Core API (`combat.lua`)

```
combat.register(module)  -> module    -- add/replace by module.id. idempotent (safe on reload).
combat.setActive(id)                  -- deactivate outgoing, activate incoming. id may be nil (=> legacy).
combat.active()          -> module|nil
combat.activeId()        -> string|nil
combat.get(id)           -> module|nil
combat.isActive(id)      -> boolean

-- Dispatch to the active module's same-named function. Each returns true if a
-- module is active (it owns the behavior), false if none is (=> legacy fallback).
combat.arm(opts)         -> bool
combat.onTarget(name)    -> bool
combat.onClearTarget()   -> bool
combat.onBalanceUsed(i)  -> bool
combat.reset()           -> bool
combat.status()          -> bool
```

---

## Making a module conform (load-order-safe)

Implement the API on the namespace, set the descriptor, register the table:

```lua
runewarden.snb.id, runewarden.snb.jitBalance = "runewarden.snb", true

function runewarden.snb.arm(opts)            -- (SnB has no modes; opts ignored)
  if have_eqbal() then runewarden.snb.dispatch()
  else runewarden.snb.state.next_bal_armed = true end
end
function runewarden.snb.onTarget(name)
  runewarden.snb.reset(); send("FALCON REPORT"); send("parry " .. (currentparry or "head"), false)
end
function runewarden.snb.onClearTarget()
  runewarden.snb.reset(); send("DISENGAGE"); send("FURY OFF"); send("FALCON RECALL")
end
-- reset() / onBalanceUsed(interval) are the module's existing entry points.

do
  local function register() if combat and combat.register then combat.register(runewarden.snb) end end
  if combat and combat.register then register() else tempTimer(0, register) end
end
```

Standard functions reference the module by **global path** (`runewarden.snb.reset`),
not a captured upvalue, so reloading the file refreshes them and re-`register()`
overwrites the stale table.

### Migrating an existing module

1. Rename/define the public entry points to the standard names (`arm`,
   `onBalanceUsed`, `onTarget`, `onClearTarget`, `reset`). Keep one-line
   **back-compat aliases** (`runewarden.snb.arm_next_bal = runewarden.snb.arm`)
   so the existing hand-wired Mudlet aliases/triggers keep working mid-migration.
2. `combat.register(<namespace>)` at the bottom.
3. Mudlet wiring: one core "Balance used" trigger →
   `combat.onBalanceUsed(matches[2])`, and **delete that module's private Balance
   trigger** (else it double-fires). Repoint the attack alias to `combat.arm{...}`.

---

## Migration phases (each shippable)

- **Phase 0** — `combat.lua` core. Nothing active; every dispatch a no-op. *(done)*
- **Phase 1** — `processTarget()` registry-aware, legacy branches guarded by
  `if not combat_handled(...)`. *(done)*
- **Phase 2** — conform the JIT modules (snb ✓, then twoh, blademaster, sentinel,
  psion, sylvan). Per module: verify onTarget/onClearTarget reproduce the old
  `target.lua` sends, swap to the single Balance trigger, delete the legacy
  branch. Retire `falconTracking`/`falconFighting` once both runewarden land.
- **Phase 3** — conform the pull modules (magi, dwc, shikudo, tekura). No
  `onBalanceUsed`; `arm{mode=}` maps to their setMode+dispatch; shikudo/tekura
  get a real `reset` (their native one is cosmetic).
- **Phase 4** — *(activation hook done early)* `class_switch.lua` maps
  group→adapter id (`class_dispatch.adapters`) + calls `combat.setActive`. Full
  restructure of the `modules` leaves into `{group=, adapter=}` is the remaining
  cleanup.
- **Phase 5** — delete dead legacy branches and the duplicate class derivation.

`air Elemental Lord` has no module here (the `AirLordSystem.init()` call in
`target.lua` was a latent nil-crash, now guarded). It stays legacy until ported.

---

## Module status

| Module | id | jitBalance | Conformed |
|---|---|---|---|
| Runewarden SnB | `runewarden.snb` | yes | ✅ Phase 2 |
| Runewarden 2H | `runewarden.twoh` | yes | ✅ Phase 2 |
| Runewarden DWC | `runewarden.dwc` | (no) | ⬜ |
| Blademaster | `blademaster` | yes | ⬜ |
| Sentinel | `sentinel` | yes | ⬜ |
| Psion | `psion` | yes | ⬜ |
| Sylvan | `sylvan` | yes | ⬜ |
| Magi | `magi` | (no) | ⬜ |
| Monk Shikudo | `monk.shikudo` | (no) | ⬜ |
| Monk Tekura | `monk.tekura` | (no) | ⬜ |
| air Elemental Lord | `airlord` | — | ⬜ (unported) |

### Decisions (locked)

- A module **implements the standard API directly**; registering hands the module
  table to the registry. No wrapper/adapter layer.
- `arm(opts)` takes a **table** (`mode`/`limb`/`side`/`finisher`/…); module-specific
  verbs (2H devastate/override) flow through it rather than private aliases.
- Adapter ids = **dotted module path**, mapped to Mudlet group in `class_switch`.
- Attack aliases stay as **thin wrappers** calling `combat.arm{...}`.
- `jitBalance` is the only capability flag. Pets stay in-module.
- `2h.reset` clears `armed, falcon_tracking, falcon_slaying, override_loc,
  override_side, devastate_pending, last_fire_time`; **keeps** `focus_mode,
  weapon_mode`.
- **`onTarget` is per-class, not uniform:** SnB's calls `reset()` (its legacy did);
  2H's clears only the falcon flags (its legacy did NOT reset on retarget, so a
  mid-combat target switch stays armed/firing). Each `onTarget` reproduces that
  module's real legacy behavior rather than forcing symmetry.
- 2H's `arm(opts)` accepts `{devastate="ARMS"|"LEGS"}` and `{override=<limb>, side=}`,
  delegating to the existing setters (the `ww`/focus toggles stay module-private).
