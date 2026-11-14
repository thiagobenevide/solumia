import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../api_esteira.dart';
import '../../models.dart';
import '../util.dart';
import 'fields.dart';

/// Manual editor of an animated graphic or a thumbnail, with the same state as the panel editor.
///
/// The preview is the frame rendered by the esteira (the same HTML that becomes the video/PNG): the app asks for the PNG on
/// each change (with a short wait to batch typing) and, while playing, frame after frame. The text
/// boxes show up outlined over the preview and can be dragged.
class EditorScreen extends StatefulWidget {
  const EditorScreen.graphic({
    super.key,
    required this.api,
    required this.ep,
    required this.index,
    this.start = 0,
  }) : kind = 'grafico',
       arquivo = '',
       background = '';

  const EditorScreen.thumb({super.key, required this.api, required this.ep, this.arquivo = '', this.background = ''})
    : kind = 'thumb',
      index = -1,
      start = 0;

  final ApiEsteira api;
  final String ep;
  final String kind;

  /// Graphic: index in graficos.json (-1 = new piece at [start]).
  final int index;
  final double start;

  /// Thumbnail: existing file in thumbs/ (empty = new) and initial background.
  final String arquivo;
  final String background;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  Json? _ctx;
  Object? _openError;
  late Json _state;
  Json? _previous;
  late int _i = widget.index;

  /// Rebuilds the fields when the state changes from outside the typing.
  int _generation = 0;

  Uint8List? _png;
  String? _previewError;
  int _version = 0;
  Timer? _wait;
  double _t = 0;
  bool _playing = false;

  final _request = TextEditingController();
  String _engine = 'claude';
  bool _thinking = false;
  String? _answerAi;
  List<String> _warningsAi = const [];
  String? _message;
  bool _badMessage = false;

  bool get _graphic => widget.kind == 'grafico';
  double get _w => (_ctx!['w'] as num).toDouble();
  double get _h => (_ctx!['h'] as num).toDouble();
  double get _duration => ((_state['dur'] as num?) ?? 1).toDouble().clamp(1, 600);
  List<Json> get _boxes => (_state['caixas'] as List).cast<Json>();

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    _wait?.cancel();
    _playing = false;
    _request.dispose();
    super.dispose();
  }

  static Json _copy(Object? v) => jsonDecode(jsonEncode(v)) as Json;

  Future<void> _open() async {
    try {
      final ctx = _graphic
          ? await widget.api.graphicEditor(widget.ep, widget.index, t: widget.start)
          : await widget.api.editorThumb(widget.ep, arquivo: widget.arquivo, background: widget.background);
      if (!mounted) return;
      setState(() {
        _ctx = ctx;
        _state = _copy(ctx['estado']);
        _state['caixas'] = [...?(_state['caixas'] as List?)];
        _engine = '${ctx['motor']}' == 'local' ? 'local' : 'claude';
        _t = _graphic ? _duration * 0.65 : 0;
      });
      _render();
    } catch (e) {
      if (mounted) setState(() => _openError = e);
    }
  }

  // ---------- Preview ----------

  /// State change: schedules a new frame (batches typing) and redraws.
  void _mudou({bool rebuildFields = false}) {
    setState(() {
      if (rebuildFields) _generation++;
    });
    _wait?.cancel();
    _wait = Timer(const Duration(milliseconds: 280), _render);
  }

  Future<void> _render() async {
    if (_playing) return; // the play loop already asks for frames with the current state
    final v = ++_version;
    try {
      final png = await widget.api.frame(widget.ep, widget.kind, _state, t: _t);
      if (mounted && v == _version) {
        setState(() {
          _png = png;
          _previewError = null;
        });
      }
    } catch (e) {
      if (mounted && v == _version) setState(() => _previewError = '$e');
    }
  }

  Future<void> _togglePlay() async {
    if (_playing) {
      setState(() => _playing = false);
      return;
    }
    setState(() => _playing = true);
    final clock = Stopwatch()..start();
    final base = _t;
    while (_playing && mounted) {
      final t = (base + clock.elapsedMilliseconds / 1000) % _duration;
      try {
        final png = await widget.api.frame(widget.ep, widget.kind, _state, t: t);
        if (!mounted || !_playing) break;
        setState(() {
          _t = t;
          _png = png;
          _previewError = null;
        });
      } catch (e) {
        if (mounted) {
          setState(() {
            _playing = false;
            _previewError = '$e';
          });
        }
      }
    }
  }

  // ---------- Actions ----------

  Future<void> _suggest() async {
    setState(() {
      _thinking = true;
      _answerAi = null;
      _warningsAi = const [];
    });
    try {
      final r = await widget.api.suggest(widget.ep, widget.kind, _state, _request.text, _engine);
      _previous = _copy(_state);
      _state = {..._state, ...r['estado'] as Json};
      _state['caixas'] = [...?(_state['caixas'] as List?)];
      _answerAi = '${r['explicacao'] ?? ''}'.isEmpty ? 'sugestão aplicada na prévia' : '${r['explicacao']}';
      _warningsAi = [for (final a in r['avisos'] as List? ?? const []) '$a'];
      _mudou(rebuildFields: true);
    } catch (e) {
      setState(() => _answerAi = 'Falhou: $e');
    } finally {
      if (mounted) setState(() => _thinking = false);
    }
  }

  void _undo() {
    if (_previous == null) return;
    _state = _previous!;
    _previous = null;
    _answerAi = null;
    _warningsAi = const [];
    _mudou(rebuildFields: true);
  }

  Future<void> _save() async {
    try {
      if (_graphic) {
        final newItem = await widget.api.saveGraphic(widget.ep, _i, _state);
        setState(() {
          _i = newItem;
          _message = 'Salvo. A renderização desta peça entrou na fila; depois rode a Montagem para o vídeo ter a mudança.';
          _badMessage = false;
        });
      } else {
        final file = await widget.api.saveThumb(widget.ep, _state);
        setState(() {
          _message = 'Salva como thumbs/$file. Em Thumbs, escolha a vaga do teste A/B.';
          _badMessage = false;
        });
      }
    } catch (e) {
      setState(() {
        _message = '$e';
        _badMessage = true;
      });
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Excluir este gráfico do vídeo?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Voltar')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Excluir')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await widget.api.deleteGraphic(widget.ep, _i);
    if (mounted) Navigator.pop(context);
  }

  // ---------- Text boxes ----------

  Json _boxDefault() => {
    'texto': '',
    'x': 8,
    'y': 70,
    'w': 60,
    'tam': (64 * _w / 1920).round(),
    'fonte': 'Inter',
    'peso': 800,
    'cor': '#f4f1ea',
    'cor_d': '',
    'fundo': 'nenhum',
    'cor_fundo': '#0a1122',
    'alinhar': 'left',
    'maiusculas': false,
    'entrada': 'subir',
    'atraso': 0.2,
    'vel': 0.6,
  };

  /// Adds boxes (sizes meant for the 1920 px frame) and, in box pieces, adjusts the veil.
  void _addBoxes(List<Json> list, [String? veu]) {
    final k = _w / 1920;
    _boxes.addAll([
      for (final c in list) {..._boxDefault(), ...c, 'tam': (((c['tam'] as num?) ?? 64) * k).round()},
    ]);
    if (veu != null && _state['modelo'] == 'caixas') (_state['dados'] as Json)['veu'] = veu;
    _mudou(rebuildFields: true);
  }

  List<(String, VoidCallback)> _presets() {
    final color = '${_ctx!['cor']}';
    return [
      (
        'Título + subtítulo',
        () => _addBoxes([
          {'texto': 'Título *forte*', 'y': 38, 'w': 70, 'tam': 110, 'peso': 900, 'maiusculas': true},
          {
            'texto': 'subtítulo explicativo',
            'y': 56,
            'w': 60,
            'tam': 44,
            'peso': 500,
            'cor': '#cbd5e1',
            'atraso': 0.5,
          },
        ], 'esquerda'),
      ),
      (
        'Legenda inferior',
        () => _addBoxes([
          {'texto': 'Legenda com *destaque*', 'y': 82, 'w': 70, 'tam': 48, 'peso': 700, 'fundo': 'vidro'},
        ]),
      ),
      (
        'Destaque central',
        () => _addBoxes([
          {
            'texto': '*NÚMERO*',
            'x': 10,
            'y': 38,
            'w': 80,
            'tam': 180,
            'peso': 900,
            'alinhar': 'center',
            'fundo': 'contorno',
            'entrada': 'zoom',
          },
        ], 'total'),
      ),
      for (final ci in (_ctx!['citacoes'] as List).cast<Json>())
        (
          'Fonte: ${'${ci['autores'] ?? ''}'.split(RegExp(r'[ ,]')).first} ${ci['ano'] ?? ''}',
          () => _addBoxes([
            {
              'texto': 'ESTUDO · ${ci['ano'] ?? ''}',
              'x': 6,
              'y': 52,
              'w': 60,
              'tam': 26,
              'fonte': 'Mono',
              'peso': 600,
              'cor': color,
              'maiusculas': true,
              'entrada': 'fade',
            },
            {
              'texto': '${ci['autores'] ?? ''}',
              'x': 6,
              'y': 57,
              'w': 60,
              'tam': 56,
              'peso': 800,
              'atraso': 0.3,
            },
            {
              'texto': '${ci['revista'] ?? ''}',
              'x': 6,
              'y': 66,
              'w': 60,
              'tam': 34,
              'fonte': 'Playfair',
              'peso': 500,
              'cor': '#cbd5e1',
              'atraso': 0.5,
            },
            if (ci['pt'] != null)
              {
                'texto': '“${ci['pt']}”',
                'x': 6,
                'y': 73,
                'w': 58,
                'tam': 34,
                'fonte': 'Playfair',
                'peso': 400,
                'fundo': 'tarja',
                'atraso': 0.9,
                'entrada': 'revelar',
              },
          ], 'esquerda'),
        ),
    ];
  }

  void _moveBox(int n, int d) {
    final m = n + d;
    if (m < 0 || m >= _boxes.length) return;
    final c = _boxes[n];
    _boxes[n] = _boxes[m];
    _boxes[m] = c;
    _mudou(rebuildFields: true);
  }

  // ---------- Tela ----------

  @override
  Widget build(BuildContext context) {
    final titulo = _graphic
        ? (_i < 0 ? 'Novo gráfico' : 'Gráfico ${_i + 1}${_ctx == null ? '' : ' de ${_ctx!['total']}'}')
        : 'Thumbnail';
    return Scaffold(
      appBar: AppBar(
        title: Text(titulo),
        actions: [
          if (_graphic && _i >= 0 && _ctx != null)
            TextButton(
              onPressed: _delete,
              child: Text('Excluir', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: FilledButton(
              onPressed: _ctx == null ? null : _save,
              child: Text(_graphic ? 'Salvar e renderizar' : 'Salvar thumb (PNG)'),
            ),
          ),
        ],
      ),
      body: _openError != null
          ? Empty('$_openError', icone: Icons.error_outline)
          : _ctx == null
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (context, area) {
                final preview = _blockPreview(context);
                final panel = _panel(context);
                if (area.maxWidth < 1000) {
                  return ListView(padding: const EdgeInsets.all(16), children: [preview, ...panel]);
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: preview),
                    ),
                    SizedBox(
                      width: 460,
                      child: ListView(padding: const EdgeInsets.fromLTRB(0, 16, 16, 16), children: panel),
                    ),
                  ],
                );
              },
            ),
    );
  }

  Widget _blockPreview(BuildContext context) {
    final vertical = _h > _w;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _message!,
              style: TextStyle(
                color: _badMessage ? Theme.of(context).colorScheme.error : Colors.teal.shade200,
              ),
            ),
          ),
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: vertical ? 420 : double.infinity),
            child: AspectRatio(aspectRatio: _w / _h, child: _preview()),
          ),
        ),
        if (_graphic)
          Row(
            children: [
              IconButton(
                tooltip: _playing ? 'pausar' : 'tocar',
                icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                onPressed: _togglePlay,
              ),
              Expanded(
                child: Slider(
                  value: _t.clamp(0, _duration),
                  max: _duration,
                  onChanged: (v) {
                    setState(() {
                      _playing = false;
                      _t = v;
                    });
                    _render();
                  },
                ),
              ),
              SizedBox(
                width: 110,
                child: Text(
                  '${_t.toStringAsFixed(2)} / ${_duration.toStringAsFixed(1)}s',
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
            ],
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('Prévia: ', style: Theme.of(context).textTheme.bodySmall),
            const EnginePill('py', label: 'Python + Chromium (no PC)'),
            Text(
              ' · arraste as caixas de texto na prévia para posicioná-las',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ],
    );
  }

  Widget _preview() => ClipRRect(
    borderRadius: BorderRadius.circular(12),
    child: LayoutBuilder(
      builder: (context, area) {
        final scale = area.maxWidth / _w;
        return Stack(
          fit: StackFit.expand,
          children: [
            if (_graphic) const CustomPaint(painter: _Checkerboard()) else const ColoredBox(color: Colors.black),
            if (_png != null) Image.memory(_png!, gaplessPlayback: true, fit: BoxFit.fill),
            for (final (n, c) in _boxes.indexed) _outline(n, c, area.biggest, scale),
            if (_previewError != null)
              ColoredBox(
                color: Colors.black.withValues(alpha: 0.7),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _previewError!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );

  /// Draggable outline of a box (height estimated from the font size and the text lines).
  Widget _outline(int n, Json c, Size area, double scale) {
    final lines = '${c['texto']}'.split('\n').length;
    final height = ((c['tam'] as num? ?? 64) * 1.25 * lines * scale).clamp(12.0, area.height);
    return Positioned(
      left: area.width * ((c['x'] as num?) ?? 0) / 100,
      top: area.height * ((c['y'] as num?) ?? 0) / 100,
      width: area.width * ((c['w'] as num?) ?? 50) / 100,
      height: height,
      child: MouseRegion(
        cursor: SystemMouseCursors.move,
        child: GestureDetector(
          onPanUpdate: (d) => setState(() {
            c['x'] = double.parse(
              (((c['x'] as num?) ?? 0) + d.delta.dx / area.width * 100).toStringAsFixed(1),
            );
            c['y'] = double.parse(
              (((c['y'] as num?) ?? 0) + d.delta.dy / area.height * 100).toStringAsFixed(1),
            );
          }),
          onPanEnd: (_) => _mudou(rebuildFields: true),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.lightBlueAccent.withValues(alpha: 0.7)),
            ),
            child: Align(
              alignment: Alignment.topLeft,
              child: Container(
                color: Colors.lightBlueAccent.withValues(alpha: 0.7),
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Text('${n + 1}', style: const TextStyle(fontSize: 10, color: Colors.black)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _panel(BuildContext context) => [
    _card(context, 'Assistente de IA', [
      const Text(
        'Descreva a mudança: "deixe mais impactante", "crie caixas com a fonte do estudo", "legenda curta embaixo". '
        'A sugestão aparece na prévia; nada é salvo sem você.',
      ),
      TextField(
        controller: _request,
        minLines: 2,
        maxLines: 4,
        decoration: const InputDecoration(
          hintText: 'o que mudar?',
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'claude', label: Text('Claude')),
              ButtonSegment(value: 'local', label: Text('LLM local')),
            ],
            selected: {_engine},
            onSelectionChanged: (v) => setState(() => _engine = v.first),
          ),
          FilledButton.tonal(
            onPressed: _thinking ? null : _suggest,
            child: Text(_thinking ? 'pensando…' : 'Sugerir'),
          ),
          if (_previous != null) TextButton(onPressed: _undo, child: const Text('Desfazer')),
        ],
      ),
      EnginePill(
        _engine,
        label: _engine == 'claude' ? 'Claude · assinatura, conta no teto' : 'LLM local · usa a GPU',
      ),
      if (_answerAi != null) Text(_answerAi!),
      for (final a in _warningsAi) Text('⚠ $a', style: const TextStyle(color: Colors.amber)),
    ]),
    _card(context, _graphic ? 'Peça' : 'Thumbnail', _graphic ? _graphicFields() : _thumbFields()),
    if (_graphic) _card(context, 'Efeitos e transições', [_effectFields()]),
    _card(context, 'Caixas de texto', [
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          FilledButton.tonalIcon(
            icon: const Icon(Icons.add, size: 18),
            label: const Text('caixa'),
            onPressed: () => _addBoxes([
              {'texto': 'Novo *texto*'},
            ]),
          ),
          for (final (label, acao) in _presets()) ActionChip(label: Text(label), onPressed: acao),
        ],
      ),
      for (final (n, c) in _boxes.indexed) _box(context, n, c),
    ]),
  ];

  Widget _card(BuildContext context, String titulo, List<Widget> children) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          Text(titulo, style: Theme.of(context).textTheme.titleSmall),
          ...children,
        ],
      ),
    ),
  );

  Key _k(String nome) => ValueKey('$_generation/$nome');

  List<Widget> _thumbFields() {
    void set(String k, Object? v) {
      _state[k] = v;
      _mudou();
    }

    final backgrounds = [for (final f in _ctx!['fundos'] as List) '$f'];
    return [
      FieldsGrid(
        columns: 2,
        largos: const {0},
        children: [
          TextInputField(
            'Texto (2–4 palavras)',
            _state['texto'],
            (v) => set('texto', v),
            key: _k('texto'),
            lines: 2,
          ),
          TextInputField(
            'Palavra em destaque',
            _state['destaque'],
            (v) => set('destaque', v),
            key: _k('destaque'),
          ),
          TextInputField('Selo (opcional)', _state['selo'], (v) => set('selo', v), key: _k('selo')),
          OptionsField(
            'Layout',
            '${_state['layout']}',
            const ['rosto_direita', 'rosto_esquerda', 'numero'],
            (v) => set('layout', v),
            key: _k('layout'),
          ),
          NumberField(
            'Tamanho do texto (px, vazio = auto)',
            _state['tamanho'] as num?,
            (v) => set('tamanho', v),
            key: _k('tamanho'),
          ),
          TextInputField(
            'Cor do destaque',
            _state['cor_d'],
            (v) => set('cor_d', v),
            key: _k('cor_d'),
            color: true,
          ),
          TextInputField(
            'Cor de alerta (selo/seta)',
            _state['alerta'],
            (v) => set('alerta', v),
            key: _k('alerta'),
            color: true,
          ),
          OptionsField('Fundo', '${_state['fundo']}', backgrounds, (v) => set('fundo', v), key: _k('fundo')),
          BoolField('Seta', _state['seta'] == true, (v) => set('seta', v), key: _k('seta')),
        ],
      ),
    ];
  }

  List<Widget> _graphicFields() {
    final dados = _state['dados'] as Json;
    final newItem = _i < 0;
    final campos = <Widget>[];
    final largos = <int>{};
    for (final MapEntry(key: chave, value: valor) in dados.entries) {
      void change(Object? v) {
        dados[chave] = v;
        _mudou();
      }

      if (chave == 'arquivo') {
        largos.add(campos.length);
        campos.add(TextInputField('PDF', '$valor'.split('/').last, (_) {}, key: _k('d.$chave'), active: false));
      } else if (chave == 'veu') {
        largos.add(campos.length);
        campos.add(
          OptionsField(
            'Véu (escurece a cena para dar leitura)',
            '$valor',
            const ['nenhum', 'baixo', 'esquerda', 'total'],
            change,
            key: _k('d.$chave'),
          ),
        );
      } else if (valor is num) {
        campos.add(NumberField(chave, valor, change, key: _k('d.$chave')));
      } else if (valor is bool) {
        campos.add(BoolField(chave, valor, change, key: _k('d.$chave')));
      } else if (valor is String) {
        final longo = valor.length > 50 || chave == 'texto';
        if (longo) largos.add(campos.length);
        campos.add(
          TextInputField(
            chave == 'trecho' ? 'trecho (como está no PDF)' : chave,
            valor,
            change,
            key: _k('d.$chave'),
            lines: longo ? 2 : 1,
          ),
        );
      } else {
        largos.add(campos.length);
        campos.add(JsonField(chave, valor, change, key: _k('d.$chave')));
      }
    }
    return [
      FieldsGrid(
        children: [
          newItem
              ? OptionsField('Modelo', '${_state['modelo']}', const ['caixas'], (v) {
                  _state['modelo'] = v;
                  _state['dados'] = {'veu': 'baixo'};
                  _mudou(rebuildFields: true);
                }, key: _k('modelo'))
              : TextInputField('Modelo', _state['modelo'], (_) {}, key: _k('modelo'), active: false),
          NumberField(
            'Início (s)',
            _state['inicio'] as num?,
            (v) => _state['inicio'] = v ?? 0,
            key: _k('inicio'),
          ),
          NumberField('Duração (s)', _state['dur'] as num?, (v) {
            _state['dur'] = v ?? 1;
            _mudou();
          }, key: _k('dur')),
        ],
      ),
      FieldsGrid(columns: 2, largos: largos, children: campos),
      Text('*asteriscos* marcam a palavra em destaque.', style: Theme.of(context).textTheme.bodySmall),
    ];
  }

  Widget _effectFields() {
    final ef = (_state['efeito'] ??= <String, dynamic>{}) as Map;
    void set(String k, Object? v) {
      ef[k] = v;
      _mudou();
    }

    return FieldsGrid(
      children: [
        OptionsField(
          'Entrada',
          '${ef['entrada'] ?? 'padrao'}',
          const ['padrao', 'nenhuma', 'fade', 'subir', 'zoom', 'deslizar', 'desfoque', 'revelar'],
          (v) => set('entrada', v),
          key: _k('ef.entrada'),
        ),
        OptionsField(
          'Saída',
          '${ef['saida'] ?? 'padrao'}',
          const ['padrao', 'nenhuma', 'fade', 'zoom', 'deslizar', 'descer'],
          (v) => set('saida', v),
          key: _k('ef.saida'),
        ),
        NumberField('Velocidade (s)', (ef['vel'] as num?) ?? 0.6, (v) => set('vel', v), key: _k('ef.vel')),
      ],
    );
  }

  Widget _box(BuildContext context, int n, Json c) {
    void set(String k, Object? v) {
      c[k] = v;
      _mudou();
    }

    final p = 'cx$n';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('caixa ${n + 1}', style: TextStyle(color: Theme.of(context).colorScheme.primary)),
              ),
              IconButton(
                tooltip: 'subir',
                icon: const Icon(Icons.arrow_upward, size: 18),
                onPressed: () => _moveBox(n, -1),
              ),
              IconButton(
                tooltip: 'descer',
                icon: const Icon(Icons.arrow_downward, size: 18),
                onPressed: () => _moveBox(n, 1),
              ),
              IconButton(
                tooltip: 'duplicar',
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () {
                  _boxes.insert(n + 1, {...c, 'y': (((c['y'] as num?) ?? 0) + 8).clamp(0, 95)});
                  _mudou(rebuildFields: true);
                },
              ),
              IconButton(
                tooltip: 'remover',
                icon: const Icon(Icons.delete_outline, size: 18),
                onPressed: () {
                  _boxes.removeAt(n);
                  _mudou(rebuildFields: true);
                },
              ),
            ],
          ),
          FieldsGrid(
            largos: const {0},
            children: [
              TextInputField('Texto', c['texto'], (v) => set('texto', v), key: _k('$p.texto'), lines: 2),
              NumberField('x %', c['x'] as num?, (v) => set('x', v), key: _k('$p.x')),
              NumberField('y %', c['y'] as num?, (v) => set('y', v), key: _k('$p.y')),
              NumberField('largura %', c['w'] as num?, (v) => set('w', v), key: _k('$p.w')),
              NumberField('Tamanho px', c['tam'] as num?, (v) => set('tam', v), key: _k('$p.tam')),
              OptionsField(
                'Fonte',
                '${c['fonte']}',
                const ['Inter', 'Playfair', 'Mono'],
                (v) => set('fonte', v),
                key: _k('$p.fonte'),
              ),
              OptionsField(
                'Peso',
                '${c['peso']}',
                const ['300', '400', '500', '600', '700', '800', '900'],
                (v) => set('peso', int.parse(v)),
                key: _k('$p.peso'),
              ),
              TextInputField('Cor', c['cor'], (v) => set('cor', v), key: _k('$p.cor'), color: true),
              TextInputField('Cor destaque', c['cor_d'], (v) => set('cor_d', v), key: _k('$p.cor_d'), color: true),
              OptionsField(
                'Alinhar',
                '${c['alinhar']}',
                const ['left', 'center', 'right'],
                (v) => set('alinhar', v),
                key: _k('$p.alinhar'),
              ),
              OptionsField(
                'Fundo',
                '${c['fundo']}',
                const ['nenhum', 'solido', 'vidro', 'tarja', 'contorno'],
                (v) => set('fundo', v),
                key: _k('$p.fundo'),
              ),
              TextInputField(
                'Cor do fundo',
                c['cor_fundo'],
                (v) => set('cor_fundo', v),
                key: _k('$p.cor_fundo'),
                color: true,
              ),
              BoolField(
                'Maiúsculas',
                c['maiusculas'] == true,
                (v) => set('maiusculas', v),
                key: _k('$p.maiusculas'),
              ),
              if (_graphic) ...[
                OptionsField(
                  'Entrada',
                  '${c['entrada']}',
                  const ['subir', 'fade', 'zoom', 'esquerda', 'revelar', 'nenhuma'],
                  (v) => set('entrada', v),
                  key: _k('$p.entrada'),
                ),
                NumberField('Atraso (s)', c['atraso'] as num?, (v) => set('atraso', v), key: _k('$p.atraso')),
                NumberField('Velocidade (s)', c['vel'] as num?, (v) => set('vel', v), key: _k('$p.vel')),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Checkerboard background of the graphic preview (the piece has transparency; in the video it sits over the scene).
class _Checkerboard extends CustomPainter {
  const _Checkerboard();

  @override
  void paint(Canvas canvas, Size size) {
    const side = 16.0;
    final a = Paint()..color = const Color(0xFF1B2030);
    final b = Paint()..color = const Color(0xFF232A3D);
    for (var y = 0.0; y < size.height; y += side) {
      for (var x = 0.0; x < size.width; x += side) {
        canvas.drawRect(Rect.fromLTWH(x, y, side, side), ((x + y) ~/ side).isEven ? a : b);
      }
    }
  }

  @override
  bool shouldRepaint(_Checkerboard old) => false;
}
