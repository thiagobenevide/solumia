/// Calendar dates without depending on `intl`: everything in local days (no time), week from Monday
/// to Sunday.
library;

const months = [
  'janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho',
  'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro',
];
const weekdays = ['seg', 'ter', 'qua', 'qui', 'sex', 'sáb', 'dom'];
const longWeekdays = ['segunda', 'terça', 'quarta', 'quinta', 'sexta', 'sábado', 'domingo'];

DateTime day(DateTime d) => DateTime(d.year, d.month, d.day);

DateTime today() => day(DateTime.now());

/// Adds days by the calendar (not by 24 h, which fails on daylight saving time).
DateTime addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);

bool sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

DateTime weekStart(DateTime d) => addDays(day(d), -(d.weekday - 1));

/// The 6 weeks (42 days) the month grid shows, starting on Monday.
List<DateTime> gradeMes(DateTime d) {
  final start = weekStart(DateTime(d.year, d.month));
  return [for (var i = 0; i < 42; i++) addDays(start, i)];
}

String iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String monthYear(DateTime d) => '${months[d.month - 1]} de ${d.year}';

String shortDay(DateTime d) => '${d.day} ${months[d.month - 1].substring(0, 3)}';

/// "segunda, 2 de novembro"
String longDay(DateTime d) => '${longWeekdays[d.weekday - 1]}, ${d.day} de ${months[d.month - 1]}';
