import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../models.dart';
import 'util.dart';

/// Live piece factory panel: Claude creates the ideas, the local LLM writes each piece in N1, the gate
/// renders and measures, Claude reviews (and writes the lesson to the guide), you approve and the piece goes into the library and the dataset.
/// Shows where the flow is now, who is working (Claude × local LLM), today's numbers and the thumbnails.
class FactoryTab extends StatelessWidget {
  const FactoryTab({super.key, required this.api});

  final ApiEsteira api;

  @override
  Widget build(BuildContext context) => Sondagem<Json>(
    intervalo: const Duration(seconds: 3),
    carregar: api.factoryPanel,
    construir: (context, d, recarregar) {
      final agora = [for (final a in d['agora'] as List) a as Json];
      final active = agora.where((a) => a['rodando'] == true).firstOrNull;
      final calls = [for (final c in d['chamadas'] as List) c as Json];
      final today = d['hoje'] as Json;
      final motion = today['motion'] as Json;
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _Agent(
                who: 'claude',
                titulo: 'Claude',
                role: 'cria ideias e revisa as peças',
                call: calls.where((c) => c['motor'] == 'claude').firstOrNull,
                extra: _Quota(d['cota'] as Json),
                rodape: 'hoje ${dollars(today['gasto_total'] as num?, places: 2)} · '
                    '${(today['ideias'] as Json)['lotes']} lotes de ideias · ${motion['revisoes']} revisões',
              ),
              _Agent(
                who: 'local',
                titulo: 'LLM local',
                role: 'escreve cada peça em N1 (sem custo)',
                call: calls.where((c) => c['motor'] == 'local').firstOrNull,
                rodape: 'hoje ${motion['local']} tentativas · ${motion['geradas']} passaram no portão',
              ),
            ],
          ),
          const Section('Fluxo agora'),
          _Flow(d: d, active: active),
          Section(
            'Pedidos',
            acao: Wrap(
              spacing: 8,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.lightbulb_outline),
                  label: const Text('Gerar ideias com o Claude'),
                  onPressed: () => _newIdeas(context, recarregar),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.swap_horiz),
                  label: const Text('Portar HTML com a LLM'),
                  onPressed: () => actionWithWarning(context, () async {
                    await api.portarHtml();
                    await recarregar();
                    return 'Porte na fila (só LLM local)';
                  }),
                ),
              ],
            ),
          ),
          _Requests([for (final p in d['pedidos'] as List) p as Json], api: api, recarregar: recarregar),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, c) {
              final largura = c.maxWidth >= 1100 ? (c.maxWidth - 24) / 3 : (c.maxWidth >= 700 ? (c.maxWidth - 12) / 2 : c.maxWidth);
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  SizedBox(width: largura, child: _Ideas(d)),
                  SizedBox(width: largura, child: _Motion(d)),
                  SizedBox(width: largura, child: _Thumbs(d)),
                ],
              );
            },
          ),
          _Lessons(d['licoes'] as Json),
          const Section('Linha do tempo'),
          Card(
            child: Column(children: [for (final e in d['eventos'] as List) _Event(e as Json)]),
          ),
        ],
      );
    },
  );

  Future<void> _newIdeas(BuildContext context, Future<void> Function() recarregar) async {
    final tema = TextEditingController();
    var quantidade = 24.0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, change) => AlertDialog(
          title: const Text('Gerar ideias com o Claude'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('O Claude cria as ideias em lotes de 8 (cerca de US\$ 0,17 por lote); a LLM local escreve '
                    'cada peça e o Claude revisa as que passarem no portão.'),
                const SizedBox(height: 12),
                TextField(
                  controller: tema,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Tema ou direção (opcional)',
                    hintText: 'ex.: comparações de finanças pessoais, linhas do tempo de história…',
                  ),
                ),
                const SizedBox(height: 12),
                Text('${quantidade.round()} peças'),
                Slider(
                  value: quantidade,
                  min: 8,
                  max: 50,
                  divisions: 42,
                  onChanged: (v) => change(() => quantidade = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Gerar')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    await actionWithWarning(context, () async {
      await api.generateIdeas(quantidade.round(), tema.text);
      await recarregar();
      return 'Pedido de ideias na fila';
    });
  }
}

/// Color and icon of who did each thing.
Color colorOf(String who) => switch (who) {
  'claude' => Colors.deepPurple,
  'local' => Colors.orange.shade800,
  'voce' => Colors.blue,
  _ => Colors.blueGrey,
};

IconData iconOf(String who) => switch (who) {
  'claude' => Icons.auto_awesome,
  'local' => Icons.memory,
  'voce' => Icons.person_outline,
  _ => Icons.settings_outlined,
};

class _Agent extends StatelessWidget {
  const _Agent({
    required this.who,
    required this.titulo,
    required this.role,
    required this.call,
    required this.rodape,
    this.extra,
  });

  final String who;
  final String titulo;
  final String role;
  final Json? call;
  final String rodape;
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final color = colorOf(who);
    final c = call;
    return SizedBox(
      width: 420,
      child: Card(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: c != null ? color : color.withValues(alpha: 0.25), width: c != null ? 2 : 1),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(iconOf(who), color: color),
                  const SizedBox(width: 8),
                  Text(titulo, style: t.titleMedium),
                  const Spacer(),
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(c != null ? 'trabalhando' : 'ocioso'),
                    backgroundColor: c != null ? color.withValues(alpha: 0.15) : null,
                  ),
                ],
              ),
              Text(role, style: t.bodySmall),
              const SizedBox(height: 8),
              if (c != null) ...[
                Text('${c['nome']} · ${c['modelo'] ?? ''}', style: t.bodyMedium),
                Text('${c['tokens']} tokens · ${duration((c['segundos'] as num?)?.toDouble())}', style: t.bodySmall),
                const SizedBox(height: 6),
                LinearProgressIndicator(color: color),
                if ((c['parcial'] as String? ?? '').isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      c['parcial'] as String,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodySmall?.copyWith(fontFamily: 'monospace'),
                    ),
                  ),
              ] else
                Text('nenhuma chamada em andamento', style: t.bodySmall),
              ?extra,
              const SizedBox(height: 6),
              Text(rodape, style: t.labelSmall),
            ],
          ),
        ),
      ),
    );
  }
}

class _Quota extends StatelessWidget {
  const _Quota(this.quota);

  final Json quota;

  @override
  Widget build(BuildContext context) {
    final windows = quota['janelas'] as Json;
    final limit = (quota['limite'] as num?)?.toDouble() ?? 0.9;
    final names = {'five_hour': 'janela de 5 h', 'seven_day': 'semana'};
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        children: [
          for (final k in windows.keys)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  SizedBox(width: 110, child: Text(names[k] ?? k, style: Theme.of(context).textTheme.bodySmall)),
                  Expanded(
                    child: LinearProgressIndicator(
                      value: ((windows[k] as Json)['uso'] as num).toDouble(),
                      color: ((windows[k] as Json)['uso'] as num) >= limit ? Colors.red : Colors.deepPurple,
                      minHeight: 6,
                    ),
                  ),
                  SizedBox(
                    width: 48,
                    child: Text(
                      '${((((windows[k] as Json)['uso'] as num)) * 100).round()}%',
                      textAlign: TextAlign.end,
                    ),
                  ),
                ],
              ),
            ),
          if (quota['cheia'] == true)
            const Text('cota no limite: o Claude para até a janela virar', style: TextStyle(color: Colors.red)),
        ],
      ),
    );
  }
}

/// The flow in stages, with the stage in progress lit and what is in it.
class _Flow extends StatelessWidget {
  const _Flow({required this.d, required this.active});

  final Json d;
  final Json? active;

  @override
  Widget build(BuildContext context) {
    final today = d['hoje'] as Json;
    final motion = today['motion'] as Json;
    final mediaLibrary = d['acervo'] as Json;
    final stage = (active?['etapa'] as Json?) ?? const {};
    final nome = stage['nome'] as String?;
    final ideas = (d['ideias_na_fila'] as List).length;
    final stages = [
      ('ideias', 'Ideias', 'claude', '${(today['ideias'] as Json)['lotes']} lotes hoje'),
      ('fila', 'Fila de ideias', 'sistema', '$ideas esperando'),
      ('n1', 'Peça em N1', 'local', '${motion['local']} tentativas'),
      ('portao', 'Portão', 'sistema', '${motion['descartadas']} descartes'),
      ('revisao', 'Revisão', 'claude', '${motion['revisoes']} revisões'),
      ('voce', 'Sua revisão', 'voce', '${d['revisao']} esperando'),
      ('acervo', 'Acervo EC', 'sistema', '${(mediaLibrary['effectcraft'] as Json)['aprovada']} aprovadas'),
    ];
    final t = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final (i, e) in stages.indexed) ...[
                    if (i > 0) const Icon(Icons.arrow_forward, size: 18, color: Colors.grey),
                    _Node(label: e.$2, who: e.$3, numero: e.$4, lit: nome == e.$1),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
            if (active == null)
              Text('Nada rodando agora. Gere ideias ou retome um pedido.', style: t.bodyMedium)
            else
              Text(
                [
                  if (stage['peca'] != null && '${stage['peca']}'.isNotEmpty) 'peça ${stage['peca']}',
                  if ((stage['rodada'] as num? ?? 0) > 0) 'rodada ${stage['rodada']} de ${stage['de']}',
                  if (stage['desde'] != null) 'há ${_since(stage['desde'] as String)}',
                  active!['situacao'] as String? ?? '',
                ].where((s) => s.isNotEmpty).join(' · '),
                style: t.bodyMedium,
              ),
          ],
        ),
      ),
    );
  }

  static String _since(String iso) {
    final t = DateTime.tryParse(iso);
    return t == null ? '?' : duration(DateTime.now().difference(t).inSeconds.toDouble());
  }
}

class _Node extends StatelessWidget {
  const _Node({required this.label, required this.who, required this.numero, required this.lit});

  final String label;
  final String who;
  final String numero;
  final bool lit;

  @override
  Widget build(BuildContext context) {
    final color = colorOf(who);
    final t = Theme.of(context).textTheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: 132,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: lit ? color.withValues(alpha: 0.18) : null,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: lit ? color : color.withValues(alpha: 0.3), width: lit ? 2 : 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(iconOf(who), size: 16, color: color),
              const SizedBox(width: 4),
              Expanded(child: Text(label, style: t.labelLarge, overflow: TextOverflow.ellipsis)),
            ],
          ),
          const SizedBox(height: 4),
          Text(numero, style: t.bodySmall),
          if (lit) ...[const SizedBox(height: 6), LinearProgressIndicator(color: color, minHeight: 3)],
        ],
      ),
    );
  }
}

class _Requests extends StatelessWidget {
  const _Requests(this.requests, {required this.api, required this.recarregar});

  final List<Json> requests;
  final ApiEsteira api;
  final Future<void> Function() recarregar;

  @override
  Widget build(BuildContext context) {
    if (requests.isEmpty) return const Empty('Nenhum pedido aberto');
    return Card(
      child: Column(
        children: [
          for (final p in requests)
            ListTile(
              dense: true,
              leading: Icon(p['tipo'] == 'ideias' ? Icons.lightbulb_outline : Icons.swap_horiz),
              title: Text(p['tipo'] == 'ideias' ? 'Ideias: ${p['texto']}' : 'Porte HTML → EffectCraft'),
              subtitle: Text(
                p['tipo'] == 'ideias'
                    ? '${p['pecas']} peças · ${p['descartadas']} descartes de ${p['quantidade']} · '
                          '${p['ideias_na_fila']} ideias na fila · ${dollars(p['gasto_usd'] as num?, places: 2)}'
                    : '${p['feitos']} de ${p['alvos']} peças tentadas · ${p['pecas']} portadas',
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  StatePill(p['rodando'] == true ? 'rodando' : (p['na_fila'] == true ? 'na fila' : '${p['estado']}')),
                  IconButton(
                    tooltip: p['estado'] == 'pausado' ? 'Retomar' : 'Pausar',
                    icon: Icon(p['estado'] == 'pausado' ? Icons.play_arrow : Icons.pause),
                    onPressed: () => actionWithWarning(context, () async {
                      await api.pauseRequest(p['id'] as String, p['estado'] != 'pausado');
                      await recarregar();
                      return p['estado'] == 'pausado' ? 'Retomado' : 'Pausa ao fim da peça atual';
                    }),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({required this.titulo, required this.icone, required this.children});

  final String titulo;
  final IconData icone;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icone),
              const SizedBox(width: 8),
              Text(titulo, style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    ),
  );
}

/// Labeled progress bar: `done` out of `total`.
class _Bar extends StatelessWidget {
  const _Bar(this.label, this.done, this.total, {this.color});

  final String label;
  final num done;
  final num total;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label: $done${total > 0 ? ' de $total' : ''}', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 2),
        LinearProgressIndicator(value: total > 0 ? (done / total).clamp(0, 1).toDouble() : 0, color: color, minHeight: 6),
      ],
    ),
  );
}

class _Ideas extends StatelessWidget {
  const _Ideas(this.d);

  final Json d;

  @override
  Widget build(BuildContext context) {
    final queue = [for (final i in d['ideias_na_fila'] as List) i as Json];
    final today = (d['hoje'] as Json)['ideias'] as Json;
    return _Block(
      titulo: 'Ideias',
      icone: Icons.lightbulb_outline,
      children: [
        Text('${today['lotes']} lotes do Claude hoje · ${dollars(today['custo'] as num?, places: 2)}'),
        const Divider(),
        if (queue.isEmpty) const Text('Fila de ideias vazia.'),
        for (final i in queue.take(8))
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.circle, size: 10, color: colorOf('claude')),
            title: Text('${i['id']}'),
            subtitle: Text('${i['descricao']}', maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        if (queue.length > 8) Text('+ ${queue.length - 8} ideias'),
      ],
    );
  }
}

class _Motion extends StatelessWidget {
  const _Motion(this.d);

  final Json d;

  @override
  Widget build(BuildContext context) {
    final m = (d['hoje'] as Json)['motion'] as Json;
    final mediaLibrary = d['acervo'] as Json;
    final ds = (d['dataset'] as Json)['peca_animar'] as Json? ?? const {};
    final motivos = [for (final x in m['motivos'] as List) x as Json];
    final largest = motivos.fold<num>(1, (a, x) => (x['n'] as num) > a ? x['n'] as num : a);
    String line(String engine) {
      final a = mediaLibrary[engine] as Json;
      return '${a['aprovada']} aprovadas · ${a['revisao']} em revisão · ${a['rascunho']} rascunhos';
    }

    return _Block(
      titulo: 'Motion graphics',
      icone: Icons.animation,
      children: [
        Text('Hoje: ${m['tentativas']} tentativas · ${m['geradas']} no portão · ${m['descartadas']} descartes · ${m['puladas'] ?? 0} puladas (o N1 não desenha)'),
        Text('Revisão do Claude: ${m['revisoes']} (${m['aprovadas_claude']} aprovadas) · '
            '${dollars(m['custo_revisao'] as num?, places: 2)}'),
        const Divider(),
        Text('Por que foram descartadas', style: Theme.of(context).textTheme.labelLarge),
        if (motivos.isEmpty) const Text('nenhum descarte hoje'),
        for (final x in motivos) _Bar('${x['motivo']}', x['n'] as num, largest, color: Colors.red.shade300),
        const Divider(),
        Text('Acervo EffectCraft: ${line('effectcraft')}'),
        Text('Acervo HTML: ${line('html')}'),
        _Bar('Dataset peca_animar (bons para treino)', (ds['sft'] as num?) ?? 0, (ds['minimo'] as num?) ?? 0,
            color: Colors.green),
      ],
    );
  }
}

class _Thumbs extends StatelessWidget {
  const _Thumbs(this.d);

  final Json d;

  @override
  Widget build(BuildContext context) {
    final ds = (d['dataset'] as Json)['thumb_compor'] as Json? ?? const {};
    final photo = (d['dataset'] as Json)['foto_tratar'] as Json? ?? const {};
    final tasks = [for (final t in (d['thumbs'] as Json)['tarefas'] as List) t as Json];
    return _Block(
      titulo: 'Thumbnails',
      icone: Icons.image_outlined,
      children: [
        _Bar('Thumbs aprovadas para treino', (ds['sft'] as num?) ?? 0, (ds['minimo'] as num?) ?? 0, color: Colors.green),
        Text('${ds['pendente'] ?? 0} esperando sua escolha (aba Thumbs do episódio)'),
        _Bar('Fotos tratadas', (photo['sft'] as num?) ?? 0, (photo['minimo'] as num?) ?? 0, color: Colors.green),
        const Divider(),
        if (tasks.isEmpty) const Text('Nenhuma thumb sendo gerada agora.'),
        for (final t in tasks)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.photo_filter_outlined),
            title: Text('${t['ep']}'),
            trailing: StatePill('${t['estado']}'),
          ),
      ],
    );
  }
}

class _Lessons extends StatelessWidget {
  const _Lessons(this.l);

  final Json l;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Section('Lições no guia da LLM (${l['total']})'),
      Card(
        child: Column(
          children: [
            for (final x in (l['ultimas'] as List).reversed)
              ListTile(
                dense: true,
                leading: Icon(Icons.school_outlined, color: colorOf('claude')),
                title: Text('$x'),
              ),
          ],
        ),
      ),
    ],
  );
}

class _Event extends StatelessWidget {
  const _Event(this.e);

  final Json e;

  @override
  Widget build(BuildContext context) {
    final who = e['quem'] as String? ?? 'sistema';
    final event = e['evento'] as String? ?? '';
    final nome = switch (event) {
      'revisao' => e['aprovada'] == true ? 'Claude aprovou' : 'Claude reprovou',
      'gerada' => 'passou no portão',
      'descartada' => 'descartada',
      'aprovada' => 'você aprovou',
      'reprovada' => 'você reprovou',
      'pedido' => 'pedido novo',
      _ => event,
    };
    final cost = (e['custo'] as num?) ?? 0;
    return ListTile(
      dense: true,
      leading: CircleAvatar(
        radius: 14,
        backgroundColor: colorOf(who).withValues(alpha: 0.15),
        child: Icon(iconOf(who), size: 16, color: colorOf(who)),
      ),
      title: Text('${e['peca'] ?? ''} · $nome'),
      subtitle: (e['texto'] as String? ?? '').isEmpty
          ? null
          : Text(e['texto'] as String, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: Text(
        [hour(DateTime.tryParse('${e['t']}')), if (cost > 0) dollars(cost, places: 2)].join('\n'),
        textAlign: TextAlign.end,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}
