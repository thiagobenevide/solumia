import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_estudos.dart';
import 'projetos_tela.dart' show AbrirNoArquivo;

/// Documento do projeto (o pré-TCC pronto, em .docx): anexar manda o arquivo para os Arquivos e o
/// Claude faz o mapeamento reverso — acha cada citação nos PDFs das referências e marca o trecho
/// no projeto. Referências sem PDF ficam como pendência de download (também viram tarefa no Quadro);
/// "Refazer mapeamento" roda de novo depois de baixar.
class MapeamentoPainel extends StatefulWidget {
  const MapeamentoPainel({super.key, required this.api, required this.projetoId, this.abrirNoArquivo, this.aoConcluir});

  final ApiEstudos api;
  final String projetoId;
  final AbrirNoArquivo? abrirNoArquivo;

  /// Chamado quando um mapeamento termina (a tela recarrega a matriz).
  final VoidCallback? aoConcluir;

  @override
  State<MapeamentoPainel> createState() => _MapeamentoPainelState();
}

class _MapeamentoPainelState extends State<MapeamentoPainel> {
  Map<String, dynamic> _m = const {};
  bool _enviando = false;
  Timer? _relogio;

  bool get _rodando => _m['estado'] == 'rodando';

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  @override
  void dispose() {
    _relogio?.cancel();
    super.dispose();
  }

  Future<void> _carregar() async {
    try {
      final m = await widget.api.mapeamento(widget.projetoId);
      if (!mounted) return;
      final terminou = _rodando && m['estado'] != 'rodando';
      setState(() => _m = m);
      _vigiar();
      if (terminou) widget.aoConcluir?.call();
    } on ApiErro catch (_) {
      // sem conexão: o painel fica como estava
    }
  }

  void _vigiar() {
    _relogio?.cancel();
    if (_rodando) _relogio = Timer(const Duration(seconds: 3), _carregar);
  }

  void _avisar(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _anexar() async {
    final escolhidos = await FilePicker.pickFiles(
      dialogTitle: 'Documento do projeto (.docx ou PDF)',
      type: FileType.custom,
      allowedExtensions: const ['docx', 'pdf'],
    );
    if (escolhidos.isEmpty || !mounted) return;
    final f = escolhidos.first;
    setState(() => _enviando = true);
    try {
      final bytes = await f.xFile.readAsBytes();
      final m = await widget.api.anexarDocumento(widget.projetoId, f.name, bytes);
      if (!mounted) return;
      setState(() => _m = m);
      _vigiar();
      _avisar('${f.name} guardado nos Arquivos. Mapeando as citações e buscando os artigos.');
    } on ApiErro catch (e) {
      if (mounted) _avisar(e.mensagem);
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  Future<void> _refazer() async {
    setState(() => _enviando = true);
    try {
      final m = await widget.api.refazerMapeamento(widget.projetoId);
      if (!mounted) return;
      setState(() => _m = m);
      _vigiar();
    } on ApiErro catch (e) {
      if (mounted) _avisar(e.mensagem);
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final refs = [for (final r in (_m['referencias'] as List? ?? const [])) (r as Map).cast<String, dynamic>()];
    final pendentes = refs.where((r) => r['arquivo_id'] == null).toList();
    final temDocumento = _m['documento_id'] != null;
    final ocupado = _enviando || _rodando;

    final botoes = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.tonalIcon(
          icon: const Icon(Icons.attach_file),
          label: Text(temDocumento ? 'Trocar documento' : 'Anexar documento (.docx ou PDF)'),
          onPressed: ocupado ? null : _anexar,
        ),
        if (temDocumento)
          OutlinedButton.icon(
            icon: const Icon(Icons.manage_search),
            label: const Text('Refazer mapeamento'),
            onPressed: ocupado ? null : _refazer,
          ),
      ],
    );

    final String subtitulo;
    if (!temDocumento) {
      subtitulo =
          'Anexe o texto (inteiro ou só introdução/resumo, .docx ou PDF): as citações são achadas nas '
          'referências, os PDFs abertos são baixados e os trechos marcados aqui.';
    } else if (_rodando) {
      subtitulo = _m['etapa'] as String? ?? 'Mapeando…';
    } else if (_m['estado'] == 'erro') {
      subtitulo = 'Falhou: ${_m['erro'] ?? ''}';
    } else {
      subtitulo =
          '${_m['citacoes'] ?? 0} citações · ${_m['marcadas'] ?? 0} marcadas · '
          '${pendentes.length} referência(s) para baixar';
    }

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: Icon(Icons.description_outlined, color: tema.colorScheme.primary),
        title: Text(
          temDocumento ? 'Documento: ${_m['documento_titulo'] ?? ''}' : 'Documento do projeto',
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          subtitulo,
          style: _m['estado'] == 'erro' ? TextStyle(color: tema.colorScheme.error) : null,
        ),
        trailing: _rodando || _enviando
            ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : null,
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          botoes,
          // O painel fica numa Column sem rolagem: a lista rola dentro de uma altura máxima.
          if (refs.isNotEmpty)
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.5),
              child: Scrollbar(
                child: ListView(
                  shrinkWrap: true,
                  primary: false,
                  children: [
                    if (pendentes.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        'Sem PDF aberto (fechados): baixe e envie para Arquivos; depois toque em '
                        '"Refazer mapeamento". Os de acesso aberto já são baixados sozinhos no mapeamento.',
                        style: tema.textTheme.titleSmall,
                      ),
                      for (final r in pendentes) _Referencia(r, abrirNoArquivo: widget.abrirNoArquivo),
                    ],
                    if (refs.length > pendentes.length) ...[
                      const SizedBox(height: 12),
                      Text('Referências com PDF', style: tema.textTheme.titleSmall),
                      for (final r in refs.where((r) => r['arquivo_id'] != null))
                        _Referencia(r, abrirNoArquivo: widget.abrirNoArquivo),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Onde baixar a referência, tirado do próprio texto (sem refazer a análise): o DOI (doi.org), o
/// link que já está na referência e buscas pelo título e autor (Google Acadêmico e Google, filetype:pdf).
List<(String, IconData, String)> linksDaReferencia(Map<String, dynamic> r) {
  final texto = r['referencia'] as String? ?? '';
  final links = <(String, IconData, String)>[];
  final achado = (r['link'] as String? ?? '').trim();
  if (achado.isNotEmpty) links.add(('Abrir o artigo', Icons.article_outlined, achado));
  final doi = RegExp(r'\b(10\.\d{4,9}/[^\s]+)', caseSensitive: false).firstMatch(texto)?.group(1);
  if (doi != null) {
    links.add(('Abrir pelo DOI', Icons.link, 'https://doi.org/${doi.replaceAll(RegExp(r'[.,;]+$'), '')}'));
  }
  for (final m in RegExp(r'https?://[^\s>)\]]+').allMatches(texto)) {
    final url = m.group(0)!.replaceAll(RegExp(r'[.,;]+$'), '');
    if (!url.contains('doi.org')) links.add(('Link da referência', Icons.public, url));
  }
  final titulo = (r['titulo'] as String? ?? '').trim();
  final autor = (r['autor_citacao'] as String? ?? '').replaceAll(RegExp(r'\bet al\.?'), '').trim();
  final busca = Uri.encodeQueryComponent('"$titulo" $autor'.trim());
  links.add(('Buscar no Google Acadêmico', Icons.school_outlined, 'https://scholar.google.com/scholar?q=$busca'));
  links.add(('Buscar o PDF no Google', Icons.search, 'https://www.google.com/search?q=$busca+filetype%3Apdf'));
  return links;
}

class _Referencia extends StatelessWidget {
  const _Referencia(this.r, {this.abrirNoArquivo});

  final Map<String, dynamic> r;
  final AbrirNoArquivo? abrirNoArquivo;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final arquivo = r['arquivo_id'] as String?;
    final faltam = [for (final x in (r['nao_localizadas'] as List? ?? const [])) '$x'];
    final citacoes = r['citacoes'] as int? ?? 0;
    final marcadas = r['marcadas'] as int? ?? 0;
    final links = linksDaReferencia(r);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: arquivo == null
          ? IconButton(
              tooltip: 'Abrir onde baixar (${links.first.$1})',
              icon: Icon(Icons.download_outlined, color: tema.colorScheme.error),
              onPressed: () => abrirLink(context, links.first.$3),
            )
          : Icon(
              marcadas >= citacoes ? Icons.check_circle : Icons.error_outline,
              color: marcadas >= citacoes ? tema.colorScheme.primary : tema.colorScheme.tertiary,
            ),
      title: SelectableText('${r['autor_citacao']} (${r['ano']}) — ${r['titulo']}'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(r['referencia'] as String? ?? '', style: tema.textTheme.bodySmall),
          Text(
            arquivo == null
                ? 'Sem PDF nos Arquivos · $citacoes citação(ões) no documento'
                : '${r['baixado_auto'] == true ? 'Baixado sozinho (acesso aberto) · ' : ''}'
                      '${r['arquivo_titulo'] ?? ''} · $marcadas/$citacoes citação(ões) marcadas',
            style: tema.textTheme.bodySmall,
          ),
          for (final f in faltam)
            Text('Não localizada: $f', style: tema.textTheme.bodySmall?.copyWith(color: tema.colorScheme.tertiary)),
        ],
      ),
      trailing: arquivo != null && abrirNoArquivo != null
          ? IconButton(
              tooltip: 'Abrir o PDF',
              icon: const Icon(Icons.open_in_new),
              onPressed: () => abrirNoArquivo!(context, arquivo, 1),
            )
          : arquivo != null
          ? null
          : PopupMenuButton<String>(
              tooltip: 'Links e copiar',
              icon: const Icon(Icons.more_vert),
              onSelected: (v) {
                if (v == 'copiar') {
                  Clipboard.setData(ClipboardData(text: r['referencia'] as String? ?? ''));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Referência copiada')));
                } else {
                  abrirLink(context, v);
                }
              },
              itemBuilder: (_) => [
                for (final (rotulo, icone, url) in links)
                  PopupMenuItem(value: url, child: ListTile(leading: Icon(icone), title: Text(rotulo), dense: true)),
                const PopupMenuItem(
                  value: 'copiar',
                  child: ListTile(leading: Icon(Icons.copy), title: Text('Copiar referência'), dense: true),
                ),
              ],
            ),
    );
  }
}
