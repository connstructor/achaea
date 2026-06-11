# Sylvan Module — Session Handoff (2026-06-10)

Audience: Claude (or any agent) continuing work on `ports/legacy_ak/sylvan/sylvan.lua`.
This file is self-contained — assume no Serena memories or conversation history exist.

## Repo context

- Achaea (IRE MUD) combat scripting for Mudlet. Repo = ports of legacy "Levi" combat
  systems to the **Legacy** (self-curing) + **AK** (enemy aff/limb tracker) environment.
- One module per class under `ports/legacy_ak/<class>/`. Sylvan authors: Tannivh (code),
  Kiryn (combat logic). The user relays Kiryn's specs; treat them as authoritative.
- `LEVI-Achaea/` submodule (original legacy source) is **uninitialized** — the original
  sylvan source is unavailable. Spec authority = the comment blocks at the bottom of
  `sylvan.lua`, plus this file.
- Repo state at handoff: branch `main`; `ports/legacy_ak/sylvan/` and `.serena/` are
  untracked; nothing committed this session (user hasn't asked).
- Useful sibling references: `tekura/tekura.lua` (parry + threshold patterns),
  `sentinel/sentinel_test.lua` (test-harness precedent), `locks/DEPENDENCIES.md`
  (affstrack score conventions).

## Runtime environment (globals provided by Mudlet + AK + Legacy, NOT in repo)

| Global | Meaning |
|---|---|
| `target` | current target name (string) |
| `ak.ae` | target's AP resource (may be string — always `tonumber`) |
| `ak.currenthealth` | target HP, absolute (string-ish; nil-guard) |
| `ak.disturbed` | weather disturbance active (bool) |
| `ak.feedback` | feedback state; module compares `~= target` (semantics unverified, see open items) |
| `ak.defs.shield` | target shield up |
| `affstrack.score[aff]` | 0–100 confidence, 100 = fresh apply; module threshold = 30 |
| `lb[target].hits[limb]` | limb damage %, **spaced** keys ("left leg") |
| `targetparry` | parried limb; spaced or unspaced depending on AK version — compare space-blind |
| `gmcp.Char.Vitals.bal/eq` | "1" when balance/eq up |
| Mudlet API | `send`, `tempTimer`, `killTimer`, `remainingTime`, `getNetworkLatency`, `echo` |

## Module conventions

- Pure logic file. **No self-registration** (no tempAlias/tempTrigger/event handlers);
  user wires Mudlet aliases/triggers manually to the public API.
- Public API: `sylvan.dispatch(mode)`, `sylvan.arm(mode)`, `sylvan.on_recover(interval)`,
  `sylvan.reset()`, `sylvan.debug_snapshot()`. Everything else is file-local.
- JIT dispatch: alias → `arm()` (fires immediately if bal+eq up); balance/eq-used trigger →
  `on_recover(interval)` → tempTimer(interval − latency) → one dispatch per arm. The timer
  keeps the LONGEST pending wait (bal and eq recover independently).
- Delivery: `send("SETALIAS SYLATK c1/c2")` then `send("QUEUE ADDCLEARFULL FREE SYLATK")`.
- Modes: ONELEG, ONELEGHEAD, TWOLEG, TWOLEGHEAD (`CONFIG.PREP_ORDER`). Validated +
  uppercased by `set_mode`.
- Thornrend grammar: `THORNREND <target> <venom> [limb] [plant]`, emitted as clean
  space-separated tokens; the venom slot is never left empty (herb → focus → CURARE
  floor) or the server would misparse limb/plant as the venom.

## ONELEG / ONELEGHEAD state machine (Kiryn, authoritative)

Each step: start condition → action; completion = next step's start.

1. Initial → prep left leg. Hindering/herb affs on BOTH slots; propagation prioritized,
   venom non-duplicate after. Done: leg prepped (dmg + 22 >= 100).
2. (ONELEGHEAD) → prep head, same selection. Done: leg + head prepped.
3. Prepped → `CAST DISTURB` (own balance). Done: `ak.disturbed`.
4. Prepped + disturbed → build AP via `SYNCHRONISE <s1> <s2> <target>`; prefix with
   `CAST FEEDBACK AT <target>` while feedback isn't on target. Spell prio =
   `CONFIG.WW_PRIO` (paralysis, clumsiness, healthleech, dizziness, epilepsy,
   sensitivity). Done: ae >= 40.
5. ae >= 40 → `THORNREND <t> <venom> left leg LOBELIA` + `SWEEP QUARTERSTAFF <t>` same
   balance (break + prone). Venom prio = herb selector. Sets 6s commit latch. Breaks are
   double-gated: ae >= gate AND limb prepped (a restored 0% leg can never hijack).
6. Latch + ae >= 40 → `OVERCHARGE STATIC CYCLONE` (exactly; expected to grant
   focusextend). Once per commit cycle (`state.oc_fired`).
7. Overcharges spent → `THORNREND <t> SLIKE head VALERIAN` in ANY mode (ONELEG never
   prepped the head; the strike delivers without breaking). Repeats until both seal affs
   (anorexia, slickness) delivered (>= threshold 30).
8. Seal delivered + ae < 28 → if impatience < 100: `SYNCHRONISE CYCLONE HAILSTONE <t>`
   (both impatience routes in one cast); else `SYNCHRONISE STATIC <next hinder> <t>`.
   Builds AP back while driving the lock.
9. ae >= 28 → confirm lock set (`CONFIG.LOCK_AFFS` = asthma, slickness, anorexia,
   impatience) to score 100: impatience/asthma gaps → `OVERCHARGE CYCLONE HAILSTONE`
   (grants impatience, asthma, weariness); seal delivered-but-<100 →
   `THORNREND <t> SLIKE torso VALERIAN`.
10. Lock holds → keep paralysis at 100 (`THORNREND <t> CURARE torso <plant>`), then stack
    class-block affs (generic torso thornrend).

Interrupts at any point (dispatch order): shield → `CAST SHEAR AT <t>`; then ae >= 40 +
>= 3 shockwave affs (dizziness/epilepsy/healthleech/impatience) + hp <= 5000 →
`CAST SHOCKWAVE AT <t>`; then committed() → execute, else prep/build.

`committed()` = 6s latch OR any mode limb broken OR (all prepped AND ae >= gate) OR
seal_present (any seal aff >= threshold — keeps the lock alive in ALL modes until the
seal cures, then falls back to prep).

## TWOLEG / TWOLEGHEAD (stepwise re-spec PENDING from user)

Current behavior: gate 56; break 1 = kelp-cured venom (`CONFIG.KELP_PRIO`) + any herb
prop; break 2 = focus venom (`CONFIG.FOCUS_PRIO`) + LOBELIA-first focus prop; overcharge
sequence `WATERSPOUT HAILSTONE` then `STATIC CYCLONE`; then the shared seal/lock pipeline
(steps 7–10 above). Expect the user to deliver a stepwise spec like the ONELEG one.

## Key code map (sylvan.lua)

- Selectors: `get_next_propagation_plant_for_herb_aff(exclude)`,
  `get_next_venom_for_herb_aff(exclude)`, `get_next_kelp_venom`, `get_next_focus_venom`,
  `get_next_focus_plant` (LOBELIA/vertigo first), `get_next_ww_spell(exclude_aff)`
  (honors needs/avoids in `DATA.AFFS.WEATHERWEAVING`).
- `break_recipe()` — per-mode break venom/prop pairing. `thornrend(cmds, limb, breaking)`
  — head+breaking = seal (SLIKE/VALERIAN); emits SWEEP for leg breaks.
- `ensure_weather(cmds)` — DISTURB takes its own balance (returns true = sent); FEEDBACK
  stacks. Used by build, overcharges, lock synchs.
- `do_execute(cmds)` — the step 5–10 pipeline, commented per step.
- `get_next_overcharge()` — `DATA.OVERCHARGE[mode]` sequence via `state.oc_fired`
  counter, AP-gated by `COMBO_COST` (28); counter resets when commitment drops
  (dispatch non-committed branch) and in `reset()`.
- Score helpers: `aff_score`, `has_aff` (>= 30), `seal_present` (any), `seal_delivered`
  (both >= 30), `seal_confirmed` (both >= 100).
- Parry: `is_parried(limb)` space-blind vs `targetparry`; prep and break prefer
  unparried limbs, fall back to the parried one if it's the only candidate.

## Open items (ask the user / verify in game)

1. **TWOLEG stepwise re-spec** — pending from user (see above).
2. **Step 8 "class hinder"** — second synch spell when impatience is confirmed currently
   defaults to next missing `WW_PRIO` spell (fallback CYCLONE). User to define.
3. **focusextend** — expected from the banked overcharge per spec, but nothing routes on
   it (its only source is already spent when it could be checked). Verify the affstrack
   key name if the user wants it used.
4. **Step 9 interpretation** — raw spec said "any of asthma/slickness/anorexia/impatience
   < 100 → overcharge", which would shadow the torso branch; implemented as overcharge
   only for impatience/asthma gaps, torso only for seal gaps. Confirm.
5. **`KELP_PRIO` = asthma, clumsiness, weariness** — verify this kelp-cure list.
6. **Thornrend token parsing** — emission assumes the server identifies venom/limb/plant
   by token, not position (e.g. `THORNREND victim SLIKE torso VALERIAN`). Confirm in game.
7. **`scytherus = "SCYTHERUS"`** venom added to `DATA.AFFS.VENOM` (was a dead `HERB_PRIO`
   entry); `lethargy` is still dead (no venom/plant source). Confirm names.
8. **`ak.feedback` semantics** — module compares `~= target` (name-shaped); user once
   wrote "if not ak.feedback" (boolean-shaped). Verify which AK provides.
9. **Absolute shockwave HP gate** (`SHOCKWAVE_MAX_HEALTH = 5000`) — siblings use percent
   (`currenthealth/maxhealth`); kept absolute per original logic.
10. No `DEPENDENCIES.md` / `MUDLET_SETUP.md` for sylvan yet (siblings have them) — the
    user must wire aliases (arm/dispatch), a bal/eq-used trigger → `on_recover`, and a
    prompt/defense trigger discipline per the JIT model above.

## Verification workflow

1. Syntax: `luac -p ports/legacy_ak/sylvan/sylvan.lua`.
2. Behavior: `lua ports/legacy_ak/sylvan/sylvan_test.lua` — 25-scenario smoke harness
   with a stubbed Mudlet/AK environment, including regression tests for: restored-leg
   lock-first, carried-AP overcharge double-fire, ONELEG unprepped-head seal, parry
   skip, nil-health shockwave crash.
3. Repo hygiene: no legacy refs (`ataxia`, `tAffs`, `haveAff(`, `combatQueue(`);
   do not commit unless the user asks.

## Session history (why things are the way they are)

- Fixed: AFF_THRESHOLD 0.5 → 30 (wrong scale); prep venom/prop duplication; lock-phase
  plant ignoring lock affs; overcharge double-fire on carried AP; nil-health crash in
  the shockwave gate; `SWING` → `SWEEP <weapon> <target>`; gate 28 → 40 (ONELEG*).
- Removed: `seal_rides` on the ONELEG leg (the seal ONLY rides head/torso thornrends now).
- The user's live in-game problem was the restored-leg hijack: execute kept whaling on a
  restored 0% leg with break-style strikes while the seal cured. Solved by double-gating
  breaks (ae >= gate AND prepped) — execute now continues the lock instead.
