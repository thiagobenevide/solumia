import 'package:flutter/material.dart';

import '../models.dart';

/// Name of each ruling in the notebook.
const ruleLabels = {
  Background.linhas: 'Pautado',
  Background.pontos: 'Pontilhado',
  Background.grade: 'Quadriculado',
  Background.liso: 'Liso',
};

/// Sheet sizes (logical px at 96 dpi).
const sheetSizes = <String, Size>{
  'A4': Size(794, 1123),
  'A5': Size(559, 794),
  'Carta': Size(816, 1056),
  'Largo (16:9)': Size(1280, 720),
  'Quadrado': Size(900, 900),
};

const paperColors = [Color(0xFFFFFFFF), Color(0xFFFBF5E6), Color(0xFFF1F4F8), Color(0xFFEFF7EE), Color(0xFF2B2F33)];

/// Edits the paper; returns the new one and whether it applies to all sheets (null = cancelled).
Future<({Paper role, bool allItems})?> editPaper(BuildContext context, Paper current) =>
    showDialog(context: context, builder: (_) => _PaperDialog(current));

class _PaperDialog extends StatefulWidget {
  const _PaperDialog(this.initial);

  final Paper initial;

  @override
  State<_PaperDialog> createState() => _PaperDialogState();
}

class _PaperDialogState extends State<_PaperDialog> {
  late Paper _p = widget.initial;
  var _allPages = false;

  bool get _landscape => _p.width > _p.height;

  void _size(Size s) => setState(() {
    final rotate = _landscape != (s.width > s.height) && s.width != s.height;
    _p = _p.copy(width: rotate ? s.height : s.width, height: rotate ? s.width : s.height);
  });

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Papel da folha'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            SegmentedButton<Background>(
              segments: [
                for (final e in ruleLabels.entries) ButtonSegment(value: e.key, label: Text(e.value)),
              ],
              selected: {_p.background},
              onSelectionChanged: (s) => setState(() => _p = _p.copy(background: s.first)),
            ),
            Text('Espaço entre linhas: ${_p.space.round()} px'),
            Slider(
              value: _p.space.clamp(12, 64),
              min: 12,
              max: 64,
              divisions: 26,
              onChanged: (v) => setState(() => _p = _p.copy(space: v)),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final e in sheetSizes.entries)
                  ChoiceChip(
                    label: Text(e.key),
                    selected: {e.value.width, e.value.height}.containsAll({_p.width, _p.height}),
                    onSelected: (_) => _size(e.value),
                  ),
                ActionChip(
                  avatar: const Icon(Icons.screen_rotation_alt, size: 18),
                  label: Text(_landscape ? 'Deitada' : 'Em pé'),
                  onPressed: () => setState(() => _p = _p.copy(width: _p.height, height: _p.width)),
                ),
              ],
            ),
            Text('Largura: ${_p.width.round()} px'),
            Slider(
              value: _p.width.clamp(400, 2400),
              min: 400,
              max: 2400,
              onChanged: (v) => setState(() => _p = _p.copy(width: v.roundToDouble())),
            ),
            Text('Altura: ${_p.height.round()} px'),
            Slider(
              value: _p.height.clamp(400, 3400),
              min: 400,
              max: 3400,
              onChanged: (v) => setState(() => _p = _p.copy(height: v.roundToDouble())),
            ),
            Row(
              spacing: 8,
              children: [
                const Text('Cor:'),
                for (final c in paperColors)
                  InkWell(
                    onTap: () => setState(() => _p = _p.copy(color: c)),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(
                          width: _p.color == c ? 3 : 1,
                          color: _p.color == c ? Theme.of(context).colorScheme.primary : Colors.black26,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Margem e cabeçalho'),
              value: _p.margin,
              onChanged: (v) => setState(() => _p = _p.copy(margin: v)),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Aplicar a todas as folhas'),
              value: _allPages,
              onChanged: (v) => setState(() => _allPages = v ?? false),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(onPressed: () => Navigator.pop(context, (role: _p, allItems: _allPages)), child: const Text('Aplicar')),
    ],
  );
}
