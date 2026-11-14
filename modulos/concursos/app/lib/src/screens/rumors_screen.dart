import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../exams_api.dart';
import '../models.dart';

const _phases = {
  'rumor': ('Rumor', Colors.grey),
  'solicitado': ('Solicitado', Colors.blueGrey),
  'autorizado': ('Autorizado', Colors.blue),
  'comissao': ('Comissão formada', Colors.indigo),
  'banca': ('Banca definida', Colors.deepPurple),
  'edital': ('Edital publicado', Colors.green),
};

/// Rumors of IT exams (federal, state and municipal), each with its source. The search is
/// done by Claude Code on the PC; followed ones are rechecked every day and each update becomes a
/// notification.
class RumorsScreen extends StatefulWidget {
  const RumorsScreen({super.key, required this.api});

  final ExamsApi api;

  @override
  State<RumorsScreen> createState() => _RumorsScreenState();
}

class _RumorsScreenState extends State<RumorsScreen> {
  final _query = TextEditingController();
  final _spheres = <String>{};
  var _onlyFollowed = false;
  var _filter = '';

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _research(Future<void> Function() reload) async {
    try {
      await widget.api.researchRumors(_query.text.trim());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pesquisando rumores com o Claude (leva alguns minutos)…')),
        );
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
    await reload();
  }

  bool _passes(Rumor r) {
    if (_onlyFollowed && !r.followed) return false;
    if (_spheres.isNotEmpty && !_spheres.contains(r.sphere)) return false;
    if (_filter.isEmpty) return true;
    final target = '${r.agency} ${r.uf} ${r.cargosTi.join(' ')} ${r.summary}'.toLowerCase();
    return _filter.toLowerCase().split(' ').every(target.contains);
  }

  @override
  Widget build(BuildContext context) => Sondagem<Rumors>(
    intervalo: const Duration(seconds: 10),
    carregar: widget.api.rumors,
    construir: (context, data, reload) {
      final itens = data.itens.where(_passes).toList();
      final topicName = Theme.of(context);
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _query,
                    onChanged: (t) => setState(() => _filter = t.trim()),
                    onSubmitted: (_) => _research(reload),
                    decoration: const InputDecoration(
                      isDense: true,
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Filtrar ou pesquisar (órgão, estado, cargo…)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                data.researching
                    ? const Padding(
                        padding: EdgeInsets.all(8),
                        child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
                      )
                    : FilledButton.icon(
                        onPressed: () => _research(reload),
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
                      selected: _spheres.contains(e),
                      onSelected: (s) => setState(() => s ? _spheres.add(e) : _spheres.remove(e)),
                    ),
                  ),
                FilterChip(
                  avatar: const Icon(Icons.notifications_active_outlined, size: 16),
                  label: const Text('Acompanhando'),
                  selected: _onlyFollowed,
                  onSelected: (s) => setState(() => _onlyFollowed = s),
                ),
                const SizedBox(width: 12),
                Text(
                  [
                    '${itens.length} de ${data.itens.length}',
                    if (data.searchedAt != null) 'última busca ${dataBr(data.searchedAt, short: true)} ${data.searchedAt!.substring(11, 16)}',
                  ].join(' · '),
                  style: topicName.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (data.searchError.isNotEmpty)
            ListTile(dense: true, leading: const Icon(Icons.error_outline), title: Text(data.searchError)),
          Expanded(
            child: itens.isEmpty
                ? Center(
                    child: Text(
                      data.itens.isEmpty
                          ? 'Nenhum rumor ainda. Toque em "Buscar rumores" para o Claude pesquisar.'
                          : 'Nada com esse filtro. "Buscar rumores" pesquisa o termo na internet.',
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                    itemCount: itens.length,
                    itemBuilder: (context, i) => _RumorCard(
                      rumor: itens[i],
                      onFollow: (sim) async {
                        await widget.api.followRumor(itens[i].id, sim);
                        await reload();
                      },
                    ),
                  ),
          ),
        ],
      );
    },
  );
}

class _RumorCard extends StatelessWidget {
  const _RumorCard({required this.rumor, required this.onFollow});

  final Rumor rumor;
  final Future<void> Function(bool) onFollow;

  @override
  Widget build(BuildContext context) {
    final topicName = Theme.of(context);
    final r = rumor;
    final (phase, color) = _phases[r.phase] ?? ('Rumor', Colors.grey);
    final novas = r.updates.reversed.toList();
    return Card(
      child: ExpansionTile(
        shape: const Border(),
        leading: CircleAvatar(backgroundColor: color.withValues(alpha: 0.2), child: Icon(Icons.campaign_outlined, color: color)),
        title: Text('${r.agency}${r.uf.isEmpty ? '' : ' · ${r.uf}'}', style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _Stamp(phase, color),
                if (r.sphere.isNotEmpty) _Stamp(r.sphere, topicName.colorScheme.secondary),
                if (r.plannedOpenings > 0) _Stamp('${r.plannedOpenings} vagas previstas', topicName.colorScheme.tertiary),
                if (r.newsDate.isNotEmpty) _Stamp('notícia ${dataBr(r.newsDate)}', topicName.colorScheme.outline),
                if (novas.isNotEmpty) _Stamp('${novas.length} novidade(s)', Colors.orange),
              ],
            ),
            if (r.cargosTi.isNotEmpty) ...[const SizedBox(height: 4), Text(r.cargosTi.join(' · '), style: topicName.textTheme.bodySmall)],
          ],
        ),
        trailing: IconButton(
          tooltip: r.followed ? 'Parar de acompanhar' : 'Acompanhar (notifica cada novidade)',
          icon: Icon(
            r.followed ? Icons.notifications_active : Icons.notifications_none,
            color: r.followed ? Colors.orange : null,
          ),
          onPressed: () => onFollow(!r.followed),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (r.summary.isNotEmpty) Text(r.summary),
          if (novas.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('Novidades', style: topicName.textTheme.titleSmall),
            for (final n in novas)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.fiber_new_outlined, color: Colors.orange),
                title: Text(n.text),
                subtitle: Text('${dataBr(n.registeredAt)} · ${n.source.name.isEmpty ? n.source.url : n.source.name}'),
                onTap: n.source.url.isEmpty ? null : () => abrirLink(context, n.source.url),
              ),
          ],
          const SizedBox(height: 10),
          Text('Fontes', style: topicName.textTheme.titleSmall),
          Wrap(
            spacing: 6,
            children: [
              for (final f in r.sources)
                ActionChip(
                  avatar: const Icon(Icons.link, size: 16),
                  label: Text(f.name.isEmpty ? Uri.tryParse(f.url)?.host ?? f.url : f.name),
                  onPressed: () => abrirLink(context, f.url),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Stamp extends StatelessWidget {
  const _Stamp(this.text, this.color);

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: color.withValues(alpha: 0.6)),
    ),
    child: Text(text, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
  );
}
