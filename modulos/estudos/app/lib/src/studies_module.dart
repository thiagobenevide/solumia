import 'package:agent_concursos/agent_concursos.dart';
import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import 'studies_api.dart';
import 'models.dart';
import 'screens/graph_screen.dart';
import 'screens/foreign_languages_screen.dart';
import 'screens/language_screen.dart';
import 'screens/projects_screen.dart';
import 'screens/tracks_screen.dart';

/// Concursos is a submodule of Estudos: a section of the screen and an item of the side submenu.
class StudiesModule extends Modulo {
  StudiesModule({required String url, String token = '', this.openInFile})
    : api = StudiesApi(url, token: token),
      exams = ExamsModule(url: url, token: token);

  final StudiesApi api;

  /// Opens the PDF in the reader of the Arquivos module (to check an excerpt on the page).
  final OpenInFile? openInFile;
  final ExamsModule exams;

  @override
  String get id => 'estudos';

  @override
  TemaCena get cena => TemaCena.estudos;

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
  void iniciar() => exams.iniciar();

  @override
  Widget construir(BuildContext context) => _StudiesScreen(modulo: this);
}

class _StudiesScreen extends StatefulWidget {
  const _StudiesScreen({required this.modulo});

  final StudiesModule modulo;

  @override
  State<_StudiesScreen> createState() => _StudiesScreenState();
}

/// No inner tabs: the section comes from the side submenu ([Modulo.secaoAtual]).
class _StudiesScreenState extends State<_StudiesScreen> {
  StudiesApi get api => widget.modulo.api;
  late Future<StudyOptions> _options = api.options();

  /// Leituras, graph and languages depend on the options; Concursos does not wait for them.
  Widget _withOptions(Widget Function(StudyOptions) screen) => FutureBuilder(
    future: _options,
    builder: (context, s) {
      if (s.hasError) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              Text('${s.error}'),
              FilledButton(
                onPressed: () => setState(() => _options = api.options()),
                child: const Text('Tentar de novo'),
              ),
            ],
          ),
        );
      }
      final options = s.data;
      if (options == null) return const Center(child: CircularProgressIndicator());
      return screen(options);
    },
  );

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: widget.modulo.secaoAtual,
    // IndexedStack keeps the state of each section when switching from the menu
    builder: (context, section, _) => IndexedStack(
      index: section,
      children: [
        _withOptions((o) => ReadingsAndProjects(api: api, options: o, openInFile: widget.modulo.openInFile)),
        TracksScreen(api: api, openInFile: widget.modulo.openInFile),
        _withOptions((o) => GraphScreen(api: api, areas: o.areas)),
        _withOptions((o) => ForeignLanguagesScreen(api: api, options: o)),
        _withOptions((o) => LanguageScreen(api: api, options: o)),
        Builder(builder: widget.modulo.exams.construir),
      ],
    ),
  );
}
