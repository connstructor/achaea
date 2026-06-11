# Target Lock Box — Legacy/AK Port Dependencies

Class-agnostic display port of LEVI's `ataxia_showTargetLocks()`. Prints an ASCII
textbox of which locking afflictions the current target has, per lock type.

## Deliverables
- `locks.lua` — consolidated module (namespace `locks`).
- `DEPENDENCIES.md` — this file.

(No `calibrate.lua` — not a limb-damage system; nothing to calibrate.)

## Canonical mappings

| Levi / Ataxia | Legacy / AK | Status |
|---|---|---|
| `haveAff("X")` | `has("X")` → `affstrack.score[X] >= CONFIG.affThreshold (30)` | ✅ |
| `getAffProbabilityV3("X")` (0.0–1.0) | `score("X")` = `affstrack.score[X]` (0–100) | ✅ |
| `target` (current target name) | unchanged (AK global) | ✅ |
| `cecho`, `string.*`, `ipairs` | unchanged (Mudlet / Lua builtins) | ✅ |
| `ataxia.lockDefs` | `locks.lockDefs` (self-contained) | ✅ |

Matches the `has()` / `affstrack.score` convention of the `tekura`, `shikudo`, and
`dwc_runie` ports (same `affThreshold = 30`).

## Colour model
AK `affstrack.score[aff]` is a 0–100 confidence value (100 = fresh apply). It
replaces V3's 0.0–1.0 probability used in the original:

- `< 30`  → missing (gray, ✗)
- `30–89` → present but uncertain (yellow, ✓)
- `>= 90` → present & certain (green, ✓)

Tunable via `locks.CONFIG.affThreshold` / `locks.CONFIG.certainThreshold`.

## Alias
Self-registering, reload-safe: `^t?locks(?:\s+(\S+))?$` → `locks.show(matches[2])`
(`tlocks` / `locks`, optional name arg; defaults to `target`). Manual-setup
variant: delete the alias block in `locks.lua` and bind `locks.show()` by hand.

## Open decisions / TODO
- [ ] **Class-specific lock aff row** (weariness / voyria / haemophilia / …):
      needs an AK source for target class — `ataxiaNDB_getClass` has no AK mapping
      yet. Omitted for now.
- [ ] **Limb locks** (Riftlock / Salvelock): need AK keys for broken/mangled-arm
      states before they can be added to `locks.lockDefs`.
- [ ] **Confirm `affstrack.score` table name/shape** in this AK profile (assumed
      identical to the tekura/shikudo/dwc_runie ports).
- [ ] **Lock-type naming** follows `lock_types.md` (Softlock → Venomlock →
      Truelock), not the V3 code's "hardlock" label. Confirm preference.
