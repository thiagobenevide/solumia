import 'dart:convert';

import 'package:flutter/material.dart';

/// Editor fields. Each one gets the initial value and reports the change; when the state changes from outside
/// (assistente, desfazer, arrastar caixa), a tela recria os campos trocando a `key`.

class TextInputField extends StatelessWidget {
  const TextInputField(
    this.label,
    this.valor,
    this.mudou, {
    super.key,
    this.lines = 1,
    this.color = false,
    this.active = true,
  });

  final String label;
  final Object? valor;
  final ValueChanged<String> mudou;
  final int lines;

  /// Color in `#rrggbb`: shows a swatch beside it.
  final bool color;
  final bool active;

  @override
  Widget build(BuildContext context) => TextFormField(
    initialValue: valor == null ? '' : '$valor',
    enabled: active,
    minLines: lines,
    maxLines: lines == 1 ? 1 : lines + 4,
    style: color ? const TextStyle(fontFamily: 'monospace') : null,
    decoration: InputDecoration(
      labelText: label,
      isDense: true,
      border: const OutlineInputBorder(),
      hintText: color ? '#rrggbb' : null,
      suffixIcon: color ? _Sample('$valor') : null,
    ),
    onChanged: mudou,
  );
}

class _Sample extends StatelessWidget {
  const _Sample(this.hex);

  final String hex;

  @override
  Widget build(BuildContext context) {
    final v = int.tryParse(hex.replaceFirst('#', ''), radix: 16);
    if (hex.length != 7 || v == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.all(10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Color(0xFF000000 | v),
          border: Border.all(color: Colors.white24),
        ),
        child: const SizedBox(width: 18, height: 18),
      ),
    );
  }
}

class NumberField extends StatelessWidget {
  const NumberField(this.label, this.valor, this.mudou, {super.key});

  final String label;
  final num? valor;

  /// `null` when the field is empty.
  final ValueChanged<num?> mudou;

  @override
  Widget build(BuildContext context) => TextFormField(
    initialValue: valor == null ? '' : '$valor',
    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
    decoration: InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder()),
    onChanged: (v) => mudou(v.trim().isEmpty ? null : num.tryParse(v.replaceAll(',', '.'))),
  );
}

class OptionsField extends StatelessWidget {
  const OptionsField(this.label, this.valor, this.options, this.mudou, {super.key});

  final String label;
  final String? valor;
  final List<String> options;
  final ValueChanged<String> mudou;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<String>(
    initialValue: options.contains(valor) ? valor : null,
    isExpanded: true,
    decoration: InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder()),
    items: [
      for (final o in options)
        DropdownMenuItem(
          value: o,
          child: Text(o, overflow: TextOverflow.ellipsis),
        ),
    ],
    onChanged: (v) => v == null ? null : mudou(v),
  );
}

class BoolField extends StatelessWidget {
  const BoolField(this.label, this.valor, this.mudou, {super.key});

  final String label;
  final bool valor;
  final ValueChanged<bool> mudou;

  @override
  Widget build(BuildContext context) => _BoolFieldStatus(label: label, valor: valor, mudou: mudou);
}

class _BoolFieldStatus extends StatefulWidget {
  const _BoolFieldStatus({required this.label, required this.valor, required this.mudou});

  final String label;
  final bool valor;
  final ValueChanged<bool> mudou;

  @override
  State<_BoolFieldStatus> createState() => _BoolFieldStatusState();
}

class _BoolFieldStatusState extends State<_BoolFieldStatus> {
  late bool _v = widget.valor;

  @override
  Widget build(BuildContext context) => SwitchListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    title: Text(widget.label),
    value: _v,
    onChanged: (v) {
      setState(() => _v = v);
      widget.mudou(v);
    },
  );
}

/// Structured value (list/object) of a template's data, edited as JSON; only reports when it is valid.
class JsonField extends StatefulWidget {
  const JsonField(this.label, this.valor, this.mudou, {super.key});

  final String label;
  final Object? valor;
  final ValueChanged<Object?> mudou;

  @override
  State<JsonField> createState() => _JsonFieldState();
}

class _JsonFieldState extends State<JsonField> {
  String? _error;

  @override
  Widget build(BuildContext context) => TextFormField(
    initialValue: const JsonEncoder.withIndent(' ').convert(widget.valor),
    minLines: 3,
    maxLines: 12,
    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
    decoration: InputDecoration(
      labelText: '${widget.label} (JSON)',
      isDense: true,
      border: const OutlineInputBorder(),
      errorText: _error,
    ),
    onChanged: (v) {
      try {
        widget.mudou(jsonDecode(v));
        setState(() => _error = null);
      } on FormatException {
        setState(() => _error = 'JSON inválido');
      }
    },
  );
}

/// Responsive field grid: [columns] per row on wide screens, one per row on narrow ones.
class FieldsGrid extends StatelessWidget {
  const FieldsGrid({super.key, required this.children, this.columns = 3, this.largos = const {}});

  final List<Widget> children;
  final int columns;

  /// Indexes of [children] that take the whole row.
  final Set<int> largos;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, area) {
      final n = area.maxWidth < 320 ? 1 : columns;
      final largura = (area.maxWidth - 8 * (n - 1)) / n;
      return Wrap(
        spacing: 8,
        runSpacing: 10,
        children: [
          for (final (i, f) in children.indexed)
            SizedBox(width: largos.contains(i) ? area.maxWidth : largura, child: f),
        ],
      );
    },
  );
}
