import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../api_arquivos.dart';
import 'camada_pagina.dart';
import 'diagramacao.dart';
import 'geometria.dart';
import 'traducao.dart' show frasesDe;

const idiomasLeitura = {'en': 'Inglês', 'es': 'Espanhol', 'fr': 'Francês', 'pt': 'Português'};
const velocidadesLeitura = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

final _palavra = RegExp(r"[\p{L}\p{N}\p{M}_’']+(?:[-‐][\p{L}\p{N}\p{M}_’']+)*", unicode: true);

/// Palavras de [texto] como (início, fim exclusivo): o mesmo corte de `shared/linguagem.py`, para casar
/// com o tempo de cada palavra que o servidor devolve.
List<(int, int)> palavrasDe(String texto) => [for (final m in _palavra.allMatches(texto)) (m.start, m.end)];

/// Trecho do texto de uma página: índices de caracteres, [fim] inclusive (como `Frase`).
class Trecho {
  const Trecho(this.inicio, this.fim);

  final int inicio;
  final int fim;

  @override
  bool operator ==(Object other) => other is Trecho && other.inicio == inicio && other.fim == fim;

  @override
  int get hashCode => Object.hash(inicio, fim);
}

/// A palavra que contém o caractere [i] (ou só ele, fora de palavra).
Trecho palavraEm(String texto, int i) {
  for (final (a, b) in palavrasDe(texto)) {
    if (a <= i && i < b) return Trecho(a, b - 1);
  }
  return Trecho(i, i);
}

/// Palavra da fala casada com o texto da página: [trecho] na página, tempo em segundos.
typedef MarcaFala = ({Trecho trecho, double t0, double t1});

class _Fala {
  _Fala(this.bytes, this.mime, this.marcas);

  final Uint8List bytes;
  final String mime;
  final List<MarcaFala> marcas;
}

/// Leitura guiada no leitor: a voz do worker lê a página frase a frase no idioma do texto e marca a
/// palavra que está sendo dita; tocar numa palavra (ou segurar e arrastar sobre um trecho) pausa e
/// traz a tradução no contexto pela LLM local. Daí dá para ouvir, marcar e "Criar tarefas" (caderno de
/// vocabulário de Estudos › Linguagem). Também grava a pessoa lendo a página em voz alta.
class LeituraGuiada extends ChangeNotifier {
  LeituraGuiada(this.api, this.arquivoId, this.titulo, this.textos);

  final ApiArquivos api;
  final String arquivoId;
  final String titulo;
  final TextosDasPaginas textos;

  bool ativa = false;
  bool tocando = false;
  bool carregando = false;
  String idioma = 'en';
  double velocidade = 1.0;
  String? erro;

  /// Página lida agora (0-based), as frases dela e a frase atual.
  int pagina = 0;
  List<Frase> frases = const [];
  int indice = 0;
  TextoPagina? texto;

  /// Palavra sendo dita (na [pagina]).
  Trecho? palavra;

  /// Trecho consultado (tocado ou selecionado) e a tradução dele.
  Trecho? selecao;
  int? paginaSelecao;
  String termo = '';
  String fraseConsulta = '';
  Map<String, dynamic>? consulta;
  bool consultando = false;

  /// Leitura em voz alta da página: gravando e o último resultado.
  final _gravador = GravadorLeitura();
  bool get gravando => _gravador.gravando;
  bool avaliando = false;

  final _tocador = Tocador();
  final _falas = <String, Future<_Fala>>{};
  StreamSubscription<Duration>? _posicao;
  StreamSubscription<void>? _fim;
  PdfDocument? _doc;
  void Function(int pagina)? _irPara;
  _Fala? _atual;
  int _geracao = 0;
  bool _descartado = false;

  final _relogio = Stopwatch();
  int _consultas = 0, _frasesLidas = 0, _criadas = 0;

  Frase? get fraseAtual => indice < frases.length ? frases[indice] : null;

  void _avisar() {
    if (!_descartado) notifyListeners();
  }

  /// Liga a leitura guiada a partir da [pagina] (0-based); [irPara] vira a página no visor.
  Future<void> abrir(PdfDocument doc, int pagina, {required void Function(int pagina) irPara}) async {
    _doc = doc;
    _irPara = irPara;
    ativa = true;
    erro = null;
    _posicao ??= _tocador.posicao.listen(_aoAndar);
    _fim ??= _tocador.terminou.listen((_) => _aoTerminar());
    await _carregar(pagina);
    _avisar();
  }

  Future<void> _carregar(int p) async {
    final doc = _doc;
    if (doc == null) return;
    pagina = p;
    indice = 0;
    palavra = null;
    _atual = null;
    final t = await textos.de(doc.pages[p]);
    texto = t;
    frases = t == null ? const [] : frasesDe(diagramar(t.texto, t.caracteres));
  }

  /// Desliga, registrando o tempo de estudo na trilha do idioma.
  Future<void> fechar() async {
    _geracao++;
    tocando = false;
    ativa = false;
    selecao = null;
    consulta = null;
    palavra = null;
    await _tocador.parar();
    if (_gravador.gravando) await _gravador.cancelar();
    _registrar();
    _avisar();
  }

  void _registrar() {
    _relogio.stop();
    final segundos = _relogio.elapsed.inSeconds;
    if (segundos < 30 && _consultas == 0) return;
    final minutos = (segundos / 60).ceil();
    api
        .registrarAtividade('leitura_guiada', idioma, minutos, {
          'frases': _frasesLidas,
          'consultas': _consultas,
          'palavras_criadas': _criadas,
          'arquivo_id': arquivoId,
        })
        .catchError((_) {}); // sem conexão: o tempo desta sessão se perde, a leitura não
    _relogio.reset();
    _consultas = _frasesLidas = _criadas = 0;
  }

  void mudarIdioma(String i) {
    idioma = i;
    _recomecarFrase();
  }

  void mudarVelocidade(double v) {
    velocidade = v;
    _recomecarFrase();
  }

  void _recomecarFrase() {
    _atual = null;
    if (tocando) {
      _tocarAtual();
    } else {
      _avisar();
    }
  }

  Future<void> tocar() async {
    if (!ativa) return;
    selecao = null;
    consulta = null;
    tocando = true;
    _relogio.start();
    if (_atual != null) {
      await _tocador.retomar();
      _avisar();
    } else {
      await _tocarAtual();
    }
  }

  Future<void> pausar() async {
    _geracao++;
    tocando = false;
    carregando = false;
    _relogio.stop();
    await _tocador.pausar();
    _avisar();
  }

  /// Frase anterior/seguinte ([delta] −1/+1).
  Future<void> pular(int delta) async {
    final novo = indice + delta;
    if (novo < 0 && pagina > 0) {
      await _carregar(pagina - 1);
      _irPara?.call(pagina);
      indice = frases.isEmpty ? 0 : frases.length - 1;
    } else if (novo >= frases.length) {
      if (!await _proximaPagina()) return;
    } else {
      indice = novo.clamp(0, frases.isEmpty ? 0 : frases.length - 1);
    }
    _atual = null;
    palavra = null;
    tocando ? await _tocarAtual() : _avisar();
  }

  /// Começa a ler da frase que contém o trecho consultado.
  Future<void> lerDaqui() async {
    final s = selecao, p = paginaSelecao;
    if (s == null || p == null) return;
    if (p != pagina) {
      await _carregar(p);
    }
    final k = frases.indexWhere((f) => f.inicio <= s.inicio && s.inicio <= f.fim);
    indice = k < 0 ? 0 : k;
    _atual = null;
    await tocar();
  }

  Future<bool> _proximaPagina() async {
    final doc = _doc;
    if (doc == null || pagina + 1 >= doc.pages.length) {
      tocando = false;
      _avisar();
      return false;
    }
    await _carregar(pagina + 1);
    _irPara?.call(pagina);
    return true;
  }

  Future<void> _tocarAtual() async {
    final g = ++_geracao;
    var f = fraseAtual;
    // Página sem texto (figura, página em branco): passa para a próxima.
    while (f == null) {
      if (!await _proximaPagina()) return;
      f = fraseAtual;
    }
    carregando = true;
    erro = null;
    _avisar();
    try {
      final fala = await _falaDe(pagina, f);
      if (g != _geracao || !tocando) return;
      if (indice + 1 < frases.length) _falaDe(pagina, frases[indice + 1]).ignore(); // já pede a próxima
      _atual = fala;
      carregando = false;
      _avisar();
      await _tocador.tocar(fala.bytes, fala.mime);
    } on ApiErro catch (e) {
      if (g != _geracao) return;
      erro = e.mensagem;
      tocando = false;
      carregando = false;
      _avisar();
    }
  }

  Future<_Fala> _falaDe(int p, Frase f) {
    final chave = '$idioma|$velocidade|$p|${f.inicio}';
    return _falas.putIfAbsent(chave, () async {
      try {
        final r = await api.fala(f.original, idioma, velocidade);
        return _Fala(base64Decode(r['audio_b64'] as String), r['mime'] as String, _marcas(f, r['palavras'] as List));
      } catch (_) {
        _falas.remove(chave); // erro não fica em cache: tocar de novo tenta de novo
        rethrow;
      }
    });
  }

  /// A k-ésima palavra da frase normalizada é a k-ésima do texto da página (só os espaços mudam).
  List<MarcaFala> _marcas(Frase f, List palavras) {
    final t = texto?.texto ?? '';
    final daPagina = [
      for (final (a, b) in palavrasDe(t.substring(f.inicio, (f.fim + 1).clamp(f.inicio, t.length))))
        Trecho(f.inicio + a, f.inicio + b - 1),
    ];
    final ordem = {for (final (k, (a, _)) in palavrasDe(f.original).indexed) a: k};
    return [
      for (final p in palavras.cast<Map>())
        if (ordem[p['inicio']] case final k? when k < daPagina.length)
          (trecho: daPagina[k], t0: (p['t0'] as num).toDouble(), t1: (p['t1'] as num).toDouble()),
    ];
  }

  void _aoAndar(Duration d) {
    final fala = _atual;
    if (fala == null || !tocando) return;
    final s = d.inMilliseconds / 1000;
    Trecho? achada;
    for (final m in fala.marcas) {
      if (m.t0 <= s) achada = m.trecho;
      if (m.t1 > s) break;
    }
    if (achada != palavra) {
      palavra = achada;
      _avisar();
    }
  }

  Future<void> _aoTerminar() async {
    if (!tocando) return;
    _frasesLidas++;
    _atual = null;
    palavra = null;
    indice++;
    if (indice >= frases.length && !await _proximaPagina()) return;
    await _tocarAtual();
  }

  /// Toque/seleção sobre o texto da página [p]: pausa e traduz o trecho no contexto da frase.
  Future<void> consultar(int p, TextoPagina t, Trecho trecho) async {
    if (tocando) await pausar();
    selecao = trecho;
    paginaSelecao = p;
    termo = normalizar(t.texto.substring(trecho.inicio, trecho.fim + 1)).replaceAll(RegExp(r'^\W+|\W+$', unicode: true), '');
    final daPagina = p == pagina ? frases : frasesDe(diagramar(t.texto, t.caracteres));
    fraseConsulta =
        daPagina.where((f) => f.inicio <= trecho.inicio && trecho.inicio <= f.fim).firstOrNull?.original ?? termo;
    consulta = null;
    erro = null;
    if (termo.isEmpty) return _avisar();
    consultando = true;
    _consultas++;
    _avisar();
    final pedido = termo;
    try {
      final r = await api.traduzirTermo(termo, fraseConsulta, idioma);
      if (pedido == termo) consulta = r;
    } on ApiErro catch (e) {
      erro = e.mensagem;
    } finally {
      consultando = false;
      _avisar();
    }
  }

  void fecharConsulta() {
    selecao = null;
    consulta = null;
    _avisar();
  }

  /// A pronúncia do [texto] pela mesma voz da leitura.
  Future<void> ouvir(String texto) async {
    if (tocando) await pausar();
    try {
      final r = await api.fala(texto, idioma, 0.85);
      _atual = null;
      await _tocador.tocar(base64Decode(r['audio_b64'] as String), r['mime'] as String);
    } on ApiErro catch (e) {
      erro = e.mensagem;
      _avisar();
    }
  }

  /// "Criar tarefas": o termo consultado vai para o caderno de vocabulário (frases e exercícios pela LLM local).
  Future<String> criarTarefas() async {
    final c = consulta;
    await api.criarPalavra({
      'termo': termo,
      'idioma': idioma,
      'contexto': fraseConsulta,
      'traducao': c?['traducao'] ?? '',
      'classe': c?['classe'] ?? '',
      'ipa': c?['ipa'] ?? '',
      'arquivo_id': arquivoId,
      'titulo': titulo,
      'pagina': paginaSelecao ?? pagina,
    });
    _criadas++;
    return termo;
  }

  /// Texto que a pessoa vai ler em voz alta: da frase atual ao fim da página.
  String get textoParaLer => [for (final f in frases.skip(indice)) f.original].join(' ');

  Future<bool> gravar() async {
    if (tocando) await pausar();
    final ok = await _gravador.iniciar();
    _avisar();
    return ok;
  }

  /// Para de gravar e avalia contra [textoParaLer]; o resultado fica em Estudos › Linguagem.
  Future<Map<String, dynamic>?> pararEAvaliar() async {
    final referencia = textoParaLer;
    final inicio = DateTime.now();
    final wav = await _gravador.parar();
    _avisar();
    if (wav == null || wav.length < 44 + 16000 * 2) return null; // menos de 1 s
    avaliando = true;
    _avisar();
    try {
      final r = await api.avaliarLeitura(wav, idioma, referencia, arquivoId: arquivoId, titulo: titulo, pagina: pagina);
      final minutos = (DateTime.now().difference(inicio).inSeconds / 60).ceil();
      api.registrarAtividade('leitura_voz', idioma, minutos, {'arquivo_id': arquivoId}).catchError((_) {});
      return r;
    } finally {
      avaliando = false;
      _avisar();
    }
  }

  @override
  void dispose() {
    _descartado = true;
    _geracao++;
    _posicao?.cancel();
    _fim?.cancel();
    if (ativa) _registrar();
    _tocador.dispose();
    _gravador.dispose();
    super.dispose();
  }
}

/// Camada da leitura guiada sobre uma página: pinta a frase e a palavra lidas e o trecho consultado, e
/// recebe o toque (palavra) ou o segurar-e-arrastar (trecho). Só existe com a leitura guiada ligada.
class CamadaLeitura extends StatefulWidget {
  const CamadaLeitura({super.key, required this.pagina, required this.guia, required this.textos});

  final PdfPage pagina;
  final LeituraGuiada guia;
  final TextosDasPaginas textos;

  @override
  State<CamadaLeitura> createState() => _CamadaLeituraState();
}

class _CamadaLeituraState extends State<CamadaLeitura> {
  TextoPagina? _texto;
  int? _ancora;
  Trecho? _arrasto;

  int get _n => widget.pagina.pageNumber - 1;

  @override
  void initState() {
    super.initState();
    widget.textos.de(widget.pagina).then((t) {
      if (mounted) setState(() => _texto = t);
    });
  }

  int? _caractere(Offset local, double escala) {
    final t = _texto;
    if (t == null) return null;
    final p = local / escala;
    final i = caractereMaisProximo(t.caracteres, p);
    return i != null && t.caracteres[i].inflate(6).contains(p) ? i : null;
  }

  Trecho _uniao(String texto, int a, int b) {
    final x = palavraEm(texto, a < b ? a : b), y = palavraEm(texto, a < b ? b : a);
    return Trecho(x.inicio, y.fim);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.guia,
    builder: (context, _) {
      final g = widget.guia, t = _texto;
      if (!g.ativa || t == null) return const SizedBox.shrink();
      final cores = Theme.of(context).colorScheme;
      final camadas = <(List<Rect>, Color)>[
        if (g.pagina == _n && g.fraseAtual != null)
          (retangulosDoTrecho(t.caracteres, g.fraseAtual!.inicio, g.fraseAtual!.fim), cores.primary.withAlpha(28)),
        if (g.pagina == _n && g.palavra != null)
          (retangulosDoTrecho(t.caracteres, g.palavra!.inicio, g.palavra!.fim), Colors.amber.withAlpha(140)),
        if (_arrasto != null)
          (retangulosDoTrecho(t.caracteres, _arrasto!.inicio, _arrasto!.fim), Colors.lightBlue.withAlpha(90))
        else if (g.paginaSelecao == _n && g.selecao != null)
          (retangulosDoTrecho(t.caracteres, g.selecao!.inicio, g.selecao!.fim), Colors.lightBlue.withAlpha(90)),
      ];
      return LayoutBuilder(
        builder: (context, c) {
          final escala = c.maxWidth / widget.pagina.width;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) {
              final i = _caractere(d.localPosition, escala);
              if (i != null) g.consultar(_n, t, palavraEm(t.texto, i));
            },
            onLongPressStart: (d) {
              _ancora = _caractere(d.localPosition, escala);
              if (_ancora != null) setState(() => _arrasto = palavraEm(t.texto, _ancora!));
            },
            onLongPressMoveUpdate: (d) {
              final i = _caractere(d.localPosition, escala);
              if (_ancora != null && i != null) setState(() => _arrasto = _uniao(t.texto, _ancora!, i));
            },
            onLongPressEnd: (_) {
              final s = _arrasto;
              setState(() => _arrasto = _ancora = null);
              if (s != null) g.consultar(_n, t, s);
            },
            child: CustomPaint(size: c.biggest, painter: _PintorLeitura(camadas, escala)),
          );
        },
      );
    },
  );
}

class _PintorLeitura extends CustomPainter {
  _PintorLeitura(this.camadas, this.escala);

  final List<(List<Rect>, Color)> camadas;
  final double escala;

  @override
  void paint(Canvas canvas, Size size) {
    for (final (rects, cor) in camadas) {
      final tinta = Paint()..color = cor;
      for (final r in rects) {
        final e = Rect.fromLTRB(r.left * escala, r.top * escala, r.right * escala, r.bottom * escala).inflate(1);
        canvas.drawRRect(RRect.fromRectAndRadius(e, const Radius.circular(2)), tinta);
      }
    }
  }

  @override
  bool shouldRepaint(_PintorLeitura old) => true;
}
