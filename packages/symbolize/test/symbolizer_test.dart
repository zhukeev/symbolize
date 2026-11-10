import 'dart:io';

import 'package:symbolize/symbolize.dart';
import 'package:test/test.dart';

void main() {
  final trace = File('test/fixtures/trace.txt').readAsStringSync();
  final symbols = SymbolsFile('test/fixtures/app.macos.symbols');
  final wrong = SymbolsFile('test/fixtures/app2.macos.symbols');

  test('explicit symbols decode real frames', () async {
    final result = await symbolize(trace, symbols: symbols);
    expect(result.decodings.single.symbols, same(symbols));
    expect(result.decodings.single.resolved, isTrue);
    expect(result.decodings.single.output, contains('secondLevel (file:///private/tmp/symfix/crash.dart:10:3)'));
  });

  test('explicit wrong-build symbols decode to wrong names — resolve by buildId instead', () async {
    // app2.macos.symbols is a different build: frames still "resolve", but
    // to crash2.dart's names — plausible garbage. This is why explicit
    // --symbols bypasses safety and archives pick by buildId.
    final result = await symbolize(trace, symbols: wrong);
    expect(result.decodings.single.output, contains('outerCall'));
    expect(result.decodings.single.output, isNot(contains('secondLevel')));
  });

  test('archive decode picks the right file by buildId', () async {
    final tmp = Directory.systemTemp.createTempSync('symbolize_e2e');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final archive = SymbolArchive(Directory('${tmp.path}/symbols'));
    for (final v in ['1.0.0', '2.0.0']) {
      final from = Directory('${tmp.path}/from_$v')..createSync();
      final src = v == '1.0.0' ? 'app.macos.symbols' : 'app2.macos.symbols';
      File('test/fixtures/$src').copySync('${from.path}/app.macos.symbols');
      archive.store(version: v, from: from);
    }

    // The trace came from the 1.0.0 build; a 2.0.0 symbols file must not be used.
    final result = await symbolize(trace, symbolsDir: archive.symbolsDir, version: '1.0.0');
    expect(result.decodings.single.resolved, isTrue);
    expect(result.decodings.single.output, contains('secondLevel'));

    // Asking for 2.0.0 decodes against the wrong build's file: frames map
    // to crash2.dart names — garbage that looks plausible.
    final miss = await symbolize(trace, symbolsDir: archive.symbolsDir, version: '2.0.0');
    expect(miss.decodings.single.output, contains('outerCall'));
    expect(miss.decodings.single.output, isNot(contains('secondLevel')));
  });

  test('no symbols anywhere throws StateError', () async {
    final empty = Directory.systemTemp.createTempSync('symbolize_empty');
    addTearDown(() => empty.deleteSync(recursive: true));
    expect(
      () => symbolize(trace, symbolsDir: empty, version: '9.9.9'),
      throwsStateError,
    );
  });

  group('build id matching', () {
    test('explicit file matching the trace reports no warning', () async {
      final result = await symbolize(trace, symbols: symbols);
      expect(result.decodings.single.buildIdMatches, isTrue);
      expect(result.warnings, isEmpty);
    });

    test('explicit wrong-build file produces a build id warning', () async {
      final result = await symbolize(trace, symbols: wrong);
      expect(result.decodings.single.buildIdMatches, isFalse);
      expect(result.warnings.single, contains('does not match'));
      expect(result.warnings.single, contains('b4485c2ed97b61f597e466d02a0568ce'));
    });
  });

  group('symbolizeAll', () {
    test('decodes each banner-separated trace against its own build', () async {
      final trace2 = File('test/fixtures/trace2.txt').readAsStringSync();
      // Both .symbols files in the pool; each trace's build_id selects its
      // own file — trace -> app.macos, trace2 -> app2.macos.
      final results = await symbolizeAll(
        '$trace\n$trace2',
        buildSymbolsDir: Directory('test/fixtures'),
      );
      expect(results, hasLength(2));
      expect(results[0].decodings.single.symbols.name, 'app.macos.symbols');
      expect(results[0].decodings.single.output, contains('secondLevel'));
      expect(results[1].decodings.single.symbols.name, 'app2.macos.symbols');
      expect(results[1].decodings.single.output, contains('outerCall'));
      for (final r in results) {
        expect(r.warnings, isEmpty);
        expect(r.decodings.single.buildIdMatches, isTrue);
      }
    });
  });

  group('.map.json pass', () {
    const nameTrace = '''
#0      YE (uN:10)
#1      ZE (uN:6)
''';

    test('sibling map restores obfuscated names', () async {
      // app.macos.map.json sits next to app.macos.symbols in fixtures/.
      final result = await symbolize(nameTrace, symbols: symbols);
      final d = result.decodings.single;
      expect(d.namesRestored, greaterThan(0));
      expect(d.output, contains('thirdLevel (file:///private/tmp/symfix/crash.dart:10)'));
      expect(d.output, contains('secondLevel'));
    });

    test('explicit obfuscationMap is used when given', () async {
      final result = await symbolize(
        nameTrace,
        symbols: symbols,
        obfuscationMap: ObfuscationMap.fromFile('test/fixtures/app.macos.map.json'),
      );
      expect(result.decodings.single.output, contains('thirdLevel'));
    });
  });
}
