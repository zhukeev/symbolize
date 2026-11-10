import 'dart:io';

final _frameLocation = RegExp(
  r'^(\s*#\d+\s+\S.*?\s*)\((file://\S+?):(\d+)(?::\d+)?\)\s*$',
);

/// Appends source snippets under each decoded frame whose `file://` URI
/// resolves on this machine — the local analog of Sentry's "source
/// context". Files are read once and cached; frames pointing at missing
/// files, `dart:`/`package:` URIs, or obfuscated tokens pass through
/// untouched.
///
/// ```text
/// #0      secondLevel (file:///x/crash.dart:10:3)
///          9 |   inner();
///       > 10 |   thirdLevel();
///         11 | }
/// ```
String applySourceContext(String output, {int context = 2}) {
  final cache = <String, List<String>?>{};
  List<String>? linesFor(String filePath) => cache.putIfAbsent(
        filePath,
        () => File(filePath).existsSync() ? File(filePath).readAsLinesSync() : null,
      );

  final out = <String>[];
  var shown = 0;
  for (final raw in output.split('\n')) {
    out.add(raw);
    if (raw.isEmpty) continue;
    final m = _frameLocation.firstMatch(raw);
    if (m == null) continue;
    final path = Uri.parse(m[2]!).toFilePath();
    final lines = linesFor(path);
    if (lines == null) continue;
    final center = int.parse(m[3]!);
    final lo = (center - context).clamp(1, lines.length);
    final hi = (center + context).clamp(1, lines.length);
    final indent = ' ' * (m[1]!.length - m[1]!.trimLeft().length + 8);
    for (var i = lo; i <= hi; i++) {
      final marker = i == center ? '>' : ' ';
      out.add('$indent$marker ${i.toString().padLeft(4)} | ${lines[i - 1]}');
    }
    shown++;
  }
  return shown == 0 ? output : out.join('\n');
}
