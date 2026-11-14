import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_arquivos.dart';
import '../leitor/dados_tela.dart';
import '../modelos.dart';
import '../telas/acoes_destaque.dart';
import 'exportar.dart';
import 'pptx.dart';

const _coresTexto = ['000000', 'FFFFFF', '1F3864', '2E75B6', 'C00000', 'FF6600', '00B050', '7030A0', '7F7F7F'];

/// Editor de PPTX no estilo PowerPoint: miniaturas (duplicar, novo, mover, excluir), slide com as
/// caixas no lugar (arrastar move, canto redimensiona, toque duplo edita o texto) e barra de estilo.
class ApresentacaoTela extends StatefulWidget {
  const ApresentacaoTela({super.key, required this.api, required this.arquivo});

  final ApiArquivos api;
  final Arquivo arquivo;

  @override
  State<ApresentacaoTela> createState() => _ApresentacaoTelaState();
}

class _ApresentacaoTelaState extends State<ApresentacaoTela> {
  late final Future<void> _carga = _ler();
  Apresentacao? _ap;
  int _atual = 0;
  Forma? _sel;
  bool _editando = false;
  bool _salvando = false;
  final _texto = TextEditingController();

  bool get _sujo => (_ap?.alterada ?? false) || _editando;
  Slide get _slide => _ap!.slides[_atual];

  @override
  void dispose() {
    _texto.dispose();
    super.dispose();
  }

  Future<void> _ler() async {
    final id = widget.arquivo.id;
    final bytes = await widget.api.offline.original(id) ?? await widget.api.original(id);
    _ap = Apresentacao.ler(bytes);
    if (_ap!.slides.isEmpty) throw PptxInvalido('A apresentação não tem slides.');
  }

  void _concluirTexto() {
    if (_editando && _sel != null && _sel!.texto != _texto.text) _sel!.texto = _texto.text;
    _editando = false;
  }

  void _selecionar(Forma? f, {bool editar = false}) {
    setState(() {
      _concluirTexto();
      _sel = f;
      if (editar && f != null && f.temTexto) {
        _texto.text = f.texto;
        _editando = true;
      }
    });
  }

  void _irPara(int i) => setState(() {
    _concluirTexto();
    _sel = null;
    _atual = i.clamp(0, _ap!.slides.length - 1);
  });

  void _slideAcao(String acao, int i) {
    setState(() {
      _concluirTexto();
      _sel = null;
      final ap = _ap!;
      switch (acao) {
        case 'duplicar':
          ap.duplicar(i);
          _atual = i + 1;
        case 'novo':
          ap.duplicar(i, vazio: true);
          _atual = i + 1;
        case 'acima':
          ap.mover(i, i - 1);
          _atual = (i - 1).clamp(0, ap.slides.length - 1);
        case 'abaixo':
          ap.mover(i, i + 1);
          _atual = (i + 1).clamp(0, ap.slides.length - 1);
        case 'excluir':
          ap.excluir(i);
          _atual = _atual.clamp(0, ap.slides.length - 1);
      }
    });
  }

  Future<bool> _salvar() async {
    setState(_concluirTexto);
    setState(() => _salvando = true);
    try {
      final novo = await widget.api.offline.salvarOriginal(widget.arquivo, _ap!.gravar());
      if (mounted) avisar(context, novo == null ? 'Sem conexão: salvo no aparelho; sobe quando a conexão voltar.' : 'Salvo.');
      return true;
    } on ApiErro catch (e) {
      if (mounted) avisar(context, 'Não consegui salvar: ${e.mensagem}');
      return false;
    } finally {
      if (mounted) setState(() => _salvando = false);
    }
  }

  Future<void> _exportar() async {
    if (_sujo && !await _salvar()) return;
    final ap = _ap!;
    final md = [
      for (final (i, s) in ap.slides.indexed) ...[
        '## Slide ${i + 1}',
        for (final f in s.formas)
          if (f.temTexto && f.texto.trim().isNotEmpty) f.titulo ? '**${f.texto.trim()}**' : f.texto.trim(),
        '',
      ],
    ].join('\n\n');
    if (mounted) await exportarArquivo(context, widget.api, widget.arquivo, markdown: md);
  }

  @override
  Widget build(BuildContext context) => GuardaSaida(
    sujo: _sujo,
    child: CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
          if (_sujo && !_salvando) _salvar();
        },
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.arquivo.titulo, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(tooltip: 'Exportar', onPressed: _ap == null ? null : _exportar, icon: const Icon(Icons.ios_share)),
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
              final msg = e is ApiErro ? e.mensagem : (e is PptxInvalido ? e.mensagem : '$e');
              return Center(child: Text('Não consegui abrir: $msg'));
            }
            if (s.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
            return LayoutBuilder(
              builder: (context, c) {
                final largo = c.maxWidth >= 720;
                final palco = Column(
                  children: [
                    _barra(),
                    const Divider(height: 1),
                    Expanded(child: _palco()),
                  ],
                );
                if (largo) {
                  return Row(
                    children: [
                      SizedBox(width: 190, child: _miniaturas(Axis.vertical)),
                      const VerticalDivider(width: 1),
                      Expanded(child: palco),
                    ],
                  );
                }
                return Column(
                  children: [
                    Expanded(child: palco),
                    const Divider(height: 1),
                    SizedBox(height: 96, child: _miniaturas(Axis.horizontal)),
                  ],
                );
              },
            );
          },
        ),
      ),
    ),
  );

  Widget _miniaturas(Axis eixo) {
    final ap = _ap!;
    final proporcao = ap.largura / ap.altura;
    return ListView.builder(
      scrollDirection: eixo,
      padding: const EdgeInsets.all(8),
      itemCount: ap.slides.length,
      itemBuilder: (context, i) {
        final atual = i == _atual;
        return Padding(
          padding: const EdgeInsets.all(4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(width: 18, child: Text('${i + 1}', style: Theme.of(context).textTheme.labelSmall)),
              SizedBox(
                width: eixo == Axis.vertical ? 140 : 80 * proporcao,
                child: AspectRatio(
                  aspectRatio: proporcao,
                  child: GestureDetector(
                    onTap: () => _irPara(i),
                    onSecondaryTapUp: (d) => _menuSlide(context, i, d.globalPosition),
                    onLongPressStart: (d) => _menuSlide(context, i, d.globalPosition),
                    child: DecoratedBox(
                      position: DecorationPosition.foreground,
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: atual ? Theme.of(context).colorScheme.primary : Colors.black26,
                          width: atual ? 2 : 1,
                        ),
                      ),
                      child: IgnorePointer(child: _SlideVista(ap: ap, slide: ap.slides[i])),
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

  Future<void> _menuSlide(BuildContext context, int i, Offset pos) async {
    final acao = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: [
        const PopupMenuItem(value: 'novo', child: Text('Novo slide depois')),
        const PopupMenuItem(value: 'duplicar', child: Text('Duplicar')),
        if (i > 0) const PopupMenuItem(value: 'acima', child: Text('Mover para cima')),
        if (i < _ap!.slides.length - 1) const PopupMenuItem(value: 'abaixo', child: Text('Mover para baixo')),
        if (_ap!.slides.length > 1) const PopupMenuItem(value: 'excluir', child: Text('Excluir slide')),
      ],
    );
    if (acao != null) _slideAcao(acao, i);
  }

  Widget _barra() {
    final f = _sel;
    final texto = f != null && f.temTexto;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: () => setState(() {
              _concluirTexto();
              _sel = _slide.novaCaixa();
            }),
            icon: const Icon(Icons.text_fields),
            label: const Text('Caixa de texto'),
          ),
          TextButton.icon(
            onPressed: () => _slideAcao('novo', _atual),
            icon: const Icon(Icons.add_box_outlined),
            label: const Text('Novo slide'),
          ),
          TextButton.icon(
            onPressed: () => _slideAcao('duplicar', _atual),
            icon: const Icon(Icons.copy_all_outlined),
            label: const Text('Duplicar'),
          ),
          const SizedBox(height: 32, child: VerticalDivider()),
          if (texto) ...[
            IconButton(
              tooltip: 'Diminuir fonte',
              onPressed: () => setState(() => f.estilo(tamanho: (f.tamanho - 2).clamp(6, 200))),
              icon: const Icon(Icons.text_decrease),
            ),
            SizedBox(width: 36, child: Text('${f.tamanho.round()}', textAlign: TextAlign.center)),
            IconButton(
              tooltip: 'Aumentar fonte',
              onPressed: () => setState(() => f.estilo(tamanho: (f.tamanho + 2).clamp(6, 200))),
              icon: const Icon(Icons.text_increase),
            ),
            IconButton(
              tooltip: 'Negrito',
              isSelected: f.negrito,
              onPressed: () => setState(() => f.estilo(negrito: !f.negrito)),
              icon: const Icon(Icons.format_bold),
            ),
            IconButton(
              tooltip: 'Itálico',
              isSelected: f.italico,
              onPressed: () => setState(() => f.estilo(italico: !f.italico)),
              icon: const Icon(Icons.format_italic),
            ),
            IconButton(
              tooltip: 'Sublinhado',
              isSelected: f.sublinhado,
              onPressed: () => setState(() => f.estilo(sublinhado: !f.sublinhado)),
              icon: const Icon(Icons.format_underline),
            ),
            for (final (algn, icone) in [
              ('l', Icons.format_align_left),
              ('ctr', Icons.format_align_center),
              ('r', Icons.format_align_right),
              ('just', Icons.format_align_justify),
            ])
              IconButton(
                isSelected: f.alinhamento == algn,
                onPressed: () => setState(() => f.estilo(alinhamento: algn)),
                icon: Icon(icone),
              ),
            PopupMenuButton<String>(
              tooltip: 'Cor do texto',
              icon: Icon(Icons.format_color_text, color: _cor(f.cor)),
              onSelected: (c) => setState(() => f.estilo(cor: c)),
              itemBuilder: (_) => [
                for (final c in _coresTexto)
                  PopupMenuItem(
                    value: c,
                    child: Row(
                      children: [
                        Container(width: 18, height: 18, color: _cor(c), margin: const EdgeInsets.only(right: 8)),
                        Text('#$c'),
                      ],
                    ),
                  ),
              ],
            ),
            IconButton(
              tooltip: _editando ? 'Concluir texto' : 'Editar texto',
              onPressed: () => _editando ? setState(_concluirTexto) : _selecionar(f, editar: true),
              icon: Icon(_editando ? Icons.check : Icons.edit_outlined),
            ),
          ],
          if (f != null)
            IconButton(
              tooltip: 'Excluir forma',
              onPressed: () => setState(() {
                _editando = false;
                _slide.excluir(f);
                _sel = null;
              }),
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
    );
  }

  Widget _palco() {
    final ap = _ap!;
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      child: GestureDetector(
        onTap: () => _selecionar(null),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: AspectRatio(
              aspectRatio: ap.largura / ap.altura,
              child: Material(
                elevation: 3,
                child: _SlideVista(
                  ap: ap,
                  slide: _slide,
                  selecionada: _sel,
                  editor: _editando ? _texto : null,
                  aoTocar: (f) => _selecionar(f),
                  aoTocarDuplo: (f) => _selecionar(f, editar: true),
                  aoMudar: () => setState(() {}),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Color _cor(String? hex) => hex == null ? Colors.black : Color(int.parse('FF$hex', radix: 16));

/// Desenho de um slide no tamanho disponível; interativo quando recebe [aoTocar].
class _SlideVista extends StatelessWidget {
  const _SlideVista({
    required this.ap,
    required this.slide,
    this.selecionada,
    this.editor,
    this.aoTocar,
    this.aoTocarDuplo,
    this.aoMudar,
  });

  final Apresentacao ap;
  final Slide slide;
  final Forma? selecionada;
  final TextEditingController? editor;
  final void Function(Forma)? aoTocar;
  final void Function(Forma)? aoTocarDuplo;
  final VoidCallback? aoMudar;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final k = c.maxWidth / ap.largura;
      final fundo = slide.fundo;
      return ClipRect(
        child: ColoredBox(
          color: fundo == null ? Colors.white : _cor(fundo),
          child: Stack(
            children: [
              for (final f in slide.formas)
                Positioned(
                  left: f.x * k,
                  top: f.y * k,
                  width: f.w * k,
                  height: f.h * k,
                  child: _forma(context, f, k),
                ),
            ],
          ),
        ),
      );
    },
  );

  TextStyle _estilo(Forma f, double k) => TextStyle(
    fontSize: (f.tamanho * emuPorPonto * k).clamp(1, 400),
    fontWeight: f.negrito ? FontWeight.bold : FontWeight.normal,
    fontStyle: f.italico ? FontStyle.italic : FontStyle.normal,
    decoration: f.sublinhado ? TextDecoration.underline : null,
    color: _cor(f.cor),
    height: 1.15,
  );

  TextAlign _alinhar(Forma f) => switch (f.alinhamento) {
    'ctr' => TextAlign.center,
    'r' => TextAlign.right,
    'just' => TextAlign.justify,
    _ => TextAlign.left,
  };

  Widget _forma(BuildContext context, Forma f, double k) {
    final imagem = f.imagem == null ? null : ap.bytes(f.imagem!);
    final Widget conteudo;
    if (imagem != null) {
      conteudo = Image.memory(imagem, fit: BoxFit.fill, errorBuilder: (_, _, _) => const Placeholder());
    } else if (f.outro != null) {
      conteudo = Container(
        color: Colors.black12,
        alignment: Alignment.center,
        child: Text(f.outro!, style: TextStyle(fontSize: (12 * emuPorPonto * k).clamp(6, 24), color: Colors.black54)),
      );
    } else if (editor != null && identical(f, selecionada)) {
      conteudo = Material(
        color: Colors.white.withValues(alpha: 0.9),
        child: TextField(
          controller: editor,
          autofocus: true,
          maxLines: null,
          expands: true,
          textAlign: _alinhar(f),
          style: _estilo(f, k),
          decoration: const InputDecoration(border: InputBorder.none, isCollapsed: true),
        ),
      );
    } else {
      final t = f.texto;
      conteudo = Align(
        alignment: f.titulo ? Alignment.center : Alignment.topLeft,
        child: Text(
          t.isEmpty && f.placeholder && aoTocar != null ? (f.titulo ? 'Clique duas vezes para o título' : 'Clique duas vezes para o texto') : t,
          textAlign: _alinhar(f),
          overflow: TextOverflow.clip,
          style: t.isEmpty ? _estilo(f, k).copyWith(color: Colors.black38) : _estilo(f, k),
        ),
      );
    }
    if (aoTocar == null) return conteudo;
    final sel = identical(f, selecionada);
    return GestureDetector(
      onTap: () => aoTocar!(f),
      onDoubleTap: () => aoTocarDuplo?.call(f),
      onPanUpdate: sel && editor == null
          ? (d) {
              f.posicionar(f.x + d.delta.dx / k, f.y + d.delta.dy / k, f.w, f.h);
              aoMudar?.call();
            }
          : null,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: conteudo),
          if (sel)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(decoration: BoxDecoration(border: Border.all(color: Colors.blue, width: 1.5))),
              ),
            ),
          if (sel && editor == null)
            Positioned(
              right: -6,
              bottom: -6,
              child: GestureDetector(
                onPanUpdate: (d) {
                  f.posicionar(f.x, f.y, f.w + d.delta.dx / k, f.h + d.delta.dy / k);
                  aoMudar?.call();
                },
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Colors.blue, width: 2)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
