import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../studies_api.dart';
import 'projects_screen.dart' show OpenInFile;

/// Project document (the finished pre-thesis, as .docx): attaching sends the file to Arquivos and
/// Claude does the reverse mapping — finds each citation in the reference PDFs and marks the excerpt
/// in the project. References without a PDF stay as pending downloads (they also become tasks on the board);
/// "Refazer mapeamento" runs again after downloading.
class MappingPanel extends StatefulWidget {
  const MappingPanel({super.key, required this.api, required this.projectId, this.openInFile, this.onComplete});

  final StudiesApi api;
  final String projectId;
  final OpenInFile? openInFile;

  /// Called when a mapping finishes (the screen reloads the matrix).
  final VoidCallback? onComplete;

  @override
  State<MappingPanel> createState() => _MappingPanelState();
}

class _MappingPanelState extends State<MappingPanel> {
  Map<String, dynamic> _m = const {};
  bool _sending = false;
  Timer? _clock;

  bool get _running => _m['estado'] == 'rodando';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final m = await widget.api.mapping(widget.projectId);
      if (!mounted) return;
      final finished = _running && m['estado'] != 'rodando';
      setState(() => _m = m);
      _watch();
      if (finished) widget.onComplete?.call();
    } on ApiErro catch (_) {
      // offline: the panel stays as it was
    }
  }

  void _watch() {
    _clock?.cancel();
    if (_running) _clock = Timer(const Duration(seconds: 3), _load);
  }

  void _notify(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _attach() async {
    final chosen = await FilePicker.pickFiles(
      dialogTitle: 'Documento do projeto (.docx ou PDF)',
      type: FileType.custom,
      allowedExtensions: const ['docx', 'pdf'],
    );
    if (chosen.isEmpty || !mounted) return;
    final f = chosen.first;
    setState(() => _sending = true);
    try {
      final bytes = await f.xFile.readAsBytes();
      final m = await widget.api.attachDocument(widget.projectId, f.name, bytes);
      if (!mounted) return;
      setState(() => _m = m);
      _watch();
      _notify('${f.name} guardado nos Arquivos. Mapeando as citações e buscando os artigos.');
    } on ApiErro catch (e) {
      if (mounted) _notify(e.mensagem);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _redo() async {
    setState(() => _sending = true);
    try {
      final m = await widget.api.redoMapping(widget.projectId);
      if (!mounted) return;
      setState(() => _m = m);
      _watch();
    } on ApiErro catch (e) {
      if (mounted) _notify(e.mensagem);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final refs = [for (final r in (_m['referencias'] as List? ?? const [])) (r as Map).cast<String, dynamic>()];
    final pending = refs.where((r) => r['arquivo_id'] == null).toList();
    final hasDocument = _m['documento_id'] != null;
    final busy = _sending || _running;

    final buttons = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.tonalIcon(
          icon: const Icon(Icons.attach_file),
          label: Text(hasDocument ? 'Trocar documento' : 'Anexar documento (.docx ou PDF)'),
          onPressed: busy ? null : _attach,
        ),
        if (hasDocument)
          OutlinedButton.icon(
            icon: const Icon(Icons.manage_search),
            label: const Text('Refazer mapeamento'),
            onPressed: busy ? null : _redo,
          ),
      ],
    );

    final String subtitle;
    if (!hasDocument) {
      subtitle =
          'Anexe o texto (inteiro ou só introdução/resumo, .docx ou PDF): as citações são achadas nas '
          'referências, os PDFs abertos são baixados e os trechos marcados aqui.';
    } else if (_running) {
      subtitle = _m['etapa'] as String? ?? 'Mapeando…';
    } else if (_m['estado'] == 'erro') {
      subtitle = 'Falhou: ${_m['erro'] ?? ''}';
    } else {
      subtitle =
          '${_m['citacoes'] ?? 0} citações · ${_m['marcadas'] ?? 0} marcadas · '
          '${pending.length} referência(s) para baixar';
    }

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: Icon(Icons.description_outlined, color: theme.colorScheme.primary),
        title: Text(
          hasDocument ? 'Documento: ${_m['documento_titulo'] ?? ''}' : 'Documento do projeto',
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          subtitle,
          style: _m['estado'] == 'erro' ? TextStyle(color: theme.colorScheme.error) : null,
        ),
        trailing: _running || _sending
            ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : null,
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          buttons,
          // The panel sits in a Column without scrolling: the list scrolls inside a maximum height.
          if (refs.isNotEmpty)
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.5),
              child: Scrollbar(
                child: ListView(
                  shrinkWrap: true,
                  primary: false,
                  children: [
                    if (pending.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        'Sem PDF aberto (fechados): baixe e envie para Arquivos; depois toque em '
                        '"Refazer mapeamento". Os de acesso aberto já são baixados sozinhos no mapeamento.',
                        style: theme.textTheme.titleSmall,
                      ),
                      for (final r in pending) _Reference(r, openInFile: widget.openInFile),
                    ],
                    if (refs.length > pending.length) ...[
                      const SizedBox(height: 12),
                      Text('Referências com PDF', style: theme.textTheme.titleSmall),
                      for (final r in refs.where((r) => r['arquivo_id'] != null))
                        _Reference(r, openInFile: widget.openInFile),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Where to download the reference, taken from its own text (without redoing the analysis): the DOI (doi.org), the
/// link already in the reference and searches by title and author (Google Scholar and Google, filetype:pdf).
List<(String, IconData, String)> referenceLinks(Map<String, dynamic> r) {
  final text = r['referencia'] as String? ?? '';
  final links = <(String, IconData, String)>[];
  final match = (r['link'] as String? ?? '').trim();
  if (match.isNotEmpty) links.add(('Abrir o artigo', Icons.article_outlined, match));
  final doi = RegExp(r'\b(10\.\d{4,9}/[^\s]+)', caseSensitive: false).firstMatch(text)?.group(1);
  if (doi != null) {
    links.add(('Abrir pelo DOI', Icons.link, 'https://doi.org/${doi.replaceAll(RegExp(r'[.,;]+$'), '')}'));
  }
  for (final m in RegExp(r'https?://[^\s>)\]]+').allMatches(text)) {
    final url = m.group(0)!.replaceAll(RegExp(r'[.,;]+$'), '');
    if (!url.contains('doi.org')) links.add(('Link da referência', Icons.public, url));
  }
  final title = (r['titulo'] as String? ?? '').trim();
  final author = (r['autor_citacao'] as String? ?? '').replaceAll(RegExp(r'\bet al\.?'), '').trim();
  final search = Uri.encodeQueryComponent('"$title" $author'.trim());
  links.add(('Buscar no Google Acadêmico', Icons.school_outlined, 'https://scholar.google.com/scholar?q=$search'));
  links.add(('Buscar o PDF no Google', Icons.search, 'https://www.google.com/search?q=$search+filetype%3Apdf'));
  return links;
}

class _Reference extends StatelessWidget {
  const _Reference(this.r, {this.openInFile});

  final Map<String, dynamic> r;
  final OpenInFile? openInFile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final file = r['arquivo_id'] as String?;
    final remaining = [for (final x in (r['nao_localizadas'] as List? ?? const [])) '$x'];
    final citations = r['citacoes'] as int? ?? 0;
    final marked = r['marcadas'] as int? ?? 0;
    final links = referenceLinks(r);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: file == null
          ? IconButton(
              tooltip: 'Abrir onde baixar (${links.first.$1})',
              icon: Icon(Icons.download_outlined, color: theme.colorScheme.error),
              onPressed: () => abrirLink(context, links.first.$3),
            )
          : Icon(
              marked >= citations ? Icons.check_circle : Icons.error_outline,
              color: marked >= citations ? theme.colorScheme.primary : theme.colorScheme.tertiary,
            ),
      title: SelectableText('${r['autor_citacao']} (${r['ano']}) — ${r['titulo']}'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(r['referencia'] as String? ?? '', style: theme.textTheme.bodySmall),
          Text(
            file == null
                ? 'Sem PDF nos Arquivos · $citations citação(ões) no documento'
                : '${r['baixado_auto'] == true ? 'Baixado sozinho (acesso aberto) · ' : ''}'
                      '${r['arquivo_titulo'] ?? ''} · $marked/$citations citação(ões) marcadas',
            style: theme.textTheme.bodySmall,
          ),
          for (final f in remaining)
            Text('Não localizada: $f', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.tertiary)),
        ],
      ),
      trailing: file != null && openInFile != null
          ? IconButton(
              tooltip: 'Abrir o PDF',
              icon: const Icon(Icons.open_in_new),
              onPressed: () => openInFile!(context, file, 1),
            )
          : file != null
          ? null
          : PopupMenuButton<String>(
              tooltip: 'Links e copiar',
              icon: const Icon(Icons.more_vert),
              onSelected: (v) {
                if (v == 'copiar') {
                  Clipboard.setData(ClipboardData(text: r['referencia'] as String? ?? ''));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Referência copiada')));
                } else {
                  abrirLink(context, v);
                }
              },
              itemBuilder: (_) => [
                for (final (label, icone, url) in links)
                  PopupMenuItem(value: url, child: ListTile(leading: Icon(icone), title: Text(label), dense: true)),
                const PopupMenuItem(
                  value: 'copiar',
                  child: ListTile(leading: Icon(Icons.copy), title: Text('Copiar referência'), dense: true),
                ),
              ],
            ),
    );
  }
}
