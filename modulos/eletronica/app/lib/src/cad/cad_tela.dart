import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_eletronica.dart';
import '../modelos.dart';
import '../telas/bom_tela.dart';
import '../telas/calculadoras_tela.dart';
import '../telas/simulacao_tela.dart';
import 'editor.dart';
import 'exportar.dart';
import 'paineis.dart';
import 'pintura.dart';

/// Tela de CAD do esquemático. Entrada para todos os aparelhos:
/// - mouse: esquerdo usa a ferramenta (no vazio, com Selecionar, abre a janela de seleção); meio ou direito
///   arrastam a folha; roda dá zoom; atalhos de CAD (ver [_atalhos]);
/// - caneta: a ponta usa a ferramenta, pairar mostra a prévia; o botão lateral arrasta;
/// - dedo: um toque usa a ferramenta, arrastar no vazio move a folha, dois dedos dão zoom.
class CadTela extends StatefulWidget {
  const CadTela({super.key, required this.api, required this.projeto, required this.biblioteca});

  final ApiEletronica api;
  final Projeto projeto;
  final Biblioteca biblioteca;

  @override
  State<CadTela> createState() => _CadTelaState();
}

enum _Gesto { nada, mover, janela, navegar, pinca, toque }

const _atalhos = [
  ('V / Esc', 'Selecionar'),
  ('A', 'Componente (biblioteca)'),
  ('W', 'Fio — clique duas vezes no mesmo ponto ou num pino para terminar'),
  ('/', 'Inverter o canto do fio'),
  ('L', 'Rótulo de rede'),
  ('T', 'Texto'),
  ('P', 'Ponta de prova: na rede mede tensão, no componente mede corrente'),
  ('R / X', 'Girar 90° / espelhar'),
  ('E', 'Editar o selecionado'),
  ('Del', 'Excluir'),
  ('Ctrl+D', 'Duplicar'),
  ('Setas', 'Mover a seleção um passo'),
  ('Ctrl+Z / Ctrl+Y', 'Desfazer / refazer'),
  ('F', 'Enquadrar a folha'),
];

class _CadTelaState extends State<CadTela> {
  late final Editor _editor = Editor(api: widget.api, projeto: widget.projeto, biblioteca: widget.biblioteca)
    ..addListener(_aoMudar);
  final Camera _camera = Camera();
  final FocusNode _foco = FocusNode(debugLabel: 'cad');
  final FocusNode _focoBusca = FocusNode(debugLabel: 'busca');
  final Map<int, Offset> _toques = {};
  Size _tamanho = Size.zero;
  bool _enquadrado = false;

  _Gesto _gesto = _Gesto.nada;
  int? _ponteiro;
  Offset _inicioTela = Offset.zero;
  Offset _inicioMundo = Offset.zero;
  P _ultimo = const P(0, 0);
  Rect? _janela;
  bool _conflitoMostrado = false;
  double _pincaDistancia = 0, _escalaTrackpad = 1;

  @override
  void dispose() {
    _editor
      ..removeListener(_aoMudar)
      ..dispose();
    _foco.dispose();
    _focoBusca.dispose();
    super.dispose();
  }

  void _aoMudar() {
    if (_editor.conflito && !_conflitoMostrado) {
      _conflitoMostrado = true;
      setState(() {});
    } else if (!_editor.conflito) {
      _conflitoMostrado = false;
    }
  }

  double get _tolerancia => 8 / _camera.escala;

  bool get _somar => HardwareKeyboard.instance.isShiftPressed || HardwareKeyboard.instance.isControlPressed;

  void _enquadrar() => setState(() => _camera.enquadrar(limitesDaFolha(_editor), _tamanho));

  // ---------- Ponteiros ----------

  void _baixou(PointerDownEvent e) {
    _foco.requestFocus();
    final mundo = _camera.paraMundo(e.localPosition);
    final snap = encaixar(mundo, _editor.passo);
    if (e.kind == PointerDeviceKind.touch) {
      _toques[e.pointer] = e.localPosition;
      if (_toques.length == 2) {
        if (_gesto == _Gesto.mover) _editor.terminarLote();
        final [a, b] = _toques.values.toList();
        _pincaDistancia = (a - b).distance;
        _gesto = _Gesto.pinca;
        _janela = null;
        return;
      }
      if (_toques.length > 2) return;
    }
    _ponteiro = e.pointer;
    _inicioTela = e.localPosition;
    _inicioMundo = mundo;
    final navegar = (e.kind == PointerDeviceKind.mouse && e.buttons & (kMiddleMouseButton | kSecondaryMouseButton) != 0) ||
        (e.kind == PointerDeviceKind.stylus && e.buttons & kPrimaryStylusButton != 0);
    if (navegar) {
      _gesto = _Gesto.navegar;
      return;
    }
    _editor.moverCursor(snap);
    if (_editor.ferramenta == Ferramenta.selecionar) {
      final alvo = _editor.acertar(mundo, _tolerancia);
      if (alvo != null) {
        setState(() {
          if (_somar) {
            _editor.selecao.contains(alvo.id) ? _editor.selecao.remove(alvo.id) : _editor.selecao.add(alvo.id);
          } else if (!_editor.selecao.contains(alvo.id)) {
            _editor.selecao
              ..clear()
              ..add(alvo.id);
          }
        });
        _editor.iniciarLote();
        _ultimo = snap;
        _gesto = _Gesto.mover;
        return;
      }
      if (e.kind == PointerDeviceKind.touch) {
        _gesto = _Gesto.toque;
        return;
      }
      _gesto = _Gesto.janela;
      _janela = Rect.fromPoints(mundo, mundo);
      return;
    }
    // Dedo: a ferramenta age ao soltar sem arrastar (arrastar move a folha).
    if (e.kind == PointerDeviceKind.touch) {
      _gesto = _Gesto.toque;
      return;
    }
    _usarFerramenta(snap);
  }

  void _moveu(PointerMoveEvent e) {
    if (e.kind == PointerDeviceKind.touch && _toques.containsKey(e.pointer)) {
      final antes = _toques[e.pointer]!;
      _toques[e.pointer] = e.localPosition;
      if (_gesto == _Gesto.pinca && _toques.length == 2) {
        final [a, b] = _toques.values.toList();
        final dist = (a - b).distance;
        setState(() {
          _camera.deslocamento += (e.localPosition - antes) / 2;
          if (_pincaDistancia > 0) _camera.zoom(dist / _pincaDistancia, (a + b) / 2);
        });
        _pincaDistancia = dist;
        return;
      }
    }
    if (e.pointer != _ponteiro) return;
    final mundo = _camera.paraMundo(e.localPosition);
    final snap = encaixar(mundo, _editor.passo);
    switch (_gesto) {
      case _Gesto.navegar:
        setState(() => _camera.deslocamento += e.delta);
      case _Gesto.toque:
        if ((e.localPosition - _inicioTela).distance > 10) _gesto = _Gesto.navegar;
      case _Gesto.mover:
        final d = snap - _ultimo;
        if (d != const P(0, 0)) {
          _editor.mexer(() => _editor.deslocarSelecao(d));
          _ultimo = snap;
        }
      case _Gesto.janela:
        setState(() => _janela = Rect.fromPoints(_inicioMundo, mundo));
      case _Gesto.nada || _Gesto.pinca:
        break;
    }
    _editor.moverCursor(snap);
  }

  void _soltou(PointerEvent e) {
    if (e.kind == PointerDeviceKind.touch) {
      _toques.remove(e.pointer);
      if (_gesto == _Gesto.pinca) {
        if (_toques.isEmpty) _gesto = _Gesto.nada;
        return;
      }
    }
    if (e.pointer != _ponteiro) return;
    final mundo = _camera.paraMundo(e.localPosition);
    switch (_gesto) {
      case _Gesto.mover:
        _editor.terminarLote();
      case _Gesto.janela:
        final j = _janela;
        if (j != null && (e.localPosition - _inicioTela).distance > 4) {
          _editor.selecionarArea(j, somar: _somar);
        } else if (!_somar) {
          setState(_editor.selecao.clear);
        }
      case _Gesto.toque:
        if (_editor.ferramenta == Ferramenta.selecionar) {
          setState(_editor.selecao.clear);
        } else if (e is PointerUpEvent) {
          _usarFerramenta(encaixar(mundo, _editor.passo));
        }
      case _Gesto.navegar:
        // Clique direito parado termina o fio.
        if (e.kind == PointerDeviceKind.mouse && (e.localPosition - _inicioTela).distance < 4 && _editor.fio != null) {
          _editor.concluirFio();
        }
      case _Gesto.nada || _Gesto.pinca:
        break;
    }
    if (e.kind == PointerDeviceKind.touch && _editor.ferramenta == Ferramenta.selecionar) _editor.moverCursor(null);
    setState(() {
      _gesto = _Gesto.nada;
      _janela = null;
      _ponteiro = null;
    });
  }

  Future<void> _usarFerramenta(P p) async {
    switch (_editor.ferramenta) {
      case Ferramenta.componente:
        _editor.colocarComponente(p);
      case Ferramenta.fio:
        final fio = _editor.fio;
        if (fio != null && fio.last == p) {
          _editor.concluirFio();
        } else {
          _editor.pontoDoFio(p);
        }
      case Ferramenta.rotulo:
        final nomes = {for (final r in _editor.projeto.rotulos) r.nome}.toList()..sort();
        final nome = await pedirTexto(context, 'Nome da rede', sugestoes: nomes);
        if (nome != null && nome.trim().isNotEmpty) _editor.colocarRotulo(p, nome);
      case Ferramenta.texto:
        final texto = await pedirTexto(context, 'Texto');
        if (texto != null && texto.trim().isNotEmpty) _editor.colocarTexto(p, texto);
      case Ferramenta.sonda:
        final aviso = _editor.colocarSonda(p, p.offset, _tolerancia);
        if (aviso != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(aviso)));
      case Ferramenta.selecionar:
        break;
    }
  }

  void _rolou(PointerSignalEvent e) {
    if (e is PointerScrollEvent) {
      setState(() => _camera.zoom(exp(-e.scrollDelta.dy / 400), e.localPosition));
    }
  }

  void _trackpad(PointerPanZoomUpdateEvent e) {
    setState(() {
      _camera.deslocamento += e.panDelta;
      _camera.zoom(e.scale / _escalaTrackpad, e.localPosition);
    });
    _escalaTrackpad = e.scale;
  }

  // ---------- Teclado ----------

  KeyEventResult _tecla(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final ctrl = HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final k = e.logicalKey;
    final passo = _editor.passo;
    P? seta;
    if (k == LogicalKeyboardKey.arrowLeft) seta = P(-passo, 0);
    if (k == LogicalKeyboardKey.arrowRight) seta = P(passo, 0);
    if (k == LogicalKeyboardKey.arrowUp) seta = P(0, -passo);
    if (k == LogicalKeyboardKey.arrowDown) seta = P(0, passo);
    if (seta != null && _editor.selecao.isNotEmpty) {
      final d = seta;
      _editor.alterar(() => _editor.deslocarSelecao(d));
      return KeyEventResult.handled;
    }
    if (e is KeyRepeatEvent) return KeyEventResult.ignored;
    if (ctrl) {
      if (k == LogicalKeyboardKey.keyZ) shift ? _editor.refazer() : _editor.desfazer();
      if (k == LogicalKeyboardKey.keyY) _editor.refazer();
      if (k == LogicalKeyboardKey.keyD) _editor.duplicarSelecao();
      if (k == LogicalKeyboardKey.keyS) _editor.gravar();
      if (k == LogicalKeyboardKey.keyA) _editor.selecionarArea(Rect.largest);
      return KeyEventResult.handled;
    }
    switch (k) {
      case LogicalKeyboardKey.escape:
        if (_editor.fio != null) {
          _editor.concluirFio();
        } else if (_editor.ferramenta != Ferramenta.selecionar) {
          _editor.escolher(Ferramenta.selecionar);
        } else {
          setState(_editor.selecao.clear);
        }
      case LogicalKeyboardKey.delete || LogicalKeyboardKey.backspace:
        _editor.excluirSelecao();
      case LogicalKeyboardKey.keyV:
        _editor.escolher(Ferramenta.selecionar);
      case LogicalKeyboardKey.keyA:
        _abrirBiblioteca();
      case LogicalKeyboardKey.keyW:
        _editor.escolher(Ferramenta.fio);
      case LogicalKeyboardKey.keyL:
        _editor.escolher(Ferramenta.rotulo);
      case LogicalKeyboardKey.keyT:
        _editor.escolher(Ferramenta.texto);
      case LogicalKeyboardKey.keyP:
        _editor.escolher(Ferramenta.sonda);
      case LogicalKeyboardKey.keyR:
        _editor.girar();
      case LogicalKeyboardKey.keyX:
        _editor.espelhar();
      case LogicalKeyboardKey.keyE:
        _editarSelecionado();
      case LogicalKeyboardKey.keyF:
        _enquadrar();
      case LogicalKeyboardKey.slash:
        _editor.inverterCanto();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  bool get _largo => MediaQuery.sizeOf(context).width >= 1100;

  void _abrirBiblioteca() {
    if (_largo) {
      _focoBusca.requestFocus();
    } else {
      Scaffold.of(_contextoCorpo!).openDrawer();
    }
  }

  BuildContext? _contextoCorpo;

  Future<void> _editarSelecionado() async {
    final sel = _editor.selecionados;
    if (sel.length != 1) return;
    await editarItem(context, _editor, sel.single);
    _foco.requestFocus();
  }

  Future<void> _exportar(FormatoExportacao f) async {
    final mensageiro = ScaffoldMessenger.of(context);
    try {
      if (await exportar(_editor, f)) mensageiro.showSnackBar(SnackBar(content: Text('Exportado em ${f.name.toUpperCase()}.')));
    } catch (e) {
      mensageiro.showSnackBar(SnackBar(content: Text('Não exportou: $e')));
    }
  }

  // ---------- Montagem ----------

  @override
  Widget build(BuildContext context) {
    final largo = _largo;
    final biblioteca = PainelBiblioteca(
      editor: _editor,
      foco: _focoBusca,
      aoEscolher: () {
        if (!largo) Navigator.of(context).maybePop();
        _foco.requestFocus();
      },
    );
    final propriedades = PainelPropriedades(editor: _editor);
    final estreito = MediaQuery.sizeOf(context).width < 700;
    void calculadoras() => mostrarCalculadoras(context);
    Future<void> bom() async {
      await _editor.gravar();
      if (context.mounted) await mostrarBom(context, widget.api, widget.projeto);
    }

    void atalhos() => showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Atalhos'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (t, d) in _atalhos)
                  ListTile(dense: true, leading: SizedBox(width: 110, child: Text(t, style: const TextStyle(fontFamily: 'monospace'))), title: Text(d)),
              ],
            ),
          ),
        ),
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: ListenableBuilder(
          listenable: _editor,
          builder: (_, _) => Row(
            spacing: 12,
            children: [
              Flexible(child: Text(widget.projeto.titulo, overflow: TextOverflow.ellipsis)),
              _EstadoGravacao(editor: _editor),
            ],
          ),
        ),
        actions: [
          ListenableBuilder(
            listenable: _editor,
            builder: (_, _) => Row(
              children: [
                IconButton(tooltip: 'Desfazer (Ctrl+Z)', onPressed: _editor.podeDesfazer() ? _editor.desfazer : null, icon: const Icon(Icons.undo)),
                IconButton(tooltip: 'Refazer (Ctrl+Y)', onPressed: _editor.podeRefazer() ? _editor.refazer : null, icon: const Icon(Icons.redo)),
              ],
            ),
          ),
          IconButton(tooltip: 'Enquadrar (F)', onPressed: _enquadrar, icon: const Icon(Icons.fit_screen_outlined)),
          IconButton(
            tooltip: 'Simular (ngspice)',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SimulacaoTela(
                  api: widget.api,
                  projeto: widget.projeto,
                  gravar: _editor.gravar,
                  aoLer: _editor.lerSondas,
                ),
              ),
            ),
            icon: const Icon(Icons.ssid_chart),
          ),
          if (!estreito) ...[
            IconButton(tooltip: 'Calculadoras', onPressed: calculadoras, icon: const Icon(Icons.calculate_outlined)),
            IconButton(tooltip: 'Lista de peças e ligações', onPressed: bom, icon: const Icon(Icons.list_alt_outlined)),
            PopupMenuButton<FormatoExportacao>(
              tooltip: 'Exportar a folha',
              icon: const Icon(Icons.ios_share),
              onSelected: _exportar,
              itemBuilder: (_) => const [
                PopupMenuItem(value: FormatoExportacao.pdf, child: Text('PDF (A4)')),
                PopupMenuItem(value: FormatoExportacao.png, child: Text('PNG')),
              ],
            ),
            IconButton(tooltip: 'Atalhos', onPressed: atalhos, icon: const Icon(Icons.keyboard_outlined)),
          ] else
            // No celular as ações secundárias vão para o menu "mais", senão a AppBar estoura.
            PopupMenuButton<VoidCallback>(
              tooltip: 'Mais',
              onSelected: (acao) => acao(),
              itemBuilder: (_) => [
                PopupMenuItem(value: calculadoras, child: const ListTile(leading: Icon(Icons.calculate_outlined), title: Text('Calculadoras'))),
                PopupMenuItem(value: bom, child: const ListTile(leading: Icon(Icons.list_alt_outlined), title: Text('Lista de peças e ligações'))),
                PopupMenuItem(value: () => _exportar(FormatoExportacao.pdf), child: const ListTile(leading: Icon(Icons.picture_as_pdf_outlined), title: Text('Exportar PDF (A4)'))),
                PopupMenuItem(value: () => _exportar(FormatoExportacao.png), child: const ListTile(leading: Icon(Icons.image_outlined), title: Text('Exportar PNG'))),
                PopupMenuItem(value: atalhos, child: const ListTile(leading: Icon(Icons.keyboard_outlined), title: Text('Atalhos'))),
              ],
            ),
          if (!largo)
            Builder(
              builder: (c) => IconButton(tooltip: 'Propriedades', onPressed: () => Scaffold.of(c).openEndDrawer(), icon: const Icon(Icons.tune)),
            ),
        ],
      ),
      drawer: largo ? null : Drawer(width: 300, child: SafeArea(child: biblioteca)),
      endDrawer: largo ? null : Drawer(width: 300, child: SafeArea(child: propriedades)),
      body: Builder(
        builder: (corpo) {
          _contextoCorpo = corpo;
          return Row(
            children: [
              if (largo) SizedBox(width: 280, child: biblioteca),
              if (largo) const VerticalDivider(width: 1),
              Expanded(
                child: Column(
                  children: [
                    BarraFerramentas(editor: _editor, aoBiblioteca: _abrirBiblioteca),
                    if (_editor.conflito)
                      MaterialBanner(
                        content: const Text('Este projeto mudou em outro aparelho.'),
                        actions: [
                          TextButton(onPressed: () => _editor.recarregar().then((_) => setState(() {})), child: const Text('Recarregar')),
                          TextButton(onPressed: () => _editor.gravar(porCima: true).then((_) => setState(() {})), child: const Text('Manter o meu')),
                        ],
                      ),
                    Expanded(child: _tela()),
                    BarraFolhas(editor: _editor, camera: _camera),
                  ],
                ),
              ),
              if (largo) const VerticalDivider(width: 1),
              if (largo) SizedBox(width: 300, child: propriedades),
            ],
          );
        },
      ),
    );
  }

  Widget _tela() => Focus(
    focusNode: _foco,
    autofocus: true,
    onKeyEvent: _tecla,
    child: LayoutBuilder(
      builder: (context, c) {
        _tamanho = c.biggest;
        if (!_enquadrado) {
          _enquadrado = true;
          WidgetsBinding.instance.addPostFrameCallback((_) => _enquadrar());
        }
        return MouseRegion(
          cursor: _editor.ferramenta == Ferramenta.selecionar ? SystemMouseCursors.basic : SystemMouseCursors.precise,
          onExit: (_) => _editor.moverCursor(null),
          child: Listener(
            onPointerDown: _baixou,
            onPointerMove: _moveu,
            onPointerUp: _soltou,
            onPointerCancel: _soltou,
            onPointerHover: (e) => _editor.moverCursor(encaixar(_camera.paraMundo(e.localPosition), _editor.passo)),
            onPointerSignal: _rolou,
            onPointerPanZoomStart: (_) => _escalaTrackpad = 1,
            onPointerPanZoomUpdate: _trackpad,
            child: GestureDetector(
              onDoubleTap: _editor.ferramenta == Ferramenta.selecionar ? _editarSelecionado : null,
              child: CustomPaint(
                size: Size.infinite,
                painter: PintorCad(_editor, _camera, janela: _janela, paleta: Paleta.escura),
              ),
            ),
          ),
        );
      },
    ),
  );
}

class _EstadoGravacao extends StatelessWidget {
  const _EstadoGravacao({required this.editor});

  final Editor editor;

  @override
  Widget build(BuildContext context) {
    final estilo = Theme.of(context).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.outline);
    final (icone, texto) = editor.conflito
        ? (Icons.sync_problem, 'conflito')
        : editor.erro != null
        ? (Icons.cloud_off, 'sem conexão — tenta de novo')
        : editor.salvando || editor.pendente
        ? (Icons.cloud_upload_outlined, 'gravando…')
        : (Icons.cloud_done_outlined, 'gravado');
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [Icon(icone, size: 16, color: estilo?.color), Text(texto, style: estilo)],
    );
  }
}
