import 'package:flutter/material.dart';

import '../api_eletronica.dart';
import '../cad/exportar.dart';
import '../modelos.dart';

/// Lista de peças, ligações (netlist) e verificação elétrica (ERC) do que está gravado, com o CSV para compras.
Future<void> mostrarBom(BuildContext context, ApiEletronica api, Projeto projeto) {
  final erc = api.erc(projeto.id);
  return showDialog<void>(
    context: context,
    builder: (c) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820, maxHeight: 640),
        child: DefaultTabController(
          length: 3,
          child: Column(
            children: [
              TabBar(
                tabs: [
                  const Tab(text: 'Lista de peças'),
                  const Tab(text: 'Ligações'),
                  Tab(
                    child: FutureBuilder(
                      future: erc,
                      builder: (_, s) =>
                          Text(s.hasData ? 'Verificação (ERC) · ${s.data!.length}' : 'Verificação (ERC)'),
                    ),
                  ),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _Bom(api: api, projeto: projeto),
                    _Ligacoes(api: api, projeto: projeto),
                    _Erc(erc: erc),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _Bom extends StatelessWidget {
  const _Bom({required this.api, required this.projeto});

  final ApiEletronica api;
  final Projeto projeto;

  Future<void> _csv(BuildContext context) async {
    final mensageiro = ScaffoldMessenger.of(context);
    try {
      final nome = projeto.titulo.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      await salvarArquivo('$nome-bom.csv', await api.bomCsv(projeto.id), 'text/csv');
    } catch (e) {
      mensageiro.showSnackBar(SnackBar(content: Text('Não baixou: $e')));
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: api.bom(projeto.id),
    builder: (context, s) {
      if (s.hasError) return Center(child: Text('${s.error}'));
      if (!s.hasData) return const Center(child: CircularProgressIndicator());
      final linhas = s.data!;
      if (linhas.isEmpty) return const Center(child: Text('Nenhum componente no projeto.'));
      return Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('Referências')),
                    DataColumn(label: Text('Qtd'), numeric: true),
                    DataColumn(label: Text('Descrição')),
                    DataColumn(label: Text('Valor')),
                    DataColumn(label: Text('Encapsulamento')),
                  ],
                  rows: [
                    for (final l in linhas)
                      DataRow(
                        cells: [
                          DataCell(Text((l['refs'] as List).join(' '))),
                          DataCell(Text('${l['quantidade']}')),
                          DataCell(Text('${l['descricao']}')),
                          DataCell(Text('${l['valor']}')),
                          DataCell(Text('${l['encapsulamento']}')),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: () => _csv(context),
                icon: const Icon(Icons.download),
                label: const Text('Baixar CSV'),
              ),
            ),
          ),
        ],
      );
    },
  );
}

class _Ligacoes extends StatelessWidget {
  const _Ligacoes({required this.api, required this.projeto});

  final ApiEletronica api;
  final Projeto projeto;

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: api.netlist(projeto.id),
    builder: (context, s) {
      if (s.hasError) return Center(child: Text('${s.error}'));
      if (!s.hasData) return const Center(child: CircularProgressIndicator());
      final redes = s.data!['redes'] as List;
      final soltos = s.data!['soltos'] as List;
      String pino(dynamic p) => '${p['ref']}.${p['pino']}${(p['nome'] as String).isEmpty ? '' : ' (${p['nome']})'}';
      return ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (soltos.isNotEmpty)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.warning_amber),
                title: Text('${soltos.length} pino${soltos.length == 1 ? '' : 's'} sem ligação'),
                subtitle: Text(soltos.map(pino).join(', ')),
              ),
            ),
          for (final r in redes)
            ListTile(
              dense: true,
              title: Text(
                '${r['nome']}',
                style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold),
              ),
              subtitle: Text((r['pinos'] as List).map(pino).join(', ')),
            ),
        ],
      );
    },
  );
}

class _Erc extends StatelessWidget {
  const _Erc({required this.erc});

  final Future<List<Map<String, dynamic>>> erc;

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: erc,
    builder: (context, s) {
      if (s.hasError) return Center(child: Text('${s.error}'));
      if (!s.hasData) return const Center(child: CircularProgressIndicator());
      final problemas = s.data!;
      if (problemas.isEmpty) {
        return const Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_circle_outline, color: Colors.green),
              SizedBox(width: 8),
              Text('Nenhum problema encontrado.'),
            ],
          ),
        );
      }
      return ListView(
        padding: const EdgeInsets.all(12),
        children: [
          for (final p in problemas)
            ListTile(
              dense: true,
              leading: p['nivel'] == 'erro'
                  ? Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error)
                  : const Icon(Icons.warning_amber, color: Colors.amber),
              title: Text('${p['mensagem']}'),
              subtitle: Text(
                [
                  if (p['rede'] != null) 'Rede ${p['rede']}',
                  if ((p['refs'] as List).isNotEmpty) (p['refs'] as List).join(' '),
                  if (p['x'] != null) '(${_mm(p['x'] as num)}; ${_mm(p['y'] as num)}) mm',
                ].join(' · '),
              ),
            ),
        ],
      );
    },
  );
}

String _mm(num um) => (um / 1000).toStringAsFixed(2).replaceAll('.', ',');
