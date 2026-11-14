import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_concursos.dart';
import '../modelos.dart';

const _letras = ['A', 'B', 'C', 'D', 'E'];

/// Aba Simulados do concurso: gerar (geral ou por disciplina, pelo Claude no estilo da banca),
/// resolver, ver a correção comentada e o desempenho por disciplina.
class SimuladosAba extends StatelessWidget {
  const SimuladosAba({super.key, required this.api, required this.concurso});

  final ApiConcursos api;
  final Concurso concurso;

  Future<void> _novo(BuildContext context, Future<void> Function() recarregar) async {
    final pedido = await showDialog<(int, String)>(
      context: context,
      builder: (_) => _NovoSimulado(disciplinas: [for (final d in concurso.disciplinas) d.nome]),
    );
    if (pedido == null) return;
    try {
      await api.novoSimulado(concurso.id, pedido.$1, disciplina: pedido.$2);
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
    await recarregar();
  }

  @override
  Widget build(BuildContext context) {
    if (concurso.estrutura == null) return const Center(child: Text('Gere o plano para criar simulados.'));
    return Sondagem<(List<Simulado>, Doc)>(
      intervalo: const Duration(seconds: 8),
      carregar: () => api.simulados(concurso.id),
      construir: (context, dados, recarregar) {
        final (lista, desempenho) = dados;
        final tema = Theme.of(context);
        final discs = [for (final d in desempenho['disciplinas'] as List) d as Doc];
        return Scaffold(
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _novo(context, recarregar),
            icon: const Icon(Icons.add_task),
            label: const Text('Novo simulado'),
          ),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              if (discs.isNotEmpty) ...[
                ListTile(title: Text('Desempenho por disciplina', style: tema.textTheme.titleMedium), subtitle: const Text('Meta: 60% (nota mínima do edital)')),
                for (final d in discs)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Row(children: [
                      Expanded(flex: 3, child: Text(d['disciplina'] as String, overflow: TextOverflow.ellipsis)),
                      Expanded(
                        flex: 4,
                        child: LinearProgressIndicator(
                          value: (d['pct'] as int) / 100,
                          minHeight: 8,
                          borderRadius: BorderRadius.circular(4),
                          color: (d['pct'] as int) >= 60 ? Colors.green : tema.colorScheme.error,
                        ),
                      ),
                      SizedBox(width: 72, child: Text('  ${d['pct']}% (${d['acertos']}/${d['total']})', style: tema.textTheme.bodySmall)),
                    ]),
                  ),
                const Divider(height: 32),
              ],
              if (lista.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'Nenhum simulado ainda. O Claude cria questões inéditas no estilo da banca, na proporção do edital, '
                    'dando preferência ao que você já estudou. Para provas reais anteriores, veja a aba Materiais.',
                    textAlign: TextAlign.center,
                  ),
                ),
              for (final s in lista)
                ListTile(
                  leading: switch (s.estado) {
                    'gerando' => const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2)),
                    'erro' => Icon(Icons.error_outline, color: tema.colorScheme.error),
                    _ when s.respondido => CircleAvatar(
                      backgroundColor: (s.resultado!['aprovado'] as bool) ? Colors.green : tema.colorScheme.error,
                      child: Text('${s.resultado!['pct']}', style: const TextStyle(color: Colors.white, fontSize: 13)),
                    ),
                    _ => const Icon(Icons.play_circle_outline),
                  },
                  title: Text(s.titulo),
                  subtitle: Text(switch (s.estado) {
                    'gerando' => 'O Claude está elaborando as questões…',
                    'erro' => s.erro,
                    _ when s.respondido =>
                      '${s.resultado!['acertos']}/${s.resultado!['total']} acertos · ${duracao((s.resultado!['segundos'] as int) / 3600)}',
                    _ => '${s.questoes.length} questões · ${s.minutos} min',
                  }),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      await api.excluirSimulado(concurso.id, s.id);
                      await recarregar();
                    },
                  ),
                  onTap: s.estado != 'pronto'
                      ? null
                      : () async {
                          await abrirTela<void>(context, (_) => ResolverSimulado(api: api, concursoId: concurso.id, simulado: s), titulo: s.titulo);
                          await recarregar();
                        },
                ),
            ],
          ),
        );
      },
    );
  }
}

class _NovoSimulado extends StatefulWidget {
  const _NovoSimulado({required this.disciplinas});

  final List<String> disciplinas;

  @override
  State<_NovoSimulado> createState() => _NovoSimuladoState();
}

class _NovoSimuladoState extends State<_NovoSimulado> {
  int _n = 20;
  String _disc = '';

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Novo simulado'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DropdownButtonFormField<String>(
          initialValue: _disc,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Conteúdo'),
          items: [
            const DropdownMenuItem(value: '', child: Text('Geral (proporção do edital)')),
            for (final d in widget.disciplinas) DropdownMenuItem(value: d, child: Text(d, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) => setState(() => _disc = v ?? ''),
        ),
        const SizedBox(height: 12),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 10, label: Text('10')),
            ButtonSegment(value: 20, label: Text('20')),
            ButtonSegment(value: 30, label: Text('30')),
            ButtonSegment(value: 60, label: Text('60 (prova)')),
          ],
          selected: {_n},
          onSelectionChanged: (s) => setState(() => _n = s.first),
        ),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(onPressed: () => Navigator.pop(context, (_n, _disc)), child: const Text('Gerar')),
    ],
  );
}

/// Resolve um simulado com cronômetro; ao entregar, mostra o gabarito comentado.
class ResolverSimulado extends StatefulWidget {
  const ResolverSimulado({super.key, required this.api, required this.concursoId, required this.simulado});

  final ApiConcursos api;
  final String concursoId;
  final Simulado simulado;

  @override
  State<ResolverSimulado> createState() => _ResolverSimuladoState();
}

class _ResolverSimuladoState extends State<ResolverSimulado> {
  late Simulado _s = widget.simulado;
  late final List<int?> _resp = List.of(widget.simulado.respostas ?? List<int?>.filled(widget.simulado.questoes.length, null));
  final _relogio = Stopwatch()..start();
  Timer? _tique;
  bool _enviando = false;

  @override
  void initState() {
    super.initState();
    _tique = Timer.periodic(const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _tique?.cancel();
    super.dispose();
  }

  Future<void> _entregar() async {
    final brancos = _resp.where((r) => r == null).length;
    if (brancos > 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          content: Text('$brancos questão(ões) em branco. Entregar assim mesmo?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Voltar')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Entregar')),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _enviando = true);
    try {
      final r = await widget.api.responder(widget.concursoId, _s.id, _resp, _relogio.elapsed.inSeconds);
      _relogio.stop();
      _tique?.cancel();
      setState(() => _s = r);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final corrigido = _s.respondido;
    final decorrido = _relogio.elapsed;
    final limite = Duration(minutes: _s.minutos);
    final estourou = !corrigido && decorrido > limite;
    final r = _s.resultado;
    return Scaffold(
      appBar: AppBar(
        title: Text(_s.titulo),
        actions: [
          if (!corrigido)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: Text(
                  '${decorrido.inMinutes}:${(decorrido.inSeconds % 60).toString().padLeft(2, '0')} / ${_s.minutos} min',
                  style: TextStyle(color: estourou ? tema.colorScheme.error : null, fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: corrigido
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton.icon(
                  onPressed: _enviando ? null : _entregar,
                  icon: const Icon(Icons.send),
                  label: Text('Entregar (${_resp.where((x) => x != null).length}/${_resp.length} respondidas)'),
                ),
              ),
            ),
      body: LarguraMaxima(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (r != null)
              Card(
                color: (r['aprovado'] as bool) ? Colors.green.withValues(alpha: .12) : tema.colorScheme.errorContainer,
                child: ListTile(
                  leading: Icon((r['aprovado'] as bool) ? Icons.emoji_events : Icons.trending_up, size: 36),
                  title: Text('${r['acertos']}/${r['total']} acertos · ${r['pct']}%', style: tema.textTheme.titleLarge),
                  subtitle: Text(
                    '${(r['aprovado'] as bool) ? 'Acima' : 'Abaixo'} dos 60% exigidos · ${r['em_branco']} em branco · '
                    '${duracao((r['segundos'] as int) / 3600)}',
                  ),
                ),
              ),
            for (final (i, q) in _s.questoes.indexed)
              Card(
                margin: const EdgeInsets.symmetric(vertical: 8),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Questão ${q.n} · ${q.disciplina}${q.topico.isEmpty ? '' : ' — ${q.topico}'}', style: tema.textTheme.labelMedium),
                      const SizedBox(height: 8),
                      SelectableText(q.enunciado, style: tema.textTheme.bodyLarge),
                      const SizedBox(height: 8),
                      for (final (a, alt) in q.alternativas.indexed)
                        _Alternativa(
                          letra: _letras[a],
                          texto: alt,
                          marcada: _resp[i] == a,
                          certa: corrigido ? q.correta == a : null,
                          aoTocar: corrigido ? null : () => setState(() => _resp[i] = _resp[i] == a ? null : a),
                        ),
                      if (corrigido && (q.comentario ?? '').isNotEmpty) ...[
                        const Divider(),
                        Text('Comentário', style: tema.textTheme.labelLarge),
                        SelectableText(q.comentario!),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Alternativa extends StatelessWidget {
  const _Alternativa({required this.letra, required this.texto, required this.marcada, required this.certa, required this.aoTocar});

  final String letra, texto;
  final bool marcada;
  final bool? certa;
  final VoidCallback? aoTocar;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final cor = certa == true
        ? Colors.green
        : (certa == false && marcada)
        ? tema.colorScheme.error
        : marcada
        ? tema.colorScheme.primary
        : tema.colorScheme.outlineVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: aoTocar,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: cor, width: marcada || certa == true ? 2 : 1),
            color: marcada || certa == true ? cor.withValues(alpha: .08) : null,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 13,
                backgroundColor: marcada || certa == true ? cor : tema.colorScheme.surfaceContainerHighest,
                child: Text(letra, style: TextStyle(fontSize: 12, color: marcada || certa == true ? Colors.white : null)),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(texto)),
            ],
          ),
        ),
      ),
    );
  }
}

const _iconeMaterial = {
  'prova': Icons.assignment,
  'questoes': Icons.quiz_outlined,
  'apostila': Icons.menu_book,
  'video': Icons.smart_display_outlined,
  'resumo': Icons.notes,
  'edital': Icons.gavel,
};

/// Aba Materiais: provas anteriores da banca, questões, apostilas e vídeos achados na web pela LLM local.
class MateriaisAba extends StatelessWidget {
  const MateriaisAba({super.key, required this.api, required this.concurso});

  final ApiConcursos api;
  final Concurso concurso;

  @override
  Widget build(BuildContext context) => Sondagem<(String, List<MaterialEstudo>)>(
    intervalo: const Duration(seconds: 8),
    carregar: () => api.materiais(concurso.id),
    construir: (context, dados, recarregar) {
      final (estado, itens) = dados;
      final grupos = <String, List<MaterialEstudo>>{};
      for (final m in itens) {
        grupos.putIfAbsent(m.tipo, () => []).add(m);
      }
      const nomes = {
        'prova': 'Provas anteriores', 'questoes': 'Questões', 'apostila': 'Apostilas e PDFs', 'video': 'Vídeos',
        'resumo': 'Resumos', 'edital': 'Editais', 'outro': 'Outros',
      };
      return ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          ListTile(
            title: const Text('Provas antigas da banca e materiais'),
            subtitle: Text(estado == 'buscando'
                ? 'Buscando na web e classificando com a LLM local…'
                : 'Busca na web (DuckDuckGo) filtrada pela LLM local para ${concurso.banca.isEmpty ? 'este concurso' : 'a ${concurso.banca}'}.'),
            trailing: estado == 'buscando'
                ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
                : FilledButton.tonalIcon(
                    onPressed: () async {
                      await api.buscarMateriais(concurso.id);
                      await recarregar();
                    },
                    icon: const Icon(Icons.travel_explore),
                    label: Text(itens.isEmpty ? 'Buscar' : 'Buscar de novo'),
                  ),
          ),
          for (final tipo in nomes.keys.where(grupos.containsKey)) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(nomes[tipo]!, style: Theme.of(context).textTheme.titleSmall),
            ),
            for (final m in grupos[tipo]!)
              ListTile(
                leading: Icon(_iconeMaterial[m.tipo] ?? Icons.link),
                title: Text(m.titulo, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text([if (m.disciplina.isNotEmpty) m.disciplina, m.descricao].join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: const Icon(Icons.open_in_new, size: 18),
                onTap: () => abrirLink(context, m.url),
              ),
          ],
        ],
      );
    },
  );
}
