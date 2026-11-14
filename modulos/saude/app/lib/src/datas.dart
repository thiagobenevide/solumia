/// Datas do calendário sem depender de `intl`: tudo em dias locais (sem hora), semana de segunda
/// a domingo.
library;

const meses = [
  'janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho',
  'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro',
];
const diasSemana = ['seg', 'ter', 'qua', 'qui', 'sex', 'sáb', 'dom'];
const diasSemanaLongos = ['segunda', 'terça', 'quarta', 'quinta', 'sexta', 'sábado', 'domingo'];

DateTime dia(DateTime d) => DateTime(d.year, d.month, d.day);

DateTime hoje() => dia(DateTime.now());

/// Soma dias pelo calendário (não por 24 h, que erra no horário de verão).
DateTime somarDias(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);

bool mesmoDia(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

DateTime inicioSemana(DateTime d) => somarDias(dia(d), -(d.weekday - 1));

/// As 6 semanas (42 dias) que a grade do mês mostra, começando na segunda.
List<DateTime> gradeMes(DateTime d) {
  final inicio = inicioSemana(DateTime(d.year, d.month));
  return [for (var i = 0; i < 42; i++) somarDias(inicio, i)];
}

String iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String mesAno(DateTime d) => '${meses[d.month - 1]} de ${d.year}';

String diaCurto(DateTime d) => '${d.day} ${meses[d.month - 1].substring(0, 3)}';

/// "segunda, 2 de novembro"
String diaLongo(DateTime d) => '${diasSemanaLongos[d.weekday - 1]}, ${d.day} de ${meses[d.month - 1]}';
