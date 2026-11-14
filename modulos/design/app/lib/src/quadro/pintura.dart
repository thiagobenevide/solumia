import 'dart:math';
import 'dart:ui' show PointMode;

import 'package:flutter/material.dart';

import '../modelos.dart';
import 'entrada.dart';
import 'imagens.dart';

/// No quadro escuro (projeção), tinta quase preta vira branca: o mesmo desenho serve aos dois.
Color tinta(Color c, bool escuro) => escuro && c.computeLuminance() < 0.08 ? const Color(0xFFF5F5F5) : c;

Color corDoFundo(bool escuro) => escuro ? const Color(0xFF1B1F1D) : const Color(0xFFFDFDFB);

/// Desenha [e] no canvas já transformado para o mundo.
void pintarElemento(Canvas canvas, Elemento e, {bool escuro = false}) {
  switch (e) {
    case Traco():
      _pintarTraco(canvas, e, escuro);
    case Forma():
      _pintarForma(canvas, e, escuro);
    case Texto():
      pintorDeTexto(e, escuro).paint(canvas, e.posicao);
    case NoFluxo():
      _pintarNo(canvas, e, escuro);
    case Ligacao():
      _pintarLigacao(canvas, e, escuro);
    case Tabela():
      pintarTabela(canvas, e, escuro);
    case Imagem():
      _pintarImagem(canvas, e, escuro);
  }
}

/// Enquanto a imagem não chegou do servidor, um quadro cinza com um X marca o lugar.
void _pintarImagem(Canvas canvas, Imagem e, bool escuro) {
  final r = e.retangulo;
  final img = CacheImagens.instancia.obter(e.imagem);
  if (img != null) {
    final origem = Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
    canvas.drawImageRect(img, origem, r, Paint()..filterQuality = FilterQuality.medium);
    return;
  }
  final cinza = Paint()
    ..color = escuro ? const Color(0x33FFFFFF) : const Color(0x22000000)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5;
  canvas
    ..drawRect(r, cinza)
    ..drawLine(r.topLeft, r.bottomRight, cinza)
    ..drawLine(r.topRight, r.bottomLeft, cinza);
}

/// Fundo padrão da linha de cabeçalho da tabela.
const fundoCabecalho = Color(0xFFECEFF1);

void pintarTabela(Canvas canvas, Tabela t, bool escuro) {
  final grade = Paint()
    ..color = tinta(t.cor, escuro)
    ..style = PaintingStyle.stroke
    ..strokeWidth = max(1, t.tamanho / 16);
  for (var l = 0; l < t.linhas; l++) {
    final cabecalho = t.cabecalho && l == 0;
    for (var c = 0; c < t.colunas; c++) {
      final r = t.celula(l, c), cel = t.celulas[l][c];
      final fundo = cel.fundo ?? (cabecalho ? fundoCabecalho : null);
      if (fundo != null) {
        canvas.drawRect(r, Paint()..color = escuro && cel.fundo == null ? const Color(0xFF2E3A40) : fundo);
      }
      if (cel.texto.isEmpty) continue;
      final folga = t.tamanho * 0.5;
      final texto = TextPainter(
        text: textoFormatado(
          cel.texto,
          TextStyle(
            color: tinta(cel.corTexto ?? const Color(0xFF111111), escuro),
            fontSize: t.tamanho,
            height: 1.25,
            fontWeight: cel.negrito || cabecalho ? FontWeight.bold : null,
          ),
          escuro,
        ),
        textAlign: const [TextAlign.left, TextAlign.center, TextAlign.right][cel.alinhamento.clamp(0, 2)],
        textDirection: TextDirection.ltr,
        ellipsis: '…',
      )..layout(minWidth: max(0, r.width - folga * 2), maxWidth: max(0, r.width - folga * 2));
      canvas.save();
      canvas.clipRect(r);
      texto.paint(canvas, Offset(r.left + folga, r.center.dy - texto.height / 2));
      canvas.restore();
    }
  }
  for (var l = 0; l < t.linhas; l++) {
    for (var c = 0; c < t.colunas; c++) {
      canvas.drawRect(t.celula(l, c), grade);
    }
  }
}

void _pintarTraco(Canvas canvas, Traco t, bool escuro) {
  if (t.pontos.isEmpty) return;
  final cor = tinta(t.cor, escuro);
  if (t.pincel == Pincel.marcador) {
    canvas.drawPath(
      caminhoSuave([for (final p in t.pontos) p.offset]),
      Paint()
        ..color = cor.withValues(alpha: 0.45)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = t.espessura,
    );
    return;
  }
  final pincel = Paint()
    ..color = cor
    ..strokeCap = StrokeCap.round;
  if (t.pontos.length == 1) {
    canvas.drawCircle(t.pontos.first.offset, _largura(t, 0) / 2, pincel);
    return;
  }
  pincel.style = PaintingStyle.stroke;
  for (var i = 1; i < t.pontos.length; i++) {
    pincel.strokeWidth = _largura(t, i);
    canvas.drawLine(t.pontos[i - 1].offset, t.pontos[i].offset, pincel);
  }
}

/// A pressão engrossa a caneta; a média com o ponto anterior evita degraus entre segmentos.
double _largura(Traco t, int i) {
  final p = i == 0 ? t.pontos[0].p : (t.pontos[i].p + t.pontos[i - 1].p) / 2;
  return t.espessura * (0.35 + 0.95 * p);
}

Path caminhoSuave(List<Offset> pontos) {
  final caminho = Path()..moveTo(pontos.first.dx, pontos.first.dy);
  if (pontos.length == 1) return caminho..lineTo(pontos.first.dx + 0.01, pontos.first.dy);
  for (var i = 1; i < pontos.length - 1; i++) {
    final meio = (pontos[i] + pontos[i + 1]) / 2;
    caminho.quadraticBezierTo(pontos[i].dx, pontos[i].dy, meio.dx, meio.dy);
  }
  return caminho..lineTo(pontos.last.dx, pontos.last.dy);
}

void _pintarForma(Canvas canvas, Forma f, bool escuro) {
  final pincel = Paint()
    ..color = tinta(f.cor, escuro)
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..strokeWidth = f.espessura;
  final r = Rect.fromPoints(f.a, f.b);
  switch (f.forma) {
    case TipoForma.reta:
      canvas.drawLine(f.a, f.b, pincel);
    case TipoForma.seta:
      canvas.drawLine(f.a, f.b, pincel);
      final d = f.b - f.a;
      if (d.distance < 1) return;
      final ponta = max(10.0, f.espessura * 4);
      for (final lado in [-1, 1]) {
        final angulo = d.direction + pi + lado * pi / 7;
        canvas.drawLine(f.b, f.b + Offset.fromDirection(angulo, ponta), pincel);
      }
    case TipoForma.retangulo:
      canvas.drawRect(r, pincel);
    case TipoForma.elipse:
      canvas.drawOval(r, pincel);
  }
}

/// Contorno do bloco pelo tipo: início/fim arredondados, processo com cantos suaves, retângulo
/// reto, círculo, decisão em losango, entrada/saída inclinada, documento com a base ondulada,
/// banco de dados em cilindro, nota com o canto dobrado, hexágono e contêiner.
Path contornoDoNo(NoFluxo n) {
  final r = n.retangulo;
  switch (n.tipo) {
    case TipoNo.inicio || TipoNo.fim:
      return Path()..addRRect(RRect.fromRectAndRadius(r, Radius.circular(r.shortestSide / 2)));
    case TipoNo.decisao:
      return Path()
        ..moveTo(r.center.dx, r.top)
        ..lineTo(r.right, r.center.dy)
        ..lineTo(r.center.dx, r.bottom)
        ..lineTo(r.left, r.center.dy)
        ..close();
    case TipoNo.dado:
      final d = r.height * 0.3;
      return Path()
        ..moveTo(r.left + d, r.top)
        ..lineTo(r.right, r.top)
        ..lineTo(r.right - d, r.bottom)
        ..lineTo(r.left, r.bottom)
        ..close();
    case TipoNo.processo || TipoNo.subprocesso:
      return Path()..addRRect(RRect.fromRectAndRadius(r, const Radius.circular(6)));
    case TipoNo.quadrado || TipoNo.container:
      return Path()..addRect(r);
    case TipoNo.circulo:
      return Path()..addOval(r);
    case TipoNo.documento:
      final onda = r.height * 0.12;
      return Path()
        ..moveTo(r.left, r.top)
        ..lineTo(r.right, r.top)
        ..lineTo(r.right, r.bottom - onda)
        ..cubicTo(r.right - r.width * 0.25, r.bottom - onda * 2.6, r.left + r.width * 0.45, r.bottom + onda * 0.8, r.left, r.bottom - onda)
        ..close();
    case TipoNo.banco:
      final e = min(r.height * 0.15, 14.0);
      return Path()
        ..moveTo(r.left, r.top + e)
        ..arcToPoint(Offset(r.right, r.top + e), radius: Radius.elliptical(r.width / 2, e))
        ..lineTo(r.right, r.bottom - e)
        ..arcToPoint(Offset(r.left, r.bottom - e), radius: Radius.elliptical(r.width / 2, e))
        ..close();
    case TipoNo.nota:
      final c = min(16.0, r.shortestSide * 0.3);
      return Path()
        ..moveTo(r.left, r.top)
        ..lineTo(r.right - c, r.top)
        ..lineTo(r.right, r.top + c)
        ..lineTo(r.right, r.bottom)
        ..lineTo(r.left, r.bottom)
        ..close();
    case TipoNo.hexagono:
      final d = min(r.width * 0.2, r.height * 0.5);
      return Path()
        ..moveTo(r.left + d, r.top)
        ..lineTo(r.right - d, r.top)
        ..lineTo(r.right, r.center.dy)
        ..lineTo(r.right - d, r.bottom)
        ..lineTo(r.left + d, r.bottom)
        ..lineTo(r.left, r.center.dy)
        ..close();
  }
}

void _pintarNo(Canvas canvas, NoFluxo n, bool escuro) {
  final cor = tinta(n.cor, escuro);
  final contorno = contornoDoNo(n);
  final r = n.retangulo;
  // Fundo do draw.io quando veio; senão, a borda bem clara. Contêiner fica quase transparente.
  final fundo = n.fundo == null
      ? cor.withValues(alpha: n.tipo == TipoNo.container ? 0.04 : (escuro ? 0.22 : 0.12))
      : (escuro ? Color.lerp(n.fundo, const Color(0xFF1B1F1D), 0.55)! : n.fundo!);
  canvas.drawPath(contorno, Paint()..color = fundo);
  final linha = Paint()
    ..color = cor
    ..style = PaintingStyle.stroke
    ..strokeWidth = n.tipo == TipoNo.container ? 1.2 : 2
    ..strokeJoin = StrokeJoin.round;
  canvas.drawPath(contorno, linha);
  switch (n.tipo) {
    case TipoNo.subprocesso:
      canvas.drawLine(Offset(r.left + 10, r.top), Offset(r.left + 10, r.bottom), linha);
      canvas.drawLine(Offset(r.right - 10, r.top), Offset(r.right - 10, r.bottom), linha);
    case TipoNo.banco:
      final e = min(r.height * 0.15, 14.0);
      canvas.drawArc(Rect.fromLTWH(r.left, r.top, r.width, e * 2), 0, pi, false, linha);
    case TipoNo.nota:
      final c = min(16.0, r.shortestSide * 0.3);
      canvas.drawPath(
        Path()
          ..moveTo(r.right - c, r.top)
          ..lineTo(r.right - c, r.top + c)
          ..lineTo(r.right, r.top + c),
        linha,
      );
    case TipoNo.container:
      canvas.drawLine(Offset(r.left, r.top + NoFluxo.alturaTitulo), Offset(r.right, r.top + NoFluxo.alturaTitulo), linha);
    default:
  }
  final corTexto = n.corTexto != null ? tinta(n.corTexto!, escuro) : tinta(const Color(0xFF111111), escuro);
  final estilo = TextStyle(
    color: corTexto,
    fontSize: n.tipo == TipoNo.container ? 14 : 15,
    height: 1.2,
    fontWeight: n.tipo == TipoNo.container ? FontWeight.w600 : null,
  );
  if (n.tipo == TipoNo.container) {
    // Título do contêiner/raia no topo, à esquerda (como o swimlane do draw.io).
    final t = TextPainter(
      text: textoFormatado(n.texto, estilo, escuro),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: max(20, r.width - 16));
    t.paint(canvas, Offset(r.left + 8, r.top + (NoFluxo.alturaTitulo - t.height) / 2));
    return;
  }
  // Losango, círculo e hexágono têm menos área útil: o texto fica mais estreito.
  final estreito = n.tipo == TipoNo.decisao || n.tipo == TipoNo.circulo || n.tipo == TipoNo.hexagono;
  final largura = n.esquerda ? r.width - 16 : r.width * (estreito ? 0.62 : 0.82);
  final texto = TextPainter(
    text: textoFormatado(n.texto, estilo, escuro),
    textAlign: n.tipo == TipoNo.nota || n.esquerda ? TextAlign.left : TextAlign.center,
    textDirection: TextDirection.ltr,
    maxLines: max(1, (r.height * 0.9 / 18).floor()),
    ellipsis: '…',
  )..layout(maxWidth: max(20, largura));
  final pos = switch (n) {
    _ when n.tipo == TipoNo.nota => Offset(r.left + 8, r.top + 8),
    _ when n.esquerda => Offset(r.left + 8, r.center.dy - texto.height / 2),
    _ => r.center - Offset(texto.width / 2, texto.height / 2),
  };
  texto.paint(canvas, pos);
}

/// Trechos de [traco] com [vao] entre eles (traço quase zero + ponta redonda = pontilhado).
void _tracejado(Canvas canvas, Offset a, Offset b, Paint pincel, {double traco = 8, double vao = 8}) {
  final d = b - a, total = d.distance;
  if (total == 0) return;
  final u = d / total;
  for (var t = 0.0; t < total; t += traco + vao) {
    canvas.drawLine(a + u * t, a + u * min(t + traco, total), pincel);
  }
}

void _pintarLigacao(Canvas canvas, Ligacao l, bool escuro) {
  final cor = tinta(l.cor, escuro);
  final pincel = Paint()
    ..color = cor
    ..style = PaintingStyle.stroke
    ..strokeWidth = l.espessura
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final c = l.caminho;
  if (l.linha == TipoLinha.continua) {
    final traco = Path()..moveTo(c.first.dx, c.first.dy);
    for (final p in c.skip(1)) {
      traco.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(traco, pincel);
  } else {
    final pontilhada = l.linha == TipoLinha.pontilhada;
    for (var i = 0; i < c.length - 1; i++) {
      _tracejado(
        canvas,
        c[i],
        c[i + 1],
        pincel,
        traco: pontilhada ? 0.01 : 4 + l.espessura * 2,
        vao: pontilhada ? l.espessura * 2.5 + 2 : 4 + l.espessura * 2,
      );
    }
  }
  final fim = c.last - c[c.length - 2], inicio = c.first - c[1];
  if (fim.distance > 1) _pintarPonta(canvas, l.b, fim.direction, l.pontaFim, cor, l.espessura, escuro);
  if (inicio.distance > 1) _pintarPonta(canvas, l.a, inicio.direction, l.pontaInicio, cor, l.espessura, escuro);
  if (l.rotulo.isEmpty) return;
  final texto = TextPainter(
    text: TextSpan(
      text: l.rotulo,
      style: TextStyle(color: cor, fontSize: 13, fontWeight: FontWeight.w600),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final caixa = Rect.fromCenter(center: l.meio, width: texto.width + 10, height: texto.height + 4);
  canvas.drawRRect(RRect.fromRectAndRadius(caixa, const Radius.circular(4)), Paint()..color = corDoFundo(escuro));
  texto.paint(canvas, caixa.topLeft + const Offset(5, 2));
}

/// Figura na ponta [p] da seta, apontando no ângulo [dir]; as vazadas pintam o fundo por dentro.
void _pintarPonta(Canvas canvas, Offset p, double dir, TipoPonta tipo, Color cor, double espessura, bool escuro) {
  if (tipo == TipoPonta.nenhuma) return;
  final t = 10 + espessura * 1.5;
  Offset em(double ang, double r) => p + Offset(cos(dir + ang) * r, sin(dir + ang) * r);
  final cheio = Paint()..color = cor;
  final contorno = Paint()
    ..color = cor
    ..style = PaintingStyle.stroke
    ..strokeWidth = max(1.5, espessura * 0.8)
    ..strokeJoin = StrokeJoin.round
    ..strokeCap = StrokeCap.round;
  final vazio = Paint()..color = corDoFundo(escuro);
  switch (tipo) {
    case TipoPonta.seta || TipoPonta.setaVazada:
      final f = Path()
        ..moveTo(p.dx, p.dy)
        ..lineTo(em(pi - pi / 8, t).dx, em(pi - pi / 8, t).dy)
        ..lineTo(em(pi + pi / 8, t).dx, em(pi + pi / 8, t).dy)
        ..close();
      if (tipo == TipoPonta.seta) {
        canvas.drawPath(f, cheio);
      } else {
        canvas.drawPath(f, vazio);
        canvas.drawPath(f, contorno);
      }
    case TipoPonta.aberta:
      canvas.drawLine(p, em(pi - pi / 7, t), contorno);
      canvas.drawLine(p, em(pi + pi / 7, t), contorno);
    case TipoPonta.circulo || TipoPonta.circuloVazado:
      final r = t * 0.4, centro = em(pi, r);
      if (tipo == TipoPonta.circulo) {
        canvas.drawCircle(centro, r, cheio);
      } else {
        canvas.drawCircle(centro, r, vazio);
        canvas.drawCircle(centro, r, contorno);
      }
    case TipoPonta.losango || TipoPonta.losangoVazado:
      final meio = em(pi, t * 0.6), lado = t * 0.35;
      final f = Path()
        ..moveTo(p.dx, p.dy)
        ..lineTo(meio.dx + cos(dir + pi / 2) * lado, meio.dy + sin(dir + pi / 2) * lado)
        ..lineTo(em(pi, t * 1.2).dx, em(pi, t * 1.2).dy)
        ..lineTo(meio.dx + cos(dir - pi / 2) * lado, meio.dy + sin(dir - pi / 2) * lado)
        ..close();
      if (tipo == TipoPonta.losango) {
        canvas.drawPath(f, cheio);
      } else {
        canvas.drawPath(f, vazio);
        canvas.drawPath(f, contorno);
      }
    case TipoPonta.nenhuma:
  }
}

TextPainter pintorDeTexto(Texto t, bool escuro) => TextPainter(
  text: textoFormatado(t.texto, TextStyle(color: tinta(t.cor, escuro), fontSize: t.tamanho, height: 1.25), escuro),
  textDirection: TextDirection.ltr,
)..layout();

final _marcas = RegExp(r'(\*\*|__|==|\*)');

/// Marcação leve dentro do texto: `**negrito**`, `*itálico*`, `__sublinhado__` e `==marcador==`
/// (fundo amarelo). Marca sem par fica como texto.
TextSpan textoFormatado(String texto, TextStyle base, bool escuro) {
  final abertas = <String>{};
  final pedacos = <TextSpan>[];
  var resto = texto;
  // Só conta como marca a que tem par mais adiante; senão vira texto comum.
  while (resto.isNotEmpty) {
    final m = _marcas.firstMatch(resto);
    if (m == null) {
      pedacos.add(TextSpan(text: resto, style: _estilo(base, abertas, escuro)));
      break;
    }
    final marca = m.group(0)!;
    final fecha = abertas.contains(marca) || resto.indexOf(marca, m.end) >= 0;
    if (m.start > 0) pedacos.add(TextSpan(text: resto.substring(0, m.start), style: _estilo(base, abertas, escuro)));
    if (fecha) {
      abertas.contains(marca) ? abertas.remove(marca) : abertas.add(marca);
    } else {
      pedacos.add(TextSpan(text: marca, style: _estilo(base, abertas, escuro)));
    }
    resto = resto.substring(m.end);
  }
  return TextSpan(style: base, children: pedacos);
}

TextStyle _estilo(TextStyle base, Set<String> marcas, bool escuro) => base.copyWith(
  fontWeight: marcas.contains('**') ? FontWeight.bold : null,
  fontStyle: marcas.contains('*') ? FontStyle.italic : null,
  decoration: marcas.contains('__') ? TextDecoration.underline : null,
  backgroundColor: marcas.contains('==') ? const Color(0xFFFFE066).withValues(alpha: escuro ? 0.45 : 0.9) : null,
  color: marcas.contains('==') && !escuro ? const Color(0xFF111111) : null,
);

/// Texto sem as marcas (para medir e para o título).
String semMarcas(String texto) => texto.replaceAll(_marcas, '');

/// Fundo (pontos, grade, linhas) desenhado na tela, acompanhando a câmera.
void pintarFundo(Canvas canvas, Size tamanho, Fundo fundo, Camera camera, bool escuro) {
  canvas.drawRect(Offset.zero & tamanho, Paint()..color = corDoFundo(escuro));
  if (fundo == Fundo.liso) return;
  var passo = 32 * camera.escala;
  while (passo < 12) {
    passo *= 4; // longe demais: espaça a grade para não virar borrão
  }
  final cor = (escuro ? Colors.white : Colors.black).withValues(alpha: fundo == Fundo.pontos ? 0.22 : 0.08);
  final pincel = Paint()
    ..color = cor
    ..strokeWidth = fundo == Fundo.pontos ? max(1.5, camera.escala * 1.5) : 1
    ..strokeCap = StrokeCap.round;
  final x0 = camera.deslocamento.dx % passo, y0 = camera.deslocamento.dy % passo;
  switch (fundo) {
    case Fundo.pontos:
      final pontos = <Offset>[
        for (var x = x0; x < tamanho.width; x += passo)
          for (var y = y0; y < tamanho.height; y += passo) Offset(x, y),
      ];
      canvas.drawPoints(PointMode.points, pontos, pincel);
    case Fundo.grade:
      for (var x = x0; x < tamanho.width; x += passo) {
        canvas.drawLine(Offset(x, 0), Offset(x, tamanho.height), pincel);
      }
      for (var y = y0; y < tamanho.height; y += passo) {
        canvas.drawLine(Offset(0, y), Offset(tamanho.width, y), pincel);
      }
    case Fundo.linhas:
      for (var y = y0; y < tamanho.height; y += passo) {
        canvas.drawLine(Offset(0, y), Offset(tamanho.width, y), pincel);
      }
    case Fundo.liso:
      break;
  }
}

/// Caderno: a mesa em volta e a folha ([papel], de (0,0) a largura × altura no mundo) com a pauta
/// dela, margem vermelha e a linha do cabeçalho, acompanhando a câmera.
void pintarPapel(Canvas canvas, Size tamanho, Papel papel, Camera camera, bool escuro) {
  canvas.drawRect(Offset.zero & tamanho, Paint()..color = escuro ? const Color(0xFF101312) : const Color(0xFFE4E6E3));
  final folha = Rect.fromPoints(camera.paraTela(Offset.zero), camera.paraTela(Offset(papel.largura, papel.altura)));
  canvas.drawRect(
    folha.shift(const Offset(0, 2)),
    Paint()
      ..color = Colors.black.withValues(alpha: 0.18)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
  );
  final cor = escuro ? Color.lerp(papel.cor, const Color(0xFF1B1F1D), 0.88)! : papel.cor;
  canvas.drawRect(folha, Paint()..color = cor);
  final passo = papel.espaco * camera.escala;
  if (passo < 4) return; // longe demais: a pauta vira borrão
  final tinta = escuro ? Colors.white : const Color(0xFF3A5A8C);
  canvas
    ..save()
    ..clipRect(folha);
  final topo = folha.top + (papel.margem ? passo * 3 : passo);
  final esquerda = folha.left + papel.recuo * camera.escala;
  final pincel = Paint()
    ..color = tinta.withValues(alpha: papel.fundo == Fundo.pontos ? 0.35 : 0.22)
    ..strokeWidth = papel.fundo == Fundo.pontos ? max(1.6, camera.escala * 1.6) : max(0.6, camera.escala * 0.8)
    ..strokeCap = StrokeCap.round;
  // Começa no primeiro passo visível (zoom grande não percorre a folha inteira).
  double inicio(double base, double min) => base + max(0, ((min - base) / passo).floor()) * passo;
  final yMax = min(folha.bottom, tamanho.height), xMax = min(folha.right, tamanho.width);
  switch (papel.fundo) {
    case Fundo.linhas:
      for (var y = inicio(topo, 0); y < yMax; y += passo) {
        canvas.drawLine(Offset(max(folha.left, 0), y), Offset(xMax, y), pincel);
      }
    case Fundo.grade:
      for (var y = inicio(folha.top + passo, 0); y < yMax; y += passo) {
        canvas.drawLine(Offset(max(folha.left, 0), y), Offset(xMax, y), pincel);
      }
      for (var x = inicio(folha.left + passo, 0); x < xMax; x += passo) {
        canvas.drawLine(Offset(x, max(folha.top, 0)), Offset(x, yMax), pincel);
      }
    case Fundo.pontos:
      canvas.drawPoints(PointMode.points, [
        for (var x = inicio(folha.left + passo, 0); x < xMax; x += passo)
          for (var y = inicio(folha.top + passo, 0); y < yMax; y += passo) Offset(x, y),
      ], pincel);
    case Fundo.liso:
      break;
  }
  if (papel.margem) {
    final vermelho = Paint()
      ..color = const Color(0xFFE57373).withValues(alpha: 0.7)
      ..strokeWidth = max(0.8, camera.escala);
    canvas.drawLine(Offset(esquerda, folha.top), Offset(esquerda, folha.bottom), vermelho);
    if (papel.fundo != Fundo.linhas) {
      canvas.drawLine(Offset(folha.left, topo - passo), Offset(folha.right, topo - passo), vermelho);
    }
  }
  canvas.restore();
}

/// Quadro inteiro: fundo e elementos visíveis (o que está fora da tela nem é desenhado).
class PintorQuadro extends CustomPainter {
  PintorQuadro({
    required this.elementos,
    required this.camera,
    required this.fundo,
    required this.escuro,
    this.ocultos = const {},
    this.papel,
    required Listenable repintar,
  }) : super(repaint: repintar);

  final List<Elemento> elementos;
  final Camera camera;
  final Fundo fundo;
  final bool escuro;

  /// Caderno: folha no lugar do fundo infinito.
  final Papel? papel;

  /// Elementos sendo arrastados: o [PintorVivo] desenha a versão em movimento.
  final Set<String> ocultos;

  @override
  void paint(Canvas canvas, Size size) {
    papel == null ? pintarFundo(canvas, size, fundo, camera, escuro) : pintarPapel(canvas, size, papel!, camera, escuro);
    final visivel = Rect.fromPoints(camera.paraMundo(Offset.zero), camera.paraMundo(size.bottomRight(Offset.zero)));
    canvas
      ..save()
      ..translate(camera.deslocamento.dx, camera.deslocamento.dy)
      ..scale(camera.escala);
    for (final e in elementos) {
      if (!ocultos.contains(e.id) && e.limites.overlaps(visivel)) pintarElemento(canvas, e, escuro: escuro);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(PintorQuadro old) =>
      old.elementos != elementos || old.fundo != fundo || old.papel != papel || old.escuro != escuro || old.ocultos != ocultos;
}

List<Offset> cantos(Rect r) => [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft];

/// O que está sendo feito agora: elemento em construção, rastro do laser e o anel da borracha.
class PintorVivo extends CustomPainter {
  PintorVivo({
    required this.vivo,
    required this.laser,
    required this.camera,
    required this.escuro,
    this.borracha,
    required this.arrastados,
    required this.laco,
    required this.caixa,
    required Listenable repintar,
  }) : super(repaint: repintar);

  final Elemento? Function() vivo;
  final List<Elemento> Function() arrastados;
  final List<Offset> Function() laco;
  final Rect? Function() caixa;
  final List<(Offset, DateTime)> Function() laser;
  final Camera camera;
  final bool escuro;
  final (Offset, double)? Function()? borracha;

  static const duracaoLaser = Duration(milliseconds: 700);

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..translate(camera.deslocamento.dx, camera.deslocamento.dy)
      ..scale(camera.escala);
    final e = vivo();
    if (e != null) pintarElemento(canvas, e, escuro: escuro);
    for (final a in arrastados()) {
      pintarElemento(canvas, a, escuro: escuro);
    }
    canvas.restore();

    final destaque = Paint()
      ..color = const Color(0xFF2979FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final pontosLaco = laco();
    if (pontosLaco.length > 1) {
      canvas.drawPath(
        Path()..addPolygon([for (final p in pontosLaco) camera.paraTela(p)], true),
        Paint()..color = const Color(0x222979FF),
      );
      canvas.drawPath(Path()..addPolygon([for (final p in pontosLaco) camera.paraTela(p)], false), destaque);
    }
    final r = caixa();
    if (r != null) {
      final tela = Rect.fromPoints(camera.paraTela(r.topLeft), camera.paraTela(r.bottomRight));
      canvas.drawRect(tela, destaque);
      for (final canto in cantos(tela)) {
        canvas
          ..drawRect(Rect.fromCenter(center: canto, width: 12, height: 12), Paint()..color = Colors.white)
          ..drawRect(Rect.fromCenter(center: canto, width: 12, height: 12), destaque);
      }
    }

    final rastro = laser();
    final agora = DateTime.now();
    for (var i = 1; i < rastro.length; i++) {
      final idade = agora.difference(rastro[i].$2).inMilliseconds / duracaoLaser.inMilliseconds;
      if (idade >= 1) continue;
      canvas.drawLine(
        camera.paraTela(rastro[i - 1].$1),
        camera.paraTela(rastro[i].$1),
        Paint()
          ..color = const Color(0xFFFF1744).withValues(alpha: 1 - idade)
          ..strokeWidth = 6 * (1 - idade) + 2
          ..strokeCap = StrokeCap.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 3),
      );
    }

    final anel = borracha?.call();
    if (anel != null) {
      canvas.drawCircle(
        camera.paraTela(anel.$1),
        anel.$2 * camera.escala,
        Paint()
          ..color = (escuro ? Colors.white : Colors.black).withValues(alpha: 0.4)
          ..style = PaintingStyle.stroke,
      );
    }
  }

  @override
  bool shouldRepaint(PintorVivo old) => true;
}
