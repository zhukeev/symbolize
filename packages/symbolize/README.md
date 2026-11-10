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
symbolize decode -i crash.txt -s        # inline source lines under frames
symbolize decode -i crash.txt --json    # machine-readable report

symbolize list                        # show archived versions + build ids

# Hands-free archiving — archives build/symbols whenever it changes:
symbolize watch

# Push an archived version to your crash provider:
symbolize upload --provider crashlytics           # needs firebase CLI
symbolize upload --provider sentry                # needs sentry-cli
```

Symbols are resolved in order: `--symbols` file → `symbols/<version>/` →
`build/symbols/` (with a warning, since it may be a different build).

Safety: a symbols file whose DWARF build id contradicts the trace's
`build_id` produces a `does not match` warning — decoding with the wrong
build emits plausible *wrong* names, not an error.

### Multi-trace input

Crash exports often contain several `*** ***`-separated dumps. Paste or
pipe the whole file — each trace is decoded against the build its own
`build_id` selects:

```text
── trace 1/2 ──      → build_id A's symbols
── trace 2/2 ──      → build_id B's symbols
```

### Name-level traces (`.map.json`)

`--obfuscate` without `--dwarf-stack-traces` produces frames like
`#0  YE (uN:10)` — no hex PCs, just scrambled identifiers. The sibling
`.map.json` (archived alongside `.symbols`, or passed with `-m`) restores
them:

```sh
symbolize decode -i crash.txt -d app.android-arm64.symbols
# app.android-arm64.symbols: restored 312 obfuscated names via .map.json
```

### Shared/remote archive

A `symbols/` directory doubles as a remote store — `archive`/`watch` write
an `index.json` at its root mapping every `build_id` to its version.
Rsync it to any static host (S3, GCS, nginx) and teammates can pull
symbols for a crash on demand:

```sh
# On the build machine — index.json is written by archive/watch:
rsync -a symbols/ s3://team-bucket/symbols/

# On any machine — fetch the symbols for a crash's build_id:
cat crash.txt | symbolize fetch --base https://cdn.example.com/symbols
symbolize decode -i crash.txt --remote https://cdn.example.com/symbols  # auto-fetch
```

### Auto-archive during development

```sh
symbolize watch     # archives build/symbols → symbols/<version>/ on every change
```

### Wire archiving into a Makefile

```make
release: ## obfuscated release build + archived symbols
	flutter build appbundle --release --obfuscate --split-debug-info=build/symbols
	symbolize archive
```

### Patches and hotfixes

A patch/hotfix build (Shorebird `patch`, an expedited rebuild of the same
`version:`) produces a **new build_id** — the old version's symbols won't
match. Archive each patch under its own label so they coexist:

```sh
shorebird patch android -- --obfuscate --split-debug-info=build/symbols
symbolize archive --version 1.4.0+21-patch.1
```

Version labels are arbitrary strings — anything that sorts/readably
identifies the build works.

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

`SymbolArchive` handles storing/listing versions plus `buildIdIndex` /
`findByBuildId` / `writeIndexFile`; `RemoteSymbolStore` fetches from a
shared store; `selectSymbols` exposes the buildId → os/arch narrowing;
`TraceInfo.parse` reads the crash header; `detectTrace` answers "is this
text an obfuscated trace"; `applySourceContext` renders source lines under
frames; `DecodedTrace.frames`/`toJson` give structured output.

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

Windows release builds emit `app.windows-x64.pdb` instead — CodeView
format, not DWARF. Decoding Windows crashes needs the `.symbols` file from
an ELF target of the same build; a `.pdb` passed to `symbolize` produces a
clear error rather than garbage.

## License

MIT — see [LICENSE](LICENSE).
