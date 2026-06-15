# Blademaster — Legacy / AK Port

Port of the Levi/Ataxia Blademaster combat system to **Legacy** (self-curing
framework) + **AK** (enemy aff/limb tracker), in the sibling-port house style.

**Source of truth (combat logic):** the Levi ataxia scripts —
- `005_CC_BM_Ice.lua` — unified dispatch, double / quad / brokenstar / group
- `003_BrokenStar.lua` — the brokenstar cascade (state-driven; the model this port follows)
- `004_Group.lua` — pommelstrike lock ladder

The logic is reproduced faithfully; only the **state model** was rebuilt to shed
fragility. This file maps the Levi symbols to their AK/Legacy equivalents and
records the design decisions.

---

## Architecture

- **No self-registration.** The module defines functions only; you wire
  manually-created Mudlet aliases/triggers to them per `MUDLET_SETUP.md`. No
  `tempAlias` / `tempRegexTrigger` / `registerAnonymousEventHandler`.
- **JIT dispatch.** An alias **arms** (`blademaster.arm(mode)`, fires immediately
  if balance+eq are up). A balance/eq-**used** trigger calls
  `blademaster.on_recover(interval)`, which schedules a `tempTimer` for
  `interval - getNetworkLatency()`; on expiry, if still armed, it dispatches with
  **current** state and disarms (one shot per arm). This replaces the old
  `attackInFlight` latch + GMCP `Char.Vitals` handler entirely.
- **State-driven brokenstar.** Reads framework state each tick instead of running
  a trigger-fed machine: `affstrack.impale == "Me"` (impaled), `ak.bleeding`
  (bleed), `lb`/`affstrack` (limbs/prone). The kill is one string,
  `withdraw blade/sheathe sword/brokenstar`. A target writhe needs no handling —
  AK flips impale off and the cascade re-impales. The only script latch is
  `impaleslash` (self-clearing after `CONFIG.IMPALESLASH_LATCH`, mirroring Levi's
  `timpaleslash`); it also guards brokenstar against stale `ak.bleeding`.

State eliminated vs. the prior port: `attackInFlight`, the GMCP balance handler,
`isImpaled` / `withdrawDone` / `secondImpale` / `bladetwistCount`, the prone
timer, and the two ASCII status panels. ~2226 → ~710 lines.

---

## Symbol mapping

### Target state (AK)
| Levi symbol | Used for | AK equivalent |
| --- | --- | --- |
| `tAffs.X` / `haveAff("X")` | target afflictions | `has("X")` → `affstrack.score[X] >= CONFIG.AFF_THRESHOLD` |
| `tAffs.impaled` | brokenstar chain | `affstrack.impale == "Me"` (`impaled()`) |
| `tAffs.bleed` | brokenstar trigger / kill | `ak.bleeding` (`bleed()`); refreshed by the `discern` ridealong |
| `lb[target].hits[limb]` | limb damage % (spaced keys) | **same**, raw `target` key |
| `tparrying` / `ataxiaTemp.parriedLimb` | focus / airfist | `targetparry` (no-space) → normalised to spaced via `PARRY_SPACED` |
| `tmounted` | dismount-before-break | `ak.mounted` |
| `ataxiaTemp.targetHP` | display | `ak.currenthealth / ak.maxhealth` (`target_hp()`) |
| `ataxiaTables.limbData.bmSlash/bmOffSlash/bmCompass` | prep/break prediction | `blademaster.CONFIG.DMG[form]` — **static**, keyed on `Legacy.Tannivh.form` |

### Self state (Legacy)
| Levi symbol | Used for | Legacy equivalent |
| --- | --- | --- |
| `ataxia.afflictions.aeon` | skip-tick gate | `self_aff("aeon")` → `Legacy.Curing.Affs.aeon` |
| `ataxia_needLockBreak/Break` | self lock-break | `need_lockbreak()` / `lockbreak_ready()` / `do_lockbreak()` |
| `getCharstat("Shin")` | airfist gate | `charstat("Shin")` (gmcp `Char.Vitals.charstats`) |
| `getLockingAffliction()` | class lock aff (group) | **same**, guarded (`if getLockingAffliction then`) |
| `engaged` | engage-on-first | `ak.engaged`; `/ENGAGE` appended to the first attack |
| `combatQueue()` prefix | pre-attack chain | `CONFIG.PRECOMMANDS` (`{"stand"}`) |

### Attack delivery
`send("SETALIAS ATK <cmd1/cmd2/…>")` then
`send("QUEUE ADDCLEARFULL FREESTAND ATK")` — the sibling-port queue convention
(`/`-separated sub-commands). Game commands are verbatim Achaea syntax.

---

## Public API

| Symbol | Called from |
| --- | --- |
| `arm(mode)` | the arming aliases (`bm*`) — the normal entry point |
| `on_recover(interval)` | the REQUIRED balance/eq-used trigger |
| `dispatch(mode)` | direct fire (arm uses it internally) |
| `set_mode(mode)` / `reset()` | mode switch without firing / clear armed+latch state |
| `on_impaleslash()` | REQUIRED brokenstar trigger |
| `on_hamstring()` | recommended hamstring trigger |
| `debug_snapshot()` | introspection (table); `bmstatus` prints a one-liner |
| `CONFIG` / `state` | tunables / runtime state |

Top-level alias handlers: `bm`, `bmd`, `bmdq`, `bmbs`, `bmgroup`, `bmreset`,
`bmstatus` — each a one-liner that arms a mode (or resets / prints status).

---

## Open decisions

- **`affstrack.impale == "Me"`** is the impaled read (per `2h_runie`). If your AK
  build exposes impale differently, override `impaled()`.
- **`ak.mounted`** assumes AK tracks a mount flag (dismount-before-break logic). 
- **`Legacy.Tannivh.form`** is expected to return a stance name; `CONFIG.DMG` is keyed
  `doya/thyr/mir/arash/sanya` (lookup is lowercased). If it returns something else,
  rename the `CONFIG.DMG` keys to match (unknown/nil → `CONFIG.DEFAULT_FORM`).
- **Aff names** `"airfisted"`, `"prone"`, etc. assume those `affstrack.score` keys
  (005 checks `"airfisted"`; verify your AK build uses the same).
- **`CONFIG.AFF_THRESHOLD = 33`** matches the prior port; siblings use 30.
- **Parry handling** matches 005: airfist only, prep phases only — no pommelstrike
  fallback (a low-shin parry just slashes; focus steers off the parried limb).
- **Group mode** is the pommelstrike lock ladder only. Levi `004` also
  bleed-executes inside group; omitted here — use `bmbs` for the kill.
- **`lockBreak` tables** are the shared cross-module per-class self-lockbreak
  data; only the row for your class (Blademaster) fires at runtime.

---

## Testing

`blademaster_test.lua` (run `lua blademaster_test.lua` from this directory) stubs the
host globals, drives all four strategies across ~34 scenarios, and asserts the
normalised decision (infuse + action + strike), plus the JIT-arm and self-lockbreak
behaviours. Those expected values were verified **identical to the original Levi 005**
by a differential oracle that loaded both modules in isolated environments and diffed
every scenario (34/34 match). Re-run the harness after any logic change.
