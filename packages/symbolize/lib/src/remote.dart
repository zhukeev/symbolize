import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'archive.dart';
import 'symbols_file.dart';

/// A remote, team-shared symbol archive — the same layout as the local
/// [SymbolArchive] plus an `index.json` at the root:
///
/// ```text
/// https://example.com/symbols/
///   index.json               {"<buildId>": {"version": "1.4.0",
///                            "files": ["app.x.symbols", "app.x.map.json"]}}
///   1.4.0/
///     app.x.symbols
///     app.x.map.json
/// ```
///
/// Any static file host works — rsync the local `symbols/` directory and
/// its generated `index.json` to S3/GCS/nginx and every teammate can
/// `symbolize fetch` a crash's `build_id` without hunting for the file.
class RemoteSymbolStore {
  RemoteSymbolStore(String baseUrl) : base = Uri.parse(baseUrl.endsWith('/') ? baseUrl : '$baseUrl/');

  /// Base URL the store is served from.
  final Uri base;

  /// The remote `index.json`, or null when unreachable/invalid.
  Future<Map<String, Object?>?> index() async {
    try {
      final body = await _get(base.resolve('index.json'));
      final decoded = jsonDecode(body);
      return decoded is Map ? decoded.cast<String, Object?>() : null;
    } on Exception {
      return null;
    }
  }

  /// The index entry for [buildId], or null.
  Future<Map<String, Object?>?> entryFor(String buildId) async =>
      (await index())?[buildId] as Map<String, Object?>?;

  /// Downloads every file recorded for [buildId] into
  /// `archive`'s `<version>/` dir and writes a manifest so the local
  /// `buildIdIndex` sees it immediately. Returns null when the build id
  /// isn't in the remote index.
  Future<ArchivedVersion?> fetch(String buildId, SymbolArchive archive) async {
    final entry = await entryFor(buildId);
    if (entry == null) return null;
    final version = entry['version'] as String?;
    final names = (entry['files'] as List?)?.whereType<String>().toList();
    if (version == null || names == null || names.isEmpty) return null;

    final dest = archive.versionDir(version)..createSync(recursive: true);
    final files = <Map<String, Object?>>[];
    for (final name in names) {
      if (name.contains('/') || name.contains('..')) continue;
      final target = File(p.join(dest.path, name));
      await target.writeAsBytes(await _getBytes(base.resolve('$version/$name')));
      files.add({
        'name': name,
        'bytes': target.lengthSync(),
        if (name.endsWith('.symbols')) 'buildId': SymbolsFile(target.path).buildId,
      });
    }
    File(p.join(dest.path, 'manifest.json')).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({
        'version': version,
        'archivedAt': DateTime.now().toUtc().toIso8601String(),
        'fetchedFrom': base.toString(),
        'files': files,
      })}\n',
    );
    return ArchivedVersion(dest);
  }

  Future<String> _get(Uri uri) async => utf8.decode(await _getBytes(uri));

  Future<List<int>> _getBytes(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(uri);
      final response = await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw StateError('GET $uri → ${response.statusCode}');
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } finally {
      client.close();
    }
  }
}
