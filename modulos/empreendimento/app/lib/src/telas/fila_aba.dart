import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../modelos.dart';
import 'processos_aba.dart';
import 'util.dart';

/// Fila de produção: duas vagas (máquina e Claude) e as tarefas, da mais nova para a mais antiga.
class FilaAba extends StatelessWidget {
  const FilaAba({super.key, required this.api});

  final ApiEsteira api;

  @override
  Widget build(BuildContext context) => Sondagem<Fila>(
    intervalo: const Duration(seconds: 2),
    carregar: api.fila,
    construir: (context, fila, recarregar) => ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final MapEntry(key: vaga, value: dono) in fila.vagas.entries)
              SeloEstado(dono == null ? 'livre' : 'rodando', texto: '${vaga == 'machine' ? 'máquina' : vaga}: ${dono ?? 'livre'}'),
            TextButton.icon(
              icon: const Icon(Icons.cleaning_services_outlined),
              label: const Text('Limpar concluídas'),
              onPressed: () => acaoComAviso(context, () async {
                await api.limparFila();
                await recarregar();
                return 'Concluídas removidas da fila.';
              }),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _GerarRoteiro(api: api),
        const SizedBox(height: 12),
        if (fila.tarefas.isEmpty) const Vazio('Fila vazia.'),
        for (final t in fila.tarefas) _TarefaLinha(api: api, t: t, recarregar: recarregar),
      ],
    ),
  );
}

class _TarefaLinha extends StatelessWidget {
  const _TarefaLinha({required this.api, required this.t, required this.recarregar});

  final ApiEsteira api;
  final Tarefa t;
  final Future<void> Function() recarregar;

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    final fim = t.fim ?? DateTime.now();
    final p = t.prog;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: t.processo == null ? null : () => abrirProcesso(context, api, t.processo!),
        leading: Icon(iconeDoEstado(t.estado), color: corDoEstado(cores, t.estado)),
        title: Text('${t.comando} ${t.ep} ${t.args.join(' ')}'.trim()),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 4,
          children: [
            Text(
              [
                t.estado,
                'vaga ${t.vaga == 'machine' ? 'máquina' : t.vaga}',
                'criada ${diaHora(t.criado)}',
                if (t.inicio != null) 'duração ${duracao(fim.difference(t.inicio!).inSeconds.toDouble())}',
              ].join(' · '),
            ),
            if (t.estado == 'rodando' && p != null) ...[
              LinearProgressIndicator(value: p.fracao),
              Text('${p.rodando ?? ''} · ${p.feitas}/${p.total} etapas'),
            ],
          ],
        ),
        trailing: t.ativa
            ? IconButton(
                tooltip: 'Cancelar',
                icon: const Icon(Icons.stop_circle_outlined),
                onPressed: () => _cancelar(context),
              )
            : null,
      ),
    );
  }

  Future<void> _cancelar(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancelar tarefa?'),
        content: Text(
          t.estado == 'rodando'
              ? '“${t.comando} ${t.ep}” está rodando e será interrompida.'
              : '“${t.comando} ${t.ep}” sai da fila.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Voltar')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Cancelar tarefa')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await acaoComAviso(context, () async {
      await api.cancelar(t.id);
      await recarregar();
      return 'Tarefa cancelada.';
    });
  }
}

/// `./dark roteiro canal:N [--ate M]`: escreve roteiros do plano do canal no vault (LLM local ou Claude).
class _GerarRoteiro extends StatefulWidget {
  const _GerarRoteiro({required this.api});

  final ApiEsteira api;

  @override
  State<_GerarRoteiro> createState() => _GerarRoteiroState();
}

class _GerarRoteiroState extends State<_GerarRoteiro> {
  final _alvo = TextEditingController();
  final _ate = TextEditingController();
  String _motor = 'local';

  @override
  void dispose() {
    _alvo.dispose();
    _ate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text('Roteiro do plano'),
          SizedBox(
            width: 150,
            child: TextField(
              controller: _alvo,
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'finlumia:51',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          SizedBox(
            width: 110,
            child: TextField(
              controller: _ate,
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'até (opcional)',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          DropdownButton<String>(
            value: _motor,
            items: const [
              DropdownMenuItem(value: 'local', child: Text('LLM local (ocupa a máquina)')),
              DropdownMenuItem(value: 'claude', child: Text('Claude (em paralelo; conta no teto)')),
            ],
            onChanged: (v) => setState(() => _motor = v ?? 'local'),
          ),
          FilledButton.tonal(
            onPressed: () => acaoComAviso(context, () async {
              final entrou = await widget.api.gerarRoteiro(
                _alvo.text.trim(),
                ate: _ate.text.trim(),
                motor: _motor,
              );
              return entrou ? 'Roteiro na fila.' : 'Esse roteiro já estava na fila.';
            }),
            child: const Text('Pôr na fila'),
          ),
        ],
      ),
    ),
  );
}
