import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:agent_core/agent_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_design.dart';
import 'modelo.dart';
import 'pintura.dart';

/// Carrega o wireframe [id] e abre o editor.
class AbrirWireframe extends StatelessWidget {
  const AbrirWireframe({super.key, required this.api, required this.id});

  final ApiDesign api;
  final String id;

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: api.obterWireframe(id),
    builder: (context, s) => s.hasData
        ? WireframeTela(api: api, wireframe: s.data!)
        : Scaffold(
            appBar: AppBar(),
            body: Center(child: s.hasError ? Text('Não abriu: ${s.error}') : const CircularProgressIndicator()),
          ),
  );
}

/// Editor de wireframe: telas (abas), paleta de componentes, prancha no estilo da referência
/// (`docs/wireframes-nd`) e painel de propriedades/notas. Grava sozinho 1,2 s depois da última mudança.
class WireframeTela extends StatefulWidget {
  const WireframeTela({super.key, required this.api, required this.wireframe});

  final ApiDesign api;
  final Wireframe wireframe;

  @override
  State<WireframeTela> createState() => _WireframeTelaState();
}

class _WireframeTelaState extends State<WireframeTela> {
  late Wireframe _wf = widget.wireframe;
  int _tela = 0;
  String? _sel;
  int _versaoPintura = 0;

  /// Sobe quando o documento muda por fora dos campos (desfazer, importação): refaz os painéis.
  int _recarga = 0;
  double _zoom = 1;
  Timer? _autosalvar;
  bool _salvando = false, _sujo = false;
  final List<String> _desfazer = [];
  final _foco = FocusNode();

  // Arrasto: deslocamento do ponteiro até o canto do componente; redimensionar = alça do canto.
  Offset? _pega;
  bool _redimensionando = false;

  TelaWf get _telaAtual => _wf.telas[_tela];
  List<Componente> get _visiveis => [for (final c in _wf.componentes) if (c.pagina == _telaAtual.id) c];
  Componente? get _selecionado => _wf.componentes.where((c) => c.id == _sel).firstOrNull;

  @override
  void dispose() {
    _autosalvar?.cancel();
    if (_sujo) unawaited(_salvar());
    _foco.dispose();
    super.dispose();
  }

  String _foto() => jsonEncode({
    'telas': [for (final t in _wf.telas) t.toJson()],
    'componentes': [for (final c in _wf.componentes) c.toJson()],
  });

  /// Toda mudança passa aqui: guarda o desfazer, repinta e agenda a gravação.
  void _mudar(VoidCallback f, {bool historico = true}) {
    if (historico) {
      _desfazer.add(_foto());
      if (_desfazer.length > 100) _desfazer.removeAt(0);
    }
    setState(() {
      f();
      _versaoPintura++;
      _sujo = true;
    });
    _autosalvar?.cancel();
    _autosalvar = Timer(const Duration(milliseconds: 1200), _salvar);
  }

  void _voltar() {
    if (_desfazer.isEmpty) return;
    final j = jsonDecode(_desfazer.removeLast()) as Map<String, dynamic>;
    _mudar(historico: false, () {
      _wf.telas
        ..clear()
        ..addAll([for (final t in j['telas'] as List) TelaWf.fromJson(t as Map<String, dynamic>)]);
      _wf.componentes
        ..clear()
        ..addAll([for (final c in j['componentes'] as List) Componente.fromJson(c as Map<String, dynamic>)]);
      _tela = _tela.clamp(0, _wf.telas.length - 1);
      _recarga++;
    });
  }

  Future<void> _salvar() async {
    if (_salvando || !_sujo) return;
    _salvando = true;
    _sujo = false;
    final mensageiro = ScaffoldMessenger.maybeOf(context);
    try {
      await widget.api.editarWireframe(_wf.id, titulo: _wf.titulo, telas: _wf.telas);
      final r = await widget.api.salvarWireframe(_wf.id, _wf.versao, _wf.componentes);
      _wf.versao = r.versao;
    } on ApiErro catch (e) {
      if (e.status == 409) {
        final atual = await widget.api.obterWireframe(_wf.id);
        if (mounted) setState(() => _trocarDocumento(atual));
        mensageiro?.showSnackBar(const SnackBar(content: Text('Outro aparelho gravou antes: abri a versão dele.')));
      } else {
        _sujo = true;
        mensageiro?.showSnackBar(SnackBar(content: Text('Não gravou: ${e.mensagem}')));
      }
    } catch (_) {
      _sujo = true;
    } finally {
      _salvando = false;
      if (mounted) setState(() {});
    }
  }

  void _trocarDocumento(Wireframe novo) {
    _wf = novo;
    _tela = _tela.clamp(0, _wf.telas.length - 1);
    _sel = null;
    _versaoPintura++;
    _recarga++;
  }

  // ---------- componentes ----------

  String _novoId(String tipo) {
    final ids = {for (final c in _wf.componentes) c.id};
    var n = 1;
    while (ids.contains('$tipo-$n')) {
      n++;
    }
    return '$tipo-$n';
  }

  void _adicionar(String tipo) {
    final (_, tamanho, props) = catalogo[tipo]!;
    final t = _telaAtual;
    final c = Componente(
      id: _novoId(tipo),
      tipo: tipo,
      pagina: t.id,
      caixa: Rect.fromCenter(center: Offset(t.largura / 2, t.altura / 3), width: tamanho.width, height: tamanho.height),
      props: jsonDecode(jsonEncode(props)) as Map<String, dynamic>,
    );
    ajustarTamanho(c);
    _mudar(() {
      _wf.componentes.add(c);
      _sel = c.id;
    });
  }

  void _excluir() {
    final c = _selecionado;
    if (c == null) return;
    _mudar(() {
      _wf.componentes.remove(c);
      _sel = null;
    });
  }

  void _duplicar() {
    final c = _selecionado;
    if (c == null) return;
    final copia = c.copiar(id: _novoId(c.tipo), deslocar: const Offset(16, 16));
    _mudar(() {
      _wf.componentes.add(copia);
      _sel = copia.id;
    });
  }

  /// Frente/fundo: a ordem da lista é a ordem de desenho.
  void _ordem(bool frente) {
    final c = _selecionado;
    if (c == null) return;
    _mudar(() {
      _wf.componentes.remove(c);
      frente ? _wf.componentes.add(c) : _wf.componentes.insert(0, c);
    });
  }

  void _mover(Offset d) {
    final c = _selecionado;
    if (c == null) return;
    _mudar(() {
      c.caixa = c.caixa.shift(d);
      _recarga++;
    });
  }

  // ---------- telas ----------

  void _novaTela() {
    final ids = {for (final t in _wf.telas) t.id};
    var n = _wf.telas.length + 1;
    while (ids.contains('tela-$n')) {
      n++;
    }
    final base = _telaAtual;
    _mudar(() {
      _wf.telas.add(TelaWf.fromJson({
        'id': 'tela-$n',
        'nome': 'Tela $n',
        'codigo': 'WF-${n.toString().padLeft(2, '0')}',
        'caminho': base.caminho,
        'largura': base.largura,
        'altura': base.altura,
      }));
      _tela = _wf.telas.length - 1;
      _sel = null;
    });
  }

  Future<void> _excluirTela() async {
    if (_wf.telas.length < 2) return;
    final t = _telaAtual;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Excluir a tela "${t.nome}"?'),
        content: const Text('Os componentes dela também saem.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Excluir')),
        ],
      ),
    );
    if (ok != true) return;
    _mudar(() {
      _wf.componentes.removeWhere((c) => c.pagina == t.id);
      _wf.telas.remove(t);
      _tela = math.max(0, _tela - 1);
      _sel = null;
    });
  }

  // ---------- IA ----------

  Future<void> _exportar(bool soJson) async {
    final mensageiro = ScaffoldMessenger.of(context);
    await _salvar();
    try {
      if (!soJson) {
        // As PNGs saem daqui (mesmo desenho do editor) e o servidor as põe no ZIP.
        for (final t in _wf.telas) {
          final png = await renderizarTela(t, [for (final c in _wf.componentes) if (c.pagina == t.id) c]);
          await widget.api.enviarPngTela(_wf.id, t.id, png);
        }
      }
      final bytes = await widget.api.exportarWireframe(_wf.id, soJson: soJson);
      final nome = _wf.titulo.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
      final salvo = await FilePicker.saveFile(
        fileName: '${nome.isEmpty ? 'wireframe' : nome}.wireframe.${soJson ? 'json' : 'zip'}',
        bytes: bytes,
        mimeType: soJson ? 'application/json' : 'application/zip',
      );
      if (salvo != null) mensageiro.showSnackBar(const SnackBar(content: Text('Pacote para IA exportado')));
    } catch (e) {
      mensageiro.showSnackBar(SnackBar(content: Text('Não exportou: $e')));
    }
  }

  Future<void> _importar() async {
    final mensageiro = ScaffoldMessenger.of(context);
    final a = (await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['json', 'zip', 'md', 'txt'])).firstOrNull;
    if (a == null) return;
    await _salvar();
    try {
      final novo = await widget.api.reimportarWireframe(_wf.id, a.name, await a.xFile.readAsBytes());
      _desfazer.add(_foto());
      setState(() => _trocarDocumento(novo));
      mensageiro.showSnackBar(const SnackBar(content: Text('Edição da IA aplicada (Ctrl+Z desfaz)')));
    } on ApiErro catch (e) {
      mensageiro.showSnackBar(SnackBar(content: Text('Não importou: ${e.mensagem}')));
    }
  }

  // ---------- entrada na prancha ----------

  Offset _naTela(Offset prancha) => prancha - Prancha(_telaAtual).origem;

  void _tocar(Offset p) {
    final pos = _naTela(p);
    final alvo = _visiveis.reversed.where((c) => c.caixa.inflate(4).contains(pos)).firstOrNull;
    setState(() => _sel = alvo?.id);
    _foco.requestFocus();
  }

  void _inicioArrasto(Offset p) {
    final pos = _naTela(p);
    final sel = _selecionado;
    if (sel != null && (pos - sel.caixa.bottomRight).distance < 12) {
      _redimensionando = true;
      _pega = Offset.zero;
    } else {
      _tocar(p);
      final c = _selecionado;
      _redimensionando = false;
      _pega = c == null ? null : pos - c.caixa.topLeft;
    }
    if (_pega != null) _desfazer.add(_foto());
  }

  void _arrasto(Offset p) {
    final c = _selecionado, pega = _pega;
    if (c == null || pega == null) return;
    final pos = _naTela(p);
    double grade(double v) => (v / 4).roundToDouble() * 4;
    _mudar(historico: false, () {
      if (_redimensionando) {
        c.caixa = Rect.fromLTRB(c.caixa.left, c.caixa.top, math.max(c.caixa.left + 8, grade(pos.dx)), math.max(c.caixa.top + 8, grade(pos.dy)));
      } else {
        final o = pos - pega;
        c.caixa = Rect.fromLTWH(grade(o.dx), grade(o.dy), c.caixa.width, c.caixa.height);
      }
    });
  }

  KeyEventResult _tecla(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final ctrl = HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;
    final passo = HardwareKeyboard.instance.isShiftPressed ? 10.0 : 1.0;
    final k = e.logicalKey;
    if (ctrl && k == LogicalKeyboardKey.keyZ) {
      _voltar();
    } else if (ctrl && k == LogicalKeyboardKey.keyD) {
      _duplicar();
    } else if (k == LogicalKeyboardKey.delete || k == LogicalKeyboardKey.backspace) {
      _excluir();
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      _mover(Offset(-passo, 0));
    } else if (k == LogicalKeyboardKey.arrowRight) {
      _mover(Offset(passo, 0));
    } else if (k == LogicalKeyboardKey.arrowUp) {
      _mover(Offset(0, -passo));
    } else if (k == LogicalKeyboardKey.arrowDown) {
      _mover(Offset(0, passo));
    } else if (k == LogicalKeyboardKey.escape) {
      setState(() => _sel = null);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // ---------- layout ----------

  Widget _prancha() {
    final tamanho = Prancha(_telaAtual).tamanho;
    return LayoutBuilder(
      builder: (context, box) {
        final escala = box.maxWidth / tamanho.width * _zoom;
        return InteractiveViewer(
          constrained: false,
          panEnabled: false,
          scaleEnabled: false,
          child: SizedBox(
            width: tamanho.width * escala,
            height: tamanho.height * escala,
            child: FittedBox(
              child: GestureDetector(
                onTapDown: (d) => _tocar(d.localPosition),
                onPanStart: (d) => _inicioArrasto(d.localPosition),
                onPanUpdate: (d) => _arrasto(d.localPosition),
                onPanEnd: (_) => setState(() {
                  _pega = null;
                  _recarga++;
                }),
                child: CustomPaint(
                  size: tamanho,
                  painter: PintorWireframe(_telaAtual, _visiveis, selecionado: _sel, versao: _versaoPintura),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _paleta() => ListView(
    padding: const EdgeInsets.all(8),
    children: [
      Text('Componentes', style: Theme.of(context).textTheme.titleSmall),
      for (final MapEntry(key: tipo, value: (rotulo, _, _)) in catalogo.entries)
        ListTile(dense: true, title: Text(rotulo), subtitle: Text(tipo), trailing: const Icon(Icons.add, size: 18), onTap: () => _adicionar(tipo)),
    ],
  );

  Widget _propriedades() {
    final c = _selecionado;
    return c == null
        ? _PainelTela(key: ValueKey('tela-${_telaAtual.id}-$_recarga'), tela: _telaAtual, aoMudar: (f) => _mudar(f))
        : _PainelComponente(
            key: ValueKey('comp-${c.id}-$_recarga'),
            c: c,
            aoMudar: (f) => _mudar(() {
              f();
              ajustarTamanho(c);
            }),
            aoExcluir: _excluir,
            aoDuplicar: _duplicar,
            aoOrdenar: _ordem,
          );
  }

  @override
  Widget build(BuildContext context) {
    final largo = MediaQuery.sizeOf(context).width >= 1100;
    return Focus(
      focusNode: _foco,
      autofocus: true,
      onKeyEvent: _tecla,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_wf.titulo),
          actions: [
            if (_salvando) const Padding(padding: EdgeInsets.all(16), child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))),
            IconButton(tooltip: 'Desfazer (Ctrl+Z)', onPressed: _desfazer.isEmpty ? null : _voltar, icon: const Icon(Icons.undo)),
            IconButton(tooltip: 'Diminuir', onPressed: () => setState(() => _zoom = math.max(.5, _zoom / 1.25)), icon: const Icon(Icons.zoom_out)),
            IconButton(tooltip: 'Aumentar', onPressed: () => setState(() => _zoom = math.min(4, _zoom * 1.25)), icon: const Icon(Icons.zoom_in)),
            PopupMenuButton<String>(
              tooltip: 'Trocar com outras IAs',
              icon: const Icon(Icons.smart_toy_outlined),
              onSelected: (v) => switch (v) {
                'zip' => _exportar(false),
                'json' => _exportar(true),
                _ => _importar(),
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'zip', child: Text('Exportar pacote para IA (.zip com PNG das telas)')),
                PopupMenuItem(value: 'json', child: Text('Exportar só o wireframe.json')),
                PopupMenuItem(value: 'importar', child: Text('Importar edição da IA…')),
              ],
            ),
            if (!largo) Builder(builder: (c) => IconButton(tooltip: 'Propriedades', onPressed: Scaffold.of(c).openEndDrawer, icon: const Icon(Icons.tune))),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(44),
            child: SizedBox(
              height: 44,
              child: Row(
                children: [
                  Expanded(
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      children: [
                        for (final (i, t) in _wf.telas.indexed)
                          Padding(
                            padding: const EdgeInsets.all(4),
                            child: ChoiceChip(
                              label: Text(t.codigo.isEmpty ? t.nome : '${t.codigo} · ${t.nome}'),
                              selected: i == _tela,
                              onSelected: (_) => setState(() {
                                _tela = i;
                                _sel = null;
                              }),
                            ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(tooltip: 'Nova tela', onPressed: _novaTela, icon: const Icon(Icons.add)),
                  IconButton(tooltip: 'Excluir tela', onPressed: _wf.telas.length < 2 ? null : _excluirTela, icon: const Icon(Icons.delete_outline)),
                ],
              ),
            ),
          ),
        ),
        drawer: largo ? null : Drawer(child: SafeArea(child: _paleta())),
        endDrawer: largo ? null : Drawer(width: 360, child: SafeArea(child: _propriedades())),
        body: largo
            ? Row(
                children: [
                  SizedBox(width: 200, child: _paleta()),
                  const VerticalDivider(width: 1),
                  Expanded(child: _prancha()),
                  const VerticalDivider(width: 1),
                  SizedBox(width: 340, child: _propriedades()),
                ],
              )
            : _prancha(),
      ),
    );
  }
}

// ---------- painéis ----------

class _Campo extends StatelessWidget {
  const _Campo(this.rotulo, this.valor, this.aoMudar, {this.linhas = 1, this.numero = false});

  final String rotulo, valor;
  final ValueChanged<String> aoMudar;
  final int linhas;
  final bool numero;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: TextFormField(
      initialValue: valor,
      minLines: linhas == 1 ? 1 : 3,
      maxLines: linhas,
      keyboardType: numero ? TextInputType.number : null,
      style: linhas > 1 ? const TextStyle(fontFamily: 'monospace', fontSize: 12) : null,
      decoration: InputDecoration(labelText: rotulo, isDense: true, border: const OutlineInputBorder()),
      onChanged: aoMudar,
    ),
  );
}

Widget _escolha<T>(String rotulo, T valor, List<T> opcoes, String Function(T) nome, ValueChanged<T> aoMudar) => Padding(
  padding: const EdgeInsets.only(bottom: 8),
  child: DropdownButtonFormField<T>(
    initialValue: opcoes.contains(valor) ? valor : null,
    isDense: true,
    decoration: InputDecoration(labelText: rotulo, border: const OutlineInputBorder()),
    items: [for (final o in opcoes) DropdownMenuItem(value: o, child: Text(nome(o)))],
    onChanged: (v) => v == null ? null : aoMudar(v),
  ),
);

/// Propriedades do componente: posição, estado, nota e as props do catálogo (listas em JSON).
class _PainelComponente extends StatefulWidget {
  const _PainelComponente({super.key, required this.c, required this.aoMudar, required this.aoExcluir, required this.aoDuplicar, required this.aoOrdenar});

  final Componente c;
  final void Function(VoidCallback) aoMudar;
  final VoidCallback aoExcluir, aoDuplicar;
  final ValueChanged<bool> aoOrdenar;

  @override
  State<_PainelComponente> createState() => _PainelComponenteState();
}

class _PainelComponenteState extends State<_PainelComponente> {
  final Map<String, String> _erros = {};

  Componente get c => widget.c;

  void _numero(String v, Rect Function(double) caixa) {
    final n = double.tryParse(v.replaceAll(',', '.'));
    if (n != null) widget.aoMudar(() => c.caixa = caixa(n));
  }

  Widget _prop(String k, Object? v) {
    if (v is bool) {
      return SwitchListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text(k), value: v, onChanged: (b) => widget.aoMudar(() => c.props[k] = b));
    }
    if (opcoesProps[k] case final opcoes?) {
      return _escolha<String>(k, '$v', opcoes, (o) => o, (o) => widget.aoMudar(() => c.props[k] = o));
    }
    if (v is List || v is Map || (k == 'destaque' && v == null)) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextFormField(
          initialValue: const JsonEncoder.withIndent('  ').convert(v),
          minLines: 3,
          maxLines: 14,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: InputDecoration(labelText: '$k (JSON)', isDense: true, border: const OutlineInputBorder(), errorText: _erros[k]),
          onChanged: (s) {
            try {
              final novo = jsonDecode(s);
              setState(() => _erros.remove(k));
              widget.aoMudar(() => c.props[k] = novo);
            } on FormatException catch (e) {
              setState(() => _erros[k] = e.message);
            }
          },
        ),
      );
    }
    if (v is num) {
      return _Campo(k, '$v', numero: true, (s) {
        final n = num.tryParse(s.replaceAll(',', '.'));
        if (n != null) widget.aoMudar(() => c.props[k] = n);
      });
    }
    return _Campo(k, '${v ?? ''}', (s) => widget.aoMudar(() => c.props[k] = s));
  }

  @override
  Widget build(BuildContext context) {
    // As chaves do catálogo aparecem mesmo que a IA não as tenha mandado; as extras também.
    final props = {...?catalogo[c.tipo]?.$3.map((k, v) => MapEntry(k, c.props.containsKey(k) ? c.props[k] : v)), ...c.props}..remove('nota');
    final r = c.caixa;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(
          children: [
            Expanded(child: Text('${catalogo[c.tipo]?.$1 ?? c.tipo} · ${c.id}', style: Theme.of(context).textTheme.titleSmall)),
            IconButton(tooltip: 'Trazer para frente', onPressed: () => widget.aoOrdenar(true), icon: const Icon(Icons.flip_to_front, size: 20)),
            IconButton(tooltip: 'Mandar para trás', onPressed: () => widget.aoOrdenar(false), icon: const Icon(Icons.flip_to_back, size: 20)),
            IconButton(tooltip: 'Duplicar (Ctrl+D)', onPressed: widget.aoDuplicar, icon: const Icon(Icons.copy, size: 20)),
            IconButton(tooltip: 'Excluir (Delete)', onPressed: widget.aoExcluir, icon: const Icon(Icons.delete_outline, size: 20)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          spacing: 8,
          children: [
            Expanded(child: _Campo('x', '${r.left.round()}', numero: true, (v) => _numero(v, (n) => Rect.fromLTWH(n, c.caixa.top, c.caixa.width, c.caixa.height)))),
            Expanded(child: _Campo('y', '${r.top.round()}', numero: true, (v) => _numero(v, (n) => Rect.fromLTWH(c.caixa.left, n, c.caixa.width, c.caixa.height)))),
            Expanded(child: _Campo('largura', '${r.width.round()}', numero: true, (v) => _numero(v, (n) => Rect.fromLTWH(c.caixa.left, c.caixa.top, n, c.caixa.height)))),
            Expanded(child: _Campo('altura', '${r.height.round()}', numero: true, (v) => _numero(v, (n) => Rect.fromLTWH(c.caixa.left, c.caixa.top, c.caixa.width, n)))),
          ],
        ),
        _escolha<EstadoWf>('estado', c.estado, EstadoWf.values, (e) => e.rotulo, (e) => widget.aoMudar(() => c.estado = e)),
        _Campo('nota (nº do painel; vazio = sem marcador)', '${c.nota ?? ''}', numero: true, (s) {
          final n = int.tryParse(s);
          widget.aoMudar(() => n == null ? c.props.remove('nota') : c.props['nota'] = n);
        }),
        const Divider(),
        for (final MapEntry(:key, :value) in props.entries) _prop(key, value),
      ],
    );
  }
}

/// Sem seleção: dados da tela (código, título, breadcrumb, tamanho) e as notas do painel lateral.
class _PainelTela extends StatelessWidget {
  const _PainelTela({super.key, required this.tela, required this.aoMudar});

  final TelaWf tela;
  final void Function(VoidCallback) aoMudar;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(12),
    children: [
      Text('Tela', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      _Campo('código', tela.codigo, (v) => aoMudar(() => tela.codigo = v)),
      _Campo('título', tela.nome, (v) => aoMudar(() => tela.nome = v)),
      _Campo('subtítulo', tela.subtitulo, (v) => aoMudar(() => tela.subtitulo = v)),
      _Campo('caminho (separado por ›)', tela.caminho.join(' › '), (v) => aoMudar(() => tela.caminho = [for (final p in v.split('›')) if (p.trim().isNotEmpty) p.trim()])),
      Row(
        spacing: 8,
        children: [
          Expanded(child: _Campo('largura', '${tela.largura.round()}', numero: true, (v) => aoMudar(() => tela.largura = double.tryParse(v) ?? tela.largura))),
          Expanded(child: _Campo('altura', '${tela.altura.round()}', numero: true, (v) => aoMudar(() => tela.altura = double.tryParse(v) ?? tela.altura))),
        ],
      ),
      const Divider(),
      Row(
        children: [
          Expanded(child: Text('Notas (painel lateral)', style: Theme.of(context).textTheme.titleSmall)),
          IconButton(
            tooltip: 'Nova nota',
            icon: const Icon(Icons.add),
            onPressed: () => aoMudar(() => tela.notas.add(Nota(tela.notas.fold(0, (m, n) => math.max(m, n.n)) + 1, titulo: 'Nova nota'))),
          ),
        ],
      ),
      for (final n in tela.notas)
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                Row(
                  spacing: 8,
                  children: [
                    SizedBox(width: 56, child: _Campo('nº', '${n.n}', numero: true, (v) => aoMudar(() => n.n = int.tryParse(v) ?? n.n))),
                    Expanded(child: _escolha<EstadoWf>('estado', n.estado, EstadoWf.values, (e) => e.rotulo, (e) => aoMudar(() => n.estado = e))),
                    IconButton(tooltip: 'Excluir nota', onPressed: () => aoMudar(() => tela.notas.remove(n)), icon: const Icon(Icons.close, size: 18)),
                  ],
                ),
                _Campo('título', n.titulo, (v) => aoMudar(() => n.titulo = v)),
                _Campo('linhas ("Rótulo: texto" por linha)', n.linhasTexto, linhas: 8, (v) => aoMudar(() => n.linhasTexto = v)),
              ],
            ),
          ),
        ),
    ],
  );
}
