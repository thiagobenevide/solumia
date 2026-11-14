import 'package:agent_core/agent_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../api_esteira.dart';
import '../../modelos.dart';
import '../editor/editor_tela.dart';
import '../util.dart';
import 'edicao_remota.dart';

/// Thumbnails: as 3 vagas do teste A/B, todas as thumbs (da etapa e do editor) com editar, abrir no
/// PhotoCraft e escolher vaga; enviar uma imagem de fundo e criar uma thumb nova.
class ThumbsAba extends StatefulWidget {
  const ThumbsAba({super.key, required this.api, required this.ep});

  final ApiEsteira api;
  final String ep;

  @override
  State<ThumbsAba> createState() => _ThumbsAbaState();
}

class _ThumbsAbaState extends State<ThumbsAba> {
  late Future<Json> _dados = widget.api.thumbs(widget.ep);

  void _recarregar() => setState(() { _dados = widget.api.thumbs(widget.ep); });

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _dados,
    builder: (context, s) {
      if (s.hasError) return ErroComRetry(erro: s.error!, tentar: _recarregar);
      final d = s.data;
      if (d == null) return const Center(child: CircularProgressIndicator());
      final vagas = [for (final v in d['vagas'] as List) v as Json];
      final thumbs = [for (final t in d['thumbs'] as List) t as Json];
      final temFundo = (d['fundos'] as List).isNotEmpty;
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
                  onPressed: _enviarFundo,
                ),
                if (temFundo)
                  FilledButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Nova thumb'),
                    onPressed: () => _editar(),
                  ),
              ],
            ),
            if (vagas.isNotEmpty) ...[
              const Secao('No teste A/B'),
              _grade([
                for (final v in vagas)
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
            Secao('Todas (${thumbs.length})'),
            if (thumbs.isEmpty)
              Vazio(
                'Nenhuma thumb ainda: rode a etapa thumb ${temFundo ? 'ou crie uma nova' : 'ou envie um fundo'}.',
              ),
            _grade([for (final t in thumbs) _thumb(context, t)]),
          ],
        ),
      );
    },
  );

  Widget _grade(List<Widget> filhos) => LayoutBuilder(
    builder: (context, area) {
      final colunas = (area.maxWidth / 420).ceil().clamp(1, 4);
      final largura = (area.maxWidth - 12 * (colunas - 1)) / colunas;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [for (final f in filhos) SizedBox(width: largura, child: f)],
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
              SeloEstado(t['origem'] == 'editor' ? 'na fila' : 'pendente', texto: '${t['origem']}'),
              if (t['nota'] != null) Text('nota ${t['nota']}'),
              if (t['pc_editado'] == true) const SeloEstado('rodando', texto: 'editado no PhotoCraft'),
              FilledButton.tonal(
                onPressed: () => _editar(arquivo: '${t['arquivo']}'),
                child: const Text('Editar'),
              ),
              OutlinedButton(
                onPressed: () => _abrirPhotoCraft('${t['arquivo']}'),
                child: const Text('PhotoCraft'),
              ),
              EdicaoRemota(
                url: widget.api.pacoteThumb(widget.ep, '${t['arquivo']}'),
                extensoes: const ['pcraft'],
                enviar: (nome, bytes) => widget.api.enviarThumb(widget.ep, '${t['arquivo']}', nome, bytes),
                feito: 'Thumb enviada: o PNG é refeito a partir do .pcraft.',
                depois: _recarregar,
              ),
              for (final k in [1, 2, 3])
                Tooltip(
                  message: 'usar como thumb $k',
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(40, 36),
                      padding: EdgeInsets.zero,
                    ),
                    onPressed: () => _usar('${t['arquivo']}', k),
                    child: Text('$k'),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );

  Future<void> _editar({String arquivo = '', String fundo = ''}) async {
    await abrirTela(context, (_) => EditorTela.thumb(api: widget.api, ep: widget.ep, arquivo: arquivo, fundo: fundo));
    _recarregar();
  }

  Future<void> _usar(String arquivo, int vaga) => acaoComAviso(context, () async {
    await widget.api.usarThumb(widget.ep, arquivo, vaga);
    _recarregar();
    return 'Thumb $vaga do teste A/B trocada.';
  });

  Future<void> _abrirPhotoCraft(String arquivo) => acaoComAviso(context, () async {
    await widget.api.abrirPhotoCraft(widget.ep, arquivo);
    return 'Abrindo no PhotoCraft (no PC). Salve com Ctrl+S: o PNG é refeito ao voltar aqui.';
  });

  Future<void> _enviarFundo() async {
    final arquivos = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
    );
    if (arquivos.isEmpty || !mounted) return;
    final a = arquivos.first;
    String? nome;
    await acaoComAviso(context, () async {
      nome = await widget.api.enviarFundo(widget.ep, a.name, await a.xFile.readAsBytes());
      return 'Fundo enviado: $nome';
    });
    if (nome != null && mounted) await _editar(fundo: nome!);
  }
}
