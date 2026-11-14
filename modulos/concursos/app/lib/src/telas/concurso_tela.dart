import 'package:agent_core/agent_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api_concursos.dart';
import '../modelos.dart';
import 'radar_tela.dart' show corDistancia;
import 'simulados_tela.dart';

const _iconeTipo = {
  'conteudo': Icons.menu_book_outlined,
  'revisao': Icons.replay,
  'simulado': Icons.timer_outlined,
  'discursiva': Icons.edit_note,
  'final': Icons.flag_outlined,
};

/// Um concurso: o que estudar hoje (e o atrasado), o cronograma por semana até a prova, o fluxo do
/// conhecimento (disciplinas → tópicos na ordem do Claude) e os prazos do edital.
class ConcursoTela extends StatefulWidget {
  const ConcursoTela({super.key, required this.api, required this.id});

  final ApiConcursos api;
  final String id;

  @override
  State<ConcursoTela> createState() => _ConcursoTelaState();
}

class _ConcursoTelaState extends State<ConcursoTela> {
  ApiConcursos get api => widget.api;

  Future<void> _acao(Future<void> Function() f, Future<void> Function() recarregar) async {
    try {
      await f();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
    await recarregar();
  }

  Future<void> _novoEdital(Future<void> Function() recarregar) async {
    final r = await FilePicker.pickFiles(dialogTitle: 'Edital (PDF)', type: FileType.custom, allowedExtensions: ['pdf']);
    if (r.isEmpty) return;
    final bytes = await r.first.xFile.readAsBytes();
    await _acao(() => api.enviarEdital(widget.id, r.first.name, bytes), recarregar);
  }

  Future<void> _excluir() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Excluir concurso?'),
        content: const Text('Apaga o edital, o plano e as tarefas.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Excluir')),
        ],
      ),
    );
    if (ok != true) return;
    await api.excluir(widget.id);
    if (mounted) Navigator.maybePop(context);
  }

  @override
  Widget build(BuildContext context) => Sondagem<Concurso>(
    intervalo: const Duration(seconds: 10),
    carregar: () => api.obter(widget.id),
    construir: (context, c, recarregar) => DefaultTabController(
      length: 6,
      child: Scaffold(
        appBar: AppBar(
          title: Text(c.nome),
          actions: [
            if (c.estado == 'pronto')
              IconButton(
                tooltip: 'Replanejar: redistribuir o que não foi feito de hoje até a prova',
                icon: const Icon(Icons.event_repeat),
                onPressed: () => _acao(() => api.replanejar(c.id), recarregar),
              ),
            PopupMenuButton<String>(
              onSelected: (v) => switch (v) {
                'gerar' => _acao(() => api.gerarPlano(c.id), recarregar),
                'edital' => _novoEdital(recarregar),
                _ => _excluir(),
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'gerar', enabled: !c.gerando && c.editalNome != null, child: const Text('Gerar o plano de novo (Claude)')),
                const PopupMenuItem(value: 'edital', child: Text('Trocar o edital (PDF)')),
                const PopupMenuItem(value: 'excluir', child: Text('Excluir concurso')),
              ],
            ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Hoje'),
              Tab(text: 'Cronograma'),
              Tab(text: 'Fluxo'),
              Tab(text: 'Simulados'),
              Tab(text: 'Materiais'),
              Tab(text: 'Prazos'),
            ],
          ),
        ),
        body: Column(
          children: [
            _Cabecalho(c: c, gerar: () => _acao(() => api.gerarPlano(c.id), recarregar)),
            Expanded(
              child: TabBarView(
                children: [
                  _HojeAba(c: c, marcar: (t, v) => _acao(() => api.marcar(c.id, t.id, v), recarregar)),
                  _CronogramaAba(c: c, marcar: (t, v) => _acao(() => api.marcar(c.id, t.id, v), recarregar)),
                  _FluxoAba(c: c),
                  SimuladosAba(api: api, concurso: c),
                  MateriaisAba(api: api, concurso: c),
                  _PrazosAba(
                    c: c,
                    adicionar: (p) => _acao(() => api.adicionarPrazo(c.id, p), recarregar),
                    remover: (p) => _acao(() => api.removerPrazo(c.id, p.id), recarregar),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Cabecalho extends StatelessWidget {
  const _Cabecalho({required this.c, required this.gerar});

  final Concurso c;
  final VoidCallback gerar;

  @override
  Widget build(BuildContext context) {
    final s = c.situacao;
    final tema = Theme.of(context);
    final aviso = switch (c.estado) {
      'gerando' => const ListTile(
        leading: SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2)),
        title: Text('O Claude está lendo o edital e montando o fluxo de estudo (alguns minutos)…'),
      ),
      'erro' => ListTile(
        leading: Icon(Icons.error_outline, color: tema.colorScheme.error),
        title: Text('Falha ao gerar o plano: ${c.erro}'),
        trailing: TextButton(onPressed: gerar, child: const Text('Tentar de novo')),
      ),
      'sem_plano' => ListTile(
        leading: const Icon(Icons.auto_awesome),
        title: Text(c.editalNome == null ? 'Envie o edital (menu ⋮).' : 'Edital: ${c.editalNome}'),
        trailing: c.editalNome == null ? null : FilledButton(onPressed: gerar, child: const Text('Gerar plano')),
      ),
      _ => null,
    };
    final r = c.resumoPlano;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Wrap(
            spacing: 24,
            runSpacing: 4,
            children: [
              Text('${c.cargo}${c.banca.isEmpty ? '' : ' · ${c.banca}'}'),
              Text('Prova: ${dataBr(c.dataProva)}${s.diasParaProva == null ? '' : ' (${s.diasParaProva} dias)'}'),
              if (s.tarefas > 0) Text('${s.feitas}/${s.tarefas} tarefas · ${s.atrasadas} atrasada(s)'),
              if (r != null) Text('Estudo até ${dataBr(r['fim_estudo'] as String?)}'),
              if (r != null && (r['fator'] as num) < 1)
                Text(
                  'Tempo curto: tópicos comprimidos a ${((r['fator'] as num) * 100).round()}%',
                  style: TextStyle(color: tema.colorScheme.error),
                ),
            ],
          ),
        ),
        if (c.radar != null) _Ficha(radar: c.radar!),
        ?aviso,
      ],
    );
  }
}

class _ItemTarefa extends StatelessWidget {
  const _ItemTarefa({required this.t, required this.marcar, this.comData = false});

  final Tarefa t;
  final void Function(Tarefa, bool) marcar;
  final bool comData;

  @override
  Widget build(BuildContext context) => CheckboxListTile(
    value: t.feito,
    onChanged: (v) => marcar(t, v ?? false),
    controlAffinity: ListTileControlAffinity.leading,
    secondary: Icon(_iconeTipo[t.tipo] ?? Icons.task_alt),
    title: Text(t.titulo, style: t.feito ? const TextStyle(decoration: TextDecoration.lineThrough) : null),
    subtitle: Text(
      [
        if (comData) dataBr(t.data, curta: true),
        if (t.disciplina.isNotEmpty) t.disciplina,
        '${t.minutos} min',
        if (t.detalhe.isNotEmpty) t.detalhe,
      ].join(' · '),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    ),
  );
}

class _HojeAba extends StatelessWidget {
  const _HojeAba({required this.c, required this.marcar});

  final Concurso c;
  final void Function(Tarefa, bool) marcar;

  @override
  Widget build(BuildContext context) {
    final hoje = iso(DateTime.now());
    final atrasadas = c.tarefas.where((t) => !t.feito && t.data.compareTo(hoje) < 0).toList();
    final deHoje = c.tarefas.where((t) => t.data == hoje).toList();
    final proximas = c.tarefas.where((t) => t.data.compareTo(hoje) > 0).take(5).toList();
    final minutos = deHoje.fold(0, (s, t) => s + t.minutos);
    return ListView(
      children: [
        ListTile(title: Text('Hoje · $minutos min', style: Theme.of(context).textTheme.titleMedium)),
        if (deHoje.isEmpty) const ListTile(title: Text('Nada planejado para hoje.')),
        for (final t in deHoje) _ItemTarefa(t: t, marcar: marcar),
        if (atrasadas.isNotEmpty) ...[
          ListTile(
            title: Text('Atrasadas (${atrasadas.length})', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            subtitle: const Text('Faça hoje ou use Replanejar (ícone no topo) para redistribuir até a prova.'),
          ),
          for (final t in atrasadas) _ItemTarefa(t: t, marcar: marcar, comData: true),
        ],
        if (proximas.isNotEmpty) ...[
          const ListTile(title: Text('Próximas')),
          for (final t in proximas) _ItemTarefa(t: t, marcar: marcar, comData: true),
        ],
      ],
    );
  }
}

class _CronogramaAba extends StatelessWidget {
  const _CronogramaAba({required this.c, required this.marcar});

  final Concurso c;
  final void Function(Tarefa, bool) marcar;

  @override
  Widget build(BuildContext context) {
    // agrupa por semana (segunda a domingo)
    final semanas = <String, List<Tarefa>>{};
    for (final t in c.tarefas) {
      final d = DateTime.parse(t.data);
      semanas.putIfAbsent(iso(d.subtract(Duration(days: d.weekday - 1))), () => []).add(t);
    }
    final hoje = iso(DateTime.now());
    return ListView(
      children: [
        for (final MapEntry(key: inicio, value: ts) in semanas.entries)
          ExpansionTile(
            initiallyExpanded: ts.any((t) => t.data == hoje),
            title: Text('Semana de ${dataBr(inicio, curta: true)}'),
            subtitle: Text(
              '${ts.where((t) => t.feito).length}/${ts.length} tarefas · '
              '${(ts.fold(0, (s, t) => s + t.minutos) / 60).toStringAsFixed(1)} h',
            ),
            children: [for (final t in ts) _ItemTarefa(t: t, marcar: marcar, comData: true)],
          ),
      ],
    );
  }
}

class _FluxoAba extends StatelessWidget {
  const _FluxoAba({required this.c});

  final Concurso c;

  @override
  Widget build(BuildContext context) {
    final e = c.estrutura;
    if (e == null) return const Center(child: Text('O fluxo aparece quando o plano for gerado.'));
    final tema = Theme.of(context);
    // tópico concluído = todos os blocos de conteúdo dele feitos (chave "disciplina|tópico|parte")
    bool concluido(String disc, String topico) {
      final blocos = c.tarefas.where((t) => t.chave?.startsWith('$disc|$topico|') ?? false);
      return blocos.isNotEmpty && blocos.every((t) => t.feito);
    }

    final discursiva = e['discursiva'] as Doc?;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if ((e['resumo'] as String? ?? '').isNotEmpty) ListTile(title: Text(e['resumo'] as String)),
        if ((e['formato_prova'] as String? ?? '').isNotEmpty)
          ListTile(leading: const Icon(Icons.assignment_outlined), title: Text(e['formato_prova'] as String), subtitle: Text(e['horario_prova'] as String? ?? '')),
        for (final d in c.disciplinas)
          Builder(builder: (context) {
            final feitos = d.topicos.where((t) => concluido(d.nome, t.titulo)).length;
            return ExpansionTile(
              title: Text(d.nome),
              subtitle: Text('${d.questoes} questões · $feitos/${d.topicos.length} tópicos · ${d.modulo}'),
              children: [
                for (final (i, t) in d.topicos.indexed)
                  ListTile(
                    leading: CircleAvatar(
                      radius: 14,
                      backgroundColor: concluido(d.nome, t.titulo) ? tema.colorScheme.primary : null,
                      child: concluido(d.nome, t.titulo) ? const Icon(Icons.check, size: 16) : Text('${i + 1}'),
                    ),
                    title: Text(t.titulo),
                    subtitle: Text('${t.horas.toStringAsFixed(0)} h · prioridade ${t.prioridade}\n${t.conteudo}'),
                    isThreeLine: true,
                  ),
              ],
            );
          }),
        if (discursiva != null)
          ExpansionTile(
            title: const Text('Discursiva'),
            subtitle: Text(discursiva['descricao'] as String? ?? ''),
            children: [for (final s in discursiva['temas_provaveis'] as List? ?? const []) ListTile(dense: true, title: Text('• $s'))],
          ),
        if (c.estrategia.isNotEmpty)
          ExpansionTile(
            initiallyExpanded: true,
            title: const Text('Estratégia'),
            children: [for (final s in c.estrategia) ListTile(dense: true, title: Text('• $s'))],
          ),
      ],
    );
  }
}

class _PrazosAba extends StatelessWidget {
  const _PrazosAba({required this.c, required this.adicionar, required this.remover});

  final Concurso c;
  final void Function(Doc) adicionar;
  final void Function(Prazo) remover;

  Future<void> _novo(BuildContext context) async {
    final titulo = TextEditingController();
    DateTime? data;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Novo prazo'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: titulo, decoration: const InputDecoration(labelText: 'O que fazer')),
              TextButton(
                onPressed: () async {
                  final d = await showDatePicker(
                    context: ctx,
                    firstDate: DateTime.now().subtract(const Duration(days: 30)),
                    lastDate: DateTime.now().add(const Duration(days: 730)),
                  );
                  if (d != null) set(() => data = d);
                },
                child: Text(data == null ? 'Escolher a data' : dataBr(iso(data!))),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Adicionar')),
          ],
        ),
      ),
    );
    if (ok == true && data != null && titulo.text.trim().isNotEmpty) {
      adicionar({'titulo': titulo.text.trim(), 'data': iso(data!)});
    }
  }

  @override
  Widget build(BuildContext context) {
    final hoje = iso(DateTime.now());
    final tema = Theme.of(context);
    return Scaffold(
      floatingActionButton: FloatingActionButton.small(
        tooltip: 'Novo prazo',
        onPressed: () => _novo(context),
        child: const Icon(Icons.add_alarm),
      ),
      body: ListView(
        children: [
          for (final p in c.prazos)
            Builder(builder: (context) {
              final passou = p.data.compareTo(hoje) < 0;
              final dias = DateTime.parse(p.data).difference(DateTime.parse(hoje)).inDays;
              final cor = passou ? tema.disabledColor : dias <= 2 ? tema.colorScheme.error : dias <= 7 ? Colors.orange : null;
              return ListTile(
                leading: Icon(p.tipo == 'prova' ? Icons.flag : Icons.event, color: cor),
                title: Text(p.titulo, style: TextStyle(color: passou ? tema.disabledColor : null)),
                subtitle: Text([
                  '${dataBr(p.data)}${p.hora.isEmpty ? '' : ' ${p.hora}'}${passou ? '' : ' · em $dias dia(s)'}',
                  if (p.detalhe.isNotEmpty) p.detalhe,
                ].join('\n')),
                trailing: p.origem == 'manual'
                    ? IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => remover(p))
                    : null,
              );
            }),
        ],
      ),
    );
  }
}

/// Ficha do concurso vindo do radar: vaga escolhida, salário, inscrições, prova e o local mais perto.
class _Ficha extends StatelessWidget {
  const _Ficha({required this.radar});

  final Doc radar;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final vaga = radar['vaga'] == null ? null : VagaTI.fromJson(radar['vaga'] as Doc);
    final local = radar['mais_proximo'] == null ? null : Local.fromJson(radar['mais_proximo'] as Doc);
    Widget dado(IconData i, String t, {Color? cor}) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [Icon(i, size: 16, color: cor ?? tema.colorScheme.primary), const SizedBox(width: 4), Text(t)],
    );
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 18,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (vaga != null) dado(Icons.work_outline, '${vaga.vagas} vaga(s)${vaga.cadastroReserva ? ' + CR' : ''}'),
            if (vaga != null && vaga.salario > 0) dado(Icons.payments_outlined, reais(vaga.salario)),
            if (radar['inscricoes_fim'] != null)
              dado(Icons.event_available, 'Inscrições ${radar['inscricoes_inicio'] == null || radar['inscricoes_inicio'] == '' ? 'até' : '${dataBr(radar['inscricoes_inicio'] as String, curta: true)} a'} ${dataBr(radar['inscricoes_fim'] as String)}'),
            if ((radar['horario_prova'] as String? ?? '').isNotEmpty) dado(Icons.schedule, 'Prova ${radar['horario_prova']}'),
            if (local != null)
              dado(Icons.place, '${local.nome} · ${local.km ?? local.kmReta} km${local.horas == null ? '' : ' · ${duracao(local.horas!)}'}', cor: corDistancia(local.km)),
            if ((radar['taxa'] as String? ?? '').isNotEmpty) dado(Icons.receipt_long, 'Taxa ${radar['taxa']}'),
            if ((radar['link_inscricao'] as String? ?? '').isNotEmpty)
              TextButton.icon(onPressed: () => abrirLink(context, radar['link_inscricao'] as String), icon: const Icon(Icons.how_to_reg, size: 16), label: const Text('Inscrição')),
            TextButton.icon(onPressed: () => abrirLink(context, radar['url'] as String), icon: const Icon(Icons.article_outlined, size: 16), label: const Text('Notícia')),
          ],
        ),
      ),
    );
  }
}
