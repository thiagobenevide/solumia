import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:pdf/widgets.dart' as pw;

import 'editor.dart';
import 'pintura.dart';

enum FormatoExportacao { png, pdf }

/// A folha aberta em cores de papel, com margem; o lado maior fica em até [maxLado] px.
Future<Uint8List> png(Editor editor, {double maxLado = 4096}) async {
  final area = (limitesDaFolha(editor) ?? const ui.Rect.fromLTWH(0, 0, 50000, 35000)).inflate(2540);
  final escala = min(0.1, maxLado / max(area.width, area.height));
  final tamanho = ui.Size((area.width * escala).ceilToDouble(), (area.height * escala).ceilToDouble());
  final gravador = ui.PictureRecorder();
  final canvas = ui.Canvas(gravador)
    ..drawRect(ui.Offset.zero & tamanho, ui.Paint()..color = Paleta.papel.fundo)
    ..scale(escala)
    ..translate(-area.left, -area.top);
  pintarFolha(canvas, editor, Paleta.papel, comSelecao: false);
  final imagem = await gravador.endRecording().toImage(tamanho.width.toInt(), tamanho.height.toInt());
  final dados = await imagem.toByteData(format: ui.ImageByteFormat.png);
  imagem.dispose();
  return dados!.buffer.asUint8List();
}

/// PDF A4 deitado com a folha inteira.
Future<Uint8List> pdf(Editor editor) async {
  final imagem = await png(editor, maxLado: 6000);
  final doc = pw.Document()
    ..addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(24),
        build: (_) => pw.Center(child: pw.Image(pw.MemoryImage(imagem), fit: pw.BoxFit.contain)),
      ),
    );
  return doc.save();
}

/// Gera e abre o "salvar como" do sistema. Devolve false quando o usuário cancelou.
Future<bool> exportar(Editor editor, FormatoExportacao formato) async {
  final bytes = formato == FormatoExportacao.png ? await png(editor) : await pdf(editor);
  final folha = editor.projeto.folhas.firstWhere((f) => f.id == editor.folha).nome;
  final nome = '${editor.projeto.titulo} - $folha'.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  final salvo = await FilePicker.saveFile(
    fileName: '$nome.${formato.name}',
    bytes: bytes,
    mimeType: formato == FormatoExportacao.png ? 'image/png' : 'application/pdf',
  );
  return salvo != null;
}

/// Salva bytes prontos (ex.: BOM em CSV vindo do servidor).
Future<bool> salvarArquivo(String nome, Uint8List bytes, String tipo) async =>
    await FilePicker.saveFile(fileName: nome, bytes: bytes, mimeType: tipo) != null;
