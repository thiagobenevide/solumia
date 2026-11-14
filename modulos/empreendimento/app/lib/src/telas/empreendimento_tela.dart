import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../youtube/api_youtube.dart';
import '../estudio/estudio_aba.dart';
import '../recording/recording_tab.dart';
import '../youtube/youtube_aba.dart';
import 'acervo_aba.dart';
import 'custos_aba.dart';
import 'dataset_aba.dart';
import 'fabrica_aba.dart';
import 'fila_aba.dart';
import 'monitor_aba.dart';
import 'opcoes_aba.dart';
import 'processos_aba.dart';
import 'producao_aba.dart';
import 'roteiros_aba.dart';

/// Uma página do módulo: etapa da esteira ou página de apoio (acompanhamento e configuração).
class _Pagina {
  const _Pagina(this.titulo, this.subtitulo, this.icone, this.construir);

  final String titulo;
  final String subtitulo;
  final IconData icone;
  final Widget Function(EmpreendimentoTela t) construir;
}

/// Etapas da esteira, na ordem em que o vídeo passa por elas.
final _etapas = <_Pagina>[
  _Pagina('Canais', 'planejar', Icons.smart_display_outlined, (t) => YoutubeAba(api: t.youtube)),
  _Pagina('Estúdio', 'definir o estilo', Icons.auto_awesome_motion_outlined, (t) => EstudioAba(api: t.api)),
  _Pagina('Fábrica', 'ideias, motion e thumbs', Icons.precision_manufacturing_outlined, (t) => FabricaAba(api: t.api)),
  _Pagina('Roteiros', 'escrever e escolher', Icons.description_outlined, (t) => RoteirosAba(api: t.api)),
  _Pagina('Fila', 'produzir', Icons.queue_outlined, (t) => FilaAba(api: t.api)),
  _Pagina('Produção', 'revisar episódios', Icons.movie_outlined, (t) => ProducaoAba(api: t.api)),
];

/// Páginas de apoio, fora do fluxo: acompanhamento e configuração.
final _apoio = <(String, List<_Pagina>)>[
  (
    'Acompanhamento',
    [
      _Pagina('Monitor', 'máquina', Icons.memory, (t) => MonitorAba(api: t.api)),
      _Pagina('Processos', 'execuções', Icons.terminal, (t) => ProcessosAba(api: t.api)),
      _Pagina('Custos', 'gastos', Icons.payments_outlined, (t) => CustosAba(api: t.api)),
      _Pagina('Dataset', 'treino e backup', Icons.dataset_outlined, (t) => DatasetAba(api: t.api)),
    ],
  ),
  (
    'Captura',
    [
      _Pagina('Gravação', 'câmera e tela', Icons.videocam_outlined, (t) => const RecordingTab()),
    ],
  ),
  (
    'Configuração',
    [
      _Pagina('Acervo', 'mídia baixada', Icons.perm_media_outlined, (t) => AcervoAba(api: t.api)),
      _Pagina('Opções', 'motores de IA', Icons.tune, (t) => OpcoesAba(api: t.api)),
    ],
  ),
];

/// Topo do módulo como esteira de produção: as etapas numeradas e ligadas na ordem do fluxo e, à parte,
/// as páginas de acompanhamento e configuração. Só a página aberta fica montada (como no TabBarView).
class EmpreendimentoTela extends StatefulWidget {
  const EmpreendimentoTela({super.key, required this.api, required this.youtube});

  final ApiEsteira api;
  final ApiYoutube youtube;

  @override
  State<EmpreendimentoTela> createState() => _EmpreendimentoTelaState();
}

class _EmpreendimentoTelaState extends State<EmpreendimentoTela> {
  late _Pagina _atual = _etapas[1];

  @override
  Widget build(BuildContext context) {
    final esquema = Theme.of(context).colorScheme;
    return Column(
      children: [
        Material(
          color: esquema.surfaceContainerLow,
          child: LayoutBuilder(
            builder: (context, c) {
              final compacto = c.maxWidth < 1100;
              // celular: uma faixa só, rolando na horizontal, sem rótulos, para não comer meia tela
              final estreito = c.maxWidth < 700;
              final esteira = _Esteira(
                atual: _atual,
                compacto: compacto,
                estreito: estreito,
                aoEscolher: (p) => setState(() => _atual = p),
              );
              final apoio = _Apoio(atual: _atual, estreito: estreito, aoEscolher: (p) => setState(() => _atual = p));
              if (estreito) {
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                  child: Row(children: [esteira, const SizedBox(width: 12), apoio]),
                );
              }
              return Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: compacto
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [esteira, const SizedBox(height: 8), apoio],
                      )
                    : Row(
                        children: [
                          Expanded(child: esteira),
                          const SizedBox(width: 12),
                          apoio,
                        ],
                      ),
              );
            },
          ),
        ),
        Divider(height: 1, color: esquema.outlineVariant),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: KeyedSubtree(key: ValueKey(_atual.titulo), child: _atual.construir(widget)),
          ),
        ),
      ],
    );
  }
}

/// Faixa das etapas: cartões numerados ligados por setas; as etapas antes da aberta ficam marcadas.
class _Esteira extends StatelessWidget {
  const _Esteira({required this.atual, required this.compacto, this.estreito = false, required this.aoEscolher});

  final _Pagina atual;
  final bool compacto;
  final bool estreito;
  final ValueChanged<_Pagina> aoEscolher;

  @override
  Widget build(BuildContext context) {
    final esquema = Theme.of(context).colorScheme;
    final iAtual = _etapas.indexOf(atual);
    final itens = <Widget>[];
    for (var i = 0; i < _etapas.length; i++) {
      if (i > 0) {
        itens.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Icon(
              Icons.arrow_forward_rounded,
              size: 18,
              color: iAtual >= i ? esquema.primary : esquema.outline,
            ),
          ),
        );
      }
      itens.add(
        _CartaoEtapa(
          numero: i + 1,
          pagina: _etapas[i],
          aberta: i == iAtual,
          passada: iAtual > i,
          compacto: compacto,
          aoTocar: () => aoEscolher(_etapas[i]),
        ),
      );
    }
    if (estreito) return Row(mainAxisSize: MainAxisSize.min, children: itens);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Rotulo('Esteira de produção de conteúdo', Icons.conveyor_belt),
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: itens),
        ),
      ],
    );
  }
}

class _CartaoEtapa extends StatelessWidget {
  const _CartaoEtapa({
    required this.numero,
    required this.pagina,
    required this.aberta,
    required this.passada,
    required this.compacto,
    required this.aoTocar,
  });

  final int numero;
  final _Pagina pagina;
  final bool aberta;
  final bool passada;
  final bool compacto;
  final VoidCallback aoTocar;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final esquema = tema.colorScheme;
    final fundo = aberta ? esquema.primaryContainer : esquema.surface;
    final frente = aberta ? esquema.onPrimaryContainer : esquema.onSurface;
    return Tooltip(
      message: '${pagina.titulo}: ${pagina.subtitulo}',
      waitDuration: const Duration(milliseconds: 600),
      child: Material(
        color: fundo,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: aberta ? esquema.primary : esquema.outlineVariant, width: aberta ? 1.5 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: aoTocar,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: compacto ? 10 : 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 12,
                  backgroundColor: aberta || passada ? esquema.primary : esquema.surfaceContainerHighest,
                  foregroundColor: aberta || passada ? esquema.onPrimary : esquema.onSurfaceVariant,
                  child: Text('$numero', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 8),
                Icon(pagina.icone, size: 20, color: aberta ? esquema.primary : esquema.onSurfaceVariant),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      pagina.titulo,
                      style: tema.textTheme.titleSmall?.copyWith(
                        color: frente,
                        fontWeight: aberta ? FontWeight.bold : FontWeight.w500,
                      ),
                    ),
                    if (!compacto)
                      Text(
                        pagina.subtitulo,
                        style: tema.textTheme.labelSmall?.copyWith(color: esquema.onSurfaceVariant),
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

/// Páginas de apoio em grupos rotulados, com botões menores que as etapas para não competir com o fluxo.
class _Apoio extends StatelessWidget {
  const _Apoio({required this.atual, this.estreito = false, required this.aoEscolher});

  final _Pagina atual;
  final bool estreito;
  final ValueChanged<_Pagina> aoEscolher;

  @override
  Widget build(BuildContext context) {
    final esquema = Theme.of(context).colorScheme;
    if (estreito) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: [
          for (final (_, paginas) in _apoio)
            for (final p in paginas)
              ChoiceChip(
                avatar: Icon(p.icone, size: 16),
                label: Text(p.titulo),
                tooltip: p.subtitulo,
                selected: identical(p, atual),
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                side: BorderSide(color: esquema.outlineVariant),
                onSelected: (_) => aoEscolher(p),
              ),
        ],
      );
    }
    return Wrap(
      spacing: 16,
      runSpacing: 8,
      children: [
        for (final (rotulo, paginas) in _apoio)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _Rotulo(rotulo, rotulo == 'Configuração' ? Icons.settings_outlined : Icons.insights_outlined),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                children: [
                  for (final p in paginas)
                    ChoiceChip(
                      avatar: Icon(p.icone, size: 16),
                      label: Text(p.titulo),
                      tooltip: p.subtitulo,
                      selected: identical(p, atual),
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      side: BorderSide(color: esquema.outlineVariant),
                      onSelected: (_) => aoEscolher(p),
                    ),
                ],
              ),
            ],
          ),
      ],
    );
  }
}

class _Rotulo extends StatelessWidget {
  const _Rotulo(this.texto, this.icone);

  final String texto;
  final IconData icone;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final cor = tema.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icone, size: 14, color: cor),
        const SizedBox(width: 4),
        Text(
          texto.toUpperCase(),
          style: tema.textTheme.labelSmall?.copyWith(color: cor, letterSpacing: 0.8, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}
