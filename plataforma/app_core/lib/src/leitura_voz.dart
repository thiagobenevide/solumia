import 'package:flutter/material.dart';
import 'package:record/record.dart';

import 'microfone_web.dart' if (dart.library.io) 'microfone_io.dart';

/// Grava a pessoa lendo em voz alta (WAV 16 kHz mono, o que o Whisper e o modelo fonético usam).
class GravadorLeitura {
  final _gravador = AudioRecorder();
  bool gravando = false;

  /// False sem permissão do microfone.
  Future<bool> iniciar() async {
    if (!await _gravador.hasPermission()) return false;
    await _gravador.start(
      const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1, noiseSuppress: true),
      path: await caminhoGravacao(),
    );
    return gravando = true;
  }

  /// Bytes do WAV, ou null se não gravou nada.
  Future<List<int>?> parar() async {
    if (!gravando) return null;
    gravando = false;
    final caminho = await _gravador.stop();
    return caminho == null ? null : lerEApagar(caminho);
  }

  Future<void> cancelar() async {
    gravando = false;
    try {
      await _gravador.cancel();
    } catch (_) {}
  }

  Future<void> dispose() => _gravador.dispose();
}

/// Resultado da leitura em voz alta (`/api/estudos/linguagem/leituras-voz`): números do topo e o
/// texto com cada palavra colorida — verde certa, laranja trocada (com o que foi ouvido), riscada
/// pulada, sublinhada em vermelho a pronúncia fraca. Tocar numa palavra chama [ouvir] (a pronúncia certa).
class ResultadoLeituraVoz extends StatelessWidget {
  const ResultadoLeituraVoz({super.key, required this.resultado, this.ouvir});

  final Map<String, dynamic> resultado;
  final void Function(String palavra)? ouvir;

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    final r = resultado;
    final palavras = (r['palavras'] as List? ?? const []).cast<Map>();
    final extras = (r['extras'] as List? ?? const []).cast<String>();
    final pronuncia = r['pronuncia'] as num?;
    Widget numero(String rotulo, String valor) => Column(
      children: [
        Text(valor, style: Theme.of(context).textTheme.titleLarge),
        Text(rotulo, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: 12,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceAround,
          spacing: 24,
          runSpacing: 8,
          children: [
            numero('palavras certas', '${r['precisao']}%'),
            if (pronuncia != null) numero('pronúncia', '$pronuncia%'),
            numero('palavras/min', '${r['ppm']}'),
            numero('pausas longas', '${r['pausas']}'),
          ],
        ),
        if ((r['aviso'] as String? ?? '').isNotEmpty)
          Text(r['aviso'] as String, style: TextStyle(color: cores.outline, fontSize: 12)),
        Wrap(
          spacing: 4,
          runSpacing: 6,
          children: [
            for (final p in palavras) _palavra(context, p.cast<String, dynamic>()),
          ],
        ),
        if (extras.isNotEmpty)
          Text('Dito a mais: ${extras.join(', ')}', style: TextStyle(color: cores.outline, fontSize: 12)),
      ],
    );
  }

  Widget _palavra(BuildContext context, Map<String, dynamic> p) {
    final cores = Theme.of(context).colorScheme;
    final estado = p['estado'] as String;
    final fonemas = (p['fonemas'] as Map?)?.cast<String, dynamic>();
    final acerto = (fonemas?['acerto'] as num?)?.toDouble();
    final fraca = acerto != null && acerto < 0.7 && estado != 'omitida';
    final cor = switch (estado) {
      'certa' => Colors.green.shade700,
      'trocada' => Colors.orange.shade800,
      _ => cores.outline,
    };
    final dicas = [
      if (estado == 'trocada') 'Ouvido: "${p['dita']}"',
      if (estado == 'omitida') 'Pulada',
      if (fonemas != null && estado != 'omitida')
        'Esperado /${fonemas['esperado']}/ · ouvido /${fonemas['ouvido']}/ (${((acerto ?? 0) * 100).round()}%)',
    ];
    return Tooltip(
      message: dicas.isEmpty ? 'Certa' : dicas.join('\n'),
      child: InkWell(
        onTap: ouvir == null ? null : () => ouvir!(p['texto'] as String),
        child: Text(
          p['texto'] as String,
          style: TextStyle(
            color: cor,
            fontSize: 16,
            decoration: estado == 'omitida'
                ? TextDecoration.lineThrough
                : fraca
                ? TextDecoration.underline
                : null,
            decorationColor: fraca ? cores.error : null,
            decorationThickness: 2,
          ),
        ),
      ),
    );
  }
}
