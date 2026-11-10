/// Deobfuscate Dart and Flutter release (AOT) stack traces.
///
/// Given an obfuscated trace (from Crashlytics, a bug report, stderr of an
/// AOT binary built with `--dwarf-stack-traces`) and the matching
/// `--split-debug-info` symbols file, [symbolize] returns the readable
/// trace — the same engine `flutter symbolize` uses, without requiring the
/// Flutter tool.
///
/// ```dart
/// final result = await symbolize(traceText,
///     symbols: SymbolsFile('app.android-arm64.symbols'));
/// print(result.decodings.single.output);
/// ```
///
/// For apps that keep per-version archives, see [SymbolArchive] and
/// [findProjectRoot]/[pubspecVersion] for resolving which symbols to use.
library;

export 'src/archive.dart';
export 'src/project.dart';
export 'src/resolver.dart';
export 'src/symbols_file.dart';
export 'src/symbolizer.dart';
export 'src/trace_info.dart';
export 'src/version.dart';
