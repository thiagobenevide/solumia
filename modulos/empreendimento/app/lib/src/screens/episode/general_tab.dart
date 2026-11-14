import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../../api_esteira.dart';
import '../../models.dart';
import '../util.dart';
import 'remote_edit.dart';
import 'final_video.dart';

/// Episode overview: progress, stages with who runs each one, activity, video, manual edit
/// and sources. Same as the episode page in the panel.
class GeneralTab extends StatelessWidget {
  const GeneralTab({super.key, required this.api, required this.ep});

  final ApiEsteira api;
  final String ep;

  /// Stages with a run/redo button in the list (the others only run through "Produzir tudo").
  static const _withButton = {'clean', 'curate', 'fetch', 'evaluate', 'graphics', 'assemble', 'thumb', 'scenes'};

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: api.meta,
    builder: (context, meta) => Sondagem<Episode>(
      intervalo: const Duration(seconds: 2),
      carregar: () => api.episode(ep),
      construir: (context, e, _) => LayoutBuilder(
        builder: (context, area) {
          final main = _main(context, e, meta.data);
          final lateral = _lateral(context, e);
          if (area.maxWidth < 1000) {
            return ListView(padding: const EdgeInsets.all(16), children: [...main, ...lateral]);
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ListView(padding: const EdgeInsets.all(16), children: main),
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

  List<Widget> _main(BuildContext context, Episode e, Json? meta) {
    final p = e.prog;
    final engines = (meta?['motores'] as Json?) ?? const {};
    return [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          Chip(label: Text(e.channel)),
          Chip(label: Text(e.vertical ? 'Short · 9:16' : 'Longo · 16:9')),
          Chip(
            avatar: Icon(e.modo == 'apresentador' ? Icons.videocam : Icons.mic, size: 16),
            label: Text(e.modo == 'apresentador' ? 'Apresentador' : 'Dark'),
          ),
          if (e.camera != null) Chip(label: Text(_camera(e.camera!))),
          if (e.withoutCamera) const StatePill('erro', texto: 'sem vídeo da câmera'),
          if (e.parts > 0) Chip(label: Text('${e.parts} partes')),
          if (e.notes > 0) Chip(label: Text('${e.notes} notas de cena')),
          Chip(label: Text('❝ ${e.quotes} ${e.quotes == 1 ? 'citação' : 'citações'} com PDF')),
          Chip(label: Text('${e.sources.length} fontes')),
        ],
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: LinearProgressIndicator(
              value: p.fraction,
              color: corDoEstado(Theme.of(context).colorScheme, p.state),
            ),
          ),
          const SizedBox(width: 12),
          Text('${p.doneSteps}/${p.total} etapas'),
        ],
      ),
      const SizedBox(height: 6),
      if (p.finalReady && p.outdated)
        const StatePill('erro', texto: 'vídeo desatualizado: produza de novo')
      else if (p.finalReady)
        const StatePill('ok', texto: 'vídeo pronto')
      else if (p.rodando != null)
        StatePill('rodando', texto: '${_nome(meta, p.rodando!)}…'),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilledButton.icon(
            icon: const Icon(Icons.play_arrow),
            label: const Text('Produzir tudo'),
            onPressed: p.rodando != null ? null : () => _run(context, 'all'),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.restart_alt),
            label: const Text('Refazer tudo do zero'),
            onPressed: p.rodando != null ? null : () => _confirmFromScratch(context),
          ),
          Text('IA: ${e.aiEngine} (trocar em Opções)', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
      const Section('Etapas da esteira'),
      Card(
        child: Column(
          children: [
            for (final stage in e.stages)
              _stage(context, stage, p.rodando != null, engines[stage.id] as List? ?? const []),
          ],
        ),
      ),
      Section('Atividade', acao: Text('Claude neste episódio: ${dollars(e.spentClaude)}')),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: e.events.isEmpty
              ? const Text('Nenhuma atividade ainda.')
              : Column(children: [for (final ev in e.events) _event(context, ev)]),
        ),
      ),
    ];
  }

  List<Widget> _lateral(BuildContext context, Episode e) => [
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
                if (e.hasProjectFilmCraft) ...[
                  OutlinedButton(
                    onPressed: () => actionWithWarning(context, () async {
                      await api.openFilmCraft(ep);
                      return 'Abrindo o vídeo no FilmCraft (no PC).';
                    }),
                    child: const Text('Vídeo no FilmCraft'),
                  ),
                  RemoteEdit(
                    url: api.packageFilmCraft(ep),
                    extensions: const ['fcproj'],
                    send: (nome, bytes) => api.sendFilmCraft(ep, nome, bytes),
                    done: 'Projeto enviado: use "Reexportar vídeo" para refazer o final.mp4.',
                  ),
                  FilledButton.tonal(
                    onPressed: () => _run(context, 'export'),
                    child: const Text('Reexportar vídeo'),
                  ),
                  // verdict on the generated assembly: it becomes training data (dataset `montar` task)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.thumb_up_alt_outlined),
                    onPressed: () => actionWithWarning(context, () async {
                      await api.verdictAssembly(ep, 'aprovada');
                      return 'Montagem aprovada: entra como exemplo de treino.';
                    }),
                    label: const Text('Montagem boa'),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.thumb_down_alt_outlined),
                    onPressed: () => actionWithWarning(context, () async {
                      await api.verdictAssembly(ep, 'ajuste');
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
    if (e.mainThumb != null)
      Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Image.network(api.arquivo(e.mainThumb!), fit: BoxFit.cover),
            ),
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Thumbnail principal (variantes em thumb_1..3.png)'),
            ),
          ],
        ),
      ),
    if (e.sources.isNotEmpty)
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
              for (final f in e.sources.take(6))
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

  static String _nome(Json? meta, String stage) => ((meta?['nomes'] as Json?)?[stage] as String?) ?? stage;

  static String _camera(Json c) {
    final sync = c['confianca_sync'] is num
        ? ' · sync ${(c['offset'] as num) >= 0 ? '+' : ''}${(c['offset'] as num).toStringAsFixed(2)}s '
              '(${((c['confianca_sync'] as num) * 100).round()}%)'
        : '';
    return 'câmera ${c['largura']}×${c['altura']}$sync';
  }

  Widget _stage(BuildContext context, Stage stage, bool somethingRunning, List engines) {
    final cores = Theme.of(context).colorScheme;
    final feita = stage.status != 'pendente';
    return ListTile(
      leading: Icon(iconOfState(stage.status), color: corDoEstado(cores, stage.status)),
      title: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(stage.nome),
          for (final m in engines) EnginePill('${(m as Json)['motor']}', label: '${m['rotulo']}'),
          if (stage.warnings > 0) StatePill('na fila', texto: '${stage.warnings} avisos'),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 4,
        children: [
          if (stage.status == 'rodando' && stage.total != null) ...[
            LinearProgressIndicator(value: stage.fraction),
            Text(
              '${stage.done}/${stage.total}'
              '${stage.secondsLeft != null && stage.secondsLeft! > 0 ? ' · faltam ${duration(stage.secondsLeft)}' : ''}',
            ),
          ],
          if (stage.msg.isNotEmpty) Text(stage.msg, maxLines: 2, overflow: TextOverflow.ellipsis),
          if (stage.status != 'rodando' && stage.durationSeconds != null)
            Text('${dayHour(stage.start)} · ${duration(stage.durationSeconds)}'),
        ],
      ),
      trailing: !_withButton.contains(stage.id)
          ? null
          : PopupMenuButton<String>(
              enabled: !somethingRunning,
              tooltip: 'Rodar etapa',
              onSelected: (acao) => switch (acao) {
                'claude' => _run(context, stage.id, redo: true, engine: 'claude'),
                'refazer' => _run(context, stage.id, redo: true),
                _ => _run(context, stage.id),
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'rodar', child: Text(feita ? 'Rodar de novo' : 'Rodar')),
                if (const {'clean', 'curate', 'fetch'}.contains(stage.id))
                  const PopupMenuItem(value: 'refazer', child: Text('Refazer do zero')),
                if (stage.id == 'curate')
                  const PopupMenuItem(
                    value: 'claude',
                    child: Text('Refazer com Claude (em paralelo, conta no teto)'),
                  ),
              ],
            ),
    );
  }

  Widget _event(BuildContext context, Event ev) {
    final cores = Theme.of(context).colorScheme;
    final (color, texto) = switch (ev.kind) {
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
          Text(hour(ev.t), style: mono.copyWith(color: cores.outline)),
          SizedBox(
            width: 70,
            child: Text(ev.stage, overflow: TextOverflow.ellipsis, style: mono),
          ),
          Expanded(
            child: Text(texto, style: mono.copyWith(color: color)),
          ),
        ],
      ),
    );
  }

  Future<void> _run(BuildContext context, String stage, {bool redo = false, String engine = ''}) =>
      actionWithWarning(context, () async {
        final entrou = await api.run(ep, stage, redo: redo, engine: engine);
        return entrou ? '$stage${redo ? ' (do zero)' : ''} na fila.' : '$stage já estava na fila.';
      });

  Future<void> _confirmFromScratch(BuildContext context) async {
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
    if (ok == true && context.mounted) await _run(context, 'all', redo: true);
  }
}
