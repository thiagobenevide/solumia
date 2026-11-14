import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../modelos.dart';
import 'episodio/episodio_tela.dart';
import 'util.dart';

/// Episódios de todos os canais (ou de um), com o andamento ao vivo.
class ProducaoAba extends StatefulWidget {
  const ProducaoAba({super.key, required this.api});

  final ApiEsteira api;

  @override
  State<ProducaoAba> createState() => _ProducaoAbaState();
}

class _ProducaoAbaState extends State<ProducaoAba> {
  late final Future<List<Canal>> _canais = widget.api.canais();
  String _canal = '';

  @override
  Widget build(BuildContext context) => Column(
    children: [
      FutureBuilder(
        future: _canais,
        builder: (context, s) => Align(
          alignment: Alignment.centerLeft,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Todos'),
                  selected: _canal.isEmpty,
                  onSelected: (_) => _escolher(''),
                ),
                for (final c in s.data ?? const <Canal>[])
                  ChoiceChip(
                    label: Text('${c.id} · ${c.episodios}'),
                    selected: _canal == c.id,
                    onSelected: (_) => _escolher(c.id),
                  ),
              ],
            ),
          ),
        ),
      ),
      Expanded(
        child: Sondagem<List<EpisodioResumo>>(
          key: ValueKey(_canal),
          intervalo: const Duration(seconds: 5),
          carregar: () => widget.api.episodios(canal: _canal),
          construir: (context, eps, _) => eps.isEmpty
              ? const Vazio('Nenhum episódio ainda.\nEscolha roteiros na aba Roteiros e mande produzir.')
              : LayoutBuilder(
                  builder: (context, area) {
                    // Altura do cartão segue a largura da coluna: thumb 16:9 + o bloco de texto.
                    const margem = 16.0, espaco = 12.0;
                    final colunas = ((area.maxWidth - 2 * margem + espaco) / (380 + espaco)).ceil().clamp(
                      1,
                      8,
                    );
                    final largura = (area.maxWidth - 2 * margem - espaco * (colunas - 1)) / colunas;
                    return GridView.builder(
                      padding: const EdgeInsets.all(margem),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: colunas,
                        mainAxisExtent: largura * 9 / 16 + 130,
                        crossAxisSpacing: espaco,
                        mainAxisSpacing: espaco,
                      ),
                      itemCount: eps.length,
                      itemBuilder: (context, i) => _CartaoEpisodio(api: widget.api, ep: eps[i]),
                    );
                  },
                ),
        ),
      ),
    ],
  );

  void _escolher(String canal) => setState(() => _canal = canal);
}

class _CartaoEpisodio extends StatelessWidget {
  const _CartaoEpisodio({required this.api, required this.ep});

  final ApiEsteira api;
  final EpisodioResumo ep;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final p = ep.prog;
    return Card(
      child: InkWell(
        onTap: () => abrirTela(context, (_) => EpisodioTela(api: api, ep: ep.id, titulo: ep.titulo)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ep.thumbs.isEmpty
                  ? ColoredBox(
                      color: tema.colorScheme.surfaceContainerHighest,
                      child: Icon(Icons.image_outlined, size: 40, color: tema.colorScheme.outline),
                    )
                  : Image.network(api.arquivo(ep.thumbs.first.url), fit: BoxFit.cover),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 6,
                children: [
                  Text(
                    ep.titulo,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: tema.textTheme.titleSmall,
                  ),
                  Text('${ep.canal} · ${ep.numero}', style: tema.textTheme.bodySmall),
                  LinearProgressIndicator(value: p.fracao, color: corDoEstado(tema.colorScheme, p.estado)),
                  Text(
                    p.rodando != null
                        ? 'Rodando: ${p.rodando} · ${p.feitas}/${p.total}'
                        : p.erro != null
                        ? 'Erro em ${p.erro} · ${p.feitas}/${p.total}'
                        : p.finalPronto
                        ? (p.desatualizado ? 'Pronto, mas o vídeo está desatualizado' : 'Vídeo pronto')
                        : '${p.feitas}/${p.total} etapas',
                    style: tema.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
