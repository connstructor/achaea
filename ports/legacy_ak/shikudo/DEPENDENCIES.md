# Shikudo God Mode — Legacy / AK Port

Mapping doc for the Shikudo **god-mode** port. Source of truth is the LEVI/Ataxia
`009_CC_Shikudo_GodMode.lua`; the AK plumbing mirrors the sibling monk port
`ports/legacy_ak/tekura/tekura.lua`.

**Destination:** `ports/legacy_ak/shikudo/shikudo.lua` — single file, `monk.shikudo.*`.

**Scope:** *lean offense.* The 5-limb prep engine, form management
(Tykonos→Willow→Rain→Oak→Gaital), the stateless 3-combo execute, and the two
finisher forks (DISPATCH + soft-LOCK). Self-sustain from the Levi `run()` is
**dropped** (see below).

---

## Tier 1 — AK (target state)

| Levi (godmode) | AK replacement |
| --- | --- |
| `haveAff("X")`, `tAffs.X` | `has("X")` → `affstrack.score[X] >= CONFIG.AFF_THRESHOLD` (30) |
| `tAffs.damagedX` / `haveAff("brokenX")` | `limbBroken(limb)` → `getLimbDamage(limb) >= 100 or has("damaged"..k) or has("broken"..k)` |
| `lb[target].hits[limb]` | unchanged (`getLimbDamage(limb)`) |
| `ataxiaTemp.parriedLimb` | `targetparry` (global) |
| `target` | unchanged |
| `ataxiaTemp.hyperLimb` | `ak.limbs.hyperfocus` — read live, never tracked client-side |
| `tCity` / Mhaldor `incapacitate` branch | removed — always `dispatch` |

## Tier 2 — Legacy (self state)

| Levi (godmode) | Legacy replacement |
| --- | --- |
| `ataxia.vitals.form` / `.kata` | `charstat("Form")` / `charstat("Kata")` (parse `gmcp.Char.Vitals.charstats`) |
| `ataxia.afflictions.X` (aeon, stupidity) | `selfAff("X")` → `Legacy.Curing.Affs[X]` |
| `ataxia.settings.paused` | `isPaused()` → `Legacy.Settings.Curing.status == false` |
| `ataxia.settings.separator` | `"/"` (hardcoded, joins commands in the SKATK alias) |
| `ataxia_needLockBreak()` / `ataxia_lockBreak()` | `selfNeedLockBreak()` / `selfLockBreak()` (Monk: stand-if-prone + `fitness`) |
| `combatQueue()` prefix | removed — Legacy handles pre-attack hooks externally |
| `send("queue addclear eqbal "..atk)` | `sendAttack(cmd, "EQBAL")` → `SETALIAS SKATK <cmd>` + `QUEUE ADDCLEARFULL EQBAL SKATK` |
| `send("cq all".. transition)` | k>=5 (clean transition — needs balance but doesn't consume it): `transition to the X form / <target-form combo>` bundled in one EQBAL send. k<5: `adopt X form` alone (adopt consumes balance; combo lands next balance). |

## Shikudo-specific

### Hyperfocus (`ataxiaTemp.hyperLimb`)
Read live from **`ak.limbs.hyperfocus`** (the limb we currently have hyperfocused) — never
tracked client-side. `hyperfocus head` is issued only during prep (non-Gaital) when
`ak.limbs.hyperfocus` isn't already `"head"`; combo 1's sweep emits `hyperfocus none` only
when the focus is actually on the head. No trigger to wire, nothing to desync.

### Limb-break percentages (`ataxiaTables.limbData.shikX`)
A static lookup table `monk.shikudo.limbDamage` (% of a limb break each attack lands), defined
in `shikudo.lua` and redefined fresh on load (file = source of truth). Damage scales with stats
+ staff artifact, so the values are **measured, not computed**: `calibrate.lua` (`skcal`) fires
each limb-damaging attack solo, reads the `lb[target].hits` delta, and `skcalshow()` prints a
paste-ready table to drop over the one in `shikudo.lua`. Seeds are rough (the old Levi formula
at 5000 health) so it works before calibration. Levi's `shikudo_breakPoint` health formula and
the `ataxia.shikudoLevel` (staff-artifact) multiplier are **dropped** — calibration captures
both your stats and your artifact directly. Attack→aff reference (drives the build ladder):
kuro→weariness+lethargy, ruku→slickness(torso)/healthleech+clumsiness(arms), hiru→dizziness,
hiraku→anorexia, nervestrike→paralysis, needle→crushedthroat, flashheel→break-leg, frontkick→prone.

---

## Dropped (vs Levi godmode)

| What | Why |
| --- | --- |
| `transmute` (HP→sustain), `kai boost`, `mind lock` (Telepathy) | Lean-offense scope (user choice) — these are self/utility, not the limb kill. |
| Maelstrom form + `maelstromPrios` + `gm.lowHp` low-HP crescent fork | Lean-offense scope. The form swap never routes to Maelstrom; the low-HP override is gone. |
| `combatQueue()` prefix; `tCity`/Mhaldor `incapacitate` | House convention (matches tekura/sentinel) — always proceed with `dispatch`. |
| Dead code the 2026-04-14 review flagged | `gm.staff[1]=="hyperfocus head"` branch (A), the 2nd `=="dispatch"` handler (D), and the never-consumed `hyperNeedsRaise` flag (S2/C) are simply not ported. |

---

## Public API

`monk.shikudo.*` — data: `CONFIG`, `state`, `limbDamage`.
`monk.shikudo.*` — functions: `dispatch()` (main entry), `run()`, `status()`, `reset()`,
`calcLimbs()`, `formswap()`.
Top-level aliases: `sk`, `skstatus`, `skreset`, `skdebug` (shikudo.lua); `skcal`, `skcalshow`,
`skcalstop` (calibrate.lua).

## Tests

`shikudo_test.lua` stubs the host globals and asserts the queued SKATK command across the
per-form build, the 3 execute combos, clean-transition bundling (transition + combo on one
balance), dispatch, lock fork, parry redirect, shield, hyperfocus, and the no-target / paused
guards. Run from this folder: `lua shikudo_test.lua`.
