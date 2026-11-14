import 'package:agent_arquivos/agent_arquivos.dart';
import 'package:agent_core/agent_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../finance_api.dart';
import '../format.dart';
import 'common.dart';

/// Finance studies: objective, track by levels (each step with the right book and chapters,
/// articles, reports and a practice in the app), guide of each book, scientific articles, reports
/// to practice and the quotes highlighted in the reader ("Trilha de Finanças" project).
class FinanceStudyScreen extends StatefulWidget {
  const FinanceStudyScreen({super.key, required this.api, this.files});

  final FinanceApi api;
  final FilesApi? files;

  @override
  State<FinanceStudyScreen> createState() => _FinanceStudyScreenState();
}

const _status = {'pendente': 'A fazer', 'lendo': 'Estudando', 'feito': 'Feito'};

const _priorityColor = {'essencial': Colors.red, 'importante': Colors.orange, 'opcional': Colors.grey};

class _FinanceStudyScreenState extends State<FinanceStudyScreen> {
  late Future<Doc> _dados = widget.api.study();

  void _reload() => setState(() => _dados = widget.api.study());

  Future<void> _mark(String item, String status) async {
    if (await tentar(context, () => widget.api.studyMark(item, status: status))) _reload();
  }

  /// Reading in Estudos › Leituras and "Trilha de Finanças" project active in the reader; then
  /// picks the PDF to read here (highlights and comments become track quotes).
  Future<void> _read(String item, String title) async {
    Doc? r;
    if (!await tentar(context, () async => r = await widget.api.studyRead(item))) return;
    final project = '${r!['projeto_id']}';
    activeProjects.value = {...activeProjects.value, project}.toList();
    _reload();
    final reader = widget.files;
    if (!mounted || reader == null) return;
    final choice = await showModalBottomSheet<bool>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(title),
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
    if (choice != true || !mounted) return;
    final f = await FilePicker.pickFiles(dialogTitle: title, type: FileType.custom, allowedExtensions: ['pdf']);
    if (f.isEmpty || !mounted) return;
    final bytes = await f.first.xFile.readAsBytes();
    if (mounted) await openPreview(context, reader, f.first.name, bytes, pasta: 'Finanças/Estudos');
  }

  /// Claude builds the book guide in the background (it can take a few minutes).
  void _guide(Doc book) {
    Tarefas.instancia.rodar<Doc>('Guia de leitura: ${book['titulo']}', (t) async {
      t.atualizar(detalhe: 'O Claude está montando o guia…');
      final r = await widget.api.studyGuide('${book['id']}', isCancelled: () => t.cancelada);
      if (mounted) _reload();
      return r;
    });
    avisar(context, 'O Claude está montando o guia. Acompanhe no sino 🔔.');
  }

  Future<void> _newBook() async {
    final d = await form(context, 'Livro que eu tenho', const [
      FormFieldSpec('titulo', 'Título', isRequired: true),
      FormFieldSpec('autor', 'Autor'),
    ]);
    if (d == null || !mounted) return;
    Doc? book;
    if (await tentar(context, () async => book = await widget.api.studyNewBook('${d['titulo']}', '${d['autor'] ?? ''}'))) {
      _reload();
      if (mounted) _guide(book!);
    }
  }

  @override
  Widget build(BuildContext context) => Waiting(
    future: _dados,
    reload: _reload,
    construir: (d) => DefaultTabController(
      length: 5,
      child: Column(
        children: [
          _Objective(d, (id) async {
            if (await tentar(context, () => widget.api.studyObjective(id))) _reload();
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
                _Track(d, mark: _mark, read: _read),
                _Books(d, mark: _mark, read: _read, guide: _guide, isNew: _newBook, owned: (id, v) async {
                  if (await tentar(context, () => widget.api.studyOwned(id, v))) _reload();
                }),
                _Articles((d['artigos'] as List).cast<Doc>(), mark: _mark, read: _read),
                _Reports((d['relatorios'] as List).cast<Doc>(), mark: _mark),
                _Quotes(api: widget.api, files: widget.files),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _Objective extends StatelessWidget {
  const _Objective(this.d, this.pick);

  final Doc d;
  final ValueChanged<String> pick;

  @override
  Widget build(BuildContext context) {
    final obj = d['objetivo'] as Doc;
    final p = d['progresso'] as Doc;
    final done = p['feitas'] as int, total = p['total'] as int;
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
                  onSelected: (_) => pick('${o['id']}'),
                  tooltip: '${o['descricao']}',
                ),
            ],
          ),
          Text('${obj['descricao']}', style: Theme.of(context).textTheme.bodySmall),
          Row(
            spacing: 8,
            children: [
              Expanded(child: LinearProgressIndicator(value: total == 0 ? 0 : done / total)),
              Text('$done de $total etapas', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ],
      ),
    );
  }
}

Widget _statusPicker(String item, String current, Future<void> Function(String, String) mark) => PopupMenuButton<String>(
  tooltip: 'Status',
  initialValue: current,
  onSelected: (s) => mark(item, s),
  itemBuilder: (_) => [for (final e in _status.entries) PopupMenuItem(value: e.key, child: Text(e.value))],
  child: Chip(
    visualDensity: VisualDensity.compact,
    avatar: Icon(
      switch (current) {
        'feito' => Icons.check_circle,
        'lendo' => Icons.timelapse,
        _ => Icons.radio_button_unchecked,
      },
      size: 18,
      color: current == 'feito' ? Colors.green : null,
    ),
    label: Text(_status[current] ?? current),
  ),
);

/// Chapter as a chip: tap marks read/unread; holding shows why to read it.
Widget _chapterChip(String book, Doc c, Future<void> Function(String, String) mark) => Tooltip(
  message: '${c['titulo']}\n${c['porque']}',
  child: FilterChip(
    visualDensity: VisualDensity.compact,
    selected: c['status'] == 'feito',
    avatar: CircleAvatar(backgroundColor: _priorityColor[c['prioridade']], radius: 5),
    label: Text(RegExp(r'^[0-9IVXL]+$').hasMatch('${c['n']}') ? 'cap. ${c['n']}' : '${c['n']}'),
    onSelected: (v) => mark('cap:$book:${c['n']}', v ? 'feito' : 'pendente'),
  ),
);

class _Track extends StatelessWidget {
  const _Track(this.d, {required this.mark, required this.read});

  final Doc d;
  final Future<void> Function(String, String) mark;
  final Future<void> Function(String, String) read;

  @override
  Widget build(BuildContext context) {
    final levels = (d['niveis'] as List).cast<Doc>();
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        for (final n in levels)
          Card(
            child: ExpansionTile(
              initiallyExpanded: n == levels.firstWhere(
                (x) => (x['etapas'] as List).any((e) => (e as Doc)['status'] != 'feito'),
                orElse: () => levels.first,
              ),
              leading: CircleAvatar(child: Text('${n['nivel']}')),
              title: Text('${n['titulo']}'),
              subtitle: Text(
                '${n['resumo']} · ${(n['etapas'] as List).where((e) => (e as Doc)['status'] == 'feito').length}/${(n['etapas'] as List).length}',
              ),
              childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              children: [for (final e in (n['etapas'] as List).cast<Doc>()) _Step(e, mark: mark, read: read)],
            ),
          ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step(this.e, {required this.mark, required this.read});

  final Doc e;
  final Future<void> Function(String, String) mark;
  final Future<void> Function(String, String) read;

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
              _statusPicker('etapa:${e['id']}', '${e['status']}', mark),
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
                      onPressed: () => read('livro:${l['livro']}', '${l['titulo']}'),
                    ),
                  ],
                ),
                if (l['inteiro'] == true)
                  Text('Leitura de apoio: veja o guia em Livros para os capítulos.', style: t.bodySmall)
                else ...[
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [for (final c in (l['capitulos'] as List).cast<Doc>()) _chapterChip('${l['livro']}', c, mark)],
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

class _Books extends StatelessWidget {
  const _Books(this.d, {required this.mark, required this.read, required this.guide, required this.isNew, required this.owned});

  final Doc d;
  final Future<void> Function(String, String) mark;
  final Future<void> Function(String, String) read;
  final void Function(Doc) guide;
  final VoidCallback isNew;
  final void Function(String, bool) owned;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final books = (d['livros'] as List).cast<Doc>();
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Os seus primeiro; depois os recomendados. Bolinha: vermelha essencial, laranja importante, cinza opcional.',
                  style: t.bodySmall),
            ),
            FilledButton.tonalIcon(onPressed: isNew, icon: const Icon(Icons.add), label: const Text('Livro que tenho')),
          ],
        ),
        for (final l in books)
          Card(
            child: ExpansionTile(
              leading: Icon(l['tenho'] == true ? Icons.menu_book : Icons.bookmark_add_outlined),
              title: Text('${l['titulo']}'),
              subtitle: Text([
                '${l['autor']}',
                if ('${l['ano']}'.isNotEmpty) '${l['ano']}',
                if ((l['niveis'] as List).isNotEmpty) 'níveis ${(l['niveis'] as List).join(', ')}',
              ].join(' · ')),
              trailing: _statusPicker('livro:${l['id']}', '${l['status']}', mark),
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
                    onChanged: (v) => mark('cap:${l['id']}:${c['n']}', v == true ? 'feito' : 'pendente'),
                    title: Row(
                      spacing: 6,
                      children: [
                        CircleAvatar(backgroundColor: _priorityColor[c['prioridade']], radius: 5),
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
                      onSelected: (v) => owned('${l['id']}', v),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => read('livro:${l['id']}', '${l['titulo']}'),
                      icon: const Icon(Icons.chrome_reader_mode_outlined),
                      label: const Text('Ler no app'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => guide(l),
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

class _Articles extends StatelessWidget {
  const _Articles(this.articles, {required this.mark, required this.read});

  final List<Doc> articles;
  final Future<void> Function(String, String) mark;
  final Future<void> Function(String, String) read;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(8),
    children: [
      Text('Artigos que fundamentam o que os livros dizem. Leia o resumo (abstract), a introdução e a conclusão; '
          'tabelas só depois. O link abre a busca no Google Acadêmico (muitos têm PDF gratuito).',
          style: Theme.of(context).textTheme.bodySmall),
      for (final a in articles)
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
                _statusPicker('artigo:${a['id']}', '${a['status']}', mark),
              ],
            ),
            onLongPress: () => read('artigo:${a['id']}', '${a['titulo']}'),
          ),
        ),
      Text('Segure um artigo para colocá-lo em Leituras e ler o PDF com grifos.', style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}

class _Reports extends StatelessWidget {
  const _Reports(this.reports, {required this.mark});

  final List<Doc> reports;
  final Future<void> Function(String, String) mark;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        for (final r in reports)
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
                      _statusPicker('relatorio:${r['id']}', '${r['status']}', mark),
                    ],
                  ),
                  Text('${r['emissor']}', style: t.bodySmall),
                  for (final step in (r['como_ler'] as List)) Text('• $step'),
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

class _Quotes extends StatefulWidget {
  const _Quotes({required this.api, this.files});

  final FinanceApi api;
  final FilesApi? files;

  @override
  State<_Quotes> createState() => _QuotesState();
}

class _QuotesState extends State<_Quotes> {
  late Future<Doc> _dados = widget.api.studyQuotes();

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: () async => setState(() => _dados = widget.api.studyQuotes()),
    child: Waiting(
      future: _dados,
      reload: () => setState(() => _dados = widget.api.studyQuotes()),
      construir: (d) {
        final works = (d['obras'] as List).cast<Doc>();
        final t = Theme.of(context).textTheme;
        return ListView(
          padding: const EdgeInsets.all(8),
          children: [
            Text(
              works.isEmpty
                  ? 'Nada grifado ainda. Use "Ler no app" num livro ou artigo: o projeto "Trilha de Finanças" fica ativo no '
                      'leitor e cada grifo ou comentário aparece aqui, com a citação pronta. A matriz completa (e o .xlsx) '
                      'está em Estudos › Leituras › Projetos.'
                  : 'Grifos e comentários do projeto "Trilha de Finanças". Puxe para atualizar.',
              style: t.bodySmall,
            ),
            for (final o in works)
              Card(
                child: ExpansionTile(
                  initiallyExpanded: works.length == 1,
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
