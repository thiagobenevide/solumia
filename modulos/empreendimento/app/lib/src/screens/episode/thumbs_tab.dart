import 'package:agent_core/agent_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../api_esteira.dart';
import '../../models.dart';
import '../editor/editor_screen.dart';
import '../util.dart';
import 'remote_edit.dart';

/// Thumbnails: the 3 A/B test slots, every thumbnail (from the stage and the editor) with edit, open in
/// PhotoCraft and pick a slot; upload a background image and create a new thumbnail.
class ThumbsTab extends StatefulWidget {
  const ThumbsTab({super.key, required this.api, required this.ep});

  final ApiEsteira api;
  final String ep;

  @override
  State<ThumbsTab> createState() => _ThumbsTabState();
}

class _ThumbsTabState extends State<ThumbsTab> {
  late Future<Json> _dados = widget.api.thumbs(widget.ep);

  void _recarregar() => setState(() { _dados = widget.api.thumbs(widget.ep); });

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _dados,
    builder: (context, s) {
      if (s.hasError) return ErroComRetry(erro: s.error!, tentar: _recarregar);
      final d = s.data;
      if (d == null) return const Center(child: CircularProgressIndicator());
      final slots = [for (final v in d['vagas'] as List) v as Json];
      final thumbs = [for (final t in d['thumbs'] as List) t as Json];
      final hasBackground = (d['fundos'] as List).isNotEmpty;
      return RefreshIndicator(
        onRefresh: () async => _recarregar(),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'As geradas pela etapa e as feitas no editor. Edite qualquer uma (texto, destaque, layout, fundo, caixas '
              'de texto) e escolha as 3 do teste A/B do YouTube.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.upload),
                  label: const Text('Enviar fundo'),
                  onPressed: _sendBackground,
                ),
                if (hasBackground)
                  FilledButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Nova thumb'),
                    onPressed: () => _edit(),
                  ),
              ],
            ),
            if (slots.isNotEmpty) ...[
              const Section('No teste A/B'),
              _grade([
                for (final v in slots)
                  Card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AspectRatio(
                          aspectRatio: 16 / 9,
                          child: Image.network(widget.api.arquivo('${v['url']}'), fit: BoxFit.cover),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(10),
                          child: Text(
                            'thumb ${v['vaga']}${v['vaga'] == 1 ? ' · principal (thumb.png)' : ''}',
                          ),
                        ),
                      ],
                    ),
                  ),
              ]),
            ],
            Section('Todas (${thumbs.length})'),
            if (thumbs.isEmpty)
              Empty(
                'Nenhuma thumb ainda: rode a etapa thumb ${hasBackground ? 'ou crie uma nova' : 'ou envie um fundo'}.',
              ),
            _grade([for (final t in thumbs) _thumb(context, t)]),
          ],
        ),
      );
    },
  );

  Widget _grade(List<Widget> children) => LayoutBuilder(
    builder: (context, area) {
      final columns = (area.maxWidth / 420).ceil().clamp(1, 4);
      final largura = (area.maxWidth - 12 * (columns - 1)) / columns;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [for (final f in children) SizedBox(width: largura, child: f)],
      );
    },
  );

  Widget _thumb(BuildContext context, Json t) => Card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: Image.network(widget.api.arquivo('${t['url']}'), fit: BoxFit.cover),
        ),
        Padding(
          padding: const EdgeInsets.all(10),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              StatePill(t['origem'] == 'editor' ? 'na fila' : 'pendente', texto: '${t['origem']}'),
              if (t['nota'] != null) Text('nota ${t['nota']}'),
              if (t['pc_editado'] == true) const StatePill('rodando', texto: 'editado no PhotoCraft'),
              FilledButton.tonal(
                onPressed: () => _edit(arquivo: '${t['arquivo']}'),
                child: const Text('Editar'),
              ),
              OutlinedButton(
                onPressed: () => _openPhotoCraft('${t['arquivo']}'),
                child: const Text('PhotoCraft'),
              ),
              RemoteEdit(
                url: widget.api.packageThumb(widget.ep, '${t['arquivo']}'),
                extensions: const ['pcraft'],
                send: (nome, bytes) => widget.api.sendThumb(widget.ep, '${t['arquivo']}', nome, bytes),
                done: 'Thumb enviada: o PNG é refeito a partir do .pcraft.',
                after: _recarregar,
              ),
              for (final k in [1, 2, 3])
                Tooltip(
                  message: 'usar como thumb $k',
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(40, 36),
                      padding: EdgeInsets.zero,
                    ),
                    onPressed: () => _use('${t['arquivo']}', k),
                    child: Text('$k'),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );

  Future<void> _edit({String arquivo = '', String background = ''}) async {
    await abrirTela(context, (_) => EditorScreen.thumb(api: widget.api, ep: widget.ep, arquivo: arquivo, background: background));
    _recarregar();
  }

  Future<void> _use(String arquivo, int slot) => actionWithWarning(context, () async {
    await widget.api.useThumb(widget.ep, arquivo, slot);
    _recarregar();
    return 'Thumb $slot do teste A/B trocada.';
  });

  Future<void> _openPhotoCraft(String arquivo) => actionWithWarning(context, () async {
    await widget.api.openPhotoCraft(widget.ep, arquivo);
    return 'Abrindo no PhotoCraft (no PC). Salve com Ctrl+S: o PNG é refeito ao voltar aqui.';
  });

  Future<void> _sendBackground() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
    );
    if (files.isEmpty || !mounted) return;
    final a = files.first;
    String? nome;
    await actionWithWarning(context, () async {
      nome = await widget.api.sendBackground(widget.ep, a.name, await a.xFile.readAsBytes());
      return 'Fundo enviado: $nome';
    });
    if (nome != null && mounted) await _edit(background: nome!);
  }
}
