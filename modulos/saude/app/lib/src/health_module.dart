import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import 'health_api.dart';
import 'sync.dart';
import 'screens/analysis_screen.dart';
import 'screens/coach_screen.dart';
import 'screens/usage_screen.dart';
import 'screens/spiritual_screen.dart';
import 'screens/mental_screen.dart';
import 'screens/watch_screen.dart';
import 'screens/workouts_screen.dart';

/// No top tabs: each part is a section of the side submenu ([secaoAtual]), as in Estudos.
class HealthModule extends Modulo {
  HealthModule({required this.url, this.token = ''}) : api = HealthApi(url, token: token);

  final String url;
  final String token;
  final HealthApi api;

  /// On Android: reads the watch now and schedules the reading every hour in the background.
  @override
  void iniciar() => scheduleSync(url, token, api);

  @override
  String get id => 'saude';

  @override
  String get nome => 'Saúde';

  @override
  String get descricao => 'Espiritual, físico e mental, com os dados do relógio';

  @override
  IconData get icone => Icons.favorite_outline;

  @override
  double? get larguraMaxima => 1600;

  @override
  List<SecaoModulo> get secoes => const [
    SecaoModulo('Treinos', Icons.fitness_center),
    SecaoModulo('Treinador IA', Icons.auto_awesome),
    SecaoModulo('Espiritual', Icons.menu_book_outlined),
    SecaoModulo('Sono e corpo', Icons.watch_outlined),
    SecaoModulo('Análise', Icons.auto_awesome_outlined),
    SecaoModulo('Hábitos', Icons.check_circle_outline),
    SecaoModulo('Foco', Icons.timer_outlined),
    SecaoModulo('Humor e ansiedade', Icons.self_improvement),
    SecaoModulo('Consumo', Icons.shield_moon_outlined),
  ];

  @override
  final ValueNotifier<int> secaoAtual = ValueNotifier(0);

  @override
  Widget construir(BuildContext context) => ValueListenableBuilder(
    valueListenable: secaoAtual,
    // IndexedStack keeps the state of each section when switching from the menu
    builder: (context, section, _) => IndexedStack(
      index: section,
      children: [
        WorkoutsScreen(api: api),
        CoachScreen(api: api),
        SpiritualScreen(api: api),
        WatchScreen(api: api),
        AnalysisScreen(api: api),
        HabitsScreen(api: api),
        FocusScreen(api: api),
        AnxietyScreen(api: api),
        UsageScreen(api: api),
      ],
    ),
  );
}
