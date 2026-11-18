import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import 'api_esteira.dart';
import 'screens/business_screen.dart';
import 'jobs/jobs_api.dart';
import 'jobs/jobs_screen.dart';
import 'youtube/youtube_api.dart';

class BusinessModule extends Modulo {
  /// [url]/[token]: platform backend, where the channels live (`/api/youtube`).
  BusinessModule({String pipelineUrl = 'http://localhost:8765', required String url, String token = ''})
    : api = ApiEsteira(pipelineUrl, token: token),
      youtube = ApiYoutube(url, token: token),
      jobs = ApiJobs(url, token: token);

  final ApiEsteira api;
  final ApiYoutube youtube;
  final ApiJobs jobs;

  @override
  String get id => 'empreendimento';

  @override
  TemaCena get cena => TemaCena.empreendimento;

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

  /// No inner tabs: the section comes from the side submenu; IndexedStack keeps each one's state.
  @override
  Widget construir(BuildContext context) => ValueListenableBuilder(
    valueListenable: secaoAtual,
    builder: (context, section, _) => IndexedStack(
      index: section,
      children: [
        BusinessScreen(api: api, youtube: youtube),
        JobsScreen(api: jobs),
      ],
    ),
  );
}
