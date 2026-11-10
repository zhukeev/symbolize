# symbolize

Deobfuscate Dart and Flutter release stack traces.

Obfuscated release builds (`--obfuscate --dwarf-stack-traces`) crash with
hex program counters instead of function names. Decoding needs the matching
`--split-debug-info` symbols file for that exact build — but
`build/symbols/` is gitignored and overwritten every build.

`symbolize` fixes both halves:

- **`symbolize archive`** stashes split-debug-info output under
  `symbols/<version>/` with a manifest (DWARF build ids, git SHA, date).
- **`symbolize decode`** picks the right file automatically — exact match on
  the trace header's `build_id`, else `os:`/`arch:` filename narrowing.

Decoding runs in-process via
[`native_stack_traces`](https://pub.dev/packages/native_stack_traces) — the
same DWARF engine `flutter symbolize` uses. No Flutter SDK needed at decode
time.

## Repository layout

| Path | What |
| --- | --- |
| [`packages/symbolize`](packages/symbolize) | The library + CLI, published on pub.dev |
| [`packages/symbolize_app`](packages/symbolize_app) | Flutter desktop app (macOS) |

## Quick start

```sh
dart pub global activate symbolize

# After each release build:
flutter build apk --release --obfuscate --split-debug-info=build/symbols
symbolize archive

# Decode a crash:
symbolize decode -i crash.txt
pbpaste | symbolize decode
```

See [packages/symbolize/README.md](packages/symbolize/README.md) for the full
CLI and library reference.

## Desktop app

```sh
cd packages/symbolize_app
flutter run -d macos
```

Paste a trace, pick an archived version (or a `.symbols` file), decode.
<!-- TODO: screenshot -->

## Development

```sh
cd packages/symbolize && dart pub get && dart test
cd packages/symbolize_app && flutter pub get && flutter test
```

## License

MIT — see [LICENSE](LICENSE).
