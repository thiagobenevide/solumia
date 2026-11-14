import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import 'electronics_api.dart';
import 'screens/projects_screen.dart';

class ElectronicsModule extends Modulo {
  ElectronicsModule({required String url, String token = ''}) : api = ElectronicsApi(url, token: token);

  final ElectronicsApi api;

  @override
  String get id => 'eletronica';

  @override
  String get nome => 'Eletrônica';

  @override
  String get descricao => 'CAD de circuitos: esquemático, simulação e placa';

  @override
  IconData get icone => Icons.memory_outlined;

  @override
  Widget construir(BuildContext context) => ProjectsScreen(api: api);
}
