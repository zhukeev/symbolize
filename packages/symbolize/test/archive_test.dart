import 'dart:io';

import 'package:symbolize/symbolize.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late SymbolArchive archive;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('symbolize_archive');
    archive = SymbolArchive(Directory('${tmp.path}/symbols'));
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  Directory stageSplitDebugInfo(String name) {
    final from = Directory('${tmp.path}/$name')..createSync();
    for (final f in Directory('test/fixtures').listSync().whereType<File>()) {
      if (f.path.endsWith('.symbols') || f.path.endsWith('.map.json')) {
        f.copySync('${from.path}/${f.path.split('/').last}');
      }
    }
    return from;
  }

  test('store copies symbols + map and writes manifest with buildIds', () async {
    final v = archive.store(version: '1.2.3', from: stageSplitDebugInfo('from'));
    expect(v.dir.path, endsWith('symbols/1.2.3'));
    final files = v.manifest!['files'] as List;
    expect(files.map((f) => (f as Map)['name']), containsAll(['app.macos.symbols', 'app.macos.map.json', 'app2.macos.symbols']));
    final app = files.firstWhere((f) => (f as Map)['name'] == 'app.macos.symbols') as Map;
    expect(app['buildId'], 'b4485c2ed97b61f597e466d02a0568ce');
  });

  test('files returns only .symbols files', () {
    archive.store(version: '1.0.0', from: stageSplitDebugInfo('from'));
    final files = archive.files('1.0.0');
    expect(files, hasLength(2));
    expect(files.map((f) => f.name), containsAll(['app.macos.symbols', 'app2.macos.symbols']));
  });

  test('versions lists stored versions sorted', () {
    archive.store(version: '2.0.0', from: stageSplitDebugInfo('from'));
    archive.store(version: '1.0.0', from: stageSplitDebugInfo('from2'));
    expect(archive.versions().map((v) => v.version), ['1.0.0', '2.0.0']);
  });

  test('store with no split-debug-info fails helpfully', () {
    final empty = Directory('${tmp.path}/nada')..createSync();
    expect(() => archive.store(version: '1.0.0', from: empty), throwsStateError);
  });

  test('buildIdIndex maps build_ids to their versions without DWARF parsing', () async {
    archive.store(version: '9.9.9', from: stageSplitDebugInfo('from'));
    final index = await archive.buildIdIndex();
    expect(index['b4485c2ed97b61f597e466d02a0568ce'], '9.9.9');
    expect(index['b4485c2eb346a69097e466d0b6070d2c'], '9.9.9');
    final hit = await archive.findByBuildId('b4485c2ed97b61f597e466d02a0568ce');
    expect(hit?.version, '9.9.9');
    expect(await archive.findByBuildId('deadbeef'), isNull);
  });

  test('buildIdIndex falls back to DWARF parsing without a manifest', () async {
    final dir = archive.versionDir('1.0.0')..createSync(recursive: true);
    File('test/fixtures/app.macos.symbols').copySync('${dir.path}/app.macos.symbols');
    final index = await archive.buildIdIndex();
    expect(index['b4485c2ed97b61f597e466d02a0568ce'], '1.0.0');
  });

  test('scanForSymbols finds files within depth and skips hidden dirs', () {
    final nested = Directory('${tmp.path}/a/b/c')..createSync(recursive: true);
    File('test/fixtures/app.macos.symbols').copySync('${nested.path}/app.macos.symbols');
    final hidden = Directory('${tmp.path}/.dart_tool/x')..createSync(recursive: true);
    File('test/fixtures/app2.macos.symbols').copySync('${hidden.path}/app2.macos.symbols');
    final found = scanForSymbols(tmp);
    expect(found.map((f) => f.name), ['app.macos.symbols']);
  });

  test('store writes meta and ignores non-symbol files', () {
    final from = stageSplitDebugInfo('from');
    File('${from.path}/ignored.txt').writeAsStringSync('not symbols');
    final entry = archive.store(version: '1.2.3+4', from: from, meta: {'gitSha': 'abc123'});

    expect(entry.version, '1.2.3+4');
    expect(File('${entry.dir.path}/ignored.txt').existsSync(), isFalse);
    final m = entry.manifest!;
    expect(m['version'], '1.2.3+4');
    expect(m['gitSha'], 'abc123');
  });
}
