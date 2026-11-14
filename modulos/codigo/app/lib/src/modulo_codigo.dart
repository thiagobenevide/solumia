import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import 'api_codigo.dart';
import 'codigo_tela.dart';
import 'navegador_tela.dart';

class ModuloCodigo extends Modulo {
  ModuloCodigo({required String url, String token = ''}) : api = ApiCodigo(url, token: token);

  final ApiCodigo api;

  @override
  String get id => 'codigo';

  @override
  String get nome => 'Código';

  @override
  String get descricao => 'Pedir recursos e módulos novos ao Claude Code do PC, em abas';

  @override
  IconData get icone => Icons.terminal;

  @override
  Widget construir(BuildContext context) => DefaultTabController(
    length: 2,
    child: Column(
      children: [
        const TabBar(
          tabs: [
            Tab(icon: Icon(Icons.terminal), text: 'Pedidos'),
            Tab(icon: Icon(Icons.code), text: 'Navegar no código'),
          ],
        ),
        Expanded(
          child: TabBarView(
            physics: const NeverScrollableScrollPhysics(),
            children: [CodigoTela(api: api), NavegadorTela(api: api)],
          ),
        ),
      ],
    ),
  );
}
