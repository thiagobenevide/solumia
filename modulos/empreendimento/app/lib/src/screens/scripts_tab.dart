import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../models.dart';
import 'episode/episode_screen.dart';
import 'util.dart';

/// Vault library per channel: summary, status filter and the scripts to produce (imports and queues
/// `tudo`). Only scripts with recorded narration or that already are an episode can be picked.
class ScriptsTab extends StatefulWidget {
  const ScriptsTab({super.key, required this.api});

  final ApiEsteira api;

  @override
  State<ScriptsTab> createState() => _ScriptsTabState();
}

class _ScriptsTabState extends State<ScriptsTab> {
  late final Future<List<Channel>> _channels = widget.api.channels();
  String? _channel;
  String _status = '';
  final _chosen = <String>{};

  /// Template (`id@N`) chosen per script, and the channel's template versions (`vN - nome`).
  final _templates = <String, String>{};
  List<Json> _versions = [];
  String? _versionsOf;

  static const _vaultStatus = ['rascunho', 'revisado', 'gravado', 'publicado'];

  void _loadVersions(String channel) {
    if (_versionsOf == channel) return;
    _versionsOf = channel;
    _versions = [];
    widget.api
        .templates(channel)
        .then((ts) {
          if (!mounted || _versionsOf != channel) return;
          setState(() => _versions = [for (final t in ts.cast<Json>()) for (final v in t['versoes'] as List) v as Json]);
        })
        .catchError((Object _) {});
  }

  /// The one already chosen; otherwise the newest locked version of the script's mode; otherwise the newest of the mode; otherwise the first.
  String? _isDefault(Script r) {
    if (r.template != null) return r.template;
    final ofMode = _versions.where((v) => v['modo'] == r.modo);
    return (ofMode.where((v) => v['travado'] == true).firstOrNull ?? ofMode.firstOrNull ?? _versions.firstOrNull)?['ref']
        as String?;
  }

  Widget _selectorTemplate(Script r) {
    final current = _templates[r.caminho] ?? _isDefault(r);
    return DropdownButton<String>(
      isDense: true,
      value: _versions.any((v) => v['ref'] == current) ? current : null,
      hint: const Text('escolher template'),
      items: [
        for (final v in _versions)
          DropdownMenuItem(
            value: v['ref'] as String,
            child: Text('Template ${v['rotulo']} · ${v['modo']}${v['travado'] == true ? ' 🔒' : ''}'),
          ),
      ],
      onChanged: (ref) {
        if (ref == null) return;
        setState(() => _templates[r.caminho] = ref);
        if (r.ep != null) {
          actionWithWarning(context, () async {
            await widget.api.chooseTemplate(r.ep!, ref);
            return 'Template da produção de ${r.ep}: ${ref.replaceFirst('@', ' v')}';
          });
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _channels,
    builder: (context, s) {
      if (s.hasError) return ErroComRetry(erro: s.error!, tentar: () => setState(() {}));
      final channels = s.data;
      if (channels == null) return const Center(child: CircularProgressIndicator());
      if (channels.isEmpty) return const Empty('Nenhum canal no vault.');
      final channel = _channel ?? channels.first.id;
      _loadVersions(channel);
      return Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                spacing: 8,
                children: [
                  for (final c in channels)
                    ChoiceChip(
                      label: Text('${c.id} · ${c.scripts}'),
                      selected: channel == c.id,
                      onSelected: (_) => setState(() {
                        _channel = c.id;
                        _chosen.clear();
                        _templates.clear();
                      }),
                    ),
                  const SizedBox(width: 8),
                  DropdownButton<String>(
                    value: _status,
                    items: [
                      const DropdownMenuItem(value: '', child: Text('Todos os status')),
                      for (final st in _vaultStatus) DropdownMenuItem(value: st, child: Text(st)),
                    ],
                    onChanged: (v) => setState(() => _status = v ?? ''),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Sondagem<List<Script>>(
              key: ValueKey(channel),
              intervalo: const Duration(seconds: 15),
              carregar: () => widget.api.scripts(channel),
              construir: (context, all, _) {
                final scripts = [
                  for (final r in all)
                    if (_status.isEmpty || r.status == _status) r,
                ];
                return ListView(
                  padding: const EdgeInsets.only(bottom: 88),
                  children: [
                    _summary(scripts),
                    if (scripts.isEmpty) const Empty('Nenhum roteiro neste canal.'),
                    for (final r in scripts) _line(context, r),
                  ],
                );
              },
            ),
          ),
          if (_chosen.isNotEmpty)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: Text('Produzir ${_chosen.length} vídeo(s)'),
                  onPressed: _produce,
                ),
              ),
            ),
        ],
      );
    },
  );

  Widget _summary(List<Script> rs) {
    final projects = rs.where((r) => r.ep != null);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          Indicator(
            'Roteiros',
            '${rs.length}',
            sub: '${rs.where((r) => r.format == '9:16').length} Shorts 9:16',
          ),
          Indicator('Com áudio', '${rs.where((r) => r.audio).length}', sub: 'prontos para a esteira'),
          Indicator('Em projeto', '${projects.length}', sub: 'já importados'),
          Indicator(
            'Vídeos prontos',
            '${projects.where((r) => r.prog?.finalReady ?? false).length}',
            sub: 'final.mp4 exportado',
          ),
          Indicator(
            'Citações com PDF',
            '${rs.fold(0, (n, r) => n + r.quotes)}',
            sub: 'blocos [!cite] no vault',
          ),
        ],
      ),
    );
  }

  Widget _line(BuildContext context, Script r) {
    final p = r.prog;
    final pequeno = Theme.of(context).textTheme.bodySmall;
    return Opacity(
      opacity: r.produzivel ? 1 : 0.55,
      child: CheckboxListTile(
        value: _chosen.contains(r.caminho),
        onChanged: !r.produzivel || p?.rodando != null
            ? null
            : (v) => setState(() {
                if (!v!) {
                  _chosen.remove(r.caminho);
                  return;
                }
                _chosen.add(r.caminho);
                final defaultValue = _isDefault(r);
                if (defaultValue != null) _templates.putIfAbsent(r.caminho, () => defaultValue);
              }),
        title: Text('${r.label} — ${r.titulo}', maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 4,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                EnginePill('', label: r.format == '9:16' ? 'Short · 9:16' : 'Longo · 16:9'),
                r.definedMode
                    ? EnginePill('', label: r.modo == 'apresentador' ? '🎥 Apresentador' : '🎙 Dark')
                    : const EnginePill('', label: 'modo a definir', fixedColor: Colors.amber),
                EnginePill('', label: r.status.isEmpty ? 'sem status' : r.status),
                r.audio
                    ? EnginePill('', label: '● áudio ${r.audioMb ?? '?'} MB', fixedColor: Colors.green)
                    : const EnginePill('', label: '○ sem áudio'),
                r.quotes > 0
                    ? EnginePill(
                        '',
                        label: '❝ ${r.quotes} ${r.quotes == 1 ? 'citação' : 'citações'}',
                        fixedColor: Colors.amber,
                      )
                    : const EnginePill('', label: 'sem citação com PDF'),
                if (_versions.isNotEmpty && r.produzivel)
                  _selectorTemplate(r)
                else if (_versions.isEmpty && r.produzivel)
                  const EnginePill('', label: 'sem template no canal: crie no Estúdio', fixedColor: Colors.amber),
              ],
            ),
            if (p != null)
              Row(
                spacing: 8,
                children: [
                  Expanded(child: LinearProgressIndicator(value: p.fraction)),
                  Text(
                    p.finalReady && p.outdated
                        ? '⚠ vídeo desatualizado'
                        : p.finalReady
                        ? '✓ vídeo pronto'
                        : p.rodando != null
                        ? '${p.rodando}…'
                        : p.erro != null
                        ? 'erro em ${p.erro}'
                        : '${p.doneSteps}/${p.total} etapas',
                    style: pequeno,
                  ),
                  TextButton(
                    onPressed: () => abrirTela(context, (_) => EpisodeScreen(api: widget.api, ep: r.ep!, titulo: r.titulo)),
                    child: Text('abrir ${r.ep}'),
                  ),
                ],
              )
            else
              Text(
                r.audio ? 'Pronto para importar e produzir' : 'Grave e exporte o áudio para liberar',
                style: pequeno,
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _produce() => actionWithWarning(context, () async {
    final n = await widget.api.produce(
      _chosen.toList(),
      templates: {
        for (final c in _chosen) c: ?_templates[c],
      },
    );
    setState(_chosen.clear);
    return n == 0 ? 'Já estavam todos na fila.' : '$n episódio(s) na fila de produção.';
  });
}
