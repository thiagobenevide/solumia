import 'dart:async';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';

import 'code_api.dart';
import 'claude_accounts.dart';
import 'models.dart';

/// Tabs of requests to the Claude Code on the PC: each tab is a separate conversation (like a new terminal),
/// and several can work at the same time.
class CodeScreen extends StatefulWidget {
  const CodeScreen({super.key, required this.api});

  final CodeApi api;

  @override
  State<CodeScreen> createState() => _CodeScreenState();
}

class _CodeScreenState extends State<CodeScreen> {
  List<CodeTab>? _tabs;
  String? _current;
  String? _unavailable;
  Object? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final tabs = await widget.api.list();
      final reason = await widget.api.unavailable();
      if (!mounted) return;
      setState(() {
        _tabs = tabs;
        _unavailable = reason;
        _error = null;
        if (!tabs.any((a) => a.id == _current)) _current = tabs.isEmpty ? null : tabs.last.id;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _newTask() async {
    final tab = await widget.api.create('Aba ${(_tabs?.length ?? 0) + 1}');
    setState(() {
      _tabs = [...?_tabs, tab];
      _current = tab.id;
    });
  }

  Future<void> _rename(CodeTab tab) async {
    final c = TextEditingController(text: tab.title);
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Renomear aba'),
        content: TextField(controller: c, autofocus: true, onSubmitted: (v) => Navigator.pop(ctx, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Salvar')),
        ],
      ),
    );
    if (title == null || title.trim().isEmpty) return;
    await widget.api.rename(tab.id, title);
    await _load();
  }

  Future<void> _close(CodeTab tab) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Fechar "${tab.title}"?'),
        content: Text(
          tab.running
              ? 'O Claude desta aba será parado e o histórico apagado. As mudanças nos arquivos ficam.'
              : 'O histórico da aba será apagado. As mudanças nos arquivos ficam.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Fechar')),
        ],
      ),
    );
    if (ok != true) return;
    await widget.api.delete(tab.id);
    await _load();
  }

  Future<void> _showGit() => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Repositório no PC'),
      content: SizedBox(
        width: 560,
        child: FutureBuilder(
          future: widget.api.git(),
          builder: (ctx, s) {
            if (s.hasError) return Text('${s.error}');
            if (!s.hasData) return const LinearProgressIndicator();
            final mono = Theme.of(ctx).textTheme.bodySmall!.copyWith(fontFamily: 'monospace');
            return SingleChildScrollView(
              child: SelectableText('${s.data!['status']}\n\nÚltimos commits:\n${s.data!['log']}', style: mono),
            );
          },
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Fechar'))],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final tabs = _tabs;
    if (tabs == null) {
      return _error != null ? ErroComRetry(erro: _error!, tentar: _load) : const Center(child: CircularProgressIndicator());
    }
    final theme = Theme.of(context);
    final current = [for (final a in tabs) if (a.id == _current) a].firstOrNull;
    return Column(
      children: [
        Material(
          color: theme.colorScheme.surfaceContainer,
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Row(
                    children: [
                      for (final a in tabs)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: GestureDetector(
                            onDoubleTap: () => _rename(a),
                            onLongPress: () => _rename(a),
                            child: InputChip(
                              selected: a.id == _current,
                              avatar: _Indicator(a),
                              label: Text(a.title),
                              onPressed: () => setState(() => _current = a.id),
                              onDeleted: () => _close(a),
                              deleteButtonTooltipMessage: 'Fechar aba',
                            ),
                          ),
                        ),
                      IconButton(tooltip: 'Nova aba', onPressed: _newTask, icon: const Icon(Icons.add)),
                    ],
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Contas do Claude (trocar ao bater o limite)',
                onPressed: () => showClaudeAccounts(context, widget.api),
                icon: const Icon(Icons.manage_accounts_outlined),
              ),
              IconButton(tooltip: 'Estado do git no PC', onPressed: _showGit, icon: const Icon(Icons.account_tree_outlined)),
            ],
          ),
        ),
        if (_unavailable != null)
          MaterialBanner(
            content: Text(_unavailable!),
            leading: const Icon(Icons.cloud_off),
            actions: [TextButton(onPressed: _load, child: const Text('Verificar'))],
          ),
        Expanded(
          child: current == null
              ? Center(
                  child: FilledButton.icon(onPressed: _newTask, icon: const Icon(Icons.add), label: const Text('Nova aba')),
                )
              : SessionView(key: ValueKey(current.id), api: widget.api, session: current, aoMudar: _load),
        ),
      ],
    );
  }
}

class _Indicator extends StatelessWidget {
  const _Indicator(this.tab);

  final CodeTab tab;

  @override
  Widget build(BuildContext context) {
    if (tab.running) return const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2));
    final color = tab.state == 'erro' ? Theme.of(context).colorScheme.error : Colors.green;
    return Icon(tab.eventos == 0 ? Icons.circle_outlined : Icons.circle, size: 12, color: color);
  }
}

/// One tab: live Claude steps, request box with images, stop and commit.
class SessionView extends StatefulWidget {
  const SessionView({super.key, required this.api, required this.session, required this.aoMudar});

  final CodeApi api;
  final CodeTab session;
  final VoidCallback aoMudar;

  @override
  State<SessionView> createState() => _SessionViewState();
}

class _SessionViewState extends State<SessionView> {
  late CodeTab _session = widget.session;
  final _steps = <SessionStep>[];
  final _string = TextEditingController();
  final _scroll = ScrollController();
  final _images = <(String, Uint8List)>[];
  bool _sending = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _string.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final since = _steps.length;
      final (session, novas) = await widget.api.fetch(_session.id, since: since);
      // The timer and sending can fetch at the same time: if another fetch already appended steps, drop this one
      // (otherwise the same step goes in twice).
      if (!mounted || _steps.length != since) return;
      final stateChanged = session.state != _session.state;
      final atEnd = !_scroll.hasClients || _scroll.position.extentAfter < 80;
      setState(() {
        _session = session;
        _steps.addAll(novas);
      });
      if (stateChanged) widget.aoMudar();
      if (novas.isNotEmpty && atEnd) _goToEnd();
    } catch (_) {
      // Offline right now: tries again on the next cycle.
    }
  }

  void _goToEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
  });

  /// Runs the [action] and returns whether it worked (an error becomes a warning on screen).
  Future<bool> _run(Future<CodeTab> Function() action) async {
    setState(() => _sending = true);
    try {
      final s = await action();
      if (mounted) setState(() => _session = s);
      widget.aoMudar();
      await _refresh();
      _goToEnd();
      return true;
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      return false;
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _send() async {
    final text = _string.text.trim();
    if (text.isEmpty || _session.running) return;
    final images = [..._images];
    if (!await _run(() => widget.api.send(_session.id, text, images: images)) || !mounted) return;
    _string.clear();
    setState(_images.clear);
  }

  Future<void> _attach() async {
    for (final f in await FilePicker.pickFiles(type: FileType.image)) {
      final bytes = await f.xFile.readAsBytes();
      setState(() => _images.add((f.name, bytes)));
    }
  }

  /// Ctrl+V: a copied image (screenshot or image file) becomes a reference; otherwise pastes the text.
  Future<void> _paste() async {
    if (_session.running) return;
    Uint8List? image;
    var files = <String>[];
    try {
      image = await Pasteboard.image;
      if (image == null) {
        files = [
          for (final c in await Pasteboard.files())
            if (RegExp(r'\.(png|jpe?g|gif|webp|bmp)$', caseSensitive: false).hasMatch(c)) c,
        ];
      }
    } catch (_) {}
    if (image != null) {
      setState(() => _images.add(('colada-${DateTime.now().millisecondsSinceEpoch}.png', image!)));
      return;
    }
    if (files.isNotEmpty) {
      for (final c in files) {
        final bytes = await File(c).readAsBytes();
        setState(() => _images.add((c.split(Platform.pathSeparator).last, bytes)));
      }
      return;
    }
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || text.isEmpty) return;
    final v = _string.value;
    final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    _string.value = v.replaced(sel, text);
  }

  Future<void> _commit() async {
    final mensagem = TextEditingController();
    var push = true;
    var publish = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setValue) => AlertDialog(
          title: const Text('Commitar o que esta aba mudou'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: mensagem,
                  decoration: const InputDecoration(
                    labelText: 'Mensagem (opcional)',
                    helperText: 'Vazio: o Claude escreve no padrão do repositório',
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Enviar (git push)'),
                  value: push,
                  onChanged: (v) => setValue(() => push = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Publicar versão do app'),
                  subtitle: const Text('infra/scripts/publicar_app: novo build no "Atualizar app"'),
                  value: publish,
                  onChanged: (v) => setValue(() => publish = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Commitar')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _run(
      () => widget.api.commit(_session.id, mensagem: mensagem.text, push: push, publish: publish),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = _session.running ? activity(_steps) : '';
    return Column(
      children: [
        if (_session.running) ...[
          const LinearProgressIndicator(minHeight: 2),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Row(
              children: [
                const Icon(Icons.bolt, size: 16),
                const SizedBox(width: 6),
                Expanded(child: Text(now, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall)),
              ],
            ),
          ),
        ],
        Expanded(
          child: _steps.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Descreva o recurso ou módulo que quer implementar. O Claude Code roda no PC, dentro do '
                      'repositório, seguindo o CLAUDE.md. Use várias abas para pedidos diferentes ao mesmo tempo.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  itemCount: _steps.length,
                  itemBuilder: (_, i) => _StepView(step: _steps[i], api: widget.api, session: _session.id),
                ),
        ),
        const Divider(height: 1),
        _box(theme),
      ],
    );
  }

  Widget _box(ThemeData theme) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    Widget input() => CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _send,
        const SingleActivator(LogicalKeyboardKey.keyV, control: true): _paste,
      },
      child: TextField(
        controller: _string,
        minLines: 1,
        // With the keyboard open there is little height left: the field scrolls inside instead of growing.
        maxLines: narrow ? 4 : 8,
        enabled: !_session.running,
        decoration: InputDecoration(
          hintText: _session.running
              ? 'O Claude está trabalhando nesta aba…'
              : _session.claudeSession == null
              ? 'O que implementar? (Ctrl+Enter envia)'
              : 'Continuar a conversa desta aba… (Ctrl+Enter envia)',
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
    return SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_images.isNotEmpty)
            SizedBox(
              height: 64,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final (i, (name, bytes)) in _images.indexed)
                    Padding(
                      padding: const EdgeInsets.only(right: 6, bottom: 6),
                      child: Stack(
                        children: [
                          Tooltip(
                            message: name,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: Image.memory(bytes, height: 58, width: 58, fit: BoxFit.cover),
                            ),
                          ),
                          Positioned(
                            right: 0,
                            top: 0,
                            child: InkWell(
                              onTap: () => setState(() => _images.removeAt(i)),
                              child: const CircleAvatar(radius: 9, child: Icon(Icons.close, size: 12)),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          // On the phone the field takes the full width and the buttons go to the line below;
          // squeezed between them the text was unreadable and vanished with the keyboard open.
          if (narrow) input(),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                tooltip: 'Imagens de referência',
                onPressed: _session.running ? null : _attach,
                icon: const Icon(Icons.add_photo_alternate_outlined),
              ),
              if (narrow) const Spacer() else Expanded(child: input()),
              const SizedBox(width: 4),
              if (_session.running)
                IconButton.filledTonal(
                  tooltip: 'Parar',
                  onPressed: _sending ? null : () => _run(() => widget.api.parar(_session.id)),
                  icon: const Icon(Icons.stop),
                )
              else ...[
                // A request to Claude Code changes the repository: the speech goes into the field to be checked first.
                BotaoMicrofone(
                  transcrever: widget.api.transcrever,
                  habilitado: !_sending,
                  aoTranscrever: (t) => setState(() {
                    final current = _string.text.trimRight();
                    _string.text = current.isEmpty ? t : '$current $t';
                  }),
                ),
                IconButton(
                  tooltip: 'Commit e versão',
                  onPressed: _sending || _session.claudeSession == null ? null : _commit,
                  icon: const Icon(Icons.commit),
                ),
                IconButton.filled(
                  tooltip: 'Enviar',
                  onPressed: _sending ? null : _send,
                  icon: const Icon(Icons.send),
                ),
              ],
            ],
          ),
        ],
      ),
    ),
  );
  }
}

IconData _toolIcon(String name) => switch (name) {
  'Bash' => Icons.terminal,
  'Read' => Icons.description_outlined,
  'Edit' || 'MultiEdit' || 'Write' || 'NotebookEdit' => Icons.edit_outlined,
  'Grep' || 'Glob' => Icons.search,
  'TodoWrite' => Icons.checklist,
  'WebFetch' || 'WebSearch' => Icons.public,
  _ => Icons.build_outlined,
};

class _StepView extends StatelessWidget {
  const _StepView({required this.step, required this.api, required this.session});

  final SessionStep step;
  final CodeApi api;
  final String session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final small = theme.textTheme.bodySmall!;
    final mono = small.copyWith(fontFamily: 'monospace');
    switch (step.type) {
      case 'pedido':
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 640),
            margin: const EdgeInsets.only(top: 12, bottom: 6, left: 48),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: colors.primaryContainer, borderRadius: BorderRadius.circular(12)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (step.commit)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [const Icon(Icons.commit, size: 16), const SizedBox(width: 4), Text('Commit', style: small)],
                  ),
                SelectableText(step.text),
                if (step.images.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [for (final name in step.images) _Thumbnail(api: api, session: session, name: name)],
                    ),
                  ),
              ],
            ),
          ),
        );
      case 'inicio':
        return _line(context, Icons.play_arrow, 'Claude Code iniciado${step.data['modelo'] != null ? ' (${step.data['modelo']})' : ''}');
      case 'texto':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: VisualizadorMarkdown(texto: step.text, estilo: theme.textTheme.bodyMedium),
        );
      case 'ferramenta':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(_toolIcon(step.name), size: 16, color: colors.primary),
              const SizedBox(width: 8),
              Text(step.name, style: small.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Expanded(child: SelectableText(step.summary, style: mono, maxLines: 3)),
            ],
          ),
        );
      case 'resultado':
        if (step.summary.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(left: 24, bottom: 4),
          child: ExpansionTile(
            dense: true,
            tilePadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            title: Text(
              step.summary.split('\n').first,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: mono.copyWith(color: step.error ? colors.error : colors.onSurfaceVariant),
            ),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: SelectableText(step.summary, style: mono.copyWith(color: step.error ? colors.error : null)),
              ),
            ],
          ),
        );
      case 'fim':
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 8),
          color: step.error ? colors.errorContainer : colors.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(step.error ? Icons.error_outline : Icons.check_circle_outline, size: 18),
                    const SizedBox(width: 6),
                    Text(step.error ? 'Terminou com erro' : 'Concluído', style: theme.textTheme.titleSmall),
                    const Spacer(),
                    Text(step.footer, style: small),
                  ],
                ),
                if (step.text.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  VisualizadorMarkdown(texto: step.text, estilo: theme.textTheme.bodyMedium),
                ],
              ],
            ),
          ),
        );
    }
    return const SizedBox.shrink();
  }

  Widget _line(BuildContext context, IconData icone, String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Icon(icone, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Text(text, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.api, required this.session, required this.name});

  final CodeApi api;
  final String session;
  final String name;

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: api.image(session, name),
    builder: (context, s) => ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: s.hasData
          ? GestureDetector(
              onTap: () => showDialog<void>(
                context: context,
                builder: (_) => Dialog(child: InteractiveViewer(child: Image.memory(s.data!))),
              ),
              child: Image.memory(s.data!, width: 72, height: 72, fit: BoxFit.cover),
            )
          : const SizedBox.square(dimension: 72, child: Icon(Icons.image_outlined)),
    ),
  );
}
