/// One stack frame parsed from decoded trace output.
class DecodedFrame {
  const DecodedFrame({
    required this.index,
    required this.name,
    this.uri,
    this.line,
    this.column,
  });

  /// Frame number as printed (`#0`, `#1`, …).
  final int index;

  /// Function/symbol name — or the raw `abs … virt …` tail when the frame
  /// never resolved.
  final String name;

  /// Source location (`file:`, `package:`, `dart:` URI or an obfuscated
  /// token like `uN` before the `.map.json` pass runs).
  final String? uri;

  final int? line;
  final int? column;

  /// Still carrying `_kDart…SnapshotInstructions+0x…` — the signature of a
  /// frame the symbols file couldn't decode (or a VM-internal PC).
  bool get isInternal => name.contains('SnapshotInstructions+0x');

  /// A frame that decoded to a source position.
  bool get resolved => !isInternal && uri != null;

  Map<String, Object?> toJson() => {
        'index': index,
        'name': name,
        if (uri != null) 'uri': uri,
        if (line != null) 'line': line,
        if (column != null) 'column': column,
      };
}

final _frameLine = RegExp(
  r'^\s*#(\d+)\s+(\S.*?)\s*(?:\((\S+?):(\d+)(?::(\d+))?\))?\s*$',
);

/// Parses every `#N …` line in decoded [output] into a [DecodedFrame].
/// Header/banner lines and non-frame text are skipped.
List<DecodedFrame> parseFrames(String output) => [
      for (final line in output.split('\n'))
        if (_frameLine.firstMatch(line) case final m?)
          DecodedFrame(
            index: int.parse(m[1]!),
            name: m[2]!,
            uri: m[3],
            line: m[4] == null ? null : int.parse(m[4]!),
            column: m[5] == null ? null : int.parse(m[5]!),
          ),
    ];
