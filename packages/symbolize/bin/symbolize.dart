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
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:symbolize/symbolize.dart';

const _commands = {'decode', 'archive', 'list'};
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
  ..addCommand('list', _projectOpts(ArgParser()));

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
  ..addFlag('internal-frames', defaultsTo: true, help: 'Keep VM-internal frames in the output.');

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
    ..writeln('  list     Show archived symbol versions.');
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
  if (explicit == null && version == null) {
    throw StateError('no --version given and no version: in ${p.join(project.path, 'pubspec.yaml')}');
  }
  // UX warning: decode is about to silently use the build/symbols fallback.
  if (explicit == null &&
      version != null &&
      SymbolArchive(symbolsDir).files(version).isEmpty &&
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
  ).catchError((Object e) {
    if (e is StateError && version != null && SymbolArchive(symbolsDir).versions().isNotEmpty) {
      final known = SymbolArchive(symbolsDir).versions().map((v) => v.version).join(', ');
      throw StateError('${e.message}\narchived versions: $known');
    }
    throw e;
  });

  final outPath = _opt(a, 'output');
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

// ---- helpers ----------------------------------------------------------

/// Reads an option only when it was defined for this parser level — the
/// bare-stdin decode path runs with top-level results that lack the decode
/// command's options.
String? _opt(ArgResults a, String name) => a.options.contains(name) ? a[name] as String? : null;

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
