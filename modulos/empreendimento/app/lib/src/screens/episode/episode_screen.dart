import 'package:flutter/material.dart';

import '../../api_esteira.dart';
import 'scenes_tab.dart';
import 'cuts_tab.dart';
import 'general_tab.dart';
import 'graphics_tab.dart';
import 'script_tab.dart';
import 'thumbs_tab.dart';

/// One episode, with the same tabs as the panel: general, script, cuts, scenes, graphics and thumbnails.
class EpisodeScreen extends StatelessWidget {
  const EpisodeScreen({super.key, required this.api, required this.ep, required this.titulo});

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
          GeneralTab(api: api, ep: ep),
          ScriptTab(api: api, ep: ep),
          CutsTab(api: api, ep: ep),
          ScenesTab(api: api, ep: ep),
          GraphicsTab(api: api, ep: ep),
          ThumbsTab(api: api, ep: ep),
        ],
      ),
    ),
  );
}
