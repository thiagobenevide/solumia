import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../api_concursos.dart';
import '../modelos.dart';

/// Cor do local de prova pela distância de carro desde a origem.
Color corDistancia(int? km) => km == null
    ? Colors.blueGrey
    : km <= 300
    ? const Color(0xFF2E7D32)
    : km <= 800
    ? const Color(0xFFEF6C00)
    : const Color(0xFFC62828);

LatLng _ll(Local l) => LatLng(l.lat, l.lon);

/// Radar de concursos de TI abertos no Brasil: mapa com a sua cidade, o local de prova mais próximo
/// de cada concurso e a rota de carro até ele; lista/detalhe ao lado com vagas, salários, inscrições,
/// prova e links, e o botão que já começa o acompanhamento (fluxo de estudo pelo Claude).
class RadarTela extends StatefulWidget {
  const RadarTela({super.key, required this.api, required this.aoAcompanhar, this.mapaBase = true});

  final ApiConcursos api;

  /// Chamado com o id do concurso criado (a tela de listagem abre o concurso).
  final void Function(String id) aoAcompanhar;

  /// Tiles do mapa (os testes desligam: sem rede).
  final bool mapaBase;

  @override
  State<RadarTela> createState() => _RadarTelaState();
}

class _RadarTelaState extends State<RadarTela> {
  final _mapa = MapController();
  final _rotas = <String, Rota>{};
  String? _selecionado;
  bool _pronto = false;
  // No celular a lista fica oculta para o mapa ocupar a tela; abre pelo botão ou ao tocar num pino.
  bool _listaAberta = false;
  final _esferas = <String>{};

  ApiConcursos get api => widget.api;

  Future<void> _selecionar(ItemRadar? item, Local? origem) async {
    setState(() => _selecionado = item?.id);
    if (item == null || origem == null) {
      if (_pronto) _mapa.move(const LatLng(-14.2, -51.9), 4);
      return;
    }
    final destino = item.maisProximo ?? item.sede;
    if (destino == null) return;
    var pontos = [_ll(origem), _ll(destino)];
    if (item.maisProximo != null && !_rotas.containsKey(item.id)) {
      try {
        final r = await api.rota(item.id);
        if (mounted) setState(() => _rotas[item.id] = r);
      } catch (_) {
        // sem rota: fica a linha reta
      }
    }
    final rota = _rotas[item.id];
    if (rota != null && rota.pontos.length > 1) pontos = [for (final (la, lo) in rota.pontos) LatLng(la, lo)];
    if (_pronto && mounted) {
      _mapa.fitCamera(CameraFit.bounds(
        bounds: LatLngBounds.fromPoints([...pontos, if (item.sede != null) _ll(item.sede!)]),
        padding: const EdgeInsets.fromLTRB(60, 110, 60, 60),
        maxZoom: 9,
      ));
    }
  }

  Future<void> _acompanhar(ItemRadar item) async {
    final cargo = await showDialog<String>(context: context, builder: (_) => _EscolherCargo(item: item));
    if (cargo == null || !mounted) return;
    try {
      final id = await api.acompanhar(item.id, cargo);
      widget.aoAcompanhar(id);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) => Sondagem<Radar>(
    intervalo: const Duration(seconds: 20),
    carregar: api.radar,
    construir: (context, todos, recarregar) {
      final radar = todos.soEsferas(_esferas);
      final item = radar.itens.where((i) => i.id == _selecionado).firstOrNull;
      final mapa = _Mapa(
        controle: _mapa,
        radar: radar,
        selecionado: item,
        rota: item == null ? null : _rotas[item.id],
        mapaBase: widget.mapaBase,
        aoPronto: () => _pronto = true,
        filtro: _FiltroEsfera(
          todos: todos,
          esferas: _esferas,
          aoMudar: (e, sim) => setState(() => sim ? _esferas.add(e) : _esferas.remove(e)),
        ),
        aoTocar: (i) => _selecionar(i, radar.origem),
        atualizar: () async {
          await api.atualizarRadar();
          await recarregar();
        },
        pesquisarClaude: () async {
          try {
            await api.pesquisarRadarClaude();
          } catch (e) {
            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
          }
          await recarregar();
        },
      );
      final painel = item == null
          ? _Lista(radar: radar, aoTocar: (i) => _selecionar(i, radar.origem))
          : _Detalhe(
              item: item,
              origem: radar.origem,
              rota: _rotas[item.id],
              voltar: () => _selecionar(null, null),
              acompanhar: () => _acompanhar(item),
            );
      return LayoutBuilder(builder: (context, c) {
        if (c.maxWidth >= 1000) {
          return Row(children: [
            Expanded(child: mapa),
            SizedBox(width: c.maxWidth >= 1500 ? 480 : 420, child: Material(elevation: 2, child: painel)),
          ]);
        }
        if (item == null && !_listaAberta) {
          return Stack(children: [
            Positioned.fill(child: mapa),
            Positioned(
              left: 0,
              right: 0,
              bottom: 16,
              child: Center(
                child: FloatingActionButton.extended(
                  heroTag: null,
                  onPressed: () => setState(() => _listaAberta = true),
                  icon: const Icon(Icons.list),
                  label: Text('Lista · ${radar.itens.length}'),
                ),
              ),
            ),
          ]);
        }
        return Column(children: [
          SizedBox(height: c.maxHeight * (item == null ? .5 : .42), child: mapa),
          if (item == null)
            Material(
              elevation: 2,
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.expand_more),
                title: const Text('Ocultar lista'),
                onTap: () => setState(() => _listaAberta = false),
              ),
            ),
          Expanded(child: Material(elevation: 2, child: painel)),
        ]);
      });
    },
  );
}

class _Mapa extends StatelessWidget {
  const _Mapa({
    required this.controle,
    required this.radar,
    required this.selecionado,
    required this.rota,
    required this.mapaBase,
    required this.aoPronto,
    required this.filtro,
    required this.aoTocar,
    required this.atualizar,
    required this.pesquisarClaude,
  });

  final Future<void> Function() pesquisarClaude;
  final MapController controle;
  final Radar radar;
  final ItemRadar? selecionado;
  final Rota? rota;
  final bool mapaBase;
  final VoidCallback aoPronto;
  final Widget filtro;
  final void Function(ItemRadar?) aoTocar;
  final Future<void> Function() atualizar;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final escuro = tema.brightness == Brightness.dark;
    final origem = radar.origem;
    final sel = selecionado;
    final destinoSel = sel?.maisProximo ?? sel?.sede;
    final linha = rota != null && rota!.pontos.length > 1
        ? [for (final (la, lo) in rota!.pontos) LatLng(la, lo)]
        : (origem != null && destinoSel != null ? [_ll(origem), _ll(destinoSel)] : <LatLng>[]);
    return Stack(
      children: [
        FlutterMap(
          mapController: controle,
          options: MapOptions(
            initialCenter: const LatLng(-14.2, -51.9),
            initialZoom: 4,
            minZoom: 3,
            maxZoom: 16,
            backgroundColor: escuro ? const Color(0xFF1B1F24) : const Color(0xFFE8EEF2),
            onMapReady: aoPronto,
            onTap: (_, _) => aoTocar(null),
            interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
          ),
          children: [
            if (mapaBase)
              TileLayer(
                // CARTO passou a exigir chave; OSM não pede (no tema escuro, as cores são invertidas)
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                tileBuilder: escuro ? darkModeTileBuilder : null,
                userAgentPackageName: 'agent.concursos',
              ),
            if (linha.length > 1)
              PolylineLayer(polylines: [
                Polyline(
                  points: linha,
                  strokeWidth: 5,
                  color: tema.colorScheme.primary,
                  borderStrokeWidth: 3,
                  borderColor: escuro ? Colors.black87 : Colors.white,
                  pattern: rota == null || rota!.estimada
                      ? StrokePattern.dashed(segments: const [12, 8])
                      : const StrokePattern.solid(),
                ),
              ]),
            MarkerLayer(markers: [
              // outros locais de prova do selecionado (menores)
              if (sel != null)
                for (final l in sel.locais.where((l) => l.nome != destinoSel?.nome))
                  Marker(
                    point: _ll(l),
                    width: 14,
                    height: 14,
                    child: Tooltip(
                      message: '${l.nome} · ${l.km ?? l.kmReta} km',
                      child: _Ponto(cor: corDistancia(l.km ?? l.kmReta), tamanho: 12),
                    ),
                  ),
              // sede do órgão, quando não é o local de prova
              if (sel?.sede != null && sel!.sede!.nome != destinoSel?.nome)
                Marker(
                  point: _ll(sel.sede!),
                  width: 300,
                  height: 76,
                  alignment: Alignment.topCenter,
                  child: _Rotulado(
                    icone: Icons.account_balance,
                    cor: const Color(0xFF6A1B9A),
                    texto: 'Sede · ${sel.sede!.nome}',
                  ),
                ),
              // um pino por concurso (local de prova mais próximo ou sede)
              for (final i in radar.itens)
                if ((i.maisProximo ?? i.sede) case final Local l)
                  Marker(
                    point: _ll(l),
                    width: i.id == sel?.id ? 300 : 44,
                    height: i.id == sel?.id ? 82 : 44,
                    alignment: Alignment.topCenter,
                    child: GestureDetector(
                      onTap: () => aoTocar(i),
                      child: i.id == sel?.id
                          ? _Rotulado(
                              icone: Icons.place,
                              cor: corDistancia(l.km),
                              texto: 'Prova · ${l.nome}',
                              grande: true,
                            )
                          : Tooltip(
                              message: '${i.orgao}\n${i.totalVagas} vaga(s) de TI · ${l.nome} · ${l.km ?? '?'} km',
                              child: _Pino(cor: corDistancia(l.km), vagas: i.totalVagas),
                            ),
                    ),
                  ),
              // você
              if (origem != null)
                Marker(
                  point: _ll(origem),
                  width: 300,
                  height: 82,
                  alignment: Alignment.topCenter,
                  child: _Rotulado(icone: Icons.home, cor: const Color(0xFF1565C0), texto: 'Você · ${origem.nome}', grande: true),
                ),
              // distância no meio do caminho
              if (sel != null && linha.length > 1 && rota != null)
                Marker(
                  point: linha[linha.length ~/ 2],
                  width: 150,
                  height: 34,
                  child: _Etiqueta(texto: '${rota!.estimada ? '≈ ' : ''}${rota!.km} km · ${duracao(rota!.horas)}'),
                ),
            ]),
            if (mapaBase)
              const RichAttributionWidget(
                alignment: AttributionAlignment.bottomLeft,
                attributions: [TextSourceAttribution('OpenStreetMap'), TextSourceAttribution('OSRM')],
              ),
          ],
        ),
        Positioned(top: 12, left: 12, right: 12, child: _Barra(radar: radar, filtro: filtro, atualizar: atualizar, pesquisarClaude: pesquisarClaude)),
        const Positioned(bottom: 28, right: 12, child: _Legenda()),
      ],
    );
  }
}

/// Card do topo do mapa: título e filtro sempre; o status (LLM, erros, Claude) só aberto, para não cobrir o mapa.
class _Barra extends StatefulWidget {
  const _Barra({required this.radar, required this.filtro, required this.atualizar, required this.pesquisarClaude});

  final Radar radar;
  final Widget filtro;
  final Future<void> Function() atualizar;
  final Future<void> Function() pesquisarClaude;

  @override
  State<_Barra> createState() => _BarraState();
}

class _BarraState extends State<_Barra> {
  bool _aberto = false;

  @override
  Widget build(BuildContext context) {
    final _Barra(:radar, :filtro, :atualizar, :pesquisarClaude) = widget;
    final tema = Theme.of(context);
    final temErro = radar.erro.isNotEmpty || radar.claudeErro.isNotEmpty;
    Text linha(String t, {bool erro = false}) => Text(
      t,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: erro ? TextStyle(color: tema.colorScheme.error, fontSize: 12) : tema.textTheme.bodySmall,
    );
    final quando = radar.atualizado == null
        ? 'ainda não coletado'
        : 'atualizado ${dataBr(radar.atualizado, curta: true)} ${radar.atualizado!.substring(11, 16)} UTC';
    return Align(
      alignment: Alignment.topLeft,
      child: Card(
        elevation: 3,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.radar, color: tema.colorScheme.primary),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    InkWell(
                      onTap: () => setState(() => _aberto = !_aberto),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(child: Text('Concursos de TI abertos · ${radar.itens.length}', style: tema.textTheme.titleSmall)),
                          if (temErro && !_aberto) ...[
                            const SizedBox(width: 4),
                            Icon(Icons.error_outline, size: 16, color: tema.colorScheme.error),
                          ],
                          Icon(_aberto ? Icons.expand_less : Icons.expand_more, size: 20),
                        ],
                      ),
                    ),
                    if (_aberto) ...[
                      linha(
                        radar.coletando
                            ? 'A LLM local está lendo os editais…${radar.pendentes > 0 ? ' (${radar.pendentes} na fila)' : ''}'
                            : '$quando${radar.pendentes > 0 ? ' · ${radar.pendentes} na fila' : ''}',
                      ),
                      if (radar.erro.isNotEmpty) linha(radar.erro, erro: true),
                      if (radar.pesquisandoClaude)
                        linha('O Claude está pesquisando na internet (alguns minutos)…')
                      else if (radar.claudeErro.isNotEmpty)
                        linha('Claude: ${radar.claudeErro}', erro: true)
                      else if (radar.claudeEm != null)
                        linha('Claude: ${radar.claudeAchados} achado(s) em ${dataBr(radar.claudeEm, curta: true)}'),
                    ],
                    // Em tela estreita o filtro só aparece com o cartão aberto, para não cobrir o mapa.
                    if (_aberto || MediaQuery.sizeOf(context).width >= 700) filtro,
                  ],
                ),
              ),
              radar.coletando
                  ? const Padding(padding: EdgeInsets.all(12), child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                  : IconButton(tooltip: 'Buscar agora (PCI + LLM local)', icon: const Icon(Icons.refresh), onPressed: atualizar),
              radar.pesquisandoClaude
                  ? const Padding(padding: EdgeInsets.all(12), child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                  : IconButton(tooltip: 'Pesquisar com o Claude (internet: abertos e previstos)', icon: const Icon(Icons.travel_explore), onPressed: pesquisarClaude),
            ],
          ),
        ),
      ),
    );
  }
}

/// Chips Federal / Estadual / Municipal (nenhum marcado = todos), com a contagem de cada um.
class _FiltroEsfera extends StatelessWidget {
  const _FiltroEsfera({required this.todos, required this.esferas, required this.aoMudar});

  final Radar todos;
  final Set<String> esferas;
  final void Function(String esfera, bool marcado) aoMudar;

  static const _rotulos = {'federal': 'Federais', 'estadual': 'Estaduais', 'municipal': 'Municipais'};

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: [
          for (final MapEntry(key: e, value: rotulo) in _rotulos.entries)
            FilterChip(
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              label: Text('$rotulo · ${todos.itens.where((i) => i.esfera == e).length}'),
              selected: esferas.contains(e),
              onSelected: (sim) => aoMudar(e, sim),
            ),
        ],
      ),
    ),
  );
}

/// Legenda recolhível: em tela estreita começa fechada (só o botão), para não cobrir o mapa.
class _Legenda extends StatefulWidget {
  const _Legenda();

  @override
  State<_Legenda> createState() => _LegendaState();
}

class _LegendaState extends State<_Legenda> {
  bool? _aberta;

  @override
  Widget build(BuildContext context) {
    final aberta = _aberta ?? MediaQuery.sizeOf(context).width >= 700;
    if (!aberta) {
      return FloatingActionButton.small(
        heroTag: null,
        tooltip: 'Legenda',
        onPressed: () => setState(() => _aberta = true),
        child: const Icon(Icons.info_outline),
      );
    }
    Widget item(Color c, String t) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(mainAxisSize: MainAxisSize.min, children: [_Ponto(cor: c, tamanho: 10), const SizedBox(width: 6), Text(t, style: const TextStyle(fontSize: 12))]),
    );
    return Card(
      elevation: 2,
      child: InkWell(
        onTap: () => setState(() => _aberta = false),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              item(const Color(0xFF1565C0), 'Você'),
              item(corDistancia(1), 'Prova até 300 km'),
              item(corDistancia(500), '300–800 km'),
              item(corDistancia(900), 'Mais de 800 km'),
              item(const Color(0xFF6A1B9A), 'Sede do órgão'),
            ],
          ),
        ),
      ),
    );
  }
}

class _Ponto extends StatelessWidget {
  const _Ponto({required this.cor, required this.tamanho});

  final Color cor;
  final double tamanho;

  @override
  Widget build(BuildContext context) => Container(
    width: tamanho,
    height: tamanho,
    decoration: BoxDecoration(color: cor, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
  );
}

/// Pino com o número de vagas de TI.
class _Pino extends StatelessWidget {
  const _Pino({required this.cor, required this.vagas});

  final Color cor;
  final int vagas;

  @override
  Widget build(BuildContext context) => Stack(
    alignment: Alignment.topCenter,
    children: [
      Icon(Icons.location_on, size: 44, color: cor, shadows: const [Shadow(blurRadius: 6, color: Colors.black38)]),
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Container(
          width: 20,
          height: 20,
          alignment: Alignment.center,
          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
          child: Text('$vagas', style: TextStyle(fontSize: vagas > 99 ? 8 : 11, fontWeight: FontWeight.bold, color: cor)),
        ),
      ),
    ],
  );
}

/// Ícone com um rótulo em pílula embaixo (você, sede, local de prova selecionado).
class _Rotulado extends StatelessWidget {
  const _Rotulado({required this.icone, required this.cor, required this.texto, this.grande = false});

  final IconData icone;
  final Color cor;
  final String texto;
  final bool grande;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        padding: EdgeInsets.all(grande ? 7 : 5),
        decoration: BoxDecoration(
          color: cor,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2.5),
          boxShadow: const [BoxShadow(blurRadius: 8, color: Colors.black38)],
        ),
        child: Icon(icone, size: grande ? 22 : 16, color: Colors.white),
      ),
      const SizedBox(height: 3),
      Flexible(child: _Etiqueta(texto: texto, cor: cor)),
    ],
  );
}

class _Etiqueta extends StatelessWidget {
  const _Etiqueta({required this.texto, this.cor});

  final String texto;
  final Color? cor;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: tema.colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cor ?? tema.colorScheme.primary, width: 1.5),
          boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
        ),
        child: Text(
          texto,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: cor ?? tema.colorScheme.primary),
        ),
      ),
    );
  }
}

class _Lista extends StatelessWidget {
  const _Lista({required this.radar, required this.aoTocar});

  final Radar radar;
  final void Function(ItemRadar) aoTocar;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    if (radar.itens.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            radar.coletando
                ? 'Buscando concursos de TI… a LLM local lê cada edital (alguns minutos).'
                : 'Nenhum concurso de TI com inscrição aberta encontrado ainda. Toque em ↻ no mapa para buscar agora '
                      'ou na lupa de globo para o Claude pesquisar na internet (abertos e previstos); '
                      'a busca do PCI também roda sozinha a cada 6 horas.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: radar.itens.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, n) {
        final i = radar.itens[n];
        final l = i.maisProximo;
        return ListTile(
          onTap: () => aoTocar(i),
          leading: CircleAvatar(
            backgroundColor: corDistancia(l?.km).withValues(alpha: .15),
            child: Text('${i.totalVagas}', style: TextStyle(color: corDistancia(l?.km), fontWeight: FontWeight.bold)),
          ),
          title: Text(i.orgao, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [
              [if (i.banca.isNotEmpty) i.banca, if (i.salarioMax > 0) 'até ${reais(i.salarioMax)}'].join(' · '),
              'Inscrições até ${dataBr(i.inscricoesFim)}${i.dataProva.isEmpty ? '' : ' · prova ${dataBr(i.dataProva)}'}',
            ].where((s) => s.isNotEmpty).join('\n'),
          ),
          isThreeLine: true,
          trailing: l == null
              ? null
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('${l.km ?? l.kmReta} km', style: tema.textTheme.titleSmall?.copyWith(color: corDistancia(l.km))),
                    Text(l.nome, style: tema.textTheme.bodySmall),
                  ],
                ),
        );
      },
    );
  }
}

class _Detalhe extends StatelessWidget {
  const _Detalhe({required this.item, required this.origem, required this.rota, required this.voltar, required this.acompanhar});

  final ItemRadar item;
  final Local? origem;
  final Rota? rota;
  final VoidCallback voltar;
  final VoidCallback acompanhar;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final l = item.maisProximo;
    final km = rota?.km ?? l?.km;
    final horas = rota?.horas ?? l?.horas;
    Widget secao(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Text(t.toUpperCase(), style: tema.textTheme.labelMedium?.copyWith(color: tema.colorScheme.primary, letterSpacing: 1)),
    );
    Widget linha(IconData i, String t, [String? s]) => ListTile(dense: true, leading: Icon(i, size: 20), title: Text(t), subtitle: s == null ? null : Text(s));
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        ListTile(
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: voltar),
          title: Text(item.orgao, style: tema.textTheme.titleMedium),
          subtitle: Text([
            if (item.situacao == 'previsto') 'Previsto',
            if (item.banca.isNotEmpty) 'Banca ${item.banca}',
            item.uf,
            if (item.nivel.isNotEmpty) item.nivel,
            if (item.fonte == 'claude') 'achado pelo Claude',
          ].join(' · ')),
        ),
        if (item.resumo.isNotEmpty) Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(item.resumo)),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _Kpi(rotulo: 'Vagas de TI', valor: '${item.totalVagas}', icone: Icons.groups),
              if (item.salarioMax > 0) _Kpi(rotulo: 'Salário até', valor: reais(item.salarioMax), icone: Icons.payments),
              if (km != null) _Kpi(rotulo: 'Distância', valor: '${rota?.estimada ?? false ? '≈' : ''}$km km', icone: Icons.route, cor: corDistancia(km)),
              if (horas != null) _Kpi(rotulo: 'De carro', valor: duracao(horas), icone: Icons.directions_car),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: acompanhar,
            icon: const Icon(Icons.auto_awesome),
            label: const Text('Acompanhar e montar o fluxo de estudo'),
          ),
        ),
        secao('Inscrições'),
        linha(Icons.event_available, item.inscricoesInicio.isEmpty ? 'Até ${dataBr(item.inscricoesFim)}' : '${dataBr(item.inscricoesInicio)} a ${dataBr(item.inscricoesFim)}',
            item.taxa.isEmpty ? null : 'Taxa: ${item.taxa}'),
        secao('Prova'),
        linha(Icons.edit_calendar, item.dataProva.isEmpty ? 'Data ainda não divulgada' : dataBr(item.dataProva),
            item.horarioProva.isEmpty ? null : 'Horário: ${item.horarioProva}'),
        if (l != null)
          linha(
            Icons.place,
            'Mais perto de você: ${l.nome}${l.suposto ? ' (sede; o edital não lista cidades)' : ''}',
            '${origem?.nome ?? 'Origem'} → ${l.nome}: ${km ?? '?'} km${horas == null ? '' : ' · ${duracao(horas)} de carro'}',
          ),
        if (item.locais.length > 1)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final x in item.locais)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: CircleAvatar(backgroundColor: corDistancia(x.km ?? x.kmReta), radius: 6),
                    label: Text('${x.nome} · ${x.km ?? '~${x.kmReta}'} km'),
                  ),
              ],
            ),
          ),
        secao('Vagas de TI'),
        for (final v in item.vagas)
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: ListTile(
              title: Text(v.cargo),
              subtitle: v.requisitos.isEmpty ? null : Text(v.requisitos),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(v.salario > 0 ? reais(v.salario) : '—', style: tema.textTheme.titleSmall),
                  Text('${v.vagas} vaga(s)${v.cadastroReserva ? ' + CR' : ''}', style: tema.textTheme.bodySmall),
                ],
              ),
            ),
          ),
        secao('Links'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (item.editalUrl.isNotEmpty)
                OutlinedButton.icon(onPressed: () => abrirLink(context, item.editalUrl), icon: const Icon(Icons.picture_as_pdf), label: const Text('Edital')),
              OutlinedButton.icon(onPressed: () => abrirLink(context, item.url), icon: const Icon(Icons.article_outlined), label: const Text('Notícia')),
              if (item.linkInscricao.isNotEmpty)
                OutlinedButton.icon(onPressed: () => abrirLink(context, item.linkInscricao), icon: const Icon(Icons.how_to_reg), label: const Text('Inscrição')),
              if (l != null && origem != null)
                OutlinedButton.icon(
                  onPressed: () => abrirLink(
                    context,
                    'https://www.google.com/maps/dir/?api=1&origin=${origem!.lat},${origem!.lon}&destination=${l.lat},${l.lon}&travelmode=driving',
                  ),
                  icon: const Icon(Icons.map_outlined),
                  label: const Text('Rota no Google Maps'),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi({required this.rotulo, required this.valor, required this.icone, this.cor});

  final String rotulo, valor;
  final IconData icone;
  final Color? cor;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final c = cor ?? tema.colorScheme.primary;
    return Container(
      width: 140,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: c.withValues(alpha: .08), borderRadius: BorderRadius.circular(12), border: Border.all(color: c.withValues(alpha: .3))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icone, size: 18, color: c),
          const SizedBox(height: 4),
          Text(valor, style: tema.textTheme.titleMedium?.copyWith(color: c, fontWeight: FontWeight.bold)),
          Text(rotulo, style: tema.textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _EscolherCargo extends StatefulWidget {
  const _EscolherCargo({required this.item});

  final ItemRadar item;

  @override
  State<_EscolherCargo> createState() => _EscolherCargoState();
}

class _EscolherCargoState extends State<_EscolherCargo> {
  late String? _cargo = widget.item.vagas.firstOrNull?.cargo;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Qual vaga você vai disputar?'),
    content: SizedBox(
      width: 480,
      child: RadioGroup<String>(
        groupValue: _cargo,
        onChanged: (v) => setState(() => _cargo = v),
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final v in widget.item.vagas)
              RadioListTile<String>(
                value: v.cargo,
                title: Text(v.cargo),
                subtitle: Text('${v.vagas} vaga(s)${v.cadastroReserva ? ' + CR' : ''}${v.salario > 0 ? ' · ${reais(v.salario)}' : ''}'),
              ),
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text('O app baixa o edital, o Claude monta o fluxo de estudo até 1 semana antes da prova e os prazos viram alertas.'),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(onPressed: _cargo == null ? null : () => Navigator.pop(context, _cargo), child: const Text('Acompanhar')),
    ],
  );
}
