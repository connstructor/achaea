# Shikudo God Mode — Mudlet Setup (manual aliases & triggers)

`shikudo.lua` self-registers **nothing** — you wire the alias(es) by hand. The good
news: this port needs **no required triggers**. Limb damage comes from `lb[target].hits`,
afflictions from `affstrack.score`, the parried limb from `targetparry`, and your monk
form/kata from `gmcp.Char.Vitals.charstats` — all supplied by AK/Legacy. Hyperfocus is
read live from `ak.limbs.hyperfocus`, so even that needs no trigger.

All regex below is in **Mudlet UI form** (single backslash). `matches[1]` is the whole
match; `matches[2]`, `matches[3]`, … are the capture groups.

---

## 0. Load order

1. Add `shikudo.lua` as a **Script** (Scripts → Add Item → paste the file). It defines
   `monk.shikudo`, the `sk*` aliases, and the `mod.limbDamage` lookup table on load.
2. (Recommended) Add `calibrate.lua` as a second **Script** — it defines `skcal` /
   `skcalshow` / `skcalstop` for measuring `limbDamage` (see §3).
3. Add the attack alias in §1. Optionally add §2 (auto-fire).
4. Set your target the usual AK way (`tar <name>` → the `target` global).

---

## 1. REQUIRED — the attack alias

Mudlet aliases are regex. Pressing `sk` rebuilds the next combo from **current** limb /
affliction / form state and queues it.

| Pattern | Script | What it does |
| --- | --- | --- |
| `^sk$` | `sk()` | dispatch one tick (build + queue the next combo) |
| `^skstatus$` | `skstatus()` | status panel (5-limb prep, phase, kill conditions) |
| `^skreset$` | `skreset()` | clear runtime state (echo debounce) |
| `^skdebug$` | `skdebug()` | toggle the per-tick debug echo |

The combo is queued with `QUEUE ADDCLEARFULL EQBAL SKATK`, so the server holds it until you
have **equilibrium + balance** and then fires it. One press = one queued combo.

---

## 2. RECOMMENDED — auto-fire on recovery ("god mode")

For hands-free combat, call `monk.shikudo.dispatch()` again each time eq/bal returns. Every
dispatch reads live state, so re-firing on recovery is always safe.

Easiest: a **Script** registered on GMCP vitals that re-dispatches when balance/equilibrium
flips back up. Example body:

```lua
-- Run on the "gmcp.Char.Vitals" event (Scripts → registered event handlers)
if gmcp.Char.Vitals.bal == "1" and gmcp.Char.Vitals.eq == "1" then
  if target and target ~= "" then monk.shikudo.dispatch() end
end
```

Or, if your game prints a timed balance-recovery line, trigger on it and call
`monk.shikudo.dispatch()`. (No prearm timer is needed — the EQBAL queue does the waiting.)

> Stop attacking by pausing curing (`Legacy.Settings.Curing.status == false`), clearing your
> target, or removing/disabling the auto-fire handler. The engine stands down under aeon,
> self-stupidity, and while soft-locked (it self-breaks with `stand`/`fitness`).

---

## 3. RECOMMENDED — calibrate the limb-damage table

`monk.shikudo.limbDamage` ships with rough seed values. Because limb damage scales with your
stats + staff artifact, measure your real numbers once with `calibrate.lua` (load it per §0):

1. `tar <a sturdy mob / sparring partner>` with limbs near 0%.
2. Adopt a form and run `skcal` — it fires each limb-damaging attack available in that form,
   reads the `lb` delta, and records it. Repeat across **Willow, Rain, Oak, Gaital** to cover
   all nine attacks (it reports which it measured).
3. `skcalshow` prints a paste-ready `mod.limbDamage = { … }` — paste it over the table in
   `shikudo.lua` and reload. `skcalstop` aborts a run.

| Pattern | Script | What it does |
| --- | --- | --- |
| `^skcal$` | `skcal()` | measure this form's limb-damaging attacks |
| `^skcalshow$` | `skcalshow()` | print the paste-ready `limbDamage` table |
| `^skcalstop$` | `skcalstop()` | abort a calibration run |

`skcal` sends `hyperfocus none` first so head numbers aren't halved; re-target between forms so
limbs reset.

---

## Quick checklist

* \[ ] `shikudo.lua` loaded as a Script
* \[ ] alias `^sk$` → `sk()` — REQUIRED
* \[ ] (recommended) auto-fire handler → `monk.shikudo.dispatch()` on eq/bal recovery
* \[ ] (recommended) `calibrate.lua` loaded; `skcal` per form → paste `skcalshow` into shikudo.lua
