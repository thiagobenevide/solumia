import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api_codigo.dart';
import 'modelos.dart';
import 'realce.dart';

/// Navegador do código (só leitura): a árvore do repositório do PC num commit (padrão: o último) com o
/// que esse commit trouxe em destaque — arquivos novos/alterados na árvore e linhas novas no arquivo.
class NavegadorTela extends StatefulWidget {
  const NavegadorTela({super.key, required this.api});

  final ApiCodigo api;

  @override
  State<NavegadorTela> createState() => _NavegadorTelaState();
}

class _NavegadorTelaState extends State<NavegadorTela> {
  ArvoreCodigo? _arvore;
  Object? _erro;
  bool _carregando = false;
  String _commit = '';
  final _abertas = <String>{};
  String? _aberto;
  bool _soNovidades = false;
  String _filtro = '';

  /// O que a caixa de busca procura: nome de arquivo, texto no código ou observações (comentários).
  _Modo _modo = _Modo.arquivos;

  /// Linha e termo para o visor pular e destacar ao abrir um resultado da busca.
  int? _linha;
  String _destaque = '';

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Future<void> _carregar([String commit = '']) async {
    setState(() => _carregando = true);
    try {
      final arvore = await widget.api.arvore(commit);
      if (!mounted) return;
      setState(() {
        _arvore = arvore;
        _commit = commit;
        _erro = null;
        // Já abre as pastas do que mudou e o primeiro arquivo novo/alterado, se nada estava aberto.
        for (final c in arvore.mudancas.keys) {
          final partes = c.split('/');
          for (var i = 1; i < partes.length; i++) {
            _abertas.add(partes.take(i).join('/'));
          }
        }
        if (_aberto == null || !arvore.arquivos.contains(_aberto)) {
          _aberto = [
            for (final e in arvore.mudancas.entries)
              if (e.value != 'D') e.key,
          ].firstOrNull;
        }
      });
    } catch (e) {
      // 404 aqui = backend da VPS anterior ao navegador (rotas /arvore e /arquivo ainda não existem lá).
      final erro = e is ApiErro && e.status == 404
          ? 'O backend da VPS está desatualizado e ainda não tem o navegador de código. '
                'Atualize a VPS (peça aqui no Código "atualizar a VPS" ou rode infra/scripts/atualizar_vps) e tente de novo.'
          : e;
      if (mounted) setState(() => _erro = erro);
    } finally {
      if (mounted) setState(() => _carregando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final arvore = _arvore;
    if (arvore == null) {
      return _erro != null
          ? ErroComRetry(erro: _erro!, tentar: _carregar)
          : const Center(child: CircularProgressIndicator());
    }
    return LayoutBuilder(
      builder: (context, c) {
        final largo = c.maxWidth >= 820;
        final lista = _Lista(
          api: widget.api,
          compacto: !largo,
          modo: _modo,
          aoModo: (m) => setState(() => _modo = m),
          aoAbrirLinha: (a, l) => setState(() {
            _aberto = a;
            _linha = l;
            _destaque = _modo == _Modo.observacoes && _filtro.trim().isEmpty ? '' : _filtro.trim();
          }),
          arvore: arvore,
          abertas: _abertas,
          aberto: _aberto,
          soNovidades: _soNovidades,
          filtro: _filtro,
          aoAlternarPasta: (p) => setState(() => _abertas.contains(p) ? _abertas.remove(p) : _abertas.add(p)),
          aoAbrir: (a) => setState(() {
            _aberto = a;
            _linha = null;
            _destaque = '';
          }),
          aoFiltrar: (f) => setState(() => _filtro = f),
          aoSoNovidades: (v) => setState(() => _soNovidades = v),
        );
        final aberto = _aberto;
        final visor = aberto == null
            ? const Center(child: Text('Escolha um arquivo à esquerda.'))
            : _Visor(
                key: ValueKey('${arvore.commit}:$aberto'),
                api: widget.api,
                caminho: aberto,
                commit: arvore.commit,
                status: arvore.mudancas[aberto],
                linha: _linha,
                destaque: _destaque,
                aoVoltar: largo ? null : () => setState(() => _aberto = null),
              );
        // No celular o arquivo aberto ocupa a tela toda; o "voltar" do sistema volta para a lista.
        final soVisor = !largo && aberto != null;
        return PopScope(
          canPop: !soVisor,
          onPopInvokedWithResult: (saiu, _) {
            if (!saiu && soVisor) setState(() => _aberto = null);
          },
          child: Column(
            children: [
              if (!soVisor)
                _Cabecalho(
                  arvore: arvore,
                  commit: _commit,
                  carregando: _carregando,
                  compacto: !largo,
                  aoEscolher: _carregar,
                ),
              if (_erro != null)
                MaterialBanner(
                  content: Text('$_erro'),
                  leading: const Icon(Icons.error_outline),
                  actions: [TextButton(onPressed: () => _carregar(_commit), child: const Text('Tentar de novo'))],
                ),
              if (!soVisor) const Divider(height: 1),
              Expanded(
                child: largo
                    ? Row(
                        children: [
                          SizedBox(width: 340, child: lista),
                          const VerticalDivider(width: 1),
                          Expanded(child: visor),
                        ],
                      )
                    : (aberto == null ? lista : visor),
              ),
            ],
          ),
        );
      },
    );
  }
}

enum _Modo { arquivos, texto, observacoes }

/// Cor e rótulo de cada status do git.
(Color, String) _status(String status, ColorScheme esquema) => switch (status) {
  'A' => (Colors.green, 'novo'),
  'M' => (Colors.orange, 'alterado'),
  'D' => (esquema.error, 'removido'),
  'R' => (Colors.blue, 'renomeado'),
  _ => (esquema.outline, status),
};

String _data(DateTime? d) {
  if (d == null) return '';
  final l = d.toLocal();
  String dois(int n) => n.toString().padLeft(2, '0');
  return '${dois(l.day)}/${dois(l.month)} ${dois(l.hour)}:${dois(l.minute)}';
}

/// Commit mostrado (lista dos últimos para escolher) e o resumo do que ele mudou.
class _Cabecalho extends StatelessWidget {
  const _Cabecalho({
    required this.arvore,
    required this.commit,
    required this.carregando,
    required this.compacto,
    required this.aoEscolher,
  });

  final ArvoreCodigo arvore;
  final String commit;
  final bool carregando;

  /// Celular: uma linha só (título e autor empilhados, contagem em letras) para sobrar tela ao código.
  final bool compacto;
  final ValueChanged<String> aoEscolher;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final esquema = tema.colorScheme;
    final atual = [
      for (final c in arvore.commits)
        if (c.hash == arvore.commit) c,
    ].firstOrNull;
    final contagem = <String, int>{};
    for (final s in arvore.mudancas.values) {
      contagem[s] = (contagem[s] ?? 0) + 1;
    }
    final titulo = atual == null
        ? arvore.commit.substring(0, 7)
        : '${commit.isEmpty ? 'Última atualização' : atual.curto} · ${atual.assunto}';
    final atualizar = IconButton(
      tooltip: 'Atualizar',
      onPressed: carregando ? null : () => aoEscolher(commit),
      icon: carregando
          ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.refresh),
    );
    PopupMenuButton<String> menu(Widget child) => PopupMenuButton<String>(
      tooltip: 'Ver outra atualização',
      onSelected: (h) => aoEscolher(h == arvore.commits.firstOrNull?.hash ? '' : h),
      itemBuilder: (_) => [
        for (final (i, c) in arvore.commits.indexed)
          PopupMenuItem(
            value: c.hash,
            child: Text(
              '${c.curto}  ${_data(c.data)}  ${c.assunto}${i == 0 ? '  (última)' : ''}',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: c.hash == arvore.commit ? FontWeight.bold : null),
            ),
          ),
      ],
      child: child,
    );
    if (compacto) {
      return Material(
        color: esquema.surfaceContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 0, 2),
          child: Row(
            children: [
              Expanded(
                child: menu(
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              titulo,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: tema.textTheme.titleSmall,
                            ),
                            Text.rich(
                              TextSpan(
                                children: [
                                  if (atual != null) TextSpan(text: '${atual.autor} · ${_data(atual.data)}'),
                                  for (final s in ['A', 'M', 'R', 'D'])
                                    if (contagem[s] != null)
                                      TextSpan(
                                        text: '  ● ${contagem[s]} ${_status(s, esquema).$2}',
                                        style: TextStyle(color: _status(s, esquema).$1),
                                      ),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: tema.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.arrow_drop_down),
                    ],
                  ),
                ),
              ),
              if (commit.isNotEmpty)
                IconButton(tooltip: 'Última', onPressed: () => aoEscolher(''), icon: const Icon(Icons.update)),
              atualizar,
            ],
          ),
        ),
      );
    }
    return Material(
      color: esquema.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Icon(Icons.history, size: 18, color: esquema.onSurfaceVariant),
            menu(
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(titulo, overflow: TextOverflow.ellipsis, style: tema.textTheme.titleSmall),
                    ),
                    const Icon(Icons.arrow_drop_down),
                  ],
                ),
              ),
            ),
            if (atual != null) Text('${atual.autor} · ${_data(atual.data)}', style: tema.textTheme.bodySmall),
            for (final s in ['A', 'M', 'R', 'D'])
              if (contagem[s] != null)
                Chip(
                  visualDensity: VisualDensity.compact,
                  avatar: Icon(Icons.circle, size: 10, color: _status(s, esquema).$1),
                  label: Text('${contagem[s]} ${_status(s, esquema).$2}${contagem[s]! > 1 ? 's' : ''}'),
                ),
            if (commit.isNotEmpty)
              TextButton.icon(
                onPressed: () => aoEscolher(''),
                icon: const Icon(Icons.update),
                label: const Text('Última'),
              ),
            atualizar,
          ],
        ),
      ),
    );
  }
}

/// Linha da lista à esquerda: pasta (com nível) ou arquivo.
typedef _Item = ({String caminho, String nome, int nivel, bool pasta});

/// Árvore de arquivos com busca e filtro "só o que mudou" (que viram lista plana de caminhos); nos
/// modos texto/observações a busca vai ao repositório e mostra as linhas encontradas.
class _Lista extends StatelessWidget {
  const _Lista({
    required this.api,
    required this.compacto,
    required this.modo,
    required this.aoModo,
    required this.aoAbrirLinha,
    required this.arvore,
    required this.abertas,
    required this.aberto,
    required this.soNovidades,
    required this.filtro,
    required this.aoAlternarPasta,
    required this.aoAbrir,
    required this.aoFiltrar,
    required this.aoSoNovidades,
  });

  final ApiCodigo api;
  final bool compacto;
  final _Modo modo;
  final ValueChanged<_Modo> aoModo;
  final void Function(String caminho, int linha) aoAbrirLinha;
  final ArvoreCodigo arvore;
  final Set<String> abertas;
  final String? aberto;
  final bool soNovidades;
  final String filtro;
  final ValueChanged<String> aoAlternarPasta;
  final ValueChanged<String> aoAbrir;
  final ValueChanged<String> aoFiltrar;
  final ValueChanged<bool> aoSoNovidades;

  /// Árvore achatada só com o que está visível (pastas antes de arquivos, em ordem alfabética).
  List<_Item> _itens() {
    final busca = filtro.trim().toLowerCase();
    if (busca.isNotEmpty || soNovidades) {
      final fonte = soNovidades ? arvore.mudancas.keys : arvore.arquivos;
      return [
        for (final c in fonte.toList()..sort())
          if (c.toLowerCase().contains(busca)) (caminho: c, nome: c, nivel: 0, pasta: false),
      ];
    }
    final pastas = <String, Set<String>>{'': {}};
    final arquivos = <String, List<String>>{};
    for (final c in arvore.arquivos) {
      final partes = c.split('/');
      for (var i = 0; i < partes.length - 1; i++) {
        final pai = partes.take(i).join('/');
        final pasta = partes.take(i + 1).join('/');
        (pastas[pai] ??= {}).add(pasta);
        pastas[pasta] ??= {};
      }
      (arquivos[partes.take(partes.length - 1).join('/')] ??= []).add(c);
    }
    final itens = <_Item>[];
    void descer(String pasta, int nivel) {
      for (final p in pastas[pasta]!.toList()..sort()) {
        itens.add((caminho: p, nome: p.split('/').last, nivel: nivel, pasta: true));
        if (abertas.contains(p)) descer(p, nivel + 1);
      }
      for (final a in [...?arquivos[pasta]]..sort()) {
        itens.add((caminho: a, nome: a.split('/').last, nivel: nivel, pasta: false));
      }
    }

    descer('', 0);
    return itens;
  }

  @override
  Widget build(BuildContext context) {
    final esquema = Theme.of(context).colorScheme;
    final itens = modo == _Modo.arquivos ? _itens() : const <_Item>[];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: SegmentedButton<_Modo>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(
                value: _Modo.arquivos,
                icon: Icon(Icons.description_outlined, size: 18),
                label: Text('Arquivos'),
              ),
              ButtonSegment(value: _Modo.texto, icon: Icon(Icons.text_fields, size: 18), label: Text('Palavras')),
              ButtonSegment(
                value: _Modo.observacoes,
                icon: Icon(Icons.comment_outlined, size: 18),
                label: Text('Observações'),
              ),
            ],
            selected: {modo},
            onSelectionChanged: (m) => aoModo(m.first),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: TextFormField(
            initialValue: filtro,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 18),
              hintText: switch (modo) {
                _Modo.arquivos => 'Buscar arquivo pelo nome ou pasta',
                _Modo.texto => 'Buscar palavra no código',
                _Modo.observacoes => 'Buscar nos comentários (vazio: TODO/FIXME)',
              },
              border: const OutlineInputBorder(),
            ),
            onChanged: aoFiltrar,
          ),
        ),
        if (modo == _Modo.arquivos)
          SwitchListTile(
            dense: true,
            title: Text('Só o que mudou (${arvore.mudancas.length})'),
            value: soNovidades,
            onChanged: aoSoNovidades,
          )
        else
          const SizedBox(height: 8),
        const Divider(height: 1),
        if (modo != _Modo.arquivos)
          Expanded(
            child: _Resultados(
              api: api,
              commit: arvore.commit,
              termo: filtro.trim(),
              observacoes: modo == _Modo.observacoes,
              aberto: aberto,
              compacto: compacto,
              aoAbrir: aoAbrirLinha,
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              itemCount: itens.length,
              itemExtent: compacto ? 40 : 30,
              itemBuilder: (context, i) {
                final item = itens[i];
                final status = arvore.mudancas[item.caminho];
                final mudou = item.pasta ? arvore.pastaMudou(item.caminho) : status != null;
                final cor = status == null ? null : _status(status, esquema).$1;
                return InkWell(
                  onTap: () {
                    if (item.pasta) {
                      aoAlternarPasta(item.caminho);
                    } else if (status != 'D') {
                      aoAbrir(item.caminho);
                    }
                  },
                  child: Container(
                    color: item.caminho == aberto ? esquema.secondaryContainer : null,
                    padding: EdgeInsets.only(left: 8 + item.nivel * 14.0, right: 8),
                    child: Row(
                      children: [
                        if (item.pasta)
                          Icon(
                            abertas.contains(item.caminho) ? Icons.folder_open : Icons.folder,
                            size: 16,
                            color: esquema.primary,
                          )
                        else
                          iconeArquivo(item.nome, esquema.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            item.nome,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: compacto ? 14 : 13,
                              color: cor,
                              fontWeight: mudou ? FontWeight.w600 : null,
                              decoration: status == 'D' ? TextDecoration.lineThrough : null,
                            ),
                          ),
                        ),
                        if (status != null)
                          Text(
                            status,
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: cor),
                          )
                        else if (item.pasta && mudou)
                          const Icon(Icons.circle, size: 7, color: Colors.orange),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

/// Linhas encontradas no repositório, agrupadas por arquivo; tocar abre o arquivo naquela linha.
class _Resultados extends StatefulWidget {
  const _Resultados({
    required this.api,
    required this.commit,
    required this.termo,
    required this.observacoes,
    required this.aberto,
    required this.compacto,
    required this.aoAbrir,
  });

  final ApiCodigo api;
  final String commit;
  final String termo;
  final bool observacoes;
  final String? aberto;
  final bool compacto;
  final void Function(String caminho, int linha) aoAbrir;

  @override
  State<_Resultados> createState() => _ResultadosState();
}

class _ResultadosState extends State<_Resultados> {
  Timer? _espera;
  Map<String, dynamic>? _achado;
  Object? _erro;
  bool _carregando = false;
  int _pedido = 0;

  /// Última busca feita: voltar do arquivo aberto (celular) mostra o resultado sem perguntar ao PC de novo.
  static (String, Map<String, dynamic>)? _ultima;

  String get _chave => '${widget.commit}|${widget.observacoes}|${widget.termo}';

  @override
  void initState() {
    super.initState();
    _buscar();
  }

  @override
  void didUpdateWidget(_Resultados antigo) {
    super.didUpdateWidget(antigo);
    if (antigo.termo != widget.termo || antigo.observacoes != widget.observacoes || antigo.commit != widget.commit) {
      // Espera parar de digitar para não mandar uma busca ao PC a cada letra.
      _espera?.cancel();
      _espera = Timer(const Duration(milliseconds: 450), _buscar);
    }
  }

  @override
  void dispose() {
    _espera?.cancel();
    super.dispose();
  }

  Future<void> _buscar() async {
    final pedido = ++_pedido;
    if (widget.termo.length < 2 && !(widget.observacoes && widget.termo.isEmpty)) {
      setState(() {
        _achado = null;
        _erro = null;
        _carregando = false;
      });
      return;
    }
    if (_ultima?.$1 == _chave) {
      setState(() {
        _achado = _ultima!.$2;
        _erro = null;
      });
      return;
    }
    final chave = _chave;
    setState(() => _carregando = true);
    try {
      final r = await widget.api.buscar(widget.termo, widget.commit, observacoes: widget.observacoes);
      _ultima = (chave, r);
      if (mounted && pedido == _pedido) {
        setState(() {
          _achado = r;
          _erro = null;
        });
      }
    } catch (e) {
      if (mounted && pedido == _pedido) setState(() => _erro = e);
    } finally {
      if (mounted && pedido == _pedido) setState(() => _carregando = false);
    }
  }

  /// Texto da linha com o termo (ou as marcações TODO/FIXME) em destaque.
  TextSpan _marcado(String texto, TextStyle base, Color fundo) {
    final termo = widget.termo.toLowerCase();
    final padrao = termo.isEmpty
        ? RegExp(r'\b(TODO|FIXME|XXX|HACK|NOTE|OBS)\b')
        : RegExp(RegExp.escape(termo), caseSensitive: false);
    final partes = <TextSpan>[];
    var pos = 0;
    for (final m in padrao.allMatches(texto)) {
      if (m.start > pos) partes.add(TextSpan(text: texto.substring(pos, m.start)));
      partes.add(
        TextSpan(
          text: m.group(0),
          style: TextStyle(backgroundColor: fundo, fontWeight: FontWeight.bold),
        ),
      );
      pos = m.end;
    }
    if (pos < texto.length) partes.add(TextSpan(text: texto.substring(pos)));
    return TextSpan(children: partes, style: base);
  }

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final esquema = tema.colorScheme;
    final achado = _achado;
    final Widget corpo;
    if (_erro != null) {
      corpo = ErroComRetry(erro: _erro!, tentar: _buscar);
    } else if (achado == null) {
      corpo = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _carregando ? 'Buscando…' : 'Digite ao menos 2 letras para buscar em todos os arquivos.',
            textAlign: TextAlign.center,
            style: tema.textTheme.bodyMedium?.copyWith(color: esquema.onSurfaceVariant),
          ),
        ),
      );
    } else {
      final resultados = [for (final r in achado['resultados'] as List) r as Map<String, dynamic>];
      final arquivos = <String>{for (final r in resultados) r['caminho'] as String};
      // Lista plana: cabeçalho do arquivo seguido das suas linhas.
      final itens = <Object>[];
      String? ultimo;
      for (final r in resultados) {
        if (r['caminho'] != ultimo) itens.add(ultimo = r['caminho'] as String);
        itens.add(r);
      }
      const mono = TextStyle(fontFamily: 'monospace', fontSize: 12.5);
      final fundo = Colors.amber.withValues(alpha: 0.45);
      corpo = Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    resultados.isEmpty
                        ? 'Nada encontrado.'
                        : '${resultados.length}${achado['cortado'] == true ? '+' : ''} linha${resultados.length > 1 ? 's' : ''} '
                              'em ${arquivos.length} arquivo${arquivos.length > 1 ? 's' : ''}',
                    style: tema.textTheme.labelMedium,
                  ),
                ),
                if (_carregando) const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: itens.length,
              itemBuilder: (context, i) {
                final item = itens[i];
                if (item is String) {
                  final partes = item.split('/');
                  return Container(
                    color: esquema.surfaceContainerHigh,
                    padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                    child: Row(
                      children: [
                        iconeArquivo(partes.last, esquema.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: partes.last,
                                  style: const TextStyle(fontWeight: FontWeight.w600),
                                ),
                                if (partes.length > 1)
                                  TextSpan(
                                    text: '  ${partes.take(partes.length - 1).join('/')}',
                                    style: TextStyle(color: esquema.onSurfaceVariant, fontSize: 11),
                                  ),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  );
                }
                final r = item as Map<String, dynamic>;
                final caminho = r['caminho'] as String;
                final linha = r['linha'] as int;
                return InkWell(
                  onTap: () => widget.aoAbrir(caminho, linha),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: widget.compacto ? 8 : 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 40,
                          child: Text(
                            '$linha',
                            textAlign: TextAlign.right,
                            style: mono.copyWith(color: esquema.outline),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text.rich(
                            _marcado(r['texto'] as String, mono, fundo),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      );
    }
    return corpo;
  }
}

/// Arquivo aberto: números de linha, linhas novas do commit em verde, botão para pular entre elas,
/// busca dentro do arquivo e tamanho da letra ajustável (para ler no celular).
class _Visor extends StatefulWidget {
  const _Visor({
    super.key,
    required this.api,
    required this.caminho,
    required this.commit,
    required this.status,
    this.linha,
    this.destaque = '',
    this.aoVoltar,
  });

  final ApiCodigo api;
  final String caminho;
  final String commit;
  final String? status;

  /// Linha (1 = primeira) para abrir já rolado até ela e o termo a destacar (vindos da busca).
  final int? linha;
  final String destaque;
  final VoidCallback? aoVoltar;

  @override
  State<_Visor> createState() => _VisorState();
}

class _VisorState extends State<_Visor> {
  /// Tamanho da letra guardado entre arquivos abertos.
  static double _fonte = 13;
  late final Future<ArquivoCodigo> _arquivo = widget.api.arquivo(widget.caminho, widget.commit);
  final _rolagem = ScrollController();
  final _busca = TextEditingController();
  final _foco = FocusNode();
  (ArquivoCodigo, Brightness)? _chaveRealce;
  List<List<TextSpan>>? _realce;
  List<String> _linhas = const [];
  bool _buscando = false;

  /// Linhas (índice 0) com o termo da busca no arquivo e qual delas está em foco.
  List<int> _achados = const [];
  int _atual = -1;

  /// Linha já rolada (para não repetir a cada reconstrução).
  int? _rolada;

  double get _altura => (_fonte * 1.3 + 2).roundToDouble();

  @override
  void initState() {
    super.initState();
    if (widget.destaque.isNotEmpty) {
      _buscando = true;
      _busca.text = widget.destaque;
    }
  }

  @override
  void didUpdateWidget(_Visor antigo) {
    super.didUpdateWidget(antigo);
    if (widget.destaque != antigo.destaque && widget.destaque.isNotEmpty) {
      _buscando = true;
      _busca.text = widget.destaque;
      _achar();
    }
  }

  @override
  void dispose() {
    _rolagem.dispose();
    _busca.dispose();
    _foco.dispose();
    super.dispose();
  }

  void _irPara(int linha, {bool animar = true}) {
    if (!_rolagem.hasClients) return;
    final alvo = ((linha - 4) * _altura).clamp(0.0, _rolagem.position.maxScrollExtent);
    animar
        ? _rolagem.animateTo(alvo, duration: const Duration(milliseconds: 250), curve: Curves.easeOut)
        : _rolagem.jumpTo(alvo);
  }

  /// Rola até o próximo bloco de linhas novas depois do que está no topo (volta ao primeiro no fim).
  void _proximaNovidade(List<int> novas) {
    if (novas.isEmpty || !_rolagem.hasClients) return;
    final topo = (_rolagem.offset / _altura).floor() + 1;
    var alvo = novas.first;
    for (var i = 0; i < novas.length; i++) {
      final inicioDeBloco = i == 0 || novas[i - 1] != novas[i] - 1;
      if (inicioDeBloco && novas[i] > topo + 4) {
        alvo = novas[i];
        break;
      }
    }
    _irPara(alvo + 1);
  }

  /// Recalcula as linhas com o termo; foca a primeira a partir do topo visível.
  void _achar() {
    final termo = _busca.text.toLowerCase();
    final achados = termo.isEmpty
        ? const <int>[]
        : [
            for (final (i, l) in _linhas.indexed)
              if (l.toLowerCase().contains(termo)) i,
          ];
    final topo = _rolagem.hasClients ? (_rolagem.offset / _altura).floor() : 0;
    setState(() {
      _achados = achados;
      _atual = achados.isEmpty ? -1 : achados.indexWhere((i) => i >= topo).clamp(0, achados.length - 1);
    });
    if (_atual >= 0) _irPara(achados[_atual] + 1);
  }

  void _passo(int delta) {
    if (_achados.isEmpty) return;
    setState(() => _atual = (_atual + delta) % _achados.length);
    _irPara(_achados[_atual] + 1);
  }

  void _fecharBusca() => setState(() {
    _buscando = false;
    _busca.clear();
    _achados = const [];
    _atual = -1;
  });

  void _mudarFonte(double delta) => setState(() => _fonte = (_fonte + delta).clamp(9, 24));

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final esquema = tema.colorScheme;
    return FutureBuilder<ArquivoCodigo>(
      future: _arquivo,
      builder: (context, s) {
        final arquivo = s.data;
        final novas = arquivo == null ? const <int>[] : (arquivo.novas.toList()..sort());
        final status = widget.status;
        final partes = widget.caminho.split('/');
        final pasta = partes.take(partes.length - 1).join('/');
        final cabecalho = Material(
          color: esquema.surfaceContainerLow,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              children: [
                if (widget.aoVoltar != null)
                  IconButton(onPressed: widget.aoVoltar, icon: const Icon(Icons.arrow_back), tooltip: 'Arquivos')
                else
                  const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          if (status != null) ...[
                            Icon(Icons.circle, size: 9, color: _status(status, esquema).$1),
                            const SizedBox(width: 5),
                          ],
                          Flexible(
                            child: Text(
                              partes.last,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: tema.textTheme.titleSmall?.copyWith(fontFamily: 'monospace'),
                            ),
                          ),
                          if (status != null)
                            Text(
                              '  ${_status(status, esquema).$2}',
                              style: tema.textTheme.labelSmall?.copyWith(color: _status(status, esquema).$1),
                            ),
                        ],
                      ),
                      if (pasta.isNotEmpty)
                        Text(
                          pasta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tema.textTheme.bodySmall?.copyWith(color: esquema.onSurfaceVariant),
                        ),
                    ],
                  ),
                ),
                if (novas.isNotEmpty)
                  TextButton.icon(
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact, foregroundColor: Colors.green),
                    onPressed: () => _proximaNovidade(novas),
                    icon: const Icon(Icons.keyboard_double_arrow_down, size: 18),
                    label: Text('${novas.length}'),
                  ),
                IconButton(
                  tooltip: 'Buscar no arquivo',
                  isSelected: _buscando,
                  onPressed: () {
                    if (_buscando) {
                      _fecharBusca();
                    } else {
                      setState(() => _buscando = true);
                      _foco.requestFocus();
                    }
                  },
                  icon: const Icon(Icons.search),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Mais',
                  onSelected: (o) => switch (o) {
                    'maior' => _mudarFonte(1),
                    'menor' => _mudarFonte(-1),
                    'inicio' => _irPara(1),
                    'fim' => _irPara(_linhas.length + 4),
                    _ => Clipboard.setData(ClipboardData(text: widget.caminho)),
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'maior',
                      child: ListTile(leading: Icon(Icons.text_increase), title: Text('Letra maior')),
                    ),
                    const PopupMenuItem(
                      value: 'menor',
                      child: ListTile(leading: Icon(Icons.text_decrease), title: Text('Letra menor')),
                    ),
                    const PopupMenuItem(
                      value: 'inicio',
                      child: ListTile(leading: Icon(Icons.vertical_align_top), title: Text('Ir ao início')),
                    ),
                    const PopupMenuItem(
                      value: 'fim',
                      child: ListTile(leading: Icon(Icons.vertical_align_bottom), title: Text('Ir ao fim')),
                    ),
                    const PopupMenuItem(
                      value: 'copiar',
                      child: ListTile(leading: Icon(Icons.copy), title: Text('Copiar caminho')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
        final barraBusca = Material(
          color: esquema.surfaceContainerLow,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 4, 6),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _busca,
                    focusNode: _foco,
                    textInputAction: TextInputAction.search,
                    decoration: const InputDecoration(
                      isDense: true,
                      prefixIcon: Icon(Icons.search, size: 18),
                      hintText: 'Buscar neste arquivo',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => _achar(),
                    onSubmitted: (_) => _passo(1),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _busca.text.isEmpty ? '' : (_achados.isEmpty ? '0' : '${_atual + 1}/${_achados.length}'),
                  style: tema.textTheme.labelMedium,
                ),
                IconButton(
                  tooltip: 'Anterior',
                  onPressed: _achados.isEmpty ? null : () => _passo(-1),
                  icon: const Icon(Icons.keyboard_arrow_up),
                ),
                IconButton(
                  tooltip: 'Próxima',
                  onPressed: _achados.isEmpty ? null : () => _passo(1),
                  icon: const Icon(Icons.keyboard_arrow_down),
                ),
                IconButton(tooltip: 'Fechar busca', onPressed: _fecharBusca, icon: const Icon(Icons.close)),
              ],
            ),
          ),
        );
        final Widget corpo;
        if (s.hasError) {
          corpo = Center(child: Text('${s.error}'));
        } else if (arquivo == null) {
          corpo = const Center(child: CircularProgressIndicator());
        } else if (arquivo.binario) {
          corpo = Center(
            child: Text('Arquivo binário (${(arquivo.tamanho / 1024).toStringAsFixed(1)} KB): sem visualização.'),
          );
        } else {
          corpo = _texto(context, arquivo);
        }
        return Column(
          children: [
            cabecalho,
            if (_buscando) barraBusca,
            const Divider(height: 1),
            Expanded(child: corpo),
          ],
        );
      },
    );
  }

  Widget _texto(BuildContext context, ArquivoCodigo arquivo) {
    final esquema = Theme.of(context).colorScheme;
    final brilho = Theme.of(context).brightness;
    final estilo = TextStyle(fontFamily: 'monospace', fontSize: _fonte, height: 1.3);
    if (_chaveRealce?.$1 != arquivo || _chaveRealce?.$2 != brilho) {
      final linhas = arquivo.texto.replaceAll('\t', '    ').split('\n');
      if (linhas.length > 1 && linhas.last.isEmpty) linhas.removeLast();
      _linhas = linhas;
      _chaveRealce = (arquivo, brilho);
      // Sem tamanho de letra no realce: os trechos herdam o do Text.rich, e mudar a letra não refaz o realce.
      _realce = realcar(linhas.join('\n'), widget.caminho, const TextStyle(fontFamily: 'monospace'), brilho);
      // Primeira vez com o texto: aplica a busca vinda da lista e rola até a linha pedida.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_busca.text.isNotEmpty) _achar();
      });
    }
    final alvo = widget.linha;
    if (alvo != null && _rolada != alvo) {
      _rolada = alvo;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final i = _achados.indexOf(alvo - 1);
        if (i >= 0) setState(() => _atual = i);
        _irPara(alvo, animar: false);
      });
    }
    final linhas = _linhas;
    final medida = TextPainter(
      text: TextSpan(text: 'M', style: estilo),
      textDirection: TextDirection.ltr,
    )..layout();
    final maior = linhas.fold<int>(0, (m, l) => l.length > m ? l.length : m);
    final larguraNumero = '${linhas.length}'.length * medida.width + 16;
    final verde = Colors.green.withValues(alpha: 0.16);
    final achado = Colors.amber.withValues(alpha: 0.22);
    final emFoco = Colors.amber.withValues(alpha: 0.5);
    final achados = _achados.toSet();
    final foco = _atual >= 0 && _atual < _achados.length ? _achados[_atual] : -1;
    final realce = _realce;
    final altura = _altura;
    return Column(
      children: [
        if (arquivo.cortado)
          MaterialBanner(
            content: Text('Arquivo grande: mostrando só os primeiros ${(arquivo.texto.length / 1024).round()} KB.'),
            actions: const [SizedBox.shrink()],
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) {
              final largura = (larguraNumero + 12 + maior * medida.width + 24).clamp(c.maxWidth, double.infinity);
              return Scrollbar(
                controller: _rolagem,
                interactive: true,
                thickness: 8,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: largura,
                    child: SelectionArea(
                      child: ListView.builder(
                        controller: _rolagem,
                        itemCount: linhas.length,
                        itemExtent: altura,
                        itemBuilder: (context, i) {
                          final nova = arquivo.novas.contains(i + 1);
                          final fundo = i == foco ? emFoco : (achados.contains(i) ? achado : (nova ? verde : null));
                          return Container(
                            decoration: fundo == null
                                ? null
                                : BoxDecoration(
                                    color: fundo,
                                    border: nova ? const Border(left: BorderSide(color: Colors.green, width: 3)) : null,
                                  ),
                            child: Row(
                              children: [
                                SelectionContainer.disabled(
                                  child: SizedBox(
                                    width: larguraNumero,
                                    child: Text(
                                      '${i + 1}',
                                      textAlign: TextAlign.right,
                                      style: estilo.copyWith(color: nova ? Colors.green : esquema.outline),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                realce != null && i < realce.length
                                    ? Text.rich(TextSpan(children: realce[i]), style: estilo, softWrap: false)
                                    : Text(linhas[i], style: estilo, softWrap: false),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
