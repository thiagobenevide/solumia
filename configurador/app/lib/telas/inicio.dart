import 'package:flutter/material.dart';

import '../l10n/textos.dart';
import '../nucleo.dart';
import '../tema.dart';

/// Início: o que já está configurado e o próximo passo.
class TelaInicio extends StatefulWidget {
  const TelaInicio({super.key, required this.nucleo, required this.irPara});
  final Nucleo nucleo;
  final void Function(int indice) irPara;
  @override
  State<TelaInicio> createState() => _TelaInicioEstado();
}

class _TelaInicioEstado extends State<TelaInicio> {
  Map<String, dynamic>? _saude;
  Map<String, dynamic>? _m;
  List<String> _cofre = [];
  List<Map<String, dynamic>> _apps = [];

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Future<void> _carregar() async {
    final r = await Future.wait([
      widget.nucleo.get('/saude'),
      widget.nucleo.manifesto(),
      widget.nucleo.get('/cofre'),
      widget.nucleo.get('/craft-apps'),
    ]);
    if (!mounted) return;
    setState(() {
      _saude = r[0] as Map<String, dynamic>;
      _m = r[1] as Map<String, dynamic>;
      _cofre = ((r[2] as Map)['segredos'] as List).cast<String>();
      _apps = ((r[3] as Map)['apps'] as List).cast<Map<String, dynamic>>();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Textos.of(context);
    final cores = Theme.of(context).colorScheme;
    final s = _saude, m = _m;
    if (s == null || m == null) return const Center(child: CircularProgressIndicator());
    final nos = m['nos'] as Map;
    final ssh = (nos['vps'] as Map?)?['ssh'] as Map?;
    final itens = <(String, bool, String, int)>[
      (t.itemConta, _cofre.contains('conta.totp'), t.itemContaDetalhe, 1),
      (t.navVps, (ssh?['impressao_host'] as String? ?? '').isNotEmpty,
          ssh == null ? t.itemVpsDetalhe : '${ssh['usuario']}@${ssh['host']}', 2),
      (t.itemPastas, (nos['casa'] as Map?)?['pastas'] != null, t.itemPastasDetalhe, 3),
      (t.navCraft, _apps.any((a) => a['instalado'] != null),
          t.itemCraftDetalhe(_apps.where((a) => a['instalado'] != null).length, _apps.length), 4),
      (t.itemApps, false, t.itemAppsDetalhe, 5),
    ];
    return RefreshIndicator(
      onRefresh: _carregar,
      child: ListView(padding: const EdgeInsets.all(24), children: [
        Text('Solumia', style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: cores.primary)),
        Text(t.inicioVersao('${s['versao']}', '${s['protocolo']}', '${s['so']}', '${s['arquitetura']}')),
        Text(t.inicioManifesto('${s['manifesto']}'), style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 24),
        for (final (titulo, ok, detalhe, indice) in itens)
          Card(
            child: ListTile(
              leading: Icon(ok ? Icons.check_circle : Icons.radio_button_unchecked, color: ok ? cores.sucesso : null),
              title: Text(titulo),
              subtitle: Text(detalhe),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => widget.irPara(indice),
            ),
          ),
        const SizedBox(height: 16),
        Text(t.inicioConvivencia('${(s['nomes'] as Map)['prefixo']}', '${(s['nomes'] as Map)['porta_gateway']}',
            '${(s['nomes'] as Map)['porta_tunel']}'),
            style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}
