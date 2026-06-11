# Tekura Consolidation — Legacy / AK Port

Mapping doc for porting the two Tekura combat scripts to Legacy + AK,
following the same pattern established for Shikudo.

**Source files (consolidating):**
- `src_new/scripts/.../tekura/001_Tekura_Offense.lua` — 3-limb backbreaker (TKD)
- `src_new/scripts/.../tekura/002_Tekura_6Limb_Offense.lua` — 6-limb backbreaker (TK6)

**Destination:** `ports/legacy_ak/tekura/tekura.lua` (single consolidated file, two modes).

**Strategy:** Same as Shikudo — inline replace, no shim layer. `monk.tekura.*`
namespace. Two-mode switch: `setMode("tkd")` / `setMode("tk6")`.

---

## Inherited mappings (from Shikudo port)

All of these carry over identically.

### Tier 1 (AK)
- `tAffs.X` / `haveAff("X")` → `has("X")` (reads `affstrack.score[X] >= AFF_THRESHOLD`)
- `lb[target].hits[limb]` → unchanged
- `ataxiaTemp.parriedLimb` → `targetparry`
- `target` → unchanged
- `ataxia.currenthealth/maxhealth` → `ak.currenthealth`/`ak.maxhealth` (via `targetHpPct()`)
- `tmounted` → `has("mounted")`
- `tCity` / Mhaldor branch → removed (always proceed)

### Tier 2 (Legacy)
- `ataxia.vitals.form` / `.kata` / `.kai` → `charstat("Form")` / `charstat("Kata")` / `charstat("Kai")`
- `ataxia.vitals.{hp,maxhp,mp,maxmp}` → `vital("hp")` etc.
- `ataxia.balances.eq` → `eqUp()`
- `ataxia.afflictions.X` → `selfAff("X")` (reads `Legacy.Curing.Affs[X]`)
- `ataxia.defences.X` → `Legacy.Curing.Defs.current.X`
- `ataxia.settings.paused` → `Legacy.Settings.Curing.status == false`
- `ataxia.settings.separator` → `"/"` hardcoded
- `ataxiaBasher.enabled` → `Legacy.Settings.Basher.status`
- `combatQueue()` → REMOVED (Legacy handles pre-attack hooks externally)
- `send("queue addclear free X")` → `sendAttack(X, "FREE")` helper
- `ataxia_needLockBreak()` / `ataxia_lockBreak()` → `selfNeedLockBreak()` / `selfLockBreak()`

---

## Tekura-specific mappings

### `ataxia.vitals.stance` (Cat/Scorpion/Horse/Bear)
Source: `charstat("Stance")` — parses `gmcp.Char.Vitals.charstats` for `"Stance: X"`.
Same parser used for Form/Kata/Kai.

### "Battered" gate (for TKD's SCYTHE kill route)
Original code: `local hasBattered = battered or false` (a global, never reliably set).
Replaced with composite affliction check — `mind batter` lands stupidity + epilepsy + dizziness:
```lua
local battered = has("stupidity") and has("epilepsy") and has("dizziness")
```

---

## Dropped (vs original Levi)

| What | Why dropped |
|---|---|
| `tekura.parry.*` (parseCombo / onAttack / onParry / queue tracking) | AK already gives us `targetparry`. The custom queue tracking ~230 lines is redundant. |
| `tekura6._eventHandler` ("limb hits updated") | Replaced with static `monk.tekura.limbDamage` table. Calibrate via `tkcalibrate` like Shikudo. |
| `combatQueue()` prefix | Legacy handles pre-attack hooks externally. |
| `ataxia.playersHere` target presence check | Trust that the user issued `tar X` only against a present target. |
| `tCity` / Mhaldor `incapacitate` branch | Same as Shikudo — always proceed with the kill move. |

---

## Public API

### `monk.tekura.*` — data
| Symbol | Purpose |
| --- | --- |
| `CONFIG` | Tunables (thresholds, kai mode, debug toggle, etc.) |
| `state` | Runtime mutable state |
| `mode` | Current mode string: `"tkd"` or `"tk6"` |
| `limbDamage` | Static per-attack limb-break progress %, flat (not HP-based) |
| `PHASES.TKD` / `PHASES.TK6` | Phase enums for each mode |

### `monk.tekura.*` — functions
| Symbol | Called from |
| --- | --- |
| `setMode(mode)` | Aliases |
| `dispatch()` | Aliases (main entry) |
| `status()` | Aliases |
| `reset()` | Aliases |
| `toggleScythe()` | `tkscythe` alias |

### Top-level aliases
`tk` (current mode), `tkd` (3-limb), `tk6` (6-limb), `tkstatus`, `tkreset`,
`tkscythe`, `tk6debug`, `tkcal` (calibration).

---

## Open Decisions

- [ ] Naming: keep TKD/TK6 as mode strings (`"tkd"`/`"tk6"`) or rename (`"3limb"`/`"6limb"`)?
- [ ] Aliases: keep original `tkd`, `tk6` style or `tktkd`, `tktk6`?
- [ ] Default mode: TK6 (newer, more capable) or TKD (simpler)?
- [ ] SCYTHE: keep in TKD as a third mode trigger, or drop entirely (user can mind scythe manually)?
