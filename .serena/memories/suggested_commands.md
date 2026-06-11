# Suggested Commands

- Syntax check a module: `luac -p <file>.lua` (used as the done-gate in prior ports). If `luac` is absent on this Windows box, `lua -e "assert(loadfile('<file>.lua'))"` works if a Lua interpreter is installed — verify availability before relying on it.
- Git: standard; submodule init for legacy source: `git submodule update --init LEVI-Achaea`.
- PowerShell 7 quirks: use `Get-Content`/`Select-String` equivalents are handled by agent tooling; no make/test runner exists.
