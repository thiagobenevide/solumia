/// Abrir o original num programa instalado (LibreOffice, Craft Apps, Office pelo padrão do
/// sistema) e subir de volta o que for salvo lá. Só no desktop; na web e no celular a lista é vazia.
library;

export 'externo_stub.dart' if (dart.library.io) 'externo_io.dart';
