import 'dart:io';

import 'package:symbolize/symbolize.dart';
import 'package:test/test.dart';

void main() {
  final trace = File('test/fixtures/trace.txt').readAsStringSync();
  final symbols = SymbolsFile('test/fixtures/app.macos.symbols');

  test('exposes the DWARF build id matching the trace header', () {
    expect(symbols.name, 'app.macos.symbols');
    expect(symbols.buildId, 'b4485c2ed97b61f597e466d02a0568ce');
  });

  test('symbolize resolves obfuscated frames to names, files and lines', () async {
    final out = await symbols.symbolize(trace);
    expect(out, contains('secondLevel (file:///private/tmp/symfix/crash.dart:10:3)'));
    expect(out, contains('thirdLevel'));
    expect(out, contains('main'));
    // Non-frame lines pass through untouched.
    expect(out, contains('Bad state: fixture crash for symbolize tests'));
  });

  test('missing or invalid files are not valid symbols', () {
    expect(SymbolsFile('does/not/exist.symbols').dwarf, isNull);
    expect(SymbolsFile('test/fixtures/trace.txt').dwarf, isNull);
    expect(() => SymbolsFile('test/fixtures/trace.txt').symbolize(trace), throwsStateError);
  });
}
