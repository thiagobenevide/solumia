import 'package:flutter/material.dart';

import '../../api_esteira.dart';
import 'cenas_aba.dart';
import 'cortes_aba.dart';
import 'geral_aba.dart';
import 'graficos_aba.dart';
import 'roteiro_aba.dart';
import 'thumbs_aba.dart';

/// Um episódio, com as mesmas abas do painel: geral, roteiro, cortes, cenas, gráficos e thumbs.
class EpisodioTela extends StatelessWidget {
  const EpisodioTela({super.key, required this.api, required this.ep, required this.titulo});

  final ApiEsteira api;
  final String ep;
  final String titulo;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 6,
    child: Scaffold(
      appBar: AppBar(
        title: Text(titulo.isEmpty ? ep : titulo, overflow: TextOverflow.ellipsis),
        bottom: const TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            Tab(text: 'Geral'),
            Tab(text: 'Roteiro'),
            Tab(text: 'Cortes'),
            Tab(text: 'Cenas'),
            Tab(text: 'Gráficos'),
            Tab(text: 'Thumbs'),
          ],
        ),
      ),
      body: TabBarView(
        children: [
          GeralAba(api: api, ep: ep),
          RoteiroAba(api: api, ep: ep),
          CortesAba(api: api, ep: ep),
          CenasAba(api: api, ep: ep),
          GraficosAba(api: api, ep: ep),
          ThumbsAba(api: api, ep: ep),
        ],
      ),
    ),
  );
}
