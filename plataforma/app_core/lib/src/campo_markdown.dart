import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'markdown.dart';

/// Campo Markdown completo: barra de formatação (desfazer, pincel, borracha, títulos, negrito…
/// cores, alinhamento, tela cheia), editor com live preview e modo leitura renderizado.
/// [extras] entram no fim da barra (ex.: link e relação nas notas).
class CampoMarkdown extends StatefulWidget {
  const CampoMarkdown({
    super.key,
    required this.controle,
    this.aoMudar,
    this.extras = const [],
    this.dica = 'Escreva…',
    this.minLinhas = 12,
    this.telaCheia = false,
    this.lendo = false,
  });

  final ControladorMarkdown controle;
  final VoidCallback? aoMudar;
  final List<Widget> extras;
  final String dica;
  final int minLinhas;

  /// Ocupa todo o espaço do pai (rota de tela cheia); o botão de sair fecha a rota.
  final bool telaCheia;

  /// Abre no modo leitura.
  final bool lendo;

  @override
  State<CampoMarkdown> createState() => _CampoMarkdownState();
}

class _CampoMarkdownState extends State<CampoMarkdown> {
  final _desfazer = UndoHistoryController();
  final _foco = FocusNode();
  late bool _lendo = widget.lendo;
  List<(String, String)>? _pincel;
  String _cor = coresTexto['Vermelho']!, _marcador = coresMarcador['Amarelo']!;

  ControladorMarkdown get _c => widget.controle;

  @override
  void dispose() {
    _desfazer.dispose();
    _foco.dispose();
    super.dispose();
  }

  /// Executa uma edição com o foco no campo (o histórico de desfazer só grava com foco).
  Future<void> _faz(void Function() acao) async {
    if (_lendo) setState(() => _lendo = false);
    if (!_foco.hasFocus) {
      _foco.requestFocus();
      await Future<void>.delayed(Duration.zero);
    }
    acao();
    widget.aoMudar?.call();
  }

  void _usarPincel() {
    if (_pincel == null) {
      final f = _c.formatosDaSelecao();
      setState(() => _pincel = f);
      if (f.isEmpty) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('Selecione um texto formatado para copiar o estilo.')),
        );
        setState(() => _pincel = null);
      }
      return;
    }
    final f = _pincel!;
    setState(() => _pincel = null);
    _faz(() => _c.aplicarFormatos(f));
  }

  Future<void> _anexar() async {
    final campo = TextEditingController();
    final valor = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Anexar'),
        content: TextField(
          controller: campo,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Link (https://…) ou nome do arquivo no cofre'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, campo.text), child: const Text('Inserir')),
        ],
      ),
    );
    campo.dispose();
    final v = valor?.trim() ?? '';
    if (v.isEmpty) return;
    final imagem = RegExp(r'\.(png|jpe?g|gif|webp|svg|bmp)(\?.*)?$', caseSensitive: false).hasMatch(v);
    final md = v.startsWith('http')
        ? (imagem ? '![](${v.replaceAll(' ', '%20')})' : '[$v]($v)')
        : (imagem ? '![[$v]]' : '[[$v]]');
    _faz(() => _c.inserir(md));
  }

  Future<void> _abrirTelaCheia() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: CampoMarkdown(
              controle: _c,
              aoMudar: widget.aoMudar,
              extras: widget.extras,
              dica: widget.dica,
              telaCheia: true,
              lendo: _lendo,
            ),
          ),
        ),
      ),
    ));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final estilo = tema.textTheme.bodyLarge?.copyWith(height: 1.6);
    final borda = BoxDecoration(
      border: Border.all(color: tema.colorScheme.outlineVariant),
      borderRadius: BorderRadius.circular(10),
    );
    final Widget corpo = _lendo
        ? Container(
            width: double.infinity,
            constraints: BoxConstraints(minHeight: widget.telaCheia ? 0 : widget.minLinhas * 18.0),
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
            decoration: borda,
            child: GestureDetector(
              onDoubleTap: () => setState(() => _lendo = false),
              child: VisualizadorMarkdown(
                texto: _c.text,
                estilo: estilo,
                aoAlternarTarefa: (i) {
                  setState(() => _c.alternarTarefa(i));
                  widget.aoMudar?.call();
                },
              ),
            ),
          )
        : CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.keyB, control: true): () => _faz(() => _c.envolver('**')),
              const SingleActivator(LogicalKeyboardKey.keyI, control: true): () => _faz(() => _c.envolver('*')),
              const SingleActivator(LogicalKeyboardKey.keyU, control: true): () => _faz(() => _c.envolver('<u>', '</u>')),
              const SingleActivator(LogicalKeyboardKey.tab): () => _faz(() => _c.recuar()),
              const SingleActivator(LogicalKeyboardKey.tab, shift: true): () => _faz(() => _c.recuar(mais: false)),
            },
            child: TextField(
              controller: _c,
              focusNode: _foco,
              undoController: _desfazer,
              maxLines: null,
              minLines: widget.telaCheia ? null : widget.minLinhas,
              expands: widget.telaCheia,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              style: estilo,
              decoration: InputDecoration(
                hintText: widget.dica,
                contentPadding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onChanged: (_) => widget.aoMudar?.call(),
            ),
          );
    final barra = _barra(tema);
    if (!widget.telaCheia) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [barra, const SizedBox(height: 8), corpo],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        barra,
        const SizedBox(height: 8),
        Expanded(child: _lendo ? SingleChildScrollView(child: corpo) : corpo),
      ],
    );
  }

  // ---------- barra ----------

  Widget _barra(ThemeData tema) {
    final cs = tema.colorScheme;
    Widget botao(Widget icone, String dica, VoidCallback? acao, {bool ativo = false}) => IconButton(
      tooltip: dica,
      visualDensity: VisualDensity.compact,
      iconSize: 19,
      isSelected: ativo,
      style: IconButton.styleFrom(
        foregroundColor: cs.onSurfaceVariant,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      icon: icone,
      onPressed: acao,
    );
    Widget icone(IconData i) => Icon(i);
    Widget texto(String t) => Text(t, style: tema.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700, color: cs.onSurfaceVariant));
    Widget menu<T>(Widget icone, String dica, List<PopupMenuEntry<T>> itens, void Function(T) escolher) => PopupMenuButton<T>(
      tooltip: dica,
      onSelected: escolher,
      itemBuilder: (_) => itens,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: IconTheme.merge(
          data: IconThemeData(size: 19, color: cs.onSurfaceVariant),
          child: Row(mainAxisSize: MainAxisSize.min, children: [icone, Icon(Icons.arrow_drop_down, size: 14, color: cs.outline)]),
        ),
      ),
    );
    PopupMenuItem<T> item<T>(T valor, IconData? i, String nome, {Color? cor}) => PopupMenuItem(
      value: valor,
      child: Row(spacing: 10, children: [if (i != null) Icon(i, size: 18, color: cor), Text(nome)]),
    );
    Widget separador() => SizedBox(height: 22, child: VerticalDivider(width: 10, color: cs.outlineVariant));
    final titulo = RegExp(r'^#{1,6}\s+');
    void cabecalho(int n) => _faz(() => _c.prefixarLinhas((_) => n == 0 ? '' : '${'#' * n} ', n == 0 ? titulo : RegExp('^${'#' * n}\\s+')));

    // botão de cor (aplica a última usada) com seta para escolher outra; a barrinha mostra a cor atual
    Widget comCor(IconData i, String dica, String atual, Map<String, String> cores, void Function(String) escolher) =>
        Row(mainAxisSize: MainAxisSize.min, children: [
          botao(
            Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(i, size: 17),
              Container(width: 16, height: 3, margin: const EdgeInsets.only(top: 1), color: corCss(atual)),
            ]),
            dica,
            () => escolher(atual),
          ),
          menu<String>(const SizedBox.shrink(), dica, [
            for (final e in cores.entries) item(e.value, Icons.circle, e.key, cor: corCss(e.value)),
          ], escolher),
        ]);

    final itens = <Widget>[
      ValueListenableBuilder(
        valueListenable: _desfazer,
        builder: (_, v, _) => Row(mainAxisSize: MainAxisSize.min, children: [
          botao(icone(Icons.undo), 'Desfazer (Ctrl+Z)', v.canUndo ? _desfazer.undo : null),
          botao(icone(Icons.redo), 'Refazer (Ctrl+Shift+Z)', v.canRedo ? _desfazer.redo : null),
        ]),
      ),
      botao(
        icone(Icons.format_paint_outlined),
        _pincel == null ? 'Pincel: copiar a formatação da seleção' : 'Pincel: selecione o destino e clique de novo',
        _usarPincel,
        ativo: _pincel != null,
      ),
      botao(icone(Icons.format_clear), 'Limpar formatação', () => _faz(_c.limparFormatacao)),
      separador(),
      botao(texto('H2'), 'Título 2', () => cabecalho(2)),
      botao(texto('H3'), 'Título 3', () => cabecalho(3)),
      menu<int>(texto('Hn'), 'Títulos', [
        for (final n in [1, 2, 3, 4, 5, 6]) item(n, null, 'Título $n'),
        const PopupMenuDivider(),
        item(0, Icons.notes, 'Texto normal'),
      ], cabecalho),
      separador(),
      botao(icone(Icons.format_bold), 'Negrito (Ctrl+B)', () => _faz(() => _c.envolver('**'))),
      botao(icone(Icons.format_italic), 'Itálico (Ctrl+I)', () => _faz(() => _c.envolver('*'))),
      botao(icone(Icons.format_strikethrough), 'Tachado', () => _faz(() => _c.envolver('~~'))),
      botao(icone(Icons.format_underlined), 'Sublinhado (Ctrl+U)', () => _faz(() => _c.envolver('<u>', '</u>'))),
      botao(icone(Icons.edit_note), 'Marca-texto', () => _faz(() => _c.envolver('=='))),
      separador(),
      menu<String>(icone(Icons.view_in_ar_outlined), 'Inserir', [
        item('cod', Icons.code, 'Código na linha'),
        item('bloco', Icons.data_object, 'Bloco de código'),
        item('mermaid', Icons.account_tree_outlined, 'Fluxograma (Mermaid)'),
        item('link', Icons.link, 'Link'),
        item('regua', Icons.horizontal_rule, 'Linha divisória'),
      ], (v) => _faz(() {
        switch (v) {
          case 'cod':
            _c.envolver('`');
          case 'bloco':
            _c.inserirBloco('```\n\n```', cursor: 4);
          case 'mermaid':
            _c.inserirBloco('```mermaid\nflowchart TD\n    A[Início] --> B{Decisão}\n    B -->|Sim| C[Fazer]\n    B -->|Não| D[Fim]\n```');
          case 'link':
            _c.envolver('[', '](https://)');
          default:
            _c.inserirBloco('---\n');
        }
      })),
      menu<bool>(icone(_lendo ? Icons.visibility_outlined : Icons.edit_outlined), 'Modo', [
        item(false, Icons.edit_outlined, 'Editar'),
        item(true, Icons.visibility_outlined, 'Visualizar'),
      ], (v) => setState(() => _lendo = v)),
      botao(icone(Icons.attach_file), 'Anexar link ou imagem', _anexar),
      menu<int>(icone(Icons.table_chart_outlined), 'Tabela', [
        for (final (l, c) in const [(2, 2), (3, 3), (4, 3), (5, 4)]) item(l * 10 + c, Icons.grid_on, '$l linhas × $c colunas'),
      ], (v) {
        final linhas = v ~/ 10, colunas = v % 10;
        final cab = '|${[for (var i = 1; i <= colunas; i++) ' Coluna $i |'].join()}';
        final sep = '|${' --- |' * colunas}';
        final vazia = '|${'  |' * colunas}';
        _faz(() => _c.inserirBloco('$cab\n$sep\n${List.filled(linhas - 1, vazia).join('\n')}\n', cursor: 2));
      }),
      botao(icone(Icons.check_circle_outline), 'Checklist', () => _faz(() => _c.prefixarLinhas((_) => '- [ ] ', RegExp(r'^\s*[-*+]\s\[[ xX]\]\s')))),
      menu<String>(icone(Icons.chat_bubble_outline), 'Citação e comentário', [
        item('cit', Icons.format_quote, 'Citação'),
        item('note', Icons.info_outline, 'Destaque: nota', cor: const Color(0xff1c7ed6)),
        item('tip', Icons.lightbulb_outline, 'Destaque: dica', cor: const Color(0xff2f9e44)),
        item('warning', Icons.warning_amber_rounded, 'Destaque: aviso', cor: const Color(0xfff08c00)),
        item('com', Icons.visibility_off_outlined, 'Comentário oculto'),
      ], (v) => _faz(() {
        switch (v) {
          case 'cit':
            _c.prefixarLinhas((_) => '> ', RegExp(r'^\s*>\s?'));
          case 'com':
            _c.envolver('%%');
          default:
            _c.inserirBloco('> [!$v]\n> ', cursor: 7 + v.length);
        }
      })),
      menu<String>(icone(Icons.format_size), 'Tamanho do texto', [
        for (final e in tamanhosTexto.entries) item(e.value, null, e.key),
      ], (t) => _faz(() => _c.envolver('<span style="font-size:$t">', '</span>'))),
      menu<String>(icone(Icons.format_list_bulleted), 'Listas', [
        item('pontos', Icons.format_list_bulleted, 'Lista com pontos'),
        item('num', Icons.format_list_numbered, 'Lista numerada'),
        item('tarefas', Icons.checklist, 'Lista de tarefas'),
        const PopupMenuDivider(),
        item('mais', Icons.format_indent_increase, 'Aumentar recuo (Tab)'),
        item('menos', Icons.format_indent_decrease, 'Diminuir recuo (Shift+Tab)'),
      ], (v) => _faz(() {
        switch (v) {
          case 'pontos':
            _c.prefixarLinhas((_) => '- ', RegExp(r'^\s*[-*+]\s(?!\[)'));
          case 'num':
            _c.prefixarLinhas((i) => '${i + 1}. ', RegExp(r'^\s*\d+[.)]\s'));
          case 'tarefas':
            _c.prefixarLinhas((_) => '- [ ] ', RegExp(r'^\s*[-*+]\s\[[ xX]\]\s'));
          default:
            _c.recuar(mais: v == 'mais');
        }
      })),
      menu<String>(icone(Icons.format_align_center), 'Alinhamento', [
        item('left', Icons.format_align_left, 'Esquerda'),
        item('center', Icons.format_align_center, 'Centro'),
        item('right', Icons.format_align_right, 'Direita'),
        item('justify', Icons.format_align_justify, 'Justificado'),
      ], (v) => _faz(() => _c.alinhar(v))),
      separador(),
      comCor(Icons.format_color_text, 'Cor do texto', _cor, coresTexto, (c) {
        setState(() => _cor = c);
        _faz(() => _c.envolver('<span style="color:$c">', '</span>'));
      }),
      comCor(Icons.border_color_outlined, 'Cor do marcador', _marcador, coresMarcador, (c) {
        setState(() => _marcador = c);
        _faz(() => c == coresMarcador['Amarelo'] ? _c.envolver('==') : _c.envolver('<mark style="background:$c">', '</mark>'));
      }),
      separador(),
      botao(icone(Icons.fullscreen), 'Tela cheia', widget.telaCheia ? null : _abrirTelaCheia),
      botao(icone(Icons.fullscreen_exit), 'Sair da tela cheia', widget.telaCheia ? () => Navigator.of(context).maybePop() : null),
      if (widget.extras.isNotEmpty) separador(),
      ...widget.extras,
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: itens),
      ),
    );
  }
}
