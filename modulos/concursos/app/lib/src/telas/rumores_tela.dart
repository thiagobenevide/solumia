import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_concursos.dart';
import '../modelos.dart';

const _fases = {
  'rumor': ('Rumor', Colors.grey),
  'solicitado': ('Solicitado', Colors.blueGrey),
  'autorizado': ('Autorizado', Colors.blue),
  'comissao': ('Comissão formada', Colors.indigo),
  'banca': ('Banca definida', Colors.deepPurple),
  'edital': ('Edital publicado', Colors.green),
};

/// Rumores de concursos de TI (federais, estaduais e municipais), cada um com a fonte. A busca é
/// feita pelo Claude Code no PC; os acompanhados são reverificados todo dia e cada novidade vira
/// notificação.
class RumoresTela extends StatefulWidget {
  const RumoresTela({super.key, required this.api});

  final ApiConcursos api;

  @override
  State<RumoresTela> createState() => _RumoresTelaState();
}

class _RumoresTelaState extends State<RumoresTela> {
  final _consulta = TextEditingController();
  final _esferas = <String>{};
  var _soAcompanhados = false;
  var _filtro = '';

  @override
  void dispose() {
    _consulta.dispose();
    super.dispose();
  }

  Future<void> _pesquisar(Future<void> Function() recarregar) async {
    try {
      await widget.api.pesquisarRumores(_consulta.text.trim());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pesquisando rumores com o Claude (leva alguns minutos)…')),
        );
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
    await recarregar();
  }

  bool _passa(Rumor r) {
    if (_soAcompanhados && !r.acompanhado) return false;
    if (_esferas.isNotEmpty && !_esferas.contains(r.esfera)) return false;
    if (_filtro.isEmpty) return true;
    final alvo = '${r.orgao} ${r.uf} ${r.cargosTi.join(' ')} ${r.resumo}'.toLowerCase();
    return _filtro.toLowerCase().split(' ').every(alvo.contains);
  }

  @override
  Widget build(BuildContext context) => Sondagem<Rumores>(
    intervalo: const Duration(seconds: 10),
    carregar: widget.api.rumores,
    construir: (context, dados, recarregar) {
      final itens = dados.itens.where(_passa).toList();
      final tema = Theme.of(context);
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _consulta,
                    onChanged: (t) => setState(() => _filtro = t.trim()),
                    onSubmitted: (_) => _pesquisar(recarregar),
                    decoration: const InputDecoration(
                      isDense: true,
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Filtrar ou pesquisar (órgão, estado, cargo…)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                dados.pesquisando
                    ? const Padding(
                        padding: EdgeInsets.all(8),
                        child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
                      )
                    : FilledButton.icon(
                        onPressed: () => _pesquisar(recarregar),
                        icon: const Icon(Icons.travel_explore),
                        label: const Text('Buscar rumores'),
                      ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                for (final e in const ['federal', 'estadual', 'municipal'])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      label: Text('${e[0].toUpperCase()}${e.substring(1)}'),
                      selected: _esferas.contains(e),
                      onSelected: (s) => setState(() => s ? _esferas.add(e) : _esferas.remove(e)),
                    ),
                  ),
                FilterChip(
                  avatar: const Icon(Icons.notifications_active_outlined, size: 16),
                  label: const Text('Acompanhando'),
                  selected: _soAcompanhados,
                  onSelected: (s) => setState(() => _soAcompanhados = s),
                ),
                const SizedBox(width: 12),
                Text(
                  [
                    '${itens.length} de ${dados.itens.length}',
                    if (dados.buscaEm != null) 'última busca ${dataBr(dados.buscaEm, curta: true)} ${dados.buscaEm!.substring(11, 16)}',
                  ].join(' · '),
                  style: tema.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (dados.buscaErro.isNotEmpty)
            ListTile(dense: true, leading: const Icon(Icons.error_outline), title: Text(dados.buscaErro)),
          Expanded(
            child: itens.isEmpty
                ? Center(
                    child: Text(
                      dados.itens.isEmpty
                          ? 'Nenhum rumor ainda. Toque em "Buscar rumores" para o Claude pesquisar.'
                          : 'Nada com esse filtro. "Buscar rumores" pesquisa o termo na internet.',
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                    itemCount: itens.length,
                    itemBuilder: (context, i) => _CartaoRumor(
                      rumor: itens[i],
                      aoAcompanhar: (sim) async {
                        await widget.api.acompanharRumor(itens[i].id, sim);
                        await recarregar();
                      },
                    ),
                  ),
          ),
        ],
      );
    },
  );
}

class _CartaoRumor extends StatelessWidget {
  const _CartaoRumor({required this.rumor, required this.aoAcompanhar});

  final Rumor rumor;
  final Future<void> Function(bool) aoAcompanhar;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final r = rumor;
    final (fase, cor) = _fases[r.fase] ?? ('Rumor', Colors.grey);
    final novas = r.novidades.reversed.toList();
    return Card(
      child: ExpansionTile(
        shape: const Border(),
        leading: CircleAvatar(backgroundColor: cor.withValues(alpha: 0.2), child: Icon(Icons.campaign_outlined, color: cor)),
        title: Text('${r.orgao}${r.uf.isEmpty ? '' : ' · ${r.uf}'}', style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _Selo(fase, cor),
                if (r.esfera.isNotEmpty) _Selo(r.esfera, tema.colorScheme.secondary),
                if (r.vagasPrevistas > 0) _Selo('${r.vagasPrevistas} vagas previstas', tema.colorScheme.tertiary),
                if (r.dataNoticia.isNotEmpty) _Selo('notícia ${dataBr(r.dataNoticia)}', tema.colorScheme.outline),
                if (novas.isNotEmpty) _Selo('${novas.length} novidade(s)', Colors.orange),
              ],
            ),
            if (r.cargosTi.isNotEmpty) ...[const SizedBox(height: 4), Text(r.cargosTi.join(' · '), style: tema.textTheme.bodySmall)],
          ],
        ),
        trailing: IconButton(
          tooltip: r.acompanhado ? 'Parar de acompanhar' : 'Acompanhar (notifica cada novidade)',
          icon: Icon(
            r.acompanhado ? Icons.notifications_active : Icons.notifications_none,
            color: r.acompanhado ? Colors.orange : null,
          ),
          onPressed: () => aoAcompanhar(!r.acompanhado),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (r.resumo.isNotEmpty) Text(r.resumo),
          if (novas.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('Novidades', style: tema.textTheme.titleSmall),
            for (final n in novas)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.fiber_new_outlined, color: Colors.orange),
                title: Text(n.texto),
                subtitle: Text('${dataBr(n.registradaEm)} · ${n.fonte.nome.isEmpty ? n.fonte.url : n.fonte.nome}'),
                onTap: n.fonte.url.isEmpty ? null : () => abrirLink(context, n.fonte.url),
              ),
          ],
          const SizedBox(height: 10),
          Text('Fontes', style: tema.textTheme.titleSmall),
          Wrap(
            spacing: 6,
            children: [
              for (final f in r.fontes)
                ActionChip(
                  avatar: const Icon(Icons.link, size: 16),
                  label: Text(f.nome.isEmpty ? Uri.tryParse(f.url)?.host ?? f.url : f.nome),
                  onPressed: () => abrirLink(context, f.url),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Selo extends StatelessWidget {
  const _Selo(this.texto, this.cor);

  final String texto;
  final Color cor;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: cor.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: cor.withValues(alpha: 0.6)),
    ),
    child: Text(texto, style: TextStyle(fontSize: 11, color: cor, fontWeight: FontWeight.w600)),
  );
}
