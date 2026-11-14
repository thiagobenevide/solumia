import 'package:agent_codigo/src/modelos.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('árvore marca o que o commit mudou, inclusive nas pastas', () {
    final a = ArvoreCodigo({
      'commit': 'abc',
      'commits': [
        {'hash': 'abc', 'curto': 'abc', 'assunto': 'feat', 'autor': 't', 'data': '2026-10-31T10:00:00-03:00'},
      ],
      'arquivos': ['a/b.py', 'c.md'],
      'mudancas': [
        {'caminho': 'a/b.py', 'status': 'A'},
      ],
    });
    expect(a.mudancas['a/b.py'], 'A');
    expect(a.pastaMudou('a'), isTrue);
    expect(a.commits.single.data, isNotNull);
    final f = ArquivoCodigo({'caminho': 'a/b.py', 'texto': 'x\n', 'novas': [1]});
    expect(f.novas, {1});
    expect(f.binario, isFalse);
  });

  test('atividade mostra a última ferramenta e some no fim', () {
    final etapas = [
      Etapa({'tipo': 'pedido', 'texto': 'crie', 'imagens': ['000-a.png']}),
      Etapa({'tipo': 'ferramenta', 'nome': 'Bash', 'resumo': 'infra/scripts/verificar'}),
    ];
    expect(atividade(etapas), 'Bash: infra/scripts/verificar');
    expect(etapas.first.imagens, ['000-a.png']);
    etapas.add(Etapa({'tipo': 'fim', 'turnos': 4, 'duracao_ms': 75000, 'custo_usd': 0.5}));
    expect(atividade(etapas), '');
    expect(etapas.last.rodape, '4 turnos · 1 min 15 s · US\$ 0.50');
  });

  test('sessão lê o estado do servidor', () {
    final s = AbaCodigo.fromJson({'id': 'a', 'titulo': 'Login', 'estado': 'rodando', 'eventos': 3, 'claude_sessao': 'x'});
    expect(s.rodando, isTrue);
    expect(s.claudeSessao, 'x');
  });
}
