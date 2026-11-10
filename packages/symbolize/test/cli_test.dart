import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Exercises the real `bin/symbolize.dart` entrypoint — the library tests
/// cover decode internals, but the CLI's option plumbing (esp. the
/// bare-stdin path that shares top-level ArgResults) only breaks here.
///
/// Regression: top-level `--version` is a bool flag while decode's
/// `--version <ver>` is a String — piping a trace without the `decode`
/// subcommand used to crash on `bool is not a subtype of String?`.
void main() {
  final bin = File('bin/symbolize.dart').absolute.path;
  final fixture = p.join('test', 'fixtures');

  Future<ProcessResult> run(List<String> args, {String? stdin_, String? cwd}) async {
    final proc = await Process.start(
      Platform.resolvedExecutable,
      ['run', bin, ...args],
      workingDirectory: cwd ?? Directory.current.path,
    );
    if (stdin_ != null) proc.stdin.write(stdin_);
    await proc.stdin.close();
    final out = await proc.stdout.transform(utf8.decoder).join();
    final err = await proc.stderr.transform(utf8.decoder).join();
    return ProcessResult(proc.pid, await proc.exitCode, out, err);
  }

  test('bare-stdin decode auto-matches archive by build_id', () async {
    final dir = await Directory.systemTemp.createTemp('cli_test');
    addTearDown(() => dir.delete(recursive: true));
    Directory(p.join(dir.path, 'build', 'symbols')).createSync(recursive: true);
    for (final f in ['app.macos.symbols', 'app2.macos.symbols', 'app.macos.map.json']) {
      File(p.join(fixture, f)).copySync(p.join(dir.path, 'build', 'symbols', f));
    }
    File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('name: t\nversion: 1.4.0+21\n');

    final arch = await run(['archive'], cwd: dir.path);
    expect(arch.exitCode, 0, reason: arch.stderr as String);

    // The headline flow: `pbpaste | symbolize` — no subcommand at all.
    final trace = File(p.join(fixture, 'trace.txt')).readAsStringSync();
    final res = await run([], stdin_: trace, cwd: dir.path);
    expect(res.exitCode, 0, reason: res.stderr as String);
    expect(res.stdout as String, contains('secondLevel'));
    expect(res.stdout as String, contains('thirdLevel'));
  });

  test('--version prints the package version', () async {
    final res = await run(['--version']);
    expect(res.exitCode, 0, reason: res.stderr as String);
    expect((res.stdout as String).trim(), matches(RegExp(r'^symbolize \d+\.\d+\.\d+')));
  });
}
