import 'package:flutter/material.dart';

import '../design_api.dart';
import '../wireframe/gallery.dart';
import 'gallery_screen.dart';

/// Design submodules: Cadernos (pen-ruled sheets), Fluxogramas (whiteboard/flows) and
/// Wireframes (screens by components). No inner tabs: the section comes from the side submenu
/// ([section] = `Modulo.secaoAtual`), as in Estudos.
class DesignScreen extends StatelessWidget {
  const DesignScreen({super.key, required this.api, required this.section});

  final ApiDesign api;
  final ValueNotifier<int> section;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: section,
    // IndexedStack keeps each gallery (and its scroll) when switching from the menu
    builder: (context, i, _) => IndexedStack(
      index: i,
      children: [GalleryScreen(api: api.notebooks), GalleryScreen(api: api), WireframeGallery(api: api)],
    ),
  );
}
