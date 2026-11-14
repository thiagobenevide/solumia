import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import 'code_api.dart';
import 'code_screen.dart';
import 'browser_screen.dart';

class CodeModule extends Modulo {
  CodeModule({required String url, String token = ''}) : api = CodeApi(url, token: token);

  final CodeApi api;

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
            children: [CodeScreen(api: api), BrowserScreen(api: api)],
          ),
        ),
      ],
    ),
  );
}
