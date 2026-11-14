import 'dart:math' as math;

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_arquivos.dart';
import '../leitor/dados_tela.dart';
import '../modelos.dart';
import '../telas/acoes_destaque.dart';
import 'xlsx.dart';

/// Editor de XLSX no estilo Excel: barra de fórmula, grade com cabeçalhos fixos (só constrói o
/// visível), abas embaixo. Toque numa célula seleciona; tocar de novo, Enter, F2 ou digitar edita.
class PlanilhaTela extends StatefulWidget {
  const PlanilhaTela({super.key, required this.api, required this.arquivo});

  final ApiArquivos api;
  final Arquivo arquivo;

  @override
  State<PlanilhaTela> createState() => _PlanilhaTelaState();
}

class _PlanilhaTelaState extends State<PlanilhaTela> {
  static const _largura = 104.0;
  static const _altura = 28.0;
  static const _larguraNumero = 56.0;

  late final Future<void> _carga = _ler();
  Pasta? _pasta;
  int _aba = 0;
  int _linha = 0;
  int _coluna = 0;
  bool _editando = false;
  bool _salvando = false;

  final _formula = TextEditingController();
  final _celula = TextEditingController();
  final _foco = FocusNode(debugLabel: 'grade');
  final _focoCelula = FocusNode(debugLabel: 'celula');
  final _focoFormula = FocusNode(debugLabel: 'formula');
  final _h = ScrollController();
  final _v = ScrollController();
  final _vNumeros = ScrollController();

  Aba get _folha => _pasta!.abas[_aba];
  bool get _sujo => _pasta?.alterada ?? false;

  @override
  void initState() {
    super.initState();
    _v.addListener(() {
      if (_vNumeros.hasClients && _vNumeros.offset != _v.offset) _vNumeros.jumpTo(_v.offset);
    });
  }

  @override
  void dispose() {
    for (final c in [_formula, _celula]) {
      c.dispose();
    }
    for (final f in [_foco, _focoCelula, _focoFormula]) {
      f.dispose();
    }
    for (final s in [_h, _v, _vNumeros]) {
      s.dispose();
    }
    super.dispose();
  }

  Future<void> _ler() async {
    final id = widget.arquivo.id;
    final bytes = await widget.api.offline.original(id) ?? await widget.api.original(id);
    _pasta = Pasta.ler(bytes);
    _formula.text = _folha.conteudo(0, 0);
  }

  // ------------------------------------------------------------- edição

  void _selecionar(int linha, int coluna, {bool editar = false, String? inicial}) {
    _confirmar();
    final l = linha.clamp(0, maxLinhas - 1), c = coluna.clamp(0, maxColunas - 1);
    setState(() {
      _linha = l;
      _coluna = c;
      _formula.text = _folha.conteudo(l, c);
      _editando = editar;
      if (editar) {
        _celula.text = inicial ?? _formula.text;
        _celula.selection = TextSelection.collapsed(offset: _celula.text.length);
      }
    });
    if (!editar) _foco.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) => _mostrarSelecao());
  }

  /// Grava o que está no editor da célula (se aberto) na célula selecionada.
  void _confirmar() {
    if (!_editando) return;
    _definir(_celula.text);
    _editando = false;
  }

  void _definir(String valor) {
    if (_folha.conteudo(_linha, _coluna) == valor) return;
    setState(() {
      _folha.definir(_linha, _coluna, valor);
      _formula.text = _folha.conteudo(_linha, _coluna);
    });
  }

  void _cancelar() {
    setState(() {
      _editando = false;
      _formula.text = _folha.conteudo(_linha, _coluna);
    });
    _foco.requestFocus();
  }

  void _mover(int dl, int dc) => _selecionar(_linha + dl, _coluna + dc);

  void _mostrarSelecao() {
    void ajustar(ScrollController s, double inicio, double tamanho) {
      if (!s.hasClients) return;
      final p = s.position;
      if (inicio < p.pixels) {
        s.jumpTo(inicio);
      } else if (inicio + tamanho > p.pixels + p.viewportDimension) {
        s.jumpTo(math.min(inicio + tamanho - p.viewportDimension, p.maxScrollExtent));
      }
    }

    ajustar(_v, _linha * _altura, _altura);
    ajustar(_h, _coluna * _largura, _largura);
  }

  KeyEventResult _tecla(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final teclado = HardwareKeyboard.instance;
    final shift = teclado.isShiftPressed;
    final ctrl = teclado.isControlPressed || teclado.isMetaPressed;
    final k = e.logicalKey;
    if (ctrl && k == LogicalKeyboardKey.keyS) {
      if (_sujo && !_salvando) _salvar();
      return KeyEventResult.handled;
    }
    if (_editando) {
      if (k == LogicalKeyboardKey.escape) {
        _cancelar();
      } else if (k == LogicalKeyboardKey.tab) {
        _mover(0, shift ? -1 : 1);
      } else if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
        _mover(k == LogicalKeyboardKey.arrowUp ? -1 : 1, 0);
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }
    switch (k) {
      case LogicalKeyboardKey.arrowUp:
        _mover(-1, 0);
      case LogicalKeyboardKey.arrowDown:
        _mover(1, 0);
      case LogicalKeyboardKey.arrowLeft:
        _mover(0, -1);
      case LogicalKeyboardKey.arrowRight:
        _mover(0, 1);
      case LogicalKeyboardKey.tab:
        _mover(0, shift ? -1 : 1);
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter || LogicalKeyboardKey.f2:
        _selecionar(_linha, _coluna, editar: true);
      case LogicalKeyboardKey.delete || LogicalKeyboardKey.backspace:
        _definir('');
      default:
        final ch = e.character;
        if (ch == null || ch.isEmpty || ch.codeUnitAt(0) < 32 || ctrl || teclado.isAltPressed) {
          return KeyEventResult.ignored;
        }
        _selecionar(_linha, _coluna, editar: true, inicial: ch);
    }
    return KeyEventResult.handled;
  }

  void _estrutura(String acao) {
    _confirmar();
    final f = _folha;
    setState(() {
      switch (acao) {
        case 'linhaAcima':
          f.inserirLinha(_linha);
        case 'linhaAbaixo':
          f.inserirLinha(_linha + 1);
        case 'excluirLinha':
          f.excluirLinha(_linha);
        case 'colunaEsquerda':
          f.inserirColuna(_coluna);
        case 'colunaDireita':
          f.inserirColuna(_coluna + 1);
        case 'excluirColuna':
          f.excluirColuna(_coluna);
      }
      _formula.text = f.conteudo(_linha, _coluna);
    });
    _foco.requestFocus();
  }

  void _trocarAba(int i) {
    _confirmar();
    setState(() {
      _aba = i;
      _linha = 0;
      _coluna = 0;
      _formula.text = _folha.conteudo(0, 0);
    });
    for (final s in [_h, _v]) {
      if (s.hasClients) s.jumpTo(0);
    }
    _foco.requestFocus();
  }

  Future<void> _salvar() async {
    _confirmar();
    setState(() => _salvando = true);
    try {
      final bytes = _pasta!.gravar();
      final novo = await widget.api.offline.salvarOriginal(widget.arquivo, bytes);
      // Relê o que foi gravado: vira a nova base para os próximos salvamentos.
      _pasta = Pasta.ler(bytes);
      if (mounted) avisar(context, novo == null ? 'Sem conexão: salvo no aparelho; sobe quando a conexão voltar.' : 'Salvo.');
    } on ApiErro catch (e) {
      if (mounted) avisar(context, 'Não consegui salvar: ${e.mensagem}');
    } on XlsxInvalido catch (e) {
      if (mounted) avisar(context, 'Não consegui gerar a planilha: ${e.mensagem}');
    } finally {
      if (mounted) setState(() => _salvando = false);
    }
  }

  // ---------------------------------------------------------------- telas

  @override
  Widget build(BuildContext context) => GuardaSaida(
    sujo: _sujo,
    child: Scaffold(
      appBar: AppBar(
        title: Text(widget.arquivo.titulo, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              onPressed: _sujo && !_salvando ? _salvar : null,
              icon: _salvando
                  ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save_outlined),
              label: const Text('Salvar'),
            ),
          ),
        ],
      ),
      body: FutureBuilder(
        future: _carga,
        builder: (context, s) {
          if (s.hasError) {
            final e = s.error;
            final msg = e is ApiErro ? e.mensagem : (e is XlsxInvalido ? e.mensagem : '$e');
            return Center(child: Text('Não consegui abrir: $msg'));
          }
          if (s.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          return Column(
            children: [
              _barraFormula(),
              const Divider(height: 1),
              Expanded(
                child: Focus(focusNode: _foco, autofocus: true, onKeyEvent: _tecla, child: _grade()),
              ),
              const Divider(height: 1),
              _abas(),
            ],
          );
        },
      ),
    ),
  );

  Widget _barraFormula() {
    final cores = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Row(
        spacing: 8,
        children: [
          Container(
            width: 72,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(border: Border.all(color: cores.outlineVariant), borderRadius: BorderRadius.circular(4)),
            child: Text(refCelula(_linha, _coluna), style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          Text('fx', style: TextStyle(fontStyle: FontStyle.italic, color: cores.outline)),
          Expanded(
            child: TextField(
              controller: _formula,
              focusNode: _focoFormula,
              decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), hintText: 'Valor ou =fórmula'),
              onTap: () {
                if (_editando) setState(() => _editando = false);
              },
              onSubmitted: (v) {
                _definir(v);
                _mover(1, 0);
              },
              onTapOutside: (_) {
                if (!_focoFormula.hasFocus) return;
                _definir(_formula.text);
                _focoFormula.unfocus();
              },
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Linhas e colunas',
            icon: const Icon(Icons.table_rows_outlined),
            onSelected: _estrutura,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'linhaAcima', child: Text('Inserir linha acima')),
              PopupMenuItem(value: 'linhaAbaixo', child: Text('Inserir linha abaixo')),
              PopupMenuItem(value: 'excluirLinha', child: Text('Excluir linha')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'colunaEsquerda', child: Text('Inserir coluna à esquerda')),
              PopupMenuItem(value: 'colunaDireita', child: Text('Inserir coluna à direita')),
              PopupMenuItem(value: 'excluirColuna', child: Text('Excluir coluna')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _abas() => SizedBox(
    height: 48,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      children: [
        for (var i = 0; i < _pasta!.abas.length; i++)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ChoiceChip(
              label: Text(_pasta!.abas[i].nome + (_pasta!.abas[i].alterada ? ' •' : '')),
              selected: i == _aba,
              onSelected: (_) => _trocarAba(i),
            ),
          ),
      ],
    ),
  );

  Widget _grade() {
    final cores = Theme.of(context).colorScheme;
    final borda = BorderSide(color: cores.outlineVariant, width: 0.5);
    final cabecalho = cores.surfaceContainerHighest;
    final f = _folha;
    return LayoutBuilder(
      builder: (context, box) {
        final larguraVisivel = math.max(0.0, box.maxWidth - _larguraNumero);
        final nLinhas = math.min(maxLinhas, math.max(math.max(f.linhas, _linha) + 50, (box.maxHeight / _altura).ceil() + 1));
        final nColunas = math.min(
          maxColunas,
          math.max(math.max(f.colunas, _coluna) + 10, (larguraVisivel / _largura).ceil() + 1),
        );

        Widget numero(int i) => GestureDetector(
          onTap: () => _selecionar(i, _coluna),
          child: Container(
            height: _altura,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: i == _linha ? cores.primaryContainer : cabecalho,
              border: Border(right: borda, bottom: borda),
            ),
            child: Text('${i + 1}', style: TextStyle(fontSize: 12, color: cores.onSurfaceVariant)),
          ),
        );

        Widget celula(int l, int c) {
          final selecionada = l == _linha && c == _coluna;
          final decoracao = BoxDecoration(border: Border(right: borda, bottom: borda));
          if (selecionada && _editando) {
            return Container(
              width: _largura,
              height: _altura,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(border: Border.all(color: cores.primary, width: 2), color: cores.surface),
              child: TextField(
                controller: _celula,
                focusNode: _focoCelula,
                autofocus: true,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(isDense: true, border: InputBorder.none, contentPadding: EdgeInsets.symmetric(vertical: 6)),
                onChanged: (v) => _formula.text = v,
                onSubmitted: (_) => _mover(1, 0),
                onTapOutside: (_) {
                  if (!_editando) return;
                  _confirmar();
                  setState(() {});
                },
              ),
            );
          }
          final texto = f.celula(l, c);
          final numerico = texto.isNotEmpty && double.tryParse(texto) != null;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _selecionar(l, c, editar: selecionada),
            onDoubleTap: () => _selecionar(l, c, editar: true),
            child: Container(
              width: _largura,
              height: _altura,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              alignment: numerico ? Alignment.centerRight : Alignment.centerLeft,
              decoration: decoracao,
              foregroundDecoration: selecionada ? BoxDecoration(border: Border.all(color: cores.primary, width: 2)) : null,
              child: Text(texto, maxLines: 1, overflow: TextOverflow.clip, softWrap: false, style: const TextStyle(fontSize: 13)),
            ),
          );
        }

        return ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: _larguraNumero,
                child: Column(
                  children: [
                    Container(
                      height: _altura,
                      decoration: BoxDecoration(color: cabecalho, border: Border(right: borda, bottom: borda)),
                    ),
                    Expanded(
                      child: ListView.builder(
                        controller: _vNumeros,
                        physics: const NeverScrollableScrollPhysics(),
                        itemExtent: _altura,
                        itemCount: nLinhas,
                        itemBuilder: (_, i) => numero(i),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Scrollbar(
                  controller: _h,
                  thumbVisibility: true,
                  child: Scrollbar(
                    controller: _v,
                    thumbVisibility: true,
                    notificationPredicate: (n) => n.depth == 1,
                    child: SingleChildScrollView(
                      controller: _h,
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: nColunas * _largura,
                        child: ListenableBuilder(
                          listenable: _h,
                          builder: (context, _) {
                            // Só as colunas na janela visível (mais uma de folga).
                            final deslocamento = _h.hasClients ? _h.offset : 0.0;
                            final c0 = math.max(0, (deslocamento / _largura).floor());
                            final c1 = math.min(nColunas, c0 + (larguraVisivel / _largura).ceil() + 1);
                            return Column(
                              children: [
                                Padding(
                                  padding: EdgeInsets.only(left: c0 * _largura),
                                  child: Row(
                                    children: [
                                      for (var c = c0; c < c1; c++)
                                        GestureDetector(
                                          onTap: () => _selecionar(_linha, c),
                                          child: Container(
                                            width: _largura,
                                            height: _altura,
                                            alignment: Alignment.center,
                                            decoration: BoxDecoration(
                                              color: c == _coluna ? cores.primaryContainer : cabecalho,
                                              border: Border(right: borda, bottom: borda),
                                            ),
                                            child: Text(
                                              letrasDaColuna(c),
                                              style: TextStyle(fontSize: 12, color: cores.onSurfaceVariant),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  child: ListView.builder(
                                    controller: _v,
                                    itemExtent: _altura,
                                    itemCount: nLinhas,
                                    itemBuilder: (_, l) => Padding(
                                      padding: EdgeInsets.only(left: c0 * _largura),
                                      child: Row(children: [for (var c = c0; c < c1; c++) celula(l, c)]),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
