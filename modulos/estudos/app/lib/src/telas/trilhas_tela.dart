import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_estudos.dart';
import '../modelos_conhecimento.dart';
import 'leituras_tela.dart' show abrirNota;
import 'projetos_tela.dart' show AbrirNoArquivo;

/// Seção Trilhas: a trilha de carreira (Arquiteto de Software) em fases e etapas, cada uma com os
/// capítulos a ler, a prática e a nota da etapa. As frentes (Back-end, Dados, IA…) filtram a mesma
/// trilha. A leitura e os grifos acontecem no leitor dos Arquivos, pelo livro ligado na aba Leituras.
class TrilhasTela extends StatefulWidget {
  const TrilhasTela({super.key, required this.api, this.abrirNoArquivo});

  final ApiEstudos api;
  final AbrirNoArquivo? abrirNoArquivo;

  @override
  State<TrilhasTela> createState() => _TrilhasTelaState();
}

class _TrilhasTelaState extends State<TrilhasTela> {
  ApiEstudos get api => widget.api;
  List<TrilhaConhecimento>? _trilhas;
  TrilhaConhecimento? _trilha;
  List<LivroTrilha>? _estante;
  String? _frente;
  bool _verEstante = false;
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
      if (_trilha == null) {
        setState(() => _erro = '$e');
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _carregar() => _tentar(() async {
    final trilhas = _trilhas ?? await api.trilhasConhecimento();
    if (trilhas.isEmpty) return;
    final id = _trilha?.id ?? trilhas.first.id;
    final t = await api.trilhaConhecimento(id, frente: _frente);
    final estante = _verEstante ? await api.estante() : _estante;
    if (mounted) {
      setState(() {
        _trilhas = trilhas;
        _trilha = t;
        _estante = estante;
        _erro = null;
      });
    }
  });

  Future<void> _marcar(EtapaTrilha e, Map<String, dynamic> dados) => _tentar(() async {
    await api.marcarEtapa(_trilha!.id, e.id, dados);
    await _carregar();
  });

  Future<void> _ligar(LivroTrilha l) => _tentar(() async {
    await api.ligarLeitura(l.id);
    await _carregar();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('“${l.titulo}” está em Leituras: anexe o PDF lá para ler e grifar.')),
      );
    }
  });

  Future<void> _abrirPdf(LeituraLigada l) async {
    final abrir = widget.abrirNoArquivo;
    if (abrir == null || l.arquivoId == null) return;
    await abrir(context, l.arquivoId!, l.paginaAtual < 1 ? 1 : l.paginaAtual);
  }

  Future<void> _nota(EtapaTrilha e) => _tentar(() async {
    var id = e.notaId;
    if (id == null) {
      final t = _trilha!;
      final leituras = [for (final i in e.leituras) '- ${i.livro.titulo} — ${i.capitulos}'].join('\n');
      final nota = await api.notas.criar({
        'titulo': '${t.titulo} — ${e.titulo}',
        'pasta': 'Notas/Estudos/${t.area}/${t.titulo}',
        'tags': ['estudos', 'trilha', for (final f in e.frentes) f.toLowerCase().replaceAll(' ', '-')],
        'propriedades': {'trilha': t.titulo, 'fase': e.fase},
        'corpo':
            '## Objetivo\n${e.objetivo}\n\n## Leituras\n$leituras\n\n## Conceitos\n'
            '${[for (final c in e.conceitos) '- $c'].join('\n')}\n\n## Grifos e ideias\n\n'
            '## Prática\n${e.pratica}\n\n## Entregável\n${e.entregavel}\n\n'
            '## Ligações\n- Área: [[${t.area}]]\n- Trilha: [[${t.titulo}]]\n',
      });
      id = nota.id;
      await api.marcarEtapa(t.id, e.id, {'nota_id': id});
      await _carregar();
    }
    if (mounted) await abrirNota(context, api.notas, id);
  });

  @override
  Widget build(BuildContext context) {
    final t = _trilha;
    if (_erro != null && t == null) {
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
    if (t == null) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _carregar,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Cabecalho(trilha: t, trilhas: _trilhas ?? const [], aoTrocar: (id) {
            _trilha = _trilhas!.firstWhere((x) => x.id == id);
            _carregar();
          }),
          const SizedBox(height: 12),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Trilha'), icon: Icon(Icons.route_outlined)),
              ButtonSegment(value: true, label: Text('Estante'), icon: Icon(Icons.shelves)),
            ],
            selected: {_verEstante},
            onSelectionChanged: (s) {
              setState(() => _verEstante = s.first);
              _carregar();
            },
          ),
          const SizedBox(height: 12),
          if (_verEstante)
            ..._livros()
          else ...[
            if (t.proxima != null) _ProximaCard(proxima: t.proxima!),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ChoiceChip(
                  label: const Text('Todas as frentes'),
                  selected: _frente == null,
                  onSelected: (_) {
                    _frente = null;
                    _carregar();
                  },
                ),
                for (final f in t.frentes)
                  ChoiceChip(
                    label: Text(f),
                    selected: _frente == f,
                    onSelected: (_) {
                      _frente = f;
                      _carregar();
                    },
                  ),
              ],
            ),
            const SizedBox(height: 8),
            ..._etapas(t),
          ],
        ],
      ),
    );
  }

  List<Widget> _etapas(TrilhaConhecimento t) {
    final itens = <Widget>[];
    String? fase;
    for (final e in t.etapas) {
      if (e.fase != fase) {
        fase = e.fase;
        itens.add(
          Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 4),
            child: Text(fase, style: Theme.of(context).textTheme.titleMedium),
          ),
        );
      }
      itens.add(
        _EtapaCard(
          etapa: e,
          aoMarcarLeitura: (i, feita) => _marcar(e, {'leitura': i, 'feita': feita}),
          aoMarcarPratica: (feita) => _marcar(e, {'pratica': feita}),
          aoNota: () => _nota(e),
          aoLigar: _ligar,
          aoAbrirPdf: widget.abrirNoArquivo == null ? null : _abrirPdf,
        ),
      );
    }
    return itens;
  }

  List<Widget> _livros() {
    final estante = _estante;
    if (estante == null) return const [Center(child: CircularProgressIndicator())];
    return [
      for (final l in estante)
        Card(
          child: ListTile(
            leading: Icon(l.tipo == 'doc' ? Icons.public : Icons.menu_book_outlined),
            title: Text(l.titulo),
            subtitle: Text(
              [
                l.autor,
                if (l.original != l.titulo) l.original,
                l.edicao,
                '${l.indicacoes} indicações na trilha',
                if (l.leitura != null) 'em Leituras: ${l.leitura!.status}${l.leitura!.arquivoId != null ? ' · PDF' : ''}',
                if (l.url.isNotEmpty) l.url,
              ].join(' · '),
            ),
            isThreeLine: true,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (l.leitura == null && l.tipo == 'livro')
                  IconButton(
                    tooltip: 'Ligar às Leituras (para anexar o PDF e grifar)',
                    icon: const Icon(Icons.link),
                    onPressed: () => _ligar(l),
                  ),
                Tooltip(
                  message: l.tenho ? 'Na estante' : 'Ainda não tenho',
                  child: Switch(
                    value: l.tenho,
                    onChanged: (v) => _tentar(() async {
                      await api.marcarLivro(l.id, v);
                      await _carregar();
                    }),
                  ),
                ),
              ],
            ),
          ),
        ),
    ];
  }
}

class _Cabecalho extends StatelessWidget {
  const _Cabecalho({required this.trilha, required this.trilhas, required this.aoTrocar});

  final TrilhaConhecimento trilha;
  final List<TrilhaConhecimento> trilhas;
  final ValueChanged<String> aoTrocar;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 6,
      children: [
        if (trilhas.length > 1)
          DropdownButton<String>(
            value: trilha.id,
            items: [for (final t in trilhas) DropdownMenuItem(value: t.id, child: Text('${t.area} · ${t.titulo}'))],
            onChanged: (id) => id == null ? null : aoTrocar(id),
          )
        else
          Text('${trilha.area} · ${trilha.titulo}', style: tema.headlineSmall),
        Text(trilha.descricao),
        LinearProgressIndicator(value: trilha.progresso),
        Text(
          '${trilha.etapasConcluidas} de ${trilha.totalEtapas} etapas concluídas'
          '${trilha.frente == null ? '' : ' em ${trilha.frente}'} · ${(trilha.progresso * 100).round()}%',
          style: tema.bodySmall,
        ),
      ],
    );
  }
}

class _ProximaCard extends StatelessWidget {
  const _ProximaCard({required this.proxima});

  final Proxima proxima;

  @override
  Widget build(BuildContext context) {
    final p = proxima;
    final i = p.indicacao;
    final (icone, titulo, texto) = switch (p.tipo) {
      'leitura' => (Icons.auto_stories, 'Leia agora', '${i!.livro.titulo} — ${i.capitulos}\n${i.foco}'),
      'conseguir' => (
        Icons.shopping_bag_outlined,
        'Próxima leitura (livro que falta na estante)',
        '${i!.livro.titulo} — ${i.capitulos}\n${i.foco}',
      ),
      _ => (Icons.build_outlined, 'Hora da prática', p.pratica),
    };
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: ListTile(
        leading: Icon(icone),
        title: Text('$titulo · ${p.etapa}'),
        subtitle: Text('${p.fase}\n$texto'),
        isThreeLine: true,
      ),
    );
  }
}

class _EtapaCard extends StatelessWidget {
  const _EtapaCard({
    required this.etapa,
    required this.aoMarcarLeitura,
    required this.aoMarcarPratica,
    required this.aoNota,
    required this.aoLigar,
    this.aoAbrirPdf,
  });

  final EtapaTrilha etapa;
  final void Function(int indice, bool feita) aoMarcarLeitura;
  final ValueChanged<bool> aoMarcarPratica;
  final VoidCallback aoNota;
  final ValueChanged<LivroTrilha> aoLigar;
  final ValueChanged<LeituraLigada>? aoAbrirPdf;

  @override
  Widget build(BuildContext context) {
    final e = etapa;
    final tema = Theme.of(context);
    return Card(
      child: ExpansionTile(
        leading: e.concluida
            ? Icon(Icons.check_circle, color: tema.colorScheme.primary)
            : SizedBox.square(dimension: 28, child: CircularProgressIndicator(value: e.progresso, strokeWidth: 3)),
        title: Text(e.titulo),
        subtitle: Text(e.frentes.join(' · ')),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(e.objetivo),
          const SizedBox(height: 8),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [for (final c in e.conceitos) Chip(label: Text(c), visualDensity: VisualDensity.compact)],
          ),
          const SizedBox(height: 8),
          Text('Leituras', style: tema.textTheme.titleSmall),
          for (final i in e.leituras)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Checkbox(value: i.feita != null, onChanged: (v) => aoMarcarLeitura(i.indice, v ?? false)),
              title: Text('${i.livro.titulo} — ${i.capitulos}'),
              subtitle: Text(
                [
                  i.foco,
                  if (!i.livro.tenho) 'Ainda não está na sua estante',
                  if (i.livro.url.isNotEmpty) i.livro.url,
                  if (i.feita != null) 'Lido em ${i.feita}',
                ].join('\n'),
              ),
              trailing: switch (i.livro.leitura) {
                final LeituraLigada l when l.arquivoId != null && aoAbrirPdf != null => IconButton(
                  tooltip: 'Abrir o PDF para ler e grifar',
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  onPressed: () => aoAbrirPdf!(l),
                ),
                null when i.livro.tipo == 'livro' => IconButton(
                  tooltip: 'Ligar às Leituras (para anexar o PDF e grifar)',
                  icon: const Icon(Icons.link),
                  onPressed: () => aoLigar(i.livro),
                ),
                _ => null,
              },
            ),
          const SizedBox(height: 4),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: e.praticaFeita != null,
            onChanged: (v) => aoMarcarPratica(v ?? false),
            title: const Text('Prática'),
            subtitle: Text('${e.pratica}\nEntregável: ${e.entregavel}'),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: aoNota,
              icon: Icon(e.notaId == null ? Icons.note_add_outlined : Icons.sticky_note_2_outlined),
              label: Text(e.notaId == null ? 'Criar nota da etapa' : 'Abrir nota da etapa'),
            ),
          ),
        ],
      ),
    );
  }
}
