import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../finance_api.dart';
import '../format.dart';
import 'common.dart';

const _topics = {
  'economia': ('Economia', Icons.public),
  'acoes': ('Ações', Icons.show_chart),
  'fiis': ('FIIs', Icons.apartment),
  'impostos': ('Impostos', Icons.gavel),
  'juros': ('Juros e inflação', Icons.percent),
};

/// Headlines of the last 24 h by topic (Google News via VPS); tapping opens the article in the browser.
class NewsScreen extends StatefulWidget {
  const NewsScreen({super.key, required this.api});

  final FinanceApi api;

  @override
  State<NewsScreen> createState() => _NewsScreenState();
}

class _NewsScreenState extends State<NewsScreen> {
  String _topic = 'economia';
  late Future<Doc> _news = widget.api.news(topic: _topic);

  void _reload() => setState(() => _news = widget.api.news(topic: _topic));

  /// "há 25 min", "há 3 h" or "ontem 18:40".
  static String _when(String? iso) {
    final d = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
    if (d == null) return '';
    final diff = DateTime.now().difference(d);
    if (diff.inMinutes < 60) return 'há ${diff.inMinutes.clamp(1, 59)} min';
    if (diff.inHours < 24) return 'há ${diff.inHours} h';
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: () async => _reload(),
    child: ListView(
      padding: const EdgeInsets.all(8),
      children: [
        Section(
          title: 'Notícias do dia',
          subtitle: 'Últimas 24 horas, mais recentes primeiro.',
          stocks: [IconButton(tooltip: 'Atualizar', onPressed: _reload, icon: const Icon(Icons.refresh))],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final MapEntry(key: key, value: (name, icone)) in _topics.entries)
                    ChoiceChip(
                      avatar: Icon(icone, size: 18),
                      label: Text(name),
                      selected: _topic == key,
                      onSelected: (_) {
                        _topic = key;
                        _reload();
                      },
                    ),
                ],
              ),
              Waiting(
                future: _news,
                reload: _reload,
                construir: (d) {
                  final itens = (d['noticias'] as List).cast<Doc>();
                  if (itens.isEmpty) {
                    return const Padding(padding: EdgeInsets.all(16), child: Text('Nenhuma notícia nas últimas 24 horas.'));
                  }
                  return Column(
                    children: [
                      for (final n in itens)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.article_outlined),
                          title: Text('${n['titulo']}', maxLines: 3, overflow: TextOverflow.ellipsis),
                          subtitle: Text([n['fonte'], _when(n['data'] as String?)].where((x) => '$x'.isNotEmpty).join(' · ')),
                          trailing: const Icon(Icons.open_in_new, size: 18),
                          onTap: () => abrirLink(context, '${n['url']}'),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
