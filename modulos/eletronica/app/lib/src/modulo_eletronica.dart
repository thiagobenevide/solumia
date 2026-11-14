import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import 'api_eletronica.dart';
import 'telas/projetos_tela.dart';

class ModuloEletronica extends Modulo {
  ModuloEletronica({required String url, String token = ''}) : api = ApiEletronica(url, token: token);

  final ApiEletronica api;

  @override
  String get id => 'eletronica';

  @override
  String get nome => 'Eletrônica';

  @override
  String get descricao => 'CAD de circuitos: esquemático, simulação e placa';

  @override
  IconData get icone => Icons.memory_outlined;

  @override
  Widget construir(BuildContext context) => ProjetosTela(api: api);
}
