import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import 'api_arquivos.dart';
import 'telas/biblioteca_tela.dart';

class ModuloArquivos extends Modulo {
  ModuloArquivos({required String url, String token = ''}) : api = ApiArquivos(url, token: token);

  final ApiArquivos api;

  @override
  String get id => 'arquivos';

  @override
  String get nome => 'Arquivos';

  @override
  String get descricao => 'PDF, DOCX e PPTX com anotação; CSV em tabela e XML em árvore';

  @override
  IconData get icone => Icons.folder_copy_outlined;

  @override
  Widget construir(BuildContext context) => BibliotecaTela(api: api);
}
