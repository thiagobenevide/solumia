import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:pdf/widgets.dart' as pw;

import 'editor.dart';
import 'painting.dart';

enum ExportFormat { png, pdf }

/// The open sheet in paper colors, with a margin; the larger side is at most [maxSide] px.
Future<Uint8List> png(Editor editor, {double maxSide = 4096}) async {
  final area = (sheetBounds(editor) ?? const ui.Rect.fromLTWH(0, 0, 50000, 35000)).inflate(2540);
  final scale = min(0.1, maxSide / max(area.width, area.height));
  final size = ui.Size((area.width * scale).ceilToDouble(), (area.height * scale).ceilToDouble());
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder)
    ..drawRect(ui.Offset.zero & size, ui.Paint()..color = Palette.role.background)
    ..scale(scale)
    ..translate(-area.left, -area.top);
  paintSheet(canvas, editor, Palette.role, withSelection: false);
  final image = await recorder.endRecording().toImage(size.width.toInt(), size.height.toInt());
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// Landscape A4 PDF with the whole sheet.
Future<Uint8List> pdf(Editor editor) async {
  final image = await png(editor, maxSide: 6000);
  final doc = pw.Document()
    ..addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(24),
        build: (_) => pw.Center(child: pw.Image(pw.MemoryImage(image), fit: pw.BoxFit.contain)),
      ),
    );
  return doc.save();
}

/// Generates it and opens the system "save as". Returns false when the user cancelled.
Future<bool> export(Editor editor, ExportFormat fileFormat) async {
  final bytes = fileFormat == ExportFormat.png ? await png(editor) : await pdf(editor);
  final sheet = editor.project.sheets.firstWhere((f) => f.id == editor.sheet).name;
  final name = '${editor.project.title} - $sheet'.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  final salvo = await FilePicker.saveFile(
    fileName: '$name.${fileFormat.name}',
    bytes: bytes,
    mimeType: fileFormat == ExportFormat.png ? 'image/png' : 'application/pdf',
  );
  return salvo != null;
}

/// Saves ready bytes (e.g. BOM as CSV coming from the server).
Future<bool> saveFile(String name, Uint8List bytes, String type) async =>
    await FilePicker.saveFile(fileName: name, bytes: bytes, mimeType: type) != null;
