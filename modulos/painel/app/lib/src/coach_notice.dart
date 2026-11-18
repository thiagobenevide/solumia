import 'models.dart';

/// What a coach alert says as a notification: a specific title (the task or goal itself), a short
/// body saying what to do, and a one-line version for the summary of several alerts. The alert
/// texts come from the server's nagger (`panel/nagger.py`); an unknown text keeps the generic form.
class CoachNotice {
  const CoachNotice({required this.title, required this.body, required this.line, required this.critical});

  final String title;
  final String body;

  /// "Name — what is wrong", for the list in the summary notification.
  final String line;
  final bool critical;

  static final _block = RegExp(r'^“(.+)” \((\d{1,2}:\d{2})–(\d{1,2}:\d{2})\) passou');
  static final _deadline = RegExp(r'^“(.+)” vence (hoje|atrasada)');
  static final _goal = RegExp(r'^Meta “(.+)”: (.+) esperados\.?$');

  factory CoachNotice.from(Alert a) {
    final critical = a.level == 'critico';
    final deadline = _deadline.firstMatch(a.text);
    if (deadline != null) {
      return _fromDeadline(deadline.group(1)!, deadline.group(2) == 'hoje', critical);
    }
    final block = _block.firstMatch(a.text);
    if (block != null) {
      return _fromBlock(block.group(1)!, block.group(2)!, block.group(3)!, critical);
    }
    final goal = _goal.firstMatch(a.text);
    if (goal != null) {
      return CoachNotice(
        title: 'Meta em atraso: ${goal.group(1)}',
        body: '${goal.group(2)} até agora. Ainda dá tempo de recuperar.',
        line: '${goal.group(1)} — meta em atraso',
        critical: critical,
      );
    }
    if (a.text.startsWith('Sem agenda para hoje')) {
      return CoachNotice(
        title: 'Seu dia ainda não tem agenda',
        body: 'Peça a sugestão do dia e ajuste os horários.',
        line: 'Dia sem agenda',
        critical: critical,
      );
    }
    return CoachNotice(title: 'Solumia', body: a.text, line: a.text, critical: critical);
  }

  static CoachNotice _fromDeadline(String task, bool today, bool critical) {
    if (today) {
      return CoachNotice(
        title: 'Vence hoje: $task',
        body: 'Ainda não tem horário na agenda. Reserve um tempo para ela hoje.',
        line: '$task — vence hoje',
        critical: critical,
      );
    }
    return CoachNotice(
      title: 'Prazo vencido: $task',
      body: 'Está atrasada e sem horário na agenda. Escolha um horário ou ajuste o prazo.',
      line: '$task — prazo vencido',
      critical: critical,
    );
  }

  static CoachNotice _fromBlock(String task, String start, String end, bool critical) {
    return CoachNotice(
      title: 'Ficou feito? $task',
      body: 'O horário das $start às $end acabou. Se terminou, marque como feito.',
      line: '$task — sem check ($start–$end)',
      critical: critical,
    );
  }
}

/// Several alerts at once become one notification: a count in the title and one line per alert.
class CoachSummary {
  CoachSummary(this.notices);

  final List<CoachNotice> notices;

  bool get critical {
    for (final n in notices) {
      if (n.critical) return true;
    }
    return false;
  }

  String get title {
    final count = notices.length;
    var overdue = 0;
    for (final n in notices) {
      if (n.title.startsWith('Prazo vencido')) overdue++;
    }
    if (overdue == count) return '$count tarefas com prazo vencido';
    return '$count pendências pedem atenção';
  }

  List<String> get lines {
    final result = <String>[];
    for (final n in notices) {
      result.add('• ${n.line}');
    }
    return result;
  }
}
