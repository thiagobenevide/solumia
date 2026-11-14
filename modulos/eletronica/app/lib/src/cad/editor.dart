import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Offset, Rect;

import 'package:agent_core/agent_core.dart';
import 'package:flutter/foundation.dart';

import '../api_eletronica.dart';
import '../modelos.dart';

enum Ferramenta { selecionar, componente, fio, rotulo, texto, sonda }

enum Camada {
  componentes('Componentes'),
  campos('Referências e valores'),
  fios('Fios'),
  rotulos('Rótulos de rede'),
  textos('Textos'),
  sondas('Pontas de prova'),
  grade('Grade');

  const Camada(this.nome);
  final String nome;
}

Camada camadaDe(Item i) => switch (i) {
  Componente() => Camada.componentes,
  Fio() => Camada.fios,
  Rotulo() => Camada.rotulos,
  TextoCad() => Camada.textos,
  Sonda() => Camada.sondas,
};

/// Estado do esquemático aberto: ferramenta, seleção, desfazer/refazer e gravação automática (1,5 s depois
/// da última mudança). 409 vira [conflito]: a tela pergunta se recarrega ou grava por cima.
class Editor extends ChangeNotifier {
  Editor({required this.api, required this.projeto, required this.biblioteca}) : folha = projeto.folhas.first.id;

  final ApiEletronica api;
  final Projeto projeto;
  final Biblioteca biblioteca;

  String folha;
  Ferramenta ferramenta = Ferramenta.selecionar;
  Simbolo? simbolo;
  int rotPrevia = 0;
  bool espelhoPrevia = false;
  final Set<String> selecao = {};
  List<P>? fio;
  bool horizontalPrimeiro = true;
  P? cursor;
  int passo = grade;
  final Set<Camada> ocultas = {};
  final Set<Camada> travadas = {};

  /// Leitura de cada sonda (id → texto, ex. "2,5 V") do último ponto de operação simulado.
  Map<String, String> leituras = {};

  final List<String> _desfazer = [], _refazer = [];
  String? _lote;
  Timer? _timer;
  bool salvando = false, pendente = false, conflito = false;
  String? erro;

  // ---------- Consulta ----------

  Iterable<Componente> get componentes => projeto.componentes.where((c) => c.folha == folha);
  Iterable<Fio> get fios => projeto.fios.where((f) => f.folha == folha);
  Iterable<Rotulo> get rotulos => projeto.rotulos.where((r) => r.folha == folha);
  Iterable<TextoCad> get textos => projeto.textos.where((t) => t.folha == folha);
  Iterable<Sonda> get sondas => projeto.sondas.where((s) => s.folha == folha);

  /// Posição da sonda na lista do projeto = posição da cor na paleta dos sinais.
  int indiceSonda(Sonda s) => projeto.sondas.indexOf(s);

  Simbolo simboloDe(Componente c) => biblioteca.de(c.simbolo);

  Iterable<P> pinosDaFolha() sync* {
    for (final c in componentes) {
      for (final p in simboloDe(c).pinos) {
        yield c.posicaoPino(p);
      }
    }
  }

  List<Item> get selecionados => [for (final i in projeto.itens(folha)) if (selecao.contains(i.id)) i];

  bool podeDesfazer() => _desfazer.isNotEmpty;
  bool podeRefazer() => _refazer.isNotEmpty;

  bool _visivel(Item i) => !ocultas.contains(camadaDe(i)) && !travadas.contains(camadaDe(i));

  /// Item sob [mundo] com folga de [tol] µm; o de cima (último desenhado) ganha.
  Item? acertar(Offset mundo, double tol) {
    Item? achado;
    for (final i in projeto.itens(folha)) {
      if (!_visivel(i)) continue;
      final toca = switch (i) {
        Componente c => c.limites(simboloDe(c)).inflate(tol).contains(mundo),
        Fio f => [
          for (var k = 0; k < f.pontos.length - 1; k++) distanciaSegmento(mundo, f.pontos[k].offset, f.pontos[k + 1].offset),
        ].any((d) => d <= tol),
        Rotulo r => _caixaRotulo(r).inflate(tol).contains(mundo),
        TextoCad t => _caixaTexto(t).inflate(tol).contains(mundo),
        Sonda s => (s.pos.offset - mundo).distance <= tol + 900,
      };
      if (toca) achado = i;
    }
    return achado;
  }

  Rect _caixaRotulo(Rotulo r) => Rect.fromLTWH(r.pos.x.toDouble(), r.pos.y - 1400.0, r.nome.length * 800.0 + 600, 1400);
  Rect _caixaTexto(TextoCad t) =>
      Rect.fromLTWH(t.pos.x.toDouble(), t.pos.y - t.tamanho.toDouble(), t.texto.length * t.tamanho * 0.62, t.tamanho * 1.3);

  /// Itens inteiros dentro de [area] (janela, como no AutoCAD).
  void selecionarArea(Rect area, {bool somar = false}) {
    if (!somar) selecao.clear();
    for (final i in projeto.itens(folha)) {
      if (!_visivel(i)) continue;
      final dentro = switch (i) {
        Componente c => _contem(area, c.limites(simboloDe(c))),
        Fio f => f.pontos.every((p) => area.contains(p.offset)),
        Rotulo r => area.contains(r.pos.offset),
        TextoCad t => area.contains(t.pos.offset),
        Sonda s => area.contains(s.pos.offset),
      };
      if (dentro) selecao.add(i.id);
    }
    notifyListeners();
  }

  static bool _contem(Rect fora, Rect dentro) => fora.contains(dentro.topLeft) && fora.contains(dentro.bottomRight);

  // ---------- Mudanças ----------

  String _foto() => jsonEncode(projeto.esquematicoJson());

  /// Aplica [mudar] guardando o estado de antes para desfazer.
  void alterar(void Function() mudar) {
    final antes = _foto();
    mudar();
    if (_foto() == antes) return;
    _desfazer.add(antes);
    if (_desfazer.length > 200) _desfazer.removeAt(0);
    _refazer.clear();
    _mudou();
  }

  /// Arrastes: [iniciarLote] guarda o estado uma vez, [mexer] muda sem pilha, [terminarLote] empilha.
  void iniciarLote() => _lote ??= _foto();

  void mexer(void Function() mudar) {
    mudar();
    notifyListeners();
  }

  void terminarLote() {
    final antes = _lote;
    _lote = null;
    if (antes == null || antes == _foto()) return;
    _desfazer.add(antes);
    _refazer.clear();
    _mudou();
  }

  void desfazer() {
    if (_desfazer.isEmpty) return;
    _refazer.add(_foto());
    projeto.restaurar(jsonDecode(_desfazer.removeLast()) as Map<String, dynamic>);
    _depoisDeRestaurar();
  }

  void refazer() {
    if (_refazer.isEmpty) return;
    _desfazer.add(_foto());
    projeto.restaurar(jsonDecode(_refazer.removeLast()) as Map<String, dynamic>);
    _depoisDeRestaurar();
  }

  void _depoisDeRestaurar() {
    if (!projeto.folhas.any((f) => f.id == folha)) folha = projeto.folhas.first.id;
    selecao.removeWhere((id) => !projeto.itens(folha).any((i) => i.id == id));
    _mudou();
  }

  void _mudou() {
    pendente = true;
    notifyListeners();
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 1500), gravar);
  }

  // ---------- Ferramentas ----------

  void escolher(Ferramenta f, {Simbolo? s}) {
    ferramenta = f;
    if (s != null) {
      simbolo = s;
      rotPrevia = 0;
      espelhoPrevia = false;
    }
    fio = null;
    if (f != Ferramenta.selecionar) selecao.clear();
    notifyListeners();
  }

  void moverCursor(P? p) {
    if (p == cursor) return;
    cursor = p;
    notifyListeners();
  }

  /// `/`: o fio em andamento dobra primeiro na outra direção.
  void inverterCanto() {
    horizontalPrimeiro = !horizontalPrimeiro;
    notifyListeners();
  }

  void mudarPasso(int novo) {
    passo = novo;
    notifyListeners();
  }

  Componente? colocarComponente(P pos) {
    final s = simbolo;
    if (s == null) return null;
    final c = Componente(
      folha: folha,
      simbolo: s.id,
      ref: proximaRef(s.prefixo, projeto.componentes),
      valor: s.valor,
      encapsulamento: s.encapsulamento,
      pos: pos,
      rot: rotPrevia,
      espelho: espelhoPrevia,
    );
    alterar(() => projeto.componentes.add(c));
    return c;
  }

  /// Ponto onde algo já liga (pino, ponta ou meio de fio): clicar nele termina o fio.
  bool ehLigacao(P p) => pinosDaFolha().contains(p) || fios.any((f) => f.passaPor(p)) || rotulos.any((r) => r.pos == p);

  void pontoDoFio(P p) {
    final atual = fio;
    if (atual == null) {
      fio = [p];
      notifyListeners();
      return;
    }
    final rota = rotaOrtogonal(atual.last, p, horizontalPrimeiro: horizontalPrimeiro);
    fio = [...atual, ...rota.skip(1)];
    if (ehLigacao(p) && fio!.length > 1) {
      concluirFio();
    } else {
      notifyListeners();
    }
  }

  void concluirFio() {
    final pontos = simplificar(fio ?? const []);
    fio = null;
    if (pontos.length >= 2) {
      alterar(() => projeto.fios.add(Fio(folha: folha, pontos: pontos)));
    } else {
      notifyListeners();
    }
  }

  void colocarRotulo(P pos, String nome) =>
      alterar(() => projeto.rotulos.add(Rotulo(folha: folha, nome: nome.trim(), pos: pos)));

  /// Ponta de corrente em cima de um componente; senão, de tensão no ponto. Devolve o aviso quando não cabe.
  String? colocarSonda(P pos, Offset mundo, double tol) {
    if (projeto.sondas.length >= Sonda.maximo) return 'No máximo ${Sonda.maximo} pontas de prova.';
    final alvo = acertar(mundo, tol);
    final s = alvo is Componente
        ? Sonda(folha: folha, tipo: 'i', pos: pos, ref: alvo.ref)
        : Sonda(folha: folha, tipo: 'v', pos: pos);
    alterar(() => projeto.sondas.add(s));
    leituras = {};
    return null;
  }

  void lerSondas(Map<String, String> novas) {
    leituras = novas;
    notifyListeners();
  }

  void colocarTexto(P pos, String texto) => alterar(() => projeto.textos.add(TextoCad(folha: folha, texto: texto, pos: pos)));

  /// R: gira a prévia (com a ferramenta de componente) ou a seleção em 90° em volta do próprio ponto.
  void girar() {
    if (ferramenta == Ferramenta.componente) {
      rotPrevia = (rotPrevia + 90) % 360;
      notifyListeners();
      return;
    }
    alterar(() {
      for (final c in selecionados.whereType<Componente>()) {
        c.rot = (c.rot + 90) % 360;
      }
    });
  }

  void espelhar() {
    if (ferramenta == Ferramenta.componente) {
      espelhoPrevia = !espelhoPrevia;
      notifyListeners();
      return;
    }
    alterar(() {
      for (final c in selecionados.whereType<Componente>()) {
        c.espelho = !c.espelho;
      }
    });
  }

  void excluirSelecao() {
    if (selecao.isEmpty) return;
    alterar(() {
      projeto.componentes.removeWhere((i) => selecao.contains(i.id));
      projeto.fios.removeWhere((i) => selecao.contains(i.id));
      projeto.rotulos.removeWhere((i) => selecao.contains(i.id));
      projeto.textos.removeWhere((i) => selecao.contains(i.id));
      projeto.sondas.removeWhere((i) => selecao.contains(i.id));
      selecao.clear();
    });
  }

  /// Ctrl+D: cópia da seleção deslocada duas grades, com referências novas.
  void duplicarSelecao() {
    final itens = selecionados;
    if (itens.isEmpty) return;
    const d = P(2 * grade, 2 * grade);
    alterar(() {
      selecao.clear();
      for (final i in itens) {
        final Item novo = switch (i) {
          Componente c => Componente(
            folha: folha,
            simbolo: c.simbolo,
            ref: proximaRef(simboloDe(c).prefixo, projeto.componentes),
            valor: c.valor,
            encapsulamento: c.encapsulamento,
            pos: c.pos + d,
            rot: c.rot,
            espelho: c.espelho,
          )..let(projeto.componentes.add),
          Fio f => Fio(folha: folha, pontos: [for (final p in f.pontos) p + d])..let(projeto.fios.add),
          Rotulo r => Rotulo(folha: folha, nome: r.nome, pos: r.pos + d)..let(projeto.rotulos.add),
          TextoCad t => TextoCad(folha: folha, texto: t.texto, pos: t.pos + d, tamanho: t.tamanho)..let(projeto.textos.add),
          // Sonda não se duplica (cada uma tem a sua cor); fica a original selecionada.
          Sonda s => s,
        };
        selecao.add(novo.id);
      }
    });
  }

  /// Desloca a seleção em [d]; pontas de fio presas a pinos de componentes movidos vão junto (elástico).
  void deslocarSelecao(P d) {
    final itens = selecionados;
    final pinos = <P>{
      for (final c in itens.whereType<Componente>())
        for (final p in simboloDe(c).pinos) c.posicaoPino(p),
    };
    for (final f in fios) {
      if (selecao.contains(f.id)) continue;
      for (final k in [0, f.pontos.length - 1]) {
        if (pinos.contains(f.pontos[k])) f.pontos[k] = f.pontos[k] + d;
      }
    }
    for (final i in itens) {
      switch (i) {
        case Componente c:
          c.pos = c.pos + d;
        case Fio f:
          f.pontos = [for (final p in f.pontos) p + d];
        case Rotulo r:
          r.pos = r.pos + d;
        case TextoCad t:
          t.pos = t.pos + d;
        case Sonda s:
          s.pos = s.pos + d;
      }
    }
  }

  void alternarCamada(Camada c, {bool travar = false}) {
    final conjunto = travar ? travadas : ocultas;
    conjunto.contains(c) ? conjunto.remove(c) : conjunto.add(c);
    selecao.removeWhere((id) => projeto.itens(folha).any((i) => i.id == id && !_visivel(i)));
    notifyListeners();
  }

  // ---------- Folhas ----------

  void irPara(String id) {
    folha = id;
    selecao.clear();
    fio = null;
    notifyListeners();
  }

  void novaFolha() {
    var n = projeto.folhas.length + 1;
    while (projeto.folhas.any((f) => f.id == 'f$n')) {
      n++;
    }
    final f = Folha(id: 'f$n', nome: 'Folha $n');
    alterar(() => projeto.folhas.add(f));
    irPara(f.id);
  }

  void renomearFolha(String id, String nome) => alterar(() => projeto.folhas.firstWhere((f) => f.id == id).nome = nome);

  void excluirFolha(String id) {
    if (projeto.folhas.length <= 1) return;
    alterar(() {
      projeto.folhas.removeWhere((f) => f.id == id);
      projeto.componentes.removeWhere((i) => i.folha == id);
      projeto.fios.removeWhere((i) => i.folha == id);
      projeto.rotulos.removeWhere((i) => i.folha == id);
      projeto.textos.removeWhere((i) => i.folha == id);
      projeto.sondas.removeWhere((i) => i.folha == id);
    });
    if (folha == id) irPara(projeto.folhas.first.id);
  }

  // ---------- Gravação ----------

  Future<void> gravar({bool porCima = false}) async {
    _timer?.cancel();
    if (salvando || (!pendente && !porCima)) return;
    salvando = true;
    notifyListeners();
    try {
      if (porCima) projeto.versao = (await api.obter(projeto.id)).versao;
      final r = await api.salvar(projeto, projeto.versao);
      projeto.versao = r.versao;
      pendente = false;
      conflito = false;
      erro = null;
    } on ApiErro catch (e) {
      if (e.status == 409) {
        conflito = true;
      } else {
        erro = e.mensagem;
        _timer = Timer(const Duration(seconds: 15), gravar);
      }
    } catch (e) {
      erro = '$e';
      _timer = Timer(const Duration(seconds: 15), gravar);
    } finally {
      salvando = false;
      notifyListeners();
    }
  }

  /// Descarta o que não foi gravado e lê a versão do servidor.
  Future<void> recarregar() async {
    final p = await api.obter(projeto.id);
    projeto
      ..versao = p.versao
      ..restaurar(p.esquematicoJson());
    _timer?.cancel();
    pendente = conflito = false;
    _desfazer.clear();
    _refazer.clear();
    if (!projeto.folhas.any((f) => f.id == folha)) folha = projeto.folhas.first.id;
    selecao.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    // Sem notificar: o editor já saiu da tela.
    if (pendente && !conflito && !salvando) unawaited(api.salvar(projeto, projeto.versao).then((_) {}, onError: (_) {}));
    super.dispose();
  }
}

extension _Let<T> on T {
  void let(void Function(T) f) => f(this);
}
