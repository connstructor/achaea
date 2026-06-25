# DWC Runewarden — Mudlet Setup (manual aliases & triggers)

`dwc_runie.lua` self-registers **nothing** — no `tempAlias`, no
`tempRegexTrigger`. You create those by hand in Mudlet. This doc lists every item
to add. The system is small to wire up: **one trigger** and a handful of aliases.

- The **arm alias** (`zz`) **arms** the system — it calls `runewarden.dwc.arm()`.
- The **"Balance used" trigger** is **required** — it's the firing engine. It calls
  `runewarden.dwc.on_balance_used(...)`, which arms a just-in-time `tempTimer` that
  fires the attack the instant balance returns (see §1).
- The **plan alias** (`dwcplan`) picks which of the four offense routines runs.

All regex below is in **Mudlet UI form** (single backslash). In Mudlet,
`matches[1]` is the whole match and `matches[2]`, … are the capture groups.

> The on-demand `tempTimer` inside `on_balance_used` is transient sequencing
> created per balance cycle — **not** a registered hook, so there's nothing to add
> or tear down for it.

---

## 0. Load order

1. Add `dwc_runie.lua` as a **Script** (Scripts → Add Item → paste the file). It
   defines the global `runewarden.dwc` table when the profile loads.
2. **Fill in `runewarden.dwc.config`** weapon item ids (`weapon1`, `weapon2`,
   `bisect_weapon`, `basic_bisect_weapon`) and `empower_runes` — the placeholders
   (`"scimitar"`, `"bastard"`, `"longsword"`) will not match your real gear.
3. Add the alias(es) and trigger below.
4. Make sure the host-framework globals the module reads are present — see §3.

---

## 1. REQUIRED — "Balance used" trigger (fires your attacks)

This is the engine. When you spend balance, the game prints a line reporting the
recovery delay. Trigger on it, capture that delay (in seconds), and pass it to
`on_balance_used` — it arms a `tempTimer` for `interval - getNetworkLatency()` and
runs the dispatch the instant balance returns, so the batch is built from
**current** limb / affliction / shield state.

Type: **Perl regex**. Capture the recovery seconds → `matches[2]`:

```
^Balance used: (\d+\.\d+)s\.$
```
```lua
runewarden.dwc.on_balance_used(matches[2])
```

Notes:
- **Match the pattern to your real game line** — replace if yours differs (e.g.
  a millisecond value, in which case divide: `... (tonumber(matches[2]) / 1000)`).
- The captured value must be **seconds** (a float).
- `on_balance_used` only *schedules*. The dispatch fires only if you **armed** it
  by pressing `zz` (§2), then it disarms — **one attack per press**.
- Tune the lead time with `runewarden.dwc.config.prearm_interval` (seconds). Leave
  it `nil` to use Mudlet's live `getNetworkLatency()`.
- **Without this trigger:** only the fire-when-ready path works — an attack fires
  only when you press `zz` *while balance + eq are already up*.

---

## 2. Aliases

Mudlet aliases are regex. Create with the given pattern and script.

| Pattern | Script | What it does |
|---|---|---|
| `^zz$` | `runewarden.dwc.arm()` | **Arm/fire.** Fires now if balance + eq are up; otherwise arms so the §1 timer dispatches on balance return. One attack per press. |
| `^dwcplan (disembowel\|head\|basic\|rift)$` | `runewarden.dwc.set_plan(matches[2])` | Choose the active offense plan. `disembowel` = the default impale→disembowel route; `head` = head-break (the only plan that EMPOWERs); `basic` = DSL stack; `rift` = riftlock variant. |
| `^dwcfalcon$` | `runewarden.dwc.toggle_falcon()` | Toggle `FALCON SLAY` emission (Levi `need_falcon`). |
| `^dwcsalve (on\|off)$` | `runewarden.dwc.set_salve_down(matches[2] == "on")` | Tell the rift plan the target's salve balance is down (enables the `EPTETH EPTETH` riftlock branch). AK can't see salve balance, so this is manual. |
| `^dwcreset$` | `runewarden.dwc.reset()` | *(optional)* Teardown — `FURY OFF` and disarm. Use when a fight ends. |

`zz` is just the default arm button — rename the pattern to whatever key you bind.

---

## 3. Prerequisites — host-framework globals (not configured here)

The module is pure offense logic; it **reads** opponent/self state from the
Legacy + AK framework. These are populated by that framework's own triggers/GMCP,
**not** by anything in this doc. If they're missing, the system runs on zeros.

| Global | Provides |
|---|---|
| `ak` | opponent state — `ak.defs` (shield/rebounding), `ak.currenthealth`/`ak.health`/`ak.maxhealth`, `ak.engaged`, `ak.bleeding` (bleed display) |
| `affstrack` | opponent afflictions — `affstrack.score[aff]` (0–100), `affstrack.impale` (`"Me"` when impaled by us) |
| `lb[target].hits[limb]` | opponent limb damage % (spaced limb keys: `"left leg"`) |
| `target` | current target |
| `gmcp.Char.Vitals` | `bal` / `eq` (`"1"`/`"0"`) for the fire-when-ready check |
| `boxEcho.send(...)` / `echo(...)` | the module's status display sinks |
| `ignoreShield` | optional flag to ignore shield/rebounding in raze gating |

See the header of `dwc_runie.lua` and `DEPENDENCIES.md` for the full Levi→AK
symbol mapping (and the `ak.bleeding` decision that avoids the dead-global trap).

---

## Quick checklist

- [ ] `dwc_runie.lua` loaded as a Script
- [ ] `config` weapon ids + empower runes filled in
- [ ] **"Balance used" trigger** → `runewarden.dwc.on_balance_used(matches[2])` — REQUIRED (fires attacks)
- [ ] `zz` alias → `runewarden.dwc.arm()` (arm/fire)
- [ ] `dwcplan …` alias → `runewarden.dwc.set_plan(matches[2])` (choose plan)
- [ ] `dwcfalcon` / `dwcsalve` / `dwcreset` aliases (optional)
- [ ] Host-framework globals present (§3): `ak`, `affstrack`, `lb`, `target`, `gmcp`, `boxEcho`
