# Psion — Dependencies & Port Notes

`Psion.lua` is pure offense logic ported from the LEVI / Ataxia `psion.*` module
into the Legacy / AK environment. It **reads** opponent/self state from the host
frameworks and **writes** nothing back to them except attack commands. It
self-registers no aliases or triggers — you wire those by hand (see
`MUDLET_SETUP.md`).

Psion offense pivots on class-specific target states (unweave levels, mind-ravaged,
target mana, …). **affstrack + AK track the kill-critical ones natively** —
`affstrack.score.unweaving{mind,body,spirit}` (the unweave level, encoded ×100),
`ak.manapercent`, and `affstrack.score.mindravaged` — so the port reads
them straight from AK and **all three kill routes work with no triggers wired**.
`affstrack` even supplies `muddled` and `lightbind`, so the port tracks **no per-target
state at all** — `psion.state` is just the offense mode + firing latches. See
[Psion-specific state](#3-psion-specific-state) below.

---

## 1. Host-framework globals the module reads

Populated by the Legacy curing system + AK opponent tracker + Mudlet GMCP — **not**
by anything in this folder. If a global is missing the module degrades gracefully
(treats it as "no evidence"): with no `affstrack` it sees zero afflictions, with no
`ak`/feed it assumes full target mana, etc.

| Global | Shape / contract | Used for |
|---|---|---|
| `target` | string — current target name; also the key into `lb`. Empty/nil = no target. | everything |
| `affstrack.score[aff]` | number 0–100 confidence (100 = fresh apply, nil = none). | every affliction via `has_aff` (≥ `AFF_THRESHOLD`) — incl. `muddled`, `lightbind`, `mindravaged` |
| `lb[target].hits["head"]` | number 0–200 — head limb damage; `>=100` = broken. | head prep/break math for the weave ladder |
| `ak.defs.shield` | boolean — target shielded. | the cleave (shield-strip) pre-empt |
| `affstrack.score.unweaving{mind,body,spirit}` | the unweave **level encoded ×100** (100 = L1 … 500 = L5, `>= CRITICAL_LEVEL` = critical) — **not** the 0–100 confidence a normal aff carries. (`ak.psion.unweaving` tracks this too but is unreliable; unused.) | `unweave_level()` (÷100) → **Deconstruct** & **Flurry** gates |
| `ak.manapercent` | number — target mana %, **kept fresh by the per-turn `CONTEMPLATE <target>` the port sends** (so don't disable `CONFIG.CONTEMPLATE`). | `target_mana()` → **Excise** gate (primary kill) |
| `affstrack.score.mindravaged` | number 0–100 — mind-ravaged tracked as a normal aff. | `has_aff("mindravaged")` → mana pressure |
| `gmcp.Char.Vitals.bal` / `.eq` | **string** `"1"`/`"0"` — our balance / equilibrium. | `have_eqbal()` — Psion combos spend both |
| `Legacy.Curing.Affs[name]` | truthy — we have self-affliction `name`. | the `aeon` guard (one action per long balance) |
| `Legacy.Settings.Curing.status` | boolean — `== false` means curing/combat paused. | stand-down guard |
| `boxEcho.send(msg)` | status display sink. *Optional* — `notify` falls back to `cecho`, then `print`. | status + debug output |

Mudlet built-ins used directly: `send`, `tempTimer`, `killTimer`,
`getNetworkLatency`, `cecho`, `table.concat`, `string.*`, `math.*`.

---

## 2. Levi / Ataxia → Legacy / AK mapping

The exact translations applied when porting. The shipped file contains **zero**
`ataxia.*` / `tAffs` / `haveAff()` / `combatQueue()` references — only this doc and
the header mention them.

| Levi / Ataxia | Legacy / AK port |
|---|---|
| `haveAff("X")` / `tAffs.X` | `has_aff("X")` → `affstrack.score[X] >= CONFIG.AFF_THRESHOLD` |
| `pm` (target mana %) | `target_mana()` → `ak.manapercent` (else the contemplate hook) |
| `gmcp.Char.Vitals.bal == "1"` (Levi gated on bal only) | `have_eqbal()` — requires **bal AND eq** up |
| `ataxia.afflictions.aeon` | `self_aff("aeon")` → `Legacy.Curing.Affs.aeon` |
| `ataxia.settings.paused` | `is_paused()` → `Legacy.Settings.Curing.status == false` |
| `ataxia.settings.separator` (`";"`) | `"/"` hardcoded |
| `lb[target].hits[limb]` | **unchanged** (both systems use `lb`) |
| `ataxiaTables.limbData.psionweaves` (per-hit weave %, default 25) | `CONFIG.WEAVE_DAMAGE` (default 25) — see [calibration](#4-calibrating-weave_damage) |
| `ataxiaNDB_getClass(target)` | `get_target_class()` — hardcode your matchup (AK has no class feed) |
| `send("queue addclear free X")` | `SETALIAS PSIATK <chain>` + `QUEUE ADDCLEARFULL FREE PSIATK` |
| `combatQueue()` pre-attack prefix | **removed** — Legacy handles pre-attack hooks externally |
| `reboundHold.gate(fn)` | **dropped** — the just-in-time fire model already avoids weaving into rebounding |
| `tAffs.unweavingmind` / `criticalmind` (binary) | `unweave_level(kind)` = `affstrack.score.unweaving<kind>` ÷100 (`>0` = unweaving, `>= CRITICAL_LEVEL` = critical) |
| `tAffs.mindravaged` | `affstrack.score.mindravaged` (normal aff) — no trigger needed |
| `lightbind` / `inverted` / `transcendence` globals | `psion.state.*` — fed by wired triggers (fallback; `inverted` no longer gates flurry — the spirit **level** does) |

The kill-route logic, the `select_weave` priority ladder, the prepare/transcend
selection, and the `PSI_BLAST_AFFS` set are preserved **verbatim** from the source —
only the state *reads* were re-pointed at the AK/Legacy/GMCP API.

---

## 3. Psion-specific state

There is none. **Everything reads live:** unweave levels from
`affstrack.score.unweaving*`, target mana from `ak.manapercent`, and every affliction — including
`muddled` and `lightbind` — from `affstrack.score`. `psion.state` holds only the offense
`mode` and the firing latches; there are **no state-feed triggers** and no per-target
bookkeeping to wire or reset.

(Earlier revisions tracked unweaves / criticals / mana / mind-ravaged / muddled /
lightbind in the port, fed by ~12 trigger hooks. All of it was deleted as AK + affstrack
were confirmed to supply each — see the project history if you need the old fallbacks.)

---

## 4. Calibrating `WEAVE_DAMAGE`

The weave ladder decides when the head is one hit (`head_prepped`) or two hits
(`head_double_prepped`) from breaking, using `CONFIG.WEAVE_DAMAGE` as the per-hit
limb %. The source default is **25**. To calibrate to your own damage: pick a target
with a fresh (0%) head, weave a head attack solo a few times, read the `lb[target]
.hits["head"]` delta, divide by the number of hits, and set:

```lua
psion.CONFIG.WEAVE_DAMAGE = <measured %>
```

(The other ports ship a `calibrate.lua` for multi-weapon limb tuning; Psion preps
only the head with one weave-damage value, so a manual reading is enough.)

---

## 5. Commands the module emits (server side)

So you know what must exist in-game / in your reflexes. All are joined with `/`,
written to the `PSIATK` server alias, and run via `QUEUE ADDCLEARFULL FREE PSIATK`.

- Weaves: `WEAVE OVERHAND|BACKHAND|PUNCTURE|SEVER|DEATHBLOW|CLEAVE|FLURRY|DECONSTRUCT|LAUNCH <target>`,
  `WEAVE UNWEAVE <target> MIND|BODY|SPIRIT`, `WEAVE INVERT <target> MIND|BODY SPIRIT`,
  `WEAVE PREPARE DISRUPTION|LACERATION|VAPOURS|RATTLE`.
- Psionics: `PSI TRANSCEND BLAST|EXCISE|MUDDLE|SHATTER <target>`, `PSI EXCISE <target>`, `PSI EXPUNGE`.
- Reactive (`cc`/`vv`, on the `PSIUTIL` queue): `WEAVE LAUNCH <target>` + `ENACT LIGHTBIND <target>` (anti-escape); `PSI EXPUNGE` (self-cure).
- Per-turn framing: `WIELD RIGHT SHIELD` (configurable / disable-able via
  `CONFIG.WIELD_SHIELD` / `CONFIG.WIELD_COMMAND`), `ENACT LIGHTBIND <target>` (while
  unbound), `ASSESS`, `CONTEMPLATE <target>`.

If your aliases/syntax differ, adjust `CONFIG` and the command strings to match.

---

## 6. Testing

`psion_test.lua` is a self-contained smoke test (stubs every host global, captures
the queued chain, asserts each kill route + key ladder branch). Run it from this
folder:

```
lua psion_test.lua
```

Exits non-zero on any failure.
