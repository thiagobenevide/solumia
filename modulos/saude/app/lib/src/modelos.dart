/// Exercício do catálogo (`/api/saude/exercicios`): base da mini-academia ou criado pelo usuário.
class Exercicio {
  Exercicio({
    required this.id,
    required this.nome,
    required this.area,
    required this.grupo,
    required this.equipamento,
    required this.series,
    required this.repeticoes,
    required this.cargaKg,
    required this.instrucoes,
    required this.personalizado,
    required this.temImagem,
    required this.temSequencia,
  });

  factory Exercicio.fromJson(Map<String, dynamic> j) => Exercicio(
    id: j['id'] as String,
    nome: j['nome'] as String,
    area: j['area'] as String,
    grupo: j['grupo'] as String? ?? '',
    equipamento: j['equipamento'] as String? ?? '',
    series: j['series'] as int,
    repeticoes: j['repeticoes'] as String,
    cargaKg: (j['carga_kg'] as num?)?.toDouble(),
    instrucoes: j['instrucoes'] as String? ?? '',
    personalizado: j['personalizado'] as bool? ?? false,
    temImagem: j['imagem_propria'] == true || j['ref'] != null,
    temSequencia: j['imagem_propria'] != true && j['ref'] != null,
  );

  final String id;
  final String nome;
  final String area;
  final String grupo;
  final String equipamento;
  final int series;
  final String repeticoes;
  final double? cargaKg;
  final String instrucoes;
  final bool personalizado;

  /// Tem foto (enviada pelo usuário ou do free-exercise-db).
  final bool temImagem;

  /// Tem as duas imagens do movimento (início e fim), as do free-exercise-db.
  final bool temSequencia;

  Map<String, dynamic> toJson() => {
    'nome': nome,
    'area': area,
    'grupo': grupo,
    'equipamento': equipamento,
    'series': series,
    'repeticoes': repeticoes,
    'carga_kg': cargaKg,
    'instrucoes': instrucoes,
  };
}

/// Um exercício marcado num dia da agenda, com o que foi planejado e se foi feito.
class ItemAgenda {
  ItemAgenda({
    required this.id,
    required this.data,
    required this.exercicioId,
    required this.ordem,
    required this.series,
    required this.repeticoes,
    required this.cargaKg,
    required this.observacao,
    required this.feito,
  });

  factory ItemAgenda.fromJson(Map<String, dynamic> j) => ItemAgenda(
    id: j['id'] as String,
    data: DateTime.parse(j['data'] as String),
    exercicioId: j['exercicio_id'] as String,
    ordem: j['ordem'] as int,
    series: j['series'] as int,
    repeticoes: j['repeticoes'] as String,
    cargaKg: (j['carga_kg'] as num?)?.toDouble(),
    observacao: j['observacao'] as String? ?? '',
    feito: j['feito'] as bool? ?? false,
  );

  final String id;
  final DateTime data;
  final String exercicioId;
  final int ordem;
  final int series;
  final String repeticoes;
  final double? cargaKg;
  final String observacao;
  final bool feito;

  /// "3 × 12 · 20 kg"
  String get resumo => '$series × $repeticoes${cargaKg == null ? '' : ' · ${formatarCarga(cargaKg!)} kg'}';
}

String formatarCarga(double kg) => kg == kg.roundToDouble() ? '${kg.toInt()}' : '$kg'.replaceAll('.', ',');

/// O que se arrasta para o calendário: um exercício novo da biblioteca ou um item já marcado
/// (que muda de dia).
sealed class Arrasto {}

class ArrastoExercicio extends Arrasto {
  ArrastoExercicio(this.exercicio);

  final Exercicio exercicio;
}

class ArrastoItem extends Arrasto {
  ArrastoItem(this.item);

  final ItemAgenda item;
}
