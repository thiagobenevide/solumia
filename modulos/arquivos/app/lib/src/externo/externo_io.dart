import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../modelos.dart';

/// Programa que abre um arquivo: [comando] recebe o caminho como último argumento.
typedef Editor = ({String nome, List<String> comando});

/// Por `tipo` do arquivo, na ordem de preferência; só entram os instalados.
const _porTipo = <String, List<Editor>>{
  'documento': [
    (nome: 'WordCraft', comando: ['wordcraft']),
    (nome: 'LibreOffice Writer', comando: ['libreoffice', '--writer']),
  ],
  'apresentacao': [
    (nome: 'DeckCraft', comando: ['deckcraft']),
    (nome: 'LibreOffice Impress', comando: ['libreoffice', '--impress']),
  ],
  'planilha': [
    (nome: 'GridCraft', comando: ['gridcraft']),
    (nome: 'LibreOffice Calc', comando: ['libreoffice', '--calc']),
  ],
  'pdf': [
    (nome: 'PDFCraft', comando: ['pdfcraft']),
  ],
};

bool _instalado(String programa) {
  final pastas = (Platform.environment['PATH'] ?? '').split(Platform.isWindows ? ';' : ':');
  return pastas.any((p) => p.isNotEmpty && File('$p/$programa').existsSync());
}

/// O padrão do sistema abre no Office quando ele é o programa associado (Windows/macOS).
Editor? get _padrao => Platform.isLinux
    ? (nome: 'Aplicativo padrão do sistema', comando: ['xdg-open'])
    : Platform.isMacOS
    ? (nome: 'Aplicativo padrão (Office, Pages…)', comando: ['open'])
    : Platform.isWindows
    ? (nome: 'Aplicativo padrão (Office…)', comando: ['cmd', '/c', 'start', '""'])
    : null;

List<Editor> editoresPara(Arquivo a) {
  if (!(Platform.isLinux || Platform.isMacOS || Platform.isWindows)) return const [];
  return [
    for (final e in _porTipo[a.tipo] ?? const <Editor>[])
      if (Platform.isLinux && _instalado(e.comando.first)) e,
    ?_padrao,
  ];
}

/// Uma vigia por arquivo: reabrir num editor reaproveita a cópia e a vigia.
final _vigias = <String, (File, StreamSubscription<FileSystemEvent>)>{};

/// Grava a cópia numa pasta temporária, abre no [e] e, a cada gravação feita lá, chama
/// [aoSalvar] com o conteúdo novo (espera o editor terminar de escrever).
Future<void> abrirFora(Editor e, Arquivo a, Uint8List bytes, Future<void> Function(Uint8List) aoSalvar) async {
  var vigia = _vigias[a.id];
  if (vigia == null) {
    final pasta = await Directory.systemTemp.createTemp('agent-arquivos-');
    final copia = File('${pasta.path}/${a.nomeOriginal}');
    await copia.writeAsBytes(bytes);
    var ultimo = bytes;
    Timer? espera;
    // A pasta, não o arquivo: editores salvam num temporário e renomeiam por cima.
    final sub = pasta.watch().listen((ev) {
      if (ev.path != copia.path && !(ev is FileSystemMoveEvent && ev.destination == copia.path)) return;
      espera?.cancel();
      espera = Timer(const Duration(milliseconds: 1500), () async {
        if (!copia.existsSync()) return;
        final novo = await copia.readAsBytes();
        if (novo.isEmpty || _iguais(novo, ultimo)) return;
        ultimo = novo;
        try {
          await aoSalvar(novo);
        } catch (e) {
          stderr.writeln('Arquivos: não subiu ${a.nomeOriginal} editado fora: $e');
        }
      });
    });
    vigia = _vigias[a.id] = (copia, sub);
  }
  await Process.start(e.comando.first, [...e.comando.skip(1), vigia.$1.path], mode: ProcessStartMode.detached);
}

bool _iguais(Uint8List x, Uint8List y) {
  if (x.length != y.length) return false;
  for (var i = 0; i < x.length; i++) {
    if (x[i] != y[i]) return false;
  }
  return true;
}
