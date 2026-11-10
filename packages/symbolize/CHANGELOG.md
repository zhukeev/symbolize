## 0.1.0

- Initial release.
- `symbolize decode` — symbolize obfuscated AOT stack traces from a file or
  stdin; picks the symbols file by DWARF `build_id`, falling back to
  `os:`/`arch:` filename matching.
- `symbolize archive` — stash `--split-debug-info` output into
  `symbols/<version>/` with a manifest (build ids, git SHA).
- `symbolize list` — show archived versions and their files.
- Library API: `symbolize()`, `SymbolArchive`, `SymbolsFile`,
  `selectSymbols`, `TraceInfo`, `findProjectRoot`, `pubspecVersion`.
- Pure Dart decode via `package:native_stack_traces` — no Flutter SDK needed
  at decode time.
