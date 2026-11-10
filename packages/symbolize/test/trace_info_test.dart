import 'dart:io';

import 'package:symbolize/symbolize.dart';
import 'package:test/test.dart';

void main() {
  final trace = File('test/fixtures/trace.txt').readAsStringSync();

  test('parses os, arch and build_id from a real crash header', () {
    final info = TraceInfo.parse(trace);
    expect(info.os, 'macos');
    expect(info.arch, 'arm64');
    expect(info.buildId, 'b4485c2ed97b61f597e466d02a0568ce');
    expect(info.isEmpty, isFalse);
  });

  test('headerless trace yields empty info', () {
    final info = TraceInfo.parse('#00 abs 0x123 _kDartIsolateSnapshotInstructions+0x1\n');
    expect(info.isEmpty, isTrue);
    expect(info.os, isNull);
    expect(info.buildId, isNull);
  });

  test('merge keeps non-null fields of the override', () {
    final merged = TraceInfo.parse(trace).merge(const TraceInfo(os: 'android'));
    expect(merged.os, 'android');
    expect(merged.arch, 'arm64');
    expect(merged.buildId, isNotNull);
  });
}
