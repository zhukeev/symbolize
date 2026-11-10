// Command-line interface for package:symbolize.
//
//   symbolize decode -i trace.txt                    # decode a saved trace
//   pbpaste | symbolize decode                       # trace from stdin
//   symbolize decode -i t.txt --version 1.4.0+21     # pick archived symbols
//   symbolize decode -i t.txt -d app.ios.symbols     # explicit symbols file
//   symbolize archive                                # stash build/symbols -> symbols/<version>/
//   symbolize list                                   # show archived versions
//
// With no subcommand and data on stdin, `symbolize` decodes.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:symbolize/symbolize.dart';

const _commands = {'decode', 'archive', 'list', 'watch', 'upload', 'fetch'};
const _topFlags = {'-h', '--help', '--version'};

void main(List<String> args) async {
  final parser = _parser();
  try {
    // `symbolize -i t.txt -d f.symbols` (no subcommand) means decode — as
    // does `cat t.txt | symbolize` and `symbolize` alone on a TTY (help).
    if (args.isNotEmpty && !_commands.contains(args.first) && !_topFlags.contains(args.first)) {
      return await _decode(_decodeOpts().parse(args));
    }
    final results = parser.parse(args);
    if (results['help'] as bool) return _printUsage(parser);
    if (results['version'] as bool) return stdout.writeln('symbolize $symbolizeVersion');
    switch (results.command?.name) {
      case 'decode':
        await _decode(results.command!);
      case 'archive':
        await _archive(results.command!);
      case 'list':
        _list(results.command!);
      case 'watch':
        await _watch(results.command!);
      case 'upload':
        await _upload(results.command!);
      case 'fetch':
        await _fetch(results.command!);
      case null:
        // No subcommand: decode when stdin is piped, otherwise show help.
        if (stdin.hasTerminal) return _printUsage(parser);
        await _decode(results);
      default:
        stderr.writeln('unknown command ${results.command!.name}');
        exit(64);
    }
  } on FormatException catch (e) {
    stderr.writeln('${e.message}\n');
    _printUsage(parser);
    exit(64);
  } on StateError catch (e) {
    stderr.writeln('error: ${e.message}');
    exit(1);
  } on PathNotFoundException catch (e) {
    stderr.writeln('error: ${e.message}');
    exit(1);
  }
}

ArgParser _parser() => ArgParser()
  ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.')
  ..addFlag('version', negatable: false, help: 'Print the symbolize version.')
  ..addCommand('decode', _decodeOpts())
  ..addCommand('archive', _projectOpts(ArgParser())
    ..addOption('from', help: 'split-debug-info dir to archive (default: <project>/build/symbols).')
    ..addOption('version', abbr: 'v', help: 'Version label (default: pubspec.yaml version).'))
  ..addCommand('list', _projectOpts(ArgParser()))
  ..addCommand('watch', _projectOpts(ArgParser())
    ..addOption('from', help: 'split-debug-info dir to watch (default: <project>/build/symbols).')
    ..addOption('version', abbr: 'v', help: 'Version label (default: pubspec.yaml version).'))
  ..addCommand('upload', _projectOpts(ArgParser())
    ..addOption('provider', abbr: 'p', help: 'crashlytics | sentry.', mandatory: true)
    ..addOption('version', abbr: 'v', help: 'Archived version to upload (default: latest archived).')
    ..addOption('app', help: 'Firebase app id (default: android/app/google-services.json).')
    ..addOption('map', help: '.map.json to also upload (sentry: requires --debug-id).')
    ..addOption('debug-id', help: 'Sentry debug-id for --map.'))
  ..addCommand('fetch', _projectOpts(ArgParser())
    ..addOption('base', abbr: 'b', help: 'Remote store base URL.', mandatory: true)
    ..addOption('build-id', help: 'build_id to fetch (default: read it from the trace on stdin).'));

ArgParser _projectOpts(ArgParser p) => p
  ..addOption('project-dir', help: 'Project root (default: nearest pubspec.yaml upwards).')
  ..addOption('symbols-dir', help: 'Symbol archive dir (default: <project>/symbols).');

ArgParser _decodeOpts() => _projectOpts(ArgParser())
  ..addOption('input', abbr: 'i', help: 'Stack trace file (default: stdin).')
  ..addOption('symbols', abbr: 'd', help: 'Explicit .symbols file — bypasses archive lookup.')
  ..addOption('map', abbr: 'm', help: 'Explicit .map.json obfuscation map (default: sibling of the .symbols file).')
  ..addOption('version', abbr: 'v', help: 'App version to decode against (default: pubspec.yaml version).')
  ..addOption('os', help: 'Override os: from the trace header.')
  ..addOption('arch', help: 'Override arch: from the trace header.')
  ..addOption('output', abbr: 'o', help: 'Write the decoded trace here (default: stdout).')
  ..addOption('build-dir', help: 'split-debug-info dir fallback (default: <project>/build/symbols).')
  ..addOption('remote', abbr: 'r', help: 'Remote symbol store URL — fetch a missing build_id automatically.')
  ..addFlag('internal-frames', defaultsTo: true, help: 'Keep VM-internal frames in the output.')
  ..addFlag('source', abbr: 's', negatable: false, help: 'Append source lines under decoded frames.')
  ..addFlag('json', negatable: false, help: 'Emit a machine-readable JSON report.');

void _printUsage(ArgParser parser) {
  stdout
    ..writeln('Deobfuscate Dart/Flutter release stack traces.')
    ..writeln('')
    ..writeln('Usage: symbolize <command> [options]   (no command + piped stdin = decode)')
    ..writeln('')
    ..writeln(parser.usage)
    ..writeln('')
    ..writeln('Commands:')
    ..writeln('  decode   Symbolize an obfuscated stack trace.')
    ..writeln('  archive  Stash build/symbols into symbols/<version>/ for later decoding.')
    ..writeln('  list     Show archived symbol versions.')
    ..writeln('  watch    Auto-archive whenever build/symbols changes.')
    ..writeln('  upload   Push an archived version to Crashlytics/Sentry.')
    ..writeln('  fetch    Download symbols for a build_id from a remote store.');
}

// ---- decode -----------------------------------------------------------

Future<void> _decode(ArgResults a) async {
  final project = findProjectRoot(_opt(a, 'project-dir') != null ? Directory(_opt(a, 'project-dir')!) : null);
  final trace = await _readTrace(_opt(a, 'input'));

  SymbolsFile? explicit;
  if (_opt(a, 'symbols') != null) {
    explicit = SymbolsFile(_opt(a, 'symbols')!);
    if (explicit.dwarf == null) throw StateError('${explicit.path} is not a valid .symbols file');
  }

  ObfuscationMap? map;
  if (_opt(a, 'map') != null) map = ObfuscationMap.fromFile(_opt(a, 'map')!);

  final symbolsDir = Directory(_opt(a, 'symbols-dir') ?? p.join(project.path, 'symbols'));
  final buildDir = Directory(_opt(a, 'build-dir') ?? p.join(project.path, 'build', 'symbols'));

  String? version = _opt(a, 'version') ?? pubspecVersion(project);

  // Remote store: the trace's build_id isn't archived locally → pull it.
  final remote = _opt(a, 'remote');
  final archive = SymbolArchive(symbolsDir);
  if (remote != null && explicit == null) {
    final buildId = TraceInfo.parse(trace).buildId;
    if (buildId != null && (version == null || archive.files(version).isEmpty)) {
      final fetched = await RemoteSymbolStore(remote).fetch(buildId, archive);
      if (fetched != null) {
        stderr.writeln('fetched ${fetched.version} for build_id $buildId');
        version = fetched.version;
      }
    }
  }

  if (explicit == null && version == null) {
    throw StateError('no --version given and no version: in ${p.join(project.path, 'pubspec.yaml')}');
  }
  // UX warning: decode is about to silently use the build/symbols fallback.
  if (explicit == null &&
      version != null &&
      archive.files(version).isEmpty &&
      _symbolFiles(buildDir).isNotEmpty) {
    stderr.writeln('warning: no archive for $version — falling back to ${buildDir.path} (may be a different build)');
  }

  final results = await symbolizeAll(
    trace,
    symbols: explicit,
    symbolsDir: symbolsDir,
    version: version,
    buildSymbolsDir: buildDir,
    obfuscationMap: map,
    os: _opt(a, 'os'),
    arch: _opt(a, 'arch'),
    includeInternalFrames: _flag(a, 'internal-frames', or: true),
    showSource: _flag(a, 'source'),
  ).catchError((Object e) {
    if (e is StateError && version != null && SymbolArchive(symbolsDir).versions().isNotEmpty) {
      final known = SymbolArchive(symbolsDir).versions().map((v) => v.version).join(', ');
      throw StateError('${e.message}\narchived versions: $known');
    }
    throw e;
  });

  final outPath = _opt(a, 'output');
  if (_flag(a, 'json')) {
    final encoded = const JsonEncoder.withIndent('  ')
        .convert({'traces': [for (final r in results) r.toJson()]});
    if (outPath == null) {
      stdout.writeln(encoded);
    } else {
      File(outPath).writeAsStringSync('$encoded\n');
      stdout.writeln('written to $outPath');
    }
    return;
  }
  final buffer = StringBuffer();
  var anyUnresolved = false;
  for (var i = 0; i < results.length; i++) {
    final result = results[i];
    if (results.length > 1) {
      stderr.writeln('── trace ${i + 1}/${results.length} ──');
      buffer.writeln('===== trace ${i + 1}/${results.length} =====');
    }
    for (final w in result.warnings) {
      stderr.writeln('warning: $w');
    }
    for (final d in result.decodings) {
      if (result.decodings.length > 1) {
        stderr.writeln('── ${d.symbols.name} ──');
        buffer.writeln('===== ${d.symbols.name} =====');
      }
      if (d.namesRestored > 0) {
        stderr.writeln('${d.symbols.name}: restored ${d.namesRestored} obfuscated names via .map.json');
      }
      if (outPath == null) {
        stdout.write(d.output.endsWith('\n') ? d.output : '${d.output}\n');
      } else {
        buffer.write(d.output.endsWith('\n') ? d.output : '${d.output}\n');
      }
    }
    if (result.resolved.isEmpty) anyUnresolved = true;
  }
  if (anyUnresolved) {
    stderr.writeln('warning: no frames resolved — the symbols file likely does not match this build');
  }
  if (outPath != null) {
    File(outPath).writeAsStringSync(buffer.toString());
    stdout.writeln('written to $outPath');
  }
}

// ---- archive ----------------------------------------------------------

Future<void> _archive(ArgResults a) async {
  final project = findProjectRoot(_opt(a, 'project-dir') != null ? Directory(_opt(a, 'project-dir')!) : null);
  final version = _opt(a, 'version') ??
      pubspecVersion(project) ??
      (throw StateError('no --version given and no version: in ${p.join(project.path, 'pubspec.yaml')}'));
  final from = Directory(_opt(a, 'from') ?? p.join(project.path, 'build', 'symbols'));
  final symbolsDir = Directory(_opt(a, 'symbols-dir') ?? p.join(project.path, 'symbols'));

  final entry = SymbolArchive(symbolsDir).store(
    version: version,
    from: from,
    meta: {
      'tool': 'symbolize $symbolizeVersion',
      'gitSha': await _git(project, ['rev-parse', '--short', 'HEAD']),
      'gitDirty': (await _git(project, ['status', '--porcelain']))?.isNotEmpty,
    },
  );

  stdout.writeln('archived -> ${entry.dir.path}');
  for (final f in (entry.manifest?['files'] as List? ?? const [])) {
    final file = f as Map;
    stdout.writeln('  ${file['name']}${file['buildId'] != null ? '  buildId ${file['buildId']}' : ''}');
  }
  await SymbolArchive(symbolsDir).writeIndexFile();
}

// ---- list -------------------------------------------------------------

void _list(ArgResults a) {
  final project = findProjectRoot(_opt(a, 'project-dir') != null ? Directory(_opt(a, 'project-dir')!) : null);
  final symbolsDir = Directory(_opt(a, 'symbols-dir') ?? p.join(project.path, 'symbols'));
  final versions = SymbolArchive(symbolsDir).versions();
  if (versions.isEmpty) {
    stdout.writeln('no archived symbols in ${symbolsDir.path} — run `symbolize archive` after a release build');
    return;
  }
  for (final v in versions) {
    final m = v.manifest ?? const {};
    final meta = [
      if (m['archivedAt'] != null) m['archivedAt'],
      if (m['gitSha'] != null) 'git ${m['gitSha']}${m['gitDirty'] == true ? ' dirty' : ''}',
    ].join(', ');
    stdout.writeln('${v.version}${meta.isEmpty ? '' : '  ($meta)'}');
    for (final f in (m['files'] as List? ?? const [])) {
      final file = f as Map;
      stdout.writeln('  ${file['name']}  ${((file['bytes'] as int? ?? 0) / 1024).toStringAsFixed(0)} KiB'
          '${file['buildId'] != null ? '  buildId ${file['buildId']}' : ''}');
    }
  }
}

// ---- watch ------------------------------------------------------------

/// Long-running: archives `build/symbols` into `symbols/<version>/` on
/// startup and again whenever files change (debounced — a build writes
/// several). Ctrl-C to stop.
Future<void> _watch(ArgResults a) async {
  final project = findProjectRoot(_opt(a, 'project-dir') != null ? Directory(_opt(a, 'project-dir')!) : null);
  final version = _opt(a, 'version') ??
      pubspecVersion(project) ??
      (throw StateError('no --version given and no version: in ${p.join(project.path, 'pubspec.yaml')}'));
  final from = Directory(_opt(a, 'from') ?? p.join(project.path, 'build', 'symbols'))..createSync(recursive: true);
  final symbolsDir = Directory(_opt(a, 'symbols-dir') ?? p.join(project.path, 'symbols'));
  final archive = SymbolArchive(symbolsDir);

  Future<void> stash() async {
    try {
      final entry = archive.store(version: version, from: from, meta: {'via': 'watch'});
      stdout.writeln('[watch] archived → symbols/$version (${entry.files.length} files)');
      await archive.writeIndexFile();
    } on StateError {
      // Nothing to archive yet — the build hasn't written symbols.
    }
  }

  if (_symbolFiles(from).isNotEmpty) await stash();
  stdout.writeln('[watch] watching ${from.path} for $version — Ctrl-C to stop');

  Timer? debounce;
  final sub = from.watch().listen((event) {
    if (!event.path.endsWith('.symbols') && !event.path.endsWith('.map.json')) return;
    debounce?.cancel();
    debounce = Timer(const Duration(seconds: 2), stash);
  });
  await ProcessSignal.sigint.watch().first;
  debounce?.cancel();
  await sub.cancel();
  stdout.writeln('[watch] stopped');
}

// ---- upload -----------------------------------------------------------

/// Pushes an archived version's symbols to a crash-reporting provider.
/// The local archive stays the source of truth; the provider just gets a
/// copy so crashes decode server-side too.
Future<void> _upload(ArgResults a) async {
  final project = findProjectRoot(_opt(a, 'project-dir') != null ? Directory(_opt(a, 'project-dir')!) : null);
  final symbolsDir = Directory(_opt(a, 'symbols-dir') ?? p.join(project.path, 'symbols'));
  final archive = SymbolArchive(symbolsDir);

  final version = _opt(a, 'version') ??
      archive.versions().lastOrNull?.version ??
      (throw StateError('no archived versions in ${symbolsDir.path} — run `symbolize archive` first'));
  final dir = archive.versionDir(version);
  if (_symbolFiles(dir).isEmpty) {
    throw StateError('no .symbols files in ${dir.path}');
  }

  switch (_opt(a, 'provider')) {
    case 'crashlytics':
      await _runChecked(
        await _requireTool('firebase', 'npm i -g firebase-tools'),
        ['crashlytics:symbols:upload', '--app', _opt(a, 'app') ?? _firebaseAppId(project) ??
            (throw StateError('no --app given and no google-services.json under ${project.path}')), dir.path],
      );
    case 'sentry':
      final tool = await _requireTool('sentry-cli', 'brew install getsentry/tools/sentry-cli');
      await _runChecked(tool, ['debug-files', 'upload', dir.path]);
      final map = _opt(a, 'map');
      if (map != null) {
        final debugId = _opt(a, 'debug-id') ??
            (throw StateError('--debug-id is required when uploading --map'));
        await _runChecked(tool, ['dart-symbol-map', 'upload', '--debug-id', debugId, map]);
      }
    case final other:
      throw StateError('unknown provider $other — use crashlytics or sentry');
  }
}

Future<String> _requireTool(String name, String installHint) async {
  final found = await _which(name);
  if (found == null) throw StateError('$name not on PATH — install: $installHint');
  return found;
}

Future<String?> _which(String name) async {
  try {
    final res = await Process.run(Platform.isWindows ? 'where' : 'which', [name]);
    return res.exitCode == 0 ? (res.stdout as String).trim().split('\n').first : null;
  } on ProcessException {
    return null;
  }
}

Future<void> _runChecked(String tool, List<String> args) async {
  stdout.writeln('> $tool ${args.join(' ')}');
  final proc = await Process.start(tool, args, mode: ProcessStartMode.inheritStdio);
  final code = await proc.exitCode;
  if (code != 0) throw StateError('$tool exited with code $code');
}

String? _firebaseAppId(Directory project) {
  for (final rel in ['android/app/google-services.json', 'google-services.json']) {
    final f = File(p.join(project.path, rel));
    if (!f.existsSync()) continue;
    try {
      final j = jsonDecode(f.readAsStringSync());
      final client = (j['client'] as List?)?.first as Map?;
      return ((client?['client_info'] as Map?)?['mobilesdk_app_id']) as String?;
    } on FormatException {
      continue;
    }
  }
  return null;
}

// ---- fetch ------------------------------------------------------------

/// Downloads the symbols for one build_id from a remote store into the
/// local archive. `--build-id` can be omitted when a trace is on stdin —
/// it's read from the trace header.
Future<void> _fetch(ArgResults a) async {
  var buildId = _opt(a, 'build-id');
  buildId ??= TraceInfo.parse(await _readTrace(null)).buildId ??
      (throw StateError('no --build-id given and no build_id in the stdin trace'));
  final project = findProjectRoot(_opt(a, 'project-dir') != null ? Directory(_opt(a, 'project-dir')!) : null);
  final symbolsDir = Directory(_opt(a, 'symbols-dir') ?? p.join(project.path, 'symbols'));

  final hit = await RemoteSymbolStore(_opt(a, 'base')!).fetch(buildId, SymbolArchive(symbolsDir));
  if (hit == null) {
    throw StateError('build_id $buildId not in ${_opt(a, 'base')}/index.json');
  }
  stdout.writeln('fetched → ${hit.dir.path}');
  for (final f in hit.files) {
    stdout.writeln('  ${f.name}');
  }
}

// ---- helpers ----------------------------------------------------------

/// Reads an option only when it was defined for this parser level — the
/// bare-stdin decode path runs with top-level results that lack the decode
/// command's options. Also guards against same-named bool flags (top-level
/// `--version` vs decode's `--version <ver>`).
String? _opt(ArgResults a, String name) {
  if (!a.options.contains(name)) return null;
  final v = a[name];
  return v is String ? v : null;
}

bool _flag(ArgResults a, String name, {bool or = false}) => a.options.contains(name) ? a[name] as bool : or;

List<SymbolsFile> _symbolFiles(Directory dir) {
  if (!dir.existsSync()) return [];
  return [for (final f in dir.listSync().whereType<File>()) if (f.path.endsWith('.symbols')) SymbolsFile(f.path)];
}

Future<String> _readTrace(String? inputPath) async {
  final String trace;
  if (inputPath != null) {
    trace = await File(inputPath).readAsString();
  } else {
    if (stdin.hasTerminal) stderr.writeln('paste the obfuscated stack trace, then Ctrl-D:');
    trace = await utf8.decodeStream(stdin);
  }
  if (trace.trim().isEmpty) throw StateError('empty stack trace');
  return trace;
}

Future<String?> _git(Directory root, List<String> args) async {
  try {
    final res = await Process.run('git', args, workingDirectory: root.path);
    return res.exitCode == 0 ? (res.stdout as String).trim() : null;
  } on ProcessException {
    return null;
  }
}
