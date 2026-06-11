# Psion — Mudlet Setup (manual aliases & triggers)

`Psion.lua` self-registers **nothing** — no `tempAlias`, no `tempRegexTrigger`. You
create those by hand. This doc lists every item to add.

With a full AK build loaded the wiring is **tiny** — AK + affstrack supply every state
the offense reads (unweave levels, mana, and all afflictions incl. muddled/lightbind),
so there are **no state triggers at all**. The whole job:

- **§1 — fire the system** (the arm aliases + 1 trigger). Required for *anything* to happen.
- **§2 — nothing else.** No state-feed triggers to wire.

All regex below is **Mudlet Perl-regex** form (single backslash — type it exactly).
`matches[1]` is the whole match; `matches[2]`, `matches[3]`, … are capture groups.

> **These patterns are written against the LEVI source's game lines.** Achaea wording
> may differ for your character/skills — **match each pattern to your real output**
> before trusting it. The handler calls are what matter; the regex is yours to tune.

> The on-demand `tempTimer` inside `on_balance` is transient per-balance sequencing —
> **not** a registered hook, so there's nothing to add or tear down for it.

---

## 0. Load order

1. Add `Psion.lua` as a **Script** (Scripts → Add Item → paste the file). It defines
   the global `psion` table when the profile loads.
2. Add the aliases and triggers below. They reference `psion.*` / `psmind()` / etc.,
   which exist after the script runs, so ordering within the profile doesn't matter.
3. Make sure the host-framework globals the module reads are present — see §3 and
   `DEPENDENCIES.md`.

---

## 1. TIER 1 — fire the system (REQUIRED)

### 1a. Arm aliases

| Pattern | Script | What it does |
|---|---|---|
| `^zz$` | `psmind()` | **Standard.** Arm mind mode — auto Psi Excise + Deconstruct. Fires now if eq+bal up, else arms for the §1b timer. One attack per press. |
| `^xx$` | `psflurry()` | **Burst.** Arm flurry mode (invert→spirit→Flurry). |
| `^cc$` | `pscatch()` | **Anti-escape.** `WEAVE LAUNCH` (pull a flier down) + re-`LIGHTBIND`. Fires now on its own `PSIUTIL` queue. |
| `^vv$` | `psheal()` | **Self-cure.** `PSI EXPUNGE` — clear a mental affliction (blocked by confusion). |
| `^psstatus$` | `psstatus()` | *(optional)* print mode / unweave levels / kill-readiness / lock tier. |
| `^psreset$` | `psreset()` | *(optional)* teardown — clears state + timers, back to mind mode. |

`zz` is just the default arm button — rename the pattern to whatever key you bind.
You normally never call `psion.dispatch()` directly; go through the arm alias.

### 1b. "Balance / Equilibrium used" trigger (the firing engine)

This is the engine. When you spend a resource, your game prints a recovery line.
Trigger on it, capture the recovery seconds, and pass them to `on_balance` — it
schedules a `tempTimer` for `interval - lead` and dispatches when that fires (~latency
**before** balance returns; the FREE queue holds the combo server-side until it
actually does, so the attack lands the instant it's back). A Psion combo spends
**both** balance and eq, so wire it to **both** the balance and equilibrium lines —
`on_balance` keeps the timer for whichever resource returns **last** (the longer
recovery) and ignores the shorter one.

Type: **Perl regex**.

```
^(Balance|Equilibrium) used: (\d+\.\d+)s\.$
```
```lua
psion.on_balance(tonumber(matches[3]))
```

Notes:
- `matches[2]` is `Balance`/`Equilibrium`; `matches[3]` is the seconds (a float).
- `on_balance` only *schedules*. The dispatch fires only if you **armed** it by
  pressing an arm alias — then it disarms. **One attack per press.**
- Tune the lead with `psion.CONFIG.PREARM_INTERVAL` (seconds); leave `nil` to use
  Mudlet's live `getNetworkLatency()`.
- **No timed used-message?** Drive it from GMCP: a Script with a registered
  `gmcp.Char.Vitals` handler that, when `bal`/`eq` flips `1`→`0`, calls
  `psion.on_balance(<recovery seconds>)`.

---

## 2. State triggers — none

There are no state-feed triggers to wire. AK + affstrack supply everything the offense
reads: unweave levels (`affstrack.score.unweaving*`, encoded ×100), target mana
(`ak.manapercent`), and every affliction including `muddled` and `lightbind`
(`affstrack.score`). The arm aliases + the §1b balance trigger are the whole setup.

> The `CONTEMPLATE <target>` the port sends each turn is what keeps `ak.manapercent`
> fresh, so leave `CONFIG.CONTEMPLATE` on — but you do **not** wire a trigger for it;
> AK parses the reply itself.

---

## 3. Prerequisites — host-framework globals (not configured here)

The module reads opponent/self state from the Legacy + AK framework. These are
populated by that framework, **not** by anything in this doc. Missing → the system
runs on zeros. See `DEPENDENCIES.md` §1 for the full contract.

| Global | Provides |
|---|---|
| `affstrack.score[aff]` | generic target afflictions (paralysis, asthma, impatience, …) |
| `lb[target].hits["head"]` | head limb damage (prep/break math) |
| `ak.defs.shield` | target shield (the cleave pre-empt) |
| `affstrack.score.unweaving{mind,body,spirit}` | unweave levels (×100) → Deconstruct / Flurry |
| `ak.manapercent` / `affstrack.score.mindravaged` | target mana % → Excise; mind-ravaged → mana pressure |
| `gmcp.Char.Vitals.bal` / `.eq` | our balance / equilibrium (fire gate) |
| `Legacy.Curing.Affs` / `Legacy.Settings.Curing.status` | our aeon guard / paused guard |
| `target` | current target name |
| `boxEcho.send(...)` | status sink (optional; falls back to cecho/print) |

---

## 4. Per-matchup tuning

- **Class-aware fillers:** AK has no target-class feed. To lead fillers with
  weariness vs Priest/Occultist/Pariah, edit `get_target_class()` near the top of
  `Psion.lua` to return the class string for your matchup (default `nil` = the
  standard clumsiness-first order).
- **Weave damage:** if head preps land early/late, calibrate
  `psion.CONFIG.WEAVE_DAMAGE` (see `DEPENDENCIES.md` §4).
- **Shield wield:** if `WIELD RIGHT SHIELD` isn't your kit, set
  `psion.CONFIG.WIELD_SHIELD = false` or change `psion.CONFIG.WIELD_COMMAND`.

---

## Quick checklist

- [ ] `Psion.lua` loaded as a Script
- [ ] **§1 (required):** `zz`→`psmind()`, `xx`→`psflurry()`, `cc`→`pscatch()`, `vv`→`psheal()`; "Balance/Equilibrium used" trigger → `psion.on_balance(...)`
- [ ] **§2:** nothing — no state-feed triggers (AK + affstrack supply it all)
- [ ] Host globals present (§3): `affstrack`, `lb`, `ak`, `gmcp`, `Legacy`, `target`, `boxEcho`
- [ ] `get_target_class()` set for your matchup (optional); `WEAVE_DAMAGE` calibrated (optional)
