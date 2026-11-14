import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';

import '../api_arquivos.dart';
import '../leitor/dados_tela.dart';
import '../modelos.dart';
import 'docx.dart';
import 'exportar.dart';
import '../telas/acoes_destaque.dart';
import 'reescrita.dart';

/// Autor das sugestões de ortografia/gramática pedidas ao Claude.
const autorRevisorClaude = 'Revisor (Claude)';

const _fontes = {
  'Padrão': 'Clear',
  'Times New Roman': 'Times New Roman',
  'Arial': 'Arial',
  'Calibri': 'Calibri',
  'Cambria': 'Cambria',
  'Georgia': 'Georgia',
  'Garamond': 'Garamond',
  'Liberation Serif': 'Liberation Serif',
  'Liberation Sans': 'Liberation Sans',
  'Courier New': 'Courier New',
};

const _tamanhos = {
  'Padrão': '0', '8': '8', '9': '9', '10': '10', '10.5': '10.5', '11': '11', '12': '12', '14': '14', '16': '16',
  '18': '18', '20': '20', '24': '24', '28': '28', '32': '32', '36': '36', '48': '48', '72': '72',
};

const _cores = [Color(0xFF1E88E5), Color(0xFFD81B60), Color(0xFF43A047), Color(0xFF8E24AA), Color(0xFFF4511E), Color(0xFF00897B)];

/// Cor fixa por autor (a mesma em todo aparelho).
Color corDoAutor(String autor) => _cores[autor.codeUnits.fold(0, (a, b) => (a * 31 + b) & 0x7fffffff) % _cores.length];

/// Trecho com revisão (inserção ou exclusão) de um autor, em posições do documento.
class Revisao {
  Revisao(this.insercao, this.marca, this.inicio, this.fim, this.texto);

  final bool insercao;
  final String marca;
  final int inicio;
  final int fim;
  final String texto;

  String get autor => lerMarca(marca).autor;
  DateTime? get data => lerMarca(marca).data;
}

/// Revisões do delta, juntando trechos vizinhos do mesmo autor e tipo.
List<Revisao> revisoesDo(List<Operation> ops) {
  final r = <Revisao>[];
  var pos = 0;
  for (final op in ops) {
    final n = op.length ?? 0;
    final texto = op.data is String ? op.data as String : '';
    for (final (chave, insercao) in [(atributoInsercao, true), (atributoExclusao, false)]) {
      final marca = op.attributes?[chave];
      if (marca is! String) continue;
      final ultima = r.lastOrNull;
      if (ultima != null && ultima.insercao == insercao && ultima.marca == marca && ultima.fim == pos) {
        r[r.length - 1] = Revisao(insercao, marca, ultima.inicio, pos + n, ultima.texto + texto);
      } else {
        r.add(Revisao(insercao, marca, pos, pos + n, texto));
      }
    }
    pos += n;
  }
  return r;
}

/// Editor de DOCX no estilo Word: fonte, tamanho, cor, realce, títulos, listas, alinhamento,
/// recuo, links; "Controlar alterações" (o que eu escrevo/apago fica marcado com meu nome, como o
/// orientador fez no original), painel de revisões (aceitar/rejeitar por autor) e de comentários,
/// ortografia e reescrita pelo Claude Code (viram sugestões rastreadas) e exportação.
class DocumentoTela extends StatefulWidget {
  const DocumentoTela({super.key, required this.api, required this.arquivo});

  final ApiArquivos api;
  final Arquivo arquivo;

  @override
  State<DocumentoTela> createState() => _DocumentoTelaState();
}

enum _Painel { revisoes, comentarios }

class _DocumentoTelaState extends State<DocumentoTela> {
  late final Future<void> _carga = _ler();
  DocumentoDocx? _docx;
  QuillController? _c;
  StreamSubscription<dynamic>? _mudancas;
  List<Comentario> _comentarios = [];
  bool _revisor = false;
  bool _sujo = false;
  bool _salvando = false;
  bool _avisosAceitos = false;
  bool _aplicando = false;
  String _autor = 'Eu';
  String? _filtroAutor;
  _Painel? _painel;
  final _andaime = GlobalKey<ScaffoldState>();
  final _foco = FocusNode(debugLabel: 'documento');
  final _rolagem = ScrollController();

  QuillController get c => _c!;

  @override
  void dispose() {
    _mudancas?.cancel();
    _c?.dispose();
    _foco.dispose();
    _rolagem.dispose();
    super.dispose();
  }

  Future<void> _ler() async {
    final arm = await Armazem.abrir('preferencias');
    final salvo = await arm.lerJson('editor/autor.json');
    if (salvo is String && salvo.trim().isNotEmpty) _autor = salvo;
    final id = widget.arquivo.id;
    final bytes = await widget.api.offline.original(id) ?? await widget.api.original(id);
    final docx = DocumentoDocx.ler(bytes);
    final controle = QuillController(
      document: Document.fromJson(docx.delta),
      selection: const TextSelection.collapsed(offset: 0),
    );
    controle.onReplaceText = _substituir;
    _mudancas = controle.document.changes.listen((_) {
      if (mounted) setState(() => _sujo = true);
    });
    _docx = docx;
    _c = controle;
    _comentarios = [...docx.comentarios];
    _revisor = docx.rastreando;
    // Revisões e comentários que vieram no arquivo (do orientador) abrem o painel.
    if (revisoesDo(controle.document.toDelta().toList()).isNotEmpty) {
      _painel = _Painel.revisoes;
    } else if (_comentarios.isNotEmpty) {
      _painel = _Painel.comentarios;
    }
  }

  // ---------------------------------------------------------------- revisão (controle de alterações)

  String _marca([String? autor]) => marcaRevisao(autor ?? _autor, DateTime.now());

  Attribute<String?> _attr(String chave, String? valor) => Attribute(chave, AttributeScope.inline, valor);

  void _semMarcas(int inicio, int n) {
    c.formatText(inicio, n, _attr(atributoInsercao, null));
    c.formatText(inicio, n, _attr(atributoExclusao, null));
  }

  void _aplicar(void Function() edicao) {
    _aplicando = true;
    try {
      edicao();
    } finally {
      _aplicando = false;
    }
  }

  /// Toda digitação/colagem passa aqui. Com o revisor ligado, o texto novo fica marcado com meu
  /// nome e o apagado vira exclusão rastreada (tachado) em vez de sumir.
  bool _substituir(int index, int len, Object? data) {
    if (_aplicando || data is! String) return true;
    _aplicar(() {
      if (!_revisor) {
        c.replaceText(index, len, data, TextSelection.collapsed(offset: index + data.length));
        // Texto novo não herda a marca de revisão do vizinho.
        if (data.isNotEmpty) _semMarcas(index, data.length);
        return;
      }
      _editarRastreado(index, len, data, _marca());
      c.updateSelection(TextSelection.collapsed(offset: index + data.length), ChangeSource.local);
    });
    return false;
  }

  /// Troca [len] caracteres em [index] por [texto] como revisão de [marca] (sem mexer na seleção).
  void _editarRastreado(int index, int len, String texto, String marca) {
    if (texto.isNotEmpty) {
      c.replaceText(index, 0, texto, null);
      _semMarcas(index, texto.length);
      c.formatText(index, texto.length, _attr(atributoInsercao, marca));
    }
    if (len > 0) _marcarExclusao(index + texto.length, len, marca);
  }

  void _marcarExclusao(int inicio, int len, String marca) {
    final autor = lerMarca(marca).autor;
    final ops = c.document.toDelta().slice(inicio, inicio + len).toList();
    // Backspace no começo da linha junta os parágrafos (a quebra não fica rastreada).
    if (len == 1 && ops.length == 1 && ops.first.data == '\n') {
      c.replaceText(inicio, 1, '', null);
      return;
    }
    // De trás para frente: apagar de verdade não desloca o que ainda falta.
    var fim = inicio + len;
    for (final op in ops.reversed) {
      final n = op.length ?? 0;
      final ini = fim - n;
      fim = ini;
      final dado = op.data;
      if (dado is! String) continue;
      final ins = op.attributes?[atributoInsercao];
      final jaExcluido = op.attributes?[atributoExclusao] != null;
      // Partes sem quebra de linha: as quebras ficam (Quill não marca formatação de linha no '\n').
      var p = n;
      for (final pedaco in dado.split('\n').reversed) {
        final a = p - pedaco.length;
        if (pedaco.isNotEmpty) {
          if (ins is String && lerMarca(ins).autor == autor) {
            c.replaceText(ini + a, pedaco.length, '', null); // apagar o que eu mesmo inseri não deixa rastro
          } else if (!jaExcluido) {
            c.formatText(ini + a, pedaco.length, _attr(atributoExclusao, marca));
          }
        }
        p = a - 1;
      }
    }
  }

  void _resolver(Iterable<Revisao> revisoes, {required bool aceitar}) {
    _aplicar(() {
      // De trás para frente, para as posições continuarem valendo.
      for (final r in revisoes.toList().reversed) {
        final remover = r.insercao != aceitar;
        if (remover) {
          c.replaceText(r.inicio, r.fim - r.inicio, '', null);
        } else {
          c.formatText(r.inicio, r.fim - r.inicio, _attr(r.insercao ? atributoInsercao : atributoExclusao, null));
        }
      }
    });
    setState(() {});
  }

  void _irPara(int inicio, int fim) {
    c.updateSelection(TextSelection(baseOffset: inicio, extentOffset: fim), ChangeSource.local);
    _foco.requestFocus();
  }

  // ---------------------------------------------------------------- comentários

  /// (início, fim) de cada trecho marcado com o comentário [id].
  List<(int, int)> _trechosDo(String id) {
    final r = <(int, int)>[];
    var pos = 0;
    for (final op in c.document.toDelta().toList()) {
      final n = op.length ?? 0;
      if (idsComentario(op.attributes?[atributoComentario]).contains(id)) {
        if (r.isNotEmpty && r.last.$2 == pos) {
          r[r.length - 1] = (r.last.$1, pos + n);
        } else {
          r.add((pos, pos + n));
        }
      }
      pos += n;
    }
    return r;
  }

  /// Junta/tira [id] da lista de comentários de cada pedaço entre [inicio] e [fim].
  void _marcarComentario(int inicio, int fim, String id, {required bool incluir}) {
    _aplicar(() {
      var pos = inicio;
      for (final op in c.document.toDelta().slice(inicio, fim).toList()) {
        final n = op.length ?? 0;
        final ids = idsComentario(op.attributes?[atributoComentario]).toSet();
        incluir ? ids.add(id) : ids.remove(id);
        c.formatText(pos, n, _attr(atributoComentario, ids.isEmpty ? null : (ids.toList()..sort()).join(',')));
        pos += n;
      }
    });
  }

  String _novoId() =>
      '${_comentarios.map((c) => int.tryParse(c.id) ?? 0).fold(-1, (a, b) => a > b ? a : b) + 1}';

  Future<String?> _pedirTexto(String titulo, {String inicial = ''}) {
    final campo = TextEditingController(text: inicial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(titulo),
        content: SizedBox(
          width: 420,
          child: TextField(controller: campo, autofocus: true, minLines: 3, maxLines: 8),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, campo.text.trim()), child: const Text('OK')),
        ],
      ),
    ).whenComplete(campo.dispose);
  }

  Future<void> _comentar({String? responderA}) async {
    final sel = c.selection;
    final trechos = responderA == null ? [(sel.start, sel.end)] : _trechosDo(responderA);
    if (trechos.isEmpty || trechos.first.$1 == trechos.first.$2) {
      return avisar(context, 'Selecione o trecho a comentar.');
    }
    final texto = await _pedirTexto(responderA == null ? 'Novo comentário' : 'Responder');
    if (texto == null || texto.isEmpty) return;
    final id = _novoId();
    final anterior = responderA == null ? null : _comentarios.firstWhere((x) => x.id == responderA);
    setState(() {
      _comentarios.add(Comentario(id: id, autor: _autor, texto: anterior == null ? texto : '↳ ${anterior.autor}: $texto'));
      _painel = _Painel.comentarios;
      _sujo = true;
    });
    for (final (i, f) in trechos) {
      _marcarComentario(i, f, id, incluir: true);
    }
  }

  void _excluirComentario(Comentario x) {
    for (final (i, f) in _trechosDo(x.id).reversed) {
      _marcarComentario(i, f, x.id, incluir: false);
    }
    setState(() {
      _comentarios.remove(x);
      _sujo = true;
    });
  }

  Future<void> _editarComentario(Comentario x) async {
    final texto = await _pedirTexto('Editar comentário', inicial: x.texto);
    if (texto == null || texto.isEmpty) return;
    setState(() {
      _comentarios[_comentarios.indexOf(x)] = x.comTexto(texto);
      _sujo = true;
    });
  }

  // ---------------------------------------------------------------- Claude

  /// Ortografia e gramática pelo Claude Code: cada sugestão aceita entra como revisão do
  /// "Revisor (Claude)", para aceitar/rejeitar no painel como as do orientador.
  Future<void> _ortografia() async {
    final sel = c.selection;
    final inicio = sel.isCollapsed ? 0 : sel.start;
    final texto = c.document.toPlainText().substring(inicio, sel.isCollapsed ? null : sel.end);
    if (texto.trim().isEmpty) return;
    if (texto.length > 60000) {
      return avisar(context, 'Texto grande demais para uma revisão: selecione uma parte (até 60 mil caracteres).');
    }
    final Map<String, dynamic> r;
    try {
      r = await _comEspera(
        'Revisando ortografia e gramática pelo Claude…',
        widget.api.reescrever(trecho: texto, objetivo: 'gramatica', arquivoId: widget.arquivo.id),
      );
    } on ApiErro catch (e) {
      if (mounted) avisar(context, 'Não consegui revisar: ${e.mensagem}');
      return;
    }
    final mudancas = [
      for (final m in (r['mudancas'] as List? ?? const []).cast<Map<String, dynamic>>())
        if ((m['antes'] as String? ?? '').isNotEmpty && m['antes'] != m['depois']) m,
    ];
    if (!mounted) return;
    if (mudancas.isEmpty) return avisar(context, 'Nenhum erro encontrado.');
    final escolhidas = await _escolherSugestoes(mudancas);
    if (escolhidas == null || escolhidas.isEmpty) return;
    var aplicadas = 0;
    _aplicar(() {
      // Do fim para o começo, procurando cada "antes" a partir do trecho revisado.
      final plano = c.document.toPlainText();
      final posicoes = <(int, Map<String, dynamic>)>[];
      var busca = inicio;
      for (final m in escolhidas) {
        final i = plano.indexOf(m['antes'] as String, busca);
        if (i < 0) continue;
        posicoes.add((i, m));
        busca = i + (m['antes'] as String).length;
      }
      for (final (i, m) in posicoes.reversed) {
        _editarRastreado(i, (m['antes'] as String).length, m['depois'] as String? ?? '', _marca(autorRevisorClaude));
        aplicadas++;
      }
    });
    setState(() => _painel = _Painel.revisoes);
    if (mounted) avisar(context, '$aplicadas sugestões entraram como revisões do $autorRevisorClaude.');
  }

  /// Espera [tarefa] com um aviso modal na frente (a revisão leva alguns segundos).
  Future<T> _comEspera<T>(String mensagem, Future<T> tarefa) async {
    final navegador = Navigator.of(context);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          content: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 16),
              Expanded(child: Text(mensagem)),
            ],
          ),
        ),
      ),
    );
    try {
      return await tarefa;
    } finally {
      navegador.pop();
    }
  }

  Future<List<Map<String, dynamic>>?> _escolherSugestoes(List<Map<String, dynamic>> mudancas) {
    final marcadas = List.filled(mudancas.length, true);
    return showDialog<List<Map<String, dynamic>>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text('${mudancas.length} sugestões'),
          content: SizedBox(
            width: 560,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (var i = 0; i < mudancas.length; i++)
                  CheckboxListTile(
                    value: marcadas[i],
                    onChanged: (v) => set(() => marcadas[i] = v ?? false),
                    title: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: mudancas[i]['antes'] as String,
                            style: const TextStyle(decoration: TextDecoration.lineThrough, color: Colors.redAccent),
                          ),
                          const TextSpan(text: '  →  '),
                          TextSpan(text: mudancas[i]['depois'] as String? ?? '', style: const TextStyle(color: Colors.green)),
                        ],
                      ),
                    ),
                    subtitle: Text(mudancas[i]['motivo'] as String? ?? ''),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, [
                for (var i = 0; i < mudancas.length; i++)
                  if (marcadas[i]) mudancas[i],
              ]),
              child: const Text('Aplicar como revisões'),
            ),
          ],
        ),
      ),
    );
  }

  /// Reescreve a seleção pelo Claude; o texto aceito substitui o trecho como revisão rastreada.
  Future<void> _reescrever() async {
    final sel = c.selection;
    if (sel.isCollapsed) return avisar(context, 'Selecione o trecho a reescrever.');
    final trecho = c.document.toPlainText().substring(sel.start, sel.end);
    final novo = await reescreverComClaude(
      context,
      widget.api,
      trecho: trecho,
      arquivoId: widget.arquivo.id,
      titulo: widget.arquivo.titulo,
    );
    if (novo == null || novo == trecho) return;
    _aplicar(() => _editarRastreado(sel.start, sel.end - sel.start, novo, _marca('Claude')));
    setState(() => _painel = _Painel.revisoes);
  }

  // ---------------------------------------------------------------- salvar e exportar

  List<Map<String, dynamic>> get _delta => [...c.document.toDelta().toJson().cast<Map<String, dynamic>>()];

  Future<bool> _salvar() async {
    final docx = _docx!;
    if (docx.avisos.isNotEmpty && !_avisosAceitos) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Salvar daqui perde partes do arquivo'),
          content: Text(
            'Este editor não preserva: ${docx.avisos.join(', ')}.\n\n'
            'Para manter tudo, use "Editar no Collabora" ou "Abrir com…" (LibreOffice/WordCraft).',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Salvar assim')),
          ],
        ),
      );
      if (ok != true) return false;
      _avisosAceitos = true;
    }
    setState(() => _salvando = true);
    try {
      final bytes = docx.gravar(_delta, comentarios: _comentarios, rastrear: _revisor);
      final novo = await widget.api.offline.salvarOriginal(widget.arquivo, bytes);
      if (mounted) {
        setState(() => _sujo = false);
        avisar(context, novo == null ? 'Sem conexão: salvo no aparelho; sobe quando a conexão voltar.' : 'Salvo.');
      }
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
    if (mounted) await exportarArquivo(context, widget.api, widget.arquivo, markdown: deltaParaMarkdown(_delta));
  }

  Future<void> _trocarAutor() async {
    final nome = await _pedirTexto('Seu nome nas revisões e comentários', inicial: _autor);
    if (nome == null || nome.isEmpty) return;
    setState(() => _autor = nome);
    await (await Armazem.abrir('preferencias')).gravarJson('editor/autor.json', nome);
  }

  // ---------------------------------------------------------------- telas

  TextStyle _estiloRevisao(Attribute<dynamic> a) {
    final v = a.value;
    if (v is! String) return const TextStyle();
    switch (a.key) {
      case atributoInsercao:
        final cor = corDoAutor(lerMarca(v).autor);
        return TextStyle(color: cor, decoration: TextDecoration.underline, decorationColor: cor);
      case atributoExclusao:
        final cor = corDoAutor(lerMarca(v).autor);
        return TextStyle(color: cor.withValues(alpha: 0.75), decoration: TextDecoration.lineThrough, decorationColor: cor);
      case atributoComentario:
        return TextStyle(backgroundColor: Colors.amber.withValues(alpha: 0.35));
    }
    return const TextStyle();
  }

  @override
  Widget build(BuildContext context) => GuardaSaida(
    sujo: _sujo,
    // O Quill traz os próprios textos da barra; o app não registra os delegates dele.
    child: Localizations.override(
      context: context,
      delegates: const [FlutterQuillLocalizations.delegate],
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
            if (_sujo && !_salvando) _salvar();
          },
        },
        child: Scaffold(
          key: _andaime,
          appBar: AppBar(
            title: Text(widget.arquivo.titulo, maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: [
              if (_c != null) ..._acoes(),
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
          endDrawer: _c != null && !_largo(context) ? Drawer(width: 360, child: SafeArea(child: _conteudoPainel())) : null,
          body: FutureBuilder(
            future: _carga,
            builder: (context, s) {
              if (s.hasError) {
                final e = s.error;
                final msg = e is ApiErro ? e.mensagem : (e is DocxInvalido ? e.mensagem : '$e');
                return Center(child: Text('Não consegui abrir: $msg'));
              }
              if (s.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
              return _corpo(context);
            },
          ),
        ),
      ),
    ),
  );

  bool _largo(BuildContext context) => MediaQuery.sizeOf(context).width >= 1000;

  List<Widget> _acoes() {
    final revisoes = revisoesDo(c.document.toDelta().toList());
    return [
      Tooltip(
        message: 'Controlar alterações: o que você escreve/apaga fica marcado com "$_autor"',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.track_changes, size: 18),
            const SizedBox(width: 4),
            const Text('Revisor'),
            Switch(value: _revisor, onChanged: (v) => setState(() {
              _revisor = v;
              _sujo = true;
            })),
          ],
        ),
      ),
      IconButton(
        tooltip: 'Revisões (${revisoes.length})',
        onPressed: () => _abrirPainel(_Painel.revisoes),
        icon: Badge.count(count: revisoes.length, isLabelVisible: revisoes.isNotEmpty, child: const Icon(Icons.rule)),
      ),
      IconButton(
        tooltip: 'Comentários (${_comentarios.length})',
        onPressed: () => _abrirPainel(_Painel.comentarios),
        icon: Badge.count(
          count: _comentarios.length,
          isLabelVisible: _comentarios.isNotEmpty,
          child: const Icon(Icons.comment_outlined),
        ),
      ),
      IconButton(tooltip: 'Comentar a seleção', onPressed: _comentar, icon: const Icon(Icons.add_comment_outlined)),
      IconButton(tooltip: 'Ortografia e gramática (Claude)', onPressed: _ortografia, icon: const Icon(Icons.spellcheck)),
      IconButton(tooltip: 'Reescrever a seleção (Claude)', onPressed: _reescrever, icon: const Icon(Icons.auto_fix_high)),
      IconButton(tooltip: 'Exportar', onPressed: _exportar, icon: const Icon(Icons.ios_share)),
      IconButton(tooltip: 'Seu nome: $_autor', onPressed: _trocarAutor, icon: const Icon(Icons.badge_outlined)),
    ];
  }

  void _abrirPainel(_Painel p) {
    if (_largo(context)) {
      setState(() => _painel = _painel == p ? null : p);
    } else {
      setState(() => _painel = p);
      _andaime.currentState?.openEndDrawer();
    }
  }

  Widget _corpo(BuildContext context) {
    final docx = _docx!;
    final largo = _largo(context);
    final plano = c.document.toPlainText();
    final palavras = RegExp(r'\S+').allMatches(plano).length;
    return Column(
      children: [
        QuillSimpleToolbar(
          controller: c,
          config: const QuillSimpleToolbarConfig(
            multiRowsDisplay: false,
            showFontFamily: true,
            showFontSize: true,
            showSubscript: true,
            showSuperscript: true,
            showCodeBlock: false,
            showInlineCode: false,
            showSearchButton: true,
            buttonOptions: QuillSimpleToolbarButtonOptions(
              fontFamily: QuillToolbarFontFamilyButtonOptions(items: _fontes),
              fontSize: QuillToolbarFontSizeButtonOptions(items: _tamanhos),
            ),
          ),
        ),
        if (docx.avisos.isNotEmpty)
          Material(
            color: Theme.of(context).colorScheme.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(
                'Não editável aqui (some ao salvar): ${docx.avisos.join(', ')}. Para isso, "Editar no Collabora".',
                style: TextStyle(color: Theme.of(context).colorScheme.onTertiaryContainer),
              ),
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _pagina(context)),
              if (largo && _painel != null) ...[
                const VerticalDivider(width: 1),
                SizedBox(width: 360, child: _conteudoPainel()),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              Text('$palavras palavras · ${plano.length - 1} caracteres', style: Theme.of(context).textTheme.bodySmall),
              const Spacer(),
              if (_revisor)
                Text(
                  'Controlar alterações ligado ($_autor)',
                  style: TextStyle(color: corDoAutor(_autor), fontSize: 12),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// Folha clara centralizada, como página de editor de texto.
  Widget _pagina(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerLowest,
    child: Theme(
      data: ThemeData(brightness: Brightness.light, colorSchemeSeed: Colors.blue),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Card(
            margin: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
            color: Colors.white,
            elevation: 2,
            child: QuillEditor(
              controller: c,
              focusNode: _foco,
              scrollController: _rolagem,
              config: QuillEditorConfig(
                padding: const EdgeInsets.fromLTRB(72, 56, 72, 56),
                placeholder: 'Escreva aqui…',
                customStyleBuilder: _estiloRevisao,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _conteudoPainel() => switch (_painel ?? _Painel.revisoes) {
    _Painel.revisoes => _painelRevisoes(),
    _Painel.comentarios => _painelComentarios(),
  };

  Widget _cabecalho(String titulo, List<Widget> acoes) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
    child: Row(
      children: [
        Expanded(child: Text(titulo, style: Theme.of(context).textTheme.titleSmall)),
        ...acoes,
      ],
    ),
  );

  Widget _painelRevisoes() {
    final todas = revisoesDo(c.document.toDelta().toList());
    final autores = {for (final r in todas) r.autor}.toList()..sort();
    final filtro = autores.contains(_filtroAutor) ? _filtroAutor : null;
    final lista = filtro == null ? todas : todas.where((r) => r.autor == filtro).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _cabecalho('Revisões (${lista.length})', [
          TextButton(onPressed: lista.isEmpty ? null : () => _resolver(lista, aceitar: true), child: const Text('Aceitar todas')),
          TextButton(onPressed: lista.isEmpty ? null : () => _resolver(lista, aceitar: false), child: const Text('Rejeitar todas')),
        ]),
        if (autores.length > 1)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 6,
              children: [
                ChoiceChip(label: const Text('Todos'), selected: filtro == null, onSelected: (_) => setState(() => _filtroAutor = null)),
                for (final a in autores)
                  ChoiceChip(
                    avatar: CircleAvatar(backgroundColor: corDoAutor(a), radius: 6),
                    label: Text(a),
                    selected: filtro == a,
                    onSelected: (_) => setState(() => _filtroAutor = a),
                  ),
              ],
            ),
          ),
        if (lista.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Sem revisões. Ligue "Revisor" para marcar o que você mudar.'),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: lista.length,
            itemBuilder: (context, i) {
              final r = lista[i];
              final data = r.data;
              return ListTile(
                dense: true,
                onTap: () => _irPara(r.inicio, r.fim),
                leading: Icon(r.insercao ? Icons.add_circle_outline : Icons.remove_circle_outline, color: corDoAutor(r.autor)),
                title: Text(
                  r.texto.trim().isEmpty ? '(quebra/espaço)' : r.texto.trim(),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(decoration: r.insercao ? null : TextDecoration.lineThrough),
                ),
                subtitle: Text(
                  '${r.insercao ? 'Inseriu' : 'Excluiu'} · ${r.autor}${data == null ? '' : ' · ${_dataCurta(data)}'}',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(tooltip: 'Aceitar', onPressed: () => _resolver([r], aceitar: true), icon: const Icon(Icons.check)),
                    IconButton(tooltip: 'Rejeitar', onPressed: () => _resolver([r], aceitar: false), icon: const Icon(Icons.close)),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _painelComentarios() {
    final plano = c.document.toPlainText();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _cabecalho('Comentários (${_comentarios.length})', [
          TextButton.icon(onPressed: _comentar, icon: const Icon(Icons.add_comment_outlined), label: const Text('Novo')),
        ]),
        if (_comentarios.isEmpty)
          const Padding(padding: EdgeInsets.all(16), child: Text('Selecione um trecho e toque em "Novo".')),
        Expanded(
          child: ListView.builder(
            itemCount: _comentarios.length,
            itemBuilder: (context, i) {
              final x = _comentarios[i];
              final trechos = _trechosDo(x.id);
              final citado = trechos.map((t) => plano.substring(t.$1, t.$2.clamp(t.$1, plano.length))).join(' … ').trim();
              return Card(
                margin: const EdgeInsets.fromLTRB(10, 4, 10, 4),
                child: InkWell(
                  onTap: trechos.isEmpty ? null : () => _irPara(trechos.first.$1, trechos.last.$2),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            CircleAvatar(
                              radius: 12,
                              backgroundColor: corDoAutor(x.autor),
                              child: Text(x.iniciais, style: const TextStyle(fontSize: 10, color: Colors.white)),
                            ),
                            const SizedBox(width: 8),
                            Expanded(child: Text('${x.autor} · ${_dataCurta(x.data)}', style: Theme.of(context).textTheme.labelMedium)),
                          ],
                        ),
                        if (citado.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              '"$citado"',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontStyle: FontStyle.italic),
                            ),
                          ),
                        Padding(padding: const EdgeInsets.only(top: 6), child: Text(x.texto)),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (trechos.isNotEmpty)
                              TextButton(onPressed: () => _comentar(responderA: x.id), child: const Text('Responder')),
                            IconButton(tooltip: 'Editar', onPressed: () => _editarComentario(x), icon: const Icon(Icons.edit_outlined, size: 18)),
                            IconButton(
                              tooltip: 'Resolver (excluir)',
                              onPressed: () => _excluirComentario(x),
                              icon: const Icon(Icons.done_all, size: 18),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

String _dataCurta(DateTime d) {
  final l = d.toLocal();
  String z(int n) => n.toString().padLeft(2, '0');
  return '${z(l.day)}/${z(l.month)}/${l.year} ${z(l.hour)}:${z(l.minute)}';
}
