import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../screens/util.dart';
import 'jobs_api.dart';
import 'resumes_screen.dart';
import 'jobs_map.dart';

const _states = {
  'nova': ('Novas', Icons.fiber_new_outlined),
  'interesse': ('Interesse', Icons.star_outline),
  'candidatei': ('Candidatei', Icons.send_outlined),
  'descartada': ('Descartadas', Icons.block),
};

/// Empreendimento Jobs section: Claude searches jobs by the profile and each one is marked as
/// interested, applied or discarded.
class JobsScreen extends StatefulWidget {
  const JobsScreen({super.key, required this.api});

  final ApiJobs api;

  @override
  State<JobsScreen> createState() => _JobsScreenState();
}

class _JobsScreenState extends State<JobsScreen> {
  String _filter = 'nova';
  String? _area;
  String? _modality;
  String? _contract;
  bool _showMap = false;
  List<String> _generating = const [];
  Map<String, dynamic> _resumeErrors = const {};
  final _city = TextEditingController();

  @override
  void dispose() {
    _city.dispose();
    super.dispose();
  }

  /// List filters (app only): work mode and part of the city/state, both optional.
  bool _passa(Doc v) {
    final city = _city.text.trim().toLowerCase();
    return (_area == null || v['area'] == _area) &&
        (_modality == null || v['modalidade'] == _modality) &&
        (_contract == null || v['contrato'] == _contract) &&
        (city.isEmpty || '${v['local'] ?? ''}'.toLowerCase().contains(city));
  }

  Future<void> _action(Future<void> Function() f, Future<void> Function() recarregar) async {
    try {
      await f();
      await recarregar();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) => Sondagem<Doc>(
    carregar: widget.api.listAll,
    intervalo: const Duration(seconds: 10),
    construir: (context, d, recarregar) {
      final slots = [for (final v in d['vagas'] as List) v as Doc];
      final claude = d['claude'] as Doc?;
      final pesquisando = d['pesquisando'] == true;
      final areas = {for (final v in slots) '${v['area'] ?? ''}'}..remove('');
      final list = slots
          .where((v) => v['estado'] == _filter && _passa(v))
          .toList();
      _generating = [for (final i in d['gerando_curriculo'] as List? ?? []) '$i'];
      _resumeErrors = d['erros_curriculo'] as Map<String, dynamic>? ?? const {};
      final cabecalho = <Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                icon: pesquisando
                    ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.travel_explore),
                label: Text(pesquisando ? 'Pesquisando ${d['progresso'] ?? ''}' : 'Pesquisar vagas'),
                onPressed: pesquisando ? null : () => _action(widget.api.runSearch, recarregar),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.tune),
                label: const Text('Perfil'),
                onPressed: () => _profile(d['perfil'] as Doc, recarregar),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.description_outlined),
                label: const Text('Currículos'),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(builder: (_) => ResumesScreen(api: widget.api)),
                ),
              ),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, icon: Icon(Icons.list), label: Text('Lista')),
                  ButtonSegment(value: true, icon: Icon(Icons.map_outlined), label: Text('Mapa')),
                ],
                selected: {_showMap},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _showMap = s.first),
              ),
            ],
          ),
          if (claude != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                (claude['erro'] as String? ?? '').isNotEmpty
                    ? 'Última pesquisa falhou: ${claude['erro']}'
                    : 'Última pesquisa: ${claude['achadas']} vaga(s) em ${'${claude['em']}'.split('T').first}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<String>(
              segments: [
                for (final e in _states.entries)
                  ButtonSegment(
                    value: e.key,
                    icon: Icon(e.value.$2),
                    label: Text('${e.value.$1} (${slots.where((v) => v['estado'] == e.key).length})'),
                  ),
              ],
              selected: {_filter},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _filter = s.first),
            ),
          ),
          if (areas.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final a in [null, ...areas])
                    ChoiceChip(
                      label: Text(a ?? 'Todas as áreas'),
                      selected: _area == a,
                      onSelected: (_) => setState(() => _area = a),
                    ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final m in [null, ...modalities.keys])
                  ChoiceChip(
                    label: Text(m == null ? 'Todas' : modalities[m]!),
                    selected: _modality == m,
                    onSelected: (_) => setState(() => _modality = m),
                  ),
                for (final c in [null, ...contracts.keys])
                  ChoiceChip(
                    label: Text(c == null ? 'Qualquer contrato' : contracts[c]!),
                    selected: _contract == c,
                    onSelected: (_) => setState(() => _contract = c),
                  ),
                SizedBox(
                  width: 220,
                  child: TextField(
                    controller: _city,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.location_on_outlined),
                      hintText: 'Filtrar por cidade/UF',
                      border: const OutlineInputBorder(),
                      suffixIcon: _city.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () => setState(_city.clear),
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
      ];
      if (_showMap) {
        return Column(
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.4),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: cabecalho),
              ),
            ),
            Expanded(child: JobsMap(slots: list, card: (v) => _card(v, recarregar))),
          ],
        );
      }
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ...cabecalho,
          if (list.isEmpty)
            Empty(
              slots.isEmpty ? 'Nenhuma vaga ainda. Toque em "Pesquisar vagas".' : 'Nada aqui.',
              icone: Icons.work_outline,
            ),
          for (final v in list) _card(v, recarregar),
        ],
      );
    },
  );

  Widget _card(Doc v, Future<void> Function() recarregar) {
    final url = '${v['url'] ?? ''}';
    final details = [
      v['empresa'],
      v['local'],
      v['salario'],
      v['senioridade'],
      v['publicada_em'],
      v['fonte'],
    ].where((s) => s != null && '$s'.isNotEmpty).join(' · ');
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 4,
          children: [
            Text('${v['titulo']}', style: Theme.of(context).textTheme.titleMedium),
            Wrap(spacing: 6, runSpacing: 4, children: slotPills(v)),
            if (details.isNotEmpty) Text(details, style: Theme.of(context).textTheme.bodySmall),
            if ('${v['resumo'] ?? ''}'.isNotEmpty) Text('${v['resumo']}'),
            Wrap(
              spacing: 4,
              children: [
                if (url.isNotEmpty)
                  TextButton.icon(
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('Abrir'),
                    onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
                  ),
                _resumeButton(v, recarregar),
                for (final e in _states.entries)
                  if (e.key != v['estado'])
                    IconButton(
                      tooltip: e.value.$1,
                      icon: Icon(e.value.$2),
                      onPressed: () => _action(() => widget.api.mark('${v['id']}', e.key), recarregar),
                    ),
                IconButton(
                  tooltip: 'Remover',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _action(() => widget.api.remove('${v['id']}'), recarregar),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Generates the job's résumé through Claude from the default one; once generated, opens the editor.
  Widget _resumeButton(Doc v, Future<void> Function() recarregar) {
    final id = '${v['id']}';
    if (_generating.contains(id)) {
      return TextButton.icon(
        onPressed: null,
        icon: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        label: Text('Gerando currículo…'),
      );
    }
    final resume = v['curriculo'] as String?;
    if (resume != null) {
      return TextButton.icon(
        icon: const Icon(Icons.description, size: 18),
        label: const Text('Currículo'),
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => ResumeScreen(api: widget.api, id: resume)),
        ),
      );
    }
    final erro = _resumeErrors[id];
    return Tooltip(
      message: erro == null ? 'Adapta o currículo padrão a esta vaga' : 'Falhou: $erro',
      child: TextButton.icon(
        icon: Icon(erro == null ? Icons.note_add_outlined : Icons.error_outline, size: 18),
        label: const Text('Criar currículo'),
        onPressed: () => _action(() => widget.api.generateResume(id), recarregar),
      ),
    );
  }

  Future<void> _profile(Doc profile, Future<void> Function() recarregar) async {
    String junto(Object? l) => [for (final x in l as List? ?? []) '$x'].join(', ');
    List<String> separado(TextEditingController c) =>
        [for (final x in c.text.split(',')) if (x.trim().isNotEmpty) x.trim()];
    final areas = TextEditingController(text: junto(profile['areas']));
    final companies = TextEditingController(text: junto(profile['empresas']));
    final cargos = TextEditingController(text: '${profile['cargos'] ?? ''}');
    final local = TextEditingController(text: '${profile['local'] ?? ''}');
    final senioridade = TextEditingController(text: '${profile['senioridade'] ?? ''}');
    final obs = TextEditingController(text: '${profile['observacoes'] ?? ''}');
    final modes = {for (final m in profile['modalidades'] as List? ?? []) '$m'};
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogo) => AlertDialog(
          title: const Text('Perfil da busca'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 12,
              children: [
                TextField(
                  controller: areas,
                  decoration: const InputDecoration(
                    labelText: 'Áreas (separadas por vírgula)',
                    helperText: 'cada área é pesquisada no LinkedIn, plataformas, sites e agregadores',
                    helperMaxLines: 2,
                  ),
                ),
                TextField(
                  controller: cargos,
                  maxLines: null,
                  decoration: const InputDecoration(labelText: 'Cargos (separados por vírgula)'),
                ),
                TextField(controller: local, decoration: const InputDecoration(
                    labelText: 'Cidade/UF (opcional)',
                    helperText: 'vazio: presenciais e híbridas do Brasil todo',
                  ),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final m in modalities.entries)
                      FilterChip(
                        label: Text(m.value),
                        selected: modes.contains(m.key),
                        onSelected: (s) => setDialogo(() => s ? modes.add(m.key) : modes.remove(m.key)),
                      ),
                  ],
                ),
                TextField(
                  controller: companies,
                  maxLines: null,
                  decoration: const InputDecoration(
                    labelText: 'Empresas para acompanhar (vírgula)',
                    helperText: 'o Claude abre o site de carreiras de cada uma',
                  ),
                ),
                TextField(
                  controller: senioridade,
                  decoration: const InputDecoration(labelText: 'Senioridade (júnior, pleno…)'),
                ),
                TextField(
                  controller: obs,
                  maxLines: null,
                  decoration: const InputDecoration(labelText: 'Observações (stack, salário mínimo…)'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Salvar')),
          ],
        ),
      ),
    );
    if (save != true) return;
    await _action(
      () => widget.api.saveProfile({
        'areas': separado(areas),
        'empresas': separado(companies),
        'cargos': cargos.text.trim(),
        'local': local.text.trim(),
        'modalidades': modes.toList(),
        'senioridade': senioridade.text.trim(),
        'observacoes': obs.text.trim(),
      }),
      recarregar,
    );
  }
}
