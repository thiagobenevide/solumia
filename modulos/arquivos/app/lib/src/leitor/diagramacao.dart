import 'dart:math' as math;
import 'dart:ui' show Rect;

/// Frase do texto de uma página: [inicio]..[fim] (inclusive) são índices no texto do PDF, os mesmos
/// dos retângulos dos caracteres, para marcar o original quando a tradução é selecionada.
class Frase {
  const Frase(this.inicio, this.fim, this.original);

  final int inicio;
  final int fim;

  /// Texto da frase com os espaços normalizados (é o que vai para o tradutor e para o destaque).
  final String original;
}

const _abreviacoes = {
  'al', 'approx', 'ca', 'cf', 'ch', 'dr', 'e.g', 'eq', 'eqs', 'etc', 'fig', 'figs', 'i.e', 'mr', 'mrs', //
  'ms', 'no', 'nos', 'p', 'pp', 'prof', 'ref', 'refs', 'resp', 'sec', 'st', 'tab', 'vol', 'vs',
};
final _fimDeFrase = RegExp(r'''[.!?]["”’')\]]*\s+(?=["“'(\[]?[A-Z0-9])''');
final _paragrafo = RegExp(r'\n[ \t\r]*\n');
final _espacos = RegExp(r'\s+');
final _letra = RegExp(r'\p{L}', unicode: true);

String normalizar(String s) => s.replaceAll(_espacos, ' ').trim();

/// Divide o texto da página em frases (fim de frase seguido de maiúscula/número, ou linha em branco),
/// sem cortar em abreviações ("et al.", "Fig.", "e.g.") nem em iniciais ("J. Smith").
List<Frase> segmentar(String texto) {
  final cortes = <int>{};
  for (final m in _fimDeFrase.allMatches(texto)) {
    final antes = texto.substring(0, m.start);
    final palavra = antes.substring(antes.lastIndexOf(_espacos) + 1).replaceFirst(RegExp(r'^[(\["“]+'), '');
    final p = palavra.toLowerCase();
    if (_abreviacoes.contains(p) || RegExp(r'^\p{Lu}$', unicode: true).hasMatch(palavra)) continue;
    cortes.add(m.end);
  }
  for (final m in _paragrafo.allMatches(texto)) {
    cortes.add(m.end);
  }
  final limites = [0, ...(cortes.toList()..sort()), texto.length];
  final frases = <Frase>[];
  for (var k = 0; k + 1 < limites.length; k++) {
    var a = limites[k];
    var b = limites[k + 1] - 1;
    while (a <= b && texto[a].trim().isEmpty) {
      a++;
    }
    while (b >= a && texto[b].trim().isEmpty) {
      b--;
    }
    if (a > b) continue;
    final original = normalizar(texto.substring(a, b + 1));
    if (!_letra.hasMatch(original)) continue;
    frases.add(Frase(a, b, original));
  }
  return frases;
}

enum Alinhamento { esquerda, centro, direita, justificado }

/// Linha de texto da página: [inicio]..[fim] são índices do texto; [palavra] é a largura da primeira
/// palavra (decide se a linha anterior acabou antes da hora).
class _Linha {
  _Linha(this.inicio, Rect r) : fim = inicio, area = r, palavra = r.width;

  final int inicio;
  int fim;
  Rect area;
  double palavra;
  bool emPalavra = true;

  /// Alturas das letras sem haste: medem a fonte (a caixa do caractere é justa ao desenho dele).
  final olhos = <double>[];
  double get olho => olhos.isEmpty ? 0 : (olhos.toList()..sort())[olhos.length ~/ 2];

  /// [r] segue nesta linha: mesma altura, para a frente e sem um vão de coluna de tabela no meio.
  bool continua(Rect r) {
    final h = area.height;
    final sobreposto = math.min(area.bottom, r.bottom) - math.max(area.top, r.top);
    return sobreposto > 0.2 * math.min(h, r.height) && r.left >= area.right - h * 0.5 && r.left - area.right <= h * 2.5;
  }
}

const _semHaste = 'acemnorsuvwxz';

/// Parágrafo, título ou célula da página, como está no PDF: [area] e [corpo] em pontos, [recuo] e
/// [recuoDireita] em fração da coluna, [vaoAntes] em alturas de linha. Sem [frases] = só números.
class Bloco {
  Bloco._(this._linhas)
    : inicio = _linhas.first.inicio,
      fim = _linhas.last.fim,
      area = _uniao(_linhas),
      corpo = _mediana(_linhas);

  final List<_Linha> _linhas;
  final int inicio;
  final int fim;
  final Rect area;
  final double corpo;
  List<Frase> frases = const [];

  /// Índice da primeira frase do bloco entre as frases da página.
  int primeira = 0;
  Alinhamento alinhamento = Alinhamento.esquerda;
  bool titulo = false;
  bool recuoPrimeiraLinha = false;
  double recuo = 0;
  double recuoDireita = 0;
  double vaoAntes = 0;

  /// Fonte em relação ao texto corrido da página.
  double escala = 1;

  /// Texto do bloco quando não tem frases mas tem números (célula de tabela, número de página).
  String numeros = '';
  double _esquerda = 0;
  double _direita = 0;

  double get _olho => (_linhas.map((l) => l.olho).toList()..sort())[_linhas.length ~/ 2];

  /// Corpo da fonte em pontos (a altura do x é cerca de 46% dele).
  double get fonte => _olho > 0 ? _olho / 0.46 : corpo * 1.2;

  static Rect _uniao(List<_Linha> linhas) => linhas.map((l) => l.area).reduce((a, b) => a.expandToInclude(b));

  static double _mediana(List<_Linha> linhas) =>
      (linhas.map((l) => l.area.height).toList()..sort())[linhas.length ~/ 2];
}

List<_Linha> _linhasDe(String texto, List<Rect> caracteres) {
  final linhas = <_Linha>[];
  final n = math.min(texto.length, caracteres.length);
  for (var i = 0; i < n; i++) {
    final r = caracteres[i];
    final atual = linhas.lastOrNull;
    if (texto[i].trim().isEmpty) {
      atual?.emPalavra = false;
      continue;
    }
    if (r.width <= 0 || r.height <= 0) continue;
    if (atual != null && atual.continua(r)) {
      atual
        ..fim = i
        ..area = atual.area.expandToInclude(r);
      if (atual.emPalavra) atual.palavra = r.right - atual.area.left;
    } else {
      linhas.add(_Linha(i, r));
    }
    if (_semHaste.contains(texto[i])) linhas.last.olhos.add(r.height);
  }
  return _semTextoGirado(linhas);
}

/// Texto girado (cabeçalho de tabela, carimbo na margem) chega uma letra por linha, muitas vezes de
/// trás para a frente: fica de fora da tradução, como está no PDF.
List<_Linha> _semTextoGirado(List<_Linha> linhas) {
  bool letra(_Linha l) => l.inicio == l.fim;
  final saida = <_Linha>[];
  for (var k = 0; k < linhas.length; k++) {
    var j = k;
    while (j + 1 < linhas.length &&
        letra(linhas[j]) &&
        letra(linhas[j + 1]) &&
        _sobrepoeX(linhas[j].area, linhas[j + 1].area)) {
      j++;
    }
    if (j - k >= 2) {
      k = j;
    } else {
      saida.add(linhas[k]);
    }
  }
  return saida;
}

/// Entrelinha típico da página, em alturas de linha.
double _entrelinha(List<_Linha> linhas) {
  final razoes = <double>[
    for (var k = 1; k < linhas.length; k++)
      if (linhas[k].area.top > linhas[k - 1].area.top && _sobrepoeX(linhas[k - 1].area, linhas[k].area))
        (linhas[k].area.top - linhas[k - 1].area.top) / math.max(linhas[k].area.height, linhas[k - 1].area.height),
  ]..sort();
  return razoes.isEmpty ? 1.3 : math.min(razoes[razoes.length ~/ 2], 1.6);
}

bool _sobrepoeX(Rect a, Rect b) => math.min(a.right, b.right) > math.max(a.left, b.left);

/// [b] continua o parágrafo de [linhas]: entrelinha normal, mesmo corpo e a linha de cima sem acabar
/// antes da hora nem mudar de recuo (parágrafo novo, lista, autores e endereços um por linha).
bool _mesmoParagrafo(List<_Linha> linhas, _Linha b, double entrelinha, double larguraTipica) {
  final a = linhas.last;
  if (math.max(a.area.width, b.area.width) < larguraTipica * 0.6) return false;
  final h = math.max(a.area.height, b.area.height);
  if (b.area.top <= a.area.top || h / math.min(a.area.height, b.area.height) > 1.35) return false;
  final direita = math.max(linhas.fold(0.0, (d, l) => math.max(d, l.area.right)), b.area.right);
  if (!_sobrepoeX(a.area, b.area) || (b.area.top - a.area.top) / h > entrelinha * 1.3) return false;
  if (a.area.right + b.palavra + h * 0.3 < direita) return false;
  final centradas = (a.area.center.dx - b.area.center.dx).abs() < h && a.area.right < b.area.right - h;
  if (centradas && a.area.width + b.palavra + h * 0.3 < b.area.width) return false;
  final mudouRecuo = (a.area.left - b.area.left).abs() > h * 0.8 && (a.area.right - b.area.right).abs() < h;
  return linhas.length < 2 || !mudouRecuo;
}

Rect _alturas(List<Bloco> blocos) {
  final r = blocos.map((b) => b.area).reduce((a, b) => a.expandToInclude(b));
  return Rect.fromLTRB(0, r.top, 1, r.bottom);
}

/// Corte em colunas: separa o que está à esquerda de um vão vertical que atravessa todo o grupo.
(List<Bloco>, List<Bloco>)? _corteVertical(List<Bloco> blocos) {
  final porX = [...blocos]..sort((a, b) => a.area.left.compareTo(b.area.left));
  var direita = porX.first.area.right;
  for (var k = 1; k < porX.length; k++) {
    if (porX[k].area.left > direita + porX[k].corpo * 0.8) {
      final (a, b) = (porX.sublist(0, k), porX.sublist(k));
      // Colunas de verdade dividem a mesma altura; senão são blocos em faixas diferentes.
      if (_alturas(a).overlaps(_alturas(b))) return (a, b);
    }
    direita = math.max(direita, porX[k].area.right);
  }
  return null;
}

/// Corte em faixas. Entre os vãos horizontais, prefere o que libera a maior parte para virar colunas
/// (cabeçalho e rodapé atravessam o vão entre as colunas e impediriam o corte vertical).
(List<Bloco>, List<Bloco>)? _corteHorizontal(List<Bloco> blocos) {
  final porY = [...blocos]..sort((a, b) => a.area.top.compareTo(b.area.top));
  (List<Bloco>, List<Bloco>)? primeiro;
  (List<Bloco>, List<Bloco>)? melhor;
  var maior = 0;
  var baixo = porY.first.area.bottom;
  for (var k = 1; k < porY.length; k++) {
    if (porY[k].area.top >= baixo) {
      final corte = (porY.sublist(0, k), porY.sublist(k));
      primeiro ??= corte;
      for (final parte in [corte.$1, corte.$2]) {
        if (parte.length > maior && _corteVertical(parte) != null) {
          maior = parte.length;
          melhor = corte;
        }
      }
    }
    baixo = math.max(baixo, porY[k].area.bottom);
  }
  return melhor ?? primeiro;
}

/// Ordem de leitura (o PDF costuma trazer cabeçalho e rodapé antes do corpo), guardando a coluna.
void _ordenar(List<Bloco> blocos, double esquerda, double direita, List<Bloco> saida) {
  void coluna(List<Bloco> parte) => _ordenar(
    parte,
    parte.fold(double.infinity, (e, b) => math.min(e, b.area.left)),
    parte.fold(0, (d, b) => math.max(d, b.area.right)),
    saida,
  );
  if (blocos.length > 1) {
    if (_corteVertical(blocos) case (final a, final b)) {
      coluna(a);
      coluna(b);
      return;
    }
    if (_corteHorizontal(blocos) case (final a, final b)) {
      _ordenar(a, esquerda, direita, saida);
      _ordenar(b, esquerda, direita, saida);
      return;
    }
  }
  for (final b in blocos) {
    b
      .._esquerda = esquerda
      .._direita = direita;
    saida.add(b);
  }
}

void _acabar(Bloco b) {
  final largura = b._direita - b._esquerda;
  final esquerda = b.area.left - b._esquerda;
  final direita = b._direita - b.area.right;
  final h = b.corpo;
  final meio = (b._esquerda + b._direita) / 2;
  final linhas = b._linhas;
  if (linhas.any((l) => l.area.left - b._esquerda > h * 1.5) &&
      linhas.every((l) => (l.area.center.dx - meio).abs() < h * 1.2)) {
    b.alinhamento = Alinhamento.centro;
  } else if (esquerda > largura * 0.2 && direita < h && linhas.every((l) => b.area.right - l.area.right < h)) {
    b.alinhamento = Alinhamento.direita;
  } else {
    final cheias = linhas.sublist(0, linhas.length - 1);
    if (linhas.length >= 3 && cheias.every((l) => b.area.right - l.area.right < h * 0.6)) {
      b.alinhamento = Alinhamento.justificado;
    }
    if (largura > 0 && esquerda > h * 1.2) b.recuo = math.min(esquerda / largura, 0.35);
    if (largura > 0 && direita > h * 1.2 && b.alinhamento == Alinhamento.justificado) {
      b.recuoDireita = math.min(direita / largura, 0.35);
    }
    b.recuoPrimeiraLinha = linhas.length >= 2 && linhas[0].area.left - linhas[1].area.left > h * 0.6;
  }
}

/// Altura do x do texto corrido: a que tem mais caracteres na página (0 = nenhuma medida).
double _olhoBase(List<_Linha> linhas) {
  final porOlho = <int, int>{};
  for (final l in linhas) {
    if (l.olho == 0) continue;
    final chave = (l.olho * 4).round();
    porOlho[chave] = (porOlho[chave] ?? 0) + l.fim - l.inicio + 1;
  }
  return porOlho.isEmpty ? 0 : porOlho.entries.reduce((a, b) => b.value > a.value ? b : a).key / 4;
}

/// Sem o peso da fonte, título de mesmo corpo do texto se reconhece por ser uma linha curta e solta.
bool _ehTitulo(Bloco b, String texto, Bloco? seguinte) {
  if (b.fim - b.inicio >= 240) return false;
  if (b.escala >= 1.25) return true;
  final solta = b.vaoAntes >= 1 && (seguinte == null || seguinte.vaoAntes >= 0.8);
  final curta = b._linhas.length == 1 && b.fim - b.inicio < 80 && !RegExp(r'[.,;:]$').hasMatch(texto);
  return b.escala >= 0.9 && solta && curta && b.alinhamento != Alinhamento.direita;
}

/// Reconstrói a diagramação da página a partir dos retângulos dos caracteres: blocos na ordem de
/// leitura, cada um com suas frases. Usado tanto no painel quanto na tradução sobre a página.
List<Bloco> diagramar(String texto, List<Rect> caracteres) {
  final linhas = _linhasDe(texto, caracteres);
  if (linhas.isEmpty) return [];
  final entrelinha = _entrelinha(linhas);
  final larguraTipica = (linhas.map((l) => l.area.width).toList()..sort())[linhas.length * 3 ~/ 4];
  final grupos = <List<_Linha>>[];
  for (final l in linhas) {
    if (grupos.isNotEmpty && _mesmoParagrafo(grupos.last, l, entrelinha, larguraTipica)) {
      grupos.last.add(l);
    } else {
      grupos.add([l]);
    }
  }
  final blocos = [for (final g in grupos) Bloco._(g)];
  final ordenados = <Bloco>[];
  _ordenar(
    blocos,
    blocos.fold(double.infinity, (e, b) => math.min(e, b.area.left)),
    blocos.fold(0, (d, b) => math.max(d, b.area.right)),
    ordenados,
  );
  final base = _olhoBase(linhas);
  var n = 0;
  for (var k = 0; k < ordenados.length; k++) {
    final b = ordenados[k];
    final trecho = texto.substring(b.inicio, b.fim + 1);
    _acabar(b);
    b
      ..escala = base > 0 && b._olho > 0 ? b._olho / base : 1
      ..primeira = n
      ..frases = [for (final f in segmentar(trecho)) Frase(f.inicio + b.inicio, f.fim + b.inicio, f.original)];
    if (b.frases.isEmpty && trecho.contains(RegExp(r'\d'))) b.numeros = normalizar(trecho);
    n += b.frases.length;
    if (k > 0) {
      final vao = b.area.top - ordenados[k - 1].area.bottom;
      b.vaoAntes = vao < 0 ? 1 : math.min(vao / ordenados[k - 1].corpo, 2.5);
    }
  }
  for (var k = 0; k < ordenados.length; k++) {
    final b = ordenados[k];
    b.titulo = _ehTitulo(
      b,
      normalizar(texto.substring(b.inicio, b.fim + 1)),
      k + 1 < ordenados.length ? ordenados[k + 1] : null,
    );
  }
  return ordenados;
}
