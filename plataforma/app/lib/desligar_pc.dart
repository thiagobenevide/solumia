import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

/// Botão do topo: liga o PC (Wake-on-LAN pela VPS) ou desliga (pelo worker), com confirmação;
/// também cancela um desligamento agendado pelo chat ("desliga o PC em 30 minutos").
class BotaoDesligarPc extends StatelessWidget {
  const BotaoDesligarPc({super.key, required this.api});

  final ApiCliente api;

  Future<void> _perguntar(BuildContext context) async {
    final acao = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.power_settings_new),
        title: const Text('Ligar ou desligar o PC?'),
        content: const Text('Ao desligar, programas abertos no computador serão fechados.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, 'cancelar_desligar'), child: const Text('Cancelar agendado')),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Voltar')),
          FilledButton.tonal(onPressed: () => Navigator.pop(context, 'ligar'), child: const Text('Ligar')),
          FilledButton(onPressed: () => Navigator.pop(context, 'desligar'), child: const Text('Desligar')),
        ],
      ),
    );
    if (acao == null || !context.mounted) return;
    final aviso = ScaffoldMessenger.of(context);
    try {
      final r = await api.post('api/painel/pc', {'acao': acao}) as Map<String, dynamic>;
      aviso.showSnackBar(SnackBar(content: Text('${r['detalhe'] ?? 'Feito'}')));
    } on ApiErro catch (e) {
      aviso.showSnackBar(SnackBar(content: Text(e.mensagem)));
    }
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Ligar/desligar o PC',
    icon: const Icon(Icons.power_settings_new),
    onPressed: () => _perguntar(context),
  );
}
