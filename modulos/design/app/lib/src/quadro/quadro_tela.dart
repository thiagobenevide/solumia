import 'dart:async';
import 'dart:math';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/gestures.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api_design.dart';
import '../cache.dart';
import '../modelos.dart';
import 'editor.dart';
import 'entrada.dart';
import 'estojo.dart';
import 'menu_caneta.dart';
import 'exportar.dart';
import 'fluxo.dart';
import 'imagens.dart';
import 'paineis.dart';
import 'pintura.dart';
import 'tabela.dart';

/// Abre o quadro [id]: carrega e mostra a [QuadroTela].
class AbrirQuadro extends StatelessWidget {
  const AbrirQuadro({super.key, required this.api, required this.cache, required this.id});

  final ApiDesign api;
  final CacheQuadros cache;
  final String id;

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: EditorQuadro.abrir(api, cache, id),
    builder: (context, s) {
      if (s.hasData) return QuadroTela(editor: s.data!);
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: s.hasError ? Text('Não abriu o quadro: ${s.error}') : const CircularProgressIndicator()),
      );
    },
  );
}

class QuadroTela extends StatefulWidget {
  const QuadroTela({super.key, required this.editor, this.acoes = const []});

  final EditorQuadro editor;

  /// Botões a mais na barra superior (o caderno põe papel, caneta inteligente e referências).
  final List<Widget> acoes;

  @override
  State<QuadroTela> createState() => _QuadroTelaState();
}

enum _ModoSelecao { laco, mover, escalar }

class _Sinal extends ChangeNotifier {
  void avisar() => notifyListeners();
}

class _QuadroTelaState extends State<QuadroTela> with SingleTickerProviderStateMixin {
  EditorQuadro get _editor => widget.editor;
  final _estojo = Estojo();
  // Clique no botão da caneta pairando abre o menu circular onde a caneta está.
  final _cliqueCaneta = CliqueDoBotao();
  Offset? _menuCaneta;
  final _camera = Camera();
  final _mudouCamera = _Sinal();
  final _vivo = _Sinal();
  late final Ticker _relogio = createTicker((_) => _animarLaser());
  Size _tela = Size.zero;
  bool _projecao = false;
  // PC: painéis laterais visíveis (botões na barra superior ocultam cada um).
  bool _verFormas = true, _verEstilo = true;
  // Painel lateral de busca no Google Imagens (sobre o quadro, em qualquer largura).
  bool _verImagens = false;
  bool _escuro = false;
  bool _enquadrado = false;
  // Barra de ferramentas: lado do quadro onde fica, oculta ou não (guardados no aparelho) e o
  // deslocamento do arrasto em andamento (ao soltar, encaixa no lado mais perto).
  _Lado _ladoBarra = _Lado.baixo;
  bool _barraOculta = false;
  Offset _arrasteBarra = Offset.zero;
  final _chaveAreaBarra = GlobalKey(), _chaveBarra = GlobalKey();
  static const _prefLado = 'design.barra.lado', _prefOculta = 'design.barra.oculta';

  // Ponteiros que movem/dão zoom (posição na tela) e o centro/abertura do último quadro.
  final Map<int, Offset> _navegando = {};
  Offset? _ultimoCentro;
  double? _ultimaAbertura;
  double? _escalaTrackpad;

  // Ponteiro que desenha/apaga agora.
  int? _ponteiro;
  PointerDeviceKind? _tipo;
  Ferramenta? _emUso;
  Offset _inicio = Offset.zero;
  List<Ponto> _pontos = [];
  Elemento? _elementoVivo;
  final List<(Offset, DateTime)> _laser = [];
  (Offset, double)? _anel;

  // Seleção: ids escolhidos, laço em andamento e o arrasto (mover/redimensionar) ao vivo.
  Set<String> _selecionados = {};
  _ModoSelecao? _modo;
  List<Offset> _laco = [];
  Offset _ancora = Offset.zero;
  Map<String, Elemento> _originais = {};
  List<Elemento> _arrastados = [];
  Set<String> _ocultos = const {};

  /// Bloco ou texto solto sendo digitado direto no quadro (texto novo ainda não está no editor).
  /// O texto dele sai da pintura enquanto o campo fica por cima, no mesmo lugar e fonte.
  Elemento? _digitando;
  final _campoTexto = TextEditingController();
  final _focoTexto = FocusNode();
  final _focoQuadro = FocusNode();

  @override
  void initState() {
    super.initState();
    unawaited(
      SharedPreferences.getInstance().then((p) {
        if (!mounted) return;
        setState(() {
          _ladoBarra = _Lado.values.asNameMap()[p.getString(_prefLado)] ?? _Lado.baixo;
          _barraOculta = p.getBool(_prefOculta) ?? false;
        });
      }),
    );
  }

  @override
  void dispose() {
    _campoTexto.dispose();
    _focoTexto.dispose();
    _focoQuadro.dispose();
    _editor.salvar();
    _editor.dispose();
    _estojo.dispose();
    _relogio.dispose();
    if (_projecao) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // ---------- câmera ----------

  void _moverCamera(void Function() mudanca) {
    mudanca();
    _mudouCamera.avisar();
  }

  void _enquadrar() => _moverCamera(() => _camera.enquadrar(_editor.limites, _tela));

  void _zoomCentro(double fator) => _moverCamera(() => _camera.zoom(fator, _tela.center(Offset.zero)));

  void _navegar() {
    if (_navegando.isEmpty) return;
    final pontos = _navegando.values;
    final centro = pontos.reduce((a, b) => a + b) / pontos.length.toDouble();
    final abertura = pontos.map((p) => (p - centro).distance).reduce((a, b) => a + b) / pontos.length;
    _moverCamera(() {
      if (_ultimoCentro != null) _camera.deslocamento += centro - _ultimoCentro!;
      if (pontos.length > 1 && (_ultimaAbertura ?? 0) > 0) _camera.zoom(abertura / _ultimaAbertura!, centro);
    });
    _ultimoCentro = centro;
    _ultimaAbertura = abertura;
  }

  // Entrou ou saiu um dedo: recomeça a medida para a câmera não pular.
  void _reiniciarNavegacao() {
    _ultimoCentro = null;
    _ultimaAbertura = null;
    _navegar();
  }

  // ---------- ponteiros ----------

  void _tocar(PointerDownEvent e) {
    _cliqueCaneta.cancelar();
    if (ehCaneta(e.kind)) _estojo.canetaVista();
    // Segundo dedo enquanto um dedo desenha: era pinça, não traço.
    if (e.kind == PointerDeviceKind.touch && _tipo == PointerDeviceKind.touch && _ponteiro != null) {
      final primeiro = _ponteiro!, ultimo = _camera.paraTela(_pontos.last.offset);
      _cancelar();
      _navegando[primeiro] = ultimo;
    }
    final gesto = classificar(
      tipo: e.kind,
      botoes: e.buttons,
      ferramenta: _estojo.ferramenta,
      dedoDesenha: _estojo.dedoDesenha && _navegando.isEmpty,
      espaco: HardwareKeyboard.instance.isLogicalKeyPressed(LogicalKeyboardKey.space),
    );
    if (gesto == Gesto.navegar) {
      _navegando[e.pointer] = e.localPosition;
      _reiniciarNavegacao();
      return;
    }
    if (_ponteiro != null) return;
    _ponteiro = e.pointer;
    _tipo = e.kind;
    _emUso = gesto == Gesto.apagar ? Ferramenta.borracha : _estojo.ferramenta;
    // Ctrl+clique do mouse seleciona com qualquer ferramenta.
    if (_emUso != Ferramenta.borracha && e.kind == PointerDeviceKind.mouse && _ctrl) {
      _estojo.ferramenta = Ferramenta.selecao;
      _emUso = Ferramenta.selecao;
    }
    _inicio = _camera.paraMundo(e.localPosition);
    _pontos = [Ponto(_inicio.dx, _inicio.dy, pressao(e))];
    if (gesto == Gesto.apagar) {
      _editor.iniciarGesto();
      _apagar(_inicio);
      return;
    }
    switch (_emUso!) {
      case Ferramenta.selecao:
        _iniciarSelecao(e.localPosition);
      case Ferramenta.laser:
        _laser.add((_inicio, DateTime.now()));
        if (!_relogio.isActive) _relogio.start();
      case Ferramenta.caneta || Ferramenta.marcador:
        _elementoVivo = _traco();
      default:
        break;
    }
    _vivo.avisar();
  }

  void _mover(PointerMoveEvent e) {
    if (_navegando.containsKey(e.pointer)) {
      _navegando[e.pointer] = e.localPosition;
      _navegar();
      return;
    }
    if (e.pointer != _ponteiro) return;
    final p = _camera.paraMundo(e.localPosition);
    switch (_emUso) {
      case Ferramenta.borracha:
        _apagar(p);
      case Ferramenta.selecao:
        _arrastarSelecao(p);
      case Ferramenta.laser:
        _laser.add((p, DateTime.now()));
      case Ferramenta.caneta || Ferramenta.marcador:
        // Pontos a menos de ~1,5 px na tela não mudam o desenho e só pesam no JSON.
        if ((p - _pontos.last.offset).distance * _camera.escala < 1.5) return;
        _pontos.add(Ponto(p.dx, p.dy, pressao(e)));
        _elementoVivo = _traco();
      case final f? when f.forma != null:
        _elementoVivo = _forma(f.forma!, p);
      default:
        break;
    }
    _vivo.avisar();
  }

  void _soltar(PointerEvent e) {
    if (_navegando.remove(e.pointer) != null) {
      _reiniciarNavegacao();
      return;
    }
    if (e.pointer != _ponteiro) return;
    final fim = _camera.paraMundo(e.localPosition);
    if (_emUso == Ferramenta.borracha) {
      _editor.encerrarGesto();
    } else if (_emUso == Ferramenta.selecao) {
      _soltarSelecao(fim);
    } else if (_emUso == Ferramenta.texto && (fim - _inicio).distance * _camera.escala < 8) {
      _escreverTexto(_inicio);
    } else if (_elementoVivo != null) {
      _editor.adicionar(_elementoVivo!);
    }
    _limparGesto();
  }

  void _cancelar() {
    if (_emUso == Ferramenta.borracha) _editor.encerrarGesto();
    if (_emUso == Ferramenta.selecao) _fimDoArrasto();
    _limparGesto();
  }

  void _limparGesto() {
    _ponteiro = null;
    _tipo = null;
    _emUso = null;
    _elementoVivo = null;
    _pontos = [];
    _vivo.avisar();
  }

  void _pairar(PointerHoverEvent e) {
    if (_cliqueCaneta.pairar(e) case final p? when !_projecao) {
      _estojo.canetaVista();
      setState(() => _menuCaneta = p);
    }
    final apagando = _estojo.ferramenta == Ferramenta.borracha || e.kind == PointerDeviceKind.invertedStylus;
    final anel = apagando ? (_camera.paraMundo(e.localPosition), _raioBorracha) : null;
    if (anel == null && _anel == null) return;
    _anel = anel;
    _vivo.avisar();
  }

  void _rolar(PointerSignalEvent e) {
    if (e is PointerScrollEvent) {
      final teclado = HardwareKeyboard.instance;
      if (teclado.isControlPressed || teclado.isMetaPressed) {
        _moverCamera(() => _camera.zoom(pow(0.998, e.scrollDelta.dy).toDouble(), e.localPosition));
      } else {
        final d = teclado.isShiftPressed ? Offset(e.scrollDelta.dy, 0) : e.scrollDelta;
        _moverCamera(() => _camera.deslocamento -= d);
      }
    } else if (e is PointerScaleEvent) {
      _moverCamera(() => _camera.zoom(e.scale, e.localPosition));
    }
  }

  // Trackpad do notebook: dois dedos movem, pinça dá zoom.
  void _trackpad(PointerPanZoomUpdateEvent e) {
    final anterior = _escalaTrackpad ?? 1;
    _escalaTrackpad = e.scale;
    _moverCamera(() {
      _camera.deslocamento += e.panDelta;
      _camera.zoom(e.scale / anterior, e.localPosition);
    });
  }

  // ---------- ferramentas ----------

  static final _aleatorio = Random();

  /// Área de transferência do Ctrl+C/Ctrl+V (estática: copia de um quadro e cola em outro).
  static List<Elemento> _copiados = const [];
  static int _colagens = 0;
  String _novoId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36) + _aleatorio.nextInt(1 << 30).toRadixString(36);

  // O id do traço vivo só vale quando ele entra no editor; até lá é descartável.
  Traco _traco() => Traco(
    _elementoVivo?.id ?? _novoId(),
    pincel: _emUso == Ferramenta.marcador ? Pincel.marcador : Pincel.caneta,
    cor: _estojo.corDe(_emUso!),
    espessura: _estojo.espessuraDe(_emUso!),
    pontos: List.unmodifiable(_pontos),
  );

  /// Shift prende a reta/seta em 45° e faz retângulo/elipse virarem quadrado/círculo.
  Forma _forma(TipoForma tipo, Offset fim) {
    var b = fim;
    if (HardwareKeyboard.instance.isShiftPressed) {
      final d = fim - _inicio;
      if (tipo == TipoForma.reta || tipo == TipoForma.seta) {
        final angulo = (d.direction / (pi / 4)).round() * (pi / 4);
        b = _inicio + Offset.fromDirection(angulo, d.distance);
      } else {
        final lado = max(d.dx.abs(), d.dy.abs());
        b = _inicio + Offset(lado * d.dx.sign, lado * d.dy.sign);
      }
    }
    return Forma(
      _elementoVivo?.id ?? _novoId(),
      forma: tipo,
      a: _inicio,
      b: b,
      cor: _estojo.corDe(_emUso!),
      espessura: _estojo.espessuraDe(_emUso!),
    );
  }

  double get _raioBorracha => _estojo.espessuraDe(Ferramenta.borracha) / _camera.escala;

  void _apagar(Offset p) {
    final raio = _raioBorracha;
    _anel = (p, raio);
    _editor.remover({
      for (final e in _editor.elementos)
        if (e.toca(p, raio)) e.id,
    }, guardar: false);
    _vivo.avisar();
  }

  // ---------- seleção ----------

  Rect? get _caixa {
    if (_estojo.ferramenta != Ferramenta.selecao || _selecionados.isEmpty) return null;
    if (_arrastados.isNotEmpty) return limitesDe(_arrastados.where((e) => _selecionados.contains(e.id)));
    return limitesDe(_editor.elementos.where((e) => _selecionados.contains(e.id)));
  }

  List<Elemento> get _elementosSelecionados => [
    for (final e in _editor.elementos)
      if (_selecionados.contains(e.id)) e,
  ];

  static bool get _ctrl => HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;

  /// [ids] mais os outros elementos dos grupos deles (grupo é selecionado inteiro).
  Set<String> _comGrupos(Set<String> ids) {
    final grupos = {
      for (final e in _editor.elementos)
        if (e.grupo.isNotEmpty && ids.contains(e.id)) e.grupo,
    };
    if (grupos.isEmpty) return ids;
    return {
      ...ids,
      for (final e in _editor.elementos)
        if (grupos.contains(e.grupo)) e.id,
    };
  }

  /// O elemento de cima sob [p] (blocos e figuras têm preferência sobre as setas que passam por cima).
  Elemento? _tocadoEm(Offset p) {
    final raio = 8 / _camera.escala;
    final sob = _editor.elementos.reversed.where((e) => e.toca(p, raio));
    return sob.where((e) => e is! Ligacao).firstOrNull ?? sob.firstOrNull;
  }

  /// Laço com Ctrl soma à seleção que já havia.
  bool _somando = false;

  /// Canto da caixa → redimensiona pelo canto oposto; dentro da caixa → move; em cima de um
  /// elemento → seleciona e já arrasta; no vazio → laço novo. Com Ctrl: o elemento tocado entra
  /// na seleção (ou sai, se já estava) e o laço soma.
  void _iniciarSelecao(Offset tela) {
    final caixa = _caixa;
    _tocouSelecionado = false;
    _somando = _ctrl;
    if (_somando) {
      final tocado = _tocadoEm(_inicio);
      if (tocado != null) {
        final ids = _comGrupos({tocado.id});
        _selecionados = _selecionados.contains(tocado.id) ? _selecionados.difference(ids) : {..._selecionados, ...ids};
        if (_selecionados.isEmpty) {
          setState(() {});
          return;
        }
        _modo = _ModoSelecao.mover;
      }
    } else if (caixa != null) {
      final emTela = Rect.fromPoints(_camera.paraTela(caixa.topLeft), _camera.paraTela(caixa.bottomRight));
      final i = cantos(emTela).indexWhere((c) => (c - tela).distance < 18);
      if (i >= 0) {
        _ancora = cantos(caixa)[(i + 2) % 4];
        _modo = _ModoSelecao.escalar;
      } else if (emTela.inflate(8).contains(tela)) {
        _modo = _ModoSelecao.mover;
        _tocouSelecionado = true;
      }
    }
    if (_modo == null && !_somando) {
      final tocado = _tocadoEm(_inicio);
      if (tocado != null) {
        _selecionados = _comGrupos({tocado.id});
        _modo = _ModoSelecao.mover;
      }
    }
    if (_modo == null) {
      _modo = _ModoSelecao.laco;
      _laco = [_inicio];
      if (!_somando) setState(() => _selecionados = {});
      return;
    }
    _originais = {for (final e in _elementosSelecionados) e.id: e};
    if (_modo == _ModoSelecao.mover) {
      // Contêiner leva junto o que está dentro dele (como a raia do draw.io).
      for (final c in [..._originais.values.whereType<NoFluxo>().where((n) => n.tipo == TipoNo.container)]) {
        for (final e in dentroDe(c, _editor.elementos)) {
          _originais.putIfAbsent(e.id, () => e);
        }
      }
    }
    _arrastados = _comSetas([..._originais.values]);
    setState(() => _ocultos = {for (final e in _arrastados) e.id});
  }

  /// Toque sem arrastar num elemento que já estava selecionado: edita o texto dele.
  bool _tocouSelecionado = false;

  /// [movidos] mais as setas ligadas aos blocos movidos, já com as pontas nas posições novas (para
  /// as setas acompanharem o arrasto ao vivo).
  List<Elemento> _comSetas(List<Elemento> movidos) {
    final blocos = {
      for (final e in movidos)
        if (e is NoFluxo) e.id,
    };
    if (blocos.isEmpty) return movidos;
    final trocados = {for (final e in movidos) e.id: e};
    final setas = religar([for (final e in _editor.elementos) trocados[e.id] ?? e], soDosBlocos: blocos)
        .whereType<Ligacao>()
        .where((l) => !trocados.containsKey(l.id) && (blocos.contains(l.de) || blocos.contains(l.para)));
    return [...movidos, ...setas];
  }

  void _arrastarSelecao(Offset p) {
    switch (_modo) {
      case _ModoSelecao.laco:
        _laco.add(p);
      case _ModoSelecao.mover:
        final d = p - _inicio;
        _arrastados = _comSetas([for (final e in _originais.values) e.transformar((q) => q + d)]);
      case _ModoSelecao.escalar:
        final unico = _originais.length == 1 ? _originais.values.first : null;
        if (unico is NoFluxo) {
          // Bloco sozinho: largura e altura livres, com um tamanho mínimo legível.
          final r = Rect.fromPoints(_ancora, p);
          final w = max(48.0, r.width), h = max(32.0, r.height);
          final canto = Offset(
            p.dx < _ancora.dx ? _ancora.dx - w : _ancora.dx,
            p.dy < _ancora.dy ? _ancora.dy - h : _ancora.dy,
          );
          _arrastados = _comSetas([unico.comRetangulo(canto & Size(w, h))]);
          return;
        }
        final antes = (_inicio - _ancora).distance;
        if (antes < 1) return;
        final fator = max(0.05, (p - _ancora).distance / antes);
        _arrastados = _comSetas([
          for (final e in _originais.values) e.transformar((q) => _ancora + (q - _ancora) * fator, fator: fator),
        ]);
      case null:
        break;
    }
  }

  void _soltarSelecao(Offset fim) {
    if (_modo == _ModoSelecao.laco) {
      var escolhidos = {
        for (final e in _editor.elementos)
          if (e.dentroDoLaco(_laco)) e.id,
      };
      // Toque sem laço: pega o elemento de cima que está sob o dedo/cursor.
      if (escolhidos.isEmpty && (fim - _inicio).distance * _camera.escala < 8) {
        final tocado = _editor.elementos.reversed.where((e) => e.toca(fim, 8 / _camera.escala)).firstOrNull;
        escolhidos = {?tocado?.id};
      }
      escolhidos = _comGrupos(escolhidos);
      setState(() => _selecionados = _somando ? {..._selecionados, ...escolhidos} : escolhidos);
    } else if (_arrastados.isNotEmpty && (fim - _inicio).distance * _camera.escala >= 1) {
      _editor.substituir({for (final e in _arrastados) e.id: e});
    } else if (_tocouSelecionado && !_somando && _selecionados.length == 1) {
      _fimDoArrasto();
      _editarTextoSelecionado();
      return;
    }
    _fimDoArrasto();
  }

  void _fimDoArrasto() {
    _modo = null;
    _laco = [];
    _arrastados = [];
    _originais = {};
    setState(() => _ocultos = const {});
  }

  void _selecionarTudo() {
    _estojo.ferramenta = Ferramenta.selecao;
    setState(() => _selecionados = {for (final e in _editor.elementos) e.id});
  }

  void _excluirSelecao() {
    _editor.remover(_selecionados);
    setState(() => _selecionados = {});
  }

  void _duplicarSelecao() => _colarElementos(_elementosSelecionados, Offset(24, 24) / _camera.escala);

  /// Ctrl+C: guarda a seleção (vale entre quadros e páginas enquanto o app está aberto).
  void _copiarSelecao() {
    if (_selecionados.isEmpty) return;
    setState(() {
      _copiados = _elementosSelecionados;
      _colagens = 0;
    });
  }

  /// Ctrl+V: cola o que foi copiado, um passo deslocado a cada colagem.
  void _colar() {
    if (_copiados.isEmpty) return;
    _colagens++;
    _colarElementos(_copiados, Offset(24, 24) * _colagens.toDouble() / _camera.escala);
  }

  void _colarElementos(List<Elemento> fonte, Offset d) {
    final novos = {for (final e in fonte) e.id: _novoId()};
    // A cópia de um grupo vira outro grupo (não se junta ao original).
    final grupos = {
      for (final e in fonte)
        if (e.grupo.isNotEmpty) e.grupo: _novoId(),
    };
    final copias = <Elemento>[
      for (final e in fonte)
        if (e is! Ligacao)
          e.transformar((q) => q + d, id: novos[e.id], grupo: grupos[e.grupo])
        // A cópia da seta liga as cópias dos blocos; sem os dois blocos copiados, ela não vem.
        else if (novos.containsKey(e.de) && novos.containsKey(e.para))
          e.comBlocos(novos[e.de]!, novos[e.para]!).transformar((q) => q + d, id: novos[e.id], grupo: grupos[e.grupo]),
    ];
    _editor.adicionarVarios(copias);
    setState(() => _selecionados = {for (final e in copias) e.id});
  }

  /// Ctrl+G: junta a seleção num grupo só (grupos que estavam nela se fundem).
  void _agrupar() {
    if (_selecionados.length < 2) return;
    final g = _novoId();
    _editor.substituir({for (final e in _elementosSelecionados) e.id: e.comGrupo(g)});
    setState(() {});
  }

  /// Ctrl+Shift+G: desfaz os grupos da seleção (os elementos continuam selecionados).
  void _desagrupar() {
    final emGrupo = _elementosSelecionados.where((e) => e.grupo.isNotEmpty);
    if (emGrupo.isEmpty) return;
    _editor.substituir({for (final e in emGrupo) e.id: e.comGrupo('')});
    setState(() {});
  }

  /// Tabela nova 3 × 3 no centro da tela, já aberta para preencher.
  Future<void> _inserirTabela() async {
    final centro = _camera.paraMundo((context.size ?? const Size(800, 600)).center(Offset.zero));
    final base = Tabela.nova(_novoId(), centro, 3, 3);
    final t = base.copia(origem: centro - Offset(base.retangulo.width / 2, base.retangulo.height / 2));
    _editor.adicionar(t);
    setState(() {
      _estojo.ferramenta = Ferramenta.selecao;
      _selecionados = {t.id};
    });
    await _editarTextoSelecionado();
  }

  /// Copia a imagem escolhida no Google para o servidor e põe em [em] (mundo) ou no centro da tela
  /// (lado maior até 320).
  Future<void> _inserirImagem(Map<String, dynamic> r, {Offset? em}) async {
    final id = await _editor.api.guardarImagem(r['url'] as String);
    if (!mounted) return;
    final w = (r['largura'] as num? ?? 0).toDouble(), h = (r['altura'] as num? ?? 0).toDouble();
    final escala = w > 0 && h > 0 ? 320 / max(w, h) : 1.0;
    final tamanho = w > 0 && h > 0 ? Size(w * escala, h * escala) : const Size(240, 240);
    final centro = em ?? _camera.paraMundo(_tela.center(Offset.zero));
    final e = Imagem(
      _novoId(),
      a: centro - Offset(tamanho.width / 2, tamanho.height / 2),
      b: centro + Offset(tamanho.width / 2, tamanho.height / 2),
      imagem: id,
      titulo: '${r['titulo'] ?? ''}',
    );
    _editor.adicionar(e);
    setState(() {
      _estojo.ferramenta = Ferramenta.selecao;
      _selecionados = {e.id};
    });
  }

  /// Camadas: 2 = para a frente de tudo, 1 = uma para a frente, -1 = uma para trás, -2 = para trás de tudo.
  void _moverCamada(int passo) {
    if (_selecionados.isEmpty) return;
    final ids = [for (final e in _editor.elementos) e.id];
    final sel = _selecionados;
    switch (passo) {
      case 2:
        _editor.reordenar([...ids.where((i) => !sel.contains(i)), ...ids.where(sel.contains)]);
      case -2:
        _editor.reordenar([...ids.where(sel.contains), ...ids.where((i) => !sel.contains(i))]);
      case 1:
        for (var i = ids.length - 2; i >= 0; i--) {
          if (sel.contains(ids[i]) && !sel.contains(ids[i + 1])) ids.insert(i + 1, ids.removeAt(i));
        }
        _editor.reordenar(ids);
      case -1:
        for (var i = 1; i < ids.length; i++) {
          if (sel.contains(ids[i]) && !sel.contains(ids[i - 1])) ids.insert(i - 1, ids.removeAt(i));
        }
        _editor.reordenar(ids);
    }
  }

  void _recolorirSelecao(Color cor) =>
      _editor.substituir({for (final e in _elementosSelecionados) e.id: e.transformar((q) => q, cor: cor)});

  /// Cor da paleta: recolore a seleção (ferramenta Seleção) ou vira a cor da ferramenta.
  void _usarCor(Color c) {
    if (_estojo.ferramenta == Ferramenta.selecao) {
      _estojo.lembrarCor(c);
      _recolorirSelecao(c);
    } else {
      _estojo.cor = c;
    }
  }

  Future<void> _maisCores() async {
    final c = await escolherCor(context, _estojo.cor, _estojo.recentes, paleta: coresRapidas);
    if (c != null) _usarCor(c);
  }

  Future<void> _exportar(FormatoExportacao formato, {bool soSelecao = false}) async {
    final mensageiro = ScaffoldMessenger.of(context);
    try {
      final salvo = await exportar(
        _editor.titulo,
        soSelecao ? _elementosSelecionados : _editor.elementos,
        _editor.fundo,
        formato,
        escuro: _escuro,
      );
      if (salvo) mensageiro.showSnackBar(SnackBar(content: Text('${formato.name.toUpperCase()} exportado')));
    } catch (e) {
      mensageiro.showSnackBar(SnackBar(content: Text('Não exportou: $e')));
    }
  }

  void _animarLaser() {
    final limite = DateTime.now().subtract(PintorVivo.duracaoLaser);
    _laser.removeWhere((p) => p.$2.isBefore(limite));
    if (_laser.isEmpty && _emUso != Ferramenta.laser) _relogio.stop();
    _vivo.avisar();
  }

  void _escreverTexto(Offset posicao) => _digitar(
    Texto(
      _novoId(),
      posicao: posicao,
      texto: '',
      cor: _estojo.corDe(Ferramenta.texto),
      tamanho: _estojo.espessuraDe(Ferramenta.texto),
    ),
  );

  // ---------- digitação no quadro ----------

  void _digitar(Elemento e) {
    _concluirTexto();
    final texto = switch (e) {
      NoFluxo() => e.texto,
      Texto() => e.texto,
      _ => '',
    };
    _campoTexto.value = TextEditingValue(
      text: texto,
      selection: TextSelection(baseOffset: 0, extentOffset: texto.length),
    );
    setState(() => _digitando = e);
    _focoTexto.requestFocus();
  }

  /// Grava o que foi digitado (Esc ou toque fora). Usa a versão atual do elemento para não desfazer
  /// estilo mudado no painel durante a digitação; texto solto vazio some.
  void _concluirTexto() {
    final e = _digitando;
    if (e == null) return;
    final atual = _editor.elementos.where((x) => x.id == e.id).firstOrNull;
    final t = _campoTexto.text.trim();
    setState(() => _digitando = null);
    _focoQuadro.requestFocus();
    switch (atual ?? e) {
      case NoFluxo n when t != n.texto:
        _editor.substituir({n.id: n.comTexto(t)});
      case Texto x when t.isEmpty:
        if (atual != null) _editor.remover({x.id});
      case Texto x when t != x.texto:
        final novo = Texto(x.id, grupo: x.grupo, posicao: x.posicao, texto: t, cor: x.cor, tamanho: x.tamanho);
        atual == null ? _editor.adicionar(novo) : _editor.substituir({x.id: novo});
      default:
    }
  }

  /// Envolve o trecho selecionado do campo nas marcas que `textoFormatado` desenha.
  void _formatar(String marca) {
    final sel = _campoTexto.selection;
    final t = _campoTexto.text;
    final ini = sel.isValid ? sel.start : t.length, fim = sel.isValid ? sel.end : t.length;
    _campoTexto.value = TextEditingValue(
      text: t.replaceRange(ini, fim, '$marca${t.substring(ini, fim)}$marca'),
      selection: TextSelection(baseOffset: ini + marca.length, extentOffset: fim + marca.length),
    );
    _focoTexto.requestFocus();
  }

  /// Campo por cima do elemento em digitação, com a mesma área, fonte e alinhamento da pintura.
  Widget _campoNoQuadro() => ListenableBuilder(
    listenable: Listenable.merge([_mudouCamera, _campoTexto]),
    builder: (context, _) {
      final e = _editor.elementos.where((x) => x.id == _digitando!.id).firstOrNull ?? _digitando!;
      final s = _camera.escala;
      Widget campo(TextStyle estilo, TextAlign alinhamento) => CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): _concluirTexto},
        child: TextField(
          controller: _campoTexto,
          focusNode: _focoTexto,
          maxLines: null,
          style: estilo,
          textAlign: alinhamento,
          cursorColor: estilo.color,
          decoration: const InputDecoration.collapsed(hintText: ''),
          onTapOutside: (_) => _concluirTexto(),
        ),
      );
      switch (e) {
        case NoFluxo n:
          final r = Rect.fromPoints(_camera.paraTela(n.retangulo.topLeft), _camera.paraTela(n.retangulo.bottomRight));
          final container = n.tipo == TipoNo.container;
          final estilo = TextStyle(
            color: tinta(n.corTexto ?? const Color(0xFF111111), _escuro),
            fontSize: (container ? 14 : 15) * s,
            height: 1.2,
            fontWeight: container ? FontWeight.w600 : null,
          );
          if (container) {
            return Positioned(
              left: r.left + 8 * s,
              top: r.top,
              width: max(20, r.width - 16 * s),
              height: NoFluxo.alturaTitulo * s,
              child: Align(alignment: Alignment.centerLeft, child: campo(estilo, TextAlign.left)),
            );
          }
          final estreito = n.tipo == TipoNo.decisao || n.tipo == TipoNo.circulo || n.tipo == TipoNo.hexagono;
          final largura = n.esquerda ? r.width - 16 * s : r.width * (estreito ? 0.62 : 0.82);
          final esquerda = n.tipo == TipoNo.nota || n.esquerda;
          return Positioned.fromRect(
            rect: Rect.fromCenter(center: r.center, width: max(20, largura), height: r.height),
            child: Center(child: campo(estilo, esquerda ? TextAlign.left : TextAlign.center)),
          );
        case Texto t:
          final estilo = TextStyle(color: tinta(t.cor, _escuro), fontSize: t.tamanho * s, height: 1.25);
          final medida = TextPainter(
            text: TextSpan(text: _campoTexto.text.isEmpty ? ' ' : _campoTexto.text, style: estilo),
            textDirection: TextDirection.ltr,
          )..layout();
          final p = _camera.paraTela(t.posicao);
          return Positioned(
            left: p.dx,
            top: p.dy,
            width: max(40, medida.width + 4 * s),
            child: campo(estilo, TextAlign.left),
          );
        default:
          return const SizedBox.shrink();
      }
    },
  );

  // ---------- fluxograma ----------

  /// Bloco de fluxo inserido à mão no centro da tela (ou em [em], no mundo, ao soltar arrastando).
  void _inserirBloco(TipoNo tipo, {Offset? em}) {
    final centro = em ?? _camera.paraMundo(_tela.center(Offset.zero));
    final tamanho = switch (tipo) {
      TipoNo.decisao => const Size(200, 120),
      TipoNo.circulo => const Size(110, 110),
      TipoNo.quadrado => const Size(140, 140),
      TipoNo.banco => const Size(110, 100),
      TipoNo.nota => const Size(200, 110),
      TipoNo.container => const Size(420, 300),
      _ => const Size(190, 80),
    };
    final no = NoFluxo(
      _novoId(),
      tipo: tipo,
      texto: tipo == TipoNo.inicio ? 'Início' : tipo.rotulo,
      a: centro - Offset(tamanho.width / 2, tamanho.height / 2),
      b: centro + Offset(tamanho.width / 2, tamanho.height / 2),
      cor: coresDoFluxo[tipo]!,
    );
    _editor.adicionar(no);
    setState(() {
      _estojo.ferramenta = Ferramenta.selecao;
      _selecionados = {no.id};
    });
  }

  /// Seta do primeiro bloco selecionado para o segundo, com rótulo opcional ("Sim", "Não"…).
  Future<void> _ligarSelecionados() async {
    final nos = _elementosSelecionados.whereType<NoFluxo>().toList();
    if (nos.length != 2) return;
    final rotulo = await _perguntar('Rótulo da seta (opcional)', '');
    if (rotulo == null) return;
    final l = Ligacao(
      _novoId(),
      de: nos[0].id,
      para: nos[1].id,
      a: Offset.zero,
      b: Offset.zero,
      cor: const Color(0xFF37474F),
      rotulo: rotulo.trim(),
      fluxo: nos[0].fluxo,
      ortogonal: true,
    );
    _editor.adicionar(l);
  }

  /// Edita o texto do único elemento selecionado (texto solto, bloco ou rótulo da seta).
  Future<void> _editarTextoSelecionado() async {
    final e = _elementosSelecionados.singleOrNull;
    switch (e) {
      case Texto() || NoFluxo():
        _digitar(e!);
      case Ligacao():
        final t = await _perguntar('Rótulo da seta', e.rotulo);
        if (t != null) {
          _editor.substituir({e.id: e.copia(rotulo: t.trim())});
        }
      case Tabela():
        final t = await editarTabela(context, e, _estojo);
        if (t != null) _editor.substituir({e.id: t});
      default:
    }
  }

  /// Seta sendo puxada de uma alça: bloco de origem e a ponta (no mundo).
  (NoFluxo, Offset)? _puxando;

  /// Ponta de uma seta sendo arrastada para outro bloco: a seta e se é a ponta final ([fim]).
  (Ligacao, bool)? _religando;

  /// Seta única selecionada: alças nas duas pontas para trocar o bloco (e o lado) de saída/chegada.
  List<Widget> _alcasDaSeta() {
    if (_estojo.ferramenta != Ferramenta.selecao || _arrastados.isNotEmpty || _selecionados.length != 1) {
      return const [];
    }
    final l = _elementosSelecionados.firstOrNull;
    if (l is! Ligacao) return const [];
    final blocos = {for (final n in _editor.elementos.whereType<NoFluxo>()) n.id: n};
    return [
      Positioned.fill(
        child: IgnorePointer(
          child: ListenableBuilder(
            listenable: _vivo,
            builder: (_, _) => CustomPaint(painter: _PintorPuxada(_puxando, _camera)),
          ),
        ),
      ),
      for (final fim in [false, true])
        ListenableBuilder(
          listenable: Listenable.merge([_mudouCamera, _vivo]),
          builder: (context, _) {
            final ponta = _religando?.$1.id == l.id && _religando?.$2 == fim ? _puxando?.$2 : null;
            final c = _camera.paraTela(ponta ?? (fim ? l.b : l.a));
            final fixo = blocos[fim ? l.de : l.para];
            return Positioned(
              left: c.dx - 9,
              top: c.dy - 9,
              child: Tooltip(
                message: fim ? 'Arraste para trocar onde a seta chega' : 'Arraste para trocar de onde a seta sai',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: fixo == null
                      ? null
                      : (_) {
                          _religando = (l, fim);
                          _puxando = (fixo, fim ? l.b : l.a);
                        },
                  onPanUpdate: (d) {
                    final atual = _puxando;
                    if (atual == null || _religando == null) return;
                    _puxando = (atual.$1, atual.$2 + d.delta / _camera.escala);
                    _vivo.avisar();
                  },
                  onPanEnd: (_) => _soltarPontaDaSeta(),
                  onPanCancel: () {
                    _religando = null;
                    _puxando = null;
                    _vivo.avisar();
                  },
                  child: MouseRegion(
                    cursor: SystemMouseCursors.move,
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: fim ? Theme.of(context).colorScheme.primary : Colors.white,
                        shape: BoxShape.circle,
                        border: Border.all(color: Theme.of(context).colorScheme.primary, width: 3),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
    ];
  }

  /// Soltou a ponta da seta: no bloco sob o cursor, liga nele pelo lado mais perto de onde soltou.
  void _soltarPontaDaSeta() {
    final religando = _religando, puxada = _puxando;
    _religando = null;
    _puxando = null;
    _vivo.avisar();
    if (religando == null || puxada == null) return;
    final (l, fim) = religando;
    final ponta = puxada.$2;
    final alvo = _editor.elementos.reversed
        .whereType<NoFluxo>()
        .where((n) => n.retangulo.inflate(12 / _camera.escala).contains(ponta))
        .firstOrNull;
    if (alvo == null) return;
    final r = alvo.retangulo;
    final meios = [r.topCenter, r.centerRight, r.bottomCenter, r.centerLeft];
    var lado = 0;
    for (var i = 1; i < 4; i++) {
      if ((meios[i] - ponta).distance < (meios[lado] - ponta).distance) lado = i;
    }
    _editor.substituir({l.id: fim ? l.copia(para: alvo.id, ladoPara: lado) : l.copia(de: alvo.id, ladoDe: lado)});
  }

  /// Bloco único selecionado (mostra as alças de ligação), fora de um arrasto.
  NoFluxo? get _blocoComAlcas {
    if (_estojo.ferramenta != Ferramenta.selecao || _arrastados.isNotEmpty || _selecionados.length != 1) {
      return null;
    }
    final e = _elementosSelecionados.firstOrNull;
    return e is NoFluxo ? e : null;
  }

  /// Quatro alças no meio das bordas do bloco selecionado: puxar até outro bloco cria a seta;
  /// soltar no vazio cria um bloco novo ligado e já abre o texto dele.
  List<Widget> _alcasDeLigacao() {
    final no = _blocoComAlcas;
    if (no == null) return const [];
    return [
      Positioned.fill(
        child: IgnorePointer(
          child: ListenableBuilder(
            listenable: _vivo,
            builder: (_, _) => CustomPaint(painter: _PintorPuxada(_puxando, _camera)),
          ),
        ),
      ),
      for (final borda in [
        no.retangulo.topCenter,
        no.retangulo.centerRight,
        no.retangulo.bottomCenter,
        no.retangulo.centerLeft,
      ])
        ListenableBuilder(
          listenable: _mudouCamera,
          builder: (context, _) {
            final c =
                _camera.paraTela(borda) +
                (_camera.paraTela(borda) - _camera.paraTela(no.retangulo.center)) /
                    max(1, (borda - no.retangulo.center).distance) *
                    14;
            return Positioned(
              left: c.dx - 12,
              top: c.dy - 12,
              child: Tooltip(
                message: 'Arraste até outro bloco (ou para o vazio, criando um novo)',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (d) => _puxando = (no, _camera.paraMundo(c)),
                  onPanUpdate: (d) {
                    final atual = _puxando;
                    if (atual == null) return;
                    _puxando = (atual.$1, atual.$2 + d.delta / _camera.escala);
                    _vivo.avisar();
                  },
                  onPanEnd: (_) => _soltarPuxada(),
                  onPanCancel: () {
                    _puxando = null;
                    _vivo.avisar();
                  },
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: const Icon(Icons.add, size: 16, color: Colors.white),
                  ),
                ),
              ),
            );
          },
        ),
    ];
  }

  Future<void> _soltarPuxada() async {
    final puxada = _puxando;
    _puxando = null;
    _vivo.avisar();
    if (puxada == null) return;
    final (origem, ponta) = puxada;
    if (origem.retangulo.inflate(8).contains(ponta)) return;
    final alvo = _editor.elementos.reversed
        .whereType<NoFluxo>()
        .where((n) => n.id != origem.id && n.retangulo.inflate(12 / _camera.escala).contains(ponta))
        .firstOrNull;
    final novo = alvo == null
        ? NoFluxo(
            _novoId(),
            tipo: TipoNo.processo,
            texto: 'Nova etapa',
            a: ponta - const Offset(95, 40),
            b: ponta + const Offset(95, 40),
            cor: coresDoFluxo[TipoNo.processo]!,
            fluxo: origem.fluxo,
          )
        : null;
    final seta = Ligacao(
      _novoId(),
      de: origem.id,
      para: alvo?.id ?? novo!.id,
      a: Offset.zero,
      b: Offset.zero,
      cor: const Color(0xFF37474F),
      fluxo: origem.fluxo,
      ortogonal: true,
    );
    _editor.adicionarVarios([?novo, seta]);
    if (novo != null) {
      setState(() => _selecionados = {novo.id});
      await _editarTextoSelecionado();
    } else if (origem.tipo == TipoNo.decisao) {
      // Saída de decisão quase sempre tem rótulo (Sim/Não).
      final r = await _perguntar('Rótulo da seta (ex.: Sim, Não)', '');
      if (r != null && r.trim().isNotEmpty) {
        final atual = _editor.elementos.whereType<Ligacao>().where((l) => l.id == seta.id).firstOrNull;
        if (atual != null) {
          _editor.substituir({seta.id: atual.copia(rotulo: r.trim())});
        }
      }
    }
  }

  Future<String?> _perguntar(String titulo, String inicial) =>
      editarTextoFormatado(context, titulo: titulo, inicial: inicial, confirmar: 'OK', formatar: false);

  List<String>? _provedoresFluxo;

  /// Fluxo com IA: descreve, manda código ou ajusta o fluxo da seleção (ou o último do quadro).
  Future<void> _fluxoComIa() async {
    final mensageiro = ScaffoldMessenger.of(context);
    try {
      _provedoresFluxo ??= await _editor.api.provedoresFluxo();
    } catch (_) {
      _provedoresFluxo = null;
      mensageiro.showSnackBar(const SnackBar(content: Text('Sem conexão com o servidor para a IA.')));
      return;
    }
    if (!mounted || _provedoresFluxo!.isEmpty) return;
    final selecionado = _elementosSelecionados.whereType<NoFluxo>().where((n) => n.fluxo.isNotEmpty).firstOrNull;
    final ultimo = _editor.elementos.whereType<NoFluxo>().where((n) => n.fluxo.isNotEmpty).lastOrNull;
    final idAtual = (selecionado ?? ultimo)?.fluxo;
    final pedido = await pedirFluxo(context, temFluxo: idAtual != null, provedores: _provedoresFluxo!);
    if (pedido == null || !mounted) return;
    final ajustar = pedido.modo == ModoFluxo.ajustar && idAtual != null;
    var cancelado = false;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        content: const Row(
          spacing: 16,
          children: [
            CircularProgressIndicator(),
            Expanded(child: Text('A IA está montando o fluxo…')),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancelado = true;
              Navigator.pop(c);
            },
            child: const Text('Cancelar'),
          ),
        ],
      ),
    );
    try {
      final fluxo = await _editor.api.gerarFluxo(
        pedido: pedido.pedido,
        codigo: pedido.codigo,
        arquivo: pedido.arquivo,
        atual: ajustar ? fluxoDoQuadro(_editor.elementos, idAtual) : null,
        provedor: pedido.provedor,
        cancelado: () => cancelado,
      );
      if (!mounted || cancelado) return;
      Navigator.of(context).pop();
      final antigos = {
        for (final e in _editor.elementos)
          if (ajustar && ((e is NoFluxo && e.fluxo == idAtual) || (e is Ligacao && e.fluxo == idAtual))) e.id,
      };
      final antigosLimites = limitesDe(_editor.elementos.where((e) => antigos.contains(e.id)));
      final resto = limitesDe(_editor.elementos.where((e) => !antigos.contains(e.id)));
      final origem = antigosLimites?.topLeft ?? (resto == null ? Offset.zero : Offset(resto.right + 200, resto.top));
      final novos = elementosDoFluxo(fluxo, origem, ajustar ? idAtual : _novoId());
      _editor.trocarGrupo(antigos, novos);
      setState(() => _selecionados = {});
      _moverCamera(() => _camera.enquadrar(limitesDe(novos), _tela));
    } catch (e) {
      if (!mounted || cancelado) return;
      Navigator.of(context).pop();
      mensageiro.showSnackBar(SnackBar(content: Text(e is ApiErro ? e.mensagem : 'A IA falhou: $e')));
    }
  }

  Future<void> _renomear() async {
    final controle = TextEditingController(text: _editor.titulo);
    final titulo = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Nome do quadro'),
        content: TextField(controller: controle, autofocus: true, onSubmitted: (v) => Navigator.pop(c, v)),
        actions: [FilledButton(onPressed: () => Navigator.pop(c, controle.text), child: const Text('Salvar'))],
      ),
    );
    controle.dispose();
    if (titulo == null || titulo.trim().isEmpty) return;
    await _editor.api.editar(_editor.id, titulo: titulo.trim());
    setState(() => _editor.titulo = titulo.trim());
  }

  Future<void> _mudarFundo(Fundo f) async {
    setState(() => _editor.fundo = f);
    await _editor.api.editar(_editor.id, fundo: f);
  }

  void _alternarProjecao() {
    setState(() => _projecao = !_projecao);
    SystemChrome.setEnabledSystemUIMode(_projecao ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
  }

  Map<ShortcutActivator, VoidCallback> get _atalhos => {
    const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _editor.desfazer,
    const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): _editor.desfazer,
    const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true): _editor.refazer,
    const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true): _editor.refazer,
    const SingleActivator(LogicalKeyboardKey.keyY, control: true): _editor.refazer,
    const SingleActivator(LogicalKeyboardKey.keyS, control: true): _editor.salvar,
    for (final f in Ferramenta.values) CharacterActivator(f.atalho): () => _estojo.ferramenta = f,
    const CharacterActivator('f'): _alternarProjecao,
    const CharacterActivator('0'): _enquadrar,
    const CharacterActivator('+'): () => _zoomCentro(1.25),
    const CharacterActivator('='): () => _zoomCentro(1.25),
    const CharacterActivator('-'): () => _zoomCentro(0.8),
    const SingleActivator(LogicalKeyboardKey.keyA, control: true): _selecionarTudo,
    const SingleActivator(LogicalKeyboardKey.keyD, control: true): _duplicarSelecao,
    const SingleActivator(LogicalKeyboardKey.keyG, control: true): _agrupar,
    const SingleActivator(LogicalKeyboardKey.keyG, control: true, shift: true): _desagrupar,
    const SingleActivator(LogicalKeyboardKey.keyC, control: true): _copiarSelecao,
    const SingleActivator(LogicalKeyboardKey.keyC, meta: true): _copiarSelecao,
    const SingleActivator(LogicalKeyboardKey.keyV, control: true): _colar,
    const SingleActivator(LogicalKeyboardKey.keyV, meta: true): _colar,
    const SingleActivator(LogicalKeyboardKey.bracketRight, control: true): () => _moverCamada(1),
    const SingleActivator(LogicalKeyboardKey.bracketLeft, control: true): () => _moverCamada(-1),
    const SingleActivator(LogicalKeyboardKey.bracketRight, control: true, shift: true): () => _moverCamada(2),
    const SingleActivator(LogicalKeyboardKey.bracketLeft, control: true, shift: true): () => _moverCamada(-2),
    const SingleActivator(LogicalKeyboardKey.delete): _excluirSelecao,
    const SingleActivator(LogicalKeyboardKey.backspace): _excluirSelecao,
    const SingleActivator(LogicalKeyboardKey.escape): () {
      if (_selecionados.isNotEmpty) {
        setState(() => _selecionados = {});
      } else if (_projecao) {
        _alternarProjecao();
      }
    },
  };

  MouseCursor get _cursor => switch (_estojo.ferramenta) {
    Ferramenta.mao => _navegando.isEmpty ? SystemMouseCursors.grab : SystemMouseCursors.grabbing,
    Ferramenta.texto => SystemMouseCursors.text,
    Ferramenta.borracha => SystemMouseCursors.none,
    Ferramenta.selecao => SystemMouseCursors.basic,
    _ => SystemMouseCursors.precise,
  };

  // ---------- montagem ----------

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_editor, _estojo]),
    builder: (context, _) => PopScope(
      onPopInvokedWithResult: (_, _) => _editor.salvar(),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        // Digitando (no quadro ou num campo como a busca de imagens), as teclas são do campo:
        // Backspace não pode apagar o bloco nem uma letra trocar de ferramenta.
        onKeyEvent: (_, evento) {
          if (_digitando != null || _emCampoDeTexto) return KeyEventResult.ignored;
          for (final MapEntry(key: atalho, value: acao) in _atalhos.entries) {
            if (atalho.accepts(evento, HardwareKeyboard.instance)) {
              acao();
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: Focus(
          focusNode: _focoQuadro,
          autofocus: true,
          child: LayoutBuilder(
            builder: (context, c) {
              _aoMudarPagina();
              // PC/notebook: formas e estilo fixos dos lados (como o draw.io); celular e tablet: gavetas.
              final largo = c.maxWidth >= 1100 && !_projecao;
              // ClipRect: o desenho fora da área do quadro não pode cobrir os painéis laterais.
              final area = ClipRect(
                child: Stack(
                  children: [
                    Positioned.fill(child: _alvoDeFormas(_quadro())),
                    ..._alcasDeLigacao(),
                    ..._alcasDaSeta(),
                    if (_digitando != null) _campoNoQuadro(),
                    if (_caixa != null)
                      Positioned(
                        top: _ladoBarra == _Lado.cima && !_barraOculta ? 72 : 8,
                        left: 8,
                        right: 8,
                        child: Center(child: _barraSelecao(context)),
                      ),
                    Positioned.fill(child: _barraPosicionada(context)),
                    Positioned(
                      right: _ladoBarra == _Lado.direita ? 76 : 12,
                      top: _projecao ? 12 : null,
                      bottom: _projecao ? null : (_ladoBarra == _Lado.baixo ? 76 : 12),
                      child: _zoom(context),
                    ),
                    if (_menuCaneta != null)
                      Positioned.fill(
                        child: MenuRadialCaneta(
                          centro: _menuCaneta!,
                          estojo: _estojo,
                          desfazer: _editor.podeDesfazer ? _editor.desfazer : null,
                          refazer: _editor.podeRefazer ? _editor.refazer : null,
                          maisCores: _maisCores,
                          fechar: () => setState(() => _menuCaneta = null),
                        ),
                      ),
                    if (_verImagens && !_projecao)
                      Positioned(
                        top: 0,
                        bottom: 0,
                        right: 0,
                        width: min(340, c.maxWidth * 0.85),
                        child: Material(
                          elevation: 6,
                          child: PainelImagens(
                            api: _editor.api,
                            inserir: _inserirImagem,
                            fechar: () => setState(() => _verImagens = false),
                          ),
                        ),
                      ),
                  ],
                ),
              );
              return Scaffold(
                appBar: _projecao ? null : _barraSuperior(context, largo: largo),
                drawer: largo || _projecao
                    ? null
                    : Drawer(width: 280, child: SafeArea(child: _painelFormas(fechar: true))),
                endDrawer: largo || _projecao ? null : Drawer(width: 300, child: SafeArea(child: _painelEstilo())),
                bottomNavigationBar: _projecao ? null : BarraPaginas(editor: _editor),
                body: largo
                    ? Row(
                        children: [
                          if (_verFormas) ...[
                            SizedBox(width: 236, child: _painelFormas()),
                            const VerticalDivider(width: 1),
                          ],
                          Expanded(child: area),
                          if (_verEstilo) ...[
                            const VerticalDivider(width: 1),
                            SizedBox(width: 280, child: _painelEstilo()),
                          ],
                        ],
                      )
                    : area,
              );
            },
          ),
        ),
      ),
    ),
  );

  Widget _quadro() => LayoutBuilder(
    builder: (context, c) {
      _tela = c.biggest;
      if (!_enquadrado) {
        _enquadrado = true;
        _camera.enquadrar(_editor.limites, _tela);
      }
      return Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _tocar,
        onPointerMove: _mover,
        onPointerUp: _soltar,
        onPointerCancel: _soltar,
        onPointerHover: _pairar,
        onPointerSignal: _rolar,
        onPointerPanZoomStart: (_) => _escalaTrackpad = 1,
        onPointerPanZoomUpdate: _trackpad,
        child: MouseRegion(
          cursor: _cursor,
          onExit: (_) {
            _anel = null;
            _vivo.avisar();
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(
                child: CustomPaint(
                  painter: PintorQuadro(
                    elementos: _digitando is NoFluxo
                        ? [
                            for (final e in _editor.elementos)
                              e is NoFluxo && e.id == _digitando!.id ? e.comTexto('') : e,
                          ]
                        : _editor.elementos,
                    camera: _camera,
                    fundo: _editor.fundo,
                    papel: _editor.papel,
                    escuro: _escuro,
                    ocultos: _digitando is Texto ? {..._ocultos, _digitando!.id} : _ocultos,
                    repintar: Listenable.merge([_mudouCamera, CacheImagens.instancia]),
                  ),
                ),
              ),
              CustomPaint(
                painter: PintorVivo(
                  vivo: () => _elementoVivo,
                  laser: () => _laser,
                  camera: _camera,
                  escuro: _escuro,
                  borracha: () => _anel,
                  arrastados: () => _arrastados,
                  laco: () => _laco,
                  caixa: () => _caixa,
                  repintar: Listenable.merge([_vivo, _mudouCamera]),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  String _paginaVista = '';

  /// Trocou de página: a seleção era da outra página e a câmera enquadra a nova.
  void _aoMudarPagina() {
    if (_paginaVista == _editor.paginaAtual) return;
    final primeira = _paginaVista.isEmpty && !_enquadrado;
    _paginaVista = _editor.paginaAtual;
    if (primeira) return;
    _selecionados = {};
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _enquadrar();
    });
  }

  Widget _painelFormas({bool fechar = false}) => Builder(
    builder: (context) => PainelFormas(
      inserir: (t) {
        if (fechar) Navigator.of(context).pop();
        _inserirBloco(t);
      },
      // Na gaveta (celular/tablet em pé), o véu dela cobre o quadro e engole o soltar: fecha ao pegar.
      aoArrastar: fechar ? () => Navigator.of(context).pop() : null,
      ferramenta: (f) {
        if (fechar) Navigator.of(context).pop();
        _estojo.ferramenta = f;
      },
    ),
  );

  Widget _painelEstilo() => DefaultTabController(
    length: 2,
    child: Column(
      children: [
        const TabBar(
          tabs: [
            Tab(text: 'Estilo', height: 40),
            Tab(text: 'Camadas', height: 40),
          ],
        ),
        Expanded(
          child: TabBarView(
            children: [
              _estilo(),
              PainelCamadas(
                elementos: _editor.elementos,
                selecionados: _selecionados,
                selecionar: (id, somar) {
                  _estojo.ferramenta = Ferramenta.selecao;
                  setState(
                    () => _selecionados = !somar
                        ? {id}
                        : _selecionados.contains(id)
                        ? ({..._selecionados}..remove(id))
                        : {..._selecionados, id},
                  );
                },
                reordenar: _editor.reordenar,
                moverCamada: _moverCamada,
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _estilo() => PainelEstilo(
    selecionados: _elementosSelecionados,
    aplicar: (novos) => _editor.substituir(novos),
    editarTexto: _editarTextoSelecionado,
    formatar: _digitando == null ? null : _formatar,
    recentes: _estojo.recentes,
    fundo: _editor.fundo,
    mudarFundo: _mudarFundo,
    exportar: [
      ('Imagem PNG', Icons.image_outlined, () => _exportar(FormatoExportacao.png)),
      ('PDF', Icons.picture_as_pdf_outlined, () => _exportar(FormatoExportacao.pdf)),
      ('draw.io (.drawio)', Icons.account_tree_outlined, _exportarDrawio),
    ],
  );

  /// Soltar uma forma arrastada do painel: cria o bloco onde o dedo/cursor soltou.
  Widget _alvoDeFormas(Widget filho) => DragTarget<TipoNo>(
    onAcceptWithDetails: (d) {
      final caixa = context.findRenderObject() as RenderBox?;
      final quadro = _chaveQuadro.currentContext?.findRenderObject() as RenderBox?;
      if (caixa == null || quadro == null) return;
      // o retorno do Draggable é a miniatura de 110×70: o centro dela é onde o bloco nasce
      final local = quadro.globalToLocal(d.offset + const Offset(55, 35));
      _inserirBloco(d.data, em: _camera.paraMundo(local));
    },
    builder: (_, _, _) => DragTarget<ImagemArrastada>(
      onAcceptWithDetails: (d) async {
        final quadro = _chaveQuadro.currentContext?.findRenderObject() as RenderBox?;
        if (quadro == null) return;
        // o retorno arrastado é a miniatura de 100×100: a imagem nasce centrada nela
        final em = _camera.paraMundo(quadro.globalToLocal(d.offset + const Offset(50, 50)));
        final mensageiro = ScaffoldMessenger.of(context);
        try {
          await _inserirImagem(d.data.resultado, em: em);
        } catch (e) {
          mensageiro.showSnackBar(SnackBar(content: Text('Não deu para usar a imagem: $e')));
        }
      },
      builder: (_, _, _) => KeyedSubtree(key: _chaveQuadro, child: filho),
    ),
  );

  final _chaveQuadro = GlobalKey();

  Future<void> _exportarDrawio() async {
    final mensageiro = ScaffoldMessenger.of(context);
    try {
      await _editor.salvar();
      final bytes = await _editor.api.baixarDrawio(_editor.id);
      final nome = _editor.titulo.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
      final salvo = await FilePicker.saveFile(
        fileName: '${nome.isEmpty ? 'quadro' : nome}.drawio',
        bytes: bytes,
        mimeType: 'application/xml',
      );
      if (salvo != null) mensageiro.showSnackBar(const SnackBar(content: Text('.drawio exportado')));
    } catch (e) {
      mensageiro.showSnackBar(SnackBar(content: Text('Não exportou: ${e is ApiErro ? e.mensagem : e}')));
    }
  }

  PreferredSizeWidget _barraSuperior(BuildContext context, {bool largo = false}) {
    // Celular e tablet em pé: os botões do quadro descem para uma segunda linha rolável; em cima fica
    // só título, salvo, desfazer/refazer e o menu ⋮ (senão a barra estoura e some o menu).
    final compacto = MediaQuery.sizeOf(context).width < 900;
    final ferramentas = <Widget>[
      if (largo) ...[
        IconButton(
          tooltip: _verFormas ? 'Ocultar painel de formas' : 'Mostrar painel de formas',
          isSelected: _verFormas,
          icon: const Icon(Icons.vertical_split_outlined),
          onPressed: () => setState(() => _verFormas = !_verFormas),
        ),
        IconButton(
          tooltip: _verEstilo ? 'Ocultar painel de estilo' : 'Mostrar painel de estilo',
          isSelected: _verEstilo,
          icon: Transform.flip(flipX: true, child: const Icon(Icons.vertical_split_outlined)),
          onPressed: () => setState(() => _verEstilo = !_verEstilo),
        ),
      ],
      if (!largo)
        Builder(
          builder: (c) => IconButton(
            tooltip: 'Formas',
            icon: const Icon(Icons.category_outlined),
            onPressed: () => Scaffold.of(c).openDrawer(),
          ),
        ),
      if (!largo)
        Builder(
          builder: (c) => IconButton(
            tooltip: 'Estilo',
            icon: const Icon(Icons.palette_outlined),
            onPressed: () => Scaffold.of(c).openEndDrawer(),
          ),
        ),
      ...widget.acoes,
    ];
    final extras = <Widget>[
      IconButton(
        tooltip: _estojo.dedoDesenha ? 'Dedo desenha (toque para só a caneta)' : 'Só a caneta desenha; dedo move',
        onPressed: () => _estojo.dedoDesenha = !_estojo.dedoDesenha,
        icon: Icon(_estojo.dedoDesenha ? Icons.touch_app : Icons.do_not_touch_outlined),
      ),
      IconButton(
        tooltip: 'Quadro escuro',
        onPressed: () => setState(() => _escuro = !_escuro),
        icon: Icon(_escuro ? Icons.dark_mode : Icons.light_mode_outlined),
      ),
      IconButton(tooltip: 'Fluxo com IA', onPressed: _fluxoComIa, icon: const Icon(Icons.auto_awesome)),
      IconButton(
        tooltip: 'Imagens, ícones e figuras (Google Imagens)',
        isSelected: _verImagens,
        onPressed: () => setState(() => _verImagens = !_verImagens),
        icon: const Icon(Icons.image_search),
      ),
      IconButton(tooltip: 'Projeção (F)', onPressed: _alternarProjecao, icon: const Icon(Icons.present_to_all)),
    ];
    return AppBar(
      title: InkWell(
        onTap: _renomear,
        child: Text(_editor.titulo, overflow: TextOverflow.ellipsis),
      ),
      bottom: compacto
          ? PreferredSize(
              preferredSize: const Size.fromHeight(48),
              child: Align(
                alignment: Alignment.centerLeft,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(children: [...ferramentas, ...extras]),
                ),
              ),
            )
          : null,
      actions: [
        if (!compacto) ...ferramentas,
        _IndicadorSalvo(_editor),
        IconButton(
          tooltip: 'Desfazer (Ctrl+Z)',
          onPressed: _editor.podeDesfazer ? _editor.desfazer : null,
          icon: const Icon(Icons.undo),
        ),
        IconButton(
          tooltip: 'Refazer (Ctrl+Shift+Z)',
          onPressed: _editor.podeRefazer ? _editor.refazer : null,
          icon: const Icon(Icons.redo),
        ),
        if (!compacto) ...extras,
        PopupMenuButton<VoidCallback>(
          onSelected: (acao) => acao(),
          itemBuilder: (_) => [
            for (final f in Fundo.values)
              CheckedPopupMenuItem(
                value: () => _mudarFundo(f),
                checked: _editor.fundo == f,
                child: Text('Fundo: ${f.rotulo}'),
              ),
            const PopupMenuDivider(),
            PopupMenuItem(value: _enquadrar, child: const Text('Ver tudo (0)')),
            PopupMenuItem(value: _selecionarTudo, child: const Text('Selecionar tudo (Ctrl+A)')),
            PopupMenuItem(value: _inserirTabela, child: const Text('Inserir tabela')),
            PopupMenuItem(
              value: () => setState(() => _verImagens = true),
              child: const Text('Inserir imagem (Google Imagens)'),
            ),
            PopupMenuItem(value: () => _exportar(FormatoExportacao.png), child: const Text('Exportar PNG')),
            PopupMenuItem(value: () => _exportar(FormatoExportacao.pdf), child: const Text('Exportar PDF')),
            PopupMenuItem(value: _exportarDrawio, child: const Text('Exportar draw.io (.drawio)')),
            PopupMenuItem(value: _editor.limpar, child: const Text('Limpar a página')),
          ],
        ),
      ],
    );
  }

  /// Na projeção a barra só tem o que se usa explicando: caneta, marcador, laser, borracha e mover.
  Widget _barraFerramentas(BuildContext context) {
    final esquema = Theme.of(context).colorScheme;
    final ferramentas = _projecao
        ? const [Ferramenta.caneta, Ferramenta.marcador, Ferramenta.laser, Ferramenta.borracha, Ferramenta.mao]
        : Ferramenta.values;
    final atual = _estojo.ferramenta;
    final vertical = _ladoBarra == _Lado.esquerda || _ladoBarra == _Lado.direita;
    final eixo = vertical ? Axis.vertical : Axis.horizontal;
    final divisor = vertical
        ? const SizedBox(width: 24, child: Divider())
        : const SizedBox(height: 24, child: VerticalDivider());
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(28),
      color: esquema.surfaceContainerHigh,
      child: SingleChildScrollView(
        scrollDirection: eixo,
        padding: vertical
            ? const EdgeInsets.symmetric(horizontal: 4, vertical: 8)
            : const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Flex(
          direction: eixo,
          mainAxisSize: MainAxisSize.min,
          children: [
            _alcaBarra(),
            for (final f in ferramentas)
              IconButton(
                tooltip: f.rotulo,
                isSelected: f == atual,
                style: IconButton.styleFrom(
                  backgroundColor: f == atual ? esquema.primaryContainer : null,
                  foregroundColor: f == atual ? esquema.onPrimaryContainer : null,
                ),
                onPressed: () => _estojo.ferramenta = f,
                icon: Icon(f.icone),
              ),
            if (atual.usaCor || _caixa != null) ...[
              divisor,
              for (final c in {...coresRapidas, ..._estojo.recentes.take(2)})
                _AmostraCor(c, selecionada: atual.usaCor && _estojo.cor == c, aoTocar: () => _usarCor(c)),
              IconButton(tooltip: 'Mais cores', onPressed: _maisCores, icon: const Icon(Icons.palette_outlined)),
            ],
            if (atual.usaEspessura)
              RotatedBox(
                quarterTurns: vertical ? 3 : 0,
                // Altura fixa: o Slider sozinho ocupa toda a altura livre e a barra cobria a tela.
                child: SizedBox(
                  width: 120,
                  height: 40,
                  child: Slider(
                    value: _estojo.espessura.clamp(1, 60),
                    min: 1,
                    max: 60,
                    onChanged: (v) => _estojo.espessura = v,
                  ),
                ),
              ),
            if (_projecao) ...[
              IconButton(onPressed: _editor.podeDesfazer ? _editor.desfazer : null, icon: const Icon(Icons.undo)),
              IconButton(
                tooltip: 'Quadro escuro',
                onPressed: () => setState(() => _escuro = !_escuro),
                icon: Icon(_escuro ? Icons.dark_mode : Icons.light_mode_outlined),
              ),
              IconButton(
                tooltip: 'Sair da projeção (Esc)',
                onPressed: _alternarProjecao,
                icon: const Icon(Icons.close),
              ),
            ],
            IconButton(
              tooltip: 'Ocultar ferramentas',
              onPressed: () => _ajustarBarra(oculta: true),
              icon: Icon(switch (_ladoBarra) {
                _Lado.baixo => Icons.keyboard_arrow_down,
                _Lado.cima => Icons.keyboard_arrow_up,
                _Lado.esquerda => Icons.keyboard_arrow_left,
                _Lado.direita => Icons.keyboard_arrow_right,
              }),
            ),
          ],
        ),
      ),
    );
  }

  /// Barra (ou, oculta, só o botão da ferramenta atual) presa ao lado escolhido; segue o dedo no
  /// arrasto pela alça.
  Widget _barraPosicionada(BuildContext context) => Align(
    key: _chaveAreaBarra,
    alignment: switch (_ladoBarra) {
      _Lado.baixo => Alignment.bottomCenter,
      _Lado.cima => Alignment.topCenter,
      _Lado.esquerda => Alignment.centerLeft,
      _Lado.direita => Alignment.centerRight,
    },
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Transform.translate(
        offset: _arrasteBarra,
        child: KeyedSubtree(
          key: _chaveBarra,
          child: _barraOculta
              ? GestureDetector(
                  onPanUpdate: (d) => setState(() => _arrasteBarra += d.delta),
                  onPanEnd: (_) => _soltarBarra(),
                  child: IconButton.filledTonal(
                    tooltip: 'Mostrar ferramentas (arraste para mudar de lado)',
                    onPressed: () => _ajustarBarra(oculta: false),
                    icon: Icon(_estojo.ferramenta.icone),
                  ),
                )
              : _barraFerramentas(context),
        ),
      ),
    ),
  );

  /// Arrastar move a barra para qualquer lado; tocar abre a escolha do lado.
  Widget _alcaBarra() => GestureDetector(
    onPanUpdate: (d) => setState(() => _arrasteBarra += d.delta),
    onPanEnd: (_) => _soltarBarra(),
    child: PopupMenuButton<_Lado>(
      tooltip: 'Arraste para mover a barra ou toque para escolher o lado',
      icon: const Icon(Icons.drag_indicator),
      initialValue: _ladoBarra,
      onSelected: (l) => _ajustarBarra(lado: l),
      itemBuilder: (_) => [for (final l in _Lado.values) PopupMenuItem(value: l, child: Text(l.rotulo))],
    ),
  );

  void _soltarBarra() {
    final area = _chaveAreaBarra.currentContext?.findRenderObject() as RenderBox?;
    final barra = _chaveBarra.currentContext?.findRenderObject() as RenderBox?;
    if (area == null || barra == null) {
      setState(() => _arrasteBarra = Offset.zero);
      return;
    }
    final c = area.globalToLocal(barra.localToGlobal(barra.size.center(Offset.zero)));
    final s = area.size;
    final distancias = {
      _Lado.cima: c.dy,
      _Lado.baixo: s.height - c.dy,
      _Lado.esquerda: c.dx,
      _Lado.direita: s.width - c.dx,
    };
    _ajustarBarra(lado: distancias.entries.reduce((a, b) => a.value <= b.value ? a : b).key);
  }

  void _ajustarBarra({_Lado? lado, bool? oculta}) {
    setState(() {
      _arrasteBarra = Offset.zero;
      if (lado != null) _ladoBarra = lado;
      if (oculta != null) _barraOculta = oculta;
    });
    unawaited(
      SharedPreferences.getInstance().then((p) async {
        await p.setString(_prefLado, _ladoBarra.name);
        await p.setBool(_prefOculta, _barraOculta);
      }),
    );
  }

  /// Foco num campo de texto (busca de imagens, nome do quadro…): os atalhos do quadro ficam quietos.
  static bool get _emCampoDeTexto =>
      FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() != null;

  Widget _barraSelecao(BuildContext context) => Material(
    elevation: 4,
    borderRadius: BorderRadius.circular(24),
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text('${_selecionados.length} selecionados'),
          ),
          if (_elementosSelecionados.length == 1 &&
              (_elementosSelecionados.first is Texto ||
                  _elementosSelecionados.first is NoFluxo ||
                  _elementosSelecionados.first is Ligacao ||
                  _elementosSelecionados.first is Tabela))
            IconButton(
              tooltip: _elementosSelecionados.first is Tabela
                  ? 'Editar tabela (linhas, colunas, células e cores)'
                  : 'Editar texto (negrito, itálico, sublinhado, marcador)',
              onPressed: _editarTextoSelecionado,
              icon: const Icon(Icons.edit_note),
            ),
          if (_elementosSelecionados.whereType<NoFluxo>().length == 2)
            IconButton(
              tooltip: 'Ligar os dois blocos com uma seta',
              onPressed: _ligarSelecionados,
              icon: const Icon(Icons.trending_flat),
            ),
          if (_selecionados.length > 1)
            IconButton(tooltip: 'Agrupar (Ctrl+G)', onPressed: _agrupar, icon: const Icon(Icons.join_full)),
          if (_elementosSelecionados.any((e) => e.grupo.isNotEmpty))
            IconButton(
              tooltip: 'Desagrupar (Ctrl+Shift+G)',
              onPressed: _desagrupar,
              icon: const Icon(Icons.join_inner),
            ),
          IconButton(
            tooltip: 'Duplicar (Ctrl+D)',
            onPressed: _duplicarSelecao,
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(tooltip: 'Copiar (Ctrl+C)', onPressed: _copiarSelecao, icon: const Icon(Icons.content_copy)),
          if (_copiados.isNotEmpty)
            IconButton(tooltip: 'Colar (Ctrl+V)', onPressed: _colar, icon: const Icon(Icons.content_paste)),
          IconButton(
            tooltip: 'Trazer para a frente (Ctrl+Shift+])',
            onPressed: () => _moverCamada(2),
            icon: const Icon(Icons.flip_to_front),
          ),
          IconButton(
            tooltip: 'Enviar para trás (Ctrl+Shift+[)',
            onPressed: () => _moverCamada(-2),
            icon: const Icon(Icons.flip_to_back),
          ),
          IconButton(
            tooltip: 'Exportar seleção (PNG)',
            onPressed: () => _exportar(FormatoExportacao.png, soSelecao: true),
            icon: const Icon(Icons.image_outlined),
          ),
          IconButton(
            tooltip: 'Exportar seleção (PDF)',
            onPressed: () => _exportar(FormatoExportacao.pdf, soSelecao: true),
            icon: const Icon(Icons.picture_as_pdf_outlined),
          ),
          IconButton(tooltip: 'Excluir (Delete)', onPressed: _excluirSelecao, icon: const Icon(Icons.delete_outline)),
          IconButton(
            tooltip: 'Desmarcar (Esc)',
            onPressed: () => setState(() => _selecionados = {}),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    ),
  );

  Widget _zoom(BuildContext context) => ListenableBuilder(
    listenable: _mudouCamera,
    builder: (context, _) =>
        ActionChip(tooltip: 'Ver tudo (0)', onPressed: _enquadrar, label: Text('${(_camera.escala * 100).round()}%')),
  );
}

enum _Lado {
  baixo('Embaixo'),
  cima('Em cima'),
  esquerda('À esquerda'),
  direita('À direita');

  const _Lado(this.rotulo);
  final String rotulo;
}

class _AmostraCor extends StatelessWidget {
  const _AmostraCor(this.cor, {required this.selecionada, required this.aoTocar});

  final Color cor;
  final bool selecionada;
  final VoidCallback aoTocar;

  @override
  Widget build(BuildContext context) => InkResponse(
    onTap: aoTocar,
    radius: 18,
    child: Container(
      margin: const EdgeInsets.all(4),
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: cor,
        shape: BoxShape.circle,
        border: Border.all(
          color: selecionada ? Theme.of(context).colorScheme.primary : Colors.black26,
          width: selecionada ? 3 : 1,
        ),
      ),
    ),
  );
}

class _IndicadorSalvo extends StatelessWidget {
  const _IndicadorSalvo(this.editor);

  final EditorQuadro editor;

  @override
  Widget build(BuildContext context) => switch (editor.estado) {
    EstadoSalvo.salvo => const Tooltip(message: 'Salvo', child: Icon(Icons.cloud_done_outlined)),
    EstadoSalvo.pendente ||
    EstadoSalvo.salvando => const Tooltip(message: 'Salvando…', child: Icon(Icons.cloud_upload_outlined)),
    EstadoSalvo.erro => IconButton(
      tooltip: editor.offline
          ? 'Sem conexão: guardado no aparelho, envia quando voltar'
          : 'Não salvou; toque para tentar de novo',
      onPressed: editor.salvar,
      icon: Icon(Icons.cloud_off, color: Theme.of(context).colorScheme.error),
    ),
  };
}

/// Linha tracejada da alça até o dedo/cursor enquanto a seta é puxada.
class _PintorPuxada extends CustomPainter {
  _PintorPuxada(this.puxando, this.camera);

  final (NoFluxo, Offset)? puxando;
  final Camera camera;

  @override
  void paint(Canvas canvas, Size size) {
    final p = puxando;
    if (p == null) return;
    final de = camera.paraTela(p.$1.borda(p.$2)), ate = camera.paraTela(p.$2);
    final pincel = Paint()
      ..color = const Color(0xFF1E88E5)
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    final d = ate - de;
    final n = (d.distance / 10).floor();
    for (var i = 0; i < n; i += 2) {
      canvas.drawLine(de + d * (i / n), de + d * ((i + 1) / n), pincel);
    }
    canvas.drawCircle(ate, 5, pincel);
  }

  @override
  bool shouldRepaint(_PintorPuxada old) => true;
}
