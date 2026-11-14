import 'dart:async';

import 'package:flutter/material.dart';

import '../modelos.dart';
import '../telas/bibliotecas_tela.dart';
import 'editor.dart';
import 'pintura.dart';

/// Diálogo de uma linha; [sugestoes] aparecem como atalhos (ex.: redes já usadas).
Future<String?> pedirTexto(BuildContext context, String titulo, {String inicial = '', List<String> sugestoes = const []}) async {
  final controle = TextEditingController(text: inicial);
  final r = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(titulo),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          TextField(controller: controle, autofocus: true, onSubmitted: (v) => Navigator.pop(c, v)),
          if (sugestoes.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [for (final s in sugestoes) ActionChip(label: Text(s), onPressed: () => Navigator.pop(c, s))],
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(c, controle.text), child: const Text('OK')),
      ],
    ),
  );
  controle.dispose();
  return r;
}

/// Diálogo de propriedades do item (E ou toque duplo); usado também no celular, sem painel lateral.
Future<void> editarItem(BuildContext context, Editor editor, Item item) async {
  switch (item) {
    case Componente c:
      final ref = TextEditingController(text: c.ref);
      final valor = TextEditingController(text: c.valor);
      final enc = TextEditingController(text: c.encapsulamento);
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(editor.simboloDe(c).nome),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              TextField(controller: ref, decoration: const InputDecoration(labelText: 'Referência')),
              TextField(controller: valor, autofocus: true, decoration: const InputDecoration(labelText: 'Valor')),
              TextField(controller: enc, decoration: const InputDecoration(labelText: 'Encapsulamento')),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Salvar')),
          ],
        ),
      );
      if (ok == true) {
        editor.alterar(() {
          c
            ..ref = ref.text.trim()
            ..valor = valor.text.trim()
            ..encapsulamento = enc.text.trim();
        });
      }
      for (final t in [ref, valor, enc]) {
        t.dispose();
      }
    case Rotulo r:
      final nome = await pedirTexto(context, 'Nome da rede', inicial: r.nome);
      if (nome != null && nome.trim().isNotEmpty) editor.alterar(() => r.nome = nome.trim());
    case TextoCad t:
      final texto = await pedirTexto(context, 'Texto', inicial: t.texto);
      if (texto != null && texto.trim().isNotEmpty) editor.alterar(() => t.texto = texto);
    case Fio() || Sonda():
      break;
  }
}

/// Miniatura do símbolo, centrada e na escala que cabe.
class PreviaSimbolo extends StatelessWidget {
  const PreviaSimbolo(this.simbolo, {super.key, this.tamanho = 44});

  final Simbolo simbolo;
  final double tamanho;

  @override
  Widget build(BuildContext context) => SizedBox.square(dimension: tamanho, child: CustomPaint(painter: _PintorPrevia(simbolo)));
}

class _PintorPrevia extends CustomPainter {
  _PintorPrevia(this.s);

  final Simbolo s;

  @override
  void paint(Canvas canvas, Size size) {
    final r = s.limites;
    if (r.isEmpty) return;
    final escala = (size.shortestSide / r.longestSide) * 0.9;
    canvas
      ..translate(size.width / 2, size.height / 2)
      ..scale(escala)
      ..translate(-r.center.dx, -r.center.dy);
    pintarSimbolo(canvas, s, pos: const P(0, 0), paleta: Paleta.escura, campos: false);
  }

  @override
  bool shouldRepaint(_PintorPrevia old) => old.s != s;
}

/// Biblioteca: aba Base (busca local por categoria) e aba KiCad (busca no servidor nas importadas).
/// Tocar num símbolo arma a ferramenta de componente.
class PainelBiblioteca extends StatefulWidget {
  const PainelBiblioteca({super.key, required this.editor, required this.foco, required this.aoEscolher});

  final Editor editor;
  final FocusNode foco;
  final VoidCallback aoEscolher;

  @override
  State<PainelBiblioteca> createState() => _PainelBibliotecaState();
}

class _PainelBibliotecaState extends State<PainelBiblioteca> {
  String _busca = '';
  String? _categoria;
  bool _kicad = false;
  List<String> _importadas = [];
  String? _lib;
  List<Simbolo> _achados = [];
  bool _buscando = false;
  String? _erro;
  Timer? _espera;
  int _pedido = 0;

  @override
  void dispose() {
    _espera?.cancel();
    super.dispose();
  }

  Future<void> _carregarImportadas() async {
    try {
      final libs = await widget.editor.api.bibliotecas();
      if (mounted) setState(() => _importadas = [for (final b in libs) '${b['nome']}']);
    } catch (_) {}
  }

  void _trocarAba(bool kicad) {
    setState(() => _kicad = kicad);
    if (kicad) {
      _carregarImportadas();
      _buscarServidor();
    }
  }

  void _mudouBusca(String v) {
    setState(() => _busca = v);
    if (!_kicad) return;
    _espera?.cancel();
    _espera = Timer(const Duration(milliseconds: 300), _buscarServidor);
  }

  Future<void> _buscarServidor() async {
    if (_busca.trim().isEmpty && _lib == null) {
      setState(() => _achados = []);
      return;
    }
    final pedido = ++_pedido;
    setState(() {
      _buscando = true;
      _erro = null;
    });
    try {
      final r = await widget.editor.api.buscarSimbolos(_busca, biblioteca: _lib);
      if (!mounted || pedido != _pedido) return;
      setState(() => _achados = r);
    } catch (e) {
      if (mounted && pedido == _pedido) setState(() => _erro = '$e');
    } finally {
      if (mounted && pedido == _pedido) setState(() => _buscando = false);
    }
  }

  Future<void> _gerenciar() async {
    await mostrarBibliotecas(context, widget.editor.api);
    await _carregarImportadas();
    if (_lib != null && !_importadas.contains(_lib)) _lib = null;
    _buscarServidor();
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.editor.biblioteca;
    final lista = _kicad ? _achados : b.buscar(_busca, categoria: _categoria);
    final chips = _kicad ? _importadas : b.categorias;
    final atual = _kicad ? _lib : _categoria;
    return ListenableBuilder(
      listenable: widget.editor,
      builder: (context, _) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Row(
              spacing: 4,
              children: [
                Expanded(
                  child: SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('Base')),
                      ButtonSegment(value: true, label: Text('KiCad')),
                    ],
                    selected: {_kicad},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) => _trocarAba(s.first),
                  ),
                ),
                IconButton(tooltip: 'Bibliotecas do KiCad', onPressed: _gerenciar, icon: const Icon(Icons.library_add_outlined)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: TextField(
              focusNode: widget.foco,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: _kicad ? 'Buscar no KiCad (ex.: LM358, mosfet)' : 'Buscar componente (A)',
                isDense: true,
              ),
              onChanged: _mudouBusca,
              onSubmitted: (_) {
                if (lista.isNotEmpty) _escolher(lista.first);
              },
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              children: [
                for (final c in [null, ...chips])
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: ChoiceChip(
                      label: Text(c ?? 'Todos'),
                      selected: atual == c,
                      onSelected: (_) {
                        setState(() => _kicad ? _lib = c : _categoria = c);
                        if (_kicad) _buscarServidor();
                      },
                    ),
                  ),
              ],
            ),
          ),
          if (_buscando) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _lista(lista)),
        ],
      ),
    );
  }

  Widget _lista(List<Simbolo> lista) {
    if (_kicad && _erro != null) return Center(child: Padding(padding: const EdgeInsets.all(16), child: Text('Não buscou: $_erro')));
    if (_kicad && _importadas.isEmpty && !_buscando) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              const Text('Nenhuma biblioteca do KiCad importada.', textAlign: TextAlign.center),
              FilledButton.icon(onPressed: _gerenciar, icon: const Icon(Icons.library_add_outlined), label: const Text('Importar')),
            ],
          ),
        ),
      );
    }
    if (_kicad && lista.isEmpty && !_buscando) {
      return const Center(child: Text('Digite para buscar ou escolha uma biblioteca.'));
    }
    return ListView.builder(
      itemCount: lista.length,
      itemBuilder: (context, i) {
        final s = lista[i];
        final ativo = widget.editor.ferramenta == Ferramenta.componente && widget.editor.simbolo?.id == s.id;
        final detalhe = _kicad
            ? [s.categoria, if (s.descricao.isNotEmpty) s.descricao].join(' · ')
            : [s.prefixo, s.valor].where((t) => t.isNotEmpty).join(' · ');
        return ListTile(
          selected: ativo,
          leading: PreviaSimbolo(s),
          title: Text(s.nome),
          subtitle: Text(detalhe, maxLines: 2, overflow: TextOverflow.ellipsis),
          onTap: () => _escolher(s),
        );
      },
    );
  }

  void _escolher(Simbolo s) {
    widget.editor.biblioteca.adicionar([s]);
    widget.editor.escolher(Ferramenta.componente, s: s);
    widget.aoEscolher();
  }
}

/// Barra das ferramentas, com botões grandes para dedo e caneta (sem teclado).
class BarraFerramentas extends StatelessWidget {
  const BarraFerramentas({super.key, required this.editor, required this.aoBiblioteca});

  final Editor editor;
  final VoidCallback aoBiblioteca;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: editor,
    builder: (context, _) {
      final f = editor.ferramenta;
      Widget ferramenta(Ferramenta alvo, IconData icone, String dica, [VoidCallback? acao]) => IconButton(
        tooltip: dica,
        isSelected: f == alvo,
        onPressed: acao ?? () => editor.escolher(alvo),
        icon: Icon(icone),
      );
      final temSelecao = editor.selecao.isNotEmpty;
      final armado = f == Ferramenta.componente;
      return Material(
        color: Theme.of(context).colorScheme.surfaceContainer,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              ferramenta(Ferramenta.selecionar, Icons.near_me_outlined, 'Selecionar (V)'),
              ferramenta(Ferramenta.componente, Icons.memory, 'Componente (A)', aoBiblioteca),
              ferramenta(Ferramenta.fio, Icons.timeline, 'Fio (W)'),
              ferramenta(Ferramenta.rotulo, Icons.label_outline, 'Rótulo de rede (L)'),
              ferramenta(Ferramenta.texto, Icons.title, 'Texto (T)'),
              ferramenta(Ferramenta.sonda, Icons.colorize_outlined, 'Ponta de prova (P): na rede = tensão, no componente = corrente'),
              const SizedBox(height: 32, child: VerticalDivider()),
              IconButton(tooltip: 'Girar 90° (R)', onPressed: temSelecao || armado ? editor.girar : null, icon: const Icon(Icons.rotate_90_degrees_cw_outlined)),
              IconButton(tooltip: 'Espelhar (X)', onPressed: temSelecao || armado ? editor.espelhar : null, icon: const Icon(Icons.flip)),
              IconButton(tooltip: 'Duplicar (Ctrl+D)', onPressed: temSelecao ? editor.duplicarSelecao : null, icon: const Icon(Icons.copy_all_outlined)),
              IconButton(tooltip: 'Excluir (Del)', onPressed: temSelecao ? editor.excluirSelecao : null, icon: const Icon(Icons.delete_outline)),
              if (editor.fio != null) ...[
                const SizedBox(height: 32, child: VerticalDivider()),
                IconButton(
                  tooltip: 'Inverter o canto (/)',
                  onPressed: editor.inverterCanto,
                  icon: const Icon(Icons.turn_right),
                ),
                FilledButton.tonalIcon(onPressed: editor.concluirFio, icon: const Icon(Icons.check), label: const Text('Concluir fio')),
              ],
              if (armado && editor.simbolo != null)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Chip(
                    avatar: PreviaSimbolo(editor.simbolo!, tamanho: 22),
                    label: Text(editor.simbolo!.nome),
                    onDeleted: () => editor.escolher(Ferramenta.selecionar),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

/// Abas das folhas + coordenadas do cursor (mm), zoom e passo da grade.
class BarraFolhas extends StatelessWidget {
  const BarraFolhas({super.key, required this.editor, required this.camera});

  final Editor editor;
  final Camera camera;

  Future<void> _menu(BuildContext context, Folha f) async {
    final acao = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Renomear'), onTap: () => Navigator.pop(c, 'renomear')),
            if (editor.projeto.folhas.length > 1)
              ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Excluir folha'), onTap: () => Navigator.pop(c, 'excluir')),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    if (acao == 'renomear') {
      final nome = await pedirTexto(context, 'Nome da folha', inicial: f.nome);
      if (nome != null && nome.trim().isNotEmpty) editor.renomearFolha(f.id, nome.trim());
    } else if (acao == 'excluir') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('Excluir "${f.nome}" e tudo o que está nela?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Excluir')),
          ],
        ),
      );
      if (ok == true) editor.excluirFolha(f.id);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: editor,
    builder: (context, _) {
      final c = editor.cursor;
      final estilo = Theme.of(context).textTheme.labelSmall?.copyWith(fontFamily: 'monospace');
      String mm(int um) => (um / 1000).toStringAsFixed(2);
      // No celular a grade e as coordenadas encolhem para sobrar lugar às abas das folhas.
      final estreito = MediaQuery.sizeOf(context).width < 700;
      final rotulo = estreito ? '' : 'grade ';
      return Material(
        color: Theme.of(context).colorScheme.surfaceContainer,
        child: SizedBox(
          height: 44,
          child: Row(
            children: [
              Expanded(
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                  children: [
                    for (final f in editor.projeto.folhas)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: GestureDetector(
                          onLongPress: () => _menu(context, f),
                          onSecondaryTap: () => _menu(context, f),
                          child: ChoiceChip(label: Text(f.nome), selected: f.id == editor.folha, onSelected: (_) => editor.irPara(f.id)),
                        ),
                      ),
                    IconButton(tooltip: 'Nova folha', onPressed: editor.novaFolha, icon: const Icon(Icons.add)),
                  ],
                ),
              ),
              DropdownButton<int>(
                value: editor.passo,
                underline: const SizedBox.shrink(),
                style: estilo,
                items: [
                  DropdownMenuItem(value: 635, child: Text('${rotulo}0,635 mm')),
                  DropdownMenuItem(value: grade, child: Text('${rotulo}1,27 mm')),
                  DropdownMenuItem(value: 2540, child: Text('${rotulo}2,54 mm')),
                ],
                onChanged: (v) => v == null ? null : editor.mudarPasso(v),
              ),
              SizedBox(width: estreito ? 6 : 12),
              SizedBox(
                width: estreito ? 96 : 190,
                child: Text(
                  c == null ? '' : (estreito ? 'X ${mm(c.x)}\nY ${mm(c.y)}' : 'X ${mm(c.x)}  Y ${mm(c.y)} mm'),
                  style: estilo,
                  maxLines: 2,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Painel da direita: propriedades do que está selecionado e as camadas.
class PainelPropriedades extends StatelessWidget {
  const PainelPropriedades({super.key, required this.editor});

  final Editor editor;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: editor,
    builder: (context, _) {
      final sel = editor.selecionados;
      final titulo = Theme.of(context).textTheme.titleSmall;
      return ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text('Propriedades', style: titulo),
          const SizedBox(height: 8),
          if (sel.isEmpty) const Text('Nada selecionado. Toque num item ou arraste uma janela (mouse).'),
          if (sel.length > 1) Text('${sel.length} itens selecionados'),
          if (sel.length == 1) ..._campos(context, sel.single),
          const Divider(height: 32),
          Text('Camadas', style: titulo),
          for (final c in Camada.values)
            Row(
              children: [
                Expanded(child: Text(c.nome)),
                IconButton(
                  tooltip: editor.ocultas.contains(c) ? 'Mostrar' : 'Esconder',
                  onPressed: () => editor.alternarCamada(c),
                  icon: Icon(editor.ocultas.contains(c) ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                ),
                if (c != Camada.grade && c != Camada.campos)
                  IconButton(
                    tooltip: editor.travadas.contains(c) ? 'Destravar' : 'Travar (não seleciona)',
                    onPressed: () => editor.alternarCamada(c, travar: true),
                    icon: Icon(editor.travadas.contains(c) ? Icons.lock_outline : Icons.lock_open_outlined),
                  ),
              ],
            ),
        ],
      );
    },
  );

  List<Widget> _campos(BuildContext context, Item item) => switch (item) {
    Componente c => [
      Row(
        spacing: 12,
        children: [
          PreviaSimbolo(editor.simboloDe(c)),
          Expanded(child: Text(editor.simboloDe(c).nome)),
        ],
      ),
      _Campo(key: ValueKey('${c.id}ref'), rotulo: 'Referência', valor: c.ref, aoMudar: (v) => editor.alterar(() => c.ref = v)),
      _Campo(key: ValueKey('${c.id}val'), rotulo: 'Valor', valor: c.valor, aoMudar: (v) => editor.alterar(() => c.valor = v)),
      _Campo(
        key: ValueKey('${c.id}enc'),
        rotulo: 'Encapsulamento',
        valor: c.encapsulamento,
        aoMudar: (v) => editor.alterar(() => c.encapsulamento = v),
      ),
      const SizedBox(height: 8),
      Text('Posição: ${(c.pos.x / 1000).toStringAsFixed(2)}, ${(c.pos.y / 1000).toStringAsFixed(2)} mm · ${c.rot}°${c.espelho ? ' · espelhado' : ''}'),
      const SizedBox(height: 8),
      Text('Pinos', style: Theme.of(context).textTheme.labelLarge),
      for (final p in editor.simboloDe(c).pinos)
        Text('${p.n.padLeft(2)}  ${p.nome.isEmpty ? '—' : p.nome}  (${p.tipo})', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
    ],
    Rotulo r => [_Campo(key: ValueKey(r.id), rotulo: 'Rede', valor: r.nome, aoMudar: (v) => editor.alterar(() => r.nome = v))],
    TextoCad t => [
      _Campo(key: ValueKey(t.id), rotulo: 'Texto', valor: t.texto, aoMudar: (v) => editor.alterar(() => t.texto = v)),
      DropdownButton<int>(
        value: t.tamanho,
        isExpanded: true,
        items: [for (final s in [635, 1016, grade, 1905, 2540, 3810]) DropdownMenuItem(value: s, child: Text('${(s / 1000).toStringAsFixed(2)} mm'))],
        onChanged: (v) => v == null ? null : editor.alterar(() => t.tamanho = v),
      ),
    ],
    Fio f => [Text('Fio com ${f.pontos.length} pontos')],
    Sonda s => [
      Text(s.tipo == 'v' ? 'Ponta de tensão V${editor.indiceSonda(s) + 1}' : 'Ponta de corrente em ${s.ref}'),
      if (editor.leituras[s.id] != null) Text('Última leitura: ${editor.leituras[s.id]}'),
      const Text('O sinal dela abre ligado no osciloscópio, com a mesma cor.'),
    ],
  };
}

/// Campo que só grava ao confirmar (Enter) ou sair dele: uma entrada de desfazer por edição.
class _Campo extends StatefulWidget {
  const _Campo({super.key, required this.rotulo, required this.valor, required this.aoMudar});

  final String rotulo, valor;
  final ValueChanged<String> aoMudar;

  @override
  State<_Campo> createState() => _CampoState();
}

class _CampoState extends State<_Campo> {
  late final _controle = TextEditingController(text: widget.valor);
  final _foco = FocusNode();

  @override
  void initState() {
    super.initState();
    _foco.addListener(() {
      if (!_foco.hasFocus) _confirmar();
    });
  }

  @override
  void didUpdateWidget(_Campo old) {
    super.didUpdateWidget(old);
    if (!_foco.hasFocus && widget.valor != _controle.text) _controle.text = widget.valor;
  }

  void _confirmar() {
    final v = _controle.text.trim();
    if (v.isNotEmpty && v != widget.valor) widget.aoMudar(v);
  }

  @override
  void dispose() {
    _controle.dispose();
    _foco.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: TextField(
      controller: _controle,
      focusNode: _foco,
      decoration: InputDecoration(labelText: widget.rotulo, isDense: true),
      onSubmitted: (_) => _confirmar(),
    ),
  );
}
