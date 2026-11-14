import 'package:agent_core/agent_core.dart';

/// Cópia das notas no aparelho, para ler, buscar, criar e editar sem conexão. No armazém
/// `notas`: `notas/<id>.json` (JSON como vem do servidor), `tipos.json`, `fila.json` e `ids.json`
/// (id provisório `offline-…` de nota criada sem conexão → id que o servidor deu).
class EspelhoNotas {
  Future<Armazem> get _armazem => Armazem.abrir('notas');

  Future<FilaOffline> get fila async => FilaOffline(await _armazem);

  Future<List<Map<String, dynamic>>> todas() async {
    final a = await _armazem;
    return [
      for (final n in await a.listar('notas'))
        if (await a.lerJson('notas/$n') case final Map<String, dynamic> j) j,
    ];
  }

  Future<Map<String, dynamic>?> obter(String id) async =>
      await (await _armazem).lerJson('notas/$id.json') as Map<String, dynamic>?;

  Future<void> guardar(Map<String, dynamic> nota) async => (await _armazem).gravarJson('notas/${nota['id']}.json', nota);

  Future<void> apagar(String id) async => (await _armazem).apagar('notas/$id.json');

  /// Troca o espelho inteiro pelo do servidor, mantendo as notas criadas offline ainda não enviadas.
  Future<void> substituir(List<Map<String, dynamic>> notas) async {
    final ids = {for (final n in notas) n['id']};
    for (final n in await todas()) {
      final id = n['id'] as String;
      if (!ids.contains(id) && !id.startsWith('offline-')) await apagar(id);
    }
    for (final n in notas) {
      await guardar(n);
    }
  }

  Future<List<dynamic>?> tipos() async => await (await _armazem).lerJson('tipos.json') as List?;

  Future<void> guardarTipos(List<dynamic> tipos) async => (await _armazem).gravarJson('tipos.json', tipos);

  Future<String> idReal(String id) async {
    if (!id.startsWith('offline-')) return id;
    final ids = await (await _armazem).lerJson('ids.json') as Map?;
    return ids?[id] as String? ?? id;
  }

  Future<void> mapear(String provisorio, String real) async {
    final a = await _armazem;
    await a.gravarJson('ids.json', {...(await a.lerJson('ids.json') as Map? ?? const {}), provisorio: real});
  }
}
