import 'dart:math';

import 'package:agent_core/agent_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../studies_api.dart';
import '../models.dart';
import 'readings_screen.dart';
import 'mapping_panel.dart';

/// Opens file [fileId] in the reader of the Arquivos module at [page] (1 = first). The platform
/// links the two modules; without it (tests), the "Ver no arquivo" button disappears.
typedef OpenInFile = Future<void> Function(BuildContext context, String fileId, int page);

/// Leituras section: the list of books/articles and the reading projects (citation matrix).
class ReadingsAndProjects extends StatefulWidget {
  const ReadingsAndProjects({super.key, required this.api, required this.options, this.openInFile});

  final StudiesApi api;
  final StudyOptions options;
  final OpenInFile? openInFile;

  @override
  State<ReadingsAndProjects> createState() => _ReadingsAndProjectsState();
}

class _ReadingsAndProjectsState extends State<ReadingsAndProjects> {
  int _vista = 1;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
        child: Center(
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, icon: Icon(Icons.menu_book_outlined), label: Text('Leituras')),
              ButtonSegment(value: 1, icon: Icon(Icons.hub_outlined), label: Text('Projetos')),
            ],
            selected: {_vista},
            onSelectionChanged: (v) => setState(() => _vista = v.first),
          ),
        ),
      ),
      Expanded(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          switchInCurve: Curves.easeOutCubic,
          transitionBuilder: (c, a) => FadeTransition(
            opacity: a,
            child: SlideTransition(
              position: Tween(begin: const Offset(0, 0.03), end: Offset.zero).animate(a),
              child: c,
            ),
          ),
          child: _vista == 0
              ? ReadingsScreen(key: const ValueKey('leituras'), api: widget.api, options: widget.options)
              : ReadingProjectsScreen(
                  key: const ValueKey('projetos'),
                  api: widget.api,
                  options: widget.options,
                  openInFile: widget.openInFile,
                ),
        ),
      ),
    ],
  );
}

const _projectColors = [0xFF3F51B5, 0xFF00897B, 0xFFE65100, 0xFF8E24AA, 0xFFC62828, 0xFF2E7D32, 0xFF1565C0, 0xFF6D4C41];

/// Shows up sliding and fading in, delayed by position (cascading list).
class _Entry extends StatelessWidget {
  const _Entry({required this.score, required this.child});

  final int score;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: Duration(milliseconds: 280 + min(score, 12) * 45),
    curve: Curves.easeOutCubic,
    builder: (context, t, child) => Opacity(
      opacity: t,
      child: Transform.translate(offset: Offset(0, (1 - t) * 18), child: child),
    ),
    child: child,
  );
}

/// Reading projects as cards; each one opens the citation matrix.
class ReadingProjectsScreen extends StatefulWidget {
  const ReadingProjectsScreen({super.key, required this.api, required this.options, this.openInFile});

  final StudiesApi api;
  final StudyOptions options;
  final OpenInFile? openInFile;

  @override
  State<ReadingProjectsScreen> createState() => _ReadingProjectsScreenState();
}

class _ReadingProjectsScreenState extends State<ReadingProjectsScreen> {
  List<ReadingProject>? _projects;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await widget.api.projects();
      if (mounted) {
        setState(() {
          _projects = p;
          _error = null;
        });
      }
    } on ApiErro catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _form([ReadingProject? current]) async {
    final data = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _ProjectForm(current: current),
    );
    if (data == null || !mounted) return;
    try {
      if (current != null && data['_excluir'] == true) {
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text('Excluir "${current.name}"?'),
            content: const Text('Os trechos e anotações continuam nos arquivos; só o projeto e a classificação somem.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Excluir')),
            ],
          ),
        );
        if (ok != true) return;
        await widget.api.deleteProject(current.id);
      } else {
        current == null ? await widget.api.createProject(data) : await widget.api.editProject(current.id, data);
      }
      await _load();
    } on ApiErro catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _open(ReadingProject p) async {
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 350),
        reverseTransitionDuration: const Duration(milliseconds: 250),
        pageBuilder: (_, _, _) =>
            ProjectScreen(api: widget.api, options: widget.options, project: p, openInFile: widget.openInFile),
        transitionsBuilder: (_, a, _, child) {
          final curve = CurvedAnimation(parent: a, curve: Curves.easeOutCubic);
          return FadeTransition(
            opacity: curve,
            child: ScaleTransition(scale: Tween(begin: 0.97, end: 1.0).animate(curve), child: child),
          );
        },
      ),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            Text(_error!),
            FilledButton(onPressed: _load, child: const Text('Tentar de novo')),
          ],
        ),
      );
    }
    final projects = _projects;
    if (projects == null) return const Center(child: CircularProgressIndicator());
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'novo-projeto-leitura',
        onPressed: _form,
        icon: const Icon(Icons.add),
        label: const Text('Projeto'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: projects.isEmpty
            ? ListView(
                padding: const EdgeInsets.all(32),
                children: const [
                  Icon(Icons.hub_outlined, size: 56),
                  SizedBox(height: 12),
                  Text(
                    'Crie um projeto (ex.: Pré-TCC). Depois, no leitor do módulo Arquivos, escolha o projeto '
                    'ativo no topo: todo trecho marcado, comentário e anotação à mão entra nele.',
                    textAlign: TextAlign.center,
                  ),
                ],
              )
            : GridView.builder(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 420,
                  mainAxisExtent: 168,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemCount: projects.length,
                itemBuilder: (context, i) => _Entry(
                  score: i,
                  child: _ProjectCard(
                    project: projects[i],
                    onOpen: () => _open(projects[i]),
                    onEdit: () => _form(projects[i]),
                  ),
                ),
              ),
      ),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({required this.project, required this.onOpen, required this.onEdit});

  final ReadingProject project;
  final VoidCallback onOpen;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = Color(project.color);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Container(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: color, width: 5)),
            gradient: LinearGradient(colors: [color.withValues(alpha: 0.10), Colors.transparent]),
          ),
          padding: const EdgeInsets.fromLTRB(16, 10, 6, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      project.name,
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(tooltip: 'Editar projeto', icon: const Icon(Icons.edit_outlined), onPressed: onEdit),
                ],
              ),
              if (project.descricao.isNotEmpty)
                Text(project.descricao, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
              const Spacer(),
              Wrap(
                spacing: 14,
                runSpacing: 4,
                children: [
                  _Stat(Icons.article_outlined, project.papers, 'trabalhos'),
                  _Stat(Icons.format_quote, project.excerpts, 'trechos'),
                  _Stat(Icons.lightbulb_outline, project.comments, 'comentários'),
                  _Stat(Icons.draw_outlined, project.handwritings, 'à mão'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.icone, this.value, this.label);

  final IconData icone;
  final int value;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: 4,
    children: [
      Icon(icone, size: 16),
      TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: value.toDouble()),
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeOutCubic,
        builder: (context, v, _) => Text('${v.round()}', style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
      Text(label, style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}

class _ProjectForm extends StatefulWidget {
  const _ProjectForm({this.current});

  final ReadingProject? current;

  @override
  State<_ProjectForm> createState() => _ProjectFormState();
}

class _ProjectFormState extends State<_ProjectForm> {
  late final _nome = TextEditingController(text: widget.current?.name);
  late final _description = TextEditingController(text: widget.current?.descricao);
  late final _sections = TextEditingController(text: widget.current?.sections.join('\n'));
  late int _color = widget.current?.color ?? _projectColors.first;

  @override
  void dispose() {
    for (final c in [_nome, _description, _sections]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.current == null ? 'Novo projeto de leitura' : 'Editar projeto'),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            TextField(
              controller: _nome,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Nome', hintText: 'Ex.: Pré-TCC'),
            ),
            TextField(
              controller: _description,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Descrição (opcional)'),
            ),
            TextField(
              controller: _sections,
              minLines: 3,
              maxLines: 10,
              decoration: const InputDecoration(
                labelText: 'Seções (uma por linha)',
                hintText: '1 Introdução\n2 Referencial Teórico\n4.2.2 Estratégia PICo',
                helperText: 'Usadas para classificar os trechos e no painel de cobertura.',
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in _projectColors)
                  InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => setState(() => _color = c),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: Color(c),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _color == c ? Theme.of(context).colorScheme.onSurface : Colors.transparent,
                          width: 3,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
    actions: [
      if (widget.current != null)
        TextButton(
          onPressed: () => Navigator.pop(context, {'_excluir': true}),
          child: Text('Excluir', style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(
        onPressed: () {
          if (_nome.text.trim().isEmpty) return;
          Navigator.pop(context, {
            'nome': _nome.text.trim(),
            'descricao': _description.text.trim(),
            'cor': _color,
            'secoes': [
              for (final s in _sections.text.split('\n'))
                if (s.trim().isNotEmpty) s.trim(),
            ],
          });
        },
        child: const Text('Salvar'),
      ),
    ],
  );
}

enum _Tab { excerpts, papers, coverage }

/// Knowledge matrix of a project: excerpts (original, translation, comment, citation),
/// papers (citation sheet) and coverage per section; exports to a spreadsheet.
class ProjectScreen extends StatefulWidget {
  const ProjectScreen({super.key, required this.api, required this.options, required this.project, this.openInFile});

  final StudiesApi api;
  final StudyOptions options;
  final ReadingProject project;
  final OpenInFile? openInFile;

  @override
  State<ProjectScreen> createState() => _ProjectScreenState();
}

class _ProjectScreenState extends State<ProjectScreen> {
  Matrix? _matrix;
  String? _error;
  _Tab _tab = _Tab.excerpts;
  String _search = '';
  String? _type;
  String? _paper;
  String? _section;
  String? _status;
  bool _exporting = false;

  StudiesApi get api => widget.api;
  ReadingProject get project => _matrix?.project ?? widget.project;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final m = await api.matrix(widget.project.id);
      if (mounted) {
        setState(() {
          _matrix = m;
          _error = null;
        });
      }
    } on ApiErro catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _notify(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      final bytes = await api.exportProject(project.id);
      final name = 'Matriz - ${project.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '')}.xlsx';
      final salvo = await FilePicker.saveFile(fileName: name, bytes: bytes);
      if (salvo != null && mounted) _notify('Planilha exportada: $name');
    } on ApiErro catch (e) {
      if (mounted) _notify('Não deu para exportar: ${e.mensagem}');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _editProject() async {
    final data = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _ProjectForm(current: project),
    );
    if (data == null || !mounted) return;
    try {
      if (data['_excluir'] == true) {
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text('Excluir "${project.name}"?'),
            content: const Text('Os trechos e anotações continuam nos arquivos; só o projeto e a classificação somem.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Excluir')),
            ],
          ),
        );
        if (ok != true) return;
        await api.deleteProject(project.id);
        if (mounted) Navigator.pop(context);
        return;
      }
      await api.editProject(project.id, data);
      await _load();
    } on ApiErro catch (e) {
      if (mounted) _notify('$e');
    }
  }

  List<MatrixItem> _filtered(Matrix m) {
    final term = _search.trim().toLowerCase();
    return [
      for (final i in m.itens)
        if ((_type == null || i.type == _type) &&
            (_paper == null || i.paper == _paper) &&
            (_section == null || i.field('secao') == _section) &&
            (_status == null || i.field('status_uso') == _status) &&
            (term.isEmpty || i.search.contains(term)))
          i,
    ];
  }

  Future<void> _classify(MatrixItem item) async {
    final m = _matrix;
    if (m == null) return;
    final paper = m.papers.where((t) => t.code == item.paper).firstOrNull;
    final data = await showAdaptiveSheet<Map<String, String>>(
      context,
      (_) => _ItemSheet(
        item: item,
        paper: paper,
        options: widget.options,
        sections: {...project.sections, for (final i in m.itens) i.field('secao')}.where((s) => s.isNotEmpty).toList(),
        openInFile: widget.openInFile,
      ),
    );
    if (data == null) return;
    try {
      await api.classify(project.id, item.id, data);
      await _load();
    } on ApiErro catch (e) {
      if (mounted) _notify('$e');
    }
  }

  Future<void> _sheet(MatrixPaper t) async {
    final data = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _PaperSheet(paper: t),
    );
    if (data == null) return;
    try {
      final id = t.readingId;
      if (id == null) {
        await api.createReading({
          ...data,
          'tipo': 'artigo',
          'area': widget.options.areas.firstOrNull ?? 'Tecnologia',
          'status': 'lendo',
          'arquivo_id': t.fileId,
        });
      } else {
        await api.editReading(id, data);
      }
      await _load();
    } on ApiErro catch (e) {
      if (mounted) _notify('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = _matrix;
    final band = Faixa.de(context);
    return Scaffold(
      appBar: AppBar(
        title: Row(
          spacing: 10,
          children: [
            CircleAvatar(radius: 7, backgroundColor: Color(project.color)),
            Flexible(child: Text(project.name, overflow: TextOverflow.ellipsis)),
          ],
        ),
        actions: [
          IconButton(tooltip: 'Atualizar', icon: const Icon(Icons.refresh), onPressed: _load),
          IconButton(tooltip: 'Editar projeto', icon: const Icon(Icons.edit_outlined), onPressed: _editProject),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: _exporting
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : band.celular
                  ? IconButton(
                      tooltip: 'Exportar planilha',
                      icon: const Icon(Icons.file_download_outlined),
                      onPressed: m == null ? null : _export,
                    )
                  : FilledButton.tonalIcon(
                      icon: const Icon(Icons.table_view_outlined),
                      label: const Text('Exportar planilha'),
                      onPressed: m == null ? null : _export,
                    ),
            ),
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                spacing: 12,
                children: [
                  Text(_error!),
                  FilledButton(onPressed: _load, child: const Text('Tentar de novo')),
                ],
              ),
            )
          : m == null
          ? const Center(child: CircularProgressIndicator())
          : LarguraMaxima(
              largura: 1800,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Summary(matrix: m),
                  MappingPanel(
                    api: api,
                    projectId: widget.project.id,
                    openInFile: widget.openInFile,
                    onComplete: _load,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: SegmentedButton<_Tab>(
                      showSelectedIcon: !band.celular,
                      segments: [
                        ButtonSegment(
                          value: _Tab.excerpts,
                          icon: const Icon(Icons.format_quote),
                          label: Text('Trechos (${m.itens.length})'),
                        ),
                        ButtonSegment(
                          value: _Tab.papers,
                          icon: const Icon(Icons.article_outlined),
                          label: Text('Trabalhos (${m.papers.length})'),
                        ),
                        const ButtonSegment(
                          value: _Tab.coverage,
                          icon: Icon(Icons.grid_view),
                          label: Text('Cobertura'),
                        ),
                      ],
                      selected: {_tab},
                      onSelectionChanged: (v) => setState(() => _tab = v.first),
                    ),
                  ),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 280),
                      switchInCurve: Curves.easeOutCubic,
                      transitionBuilder: (c, a) => FadeTransition(opacity: a, child: c),
                      child: switch (_tab) {
                        _Tab.excerpts => KeyedSubtree(key: const ValueKey('trechos'), child: _excerpts(m)),
                        _Tab.papers => KeyedSubtree(key: const ValueKey('trabalhos'), child: _papers(m)),
                        _Tab.coverage => KeyedSubtree(key: const ValueKey('cobertura'), child: _coverage(m)),
                      },
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _filters(Matrix m) {
    final sections = {for (final i in m.itens) i.field('secao')}.where((s) => s.isNotEmpty).toList()..sort();
    Widget menu(String label, String? value, Map<String?, String> options, ValueChanged<String?> aoMudar) =>
        PopupMenuButton<String?>(
          tooltip: label,
          onSelected: aoMudar,
          itemBuilder: (_) => [
            for (final e in options.entries)
              CheckedPopupMenuItem(value: e.key, checked: value == e.key, child: Text(e.value)),
          ],
          child: Chip(
            avatar: Icon(value == null ? Icons.filter_list : Icons.filter_alt, size: 18),
            label: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: Text(value == null ? label : options[value] ?? value, overflow: TextOverflow.ellipsis),
            ),
            backgroundColor: value == null ? null : Theme.of(context).colorScheme.secondaryContainer,
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: min(MediaQuery.sizeOf(context).width - 24, 340),
            child: TextField(
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search),
                hintText: 'Buscar no trecho, tradução, comentário…',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _search = v),
            ),
          ),
          menu('Tipo', _type, const {
            null: 'Todos os tipos',
            'destaque': 'Trechos marcados',
            'texto': 'Comentários na página',
            'manuscrito': 'Anotações à mão',
          }, (v) => setState(() => _type = v)),
          menu('Trabalho', _paper, {
            null: 'Todos os trabalhos',
            for (final t in m.papers)
              t.code: '${t.code} · ${t.citationAuthor.isEmpty ? t.title : t.citationAuthor}',
          }, (v) => setState(() => _paper = v)),
          if (sections.isNotEmpty)
            menu('Seção', _section, {
              null: 'Todas as seções',
              for (final s in sections) s: s,
            }, (v) => setState(() => _section = v)),
          menu('Status', _status, {
            null: 'Qualquer status',
            for (final s in widget.options.statusUso) s: s,
          }, (v) => setState(() => _status = v)),
        ],
      ),
    );
  }

  Widget _excerpts(Matrix m) {
    final itens = _filtered(m);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _filters(m),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: m.itens.isEmpty
                ? ListView(
                    padding: const EdgeInsets.all(32),
                    children: const [
                      Text(
                        'Nada ligado a este projeto ainda. No leitor de Arquivos, escolha este projeto no botão '
                        'de projeto (topo) e marque trechos, escreva ou anote à mão; ou toque num destaque e '
                        'ligue-o ao projeto.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  )
                : itens.isEmpty
                ? ListView(
                    padding: const EdgeInsets.all(32),
                    children: const [Text('Nada com esses filtros.', textAlign: TextAlign.center)],
                  )
                : LayoutBuilder(
                    builder: (context, area) {
                      final columns = max(1, min(3, (area.maxWidth / 480).floor()));
                      final width = (area.maxWidth - 24 - (columns - 1) * 12) / columns;
                      return SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            for (final (n, i) in itens.indexed)
                              SizedBox(
                                key: ValueKey(i.id),
                                width: width,
                                child: _Entry(
                                  score: n,
                                  child: _ItemCard(item: i, onItemTap: () => _classify(i)),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  Widget _papers(Matrix m) => ListView.builder(
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
    itemCount: m.papers.length,
    itemBuilder: (context, n) {
      final t = m.papers[n];
      final theme = Theme.of(context);
      return _Entry(
        score: n,
        child: Card(
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _sheet(t),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 6,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Chip(label: Text(t.code), visualDensity: VisualDensity.compact),
                      Text(
                        t.citationAuthor.isEmpty
                            ? 'Autor não informado'
                            : '${t.citationAuthor} (${t.year.isEmpty ? 's.d.' : t.year})',
                        style: theme.textTheme.titleSmall,
                      ),
                      if (t.citationAuthor.isEmpty || t.year.isEmpty)
                        Text(
                          'Complete a ficha para citar',
                          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.error),
                        ),
                    ],
                  ),
                  Text(t.title, style: theme.textTheme.titleMedium),
                  if (t.reference.isNotEmpty) SelectableText(t.reference, style: theme.textTheme.bodySmall),
                  Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: TweenAnimationBuilder<double>(
                            tween: Tween(begin: 0, end: t.excerpts == 0 ? 0 : t.usedItems / t.excerpts),
                            duration: const Duration(milliseconds: 700),
                            curve: Curves.easeOutCubic,
                            builder: (_, v, _) => LinearProgressIndicator(value: v, minHeight: 6),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text('${t.usedItems}/${t.excerpts} usados', style: theme.textTheme.bodySmall),
                      if (widget.openInFile != null)
                        IconButton(
                          tooltip: 'Abrir o arquivo',
                          icon: const Icon(Icons.open_in_new),
                          onPressed: () => widget.openInFile!(context, t.fileId, 1),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _coverage(Matrix m) {
    final counts = <String, (int, int)>{for (final s in project.sections) s: (0, 0)};
    for (final i in m.itens) {
      final s = i.field('secao').isEmpty ? 'Não definido' : i.field('secao');
      final (total, usedItems) = counts[s] ?? (0, 0);
      counts[s] = (total + 1, usedItems + (i.used ? 1 : 0));
    }
    final larger = counts.values.fold<int>(1, (a, c) => max(a, c.$1));
    final theme = Theme.of(context);
    // Paper × section: how many excerpts of each paper feed each section.
    final crossed = <(String, String), int>{};
    for (final i in m.itens) {
      final s = i.field('secao').isEmpty ? 'Não definido' : i.field('secao');
      crossed[(i.paper, s)] = (crossed[(i.paper, s)] ?? 0) + 1;
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
      children: [
        Text('Trechos por seção', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        if (counts.isEmpty) const Text('Defina seções no projeto (Editar projeto) e classifique os trechos.'),
        for (final (n, e) in counts.entries.indexed)
          _Entry(
            score: n,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(e.key, overflow: TextOverflow.ellipsis)),
                      Text('${e.value.$2} usados · ${e.value.$1} trechos', style: theme.textTheme.bodySmall),
                    ],
                  ),
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: e.value.$1 / larger),
                    duration: const Duration(milliseconds: 700),
                    curve: Curves.easeOutCubic,
                    builder: (_, v, _) => Stack(
                      children: [
                        Container(
                          height: 10,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(5),
                          ),
                        ),
                        FractionallySizedBox(
                          widthFactor: v,
                          child: Container(
                            height: 10,
                            decoration: BoxDecoration(
                              color: Color(project.color).withValues(alpha: 0.45),
                              borderRadius: BorderRadius.circular(5),
                            ),
                          ),
                        ),
                        FractionallySizedBox(
                          widthFactor: e.value.$1 == 0 ? 0 : v * e.value.$2 / e.value.$1,
                          child: Container(
                            height: 10,
                            decoration: BoxDecoration(
                              color: Color(project.color),
                              borderRadius: BorderRadius.circular(5),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 20),
        Text('Matriz trabalho × seção', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowHeight: 40,
            dataRowMinHeight: 36,
            dataRowMaxHeight: 44,
            columnSpacing: 18,
            columns: [
              const DataColumn(label: Text('Trabalho')),
              for (final s in counts.keys)
                DataColumn(
                  numeric: true,
                  label: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 140),
                    child: Text(s, overflow: TextOverflow.ellipsis),
                  ),
                ),
            ],
            rows: [
              for (final t in m.papers)
                DataRow(
                  cells: [
                    DataCell(Text('${t.code} · ${t.citationAuthor.isEmpty ? t.title : t.shortCitation}')),
                    for (final s in counts.keys)
                      DataCell(
                        (crossed[(t.code, s)] ?? 0) == 0
                            ? const Text('·')
                            : CircleAvatar(
                                radius: 13,
                                backgroundColor: Color(project.color)
                                    .withValues(alpha: 0.25 + 0.75 * min(1, (crossed[(t.code, s)] ?? 0) / 5)),
                                child: Text('${crossed[(t.code, s)]}', style: const TextStyle(fontSize: 12)),
                              ),
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

extension on MatrixPaper {
  String get shortCitation => '$citationAuthor ${year.isEmpty ? 's.d.' : year}';
}

/// Animated summary of the project at the top of the matrix.
class _Summary extends StatelessWidget {
  const _Summary({required this.matrix});

  final Matrix matrix;

  @override
  Widget build(BuildContext context) {
    final itens = matrix.itens;
    final data = [
      (Icons.article_outlined, matrix.papers.length, 'trabalhos'),
      (Icons.format_quote, itens.where((i) => i.type == 'destaque').length, 'trechos'),
      (Icons.lightbulb_outline, itens.where((i) => i.type == 'texto' || i.comment.isNotEmpty).length, 'comentários'),
      (Icons.draw_outlined, itens.where((i) => i.type == 'manuscrito').length, 'páginas à mão'),
      (Icons.check_circle_outline, itens.where((i) => i.used).length, 'usados'),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        spacing: 10,
        children: [
          for (final (icone, value, label) in data)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              child: _Stat(icone, value, label),
            ),
        ],
      ),
    );
  }
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({required this.item, required this.onItemTap});

  final MatrixItem item;
  final VoidCallback onItemTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = item.color == null ? theme.colorScheme.primary : Color(item.color!).withValues(alpha: 1);
    final (icone, type) = switch (item.type) {
      'destaque' => (Icons.format_quote, 'Trecho'),
      'texto' => (Icons.sticky_note_2_outlined, 'Comentário na página'),
      _ => (Icons.draw_outlined, 'Anotação à mão'),
    };
    final c = item.classification;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onItemTap,
        child: Container(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: color, width: 4)),
          ),
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              Row(
                spacing: 6,
                children: [
                  Icon(icone, size: 18, color: color),
                  Text(item.code, style: theme.textTheme.labelLarge),
                  Expanded(
                    child: Text(
                      '$type · ${item.narrativeCitation}, p. ${item.page + 1}',
                      style: theme.textTheme.labelMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (item.used) Icon(Icons.check_circle, size: 18, color: theme.colorScheme.primary),
                ],
              ),
              if (item.type == 'manuscrito')
                Container(
                  height: 150,
                  width: double.infinity,
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
                  child: CustomPaint(painter: _HandwritingPainter(item.strokes)),
                )
              else
                Text(
                  item.text,
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                  style: item.type == 'destaque'
                      ? theme.textTheme.bodyMedium?.copyWith(fontStyle: FontStyle.italic)
                      : null,
                ),
              if (item.translation.isNotEmpty) _Row(icone: Icons.translate, text: item.translation, lines: 5),
              if (item.comment.isNotEmpty)
                _Row(icone: Icons.lightbulb_outline, text: item.comment, lines: 4, highlight: true),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _Badge(item.parentheticalCitation, Icons.format_quote),
                  for (final field in const ['secao', 'tipo_citacao', 'tipo_conteudo'])
                    if ((c[field] ?? '').isNotEmpty) _Badge(c[field]!, null),
                  _Badge(c['status_uso'] ?? 'Não usado', item.used ? Icons.check : Icons.schedule),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.icone, required this.text, required this.lines, this.highlight = false});

  final IconData icone;
  final String text;
  final int lines;
  final bool highlight;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: highlight
          ? Theme.of(context).colorScheme.tertiaryContainer.withValues(alpha: 0.5)
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 6,
      children: [
        Icon(icone, size: 16),
        Expanded(
          child: Text(text, maxLines: lines, overflow: TextOverflow.ellipsis),
        ),
      ],
    ),
  );
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, this.icone);

  final String text;
  final IconData? icone;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        if (icone != null) Icon(icone, size: 13),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Text(text, style: Theme.of(context).textTheme.labelSmall, overflow: TextOverflow.ellipsis),
        ),
      ],
    ),
  );
}

/// Handwritten strokes of a page, framed in the box (without the PDF underneath).
class _HandwritingPainter extends CustomPainter {
  _HandwritingPainter(this.strokes);

  final List<HandStroke> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    var bounds = Rect.zero;
    var first = true;
    for (final t in strokes) {
      for (var i = 0; i + 1 < t.points.length; i += 3) {
        final p = Rect.fromLTWH(t.points[i], t.points[i + 1], 0, 0);
        bounds = first ? p : bounds.expandToInclude(p);
        first = false;
      }
    }
    if (first) return;
    bounds = bounds.inflate(8);
    final scale = min(size.width / max(bounds.width, 1), size.height / max(bounds.height, 1));
    canvas
      ..translate(
        (size.width - bounds.width * scale) / 2 - bounds.left * scale,
        (size.height - bounds.height * scale) / 2 - bounds.top * scale,
      )
      ..scale(scale);
    for (final t in strokes) {
      final path = Path();
      for (var i = 0; i + 1 < t.points.length; i += 3) {
        i == 0 ? path.moveTo(t.points[i], t.points[i + 1]) : path.lineTo(t.points[i], t.points[i + 1]);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = Color(t.color).withValues(alpha: t.marker ? 0.4 : 1)
          ..strokeWidth = t.thickness
          ..style = PaintingStyle.stroke
          ..strokeCap = t.marker ? StrokeCap.square : StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  @override
  bool shouldRepaint(_HandwritingPainter old) => old.strokes != strokes;
}

/// Bottom sheet on the phone, side dialog on tablet/PC.
Future<T?> showAdaptiveSheet<T>(BuildContext context, WidgetBuilder construir) {
  if (Faixa.de(context).celular) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: construir,
    );
  }
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Fechar',
    transitionDuration: const Duration(milliseconds: 280),
    pageBuilder: (c, _, _) => Align(
      alignment: Alignment.centerRight,
      child: Material(
        elevation: 8,
        child: SizedBox(
          width: min(560, MediaQuery.sizeOf(c).width * 0.9),
          height: double.infinity,
          child: SafeArea(child: construir(c)),
        ),
      ),
    ),
    transitionBuilder: (_, a, _, child) => SlideTransition(
      position: Tween(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}

/// Detail of a matrix item with its classification in the project. Returns the changed fields.
class _ItemSheet extends StatefulWidget {
  const _ItemSheet({
    required this.item,
    required this.paper,
    required this.options,
    required this.sections,
    this.openInFile,
  });

  final MatrixItem item;
  final MatrixPaper? paper;
  final StudyOptions options;
  final List<String> sections;
  final OpenInFile? openInFile;

  @override
  State<_ItemSheet> createState() => _ItemSheetState();
}

class _ItemSheetState extends State<_ItemSheet> {
  late final Map<String, String> _values = {...widget.item.classification};
  late final _words = TextEditingController(text: widget.item.field('palavras_chave'));
  late final _paraphrase = TextEditingController(text: widget.item.field('parafrase'));
  late final _notes = TextEditingController(text: widget.item.field('observacoes'));
  late final _section = TextEditingController(text: widget.item.field('secao'));

  /// Autocomplete field (the typed or chosen text belongs to it).
  TextEditingController? _sectionField;

  @override
  void dispose() {
    for (final c in [_words, _paraphrase, _notes, _section]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _choice(String label, String field, List<String> options) => DropdownButtonFormField<String>(
    initialValue: options.contains(_values[field]) ? _values[field] : null,
    isExpanded: true,
    decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
    items: [
      for (final o in options)
        DropdownMenuItem(
          value: o,
          child: Text(o, overflow: TextOverflow.ellipsis),
        ),
    ],
    onChanged: (v) => setState(() => _values[field] = v ?? ''),
  );

  void _copy(String text, String warning) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(warning)));
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.item;
    final theme = Theme.of(context);
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            children: [
              Text('${i.code} · ${i.fileTitle}', style: theme.textTheme.titleMedium),
              Text('Página ${i.page + 1} · ${i.narrativeCitation}', style: theme.textTheme.bodySmall),
              const SizedBox(height: 12),
              if (i.type == 'manuscrito')
                Container(
                  height: 220,
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
                  child: CustomPaint(painter: _HandwritingPainter(i.strokes)),
                )
              else
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(
                        color: i.color == null ? theme.colorScheme.primary : Color(i.color!).withValues(alpha: 1),
                        width: 4,
                      ),
                    ),
                    color: theme.colorScheme.surfaceContainerHighest,
                  ),
                  child: SelectableText(i.text),
                ),
              if (i.translation.isNotEmpty) ...[
                const SizedBox(height: 8),
                _Row(icone: Icons.translate, text: i.translation, lines: 40),
              ],
              if (i.comment.isNotEmpty) ...[
                const SizedBox(height: 8),
                _Row(icone: Icons.lightbulb_outline, text: i.comment, lines: 40, highlight: true),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (i.text.isNotEmpty && i.type == 'destaque')
                    ActionChip(
                      avatar: const Icon(Icons.copy, size: 16),
                      label: Text('Citação ${i.parentheticalCitation}'),
                      onPressed: () => _copy(
                        '"${i.text}" ${i.parentheticalCitation.replaceFirst(']', ', p. ${i.page + 1}]')}',
                        'Citação direta copiada',
                      ),
                    ),
                  ActionChip(
                    avatar: const Icon(Icons.copy, size: 16),
                    label: Text(i.narrativeCitation),
                    onPressed: () => _copy(i.narrativeCitation, 'Citação narrativa copiada'),
                  ),
                  if (widget.paper?.reference.isNotEmpty ?? false)
                    ActionChip(
                      avatar: const Icon(Icons.copy, size: 16),
                      label: const Text('Referência'),
                      onPressed: () => _copy(widget.paper!.reference, 'Referência copiada'),
                    ),
                  if (widget.openInFile != null)
                    ActionChip(
                      avatar: const Icon(Icons.open_in_new, size: 16),
                      label: const Text('Ver no arquivo'),
                      onPressed: () => widget.openInFile!(context, i.fileId, i.page + 1),
                    ),
                ],
              ),
              const Divider(height: 32),
              Text('Classificação neste projeto', style: theme.textTheme.titleSmall),
              const SizedBox(height: 12),
              Autocomplete<String>(
                initialValue: TextEditingValue(text: _section.text),
                optionsBuilder: (v) => widget.sections.where((s) => s.toLowerCase().contains(v.text.toLowerCase())),
                fieldViewBuilder: (context, field, focus, _) {
                  _sectionField = field;
                  return TextField(
                    controller: field,
                    focusNode: focus,
                    decoration: const InputDecoration(
                      labelText: 'Seção / subseção',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, area) {
                  final wide = area.maxWidth > 460;
                  final fields = [
                    _choice('Tipo de citação', 'tipo_citacao', widget.options.citationTypes),
                    _choice('Tipo de conteúdo', 'tipo_conteudo', widget.options.contentTypes),
                  ];
                  return wide
                      ? Row(spacing: 12, children: [for (final c in fields) Expanded(child: c)])
                      : Column(spacing: 12, children: fields);
                },
              ),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: [for (final s in widget.options.statusUso) ButtonSegment(value: s, label: Text(s))],
                selected: {_values['status_uso'] ?? 'Não usado'},
                onSelectionChanged: (v) => setState(() => _values['status_uso'] = v.first),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _words,
                decoration: const InputDecoration(
                  labelText: 'Palavras-chave (separe com ;)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _paraphrase,
                minLines: 2,
                maxLines: 8,
                decoration: const InputDecoration(
                  labelText: 'Paráfrase ou redação própria',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notes,
                minLines: 1,
                maxLines: 5,
                decoration: const InputDecoration(labelText: 'Observações', border: OutlineInputBorder()),
              ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Row(
              children: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
                const Spacer(),
                FilledButton.icon(
                  icon: const Icon(Icons.check),
                  label: const Text('Salvar'),
                  onPressed: () => Navigator.pop(context, {
                    for (final field in const ['tipo_citacao', 'tipo_conteudo', 'status_uso'])
                      if (_values[field] != null) field: _values[field]!,
                    'secao': (_sectionField ?? _section).text.trim(),
                    'palavras_chave': _words.text.trim(),
                    'parafrase': _paraphrase.text.trim(),
                    'observacoes': _notes.text.trim(),
                  }),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Paper sheet (author, year, reference…) saved in the reading linked to the file.
class _PaperSheet extends StatefulWidget {
  const _PaperSheet({required this.paper});

  final MatrixPaper paper;

  @override
  State<_PaperSheet> createState() => _PaperSheetState();
}

class _PaperSheetState extends State<_PaperSheet> {
  late final _campos = {
    'titulo': TextEditingController(text: widget.paper.title),
    'autor': TextEditingController(text: widget.paper.author),
    'ano': TextEditingController(text: widget.paper.year),
    'referencia': TextEditingController(text: widget.paper.reference),
    'tipo_publicacao': TextEditingController(text: widget.paper.publicationType),
    'veiculo': TextEditingController(text: widget.paper.venue),
    'doi': TextEditingController(text: widget.paper.doi),
    'idioma': TextEditingController(text: widget.paper.language),
  };

  static const _labels = {
    'titulo': 'Título',
    'autor': 'Autor(es) — "Sobrenome, N.; Sobrenome, N."',
    'ano': 'Ano',
    'referencia': 'Referência completa',
    'tipo_publicacao': 'Tipo de publicação (artigo em periódico, evento…)',
    'veiculo': 'Veículo (periódico ou evento)',
    'doi': 'DOI ou URL',
    'idioma': 'Idioma',
  };

  @override
  void dispose() {
    for (final c in _campos.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Ficha de ${widget.paper.code}'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 10,
          children: [
            for (final e in _campos.entries)
              TextField(
                controller: e.value,
                minLines: 1,
                maxLines: e.key == 'referencia' ? 4 : 1,
                keyboardType: e.key == 'ano' ? TextInputType.number : null,
                decoration: InputDecoration(labelText: _labels[e.key]),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(
        onPressed: () {
          final data = {for (final e in _campos.entries) e.key: e.value.text.trim()};
          if (data['titulo']!.isEmpty) return;
          Navigator.pop(context, data);
        },
        child: const Text('Salvar'),
      ),
    ],
  );
}
