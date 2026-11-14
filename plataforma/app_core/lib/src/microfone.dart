import 'dart:async';

import 'package:flutter/material.dart';
import 'package:record/record.dart';

import 'api.dart';
import 'microfone_web.dart' if (dart.library.io) 'microfone_io.dart';

/// Fala → texto pelo Whisper do worker (`/api/painel/transcrever`). [idioma] `pt`, `en` ou vazio
/// (detecta entre os dois).
Future<String> transcreverFala(ApiCliente api, List<int> wav, {String idioma = ''}) async {
  final r = await api.enviarArquivo(
    'api/painel/transcrever',
    'audio',
    'fala.wav',
    wav,
    campos: {if (idioma.isNotEmpty) 'idioma': idioma},
  );
  return (r as Map)['texto'] as String;
}

/// Microfone para qualquer chat: toque grava; para sozinho ~1,2 s depois que você para de falar (ou
/// no segundo toque), transcreve no PC e entrega o texto em [aoTranscrever].
class BotaoMicrofone extends StatefulWidget {
  const BotaoMicrofone({super.key, required this.transcrever, required this.aoTranscrever, this.habilitado = true});

  final Future<String> Function(List<int> wav) transcrever;
  final void Function(String texto) aoTranscrever;
  final bool habilitado;

  @override
  State<BotaoMicrofone> createState() => _BotaoMicrofoneState();
}

class _BotaoMicrofoneState extends State<BotaoMicrofone> {
  final _gravador = AudioRecorder();
  StreamSubscription<Amplitude>? _vigia;
  bool _gravando = false;
  bool _transcrevendo = false;

  @override
  void dispose() {
    _vigia?.cancel();
    _gravador.dispose();
    super.dispose();
  }

  void _avisar(String texto) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(texto)));
  }

  Future<void> _alternar() async {
    if (_gravando) return _pararEEnviar();
    try {
      if (!await _gravador.hasPermission()) return _avisar('Sem permissão para usar o microfone.');
      await _gravador.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
          autoGain: true,
          echoCancel: true,
          noiseSuppress: true,
        ),
        path: await caminhoGravacao(),
      );
    } catch (e) {
      return _avisar('Não consegui abrir o microfone: $e');
    }
    setState(() => _gravando = true);
    _vigiarSilencio();
  }

  /// Fim da fala pelo volume (dBFS, acima de -40 é voz); 8 s sem voz cancela.
  void _vigiarSilencio() {
    final inicio = DateTime.now();
    DateTime? ultimaVoz;
    _vigia = _gravador.onAmplitudeChanged(const Duration(milliseconds: 120)).listen((amp) {
      if (!_gravando) return;
      final agora = DateTime.now();
      if (amp.current > -40) ultimaVoz = agora;
      if (ultimaVoz == null && agora.difference(inicio) > const Duration(seconds: 8)) {
        _cancelar();
      } else if (ultimaVoz != null && agora.difference(ultimaVoz!) > const Duration(milliseconds: 1200)) {
        _pararEEnviar();
      }
    });
  }

  Future<void> _cancelar() async {
    _vigia?.cancel();
    setState(() => _gravando = false);
    try {
      await _gravador.cancel();
    } catch (_) {}
    _avisar('Não ouvi nada.');
  }

  Future<void> _pararEEnviar() async {
    if (!_gravando) return;
    _vigia?.cancel();
    setState(() {
      _gravando = false;
      _transcrevendo = true;
    });
    try {
      final caminho = await _gravador.stop();
      if (caminho == null) return;
      final wav = await lerEApagar(caminho);
      // WAV 16 kHz mono: menos de ~0,4 s é toque acidental.
      if (wav.length < 44 + 16000 * 2 * 0.4) return _avisar('Gravação curta demais.');
      final texto = (await widget.transcrever(wav).timeout(const Duration(minutes: 1))).trim();
      if (texto.isNotEmpty) widget.aoTranscrever(texto);
    } on ApiErro catch (e) {
      _avisar(e.mensagem);
    } on TimeoutException {
      _avisar('O PC demorou para transcrever; tente de novo.');
    } catch (e) {
      _avisar('A gravação falhou: $e');
    } finally {
      if (mounted) setState(() => _transcrevendo = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_transcrevendo) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return IconButton(
      tooltip: _gravando ? 'Parar e enviar' : 'Falar (português ou inglês)',
      color: _gravando ? Theme.of(context).colorScheme.error : null,
      onPressed: widget.habilitado || _gravando ? _alternar : null,
      icon: Icon(_gravando ? Icons.stop_circle : Icons.mic_none),
    );
  }
}
