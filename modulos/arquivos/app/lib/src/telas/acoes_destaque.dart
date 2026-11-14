import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_arquivos.dart';
import '../modelos.dart';
import 'projetos_leitura.dart';

void avisar(BuildContext context, String mensagem) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(mensagem)));

/// Pede um texto numa caixa de diálogo. `null` quando cancelado.
Future<String?> pedirTexto(
  BuildContext context, {
  required String titulo,
  String inicial = '',
  String rotulo = '',
  int linhas = 1,
  String confirmar = 'Salvar',
}) {
  final campo = TextEditingController(text: inicial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(titulo),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: campo,
          autofocus: true,
          minLines: linhas,
          maxLines: linhas == 1 ? 1 : 12,
          decoration: InputDecoration(labelText: rotulo.isEmpty ? null : rotulo),
          onSubmitted: linhas == 1 ? (v) => Navigator.pop(context, v) : null,
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(context, campo.text), child: Text(confirmar)),
      ],
    ),
  ).whenComplete(campo.dispose);
}

/// Cria uma nota a partir do destaque, perguntando o título (padrão: começo do trecho).
Future<void> criarNotaDoDestaque(BuildContext context, ApiArquivos api, Referencia r) async {
  final palavras = r.destaque.texto.split(RegExp(r'\s+')).take(8).join(' ');
  final titulo = await pedirTexto(
    context,
    titulo: 'Nova nota com a referência',
    inicial: palavras.isEmpty ? r.arquivoTitulo : palavras,
    rotulo: 'Título da nota',
    confirmar: 'Criar',
  );
  if (titulo == null || titulo.trim().isEmpty || !context.mounted) return;
  try {
    await api.criarNota(r, titulo: titulo.trim());
    if (context.mounted) avisar(context, 'Nota "$titulo" criada no módulo Notas');
  } on ApiErro catch (e) {
    if (context.mounted) avisar(context, 'Não deu para criar a nota: ${e.mensagem}');
  }
}

/// Painel de um destaque: texto, comentário e o que dá para fazer com ele.
Future<void> mostrarDestaque(
  BuildContext context, {
  required ApiArquivos api,
  required Referencia referencia,
  ValueChanged<String>? aoComentar,
  ValueChanged<String>? aoTraduzir,
  ValueChanged<List<String>>? aoMudarProjetos,
  VoidCallback? aoExcluir,
  VoidCallback? aoAbrir,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (folha) {
    final d = referencia.destaque;
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              Text('${referencia.arquivoTitulo} · p. ${d.pagina + 1}', style: Theme.of(folha).textTheme.labelLarge),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border(left: BorderSide(color: d.cor.withValues(alpha: 1), width: 4)),
                  color: d.cor.withValues(alpha: 0.12),
                ),
                constraints: const BoxConstraints(maxHeight: 260),
                child: SingleChildScrollView(child: SelectableText(d.texto)),
              ),
              if (d.traducao.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(folha).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 8,
                    children: [
                      const Icon(Icons.translate, size: 18),
                      Expanded(child: SelectableText(d.traducao)),
                    ],
                  ),
                ),
              if (d.comentario.isNotEmpty)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 8,
                  children: [
                    const Icon(Icons.lightbulb_outline, size: 18),
                    Expanded(
                      child: Text(d.comentario, style: const TextStyle(fontStyle: FontStyle.italic)),
                    ),
                  ],
                ),
              if (aoMudarProjetos != null) ...[
                Text('Projetos de leitura', style: Theme.of(folha).textTheme.labelLarge),
                ChipsProjetos(api: api, inicial: d.projetos, aoMudar: aoMudarProjetos),
              ],
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.copy),
                    label: const Text('Copiar referência'),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: referencia.citacao));
                      Navigator.pop(folha);
                      avisar(context, 'Referência copiada');
                    },
                  ),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.note_add_outlined),
                    label: const Text('Criar nota'),
                    onPressed: () {
                      Navigator.pop(folha);
                      criarNotaDoDestaque(context, api, referencia);
                    },
                  ),
                  if (aoComentar != null)
                    OutlinedButton.icon(
                      icon: const Icon(Icons.comment_outlined),
                      label: Text(d.comentario.isEmpty ? 'Comentar' : 'Editar comentário'),
                      onPressed: () async {
                        Navigator.pop(folha);
                        final c = await pedirTexto(
                          context,
                          titulo: 'Meu comentário (extração do conhecimento)',
                          inicial: d.comentario,
                          linhas: 4,
                        );
                        if (c != null) aoComentar(c.trim());
                      },
                    ),
                  if (aoTraduzir != null)
                    OutlinedButton.icon(
                      icon: const Icon(Icons.translate),
                      label: Text(d.traducao.isEmpty ? 'Traduzir' : 'Editar tradução'),
                      onPressed: () async {
                        Navigator.pop(folha);
                        final t = await editarTraducao(context, api, original: d.texto, atual: d.traducao);
                        if (t != null) aoTraduzir(t);
                      },
                    ),
                  if (aoAbrir != null)
                    OutlinedButton.icon(
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Abrir no arquivo'),
                      onPressed: () {
                        Navigator.pop(folha);
                        aoAbrir();
                      },
                    ),
                  if (aoExcluir != null)
                    TextButton.icon(
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Excluir'),
                      onPressed: () {
                        Navigator.pop(folha);
                        aoExcluir();
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  },
);
