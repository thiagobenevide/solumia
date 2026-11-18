import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../panel_api.dart';
import '../models.dart';
import 'coach_chat.dart';
import 'llm_dashboard.dart';

class PanelScreen extends StatefulWidget {
  const PanelScreen({super.key, required this.api});

  final PanelApi api;

  @override
  State<PanelScreen> createState() => _PanelScreenState();
}

class _PanelScreenState extends State<PanelScreen> {
  late final _conversation = CoachConversation(widget.api);

  @override
  void dispose() {
    _conversation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 4,
    child: Column(
      children: [
        const TabBar(
          tabs: [
            Tab(icon: Icon(Icons.today_outlined), text: 'Hoje'),
            Tab(icon: Icon(Icons.forum_outlined), text: 'Cobrador'),
            Tab(icon: Icon(Icons.flag_outlined), text: 'Metas'),
            Tab(icon: Icon(Icons.speed_outlined), text: 'LLMs'),
          ],
        ),
        Expanded(
          child: TabBarView(
            children: [
              _Today(api: widget.api),
              CoachChat(conversation: _conversation),
              _Goals(api: widget.api),
              LlmDashboard(api: widget.api),
            ],
          ),
        ),
      ],
    ),
  );
}

// --- Today: discipline, alerts and editable schedule ---

class _Today extends StatelessWidget {
  const _Today({required this.api});

  final PanelApi api;

  Future<(Discipline, Agenda)> _load() async {
    final day = isoDate(DateTime.now());
    final r = await Future.wait([api.discipline(), api.agenda(day)]);
    return (r[0] as Discipline, r[1] as Agenda);
  }

  @override
  Widget build(BuildContext context) => Sondagem<(Discipline, Agenda)>(
    carregar: _load,
    intervalo: const Duration(seconds: 60),
    construir: (context, data, reload) {
      final (d, ag) = data;
      final summary = [
        _Entrance(order: 0, child: _Greeting(d: d, agenda: ag)),
        const SizedBox(height: 16),
        _Entrance(order: 1, child: _Scoreboard(d: d)),
        const SizedBox(height: 12),
        const _Entrance(order: 2, child: _QuickActions()),
      ];
      final day = [
        if (d.alerts.isNotEmpty) ...[
          const _SectionTitle(icon: Icons.notifications_active_outlined, text: 'Alertas'),
          for (var i = 0; i < d.alerts.length; i++)
            _Entrance(
              order: 3 + i,
              child: _AlertCard(alert: d.alerts[i]),
            ),
        ],
        const _SectionTitle(icon: Icons.event_note_outlined, text: 'Agenda de hoje'),
        _Entrance(
          order: 3 + d.alerts.length,
          child: _DaySchedule(api: api, agenda: ag, aoMudar: reload),
        ),
      ];
      return LayoutBuilder(builder: (context, box) => _layout(box.maxWidth, summary, day));
    },
  );

  /// PC (wide): summary on the left, alerts and agenda on the right; phone: one column.
  Widget _layout(double width, List<Widget> summary, List<Widget> day) {
    final side = width < 600 ? 16.0 : 28.0;
    if (width < 980) {
      return FundoVidro(
        child: ListView(padding: EdgeInsets.fromLTRB(side, 20, side, 24), children: [...summary, ...day]),
      );
    }
    return FundoVidro(child: _wide(side, summary, day));
  }

  Widget _wide(double side, List<Widget> summary, List<Widget> day) {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(side, 24, side, 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1280),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 5,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: summary),
              ),
              const SizedBox(width: 28),
              Expanded(
                flex: 6,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: day),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fades and slides the card in once, in cascade by [order] (60 s reloads do not replay it).
class _Entrance extends StatelessWidget {
  const _Entrance({required this.order, required this.child});

  final int order;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final delay = 80 * order.clamp(0, 8);
    final total = 380 + delay;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(delay / total, 1, curve: Curves.easeOutCubic),
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 18 * (1 - t)), child: child),
      ),
    );
  }
}

const _weekdays = ['segunda-feira', 'terça-feira', 'quarta-feira', 'quinta-feira', 'sexta-feira', 'sábado', 'domingo'];
const _months = [
  'janeiro',
  'fevereiro',
  'março',
  'abril',
  'maio',
  'junho',
  'julho',
  'agosto',
  'setembro',
  'outubro',
  'novembro',
  'dezembro',
];

/// "Boa noite, Thiago", today's date and, below, questions that take turns about what is still open
/// (blocks not done, goals behind, late tasks). Tapping the name changes how the person is called.
class _Greeting extends StatelessWidget {
  const _Greeting({required this.d, required this.agenda});

  final Discipline d;
  final Agenda agenda;

  String _salutation(int hour) {
    if (hour >= 5 && hour < 12) return 'Bom dia';
    if (hour >= 12 && hour < 18) return 'Boa tarde';
    return 'Boa noite';
  }

  IconData _icon(int hour) {
    if (hour >= 6 && hour < 12) return Icons.wb_sunny_rounded;
    if (hour >= 12 && hour < 18) return Icons.wb_twilight_rounded;
    return Icons.nights_stay_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    final onCard = colors.onPrimary;
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.primary, Color.lerp(colors.primary, colors.tertiary, 0.75)!],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        boxShadow: [
          BoxShadow(color: colors.primary.withValues(alpha: 0.28), blurRadius: 28, offset: const Offset(0, 12)),
        ],
      ),
      child: ValueListenableBuilder(
        valueListenable: NomeUsuario.nome,
        builder: (context, name, _) {
          final first = NomeUsuario.primeiro;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => perguntarNome(context),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            first.isEmpty ? '${_salutation(now.hour)}!' : '${_salutation(now.hour)}, $first',
                            style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800, color: onCard),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            first.isEmpty
                                ? 'Toque aqui e diga como quer ser chamado'
                                : '${_weekdays[now.weekday - 1]}, ${now.day} de ${_months[now.month - 1]}',
                            style: text.titleMedium?.copyWith(color: onCard.withValues(alpha: 0.85)),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Icon(_icon(now.hour), size: 48, color: onCard.withValues(alpha: 0.9)),
                ],
              ),
              const SizedBox(height: 14),
              _Nudges(messages: _messages(first), color: onCard),
            ],
          );
        },
      ),
    );
  }

  static final _goal = RegExp(r'^Meta [“"](.+?)[”"]: (\d+) de (\d+)');
  static final _late = RegExp(r'^[“"](.+?)[”"] vence atrasada');

  /// What to ask about, from the day's data (the names come from the blocks, goals and tasks).
  List<String> _messages(String first) {
    final who = first.isEmpty ? '' : ', $first';
    final messages = <String>[];
    final current = d.currentBlock;
    if (current != null) messages.add('Agora é hora de “${current.title}”$who. Bora?');
    for (final b in agenda.blocks) {
      if (!b.done && b.title != current?.title) messages.add('Já fez “${b.title}”$who? (${b.start}–${b.end})');
    }
    for (final a in d.alerts) {
      messages.add(_question(a.text, who));
    }
    if (messages.isEmpty) messages.add('Tudo em dia$who. Mandou bem!');
    return messages;
  }

  String _question(String alert, String who) {
    final goal = _goal.firstMatch(alert);
    if (goal != null) return 'Já fez “${goal[1]}” hoje$who? Está em ${goal[2]} de ${goal[3]}.';
    final late = _late.firstMatch(alert);
    if (late != null) return '“${late[1]}” está atrasada$who. Que tal encaixar hoje?';
    if (alert.startsWith('Sem agenda para hoje')) return 'Ainda não tem agenda hoje$who. Peça a sugestão do dia.';
    return who.isEmpty ? alert : '${who.substring(2)}, ${alert[0].toLowerCase()}${alert.substring(1)}';
  }
}

/// One question at a time, changing every 5 s with a slide from below (not a running ticker).
class _Nudges extends StatefulWidget {
  const _Nudges({required this.messages, required this.color});

  final List<String> messages;
  final Color color;

  @override
  State<_Nudges> createState() => _NudgesState();
}

class _NudgesState extends State<_Nudges> {
  int _index = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _next());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _next() {
    if (!mounted || widget.messages.length < 2) return;
    setState(() => _index = (_index + 1) % widget.messages.length);
  }

  static Widget _transition(Widget child, Animation<double> a) => FadeTransition(
    opacity: a,
    child: SlideTransition(
      position: Tween(begin: const Offset(0, 0.6), end: Offset.zero).animate(a),
      child: child,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final messages = widget.messages;
    final message = messages[_index % messages.length];
    return GestureDetector(
      onTap: _next,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        ),
        child: Row(
          children: [
            Icon(Icons.chat_bubble_rounded, size: 18, color: widget.color),
            const SizedBox(width: 10),
            Expanded(
              child: ClipRect(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 450),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: _transition,
                  layoutBuilder: (current, previous) => Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
                  child: Text(
                    message,
                    key: ValueKey(message),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: widget.color, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
            if (messages.length > 1) ...[
              const SizedBox(width: 8),
              Text(
                '${_index % messages.length + 1}/${messages.length}',
                style: TextStyle(color: widget.color.withValues(alpha: 0.7), fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Discipline of the day: score ring, state and counters.
class _Scoreboard extends StatelessWidget {
  const _Scoreboard({required this.d});

  final Discipline d;

  String _title() {
    if (d.score == null) return 'Dia ainda sem medição';
    if (d.inside) return 'Dentro da disciplina';
    return 'Fora da disciplina';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final good = d.score == null || d.inside;
    final background = good ? colors.primaryContainer : colors.errorContainer;
    final foreground = good ? colors.onPrimaryContainer : colors.onErrorContainer;
    final ring = good ? colors.primary : colors.error;
    // glass tinted by the state (blue inside the discipline, red outside)
    return AnimatedContainer(
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [background.withValues(alpha: 0.75), background.withValues(alpha: 0.45)],
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
        boxShadow: [BoxShadow(color: ring.withValues(alpha: 0.18), blurRadius: 26, offset: const Offset(0, 10))],
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 84,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // fills from where it was to the new score (and counts up the first time)
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: (d.score ?? 0).toDouble()),
                    duration: const Duration(milliseconds: 1100),
                    curve: Curves.easeOutCubic,
                    builder: (context, value, _) => Stack(
                      fit: StackFit.expand,
                      children: [
                        CircularProgressIndicator(
                          value: value / 100,
                          strokeWidth: 8,
                          strokeCap: StrokeCap.round,
                          color: ring,
                          backgroundColor: foreground.withValues(alpha: 0.15),
                        ),
                        Center(
                          child: Text(
                            d.score == null ? '–' : '${value.round()}',
                            style: text.headlineSmall?.copyWith(color: foreground, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _title(),
                    style: text.titleLarge?.copyWith(color: foreground, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      _Pill(
                        icon: Icons.check_circle_outline,
                        text: 'Blocos ${d.blocksDone}/${d.blocksOverdue}',
                        color: foreground,
                      ),
                      _Pill(
                        icon: Icons.flag_outlined,
                        text: 'Metas ${d.goalsOnTrack}/${d.goalsTotal}',
                        color: foreground,
                      ),
                    ],
                  ),
                  if (d.currentBlock != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      'Agora: ${d.currentBlock!.title} (até ${d.currentBlock!.end})',
                      style: text.bodyMedium?.copyWith(color: foreground),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text, required this.color});

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Text(text, style: TextStyle(color: color)),
      ],
    ),
  );
}

/// Shortcuts to the other tabs of the home page.
class _QuickActions extends StatelessWidget {
  const _QuickActions();

  @override
  Widget build(BuildContext context) {
    final tabs = DefaultTabController.of(context);
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: _ActionTile(
            icon: Icons.forum_rounded,
            title: 'Falar com o cobrador',
            subtitle: 'Conversa e cobrança do dia',
            color: colors.secondary,
            onTap: () => tabs.animateTo(1),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _ActionTile(
            icon: Icons.flag_rounded,
            title: 'Ver metas',
            subtitle: 'Progresso da semana',
            color: colors.tertiary,
            onTap: () => tabs.animateTo(2),
          ),
        ),
      ],
    );
  }
}

/// Shortcut card: lifts and lights up under the mouse (PC) and shrinks a bit when pressed.
class _ActionTile extends StatefulWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  @override
  State<_ActionTile> createState() => _ActionTileState();
}

class _ActionTileState extends State<_ActionTile> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final lifted = _hover && !_pressed;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.97 : 1,
          duration: const Duration(milliseconds: 120),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            transform: Matrix4.translationValues(0, lifted ? -3 : 0, 0),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Color.lerp(colors.surfaceContainerLow, widget.color, lifted ? 0.14 : 0.07),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: widget.color.withValues(alpha: lifted ? 0.6 : 0.25)),
              boxShadow: [
                if (lifted)
                  BoxShadow(color: widget.color.withValues(alpha: 0.2), blurRadius: 16, offset: const Offset(0, 6)),
              ],
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: widget.color.withValues(alpha: 0.18),
                  child: Icon(widget.icon, color: widget.color, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        widget.subtitle,
                        style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: colors.primary),
          const SizedBox(width: 8),
          Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _AlertCard extends StatelessWidget {
  const _AlertCard({required this.alert});

  final Alert alert;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final critical = alert.level == 'critico';
    final accent = critical ? colors.error : colors.tertiary;
    return Vidro(
      cor: accent,
      raio: 16,
      margem: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(critical ? Icons.priority_high_rounded : Icons.notifications_active_rounded, color: accent),
          const SizedBox(width: 12),
          Expanded(child: Text(alert.text)),
        ],
      ),
    );
  }
}

class _DaySchedule extends StatelessWidget {
  const _DaySchedule({required this.api, required this.agenda, required this.aoMudar});

  final PanelApi api;
  final Agenda agenda;
  final Future<void> Function() aoMudar;

  Future<void> _retry(BuildContext context, Future<void> Function() action) async {
    try {
      await action();
    } on ApiErro catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
    await aoMudar();
  }

  /// Edits (or creates, with a null [block]) and saves the whole schedule; shows the coach's objections.
  Future<void> _edit(BuildContext context, ScheduleBlock? block) async {
    final result = await showDialog<_Editing>(
      context: context,
      builder: (_) => _BlockEditor(block: block),
    );
    if (result == null || !context.mounted) return;
    final blocks = [...agenda.blocks];
    if (block != null) blocks.remove(block);
    if (result.block != null) blocks.add(result.block!);
    await _retry(context, () async {
      final saved = await api.save(agenda.data, blocks, result.reason);
      if (saved.objections.isNotEmpty && context.mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            icon: const Icon(Icons.gavel_outlined),
            title: const Text('O cobrador contesta'),
            content: Text(saved.objections.join('\n\n')),
            actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Entendi'))],
          ),
        );
      }
    });
  }

  Future<void> _suggest(BuildContext context) async {
    if (agenda.blocks.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Refazer a agenda?'),
          content: const Text('A sugestão substitui os blocos de hoje.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Refazer')),
          ],
        ),
      );
      if (ok != true || !context.mounted) return;
    }
    await _retry(context, () => api.suggest(agenda.data));
  }

  Future<void> _mark(BuildContext context, ScheduleBlock b, bool done) async {
    if (done) comemorar(context, mensagem: 'Bloco concluído');
    await _retry(context, () => api.mark(agenda.data, b.id!, done));
  }

  @override
  Widget build(BuildContext context) => Vidro(
    padding: const EdgeInsets.fromLTRB(14, 10, 10, 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Blocos do dia',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            TextButton.icon(
              icon: const Icon(Icons.auto_fix_high_outlined),
              label: const Text('Sugerir'),
              onPressed: () => _suggest(context),
            ),
            IconButton(tooltip: 'Novo bloco', icon: const Icon(Icons.add), onPressed: () => _edit(context, null)),
          ],
        ),
        if (agenda.blocks.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('Nenhum bloco. Use “Sugerir” para montar o dia com as tarefas do Kanban.'),
          ),
        for (final b in agenda.blocks)
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            margin: const EdgeInsets.only(top: 8),
            decoration: BoxDecoration(
              color: b.done
                  ? Colors.green.withValues(alpha: 0.12)
                  : Theme.of(context).colorScheme.surfaceContainerHigh.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(14),
            ),
            child: CheckboxListTile(
              value: b.done,
              onChanged: (v) => _mark(context, b, v ?? false),
              title: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 250),
                style: DefaultTextStyle.of(context).style.copyWith(
                  decoration: b.done ? TextDecoration.lineThrough : null,
                  color: b.done ? Theme.of(context).colorScheme.onSurfaceVariant : null,
                ),
                child: Text(b.title),
              ),
              subtitle: Text(
                '${b.start}–${b.end} · prioridade ${b.priority}${b.due == null ? '' : ' · prazo ${b.due}'}',
              ),
              secondary: IconButton(
                tooltip: 'Editar',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => _edit(context, b),
              ),
            ),
          ),
      ],
    ),
  );
}

/// Editor result: null [block] = delete. [reason] goes to the change history.
class _Editing {
  const _Editing(this.block, this.reason);

  final ScheduleBlock? block;
  final String reason;
}

class _BlockEditor extends StatefulWidget {
  const _BlockEditor({this.block});

  final ScheduleBlock? block;

  @override
  State<_BlockEditor> createState() => _BlockEditorState();
}

class _BlockEditorState extends State<_BlockEditor> {
  late final _title = TextEditingController(text: widget.block?.title);
  late final _start = TextEditingController(text: widget.block?.start ?? '09:00');
  late final _end = TextEditingController(text: widget.block?.end ?? '09:50');
  final _reason = TextEditingController();
  late String _priority = widget.block?.priority ?? 'media';
  final _time = RegExp(r'^\d{2}:\d{2}$');

  @override
  void dispose() {
    for (final c in [_title, _start, _end, _reason]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (_title.text.trim().isEmpty || !_time.hasMatch(_start.text) || !_time.hasMatch(_end.text)) return;
    final b = widget.block;
    Navigator.pop(
      context,
      _Editing(
        ScheduleBlock(
          id: b?.id,
          title: _title.text.trim(),
          start: _start.text,
          end: _end.text,
          priority: _priority,
          taskId: b?.taskId,
          due: b?.due,
          done: b?.done ?? false,
        ),
        _reason.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.block == null ? 'Novo bloco' : 'Editar bloco'),
    content: SizedBox(
      width: 380,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 12,
        children: [
          TextField(
            controller: _title,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Título'),
          ),
          Row(
            spacing: 12,
            children: [
              Expanded(
                child: TextField(
                  controller: _start,
                  decoration: const InputDecoration(labelText: 'Início (HH:MM)'),
                ),
              ),
              Expanded(
                child: TextField(
                  controller: _end,
                  decoration: const InputDecoration(labelText: 'Fim (HH:MM)'),
                ),
              ),
            ],
          ),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'baixa', label: Text('Baixa')),
              ButtonSegment(value: 'media', label: Text('Média')),
              ButtonSegment(value: 'alta', label: Text('Alta')),
            ],
            selected: {_priority},
            onSelectionChanged: (s) => setState(() => _priority = s.first),
          ),
          TextField(
            controller: _reason,
            decoration: const InputDecoration(labelText: 'Motivo da mudança (o cobrador registra)'),
          ),
        ],
      ),
    ),
    actions: [
      if (widget.block != null)
        TextButton(
          onPressed: () => Navigator.pop(context, _Editing(null, _reason.text.trim())),
          child: const Text('Excluir'),
        ),
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(onPressed: _save, child: const Text('Salvar')),
    ],
  );
}

// --- Goals ---

class _Goals extends StatelessWidget {
  const _Goals({required this.api});

  final PanelApi api;

  Future<void> _newConversation(BuildContext context, Future<void> Function() reload) async {
    final title = TextEditingController();
    final target = TextEditingController(text: '1');
    final unit = TextEditingController(text: 'vez');
    var frequency = 'diaria';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Nova meta'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              TextField(
                controller: title,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Meta'),
              ),
              Row(
                spacing: 12,
                children: [
                  Expanded(
                    child: TextField(
                      controller: target,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Alvo'),
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: unit,
                      decoration: const InputDecoration(labelText: 'Unidade'),
                    ),
                  ),
                ],
              ),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'diaria', label: Text('Por dia')),
                  ButtonSegment(value: 'semanal', label: Text('Por semana')),
                ],
                selected: {frequency},
                onSelectionChanged: (s) => setState(() => frequency = s.first),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Criar')),
          ],
        ),
      ),
    );
    final value = double.tryParse(target.text.replaceAll(',', '.'));
    if (ok == true && title.text.trim().isNotEmpty && value != null && value > 0) {
      await api.createGoal(title.text.trim(), frequency, value, unit.text.trim());
      await reload();
    }
    for (final c in [title, target, unit]) {
      c.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => Sondagem<List<Goal>>(
    carregar: api.goals,
    intervalo: const Duration(seconds: 60),
    construir: (context, goals, reload) => Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Meta'),
        onPressed: () => _newConversation(context, reload),
      ),
      body: goals.isEmpty
          ? const Center(child: Text('Sem metas. Crie as que o cobrador deve acompanhar.'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
              children: [
                for (final m in goals)
                  Card(
                    child: ListTile(
                      leading: Icon(
                        m.onTrack ? Icons.check_circle_outline : Icons.trending_down,
                        color: m.onTrack ? null : Theme.of(context).colorScheme.error,
                      ),
                      title: Text(m.title),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 4,
                        children: [
                          Text(
                            '${_n(m.done)}/${_n(m.target)} ${m.unit} ${m.frequency == 'diaria' ? 'hoje' : 'na semana'}'
                            ' · esperado agora ${_n(m.expected)}',
                          ),
                          LinearProgressIndicator(value: (m.done / m.target).clamp(0, 1)),
                        ],
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Registrar +1',
                            icon: const Icon(Icons.add_task),
                            onPressed: () async {
                              await api.register(m.id);
                              await reload();
                            },
                          ),
                          IconButton(
                            tooltip: 'Excluir',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              await api.deleteGoal(m.id);
                              await reload();
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    ),
  );
}

String _n(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
