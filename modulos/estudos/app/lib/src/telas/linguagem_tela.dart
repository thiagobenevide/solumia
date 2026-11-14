import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_estudos.dart';
import '../modelos.dart';

/// Estudos › Linguagem: o que a leitura guiada dos Arquivos junta (palavras marcadas com "Criar
/// tarefas", leituras em voz alta) e o treino em cima disso — revisão espaçada com exercícios corrigidos,
/// escrita sobre os artigos lidos e o progresso. Tudo pela LLM local e pela voz do PC (nunca o Claude).
class LinguagemTela extends StatefulWidget {
  const LinguagemTela({super.key, required this.api, required this.opcoes});

  final ApiEstudos api;
  final Opcoes opcoes;

  @override
  State<LinguagemTela> createState() => _LinguagemTelaState();
}

class _LinguagemTelaState extends State<LinguagemTela> {
  late String _idioma = widget.opcoes.idiomas.containsKey('en') ? 'en' : widget.opcoes.idiomas.keys.first;
  final _voz = _Voz();

  @override
  void dispose() {
    _voz.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final api = widget.api;
    return DefaultTabController(
      length: 5,
      child: Column(
        children: [
          Material(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            // No celular o seletor de idioma fica numa linha própria, para as abas usarem a largura toda
            child: LayoutBuilder(
              builder: (context, c) {
                final idioma = Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: DropdownButton<String>(
                    value: _idioma,
                    underline: const SizedBox(),
                    items: [
                      for (final e in widget.opcoes.idiomas.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
                    ],
                    onChanged: (v) => setState(() => _idioma = v ?? _idioma),
                  ),
                );
                const abas = TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: [
                    Tab(icon: Icon(Icons.replay_circle_filled_outlined), text: 'Revisar'),
                    Tab(icon: Icon(Icons.style_outlined), text: 'Vocabulário'),
                    Tab(icon: Icon(Icons.edit_note), text: 'Escrita'),
                    Tab(icon: Icon(Icons.record_voice_over_outlined), text: 'Leitura em voz'),
                    Tab(icon: Icon(Icons.insights_outlined), text: 'Progresso'),
                  ],
                );
                if (c.maxWidth < 600) {
                  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [idioma, abas]);
                }
                return Row(children: [idioma, const Expanded(child: abas)]);
              },
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                _RevisarAba(key: ValueKey('r$_idioma'), api: api, idioma: _idioma, voz: _voz),
                _VocabularioAba(key: ValueKey('v$_idioma'), api: api, idioma: _idioma, voz: _voz),
                _EscritaAba(key: ValueKey('e$_idioma'), api: api, idioma: _idioma, niveis: widget.opcoes.niveis),
                _LeituraVozAba(key: ValueKey('l$_idioma'), api: api, idioma: _idioma, voz: _voz),
                _ProgressoAba(key: ValueKey('p$_idioma'), api: api, idioma: _idioma),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

void _avisar(BuildContext context, Object erro) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(erro is ApiErro ? erro.mensagem : '$erro')));
}

String _data(String? iso) {
  final d = DateTime.tryParse(iso ?? '')?.toLocal();
  if (d == null) return '';
  String dois(int n) => n.toString().padLeft(2, '0');
  return '${dois(d.day)}/${dois(d.month)} ${dois(d.hour)}:${dois(d.minute)}';
}

/// Fala de palavras e frases pela mesma voz da leitura guiada.
class _Voz {
  final _tocador = Tocador();

  Future<void> ouvir(BuildContext context, ApiEstudos api, String texto, String idioma) async {
    try {
      final r = await api.fala(texto, idioma, velocidade: 0.9);
      await _tocador.tocar(base64Decode(r['audio_b64'] as String), r['mime'] as String);
    } catch (e) {
      if (context.mounted) _avisar(context, e);
    }
  }

  void dispose() => _tocador.dispose();
}

/// Tempo de estudo de uma aba (entra na trilha do idioma ao sair, se passar de meio minuto).
class _Cronometro {
  _Cronometro(this.api, this.tipo, this.idioma);

  final ApiEstudos api;
  final String tipo, idioma;
  final _relogio = Stopwatch();

  void marcar() => _relogio.start();

  void encerrar() {
    final s = _relogio.elapsed.inSeconds;
    if (s >= 30) api.registrarAtividade(tipo, idioma, (s / 60).ceil()).catchError((_) {});
  }
}

// --- Revisar: as palavras do dia, com um exercício por vez ---

class _RevisarAba extends StatefulWidget {
  const _RevisarAba({super.key, required this.api, required this.idioma, required this.voz});

  final ApiEstudos api;
  final String idioma;
  final _Voz voz;

  @override
  State<_RevisarAba> createState() => _RevisarAbaState();
}

class _RevisarAbaState extends State<_RevisarAba> {
  late Future<List<Map<String, dynamic>>> _fila = _carregar();
  late final _cronometro = _Cronometro(widget.api, 'vocabulario', widget.idioma);
  final _resposta = TextEditingController();
  Map<String, dynamic>? _correcao;
  bool _mostrar = false;
  bool _enviando = false;

  Future<List<Map<String, dynamic>>> _carregar() => widget.api.vocabulario(widget.idioma, devidas: true);

  @override
  void dispose() {
    _cronometro.encerrar();
    _resposta.dispose();
    super.dispose();
  }

  void _proxima() => setState(() {
    _correcao = null;
    _mostrar = false;
    _resposta.clear();
    _fila = _carregar();
  });

  Future<void> _corrigir(Map<String, dynamic> item, int indice) async {
    if (_resposta.text.trim().isEmpty) return;
    _cronometro.marcar();
    setState(() => _enviando = true);
    try {
      final r = await widget.api.responderExercicio(item['id'] as String, indice, _resposta.text);
      setState(() => _correcao = (r['correcao'] as Map).cast<String, dynamic>());
    } catch (e) {
      if (mounted) _avisar(context, e);
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  Future<void> _avaliar(Map<String, dynamic> item, int nota) async {
    _cronometro.marcar();
    try {
      await widget.api.revisarPalavra(item['id'] as String, nota);
      _proxima();
    } catch (e) {
      if (mounted) _avisar(context, e);
    }
  }

  Future<void> _gerar(Map<String, dynamic> item) async {
    setState(() => _enviando = true);
    try {
      await widget.api.gerarPratica(item['id'] as String);
      _proxima();
    } catch (e) {
      if (mounted) _avisar(context, e);
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _fila,
    builder: (context, s) {
      if (s.hasError) return Center(child: Text('${s.error}'));
      final fila = s.data;
      if (fila == null) return const Center(child: CircularProgressIndicator());
      if (fila.isEmpty) {
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Nada para revisar agora.\nNa leitura guiada dos Arquivos, toque numa palavra e em "Criar tarefas".',
              textAlign: TextAlign.center,
            ),
          ),
        );
      }
      final item = fila.first;
      final tema = Theme.of(context).textTheme;
      final exercicios = (item['exercicios'] as List).cast<Map>();
      final contexto = (item['contextos'] as List).cast<Map>().firstOrNull?['frase'] as String? ?? '';
      // Um exercício diferente a cada revisão da mesma palavra.
      final indice = exercicios.isEmpty ? -1 : (item['respostas'] as List).length % exercicios.length;
      final ex = indice < 0 ? null : exercicios[indice].cast<String, dynamic>();
      final c = _correcao;
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('${fila.length} para revisar', style: tema.labelMedium),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 8,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(item['termo'] as String, style: tema.headlineSmall)),
                      IconButton(
                        tooltip: 'Ouvir',
                        icon: const Icon(Icons.volume_up),
                        onPressed: () => widget.voz.ouvir(context, widget.api, item['termo'] as String, widget.idioma),
                      ),
                    ],
                  ),
                  if (contexto.isNotEmpty) Text('“$contexto”', style: tema.bodyMedium?.copyWith(fontStyle: FontStyle.italic)),
                  if (_mostrar || c != null)
                    Text(
                      '${item['traducao']}${(item['ipa'] as String? ?? '').isEmpty ? '' : '  /${item['ipa']}/'}',
                      style: tema.titleMedium?.copyWith(color: Theme.of(context).colorScheme.primary),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (ex == null)
            Row(
              spacing: 12,
              children: [
                Expanded(
                  child: Text(
                    item['gerando'] == true
                        ? 'A LLM local está criando as frases e exercícios…'
                        : (item['erro'] as String? ?? '').isNotEmpty
                        ? 'Não deu para gerar: ${item['erro']}'
                        : 'Sem exercícios ainda.',
                  ),
                ),
                OutlinedButton(onPressed: _enviando ? null : () => _gerar(item), child: const Text('Gerar agora')),
              ],
            )
          else ...[
            Text(
              switch (ex['tipo']) {
                'lacuna' => 'Complete a lacuna',
                'traducao' => 'Traduza',
                _ => 'Escreva',
              },
              style: tema.labelLarge,
            ),
            Text(ex['enunciado'] as String, style: tema.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _resposta,
              enabled: c == null,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Sua resposta'),
              onSubmitted: (_) => _corrigir(item, indice),
            ),
            const SizedBox(height: 8),
            if (c == null)
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    onPressed: _enviando ? null : () => _corrigir(item, indice),
                    child: _enviando
                        ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Corrigir'),
                  ),
                  TextButton(onPressed: () => setState(() => _mostrar = true), child: const Text('Mostrar resposta')),
                ],
              )
            else
              _Correcao(c),
          ],
          if (_mostrar && c == null && ex != null && (ex['resposta'] as String).isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text('Resposta: ${ex['resposta']}')),
          if (_mostrar || c != null || ex == null) ...[
            const SizedBox(height: 16),
            if (c != null)
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: _proxima,
                  icon: const Icon(Icons.arrow_forward),
                  label: const Text('Próxima'),
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (nota, rotulo) in [(1, 'Errei'), (2, 'Difícil'), (3, 'Bom'), (4, 'Fácil')])
                    OutlinedButton(onPressed: () => _avaliar(item, nota), child: Text(rotulo)),
                ],
              ),
          ],
        ],
      );
    },
  );
}

class _Correcao extends StatelessWidget {
  const _Correcao(this.c);

  final Map<String, dynamic> c;

  @override
  Widget build(BuildContext context) {
    final certo = c['correto'] == true;
    final cor = certo ? Colors.green.shade700 : Colors.orange.shade800;
    return Card(
      color: cor.withAlpha(20),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 4,
          children: [
            Text('${certo ? 'Certo' : 'Quase'} · ${c['nota']}/100', style: TextStyle(color: cor, fontWeight: FontWeight.bold)),
            if ((c['correcao'] as String? ?? '').isNotEmpty) Text(c['correcao'] as String),
            if ((c['explicacao'] as String? ?? '').isNotEmpty)
              Text(c['explicacao'] as String, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

// --- Vocabulário: o caderno inteiro ---

class _VocabularioAba extends StatefulWidget {
  const _VocabularioAba({super.key, required this.api, required this.idioma, required this.voz});

  final ApiEstudos api;
  final String idioma;
  final _Voz voz;

  @override
  State<_VocabularioAba> createState() => _VocabularioAbaState();
}

class _VocabularioAbaState extends State<_VocabularioAba> {
  late Future<List<Map<String, dynamic>>> _itens = widget.api.vocabulario(widget.idioma);
  String _filtro = '';

  void _recarregar() => setState(() => _itens = widget.api.vocabulario(widget.idioma));

  Future<void> _nova() async {
    final termo = TextEditingController(), contexto = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nova palavra'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: termo, autofocus: true, decoration: const InputDecoration(labelText: 'Palavra ou expressão')),
            TextField(controller: contexto, decoration: const InputDecoration(labelText: 'Frase onde apareceu (opcional)')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Criar tarefas')),
        ],
      ),
    );
    if (ok != true || termo.text.trim().isEmpty) return;
    try {
      await widget.api.criarPalavra({'termo': termo.text.trim(), 'idioma': widget.idioma, 'contexto': contexto.text.trim()});
      _recarregar();
    } catch (e) {
      if (mounted) _avisar(context, e);
    }
  }

  Future<void> _detalhe(Map<String, dynamic> item) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (context, rolagem) => _DetalhePalavra(
          item: item,
          rolagem: rolagem,
          ouvir: (t) => widget.voz.ouvir(context, widget.api, t, widget.idioma),
          gerar: () async {
            Navigator.pop(context);
            try {
              await widget.api.gerarPratica(item['id'] as String);
            } catch (e) {
              if (mounted) _avisar(this.context, e);
            }
            _recarregar();
          },
          excluir: () async {
            Navigator.pop(context);
            await widget.api.excluirPalavra(item['id'] as String);
            _recarregar();
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _nova,
      icon: const Icon(Icons.add),
      label: const Text('Palavra'),
    ),
    body: FutureBuilder(
      future: _itens,
      builder: (context, s) {
        if (s.hasError) return Center(child: Text('${s.error}'));
        final itens = s.data;
        if (itens == null) return const Center(child: CircularProgressIndicator());
        final f = _filtro.toLowerCase();
        final vistos = [
          for (final v in itens)
            if (f.isEmpty || '${v['termo']} ${v['traducao']}'.toLowerCase().contains(f)) v,
        ];
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: TextField(
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: '${itens.length} palavras no caderno',
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _filtro = v),
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async => _recarregar(),
                child: ListView.builder(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: vistos.length,
                  itemBuilder: (context, i) {
                    final v = vistos[i];
                    final fonte = (v['contextos'] as List).cast<Map>().firstOrNull;
                    final proxima = (v['cartao'] as Map?)?['proxima'] as String?;
                    return ListTile(
                      title: Text(v['termo'] as String),
                      subtitle: Text(
                        [
                          if ((v['traducao'] as String? ?? '').isNotEmpty) v['traducao'],
                          if (fonte?['titulo'] case final String t when t.isNotEmpty)
                            '$t${fonte?['pagina'] != null ? ', p. ${(fonte!['pagina'] as int) + 1}' : ''}',
                          if (v['gerando'] == true) 'gerando exercícios…',
                        ].join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Text('revisar ${_data(proxima).split(' ').first}', style: Theme.of(context).textTheme.labelSmall),
                      onTap: () => _detalhe(v),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

class _DetalhePalavra extends StatelessWidget {
  const _DetalhePalavra({
    required this.item,
    required this.rolagem,
    required this.ouvir,
    required this.gerar,
    required this.excluir,
  });

  final Map<String, dynamic> item;
  final ScrollController rolagem;
  final void Function(String texto) ouvir;
  final VoidCallback gerar, excluir;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context).textTheme;
    final contextos = (item['contextos'] as List).cast<Map>();
    final frases = (item['frases'] as List).cast<Map>();
    final exercicios = (item['exercicios'] as List).cast<Map>();
    final cartao = (item['cartao'] as Map?) ?? const {};
    return ListView(
      controller: rolagem,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      children: [
        Row(
          children: [
            Expanded(child: Text(item['termo'] as String, style: tema.headlineSmall)),
            IconButton(icon: const Icon(Icons.volume_up), onPressed: () => ouvir(item['termo'] as String)),
          ],
        ),
        Text(
          [
            item['traducao'],
            if ((item['ipa'] as String? ?? '').isNotEmpty) '/${item['ipa']}/',
            item['classe'],
          ].where((x) => '$x'.isNotEmpty).join('  ·  '),
          style: tema.titleMedium,
        ),
        Text(
          'Revisões: ${cartao['revisoes'] ?? 0} · próxima: ${_data(cartao['proxima'] as String?)}',
          style: tema.labelSmall,
        ),
        if (contextos.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Onde apareceu', style: tema.titleSmall),
          for (final c in contextos)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('“${c['frase']}”'),
              subtitle: (c['titulo'] as String? ?? '').isEmpty ? null : Text('${c['titulo']}'),
            ),
        ],
        const SizedBox(height: 16),
        Text('Frases para memorizar', style: tema.titleSmall),
        if (frases.isEmpty) const Text('Ainda não geradas.'),
        for (final f in frases)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Text('${f['nivel']}', style: tema.labelSmall),
            title: Text('${f['texto']}'),
            subtitle: Text('${f['traducao']}'),
            trailing: IconButton(icon: const Icon(Icons.volume_up_outlined), onPressed: () => ouvir('${f['texto']}')),
          ),
        if (exercicios.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Exercícios (aparecem na aba Revisar)', style: tema.titleSmall),
          for (final e in exercicios) Text('• ${e['enunciado']}'),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton.icon(onPressed: gerar, icon: const Icon(Icons.auto_awesome), label: const Text('Gerar de novo')),
            TextButton.icon(onPressed: excluir, icon: const Icon(Icons.delete_outline), label: const Text('Excluir')),
          ],
        ),
      ],
    );
  }
}

// --- Escrita: perguntas sobre o artigo lido, corrigidas pela LLM local ---

class _EscritaAba extends StatefulWidget {
  const _EscritaAba({super.key, required this.api, required this.idioma, required this.niveis});

  final ApiEstudos api;
  final String idioma;
  final List<String> niveis;

  @override
  State<_EscritaAba> createState() => _EscritaAbaState();
}

class _EscritaAbaState extends State<_EscritaAba> {
  late Future<List<Map<String, dynamic>>> _escritas = widget.api.escritas(widget.idioma);
  bool _criando = false;

  void _recarregar() => setState(() => _escritas = widget.api.escritas(widget.idioma));

  Future<void> _nova() async {
    final leituras = [
      for (final l in await widget.api.leituras().catchError((_) => <Leitura>[]))
        if (l.arquivoId != null) l,
    ];
    if (!mounted) return;
    final pedido = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _NovaEscrita(leituras: leituras, niveis: widget.niveis),
    );
    if (pedido == null) return;
    setState(() => _criando = true);
    try {
      final e = await widget.api.criarEscrita({...pedido, 'idioma': widget.idioma});
      _recarregar();
      if (mounted) await _abrir(e);
    } catch (e) {
      if (mounted) _avisar(context, e);
    } finally {
      if (mounted) setState(() => _criando = false);
    }
  }

  Future<void> _abrir(Map<String, dynamic> e) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => _EscritaTela(api: widget.api, escrita: e)),
    );
    _recarregar();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _criando ? null : _nova,
      icon: _criando
          ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.add),
      label: Text(_criando ? 'Criando perguntas…' : 'Nova escrita'),
    ),
    body: FutureBuilder(
      future: _escritas,
      builder: (context, s) {
        if (s.hasError) return Center(child: Text('${s.error}'));
        final lista = s.data;
        if (lista == null) return const Center(child: CircularProgressIndicator());
        if (lista.isEmpty) {
          return const Center(child: Text('Crie uma escrita sobre um artigo que você leu.'));
        }
        return ListView(
          padding: const EdgeInsets.only(bottom: 88),
          children: [
            for (final e in lista)
              Builder(
                builder: (context) {
                  final respostas = (e['respostas'] as Map).values.cast<Map>().toList();
                  final media = respostas.isEmpty
                      ? null
                      : (respostas.fold<num>(0, (s, r) => s + (r['nota'] as num)) / respostas.length).round();
                  return ListTile(
                    title: Text(e['titulo'] as String),
                    subtitle: Text(
                      [
                        e['nivel'],
                        if ((e['titulo_arquivo'] as String? ?? '').isNotEmpty) e['titulo_arquivo'],
                        '${respostas.length}/${(e['perguntas'] as List).length} respondidas',
                        _data(e['criado'] as String?),
                      ].join(' · '),
                    ),
                    trailing: media == null ? null : Text('$media', style: Theme.of(context).textTheme.titleLarge),
                    onTap: () => _abrir(e),
                  );
                },
              ),
          ],
        );
      },
    ),
  );
}

class _NovaEscrita extends StatefulWidget {
  const _NovaEscrita({required this.leituras, required this.niveis});

  final List<Leitura> leituras;
  final List<String> niveis;

  @override
  State<_NovaEscrita> createState() => _NovaEscritaState();
}

class _NovaEscritaState extends State<_NovaEscrita> {
  Leitura? _leitura;
  String _nivel = 'B1';
  final _texto = TextEditingController();

  @override
  void dispose() {
    _texto.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Nova escrita'),
    content: SizedBox(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 12,
        children: [
          DropdownButtonFormField<Leitura?>(
            initialValue: _leitura,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Sobre o artigo'),
            items: [
              const DropdownMenuItem(value: null, child: Text('Texto colado abaixo / tema livre')),
              for (final l in widget.leituras)
                DropdownMenuItem(value: l, child: Text(l.titulo, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() => _leitura = v),
          ),
          if (_leitura == null)
            TextField(
              controller: _texto,
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(labelText: 'Trecho de referência (opcional)', border: OutlineInputBorder()),
            ),
          DropdownButtonFormField<String>(
            initialValue: _nivel,
            decoration: const InputDecoration(labelText: 'Nível'),
            items: [for (final n in widget.niveis) DropdownMenuItem(value: n, child: Text(n))],
            onChanged: (v) => setState(() => _nivel = v ?? _nivel),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(
        onPressed: () => Navigator.pop(context, {
          'nivel': _nivel,
          if (_leitura != null) ...{'arquivo_id': _leitura!.arquivoId, 'titulo_arquivo': _leitura!.titulo},
          if (_leitura == null) 'texto': _texto.text.trim(),
        }),
        child: const Text('Criar perguntas'),
      ),
    ],
  );
}

class _EscritaTela extends StatefulWidget {
  const _EscritaTela({required this.api, required this.escrita});

  final ApiEstudos api;
  final Map<String, dynamic> escrita;

  @override
  State<_EscritaTela> createState() => _EscritaTelaState();
}

class _EscritaTelaState extends State<_EscritaTela> {
  late var _e = widget.escrita;
  late final _cronometro = _Cronometro(widget.api, 'escrita', widget.escrita['idioma'] as String);
  late final _campos = [
    for (var i = 0; i < (_e['perguntas'] as List).length; i++)
      TextEditingController(text: ((_e['respostas'] as Map)['$i'] as Map?)?['resposta'] as String? ?? ''),
  ];
  final _enviando = <int>{};

  @override
  void initState() {
    super.initState();
    _cronometro.marcar();
  }

  @override
  void dispose() {
    _cronometro.encerrar();
    for (final c in _campos) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _corrigir(int i) async {
    setState(() => _enviando.add(i));
    try {
      final e = await widget.api.responderEscrita(_e['id'] as String, i, _campos[i].text);
      setState(() => _e = e);
    } catch (e) {
      if (mounted) _avisar(context, e);
    } finally {
      if (mounted) setState(() => _enviando.remove(i));
    }
  }

  Future<void> _excluir() async {
    await widget.api.excluirEscrita(_e['id'] as String);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context).textTheme;
    final perguntas = (_e['perguntas'] as List).cast<Map>();
    final respostas = (_e['respostas'] as Map).cast<String, dynamic>();
    return Scaffold(
      appBar: AppBar(
        title: Text(_e['titulo'] as String),
        actions: [IconButton(tooltip: 'Excluir', icon: const Icon(Icons.delete_outline), onPressed: _excluir)],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final (i, p) in perguntas.indexed) ...[
            Text('${i + 1}. ${p['pergunta']}', style: tema.titleMedium),
            if ((p['palavras_sugeridas'] as List? ?? const []).isNotEmpty)
              Wrap(
                spacing: 6,
                children: [
                  for (final w in (p['palavras_sugeridas'] as List).cast<String>())
                    Chip(label: Text(w), visualDensity: VisualDensity.compact),
                ],
              ),
            const SizedBox(height: 8),
            TextField(
              controller: _campos[i],
              minLines: 4,
              maxLines: 12,
              decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Escreva sua resposta'),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonal(
                onPressed: _enviando.contains(i) ? null : () => _corrigir(i),
                child: _enviando.contains(i)
                    ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(respostas.containsKey('$i') ? 'Corrigir de novo' : 'Corrigir'),
              ),
            ),
            if (respostas['$i'] case final Map c) _CorrecaoEscrita(c.cast<String, dynamic>()),
            const Divider(height: 32),
          ],
        ],
      ),
    );
  }
}

class _CorrecaoEscrita extends StatelessWidget {
  const _CorrecaoEscrita(this.c);

  final Map<String, dynamic> c;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context).textTheme;
    final correcoes = (c['correcoes'] as List? ?? const []).cast<Map>();
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 6,
          children: [
            Text(
              'Nota ${c['nota']}  ·  nível ${c['nivel_cefr'] ?? '?'}',
              style: tema.titleMedium?.copyWith(color: Theme.of(context).colorScheme.primary),
            ),
            Text(
              'Gramática ${c['gramatica']} · Vocabulário ${c['vocabulario']} · Coerência ${c['coerencia']} · '
              'Adequação ${c['adequacao']}',
              style: tema.labelMedium,
            ),
            if ((c['texto_corrigido'] as String? ?? '').isNotEmpty) ...[
              Text('Texto corrigido', style: tema.titleSmall),
              SelectableText(c['texto_corrigido'] as String),
            ],
            for (final k in correcoes)
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: '${k['trecho']}', style: const TextStyle(decoration: TextDecoration.lineThrough)),
                    const TextSpan(text: '  →  '),
                    TextSpan(text: '${k['correcao']}', style: const TextStyle(fontWeight: FontWeight.bold)),
                    TextSpan(text: '\n${k['explicacao']}', style: tema.bodySmall),
                  ],
                ),
              ),
            if ((c['comentario'] as String? ?? '').isNotEmpty) Text(c['comentario'] as String, style: tema.bodyMedium),
          ],
        ),
      ),
    );
  }
}

// --- Leitura em voz alta: cola o texto, lê, e vê as palavras e a pronúncia ---

class _LeituraVozAba extends StatefulWidget {
  const _LeituraVozAba({super.key, required this.api, required this.idioma, required this.voz});

  final ApiEstudos api;
  final String idioma;
  final _Voz voz;

  @override
  State<_LeituraVozAba> createState() => _LeituraVozAbaState();
}

class _LeituraVozAbaState extends State<_LeituraVozAba> {
  late Future<List<Map<String, dynamic>>> _historico = widget.api.leiturasVoz(widget.idioma);
  final _texto = TextEditingController();
  final _gravador = GravadorLeitura();
  DateTime? _inicio;
  bool _avaliando = false;
  Map<String, dynamic>? _resultado;

  @override
  void dispose() {
    _texto.dispose();
    _gravador.dispose();
    super.dispose();
  }

  Future<void> _alternar() async {
    if (!_gravador.gravando) {
      if (_texto.text.trim().isEmpty) return _avisar(context, 'Cole primeiro o trecho que você vai ler.');
      if (!await _gravador.iniciar()) {
        if (mounted) _avisar(context, 'Sem permissão para usar o microfone.');
        return;
      }
      setState(() {
        _inicio = DateTime.now();
        _resultado = null;
      });
      return;
    }
    final wav = await _gravador.parar();
    setState(() => _avaliando = true);
    try {
      if (wav == null || wav.length < 44 + 16000 * 2) throw 'Gravação curta demais.';
      final r = await widget.api.avaliarLeitura(wav, widget.idioma, _texto.text.trim());
      final minutos = (DateTime.now().difference(_inicio ?? DateTime.now()).inSeconds / 60).ceil();
      widget.api.registrarAtividade('leitura_voz', widget.idioma, minutos).catchError((_) {});
      setState(() {
        _resultado = r;
        _historico = widget.api.leiturasVoz(widget.idioma);
      });
    } catch (e) {
      if (mounted) _avisar(context, e);
    } finally {
      if (mounted) setState(() => _avaliando = false);
    }
  }

  void _ouvir(String t) => widget.voz.ouvir(context, widget.api, t, widget.idioma);

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context).textTheme;
    final gravando = _gravador.gravando;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Cole um trecho de artigo e leia em voz alta. O Whisper confere as palavras e o modelo fonético a pronúncia de '
          'cada uma (no leitor dos Arquivos, o microfone da leitura guiada faz o mesmo com a página).',
          style: tema.bodySmall,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _texto,
          minLines: 3,
          maxLines: 10,
          enabled: !gravando,
          decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Trecho para ler'),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: _avaliando ? null : _alternar,
              style: gravando ? FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error) : null,
              icon: Icon(gravando ? Icons.stop : Icons.mic),
              label: Text(gravando ? 'Parar e avaliar' : 'Gravar minha leitura'),
            ),
            OutlinedButton.icon(
              onPressed: gravando || _texto.text.trim().isEmpty ? null : () => _ouvir(_texto.text.trim()),
              icon: const Icon(Icons.volume_up_outlined),
              label: const Text('Ouvir o modelo'),
            ),
            if (_avaliando) const Text('Avaliando…'),
          ],
        ),
        if (_resultado != null)
          Card(
            margin: const EdgeInsets.only(top: 16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ResultadoLeituraVoz(resultado: _resultado!, ouvir: _ouvir),
            ),
          ),
        const SizedBox(height: 24),
        Text('Histórico', style: tema.titleSmall),
        FutureBuilder(
          future: _historico,
          builder: (context, s) {
            final lista = s.data;
            if (lista == null) return const LinearProgressIndicator();
            if (lista.isEmpty) return const Text('Nenhuma leitura ainda.');
            return Column(
              children: [
                for (final r in lista)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(r['referencia'] as String, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      [
                        '${r['precisao']}% certas',
                        if (r['pronuncia'] != null) 'pronúncia ${r['pronuncia']}%',
                        '${r['ppm']} ppm',
                        if ((r['titulo'] as String? ?? '').isNotEmpty) r['titulo'],
                        _data(r['criado'] as String?),
                      ].join(' · '),
                    ),
                    onTap: () => showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                        content: SizedBox(
                          width: 560,
                          child: SingleChildScrollView(child: ResultadoLeituraVoz(resultado: r, ouvir: _ouvir)),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () async {
                              Navigator.pop(context);
                              await widget.api.excluirLeituraVoz(r['id'] as String);
                              setState(() => _historico = widget.api.leiturasVoz(widget.idioma));
                            },
                            child: const Text('Excluir'),
                          ),
                          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fechar')),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

// --- Progresso ---

class _ProgressoAba extends StatelessWidget {
  const _ProgressoAba({super.key, required this.api, required this.idioma});

  final ApiEstudos api;
  final String idioma;

  static const _tipos = {
    'leitura_guiada': 'Leitura guiada',
    'vocabulario': 'Revisão de vocabulário',
    'escrita': 'Escrita',
    'leitura_voz': 'Leitura em voz alta',
  };

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: api.progresso(idioma),
    builder: (context, s) {
      if (s.hasError) return Center(child: Text('${s.error}'));
      final p = s.data;
      if (p == null) return const Center(child: CircularProgressIndicator());
      final tema = Theme.of(context).textTheme;
      final v = (p['vocabulario'] as Map).cast<String, dynamic>();
      final minutos = (p['minutos'] as Map).cast<String, dynamic>();
      final escrita = (p['escrita'] as List).cast<Map>().reversed.take(10).toList();
      final leitura = (p['leitura_voz'] as List).cast<Map>().reversed.take(10).toList();
      Widget secao(String titulo, List<Widget> filhos) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [Text(titulo, style: tema.titleMedium), ...filhos],
          ),
        ),
      );
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          secao('Vocabulário', [
            Text('${v['total']} palavras · ${v['devidas']} para revisar hoje'),
            Text('${v['aprendendo']} aprendendo · ${v['dominadas']} dominadas (intervalo de 3 semanas ou mais)'),
          ]),
          secao('Tempo de estudo', [
            if (minutos.isEmpty) const Text('Nada registrado ainda.'),
            for (final e in minutos.entries) Text('${_tipos[e.key] ?? e.key}: ${e.value} min'),
          ]),
          secao('Escrita (últimas notas)', [
            if (escrita.isEmpty) const Text('Nenhuma resposta corrigida ainda.'),
            for (final e in escrita) Text('${_data(e['data'] as String?)} — nota ${e['nota']} (${e['nivel_cefr']})'),
          ]),
          secao('Leitura em voz alta (últimas)', [
            if (leitura.isEmpty) const Text('Nenhuma leitura ainda.'),
            for (final l in leitura)
              Text(
                '${_data(l['data'] as String?)} — ${l['precisao']}% certas, ${l['ppm']} ppm'
                '${l['pronuncia'] != null ? ', pronúncia ${l['pronuncia']}%' : ''}',
              ),
          ]),
        ],
      );
    },
  );
}
