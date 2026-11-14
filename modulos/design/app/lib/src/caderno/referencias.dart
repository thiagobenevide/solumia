import 'dart:async';

import 'package:flutter/material.dart';

import '../api_design.dart';

/// Escolhe o que trazer para o caderno: um trecho destacado nos Arquivos (com a citação) ou uma nota
/// do cofre. Devolve o texto do cartão (`**título**` + trecho), ou null.
Future<String?> escolherReferencia(BuildContext context, ApiDesign api) =>
    showDialog(context: context, builder: (_) => _DialogoReferencias(api));

/// Texto do cartão de um destaque: arquivo e página em negrito, o trecho e o comentário em itálico.
String textoDoDestaque(Map<String, dynamic> d) {
  final pagina = d['pagina'] is num ? ', p. ${(d['pagina'] as num).toInt() + 1}' : '';
  final comentario = '${d['comentario'] ?? ''}'.trim();
  return [
    '**${d['arquivo_titulo'] ?? 'Arquivo'}$pagina**',
    '“${'${d['texto'] ?? ''}'.trim()}”',
    if (comentario.isNotEmpty) '*$comentario*',
  ].join('\n');
}

/// Cartão de uma nota: título em negrito e o começo do corpo (sem o Markdown pesado).
String textoDaNota(Map<String, dynamic> n) {
  final corpo = '${n['corpo'] ?? ''}'
      .split('\n')
      .map((l) => l.replaceFirst(RegExp(r'^#+\s*'), '').trim())
      .where((l) => l.isNotEmpty)
      .take(8)
      .join('\n');
  return ['**${n['titulo'] ?? 'Nota'}**', if (corpo.isNotEmpty) corpo].join('\n');
}

class _DialogoReferencias extends StatefulWidget {
  const _DialogoReferencias(this.api);

  final ApiDesign api;

  @override
  State<_DialogoReferencias> createState() => _DialogoReferenciasState();
}

class _DialogoReferenciasState extends State<_DialogoReferencias> {
  final _busca = TextEditingController();
  Timer? _espera;
  late Future<List<Map<String, dynamic>>> _destaques = widget.api.destaques('');
  late Future<List<Map<String, dynamic>>> _notas = widget.api.notas('');

  @override
  void dispose() {
    _espera?.cancel();
    _busca.dispose();
    super.dispose();
  }

  void _buscar(String q) {
    _espera?.cancel();
    _espera = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      setState(() {
        _destaques = widget.api.destaques(q.trim());
        _notas = widget.api.notas(q.trim());
      });
    });
  }

  Future<void> _escolherNota(Map<String, dynamic> resumo) async {
    final navegador = Navigator.of(context);
    try {
      navegador.pop(textoDaNota(await widget.api.nota('${resumo['id']}')));
    } catch (_) {
      navegador.pop(textoDaNota(resumo));
    }
  }

  Widget _lista(Future<List<Map<String, dynamic>>> futuro, Widget Function(Map<String, dynamic>) item) =>
      FutureBuilder(
        future: futuro,
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
                controller: _busca,
                autofocus: true,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Buscar nos destaques e nas notas',
                  border: OutlineInputBorder(),
                ),
                onChanged: _buscar,
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
                  _lista(
                    _destaques,
                    (d) => ListTile(
                      leading: const Icon(Icons.picture_as_pdf_outlined),
                      title: Text('${d['texto'] ?? ''}', maxLines: 3, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${d['arquivo_titulo'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => Navigator.pop(context, textoDoDestaque(d)),
                    ),
                  ),
                  _lista(
                    _notas,
                    (n) => ListTile(
                      leading: const Icon(Icons.description_outlined),
                      title: Text('${n['titulo'] ?? ''}'),
                      subtitle: Text('${n['tipo'] ?? ''}'),
                      onTap: () => _escolherNota(n),
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
