import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'symbols_file.dart';

/// A versioned on-disk store of `--split-debug-info` output.
///
/// `flutter build <target> --release --obfuscate --split-debug-info=DIR`
/// writes `app.*.symbols` (and `app.*.map.json`) into DIR, which is
/// typically gitignored `build/symbols/` — overwritten by the next build.
/// [store] copies them into `<symbolsDir>/<version>/` plus a manifest so a
/// crash trace from any shipped version can still be decoded later.
///
/// Layout:
///
/// ```text
/// symbols/
///   1.4.0+21/
///     app.android-arm64.symbols
///     app.ios.symbols
///     manifest.json
/// ```
class SymbolArchive {
  /// Creates an archive rooted at [symbolsDir] — the directory that holds
  /// one subdirectory per app version.
  SymbolArchive(this.symbolsDir);

  /// Archive at `<projectRoot>/symbols`.
  SymbolArchive.at(Directory projectRoot) : this(Directory(p.join(projectRoot.path, 'symbols')));

  final Directory symbolsDir;

  Directory versionDir(String version) => Directory(p.join(symbolsDir.path, version));

  /// `*.symbols` files archived for [version] (empty when none).
  List<SymbolsFile> files(String version) {
    final dir = versionDir(version);
    if (!dir.existsSync()) return [];
    final files = [
      for (final f in dir.listSync().whereType<File>())
        if (f.path.endsWith('.symbols')) SymbolsFile(f.path),
    ];
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  /// All archived versions, sorted by directory name.
  List<ArchivedVersion> versions() {
    if (!symbolsDir.existsSync()) return [];
    final dirs = symbolsDir.listSync().whereType<Directory>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return [for (final d in dirs) ArchivedVersion(d)];
  }

  /// Copies `*.symbols` and `*.map.json` from [from] into
  /// `<symbolsDir>/<version>/` and writes `manifest.json`.
  ///
  /// [meta] is merged into the manifest — callers typically add git SHA or
  /// toolchain versions. Each file's DWARF buildId is recorded so the
  /// archive is self-describing.
  ArchivedVersion store({required String version, required Directory from, Map<String, Object?> meta = const {}}) {
    final sources = from.existsSync()
        ? from
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.symbols') || f.path.endsWith('.map.json'))
            .toList()
        : <File>[];
    if (sources.isEmpty) {
      throw StateError('no split-debug-info in ${from.path} — build with '
          '--obfuscate --split-debug-info=<dir> first');
    }
    sources.sort((a, b) => a.path.compareTo(b.path));
    final dest = versionDir(version)..createSync(recursive: true);
    final files = <Map<String, Object?>>[];
    for (final f in sources) {
      final target = p.join(dest.path, p.basename(f.path));
      f.copySync(target);
      files.add({
        'name': p.basename(f.path),
        'bytes': f.lengthSync(),
        if (f.path.endsWith('.symbols')) 'buildId': SymbolsFile(target).buildId,
      });
    }
    final manifest = {
      'version': version,
      'archivedAt': DateTime.now().toUtc().toIso8601String(),
      ...meta,
      'files': files,
    };
    File(p.join(dest.path, 'manifest.json'))
        .writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(manifest)}\n');
    return ArchivedVersion(dest);
  }
}

/// One `<symbolsDir>/<version>/` directory.
class ArchivedVersion {
  ArchivedVersion(this.dir);

  final Directory dir;

  String get version => p.basename(dir.path);

  /// Parsed manifest.json, or null when absent/corrupt.
  Map<String, Object?>? get manifest {
    try {
      final f = File(p.join(dir.path, 'manifest.json'));
      if (!f.existsSync()) return null;
      final decoded = jsonDecode(f.readAsStringSync());
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  /// `*.symbols` files in this version dir.
  List<SymbolsFile> get files => SymbolArchive(dir.parent).files(version);
}
