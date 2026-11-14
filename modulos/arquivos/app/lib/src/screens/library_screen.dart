import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../files_api.dart';
import '../editors/presentation_screen.dart';
import '../editors/collabora_screen.dart';
import '../editors/document_screen.dart';
import '../editors/export.dart';
import '../editors/spreadsheet_screen.dart';
import '../editors/rewrite.dart';
import '../external/external.dart';
import '../reader/data_screen.dart';
import '../reader/reader_screen.dart';
import '../models.dart';
import '../offline.dart';
import 'highlight_actions.dart';
import 'highlights_tab.dart';

const acceptedExtensions = [
  'pdf',
  'docx',
  'doc',
  'odt',
  'rtf',
  'pptx',
  'ppt',
  'odp',
  'csv',
  'xls',
  'xlsx',
  'ods',
  'ofx',
  'qfx',
  'txt',
  'xml',
];

bool hasEditor(FileItem a) => const {'docx', 'xlsx', 'pptx'}.contains(a.extension);

/// Own editor per extension (the app's Word, Excel and PowerPoint); the rest only in the reader.
Widget Function(BuildContext)? editorDe(FilesApi api, FileItem a) => switch (a.extension) {
  'docx' => (_) => DocumentScreen(api: api, file: a),
  'xlsx' => (_) => SpreadsheetScreen(api: api, file: a),
  'pptx' => (_) => PresentationScreen(api: api, file: a),
  _ => null,
};

/// Opens the format's viewer: DOCX/XLSX/PPTX in the editor, CSV as a table and XML as a tree (they read the
/// original); the rest in the PDF reader (warns if it is still converting or if the conversion failed).
/// [read] forces the PDF reader (to annotate with ink).
Future<void> openFile(BuildContext context, FilesApi api, FileItem a, {int page = 1, bool read = false}) async {
  final editor = read ? null : editorDe(api, a);
  if (editor != null) return abrirTela<void>(context, editor);
  switch (a.formatStr) {
    case FileFormat.csv:
      return abrirTela<void>(context, (_) => CsvScreen(api: api, file: a));
    case FileFormat.xml:
      return abrirTela<void>(context, (_) => XmlScreen(api: api, file: a));
    default:
  }
  if (a.status == 'convertendo') return notify(context, 'Ainda convertendo para PDF; já fica pronto.');
  if (a.status == 'erro') return notify(context, 'A conversão falhou: ${a.error ?? 'erro'}');
  await abrirTela<void>(context, (_) => ReaderScreen(api: api, file: a, initialPage: page));
}

/// Picks an installed program and opens the original in it; what is saved there uploads on its own
/// (offline, it stays in the device queue). The grid updates through the change polling.
Future<void> openWithEditor(BuildContext context, FilesApi api, FileItem a) async {
  final editors = editorsFor(a);
  final chosenItem = await showDialog<Editor>(
    context: context,
    builder: (c) => SimpleDialog(
      title: Text('Abrir "${a.nomeOriginal}" com'),
      children: [
        for (final e in editors) SimpleDialogOption(onPressed: () => Navigator.pop(c, e), child: Text(e.name)),
      ],
    ),
  );
  if (chosenItem == null) return;
  try {
    final bytes =
        await api.offline.original(a.id) ??
        (a.type == 'pdf' ? await api.offline.pdf(a.id) : null) ??
        await api.original(a.id);
    await openExternally(chosenItem, a, bytes, (isNew) => api.offline.saveOriginal(a, isNew));
    if (context.mounted) notify(context, 'Aberto no ${chosenItem.name}; ao salvar lá, a versão sobe sozinha.');
  } on ApiErro catch (e) {
    if (context.mounted) notify(context, 'Não consegui abrir: ${e.mensagem}');
  }
}

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key, required this.api});

  final FilesApi api;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Column(
      children: [
        const TabBar(
          tabs: [
            Tab(icon: Icon(Icons.folder_open_outlined), text: 'Arquivos'),
            Tab(icon: Icon(Icons.border_color_outlined), text: 'Destaques'),
          ],
        ),
        Expanded(
          child: TabBarView(
            children: [
              _FilesTab(api: api),
              HighlightsTab(api: api),
            ],
          ),
        ),
      ],
    ),
  );
}

class _FilesTab extends StatefulWidget {
  const _FilesTab({required this.api});

  final FilesApi api;

  @override
  State<_FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<_FilesTab> {
  List<FileItem>? _files;
  List<String> _pastas = [];
  String? _pasta;

  /// Filtro por formato (PDF, DOCX, PPTX, CSV, XML); `null` mostra todos.
  FileFormat? _format;
  String _search = '';
  Object? _error;
  int _seq = -1;
  Timer? _polling;
  Timer? _typing;
  String? _sending;

  /// Offline: the grid shows only the files downloaded on the device.
  bool _offline = false;
  Set<String> _downloaded = {};
  int _pendingItems = 0;
  bool _syncing = false;

  /// Selection for batch actions (download, duplicate, rename, delete); only what is visible counts.
  bool _selecting = false;
  final Set<String> _selectedItems = {};

  OfflineVault get _vault => widget.api.offline;

  List<FileItem>? get _visible {
    final all = _files;
    return all == null || _format == null
        ? all
        : [
            for (final a in all)
              if (a.formatStr == _format) a,
          ];
  }

  List<FileItem> get _chosen => [
    for (final a in _visible ?? const <FileItem>[])
      if (_selectedItems.contains(a.id)) a,
  ];

  void _toggle(FileItem a) => setState(() {
    _selecting = true;
    if (!_selectedItems.remove(a.id)) _selectedItems.add(a.id);
  });

  void _leaveSelection() => setState(() {
    _selecting = false;
    _selectedItems.clear();
  });

  @override
  void initState() {
    super.initState();
    _load();
    // What changes on another device (new file, deletion, finished conversion) shows up here.
    _polling = Timer.periodic(const Duration(seconds: 4), (_) => _checkChanges());
  }

  @override
  void dispose() {
    _polling?.cancel();
    _typing?.cancel();
    super.dispose();
  }

  Future<void> _checkChanges() async {
    if (_offline || _pendingItems > 0) return _load();
    try {
      final (seq, _) = await widget.api.changes(1 << 50);
      if (seq != _seq) await _load();
    } catch (_) {
      // Offline: the next cycle tries again.
    }
  }

  Future<void> _load() async {
    try {
      final (seq, _) = await widget.api.changes(1 << 50);
      if (await _vault.pendingItems() > 0) await _sync();
      final (files, pastas) = await (widget.api.list(q: _search, pasta: _pasta), widget.api.pastas()).wait;
      final (downloadedItems, pendingItems) = await (_vault.downloadedItems(), _vault.pendingItems()).wait;
      if (!mounted) return;
      setState(() {
        _seq = seq;
        _files = files;
        _selectedItems.retainAll({for (final a in files) a.id});
        _pastas = pastas;
        _downloaded = downloadedItems;
        _pendingItems = pendingItems;
        _offline = false;
        _error = null;
      });
    } catch (e) {
      if (semConexao(e)) return _loadFromDevice();
      if (mounted) setState(() => _error = e is ParallelWaitError ? e.errors : e);
    }
  }

  /// Offline: lists what was downloaded, with the same search and folder.
  Future<void> _loadFromDevice() async {
    final (all, pendingItems) = await (_vault.files(), _vault.pendingItems()).wait;
    final term = _search.toLowerCase();
    if (!mounted) return;
    setState(() {
      _offline = true;
      _error = null;
      _pendingItems = pendingItems;
      _downloaded = {for (final a in all) a.id};
      _pastas = {for (final a in all) a.pasta}.where((p) => p.isNotEmpty).toList()..sort();
      _files = [
        for (final a in all)
          if ((_pasta == null || a.pasta == _pasta) &&
              [a.title, a.nomeOriginal, ...a.tags].any((t) => t.toLowerCase().contains(term)))
            a,
      ];
    });
  }

  Future<void> _sync() async {
    if (_syncing) return;
    _syncing = true;
    try {
      final warnings = await _vault.sync();
      if (warnings.isNotEmpty && mounted) notify(context, 'Sincronizado, com avisos: ${warnings.join('; ')}');
    } finally {
      _syncing = false;
    }
  }

  /// Downloads to the device all the ready files of the current list (search and folder apply).
  Future<void> _downloadListed() async {
    final remaining = [
      for (final a in _files ?? const <FileItem>[])
        if (a.pronto && !_downloaded.contains(a.id)) a,
    ];
    if (remaining.isEmpty) return notify(context, 'Tudo o que está listado já está no aparelho.');
    for (final (i, a) in remaining.indexed) {
      setState(() => _sending = 'Baixando ${i + 1}/${remaining.length}');
      try {
        await _vault.download(a);
      } on ApiErro catch (e) {
        if (mounted) notify(context, '${a.title}: ${e.mensagem}');
        if (semConexao(e)) break;
      }
    }
    if (!mounted) return;
    setState(() => _sending = null);
    await _load();
  }

  Future<void> _edit(FileItem a, {String? title, String? pasta, List<String>? tags}) async {
    try {
      await widget.api.edit(a.id, title: title, pasta: pasta, tags: tags);
    } on ApiErro catch (e) {
      if (!semConexao(e)) rethrow;
      await _vault.edit(a, title: title, pasta: pasta, tags: tags);
    }
  }

  Future<void> _add() async {
    final chosen = await FilePicker.pickFiles(
      dialogTitle: 'Adicionar arquivos',
      type: FileType.custom,
      allowedExtensions: acceptedExtensions,
    );
    if (chosen.isEmpty || !mounted) return;
    final duplicatedItems = <String>[];
    final stored = <String>[];
    for (final (i, f) in chosen.indexed) {
      setState(() => _sending = 'Enviando ${i + 1}/${chosen.length}: ${f.name}');
      final bytes = await f.xFile.readAsBytes();
      try {
        final (_, duplicated) = await widget.api.send(f.name, bytes, pasta: _pasta ?? '');
        if (duplicated) duplicatedItems.add(f.name);
      } on ApiErro catch (e) {
        if (semConexao(e)) {
          await _vault.send(f.name, bytes, pasta: _pasta ?? '');
          stored.add(f.name);
        } else if (mounted) {
          notify(context, '${f.name}: ${e.mensagem}');
        }
      }
    }
    if (!mounted) return;
    setState(() => _sending = null);
    if (duplicatedItems.isNotEmpty) notify(context, 'Já estavam na biblioteca: ${duplicatedItems.join(', ')}');
    if (stored.isNotEmpty) notify(context, 'Sem conexão: ${stored.join(', ')} sobem quando a conexão voltar.');
    await _load();
  }

  Future<void> _act(String action, FileItem a) async {
    try {
      switch (action) {
        case 'renomear':
          final t = await askText(context, title: 'Renomear', initial: a.title);
          if (t != null && t.trim().isNotEmpty) await _edit(a, title: t.trim());
        case 'pasta':
          final p = await askText(
            context,
            title: 'Mover para a pasta',
            initial: a.pasta,
            label: 'Pasta (vazio = sem pasta)',
          );
          if (p != null) await _edit(a, pasta: p.trim());
        case 'tags':
          final t = await askText(context, title: 'Tags (separadas por vírgula)', initial: a.tags.join(', '));
          if (t != null) {
            await _edit(
              a,
              tags: [
                for (final x in t.split(','))
                  if (x.trim().isNotEmpty) x.trim(),
              ],
            );
          }
        case 'baixar':
          final bytes = await widget.api.original(a.id);
          final saved = await FilePicker.saveFile(fileName: a.nomeOriginal, bytes: bytes);
          if (saved != null && mounted) notify(context, 'Salvo: ${a.nomeOriginal}');
        case 'offline':
          if (_downloaded.contains(a.id)) {
            await _vault.remover(a.id);
          } else {
            setState(() => _sending = 'Baixando ${a.title}');
            try {
              await _vault.download(a);
            } finally {
              if (mounted) setState(() => _sending = null);
            }
          }
        case 'fora':
          await openWithEditor(context, widget.api, a);
        case 'ler':
          await openFile(context, widget.api, a, read: true);
        case 'exportar':
          await exportFile(context, widget.api, a);
        case 'collabora':
          await abrirTela<void>(context, (_) => CollaboraScreen(api: widget.api, file: a));
        case 'claude':
          // Outside the editor there is nowhere to apply it: the accepted suggestion goes to the clipboard.
          final text = await rewriteWithClaude(context, widget.api, fileId: a.id, title: a.title);
          if (text != null) {
            await Clipboard.setData(ClipboardData(text: text));
            if (mounted) notify(context, 'Texto reescrito copiado; cole no documento.');
          }
        case 'converter':
          await widget.api.reconvert(a.id);
        case 'excluir':
          final ok = await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: Text('Excluir "${a.title}"?'),
              content: Text(
                'O arquivo e as anotações (${a.highlights} destaques) somem de todos os aparelhos. Não dá para desfazer.',
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
                FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Excluir')),
              ],
            ),
          );
          if (ok == true) await _delete(a);
        case 'duplicar':
          await widget.api.duplicate(a.id);
      }
    } on ApiErro catch (e) {
      if (mounted) notify(context, e.mensagem);
    }
    await _load();
  }

  Future<void> _delete(FileItem a) async {
    try {
      await widget.api.delete(a.id);
      await _vault.remover(a.id);
    } on ApiErro catch (e) {
      if (!semConexao(e)) rethrow;
      await _vault.delete(a.id);
    }
  }

  /// Action on the selected ones; with only one, falls into the card menu (same dialogs).
  Future<void> _batch(String action) async {
    final chosen = _chosen;
    if (chosen.isEmpty) return notify(context, 'Nenhum arquivo selecionado.');
    if (chosen.length == 1 && action != 'excluir') return _act(action, chosen.single);
    final n = chosen.length;
    try {
      switch (action) {
        case 'baixar':
          // Several originals in a single ZIP: one save dialog, the same on desktop, web and phone.
          final zip = Archive();
          final names = <String>{};
          for (final (i, a) in chosen.indexed) {
            setState(() => _sending = 'Baixando ${i + 1}/$n');
            var name = a.nomeOriginal;
            for (var k = 2; !names.add(name); k++) {
              name = '${a.title} ($k).${a.extension}';
            }
            zip.addFile(ArchiveFile.bytes(name, await widget.api.original(a.id)));
          }
          final saved = await FilePicker.saveFile(fileName: 'arquivos.zip', bytes: ZipEncoder().encodeBytes(zip));
          if (saved != null && mounted) notify(context, '$n arquivos salvos em arquivos.zip');
          return;
        case 'duplicar':
          for (final (i, a) in chosen.indexed) {
            setState(() => _sending = 'Duplicando ${i + 1}/$n');
            await widget.api.duplicate(a.id);
          }
        case 'renomear':
          final base = await askText(
            context,
            title: 'Renomear $n arquivos',
            label: 'Nome (vira "Nome 1", "Nome 2"…)',
          );
          if (base == null || base.trim().isEmpty) return;
          for (final (i, a) in chosen.indexed) {
            await _edit(a, title: '${base.trim()} ${i + 1}');
          }
        case 'excluir':
          final highlights = chosen.fold(0, (s, a) => s + a.highlights);
          final ok = await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: Text(n == 1 ? 'Excluir "${chosen.single.title}"?' : 'Excluir $n arquivos?'),
              content: Text(
                'Os arquivos e as anotações ($highlights destaques) somem de todos os aparelhos. Não dá para desfazer.',
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
                FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Excluir')),
              ],
            ),
          );
          if (ok != true) return;
          for (final (i, a) in chosen.indexed) {
            setState(() => _sending = 'Excluindo ${i + 1}/$n');
            await _delete(a);
          }
      }
      if (mounted) _leaveSelection();
    } on ApiErro catch (e) {
      if (mounted) notify(context, e.mensagem);
    } finally {
      if (mounted) setState(() => _sending = null);
      if (action != 'baixar') await _load();
    }
  }

  Widget _selectionBar() {
    final visible = _visible ?? const <FileItem>[];
    final all = visible.isNotEmpty && visible.every((a) => _selectedItems.contains(a.id));
    final active = _sending == null && _selectedItems.isNotEmpty;
    return Row(
      children: [
        IconButton(tooltip: 'Sair da seleção', icon: const Icon(Icons.close), onPressed: _leaveSelection),
        Text('${_chosen.length} selecionado(s)', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(width: 8),
        TextButton.icon(
          icon: Icon(all ? Icons.deselect : Icons.select_all),
          label: Text(all ? 'Limpar' : 'Selecionar todos (${visible.length})'),
          onPressed: () => setState(() {
            all ? _selectedItems.clear() : _selectedItems.addAll(visible.map((a) => a.id));
          }),
        ),
        const Spacer(),
        IconButton(
          tooltip: 'Baixar (vários vão num ZIP)',
          icon: const Icon(Icons.download),
          onPressed: active && !_offline ? () => _batch('baixar') : null,
        ),
        IconButton(
          tooltip: 'Duplicar',
          icon: const Icon(Icons.copy_all_outlined),
          onPressed: active && !_offline ? () => _batch('duplicar') : null,
        ),
        IconButton(
          tooltip: 'Renomear',
          icon: const Icon(Icons.drive_file_rename_outline),
          onPressed: active ? () => _batch('renomear') : null,
        ),
        IconButton(
          tooltip: 'Excluir',
          icon: const Icon(Icons.delete_outline),
          onPressed: active ? () => _batch('excluir') : null,
        ),
      ],
    );
  }

  /// Blank document, spreadsheet or presentation (generated on the server) already open in the editor.
  Future<void> _new() async {
    final title = TextEditingController(text: 'Sem título');
    var type = 'documento';
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Novo arquivo'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'documento', icon: Icon(Icons.description_outlined), label: Text('Documento')),
                  ButtonSegment(value: 'planilha', icon: Icon(Icons.table_chart_outlined), label: Text('Planilha')),
                  ButtonSegment(value: 'apresentacao', icon: Icon(Icons.slideshow_outlined), label: Text('Apresentação')),
                ],
                selected: {type},
                onSelectionChanged: (s) => set(() => type = s.first),
              ),
              TextField(controller: title, autofocus: true, decoration: const InputDecoration(labelText: 'Título')),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Criar')),
          ],
        ),
      ),
    );
    final name = title.text.trim();
    title.dispose();
    if (ok != true || !mounted) return;
    setState(() => _sending = 'Criando…');
    try {
      final a = await widget.api.isNew(type, name, pasta: _pasta ?? '');
      await _load();
      if (mounted) await openFile(context, widget.api, a);
    } on ApiErro catch (e) {
      if (mounted) notify(context, 'Não consegui criar: ${e.mensagem}');
    } finally {
      if (mounted) setState(() => _sending = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final all = _files;
    final files = _visible;
    final counts = <FileFormat, int>{};
    for (final a in all ?? const <FileItem>[]) {
      counts[a.formatStr] = (counts[a.formatStr] ?? 0) + 1;
    }
    return Scaffold(
      floatingActionButton: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 12,
        children: [
          FloatingActionButton.extended(
            heroTag: 'novo',
            onPressed: _sending == null ? _new : null,
            icon: const Icon(Icons.note_add_outlined),
            label: const Text('Novo'),
          ),
          FloatingActionButton.extended(
            heroTag: 'adicionar',
            onPressed: _sending == null ? _add : null,
            icon: const Icon(Icons.upload_file),
            label: Text(_sending ?? 'Adicionar'),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_selecting)
            Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: _selectionBar()),
          FiltrosRecolhiveis(
            chave: 'arquivos.biblioteca',
            resumo: [?_pasta, ?_format?.label, if (_search.isNotEmpty) '"$_search"'].join(' · '),
            children: [
          if (!_selecting)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
                    spacing: 4,
                    children: [
                      Expanded(
                        child: TextField(
                          decoration: const InputDecoration(
                            prefixIcon: Icon(Icons.search),
                            hintText: 'Buscar por título, nome ou tag',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          onChanged: (v) {
                            _search = v;
                            _typing?.cancel();
                            _typing = Timer(const Duration(milliseconds: 300), _load);
                          },
                        ),
                      ),
                      IconButton(
                        tooltip: 'Selecionar arquivos (ou segure/clique longo num cartão)',
                        icon: const Icon(Icons.checklist),
                        onPressed: () => setState(() => _selecting = true),
                      ),
                      IconButton(
                        tooltip: 'Baixar para o aparelho todos os listados (para usar sem conexão)',
                        icon: const Icon(Icons.download_for_offline_outlined),
                        onPressed: _offline || _sending != null ? null : _downloadListed,
                      ),
                    ],
                  ),
          ),
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final p in <String?>[null, ..._pastas])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(p ?? 'Todas'),
                      avatar: p == null ? null : const Icon(Icons.folder_outlined, size: 18),
                      selected: _pasta == p,
                      onSelected: (_) {
                        setState(() => _pasta = p);
                        _load();
                      },
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final f in <FileFormat?>[null, ...FileFormat.values])
                  if (f != FileFormat.other || counts.containsKey(f))
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: Text(f == null ? 'Todos (${all?.length ?? 0})' : '${f.label} (${counts[f] ?? 0})'),
                        selected: _format == f,
                        onSelected: (_) => setState(() => _format = f),
                      ),
                    ),
              ],
            ),
          ),
            ],
          ),
          if (_offline || _pendingItems > 0)
            MaterialBanner(
              leading: Icon(_offline ? Icons.cloud_off : Icons.cloud_sync_outlined),
              content: Text(
                [
                  if (_offline) 'Sem conexão: mostrando os arquivos baixados no aparelho.',
                  if (_pendingItems > 0) '$_pendingItems alteração(ões) esperando para subir.',
                ].join(' '),
              ),
              actions: [TextButton(onPressed: _load, child: const Text('Sincronizar'))],
            ),
          if (_error != null)
            MaterialBanner(
              content: Text('Sem conexão com a API de arquivos: $_error'),
              actions: [TextButton(onPressed: _load, child: const Text('Tentar de novo'))],
            ),
          Expanded(
            child: files == null
                ? Center(child: _error == null ? const CircularProgressIndicator() : const SizedBox())
                : files.isEmpty
                ? Center(
                    child: Text(
                      _format == null
                          ? 'Nenhum arquivo. Adicione PDF, DOCX, PPTX, CSV ou XML pelo botão abaixo.'
                          : 'Nenhum arquivo ${_format!.label} aqui.',
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _load,
                    child: GridView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 220,
                        childAspectRatio: 0.66,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                      ),
                      itemCount: files.length,
                      itemBuilder: (context, i) => _FileCard(
                        api: widget.api,
                        file: files[i],
                        downloaded: _downloaded.contains(files[i].id),
                        selecting: _selecting,
                        selected: _selectedItems.contains(files[i].id),
                        onSelect: () => _toggle(files[i]),
                        onOpen: () async {
                          await openFile(context, widget.api, files[i]);
                          await _load();
                        },
                        onAction: (action) => _act(action, files[i]),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _FileCard extends StatelessWidget {
  const _FileCard({
    required this.api,
    required this.file,
    required this.downloaded,
    required this.selecting,
    required this.selected,
    required this.onSelect,
    required this.onOpen,
    required this.onAction,
  });

  final FilesApi api;
  final FileItem file;
  final bool downloaded;
  final bool selecting;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onOpen;
  final ValueChanged<String> onAction;

  IconData get _icon => switch (file.type) {
    'apresentacao' => Icons.slideshow_outlined,
    'planilha' => Icons.table_chart_outlined,
    'xml' => Icons.code,
    'extrato' => Icons.receipt_long_outlined,
    'documento' => Icons.description_outlined,
    _ => Icons.picture_as_pdf_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final a = file;
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: selected
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: colors.primary, width: 3),
            )
          : null,
      child: InkWell(
        onTap: selecting ? onSelect : onOpen,
        onLongPress: onSelect,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: colors.surfaceContainerHighest,
                    child: a.pronto
                        ? Image(
                            image: ImagemRede(api.thumbnailUrl(a).toString(), headers: api.cabecalhos),
                            fit: BoxFit.cover,
                            alignment: Alignment.topCenter,
                            errorBuilder: (_, _, _) => Icon(_icon, size: 48, color: colors.outline),
                          )
                        : Icon(_icon, size: 48, color: colors.outline),
                  ),
                  if (a.status != 'pronto')
                    Positioned(
                      left: 8,
                      bottom: 8,
                      child: Chip(
                        visualDensity: VisualDensity.compact,
                        avatar: a.status == 'convertendo'
                            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                            : Icon(Icons.error_outline, color: colors.error),
                        label: Text(a.status == 'convertendo' ? 'convertendo' : 'falhou'),
                      ),
                    ),
                  if (selecting)
                    Positioned(
                      top: 4,
                      left: 4,
                      child: Checkbox(value: selected, onChanged: (_) => onSelect()),
                    )
                  else if (downloaded)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Tooltip(
                        message: 'Disponível sem conexão',
                        child: CircleAvatar(
                          radius: 14,
                          backgroundColor: colors.primaryContainer,
                          child: Icon(Icons.offline_pin, size: 18, color: colors.onPrimaryContainer),
                        ),
                      ),
                    ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: PopupMenuButton<String>(
                      onSelected: onAction,
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'renomear', child: Text('Renomear')),
                        const PopupMenuItem(value: 'pasta', child: Text('Mover para pasta')),
                        const PopupMenuItem(value: 'tags', child: Text('Tags')),
                        if (a.pronto)
                          PopupMenuItem(
                            value: 'offline',
                            child: Text(downloaded ? 'Remover do aparelho' : 'Disponível offline'),
                          ),
                        if (hasEditor(a) && a.pronto)
                          const PopupMenuItem(value: 'ler', child: Text('Ler e anotar (PDF)')),
                        if (exportFormats.containsKey(a.type))
                          const PopupMenuItem(value: 'exportar', child: Text('Exportar…')),
                        if (editorsFor(a).isNotEmpty) const PopupMenuItem(value: 'fora', child: Text('Abrir com…')),
                        if (const {'documento', 'apresentacao', 'planilha'}.contains(a.type))
                          const PopupMenuItem(value: 'collabora', child: Text('Editar no Collabora')),
                        if (a.type == 'documento' || a.type == 'pdf')
                          const PopupMenuItem(value: 'claude', child: Text('Reescrever trecho com Claude')),
                        const PopupMenuItem(value: 'baixar', child: Text('Baixar original')),
                        const PopupMenuItem(value: 'duplicar', child: Text('Duplicar')),
                        if (a.type != 'pdf' && a.type != 'xml')
                          const PopupMenuItem(value: 'converter', child: Text('Converter de novo')),
                        const PopupMenuItem(value: 'excluir', child: Text('Excluir')),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 2,
                children: [
                  Text(
                    a.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  Text(
                    [
                      a.extension.toUpperCase(),
                      if (a.pasta.isNotEmpty) a.pasta,
                      if (a.highlights > 0) '${a.highlights} destaques',
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
