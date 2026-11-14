import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_esteira.dart';
import '../modelos.dart';
import '../telas/episodio/video_final.dart';
import '../telas/util.dart';
import 'acervo_tela.dart';
import 'estilo_tela.dart';
import 'fabrica_tela.dart';
import 'producao_tela.dart';
import 'sistema.dart';

/// Aba Estúdio: a rede de canais, os estilos de cada um (Fluxo A) e as produções por estilo (Fluxo B).
class EstudioAba extends StatefulWidget {
  const EstudioAba({super.key, required this.api});

  final ApiEsteira api;

  @override
  State<EstudioAba> createState() => _EstudioAbaState();
}

class _EstudioAbaState extends State<EstudioAba> {
  String? _canal;

  @override
  Widget build(BuildContext context) => Sondagem<List<dynamic>>(
    intervalo: const Duration(seconds: 20),
    carregar: widget.api.estudioCanais,
    construir: (context, canais, recarregar) {
      final lista = [for (final c in canais) c as Json];
      final sel = lista.where((c) => c['canal'] == _canal).firstOrNull ?? lista.firstOrNull;
      return LayoutBuilder(
        builder: (context, box) {
          final largo = box.maxWidth > 900;
          final menu = _Canais(
            canais: lista,
            selecionado: sel?['canal'] as String?,
            aoEscolher: (c) => setState(() => _canal = c),
            aoAdicionar: () => _adicionar(recarregar),
            api: widget.api,
          );
          final conteudo = sel == null
              ? const Vazio('Nenhum canal ainda. Use "Adicionar canal".', icone: Icons.add_circle_outline)
              : _Canal(api: widget.api, canal: sel, recarregar: recarregar);
          if (largo) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 280, child: menu),
                const VerticalDivider(width: 1),
                Expanded(child: conteudo),
              ],
            );
          }
          return ListView(children: [SizedBox(height: 300, child: menu), const Divider(), SizedBox(height: 900, child: conteudo)]);
        },
      );
    },
  );

  Future<void> _adicionar(Future<void> Function() recarregar) async {
    final dados = await showDialog<Json>(context: context, builder: (_) => const _NovoCanal());
    if (dados == null || !mounted) return;
    await acaoComAviso(context, () async {
      final e = await widget.api.novoCanal(dados);
      return 'Canal criado com o estilo ${e['id']}. Envie referências e peça a proposta do Claude.';
    });
    setState(() => _canal = dados['slug'] as String);
    await recarregar();
  }
}

class _Canais extends StatelessWidget {
  const _Canais({
    required this.canais,
    required this.selecionado,
    required this.aoEscolher,
    required this.aoAdicionar,
    required this.api,
  });

  final List<Json> canais;
  final String? selecionado;
  final ValueChanged<String> aoEscolher;
  final VoidCallback aoAdicionar;
  final ApiEsteira api;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(12),
    children: [
      FilledButton.icon(onPressed: aoAdicionar, icon: const Icon(Icons.add), label: const Text('Adicionar canal')),
      const SizedBox(height: 12),
      for (final c in canais)
        Card(
          color: c['canal'] == selecionado ? Theme.of(context).colorScheme.secondaryContainer : null,
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: cor((c['estilos'] as List).isEmpty ? null : (c['estilos'] as List).first['destaque'] as String),
              child: Text('${c['canal']}'.substring(0, 1).toUpperCase()),
            ),
            title: Text('${c['canal']}'),
            subtitle: Text('${(c['estilos'] as List).length} template(s) ·${c['episodios']} episódio(s)'),
            onTap: () => aoEscolher(c['canal'] as String),
          ),
        ),
      const Divider(height: 32),
      ListTile(
        leading: const Icon(Icons.build_circle_outlined),
        title: const Text('Dependências do motor'),
        onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => SistemaTela(api: api))),
      ),
      ListTile(
        leading: const Icon(Icons.collections_outlined),
        title: const Text('Acervo de peças'),
        subtitle: const Text('Galeria, ficha e prévia em qualquer canal'),
        onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => AcervoTela(api: api))),
      ),
      ListTile(
        leading: const Icon(Icons.auto_awesome_motion_outlined),
        title: const Text('Fábrica de peças'),
        subtitle: const Text('Claude gera, você revisa'),
        onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => FabricaTela(api: api))),
      ),
    ],
  );
}

/// Cor `#rrggbb` → [Color] (cinza se vazio ou inválido).
Color cor(String? hex) {
  final v = int.tryParse((hex ?? '').replaceFirst('#', ''), radix: 16);
  return v == null ? Colors.grey : Color(0xFF000000 | v);
}

class _Canal extends StatelessWidget {
  const _Canal({required this.api, required this.canal, required this.recarregar});

  final ApiEsteira api;
  final Json canal;
  final Future<void> Function() recarregar;

  @override
  Widget build(BuildContext context) {
    final nome = canal['canal'] as String;
    return Sondagem<List<dynamic>>(
      key: ValueKey('templates-$nome'),
      intervalo: const Duration(seconds: 15),
      carregar: () => api.templates(nome),
      construir: (context, lista, recarregarTemplates) {
        final templates = lista.cast<Json>();
        final versoes = [for (final t in templates) for (final v in t['versoes'] as List) v as Json];
        Future<void> tudo() async {
          await recarregar();
          await recarregarTemplates();
        }

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                Expanded(child: Text(nome, style: Theme.of(context).textTheme.headlineSmall)),
                FilledButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Novo template'),
                  onPressed: () => _novo(context, nome, tudo),
                ),
              ],
            ),
            const Secao('Templates (cada salvamento vira uma versão; o exemplo mostra a versão em 16:9 e 9:16)'),
            if (templates.isEmpty) const Text('Nenhum template neste canal: use "Novo template" e escolha o tipo.'),
            for (final t in templates) _Template(api: api, template: t, recarregar: tudo),
            const Secao('Produções'),
            _Producoes(api: api, canal: nome, estilos: versoes),
          ],
        );
      },
    );
  }

  Future<void> _novo(BuildContext context, String canal, Future<void> Function() recarregar) async {
    final dados = await showDialog<Json>(context: context, builder: (_) => const _NovoTemplate());
    if (dados == null || !context.mounted) return;
    Json? criado;
    await acaoComAviso(context, () async {
      criado = await api.novoTemplate(
        canal,
        dados['modo'] as String,
        (dados['formatos'] as List).cast<String>(),
        nome: dados['nome'] as String,
      );
      return 'Template ${criado!['nome']} criado (v1). Ajuste e salve; depois gere o exemplo.';
    });
    await recarregar();
    if (criado == null || !context.mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => EstiloTela(api: api, id: criado!['id'] as String)),
    );
    await recarregar();
  }
}

/// Um template do canal: escolha da versão, editar e o exemplo da versão lado a lado (horizontal e vertical).
class _Template extends StatefulWidget {
  const _Template({required this.api, required this.template, required this.recarregar});

  final ApiEsteira api;
  final Json template;
  final Future<void> Function() recarregar;

  @override
  State<_Template> createState() => _TemplateState();
}

class _TemplateState extends State<_Template> {
  String? _ref;
  bool _tocando = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.template;
    final versoes = (t['versoes'] as List).cast<Json>();
    final v = versoes.where((x) => x['ref'] == _ref).firstOrNull ?? versoes.first;
    final amostras = (v['amostras'] as Json).cast<String, bool>();
    final prontas = amostras.values.where((x) => x).length;
    final pequeno = Theme.of(context).textTheme.bodySmall;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Row(
              spacing: 12,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: cor(v['fundo'] as String?),
                    border: Border.all(color: cor(v['destaque'] as String?), width: 3),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${t['nome']}', style: Theme.of(context).textTheme.titleMedium),
                      Text(
                        'prévia ${_tipo(t['modo'] as String)} · ${(t['formatos'] as List).join(' · ')} · ${versoes.length} versão(ões)',
                        style: pequeno,
                      ),
                    ],
                  ),
                ),
                _BotaoEditar(
                  aoTocar: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute<void>(builder: (_) => EstiloTela(api: widget.api, id: t['id'] as String)),
                    );
                    setState(() => _ref = null); // volta para a versão mais nova (a recém-salva)
                    await widget.recarregar();
                  },
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                DropdownButton<String>(
                  value: v['ref'] as String,
                  items: [
                    for (final x in versoes)
                      DropdownMenuItem(
                        value: x['ref'] as String,
                        child: Text(
                          '${x['rotulo']}${x['travado'] == true ? ' 🔒' : ''}'
                          '${(x['salvo_em'] as String? ?? '').isEmpty ? '' : ' · ${_data(x['salvo_em'] as String)}'}',
                        ),
                      ),
                  ],
                  onChanged: (r) => setState(() {
                    _ref = r;
                    _tocando = false;
                  }),
                ),
                if (prontas > 0)
                  FilledButton.tonalIcon(
                    icon: Icon(_tocando ? Icons.stop : Icons.play_arrow),
                    label: Text(_tocando ? 'Fechar exemplo' : 'Ver exemplo'),
                    onPressed: () => setState(() => _tocando = !_tocando),
                  ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.movie_creation_outlined),
                  label: Text(prontas > 0 ? 'Refazer exemplo' : 'Gerar exemplo'),
                  onPressed: () => acaoComAviso(context, () async {
                    await widget.api.gerarAmostra(v['ref'] as String);
                    return 'Exemplo de ${v['rotulo']} na fila (30 s em ${amostras.keys.join(' e ')}). Acompanhe em Fila.';
                  }),
                ),
                if (prontas < amostras.length) Text('exemplo: $prontas de ${amostras.length} formato(s) pronto(s)', style: pequeno),
              ],
            ),
            if (_tocando)
              Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  for (final MapEntry(key: fmt, value: pronta) in amostras.entries)
                    if (pronta)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 4,
                        children: [
                          Text(fmt == '9x16' ? 'Vertical 9:16' : 'Horizontal 16:9', style: pequeno),
                          SizedBox(
                            width: fmt == '9x16' ? 230 : 560,
                            height: fmt == '9x16' ? 410 : 315,
                            child: VideoFinal(
                              url: widget.api.amostra(v['id'] as String, v['versao'] as int, fmt),
                              vertical: fmt == '9x16',
                            ),
                          ),
                        ],
                      ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  static String _tipo(String modo) => switch (modo) {
    'apresentador' => 'Apresentador',
    'curso' => 'Curso',
    _ => 'Dark',
  };

  /// `2026-11-01T22:10:05` → `01/11 22:10`.
  static String _data(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    String dois(int n) => n.toString().padLeft(2, '0');
    return '${dois(d.day)}/${dois(d.month)} ${dois(d.hour)}:${dois(d.minute)}';
  }
}

/// Tipo do template novo: modo (dark, apresentador, curso) e formatos.
class _NovoTemplate extends StatefulWidget {
  const _NovoTemplate();

  @override
  State<_NovoTemplate> createState() => _NovoTemplateState();
}

class _NovoTemplateState extends State<_NovoTemplate> {
  final _nome = TextEditingController();
  String _modo = 'dark';
  final _formatos = {'16:9', '9:16'};

  @override
  void dispose() {
    _nome.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Novo template'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          const Text('Modo da prévia e da amostra'),
          Text('No vídeo vale o modo marcado no roteiro (modo: dark ou apresentador); aqui é só como o template é mostrado.',
              style: Theme.of(context).textTheme.bodySmall),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'dark', label: Text('Dark'), icon: Icon(Icons.mic)),
              ButtonSegment(value: 'apresentador', label: Text('Apresentador'), icon: Icon(Icons.videocam)),
              ButtonSegment(value: 'curso', label: Text('Curso'), icon: Icon(Icons.school)),
            ],
            selected: {_modo},
            onSelectionChanged: (s) => setState(() => _modo = s.first),
          ),
          const Text('Formatos'),
          Wrap(
            spacing: 8,
            children: [
              for (final (f, rotulo) in const [('16:9', 'Horizontal 16:9'), ('9:16', 'Vertical 9:16')])
                FilterChip(
                  label: Text(rotulo),
                  selected: _formatos.contains(f),
                  onSelected: (s) => setState(() => s ? _formatos.add(f) : _formatos.remove(f)),
                ),
            ],
          ),
          TextField(
            controller: _nome,
            decoration: const InputDecoration(labelText: 'Nome (opcional)', hintText: 'padrão: <canal> · <tipo>'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(
        onPressed: _formatos.isEmpty
            ? null
            : () => Navigator.pop(context, {'modo': _modo, 'formatos': _formatos.toList(), 'nome': _nome.text.trim()}),
        child: const Text('Criar'),
      ),
    ],
  );
}

class _Producoes extends StatelessWidget {
  const _Producoes({required this.api, required this.canal, required this.estilos});

  final ApiEsteira api;
  final String canal;
  final List<Json> estilos;

  @override
  Widget build(BuildContext context) => Sondagem<List<dynamic>>(
    key: ValueKey(canal),
    intervalo: const Duration(seconds: 10),
    carregar: () => api.producoesEstudio(canal),
    construir: (context, lista, _) {
      if (lista.isEmpty) {
        return const Text('Nenhum episódio com narração editada neste canal (importe um roteiro na aba Roteiros).');
      }
      return Card(
        child: Column(
          children: [
            for (final p in lista.cast<Json>())
              ListTile(
                title: Text('${p['ep']} · ${p['titulo']}'),
                subtitle: Text(_resumo(p)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => ProducaoTela(api: api, ep: p['ep'] as String, estilos: estilos),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );

  static String _resumo(Json p) {
    final ap = p['aprovacoes'] as Json;
    final partes = <String>[
      (ap['corte'] as Json?)?['aprovado'] == true ? 'corte aprovado' : 'corte a aprovar',
      if (p['mapa'] != null) '${(p['mapa'] as Json)['cenas']} cenas',
      for (final f in (p['formatos'] as Json).entries)
        '${f.key}: ${(f.value as Json)['final'] == true ? 'vídeo pronto' : 'em produção'}',
    ];
    return partes.join(' · ');
  }
}

class _NovoCanal extends StatefulWidget {
  const _NovoCanal();

  @override
  State<_NovoCanal> createState() => _NovoCanalState();
}

class _NovoCanalState extends State<_NovoCanal> {
  final _nome = TextEditingController();
  final _slug = TextEditingController();
  final _nicho = TextEditingController();
  final _cor = TextEditingController(text: '#f5c518');
  String _modo = 'dark';

  @override
  void dispose() {
    for (final c in [_nome, _slug, _nicho, _cor]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Adicionar canal'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nome,
            decoration: const InputDecoration(labelText: 'Nome do canal'),
            onChanged: (v) => _slug.text = v.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-|-$'), ''),
          ),
          TextField(controller: _slug, decoration: const InputDecoration(labelText: 'Identificador (pasta)')),
          TextField(controller: _nicho, decoration: const InputDecoration(labelText: 'Nicho e público')),
          TextField(controller: _cor, decoration: const InputDecoration(labelText: 'Cor de destaque (#rrggbb)')),
          const SizedBox(height: 12),
          Text('Modo da prévia (no vídeo vale o do roteiro)', style: Theme.of(context).textTheme.bodySmall),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'dark', label: Text('Dark')),
              ButtonSegment(value: 'apresentador', label: Text('Apresentador')),
              ButtonSegment(value: 'curso', label: Text('Curso')),
            ],
            selected: {_modo},
            onSelectionChanged: (s) => setState(() => _modo = s.first),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(
        onPressed: () => Navigator.pop(context, {
          'nome': _nome.text,
          'slug': _slug.text,
          'nicho': _nicho.text,
          'cor': _cor.text,
          'modo': _modo,
        }),
        child: const Text('Criar'),
      ),
    ],
  );
}

/// "Editar" com rótulo em tela larga; no celular só o ícone, para o nome do template não quebrar.
class _BotaoEditar extends StatelessWidget {
  const _BotaoEditar({required this.aoTocar});

  final VoidCallback aoTocar;

  @override
  Widget build(BuildContext context) => MediaQuery.sizeOf(context).width < 600
      ? IconButton.outlined(tooltip: 'Editar', icon: const Icon(Icons.edit), onPressed: aoTocar)
      : OutlinedButton.icon(icon: const Icon(Icons.edit), label: const Text('Editar'), onPressed: aoTocar);
}
