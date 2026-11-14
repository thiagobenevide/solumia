import 'dart:async';

import 'package:flutter/material.dart';

import '../design_api.dart';

/// Picks what to bring into the notebook: an excerpt highlighted in Arquivos (with the citation) or a vault
/// note. Returns the card text (`**title**` + excerpt), or null.
Future<String?> pickReference(BuildContext context, ApiDesign api) =>
    showDialog(context: context, builder: (_) => _ReferencesDialog(api));

/// Card text of a highlight: file and page in bold, the excerpt and the comment in italics.
String highlightText(Map<String, dynamic> d) {
  final page = d['pagina'] is num ? ', p. ${(d['pagina'] as num).toInt() + 1}' : '';
  final comment = '${d['comentario'] ?? ''}'.trim();
  return [
    '**${d['arquivo_titulo'] ?? 'Arquivo'}$page**',
    '“${'${d['texto'] ?? ''}'.trim()}”',
    if (comment.isNotEmpty) '*$comment*',
  ].join('\n');
}

/// Card of a note: title in bold and the start of the body (without the heavy Markdown).
String noteText(Map<String, dynamic> n) {
  final body = '${n['corpo'] ?? ''}'
      .split('\n')
      .map((l) => l.replaceFirst(RegExp(r'^#+\s*'), '').trim())
      .where((l) => l.isNotEmpty)
      .take(8)
      .join('\n');
  return ['**${n['titulo'] ?? 'Nota'}**', if (body.isNotEmpty) body].join('\n');
}

class _ReferencesDialog extends StatefulWidget {
  const _ReferencesDialog(this.api);

  final ApiDesign api;

  @override
  State<_ReferencesDialog> createState() => _ReferencesDialogState();
}

class _ReferencesDialogState extends State<_ReferencesDialog> {
  final _search = TextEditingController();
  Timer? _wait;
  late Future<List<Map<String, dynamic>>> _highlights = widget.api.highlights('');
  late Future<List<Map<String, dynamic>>> _notes = widget.api.notas('');

  @override
  void dispose() {
    _wait?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _runSearch(String q) {
    _wait?.cancel();
    _wait = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      setState(() {
        _highlights = widget.api.highlights(q.trim());
        _notes = widget.api.notas(q.trim());
      });
    });
  }

  Future<void> _pickNote(Map<String, dynamic> summary) async {
    final browser = Navigator.of(context);
    try {
      browser.pop(noteText(await widget.api.nota('${summary['id']}')));
    } catch (_) {
      browser.pop(noteText(summary));
    }
  }

  Widget _list(Future<List<Map<String, dynamic>>> future, Widget Function(Map<String, dynamic>) item) =>
      FutureBuilder(
        future: future,
        builder: (context, s) {
          if (s.hasError) return Center(child: Text('Não carregou: ${s.error}'));
          if (!s.hasData) return const Center(child: CircularProgressIndicator());
          if (s.data!.isEmpty) return const Center(child: Text('Nada encontrado.'));
          return ListView(children: [for (final d in s.data!.take(80)) item(d)]);
        },
      );

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 560,
      height: 600,
      child: DefaultTabController(
        length: 2,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: TextField(
                controller: _search,
                autofocus: true,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Buscar nos destaques e nas notas',
                  border: OutlineInputBorder(),
                ),
                onChanged: _runSearch,
              ),
            ),
            const TabBar(
              tabs: [
                Tab(icon: Icon(Icons.format_quote_outlined), text: 'Destaques dos arquivos'),
                Tab(icon: Icon(Icons.sticky_note_2_outlined), text: 'Notas'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _list(
                    _highlights,
                    (d) => ListTile(
                      leading: const Icon(Icons.picture_as_pdf_outlined),
                      title: Text('${d['texto'] ?? ''}', maxLines: 3, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${d['arquivo_titulo'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => Navigator.pop(context, highlightText(d)),
                    ),
                  ),
                  _list(
                    _notes,
                    (n) => ListTile(
                      leading: const Icon(Icons.description_outlined),
                      title: Text('${n['titulo'] ?? ''}'),
                      subtitle: Text('${n['tipo'] ?? ''}'),
                      onTap: () => _pickNote(n),
                    ),
                  ),
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fechar')),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
