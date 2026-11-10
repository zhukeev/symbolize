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

  group('splitTraces', () {
    test('single trace stays whole', () {
      expect(splitTraces(trace), [trace]);
    });

    test('banner-less input returns as one segment', () {
      expect(splitTraces('just a note\n#0 something\n'), hasLength(1));
    });

    test('splits banner-separated traces and keeps the prologue with the first', () {
      final two = '${trace}extra noise\n${File('test/fixtures/trace2.txt').readAsStringSync()}';
      final parts = splitTraces(two);
      expect(parts, hasLength(2));
      expect(parts[0], contains('extra noise'));
      expect(parts[0], contains('b4485c2ed97b61f597e466d02a0568ce'));
      expect(parts[1], contains('b4485c2eb346a69097e466d0b6070d2c'));
    });
  });

  group('detectTrace', () {
    test('real VM dump detected', () {
      expect(detectTrace(trace), isTrue);
    });

    test('name-level trace with build_id detected', () {
      expect(detectTrace("build_id: 'abc123'\n#0      YE (uN:10)\n"), isTrue);
    });

    test('ordinary prose and partial frames rejected', () {
      expect(detectTrace('hello world'), isFalse);
      expect(detectTrace('#0 something without markers'), isFalse);
      expect(detectTrace(''), isFalse);
    });
  });
}
