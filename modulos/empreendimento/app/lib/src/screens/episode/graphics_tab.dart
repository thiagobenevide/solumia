import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../../api_esteira.dart';
import '../../models.dart';
import '../editor/editor_screen.dart';
import '../util.dart';
import 'remote_edit.dart';

/// Animated graphics: frame of each piece at 65% of its duration, open in the editor or in EffectCraft, create
/// a new piece and render what was saved in EffectCraft.
class GraphicsTab extends StatefulWidget {
  const GraphicsTab({super.key, required this.api, required this.ep});

  final ApiEsteira api;
  final String ep;

  @override
  State<GraphicsTab> createState() => _GraphicsTabState();
}

class _GraphicsTabState extends State<GraphicsTab> {
  late Future<Json> _dados = widget.api.graphics(widget.ep);
  final _newStart = TextEditingController(text: '0');

  void _recarregar() => setState(() { _dados = widget.api.graphics(widget.ep); });

  @override
  void dispose() {
    _newStart.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _dados,
    builder: (context, s) {
      if (s.hasError) return Empty('${s.error}', icone: Icons.animation);
      final d = s.data;
      if (d == null) return const Center(child: CircularProgressIndicator());
      final list = [for (final g in d['graficos'] as List) g as Json];
      final vertical = d['vertical'] == true;
      final byKind = (d['por_tipo'] as Json).entries.map((e) => '${e.value} ${e.key}').join(', ');
      return RefreshIndicator(
        onRefresh: () async => _recarregar(),
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverList.list(
                children: [
                  Text(
                    '${list.length} peças (${vertical ? '9:16' : '16:9'}): $byKind. Quadro de cada uma aos 65% da '
                    'duração, sobre fundo cinza (no vídeo fica sobre a cena). Toque numa peça para editar texto, '
                    'tempo, efeitos e caixas de texto.',
                  ),
                  const SizedBox(height: 6),
                  const Wrap(
                    spacing: 6,
                    children: [
                      EnginePill('local', label: 'LLM local planeja'),
                      EnginePill('py', label: 'Python renderiza'),
                      EnginePill('claude', label: 'assistente do editor'),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text('Nova caixa de texto aos'),
                      SizedBox(
                        width: 90,
                        child: TextField(
                          controller: _newStart,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(
                            isDense: true,
                            suffixText: 's',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      FilledButton.icon(
                        icon: const Icon(Icons.add),
                        label: const Text('Novo gráfico'),
                        onPressed: () =>
                            _edit(-1, start: double.tryParse(_newStart.text.replaceAll(',', '.')) ?? 0),
                      ),
                    ],
                  ),
                  if ((d['editados_ec'] as int) > 0)
                    Card(
                      margin: const EdgeInsets.only(top: 12),
                      // button below the text (not in the trailing): on the phone it squeezed the title
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            const Icon(Icons.edit_note, color: Colors.amber),
                            Text('${d['editados_ec']} peça(s) salva(s) no EffectCraft.'),
                            FilledButton.tonal(onPressed: _render, child: const Text('Renderizar as edições')),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              sliver: SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: vertical ? 220 : 420,
                  mainAxisExtent: vertical ? 520 : 360,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemCount: list.length,
                itemBuilder: (context, i) => _piece(context, list[i], vertical),
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _piece(BuildContext context, Json g, bool vertical) {
    final start = g['inicio'] as num;
    final cores = Theme.of(context).colorScheme;
    final Widget frame = g['previa'] != null
        ? Image.network(widget.api.arquivo('${g['previa']}'), fit: BoxFit.contain)
        : Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                g['manual'] == true
                    ? 'editado: aguardando renderização'
                    : 'não renderizado (trecho não achado no PDF)',
                textAlign: TextAlign.center,
                style: TextStyle(color: g['manual'] == true ? Colors.amber : cores.error),
              ),
            ),
          );
    return Card(
      child: InkWell(
        onTap: () => _edit(g['i'] as int),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: vertical ? 9 / 16 : 16 / 9,
              child: ColoredBox(color: const Color(0xFF2A2D33), child: frame),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 6,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '${start ~/ 60}:${(start % 60).floor().toString().padLeft(2, '0')}',
                          style: TextStyle(color: cores.primary, fontFamily: 'monospace'),
                        ),
                        EnginePill('py', label: '${g['modelo']}'),
                        Text('${g['dur']}s', style: Theme.of(context).textTheme.bodySmall),
                        if (g['manual'] == true) const StatePill('na fila', texto: 'editado'),
                        if (g['roteiro'] == true)
                          const StatePill('rodando', texto: 'do roteiro')
                        else if (g['origem'] != null)
                          Text('${g['origem']}', style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                    Text('${g['rotulo']}', maxLines: 2, overflow: TextOverflow.ellipsis),
                    const Spacer(),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        TextButton(
                          onPressed: () => _openEffectCraft(g['i'] as int),
                          child: const Text('Abrir no EffectCraft'),
                        ),
                        RemoteEdit(
                          url: widget.api.graphicPackage(widget.ep, g['i'] as int),
                          extensions: const ['ecproj'],
                          send: (nome, bytes) => widget.api.sendGraphic(widget.ep, g['i'] as int, nome, bytes),
                          done: 'Peça enviada: renderize as edições para entrar no vídeo.',
                          after: _recarregar,
                        ),
                        if (g['ec_editado'] == true)
                          const StatePill('na fila', texto: 'salvo no EffectCraft: falta renderizar')
                        else if (g['manual_ec'] == true)
                          const StatePill('rodando', texto: 'editado no EffectCraft'),
                      ],
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

  Future<void> _edit(int i, {double start = 0}) async {
    await abrirTela(context, (_) => EditorScreen.graphic(api: widget.api, ep: widget.ep, index: i, start: start));
    _recarregar();
  }

  Future<void> _openEffectCraft(int i) => actionWithWarning(context, () async {
    await widget.api.openEffectCraft(widget.ep, i);
    return 'Abrindo a peça no EffectCraft (no PC). Salve com Ctrl+S e renderize aqui.';
  });

  Future<void> _render() => actionWithWarning(context, () async {
    final entrou = await widget.api.run(widget.ep, 'graphics', renderOnly: true);
    return entrou ? 'Renderização das edições na fila.' : 'A renderização já estava na fila.';
  });
}
