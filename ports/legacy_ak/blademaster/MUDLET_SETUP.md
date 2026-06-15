# Blademaster — Mudlet Setup (manual aliases & triggers)

`blademaster.lua` self-registers **nothing** — no `tempAlias`, no
`tempRegexTrigger`, no event handler. You create those by hand in Mudlet. This
doc lists every item to add.

* **Aliases** call the `bm*()` handlers — they **arm** the system.
* **Triggers** call `blademaster.on_*`.
* **One balance/equilibrium-"used" trigger** is **required** — it's the engine
  that fires your attacks (see §1).

Most of what the old port needed triggers for is now read straight from AK:
**impaled** comes from `affstrack.impale == "Me"`, **bleeding** from `ak.bleeding`,
limb damage from `lb[target].hits`. Slash damage is a static per-form table
(`blademaster.CONFIG.DMG`, keyed on `Legacy.Tannivh.form`) — no calibration trigger.
So the brokenstar section is just one trigger.

All regex below is in **Mudlet UI form** (single backslash). In Mudlet,
`matches[1]` is the whole match and `matches[2]`, `matches[3]`, … are the groups.

***

## 0. Load order

1. Add `blademaster.lua` as a **Script** (Scripts → Add Item → paste the file).
   It defines the global `blademaster` table when the profile loads.
2. (Optional) Add `calibrate.lua` as a second Script for the `bmcal` tools.
3. Add the items below. They all reference `blademaster.*`, which exists after
   the script runs, so ordering within the profile doesn't matter at runtime.

***

## 1. REQUIRED — balance / equilibrium "used" trigger (fires your attacks)

This is the engine. When you spend balance (or eq), your game prints a line that
includes the recovery delay. Trigger on it, capture that delay, and pass it to
`on_recover` — it arms a `tempTimer` for `recoverTime - getNetworkLatency()` and
runs the dispatch the instant balance/eq returns, so the combo is built from
**current** limb / affliction / bleed state.

Type: **Perl regex**. Capture the recovery time (seconds) as a group → `matches[2]`:

```
^Balance Used: (\d+\.?\d*)
```

```lua
blademaster.on_recover(matches[2])
```

Notes:

* The captured value must be **seconds** (a float). If your line reports ms:
  `blademaster.on_recover(tonumber(matches[2]) / 1000)`.
* Wire **balance** at minimum (BM slashes are balance-based). Pointing an eq-used
  line at the same `on_recover` is safe — the `QUEUE ADDCLEARFULL FREESTAND`
  queue holds the attack until balance is actually up.
* `on_recover` only *schedules*; the dispatch fires only if the system is
  **armed** (you pressed an alias), then disarms — one attack per press.
* **Without this trigger:** only the fire-when-ready path works — one attack each
  time you press an alias *while eqbal is up*; the queue-during-recovery timing is lost.

> **No timed used-message?** Use GMCP instead: a Script registered on
> `gmcp.Char.Vitals` that, when `bal` flips 1→0, calls `blademaster.on_recover(<recovery seconds>)`.

***

## 2. Aliases

Mudlet aliases are regex. Pressing an alias **arms** the system (and fires
immediately if eqbal is up); otherwise the §1 trigger dispatches on balance return.

| Pattern | Script | What it does |
| --- | --- | --- |
| `^bm$` | `bm()` | arm in current mode |
| `^bmd$` | `bmd()` | double-prep (legs) |
| `^bmdq$` | `bmdq()` | quad-prep (arms + legs) |
| `^bmbs$` | `bmbs()` | brokenstar (bleed kill) |
| `^bmgroup$` | `bmgroup()` | group pommelstrike lock |
| `^bmreset$` | `bmreset()` | clear armed/latch state |
| `^bmstatus$` | `bmstatus()` | one-line status echo |

***

## 3. REQUIRED for brokenstar — impaleslash trigger

The brokenstar route reads **impaled** (`affstrack.impale`) and **bleeding**
(`ak.bleeding`) from AK, so it needs no impale / writhe / withdraw / bladetwist /
stand-up triggers. The one thing AK can't tell us is that *our* impaleslash
landed (which gates bladetwist → brokenstar), so wire this. Type: **Perl regex**.

```
steady in your grip, you drag its razor edge across arteries within [\w'\-]+'s abdomen\.$
```

```lua
blademaster.on_impaleslash()
```

The latch self-clears after `CONFIG.IMPALESLASH_LATCH` seconds (29 by default),
matching Levi's `timpaleslash`, so it can never get stuck and it guards brokenstar
against stale `ak.bleeding` from a previous target.

***

## 4. Recommended — hamstring trigger

Without it, prep strikes never advance past `hamstring` (the ladder thinks
hamstring is always expired and re-applies it instead of layering
paralysis/hypochondria/weariness/clumsiness). Limb breaks still work; only the
secondary affliction stack stalls.

> The exact game line isn't bundled (Levi sourced it separately). Hamstring once,
> copy the confirmation line from your log, anchor a pattern on it. Placeholder:

```
«your hamstring-application confirmation line»
```

```lua
blademaster.on_hamstring()
```

***

## 5. Optional — slash-damage calibration (only if you loaded `calibrate.lua`)

Slash damage lives in the **static** `blademaster.CONFIG.DMG` table (keyed on form).
There's no auto-calibration trigger — `bmcal` measures the four slashes in your
current form so you can paste real numbers in. Switch into a form, run `bmcal`,
repeat per form, then `bmcalshow`.

| Pattern | Script | What it does |
| --- | --- | --- |
| `^bmcal$` | `bmcal()` | measure the 4 slashes in the current form |
| `^bmcalshow$` | `bmcalshow()` | print paste-ready `blademaster.CONFIG.DMG` |
| `^bmcalstop$` | `bmcalstop()` | abort a calibration run |

***

## Quick checklist

* \[ ] `blademaster.lua` loaded as a Script
* \[ ] **balance/eq-used trigger** → `blademaster.on_recover(matches[2])` — REQUIRED (fires attacks)
* \[ ] 7 aliases (`bm`, `bmd`, `bmdq`, `bmbs`, `bmgroup`, `bmreset`, `bmstatus`)
* \[ ] **impaleslash trigger** → `blademaster.on_impaleslash()` — REQUIRED for brokenstar
* \[ ] hamstring trigger → `blademaster.on_hamstring()` (recommended)
* \[ ] (optional) fill `blademaster.CONFIG.DMG` per form, by hand or with `calibrate.lua`
