# Magi — Mudlet wire-up

`magi.lua` self-registers **nothing**. You create the items below by hand. The wiring is
now small: AK's `affstrack` supplies the Magi cast-states (burns/aflame, conflagrate,
scalded, calcifiedtorso, calcifiedhead, frozen, hypothermia), so the only triggers you
*need* are the firing line and the two states AK can't see (scintilla cooldown, shalestorm
channel). Everything in §3 is an optional fallback.

After loading, set your weapon IDs:

```lua
magi.CONFIG.WEAPONS.STAFF  = "staffNNNNNN"   -- your elemental staff item id
magi.CONFIG.WEAPONS.SHIELD = "shield"        -- or your shield id / keyword
```

A still-default `staff569815` will silently fail to wield — override it.

---

## 1. Firing (required)

| Type | Pattern | Calls |
| --- | --- | --- |
| Alias | `^mfire$`   | `mfire()`   — arm, fire mode (default) |
| Alias | `^mwater$`  | `mwater()`  — arm, water mode |
| Alias | `^mlock$`   | `mlock()`   — arm, lock mode |
| Alias | `^msalve$`  | `msalve()`  — arm, salve mode |
| Alias | `^mgroup$`  | `mgroup()`  — arm, group mode |
| Alias | `^magiarm$` | `magiarm()` — re-arm the current mode (no mode change) |
| Alias | `^magistatus$` | `magistatus()` — status box |
| Alias | `^magireset$`  | `magireset()`  — wipe our latches (shalestorm/scintilla/affs) |
| Regex | `^(Balance\|Equilibrium) used: (\d+\.\d+)s\.$` | `magi.on_balance(tonumber(matches[3]))` |

`magi.arm()` fires immediately if you have eq **and** bal; otherwise it latches and the
`...used` trigger schedules the just-in-time fire. A Magi combo spends **both** balance and
equilibrium, so the one regex above matches both lines — the module keeps the timer for
whichever returns last.

**Target change reset (required).** Wire your target-change path to `magi.reset()` so our
own per-target latches (shalestorm channel, scintilla cooldown, applied-aff fallbacks) are
wiped. The AK-tracked cast-states reset themselves with the target via `affstrack`.

```lua
-- e.g. an AK "target changed" event handler, or your own `tar <name>` alias:
magi.reset()
```

**Resonance (automatic).** `magi.dispatch()`/`magi.status()` parse
`gmcp.Char.Vitals.charstats` (`Rfire/Rwater/Rearth/Rair: Major/Moderate/Minor`). No wiring
needed; optionally bind `get_resonance()` to a `gmcp.Char.Vitals` event to keep the status
box live.

---

## 2. Our-own-state triggers (recommended — AK can't see these)

Perl regex, anchored as in the Levi source. `matches[2]` is the target-name capture.

| State | Pattern | Calls |
| --- | --- | --- |
| Scintilla spark (over-cast guard) | `^You sense a combustive spark take hold of (\w+)\.$` | `magi.track.scintillaSpark(matches[2])` |
| Scintilla ignite (clears the guard) | `^Flames ignite all over the body of (\w+), fanned to intensity in an instant\.$` | `magi.track.scintillaIgnite(matches[2])` |
| Shalestorm start (our channel) | `^You call upon the might of Elemental Earth to grind down (\w+)` | `magi.track.shalestormStart(matches[2])` |
| Shalestorm end | `^You can no longer maintain your shalestorm against (\w+)\.$` | `magi.track.shalestormEnd(matches[2])` |

`scintillaSpark` stops the engine over-casting scintilla during its ~4s windup;
`shalestormStart/End` track whether your shalestorm channel is live (the end handler ignores
the message while your earth resonance is still up — anti-illusion). The shalestorm shield-
snap and boulder limb-breaks already feed AK's `ak.defs`/`lb`, so they need no wiring here.

---

## 3. Applied-affliction fallback (optional — only if AK misses a Magi-applied aff)

The decision tree reads ordinary afflictions (`asthma, frostbite, shivering, weariness,
nausea, nocaloric, paralysis, anorexia, clumsiness, waterbond, blistered`) from `affstrack`.
Most are standard affs AK tracks. **But** Magi applies some through *class-specific* cast
lines AK may not parse. If a route stalls (e.g. lock never advances past horripilation, or
the freeze route never sees `nocaloric`), wire the matching handler — its latch is OR'd with
`affstrack` and cleared on target change. Drop any whose aff AK already tracks.

| Effect | Pattern | Calls |
| --- | --- | --- |
| Lock: waterbond/blistered (gate) | the horripilation / fire-major land lines | `magi.track.resFireBlistered(matches[2])` ; `magi.track.resAff("waterbond", matches[2])` |
| Bombard → clumsiness | `^You tap the Elemental Plane of Earth, summoning up a flurry of rocks to bombard (\w+)\.$` | `magi.track.bombard(matches[2])` |
| Mudslide → slickness + prone | `^You weave earth and water and a torrent of thick mud thunders forth to roll over (\w+), knocking \w+ sprawling\.$` | `magi.track.mudslide(matches[2])` |
| Fulminate mental chain | `^You click your fingers and lightning strikes from the air to smite (\w+)\.$` | `magi.track.fulminate(matches[2])` |
| Freeze buildup (nocaloric→shivering) | `^You rip the heat from (\w+)\.$` | `magi.track.freezeRip(matches[2])` |
| Resonance affs (asthma/anorexia/paralysis/…) | the per-element resonance lines | `magi.track.resAff("<aff>", matches[2])` / `magi.track.curedAff("<aff>", matches[2])` |

`freezeRip` advances only the `nocaloric → shivering` buildup (AK owns `frozen`/
`hypothermia`). Wire it only if AK does not track `nocaloric`/`shivering`.

---

## 4. Stormhammer multi-target (optional)

`mgroup` and the low-HP stormhammer kill sweep up to 3 enemies in the room. Out of the box
the selector treats only your current `target` as hostile (single-target). For real sweeps,
populate the enemy set or override the hook:

```lua
magi.storm.enemies = { Bubba = true, Joe = true }            -- a name set you maintain
function magi.storm.is_enemy(name) return myEnemyList[name] == true end   -- or your list
function magi.storm.citizenship(name) return ndb_getCitizenship(name) end -- for "city" mode
magi.storm.setMode("all")   -- "city" | "all" | "priority"
```

`gmcp.Room.Players` supplies the candidate list automatically.

---

## 5. Notes

- The module reads `boxEcho.send` for status if present, else falls back to `cecho`.
- Reactive one-offs use a separate `MAGIUTIL` server alias; attacks use `MAGIATK`. Both go
  out via `QUEUE ADDCLEARFULL FREESTAND`. Change `magi.CONFIG.QUEUE`/`ATK_ALIAS` if your
  queue contract differs.
- `blisteredDuration` (15s) and `scintillaDuration` (4s) are client-side estimates — confirm
  against current Achaea Elementalism timings.
