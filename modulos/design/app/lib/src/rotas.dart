import 'dart:collection';
import 'dart:math';
import 'dart:ui';

/// Rota em ângulo reto entre dois blocos desviando dos outros (como o roteador do draw.io).
///
/// Monta uma grade esparsa com as linhas que passam rente às bordas dos blocos (com [margem]) e
/// pelas saídas de cada lado, e roda um A* que soma o comprimento e uma penalidade por curva: sai o
/// caminho mais curto com menos dobras que não atravessa nenhum bloco. A seta pode sair e chegar por
/// qualquer lado; o A* escolhe. Devolve os pontos do início ao fim (na borda dos blocos) ou null se
/// não houver caminho (aí quem chama usa a rota simples).
///
/// [retoDe]/[retoPara]: o bloco tem os lados retos (retângulo, processo…), então a seta pode sair de
/// qualquer ponto do lado; assim, blocos de frente um para o outro ligam com uma linha reta, sem o
/// degrau de alguns pixels que o meio exato do lado daria. Losango e círculo saem só do meio.
/// [ladoDe]/[ladoPara] prendem a saída/chegada num lado (null = o A* escolhe).
List<Offset>? rotaOrtogonal(
  Rect de,
  Rect para,
  Iterable<Rect> obstaculos, {
  double margem = 18,
  bool retoDe = true,
  bool retoPara = true,
  int? ladoDe,
  int? ladoPara,
}) {
  // Só importa o que está perto dos dois blocos: limita a grade (e o tempo) ao redor deles.
  final regiao = de.expandToInclude(para).inflate(margem * 12);
  final cheios = [
    for (final o in [de, para, ...obstaculos])
      if (o.overlaps(regiao)) o.inflate(margem),
  ];

  // Saídas: o meio de cada lado, um passo [margem] para fora.
  List<(Offset porta, Offset fora, int lado)> saidas(Rect r) => [
    (r.topCenter, r.topCenter.translate(0, -margem), 0),
    (r.centerRight, r.centerRight.translate(margem, 0), 1),
    (r.bottomCenter, r.bottomCenter.translate(0, margem), 2),
    (r.centerLeft, r.centerLeft.translate(-margem, 0), 3),
  ];
  final origens = saidas(de), destinos = saidas(para);
  // Blocos de frente um para o outro: uma saída a mais em cada um, na mesma altura (ou coluna),
  // para a ligação sair reta. Com dois lados retos, no meio da faixa em comum; com um losango ou
  // círculo, na ponta dele (o bloco reto se alinha a ela).
  double? alinhar(double ini1, double fim1, double c1, bool reto1, double ini2, double fim2, double c2, bool reto2) {
    final ini = max(ini1, ini2), fim = min(fim1, fim2);
    if (fim - ini <= 8) return null;
    if (reto1 && reto2) return (ini + fim) / 2;
    final alvo = reto1 ? c2 : (reto2 ? c1 : null);
    return alvo != null && alvo > ini + 4 && alvo < fim - 4 ? alvo : null;
  }

  final y = alinhar(de.top, de.bottom, de.center.dy, retoDe, para.top, para.bottom, para.center.dy, retoPara);
  if (y != null && (de.right < para.left || para.right < de.left)) {
    final deEsquerda = de.center.dx <= para.center.dx;
    final (ld, lp) = deEsquerda ? (de.right, para.left) : (de.left, para.right);
    final m = deEsquerda ? margem : -margem;
    origens.add((Offset(ld, y), Offset(ld + m, y), deEsquerda ? 1 : 3));
    destinos.add((Offset(lp, y), Offset(lp - m, y), deEsquerda ? 3 : 1));
  }
  final x = alinhar(de.left, de.right, de.center.dx, retoDe, para.left, para.right, para.center.dx, retoPara);
  if (x != null && (de.bottom < para.top || para.bottom < de.top)) {
    final deCima = de.center.dy <= para.center.dy;
    final (ld, lp) = deCima ? (de.bottom, para.top) : (de.top, para.bottom);
    final m = deCima ? margem : -margem;
    origens.add((Offset(x, ld), Offset(x, ld + m), deCima ? 2 : 0));
    destinos.add((Offset(x, lp), Offset(x, lp - m), deCima ? 0 : 2));
  }
  // Lado escolhido pelo usuário (0 cima, 1 direita, 2 baixo, 3 esquerda): só ele serve.
  if (ladoDe != null) origens.removeWhere((o) => o.$3 != ladoDe);
  if (ladoPara != null) destinos.removeWhere((o) => o.$3 != ladoPara);

  final xs = SplayTreeSet<double>(), ys = SplayTreeSet<double>();
  for (final r in cheios) {
    xs.addAll([r.left, r.right]);
    ys.addAll([r.top, r.bottom]);
  }
  for (final (_, p, _) in [...origens, ...destinos]) {
    xs.add(p.dx);
    ys.add(p.dy);
  }
  xs.addAll([regiao.left, regiao.right]);
  ys.addAll([regiao.top, regiao.bottom]);
  // Linhas do meio entre os dois blocos deixam o caminho centrado no vão, como o draw.io.
  xs.add((de.center.dx + para.center.dx) / 2);
  ys.add((de.center.dy + para.center.dy) / 2);
  final vx = xs.toList(), vy = ys.toList();

  bool dentro(Offset p) => cheios.any((r) => p.dx > r.left + 0.5 && p.dx < r.right - 0.5 && p.dy > r.top + 0.5 && p.dy < r.bottom - 0.5);
  bool cruza(Offset a, Offset b) {
    for (final r in cheios) {
      if (a.dy == b.dy) {
        final y = a.dy;
        if (y > r.top + 0.5 && y < r.bottom - 0.5 && max(a.dx, b.dx) > r.left + 0.5 && min(a.dx, b.dx) < r.right - 0.5) return true;
      } else {
        final x = a.dx;
        if (x > r.left + 0.5 && x < r.right - 0.5 && max(a.dy, b.dy) > r.top + 0.5 && min(a.dy, b.dy) < r.bottom - 0.5) return true;
      }
    }
    return false;
  }

  final ix = {for (final (i, x) in vx.indexed) x: i}, iy = {for (final (i, y) in vy.indexed) y: i};
  // Estado: posição na grade e direção de chegada (0 ↑, 1 →, 2 ↓, 3 ←); a curva custa caro.
  const curva = 60.0;
  const passos = [(0, -1), (1, 0), (0, 1), (-1, 0)];
  final alvos = <(int, int), (Offset, int)>{
    for (final (porta, p, lado) in destinos) (ix[p.dx]!, iy[p.dy]!): (porta, lado),
  };
  double h(int i, int j) {
    var melhor = double.infinity;
    for (final (_, p, _) in destinos) {
      melhor = min(melhor, (vx[i] - p.dx).abs() + (vy[j] - p.dy).abs());
    }
    return melhor;
  }

  final custo = <(int, int, int), double>{};
  final veio = <(int, int, int), (int, int, int)?>{};
  final fila = PriorityQueue<(double, (int, int, int))>((a, b) => a.$1.compareTo(b.$1));
  for (final (_, p, lado) in origens) {
    final i = ix[p.dx]!, j = iy[p.dy]!;
    if (dentro(p)) continue;
    // Sair pelo lado que aponta para o destino é mais barato (evita voltas logo na saída).
    final d = para.center - de.center;
    final contra = switch (lado) { 0 => d.dy > 0, 1 => d.dx < 0, 2 => d.dy < 0, _ => d.dx > 0 };
    final c = margem + (contra ? curva * 2 : 0);
    final s = (i, j, lado);
    custo[s] = c;
    veio[s] = null;
    fila.add((c + h(i, j), s));
  }
  (int, int, int)? fim;
  var visitas = 0;
  while (fila.isNotEmpty && visitas++ < 20000) {
    final (_, s) = fila.removeFirst();
    final (i, j, dir) = s;
    final c = custo[s]!;
    final alvo = alvos[(i, j)];
    // Chega pela saída do destino entrando no sentido do lado (vindo de fora).
    if (alvo != null && (dir + 2) % 4 == alvo.$2) {
      fim = s;
      break;
    }
    for (final (nd, (di, dj)) in passos.indexed) {
      if (nd == (dir + 2) % 4) continue; // não dá meia-volta
      final ni = i + di, nj = j + dj;
      if (ni < 0 || nj < 0 || ni >= vx.length || nj >= vy.length) continue;
      final a = Offset(vx[i], vy[j]), b = Offset(vx[ni], vy[nj]);
      if (dentro(b) || cruza(a, b)) continue;
      final nc = c + (b - a).distance + (nd == dir ? 0 : curva);
      final ns = (ni, nj, nd);
      if (nc < (custo[ns] ?? double.infinity)) {
        custo[ns] = nc;
        veio[ns] = s;
        fila.add((nc + h(ni, nj), ns));
      }
    }
  }
  if (fim == null) return null;

  final pontos = <Offset>[alvos[(fim.$1, fim.$2)]!.$1];
  for ((int, int, int)? s = fim; s != null; s = veio[s]) {
    pontos.add(Offset(vx[s.$1], vy[s.$2]));
  }
  // a porta de origem é a do lado de saída do primeiro estado
  var primeiro = fim;
  while (veio[primeiro] != null) {
    primeiro = veio[primeiro]!;
  }
  pontos.add(
    origens.firstWhere((o) => o.$3 == primeiro.$3 && ix[o.$2.dx] == primeiro.$1 && iy[o.$2.dy] == primeiro.$2).$1,
  );
  return _enxugar(pontos.reversed.toList());
}

/// Tira os pontos no meio de trechos retos.
List<Offset> _enxugar(List<Offset> p) {
  final saida = <Offset>[];
  for (final q in p) {
    if (saida.isNotEmpty && (saida.last - q).distance < 0.5) continue;
    if (saida.length >= 2) {
      final a = saida[saida.length - 2], b = saida.last;
      if ((a.dx == b.dx && b.dx == q.dx) || (a.dy == b.dy && b.dy == q.dy)) {
        saida[saida.length - 1] = q;
        continue;
      }
    }
    saida.add(q);
  }
  return saida;
}

/// Fila de prioridade mínima (heap binário) para o A*.
class PriorityQueue<T> {
  PriorityQueue(this._comparar);

  final int Function(T, T) _comparar;
  final _itens = <T>[];

  bool get isNotEmpty => _itens.isNotEmpty;

  void _trocar(int a, int b) {
    final t = _itens[a];
    _itens[a] = _itens[b];
    _itens[b] = t;
  }

  void add(T item) {
    _itens.add(item);
    var i = _itens.length - 1;
    while (i > 0) {
      final pai = (i - 1) >> 1;
      if (_comparar(_itens[i], _itens[pai]) >= 0) break;
      _trocar(i, pai);
      i = pai;
    }
  }

  T removeFirst() {
    final primeiro = _itens.first, ultimo = _itens.removeLast();
    if (_itens.isNotEmpty) {
      _itens[0] = ultimo;
      var i = 0;
      while (true) {
        final e = 2 * i + 1, d = e + 1;
        var menor = i;
        if (e < _itens.length && _comparar(_itens[e], _itens[menor]) < 0) menor = e;
        if (d < _itens.length && _comparar(_itens[d], _itens[menor]) < 0) menor = d;
        if (menor == i) break;
        _trocar(i, menor);
        i = menor;
      }
    }
    return primeiro;
  }
}
