import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models.dart';

// ---------- formatted text ----------

/// Text dialog with bold, italic, underline and highlighter: the buttons wrap the selected excerpt
/// in the marks that `formattedText` draws (`**`, `*`, `__`, `==`). With [format]
/// false it is just a one-line field (arrow label).
Future<String?> editFormattedText(
  BuildContext context, {
  String title = 'Texto',
  String initial = '',
  String confirm = 'Inserir',
  bool format = true,
}) => showDialog<String>(
  context: context,
  builder: (_) => _TextDialog(title: title, initial: initial, confirm: confirm, format: format),
);

/// The field controller lives with the dialog: disposing it right after `showDialog` broke the
/// closing animation ("TextEditingController used after being disposed").
class _TextDialog extends StatefulWidget {
  const _TextDialog({required this.title, required this.initial, required this.confirm, required this.format});

  final String title, initial, confirm;
  final bool format;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _wrap(String mark) {
    final sel = _controller.selection;
    final t = _controller.text;
    final ini = sel.isValid ? sel.start : t.length, fim = sel.isValid ? sel.end : t.length;
    _controller.value = TextEditingValue(
      text: t.replaceRange(ini, fim, '$mark${t.substring(ini, fim)}$mark'),
      selection: TextSelection(baseOffset: ini + mark.length, extentOffset: fim + mark.length),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.format)
            Row(
              children: [
                IconButton(tooltip: 'Negrito', onPressed: () => _wrap('**'), icon: const Icon(Icons.format_bold)),
                IconButton(tooltip: 'Itálico', onPressed: () => _wrap('*'), icon: const Icon(Icons.format_italic)),
                IconButton(
                  tooltip: 'Sublinhado',
                  onPressed: () => _wrap('__'),
                  icon: const Icon(Icons.format_underlined),
                ),
                IconButton(tooltip: 'Marcador', onPressed: () => _wrap('=='), icon: const Icon(Icons.border_color)),
              ],
            ),
          TextField(
            controller: _controller,
            autofocus: true,
            maxLines: widget.format ? 6 : 1,
            minLines: widget.format ? 2 : 1,
            onSubmitted: widget.format ? null : (v) => Navigator.pop(context, v),
          ),
          if (widget.format)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Selecione um trecho e toque no botão, ou escreva **negrito**, *itálico*, __sublinhado__, ==marcador==.',
                style: TextStyle(fontSize: 12),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(onPressed: () => Navigator.pop(context, _controller.text), child: Text(widget.confirm)),
    ],
  );
}

// ---------- AI flowchart ----------

enum FlowMode {
  describe('Descrever'),
  code('A partir de código'),
  fit('Ajustar o atual');

  const FlowMode(this.label);

  final String label;
}

class FlowRequest {
  const FlowRequest(this.mode, this.request, this.provider, {this.code = '', this.file = ''});

  final FlowMode mode;
  final String request, provider, code, file;
}

/// "Fluxo com IA" dialog: describe the rule, send a code file or adjust the flow that
/// is already on the board ([hasFlow]).
Future<FlowRequest?> requestFlow(BuildContext context, {required bool hasFlow, required List<String> providers}) =>
    showDialog<FlowRequest>(
      context: context,
      builder: (_) => _FlowDialog(hasFlow: hasFlow, providers: providers),
    );

class _FlowDialog extends StatefulWidget {
  const _FlowDialog({required this.hasFlow, required this.providers});

  final bool hasFlow;
  final List<String> providers;

  @override
  State<_FlowDialog> createState() => _FlowDialogState();
}

class _FlowDialogState extends State<_FlowDialog> {
  late FlowMode _mode = widget.hasFlow ? FlowMode.fit : FlowMode.describe;
  late String _provider = widget.providers.first;
  final _request = TextEditingController();
  String _code = '', _file = '';

  @override
  void dispose() {
    _request.dispose();
    super.dispose();
  }

  Future<void> _pickCode() async {
    final a = (await FilePicker.pickFiles()).firstOrNull;
    if (a == null) return;
    final bytes = await a.xFile.readAsBytes();
    setState(() {
      _code = utf8.decode(bytes, allowMalformed: true);
      _file = a.name;
    });
  }

  @override
  Widget build(BuildContext context) {
    final pronto = switch (_mode) {
      FlowMode.code => _code.isNotEmpty,
      _ => _request.text.trim().isNotEmpty,
    };
    return AlertDialog(
      title: const Text('Fluxo com IA'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            SegmentedButton<FlowMode>(
              segments: [
                for (final m in FlowMode.values)
                  if (m != FlowMode.fit || widget.hasFlow) ButtonSegment(value: m, label: Text(m.label)),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
            if (_mode == FlowMode.code)
              Row(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _pickCode,
                    icon: const Icon(Icons.upload_file),
                    label: const Text('Escolher arquivo de código'),
                  ),
                  Expanded(
                    child: Text(
                      _file.isEmpty ? 'Nenhum arquivo' : '$_file (${_code.length} caracteres)',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            TextField(
              controller: _request,
              autofocus: true,
              minLines: 3,
              maxLines: 8,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: switch (_mode) {
                  FlowMode.describe => 'Descreva a regra de negócio',
                  FlowMode.code => 'Foco (opcional): ex. "só a aprovação de crédito"',
                  FlowMode.fit => 'O que mudar: ex. "inclua a validação de estoque"',
                },
              ),
            ),
            if (widget.providers.length > 1)
              Row(
                spacing: 8,
                children: [
                  const Text('IA:'),
                  SegmentedButton<String>(
                    segments: [
                      for (final p in widget.providers)
                        ButtonSegment(value: p, label: Text(p == 'local' ? 'LLM local' : 'Claude')),
                    ],
                    selected: {_provider},
                    onSelectionChanged: (s) => setState(() => _provider = s.first),
                  ),
                ],
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton.icon(
          onPressed: pronto
              ? () => Navigator.pop(
                  context,
                  FlowRequest(
                    _mode,
                    _request.text.trim(),
                    _provider,
                    code: _mode == FlowMode.code ? _code : '',
                    file: _file,
                  ),
                )
              : null,
          icon: const Icon(Icons.auto_awesome),
          label: const Text('Gerar'),
        ),
      ],
    );
  }
}

/// Default block colors by type (the user recolors them later through the selection).
const flowColors = {
  NodeKind.inicio: Color(0xFF2E7D32),
  NodeKind.fim: Color(0xFFC62828),
  NodeKind.processo: Color(0xFF1565C0),
  NodeKind.decisao: Color(0xFFEF6C00),
  NodeKind.dado: Color(0xFF6A1B9A),
  NodeKind.subprocesso: Color(0xFF00838F),
  NodeKind.quadrado: Color(0xFF455A64),
  NodeKind.circulo: Color(0xFF5D4037),
  NodeKind.documento: Color(0xFF283593),
  NodeKind.banco: Color(0xFF00695C),
  NodeKind.nota: Color(0xFFF9A825),
  NodeKind.hexagono: Color(0xFFAD1457),
  NodeKind.container: Color(0xFF607D8B),
};

/// Server flow (`nos` with x/y/w/h, `ligacoes`) → board elements, with the top-left corner
/// at [origin]. The ids become `<fluxo>.<node id>`: adjusting the flow keeps the same ones.
List<Elemento> flowElements(Map<String, dynamic> flow, Offset origin, String flowId) {
  final nos = (flow['nos'] as List).cast<Map<String, dynamic>>();
  if (nos.isEmpty) return const [];
  double num_(Object? v) => (v as num? ?? 0).toDouble();
  final minX = nos.map((n) => num_(n['x'])).reduce((a, b) => a < b ? a : b);
  final minY = nos.map((n) => num_(n['y'])).reduce((a, b) => a < b ? a : b);
  final shifts = origin - Offset(minX, minY);
  final exit = <Elemento>[];
  for (final n in nos) {
    final type = NodeKind.de(n['tipo'] as String?);
    final a = Offset(num_(n['x']), num_(n['y'])) + shifts;
    exit.add(
      FlowNode(
        '$flowId.${n['id']}',
        type: type,
        text: '${n['texto'] ?? ''}',
        a: a,
        b: a + Offset(num_(n['w']), num_(n['h'])),
        color: flowColors[type]!,
        flow: flowId,
      ),
    );
  }
  var i = 0;
  for (final l in (flow['ligacoes'] as List).cast<Map<String, dynamic>>()) {
    exit.add(
      Connector(
        '$flowId.l${i++}',
        de: '$flowId.${l['de']}',
        to: '$flowId.${l['para']}',
        a: Offset.zero,
        b: Offset.zero,
        color: const Color(0xFF37474F),
        label: '${l['rotulo'] ?? ''}',
        flow: flowId,
        orthogonal: true,
      ),
    );
  }
  return reconnect(exit);
}

/// The board flow [flowId] in the format the AI receives to adjust (ids without the prefix).
Map<String, dynamic> boardFlow(List<Elemento> elements, String flowId) {
  String short(String id) => id.startsWith('$flowId.') ? id.substring(flowId.length + 1) : id;
  return {
    'nos': [
      for (final n in elements.whereType<FlowNode>())
        if (n.flow == flowId) {'id': short(n.id), 'tipo': n.type.name, 'texto': n.text},
    ],
    'ligacoes': [
      for (final l in elements.whereType<Connector>())
        if (l.flow == flowId) {'de': short(l.de), 'para': short(l.to), 'rotulo': l.label},
    ],
  };
}
