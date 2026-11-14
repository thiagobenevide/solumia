import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../telas/acoes_destaque.dart';
import 'leitura_guiada.dart';

/// Barra flutuante da leitura guiada (embaixo do PDF) e, acima dela, o cartão da tradução do trecho
/// tocado, como no Kindle: ouvir, marcar no PDF, ler a partir dali e "Criar tarefas".
class PainelLeituraGuiada extends StatelessWidget {
  const PainelLeituraGuiada({super.key, required this.guia, required this.aoMarcar});

  final LeituraGuiada guia;

  /// Marca o trecho consultado como destaque (com a tradução).
  final VoidCallback aoMarcar;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: guia,
    builder: (context, _) => Column(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        if (guia.selecao != null) _CartaoConsulta(guia: guia, aoMarcar: aoMarcar),
        _Barra(guia: guia),
      ],
    ),
  );
}

class _Barra extends StatelessWidget {
  const _Barra({required this.guia});

  final LeituraGuiada guia;

  Future<void> _gravar(BuildContext context) async {
    final g = guia;
    if (!g.gravando) {
      if (g.textoParaLer.isEmpty) return avisar(context, 'Esta página não tem texto para ler.');
      if (!await g.gravar()) {
        if (context.mounted) avisar(context, 'Sem permissão para usar o microfone.');
        return;
      }
      if (context.mounted) avisar(context, 'Gravando: leia em voz alta a partir da frase marcada e toque em parar.');
      return;
    }
    try {
      final r = await g.pararEAvaliar();
      if (!context.mounted) return;
      if (r == null) return avisar(context, 'Gravação curta demais.');
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Sua leitura em voz alta'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(child: ResultadoLeituraVoz(resultado: r, ouvir: g.ouvir)),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fechar'))],
        ),
      );
    } on ApiErro catch (e) {
      if (context.mounted) avisar(context, e.mensagem);
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = guia;
    final aviso =
        g.erro ??
        (g.avaliando
            ? 'Avaliando sua leitura…'
            : g.gravando
            ? 'Gravando sua leitura…'
            : g.carregando
            ? 'Preparando a voz…'
            : g.frases.isEmpty
            ? 'Página ${g.pagina + 1} sem texto selecionável'
            : 'Pág. ${g.pagina + 1} · frase ${g.indice + 1}/${g.frases.length}');
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
            IconButton(tooltip: 'Frase anterior', icon: const Icon(Icons.skip_previous), onPressed: () => g.pular(-1)),
            IconButton.filledTonal(
              tooltip: g.tocando ? 'Pausar' : 'Ler em voz alta para mim',
              icon: Icon(g.tocando ? Icons.pause : Icons.play_arrow),
              onPressed: g.gravando ? null : (g.tocando ? g.pausar : g.tocar),
            ),
            IconButton(tooltip: 'Próxima frase', icon: const Icon(Icons.skip_next), onPressed: () => g.pular(1)),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(aviso, overflow: TextOverflow.ellipsis),
              ),
            ),
            PopupMenuButton<double>(
              tooltip: 'Velocidade',
              initialValue: g.velocidade,
              onSelected: g.mudarVelocidade,
              itemBuilder: (_) => [for (final v in velocidadesLeitura) PopupMenuItem(value: v, child: Text('${v}x'))],
              child: Padding(padding: const EdgeInsets.all(8), child: Text('${g.velocidade}x')),
            ),
            PopupMenuButton<String>(
              tooltip: 'Idioma do texto',
              initialValue: g.idioma,
              onSelected: g.mudarIdioma,
              itemBuilder: (_) => [
                for (final e in idiomasLeitura.entries) PopupMenuItem(value: e.key, child: Text(e.value)),
              ],
              child: Padding(padding: const EdgeInsets.all(8), child: Text(g.idioma.toUpperCase())),
            ),
            IconButton(
              tooltip: g.gravando ? 'Parar e avaliar minha leitura' : 'Eu leio em voz alta (avaliar pronúncia)',
              color: g.gravando ? Theme.of(context).colorScheme.error : null,
              icon: g.avaliando
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(g.gravando ? Icons.stop_circle : Icons.mic_none),
              onPressed: g.avaliando ? null : () => _gravar(context),
            ),
            IconButton(tooltip: 'Fechar a leitura guiada', icon: const Icon(Icons.close), onPressed: g.fechar),
          ],
        ),
      ),
    );
  }
}

class _CartaoConsulta extends StatelessWidget {
  const _CartaoConsulta({required this.guia, required this.aoMarcar});

  final LeituraGuiada guia;
  final VoidCallback aoMarcar;

  Future<void> _criar(BuildContext context) async {
    try {
      final termo = await guia.criarTarefas();
      if (context.mounted) {
        avisar(context, '"$termo" no caderno de Estudos › Linguagem; as frases e exercícios estão sendo gerados.');
      }
    } on ApiErro catch (e) {
      if (context.mounted) avisar(context, e.mensagem);
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = guia, c = g.consulta;
    final tema = Theme.of(context).textTheme;
    final cores = Theme.of(context).colorScheme;
    String campo(String k) => (c?[k] as String? ?? '').trim();
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
                          TextSpan(text: g.termo, style: tema.titleMedium),
                          if (campo('ipa').isNotEmpty)
                            TextSpan(text: '  /${campo('ipa').replaceAll('/', '')}/', style: TextStyle(color: cores.outline)),
                          if (campo('classe').isNotEmpty)
                            TextSpan(text: '  ${campo('classe')}', style: TextStyle(color: cores.outline, fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                  IconButton(tooltip: 'Ouvir', icon: const Icon(Icons.volume_up), onPressed: () => g.ouvir(g.termo)),
                  IconButton(tooltip: 'Fechar', icon: const Icon(Icons.close), onPressed: g.fecharConsulta),
                ],
              ),
              if (g.consultando)
                const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator())
              else if (c == null)
                Text(g.erro ?? 'Sem tradução.', style: TextStyle(color: cores.error))
              else ...[
                Text(campo('traducao'), style: tema.titleMedium?.copyWith(color: cores.primary)),
                if (campo('sentido').isNotEmpty) Text(campo('sentido'), style: tema.bodyMedium),
                if (campo('frase_traduzida').isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      campo('frase_traduzida'),
                      style: tema.bodySmall?.copyWith(fontStyle: FontStyle.italic),
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
                    onPressed: g.lerDaqui,
                  ),
                  TextButton.icon(icon: const Icon(Icons.border_color), label: const Text('Marcar'), onPressed: aoMarcar),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.school_outlined),
                    label: const Text('Criar tarefas'),
                    onPressed: g.consultando ? null : () => _criar(context),
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
