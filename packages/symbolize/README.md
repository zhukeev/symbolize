# symbolize

Deobfuscate Dart and Flutter release stack traces — CLI and library.

Release builds made with `--obfuscate --dwarf-stack-traces` produce crash
traces full of hex program counters instead of function names. `flutter
symbolize` can decode them, but only if you can find the matching
`--split-debug-info` symbols file for that exact build — and `build/symbols/`
is overwritten every build.

`symbolize` fixes both halves of that:

1. **Archive** — stashes split-debug-info output under `symbols/<version>/`
   after every release build, with a manifest (build ids, git SHA, date).
2. **Decode** — picks the right symbols file automatically. When the trace
   header's `build_id` matches a file's DWARF build id the choice is exact;
   otherwise `os:`/`arch:` narrows by filename. Ambiguous pools decode every
   candidate so you can compare.

Decoding runs in-process via
[`native_stack_traces`](https://pub.dev/packages/native_stack_traces) — the
same DWARF engine `flutter symbolize` uses. No Flutter SDK required at
decode time.

## Install

```sh
dart pub global activate symbolize
```

## CLI

```sh
# One-time setup, after every release build (same dir as pubspec.yaml):
flutter build apk --release --obfuscate --split-debug-info=build/symbols
symbolize archive                     # build/symbols -> symbols/<pubspec version>/

# Decode a crash (version read from pubspec.yaml; or --version x.y.z+n):
symbolize decode -i crash.txt
pbpaste | symbolize decode            # paste from clipboard
symbolize decode -i crash.txt -d path/to/app.ios.symbols   # explicit file
symbolize decode -i crash.txt -o decoded.txt
symbolize decode -i crash.txt --arch arm64 --os android    # override header

symbolize list                        # show archived versions + build ids
```

Symbols are resolved in order: `--symbols` file → `symbols/<version>/` →
`build/symbols/` (with a warning, since it may be a different build).

A symbols file that doesn't match the build leaves the trace unchanged —
the CLI warns `no frames resolved` in that case instead of printing garbage.

### Wire archiving into a Makefile

```make
release: ## obfuscated release build + archived symbols
	flutter build appbundle --release --obfuscate --split-debug-info=build/symbols
	symbolize archive
```

## Library

```dart
import 'package:symbolize/symbolize.dart';

final result = await symbolize(
  traceText,
  symbols: SymbolsFile('app.android-arm64.symbols'),
);
print(result.decodings.single.output);

// Or resolve from an archive:
final result2 = await symbolize(
  traceText,
  symbolsDir: Directory('symbols'),
  version: '1.4.0+21',
);
for (final d in result2.decodings) {
  print('${d.symbols.name}: resolved=${d.resolved}');
}
```

`SymbolArchive` handles storing/listing versions; `selectSymbols` exposes
the buildId → os/arch narrowing; `TraceInfo.parse` reads the crash header.

## The desktop app

A small Flutter desktop UI lives in
[`packages/symbolize_app`](https://github.com/zhukeev/symbolize/tree/main/packages/symbolize_app)
— paste a trace, pick a version, decode.

## How symbols files work

`--split-debug-info=<dir>` writes `app.<platform>.symbols` —
`app.android-arm.symbols`, `app.android-arm64.symbols`,
`app.android-x64.symbols`, `app.ios.symbols`, `app.macos.symbols`. Each is an
ELF container of DWARF data including the snapshot `build_id` printed in the
crash header, which is what makes exact matching possible.

## License

MIT — see [LICENSE](LICENSE).
