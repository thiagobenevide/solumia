import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api_saude.dart';
import '../datas.dart';
import '../modelos.dart';
import 'comuns.dart';

/// Foto escolhida no aparelho (galeria no Android, arquivo no PC).
typedef Foto = ({String nome, List<int> bytes});

Future<Foto?> escolherFoto() async {
  final r = await FilePicker.pickFiles(dialogTitle: 'Foto do exercício', type: FileType.image);
  if (r.isEmpty) return null;
  return (nome: r.first.name, bytes: await r.first.xFile.readAsBytes());
}

/// Criar ([atual] nulo) ou editar um exercício. Devolve os dados e, se escolhida, a foto.
Future<(Map<String, dynamic>, Foto?)?> formularioExercicio(
  BuildContext context,
  List<String> areas, {
  Exercicio? atual,
}) => showDialog(context: context, builder: (_) => _FormularioExercicio(areas: areas, atual: atual));

class _FormularioExercicio extends StatefulWidget {
  const _FormularioExercicio({required this.areas, this.atual});

  final List<String> areas;
  final Exercicio? atual;

  @override
  State<_FormularioExercicio> createState() => _FormularioExercicioState();
}

class _FormularioExercicioState extends State<_FormularioExercicio> {
  final _form = GlobalKey<FormState>();
  late final _nome = TextEditingController(text: widget.atual?.nome);
  late final _grupo = TextEditingController(text: widget.atual?.grupo);
  late final _equipamento = TextEditingController(text: widget.atual?.equipamento);
  late final _series = TextEditingController(text: '${widget.atual?.series ?? 3}');
  late final _reps = TextEditingController(text: widget.atual?.repeticoes ?? '10');
  late final _carga = TextEditingController(
    text: widget.atual?.cargaKg == null ? '' : formatarCarga(widget.atual!.cargaKg!),
  );
  late final _instrucoes = TextEditingController(text: widget.atual?.instrucoes);
  late String _area = widget.atual?.area ?? widget.areas.first;
  Foto? _foto;

  @override
  void dispose() {
    for (final c in [_nome, _grupo, _equipamento, _series, _reps, _carga, _instrucoes]) {
      c.dispose();
    }
    super.dispose();
  }

  void _salvar() {
    if (!_form.currentState!.validate()) return;
    Navigator.pop(context, (
      {
        'nome': _nome.text.trim(),
        'area': _area,
        'grupo': _grupo.text.trim(),
        'equipamento': _equipamento.text.trim(),
        'series': int.parse(_series.text),
        'repeticoes': _reps.text.trim(),
        'carga_kg': double.tryParse(_carga.text.replaceAll(',', '.')),
        'instrucoes': _instrucoes.text.trim(),
      },
      _foto,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final areas = {...widget.areas, _area}.toList();
    return AlertDialog(
      title: Text(widget.atual == null ? 'Novo exercício' : 'Editar exercício'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 10,
              children: [
                TextFormField(
                  controller: _nome,
                  autofocus: widget.atual == null,
                  decoration: const InputDecoration(labelText: 'Nome'),
                  validator: (v) => (v ?? '').trim().isEmpty ? 'Dê um nome' : null,
                ),
                DropdownButtonFormField<String>(
                  initialValue: _area,
                  decoration: const InputDecoration(labelText: 'Área do corpo'),
                  items: [for (final a in areas) DropdownMenuItem(value: a, child: Text(a))],
                  onChanged: (v) => setState(() => _area = v!),
                ),
                TextFormField(
                  controller: _grupo,
                  decoration: const InputDecoration(labelText: 'Grupo muscular', hintText: 'ex.: Bíceps'),
                ),
                TextFormField(
                  controller: _equipamento,
                  decoration: const InputDecoration(labelText: 'Equipamento', hintText: 'ex.: Saco de pancada'),
                ),
                Row(
                  spacing: 10,
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _series,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Séries'),
                        validator: (v) => (int.tryParse(v ?? '') ?? 0) < 1 ? 'Número' : null,
                      ),
                    ),
                    Expanded(
                      child: TextFormField(
                        controller: _reps,
                        decoration: const InputDecoration(labelText: 'Repetições', hintText: '12 ou 40 s'),
                      ),
                    ),
                    Expanded(
                      child: TextFormField(
                        controller: _carga,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'Carga (kg)'),
                      ),
                    ),
                  ],
                ),
                TextFormField(
                  controller: _instrucoes,
                  minLines: 2,
                  maxLines: 6,
                  decoration: const InputDecoration(labelText: 'Como fazer'),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    label: Text(_foto == null ? 'Escolher foto' : 'Foto: ${_foto!.nome}'),
                    onPressed: () async {
                      final f = await escolherFoto();
                      if (f != null) setState(() => _foto = f);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: _salvar, child: const Text('Salvar')),
      ],
    );
  }
}

enum AcaoExercicio { marcar, editar, trocarFoto, removerFoto, excluir }

/// Fotos do movimento (início e fim), instruções e ações do exercício.
Future<AcaoExercicio?> detalhesExercicio(BuildContext context, ApiSaude api, Exercicio e, int versao) =>
    showDialog<AcaoExercicio>(
      context: context,
      builder: (context) {
        final tema = Theme.of(context);
        final fotos = [
          for (final n in e.temSequencia ? [0, 1] : [0])
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: AspectRatio(
                  aspectRatio: 4 / 3,
                  child: ImagemExercicio(api: api, exercicio: e, n: n, versao: versao),
                ),
              ),
            ),
        ];
        return AlertDialog(
          title: Text(e.nome),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                spacing: 10,
                children: [
                  Row(spacing: 8, children: fotos),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final t in [e.area, e.grupo, e.equipamento, '${e.series} × ${e.repeticoes}'])
                        if (t.isNotEmpty) Chip(label: Text(t), visualDensity: VisualDensity.compact),
                      if (e.cargaKg != null) Chip(label: Text('${formatarCarga(e.cargaKg!)} kg')),
                    ],
                  ),
                  if (e.instrucoes.isNotEmpty) Text(e.instrucoes, style: tema.textTheme.bodyMedium),
                ],
              ),
            ),
          ),
          actions: [
            PopupMenuButton<AcaoExercicio>(
              tooltip: 'Mais',
              onSelected: (a) => Navigator.pop(context, a),
              itemBuilder: (_) => [
                const PopupMenuItem(value: AcaoExercicio.editar, child: Text('Editar')),
                const PopupMenuItem(value: AcaoExercicio.trocarFoto, child: Text('Trocar foto')),
                if (e.temImagem && !e.temSequencia)
                  const PopupMenuItem(value: AcaoExercicio.removerFoto, child: Text('Remover foto')),
                const PopupMenuItem(value: AcaoExercicio.excluir, child: Text('Excluir exercício')),
              ],
            ),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fechar')),
            FilledButton.icon(
              icon: const Icon(Icons.event_available),
              label: const Text('Marcar no dia'),
              onPressed: () => Navigator.pop(context, AcaoExercicio.marcar),
            ),
          ],
        );
      },
    );

/// Resultado da edição de um item: os campos alterados ou a exclusão.
sealed class EdicaoItem {}

class ItemAlterado extends EdicaoItem {
  ItemAlterado(this.dados);

  final Map<String, dynamic> dados;
}

class ItemExcluido extends EdicaoItem {}

/// Séries, repetições e carga planejadas/feitas, observação e se foi feito.
Future<EdicaoItem?> editarItem(BuildContext context, ItemAgenda item, Exercicio? e) {
  final series = TextEditingController(text: '${item.series}');
  final reps = TextEditingController(text: item.repeticoes);
  final carga = TextEditingController(text: item.cargaKg == null ? '' : formatarCarga(item.cargaKg!));
  final obs = TextEditingController(text: item.observacao);
  var feito = item.feito;
  return showDialog<EdicaoItem>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(e?.nome ?? item.exercicioId),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 10,
            children: [
              Text(diaLongo(item.data)),
              Row(
                spacing: 10,
                children: [
                  Expanded(
                    child: TextField(
                      controller: series,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Séries'),
                    ),
                  ),
                  Expanded(
                    child: TextField(controller: reps, decoration: const InputDecoration(labelText: 'Repetições')),
                  ),
                  Expanded(
                    child: TextField(
                      controller: carga,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Carga (kg)'),
                    ),
                  ),
                ],
              ),
              TextField(
                controller: obs,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'Observação (como foi, dor, ajuste)'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Feito'),
                value: feito,
                onChanged: (v) => setState(() => feito = v),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.delete_outline),
            label: const Text('Tirar do dia'),
            onPressed: () => Navigator.pop(context, ItemExcluido()),
          ),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              ItemAlterado({
                'series': int.tryParse(series.text) ?? item.series,
                'repeticoes': reps.text.trim().isEmpty ? item.repeticoes : reps.text.trim(),
                'carga_kg': double.tryParse(carga.text.replaceAll(',', '.')),
                'observacao': obs.text.trim(),
                'feito': feito,
              }),
            ),
            child: const Text('Salvar'),
          ),
        ],
      ),
    ),
  );
}
