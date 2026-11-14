import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../routines_api.dart';

/// One-tap questions: the most common doubts about the board.
const quickReplies = [
  'O que devo fazer agora?',
  'Resuma meu dia',
  'Quanto tempo gastei hoje?',
  'Quais tarefas estão atrasadas?',
];

/// Chat with the LLM. Lives outside the widget to survive opening and closing the panel.
class AssistantChat extends ChangeNotifier {
  AssistantChat(this.api);

  final RoutinesApi api;

  /// (`usuario`|`assistente`, text), in order.
  final messages = <(String, String)>[];
  bool thinking = false;
  String? error;

  Future<void> ask(String question) async {
    question = question.trim();
    if (question.isEmpty || thinking) return;
    // the last exchanges are enough context; the whole board goes in the server prompt
    final history = messages.length > 10 ? messages.sublist(messages.length - 10) : [...messages];
    messages.add(('usuario', question));
    thinking = true;
    error = null;
    notifyListeners();
    try {
      messages.add(('assistente', await api.ask(question, history)));
    } on ApiErro catch (e) {
      error = e.status == 503 ? e.mensagem : '$e';
    } finally {
      thinking = false;
      notifyListeners();
    }
  }

  void clear() {
    messages.clear();
    error = null;
    notifyListeners();
  }
}

class Assistant extends StatefulWidget {
  const Assistant({super.key, required this.chat, this.onClose});

  final AssistantChat chat;
  final VoidCallback? onClose;

  @override
  State<Assistant> createState() => _AssistantState();
}

class _AssistantState extends State<Assistant> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.chat.addListener(_scrollToEnd);
  }

  @override
  void dispose() {
    widget.chat.removeListener(_scrollToEnd);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
  });

  void _send([String? text]) {
    widget.chat.ask(text ?? _input.text);
    _input.clear();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.chat,
      builder: (context, _) {
        final c = widget.chat;
        return Column(
          children: [
            ListTile(
              leading: const Icon(Icons.auto_awesome_outlined),
              title: const Text('Assistente'),
              subtitle: const Text('Dúvidas sobre suas tarefas e rotinas'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (c.messages.isNotEmpty)
                    IconButton(tooltip: 'Nova conversa', icon: const Icon(Icons.delete_sweep_outlined), onPressed: c.clear),
                  if (widget.onClose != null)
                    IconButton(tooltip: 'Fechar', icon: const Icon(Icons.close), onPressed: widget.onClose),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                controller: _scroll,
                padding: const EdgeInsets.all(12),
                children: [
                  for (final (role, text) in c.messages) _Bubble(text: text, fromUser: role == 'usuario'),
                  if (c.thinking)
                    const Padding(
                      padding: EdgeInsets.all(8),
                      child: Align(alignment: Alignment.centerLeft, child: CircularProgressIndicator.adaptive()),
                    ),
                  if (c.error != null)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(c.error!, style: TextStyle(color: colors.error)),
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
                  for (final r in quickReplies)
                    ActionChip(label: Text(r), onPressed: c.thinking ? null : () => _send(r)),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  controller: _input,
                  enabled: !c.thinking,
                  textInputAction: TextInputAction.send,
                  minLines: 1,
                  maxLines: 4,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: 'Pergunte algo…',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // the transcribed speech goes straight in as a question
                        BotaoMicrofone(
                          transcrever: c.api.transcrever,
                          aoTranscrever: _send,
                          habilitado: !c.thinking,
                        ),
                        IconButton(icon: const Icon(Icons.send), onPressed: () => _send()),
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

class _Bubble extends StatelessWidget {
  const _Bubble({required this.text, required this.fromUser});

  final String text;
  final bool fromUser;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Align(
      alignment: fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: fromUser ? colors.primaryContainer : colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: SelectableText(
          text,
          style: TextStyle(color: fromUser ? colors.onPrimaryContainer : colors.onSurface),
        ),
      ),
    );
  }
}
