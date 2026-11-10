import 'dart:io';

import 'package:path/path.dart' as p;

/// Walks up from [start] (default: cwd) looking for a directory containing
/// pubspec.yaml — i.e. a Dart/Flutter project root. Falls back to [start]
/// when none is found.
Directory findProjectRoot([Directory? start]) {
  final origin = (start ?? Directory.current).absolute;
  var dir = origin;
  while (true) {
    if (File(p.join(dir.path, 'pubspec.yaml')).existsSync()) return dir;
    if (dir.parent.path == dir.path) return origin;
    dir = dir.parent;
  }
}

/// The `version:` field of `<root>/pubspec.yaml`, or null.
String? pubspecVersion(Directory root) {
  final pubspec = File(p.join(root.path, 'pubspec.yaml'));
  if (!pubspec.existsSync()) return null;
  return RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec.readAsStringSync())?.group(1);
}
