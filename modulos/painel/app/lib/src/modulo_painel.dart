import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import 'api_painel.dart';
import 'telas/painel_tela.dart';
import 'vigia.dart';

class ModuloPainel extends Modulo {
  ModuloPainel({required String url, String token = ''}) : api = ApiPainel(url, token: token);

  final ApiPainel api;
  late final vigia = VigiaCobrador(api);

  @override
  void iniciar() => vigia.iniciar();

  @override
  String get id => 'painel';

  @override
  String get nome => 'Cobrador';

  @override
  String get descricao => 'Agenda do dia, metas, alertas e chat de disciplina';

  @override
  IconData get icone => Icons.monitor_heart_outlined;

  @override
  double? get larguraMaxima => 1600;

  @override
  Widget construir(BuildContext context) => PainelTela(api: api);
}
