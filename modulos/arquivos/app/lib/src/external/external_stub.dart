import 'dart:typed_data';

import '../models.dart';

/// Program that opens a file: [command] gets the path as the last argument.
typedef Editor = ({String name, List<String> command});

List<Editor> editorsFor(FileItem a) => const [];

Future<void> openExternally(Editor e, FileItem a, Uint8List bytes, Future<void> Function(Uint8List) onSave) async {}
