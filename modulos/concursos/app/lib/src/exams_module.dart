import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import 'exams_api.dart';
import 'screens/exams_screen.dart';

class ExamsModule extends Modulo {
  ExamsModule({required String url, String token = ''}) : api = ExamsApi(url, token: token);

  final ExamsApi api;

  @override
  String get id => 'concursos';

  @override
  String get nome => 'Concursos';

  @override
  String get descricao => 'Edital → plano de estudos, tarefas, prazos e alertas';

  @override
  IconData get icone => Icons.school_outlined;

  @override
  Widget construir(BuildContext context) => ExamsScreen(api: api);
}
