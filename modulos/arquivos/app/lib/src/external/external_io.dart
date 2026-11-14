import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../models.dart';

/// Program that opens a file: [command] gets the path as the last argument.
typedef Editor = ({String name, List<String> command});

/// By file `tipo`, in order of preference; only the installed ones go in.
const _byType = <String, List<Editor>>{
  'documento': [
    (name: 'WordCraft', command: ['wordcraft']),
    (name: 'LibreOffice Writer', command: ['libreoffice', '--writer']),
  ],
  'apresentacao': [
    (name: 'DeckCraft', command: ['deckcraft']),
    (name: 'LibreOffice Impress', command: ['libreoffice', '--impress']),
  ],
  'planilha': [
    (name: 'GridCraft', command: ['gridcraft']),
    (name: 'LibreOffice Calc', command: ['libreoffice', '--calc']),
  ],
  'pdf': [
    (name: 'PDFCraft', command: ['pdfcraft']),
  ],
};

bool _installed(String program) {
  final pastas = (Platform.environment['PATH'] ?? '').split(Platform.isWindows ? ';' : ':');
  return pastas.any((p) => p.isNotEmpty && File('$p/$program').existsSync());
}

/// The system default opens in Office when it is the associated program (Windows/macOS).
Editor? get _default => Platform.isLinux
    ? (name: 'Aplicativo padrão do sistema', command: ['xdg-open'])
    : Platform.isMacOS
    ? (name: 'Aplicativo padrão (Office, Pages…)', command: ['open'])
    : Platform.isWindows
    ? (name: 'Aplicativo padrão (Office…)', command: ['cmd', '/c', 'start', '""'])
    : null;

List<Editor> editorsFor(FileItem a) {
  if (!(Platform.isLinux || Platform.isMacOS || Platform.isWindows)) return const [];
  return [
    for (final e in _byType[a.type] ?? const <Editor>[])
      if (Platform.isLinux && _installed(e.command.first)) e,
    ?_default,
  ];
}

/// One watcher per file: reopening in an editor reuses the copy and the watcher.
final _watchers = <String, (File, StreamSubscription<FileSystemEvent>)>{};

/// Writes the copy to a temp folder, opens it in [e] and, on every save made there, calls
/// [onSave] with the new content (waits for the editor to finish writing).
Future<void> openExternally(Editor e, FileItem a, Uint8List bytes, Future<void> Function(Uint8List) onSave) async {
  var watcher = _watchers[a.id];
  if (watcher == null) {
    final pasta = await Directory.systemTemp.createTemp('agent-arquivos-');
    final copy = File('${pasta.path}/${a.nomeOriginal}');
    await copy.writeAsBytes(bytes);
    var last = bytes;
    Timer? wait;
    // The folder, not the file: editors save to a temp file and rename it over.
    final sub = pasta.watch().listen((ev) {
      if (ev.path != copy.path && !(ev is FileSystemMoveEvent && ev.destination == copy.path)) return;
      wait?.cancel();
      wait = Timer(const Duration(milliseconds: 1500), () async {
        if (!copy.existsSync()) return;
        final isNew = await copy.readAsBytes();
        if (isNew.isEmpty || _equal(isNew, last)) return;
        last = isNew;
        try {
          await onSave(isNew);
        } catch (e) {
          stderr.writeln('Arquivos: não subiu ${a.nomeOriginal} editado fora: $e');
        }
      });
    });
    watcher = _watchers[a.id] = (copy, sub);
  }
  await Process.start(e.command.first, [...e.command.skip(1), watcher.$1.path], mode: ProcessStartMode.detached);
}

bool _equal(Uint8List x, Uint8List y) {
  if (x.length != y.length) return false;
  for (var i = 0; i < x.length; i++) {
    if (x[i] != y[i]) return false;
  }
  return true;
}
