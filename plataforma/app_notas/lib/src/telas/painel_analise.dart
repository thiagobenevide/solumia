import 'package:flutter/material.dart';

import '../api_notas.dart';
import '../modelos.dart';

/// Análise do cofre: o que está vencido/parado (base das cobranças) e a saúde dos links.
/// Reutilizável: o módulo Painel embute este widget com o seu [aoAbrir].
class PainelAnalise extends StatefulWidget {
  const PainelAnalise({super.key, required this.api, required this.aoAbrir});

  final ApiNotas api;
  final void Function(String id) aoAbrir;

  @override
  State<PainelAnalise> createState() => _PainelAnaliseState();
}

class _PainelAnaliseState extends State<PainelAnalise> {
  late Future<Analise> _analise = widget.api.analise();

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _analise,
    builder: (context, snap) {
      if (snap.hasError) return Center(child: Text('${snap.error}'));
      final a = snap.data;
      if (a == null) return const Center(child: CircularProgressIndicator());
      final cores = Theme.of(context).colorScheme;
      final secoes = [
        _secao('Vencidas: cobrar', Icons.alarm, cores.error, a.vencidas, prazo: true),
        _secao('Vencem em 7 dias', Icons.event, cores.tertiary, a.aVencer, prazo: true),
        _secao('Paradas há 14+ dias', Icons.hourglass_bottom, cores.secondary, a.paradas),
        _secao('Mais citadas', Icons.hub_outlined, cores.primary, a.hubs),
        _Bloco(
          titulo: 'Links quebrados (${a.quebrados.length})',
          icone: Icons.link_off,
          cor: cores.error,
          filhos: [
            for (final q in a.quebrados.take(30))
              ListTile(
                dense: true,
                title: Text(q.titulo),
                subtitle: Text('${q.tipo} → [[${q.trecho}]]'),
                onTap: () => widget.aoAbrir(q.id!),
              ),
          ],
        ),
        _secao('Órfãs (sem nenhum link)', Icons.scatter_plot_outlined, cores.outline, a.orfas),
        _Bloco(
          titulo: 'Por tipo',
          icone: Icons.category_outlined,
          cor: cores.primary,
          filhos: [
            for (final MapEntry(key: t, value: n) in a.porTipo.entries)
              ListTile(
                dense: true,
                leading: Icon(iconeDoTipo(t)),
                title: Text(t),
                subtitle: LinearProgressIndicator(value: n / a.total),
                trailing: Text('$n'),
              ),
          ],
        ),
      ];
      return RefreshIndicator(
        onRefresh: () async => setState(() => _analise = widget.api.analise()),
        child: LayoutBuilder(
          builder: (context, c) {
            // duas colunas no PC/tablet deitado, uma no celular
            final largura = c.maxWidth >= 900 ? (c.maxWidth - 36) / 2 : c.maxWidth - 24;
            return ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _Numero('Notas', a.total, cores.primary),
                    _Numero('Abertas', a.abertas, cores.secondary),
                    _Numero('Vencidas', a.vencidas.length, cores.error),
                    _Numero('Paradas', a.paradas.length, cores.tertiary),
                    _Numero('Links quebrados', a.quebrados.length, cores.error),
                    _Numero('Órfãs', a.orfas.length, cores.outline),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [for (final s in secoes) SizedBox(width: largura, child: s)],
                ),
              ],
            );
          },
        ),
      );
    },
  );

  Widget _secao(String titulo, IconData icone, Color cor, List<NotaResumo> lista, {bool prazo = false}) =>
      _Bloco(
        titulo: '$titulo (${lista.length})',
        icone: icone,
        cor: cor,
        filhos: [
          for (final r in lista.take(30))
            ListTile(
              dense: true,
              leading: Icon(iconeDoTipo(r.tipo)),
              title: Text(r.titulo),
              subtitle: Text(
                [r.status, prazo ? dataCurta(r.prazo) : null, '${r.entradas} backlinks'].nonNulls.join(' · '),
              ),
              onTap: () => widget.aoAbrir(r.id),
            ),
        ],
      );
}

class _Numero extends StatelessWidget {
  const _Numero(this.rotulo, this.valor, this.cor);

  final String rotulo;
  final int valor;
  final Color cor;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 150,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$valor', style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: cor)),
            Text(rotulo),
          ],
        ),
      ),
    ),
  );
}

class _Bloco extends StatelessWidget {
  const _Bloco({required this.titulo, required this.icone, required this.cor, required this.filhos});

  final String titulo;
  final IconData icone;
  final Color cor;
  final List<Widget> filhos;

  @override
  Widget build(BuildContext context) => Card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: Icon(icone, color: cor),
          title: Text(titulo, style: Theme.of(context).textTheme.titleSmall),
        ),
        if (filhos.isEmpty)
          const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 16), child: Text('Nada aqui.'))
        else
          ...filhos,
      ],
    ),
  );
}
