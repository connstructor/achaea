# Runewarden SnB — Mudlet Setup (manual aliases & triggers)

`RunewardenSnB.lua` self-registers **nothing** — no `tempAlias`, no
`tempRegexTrigger`. You create those by hand in Mudlet. This doc lists every item
to add. The system is **tiny** to wire up: **one trigger** and **one alias**.

- The **alias** (`zz`) **arms** the system — it calls `runewarden.snb.arm_next_bal()`.
- The **"Balance used" trigger** is **required** — it's the firing engine. It calls
  `runewarden.snb.on_balance_used(...)`, which arms a just-in-time `tempTimer` that
  fires your attack the instant balance returns (see §1).

All regex below is in **Mudlet UI form** (single backslash). Don't double-escape —
the `\d` / `\.` you see here is exactly what you type into the pattern box. In
Mudlet, `matches[1]` is the whole match and `matches[2]`, `matches[3]`, … are the
capture groups.

> The on-demand `tempTimer` inside `on_balance_used` is transient sequencing
> created per balance cycle — **not** a registered hook, so there's nothing to add
> or tear down for it.

---

## 0. Load order

1. Add `RunewardenSnB.lua` as a **Script** (Scripts → Add Item → paste the file).
   It defines the global `runewarden.snb` table when the profile loads.
2. Add the alias and trigger below. They reference `runewarden.snb.*`, which exists
   after the script runs, so ordering within the profile doesn't matter at runtime.
3. Make sure the host-framework globals the module reads are present — see §3.

---

## 1. REQUIRED — "Balance used" trigger (fires your attacks)

This is the engine. When you spend balance, your game prints a line reporting the
recovery delay. Trigger on it, capture that delay (in seconds), and pass it to
`on_balance_used` — it arms a `tempTimer` for `interval - getNetworkLatency()` and
runs the dispatch the instant balance returns, so the combo is built from
**current** limb / affliction / shield / ferocity state.

Type: **Perl regex**. Capture the recovery seconds as a group → `matches[2]`:

```
^Balance used: (\d+\.\d+)s\.$
```
```lua
runewarden.snb.on_balance_used(matches[2])
```

Notes:
- The pattern above is the line the port was written against. **Match it to your
  real game line** — replace it if yours differs (e.g. capitalisation, "seconds"
  spelled out, or a millisecond value, in which case divide:
  `runewarden.snb.on_balance_used(tonumber(matches[2]) / 1000)`).
- The captured value must be **seconds** (a float).
- `on_balance_used` only *schedules*. The dispatch fires only if you **armed** it
  by pressing the `zz` alias (§2), then it disarms — **one attack per press**.
- Tune the lead time with `runewarden.snb.CONFIG.PREARM_INTERVAL` (seconds). Leave
  it `nil` to use Mudlet's live `getNetworkLatency()`.
- **Without this trigger:** only `arm_next_bal()`'s fire-when-ready path works — an
  attack fires only when you press `zz` *while balance + eq are already up*. The
  "queue during recovery, fire on return" timing is lost.

> **No timed used-message?** Drive it from GMCP instead: a Script with a registered
> `gmcp.Char.Vitals` event handler that, when `bal` flips `1`→`0`, calls
> `runewarden.snb.on_balance_used(<recovery seconds>)` with a duration you supply
> (e.g. your class balance constant).

---

## 2. Aliases

Mudlet aliases are regex. Create with the given pattern and script.

| Pattern | Script | What it does |
|---|---|---|
| `^zz$` | `runewarden.snb.arm_next_bal()` | **Arm/fire.** Fires now if balance + eq are up; otherwise arms so the §1 timer dispatches on balance return. One attack per press. |
| `^snbreset$` | `runewarden.snb.reset()` | *(optional)* Teardown — turns `FURY OFF` and clears state (falcon flags, armed flag). Use when a fight ends. |

`zz` is just the default arm button — rename the pattern to whatever key you bind.
You normally never call `runewarden.snb.dispatch()` directly; go through `zz`.

---

## 3. Prerequisites — host-framework globals (not configured here)

The module is pure offense logic; it **reads** opponent/self state from the
Legacy + AK framework. These are populated by that framework's own triggers/GMCP,
**not** by anything in this doc. If they're missing, the system runs on zeros.
The module needs:

| Global | Provides |
|---|---|
| `Legacy.Curing.Defs.current` | self defences (`fury`) |
| `ak` | opponent state — `ak.defs` (shield/rebounding), `ak.health` / `ak.maxhealth`, `ak.engaged` |
| `affstrack` | opponent afflictions — `affstrack.score[aff]`, `affstrack.impale`, `affstrack.ferocity` |
| `lb[target].hits[limb]` | opponent limb damage |
| `target` / `targetparry` | current target, and the limb they're parrying |
| `boxEcho.send(...)` | the module's status display sink |
| `gmcp.Char.Vitals` | `bal` / `eq` for the fire-when-ready check |

(These are the same globals documented at the top of `RunewardenSnB.lua`.)

---

## Quick checklist

- [ ] `RunewardenSnB.lua` loaded as a Script
- [ ] **"Balance used" trigger** → `runewarden.snb.on_balance_used(matches[2])` — REQUIRED (fires attacks)
- [ ] `zz` alias → `runewarden.snb.arm_next_bal()` (arm/fire)
- [ ] `snbreset` alias → `runewarden.snb.reset()` (optional teardown)
- [ ] Host-framework globals present (§3): `Legacy`, `ak`, `affstrack`, `lb`, `target`, `targetparry`, `boxEcho`
