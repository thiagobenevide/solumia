import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../files_api.dart';

/// Reading project of the Estudos module (`/api/estudos/projetos`): pre-thesis, video script…
/// The excerpts, comments and handwritten notes store its `id` in the `projetos` field.
class ReadingProject {
  const ReadingProject({required this.id, required this.name, required this.color});

  factory ReadingProject.fromJson(Map<String, dynamic> j) =>
      ReadingProject(id: j['id'] as String, name: j['nome'] as String, color: Color(j['cor'] as int? ?? 0xFF3F51B5));

  final String id;
  final String name;
  final Color color;
}

/// Projects that whatever is marked or written now goes into on its own. Applies to all files
/// opened in the session (switching articles does not lose the choice).
final activeProjects = ValueNotifier<List<String>>(const []);

List<ReadingProject>? _cache;

Future<List<ReadingProject>> loadProjects(FilesApi api, {bool reload = false}) async {
  if (_cache != null && !reload) return _cache!;
  return _cache = await api.readingProjects();
}

/// Sheet to pick projects (several at once) and create a new one. `null` = cancelled.
Future<List<String>?> pickProjects(
  BuildContext context,
  FilesApi api, {
  required List<String> selectedItems,
  String title = 'Projetos de leitura',
  String? hint,
}) => showModalBottomSheet<List<String>>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _ProjectPicker(api: api, initial: selectedItems, title: title, hint: hint),
);

class _ProjectPicker extends StatefulWidget {
  const _ProjectPicker({required this.api, required this.initial, required this.title, this.hint});

  final FilesApi api;
  final List<String> initial;
  final String title;
  final String? hint;

  @override
  State<_ProjectPicker> createState() => _ProjectPickerState();
}

class _ProjectPickerState extends State<_ProjectPicker> {
  late final _marked = {...widget.initial};
  List<ReadingProject>? _projects;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool reload = false}) async {
    try {
      final p = await loadProjects(widget.api, reload: reload);
      if (mounted) setState(() => _projects = p);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _new() async {
    final field = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Novo projeto de leitura'),
        content: TextField(
          controller: field,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Nome', hintText: 'Ex.: Pré-TCC, vídeo sobre IA…'),
          onSubmitted: (v) => Navigator.pop(c, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, field.text), child: const Text('Criar')),
        ],
      ),
    ).whenComplete(field.dispose);
    if (name == null || name.trim().isEmpty) return;
    try {
      final p = await widget.api.createReadingProject(name.trim());
      _marked.add(p.id);
      await _load(reload: true);
    } on ApiErro catch (e) {
      if (mounted) setState(() => _error = e.mensagem);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final projects = _projects;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              Text(widget.title, style: theme.textTheme.titleMedium),
              if (widget.hint != null) Text(widget.hint!, style: theme.textTheme.bodySmall),
              if (_error != null) Text('$_error', style: TextStyle(color: theme.colorScheme.error)),
              Flexible(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: projects == null
                      ? const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      : SingleChildScrollView(
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final p in projects)
                                FilterChip(
                                  avatar: CircleAvatar(backgroundColor: p.color, radius: 6),
                                  label: Text(p.name),
                                  selected: _marked.contains(p.id),
                                  onSelected: (v) => setState(() => v ? _marked.add(p.id) : _marked.remove(p.id)),
                                ),
                              ActionChip(
                                avatar: const Icon(Icons.add, size: 18),
                                label: const Text('Novo projeto'),
                                onPressed: _new,
                              ),
                            ],
                          ),
                        ),
                ),
              ),
              Row(
                children: [
                  if (_marked.isNotEmpty)
                    TextButton(onPressed: () => setState(_marked.clear), child: const Text('Nenhum')),
                  const Spacer(),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, [
                      for (final p in projects ?? const <ReadingProject>[])
                        if (_marked.contains(p.id)) p.id,
                    ]),
                    child: const Text('Pronto'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Reader bar button with the active project(s): what is marked or written goes into them.
class ActiveProjectButton extends StatelessWidget {
  const ActiveProjectButton({super.key, required this.api, this.onLinkPage});

  final FilesApi api;

  /// Links what was already annotated on the open page to the active project(s).
  final VoidCallback? onLinkPage;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: activeProjects,
    builder: (context, assets, _) => FutureBuilder(
      future: loadProjects(api),
      builder: (context, s) {
        final names = {for (final p in s.data ?? const <ReadingProject>[]) p.id: p};
        final chosen = [for (final id in assets) ?names[id]];
        final narrow = MediaQuery.sizeOf(context).width < 600;
        final label = chosen.isEmpty
            ? (narrow ? '' : 'Sem projeto')
            : chosen.length == 1
            ? chosen.first.name
            : '${chosen.length} projetos';
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: Tooltip(
              message: 'Projeto de leitura: o que você marcar ou escrever entra nele',
              child: ActionChip(
                avatar: Icon(
                  chosen.isEmpty ? Icons.folder_off_outlined : Icons.folder_special,
                  size: 18,
                  color: chosen.isEmpty ? null : chosen.first.color,
                ),
                label: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  transitionBuilder: (c, a) => FadeTransition(
                    opacity: a,
                    child: SizeTransition(sizeFactor: a, axis: Axis.horizontal, child: c),
                  ),
                  child: label.isEmpty
                      ? const SizedBox.shrink()
                      : ConstrainedBox(
                          key: ValueKey(label),
                          constraints: BoxConstraints(maxWidth: narrow ? 110 : 200),
                          child: Text(label, overflow: TextOverflow.ellipsis),
                        ),
                ),
                labelPadding: label.isEmpty ? EdgeInsets.zero : null,
                onPressed: () async {
                  final r = await pickProjects(
                    context,
                    api,
                    selectedItems: assets,
                    title: 'Projeto ativo',
                    hint:
                        'Trechos marcados, textos e anotações à mão feitos daqui em diante entram '
                        'nos projetos escolhidos. Toque num destaque para mudar só ele.',
                  );
                  if (r == null) return;
                  activeProjects.value = r;
                  if (r.isNotEmpty && onLinkPage != null && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: const Text('Projeto ativo definido'),
                        action: SnackBarAction(label: 'Ligar esta página', onPressed: onLinkPage!),
                      ),
                    );
                  }
                },
              ),
            ),
          ),
        );
      },
    ),
  );
}

/// Project chips of a highlight, to link/unlink with a tap.
class ProjectChips extends StatefulWidget {
  const ProjectChips({super.key, required this.api, required this.initial, required this.aoMudar});

  final FilesApi api;
  final List<String> initial;
  final ValueChanged<List<String>> aoMudar;

  @override
  State<ProjectChips> createState() => _ProjectChipsState();
}

class _ProjectChipsState extends State<ProjectChips> {
  late List<String> _marked = [...widget.initial];

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: loadProjects(widget.api),
    builder: (context, s) {
      if (s.hasError) return Text('Projetos indisponíveis: ${s.error}');
      final projects = s.data;
      return AnimatedSize(
        duration: const Duration(milliseconds: 220),
        child: projects == null
            ? const LinearProgressIndicator()
            : Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final p in projects)
                    FilterChip(
                      avatar: CircleAvatar(backgroundColor: p.color, radius: 6),
                      label: Text(p.name),
                      selected: _marked.contains(p.id),
                      onSelected: (v) {
                        setState(
                          () => _marked = [
                            for (final id in _marked)
                              if (id != p.id) id,
                            if (v) p.id,
                          ],
                        );
                        widget.aoMudar(_marked);
                      },
                    ),
                  ActionChip(
                    avatar: const Icon(Icons.add, size: 18),
                    label: const Text('Projeto'),
                    onPressed: () async {
                      final r = await pickProjects(context, widget.api, selectedItems: _marked);
                      if (r == null) return;
                      setState(() => _marked = r);
                      widget.aoMudar(r);
                    },
                  ),
                ],
              ),
      );
    },
  );
}

/// Edits the translation of an excerpt; "Traduzir" fills it with the local LLM.
Future<String?> editTranslation(BuildContext context, FilesApi api, {required String original, String current = ''}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _Translation(api: api, original: original, current: current),
    );

class _Translation extends StatefulWidget {
  const _Translation({required this.api, required this.original, required this.current});

  final FilesApi api;
  final String original;
  final String current;

  @override
  State<_Translation> createState() => _TranslationState();
}

class _TranslationState extends State<_Translation> {
  late final _input = TextEditingController(text: widget.current);
  bool _translating = false;
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _translate() async {
    setState(() {
      _translating = true;
      _error = null;
    });
    try {
      final r = await widget.api.rewrite(excerpt: widget.original, goal: 'traduzir');
      _input.text = (r['texto'] as String? ?? '').trim();
    } on ApiErro catch (e) {
      _error = e.mensagem;
    } finally {
      if (mounted) setState(() => _translating = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Tradução (português)'),
    content: SizedBox(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          Container(
            constraints: const BoxConstraints(maxHeight: 140),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SingleChildScrollView(child: SelectableText(widget.original)),
          ),
          TextField(
            controller: _input,
            minLines: 3,
            maxLines: 10,
            enabled: !_translating,
            decoration: const InputDecoration(labelText: 'Tradução', border: OutlineInputBorder()),
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: _translating
                ? const LinearProgressIndicator()
                : Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.translate),
                      label: const Text('Traduzir'),
                      onPressed: _translate,
                    ),
                  ),
          ),
          if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(onPressed: () => Navigator.pop(context, _input.text.trim()), child: const Text('Salvar')),
    ],
  );
}
