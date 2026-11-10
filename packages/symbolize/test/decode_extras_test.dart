import 'dart:convert';
import 'dart:io';

import 'package:symbolize/symbolize.dart';
import 'package:test/test.dart';

void main() {
  final trace = File('test/fixtures/trace.txt').readAsStringSync();
  final symbols = SymbolsFile('test/fixtures/app.macos.symbols');

  group('parseFrames / toJson', () {
    test('decoded frames carry name + location', () async {
      final result = await symbolize(trace, symbols: symbols);
      final d = result.decodings.single;
      final frames = d.frames;
      expect(frames.length, greaterThanOrEqualTo(3));
      expect(frames[0].name, 'secondLevel');
      expect(frames[0].uri, 'file:///private/tmp/symfix/crash.dart');
      expect(frames[0].line, 10);
      expect(frames[0].resolved, isTrue);
      final json = d.toJson();
      expect(json['symbols'], 'app.macos.symbols');
      expect(json['buildIdMatches'], isTrue);
      expect((json['frames'] as List).length, frames.length);
      final rj = result.toJson();
      expect((rj['decodings'] as List).single, json);
    });
  });

  group('applySourceContext', () {
    test('renders context lines around a decoded file:line', () {
      final src = File('${Directory.systemTemp.path}/ctx_${DateTime.now().microsecondsSinceEpoch}.dart')
        ..writeAsStringSync(List.generate(9, (i) => 'line ${i + 1}').join('\n'));
      addTearDown(src.deleteSync);
      final out = '#0      foo (file://${src.path}:5:3)';
      final rendered = applySourceContext(out);
      expect(rendered, contains('>    5 | line 5'));
      expect(rendered, contains('     4 | line 4'));
      expect(rendered, contains('     6 | line 6'));
    });

    test('missing files and non-file URIs pass through untouched', () {
      const out = '#0      foo (file:///nope/x.dart:5:3)\n#1      bar (dart:core/x.dart)';
      expect(applySourceContext(out), out);
    });
  });

  group('PDB detection', () {
    test('.pdb file fails with a clear message', () {
      final pdb = File('${Directory.systemTemp.path}/app.windows-x64.pdb')..writeAsBytesSync([0]);
      addTearDown(pdb.deleteSync);
      expect(
        () => SymbolsFile(pdb.path).symbolize(trace),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('CodeView'))),
      );
    });
  });

  group('RemoteSymbolStore', () {
    test('fetch downloads files and writes a usable manifest', () async {
      final tmp = Directory.systemTemp.createTempSync('symbolize_remote');
      addTearDown(() => tmp.deleteSync(recursive: true));

      // Serve <base>/index.json + <base>/<version>/<file> from a real server.
      final remoteDir = Directory('${tmp.path}/remote')..createSync();
      final versionDir = Directory('${remoteDir.path}/9.9.9')..createSync();
      File('test/fixtures/app.macos.symbols').copySync('${versionDir.path}/app.macos.symbols');
      File('test/fixtures/app.macos.map.json').copySync('${versionDir.path}/app.macos.map.json');
      File('${remoteDir.path}/index.json').writeAsStringSync(jsonEncode({
        'b4485c2ed97b61f597e466d02a0568ce': {
          'version': '9.9.9',
          'files': ['app.macos.symbols', 'app.macos.map.json'],
        },
      }));

      final server = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(server.close);
      server.listen((req) async {
        final rel = req.uri.path.substring(1); // strip leading /
        final f = File('${remoteDir.path}/$rel');
        req.response.statusCode = f.existsSync() && rel.isNotEmpty ? 200 : 404;
        if (req.response.statusCode == 200) await f.openRead().pipe(req.response);
        await req.response.close();
      });

      final archive = SymbolArchive(Directory('${tmp.path}/symbols'));
      final store = RemoteSymbolStore('http://127.0.0.1:${server.port}');
      final hit = await store.fetch('b4485c2ed97b61f597e466d02a0568ce', archive);
      expect(hit?.version, '9.9.9');
      expect(File('${hit!.dir.path}/app.macos.symbols').existsSync(), isTrue);
      // The written manifest feeds buildIdIndex — a decode can now resolve.
      expect((await archive.buildIdIndex())['b4485c2ed97b61f597e466d02a0568ce'], '9.9.9');
      final result = await symbolize(trace, symbolsDir: archive.symbolsDir, version: '9.9.9');
      expect(result.decodings.single.output, contains('secondLevel'));

      // Unknown build ids and unreachable stores return null, not crashes.
      expect(await store.fetch('deadbeef', archive), isNull);
      expect(await RemoteSymbolStore('http://127.0.0.1:1').fetch('x', archive), isNull);
    });

    test('writeIndexFile produces the remote-store layout', () async {
      final tmp = Directory.systemTemp.createTempSync('symbolize_index');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final from = Directory('${tmp.path}/from')..createSync();
      File('test/fixtures/app.macos.symbols').copySync('${from.path}/app.macos.symbols');
      final archive = SymbolArchive(Directory('${tmp.path}/symbols'));
      archive.store(version: '1.0.0', from: from);
      final index = jsonDecode((await archive.writeIndexFile()).readAsStringSync());
      expect(index['b4485c2ed97b61f597e466d02a0568ce']['version'], '1.0.0');
      expect(index['b4485c2ed97b61f597e466d02a0568ce']['files'], contains('app.macos.symbols'));
    });
  });
}
