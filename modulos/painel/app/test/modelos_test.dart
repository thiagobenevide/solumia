import 'package:agent_painel/src/modelos.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('disciplina e agenda vindas da API', () {
    final d = Disciplina.fromJson({
      'indice': 50,
      'dentro': false,
      'blocos': {'total': 2, 'vencidos': 2, 'feitos': 1},
      'bloco_atual': null,
      'metas': {'total': 1, 'no_ritmo': 0},
      'alertas': [
        {'nivel': 'critico', 'texto': 'x'},
      ],
    });
    expect((d.indice, d.dentro, d.alertas.single.nivel), (50, false, 'critico'));

    final ag = Agenda.fromJson({
      'data': '2026-10-28',
      'blocos': [
        {'id': 'b1', 'titulo': 'A', 'inicio': '08:00', 'fim': '08:50', 'prioridade': 'alta', 'feito': false},
      ],
      'contestacoes': ['empurrou'],
    });
    expect(ag.blocos.single.toJson()['id'], 'b1');
    expect(ag.blocos.single.toJson().containsKey('tarefa_id'), isFalse);
    expect(ag.contestacoes, ['empurrou']);
    expect(dataIso(DateTime(2026, 3, 5)), '2026-03-05');
  });

  test('resposta com ações e dashboard', () {
    final r = Resposta.fromJson({
      'resposta': 'Feito.',
      'executadas': [
        {'tipo': 'criar_tarefa', 'ok': true, 'detalhe': 'Tarefa criada: A'},
        {'tipo': 'remover_bloco', 'ok': false, 'detalhe': 'Não achei “B”.'},
      ],
      'transcricao': 'cria a tarefa A',
    });
    expect(r.completa, 'Feito.\n✔ Tarefa criada: A\n✖ Não achei “B”.');
    expect(r.transcricao, 'cria a tarefa A');

    final d = Dashboard.fromJson({
      'provedores': {
        'local': {
          'pedidos': 2, 'erros': 1, 'disponibilidade_pct': 50.0, 'latencia_p50_ms': 100,
          'latencia_p95_ms': 300, 'tokens_entrada': 0, 'tokens_saida': 0, 'ultimo_em': 1.0,
        },
      },
      'configurados': ['local'],
      'workers': [],
      'recentes': [],
    });
    expect((d.provedores.single.nome, d.provedores.single.p95), ('local', 300));
  });
}
