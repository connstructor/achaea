# Shikudo Consolidation — Legacy / AK Port

Mapping doc for porting the four CC scripts to **Legacy** (self combat framework) + **AK** (enemy limb & affliction tracker).

**Source files (consolidating):**
- `src_new/scripts/.../shikudo/006_CC_Shikudo_Dispatch.lua` — limb-prep dispatch
- `src_new/scripts/.../shikudo/007_CC_Shikudo_Lock.lua` — telepathy lock
- `src_new/scripts/.../shikudo/008_CC_Shikudo_Offense_ALL.lua` — **source of truth** (dispatch + lock + riftlock modes)
- `src_new/scripts/.../shikudo/009_CC_Shikudo_GodMode.lua` — godmode (5-limb)

**Destination:** `ports/legacy_ak/shikudo/shikudo.lua` (1852 lines, syntax-clean).

**Strategy:** Inline replace — no shim layer. Final file contains zero `ataxia.*` / `ataxiaTemp.*` / `tAffs` / `lb` references.

---

## Status — 2026-05-27

✅ **Tier 1 (AK)** — DONE.
- `tAffs.X` / `haveAff("X")` → `has("X")` (reads `affstrack.score[X] >= AFF_THRESHOLD=30`).
- `lb[target].hits[limb]` — unchanged.
- `ataxiaTemp.parriedLimb` → `targetparry`.
- `ataxiaTemp.lastAssess` → `targetHpPct()` (`ak.currenthealth/maxhealth * 100`).
- `ataxiaTemp.hyperLimb` → `ak.limbs.hyperfocus`.
- `tCity` / Mhaldorian / incapacitate — removed.

✅ **Tier 2 (Legacy)** — DONE.
- `gmcp.Char.Vitals.charstats` parser (`charstat(name)`) for **Form / Kata / Kai**.
- `vital("hp")` etc. (with `tonumber`) for **hp / maxhp / mp / maxmp**.
- `eqUp()` for **balances.eq** (`gmcp.Char.Vitals.eq == "1"`).
- **Separator** → `"/"` everywhere, hardcoded.
- **Send pattern** → `sendAttack(cmd, "FREE"|"EQBAL")` helper that emits the
  `SETALIAS ATK <cmd>` + `QUEUE ADDCLEARFULL <queue> ATK` pair.
- **combatQueue()** — removed; Legacy handles pre-attack hooks externally.
- Self afflictions → `selfAff("X")` (reads `Legacy.Curing.Affs[X]`).
- Self defences → `Legacy.Curing.Defs.current.kaiboost` (et al).
- Paused → `Legacy.Settings.Curing.status == false`.
- Basher state → `Legacy.Settings.Basher.status` (read-only, no mutation).
- **Skill multiplier** → `shikudo.config.skillMultiplier` (default 1.0, Trans).
- **Kai surge window** → module-local `shikudo.state.kaiSurgeWindow` + helper
  `shikudo.startKaiSurgeWindow()` (15s tempTimer auto-clear). User needs to
  call from a trigger.
- **Lock break** → ported and collapsed to Monk-only: `selfNeedLockBreak()`
  checks asthma+anorexia+slickness|bloodfire; `selfLockBreak()` sends
  `fitness` (after `stand` if prone). 2s cooldown.

✅ **Tier 3 (mindlock state)** — DONE via new `monk.telepathy` namespace.
- `mindlocked` → `monk.telepathy.mindlocked` (set by trigger on
  "You complete the mind lock on X").
- `startingMindlock` → `monk.telepathy.starting_mindlock` (set when issuing
  `mind lock X`, cleared by a 3s tempTimer in the trigger).
- Until triggers are wired, lock/riftlock/godmode redundantly resend
  `mind lock X` each tick; the server rejects duplicates so it's safe.

✅ **Namespace consolidation** — DONE.
- All module-owned state under `monk.shikudo.*` (was bare `shikudo.*`).
- `shikudo_breakPoint()` → `monk.shikudo.breakPoint()`.
- `shikudo_limbDamage` → `monk.shikudo.limbDamage`.
- Aliases stay top-level (`skdispatch`, `sklock`, etc.) so they remain typeable
  from the Mudlet input line; each is a one-line wrapper over `monk.shikudo.*`.
- External globals untouched: `gmcp`, `ak`, `Legacy`, `target`, `lb`,
  `affstrack`, `targetparry`.

🟢 **Port status: complete.** 0 `TODO(legacy)` markers remaining.

✅ **Hyperfocus rule** — DONE.
- Rule: `hyperfocus head` iff `form == "Oak" AND targetparry == "head"`, else `hyperfocus none`.
- Source of truth: `ak.limbs.hyperfocus`. No local mirror.
- Per-tick: `hyperfocusFix()` emits the appropriate command at the front of
  the stack only when desired ≠ current. Idempotent: no command sent if
  state is already correct.
- Damage calcs (`getAttackDamage`, `getHeadPrepThreshold`) halve head
  damage iff `wantHyperfocus() == "head"`.
- Removed: `monk.shikudo.setHyperfocus(limb)`, `monk.shikudo.resetHyperfocus()`,
  `monk.shikudo.state.hyperfocus`, `monk.shikudo.state.hyperNeedsRaise`.
- Godmode is **safe under the new rule** — no threshold change needed.
  `CONFIG.godmodePrepThreshold = 92` is the **arm** prep threshold (drives
  `gm.laPREP/raPREP`, used by combo 2's `ruku + ruku` arm-break sequence).
  Head uses a separate hardcoded `gm.hPREP = (gm.H >= 86)` in `calcLimbs`,
  unrelated to CONFIG. The safety guards (`hNERVRIS`, `shouldLight`) all
  use unhalved damage values, so they're conservative across both
  hyperfocus states. Trade-off vs the old always-hyperfocus regime: one
  extra needle in execute combo 3 (96.6% → next tick → 107.2% break),
  which is negligible.

---

## Final Public API

Only these are exposed on the namespace. Everything else is file-local.

### `monk.shikudo.*` — data
| Symbol | Purpose |
| --- | --- |
| `CONFIG` | All tunables (thresholds, multipliers, item IDs, durations) — see below |
| `state` | Runtime mutable state (kick alternation, phase, blackout, kaiSurgeWindow…) |
| `mode` | Current mode string: `"dispatch"`, `"lock"`, `"riftlock"`, `"godmode"` |
| `formAttacks`, `transitions`, `maxKata` | Reference data tables |
| `limbDamage` | Static per-attack % HP damage table (target-independent post-normalization) |
| `godmode` | Sub-namespace for godmode public functions |

### `monk.shikudo.*` — functions
| Symbol | Called from |
| --- | --- |
| `setMode(mode)` | Aliases |
| `dispatch()` | Aliases (main entry; delegates to `godmode.run()` when mode=godmode) |
| `status()` | Aliases |
| `reset()` | Aliases |
| `startKaiSurgeWindow()` | Your kai-surge-fired trigger |
| `godmode.run()` | Delegated from `dispatch()` |
| `godmode.status()` | `skgmstatus` alias + `status()` |

### `monk.telepathy.*` — state
| Symbol | Trigger that sets it |
| --- | --- |
| `mindlocked` | "You complete the mind lock on X" → true; "X is no longer mind-locked" → false |
| `starting_mindlock` | Send `mind lock X` → true; 3s tempTimer → false |

### Top-level aliases (kept for typeability from Mudlet input line)
`skdispatch`, `sklock`, `skriftlock`, `skgodmode`, `skstatus`, `sklstatus`, `srlstatus`, `skgmstatus`, `skreset`, `srlreset` — each is a one-line wrapper.

---

## `monk.shikudo.CONFIG` — tunable knobs

```lua
monk.shikudo.CONFIG = {
  -- AK affstrack confidence threshold (0-100)
  affThreshold              = 30,
  -- Item ID for `wield`
  staffId                   = "staff489282",
  -- Kai surge window duration (seconds)
  kaiSurgeWindowDuration    = 15,
  -- Self lock-break cooldown (seconds)
  lockBreakCooldown         = 2,
  -- Godmode thresholds
  godmodePrepThreshold      = 92,
  godmodeLockForkMinAffs    = 3,
  godmodeMaelstromHpThresh  = 38,
}
```

---

## Internals (file-local — not exposed)

These were on `monk.shikudo.*` before the localization sweep. Now `local function X(...)`:

`getLimbDamage`, `getAttackDamage`, `hitsToPrep`, `isLimbPrepped`, `getLegPrepThreshold`, `getHeadPrepThreshold`, `isLegPreppedByName`, `areBothLegsPrepped`, `isDynamicHeadPrepped`, `getFocusLeg`, `getOffLeg`, `isHyperfocusSet`, `checkSoftlock`, `checkVenomlock`, `checkHardlock`, `checkTruelock`, `checkDispatchReady`, `selectTelepathy`, `selectKick`, `selectStaff`, `selectRainStaff`, `selectOakStaff`, `selectGaitalStaff`, `selectWillowStaff`, `selectMaelstromStaff`, `shouldTransition`, `buildCombo`

Inside the godmode do-block:

`calcLimbs`, `formswap`, `shouldLight`, `tykonosPrios`, `willowPrios`, `rainPrios`, `oakPrios`, `gaitalPrios`, `maelstromPrios` (all already / now local)

Top-of-file helpers (always local):

`charstat`, `vital`, `eqUp`, `has`, `targetHpPct`, `selfAff`, `selfNeedLockBreak`, `selfLockBreak`, `sendAttack`

---

## Tier 1 — Target State (AK domain)

These are read on every dispatch tick to decide what to attack.

| Levi symbol | Used for | Legacy/AK equivalent | Status |
| --- | --- | --- | --- |
| `target` (string) | Current target name | **same** (global `target`) | ✅ |
| `tCity` (string) | City check ("Mhaldor" → incapacitate vs dispatch) | **dropped** — always dispatch | ✅ |
| `tmounted` (bool) | Is target mounted? Affects sweep / Rain kai-surge | `affstrack.score.mounted` (presumed via affliction names match) | ⚠ confirm |
| `tAffs.prone` | Prone state — gates Gaital kill, spinkick, crescent | `affstrack.score.prone` | ✅ |
| `tAffs.shield` | Target has shield — switch to shatter combo | `affstrack.score.shield` | ✅ |
| `tAffs.asthma` | Lock building block | `affstrack.score.asthma` | ✅ |
| `tAffs.anorexia` | Lock building block | `affstrack.score.anorexia` | ✅ |
| `tAffs.slickness` | Lock building block | `affstrack.score.slickness` | ✅ |
| `tAffs.paralysis` | Venomlock | `affstrack.score.paralysis` | ✅ |
| `tAffs.impatience` | Hardlock | `affstrack.score.impatience` | ✅ |
| `tAffs.weariness` | Truelock | `affstrack.score.weariness` | ✅ |
| `tAffs.clumsiness` | Pressure aff | `affstrack.score.clumsiness` | ✅ |
| `tAffs.addiction` | Pressure / riftlock | `affstrack.score.addiction` | ✅ |
| `tAffs.lethargy` | Pressure (godmode wea+leth combo) | `affstrack.score.lethargy` | ✅ |
| `tAffs.healthleech` | Godmode 2-aff hit (ruku@10+) | `affstrack.score.healthleech` | ✅ |
| `tAffs.damagedhead` | Head break state (level-2 limb) | `affstrack.score.damagedhead` | ✅ |
| `tAffs.damagedleftleg` / `damagedrightleg` | Leg break states | `affstrack.score.damagedleftleg` / `…rightleg` | ✅ |
| `tAffs.damagedleftarm` / `damagedrightarm` | Arm break states | `affstrack.score.damagedleftarm` / `…rightarm` | ✅ |
| `tAffs.damagedwindpipe` / `crushedthroat` | Dispatch kill condition | `affstrack.score.damagedwindpipe` / `…crushedthroat` | ✅ |
| `tAffs.mounted` | Same as `tmounted` (duplicate path) | `affstrack.score.mounted` | ✅ |
| `haveAff(name)` → bool | V3 probability threshold lookup (≥30%) | Replace inline with `affstrack.score.<name>` truthiness check | ✅ |
| `lb[target].hits["head"]` (number 0-200) | Head damage % | **same** (`lb[target].hits["head"]`) | ✅ |
| `lb[target].hits["left leg"]` | Left leg damage % | **same** | ✅ |
| `lb[target].hits["right leg"]` | Right leg damage % | **same** | ✅ |
| `lb[target].hits["left arm"]` | Left arm damage % | **same** | ✅ |
| `lb[target].hits["right arm"]` | Right arm damage % | **same** | ✅ |
| `lb[target].hits["torso"]` | Torso damage % | **same** | ✅ |
| `ataxiaTemp.parriedLimb` | Last limb the target parried — drives kick/staff redirection | `targetparry` (global) | ✅ |
| `mindlocked` (bool global) | Telepathy mindlock established? | | ❓ |
| `startingMindlock` (bool global) | Mindlock attempt in flight | | ❓ |
| _(new)_ Target HP% for Maelstrom override | Used to be `ataxiaTemp.lastAssess` (a 0-100 percent) | `math.floor(ak.currenthealth / ak.maxhealth * 100)` | ✅ |

---

## Tier 2 — Self State (Legacy domain)

| Levi symbol | Used for | Legacy/AK equivalent | Status |
| --- | --- | --- | --- |
| `ataxia.vitals.form` | Current Shikudo form (Tykonos/Willow/Rain/Oak/Gaital/Maelstrom) | | ❓ |
| `ataxia.vitals.kata` | Current kata count in form | | ❓ |
| `ataxia.vitals.kai` | Kai energy (used by godmode kai boost, kai surge) | | ❓ |
| `ataxia.vitals.class` (= kai for Monk) | Same value — `shikudoLock.getKai()` reads this | | ❓ |
| `ataxia.vitals.hp` / `.maxhp` | Transmute calc | | ❓ |
| `ataxia.vitals.mp` / `.maxmp` | Transmute calc | | ❓ |
| `ataxia.balances.eq` | Equilibrium available for telepathy? | | ❓ |
| `ataxia.afflictions.stupidity` | Self has stupidity → skip tick | | ❓ |
| `ataxia.defences.kaiboost` | Self has kaiboost defence? | | ❓ |
| `ataxia.shikudoLevel` | Skill multiplier for `shikudo_breakPoint` (Trans=1.0, Mythical=1.x) | | ❓ |
| `ataxia.settings.paused` | Combat paused | | ❓ |
| `ataxia.settings.separator` | Command separator (`;` or `::`) | | ❓ |
| `ataxia.debug` | Debug echo toggle | | ❓ |
| `ataxiaBasher.enabled` | Autobashing — suppress debug echo | | ❓ |
| `ataxia.playersHere` | Players-in-room check (currently commented out) | | ❓ |

---

## Tier 3 — Script-internal Temp State

These can stay local to the consolidated module unless Legacy/AK already tracks one (e.g. `parriedLimb`, `hyperLimb` likely belong to AK / the Monk class module).

| Levi symbol | Owner | Keep local OR map? |
| --- | --- | --- |
| `ataxiaTemp.kickTarget` | Set by `selectKick`, read elsewhere | Local |
| `ataxiaTemp.slot1Target` | Set by `selectStaff(1)`, read by `selectStaff(2)` | Local |
| `ataxiaTemp.lastFrontkickArm` / `.frontkickWasParried` | Rain frontkick alternation | Local (state machine) |
| `ataxiaTemp.lastFlashheelLeg` / `.flashheelWasParried` | Willow/Gaital flashheel alternation | Local |
| `ataxiaTemp.lastAssess` | Last seen target HP% | ❓ AK likely tracks |
| `ataxiaTemp.targetHP` | Target HP for Maelstrom crescent | ❓ AK likely tracks |
| `ataxiaTemp.kaiSurgeWindow` | "Target can't remount" 15s window | Local (timer) |
| `ataxiaTemp.hyperLimb` | Current hyperfocus limb | ❓ Monk class state |
| `ataxiaTemp.hyperNeedsRaise` | Need to re-hyperfocus after sweep | Local |
| `ataxiaTemp.shikCombo` | Combo introspection cache (used by triggers) | Skip — not used by dispatch |
| `ataxiaTables.limbData.shik{Ruku,Kuro,Flashheel,Needle,Nervestrike,Hiru,Hiraku,Risingkick,Frontkick}` | Per-attack % damage table | Local — built by `shikudo_breakPoint` |
| `shikudo_limbDamage` | Same as above, alternate access | Local — same table |

---

## Tier 4 — Helper Functions

| Levi symbol | Purpose | Legacy/AK equivalent | Status |
| --- | --- | --- | --- |
| `combatQueue()` → string | Pre-queued combat commands (defences, herbs, etc.) | | ❓ |
| `reboundHold.gate(fn)` → bool | Rebound-hold gate (defers attack while we have rebounding) | | ❓ |
| `ataxia_needLockBreak()` → bool | Self is locked? | | ❓ |
| `ataxia_lockBreak()` | Send lock-break sequence | | ❓ |
| `shikudo_breakPoint(hp)` | Build damage table | Local — keep as helper |
| `cecho(...)` / `send(...)` | Mudlet built-ins | Keep |

---

## Tier 5 — Sends / Commands

These are commands written to the MUD; mostly verbatim Achaea syntax. Mainly need to confirm Legacy's queue dispatch syntax.

| Levi send | Description | Legacy equivalent | Status |
| --- | --- | --- | --- |
| `send("queue addclear free " .. cmd)` | Atomic queue replace (free balance) | | ❓ |
| `send("queue addclear eqbal " .. cmd)` | Atomic queue replace (eqbal) | | ❓ |
| `wield staff489282` | Hard-coded wield by item ID | ❓ Legacy wield helper? Or keep ID? | ❓ |
| `combo <tar> kick staff1 staff2` | Standard combo | Probably identical (Achaea command) | ✅ |
| `dispatch <tar>` / `incapacitate <tar>` | Kill commands | Achaea native | ✅ |
| `hyperfocus head/none/<limb>` | Hyperfocus | Achaea native | ✅ |
| `mind lock <tar>` | Telepathy lock | Achaea native | ✅ |
| `impatience <tar>` / `batter <tar>` / `paralyse <tar>` / `blackout <tar>` | Telepathy attacks | Achaea native | ✅ |
| `transmute <amount>` | HP/MP transmute | Achaea native | ✅ |
| `kai boost` / `kai surge <tar>` | Kai abilities | Achaea native | ✅ |
| `transition to the <form> form` / `adopt <form> form` | Form change | Achaea native | ✅ |

---

## Tier 6 — Trigger-fed State (out of scope for dispatch file, but noted)

These are populated by triggers we're NOT porting (yet). The consolidated file READS them — if AK fills them, great; if not, they remain TODO.

- Limb damage hits (every staff/kick that landed → `lb[target].hits[limb] += dmg`)
- Parried limb capture (e.g. "X parries your strike at his left leg" → `ataxiaTemp.parriedLimb = "left leg"`)
- Hyperfocus state ("You focus your awareness on X's head" → `ataxiaTemp.hyperLimb = "head"`)
- Frontkick / flashheel parry flags (set by parry triggers, consumed by selector)
- Kai surge window (15s after kai surge fires → blocks remount)

---

## Open Decisions

- [ ] Wield syntax — keep `wield staff489282` (specific item) or generalise to `wield staff`?
- [x] File layout — one big `shikudo.lua` (consolidated, 1852 lines).
- [x] Aliases — kept as-is: `skdispatch`, `sklock`, `skriftlock`, `skgodmode`, `skstatus`, `sklstatus`, `srlstatus`, `skgmstatus`, `skreset`.
- [x] `shikudo_findCombo` / `shikudo_lightAttack` / `shikudo_checkForms` — dropped (trigger-side only, not used by dispatch).

---

## TODO Punch List (Tier 2-4, in priority order)

### A. Shikudo form state  ⭐ HIGH (used ~10x)
- `ataxia.vitals.form` — current form: Tykonos / Willow / Rain / Oak / Gaital / Maelstrom
- `ataxia.vitals.kata` — current kata count (0-12, or 0-24 for Rain)

### B. Vitals  ⭐ HIGH (godmode transmute + kai surge)
- `ataxia.vitals.hp` / `.maxhp`
- `ataxia.vitals.mp` / `.maxmp`
- `ataxia.vitals.kai` — kai energy

### C. Command separator  ⭐ HIGH (3 occurrences)
- `ataxia.settings.separator` — `";"` (dispatch) or `"::"` (godmode `cq all`-style chains)

### D. EQ balance flag  ⭐ HIGH (telepathy gate)
- `ataxia.balances.eq` — is EQ up?

### E. Combat queue hook  ⭐ HIGH (2 occurrences)
- `combatQueue()` — returns string of pre-attack commands (defences, herbs, etc.)

### F. Wield staff  ⭐ MEDIUM (3 occurrences)
- `wield staff489282` — hardcoded item ID. Generalise to `wield staff`?

### G. Self afflictions  • MEDIUM
- `ataxia.afflictions.stupidity` — skip-tick gate

### H. Self defences  • MEDIUM
- `ataxia.defences.kaiboost` — already have kaiboost?

### I. Combat settings  • MEDIUM
- `ataxia.settings.paused` — pause gate

### J. Skill multiplier  • MEDIUM
- `ataxia.shikudoLevel` — feeds `shikudo_breakPoint()` damage calc

### K. Basher state  • LOW (debug suppression only)
- `ataxiaBasher.enabled` — true → don't echo debug

### L. Hyperfocus state (read)  • LOW (godmode only)
- `ataxiaTemp.hyperLimb` — current self hyperfocus limb. Read by godmode to skip the "set hyperfocus head" step.

### M. Kai surge window  • LOW (Gaital only)
- `ataxiaTemp.kaiSurgeWindow` — set by a kai-surge-fired trigger; clears after 15s.

### N. Self lock break  • LOW
- `ataxia_needLockBreak()` / `ataxia_lockBreak()` — only used in godmode early-exit guard.

### Z. Deferred (mindlock)  🛑 TODO
- `mindlocked` — Telepathy lock established on target.
- `startingMindlock` — mindlock attempt in flight.
