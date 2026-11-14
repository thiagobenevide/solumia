import 'package:flutter/material.dart';

import '../modelos.dart';

class CartaoTarefa extends StatelessWidget {
  const CartaoTarefa({
    super.key,
    required this.tarefa,
    required this.agora,
    required this.aoAlternarCronometro,
    required this.aoEditar,
    required this.aoMover,
    required this.aoZerar,
    required this.aoExcluir,
  });

  final Tarefa tarefa;
  final DateTime agora;
  final VoidCallback aoAlternarCronometro;
  final VoidCallback aoEditar;
  final ValueChanged<Coluna> aoMover;
  final VoidCallback aoZerar;
  final VoidCallback aoExcluir;

  Color _corPrioridade(ColorScheme c) => switch (tarefa.prioridade) {
    'alta' => c.error,
    'baixa' => c.outline,
    _ => c.tertiary,
  };

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    final texto = Theme.of(context).textTheme;
    final t = tarefa;
    final concluida = t.coluna == Coluna.concluida;
    final atrasada = t.atrasadaEm(agora);
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: t.rodando ? BorderSide(color: cores.primary, width: 2) : BorderSide.none,
      ),
      child: InkWell(
        onTap: aoEditar,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [
              Row(
                children: [
                  Container(
                    width: 4,
                    height: 20,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(color: _corPrioridade(cores), borderRadius: BorderRadius.circular(2)),
                  ),
                  Expanded(
                    child: Text(
                      t.titulo,
                      style: texto.titleSmall?.copyWith(decoration: concluida ? TextDecoration.lineThrough : null),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  _Menu(tarefa: t, aoMover: aoMover, aoEditar: aoEditar, aoZerar: aoZerar, aoExcluir: aoExcluir),
                ],
              ),
              if (t.descricao.isNotEmpty)
                Text(t.descricao, maxLines: 2, overflow: TextOverflow.ellipsis, style: texto.bodySmall),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (t.prazo != null)
                    _Etiqueta(
                      icone: Icons.event_outlined,
                      texto: '${t.prazo!.day}/${t.prazo!.month}',
                      cor: atrasada ? cores.error : null,
                    ),
                  for (final tag in t.tags) _Etiqueta(icone: Icons.sell_outlined, texto: tag),
                ],
              ),
              Row(
                children: [
                  Icon(Icons.timer_outlined, size: 16, color: t.rodando ? cores.primary : cores.outline),
                  const SizedBox(width: 4),
                  Text(
                    formatarDuracao(t.tempoEm(agora), segundos: t.rodando),
                    style: texto.labelMedium?.copyWith(
                      color: t.rodando ? cores.primary : null,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const Spacer(),
                  if (!concluida)
                    IconButton(
                      tooltip: t.rodando ? 'Pausar' : 'Iniciar cronômetro',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(t.rodando ? Icons.pause_circle : Icons.play_circle_outline),
                      color: cores.primary,
                      onPressed: aoAlternarCronometro,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Etiqueta extends StatelessWidget {
  const _Etiqueta({required this.icone, required this.texto, this.cor});

  final IconData icone;
  final String texto;
  final Color? cor;

  @override
  Widget build(BuildContext context) {
    final c = cor ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 2,
      children: [
        Icon(icone, size: 14, color: c),
        Text(texto, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: c)),
      ],
    );
  }
}

class _Menu extends StatelessWidget {
  const _Menu({
    required this.tarefa,
    required this.aoMover,
    required this.aoEditar,
    required this.aoZerar,
    required this.aoExcluir,
  });

  final Tarefa tarefa;
  final ValueChanged<Coluna> aoMover;
  final VoidCallback aoEditar;
  final VoidCallback aoZerar;
  final VoidCallback aoExcluir;

  @override
  Widget build(BuildContext context) => PopupMenuButton<VoidCallback>(
    tooltip: 'Ações',
    icon: const Icon(Icons.more_vert, size: 20),
    onSelected: (acao) => acao(),
    itemBuilder: (_) => [
      for (final c in Coluna.values)
        if (c != tarefa.coluna)
          PopupMenuItem(value: () => aoMover(c), child: Text('Mover para ${c.rotulo.toLowerCase()}')),
      const PopupMenuDivider(),
      PopupMenuItem(value: aoEditar, child: const Text('Editar')),
      if (tarefa.tempoTotal > Duration.zero || tarefa.rodando)
        PopupMenuItem(value: aoZerar, child: const Text('Zerar tempo')),
      PopupMenuItem(value: aoExcluir, child: const Text('Excluir')),
    ],
  );
}
