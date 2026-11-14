import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../../api_esteira.dart';
import '../../modelos.dart';
import '../util.dart';
import 'edicao_remota.dart';
import 'video_final.dart';

/// Visão geral do episódio: andamento, etapas com quem faz cada uma, atividade, vídeo, edição manual
/// e fontes. Igual à página do episódio no painel.
class GeralAba extends StatelessWidget {
  const GeralAba({super.key, required this.api, required this.ep});

  final ApiEsteira api;
  final String ep;

  /// Etapas com botão rodar/refazer na lista (as outras só rodam pelo "Produzir tudo").
  static const _comBotao = {'clean', 'curate', 'fetch', 'evaluate', 'graphics', 'assemble', 'thumb', 'scenes'};

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: api.meta,
    builder: (context, meta) => Sondagem<Episodio>(
      intervalo: const Duration(seconds: 2),
      carregar: () => api.episodio(ep),
      construir: (context, e, _) => LayoutBuilder(
        builder: (context, area) {
          final principal = _principal(context, e, meta.data);
          final lateral = _lateral(context, e);
          if (area.maxWidth < 1000) {
            return ListView(padding: const EdgeInsets.all(16), children: [...principal, ...lateral]);
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ListView(padding: const EdgeInsets.all(16), children: principal),
              ),
              SizedBox(
                width: 400,
                child: ListView(padding: const EdgeInsets.fromLTRB(0, 16, 16, 16), children: lateral),
              ),
            ],
          );
        },
      ),
    ),
  );

  List<Widget> _principal(BuildContext context, Episodio e, Json? meta) {
    final p = e.prog;
    final motores = (meta?['motores'] as Json?) ?? const {};
    return [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          Chip(label: Text(e.canal)),
          Chip(label: Text(e.vertical ? 'Short · 9:16' : 'Longo · 16:9')),
          Chip(
            avatar: Icon(e.modo == 'apresentador' ? Icons.videocam : Icons.mic, size: 16),
            label: Text(e.modo == 'apresentador' ? 'Apresentador' : 'Dark'),
          ),
          if (e.camera != null) Chip(label: Text(_camera(e.camera!))),
          if (e.semCamera) const SeloEstado('erro', texto: 'sem vídeo da câmera'),
          if (e.partes > 0) Chip(label: Text('${e.partes} partes')),
          if (e.notas > 0) Chip(label: Text('${e.notas} notas de cena')),
          Chip(label: Text('❝ ${e.citacoes} ${e.citacoes == 1 ? 'citação' : 'citações'} com PDF')),
          Chip(label: Text('${e.fontes.length} fontes')),
        ],
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: LinearProgressIndicator(
              value: p.fracao,
              color: corDoEstado(Theme.of(context).colorScheme, p.estado),
            ),
          ),
          const SizedBox(width: 12),
          Text('${p.feitas}/${p.total} etapas'),
        ],
      ),
      const SizedBox(height: 6),
      if (p.finalPronto && p.desatualizado)
        const SeloEstado('erro', texto: 'vídeo desatualizado: produza de novo')
      else if (p.finalPronto)
        const SeloEstado('ok', texto: 'vídeo pronto')
      else if (p.rodando != null)
        SeloEstado('rodando', texto: '${_nome(meta, p.rodando!)}…'),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilledButton.icon(
            icon: const Icon(Icons.play_arrow),
            label: const Text('Produzir tudo'),
            onPressed: p.rodando != null ? null : () => _rodar(context, 'all'),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.restart_alt),
            label: const Text('Refazer tudo do zero'),
            onPressed: p.rodando != null ? null : () => _confirmarDoZero(context),
          ),
          Text('IA: ${e.motorIa} (trocar em Opções)', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
      const Secao('Etapas da esteira'),
      Card(
        child: Column(
          children: [
            for (final etapa in e.etapas)
              _etapa(context, etapa, p.rodando != null, motores[etapa.id] as List? ?? const []),
          ],
        ),
      ),
      Secao('Atividade', acao: Text('Claude neste episódio: ${dolares(e.gastoClaude)}')),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: e.eventos.isEmpty
              ? const Text('Nenhuma atividade ainda.')
              : Column(children: [for (final ev in e.eventos) _evento(context, ev)]),
        ),
      ),
    ];
  }

  List<Widget> _lateral(BuildContext context, Episodio e) => [
    if (e.video != null) VideoFinal(url: api.arquivo(e.video!), vertical: e.vertical),
    Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Text('Edição manual', style: Theme.of(context).textTheme.titleSmall),
            const Text(
              'Tudo é criado automaticamente; aqui você abre cada arquivo na ferramenta, ajusta e salva (Ctrl+S). '
              'A esteira percebe o arquivo salvo e refaz só o que mudou.',
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (e.temProjetoFilmCraft) ...[
                  OutlinedButton(
                    onPressed: () => acaoComAviso(context, () async {
                      await api.abrirFilmCraft(ep);
                      return 'Abrindo o vídeo no FilmCraft (no PC).';
                    }),
                    child: const Text('Vídeo no FilmCraft'),
                  ),
                  EdicaoRemota(
                    url: api.pacoteFilmCraft(ep),
                    extensoes: const ['fcproj'],
                    enviar: (nome, bytes) => api.enviarFilmCraft(ep, nome, bytes),
                    feito: 'Projeto enviado: use "Reexportar vídeo" para refazer o final.mp4.',
                  ),
                  FilledButton.tonal(
                    onPressed: () => _rodar(context, 'export'),
                    child: const Text('Reexportar vídeo'),
                  ),
                  // veredito da montagem gerada: vira dado de treino (tarefa `montar` do dataset)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.thumb_up_alt_outlined),
                    onPressed: () => acaoComAviso(context, () async {
                      await api.vereditoMontagem(ep, 'aprovada');
                      return 'Montagem aprovada: entra como exemplo de treino.';
                    }),
                    label: const Text('Montagem boa'),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.thumb_down_alt_outlined),
                    onPressed: () => acaoComAviso(context, () async {
                      await api.vereditoMontagem(ep, 'ajuste');
                      return 'Anotado: corrija no FilmCraft e salve; a correção vira exemplo.';
                    }),
                    label: const Text('Precisa de ajuste'),
                  ),
                ],
                OutlinedButton(
                  onPressed: () => DefaultTabController.of(context).animateTo(4),
                  child: const Text('Gráficos no EffectCraft'),
                ),
                OutlinedButton(
                  onPressed: () => DefaultTabController.of(context).animateTo(5),
                  child: const Text('Thumbs no PhotoCraft'),
                ),
              ],
            ),
            if (e.manuais.isNotEmpty)
              Text(
                'Edições manuais guardadas: ${e.manuais.join(', ')}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
    ),
    if (e.thumbPrincipal != null)
      Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Image.network(api.arquivo(e.thumbPrincipal!), fit: BoxFit.cover),
            ),
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Thumbnail principal (variantes em thumb_1..3.png)'),
            ),
          ],
        ),
      ),
    if (e.fontes.isNotEmpty)
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              Row(
                children: [
                  Expanded(child: Text('Fontes do roteiro', style: Theme.of(context).textTheme.titleSmall)),
                  TextButton(
                    onPressed: () => DefaultTabController.of(context).animateTo(1),
                    child: const Text('ver todas'),
                  ),
                ],
              ),
              for (final f in e.fontes.take(6))
                Text.rich(
                  TextSpan(
                    text: '${f['autores']} (${f['ano']})\n',
                    children: [
                      TextSpan(
                        text: '${f['revista'] ?? ''}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
  ];

  static String _nome(Json? meta, String etapa) => ((meta?['nomes'] as Json?)?[etapa] as String?) ?? etapa;

  static String _camera(Json c) {
    final sync = c['confianca_sync'] is num
        ? ' · sync ${(c['offset'] as num) >= 0 ? '+' : ''}${(c['offset'] as num).toStringAsFixed(2)}s '
              '(${((c['confianca_sync'] as num) * 100).round()}%)'
        : '';
    return 'câmera ${c['largura']}×${c['altura']}$sync';
  }

  Widget _etapa(BuildContext context, Etapa etapa, bool algoRodando, List motores) {
    final cores = Theme.of(context).colorScheme;
    final feita = etapa.status != 'pendente';
    return ListTile(
      leading: Icon(iconeDoEstado(etapa.status), color: corDoEstado(cores, etapa.status)),
      title: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(etapa.nome),
          for (final m in motores) SeloMotor('${(m as Json)['motor']}', rotulo: '${m['rotulo']}'),
          if (etapa.avisos > 0) SeloEstado('na fila', texto: '${etapa.avisos} avisos'),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 4,
        children: [
          if (etapa.status == 'rodando' && etapa.total != null) ...[
            LinearProgressIndicator(value: etapa.fracao),
            Text(
              '${etapa.feito}/${etapa.total}'
              '${etapa.restaSegundos != null && etapa.restaSegundos! > 0 ? ' · faltam ${duracao(etapa.restaSegundos)}' : ''}',
            ),
          ],
          if (etapa.msg.isNotEmpty) Text(etapa.msg, maxLines: 2, overflow: TextOverflow.ellipsis),
          if (etapa.status != 'rodando' && etapa.duracaoSegundos != null)
            Text('${diaHora(etapa.inicio)} · ${duracao(etapa.duracaoSegundos)}'),
        ],
      ),
      trailing: !_comBotao.contains(etapa.id)
          ? null
          : PopupMenuButton<String>(
              enabled: !algoRodando,
              tooltip: 'Rodar etapa',
              onSelected: (acao) => switch (acao) {
                'claude' => _rodar(context, etapa.id, refazer: true, motor: 'claude'),
                'refazer' => _rodar(context, etapa.id, refazer: true),
                _ => _rodar(context, etapa.id),
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'rodar', child: Text(feita ? 'Rodar de novo' : 'Rodar')),
                if (const {'clean', 'curate', 'fetch'}.contains(etapa.id))
                  const PopupMenuItem(value: 'refazer', child: Text('Refazer do zero')),
                if (etapa.id == 'curate')
                  const PopupMenuItem(
                    value: 'claude',
                    child: Text('Refazer com Claude (em paralelo, conta no teto)'),
                  ),
              ],
            ),
    );
  }

  Widget _evento(BuildContext context, Evento ev) {
    final cores = Theme.of(context).colorScheme;
    final (cor, texto) = switch (ev.tipo) {
      'erro' => (cores.error, ev.msg),
      'aviso' => (Colors.amber, ev.msg),
      'claude' => (Colors.purple.shade200, '☁ ${ev.msg}'),
      'inicio' => (Colors.lightBlue.shade200, '▶ início'),
      'fim' => (Colors.green, '✓ fim'),
      _ => (cores.onSurfaceVariant, ev.msg),
    };
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 12);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 10,
        children: [
          Text(hora(ev.t), style: mono.copyWith(color: cores.outline)),
          SizedBox(
            width: 70,
            child: Text(ev.etapa, overflow: TextOverflow.ellipsis, style: mono),
          ),
          Expanded(
            child: Text(texto, style: mono.copyWith(color: cor)),
          ),
        ],
      ),
    );
  }

  Future<void> _rodar(BuildContext context, String etapa, {bool refazer = false, String motor = ''}) =>
      acaoComAviso(context, () async {
        final entrou = await api.rodar(ep, etapa, refazer: refazer, motor: motor);
        return entrou ? '$etapa${refazer ? ' (do zero)' : ''} na fila.' : '$etapa já estava na fila.';
      });

  Future<void> _confirmarDoZero(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Refazer o vídeo do zero?'),
        content: const Text(
          'A transcrição e os cortes da narração são decididos de novo (ajustes de corte feitos à mão se perdem), '
          'a curadoria é refeita e todas as etapas rodam outra vez. Com estilo do canal no Estúdio, a edição sai do '
          'acervo de motion graphics pelas suas falas. Gráficos e thumbs editados à mão são mantidos.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Voltar')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Refazer')),
        ],
      ),
    );
    if (ok == true && context.mounted) await _rodar(context, 'all', refazer: true);
  }
}
