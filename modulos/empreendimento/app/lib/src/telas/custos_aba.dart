import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../modelos.dart';
import 'util.dart';

/// Consumo do Claude (escalonamento): hoje, total, teto, gasto por episódio e cada chamada.
class CustosAba extends StatelessWidget {
  const CustosAba({super.key, required this.api});

  final ApiEsteira api;

  @override
  Widget build(BuildContext context) => Sondagem<Json>(
    intervalo: const Duration(seconds: 15),
    carregar: api.custos,
    construir: (context, d, _) {
      final regs = [for (final r in d['registros'] as List) r as Json];
      final porEp = [for (final p in d['por_episodio'] as List) p as Json];
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'O Claude só é chamado quando o código e o LLM local não resolvem com confiança. Sem cobrança extra: as '
            'chamadas usam a sua assinatura do Claude (sem chave de API). Os valores em US\$ são o equivalente em '
            'preço de API, só para medir o consumo e aplicar os tetos.',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Indicador(
                'Hoje',
                dolares(d['hoje'] as num),
                sub: 'teto ${dolares(d['teto_dia_usd'] as num, casas: 2)}',
              ),
              Indicador('Total', dolares(d['total'] as num), sub: '${d['n_registros']} chamadas'),
              Indicador(
                'Teto por episódio',
                dolares(d['teto_episodio_usd'] as num, casas: 2),
                sub: '${d['modelo']}',
              ),
            ],
          ),
          const Secao('Por episódio'),
          Card(
            child: Column(
              children: [
                if (porEp.isEmpty) const ListTile(title: Text('Nenhuma chamada.')),
                for (final p in porEp)
                  ListTile(
                    dense: true,
                    title: Text('${p['ep']}'),
                    trailing: Text(dolares(p['custo'] as num)),
                  ),
              ],
            ),
          ),
          const Secao('Chamadas'),
          for (final r in regs)
            Card(
              margin: const EdgeInsets.only(bottom: 6),
              child: ExpansionTile(
                dense: true,
                title: Text('${r['motivo']}'),
                subtitle: Text('${'${r['t']}'.substring(5, 16).replaceFirst('T', ' ')} · ${r['ep']}'),
                trailing: Text(dolares(r['custo'] as num, casas: 4)),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (r['resposta'] != null)
                    SelectableText(
                      '${r['resposta']}',
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    ),
                ],
              ),
            ),
        ],
      );
    },
  );
}
