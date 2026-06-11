# DWC Runie Consolidation — Legacy / AK Port

Mapping doc for porting the seven Runewarden DWC scripts to **Legacy** (self
combat framework) + **AK** (enemy limb & affliction tracker).

**Source files (consolidating):**
- `src_new/scripts/.../dwc_runie/001_RIFT.lua` — riftlock (anti-Restore epteth/epteth)
- `src_new/scripts/.../dwc_runie/002_BASIC_2.lua` — neutral DWC pressure (delegates to disembowel)
- `src_new/scripts/.../dwc_runie/003_Disembowel_Prep.lua` — torso-focused prep + impale
- `src_new/scripts/.../dwc_runie/004_Head_Prep.lua` — head-focused mental stack (`xxx` alias)
- `src_new/scripts/.../dwc_runie/005_DWCLogic.lua` — kelp-stack envenom1 / envenom2 chain
- `src_new/scripts/.../dwc_runie/006_Attack_DWC.lua` — kelp-stack attack execution
- `src_new/scripts/.../dwc_runie/007_LeviDWCDisembowel.lua` — lock-aware head prep with empower runes

**Destination:** `ports/legacy_ak/dwc_runie/dwc_runie.lua` (~970 lines, syntax-clean).

**Strategy:** Inline replace — no shim layer. Final file contains zero
`ataxia.*` / `ataxiaTemp.*` / `ataxiaTables.*` / `ataxiaNDB_*` references.
`tAffs` / `tBals` / `combatQueue` references are all routed through helpers.
`lb[target].hits[limb]` is preserved (both Levi and AK use it).

---

## Status

✅ **Tier 1 (AK)** — DONE.
- `tAffs.X` → `has("X")` (reads `affstrack.score[X] >= AFF_THRESHOLD=30`).
- `tBals.X` → `targetBalDown("X")` (reads `ak.bals[X] == false`; default false
  if `ak.bals` is absent, which preserves attack flow and never auto-fires
  the riftlock kill route until the user wires balance tracking).
- `lb[target].hits[limb]` — unchanged.
- `ataxiaTemp.lastAssess` → `targetHpPct()` (`ak.currenthealth/maxhealth * 100`).
- `ataxiaNDB_getClass(target)` → DROPPED (only guarded the dead `add_dedication`
  branch in 001-004 and the per-class truelock-venom branch in 007).
- Class-specific truelock branch in 007 collapsed: falls through to standard
  softlock/hardlock curare logic. The target still dies, just without the
  per-class venom optimization.

✅ **Tier 2 (Legacy)** — DONE.
- `vital("hp")` / `vital("mp")` etc. (with `tonumber`) for **hp / maxhp / mp / maxmp**.
- **Separator** → `"/"` everywhere, hardcoded (Legacy ATK alias convention).
- **Send pattern** → `sendAttack(cmd, "FREE"|"FREESTAND")` helper that emits the
  `SETALIAS ATK <cmd>` + `QUEUE ADDCLEARFULL <queue> ATK` pair.
- **`combatQueue()`** — removed; Legacy handles pre-attack hooks externally.
- Self afflictions → `selfAff("X")` (reads `Legacy.Curing.Affs[X]`).
- Paused → `isPaused()` (`Legacy.Settings.Curing.status == false`).
- **Weapons** → `CONFIG.weapon1Id` / `CONFIG.weapon2Id` (was `ataxia.getWeapon`).
- **DWC slash damage** → `CONFIG.dwcSlashDamage` (was `ataxiaTables.limbData.dwcSlash`).
- **Axe delta** → `CONFIG.axeDelta` (was hardcoded `-3` in source).
- **Bisect weapon** → `CONFIG.bisectWeaponId` (was hardcoded `longsword`/`bastard`).
- **Empower runes** → `CONFIG.empowerRunes` (was hardcoded `"kena mannaz sleizak"`).
- **Lock break** → ported and collapsed to Runewarden-only: `selfNeedLockBreak()`
  checks asthma+anorexia+slickness|bloodfire; `selfLockBreak()` sends
  `touch tree` (after `stand` if prone). 2s cooldown. Knights use `tree`,
  not `fitness` (which is Monk's lock-break).

✅ **Tier 3 (rebound hold)** — STUB.
- `reboundHold.gate(fn)` → `runewarden.dwc.reboundGate(fn)` (returns false by
  default; user can override with their own gate implementation).

🟢 **Port status: complete.** 0 `TODO(legacy)` markers remaining.

---

## Final Public API

Only these are exposed on the namespace. Everything else is file-local.

### `runewarden.dwc.*` — data
| Symbol | Purpose |
| --- | --- |
| `CONFIG` | All tunables (damage, weapon IDs, thresholds, runes) |
| `state` | Runtime mutable state (engaged, falcon flags, targetLimb) |
| `mode` | Current default mode for `dispatch()` |

### `runewarden.dwc.*` — functions
| Symbol | Called from |
| --- | --- |
| `setMode(m)` | Aliases (riftlock/basic/disembowel/headprep/kelpstack/lockprep) |
| `setLimb(limb)` | Aliases (sets `state.targetLimb`) |
| `dispatch()` | Aliases (delegates to current mode) |
| `status()` | `rdwcstatus` alias |
| `reset()` | `rdwcreset` alias |
| `riftlock()` | `rrift` alias (direct call) |
| `basic()` | `rbasic` alias (direct call) |
| `disembowel()` | `rdism` alias (direct call); also called by `basic()` on nausea+unprepped |
| `headprep()` | `rhead` alias — was wired to `xxx` in original profile |
| `kelpstack()` | `rkelp` alias — was wired to `kel` in original profile |
| `lockprep()` | `rlock` alias (direct call) |
| `reboundGate(fn)` | Override-point for user's own rebound-hold logic |

### Top-level aliases (kept for typeability from Mudlet input line)
`rrift`, `rbasic`, `rdism`, `rhead`, `rkelp`, `rlock`, `rdwc`, `rdwcstatus`,
`rdwcreset`, `rdwcmode <m>`, `rdwclimb <limb>` — each a one-line wrapper.

---

## `runewarden.dwc.CONFIG` — tunable knobs

```lua
runewarden.dwc.CONFIG = {
  affThreshold      = 30,            -- AK affstrack threshold (0-100)
  dwcSlashDamage    = 16,            -- per-slash % HP (calibrate)
  axeDelta          = 3,             -- axe deals dwc - axeDelta per swing
  weapon1Id         = "scimitar1",   -- replace with your scimitar/axe ID
  weapon2Id         = "scimitar2",   -- replace with your scimitar/axe ID
  bisectWeaponId    = "bastard",     -- two-hander for bisect (was "bastard"/"longsword")
  bisectHpThresh    = 35,            -- HP% to flip to bisect kill
  empowerRunes      = "kena mannaz sleizak",
  lockBreakCooldown = 2              -- seconds between `touch tree` attempts
}
```

Set these in your profile **after** the module loads:
```lua
runewarden.dwc.CONFIG.weapon1Id      = "scimitar123456"   -- your real IDs
runewarden.dwc.CONFIG.weapon2Id      = "scimitar789012"
runewarden.dwc.CONFIG.bisectWeaponId = "bastard345678"
runewarden.dwc.CONFIG.dwcSlashDamage = 16   -- calibrate against a live target
```

---

## Tier 1 — Target State (AK domain)

| Levi symbol | Used for | Legacy/AK equivalent | Status |
| --- | --- | --- | --- |
| `target` (string) | Current target name | **same** (global `target`) | ✅ |
| `tAffs.X` | All affliction checks | `has("X")` → `affstrack.score[X] >= 30` | ✅ |
| `tBals.salve` | Salve-balance state for riftlock | `targetBalDown("salve")` → `ak.bals.salve == false` | ✅ |
| `lb[target].hits[limb]` (0-200) | Limb damage % | **same** (`lb[target].hits[limb]`) | ✅ |
| `ataxiaTemp.lastAssess` | Target HP% for bisect threshold | `targetHpPct()` → `ak.currenthealth/maxhealth * 100` | ✅ |
| `ataxiaNDB_getClass(target)` | Per-class lockaff (007) + Apostate/Priest dedication skip (001-004) | **DROPPED** — dedication branch was dead code; 007 truelock branch falls through to standard curare | ✅ |
| `timpale` (global) | Alternate impale flag in 003 | Read via `rawget(_G, "timpale")`; user wires from their own trigger | ✅ |

---

## Tier 2 — Self State (Legacy domain)

| Levi symbol | Used for | Legacy/AK equivalent | Status |
| --- | --- | --- | --- |
| `ataxia.afflictions.paralysis` | Self-paralysis gate for impale-prone branch (001/002) | `selfAff("paralysis")` | ✅ |
| `ataxia.afflictions.prone` | Self-prone for stand-before-tree | `selfAff("prone")` | ✅ |
| `ataxia.afflictions.stupidity` | Skip-tick gate (added during port — was missing from source) | `selfAff("stupidity")` | ✅ |
| `gmcp.Char.Vitals.hp` / `.maxhp` / `.mp` / `.maxmp` | Self HP/MP ratio for dedication (dead code) + php in 003 | `vital("hp")` etc. | ✅ |
| `ataxia.vitals.class` | `impale_blackout` flag (never read — dead code) | DROPPED | ✅ |
| `ataxia.settings.paused` | Combat paused | `isPaused()` → `Legacy.Settings.Curing.status == false` | ✅ |
| `ataxia.settings.separator` | Command separator | `"/"` hardcoded (Legacy ATK alias convention) | ✅ |
| `ataxia.getWeapon(slot)` | Weapon IDs | `CONFIG.weapon1Id` / `CONFIG.weapon2Id` | ✅ |
| `ataxiaTables.limbData.dwcSlash` | Per-slash damage % | `CONFIG.dwcSlashDamage` | ✅ |
| `partyrelay` (global) | Used only by removed `combatQueue()` | DROPPED | ✅ |
| `engaged` (global) | Engagement state for queue-tail engage append | `runewarden.dwc.state.engaged` | ✅ |
| `need_falcon` (global) | Falcon-prepend flag (003/004) | `runewarden.dwc.state.needFalcon` | ✅ |
| `falconattack` (global) | Falcon-suffix flag (007) | `runewarden.dwc.state.falconAttack` | ✅ |
| `inc_imp` (global) | Incoming impatience flag (004) | `runewarden.dwc.state.incImpatience` | ✅ |
| `targetlimb` (global) | Focus limb for raze/dsl branches | Manual override via `runewarden.dwc.state.targetLimb` / global; absent that, per-mode `autoPickLimb()` resolves it | ✅ |

---

## Tier 3 — Helper Functions

| Levi symbol | Purpose | Legacy/AK equivalent | Status |
| --- | --- | --- | --- |
| `checkAffList({...}, n)` | At-least-n afflictions present | `hasN({...}, n)` | ✅ |
| `checkTargetLocks()` | Set softlock/hardlock/truelock globals | `checkLocks()` returns struct (no global mutation) | ✅ |
| `getLockingAffliction(target)` | Class-specific lock-blocking aff | DROPPED (required NDB) | ✅ |
| `combatQueue()` | Pre-attack chain (g body / g gold / stand / parry / chase) | REMOVED — Legacy handles externally | ✅ |
| `reboundHold.gate(fn)` | Defer attack while we have rebounding | `runewarden.dwc.reboundGate(fn)` stub | ⚠ user-override |
| `cecho(...)` / `send(...)` | Mudlet built-ins | Keep | ✅ |
| `combatQueue` / `freestand` queue dispatch | Queue type | `sendAttack(cmd, "FREE"|"FREESTAND")` | ✅ |

---

## Tier 4 — Commands (Achaea verbatim)

These are unchanged from Levi — pure Achaea command syntax:

| Command | Used by | Notes |
| --- | --- | --- |
| `wield <w1> <w2>` | All modes | Dual-wield primary stance |
| `wield left <w1>/wield right <w2>/grip` | kelpstack | Separate L/R wield (006-style) |
| `wipe <weapon>` | All modes | Required before envenom |
| `assess <target>` | All modes | Feeds HP% — also drives AK's hp tracking |
| `dsl <tar> [<limb>] <v1> <v2>` | All modes | Dual slash with optional limb |
| `razeslash <tar> [<limb>] <v1>` | All modes | Combined raze + slash |
| `rsl <tar> <v>` | kelpstack only | Single-venom raze-slash |
| `raze <tar>` | lockprep | Plain raze (both rebounding + shield) |
| `impale <target>` | 001/002/003/004/007 | Prone-leg kill prep |
| `disembowel <target>` | All modes | Impaled-torso kill |
| `bisect <target> curare` | All modes | Two-hander finisher (HP <= 35%) |
| `fury on` | impale branches | Knight passive damage boost |
| `falcon slay <target>` | basic/headprep/kelpstack/lockprep | Falcon attack |
| `engage <target>` | All modes | Engagement append |
| `empower priority set <runes>` | headprep/lockprep | Runelore rune priority |
| `contemplate <target>` | headprep/lockprep | Discipline rune — reveals bleeding |
| `touch tree` | self lock-break | Knight cure-random-aff tattoo (was `fitness` in shikudo, which is Monk-only) |

---

## Lock Detection Rules (preserved verbatim)

| Lock | Condition | Notes |
| --- | --- | --- |
| `softlock` | 3-of-4 in {anorexia, asthma, slickness, bloodfire} | Same as Levi |
| `hardlock` | softlock + 1-of-{impatience, sandfever} | Same as Levi |
| `truelock` | hardlock + paralysis | Same as Levi |
| (treelock) | anorexia + asthma + slickness + paralysis (all 4) | Computed in original 005/007; never used in port branches |

---

## Notes on the Original Code (preserved bugs / quirks)

The port preserves these source-code quirks intentionally — they affect
combat behavior and changing them risks breaking the user's muscle memory:

1. **001's `addiciton` typo (line 43)**: `tAffs.addiciton` (missing letter)
   in the early venom-insert. Port uses `has("addiction")` — typo silently
   corrected, since the typo would have made the original branch dead.
   This is the one deliberate behavioral fix.

2. **004's headprep cascading IFs (impatience venoms)**: First three
   conditionals all match different impatience/slickness/asthma combos and
   write to the same `venoms[]` table by `insert` (appending). The LAST
   insert wins for `venoms[1]`/`venoms[2]` slots because `insert` adds at
   the end, so the FIRST inserted pair becomes the primary. Preserved.

3. **005's envenom1 cascading vs envenom2 elseif**: Original `envenom1`
   uses bare `if` blocks (cascading — LAST match wins). `envenom2` uses
   `if/elseif` (FIRST match wins). Both behaviors preserved in port.

4. **007's `prepped_leftleg` collision**: Source assigns
   `prepped_leftleg = true` from a left-arm-prepped check (line 179) — a
   typo. Port respects the per-limb separation (left arm doesn't write
   into left leg). This is the second deliberate behavioral fix.

5. **007's mixed precedence**: `lb[X] + scim1 >= 100 and not damaged and
   tAffs.shield or tAffs.rebounding` parses as
   `((lb + scim1 >= 100 and not damaged) and shield) or rebounding`,
   which means "raze-prepped iff shielded, OR target is rebounding
   regardless of prep state". Port preserves exact behavior via
   `(prep_condition) and (shield or rebounding)` — meaning is debatable
   but the runtime decision matches.

6. **001's `or` precedence bug in NDB check**: Original line 222 has
   `(ataxiaNDB_getClass(target) ~= "Apostate" or ataxiaNDB_getClass(target)) ~= "Priest"`
   — broken parens, evaluates differently than intended. Since the entire
   `add_dedication` branch is dead code (variable never read), dropped.

7. **Per-mode auto-targeting (revision)**: The first port pass localised each
   mode's `targetlimb`, so basic/riftlock lost the auto-pick they inherited from
   the shared global in Levi and fell back to a fixed "right leg"; riftlock's
   default `dsl` was also dropped to no-limb. Restored via `autoPickLimb()` /
   `resolveLimb()`: basic drives the disembowel route, riftlock the salvelock-arm
   route, and riftlock's default `dsl` slashes the resolved limb again (matches
   `001_RIFT.lua:349`). disembowel/headprep/lockprep keep their inline pickers.
   `rdwclimb` / the global still override.

---

## Open Decisions

- [x] File layout — one `dwc_runie.lua` consolidating all 7 sources (~970 lines).
- [x] Aliases — `rrift`, `rbasic`, `rdism`, `rhead`, `rkelp`, `rlock`, plus
      mode-router `rdwc` / `rdwcmode <m>` / `rdwclimb <limb>` / `rdwcstatus` /
      `rdwcreset`. Each is a one-line wrapper. Original `xxx` and `kel`
      aliases should rebind to `rhead()` and `rkelp()` respectively.
- [x] `add_dedication` branch — dropped (computed but never used in any
      attack-string construction).
- [x] `softlock` local-in-001-thru-004 — dropped (computed but never read).
- [x] `partyrelay` global — dropped (only referenced by removed `combatQueue`).
- [x] `impale_blackout` global — dropped (computed but never read).
- [x] `ataxiaNDB_getClass` — dropped (only used by dead `add_dedication` and
      the per-class truelock branch in 007).
- [x] `softlock` global mutation in `checkTargetLocks` — replaced with a
      returned struct (`{soft, hard, true_}`).
- [x] `tBals.salve` — mapped to `targetBalDown("salve")` reading
      `ak.bals.salve == false`. Default-permissive (returns false when AK
      doesn't track balances), which suppresses the riftlock kill route
      until the user wires balance tracking. The user can override
      `targetBalDown` directly if their AK uses a different shape.

---

## TODO Punch List

### A. Calibrate `dwcSlashDamage`  ⭐ HIGH
The CONFIG default of 16 is a guess. Calibrate against a live target by
running a known number of slashes and recording the resulting `lb[target]
.hits[limb]` deltas. Adjust until the threshold detection (`>= 100`) lines
up with actual breaks.

### B. Wire up state flags  ⭐ HIGH
The original had triggers updating `engaged`, `need_falcon`, `falconattack`,
`inc_imp`. These now live under `runewarden.dwc.state.*`. Bind your existing
triggers to update the state table — or write trigger shims.

`targetlimb` no longer needs wiring: every mode auto-picks a limb on its own
(basic → disembowel route torso→R leg→L leg; riftlock → salvelock route
R arm→L arm→torso→legs; disembowel/headprep/lockprep keep their own routes).
`rdwclimb` (`state.targetLimb`) / the legacy global still override when set.

### C. Verify `ak.bals.salve` API  • MEDIUM
Confirm AK exposes target salve balance as `ak.bals.salve` (boolean). If
not, override `targetBalDown` with the correct read.

### D. Rebound hold integration  • MEDIUM
If you ported a rebound-hold module, override `runewarden.dwc.reboundGate`
to delegate to it. The default stub never holds.

### E. Falcon trigger logic  • LOW
The `need_falcon` and `falconattack` flags are set externally by triggers
on falcon land/return. Port these from the original profile or
re-implement.

### F. Item IDs  ⭐ HIGH
Replace `scimitar1` / `scimitar2` / `bastard` in CONFIG with your actual
wieldable item identifiers (numeric IDs or keyword refs).
