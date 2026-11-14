import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import 'api_notas.dart';
import 'telas/notas_tela.dart';

class ModuloNotas extends Modulo {
  ModuloNotas({required String url, String token = ''}) : api = ApiNotas(url, token: token);

  final ApiNotas api;

  @override
  String get id => 'notas';

  @override
  String get nome => 'Notas';

  @override
  String get descricao => 'Notas, links e relações (Obsidian)';

  @override
  IconData get icone => Icons.sticky_note_2_outlined;

  @override
  Widget construir(BuildContext context) => NotasTela(api: api);
}
