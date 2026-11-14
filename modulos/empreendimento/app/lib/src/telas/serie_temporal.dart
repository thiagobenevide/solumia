import 'package:flutter/material.dart';

/// Série temporal pequena (uma medida, um eixo): linha de 2 px, grade discreta, valor atual no título e
/// cruz com o valor do instante sob o ponteiro (mouse ou toque). Medidas de escalas diferentes viram
/// gráficos separados lado a lado, nunca dois eixos no mesmo.
class SerieTemporal extends StatefulWidget {
  const SerieTemporal({
    super.key,
    required this.titulo,
    required this.unidade,
    required this.pontos,
    this.maximo,
  });

  final String titulo;
  final String unidade;

  /// (segundos Unix, valor); valores nulos interrompem a linha.
  final List<(num, num?)> pontos;

  /// Teto fixo do eixo (ex.: 100 para %); sem ele, o maior valor da série.
  final double? maximo;

  @override
  State<SerieTemporal> createState() => _SerieTemporalState();
}

class _SerieTemporalState extends State<SerieTemporal> {
  double? _x;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final valores = widget.pontos.map((p) => p.$2).whereType<num>();
    final atual = widget.pontos.isEmpty ? null : widget.pontos.last.$2;
    final topo =
        widget.maximo ??
        (valores.isEmpty ? 1.0 : (valores.reduce((a, b) => a > b ? a : b) * 1.15).toDouble());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${widget.titulo}  ${atual == null ? '—' : '${atual.toStringAsFixed(atual < 10 ? 1 : 0)} ${widget.unidade}'}',
          style: t.textTheme.labelMedium,
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 90,
          child: MouseRegion(
            onHover: (e) => setState(() => _x = e.localPosition.dx),
            onExit: (_) => setState(() => _x = null),
            child: GestureDetector(
              onPanUpdate: (e) => setState(() => _x = e.localPosition.dx),
              onPanEnd: (_) => setState(() => _x = null),
              child: CustomPaint(
                size: Size.infinite,
                painter: _Pintor(
                  pontos: widget.pontos,
                  topo: topo <= 0 ? 1 : topo,
                  cor: t.colorScheme.primary,
                  grade: t.colorScheme.outlineVariant.withValues(alpha: 0.4),
                  texto: t.textTheme.bodySmall!.copyWith(color: t.colorScheme.onSurfaceVariant),
                  fundoRotulo: t.colorScheme.surfaceContainerHighest,
                  unidade: widget.unidade,
                  ponteiro: _x,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Pintor extends CustomPainter {
  _Pintor({
    required this.pontos,
    required this.topo,
    required this.cor,
    required this.grade,
    required this.texto,
    required this.fundoRotulo,
    required this.unidade,
    required this.ponteiro,
  });

  final List<(num, num?)> pontos;
  final double topo;
  final Color cor;
  final Color grade;
  final TextStyle texto;
  final Color fundoRotulo;
  final String unidade;
  final double? ponteiro;

  @override
  void paint(Canvas canvas, Size size) {
    final linhaGrade = Paint()
      ..color = grade
      ..strokeWidth = 1;
    for (final f in [0.0, 0.5, 1.0]) {
      canvas.drawLine(Offset(0, size.height * f), Offset(size.width, size.height * f), linhaGrade);
    }
    _rotulo(canvas, topo.toStringAsFixed(0), const Offset(2, 0));
    if (pontos.length < 2) return;
    final t0 = pontos.first.$1.toDouble(), t1 = pontos.last.$1.toDouble();
    final span = (t1 - t0) <= 0 ? 1.0 : t1 - t0;
    Offset pos((num, num?) p) => Offset(
      (p.$1 - t0) / span * size.width,
      size.height - ((p.$2 ?? 0) / topo).clamp(0.0, 1.0) * size.height,
    );
    final caminho = Path();
    var aberto = false;
    for (final p in pontos) {
      if (p.$2 == null) {
        aberto = false;
        continue;
      }
      final o = pos(p);
      aberto ? caminho.lineTo(o.dx, o.dy) : caminho.moveTo(o.dx, o.dy);
      aberto = true;
    }
    canvas.drawPath(
      caminho,
      Paint()
        ..color = cor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
    final x = ponteiro;
    if (x == null) return;
    final alvo = t0 + (x / size.width).clamp(0.0, 1.0) * span;
    final p = pontos.reduce((a, b) => (a.$1 - alvo).abs() < (b.$1 - alvo).abs() ? a : b);
    if (p.$2 == null) return;
    final o = pos(p);
    canvas.drawLine(
      Offset(o.dx, 0),
      Offset(o.dx, size.height),
      linhaGrade..color = texto.color!.withValues(alpha: 0.5),
    );
    canvas.drawCircle(o, 4, Paint()..color = cor);
    final quando = DateTime.fromMillisecondsSinceEpoch((p.$1 * 1000).round());
    final rotulo =
        '${p.$2!.toStringAsFixed(1)} $unidade · '
        '${quando.hour.toString().padLeft(2, '0')}:${quando.minute.toString().padLeft(2, '0')}:'
        '${quando.second.toString().padLeft(2, '0')}';
    _rotulo(canvas, rotulo, Offset((o.dx + 8).clamp(0, size.width - 150), 2), fundo: true);
  }

  void _rotulo(Canvas canvas, String s, Offset o, {bool fundo = false}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: texto),
      textDirection: TextDirection.ltr,
    )..layout();
    if (fundo) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(o.dx - 4, o.dy - 2, tp.width + 8, tp.height + 4),
          const Radius.circular(4),
        ),
        Paint()..color = fundoRotulo,
      );
    }
    tp.paint(canvas, o);
  }

  @override
  bool shouldRepaint(_Pintor antigo) =>
      antigo.pontos != pontos || antigo.ponteiro != ponteiro || antigo.topo != topo;
}
