import 'package:flutter/material.dart';

import '../../api_esteira.dart';
import '../../models.dart';
import '../util.dart';

/// How the esteira read the vault script (this is what becomes the video): parts, scene notes, numbered
/// lines, citations with the marked PDF crop and the sources table.
class ScriptTab extends StatefulWidget {
  const ScriptTab({super.key, required this.api, required this.ep});

  final ApiEsteira api;
  final String ep;

  @override
  State<ScriptTab> createState() => _ScriptTabState();
}

class _ScriptTabState extends State<ScriptTab> {
  late Future<Json> _script = widget.api.script(widget.ep);
  final _anchors = <int, GlobalKey>{};
  final _sources = GlobalKey();

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _script,
    builder: (context, s) {
      if (s.hasError) {
        return Empty('${s.error}', icone: Icons.description_outlined);
      }
      final r = s.data;
      if (r == null) return const Center(child: CircularProgressIndicator());
      final parts = [for (final p in r['partes'] as List) p as Json];
      return RefreshIndicator(
        onRefresh: () async => setState(() { _script = widget.api.script(widget.ep); }),
        child: LayoutBuilder(
          builder: (context, area) {
            final corpo = SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _header(context, r, parts.length),
                  for (final p in parts) _part(context, p, r['tem_graficos'] == true),
                  _tableSources(context, [for (final f in r['fontes'] as List) f as Json]),
                ],
              ),
            );
            if (area.maxWidth < 1000) return corpo;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 230, child: _index(context, parts)),
                Expanded(child: corpo),
              ],
            );
          },
        ),
      );
    },
  );

  Widget _header(BuildContext context, Json r, int nParts) {
    final words = r['palavras'] as int;
    final nc = r['n_citacoes'] as int;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 10,
          children: [
            Text('${r['titulo']}', style: Theme.of(context).textTheme.headlineSmall),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final t in [
                  '${r['formato']}',
                  '$nParts partes',
                  '${r['n_falas']} falas',
                  '$words palavras · ~${(words / 155).round()} min',
                  '${r['n_notas']} notas de cena',
                  '❝ $nc ${nc == 1 ? 'citação' : 'citações'} com PDF',
                  '${(r['fontes'] as List).length} fontes',
                ])
                  Chip(label: Text(t)),
              ],
            ),
            if (r['origem'] != null)
              Text(
                '${r['origem']}',
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ),
    );
  }

  Widget _index(BuildContext context, List<Json> parts) => ListView(
    padding: const EdgeInsets.all(12),
    children: [
      for (final p in parts)
        ListTile(
          dense: true,
          title: Text('${p['parte']} · ${p['nome']}', overflow: TextOverflow.ellipsis),
          trailing: _nQuotes(p) > 0 ? Text('${_nQuotes(p)} cit.') : null,
          onTap: () => _goTo(_anchors[p['parte']]),
        ),
      ListTile(dense: true, title: const Text('Fontes'), onTap: () => _goTo(_sources)),
    ],
  );

  static int _nQuotes(Json p) => (p['itens'] as List).where((i) => (i as Json)['tipo'] == 'cite').length;

  void _goTo(GlobalKey? chave) {
    final c = chave?.currentContext;
    if (c != null) Scrollable.ensureVisible(c, duration: const Duration(milliseconds: 300));
  }

  Widget _part(BuildContext context, Json p, bool hasGraphics) {
    final t = Theme.of(context).textTheme;
    return Padding(
      key: _anchors.putIfAbsent(p['parte'] as int? ?? 0, GlobalKey.new),
      padding: const EdgeInsets.only(top: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 10,
        children: [
          Text(
            'PARTE ${p['parte']}',
            style: t.labelMedium?.copyWith(color: Theme.of(context).colorScheme.primary),
          ),
          Text('${p['nome']}', style: t.headlineSmall?.copyWith(fontStyle: FontStyle.italic)),
          for (final it in p['itens'] as List) _item(context, it as Json, hasGraphics),
        ],
      ),
    );
  }

  Widget _item(BuildContext context, Json it, bool hasGraphics) {
    final cores = Theme.of(context).colorScheme;
    switch (it['tipo']) {
      case 'cena':
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 10,
          children: [
            const EnginePill('py', label: 'CENA'),
            Expanded(
              child: MarkedText(
                '${it['texto']}',
                estilo: TextStyle(fontStyle: FontStyle.italic, color: Colors.lightBlue.shade100),
              ),
            ),
          ],
        );
      case 'fala':
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 10,
          children: [
            SizedBox(
              width: 30,
              child: Text(
                '${it['n']}',
                textAlign: TextAlign.right,
                style: TextStyle(color: cores.outline),
              ),
            ),
            Expanded(
              child: MarkedText('${it['texto']}', estilo: const TextStyle(fontSize: 15, height: 1.45)),
            ),
          ],
        );
      default:
        return Padding(padding: const EdgeInsets.only(left: 40), child: _quote(context, it, hasGraphics));
    }
  }

  Widget _quote(BuildContext context, Json it, bool hasGraphics) {
    final c = it['c'] as Json;
    final ok = c['ok'] == true;
    final rec = it['recorte'] as Json?;
    final t = Theme.of(context).textTheme;
    final texto = Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Text('EN · COMO ESTÁ NO PDF', style: t.labelSmall),
          Text('${c['en']}', style: TextStyle(backgroundColor: Colors.amber.withValues(alpha: 0.25))),
          Text('PT · TRADUÇÃO NA TELA', style: t.labelSmall),
          Text('“${c['pt']}”', style: t.titleMedium?.copyWith(fontStyle: FontStyle.italic)),
          if (it['pdf'] != null)
            TextButton.icon(
              icon: const Icon(Icons.picture_as_pdf, size: 18),
              label: Text('${'${c['arquivo']}'.split('/').last} · p. ${c['pagina']}'),
              onPressed: () => openUrl(context, widget.api.arquivo('${it['pdf']}')),
            ),
        ],
      ),
    );
    final crop = rec == null
        ? const Padding(padding: EdgeInsets.all(24), child: Text('Sem recorte do PDF.'))
        : ColoredBox(
            color: Colors.white,
            child: _MarkedCrop(url: widget.api.arquivo('${rec['url']}'), rects: rec['rects'] as List),
          );
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: ok ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.error,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 6,
              children: [
                Text(
                  'CITAÇÃO NA TELA · ${c['autores']} (${c['ano']})${c['revista'] != null ? ' · ${c['revista']}' : ''}',
                  style: t.labelMedium?.copyWith(color: Theme.of(context).colorScheme.primary),
                ),
                if (c['titulo'] != null)
                  Text('${c['titulo']}', style: t.titleMedium?.copyWith(fontStyle: FontStyle.italic)),
                Wrap(
                  spacing: 6,
                  children: [
                    ok
                        ? StatePill('ok', texto: 'trecho conferido · p. ${c['pagina']}')
                        : const StatePill('erro', texto: 'não achado no PDF'),
                    if (it['no_video'] == true)
                      const StatePill('rodando', texto: 'no vídeo')
                    else if (hasGraphics)
                      const StatePill('pendente', texto: 'fora do vídeo (agenda cheia)'),
                  ],
                ),
              ],
            ),
          ),
          LayoutBuilder(
            builder: (context, area) => area.maxWidth < 700
                ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [crop, texto])
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 11, child: crop),
                      Expanded(flex: 10, child: texto),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _tableSources(BuildContext context, List<Json> sources) => Column(
    key: _sources,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Section('Fontes'),
      Card(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            dataRowMaxHeight: double.infinity,
            columns: const [
              DataColumn(label: Text('Estudo')),
              DataColumn(label: Text('Revista')),
              DataColumn(label: Text('DOI')),
              DataColumn(label: Text('No vídeo')),
            ],
            rows: [
              for (final f in sources)
                DataRow(
                  cells: [
                    DataCell(
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 380),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text('${f['autores']} (${f['ano']})\n${f['titulo'] ?? ''}'),
                        ),
                      ),
                    ),
                    DataCell(Text('${f['revista'] ?? ''}')),
                    DataCell(
                      f['doi'] == null
                          ? const Text('—')
                          : TextButton(
                              onPressed: () => openUrl(context, 'https://doi.org/${f['doi']}'),
                              child: Text('${f['doi']}'),
                            ),
                    ),
                    DataCell(
                      StatePill(
                        f['situacao'] == 'citação na tela' ? 'rodando' : 'pendente',
                        texto: '${f['situacao']}',
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          'Para virar citação na tela, o estudo precisa de PDF e de um bloco [!cite] no roteiro do vault '
          '(.claude/scripts/artigo citar). Depois: reimportar e refazer os gráficos.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    ],
  );
}

/// Crop of the PDF page with the highlighter rectangles (in % of the crop) on top.
class _MarkedCrop extends StatelessWidget {
  const _MarkedCrop({required this.url, required this.rects});

  final String url;
  final List rects;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, area) => Stack(
      children: [
        Image.network(url, width: area.maxWidth, fit: BoxFit.fitWidth),
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, img) => Stack(
              children: [
                for (final r in rects)
                  Positioned(
                    left: img.maxWidth * (r[0] as num) / 100,
                    top: img.maxHeight * (r[1] as num) / 100,
                    width: img.maxWidth * (r[2] as num) / 100,
                    height: img.maxHeight * (r[3] as num) / 100,
                    child: ColoredBox(color: const Color(0xFFFFD400).withValues(alpha: 0.45)),
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
