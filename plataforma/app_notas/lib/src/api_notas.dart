import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/foundation.dart';

import 'modelos.dart';
import 'offline.dart';

/// Rotas de `/api/notas` do backend da plataforma (`backend/notes/api.py`). Sem conexão, lê e
/// grava no espelho do aparelho ([EspelhoNotas]); o que foi feito offline sobe na próxima chamada
/// que alcançar o servidor.
class ApiNotas {
  ApiNotas(String base, {String token = ''})
    : _api = ApiCliente(base, cabecalhos: token.isEmpty ? const {} : {'Authorization': 'Bearer $token'});

  final ApiCliente _api;
  final _espelho = EspelhoNotas();
  List<TipoNota>? _tipos;
  // "Nota" também lista os tipos do vault que o app não conhece (roteiro, moc...)
  Set<String> get _tiposDoApp => {for (final t in _tipos ?? const <TipoNota>[]) t.id}..remove('nota');
  DateTime? _espelhado;

  /// `atualizada` que o próprio aparelho gravou ao sincronizar: não conta como edição de outro lugar.
  final _proprias = <String, String>{};

  /// Para a tela: sem conexão agora, quantas alterações esperam para subir e avisos da última
  /// sincronização (ex.: conflito que virou cópia).
  final offline = ValueNotifier(false);
  final pendencias = ValueNotifier(0);
  final avisos = ValueNotifier(<String>[]);

  Future<T> _ouLocal<T>(Future<T> Function() remoto, Future<T> Function() local) async {
    try {
      final r = await remoto();
      offline.value = false;
      return r;
    } on ApiErro catch (e) {
      if (!semConexao(e)) rethrow;
      offline.value = true;
      return local();
    }
  }

  /// Sobe o que ficou pendente antes de ler do servidor; de tempos em tempos renova o espelho.
  Future<void> _antesDeLer() async {
    if ((await (await _espelho.fila).itens()).isNotEmpty) {
      try {
        await sincronizar();
      } on ApiErro catch (e) {
        if (semConexao(e)) rethrow; // outro erro (ex.: backend antigo sem /espelho) não impede a leitura
      }
    } else if (_espelhado == null || DateTime.now().difference(_espelhado!) > const Duration(minutes: 10)) {
      _espelhado = DateTime.now();
      unawaited(sincronizar().then<void>((_) {}, onError: (_) => _espelhado = null));
    }
  }

  Future<List<NotaResumo>> listar({String q = '', String? tipo}) => _ouLocal(
    () async {
      await _antesDeLer();
      final qs = Uri(queryParameters: {'q': q, 'tipo': ?tipo}).query;
      return [for (final j in await _api.get('api/notas?$qs') as List) NotaResumo.fromJson(j)];
    },
    () async {
      final termo = q.toLowerCase();
      final achadas = [
        for (final j in await _espelho.todas())
          if ((tipo == null || j['tipo'] == tipo || tipo == 'nota' && !_tiposDoApp.contains(j['tipo'])) &&
              [j['titulo'], ...?j['aliases'] as List?, j['corpo']].any((t) => '$t'.toLowerCase().contains(termo)))
            j,
      ]..sort((a, b) => '${b['atualizada']}'.compareTo('${a['atualizada']}'));
      return [for (final j in achadas) NotaResumo.fromJson({...j, 'entradas': (j['entradas'] as List?)?.length ?? 0})];
    },
  );

  /// Os tipos quase nunca mudam: busca uma vez por sessão.
  Future<List<TipoNota>> tipos() async => _tipos ??= await _ouLocal<List<TipoNota>>(
    () async {
      final j = await _api.get('api/notas/tipos') as List;
      await _espelho.guardarTipos(j);
      return [for (final t in j) TipoNota.fromJson(t)];
    },
    () async => [for (final t in await _espelho.tipos() ?? const []) TipoNota.fromJson(t)],
  );

  Future<List<String>> sugestoes(String q) => _ouLocal(
    () async => [
      for (final j in await _api.get('api/notas/sugestoes?${Uri(queryParameters: {'q': q}).query}') as List)
        j['titulo'] as String,
    ],
    () async => [
      for (final j in await _espelho.todas())
        if ('${j['titulo']}'.toLowerCase().contains(q.toLowerCase())) j['titulo'] as String,
    ].take(10).toList(),
  );

  Future<Nota> obter(String id) async {
    id = await _espelho.idReal(id);
    return _ouLocal(
      () async {
        await _antesDeLer();
        final j = await _api.get('api/notas/$id') as Map<String, dynamic>;
        await _espelho.guardar(j);
        return Nota.fromJson(j);
      },
      () async {
        final j = await _espelho.obter(id);
        if (j == null) throw ApiErro(0, 'Sem conexão e esta nota ainda não estava no aparelho');
        return Nota.fromJson(j);
      },
    );
  }

  Future<Nota> criar(Map<String, dynamic> dados) => _ouLocal(
    () async {
      final j = await _api.post('api/notas', dados) as Map<String, dynamic>;
      await _espelho.guardar(j);
      return Nota.fromJson(j);
    },
    () async {
      final agora = DateTime.now().toIso8601String();
      final id = 'offline-${DateTime.now().microsecondsSinceEpoch}';
      final j = _local({'id': id, 'tipo': 'nota', 'criada': agora, '_base': null, ...dados}, agora);
      await (await _espelho.fila).adicionar({'op': 'criar', 'id': id, 'dados': dados});
      await _espelho.guardar(j);
      await _contarPendencias();
      return Nota.fromJson(j);
    },
  );

  Future<Nota> salvar(String id, Map<String, dynamic> dados) async {
    id = await _espelho.idReal(id);
    return _ouLocal(
      () async {
        final j = await _api.put('api/notas/$id', dados) as Map<String, dynamic>;
        await _espelho.guardar(j);
        return Nota.fromJson(j);
      },
      () async {
        final atual = await _espelho.obter(id);
        if (atual == null) throw ApiErro(0, 'Sem conexão e esta nota ainda não estava no aparelho');
        // `_base`: a `atualizada` do servidor quando a edição offline começou (detecta conflito).
        final base = atual.containsKey('_base') ? atual['_base'] : atual['atualizada'];
        final j = _local({...atual, ...dados, '_base': base}, DateTime.now().toIso8601String());
        await (await _espelho.fila).adicionar({'op': 'salvar', 'id': id, 'dados': dados, 'base': base});
        await _espelho.guardar(j);
        await _contarPendencias();
        return Nota.fromJson(j);
      },
    );
  }

  Future<void> excluir(String id) async {
    id = await _espelho.idReal(id);
    await _ouLocal(() => _api.delete('api/notas/$id'), () async {
      await (await _espelho.fila).adicionar({'op': 'excluir', 'id': id});
      await _contarPendencias();
    });
    await _espelho.apagar(id);
  }

  Future<Analise> analise() async => Analise.fromJson(await _api.get('api/notas/analise'));

  /// Nota gravada só no aparelho, com os campos que a lista e o editor usam.
  static Map<String, dynamic> _local(Map<String, dynamic> j, String agora) {
    final props = Map<String, dynamic>.from(j['propriedades'] as Map? ?? const {});
    return {...j, 'atualizada': agora, 'status': props['status'] ?? j['status'], 'prazo': props['prazo'] ?? j['prazo']};
  }

  Future<void> _contarPendencias() async => pendencias.value = (await (await _espelho.fila).itens()).length;

  /// Sobe a fila feita offline e renova o espelho com todas as notas do servidor. Sem conexão,
  /// lança [ApiErro] com status 0.
  Future<List<String>> sincronizar() async {
    final feitos = await (await _espelho.fila).processar(_executar);
    await _contarPendencias();
    final todas = [for (final j in await _api.get('api/notas/espelho') as List) Map<String, dynamic>.from(j)];
    await _espelho.substituir(todas);
    _espelhado = DateTime.now();
    if (feitos.isNotEmpty) avisos.value = [...avisos.value, ...feitos];
    return feitos;
  }

  Future<String?> _executar(Map<String, dynamic> op) async {
    final dados = Map<String, dynamic>.from(op['dados'] as Map? ?? const {});
    switch (op['op']) {
      case 'criar':
        Map<String, dynamic> j;
        try {
          j = await _api.post('api/notas', dados) as Map<String, dynamic>;
        } on ApiErro catch (e) {
          if (e.status != 409) rethrow; // já existe nota com o título: entra como cópia
          j = await _api.post('api/notas', {...dados, 'titulo': '${dados['titulo']} (offline)'}) as Map<String, dynamic>;
        }
        await _espelho.mapear(op['id'] as String, j['id'] as String);
        await _espelho.apagar(op['id'] as String);
        await _espelho.guardar(j);
      case 'salvar':
        final id = await _espelho.idReal(op['id'] as String);
        final servidor = await _api.get('api/notas/$id') as Map<String, dynamic>;
        final base = op['base'];
        if (base != null && servidor['atualizada'] != base && servidor['atualizada'] != _proprias[id]) {
          // Editada aqui offline e em outro lugar: nada se perde, a versão do aparelho vira cópia.
          final dt = DateTime.now();
          final titulo = '${dados['titulo'] ?? servidor['titulo']} (offline ${dt.day}/${dt.month} ${dt.hour}h${dt.minute})';
          await _api.post('api/notas', {
            for (final c in ['tipo', 'tags', 'aliases', 'propriedades', 'corpo']) c: dados[c] ?? servidor[c],
            'titulo': titulo,
          });
          return '"${servidor['titulo']}" mudou em outro lugar enquanto você estava offline; sua versão virou "$titulo".';
        }
        final j = await _api.put('api/notas/$id', dados) as Map<String, dynamic>;
        _proprias[id] = j['atualizada'] as String;
        await _espelho.guardar(j);
      case 'excluir':
        await _api.delete('api/notas/${await _espelho.idReal(op['id'] as String)}');
    }
    return null;
  }
}
