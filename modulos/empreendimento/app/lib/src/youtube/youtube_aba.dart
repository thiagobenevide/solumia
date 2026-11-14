import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../telas/util.dart';
import 'api_youtube.dart';
import 'canal_tela.dart';
import 'formulario.dart';

/// Gerência dos canais: um cartão por canal com o total e o status de cada coleção. Os dados vêm do
/// cofre de notas (`/api/youtube`); "Importar do Obsidian" traz as notas do vault para o cofre.
class YoutubeAba extends StatefulWidget {
  const YoutubeAba({super.key, required this.api});

  final ApiYoutube api;

  @override
  State<YoutubeAba> createState() => _YoutubeAbaState();
}

class _YoutubeAbaState extends State<YoutubeAba> {
  late Future<(Doc, List<Doc>)> _dados = _carregar();

  Future<(Doc, List<Doc>)> _carregar() async => (await widget.api.esquema(), await widget.api.canais());

  void _recarregar() => setState(() { _dados = _carregar(); });

  Future<void> _importar() async {
    var substituir = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Importar do Obsidian'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Copia Notas/Empreendimento/YouTube do vault para o cofre de notas, no padrão das notas.'),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: substituir,
                onChanged: (v) => set(() => substituir = v ?? false),
                title: const Text('Regravar notas que já existem no cofre'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Importar')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    await acaoComAviso(context, () async {
      final r = await widget.api.importar(substituir: substituir);
      return '${r['importadas']} notas importadas, ${r['puladas']} já existiam';
    });
    _recarregar();
  }

  Future<void> _novoCanal(Doc esquema) async {
    final r = await abrirTela<Doc>(context, (_) => FormularioNota(titulo: 'Novo canal', campos: camposCanal(esquema, novo: true)));
    if (r == null || !mounted) return;
    final campos = r['campos'] as Doc;
    await acaoComAviso(context, () async {
      await widget.api.criarCanal({
        'slug': campos['slug'],
        'titulo': r['titulo'],
        'nome': campos['nome'],
        if ('${campos['status']}'.isNotEmpty) 'status': campos['status'],
        'tags': r['tags'],
        'corpo': r['corpo'],
      });
      return 'Canal criado';
    });
    _recarregar();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _dados,
    builder: (context, s) {
      if (s.hasError) return ErroComRetry(erro: s.error!, tentar: _recarregar);
      final dados = s.data;
      if (dados == null) return const Center(child: CircularProgressIndicator());
      final (esquema, canais) = dados;
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => _novoCanal(esquema),
                icon: const Icon(Icons.add),
                label: const Text('Novo canal'),
              ),
              OutlinedButton.icon(
                onPressed: _importar,
                icon: const Icon(Icons.download_outlined),
                label: const Text('Importar do Obsidian'),
              ),
              IconButton(onPressed: _recarregar, icon: const Icon(Icons.refresh), tooltip: 'Recarregar'),
            ],
          ),
          const SizedBox(height: 12),
          if (canais.isEmpty)
            const Vazio('Nenhum canal no cofre. Importe do Obsidian ou crie um.', icone: Icons.smart_display_outlined)
          else
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final c in canais)
                  _CartaoCanal(
                    canal: c,
                    esquema: esquema,
                    abrir: () async {
                      await abrirTela(context, (_) => CanalTela(api: widget.api, slug: c['slug'] as String, esquema: esquema));
                      _recarregar();
                    },
                  ),
              ],
            ),
        ],
      );
    },
  );
}

/// Campos do formulário do canal; o identificador (pasta) só se escolhe ao criar.
List<Doc> camposCanal(Doc esquema, {bool novo = false}) => [
  if (novo) {'nome': 'slug', 'rotulo': 'Identificador (pasta, ex.: finlumia)', 'tipo': 'texto', 'opcoes': []},
  {'nome': 'nome', 'rotulo': 'Nome do canal', 'tipo': 'texto', 'opcoes': []},
  {'nome': 'status', 'rotulo': 'Status', 'tipo': 'opcoes', 'opcoes': esquema['status_canal']},
];

class _CartaoCanal extends StatelessWidget {
  const _CartaoCanal({required this.canal, required this.esquema, required this.abrir});

  final Doc canal;
  final Doc esquema;
  final VoidCallback abrir;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final colecoes = canal['colecoes'] as Doc;
    return SizedBox(
      width: 340,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: abrir,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 6,
              children: [
                Row(
                  children: [
                    Expanded(child: Text('${canal['nome']}', style: t.titleLarge)),
                    if (canal['status'] != null) Chip(label: Text('${canal['status']}')),
                  ],
                ),
                Text('${canal['titulo']}', style: t.bodySmall),
                const Divider(),
                for (final col in esquema['colecoes'] as List)
                  _LinhaColecao(nome: '${col['nome']}', dados: colecoes[col['id']] as Doc),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LinhaColecao extends StatelessWidget {
  const _LinhaColecao({required this.nome, required this.dados});

  final String nome;
  final Doc dados;

  @override
  Widget build(BuildContext context) {
    final status = dados['status'] as Doc;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 90, child: Text(nome)),
        SizedBox(width: 36, child: Text('${dados['total']}', style: const TextStyle(fontWeight: FontWeight.w600))),
        Expanded(
          child: Text(
            [for (final e in status.entries) '${e.key} ${e.value}'].join(' · '),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
