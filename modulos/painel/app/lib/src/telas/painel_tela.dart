import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_painel.dart';
import '../modelos.dart';
import 'chat_cobrador.dart';
import 'dashboard_llms.dart';

class PainelTela extends StatefulWidget {
  const PainelTela({super.key, required this.api});

  final ApiPainel api;

  @override
  State<PainelTela> createState() => _PainelTelaState();
}

class _PainelTelaState extends State<PainelTela> {
  late final _conversa = ConversaCobrador(widget.api);

  @override
  void dispose() {
    _conversa.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 4,
    child: Column(
      children: [
        const TabBar(
          tabs: [
            Tab(icon: Icon(Icons.today_outlined), text: 'Hoje'),
            Tab(icon: Icon(Icons.forum_outlined), text: 'Cobrador'),
            Tab(icon: Icon(Icons.flag_outlined), text: 'Metas'),
            Tab(icon: Icon(Icons.speed_outlined), text: 'LLMs'),
          ],
        ),
        Expanded(
          child: TabBarView(
            children: [
              _Hoje(api: widget.api),
              ChatCobrador(conversa: _conversa),
              _Metas(api: widget.api),
              DashboardLlms(api: widget.api),
            ],
          ),
        ),
      ],
    ),
  );
}

// --- Hoje: disciplina, alertas e agenda editável ---

class _Hoje extends StatelessWidget {
  const _Hoje({required this.api});

  final ApiPainel api;

  Future<(Disciplina, Agenda)> _carregar() async {
    final dia = dataIso(DateTime.now());
    final r = await Future.wait([api.disciplina(), api.agenda(dia)]);
    return (r[0] as Disciplina, r[1] as Agenda);
  }

  @override
  Widget build(BuildContext context) => Sondagem<(Disciplina, Agenda)>(
    carregar: _carregar,
    intervalo: const Duration(seconds: 60),
    construir: (context, dados, recarregar) {
      final (d, ag) = dados;
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Placar(d: d),
          for (final a in d.alertas) _CartaoAlerta(alerta: a),
          const SizedBox(height: 8),
          _AgendaDia(api: api, agenda: ag, aoMudar: recarregar),
        ],
      );
    },
  );
}

class _Placar extends StatelessWidget {
  const _Placar({required this.d});

  final Disciplina d;

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    final cor = d.indice == null ? cores.outline : (d.dentro ? cores.primary : cores.error);
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: cor,
          foregroundColor: cores.onPrimary,
          child: Text(d.indice == null ? '–' : '${d.indice}'),
        ),
        title: Text(
          d.indice == null ? 'Dia ainda sem medição' : (d.dentro ? 'Dentro da disciplina' : 'Fora da disciplina'),
        ),
        subtitle: Text(
          'Blocos ${d.blocosFeitos}/${d.blocosVencidos} cumpridos · metas no ritmo ${d.metasNoRitmo}/${d.metasTotal}'
          '${d.blocoAtual == null ? '' : '\nAgora: ${d.blocoAtual!.titulo} (até ${d.blocoAtual!.fim})'}',
        ),
      ),
    );
  }
}

class _CartaoAlerta extends StatelessWidget {
  const _CartaoAlerta({required this.alerta});

  final Alerta alerta;

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    final critico = alerta.nivel == 'critico';
    return Card(
      color: critico ? cores.errorContainer : cores.tertiaryContainer,
      child: ListTile(
        dense: true,
        leading: Icon(critico ? Icons.priority_high : Icons.notifications_active_outlined),
        title: Text(alerta.texto),
      ),
    );
  }
}

class _AgendaDia extends StatelessWidget {
  const _AgendaDia({required this.api, required this.agenda, required this.aoMudar});

  final ApiPainel api;
  final Agenda agenda;
  final Future<void> Function() aoMudar;

  Future<void> _tentar(BuildContext context, Future<void> Function() acao) async {
    try {
      await acao();
    } on ApiErro catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
    await aoMudar();
  }

  /// Edita (ou cria, com [bloco] nulo) e grava a agenda inteira; mostra as contestações do cobrador.
  Future<void> _editar(BuildContext context, Bloco? bloco) async {
    final resultado = await showDialog<_Edicao>(context: context, builder: (_) => _EditorBloco(bloco: bloco));
    if (resultado == null || !context.mounted) return;
    final blocos = [...agenda.blocos];
    if (bloco != null) blocos.remove(bloco);
    if (resultado.bloco != null) blocos.add(resultado.bloco!);
    await _tentar(context, () async {
      final salva = await api.salvar(agenda.data, blocos, resultado.motivo);
      if (salva.contestacoes.isNotEmpty && context.mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            icon: const Icon(Icons.gavel_outlined),
            title: const Text('O cobrador contesta'),
            content: Text(salva.contestacoes.join('\n\n')),
            actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Entendi'))],
          ),
        );
      }
    });
  }

  Future<void> _sugerir(BuildContext context) async {
    if (agenda.blocos.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Refazer a agenda?'),
          content: const Text('A sugestão substitui os blocos de hoje.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Refazer')),
          ],
        ),
      );
      if (ok != true || !context.mounted) return;
    }
    await _tentar(context, () => api.sugerir(agenda.data));
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(child: Text('Agenda de hoje', style: Theme.of(context).textTheme.titleMedium)),
          TextButton.icon(
            icon: const Icon(Icons.auto_fix_high_outlined),
            label: const Text('Sugerir'),
            onPressed: () => _sugerir(context),
          ),
          IconButton(tooltip: 'Novo bloco', icon: const Icon(Icons.add), onPressed: () => _editar(context, null)),
        ],
      ),
      if (agenda.blocos.isEmpty)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text('Nenhum bloco. Use “Sugerir” para montar o dia com as tarefas do Kanban.'),
        ),
      for (final b in agenda.blocos)
        Card(
          child: CheckboxListTile(
            value: b.feito,
            onChanged: (v) => _tentar(context, () => api.marcar(agenda.data, b.id!, v ?? false)),
            title: Text(b.titulo, style: TextStyle(decoration: b.feito ? TextDecoration.lineThrough : null)),
            subtitle: Text('${b.inicio}–${b.fim} · prioridade ${b.prioridade}${b.prazo == null ? '' : ' · prazo ${b.prazo}'}'),
            secondary: IconButton(
              tooltip: 'Editar',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _editar(context, b),
            ),
          ),
        ),
    ],
  );
}

/// Resultado do editor: [bloco] nulo = excluir. [motivo] vai para o histórico de alterações.
class _Edicao {
  const _Edicao(this.bloco, this.motivo);

  final Bloco? bloco;
  final String motivo;
}

class _EditorBloco extends StatefulWidget {
  const _EditorBloco({this.bloco});

  final Bloco? bloco;

  @override
  State<_EditorBloco> createState() => _EditorBlocoState();
}

class _EditorBlocoState extends State<_EditorBloco> {
  late final _titulo = TextEditingController(text: widget.bloco?.titulo);
  late final _inicio = TextEditingController(text: widget.bloco?.inicio ?? '09:00');
  late final _fim = TextEditingController(text: widget.bloco?.fim ?? '09:50');
  final _motivo = TextEditingController();
  late String _prioridade = widget.bloco?.prioridade ?? 'media';
  final _hora = RegExp(r'^\d{2}:\d{2}$');

  @override
  void dispose() {
    for (final c in [_titulo, _inicio, _fim, _motivo]) {
      c.dispose();
    }
    super.dispose();
  }

  void _salvar() {
    if (_titulo.text.trim().isEmpty || !_hora.hasMatch(_inicio.text) || !_hora.hasMatch(_fim.text)) return;
    final b = widget.bloco;
    Navigator.pop(
      context,
      _Edicao(
        Bloco(
          id: b?.id,
          titulo: _titulo.text.trim(),
          inicio: _inicio.text,
          fim: _fim.text,
          prioridade: _prioridade,
          tarefaId: b?.tarefaId,
          prazo: b?.prazo,
          feito: b?.feito ?? false,
        ),
        _motivo.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.bloco == null ? 'Novo bloco' : 'Editar bloco'),
    content: SizedBox(
      width: 380,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 12,
        children: [
          TextField(controller: _titulo, autofocus: true, decoration: const InputDecoration(labelText: 'Título')),
          Row(
            spacing: 12,
            children: [
              Expanded(
                child: TextField(controller: _inicio, decoration: const InputDecoration(labelText: 'Início (HH:MM)')),
              ),
              Expanded(
                child: TextField(controller: _fim, decoration: const InputDecoration(labelText: 'Fim (HH:MM)')),
              ),
            ],
          ),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'baixa', label: Text('Baixa')),
              ButtonSegment(value: 'media', label: Text('Média')),
              ButtonSegment(value: 'alta', label: Text('Alta')),
            ],
            selected: {_prioridade},
            onSelectionChanged: (s) => setState(() => _prioridade = s.first),
          ),
          TextField(
            controller: _motivo,
            decoration: const InputDecoration(labelText: 'Motivo da mudança (o cobrador registra)'),
          ),
        ],
      ),
    ),
    actions: [
      if (widget.bloco != null)
        TextButton(
          onPressed: () => Navigator.pop(context, _Edicao(null, _motivo.text.trim())),
          child: const Text('Excluir'),
        ),
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(onPressed: _salvar, child: const Text('Salvar')),
    ],
  );
}

// --- Metas ---

class _Metas extends StatelessWidget {
  const _Metas({required this.api});

  final ApiPainel api;

  Future<void> _nova(BuildContext context, Future<void> Function() recarregar) async {
    final titulo = TextEditingController();
    final alvo = TextEditingController(text: '1');
    final unidade = TextEditingController(text: 'vez');
    var frequencia = 'diaria';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Nova meta'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              TextField(controller: titulo, autofocus: true, decoration: const InputDecoration(labelText: 'Meta')),
              Row(
                spacing: 12,
                children: [
                  Expanded(
                    child: TextField(
                      controller: alvo,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Alvo'),
                    ),
                  ),
                  Expanded(
                    child: TextField(controller: unidade, decoration: const InputDecoration(labelText: 'Unidade')),
                  ),
                ],
              ),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'diaria', label: Text('Por dia')),
                  ButtonSegment(value: 'semanal', label: Text('Por semana')),
                ],
                selected: {frequencia},
                onSelectionChanged: (s) => setState(() => frequencia = s.first),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Criar')),
          ],
        ),
      ),
    );
    final valor = double.tryParse(alvo.text.replaceAll(',', '.'));
    if (ok == true && titulo.text.trim().isNotEmpty && valor != null && valor > 0) {
      await api.criarMeta(titulo.text.trim(), frequencia, valor, unidade.text.trim());
      await recarregar();
    }
    for (final c in [titulo, alvo, unidade]) {
      c.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => Sondagem<List<Meta>>(
    carregar: api.metas,
    intervalo: const Duration(seconds: 60),
    construir: (context, metas, recarregar) => Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Meta'),
        onPressed: () => _nova(context, recarregar),
      ),
      body: metas.isEmpty
          ? const Center(child: Text('Sem metas. Crie as que o cobrador deve acompanhar.'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
              children: [
                for (final m in metas)
                  Card(
                    child: ListTile(
                      leading: Icon(
                        m.noRitmo ? Icons.check_circle_outline : Icons.trending_down,
                        color: m.noRitmo ? null : Theme.of(context).colorScheme.error,
                      ),
                      title: Text(m.titulo),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 4,
                        children: [
                          Text(
                            '${_n(m.feito)}/${_n(m.alvo)} ${m.unidade} ${m.frequencia == 'diaria' ? 'hoje' : 'na semana'}'
                            ' · esperado agora ${_n(m.esperado)}',
                          ),
                          LinearProgressIndicator(value: (m.feito / m.alvo).clamp(0, 1)),
                        ],
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Registrar +1',
                            icon: const Icon(Icons.add_task),
                            onPressed: () async {
                              await api.registrar(m.id);
                              await recarregar();
                            },
                          ),
                          IconButton(
                            tooltip: 'Excluir',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              await api.excluirMeta(m.id);
                              await recarregar();
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    ),
  );
}

String _n(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
