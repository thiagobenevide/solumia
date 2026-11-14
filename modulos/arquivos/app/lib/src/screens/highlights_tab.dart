import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../files_api.dart';
import '../models.dart';
import 'highlight_actions.dart';
import 'library_screen.dart';

/// All marked excerpts, of all files: the source of references for the notes.
class HighlightsTab extends StatefulWidget {
  const HighlightsTab({super.key, required this.api});

  final FilesApi api;

  @override
  State<HighlightsTab> createState() => _HighlightsTabState();
}

class _HighlightsTabState extends State<HighlightsTab> {
  List<Reference>? _items;
  Object? _error;
  String _search = '';
  Timer? _typing;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _typing?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final itens = await widget.api.highlights(q: _search);
      if (mounted) {
        setState(() {
          _items = itens;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _open(Reference r) async {
    final file = await widget.api.fetch(r.fileId);
    if (mounted) await openFile(context, widget.api, file, page: r.highlight.page + 1);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final itens = _items;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            spacing: 8,
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Buscar nos trechos e comentários',
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
                tooltip: 'Copiar todos (Markdown)',
                icon: const Icon(Icons.copy_all),
                onPressed: itens == null || itens.isEmpty
                    ? null
                    : () {
                        Clipboard.setData(ClipboardData(text: itens.map((r) => r.citation).join('\n\n')));
                        notify(context, '${itens.length} referências copiadas');
                      },
              ),
              IconButton(tooltip: 'Atualizar', icon: const Icon(Icons.refresh), onPressed: _load),
            ],
          ),
        ),
        if (_error != null) Text('Sem conexão: $_error'),
        Expanded(
          child: itens == null
              ? const Center(child: CircularProgressIndicator())
              : itens.isEmpty
              ? const Center(child: Text('Nenhum destaque. No leitor, use o marca-texto que salva o texto.'))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: itens.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final r = itens[i];
                      final d = r.highlight;
                      return ListTile(
                        leading: Container(width: 6, height: 40, color: d.color.withValues(alpha: 1)),
                        title: Text(d.text, maxLines: 4, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          [
                            '${r.fileTitle} · p. ${d.page + 1}',
                            if (d.comment.isNotEmpty) d.comment,
                          ].join('\n'),
                        ),
                        onTap: () => showHighlight(context, api: widget.api, reference: r, onOpen: () => _open(r)),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}
