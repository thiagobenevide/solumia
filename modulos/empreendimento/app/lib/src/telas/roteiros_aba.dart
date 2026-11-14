import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../modelos.dart';
import 'episodio/episodio_tela.dart';
import 'util.dart';

/// Biblioteca do vault por canal: resumo, filtro de status e os roteiros para produzir (importa e põe
/// `tudo` na fila). Só dá para escolher roteiro com narração gravada ou que já é episódio.
class RoteirosAba extends StatefulWidget {
  const RoteirosAba({super.key, required this.api});

  final ApiEsteira api;

  @override
  State<RoteirosAba> createState() => _RoteirosAbaState();
}

class _RoteirosAbaState extends State<RoteirosAba> {
  late final Future<List<Canal>> _canais = widget.api.canais();
  String? _canal;
  String _status = '';
  final _escolhidos = <String>{};

  /// Template (`id@N`) escolhido por roteiro, e as versões de template do canal (`vN - nome`).
  final _templates = <String, String>{};
  List<Json> _versoes = [];
  String? _versoesDe;

  static const _statusDoVault = ['rascunho', 'revisado', 'gravado', 'publicado'];

  void _carregarVersoes(String canal) {
    if (_versoesDe == canal) return;
    _versoesDe = canal;
    _versoes = [];
    widget.api
        .templates(canal)
        .then((ts) {
          if (!mounted || _versoesDe != canal) return;
          setState(() => _versoes = [for (final t in ts.cast<Json>()) for (final v in t['versoes'] as List) v as Json]);
        })
        .catchError((Object _) {});
  }

  /// O já escolhido; senão a versão mais nova travada do modo do roteiro; senão a mais nova do modo; senão a primeira.
  String? _padrao(Roteiro r) {
    if (r.template != null) return r.template;
    final doModo = _versoes.where((v) => v['modo'] == r.modo);
    return (doModo.where((v) => v['travado'] == true).firstOrNull ?? doModo.firstOrNull ?? _versoes.firstOrNull)?['ref']
        as String?;
  }

  Widget _seletorTemplate(Roteiro r) {
    final atual = _templates[r.caminho] ?? _padrao(r);
    return DropdownButton<String>(
      isDense: true,
      value: _versoes.any((v) => v['ref'] == atual) ? atual : null,
      hint: const Text('escolher template'),
      items: [
        for (final v in _versoes)
          DropdownMenuItem(
            value: v['ref'] as String,
            child: Text('Template ${v['rotulo']} · ${v['modo']}${v['travado'] == true ? ' 🔒' : ''}'),
          ),
      ],
      onChanged: (ref) {
        if (ref == null) return;
        setState(() => _templates[r.caminho] = ref);
        if (r.ep != null) {
          acaoComAviso(context, () async {
            await widget.api.escolherTemplate(r.ep!, ref);
            return 'Template da produção de ${r.ep}: ${ref.replaceFirst('@', ' v')}';
          });
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _canais,
    builder: (context, s) {
      if (s.hasError) return ErroComRetry(erro: s.error!, tentar: () => setState(() {}));
      final canais = s.data;
      if (canais == null) return const Center(child: CircularProgressIndicator());
      if (canais.isEmpty) return const Vazio('Nenhum canal no vault.');
      final canal = _canal ?? canais.first.id;
      _carregarVersoes(canal);
      return Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                spacing: 8,
                children: [
                  for (final c in canais)
                    ChoiceChip(
                      label: Text('${c.id} · ${c.roteiros}'),
                      selected: canal == c.id,
                      onSelected: (_) => setState(() {
                        _canal = c.id;
                        _escolhidos.clear();
                        _templates.clear();
                      }),
                    ),
                  const SizedBox(width: 8),
                  DropdownButton<String>(
                    value: _status,
                    items: [
                      const DropdownMenuItem(value: '', child: Text('Todos os status')),
                      for (final st in _statusDoVault) DropdownMenuItem(value: st, child: Text(st)),
                    ],
                    onChanged: (v) => setState(() => _status = v ?? ''),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Sondagem<List<Roteiro>>(
              key: ValueKey(canal),
              intervalo: const Duration(seconds: 15),
              carregar: () => widget.api.roteiros(canal),
              construir: (context, todos, _) {
                final roteiros = [
                  for (final r in todos)
                    if (_status.isEmpty || r.status == _status) r,
                ];
                return ListView(
                  padding: const EdgeInsets.only(bottom: 88),
                  children: [
                    _resumo(roteiros),
                    if (roteiros.isEmpty) const Vazio('Nenhum roteiro neste canal.'),
                    for (final r in roteiros) _linha(context, r),
                  ],
                );
              },
            ),
          ),
          if (_escolhidos.isNotEmpty)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: Text('Produzir ${_escolhidos.length} vídeo(s)'),
                  onPressed: _produzir,
                ),
              ),
            ),
        ],
      );
    },
  );

  Widget _resumo(List<Roteiro> rs) {
    final projetos = rs.where((r) => r.ep != null);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          Indicador(
            'Roteiros',
            '${rs.length}',
            sub: '${rs.where((r) => r.formato == '9:16').length} Shorts 9:16',
          ),
          Indicador('Com áudio', '${rs.where((r) => r.audio).length}', sub: 'prontos para a esteira'),
          Indicador('Em projeto', '${projetos.length}', sub: 'já importados'),
          Indicador(
            'Vídeos prontos',
            '${projetos.where((r) => r.prog?.finalPronto ?? false).length}',
            sub: 'final.mp4 exportado',
          ),
          Indicador(
            'Citações com PDF',
            '${rs.fold(0, (n, r) => n + r.citacoes)}',
            sub: 'blocos [!cite] no vault',
          ),
        ],
      ),
    );
  }

  Widget _linha(BuildContext context, Roteiro r) {
    final p = r.prog;
    final pequeno = Theme.of(context).textTheme.bodySmall;
    return Opacity(
      opacity: r.produzivel ? 1 : 0.55,
      child: CheckboxListTile(
        value: _escolhidos.contains(r.caminho),
        onChanged: !r.produzivel || p?.rodando != null
            ? null
            : (v) => setState(() {
                if (!v!) {
                  _escolhidos.remove(r.caminho);
                  return;
                }
                _escolhidos.add(r.caminho);
                final padrao = _padrao(r);
                if (padrao != null) _templates.putIfAbsent(r.caminho, () => padrao);
              }),
        title: Text('${r.rotulo} — ${r.titulo}', maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 4,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                SeloMotor('', rotulo: r.formato == '9:16' ? 'Short · 9:16' : 'Longo · 16:9'),
                r.modoDefinido
                    ? SeloMotor('', rotulo: r.modo == 'apresentador' ? '🎥 Apresentador' : '🎙 Dark')
                    : const SeloMotor('', rotulo: 'modo a definir', corFixa: Colors.amber),
                SeloMotor('', rotulo: r.status.isEmpty ? 'sem status' : r.status),
                r.audio
                    ? SeloMotor('', rotulo: '● áudio ${r.audioMb ?? '?'} MB', corFixa: Colors.green)
                    : const SeloMotor('', rotulo: '○ sem áudio'),
                r.citacoes > 0
                    ? SeloMotor(
                        '',
                        rotulo: '❝ ${r.citacoes} ${r.citacoes == 1 ? 'citação' : 'citações'}',
                        corFixa: Colors.amber,
                      )
                    : const SeloMotor('', rotulo: 'sem citação com PDF'),
                if (_versoes.isNotEmpty && r.produzivel)
                  _seletorTemplate(r)
                else if (_versoes.isEmpty && r.produzivel)
                  const SeloMotor('', rotulo: 'sem template no canal: crie no Estúdio', corFixa: Colors.amber),
              ],
            ),
            if (p != null)
              Row(
                spacing: 8,
                children: [
                  Expanded(child: LinearProgressIndicator(value: p.fracao)),
                  Text(
                    p.finalPronto && p.desatualizado
                        ? '⚠ vídeo desatualizado'
                        : p.finalPronto
                        ? '✓ vídeo pronto'
                        : p.rodando != null
                        ? '${p.rodando}…'
                        : p.erro != null
                        ? 'erro em ${p.erro}'
                        : '${p.feitas}/${p.total} etapas',
                    style: pequeno,
                  ),
                  TextButton(
                    onPressed: () => abrirTela(context, (_) => EpisodioTela(api: widget.api, ep: r.ep!, titulo: r.titulo)),
                    child: Text('abrir ${r.ep}'),
                  ),
                ],
              )
            else
              Text(
                r.audio ? 'Pronto para importar e produzir' : 'Grave e exporte o áudio para liberar',
                style: pequeno,
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _produzir() => acaoComAviso(context, () async {
    final n = await widget.api.produzir(
      _escolhidos.toList(),
      templates: {
        for (final c in _escolhidos) c: ?_templates[c],
      },
    );
    setState(_escolhidos.clear);
    return n == 0 ? 'Já estavam todos na fila.' : '$n episódio(s) na fila de produção.';
  });
}
