import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import 'api_saude.dart';
import 'sincronizacao.dart';
import 'telas/analise_tela.dart';
import 'telas/consumo_tela.dart';
import 'telas/espiritual_tela.dart';
import 'telas/mental_tela.dart';
import 'telas/relogio_tela.dart';
import 'telas/treinos_tela.dart';

/// Sem abas no topo: cada parte é uma seção do submenu lateral ([secaoAtual]), como em Estudos.
class ModuloSaude extends Modulo {
  ModuloSaude({required this.url, this.token = ''}) : api = ApiSaude(url, token: token);

  final String url;
  final String token;
  final ApiSaude api;

  /// No Android: lê o relógio agora e agenda a leitura a cada hora em segundo plano.
  @override
  void iniciar() => agendarSincronizacao(url, token, api);

  @override
  String get id => 'saude';

  @override
  String get nome => 'Saúde';

  @override
  String get descricao => 'Espiritual, físico e mental, com os dados do relógio';

  @override
  IconData get icone => Icons.favorite_outline;

  @override
  double? get larguraMaxima => 1600;

  @override
  List<SecaoModulo> get secoes => const [
    SecaoModulo('Treinos', Icons.fitness_center),
    SecaoModulo('Espiritual', Icons.menu_book_outlined),
    SecaoModulo('Sono e corpo', Icons.watch_outlined),
    SecaoModulo('Análise', Icons.auto_awesome_outlined),
    SecaoModulo('Hábitos', Icons.check_circle_outline),
    SecaoModulo('Foco', Icons.timer_outlined),
    SecaoModulo('Humor e ansiedade', Icons.self_improvement),
    SecaoModulo('Consumo', Icons.shield_moon_outlined),
  ];

  @override
  final ValueNotifier<int> secaoAtual = ValueNotifier(0);

  @override
  Widget construir(BuildContext context) => ValueListenableBuilder(
    valueListenable: secaoAtual,
    // IndexedStack mantém o estado de cada seção ao trocar pelo menu
    builder: (context, secao, _) => IndexedStack(
      index: secao,
      children: [
        TreinosTela(api: api),
        EspiritualTela(api: api),
        RelogioTela(api: api),
        AnaliseTela(api: api),
        HabitosTela(api: api),
        FocoTela(api: api),
        AnsiedadeTela(api: api),
        ConsumoTela(api: api),
      ],
    ),
  );
}
