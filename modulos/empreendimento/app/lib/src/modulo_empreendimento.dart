import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import 'api_esteira.dart';
import 'telas/empreendimento_tela.dart';
import 'vagas/api_vagas.dart';
import 'vagas/vagas_tela.dart';
import 'youtube/api_youtube.dart';

class ModuloEmpreendimento extends Modulo {
  /// [url]/[token]: backend da plataforma, onde ficam os canais (`/api/youtube`).
  ModuloEmpreendimento({String urlEsteira = 'http://localhost:8765', required String url, String token = ''})
    : api = ApiEsteira(urlEsteira, token: token),
      youtube = ApiYoutube(url, token: token),
      vagas = ApiVagas(url, token: token);

  final ApiEsteira api;
  final ApiYoutube youtube;
  final ApiVagas vagas;

  @override
  String get id => 'empreendimento';

  @override
  String get nome => 'Empreendimento';

  @override
  String get descricao => 'Produção dos canais do YouTube e vagas de emprego';

  @override
  IconData get icone => Icons.smart_display_outlined;

  @override
  List<SecaoModulo> get secoes => const [
    SecaoModulo('YouTube', Icons.smart_display_outlined),
    SecaoModulo('Vagas', Icons.work_outline),
  ];

  @override
  final ValueNotifier<int> secaoAtual = ValueNotifier(0);

  /// Sem abas internas: a seção vem do submenu lateral; IndexedStack mantém o estado de cada uma.
  @override
  Widget construir(BuildContext context) => ValueListenableBuilder(
    valueListenable: secaoAtual,
    builder: (context, secao, _) => IndexedStack(
      index: secao,
      children: [
        EmpreendimentoTela(api: api, youtube: youtube),
        VagasTela(api: vagas),
      ],
    ),
  );
}
