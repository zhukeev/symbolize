import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mcp_toolkit/mcp_toolkit.dart';
import 'package:path/path.dart' as p;
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

  /// How the archive's buildId index is scanned — a worker isolate in
  /// production for the same reason as [decodeRunner].
  @visibleForTesting
  static Future<Map<String, String>> Function(String) indexRunner =
      (dir) => compute(indexArchive, dir);

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
                  'buildIdMatches': d.buildIdMatches,
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

/// Maps every DWARF `build_id` archived under [dir] to its version —
/// runs in a worker isolate via [SymbolizeApp.indexRunner].
Future<Map<String, String>> indexArchive(String dir) =>
    SymbolArchive(Directory(dir)).buildIdIndex();

class _SymbolizeHomeState extends State<SymbolizeHome> {
  final _trace = TextEditingController();
  final _symbolsDir = TextEditingController();
  final _explicitFile = TextEditingController();
  _SourceMode _mode = _SourceMode.archive;
  List<ArchivedVersion> _versions = [];
  String? _version;
  bool _internalFrames = true;
  bool _busy = false;
  bool _dragging = false;
  String _status = '';
  String _output = '';

  /// build_id → archived version, rebuilt whenever the symbols dir
  /// changes. Lets a pasted trace resolve its own version — the user
  /// never has to pick one.
  Map<String, String> _buildIdIndex = {};

  /// Debounce for paste-detection auto-decode.
  Timer? _autoDecode;

  /// The trace text last decoded — re-pasting the same trace doesn't
  /// re-trigger the auto-decode loop.
  String _lastDecodedTrace = '';

  @override
  void initState() {
    super.initState();
    // Prefill with <cwd>/symbols when the app happens to launch inside a
    // project; the picker is the normal path.
    final guess = findProjectRoot();
    final symbols = SymbolArchive.at(guess).symbolsDir.path;
    _symbolsDir.text = symbols;
    _restore().whenComplete(_reloadVersions);
    // Paste a trace → decode it without touching anything else.
    _trace.addListener(() {
      _autoDecode?.cancel();
      final text = _trace.text;
      if (!detectTrace(text) || text == _lastDecodedTrace) return;
      _autoDecode = Timer(const Duration(milliseconds: 400), () {
        if (!_busy && _trace.text != _lastDecodedTrace) _decode();
      });
    });
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
    _autoDecode?.cancel();
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
    _rescanIndex();
  }

  /// Rebuild the build_id → version index off the UI isolate.
  Future<void> _rescanIndex() async {
    final dir = _symbolsDir.text;
    final index = await SymbolizeApp.indexRunner(dir);
    if (mounted && dir == _symbolsDir.text) setState(() => _buildIdIndex = index);
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
    var trace = _trace.text;
    if (trace.trim().isEmpty) {
      // One tap, zero typing: empty field means "use the clipboard".
      trace = (await Clipboard.getData('text/plain'))?.text ?? '';
      if (!detectTrace(trace)) {
        setState(() => _status = 'Copy a crash trace or paste it here — '
            'clipboard doesn\'t look like one.');
        return;
      }
      _trace.text = trace;
    }
    // Version resolution: the trace's own build_id beats the dropdown —
    // an archived build needs zero selection from the user.
    var version = _version;
    String? autoNote;
    final buildId = TraceInfo.parse(trace).buildId;
    if (_mode == _SourceMode.archive && buildId != null) {
      final hit = _buildIdIndex[buildId];
      if (hit != null) {
        if (hit != version) autoNote = 'auto-matched $hit by build_id';
        version = hit;
      }
    }
    setState(() {
      _busy = true;
      _status = 'Decoding…';
      _output = '';
    });
    _lastDecodedTrace = trace;
    _persist();
    // DWARF parsing + decoding can take a while on large symbols files —
    // keep it off the UI isolate. The closure may only capture sendable
    // values, so the inputs are copied into a plain map first.
    final args = <String, Object?>{
      'trace': trace,
      'symbolsFile': _mode == _SourceMode.file ? _explicitFile.text : null,
      'symbolsDir': _symbolsDir.text,
      'version': version,
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
      final status = <String>[?autoNote];
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
          final idOk = decoding['buildIdMatches'] == true ? ', build_id ✓' : '';
          status.add('$name — ${decoding['resolved'] == true ? 'resolved' : 'no frames resolved (wrong build?)'}'
              '$idOk${restored > 0 ? ', $restored names via .map.json' : ''}');
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

  /// Dropped `.symbols` → explicit-file decode; dropped directory →
  /// archive root; dropped text → pasted and auto-decoded by the
  /// controller listener.
  Future<void> _handleDrop(List<DropItem> files) async {
    setState(() => _dragging = false);
    for (final f in files) {
      final file = File(f.path);
      if (Directory(f.path).existsSync()) {
        _symbolsDir.text = f.path;
        setState(() => _mode = _SourceMode.archive);
        _persist();
        _reloadVersions();
        continue;
      }
      if (f.path.endsWith('.symbols')) {
        _explicitFile.text = f.path;
        setState(() => _mode = _SourceMode.file);
        _persist();
        if (detectTrace(_trace.text)) unawaited(_decode());
        continue;
      }
      final text = await file.readAsString();
      if (detectTrace(text)) {
        _trace.text = text; // listener auto-decodes
      } else {
        setState(() => _status = '${p.basename(f.path)} — not a stack trace, ignored.');
      }
    }
  }

  /// One tap: copy the project's `build/symbols` output into the archive
  /// under the pubspec version, then re-index so the next crash from that
  /// version resolves instantly.
  Future<void> _importBuildSymbols() async {
    // The archive's parent is the project root (conventional layout);
    // fall back to cwd detection.
    final dir = Directory(_symbolsDir.text);
    final root = p.basename(dir.path) == 'symbols' ? dir.parent : findProjectRoot();
    final version = pubspecVersion(root);
    final from = Directory(p.join(root.path, 'build', 'symbols'));
    if (version == null) {
      setState(() => _status = 'no version in ${root.path}/pubspec.yaml');
      return;
    }
    try {
      final v = SymbolArchive(dir).store(version: version, from: from, meta: {'importedAt': DateTime.now().toUtc().toIso8601String()});
      _reloadVersions();
      setState(() {
        _version = v.version;
        _status = 'archived ${from.path} → symbols/$version (${v.files.length} files)';
      });
      _persist();
    } on StateError catch (e) {
      setState(() => _status = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mono = TextStyle(fontFamily: 'Menlo', fontSize: 12, color: Theme.of(context).colorScheme.onSurface);
    return Scaffold(
      appBar: AppBar(title: const Text('Symbolize'), actions: [
        IconButton(tooltip: 'Import build/symbols → archive', icon: const Icon(Icons.archive_outlined), onPressed: _importBuildSymbols),
        if (_output.isNotEmpty)
          IconButton(tooltip: 'Copy output', icon: const Icon(Icons.copy), onPressed: () => Clipboard.setData(ClipboardData(text: _output))),
        if (_output.isNotEmpty) IconButton(tooltip: 'Save output…', icon: const Icon(Icons.save), onPressed: _saveOutput),
      ]),
      body: DropTarget(
        onDragDone: (d) => _handleDrop(d.files),
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        child: Stack(children: [
          Padding(
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
                decoration: InputDecoration(
                  labelText: 'Obfuscated stack trace',
                  alignLabelWithHint: true,
                  hintText: 'Paste the Crashlytics/console trace here — or drop it on the window',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: 'Paste from clipboard',
                    icon: const Icon(Icons.paste_outlined, size: 18),
                    onPressed: () async {
                      _trace.text = (await Clipboard.getData('text/plain'))?.text ?? '';
                    },
                  ),
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
          if (_dragging)
            IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
                  border: Border.all(color: Theme.of(context).colorScheme.primary, width: 2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Center(child: Text('Drop a .symbols file, a trace file, or a symbols folder', style: TextStyle(fontSize: 16))),
              ),
            ),
        ]),
      ),
    );
  }
}
