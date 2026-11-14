import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'traducao.dart';

/// Texto em português de um bloco, já ajustado à área dele, em pontos PDF.
class _Caixa {
  _Caixa(this.area, this.texto);

  final Rect area;
  final TextPainter texto;
}

/// Maior corpo em que [texto] cabe na área do bloco (o português costuma ser mais comprido).
TextPainter _ajustar(String texto, Bloco b) {
  final minimo = b.fonte * 0.4;
  var corpo = b.fonte;
  while (true) {
    final t = TextPainter(
      text: TextSpan(
        text: texto,
        style: TextStyle(
          color: Colors.black87,
          fontSize: corpo,
          height: 1.15,
          fontWeight: b.titulo ? FontWeight.bold : null,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: switch (b.alinhamento) {
        Alinhamento.esquerda => TextAlign.left,
        Alinhamento.centro => TextAlign.center,
        Alinhamento.direita => TextAlign.right,
        Alinhamento.justificado => TextAlign.justify,
      },
    )..layout(minWidth: b.area.width, maxWidth: b.area.width);
    if (t.height <= b.area.height + b.corpo * 0.2 || corpo <= minimo) return t;
    t.dispose();
    corpo *= 0.94;
  }
}

/// A tradução no lugar do texto do PDF, bloco a bloco, como a tradução de tela do Android: figuras e
/// margens continuam as da página. Fica embaixo da tinta, então os destaques aparecem por cima.
class CamadaTraducao extends StatefulWidget {
  const CamadaTraducao({super.key, required this.pagina, required this.tradutor, required this.modo});

  final PdfPage pagina;
  final TradutorDocumento tradutor;
  final ValueNotifier<ModoTraducao> modo;

  @override
  State<CamadaTraducao> createState() => _CamadaTraducaoState();
}

class _CamadaTraducaoState extends State<CamadaTraducao> {
  PaginaTraduzida? _feita;
  var _caixas = <_Caixa>[];

  void _descartar() {
    for (final c in _caixas) {
      c.texto.dispose();
    }
    _caixas = [];
  }

  @override
  void dispose() {
    _descartar();
    super.dispose();
  }

  List<_Caixa> _caixasDe(PaginaTraduzida p) {
    if (!identical(p, _feita)) {
      _descartar();
      _feita = p;
      _caixas = [
        for (final b in p.blocos)
          if (b.frases.isNotEmpty) _Caixa(b.area, _ajustar(p.textoDe(b), b)),
      ];
    }
    return _caixas;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.tradutor, widget.modo]),
    builder: (context, _) {
      final p = widget.tradutor.paginas[widget.pagina.pageNumber - 1];
      if (p == null || widget.modo.value != ModoTraducao.sobrePagina) return const SizedBox.shrink();
      return IgnorePointer(
        child: LayoutBuilder(
          builder: (context, c) => RepaintBoundary(
            child: CustomPaint(
              size: c.biggest,
              painter: _PintorTraducao(_caixasDe(p), c.maxWidth / widget.pagina.width),
            ),
          ),
        ),
      );
    },
  );
}

class _PintorTraducao extends CustomPainter {
  _PintorTraducao(this.caixas, this.escala);

  final List<_Caixa> caixas;
  final double escala;

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..scale(escala);
    final fundo = Paint()..color = Colors.white;
    for (final c in caixas) {
      canvas.drawRect(c.area.inflate(1), fundo);
    }
    for (final c in caixas) {
      c.texto.paint(canvas, c.area.topLeft);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PintorTraducao old) => !identical(old.caixas, caixas) || old.escala != escala;
}

/// Barrinha flutuante da tradução sobre a página: andamento, pausa, refazer a página e fechar.
class BarraTraducao extends StatelessWidget {
  const BarraTraducao({
    super.key,
    required this.tradutor,
    required this.pagina,
    required this.aoRetomar,
    required this.aoFechar,
  });

  final TradutorDocumento tradutor;
  final int pagina;
  final VoidCallback aoRetomar;
  final VoidCallback aoFechar;

  @override
  Widget build(BuildContext context) {
    final t = tradutor;
    final pronta = t.paginas.containsKey(pagina);
    final andamento = t.total > 0 && t.prontas < t.total ? ' (${t.prontas}/${t.total})' : '';
    final aviso =
        t.erro ??
        (t.semTexto.contains(pagina)
            ? 'Esta página não tem texto selecionável'
            : pronta
            ? 'Traduzido para o português$andamento'
            : t.ativo
            ? 'Traduzindo para o português$andamento'
            : 'Tradução pausada$andamento');
    return Material(
      elevation: 4,
      shape: const StadiumBorder(),
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.translate, size: 18),
            const SizedBox(width: 8),
            Flexible(child: Text(aviso, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 4),
            if (t.ativo)
              IconButton(tooltip: 'Pausar a tradução', icon: const Icon(Icons.pause), onPressed: t.parar)
            else if (t.prontas < t.total || t.total == 0)
              IconButton(
                tooltip: 'Continuar traduzindo o documento',
                icon: const Icon(Icons.play_arrow),
                onPressed: aoRetomar,
              ),
            if (pronta)
              IconButton(
                tooltip: 'Traduzir esta página de novo',
                icon: const Icon(Icons.refresh),
                onPressed: t.traduzindo(pagina) ? null : () => t.refazer(pagina),
              ),
            IconButton(tooltip: 'Fechar a tradução', icon: const Icon(Icons.close), onPressed: aoFechar),
          ],
        ),
      ),
    );
  }
}
