import 'package:flutter/material.dart';

import '../api_saude.dart';
import '../modelos.dart';
import 'comuns.dart';

/// Exercícios em drill-down: área do corpo → grupo muscular → exercício. Cada exercício se arrasta
/// para um dia do calendário; o + marca no dia em foco e o toque abre os detalhes.
class BibliotecaExercicios extends StatefulWidget {
  const BibliotecaExercicios({
    super.key,
    required this.api,
    required this.areas,
    required this.exercicios,
    required this.versaoImagem,
    required this.adicionar,
    required this.abrir,
    required this.criar,
    this.fechar,
  });

  final ApiSaude api;
  final List<String> areas;
  final List<Exercicio> exercicios;
  final int Function(String exercicioId) versaoImagem;
  final void Function(Exercicio e) adicionar;
  final void Function(Exercicio e) abrir;
  final VoidCallback criar;
  final VoidCallback? fechar;

  @override
  State<BibliotecaExercicios> createState() => _BibliotecaExerciciosState();
}

class _BibliotecaExerciciosState extends State<BibliotecaExercicios> {
  String _busca = '';

  static String _normal(String s) {
    const de = 'áàâãäéèêëíìîïóòôõöúùûüç';
    const para = 'aaaaaeeeeiiiiooooouuuuc';
    final b = StringBuffer();
    for (final c in s.toLowerCase().split('')) {
      final i = de.indexOf(c);
      b.write(i < 0 ? c : para[i]);
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final busca = _normal(_busca.trim());
    final filtrados = busca.isEmpty
        ? widget.exercicios
        : widget.exercicios
              .where((e) => _normal('${e.nome} ${e.grupo} ${e.area} ${e.equipamento}').contains(busca))
              .toList();
    // áreas conhecidas na ordem do catálogo; as criadas pelo usuário vão ao fim
    final areas = [
      ...widget.areas,
      ...{for (final e in widget.exercicios) e.area}.difference(widget.areas.toSet()),
    ];
    return Material(
      color: tema.colorScheme.surfaceContainerLowest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
            child: Row(
              children: [
                Expanded(child: Text('Exercícios', style: tema.textTheme.titleMedium)),
                IconButton(tooltip: 'Novo exercício', icon: const Icon(Icons.add_circle_outline), onPressed: widget.criar),
                if (widget.fechar != null)
                  IconButton(tooltip: 'Fechar', icon: const Icon(Icons.close), onPressed: widget.fechar),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: TextField(
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search),
                hintText: 'Buscar (nome, músculo, equipamento)',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _busca = v),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final area in areas)
                  if (filtrados.any((e) => e.area == area)) _area(area, filtrados.where((e) => e.area == area).toList(), busca.isNotEmpty),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _area(String area, List<Exercicio> lista, bool expandir) {
    final grupos = <String, List<Exercicio>>{};
    for (final e in lista) {
      grupos.putIfAbsent(e.grupo.isEmpty ? 'Outros' : e.grupo, () => []).add(e);
    }
    return ExpansionTile(
      key: PageStorageKey('area-$area-$expandir'),
      initiallyExpanded: expandir,
      leading: Icon(_iconeArea(area)),
      title: Text(area),
      subtitle: Text('${lista.length} exercícios'),
      childrenPadding: const EdgeInsets.only(left: 12),
      children: [
        for (final MapEntry(key: grupo, value: es) in grupos.entries)
          ExpansionTile(
            key: PageStorageKey('grupo-$area-$grupo-$expandir'),
            initiallyExpanded: expandir || grupos.length == 1,
            dense: true,
            title: Text(grupo),
            trailing: Text('${es.length}'),
            children: [for (final e in es) _exercicio(e)],
          ),
      ],
    );
  }

  Widget _exercicio(Exercicio e) => Arrastavel(
    dado: ArrastoExercicio(e),
    rotulo: e.nome,
    child: ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 8, right: 0),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: ImagemExercicio(api: widget.api, exercicio: e, tamanho: 40, versao: widget.versaoImagem(e.id)),
      ),
      title: Text(e.nome, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text('${e.equipamento} · ${e.series} × ${e.repeticoes}', maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: IconButton(
        tooltip: 'Marcar no dia em foco',
        icon: const Icon(Icons.add),
        onPressed: () => widget.adicionar(e),
      ),
      onTap: () => widget.abrir(e),
    ),
  );

  static IconData _iconeArea(String area) => switch (area) {
    'Peito' => Icons.accessibility_new,
    'Costas' => Icons.airline_seat_flat,
    'Ombros' => Icons.expand_less,
    'Braços' => Icons.fitness_center,
    'Abdômen' => Icons.grid_view,
    'Pernas' => Icons.directions_walk,
    'Glúteos' => Icons.airline_seat_recline_normal,
    'Cardio e luta' => Icons.sports_mma,
    _ => Icons.sports_gymnastics,
  };
}
