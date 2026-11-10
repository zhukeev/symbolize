import 'dart:io';

import 'package:symbolize/symbolize.dart';
import 'package:test/test.dart';

void main() {
  test('symbolizeVersion matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec)!.group(1);
    expect(symbolizeVersion, version);
  });

  test('findProjectRoot walks up to this package and reads its version', () {
    final root = findProjectRoot(Directory('test/fixtures'));
    expect(pubspecVersion(root), symbolizeVersion);
  });
}
