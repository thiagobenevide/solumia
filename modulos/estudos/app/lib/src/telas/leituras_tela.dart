import 'package:agent_core/agent_core.dart';
import 'package:agent_notas/agent_notas.dart';
import 'package:flutter/material.dart';

import '../api_estudos.dart';
import '../modelos.dart';

/// Abre a nota [id] no editor de notas, numa página por cima do módulo.
Future<void> abrirNota(BuildContext context, ApiNotas api, String id) {
  final aberta = NotaAberta(api)..abrir(id);
  return abrirTela(context, (_) => Scaffold(
        appBar: AppBar(title: const Text('Nota')),
        body: EditorNota(aberta: aberta),
      ));
}

/// Livros e artigos por área e status; cada um tem a sua nota de síntese (Markdown no vault),
/// que liga à nota da área e entra no grafo do conhecimento.
class LeiturasTela extends StatefulWidget {
  const LeiturasTela({super.key, required this.api, required this.opcoes});

  final ApiEstudos api;
  final Opcoes opcoes;

  @override
  State<LeiturasTela> createState() => _LeiturasTelaState();
}

class _LeiturasTelaState extends State<LeiturasTela> {
  ApiEstudos get api => widget.api;
  List<Leitura>? _leituras;
  String? _area;
  String? _erro;

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Future<void> _tentar(Future<void> Function() acao) async {
    try {
      await acao();
    } on ApiErro catch (e) {
      if (!mounted) return;
      if (_leituras == null) {
        setState(() => _erro = '$e');
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _carregar() => _tentar(() async {
    final l = await api.leituras();
    if (mounted) {
      setState(() {
        _leituras = l;
        _erro = null;
      });
    }
  });

  Future<void> _formulario([Leitura? atual]) async {
    final dados = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _FormularioLeitura(opcoes: widget.opcoes, atual: atual, areaInicial: _area),
    );
    if (dados == null) return;
    await _tentar(() async {
      atual == null ? await api.criarLeitura(dados) : await api.editarLeitura(atual.id, dados);
      await _carregar();
    });
  }

  Future<void> _sintese(Leitura l) => _tentar(() async {
    var id = l.notaId;
    if (id == null) {
      final nota = await api.notas.criar({
        'titulo': l.titulo,
        'tags': ['estudos', l.area.toLowerCase()],
        'propriedades': {'autor': l.autor, 'tipo_leitura': l.tipo},
        'corpo':
            '## Ideias principais\n\n## Citações\n\n## Como aplico\n\n## Ligações\n- Área: [[${l.area}]]\n',
      });
      id = nota.id;
      await api.editarLeitura(l.id, {'nota_id': id});
      await _carregar();
    }
    if (mounted) await abrirNota(context, api.notas, id);
  });

  Future<void> _progresso(Leitura l) async {
    final c = TextEditingController(text: '${l.paginaAtual}');
    final pagina = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.titulo),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: 'Página atual', suffixText: l.paginas == null ? null : 'de ${l.paginas}'),
          onSubmitted: (v) => Navigator.pop(context, int.tryParse(v)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, int.tryParse(c.text)), child: const Text('Salvar')),
        ],
      ),
    );
    if (pagina == null) return;
    final fim = l.paginas != null && pagina >= l.paginas!;
    await _tentar(() async {
      await api.editarLeitura(l.id, {
        'pagina_atual': pagina,
        if (fim) 'status': 'lido' else if (l.status == 'quero ler' && pagina > 0) 'status': 'lendo',
      });
      await _carregar();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_erro != null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, spacing: 12, children: [Text(_erro!), FilledButton(onPressed: _carregar, child: const Text('Tentar de novo'))]));
    }
    final todas = _leituras;
    if (todas == null) return const Center(child: CircularProgressIndicator());
    final lista = [for (final l in todas) if (_area == null || l.area == _area) l];
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _formulario,
        icon: const Icon(Icons.add),
        label: const Text('Leitura'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(8),
            child: Row(
              spacing: 6,
              children: [
                ChoiceChip(label: Text('Todas (${todas.length})'), selected: _area == null, onSelected: (_) => setState(() => _area = null)),
                for (final a in widget.opcoes.areas)
                  ChoiceChip(
                    label: Text('$a (${todas.where((l) => l.area == a).length})'),
                    selected: _area == a,
                    onSelected: (_) => setState(() => _area = a),
                  ),
              ],
            ),
          ),
          Expanded(
            child: lista.isEmpty
                ? const Center(child: Text('Nenhuma leitura. Adicione um livro ou artigo.'))
                : RefreshIndicator(
                    onRefresh: _carregar,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 88),
                      children: [
                        for (final status in const ['lendo', 'quero ler', 'lido'])
                          if (lista.any((l) => l.status == status)) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
                              child: Text(status.toUpperCase(), style: Theme.of(context).textTheme.labelLarge),
                            ),
                            for (final l in lista.where((l) => l.status == status)) _cartao(l),
                          ],
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _cartao(Leitura l) {
    final tema = Theme.of(context);
    return Card(
      child: InkWell(
        onTap: () => _progresso(l),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            children: [
              Icon(l.tipo == 'artigo' ? Icons.article_outlined : Icons.menu_book_outlined, size: 32),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: [
                    Text(l.titulo, style: tema.textTheme.titleSmall),
                    Text([l.autor, l.area].where((t) => t.isNotEmpty).join(' · '), style: tema.textTheme.bodySmall),
                    if (l.progresso != null) ...[
                      const SizedBox(height: 4),
                      LinearProgressIndicator(value: l.progresso),
                      Text('${l.paginaAtual} de ${l.paginas} páginas', style: tema.textTheme.labelSmall),
                    ],
                  ],
                ),
              ),
              IconButton(
                tooltip: l.notaId == null ? 'Criar nota de síntese' : 'Abrir nota de síntese',
                icon: Icon(l.notaId == null ? Icons.note_add_outlined : Icons.sticky_note_2_outlined),
                onPressed: () => _sintese(l),
              ),
              PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'editar') return _formulario(l);
                  if (v.startsWith('status:')) {
                    return _tentar(() async {
                      await api.editarLeitura(l.id, {'status': v.substring(7)});
                      await _carregar();
                    });
                  }
                  await _tentar(() async {
                    await api.excluirLeitura(l.id);
                    await _carregar();
                  });
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'editar', child: Text('Editar')),
                  for (final s in widget.opcoes.status)
                    if (s != l.status) PopupMenuItem(value: 'status:$s', child: Text('Marcar "$s"')),
                  const PopupMenuItem(value: 'excluir', child: Text('Excluir (a nota fica)')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FormularioLeitura extends StatefulWidget {
  const _FormularioLeitura({required this.opcoes, this.atual, this.areaInicial});

  final Opcoes opcoes;
  final Leitura? atual;
  final String? areaInicial;

  @override
  State<_FormularioLeitura> createState() => _FormularioLeituraState();
}

class _FormularioLeituraState extends State<_FormularioLeitura> {
  late final _titulo = TextEditingController(text: widget.atual?.titulo);
  late final _autor = TextEditingController(text: widget.atual?.autor);
  late final _paginas = TextEditingController(text: widget.atual?.paginas?.toString() ?? '');
  late final _url = TextEditingController(text: widget.atual?.url);
  late String _tipo = widget.atual?.tipo ?? 'livro';
  late String _area = widget.atual?.area ?? widget.areaInicial ?? widget.opcoes.areas.first;
  late String _status = widget.atual?.status ?? 'quero ler';

  @override
  void dispose() {
    for (final c in [_titulo, _autor, _paginas, _url]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.atual == null ? 'Nova leitura' : 'Editar leitura'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 10,
          children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'livro', icon: Icon(Icons.menu_book_outlined), label: Text('Livro')),
                ButtonSegment(value: 'artigo', icon: Icon(Icons.article_outlined), label: Text('Artigo')),
              ],
              selected: {_tipo},
              onSelectionChanged: (s) => setState(() => _tipo = s.first),
            ),
            TextField(controller: _titulo, autofocus: true, decoration: const InputDecoration(labelText: 'Título')),
            TextField(controller: _autor, decoration: const InputDecoration(labelText: 'Autor')),
            DropdownButtonFormField<String>(
              initialValue: _area,
              decoration: const InputDecoration(labelText: 'Área'),
              items: [for (final a in widget.opcoes.areas) DropdownMenuItem(value: a, child: Text(a))],
              onChanged: (v) => setState(() => _area = v!),
            ),
            DropdownButtonFormField<String>(
              initialValue: _status,
              decoration: const InputDecoration(labelText: 'Status'),
              items: [for (final s in widget.opcoes.status) DropdownMenuItem(value: s, child: Text(s))],
              onChanged: (v) => setState(() => _status = v!),
            ),
            TextField(
              controller: _paginas,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Páginas (opcional)'),
            ),
            TextField(controller: _url, decoration: const InputDecoration(labelText: 'Link (opcional)')),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(
        onPressed: () {
          if (_titulo.text.trim().isEmpty) return;
          Navigator.pop(context, {
            'titulo': _titulo.text.trim(),
            'autor': _autor.text.trim(),
            'tipo': _tipo,
            'area': _area,
            'status': _status,
            'paginas': int.tryParse(_paginas.text),
            'url': _url.text.trim(),
          });
        },
        child: const Text('Salvar'),
      ),
    ],
  );
}
