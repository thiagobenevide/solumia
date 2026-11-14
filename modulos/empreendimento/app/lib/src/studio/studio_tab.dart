import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../models.dart';
import '../screens/episode/final_video.dart';
import '../screens/util.dart';
import 'library_screen.dart';
import 'style_screen.dart';
import 'factory_screen.dart';
import 'production_screen.dart';
import 'system.dart';

/// Studio tab: the channel network, each one's styles (Flow A) and the productions per style (Flow B).
class StudioTab extends StatefulWidget {
  const StudioTab({super.key, required this.api});

  final ApiEsteira api;

  @override
  State<StudioTab> createState() => _StudioTabState();
}

class _StudioTabState extends State<StudioTab> {
  String? _channel;

  @override
  Widget build(BuildContext context) => Sondagem<List<dynamic>>(
    intervalo: const Duration(seconds: 20),
    carregar: widget.api.studioChannels,
    construir: (context, channels, recarregar) {
      final list = [for (final c in channels) c as Json];
      final sel = list.where((c) => c['canal'] == _channel).firstOrNull ?? list.firstOrNull;
      return LayoutBuilder(
        builder: (context, box) {
          final largo = box.maxWidth > 900;
          final menu = _Channels(
            channels: list,
            selecionado: sel?['canal'] as String?,
            onChoose: (c) => setState(() => _channel = c),
            onAdd: () => _add(recarregar),
            api: widget.api,
          );
          final content = sel == null
              ? const Empty('Nenhum canal ainda. Use "Adicionar canal".', icone: Icons.add_circle_outline)
              : _Channel(api: widget.api, channel: sel, recarregar: recarregar);
          if (largo) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 280, child: menu),
                const VerticalDivider(width: 1),
                Expanded(child: content),
              ],
            );
          }
          return ListView(children: [SizedBox(height: 300, child: menu), const Divider(), SizedBox(height: 900, child: content)]);
        },
      );
    },
  );

  Future<void> _add(Future<void> Function() recarregar) async {
    final dados = await showDialog<Json>(context: context, builder: (_) => const _NewChannel());
    if (dados == null || !mounted) return;
    await actionWithWarning(context, () async {
      final e = await widget.api.newChannel(dados);
      return 'Canal criado com o estilo ${e['id']}. Envie referências e peça a proposta do Claude.';
    });
    setState(() => _channel = dados['slug'] as String);
    await recarregar();
  }
}

class _Channels extends StatelessWidget {
  const _Channels({
    required this.channels,
    required this.selecionado,
    required this.onChoose,
    required this.onAdd,
    required this.api,
  });

  final List<Json> channels;
  final String? selecionado;
  final ValueChanged<String> onChoose;
  final VoidCallback onAdd;
  final ApiEsteira api;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(12),
    children: [
      FilledButton.icon(onPressed: onAdd, icon: const Icon(Icons.add), label: const Text('Adicionar canal')),
      const SizedBox(height: 12),
      for (final c in channels)
        Card(
          color: c['canal'] == selecionado ? Theme.of(context).colorScheme.secondaryContainer : null,
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: color((c['estilos'] as List).isEmpty ? null : (c['estilos'] as List).first['destaque'] as String),
              child: Text('${c['canal']}'.substring(0, 1).toUpperCase()),
            ),
            title: Text('${c['canal']}'),
            subtitle: Text('${(c['estilos'] as List).length} template(s) ·${c['episodios']} episódio(s)'),
            onTap: () => onChoose(c['canal'] as String),
          ),
        ),
      const Divider(height: 32),
      ListTile(
        leading: const Icon(Icons.build_circle_outlined),
        title: const Text('Dependências do motor'),
        onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => SystemScreen(api: api))),
      ),
      ListTile(
        leading: const Icon(Icons.collections_outlined),
        title: const Text('Acervo de peças'),
        subtitle: const Text('Galeria, ficha e prévia em qualquer canal'),
        onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => LibraryScreen(api: api))),
      ),
      ListTile(
        leading: const Icon(Icons.auto_awesome_motion_outlined),
        title: const Text('Fábrica de peças'),
        subtitle: const Text('Claude gera, você revisa'),
        onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => FactoryScreen(api: api))),
      ),
    ],
  );
}

/// `#rrggbb` color → [Color] (grey if empty or invalid).
Color color(String? hex) {
  final v = int.tryParse((hex ?? '').replaceFirst('#', ''), radix: 16);
  return v == null ? Colors.grey : Color(0xFF000000 | v);
}

class _Channel extends StatelessWidget {
  const _Channel({required this.api, required this.channel, required this.recarregar});

  final ApiEsteira api;
  final Json channel;
  final Future<void> Function() recarregar;

  @override
  Widget build(BuildContext context) {
    final nome = channel['canal'] as String;
    return Sondagem<List<dynamic>>(
      key: ValueKey('templates-$nome'),
      intervalo: const Duration(seconds: 15),
      carregar: () => api.templates(nome),
      construir: (context, list, recarregarTemplates) {
        final templates = list.cast<Json>();
        final versions = [for (final t in templates) for (final v in t['versoes'] as List) v as Json];
        Future<void> reloadAll() async {
          await recarregar();
          await recarregarTemplates();
        }

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                Expanded(child: Text(nome, style: Theme.of(context).textTheme.headlineSmall)),
                FilledButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Novo template'),
                  onPressed: () => _new(context, nome, reloadAll),
                ),
              ],
            ),
            const Section('Templates (cada salvamento vira uma versão; o exemplo mostra a versão em 16:9 e 9:16)'),
            if (templates.isEmpty) const Text('Nenhum template neste canal: use "Novo template" e escolha o tipo.'),
            for (final t in templates) _Template(api: api, template: t, recarregar: reloadAll),
            const Section('Produções'),
            _Productions(api: api, channel: nome, styles: versions),
          ],
        );
      },
    );
  }

  Future<void> _new(BuildContext context, String channel, Future<void> Function() recarregar) async {
    final dados = await showDialog<Json>(context: context, builder: (_) => const _NewTemplate());
    if (dados == null || !context.mounted) return;
    Json? created;
    await actionWithWarning(context, () async {
      created = await api.newTemplate(
        channel,
        dados['modo'] as String,
        (dados['formatos'] as List).cast<String>(),
        nome: dados['nome'] as String,
      );
      return 'Template ${created!['nome']} criado (v1). Ajuste e salve; depois gere o exemplo.';
    });
    await recarregar();
    if (created == null || !context.mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => StyleScreen(api: api, id: created!['id'] as String)),
    );
    await recarregar();
  }
}

/// One channel template: version choice, edit and the version sample side by side (horizontal and vertical).
class _Template extends StatefulWidget {
  const _Template({required this.api, required this.template, required this.recarregar});

  final ApiEsteira api;
  final Json template;
  final Future<void> Function() recarregar;

  @override
  State<_Template> createState() => _TemplateState();
}

class _TemplateState extends State<_Template> {
  String? _ref;
  bool _playing = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.template;
    final versions = (t['versoes'] as List).cast<Json>();
    final v = versions.where((x) => x['ref'] == _ref).firstOrNull ?? versions.first;
    final samples = (v['amostras'] as Json).cast<String, bool>();
    final prontas = samples.values.where((x) => x).length;
    final pequeno = Theme.of(context).textTheme.bodySmall;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Row(
              spacing: 12,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: color(v['fundo'] as String?),
                    border: Border.all(color: color(v['destaque'] as String?), width: 3),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${t['nome']}', style: Theme.of(context).textTheme.titleMedium),
                      Text(
                        'prévia ${_kind(t['modo'] as String)} · ${(t['formatos'] as List).join(' · ')} · ${versions.length} versão(ões)',
                        style: pequeno,
                      ),
                    ],
                  ),
                ),
                _EditButton(
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute<void>(builder: (_) => StyleScreen(api: widget.api, id: t['id'] as String)),
                    );
                    setState(() => _ref = null); // goes back to the newest version (the one just saved)
                    await widget.recarregar();
                  },
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                DropdownButton<String>(
                  value: v['ref'] as String,
                  items: [
                    for (final x in versions)
                      DropdownMenuItem(
                        value: x['ref'] as String,
                        child: Text(
                          '${x['rotulo']}${x['travado'] == true ? ' 🔒' : ''}'
                          '${(x['salvo_em'] as String? ?? '').isEmpty ? '' : ' · ${_data(x['salvo_em'] as String)}'}',
                        ),
                      ),
                  ],
                  onChanged: (r) => setState(() {
                    _ref = r;
                    _playing = false;
                  }),
                ),
                if (prontas > 0)
                  FilledButton.tonalIcon(
                    icon: Icon(_playing ? Icons.stop : Icons.play_arrow),
                    label: Text(_playing ? 'Fechar exemplo' : 'Ver exemplo'),
                    onPressed: () => setState(() => _playing = !_playing),
                  ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.movie_creation_outlined),
                  label: Text(prontas > 0 ? 'Refazer exemplo' : 'Gerar exemplo'),
                  onPressed: () => actionWithWarning(context, () async {
                    await widget.api.generateSample(v['ref'] as String);
                    return 'Exemplo de ${v['rotulo']} na fila (30 s em ${samples.keys.join(' e ')}). Acompanhe em Fila.';
                  }),
                ),
                if (prontas < samples.length) Text('exemplo: $prontas de ${samples.length} formato(s) pronto(s)', style: pequeno),
              ],
            ),
            if (_playing)
              Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  for (final MapEntry(key: fmt, value: pronta) in samples.entries)
                    if (pronta)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 4,
                        children: [
                          Text(fmt == '9x16' ? 'Vertical 9:16' : 'Horizontal 16:9', style: pequeno),
                          SizedBox(
                            width: fmt == '9x16' ? 230 : 560,
                            height: fmt == '9x16' ? 410 : 315,
                            child: VideoFinal(
                              url: widget.api.sample(v['id'] as String, v['versao'] as int, fmt),
                              vertical: fmt == '9x16',
                            ),
                          ),
                        ],
                      ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  static String _kind(String modo) => switch (modo) {
    'apresentador' => 'Apresentador',
    'curso' => 'Curso',
    _ => 'Dark',
  };

  /// `2026-11-01T22:10:05` → `01/11 22:10`.
  static String _data(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)} ${two(d.hour)}:${two(d.minute)}';
  }
}

/// Kind of the new template: mode (dark, presenter, course) and formats.
class _NewTemplate extends StatefulWidget {
  const _NewTemplate();

  @override
  State<_NewTemplate> createState() => _NewTemplateState();
}

class _NewTemplateState extends State<_NewTemplate> {
  final _nome = TextEditingController();
  String _mode = 'dark';
  final _formats = {'16:9', '9:16'};

  @override
  void dispose() {
    _nome.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Novo template'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          const Text('Modo da prévia e da amostra'),
          Text('No vídeo vale o modo marcado no roteiro (modo: dark ou apresentador); aqui é só como o template é mostrado.',
              style: Theme.of(context).textTheme.bodySmall),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'dark', label: Text('Dark'), icon: Icon(Icons.mic)),
              ButtonSegment(value: 'apresentador', label: Text('Apresentador'), icon: Icon(Icons.videocam)),
              ButtonSegment(value: 'curso', label: Text('Curso'), icon: Icon(Icons.school)),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),
          const Text('Formatos'),
          Wrap(
            spacing: 8,
            children: [
              for (final (f, label) in const [('16:9', 'Horizontal 16:9'), ('9:16', 'Vertical 9:16')])
                FilterChip(
                  label: Text(label),
                  selected: _formats.contains(f),
                  onSelected: (s) => setState(() => s ? _formats.add(f) : _formats.remove(f)),
                ),
            ],
          ),
          TextField(
            controller: _nome,
            decoration: const InputDecoration(labelText: 'Nome (opcional)', hintText: 'padrão: <canal> · <tipo>'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(
        onPressed: _formats.isEmpty
            ? null
            : () => Navigator.pop(context, {'modo': _mode, 'formatos': _formats.toList(), 'nome': _nome.text.trim()}),
        child: const Text('Criar'),
      ),
    ],
  );
}

class _Productions extends StatelessWidget {
  const _Productions({required this.api, required this.channel, required this.styles});

  final ApiEsteira api;
  final String channel;
  final List<Json> styles;

  @override
  Widget build(BuildContext context) => Sondagem<List<dynamic>>(
    key: ValueKey(channel),
    intervalo: const Duration(seconds: 10),
    carregar: () => api.studioProductions(channel),
    construir: (context, list, _) {
      if (list.isEmpty) {
        return const Text('Nenhum episódio com narração editada neste canal (importe um roteiro na aba Roteiros).');
      }
      return Card(
        child: Column(
          children: [
            for (final p in list.cast<Json>())
              ListTile(
                title: Text('${p['ep']} · ${p['titulo']}'),
                subtitle: Text(_summary(p)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => ProductionScreen(api: api, ep: p['ep'] as String, styles: styles),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );

  static String _summary(Json p) {
    final ap = p['aprovacoes'] as Json;
    final parts = <String>[
      (ap['corte'] as Json?)?['aprovado'] == true ? 'corte aprovado' : 'corte a aprovar',
      if (p['mapa'] != null) '${(p['mapa'] as Json)['cenas']} cenas',
      for (final f in (p['formatos'] as Json).entries)
        '${f.key}: ${(f.value as Json)['final'] == true ? 'vídeo pronto' : 'em produção'}',
    ];
    return parts.join(' · ');
  }
}

class _NewChannel extends StatefulWidget {
  const _NewChannel();

  @override
  State<_NewChannel> createState() => _NewChannelState();
}

class _NewChannelState extends State<_NewChannel> {
  final _nome = TextEditingController();
  final _slug = TextEditingController();
  final _niche = TextEditingController();
  final _color = TextEditingController(text: '#f5c518');
  String _mode = 'dark';

  @override
  void dispose() {
    for (final c in [_nome, _slug, _niche, _color]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Adicionar canal'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nome,
            decoration: const InputDecoration(labelText: 'Nome do canal'),
            onChanged: (v) => _slug.text = v.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-|-$'), ''),
          ),
          TextField(controller: _slug, decoration: const InputDecoration(labelText: 'Identificador (pasta)')),
          TextField(controller: _niche, decoration: const InputDecoration(labelText: 'Nicho e público')),
          TextField(controller: _color, decoration: const InputDecoration(labelText: 'Cor de destaque (#rrggbb)')),
          const SizedBox(height: 12),
          Text('Modo da prévia (no vídeo vale o do roteiro)', style: Theme.of(context).textTheme.bodySmall),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'dark', label: Text('Dark')),
              ButtonSegment(value: 'apresentador', label: Text('Apresentador')),
              ButtonSegment(value: 'curso', label: Text('Curso')),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(
        onPressed: () => Navigator.pop(context, {
          'nome': _nome.text,
          'slug': _slug.text,
          'nicho': _niche.text,
          'cor': _color.text,
          'modo': _mode,
        }),
        child: const Text('Criar'),
      ),
    ],
  );
}

/// "Editar" with a label on a wide screen; on the phone only the icon, so the template name does not wrap.
class _EditButton extends StatelessWidget {
  const _EditButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => MediaQuery.sizeOf(context).width < 600
      ? IconButton.outlined(tooltip: 'Editar', icon: const Icon(Icons.edit), onPressed: onTap)
      : OutlinedButton.icon(icon: const Icon(Icons.edit), label: const Text('Editar'), onPressed: onTap);
}
