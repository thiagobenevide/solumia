import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:xml/xml.dart';

import '../api_arquivos.dart';
import '../externo/externo.dart';
import '../modelos.dart';
import '../telas/acoes_destaque.dart';
import '../telas/biblioteca_tela.dart';

/// Texto do original e como estava codificado, para gravar de volta do mesmo jeito: UTF-8 (com ou
/// sem BOM) ou, se não for, Latin-1 (CSV exportado pelo Excel em PT-BR).
class TextoOriginal {
  TextoOriginal(this.texto, {this.emLatin1 = false, this.bom = false});

  factory TextoOriginal.decodificar(Uint8List bytes) {
    try {
      // utf8.decode já descarta o BOM; ele é visto nos bytes.
      final bom = bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF;
      return TextoOriginal(utf8.decode(bytes), bom: bom);
    } on FormatException {
      return TextoOriginal(latin1.decode(bytes), emLatin1: true);
    }
  }

  final String texto;
  final bool emLatin1;
  final bool bom;

  /// Caractere fora do Latin-1 vira `?` (o arquivo original já não aceitava).
  Uint8List codificar(String novo) => emLatin1
      ? const Latin1Codec(allowInvalid: true).encode(novo)
      : utf8.encode(bom ? '\uFEFF$novo' : novo);
}

/// Linhas do CSV e o separador (`;`, `,` ou tab: o mais frequente na primeira linha). Aspas
/// duplas protegem separador e quebra de linha; `""` dentro delas vira `"`.
(List<List<String>>, String) lerCsv(String texto) {
  final primeira = texto.split('\n').first;
  final separador = [';', ',', '\t'].reduce((a, b) => b.allMatches(primeira).length > a.allMatches(primeira).length ? b : a);
  final linhas = <List<String>>[];
  var linha = <String>[];
  final campo = StringBuffer();
  var aspas = false;
  for (var i = 0; i < texto.length; i++) {
    final c = texto[i];
    if (aspas) {
      if (c == '"' && i + 1 < texto.length && texto[i + 1] == '"') {
        campo.write('"');
        i++;
      } else if (c == '"') {
        aspas = false;
      } else {
        campo.write(c);
      }
    } else if (c == '"') {
      aspas = true;
    } else if (c == separador) {
      linha.add(campo.toString());
      campo.clear();
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < texto.length && texto[i + 1] == '\n') i++;
      linha.add(campo.toString());
      campo.clear();
      linhas.add(linha);
      linha = [];
    } else {
      campo.write(c);
    }
  }
  if (campo.isNotEmpty || linha.isNotEmpty) linhas.add([...linha, campo.toString()]);
  return ([for (final l in linhas) if (l.any((c) => c.isNotEmpty)) l], separador);
}

/// Inverso de [lerCsv]: aspas só onde o campo tem separador, aspas ou quebra de linha.
String escreverCsv(List<List<String>> linhas, String separador, {String quebra = '\n'}) {
  String campo(String c) =>
      c.contains(separador) || c.contains('"') || c.contains('\n') || c.contains('\r') ? '"${c.replaceAll('"', '""')}"' : c;
  return [for (final l in linhas) l.map(campo).join(separador)].join(quebra) + quebra;
}

/// Grava o texto editado: sobe já ou, sem conexão, fica no aparelho. `true` se deu certo.
typedef Salvar = Future<bool> Function(String novo);

/// Baixa o original (do aparelho quando baixado, senão do servidor) e entrega ao editor.
class _OriginalTela extends StatefulWidget {
  const _OriginalTela({required this.api, required this.arquivo, required this.construir});

  final ApiArquivos api;
  final Arquivo arquivo;
  final Widget Function(TextoOriginal original, Salvar salvar) construir;

  @override
  State<_OriginalTela> createState() => _OriginalTelaState();
}

class _OriginalTelaState extends State<_OriginalTela> {
  late final Future<TextoOriginal> _original = _ler();

  Future<TextoOriginal> _ler() async {
    final id = widget.arquivo.id;
    return TextoOriginal.decodificar(await widget.api.offline.original(id) ?? await widget.api.original(id));
  }

  Future<bool> _salvar(String novo) async {
    try {
      final bytes = (await _original).codificar(novo);
      final salvo = await widget.api.offline.salvarOriginal(widget.arquivo, bytes);
      if (mounted) avisar(context, salvo == null ? 'Sem conexão: salvo no aparelho; sobe quando a conexão voltar.' : 'Salvo.');
      return true;
    } on ApiErro catch (e) {
      if (mounted) avisar(context, 'Não consegui salvar: ${e.mensagem}');
      return false;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.arquivo.titulo, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        if (editoresPara(widget.arquivo).isNotEmpty)
          IconButton(
            tooltip: 'Abrir com…',
            icon: const Icon(Icons.open_in_new),
            onPressed: () => abrirComEditor(context, widget.api, widget.arquivo),
          ),
      ],
    ),
    body: FutureBuilder(
      future: _original,
      builder: (context, s) => s.hasError
          ? Center(child: Text('Não consegui abrir: ${s.error is ApiErro ? (s.error as ApiErro).mensagem : s.error}'))
          : s.hasData
          ? widget.construir(s.data!, _salvar)
          : const Center(child: CircularProgressIndicator()),
    ),
  );
}

/// Pergunta antes de sair com alterações não salvas.
class GuardaSaida extends StatelessWidget {
  const GuardaSaida({super.key, required this.sujo, required this.child});

  final bool sujo;
  final Widget child;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !sujo,
    onPopInvokedWithResult: (saiu, _) async {
      if (saiu) return;
      final sair = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Sair sem salvar?'),
          content: const Text('As alterações feitas aqui se perdem.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Continuar editando')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Sair')),
          ],
        ),
      );
      if (sair == true && context.mounted) Navigator.of(context).pop();
    },
    child: child,
  );
}

/// CSV em tabela editável: toque na célula para editar; menu da linha (nº) e da coluna
/// (cabeçalho) para inserir e excluir.
class CsvTela extends StatelessWidget {
  const CsvTela({super.key, required this.api, required this.arquivo});

  final ApiArquivos api;
  final Arquivo arquivo;

  @override
  Widget build(BuildContext context) =>
      _OriginalTela(api: api, arquivo: arquivo, construir: (o, salvar) => _Tabela(original: o.texto, salvar: salvar));
}

class _Tabela extends StatefulWidget {
  const _Tabela({required this.original, required this.salvar});

  final String original;
  final Salvar salvar;

  @override
  State<_Tabela> createState() => _TabelaState();
}

class _TabelaState extends State<_Tabela> {
  static const _largura = 180.0;
  static const _larguraNumero = 56.0;

  late final List<List<String>> _linhas;
  late final String _separador;
  late final String _quebra = widget.original.contains('\r\n') ? '\r\n' : '\n';
  String _busca = '';
  bool _sujo = false;
  bool _salvando = false;
  (int, int)? _editando;
  final _campo = TextEditingController();

  @override
  void initState() {
    super.initState();
    final (linhas, separador) = lerCsv(widget.original);
    _linhas = linhas.isEmpty ? [<String>['']] : linhas;
    _separador = separador;
  }

  @override
  void dispose() {
    _campo.dispose();
    super.dispose();
  }

  int get _colunas => _linhas.fold(0, (n, l) => l.length > n ? l.length : n);

  void _alterar(VoidCallback f) => setState(() {
    f();
    _sujo = true;
  });

  void _editar(int linha, int coluna) {
    _confirmarEdicao();
    final l = _linhas[linha];
    _campo.text = coluna < l.length ? l[coluna] : '';
    setState(() => _editando = (linha, coluna));
  }

  void _confirmarEdicao() {
    final e = _editando;
    if (e == null) return;
    final (linha, coluna) = e;
    final l = _linhas[linha];
    while (l.length <= coluna) {
      l.add('');
    }
    if (l[coluna] != _campo.text) {
      l[coluna] = _campo.text;
      _sujo = true;
    }
    setState(() => _editando = null);
  }

  Future<void> _salvar() async {
    _confirmarEdicao();
    setState(() => _salvando = true);
    final ok = await widget.salvar(escreverCsv(_linhas, _separador, quebra: _quebra));
    if (!mounted) return;
    setState(() {
      _salvando = false;
      if (ok) _sujo = false;
    });
  }

  void _acaoLinha(String acao, int i) => _alterar(() {
    _editando = null;
    switch (acao) {
      case 'acima':
        _linhas.insert(i, List.filled(_colunas, '', growable: true));
      case 'abaixo':
        _linhas.insert(i + 1, List.filled(_colunas, '', growable: true));
      case 'excluir':
        _linhas.removeAt(i);
    }
  });

  void _acaoColuna(String acao, int c) => _alterar(() {
    _editando = null;
    for (final l in _linhas) {
      while (l.length < _colunas) {
        l.add('');
      }
    }
    for (final l in _linhas) {
      if (acao == 'direita') l.insert(c + 1, '');
      if (acao == 'excluir' && _linhas.first.length > 1) l.removeAt(c);
    }
  });

  Widget _celula(int linha, int coluna, {bool negrito = false}) {
    final cores = Theme.of(context).colorScheme;
    final l = _linhas[linha];
    final editando = _editando == (linha, coluna);
    return Container(
      width: _largura,
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: cores.outlineVariant)),
        color: editando ? cores.primaryContainer : null,
      ),
      child: editando
          ? TextField(
              controller: _campo,
              autofocus: true,
              style: negrito ? const TextStyle(fontWeight: FontWeight.bold) : null,
              decoration: const InputDecoration(isDense: true, border: InputBorder.none),
              onSubmitted: (_) => _confirmarEdicao(),
              onTapOutside: (_) => _confirmarEdicao(),
            )
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _editar(linha, coluna),
              child: SizedBox.expand(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    coluna < l.length ? l[coluna] : '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: negrito ? const TextStyle(fontWeight: FontWeight.bold) : null,
                  ),
                ),
              ),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colunas = _colunas;
    final termo = _busca.toLowerCase();
    final indices = [
      for (var i = 1; i < _linhas.length; i++)
        if (termo.isEmpty || _linhas[i].any((c) => c.toLowerCase().contains(termo))) i,
    ];
    final cores = Theme.of(context).colorScheme;
    Widget linha(int i, {Color? fundo}) => Container(
      color: fundo,
      child: Row(
        children: [
          SizedBox(
            width: _larguraNumero,
            child: PopupMenuButton<String>(
              tooltip: 'Linha $i',
              onSelected: (a) => _acaoLinha(a, i),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'acima', child: Text('Inserir linha acima')),
                PopupMenuItem(value: 'abaixo', child: Text('Inserir linha abaixo')),
                PopupMenuItem(value: 'excluir', child: Text('Excluir linha')),
              ],
              child: Center(child: Text('$i', style: TextStyle(color: cores.outline))),
            ),
          ),
          for (var c = 0; c < colunas; c++) _celula(i, c),
        ],
      ),
    );
    return GuardaSaida(
      sujo: _sujo,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              spacing: 8,
              children: [
                Expanded(
                  child: TextField(
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'Buscar nas linhas',
                      helperText: '${indices.length} de ${_linhas.length - 1} linhas · $colunas colunas',
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (v) => setState(() => _busca = v),
                  ),
                ),
                IconButton(
                  tooltip: 'Nova linha no fim',
                  icon: const Icon(Icons.playlist_add),
                  onPressed: () => _acaoLinha('abaixo', _linhas.length - 1),
                ),
                IconButton(
                  tooltip: 'Nova coluna no fim',
                  icon: const Icon(Icons.view_column_outlined),
                  onPressed: () => _acaoColuna('direita', colunas - 1),
                ),
                FilledButton.icon(
                  onPressed: _sujo && !_salvando ? _salvar : null,
                  icon: _salvando
                      ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.save_outlined),
                  label: const Text('Salvar'),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: _larguraNumero + colunas * _largura,
                child: Column(
                  children: [
                    Container(
                      color: cores.surfaceContainerHighest,
                      child: Row(
                        children: [
                          const SizedBox(width: _larguraNumero),
                          for (var c = 0; c < colunas; c++)
                            Stack(
                              children: [
                                _celula(0, c, negrito: true),
                                Positioned(
                                  right: 0,
                                  top: 0,
                                  bottom: 0,
                                  child: PopupMenuButton<String>(
                                    tooltip: 'Coluna',
                                    icon: const Icon(Icons.more_vert, size: 16),
                                    padding: EdgeInsets.zero,
                                    onSelected: (a) => _acaoColuna(a, c),
                                    itemBuilder: (_) => const [
                                      PopupMenuItem(value: 'direita', child: Text('Inserir coluna à direita')),
                                      PopupMenuItem(value: 'excluir', child: Text('Excluir coluna')),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: indices.length,
                        itemBuilder: (_, k) => linha(indices[k], fundo: k.isOdd ? cores.surfaceContainerLow : null),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// XML em árvore recolhível (navegar) ou em texto editável (o original, sem reformatar).
class XmlTela extends StatelessWidget {
  const XmlTela({super.key, required this.api, required this.arquivo});

  final ApiArquivos api;
  final Arquivo arquivo;

  @override
  Widget build(BuildContext context) =>
      _OriginalTela(api: api, arquivo: arquivo, construir: (o, salvar) => _EditorXml(original: o.texto, salvar: salvar));
}

class _EditorXml extends StatefulWidget {
  const _EditorXml({required this.original, required this.salvar});

  final String original;
  final Salvar salvar;

  @override
  State<_EditorXml> createState() => _EditorXmlState();
}

class _EditorXmlState extends State<_EditorXml> {
  late final _texto = TextEditingController(text: widget.original);
  late String _salvo = widget.original;
  bool _modoTexto = false;
  bool _salvando = false;

  bool get _sujo => _texto.text != _salvo;

  @override
  void dispose() {
    _texto.dispose();
    super.dispose();
  }

  Future<void> _salvar() async {
    final novo = _texto.text;
    try {
      XmlDocument.parse(novo);
    } on XmlException catch (e) {
      return avisar(context, 'XML inválido, não salvei: $e');
    }
    setState(() => _salvando = true);
    final ok = await widget.salvar(novo);
    if (!mounted) return;
    setState(() {
      _salvando = false;
      if (ok) _salvo = novo;
    });
  }

  @override
  Widget build(BuildContext context) {
    Widget corpo;
    if (_modoTexto) {
      corpo = Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: TextField(
          controller: _texto,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          decoration: const InputDecoration(border: OutlineInputBorder()),
          onChanged: (_) => setState(() {}),
        ),
      );
    } else {
      try {
        corpo = _ArvoreXml(key: ValueKey(_texto.text), raiz: XmlDocument.parse(_texto.text).rootElement);
      } on XmlException catch (e) {
        corpo = Center(child: Text('XML inválido ($e). Corrija no modo texto.'));
      }
    }
    return GuardaSaida(
      sujo: _sujo,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              spacing: 8,
              children: [
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, icon: Icon(Icons.account_tree_outlined), label: Text('Árvore')),
                    ButtonSegment(value: true, icon: Icon(Icons.edit_note), label: Text('Editar texto')),
                  ],
                  selected: {_modoTexto},
                  onSelectionChanged: (s) => setState(() => _modoTexto = s.first),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _sujo && !_salvando ? _salvar : null,
                  icon: _salvando
                      ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.save_outlined),
                  label: const Text('Salvar'),
                ),
              ],
            ),
          ),
          Expanded(child: corpo),
        ],
      ),
    );
  }
}

class _ArvoreXml extends StatefulWidget {
  const _ArvoreXml({super.key, required this.raiz});

  final XmlElement raiz;

  @override
  State<_ArvoreXml> createState() => _ArvoreXmlState();
}

class _ArvoreXmlState extends State<_ArvoreXml> {
  /// Elementos abertos; começa com a raiz e o primeiro nível.
  late final Set<XmlElement> _abertos = {widget.raiz, ...widget.raiz.childElements};

  /// Elementos visíveis em ordem, com a profundidade.
  List<(XmlElement, int)> _visiveis() {
    final saida = <(XmlElement, int)>[];
    void visitar(XmlElement e, int nivel) {
      saida.add((e, nivel));
      if (_abertos.contains(e)) {
        for (final f in e.childElements) {
          visitar(f, nivel + 1);
        }
      }
    }

    visitar(widget.raiz, 0);
    return saida;
  }

  @override
  Widget build(BuildContext context) {
    final visiveis = _visiveis();
    final cores = Theme.of(context).colorScheme;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: visiveis.length,
      itemBuilder: (context, i) {
        final (e, nivel) = visiveis[i];
        final temFilhos = e.childElements.isNotEmpty;
        final valor = temFilhos ? '' : e.innerText.trim();
        return InkWell(
          onTap: temFilhos ? () => setState(() => _abertos.contains(e) ? _abertos.remove(e) : _abertos.add(e)) : null,
          child: Padding(
            padding: EdgeInsets.fromLTRB(8 + nivel * 18.0, 4, 16, 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 24,
                  child: temFilhos
                      ? Icon(_abertos.contains(e) ? Icons.expand_more : Icons.chevron_right, size: 20)
                      : null,
                ),
                Expanded(
                  child: SelectableText.rich(
                    TextSpan(
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                      children: [
                        TextSpan(text: e.name.qualified, style: TextStyle(color: cores.primary, fontWeight: FontWeight.bold)),
                        for (final a in e.attributes) ...[
                          TextSpan(text: ' ${a.name.qualified}=', style: TextStyle(color: cores.tertiary)),
                          TextSpan(text: '"${a.value}"'),
                        ],
                        if (temFilhos && !_abertos.contains(e))
                          TextSpan(text: '  (${e.childElements.length})', style: TextStyle(color: cores.outline)),
                        if (valor.isNotEmpty) TextSpan(text: '  $valor', style: TextStyle(color: cores.onSurface)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
