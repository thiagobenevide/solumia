import 'package:agent_arquivos/agent_arquivos.dart';
import 'package:agent_core/agent_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api_financas.dart';
import '../formato.dart';
import 'comuns.dart';

/// Estudos de finanças: objetivo, trilha por níveis (cada etapa com o livro e os capítulos certos,
/// artigos, relatórios e uma prática no app), guia de cada livro, artigos científicos, relatórios
/// para praticar e as citações grifadas no leitor (projeto "Trilha de Finanças").
class EstudoTela extends StatefulWidget {
  const EstudoTela({super.key, required this.api, this.arquivos});

  final ApiFinancas api;
  final ApiArquivos? arquivos;

  @override
  State<EstudoTela> createState() => _EstudoTelaState();
}

const _status = {'pendente': 'A fazer', 'lendo': 'Estudando', 'feito': 'Feito'};

const _corPrioridade = {'essencial': Colors.red, 'importante': Colors.orange, 'opcional': Colors.grey};

class _EstudoTelaState extends State<EstudoTela> {
  late Future<Doc> _dados = widget.api.estudo();

  void _recarregar() => setState(() => _dados = widget.api.estudo());

  Future<void> _marcar(String item, String status) async {
    if (await tentar(context, () => widget.api.estudoMarcar(item, status: status))) _recarregar();
  }

  /// Leitura em Estudos › Leituras e projeto "Trilha de Finanças" ativo no leitor; em seguida
  /// escolhe o PDF para ler aqui (grifos e comentários viram citações da trilha).
  Future<void> _ler(String item, String titulo) async {
    Doc? r;
    if (!await tentar(context, () async => r = await widget.api.estudoLer(item))) return;
    final projeto = '${r!['projeto_id']}';
    projetosAtivos.value = {...projetosAtivos.value, projeto}.toList();
    _recarregar();
    final leitor = widget.arquivos;
    if (!mounted || leitor == null) return;
    final escolha = await showModalBottomSheet<bool>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(titulo),
              subtitle: const Text('Está em Estudos › Leituras e o projeto "Trilha de Finanças" ficou ativo no leitor: '
                  'o que você grifar ou comentar entra nas Citações.'),
            ),
            ListTile(
              leading: const Icon(Icons.picture_as_pdf_outlined),
              title: const Text('Escolher o PDF para ler aqui'),
              onTap: () => Navigator.pop(c, true),
            ),
            ListTile(
              leading: const Icon(Icons.menu_book_outlined),
              title: const Text('Livro físico ou PDF que já está em Arquivos'),
              subtitle: const Text('Abra pelo módulo Arquivos; marque os capítulos aqui.'),
              onTap: () => Navigator.pop(c, false),
            ),
          ],
        ),
      ),
    );
    if (escolha != true || !mounted) return;
    final f = await FilePicker.pickFiles(dialogTitle: titulo, type: FileType.custom, allowedExtensions: ['pdf']);
    if (f.isEmpty || !mounted) return;
    final bytes = await f.first.xFile.readAsBytes();
    if (mounted) await abrirPrevia(context, leitor, f.first.name, bytes, pasta: 'Finanças/Estudos');
  }

  /// O Claude monta o guia do livro em segundo plano (pode levar alguns minutos).
  void _guia(Doc livro) {
    Tarefas.instancia.rodar<Doc>('Guia de leitura: ${livro['titulo']}', (t) async {
      t.atualizar(detalhe: 'O Claude está montando o guia…');
      final r = await widget.api.estudoGuia('${livro['id']}', cancelado: () => t.cancelada);
      if (mounted) _recarregar();
      return r;
    });
    avisar(context, 'O Claude está montando o guia. Acompanhe no sino 🔔.');
  }

  Future<void> _novoLivro() async {
    final d = await formulario(context, 'Livro que eu tenho', const [
      Campo('titulo', 'Título', obrigatorio: true),
      Campo('autor', 'Autor'),
    ]);
    if (d == null || !mounted) return;
    Doc? livro;
    if (await tentar(context, () async => livro = await widget.api.estudoNovoLivro('${d['titulo']}', '${d['autor'] ?? ''}'))) {
      _recarregar();
      if (mounted) _guia(livro!);
    }
  }

  @override
  Widget build(BuildContext context) => Esperar(
    futuro: _dados,
    recarregar: _recarregar,
    construir: (d) => DefaultTabController(
      length: 5,
      child: Column(
        children: [
          _Objetivo(d, (id) async {
            if (await tentar(context, () => widget.api.estudoObjetivo(id))) _recarregar();
          }),
          const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Trilha'),
              Tab(text: 'Livros'),
              Tab(text: 'Artigos'),
              Tab(text: 'Relatórios'),
              Tab(text: 'Citações'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _Trilha(d, marcar: _marcar, ler: _ler),
                _Livros(d, marcar: _marcar, ler: _ler, guia: _guia, novo: _novoLivro, tenho: (id, v) async {
                  if (await tentar(context, () => widget.api.estudoTenho(id, v))) _recarregar();
                }),
                _Artigos((d['artigos'] as List).cast<Doc>(), marcar: _marcar, ler: _ler),
                _Relatorios((d['relatorios'] as List).cast<Doc>(), marcar: _marcar),
                _Citacoes(api: widget.api, arquivos: widget.arquivos),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _Objetivo extends StatelessWidget {
  const _Objetivo(this.d, this.escolher);

  final Doc d;
  final ValueChanged<String> escolher;

  @override
  Widget build(BuildContext context) {
    final obj = d['objetivo'] as Doc;
    final p = d['progresso'] as Doc;
    final feitas = p['feitas'] as int, total = p['total'] as int;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 6,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Quero ser:', style: Theme.of(context).textTheme.titleSmall),
              for (final o in (d['objetivos'] as List).cast<Doc>())
                ChoiceChip(
                  label: Text('${o['nome']}'),
                  selected: o['id'] == obj['id'],
                  onSelected: (_) => escolher('${o['id']}'),
                  tooltip: '${o['descricao']}',
                ),
            ],
          ),
          Text('${obj['descricao']}', style: Theme.of(context).textTheme.bodySmall),
          Row(
            spacing: 8,
            children: [
              Expanded(child: LinearProgressIndicator(value: total == 0 ? 0 : feitas / total)),
              Text('$feitas de $total etapas', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ],
      ),
    );
  }
}

Widget _seletorStatus(String item, String atual, Future<void> Function(String, String) marcar) => PopupMenuButton<String>(
  tooltip: 'Status',
  initialValue: atual,
  onSelected: (s) => marcar(item, s),
  itemBuilder: (_) => [for (final e in _status.entries) PopupMenuItem(value: e.key, child: Text(e.value))],
  child: Chip(
    visualDensity: VisualDensity.compact,
    avatar: Icon(
      switch (atual) {
        'feito' => Icons.check_circle,
        'lendo' => Icons.timelapse,
        _ => Icons.radio_button_unchecked,
      },
      size: 18,
      color: atual == 'feito' ? Colors.green : null,
    ),
    label: Text(_status[atual] ?? atual),
  ),
);

/// Capítulo como chip: toque marca lido/não lido; segurar mostra por que ler.
Widget _chipCapitulo(String livro, Doc c, Future<void> Function(String, String) marcar) => Tooltip(
  message: '${c['titulo']}\n${c['porque']}',
  child: FilterChip(
    visualDensity: VisualDensity.compact,
    selected: c['status'] == 'feito',
    avatar: CircleAvatar(backgroundColor: _corPrioridade[c['prioridade']], radius: 5),
    label: Text(RegExp(r'^[0-9IVXL]+$').hasMatch('${c['n']}') ? 'cap. ${c['n']}' : '${c['n']}'),
    onSelected: (v) => marcar('cap:$livro:${c['n']}', v ? 'feito' : 'pendente'),
  ),
);

class _Trilha extends StatelessWidget {
  const _Trilha(this.d, {required this.marcar, required this.ler});

  final Doc d;
  final Future<void> Function(String, String) marcar;
  final Future<void> Function(String, String) ler;

  @override
  Widget build(BuildContext context) {
    final niveis = (d['niveis'] as List).cast<Doc>();
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        for (final n in niveis)
          Card(
            child: ExpansionTile(
              initiallyExpanded: n == niveis.firstWhere(
                (x) => (x['etapas'] as List).any((e) => (e as Doc)['status'] != 'feito'),
                orElse: () => niveis.first,
              ),
              leading: CircleAvatar(child: Text('${n['nivel']}')),
              title: Text('${n['titulo']}'),
              subtitle: Text(
                '${n['resumo']} · ${(n['etapas'] as List).where((e) => (e as Doc)['status'] == 'feito').length}/${(n['etapas'] as List).length}',
              ),
              childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              children: [for (final e in (n['etapas'] as List).cast<Doc>()) _Etapa(e, marcar: marcar, ler: ler)],
            ),
          ),
      ],
    );
  }
}

class _Etapa extends StatelessWidget {
  const _Etapa(this.e, {required this.marcar, required this.ler});

  final Doc e;
  final Future<void> Function(String, String) marcar;
  final Future<void> Function(String, String) ler;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 6,
        children: [
          Row(
            children: [
              Expanded(child: Text('${e['titulo']}', style: t.titleMedium)),
              _seletorStatus('etapa:${e['id']}', '${e['status']}', marcar),
            ],
          ),
          Text('Meta: ${e['meta']}', style: t.bodyMedium?.copyWith(fontStyle: FontStyle.italic)),
          for (final l in (e['leituras'] as List).cast<Doc>())
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                Row(
                  children: [
                    Icon(l['tenho'] == true ? Icons.menu_book : Icons.bookmark_add_outlined, size: 18),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${l['titulo']} — ${l['autor']}${l['tenho'] == true ? '' : ' (recomendado)'}',
                        style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Ler no app (grifos viram citações)',
                      icon: const Icon(Icons.chrome_reader_mode_outlined, size: 20),
                      onPressed: () => ler('livro:${l['livro']}', '${l['titulo']}'),
                    ),
                  ],
                ),
                if (l['inteiro'] == true)
                  Text('Leitura de apoio: veja o guia em Livros para os capítulos.', style: t.bodySmall)
                else ...[
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [for (final c in (l['capitulos'] as List).cast<Doc>()) _chipCapitulo('${l['livro']}', c, marcar)],
                  ),
                  for (final c in (l['capitulos'] as List).cast<Doc>())
                    Text('• ${c['n']} ${c['titulo']}: ${c['porque']}', style: t.bodySmall),
                ],
              ],
            ),
          if ((e['artigos'] as List).isNotEmpty)
            Text('Artigos: ${(e['artigos'] as List).map((a) => (a as Doc)['autores']).join('; ')}', style: t.bodySmall),
          if ((e['relatorios'] as List).isNotEmpty)
            Text('Relatórios: ${(e['relatorios'] as List).map((r) => (r as Doc)['nome']).join('; ')}', style: t.bodySmall),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('Prática: ${e['pratica']}', style: t.bodySmall),
          ),
          const Divider(),
        ],
      ),
    );
  }
}

class _Livros extends StatelessWidget {
  const _Livros(this.d, {required this.marcar, required this.ler, required this.guia, required this.novo, required this.tenho});

  final Doc d;
  final Future<void> Function(String, String) marcar;
  final Future<void> Function(String, String) ler;
  final void Function(Doc) guia;
  final VoidCallback novo;
  final void Function(String, bool) tenho;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final livros = (d['livros'] as List).cast<Doc>();
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Os seus primeiro; depois os recomendados. Bolinha: vermelha essencial, laranja importante, cinza opcional.',
                  style: t.bodySmall),
            ),
            FilledButton.tonalIcon(onPressed: novo, icon: const Icon(Icons.add), label: const Text('Livro que tenho')),
          ],
        ),
        for (final l in livros)
          Card(
            child: ExpansionTile(
              leading: Icon(l['tenho'] == true ? Icons.menu_book : Icons.bookmark_add_outlined),
              title: Text('${l['titulo']}'),
              subtitle: Text([
                '${l['autor']}',
                if ('${l['ano']}'.isNotEmpty) '${l['ano']}',
                if ((l['niveis'] as List).isNotEmpty) 'níveis ${(l['niveis'] as List).join(', ')}',
              ].join(' · ')),
              trailing: _seletorStatus('livro:${l['id']}', '${l['status']}', marcar),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if ('${l['sobre']}'.isNotEmpty) Text('${l['sobre']}'),
                if ('${l['como_ler']}'.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('Como ler', style: t.titleSmall),
                  Text('${l['como_ler']}'),
                ],
                if ((l['ordem'] as List).isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('Ordem sugerida: ${(l['ordem'] as List).join(' → ')}', style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                ],
                for (final c in (l['capitulos'] as List).cast<Doc>())
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: c['status'] == 'feito',
                    onChanged: (v) => marcar('cap:${l['id']}:${c['n']}', v == true ? 'feito' : 'pendente'),
                    title: Row(
                      spacing: 6,
                      children: [
                        CircleAvatar(backgroundColor: _corPrioridade[c['prioridade']], radius: 5),
                        Expanded(child: Text('${c['n']} · ${c['titulo']}')),
                      ],
                    ),
                    subtitle: Text('${c['porque']}'),
                  ),
                if ((l['relacionados'] as List).isNotEmpty)
                  Text('Complementam: ${(l['relacionados'] as List).join('; ')}', style: t.bodySmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    FilterChip(
                      label: const Text('Tenho'),
                      selected: l['tenho'] == true,
                      onSelected: (v) => tenho('${l['id']}', v),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => ler('livro:${l['id']}', '${l['titulo']}'),
                      icon: const Icon(Icons.chrome_reader_mode_outlined),
                      label: const Text('Ler no app'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => guia(l),
                      icon: const Icon(Icons.auto_awesome),
                      label: Text(l['guia_claude'] == true || (l['capitulos'] as List).isNotEmpty
                          ? 'Aprofundar guia com o Claude'
                          : 'Montar guia com o Claude'),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Artigos extends StatelessWidget {
  const _Artigos(this.artigos, {required this.marcar, required this.ler});

  final List<Doc> artigos;
  final Future<void> Function(String, String) marcar;
  final Future<void> Function(String, String) ler;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(8),
    children: [
      Text('Artigos que fundamentam o que os livros dizem. Leia o resumo (abstract), a introdução e a conclusão; '
          'tabelas só depois. O link abre a busca no Google Acadêmico (muitos têm PDF gratuito).',
          style: Theme.of(context).textTheme.bodySmall),
      for (final a in artigos)
        Card(
          child: ListTile(
            leading: CircleAvatar(child: Text('${a['nivel']}')),
            title: Text('${a['autores']} — ${a['titulo']}'),
            subtitle: Text('${a['revista']}\n${a['porque']}'),
            isThreeLine: true,
            onTap: () => abrirLink(context, '${a['url']}'),
            trailing: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _seletorStatus('artigo:${a['id']}', '${a['status']}', marcar),
              ],
            ),
            onLongPress: () => ler('artigo:${a['id']}', '${a['titulo']}'),
          ),
        ),
      Text('Segure um artigo para colocá-lo em Leituras e ler o PDF com grifos.', style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}

class _Relatorios extends StatelessWidget {
  const _Relatorios(this.relatorios, {required this.marcar});

  final List<Doc> relatorios;
  final Future<void> Function(String, String) marcar;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        for (final r in relatorios)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: [
                  Row(
                    children: [
                      CircleAvatar(radius: 14, child: Text('${r['nivel']}')),
                      const SizedBox(width: 8),
                      Expanded(child: Text('${r['nome']}', style: t.titleMedium)),
                      _seletorStatus('relatorio:${r['id']}', '${r['status']}', marcar),
                    ],
                  ),
                  Text('${r['emissor']}', style: t.bodySmall),
                  for (final passo in (r['como_ler'] as List)) Text('• $passo'),
                  if ('${r['no_app']}'.isNotEmpty) Text('No app: ${r['no_app']}', style: t.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => abrirLink(context, '${r['url']}'),
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: const Text('Abrir fonte'),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _Citacoes extends StatefulWidget {
  const _Citacoes({required this.api, this.arquivos});

  final ApiFinancas api;
  final ApiArquivos? arquivos;

  @override
  State<_Citacoes> createState() => _CitacoesState();
}

class _CitacoesState extends State<_Citacoes> {
  late Future<Doc> _dados = widget.api.estudoCitacoes();

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: () async => setState(() => _dados = widget.api.estudoCitacoes()),
    child: Esperar(
      futuro: _dados,
      recarregar: () => setState(() => _dados = widget.api.estudoCitacoes()),
      construir: (d) {
        final obras = (d['obras'] as List).cast<Doc>();
        final t = Theme.of(context).textTheme;
        return ListView(
          padding: const EdgeInsets.all(8),
          children: [
            Text(
              obras.isEmpty
                  ? 'Nada grifado ainda. Use "Ler no app" num livro ou artigo: o projeto "Trilha de Finanças" fica ativo no '
                      'leitor e cada grifo ou comentário aparece aqui, com a citação pronta. A matriz completa (e o .xlsx) '
                      'está em Estudos › Leituras › Projetos.'
                  : 'Grifos e comentários do projeto "Trilha de Finanças". Puxe para atualizar.',
              style: t.bodySmall,
            ),
            for (final o in obras)
              Card(
                child: ExpansionTile(
                  initiallyExpanded: obras.length == 1,
                  title: Text('${o['titulo']}'),
                  subtitle: Text('${(o['itens'] as List).length} trecho(s)'),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  children: [
                    for (final i in (o['itens'] as List).cast<Doc>())
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('“${i['texto']}”', style: t.bodyMedium?.copyWith(fontStyle: FontStyle.italic)),
                        subtitle: Text([
                          if ('${i['comentario']}'.isNotEmpty) 'Nota: ${i['comentario']}',
                          [if ('${i['citacao']}'.isNotEmpty) '${i['citacao']}', if (i['pagina'] != 0) 'p. ${i['pagina']}'].join(' · '),
                        ].where((x) => x.isNotEmpty).join('\n')),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    ),
  );
}
