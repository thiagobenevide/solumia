import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../modelos.dart';
import 'util.dart';

/// Quem faz o trabalho de IA: motor padrão, Claude (modelo e tetos), motor e modelos locais por operação,
/// e download de modelos (Hugging Face → llama.cpp) com o andamento.
class OpcoesAba extends StatefulWidget {
  const OpcoesAba({super.key, required this.api});

  final ApiEsteira api;

  @override
  State<OpcoesAba> createState() => _OpcoesAbaState();
}

class _OpcoesAbaState extends State<OpcoesAba> {
  late Future<Json> _dados = widget.api.opcoes();
  Json? _form;
  final _baixar = TextEditingController();

  @override
  void dispose() {
    _baixar.dispose();
    super.dispose();
  }

  void _preencher(Json d) {
    final o = d['opcoes'] as Json;
    final c = d['claude'] as Json;
    _form = {
      'motor': o['motor'] ?? 'local',
      'modelo_claude': c['modelo'],
      'teto_episodio_usd': c['teto_episodio_usd'],
      'teto_dia_usd': c['teto_dia_usd'],
      'socorro_claude': o['socorro_claude'] == true,
      'operacoes': {
        for (final op in (d['operacoes'] as List).cast<Json>()) '${op['id']}': {...op['atual'] as Json},
      },
    };
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _dados,
    builder: (context, s) {
      if (s.hasError) {
        return ErroComRetry(
          erro: s.error!,
          tentar: () => setState(() {
            _dados = widget.api.opcoes();
          }),
        );
      }
      final d = s.data;
      if (d == null) return const Center(child: CircularProgressIndicator());
      if (_form == null) _preencher(d);
      final f = _form!;
      final locais = [for (final m in d['locais'] as List) m as Json];
      final padrao = d['padrao'] as Json;
      return LarguraMaxima(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Vale para tudo que entrar na fila a partir de agora (e para o ./dark no terminal). Transcrição (Whisper), '
              'imagens das thumbs e renders continuam na máquina.',
            ),
            const Secao('Motor padrão'),
            RadioGroup<String>(
              groupValue: '${f['motor']}',
              onChanged: (v) => setState(() => f['motor'] = v),
              child: const Column(
                children: [
                  RadioListTile(
                    value: 'local',
                    title: Text('LLM local (GPU)'),
                    subtitle: Text('llama.cpp na máquina; sem custo. O Claude só entra quando o local fica em dúvida.'),
                  ),
                  RadioListTile(
                    value: 'claude',
                    title: Text('Claude'),
                    subtitle: Text(
                      'Toda pergunta de LLM vai ao Claude; não ocupa a GPU. Conta no teto de gasto; se o teto acabar, volta ao local.',
                    ),
                  ),
                ],
              ),
            ),
            const Secao('Claude'),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                SizedBox(
                  width: 320,
                  child: DropdownButtonFormField<String>(
                    initialValue: f['modelo_claude'] as String?,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Modelo', border: OutlineInputBorder(), isDense: true),
                    items: [
                      for (final m in (d['modelos_claude'] as List).cast<Json>())
                        DropdownMenuItem(
                          value: '${m['id']}',
                          child: Text('${m['nome']} · ${m['descricao']}', overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (v) => f['modelo_claude'] = v,
                  ),
                ),
                for (final (chave, rotulo) in const [
                  ('teto_episodio_usd', 'Teto por episódio (US\$)'),
                  ('teto_dia_usd', 'Teto por dia (US\$)'),
                ])
                  SizedBox(
                    width: 170,
                    child: TextFormField(
                      initialValue: '${f[chave] ?? ''}',
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(labelText: rotulo, border: const OutlineInputBorder(), isDense: true),
                      onChanged: (v) => f[chave] = double.tryParse(v.replaceAll(',', '.')),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Com o motor Claude em tudo, o teto de US\$ 1 por episódio costuma acabar no meio da produção. Ajuste aqui se quiser.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Socorro do Claude no Estúdio'),
              subtitle: const Text(
                'Desligado (padrão): o que a IA local errar duas vezes no diretor cai na regra fixa, sem custo. '
                'Ligado: vai ao Claude em lote (até 20% das frases por vídeo).',
              ),
              value: f['socorro_claude'] == true,
              onChanged: (v) => setState(() => f['socorro_claude'] = v),
            ),
            const Secao('Por operação'),
            Text(
              '"Padrão" segue o motor padrão acima. O modelo local só vale quando a operação roda no LLM local.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            for (final op in (d['operacoes'] as List).cast<Json>()) _operacao(context, op, f, locais, padrao),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(onPressed: _salvar, child: const Text('Salvar opções')),
            ),
            const Secao('Modelos locais (llama.cpp)'),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (locais.isEmpty) const Text('O llama.cpp não respondeu.', style: TextStyle(color: Colors.redAccent)),
                for (final m in locais)
                  Chip(label: Text('${m['nome']} · ${m['gb']} GB${m['visao'] == true ? ' · visão' : ''}')),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 280,
                  child: Autocomplete<String>(
                    optionsBuilder: (v) => [
                      for (final sug in (d['sugestoes'] as List).cast<Json>())
                        if ('${sug['nome']}'.contains(v.text)) '${sug['nome']}',
                    ],
                    onSelected: (v) => _baixar.text = v,
                    fieldViewBuilder: (context, c, foco, enviar) {
                      c.addListener(() => _baixar.text = c.text);
                      return TextField(
                        controller: c,
                        focusNode: foco,
                        decoration: const InputDecoration(
                          labelText: 'Baixar modelo do Hugging Face (usuario/repo:QUANT)',
                          hintText: 'unsloth/Qwen3-8B-GGUF:Q4_K_M',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      );
                    },
                  ),
                ),
                FilledButton.tonal(onPressed: _baixarModelo, child: const Text('Baixar')),
              ],
            ),
            const SizedBox(height: 8),
            for (final sug in (d['sugestoes'] as List).cast<Json>())
              Text(
                '${sug['nome']} · ${sug['tipo']} · ${sug['descricao']}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            Text(
              'Até 16 GB de VRAM; modelos maiores rodam em parte na CPU (bem mais lentos). Depois de baixar, escolha-o na operação acima.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 140,
              child: Sondagem<Json>(
                intervalo: const Duration(seconds: 2),
                carregar: widget.api.baixando,
                construir: (context, b, _) => ListView(
                  children: [for (final MapEntry(key: nome, value: st) in b.entries) _baixando(nome, st as Json)],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _operacao(BuildContext context, Json op, Json f, List<Json> locais, Json padrao) {
    final atual = (f['operacoes'] as Json)['${op['id']}'] as Json;
    final tipos = [for (final t in op['tipos'] as List) '$t'];
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 12,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 300,
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${op['nome']}'),
                subtitle: Text('${op['descricao']}'),
              ),
            ),
            SizedBox(
              width: 160,
              child: DropdownButtonFormField<String>(
                initialValue: '${atual['motor'] ?? 'padrao'}',
                decoration: const InputDecoration(labelText: 'Motor', border: OutlineInputBorder(), isDense: true),
                items: const [
                  DropdownMenuItem(value: 'padrao', child: Text('Padrão')),
                  DropdownMenuItem(value: 'local', child: Text('LLM local')),
                  DropdownMenuItem(value: 'claude', child: Text('Claude')),
                ],
                onChanged: (v) => atual['motor'] = v,
              ),
            ),
            for (final t in tipos)
              SizedBox(
                width: 240,
                child: DropdownButtonFormField<String>(
                  initialValue: atual[t] as String? ?? '',
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'modelo de ${t == 'texto' ? 'texto' : 'visão (imagens)'}',
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    DropdownMenuItem(value: '', child: Text('padrão (${padrao[t]})')),
                    for (final m in locais)
                      if (t == 'texto' || m['visao'] == true)
                        DropdownMenuItem(value: '${m['nome']}', child: Text('${m['nome']} · ${m['gb']} GB')),
                  ],
                  onChanged: (v) => atual[t] = (v == null || v.isEmpty) ? null : v,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _baixando(String nome, Json s) {
    final total = (s['total'] as num? ?? 0).toDouble();
    final feito = (s['feito'] as num? ?? 0).toDouble();
    return ListTile(
      dense: true,
      title: Text(nome, style: const TextStyle(fontFamily: 'monospace')),
      subtitle: switch (s['estado']) {
        'baixando' => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(value: total > 0 ? feito / total : null),
            Text(
              '${s['msg']}${total > 0 ? ' · ${(feito / 1e9).toStringAsFixed(1)}/${(total / 1e9).toStringAsFixed(1)} GB' : ''}',
            ),
          ],
        ),
        'ok' => const Text('✓ instalado', style: TextStyle(color: Colors.green)),
        _ => Text('✗ ${s['msg']}', style: const TextStyle(color: Colors.redAccent)),
      },
    );
  }

  Future<void> _salvar() => acaoComAviso(context, () async {
    final d = await widget.api.salvarOpcoes(_form!);
    setState(() {
      _preencher(d);
      _dados = Future.value(d);
    });
    return 'Opções salvas.';
  });

  Future<void> _baixarModelo() => acaoComAviso(context, () async {
    await widget.api.baixarModelo(_baixar.text.trim());
    return 'Baixando ${_baixar.text.trim()}…';
  });
}
