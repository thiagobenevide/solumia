import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import 'panel_api.dart';
import 'screens/panel_screen.dart';
import 'coach_watcher.dart';

class PanelModule extends Modulo {
  PanelModule({required String url, String token = ''}) : api = PanelApi(url, token: token);

  final PanelApi api;
  late final watcher = CoachWatcher(api);

  @override
  void iniciar() => watcher.start();

  @override
  String get id => 'painel';

  @override
  TemaCena get cena => TemaCena.painel;

  @override
  String get nome => 'Cobrador';

  @override
  String get descricao => 'Agenda do dia, metas, alertas e chat de disciplina';

  @override
  IconData get icone => Icons.monitor_heart_outlined;

  @override
  double? get larguraMaxima => 1600;

  @override
  bool get fundoVidro => true;

  @override
  Widget construir(BuildContext context) => PanelScreen(api: api);
}
