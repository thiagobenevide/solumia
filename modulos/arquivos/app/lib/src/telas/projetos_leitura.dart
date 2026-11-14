import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_arquivos.dart';

/// Projeto de leitura do módulo Estudos (`/api/estudos/projetos`): pré-TCC, roteiro de vídeo…
/// Os trechos, comentários e anotações à mão guardam o `id` dele no campo `projetos`.
class ProjetoLeitura {
  const ProjetoLeitura({required this.id, required this.nome, required this.cor});

  factory ProjetoLeitura.fromJson(Map<String, dynamic> j) =>
      ProjetoLeitura(id: j['id'] as String, nome: j['nome'] as String, cor: Color(j['cor'] as int? ?? 0xFF3F51B5));

  final String id;
  final String nome;
  final Color cor;
}

/// Projetos em que o que for marcado ou escrito agora entra sozinho. Vale para todos os arquivos
/// abertos na sessão (trocar de artigo não perde a escolha).
final projetosAtivos = ValueNotifier<List<String>>(const []);

List<ProjetoLeitura>? _cache;

Future<List<ProjetoLeitura>> carregarProjetos(ApiArquivos api, {bool recarregar = false}) async {
  if (_cache != null && !recarregar) return _cache!;
  return _cache = await api.projetosLeitura();
}

/// Folha para escolher projetos (vários de uma vez) e criar um novo. `null` = cancelou.
Future<List<String>?> escolherProjetos(
  BuildContext context,
  ApiArquivos api, {
  required List<String> selecionados,
  String titulo = 'Projetos de leitura',
  String? dica,
}) => showModalBottomSheet<List<String>>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _EscolhaProjetos(api: api, inicial: selecionados, titulo: titulo, dica: dica),
);

class _EscolhaProjetos extends StatefulWidget {
  const _EscolhaProjetos({required this.api, required this.inicial, required this.titulo, this.dica});

  final ApiArquivos api;
  final List<String> inicial;
  final String titulo;
  final String? dica;

  @override
  State<_EscolhaProjetos> createState() => _EscolhaProjetosState();
}

class _EscolhaProjetosState extends State<_EscolhaProjetos> {
  late final _marcados = {...widget.inicial};
  List<ProjetoLeitura>? _projetos;
  Object? _erro;

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Future<void> _carregar({bool recarregar = false}) async {
    try {
      final p = await carregarProjetos(widget.api, recarregar: recarregar);
      if (mounted) setState(() => _projetos = p);
    } catch (e) {
      if (mounted) setState(() => _erro = e);
    }
  }

  Future<void> _novo() async {
    final campo = TextEditingController();
    final nome = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Novo projeto de leitura'),
        content: TextField(
          controller: campo,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Nome', hintText: 'Ex.: Pré-TCC, vídeo sobre IA…'),
          onSubmitted: (v) => Navigator.pop(c, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, campo.text), child: const Text('Criar')),
        ],
      ),
    ).whenComplete(campo.dispose);
    if (nome == null || nome.trim().isEmpty) return;
    try {
      final p = await widget.api.criarProjetoLeitura(nome.trim());
      _marcados.add(p.id);
      await _carregar(recarregar: true);
    } on ApiErro catch (e) {
      if (mounted) setState(() => _erro = e.mensagem);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final projetos = _projetos;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              Text(widget.titulo, style: tema.textTheme.titleMedium),
              if (widget.dica != null) Text(widget.dica!, style: tema.textTheme.bodySmall),
              if (_erro != null) Text('$_erro', style: TextStyle(color: tema.colorScheme.error)),
              Flexible(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: projetos == null
                      ? const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      : SingleChildScrollView(
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final p in projetos)
                                FilterChip(
                                  avatar: CircleAvatar(backgroundColor: p.cor, radius: 6),
                                  label: Text(p.nome),
                                  selected: _marcados.contains(p.id),
                                  onSelected: (v) => setState(() => v ? _marcados.add(p.id) : _marcados.remove(p.id)),
                                ),
                              ActionChip(
                                avatar: const Icon(Icons.add, size: 18),
                                label: const Text('Novo projeto'),
                                onPressed: _novo,
                              ),
                            ],
                          ),
                        ),
                ),
              ),
              Row(
                children: [
                  if (_marcados.isNotEmpty)
                    TextButton(onPressed: () => setState(_marcados.clear), child: const Text('Nenhum')),
                  const Spacer(),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, [
                      for (final p in projetos ?? const <ProjetoLeitura>[])
                        if (_marcados.contains(p.id)) p.id,
                    ]),
                    child: const Text('Pronto'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Botão da barra do leitor com o(s) projeto(s) ativo(s): o que for marcado ou escrito entra neles.
class BotaoProjetoAtivo extends StatelessWidget {
  const BotaoProjetoAtivo({super.key, required this.api, this.aoLigarPagina});

  final ApiArquivos api;

  /// Liga ao(s) projeto(s) ativo(s) o que já foi anotado na página aberta.
  final VoidCallback? aoLigarPagina;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: projetosAtivos,
    builder: (context, ativos, _) => FutureBuilder(
      future: carregarProjetos(api),
      builder: (context, s) {
        final nomes = {for (final p in s.data ?? const <ProjetoLeitura>[]) p.id: p};
        final escolhidos = [for (final id in ativos) ?nomes[id]];
        final estreito = MediaQuery.sizeOf(context).width < 600;
        final rotulo = escolhidos.isEmpty
            ? (estreito ? '' : 'Sem projeto')
            : escolhidos.length == 1
            ? escolhidos.first.nome
            : '${escolhidos.length} projetos';
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: Tooltip(
              message: 'Projeto de leitura: o que você marcar ou escrever entra nele',
              child: ActionChip(
                avatar: Icon(
                  escolhidos.isEmpty ? Icons.folder_off_outlined : Icons.folder_special,
                  size: 18,
                  color: escolhidos.isEmpty ? null : escolhidos.first.cor,
                ),
                label: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  transitionBuilder: (c, a) => FadeTransition(
                    opacity: a,
                    child: SizeTransition(sizeFactor: a, axis: Axis.horizontal, child: c),
                  ),
                  child: rotulo.isEmpty
                      ? const SizedBox.shrink()
                      : ConstrainedBox(
                          key: ValueKey(rotulo),
                          constraints: BoxConstraints(maxWidth: estreito ? 110 : 200),
                          child: Text(rotulo, overflow: TextOverflow.ellipsis),
                        ),
                ),
                labelPadding: rotulo.isEmpty ? EdgeInsets.zero : null,
                onPressed: () async {
                  final r = await escolherProjetos(
                    context,
                    api,
                    selecionados: ativos,
                    titulo: 'Projeto ativo',
                    dica:
                        'Trechos marcados, textos e anotações à mão feitos daqui em diante entram '
                        'nos projetos escolhidos. Toque num destaque para mudar só ele.',
                  );
                  if (r == null) return;
                  projetosAtivos.value = r;
                  if (r.isNotEmpty && aoLigarPagina != null && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: const Text('Projeto ativo definido'),
                        action: SnackBarAction(label: 'Ligar esta página', onPressed: aoLigarPagina!),
                      ),
                    );
                  }
                },
              ),
            ),
          ),
        );
      },
    ),
  );
}

/// Chips dos projetos de um destaque, para ligar/desligar com um toque.
class ChipsProjetos extends StatefulWidget {
  const ChipsProjetos({super.key, required this.api, required this.inicial, required this.aoMudar});

  final ApiArquivos api;
  final List<String> inicial;
  final ValueChanged<List<String>> aoMudar;

  @override
  State<ChipsProjetos> createState() => _ChipsProjetosState();
}

class _ChipsProjetosState extends State<ChipsProjetos> {
  late List<String> _marcados = [...widget.inicial];

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: carregarProjetos(widget.api),
    builder: (context, s) {
      if (s.hasError) return Text('Projetos indisponíveis: ${s.error}');
      final projetos = s.data;
      return AnimatedSize(
        duration: const Duration(milliseconds: 220),
        child: projetos == null
            ? const LinearProgressIndicator()
            : Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final p in projetos)
                    FilterChip(
                      avatar: CircleAvatar(backgroundColor: p.cor, radius: 6),
                      label: Text(p.nome),
                      selected: _marcados.contains(p.id),
                      onSelected: (v) {
                        setState(
                          () => _marcados = [
                            for (final id in _marcados)
                              if (id != p.id) id,
                            if (v) p.id,
                          ],
                        );
                        widget.aoMudar(_marcados);
                      },
                    ),
                  ActionChip(
                    avatar: const Icon(Icons.add, size: 18),
                    label: const Text('Projeto'),
                    onPressed: () async {
                      final r = await escolherProjetos(context, widget.api, selecionados: _marcados);
                      if (r == null) return;
                      setState(() => _marcados = r);
                      widget.aoMudar(r);
                    },
                  ),
                ],
              ),
      );
    },
  );
}

/// Edita a tradução de um trecho; "Traduzir" preenche pela LLM local.
Future<String?> editarTraducao(BuildContext context, ApiArquivos api, {required String original, String atual = ''}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _Traducao(api: api, original: original, atual: atual),
    );

class _Traducao extends StatefulWidget {
  const _Traducao({required this.api, required this.original, required this.atual});

  final ApiArquivos api;
  final String original;
  final String atual;

  @override
  State<_Traducao> createState() => _TraducaoState();
}

class _TraducaoState extends State<_Traducao> {
  late final _campo = TextEditingController(text: widget.atual);
  bool _traduzindo = false;
  String? _erro;

  @override
  void dispose() {
    _campo.dispose();
    super.dispose();
  }

  Future<void> _traduzir() async {
    setState(() {
      _traduzindo = true;
      _erro = null;
    });
    try {
      final r = await widget.api.reescrever(trecho: widget.original, objetivo: 'traduzir');
      _campo.text = (r['texto'] as String? ?? '').trim();
    } on ApiErro catch (e) {
      _erro = e.mensagem;
    } finally {
      if (mounted) setState(() => _traduzindo = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Tradução (português)'),
    content: SizedBox(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          Container(
            constraints: const BoxConstraints(maxHeight: 140),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SingleChildScrollView(child: SelectableText(widget.original)),
          ),
          TextField(
            controller: _campo,
            minLines: 3,
            maxLines: 10,
            enabled: !_traduzindo,
            decoration: const InputDecoration(labelText: 'Tradução', border: OutlineInputBorder()),
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: _traduzindo
                ? const LinearProgressIndicator()
                : Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.translate),
                      label: const Text('Traduzir'),
                      onPressed: _traduzir,
                    ),
                  ),
          ),
          if (_erro != null) Text(_erro!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(onPressed: () => Navigator.pop(context, _campo.text.trim()), child: const Text('Salvar')),
    ],
  );
}
