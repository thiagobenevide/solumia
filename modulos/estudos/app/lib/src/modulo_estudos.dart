import 'package:agent_concursos/agent_concursos.dart';
import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import 'api_estudos.dart';
import 'modelos.dart';
import 'telas/grafo_tela.dart';
import 'telas/idiomas_tela.dart';
import 'telas/linguagem_tela.dart';
import 'telas/projetos_tela.dart';
import 'telas/trilhas_tela.dart';

/// Concursos é submódulo de Estudos: uma seção da tela e um item do submenu lateral.
class ModuloEstudos extends Modulo {
  ModuloEstudos({required String url, String token = '', this.abrirNoArquivo})
    : api = ApiEstudos(url, token: token),
      concursos = ModuloConcursos(url: url, token: token);

  final ApiEstudos api;

  /// Abre o PDF no leitor do módulo Arquivos (para conferir um trecho na página).
  final AbrirNoArquivo? abrirNoArquivo;
  final ModuloConcursos concursos;

  @override
  String get id => 'estudos';

  @override
  String get nome => 'Estudos';

  @override
  String get descricao => 'Leituras, trilhas de conhecimento, grafo, idiomas e concursos';

  @override
  IconData get icone => Icons.school_outlined;

  @override
  List<SecaoModulo> get secoes => const [
    SecaoModulo('Leituras', Icons.menu_book_outlined),
    SecaoModulo('Trilhas', Icons.route_outlined),
    SecaoModulo('Grafo', Icons.hub_outlined),
    SecaoModulo('Idiomas', Icons.translate),
    SecaoModulo('Linguagem', Icons.record_voice_over_outlined),
    SecaoModulo('Concursos', Icons.assignment_outlined),
  ];

  @override
  final ValueNotifier<int> secaoAtual = ValueNotifier(0);

  @override
  void iniciar() => concursos.iniciar();

  @override
  Widget construir(BuildContext context) => _EstudosTela(modulo: this);
}

class _EstudosTela extends StatefulWidget {
  const _EstudosTela({required this.modulo});

  final ModuloEstudos modulo;

  @override
  State<_EstudosTela> createState() => _EstudosTelaState();
}

/// Sem abas internas: a seção vem do submenu lateral ([Modulo.secaoAtual]).
class _EstudosTelaState extends State<_EstudosTela> {
  ApiEstudos get api => widget.modulo.api;
  late Future<Opcoes> _opcoes = api.opcoes();

  /// Leituras, grafo e idiomas dependem das opções; Concursos não espera por elas.
  Widget _comOpcoes(Widget Function(Opcoes) tela) => FutureBuilder(
    future: _opcoes,
    builder: (context, s) {
      if (s.hasError) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              Text('${s.error}'),
              FilledButton(
                onPressed: () => setState(() => _opcoes = api.opcoes()),
                child: const Text('Tentar de novo'),
              ),
            ],
          ),
        );
      }
      final opcoes = s.data;
      if (opcoes == null) return const Center(child: CircularProgressIndicator());
      return tela(opcoes);
    },
  );

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: widget.modulo.secaoAtual,
    // IndexedStack mantém o estado de cada seção ao trocar pelo menu
    builder: (context, secao, _) => IndexedStack(
      index: secao,
      children: [
        _comOpcoes((o) => LeiturasEProjetos(api: api, opcoes: o, abrirNoArquivo: widget.modulo.abrirNoArquivo)),
        TrilhasTela(api: api, abrirNoArquivo: widget.modulo.abrirNoArquivo),
        _comOpcoes((o) => GrafoTela(api: api, areas: o.areas)),
        _comOpcoes((o) => IdiomasTela(api: api, opcoes: o)),
        _comOpcoes((o) => LinguagemTela(api: api, opcoes: o)),
        Builder(builder: widget.modulo.concursos.construir),
      ],
    ),
  );
}
