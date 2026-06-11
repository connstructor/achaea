# AGENTS.md

## Cursor Cloud specific instructions

This repo is a collection of **Lua 5.1** combat-scripting modules for the Achaea MUD,
intended to be loaded into a **Mudlet** client. There is no build system, package
manager, server, or GUI app in this repo — the modules assume host globals provided at
runtime by Mudlet + the Legacy/AK frameworks (`send`, `tempTimer`, `target`, `ak.*`,
`affstrack`, `lb`, `gmcp`, etc.), so they are never "run" standalone outside Mudlet.

What you *can* run here (all from the repo root unless noted):

- **Lint / syntax check** (the project's done-gate): `luac -p <file>.lua`. Check every
  module at once with `find . -name '*.lua' -not -path './.git/*' -exec luac -p {} \;`
  (silent = pass). `luac` ships with `lua5.1`.
- **Tests**: three self-contained smoke harnesses stub the host globals and assert the
  commands each module emits. They are the closest thing to running the product:
  - `lua sys/sylvan/sylvan_test.lua` — run from the repo root (uses `dofile("sys/sylvan/sylvan.lua")`).
  - `lua sentinel_test.lua` — run from inside `ports/legacy_ak/sentinel/` (uses `dofile("Sentinel.lua")`).
  - `lua psion_test.lua` — run from inside `ports/legacy_ak/psion/` (uses `dofile("Psion.lua")`).

  Gotcha: the sentinel/psion harnesses `dofile()` their module by **bare filename**, so
  they only work when the current directory is the module's own folder. Exit code is
  non-zero on any failed assertion.

- **Lua version**: target is Lua 5.1 (Mudlet's embedded interpreter). The modules are
  5.1-style and also load under newer Lua, but prefer `lua5.1`/`luac5.1` for fidelity.

- The `LEVI-Achaea/` git submodule holds legacy reference source only; it is **not**
  required to lint or test, and is usually left uninitialized.

- Per-module `DEPENDENCIES.md` / `MUDLET_SETUP.md` document the manual Mudlet wiring
  (aliases/triggers) a human would set up; nothing needs to be wired for lint/tests.
