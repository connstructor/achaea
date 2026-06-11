# Blademaster — Mudlet Setup (manual aliases & triggers)

`blademaster.lua` self-registers **nothing** — no `tempAlias`, no
`tempRegexTrigger`, no event handler. You create those by hand in Mudlet. This
doc lists every item to add.

- **Aliases** call the `bm*()` handler functions — they **arm** the system.
- **Triggers** call the `blademaster.on*` / `blademaster.capture*` callbacks.
- **One balance/equilibrium-"used" trigger** is **required** — it's what fires
  your attacks (arms a just-in-time `tempTimer`); see §1. Without it you only get
  fire-when-ready dispatch straight from the alias.

All regex below is in **Mudlet UI form** (single backslash). Don't double-escape —
the `\d` / `\w` / `\.` you see here is exactly what you type into the pattern box.
In Mudlet, `matches[1]` is the whole match and `matches[2]`, `matches[3]`, … are
the capture groups.

---

## 0. Load order

1. Add `blademaster.lua` as a **Script** (Scripts → Add Item → paste the file).
   It defines the global `blademaster` table when the profile loads.
2. (Optional) Add `calibrate.lua` as a second Script for the `bmcal` tools.
3. Add the items below. They all reference `blademaster.*`, which exists after
   the script runs, so ordering within the profile doesn't matter at runtime.

---

## 1. REQUIRED — balance / equilibrium "used" trigger (fires your attacks)

This is the engine. When you spend balance (or eq), your game prints a message
that includes the recovery delay. Trigger on it, capture that delay, and pass it
to `scheduleDispatch` — it arms a `tempTimer` for
`recoverTime - getNetworkLatency()*2` and runs the dispatch the instant balance/eq
returns, so the combo is built from **current** limb / affliction / bleed state.

Type: **Perl regex**. Capture the recovery time (seconds) as a group → `matches[2]`:

```
«your balance/eq-used line, with the recovery time captured»
```
```lua
blademaster.scheduleDispatch(matches[2])
```

Example shape (replace with your real line):
```
^Balance Used: (\d+\.?\d*)
```

Notes:
- The captured value must be **seconds** (a float). If your line reports ms:
  `blademaster.scheduleDispatch(tonumber(matches[2]) / 1000)`.
- Wire **balance** at minimum (BM slashes are balance-based). Pointing an eq-used
  line at the same `scheduleDispatch` is safe — the `QUEUE ADDCLEARFULL FREESTAND`
  queue holds the attack until balance is actually up, so an eq-timed fire just
  queues a touch early.
- `scheduleDispatch` only *schedules*; the dispatch fires only if the system is
  **armed** (you pressed an alias), then disarms — one attack per press.
- **Without this trigger:** only `arm()`'s fire-when-ready path works — one attack
  each time you press an alias *while eqbal is up*; the "queue during
  recovery, fire on return" timing is lost.

> **No timed used-message?** Use GMCP instead: a Script with registered event
> `gmcp.Char.Vitals` that, when `bal` flips 1→0, calls
> `blademaster.scheduleDispatch(<recovery seconds>)` with a duration you supply
> (e.g. from your curing system / class balance constant).

---

## 2. Aliases

Mudlet aliases are regex. Create each with the given pattern and script. Pressing
an alias **arms** the system (and fires immediately if eqbal is up);
otherwise the §1 used-trigger's timer dispatches the attack on balance return.

| Pattern | Script | What it does |
|---|---|---|
| `^bm$` | `bm()` | arm in current mode |
| `^bmd$` | `bmd()` | double-prep (legs) |
| `^bmdq$` | `bmdq()` | quad-prep (arms + legs) |
| `^bmbs$` | `bmbs()` | brokenstar (bleed kill) |
| `^bmgroup$` | `bmgroup()` | group pommelstrike lock |
| `^bmreset$` | `bmreset()` | full state reset |
| `^bmstatus$` | `bmstatus()` | double-prep status panel |
| `^bmstatusq$` | `bmstatusq()` | quad-prep status panel |

---

## 3. Triggers — damage capture (per-stance auto-calibration)

These feed `blademaster.limbDamage[stance]` so the prep/break math tracks your
actual slash damage. Type: **Perl regex**.

**Leg damage**
```
^As you carve into .+, you perceive that you have dealt (\d+\.?\d*)% damage to \w+ (left|right) leg
```
```lua
blademaster.captureLegDamage(matches[2], matches[3])
```

**Arm damage**
```
^As you carve into .+, you perceive that you have dealt (\d+\.?\d*)% damage to \w+ (left|right) arm
```
```lua
blademaster.captureArmDamage(matches[2], matches[3])
```

**Upper (torso/head) damage**
```
^As you carve into .+, you perceive that you have dealt (\d+\.?\d*)% damage to \w+ (torso|head)
```
```lua
blademaster.captureUpperDamage(matches[2], matches[3])
```

---

## 4. Triggers — brokenstar state machine

These drive the impale → bladetwist → brokenstar progression and the
writhe/stand recovery. Type: **Perl regex**.

**Impale landed**
```
^You draw your blade back and plunge it deep into the body of ([\w'\-]+) impaling [\w'\-]+ to the hilt\.$
```
```lua
blademaster.onImpaleSuccess()
```

**Impaleslash landed**
```
steady in your grip, you drag its razor edge across arteries within ([\w'\-]+)'s abdomen\.$
```
```lua
blademaster.onImpaleslashSuccess()
```

**Bleeding hit 700+ (heavy torrents)**
```
^You observe heavy torrents of lifeblood spilling from ([\w'\-]+)'s near-fatal wounds\.$
```
```lua
blademaster.onBleedingReady()
```

**Bleeding value update** (from `assess` / `discern` — `[280]`, `[850]`, …)
```
You observe .+ \[(\d+)\]
```
```lua
blademaster.onBleedingUpdate(matches[2])
```

**Blade withdrawn**
```
^You wrench your blade free of ([\w'\-]+)
```
```lua
blademaster.onWithdrawSuccess()
```

**Target writhed free of impale**
```
manages to writhe \w+self free of the weapon which impaled
```
```lua
blademaster.onTargetUnimpaled()
```

**Bladetwist fired** (the triple-twist combo echo — increments the twist count)
```
BLADETWIST \[\|\] BLADETWIST \[\|\] BLADETWIST
```
```lua
blademaster.onBladetwistSuccess()
```

**Target stands up**
```
^(\w+) stands up\.$
```
```lua
blademaster.onTargetStandUp(matches[2])
```

---

## 5. Recommended triggers

**Hamstring applied** — *recommended.* Without it, prep strikes never advance
past `hamstring` (the system thinks hamstring is always expired and re-applies it
every tick instead of layering paralysis/hypochondria/weariness/clumsiness). Limb
breaks still work; only the secondary affliction stack stalls.

> The exact game line isn't bundled (Levi sourced it from a separate trigger).
> Hamstring once, copy the confirmation line from your log, and anchor a pattern
> on it. Placeholder:
```
«your hamstring-application confirmation line»
```
```lua
blademaster.onHamstringApplied()
```

**Leg salve (prone timer)** — *optional.* Feeds the vestigial prone timer
(`onLegSalveDetected`); no behavioral effect since balanceslash was dropped. Add
only if you later revive that mechanic.
```
takes some salve from a vial and rubs it on \w+ legs
```
```lua
blademaster.onLegSalveDetected()
```

---

## 6. Optional — calibration aliases (only if you loaded `calibrate.lua`)

| Pattern | Script | What it does |
|---|---|---|
| `^bmcal(?:\s+(\w+))?$` | `bmcal(matches[2])` | calibrate a stance (arg) or current stance |
| `^bmcalshow$` | `bmcalshow()` | print paste-ready `blademaster.limbDamage` |
| `^bmcalstop$` | `bmcalstop()` | abort a calibration run |
| `^bmcalreset$` | `bmcalreset()` | clear calibration results |

`bmcal` with no stance (`matches[2]` is `nil`) calibrates the current stance.
`calibrate.lua` uses an internal `tempTimer` to space its measurement attacks —
that's a transient one-shot delay inherent to the tool, not a registered hook.

---

## Quick checklist

- [ ] `blademaster.lua` loaded as a Script
- [ ] **balance/eq-used trigger** → `blademaster.scheduleDispatch(matches[2])` — REQUIRED (fires attacks)
- [ ] 8 aliases (`bm`, `bmd`, `bmdq`, `bmbs`, `bmgroup`, `bmreset`, `bmstatus`, `bmstatusq`)
- [ ] 3 damage-capture triggers (leg / arm / upper)
- [ ] 8 brokenstar triggers (impale, impaleslash, bleeding-ready, bleeding-update, withdraw, writhe, bladetwist, stand-up)
- [ ] hamstring trigger (recommended — needs your game line)
- [ ] leg-salve trigger (optional)
- [ ] `calibrate.lua` + 4 `bmcal*` aliases (optional)
