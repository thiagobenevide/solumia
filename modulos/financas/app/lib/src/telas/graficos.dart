import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../formato.dart';

/// Paleta para categorias sem cor definida.
const paleta = [
  Color(0xFF5C6BC0), Color(0xFF26A69A), Color(0xFFFFA726), Color(0xFFEF5350), Color(0xFFAB47BC),
  Color(0xFF29B6F6), Color(0xFF8D6E63), Color(0xFFFFCA28), Color(0xFF66BB6A), Color(0xFFEC407A),
];

Color corDe(String? hex, int i) => corHex(hex) ?? paleta[i % paleta.length];

/// Fluxo de caixa mensal: barras de receitas e despesas (+ investimentos) lado a lado e a linha do saldo.
class GraficoFluxo extends StatelessWidget {
  const GraficoFluxo(this.meses, {super.key, this.altura = 220});

  final List<Doc> meses;
  final double altura;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      spacing: 8,
      children: [
        SizedBox(
          height: altura,
          width: double.infinity,
          child: CustomPaint(painter: _PintorFluxo(meses, cs, Theme.of(context).textTheme.bodySmall!)),
        ),
        Wrap(
          spacing: 16,
          children: [
            _Legenda(Colors.green.shade400, 'Receitas'),
            _Legenda(cs.error, 'Despesas'),
            _Legenda(Colors.teal.shade300, 'Investimentos'),
            _Legenda(cs.primary, 'Saldo'),
          ],
        ),
      ],
    );
  }
}

class _Legenda extends StatelessWidget {
  const _Legenda(this.cor, this.texto);

  final Color cor;
  final String texto;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: 4,
    children: [
      Container(width: 10, height: 10, decoration: BoxDecoration(color: cor, borderRadius: BorderRadius.circular(2))),
      Text(texto, style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}

class _PintorFluxo extends CustomPainter {
  _PintorFluxo(this.meses, this.cs, this.estilo);

  final List<Doc> meses;
  final ColorScheme cs;
  final TextStyle estilo;

  @override
  void paint(Canvas canvas, Size size) {
    if (meses.isEmpty) return;
    const baseRotulo = 18.0;
    final h = size.height - baseRotulo;
    final maximo = meses.fold<double>(1, (m, x) => math.max(m, math.max(n(x['receitas']), n(x['despesas']) + n(x['investimentos']))));
    final minSaldo = meses.fold<double>(0, (m, x) => math.min(m, n(x['saldo'])));
    final escala = h / (maximo - minSaldo);
    final zero = h + minSaldo * escala;
    final largura = size.width / meses.length;
    final barra = math.min(18.0, largura * 0.3);
    final grade = Paint()..color = cs.outlineVariant.withValues(alpha: 0.4);
    canvas.drawLine(Offset(0, zero), Offset(size.width, zero), grade);

    final pontos = <Offset>[];
    for (var i = 0; i < meses.length; i++) {
      final m = meses[i];
      final cx = largura * i + largura / 2;
      final rec = n(m['receitas']) * escala;
      final des = n(m['despesas']) * escala;
      final inv = n(m['investimentos']) * escala;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(cx - barra - 1, zero - rec, barra, rec), const Radius.circular(3)),
        Paint()..color = Colors.green.shade400,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(cx + 1, zero - des, barra, des), const Radius.circular(3)),
        Paint()..color = cs.error,
      );
      if (inv > 0) {
        canvas.drawRect(Rect.fromLTWH(cx + 1, zero - des - inv, barra, inv), Paint()..color = Colors.teal.shade300);
      }
      pontos.add(Offset(cx, zero - n(m['saldo']) * escala));
      final tp = TextPainter(text: TextSpan(text: mesCurto(m['mes'] as String), style: estilo), textDirection: TextDirection.ltr)
        ..layout();
      tp.paint(canvas, Offset(cx - tp.width / 2, size.height - tp.height));
    }
    final linha = Paint()
      ..color = cs.primary
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawPath(Path()..addPolygon(pontos, false), linha);
    for (final p in pontos) {
      canvas.drawCircle(p, 3, Paint()..color = cs.primary);
    }
  }

  @override
  bool shouldRepaint(_PintorFluxo old) => old.meses != meses;
}

/// Fatia de [Rosca].
typedef Fatia = ({String nome, double valor, Color cor});

/// Rosca com legenda (percentual de cada fatia).
class Rosca extends StatelessWidget {
  const Rosca(this.fatias, {super.key, this.centro, this.tamanho = 150});

  final List<Fatia> fatias;
  final String? centro;
  final double tamanho;

  @override
  Widget build(BuildContext context) {
    final total = fatias.fold<double>(0, (s, f) => s + f.valor);
    final legenda = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        for (final f in fatias.take(10))
          Row(
            spacing: 6,
            children: [
              Container(width: 10, height: 10, decoration: BoxDecoration(color: f.cor, shape: BoxShape.circle)),
              Expanded(child: Text(f.nome, overflow: TextOverflow.ellipsis)),
              Text(pct(total == 0 ? 0 : 100 * f.valor / total), style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
      ],
    );
    return LayoutBuilder(
      builder: (context, c) {
        final grafico = SizedBox(
          width: tamanho,
          height: tamanho,
          child: CustomPaint(
            painter: _PintorRosca(fatias, total, Theme.of(context).colorScheme.surfaceContainerHighest),
            child: Center(
              child: Text(centro ?? '', textAlign: TextAlign.center, style: Theme.of(context).textTheme.labelLarge),
            ),
          ),
        );
        if (c.maxWidth < 380) return Column(spacing: 12, children: [grafico, legenda]);
        return Row(spacing: 16, children: [grafico, Expanded(child: legenda)]);
      },
    );
  }
}

class _PintorRosca extends CustomPainter {
  _PintorRosca(this.fatias, this.total, this.fundo);

  final List<Fatia> fatias;
  final double total;
  final Color fundo;

  @override
  void paint(Canvas canvas, Size size) {
    final espessura = size.width * 0.16;
    final r = Rect.fromLTWH(espessura / 2, espessura / 2, size.width - espessura, size.height - espessura);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = espessura;
    if (total <= 0) {
      canvas.drawArc(r, 0, 2 * math.pi, false, p..color = fundo);
      return;
    }
    var inicio = -math.pi / 2;
    for (final f in fatias) {
      final ang = 2 * math.pi * f.valor / total;
      canvas.drawArc(r, inicio, math.max(ang - 0.02, 0.001), false, p..color = f.cor);
      inicio += ang;
    }
  }

  @override
  bool shouldRepaint(_PintorRosca old) => old.fatias != fatias;
}

/// Linha simples (projeção de saldo, cotação…) com o mínimo e o máximo marcados.
class GraficoLinha extends StatelessWidget {
  const GraficoLinha(this.pontos, {super.key, this.altura = 160});

  final List<({String rotulo, double valor})> pontos;
  final double altura;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: altura,
    width: double.infinity,
    child: CustomPaint(painter: _PintorLinha(pontos, Theme.of(context).colorScheme, Theme.of(context).textTheme.bodySmall!)),
  );
}

class _PintorLinha extends CustomPainter {
  _PintorLinha(this.pontos, this.cs, this.estilo);

  final List<({String rotulo, double valor})> pontos;
  final ColorScheme cs;
  final TextStyle estilo;

  @override
  void paint(Canvas canvas, Size size) {
    if (pontos.isEmpty) return;
    const margem = 16.0;
    final h = size.height - margem * 2;
    final vals = pontos.map((p) => p.valor);
    final lo = math.min(vals.reduce(math.min), 0.0);
    final hi = math.max(vals.reduce(math.max), lo + 1);
    double y(double v) => margem + h - (v - lo) / (hi - lo) * h;
    final passo = pontos.length > 1 ? size.width / (pontos.length - 1) : 0.0;
    final grade = Paint()..color = cs.outlineVariant.withValues(alpha: 0.5);
    canvas.drawLine(Offset(0, y(0)), Offset(size.width, y(0)), grade);
    final caminho = Path();
    for (var i = 0; i < pontos.length; i++) {
      final o = Offset(passo * i, y(pontos[i].valor));
      i == 0 ? caminho.moveTo(o.dx, o.dy) : caminho.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(
      caminho,
      Paint()
        ..color = cs.primary
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
    void rotulo(String t, Offset o) {
      final tp = TextPainter(text: TextSpan(text: t, style: estilo), textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, Offset((o.dx - tp.width / 2).clamp(0, size.width - tp.width), o.dy));
    }

    rotulo(pontos.first.rotulo, Offset(0, size.height - margem + 2));
    if (pontos.length > 1) rotulo(pontos.last.rotulo, Offset(size.width, size.height - margem + 2));
    final iMin = pontos.indexWhere((p) => p.valor == vals.reduce(math.min));
    rotulo(moeda(pontos[iMin].valor), Offset(passo * iMin, y(pontos[iMin].valor) + 4));
  }

  @override
  bool shouldRepaint(_PintorLinha old) => old.pontos != pontos;
}
