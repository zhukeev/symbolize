import 'dart:convert';
import 'dart:io';

import 'package:native_stack_traces/native_stack_traces.dart';
import 'package:path/path.dart' as p;

import 'obfuscation_map.dart';

/// A `--split-debug-info` symbols file (`app.<platform>.symbols`).
///
/// The file is an ELF/DWARF container; [Dwarf.fromFile] parses it lazily on
/// first access and caches the result.
class SymbolsFile {
  SymbolsFile(this.path);

  /// Path to the `.symbols` file.
  final String path;

  Dwarf? _dwarf;
  bool _loaded = false;

  /// Basename, e.g. `app.android-arm64.symbols`.
  String get name => p.basename(path);

  /// Windows builds emit `app.windows-x64.pdb` instead of `.symbols` —
  /// CodeView format the DWARF decoder can't read. Detected early so the
  /// user gets a clear message instead of a parse failure.
  bool get isPdb => path.endsWith('.pdb');

  /// Parsed DWARF info, or null when [path] is missing or not a symbols file.
  Dwarf? get dwarf {
    if (!_loaded) {
      _loaded = true;
      try {
        _dwarf = File(path).existsSync() ? Dwarf.fromFile(path) : null;
      } on Exception {
        _dwarf = null;
      }
    }
    return _dwarf;
  }

  /// The snapshot build id embedded in the DWARF info, when present —
  /// comparable to `TraceInfo.buildId`.
  String? get buildId => dwarf?.buildId();

  /// Path of the sibling `*.map.json` for this file
  /// (`app.x.symbols` → `app.x.map.json`) when it exists on disk.
  String? get mapPath {
    final candidate = ObfuscationMap.pathForSymbols(path);
    return File(candidate).existsSync() ? candidate : null;
  }

  ObfuscationMap? _map;
  bool _mapLoaded = false;

  /// The sibling `.map.json` parsed as an [ObfuscationMap], or null when
  /// absent or invalid. Lazily loaded and cached.
  ObfuscationMap? get obfuscationMap {
    if (!_mapLoaded) {
      _mapLoaded = true;
      final path = mapPath;
      _map = path == null ? null : ObfuscationMap.tryFile(path);
    }
    return _map;
  }

  /// Decodes [trace] against this file.
  ///
  /// Lines that don't look like non-symbolic frames pass through unchanged,
  /// so decoding with the wrong file yields the input back rather than an
  /// error. When [includeInternalFrames] is false, frames inside the VM and
  /// runtime internals are dropped from the output.
  Future<String> symbolize(String trace, {bool includeInternalFrames = true}) {
    if (isPdb) {
      throw StateError('$path is a Windows PDB (CodeView format) — the '
          'decoder needs the ELF .symbols file from the same build');
    }
    final d = dwarf;
    if (d == null) throw StateError('$path is not a valid .symbols file');
    return Stream.value(trace)
        .transform(const LineSplitter())
        .transform(DwarfStackTraceDecoder(d, includeInternalFrames: includeInternalFrames))
        .join('\n');
  }

  @override
  String toString() => 'SymbolsFile($path)';
}
