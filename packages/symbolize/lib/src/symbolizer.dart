import 'dart:io';

import 'archive.dart';
import 'resolver.dart';
import 'symbols_file.dart';
import 'trace_info.dart';

final _unresolvedFrame = RegExp(r'_kDart(?:Isolate|Vm)SnapshotInstructions\+0x');

/// Output of [symbolize] for one candidate symbols file.
class DecodedTrace {
  const DecodedTrace({required this.symbols, required this.output, this.resolved = true});

  /// The symbols file this output was decoded with.
  final SymbolsFile symbols;

  /// The symbolized trace text.
  final String output;

  /// Heuristic: true when no unresolved `_kDart…SnapshotInstructions+0x…`
  /// frame markers remain in [output]. Note a wrong-but-valid symbols file
  /// can still "resolve" every frame — to wrong names; exact matching happens
  /// earlier in [selectSymbols] via the DWARF build id.
  final bool resolved;
}

/// Result of [symbolize]: the candidates considered plus one [DecodedTrace]
/// per candidate actually tried.
class SymbolizeResult {
  const SymbolizeResult({required this.decodings});

  /// One entry per candidate file tried, in selection order. When the trace
  /// header (os/arch) or buildId identified a single file, this has length 1.
  final List<DecodedTrace> decodings;

  /// Decodings that actually resolved frames — normally the whole list.
  List<DecodedTrace> get resolved => [for (final d in decodings) if (d.resolved) d];
}

/// Deobfuscates an AOT [trace] against resolved symbols files.
///
/// Symbols are resolved in this order:
///
/// 1. [symbols] — an explicit file, always wins.
/// 2. `SymbolArchive(symbolsDir).files(version)` — the archive for the given
///    app [version]. Requires [symbolsDir] and [version] to be non-null.
/// 3. [buildSymbolsDir] — a raw `--split-debug-info` output dir (typically
///    `build/symbols/`), used when the archive has nothing for [version].
///
/// The candidate pool is then narrowed by [selectSymbols] (buildId, then
/// os/arch filename match). Each surviving candidate produces a
/// [DecodedTrace] — more than one only when the trace header can't
/// disambiguate, in which case `result.resolved` tells you which worked.
///
/// Throws [StateError] when no candidates are found or a file isn't valid
/// symbols output.
Future<SymbolizeResult> symbolize(
  String trace, {
  SymbolsFile? symbols,
  Directory? symbolsDir,
  String? version,
  Directory? buildSymbolsDir,
  String? os,
  String? arch,
  bool includeInternalFrames = true,
}) async {
  final info = TraceInfo.parse(trace).merge(TraceInfo(os: os, arch: arch));

  final List<SymbolsFile> pool;
  if (symbols != null) {
    pool = [symbols];
  } else {
    pool = (version != null && symbolsDir != null) ? SymbolArchive(symbolsDir).files(version) : [];
    if (pool.isEmpty && buildSymbolsDir != null && buildSymbolsDir.existsSync()) {
      pool.addAll([
        for (final f in buildSymbolsDir.listSync().whereType<File>())
          if (f.path.endsWith('.symbols')) SymbolsFile(f.path),
      ]);
    }
    if (pool.isEmpty) {
      throw StateError('no symbols found — pass an explicit file, an archive '
          'version, or a split-debug-info directory');
    }
  }

  final candidates = await selectSymbols(pool, info);
  final decodings = <DecodedTrace>[];
  for (final file in candidates) {
    final output = await file.symbolize(trace, includeInternalFrames: includeInternalFrames);
    decodings.add(DecodedTrace(
      symbols: file,
      output: output,
      resolved: !_unresolvedFrame.hasMatch(output),
    ));
  }
  return SymbolizeResult(decodings: decodings);
}
