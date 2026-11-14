import 'dart:math' as math;

import 'package:agent_core/agent_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:pdfrx/pdfrx.dart';

import '../api_arquivos.dart';
import '../modelos.dart';
import 'camada_pagina.dart';
import 'diagramacao.dart';

export 'diagramacao.dart';

/// Como a tradução aparece no leitor: no painel, ou por cima do próprio PDF.
enum ModoTraducao { desligada, painel, sobrePagina }

/// Página traduzida: o texto do PDF, os blocos e a tradução de cada frase (vazia = não veio).
class PaginaTraduzida {
  PaginaTraduzida(this.texto, this.blocos, this.traducoes);

  final TextoPagina texto;
  final List<Bloco> blocos;
  final List<String> traducoes;

  /// Frases na ordem de leitura.
  late final frases = frasesDe(blocos);

  /// Português do bloco; a frase que não veio fica no original.
  String textoDe(Bloco b) => [
    for (var k = 0; k < b.frases.length; k++)
      traducoes[b.primeira + k].isEmpty ? b.frases[k].original : traducoes[b.primeira + k],
  ].join(' ');
}

List<Frase> frasesDe(List<Bloco> blocos) => [for (final b in blocos) ...b.frases];

/// Traduz o documento inteiro, página por página, a partir da que está na tela; o que já foi traduzido
/// fica no servidor (`/traducao`) e volta na hora quando o arquivo é aberto de novo.
class TradutorDocumento extends ChangeNotifier {
  TradutorDocumento(this.api, this.arquivoId, this.textos);

  final ApiArquivos api;
  final String arquivoId;
  final TextosDasPaginas textos;

  /// Páginas 0-based.
  final paginas = <int, PaginaTraduzida>{};
  final semTexto = <int>{};
  final _pedindo = <int>{};
  Map<String, dynamic>? _cache;
  String? erro;
  bool ativo = false;
  int total = 0;
  bool _descartado = false;

  bool traduzindo(int pagina) => _pedindo.contains(pagina);
  int get prontas => paginas.length + semTexto.length;

  void parar() {
    ativo = false;
    _avisar();
  }

  void _avisar() {
    if (!_descartado) notifyListeners();
  }

  @override
  void dispose() {
    _descartado = true;
    ativo = false;
    super.dispose();
  }

  Future<void> traduzirDocumento(PdfDocument doc, int aPartirDe) async {
    if (ativo) return;
    ativo = true;
    erro = null;
    total = doc.pages.length;
    _avisar();
    try {
      _cache ??= await api.traducao(arquivoId);
      final ordem = [for (var i = aPartirDe; i < total; i++) i, for (var i = 0; i < aPartirDe; i++) i];
      var lote = <int, (TextoPagina, List<Bloco>)>{};
      var tamanho = 0;
      for (final i in ordem) {
        if (!ativo) return;
        if (paginas.containsKey(i) || semTexto.contains(i)) continue;
        final t = await textos.de(doc.pages[i]);
        final blocos = t == null ? const <Bloco>[] : diagramar(t.texto, t.caracteres);
        final frases = frasesDe(blocos);
        if (t == null || frases.isEmpty) {
          semTexto.add(i);
          _avisar();
          continue;
        }
        final c = _cache?['$i'];
        if (c is Map && listEquals((c['segmentos'] as List?)?.cast<String>(), [for (final f in frases) f.original])) {
          paginas[i] = PaginaTraduzida(t, blocos, (c['traducoes'] as List).cast<String>());
          _avisar();
          continue;
        }
        lote[i] = (t, blocos);
        tamanho += frases.fold(0, (s, f) => s + f.original.length);
        // A página da tela vai sozinha, para aparecer logo; as outras em lotes de ~6 mil caracteres.
        if (tamanho > 6000 || i == aPartirDe) {
          await _enviar(lote);
          lote = {};
          tamanho = 0;
        }
      }
      if (ativo && lote.isNotEmpty) await _enviar(lote);
    } on ApiErro catch (e) {
      erro = e.mensagem;
    } catch (e) {
      erro = '$e';
    } finally {
      ativo = false;
      _avisar();
    }
  }

  /// Pede de novo a tradução da [pagina] (quando veio estranha ou incompleta).
  Future<void> refazer(int pagina) async {
    final p = paginas.remove(pagina);
    if (p == null) return;
    try {
      await _enviar({pagina: (p.texto, p.blocos)}, refazer: true);
    } on ApiErro catch (e) {
      paginas[pagina] = p;
      erro = e.mensagem;
      _avisar();
    }
  }

  Future<void> _enviar(Map<int, (TextoPagina, List<Bloco>)> lote, {bool refazer = false}) async {
    _pedindo.addAll(lote.keys);
    _avisar();
    try {
      final r = await api.traduzir(arquivoId, {
        for (final e in lote.entries) e.key: [for (final f in frasesDe(e.value.$2)) f.original],
      }, refazer: refazer);
      for (final e in lote.entries) {
        final traducoes = ((r['${e.key}'] as Map?)?['traducoes'] as List?)?.cast<String>() ?? const [];
        final n = frasesDe(e.value.$2).length;
        paginas[e.key] = PaginaTraduzida(e.value.$1, e.value.$2, [
          for (var k = 0; k < n; k++) k < traducoes.length ? traducoes[k] : '',
        ]);
      }
    } finally {
      _pedindo.removeAll(lote.keys);
      _avisar();
    }
  }
}

/// Tradução da página na tela, para ler em português. Selecionar um trecho e tocar em "Marcar no
/// original" marca as frases em inglês no PDF e cria o destaque com original + tradução (que entra
/// no projeto de leitura ativo).
class PainelTraducao extends StatefulWidget {
  const PainelTraducao({
    super.key,
    required this.tradutor,
    required this.pagina,
    required this.destaques,
    required this.aoMarcar,
    required this.aoRetomar,
    required this.aoFechar,
  });

  final TradutorDocumento tradutor;

  /// Página na tela, 0-based.
  final int pagina;

  /// Destaques da página, para mostrar o que já foi marcado.
  final List<Destaque> destaques;
  final void Function(PaginaTraduzida pagina, List<int> frases) aoMarcar;
  final VoidCallback aoRetomar;
  final VoidCallback aoFechar;

  @override
  State<PainelTraducao> createState() => _PainelTraducaoState();
}

class _PainelTraducaoState extends State<PainelTraducao> {
  /// Frases selecionadas, por bloco (cada parágrafo avisa da sua parte da seleção).
  final _selecao = <Bloco, Set<int>>{};
  int _geracao = 0;

  List<int> get _frases => _selecao.values.expand((s) => s).toList()..sort();

  void _limpar() {
    _selecao.clear();
    _geracao++;
  }

  @override
  void didUpdateWidget(PainelTraducao antigo) {
    super.didUpdateWidget(antigo);
    if (antigo.pagina != widget.pagina) _limpar();
  }

  void _selecionou(Bloco b, Set<int> frases) {
    if (setEquals(_selecao[b] ?? const {}, frases)) return;
    setState(() => frases.isEmpty ? _selecao.remove(b) : _selecao[b] = frases);
  }

  void _marcar(PaginaTraduzida p) {
    final frases = _frases;
    if (frases.isEmpty) return;
    widget.aoMarcar(p, frases);
    setState(_limpar);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tradutor;
    final cores = Theme.of(context).colorScheme;
    final p = t.paginas[widget.pagina];
    final cabecalho = Row(
      children: [
        const SizedBox(width: 12),
        const Icon(Icons.translate, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Tradução · p. ${widget.pagina + 1}'
            '${t.total > 0 && t.prontas < t.total ? '  (${t.prontas}/${t.total} páginas)' : ''}',
            style: Theme.of(context).textTheme.titleSmall,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (t.ativo)
          IconButton(tooltip: 'Pausar a tradução', icon: const Icon(Icons.pause), onPressed: t.parar)
        else if (t.prontas < t.total || t.total == 0)
          IconButton(
            tooltip: 'Continuar traduzindo o documento',
            icon: const Icon(Icons.play_arrow),
            onPressed: widget.aoRetomar,
          ),
        if (p != null)
          IconButton(
            tooltip: 'Traduzir esta página de novo',
            icon: const Icon(Icons.refresh),
            onPressed: t.traduzindo(widget.pagina) ? null : () => t.refazer(widget.pagina),
          ),
        IconButton(tooltip: 'Fechar a tradução', icon: const Icon(Icons.close), onPressed: widget.aoFechar),
      ],
    );
    Widget corpo;
    if (p != null) {
      final estilo = Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.5);
      corpo = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SelectionArea(
              key: ValueKey((p, _geracao)),
              contextMenuBuilder: (context, estado) => AdaptiveTextSelectionToolbar.buttonItems(
                anchors: estado.contextMenuAnchors,
                buttonItems: [
                  ContextMenuButtonItem(
                    label: 'Marcar no original',
                    onPressed: () {
                      estado.hideToolbar();
                      _marcar(p);
                    },
                  ),
                  ...estado.contextMenuButtonItems,
                ],
              ),
              child: LayoutBuilder(
                builder: (context, area) => SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final b in p.blocos)
                        if (b.frases.isNotEmpty || b.numeros.isNotEmpty)
                          _Paragrafo(
                            pagina: p,
                            bloco: b,
                            estilo: estilo,
                            largura: area.maxWidth - 32,
                            destaques: widget.destaques,
                            aoSelecionar: (frases) => _selecionou(b, frases),
                          ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_selecao.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: FilledButton.icon(
                icon: const Icon(Icons.border_color),
                label: const Text('Marcar no original (inglês + português)'),
                onPressed: () => _marcar(p),
              ),
            ),
        ],
      );
    } else if (t.semTexto.contains(widget.pagina)) {
      corpo = const _Aviso('Esta página não tem texto selecionável (imagem ou escaneada).');
    } else if (t.traduzindo(widget.pagina) || t.ativo) {
      corpo = const Center(child: CircularProgressIndicator());
    } else {
      corpo = _Aviso(t.erro ?? 'Toque em ▶ para traduzir o documento a partir desta página.');
    }
    return Material(
      color: cores.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          cabecalho,
          if (t.erro != null && p != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(t.erro!, style: TextStyle(color: cores.error)),
            ),
          const Divider(height: 1),
          Expanded(child: corpo),
        ],
      ),
    );
  }
}

/// Um bloco da página no painel, com o corpo, o alinhamento, o recuo e o vão que tem no PDF.
class _Paragrafo extends StatefulWidget {
  const _Paragrafo({
    required this.pagina,
    required this.bloco,
    required this.estilo,
    required this.largura,
    required this.destaques,
    required this.aoSelecionar,
  });

  final PaginaTraduzida pagina;
  final Bloco bloco;
  final TextStyle? estilo;
  final double largura;
  final List<Destaque> destaques;

  /// Índices (na página) das frases que a seleção pega neste bloco.
  final ValueChanged<Set<int>> aoSelecionar;

  @override
  State<_Paragrafo> createState() => _ParagrafoState();
}

class _ParagrafoState extends State<_Paragrafo> {
  final _notificador = SelectionListenerNotifier();
  var _faixas = <(int, int)>[];

  @override
  void initState() {
    super.initState();
    _notificador.addListener(_mudouSelecao);
  }

  @override
  void dispose() {
    _notificador.dispose();
    super.dispose();
  }

  void _mudouSelecao() {
    final s = _notificador.selection;
    final r = s.range;
    final frases = <int>{};
    if (s.status == SelectionStatus.uncollapsed && r != null) {
      final inicio = math.min(r.startOffset, r.endOffset);
      final fim = math.max(r.startOffset, r.endOffset);
      for (var k = 0; k < _faixas.length; k++) {
        if (_faixas[k].$1 < fim && _faixas[k].$2 > inicio) frases.add(widget.bloco.primeira + k);
      }
    }
    // A seleção pode mudar no meio de um layout (a tela girou, o painel redimensionou).
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
      widget.aoSelecionar(frases);
    } else {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.aoSelecionar(frases);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.bloco;
    final p = widget.pagina;
    final cores = Theme.of(context).colorScheme;
    final spans = <InlineSpan>[];
    _faixas = [];
    var pos = 0;
    void escrever(String texto, [TextStyle? estilo]) {
      spans.add(TextSpan(text: texto, style: estilo));
      pos += texto.length;
    }

    if (b.recuoPrimeiraLinha) escrever('\u2003\u2003');
    escrever(b.numeros);
    for (var k = 0; k < b.frases.length; k++) {
      if (k > 0) escrever(' ');
      final f = b.frases[k];
      final pt = p.traducoes[b.primeira + k];
      final inicio = pos;
      escrever(
        pt.isEmpty ? f.original : pt,
        TextStyle(
          fontStyle: pt.isEmpty ? FontStyle.italic : null,
          color: pt.isEmpty ? cores.outline : null,
          backgroundColor: widget.destaques
              .where((d) => d.texto.contains(f.original))
              .firstOrNull
              ?.cor
              .withValues(alpha: 0.35),
        ),
      );
      _faixas.add((inicio, pos));
    }
    final estilo = widget.estilo;
    return Padding(
      padding: EdgeInsets.only(
        top: b.vaoAntes * 10,
        left: widget.largura * b.recuo,
        right: widget.largura * b.recuoDireita,
      ),
      child: SelectionListener(
        selectionNotifier: _notificador,
        child: Text.rich(
          TextSpan(children: spans),
          textAlign: switch (b.alinhamento) {
            Alinhamento.esquerda => TextAlign.left,
            Alinhamento.centro => TextAlign.center,
            Alinhamento.direita => TextAlign.right,
            Alinhamento.justificado => TextAlign.justify,
          },
          style: estilo?.copyWith(
            fontSize: (estilo.fontSize ?? 16) * b.escala.clamp(0.8, 1.7),
            fontWeight: b.titulo ? FontWeight.bold : null,
          ),
        ),
      ),
    );
  }
}

class _Aviso extends StatelessWidget {
  const _Aviso(this.texto);

  final String texto;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(texto, textAlign: TextAlign.center),
    ),
  );
}
