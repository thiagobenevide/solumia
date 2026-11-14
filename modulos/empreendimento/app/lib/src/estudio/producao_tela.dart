import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../modelos.dart';
import '../telas/episodio/cortes_aba.dart';
import '../telas/episodio/video_final.dart';
import '../telas/util.dart';
import 'linha_tempo.dart';
import 'apontamento_tela.dart';
import 'corte_tela.dart';

const _cenas = [
  'contador', 'barras_comparacao', 'versus', 'passo_a_passo', 'lista_itens', 'linha_do_tempo', 'citacao_estudo',
  'conceito_icone', 'pergunta_destaque', 'titulo_capitulo', 'frase_destaque', 'cta', 'midia', //
];

/// Uma produção do Estúdio (Fluxo B): portão 1 (corte) → produzir (estilo + formatos) → mapa de cenas (ajuste opcional)
/// → vídeo final de cada formato com relatório (portão final).
class ProducaoTela extends StatefulWidget {
  const ProducaoTela({super.key, required this.api, required this.ep, required this.estilos});

  final ApiEsteira api;
  final String ep;
  final List<Json> estilos;

  @override
  State<ProducaoTela> createState() => _ProducaoTelaState();
}

class _ProducaoTelaState extends State<ProducaoTela> {
  String? _estilo;
  final Set<String> _formatos = {'16:9', '9:16'};
  final Map<String, String> _intensidade = {}; // só nesta produção; vazio = a do estilo

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Estúdio · ${widget.ep}')),
    body: Sondagem<Json>(
      intervalo: const Duration(seconds: 5),
      carregar: () => widget.api.producaoEstudio(widget.ep),
      construir: (context, p, recarregar) {
        final ap = p['aprovacoes'] as Json;
        final corteOk = (ap['corte'] as Json?)?['aprovado'] == true;
        final cenas = [for (final c in p['cenas'] as List) c as Json];
        final formatos = p['formatos'] as Json;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _Portao(
              numero: 1,
              titulo: 'Corte do áudio',
              feito: corteOk,
              texto: _textoCorte(p['corte'] as Json? ?? {}),
              acoes: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.content_cut),
                  label: const Text('Tomadas (texto)'),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                        appBar: AppBar(title: Text('Corte · ${widget.ep}')),
                        body: CortesAba(api: widget.api, ep: widget.ep),
                      ),
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.graphic_eq),
                  label: const Text('Cortar pelo som'),
                  onPressed: () => acaoComAviso(context, () async {
                    await widget.api.cortarPeloSom(widget.ep);
                    return 'Corte pelo som na fila';
                  }),
                ),
                if ((p['corte'] as Json?)?['feito'] == true)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.call_split),
                    label: const Text('Emendas'),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(builder: (_) => CorteTela(api: widget.api, ep: widget.ep)),
                    ),
                  ),
                FilledButton.icon(
                  icon: Icon(corteOk ? Icons.undo : Icons.check),
                  label: Text(corteOk ? 'Reabrir corte' : 'Aprovar corte'),
                  onPressed: () => acaoComAviso(context, () async {
                    await widget.api.aprovarPortao(widget.ep, 'corte', !corteOk);
                    await recarregar();
                    return corteOk ? 'Corte reaberto' : 'Corte aprovado';
                  }),
                ),
              ],
            ),
            _Portao(
              numero: 2,
              titulo: 'Produzir',
              feito: p['mapa'] != null,
              texto: '${(p['apontamento'] as Json?)?['confirmado'] == true ? 'Apontamento confirmado. ' : ''}'
                  'Marque no roteiro as cenas que você quer; a IA local dirige o resto (frase → cena do estilo), compila, renderiza na GPU, acerta o áudio (−14 LUFS) e '
                  'confere os quadros. Acompanhe em Fila e Processos.\n'
                  '${p['camera'] != null ? 'Câmera: pronta — estilos de apresentador alternam câmera cheia, tela dividida e B-roll.' : 'Sem vídeo da câmera: só estilos dark (o vídeo entra na importação do episódio em modo apresentador).'}',
              acoes: [
                DropdownButton<String>(
                  hint: const Text('template do canal'),
                  value: widget.estilos.any((e) => e['ref'] == (_estilo ??= p['template'] as String?)) ? _estilo : null,
                  items: [
                    for (final e in widget.estilos)
                      DropdownMenuItem(
                        value: e['ref'] as String,
                        child: Text('Template ${e['rotulo']} · ${e['modo']}${e['travado'] == true ? ' 🔒' : ''}'),
                      ),
                  ],
                  onChanged: (v) => setState(() => _estilo = v),
                ),
                for (final MapEntry(key: eixo, value: rotulo) in const {'sfx': 'Som', 'motion': 'Motion', 'efeitos': 'Efeitos'}.entries)
                  DropdownButton<String>(
                    value: _intensidade[eixo] ?? '',
                    items: [
                      DropdownMenuItem(value: '', child: Text('$rotulo: do estilo')),
                      for (final MapEntry(:key, :value) in const {'baixa': 'baixa', 'media': 'média', 'alta': 'alta'}.entries)
                        DropdownMenuItem(value: key, child: Text('$rotulo: $value')),
                    ],
                    onChanged: (v) => setState(() => (v == null || v.isEmpty) ? _intensidade.remove(eixo) : _intensidade[eixo] = v),
                  ),
                for (final f in ['16:9', '9:16'])
                  FilterChip(
                    label: Text(f),
                    selected: _formatos.contains(f),
                    onSelected: (s) => setState(() => s ? _formatos.add(f) : _formatos.remove(f)),
                  ),
                FilledButton.icon(
                  icon: const Icon(Icons.edit_note),
                  label: const Text('Apontar no roteiro e produzir'),
                  onPressed: !corteOk || _formatos.isEmpty
                      ? null
                      : () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => ApontamentoTela(
                              api: widget.api,
                              ep: widget.ep,
                              produzir: {'estilo': _estilo ?? '', 'formatos': _formatos.toList(), 'intensidade': _intensidade},
                            ),
                          ),
                        ),
                ),
                if (p['mapa'] != null)
                  OutlinedButton(
                    onPressed: () => acaoComAviso(context, () async {
                      await widget.api.produzirEstudio(
                        widget.ep,
                        estilo: _estilo ?? '',
                        formatos: _formatos.toList(),
                        etapas: const ['compilar', 'render', 'audio', 'verificar'],
                        intensidade: _intensidade,
                      );
                      return 'Renderizando de novo com o mapa atual';
                    }),
                    child: const Text('Só renderizar (mantém o mapa)'),
                  ),
              ],
            ),
            if (p['mapa'] != null)
              _Portao(
                numero: 3,
                titulo: 'Mapa de cenas',
                feito: (ap['mapa'] as Json?)?['aprovado'] == true,
                texto: 'Ritmo ${p['ritmo']} · modo ${p['modo']} (do roteiro). Decisões: ${(p['mapa'] as Json)['decisoes']}. '
                    'Toque numa cena para trocar: a troca fica e ensina a bancada. Depois, "Só renderizar".'
                    '${_avisosRitmo(p['mapa'] as Json)}',
                acoes: [
                  FilledButton.tonal(
                    onPressed: () => widget.api.aprovarPortao(widget.ep, 'mapa', true).then((_) => recarregar()),
                    child: const Text('Aprovar mapa'),
                  ),
                ],
                filho: p['direcao'] == 'blocos'
                    ? LinhaDoTempo(
                        api: widget.api,
                        ep: widget.ep,
                        blocos: [for (final b in (p['blocos'] as List?) ?? const []) b as Json],
                        cenas: cenas,
                        temRender: formatos.values.any((f) => (f as Json)['render'] == true),
                        recarregar: recarregar,
                      )
                    : Card(
                  child: SizedBox(
                    height: 320,
                    child: ListView(
                      children: [
                        for (final c in cenas)
                          ListTile(
                            dense: true,
                            leading: Text(_tempo(c['t'] as num)),
                            title: Text('${c['cena']}${c['titulo'] != '' ? ' · ${c['titulo']}' : ''}'),
                            subtitle: Text('${c['frase']}', maxLines: 1, overflow: TextOverflow.ellipsis),
                            trailing: Text(c['manual'] == true ? 'manual' : '${c['por']}'),
                            onTap: () => _editar(c, recarregar),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            for (final f in formatos.entries)
              _Final(api: widget.api, ep: widget.ep, formato: f.key, dados: f.value as Json, aprovacoes: ap, recarregar: recarregar),
          ],
        );
      },
    ),
  );

  static String _tempo(num s) => '${s ~/ 60}:${(s % 60).floor().toString().padLeft(2, '0')}';

  Future<void> _editar(Json c, Future<void> Function() recarregar) async {
    var cena = c['cena'] as String;
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
                value: cena,
                isExpanded: true,
                // direção por bloco: as 5 candidatas do código primeiro (a troca ensina a bancada), depois o resto
                items: [
                  for (final x in {...((c['candidatas'] as List?) ?? const []).map((e) => '$e'), cena, ..._cenas})
                    DropdownMenuItem(value: x, child: Text(x)),
                ],
                onChanged: (v) => set(() => cena = v ?? cena),
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
      await widget.api.editarCena(widget.ep, c['id'] as int, {'cena': cena, 'titulo': titulo.text, 'valores': c['valores']});
      await recarregar();
    }
    titulo.dispose();
  }
}

String _textoCorte(Json c) {
  const base = '1) Tomadas: a esteira escolhe a melhor leitura de cada frase. 2) Som: vícios, respirações e pausas saem; '
      'revise as emendas e reverta o que não ficou bom. Obrigatório.';
  if (c['feito'] != true) return base;
  String s(num v) => v.toStringAsFixed(1).replaceAll('.', ',');
  return '$base\n${s(c['duracao_antes'] as num)} s → ${s(c['duracao'] as num)} s · ${c['emendas']} emendas · '
      '${c['sumidas']} trecho(s) a conferir · ${c['repeticoes']} repetição(ões)${c['atualizado'] == true ? '' : ' · refazendo…'}';
}

class _Portao extends StatelessWidget {
  const _Portao({
    required this.numero,
    required this.titulo,
    required this.feito,
    required this.texto,
    required this.acoes,
    this.filho,
  });

  final int numero;
  final String titulo;
  final bool feito;
  final String texto;
  final List<Widget> acoes;
  final Widget? filho;

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
              CircleAvatar(radius: 14, child: feito ? const Icon(Icons.check, size: 16) : Text('$numero')),
              const SizedBox(width: 12),
              Text(titulo, style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 8),
          Text(texto),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: acoes),
          if (filho != null) ...[const SizedBox(height: 12), filho!],
        ],
      ),
    ),
  );
}

class _Final extends StatelessWidget {
  const _Final({
    required this.api,
    required this.ep,
    required this.formato,
    required this.dados,
    required this.aprovacoes,
    required this.recarregar,
  });

  final ApiEsteira api;
  final String ep;
  final String formato;
  final Json dados;
  final Json aprovacoes;
  final Future<void> Function() recarregar;

  @override
  Widget build(BuildContext context) {
    final rel = dados['relatorio'] as Json?;
    final portao = 'final_$formato';
    final aprovado = (aprovacoes[portao] as Json?)?['aprovado'] == true;
    final base = 'arq/$ep/estudio/$formato';
    return _Portao(
      numero: 4,
      titulo: 'Vídeo final ${formato.replaceAll('x', ':')}',
      feito: aprovado,
      texto: rel == null
          ? (dados['final'] == true ? 'Conferindo…' : 'Em produção (compilado: ${dados['compilado']}, render: ${dados['render']}).')
          : '${rel['lufs']} LUFS · pico ${rel['pico']} dBTP · ${rel['cenas']} cenas · ${rel['sfx_por_s']} efeitos/s · '
                'motion ${((rel['takeover'] as num) * 100).round()}% do tempo · '
                '${(rel['visao'] as List).isEmpty ? 'nenhum defeito visual' : '${(rel['visao'] as List).length} quadro(s) com defeito'}',
      acoes: [
        if (dados['final'] == true) ...[
          FilledButton.icon(
            icon: Icon(aprovado ? Icons.undo : Icons.verified),
            label: Text(aprovado ? 'Reabrir' : 'Aprovar vídeo'),
            onPressed: () => api.aprovarPortao(ep, portao, !aprovado).then((_) => recarregar()),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.download),
            label: const Text('Baixar'),
            onPressed: () => abrirUrl(context, api.arquivo('$base/final.mp4')),
          ),
        ],
      ],
      filho: dados['final'] == true
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 520),
                  // prévia leve (540p) para tocar rápido de qualquer rede; "Baixar" continua entregando o final cheio
                  child: VideoFinal(
                    url: api.arquivo('$base/${dados['previa'] == true ? 'previa' : 'final'}.mp4'),
                    vertical: formato == '9x16',
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

/// Avisos da conferência de ritmo do mapa (perfil longo/curto), em linhas para o texto do portão.
String _avisosRitmo(Json mapa) {
  final r = mapa['ritmo'] as Json?;
  final avisos = (r?['avisos'] as List?) ?? const [];
  if (avisos.isEmpty) return '';
  return '\nConferência do ritmo ${r!['perfil']}:\n${avisos.take(8).map((a) => '• ${(a as Json)['t']} s: ${a['texto']}').join('\n')}';
}
