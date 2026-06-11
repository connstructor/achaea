# Task Completion

When a coding task on a module is done:
1. Syntax check: `luac -p <module>.lua` (or `lua -e "assert(loadfile(...))"`). No linter/formatter/test suite configured.
2. Verify zero leftover legacy refs in ported code (`ataxia`, `ataxiaTemp`, `tAffs`, `haveAff(`, `combatQueue(`) — grep the module.
3. Keep `DEPENDENCIES.md` / `MUDLET_SETUP.md` of the touched module in sync if public API, aliases, or triggers changed.
4. Do not commit unless asked.
