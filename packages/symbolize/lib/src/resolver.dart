import 'symbols_file.dart';
import 'trace_info.dart';

/// Dart `arch:` names that differ from the `<os>-<arch>` part Flutter uses in
/// `app.<platform>.symbols` filenames.
const archAliases = {
  'ia32': 'x86',
  'x86_64': 'x64',
  'aarch64': 'arm64',
  'armv7': 'arm',
  'armv7l': 'arm',
};

/// Narrows [pool] to the symbols files most likely to decode [trace]'s
/// frames, best match first:
///
/// 1. A DWARF `buildId` equal to [TraceInfo.buildId] — deterministic.
/// 2. Filename matches `.<os>` then `-<arch>` (with [archAliases]).
/// 3. Otherwise the whole pool — the caller decodes each candidate and the
///    matching file is the one whose output resolves frames.
///
/// A pool of zero or one always returns as-is.
Future<List<SymbolsFile>> selectSymbols(List<SymbolsFile> pool, TraceInfo trace) async {
  if (pool.length <= 1) return pool;

  final buildId = trace.buildId?.toLowerCase();
  if (buildId != null) {
    for (final file in pool) {
      if (file.buildId?.toLowerCase() == buildId) return [file];
    }
  }

  var rest = pool;
  final os = trace.os;
  if (os != null) {
    final byOs = rest.where((f) => f.name.contains('.$os')).toList();
    if (byOs.isNotEmpty) rest = byOs;
  }
  final arch = trace.arch;
  if (arch != null && rest.length > 1) {
    final alias = archAliases[arch] ?? arch;
    final byArch = rest.where((f) => f.name.contains('-$alias.')).toList();
    if (byArch.isNotEmpty) rest = byArch;
  }
  return rest;
}
