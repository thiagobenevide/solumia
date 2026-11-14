import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../modelos.dart';
import 'anotador.dart';
import 'estojo.dart';
import 'geometria.dart';
import 'pintura.dart';

/// Texto de uma página com o retângulo de cada caractere, em pontos PDF como a página é exibida.
class TextoPagina {
  TextoPagina(this.texto, this.caracteres);

  final String texto;
  final List<Rect> caracteres;
}

/// Carrega o texto de cada página uma vez só (o marca-texto inteligente usa para achar as linhas).
class TextosDasPaginas {
  final Map<int, Future<TextoPagina?>> _cache = {};
  final Map<int, TextoPagina?> prontos = {};

  Future<TextoPagina?> de(PdfPage pagina) => _cache.putIfAbsent(pagina.pageNumber, () async {
    try {
      final t = await pagina.loadStructuredText();
      final r = TextoPagina(t.fullText, [for (final c in t.charRects) c.toRect(page: pagina)]);
      return prontos[pagina.pageNumber] = r.texto.trim().isEmpty ? null : r;
    } catch (_) {
      return prontos[pagina.pageNumber] = null;
    }
  });
}

/// Camada de tinta sobre uma página do PDF: recebe a caneta (ou o dedo/mouse, se permitido),
/// desenha o traço ao vivo e grava no [Anotador] ao soltar.
class CamadaPagina extends StatefulWidget {
  const CamadaPagina({
    super.key,
    required this.pagina,
    required this.anotador,
    required this.estojo,
    required this.textos,
    required this.aoCriarTexto,
    required this.aoTocarTexto,
    required this.aoTocarDestaque,
  });

  final PdfPage pagina;
  final Anotador anotador;
  final Estojo estojo;
  final TextosDasPaginas textos;
  final void Function(int pagina, Offset posicao) aoCriarTexto;
  final void Function(TextoAnotado texto) aoTocarTexto;
  final void Function(Destaque destaque) aoTocarDestaque;

  @override
  State<CamadaPagina> createState() => _CamadaPaginaState();
}

class _CamadaPaginaState extends State<CamadaPagina> {
  final _vivo = _Vivo();
  double _escala = 1;
  Ferramenta? _emUso;
  List<PontoTinta> _pontos = [];
  Offset _inicio = Offset.zero;
  bool _endireitado = false;
  Timer? _segurar;
  (int, int)? _trecho;

  int get _indice => widget.pagina.pageNumber - 1;

  @override
  void dispose() {
    _segurar?.cancel();
    _vivo.dispose();
    super.dispose();
  }

  Set<PointerDeviceKind> get _dispositivos => {
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    if (!widget.estojo.soCaneta) ...{PointerDeviceKind.touch, PointerDeviceKind.mouse, PointerDeviceKind.unknown},
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.anotador, widget.estojo]),
    builder: (context, _) => LayoutBuilder(
      builder: (context, c) {
        _escala = c.maxWidth / widget.pagina.width;
        final navegando = widget.estojo.ferramenta == Ferramenta.navegar;
        final pintura = Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(child: CustomPaint(painter: _PintorPagina(widget.anotador.visiveis, _indice, _escala))),
            CustomPaint(painter: _PintorVivo(_vivo, _escala)),
          ],
        );
        if (navegando) return IgnorePointer(child: pintura);
        return RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: {
            _ReconhecedorTinta: GestureRecognizerFactoryWithHandlers<_ReconhecedorTinta>(
              () => _ReconhecedorTinta(_dispositivos),
              (r) => r
                ..dispositivos = _dispositivos
                ..aoTocar = _tocar
                ..aoMover = _mover
                ..aoSoltar = _soltar
                ..aoCancelar = _cancelar,
            ),
          },
          child: pintura,
        );
      },
    ),
  );

  Offset _pt(PointerEvent e) => e.localPosition / _escala;

  double _pressao(PointerEvent e) {
    if (e.kind != PointerDeviceKind.stylus && e.kind != PointerDeviceKind.invertedStylus) return 0.5;
    final faixa = e.pressureMax - e.pressureMin;
    if (faixa <= 0) return 0.5;
    return ((e.pressure - e.pressureMin) / faixa).clamp(0.05, 1.0);
  }

  void _tocar(PointerDownEvent e) {
    // Ponta de borracha da caneta ou botão lateral da S Pen apertado: apaga, seja qual for a ferramenta.
    final botao = e.kind == PointerDeviceKind.stylus && e.buttons & kPrimaryStylusButton != 0;
    _emUso = e.kind == PointerDeviceKind.invertedStylus || botao ? Ferramenta.borracha : widget.estojo.ferramenta;
    _inicio = _pt(e);
    _endireitado = false;
    _trecho = null;
    switch (_emUso!) {
      case Ferramenta.borracha:
        widget.anotador.iniciarGesto();
        _apagar(_inicio);
      case Ferramenta.marcaTexto:
        widget.textos.de(widget.pagina);
        _pontos = [PontoTinta(_inicio.dx, _inicio.dy, 0.5)];
      case Ferramenta.texto || Ferramenta.navegar:
        break;
      default:
        _pontos = [PontoTinta(_inicio.dx, _inicio.dy, _pressao(e))];
        _vivo.traco = _tracoVivo();
        _armarSegurar();
    }
  }

  void _mover(PointerMoveEvent e) {
    final p = _pt(e);
    switch (_emUso) {
      case Ferramenta.borracha:
        _apagar(p);
      case Ferramenta.marcaTexto:
        _pontos.add(PontoTinta(p.dx, p.dy, 0.5));
        _atualizarTrecho(p);
      case Ferramenta.texto || Ferramenta.navegar || null:
        break;
      default:
        final ultimo = _pontos.last.offset;
        if ((p - ultimo).distance * _escala < 0.8) return;
        if (_endireitado || widget.estojo.retas) {
          _pontos = retificar([_pontos.first, PontoTinta(p.dx, p.dy, _pressao(e))]);
        } else {
          // Estabilizador: segue a ponta com um leve atraso, absorvendo o tremor da mão e da pressão.
          final a = _pontos.last;
          final s = a.offset + (p - a.offset) * 0.55;
          _pontos.add(PontoTinta(s.dx, s.dy, a.p + (_pressao(e) - a.p) * 0.35));
          if ((p - ultimo).distance * _escala > 3) _armarSegurar();
        }
        _vivo.traco = _tracoVivo();
    }
  }

  void _soltar(PointerUpEvent e) {
    _segurar?.cancel();
    final p = _pt(e);
    final foiToque = (p - _inicio).distance * _escala < 6;
    switch (_emUso) {
      case Ferramenta.borracha:
        widget.anotador.concluirGesto();
        _vivo.borracha = null;
      case Ferramenta.texto:
        if (foiToque) _tocarTexto(p);
      case Ferramenta.marcaTexto:
        if (foiToque) {
          _tocarDestaque(p);
        } else {
          _gravarDestaque();
        }
      case Ferramenta.navegar || null:
        break;
      default:
        // O estabilizador fica um pouco atrás: o traço termina onde a ponta saiu.
        if (_pontos.length > 1 && !_endireitado && !widget.estojo.retas) {
          _pontos.add(PontoTinta(p.dx, p.dy, _pontos.last.p));
        }
        if (_pontos.isNotEmpty) widget.anotador.adicionar(_tracoVivo()!);
    }
    _limpar();
  }

  void _cancelar() {
    _segurar?.cancel();
    if (_emUso == Ferramenta.borracha) widget.anotador.concluirGesto();
    _limpar();
  }

  void _limpar() {
    _emUso = null;
    _pontos = [];
    _trecho = null;
    _vivo
      ..traco = null
      ..trecho = const []
      ..borracha = null;
  }

  /// Segurar a caneta parada no fim do traço por meio segundo endireita o traço (Samsung Notes).
  void _armarSegurar() {
    _segurar?.cancel();
    _segurar = Timer(const Duration(milliseconds: 550), () {
      if (_pontos.length < 3 || _endireitado) return;
      _endireitado = true;
      _pontos = retificar(_pontos);
      _vivo.traco = _tracoVivo();
    });
  }

  Traco? _tracoVivo() {
    final f = _emUso;
    final pincel = f == Ferramenta.marcaTexto ? Pincel.marcador : f?.pincel;
    if (pincel == null) return null;
    final pontos = widget.estojo.retas && _pontos.length > 1 ? retificar(_pontos) : _pontos;
    return Traco(
      id: novoId(),
      pagina: _indice,
      pincel: pincel,
      cor: widget.estojo.corDe(f!),
      espessura: widget.estojo.espessuraDe(f),
      pontos: List.of(pontos),
    );
  }

  void _apagar(Offset p) {
    final raio = widget.estojo.espessuraDe(Ferramenta.borracha) / 2;
    _vivo.borracha = (p, raio);
    final a = widget.anotador.visiveis;
    widget.anotador.removerNoGesto({
      for (final t in a.tracos)
        if (t.pagina == _indice && tocaTraco(t, p, raio)) t.id,
      for (final d in a.destaques)
        if (d.pagina == _indice && d.retangulos.any((r) => r.inflate(raio).contains(p))) d.id,
      for (final t in a.textos)
        if (t.pagina == _indice && limitesDoTexto(t).inflate(raio).contains(p)) t.id,
    });
  }

  void _atualizarTrecho(Offset p) {
    final texto = widget.textos.prontos[widget.pagina.pageNumber];
    if (texto == null) {
      // Página sem texto (escaneada): vira um marca-texto livre reto.
      _vivo.traco = Traco(
        id: '',
        pagina: _indice,
        pincel: Pincel.marcador,
        cor: widget.estojo.corDe(Ferramenta.marcaTexto),
        espessura: widget.estojo.espessuraDe(Ferramenta.marcaTexto),
        pontos: retificar(_pontos),
      );
      return;
    }
    final i = caractereMaisProximo(texto.caracteres, _inicio);
    final j = caractereMaisProximo(texto.caracteres, p);
    if (i == null || j == null) return;
    _trecho = i <= j ? (i, j) : (j, i);
    _vivo.traco = null;
    _vivo.trecho = retangulosDoTrecho(texto.caracteres, _trecho!.$1, _trecho!.$2);
    _vivo.corTrecho = widget.estojo.corDe(Ferramenta.marcaTexto);
  }

  void _gravarDestaque() {
    final texto = widget.textos.prontos[widget.pagina.pageNumber];
    final trecho = _trecho;
    if (texto == null || trecho == null) {
      if (_vivo.traco != null) widget.anotador.adicionar(_vivo.traco!.copiarComId(novoId()));
      return;
    }
    final conteudo = texto.texto.substring(trecho.$1, trecho.$2 + 1).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (conteudo.isEmpty) return;
    widget.anotador.adicionar(
      Destaque(
        id: novoId(),
        pagina: _indice,
        texto: conteudo,
        cor: widget.estojo.corDe(Ferramenta.marcaTexto),
        retangulos: retangulosDoTrecho(texto.caracteres, trecho.$1, trecho.$2),
        criado: DateTime.now(),
      ),
    );
  }

  void _tocarTexto(Offset p) {
    for (final t in widget.anotador.visiveis.textos.reversed) {
      if (t.pagina == _indice && limitesDoTexto(t).inflate(4).contains(p)) return widget.aoTocarTexto(t);
    }
    widget.aoCriarTexto(_indice, p);
  }

  void _tocarDestaque(Offset p) {
    for (final d in widget.anotador.visiveis.destaques.reversed) {
      if (d.pagina == _indice && d.retangulos.any((r) => r.inflate(3).contains(p))) return widget.aoTocarDestaque(d);
    }
  }
}

extension on Traco {
  Traco copiarComId(String id) =>
      Traco(id: id, pagina: pagina, pincel: pincel, cor: cor, espessura: espessura, pontos: pontos, projetos: projetos);
}

/// O que está sendo desenhado agora (repinta só a camada de cima).
class _Vivo extends ChangeNotifier {
  Traco? _traco;
  List<Rect> _trecho = const [];
  Color corTrecho = const Color(0xFFFFEB3B);
  (Offset, double)? _borracha;

  Traco? get traco => _traco;
  set traco(Traco? t) {
    _traco = t;
    notifyListeners();
  }

  List<Rect> get trecho => _trecho;
  set trecho(List<Rect> r) {
    _trecho = r;
    notifyListeners();
  }

  (Offset, double)? get borracha => _borracha;
  set borracha((Offset, double)? b) {
    _borracha = b;
    notifyListeners();
  }
}

class _PintorPagina extends CustomPainter {
  _PintorPagina(this.anotacoes, this.pagina, this.escala);

  final Anotacoes anotacoes;
  final int pagina;
  final double escala;

  @override
  void paint(Canvas canvas, Size size) {
    for (final d in anotacoes.destaques) {
      if (d.pagina == pagina) pintarDestaque(canvas, d, escala);
    }
    for (final t in anotacoes.tracos) {
      if (t.pagina == pagina) pintarTraco(canvas, t, escala);
    }
    for (final t in anotacoes.textos) {
      if (t.pagina == pagina) pintarTexto(canvas, t, escala);
    }
  }

  @override
  bool shouldRepaint(_PintorPagina old) =>
      !identical(old.anotacoes, anotacoes) || old.escala != escala || old.pagina != pagina;
}

class _PintorVivo extends CustomPainter {
  _PintorVivo(this.vivo, this.escala) : super(repaint: vivo);

  final _Vivo vivo;
  final double escala;

  @override
  void paint(Canvas canvas, Size size) {
    final tinta = Paint()
      ..color = vivo.corTrecho.withValues(alpha: 0.4)
      ..blendMode = BlendMode.multiply;
    for (final r in vivo.trecho) {
      canvas.drawRect(Rect.fromLTRB(r.left * escala, r.top * escala, r.right * escala, r.bottom * escala), tinta);
    }
    if (vivo.traco case final t?) pintarTraco(canvas, t, escala);
    if (vivo.borracha case (final p, final raio)) {
      canvas.drawCircle(
        p * escala,
        raio * escala,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = Colors.grey.shade600,
      );
    }
  }

  @override
  bool shouldRepaint(_PintorVivo old) => old.escala != escala || old.vivo != vivo;
}

/// Ganha a disputa de gestos assim que um dispositivo permitido encosta: o traço sai na hora e o
/// visualizador não rola junto. Dispositivos fora de [dispositivos] (o dedo, no modo "só caneta")
/// nem entram, e o visualizador continua rolando e dando zoom com eles.
class _ReconhecedorTinta extends OneSequenceGestureRecognizer {
  _ReconhecedorTinta(this.dispositivos);

  Set<PointerDeviceKind> dispositivos;
  void Function(PointerDownEvent)? aoTocar;
  void Function(PointerMoveEvent)? aoMover;
  void Function(PointerUpEvent)? aoSoltar;
  VoidCallback? aoCancelar;
  int? _ponteiro;

  @override
  bool isPointerAllowed(PointerDownEvent event) => _ponteiro == null && dispositivos.contains(event.kind);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    startTrackingPointer(event.pointer, event.transform);
    _ponteiro = event.pointer;
    resolve(GestureDisposition.accepted);
    aoTocar?.call(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _ponteiro) return;
    if (event is PointerMoveEvent) {
      aoMover?.call(event);
    } else if (event is PointerUpEvent) {
      aoSoltar?.call(event);
      _encerrar(event.pointer);
    } else if (event is PointerCancelEvent) {
      aoCancelar?.call();
      _encerrar(event.pointer);
    }
  }

  void _encerrar(int ponteiro) {
    _ponteiro = null;
    stopTrackingPointer(ponteiro);
  }

  @override
  void rejectGesture(int pointer) {
    super.rejectGesture(pointer);
    if (pointer == _ponteiro) {
      _ponteiro = null;
      aoCancelar?.call();
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'tinta';
}
