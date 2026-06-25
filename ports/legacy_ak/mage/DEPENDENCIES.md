# Magi — Legacy / AK port dependency mapping

Maps the LEVI/Ataxia Magi (Elementalism) offense onto **Legacy** (self curing
framework) + **AK** (opponent affliction & limb tracker). The decision tree is ported
verbatim from the source; only the **state reads** are re-pointed.

**Source of truth (Levi):**
- `src_new/scripts/.../mage/001_Resonance.lua` — self resonance from GMCP charstats
- `src_new/scripts/.../mage/004_Magi_Offense.lua` — the unified 5-mode decision tree
- `src_new/scripts/.../mage/005_Stormhammer_Targeting.lua` — 3-target selector
- `src_new/triggers/.../leviticus/**` — the original cast-state feeds (now read from AK affstrack)

**Destination:** `magi.lua` (logic + a few tracking handlers), `magi_test.lua` (108 asserts),
`MUDLET_SETUP.md` (hand-wiring), this file.

---

## Why this is a rewrite, not a tweak

The previous AK port was removed "for rework." Its flaw: it read the Magi class-mechanic
states (`aflame`/burns, `conflagrate`, `scalded`, `calcifiedtorso`, `calcifiedhead`,
`frozen`, `hypothermia`) from `affstrack.score` keys that **did not yet exist** in AK, so
every read returned 0/false and the engine degenerated to a `magma → dehydrate` loop. It
also shipped **no test**.

AK now tracks those keys (`aflame` is 100 per burn stack; the rest are standard 0–100
confidence). So this port reads the cast-states **live from AK affstrack** — AK owns the
decay/clear, no per-target bookkeeping. Only state AK genuinely cannot see is self-tracked:
our **shalestorm** channel and the **scintilla** over-cast cooldown, plus an OPTIONAL
`magi.affs` fallback for affs Magi applies via class-specific lines AK may miss.

---

## Tier 1 — Target state (AK domain)

| Levi symbol | Used for | Legacy/AK equivalent | Notes |
| --- | --- | --- | --- |
| `haveAff("X")` | boolean aff | `has_aff("X")` → `score(X) >= AFF_THRESHOLD (30)` | `score` = `affstrack.score[X]` OR an optional magi-applied latch |
| `getAffProbabilityV3("X")` | 0–1 prob | `prob("X")` → `score(X)/100` | the `>= 0.5` gates use this |
| `haveAff("shield")` | shield strip gate | `ak.defs.shield` (fallback `has_aff("shield")`) | |
| `haveAff("rebounding")`/`shield` | any block | `ak.defs.rebounding or ak.defs.shield` | |
| `targetHealth` / `php` | HP% kill gates | `target_hp()` → `floor(ak.currenthealth/ak.maxhealth*100)` | refreshed by tail `assess`; default 100 |
| `haveAff("brokenleftleg")` … | mending-balance count | `is_limb_broken("left leg")` → `lb[target].hits[<spaced>] >= 100` | broken limbs live in `lb`, not affstrack |

### Magi cast-states — read LIVE from AK affstrack

The decision tree's `magi.state.X` reads are re-pointed to file-local accessors over
`affstrack`. No self-tracking, no triggers, no reset — AK owns these.

| Source `state.X` | This port reads | AK key |
| --- | --- | --- |
| `burns` (0–5) | `burns_count()` = `min(floor(score/100), 5)` | `affstrack.score.aflame` (100/stack) |
| `conflagrated` | `is_conflagrated()` = `has_aff(...)` | `affstrack.score.conflagrate` |
| `scalded` | `is_scalded()` | `affstrack.score.scalded` |
| `calcifiedTorso` | `is_calcified_torso()` | `affstrack.score.calcifiedtorso` |
| `calcifiedSkull` | `is_calcified_skull()` | `affstrack.score.calcifiedhead` |
| `frozen` | `is_frozen()` = `prob("frozen") >= 0.5` | `affstrack.score.frozen` |
| `hypothermia` | `is_hypothermia()` = `prob("hypothermia") >= 0.5` | `affstrack.score.hypothermia` |

`calcifiedtorso` is applied by `CAST EMANATION AT <target> EARTH` at level-3 earth resonance
(the tree's P6) — confirm AK's `calcifiedtorso` tracker is live.

### Self-tracked here — state AK cannot see

| State | Where | Fed by |
| --- | --- | --- |
| `shalestorm` (our channel) | `magi.state.shalestorm` | `magi.track.shalestormStart` / `shalestormEnd` (anti-illusion: earth reso > 0) |
| `scintillaSpark` (+4s over-cast guard) | `magi.state.scintillaSpark` | `magi.track.scintillaSpark` / `scintillaIgnite` |

### Magi-APPLIED affs — `magi.affs` OPTIONAL fallback (OR'd with affstrack)

For affs Magi inflicts via class-specific lines AK may not parse: `waterbond`, `blistered`
(15s), `clumsiness` (bombard), `slickness`/`prone` (mudslide), the fulminate
`fulminated→epilepsy→paralysis` chain, the `nocaloric → shivering` freeze buildup
(`freezeRip`), and the resonance affs. Fed by `magi.track.resAff/curedAff/bombard/mudslide/
fulminate/resFireBlistered/freezeRip`; cleared on target change. Wire only the ones AK
misses — `affstrack` supplies the rest. **Pending confirmation of which AK tracks natively.**

---

## Tier 2 — Self state (Legacy domain)

| Levi symbol | Legacy equivalent |
| --- | --- |
| `ataxia.afflictions.aeon` | `self_aff("aeon")` → `Legacy.Curing.Affs.aeon` |
| `ataxia.settings.paused` | `is_paused()` → `Legacy.Settings.Curing.status == false` |
| `gmcp.Char.Vitals.bal`/`.eq` | `have_eqbal()` (strings `"1"`) — used by `magi.arm`, not in-dispatch |
| `gmcp.Char.Status.class` guard | `my_class()` — **lenient**: blocks only a *known* non-Magi class (graceful if gmcp absent) |
| `magi.resonance` (V3-fed) | parsed from `gmcp.Char.Vitals.charstats` (`Rfire/…: Major/Moderate/Minor`) — unchanged |
| `ataxia.settings.separator` (`"::"`) | `CONFIG.SEPARATOR` (`"/"`, house SETALIAS convention) |
| `send("queue addclearfull freestand X")` | `SETALIAS MAGIATK …` + `QUEUE ADDCLEARFULL FREESTAND MAGIATK` |
| `partyrelay` (global) | `CONFIG.partyRelay` (off by default) |

## Tier 3 — Stormhammer (005)

| Levi symbol | Equivalent |
| --- | --- |
| `ataxia.playersHere` | `gmcp.Room.Players` ("the soul of " stripped) |
| `ataxiaTemp.enemies` | `magi.storm.is_enemy(name)` — override / `magi.storm.enemies` set (default: target only) |
| `ataxiaNDB_getCitizenship` | `magi.storm.citizenship()` — default nil → "city" degrades to "all" |
| `tprio.list` (priority mode) | guarded; degrades to "all" if absent (case-normalised) |
| `gmcp.Char.Status.name` | `my_name()` self-exclusion |

---

## Intentional divergences from the source

- **Dropped** the source's `if getAffProbabilityV3("burning")==0 then burns=0` stale reset
  and the self-tracked burns counter entirely — burns are read live from `affstrack.score.aflame`
  (100/stack), which AK keeps current.
- **Firing model**: arm + JIT timer (house "new-family"), dual-resource (bal+eq), instead
  of the source's direct dispatch with an inline eq/bal gate. Dispatch does not re-gate
  eq/bal (the FREE queue holds the chain).
- **Class guard** is lenient (blocks only a *known* different class) rather than blocking
  whenever class ≠ "Magi", so an unloaded gmcp doesn't dead-lock the engine.
- **Stormhammer** returns its command into the unified sender instead of sending directly.
- **Not ported** (out of scope / dead / foreign): `004_Mizik_Bullshit` (superseded
  alternate offense), `006_Target_Priority`/`tprio` (Levi-coupled; trust `tar X`),
  `197_Magi_Reset` (dangling), `122_DAMAGE` (misfiled Knight), `096_Mage_PvE`
  (superseded), `021_Magi_Vibes_Tracking` (Crystalism VIBES ≠ Elementalism RESONANCE).

---

## Confirm before trusting in combat (`[ ]` = verify on your character)

- [ ] **Weapon IDs** — set `magi.CONFIG.WEAPONS.STAFF/.SHIELD`; the placeholder won't wield.
- [ ] **Separator / queue** — `"/"` + `FREESTAND` assumed; confirm against your Legacy queue.
- [ ] **AK cast-state keys live** — `aflame` (100/stack), `conflagrate`, `scalded`,
      `calcifiedtorso` (tracker was reported broken — fix it), `calcifiedhead`, `frozen`,
      `hypothermia`. These ARE the kill routes; a missing key kills that route.
- [ ] **AK aff key spellings** — `asthma/frostbite/shivering/weariness/nausea/nocaloric/`
      `paralysis/anorexia/clumsiness`; wire the §3 fallback handlers for any AK does not track
      (esp. `waterbond`/`blistered` for lock, `nocaloric`/`shivering` for freeze pressure).
- [ ] **Latch durations** — `blisteredDuration` 15s, `scintillaDuration` 4s (fallback latches).
- [ ] **Enemy list** — populate `magi.storm.enemies` / override `is_enemy` for real
      3-target stormhammer; default is single-target-safe.
- [ ] **Target-change reset** — wire `magi.reset()` to your target-change path.

## Status

🟢 `luac -p magi.lua` clean. 🟢 `lua magi_test.lua` → **108 passed, 0 failed** — every kill
route, the 5 mode branches, **priority pre-emption ordering**, the AK cast-state reads
(aflame encoding, calcifiedtorso pivot, scalded pivot), all guards, the dual-resource arm/JIT
firing, the stormhammer selector (city/all/priority/soul-of/setMode), the burning sub-tree
arms, and the self-tracked + fallback handlers. Hardened against an adversarial multi-agent
review, then re-pointed to AK affstrack for the cast-states.
