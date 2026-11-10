import 'dart:io';

import 'package:symbolize/symbolize.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late Directory from;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('symbolize_test');
    from = Directory('${tmp.path}/from')..createSync();
    File('test/fixtures/app.macos.symbols').copySync('${tmp.path}/from/app.macos.symbols');
    File('${tmp.path}/from/app.macos.map.json').writeAsStringSync('{}');
    File('${tmp.path}/from/ignored.txt').writeAsStringSync('not symbols');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('store copies symbols+map, writes manifest with buildId', () {
    final archive = SymbolArchive(Directory('${tmp.path}/symbols'));
    final entry = archive.store(version: '1.2.3+4', from: from, meta: {'gitSha': 'abc123'});

    expect(entry.version, '1.2.3+4');
    expect(File('${entry.dir.path}/app.macos.symbols').existsSync(), isTrue);
    expect(File('${entry.dir.path}/app.macos.map.json').existsSync(), isTrue);
    expect(File('${entry.dir.path}/ignored.txt').existsSync(), isFalse);

    final m = entry.manifest!;
    expect(m['version'], '1.2.3+4');
    expect(m['gitSha'], 'abc123');
    final files = m['files'] as List;
    final sym = files.singleWhere((f) => (f as Map)['name'] == 'app.macos.symbols') as Map;
    expect(sym['buildId'], 'b4485c2ed97b61f597e466d02a0568ce');
  });

  test('files() and versions() read the archive back', () {
    final archive = SymbolArchive(Directory('${tmp.path}/symbols'));
    archive.store(version: '1.0.0', from: from);

    expect(archive.files('1.0.0').single.name, 'app.macos.symbols');
    expect(archive.files('nope'), isEmpty);
    expect(archive.versions().single.version, '1.0.0');
  });

  test('store with no split-debug-info fails helpfully', () {
    final archive = SymbolArchive(Directory('${tmp.path}/symbols'));
    expect(
      () => archive.store(version: '1.0.0', from: Directory('${tmp.path}/empty')),
      throwsStateError,
    );
  });
}
