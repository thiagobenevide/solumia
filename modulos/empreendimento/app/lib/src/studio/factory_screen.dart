import 'package:agent_core/agent_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../models.dart';
import '../screens/episode/final_video.dart';
import '../screens/util.dart';

/// Piece factory (Studio): requests to Claude, review queue (approve, adjust, variation, reject), library
/// gaps and log. Claude only works here; each video's production uses the local AI.
class FactoryScreen extends StatelessWidget {
  const FactoryScreen({super.key, required this.api});

  final ApiEsteira api;

  Future<Json> _load() async {
    final r = await Future.wait([api.pieceFactory(), api.libraryPieces(), api.studioChannels()]);
    return {'f': r[0], 'pecas': r[1], 'canais': r[2]};
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Estúdio · fábrica de peças')),
    body: Sondagem<Json>(
      intervalo: const Duration(seconds: 10),
      carregar: _load,
      construir: (context, d, recarregar) {
        final f = d['f'] as Json;
        final pieces = {for (final p in d['pecas'] as List) (p as Json)['id'] as String: p};
        final styles = [
          for (final c in d['canais'] as List)
            for (final e in ((c as Json)['estilos'] as List)) (e as Json)['id'] as String,
        ];
        final review = [for (final r in f['revisao'] as List) (r as Json)];
        final mediaLibrary = f['acervo'] as Json;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Acervo: ${mediaLibrary['aprovadas']} aprovada(s) · ${mediaLibrary['revisao']} em revisão · '
              'gasto da fábrica hoje US\$ ${(f['gasto_hoje'] as num).toStringAsFixed(2)}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 12),
            _NewRequest(api: api, onCreate: recarregar),
            Section('Revisão (${review.length})'),
            if (review.isEmpty)
              const Empty('Nada esperando você. As peças aprovadas no portão aparecem aqui.', icone: Icons.inbox_outlined),
            for (final r in review)
              if (pieces[r['id']] case final Json p)
                PieceReview(api: api, piece: p, request: r, styles: styles, aoMudar: recarregar),
            const Section('Pedidos'),
            for (final p in f['pedidos'] as List) _Request(api: api, p: p as Json, aoMudar: recarregar),
            if ((f['pedidos'] as List).isEmpty) const Text('Nenhum pedido ainda.'),
            const Section('Ampliação contínua'),
            _Expansion(api: api, a: f['ampliacao'] as Json, aoMudar: recarregar),
            const Section('Lacunas do acervo (intenção × peso)'),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final l in f['lacunas'] as List)
                  Chip(label: Text('${(l as Json)['intencao']} · ${l['peso']} (${l['tem']}/${(l['tem'] as int) + (l['falta'] as int)})')),
              ],
            ),
            const Section('Motores: HTML × EffectCraft'),
            _Comparison(api: api),
            const Section('Troca de pele entre canais'),
            _ChannelsProof(api: api, styles: styles),
            const Section('Registro'),
            for (final e in (f['registro'] as List).take(20))
              Text(
                '${'${(e as Json)['t']}'.replaceFirst('T', ' ')} · ${e['evento']} · ${e['peca'] ?? e['pedido'] ?? ''}'
                '${e['motivo'] != null ? ' · ${e['motivo']}' : ''}${e['custo'] != null ? ' · US\$ ${e['custo']}' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        );
      },
    ),
  );
}

class _NewRequest extends StatefulWidget {
  const _NewRequest({required this.api, required this.onCreate});

  final ApiEsteira api;
  final Future<void> Function() onCreate;

  @override
  State<_NewRequest> createState() => _NewRequestState();
}

class _NewRequestState extends State<_NewRequest> {
  String _kind = 'livre';
  final _text = TextEditingController();
  final _cap = TextEditingController(text: '3');
  int _count = 3;
  String _ref = '';
  String _engine = 'html';
  String _ai = 'claude';

  @override
  void dispose() {
    _text.dispose();
    _cap.dispose();
    super.dispose();
  }

  double get _capUsd => double.tryParse(_cap.text.replaceAll(',', '.')) ?? 3;

  Future<void> _chooseRef() async {
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['png', 'jpg', 'jpeg', 'webp']);
    if (files.isEmpty || !mounted) return;
    final a = files.first;
    final nome = await widget.api.sendFactoryReference(a.name, await a.xFile.readAsBytes());
    setState(() => _ref = nome);
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 10,
        children: [
          Text('Novo pedido', style: Theme.of(context).textTheme.titleMedium),
          _Options(
            options: const [
              ('livre', 'Livre', Icons.edit_note),
              ('referencia', 'Referência', Icons.image_outlined),
              ('lacunas', 'Preencher lacunas', Icons.grid_view),
            ],
            current: _kind,
            onChoose: (v) => setState(() => _kind = v),
          ),
          _Options(
            options: const [
              ('html', 'HTML', null),
              ('effectcraft', 'EffectCraft', null),
              ('ambos', 'Os dois (comparar)', null),
              ('auto', 'Automático', null),
            ],
            current: _ai == 'local' ? 'html' : _engine,
            onChoose: _ai == 'local' ? null : (v) => setState(() => _engine = v),
          ),
          // the local LLM does not spend the quota, but only writes HTML (the EffectCraft dossier does not fit in the context)
          _Options(
            options: const [
              ('claude', 'Claude', Icons.cloud_outlined),
              ('local', 'LLM local (só HTML)', Icons.memory),
            ],
            current: _ai,
            onChoose: (v) => setState(() => _ai = v),
          ),
          if (_kind != 'lacunas')
            TextField(
              controller: _text,
              minLines: 2,
              maxLines: 5,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: _kind == 'livre' ? 'O que gerar' : 'Observação sobre a referência (opcional)',
                hintText: _kind == 'livre' ? 'Ex.: 3 animações de linha do tempo com fotos de época' : null,
              ),
            ),
          if (_kind == 'referencia')
            Row(
              spacing: 8,
              children: [
                OutlinedButton.icon(onPressed: _chooseRef, icon: const Icon(Icons.upload), label: const Text('Enviar imagem')),
                Text(_ref.isEmpty ? 'nenhuma imagem' : _ref),
              ],
            ),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DropdownMenu<int>(
                label: const Text('Quantidade'),
                initialSelection: _count,
                dropdownMenuEntries: [for (final n in [1, 2, 3, 5, 8, 10]) DropdownMenuEntry(value: n, label: '$n')],
                onSelected: (v) => setState(() => _count = v ?? _count),
              ),
              SizedBox(
                width: 160,
                child: TextField(
                  controller: _cap,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Teto do dia (US\$)'),
                ),
              ),
              FilledButton.icon(
                icon: const Icon(Icons.auto_awesome),
                label: const Text('Gerar'),
                onPressed: () => actionWithWarning(context, () async {
                  final p = await widget.api.newFactoryRequest({
                    'tipo': _kind,
                    'texto': _text.text.trim(),
                    'quantidade': _count,
                    'teto_dia_usd': _capUsd,
                    'referencia': _ref,
                    'motor': _ai == 'local' ? 'html' : _engine,
                    'ia': _ai,
                  });
                  _text.clear();
                  await widget.onCreate();
                  return 'Pedido ${p['id']} na fila ${_ai == 'local' ? 'do LLM local' : 'do Claude'}';
                }),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.format_quote),
                label: const Text('Primeira peça: citação de PDF'),
                onPressed: () => actionWithWarning(context, () async {
                  await widget.api.requestQuote(cap: _capUsd, engine: _engine);
                  await widget.onCreate();
                  return 'Pedido da citação de PDF na fila do Claude';
                }),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// Single choice in wrapping chips: the SegmentedButton squeezed the labels letter by letter on the phone.
class _Options extends StatelessWidget {
  const _Options({required this.options, required this.current, required this.onChoose});

  final List<(String, String, IconData?)> options;
  final String current;
  final ValueChanged<String>? onChoose;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final (valor, label, icone) in options)
        ChoiceChip(
          avatar: icone == null || valor == current ? null : Icon(icone, size: 18),
          label: Text(label),
          selected: valor == current,
          onSelected: onChoose == null ? null : (_) => onChoose!(valor),
        ),
    ],
  );
}

class _Request extends StatelessWidget {
  const _Request({required this.api, required this.p, required this.aoMudar});

  final ApiEsteira api;
  final Json p;
  final Future<void> Function() aoMudar;

  @override
  Widget build(BuildContext context) {
    final pausado = p['estado'] == 'pausado';
    final label = p['tipo'] == 'lacunas' ? 'Preencher lacunas' : '${p['texto']}';
    return Card(
      child: ListTile(
        title: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${p['estado']} · ${(p['pecas'] as List).length}/${p['quantidade']} peça(s) · ${p['descartadas']} descartada(s) · '
          'US\$ ${(p['gasto_usd'] as num).toStringAsFixed(2)}${(p['tarefas'] as List).isNotEmpty ? ' · ${(p['tarefas'] as List).length} tarefa(s)' : ''}'
          '\n${p['situacao']}',
        ),
        isThreeLine: true,
        trailing: Wrap(
          children: [
            IconButton(
              tooltip: pausado ? 'Retomar' : 'Pausar',
              icon: Icon(pausado ? Icons.play_arrow : Icons.pause),
              onPressed: () => actionWithWarning(context, () async {
                await api.pauseRequest(p['id'] as String, !pausado);
                await aoMudar();
                return pausado ? 'Retomado' : 'Pausado';
              }),
            ),
            IconButton(
              tooltip: 'Rodar agora',
              icon: const Icon(Icons.refresh),
              onPressed: () => actionWithWarning(context, () async {
                await api.runRequest(p['id'] as String);
                return 'Pedido na fila';
              }),
            ),
          ],
        ),
      ),
    );
  }
}

class PieceReview extends StatefulWidget {
  const PieceReview({super.key, required this.api, required this.piece, required this.request, required this.styles, required this.aoMudar});

  final ApiEsteira api;
  final Json piece;
  final Json request;
  final List<String> styles;
  final Future<void> Function() aoMudar;

  @override
  State<PieceReview> createState() => PieceReviewState();
}

class PieceReviewState extends State<PieceReview> {
  String? _style;
  int? _note;
  List<Json> _previews = const [];

  String get _id => widget.piece['id'] as String;

  @override
  void initState() {
    super.initState();
    _loadPreviews();
  }

  Future<void> _loadPreviews() async {
    final l = await widget.api.piecePreviews(_id);
    if (mounted) setState(() => _previews = [for (final p in l) p as Json]);
  }

  Future<String?> _askText(String titulo, String dica) => showDialog<String>(
    context: context,
    builder: (context) {
      final c = TextEditingController();
      return AlertDialog(
        title: Text(titulo),
        content: TextField(controller: c, autofocus: true, minLines: 2, maxLines: 4, decoration: InputDecoration(hintText: dica)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, c.text.trim()), child: const Text('Enviar')),
        ],
      );
    },
  );

  Future<void> _review(String acao, String aviso, {String? titulo, String dica = ''}) async {
    var texto = '';
    if (titulo != null) {
      final t = await _askText(titulo, dica);
      if (t == null || t.isEmpty || !mounted) return;
      texto = t;
    }
    await actionWithWarning(context, () async {
      await widget.api.reviewPiece(_id, acao, texto, acao == 'aprovar' || acao == 'reprovar' ? _note : null);
      await widget.aoMudar();
      return aviso;
    });
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.piece['ficha'] as Json;
    final frames = [for (final q in widget.piece['quadros'] as List) q as String];
    final pequeno = Theme.of(context).textTheme.bodySmall;
    final estilo = _style ?? widget.styles.firstOrNull;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('$_id · v${card['versao']}', style: Theme.of(context).textTheme.titleMedium),
                Chip(label: Text(card['motor'] == 'effectcraft' ? 'EffectCraft' : 'HTML')),
                if (widget.request['par'] != null) Text('par de ${widget.request['par']}', style: pequeno),
              ],
            ),
            Text('${card['comunica']}'),
            Text(
              'intenções: ${(card['intencoes'] as List).join(', ')} · peso ${card['peso']} · ${(card['formatos'] as List).join(' / ')} · '
              '${card['duracao_min']}–${card['duracao_max']} s · tom ${(card['tom'] as List).join(', ')} · energia ${card['energia']}',
              style: pequeno,
            ),
            if ('${card['notas'] ?? ''}'.isNotEmpty) Text('Notas: ${card['notas']}', style: pequeno),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                spacing: 8,
                children: [
                  for (final q in frames)
                    Column(
                      children: [
                        SizedBox(
                          height: 220,
                          child: Image.network(widget.api.arquivo(q.replaceFirst('/', '')), fit: BoxFit.contain),
                        ),
                        Text(q.split('/').last.replaceAll('.jpg', '').replaceAll('_', ' · '), style: pequeno),
                      ],
                    ),
                ],
              ),
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Ficha: encaixes, botões e exemplos'),
              children: [
                for (final e in card['encaixes'] as List)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '• ${(e as Json)['nome']} (${e['tipo']}${e['tipo'] == 'itens' ? ', ${e['min_itens']}–${e['max_itens']} itens' : ''}, '
                      'até ${e['max_car']} car.${e['obrigatorio'] == true ? '' : ', opcional'}): ${e['descricao']}',
                    ),
                  ),
                for (final b in card['botoes'] as List)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text('◦ ${(b as Json)['nome']}: ${(b['valores'] as List).join(' / ')} (padrão ${b['padrao']})'),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Serve para: ${(card['exemplos_sim'] as List).join(' | ')}', style: pequeno),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Não serve para: ${(card['exemplos_nao'] as List).join(' | ')}', style: pequeno),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (widget.styles.isNotEmpty)
                  DropdownMenu<String>(
                    label: const Text('Prévia na pele de'),
                    initialSelection: estilo,
                    dropdownMenuEntries: [for (final e in widget.styles) DropdownMenuEntry(value: e, label: e)],
                    onSelected: (v) => setState(() => _style = v),
                  ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.movie_outlined),
                  label: const Text('Gerar prévia animada'),
                  onPressed: estilo == null
                      ? null
                      : () => actionWithWarning(context, () async {
                          await widget.api.piecePreview(_id, estilo);
                          return 'Prévia na fila (alguns segundos na GPU); toque em atualizar depois';
                        }),
                ),
                IconButton(tooltip: 'Atualizar prévias', onPressed: _loadPreviews, icon: const Icon(Icons.refresh)),
              ],
            ),
            if (_previews.isNotEmpty)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  spacing: 12,
                  children: [
                    for (final p in _previews)
                      Column(
                        children: [
                          SizedBox(
                            width: '${p['nome']}'.endsWith('9x16') ? 200 : 420,
                            height: '${p['nome']}'.endsWith('9x16') ? 356 : 236,
                            child: VideoFinal(
                              url: widget.api.arquivo('${p['url']}'.replaceFirst('/', '')),
                              vertical: '${p['nome']}'.endsWith('9x16'),
                            ),
                          ),
                          Text('${p['nome']}', style: pequeno),
                        ],
                      ),
                  ],
                ),
              ),
            Wrap(
              spacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('Nota (compara os motores):', style: pequeno),
                for (final n in [1, 2, 3, 4, 5])
                  ChoiceChip(label: Text('$n'), selected: _note == n, onSelected: (v) => setState(() => _note = v ? n : null)),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.check),
                  label: const Text('Aprovar'),
                  onPressed: () => _review('aprovar', '$_id entrou no acervo'),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.tune),
                  label: const Text('Pedir ajuste'),
                  onPressed: () => _review('ajuste', 'Ajuste na fila do Claude',
                      titulo: 'O que ajustar em $_id?', dica: 'Ex.: entrada mais lenta, número maior, sem o anel'),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.copy_all),
                  label: const Text('Variação'),
                  onPressed: () => _review('variacao', 'Variação na fila do Claude'),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.close),
                  label: const Text('Reprovar'),
                  onPressed: () => _review('reprovar', 'Reprovada; o motivo vira regra para as próximas',
                      titulo: 'Por que reprovar $_id?', dica: 'O motivo entra no guia e o Claude evita nas próximas'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Skin swap proof: every approved piece in the skin of each chosen style, with the sheets and the problems.
class _ChannelsProof extends StatefulWidget {
  const _ChannelsProof({required this.api, required this.styles});

  final ApiEsteira api;
  final List<String> styles;

  @override
  State<_ChannelsProof> createState() => _ChannelsProofState();
}

class _ChannelsProofState extends State<_ChannelsProof> {
  final _sel = <String>{};
  Json? _r;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await widget.api.resultChannelsProof();
    if (mounted) setState(() => _r = r);
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    final problems = [for (final p in (r?['problemas'] as List?) ?? const []) p as Json];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final e in widget.styles)
              FilterChip(
                label: Text(e),
                selected: _sel.contains(e),
                onSelected: (v) => setState(() => v ? _sel.add(e) : _sel.remove(e)),
              ),
          ],
        ),
        Row(
          spacing: 8,
          children: [
            FilledButton.tonalIcon(
              icon: const Icon(Icons.palette_outlined),
              label: const Text('Provar as peças nessas peles'),
              onPressed: _sel.isEmpty
                  ? null
                  : () => actionWithWarning(context, () async {
                      await widget.api.channelsProof(_sel.toList());
                      return 'Prova na fila (cerca de 1 min por estilo); toque em atualizar depois';
                    }),
            ),
            IconButton(tooltip: 'Atualizar', onPressed: _load, icon: const Icon(Icons.refresh)),
          ],
        ),
        if (r != null && (r['folhas'] as List).isNotEmpty) ...[
          Text(
            '${(r['pecas'] as List).length} peça(s) em ${(r['estilos'] as List).join(', ')} · '
            '${problems.isEmpty ? 'nenhum problema' : '${problems.length} problema(s)'}',
          ),
          for (final p in problems) Text('• ${p['peca']} · ${p['estilo']} · ${p['formato']}: ${p['erro']}'),
          for (final f in r['folhas'] as List)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$f'.split('/').last, style: Theme.of(context).textTheme.bodySmall),
                Image.network(widget.api.arquivo('$f'.replaceFirst('/', ''))),
              ],
            ),
        ],
      ],
    );
  }
}

/// Engine comparison (from the factory log) and the engine decision per intent.
class _Comparison extends StatefulWidget {
  const _Comparison({required this.api});

  final ApiEsteira api;

  @override
  State<_Comparison> createState() => _ComparisonState();
}

class _ComparisonState extends State<_Comparison> {
  Json? _c;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final c = await widget.api.enginesComparison();
    if (mounted) setState(() => _c = c);
  }

  static const _lines = [
    ('geradas', 'Geradas'),
    ('descartadas', 'Descartadas no portão'),
    ('taxa_portao', 'Passaram no portão'),
    ('rodadas_media', 'Rodadas do Claude'),
    ('custo_medio', 'Custo médio (US\$)'),
    ('segundos_medio', 'Tempo de geração (s)'),
    ('render_s_medio', 'Render da prova (s)'),
    ('taxa_aprovacao', 'Aprovação sua'),
    ('nota_media', 'Nota média'),
    ('pele_problemas', 'Problemas na troca de pele'),
  ];

  String _v(Object? v) => v == null ? '—' : (v is double && v <= 1 && v >= 0 ? '${(v * 100).round()}%' : '$v');

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null) return const LinearProgressIndicator();
    final general = c['geral'] as Json;
    final sug = c['sugestao'] as Json;
    final decision = ((c['decisao'] as Json)['por_intencao'] as Json?) ?? const {};
    final aplicaveis = {
      for (final e in sug.entries)
        if ((e.value as Json)['motor'] != null) e.key: (e.value as Json)['motor'] as String,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: const [DataColumn(label: Text('')), DataColumn(label: Text('HTML')), DataColumn(label: Text('EffectCraft'))],
            rows: [
              for (final (k, rot) in _lines)
                DataRow(cells: [
                  DataCell(Text(rot)),
                  DataCell(Text(k == 'custo_medio' || k == 'render_s_medio' || k == 'segundos_medio' || k == 'rodadas_media' || k == 'nota_media'
                      ? '${(general['html'] as Json)[k] ?? '—'}'
                      : _v((general['html'] as Json)[k]))),
                  DataCell(Text(k == 'custo_medio' || k == 'render_s_medio' || k == 'segundos_medio' || k == 'rodadas_media' || k == 'nota_media'
                      ? '${(general['effectcraft'] as Json)[k] ?? '—'}'
                      : _v((general['effectcraft'] as Json)[k]))),
                ]),
            ],
          ),
        ),
        Text('Por intenção (sugestão a partir de ${c['amostra_min']} peças revisadas por motor):',
            style: Theme.of(context).textTheme.titleSmall),
        for (final e in sug.entries)
          Text('• ${e.key}: ${(e.value as Json)['motor'] ?? 'sem sugestão'} — ${(e.value as Json)['motivo']}'
              '${decision[e.key] != null ? ' · decidido: ${decision[e.key]}' : ''}'),
        if (sug.isEmpty) const Text('Ainda sem peças revisadas. Gere pedidos com "Os dois (comparar)" e dê nota na revisão.'),
        Text('${c['pendente']}', style: Theme.of(context).textTheme.bodySmall),
        Row(
          spacing: 8,
          children: [
            FilledButton.tonalIcon(
              icon: const Icon(Icons.rule),
              label: Text('Aplicar sugestão (${aplicaveis.length} intenção(ões))'),
              onPressed: aplicaveis.isEmpty
                  ? null
                  : () => actionWithWarning(context, () async {
                      await widget.api.applyEngines(aplicaveis);
                      await _load();
                      return 'Decisão aplicada: os pedidos em Automático usam esse motor por intenção';
                    }),
            ),
            IconButton(tooltip: 'Atualizar', onPressed: _load, icon: const Icon(Icons.refresh)),
          ],
        ),
      ],
    );
  }
}

/// Continuous growth: the library grows on its own from the gaps (one request per day), you keep approving everything.
class _Expansion extends StatelessWidget {
  const _Expansion({required this.api, required this.a, required this.aoMudar});

  final ApiEsteira api;
  final Json a;
  final Future<void> Function() aoMudar;

  Future<void> _save(BuildContext context, Json mudanca) => actionWithWarning(context, () async {
    final r = await api.saveExpansion({...a, ...mudanca});
    await aoMudar();
    return r['ativo'] == true ? 'Ampliação ligada (agora: ${r['agora']})' : 'Ampliação desligada';
  });

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Ampliar o acervo pelas lacunas todo dia'),
            subtitle: const Text('Um pedido de lacunas por dia (inclui 2,5D), dentro do teto; pausa se a revisão acumular'),
            value: a['ativo'] == true,
            onChanged: (v) => _save(context, {'ativo': v}),
          ),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DropdownMenu<int>(
                label: const Text('Peças por dia'),
                initialSelection: (a['pecas_por_dia'] as num).toInt(),
                dropdownMenuEntries: [for (final n in [1, 2, 3, 5, 8]) DropdownMenuEntry(value: n, label: '$n')],
                onSelected: (v) => v == null ? null : _save(context, {'pecas_por_dia': v}),
              ),
              DropdownMenu<double>(
                label: const Text('Teto do dia (US\$)'),
                initialSelection: (a['teto_dia_usd'] as num).toDouble(),
                dropdownMenuEntries: [for (final n in [1.0, 2.0, 3.0, 5.0]) DropdownMenuEntry(value: n, label: n.toStringAsFixed(0))],
                onSelected: (v) => v == null ? null : _save(context, {'teto_dia_usd': v}),
              ),
              DropdownMenu<String>(
                label: const Text('Motor'),
                initialSelection: '${a['motor']}',
                dropdownMenuEntries: const [
                  DropdownMenuEntry(value: 'auto', label: 'Automático'),
                  DropdownMenuEntry(value: 'html', label: 'HTML'),
                  DropdownMenuEntry(value: 'effectcraft', label: 'EffectCraft'),
                  DropdownMenuEntry(value: 'ambos', label: 'Os dois'),
                ],
                onSelected: (v) => v == null ? null : _save(context, {'motor': v}),
              ),
              DropdownMenu<int>(
                label: const Text('Pausa com N na revisão'),
                initialSelection: (a['revisao_max'] as num).toInt(),
                dropdownMenuEntries: [for (final n in [4, 8, 12, 20]) DropdownMenuEntry(value: n, label: '$n')],
                onSelected: (v) => v == null ? null : _save(context, {'revisao_max': v}),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
