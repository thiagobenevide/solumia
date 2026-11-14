import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../finance_api.dart';
import '../format.dart';
import 'common.dart';

/// Text or voice chat about your financial data and the open simulation. A question asked on the
/// microphone is answered aloud; with "Ler respostas", the typed ones too.
class FinanceChat extends StatefulWidget {
  const FinanceChat({super.key, required this.api, this.scenario});

  final FinanceApi api;

  /// `{pergunta, analise}` of the simulation on screen (chat context).
  final Doc? scenario;

  @override
  State<FinanceChat> createState() => _FinanceChatState();
}

class _FinanceChatState extends State<FinanceChat> {
  static final _voiceSupported = !kIsWeb;

  final _text = TextEditingController();
  final _player = AudioPlayer();
  final _messages = <Doc>[];
  bool _thinking = false;
  bool _speaking = false;
  bool _alwaysRead = false;
  String? _error;
  int _speech = 0;

  @override
  void initState() {
    super.initState();
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _speaking = false);
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _send(String question, {bool byVoice = false}) async {
    question = question.trim();
    if (question.isEmpty || _thinking) return;
    await _stop();
    setState(() {
      _messages.add({'role': 'user', 'content': byVoice ? '🎤 $question' : question});
      _thinking = true;
      _error = null;
      _text.clear();
    });
    try {
      final send = [
        for (final m in _messages) {'role': m['role'], 'content': (m['content'] as String).replaceFirst('🎤 ', '')},
      ];
      final answer = await widget.api.chat(send, scenario: widget.scenario);
      if (!mounted) return;
      setState(() => _messages.add({'role': 'assistant', 'content': answer}));
      if (_voiceSupported && (byVoice || _alwaysRead)) await _speak(answer);
    } on ApiErro catch (e) {
      if (mounted) setState(() => _error = e.mensagem);
    } finally {
      if (mounted) setState(() => _thinking = false);
    }
  }

  Future<void> _speak(String text) async {
    final n = ++_speech;
    try {
      final wav = await widget.api.speak(text);
      if (n != _speech || !mounted) return; // another question arrived while the voice was being generated
      final file = File('${Directory.systemTemp.path}/financas_fala_$n.wav');
      await file.writeAsBytes(wav, flush: true);
      setState(() => _speaking = true);
      await _player.play(DeviceFileSource(file.path));
    } on ApiErro catch (e) {
      if (mounted) setState(() => _error = 'Sem voz agora: ${e.mensagem}');
    } catch (e) {
      if (mounted) setState(() => _error = 'Não consegui tocar a resposta: $e');
    }
  }

  Future<void> _stop() async {
    _speech++;
    if (_speaking) await _player.stop();
    if (mounted) setState(() => _speaking = false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Section(
      title: 'Conversar sobre minhas finanças',
      subtitle: 'Pergunte por texto ou pelo microfone; a resposta vem curta e, se você falou, em voz alta.',
      stocks: [
        if (_voiceSupported)
          FilterChip(
            label: const Text('Ler respostas'),
            avatar: const Icon(Icons.volume_up, size: 18),
            selected: _alwaysRead,
            onSelected: (v) => setState(() => _alwaysRead = v),
          ),
        if (_speaking) IconButton(tooltip: 'Parar a voz', icon: const Icon(Icons.stop_circle), onPressed: _stop),
        if (_messages.isNotEmpty)
          IconButton(
            tooltip: 'Nova conversa',
            icon: const Icon(Icons.refresh),
            onPressed: _thinking
                ? null
                : () {
                    _stop();
                    setState(_messages.clear);
                  },
          ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          for (final m in _messages)
            Align(
              alignment: m['role'] == 'user' ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 640),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: m['role'] == 'user' ? colors.primaryContainer : colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SelectableText(m['content'] as String),
              ),
            ),
          if (_thinking)
            const Row(
              spacing: 8,
              children: [
                SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                Text('Pensando…'),
              ],
            ),
          Row(
            spacing: 4,
            children: [
              Expanded(
                child: TextField(
                  controller: _text,
                  enabled: !_thinking,
                  textInputAction: TextInputAction.send,
                  onSubmitted: _send,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                    hintText: 'Ex.: Onde estou gastando mais? Dá para guardar 1.000 por mês?',
                  ),
                ),
              ),
              if (_voiceSupported)
                BotaoMicrofone(
                  habilitado: !_thinking,
                  transcrever: widget.api.transcrever,
                  aoTranscrever: (t) => _send(t, byVoice: true),
                ),
              IconButton(
                tooltip: 'Enviar',
                icon: const Icon(Icons.send),
                onPressed: _thinking ? null : () => _send(_text.text),
              ),
            ],
          ),
          if (_error != null) Text(_error!, style: TextStyle(color: colors.error)),
        ],
      ),
    );
  }
}
