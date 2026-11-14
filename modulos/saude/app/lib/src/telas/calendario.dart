import 'package:flutter/material.dart';

import '../datas.dart';
import 'comuns.dart';

/// Grade do mês: 6 semanas; cada dia recebe exercícios arrastados e, ao toque, abre o dia.
class VistaMes extends StatelessWidget {
  const VistaMes({super.key, required this.agenda, required this.foco});

  final Agenda agenda;
  final DateTime foco;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final dias = gradeMes(foco);
    return Column(
      children: [
        Row(
          children: [
            for (final d in diasSemana)
              Expanded(child: Center(child: Text(d, style: tema.textTheme.labelMedium))),
          ],
        ),
        const SizedBox(height: 4),
        Expanded(
          child: Column(
            children: [
              for (var s = 0; s < 6; s++)
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final d in dias.sublist(s * 7, s * 7 + 7))
                        Expanded(child: _CelulaMes(agenda: agenda, dia: d, doMes: d.month == foco.month)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CelulaMes extends StatelessWidget {
  const _CelulaMes({required this.agenda, required this.dia, required this.doMes});

  final Agenda agenda;
  final DateTime dia;
  final bool doMes;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final itens = agenda.itensDoDia(dia);
    final ehHoje = mesmoDia(dia, hoje());
    return Padding(
      padding: const EdgeInsets.all(1),
      child: AlvoDia(
        agenda: agenda,
        dia: dia,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => agenda.abrirDia(dia),
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: doMes ? tema.colorScheme.surfaceContainerLow : null,
              borderRadius: BorderRadius.circular(8),
            ),
            child: LayoutBuilder(
              builder: (context, c) {
                // quantos cartões cabem abaixo do número do dia (cada um ~18 px)
                final cabem = ((c.maxHeight - 22) / 18).floor().clamp(0, 99);
                final mostrar = itens.length > cabem ? (cabem - 1).clamp(0, 99) : itens.length;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.topLeft,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: ehHoje
                            ? BoxDecoration(color: tema.colorScheme.primary, borderRadius: BorderRadius.circular(10))
                            : null,
                        child: Text(
                          '${dia.day}',
                          style: tema.textTheme.labelMedium?.copyWith(
                            color: ehHoje
                                ? tema.colorScheme.onPrimary
                                : doMes
                                ? null
                                : tema.colorScheme.outline,
                          ),
                        ),
                      ),
                    ),
                    for (final i in itens.take(mostrar)) CartaoItem(agenda: agenda, item: i, compacto: true),
                    if (mostrar < itens.length)
                      Text('+${itens.length - mostrar}', style: tema.textTheme.labelSmall),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Semana de segunda a domingo: 7 colunas na tela larga; uma lista de dias na estreita.
class VistaSemana extends StatelessWidget {
  const VistaSemana({super.key, required this.agenda, required this.foco});

  final Agenda agenda;
  final DateTime foco;

  @override
  Widget build(BuildContext context) {
    final dias = [for (var i = 0; i < 7; i++) somarDias(inicioSemana(foco), i)];
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth >= 640) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final d in dias) Expanded(child: _ColunaDia(agenda: agenda, dia: d))],
          );
        }
        return ListView(
          children: [
            for (final d in dias)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _ColunaDia(agenda: agenda, dia: d, rolavel: false),
              ),
          ],
        );
      },
    );
  }
}

class _ColunaDia extends StatelessWidget {
  const _ColunaDia({required this.agenda, required this.dia, this.rolavel = true});

  final Agenda agenda;
  final DateTime dia;
  final bool rolavel;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final itens = agenda.itensDoDia(dia);
    final ehHoje = mesmoDia(dia, hoje());
    final cartoes = [for (final i in itens) CartaoItem(agenda: agenda, item: i)];
    return Padding(
      padding: const EdgeInsets.all(2),
      child: AlvoDia(
        agenda: agenda,
        dia: dia,
        child: Container(
          constraints: const BoxConstraints(minHeight: 72),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: tema.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(8),
            border: ehHoje ? Border.all(color: tema.colorScheme.primary) : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                onTap: () => agenda.abrirDia(dia),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    rolavel ? '${diasSemana[dia.weekday - 1]} ${dia.day}' : diaLongo(dia),
                    style: tema.textTheme.titleSmall?.copyWith(color: ehHoje ? tema.colorScheme.primary : null),
                  ),
                ),
              ),
              if (rolavel) Expanded(child: ListView(children: cartoes)) else ...cartoes,
              if (itens.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text('arraste exercícios aqui', style: tema.textTheme.bodySmall?.copyWith(color: tema.colorScheme.outline)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Um dia: os exercícios na ordem, com reordenação e cartões grandes.
class VistaDia extends StatelessWidget {
  const VistaDia({super.key, required this.agenda, required this.foco, required this.reordenar});

  final Agenda agenda;
  final DateTime foco;
  final void Function(List<String> idsNaOrdem) reordenar;

  @override
  Widget build(BuildContext context) {
    final itens = agenda.itensDoDia(foco);
    final tema = Theme.of(context);
    final feitos = itens.where((i) => i.feito).length;
    return AlvoDia(
      agenda: agenda,
      dia: foco,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                Expanded(child: Text(diaLongo(foco), style: tema.textTheme.titleMedium)),
                if (itens.isNotEmpty) Text('$feitos de ${itens.length} feitos'),
              ],
            ),
          ),
          if (itens.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: LinearProgressIndicator(value: feitos / itens.length),
            ),
          Expanded(
            child: itens.isEmpty
                ? Center(
                    child: Text(
                      'Nenhum exercício neste dia.\nArraste da biblioteca ou use o + de cada exercício.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: tema.colorScheme.outline),
                    ),
                  )
                : ReorderableListView(
                    padding: const EdgeInsets.all(8),
                    buildDefaultDragHandles: false,
                    onReorderItem: (de, para) {
                      final ids = [for (final i in itens) i.id];
                      ids.insert(para, ids.removeAt(de));
                      reordenar(ids);
                    },
                    children: [
                      for (final (n, i) in itens.indexed)
                        Row(
                          key: ValueKey(i.id),
                          children: [
                            ReorderableDragStartListener(
                              index: n,
                              child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.drag_indicator)),
                            ),
                            Expanded(child: CartaoItem(agenda: agenda, item: i)),
                          ],
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
