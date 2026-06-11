# Blademaster Consolidation — Legacy / AK Port

Mapping doc for porting the Blademaster Ice-Dispatch combat system to
**Legacy** (self combat framework) + **AK** (enemy limb & affliction tracker).

**Source file (source of truth):**
- `src_new/scripts/.../blademaster/005_CC_BM_Ice.lua` — unified dispatch, 4 strategies

**Legacy files NOT ported (superseded by 005):**
- `001_Logic.lua` (`isActive:'no'`) — `bmstriking` / `bmstriking2` / `bmstriking4`,
  `bmgrouplock`, `levibmtruelock`, `getCharstat`, `tbleeding`
- `002_Attack.lua` (`isActive:'no'`) — `bm_attack`
- `003_BrokenStar.lua` (`isActive:'no'`) — `bm_brokenstarroute` / `bm_brokenstarroute2`
- `004_Group.lua` (`isActive:'yes'`, but calls `bmgrouplock()` from the inactive
  001 file — effectively orphaned) — `bm_groupfighting`

005's four strategies (`double` / `quad` / `brokenstar` / `group`) cover the same
ground as the legacy files. The richer truelock-progression strike order in
001's `levibmtruelock` is **not** reproduced — 005's `group` mode uses the
simpler hamstring → para → asthma → slickness → anorexia → class-lock →
hypochondria → sternum ladder. See Open Decisions.

**Destination files:**
- `blademaster.lua` — the module (pure logic; self-registers nothing)
- `MUDLET_SETUP.md` — every alias / trigger / event handler to add by hand
- `calibrate.lua` — optional per-stance damage calibrator (`bmcal`)
- `DEPENDENCIES.md` — this mapping doc

**Strategy:** Inline replace — no shim layer. Final file contains zero
`ataxia.*` / `ataxiaTemp.*` / `tAffs` / `haveAff()` / `combatQueue()` references
in code (only in this doc + the in-file mapping header). `lb[target].hits[limb]`
is preserved (both Levi and AK use it).

**No self-registration:** unlike the other ports, this module does **not**
self-install aliases/triggers/handlers (`tempAlias` / `tempRegexTrigger` /
`registerAnonymousEventHandler` all removed per user preference). It exposes the
handler + callback functions only; you wire them to manually-created Mudlet items
per `MUDLET_SETUP.md`.

**JIT dispatch model (replaces `attackInFlight`):** the old anti-desync latch +
GMCP balance handler are gone. Now the alias **arms** the system (`blademaster.arm()`,
fires immediately if eqbal — balance AND eq — is up, via `CONFIG.fireWhenReady`), and a
balance/equilibrium-**used** trigger calls `blademaster.scheduleDispatch(recoverTime)`,
which arms a `tempTimer` for `recoverTime - getNetworkLatency()*CONFIG.latencyMultiplier`.
On expiry, if still armed, it runs the dispatch with **current** state and disarms
(one shot per arm). That used-trigger is **required** to fire attacks. The dispatch
timer is the only `tempTimer` the module uses (created on demand, not a registered
hook). State: `armed` + `dispatchTimer` replace `attackInFlight`.

---

## Status — 2026-05-28

✅ **Tier 1 (AK)** — DONE.
- `haveAff("X")` → `has("X")` (`affstrack.score[X] >= CONFIG.affThreshold=30`),
  routed through the preserved `blademaster.hasAff()` so every call site is unchanged.
- `getAffProbabilityV3` / `blademaster.getAffProb` → **dropped** (was never read
  by dispatch logic; only added during the V3 integration).
- `getTrackingSystem()` → returns `"AK"` (status panels show `Track: AK`).
- `lb[target].hits[limb]` → unchanged, but keyed by **raw `target`** (AK
  convention; the source capitalized the first letter via
  `target:lower():gsub("^%l", string.upper)` — dropped).
- `tparrying or ataxiaTemp.parriedLimb` → `targetparry` (global) via `blademaster.getParried()`,
  which normalizes AK's no-space limb names (`leftleg`…) to the spaced form the logic uses.
- `tmounted` → `has("mounted")` (4 sites, inlined).
- `ataxiaTemp.targetHP` → `targetHpPct()` (`ak.currenthealth/maxhealth*100`).
- `tAffs` / `(tAffs and tAffs.shield)` belt-and-suspenders fallback → **dropped**
  (no V1 table in AK; `has("shield")`/`has("rebounding")` already read `affstrack`).
- `ataxia.playersHere` presence check → **dropped** (trust the user's `tar X`).

✅ **Tier 2 (Legacy)** — DONE.
- `ataxia.afflictions.aeon` → `selfAff("aeon")` (`Legacy.Curing.Affs.aeon`).
- `ataxia_needLockBreak()` / `ataxia_lockBreak()` → `selfNeedLockBreak()` /
  `selfLockBreak()`. Checks asthma+anorexia+(slickness|bloodfire); sends
  `CONFIG.lockBreakCommand` (default `fitness`) after `stand` if prone. 2s cooldown.
- `reboundHold.gate(fn)` → `blademaster.reboundGate(fn)` (stub, returns false;
  user-override point).
- `combatQueue()` prefix → **removed** (Legacy handles pre-attack hooks externally).
- `send("queue addclear freestand " .. cmd)` → `sendAttack(cmd, "FREESTAND")`
  emitting the `SETALIAS ATK <cmd>` + `QUEUE ADDCLEARFULL FREESTAND ATK` pair.
- `engaged` (bare global) → `blademaster.state.engaged`, reset on target change;
  `;engage <target>` appended to the first attack of each fight (gated by
  `CONFIG.engageOnFirst`).
- `getShin()` → unchanged in spirit; now reads via the shared `charstat("Shin")`
  parser (pure GMCP `Char.Vitals.charstats`).
- `getLockingAffliction()` → **kept, guarded** (`if getLockingAffliction then`).
  No-ops gracefully if your profile doesn't define it (group mode only).
- Paused → `isPaused()` (`Legacy.Settings.Curing.status == false`). **NOTE:** 005
  never gated on pause; this guard is an addition for parity with the other
  ports. It's safe (blocks only when status is explicitly `false`).
- `blademaster.config` → renamed `blademaster.CONFIG` (port-family convention),
  plus new knobs (`affThreshold`, `airfistShinCost`, `lockBreakCommand`,
  `lockBreakCooldown`, `echoDebounce`, `debugEcho`, `queueType`, `engageOnFirst`).
- Per-hit damage → **stance-keyed** `blademaster.limbDamage[stance]` (was single
  `state.*Damage` fields). `getStance()`/`stanceLd()` route every read + capture
  write through the active stance. See "Damage estimates" below.

🟢 **Port status: complete.** Syntax-clean (`luac -p`). 0 unmapped Levi refs in code.

---

## Final Public API

Only these are exposed on the namespace. Everything else is file-local.

### `blademaster.*` — data
| Symbol | Purpose |
| --- | --- |
| `CONFIG` | All tunables (thresholds, durations, shin cost, lock-break cmd, queue, debug) |
| `state` | Runtime mutable state (mode, phase tracking, damage estimates, brokenstar state) |
| `dispatch` | Namespace for `run*` / `status*` functions |
| `lockAffToStrike` | getLockingAffliction()-name → pommelstrike location (group mode) |
| `damageCapture` | Internal pending-primary buffer for the two-hit P/S damage capture |

### `blademaster.*` — functions
| Symbol | Called from |
| --- | --- |
| `setMode(m)` | optional — set mode without dispatching |
| `run()` | unified entry (guards + mode routing) |
| `fullReset()` | `bmreset` alias |
| `dispatch.runDoublePrep/runQuadPrep/runBrokenstar/runGroup()` | `run()` |
| `dispatch.statusDoublePrep/statusQuadPrep()` | `bmstatus` / `bmstatusq` |
| `reboundGate(fn)` | override-point for your rebound-hold logic |
| `hasAff` / `getLimbDamage` / `getLL…getHead` / `check*` / `getFocus*` / `calculate*Path` / `getShin` / `needsAirfist` / `select*` / `getCentreslashDirection` / `getParried` | internal dispatch helpers (kept on namespace as in source) |
| `on*` callbacks (`onImpaleSuccess`, `onBleedingUpdate`, …) | the combat-text triggers |

### Top-level alias handlers (point manually-created Mudlet aliases at these)
`bm`, `bmd` / `bmdispatch`, `bmdq` / `bmdispatchquad`, `bmbs` / `bmdispatchbs`,
`bmgroup`, `bmreset`, `bmstatus`, `bmstatusq` — each a one-line wrapper that sets
`state.mode` and calls `run()`. **The module no longer self-registers aliases** —
create them by hand per **`MUDLET_SETUP.md`**.

---

## `blademaster.CONFIG` — tunable knobs

```lua
blademaster.CONFIG = {
  affThreshold             = 30,          -- AK affstrack threshold (0-100)
  breakThreshold           = 100,         -- limb % for "broken"
  prepThreshold            = 90,          -- limb % for "prepped"
  killHealthThreshold      = 30,          -- (reference; HP% for burst)
  hamstringDuration        = 10,          -- re-strike hamstring after N seconds
  proneTimerDuration       = 9,           -- vestigial prone window (balanceslash removed)
  balanceslashThreshold    = 4,           -- vestigial
  brokenstarBleedThreshold = 700,         -- bleeding for brokenstar execution
  airfistShinCost          = 25,          -- 20 shin + 5 infuse
  lockBreakCommand         = "fitness",   -- self lock-break (asthma cure); override per profile
  lockBreakCooldown        = 2,           -- seconds between lock-break attempts
  echoDebounce             = 0.3,         -- echo spam guard (seconds)
  debugEcho                = true,        -- per-tick debug echo
  queueType                = "FREESTAND", -- Legacy queue for sendAttack
  engageOnFirst            = true,        -- append ";engage <target>" on first attack
}
```

---

## Tier 1 — Target State (AK domain)

| Levi symbol | Used for | Legacy/AK equivalent | Status |
| --- | --- | --- | --- |
| `target` (string) | Current target name | **same** (global `target`) | ✅ |
| `haveAff("X")` | All affliction checks (via `blademaster.hasAff`) | `has("X")` → `affstrack.score[X] >= 30` | ✅ |
| `lb[target].hits[limb]` (0-200) | Limb damage % (legs/arms/torso/head) | **same** (raw `target` key) | ✅ |
| `tparrying` / `ataxiaTemp.parriedLimb` | Last limb parried — focus/airfist logic | `targetparry` (global). AK uses **no-space** limb names (`leftleg`, `rightarm`, …); `getParried()` normalizes them to the spaced form (`"left leg"`) the dispatch logic compares against. | ✅ |
| `tmounted` | Mounted? — dismount-before-double-break | `has("mounted")` | ⚠ confirm AK tracks `mounted` |
| `ataxiaTemp.targetHP` | Target HP% (display only) | `targetHpPct()` | ✅ |
| `ataxiaTemp.lastAssess` | (legacy 004 only; not in 005) | n/a | ✅ |
| `getAffProbabilityV3` | (V3 only; unused by dispatch) | dropped | ✅ |

## Tier 2 — Self State (Legacy domain)

| Levi symbol | Used for | Legacy/AK equivalent | Status |
| --- | --- | --- | --- |
| `ataxia.afflictions.aeon` | Skip-tick gate | `selfAff("aeon")` | ✅ |
| `ataxia_needLockBreak()` / `ataxia_lockBreak()` | Self lock-break before attack | `selfNeedLockBreak()` / `selfLockBreak()` | ✅ |
| `reboundHold.gate(fn)` | Defer attack while we have rebounding | `blademaster.reboundGate(fn)` stub | ⚠ user-override |
| `combatQueue()` | Pre-attack chain | **removed** — Legacy handles externally | ✅ |
| `engaged` (global) | Engage-on-first-attack | `blademaster.state.engaged` | ✅ |
| `gmcp Char.Vitals.charstats "Shin:"` | Shin for airfist/flamefist | `charstat("Shin")` via `getShin()` | ✅ |
| `getLockingAffliction()` | Class lock aff (group mode) | kept, guarded | ⚠ optional |
| _(none — 005 never gated on pause)_ | Combat paused | `isPaused()` **added** for port-family consistency (`Legacy.Settings.Curing.status == false`) | ➕ |
| `ataxia.playersHere` | Players-in-room presence | dropped (trust `tar X`) | ✅ |

## Tier 3 — Helper Functions (top-of-file, file-local)

`has`, `targetHpPct`, `charstat`, `vital`, `eqUp`, `selfAff`, `selfNeedLockBreak`,
`selfLockBreak`, `isPaused`, `sendAttack`, `progressBar`.

`blademaster.reboundGate` is public so you can override it.

## Tier 4 — Commands (Achaea verbatim, unchanged)

`infuse lightning|ice`, `legslash <t> <l/r>`, `armslash <t> <l/r>`,
`centreslash <t> up|down`, `raze <t>`, `airfist <t>`, `flamefist <t>`,
`pommelstrike <t> <location>`, `impale <t>`, `impaleslash <t>`, `bladetwist`,
`withdraw <t>`, `brokenstar <t>`, `assess <t>`, `discern <t>`, plus strike
locations (`hamstring`, `neck`, `chest`, `shoulder`, `ears`, `knees`, `feet`,
`sternum`, `throat`, `underarm`, `stomach`, `eyes`, `temple`, `groin`).

---

## Trigger-fed State (callbacks kept; triggers created MANUALLY)

Blademaster's brokenstar progression and per-hit damage estimates are
**class-specific** and not provided by AK, so the module keeps the callback
functions (`blademaster.on*` / `capture*`). **The triggers themselves are NOT
self-registered** — per the user's preference there is no `tempRegexTrigger`
block. Create each trigger by hand (Perl regex) and point its script at the
callback; full patterns + scripts are in **`MUDLET_SETUP.md`**. The callbacks
read the trigger's `matches` and never write to `lb[target]` (AK still owns that).

| Trigger | Pattern (abridged) | Callback |
| --- | --- | --- |
| leg damage | `you have dealt N% damage to … (left/right) leg` | `captureLegDamage` (P/S two-hit capture) |
| arm damage | `… (left/right) arm` | `captureArmDamage` |
| upper damage | `… (torso/head)` | `captureUpperDamage` |
| leg salve | `takes some salve … rubs it on … legs` | `onLegSalveDetected` (prone timer) |
| impale | `plunge it deep into the body of X impaling … to the hilt` | `onImpaleSuccess` |
| impaleslash | `drag its razor edge across arteries within X's abdomen` | `onImpaleslashSuccess` |
| bleeding ready | `heavy torrents of lifeblood spilling from X's near-fatal wounds` | `onBleedingReady` |
| withdraw | `You wrench your blade free of X` | `onWithdrawSuccess` |
| writhe | `manages to writhe Xself free of the weapon which impaled` | `onTargetUnimpaled` |
| bleeding update | `You observe … [N]` | `onBleedingUpdate` |
| stand up | `X stands up.` | `onTargetStandUp` |
| bladetwist | `BLADETWIST [|] BLADETWIST [|] BLADETWIST` | `onBladetwistSuccess` |

Attack firing is driven by a balance/equilibrium-**used** trigger →
`blademaster.scheduleDispatch(recoverTime)` (the `tempTimer` JIT model above), not
by a GMCP balance handler. That trigger is **REQUIRED** and is created manually
(see `MUDLET_SETUP.md`). Without it, only the `arm()` fire-when-ready path works
(one attack per press while eqbal is up).

---

## Damage estimates — STANCE-KEYED (auto-calibrating)

Blademaster slash damage **varies by stance** (the class doc: thyr reduced <
mir/sanya normal < doya increased < arash highest). 005 stored single
auto-captured P/S values in `blademaster.state`, which silently used stale
numbers for one hit after a mid-fight stance switch (e.g. the Thyr-prep →
Arash-break burst). This port keys them by stance instead — Tekura-style:

```lua
blademaster.limbDamage = {
  doya  = { legPrimaryDamage=17.3, legSecondaryDamage=11.5, armPrimaryDamage=17.3,
            armSecondaryDamage=11.5, torsoDamage=18.1, headDamage=12.1, compassDamage=14.9 },
  thyr  = { ... },  -- all 5 seed identically; calibrate each separately
  mir   = { ... },
  arash = { ... },
  sanya = { ... },
}
```

- `blademaster.getStance()` — lowercased `charstat("Stance")`, falls back to
  `blademaster.defaultStance` (`"thyr"`) when unknown/unstanced.
- `blademaster.stanceLd()` — the current stance's subtable. **Every** damage
  read (prep/break/path math) and the three capture-trigger **writes** route
  through it, so each stance accumulates its own calibrated numbers and the
  active stance is always used (no post-switch lag).
- The table is `or`-guarded, so calibrated values survive a script reload.
- Seeds are identical across stances (Levi baseline) — they are GUESSES until
  calibrated. Run `bmcal("<stance>")` (`calibrate.lua`) in each stance against a
  sparring target; `bmcalshow()` prints the paste-ready `blademaster.limbDamage`.

---

## Open Decisions

- [x] **Source of truth** — 005 (active, documented, 4 strategies). 001-004 legacy
      not ported.
- [x] **Namespace** — `blademaster.*` (the source already used it; it IS the class).
- [x] **CONFIG vs config** — renamed to `CONFIG` for port-family consistency.
- [x] **lb target key** — raw `target` (AK convention), dropped the capitalization.
- [x] **tAffs shield/rebounding fallback** — dropped (no V1 table in AK).
- [x] **Per-hit damage stance-awareness** — 005 used single auto-captured values
      (1-hit stale after a stance switch). This port keys them by stance
      (`blademaster.limbDamage[stance]` via `getStance()`/`stanceLd()`),
      Tekura-style. Reads + capture writes all route through `stanceLd()`.
- [ ] **`lockBreakCommand`** — defaulted to `fitness` (Blademaster's Striking
      Fitness cures asthma). If your character relies on a tree tattoo or other
      cure-random, set `blademaster.CONFIG.lockBreakCommand` accordingly. Note
      weariness blocks Fitness, so a hard lock may need a different escape.
- [ ] **`mounted` affliction name** — `has("mounted")` assumes AK tracks a
      `mounted` pseudo-affliction. If AK exposes mount state elsewhere, override
      the 4 `has("mounted")` sites (double-prep + brokenstar strike + their echoes).
- [ ] **Group-mode lock ladder** — uses 005's simpler ladder, not 001's richer
      `levibmtruelock` truelock progression. Re-port if you want the legacy order.
- [ ] **`engageOnFirst`** — on by default (mirrors source). Set false if Legacy
      already engages for you.

---

## TODO Punch List

### A. `targetparry` shape  ✅ RESOLVED
AK reports parried limbs with **no spaces** (`leftleg`, `rightleg`, `leftarm`,
`rightarm`, plus `torso` / `head` / `none`). `blademaster.getParried()` maps the
four no-space limb values to the spaced form (`"left leg"`, …) the focus/airfist
logic compares against, via the `PARRY_SPACED` table. `torso` / `head` / `none`
pass through unchanged. (Note: `lb[target].hits` keys are separate and remain
spaced.)

### B. Confirm `mounted` tracking  ⭐ HIGH
The dismount-before-double-break logic gates on `has("mounted")`. Verify AK sets
`affstrack.score.mounted` (or override those 4 sites).

### C. Verify `lb[target].hits` keys  ⭐ HIGH
Limb keys used: `"left leg"`, `"right leg"`, `"left arm"`, `"right arm"`,
`"torso"`, `"head"`. Confirm AK uses these exact strings.

### D. Set `lockBreakCommand`  • MEDIUM
Default `fitness`. Override if your profile uses a different lock-break.

### E. Rebound-hold integration  • MEDIUM
Override `blademaster.reboundGate` to delegate to your rebound-hold module.
The default stub never holds.

### F. Calibrate per-stance damage  ⭐ MEDIUM
All 5 stance subtables in `blademaster.limbDamage` seed to the same Levi
baseline — they are guesses until calibrated. Run `bmcal("<stance>")` in each
stance (doya/thyr/mir/arash/sanya) against a sparring target, then `bmcalshow()`
to print the paste-ready table. Live combat also auto-calibrates the current
stance via the capture triggers, but the seeds drive the would-break guards
until the first real hit lands in that stance. The stance-switch command in
`calibrate.lua` is the bare stance name (`thyr`, `arash`, …) — adjust if your
profile differs.
```
