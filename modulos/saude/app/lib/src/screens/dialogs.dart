import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../health_api.dart';
import '../dates.dart';
import '../models.dart';
import 'common.dart';

/// Photo picked on the device (gallery on Android, file on the PC).
typedef Photo = ({String name, List<int> bytes});

Future<Photo?> pickPhoto() async {
  final r = await FilePicker.pickFiles(dialogTitle: 'Foto do exercício', type: FileType.image);
  if (r.isEmpty) return null;
  return (name: r.first.name, bytes: await r.first.xFile.readAsBytes());
}

/// Create ([current] null) or edit an exercise. Returns the data and, if picked, the photo.
Future<(Map<String, dynamic>, Photo?)?> exerciseForm(
  BuildContext context,
  List<String> areas, {
  Exercise? current,
}) => showDialog(context: context, builder: (_) => _ExerciseForm(areas: areas, current: current));

class _ExerciseForm extends StatefulWidget {
  const _ExerciseForm({required this.areas, this.current});

  final List<String> areas;
  final Exercise? current;

  @override
  State<_ExerciseForm> createState() => _ExerciseFormState();
}

class _ExerciseFormState extends State<_ExerciseForm> {
  final _form = GlobalKey<FormState>();
  late final _nome = TextEditingController(text: widget.current?.name);
  late final _group = TextEditingController(text: widget.current?.group);
  late final _equipment = TextEditingController(text: widget.current?.equipment);
  late final _series = TextEditingController(text: '${widget.current?.series ?? 3}');
  late final _reps = TextEditingController(text: widget.current?.reps ?? '10');
  late final _load = TextEditingController(
    text: widget.current?.loadKg == null ? '' : formatLoad(widget.current!.loadKg!),
  );
  late final _instructions = TextEditingController(text: widget.current?.instructions);
  late String _area = widget.current?.area ?? widget.areas.first;
  Photo? _photo;

  @override
  void dispose() {
    for (final c in [_nome, _group, _equipment, _series, _reps, _load, _instructions]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    Navigator.pop(context, (
      {
        'nome': _nome.text.trim(),
        'area': _area,
        'grupo': _group.text.trim(),
        'equipamento': _equipment.text.trim(),
        'series': int.parse(_series.text),
        'repeticoes': _reps.text.trim(),
        'carga_kg': double.tryParse(_load.text.replaceAll(',', '.')),
        'instrucoes': _instructions.text.trim(),
      },
      _photo,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final areas = {...widget.areas, _area}.toList();
    return AlertDialog(
      title: Text(widget.current == null ? 'Novo exercício' : 'Editar exercício'),
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
                  autofocus: widget.current == null,
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
                  controller: _group,
                  decoration: const InputDecoration(labelText: 'Grupo muscular', hintText: 'ex.: Bíceps'),
                ),
                TextFormField(
                  controller: _equipment,
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
                        controller: _load,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'Carga (kg)'),
                      ),
                    ),
                  ],
                ),
                TextFormField(
                  controller: _instructions,
                  minLines: 2,
                  maxLines: 6,
                  decoration: const InputDecoration(labelText: 'Como fazer'),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    label: Text(_photo == null ? 'Escolher foto' : 'Foto: ${_photo!.name}'),
                    onPressed: () async {
                      final f = await pickPhoto();
                      if (f != null) setState(() => _photo = f);
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
        FilledButton(onPressed: _save, child: const Text('Salvar')),
      ],
    );
  }
}

enum ExerciseAction { mark, edit, changePhoto, removePhoto, delete }

/// Photos of the movement (start and end), instructions and actions of the exercise.
Future<ExerciseAction?> exerciseDetails(BuildContext context, HealthApi api, Exercise e, int version) =>
    showDialog<ExerciseAction>(
      context: context,
      builder: (context) {
        final topic = Theme.of(context);
        final photos = [
          for (final n in e.hasSequence ? [0, 1] : [0])
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: AspectRatio(
                  aspectRatio: 4 / 3,
                  child: ExerciseImage(api: api, exercise: e, n: n, version: version),
                ),
              ),
            ),
        ];
        return AlertDialog(
          title: Text(e.name),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                spacing: 10,
                children: [
                  Row(spacing: 8, children: photos),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final t in [e.area, e.group, e.equipment, '${e.series} × ${e.reps}'])
                        if (t.isNotEmpty) Chip(label: Text(t), visualDensity: VisualDensity.compact),
                      if (e.loadKg != null) Chip(label: Text('${formatLoad(e.loadKg!)} kg')),
                    ],
                  ),
                  if (e.instructions.isNotEmpty) Text(e.instructions, style: topic.textTheme.bodyMedium),
                ],
              ),
            ),
          ),
          actions: [
            PopupMenuButton<ExerciseAction>(
              tooltip: 'Mais',
              onSelected: (a) => Navigator.pop(context, a),
              itemBuilder: (_) => [
                const PopupMenuItem(value: ExerciseAction.edit, child: Text('Editar')),
                const PopupMenuItem(value: ExerciseAction.changePhoto, child: Text('Trocar foto')),
                if (e.hasImage && !e.hasSequence)
                  const PopupMenuItem(value: ExerciseAction.removePhoto, child: Text('Remover foto')),
                const PopupMenuItem(value: ExerciseAction.delete, child: Text('Excluir exercício')),
              ],
            ),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fechar')),
            FilledButton.icon(
              icon: const Icon(Icons.event_available),
              label: const Text('Marcar no dia'),
              onPressed: () => Navigator.pop(context, ExerciseAction.mark),
            ),
          ],
        );
      },
    );

/// Result of editing an item: the changed fields or the deletion.
sealed class ItemEdit {}

class ItemChanged extends ItemEdit {
  ItemChanged(this.data);

  final Map<String, dynamic> data;
}

class ItemDeleted extends ItemEdit {}

/// Sets, reps and planned/done load, observation and whether it was done.
Future<ItemEdit?> editItem(BuildContext context, ItemAgenda item, Exercise? e) {
  final series = TextEditingController(text: '${item.series}');
  final reps = TextEditingController(text: item.reps);
  final load = TextEditingController(text: item.loadKg == null ? '' : formatLoad(item.loadKg!));
  final obs = TextEditingController(text: item.observation);
  var done = item.done;
  return showDialog<ItemEdit>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(e?.name ?? item.exerciseId),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 10,
            children: [
              Text(longDay(item.data)),
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
                      controller: load,
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
                value: done,
                onChanged: (v) => setState(() => done = v),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.delete_outline),
            label: const Text('Tirar do dia'),
            onPressed: () => Navigator.pop(context, ItemDeleted()),
          ),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              ItemChanged({
                'series': int.tryParse(series.text) ?? item.series,
                'repeticoes': reps.text.trim().isEmpty ? item.reps : reps.text.trim(),
                'carga_kg': double.tryParse(load.text.replaceAll(',', '.')),
                'observacao': obs.text.trim(),
                'feito': done,
              }),
            ),
            child: const Text('Salvar'),
          ),
        ],
      ),
    ),
  );
}
