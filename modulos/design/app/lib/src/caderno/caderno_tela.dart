import 'dart:math';

import 'package:flutter/material.dart';

import '../api_design.dart';
import '../cache.dart';
import '../modelos.dart';
import '../quadro/editor.dart';
import '../quadro/quadro_tela.dart';
import 'caneta.dart';
import 'papel_dialogo.dart';
import 'referencias.dart';

/// Abre um caderno: o mesmo editor do fluxograma (formas, imagens, texto, seleção, páginas…) com a
/// folha pautada de cada página e a caneta inteligente.
class AbrirCaderno extends StatefulWidget {
  const AbrirCaderno({super.key, required this.api, required this.cache, required this.id});

  final ApiDesign api;
  final CacheQuadros cache;
  final String id;

  @override
  State<AbrirCaderno> createState() => _AbrirCadernoState();
}

class _AbrirCadernoState extends State<AbrirCaderno> {
  late final Future<EditorQuadro> _editor = _abrir();
  final _caneta = CanetaInteligente();

  Future<EditorQuadro> _abrir() async {
    final e = await EditorQuadro.abrir(widget.api, widget.cache, widget.id);
    e.papelPadrao = const Papel();
    e.ajustarTraco = (t) => _caneta.ajustar(t, unidade: e.papel?.espaco ?? 28);
    return e;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _editor,
    builder: (context, s) {
      if (s.hasData) return CadernoTela(editor: s.data!, caneta: _caneta);
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: s.hasError ? Text('Não abriu: ${s.error}') : const CircularProgressIndicator()),
      );
    },
  );
}

class CadernoTela extends StatefulWidget {
  const CadernoTela({super.key, required this.editor, required this.caneta});

  final EditorQuadro editor;
  final CanetaInteligente caneta;

  @override
  State<CadernoTela> createState() => _CadernoTelaState();
}

class _CadernoTelaState extends State<CadernoTela> {
  EditorQuadro get _editor => widget.editor;

  Future<void> _papel() async {
    final r = await editarPapel(context, _editor.papel ?? const Papel());
    if (r != null) await _editor.mudarPapel(r.papel, todas: r.todas);
  }

  Future<void> _referencias() async {
    final texto = await escolherReferencia(context, _editor.api);
    if (texto != null && texto.trim().isNotEmpty) _inserirReferencia(texto.trim());
  }

  /// Cartão da referência na folha aberta, logo abaixo do que já está escrito.
  void _inserirReferencia(String texto) {
    final papel = _editor.papel ?? const Papel();
    final largura = min(460.0, papel.largura - papel.recuo - papel.espaco);
    final linhas = texto.split('\n').fold<int>(0, (n, l) => n + max(1, (l.length / 52).ceil()));
    final altura = max(papel.espaco * 2, linhas * 20.0 + 24);
    final baixo = _editor.elementos.isEmpty ? null : limitesDe(_editor.elementos)?.bottom;
    final topo = max(papel.espaco * (papel.margem ? 3 : 1), (baixo ?? 0) + papel.espaco / 2);
    final a = Offset(papel.recuo + 6, topo);
    _editor.adicionar(
      NoFluxo(
        'ref${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
        tipo: TipoNo.nota,
        texto: texto,
        a: a,
        b: a + Offset(largura, altura),
        cor: const Color(0xFFC9A227),
        fundo: const Color(0xFFFFF8D6),
        esquerda: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => QuadroTela(
    editor: _editor,
    acoes: [
      IconButton(
        tooltip: widget.caneta.ligada
            ? 'Caneta inteligente ligada: retas e figuras ficam alinhadas'
            : 'Caneta inteligente desligada: traço livre',
        isSelected: widget.caneta.ligada,
        onPressed: () => setState(() => widget.caneta.ligada = !widget.caneta.ligada),
        icon: const Icon(Icons.auto_fix_off_outlined),
        selectedIcon: const Icon(Icons.auto_fix_high),
      ),
      IconButton(tooltip: 'Papel da folha (pauta, tamanho, cor)', onPressed: _papel, icon: const Icon(Icons.article_outlined)),
      IconButton(
        tooltip: 'Trazer referência (destaques dos Arquivos, Notas)',
        onPressed: _referencias,
        icon: const Icon(Icons.format_quote_outlined),
      ),
    ],
  );
}
