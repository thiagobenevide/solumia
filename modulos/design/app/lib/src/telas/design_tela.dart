import 'package:flutter/material.dart';

import '../api_design.dart';
import '../wireframe/galeria.dart';
import 'galeria_tela.dart';

/// Submódulos do Design: Cadernos (folhas pautadas à caneta), Fluxogramas (quadro branco/fluxos) e
/// Wireframes (telas por componentes). Sem abas internas: a seção vem do submenu lateral
/// ([secao] = `Modulo.secaoAtual`), como em Estudos.
class DesignTela extends StatelessWidget {
  const DesignTela({super.key, required this.api, required this.secao});

  final ApiDesign api;
  final ValueNotifier<int> secao;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: secao,
    // IndexedStack mantém cada galeria (e a rolagem) ao trocar pelo menu
    builder: (context, i, _) => IndexedStack(
      index: i,
      children: [GaleriaTela(api: api.cadernos), GaleriaTela(api: api), GaleriaWireframes(api: api)],
    ),
  );
}
