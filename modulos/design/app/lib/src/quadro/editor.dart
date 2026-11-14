import 'dart:async';
import 'dart:ui' show Color, Rect;

import 'package:agent_core/agent_core.dart';
import 'package:flutter/foundation.dart';

import '../api_design.dart';
import '../cache.dart';
import '../modelos.dart';
import 'exportar.dart';
import 'imagens.dart';

enum EstadoSalvo { salvo, pendente, salvando, erro }

/// Estado de um quadro aberto: elementos, desfazer/refazer, autosalvar, cache offline e miniatura.
/// Cada mudança troca a lista inteira (imutável), então o desfazer guarda só referências.
class EditorQuadro extends ChangeNotifier {
  EditorQuadro(
    this.api,
    this.cache,
    ResumoQuadro resumo,
    List<Elemento> elementos, {
    bool pendente = false,
    Set<String> apagados = const {},
    Map<String, String> paginaDe = const {},
    this.offline = false,
  }) : id = resumo.id,
       titulo = resumo.titulo,
       fundo = resumo.fundo,
       _resumo = resumo.toJson(),
       _versao = resumo.versao,
       // Ao abrir, as setas ficam como foram salvas (recalcular com os blocos de todas as páginas
       // mudava as rotas); só as importadas do draw.io, sem pontas, são calculadas.
       _todos = List.unmodifiable(religar(elementos, manterProntas: true)),
       _paginaDe = {...paginaDe},
       paginas = resumo.paginas.isEmpty ? const [Pagina('', 'Página 1')] : resumo.paginas,
       _apagados = {...apagados} {
    paginaAtual = paginas.first.id;
    _filtrar();
    if (pendente) _agendar();
  }

  /// Abre do servidor; sem rede, da cópia do aparelho. Se a cópia tinha mudanças não enviadas,
  /// junta com o que está no servidor e grava.
  static Future<EditorQuadro> abrir(ApiDesign api, CacheQuadros cache, String id) async {
    CacheImagens.instancia.api = api;
    final local = cache.ler(id);
    Quadro? remoto;
    try {
      remoto = await api.obter(id);
    } catch (_) {
      if (local == null) rethrow;
    }
    if (remoto == null) {
      return EditorQuadro(
        api,
        cache,
        local!.resumo,
        local.elementos,
        pendente: local.pendente,
        apagados: local.apagados,
        paginaDe: local.paginaDe,
        offline: true,
      );
    }
    if (local != null && local.pendente) {
      return EditorQuadro(
        api,
        cache,
        remoto.resumo,
        mesclar(local.elementos, remoto.elementos, local.apagados),
        pendente: true,
        apagados: local.apagados,
        paginaDe: {...remoto.paginaDe, ...local.paginaDe},
      );
    }
    unawaited(cache.guardar(remoto.resumo.toJson(), remoto.elementos, pendente: false, paginaDe: remoto.paginaDe));
    return EditorQuadro(api, cache, remoto.resumo, remoto.elementos, paginaDe: remoto.paginaDe);
  }

  final ApiDesign api;
  final CacheQuadros cache;
  final String id;
  String titulo;
  Fundo fundo;
  bool offline;
  final Map<String, dynamic> _resumo;
  int _versao;

  /// Todos os elementos, de todas as páginas; [elementos] é só a página aberta.
  List<Elemento> _todos;
  List<Elemento> _elementos = const [];
  final Map<String, String> _paginaDe;

  /// Abas do quadro (draw.io: várias páginas no mesmo arquivo).
  List<Pagina> paginas;
  late String paginaAtual;
  final List<List<Elemento>> _desfazer = [];
  final List<List<Elemento>> _refazer = [];
  final Set<String> _apagados;
  EstadoSalvo estado = EstadoSalvo.salvo;
  Timer? _timer;
  Future<void>? _gravando;

  static const _limiteDesfazer = 200;
  static const _espera = Duration(milliseconds: 1200);
  static const _novaTentativa = Duration(seconds: 15);

  List<Elemento> get elementos => _elementos;
  bool get podeDesfazer => _desfazer.isNotEmpty;
  bool get podeRefazer => _refazer.isNotEmpty;

  Rect? get limites {
    final l = limitesDe(_elementos), folha = papel?.retangulo;
    return folha == null || l == null ? l ?? folha : l.expandToInclude(folha);
  }

  Map<String, dynamic> get _resumoAtual => {
    ..._resumo,
    'titulo': titulo,
    'fundo': fundo.name,
    'versao': _versao,
    'paginas': [for (final p in paginas) p.toJson()],
  };

  String _paginaDoElemento(Elemento e) {
    final p = _paginaDe[e.id] ?? paginas.first.id;
    return paginas.any((x) => x.id == p) ? p : paginas.first.id;
  }

  void _filtrar() => _elementos = List.unmodifiable(_todos.where((e) => _paginaDoElemento(e) == paginaAtual));

  // ---------- páginas ----------

  void irPara(String pagina) {
    if (pagina == paginaAtual || !paginas.any((p) => p.id == pagina)) return;
    paginaAtual = pagina;
    _filtrar();
    notifyListeners();
  }

  Future<void> _gravarPaginas() async {
    try {
      await api.editar(id, paginas: paginas);
    } catch (_) {
      // sem rede: as páginas vão no cache (resumo) e na próxima gravação dos elementos
    }
    await cache.guardar(_resumoAtual, _todos, pendente: estado != EstadoSalvo.salvo, apagados: _apagados, paginaDe: _paginaDe);
  }

  /// A primeira página sem id ganha um agora (o servidor exige id), e os elementos dela continuam nela.
  void _darIdAPrimeira() {
    if (paginas.length != 1 || paginas.first.id.isNotEmpty) return;
    paginas = [Pagina('p0', paginas.first.nome, cor: paginas.first.cor, papel: paginas.first.papel)];
    for (final e in _todos) {
      _paginaDe.putIfAbsent(e.id, () => 'p0');
    }
    paginaAtual = 'p0';
  }

  Future<void> novaPagina(String nome) async {
    final pid = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    _darIdAPrimeira();
    // No caderno a folha nova sai com o mesmo papel da folha aberta.
    paginas = [...paginas, Pagina(pid, nome, papel: _pagina.papel)];
    irPara(pid);
    _agendar();
    await _gravarPaginas();
  }

  Future<void> renomearPagina(String pagina, String nome) async {
    paginas = [for (final p in paginas) p.id == pagina ? p.copia(nome: nome) : p];
    notifyListeners();
    await _gravarPaginas();
  }

  /// Pinta a aba para marcar a página (null tira a cor).
  Future<void> colorirPagina(String pagina, Color? cor) async {
    final eraAtual = pagina == paginaAtual;
    if (pagina.isEmpty) {
      _darIdAPrimeira();
      pagina = paginas.first.id;
      _agendar();
    }
    paginas = [for (final p in paginas) p.id == pagina ? p.copia(cor: cor, semCor: cor == null) : p];
    if (eraAtual) paginaAtual = pagina;
    notifyListeners();
    await _gravarPaginas();
  }

  Pagina get _pagina => paginas.firstWhere((p) => p.id == paginaAtual, orElse: () => paginas.first);

  /// Caderno: papel de cada folha, com [papelPadrao] na que não tem; quadro: null (infinito).
  Papel? papelPadrao;

  Papel? get papel => papelPadrao == null ? null : _pagina.papel ?? papelPadrao;

  /// Troca o papel da folha aberta ou, com [todas], de todas as folhas do caderno.
  Future<void> mudarPapel(Papel novo, {bool todas = false}) async {
    if (paginaAtual.isEmpty) _darIdAPrimeira();
    paginas = [for (final p in paginas) todas || p.id == paginaAtual ? p.copia(papel: novo) : p];
    _agendar();
    notifyListeners();
    await _gravarPaginas();
  }

  /// Caderno: a caneta inteligente troca o traço recém-feito por reta/figura alinhada (null = fica).
  Elemento? Function(Traco traco)? ajustarTraco;

  /// Exclui a página e o que está nela (fica no desfazer só a lista de elementos).
  Future<void> excluirPagina(String pagina) async {
    if (paginas.length <= 1) return;
    final sai = {for (final e in _todos) if (_paginaDoElemento(e) == pagina) e.id};
    paginas = [for (final p in paginas) if (p.id != pagina) p];
    _apagados.addAll(sai);
    _todos = List.unmodifiable(_todos.where((e) => !sai.contains(e.id)));
    paginaAtual = paginas.first.id;
    _filtrar();
    _agendar();
    notifyListeners();
    await _gravarPaginas();
  }

  void _trocar(List<Elemento> novos, {bool guardar = true}) {
    if (guardar) {
      _desfazer.add(_todos);
      if (_desfazer.length > _limiteDesfazer) _desfazer.removeAt(0);
      _refazer.clear();
    }
    // Setas de fluxograma seguem os blocos; as que perderam um bloco saem junto (e contam como apagadas).
    final religados = religar(novos);
    if (religados.length != novos.length) {
      final ficam = {for (final e in religados) e.id};
      _apagados.addAll(novos.where((e) => !ficam.contains(e.id)).map((e) => e.id));
    }
    // [novos] é a página aberta: as outras páginas ficam como estão.
    for (final e in religados) {
      _paginaDe.putIfAbsent(e.id, () => paginaAtual);
    }
    _todos = List.unmodifiable([..._todos.where((e) => _paginaDoElemento(e) != paginaAtual), ...religados]);
    _filtrar();
    _agendar();
    notifyListeners();
  }

  void adicionar(Elemento e) => _trocar([..._elementos, if (e is Traco) ajustarTraco?.call(e) ?? e else e]);

  void adicionarVarios(List<Elemento> novos) => _trocar([..._elementos, ...novos]);

  /// Troca um grupo de elementos por outro num passo só (o desfazer volta tudo): a IA ajustando um
  /// fluxo. Ids que voltam deixam de contar como apagados.
  void trocarGrupo(Set<String> sair, List<Elemento> entrar) {
    final entram = {for (final e in entrar) e.id};
    _apagados
      ..addAll(sair.difference(entram))
      ..removeAll(entram);
    _trocar([
      for (final e in _elementos)
        if (!sair.contains(e.id)) e,
      ...entrar,
    ]);
  }

  /// Troca elementos pelo id (mover, redimensionar, recolorir a seleção), mantendo a ordem.
  /// Camadas: põe os elementos na ordem [ids] (o último fica na frente); quem não está em [ids] fica atrás.
  void reordenar(List<String> ids) {
    final porId = {for (final e in _elementos) e.id: e};
    final na = ids.toSet();
    _trocar([..._elementos.where((e) => !na.contains(e.id)), for (final id in ids) ?porId[id]]);
  }

  void substituir(Map<String, Elemento> novos) => _trocar([for (final e in _elementos) novos[e.id] ?? e]);

  /// A borracha apaga vários elementos num gesto só: [iniciarGesto] guarda um passo de desfazer e
  /// os [remover] seguintes (com `guardar: false`) entram nele.
  void iniciarGesto() {
    _desfazer.add(_todos);
    _refazer.clear();
  }

  void remover(Set<String> ids, {bool guardar = true}) {
    if (ids.isEmpty) return;
    _apagados.addAll(ids);
    _trocar([
      for (final e in _elementos)
        if (!ids.contains(e.id)) e,
    ], guardar: guardar);
  }

  /// Desfaz o gesto da borracha que não apagou nada (o passo guardado ficou igual ao atual).
  void encerrarGesto() {
    if (_desfazer.isNotEmpty && identical(_desfazer.last, _todos)) _desfazer.removeLast();
  }

  void limpar() => remover({for (final e in _elementos) e.id});

  void desfazer() {
    if (_desfazer.isEmpty) return;
    _refazer.add(_todos);
    _todos = _desfazer.removeLast();
    _filtrar();
    _agendar();
    notifyListeners();
  }

  void refazer() {
    if (_refazer.isEmpty) return;
    _desfazer.add(_todos);
    _todos = _refazer.removeLast();
    _filtrar();
    _agendar();
    notifyListeners();
  }

  void _agendar([Duration espera = _espera]) {
    estado = EstadoSalvo.pendente;
    _timer?.cancel();
    if (_descartado) return; // fora da tela: a cópia do aparelho fica pendente e vai na próxima abertura
    _timer = Timer(espera, salvar);
  }

  /// Grava agora (o autosalvar chama sozinho; a tela chama ao sair).
  Future<void> salvar() async {
    _timer?.cancel();
    await _gravando;
    if (estado == EstadoSalvo.salvo) return;
    _gravando = _gravar();
    await _gravando;
    _gravando = null;
  }

  Future<void> _gravar() async {
    estado = EstadoSalvo.salvando;
    notifyListeners();
    final apagados = {..._apagados};
    // Primeiro no aparelho: se a rede cair, nada se perde.
    await cache.guardar(_resumoAtual, _todos, pendente: true, apagados: _apagados, paginaDe: _paginaDe);
    try {
      try {
        _versao = (await api.salvar(id, _versao, _todos, paginaDe: _paginaDe)).versao;
      } on ApiErro catch (e) {
        if (e.status != 409) rethrow;
        // Outro aparelho gravou antes: junta as duas versões e grava sobre a dele.
        final remoto = await api.obter(id);
        remoto.paginaDe.forEach((k, v) => _paginaDe.putIfAbsent(k, () => v));
        _todos = List.unmodifiable(mesclar(_todos, remoto.elementos, _apagados));
        _filtrar();
        _versao = (await api.salvar(id, remoto.resumo.versao, _todos, paginaDe: _paginaDe)).versao;
      }
      offline = false;
      _apagados.removeAll(apagados);
      // Mudou durante a gravação? `_agendar` já marcou pendente e o timer grava de novo.
      if (estado == EstadoSalvo.salvando) estado = EstadoSalvo.salvo;
      await cache.guardar(_resumoAtual, _todos, pendente: estado != EstadoSalvo.salvo, apagados: _apagados, paginaDe: _paginaDe);
      unawaited(_enviarMiniatura());
    } catch (_) {
      // Sem rede: fica no cache e tenta de novo sozinho.
      offline = true;
      estado = EstadoSalvo.erro;
      if (!_descartado) _timer = Timer(_novaTentativa, salvar);
    }
    notifyListeners();
  }

  Future<void> _enviarMiniatura() async {
    try {
      // miniatura da primeira página (é a que abre primeiro)
      final primeira = [for (final e in _todos) if (_paginaDoElemento(e) == paginas.first.id) e];
      await api.enviarMiniatura(id, await png(primeira, fundo, densidade: 1, maxLado: 480));
    } catch (_) {
      // Miniatura é enfeite da galeria; falhar não atrapalha o quadro.
    }
  }

  @override
  void dispose() {
    _descartado = true;
    _timer?.cancel();
    super.dispose();
  }

  // A tela chama `salvar()` e descarta o editor em seguida: a gravação termina depois e não pode
  // mais avisar ninguém.
  bool _descartado = false;

  @override
  void notifyListeners() {
    if (!_descartado) super.notifyListeners();
  }
}
