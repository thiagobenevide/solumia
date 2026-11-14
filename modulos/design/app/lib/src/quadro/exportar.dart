import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:pdf/widgets.dart' as pw;

import '../modelos.dart';
import 'entrada.dart';
import 'imagens.dart';
import 'pintura.dart';

/// Desenha [elementos] numa imagem, com o fundo do quadro e [margem] em volta. [densidade] é
/// pixels por unidade do mundo; o lado maior nunca passa de [maxLado] (memória do celular).
Future<ui.Image> renderizar(
  List<Elemento> elementos,
  Fundo fundo, {
  bool escuro = false,
  double densidade = 2,
  double maxLado = 4096,
  double margem = 32,
}) async {
  await CacheImagens.instancia.garantir(elementos.whereType<Imagem>().map((e) => e.imagem));
  final area = (limitesDe(elementos) ?? const ui.Rect.fromLTWH(0, 0, 800, 600)).inflate(margem);
  final escala = min(densidade, maxLado / max(area.width, area.height));
  final tamanho = ui.Size((area.width * escala).ceilToDouble(), (area.height * escala).ceilToDouble());
  final camera = Camera()
    ..escala = escala
    ..deslocamento = -area.topLeft * escala;
  final gravador = ui.PictureRecorder();
  final canvas = ui.Canvas(gravador);
  pintarFundo(canvas, tamanho, fundo, camera, escuro);
  canvas
    ..translate(camera.deslocamento.dx, camera.deslocamento.dy)
    ..scale(escala);
  for (final e in elementos) {
    pintarElemento(canvas, e, escuro: escuro);
  }
  return gravador.endRecording().toImage(tamanho.width.toInt(), tamanho.height.toInt());
}

Future<Uint8List> png(
  List<Elemento> elementos,
  Fundo fundo, {
  bool escuro = false,
  double densidade = 2,
  double maxLado = 4096,
}) async {
  final imagem = await renderizar(elementos, fundo, escuro: escuro, densidade: densidade, maxLado: maxLado);
  final dados = await imagem.toByteData(format: ui.ImageByteFormat.png);
  imagem.dispose();
  return dados!.buffer.asUint8List();
}

/// PDF de uma página do tamanho do desenho (px lógico → pt: × 0,75), com a imagem em alta.
Future<Uint8List> pdf(List<Elemento> elementos, Fundo fundo, {bool escuro = false}) async {
  final imagem = await png(elementos, fundo, escuro: escuro, densidade: 3);
  final area = (limitesDe(elementos) ?? const ui.Rect.fromLTWH(0, 0, 800, 600)).inflate(32);
  final doc = pw.Document()
    ..addPage(
      pw.Page(
        pageFormat: PdfPageFormat(area.width * 0.75, area.height * 0.75),
        build: (_) => pw.Image(pw.MemoryImage(imagem), fit: pw.BoxFit.contain),
      ),
    );
  return doc.save();
}

enum FormatoExportacao { png, pdf }

/// Gera e abre o "salvar como" do sistema (download na web, Arquivos no Android, diálogo no desktop).
/// Devolve false quando o usuário cancelou.
Future<bool> exportar(
  String titulo,
  List<Elemento> elementos,
  Fundo fundo,
  FormatoExportacao formato, {
  bool escuro = false,
}) async {
  final bytes = switch (formato) {
    FormatoExportacao.png => await png(elementos, fundo, escuro: escuro),
    FormatoExportacao.pdf => await pdf(elementos, fundo, escuro: escuro),
  };
  final nome = titulo.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  final salvo = await FilePicker.saveFile(
    fileName: '${nome.isEmpty ? 'quadro' : nome}.${formato.name}',
    bytes: bytes,
    mimeType: formato == FormatoExportacao.png ? 'image/png' : 'application/pdf',
  );
  return salvo != null;
}
