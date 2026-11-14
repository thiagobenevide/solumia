import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../modelos.dart';
import 'util.dart';

/// Painel ao vivo da fábrica de peças: o Claude cria as ideias, a LLM local escreve cada peça em N1, o portão
/// renderiza e mede, o Claude revisa (e grava a lição no guia), você aprova e a peça entra no acervo e no dataset.
/// Mostra onde o fluxo está agora, quem está trabalhando (Claude × LLM local), os números de hoje e as thumbs.
class FabricaAba extends StatelessWidget {
  const FabricaAba({super.key, required this.api});

  final ApiEsteira api;

  @override
  Widget build(BuildContext context) => Sondagem<Json>(
    intervalo: const Duration(seconds: 3),
    carregar: api.painelFabrica,
    construir: (context, d, recarregar) {
      final agora = [for (final a in d['agora'] as List) a as Json];
      final ativo = agora.where((a) => a['rodando'] == true).firstOrNull;
      final chamadas = [for (final c in d['chamadas'] as List) c as Json];
      final hoje = d['hoje'] as Json;
      final motion = hoje['motion'] as Json;
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _Agente(
                quem: 'claude',
                titulo: 'Claude',
                papel: 'cria ideias e revisa as peças',
                chamada: chamadas.where((c) => c['motor'] == 'claude').firstOrNull,
                extra: _Cota(d['cota'] as Json),
                rodape: 'hoje ${dolares(hoje['gasto_total'] as num?, casas: 2)} · '
                    '${(hoje['ideias'] as Json)['lotes']} lotes de ideias · ${motion['revisoes']} revisões',
              ),
              _Agente(
                quem: 'local',
                titulo: 'LLM local',
                papel: 'escreve cada peça em N1 (sem custo)',
                chamada: chamadas.where((c) => c['motor'] == 'local').firstOrNull,
                rodape: 'hoje ${motion['local']} tentativas · ${motion['geradas']} passaram no portão',
              ),
            ],
          ),
          const Secao('Fluxo agora'),
          _Fluxo(d: d, ativo: ativo),
          Secao(
            'Pedidos',
            acao: Wrap(
              spacing: 8,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.lightbulb_outline),
                  label: const Text('Gerar ideias com o Claude'),
                  onPressed: () => _novasIdeias(context, recarregar),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.swap_horiz),
                  label: const Text('Portar HTML com a LLM'),
                  onPressed: () => acaoComAviso(context, () async {
                    await api.portarHtml();
                    await recarregar();
                    return 'Porte na fila (só LLM local)';
                  }),
                ),
              ],
            ),
          ),
          _Pedidos([for (final p in d['pedidos'] as List) p as Json], api: api, recarregar: recarregar),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, c) {
              final largura = c.maxWidth >= 1100 ? (c.maxWidth - 24) / 3 : (c.maxWidth >= 700 ? (c.maxWidth - 12) / 2 : c.maxWidth);
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  SizedBox(width: largura, child: _Ideias(d)),
                  SizedBox(width: largura, child: _Motion(d)),
                  SizedBox(width: largura, child: _Thumbs(d)),
                ],
              );
            },
          ),
          _Licoes(d['licoes'] as Json),
          const Secao('Linha do tempo'),
          Card(
            child: Column(children: [for (final e in d['eventos'] as List) _Evento(e as Json)]),
          ),
        ],
      );
    },
  );

  Future<void> _novasIdeias(BuildContext context, Future<void> Function() recarregar) async {
    final tema = TextEditingController();
    var quantidade = 24.0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, mudar) => AlertDialog(
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
                  onChanged: (v) => mudar(() => quantidade = v),
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
    await acaoComAviso(context, () async {
      await api.gerarIdeias(quantidade.round(), tema.text);
      await recarregar();
      return 'Pedido de ideias na fila';
    });
  }
}

/// Cor e ícone de quem fez cada coisa.
Color corDe(String quem) => switch (quem) {
  'claude' => Colors.deepPurple,
  'local' => Colors.orange.shade800,
  'voce' => Colors.blue,
  _ => Colors.blueGrey,
};

IconData iconeDe(String quem) => switch (quem) {
  'claude' => Icons.auto_awesome,
  'local' => Icons.memory,
  'voce' => Icons.person_outline,
  _ => Icons.settings_outlined,
};

class _Agente extends StatelessWidget {
  const _Agente({
    required this.quem,
    required this.titulo,
    required this.papel,
    required this.chamada,
    required this.rodape,
    this.extra,
  });

  final String quem;
  final String titulo;
  final String papel;
  final Json? chamada;
  final String rodape;
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cor = corDe(quem);
    final c = chamada;
    return SizedBox(
      width: 420,
      child: Card(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: c != null ? cor : cor.withValues(alpha: 0.25), width: c != null ? 2 : 1),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(iconeDe(quem), color: cor),
                  const SizedBox(width: 8),
                  Text(titulo, style: t.titleMedium),
                  const Spacer(),
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(c != null ? 'trabalhando' : 'ocioso'),
                    backgroundColor: c != null ? cor.withValues(alpha: 0.15) : null,
                  ),
                ],
              ),
              Text(papel, style: t.bodySmall),
              const SizedBox(height: 8),
              if (c != null) ...[
                Text('${c['nome']} · ${c['modelo'] ?? ''}', style: t.bodyMedium),
                Text('${c['tokens']} tokens · ${duracao((c['segundos'] as num?)?.toDouble())}', style: t.bodySmall),
                const SizedBox(height: 6),
                LinearProgressIndicator(color: cor),
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

class _Cota extends StatelessWidget {
  const _Cota(this.cota);

  final Json cota;

  @override
  Widget build(BuildContext context) {
    final janelas = cota['janelas'] as Json;
    final limite = (cota['limite'] as num?)?.toDouble() ?? 0.9;
    final nomes = {'five_hour': 'janela de 5 h', 'seven_day': 'semana'};
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        children: [
          for (final k in janelas.keys)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  SizedBox(width: 110, child: Text(nomes[k] ?? k, style: Theme.of(context).textTheme.bodySmall)),
                  Expanded(
                    child: LinearProgressIndicator(
                      value: ((janelas[k] as Json)['uso'] as num).toDouble(),
                      color: ((janelas[k] as Json)['uso'] as num) >= limite ? Colors.red : Colors.deepPurple,
                      minHeight: 6,
                    ),
                  ),
                  SizedBox(
                    width: 48,
                    child: Text(
                      '${((((janelas[k] as Json)['uso'] as num)) * 100).round()}%',
                      textAlign: TextAlign.end,
                    ),
                  ),
                ],
              ),
            ),
          if (cota['cheia'] == true)
            const Text('cota no limite: o Claude para até a janela virar', style: TextStyle(color: Colors.red)),
        ],
      ),
    );
  }
}

/// O fluxo em etapas, com a etapa em andamento acesa e o que está nela.
class _Fluxo extends StatelessWidget {
  const _Fluxo({required this.d, required this.ativo});

  final Json d;
  final Json? ativo;

  @override
  Widget build(BuildContext context) {
    final hoje = d['hoje'] as Json;
    final motion = hoje['motion'] as Json;
    final acervo = d['acervo'] as Json;
    final etapa = (ativo?['etapa'] as Json?) ?? const {};
    final nome = etapa['nome'] as String?;
    final ideias = (d['ideias_na_fila'] as List).length;
    final etapas = [
      ('ideias', 'Ideias', 'claude', '${(hoje['ideias'] as Json)['lotes']} lotes hoje'),
      ('fila', 'Fila de ideias', 'sistema', '$ideias esperando'),
      ('n1', 'Peça em N1', 'local', '${motion['local']} tentativas'),
      ('portao', 'Portão', 'sistema', '${motion['descartadas']} descartes'),
      ('revisao', 'Revisão', 'claude', '${motion['revisoes']} revisões'),
      ('voce', 'Sua revisão', 'voce', '${d['revisao']} esperando'),
      ('acervo', 'Acervo EC', 'sistema', '${(acervo['effectcraft'] as Json)['aprovada']} aprovadas'),
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
                  for (final (i, e) in etapas.indexed) ...[
                    if (i > 0) const Icon(Icons.arrow_forward, size: 18, color: Colors.grey),
                    _No(rotulo: e.$2, quem: e.$3, numero: e.$4, aceso: nome == e.$1),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
            if (ativo == null)
              Text('Nada rodando agora. Gere ideias ou retome um pedido.', style: t.bodyMedium)
            else
              Text(
                [
                  if (etapa['peca'] != null && '${etapa['peca']}'.isNotEmpty) 'peça ${etapa['peca']}',
                  if ((etapa['rodada'] as num? ?? 0) > 0) 'rodada ${etapa['rodada']} de ${etapa['de']}',
                  if (etapa['desde'] != null) 'há ${_desde(etapa['desde'] as String)}',
                  ativo!['situacao'] as String? ?? '',
                ].where((s) => s.isNotEmpty).join(' · '),
                style: t.bodyMedium,
              ),
          ],
        ),
      ),
    );
  }

  static String _desde(String iso) {
    final t = DateTime.tryParse(iso);
    return t == null ? '?' : duracao(DateTime.now().difference(t).inSeconds.toDouble());
  }
}

class _No extends StatelessWidget {
  const _No({required this.rotulo, required this.quem, required this.numero, required this.aceso});

  final String rotulo;
  final String quem;
  final String numero;
  final bool aceso;

  @override
  Widget build(BuildContext context) {
    final cor = corDe(quem);
    final t = Theme.of(context).textTheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: 132,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: aceso ? cor.withValues(alpha: 0.18) : null,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: aceso ? cor : cor.withValues(alpha: 0.3), width: aceso ? 2 : 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(iconeDe(quem), size: 16, color: cor),
              const SizedBox(width: 4),
              Expanded(child: Text(rotulo, style: t.labelLarge, overflow: TextOverflow.ellipsis)),
            ],
          ),
          const SizedBox(height: 4),
          Text(numero, style: t.bodySmall),
          if (aceso) ...[const SizedBox(height: 6), LinearProgressIndicator(color: cor, minHeight: 3)],
        ],
      ),
    );
  }
}

class _Pedidos extends StatelessWidget {
  const _Pedidos(this.pedidos, {required this.api, required this.recarregar});

  final List<Json> pedidos;
  final ApiEsteira api;
  final Future<void> Function() recarregar;

  @override
  Widget build(BuildContext context) {
    if (pedidos.isEmpty) return const Vazio('Nenhum pedido aberto');
    return Card(
      child: Column(
        children: [
          for (final p in pedidos)
            ListTile(
              dense: true,
              leading: Icon(p['tipo'] == 'ideias' ? Icons.lightbulb_outline : Icons.swap_horiz),
              title: Text(p['tipo'] == 'ideias' ? 'Ideias: ${p['texto']}' : 'Porte HTML → EffectCraft'),
              subtitle: Text(
                p['tipo'] == 'ideias'
                    ? '${p['pecas']} peças · ${p['descartadas']} descartes de ${p['quantidade']} · '
                          '${p['ideias_na_fila']} ideias na fila · ${dolares(p['gasto_usd'] as num?, casas: 2)}'
                    : '${p['feitos']} de ${p['alvos']} peças tentadas · ${p['pecas']} portadas',
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SeloEstado(p['rodando'] == true ? 'rodando' : (p['na_fila'] == true ? 'na fila' : '${p['estado']}')),
                  IconButton(
                    tooltip: p['estado'] == 'pausado' ? 'Retomar' : 'Pausar',
                    icon: Icon(p['estado'] == 'pausado' ? Icons.play_arrow : Icons.pause),
                    onPressed: () => acaoComAviso(context, () async {
                      await api.pausarPedido(p['id'] as String, p['estado'] != 'pausado');
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

class _Bloco extends StatelessWidget {
  const _Bloco({required this.titulo, required this.icone, required this.filhos});

  final String titulo;
  final IconData icone;
  final List<Widget> filhos;

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
          ...filhos,
        ],
      ),
    ),
  );
}

/// Barra de progresso com rótulo: `feito` de `total`.
class _Barra extends StatelessWidget {
  const _Barra(this.rotulo, this.feito, this.total, {this.cor});

  final String rotulo;
  final num feito;
  final num total;
  final Color? cor;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$rotulo: $feito${total > 0 ? ' de $total' : ''}', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 2),
        LinearProgressIndicator(value: total > 0 ? (feito / total).clamp(0, 1).toDouble() : 0, color: cor, minHeight: 6),
      ],
    ),
  );
}

class _Ideias extends StatelessWidget {
  const _Ideias(this.d);

  final Json d;

  @override
  Widget build(BuildContext context) {
    final fila = [for (final i in d['ideias_na_fila'] as List) i as Json];
    final hoje = (d['hoje'] as Json)['ideias'] as Json;
    return _Bloco(
      titulo: 'Ideias',
      icone: Icons.lightbulb_outline,
      filhos: [
        Text('${hoje['lotes']} lotes do Claude hoje · ${dolares(hoje['custo'] as num?, casas: 2)}'),
        const Divider(),
        if (fila.isEmpty) const Text('Fila de ideias vazia.'),
        for (final i in fila.take(8))
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.circle, size: 10, color: corDe('claude')),
            title: Text('${i['id']}'),
            subtitle: Text('${i['descricao']}', maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        if (fila.length > 8) Text('+ ${fila.length - 8} ideias'),
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
    final acervo = d['acervo'] as Json;
    final ds = (d['dataset'] as Json)['peca_animar'] as Json? ?? const {};
    final motivos = [for (final x in m['motivos'] as List) x as Json];
    final maior = motivos.fold<num>(1, (a, x) => (x['n'] as num) > a ? x['n'] as num : a);
    String linha(String motor) {
      final a = acervo[motor] as Json;
      return '${a['aprovada']} aprovadas · ${a['revisao']} em revisão · ${a['rascunho']} rascunhos';
    }

    return _Bloco(
      titulo: 'Motion graphics',
      icone: Icons.animation,
      filhos: [
        Text('Hoje: ${m['tentativas']} tentativas · ${m['geradas']} no portão · ${m['descartadas']} descartes · ${m['puladas'] ?? 0} puladas (o N1 não desenha)'),
        Text('Revisão do Claude: ${m['revisoes']} (${m['aprovadas_claude']} aprovadas) · '
            '${dolares(m['custo_revisao'] as num?, casas: 2)}'),
        const Divider(),
        Text('Por que foram descartadas', style: Theme.of(context).textTheme.labelLarge),
        if (motivos.isEmpty) const Text('nenhum descarte hoje'),
        for (final x in motivos) _Barra('${x['motivo']}', x['n'] as num, maior, cor: Colors.red.shade300),
        const Divider(),
        Text('Acervo EffectCraft: ${linha('effectcraft')}'),
        Text('Acervo HTML: ${linha('html')}'),
        _Barra('Dataset peca_animar (bons para treino)', (ds['sft'] as num?) ?? 0, (ds['minimo'] as num?) ?? 0,
            cor: Colors.green),
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
    final foto = (d['dataset'] as Json)['foto_tratar'] as Json? ?? const {};
    final tarefas = [for (final t in (d['thumbs'] as Json)['tarefas'] as List) t as Json];
    return _Bloco(
      titulo: 'Thumbnails',
      icone: Icons.image_outlined,
      filhos: [
        _Barra('Thumbs aprovadas para treino', (ds['sft'] as num?) ?? 0, (ds['minimo'] as num?) ?? 0, cor: Colors.green),
        Text('${ds['pendente'] ?? 0} esperando sua escolha (aba Thumbs do episódio)'),
        _Barra('Fotos tratadas', (foto['sft'] as num?) ?? 0, (foto['minimo'] as num?) ?? 0, cor: Colors.green),
        const Divider(),
        if (tarefas.isEmpty) const Text('Nenhuma thumb sendo gerada agora.'),
        for (final t in tarefas)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.photo_filter_outlined),
            title: Text('${t['ep']}'),
            trailing: SeloEstado('${t['estado']}'),
          ),
      ],
    );
  }
}

class _Licoes extends StatelessWidget {
  const _Licoes(this.l);

  final Json l;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Secao('Lições no guia da LLM (${l['total']})'),
      Card(
        child: Column(
          children: [
            for (final x in (l['ultimas'] as List).reversed)
              ListTile(
                dense: true,
                leading: Icon(Icons.school_outlined, color: corDe('claude')),
                title: Text('$x'),
              ),
          ],
        ),
      ),
    ],
  );
}

class _Evento extends StatelessWidget {
  const _Evento(this.e);

  final Json e;

  @override
  Widget build(BuildContext context) {
    final quem = e['quem'] as String? ?? 'sistema';
    final evento = e['evento'] as String? ?? '';
    final nome = switch (evento) {
      'revisao' => e['aprovada'] == true ? 'Claude aprovou' : 'Claude reprovou',
      'gerada' => 'passou no portão',
      'descartada' => 'descartada',
      'aprovada' => 'você aprovou',
      'reprovada' => 'você reprovou',
      'pedido' => 'pedido novo',
      _ => evento,
    };
    final custo = (e['custo'] as num?) ?? 0;
    return ListTile(
      dense: true,
      leading: CircleAvatar(
        radius: 14,
        backgroundColor: corDe(quem).withValues(alpha: 0.15),
        child: Icon(iconeDe(quem), size: 16, color: corDe(quem)),
      ),
      title: Text('${e['peca'] ?? ''} · $nome'),
      subtitle: (e['texto'] as String? ?? '').isEmpty
          ? null
          : Text(e['texto'] as String, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: Text(
        [hora(DateTime.tryParse('${e['t']}')), if (custo > 0) dolares(custo, casas: 2)].join('\n'),
        textAlign: TextAlign.end,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}
