import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import 'files_api.dart';
import 'screens/library_screen.dart';

class FilesModule extends Modulo {
  FilesModule({required String url, String token = ''}) : api = FilesApi(url, token: token);

  final FilesApi api;

  @override
  String get id => 'arquivos';

  @override
  String get nome => 'Arquivos';

  @override
  String get descricao => 'PDF, DOCX e PPTX com anotação; CSV em tabela e XML em árvore';

  @override
  IconData get icone => Icons.folder_copy_outlined;

  @override
  Widget construir(BuildContext context) => LibraryScreen(api: api);
}
