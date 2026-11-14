import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../youtube/youtube_api.dart';
import '../studio/studio_tab.dart';
import '../recording/recording_tab.dart';
import '../youtube/youtube_tab.dart';
import 'library_tab.dart';
import 'costs_tab.dart';
import 'dataset_tab.dart';
import 'factory_tab.dart';
import 'queue_tab.dart';
import 'monitor_tab.dart';
import 'options_tab.dart';
import 'processes_tab.dart';
import 'production_tab.dart';
import 'scripts_tab.dart';

/// One module page: an esteira stage or a support page (tracking and configuration).
class _Page {
  const _Page(this.titulo, this.subtitulo, this.icone, this.construir);

  final String titulo;
  final String subtitulo;
  final IconData icone;
  final Widget Function(BusinessScreen t) construir;
}

/// Esteira stages, in the order the video goes through them.
final _stages = <_Page>[
  _Page('Canais', 'planejar', Icons.smart_display_outlined, (t) => YoutubeTab(api: t.youtube)),
  _Page('Estúdio', 'definir o estilo', Icons.auto_awesome_motion_outlined, (t) => StudioTab(api: t.api)),
  _Page('Fábrica', 'ideias, motion e thumbs', Icons.precision_manufacturing_outlined, (t) => FactoryTab(api: t.api)),
  _Page('Roteiros', 'escrever e escolher', Icons.description_outlined, (t) => ScriptsTab(api: t.api)),
  _Page('Fila', 'produzir', Icons.queue_outlined, (t) => QueueTab(api: t.api)),
  _Page('Produção', 'revisar episódios', Icons.movie_outlined, (t) => ProductionTab(api: t.api)),
];

/// Support pages, outside the flow: tracking and configuration.
final _support = <(String, List<_Page>)>[
  (
    'Acompanhamento',
    [
      _Page('Monitor', 'máquina', Icons.memory, (t) => MonitorTab(api: t.api)),
      _Page('Processos', 'execuções', Icons.terminal, (t) => ProcessesTab(api: t.api)),
      _Page('Custos', 'gastos', Icons.payments_outlined, (t) => CostsTab(api: t.api)),
      _Page('Dataset', 'treino e backup', Icons.dataset_outlined, (t) => DatasetTab(api: t.api)),
    ],
  ),
  (
    'Captura',
    [
      _Page('Gravação', 'câmera e tela', Icons.videocam_outlined, (t) => const RecordingTab()),
    ],
  ),
  (
    'Configuração',
    [
      _Page('Acervo', 'mídia baixada', Icons.perm_media_outlined, (t) => LibraryTab(api: t.api)),
      _Page('Opções', 'motores de IA', Icons.tune, (t) => OptionsTab(api: t.api)),
    ],
  ),
];

/// Module top as a production esteira: the stages numbered and linked in flow order and, apart,
/// the tracking and configuration pages. Only the open page stays mounted (as in TabBarView).
class BusinessScreen extends StatefulWidget {
  const BusinessScreen({super.key, required this.api, required this.youtube});

  final ApiEsteira api;
  final ApiYoutube youtube;

  @override
  State<BusinessScreen> createState() => _BusinessScreenState();
}

class _BusinessScreenState extends State<BusinessScreen> {
  late _Page _current = _stages[1];

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    return Column(
      children: [
        Material(
          color: schema.surfaceContainerLow,
          child: LayoutBuilder(
            builder: (context, c) {
              final compact = c.maxWidth < 1100;
              // phone: a single strip, scrolling horizontally, without labels, so it does not eat half the screen
              final estreito = c.maxWidth < 700;
              final esteira = _Esteira(
                current: _current,
                compact: compact,
                estreito: estreito,
                onChoose: (p) => setState(() => _current = p),
              );
              final support = _Support(current: _current, estreito: estreito, onChoose: (p) => setState(() => _current = p));
              if (estreito) {
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                  child: Row(children: [esteira, const SizedBox(width: 12), support]),
                );
              }
              return Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: compact
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [esteira, const SizedBox(height: 8), support],
                      )
                    : Row(
                        children: [
                          Expanded(child: esteira),
                          const SizedBox(width: 12),
                          support,
                        ],
                      ),
              );
            },
          ),
        ),
        Divider(height: 1, color: schema.outlineVariant),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: KeyedSubtree(key: ValueKey(_current.titulo), child: _current.construir(widget)),
          ),
        ),
      ],
    );
  }
}

/// Stage strip: numbered cards linked by arrows; the stages before the open one are marked.
class _Esteira extends StatelessWidget {
  const _Esteira({required this.current, required this.compact, this.estreito = false, required this.onChoose});

  final _Page current;
  final bool compact;
  final bool estreito;
  final ValueChanged<_Page> onChoose;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    final currentIndex = _stages.indexOf(current);
    final items = <Widget>[];
    for (var i = 0; i < _stages.length; i++) {
      if (i > 0) {
        items.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Icon(
              Icons.arrow_forward_rounded,
              size: 18,
              color: currentIndex >= i ? schema.primary : schema.outline,
            ),
          ),
        );
      }
      items.add(
        _StageCard(
          numero: i + 1,
          page: _stages[i],
          open: i == currentIndex,
          pass: currentIndex > i,
          compact: compact,
          onTap: () => onChoose(_stages[i]),
        ),
      );
    }
    if (estreito) return Row(mainAxisSize: MainAxisSize.min, children: items);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Label('Esteira de produção de conteúdo', Icons.conveyor_belt),
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: items),
        ),
      ],
    );
  }
}

class _StageCard extends StatelessWidget {
  const _StageCard({
    required this.numero,
    required this.page,
    required this.open,
    required this.pass,
    required this.compact,
    required this.onTap,
  });

  final int numero;
  final _Page page;
  final bool open;
  final bool pass;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final schema = tema.colorScheme;
    final background = open ? schema.primaryContainer : schema.surface;
    final frente = open ? schema.onPrimaryContainer : schema.onSurface;
    return Tooltip(
      message: '${page.titulo}: ${page.subtitulo}',
      waitDuration: const Duration(milliseconds: 600),
      child: Material(
        color: background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: open ? schema.primary : schema.outlineVariant, width: open ? 1.5 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 12,
                  backgroundColor: open || pass ? schema.primary : schema.surfaceContainerHighest,
                  foregroundColor: open || pass ? schema.onPrimary : schema.onSurfaceVariant,
                  child: Text('$numero', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 8),
                Icon(page.icone, size: 20, color: open ? schema.primary : schema.onSurfaceVariant),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      page.titulo,
                      style: tema.textTheme.titleSmall?.copyWith(
                        color: frente,
                        fontWeight: open ? FontWeight.bold : FontWeight.w500,
                      ),
                    ),
                    if (!compact)
                      Text(
                        page.subtitulo,
                        style: tema.textTheme.labelSmall?.copyWith(color: schema.onSurfaceVariant),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Support pages in labeled groups, with buttons smaller than the stages so they do not compete with the flow.
class _Support extends StatelessWidget {
  const _Support({required this.current, this.estreito = false, required this.onChoose});

  final _Page current;
  final bool estreito;
  final ValueChanged<_Page> onChoose;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    if (estreito) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: [
          for (final (_, pages) in _support)
            for (final p in pages)
              ChoiceChip(
                avatar: Icon(p.icone, size: 16),
                label: Text(p.titulo),
                tooltip: p.subtitulo,
                selected: identical(p, current),
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                side: BorderSide(color: schema.outlineVariant),
                onSelected: (_) => onChoose(p),
              ),
        ],
      );
    }
    return Wrap(
      spacing: 16,
      runSpacing: 8,
      children: [
        for (final (label, pages) in _support)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _Label(label, label == 'Configuração' ? Icons.settings_outlined : Icons.insights_outlined),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                children: [
                  for (final p in pages)
                    ChoiceChip(
                      avatar: Icon(p.icone, size: 16),
                      label: Text(p.titulo),
                      tooltip: p.subtitulo,
                      selected: identical(p, current),
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      side: BorderSide(color: schema.outlineVariant),
                      onSelected: (_) => onChoose(p),
                    ),
                ],
              ),
            ],
          ),
      ],
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.texto, this.icone);

  final String texto;
  final IconData icone;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final color = tema.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icone, size: 14, color: color),
        const SizedBox(width: 4),
        Text(
          texto.toUpperCase(),
          style: tema.textTheme.labelSmall?.copyWith(color: color, letterSpacing: 0.8, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}
