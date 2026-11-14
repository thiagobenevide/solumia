import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import 'api_rotinas.dart';
import 'telas/rotinas_tela.dart';

class ModuloRotinas extends Modulo {
  ModuloRotinas({required String url, String token = ''}) : api = ApiRotinas(url, token: token);

  final ApiRotinas api;

  @override
  String get id => 'rotinas';

  @override
  String get nome => 'Rotinas';

  @override
  String get descricao => 'Kanban, temporizador e respostas rápidas';

  @override
  IconData get icone => Icons.view_kanban_outlined;

  @override
  Widget construir(BuildContext context) => RotinasTela(api: api);
}
