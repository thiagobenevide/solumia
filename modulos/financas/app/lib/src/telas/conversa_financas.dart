import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api_financas.dart';
import '../formato.dart';
import 'comuns.dart';

/// Conversa por texto ou voz sobre os seus dados financeiros e a simulação aberta. Pergunta feita no
/// microfone é respondida em voz alta; com "Ler respostas", as digitadas também.
class ConversaFinancas extends StatefulWidget {
  const ConversaFinancas({super.key, required this.api, this.cenario});

  final ApiFinancas api;

  /// `{pergunta, analise}` da simulação na tela (contexto da conversa).
  final Doc? cenario;

  @override
  State<ConversaFinancas> createState() => _ConversaFinancasState();
}

class _ConversaFinancasState extends State<ConversaFinancas> {
  static final _vozSuportada = !kIsWeb;

  final _texto = TextEditingController();
  final _player = AudioPlayer();
  final _mensagens = <Doc>[];
  bool _pensando = false;
  bool _falando = false;
  bool _lerSempre = false;
  String? _erro;
  int _fala = 0;

  @override
  void initState() {
    super.initState();
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _falando = false);
    });
  }

  @override
  void dispose() {
    _texto.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _enviar(String pergunta, {bool porVoz = false}) async {
    pergunta = pergunta.trim();
    if (pergunta.isEmpty || _pensando) return;
    await _parar();
    setState(() {
      _mensagens.add({'role': 'user', 'content': porVoz ? '🎤 $pergunta' : pergunta});
      _pensando = true;
      _erro = null;
      _texto.clear();
    });
    try {
      final enviar = [
        for (final m in _mensagens) {'role': m['role'], 'content': (m['content'] as String).replaceFirst('🎤 ', '')},
      ];
      final resposta = await widget.api.conversar(enviar, cenario: widget.cenario);
      if (!mounted) return;
      setState(() => _mensagens.add({'role': 'assistant', 'content': resposta}));
      if (_vozSuportada && (porVoz || _lerSempre)) await _falar(resposta);
    } on ApiErro catch (e) {
      if (mounted) setState(() => _erro = e.mensagem);
    } finally {
      if (mounted) setState(() => _pensando = false);
    }
  }

  Future<void> _falar(String texto) async {
    final n = ++_fala;
    try {
      final wav = await widget.api.falar(texto);
      if (n != _fala || !mounted) return; // outra pergunta chegou enquanto a voz era gerada
      final arquivo = File('${Directory.systemTemp.path}/financas_fala_$n.wav');
      await arquivo.writeAsBytes(wav, flush: true);
      setState(() => _falando = true);
      await _player.play(DeviceFileSource(arquivo.path));
    } on ApiErro catch (e) {
      if (mounted) setState(() => _erro = 'Sem voz agora: ${e.mensagem}');
    } catch (e) {
      if (mounted) setState(() => _erro = 'Não consegui tocar a resposta: $e');
    }
  }

  Future<void> _parar() async {
    _fala++;
    if (_falando) await _player.stop();
    if (mounted) setState(() => _falando = false);
  }

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    return Secao(
      titulo: 'Conversar sobre minhas finanças',
      subtitulo: 'Pergunte por texto ou pelo microfone; a resposta vem curta e, se você falou, em voz alta.',
      acoes: [
        if (_vozSuportada)
          FilterChip(
            label: const Text('Ler respostas'),
            avatar: const Icon(Icons.volume_up, size: 18),
            selected: _lerSempre,
            onSelected: (v) => setState(() => _lerSempre = v),
          ),
        if (_falando) IconButton(tooltip: 'Parar a voz', icon: const Icon(Icons.stop_circle), onPressed: _parar),
        if (_mensagens.isNotEmpty)
          IconButton(
            tooltip: 'Nova conversa',
            icon: const Icon(Icons.refresh),
            onPressed: _pensando
                ? null
                : () {
                    _parar();
                    setState(_mensagens.clear);
                  },
          ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          for (final m in _mensagens)
            Align(
              alignment: m['role'] == 'user' ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 640),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: m['role'] == 'user' ? cores.primaryContainer : cores.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SelectableText(m['content'] as String),
              ),
            ),
          if (_pensando)
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
                  controller: _texto,
                  enabled: !_pensando,
                  textInputAction: TextInputAction.send,
                  onSubmitted: _enviar,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                    hintText: 'Ex.: Onde estou gastando mais? Dá para guardar 1.000 por mês?',
                  ),
                ),
              ),
              if (_vozSuportada)
                BotaoMicrofone(
                  habilitado: !_pensando,
                  transcrever: widget.api.transcrever,
                  aoTranscrever: (t) => _enviar(t, porVoz: true),
                ),
              IconButton(
                tooltip: 'Enviar',
                icon: const Icon(Icons.send),
                onPressed: _pensando ? null : () => _enviar(_texto.text),
              ),
            ],
          ),
          if (_erro != null) Text(_erro!, style: TextStyle(color: cores.error)),
        ],
      ),
    );
  }
}
