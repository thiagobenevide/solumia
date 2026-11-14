import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../api_esteira.dart';
import '../../modelos.dart';
import '../util.dart';
import 'campos.dart';

/// Editor manual de gráfico animado ou thumbnail, com o mesmo estado do editor do painel.
///
/// A prévia é o quadro renderizado pela esteira (o mesmo HTML que vira o vídeo/PNG): o app pede o PNG a
/// cada mudança (com uma pequena espera para juntar digitação) e, tocando, quadro após quadro. As caixas de
/// texto aparecem contornadas por cima da prévia e podem ser arrastadas.
class EditorTela extends StatefulWidget {
  const EditorTela.grafico({
    super.key,
    required this.api,
    required this.ep,
    required this.indice,
    this.inicio = 0,
  }) : tipo = 'grafico',
       arquivo = '',
       fundo = '';

  const EditorTela.thumb({super.key, required this.api, required this.ep, this.arquivo = '', this.fundo = ''})
    : tipo = 'thumb',
      indice = -1,
      inicio = 0;

  final ApiEsteira api;
  final String ep;
  final String tipo;

  /// Gráfico: índice no graficos.json (-1 = peça nova em [inicio]).
  final int indice;
  final double inicio;

  /// Thumb: arquivo existente em thumbs/ (vazio = nova) e fundo inicial.
  final String arquivo;
  final String fundo;

  @override
  State<EditorTela> createState() => _EditorTelaState();
}

class _EditorTelaState extends State<EditorTela> {
  Json? _ctx;
  Object? _erroAbrir;
  late Json _estado;
  Json? _anterior;
  late int _i = widget.indice;

  /// Recria os campos quando o estado muda por fora da digitação.
  int _geracao = 0;

  Uint8List? _png;
  String? _erroPrevia;
  int _versao = 0;
  Timer? _espera;
  double _t = 0;
  bool _tocando = false;

  final _pedido = TextEditingController();
  String _motor = 'claude';
  bool _pensando = false;
  String? _respostaIa;
  List<String> _avisosIa = const [];
  String? _mensagem;
  bool _mensagemRuim = false;

  bool get _grafico => widget.tipo == 'grafico';
  double get _w => (_ctx!['w'] as num).toDouble();
  double get _h => (_ctx!['h'] as num).toDouble();
  double get _dur => ((_estado['dur'] as num?) ?? 1).toDouble().clamp(1, 600);
  List<Json> get _caixas => (_estado['caixas'] as List).cast<Json>();

  @override
  void initState() {
    super.initState();
    _abrir();
  }

  @override
  void dispose() {
    _espera?.cancel();
    _tocando = false;
    _pedido.dispose();
    super.dispose();
  }

  static Json _copia(Object? v) => jsonDecode(jsonEncode(v)) as Json;

  Future<void> _abrir() async {
    try {
      final ctx = _grafico
          ? await widget.api.editorGrafico(widget.ep, widget.indice, t: widget.inicio)
          : await widget.api.editorThumb(widget.ep, arquivo: widget.arquivo, fundo: widget.fundo);
      if (!mounted) return;
      setState(() {
        _ctx = ctx;
        _estado = _copia(ctx['estado']);
        _estado['caixas'] = [...?(_estado['caixas'] as List?)];
        _motor = '${ctx['motor']}' == 'local' ? 'local' : 'claude';
        _t = _grafico ? _dur * 0.65 : 0;
      });
      _renderizar();
    } catch (e) {
      if (mounted) setState(() => _erroAbrir = e);
    }
  }

  // ---------- Prévia ----------

  /// Mudança no estado: agenda um quadro novo (junta digitação) e redesenha.
  void _mudou({bool recriarCampos = false}) {
    setState(() {
      if (recriarCampos) _geracao++;
    });
    _espera?.cancel();
    _espera = Timer(const Duration(milliseconds: 280), _renderizar);
  }

  Future<void> _renderizar() async {
    if (_tocando) return; // o laço de tocar já pede quadros com o estado atual
    final v = ++_versao;
    try {
      final png = await widget.api.quadro(widget.ep, widget.tipo, _estado, t: _t);
      if (mounted && v == _versao) {
        setState(() {
          _png = png;
          _erroPrevia = null;
        });
      }
    } catch (e) {
      if (mounted && v == _versao) setState(() => _erroPrevia = '$e');
    }
  }

  Future<void> _alternarTocar() async {
    if (_tocando) {
      setState(() => _tocando = false);
      return;
    }
    setState(() => _tocando = true);
    final relogio = Stopwatch()..start();
    final base = _t;
    while (_tocando && mounted) {
      final t = (base + relogio.elapsedMilliseconds / 1000) % _dur;
      try {
        final png = await widget.api.quadro(widget.ep, widget.tipo, _estado, t: t);
        if (!mounted || !_tocando) break;
        setState(() {
          _t = t;
          _png = png;
          _erroPrevia = null;
        });
      } catch (e) {
        if (mounted) {
          setState(() {
            _tocando = false;
            _erroPrevia = '$e';
          });
        }
      }
    }
  }

  // ---------- Ações ----------

  Future<void> _sugerir() async {
    setState(() {
      _pensando = true;
      _respostaIa = null;
      _avisosIa = const [];
    });
    try {
      final r = await widget.api.sugerir(widget.ep, widget.tipo, _estado, _pedido.text, _motor);
      _anterior = _copia(_estado);
      _estado = {..._estado, ...r['estado'] as Json};
      _estado['caixas'] = [...?(_estado['caixas'] as List?)];
      _respostaIa = '${r['explicacao'] ?? ''}'.isEmpty ? 'sugestão aplicada na prévia' : '${r['explicacao']}';
      _avisosIa = [for (final a in r['avisos'] as List? ?? const []) '$a'];
      _mudou(recriarCampos: true);
    } catch (e) {
      setState(() => _respostaIa = 'Falhou: $e');
    } finally {
      if (mounted) setState(() => _pensando = false);
    }
  }

  void _desfazer() {
    if (_anterior == null) return;
    _estado = _anterior!;
    _anterior = null;
    _respostaIa = null;
    _avisosIa = const [];
    _mudou(recriarCampos: true);
  }

  Future<void> _salvar() async {
    try {
      if (_grafico) {
        final novo = await widget.api.salvarGrafico(widget.ep, _i, _estado);
        setState(() {
          _i = novo;
          _mensagem = 'Salvo. A renderização desta peça entrou na fila; depois rode a Montagem para o vídeo ter a mudança.';
          _mensagemRuim = false;
        });
      } else {
        final arq = await widget.api.salvarThumb(widget.ep, _estado);
        setState(() {
          _mensagem = 'Salva como thumbs/$arq. Em Thumbs, escolha a vaga do teste A/B.';
          _mensagemRuim = false;
        });
      }
    } catch (e) {
      setState(() {
        _mensagem = '$e';
        _mensagemRuim = true;
      });
    }
  }

  Future<void> _excluir() async {
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
    await widget.api.excluirGrafico(widget.ep, _i);
    if (mounted) Navigator.pop(context);
  }

  // ---------- Caixas de texto ----------

  Json _caixaPadrao() => {
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

  /// Acrescenta caixas (tamanhos pensados no quadro de 1920 px) e, nas peças de caixas, ajusta o véu.
  void _addCaixas(List<Json> lista, [String? veu]) {
    final k = _w / 1920;
    _caixas.addAll([
      for (final c in lista) {..._caixaPadrao(), ...c, 'tam': (((c['tam'] as num?) ?? 64) * k).round()},
    ]);
    if (veu != null && _estado['modelo'] == 'caixas') (_estado['dados'] as Json)['veu'] = veu;
    _mudou(recriarCampos: true);
  }

  List<(String, VoidCallback)> _presets() {
    final cor = '${_ctx!['cor']}';
    return [
      (
        'Título + subtítulo',
        () => _addCaixas([
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
        () => _addCaixas([
          {'texto': 'Legenda com *destaque*', 'y': 82, 'w': 70, 'tam': 48, 'peso': 700, 'fundo': 'vidro'},
        ]),
      ),
      (
        'Destaque central',
        () => _addCaixas([
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
          () => _addCaixas([
            {
              'texto': 'ESTUDO · ${ci['ano'] ?? ''}',
              'x': 6,
              'y': 52,
              'w': 60,
              'tam': 26,
              'fonte': 'Mono',
              'peso': 600,
              'cor': cor,
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

  void _moverCaixa(int n, int d) {
    final m = n + d;
    if (m < 0 || m >= _caixas.length) return;
    final c = _caixas[n];
    _caixas[n] = _caixas[m];
    _caixas[m] = c;
    _mudou(recriarCampos: true);
  }

  // ---------- Tela ----------

  @override
  Widget build(BuildContext context) {
    final titulo = _grafico
        ? (_i < 0 ? 'Novo gráfico' : 'Gráfico ${_i + 1}${_ctx == null ? '' : ' de ${_ctx!['total']}'}')
        : 'Thumbnail';
    return Scaffold(
      appBar: AppBar(
        title: Text(titulo),
        actions: [
          if (_grafico && _i >= 0 && _ctx != null)
            TextButton(
              onPressed: _excluir,
              child: Text('Excluir', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: FilledButton(
              onPressed: _ctx == null ? null : _salvar,
              child: Text(_grafico ? 'Salvar e renderizar' : 'Salvar thumb (PNG)'),
            ),
          ),
        ],
      ),
      body: _erroAbrir != null
          ? Vazio('$_erroAbrir', icone: Icons.error_outline)
          : _ctx == null
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (context, area) {
                final previa = _blocoPrevia(context);
                final painel = _painel(context);
                if (area.maxWidth < 1000) {
                  return ListView(padding: const EdgeInsets.all(16), children: [previa, ...painel]);
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: previa),
                    ),
                    SizedBox(
                      width: 460,
                      child: ListView(padding: const EdgeInsets.fromLTRB(0, 16, 16, 16), children: painel),
                    ),
                  ],
                );
              },
            ),
    );
  }

  Widget _blocoPrevia(BuildContext context) {
    final vertical = _h > _w;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_mensagem != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _mensagem!,
              style: TextStyle(
                color: _mensagemRuim ? Theme.of(context).colorScheme.error : Colors.teal.shade200,
              ),
            ),
          ),
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: vertical ? 420 : double.infinity),
            child: AspectRatio(aspectRatio: _w / _h, child: _previa()),
          ),
        ),
        if (_grafico)
          Row(
            children: [
              IconButton(
                tooltip: _tocando ? 'pausar' : 'tocar',
                icon: Icon(_tocando ? Icons.pause : Icons.play_arrow),
                onPressed: _alternarTocar,
              ),
              Expanded(
                child: Slider(
                  value: _t.clamp(0, _dur),
                  max: _dur,
                  onChanged: (v) {
                    setState(() {
                      _tocando = false;
                      _t = v;
                    });
                    _renderizar();
                  },
                ),
              ),
              SizedBox(
                width: 110,
                child: Text(
                  '${_t.toStringAsFixed(2)} / ${_dur.toStringAsFixed(1)}s',
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
            const SeloMotor('py', rotulo: 'Python + Chromium (no PC)'),
            Text(
              ' · arraste as caixas de texto na prévia para posicioná-las',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ],
    );
  }

  Widget _previa() => ClipRRect(
    borderRadius: BorderRadius.circular(12),
    child: LayoutBuilder(
      builder: (context, area) {
        final escala = area.maxWidth / _w;
        return Stack(
          fit: StackFit.expand,
          children: [
            if (_grafico) const CustomPaint(painter: _Xadrez()) else const ColoredBox(color: Colors.black),
            if (_png != null) Image.memory(_png!, gaplessPlayback: true, fit: BoxFit.fill),
            for (final (n, c) in _caixas.indexed) _contorno(n, c, area.biggest, escala),
            if (_erroPrevia != null)
              ColoredBox(
                color: Colors.black.withValues(alpha: 0.7),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _erroPrevia!,
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

  /// Contorno arrastável de uma caixa (altura estimada pelo tamanho da fonte e pelas linhas do texto).
  Widget _contorno(int n, Json c, Size area, double escala) {
    final linhas = '${c['texto']}'.split('\n').length;
    final altura = ((c['tam'] as num? ?? 64) * 1.25 * linhas * escala).clamp(12.0, area.height);
    return Positioned(
      left: area.width * ((c['x'] as num?) ?? 0) / 100,
      top: area.height * ((c['y'] as num?) ?? 0) / 100,
      width: area.width * ((c['w'] as num?) ?? 50) / 100,
      height: altura,
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
          onPanEnd: (_) => _mudou(recriarCampos: true),
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

  List<Widget> _painel(BuildContext context) => [
    _cartao(context, 'Assistente de IA', [
      const Text(
        'Descreva a mudança: "deixe mais impactante", "crie caixas com a fonte do estudo", "legenda curta embaixo". '
        'A sugestão aparece na prévia; nada é salvo sem você.',
      ),
      TextField(
        controller: _pedido,
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
            selected: {_motor},
            onSelectionChanged: (v) => setState(() => _motor = v.first),
          ),
          FilledButton.tonal(
            onPressed: _pensando ? null : _sugerir,
            child: Text(_pensando ? 'pensando…' : 'Sugerir'),
          ),
          if (_anterior != null) TextButton(onPressed: _desfazer, child: const Text('Desfazer')),
        ],
      ),
      SeloMotor(
        _motor,
        rotulo: _motor == 'claude' ? 'Claude · assinatura, conta no teto' : 'LLM local · usa a GPU',
      ),
      if (_respostaIa != null) Text(_respostaIa!),
      for (final a in _avisosIa) Text('⚠ $a', style: const TextStyle(color: Colors.amber)),
    ]),
    _cartao(context, _grafico ? 'Peça' : 'Thumbnail', _grafico ? _camposGrafico() : _camposThumb()),
    if (_grafico) _cartao(context, 'Efeitos e transições', [_camposEfeito()]),
    _cartao(context, 'Caixas de texto', [
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          FilledButton.tonalIcon(
            icon: const Icon(Icons.add, size: 18),
            label: const Text('caixa'),
            onPressed: () => _addCaixas([
              {'texto': 'Novo *texto*'},
            ]),
          ),
          for (final (rotulo, acao) in _presets()) ActionChip(label: Text(rotulo), onPressed: acao),
        ],
      ),
      for (final (n, c) in _caixas.indexed) _caixa(context, n, c),
    ]),
  ];

  Widget _cartao(BuildContext context, String titulo, List<Widget> filhos) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          Text(titulo, style: Theme.of(context).textTheme.titleSmall),
          ...filhos,
        ],
      ),
    ),
  );

  Key _k(String nome) => ValueKey('$_geracao/$nome');

  List<Widget> _camposThumb() {
    void set(String k, Object? v) {
      _estado[k] = v;
      _mudou();
    }

    final fundos = [for (final f in _ctx!['fundos'] as List) '$f'];
    return [
      GradeCampos(
        colunas: 2,
        largos: const {0},
        filhos: [
          CampoTexto(
            'Texto (2–4 palavras)',
            _estado['texto'],
            (v) => set('texto', v),
            key: _k('texto'),
            linhas: 2,
          ),
          CampoTexto(
            'Palavra em destaque',
            _estado['destaque'],
            (v) => set('destaque', v),
            key: _k('destaque'),
          ),
          CampoTexto('Selo (opcional)', _estado['selo'], (v) => set('selo', v), key: _k('selo')),
          CampoOpcoes(
            'Layout',
            '${_estado['layout']}',
            const ['rosto_direita', 'rosto_esquerda', 'numero'],
            (v) => set('layout', v),
            key: _k('layout'),
          ),
          CampoNumero(
            'Tamanho do texto (px, vazio = auto)',
            _estado['tamanho'] as num?,
            (v) => set('tamanho', v),
            key: _k('tamanho'),
          ),
          CampoTexto(
            'Cor do destaque',
            _estado['cor_d'],
            (v) => set('cor_d', v),
            key: _k('cor_d'),
            cor: true,
          ),
          CampoTexto(
            'Cor de alerta (selo/seta)',
            _estado['alerta'],
            (v) => set('alerta', v),
            key: _k('alerta'),
            cor: true,
          ),
          CampoOpcoes('Fundo', '${_estado['fundo']}', fundos, (v) => set('fundo', v), key: _k('fundo')),
          CampoBool('Seta', _estado['seta'] == true, (v) => set('seta', v), key: _k('seta')),
        ],
      ),
    ];
  }

  List<Widget> _camposGrafico() {
    final dados = _estado['dados'] as Json;
    final novo = _i < 0;
    final campos = <Widget>[];
    final largos = <int>{};
    for (final MapEntry(key: chave, value: valor) in dados.entries) {
      void mudar(Object? v) {
        dados[chave] = v;
        _mudou();
      }

      if (chave == 'arquivo') {
        largos.add(campos.length);
        campos.add(CampoTexto('PDF', '$valor'.split('/').last, (_) {}, key: _k('d.$chave'), ativo: false));
      } else if (chave == 'veu') {
        largos.add(campos.length);
        campos.add(
          CampoOpcoes(
            'Véu (escurece a cena para dar leitura)',
            '$valor',
            const ['nenhum', 'baixo', 'esquerda', 'total'],
            mudar,
            key: _k('d.$chave'),
          ),
        );
      } else if (valor is num) {
        campos.add(CampoNumero(chave, valor, mudar, key: _k('d.$chave')));
      } else if (valor is bool) {
        campos.add(CampoBool(chave, valor, mudar, key: _k('d.$chave')));
      } else if (valor is String) {
        final longo = valor.length > 50 || chave == 'texto';
        if (longo) largos.add(campos.length);
        campos.add(
          CampoTexto(
            chave == 'trecho' ? 'trecho (como está no PDF)' : chave,
            valor,
            mudar,
            key: _k('d.$chave'),
            linhas: longo ? 2 : 1,
          ),
        );
      } else {
        largos.add(campos.length);
        campos.add(CampoJson(chave, valor, mudar, key: _k('d.$chave')));
      }
    }
    return [
      GradeCampos(
        filhos: [
          novo
              ? CampoOpcoes('Modelo', '${_estado['modelo']}', const ['caixas'], (v) {
                  _estado['modelo'] = v;
                  _estado['dados'] = {'veu': 'baixo'};
                  _mudou(recriarCampos: true);
                }, key: _k('modelo'))
              : CampoTexto('Modelo', _estado['modelo'], (_) {}, key: _k('modelo'), ativo: false),
          CampoNumero(
            'Início (s)',
            _estado['inicio'] as num?,
            (v) => _estado['inicio'] = v ?? 0,
            key: _k('inicio'),
          ),
          CampoNumero('Duração (s)', _estado['dur'] as num?, (v) {
            _estado['dur'] = v ?? 1;
            _mudou();
          }, key: _k('dur')),
        ],
      ),
      GradeCampos(colunas: 2, largos: largos, filhos: campos),
      Text('*asteriscos* marcam a palavra em destaque.', style: Theme.of(context).textTheme.bodySmall),
    ];
  }

  Widget _camposEfeito() {
    final ef = (_estado['efeito'] ??= <String, dynamic>{}) as Map;
    void set(String k, Object? v) {
      ef[k] = v;
      _mudou();
    }

    return GradeCampos(
      filhos: [
        CampoOpcoes(
          'Entrada',
          '${ef['entrada'] ?? 'padrao'}',
          const ['padrao', 'nenhuma', 'fade', 'subir', 'zoom', 'deslizar', 'desfoque', 'revelar'],
          (v) => set('entrada', v),
          key: _k('ef.entrada'),
        ),
        CampoOpcoes(
          'Saída',
          '${ef['saida'] ?? 'padrao'}',
          const ['padrao', 'nenhuma', 'fade', 'zoom', 'deslizar', 'descer'],
          (v) => set('saida', v),
          key: _k('ef.saida'),
        ),
        CampoNumero('Velocidade (s)', (ef['vel'] as num?) ?? 0.6, (v) => set('vel', v), key: _k('ef.vel')),
      ],
    );
  }

  Widget _caixa(BuildContext context, int n, Json c) {
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
                onPressed: () => _moverCaixa(n, -1),
              ),
              IconButton(
                tooltip: 'descer',
                icon: const Icon(Icons.arrow_downward, size: 18),
                onPressed: () => _moverCaixa(n, 1),
              ),
              IconButton(
                tooltip: 'duplicar',
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () {
                  _caixas.insert(n + 1, {...c, 'y': (((c['y'] as num?) ?? 0) + 8).clamp(0, 95)});
                  _mudou(recriarCampos: true);
                },
              ),
              IconButton(
                tooltip: 'remover',
                icon: const Icon(Icons.delete_outline, size: 18),
                onPressed: () {
                  _caixas.removeAt(n);
                  _mudou(recriarCampos: true);
                },
              ),
            ],
          ),
          GradeCampos(
            largos: const {0},
            filhos: [
              CampoTexto('Texto', c['texto'], (v) => set('texto', v), key: _k('$p.texto'), linhas: 2),
              CampoNumero('x %', c['x'] as num?, (v) => set('x', v), key: _k('$p.x')),
              CampoNumero('y %', c['y'] as num?, (v) => set('y', v), key: _k('$p.y')),
              CampoNumero('largura %', c['w'] as num?, (v) => set('w', v), key: _k('$p.w')),
              CampoNumero('Tamanho px', c['tam'] as num?, (v) => set('tam', v), key: _k('$p.tam')),
              CampoOpcoes(
                'Fonte',
                '${c['fonte']}',
                const ['Inter', 'Playfair', 'Mono'],
                (v) => set('fonte', v),
                key: _k('$p.fonte'),
              ),
              CampoOpcoes(
                'Peso',
                '${c['peso']}',
                const ['300', '400', '500', '600', '700', '800', '900'],
                (v) => set('peso', int.parse(v)),
                key: _k('$p.peso'),
              ),
              CampoTexto('Cor', c['cor'], (v) => set('cor', v), key: _k('$p.cor'), cor: true),
              CampoTexto('Cor destaque', c['cor_d'], (v) => set('cor_d', v), key: _k('$p.cor_d'), cor: true),
              CampoOpcoes(
                'Alinhar',
                '${c['alinhar']}',
                const ['left', 'center', 'right'],
                (v) => set('alinhar', v),
                key: _k('$p.alinhar'),
              ),
              CampoOpcoes(
                'Fundo',
                '${c['fundo']}',
                const ['nenhum', 'solido', 'vidro', 'tarja', 'contorno'],
                (v) => set('fundo', v),
                key: _k('$p.fundo'),
              ),
              CampoTexto(
                'Cor do fundo',
                c['cor_fundo'],
                (v) => set('cor_fundo', v),
                key: _k('$p.cor_fundo'),
                cor: true,
              ),
              CampoBool(
                'Maiúsculas',
                c['maiusculas'] == true,
                (v) => set('maiusculas', v),
                key: _k('$p.maiusculas'),
              ),
              if (_grafico) ...[
                CampoOpcoes(
                  'Entrada',
                  '${c['entrada']}',
                  const ['subir', 'fade', 'zoom', 'esquerda', 'revelar', 'nenhuma'],
                  (v) => set('entrada', v),
                  key: _k('$p.entrada'),
                ),
                CampoNumero('Atraso (s)', c['atraso'] as num?, (v) => set('atraso', v), key: _k('$p.atraso')),
                CampoNumero('Velocidade (s)', c['vel'] as num?, (v) => set('vel', v), key: _k('$p.vel')),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Fundo xadrez da prévia do gráfico (a peça tem transparência; no vídeo fica sobre a cena).
class _Xadrez extends CustomPainter {
  const _Xadrez();

  @override
  void paint(Canvas canvas, Size size) {
    const lado = 16.0;
    final a = Paint()..color = const Color(0xFF1B2030);
    final b = Paint()..color = const Color(0xFF232A3D);
    for (var y = 0.0; y < size.height; y += lado) {
      for (var x = 0.0; x < size.width; x += lado) {
        canvas.drawRect(Rect.fromLTWH(x, y, lado, lado), ((x + y) ~/ lado).isEven ? a : b);
      }
    }
  }

  @override
  bool shouldRepaint(_Xadrez antigo) => false;
}
