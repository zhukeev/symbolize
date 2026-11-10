/// Metadata parsed from the header of an obfuscated Dart AOT stack trace.
///
/// A crash trace from a build made with `--dwarf-stack-traces` starts with a
/// header like:
///
/// ```text
/// os: android arch: arm64 comp: yes sim: no
/// build_id: 'b4485c2ed97b61f597e466d02a0568ce'
/// isolate_dso_base: 7f0000, vm_dso_base: 7f0000
/// ```
///
/// The [os]/[arch] pair narrows which `app.<os>-<arch>.symbols` file applies;
/// [buildId] identifies the exact build when the symbols file carries DWARF
/// build-id information (all `--split-debug-info` outputs do).
class TraceInfo {
  const TraceInfo({this.os, this.arch, this.buildId});

  /// Parses the header fields present in [trace]. Missing fields stay null.
  factory TraceInfo.parse(String trace) {
    final header = _header.firstMatch(trace);
    return TraceInfo(
      os: header?.group(1),
      arch: header?.group(2),
      buildId: _buildId.firstMatch(trace)?.group(1),
    );
  }

  /// Operating system reported by the VM (`android`, `ios`, `macos`, ...).
  final String? os;

  /// CPU architecture reported by the VM (`arm64`, `arm`, `x64`, `ia32`, ...).
  final String? arch;

  /// Build identifier of the snapshot that produced the trace, if present.
  final String? buildId;

  /// True when the trace carried no parseable header information.
  bool get isEmpty => os == null && arch == null && buildId == null;

  /// Returns a copy with non-null fields of [override] winning.
  TraceInfo merge(TraceInfo? other) => other == null
      ? this
      : TraceInfo(os: other.os ?? os, arch: other.arch ?? arch, buildId: other.buildId ?? buildId);

  @override
  String toString() => 'TraceInfo(os: $os, arch: $arch, buildId: $buildId)';

  static final _header = RegExp(r'^os:\s*(\S+)\s+arch:\s*(\S+)', multiLine: true);
  static final _buildId = RegExp(r"^build_id:\s*'([0-9a-fA-F]+)'", multiLine: true);
}

/// Splits [input] into individual stack traces.
///
/// Crash exports (Crashlytics `issue.txt`, logcat dumps) often contain
/// several traces, each starting with the VM's `*** *** ***` banner line.
/// Text before the first banner belongs to the first trace (file headers,
/// breadcrumbs); a banner-less input is returned as a single element.
List<String> splitTraces(String input) {
  final segments = <List<String>>[];
  var current = <String>[];
  var currentHasBanner = false;
  for (final line in input.split('\n')) {
    // A banner starts a new segment only when the buffer already holds one —
    // text before the first banner belongs to the first trace.
    if (_banner.hasMatch(line)) {
      if (currentHasBanner) {
        segments.add(current);
        current = [];
      }
      currentHasBanner = true;
    }
    current.add(line);
  }
  segments.add(current);
  return [
    for (final s in segments)
      if (s.join('\n').trim().isNotEmpty) s.join('\n'),
  ];
}

final _banner = RegExp(r'^\*{2,}\s+\*{2,}(\s+\*{2,})*\s*$');
