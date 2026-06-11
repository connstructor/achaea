# Magi Consolidation — Legacy / AK Port

Mapping doc for porting the Magi (Elementalism) offense to **Legacy** (self
combat framework) + **AK** (enemy limb & affliction tracker).

**Source files (source of truth):**
- `src_new/scripts/.../mage/001_Resonance.lua` — resonance state engine
- `src_new/scripts/.../mage/004_Magi_Offense.lua` — unified 5-mode decision tree
- `src_new/scripts/.../mage/005_Stormhammer_Targeting.lua` — 3-target selector

**Not ported:**
- `mage/004_Mizik_Bullshit.lua` — legacy/foreign `MagiFire` loop. Superseded by
  004's unified tree; reads dead globals (`ak.defs`, `Legacy.Curing`, `ashbeast`,
  `affstrack.score`) from a different lineage.
- `mage/006_Target_Priority.lua` (`tprio`) — class-agnostic targeting queue,
  heavily Levi-coupled (`switchTarget`, `ataxiaEcho`, GMCP room handlers). Omitted
  exactly like the other ports, which **trust the user's `tar X`**.

**Destination files:**
- `magi.lua` — the module (pure logic; self-registers nothing)
- `MUDLET_SETUP.md` — every alias / trigger to add by hand
- `DEPENDENCIES.md` — this mapping doc

**Strategy:** Inline replace, no shim layer. Source namespace kept
(`magi.offense` / `magi.resonance` / `magi.storm`). The source's self-tracked
Magi-mechanic opponent state (`magi.offense.state.*`) is **read live from AK
`affstrack` instead** (the chosen porting strategy — see Tier 1b below).

**No self-registration:** no `tempAlias` / `tempRegexTrigger` /
`registerAnonymousEventHandler` anywhere. The module exposes handler functions;
you wire them to manually-created Mudlet items per `MUDLET_SETUP.md`.

**Dispatch model:** direct dispatch (Tekura-style). An alias sets the mode and
calls `magi.offense.dispatch()`, which bails unless balance **and** equilibrium
are up (`balUp()`/`eqUp()`), so it's safe to re-press / drive from a balance
trigger. `assess <target>` is appended to every attack so AK/Legacy keep HP and
state fresh. (If you prefer the arm + "balance used" JIT timer model used by the
sentinel/blademaster ports, wrap `dispatch()` in that — it's compatible.)

---

## Status — port complete

🟢 Syntax-clean (`luac -p magi.lua` → OK). 0 `ataxia.*` / `tAffs` / `haveAff()`
references in code. The only soft dependency is `ataxiaNDB_getCitizenship`
(guarded — stormhammer "city" mode degrades to "all" without it).

---

## Tier 1a — Target State (AK domain): standard symbols

| Levi symbol | Used for | Legacy/AK equivalent | Status |
| --- | --- | --- | --- |
| `target` (string) | Current target | **same** (global `target`) | ✅ |
| `haveAff("X")` | Boolean aff check | `has("X")` → `affstrack.score[X] >= CONFIG.affThreshold (30)` | ✅ |
| `getAffProbabilityV3("X")` | 0.0-1.0 prob | `prob("X")` → `affstrack.score[X] / 100` | ✅ |
| `tAffs.X` fallback | V1 belt-and-suspenders | **dropped** (no V1 table in AK) | ✅ |
| `haveAff("shield")` | Shield strip gate | `ak.defs.shield` | ✅ |
| `haveAff("rebounding")`/`shield` | Any block (`hasShield`) | `ak.defs.rebounding or ak.defs.shield` | ✅ |
| `targetHealth` / `php` | HP% for kill thresholds | `targetHpPct()` → `ak.currenthealth/maxhealth*100` | ✅ |
| `lb[target].hits[limb]` (0-200) | Broken-limb count (mending affs) | **same**; broken = `>= CONFIG.breakThreshold (100)` | ✅ |

## Tier 1b — Target State (AK domain): Magi-mechanic states ⭐ CONFIRM KEYS

The source **self-tracked** these in `magi.offense.state`, fed by Levi triggers
(`general/025_Burns_Tracking`, `023_Shalestorm`, `026_Calcify`,
`019_Conflagrated`, `501_Scalded`, `pummel-related/002_Hypothermia`). Per the
port decision they are now read **entirely from AK `affstrack`**. Confirm your AK
tracks these keys (override the helper or the `affstrack` key names if not).

| Source `state.X` | This port reads | Helper | Confirm |
| --- | --- | --- | --- |
| `burns` (0-5) | `floor(score.aflame / CONFIG.aflameScale)` | `getBurns()` | ⭐ `aflame` scale: 200==2 burns (set `aflameScale=1` if raw) |
| `conflagrated` | `score.conflagrate >= CONFIG.fullThreshold (100)` | `isConflagrated()` | ⭐ key `conflagrate` |
| `scalded` | `score.scalded >= 100` | `isScalded()` | ⭐ key `scalded` |
| `calcifiedTorso` | `score.calcifiedtorso >= 100` | `isCalcifiedTorso()` | ⭐ key `calcifiedtorso` |
| `calcifiedSkull` | `score.calcifiedhead >= 100` | `isCalcifiedSkull()` | ⭐ key `calcifiedhead` |
| `shalestorm` | `has("shalestorm")` | inline | ⭐ key `shalestorm` |
| `hypothermia` | `prob("hypothermia") >= 0.5` | inline | ⭐ key `hypothermia` |
| `frozen` | `prob("frozen") >= 0.5` | inline | ⭐ key `frozen` |
| `scintillaSpark` | **dropped** (internal cooldown marker, not an aff) | — | minor over-cast of scintilla |
| `firestorm` | **dropped** (referenced removed legacy global) | — | — |

Standard affs also read from `affstrack`: `asthma`, `frostbite`, `shivering`,
`weariness`, `nausea`, `nocaloric` (caloric defence down), `waterbond`,
`blistered`, `paralysis`, `anorexia`, `clumsiness`, `prone`, `entangled`.

## Tier 2 — Self State (Legacy domain)

| Levi symbol | Used for | Legacy/AK equivalent | Status |
| --- | --- | --- | --- |
| `ataxia.afflictions.aeon` | Skip-tick gate | `selfAff("aeon")` (`Legacy.Curing.Affs.aeon`) | ✅ |
| `gmcp.Char.Vitals.bal`/`.eq` | Fire-when-ready gate | `balUp()` / `eqUp()` | ✅ |
| `gmcp.Char.Status.class` | Class guard | unchanged (`CONFIG.classGuard`) | ✅ |
| `ataxia.settings.separator` | Command join | `CONFIG.separator` (`"/"`) | ✅ |
| `partyrelay` (global) | `pt` route callouts | `CONFIG.partyRelay` | ✅ |
| `magi.staff` / `"shield"` | Wield line | `CONFIG.WEAPONS.STAFF` / `.SHIELD` | ✅ |
| `send("queue addclearfull freestand X")` | Attack send | `sendAttack(X)` (SETALIAS ATK / QUEUE ADDCLEARFULL FREESTAND) | ✅ |
| _(none — source never gated on pause)_ | Combat paused | `isPaused()` **added** for port-family parity | ➕ |

## Tier 3 — Stormhammer multi-target (005)

Levi room/enemy/NDB infra is absent in AK, so:

| Levi symbol | Equivalent | Status |
| --- | --- | --- |
| `ataxia.playersHere` | `gmcp.Room.Players` (standard IRE GMCP; "the soul of " stripped) | ✅ |
| `ataxiaTemp.enemies` | `magi.storm.isEnemy(name)` — **override point**. Safe default: current target only + names in `magi.storm.enemies` | ⚠ wire your enemy list |
| `gmcp.Char.Name` | `myName()` (self-exclusion) | ✅ |
| `ataxiaNDB_getCitizenship` | guarded — "city" mode degrades to "all" if absent | ⚠ optional |
| `tprio.list` ("priority" mode) | degrades to "all" (tprio not ported) | ✅ |
| `ataxiaEcho` / `ataxia_boxEcho` | `magi.offense.echo` (cecho) | ✅ |

Default `magi.storm.mode` is `"all"`. With the safe `isEnemy` default and no
`magi.storm.enemies` populated, multi-target collapses to the single primary
target — identical to the source's `else "cast stormhammer at " .. target`
fallback. Populate `magi.storm.enemies` (or override `magi.storm.isEnemy`) to get
real 3-target sweeps.

## Tier 4 — Helper functions (top-of-file, file-local)

`score`, `prob`, `has`, `akDef`, `targetHpPct`, `limbDmg`, `limbBroken`,
`selfAff`, `isPaused`, `balUp`, `eqUp`, `gmcpClass`, `myName`, `sendAttack`,
`roomPlayers`. `get_resonance()` is global (status display + dispatch refresh).

## Tier 5 — Commands (Achaea verbatim, unchanged)

`cast destroy/glaciate/hypothermia/mudslide/magma/freeze/dehydrate/conflagrate/`
`fulminate/bombard/shalestorm/emanation/erode/meteorite at <t> [arg]`,
`staffcast scintilla/horripilation <t>`, `cast stormhammer at <t> [and <t> and <t>]`,
plus the `stand` / `wield <staff> <shield>` / `assess <t>` wrapper and the optional
`arachnideye trample <t>` / `webbomb <t>` artefact prefixes.

---

## Open Decisions

- [x] **Source of truth** — 004 (unified, documented, 5 modes). Mizik not ported.
- [x] **Namespace** — `magi.offense` / `magi.resonance` / `magi.storm` (source).
- [x] **Magi-mechanic state** — all from AK `affstrack` (user choice). See Tier 1b.
- [x] **tprio (006)** — omitted (trust `tar X`, like the other ports).
- [ ] **AK key names / scale** — confirm the ⭐ keys in Tier 1b (esp. `aflameScale`
      and the `calcifiedtorso`/`calcifiedhead` spellings).
- [ ] **`magi.storm.enemies` / `isEnemy`** — wire your framework's enemy list for
      true multi-target; default is single-target-safe.
- [ ] **Staff/shield IDs** — set `magi.offense.CONFIG.WEAPONS`.
