import 'package:flutter/material.dart';

import '../../api_esteira.dart';
import '../../modelos.dart';
import '../util.dart';

/// Como a esteira leu o roteiro do vault (é isto que vira o vídeo): partes, notas de cena, falas
/// numeradas, citações com o recorte do PDF marcado e a tabela de fontes.
class RoteiroAba extends StatefulWidget {
  const RoteiroAba({super.key, required this.api, required this.ep});

  final ApiEsteira api;
  final String ep;

  @override
  State<RoteiroAba> createState() => _RoteiroAbaState();
}

class _RoteiroAbaState extends State<RoteiroAba> {
  late Future<Json> _roteiro = widget.api.roteiro(widget.ep);
  final _ancoras = <int, GlobalKey>{};
  final _fontes = GlobalKey();

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _roteiro,
    builder: (context, s) {
      if (s.hasError) {
        return Vazio('${s.error}', icone: Icons.description_outlined);
      }
      final r = s.data;
      if (r == null) return const Center(child: CircularProgressIndicator());
      final partes = [for (final p in r['partes'] as List) p as Json];
      return RefreshIndicator(
        onRefresh: () async => setState(() { _roteiro = widget.api.roteiro(widget.ep); }),
        child: LayoutBuilder(
          builder: (context, area) {
            final corpo = SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _cabecalho(context, r, partes.length),
                  for (final p in partes) _parte(context, p, r['tem_graficos'] == true),
                  _tabelaFontes(context, [for (final f in r['fontes'] as List) f as Json]),
                ],
              ),
            );
            if (area.maxWidth < 1000) return corpo;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 230, child: _indice(context, partes)),
                Expanded(child: corpo),
              ],
            );
          },
        ),
      );
    },
  );

  Widget _cabecalho(BuildContext context, Json r, int nPartes) {
    final palavras = r['palavras'] as int;
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
                  '$nPartes partes',
                  '${r['n_falas']} falas',
                  '$palavras palavras · ~${(palavras / 155).round()} min',
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

  Widget _indice(BuildContext context, List<Json> partes) => ListView(
    padding: const EdgeInsets.all(12),
    children: [
      for (final p in partes)
        ListTile(
          dense: true,
          title: Text('${p['parte']} · ${p['nome']}', overflow: TextOverflow.ellipsis),
          trailing: _nCitacoes(p) > 0 ? Text('${_nCitacoes(p)} cit.') : null,
          onTap: () => _irPara(_ancoras[p['parte']]),
        ),
      ListTile(dense: true, title: const Text('Fontes'), onTap: () => _irPara(_fontes)),
    ],
  );

  static int _nCitacoes(Json p) => (p['itens'] as List).where((i) => (i as Json)['tipo'] == 'cite').length;

  void _irPara(GlobalKey? chave) {
    final c = chave?.currentContext;
    if (c != null) Scrollable.ensureVisible(c, duration: const Duration(milliseconds: 300));
  }

  Widget _parte(BuildContext context, Json p, bool temGraficos) {
    final t = Theme.of(context).textTheme;
    return Padding(
      key: _ancoras.putIfAbsent(p['parte'] as int? ?? 0, GlobalKey.new),
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
          for (final it in p['itens'] as List) _item(context, it as Json, temGraficos),
        ],
      ),
    );
  }

  Widget _item(BuildContext context, Json it, bool temGraficos) {
    final cores = Theme.of(context).colorScheme;
    switch (it['tipo']) {
      case 'cena':
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 10,
          children: [
            const SeloMotor('py', rotulo: 'CENA'),
            Expanded(
              child: TextoMarcado(
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
              child: TextoMarcado('${it['texto']}', estilo: const TextStyle(fontSize: 15, height: 1.45)),
            ),
          ],
        );
      default:
        return Padding(padding: const EdgeInsets.only(left: 40), child: _citacao(context, it, temGraficos));
    }
  }

  Widget _citacao(BuildContext context, Json it, bool temGraficos) {
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
              onPressed: () => abrirUrl(context, widget.api.arquivo('${it['pdf']}')),
            ),
        ],
      ),
    );
    final recorte = rec == null
        ? const Padding(padding: EdgeInsets.all(24), child: Text('Sem recorte do PDF.'))
        : ColoredBox(
            color: Colors.white,
            child: _RecorteMarcado(url: widget.api.arquivo('${rec['url']}'), rects: rec['rects'] as List),
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
                        ? SeloEstado('ok', texto: 'trecho conferido · p. ${c['pagina']}')
                        : const SeloEstado('erro', texto: 'não achado no PDF'),
                    if (it['no_video'] == true)
                      const SeloEstado('rodando', texto: 'no vídeo')
                    else if (temGraficos)
                      const SeloEstado('pendente', texto: 'fora do vídeo (agenda cheia)'),
                  ],
                ),
              ],
            ),
          ),
          LayoutBuilder(
            builder: (context, area) => area.maxWidth < 700
                ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [recorte, texto])
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 11, child: recorte),
                      Expanded(flex: 10, child: texto),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _tabelaFontes(BuildContext context, List<Json> fontes) => Column(
    key: _fontes,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Secao('Fontes'),
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
              for (final f in fontes)
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
                              onPressed: () => abrirUrl(context, 'https://doi.org/${f['doi']}'),
                              child: Text('${f['doi']}'),
                            ),
                    ),
                    DataCell(
                      SeloEstado(
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

/// Recorte da página do PDF com os retângulos do marca-texto (em % do recorte) por cima.
class _RecorteMarcado extends StatelessWidget {
  const _RecorteMarcado({required this.url, required this.rects});

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
