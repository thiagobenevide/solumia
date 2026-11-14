import 'package:agent_core/agent_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api_financas.dart';
import '../formato.dart';
import 'comuns.dart';

/// Extrato: lançamentos do mês com filtros, importação de OFX/CSV, categorização em lote (que pode
/// virar regra) e o cadastro de regras.
class ExtratoTela extends StatefulWidget {
  const ExtratoTela({super.key, required this.api, required this.cadastros});

  final ApiFinancas api;
  final Cadastros cadastros;

  @override
  State<ExtratoTela> createState() => _ExtratoTelaState();
}

class _ExtratoTelaState extends State<ExtratoTela> {
  var _mes = DateTime(DateTime.now().year, DateTime.now().month);
  var _todoPeriodo = false;
  String? _conta;
  String? _categoria;
  var _semCategoria = false;
  final _busca = TextEditingController();
  final _selecionadas = <String>{};
  late Future<List<Doc>> _itens = _carregar();

  ApiFinancas get api => widget.api;
  Cadastros get cad => widget.cadastros;

  Future<List<Doc>> _carregar() => api.listar('transacoes', {
    if (!_todoPeriodo) 'de': iso(_mes),
    if (!_todoPeriodo) 'ate': iso(DateTime(_mes.year, _mes.month + 1, 0)),
    'conta_id': ?_conta,
    'categoria_id': ?_categoria,
    if (_semCategoria) 'sem_categoria': 'true',
    if (_busca.text.trim().isNotEmpty) 'q': _busca.text.trim(),
  });

  void _recarregar() => setState(() {
    _selecionadas.clear();
    _itens = _carregar();
  });

  @override
  void dispose() {
    _busca.dispose();
    super.dispose();
  }

  List<Campo> get _campos => [
    const Campo('data', 'Data', tipo: TipoCampo.data, obrigatorio: true),
    const Campo('descricao', 'Descrição', obrigatorio: true),
    const Campo('valor', 'Valor', tipo: TipoCampo.numero, ajuda: 'negativo = saída (despesa), positivo = entrada'),
    Campo('conta_id', 'Conta', tipo: TipoCampo.opcao, opcoes: cad.opcoesContas),
    Campo('categoria_id', 'Categoria', tipo: TipoCampo.opcao, opcoes: cad.opcoesCategorias),
    const Campo('contraparte', 'Contraparte (pessoa ou empresa)', ajuda: 'vazio = deduz da descrição'),
    const Campo('parcela', 'Parcela', ajuda: 'ex.: 2/10'),
    const Campo('forma_pagamento', 'Forma de pagamento', tipo: TipoCampo.opcao, opcoes: formasPagamento),
    const Campo('observacao', 'Observação', tipo: TipoCampo.longo),
  ];

  Future<void> _nova() async {
    final d = await formulario(context, 'Nova transação', _campos, {'data': iso(DateTime.now()), 'conta_id': _conta ?? ''});
    if (d == null || !mounted) return;
    if (await tentar(context, () => api.criar('transacoes', d))) _recarregar();
  }

  Future<void> _editar(Doc t) async {
    final d = await formulario(context, 'Transação', _campos, t);
    if (d == null || !mounted) return;
    if (await tentar(context, () => api.editar('transacoes', t['id'] as String, d))) _recarregar();
  }

  Future<void> _importar() async {
    if (cad.contas.isEmpty) return avisar(context, 'Cadastre uma conta ou cartão em Contas primeiro.');
    final conta = await formulario(context, 'Importar extrato', [
      Campo('conta_id', 'Conta ou cartão do extrato', tipo: TipoCampo.opcao,
          opcoes: {for (final c in cad.contas) c['id'] as String: c['nome'] as String}),
    ], {'conta_id': _conta});
    if (conta == null) return;
    final r = await FilePicker.pickFiles(
      dialogTitle: 'Extratos (OFX, CSV, XLS/XLSX ou PDF)',
      type: FileType.custom,
      allowedExtensions: ['ofx', 'qfx', 'csv', 'txt', 'xlsx', 'xls', 'pdf'],
    );
    if (r.isEmpty || !mounted) return;
    // Vários meses de uma vez, um arquivo por vez, em segundo plano: o andamento e o resumo ficam
    // no sino e a tela continua livre.
    final contaId = conta['conta_id'] as String;
    Tarefas.instancia.rodar<void>('Importar ${r.length} extrato(s)', (t) async {
      var importadas = 0, duplicadas = 0, semCategoria = 0;
      final falhas = <String>[];
      for (final (i, a) in r.indexed) {
        t.conferir();
        t.atualizar(detalhe: '${i + 1} de ${r.length}: ${a.name}', progresso: i / r.length);
        try {
          final res = await api.importar(contaId, a.name, await a.xFile.readAsBytes());
          importadas += res['importadas'] as int;
          duplicadas += res['duplicadas'] as int;
          var faltam = res['sem_categoria'] as int;
          // o que as regras não pegaram a IA categoriza pelo nome de quem recebeu/enviou
          if (res['categorizando'] case final String tarefa) {
            t.atualizar(detalhe: '${i + 1} de ${r.length}: a IA está categorizando ${a.name}');
            try {
              faltam -= (await api.esperarTarefa(tarefa, cancelado: () => t.cancelada))['categorizadas'] as int;
            } on ApiErro catch (e) {
              falhas.add('${a.name}: categorias pela IA — ${e.mensagem}');
            }
          }
          semCategoria += faltam;
        } on ApiErro catch (e) {
          falhas.add('${a.name}: ${e.mensagem}');
        }
      }
      t.atualizar(
        detalhe: '$importadas importadas, $duplicadas já existiam, $semCategoria sem categoria'
            '${falhas.isEmpty ? '' : '. Falharam: ${falhas.join('; ')}'}',
      );
      if (mounted) _recarregar();
    });
    avisar(context, 'Importando em segundo plano; o resultado aparece no sino.');
  }

  void _categorizarIa() {
    Tarefas.instancia.rodar<void>('Categorizar com IA', (t) async {
      t.atualizar(detalhe: 'A IA está categorizando…');
      final r = await api.categorizarIa();
      t.atualizar(detalhe: '${r['categorizadas']} de ${r['analisadas']} categorizadas; ${r['formas']} formas completadas');
      if (mounted) _recarregar();
    });
  }

  /// Conserta o que foi importado antes da correção: sinal invertido e tudo como crédito na conta
  /// do cartão, e categoria pelas regras e pela IA. Não apaga nada.
  Future<void> _corrigir() async {
    if (!await confirmar(
          context,
          'Corrigir os lançamentos já importados? Acerta o sinal e a forma de pagamento (Pix, débito, '
          'depósito) da conta do cartão pelos extratos originais guardados e a IA reconfere: categoriza o que falta, '
          'define a forma de todos e revê o que ela mesma categorizou ou está no sentido errado (suas escolhas ficam). '
          'Nada é apagado.',
        ) ||
        !mounted) {
      return;
    }
    Tarefas.instancia.rodar<void>('Corrigir lançamentos', (t) async {
      t.atualizar(detalhe: 'Relendo os extratos originais e categorizando…');
      final r = await api.corrigir();
      t.atualizar(
        detalhe: '${r['sinais']} sinais acertados, ${r['formas']} formas corrigidas, '
            '${(r['categorizadas'] as int) + (r['categorizadas_ia'] as int)} categorizadas, '
            '${r['trocadas_ia'] ?? 0} recategorizadas, ${r['sem_categoria']} sem categoria'
            '${r['erro_ia'] == null ? '' : ' (${r['erro_ia']})'}',
      );
      if (mounted) _recarregar();
    });
    avisar(context, 'Corrigindo em segundo plano; o resultado aparece no sino.');
  }

  Future<void> _categorizarSelecionadas(List<Doc> itens) async {
    final primeira = itens.firstWhere((t) => _selecionadas.contains(t['id']));
    final d = await formulario(context, 'Categorizar ${_selecionadas.length}', [
      Campo('categoria_id', 'Categoria', tipo: TipoCampo.opcao, opcoes: cad.opcoesCategorias),
      const Campo('contraparte', 'Contraparte (opcional)'),
      const Campo('regra', 'Criar regra com o texto', ajuda: 'vazio = sem regra; a regra categoriza as próximas importações'),
    ], {'regra': primeira['contraparte']});
    if (d == null || !mounted) return;
    final dados = <String, dynamic>{'categoria_id': d['categoria_id']};
    if ((d['contraparte'] as String).isNotEmpty) dados['contraparte'] = d['contraparte'];
    final regra = (d['regra'] as String).trim();
    var primeiroLote = true;
    // A regra só vai no primeiro lote (senão seria criada uma vez por lote).
    if (await tentar(
      context,
      () => executarEmLotes(context, 'Categorizando', [..._selecionadas], (lote) async {
        await api.lote(lote, dados, regra: primeiroLote && regra.isNotEmpty ? regra : null);
        primeiroLote = false;
      }),
    )) {
      _recarregar();
    }
  }

  Future<void> _excluirSelecionadas() async {
    if (!await confirmar(context, 'Excluir ${_selecionadas.length} transações?') || !mounted) return;
    await tentar(
      context,
      () => executarEmLotes(context, 'Excluindo', [..._selecionadas], (lote) => api.excluirLote('transacoes', lote)),
    );
    _recarregar();
  }

  Future<void> _abrirRegras() async {
    await abrirTela<void>(context, (_) => RegrasTela(api: api, cadastros: cad));
    _recarregar();
  }

  void _selecionarTodas(List<Doc> itens) => setState(() => _selecionadas.addAll([for (final t in itens) t['id'] as String]));

  void _alternar(String id) => setState(() => _selecionadas.contains(id) ? _selecionadas.remove(id) : _selecionadas.add(id));

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: cad,
    builder: (context, _) => LayoutBuilder(
      builder: (context, c) => Column(
        children: [
          _filtros(context, c.maxWidth),
          Expanded(
            child: Esperar(
              futuro: _itens,
              recarregar: _recarregar,
              construir: (itens) => _lista(context, itens, compacto: c.maxWidth < 600),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _filtros(BuildContext context, double largura) {
    final filtros = <Widget>[
      if (!_todoPeriodo) SeletorMes(mes: _mes, aoMudar: (m) {
        _mes = m;
        _recarregar();
      }),
      FilterChip(label: const Text('Todo o período'), selected: _todoPeriodo, onSelected: (v) {
        _todoPeriodo = v;
        _recarregar();
      }),
      DropdownButton<String?>(
        value: _conta,
        hint: const Text('Todas as contas'),
        items: [
          const DropdownMenuItem(value: null, child: Text('Todas as contas')),
          for (final c in cad.contas) DropdownMenuItem(value: c['id'] as String, child: Text(c['nome'] as String)),
        ],
        onChanged: (v) {
          _conta = v;
          _recarregar();
        },
      ),
      DropdownButton<String?>(
        value: _categoria,
        hint: const Text('Todas as categorias'),
        items: [
          const DropdownMenuItem(value: null, child: Text('Todas as categorias')),
          for (final c in cad.categorias) DropdownMenuItem(value: c['id'] as String, child: Text(c['nome'] as String)),
        ],
        onChanged: (v) {
          _categoria = v;
          _recarregar();
        },
      ),
      FilterChip(label: const Text('Sem categoria'), selected: _semCategoria, onSelected: (v) {
        _semCategoria = v;
        _recarregar();
      }),
    ];
    final busca = TextField(
      controller: _busca,
      decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search), hintText: 'Buscar'),
      onSubmitted: (_) => _recarregar(),
    );
    final acoes = <(IconData, String, VoidCallback)>[
      (Icons.upload_file, 'Importar extratos', _importar),
      (Icons.auto_awesome, 'Categorizar com IA', _categorizarIa),
      (Icons.healing, 'Corrigir lançamentos', _corrigir),
      (Icons.rule, 'Regras', _abrirRegras),
    ];
    if (largura >= 1000) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ...filtros,
            SizedBox(width: 220, child: busca),
            FilledButton.icon(onPressed: _importar, icon: const Icon(Icons.upload_file), label: const Text('Importar extratos')),
            for (final (icone, rotulo, acao) in acoes.skip(1).take(2))
              OutlinedButton.icon(onPressed: acao, icon: Icon(icone), label: Text(rotulo)),
            OutlinedButton.icon(onPressed: _nova, icon: const Icon(Icons.add), label: const Text('Transação')),
            OutlinedButton.icon(onPressed: _abrirRegras, icon: const Icon(Icons.rule), label: const Text('Regras')),
          ],
        ),
      );
    }
    // Telas estreitas (celular/tablet): filtros numa linha rolável; busca, nova e menu de ações na outra.
    return FiltrosRecolhiveis(
      chave: 'financas.extrato',
      children: [
        Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [for (final f in filtros) Padding(padding: const EdgeInsets.only(right: 8), child: f)]),
          ),
          Row(
            children: [
              Expanded(child: busca),
              IconButton(onPressed: _nova, icon: const Icon(Icons.add), tooltip: 'Nova transação'),
              PopupMenuButton<VoidCallback>(
                tooltip: 'Ações',
                onSelected: (acao) => acao(),
                itemBuilder: (_) => [
                  for (final (icone, rotulo, acao) in acoes)
                    PopupMenuItem(value: acao, child: ListTile(leading: Icon(icone), title: Text(rotulo), dense: true)),
                ],
              ),
            ],
          ),
        ],
      ),
        ),
      ],
    );
  }

  Widget _lista(BuildContext context, List<Doc> itens, {required bool compacto}) {
    final cs = Theme.of(context).colorScheme;
    final entradas = itens.where((t) => n(t['valor']) > 0).fold<double>(0, (s, t) => s + n(t['valor']));
    final saidas = itens.where((t) => n(t['valor']) < 0).fold<double>(0, (s, t) => s + n(t['valor']));
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: compacto ? 12 : 16, vertical: 6),
          child: Wrap(
            spacing: compacto ? 12 : 18,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (itens.isNotEmpty)
                Tooltip(
                  message: 'Selecionar todos',
                  child: MarcarTodos(
                    ids: [for (final t in itens) t['id'] as String],
                    selecionados: _selecionadas,
                    mudou: (novos) => setState(() => _selecionadas
                      ..clear()
                      ..addAll(novos)),
                  ),
                ),
              Text('${itens.length} lançamentos'),
              Text('Entradas ${moeda(entradas)}', style: TextStyle(color: Colors.green.shade400)),
              Text('Saídas ${moeda(-saidas)}', style: TextStyle(color: cs.error)),
              Text('Saldo ${moeda(entradas + saidas)}', style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        if (_selecionadas.isNotEmpty)
          Material(
            color: cs.secondaryContainer,
            child: Row(
              children: [
                const SizedBox(width: 12),
                Expanded(child: Text('${_selecionadas.length} selecionadas', overflow: TextOverflow.ellipsis)),
                if (_selecionadas.length < itens.length)
                  compacto
                      ? IconButton(onPressed: () => _selecionarTodas(itens), icon: const Icon(Icons.select_all), tooltip: 'Selecionar todas')
                      : TextButton.icon(
                          onPressed: () => _selecionarTodas(itens),
                          icon: const Icon(Icons.select_all),
                          label: Text('Selecionar todas (${itens.length})'),
                        ),
                if (compacto) ...[
                  IconButton(onPressed: () => _categorizarSelecionadas(itens), icon: const Icon(Icons.label), tooltip: 'Categorizar'),
                  IconButton(onPressed: _excluirSelecionadas, icon: const Icon(Icons.delete_outline), tooltip: 'Excluir'),
                ] else ...[
                  TextButton.icon(onPressed: () => _categorizarSelecionadas(itens), icon: const Icon(Icons.label), label: const Text('Categorizar')),
                  TextButton.icon(onPressed: _excluirSelecionadas, icon: const Icon(Icons.delete_outline), label: const Text('Excluir')),
                ],
                IconButton(onPressed: () => setState(_selecionadas.clear), icon: const Icon(Icons.close)),
              ],
            ),
          ),
        Expanded(
          child: itens.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Nenhum lançamento. Importe um extrato OFX/CSV ou crie uma transação.', textAlign: TextAlign.center),
                  ),
                )
              : ListView.separated(
                  itemCount: itens.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) => compacto ? _itemCompacto(context, itens[i]) : _item(context, itens[i]),
                ),
        ),
      ],
    );
  }

  /// Detalhes secundários da transação (data, conta, contraparte, parcela, forma de pagamento).
  List<String> _detalhes(Doc t) {
    final conta = cad.conta(t['conta_id'] as String?);
    final forma = t['forma_pagamento'] as String? ?? '';
    return [
      dataBr(t['data'] as String?),
      if (conta != null) conta['nome'] as String,
      if ((t['contraparte'] as String).isNotEmpty) t['contraparte'] as String,
      if ((t['parcela'] as String).isNotEmpty) 'parcela ${t['parcela']}',
      if (forma.isNotEmpty) formasPagamento[forma] ?? forma,
    ];
  }

  Widget _etiqueta(Doc t) {
    final cat = cad.categoria(t['categoria_id'] as String?);
    return Etiqueta(cat?['nome'] as String? ?? 'sem categoria', cor: cat == null ? Colors.orange : corHex(cat['cor'] as String?));
  }

  Widget _item(BuildContext context, Doc t) {
    final cs = Theme.of(context).colorScheme;
    final id = t['id'] as String;
    return ListTile(
      dense: true,
      selected: _selecionadas.contains(id),
      leading: Checkbox(value: _selecionadas.contains(id), onChanged: (_) => _alternar(id)),
      title: Text(t['descricao'] as String, overflow: TextOverflow.ellipsis),
      subtitle: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [Text(_detalhes(t).join(' · ')), _etiqueta(t)],
      ),
      trailing: Text(moeda(nn(t['valor'])), style: TextStyle(color: corValor(nn(t['valor']), cs), fontWeight: FontWeight.w600)),
      onTap: () => _editar(t),
      onLongPress: () => setState(() => _selecionadas.add(id)),
    );
  }

  /// Linha para celular: sem checkbox fixo (toque longo entra em seleção), descrição em até 2 linhas e valor
  /// alinhado no topo à direita.
  Widget _itemCompacto(BuildContext context, Doc t) {
    final tema = Theme.of(context);
    final cs = tema.colorScheme;
    final id = t['id'] as String;
    final selecionada = _selecionadas.contains(id);
    final selecionando = _selecionadas.isNotEmpty;
    return InkWell(
      onTap: selecionando ? () => _alternar(id) : () => _editar(t),
      onLongPress: () => setState(() => _selecionadas.add(id)),
      child: Container(
        color: selecionada ? cs.primaryContainer.withValues(alpha: 0.4) : null,
        padding: EdgeInsets.fromLTRB(selecionando ? 4 : 12, 8, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (selecionando) Checkbox(value: selecionada, onChanged: (_) => _alternar(id)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(t['descricao'] as String, maxLines: 2, overflow: TextOverflow.ellipsis,
                            style: tema.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                      ),
                      const SizedBox(width: 8),
                      Text(moeda(nn(t['valor'])),
                          style: TextStyle(color: corValor(nn(t['valor']), cs), fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(_detalhes(t).join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: tema.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  const SizedBox(height: 4),
                  _etiqueta(t),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Regras de categorização: texto que aparece na descrição → categoria e contraparte.
class RegrasTela extends StatefulWidget {
  const RegrasTela({super.key, required this.api, required this.cadastros});

  final ApiFinancas api;
  final Cadastros cadastros;

  @override
  State<RegrasTela> createState() => _RegrasTelaState();
}

class _RegrasTelaState extends State<RegrasTela> {
  late Future<List<Doc>> _regras = widget.api.listar('regras');

  void _recarregar() => setState(() => _regras = widget.api.listar('regras'));

  List<Campo> get _campos => [
    const Campo('padrao', 'Texto na descrição', obrigatorio: true, ajuda: 'sem diferenciar maiúsculas e acentos'),
    Campo('categoria_id', 'Categoria', tipo: TipoCampo.opcao, opcoes: widget.cadastros.opcoesCategorias),
    const Campo('contraparte', 'Contraparte'),
    const Campo('prioridade', 'Prioridade', tipo: TipoCampo.inteiro, ajuda: 'maior vence quando duas regras batem'),
  ];

  Future<void> _formulario([Doc? r]) async {
    final d = await formulario(context, r == null ? 'Nova regra' : 'Regra', _campos, r ?? {});
    if (d == null || !mounted) return;
    final ok = await tentar(context, () => r == null ? widget.api.criar('regras', d) : widget.api.editar('regras', r['id'] as String, d));
    if (ok) _recarregar();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Regras de categorização'),
      actions: [
        TextButton.icon(
          onPressed: () => tentar(context, () async {
            final n = await widget.api.aplicarRegras();
            if (context.mounted) avisar(context, '$n transações categorizadas');
          }),
          icon: const Icon(Icons.auto_fix_high),
          label: const Text('Aplicar nas sem categoria'),
        ),
      ],
    ),
    floatingActionButton: FloatingActionButton(onPressed: _formulario, child: const Icon(Icons.add)),
    body: Esperar(
      futuro: _regras,
      recarregar: _recarregar,
      construir: (regras) => regras.isEmpty
          ? const Center(child: Text('Sem regras. Crie aqui ou ao categorizar em lote no extrato.'))
          : ListView(
              children: [
                for (final r in regras)
                  ListTile(
                    title: Text('"${r['padrao']}"'),
                    subtitle: Text([
                      widget.cadastros.categoria(r['categoria_id'] as String?)?['nome'] ?? 'sem categoria',
                      if ((r['contraparte'] as String).isNotEmpty) r['contraparte'],
                      'prioridade ${r['prioridade']}',
                    ].join(' · ')),
                    trailing: MenuItem(
                      aoEditar: () => _formulario(r),
                      aoExcluir: () async {
                        if (await tentar(context, () => widget.api.excluir('regras', r['id'] as String))) _recarregar();
                      },
                    ),
                  ),
              ],
            ),
    ),
  );
}
