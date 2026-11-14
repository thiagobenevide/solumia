import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_financas.dart';
import '../formato.dart';
import 'comuns.dart';

const _temas = {
  'economia': ('Economia', Icons.public),
  'acoes': ('Ações', Icons.show_chart),
  'fiis': ('FIIs', Icons.apartment),
  'impostos': ('Impostos', Icons.gavel),
  'juros': ('Juros e inflação', Icons.percent),
};

/// Manchetes das últimas 24 h por tema (Google Notícias via VPS); tocar abre a matéria no navegador.
class NoticiasTela extends StatefulWidget {
  const NoticiasTela({super.key, required this.api});

  final ApiFinancas api;

  @override
  State<NoticiasTela> createState() => _NoticiasTelaState();
}

class _NoticiasTelaState extends State<NoticiasTela> {
  String _tema = 'economia';
  late Future<Doc> _noticias = widget.api.noticias(tema: _tema);

  void _recarregar() => setState(() => _noticias = widget.api.noticias(tema: _tema));

  /// "há 25 min", "há 3 h" ou "ontem 18:40".
  static String _quando(String? iso) {
    final d = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
    if (d == null) return '';
    final dif = DateTime.now().difference(d);
    if (dif.inMinutes < 60) return 'há ${dif.inMinutes.clamp(1, 59)} min';
    if (dif.inHours < 24) return 'há ${dif.inHours} h';
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: () async => _recarregar(),
    child: ListView(
      padding: const EdgeInsets.all(8),
      children: [
        Secao(
          titulo: 'Notícias do dia',
          subtitulo: 'Últimas 24 horas, mais recentes primeiro.',
          acoes: [IconButton(tooltip: 'Atualizar', onPressed: _recarregar, icon: const Icon(Icons.refresh))],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final MapEntry(key: chave, value: (nome, icone)) in _temas.entries)
                    ChoiceChip(
                      avatar: Icon(icone, size: 18),
                      label: Text(nome),
                      selected: _tema == chave,
                      onSelected: (_) {
                        _tema = chave;
                        _recarregar();
                      },
                    ),
                ],
              ),
              Esperar(
                futuro: _noticias,
                recarregar: _recarregar,
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
                          subtitle: Text([n['fonte'], _quando(n['data'] as String?)].where((x) => '$x'.isNotEmpty).join(' · ')),
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
