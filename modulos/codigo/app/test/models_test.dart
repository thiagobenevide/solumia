import 'package:agent_codigo/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('árvore marca o que o commit mudou, inclusive nas pastas', () {
    final a = CodeTree({
      'commit': 'abc',
      'commits': [
        {'hash': 'abc', 'curto': 'abc', 'assunto': 'feat', 'autor': 't', 'data': '2026-10-31T10:00:00-03:00'},
      ],
      'arquivos': ['a/b.py', 'c.md'],
      'mudancas': [
        {'caminho': 'a/b.py', 'status': 'A'},
      ],
    });
    expect(a.changes['a/b.py'], 'A');
    expect(a.folderChanged('a'), isTrue);
    expect(a.commits.single.data, isNotNull);
    final f = CodeFile({'caminho': 'a/b.py', 'texto': 'x\n', 'novas': [1]});
    expect(f.novas, {1});
    expect(f.binary, isFalse);
  });

  test('atividade mostra a última ferramenta e some no fim', () {
    final steps = [
      SessionStep({'tipo': 'pedido', 'texto': 'crie', 'imagens': ['000-a.png']}),
      SessionStep({'tipo': 'ferramenta', 'nome': 'Bash', 'resumo': 'infra/scripts/verificar'}),
    ];
    expect(activity(steps), 'Bash: infra/scripts/verificar');
    expect(steps.first.images, ['000-a.png']);
    steps.add(SessionStep({'tipo': 'fim', 'turnos': 4, 'duracao_ms': 75000, 'custo_usd': 0.5}));
    expect(activity(steps), '');
    expect(steps.last.footer, '4 turnos · 1 min 15 s · US\$ 0.50');
  });

  test('sessão lê o estado do servidor', () {
    final s = CodeTab.fromJson({'id': 'a', 'titulo': 'Login', 'estado': 'rodando', 'eventos': 3, 'claude_sessao': 'x'});
    expect(s.running, isTrue);
    expect(s.claudeSession, 'x');
  });
}
