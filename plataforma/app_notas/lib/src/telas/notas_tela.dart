import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_notas.dart';
import '../controlador.dart';
import '../modelos.dart';
import 'editor_nota.dart';
import 'painel_analise.dart';
import 'painel_relacoes.dart';

/// Tela do módulo Notas.
/// - PC (≥ 1100): lista | editor | relações.
/// - Tablet (≥ 700): lista | editor com abas Escrever/Relações.
/// - Celular: lista; a nota (e a análise) abrem em página própria.
class NotasTela extends StatefulWidget {
  const NotasTela({super.key, required this.api});

  final ApiNotas api;

  @override
  State<NotasTela> createState() => _NotasTelaState();
}

class _NotasTelaState extends State<NotasTela> {
  late final _aberta = NotaAberta(widget.api);
  bool _analise = false;

  @override
  void initState() {
    super.initState();
    _aberta.addListener(_atualizarTitulo);
  }

  /// A aba do app mostra o título da nota aberta.
  void _atualizarTitulo() {
    if (mounted) TituloAba.definir(context, _aberta.nota?.titulo);
  }

  @override
  void dispose() {
    _aberta.removeListener(_atualizarTitulo);
    _aberta.dispose();
    super.dispose();
  }

  Future<void> _abrir(String id, bool compacto) async {
    setState(() => _analise = false);
    final abrindo = _aberta.abrir(id);
    if (compacto) await _paginaNota();
    return abrindo;
  }

  Future<void> _nova(bool compacto) async {
    final dados = await _dialogoNova(context, widget.api);
    if (dados == null) return;
    setState(() => _analise = false);
    final criando = _aberta.criar(dados);
    if (compacto) await _paginaNota();
    return criando;
  }

  Future<void> _paginaNota() => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Nota')),
        body: EditorNota(aberta: _aberta, comAbas: true),
      ),
    ),
  );

  void _mostrarAnalise(bool compacto) {
    if (!compacto) return setState(() => _analise = !_analise);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (c) => Scaffold(
          appBar: AppBar(title: const Text('Análise das notas')),
          body: PainelAnalise(
            api: widget.api,
            aoAbrir: (id) {
              Navigator.pop(c);
              _abrir(id, true);
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final compacto = c.maxWidth < 700;
      final lista = _ListaNotas(
        aberta: _aberta,
        analise: _analise,
        aoAbrir: (id) => _abrir(id, compacto),
        aoCriar: () => _nova(compacto),
        aoAnalisar: () => _mostrarAnalise(compacto),
      );
      if (compacto) return lista;
      final centro = _analise
          ? PainelAnalise(key: ValueKey(_aberta.versao), api: widget.api, aoAbrir: (id) => _abrir(id, false))
          : EditorNota(aberta: _aberta, comAbas: c.maxWidth < 1100);
      return Row(
        children: [
          SizedBox(width: c.maxWidth < 1100 ? 280 : 320, child: lista),
          const VerticalDivider(width: 1),
          Expanded(child: LarguraMaxima(largura: 1100, child: centro)),
          if (c.maxWidth >= 1100 && !_analise) ...[
            const VerticalDivider(width: 1),
            SizedBox(width: 340, child: PainelRelacoes(aberta: _aberta)),
          ],
        ],
      );
    },
  );
}

class _ListaNotas extends StatefulWidget {
  const _ListaNotas({
    required this.aberta,
    required this.analise,
    required this.aoAbrir,
    required this.aoCriar,
    required this.aoAnalisar,
  });

  final NotaAberta aberta;
  final bool analise;
  final void Function(String id) aoAbrir;
  final VoidCallback aoCriar, aoAnalisar;

  @override
  State<_ListaNotas> createState() => _ListaNotasState();
}

class _ListaNotasState extends State<_ListaNotas> {
  String _q = '';
  String? _tipo;
  int _versao = -1;
  late Future<List<NotaResumo>> _notas;
  List<TipoNota> _tipos = [];

  ApiNotas get _api => widget.aberta.api;

  @override
  void initState() {
    super.initState();
    widget.aberta.addListener(_talvezRecarregar);
    _api.tipos().then((t) => mounted ? setState(() => _tipos = t) : null, onError: (_) {});
    _versao = widget.aberta.versao;
    _notas = _api.listar(q: _q, tipo: _tipo);
  }

  @override
  void dispose() {
    widget.aberta.removeListener(_talvezRecarregar);
    super.dispose();
  }

  void _talvezRecarregar({bool forcar = false}) {
    if (!forcar && _versao == widget.aberta.versao) return setState(() {});
    _versao = widget.aberta.versao;
    setState(() {
      _notas = _api.listar(q: _q, tipo: _tipo);
    });
  }

  @override
  Widget build(BuildContext context) {
    final selecionada = widget.aberta.nota?.id;
    return Column(
      children: [
        FiltrosRecolhiveis(
          chave: 'notas.lista',
          resumo: [?_tipos.where((t) => t.id == _tipo).firstOrNull?.nome, if (_q.isNotEmpty) '"$_q"'].join(' · '),
          children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            spacing: 4,
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Buscar', isDense: true),
                  onChanged: (q) {
                    _q = q;
                    _talvezRecarregar(forcar: true);
                  },
                ),
              ),
              IconButton(
                tooltip: 'Análise',
                isSelected: widget.analise,
                icon: const Icon(Icons.insights_outlined),
                onPressed: widget.aoAnalisar,
              ),
              IconButton.filledTonal(tooltip: 'Nova nota', icon: const Icon(Icons.add), onPressed: widget.aoCriar),
            ],
          ),
        ),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final t in [null, ..._tipos])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(t?.nome ?? 'Todas'),
                    selected: _tipo == t?.id,
                    onSelected: (_) {
                      _tipo = t?.id;
                      _talvezRecarregar(forcar: true);
                    },
                  ),
                ),
            ],
          ),
        ),
          ],
        ),
        ListenableBuilder(
          listenable: Listenable.merge([_api.offline, _api.pendencias, _api.avisos]),
          builder: (context, _) {
            final avisos = _api.avisos.value;
            if (!_api.offline.value && _api.pendencias.value == 0 && avisos.isEmpty) return const SizedBox();
            return MaterialBanner(
              leading: Icon(_api.offline.value ? Icons.cloud_off : Icons.cloud_sync_outlined),
              content: Text(
                [
                  if (_api.offline.value) 'Sem conexão: lendo e salvando as notas do aparelho.',
                  if (_api.pendencias.value > 0) '${_api.pendencias.value} alteração(ões) esperando para subir.',
                  ...avisos,
                ].join('\n'),
              ),
              actions: [
                if (avisos.isNotEmpty) TextButton(onPressed: () => _api.avisos.value = [], child: const Text('Ok')),
                TextButton(
                  onPressed: () {
                    final mensagens = ScaffoldMessenger.of(context);
                    _api.sincronizar().then(
                      (_) => _talvezRecarregar(forcar: true),
                      onError: (Object e) => mensagens.showSnackBar(SnackBar(content: Text('$e'))),
                    );
                  },
                  child: const Text('Sincronizar'),
                ),
              ],
            );
          },
        ),
        Expanded(
          child: FutureBuilder(
            future: _notas,
            builder: (context, snap) {
              if (snap.hasError) {
                return Center(
                  child: Padding(padding: const EdgeInsets.all(16), child: Text('${snap.error}')),
                );
              }
              final notas = snap.data;
              if (notas == null) return const Center(child: CircularProgressIndicator());
              if (notas.isEmpty) return const Center(child: Text('Nenhuma nota'));
              // agrupa por tipo, na ordem dos chips (Tarefa, Meta...); cabeçalho = String, nota = NotaResumo
              final ordem = [for (final t in _tipos) t.id];
              final nomes = {for (final t in _tipos) t.id: t.nome};
              final grupos = <String, List<NotaResumo>>{};
              for (final n in notas) {
                // tipos do vault que o app não conhece (roteiro, moc...) entram em Nota
                (grupos[nomes.containsKey(n.tipo) ? n.tipo : 'nota'] ??= []).add(n);
              }
              final chaves = grupos.keys.toList()
                ..sort((a, b) => (ordem.indexOf(a) % 999).compareTo(ordem.indexOf(b) % 999));
              final itens = <Object>[
                for (final k in chaves) ...[
                  if (_tipo == null) k,
                  ...grupos[k]!,
                ],
              ];
              return RefreshIndicator(
                onRefresh: () async => _talvezRecarregar(forcar: true),
                child: ListView.builder(
                  itemCount: itens.length,
                  itemBuilder: (context, i) {
                    final n = itens[i];
                    if (n is String) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Row(
                          spacing: 8,
                          children: [
                            Icon(iconeDoTipo(n), size: 16, color: Theme.of(context).colorScheme.primary),
                            Text(
                              '${nomes[n] ?? n} (${grupos[n]!.length})',
                              style: Theme.of(context).textTheme.labelLarge
                                  ?.copyWith(color: Theme.of(context).colorScheme.primary),
                            ),
                          ],
                        ),
                      );
                    }
                    n as NotaResumo;
                    final atrasada = n.prazo != null && n.prazo!.isBefore(DateTime.now()) && n.status != null;
                    return ListTile(
                      selected: n.id == selecionada,
                      leading: Icon(iconeDoTipo(n.tipo)),
                      title: Text(n.titulo, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        [n.status, if (n.prazo != null) dataCurta(n.prazo), if (n.entradas > 0) '${n.entradas} ←']
                            .nonNulls
                            .join(' · '),
                        style: atrasada ? TextStyle(color: Theme.of(context).colorScheme.error) : null,
                      ),
                      onTap: () => widget.aoAbrir(n.id),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Pergunta o tipo e o título; devolve os dados de criação (com o modelo de texto do tipo).
Future<Map<String, dynamic>?> _dialogoNova(BuildContext context, ApiNotas api) async {
  final tipos = await api.tipos().catchError((_) => <TipoNota>[]);
  if (!context.mounted) return null;
  final titulo = TextEditingController();
  var tipo = tipos.isEmpty ? null : tipos.first;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: const Text('Nova nota'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final t in tipos)
                  ChoiceChip(
                    avatar: Icon(iconeDoTipo(t.id), size: 16),
                    label: Text(t.nome),
                    selected: tipo == t,
                    onSelected: (_) => set(() => tipo = t),
                  ),
              ],
            ),
            TextField(
              controller: titulo,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Título'),
              onSubmitted: (_) => Navigator.pop(c, true),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Criar')),
        ],
      ),
    ),
  );
  final t = titulo.text.trim();
  titulo.dispose();
  if (ok != true || t.isEmpty) return null;
  return {'titulo': t, 'tipo': tipo?.id ?? 'nota', 'corpo': tipo?.modelo ?? ''};
}
