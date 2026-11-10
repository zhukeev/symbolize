import 'dart:io';

import 'archive.dart';
import 'obfuscation_map.dart';
import 'resolver.dart';
import 'symbols_file.dart';
import 'trace_info.dart';

final _unresolvedFrame = RegExp(r'_kDart(?:Isolate|Vm)SnapshotInstructions\+0x');

/// Output of [symbolize] for one candidate symbols file.
class DecodedTrace {
  const DecodedTrace({
    required this.symbols,
    required this.output,
    this.resolved = true,
    this.buildIdMatches,
    this.namesRestored = 0,
  });

  /// The symbols file this output was decoded with.
  final SymbolsFile symbols;

  /// The symbolized trace text.
  final String output;

  /// Heuristic: true when no unresolved `_kDart…SnapshotInstructions+0x…`
  /// frame markers remain in [output]. Note a wrong-but-valid symbols file
  /// can still "resolve" every frame — to wrong names; exact matching happens
  /// in [selectSymbols] via the DWARF build id, and [buildIdMatches] reports
  /// when the file used disagreed with the trace.
  final bool resolved;

  /// Whether this file's DWARF build id equals the trace header's
  /// `build_id` — `null` when either side lacks one and no comparison is
  /// possible. `false` means the decoded names are almost certainly wrong.
  final bool? buildIdMatches;

  /// Identifiers restored by the `.map.json` pass — non-zero only for
  /// name-level obfuscated traces (no `--dwarf-stack-traces`).
  final int namesRestored;
}

/// Result of [symbolize]: the candidates considered plus one [DecodedTrace]
/// per candidate actually tried.
class SymbolizeResult {
  const SymbolizeResult({required this.decodings, this.warnings = const []});

  /// One entry per candidate file tried, in selection order. When the trace
  /// header (os/arch) or buildId identified a single file, this has length 1.
  final List<DecodedTrace> decodings;

  /// Human-readable warnings — e.g. a symbols file whose DWARF build id
  /// contradicts the trace's `build_id`.
  final List<String> warnings;

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
/// When a `.map.json` sits next to the symbols file (or [obfuscationMap] is
/// given), obfuscated identifiers on stack-frame lines are also restored —
/// covering name-level traces that carry no hex PCs.
///
/// Throws [StateError] when no candidates are found or a file isn't valid
/// symbols output.
Future<SymbolizeResult> symbolize(
  String trace, {
  SymbolsFile? symbols,
  Directory? symbolsDir,
  String? version,
  Directory? buildSymbolsDir,
  ObfuscationMap? obfuscationMap,
  String? os,
  String? arch,
  bool includeInternalFrames = true,
}) async =>
    _decodeTrace(
      trace,
      _pool(symbols: symbols, symbolsDir: symbolsDir, version: version, buildSymbolsDir: buildSymbolsDir),
      os: os,
      arch: arch,
      obfuscationMap: obfuscationMap,
      includeInternalFrames: includeInternalFrames,
    );

/// Like [symbolize] but splits [input] into individual traces first —
/// crash exports routinely contain several `*** ***` banner-separated
/// dumps, each potentially from a different build. Symbols selection
/// (buildId/os/arch) runs per trace, and the returned list has one
/// [SymbolizeResult] per trace found.
Future<List<SymbolizeResult>> symbolizeAll(
  String input, {
  SymbolsFile? symbols,
  Directory? symbolsDir,
  String? version,
  Directory? buildSymbolsDir,
  ObfuscationMap? obfuscationMap,
  String? os,
  String? arch,
  bool includeInternalFrames = true,
}) async {
  final pool = _pool(symbols: symbols, symbolsDir: symbolsDir, version: version, buildSymbolsDir: buildSymbolsDir);
  return [
    for (final trace in splitTraces(input))
      await _decodeTrace(
        trace,
        pool,
        os: os,
        arch: arch,
        obfuscationMap: obfuscationMap,
        includeInternalFrames: includeInternalFrames,
      ),
  ];
}

List<SymbolsFile> _pool({
  SymbolsFile? symbols,
  Directory? symbolsDir,
  String? version,
  Directory? buildSymbolsDir,
}) {
  if (symbols != null) return [symbols];
  final pool = (version != null && symbolsDir != null) ? SymbolArchive(symbolsDir).files(version) : <SymbolsFile>[];
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
  return pool;
}

Future<SymbolizeResult> _decodeTrace(
  String trace,
  List<SymbolsFile> pool, {
  required String? os,
  required String? arch,
  required ObfuscationMap? obfuscationMap,
  required bool includeInternalFrames,
}) async {
  final info = TraceInfo.parse(trace).merge(TraceInfo(os: os, arch: arch));
  final candidates = await selectSymbols(pool, info);
  final decodings = <DecodedTrace>[];
  final warnings = <String>[];
  final traceBuildId = info.buildId?.toLowerCase();
  for (final file in candidates) {
    var output = await file.symbolize(trace, includeInternalFrames: includeInternalFrames);
    final map = obfuscationMap ?? file.obfuscationMap;
    var namesRestored = 0;
    if (map != null) (output, namesRestored) = map.apply(output);
    final bool? buildIdMatches = (traceBuildId != null && file.buildId != null)
        ? file.buildId!.toLowerCase() == traceBuildId
        : null;
    if (buildIdMatches == false) {
      warnings.add('${file.name} buildId ${file.buildId} does not match trace '
          'build_id ${info.buildId} — decoded names are probably wrong');
    }
    decodings.add(DecodedTrace(
      symbols: file,
      output: output,
      resolved: !_unresolvedFrame.hasMatch(output),
      buildIdMatches: buildIdMatches,
      namesRestored: namesRestored,
    ));
  }
  return SymbolizeResult(decodings: decodings, warnings: warnings);
}
