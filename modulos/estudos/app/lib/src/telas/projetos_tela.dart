import 'dart:math';

import 'package:agent_core/agent_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_estudos.dart';
import '../modelos.dart';
import 'leituras_tela.dart';
import 'mapeamento_painel.dart';

/// Abre o arquivo [arquivoId] no leitor do módulo Arquivos na [pagina] (1 = primeira). A plataforma
/// liga os dois módulos; sem ela (testes), o botão "Ver no arquivo" some.
typedef AbrirNoArquivo = Future<void> Function(BuildContext context, String arquivoId, int pagina);

/// Seção Leituras: a lista de livros/artigos e os projetos de leitura (matriz de citações).
class LeiturasEProjetos extends StatefulWidget {
  const LeiturasEProjetos({super.key, required this.api, required this.opcoes, this.abrirNoArquivo});

  final ApiEstudos api;
  final Opcoes opcoes;
  final AbrirNoArquivo? abrirNoArquivo;

  @override
  State<LeiturasEProjetos> createState() => _LeiturasEProjetosState();
}

class _LeiturasEProjetosState extends State<LeiturasEProjetos> {
  int _vista = 1;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
        child: Center(
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, icon: Icon(Icons.menu_book_outlined), label: Text('Leituras')),
              ButtonSegment(value: 1, icon: Icon(Icons.hub_outlined), label: Text('Projetos')),
            ],
            selected: {_vista},
            onSelectionChanged: (v) => setState(() => _vista = v.first),
          ),
        ),
      ),
      Expanded(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          switchInCurve: Curves.easeOutCubic,
          transitionBuilder: (c, a) => FadeTransition(
            opacity: a,
            child: SlideTransition(
              position: Tween(begin: const Offset(0, 0.03), end: Offset.zero).animate(a),
              child: c,
            ),
          ),
          child: _vista == 0
              ? LeiturasTela(key: const ValueKey('leituras'), api: widget.api, opcoes: widget.opcoes)
              : ProjetosLeituraTela(
                  key: const ValueKey('projetos'),
                  api: widget.api,
                  opcoes: widget.opcoes,
                  abrirNoArquivo: widget.abrirNoArquivo,
                ),
        ),
      ),
    ],
  );
}

const _coresProjeto = [0xFF3F51B5, 0xFF00897B, 0xFFE65100, 0xFF8E24AA, 0xFFC62828, 0xFF2E7D32, 0xFF1565C0, 0xFF6D4C41];

/// Aparece deslizando e surgindo, com atraso pela posição (lista em cascata).
class _Entrada extends StatelessWidget {
  const _Entrada({required this.indice, required this.child});

  final int indice;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: Duration(milliseconds: 280 + min(indice, 12) * 45),
    curve: Curves.easeOutCubic,
    builder: (context, t, filho) => Opacity(
      opacity: t,
      child: Transform.translate(offset: Offset(0, (1 - t) * 18), child: filho),
    ),
    child: child,
  );
}

/// Projetos de leitura em cartões; cada um abre a matriz de citações.
class ProjetosLeituraTela extends StatefulWidget {
  const ProjetosLeituraTela({super.key, required this.api, required this.opcoes, this.abrirNoArquivo});

  final ApiEstudos api;
  final Opcoes opcoes;
  final AbrirNoArquivo? abrirNoArquivo;

  @override
  State<ProjetosLeituraTela> createState() => _ProjetosLeituraTelaState();
}

class _ProjetosLeituraTelaState extends State<ProjetosLeituraTela> {
  List<ProjetoLeitura>? _projetos;
  String? _erro;

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Future<void> _carregar() async {
    try {
      final p = await widget.api.projetos();
      if (mounted) {
        setState(() {
          _projetos = p;
          _erro = null;
        });
      }
    } on ApiErro catch (e) {
      if (mounted) setState(() => _erro = '$e');
    }
  }

  Future<void> _formulario([ProjetoLeitura? atual]) async {
    final dados = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _FormularioProjeto(atual: atual),
    );
    if (dados == null || !mounted) return;
    try {
      if (atual != null && dados['_excluir'] == true) {
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text('Excluir "${atual.nome}"?'),
            content: const Text('Os trechos e anotações continuam nos arquivos; só o projeto e a classificação somem.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Excluir')),
            ],
          ),
        );
        if (ok != true) return;
        await widget.api.excluirProjeto(atual.id);
      } else {
        atual == null ? await widget.api.criarProjeto(dados) : await widget.api.editarProjeto(atual.id, dados);
      }
      await _carregar();
    } on ApiErro catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _abrir(ProjetoLeitura p) async {
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 350),
        reverseTransitionDuration: const Duration(milliseconds: 250),
        pageBuilder: (_, _, _) =>
            ProjetoTela(api: widget.api, opcoes: widget.opcoes, projeto: p, abrirNoArquivo: widget.abrirNoArquivo),
        transitionsBuilder: (_, a, _, filho) {
          final curva = CurvedAnimation(parent: a, curve: Curves.easeOutCubic);
          return FadeTransition(
            opacity: curva,
            child: ScaleTransition(scale: Tween(begin: 0.97, end: 1.0).animate(curva), child: filho),
          );
        },
      ),
    );
    await _carregar();
  }

  @override
  Widget build(BuildContext context) {
    if (_erro != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            Text(_erro!),
            FilledButton(onPressed: _carregar, child: const Text('Tentar de novo')),
          ],
        ),
      );
    }
    final projetos = _projetos;
    if (projetos == null) return const Center(child: CircularProgressIndicator());
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'novo-projeto-leitura',
        onPressed: _formulario,
        icon: const Icon(Icons.add),
        label: const Text('Projeto'),
      ),
      body: RefreshIndicator(
        onRefresh: _carregar,
        child: projetos.isEmpty
            ? ListView(
                padding: const EdgeInsets.all(32),
                children: const [
                  Icon(Icons.hub_outlined, size: 56),
                  SizedBox(height: 12),
                  Text(
                    'Crie um projeto (ex.: Pré-TCC). Depois, no leitor do módulo Arquivos, escolha o projeto '
                    'ativo no topo: todo trecho marcado, comentário e anotação à mão entra nele.',
                    textAlign: TextAlign.center,
                  ),
                ],
              )
            : GridView.builder(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 420,
                  mainAxisExtent: 168,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemCount: projetos.length,
                itemBuilder: (context, i) => _Entrada(
                  indice: i,
                  child: _CartaoProjeto(
                    projeto: projetos[i],
                    aoAbrir: () => _abrir(projetos[i]),
                    aoEditar: () => _formulario(projetos[i]),
                  ),
                ),
              ),
      ),
    );
  }
}

class _CartaoProjeto extends StatelessWidget {
  const _CartaoProjeto({required this.projeto, required this.aoAbrir, required this.aoEditar});

  final ProjetoLeitura projeto;
  final VoidCallback aoAbrir;
  final VoidCallback aoEditar;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final cor = Color(projeto.cor);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: aoAbrir,
        child: Container(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: cor, width: 5)),
            gradient: LinearGradient(colors: [cor.withValues(alpha: 0.10), Colors.transparent]),
          ),
          padding: const EdgeInsets.fromLTRB(16, 10, 6, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      projeto.nome,
                      style: tema.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(tooltip: 'Editar projeto', icon: const Icon(Icons.edit_outlined), onPressed: aoEditar),
                ],
              ),
              if (projeto.descricao.isNotEmpty)
                Text(projeto.descricao, maxLines: 2, overflow: TextOverflow.ellipsis, style: tema.textTheme.bodySmall),
              const Spacer(),
              Wrap(
                spacing: 14,
                runSpacing: 4,
                children: [
                  _Numero(Icons.article_outlined, projeto.trabalhos, 'trabalhos'),
                  _Numero(Icons.format_quote, projeto.trechos, 'trechos'),
                  _Numero(Icons.lightbulb_outline, projeto.comentarios, 'comentários'),
                  _Numero(Icons.draw_outlined, projeto.manuscritos, 'à mão'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Numero extends StatelessWidget {
  const _Numero(this.icone, this.valor, this.rotulo);

  final IconData icone;
  final int valor;
  final String rotulo;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: 4,
    children: [
      Icon(icone, size: 16),
      TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: valor.toDouble()),
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeOutCubic,
        builder: (context, v, _) => Text('${v.round()}', style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
      Text(rotulo, style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}

class _FormularioProjeto extends StatefulWidget {
  const _FormularioProjeto({this.atual});

  final ProjetoLeitura? atual;

  @override
  State<_FormularioProjeto> createState() => _FormularioProjetoState();
}

class _FormularioProjetoState extends State<_FormularioProjeto> {
  late final _nome = TextEditingController(text: widget.atual?.nome);
  late final _descricao = TextEditingController(text: widget.atual?.descricao);
  late final _secoes = TextEditingController(text: widget.atual?.secoes.join('\n'));
  late int _cor = widget.atual?.cor ?? _coresProjeto.first;

  @override
  void dispose() {
    for (final c in [_nome, _descricao, _secoes]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.atual == null ? 'Novo projeto de leitura' : 'Editar projeto'),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            TextField(
              controller: _nome,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Nome', hintText: 'Ex.: Pré-TCC'),
            ),
            TextField(
              controller: _descricao,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Descrição (opcional)'),
            ),
            TextField(
              controller: _secoes,
              minLines: 3,
              maxLines: 10,
              decoration: const InputDecoration(
                labelText: 'Seções (uma por linha)',
                hintText: '1 Introdução\n2 Referencial Teórico\n4.2.2 Estratégia PICo',
                helperText: 'Usadas para classificar os trechos e no painel de cobertura.',
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in _coresProjeto)
                  InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => setState(() => _cor = c),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: Color(c),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _cor == c ? Theme.of(context).colorScheme.onSurface : Colors.transparent,
                          width: 3,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
    actions: [
      if (widget.atual != null)
        TextButton(
          onPressed: () => Navigator.pop(context, {'_excluir': true}),
          child: Text('Excluir', style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(
        onPressed: () {
          if (_nome.text.trim().isEmpty) return;
          Navigator.pop(context, {
            'nome': _nome.text.trim(),
            'descricao': _descricao.text.trim(),
            'cor': _cor,
            'secoes': [
              for (final s in _secoes.text.split('\n'))
                if (s.trim().isNotEmpty) s.trim(),
            ],
          });
        },
        child: const Text('Salvar'),
      ),
    ],
  );
}

enum _Aba { trechos, trabalhos, cobertura }

/// Matriz de conhecimento de um projeto: trechos (original, tradução, comentário, citação),
/// trabalhos (ficha para citar) e cobertura por seção; exporta em planilha.
class ProjetoTela extends StatefulWidget {
  const ProjetoTela({super.key, required this.api, required this.opcoes, required this.projeto, this.abrirNoArquivo});

  final ApiEstudos api;
  final Opcoes opcoes;
  final ProjetoLeitura projeto;
  final AbrirNoArquivo? abrirNoArquivo;

  @override
  State<ProjetoTela> createState() => _ProjetoTelaState();
}

class _ProjetoTelaState extends State<ProjetoTela> {
  Matriz? _matriz;
  String? _erro;
  _Aba _aba = _Aba.trechos;
  String _busca = '';
  String? _tipo;
  String? _trabalho;
  String? _secao;
  String? _status;
  bool _exportando = false;

  ApiEstudos get api => widget.api;
  ProjetoLeitura get projeto => _matriz?.projeto ?? widget.projeto;

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Future<void> _carregar() async {
    try {
      final m = await api.matriz(widget.projeto.id);
      if (mounted) {
        setState(() {
          _matriz = m;
          _erro = null;
        });
      }
    } on ApiErro catch (e) {
      if (mounted) setState(() => _erro = '$e');
    }
  }

  void _avisar(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _exportar() async {
    setState(() => _exportando = true);
    try {
      final bytes = await api.exportarProjeto(projeto.id);
      final nome = 'Matriz - ${projeto.nome.replaceAll(RegExp(r'[\\/:*?"<>|]'), '')}.xlsx';
      final salvo = await FilePicker.saveFile(fileName: nome, bytes: bytes);
      if (salvo != null && mounted) _avisar('Planilha exportada: $nome');
    } on ApiErro catch (e) {
      if (mounted) _avisar('Não deu para exportar: ${e.mensagem}');
    } finally {
      if (mounted) setState(() => _exportando = false);
    }
  }

  Future<void> _editarProjeto() async {
    final dados = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _FormularioProjeto(atual: projeto),
    );
    if (dados == null || !mounted) return;
    try {
      if (dados['_excluir'] == true) {
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text('Excluir "${projeto.nome}"?'),
            content: const Text('Os trechos e anotações continuam nos arquivos; só o projeto e a classificação somem.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Excluir')),
            ],
          ),
        );
        if (ok != true) return;
        await api.excluirProjeto(projeto.id);
        if (mounted) Navigator.pop(context);
        return;
      }
      await api.editarProjeto(projeto.id, dados);
      await _carregar();
    } on ApiErro catch (e) {
      if (mounted) _avisar('$e');
    }
  }

  List<ItemMatriz> _filtrados(Matriz m) {
    final termo = _busca.trim().toLowerCase();
    return [
      for (final i in m.itens)
        if ((_tipo == null || i.tipo == _tipo) &&
            (_trabalho == null || i.trabalho == _trabalho) &&
            (_secao == null || i.campo('secao') == _secao) &&
            (_status == null || i.campo('status_uso') == _status) &&
            (termo.isEmpty || i.busca.contains(termo)))
          i,
    ];
  }

  Future<void> _classificar(ItemMatriz item) async {
    final m = _matriz;
    if (m == null) return;
    final trabalho = m.trabalhos.where((t) => t.codigo == item.trabalho).firstOrNull;
    final dados = await mostrarFolhaAdaptavel<Map<String, String>>(
      context,
      (_) => _FolhaItem(
        item: item,
        trabalho: trabalho,
        opcoes: widget.opcoes,
        secoes: {...projeto.secoes, for (final i in m.itens) i.campo('secao')}.where((s) => s.isNotEmpty).toList(),
        abrirNoArquivo: widget.abrirNoArquivo,
      ),
    );
    if (dados == null) return;
    try {
      await api.classificar(projeto.id, item.id, dados);
      await _carregar();
    } on ApiErro catch (e) {
      if (mounted) _avisar('$e');
    }
  }

  Future<void> _ficha(TrabalhoMatriz t) async {
    final dados = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _FichaTrabalho(trabalho: t),
    );
    if (dados == null) return;
    try {
      final id = t.leituraId;
      if (id == null) {
        await api.criarLeitura({
          ...dados,
          'tipo': 'artigo',
          'area': widget.opcoes.areas.firstOrNull ?? 'Tecnologia',
          'status': 'lendo',
          'arquivo_id': t.arquivoId,
        });
      } else {
        await api.editarLeitura(id, dados);
      }
      await _carregar();
    } on ApiErro catch (e) {
      if (mounted) _avisar('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = _matriz;
    final faixa = Faixa.de(context);
    return Scaffold(
      appBar: AppBar(
        title: Row(
          spacing: 10,
          children: [
            CircleAvatar(radius: 7, backgroundColor: Color(projeto.cor)),
            Flexible(child: Text(projeto.nome, overflow: TextOverflow.ellipsis)),
          ],
        ),
        actions: [
          IconButton(tooltip: 'Atualizar', icon: const Icon(Icons.refresh), onPressed: _carregar),
          IconButton(tooltip: 'Editar projeto', icon: const Icon(Icons.edit_outlined), onPressed: _editarProjeto),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: _exportando
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : faixa.celular
                  ? IconButton(
                      tooltip: 'Exportar planilha',
                      icon: const Icon(Icons.file_download_outlined),
                      onPressed: m == null ? null : _exportar,
                    )
                  : FilledButton.tonalIcon(
                      icon: const Icon(Icons.table_view_outlined),
                      label: const Text('Exportar planilha'),
                      onPressed: m == null ? null : _exportar,
                    ),
            ),
          ),
        ],
      ),
      body: _erro != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                spacing: 12,
                children: [
                  Text(_erro!),
                  FilledButton(onPressed: _carregar, child: const Text('Tentar de novo')),
                ],
              ),
            )
          : m == null
          ? const Center(child: CircularProgressIndicator())
          : LarguraMaxima(
              largura: 1800,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Resumo(matriz: m),
                  MapeamentoPainel(
                    api: api,
                    projetoId: widget.projeto.id,
                    abrirNoArquivo: widget.abrirNoArquivo,
                    aoConcluir: _carregar,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: SegmentedButton<_Aba>(
                      showSelectedIcon: !faixa.celular,
                      segments: [
                        ButtonSegment(
                          value: _Aba.trechos,
                          icon: const Icon(Icons.format_quote),
                          label: Text('Trechos (${m.itens.length})'),
                        ),
                        ButtonSegment(
                          value: _Aba.trabalhos,
                          icon: const Icon(Icons.article_outlined),
                          label: Text('Trabalhos (${m.trabalhos.length})'),
                        ),
                        const ButtonSegment(
                          value: _Aba.cobertura,
                          icon: Icon(Icons.grid_view),
                          label: Text('Cobertura'),
                        ),
                      ],
                      selected: {_aba},
                      onSelectionChanged: (v) => setState(() => _aba = v.first),
                    ),
                  ),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 280),
                      switchInCurve: Curves.easeOutCubic,
                      transitionBuilder: (c, a) => FadeTransition(opacity: a, child: c),
                      child: switch (_aba) {
                        _Aba.trechos => KeyedSubtree(key: const ValueKey('trechos'), child: _trechos(m)),
                        _Aba.trabalhos => KeyedSubtree(key: const ValueKey('trabalhos'), child: _trabalhos(m)),
                        _Aba.cobertura => KeyedSubtree(key: const ValueKey('cobertura'), child: _cobertura(m)),
                      },
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _filtros(Matriz m) {
    final secoes = {for (final i in m.itens) i.campo('secao')}.where((s) => s.isNotEmpty).toList()..sort();
    Widget menu(String rotulo, String? valor, Map<String?, String> opcoes, ValueChanged<String?> aoMudar) =>
        PopupMenuButton<String?>(
          tooltip: rotulo,
          onSelected: aoMudar,
          itemBuilder: (_) => [
            for (final e in opcoes.entries)
              CheckedPopupMenuItem(value: e.key, checked: valor == e.key, child: Text(e.value)),
          ],
          child: Chip(
            avatar: Icon(valor == null ? Icons.filter_list : Icons.filter_alt, size: 18),
            label: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: Text(valor == null ? rotulo : opcoes[valor] ?? valor, overflow: TextOverflow.ellipsis),
            ),
            backgroundColor: valor == null ? null : Theme.of(context).colorScheme.secondaryContainer,
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: min(MediaQuery.sizeOf(context).width - 24, 340),
            child: TextField(
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search),
                hintText: 'Buscar no trecho, tradução, comentário…',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _busca = v),
            ),
          ),
          menu('Tipo', _tipo, const {
            null: 'Todos os tipos',
            'destaque': 'Trechos marcados',
            'texto': 'Comentários na página',
            'manuscrito': 'Anotações à mão',
          }, (v) => setState(() => _tipo = v)),
          menu('Trabalho', _trabalho, {
            null: 'Todos os trabalhos',
            for (final t in m.trabalhos)
              t.codigo: '${t.codigo} · ${t.autorCitacao.isEmpty ? t.titulo : t.autorCitacao}',
          }, (v) => setState(() => _trabalho = v)),
          if (secoes.isNotEmpty)
            menu('Seção', _secao, {
              null: 'Todas as seções',
              for (final s in secoes) s: s,
            }, (v) => setState(() => _secao = v)),
          menu('Status', _status, {
            null: 'Qualquer status',
            for (final s in widget.opcoes.statusUso) s: s,
          }, (v) => setState(() => _status = v)),
        ],
      ),
    );
  }

  Widget _trechos(Matriz m) {
    final itens = _filtrados(m);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _filtros(m),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _carregar,
            child: m.itens.isEmpty
                ? ListView(
                    padding: const EdgeInsets.all(32),
                    children: const [
                      Text(
                        'Nada ligado a este projeto ainda. No leitor de Arquivos, escolha este projeto no botão '
                        'de projeto (topo) e marque trechos, escreva ou anote à mão; ou toque num destaque e '
                        'ligue-o ao projeto.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  )
                : itens.isEmpty
                ? ListView(
                    padding: const EdgeInsets.all(32),
                    children: const [Text('Nada com esses filtros.', textAlign: TextAlign.center)],
                  )
                : LayoutBuilder(
                    builder: (context, area) {
                      final colunas = max(1, min(3, (area.maxWidth / 480).floor()));
                      final largura = (area.maxWidth - 24 - (colunas - 1) * 12) / colunas;
                      return SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            for (final (n, i) in itens.indexed)
                              SizedBox(
                                key: ValueKey(i.id),
                                width: largura,
                                child: _Entrada(
                                  indice: n,
                                  child: _CartaoItem(item: i, aoTocar: () => _classificar(i)),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  Widget _trabalhos(Matriz m) => ListView.builder(
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
    itemCount: m.trabalhos.length,
    itemBuilder: (context, n) {
      final t = m.trabalhos[n];
      final tema = Theme.of(context);
      return _Entrada(
        indice: n,
        child: Card(
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _ficha(t),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 6,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Chip(label: Text(t.codigo), visualDensity: VisualDensity.compact),
                      Text(
                        t.autorCitacao.isEmpty
                            ? 'Autor não informado'
                            : '${t.autorCitacao} (${t.ano.isEmpty ? 's.d.' : t.ano})',
                        style: tema.textTheme.titleSmall,
                      ),
                      if (t.autorCitacao.isEmpty || t.ano.isEmpty)
                        Text(
                          'Complete a ficha para citar',
                          style: tema.textTheme.labelSmall?.copyWith(color: tema.colorScheme.error),
                        ),
                    ],
                  ),
                  Text(t.titulo, style: tema.textTheme.titleMedium),
                  if (t.referencia.isNotEmpty) SelectableText(t.referencia, style: tema.textTheme.bodySmall),
                  Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: TweenAnimationBuilder<double>(
                            tween: Tween(begin: 0, end: t.trechos == 0 ? 0 : t.usados / t.trechos),
                            duration: const Duration(milliseconds: 700),
                            curve: Curves.easeOutCubic,
                            builder: (_, v, _) => LinearProgressIndicator(value: v, minHeight: 6),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text('${t.usados}/${t.trechos} usados', style: tema.textTheme.bodySmall),
                      if (widget.abrirNoArquivo != null)
                        IconButton(
                          tooltip: 'Abrir o arquivo',
                          icon: const Icon(Icons.open_in_new),
                          onPressed: () => widget.abrirNoArquivo!(context, t.arquivoId, 1),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _cobertura(Matriz m) {
    final contagem = <String, (int, int)>{for (final s in projeto.secoes) s: (0, 0)};
    for (final i in m.itens) {
      final s = i.campo('secao').isEmpty ? 'Não definido' : i.campo('secao');
      final (total, usados) = contagem[s] ?? (0, 0);
      contagem[s] = (total + 1, usados + (i.usado ? 1 : 0));
    }
    final maior = contagem.values.fold<int>(1, (a, c) => max(a, c.$1));
    final tema = Theme.of(context);
    // Trabalho × seção: quantos trechos de cada trabalho alimentam cada seção.
    final cruzado = <(String, String), int>{};
    for (final i in m.itens) {
      final s = i.campo('secao').isEmpty ? 'Não definido' : i.campo('secao');
      cruzado[(i.trabalho, s)] = (cruzado[(i.trabalho, s)] ?? 0) + 1;
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
      children: [
        Text('Trechos por seção', style: tema.textTheme.titleMedium),
        const SizedBox(height: 8),
        if (contagem.isEmpty) const Text('Defina seções no projeto (Editar projeto) e classifique os trechos.'),
        for (final (n, e) in contagem.entries.indexed)
          _Entrada(
            indice: n,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(e.key, overflow: TextOverflow.ellipsis)),
                      Text('${e.value.$2} usados · ${e.value.$1} trechos', style: tema.textTheme.bodySmall),
                    ],
                  ),
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: e.value.$1 / maior),
                    duration: const Duration(milliseconds: 700),
                    curve: Curves.easeOutCubic,
                    builder: (_, v, _) => Stack(
                      children: [
                        Container(
                          height: 10,
                          decoration: BoxDecoration(
                            color: tema.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(5),
                          ),
                        ),
                        FractionallySizedBox(
                          widthFactor: v,
                          child: Container(
                            height: 10,
                            decoration: BoxDecoration(
                              color: Color(projeto.cor).withValues(alpha: 0.45),
                              borderRadius: BorderRadius.circular(5),
                            ),
                          ),
                        ),
                        FractionallySizedBox(
                          widthFactor: e.value.$1 == 0 ? 0 : v * e.value.$2 / e.value.$1,
                          child: Container(
                            height: 10,
                            decoration: BoxDecoration(
                              color: Color(projeto.cor),
                              borderRadius: BorderRadius.circular(5),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 20),
        Text('Matriz trabalho × seção', style: tema.textTheme.titleMedium),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowHeight: 40,
            dataRowMinHeight: 36,
            dataRowMaxHeight: 44,
            columnSpacing: 18,
            columns: [
              const DataColumn(label: Text('Trabalho')),
              for (final s in contagem.keys)
                DataColumn(
                  numeric: true,
                  label: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 140),
                    child: Text(s, overflow: TextOverflow.ellipsis),
                  ),
                ),
            ],
            rows: [
              for (final t in m.trabalhos)
                DataRow(
                  cells: [
                    DataCell(Text('${t.codigo} · ${t.autorCitacao.isEmpty ? t.titulo : t.citacaoCurta}')),
                    for (final s in contagem.keys)
                      DataCell(
                        (cruzado[(t.codigo, s)] ?? 0) == 0
                            ? const Text('·')
                            : CircleAvatar(
                                radius: 13,
                                backgroundColor: Color(projeto.cor)
                                    .withValues(alpha: 0.25 + 0.75 * min(1, (cruzado[(t.codigo, s)] ?? 0) / 5)),
                                child: Text('${cruzado[(t.codigo, s)]}', style: const TextStyle(fontSize: 12)),
                              ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}

extension on TrabalhoMatriz {
  String get citacaoCurta => '$autorCitacao ${ano.isEmpty ? 's.d.' : ano}';
}

/// Resumo animado do projeto no topo da matriz.
class _Resumo extends StatelessWidget {
  const _Resumo({required this.matriz});

  final Matriz matriz;

  @override
  Widget build(BuildContext context) {
    final itens = matriz.itens;
    final dados = [
      (Icons.article_outlined, matriz.trabalhos.length, 'trabalhos'),
      (Icons.format_quote, itens.where((i) => i.tipo == 'destaque').length, 'trechos'),
      (Icons.lightbulb_outline, itens.where((i) => i.tipo == 'texto' || i.comentario.isNotEmpty).length, 'comentários'),
      (Icons.draw_outlined, itens.where((i) => i.tipo == 'manuscrito').length, 'páginas à mão'),
      (Icons.check_circle_outline, itens.where((i) => i.usado).length, 'usados'),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        spacing: 10,
        children: [
          for (final (icone, valor, rotulo) in dados)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              child: _Numero(icone, valor, rotulo),
            ),
        ],
      ),
    );
  }
}

class _CartaoItem extends StatelessWidget {
  const _CartaoItem({required this.item, required this.aoTocar});

  final ItemMatriz item;
  final VoidCallback aoTocar;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final cor = item.cor == null ? tema.colorScheme.primary : Color(item.cor!).withValues(alpha: 1);
    final (icone, tipo) = switch (item.tipo) {
      'destaque' => (Icons.format_quote, 'Trecho'),
      'texto' => (Icons.sticky_note_2_outlined, 'Comentário na página'),
      _ => (Icons.draw_outlined, 'Anotação à mão'),
    };
    final c = item.classificacao;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: aoTocar,
        child: Container(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: cor, width: 4)),
          ),
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              Row(
                spacing: 6,
                children: [
                  Icon(icone, size: 18, color: cor),
                  Text(item.codigo, style: tema.textTheme.labelLarge),
                  Expanded(
                    child: Text(
                      '$tipo · ${item.citacaoNarrativa}, p. ${item.pagina + 1}',
                      style: tema.textTheme.labelMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (item.usado) Icon(Icons.check_circle, size: 18, color: tema.colorScheme.primary),
                ],
              ),
              if (item.tipo == 'manuscrito')
                Container(
                  height: 150,
                  width: double.infinity,
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
                  child: CustomPaint(painter: _PinturaManuscrito(item.tracos)),
                )
              else
                Text(
                  item.texto,
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                  style: item.tipo == 'destaque'
                      ? tema.textTheme.bodyMedium?.copyWith(fontStyle: FontStyle.italic)
                      : null,
                ),
              if (item.traducao.isNotEmpty) _Linha(icone: Icons.translate, texto: item.traducao, linhas: 5),
              if (item.comentario.isNotEmpty)
                _Linha(icone: Icons.lightbulb_outline, texto: item.comentario, linhas: 4, destaque: true),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _Etiqueta(item.citacaoParentetica, Icons.format_quote),
                  for (final campo in const ['secao', 'tipo_citacao', 'tipo_conteudo'])
                    if ((c[campo] ?? '').isNotEmpty) _Etiqueta(c[campo]!, null),
                  _Etiqueta(c['status_uso'] ?? 'Não usado', item.usado ? Icons.check : Icons.schedule),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Linha extends StatelessWidget {
  const _Linha({required this.icone, required this.texto, required this.linhas, this.destaque = false});

  final IconData icone;
  final String texto;
  final int linhas;
  final bool destaque;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: destaque
          ? Theme.of(context).colorScheme.tertiaryContainer.withValues(alpha: 0.5)
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 6,
      children: [
        Icon(icone, size: 16),
        Expanded(
          child: Text(texto, maxLines: linhas, overflow: TextOverflow.ellipsis),
        ),
      ],
    ),
  );
}

class _Etiqueta extends StatelessWidget {
  const _Etiqueta(this.texto, this.icone);

  final String texto;
  final IconData? icone;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        if (icone != null) Icon(icone, size: 13),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Text(texto, style: Theme.of(context).textTheme.labelSmall, overflow: TextOverflow.ellipsis),
        ),
      ],
    ),
  );
}

/// Traços à mão de uma página, enquadrados na caixa (sem o PDF por baixo).
class _PinturaManuscrito extends CustomPainter {
  _PinturaManuscrito(this.tracos);

  final List<TracoMao> tracos;

  @override
  void paint(Canvas canvas, Size size) {
    var limites = Rect.zero;
    var primeiro = true;
    for (final t in tracos) {
      for (var i = 0; i + 1 < t.pontos.length; i += 3) {
        final p = Rect.fromLTWH(t.pontos[i], t.pontos[i + 1], 0, 0);
        limites = primeiro ? p : limites.expandToInclude(p);
        primeiro = false;
      }
    }
    if (primeiro) return;
    limites = limites.inflate(8);
    final escala = min(size.width / max(limites.width, 1), size.height / max(limites.height, 1));
    canvas
      ..translate(
        (size.width - limites.width * escala) / 2 - limites.left * escala,
        (size.height - limites.height * escala) / 2 - limites.top * escala,
      )
      ..scale(escala);
    for (final t in tracos) {
      final caminho = Path();
      for (var i = 0; i + 1 < t.pontos.length; i += 3) {
        i == 0 ? caminho.moveTo(t.pontos[i], t.pontos[i + 1]) : caminho.lineTo(t.pontos[i], t.pontos[i + 1]);
      }
      canvas.drawPath(
        caminho,
        Paint()
          ..color = Color(t.cor).withValues(alpha: t.marcador ? 0.4 : 1)
          ..strokeWidth = t.espessura
          ..style = PaintingStyle.stroke
          ..strokeCap = t.marcador ? StrokeCap.square : StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  @override
  bool shouldRepaint(_PinturaManuscrito antiga) => antiga.tracos != tracos;
}

/// Folha de baixo no celular, diálogo lateral no tablet/PC.
Future<T?> mostrarFolhaAdaptavel<T>(BuildContext context, WidgetBuilder construir) {
  if (Faixa.de(context).celular) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: construir,
    );
  }
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Fechar',
    transitionDuration: const Duration(milliseconds: 280),
    pageBuilder: (c, _, _) => Align(
      alignment: Alignment.centerRight,
      child: Material(
        elevation: 8,
        child: SizedBox(
          width: min(560, MediaQuery.sizeOf(c).width * 0.9),
          height: double.infinity,
          child: SafeArea(child: construir(c)),
        ),
      ),
    ),
    transitionBuilder: (_, a, _, filho) => SlideTransition(
      position: Tween(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
      child: filho,
    ),
  );
}

/// Detalhe de um item da matriz com a classificação no projeto. Devolve os campos alterados.
class _FolhaItem extends StatefulWidget {
  const _FolhaItem({
    required this.item,
    required this.trabalho,
    required this.opcoes,
    required this.secoes,
    this.abrirNoArquivo,
  });

  final ItemMatriz item;
  final TrabalhoMatriz? trabalho;
  final Opcoes opcoes;
  final List<String> secoes;
  final AbrirNoArquivo? abrirNoArquivo;

  @override
  State<_FolhaItem> createState() => _FolhaItemState();
}

class _FolhaItemState extends State<_FolhaItem> {
  late final Map<String, String> _valores = {...widget.item.classificacao};
  late final _palavras = TextEditingController(text: widget.item.campo('palavras_chave'));
  late final _parafrase = TextEditingController(text: widget.item.campo('parafrase'));
  late final _observacoes = TextEditingController(text: widget.item.campo('observacoes'));
  late final _secao = TextEditingController(text: widget.item.campo('secao'));

  /// Campo do Autocomplete (é dele o texto digitado ou escolhido).
  TextEditingController? _campoSecao;

  @override
  void dispose() {
    for (final c in [_palavras, _parafrase, _observacoes, _secao]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _escolha(String rotulo, String campo, List<String> opcoes) => DropdownButtonFormField<String>(
    initialValue: opcoes.contains(_valores[campo]) ? _valores[campo] : null,
    isExpanded: true,
    decoration: InputDecoration(labelText: rotulo, border: const OutlineInputBorder(), isDense: true),
    items: [
      for (final o in opcoes)
        DropdownMenuItem(
          value: o,
          child: Text(o, overflow: TextOverflow.ellipsis),
        ),
    ],
    onChanged: (v) => setState(() => _valores[campo] = v ?? ''),
  );

  void _copiar(String texto, String aviso) {
    Clipboard.setData(ClipboardData(text: texto));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(aviso)));
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.item;
    final tema = Theme.of(context);
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            children: [
              Text('${i.codigo} · ${i.arquivoTitulo}', style: tema.textTheme.titleMedium),
              Text('Página ${i.pagina + 1} · ${i.citacaoNarrativa}', style: tema.textTheme.bodySmall),
              const SizedBox(height: 12),
              if (i.tipo == 'manuscrito')
                Container(
                  height: 220,
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
                  child: CustomPaint(painter: _PinturaManuscrito(i.tracos)),
                )
              else
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(
                        color: i.cor == null ? tema.colorScheme.primary : Color(i.cor!).withValues(alpha: 1),
                        width: 4,
                      ),
                    ),
                    color: tema.colorScheme.surfaceContainerHighest,
                  ),
                  child: SelectableText(i.texto),
                ),
              if (i.traducao.isNotEmpty) ...[
                const SizedBox(height: 8),
                _Linha(icone: Icons.translate, texto: i.traducao, linhas: 40),
              ],
              if (i.comentario.isNotEmpty) ...[
                const SizedBox(height: 8),
                _Linha(icone: Icons.lightbulb_outline, texto: i.comentario, linhas: 40, destaque: true),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (i.texto.isNotEmpty && i.tipo == 'destaque')
                    ActionChip(
                      avatar: const Icon(Icons.copy, size: 16),
                      label: Text('Citação ${i.citacaoParentetica}'),
                      onPressed: () => _copiar(
                        '"${i.texto}" ${i.citacaoParentetica.replaceFirst(']', ', p. ${i.pagina + 1}]')}',
                        'Citação direta copiada',
                      ),
                    ),
                  ActionChip(
                    avatar: const Icon(Icons.copy, size: 16),
                    label: Text(i.citacaoNarrativa),
                    onPressed: () => _copiar(i.citacaoNarrativa, 'Citação narrativa copiada'),
                  ),
                  if (widget.trabalho?.referencia.isNotEmpty ?? false)
                    ActionChip(
                      avatar: const Icon(Icons.copy, size: 16),
                      label: const Text('Referência'),
                      onPressed: () => _copiar(widget.trabalho!.referencia, 'Referência copiada'),
                    ),
                  if (widget.abrirNoArquivo != null)
                    ActionChip(
                      avatar: const Icon(Icons.open_in_new, size: 16),
                      label: const Text('Ver no arquivo'),
                      onPressed: () => widget.abrirNoArquivo!(context, i.arquivoId, i.pagina + 1),
                    ),
                ],
              ),
              const Divider(height: 32),
              Text('Classificação neste projeto', style: tema.textTheme.titleSmall),
              const SizedBox(height: 12),
              Autocomplete<String>(
                initialValue: TextEditingValue(text: _secao.text),
                optionsBuilder: (v) => widget.secoes.where((s) => s.toLowerCase().contains(v.text.toLowerCase())),
                fieldViewBuilder: (context, campo, foco, _) {
                  _campoSecao = campo;
                  return TextField(
                    controller: campo,
                    focusNode: foco,
                    decoration: const InputDecoration(
                      labelText: 'Seção / subseção',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, area) {
                  final larga = area.maxWidth > 460;
                  final campos = [
                    _escolha('Tipo de citação', 'tipo_citacao', widget.opcoes.tiposCitacao),
                    _escolha('Tipo de conteúdo', 'tipo_conteudo', widget.opcoes.tiposConteudo),
                  ];
                  return larga
                      ? Row(spacing: 12, children: [for (final c in campos) Expanded(child: c)])
                      : Column(spacing: 12, children: campos);
                },
              ),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: [for (final s in widget.opcoes.statusUso) ButtonSegment(value: s, label: Text(s))],
                selected: {_valores['status_uso'] ?? 'Não usado'},
                onSelectionChanged: (v) => setState(() => _valores['status_uso'] = v.first),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _palavras,
                decoration: const InputDecoration(
                  labelText: 'Palavras-chave (separe com ;)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _parafrase,
                minLines: 2,
                maxLines: 8,
                decoration: const InputDecoration(
                  labelText: 'Paráfrase ou redação própria',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _observacoes,
                minLines: 1,
                maxLines: 5,
                decoration: const InputDecoration(labelText: 'Observações', border: OutlineInputBorder()),
              ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Row(
              children: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
                const Spacer(),
                FilledButton.icon(
                  icon: const Icon(Icons.check),
                  label: const Text('Salvar'),
                  onPressed: () => Navigator.pop(context, {
                    for (final campo in const ['tipo_citacao', 'tipo_conteudo', 'status_uso'])
                      if (_valores[campo] != null) campo: _valores[campo]!,
                    'secao': (_campoSecao ?? _secao).text.trim(),
                    'palavras_chave': _palavras.text.trim(),
                    'parafrase': _parafrase.text.trim(),
                    'observacoes': _observacoes.text.trim(),
                  }),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Ficha do trabalho (autor, ano, referência…) gravada na leitura ligada ao arquivo.
class _FichaTrabalho extends StatefulWidget {
  const _FichaTrabalho({required this.trabalho});

  final TrabalhoMatriz trabalho;

  @override
  State<_FichaTrabalho> createState() => _FichaTrabalhoState();
}

class _FichaTrabalhoState extends State<_FichaTrabalho> {
  late final _campos = {
    'titulo': TextEditingController(text: widget.trabalho.titulo),
    'autor': TextEditingController(text: widget.trabalho.autor),
    'ano': TextEditingController(text: widget.trabalho.ano),
    'referencia': TextEditingController(text: widget.trabalho.referencia),
    'tipo_publicacao': TextEditingController(text: widget.trabalho.tipoPublicacao),
    'veiculo': TextEditingController(text: widget.trabalho.veiculo),
    'doi': TextEditingController(text: widget.trabalho.doi),
    'idioma': TextEditingController(text: widget.trabalho.idioma),
  };

  static const _rotulos = {
    'titulo': 'Título',
    'autor': 'Autor(es) — "Sobrenome, N.; Sobrenome, N."',
    'ano': 'Ano',
    'referencia': 'Referência completa',
    'tipo_publicacao': 'Tipo de publicação (artigo em periódico, evento…)',
    'veiculo': 'Veículo (periódico ou evento)',
    'doi': 'DOI ou URL',
    'idioma': 'Idioma',
  };

  @override
  void dispose() {
    for (final c in _campos.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Ficha de ${widget.trabalho.codigo}'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 10,
          children: [
            for (final e in _campos.entries)
              TextField(
                controller: e.value,
                minLines: 1,
                maxLines: e.key == 'referencia' ? 4 : 1,
                keyboardType: e.key == 'ano' ? TextInputType.number : null,
                decoration: InputDecoration(labelText: _rotulos[e.key]),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(
        onPressed: () {
          final dados = {for (final e in _campos.entries) e.key: e.value.text.trim()};
          if (dados['titulo']!.isEmpty) return;
          Navigator.pop(context, dados);
        },
        child: const Text('Salvar'),
      ),
    ],
  );
}
