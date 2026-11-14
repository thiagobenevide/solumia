import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_rotinas.dart';

/// Perguntas de um toque: as dúvidas mais comuns sobre o quadro.
const respostasRapidas = [
  'O que devo fazer agora?',
  'Resuma meu dia',
  'Quanto tempo gastei hoje?',
  'Quais tarefas estão atrasadas?',
];

/// Conversa com o LLM. Fica fora do widget para sobreviver ao abrir e fechar o painel.
class ConversaAssistente extends ChangeNotifier {
  ConversaAssistente(this.api);

  final ApiRotinas api;

  /// (`usuario`|`assistente`, texto), na ordem.
  final mensagens = <(String, String)>[];
  bool pensando = false;
  String? erro;

  Future<void> perguntar(String pergunta) async {
    pergunta = pergunta.trim();
    if (pergunta.isEmpty || pensando) return;
    // as últimas trocas bastam de contexto; o quadro vai inteiro no prompt do servidor
    final historico = mensagens.length > 10 ? mensagens.sublist(mensagens.length - 10) : [...mensagens];
    mensagens.add(('usuario', pergunta));
    pensando = true;
    erro = null;
    notifyListeners();
    try {
      mensagens.add(('assistente', await api.perguntar(pergunta, historico)));
    } on ApiErro catch (e) {
      erro = e.status == 503 ? e.mensagem : '$e';
    } finally {
      pensando = false;
      notifyListeners();
    }
  }

  void limpar() {
    mensagens.clear();
    erro = null;
    notifyListeners();
  }
}

class Assistente extends StatefulWidget {
  const Assistente({super.key, required this.conversa, this.aoFechar});

  final ConversaAssistente conversa;
  final VoidCallback? aoFechar;

  @override
  State<Assistente> createState() => _AssistenteState();
}

class _AssistenteState extends State<Assistente> {
  final _campo = TextEditingController();
  final _rolagem = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.conversa.addListener(_rolarParaFim);
  }

  @override
  void dispose() {
    widget.conversa.removeListener(_rolarParaFim);
    _campo.dispose();
    _rolagem.dispose();
    super.dispose();
  }

  void _rolarParaFim() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_rolagem.hasClients) _rolagem.jumpTo(_rolagem.position.maxScrollExtent);
  });

  void _enviar([String? texto]) {
    widget.conversa.perguntar(texto ?? _campo.text);
    _campo.clear();
  }

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.conversa,
      builder: (context, _) {
        final c = widget.conversa;
        return Column(
          children: [
            ListTile(
              leading: const Icon(Icons.auto_awesome_outlined),
              title: const Text('Assistente'),
              subtitle: const Text('Dúvidas sobre suas tarefas e rotinas'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (c.mensagens.isNotEmpty)
                    IconButton(tooltip: 'Nova conversa', icon: const Icon(Icons.delete_sweep_outlined), onPressed: c.limpar),
                  if (widget.aoFechar != null)
                    IconButton(tooltip: 'Fechar', icon: const Icon(Icons.close), onPressed: widget.aoFechar),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                controller: _rolagem,
                padding: const EdgeInsets.all(12),
                children: [
                  for (final (papel, texto) in c.mensagens) _Balao(texto: texto, doUsuario: papel == 'usuario'),
                  if (c.pensando)
                    const Padding(
                      padding: EdgeInsets.all(8),
                      child: Align(alignment: Alignment.centerLeft, child: CircularProgressIndicator.adaptive()),
                    ),
                  if (c.erro != null)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(c.erro!, style: TextStyle(color: cores.error)),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final r in respostasRapidas)
                    ActionChip(label: Text(r), onPressed: c.pensando ? null : () => _enviar(r)),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  controller: _campo,
                  enabled: !c.pensando,
                  textInputAction: TextInputAction.send,
                  minLines: 1,
                  maxLines: 4,
                  onSubmitted: (_) => _enviar(),
                  decoration: InputDecoration(
                    hintText: 'Pergunte algo…',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // a fala transcrita vai direto como pergunta
                        BotaoMicrofone(
                          transcrever: c.api.transcrever,
                          aoTranscrever: _enviar,
                          habilitado: !c.pensando,
                        ),
                        IconButton(icon: const Icon(Icons.send), onPressed: () => _enviar()),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Balao extends StatelessWidget {
  const _Balao({required this.texto, required this.doUsuario});

  final String texto;
  final bool doUsuario;

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    return Align(
      alignment: doUsuario ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: doUsuario ? cores.primaryContainer : cores.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: SelectableText(
          texto,
          style: TextStyle(color: doUsuario ? cores.onPrimaryContainer : cores.onSurface),
        ),
      ),
    );
  }
}
