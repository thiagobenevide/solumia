import 'package:agent_core/agent_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../modelos.dart';
import 'editor.dart';
import 'estojo.dart';
import 'fluxo.dart';
import 'pintura.dart';

/// Formas para inserir no quadro, como a biblioteca lateral do draw.io: busca e categorias. Tocar
/// insere no centro da tela; arrastar solta onde quiser.
class PainelFormas extends StatefulWidget {
  const PainelFormas({super.key, required this.inserir, required this.ferramenta, this.aoArrastar});

  final ValueChanged<TipoNo> inserir;
  final ValueChanged<Ferramenta> ferramenta;

  /// Chamado quando uma forma começa a ser arrastada.
  final VoidCallback? aoArrastar;

  @override
  State<PainelFormas> createState() => _PainelFormasState();
}

class _PainelFormasState extends State<PainelFormas> {
  String _busca = '';

  static const _fluxograma = [
    TipoNo.inicio,
    TipoNo.processo,
    TipoNo.decisao,
    TipoNo.dado,
    TipoNo.subprocesso,
    TipoNo.documento,
    TipoNo.banco,
    TipoNo.quadrado,
    TipoNo.circulo,
    TipoNo.hexagono,
    TipoNo.nota,
    TipoNo.container,
  ];
  static const _geral = [Ferramenta.texto, Ferramenta.retangulo, Ferramenta.elipse, Ferramenta.seta, Ferramenta.reta];

  bool _bate(String nome) => _busca.isEmpty || nome.toLowerCase().contains(_busca.toLowerCase());

  @override
  Widget build(BuildContext context) {
    final fluxo = [
      for (final t in _fluxograma)
        if (_bate(t.rotulo)) t,
    ];
    final geral = [
      for (final f in _geral)
        if (_bate(f.rotulo)) f,
    ];
    return ListView(
      padding: const EdgeInsets.all(10),
      children: [
        TextField(
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.search, size: 20),
            hintText: 'Procurar formas',
          ),
          onChanged: (v) => setState(() => _busca = v),
        ),
        if (fluxo.isNotEmpty) ...[
          const _Titulo('Fluxograma'),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in fluxo)
                _FormaArrastavel(tipo: t, aoTocar: () => widget.inserir(t), aoArrastar: widget.aoArrastar),
            ],
          ),
        ],
        if (geral.isNotEmpty) ...[
          const _Titulo('Geral (desenhar)'),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final f in geral)
                Tooltip(
                  message: f.rotulo,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(56, 48), padding: EdgeInsets.zero),
                    onPressed: () => widget.ferramenta(f),
                    child: Icon(f.icone),
                  ),
                ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        Text(
          'Toque para inserir no centro ou arraste para o quadro. Selecione um bloco e puxe as alças ⊕ para ligar.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _Titulo extends StatelessWidget {
  const _Titulo(this.texto);

  final String texto;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 8),
    child: Text(texto, style: Theme.of(context).textTheme.titleSmall),
  );
}

/// Miniatura de um tipo de bloco (o mesmo desenho do quadro, em escala).
class MiniaturaBloco extends StatelessWidget {
  const MiniaturaBloco(this.tipo, {super.key, this.tamanho = const Size(56, 40)});

  final TipoNo tipo;
  final Size tamanho;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: tamanho, painter: _PintorMiniatura(tipo, Theme.of(context).brightness == Brightness.dark));
}

class _PintorMiniatura extends CustomPainter {
  _PintorMiniatura(this.tipo, this.escuro);

  final TipoNo tipo;
  final bool escuro;

  @override
  void paint(Canvas canvas, Size size) {
    final quadrado = tipo == TipoNo.circulo || tipo == TipoNo.banco;
    final w = quadrado ? size.height : size.width;
    final no = NoFluxo(
      '_',
      tipo: tipo,
      texto: '',
      a: Offset((size.width - w) / 2 + 2, 2),
      b: Offset((size.width + w) / 2 - 2, size.height - 2),
      cor: coresDoFluxo[tipo]!,
    );
    pintarElemento(canvas, no, escuro: escuro);
  }

  @override
  bool shouldRepaint(_PintorMiniatura old) => old.tipo != tipo || old.escuro != escuro;
}

class _FormaArrastavel extends StatelessWidget {
  const _FormaArrastavel({required this.tipo, required this.aoTocar, this.aoArrastar});

  final TipoNo tipo;
  final VoidCallback aoTocar;
  final VoidCallback? aoArrastar;

  @override
  Widget build(BuildContext context) {
    final cartao = Tooltip(
      message: tipo.rotulo,
      child: InkWell(
        onTap: aoTocar,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: 64,
          height: 52,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          ),
          child: MiniaturaBloco(tipo),
        ),
      ),
    );
    return Draggable<TipoNo>(
      data: tipo,
      onDragStarted: aoArrastar,
      feedback: Material(
        color: Colors.transparent,
        child: Opacity(opacity: 0.8, child: MiniaturaBloco(tipo, tamanho: const Size(110, 70))),
      ),
      child: cartao,
    );
  }
}

/// Estilo da seleção, como a aba "Estilo" do draw.io: forma do bloco, cores de borda, fundo e texto,
/// alinhamento, rótulo e traço da seta. Sem seleção: o "Diagrama" (fundo e exportação).
class PainelEstilo extends StatelessWidget {
  const PainelEstilo({
    super.key,
    required this.selecionados,
    required this.aplicar,
    required this.editarTexto,
    this.formatar,
    required this.recentes,
    required this.fundo,
    required this.mudarFundo,
    required this.exportar,
  });

  final List<Elemento> selecionados;
  final void Function(Map<String, Elemento>) aplicar;
  final VoidCallback editarTexto;

  /// Com texto sendo digitado no quadro: envolve o trecho selecionado na marca (`**`, `*`, `__`, `==`).
  final ValueChanged<String>? formatar;
  final List<Color> recentes;
  final Fundo fundo;
  final ValueChanged<Fundo> mudarFundo;
  final List<(String, IconData, VoidCallback)> exportar;

  /// Botões de formatação do texto em digitação. Ficam na região do campo, senão o toque aqui
  /// contaria como "fora" e encerraria a digitação.
  Widget _formatacao(BuildContext context) => TextFieldTapRegion(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Titulo('Texto'),
        Wrap(
          children: [
            IconButton(tooltip: 'Negrito', onPressed: () => formatar!('**'), icon: const Icon(Icons.format_bold)),
            IconButton(tooltip: 'Itálico', onPressed: () => formatar!('*'), icon: const Icon(Icons.format_italic)),
            IconButton(
              tooltip: 'Sublinhado',
              onPressed: () => formatar!('__'),
              icon: const Icon(Icons.format_underlined),
            ),
            IconButton(tooltip: 'Marcador', onPressed: () => formatar!('=='), icon: const Icon(Icons.border_color)),
          ],
        ),
        Text(
          'Selecione um trecho e toque no botão. Esc ou clique fora para concluir.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final blocos = selecionados.whereType<NoFluxo>().toList();
    final setas = selecionados.whereType<Ligacao>().toList();
    final textos = selecionados.whereType<Texto>().toList();
    if (selecionados.isEmpty && formatar == null) return _diagrama(context);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (formatar != null) _formatacao(context),
        if (selecionados.isNotEmpty)
          Text(
            '${selecionados.length} selecionado${selecionados.length == 1 ? '' : 's'}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        if (formatar == null &&
            selecionados.length == 1 &&
            (blocos.isNotEmpty || setas.isNotEmpty || textos.isNotEmpty))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton.icon(
              onPressed: editarTexto,
              icon: const Icon(Icons.edit_note),
              label: const Text('Editar texto'),
            ),
          ),
        if (blocos.isNotEmpty) ...[
          const _Titulo('Forma'),
          DropdownButtonFormField<TipoNo>(
            initialValue: blocos.map((b) => b.tipo).toSet().length == 1 ? blocos.first.tipo : null,
            isExpanded: true,
            decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
            items: [
              for (final t in TipoNo.values)
                if (t != TipoNo.fim)
                  DropdownMenuItem(
                    value: t,
                    child: Row(
                      spacing: 8,
                      children: [
                        MiniaturaBloco(t, tamanho: const Size(28, 20)),
                        Expanded(child: Text(t.rotulo)),
                      ],
                    ),
                  ),
            ],
            onChanged: (t) => t == null ? null : aplicar({for (final b in blocos) b.id: b.copia(tipo: t)}),
          ),
          _Cor('Borda', blocos.first.cor, recentes, (c) => aplicar({for (final b in blocos) b.id: b.copia(cor: c)})),
          _Cor(
            'Preenchimento',
            blocos.first.fundo,
            recentes,
            (c) => aplicar({for (final b in blocos) b.id: b.copia(fundo: c)}),
            limpar: () => aplicar({for (final b in blocos) b.id: b.copia(semFundo: true)}),
          ),
          _Cor(
            'Texto',
            blocos.first.corTexto,
            recentes,
            (c) => aplicar({for (final b in blocos) b.id: b.copia(corTexto: c)}),
            limpar: () => aplicar({for (final b in blocos) b.id: b.copia(semCorTexto: true)}),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Texto à esquerda'),
            value: blocos.every((b) => b.esquerda),
            onChanged: (v) => aplicar({for (final b in blocos) b.id: b.copia(esquerda: v)}),
          ),
        ],
        if (setas.isNotEmpty) ...[
          const _Titulo('Seta'),
          _Cor('Cor', setas.first.cor, recentes, (c) => aplicar({for (final s in setas) s.id: s.copia(cor: c)})),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Em ângulo reto'),
            value: setas.every((s) => s.ortogonal),
            onChanged: (v) => aplicar({for (final s in setas) s.id: s.copia(ortogonal: v)}),
          ),
          const _Titulo('Linha'),
          SegmentedButton<TipoLinha>(
            showSelectedIcon: false,
            segments: [for (final t in TipoLinha.values) ButtonSegment(value: t, label: Text(t.rotulo))],
            selected: {if (setas.map((s) => s.linha).toSet().length == 1) setas.first.linha},
            emptySelectionAllowed: true,
            onSelectionChanged: (v) {
              if (v.isNotEmpty) aplicar({for (final s in setas) s.id: s.copia(linha: v.first)});
            },
          ),
          Row(
            children: [
              Text('Espessura ${setas.first.espessura.round()}'),
              Expanded(
                child: Slider(
                  min: 1,
                  max: 10,
                  divisions: 9,
                  value: setas.first.espessura.clamp(1, 10),
                  onChanged: (v) => aplicar({for (final s in setas) s.id: s.copia(espessura: v)}),
                ),
              ),
            ],
          ),
          _Escolha<TipoPonta>(
            'Ponta no início',
            setas.map((s) => s.pontaInicio).toSet().length == 1 ? setas.first.pontaInicio : null,
            {for (final t in TipoPonta.values) t: t.rotulo},
            (t) => aplicar({for (final s in setas) s.id: s.copia(pontaInicio: t)}),
          ),
          _Escolha<TipoPonta>(
            'Ponta no fim',
            setas.map((s) => s.pontaFim).toSet().length == 1 ? setas.first.pontaFim : null,
            {for (final t in TipoPonta.values) t: t.rotulo},
            (t) => aplicar({for (final s in setas) s.id: s.copia(pontaFim: t)}),
          ),
          _Escolha<int>(
            'Sai pelo lado',
            setas.map((s) => s.ladoDe).toSet().length == 1 ? setas.first.ladoDe ?? -1 : null,
            {-1: 'Automático', for (final (i, l) in ladosDoBloco.indexed) i: l},
            (i) => aplicar({for (final s in setas) s.id: s.copia(ladoDe: i, ladoDeAuto: i < 0)}),
          ),
          _Escolha<int>(
            'Chega pelo lado',
            setas.map((s) => s.ladoPara).toSet().length == 1 ? setas.first.ladoPara ?? -1 : null,
            {-1: 'Automático', for (final (i, l) in ladosDoBloco.indexed) i: l},
            (i) => aplicar({for (final s in setas) s.id: s.copia(ladoPara: i, ladoParaAuto: i < 0)}),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton.icon(
              onPressed: () => aplicar({for (final s in setas) s.id: s.invertida()}),
              icon: const Icon(Icons.swap_horiz),
              label: const Text('Inverter sentido'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Para ligar em outro bloco, arraste a bolinha da ponta da seta até ele: o lado mais perto de onde soltar vira o ponto de ligação.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
        if (textos.isNotEmpty) ...[
          const _Titulo('Texto'),
          _Cor(
            'Cor',
            textos.first.cor,
            recentes,
            (c) => aplicar({for (final t in textos) t.id: t.transformar((q) => q, cor: c)}),
          ),
          Row(
            children: [
              const Text('Tamanho'),
              Expanded(
                child: Slider(
                  min: 10,
                  max: 72,
                  value: textos.first.tamanho.clamp(10, 72),
                  onChanged: (v) => aplicar({
                    for (final t in textos)
                      t.id: Texto(t.id, posicao: t.posicao, texto: t.texto, cor: t.cor, tamanho: v),
                  }),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _diagrama(BuildContext context) => ListView(
    padding: const EdgeInsets.all(12),
    children: [
      Text('Diagrama', style: Theme.of(context).textTheme.titleSmall),
      const _Titulo('Fundo'),
      Wrap(
        spacing: 6,
        children: [
          for (final f in Fundo.values)
            ChoiceChip(label: Text(f.rotulo), selected: fundo == f, onSelected: (_) => mudarFundo(f)),
        ],
      ),
      const _Titulo('Exportar'),
      for (final (rotulo, icone, acao) in exportar)
        ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(icone), title: Text(rotulo), onTap: acao),
      const SizedBox(height: 8),
      Text('Selecione um elemento para mudar forma, cores e texto.', style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}

/// Rótulo + lista suspensa compacta ([atual] null = valores misturados na seleção).
class _Escolha<T> extends StatelessWidget {
  const _Escolha(this.rotulo, this.atual, this.opcoes, this.escolher);

  final String rotulo;
  final T? atual;
  final Map<T, String> opcoes;
  final ValueChanged<T> escolher;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Row(
      spacing: 8,
      children: [
        Expanded(child: Text(rotulo)),
        DropdownButton<T>(
          value: atual,
          isDense: true,
          items: [
            for (final MapEntry(:key, :value) in opcoes.entries) DropdownMenuItem(value: key, child: Text(value)),
          ],
          onChanged: (v) => v == null ? null : escolher(v),
        ),
      ],
    ),
  );
}

/// Camadas da página, de cima (na frente) para baixo: tocar seleciona (Ctrl soma), arrastar muda a ordem.
class PainelCamadas extends StatelessWidget {
  const PainelCamadas({
    super.key,
    required this.elementos,
    required this.selecionados,
    required this.selecionar,
    required this.reordenar,
    required this.moverCamada,
  });

  final List<Elemento> elementos;
  final Set<String> selecionados;
  final void Function(String id, bool somar) selecionar;

  /// Nova ordem de baixo para cima (o último fica na frente).
  final ValueChanged<List<String>> reordenar;
  final ValueChanged<int> moverCamada;

  static (IconData, String) _descrever(Elemento e) => switch (e) {
    Traco() => (Icons.gesture, 'Traço'),
    Forma(:final forma) => (
      Icons.crop_square,
      switch (forma) {
        TipoForma.reta => 'Reta',
        TipoForma.seta => 'Seta solta',
        TipoForma.retangulo => 'Retângulo',
        TipoForma.elipse => 'Elipse',
      },
    ),
    Texto(:final texto) => (Icons.title, texto),
    NoFluxo(:final tipo, :final texto) => (Icons.widgets_outlined, texto.isEmpty ? tipo.rotulo : texto),
    Ligacao(:final rotulo) => (Icons.trending_flat, rotulo.isEmpty ? 'Seta' : 'Seta: $rotulo'),
    Tabela(:final linhas, :final colunas) => (Icons.table_chart_outlined, 'Tabela $linhas × $colunas'),
    Imagem(:final titulo) => (Icons.image_outlined, titulo.isEmpty ? 'Imagem' : titulo),
  };

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    final lista = elementos.reversed.toList();
    final temSelecao = selecionados.isNotEmpty;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final (passo, icone, dica) in [
                (2, Icons.flip_to_front, 'Trazer para a frente (Ctrl+Shift+])'),
                (1, Icons.arrow_upward, 'Uma camada para a frente (Ctrl+])'),
                (-1, Icons.arrow_downward, 'Uma camada para trás (Ctrl+[)'),
                (-2, Icons.flip_to_back, 'Enviar para trás (Ctrl+Shift+[)'),
              ])
                IconButton(tooltip: dica, onPressed: temSelecao ? () => moverCamada(passo) : null, icon: Icon(icone)),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: lista.isEmpty
              ? const Center(child: Text('Página vazia'))
              : ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: lista.length,
                  onReorderItem: (de, para) {
                    final ids = [for (final e in lista) e.id];
                    ids.insert(para, ids.removeAt(de));
                    reordenar(ids.reversed.toList());
                  },
                  itemBuilder: (context, i) {
                    final e = lista[i];
                    final (icone, nome) = _descrever(e);
                    return ListTile(
                      key: ValueKey(e.id),
                      dense: true,
                      selected: selecionados.contains(e.id),
                      selectedTileColor: cores.primaryContainer,
                      leading: Icon(
                        icone,
                        size: 18,
                        color: switch (e) {
                          Traco(:final cor) || Forma(:final cor) || Texto(:final cor) => cor,
                          NoFluxo(:final cor) || Ligacao(:final cor) || Tabela(:final cor) => cor,
                          Imagem() => null,
                        },
                      ),
                      title: Text(nome.replaceAll('\n', ' '), maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: e.grupo.isEmpty ? null : const Text('em grupo'),
                      trailing: ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle)),
                      onTap: () => selecionar(e.id, HardwareKeyboard.instance.isControlPressed),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _Cor extends StatelessWidget {
  const _Cor(this.rotulo, this.atual, this.recentes, this.escolher, {this.limpar});

  final String rotulo;
  final Color? atual;
  final List<Color> recentes;
  final ValueChanged<Color> escolher;
  final VoidCallback? limpar;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Row(
      spacing: 8,
      children: [
        Expanded(child: Text(rotulo)),
        if (limpar != null)
          IconButton(
            tooltip: 'Automático',
            visualDensity: VisualDensity.compact,
            onPressed: limpar,
            icon: const Icon(Icons.format_color_reset, size: 20),
          ),
        InkWell(
          onTap: () async {
            final c = await escolherCor(context, atual ?? const Color(0xFF1565C0), recentes, paleta: coresRapidas);
            if (c != null) escolher(c);
          },
          child: Container(
            width: 36,
            height: 28,
            decoration: BoxDecoration(
              color: atual,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Theme.of(context).colorScheme.outline),
            ),
            child: atual == null ? const Icon(Icons.auto_awesome, size: 16) : null,
          ),
        ),
      ],
    ),
  );
}

/// Abas das páginas no rodapé (como o draw.io): tocar abre, ⋮ (ou botão direito) renomeia, pinta ou
/// exclui, + cria. A roda do mouse em cima das abas rola a barra para os lados.
class BarraPaginas extends StatefulWidget {
  const BarraPaginas({super.key, required this.editor});

  final EditorQuadro editor;

  @override
  State<BarraPaginas> createState() => _BarraPaginasState();
}

class _BarraPaginasState extends State<BarraPaginas> {
  final _rolagem = ScrollController();

  EditorQuadro get editor => widget.editor;

  @override
  void dispose() {
    _rolagem.dispose();
    super.dispose();
  }

  void _rodaDoMouse(PointerSignalEvent e) {
    if (e is! PointerScrollEvent || !_rolagem.hasClients) return;
    GestureBinding.instance.pointerSignalResolver.register(e, (_) {
      final d = e.scrollDelta.dy.abs() > e.scrollDelta.dx.abs() ? e.scrollDelta.dy : e.scrollDelta.dx;
      final pos = _rolagem.position;
      _rolagem.jumpTo((pos.pixels + d).clamp(pos.minScrollExtent, pos.maxScrollExtent));
    });
  }

  Future<String?> _nome(BuildContext context, String titulo, String inicial) =>
      editarTextoFormatado(context, titulo: titulo, inicial: inicial, confirmar: 'OK', formatar: false);

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    return Material(
      color: cores.surfaceContainer,
      child: SizedBox(
        height: 42,
        child: Row(
          children: [
            Expanded(
              child: Listener(
                onPointerSignal: _rodaDoMouse,
                child: ListView(
                  controller: _rolagem,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  children: [
                    for (final (i, p) in editor.paginas.indexed)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
                        child: GestureDetector(onSecondaryTap: () => _menu(context, p), child: _aba(context, i, p)),
                      ),
                  ],
                ),
              ),
            ),
            IconButton(
              tooltip: 'Nova página',
              icon: const Icon(Icons.add),
              onPressed: () async {
                final n = await _nome(context, 'Nova página', 'Página ${editor.paginas.length + 1}');
                if (n != null && n.trim().isNotEmpty) await editor.novaPagina(n.trim());
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _aba(BuildContext context, int i, Pagina p) {
    final atual = p.id == editor.paginaAtual;
    final cor = p.cor;
    final texto = cor == null ? null : (cor.computeLuminance() > 0.5 ? Colors.black : Colors.white);
    return InputChip(
      label: Text(p.nome.isEmpty ? 'Página ${i + 1}' : p.nome, style: TextStyle(color: texto)),
      selected: atual,
      showCheckmark: false,
      backgroundColor: cor,
      selectedColor: cor,
      side: atual && cor != null ? BorderSide(color: Theme.of(context).colorScheme.primary, width: 2.5) : null,
      onPressed: () => editor.irPara(p.id),
      deleteIcon: Icon(Icons.more_vert, size: 16, color: texto),
      onDeleted: atual ? () => _menu(context, p) : null,
    );
  }

  Future<void> _menu(BuildContext context, Pagina p) async {
    final acao = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('Renomear página'),
              onTap: () => Navigator.pop(c, 'renomear'),
            ),
            ListTile(
              leading: Icon(Icons.format_color_fill, color: p.cor),
              title: const Text('Cor da aba'),
              onTap: () => Navigator.pop(c, 'cor'),
            ),
            if (p.cor != null)
              ListTile(
                leading: const Icon(Icons.format_color_reset),
                title: const Text('Tirar a cor da aba'),
                onTap: () => Navigator.pop(c, 'sem cor'),
              ),
            if (editor.paginas.length > 1)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Excluir página e o que tem nela'),
                onTap: () => Navigator.pop(c, 'excluir'),
              ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    if (acao == 'renomear') {
      final n = await _nome(context, 'Renomear página', p.nome);
      if (n != null && n.trim().isNotEmpty) await editor.renomearPagina(p.id, n.trim());
    } else if (acao == 'cor') {
      final c = await escolherCor(context, p.cor ?? const Color(0xFFFFE082), const [], paleta: coresRapidas);
      if (c != null) await editor.colorirPagina(p.id, c);
    } else if (acao == 'sem cor') {
      await editor.colorirPagina(p.id, null);
    } else if (acao == 'excluir') {
      await editor.excluirPagina(p.id);
    }
  }
}
