import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../studies_api.dart';
import '../models.dart';

/// Estudos › Linguagem: what the guided reading in Arquivos gathers (words marked with "Criar
/// tarefas", readings aloud) and the training on top of it — spaced review with corrected exercises,
/// writing about the read articles and the progress. All by the local LLM and the PC voice (never Claude).
class LanguageScreen extends StatefulWidget {
  const LanguageScreen({super.key, required this.api, required this.options});

  final StudiesApi api;
  final StudyOptions options;

  @override
  State<LanguageScreen> createState() => _LanguageScreenState();
}

class _LanguageScreenState extends State<LanguageScreen> {
  late String _language = widget.options.languages.containsKey('en') ? 'en' : widget.options.languages.keys.first;
  final _voice = _Voice();

  @override
  void dispose() {
    _voice.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final api = widget.api;
    return DefaultTabController(
      length: 5,
      child: Column(
        children: [
          Material(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            // On the phone the language selector gets its own line, so the tabs use the full width
            child: LayoutBuilder(
              builder: (context, c) {
                final language = Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: DropdownButton<String>(
                    value: _language,
                    underline: const SizedBox(),
                    items: [
                      for (final e in widget.options.languages.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
                    ],
                    onChanged: (v) => setState(() => _language = v ?? _language),
                  ),
                );
                const tabs = TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: [
                    Tab(icon: Icon(Icons.replay_circle_filled_outlined), text: 'Revisar'),
                    Tab(icon: Icon(Icons.style_outlined), text: 'Vocabulário'),
                    Tab(icon: Icon(Icons.edit_note), text: 'Escrita'),
                    Tab(icon: Icon(Icons.record_voice_over_outlined), text: 'Leitura em voz'),
                    Tab(icon: Icon(Icons.insights_outlined), text: 'Progresso'),
                  ],
                );
                if (c.maxWidth < 600) {
                  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [language, tabs]);
                }
                return Row(children: [language, const Expanded(child: tabs)]);
              },
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                _ReviewTab(key: ValueKey('r$_language'), api: api, language: _language, voice: _voice),
                _VocabularyTab(key: ValueKey('v$_language'), api: api, language: _language, voice: _voice),
                _WritingTab(key: ValueKey('e$_language'), api: api, language: _language, levels: widget.options.levels),
                _VoiceReadingTab(key: ValueKey('l$_language'), api: api, language: _language, voice: _voice),
                _ProgressTab(key: ValueKey('p$_language'), api: api, language: _language),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

void _notify(BuildContext context, Object error) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error is ApiErro ? error.mensagem : '$error')));
}

String _data(String? iso) {
  final d = DateTime.tryParse(iso ?? '')?.toLocal();
  if (d == null) return '';
  String twoDigits(int n) => n.toString().padLeft(2, '0');
  return '${twoDigits(d.day)}/${twoDigits(d.month)} ${twoDigits(d.hour)}:${twoDigits(d.minute)}';
}

/// Speaks words and sentences with the same voice as the guided reading.
class _Voice {
  final _player = Tocador();

  Future<void> listen(BuildContext context, StudiesApi api, String text, String language) async {
    try {
      final r = await api.speech(text, language, speed: 0.9);
      await _player.tocar(base64Decode(r['audio_b64'] as String), r['mime'] as String);
    } catch (e) {
      if (context.mounted) _notify(context, e);
    }
  }

  void dispose() => _player.dispose();
}

/// Study time of a tab (goes into the language track on leaving, if it is over half a minute).
class _Stopwatch {
  _Stopwatch(this.api, this.type, this.language);

  final StudiesApi api;
  final String type, language;
  final _clock = Stopwatch();

  void mark() => _clock.start();

  void finish() {
    final s = _clock.elapsed.inSeconds;
    if (s >= 30) api.logActivity(type, language, (s / 60).ceil()).catchError((_) {});
  }
}

// --- Review: the words of the day, one exercise at a time ---

class _ReviewTab extends StatefulWidget {
  const _ReviewTab({super.key, required this.api, required this.language, required this.voice});

  final StudiesApi api;
  final String language;
  final _Voice voice;

  @override
  State<_ReviewTab> createState() => _ReviewTabState();
}

class _ReviewTabState extends State<_ReviewTab> {
  late Future<List<Map<String, dynamic>>> _queue = _load();
  late final _stopwatch = _Stopwatch(widget.api, 'vocabulario', widget.language);
  final _answer = TextEditingController();
  Map<String, dynamic>? _correction;
  bool _show = false;
  bool _sending = false;

  Future<List<Map<String, dynamic>>> _load() => widget.api.vocabulary(widget.language, due: true);

  @override
  void dispose() {
    _stopwatch.finish();
    _answer.dispose();
    super.dispose();
  }

  void _next() => setState(() {
    _correction = null;
    _show = false;
    _answer.clear();
    _queue = _load();
  });

  Future<void> _correct(Map<String, dynamic> item, int score) async {
    if (_answer.text.trim().isEmpty) return;
    _stopwatch.mark();
    setState(() => _sending = true);
    try {
      final r = await widget.api.answerExercise(item['id'] as String, score, _answer.text);
      setState(() => _correction = (r['correcao'] as Map).cast<String, dynamic>());
    } catch (e) {
      if (mounted) _notify(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _evaluate(Map<String, dynamic> item, int note) async {
    _stopwatch.mark();
    try {
      await widget.api.reviewWord(item['id'] as String, note);
      _next();
    } catch (e) {
      if (mounted) _notify(context, e);
    }
  }

  Future<void> _generate(Map<String, dynamic> item) async {
    setState(() => _sending = true);
    try {
      await widget.api.generatePractice(item['id'] as String);
      _next();
    } catch (e) {
      if (mounted) _notify(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _queue,
    builder: (context, s) {
      if (s.hasError) return Center(child: Text('${s.error}'));
      final queue = s.data;
      if (queue == null) return const Center(child: CircularProgressIndicator());
      if (queue.isEmpty) {
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Nada para revisar agora.\nNa leitura guiada dos Arquivos, toque numa palavra e em "Criar tarefas".',
              textAlign: TextAlign.center,
            ),
          ),
        );
      }
      final item = queue.first;
      final theme = Theme.of(context).textTheme;
      final exercises = (item['exercicios'] as List).cast<Map>();
      final sentenceContext = (item['contextos'] as List).cast<Map>().firstOrNull?['frase'] as String? ?? '';
      // A different exercise on each review of the same word.
      final score = exercises.isEmpty ? -1 : (item['respostas'] as List).length % exercises.length;
      final ex = score < 0 ? null : exercises[score].cast<String, dynamic>();
      final c = _correction;
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('${queue.length} para revisar', style: theme.labelMedium),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 8,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(item['termo'] as String, style: theme.headlineSmall)),
                      IconButton(
                        tooltip: 'Ouvir',
                        icon: const Icon(Icons.volume_up),
                        onPressed: () => widget.voice.listen(context, widget.api, item['termo'] as String, widget.language),
                      ),
                    ],
                  ),
                  if (sentenceContext.isNotEmpty) Text('“$sentenceContext”', style: theme.bodyMedium?.copyWith(fontStyle: FontStyle.italic)),
                  if (_show || c != null)
                    Text(
                      '${item['traducao']}${(item['ipa'] as String? ?? '').isEmpty ? '' : '  /${item['ipa']}/'}',
                      style: theme.titleMedium?.copyWith(color: Theme.of(context).colorScheme.primary),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (ex == null)
            Row(
              spacing: 12,
              children: [
                Expanded(
                  child: Text(
                    item['gerando'] == true
                        ? 'A LLM local está criando as frases e exercícios…'
                        : (item['erro'] as String? ?? '').isNotEmpty
                        ? 'Não deu para gerar: ${item['erro']}'
                        : 'Sem exercícios ainda.',
                  ),
                ),
                OutlinedButton(onPressed: _sending ? null : () => _generate(item), child: const Text('Gerar agora')),
              ],
            )
          else ...[
            Text(
              switch (ex['tipo']) {
                'lacuna' => 'Complete a lacuna',
                'traducao' => 'Traduza',
                _ => 'Escreva',
              },
              style: theme.labelLarge,
            ),
            Text(ex['enunciado'] as String, style: theme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _answer,
              enabled: c == null,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Sua resposta'),
              onSubmitted: (_) => _correct(item, score),
            ),
            const SizedBox(height: 8),
            if (c == null)
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    onPressed: _sending ? null : () => _correct(item, score),
                    child: _sending
                        ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Corrigir'),
                  ),
                  TextButton(onPressed: () => setState(() => _show = true), child: const Text('Mostrar resposta')),
                ],
              )
            else
              _Correction(c),
          ],
          if (_show && c == null && ex != null && (ex['resposta'] as String).isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text('Resposta: ${ex['resposta']}')),
          if (_show || c != null || ex == null) ...[
            const SizedBox(height: 16),
            if (c != null)
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: _next,
                  icon: const Icon(Icons.arrow_forward),
                  label: const Text('Próxima'),
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (note, label) in [(1, 'Errei'), (2, 'Difícil'), (3, 'Bom'), (4, 'Fácil')])
                    OutlinedButton(onPressed: () => _evaluate(item, note), child: Text(label)),
                ],
              ),
          ],
        ],
      );
    },
  );
}

class _Correction extends StatelessWidget {
  const _Correction(this.c);

  final Map<String, dynamic> c;

  @override
  Widget build(BuildContext context) {
    final correct = c['correto'] == true;
    final color = correct ? Colors.green.shade700 : Colors.orange.shade800;
    return Card(
      color: color.withAlpha(20),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 4,
          children: [
            Text('${correct ? 'Certo' : 'Quase'} · ${c['nota']}/100', style: TextStyle(color: color, fontWeight: FontWeight.bold)),
            if ((c['correcao'] as String? ?? '').isNotEmpty) Text(c['correcao'] as String),
            if ((c['explicacao'] as String? ?? '').isNotEmpty)
              Text(c['explicacao'] as String, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

// --- Vocabulary: the whole notebook ---

class _VocabularyTab extends StatefulWidget {
  const _VocabularyTab({super.key, required this.api, required this.language, required this.voice});

  final StudiesApi api;
  final String language;
  final _Voice voice;

  @override
  State<_VocabularyTab> createState() => _VocabularyTabState();
}

class _VocabularyTabState extends State<_VocabularyTab> {
  late Future<List<Map<String, dynamic>>> _items = widget.api.vocabulary(widget.language);
  String _filter = '';

  void _reload() => setState(() => _items = widget.api.vocabulary(widget.language));

  Future<void> _newTask() async {
    final term = TextEditingController(), sentenceContext = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nova palavra'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: term, autofocus: true, decoration: const InputDecoration(labelText: 'Palavra ou expressão')),
            TextField(controller: sentenceContext, decoration: const InputDecoration(labelText: 'Frase onde apareceu (opcional)')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Criar tarefas')),
        ],
      ),
    );
    if (ok != true || term.text.trim().isEmpty) return;
    try {
      await widget.api.createWord({'termo': term.text.trim(), 'idioma': widget.language, 'contexto': sentenceContext.text.trim()});
      _reload();
    } catch (e) {
      if (mounted) _notify(context, e);
    }
  }

  Future<void> _detail(Map<String, dynamic> item) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (context, scroll) => _WordDetail(
          item: item,
          scroll: scroll,
          listen: (t) => widget.voice.listen(context, widget.api, t, widget.language),
          generate: () async {
            Navigator.pop(context);
            try {
              await widget.api.generatePractice(item['id'] as String);
            } catch (e) {
              if (mounted) _notify(this.context, e);
            }
            _reload();
          },
          delete: () async {
            Navigator.pop(context);
            await widget.api.deleteWord(item['id'] as String);
            _reload();
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _newTask,
      icon: const Icon(Icons.add),
      label: const Text('Palavra'),
    ),
    body: FutureBuilder(
      future: _items,
      builder: (context, s) {
        if (s.hasError) return Center(child: Text('${s.error}'));
        final itens = s.data;
        if (itens == null) return const Center(child: CircularProgressIndicator());
        final f = _filter.toLowerCase();
        final seenItems = [
          for (final v in itens)
            if (f.isEmpty || '${v['termo']} ${v['traducao']}'.toLowerCase().contains(f)) v,
        ];
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: TextField(
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: '${itens.length} palavras no caderno',
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _filter = v),
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async => _reload(),
                child: ListView.builder(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: seenItems.length,
                  itemBuilder: (context, i) {
                    final v = seenItems[i];
                    final source = (v['contextos'] as List).cast<Map>().firstOrNull;
                    final next = (v['cartao'] as Map?)?['proxima'] as String?;
                    return ListTile(
                      title: Text(v['termo'] as String),
                      subtitle: Text(
                        [
                          if ((v['traducao'] as String? ?? '').isNotEmpty) v['traducao'],
                          if (source?['titulo'] case final String t when t.isNotEmpty)
                            '$t${source?['pagina'] != null ? ', p. ${(source!['pagina'] as int) + 1}' : ''}',
                          if (v['gerando'] == true) 'gerando exercícios…',
                        ].join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Text('revisar ${_data(next).split(' ').first}', style: Theme.of(context).textTheme.labelSmall),
                      onTap: () => _detail(v),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

class _WordDetail extends StatelessWidget {
  const _WordDetail({
    required this.item,
    required this.scroll,
    required this.listen,
    required this.generate,
    required this.delete,
  });

  final Map<String, dynamic> item;
  final ScrollController scroll;
  final void Function(String text) listen;
  final VoidCallback generate, delete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final contexts = (item['contextos'] as List).cast<Map>();
    final sentences = (item['frases'] as List).cast<Map>();
    final exercises = (item['exercicios'] as List).cast<Map>();
    final card = (item['cartao'] as Map?) ?? const {};
    return ListView(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      children: [
        Row(
          children: [
            Expanded(child: Text(item['termo'] as String, style: theme.headlineSmall)),
            IconButton(icon: const Icon(Icons.volume_up), onPressed: () => listen(item['termo'] as String)),
          ],
        ),
        Text(
          [
            item['traducao'],
            if ((item['ipa'] as String? ?? '').isNotEmpty) '/${item['ipa']}/',
            item['classe'],
          ].where((x) => '$x'.isNotEmpty).join('  ·  '),
          style: theme.titleMedium,
        ),
        Text(
          'Revisões: ${card['revisoes'] ?? 0} · próxima: ${_data(card['proxima'] as String?)}',
          style: theme.labelSmall,
        ),
        if (contexts.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Onde apareceu', style: theme.titleSmall),
          for (final c in contexts)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('“${c['frase']}”'),
              subtitle: (c['titulo'] as String? ?? '').isEmpty ? null : Text('${c['titulo']}'),
            ),
        ],
        const SizedBox(height: 16),
        Text('Frases para memorizar', style: theme.titleSmall),
        if (sentences.isEmpty) const Text('Ainda não geradas.'),
        for (final f in sentences)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Text('${f['nivel']}', style: theme.labelSmall),
            title: Text('${f['texto']}'),
            subtitle: Text('${f['traducao']}'),
            trailing: IconButton(icon: const Icon(Icons.volume_up_outlined), onPressed: () => listen('${f['texto']}')),
          ),
        if (exercises.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Exercícios (aparecem na aba Revisar)', style: theme.titleSmall),
          for (final e in exercises) Text('• ${e['enunciado']}'),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton.icon(onPressed: generate, icon: const Icon(Icons.auto_awesome), label: const Text('Gerar de novo')),
            TextButton.icon(onPressed: delete, icon: const Icon(Icons.delete_outline), label: const Text('Excluir')),
          ],
        ),
      ],
    );
  }
}

// --- Writing: questions about the read article, corrected by the local LLM ---

class _WritingTab extends StatefulWidget {
  const _WritingTab({super.key, required this.api, required this.language, required this.levels});

  final StudiesApi api;
  final String language;
  final List<String> levels;

  @override
  State<_WritingTab> createState() => _WritingTabState();
}

class _WritingTabState extends State<_WritingTab> {
  late Future<List<Map<String, dynamic>>> _writings = widget.api.writings(widget.language);
  bool _creating = false;

  void _reload() => setState(() => _writings = widget.api.writings(widget.language));

  Future<void> _newTask() async {
    final readings = [
      for (final l in await widget.api.readings().catchError((_) => <Reading>[]))
        if (l.fileId != null) l,
    ];
    if (!mounted) return;
    final request = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _NewWriting(readings: readings, levels: widget.levels),
    );
    if (request == null) return;
    setState(() => _creating = true);
    try {
      final e = await widget.api.createWriting({...request, 'idioma': widget.language});
      _reload();
      if (mounted) await _open(e);
    } catch (e) {
      if (mounted) _notify(context, e);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _open(Map<String, dynamic> e) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => _WritingScreen(api: widget.api, writing: e)),
    );
    _reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _creating ? null : _newTask,
      icon: _creating
          ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.add),
      label: Text(_creating ? 'Criando perguntas…' : 'Nova escrita'),
    ),
    body: FutureBuilder(
      future: _writings,
      builder: (context, s) {
        if (s.hasError) return Center(child: Text('${s.error}'));
        final items = s.data;
        if (items == null) return const Center(child: CircularProgressIndicator());
        if (items.isEmpty) {
          return const Center(child: Text('Crie uma escrita sobre um artigo que você leu.'));
        }
        return ListView(
          padding: const EdgeInsets.only(bottom: 88),
          children: [
            for (final e in items)
              Builder(
                builder: (context) {
                  final answers = (e['respostas'] as Map).values.cast<Map>().toList();
                  final media = answers.isEmpty
                      ? null
                      : (answers.fold<num>(0, (s, r) => s + (r['nota'] as num)) / answers.length).round();
                  return ListTile(
                    title: Text(e['titulo'] as String),
                    subtitle: Text(
                      [
                        e['nivel'],
                        if ((e['titulo_arquivo'] as String? ?? '').isNotEmpty) e['titulo_arquivo'],
                        '${answers.length}/${(e['perguntas'] as List).length} respondidas',
                        _data(e['criado'] as String?),
                      ].join(' · '),
                    ),
                    trailing: media == null ? null : Text('$media', style: Theme.of(context).textTheme.titleLarge),
                    onTap: () => _open(e),
                  );
                },
              ),
          ],
        );
      },
    ),
  );
}

class _NewWriting extends StatefulWidget {
  const _NewWriting({required this.readings, required this.levels});

  final List<Reading> readings;
  final List<String> levels;

  @override
  State<_NewWriting> createState() => _NewWritingState();
}

class _NewWritingState extends State<_NewWriting> {
  Reading? _reading;
  String _level = 'B1';
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Nova escrita'),
    content: SizedBox(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 12,
        children: [
          DropdownButtonFormField<Reading?>(
            initialValue: _reading,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Sobre o artigo'),
            items: [
              const DropdownMenuItem(value: null, child: Text('Texto colado abaixo / tema livre')),
              for (final l in widget.readings)
                DropdownMenuItem(value: l, child: Text(l.title, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() => _reading = v),
          ),
          if (_reading == null)
            TextField(
              controller: _text,
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(labelText: 'Trecho de referência (opcional)', border: OutlineInputBorder()),
            ),
          DropdownButtonFormField<String>(
            initialValue: _level,
            decoration: const InputDecoration(labelText: 'Nível'),
            items: [for (final n in widget.levels) DropdownMenuItem(value: n, child: Text(n))],
            onChanged: (v) => setState(() => _level = v ?? _level),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(
        onPressed: () => Navigator.pop(context, {
          'nivel': _level,
          if (_reading != null) ...{'arquivo_id': _reading!.fileId, 'titulo_arquivo': _reading!.title},
          if (_reading == null) 'texto': _text.text.trim(),
        }),
        child: const Text('Criar perguntas'),
      ),
    ],
  );
}

class _WritingScreen extends StatefulWidget {
  const _WritingScreen({required this.api, required this.writing});

  final StudiesApi api;
  final Map<String, dynamic> writing;

  @override
  State<_WritingScreen> createState() => _WritingScreenState();
}

class _WritingScreenState extends State<_WritingScreen> {
  late var _e = widget.writing;
  late final _stopwatch = _Stopwatch(widget.api, 'escrita', widget.writing['idioma'] as String);
  late final _campos = [
    for (var i = 0; i < (_e['perguntas'] as List).length; i++)
      TextEditingController(text: ((_e['respostas'] as Map)['$i'] as Map?)?['resposta'] as String? ?? ''),
  ];
  final _sending = <int>{};

  @override
  void initState() {
    super.initState();
    _stopwatch.mark();
  }

  @override
  void dispose() {
    _stopwatch.finish();
    for (final c in _campos) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _correct(int i) async {
    setState(() => _sending.add(i));
    try {
      final e = await widget.api.answerWriting(_e['id'] as String, i, _campos[i].text);
      setState(() => _e = e);
    } catch (e) {
      if (mounted) _notify(context, e);
    } finally {
      if (mounted) setState(() => _sending.remove(i));
    }
  }

  Future<void> _delete() async {
    await widget.api.deleteWriting(_e['id'] as String);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final questions = (_e['perguntas'] as List).cast<Map>();
    final answers = (_e['respostas'] as Map).cast<String, dynamic>();
    return Scaffold(
      appBar: AppBar(
        title: Text(_e['titulo'] as String),
        actions: [IconButton(tooltip: 'Excluir', icon: const Icon(Icons.delete_outline), onPressed: _delete)],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final (i, p) in questions.indexed) ...[
            Text('${i + 1}. ${p['pergunta']}', style: theme.titleMedium),
            if ((p['palavras_sugeridas'] as List? ?? const []).isNotEmpty)
              Wrap(
                spacing: 6,
                children: [
                  for (final w in (p['palavras_sugeridas'] as List).cast<String>())
                    Chip(label: Text(w), visualDensity: VisualDensity.compact),
                ],
              ),
            const SizedBox(height: 8),
            TextField(
              controller: _campos[i],
              minLines: 4,
              maxLines: 12,
              decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Escreva sua resposta'),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonal(
                onPressed: _sending.contains(i) ? null : () => _correct(i),
                child: _sending.contains(i)
                    ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(answers.containsKey('$i') ? 'Corrigir de novo' : 'Corrigir'),
              ),
            ),
            if (answers['$i'] case final Map c) _WritingCorrection(c.cast<String, dynamic>()),
            const Divider(height: 32),
          ],
        ],
      ),
    );
  }
}

class _WritingCorrection extends StatelessWidget {
  const _WritingCorrection(this.c);

  final Map<String, dynamic> c;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final corrections = (c['correcoes'] as List? ?? const []).cast<Map>();
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 6,
          children: [
            Text(
              'Nota ${c['nota']}  ·  nível ${c['nivel_cefr'] ?? '?'}',
              style: theme.titleMedium?.copyWith(color: Theme.of(context).colorScheme.primary),
            ),
            Text(
              'Gramática ${c['gramatica']} · Vocabulário ${c['vocabulario']} · Coerência ${c['coerencia']} · '
              'Adequação ${c['adequacao']}',
              style: theme.labelMedium,
            ),
            if ((c['texto_corrigido'] as String? ?? '').isNotEmpty) ...[
              Text('Texto corrigido', style: theme.titleSmall),
              SelectableText(c['texto_corrigido'] as String),
            ],
            for (final k in corrections)
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: '${k['trecho']}', style: const TextStyle(decoration: TextDecoration.lineThrough)),
                    const TextSpan(text: '  →  '),
                    TextSpan(text: '${k['correcao']}', style: const TextStyle(fontWeight: FontWeight.bold)),
                    TextSpan(text: '\n${k['explicacao']}', style: theme.bodySmall),
                  ],
                ),
              ),
            if ((c['comentario'] as String? ?? '').isNotEmpty) Text(c['comentario'] as String, style: theme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

// --- Reading aloud: paste the text, read it, and see the words and the pronunciation ---

class _VoiceReadingTab extends StatefulWidget {
  const _VoiceReadingTab({super.key, required this.api, required this.language, required this.voice});

  final StudiesApi api;
  final String language;
  final _Voice voice;

  @override
  State<_VoiceReadingTab> createState() => _VoiceReadingTabState();
}

class _VoiceReadingTabState extends State<_VoiceReadingTab> {
  late Future<List<Map<String, dynamic>>> _history = widget.api.voiceReadings(widget.language);
  final _text = TextEditingController();
  final _recorder = GravadorLeitura();
  DateTime? _start;
  bool _evaluating = false;
  Map<String, dynamic>? _result;

  @override
  void dispose() {
    _text.dispose();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (!_recorder.gravando) {
      if (_text.text.trim().isEmpty) return _notify(context, 'Cole primeiro o trecho que você vai ler.');
      if (!await _recorder.iniciar()) {
        if (mounted) _notify(context, 'Sem permissão para usar o microfone.');
        return;
      }
      setState(() {
        _start = DateTime.now();
        _result = null;
      });
      return;
    }
    final wav = await _recorder.parar();
    setState(() => _evaluating = true);
    try {
      if (wav == null || wav.length < 44 + 16000 * 2) throw 'Gravação curta demais.';
      final r = await widget.api.evaluateReading(wav, widget.language, _text.text.trim());
      final minutes = (DateTime.now().difference(_start ?? DateTime.now()).inSeconds / 60).ceil();
      widget.api.logActivity('leitura_voz', widget.language, minutes).catchError((_) {});
      setState(() {
        _result = r;
        _history = widget.api.voiceReadings(widget.language);
      });
    } catch (e) {
      if (mounted) _notify(context, e);
    } finally {
      if (mounted) setState(() => _evaluating = false);
    }
  }

  void _listen(String t) => widget.voice.listen(context, widget.api, t, widget.language);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final recording = _recorder.gravando;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Cole um trecho de artigo e leia em voz alta. O Whisper confere as palavras e o modelo fonético a pronúncia de '
          'cada uma (no leitor dos Arquivos, o microfone da leitura guiada faz o mesmo com a página).',
          style: theme.bodySmall,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _text,
          minLines: 3,
          maxLines: 10,
          enabled: !recording,
          decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Trecho para ler'),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: _evaluating ? null : _toggle,
              style: recording ? FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error) : null,
              icon: Icon(recording ? Icons.stop : Icons.mic),
              label: Text(recording ? 'Parar e avaliar' : 'Gravar minha leitura'),
            ),
            OutlinedButton.icon(
              onPressed: recording || _text.text.trim().isEmpty ? null : () => _listen(_text.text.trim()),
              icon: const Icon(Icons.volume_up_outlined),
              label: const Text('Ouvir o modelo'),
            ),
            if (_evaluating) const Text('Avaliando…'),
          ],
        ),
        if (_result != null)
          Card(
            margin: const EdgeInsets.only(top: 16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ResultadoLeituraVoz(resultado: _result!, ouvir: _listen),
            ),
          ),
        const SizedBox(height: 24),
        Text('Histórico', style: theme.titleSmall),
        FutureBuilder(
          future: _history,
          builder: (context, s) {
            final items = s.data;
            if (items == null) return const LinearProgressIndicator();
            if (items.isEmpty) return const Text('Nenhuma leitura ainda.');
            return Column(
              children: [
                for (final r in items)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(r['referencia'] as String, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      [
                        '${r['precisao']}% certas',
                        if (r['pronuncia'] != null) 'pronúncia ${r['pronuncia']}%',
                        '${r['ppm']} ppm',
                        if ((r['titulo'] as String? ?? '').isNotEmpty) r['titulo'],
                        _data(r['criado'] as String?),
                      ].join(' · '),
                    ),
                    onTap: () => showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                        content: SizedBox(
                          width: 560,
                          child: SingleChildScrollView(child: ResultadoLeituraVoz(resultado: r, ouvir: _listen)),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () async {
                              Navigator.pop(context);
                              await widget.api.deleteVoiceReading(r['id'] as String);
                              setState(() => _history = widget.api.voiceReadings(widget.language));
                            },
                            child: const Text('Excluir'),
                          ),
                          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fechar')),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

// --- Progresso ---

class _ProgressTab extends StatelessWidget {
  const _ProgressTab({super.key, required this.api, required this.language});

  final StudiesApi api;
  final String language;

  static const _types = {
    'leitura_guiada': 'Leitura guiada',
    'vocabulario': 'Revisão de vocabulário',
    'escrita': 'Escrita',
    'leitura_voz': 'Leitura em voz alta',
  };

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: api.progress(language),
    builder: (context, s) {
      if (s.hasError) return Center(child: Text('${s.error}'));
      final p = s.data;
      if (p == null) return const Center(child: CircularProgressIndicator());
      final theme = Theme.of(context).textTheme;
      final v = (p['vocabulario'] as Map).cast<String, dynamic>();
      final minutes = (p['minutos'] as Map).cast<String, dynamic>();
      final writing = (p['escrita'] as List).cast<Map>().reversed.take(10).toList();
      final reading = (p['leitura_voz'] as List).cast<Map>().reversed.take(10).toList();
      Widget section(String title, List<Widget> children) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [Text(title, style: theme.titleMedium), ...children],
          ),
        ),
      );
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          section('Vocabulário', [
            Text('${v['total']} palavras · ${v['devidas']} para revisar hoje'),
            Text('${v['aprendendo']} aprendendo · ${v['dominadas']} dominadas (intervalo de 3 semanas ou mais)'),
          ]),
          section('Tempo de estudo', [
            if (minutes.isEmpty) const Text('Nada registrado ainda.'),
            for (final e in minutes.entries) Text('${_types[e.key] ?? e.key}: ${e.value} min'),
          ]),
          section('Escrita (últimas notas)', [
            if (writing.isEmpty) const Text('Nenhuma resposta corrigida ainda.'),
            for (final e in writing) Text('${_data(e['data'] as String?)} — nota ${e['nota']} (${e['nivel_cefr']})'),
          ]),
          section('Leitura em voz alta (últimas)', [
            if (reading.isEmpty) const Text('Nenhuma leitura ainda.'),
            for (final l in reading)
              Text(
                '${_data(l['data'] as String?)} — ${l['precisao']}% certas, ${l['ppm']} ppm'
                '${l['pronuncia'] != null ? ', pronúncia ${l['pronuncia']}%' : ''}',
              ),
          ]),
        ],
      );
    },
  );
}
