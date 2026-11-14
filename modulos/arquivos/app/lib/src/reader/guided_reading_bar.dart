import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../screens/highlight_actions.dart';
import 'guided_reading.dart';

/// Floating guided reading bar (below the PDF) and, above it, the translation card of the tapped
/// excerpt, as in Kindle: listen, mark on the PDF, read from there and "Criar tarefas".
class GuidedReadingPanel extends StatelessWidget {
  const GuidedReadingPanel({super.key, required this.guide, required this.onMark});

  final GuidedReading guide;

  /// Marks the looked-up excerpt as a highlight (with the translation).
  final VoidCallback onMark;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: guide,
    builder: (context, _) => Column(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        if (guide.selection != null) _LookupCard(guide: guide, onMark: onMark),
        _TopBar(guide: guide),
      ],
    ),
  );
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.guide});

  final GuidedReading guide;

  Future<void> _save(BuildContext context) async {
    final g = guide;
    if (!g.recording) {
      if (g.textToRead.isEmpty) return notify(context, 'Esta página não tem texto para ler.');
      if (!await g.save()) {
        if (context.mounted) notify(context, 'Sem permissão para usar o microfone.');
        return;
      }
      if (context.mounted) notify(context, 'Gravando: leia em voz alta a partir da frase marcada e toque em parar.');
      return;
    }
    try {
      final r = await g.stopAndEvaluate();
      if (!context.mounted) return;
      if (r == null) return notify(context, 'Gravação curta demais.');
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Sua leitura em voz alta'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(child: ResultadoLeituraVoz(resultado: r, ouvir: g.listen)),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fechar'))],
        ),
      );
    } on ApiErro catch (e) {
      if (context.mounted) notify(context, e.mensagem);
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = guide;
    final warning =
        g.error ??
        (g.evaluating
            ? 'Avaliando sua leitura…'
            : g.recording
            ? 'Gravando sua leitura…'
            : g.loading
            ? 'Preparando a voz…'
            : g.sentences.isEmpty
            ? 'Página ${g.page + 1} sem texto selecionável'
            : 'Pág. ${g.page + 1} · frase ${g.score + 1}/${g.sentences.length}');
    return Material(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            IconButton(tooltip: 'Frase anterior', icon: const Icon(Icons.skip_previous), onPressed: () => g.skip(-1)),
            IconButton.filledTonal(
              tooltip: g.playing ? 'Pausar' : 'Ler em voz alta para mim',
              icon: Icon(g.playing ? Icons.pause : Icons.play_arrow),
              onPressed: g.recording ? null : (g.playing ? g.pause : g.play),
            ),
            IconButton(tooltip: 'Próxima frase', icon: const Icon(Icons.skip_next), onPressed: () => g.skip(1)),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(warning, overflow: TextOverflow.ellipsis),
              ),
            ),
            PopupMenuButton<double>(
              tooltip: 'Velocidade',
              initialValue: g.speed,
              onSelected: g.changeSpeed,
              itemBuilder: (_) => [for (final v in readingSpeeds) PopupMenuItem(value: v, child: Text('${v}x'))],
              child: Padding(padding: const EdgeInsets.all(8), child: Text('${g.speed}x')),
            ),
            PopupMenuButton<String>(
              tooltip: 'Idioma do texto',
              initialValue: g.language,
              onSelected: g.changeLanguage,
              itemBuilder: (_) => [
                for (final e in readingLanguages.entries) PopupMenuItem(value: e.key, child: Text(e.value)),
              ],
              child: Padding(padding: const EdgeInsets.all(8), child: Text(g.language.toUpperCase())),
            ),
            IconButton(
              tooltip: g.recording ? 'Parar e avaliar minha leitura' : 'Eu leio em voz alta (avaliar pronúncia)',
              color: g.recording ? Theme.of(context).colorScheme.error : null,
              icon: g.evaluating
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(g.recording ? Icons.stop_circle : Icons.mic_none),
              onPressed: g.evaluating ? null : () => _save(context),
            ),
            IconButton(tooltip: 'Fechar a leitura guiada', icon: const Icon(Icons.close), onPressed: g.close),
          ],
        ),
      ),
    );
  }
}

class _LookupCard extends StatelessWidget {
  const _LookupCard({required this.guide, required this.onMark});

  final GuidedReading guide;
  final VoidCallback onMark;

  Future<void> _create(BuildContext context) async {
    try {
      final term = await guide.createTasks();
      if (context.mounted) {
        notify(context, '"$term" no caderno de Estudos › Linguagem; as frases e exercícios estão sendo gerados.');
      }
    } on ApiErro catch (e) {
      if (context.mounted) notify(context, e.mensagem);
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = guide, c = g.query;
    final theme = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    String field(String k) => (c?[k] as String? ?? '').trim();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Card(
        elevation: 6,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: g.term, style: theme.titleMedium),
                          if (field('ipa').isNotEmpty)
                            TextSpan(text: '  /${field('ipa').replaceAll('/', '')}/', style: TextStyle(color: colors.outline)),
                          if (field('classe').isNotEmpty)
                            TextSpan(text: '  ${field('classe')}', style: TextStyle(color: colors.outline, fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                  IconButton(tooltip: 'Ouvir', icon: const Icon(Icons.volume_up), onPressed: () => g.listen(g.term)),
                  IconButton(tooltip: 'Fechar', icon: const Icon(Icons.close), onPressed: g.closeLookup),
                ],
              ),
              if (g.lookingUp)
                const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator())
              else if (c == null)
                Text(g.error ?? 'Sem tradução.', style: TextStyle(color: colors.error))
              else ...[
                Text(field('traducao'), style: theme.titleMedium?.copyWith(color: colors.primary)),
                if (field('sentido').isNotEmpty) Text(field('sentido'), style: theme.bodyMedium),
                if (field('frase_traduzida').isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      field('frase_traduzida'),
                      style: theme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              Wrap(
                spacing: 4,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.play_circle_outline),
                    label: const Text('Ler daqui'),
                    onPressed: g.readFromHere,
                  ),
                  TextButton.icon(icon: const Icon(Icons.border_color), label: const Text('Marcar'), onPressed: onMark),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.school_outlined),
                    label: const Text('Criar tarefas'),
                    onPressed: g.lookingUp ? null : () => _create(context),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
