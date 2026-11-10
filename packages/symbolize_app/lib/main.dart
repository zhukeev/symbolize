import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mcp_toolkit/mcp_toolkit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:symbolize/symbolize.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Debug-only: register the MCP toolkit service extension + Flutter entries
  // (screenshot/tap/snapshot tools for fmtk and the MCP server).
  if (kDebugMode) {
    MCPToolkitBinding.instance
      ..initialize()
      ..initializeFlutterToolkit();
  }
  runApp(const SymbolizeApp());
}

class SymbolizeApp extends StatelessWidget {
  const SymbolizeApp({super.key});

  /// How decoding is dispatched — a worker isolate in production
  /// (DWARF parsing is CPU-heavy). Tests replace this with
  /// [decodeTraceReport] to run inline, since a real isolate's future
  /// can't be awaited inside the fake-async test zone.
  @visibleForTesting
  static Future<Map<String, Object?>> Function(Map<String, Object?>) decodeRunner =
      (args) => compute(decodeTraceReport, args);

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Symbolize',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: Colors.teal, brightness: Brightness.light, useMaterial3: true),
        darkTheme: ThemeData(colorSchemeSeed: Colors.teal, brightness: Brightness.dark, useMaterial3: true),
        home: const SymbolizeHome(),
      );
}

class SymbolizeHome extends StatefulWidget {
  const SymbolizeHome({super.key});

  @override
  State<SymbolizeHome> createState() => _SymbolizeHomeState();
}

enum _SourceMode { archive, file }

/// The decode work unit — produces a report of only sendable data
/// (`SymbolsFile` holds a parsed [Dwarf] after decoding, which can't cross
/// an isolate boundary, so the report is plain maps/lists/strings). Safe to
/// run inside `compute`; tests run it inline via [SymbolizeApp.decodeRunner].
Future<Map<String, Object?>> decodeTraceReport(Map<String, Object?> args) async {
  try {
    final results = await symbolizeAll(
      args['trace'] as String,
      symbols: args['symbolsFile'] == null ? null : SymbolsFile(args['symbolsFile'] as String),
      symbolsDir: Directory(args['symbolsDir'] as String),
      version: args['version'] as String?,
      includeInternalFrames: args['internalFrames'] as bool,
    );
    return {
      'traces': [
        for (final r in results)
          {
            'warnings': r.warnings,
            'decodings': [
              for (final d in r.decodings)
                {
                  'name': d.symbols.name,
                  'output': d.output,
                  'resolved': d.resolved,
                  'namesRestored': d.namesRestored,
                },
            ],
          },
      ],
    };
  } on StateError catch (e) {
    return {'error': e.message};
  }
}

class _SymbolizeHomeState extends State<SymbolizeHome> {
  final _trace = TextEditingController();
  final _symbolsDir = TextEditingController();
  final _explicitFile = TextEditingController();
  _SourceMode _mode = _SourceMode.archive;
  List<ArchivedVersion> _versions = [];
  String? _version;
  bool _internalFrames = true;
  bool _busy = false;
  String _status = '';
  String _output = '';

  @override
  void initState() {
    super.initState();
    // Prefill with <cwd>/symbols when the app happens to launch inside a
    // project; the picker is the normal path.
    final guess = findProjectRoot();
    final symbols = SymbolArchive.at(guess).symbolsDir.path;
    _symbolsDir.text = symbols;
    _restore().whenComplete(_reloadVersions);
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _symbolsDir.text = prefs.getString('symbolsDir') ?? _symbolsDir.text;
      _explicitFile.text = prefs.getString('symbolsFile') ?? '';
      _internalFrames = prefs.getBool('internalFrames') ?? _internalFrames;
      _mode = _SourceMode.values[prefs.getInt('mode') ?? _mode.index];
    });
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('symbolsDir', _symbolsDir.text);
    await prefs.setString('symbolsFile', _explicitFile.text);
    await prefs.setBool('internalFrames', _internalFrames);
    await prefs.setInt('mode', _mode.index);
  }

  @override
  void dispose() {
    _trace.dispose();
    _symbolsDir.dispose();
    _explicitFile.dispose();
    super.dispose();
  }

  void _reloadVersions() {
    setState(() {
      _versions = SymbolArchive(Directory(_symbolsDir.text)).versions();
      if (_version != null && !_versions.any((v) => v.version == _version)) _version = null;
      _version ??= _versions.isEmpty ? null : _versions.last.version;
    });
  }

  Future<void> _pickDir() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Choose symbols directory');
    if (dir == null) return;
    _symbolsDir.text = dir;
    _persist();
    _reloadVersions();
  }

  Future<void> _pickSymbols() async {
    final res = await FilePicker.pickFiles(
      dialogTitle: 'Choose .symbols file',
      type: FileType.custom,
      allowedExtensions: ['symbols'],
    );
    final path = res?.files.single.path;
    if (path != null) {
      _explicitFile.text = path;
      _persist();
    }
  }

  Future<void> _decode() async {
    final trace = _trace.text;
    if (trace.trim().isEmpty) {
      setState(() => _status = 'Paste an obfuscated stack trace first.');
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Decoding…';
      _output = '';
    });
    _persist();
    // DWARF parsing + decoding can take a while on large symbols files —
    // keep it off the UI isolate. The closure may only capture sendable
    // values, so the inputs are copied into a plain map first.
    final args = <String, Object?>{
      'trace': trace,
      'symbolsFile': _mode == _SourceMode.file ? _explicitFile.text : null,
      'symbolsDir': _symbolsDir.text,
      'version': _version,
      'internalFrames': _internalFrames,
    };
    final report = await SymbolizeApp.decodeRunner(args);
    try {
      final error = report['error'];
      if (error is String) {
        setState(() => _status = error);
        return;
      }
      final traces = report['traces'] as List;
      final buffer = StringBuffer();
      final status = <String>[];
      for (var i = 0; i < traces.length; i++) {
        final result = traces[i] as Map;
        for (final w in result['warnings'] as List) {
          status.add('warning: $w');
        }
        if (traces.length > 1) buffer.writeln('===== trace ${i + 1}/${traces.length} =====\n');
        for (final d in result['decodings'] as List) {
          final decoding = d as Map;
          final name = decoding['name'] as String;
          final output = decoding['output'] as String;
          if ((result['decodings'] as List).length > 1) buffer.writeln('===== $name =====\n');
          buffer.write(output.endsWith('\n') ? output : '$output\n');
          final restored = decoding['namesRestored'] as int;
          status.add('$name — ${decoding['resolved'] == true ? 'resolved' : 'no frames resolved (wrong build?)'}'
              '${restored > 0 ? ', $restored names via .map.json' : ''}');
        }
      }
      setState(() {
        _output = buffer.toString();
        _status = status.join('\n');
      });
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _saveOutput() async {
    final path = await FilePicker.saveFile(dialogTitle: 'Save decoded trace', fileName: 'decoded_trace.txt');
    if (path != null) await File(path).writeAsString(_output);
  }

  @override
  Widget build(BuildContext context) {
    final mono = TextStyle(fontFamily: 'Menlo', fontSize: 12, color: Theme.of(context).colorScheme.onSurface);
    return Scaffold(
      appBar: AppBar(title: const Text('Symbolize'), actions: [
        if (_output.isNotEmpty)
          IconButton(tooltip: 'Copy output', icon: const Icon(Icons.copy), onPressed: () => Clipboard.setData(ClipboardData(text: _output))),
        if (_output.isNotEmpty) IconButton(tooltip: 'Save output…', icon: const Icon(Icons.save), onPressed: _saveOutput),
      ]),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<_SourceMode>(
              segments: const [
                ButtonSegment(value: _SourceMode.archive, label: Text('Archived version'), icon: Icon(Icons.inventory_2_outlined)),
                ButtonSegment(value: _SourceMode.file, label: Text('.symbols file'), icon: Icon(Icons.insert_drive_file_outlined)),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() {
                _mode = s.first;
                _persist();
              }),
            ),
            const SizedBox(height: 12),
            if (_mode == _SourceMode.archive)
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _symbolsDir,
                    decoration: const InputDecoration(labelText: 'Symbols directory', hintText: '<project>/symbols', border: OutlineInputBorder(), isDense: true),
                    onSubmitted: (_) => _reloadVersions(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(tooltip: 'Browse…', icon: const Icon(Icons.folder_open), onPressed: _pickDir),
                const SizedBox(width: 16),
                DropdownMenu<String>(
                  label: const Text('Version'),
                  initialSelection: _version,
                  dropdownMenuEntries: [for (final v in _versions) DropdownMenuEntry(value: v.version, label: v.version)],
                  onSelected: (v) => setState(() => _version = v),
                ),
              ])
            else
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _explicitFile,
                    decoration: const InputDecoration(labelText: 'Symbols file', hintText: 'app.android-arm64.symbols', border: OutlineInputBorder(), isDense: true),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(tooltip: 'Browse…', icon: const Icon(Icons.file_open), onPressed: _pickSymbols),
              ]),
            const SizedBox(height: 12),
            Expanded(
              flex: 2,
              child: TextField(
                controller: _trace,
                expands: true,
                maxLines: null,
                textAlignVertical: TextAlignVertical.top,
                style: mono,
                decoration: const InputDecoration(
                  labelText: 'Obfuscated stack trace',
                  alignLabelWithHint: true,
                  hintText: 'Paste the Crashlytics/console trace here…',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              FilledButton.icon(
                onPressed: _busy ? null : _decode,
                icon: const Icon(Icons.auto_fix_high),
                label: Text(_busy ? 'Decoding…' : 'Symbolize'),
              ),
              const SizedBox(width: 16),
              Checkbox(value: _internalFrames, onChanged: (v) => setState(() => _internalFrames = v ?? true)),
              const Text('Include VM-internal frames'),
            ]),
            if (_status.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_status, style: mono.copyWith(fontSize: 11))),
            const SizedBox(height: 8),
            Expanded(
              flex: 3,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor),
                  borderRadius: BorderRadius.circular(4),
                ),
                padding: const EdgeInsets.all(8),
                child: SingleChildScrollView(child: SelectableText(_output, style: mono)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
