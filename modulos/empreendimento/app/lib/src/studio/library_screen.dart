import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../models.dart';
import '../screens/util.dart';
import 'factory_screen.dart';

/// Piece library (Studio): gallery with the proof frame, filter by the sheet (state, weight, engine, intent, search) and,
/// when opened, the readable sheet, the frames in both skins, the animated preview in any channel's skin and the actions.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.api});

  final ApiEsteira api;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  String _state = 'todas', _weight = 'todos', _engine = 'todos', _intent = 'todas', _search = '';

  Future<Json> _load() async {
    final r = await Future.wait([widget.api.libraryPieces(), widget.api.studioChannels()]);
    return {'pecas': r[0], 'canais': r[1]};
  }

  bool _passa(Json p) {
    final f = p['ficha'] as Json;
    final texto = '${p['id']} ${f['comunica'] ?? ''} ${(f['exemplos_sim'] as List?)?.join(' ') ?? ''}'.toLowerCase();
    return (_state == 'todas' || f['estado'] == _state) &&
        (_weight == 'todos' || f['peso'] == _weight) &&
        (_engine == 'todos' || f['motor'] == _engine) &&
        (_intent == 'todas' || ((f['intencoes'] as List?) ?? const []).contains(_intent)) &&
        (_search.isEmpty || texto.contains(_search.toLowerCase()));
  }

  Widget _filter(String label, String valor, List<String> options, ValueChanged<String> change) => DropdownMenu<String>(
    label: Text(label),
    initialSelection: valor,
    dropdownMenuEntries: [for (final o in options) DropdownMenuEntry(value: o, label: o)],
    onSelected: (v) => setState(() => change(v ?? valor)),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Estúdio · acervo de peças')),
    body: Sondagem<Json>(
      intervalo: const Duration(seconds: 30),
      carregar: _load,
      construir: (context, d, recarregar) {
        final all = [for (final p in d['pecas'] as List) p as Json];
        final styles = [
          for (final c in d['canais'] as List)
            for (final e in ((c as Json)['estilos'] as List)) (e as Json)['id'] as String,
        ];
        final intents = {for (final p in all) ...(((p['ficha'] as Json)['intencoes'] as List?) ?? const []).map((x) => '$x')}.toList()..sort();
        final list = all.where(_passa).toList();
        final cont = {for (final e in ['aprovada', 'revisao', 'rascunho']) e: all.where((p) => (p['ficha'] as Json)['estado'] == e).length};
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('${all.length} peças · ${cont['aprovada']} aprovadas · ${cont['revisao']} em revisão · ${cont['rascunho']} em rascunho',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _filter('Estado', _state, ['todas', 'aprovada', 'revisao', 'rascunho'], (v) => _state = v),
                _filter('Peso', _weight, ['todos', 'texto', '2d', '2_5d', '3d', 'midia'], (v) => _weight = v),
                _filter('Motor', _engine, ['todos', 'html', 'effectcraft'], (v) => _engine = v),
                _filter('Intenção', _intent, ['todas', ...intents], (v) => _intent = v),
                SizedBox(
                  width: 240,
                  child: TextField(
                    decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Buscar (id, o que comunica, exemplos)'),
                    onChanged: (v) => setState(() => _search = v.trim()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (list.isEmpty) const Empty('Nenhuma peça com esse filtro.', icone: Icons.filter_alt_off),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [for (final p in list) _Card(api: widget.api, p: p, styles: styles, aoMudar: recarregar)],
            ),
          ],
        );
      },
    ),
  );
}

class _Card extends StatelessWidget {
  const _Card({required this.api, required this.p, required this.styles, required this.aoMudar});

  final ApiEsteira api;
  final Json p;
  final List<String> styles;
  final Future<void> Function() aoMudar;

  @override
  Widget build(BuildContext context) {
    final f = p['ficha'] as Json;
    final frames = [for (final q in (p['quadros'] as List?) ?? const []) '$q'];
    final cover = frames.where((q) => q.contains('escura_16x9')).firstOrNull ?? frames.firstOrNull;
    final pequeno = Theme.of(context).textTheme.bodySmall;
    final color = {'aprovada': Colors.green, 'revisao': Colors.amber, 'rascunho': Colors.grey}[f['estado']] ?? Colors.grey;
    return SizedBox(
      width: 300,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                appBar: AppBar(title: Text('${p['id']}')),
                body: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [PieceReview(api: api, piece: p, request: const {}, styles: styles, aoMudar: aoMudar)],
                ),
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: cover == null
                    ? const ColoredBox(color: Colors.black12, child: Center(child: Text('sem prova')))
                    : Image.network(api.arquivo(cover.replaceFirst('/', '')), fit: BoxFit.cover),
              ),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 4,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text('${p['id']}', style: Theme.of(context).textTheme.titleSmall, overflow: TextOverflow.ellipsis)),
                        Icon(Icons.circle, size: 10, color: color),
                        const SizedBox(width: 4),
                        Text('${f['estado']}', style: pequeno),
                      ],
                    ),
                    Text('${f['comunica'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis, style: pequeno),
                    Text('${f['peso'] ?? ''} · ${f['motor'] == 'effectcraft' ? 'EffectCraft' : 'HTML'} · '
                        '${((f['intencoes'] as List?) ?? const []).join(', ')}', style: pequeno),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
