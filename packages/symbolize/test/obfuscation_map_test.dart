import 'package:symbolize/symbolize.dart';
import 'package:test/test.dart';

void main() {
  final map = ObfuscationMap.fromFile('test/fixtures/app.macos.map.json');

  test('parses the gen_snapshot name map — obfuscated to original', () {
    // ~1.5k pairs are identity (un-obfuscated names) and are excluded.
    expect(map.size, greaterThan(3000));
    // Real pairs from the fixture build (verified against the map file).
    expect(map.lookup('YE'), 'thirdLevel');
    expect(map.lookup('ZE'), 'secondLevel');
    expect(map.lookup('uN'), 'file:///private/tmp/symfix/crash.dart');
  });

  test('apply restores identifiers on stack-frame lines', () {
    const obfuscated = '''
Unhandled exception:
YE: exploded
#0      YE (uN:10)
#1      ZE (uN:6)
''';
    final (text, count) = map.apply(obfuscated);
    expect(text, contains('#0      thirdLevel (file:///private/tmp/symfix/crash.dart:10)'));
    expect(text, contains('#1      secondLevel (file:///private/tmp/symfix/crash.dart:6)'));
    // The exception line is not a frame — `YE:` prose is left alone.
    expect(text, contains('YE: exploded'));
    expect(count, 4);
  });

  test('apply is a no-op on already-decoded traces', () {
    const decoded = '#0      main (file:///project/lib/main.dart:1:1)';
    final (text, count) = map.apply(decoded);
    expect(text, decoded);
    expect(count, 0);
  });

  test('invalid files are rejected', () {
    expect(() => ObfuscationMap.fromFile('test/fixtures/trace.txt'), throwsStateError);
    expect(() => ObfuscationMap.fromFile('does/not/exist.map.json'), throwsStateError);
    expect(ObfuscationMap.tryFile('does/not/exist.map.json'), isNull);
  });
}
