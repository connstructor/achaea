# Core

Achaea (IRE MUD) combat scripting for Mudlet. Repo = ports of legacy "Levi" combat systems to the **Legacy** (self-curing framework) + **AK** (enemy aff/limb tracker) environment.

- `ports/legacy_ak/<class>/` — one module per Achaea class (blademaster, mage/magi, sylvan, tekura, shikudo, sentinel, snb_runie, dwc_runie, locks). Each: `<class>.lua` (pure logic), usually `DEPENDENCIES.md` (port mapping doc), `MUDLET_SETUP.md` (manual aliases/triggers), sometimes `calibrate.lua`.
- `LEVI-Achaea/` — git submodule (often uninitialized) holding the original legacy source.
- Port conventions and shared environment: `mem:conventions`.
- Sylvan: spec/state machine + decisions in comments at bottom of `ports/legacy_ak/sylvan/sylvan.lua`; full session handoff incl. open items in `ports/legacy_ak/sylvan/HANDOFF.md`; smoke harness `sylvan_test.lua` (run with plain `lua`, stubbed env). No DEPENDENCIES.md/MUDLET_SETUP.md yet.

Global environment the modules assume (provided by Mudlet + AK + Legacy, NOT in repo):
- `target` (string), `ak.*` (target state: `ae` AP, `currenthealth`, `disturbed`, `feedback`, `defs.shield`), `affstrack.score[aff]` (target affs), `lb[target].hits[limb]` (limb dmg %, spaced limb names like "left leg"), `gmcp.Char.Vitals` (`bal`/`eq` as string "1"), Mudlet API (`send`, `tempTimer`, `killTimer`, `remainingTime`, `getNetworkLatency`).
