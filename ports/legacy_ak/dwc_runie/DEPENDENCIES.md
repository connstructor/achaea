# DWC Runewarden — Legacy / AK Port

Port of the Levi/Ataxia **Dual-Cutting (DWC) Runewarden** offense to **Legacy**
(self-curing framework) + **AK** (enemy aff/limb tracker), in the sibling-port
house style (`2h_runie`, `snb_runie`, `blademaster`).

**Source of truth (combat logic):** the Levi ataxia DWC scripts —
- `dwc_runie/003_Disembowel_Prep.lua` — `dwcprioslimb` → plan **`disembowel`** (default)
- `dwc_runie/004_Head_Prep.lua` — `dwcpriosheadprep` → plan **`head`**
- `dwc_runie/002_BASIC_2.lua` — `dwcpriosbasic` → plan **`basic`**
- `dwc_runie/001_RIFT.lua` — `runie_riftlock` → plan **`rift`**

The decision ladders (branch order, attack commands, venom selection) are
reproduced **verbatim**; only the *state model* and *firing spine* were
re-pointed at the AK/Legacy host APIs and the sibling-port arm/JIT/dispatch.
Game-command letter-case was normalised to UPPERCASE to match the sibling ports
(Achaea is case-insensitive; semantics are unchanged).

---

## Architecture

- **No self-registration.** The module defines functions only; wire the
  hand-made Mudlet aliases/triggers to them per `MUDLET_SETUP.md`. No
  `tempAlias` / `tempRegexTrigger` / `registerAnonymousEventHandler`.
- **JIT dispatch.** An alias **arms** (`M.arm()`, fires immediately if balance+eq
  are up via `gmcp.Char.Vitals.bal/.eq == "1"`). A balance-**used** trigger calls
  `M.on_balance_used(interval)`, which schedules a `tempTimer` for
  `interval - getNetworkLatency()`; on expiry, if still armed, it dispatches with
  **current** state and disarms (one shot per arm).
- **User-selected plan.** Unlike `2h_runie` (auto weapon/phase cascade), the DWC
  routines are four **mutually-exclusive** offense plans the user picks with
  `M.set_plan("disembowel"|"head"|"basic"|"rift")`. Each is its own Levi function.
- **Attack delivery:** `send("SETALIAS DWCATK <cmd1/cmd2/…>")` then
  `send("QUEUE ADDCLEARFULL FREE DWCATK")` — the sibling-port queue convention
  (`/`-separated sub-commands; Levi's `;`-joined string maps 1:1).

---

## Symbol mapping (the anti-"dead global" contract)

Every state READ maps to a **proven** AK/Legacy source. The first DWC/Magi ports
were scrapped because ported logic read invented globals nothing populated — do
not reintroduce `tAffs.bleed`, `tAffs.damaged*`, `envenom*`, etc.

### Target state
| Levi symbol | Used for | AK / Legacy equivalent |
| --- | --- | --- |
| `tAffs.<aff>` | venom ladders, branch gates | `aff_present(s,"<aff>")` = `affstrack.score[aff] >= config.aff_threshold` |
| `tAffs.rebounding` / `.shield` | raze / bisect gates | `ak.defs.rebounding` / `ak.defs.shield` (and `not ignoreShield`) — **not** affstrack |
| `tAffs.impaled` / `timpale` | disembowel gate | `affstrack.impale == "Me"` (`s.impaled`); Levi's `or timpale` fallback dropped (no AK source) |
| `tAffs.damaged<limb>` / `broken<arm>` | "limb already broken" gates | `is_limb_broken(limb)` = `lb[target].hits[limb] >= 100` (lb-derived; the safe mapping) |
| `tAffs.mildtrauma` | torso-broken (plan rift/007) | `is_limb_broken("torso")` |
| `lb[target].hits[limb]` | limb damage %, prep math | **same** (spaced keys: `"left leg"`; raw `target` key) |
| `scimdamage = ataxiaTables.limbData.dwcSlash * 2` | one-DSL break prediction | `config.dwc_slash_damage * 2` (a DSL lands two slashes) |
| `axedamage = scimdamage - 3` | raze margin checks | same formula |
| `php` / `ataxiaTemp.lastAssess` | BISECT gate (≤ 35%) | `hp_pct(s)` from `ak.currenthealth` (fallback `ak.health`) / `ak.maxhealth` |
| `engaged` | ENGAGE suffix | `ak.engaged` |
| `tAffs.bleed` | **display only** | `ak.bleeding` (`s.bleed`) — see note below |
| `ataxia.getWeapon("weaponN")` | wield | `config.weaponN` |

### Bleed — the central DWC mechanic, sourced correctly
The DWC decision tree **never branches on bleeding** — it kills via
limb-prep → IMPALE → DISEMBOWEL (and a low-HP BISECT). So `tAffs.bleed` is read
into `s.bleed` from **`ak.bleeding`** (the same accessor the working Blademaster
port uses) purely for awareness/GUI, and is kept fresh by the optional
`DISCERN <target>` ridealong appended to each batch. The Levi DISCERN ladder
(`discern_levels/001–011`) and haemophilia clamps are **not** ported — they
duplicate what `ak.bleeding` already provides. Set `config.discern_ridealong =
false` for a 1:1 match with the (non-discerning) Levi source.

---

## Deliberate deviations from the literal Levi source

These are **intentional** — porting the bugs faithfully would break the port:

1. **`002` `prepped_torso` is computed locally.** Levi's `dwcpriosbasic` reads a
   `prepped_torso` global it never assigns (stale cross-routine state). We
   recompute it each tick in `derive()`.
2. **`002` nausea hand-off returns the disembowel plan directly.** Levi calls
   `dwcprioslimb()` (which *sends*) and then falls through and *sends again* — a
   double-send. We return the disembowel plan's batch instead.
3. **`001` `targetlimb` is assigned.** Levi's `runie_riftlock` uses `targetlimb`
   without ever setting it (stale global → nil concat). We use the disembowel
   limb pick (torso → right leg → left leg).
4. **Falcon is a `need_falcon` gate, not re-emitted spam.** `FALCON SLAY` is
   emitted per the source's gating (basic: always; disembowel/head: when
   `not engaged and need_falcon`; rift: never). It self-limits because the batch
   appends `ENGAGE` and the next tick reads `ak.engaged`.
5. **`tBals.salve` (untracked).** AK exposes no salve-balance flag. The rift
   plan's riftlock branch (`dsl … EPTETH EPTETH`) and the salve-gated venom adds
   read `M.state.salve_down` (default `false`) — a manual flag the user can set
   (`dwcsalve on`). Faithful default: branch off.
6. **`inc_imp` (untracked).** The head plan's incoming-impatience venom adds are
   gated `false` (Levi self-tracks this via a trigger; no AK source).
7. **Dead code dropped:** `add_dedication` (Levi's `(x ~= 'Apostate' or x) ~=
   'Priest'` is a no-op bug), `impale_blackout`, `partyrelay`, `softlock`/
   `treelock` locals, and the dead atk-string BISECT branches (overridden by the
   dispatch-level BISECT in disembowel/head).
8. **BISECT ignores shield (disembowel/head).** The live Levi dispatch fires
   BISECT on `use_bisect` alone (`003:333`, `004:363`); the `and not shield` you
   see on the *atk-string* bisect branch is dead code. So a shielded low-HP target
   still bisects (BISECT bypasses defenses, per the SnB port).
9. **`002` `need_raze2`/`need_raze3` collapsed into `need_raze`.** In `dwcpriosbasic`
   those two branches emit an *untargeted* `razeslash <target> venoms[1]` (identical
   to `need_raze`) and are gated on `targetlimb == "right leg"`/etc. — but `002`
   never assigns `targetlimb` (stale global), so they are unreachable via defined
   state. The port keeps only `need_raze`. (In disembowel/head/rift, which *do*
   assign `targetlimb`, all three raze branches are reproduced — they emit a
   *targeted* razeslash there.)

---

## Host-global contract

Reads: `gmcp.Char.Vitals.bal/.eq` (strings `"1"`/`"0"`), `target`,
`ak.currenthealth`/`ak.health`/`ak.maxhealth`, `ak.defs.rebounding`/`.shield`,
`ak.engaged`, `ak.bleeding`, `affstrack.score[<aff>]` (0–100), `affstrack.impale`
(`"Me"`), `lb[target].hits[<spaced limb>]` (0–200+), `ignoreShield`.

Writes (host fns): `send`, `tempTimer`, `getNetworkLatency`, `boxEcho.send`,
`echo`, `os.time`.

---

## Public API

| Symbol | Called from |
| --- | --- |
| `M.arm()` | the arming alias (e.g. `zz`) — normal entry point |
| `M.on_balance_used(interval)` | the REQUIRED "Balance used: Ns." trigger |
| `M.set_plan(name)` | `dwcplan <disembowel\|head\|basic\|rift>` |
| `M.toggle_falcon()` | `dwcfalcon` — flip `need_falcon` |
| `M.set_salve_down(bool)` | `dwcsalve on\|off` — rift riftlock gate |
| `M.reset()` | `dwcreset` — FURY OFF + disarm |
| `M.on_gmcp_char_vitals(e)` | optional vitals handler (no-op; parity stub) |
| `M.config` / `M.state` | tunables / runtime state |

---

## Config to fill in before use

- `config.weapon1` / `config.weapon2` — your two cutting weapon **item ids**
  (placeholders: `"scimitar"`).
- `config.bisect_weapon` — swap-in execute weapon for the disembowel/head BISECT
  (`wield <this>;grip`; placeholder `"bastard"`).
- `config.basic_bisect_weapon` — the basic/rift SnB bisect weapon
  (`wield shield <this>`; placeholder `"longsword"`).
- `config.empower_runes` — head-prep `EMPOWER PRIORITY SET` (default
  `"KENA MANNAZ SLEIZAK"`).
- `config.dwc_slash_damage` — per-slash limb damage (default `6.6`; `scimdamage`
  is `2×`). Tune to your actual DSL break math.
- `config.aff_threshold` — affstrack "present" cutoff (default `50`).

---

## Open decisions / verify live

- **`ak.bleeding`** must be populated by your AK build for the bleed display
  (Blademaster relies on it). The kill route does **not** need it.
- **`affstrack.score` for rune-applied affs** (nausea/paralysis/anorexia/
  slickness/asthma/impatience/addiction/etc.): the venom ladders and the
  nausea-gated branches trust affstrack to see normal combat landings, exactly as
  `snb_runie`/`2h_runie` do. Verify these keys populate on your build — this is
  the one residual visibility bet.
- **`damaged<limb>` mapping.** Derived from `is_limb_broken` (`lb >= 100`). If
  your AK build exposes distinct `affstrack.score.damaged<limb>` keys you trust,
  swap the `is_limb_broken` calls in `derive()` for `aff_present`.
- **HP field.** `hp_pct` reads `ak.currenthealth` then falls back to `ak.health`
  (snb's field) — works on either build.

---

## Testing

`dwc_runie_test.lua` (run `lua dwc_runie_test.lua` from this directory) stubs the
host globals, drives all four plans through `M.arm()`/`compute_and_fire()`, and
asserts the emitted `DWCATK` batch (wield/wipe, DSL venom order, BISECT forms,
IMPALE/DISEMBOWEL gating, head-crack, EMPOWER/CONTEMPLATE, falcon gating, the
nausea→disembowel delegation, the rift riftlock, and the SETALIAS+QUEUE pair).
Exit code is non-zero on any failed assertion. Re-run after any logic change.
