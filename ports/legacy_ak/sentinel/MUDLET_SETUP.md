# Sentinel — Mudlet Setup (manual aliases & triggers)

`Sentinel.lua` self-registers **nothing** — no `tempAlias`, no `tempRegexTrigger`. You
create those by hand in Mudlet. This doc lists every item to add. The system is small to
wire: **one required trigger**, **four arm aliases**, and **one optional trigger** (only
needed for the dismember route).

- The **arm aliases** (`zz`/`xx`/`cc`/`vv`) pick the finisher and arm the system —
  `sentinel.arm_next_bal(...)`.
- The **"Balance used" trigger** is **required** — it's the firing engine. It calls
  `sentinel.on_balance(...)`, which arms a just-in-time `tempTimer` that fires your attack
  the instant balance returns (see §1).
- The **"skullbash lands" trigger** is **optional** — only the dismember route needs it, to
  advance its SKULLBASH → RATTLE step (see §3).

All regex below is in **Mudlet UI form** (single backslash). Don't double-escape. In Mudlet,
`matches[1]` is the whole match and `matches[2]`, `matches[3]`, … are the capture groups.

> The on-demand `tempTimer` inside `on_balance` is transient sequencing created per balance
> cycle — **not** a registered hook, so there's nothing to add or tear down for it.

---

## 0. Load order

1. Add `Sentinel.lua` as a **Script** (Scripts → Add Item → paste the file). It defines the
   global `sentinel` table when the profile loads.
2. Add the aliases and triggers below. They reference `sentinel.*`, which exists after the
   script runs, so ordering within the profile doesn't matter at runtime.
3. Make sure the host-framework globals the module reads are present — see §5.
4. Set your weapon item IDs in `sentinel.CONFIG.WEAPONS` (`SPEAR`, `HANDAXE`, `SHIELD`).

---

## 1. REQUIRED — "Balance used" trigger (fires your attacks)

This is the engine. When you spend balance, your game prints a line reporting the recovery
delay. Trigger on it, capture that delay (in seconds), and pass it to `on_balance` — it arms a
`tempTimer` for `interval - getNetworkLatency()` and runs the dispatch the instant balance
returns, so the combo is built from **current** limb / affliction / shield state.

Type: **Perl regex**. Capture the recovery seconds as a group → `matches[2]`:

```
^Balance used: (\d+\.\d+)s\.$
```
```lua
sentinel.on_balance(tonumber(matches[2]))
```

Notes:
- The pattern above is the line the port was written against. **Match it to your real game
  line** — replace it if yours differs (e.g. capitalisation, "seconds" spelled out, or a
  millisecond value, in which case divide: `sentinel.on_balance(tonumber(matches[2]) / 1000)`).
- The captured value must be **seconds** (a float).
- `on_balance` only *schedules*. The dispatch fires only if you **armed** it via one of the
  arm aliases (§2), then it disarms — **one attack per press**.
- Tune the lead time with `sentinel.CONFIG.PREARM_INTERVAL` (seconds). Leave it `nil` to use
  Mudlet's live `getNetworkLatency()`.
- **Without this trigger:** only the fire-when-ready path works — an attack fires only when you
  press an arm alias *while balance + eq are already up*. The "queue during recovery, fire on
  return" timing is lost.

> **No timed used-message?** Drive it from GMCP instead: a Script with a registered
> `gmcp.Char.Vitals` handler that, when `bal` flips `1`→`0`, calls `sentinel.on_balance(<recovery
> seconds>)` with a duration you supply.

---

## 2. Arm aliases (pick the finisher + arm)

Mudlet aliases are regex. Each press arms a single dispatch; it fires now if balance + eq are
up, otherwise the §1 timer fires it on balance return.

| Pattern | Script | Finisher |
|---|---|---|
| `^zz$` | `sentinel.arm_next_bal(false)` | **skullbash** (default) — break leg/leg/head, then SKULLBASH to death. |
| `^xx$` | `sentinel.arm_next_bal(true)` | **wrench** — break BOTH legs (TRIP the first, axe the second), then IMPALE → WRENCH once impaled. |
| `^cc$` | `sentinel.arm_next_bal("dismember")` | **dismember** — break BOTH legs (no head), then SKULLBASH → ENRAGE BUTTERFLY + ENSNARE → RATTLE → OUTR ROPE/TRUSS → IMPALE → DISMEMBER. |
| `^vv$` | `sentinel.arm_next_bal("lock")` | **lock** — go for the truelock, not a limb kill: once impatience+asthma+weariness are up, TRIP one leg (off-herb-balance opener), then handaxe anorexia + slickness inside the 4s tempslickness window, then SKULLBASH the prone-locked target. Separate path — leaves zz/xx/cc untouched. |

The finisher you pick is a **preference**, not an engine latch: it persists until you press a
different arm alias. So `cc` keeps driving dismember on every subsequent arm until you press
`zz`/`xx` to switch back. Each step is still re-read from live state every dispatch.

`zz`/`xx`/`cc`/`vv` are just default buttons — rename the patterns to whatever keys you bind. You
normally never call `sentinel.dispatch()` directly; go through an arm alias.

---

## 3. OPTIONAL — "skullbash lands" trigger (dismember only)

The dismember route's `SKULLBASH` → `ENSNARE` transition is the one step that isn't visible
in target state (nothing in `affstrack`/`lb` reports the SKULLBASH landing). Wire your
"your skullbash lands" game line to:

```lua
sentinel.on_skullbash()
```

This stamps a 10-second window (`sentinel.CONFIG.SKULLBASH_FLAG_SECONDS`) during which the
dismember route knows the SKULLBASH connected and advances to ENRAGE BUTTERFLY + ENSNARE.
**Not needed** for the skullbash, wrench, or lock routes; harmless to add regardless. Match
the pattern to your real skullbash-landed line.

---

## 4. Optional convenience aliases

| Pattern | Script | What it does |
|---|---|---|
| `^sentstatus$` | `sentstatus()` | Read-only status: finisher, limb prep bars, per-route readiness, conditions. |
| `^sentreset$` | `sentreset()` | Teardown — resets the finisher to skullbash and clears state. Use when a fight ends. |

---

## 5. Prerequisites — host-framework globals (not configured here)

The module is pure offense logic; it **reads** opponent/self state from the Legacy + AK
framework. These are populated by that framework's own triggers/GMCP, **not** by anything in
this doc. If they're missing, the system runs on zeros. The module needs:

| Global | Provides |
|---|---|
| `Legacy.Curing.Affs` | self afflictions (`aeon` gate) |
| `Legacy.Settings.Curing.status` | combat-paused gate |
| `Legacy[<name>].morph` | current morph form (Jaguar/Basilisk) |
| `ak.defs` | opponent shield / rebounding |
| `affstrack` | opponent afflictions — `affstrack.score[aff]` (0-100), `affstrack.impale` |
| `lb[target].hits[limb]` | opponent limb damage (0-200) |
| `target` / `targetparry` | current target, and the limb they're parrying |
| `boxEcho.send(...)` | status display sink (falls back to `cecho`/`print` if absent) |
| `gmcp.Char.Vitals` | `bal` / `eq` for the fire-when-ready check; `Char.Status.name` |

---

## Quick checklist

- [ ] `Sentinel.lua` loaded as a Script
- [ ] Weapon IDs set in `sentinel.CONFIG.WEAPONS`
- [ ] **"Balance used" trigger** → `sentinel.on_balance(tonumber(matches[2]))` — REQUIRED
- [ ] `zz` alias → `sentinel.arm_next_bal(false)` (skullbash)
- [ ] `xx` alias → `sentinel.arm_next_bal(true)` (wrench)
- [ ] `cc` alias → `sentinel.arm_next_bal("dismember")` (dismember)
- [ ] `vv` alias → `sentinel.arm_next_bal("lock")` (lock — single-leg truelock)
- [ ] *(dismember only)* "skullbash lands" trigger → `sentinel.on_skullbash()`
- [ ] *(optional)* `sentstatus` / `sentreset` aliases
- [ ] Host-framework globals present (§5): `Legacy`, `ak`, `affstrack`, `lb`, `target`, `targetparry`, `boxEcho`, `gmcp`
