import 'dart:convert';
import 'dart:io';

/// The `<name>.map.json` written by `--split-debug-info` next to each
/// `.symbols` file — the obfuscation map.
///
/// The file is a flat JSON array of alternating
/// `[original, obfuscated, ...]` entries:
///
/// ```json
/// ["secondLevel", "ZE", "file:///project/lib/crash.dart", "uN", ...]
/// ```
///
/// [ObfuscationMap] holds the reverse direction — obfuscated → original —
/// and restores identifier names in name-level obfuscated traces (stack
/// frames like `#0  YE (uN:10)` produced by `--obfuscate` builds that lack
/// `--dwarf-stack-traces`). DWARF-decoded output passes through unchanged:
/// its frames already carry real names, which are not map keys.
class ObfuscationMap {
  ObfuscationMap._(this._deobfuscate);

  /// Parses [path] (a `*.map.json` file). Throws [StateError] when the file
  /// is missing or not a valid obfuscation map.
  factory ObfuscationMap.fromFile(String path) {
    final file = File(path);
    final Object? decoded;
    try {
      decoded = jsonDecode(file.readAsStringSync());
    } on Exception {
      throw StateError('$path is not a valid .map.json file');
    }
    if (decoded is! List) throw StateError('$path is not a valid .map.json file');
    final map = <String, String>{};
    for (var i = 0; i + 1 < decoded.length; i += 2) {
      final original = decoded[i];
      final obfuscated = decoded[i + 1];
      // Identity pairs (un-obfuscated names like `main`, `dart:` URIs) are
      // excluded — they'd count as "replacements" and act as false gates.
      if (original is String &&
          obfuscated is String &&
          obfuscated.isNotEmpty &&
          obfuscated != original) {
        map[obfuscated] = original;
      }
    }
    if (map.isEmpty) throw StateError('$path is not a valid .map.json file');
    return ObfuscationMap._(map);
  }

  /// [ObfuscationMap.fromFile] that returns null instead of throwing.
  static ObfuscationMap? tryFile(String path) {
    try {
      return ObfuscationMap.fromFile(path);
    } on StateError {
      return null;
    }
  }

  /// Sibling map path for a `.symbols` file: `app.x.symbols` →
  /// `app.x.map.json`.
  static String pathForSymbols(String symbolsPath) =>
      symbolsPath.endsWith('.symbols') ? '${symbolsPath.substring(0, symbolsPath.length - '.symbols'.length)}.map.json' : '$symbolsPath.map.json';

  final Map<String, String> _deobfuscate;

  /// Number of known obfuscated names.
  int get size => _deobfuscate.length;

  /// The original name for [obfuscated], or null.
  String? lookup(String obfuscated) => _deobfuscate[obfuscated];

  static final _identifier = RegExp(r'[A-Za-z_$][\w$@]*');
  static final _frameLine = RegExp(r'^\s*(?:#\d+|at\s)');
  static final _parenTarget = RegExp(r'\(\s*([A-Za-z_$][\w$@]*)');

  /// Replaces obfuscated identifiers on stack-frame lines of [trace] and
  /// returns the substituted text plus the number of replacements made.
  ///
  /// A line is only rewritten when its `(<location>…)` position holds an
  /// obfuscated key — e.g. `#0  YE (uN:10)` where `uN` maps to a file URI.
  /// Already-decoded frames carry real locations (`file:///…`, `dart:…`)
  /// and are passed through untouched, which matters because short
  /// obfuscated names like `at` or `do` are also real words and would
  /// otherwise corrupt resolved output.
  (String, int) apply(String trace) {
    var count = 0;
    final lines = trace.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (!_frameLine.hasMatch(line)) continue;
      final location = _parenTarget.firstMatch(line)?.group(1);
      if (location == null || !_deobfuscate.containsKey(location)) continue;
      lines[i] = line.splitMapJoin(
        _identifier,
        onMatch: (m) {
          final original = _deobfuscate[m[0]];
          if (original != null) count++;
          return original ?? m[0]!;
        },
      );
    }
    return (lines.join('\n'), count);
  }
}
