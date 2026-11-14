import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_arquivos.dart';
import '../modelos.dart';
import 'acoes_destaque.dart';
import 'biblioteca_tela.dart';

/// Todos os trechos marcados, de todos os arquivos: a fonte de referências para as notas.
class DestaquesAba extends StatefulWidget {
  const DestaquesAba({super.key, required this.api});

  final ApiArquivos api;

  @override
  State<DestaquesAba> createState() => _DestaquesAbaState();
}

class _DestaquesAbaState extends State<DestaquesAba> {
  List<Referencia>? _itens;
  Object? _erro;
  String _busca = '';
  Timer? _digitando;

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  @override
  void dispose() {
    _digitando?.cancel();
    super.dispose();
  }

  Future<void> _carregar() async {
    try {
      final itens = await widget.api.destaques(q: _busca);
      if (mounted) {
        setState(() {
          _itens = itens;
          _erro = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _erro = e);
    }
  }

  Future<void> _abrir(Referencia r) async {
    final arquivo = await widget.api.obter(r.arquivoId);
    if (mounted) await abrirArquivo(context, widget.api, arquivo, pagina: r.destaque.pagina + 1);
    await _carregar();
  }

  @override
  Widget build(BuildContext context) {
    final itens = _itens;
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
                    _busca = v;
                    _digitando?.cancel();
                    _digitando = Timer(const Duration(milliseconds: 300), _carregar);
                  },
                ),
              ),
              IconButton(
                tooltip: 'Copiar todos (Markdown)',
                icon: const Icon(Icons.copy_all),
                onPressed: itens == null || itens.isEmpty
                    ? null
                    : () {
                        Clipboard.setData(ClipboardData(text: itens.map((r) => r.citacao).join('\n\n')));
                        avisar(context, '${itens.length} referências copiadas');
                      },
              ),
              IconButton(tooltip: 'Atualizar', icon: const Icon(Icons.refresh), onPressed: _carregar),
            ],
          ),
        ),
        if (_erro != null) Text('Sem conexão: $_erro'),
        Expanded(
          child: itens == null
              ? const Center(child: CircularProgressIndicator())
              : itens.isEmpty
              ? const Center(child: Text('Nenhum destaque. No leitor, use o marca-texto que salva o texto.'))
              : RefreshIndicator(
                  onRefresh: _carregar,
                  child: ListView.separated(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: itens.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final r = itens[i];
                      final d = r.destaque;
                      return ListTile(
                        leading: Container(width: 6, height: 40, color: d.cor.withValues(alpha: 1)),
                        title: Text(d.texto, maxLines: 4, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          [
                            '${r.arquivoTitulo} · p. ${d.pagina + 1}',
                            if (d.comentario.isNotEmpty) d.comentario,
                          ].join('\n'),
                        ),
                        onTap: () => mostrarDestaque(context, api: widget.api, referencia: r, aoAbrir: () => _abrir(r)),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}
