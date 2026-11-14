import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:pdf/widgets.dart' as pw;

import '../models.dart';
import 'input.dart';
import 'images.dart';
import 'painting.dart';

/// Draws [elements] into an image, with the board background and [margin] around. [density] is
/// pixels per world unit; the larger side never goes over [maxSide] (phone memory).
Future<ui.Image> render(
  List<Elemento> elements,
  Background background, {
  bool dark = false,
  double density = 2,
  double maxSide = 4096,
  double margin = 32,
}) async {
  await BoardImageCache.instance.ensure(elements.whereType<BoardImage>().map((e) => e.image));
  final area = (boundsOf(elements) ?? const ui.Rect.fromLTWH(0, 0, 800, 600)).inflate(margin);
  final scale = min(density, maxSide / max(area.width, area.height));
  final size = ui.Size((area.width * scale).ceilToDouble(), (area.height * scale).ceilToDouble());
  final camera = Camera()
    ..scale = scale
    ..offset = -area.topLeft * scale;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  paintBackground(canvas, size, background, camera, dark);
  canvas
    ..translate(camera.offset.dx, camera.offset.dy)
    ..scale(scale);
  for (final e in elements) {
    paintElement(canvas, e, dark: dark);
  }
  return recorder.endRecording().toImage(size.width.toInt(), size.height.toInt());
}

Future<Uint8List> png(
  List<Elemento> elements,
  Background background, {
  bool dark = false,
  double density = 2,
  double maxSide = 4096,
}) async {
  final image = await render(elements, background, dark: dark, density: density, maxSide: maxSide);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// One-page PDF the size of the drawing (logical px → pt: × 0.75), with the high-res image.
Future<Uint8List> pdf(List<Elemento> elements, Background background, {bool dark = false}) async {
  final image = await png(elements, background, dark: dark, density: 3);
  final area = (boundsOf(elements) ?? const ui.Rect.fromLTWH(0, 0, 800, 600)).inflate(32);
  final doc = pw.Document()
    ..addPage(
      pw.Page(
        pageFormat: PdfPageFormat(area.width * 0.75, area.height * 0.75),
        build: (_) => pw.Image(pw.MemoryImage(image), fit: pw.BoxFit.contain),
      ),
    );
  return doc.save();
}

enum ExportFormat { png, pdf }

/// Generates it and opens the system "save as" (download on the web, Files on Android, dialog on desktop).
/// Returns false when the user cancelled.
Future<bool> export(
  String title,
  List<Elemento> elements,
  Background background,
  ExportFormat fileFormat, {
  bool dark = false,
}) async {
  final bytes = switch (fileFormat) {
    ExportFormat.png => await png(elements, background, dark: dark),
    ExportFormat.pdf => await pdf(elements, background, dark: dark),
  };
  final name = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  final saved = await FilePicker.saveFile(
    fileName: '${name.isEmpty ? 'quadro' : name}.${fileFormat.name}',
    bytes: bytes,
    mimeType: fileFormat == ExportFormat.png ? 'image/png' : 'application/pdf',
  );
  return saved != null;
}
