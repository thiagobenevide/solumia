import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Cena de entrada de cada módulo: ao entrar num módulo, uma animação curta mostra "em que camada
/// da vida" a pessoa está entrando (saúde: batimento; notas: folha virando; empreendimento: barras
/// subindo) e depois a tela aparece com um zoom suave, como atravessar a cena. Só cor do tema, sem
/// imagem; respeita "reduzir animações" do sistema.
enum TemaCena { padrao, painel, saude, notas, estudos, empreendimento, financas, codigo }

class CenaEntrada extends StatefulWidget {
  const CenaEntrada({
    super.key,
    required this.tema,
    required this.titulo,
    required this.icone,
    required this.ativa,
    required this.child,
  });

  final TemaCena tema;
  final String titulo;
  final IconData icone;

  /// A aba está à frente. Ao voltar a ficar ativa, a tela só refaz o zoom curto (a cena completa
  /// toca na primeira entrada).
  final bool ativa;
  final Widget child;

  @override
  State<CenaEntrada> createState() => _CenaEntradaState();
}

class _CenaEntradaState extends State<CenaEntrada> with TickerProviderStateMixin {
  static const _cena = Duration(milliseconds: 1500);
  static const _zoom = Duration(milliseconds: 420);

  /// 0 → 1: a cena desenha (até [_fimDesenho]) e depois some com zoom, revelando a tela.
  late final AnimationController _intro = AnimationController(vsync: this, duration: _cena);

  /// Zoom curto da tela ao voltar para a aba.
  late final AnimationController _volta = AnimationController(vsync: this, duration: _zoom, value: 1);
  bool _tocou = false;

  static const _fimDesenho = 0.62;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_tocou && widget.ativa) _tocarPrimeira();
  }

  @override
  void didUpdateWidget(CenaEntrada antigo) {
    super.didUpdateWidget(antigo);
    if (!widget.ativa || antigo.ativa) return;
    if (!_tocou) {
      _tocarPrimeira();
      return;
    }
    if (!_semAnimacao) _volta.forward(from: 0);
  }

  bool get _semAnimacao => MediaQuery.of(context).disableAnimations;

  void _tocarPrimeira() {
    _tocou = true;
    if (_semAnimacao) {
      _intro.value = 1;
      return;
    }
    _intro.forward(from: 0);
  }

  void _pular(PointerDownEvent _) {
    if (_tocou && _intro.value < 1) _intro.animateTo(1, duration: const Duration(milliseconds: 220));
  }

  @override
  void dispose() {
    _intro.dispose();
    _volta.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_intro, _volta]),
      child: widget.child,
      builder: (context, tela) => _montar(context, tela!),
    );
  }

  Widget _montar(BuildContext context, Widget tela) {
    final i = _intro.value;
    final saida = ((i - _fimDesenho) / (1 - _fimDesenho)).clamp(0.0, 1.0);
    final revela = Curves.easeOutCubic.transform(saida);
    final volta = Curves.easeOutCubic.transform(_volta.value);
    // a tela chega de um pouco mais longe até o tamanho real (nunca maior: as bordas seguem
    // tocáveis durante a animação)
    final escala = (0.94 + 0.06 * revela) * (0.98 + 0.02 * volta);
    final telaVista = Opacity(
      opacity: math.min(revela, 0.35 + 0.65 * volta),
      child: Transform.scale(scale: escala, child: tela),
    );
    final emCena = _tocou && i < 1;
    // Estrutura fixa (Listener > Stack > tela): trocar a forma da árvore no fim da cena recriaria
    // a tela e perderia o estado dela. Um toque encurta a cena sem prender a tela.
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _pular,
      child: Stack(
        fit: StackFit.expand,
        children: [
          telaVista,
          if (emCena)
            IgnorePointer(
              child: _Palco(
                tema: widget.tema,
                titulo: widget.titulo,
                icone: widget.icone,
                desenho: (i / _fimDesenho).clamp(0.0, 1.0),
                saida: saida,
              ),
            ),
        ],
      ),
    );
  }
}

/// A cena em si: o desenho do tema no centro, o nome do módulo embaixo; na saída cresce e some
/// (a câmera atravessa a cena até a tela).
class _Palco extends StatelessWidget {
  const _Palco({
    required this.tema,
    required this.titulo,
    required this.icone,
    required this.desenho,
    required this.saida,
  });

  final TemaCena tema;
  final String titulo;
  final IconData icone;
  final double desenho;
  final double saida;

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    final texto = Theme.of(context).textTheme;
    final s = Curves.easeInCubic.transform(saida);
    final nome = Curves.easeOutCubic.transform(((desenho - 0.35) / 0.65).clamp(0.0, 1.0));
    return Opacity(
      opacity: 1 - s,
      child: ColoredBox(
        color: cores.surface,
        child: Center(
          child: Transform.scale(
            scale: 1 + 2.2 * s,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 180,
                  height: 140,
                  child: CustomPaint(painter: _pintor(tema, desenho, cores, icone)),
                ),
                const SizedBox(height: 18),
                Opacity(
                  opacity: nome,
                  child: Transform.translate(
                    offset: Offset(0, 12 * (1 - nome)),
                    child: Text(
                      titulo,
                      style: texto.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.4),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

CustomPainter _pintor(TemaCena tema, double t, ColorScheme c, IconData icone) {
  switch (tema) {
    case TemaCena.saude:
      return _Batimento(t, c);
    case TemaCena.notas:
    case TemaCena.estudos:
      return _Folhas(t, c, livro: tema == TemaCena.estudos);
    case TemaCena.empreendimento:
    case TemaCena.financas:
      return _Barras(t, c);
    case TemaCena.painel:
      return _Aneis(t, c);
    case TemaCena.codigo:
      return _Codigo(t, c);
    case TemaCena.padrao:
      return _Estilhacos(t, c, icone);
  }
}

double _faixa(double t, double inicio, double fim) {
  return Curves.easeOutCubic.transform(((t - inicio) / (fim - inicio)).clamp(0.0, 1.0));
}

/// Saúde: a linha do eletrocardiograma se desenha e o coração pulsa no pico.
class _Batimento extends CustomPainter {
  _Batimento(this.t, this.c);

  final double t;
  final ColorScheme c;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final m = size.height / 2;
    final linha = Path()
      ..moveTo(0, m)
      ..lineTo(w * 0.30, m)
      ..lineTo(w * 0.38, m - 14)
      ..lineTo(w * 0.45, m + 10)
      ..lineTo(w * 0.52, m - 48)
      ..lineTo(w * 0.59, m + 30)
      ..lineTo(w * 0.66, m)
      ..lineTo(w, m);
    final tinta = Paint()
      ..color = c.primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    _desenharParcial(canvas, linha, _faixa(t, 0, 0.75), tinta);
    final pulso = _faixa(t, 0.45, 1);
    final brilho = Paint()..color = c.primary.withValues(alpha: 0.18 * (1 - pulso));
    canvas.drawCircle(Offset(w * 0.52, m - 48), 6 + 34 * pulso, brilho);
  }

  @override
  bool shouldRepaint(_Batimento old) => old.t != t;
}

/// Notas (caderno) e estudos (livro): folhas que viram e linhas que se escrevem.
class _Folhas extends CustomPainter {
  _Folhas(this.t, this.c, {required this.livro});

  final double t;
  final ColorScheme c;
  final bool livro;

  @override
  void paint(Canvas canvas, Size size) {
    final largura = size.width * 0.36;
    final altura = size.height * 0.92;
    final topo = (size.height - altura) / 2;
    final lombada = size.width / 2;
    final papel = Paint()..color = c.surfaceContainerHighest;
    final borda = Paint()
      ..color = c.outlineVariant
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final direita = RRect.fromLTRBR(lombada, topo, lombada + largura, topo + altura, const Radius.circular(6));
    final esquerda = RRect.fromLTRBR(lombada - largura, topo, lombada, topo + altura, const Radius.circular(6));
    canvas.drawRRect(esquerda, papel);
    canvas.drawRRect(esquerda, borda);
    canvas.drawRRect(direita, papel);
    canvas.drawRRect(direita, borda);
    _escrever(canvas, esquerda.outerRect, _faixa(t, 0.55, 1));
    // duas folhas viram da direita para a esquerda (escala horizontal = projeção do giro)
    _virar(canvas, lombada, topo, largura, altura, _faixa(t, 0, 0.5));
    _virar(canvas, lombada, topo, largura, altura, _faixa(t, 0.2, 0.7));
    if (livro) {
      final marca = Paint()..color = c.primary;
      canvas.drawRect(Rect.fromLTWH(lombada + largura * 0.7, topo - 4, 8, 26 * _faixa(t, 0.6, 1)), marca);
    }
  }

  void _escrever(Canvas canvas, Rect folha, double p) {
    final tinta = Paint()
      ..color = c.primary.withValues(alpha: 0.75)
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    const linhas = 5;
    for (var k = 0; k < linhas; k++) {
      final local = (p * linhas - k).clamp(0.0, 1.0);
      if (local <= 0) break;
      final y = folha.top + 22 + k * 18;
      final fim = folha.left + 12 + (folha.width - 24) * (k == linhas - 1 ? 0.55 : 0.92) * local;
      canvas.drawLine(Offset(folha.left + 12, y), Offset(fim, y), tinta);
    }
  }

  void _virar(Canvas canvas, double lombada, double topo, double largura, double altura, double p) {
    if (p <= 0 || p >= 1) return;
    final giro = math.cos(p * math.pi);
    final larg = largura * giro;
    final rect = larg >= 0
        ? Rect.fromLTWH(lombada, topo, larg, altura)
        : Rect.fromLTWH(lombada + larg, topo, -larg, altura);
    final sombra = 0.10 + 0.25 * (1 - giro.abs());
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(6)),
      Paint()..color = Color.lerp(c.surfaceContainerHighest, c.shadow, sombra)!,
    );
  }

  @override
  bool shouldRepaint(_Folhas old) => old.t != t;
}

/// Empreendimento e finanças: barras sobem em cascata e a linha de tendência passa por cima.
class _Barras extends CustomPainter {
  _Barras(this.t, this.c);

  final double t;
  final ColorScheme c;

  static const _alturas = [0.30, 0.45, 0.40, 0.62, 0.78, 0.95];

  @override
  void paint(Canvas canvas, Size size) {
    final n = _alturas.length;
    final passo = size.width / n;
    final base = size.height;
    final tendencia = Path();
    for (var k = 0; k < n; k++) {
      final p = _faixa(t, k * 0.07, 0.45 + k * 0.07);
      final h = size.height * _alturas[k] * p;
      final x = k * passo + passo * 0.18;
      final barra = RRect.fromLTRBR(x, base - h, x + passo * 0.64, base, const Radius.circular(4));
      canvas.drawRRect(barra, Paint()..color = Color.lerp(c.secondaryContainer, c.primary, k / (n - 1))!);
      final topo = Offset(x + passo * 0.32, base - size.height * _alturas[k] - 10);
      if (k == 0) {
        tendencia.moveTo(topo.dx, topo.dy);
      } else {
        tendencia.lineTo(topo.dx, topo.dy);
      }
    }
    final tinta = Paint()
      ..color = c.tertiary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round;
    _desenharParcial(canvas, tendencia, _faixa(t, 0.5, 1), tinta);
  }

  @override
  bool shouldRepaint(_Barras old) => old.t != t;
}

/// Painel (início): anéis concêntricos se fecham, como o placar do dia montando.
class _Aneis extends CustomPainter {
  _Aneis(this.t, this.c);

  final double t;
  final ColorScheme c;

  @override
  void paint(Canvas canvas, Size size) {
    final centro = size.center(Offset.zero);
    final cores = [c.primary, c.tertiary, c.secondary];
    for (var k = 0; k < 3; k++) {
      final raio = size.height * 0.46 - k * 16;
      final p = _faixa(t, k * 0.15, 0.7 + k * 0.1);
      final fundo = Paint()
        ..color = cores[k].withValues(alpha: 0.14)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10;
      canvas.drawCircle(centro, raio, fundo);
      final arco = Paint()
        ..color = cores[k]
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10
        ..strokeCap = StrokeCap.round;
      final rect = Rect.fromCircle(center: centro, radius: raio);
      canvas.drawArc(rect, -math.pi / 2 + k * 0.6, 2 * math.pi * 0.82 * p, false, arco);
    }
  }

  @override
  bool shouldRepaint(_Aneis old) => old.t != t;
}

/// Código: os sinais < > se abrem e linhas indentadas se digitam entre eles, com cursor.
class _Codigo extends CustomPainter {
  _Codigo(this.t, this.c);

  final double t;
  final ColorScheme c;

  static const _linhas = [(0, 0.7), (1, 0.5), (1, 0.8), (2, 0.4), (0, 0.3)];

  @override
  void paint(Canvas canvas, Size size) {
    final m = size.height / 2;
    final abre = _faixa(t, 0, 0.35);
    final sinal = Paint()
      ..color = c.primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final x1 = size.width * (0.5 - 0.42 * abre);
    final x2 = size.width * (0.5 + 0.42 * abre);
    canvas.drawPath(Path()..moveTo(x1 + 16, m - 26)..lineTo(x1, m)..lineTo(x1 + 16, m + 26), sinal);
    canvas.drawPath(Path()..moveTo(x2 - 16, m - 26)..lineTo(x2, m)..lineTo(x2 - 16, m + 26), sinal);
    final p = _faixa(t, 0.3, 1);
    final tinta = Paint()
      ..color = c.onSurfaceVariant
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final esquerda = size.width * 0.24;
    final util = size.width * 0.52;
    final n = _linhas.length;
    for (var k = 0; k < n; k++) {
      final local = (p * n - k).clamp(0.0, 1.0);
      if (local <= 0) break;
      final (recuo, tamanho) = _linhas[k];
      final y = m - 32 + k * 16;
      final x = esquerda + recuo * 12;
      canvas.drawLine(Offset(x, y), Offset(x + util * tamanho * local, y), tinta);
    }
  }

  @override
  bool shouldRepaint(_Codigo old) => old.t != t;
}

/// Demais módulos: estilhaços espalhados voam para o centro e formam o ícone do módulo.
class _Estilhacos extends CustomPainter {
  _Estilhacos(this.t, this.c, this.icone);

  final double t;
  final ColorScheme c;
  final IconData icone;

  @override
  void paint(Canvas canvas, Size size) {
    final centro = size.center(Offset.zero);
    final junta = _faixa(t, 0, 0.7);
    const pedacos = 10;
    for (var k = 0; k < pedacos; k++) {
      final angulo = k * 2 * math.pi / pedacos + 0.4;
      final longe = 90 * (1 - junta);
      final pos = centro + Offset(math.cos(angulo), math.sin(angulo)) * (26 + longe);
      final lado = 10 + (k % 3) * 4.0;
      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      canvas.rotate(angulo + 2.5 * (1 - junta));
      final cor = (k.isEven ? c.primary : c.tertiary).withValues(alpha: 0.25 + 0.5 * (1 - junta));
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: lado, height: lado * 0.6), const Radius.circular(2)),
        Paint()..color = cor,
      );
      canvas.restore();
    }
    final aparece = _faixa(t, 0.45, 1);
    final pintor = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icone.codePoint),
        style: TextStyle(
          fontSize: 44 + 12 * aparece,
          fontFamily: icone.fontFamily,
          package: icone.fontPackage,
          color: c.primary.withValues(alpha: aparece),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    pintor.paint(canvas, centro - Offset(pintor.width / 2, pintor.height / 2));
  }

  @override
  bool shouldRepaint(_Estilhacos old) => old.t != t;
}

/// Desenha só a fração [p] do comprimento de [caminho] (traço que vai se formando).
void _desenharParcial(Canvas canvas, Path caminho, double p, Paint tinta) {
  if (p <= 0) return;
  for (final parte in caminho.computeMetrics()) {
    canvas.drawPath(parte.extractPath(0, parte.length * p), tinta);
  }
}
