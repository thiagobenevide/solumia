import 'package:agent_empreendimento/src/modelos.dart';
import 'package:flutter_test/flutter_test.dart';

// Amostras no formato que `esteira/web/api.py` devolve.
const _prog = {
  'feitas': 5, 'total': 8, 'rodando': 'graficos', 'erro': null, //
  'desatualizado': false, 'final': false, 'thumb': false,
};

void main() {
  test('episódio com etapas, eventos e thumbs', () {
    final e = Episodio.fromJson({
      'id': 'finlumia-003',
      'canal': 'finlumia',
      'numero': '003',
      'titulo': 'Bola de neve ou avalanche?',
      'prog': _prog,
      'thumbs': [
        {'vaga': 1, 'url': '/arq/finlumia-003/thumb_1.png?v=1'},
      ],
      'etapas': [
        {
          'id': 'limpar',
          'nome': 'Cortes da narração',
          'status': 'ok',
          'start': '2026-10-27T21:18:29.418',
          'message': 'bruta 995s → editada 372s',
          'warnings': 41,
          'i': 371,
          'n': 371,
          'remaining': 0.0,
          'duration': 142.7,
        },
        {'id': 'graficos', 'nome': 'Gráficos animados', 'status': 'running', 'i': 4, 'n': 17, 'remaining': 30},
        {'id': 'thumb', 'nome': 'Thumbnail', 'status': 'pending'},
      ],
      'eventos': [
        {'t': '2026-10-27T21:49:27.699', 'stage': 'thumb', 'kind': 'end', 'message': ''},
      ],
      'gasto_claude': 0.12,
      'video': null,
    });
    expect(e.prog.estado, 'rodando');
    expect(e.prog.fracao, 5 / 8);
    expect(e.etapas[0].duracaoSegundos, 142.7);
    expect(e.etapas[1].fracao, 4 / 17);
    expect(e.etapas[1].restaSegundos, 30);
    expect(e.etapas[2].fracao, isNull);
    expect(e.thumbs.single.vaga, 1);
    expect(e.gastoClaude, 0.12);
    expect(e.video, isNull);
  });

  test('fila com vaga ocupada e tarefa de roteiro sem progresso', () {
    final f = Fila.fromJson({
      'tarefas': [
        {
          'id': 1793146709366,
          'ep': 'finlumia-003',
          'comando': 'tudo',
          'args': ['--refazer'],
          'vaga': 'machine',
          'estado': 'rodando',
          'criado': '2026-10-27T21:18:29',
          'inicio': '2026-10-27T21:18:29',
          'prog': _prog,
        },
        {
          'id': 2,
          'ep': 'finlumia:51',
          'comando': 'roteiro',
          'args': [],
          'vaga': 'claude',
          'estado': 'ok',
          'criado': '2026-10-27T21:00:00',
          'prog': null,
        },
      ],
      'vagas': {
        'machine': {'pid': 10, 'command': 'tudo finlumia-003'},
        'claude': null,
      },
    });
    expect(f.tarefas.first.ativa, isTrue);
    expect(f.tarefas.last.prog, isNull);
    expect(f.vagas, {'machine': 'tudo finlumia-003', 'claude': null});
  });

  test('roteiro ainda sem episódio', () {
    final r = Roteiro.fromJson({
      'canal': 'finlumia',
      'numero': 7,
      'short': 'a',
      'formato': '9:16',
      'titulo': 'X',
      'modo': 'dark',
      'status': 'rascunho',
      'caminho': '/vault/x.md',
      'atualizado': '2026-10-26',
      'audio': false,
      'ep': null,
      'prog': null,
    });
    expect(r.rotulo, '007a');
    expect(r.prog, isNull);
  });

  test('máquina antes do monitor coletar', () {
    final m = Maquina.fromJson({
      'gpu': null,
      'cpu': null,
      'ram': null,
      'ollama': null,
      'energia': {'kwh': 0},
    });
    expect(m.coletando, isFalse);
    expect(m.ollama, isEmpty);
  });
}
