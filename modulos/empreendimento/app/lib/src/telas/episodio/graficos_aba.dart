import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../../api_esteira.dart';
import '../../modelos.dart';
import '../editor/editor_tela.dart';
import '../util.dart';
import 'edicao_remota.dart';

/// Gráficos animados: quadro de cada peça aos 65% da duração, abrir no editor ou no EffectCraft, criar
/// uma peça nova e renderizar o que foi salvo no EffectCraft.
class GraficosAba extends StatefulWidget {
  const GraficosAba({super.key, required this.api, required this.ep});

  final ApiEsteira api;
  final String ep;

  @override
  State<GraficosAba> createState() => _GraficosAbaState();
}

class _GraficosAbaState extends State<GraficosAba> {
  late Future<Json> _dados = widget.api.graficos(widget.ep);
  final _inicioNovo = TextEditingController(text: '0');

  void _recarregar() => setState(() { _dados = widget.api.graficos(widget.ep); });

  @override
  void dispose() {
    _inicioNovo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _dados,
    builder: (context, s) {
      if (s.hasError) return Vazio('${s.error}', icone: Icons.animation);
      final d = s.data;
      if (d == null) return const Center(child: CircularProgressIndicator());
      final lista = [for (final g in d['graficos'] as List) g as Json];
      final vertical = d['vertical'] == true;
      final porTipo = (d['por_tipo'] as Json).entries.map((e) => '${e.value} ${e.key}').join(', ');
      return RefreshIndicator(
        onRefresh: () async => _recarregar(),
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverList.list(
                children: [
                  Text(
                    '${lista.length} peças (${vertical ? '9:16' : '16:9'}): $porTipo. Quadro de cada uma aos 65% da '
                    'duração, sobre fundo cinza (no vídeo fica sobre a cena). Toque numa peça para editar texto, '
                    'tempo, efeitos e caixas de texto.',
                  ),
                  const SizedBox(height: 6),
                  const Wrap(
                    spacing: 6,
                    children: [
                      SeloMotor('local', rotulo: 'LLM local planeja'),
                      SeloMotor('py', rotulo: 'Python renderiza'),
                      SeloMotor('claude', rotulo: 'assistente do editor'),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text('Nova caixa de texto aos'),
                      SizedBox(
                        width: 90,
                        child: TextField(
                          controller: _inicioNovo,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(
                            isDense: true,
                            suffixText: 's',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      FilledButton.icon(
                        icon: const Icon(Icons.add),
                        label: const Text('Novo gráfico'),
                        onPressed: () =>
                            _editar(-1, inicio: double.tryParse(_inicioNovo.text.replaceAll(',', '.')) ?? 0),
                      ),
                    ],
                  ),
                  if ((d['editados_ec'] as int) > 0)
                    Card(
                      margin: const EdgeInsets.only(top: 12),
                      // botão abaixo do texto (não no trailing): no celular ele espremia o título
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            const Icon(Icons.edit_note, color: Colors.amber),
                            Text('${d['editados_ec']} peça(s) salva(s) no EffectCraft.'),
                            FilledButton.tonal(onPressed: _renderizar, child: const Text('Renderizar as edições')),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              sliver: SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: vertical ? 220 : 420,
                  mainAxisExtent: vertical ? 520 : 360,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemCount: lista.length,
                itemBuilder: (context, i) => _peca(context, lista[i], vertical),
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _peca(BuildContext context, Json g, bool vertical) {
    final inicio = g['inicio'] as num;
    final cores = Theme.of(context).colorScheme;
    final Widget quadro = g['previa'] != null
        ? Image.network(widget.api.arquivo('${g['previa']}'), fit: BoxFit.contain)
        : Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                g['manual'] == true
                    ? 'editado: aguardando renderização'
                    : 'não renderizado (trecho não achado no PDF)',
                textAlign: TextAlign.center,
                style: TextStyle(color: g['manual'] == true ? Colors.amber : cores.error),
              ),
            ),
          );
    return Card(
      child: InkWell(
        onTap: () => _editar(g['i'] as int),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: vertical ? 9 / 16 : 16 / 9,
              child: ColoredBox(color: const Color(0xFF2A2D33), child: quadro),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 6,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '${inicio ~/ 60}:${(inicio % 60).floor().toString().padLeft(2, '0')}',
                          style: TextStyle(color: cores.primary, fontFamily: 'monospace'),
                        ),
                        SeloMotor('py', rotulo: '${g['modelo']}'),
                        Text('${g['dur']}s', style: Theme.of(context).textTheme.bodySmall),
                        if (g['manual'] == true) const SeloEstado('na fila', texto: 'editado'),
                        if (g['roteiro'] == true)
                          const SeloEstado('rodando', texto: 'do roteiro')
                        else if (g['origem'] != null)
                          Text('${g['origem']}', style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                    Text('${g['rotulo']}', maxLines: 2, overflow: TextOverflow.ellipsis),
                    const Spacer(),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        TextButton(
                          onPressed: () => _abrirEffectCraft(g['i'] as int),
                          child: const Text('Abrir no EffectCraft'),
                        ),
                        EdicaoRemota(
                          url: widget.api.pacoteGrafico(widget.ep, g['i'] as int),
                          extensoes: const ['ecproj'],
                          enviar: (nome, bytes) => widget.api.enviarGrafico(widget.ep, g['i'] as int, nome, bytes),
                          feito: 'Peça enviada: renderize as edições para entrar no vídeo.',
                          depois: _recarregar,
                        ),
                        if (g['ec_editado'] == true)
                          const SeloEstado('na fila', texto: 'salvo no EffectCraft: falta renderizar')
                        else if (g['manual_ec'] == true)
                          const SeloEstado('rodando', texto: 'editado no EffectCraft'),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editar(int i, {double inicio = 0}) async {
    await abrirTela(context, (_) => EditorTela.grafico(api: widget.api, ep: widget.ep, indice: i, inicio: inicio));
    _recarregar();
  }

  Future<void> _abrirEffectCraft(int i) => acaoComAviso(context, () async {
    await widget.api.abrirEffectCraft(widget.ep, i);
    return 'Abrindo a peça no EffectCraft (no PC). Salve com Ctrl+S e renderize aqui.';
  });

  Future<void> _renderizar() => acaoComAviso(context, () async {
    final entrou = await widget.api.rodar(widget.ep, 'graphics', soRender: true);
    return entrou ? 'Renderização das edições na fila.' : 'A renderização já estava na fila.';
  });
}
