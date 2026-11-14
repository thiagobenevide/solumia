import 'package:agent_core/agent_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../finance_api.dart';
import '../format.dart';
import 'common.dart';

/// Statement: the month's entries with filters, OFX/CSV import, batch categorization (which can
/// become a rule) and the rules registry.
class StatementScreen extends StatefulWidget {
  const StatementScreen({super.key, required this.api, required this.registry});

  final FinanceApi api;
  final Registry registry;

  @override
  State<StatementScreen> createState() => _StatementScreenState();
}

class _StatementScreenState extends State<StatementScreen> {
  var _mes = DateTime(DateTime.now().year, DateTime.now().month);
  var _wholePeriod = false;
  String? _account;
  String? _category;
  var _uncategorized = false;
  final _search = TextEditingController();
  final _selected = <String>{};
  late Future<List<Doc>> _items = _load();

  FinanceApi get api => widget.api;
  Registry get cad => widget.registry;

  Future<List<Doc>> _load() => api.list('transacoes', {
    if (!_wholePeriod) 'de': iso(_mes),
    if (!_wholePeriod) 'ate': iso(DateTime(_mes.year, _mes.month + 1, 0)),
    'conta_id': ?_account,
    'categoria_id': ?_category,
    if (_uncategorized) 'sem_categoria': 'true',
    if (_search.text.trim().isNotEmpty) 'q': _search.text.trim(),
  });

  void _reload() => setState(() {
    _selected.clear();
    _items = _load();
  });

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<FormFieldSpec> get _campos => [
    const FormFieldSpec('data', 'Data', type: FieldKind.data, isRequired: true),
    const FormFieldSpec('descricao', 'Descrição', isRequired: true),
    const FormFieldSpec('valor', 'Valor', type: FieldKind.number, help: 'negativo = saída (despesa), positivo = entrada'),
    FormFieldSpec('conta_id', 'Conta', type: FieldKind.option, options: cad.accountOptions),
    FormFieldSpec('categoria_id', 'Categoria', type: FieldKind.option, options: cad.categoryOptions),
    const FormFieldSpec('contraparte', 'Contraparte (pessoa ou empresa)', help: 'vazio = deduz da descrição'),
    const FormFieldSpec('parcela', 'Parcela', help: 'ex.: 2/10'),
    const FormFieldSpec('forma_pagamento', 'Forma de pagamento', type: FieldKind.option, options: paymentMethods),
    const FormFieldSpec('observacao', 'Observação', type: FieldKind.longText),
  ];

  Future<void> _newTask() async {
    final d = await form(context, 'Nova transação', _campos, {'data': iso(DateTime.now()), 'conta_id': _account ?? ''});
    if (d == null || !mounted) return;
    if (await tentar(context, () => api.create('transacoes', d))) _reload();
  }

  Future<void> _edit(Doc t) async {
    final d = await form(context, 'Transação', _campos, t);
    if (d == null || !mounted) return;
    if (await tentar(context, () => api.edit('transacoes', t['id'] as String, d))) _reload();
  }

  Future<void> _import() async {
    if (cad.accounts.isEmpty) return avisar(context, 'Cadastre uma conta ou cartão em Contas primeiro.');
    final account = await form(context, 'Importar extrato', [
      FormFieldSpec('conta_id', 'Conta ou cartão do extrato', type: FieldKind.option,
          options: {for (final c in cad.accounts) c['id'] as String: c['nome'] as String}),
    ], {'conta_id': _account});
    if (account == null) return;
    final r = await FilePicker.pickFiles(
      dialogTitle: 'Extratos (OFX, CSV, XLS/XLSX ou PDF)',
      type: FileType.custom,
      allowedExtensions: ['ofx', 'qfx', 'csv', 'txt', 'xlsx', 'xls', 'pdf'],
    );
    if (r.isEmpty || !mounted) return;
    // Several months at once, one file at a time, in the background: the progress and the summary stay
    // in the bell and the screen stays free.
    final accountId = account['conta_id'] as String;
    Tarefas.instancia.rodar<void>('Importar ${r.length} extrato(s)', (t) async {
      var imported = 0, duplicadas = 0, uncategorized = 0;
      final failures = <String>[];
      for (final (i, a) in r.indexed) {
        t.conferir();
        t.atualizar(detalhe: '${i + 1} de ${r.length}: ${a.name}', progresso: i / r.length);
        try {
          final res = await api.importFile(accountId, a.name, await a.xFile.readAsBytes());
          imported += res['importadas'] as int;
          duplicadas += res['duplicadas'] as int;
          var remaining = res['sem_categoria'] as int;
          // what the rules did not catch the AI categorizes by the name of who received/sent
          if (res['categorizando'] case final String task) {
            t.atualizar(detalhe: '${i + 1} de ${r.length}: a IA está categorizando ${a.name}');
            try {
              remaining -= (await api.waitForTask(task, isCancelled: () => t.cancelada))['categorizadas'] as int;
            } on ApiErro catch (e) {
              failures.add('${a.name}: categorias pela IA — ${e.mensagem}');
            }
          }
          uncategorized += remaining;
        } on ApiErro catch (e) {
          failures.add('${a.name}: ${e.mensagem}');
        }
      }
      t.atualizar(
        detalhe: '$imported importadas, $duplicadas já existiam, $uncategorized sem categoria'
            '${failures.isEmpty ? '' : '. Falharam: ${failures.join('; ')}'}',
      );
      if (mounted) _reload();
    });
    avisar(context, 'Importando em segundo plano; o resultado aparece no sino.');
  }

  void _categorizeAi() {
    Tarefas.instancia.rodar<void>('Categorizar com IA', (t) async {
      t.atualizar(detalhe: 'A IA está categorizando…');
      final r = await api.categorizeAi();
      t.atualizar(detalhe: '${r['categorizadas']} de ${r['analisadas']} categorizadas; ${r['formas']} formas completadas');
      if (mounted) _reload();
    });
  }

  /// Fixes what was imported before the correction: inverted sign and everything as credit in the card
  /// account, and category by the rules and the AI. Deletes nothing.
  Future<void> _correct() async {
    if (!await confirm(
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
      final r = await api.correct();
      t.atualizar(
        detalhe: '${r['sinais']} sinais acertados, ${r['formas']} formas corrigidas, '
            '${(r['categorizadas'] as int) + (r['categorizadas_ia'] as int)} categorizadas, '
            '${r['trocadas_ia'] ?? 0} recategorizadas, ${r['sem_categoria']} sem categoria'
            '${r['erro_ia'] == null ? '' : ' (${r['erro_ia']})'}',
      );
      if (mounted) _reload();
    });
    avisar(context, 'Corrigindo em segundo plano; o resultado aparece no sino.');
  }

  Future<void> _categorizeSelected(List<Doc> itens) async {
    final first = itens.firstWhere((t) => _selected.contains(t['id']));
    final d = await form(context, 'Categorizar ${_selected.length}', [
      FormFieldSpec('categoria_id', 'Categoria', type: FieldKind.option, options: cad.categoryOptions),
      const FormFieldSpec('contraparte', 'Contraparte (opcional)'),
      const FormFieldSpec('regra', 'Criar regra com o texto', help: 'vazio = sem regra; a regra categoriza as próximas importações'),
    ], {'regra': first['contraparte']});
    if (d == null || !mounted) return;
    final data = <String, dynamic>{'categoria_id': d['categoria_id']};
    if ((d['contraparte'] as String).isNotEmpty) data['contraparte'] = d['contraparte'];
    final rule = (d['regra'] as String).trim();
    var firstBatch = true;
    // The rule only goes in the first batch (otherwise it would be created once per batch).
    if (await tentar(
      context,
      () => executarEmLotes(context, 'Categorizando', [..._selected], (batch) async {
        await api.batch(batch, data, rule: firstBatch && rule.isNotEmpty ? rule : null);
        firstBatch = false;
      }),
    )) {
      _reload();
    }
  }

  Future<void> _deleteSelected() async {
    if (!await confirm(context, 'Excluir ${_selected.length} transações?') || !mounted) return;
    await tentar(
      context,
      () => executarEmLotes(context, 'Excluindo', [..._selected], (batch) => api.deleteBatch('transacoes', batch)),
    );
    _reload();
  }

  Future<void> _openRules() async {
    await abrirTela<void>(context, (_) => RulesScreen(api: api, registry: cad));
    _reload();
  }

  void _selectAll(List<Doc> itens) => setState(() => _selected.addAll([for (final t in itens) t['id'] as String]));

  void _toggle(String id) => setState(() => _selected.contains(id) ? _selected.remove(id) : _selected.add(id));

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: cad,
    builder: (context, _) => LayoutBuilder(
      builder: (context, c) => Column(
        children: [
          _filters(context, c.maxWidth),
          Expanded(
            child: Waiting(
              future: _items,
              reload: _reload,
              construir: (itens) => _list(context, itens, compact: c.maxWidth < 600),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _filters(BuildContext context, double width) {
    final filters = <Widget>[
      if (!_wholePeriod) MonthPicker(mes: _mes, aoMudar: (m) {
        _mes = m;
        _reload();
      }),
      FilterChip(label: const Text('Todo o período'), selected: _wholePeriod, onSelected: (v) {
        _wholePeriod = v;
        _reload();
      }),
      DropdownButton<String?>(
        value: _account,
        hint: const Text('Todas as contas'),
        items: [
          const DropdownMenuItem(value: null, child: Text('Todas as contas')),
          for (final c in cad.accounts) DropdownMenuItem(value: c['id'] as String, child: Text(c['nome'] as String)),
        ],
        onChanged: (v) {
          _account = v;
          _reload();
        },
      ),
      DropdownButton<String?>(
        value: _category,
        hint: const Text('Todas as categorias'),
        items: [
          const DropdownMenuItem(value: null, child: Text('Todas as categorias')),
          for (final c in cad.categories) DropdownMenuItem(value: c['id'] as String, child: Text(c['nome'] as String)),
        ],
        onChanged: (v) {
          _category = v;
          _reload();
        },
      ),
      FilterChip(label: const Text('Sem categoria'), selected: _uncategorized, onSelected: (v) {
        _uncategorized = v;
        _reload();
      }),
    ];
    final busca = TextField(
      controller: _search,
      decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search), hintText: 'Buscar'),
      onSubmitted: (_) => _reload(),
    );
    final stocks = <(IconData, String, VoidCallback)>[
      (Icons.upload_file, 'Importar extratos', _import),
      (Icons.auto_awesome, 'Categorizar com IA', _categorizeAi),
      (Icons.healing, 'Corrigir lançamentos', _correct),
      (Icons.rule, 'Regras', _openRules),
    ];
    if (width >= 1000) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ...filters,
            SizedBox(width: 220, child: busca),
            FilledButton.icon(onPressed: _import, icon: const Icon(Icons.upload_file), label: const Text('Importar extratos')),
            for (final (icone, label, action) in stocks.skip(1).take(2))
              OutlinedButton.icon(onPressed: action, icon: Icon(icone), label: Text(label)),
            OutlinedButton.icon(onPressed: _newTask, icon: const Icon(Icons.add), label: const Text('Transação')),
            OutlinedButton.icon(onPressed: _openRules, icon: const Icon(Icons.rule), label: const Text('Regras')),
          ],
        ),
      );
    }
    // Narrow screens (phone/tablet): filters on a scrollable line; search, new and actions menu on the other.
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
            child: Row(children: [for (final f in filters) Padding(padding: const EdgeInsets.only(right: 8), child: f)]),
          ),
          Row(
            children: [
              Expanded(child: busca),
              IconButton(onPressed: _newTask, icon: const Icon(Icons.add), tooltip: 'Nova transação'),
              PopupMenuButton<VoidCallback>(
                tooltip: 'Ações',
                onSelected: (action) => action(),
                itemBuilder: (_) => [
                  for (final (icone, label, action) in stocks)
                    PopupMenuItem(value: action, child: ListTile(leading: Icon(icone), title: Text(label), dense: true)),
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

  Widget _list(BuildContext context, List<Doc> itens, {required bool compact}) {
    final cs = Theme.of(context).colorScheme;
    final income = itens.where((t) => n(t['valor']) > 0).fold<double>(0, (s, t) => s + n(t['valor']));
    final outflows = itens.where((t) => n(t['valor']) < 0).fold<double>(0, (s, t) => s + n(t['valor']));
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 16, vertical: 6),
          child: Wrap(
            spacing: compact ? 12 : 18,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (itens.isNotEmpty)
                Tooltip(
                  message: 'Selecionar todos',
                  child: MarcarTodos(
                    ids: [for (final t in itens) t['id'] as String],
                    selecionados: _selected,
                    mudou: (newItems) => setState(() => _selected
                      ..clear()
                      ..addAll(newItems)),
                  ),
                ),
              Text('${itens.length} lançamentos'),
              Text('Entradas ${currency(income)}', style: TextStyle(color: Colors.green.shade400)),
              Text('Saídas ${currency(-outflows)}', style: TextStyle(color: cs.error)),
              Text('Saldo ${currency(income + outflows)}', style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        if (_selected.isNotEmpty)
          Material(
            color: cs.secondaryContainer,
            child: Row(
              children: [
                const SizedBox(width: 12),
                Expanded(child: Text('${_selected.length} selecionadas', overflow: TextOverflow.ellipsis)),
                if (_selected.length < itens.length)
                  compact
                      ? IconButton(onPressed: () => _selectAll(itens), icon: const Icon(Icons.select_all), tooltip: 'Selecionar todas')
                      : TextButton.icon(
                          onPressed: () => _selectAll(itens),
                          icon: const Icon(Icons.select_all),
                          label: Text('Selecionar todas (${itens.length})'),
                        ),
                if (compact) ...[
                  IconButton(onPressed: () => _categorizeSelected(itens), icon: const Icon(Icons.label), tooltip: 'Categorizar'),
                  IconButton(onPressed: _deleteSelected, icon: const Icon(Icons.delete_outline), tooltip: 'Excluir'),
                ] else ...[
                  TextButton.icon(onPressed: () => _categorizeSelected(itens), icon: const Icon(Icons.label), label: const Text('Categorizar')),
                  TextButton.icon(onPressed: _deleteSelected, icon: const Icon(Icons.delete_outline), label: const Text('Excluir')),
                ],
                IconButton(onPressed: () => setState(_selected.clear), icon: const Icon(Icons.close)),
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
                  itemBuilder: (context, i) => compact ? _compactItem(context, itens[i]) : _item(context, itens[i]),
                ),
        ),
      ],
    );
  }

  /// Secondary details of the transaction (date, account, counterparty, installment, payment method).
  List<String> _details(Doc t) {
    final account = cad.account(t['conta_id'] as String?);
    final method = t['forma_pagamento'] as String? ?? '';
    return [
      dataBr(t['data'] as String?),
      if (account != null) account['nome'] as String,
      if ((t['contraparte'] as String).isNotEmpty) t['contraparte'] as String,
      if ((t['parcela'] as String).isNotEmpty) 'parcela ${t['parcela']}',
      if (method.isNotEmpty) paymentMethods[method] ?? method,
    ];
  }

  Widget _tag(Doc t) {
    final cat = cad.category(t['categoria_id'] as String?);
    return Tag(cat?['nome'] as String? ?? 'sem categoria', color: cat == null ? Colors.orange : hexColor(cat['cor'] as String?));
  }

  Widget _item(BuildContext context, Doc t) {
    final cs = Theme.of(context).colorScheme;
    final id = t['id'] as String;
    return ListTile(
      dense: true,
      selected: _selected.contains(id),
      leading: Checkbox(value: _selected.contains(id), onChanged: (_) => _toggle(id)),
      title: Text(t['descricao'] as String, overflow: TextOverflow.ellipsis),
      subtitle: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [Text(_details(t).join(' · ')), _tag(t)],
      ),
      trailing: Text(currency(nn(t['valor'])), style: TextStyle(color: valueColor(nn(t['valor']), cs), fontWeight: FontWeight.w600)),
      onTap: () => _edit(t),
      onLongPress: () => setState(() => _selected.add(id)),
    );
  }

  /// Phone row: no fixed checkbox (long press enters selection), description in up to 2 lines and value
  /// aligned at the top right.
  Widget _compactItem(BuildContext context, Doc t) {
    final topic = Theme.of(context);
    final cs = topic.colorScheme;
    final id = t['id'] as String;
    final selected = _selected.contains(id);
    final selecting = _selected.isNotEmpty;
    return InkWell(
      onTap: selecting ? () => _toggle(id) : () => _edit(t),
      onLongPress: () => setState(() => _selected.add(id)),
      child: Container(
        color: selected ? cs.primaryContainer.withValues(alpha: 0.4) : null,
        padding: EdgeInsets.fromLTRB(selecting ? 4 : 12, 8, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (selecting) Checkbox(value: selected, onChanged: (_) => _toggle(id)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(t['descricao'] as String, maxLines: 2, overflow: TextOverflow.ellipsis,
                            style: topic.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                      ),
                      const SizedBox(width: 8),
                      Text(currency(nn(t['valor'])),
                          style: TextStyle(color: valueColor(nn(t['valor']), cs), fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(_details(t).join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: topic.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  const SizedBox(height: 4),
                  _tag(t),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Categorization rules: text that appears in the description → category and counterparty.
class RulesScreen extends StatefulWidget {
  const RulesScreen({super.key, required this.api, required this.registry});

  final FinanceApi api;
  final Registry registry;

  @override
  State<RulesScreen> createState() => _RulesScreenState();
}

class _RulesScreenState extends State<RulesScreen> {
  late Future<List<Doc>> _rules = widget.api.list('regras');

  void _reload() => setState(() => _rules = widget.api.list('regras'));

  List<FormFieldSpec> get _campos => [
    const FormFieldSpec('padrao', 'Texto na descrição', isRequired: true, help: 'sem diferenciar maiúsculas e acentos'),
    FormFieldSpec('categoria_id', 'Categoria', type: FieldKind.option, options: widget.registry.categoryOptions),
    const FormFieldSpec('contraparte', 'Contraparte'),
    const FormFieldSpec('prioridade', 'Prioridade', type: FieldKind.integer, help: 'maior vence quando duas regras batem'),
  ];

  Future<void> _form([Doc? r]) async {
    final d = await form(context, r == null ? 'Nova regra' : 'Regra', _campos, r ?? {});
    if (d == null || !mounted) return;
    final ok = await tentar(context, () => r == null ? widget.api.create('regras', d) : widget.api.edit('regras', r['id'] as String, d));
    if (ok) _reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Regras de categorização'),
      actions: [
        TextButton.icon(
          onPressed: () => tentar(context, () async {
            final n = await widget.api.applyRules();
            if (context.mounted) avisar(context, '$n transações categorizadas');
          }),
          icon: const Icon(Icons.auto_fix_high),
          label: const Text('Aplicar nas sem categoria'),
        ),
      ],
    ),
    floatingActionButton: FloatingActionButton(onPressed: _form, child: const Icon(Icons.add)),
    body: Waiting(
      future: _rules,
      reload: _reload,
      construir: (rules) => rules.isEmpty
          ? const Center(child: Text('Sem regras. Crie aqui ou ao categorizar em lote no extrato.'))
          : ListView(
              children: [
                for (final r in rules)
                  ListTile(
                    title: Text('"${r['padrao']}"'),
                    subtitle: Text([
                      widget.registry.category(r['categoria_id'] as String?)?['nome'] ?? 'sem categoria',
                      if ((r['contraparte'] as String).isNotEmpty) r['contraparte'],
                      'prioridade ${r['prioridade']}',
                    ].join(' · ')),
                    trailing: MenuItem(
                      onEdit: () => _form(r),
                      onDelete: () async {
                        if (await tentar(context, () => widget.api.delete('regras', r['id'] as String))) _reload();
                      },
                    ),
                  ),
              ],
            ),
    ),
  );
}
