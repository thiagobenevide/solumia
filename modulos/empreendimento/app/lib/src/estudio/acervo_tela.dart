import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../modelos.dart';
import '../telas/util.dart';
import 'fabrica_tela.dart';

/// Acervo de peças (Estúdio): galeria com o quadro da prova, filtro pela ficha (estado, peso, motor, intenção, busca) e,
/// ao abrir, a ficha legível, os quadros nas duas peles, a prévia animada na pele de qualquer canal e as ações.
class AcervoTela extends StatefulWidget {
  const AcervoTela({super.key, required this.api});

  final ApiEsteira api;

  @override
  State<AcervoTela> createState() => _AcervoTelaState();
}

class _AcervoTelaState extends State<AcervoTela> {
  String _estado = 'todas', _peso = 'todos', _motor = 'todos', _intencao = 'todas', _busca = '';

  Future<Json> _carregar() async {
    final r = await Future.wait([widget.api.pecasAcervo(), widget.api.estudioCanais()]);
    return {'pecas': r[0], 'canais': r[1]};
  }

  bool _passa(Json p) {
    final f = p['ficha'] as Json;
    final texto = '${p['id']} ${f['comunica'] ?? ''} ${(f['exemplos_sim'] as List?)?.join(' ') ?? ''}'.toLowerCase();
    return (_estado == 'todas' || f['estado'] == _estado) &&
        (_peso == 'todos' || f['peso'] == _peso) &&
        (_motor == 'todos' || f['motor'] == _motor) &&
        (_intencao == 'todas' || ((f['intencoes'] as List?) ?? const []).contains(_intencao)) &&
        (_busca.isEmpty || texto.contains(_busca.toLowerCase()));
  }

  Widget _filtro(String rotulo, String valor, List<String> opcoes, ValueChanged<String> mudar) => DropdownMenu<String>(
    label: Text(rotulo),
    initialSelection: valor,
    dropdownMenuEntries: [for (final o in opcoes) DropdownMenuEntry(value: o, label: o)],
    onSelected: (v) => setState(() => mudar(v ?? valor)),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Estúdio · acervo de peças')),
    body: Sondagem<Json>(
      intervalo: const Duration(seconds: 30),
      carregar: _carregar,
      construir: (context, d, recarregar) {
        final todas = [for (final p in d['pecas'] as List) p as Json];
        final estilos = [
          for (final c in d['canais'] as List)
            for (final e in ((c as Json)['estilos'] as List)) (e as Json)['id'] as String,
        ];
        final intencoes = {for (final p in todas) ...(((p['ficha'] as Json)['intencoes'] as List?) ?? const []).map((x) => '$x')}.toList()..sort();
        final lista = todas.where(_passa).toList();
        final cont = {for (final e in ['aprovada', 'revisao', 'rascunho']) e: todas.where((p) => (p['ficha'] as Json)['estado'] == e).length};
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('${todas.length} peças · ${cont['aprovada']} aprovadas · ${cont['revisao']} em revisão · ${cont['rascunho']} em rascunho',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _filtro('Estado', _estado, ['todas', 'aprovada', 'revisao', 'rascunho'], (v) => _estado = v),
                _filtro('Peso', _peso, ['todos', 'texto', '2d', '2_5d', '3d', 'midia'], (v) => _peso = v),
                _filtro('Motor', _motor, ['todos', 'html', 'effectcraft'], (v) => _motor = v),
                _filtro('Intenção', _intencao, ['todas', ...intencoes], (v) => _intencao = v),
                SizedBox(
                  width: 240,
                  child: TextField(
                    decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Buscar (id, o que comunica, exemplos)'),
                    onChanged: (v) => setState(() => _busca = v.trim()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (lista.isEmpty) const Vazio('Nenhuma peça com esse filtro.', icone: Icons.filter_alt_off),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [for (final p in lista) _Cartao(api: widget.api, p: p, estilos: estilos, aoMudar: recarregar)],
            ),
          ],
        );
      },
    ),
  );
}

class _Cartao extends StatelessWidget {
  const _Cartao({required this.api, required this.p, required this.estilos, required this.aoMudar});

  final ApiEsteira api;
  final Json p;
  final List<String> estilos;
  final Future<void> Function() aoMudar;

  @override
  Widget build(BuildContext context) {
    final f = p['ficha'] as Json;
    final quadros = [for (final q in (p['quadros'] as List?) ?? const []) '$q'];
    final capa = quadros.where((q) => q.contains('escura_16x9')).firstOrNull ?? quadros.firstOrNull;
    final pequeno = Theme.of(context).textTheme.bodySmall;
    final cor = {'aprovada': Colors.green, 'revisao': Colors.amber, 'rascunho': Colors.grey}[f['estado']] ?? Colors.grey;
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
                  children: [PecaRevisao(api: api, peca: p, pedido: const {}, estilos: estilos, aoMudar: aoMudar)],
                ),
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: capa == null
                    ? const ColoredBox(color: Colors.black12, child: Center(child: Text('sem prova')))
                    : Image.network(api.arquivo(capa.replaceFirst('/', '')), fit: BoxFit.cover),
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
                        Icon(Icons.circle, size: 10, color: cor),
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
