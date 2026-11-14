import 'package:flutter/material.dart';

import '../electronics_api.dart';
import '../cad/export.dart';
import '../models.dart';

/// Parts list, connections (netlist) and electrical check (ERC) of what is saved, with the CSV for purchasing.
Future<void> showBom(BuildContext context, ElectronicsApi api, Project project) {
  final erc = api.erc(project.id);
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
                    _Bom(api: api, project: project),
                    _Connections(api: api, project: project),
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
  const _Bom({required this.api, required this.project});

  final ElectronicsApi api;
  final Project project;

  Future<void> _csv(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final name = project.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      await saveFile('$name-bom.csv', await api.bomCsv(project.id), 'text/csv');
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Não baixou: $e')));
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: api.bom(project.id),
    builder: (context, s) {
      if (s.hasError) return Center(child: Text('${s.error}'));
      if (!s.hasData) return const Center(child: CircularProgressIndicator());
      final lines = s.data!;
      if (lines.isEmpty) return const Center(child: Text('Nenhum componente no projeto.'));
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
                    for (final l in lines)
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

class _Connections extends StatelessWidget {
  const _Connections({required this.api, required this.project});

  final ElectronicsApi api;
  final Project project;

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: api.netlist(project.id),
    builder: (context, s) {
      if (s.hasError) return Center(child: Text('${s.error}'));
      if (!s.hasData) return const Center(child: CircularProgressIndicator());
      final nets = s.data!['redes'] as List;
      final loose = s.data!['soltos'] as List;
      String pin(dynamic p) => '${p['ref']}.${p['pino']}${(p['nome'] as String).isEmpty ? '' : ' (${p['nome']})'}';
      return ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (loose.isNotEmpty)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.warning_amber),
                title: Text('${loose.length} pino${loose.length == 1 ? '' : 's'} sem ligação'),
                subtitle: Text(loose.map(pin).join(', ')),
              ),
            ),
          for (final r in nets)
            ListTile(
              dense: true,
              title: Text(
                '${r['nome']}',
                style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold),
              ),
              subtitle: Text((r['pinos'] as List).map(pin).join(', ')),
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
      final problems = s.data!;
      if (problems.isEmpty) {
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
          for (final p in problems)
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
