import 'package:agent_core/agent_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../modelos.dart';
import '../telas/episodio/video_final.dart';
import '../telas/util.dart';

/// Fábrica de peças (Estúdio): pedidos ao Claude, fila de revisão (aprovar, ajuste, variação, reprovar), lacunas do
/// acervo e registro. O Claude só trabalha aqui; a produção de cada vídeo usa a IA local.
class FabricaTela extends StatelessWidget {
  const FabricaTela({super.key, required this.api});

  final ApiEsteira api;

  Future<Json> _carregar() async {
    final r = await Future.wait([api.fabrica(), api.pecasAcervo(), api.estudioCanais()]);
    return {'f': r[0], 'pecas': r[1], 'canais': r[2]};
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Estúdio · fábrica de peças')),
    body: Sondagem<Json>(
      intervalo: const Duration(seconds: 10),
      carregar: _carregar,
      construir: (context, d, recarregar) {
        final f = d['f'] as Json;
        final pecas = {for (final p in d['pecas'] as List) (p as Json)['id'] as String: p};
        final estilos = [
          for (final c in d['canais'] as List)
            for (final e in ((c as Json)['estilos'] as List)) (e as Json)['id'] as String,
        ];
        final revisao = [for (final r in f['revisao'] as List) (r as Json)];
        final acervo = f['acervo'] as Json;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Acervo: ${acervo['aprovadas']} aprovada(s) · ${acervo['revisao']} em revisão · '
              'gasto da fábrica hoje US\$ ${(f['gasto_hoje'] as num).toStringAsFixed(2)}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 12),
            _NovoPedido(api: api, aoCriar: recarregar),
            Secao('Revisão (${revisao.length})'),
            if (revisao.isEmpty)
              const Vazio('Nada esperando você. As peças aprovadas no portão aparecem aqui.', icone: Icons.inbox_outlined),
            for (final r in revisao)
              if (pecas[r['id']] case final Json p)
                PecaRevisao(api: api, peca: p, pedido: r, estilos: estilos, aoMudar: recarregar),
            const Secao('Pedidos'),
            for (final p in f['pedidos'] as List) _Pedido(api: api, p: p as Json, aoMudar: recarregar),
            if ((f['pedidos'] as List).isEmpty) const Text('Nenhum pedido ainda.'),
            const Secao('Ampliação contínua'),
            _Ampliacao(api: api, a: f['ampliacao'] as Json, aoMudar: recarregar),
            const Secao('Lacunas do acervo (intenção × peso)'),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final l in f['lacunas'] as List)
                  Chip(label: Text('${(l as Json)['intencao']} · ${l['peso']} (${l['tem']}/${(l['tem'] as int) + (l['falta'] as int)})')),
              ],
            ),
            const Secao('Motores: HTML × EffectCraft'),
            _Comparacao(api: api),
            const Secao('Troca de pele entre canais'),
            _ProvaCanais(api: api, estilos: estilos),
            const Secao('Registro'),
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

class _NovoPedido extends StatefulWidget {
  const _NovoPedido({required this.api, required this.aoCriar});

  final ApiEsteira api;
  final Future<void> Function() aoCriar;

  @override
  State<_NovoPedido> createState() => _NovoPedidoState();
}

class _NovoPedidoState extends State<_NovoPedido> {
  String _tipo = 'livre';
  final _texto = TextEditingController();
  final _teto = TextEditingController(text: '3');
  int _qtd = 3;
  String _ref = '';
  String _motor = 'html';
  String _ia = 'claude';

  @override
  void dispose() {
    _texto.dispose();
    _teto.dispose();
    super.dispose();
  }

  double get _tetoUsd => double.tryParse(_teto.text.replaceAll(',', '.')) ?? 3;

  Future<void> _escolherRef() async {
    final arquivos = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['png', 'jpg', 'jpeg', 'webp']);
    if (arquivos.isEmpty || !mounted) return;
    final a = arquivos.first;
    final nome = await widget.api.enviarReferenciaFabrica(a.name, await a.xFile.readAsBytes());
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
          _Opcoes(
            opcoes: const [
              ('livre', 'Livre', Icons.edit_note),
              ('referencia', 'Referência', Icons.image_outlined),
              ('lacunas', 'Preencher lacunas', Icons.grid_view),
            ],
            atual: _tipo,
            aoEscolher: (v) => setState(() => _tipo = v),
          ),
          _Opcoes(
            opcoes: const [
              ('html', 'HTML', null),
              ('effectcraft', 'EffectCraft', null),
              ('ambos', 'Os dois (comparar)', null),
              ('auto', 'Automático', null),
            ],
            atual: _ia == 'local' ? 'html' : _motor,
            aoEscolher: _ia == 'local' ? null : (v) => setState(() => _motor = v),
          ),
          // LLM local não gasta a cota, mas só escreve HTML (o dossiê do EffectCraft não cabe no contexto)
          _Opcoes(
            opcoes: const [
              ('claude', 'Claude', Icons.cloud_outlined),
              ('local', 'LLM local (só HTML)', Icons.memory),
            ],
            atual: _ia,
            aoEscolher: (v) => setState(() => _ia = v),
          ),
          if (_tipo != 'lacunas')
            TextField(
              controller: _texto,
              minLines: 2,
              maxLines: 5,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: _tipo == 'livre' ? 'O que gerar' : 'Observação sobre a referência (opcional)',
                hintText: _tipo == 'livre' ? 'Ex.: 3 animações de linha do tempo com fotos de época' : null,
              ),
            ),
          if (_tipo == 'referencia')
            Row(
              spacing: 8,
              children: [
                OutlinedButton.icon(onPressed: _escolherRef, icon: const Icon(Icons.upload), label: const Text('Enviar imagem')),
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
                initialSelection: _qtd,
                dropdownMenuEntries: [for (final n in [1, 2, 3, 5, 8, 10]) DropdownMenuEntry(value: n, label: '$n')],
                onSelected: (v) => setState(() => _qtd = v ?? _qtd),
              ),
              SizedBox(
                width: 160,
                child: TextField(
                  controller: _teto,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Teto do dia (US\$)'),
                ),
              ),
              FilledButton.icon(
                icon: const Icon(Icons.auto_awesome),
                label: const Text('Gerar'),
                onPressed: () => acaoComAviso(context, () async {
                  final p = await widget.api.novoPedidoFabrica({
                    'tipo': _tipo,
                    'texto': _texto.text.trim(),
                    'quantidade': _qtd,
                    'teto_dia_usd': _tetoUsd,
                    'referencia': _ref,
                    'motor': _ia == 'local' ? 'html' : _motor,
                    'ia': _ia,
                  });
                  _texto.clear();
                  await widget.aoCriar();
                  return 'Pedido ${p['id']} na fila ${_ia == 'local' ? 'do LLM local' : 'do Claude'}';
                }),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.format_quote),
                label: const Text('Primeira peça: citação de PDF'),
                onPressed: () => acaoComAviso(context, () async {
                  await widget.api.pedidoCitacao(teto: _tetoUsd, motor: _motor);
                  await widget.aoCriar();
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

/// Escolha única em chips que quebram linha: o SegmentedButton espremia os rótulos letra a letra no celular.
class _Opcoes extends StatelessWidget {
  const _Opcoes({required this.opcoes, required this.atual, required this.aoEscolher});

  final List<(String, String, IconData?)> opcoes;
  final String atual;
  final ValueChanged<String>? aoEscolher;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final (valor, rotulo, icone) in opcoes)
        ChoiceChip(
          avatar: icone == null || valor == atual ? null : Icon(icone, size: 18),
          label: Text(rotulo),
          selected: valor == atual,
          onSelected: aoEscolher == null ? null : (_) => aoEscolher!(valor),
        ),
    ],
  );
}

class _Pedido extends StatelessWidget {
  const _Pedido({required this.api, required this.p, required this.aoMudar});

  final ApiEsteira api;
  final Json p;
  final Future<void> Function() aoMudar;

  @override
  Widget build(BuildContext context) {
    final pausado = p['estado'] == 'pausado';
    final rotulo = p['tipo'] == 'lacunas' ? 'Preencher lacunas' : '${p['texto']}';
    return Card(
      child: ListTile(
        title: Text(rotulo, maxLines: 2, overflow: TextOverflow.ellipsis),
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
              onPressed: () => acaoComAviso(context, () async {
                await api.pausarPedido(p['id'] as String, !pausado);
                await aoMudar();
                return pausado ? 'Retomado' : 'Pausado';
              }),
            ),
            IconButton(
              tooltip: 'Rodar agora',
              icon: const Icon(Icons.refresh),
              onPressed: () => acaoComAviso(context, () async {
                await api.rodarPedido(p['id'] as String);
                return 'Pedido na fila';
              }),
            ),
          ],
        ),
      ),
    );
  }
}

class PecaRevisao extends StatefulWidget {
  const PecaRevisao({super.key, required this.api, required this.peca, required this.pedido, required this.estilos, required this.aoMudar});

  final ApiEsteira api;
  final Json peca;
  final Json pedido;
  final List<String> estilos;
  final Future<void> Function() aoMudar;

  @override
  State<PecaRevisao> createState() => PecaRevisaoState();
}

class PecaRevisaoState extends State<PecaRevisao> {
  String? _estilo;
  int? _nota;
  List<Json> _previas = const [];

  String get _id => widget.peca['id'] as String;

  @override
  void initState() {
    super.initState();
    _carregarPrevias();
  }

  Future<void> _carregarPrevias() async {
    final l = await widget.api.previasPeca(_id);
    if (mounted) setState(() => _previas = [for (final p in l) p as Json]);
  }

  Future<String?> _pedirTexto(String titulo, String dica) => showDialog<String>(
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

  Future<void> _revisar(String acao, String aviso, {String? titulo, String dica = ''}) async {
    var texto = '';
    if (titulo != null) {
      final t = await _pedirTexto(titulo, dica);
      if (t == null || t.isEmpty || !mounted) return;
      texto = t;
    }
    await acaoComAviso(context, () async {
      await widget.api.revisarPeca(_id, acao, texto, acao == 'aprovar' || acao == 'reprovar' ? _nota : null);
      await widget.aoMudar();
      return aviso;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ficha = widget.peca['ficha'] as Json;
    final quadros = [for (final q in widget.peca['quadros'] as List) q as String];
    final pequeno = Theme.of(context).textTheme.bodySmall;
    final estilo = _estilo ?? widget.estilos.firstOrNull;
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
                Text('$_id · v${ficha['versao']}', style: Theme.of(context).textTheme.titleMedium),
                Chip(label: Text(ficha['motor'] == 'effectcraft' ? 'EffectCraft' : 'HTML')),
                if (widget.pedido['par'] != null) Text('par de ${widget.pedido['par']}', style: pequeno),
              ],
            ),
            Text('${ficha['comunica']}'),
            Text(
              'intenções: ${(ficha['intencoes'] as List).join(', ')} · peso ${ficha['peso']} · ${(ficha['formatos'] as List).join(' / ')} · '
              '${ficha['duracao_min']}–${ficha['duracao_max']} s · tom ${(ficha['tom'] as List).join(', ')} · energia ${ficha['energia']}',
              style: pequeno,
            ),
            if ('${ficha['notas'] ?? ''}'.isNotEmpty) Text('Notas: ${ficha['notas']}', style: pequeno),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                spacing: 8,
                children: [
                  for (final q in quadros)
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
                for (final e in ficha['encaixes'] as List)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '• ${(e as Json)['nome']} (${e['tipo']}${e['tipo'] == 'itens' ? ', ${e['min_itens']}–${e['max_itens']} itens' : ''}, '
                      'até ${e['max_car']} car.${e['obrigatorio'] == true ? '' : ', opcional'}): ${e['descricao']}',
                    ),
                  ),
                for (final b in ficha['botoes'] as List)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text('◦ ${(b as Json)['nome']}: ${(b['valores'] as List).join(' / ')} (padrão ${b['padrao']})'),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Serve para: ${(ficha['exemplos_sim'] as List).join(' | ')}', style: pequeno),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Não serve para: ${(ficha['exemplos_nao'] as List).join(' | ')}', style: pequeno),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (widget.estilos.isNotEmpty)
                  DropdownMenu<String>(
                    label: const Text('Prévia na pele de'),
                    initialSelection: estilo,
                    dropdownMenuEntries: [for (final e in widget.estilos) DropdownMenuEntry(value: e, label: e)],
                    onSelected: (v) => setState(() => _estilo = v),
                  ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.movie_outlined),
                  label: const Text('Gerar prévia animada'),
                  onPressed: estilo == null
                      ? null
                      : () => acaoComAviso(context, () async {
                          await widget.api.previaPeca(_id, estilo);
                          return 'Prévia na fila (alguns segundos na GPU); toque em atualizar depois';
                        }),
                ),
                IconButton(tooltip: 'Atualizar prévias', onPressed: _carregarPrevias, icon: const Icon(Icons.refresh)),
              ],
            ),
            if (_previas.isNotEmpty)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  spacing: 12,
                  children: [
                    for (final p in _previas)
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
                  ChoiceChip(label: Text('$n'), selected: _nota == n, onSelected: (v) => setState(() => _nota = v ? n : null)),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.check),
                  label: const Text('Aprovar'),
                  onPressed: () => _revisar('aprovar', '$_id entrou no acervo'),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.tune),
                  label: const Text('Pedir ajuste'),
                  onPressed: () => _revisar('ajuste', 'Ajuste na fila do Claude',
                      titulo: 'O que ajustar em $_id?', dica: 'Ex.: entrada mais lenta, número maior, sem o anel'),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.copy_all),
                  label: const Text('Variação'),
                  onPressed: () => _revisar('variacao', 'Variação na fila do Claude'),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.close),
                  label: const Text('Reprovar'),
                  onPressed: () => _revisar('reprovar', 'Reprovada; o motivo vira regra para as próximas',
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

/// Prova de troca de pele: todas as peças aprovadas na pele de cada estilo escolhido, com as folhas e os problemas.
class _ProvaCanais extends StatefulWidget {
  const _ProvaCanais({required this.api, required this.estilos});

  final ApiEsteira api;
  final List<String> estilos;

  @override
  State<_ProvaCanais> createState() => _ProvaCanaisState();
}

class _ProvaCanaisState extends State<_ProvaCanais> {
  final _sel = <String>{};
  Json? _r;

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Future<void> _carregar() async {
    final r = await widget.api.resultadoProvaCanais();
    if (mounted) setState(() => _r = r);
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    final problemas = [for (final p in (r?['problemas'] as List?) ?? const []) p as Json];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final e in widget.estilos)
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
                  : () => acaoComAviso(context, () async {
                      await widget.api.provaCanais(_sel.toList());
                      return 'Prova na fila (cerca de 1 min por estilo); toque em atualizar depois';
                    }),
            ),
            IconButton(tooltip: 'Atualizar', onPressed: _carregar, icon: const Icon(Icons.refresh)),
          ],
        ),
        if (r != null && (r['folhas'] as List).isNotEmpty) ...[
          Text(
            '${(r['pecas'] as List).length} peça(s) em ${(r['estilos'] as List).join(', ')} · '
            '${problemas.isEmpty ? 'nenhum problema' : '${problemas.length} problema(s)'}',
          ),
          for (final p in problemas) Text('• ${p['peca']} · ${p['estilo']} · ${p['formato']}: ${p['erro']}'),
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

/// Comparação dos motores (pelo registro da fábrica) e a decisão de motor por intenção.
class _Comparacao extends StatefulWidget {
  const _Comparacao({required this.api});

  final ApiEsteira api;

  @override
  State<_Comparacao> createState() => _ComparacaoState();
}

class _ComparacaoState extends State<_Comparacao> {
  Json? _c;

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Future<void> _carregar() async {
    final c = await widget.api.comparacaoMotores();
    if (mounted) setState(() => _c = c);
  }

  static const _linhas = [
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
    final geral = c['geral'] as Json;
    final sug = c['sugestao'] as Json;
    final decisao = ((c['decisao'] as Json)['por_intencao'] as Json?) ?? const {};
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
              for (final (k, rot) in _linhas)
                DataRow(cells: [
                  DataCell(Text(rot)),
                  DataCell(Text(k == 'custo_medio' || k == 'render_s_medio' || k == 'segundos_medio' || k == 'rodadas_media' || k == 'nota_media'
                      ? '${(geral['html'] as Json)[k] ?? '—'}'
                      : _v((geral['html'] as Json)[k]))),
                  DataCell(Text(k == 'custo_medio' || k == 'render_s_medio' || k == 'segundos_medio' || k == 'rodadas_media' || k == 'nota_media'
                      ? '${(geral['effectcraft'] as Json)[k] ?? '—'}'
                      : _v((geral['effectcraft'] as Json)[k]))),
                ]),
            ],
          ),
        ),
        Text('Por intenção (sugestão a partir de ${c['amostra_min']} peças revisadas por motor):',
            style: Theme.of(context).textTheme.titleSmall),
        for (final e in sug.entries)
          Text('• ${e.key}: ${(e.value as Json)['motor'] ?? 'sem sugestão'} — ${(e.value as Json)['motivo']}'
              '${decisao[e.key] != null ? ' · decidido: ${decisao[e.key]}' : ''}'),
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
                  : () => acaoComAviso(context, () async {
                      await widget.api.aplicarMotores(aplicaveis);
                      await _carregar();
                      return 'Decisão aplicada: os pedidos em Automático usam esse motor por intenção';
                    }),
            ),
            IconButton(tooltip: 'Atualizar', onPressed: _carregar, icon: const Icon(Icons.refresh)),
          ],
        ),
      ],
    );
  }
}

/// Ampliação contínua: o acervo cresce sozinho pelas lacunas (um pedido por dia), você continua aprovando tudo.
class _Ampliacao extends StatelessWidget {
  const _Ampliacao({required this.api, required this.a, required this.aoMudar});

  final ApiEsteira api;
  final Json a;
  final Future<void> Function() aoMudar;

  Future<void> _salvar(BuildContext context, Json mudanca) => acaoComAviso(context, () async {
    final r = await api.salvarAmpliacao({...a, ...mudanca});
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
            onChanged: (v) => _salvar(context, {'ativo': v}),
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
                onSelected: (v) => v == null ? null : _salvar(context, {'pecas_por_dia': v}),
              ),
              DropdownMenu<double>(
                label: const Text('Teto do dia (US\$)'),
                initialSelection: (a['teto_dia_usd'] as num).toDouble(),
                dropdownMenuEntries: [for (final n in [1.0, 2.0, 3.0, 5.0]) DropdownMenuEntry(value: n, label: n.toStringAsFixed(0))],
                onSelected: (v) => v == null ? null : _salvar(context, {'teto_dia_usd': v}),
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
                onSelected: (v) => v == null ? null : _salvar(context, {'motor': v}),
              ),
              DropdownMenu<int>(
                label: const Text('Pausa com N na revisão'),
                initialSelection: (a['revisao_max'] as num).toInt(),
                dropdownMenuEntries: [for (final n in [4, 8, 12, 20]) DropdownMenuEntry(value: n, label: '$n')],
                onSelected: (v) => v == null ? null : _salvar(context, {'revisao_max': v}),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
