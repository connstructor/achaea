# Conventions (port family)

- One global namespace table per class (`sylvan`, `blademaster`, …), `X = X or {}` reload-safe; same for `X.CONFIG`/`X.state`/data tables.
- Tunables in `X.CONFIG` (UPPERCASE key style varies; sylvan uses UPPER_SNAKE keys).
- Helpers are file-local `local function`s; only the public API (dispatch/arm/reset/on_* callbacks/debug_snapshot) lives on the namespace.
- **No self-registration**: modules never call `tempAlias`/`tempRegexTrigger`/`registerAnonymousEventHandler`. User wires manually-created Mudlet aliases/triggers to the exposed functions per `MUDLET_SETUP.md`.
- Attack delivery: server-side queue — `send("SETALIAS <NAME> cmd1/cmd2")` then `send("QUEUE ADDCLEARFULL FREE <NAME>")` (sylvan uses queue `FREE`, alias `SYLATK`; blademaster uses `FREESTAND`/`ATK`).
- JIT dispatch model: alias calls `X.arm()` (fires immediately if bal+eq up), a balance/eq-used trigger calls `X.on_recover(interval)` which sets a `tempTimer(interval - latency)`; on expiry, if still armed, dispatch with current state, one shot per arm. The only timers are on-demand tempTimers stored in `state` (`fire_timer`, latches).
- Self-clearing latches: boolean in `state` + tempTimer that clears it (e.g. sylvan `commit_latch`).
- Aff checks: `affstrack.score[aff] >= threshold` (0-100 confidence scale; threshold 30 across modules, sylvan included).
- Limb names: `lb[target].hits` keys are spaced ("left leg"); AK parry globals are no-space ("leftleg") — normalize when comparing.
- Game commands kept verbatim Achaea syntax, UPPERCASE in sylvan.
- Comments: sparse, only non-obvious WHY; spec/design notes sometimes live as comment blocks at file bottom.
