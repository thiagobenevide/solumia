import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../modelos.dart';
import '../telas/grafico.dart' show coresSinais;
import 'editor.dart';

/// Câmera da folha: tela = mundo (µm) × [escala] + [deslocamento]. 0,02 px/µm ≈ 25 px por grade.
class Camera {
  Offset deslocamento = const Offset(400, 300);
  double escala = 0.02;

  static const minimo = 0.002, maximo = 1.0;

  Offset paraMundo(Offset tela) => (tela - deslocamento) / escala;

  Offset paraTela(Offset mundo) => mundo * escala + deslocamento;

  void zoom(double fator, Offset foco) {
    final mundo = paraMundo(foco);
    escala = (escala * fator).clamp(minimo, maximo);
    deslocamento = foco - mundo * escala;
  }

  void enquadrar(Rect? area, Size tela) {
    if (area == null || area.isEmpty || tela.isEmpty) {
      escala = 0.02;
      deslocamento = tela.center(Offset.zero);
      return;
    }
    escala = min(tela.width / area.width, tela.height / area.height).clamp(minimo, 0.08) * 0.85;
    deslocamento = tela.center(Offset.zero) - area.center * escala;
  }
}

/// Cores do esquemático: escuro na tela, claro (papel) na exportação.
class Paleta {
  const Paleta({
    required this.fundo,
    required this.grade,
    required this.corpo,
    required this.preenchimento,
    required this.pino,
    required this.fio,
    required this.juncao,
    required this.rotulo,
    required this.texto,
    required this.campo,
    required this.selecao,
    required this.previa,
  });

  final Color fundo, grade, corpo, preenchimento, pino, fio, juncao, rotulo, texto, campo, selecao, previa;

  static const escura = Paleta(
    fundo: Color(0xFF14161A),
    grade: Color(0xFF3A3F47),
    corpo: Color(0xFFE0A050),
    preenchimento: Color(0x33E0A050),
    pino: Color(0xFFD06060),
    fio: Color(0xFF4CC38A),
    juncao: Color(0xFF4CC38A),
    rotulo: Color(0xFF6FA8FF),
    texto: Color(0xFFDADDE2),
    campo: Color(0xFFB0B6BF),
    selecao: Color(0xFFFFE066),
    previa: Color(0x99FFFFFF),
  );

  static const papel = Paleta(
    fundo: Color(0xFFFFFFFF),
    grade: Color(0xFFDDDDDD),
    corpo: Color(0xFF8A1C1C),
    preenchimento: Color(0x22F2D7A0),
    pino: Color(0xFF8A1C1C),
    fio: Color(0xFF1B6E3A),
    juncao: Color(0xFF1B6E3A),
    rotulo: Color(0xFF1B3F8A),
    texto: Color(0xFF222222),
    campo: Color(0xFF444444),
    selecao: Color(0xFFE08A00),
    previa: Color(0x88000000),
  );
}

const _traco = 160.0; // espessura das linhas em µm (~0,15 mm)

void _texto(Canvas canvas, String s, Offset pos, double tamanho, Color cor, {TextAlign alinhar = TextAlign.center}) {
  if (s.isEmpty) return;
  final tp = TextPainter(
    text: TextSpan(text: s, style: TextStyle(fontSize: tamanho, color: cor, fontFamily: 'monospace', height: 1)),
    textDirection: TextDirection.ltr,
  )..layout();
  final dx = switch (alinhar) {
    TextAlign.left => 0.0,
    TextAlign.right => -tp.width,
    _ => -tp.width / 2,
  };
  tp.paint(canvas, pos + Offset(dx, -tp.height / 2));
}

/// Desenha [s] em [pos] com rotação e espelho; textos ficam sempre de pé. [destaque] troca as cores.
void pintarSimbolo(
  Canvas canvas,
  Simbolo s, {
  required P pos,
  int rot = 0,
  bool espelho = false,
  String ref = '',
  String valor = '',
  required Paleta paleta,
  Color? destaque,
  bool campos = true,
}) {
  P mundo(P local) => pos + transformar(local, rot, espelho);
  final corpo = Paint()
    ..color = destaque ?? paleta.corpo
    ..strokeWidth = _traco
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final cheio = Paint()..color = destaque ?? paleta.corpo;

  canvas
    ..save()
    ..translate(pos.x.toDouble(), pos.y.toDouble())
    ..rotate(rot * pi / 180)
    ..scale(espelho ? -1 : 1, 1);
  for (final d in s.desenho) {
    switch (d['t']) {
      case 'linha':
        final pts = [for (final q in d['p'] as List) P.json(q as List).offset];
        final caminho = Path()..addPolygon(pts, d['fechada'] == true);
        canvas.drawPath(caminho, d['cheia'] == true ? cheio : corpo);
      case 'ret':
        final r = Rect.fromPoints(P.json(d['a'] as List).offset, P.json(d['b'] as List).offset);
        canvas.drawRect(r, d['cheio'] == true ? cheio : (Paint()..color = destaque?.withValues(alpha: 0.15) ?? paleta.preenchimento));
        canvas.drawRect(r, corpo);
      case 'circ':
        canvas.drawCircle(P.json(d['c'] as List).offset, (d['r'] as num).toDouble(), d['cheio'] == true ? cheio : corpo);
      case 'arco':
        final c = P.json(d['c'] as List).offset, r = (d['r'] as num).toDouble();
        canvas.drawArc(
          Rect.fromCircle(center: c, radius: r),
          (d['ini'] as num) * pi / 180,
          (d['var'] as num) * pi / 180,
          false,
          corpo,
        );
    }
  }
  final perna = Paint()
    ..color = destaque ?? paleta.pino
    ..strokeWidth = _traco
    ..strokeCap = StrokeCap.round;
  for (final p in s.pinos) {
    if (p.comp > 0 && !p.oculto) canvas.drawLine(p.pos.offset, p.fim.offset, perna);
  }
  canvas.restore();

  // Textos de pé, nas posições já transformadas.
  for (final d in s.desenho) {
    if (d['t'] == 'texto') _texto(canvas, d['s'] as String, mundo(P.json(d['p'] as List)).offset, 1100, destaque ?? paleta.corpo);
  }
  if (s.nomesPinos || s.numerosPinos) {
    for (final p in s.pinos) {
      if (p.oculto) continue;
      final dir = transformar(p.dir.vetor, rot, espelho);
      final fim = mundo(p.fim).offset;
      if (s.nomesPinos) {
        final alinhar = dir.x > 0 ? TextAlign.left : (dir.x < 0 ? TextAlign.right : TextAlign.center);
        final dentro = fim + Offset(dir.x * 400.0, dir.y * 900.0);
        _texto(canvas, p.nome, dentro, 900, destaque ?? paleta.campo, alinhar: alinhar);
      }
      if (s.numerosPinos) {
        final meio = (mundo(p.pos).offset + fim) / 2;
        final fora = dir.x != 0 ? const Offset(0, -500) : const Offset(-500, 0);
        _texto(canvas, p.n, meio + fora, 700, destaque ?? paleta.pino);
      }
    }
  }
  if (campos) {
    if (!s.alimentacao) _texto(canvas, ref, mundo(s.campoRef).offset, 1100, destaque ?? paleta.campo);
    _texto(canvas, valor, mundo(s.campoValor).offset, 1100, destaque ?? paleta.campo);
  }
}

/// Desenha a folha aberta do [editor] em coordenadas do mundo (o canvas já vem com a câmera aplicada).
void pintarFolha(Canvas canvas, Editor editor, Paleta paleta, {bool comSelecao = true}) {
  final ocultas = editor.ocultas;
  final sel = comSelecao ? editor.selecao : const <String>{};
  if (!ocultas.contains(Camada.fios)) {
    for (final f in editor.fios) {
      final cor = sel.contains(f.id) ? paleta.selecao : paleta.fio;
      canvas.drawPath(
        Path()..addPolygon([for (final p in f.pontos) p.offset], false),
        Paint()
          ..color = cor
          ..style = PaintingStyle.stroke
          ..strokeWidth = _traco * 1.2
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );
    }
    final bolinha = Paint()..color = paleta.juncao;
    for (final j in juncoes(editor.fios, editor.pinosDaFolha())) {
      canvas.drawCircle(j.offset, 420, bolinha);
    }
  }
  if (!ocultas.contains(Camada.componentes)) {
    for (final c in editor.componentes) {
      pintarSimbolo(
        canvas,
        editor.simboloDe(c),
        pos: c.pos,
        rot: c.rot,
        espelho: c.espelho,
        ref: c.ref,
        valor: c.valor,
        paleta: paleta,
        destaque: sel.contains(c.id) ? paleta.selecao : null,
        campos: !ocultas.contains(Camada.campos),
      );
    }
  }
  if (!ocultas.contains(Camada.rotulos)) {
    for (final r in editor.rotulos) {
      final cor = sel.contains(r.id) ? paleta.selecao : paleta.rotulo;
      final o = r.pos.offset;
      canvas.drawPath(
        Path()..addPolygon([o, o + const Offset(400, -700), o + Offset(r.nome.length * 800.0 + 600, -700)], false),
        Paint()
          ..color = cor
          ..style = PaintingStyle.stroke
          ..strokeWidth = _traco,
      );
      _texto(canvas, r.nome, o + const Offset(500, -1250), 1100, cor, alinhar: TextAlign.left);
    }
  }
  if (!ocultas.contains(Camada.sondas)) {
    for (final s in editor.sondas) {
      final i = editor.indiceSonda(s);
      final cor = coresSinais[i.clamp(0, coresSinais.length - 1)];
      final ponta = s.pos.offset, cabo = ponta + const Offset(1500, -1500);
      canvas
        ..drawLine(ponta, cabo, Paint()
          ..color = sel.contains(s.id) ? paleta.selecao : cor
          ..strokeWidth = 380
          ..strokeCap = StrokeCap.round)
        ..drawCircle(cabo, 650, Paint()..color = sel.contains(s.id) ? paleta.selecao : cor)
        ..drawCircle(ponta, 220, Paint()..color = paleta.fundo);
      final nome = s.tipo == 'v' ? 'V${i + 1}' : 'I ${s.ref}';
      final leitura = editor.leituras[s.id];
      _texto(canvas, leitura == null ? nome : '$nome = $leitura', cabo + const Offset(950, 0), 1100, paleta.texto,
          alinhar: TextAlign.left);
    }
  }
  if (!ocultas.contains(Camada.textos)) {
    for (final t in editor.textos) {
      _texto(canvas, t.texto, t.pos.offset + Offset(0, -t.tamanho / 2), t.tamanho.toDouble(),
          sel.contains(t.id) ? paleta.selecao : paleta.texto, alinhar: TextAlign.left);
    }
  }
}

/// Grade em pontos; afina o passo enquanto ficar apertado na tela.
void pintarGrade(Canvas canvas, Size tela, Camera camera, int passo, Paleta paleta) {
  var p = passo.toDouble();
  while (p * camera.escala < 10) {
    p *= 5;
  }
  final a = camera.paraMundo(Offset.zero), b = camera.paraMundo(Offset(tela.width, tela.height));
  final pts = <Offset>[];
  for (var x = (a.dx / p).floor() * p; x <= b.dx; x += p) {
    for (var y = (a.dy / p).floor() * p; y <= b.dy; y += p) {
      pts.add(camera.paraTela(Offset(x, y)));
    }
  }
  canvas.drawPoints(
    ui.PointMode.points,
    pts,
    Paint()
      ..color = paleta.grade
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round,
  );
  // Eixos na origem, para orientar.
  final o = camera.paraTela(Offset.zero);
  final eixo = Paint()
    ..color = paleta.grade
    ..strokeWidth = 1;
  canvas
    ..drawLine(o - const Offset(12, 0), o + const Offset(12, 0), eixo)
    ..drawLine(o - const Offset(0, 12), o + const Offset(0, 12), eixo);
}

/// Limites de tudo o que está na folha (para enquadrar e exportar).
Rect? limitesDaFolha(Editor editor) {
  Rect? r;
  void somar(Rect x) => r = r == null ? x : r!.expandToInclude(x);
  for (final c in editor.componentes) {
    somar(c.limites(editor.simboloDe(c)).inflate(1500));
  }
  for (final f in editor.fios) {
    for (final p in f.pontos) {
      somar(Rect.fromCircle(center: p.offset, radius: 500));
    }
  }
  for (final x in editor.rotulos) {
    somar(Rect.fromLTWH(x.pos.x.toDouble(), x.pos.y - 1500.0, x.nome.length * 800.0 + 800, 1600));
  }
  for (final s in editor.sondas) {
    somar(Rect.fromPoints(s.pos.offset, s.pos.offset + const Offset(9000, -2500)));
  }
  for (final t in editor.textos) {
    somar(Rect.fromLTWH(t.pos.x.toDouble(), t.pos.y - t.tamanho.toDouble(), t.texto.length * t.tamanho * 0.62, t.tamanho * 1.4));
  }
  return r;
}

/// Pinta a folha na tela: grade, itens, prévia da ferramenta, fio em andamento, cursor e janela de seleção.
class PintorCad extends CustomPainter {
  PintorCad(this.editor, this.camera, {this.janela, required this.paleta}) : super(repaint: editor);

  final Editor editor;
  final Camera camera;
  final Rect? janela;
  final Paleta paleta;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = paleta.fundo);
    if (!editor.ocultas.contains(Camada.grade)) pintarGrade(canvas, size, camera, editor.passo, paleta);
    canvas
      ..save()
      ..translate(camera.deslocamento.dx, camera.deslocamento.dy)
      ..scale(camera.escala);
    pintarFolha(canvas, editor, paleta);

    final cursor = editor.cursor;
    final s = editor.simbolo;
    if (cursor != null && editor.ferramenta == Ferramenta.componente && s != null) {
      pintarSimbolo(
        canvas,
        s,
        pos: cursor,
        rot: editor.rotPrevia,
        espelho: editor.espelhoPrevia,
        ref: '${s.prefixo}?',
        valor: s.valor,
        paleta: paleta,
        destaque: paleta.previa,
      );
    }
    final fio = editor.fio;
    if (fio != null) {
      final pts = [...fio, if (cursor != null) ...rotaOrtogonal(fio.last, cursor, horizontalPrimeiro: editor.horizontalPrimeiro).skip(1)];
      canvas.drawPath(
        Path()..addPolygon([for (final p in pts) p.offset], false),
        Paint()
          ..color = paleta.fio.withValues(alpha: 0.7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = _traco * 1.2,
      );
    }
    if (cursor != null && editor.ferramenta != Ferramenta.selecionar) {
      final cruz = Paint()
        ..color = paleta.previa
        ..strokeWidth = 1 / camera.escala;
      final t = 10 / camera.escala;
      final c = cursor.offset;
      canvas
        ..drawLine(c - Offset(t, 0), c + Offset(t, 0), cruz)
        ..drawLine(c - Offset(0, t), c + Offset(0, t), cruz);
      if (editor.ehLigacao(cursor)) {
        canvas.drawCircle(
          c,
          6 / camera.escala,
          Paint()
            ..color = paleta.selecao
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5 / camera.escala,
        );
      }
    }
    canvas.restore();

    final j = janela;
    if (j != null) {
      final r = Rect.fromPoints(camera.paraTela(j.topLeft), camera.paraTela(j.bottomRight));
      canvas
        ..drawRect(r, Paint()..color = paleta.selecao.withValues(alpha: 0.08))
        ..drawRect(
          r,
          Paint()
            ..color = paleta.selecao
            ..style = PaintingStyle.stroke,
        );
    }
  }

  @override
  bool shouldRepaint(PintorCad old) => true;
}
