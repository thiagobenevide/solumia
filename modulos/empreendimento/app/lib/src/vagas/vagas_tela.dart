import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../telas/util.dart';
import 'api_vagas.dart';
import 'curriculos_tela.dart';
import 'mapa_vagas.dart';

const _estados = {
  'nova': ('Novas', Icons.fiber_new_outlined),
  'interesse': ('Interesse', Icons.star_outline),
  'candidatei': ('Candidatei', Icons.send_outlined),
  'descartada': ('Descartadas', Icons.block),
};

/// Seção Vagas do Empreendimento: o Claude pesquisa vagas pelo perfil e cada uma é marcada como
/// interesse, candidatei ou descartada.
class VagasTela extends StatefulWidget {
  const VagasTela({super.key, required this.api});

  final ApiVagas api;

  @override
  State<VagasTela> createState() => _VagasTelaState();
}

class _VagasTelaState extends State<VagasTela> {
  String _filtro = 'nova';
  String? _area;
  String? _modalidade;
  String? _contrato;
  bool _verMapa = false;
  List<String> _gerando = const [];
  Map<String, dynamic> _errosCurriculo = const {};
  final _cidade = TextEditingController();

  @override
  void dispose() {
    _cidade.dispose();
    super.dispose();
  }

  /// Filtros da lista (só no app): modalidade e trecho da cidade/UF, os dois opcionais.
  bool _passa(Doc v) {
    final cidade = _cidade.text.trim().toLowerCase();
    return (_area == null || v['area'] == _area) &&
        (_modalidade == null || v['modalidade'] == _modalidade) &&
        (_contrato == null || v['contrato'] == _contrato) &&
        (cidade.isEmpty || '${v['local'] ?? ''}'.toLowerCase().contains(cidade));
  }

  Future<void> _acao(Future<void> Function() f, Future<void> Function() recarregar) async {
    try {
      await f();
      await recarregar();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) => Sondagem<Doc>(
    carregar: widget.api.listar,
    intervalo: const Duration(seconds: 10),
    construir: (context, d, recarregar) {
      final vagas = [for (final v in d['vagas'] as List) v as Doc];
      final claude = d['claude'] as Doc?;
      final pesquisando = d['pesquisando'] == true;
      final areas = {for (final v in vagas) '${v['area'] ?? ''}'}..remove('');
      final lista = vagas
          .where((v) => v['estado'] == _filtro && _passa(v))
          .toList();
      _gerando = [for (final i in d['gerando_curriculo'] as List? ?? []) '$i'];
      _errosCurriculo = d['erros_curriculo'] as Map<String, dynamic>? ?? const {};
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
                onPressed: pesquisando ? null : () => _acao(widget.api.pesquisar, recarregar),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.tune),
                label: const Text('Perfil'),
                onPressed: () => _perfil(d['perfil'] as Doc, recarregar),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.description_outlined),
                label: const Text('Currículos'),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(builder: (_) => CurriculosTela(api: widget.api)),
                ),
              ),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, icon: Icon(Icons.list), label: Text('Lista')),
                  ButtonSegment(value: true, icon: Icon(Icons.map_outlined), label: Text('Mapa')),
                ],
                selected: {_verMapa},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _verMapa = s.first),
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
                for (final e in _estados.entries)
                  ButtonSegment(
                    value: e.key,
                    icon: Icon(e.value.$2),
                    label: Text('${e.value.$1} (${vagas.where((v) => v['estado'] == e.key).length})'),
                  ),
              ],
              selected: {_filtro},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _filtro = s.first),
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
                for (final m in [null, ...modalidades.keys])
                  ChoiceChip(
                    label: Text(m == null ? 'Todas' : modalidades[m]!),
                    selected: _modalidade == m,
                    onSelected: (_) => setState(() => _modalidade = m),
                  ),
                for (final c in [null, ...contratos.keys])
                  ChoiceChip(
                    label: Text(c == null ? 'Qualquer contrato' : contratos[c]!),
                    selected: _contrato == c,
                    onSelected: (_) => setState(() => _contrato = c),
                  ),
                SizedBox(
                  width: 220,
                  child: TextField(
                    controller: _cidade,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.location_on_outlined),
                      hintText: 'Filtrar por cidade/UF',
                      border: const OutlineInputBorder(),
                      suffixIcon: _cidade.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () => setState(_cidade.clear),
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
      ];
      if (_verMapa) {
        return Column(
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.4),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: cabecalho),
              ),
            ),
            Expanded(child: MapaVagas(vagas: lista, cartao: (v) => _cartao(v, recarregar))),
          ],
        );
      }
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ...cabecalho,
          if (lista.isEmpty)
            Vazio(
              vagas.isEmpty ? 'Nenhuma vaga ainda. Toque em "Pesquisar vagas".' : 'Nada aqui.',
              icone: Icons.work_outline,
            ),
          for (final v in lista) _cartao(v, recarregar),
        ],
      );
    },
  );

  Widget _cartao(Doc v, Future<void> Function() recarregar) {
    final url = '${v['url'] ?? ''}';
    final detalhes = [
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
            Wrap(spacing: 6, runSpacing: 4, children: selosDaVaga(v)),
            if (detalhes.isNotEmpty) Text(detalhes, style: Theme.of(context).textTheme.bodySmall),
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
                _botaoCurriculo(v, recarregar),
                for (final e in _estados.entries)
                  if (e.key != v['estado'])
                    IconButton(
                      tooltip: e.value.$1,
                      icon: Icon(e.value.$2),
                      onPressed: () => _acao(() => widget.api.marcar('${v['id']}', e.key), recarregar),
                    ),
                IconButton(
                  tooltip: 'Remover',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _acao(() => widget.api.remover('${v['id']}'), recarregar),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Gera pelo Claude o currículo da vaga a partir do padrão; depois de gerado, abre o editor.
  Widget _botaoCurriculo(Doc v, Future<void> Function() recarregar) {
    final id = '${v['id']}';
    if (_gerando.contains(id)) {
      return TextButton.icon(
        onPressed: null,
        icon: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        label: Text('Gerando currículo…'),
      );
    }
    final curriculo = v['curriculo'] as String?;
    if (curriculo != null) {
      return TextButton.icon(
        icon: const Icon(Icons.description, size: 18),
        label: const Text('Currículo'),
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => CurriculoTela(api: widget.api, id: curriculo)),
        ),
      );
    }
    final erro = _errosCurriculo[id];
    return Tooltip(
      message: erro == null ? 'Adapta o currículo padrão a esta vaga' : 'Falhou: $erro',
      child: TextButton.icon(
        icon: Icon(erro == null ? Icons.note_add_outlined : Icons.error_outline, size: 18),
        label: const Text('Criar currículo'),
        onPressed: () => _acao(() => widget.api.gerarCurriculo(id), recarregar),
      ),
    );
  }

  Future<void> _perfil(Doc perfil, Future<void> Function() recarregar) async {
    String junto(Object? l) => [for (final x in l as List? ?? []) '$x'].join(', ');
    List<String> separado(TextEditingController c) =>
        [for (final x in c.text.split(',')) if (x.trim().isNotEmpty) x.trim()];
    final areas = TextEditingController(text: junto(perfil['areas']));
    final empresas = TextEditingController(text: junto(perfil['empresas']));
    final cargos = TextEditingController(text: '${perfil['cargos'] ?? ''}');
    final local = TextEditingController(text: '${perfil['local'] ?? ''}');
    final senioridade = TextEditingController(text: '${perfil['senioridade'] ?? ''}');
    final obs = TextEditingController(text: '${perfil['observacoes'] ?? ''}');
    final modos = {for (final m in perfil['modalidades'] as List? ?? []) '$m'};
    final salvar = await showDialog<bool>(
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
                    for (final m in modalidades.entries)
                      FilterChip(
                        label: Text(m.value),
                        selected: modos.contains(m.key),
                        onSelected: (s) => setDialogo(() => s ? modos.add(m.key) : modos.remove(m.key)),
                      ),
                  ],
                ),
                TextField(
                  controller: empresas,
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
    if (salvar != true) return;
    await _acao(
      () => widget.api.salvarPerfil({
        'areas': separado(areas),
        'empresas': separado(empresas),
        'cargos': cargos.text.trim(),
        'local': local.text.trim(),
        'modalidades': modos.toList(),
        'senioridade': senioridade.text.trim(),
        'observacoes': obs.text.trim(),
      }),
      recarregar,
    );
  }
}
