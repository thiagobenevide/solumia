import 'dart:math';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../modelos.dart';
import 'estojo.dart';
import 'pintura.dart';

/// Diálogo da tabela: digitar nas células, pôr/tirar linhas e colunas, cores de fundo e de texto,
/// negrito e alinhamento. Clique marca a célula; Shift+clique marca o retângulo até ela. Devolve a
/// tabela nova (com as medidas refeitas pelo texto) ou null se cancelar.
Future<Tabela?> editarTabela(BuildContext context, Tabela tabela, Estojo estojo) =>
    showDialog<Tabela>(context: context, builder: (_) => _EditorTabela(tabela, estojo));

class _EditorTabela extends StatefulWidget {
  const _EditorTabela(this.tabela, this.estojo);

  final Tabela tabela;
  final Estojo estojo;

  @override
  State<_EditorTabela> createState() => _EditorTabelaState();
}

class _EditorTabelaState extends State<_EditorTabela> {
  late final List<List<Celula>> _celulas = [for (final l in widget.tabela.celulas) [...l]];
  late List<List<TextEditingController>> _textos = _controles();
  late bool _cabecalho = widget.tabela.cabecalho;
  late Color _grade = widget.tabela.cor;
  late double _tamanho = widget.tabela.tamanho;

  /// Célula onde o retângulo marcado começa ([_ancora]) e termina ([_atual]).
  (int, int) _ancora = (0, 0), _atual = (0, 0);

  int get _linhas => _celulas.length;
  int get _colunas => _celulas.isEmpty ? 0 : _celulas.first.length;

  List<List<TextEditingController>> _controles() => [
    for (final l in _celulas) [for (final c in l) TextEditingController(text: c.texto)],
  ];

  Iterable<(int, int)> get _marcadas sync* {
    for (var l = min(_ancora.$1, _atual.$1); l <= max(_ancora.$1, _atual.$1); l++) {
      for (var c = min(_ancora.$2, _atual.$2); c <= max(_ancora.$2, _atual.$2); c++) {
        yield (l, c);
      }
    }
  }

  bool _marcada(int l, int c) =>
      l >= min(_ancora.$1, _atual.$1) &&
      l <= max(_ancora.$1, _atual.$1) &&
      c >= min(_ancora.$2, _atual.$2) &&
      c <= max(_ancora.$2, _atual.$2);

  void _guardarTextos() {
    for (var l = 0; l < _linhas; l++) {
      for (var c = 0; c < _colunas; c++) {
        _celulas[l][c] = _celulas[l][c].copia(texto: _textos[l][c].text);
      }
    }
  }

  @override
  void dispose() {
    for (final l in _textos) {
      for (final t in l) {
        t.dispose();
      }
    }
    super.dispose();
  }

  /// Mudança de linhas/colunas: guarda o que foi digitado e refaz os campos.
  void _estrutura(void Function() mudar) {
    _guardarTextos();
    final antigos = _textos;
    mudar();
    _textos = _controles();
    _atual = (_atual.$1.clamp(0, _linhas - 1), _atual.$2.clamp(0, _colunas - 1));
    _ancora = _atual;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final l in antigos) {
        for (final t in l) {
          t.dispose();
        }
      }
    });
  }

  void _inserirLinha(int em) =>
      _estrutura(() => _celulas.insert(em, List.generate(_colunas, (_) => const Celula())));

  void _inserirColuna(int em) => _estrutura(() {
    for (final l in _celulas) {
      l.insert(em, const Celula());
    }
  });

  void _excluirLinhas() {
    final de = min(_ancora.$1, _atual.$1), ate = max(_ancora.$1, _atual.$1);
    if (ate - de + 1 >= _linhas) return;
    _estrutura(() => _celulas.removeRange(de, ate + 1));
  }

  void _excluirColunas() {
    final de = min(_ancora.$2, _atual.$2), ate = max(_ancora.$2, _atual.$2);
    if (ate - de + 1 >= _colunas) return;
    _estrutura(() {
      for (final l in _celulas) {
        l.removeRange(de, ate + 1);
      }
    });
  }

  void _aplicar(Celula Function(Celula) f) {
    _guardarTextos();
    setState(() {
      for (final (l, c) in _marcadas) {
        _celulas[l][c] = f(_celulas[l][c]);
      }
    });
  }

  Future<Color?> _cor(Color inicial) async {
    final c = await escolherCor(context, inicial, widget.estojo.recentes, paleta: coresRapidas);
    if (c != null) widget.estojo.lembrarCor(c);
    return c;
  }

  void _marcar(int l, int c) {
    setState(() {
      _atual = (l, c);
      if (!HardwareKeyboard.instance.isShiftPressed) _ancora = (l, c);
    });
  }

  Tabela _resultado() {
    _guardarTextos();
    return widget.tabela
        .copia(
          celulas: [for (final l in _celulas) List.unmodifiable(l)],
          larguras: List.filled(_colunas, 0),
          alturas: List.filled(_linhas, 0),
          cabecalho: _cabecalho,
          cor: _grade,
          tamanho: _tamanho,
        )
        .ajustada();
  }

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    final atual = _celulas[_atual.$1][_atual.$2];
    final tela = MediaQuery.sizeOf(context);
    return AlertDialog(
      title: const Text('Tabela'),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: min(960, tela.width * 0.9),
        height: min(600, tela.height * 0.7),
        child: Column(
          children: [
            Wrap(
              spacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                PopupMenuButton<VoidCallback>(
                  tooltip: 'Linhas',
                  onSelected: (f) => f(),
                  itemBuilder: (_) => [
                    PopupMenuItem(value: () => _inserirLinha(min(_ancora.$1, _atual.$1)), child: const Text('Inserir linha acima')),
                    PopupMenuItem(value: () => _inserirLinha(max(_ancora.$1, _atual.$1) + 1), child: const Text('Inserir linha abaixo')),
                    PopupMenuItem(value: _excluirLinhas, child: const Text('Excluir linha(s) marcada(s)')),
                  ],
                  child: const Chip(avatar: Icon(Icons.table_rows_outlined, size: 18), label: Text('Linhas')),
                ),
                PopupMenuButton<VoidCallback>(
                  tooltip: 'Colunas',
                  onSelected: (f) => f(),
                  itemBuilder: (_) => [
                    PopupMenuItem(value: () => _inserirColuna(min(_ancora.$2, _atual.$2)), child: const Text('Inserir coluna à esquerda')),
                    PopupMenuItem(value: () => _inserirColuna(max(_ancora.$2, _atual.$2) + 1), child: const Text('Inserir coluna à direita')),
                    PopupMenuItem(value: _excluirColunas, child: const Text('Excluir coluna(s) marcada(s)')),
                  ],
                  child: const Chip(avatar: Icon(Icons.view_column_outlined, size: 18), label: Text('Colunas')),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Cor de fundo das células marcadas',
                  icon: Icon(Icons.format_color_fill, color: atual.fundo),
                  onPressed: () async {
                    final c = await _cor(atual.fundo ?? Colors.white);
                    if (c != null) _aplicar((cel) => cel.copia(fundo: c));
                  },
                ),
                IconButton(
                  tooltip: 'Cor do texto das células marcadas',
                  icon: Icon(Icons.format_color_text, color: atual.corTexto),
                  onPressed: () async {
                    final c = await _cor(atual.corTexto ?? Colors.black);
                    if (c != null) _aplicar((cel) => cel.copia(corTexto: c));
                  },
                ),
                IconButton(
                  tooltip: 'Tirar as cores das células marcadas',
                  icon: const Icon(Icons.format_color_reset),
                  onPressed: () => _aplicar((cel) => cel.copia(semFundo: true, semCorTexto: true)),
                ),
                IconButton(
                  tooltip: 'Negrito',
                  isSelected: atual.negrito,
                  icon: const Icon(Icons.format_bold),
                  onPressed: () => _aplicar((cel) => cel.copia(negrito: !atual.negrito)),
                ),
                for (final (i, icone, dica) in [
                  (0, Icons.format_align_left, 'Alinhar à esquerda'),
                  (1, Icons.format_align_center, 'Centralizar'),
                  (2, Icons.format_align_right, 'Alinhar à direita'),
                ])
                  IconButton(
                    tooltip: dica,
                    isSelected: atual.alinhamento == i,
                    icon: Icon(icone),
                    onPressed: () => _aplicar((cel) => cel.copia(alinhamento: i)),
                  ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Cor da grade',
                  icon: Icon(Icons.border_all, color: _grade),
                  onPressed: () async {
                    final c = await _cor(_grade);
                    if (c != null) setState(() => _grade = c);
                  },
                ),
                IconButton(
                  tooltip: 'Letra menor',
                  icon: const Icon(Icons.text_decrease),
                  onPressed: _tamanho > 8 ? () => setState(() => _tamanho -= 2) : null,
                ),
                Text('${_tamanho.round()}'),
                IconButton(
                  tooltip: 'Letra maior',
                  icon: const Icon(Icons.text_increase),
                  onPressed: () => setState(() => _tamanho += 2),
                ),
                FilterChip(
                  label: const Text('Cabeçalho'),
                  selected: _cabecalho,
                  onSelected: (v) => setState(() => _cabecalho = v),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Scrollbar(
                child: SingleChildScrollView(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Table(
                      defaultColumnWidth: const FixedColumnWidth(150),
                      border: TableBorder.all(color: _grade),
                      children: [
                        for (var l = 0; l < _linhas; l++)
                          TableRow(
                            children: [
                              for (var c = 0; c < _colunas; c++) _campo(l, c, cores),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                '$_linhas × $_colunas · Shift+clique marca várias células · **negrito**, *itálico* no texto',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(context, _resultado()), child: const Text('Salvar')),
      ],
    );
  }

  Widget _campo(int l, int c, ColorScheme cores) {
    final cel = _celulas[l][c];
    final cabecalho = _cabecalho && l == 0;
    final marcada = _marcada(l, c);
    return Container(
      decoration: BoxDecoration(
        color: cel.fundo ?? (cabecalho ? fundoCabecalho : Colors.white),
        border: marcada ? Border.all(color: cores.primary, width: 2) : null,
      ),
      child: TextField(
        controller: _textos[l][c],
        maxLines: null,
        textAlign: const [TextAlign.left, TextAlign.center, TextAlign.right][cel.alinhamento.clamp(0, 2)],
        onTap: () => _marcar(l, c),
        style: TextStyle(
          color: cel.corTexto ?? Colors.black,
          fontWeight: cel.negrito || cabecalho ? FontWeight.bold : null,
        ),
        decoration: const InputDecoration(
          border: InputBorder.none,
          isDense: true,
          contentPadding: EdgeInsets.all(8),
        ),
      ),
    );
  }
}
