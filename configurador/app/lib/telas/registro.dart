import 'package:flutter/material.dart';

import '../l10n/textos.dart';
import '../nucleo.dart';
import '../plano.dart';
import '../tema.dart';

/// Registro: todas as aplicações feitas, com o estado final.
class TelaRegistro extends StatefulWidget {
  const TelaRegistro({super.key, required this.nucleo});
  final Nucleo nucleo;
  @override
  State<TelaRegistro> createState() => _TelaRegistroEstado();
}

class _TelaRegistroEstado extends State<TelaRegistro> {
  List<Map<String, dynamic>> _itens = [];

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Future<void> _carregar() async {
    final r = await widget.nucleo.get('/registro') as Map<String, dynamic>;
    if (mounted) setState(() => _itens = (r['execucoes'] as List).cast<Map<String, dynamic>>());
  }

  @override
  Widget build(BuildContext context) {
    final t = Textos.of(context);
    final cores = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: _carregar,
      child: ListView(padding: const EdgeInsets.all(24), children: [
        Text(t.registroTitulo, style: Theme.of(context).textTheme.headlineSmall),
        if (_itens.isEmpty) Padding(padding: const EdgeInsets.only(top: 16), child: Text(t.registroVazio)),
        for (final i in _itens)
          ListTile(
            leading: Icon(switch (i['estado']) {
              'concluida' => Icons.check_circle,
              'falhou' => Icons.error,
              _ => Icons.pause_circle,
            }, color: switch (i['estado']) {
              'concluida' => cores.sucesso,
              'falhou' => cores.error,
              _ => cores.atencao,
            }),
            title: Text(i['titulo'] as String),
            subtitle: Text('${i['id']} · ${rotuloEstado(t, i['estado'] as String)}'),
          ),
      ]),
    );
  }
}
