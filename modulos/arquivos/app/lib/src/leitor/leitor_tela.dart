import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import '../api_arquivos.dart';
import '../modelos.dart';
import '../telas/acoes_destaque.dart';
import '../telas/projetos_leitura.dart';
import 'anotador.dart';
import 'camada_pagina.dart';
import 'estojo.dart';
import 'geometria.dart';
import 'leitura_guiada.dart';
import 'leitura_guiada_barra.dart';
import 'traducao.dart';
import 'traducao_pagina.dart';

/// Leitor de um arquivo (PDF, ou DOCX/PPTX já convertidos) com anotação à tinta por cima.
class LeitorTela extends StatefulWidget {
  const LeitorTela({super.key, required this.api, required this.arquivo, this.paginaInicial = 1});

  final ApiArquivos api;
  final Arquivo arquivo;
  final int paginaInicial;

  @override
  State<LeitorTela> createState() => _LeitorTelaState();
}

class _LeitorTelaState extends State<LeitorTela> {
  late final _anotador = Anotador(widget.api, widget.arquivo.id);
  final _estojo = Estojo();
  final _textos = TextosDasPaginas();
  final _controle = PdfViewerController();
  late final _tradutor = TradutorDocumento(widget.api, widget.arquivo.id, _textos);
  late final _guia = LeituraGuiada(widget.api, widget.arquivo.id, widget.arquivo.titulo, _textos);
  late final _paginaAtual = ValueNotifier(widget.paginaInicial - 1);
  final _chaveVisor = GlobalKey();
  final _modo = ValueNotifier(ModoTraducao.desligada);
  late final Future<Uint8List> _pdf = _abrir();
  Timer? _sondagem;
  int _seq = 0;

  Future<Uint8List> _abrir() async {
    final local = await widget.api.offline.pdf(widget.arquivo.id);
    final (bytes, _) = await (
      local != null ? Future.value(local) : widget.api.pdf(widget.arquivo.id),
      _anotador.carregar(),
    ).wait;
    try {
      final (seq, _) = await widget.api.mudancas(1 << 50);
      _seq = seq;
    } on ApiErro catch (e) {
      if (!semConexao(e)) rethrow; // offline com o arquivo baixado: a sondagem pega quando voltar
    }
    _sondagem = Timer.periodic(const Duration(seconds: 4), (_) => _verificarMudancas());
    return bytes;
  }

  /// Anotações feitas em outro aparelho aparecem aqui sem reabrir o arquivo.
  Future<void> _verificarMudancas() async {
    try {
      final (seq, mudancas) = await widget.api.mudancas(_seq);
      _seq = seq;
      final minhas = mudancas.where((m) => m['arquivo_id'] == widget.arquivo.id && m['acao'] == 'anotado');
      if (minhas.isNotEmpty) await _anotador.atualizarDoServidor(minhas.last['versao'] as int);
    } catch (_) {
      // Sem conexão agora: tenta de novo no próximo ciclo.
    }
  }

  @override
  void dispose() {
    _sondagem?.cancel();
    _anotador.salvar().whenComplete(_anotador.dispose);
    _estojo.dispose();
    _tradutor.dispose();
    _guia.dispose();
    _paginaAtual.dispose();
    _modo.dispose();
    super.dispose();
  }

  Future<void> _texto(int pagina, Offset posicao, [TextoAnotado? existente]) async {
    final texto = await pedirTexto(
      context,
      titulo: existente == null ? 'Texto na página ${pagina + 1}' : 'Editar texto (vazio apaga)',
      inicial: existente?.texto ?? '',
      linhas: 3,
    );
    if (texto == null) return;
    if (existente != null) {
      texto.trim().isEmpty ? _anotador.remover({existente.id}) : _anotador.substituir(existente.comTexto(texto));
    } else if (texto.trim().isNotEmpty) {
      _anotador.adicionar(
        TextoAnotado(
          id: novoId(),
          pagina: pagina,
          posicao: posicao,
          texto: texto,
          cor: _estojo.corDe(Ferramenta.texto),
          tamanho: _estojo.espessuraDe(Ferramenta.texto),
        ),
      );
    }
  }

  /// Versão mais nova do destaque (a folha pode mudar projetos e depois o comentário).
  Destaque _atualDe(Destaque d) => _anotador.atual.destaques.firstWhere((x) => x.id == d.id, orElse: () => d);

  void _ligarPagina() {
    final pagina = (_controle.pageNumber ?? 1) - 1;
    final n = _anotador.ligarPagina(pagina, projetosAtivos.value);
    avisar(
      context,
      n == 0 ? 'Nada novo para ligar na página ${pagina + 1}' : '$n anotações da página ${pagina + 1} ligadas',
    );
  }

  /// Trecho já marcado sem o projeto ativo: liga a ele em vez de ignorar o "Marcar".
  bool _ligarAoProjeto(Destaque d) {
    final ativos = projetosAtivos.value;
    if (ativos.isEmpty || ativos.every(d.projetos.contains)) return false;
    _anotador.substituir(d.comProjetos({...d.projetos, ...ativos}.toList()));
    avisar(context, 'Trecho já marcado: ligado ao projeto ativo');
    return true;
  }

  void _traduzir(ModoTraducao modo) {
    setState(() => _modo.value = modo);
    if (modo != ModoTraducao.desligada) _retomarTraducao();
  }

  void _retomarTraducao() {
    if (_controle.isReady) _tradutor.traduzirDocumento(_controle.document, _paginaAtual.value);
  }

  /// Frases selecionadas na tradução → destaque no original em inglês, com a tradução junto; o
  /// `Anotador` liga ao projeto de leitura ativo. Se já estava marcado igual, abre o destaque.
  void _marcarTraducao(int pagina, PaginaTraduzida p, List<int> frases) {
    final original = [for (final k in frases) p.frases[k].original].join(' ');
    final traducao = [for (final k in frases) p.traducoes[k]].where((t) => t.isNotEmpty).join(' ');
    final existente = _anotador.visiveis.destaques.where((d) => d.pagina == pagina && d.texto == original).firstOrNull;
    if (existente != null) {
      if (_ligarAoProjeto(existente)) return;
      return _destaque(existente);
    }
    _anotador.adicionar(
      Destaque(
        id: novoId(),
        pagina: pagina,
        texto: original,
        traducao: traducao,
        cor: _estojo.corDe(Ferramenta.marcaTexto),
        retangulos: [
          for (final k in frases) ...retangulosDoTrecho(p.texto.caracteres, p.frases[k].inicio, p.frases[k].fim),
        ],
        criado: DateTime.now(),
      ),
    );
    avisar(
      context,
      projetosAtivos.value.isEmpty
          ? 'Marcado no original. Escolha um projeto ativo para o trecho entrar no projeto de leitura.'
          : 'Marcado no original e no projeto de leitura (inglês + português)',
    );
  }

  /// Leitura guiada: a voz lê a partir da página na tela; tocar numa palavra traduz.
  void _alternarGuia() {
    if (_guia.ativa) {
      _guia.fechar();
    } else if (_controle.isReady) {
      _guia.abrir(_controle.document, _paginaAtual.value, irPara: (p) => _controle.goToPage(pageNumber: p + 1));
    }
  }

  /// O trecho consultado na leitura guiada vira destaque no PDF, com a tradução (entra no projeto ativo).
  void _marcarConsulta() {
    final s = _guia.selecao, p = _guia.paginaSelecao;
    final t = p == null ? null : _textos.prontos[p + 1];
    if (s == null || p == null || t == null) return;
    final texto = normalizar(t.texto.substring(s.inicio, s.fim + 1));
    final existente = _anotador.visiveis.destaques.where((d) => d.pagina == p && d.texto == texto).firstOrNull;
    if (existente != null) {
      if (_ligarAoProjeto(existente)) return;
      return avisar(context, 'Esse trecho já está marcado.');
    }
    _anotador.adicionar(
      Destaque(
        id: novoId(),
        pagina: p,
        texto: texto,
        traducao: (_guia.consulta?['traducao'] as String?) ?? '',
        cor: _estojo.corDe(Ferramenta.marcaTexto),
        retangulos: retangulosDoTrecho(t.caracteres, s.inicio, s.fim),
        criado: DateTime.now(),
      ),
    );
    avisar(context, 'Marcado no PDF com a tradução');
  }

  void _destaque(Destaque d) => mostrarDestaque(
    context,
    api: widget.api,
    referencia: Referencia.de(d, widget.arquivo),
    aoComentar: (c) => _anotador.substituir(_atualDe(d).comComentario(c)),
    aoTraduzir: (t) => _anotador.substituir(_atualDe(d).copiar(traducao: t)),
    aoMudarProjetos: (p) => _anotador.substituir(_atualDe(d).comProjetos(p)),
    aoExcluir: () => _anotador.remover({d.id}),
    aoAbrir: () => _controle.goToPage(pageNumber: d.pagina + 1),
  );

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _anotador.desfazer,
      const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true): _anotador.refazer,
      const SingleActivator(LogicalKeyboardKey.keyY, control: true): _anotador.refazer,
      const SingleActivator(LogicalKeyboardKey.keyS, control: true): _anotador.salvar,
    },
    child: Focus(
      autofocus: true,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.arquivo.titulo, overflow: TextOverflow.ellipsis),
          actions: [
            ListenableBuilder(
              listenable: _guia,
              builder: (context, _) => IconButton(
                tooltip: _guia.ativa ? 'Fechar a leitura guiada' : 'Leitura guiada (ouvir e traduzir tocando)',
                icon: Icon(
                  Icons.record_voice_over_outlined,
                  color: _guia.ativa ? Theme.of(context).colorScheme.primary : null,
                ),
                onPressed: _alternarGuia,
              ),
            ),
            PopupMenuButton<ModoTraducao>(
              tooltip: 'Traduzir o documento para o português',
              icon: Icon(
                Icons.translate,
                color: _modo.value == ModoTraducao.desligada ? null : Theme.of(context).colorScheme.primary,
              ),
              onSelected: _traduzir,
              itemBuilder: (context) => [
                CheckedPopupMenuItem(
                  value: ModoTraducao.painel,
                  checked: _modo.value == ModoTraducao.painel,
                  child: const Text('No painel, junto do PDF'),
                ),
                CheckedPopupMenuItem(
                  value: ModoTraducao.sobrePagina,
                  checked: _modo.value == ModoTraducao.sobrePagina,
                  child: const Text('Sobre a página'),
                ),
                if (_modo.value != ModoTraducao.desligada)
                  const PopupMenuItem(value: ModoTraducao.desligada, child: Text('Desligar a tradução')),
              ],
            ),
            BotaoProjetoAtivo(api: widget.api, aoLigarPagina: _ligarPagina),
            ListenableBuilder(
              listenable: _anotador,
              builder: (context, _) => Row(
                children: [
                  _IconeSalvamento(_anotador),
                  IconButton(
                    tooltip: 'Desfazer (Ctrl+Z)',
                    icon: const Icon(Icons.undo),
                    onPressed: _anotador.podeDesfazer ? _anotador.desfazer : null,
                  ),
                  IconButton(
                    tooltip: 'Refazer (Ctrl+Y)',
                    icon: const Icon(Icons.redo),
                    onPressed: _anotador.podeRefazer ? _anotador.refazer : null,
                  ),
                ],
              ),
            ),
            Builder(
              builder: (context) => IconButton(
                tooltip: 'Destaques deste arquivo',
                icon: const Icon(Icons.format_list_bulleted),
                onPressed: () => Scaffold.of(context).openEndDrawer(),
              ),
            ),
          ],
          bottom: PreferredSize(preferredSize: const Size.fromHeight(52), child: _BarraFerramentas(_estojo)),
        ),
        endDrawer: Drawer(
          width: 360,
          child: ListenableBuilder(
            listenable: _anotador,
            builder: (context, _) => _ListaDestaques(
              destaques: [..._anotador.visiveis.destaques]..sort((a, b) => a.pagina.compareTo(b.pagina)),
              aoTocar: (d) {
                Navigator.pop(context);
                _controle.goToPage(pageNumber: d.pagina + 1);
                _destaque(d);
              },
            ),
          ),
        ),
        body: LayoutBuilder(
          builder: (context, area) => Stack(
            children: [
              Positioned.fill(child: _comPainel(area, _visor())),
              Positioned(
                left: 12,
                right: 12,
                // acima da barrinha da tradução sobre a página
                bottom: _modo.value == ModoTraducao.sobrePagina ? 72 : 12,
                child: ListenableBuilder(
                  listenable: _guia,
                  builder: (context, _) => !_guia.ativa
                      ? const SizedBox.shrink()
                      : Center(child: PainelLeituraGuiada(guia: _guia, aoMarcar: _marcarConsulta)),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  /// PDF e, com a tradução no painel, ele ao lado (tela larga) ou embaixo (celular); sobre a página,
  /// só a barrinha flutuante. O
  /// [_chaveVisor] mantém o PdfViewer (página, zoom) quando o painel abre ou fecha.
  Widget _comPainel(BoxConstraints area, Widget visor) {
    visor = KeyedSubtree(key: _chaveVisor, child: visor);
    if (_modo.value == ModoTraducao.desligada) return visor;
    if (_modo.value == ModoTraducao.sobrePagina) {
      return Stack(
        children: [
          Positioned.fill(child: visor),
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: Center(
              child: ListenableBuilder(
                listenable: Listenable.merge([_tradutor, _paginaAtual]),
                builder: (context, _) => BarraTraducao(
                  tradutor: _tradutor,
                  pagina: _paginaAtual.value,
                  aoRetomar: _retomarTraducao,
                  aoFechar: () => _traduzir(ModoTraducao.desligada),
                ),
              ),
            ),
          ),
        ],
      );
    }
    final painel = ListenableBuilder(
      listenable: Listenable.merge([_tradutor, _anotador, _paginaAtual]),
      builder: (context, _) {
        final pagina = _paginaAtual.value;
        return PainelTraducao(
          tradutor: _tradutor,
          pagina: pagina,
          destaques: [
            for (final d in _anotador.visiveis.destaques)
              if (d.pagina == pagina) d,
          ],
          aoMarcar: (p, frases) => _marcarTraducao(pagina, p, frases),
          aoRetomar: _retomarTraducao,
          aoFechar: () => _traduzir(ModoTraducao.desligada),
        );
      },
    );
    return area.maxWidth >= 900
        ? Row(
            children: [
              Expanded(child: visor),
              const VerticalDivider(width: 1),
              SizedBox(width: area.maxWidth * 0.42, child: painel),
            ],
          )
        : Column(
            children: [
              Expanded(child: visor),
              const Divider(height: 1),
              SizedBox(height: area.maxHeight * 0.45, child: painel),
            ],
          );
  }

  Widget _visor() => FutureBuilder(
    future: _pdf,
    builder: (context, s) {
      if (s.hasError) return Center(child: Text('Não deu para abrir: ${s.error}'));
      if (!s.hasData) return const Center(child: CircularProgressIndicator());
      return PdfViewer.data(
        s.data!,
        sourceName: widget.arquivo.id,
        controller: _controle,
        initialPageNumber: widget.paginaInicial,
        params: PdfViewerParams(
          backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
          onPageChanged: _mudouPagina,
          onViewerReady: _pronto,
          pageOverlaysBuilder: (context, area, pagina) => [
            Positioned.fill(
              child: CamadaTraducao(
                key: ValueKey('traducao ${pagina.pageNumber}'),
                pagina: pagina,
                tradutor: _tradutor,
                modo: _modo,
              ),
            ),
            Positioned.fill(
              child: CamadaPagina(
                key: ValueKey(pagina.pageNumber),
                pagina: pagina,
                anotador: _anotador,
                estojo: _estojo,
                textos: _textos,
                aoCriarTexto: _texto,
                aoTocarTexto: (t) => _texto(t.pagina, t.posicao, t),
                aoTocarDestaque: _destaque,
              ),
            ),
            Positioned.fill(
              child: CamadaLeitura(
                key: ValueKey('leitura ${pagina.pageNumber}'),
                pagina: pagina,
                guia: _guia,
                textos: _textos,
              ),
            ),
          ],
        ),
      );
    },
  );

  void _mudouPagina(int? n) {
    if (n != null) _paginaAtual.value = n - 1;
  }

  void _pronto(PdfDocument _, PdfViewerController _) {
    if (_modo.value != ModoTraducao.desligada) _retomarTraducao();
  }
}

class _IconeSalvamento extends StatelessWidget {
  const _IconeSalvamento(this.anotador);

  final Anotador anotador;

  @override
  Widget build(BuildContext context) {
    final (icone, dica) = switch (anotador.estado) {
      EstadoSalvamento.salvo => (Icons.cloud_done_outlined, 'Anotações salvas'),
      EstadoSalvamento.pendente => (Icons.cloud_queue, 'Salvando em instantes'),
      EstadoSalvamento.salvando => (Icons.cloud_upload_outlined, 'Salvando…'),
      EstadoSalvamento.erro => (Icons.cloud_off, 'Falhou: ${anotador.erro}. Tento de novo sozinho.'),
      EstadoSalvamento.noAparelho => (Icons.save_outlined, 'Sem conexão: salvo no aparelho. Sobe quando voltar.'),
    };
    return IconButton(
      tooltip: dica,
      onPressed: anotador.salvar,
      icon: Icon(icone, color: anotador.estado == EstadoSalvamento.erro ? Theme.of(context).colorScheme.error : null),
    );
  }
}

/// Ferramentas, cor, espessura, régua e "só caneta", numa faixa que rola na horizontal no celular.
class _BarraFerramentas extends StatelessWidget {
  const _BarraFerramentas(this.estojo);

  final Estojo estojo;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: estojo,
    builder: (context, _) {
      final f = estojo.ferramenta;
      final (min, max) = estojo.faixa;
      return SizedBox(
        height: 52,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          children: [
            for (final opcao in Ferramenta.values)
              IconButton(
                tooltip: opcao.rotulo,
                isSelected: f == opcao,
                icon: Icon(
                  opcao.icone,
                  color: opcao.usaCor && f == opcao ? estojo.corDe(opcao).withValues(alpha: 1) : null,
                ),
                onPressed: () => estojo.ferramenta = opcao,
                style: IconButton.styleFrom(
                  backgroundColor: f == opcao ? Theme.of(context).colorScheme.secondaryContainer : null,
                ),
              ),
            const VerticalDivider(indent: 10, endIndent: 10),
            if (f.usaCor) ...[
              for (final c in {...estojo.recentes.take(3), ...coresRapidas.take(5)})
                _BolinhaCor(cor: c, selecionada: c == estojo.cor, aoTocar: () => estojo.cor = c),
              IconButton(
                tooltip: 'Qualquer cor',
                icon: const Icon(Icons.palette_outlined),
                onPressed: () async {
                  final c = await escolherCor(context, estojo.cor, estojo.recentes, paleta: coresRapidas);
                  if (c != null) estojo.cor = c;
                },
              ),
            ],
            if (f != Ferramenta.navegar)
              SizedBox(
                width: 170,
                child: Row(
                  children: [
                    SizedBox(
                      width: 34,
                      child: Text(
                        estojo.espessura.toStringAsFixed(estojo.espessura < 10 ? 1 : 0),
                        textAlign: TextAlign.end,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                    Expanded(
                      child: Slider(
                        value: estojo.espessura.clamp(min, max),
                        min: min,
                        max: max,
                        onChanged: (v) => estojo.espessura = v,
                      ),
                    ),
                  ],
                ),
              ),
            const VerticalDivider(indent: 10, endIndent: 10),
            IconButton(
              tooltip: 'Linhas retas (ou segure a caneta parada no fim do traço)',
              isSelected: estojo.retas,
              icon: const Icon(Icons.straighten),
              onPressed: estojo.alternarRetas,
              style: IconButton.styleFrom(
                backgroundColor: estojo.retas ? Theme.of(context).colorScheme.secondaryContainer : null,
              ),
            ),
            IconButton(
              tooltip: estojo.soCaneta
                  ? 'Só a caneta desenha (o dedo rola e dá zoom)'
                  : 'Caneta, dedo e mouse desenham',
              isSelected: estojo.soCaneta,
              icon: Icon(estojo.soCaneta ? Icons.draw_outlined : Icons.touch_app_outlined),
              onPressed: estojo.alternarSoCaneta,
            ),
          ],
        ),
      );
    },
  );
}

class _BolinhaCor extends StatelessWidget {
  const _BolinhaCor({required this.cor, required this.selecionada, required this.aoTocar});

  final Color cor;
  final bool selecionada;
  final VoidCallback aoTocar;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 3),
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: aoTocar,
      child: Container(
        width: 26,
        height: 26,
        margin: const EdgeInsets.symmetric(vertical: 13),
        decoration: BoxDecoration(
          color: cor,
          shape: BoxShape.circle,
          border: Border.all(
            color: selecionada ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outlineVariant,
            width: selecionada ? 3 : 1,
          ),
        ),
      ),
    ),
  );
}

class _ListaDestaques extends StatelessWidget {
  const _ListaDestaques({required this.destaques, required this.aoTocar});

  final List<Destaque> destaques;
  final ValueChanged<Destaque> aoTocar;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: destaques.isEmpty
        ? const Padding(
            padding: EdgeInsets.all(24),
            child: Text('Nenhum destaque ainda. Use o marca-texto que salva o texto para marcar trechos.'),
          )
        : ListView(
            children: [
              ListTile(title: Text('${destaques.length} destaques', style: Theme.of(context).textTheme.titleMedium)),
              for (final d in destaques)
                ListTile(
                  leading: CircleAvatar(radius: 6, backgroundColor: d.cor.withValues(alpha: 1)),
                  title: Text(d.texto, maxLines: 3, overflow: TextOverflow.ellipsis),
                  subtitle: Text(['p. ${d.pagina + 1}', if (d.comentario.isNotEmpty) d.comentario].join(' · ')),
                  onTap: () => aoTocar(d),
                ),
            ],
          ),
  );
}
