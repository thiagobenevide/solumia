import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'atualizacao.dart';
import 'desligar_pc.dart';
import 'llm_tela.dart';

/// Moldura do app: navegação entre os módulos. No celular e no tablet em pé (até 1199 dp), barra
/// inferior com botão central e a aba "Mais" com o menu completo; a partir daí, menu lateral fixo com
/// o usuário no topo e os submenus recuados.
///
/// No menu lateral cada módulo abre em abas (várias do mesmo módulo, cada uma com o próprio estado)
/// e a área pode ser dividida em dois painéis lado a lado, cada um com sua barra de abas.
class Shell extends StatefulWidget {
  const Shell({super.key, required this.modulos, required this.aoSair, required this.api, this.usuario = ''});

  final List<Modulo> modulos;

  /// Nome mostrado no topo do menu.
  final String usuario;

  /// Backend da plataforma (tela Modelo de IA).
  final ApiCliente api;
  final VoidCallback aoSair;

  @override
  State<Shell> createState() => _ShellState();
}

/// Uma aba aberta. A [chave] global preserva o estado da tela ao mover a aba de painel.
/// Com [tela], é uma tela aberta de dentro do módulo ([abrirTela]): leitor, detalhe, link...
class _Aba {
  _Aba(this.modulo, {this.tela, this.icone, String? titulo, this.resultado}) {
    this.titulo.value = titulo;
  }

  final int modulo;
  final WidgetBuilder? tela;
  final IconData? icone;

  /// Quem abriu a tela espera o resultado do `Navigator.pop` (ou `null` ao fechar a aba).
  final Completer<Object?>? resultado;
  final chave = GlobalKey();

  _Aba copia() => _Aba(modulo, tela: tela, icone: icone, titulo: titulo.value);

  /// Definido pela própria tela ([TituloAba]); `null` usa o nome do módulo.
  final titulo = ValueNotifier<String?>(null);
}

class _Painel {
  _Painel(_Aba aba) : abas = [aba];

  final List<_Aba> abas;
  int ativa = 0;

  _Aba get atual => abas[ativa];
}

class _ShellState extends State<Shell> {
  late final List<_Painel> _paineis = [_Painel(_Aba(0))];
  int _foco = 0;
  _ModoMenu _modoMenu = _ModoMenu.completo;

  /// Barra inferior: a aba "Mais" (menu completo) está aberta no lugar da tela do módulo.
  bool _maisAberto = false;

  /// Barra inferior some ao rolar para baixo e volta ao rolar para cima.
  bool _barraVisivel = true;

  /// Fração da largura do primeiro painel quando dividido.
  double _divisao = 0.5;

  _Painel get _painel => _paineis[_foco];

  @override
  void initState() {
    super.initState();
    for (final m in widget.modulos) {
      m.iniciar();
    }
  }

  /// Menu lateral: ativa a aba do módulo no painel em foco ou abre uma nova.
  void _irPara(int modulo) => setState(() {
    final i = _painel.abas.indexWhere((a) => a.modulo == modulo && a.tela == null);
    if (i >= 0) {
      _painel.ativa = i;
    } else {
      _abrir(_foco, modulo);
    }
  });

  /// Submenu: abre o módulo e troca a tela dele para a seção pedida.
  void _irParaSecao(int modulo, int secao) {
    _irPara(modulo);
    widget.modulos[modulo].secaoAtual?.value = secao;
  }

  /// Módulos com o submenu aberto no menu lateral.
  final Set<int> _expandidos = {};

  /// Itens do menu lateral: (módulo, seção); cada módulo seguido do seu submenu, se expandido.
  List<(int, int?)> get _itensMenu => [
    for (final (i, m) in widget.modulos.indexed) ...[
      (i, null),
      if (_expandidos.contains(i))
        for (var j = 0; j < m.secoes.length; j++) (i, j),
    ],
  ];

  /// Destaca a seção aberta quando a aba ativa é a tela principal de um módulo com submenu expandido;
  /// recolhido, destaca o próprio módulo.
  int get _itemAtual {
    final aba = _painel.atual;
    final m = widget.modulos[aba.modulo];
    final s = aba.tela == null && m.secoes.isNotEmpty ? m.secaoAtual?.value : null;
    final k = _itensMenu.indexOf((aba.modulo, s));
    return k >= 0 ? k : _itensMenu.indexOf((aba.modulo, null));
  }

  /// Clicar num módulo com submenu abre ou recolhe as seções dele.
  void _aoEscolherItem(int k) {
    final (i, j) = _itensMenu[k];
    if (j != null) return _irParaSecao(i, j);
    if (widget.modulos[i].secoes.isNotEmpty && !_expandidos.remove(i)) _expandidos.add(i);
    _irPara(i);
  }

  /// Mudanças de seção feitas dentro das telas refazem o destaque do menu.
  late final Listenable _secoes = Listenable.merge([for (final m in widget.modulos) ?m.secaoAtual]);

  void _abrir(int painel, int modulo) => _inserir(painel, _Aba(modulo));

  void _inserir(int painel, _Aba aba) {
    final p = _paineis[painel];
    p.abas.insert(p.ativa + 1, aba);
    p.ativa++;
    _foco = painel;
  }

  /// [abrirTela] das telas: abre ao lado da aba ativa do painel em foco.
  Future<Object?> _abrirTela(String? titulo, IconData? icone, WidgetBuilder tela) {
    final aba = _Aba(_painel.atual.modulo, tela: tela, icone: icone, titulo: titulo, resultado: Completer());
    setState(() => _inserir(_foco, aba));
    return aba.resultado!.future;
  }

  void _encerrar(_Aba aba, [Object? resultado]) {
    if (aba.resultado?.isCompleted == false) aba.resultado!.complete(resultado);
  }

  /// A tela da aba saiu com `Navigator.pop`: devolve o resultado e fecha a aba.
  void _saiu(_Aba aba, Future<Object?> resultado) => resultado.then((r) {
    // devolve antes de fechar: fechar completa com null
    _encerrar(aba, r);
    final painel = _paineis.indexWhere((p) => p.abas.contains(aba));
    if (mounted && painel >= 0) _fechar(painel, aba);
  });

  void _fechar(int painel, _Aba aba) => setState(() {
    _encerrar(aba);
    final p = _paineis[painel];
    final i = p.abas.indexOf(aba);
    p.abas.removeAt(i);
    if (p.abas.isEmpty) {
      if (_paineis.length > 1) {
        _paineis.removeAt(painel);
        _foco = 0;
      } else {
        p.abas.add(_Aba(aba.modulo));
        p.ativa = 0;
      }
      return;
    }
    if (p.ativa >= i && p.ativa > 0) p.ativa--;
  });

  /// Divide a área: a aba ativa do painel em foco ganha uma cópia no novo painel à direita.
  void _dividir() => setState(() {
    _paineis.add(_Painel(_Aba(_painel.atual.modulo)));
    _foco = 1;
  });

  /// Leva a aba para o outro painel (criando-o se a área ainda não está dividida).
  void _mover(int painel, _Aba aba) => setState(() {
    if (_paineis.length == 1) {
      if (_paineis[0].abas.length == 1) return;
      _paineis.add(_Painel(aba));
      _tirar(0, aba);
    } else {
      final destino = _paineis[1 - painel];
      destino.abas.add(aba);
      destino.ativa = destino.abas.length - 1;
      _tirar(painel, aba);
    }
    _foco = _paineis.indexWhere((p) => p.abas.contains(aba));
  });

  void _tirar(int painel, _Aba aba) {
    final p = _paineis[painel];
    final i = p.abas.indexOf(aba);
    p.abas.removeAt(i);
    if (p.abas.isEmpty) {
      _paineis.removeAt(painel);
    } else if (p.ativa >= i && p.ativa > 0) {
      p.ativa--;
    }
  }

  /// Solta uma aba arrastada na [posicao] da barra do [painel] (do mesmo painel ou do outro).
  void _soltar(int painel, _Aba aba, int posicao) => setState(() {
    final destino = _paineis[painel];
    final i = destino.abas.indexOf(aba);
    if (i >= 0) {
      destino.abas.removeAt(i);
      if (i < posicao) posicao--;
    } else {
      _tirar(_paineis.indexWhere((p) => p.abas.contains(aba)), aba);
    }
    destino.abas.insert(posicao.clamp(0, destino.abas.length), aba);
    destino.ativa = destino.abas.indexOf(aba);
    _foco = _paineis.indexOf(destino);
  });

  /// Aba solta sobre a tela de um painel: vinda do outro painel, entra nele; do próprio painel
  /// (sem divisão), abre ao lado.
  void _soltarNaTela(int painel, _Aba aba) {
    if (_paineis[painel].abas.contains(aba)) {
      if (_paineis.length == 1) _mover(painel, aba);
    } else {
      _soltar(painel, aba, _paineis[painel].abas.length);
    }
  }

  /// Junta os painéis num só, mantendo todas as abas.
  void _juntar() => setState(() {
    final segundo = _paineis.removeAt(1);
    _paineis[0].abas.addAll(segundo.abas);
    _foco = 0;
  });

  /// Cena de entrada do módulo na aba raiz dele; telas abertas por cima (aba.tela) entram direto.
  Widget _comCena(Modulo m, _Aba aba, bool ativa, Widget tela) {
    if (aba.tela != null) return tela;
    return CenaEntrada(tema: m.cena, titulo: m.nome, icone: m.icone, ativa: ativa, child: tela);
  }

  /// Fundo de vidro na largura toda, só nos módulos que pedem (a tela segue na largura máxima).
  Widget _comFundo(Modulo m, Widget tela) {
    if (!m.fundoVidro) return tela;
    return FundoVidro(child: tela);
  }

  Widget _tela(_Aba aba, {required bool ativa}) {
    final m = widget.modulos[aba.modulo];
    final tela = aba.tela == null
        ? Builder(builder: m.construir)
        : _NavegadorAba(tela: aba.tela!, titulo: aba.titulo, aoSair: (r) => _saiu(aba, r));
    return KeyedSubtree(
      key: aba.chave,
      child: TituloAba(
        titulo: aba.titulo,
        // A tela mede o próprio painel, não a janela: com a área dividida, Faixa.de e
        // MediaQuery.sizeOf veem só a metade que ela ocupa.
        child: LayoutBuilder(
          builder: (context, area) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: area.biggest),
            child: _comCena(
              m,
              aba,
              ativa,
              _comFundo(m, m.larguraMaxima == null ? tela : LarguraMaxima(largura: m.larguraMaxima!, child: tela)),
            ),
          ),
        ),
      ),
    );
  }

  /// IndexedStack mantém o estado de cada aba ao trocar de uma para outra.
  Widget _corpo(_Painel p) {
    final telas = <Widget>[];
    for (var i = 0; i < p.abas.length; i++) {
      telas.add(_tela(p.abas[i], ativa: i == p.ativa));
    }
    return IndexedStack(index: p.ativa, children: telas);
  }

  @override
  Widget build(BuildContext context) {
    final faixa = Faixa.de(context);
    if (faixa == Faixa.compacto || faixa == Faixa.medio) return _movel(context);
    return AbridorAbas(
      abrir: _abrirTela,
      child: Scaffold(
        body: Row(
          children: [
            // Menu completo: a mesma gaveta do celular, fixa ao lado (submenus recuados e com nome inteiro).
            if (_modoMenu == _ModoMenu.completo) ...[
              DrawerTheme(
                data: DrawerTheme.of(context).copyWith(width: 280, shape: const RoundedRectangleBorder()),
                child: SafeArea(right: false, child: _gaveta(context, fixa: true)),
              ),
              const VerticalDivider(width: 1),
            ] else if (_modoMenu != _ModoMenu.oculto) ...[
              SafeArea(
                right: false,
                child: ListenableBuilder(
                  listenable: _secoes,
                  builder: (context, _) => NavigationRail(
                    selectedIndex: _itemAtual,
                    onDestinationSelected: _aoEscolherItem,
                    labelType: NavigationRailLabelType.none,
                    leading: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.asset('assets/logo.png', width: 40, height: 40),
                      ),
                    ),
                    // Sair fixo no rodapé; a lista rola quando há mais módulos do que cabe na altura.
                    scrollable: true,
                    trailingAtBottom: true,
                    trailing: Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: IconButton(tooltip: 'Sair', icon: const Icon(Icons.logout), onPressed: widget.aoSair),
                    ),
                    destinations: [for (final (i, j) in _itensMenu) _destino(widget.modulos[i], j)],
                  ),
                ),
              ),
              const VerticalDivider(width: 1),
            ],
            // A barra de abas não é AppBar: sem o SafeArea ela fica sob a barra de status do Android.
            Expanded(child: SafeArea(child: _paineis.length == 1 ? _area(context, 0) : _divididos(context))),
          ],
        ),
      ),
    );
  }

  Widget _divididos(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final esquerda = (c.maxWidth * _divisao).clamp(240.0, c.maxWidth - 240);
      return Row(
        children: [
          SizedBox(width: esquerda, child: _area(context, 0)),
          MouseRegion(
            cursor: SystemMouseCursors.resizeColumn,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: (d) =>
                  setState(() => _divisao = ((esquerda + d.delta.dx) / c.maxWidth).clamp(0.2, 0.8)),
              onDoubleTap: () => setState(() => _divisao = 0.5),
              child: const SizedBox(width: 6, child: VerticalDivider(width: 6)),
            ),
          ),
          Expanded(child: _area(context, 1)),
        ],
      );
    },
  );

  /// Painel: barra de abas em cima e a tela da aba ativa. Tocar no painel o coloca em foco (o menu
  /// lateral passa a abrir módulos nele).
  Widget _area(BuildContext context, int i) {
    final p = _paineis[i];
    final ultimo = i == _paineis.length - 1;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        if (_foco != i) setState(() => _foco = i);
      },
      child: Column(
        children: [
          _BarraAbas(
            abas: p.abas,
            nome: _titulo,
            icone: (a) => a.icone ?? widget.modulos[a.modulo].icone,
            ativa: p.ativa,
            emFoco: _paineis.length > 1 && _foco == i,
            inicio: i == 0
                ? IconButton(
                    tooltip: _modoMenu.proximo.dica,
                    icon: Icon(_modoMenu.icone),
                    onPressed: () => setState(() => _modoMenu = _modoMenu.proximo),
                  )
                : null,
            fim: [
              IconButton(
                tooltip: 'Nova aba',
                icon: const Icon(Icons.add, size: 20),
                onPressed: () => setState(() => _abrir(i, p.atual.modulo)),
              ),
              if (ultimo) ...[
                _paineis.length == 1
                    ? IconButton(
                        tooltip: 'Dividir à direita',
                        icon: const Icon(Icons.vertical_split_outlined),
                        onPressed: _dividir,
                      )
                    : IconButton(tooltip: 'Juntar painéis', icon: const Icon(Icons.crop_square), onPressed: _juntar),
                ..._acoes(context),
              ],
            ],
            aoTocar: (j) => setState(() {
              p.ativa = j;
              _foco = i;
            }),
            aoFechar: (j) => _fechar(i, p.abas[j]),
            aoMenu: (j, acao) => switch (acao) {
              _AcaoAba.duplicar => setState(() {
                p.ativa = j;
                _inserir(i, p.abas[j].copia());
              }),
              _AcaoAba.mover => _mover(i, p.abas[j]),
              _AcaoAba.fecharOutras => setState(() {
                final fica = p.abas[j];
                p.abas.where((a) => a != fica).forEach(_encerrar);
                p.abas.retainWhere((a) => a == fica);
                p.ativa = 0;
              }),
              _AcaoAba.fechar => _fechar(i, p.abas[j]),
            },
            podeMover: _paineis.length > 1 || p.abas.length > 1,
            aoSoltar: (aba, posicao) => _soltar(i, aba, posicao),
          ),
          const Divider(height: 1),
          Expanded(
            child: DragTarget<_Aba>(
              onWillAcceptWithDetails: (d) => !p.abas.contains(d.data) || (_paineis.length == 1 && p.abas.length > 1),
              onAcceptWithDetails: (d) => _soltarNaTela(i, d.data),
              builder: (context, candidatas, _) => Stack(
                children: [
                  Positioned.fill(child: _corpo(p)),
                  if (candidatas.isNotEmpty)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: ColoredBox(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Nome do módulo, numerado quando há mais de uma aba dele aberta (usado enquanto a tela não
  /// define o próprio título).
  String _titulo(_Aba aba) {
    final nome = widget.modulos[aba.modulo].nome;
    final mesmas = [for (final p in _paineis) ...p.abas.where((a) => a.modulo == aba.modulo)];
    return mesmas.length == 1 ? nome : '$nome ${mesmas.indexOf(aba) + 1}';
  }

  List<Widget> _acoes(BuildContext context, {bool sino = true}) => [
    if (sino) const SinoTarefas(),
    BotaoAtualizar(api: widget.api),
    BotaoDesligarPc(api: widget.api),
    IconButton(
      tooltip: 'Modelo de IA',
      icon: const Icon(Icons.memory),
      onPressed: () => Faixa.de(context).celular
          ? Navigator.push(context, MaterialPageRoute<void>(builder: (_) => TelaLlm(api: widget.api)))
          : _abrirTela('Modelo de IA', Icons.memory, (_) => TelaLlm(api: widget.api)),
    ),
  ];

  /// Gaveta do menu: no celular abre por cima e fecha ao escolher; [fixa] fica ao lado da área.
  Widget _gaveta(BuildContext context, {bool fixa = false}) => ListenableBuilder(
    listenable: _secoes,
    builder: (context, _) => NavigationDrawer(
      elevation: fixa ? 0 : null,
      selectedIndex: _itemAtual,
      onDestinationSelected: (k) {
        final (i, j) = _itensMenu[k];
        _aoEscolherItem(k);
        // abrir/recolher o submenu mantém a gaveta aberta
        if (!fixa && (j != null || widget.modulos[i].secoes.isEmpty)) Navigator.pop(context);
      },
      children: [
        _CabecalhoUsuario(usuario: widget.usuario),
        const SizedBox(height: 8),
        for (final (i, j) in _itensMenu)
          if (j == null)
            NavigationDrawerDestination(icon: Icon(widget.modulos[i].icone), label: _rotuloModulo(i))
          else
            NavigationDrawerDestination(
              icon: Padding(
                padding: const EdgeInsets.only(left: 40),
                child: Icon(widget.modulos[i].secoes[j].icone, size: 18),
              ),
              label: Text(widget.modulos[i].secoes[j].nome),
            ),
        const Divider(),
        ListTile(leading: const Icon(Icons.logout), title: const Text('Sair'), onTap: widget.aoSair),
      ],
    ),
  );

  /// Celular e tablet em pé: uma tela por vez, barra inferior (Início, Notas, Módulos no centro,
  /// Tarefas e Mais). Some com o teclado aberto e ao rolar a tela para baixo.
  Widget _movel(BuildContext context) {
    final modulo = widget.modulos[_painel.atual.modulo];
    final teclado = MediaQuery.viewInsetsOf(context).bottom > 0;
    // Celular deitado: pouca altura, a barra vai para a lateral esquerda.
    final deitado = MediaQuery.sizeOf(context).height < 480;
    final barra = _barraMovel(context, visivel: (_barraVisivel || _maisAberto) && !teclado, vertical: deitado);
    Widget corpo = IndexedStack(
      index: _maisAberto ? 1 : 0,
      children: [
        NotificationListener<UserScrollNotification>(onNotification: _aoRolar, child: _corpo(_painel)),
        _menuMais(context),
      ],
    );
    Widget tela = Scaffold(
      appBar: _maisAberto ? null : AppBar(title: Text(modulo.nome), actions: _acoes(context, sino: false)),
      body: corpo,
      bottomNavigationBar: deitado ? null : barra,
    );
    // Deitado, a barra fica fora do Scaffold (como um NavigationRail): avisos e AppBar só cobrem o módulo.
    if (deitado) {
      tela = Row(
        children: [
          SafeArea(right: false, child: barra),
          const VerticalDivider(width: 1),
          Expanded(child: tela),
        ],
      );
    }
    return PopScope(
      // Voltar do sistema com o "Mais" aberto volta para a tela do módulo.
      canPop: !_maisAberto,
      onPopInvokedWithResult: (saiu, _) {
        if (!saiu) setState(() => _maisAberto = false);
      },
      child: tela,
    );
  }

  Widget _barraMovel(BuildContext context, {required bool visivel, required bool vertical}) {
    final atual = _painel.atual.modulo;
    final notas = _indiceNotas;
    return _BarraInferior(
      visivel: visivel || vertical,
      vertical: vertical,
      itens: [
        _ItemBarra(
          icone: const Icon(Icons.home_outlined),
          rotulo: 'Início',
          selecionado: !_maisAberto && atual == 0,
          aoTocar: () => _irNaBarra(0),
        ),
        if (notas != null)
          _ItemBarra(
            icone: Icon(widget.modulos[notas].icone),
            rotulo: widget.modulos[notas].nome,
            selecionado: !_maisAberto && atual == notas,
            aoTocar: () => _irNaBarra(notas),
          ),
        _ItemBarra(
          icone: const _IconeTarefas(),
          rotulo: 'Tarefas',
          selecionado: false,
          aoTocar: () => SinoTarefas.abrir(context),
        ),
        _ItemBarra(
          icone: const Icon(Icons.menu),
          rotulo: 'Mais',
          selecionado: _maisAberto,
          aoTocar: () => setState(() => _maisAberto = true),
        ),
      ],
      central: _ItemBarra(
        icone: const Icon(Icons.apps),
        rotulo: 'Módulos',
        selecionado: false,
        aoTocar: () => _abrirAtalhos(context),
      ),
    );
  }

  /// Posição do módulo de notas, atalho fixo da barra inferior.
  int? get _indiceNotas {
    final i = widget.modulos.indexWhere((m) => m.id == 'notas');
    if (i > 0) return i;
    return null;
  }

  bool _aoRolar(UserScrollNotification n) {
    if (n.metrics.axis != Axis.vertical || n.direction == ScrollDirection.idle) return false;
    final visivel = n.direction == ScrollDirection.forward;
    if (visivel != _barraVisivel) setState(() => _barraVisivel = visivel);
    return false;
  }

  /// Barra inferior e menu "Mais": fecha o "Mais" e abre o módulo (ou a seção).
  void _irNaBarra(int modulo, [int? secao]) {
    setState(() {
      _maisAberto = false;
      _barraVisivel = true;
    });
    if (secao == null) {
      _irPara(modulo);
    } else {
      _irParaSecao(modulo, secao);
    }
  }

  /// Botão central: grade com todos os módulos.
  void _abrirAtalhos(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (folha) => SafeArea(
      child: GridView.extent(
        shrinkWrap: true,
        maxCrossAxisExtent: 110,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
        children: [for (final (i, m) in widget.modulos.indexed) _atalho(folha, i, m)],
      ),
    ),
  );

  Widget _atalho(BuildContext folha, int i, Modulo m) {
    final cores = Theme.of(folha).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        Navigator.pop(folha);
        _irNaBarra(i);
      },
      child: Opacity(
        opacity: m.disponivel ? 1 : 0.55,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 6,
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: cores.primaryContainer,
              child: Icon(m.icone, color: cores.onPrimaryContainer),
            ),
            Text(m.nome, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  /// Aba "Mais": usuário no topo, módulos com submenus que abrem no lugar e as ações do sistema.
  Widget _menuMais(BuildContext context) => ListenableBuilder(
    listenable: _secoes,
    builder: (context, _) {
      final itens = _itensMenu;
      final atual = _maisAberto ? null : itens[_itemAtual];
      // Lista curta: Column montada inteira (a ListView preguiçosa não monta os itens fora da tela).
      return SingleChildScrollView(
        child: Column(
          children: [
            _CabecalhoUsuario(usuario: widget.usuario, topoSeguro: true),
            for (final (i, j) in itens) _itemMais(i, j, (i, j) == atual),
            const Divider(indent: 16, endIndent: 16),
            ListTile(
              leading: const Icon(Icons.memory),
              title: const Text('Modelo de IA'),
              onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => TelaLlm(api: widget.api))),
            ),
            ListTile(leading: const Icon(Icons.logout), title: const Text('Sair'), onTap: widget.aoSair),
          ],
        ),
      );
    },
  );

  Widget _itemMais(int i, int? j, bool selecionado) {
    final m = widget.modulos[i];
    if (j != null) {
      return ListTile(
        contentPadding: const EdgeInsets.only(left: 56, right: 16),
        leading: Icon(m.secoes[j].icone, size: 20),
        title: Text(m.secoes[j].nome),
        selected: selecionado,
        onTap: () => _irNaBarra(i, j),
      );
    }
    Widget? fim;
    if (m.secoes.isNotEmpty) fim = Icon(_expandidos.contains(i) ? Icons.expand_less : Icons.expand_more);
    return ListTile(
      leading: Icon(m.icone),
      title: Opacity(opacity: m.disponivel ? 1 : 0.55, child: Text(m.nome)),
      trailing: fim,
      selected: selecionado,
      onTap: () => _tocarModuloMais(i),
    );
  }

  /// Módulo com submenu só abre ou recolhe as seções; sem submenu, abre o módulo.
  void _tocarModuloMais(int i) {
    if (widget.modulos[i].secoes.isEmpty) return _irNaBarra(i);
    setState(() {
      if (!_expandidos.remove(i)) _expandidos.add(i);
    });
  }

  /// Item do menu lateral: o módulo ou, recuada e menor, uma seção do submenu dele.
  NavigationRailDestination _destino(Modulo m, int? secao) {
    final nome = secao == null ? m.nome : m.secoes[secao].nome;
    Widget icone = secao == null ? Icon(m.icone) : Icon(m.secoes[secao].icone, size: 18);
    // Só ícones: o nome aparece ao passar o mouse.
    if (_modoMenu == _ModoMenu.icones) icone = Tooltip(message: nome, child: icone);
    return NavigationRailDestination(
      icon: icone,
      label: secao == null
          ? _rotuloModulo(widget.modulos.indexOf(m))
          : Text(nome, style: const TextStyle(fontSize: 13)),
    );
  }

  /// Nome do módulo; com submenu, uma seta indica se está aberto ou recolhido.
  Widget _rotuloModulo(int i) {
    final m = widget.modulos[i];
    final texto = Opacity(opacity: m.disponivel ? 1 : 0.55, child: Text(m.nome));
    if (m.secoes.isEmpty) return texto;
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [texto, Icon(_expandidos.contains(i) ? Icons.expand_less : Icons.expand_more, size: 18)],
    );
  }
}

/// Navegador próprio da aba de uma tela: `Navigator.pop` dentro dela fecha a aba (com o resultado)
/// e `pushReplacement` troca a tela sem fechar.
class _NavegadorAba extends StatefulWidget {
  const _NavegadorAba({required this.tela, required this.titulo, required this.aoSair});

  final WidgetBuilder tela;
  final ValueNotifier<String?> titulo;
  final void Function(Future<Object?> resultado) aoSair;

  @override
  State<_NavegadorAba> createState() => _NavegadorAbaState();
}

class _NavegadorAbaState extends State<_NavegadorAba> {
  // fica por baixo da tela para o pop não esvaziar o navegador
  final _base = PageRouteBuilder<void>(pageBuilder: (_, _, _) => const SizedBox());
  late final _observador = _AoSair(_base, (r) => widget.aoSair(r));
  late final _semTitulo = widget.titulo.value == null;
  late final Timer _depois;

  @override
  void initState() {
    super.initState();
    // a tela costuma carregar o nome depois: olha de novo um pouco mais tarde
    WidgetsBinding.instance.addPostFrameCallback((_) => _tituloDaTela());
    _depois = Timer(const Duration(seconds: 2), _tituloDaTela);
  }

  @override
  void dispose() {
    _depois.cancel();
    super.dispose();
  }

  /// Sem título dado por quem abriu (nem pela tela, via [TituloAba]), usa o texto da AppBar.
  void _tituloDaTela() {
    if (!mounted || !_semTitulo) return;
    String? achado;
    void visitar(Element e) {
      final w = e.widget;
      if (w is AppBar) {
        if (w.title is Text) achado = (w.title! as Text).data;
        return;
      }
      if (achado == null) e.visitChildren(visitar);
    }

    context.visitChildElements(visitar);
    if (achado != null && achado!.isNotEmpty) widget.titulo.value = achado;
  }

  @override
  Widget build(BuildContext context) => Navigator(
    observers: [_observador],
    onGenerateInitialRoutes: (_, _) => [_base, MaterialPageRoute<Object?>(builder: widget.tela)],
  );
}

class _AoSair extends NavigatorObserver {
  _AoSair(this.base, this.aoSair);

  final Route<void> base;
  final void Function(Future<Object?> resultado) aoSair;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute == base) aoSair(route.popped);
  }
}

/// Menu lateral: completo (ícone e nome), só ícones ou oculto; o botão das abas alterna nessa ordem.
enum _ModoMenu {
  completo('Menu completo', Icons.menu_open),
  icones('Só ícones no menu', Icons.view_sidebar_outlined),
  oculto('Ocultar menu', Icons.menu);

  const _ModoMenu(this.dica, this.icone);

  final String dica;
  final IconData icone;

  _ModoMenu get proximo => values[(index + 1) % values.length];
}

/// Topo do menu (lateral e "Mais"): avatar com a inicial e o nome do usuário sobre a cor do tema.
class _CabecalhoUsuario extends StatelessWidget {
  const _CabecalhoUsuario({required this.usuario, this.topoSeguro = false});

  final String usuario;

  /// No "Mais" não há AppBar: o cabeçalho desce abaixo da barra de status.
  final bool topoSeguro;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: NomeUsuario.nome,
      builder: (context, escolhido, _) => _conteudo(context, escolhido.isNotEmpty ? escolhido : usuario),
    );
  }

  Widget _conteudo(BuildContext context, String usuario) {
    final cores = Theme.of(context).colorScheme;
    final nome = usuario.isEmpty ? 'Solumia' : usuario;
    return ColoredBox(
      color: cores.primaryContainer,
      child: SafeArea(
        top: topoSeguro,
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 16, 20),
          child: Row(
            spacing: 14,
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: cores.primary,
                foregroundColor: cores.onPrimary,
                child: Text(nome.characters.first.toUpperCase(), style: const TextStyle(fontSize: 22)),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      nome,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(color: cores.onPrimaryContainer),
                    ),
                    Text('Solumia', style: TextStyle(color: cores.onPrimaryContainer.withValues(alpha: 0.7))),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ItemBarra {
  const _ItemBarra({required this.icone, required this.rotulo, required this.selecionado, required this.aoTocar});

  final Widget icone;
  final String rotulo;
  final bool selecionado;
  final VoidCallback aoTocar;
}

/// Barra inferior do celular e do tablet em pé: itens divididos dos dois lados e um botão redondo
/// em destaque no centro. Recolhe com animação quando [visivel] é falso.
class _BarraInferior extends StatelessWidget {
  const _BarraInferior({required this.itens, required this.central, required this.visivel, this.vertical = false});

  final List<_ItemBarra> itens;
  final _ItemBarra central;
  final bool visivel;

  /// Na lateral esquerda (celular deitado), sempre visível.
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    final metade = (itens.length + 1) ~/ 2;
    final linha = <Widget>[];
    for (var k = 0; k < itens.length; k++) {
      if (k == metade) linha.add(Expanded(child: _Central(item: central)));
      linha.add(Expanded(child: _BotaoBarra(item: itens[k])));
    }
    if (vertical) {
      return Material(
        color: cores.surfaceContainer,
        child: SizedBox(width: 76, child: Column(children: linha)),
      );
    }
    return ClipRect(
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        alignment: Alignment.topCenter,
        heightFactor: visivel ? 1 : 0,
        child: Material(
          color: cores.surfaceContainer,
          elevation: 3,
          child: SizedBox(height: 68, child: Row(children: linha)),
        ),
      ),
    );
  }
}

class _BotaoBarra extends StatelessWidget {
  const _BotaoBarra({required this.item});

  final _ItemBarra item;

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    final cor = item.selecionado ? cores.primary : cores.onSurfaceVariant;
    return InkWell(
      onTap: item.aoTocar,
      child: IconTheme.merge(
        data: IconThemeData(color: cor, size: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 4,
          children: [
            item.icone,
            Text(
              item.rotulo,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: cor,
                fontWeight: item.selecionado ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Botão redondo do centro da barra.
class _Central extends StatelessWidget {
  const _Central({required this.item});

  final _ItemBarra item;

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    return Center(
      child: Tooltip(
        message: item.rotulo,
        child: Material(
          color: cores.primary,
          shape: const CircleBorder(),
          elevation: 4,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: item.aoTocar,
            child: SizedBox(
              width: 54,
              height: 54,
              child: IconTheme.merge(
                data: IconThemeData(color: cores.onPrimary, size: 28),
                child: item.icone,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Ícone das tarefas em segundo plano com o contador das que estão rodando.
class _IconeTarefas extends StatelessWidget {
  const _IconeTarefas();

  @override
  Widget build(BuildContext context) {
    final tarefas = Tarefas.instancia;
    return ListenableBuilder(
      listenable: tarefas,
      builder: (context, _) => Badge(
        isLabelVisible: tarefas.rodando > 0 || tarefas.novas > 0,
        label: tarefas.rodando > 0 ? Text('${tarefas.rodando}') : null,
        child: Icon(tarefas.rodando > 0 ? Icons.notifications_active_outlined : Icons.notifications_none),
      ),
    );
  }
}

enum _AcaoAba { duplicar, mover, fecharOutras, fechar }

/// Faixa de abas de um painel: rola na horizontal quando não cabe; botão do meio fecha a aba e o
/// botão direito abre o menu (duplicar, mover para o outro painel, fechar). As abas podem ser
/// arrastadas para reordenar, para a barra do outro painel ou para a tela (abre ao lado).
class _BarraAbas extends StatelessWidget {
  const _BarraAbas({
    required this.abas,
    required this.nome,
    required this.icone,
    required this.ativa,
    required this.emFoco,
    required this.inicio,
    required this.fim,
    required this.aoTocar,
    required this.aoFechar,
    required this.aoMenu,
    required this.podeMover,
    required this.aoSoltar,
  });

  final List<_Aba> abas;
  final String Function(_Aba) nome;
  final IconData Function(_Aba) icone;
  final int ativa;
  final bool emFoco;
  final Widget? inicio;
  final List<Widget> fim;
  final ValueChanged<int> aoTocar;
  final ValueChanged<int> aoFechar;
  final void Function(int, _AcaoAba) aoMenu;
  final bool podeMover;

  /// Aba solta antes da posição dada (o fim da barra solta no final).
  final void Function(_Aba, int) aoSoltar;

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          ?inicio,
          Expanded(
            child: DragTarget<_Aba>(
              onAcceptWithDetails: (d) => aoSoltar(d.data, abas.length),
              builder: (context, _, _) => ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: abas.length,
                itemBuilder: (context, j) => DragTarget<_Aba>(
                  onWillAcceptWithDetails: (d) => d.data != abas[j],
                  onAcceptWithDetails: (d) => aoSoltar(d.data, j),
                  builder: (context, candidatas, _) => _aba(context, cores, j, candidatas.isNotEmpty),
                ),
              ),
            ),
          ),
          ...fim,
        ],
      ),
    );
  }

  Widget _aba(BuildContext context, ColorScheme cores, int j, bool alvo) {
    final aba = abas[j];
    final selecionada = j == ativa;
    final rotulo = ValueListenableBuilder(
      valueListenable: aba.titulo,
      builder: (context, titulo, _) => Text(titulo ?? nome(aba), overflow: TextOverflow.ellipsis),
    );
    return Draggable<_Aba>(
      data: aba,
      feedback: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(6),
        color: cores.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 8,
            children: [
              Icon(icone(aba), size: 16),
              ConstrainedBox(constraints: const BoxConstraints(maxWidth: 200), child: rotulo),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: _conteudo(context, cores, j, selecionada, alvo, rotulo)),
      child: _conteudo(context, cores, j, selecionada, alvo, rotulo),
    );
  }

  Widget _conteudo(BuildContext context, ColorScheme cores, int j, bool selecionada, bool alvo, Widget rotulo) =>
      GestureDetector(
        onTertiaryTapUp: (_) => aoFechar(j),
        onSecondaryTapUp: (d) => _menu(context, j, d.globalPosition),
        child: InkWell(
          onTap: () => aoTocar(j),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 220),
            padding: const EdgeInsets.only(left: 12, right: 4),
            decoration: BoxDecoration(
              color: selecionada ? cores.surfaceContainerHigh : null,
              border: Border(
                // Linha à esquerda: onde a aba arrastada vai entrar.
                left: BorderSide(width: 2, color: alvo ? cores.primary : Colors.transparent),
                bottom: BorderSide(
                  width: 2,
                  color: selecionada ? (emFoco ? cores.primary : cores.outline) : Colors.transparent,
                ),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 8,
              children: [
                Icon(icone(abas[j]), size: 16, color: selecionada ? cores.primary : cores.onSurfaceVariant),
                Flexible(child: rotulo),
                IconButton(
                  tooltip: 'Fechar aba',
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  icon: const Icon(Icons.close),
                  onPressed: () => aoFechar(j),
                ),
              ],
            ),
          ),
        ),
      );

  Future<void> _menu(BuildContext context, int j, Offset pos) async {
    final acao = await showMenu<_AcaoAba>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: [
        const PopupMenuItem(value: _AcaoAba.duplicar, child: Text('Nova aba deste módulo')),
        if (podeMover) const PopupMenuItem(value: _AcaoAba.mover, child: Text('Mover para o outro lado')),
        if (abas.length > 1) const PopupMenuItem(value: _AcaoAba.fecharOutras, child: Text('Fechar as outras')),
        const PopupMenuItem(value: _AcaoAba.fechar, child: Text('Fechar')),
      ],
    );
    if (acao != null) aoMenu(j, acao);
  }
}
