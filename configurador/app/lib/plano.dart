// Diálogo de plano: mostra os passos ANTES de qualquer mudança, aplica só com confirmação e
// acompanha a execução com log ao vivo.
import 'dart:async';

import 'package:flutter/material.dart';

import 'l10n/textos.dart';
import 'nucleo.dart';
import 'tema.dart';

Future<bool> mostrarPlano(BuildContext context, Nucleo nucleo, Map<String, dynamic> plano) async {
  final r = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _DialogoPlano(nucleo: nucleo, plano: plano),
  );
  return r ?? false;
}

class _DialogoPlano extends StatefulWidget {
  const _DialogoPlano({required this.nucleo, required this.plano});
  final Nucleo nucleo;
  final Map<String, dynamic> plano;
  @override
  State<_DialogoPlano> createState() => _DialogoPlanoEstado();
}

class _DialogoPlanoEstado extends State<_DialogoPlano> {
  final _totp = TextEditingController();
  final _rolagem = ScrollController();
  String? _execId;
  String _estado = 'plano'; // plano | rodando | concluida | falhou | cancelada
  final Map<String, String> _passos = {};
  final List<Map<String, dynamic>> _log = [];
  int _desde = 0;
  Timer? _timer;
  String? _erro;

  List<Map<String, dynamic>> get _lista =>
      (widget.plano['passos'] as List).cast<Map<String, dynamic>>();

  @override
  void dispose() {
    _timer?.cancel();
    _totp.dispose();
    _rolagem.dispose();
    super.dispose();
  }

  Future<void> _aplicar() async {
    setState(() => _erro = null);
    try {
      final r = await widget.nucleo.post('/planos/${widget.plano['id']}/aplicar', {
        'hash': widget.plano['hash'],
        if (widget.plano['destrutivo'] == true) 'totp': _totp.text.trim(),
      });
      _execId = r['id'] as String;
      setState(() => _estado = 'rodando');
      _timer = Timer.periodic(const Duration(milliseconds: 700), (_) => _consultar());
    } on ErroNucleo catch (e) {
      setState(() => _erro = e.mensagem);
    }
  }

  Future<void> _consultar() async {
    if (_execId == null) return;
    try {
      final r = await widget.nucleo.get('/execucoes/$_execId', {'desde': '$_desde'});
      final novos = (r['novos'] as List).cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() {
        for (final ev in novos) {
          _desde = (ev['n'] as int) + 1;
          final passo = ev['passo'] as String?;
          switch (ev['tipo']) {
            case 'passo':
              _passos[passo!] = 'rodando';
            case 'ok':
              if (_passos[passo] != 'pulado') _passos[passo!] = 'ok';
            case 'pulado':
              _passos[passo!] = 'pulado';
            case 'falha':
              if (passo != null) _passos[passo] = 'falha';
              _log.add(ev);
            default:
              if ((ev['texto'] as String).isNotEmpty) _log.add(ev);
          }
        }
        final estado = r['estado'] as String;
        if (estado != 'rodando' && estado != 'pendente') {
          _estado = estado;
          _timer?.cancel();
        }
      });
      if (_rolagem.hasClients) {
        _rolagem.jumpTo(_rolagem.position.maxScrollExtent);
      }
    } on ErroNucleo catch (e) {
      setState(() => _erro = e.mensagem);
    }
  }

  Widget _icone(String? s, ColorScheme c) => switch (s) {
        'rodando' => const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        'ok' => Icon(Icons.check_circle, color: c.sucesso, size: 20),
        'pulado' => Icon(Icons.skip_next, color: c.outline, size: 20),
        'falha' => Icon(Icons.error, color: c.error, size: 20),
        _ => const Icon(Icons.radio_button_unchecked, size: 20),
      };

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final t = Textos.of(context);
    final rodou = _estado != 'plano';
    return AlertDialog(
      title: Text(widget.plano['titulo'] as String),
      content: SizedBox(
        width: 760,
        height: 560,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(rodou ? t.planoExecucao(rotuloEstado(t, _estado)) : t.planoNadaAlterado,
              style: tema.textTheme.titleSmall),
          const SizedBox(height: 8),
          Expanded(
            flex: rodou ? 2 : 5,
            child: ListView(children: [
              for (final p in _lista)
                ListTile(
                  dense: true,
                  leading: _icone(_passos[p['id']], tema.colorScheme),
                  title: Text(p['titulo'] as String),
                  subtitle: (p['detalhe'] as String).isEmpty ? null : Text(p['detalhe'] as String),
                ),
            ]),
          ),
          if (rodou) ...[
            const Divider(),
            Expanded(
              flex: 3,
              child: Container(
                padding: const EdgeInsets.all(8),
                color: tema.colorScheme.surfaceContainerHighest,
                child: ListView.builder(
                  controller: _rolagem,
                  itemCount: _log.length,
                  itemBuilder: (_, i) {
                    final ev = _log[i];
                    return SelectableText(ev['texto'] as String,
                        style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: ev['tipo'] == 'falha' ? tema.colorScheme.error : null));
                  },
                ),
              ),
            ),
          ],
          if (!rodou && widget.plano['destrutivo'] == true)
            TextField(
              controller: _totp,
              decoration: InputDecoration(labelText: t.codigoDestrutivo),
              keyboardType: TextInputType.number,
              maxLength: 6,
            ),
          if (_erro != null) Text(_erro!, style: TextStyle(color: tema.colorScheme.error)),
        ]),
      ),
      actions: [
        if (_estado == 'plano') ...[
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.cancelar)),
          FilledButton.icon(onPressed: _aplicar, icon: const Icon(Icons.play_arrow), label: Text(t.aplicar)),
        ],
        if (_estado == 'rodando')
          TextButton(
            onPressed: () => widget.nucleo.post('/execucoes/$_execId/cancelar'),
            child: Text(t.pararAposPasso),
          ),
        if (_estado != 'plano' && _estado != 'rodando')
          FilledButton(onPressed: () => Navigator.pop(context, _estado == 'concluida'), child: Text(t.fechar)),
      ],
    );
  }
}

String rotuloEstado(Textos t, String s) => switch (s) {
      'rodando' => t.estadoRodando,
      'concluida' => t.estadoConcluida,
      'falhou' => t.estadoFalhou,
      'cancelada' => t.estadoCancelada,
      _ => s,
    };

void avisar(BuildContext context, String texto, {bool erro = false}) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(texto),
    backgroundColor: erro ? Theme.of(context).colorScheme.error : null,
  ));
}
