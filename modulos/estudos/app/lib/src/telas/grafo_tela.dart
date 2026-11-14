import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:agent_core/agent_core.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';

import '../api_estudos.dart';
import '../layout_grafo.dart';
import '../modelos.dart';
import 'leituras_tela.dart';

const _lado = 1600.0;
const _maxGrupos = 10; // grupos com cor própria; o resto fica cinza ("outros")

// Linha do tempo da animação (0..1): os nós novos surgem em onda a partir dos mais ligados, cada um saindo
// do nó que o "puxa"; as demais ligações se desenham depois que as duas pontas já apareceram.
const _durNo = 0.16, _atrasoAresta = 0.05, _durAresta = 0.14;
const _janela = 1 - _durNo - _atrasoAresta - _durAresta;
const _durExistente = 0.5; // nós que já estavam na tela deslizam até a nova posição

/// Grafo do conhecimento: as notas do vault e os links entre elas. O layout é calculado em segundo plano
/// e a tela só anima o resultado (nós brotando e se ligando). A cor é o grupo (1ª tag ou prefixo do
/// título); passar o mouse/tocar destaca as ligações e os rótulos aparecem conforme o zoom. Filtra por
/// área, categoria (tipo), cor (clique na legenda) e busca por palavras-chave (título, tags e tipo).
class GrafoTela extends StatefulWidget {
  const GrafoTela({super.key, required this.api, required this.areas});

  final ApiEstudos api;
  final List<String> areas;

  @override
  State<GrafoTela> createState() => _GrafoTelaState();
}

class _GrafoTelaState extends State<GrafoTela> with TickerProviderStateMixin {
  List<NoGrafo> _nos = const [];
  List<Aresta> _arestas = const [];
  Map<String, NoGrafo> _porId = const {};
  Map<String, Set<String>> _vizinhos = const {};
  Map<String, String> _textoBusca = const {}; // id → título, tags e tipo em minúsculas
  Map<String, int> _grupoDe = const {}; // id → índice do grupo (-1 = outros)
  List<(String, int)> _grupos = const []; // (nome, quantidade), maiores primeiro
  List<String> _tipos = const [];
  Set<String> _hubs = const {}; // nós mais ligados: rótulo visível em qualquer zoom

  // cena na tela: vetores na ordem de _nosSim (x, y intercalados)
  List<NoGrafo> _nosSim = const [];
  List<(int, int)> _arestasSim = const [];
  Float64List _de = Float64List(0), _para = Float64List(0), _pos = Float64List(0);
  Float64List _tam = Float64List(0), _inicio = Float64List(0);
  Int32List _pai = Int32List(0);
  List<bool> _existia = const [];
  List<int> _ordem = const [];
  Float32List _pontos = Float32List(0);
  int _nPontos = 0;
  int _geracao = 0; // descarta layout calculado para um filtro que já mudou

  String? _area, _tipo;
  final Set<int> _gruposFiltro = {};
  List<String> _termos = const [];
  Set<String> _achados = const {};
  bool _soBusca = false;
  Timer? _espera;
  String? _selecionado, _hover, _ultimoFoco;
  String? _erro;
  bool _carregando = true;
  Size _tamanho = Size.zero;
  final _visor = TransformationController();
  final _quadro = ValueNotifier(0);
  final _rotulos = <String, TextPainter>{};
  late final _anim = AnimationController(vsync: this)..addListener(_aplicarQuadro);
  late final _foco = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  late final _camera = AnimationController(vsync: this, duration: const Duration(milliseconds: 650));
  Matrix4Tween? _rotaCamera;

  @override
  void initState() {
    super.initState();
    _camera.addListener(() {
      final r = _rotaCamera;
      if (r != null) _visor.value = r.evaluate(CurvedAnimation(parent: _camera, curve: Curves.easeInOutCubic));
    });
    _carregar();
  }

  @override
  void dispose() {
    _espera?.cancel();
    _anim.dispose();
    _foco.dispose();
    _camera.dispose();
    _visor.dispose();
    _quadro.dispose();
    super.dispose();
  }

  Future<void> _carregar() async {
    setState(() => _carregando = true);
    try {
      final (nos, arestas) = await widget.api.grafo();
      _nos = nos;
      _arestas = arestas;
      _indexar();
      _rotulos.clear();
      _erro = null;
      await _refazerLayout();
    } on ApiErro catch (e) {
      _erro = '$e';
    }
    if (mounted) setState(() => _carregando = false);
  }

  static String _nomeGrupo(NoGrafo n) {
    if (n.tags.isNotEmpty) return '#${n.tags.first}';
    if (n.tipo != 'nota') return n.tipo;
    final prefixo = n.titulo.split(RegExp(r' [—–-] ')).first;
    final nome = prefixo.replaceAll(RegExp(r'[\d\s.()]+$'), '').trim();
    return nome.isEmpty ? 'nota' : nome;
  }

  void _indexar() {
    _porId = {for (final n in _nos) n.id: n};
    final viz = <String, Set<String>>{};
    for (final a in _arestas) {
      (viz[a.de] ??= {}).add(a.para);
      (viz[a.para] ??= {}).add(a.de);
    }
    _vizinhos = viz;
    _textoBusca = {for (final n in _nos) n.id: '${n.titulo} #${n.tags.join(' #')} ${n.tipo}'.toLowerCase()};
    _tipos = {for (final n in _nos) n.tipo}.toList()..sort();
    if (!_tipos.contains(_tipo)) _tipo = null;
    final contagem = <String, int>{};
    final nomes = {for (final n in _nos) n.id: _nomeGrupo(n)};
    for (final g in nomes.values) {
      contagem[g] = (contagem[g] ?? 0) + 1;
    }
    final ordem = contagem.entries.where((e) => e.value >= 3).toList()..sort((a, b) => b.value.compareTo(a.value));
    _grupos = [for (final e in ordem.take(_maxGrupos)) (e.key, e.value)];
    _gruposFiltro.removeWhere((g) => g >= _grupos.length);
    final indice = {for (final (i, g) in _grupos.indexed) g.$1: i};
    _grupoDe = {for (final e in nomes.entries) e.key: indice[e.value] ?? -1};
    final porGrau = [..._nos]..sort((a, b) => b.grau.compareTo(a.grau));
    _hubs = {for (final n in porGrau.take(12)) if (n.grau > 2) n.id};
    _buscarTermos();
  }

  bool _naArea(NoGrafo n) =>
      _area == null ||
      n.tags.any((t) => t.toLowerCase() == _area!.toLowerCase()) ||
      n.titulo.toLowerCase() == _area!.toLowerCase();

  bool _passa(NoGrafo n) =>
      (_tipo == null || n.tipo == _tipo) &&
      (_gruposFiltro.isEmpty || _gruposFiltro.contains(_grupoDe[n.id] ?? -1)) &&
      (!_soBusca || _termos.isEmpty || _achados.contains(n.id));

  bool get _filtrando => _area != null || _tipo != null || _gruposFiltro.isNotEmpty || (_soBusca && _termos.isNotEmpty);

  /// Área: os nós dela e os vizinhos diretos; depois categoria, cor e (se ligado) a busca.
  Set<String> get _visiveis {
    var base = {for (final n in _nos) if (_naArea(n)) n.id};
    if (_area != null) base = {...base, for (final id in base) ...?_vizinhos[id]};
    return {for (final id in base) if (_porId[id] != null && _passa(_porId[id]!)) id};
  }

  Future<void> _refazerLayout() async {
    final geracao = ++_geracao;
    final vis = _visiveis;
    final nos = [for (final n in _nos) if (vis.contains(n.id)) n];
    final atuais = <String, Offset>{
      for (final (i, n) in _nosSim.indexed)
        if (_tam[i] > 0) n.id: Offset(_pos[2 * i], _pos[2 * i + 1]),
    };
    final ids = [for (final n in nos) n.id];
    final arestas = [for (final a in _arestas) if (vis.contains(a.de) && vis.contains(a.para)) (a.de, a.para)];
    // poucos nós em comum com a cena atual: layout do zero sai melhor (os que ficam ainda deslizam)
    final comuns = ids.where(atuais.containsKey).length;
    final semente = comuns * 2 >= ids.length ? atuais : const <String, Offset>{};
    final finais = await compute(calcularLayout, (ids, arestas, _lado, semente));
    if (!mounted || geracao != _geracao) return;
    setState(() => _montarCena(nos, finais, atuais));
  }

  void _montarCena(List<NoGrafo> nos, Map<String, Offset> finais, Map<String, Offset> atuais) {
    final n = nos.length;
    final indice = {for (final (i, no) in nos.indexed) no.id: i};
    final arestas = <(int, int)>[
      for (final a in _arestas)
        if (indice[a.de] != null && indice[a.para] != null && a.de != a.para) (indice[a.de]!, indice[a.para]!),
    ];
    final viz = List.generate(n, (_) => <int>[]);
    for (final (a, b) in arestas) {
      viz[a].add(b);
      viz[b].add(a);
    }
    final de = Float64List(2 * n), para = Float64List(2 * n);
    final existia = List.filled(n, false);
    for (final (i, no) in nos.indexed) {
      final f = finais[no.id] ?? Offset.zero;
      final a = atuais[no.id];
      existia[i] = a != null;
      para[2 * i] = f.dx;
      para[2 * i + 1] = f.dy;
      de[2 * i] = (a ?? f).dx;
      de[2 * i + 1] = (a ?? f).dy;
    }
    // ordem de surgimento: busca em largura a partir do que já está na tela, senão dos nós mais ligados
    final porGrau = List.generate(n, (i) => i)..sort((a, b) => viz[b].length.compareTo(viz[a].length));
    final pai = Int32List(n)..fillRange(0, n, -1);
    final visto = List.of(existia);
    final fila = [for (final i in porGrau) if (existia[i]) i];
    final ordem = <int>[];
    var cabeca = 0, raiz = 0;
    while (ordem.length < n) {
      if (cabeca == fila.length) {
        while (visto[porGrau[raiz]]) {
          raiz++;
        }
        visto[porGrau[raiz]] = true;
        fila.add(porGrau[raiz]);
      }
      final i = fila[cabeca++];
      ordem.add(i);
      for (final j in viz[i]) {
        if (!visto[j]) {
          visto[j] = true;
          pai[j] = i;
          fila.add(j);
        }
      }
    }
    final novos = existia.where((e) => !e).length;
    final inicio = Float64List(n);
    var k = 0;
    for (final i in ordem) {
      if (!existia[i]) inicio[i] = novos <= 1 ? 0 : _janela * k++ / (novos - 1);
    }

    _nosSim = nos;
    _arestasSim = arestas;
    _de = de;
    _para = para;
    _pos = Float64List.fromList(de);
    _tam = Float64List(n);
    _inicio = inicio;
    _pai = pai;
    _existia = existia;
    _ordem = ordem;
    _pontos = Float32List(arestas.length * 4);
    if (_selecionado != null && indice[_selecionado] == null) _selecionado = null;
    if (_hover != null && indice[_hover] == null) _hover = null;
    _atualizarFoco();

    final segundos = novos == 0 ? 0.9 : (1.2 + novos * 0.006).clamp(1.4, 4.5);
    _anim.duration = Duration(milliseconds: (segundos * 1000).round());
    _enquadrar(animar: atuais.isNotEmpty);
    _anim.forward(from: 0);
    _aplicarQuadro();
  }

  /// Posições, tamanhos e ligações (já recortadas pelo progresso) do instante atual da animação.
  void _aplicarQuadro() {
    final t = _anim.value;
    for (final i in _ordem) {
      final double e;
      final double ox, oy;
      if (_existia[i]) {
        e = Curves.easeInOutCubic.transform((t / _durExistente).clamp(0.0, 1.0));
        _tam[i] = 1;
        ox = _de[2 * i];
        oy = _de[2 * i + 1];
      } else {
        final u = ((t - _inicio[i]) / _durNo).clamp(0.0, 1.0);
        e = Curves.easeOutCubic.transform(u);
        _tam[i] = u == 0 ? 0 : Curves.easeOutBack.transform(u);
        final p = _pai[i]; // o pai vem antes na ordem: a posição dele já é a deste quadro
        ox = p >= 0 ? _pos[2 * p] : _de[2 * i];
        oy = p >= 0 ? _pos[2 * p + 1] : _de[2 * i + 1];
      }
      _pos[2 * i] = ox + (_para[2 * i] - ox) * e;
      _pos[2 * i + 1] = oy + (_para[2 * i + 1] - oy) * e;
    }
    var k = 0;
    for (final (a, b) in _arestasSim) {
      if (_tam[a] == 0 || _tam[b] == 0) continue;
      final (o, d) = _inicio[a] <= _inicio[b] ? (a, b) : (b, a);
      var prog = 1.0;
      // a ligação com o nó que puxou já nasce inteira (o filho sai dele); as outras se desenham depois
      if (!(_existia[a] && _existia[b]) && _pai[d] != o && _pai[o] != d) {
        final s = max(_inicio[a], _inicio[b]) + _durNo + _atrasoAresta;
        prog = Curves.easeOut.transform(((t - s) / _durAresta).clamp(0.0, 1.0));
        if (prog == 0) continue;
      }
      final ox = _pos[2 * o], oy = _pos[2 * o + 1];
      _pontos[k++] = ox;
      _pontos[k++] = oy;
      _pontos[k++] = ox + (_pos[2 * d] - ox) * prog;
      _pontos[k++] = oy + (_pos[2 * d + 1] - oy) * prog;
    }
    _nPontos = k;
    _quadro.value++;
  }

  /// Ajusta a câmera às posições finais dos nós [indices] (todos, se nulo).
  void _enquadrar({Iterable<int>? indices, bool animar = true}) {
    if (_tamanho.isEmpty || _nosSim.isEmpty) return;
    Rect? caixa;
    for (final i in indices ?? Iterable<int>.generate(_nosSim.length)) {
      final p = Offset(_para[2 * i], _para[2 * i + 1]);
      caixa = caixa == null ? Rect.fromCenter(center: p, width: 0, height: 0) : caixa.expandToInclude(Rect.fromPoints(p, p));
    }
    if (caixa == null) return;
    caixa = Rect.fromCenter(
      center: caixa.center,
      width: max(caixa.width + 120, 300),
      height: max(caixa.height + 120, 300),
    );
    final s = min(_tamanho.width / caixa.width, _tamanho.height / caixa.height).clamp(0.1, 2.5);
    final centro = caixa.center + const Offset(_lado / 2, _lado / 2);
    final alvo = Matrix4.diagonal3Values(s, s, 1)
      ..setTranslationRaw(_tamanho.width / 2 - centro.dx * s, _tamanho.height / 2 - centro.dy * s, 0);
    if (!animar) {
      _camera.stop();
      _visor.value = alvo;
      return;
    }
    _rotaCamera = Matrix4Tween(begin: _visor.value.clone(), end: alvo);
    _camera.forward(from: 0);
  }

  static double _raio(NoGrafo n) => min(3.5 + sqrt(n.grau) * 1.4, 18);

  double get _escala => _visor.value.getMaxScaleOnAxis();

  String? _noEm(Offset local) {
    final p0 = local - const Offset(_lado / 2, _lado / 2);
    final folga = 6 / _escala;
    String? achado;
    var melhor = double.infinity;
    for (var i = 0; i < _nosSim.length; i++) {
      if (_tam[i] <= 0) continue;
      final d = (Offset(_pos[2 * i], _pos[2 * i + 1]) - p0).distance;
      if (d < _raio(_nosSim[i]) + folga && d < melhor) {
        melhor = d;
        achado = _nosSim[i].id;
      }
    }
    return achado;
  }

  /// Foco = nó sob o mouse, senão o selecionado, ou a busca. Anima o esmaecer dos outros.
  void _atualizarFoco() {
    final alvo = _hover ?? _selecionado;
    if (alvo != null || _termos.isNotEmpty) {
      _ultimoFoco = alvo;
      _foco.forward();
    } else {
      _foco.reverse();
    }
  }

  void _buscarTermos([String? texto]) {
    if (texto != null) _termos = texto.toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    _achados = _termos.isEmpty
        ? const {}
        : {for (final e in _textoBusca.entries) if (_termos.every(e.value.contains)) e.key};
  }

  void _buscar(String texto) {
    setState(() => _buscarTermos(texto));
    _atualizarFoco();
    if (_soBusca) {
      _espera?.cancel();
      _espera = Timer(const Duration(milliseconds: 350), _refazerLayout);
    }
  }

  void _enquadrarAchados() {
    final indices = [for (final (i, n) in _nosSim.indexed) if (_achados.contains(n.id)) i];
    if (indices.isNotEmpty) _enquadrar(indices: indices);
  }

  void _filtrar(VoidCallback mudar) {
    setState(mudar);
    _refazerLayout();
  }

  static List<Color> _paleta(int n, bool escuro) => [
    for (var i = 0; i < n; i++)
      HSLColor.fromAHSL(1, (205 + i * 137.508) % 360, escuro ? 0.68 : 0.62, escuro ? 0.64 : 0.46).toColor(),
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      _tamanho = c.biggest;
      return _corpo(context);
    });
  }

  Widget _corpo(BuildContext context) {
    if (_carregando && _nosSim.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_erro != null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, spacing: 12, children: [Text(_erro!), FilledButton(onPressed: _carregar, child: const Text('Tentar de novo'))]));
    }
    if (_nos.isEmpty) {
      return const Center(child: Text('Nenhuma nota ainda. As notas de síntese das leituras aparecem aqui.'));
    }
    final tema = Theme.of(context);
    final escuro = tema.brightness == Brightness.dark;
    final paleta = _paleta(_grupos.length, escuro);
    final outros = tema.colorScheme.outline;
    final sel = _selecionado == null ? null : _porId[_selecionado];
    final pintor = _PintorGrafo(
      nos: _nosSim,
      arestas: _arestasSim,
      pos: _pos,
      tam: _tam,
      pontos: () => Float32List.sublistView(_pontos, 0, _nPontos),
      cor: (n) {
        final g = _grupoDe[n.id] ?? -1;
        return g < 0 ? outros : paleta[g];
      },
      foco: _ultimoFoco,
      vizinhos: _vizinhos[_ultimoFoco] ?? const {},
      selecionado: _selecionado,
      achados: _achados,
      hubs: _hubs,
      t: _foco,
      visor: _visor,
      rotulos: _rotulos,
      cores: tema.colorScheme,
      estiloTexto: tema.textTheme.labelSmall!,
      repaint: Listenable.merge([_quadro, _foco, _visor]),
    );
    Widget legenda(int g, Color cor, String texto) {
      final ativo = _gruposFiltro.isEmpty || _gruposFiltro.contains(g);
      return InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _filtrar(() => _gruposFiltro.contains(g) ? _gruposFiltro.remove(g) : _gruposFiltro.add(g)),
        child: Opacity(
          opacity: ativo ? 1 : 0.35,
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2), child: _Legenda(cor: cor, texto: texto)),
        ),
      );
    }

    return Stack(
      children: [
        Positioned.fill(
          child: InteractiveViewer(
            transformationController: _visor,
            constrained: false,
            boundaryMargin: const EdgeInsets.all(_lado),
            minScale: 0.1,
            maxScale: 6,
            onInteractionStart: (_) => _camera.stop(),
            child: MouseRegion(
              cursor: _hover != null ? SystemMouseCursors.click : MouseCursor.defer,
              onHover: (e) {
                final id = _noEm(e.localPosition);
                if (id != _hover) {
                  setState(() => _hover = id);
                  _atualizarFoco();
                }
              },
              onExit: (_) {
                if (_hover == null) return;
                setState(() => _hover = null);
                _atualizarFoco();
              },
              child: GestureDetector(
                onTapUp: (d) {
                  setState(() => _selecionado = _noEm(d.localPosition));
                  _atualizarFoco();
                },
                child: CustomPaint(size: const Size(_lado, _lado), painter: pintor),
              ),
            ),
          ),
        ),
        if (_nosSim.isEmpty) const Center(child: Text('Nenhuma nota com esses filtros.')),
        Positioned(
          left: 8,
          right: 8,
          top: 8,
          child: LayoutBuilder(
            builder: (context, c) {
              final busca = TextField(
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: tema.colorScheme.surface,
                    prefixIcon: const Icon(Icons.search),
                    hintText: 'Buscar: título, #tag, palavras',
                    suffixText: _termos.isEmpty ? null : '${_achados.length}',
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: _buscar,
                  onSubmitted: (_) => _enquadrarAchados(),
              );
              final filtros = <Widget>[
              FilterChip(
                label: const Text('Só resultados'),
                tooltip: 'Esconde as notas que não batem com a busca',
                selected: _soBusca,
                onSelected: (v) => _filtrar(() => _soBusca = v),
              ),
              ChoiceChip(
                label: const Text('Tudo'),
                selected: _area == null,
                onSelected: (_) => _filtrar(() => _area = null),
              ),
              for (final a in widget.areas)
                ChoiceChip(label: Text(a), selected: _area == a, onSelected: (_) => _filtrar(() => _area = a)),
              if (_tipos.length > 1)
                PopupMenuButton<String>(
                  tooltip: 'Categoria da nota',
                  onSelected: (v) => _filtrar(() => _tipo = v.isEmpty ? null : v),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: '', child: Text('Todas as categorias')),
                    for (final t in _tipos) CheckedPopupMenuItem(value: t, checked: _tipo == t, child: Text(t)),
                  ],
                  child: Chip(
                    avatar: const Icon(Icons.category_outlined, size: 18),
                    label: Text(_tipo ?? 'Categoria'),
                    backgroundColor: _tipo == null ? null : tema.colorScheme.secondaryContainer,
                  ),
                ),
              if (_filtrando)
                ActionChip(
                  avatar: const Icon(Icons.filter_alt_off_outlined, size: 18),
                  label: const Text('Limpar filtros'),
                  onPressed: () => _filtrar(() {
                    _area = null;
                    _tipo = null;
                    _soBusca = false;
                    _gruposFiltro.clear();
                  }),
                ),
              IconButton.filledTonal(tooltip: 'Recarregar', icon: const Icon(Icons.refresh), onPressed: _carregar),
              IconButton.filledTonal(
                tooltip: 'Enquadrar',
                icon: const Icon(Icons.center_focus_strong),
                onPressed: () => _enquadrar(),
              ),
              ];
              // celular: busca na largura toda e filtros numa linha só rolando na horizontal
              if (c.maxWidth < 600) {
                return Material(
                  color: tema.colorScheme.surface.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(8),
                  clipBehavior: Clip.antiAlias,
                  child: FiltrosRecolhiveis(
                    chave: 'estudos.grafo',
                    resumo: [?_area, ?_tipo, ..._termos].join(' · '),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          spacing: 6,
                          children: [
                            busca,
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(spacing: 6, children: filtros),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }
              return Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [SizedBox(width: 260, child: busca), ...filtros],
              );
            },
          ),
        ),
        Positioned(
          left: 8,
          bottom: 8,
          right: sel == null ? 8 : 320,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            spacing: 6,
            children: [
              // legenda longa rola em vez de cobrir o grafo
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 96),
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 2,
                    children: [
                      for (final (i, (nome, qtd)) in _grupos.indexed) legenda(i, paleta[i], '$nome ($qtd)'),
                      if (_grupoDe.values.contains(-1)) legenda(-1, outros, 'outros'),
                    ],
                  ),
                ),
              ),
              Text(
                '${_nosSim.length} notas · ${_arestasSim.length} ligações · clique na cor para filtrar',
                style: tema.textTheme.labelSmall,
              ),
            ],
          ),
        ),
        Positioned(
          right: 8,
          bottom: 8,
          width: 300,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            transitionBuilder: (filho, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween(begin: const Offset(0, 0.08), end: Offset.zero).animate(anim),
                child: filho,
              ),
            ),
            child: sel == null ? const SizedBox.shrink() : _cartao(context, sel),
          ),
        ),
      ],
    );
  }

  Widget _cartao(BuildContext context, NoGrafo sel) {
    final tema = Theme.of(context);
    final vizinhos = _vizinhos[sel.id] ?? const {};
    return Card(
      key: ValueKey(sel.id),
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          spacing: 6,
          children: [
            Text(sel.titulo, style: tema.textTheme.titleMedium),
            Text('${sel.tipo} · ${sel.grau} ligações${sel.tags.isEmpty ? '' : ' · #${sel.tags.join(' #')}'}', style: tema.textTheme.bodySmall),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final id in vizinhos)
                    if (_porId[id] != null)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.link, size: 18),
                        title: Text(_porId[id]!.titulo),
                        onTap: () {
                          setState(() => _selecionado = id);
                          _atualizarFoco();
                        },
                      ),
                ],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () {
                    setState(() => _selecionado = null);
                    _atualizarFoco();
                  },
                  child: const Text('Fechar'),
                ),
                FilledButton(
                  onPressed: () async {
                    await abrirNota(context, widget.api.notas, sel.id);
                    _carregar();
                  },
                  child: const Text('Abrir nota'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Legenda extends StatelessWidget {
  const _Legenda({required this.cor, required this.texto});

  final Color cor;
  final String texto;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: 4,
    children: [
      Container(width: 9, height: 9, decoration: BoxDecoration(color: cor, shape: BoxShape.circle)),
      Text(texto, style: Theme.of(context).textTheme.labelSmall),
    ],
  );
}

class _PintorGrafo extends CustomPainter {
  _PintorGrafo({
    required this.nos,
    required this.arestas,
    required this.pos,
    required this.tam,
    required this.pontos,
    required this.cor,
    required this.foco,
    required this.vizinhos,
    required this.selecionado,
    required this.achados,
    required this.hubs,
    required this.t,
    required this.visor,
    required this.rotulos,
    required this.cores,
    required this.estiloTexto,
    super.repaint,
  });

  final List<NoGrafo> nos;
  final List<(int, int)> arestas;
  final Float64List pos, tam; // mutados a cada quadro pela animação
  final Float32List Function() pontos;
  final Color Function(NoGrafo) cor;
  final String? foco, selecionado;
  final Set<String> vizinhos, hubs, achados;
  final Animation<double> t;
  final TransformationController visor;
  final Map<String, TextPainter> rotulos;
  final ColorScheme cores;
  final TextStyle estiloTexto;

  bool _destaque(NoGrafo n) => n.id == foco || vizinhos.contains(n.id) || achados.contains(n.id);

  Offset _p(int i) => Offset(pos[2 * i], pos[2 * i + 1]);

  TextPainter _rotulo(String id, String texto, double tamanho, double alfa, bool forte) {
    final chave = '$id|${tamanho.round()}|${(alfa * 10).round()}|$forte';
    if (rotulos.length > 4000) rotulos.clear();
    return rotulos[chave] ??= TextPainter(
      text: TextSpan(
        text: texto,
        style: estiloTexto.copyWith(
          fontSize: tamanho.roundToDouble(),
          fontWeight: forte ? FontWeight.w600 : FontWeight.w400,
          color: cores.onSurface.withValues(alpha: (alfa * 10).round() / 10),
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 15 * tamanho);
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.translate(size.width / 2, size.height / 2);
    final escala = visor.value.getMaxScaleOnAxis();
    final f = Curves.easeOut.transform(t.value); // 0 = sem foco, 1 = foco total
    final px = 1 / escala; // 1 pixel de tela em unidades do canvas

    // arestas comuns num só draw call (linha fina de 1 px em qualquer zoom), já no progresso da animação
    canvas.drawRawPoints(
      ui.PointMode.lines,
      pontos(),
      Paint()
        ..strokeWidth = 0
        ..color = cores.onSurface.withValues(alpha: ui.lerpDouble(0.09, 0.03, f)!),
    );
    // arestas do nó em foco, na cor dele
    if (foco != null && f > 0) {
      final i = nos.indexWhere((n) => n.id == foco);
      if (i >= 0) {
        final linha = Paint()
          ..strokeWidth = 1.6 * px
          ..color = cor(nos[i]).withValues(alpha: 0.85 * f);
        for (final (a, b) in arestas) {
          if ((a == i || b == i) && tam[a] > 0 && tam[b] > 0) canvas.drawLine(_p(a), _p(b), linha);
        }
      }
    }

    final contorno = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2 * px
      ..color = cores.surface;
    final preenche = Paint();
    final pequeno = nos.length < 60;
    final rotuloComum = ((escala - 1.0) / 0.5).clamp(0.0, 1.0); // rótulos de todos aparecem com zoom
    final tamanhoTexto = (12 * px).clamp(5.0, 30.0);
    for (final (i, n) in nos.indexed) {
      final s = tam[i];
      if (s <= 0) continue;
      final p = _p(i);
      final destaque = _destaque(n);
      final alfa = destaque ? 1.0 : ui.lerpDouble(1, 0.13, f)!;
      var raio = _GrafoTelaState._raio(n) * s;
      if (n.id == foco) raio *= 1 + 0.35 * f;
      canvas.drawCircle(p, raio, preenche..color = cor(n).withValues(alpha: alfa));
      canvas.drawCircle(p, raio, contorno);
      if (n.id == selecionado) {
        canvas.drawCircle(p, raio + 4 * px, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 * px
          ..color = cores.onSurface);
      }
      final base = (destaque && f > 0) || hubs.contains(n.id) || pequeno ? 1.0 : rotuloComum;
      final alfaTexto = base * alfa * s.clamp(0.0, 1.0);
      if (alfaTexto < 0.08) continue;
      final texto = _rotulo(n.id, n.titulo, tamanhoTexto, alfaTexto, destaque && f > 0 || hubs.contains(n.id));
      texto.paint(canvas, p + Offset(-texto.width / 2, raio + 2 * px));
    }
  }

  @override
  bool shouldRepaint(_PintorGrafo antigo) => true;
}
