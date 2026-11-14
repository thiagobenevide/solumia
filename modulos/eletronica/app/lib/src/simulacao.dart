import 'package:agent_core/agent_core.dart';

import 'api_eletronica.dart';

/// Análises do ngspice que a tela oferece.
enum Analise {
  op('Ponto de operação', 'multímetro: tensão em cada rede e corrente em cada fonte'),
  tran('Transiente', 'osciloscópio: sinais no tempo'),
  ac('Resposta em frequência (AC)', 'ganho por frequência, escala logarítmica'),
  dc('Varredura DC', 'varia uma fonte e mede o circuito');

  const Analise(this.nome, this.dica);
  final String nome, dica;
}

/// Netlist SPICE gerada pelo servidor, o que ficou de fora (com os avisos) e as fontes que dá para varrer.
class Spice {
  const Spice({required this.texto, required this.ignorados, required this.fontes});

  final String texto;
  final List<String> ignorados;
  final List<String> fontes;

  factory Spice.fromJson(Map<String, dynamic> j) => Spice(
    texto: j['texto'] as String? ?? '',
    ignorados: [
      for (final i in j['ignorados'] as List? ?? []) i is Map ? '${i['ref']}: ${i['motivo']}' : '$i',
      for (final a in j['avisos'] as List? ?? []) a is Map ? '${a['mensagem'] ?? a}' : '$a',
    ],
    fontes: [for (final f in j['fontes'] as List? ?? []) '$f'],
  );
}

sealed class Resultado {
  const Resultado();

  factory Resultado.fromJson(Map<String, dynamic> j) {
    if (j['analise'] == 'op') {
      Map<String, double> mapa(Object? m) => {
        for (final e in (m as Map? ?? {}).entries) '${e.key}': (e.value as num).toDouble(),
      };
      return PontoOperacao(tensoes: mapa(j['tensoes']), correntes: mapa(j['correntes']));
    }
    final eixo = j['eixo'] as Map<String, dynamic>;
    List<double> lista(Object? l) => [for (final v in l as List) (v as num).toDouble()];
    return Curvas(
      analise: Analise.values.byName(j['analise'] as String),
      eixoNome: eixo['nome'] as String? ?? '',
      eixoUnidade: eixo['unidade'] as String? ?? '',
      eixo: lista(eixo['valores']),
      series: {for (final e in (j['series'] as Map).entries) '${e.key}': lista(e.value)},
      fases: {for (final e in (j['fases'] as Map? ?? {}).entries) '${e.key}': lista(e.value)},
    );
  }
}

class PontoOperacao extends Resultado {
  const PontoOperacao({required this.tensoes, required this.correntes});

  final Map<String, double> tensoes, correntes;
}

class Curvas extends Resultado {
  const Curvas({
    required this.analise,
    required this.eixoNome,
    required this.eixoUnidade,
    required this.eixo,
    required this.series,
    this.fases = const {},
  });

  final Analise analise;
  final String eixoNome, eixoUnidade;
  final List<double> eixo;
  final Map<String, List<double>> series;
  final Map<String, List<double>> fases;

  /// `v(...)` é tensão (V), `i(...)` corrente (A); cada grandeza vai num gráfico (nunca dois eixos y).
  static String unidadeDe(String serie) => serie.toLowerCase().startsWith('i(') ? 'A' : 'V';
}

extension ApiSimulacao on ApiEletronica {
  Future<Spice> spice(String projeto) async =>
      Spice.fromJson(await cliente.get('api/eletronica/projetos/$projeto/spice') as Map<String, dynamic>);

  /// Pede a simulação e consulta a tarefa a cada segundo até ficar pronta (ou [cancelado]).
  Future<Resultado> simular(
    String projeto,
    Map<String, dynamic> pedido, {
    bool Function()? cancelado,
    void Function(String estado)? aoMudar,
  }) async {
    final t = await cliente.post('api/eletronica/projetos/$projeto/simular', pedido) as Map<String, dynamic>;
    final limite = DateTime.now().add(const Duration(minutes: 3));
    while (true) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (cancelado?.call() ?? false) throw ApiErro(0, 'Cancelada.');
      if (DateTime.now().isAfter(limite)) throw ApiErro(0, 'A simulação passou de 3 minutos.');
      final r = await cliente.get('api/eletronica/simulacoes/${t['id']}') as Map<String, dynamic>;
      aoMudar?.call('${r['estado']}');
      if (r['estado'] == 'pronto') return Resultado.fromJson(r['resultado'] as Map<String, dynamic>);
      if (r['estado'] == 'erro') throw ApiErro(422, '${r['erro'] ?? 'falhou'}');
    }
  }
}
