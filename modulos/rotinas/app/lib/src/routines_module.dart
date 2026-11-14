import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import 'routines_api.dart';
import 'screens/routines_screen.dart';

class RoutinesModule extends Modulo {
  RoutinesModule({required String url, String token = ''}) : api = RoutinesApi(url, token: token);

  final RoutinesApi api;

  @override
  String get id => 'rotinas';

  @override
  String get nome => 'Rotinas';

  @override
  String get descricao => 'Kanban, temporizador e respostas rápidas';

  @override
  IconData get icone => Icons.view_kanban_outlined;

  @override
  Widget construir(BuildContext context) => RoutinesScreen(api: api);
}
