import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import 'design_api.dart';
import 'screens/design_screen.dart';

class ModuloDesign extends Modulo {
  ModuloDesign({required String url, String token = ''}) : api = ApiDesign(url, token: token);

  final ApiDesign api;

  @override
  String get id => 'design';

  @override
  String get nome => 'Design';

  @override
  String get descricao => 'Cadernos à caneta, fluxogramas (quadro branco com caneta, mouse ou mesa) e wireframes de telas';

  @override
  IconData get icone => Icons.draw_outlined;

  @override
  List<SecaoModulo> get secoes => const [
    SecaoModulo('Cadernos', Icons.menu_book_outlined),
    SecaoModulo('Fluxogramas', Icons.account_tree_outlined),
    SecaoModulo('Wireframes', Icons.web_outlined),
  ];

  @override
  final ValueNotifier<int> secaoAtual = ValueNotifier(0);

  @override
  Widget construir(BuildContext context) => DesignScreen(api: api, section: secaoAtual);
}
