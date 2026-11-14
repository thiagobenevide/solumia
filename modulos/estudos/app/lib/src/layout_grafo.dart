import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

/// Simulação de força dirigida (Fruchterman–Reingold) que avança um passo por vez, para a tela animar
/// os nós se acomodando: arestas puxam, nós se repelem, a "temperatura" cai a cada passo até parar.
/// Semente fixa: o mesmo grafo sai sempre com o mesmo desenho. Posições num quadrado de lado [lado]
/// centrado na origem; [inicio] reaproveita posições já conhecidas (troca de filtro não embaralha tudo).
class SimulacaoGrafo {
  SimulacaoGrafo(this.ids, List<(String, String)> arestas, {this.lado = 1000, Map<String, Offset> inicio = const {}})
    : _x = Float64List(ids.length),
      _y = Float64List(ids.length),
      _k = ids.isEmpty ? 1 : sqrt(lado * lado / ids.length) * 0.8 {
    final indice = {for (final (i, id) in ids.indexed) id: i};
    _ligacoes = [
      for (final (a, b) in arestas)
        if (indice[a] != null && indice[b] != null && a != b) (indice[a]!, indice[b]!),
    ];
    // nós novos nascem perto do centro e "explodem" para fora: a animação fica legível
    final espalhar = inicio.isEmpty ? lado * 0.25 : lado * 0.05;
    for (var i = 0; i < ids.length; i++) {
      final p = inicio[ids[i]];
      _x[i] = p?.dx ?? (_aleatorio.nextDouble() - .5) * espalhar;
      _y[i] = p?.dy ?? (_aleatorio.nextDouble() - .5) * espalhar;
    }
    temperatura = inicio.isEmpty ? lado / 10 : lado / 30;
  }

  final List<String> ids;
  final double lado;
  final Float64List _x, _y;
  final double _k; // distância ideal entre nós
  late final List<(int, int)> _ligacoes;
  final _aleatorio = Random(42);
  late double temperatura;

  static const _minima = 1.0;

  bool get ativa => temperatura > _minima && ids.isNotEmpty;

  Offset posicao(int i) => Offset(_x[i], _y[i]);

  Map<String, Offset> get posicoes => {for (final (i, id) in ids.indexed) id: posicao(i)};

  void passo() {
    final n = ids.length;
    final dx = Float64List(n), dy = Float64List(n);
    final k2 = _k * _k;
    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
        var ex = _x[i] - _x[j], ey = _y[i] - _y[j];
        var d2 = ex * ex + ey * ey;
        if (d2 < 1e-4) {
          ex = _aleatorio.nextDouble() - .5;
          ey = _aleatorio.nextDouble() - .5;
          d2 = 1e-4;
        }
        final f = k2 / d2; // (d/|d|) * k²/|d|
        dx[i] += ex * f;
        dy[i] += ey * f;
        dx[j] -= ex * f;
        dy[j] -= ey * f;
      }
    }
    for (final (a, b) in _ligacoes) {
      final ex = _x[a] - _x[b], ey = _y[a] - _y[b];
      final f = sqrt(ex * ex + ey * ey) / _k; // (d/|d|) * |d|²/k
      dx[a] -= ex * f;
      dy[a] -= ey * f;
      dx[b] += ex * f;
      dy[b] += ey * f;
    }
    final meio = lado / 2;
    for (var i = 0; i < n; i++) {
      // gravidade leve para o centro: componentes soltos não fogem do quadro
      final gx = dx[i] - _x[i] * 0.02, gy = dy[i] - _y[i] * 0.02;
      final d = sqrt(gx * gx + gy * gy);
      if (d > 0) {
        final m = min(d, temperatura) / d;
        _x[i] = (_x[i] + gx * m).clamp(-meio, meio);
        _y[i] = (_y[i] + gy * m).clamp(-meio, meio);
      }
    }
    temperatura = max(temperatura * 0.97, _minima);
  }
}

/// Para `compute`: (ids, arestas, lado, posições iniciais) → posições finais, simulando até esfriar fora
/// da thread da interface (a tela só anima o resultado, sem tremer).
Map<String, Offset> calcularLayout((List<String>, List<(String, String)>, double, Map<String, Offset>) p) {
  final (ids, arestas, lado, inicio) = p;
  final sim = SimulacaoGrafo(ids, arestas, lado: lado, inicio: inicio);
  for (var i = 0; i < 600 && sim.ativa; i++) {
    sim.passo();
  }
  return sim.posicoes;
}

/// Layout pronto (sem animação): roda a simulação [passos] vezes.
Map<String, Offset> layoutGrafo(
  List<String> nos,
  List<(String, String)> arestas, {
  double lado = 1000,
  int passos = 250,
}) {
  if (nos.isEmpty) return {};
  final sim = SimulacaoGrafo(nos, arestas, lado: lado);
  for (var i = 0; i < passos; i++) {
    sim.passo();
  }
  return sim.posicoes;
}
