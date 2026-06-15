# Shikudo God Mode - Legacy / AK Port

Fresh port of LEVI/Ataxia `009_CC_Shikudo_GodMode.lua`.

The previous consolidated Shikudo port has been removed. This module is now
GodMode-only: 5-limb prep, Gaital execute, lock fork, low-HP Maelstrom fork.

## Entry Points

| Function | Purpose |
| --- | --- |
| `monk.shikudo.arm()` | Fires now if balance/equilibrium are up; otherwise arms one GodMode hit for the next balance timer |
| `monk.shikudo.on_balance(interval)` | Balance/equilibrium-used trigger hook for timer-based arming |
| `monk.shikudo.dispatch()` | Runs GodMode immediately |
| `monk.shikudo.godmode.run()` | Runs GodMode directly |
| `monk.shikudo.status()` | GodMode status |
| `monk.shikudo.godmode.status()` | GodMode status directly |
| `monk.shikudo.reset()` | Clears module-local GodMode flags |
| `skgodmode()` | Alias wrapper: arm GodMode |
| `skstatus()`, `skgmstatus()` | Alias wrappers: status |
| `skreset()` | Alias wrapper: reset |

Compatibility wrappers `skdispatch()`, `sklock()`, and `skriftlock()` now warn and
run GodMode. The old dispatch, lock, and riftlock engines are intentionally gone.

## Legacy / AK Mappings

| LEVI / Ataxia | Legacy / AK |
| --- | --- |
| `haveAff("x")`, `tAffs.x` | `affstrack.score[x] >= monk.shikudo.CONFIG.affThreshold` |
| `tAffs.shield` | `ak.defs.shield` or `affstrack.score.shield` |
| `lb[target].hits[limb]` | unchanged |
| `ataxiaTemp.parriedLimb` | `targetparry` |
| `ataxiaTemp.lastAssess` | `ak.currenthealth / ak.maxhealth * 100` |
| `ataxiaTemp.hyperLimb` | `ak.limbs.hyperfocus` (`nil` / `false` / `"none"` means no hyperfocus) |
| `ataxia.vitals.form/kata/kai` | `gmcp.Char.Vitals.charstats` |
| `ataxia.vitals.hp/mp/maxhp/maxmp` | `gmcp.Char.Vitals` |
| balance/equilibrium up | `gmcp.Char.Vitals.bal == "1"` and `gmcp.Char.Vitals.eq == "1"` |
| `ataxia.defences.kaiboost` | `Legacy.Curing.Defs.current.kaiboost` |
| `ataxia.afflictions.stupidity` | `Legacy.Curing.Affs.stupidity` |
| `ataxia.settings.paused` | `Legacy.Settings.Curing.status == false` |
| `ataxiaBasher.enabled` | `Legacy.Settings.Basher.status` |
| `combatQueue()` | removed; Legacy pre-attack hooks live outside this module |
| `queue addclear eqbal <cmd>` | `SETALIAS ATK <cmd>` + `QUEUE ADDCLEARFULL EQBAL ATK` |
| `ataxia_needLockBreak()` / `ataxia_lockBreak()` | module-local monk fitness lock-break |

## Tunables

Override these after loading the file:

```lua
monk.shikudo.CONFIG.affThreshold = 30
monk.shikudo.CONFIG.godmodePrepThreshold = 92
monk.shikudo.CONFIG.godmodeHeadPrepThreshold = 86
monk.shikudo.CONFIG.godmodeLockForkMinAffs = 3
monk.shikudo.CONFIG.godmodeMaelstromHpThresh = 38
monk.shikudo.CONFIG.separator = "/"
monk.shikudo.CONFIG.aliasName = "ATK"
monk.shikudo.CONFIG.prearmInterval = nil  -- nil uses getNetworkLatency(), fallback 0.1s
monk.shikudo.CONFIG.debug = true
```

`monk.shikudo.limbDamage` contains the static percent damage table used for all
prep and light/no-light decisions. Recalibrate with `calibrate.lua` if your live
numbers differ. The calibrator emits a standalone `monk.shikudo.limbDamage = { ... }`
assignment with the exact lower-case keys read by this module. Missing, zero, or
negative calibration results are left at the currently loaded/default value with
an inline comment, so the printed table stays valid Lua.

`calibrate.lua` does not assume you have enough kata for balance-free form
switching. For each test it queues `adopt <form> form`, waits
`skCalibrate.formSwitchDelaySeconds` (default `4.1`), snapshots the limb, then
queues the calibration combo. Increase that delay if your form switch is slower.

## Required Mudlet Wiring

The module self-registers nothing. Wire aliases and the balance/equilibrium-used
trigger by hand:

| Alias | Script |
| --- | --- |
| `skgodmode` | `skgodmode()` |
| `skstatus` | `skstatus()` |
| `skgmstatus` | `skgmstatus()` |
| `skreset` | `skreset()` |

| Trigger | Script |
| --- | --- |
| `^(Balance|Equilibrium) used: (\d+\.\d+)s\.$` | `monk.shikudo.on_balance(tonumber(matches[3]))` |

AK must provide target affliction scores, target limb hits, target HP, target
parry, and hyperfocus state. Legacy must provide self curing settings, self
afflictions, self defences, and GMCP vitals/charstats.

Telepathy state is optional but recommended:

```lua
monk.telepathy.mindlocked = true  -- on successful mind lock
monk.telepathy.mindlocked = false -- when mind lock drops
```

Without that trigger state, the module may retry `mind lock <target>` more often.

Hyperfocus is not mirrored locally. AK's `ak.limbs.hyperfocus` is the source of
truth; the game-side setting persists until `hyperfocus none`. GodMode only sends
`hyperfocus <limb>` when the target is parrying a limb in the selected combo, and
sends `hyperfocus none` once the selected combo no longer needs the current focus.
