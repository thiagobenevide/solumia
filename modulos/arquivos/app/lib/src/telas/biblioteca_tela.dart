import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_arquivos.dart';
import '../editores/apresentacao_tela.dart';
import '../editores/collabora_tela.dart';
import '../editores/documento_tela.dart';
import '../editores/exportar.dart';
import '../editores/planilha_tela.dart';
import '../editores/reescrita.dart';
import '../externo/externo.dart';
import '../leitor/dados_tela.dart';
import '../leitor/leitor_tela.dart';
import '../modelos.dart';
import '../offline.dart';
import 'acoes_destaque.dart';
import 'destaques_aba.dart';

const extensoesAceitas = [
  'pdf',
  'docx',
  'doc',
  'odt',
  'rtf',
  'pptx',
  'ppt',
  'odp',
  'csv',
  'xls',
  'xlsx',
  'ods',
  'ofx',
  'qfx',
  'txt',
  'xml',
];

bool temEditor(Arquivo a) => const {'docx', 'xlsx', 'pptx'}.contains(a.extensao);

/// Editor próprio por extensão (Word, Excel e PowerPoint do app); o resto só no leitor.
Widget Function(BuildContext)? editorDe(ApiArquivos api, Arquivo a) => switch (a.extensao) {
  'docx' => (_) => DocumentoTela(api: api, arquivo: a),
  'xlsx' => (_) => PlanilhaTela(api: api, arquivo: a),
  'pptx' => (_) => ApresentacaoTela(api: api, arquivo: a),
  _ => null,
};

/// Abre o visualizador do formato: DOCX/XLSX/PPTX no editor, CSV em tabela e XML em árvore (leem o
/// original); o resto no leitor de PDF (avisa se ainda está convertendo ou se a conversão falhou).
/// [ler] força o leitor de PDF (para anotar à tinta).
Future<void> abrirArquivo(BuildContext context, ApiArquivos api, Arquivo a, {int pagina = 1, bool ler = false}) async {
  final editor = ler ? null : editorDe(api, a);
  if (editor != null) return abrirTela<void>(context, editor);
  switch (a.formato) {
    case Formato.csv:
      return abrirTela<void>(context, (_) => CsvTela(api: api, arquivo: a));
    case Formato.xml:
      return abrirTela<void>(context, (_) => XmlTela(api: api, arquivo: a));
    default:
  }
  if (a.status == 'convertendo') return avisar(context, 'Ainda convertendo para PDF; já fica pronto.');
  if (a.status == 'erro') return avisar(context, 'A conversão falhou: ${a.erro ?? 'erro'}');
  await abrirTela<void>(context, (_) => LeitorTela(api: api, arquivo: a, paginaInicial: pagina));
}

/// Escolhe um programa instalado e abre o original nele; o que for salvo lá sobe sozinho
/// (sem conexão, fica na fila do aparelho). A grade atualiza pela sondagem de mudanças.
Future<void> abrirComEditor(BuildContext context, ApiArquivos api, Arquivo a) async {
  final editores = editoresPara(a);
  final escolhido = await showDialog<Editor>(
    context: context,
    builder: (c) => SimpleDialog(
      title: Text('Abrir "${a.nomeOriginal}" com'),
      children: [
        for (final e in editores) SimpleDialogOption(onPressed: () => Navigator.pop(c, e), child: Text(e.nome)),
      ],
    ),
  );
  if (escolhido == null) return;
  try {
    final bytes =
        await api.offline.original(a.id) ??
        (a.tipo == 'pdf' ? await api.offline.pdf(a.id) : null) ??
        await api.original(a.id);
    await abrirFora(escolhido, a, bytes, (novo) => api.offline.salvarOriginal(a, novo));
    if (context.mounted) avisar(context, 'Aberto no ${escolhido.nome}; ao salvar lá, a versão sobe sozinha.');
  } on ApiErro catch (e) {
    if (context.mounted) avisar(context, 'Não consegui abrir: ${e.mensagem}');
  }
}

class BibliotecaTela extends StatelessWidget {
  const BibliotecaTela({super.key, required this.api});

  final ApiArquivos api;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Column(
      children: [
        const TabBar(
          tabs: [
            Tab(icon: Icon(Icons.folder_open_outlined), text: 'Arquivos'),
            Tab(icon: Icon(Icons.border_color_outlined), text: 'Destaques'),
          ],
        ),
        Expanded(
          child: TabBarView(
            children: [
              _ArquivosAba(api: api),
              DestaquesAba(api: api),
            ],
          ),
        ),
      ],
    ),
  );
}

class _ArquivosAba extends StatefulWidget {
  const _ArquivosAba({required this.api});

  final ApiArquivos api;

  @override
  State<_ArquivosAba> createState() => _ArquivosAbaState();
}

class _ArquivosAbaState extends State<_ArquivosAba> {
  List<Arquivo>? _arquivos;
  List<String> _pastas = [];
  String? _pasta;

  /// Filtro por formato (PDF, DOCX, PPTX, CSV, XML); `null` mostra todos.
  Formato? _formato;
  String _busca = '';
  Object? _erro;
  int _seq = -1;
  Timer? _sondagem;
  Timer? _digitando;
  String? _enviando;

  /// Sem conexão: a grade mostra só os arquivos baixados no aparelho.
  bool _offline = false;
  Set<String> _baixados = {};
  int _pendencias = 0;
  bool _sincronizando = false;

  /// Seleção para ações em lote (baixar, duplicar, renomear, excluir); vale só o que está visível.
  bool _selecionando = false;
  final Set<String> _selecionados = {};

  AcervoOffline get _acervo => widget.api.offline;

  List<Arquivo>? get _visiveis {
    final todos = _arquivos;
    return todos == null || _formato == null
        ? todos
        : [
            for (final a in todos)
              if (a.formato == _formato) a,
          ];
  }

  List<Arquivo> get _escolhidos => [
    for (final a in _visiveis ?? const <Arquivo>[])
      if (_selecionados.contains(a.id)) a,
  ];

  void _alternar(Arquivo a) => setState(() {
    _selecionando = true;
    if (!_selecionados.remove(a.id)) _selecionados.add(a.id);
  });

  void _sairDaSelecao() => setState(() {
    _selecionando = false;
    _selecionados.clear();
  });

  @override
  void initState() {
    super.initState();
    _carregar();
    // O que mudar em outro aparelho (novo arquivo, exclusão, conversão pronta) aparece aqui.
    _sondagem = Timer.periodic(const Duration(seconds: 4), (_) => _verificarMudancas());
  }

  @override
  void dispose() {
    _sondagem?.cancel();
    _digitando?.cancel();
    super.dispose();
  }

  Future<void> _verificarMudancas() async {
    if (_offline || _pendencias > 0) return _carregar();
    try {
      final (seq, _) = await widget.api.mudancas(1 << 50);
      if (seq != _seq) await _carregar();
    } catch (_) {
      // Sem conexão: o próximo ciclo tenta de novo.
    }
  }

  Future<void> _carregar() async {
    try {
      final (seq, _) = await widget.api.mudancas(1 << 50);
      if (await _acervo.pendencias() > 0) await _sincronizar();
      final (arquivos, pastas) = await (widget.api.listar(q: _busca, pasta: _pasta), widget.api.pastas()).wait;
      final (baixados, pendencias) = await (_acervo.baixados(), _acervo.pendencias()).wait;
      if (!mounted) return;
      setState(() {
        _seq = seq;
        _arquivos = arquivos;
        _selecionados.retainAll({for (final a in arquivos) a.id});
        _pastas = pastas;
        _baixados = baixados;
        _pendencias = pendencias;
        _offline = false;
        _erro = null;
      });
    } catch (e) {
      if (semConexao(e)) return _carregarDoAparelho();
      if (mounted) setState(() => _erro = e is ParallelWaitError ? e.errors : e);
    }
  }

  /// Sem conexão: lista o que foi baixado, com a mesma busca e pasta.
  Future<void> _carregarDoAparelho() async {
    final (todos, pendencias) = await (_acervo.arquivos(), _acervo.pendencias()).wait;
    final termo = _busca.toLowerCase();
    if (!mounted) return;
    setState(() {
      _offline = true;
      _erro = null;
      _pendencias = pendencias;
      _baixados = {for (final a in todos) a.id};
      _pastas = {for (final a in todos) a.pasta}.where((p) => p.isNotEmpty).toList()..sort();
      _arquivos = [
        for (final a in todos)
          if ((_pasta == null || a.pasta == _pasta) &&
              [a.titulo, a.nomeOriginal, ...a.tags].any((t) => t.toLowerCase().contains(termo)))
            a,
      ];
    });
  }

  Future<void> _sincronizar() async {
    if (_sincronizando) return;
    _sincronizando = true;
    try {
      final avisos = await _acervo.sincronizar();
      if (avisos.isNotEmpty && mounted) avisar(context, 'Sincronizado, com avisos: ${avisos.join('; ')}');
    } finally {
      _sincronizando = false;
    }
  }

  /// Baixa para o aparelho todos os arquivos prontos da lista atual (busca e pasta valem).
  Future<void> _baixarListados() async {
    final faltam = [
      for (final a in _arquivos ?? const <Arquivo>[])
        if (a.pronto && !_baixados.contains(a.id)) a,
    ];
    if (faltam.isEmpty) return avisar(context, 'Tudo o que está listado já está no aparelho.');
    for (final (i, a) in faltam.indexed) {
      setState(() => _enviando = 'Baixando ${i + 1}/${faltam.length}');
      try {
        await _acervo.baixar(a);
      } on ApiErro catch (e) {
        if (mounted) avisar(context, '${a.titulo}: ${e.mensagem}');
        if (semConexao(e)) break;
      }
    }
    if (!mounted) return;
    setState(() => _enviando = null);
    await _carregar();
  }

  Future<void> _editar(Arquivo a, {String? titulo, String? pasta, List<String>? tags}) async {
    try {
      await widget.api.editar(a.id, titulo: titulo, pasta: pasta, tags: tags);
    } on ApiErro catch (e) {
      if (!semConexao(e)) rethrow;
      await _acervo.editar(a, titulo: titulo, pasta: pasta, tags: tags);
    }
  }

  Future<void> _adicionar() async {
    final escolhidos = await FilePicker.pickFiles(
      dialogTitle: 'Adicionar arquivos',
      type: FileType.custom,
      allowedExtensions: extensoesAceitas,
    );
    if (escolhidos.isEmpty || !mounted) return;
    final duplicados = <String>[];
    final guardados = <String>[];
    for (final (i, f) in escolhidos.indexed) {
      setState(() => _enviando = 'Enviando ${i + 1}/${escolhidos.length}: ${f.name}');
      final bytes = await f.xFile.readAsBytes();
      try {
        final (_, duplicado) = await widget.api.enviar(f.name, bytes, pasta: _pasta ?? '');
        if (duplicado) duplicados.add(f.name);
      } on ApiErro catch (e) {
        if (semConexao(e)) {
          await _acervo.enviar(f.name, bytes, pasta: _pasta ?? '');
          guardados.add(f.name);
        } else if (mounted) {
          avisar(context, '${f.name}: ${e.mensagem}');
        }
      }
    }
    if (!mounted) return;
    setState(() => _enviando = null);
    if (duplicados.isNotEmpty) avisar(context, 'Já estavam na biblioteca: ${duplicados.join(', ')}');
    if (guardados.isNotEmpty) avisar(context, 'Sem conexão: ${guardados.join(', ')} sobem quando a conexão voltar.');
    await _carregar();
  }

  Future<void> _acao(String acao, Arquivo a) async {
    try {
      switch (acao) {
        case 'renomear':
          final t = await pedirTexto(context, titulo: 'Renomear', inicial: a.titulo);
          if (t != null && t.trim().isNotEmpty) await _editar(a, titulo: t.trim());
        case 'pasta':
          final p = await pedirTexto(
            context,
            titulo: 'Mover para a pasta',
            inicial: a.pasta,
            rotulo: 'Pasta (vazio = sem pasta)',
          );
          if (p != null) await _editar(a, pasta: p.trim());
        case 'tags':
          final t = await pedirTexto(context, titulo: 'Tags (separadas por vírgula)', inicial: a.tags.join(', '));
          if (t != null) {
            await _editar(
              a,
              tags: [
                for (final x in t.split(','))
                  if (x.trim().isNotEmpty) x.trim(),
              ],
            );
          }
        case 'baixar':
          final bytes = await widget.api.original(a.id);
          final salvo = await FilePicker.saveFile(fileName: a.nomeOriginal, bytes: bytes);
          if (salvo != null && mounted) avisar(context, 'Salvo: ${a.nomeOriginal}');
        case 'offline':
          if (_baixados.contains(a.id)) {
            await _acervo.remover(a.id);
          } else {
            setState(() => _enviando = 'Baixando ${a.titulo}');
            try {
              await _acervo.baixar(a);
            } finally {
              if (mounted) setState(() => _enviando = null);
            }
          }
        case 'fora':
          await abrirComEditor(context, widget.api, a);
        case 'ler':
          await abrirArquivo(context, widget.api, a, ler: true);
        case 'exportar':
          await exportarArquivo(context, widget.api, a);
        case 'collabora':
          await abrirTela<void>(context, (_) => CollaboraTela(api: widget.api, arquivo: a));
        case 'claude':
          // Fora do editor não há onde aplicar: a sugestão aceita vai para a área de transferência.
          final texto = await reescreverComClaude(context, widget.api, arquivoId: a.id, titulo: a.titulo);
          if (texto != null) {
            await Clipboard.setData(ClipboardData(text: texto));
            if (mounted) avisar(context, 'Texto reescrito copiado; cole no documento.');
          }
        case 'converter':
          await widget.api.reconverter(a.id);
        case 'excluir':
          final ok = await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: Text('Excluir "${a.titulo}"?'),
              content: Text(
                'O arquivo e as anotações (${a.destaques} destaques) somem de todos os aparelhos. Não dá para desfazer.',
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
                FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Excluir')),
              ],
            ),
          );
          if (ok == true) await _excluir(a);
        case 'duplicar':
          await widget.api.duplicar(a.id);
      }
    } on ApiErro catch (e) {
      if (mounted) avisar(context, e.mensagem);
    }
    await _carregar();
  }

  Future<void> _excluir(Arquivo a) async {
    try {
      await widget.api.excluir(a.id);
      await _acervo.remover(a.id);
    } on ApiErro catch (e) {
      if (!semConexao(e)) rethrow;
      await _acervo.excluir(a.id);
    }
  }

  /// Ação sobre os selecionados; com um só, cai no menu do cartão (mesmos diálogos).
  Future<void> _lote(String acao) async {
    final escolhidos = _escolhidos;
    if (escolhidos.isEmpty) return avisar(context, 'Nenhum arquivo selecionado.');
    if (escolhidos.length == 1 && acao != 'excluir') return _acao(acao, escolhidos.single);
    final n = escolhidos.length;
    try {
      switch (acao) {
        case 'baixar':
          // Vários originais num ZIP só: um diálogo de salvar, igual em desktop, web e celular.
          final zip = Archive();
          final nomes = <String>{};
          for (final (i, a) in escolhidos.indexed) {
            setState(() => _enviando = 'Baixando ${i + 1}/$n');
            var nome = a.nomeOriginal;
            for (var k = 2; !nomes.add(nome); k++) {
              nome = '${a.titulo} ($k).${a.extensao}';
            }
            zip.addFile(ArchiveFile.bytes(nome, await widget.api.original(a.id)));
          }
          final salvo = await FilePicker.saveFile(fileName: 'arquivos.zip', bytes: ZipEncoder().encodeBytes(zip));
          if (salvo != null && mounted) avisar(context, '$n arquivos salvos em arquivos.zip');
          return;
        case 'duplicar':
          for (final (i, a) in escolhidos.indexed) {
            setState(() => _enviando = 'Duplicando ${i + 1}/$n');
            await widget.api.duplicar(a.id);
          }
        case 'renomear':
          final base = await pedirTexto(
            context,
            titulo: 'Renomear $n arquivos',
            rotulo: 'Nome (vira "Nome 1", "Nome 2"…)',
          );
          if (base == null || base.trim().isEmpty) return;
          for (final (i, a) in escolhidos.indexed) {
            await _editar(a, titulo: '${base.trim()} ${i + 1}');
          }
        case 'excluir':
          final destaques = escolhidos.fold(0, (s, a) => s + a.destaques);
          final ok = await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: Text(n == 1 ? 'Excluir "${escolhidos.single.titulo}"?' : 'Excluir $n arquivos?'),
              content: Text(
                'Os arquivos e as anotações ($destaques destaques) somem de todos os aparelhos. Não dá para desfazer.',
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
                FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Excluir')),
              ],
            ),
          );
          if (ok != true) return;
          for (final (i, a) in escolhidos.indexed) {
            setState(() => _enviando = 'Excluindo ${i + 1}/$n');
            await _excluir(a);
          }
      }
      if (mounted) _sairDaSelecao();
    } on ApiErro catch (e) {
      if (mounted) avisar(context, e.mensagem);
    } finally {
      if (mounted) setState(() => _enviando = null);
      if (acao != 'baixar') await _carregar();
    }
  }

  Widget _barraSelecao() {
    final visiveis = _visiveis ?? const <Arquivo>[];
    final todos = visiveis.isNotEmpty && visiveis.every((a) => _selecionados.contains(a.id));
    final ativo = _enviando == null && _selecionados.isNotEmpty;
    return Row(
      children: [
        IconButton(tooltip: 'Sair da seleção', icon: const Icon(Icons.close), onPressed: _sairDaSelecao),
        Text('${_escolhidos.length} selecionado(s)', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(width: 8),
        TextButton.icon(
          icon: Icon(todos ? Icons.deselect : Icons.select_all),
          label: Text(todos ? 'Limpar' : 'Selecionar todos (${visiveis.length})'),
          onPressed: () => setState(() {
            todos ? _selecionados.clear() : _selecionados.addAll(visiveis.map((a) => a.id));
          }),
        ),
        const Spacer(),
        IconButton(
          tooltip: 'Baixar (vários vão num ZIP)',
          icon: const Icon(Icons.download),
          onPressed: ativo && !_offline ? () => _lote('baixar') : null,
        ),
        IconButton(
          tooltip: 'Duplicar',
          icon: const Icon(Icons.copy_all_outlined),
          onPressed: ativo && !_offline ? () => _lote('duplicar') : null,
        ),
        IconButton(
          tooltip: 'Renomear',
          icon: const Icon(Icons.drive_file_rename_outline),
          onPressed: ativo ? () => _lote('renomear') : null,
        ),
        IconButton(
          tooltip: 'Excluir',
          icon: const Icon(Icons.delete_outline),
          onPressed: ativo ? () => _lote('excluir') : null,
        ),
      ],
    );
  }

  /// Documento, planilha ou apresentação em branco (gerado no servidor) e já aberto no editor.
  Future<void> _novo() async {
    final titulo = TextEditingController(text: 'Sem título');
    var tipo = 'documento';
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Novo arquivo'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'documento', icon: Icon(Icons.description_outlined), label: Text('Documento')),
                  ButtonSegment(value: 'planilha', icon: Icon(Icons.table_chart_outlined), label: Text('Planilha')),
                  ButtonSegment(value: 'apresentacao', icon: Icon(Icons.slideshow_outlined), label: Text('Apresentação')),
                ],
                selected: {tipo},
                onSelectionChanged: (s) => set(() => tipo = s.first),
              ),
              TextField(controller: titulo, autofocus: true, decoration: const InputDecoration(labelText: 'Título')),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Criar')),
          ],
        ),
      ),
    );
    final nome = titulo.text.trim();
    titulo.dispose();
    if (ok != true || !mounted) return;
    setState(() => _enviando = 'Criando…');
    try {
      final a = await widget.api.novo(tipo, nome, pasta: _pasta ?? '');
      await _carregar();
      if (mounted) await abrirArquivo(context, widget.api, a);
    } on ApiErro catch (e) {
      if (mounted) avisar(context, 'Não consegui criar: ${e.mensagem}');
    } finally {
      if (mounted) setState(() => _enviando = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final todos = _arquivos;
    final arquivos = _visiveis;
    final contagem = <Formato, int>{};
    for (final a in todos ?? const <Arquivo>[]) {
      contagem[a.formato] = (contagem[a.formato] ?? 0) + 1;
    }
    return Scaffold(
      floatingActionButton: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 12,
        children: [
          FloatingActionButton.extended(
            heroTag: 'novo',
            onPressed: _enviando == null ? _novo : null,
            icon: const Icon(Icons.note_add_outlined),
            label: const Text('Novo'),
          ),
          FloatingActionButton.extended(
            heroTag: 'adicionar',
            onPressed: _enviando == null ? _adicionar : null,
            icon: const Icon(Icons.upload_file),
            label: Text(_enviando ?? 'Adicionar'),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_selecionando)
            Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: _barraSelecao()),
          FiltrosRecolhiveis(
            chave: 'arquivos.biblioteca',
            resumo: [?_pasta, ?_formato?.rotulo, if (_busca.isNotEmpty) '"$_busca"'].join(' · '),
            children: [
          if (!_selecionando)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
                    spacing: 4,
                    children: [
                      Expanded(
                        child: TextField(
                          decoration: const InputDecoration(
                            prefixIcon: Icon(Icons.search),
                            hintText: 'Buscar por título, nome ou tag',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          onChanged: (v) {
                            _busca = v;
                            _digitando?.cancel();
                            _digitando = Timer(const Duration(milliseconds: 300), _carregar);
                          },
                        ),
                      ),
                      IconButton(
                        tooltip: 'Selecionar arquivos (ou segure/clique longo num cartão)',
                        icon: const Icon(Icons.checklist),
                        onPressed: () => setState(() => _selecionando = true),
                      ),
                      IconButton(
                        tooltip: 'Baixar para o aparelho todos os listados (para usar sem conexão)',
                        icon: const Icon(Icons.download_for_offline_outlined),
                        onPressed: _offline || _enviando != null ? null : _baixarListados,
                      ),
                    ],
                  ),
          ),
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final p in <String?>[null, ..._pastas])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(p ?? 'Todas'),
                      avatar: p == null ? null : const Icon(Icons.folder_outlined, size: 18),
                      selected: _pasta == p,
                      onSelected: (_) {
                        setState(() => _pasta = p);
                        _carregar();
                      },
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final f in <Formato?>[null, ...Formato.values])
                  if (f != Formato.outros || contagem.containsKey(f))
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: Text(f == null ? 'Todos (${todos?.length ?? 0})' : '${f.rotulo} (${contagem[f] ?? 0})'),
                        selected: _formato == f,
                        onSelected: (_) => setState(() => _formato = f),
                      ),
                    ),
              ],
            ),
          ),
            ],
          ),
          if (_offline || _pendencias > 0)
            MaterialBanner(
              leading: Icon(_offline ? Icons.cloud_off : Icons.cloud_sync_outlined),
              content: Text(
                [
                  if (_offline) 'Sem conexão: mostrando os arquivos baixados no aparelho.',
                  if (_pendencias > 0) '$_pendencias alteração(ões) esperando para subir.',
                ].join(' '),
              ),
              actions: [TextButton(onPressed: _carregar, child: const Text('Sincronizar'))],
            ),
          if (_erro != null)
            MaterialBanner(
              content: Text('Sem conexão com a API de arquivos: $_erro'),
              actions: [TextButton(onPressed: _carregar, child: const Text('Tentar de novo'))],
            ),
          Expanded(
            child: arquivos == null
                ? Center(child: _erro == null ? const CircularProgressIndicator() : const SizedBox())
                : arquivos.isEmpty
                ? Center(
                    child: Text(
                      _formato == null
                          ? 'Nenhum arquivo. Adicione PDF, DOCX, PPTX, CSV ou XML pelo botão abaixo.'
                          : 'Nenhum arquivo ${_formato!.rotulo} aqui.',
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _carregar,
                    child: GridView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 220,
                        childAspectRatio: 0.66,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                      ),
                      itemCount: arquivos.length,
                      itemBuilder: (context, i) => _CartaoArquivo(
                        api: widget.api,
                        arquivo: arquivos[i],
                        baixado: _baixados.contains(arquivos[i].id),
                        selecionando: _selecionando,
                        selecionado: _selecionados.contains(arquivos[i].id),
                        aoSelecionar: () => _alternar(arquivos[i]),
                        aoAbrir: () async {
                          await abrirArquivo(context, widget.api, arquivos[i]);
                          await _carregar();
                        },
                        aoAcao: (acao) => _acao(acao, arquivos[i]),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _CartaoArquivo extends StatelessWidget {
  const _CartaoArquivo({
    required this.api,
    required this.arquivo,
    required this.baixado,
    required this.selecionando,
    required this.selecionado,
    required this.aoSelecionar,
    required this.aoAbrir,
    required this.aoAcao,
  });

  final ApiArquivos api;
  final Arquivo arquivo;
  final bool baixado;
  final bool selecionando;
  final bool selecionado;
  final VoidCallback aoSelecionar;
  final VoidCallback aoAbrir;
  final ValueChanged<String> aoAcao;

  IconData get _icone => switch (arquivo.tipo) {
    'apresentacao' => Icons.slideshow_outlined,
    'planilha' => Icons.table_chart_outlined,
    'xml' => Icons.code,
    'extrato' => Icons.receipt_long_outlined,
    'documento' => Icons.description_outlined,
    _ => Icons.picture_as_pdf_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    final a = arquivo;
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: selecionado
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: cores.primary, width: 3),
            )
          : null,
      child: InkWell(
        onTap: selecionando ? aoSelecionar : aoAbrir,
        onLongPress: aoSelecionar,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: cores.surfaceContainerHighest,
                    child: a.pronto
                        ? Image(
                            image: ImagemRede(api.urlMiniatura(a).toString(), headers: api.cabecalhos),
                            fit: BoxFit.cover,
                            alignment: Alignment.topCenter,
                            errorBuilder: (_, _, _) => Icon(_icone, size: 48, color: cores.outline),
                          )
                        : Icon(_icone, size: 48, color: cores.outline),
                  ),
                  if (a.status != 'pronto')
                    Positioned(
                      left: 8,
                      bottom: 8,
                      child: Chip(
                        visualDensity: VisualDensity.compact,
                        avatar: a.status == 'convertendo'
                            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                            : Icon(Icons.error_outline, color: cores.error),
                        label: Text(a.status == 'convertendo' ? 'convertendo' : 'falhou'),
                      ),
                    ),
                  if (selecionando)
                    Positioned(
                      top: 4,
                      left: 4,
                      child: Checkbox(value: selecionado, onChanged: (_) => aoSelecionar()),
                    )
                  else if (baixado)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Tooltip(
                        message: 'Disponível sem conexão',
                        child: CircleAvatar(
                          radius: 14,
                          backgroundColor: cores.primaryContainer,
                          child: Icon(Icons.offline_pin, size: 18, color: cores.onPrimaryContainer),
                        ),
                      ),
                    ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: PopupMenuButton<String>(
                      onSelected: aoAcao,
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'renomear', child: Text('Renomear')),
                        const PopupMenuItem(value: 'pasta', child: Text('Mover para pasta')),
                        const PopupMenuItem(value: 'tags', child: Text('Tags')),
                        if (a.pronto)
                          PopupMenuItem(
                            value: 'offline',
                            child: Text(baixado ? 'Remover do aparelho' : 'Disponível offline'),
                          ),
                        if (temEditor(a) && a.pronto)
                          const PopupMenuItem(value: 'ler', child: Text('Ler e anotar (PDF)')),
                        if (formatosExportacao.containsKey(a.tipo))
                          const PopupMenuItem(value: 'exportar', child: Text('Exportar…')),
                        if (editoresPara(a).isNotEmpty) const PopupMenuItem(value: 'fora', child: Text('Abrir com…')),
                        if (const {'documento', 'apresentacao', 'planilha'}.contains(a.tipo))
                          const PopupMenuItem(value: 'collabora', child: Text('Editar no Collabora')),
                        if (a.tipo == 'documento' || a.tipo == 'pdf')
                          const PopupMenuItem(value: 'claude', child: Text('Reescrever trecho com Claude')),
                        const PopupMenuItem(value: 'baixar', child: Text('Baixar original')),
                        const PopupMenuItem(value: 'duplicar', child: Text('Duplicar')),
                        if (a.tipo != 'pdf' && a.tipo != 'xml')
                          const PopupMenuItem(value: 'converter', child: Text('Converter de novo')),
                        const PopupMenuItem(value: 'excluir', child: Text('Excluir')),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 2,
                children: [
                  Text(
                    a.titulo,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  Text(
                    [
                      a.extensao.toUpperCase(),
                      if (a.pasta.isNotEmpty) a.pasta,
                      if (a.destaques > 0) '${a.destaques} destaques',
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
