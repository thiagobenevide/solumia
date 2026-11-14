import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import 'api_concursos.dart';
import 'telas/concursos_tela.dart';

class ModuloConcursos extends Modulo {
  ModuloConcursos({required String url, String token = ''}) : api = ApiConcursos(url, token: token);

  final ApiConcursos api;

  @override
  String get id => 'concursos';

  @override
  String get nome => 'Concursos';

  @override
  String get descricao => 'Edital → plano de estudos, tarefas, prazos e alertas';

  @override
  IconData get icone => Icons.school_outlined;

  @override
  Widget construir(BuildContext context) => ConcursosTela(api: api);
}
