## 0.1.1

- Fix `pbpaste | symbolize` crash: the bare-stdin path hit
  `bool is not a subtype of String?` because top-level `--version` is a
  flag while decode's `--version <ver>` is an option sharing the name.

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
- `symbolize decode --json` — machine-readable report with structured
  `DecodedFrame`s (name, uri, line, column) per decoding.
- `symbolize decode --source` — appends ±2 lines of source under decoded
  frames when the `file://` path exists locally.
- `symbolize decode --remote` + `symbolize fetch` — pull symbols for a
  trace's `build_id` from a shared remote store; `archive`/`watch` write
  `index.json` so any `symbols/` dir is publishable over HTTP.
- `symbolize watch` — auto-archives `build/symbols` whenever it changes.
- `symbolize upload` — pushes an archived version to Crashlytics
  (`firebase` CLI) or Sentry (`sentry-cli`, incl. `dart-symbol-map`).
- `.pdb` input produces a clear CodeView-format error.
- `symbolize archive` — stash `--split-debug-info` output into
  `symbols/<version>/` with a manifest (build ids, git SHA).
- `symbolize list` — show archived versions and their files.
- Library API: `symbolize()`, `symbolizeAll()`, `SymbolArchive`,
  `SymbolsFile`, `ObfuscationMap`, `selectSymbols`, `TraceInfo`,
  `splitTraces`, `detectTrace`, `scanForSymbols`,
  `SymbolArchive.buildIdIndex`/`findByBuildId`, `findProjectRoot`,
  `pubspecVersion`.
- Pure Dart decode via `package:native_stack_traces` — no Flutter SDK needed
  at decode time.
