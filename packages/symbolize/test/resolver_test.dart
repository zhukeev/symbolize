import 'package:symbolize/symbolize.dart';
import 'package:test/test.dart';

void main() {
  final one = SymbolsFile('test/fixtures/app.macos.symbols');
  final two = SymbolsFile('test/fixtures/app2.macos.symbols');

  group('buildId matching', () {
    test('picks the file whose buildId equals the trace header', () async {
      // Both files are named *.macos.symbols — the filename alone cannot
      // disambiguate; only the embedded build id can.
      final pick = await selectSymbols([one, two], const TraceInfo(buildId: 'b4485c2ed97b61f597e466d02a0568ce'));
      expect(pick.single, same(one));
      final pick2 = await selectSymbols([one, two], const TraceInfo(buildId: 'B4485C2EB346A69097E466D0B6070D2C'));
      expect(pick2.single, same(two));
    });

    test('falls through to filename matching when buildId is unknown', () async {
      final pick = await selectSymbols(
        [SymbolsFile('app.android-arm.symbols'), SymbolsFile('app.android-arm64.symbols')],
        const TraceInfo(buildId: 'deadbeef', os: 'android', arch: 'arm64'),
      );
      expect(pick.single.name, 'app.android-arm64.symbols');
    });
  });

  group('filename narrowing', () {
    test('os then arch, arch aliases applied', () async {
      final files = [
        SymbolsFile('app.android-arm.symbols'),
        SymbolsFile('app.android-arm64.symbols'),
        SymbolsFile('app.ios.symbols'),
      ];
      final android = await selectSymbols(files, const TraceInfo(os: 'android'));
      expect(android.map((f) => f.name), containsAll(['app.android-arm.symbols', 'app.android-arm64.symbols']));
      final arm64 = await selectSymbols(files, const TraceInfo(os: 'android', arch: 'arm64'));
      expect(arm64.single.name, 'app.android-arm64.symbols');
      final ios = await selectSymbols(files, const TraceInfo(os: 'ios', arch: 'arm64'));
      expect(ios.single.name, 'app.ios.symbols');
      // ia32 maps to the x86 filename.
      final x86 = await selectSymbols(
        [SymbolsFile('app.android-x86.symbols'), SymbolsFile('app.android-arm.symbols')],
        const TraceInfo(os: 'android', arch: 'ia32'),
      );
      expect(x86.single.name, 'app.android-x86.symbols');
    });

    test('unknown header fields leave the whole pool', () async {
      final files = [SymbolsFile('app.android-arm.symbols'), SymbolsFile('app.android-arm64.symbols')];
      expect((await selectSymbols(files, const TraceInfo())).length, 2);
      expect((await selectSymbols(files, const TraceInfo(os: 'windows'))).length, 2);
    });

    test('pools of zero or one pass through', () async {
      expect(await selectSymbols([], const TraceInfo()), isEmpty);
      expect((await selectSymbols([one], const TraceInfo(os: 'ios'))).single, same(one));
    });
  });
}
