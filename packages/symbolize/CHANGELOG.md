## 0.1.0

- Initial release.
- `symbolize decode` — symbolize obfuscated AOT stack traces from a file or
  stdin; picks the symbols file by DWARF `build_id`, falling back to
  `os:`/`arch:` filename matching.
- Multi-trace input — `*** ***`-separated dumps (Crashlytics exports,
  logcat) decode per trace, each against its own build.
- `.map.json` support — restores obfuscated identifiers in name-level
  traces (`#0 YE (uN:10)`) via the archived obfuscation map; sibling
  discovery next to the `.symbols` file or `-m/--map`.
- Build-id safety — warns when a symbols file's DWARF build id contradicts
  the trace's `build_id` instead of emitting plausible garbage.
- `symbolize archive` — stash `--split-debug-info` output into
  `symbols/<version>/` with a manifest (build ids, git SHA).
- `symbolize list` — show archived versions and their files.
- Library API: `symbolize()`, `symbolizeAll()`, `SymbolArchive`,
  `SymbolsFile`, `ObfuscationMap`, `selectSymbols`, `TraceInfo`,
  `splitTraces`, `findProjectRoot`, `pubspecVersion`.
- Pure Dart decode via `package:native_stack_traces` — no Flutter SDK needed
  at decode time.
