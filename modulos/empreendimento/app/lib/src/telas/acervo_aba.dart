import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../modelos.dart';
import 'util.dart';

/// Acervo: toda mídia baixada dos bancos, com crédito, termos, descrição do modelo de visão e onde já foi
/// usada. A busca de mídia consulta o acervo antes das APIs.
class AcervoAba extends StatefulWidget {
  const AcervoAba({super.key, required this.api});

  final ApiEsteira api;

  @override
  State<AcervoAba> createState() => _AcervoAbaState();
}

class _AcervoAbaState extends State<AcervoAba> {
  final _q = TextEditingController();
  String _tipo = '';
  late Future<Json> _dados = widget.api.acervo();

  void _buscar() => setState(() { _dados = widget.api.acervo(q: _q.text.trim(), tipo: _tipo); });

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomScrollView(
    slivers: [
      SliverPadding(
        padding: const EdgeInsets.all(16),
        sliver: SliverList.list(
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 340,
                  child: TextField(
                    controller: _q,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      hintText: 'buscar (inglês): credit card, debt, city night…',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onSubmitted: (_) => _buscar(),
                  ),
                ),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: '', label: Text('Tudo')),
                    ButtonSegment(value: 'video', label: Text('Vídeos')),
                    ButtonSegment(value: 'imagem', label: Text('Imagens')),
                  ],
                  selected: {_tipo},
                  onSelectionChanged: (v) {
                    _tipo = v.first;
                    _buscar();
                  },
                ),
                FilledButton(onPressed: _buscar, child: const Text('Buscar')),
              ],
            ),
            const SizedBox(height: 6),
            const Wrap(
              spacing: 6,
              children: [
                SeloMotor('py', rotulo: 'busca: Python (SQLite)'),
                SeloMotor('local', rotulo: 'descrições: visão local'),
              ],
            ),
          ],
        ),
      ),
      FutureBuilder(
        future: _dados,
        builder: (context, s) {
          if (s.hasError) return SliverToBoxAdapter(child: Vazio('${s.error}'));
          final d = s.data;
          if (d == null) return const SliverToBoxAdapter(child: Center(child: CircularProgressIndicator()));
          final e = d['estatisticas'] as Json;
          final itens = [for (final it in d['itens'] as List) it as Json];
          return SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            sliver: SliverMainAxisGroup(
              slivers: [
                SliverToBoxAdapter(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Indicador('Itens', '${e['itens']}', sub: '${e['gb']} GB em disco'),
                      Indicador('Vídeos', '${e['videos']}', sub: 'clipes guardados'),
                      Indicador('Imagens', '${e['imagens']}', sub: 'fotos guardadas'),
                      Indicador('Descritos', '${e['descritos']}', sub: 'pelo modelo de visão local'),
                      Indicador('Usos', '${e['usos']}', sub: '${e['reusados']} mídias já usadas'),
                    ],
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 16)),
                if (itens.isEmpty)
                  SliverToBoxAdapter(
                    child: Vazio(
                      _q.text.isEmpty
                          ? 'Acervo vazio: rode ./dark acervo importar ou produza um episódio.'
                          : 'Nada encontrado para "${_q.text}".',
                    ),
                  ),
                SliverGrid.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 320,
                    mainAxisExtent: 320,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: itens.length,
                  itemBuilder: (context, i) => _item(context, itens[i]),
                ),
              ],
            ),
          );
        },
      ),
    ],
  );

  Widget _item(BuildContext context, Json it) {
    final usos = it['usos'] as List? ?? const [];
    final video = it['tipo'] == 'video';
    final pequeno = Theme.of(context).textTheme.bodySmall;
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.network(
                  widget.api.arquivo('${it['mini']}'),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black26),
                ),
                Positioned(top: 6, left: 6, child: _etiqueta('${it['provedor']}')),
                Positioned(
                  top: 6,
                  right: 6,
                  child: _etiqueta(video ? '▶ ${(it['duracao'] as num? ?? 0).round()}s' : 'foto'),
                ),
                if (usos.isNotEmpty)
                  Positioned(
                    bottom: 6,
                    right: 6,
                    child: _etiqueta('${usos.length} uso${usos.length > 1 ? 's' : ''}'),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: [
                  if ('${it['descricao'] ?? ''}'.isNotEmpty)
                    Text('${it['descricao']}', maxLines: 2, overflow: TextOverflow.ellipsis),
                  Text(
                    'termos: ${(it['termos'] as List? ?? const []).join(' · ')}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: pequeno,
                  ),
                  Text('${it['largura']}×${it['altura']} · ${it['orientacao']}', style: pequeno),
                  if (usos.isNotEmpty)
                    Text(
                      'usado em: ${usos.take(3).map((u) => (u as Json)['ep']).join(', ')}',
                      overflow: TextOverflow.ellipsis,
                      style: pequeno,
                    ),
                  if (it['pagina'] != null)
                    InkWell(
                      onTap: () => abrirUrl(context, '${it['pagina']}'),
                      child: Text(
                        '${it['licenca'] ?? 'fonte'} ↗',
                        style: pequeno?.copyWith(color: Theme.of(context).colorScheme.primary),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _etiqueta(String t) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(4)),
    child: Text(t, style: const TextStyle(fontSize: 10, color: Colors.white)),
  );
}
