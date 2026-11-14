import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_painel.dart';
import '../modelos.dart';

/// Dashboard das LLMs (últimas 24 h): disponibilidade, latência e tokens por provedor, workers
/// conectados com o uso da máquina e o log dos últimos pedidos.
class DashboardLlms extends StatelessWidget {
  const DashboardLlms({super.key, required this.api});

  final ApiPainel api;

  @override
  Widget build(BuildContext context) => Sondagem<Dashboard>(
    carregar: api.dashboard,
    intervalo: const Duration(seconds: 15),
    construir: (context, d, _) {
      final texto = Theme.of(context).textTheme;
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Provedores (24 h)', style: texto.titleMedium),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final nome in d.configurados)
                _CartaoProvedor(
                  nome: nome,
                  uso: d.provedores.where((p) => p.nome == nome).firstOrNull,
                  online: nome != 'local' || d.workers.isNotEmpty,
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text('Workers', style: texto.titleMedium),
          if (d.workers.isEmpty)
            const ListTile(leading: Icon(Icons.power_off_outlined), title: Text('Nenhum worker conectado')),
          for (final w in d.workers) _CartaoWorker(w: w),
          const SizedBox(height: 16),
          Text('Últimos pedidos', style: texto.titleMedium),
          if (d.recentes.isEmpty) const ListTile(title: Text('Nenhum pedido nas últimas 24 h')),
          for (final r in d.recentes) _LinhaLog(r: r),
        ],
      );
    },
  );
}

class _CartaoProvedor extends StatelessWidget {
  const _CartaoProvedor({required this.nome, required this.uso, required this.online});

  final String nome;
  final UsoProvedor? uso;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    final u = uso;
    return SizedBox(
      width: 280,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [
              Row(
                children: [
                  Icon(Icons.circle, size: 12, color: online ? cores.primary : cores.error),
                  const SizedBox(width: 8),
                  Text(nome == 'local' ? 'LLM local (worker)' : 'Claude', style: Theme.of(context).textTheme.titleSmall),
                ],
              ),
              if (u == null)
                const Text('Sem pedidos na janela')
              else ...[
                Text('${u.pedidos} pedidos · ${u.erros} erros · ${u.disponibilidade.toStringAsFixed(1)}% ok'),
                Text('Latência p50 ${u.p50 ?? '–'} ms · p95 ${u.p95 ?? '–'} ms'),
                Text('Tokens: ${u.tokensEntrada} entrada · ${u.tokensSaida} saída'),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CartaoWorker extends StatelessWidget {
  const _CartaoWorker({required this.w});

  final Map<String, dynamic> w;

  @override
  Widget build(BuildContext context) {
    final r = w['recursos'] as Map<String, dynamic>?;
    final gpus = [for (final g in r?['gpus'] as List? ?? const []) g as Map<String, dynamic>];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 6,
          children: [
            Text('${w['id']} · visto há ${w['visto_ha_s']} s', style: Theme.of(context).textTheme.titleSmall),
            Text('Modelos: ${(w['modelos'] as List).join(', ')}'),
            if (r == null) const Text('Sem dados de uso ainda (chegam no próximo heartbeat)'),
            if (r?['cpu_pct'] != null) _Barra('CPU', (r!['cpu_pct'] as num).toDouble()),
            if (r?['ram_pct'] != null) _Barra('RAM', (r!['ram_pct'] as num).toDouble()),
            for (final g in gpus) ...[
              _Barra('GPU ${g['nome']} (${g['temp_c']}°C)', (g['uso_pct'] as num).toDouble()),
              _Barra(
                'VRAM ${g['mem_usada_mb']}/${g['mem_total_mb']} MB',
                100 * (g['mem_usada_mb'] as num) / (g['mem_total_mb'] as num),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Barra extends StatelessWidget {
  const _Barra(this.rotulo, this.pct);

  final String rotulo;
  final double pct;

  @override
  Widget build(BuildContext context) => Row(
    spacing: 8,
    children: [
      SizedBox(width: 220, child: Text(rotulo, overflow: TextOverflow.ellipsis)),
      Expanded(child: LinearProgressIndicator(value: (pct / 100).clamp(0, 1))),
      SizedBox(width: 48, child: Text('${pct.toStringAsFixed(0)}%', textAlign: TextAlign.end)),
    ],
  );
}

class _LinhaLog extends StatelessWidget {
  const _LinhaLog({required this.r});

  final Map<String, dynamic> r;

  @override
  Widget build(BuildContext context) {
    final quando = DateTime.fromMillisecondsSinceEpoch(((r['em'] as num) * 1000).round());
    final hora = '${quando.hour.toString().padLeft(2, '0')}:${quando.minute.toString().padLeft(2, '0')}';
    final erro = r['erro'] as String?;
    final tokens = r['tokens_saida'] == null ? '' : ' · ${r['tokens_entrada'] ?? 0}→${r['tokens_saida']} tokens';
    return ListTile(
      dense: true,
      leading: Icon(
        erro == null ? Icons.check_circle_outline : Icons.error_outline,
        color: erro == null ? null : Theme.of(context).colorScheme.error,
      ),
      title: Text('$hora · ${r['provedor']} · ${r['tarefa'] ?? 'chat'} · ${r['modelo'] ?? ''}'),
      subtitle: Text('${r['ms']} ms$tokens${erro == null ? '' : '\n$erro'}'),
    );
  }
}
