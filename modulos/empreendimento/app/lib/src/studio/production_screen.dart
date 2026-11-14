import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../models.dart';
import '../screens/episode/cuts_tab.dart';
import '../screens/episode/final_video.dart';
import '../screens/util.dart';
import 'timeline.dart';
import 'marking_screen.dart';
import 'cut_screen.dart';

const _scenes = [
  'contador', 'barras_comparacao', 'versus', 'passo_a_passo', 'lista_itens', 'linha_do_tempo', 'citacao_estudo',
  'conceito_icone', 'pergunta_destaque', 'titulo_capitulo', 'frase_destaque', 'cta', 'midia', //
];

/// One Studio production (Flow B): gate 1 (cut) → produce (style + formats) → scene map (optional adjustment)
/// → final video of each format with a report (final gate).
class ProductionScreen extends StatefulWidget {
  const ProductionScreen({super.key, required this.api, required this.ep, required this.styles});

  final ApiEsteira api;
  final String ep;
  final List<Json> styles;

  @override
  State<ProductionScreen> createState() => _ProductionScreenState();
}

class _ProductionScreenState extends State<ProductionScreen> {
  String? _style;
  final Set<String> _formats = {'16:9', '9:16'};
  final Map<String, String> _intensidade = {}; // only in this production; empty = the style's

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Estúdio · ${widget.ep}')),
    body: Sondagem<Json>(
      intervalo: const Duration(seconds: 5),
      carregar: () => widget.api.studioProduction(widget.ep),
      construir: (context, p, recarregar) {
        final ap = p['aprovacoes'] as Json;
        final cutOk = (ap['corte'] as Json?)?['aprovado'] == true;
        final scenes = [for (final c in p['cenas'] as List) c as Json];
        final formats = p['formatos'] as Json;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _Gate(
              numero: 1,
              titulo: 'Corte do áudio',
              done: cutOk,
              texto: _textCut(p['corte'] as Json? ?? {}),
              actions: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.content_cut),
                  label: const Text('Tomadas (texto)'),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                        appBar: AppBar(title: Text('Corte · ${widget.ep}')),
                        body: CutsTab(api: widget.api, ep: widget.ep),
                      ),
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.graphic_eq),
                  label: const Text('Cortar pelo som'),
                  onPressed: () => actionWithWarning(context, () async {
                    await widget.api.cutBySound(widget.ep);
                    return 'Corte pelo som na fila';
                  }),
                ),
                if ((p['corte'] as Json?)?['feito'] == true)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.call_split),
                    label: const Text('Emendas'),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(builder: (_) => CutScreen(api: widget.api, ep: widget.ep)),
                    ),
                  ),
                FilledButton.icon(
                  icon: Icon(cutOk ? Icons.undo : Icons.check),
                  label: Text(cutOk ? 'Reabrir corte' : 'Aprovar corte'),
                  onPressed: () => actionWithWarning(context, () async {
                    await widget.api.approveGate(widget.ep, 'corte', !cutOk);
                    await recarregar();
                    return cutOk ? 'Corte reaberto' : 'Corte aprovado';
                  }),
                ),
              ],
            ),
            _Gate(
              numero: 2,
              titulo: 'Produzir',
              done: p['mapa'] != null,
              texto: '${(p['apontamento'] as Json?)?['confirmado'] == true ? 'Apontamento confirmado. ' : ''}'
                  'Marque no roteiro as cenas que você quer; a IA local dirige o resto (frase → cena do estilo), compila, renderiza na GPU, acerta o áudio (−14 LUFS) e '
                  'confere os quadros. Acompanhe em Fila e Processos.\n'
                  '${p['camera'] != null ? 'Câmera: pronta — estilos de apresentador alternam câmera cheia, tela dividida e B-roll.' : 'Sem vídeo da câmera: só estilos dark (o vídeo entra na importação do episódio em modo apresentador).'}',
              actions: [
                DropdownButton<String>(
                  hint: const Text('template do canal'),
                  value: widget.styles.any((e) => e['ref'] == (_style ??= p['template'] as String?)) ? _style : null,
                  items: [
                    for (final e in widget.styles)
                      DropdownMenuItem(
                        value: e['ref'] as String,
                        child: Text('Template ${e['rotulo']} · ${e['modo']}${e['travado'] == true ? ' 🔒' : ''}'),
                      ),
                  ],
                  onChanged: (v) => setState(() => _style = v),
                ),
                for (final MapEntry(key: axis, value: label) in const {'sfx': 'Som', 'motion': 'Motion', 'efeitos': 'Efeitos'}.entries)
                  DropdownButton<String>(
                    value: _intensidade[axis] ?? '',
                    items: [
                      DropdownMenuItem(value: '', child: Text('$label: do estilo')),
                      for (final MapEntry(:key, :value) in const {'baixa': 'baixa', 'media': 'média', 'alta': 'alta'}.entries)
                        DropdownMenuItem(value: key, child: Text('$label: $value')),
                    ],
                    onChanged: (v) => setState(() => (v == null || v.isEmpty) ? _intensidade.remove(axis) : _intensidade[axis] = v),
                  ),
                for (final f in ['16:9', '9:16'])
                  FilterChip(
                    label: Text(f),
                    selected: _formats.contains(f),
                    onSelected: (s) => setState(() => s ? _formats.add(f) : _formats.remove(f)),
                  ),
                FilledButton.icon(
                  icon: const Icon(Icons.edit_note),
                  label: const Text('Apontar no roteiro e produzir'),
                  onPressed: !cutOk || _formats.isEmpty
                      ? null
                      : () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => MarkingScreen(
                              api: widget.api,
                              ep: widget.ep,
                              produce: {'estilo': _style ?? '', 'formatos': _formats.toList(), 'intensidade': _intensidade},
                            ),
                          ),
                        ),
                ),
                if (p['mapa'] != null)
                  OutlinedButton(
                    onPressed: () => actionWithWarning(context, () async {
                      await widget.api.produceStudio(
                        widget.ep,
                        estilo: _style ?? '',
                        formats: _formats.toList(),
                        stages: const ['compilar', 'render', 'audio', 'verificar'],
                        intensidade: _intensidade,
                      );
                      return 'Renderizando de novo com o mapa atual';
                    }),
                    child: const Text('Só renderizar (mantém o mapa)'),
                  ),
              ],
            ),
            if (p['mapa'] != null)
              _Gate(
                numero: 3,
                titulo: 'Mapa de cenas',
                done: (ap['mapa'] as Json?)?['aprovado'] == true,
                texto: 'Ritmo ${p['ritmo']} · modo ${p['modo']} (do roteiro). Decisões: ${(p['mapa'] as Json)['decisoes']}. '
                    'Toque numa cena para trocar: a troca fica e ensina a bancada. Depois, "Só renderizar".'
                    '${_warningsRhythm(p['mapa'] as Json)}',
                actions: [
                  FilledButton.tonal(
                    onPressed: () => widget.api.approveGate(widget.ep, 'mapa', true).then((_) => recarregar()),
                    child: const Text('Aprovar mapa'),
                  ),
                ],
                child: p['direcao'] == 'blocos'
                    ? Timeline(
                        api: widget.api,
                        ep: widget.ep,
                        blocks: [for (final b in (p['blocos'] as List?) ?? const []) b as Json],
                        scenes: scenes,
                        hasRender: formats.values.any((f) => (f as Json)['render'] == true),
                        recarregar: recarregar,
                      )
                    : Card(
                  child: SizedBox(
                    height: 320,
                    child: ListView(
                      children: [
                        for (final c in scenes)
                          ListTile(
                            dense: true,
                            leading: Text(_time(c['t'] as num)),
                            title: Text('${c['cena']}${c['titulo'] != '' ? ' · ${c['titulo']}' : ''}'),
                            subtitle: Text('${c['frase']}', maxLines: 1, overflow: TextOverflow.ellipsis),
                            trailing: Text(c['manual'] == true ? 'manual' : '${c['por']}'),
                            onTap: () => _edit(c, recarregar),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            for (final f in formats.entries)
              _Final(api: widget.api, ep: widget.ep, format: f.key, dados: f.value as Json, approvals: ap, recarregar: recarregar),
          ],
        );
      },
    ),
  );

  static String _time(num s) => '${s ~/ 60}:${(s % 60).floor().toString().padLeft(2, '0')}';

  Future<void> _edit(Json c, Future<void> Function() recarregar) async {
    var scene = c['cena'] as String;
    final titulo = TextEditingController(text: '${c['titulo']}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text('Cena ${c['id']}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${c['frase']}'),
              const SizedBox(height: 12),
              DropdownButton<String>(
                value: scene,
                isExpanded: true,
                // direction per block: the code's 5 candidates first (the swap teaches the bench), then the rest
                items: [
                  for (final x in {...((c['candidatas'] as List?) ?? const []).map((e) => '$e'), scene, ..._scenes})
                    DropdownMenuItem(value: x, child: Text(x)),
                ],
                onChanged: (v) => set(() => scene = v ?? scene),
              ),
              TextField(controller: titulo, decoration: const InputDecoration(labelText: 'Título')),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Salvar')),
          ],
        ),
      ),
    );
    if (ok == true) {
      await widget.api.editScene(widget.ep, c['id'] as int, {'cena': scene, 'titulo': titulo.text, 'valores': c['valores']});
      await recarregar();
    }
    titulo.dispose();
  }
}

String _textCut(Json c) {
  const base = '1) Tomadas: a esteira escolhe a melhor leitura de cada frase. 2) Som: vícios, respirações e pausas saem; '
      'revise as emendas e reverta o que não ficou bom. Obrigatório.';
  if (c['feito'] != true) return base;
  String s(num v) => v.toStringAsFixed(1).replaceAll('.', ',');
  return '$base\n${s(c['duracao_antes'] as num)} s → ${s(c['duracao'] as num)} s · ${c['emendas']} emendas · '
      '${c['sumidas']} trecho(s) a conferir · ${c['repeticoes']} repetição(ões)${c['atualizado'] == true ? '' : ' · refazendo…'}';
}

class _Gate extends StatelessWidget {
  const _Gate({
    required this.numero,
    required this.titulo,
    required this.done,
    required this.texto,
    required this.actions,
    this.child,
  });

  final int numero;
  final String titulo;
  final bool done;
  final String texto;
  final List<Widget> actions;
  final Widget? child;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 16),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(radius: 14, child: done ? const Icon(Icons.check, size: 16) : Text('$numero')),
              const SizedBox(width: 12),
              Text(titulo, style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 8),
          Text(texto),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: actions),
          if (child != null) ...[const SizedBox(height: 12), child!],
        ],
      ),
    ),
  );
}

class _Final extends StatelessWidget {
  const _Final({
    required this.api,
    required this.ep,
    required this.format,
    required this.dados,
    required this.approvals,
    required this.recarregar,
  });

  final ApiEsteira api;
  final String ep;
  final String format;
  final Json dados;
  final Json approvals;
  final Future<void> Function() recarregar;

  @override
  Widget build(BuildContext context) {
    final rel = dados['relatorio'] as Json?;
    final gate = 'final_$format';
    final approved = (approvals[gate] as Json?)?['aprovado'] == true;
    final base = 'arq/$ep/estudio/$format';
    return _Gate(
      numero: 4,
      titulo: 'Vídeo final ${format.replaceAll('x', ':')}',
      done: approved,
      texto: rel == null
          ? (dados['final'] == true ? 'Conferindo…' : 'Em produção (compilado: ${dados['compilado']}, render: ${dados['render']}).')
          : '${rel['lufs']} LUFS · pico ${rel['pico']} dBTP · ${rel['cenas']} cenas · ${rel['sfx_por_s']} efeitos/s · '
                'motion ${((rel['takeover'] as num) * 100).round()}% do tempo · '
                '${(rel['visao'] as List).isEmpty ? 'nenhum defeito visual' : '${(rel['visao'] as List).length} quadro(s) com defeito'}',
      actions: [
        if (dados['final'] == true) ...[
          FilledButton.icon(
            icon: Icon(approved ? Icons.undo : Icons.verified),
            label: Text(approved ? 'Reabrir' : 'Aprovar vídeo'),
            onPressed: () => api.approveGate(ep, gate, !approved).then((_) => recarregar()),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.download),
            label: const Text('Baixar'),
            onPressed: () => openUrl(context, api.arquivo('$base/final.mp4')),
          ),
        ],
      ],
      child: dados['final'] == true
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 520),
                  // light preview (540p) to play fast from any network; "Baixar" still delivers the full final
                  child: VideoFinal(
                    url: api.arquivo('$base/${dados['previa'] == true ? 'previa' : 'final'}.mp4'),
                    vertical: format == '9x16',
                  ),
                ),
                if (dados['folha'] == true) ...[
                  const SizedBox(height: 12),
                  Image.network(api.arquivo('$base/folha.jpg')),
                ],
                if (rel != null)
                  for (final v in (rel['visao'] as List).cast<Json>())
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.warning_amber),
                      title: Text('Cena ${v['cena']} (${v['tipo']}): ${(v['defeitos'] as List).join(', ')}'),
                    ),
              ],
            )
          : null,
    );
  }
}

/// Warnings from the map's rhythm check (long/short profile), in lines for the gate text.
String _warningsRhythm(Json map) {
  final r = map['ritmo'] as Json?;
  final warnings = (r?['avisos'] as List?) ?? const [];
  if (warnings.isEmpty) return '';
  return '\nConferência do ritmo ${r!['perfil']}:\n${warnings.take(8).map((a) => '• ${(a as Json)['t']} s: ${a['texto']}').join('\n')}';
}
