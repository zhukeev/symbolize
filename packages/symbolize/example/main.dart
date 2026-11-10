import 'package:symbolize/symbolize.dart';

/// Decodes an obfuscated trace two ways: against an explicit symbols file,
/// and against a versioned archive.
Future<void> main() async {
  const trace = '''
*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
os: android arch: arm64 comp: yes sim: no
build_id: 'b4485c2ed97b61f597e466d02a0568ce'
isolate_instructions: 7f1000, vm_instructions: 7f0800
    #00 abs 00000000007f2042 _kDartIsolateSnapshotInstructions+0x1042
''';

  // 1. Explicit file.
  final result = await symbolize(
    trace,
    symbols: SymbolsFile('build/symbols/app.android-arm64.symbols'),
  );
  print(result.decodings.single.output);

  // 2. Versioned archive (created by `symbolize archive` after each release
  //    build). The right file is picked by the trace's buildId/os/arch.
  final project = findProjectRoot();
  final archived = await symbolize(
    trace,
    symbolsDir: SymbolArchive.at(project).symbolsDir,
    version: pubspecVersion(project),
  );
  for (final d in archived.decodings) {
    print('--- decoded with ${d.symbols.name} (resolved: ${d.resolved}) ---');
    print(d.output);
  }
}
