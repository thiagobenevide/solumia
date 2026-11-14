import 'package:flutter/material.dart';

import '../finance_api.dart';
import '../format.dart';

/// Accounts and categories, used by almost every screen; reloads and notifies when they change.
class Registry extends ChangeNotifier {
  Registry(this.api);

  final FinanceApi api;
  List<Doc> accounts = [];
  List<Doc> categories = [];
  bool loaded = false;

  Future<void> carregar() async {
    final (c, k) = await (api.list('contas'), api.list('categorias')).wait;
    accounts = c;
    categories = k..sort((a, b) => '${a['tipo']}${a['nome']}'.compareTo('${b['tipo']}${b['nome']}'));
    loaded = true;
    notifyListeners();
  }

  Doc? account(String? id) => accounts.where((c) => c['id'] == id).firstOrNull;

  Doc? category(String? id) => categories.where((c) => c['id'] == id).firstOrNull;

  Map<String, String> get accountOptions => {'': '—', for (final c in accounts) c['id'] as String: c['nome'] as String};

  Map<String, String> get categoryOptions => {
    '': 'Sem categoria',
    for (final c in categories) c['id'] as String: '${c['nome']} · ${typeLabel[c['tipo']] ?? ''}',
  };
}

const typeLabel = {
  'receita': 'receita',
  'despesa': 'despesa',
  'investimento': 'investimento',
  'transferencia': 'transferência',
};

void avisar(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

/// Runs [action] showing the error in a warning; returns whether it worked.
Future<bool> tentar(BuildContext context, Future<void> Function() action, {String? ok}) async {
  try {
    await action();
    if (ok != null && context.mounted) avisar(context, ok);
    return true;
  } catch (e) {
    if (context.mounted) avisar(context, 'Erro: $e');
    return false;
  }
}

Future<bool> confirm(BuildContext context, String text) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        content: Text(text),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Confirmar')),
        ],
      ),
    ) ??
    false;

/// FutureBuilder with loading, error (with retry) and the content.
class Waiting<T> extends StatelessWidget {
  const Waiting({super.key, required this.future, required this.construir, this.reload});

  final Future<T> future;
  final Widget Function(T) construir;
  final VoidCallback? reload;

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
    future: future,
    builder: (context, s) {
      if (s.hasError) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              Text('Não carregou: ${s.error}', textAlign: TextAlign.center),
              if (reload != null) OutlinedButton(onPressed: reload, child: const Text('Tentar de novo')),
            ],
          ),
        );
      }
      // `connectionState`, not `hasData`: a Future<void> ends with null.
      if (s.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
      return construir(s.data as T);
    },
  );
}

/// Block with title and actions, used on the dashboard and in the tabs.
class Section extends StatelessWidget {
  const Section({super.key, required this.title, required this.child, this.stocks = const [], this.subtitle});

  final String title;
  final String? subtitle;
  final Widget child;
  final List<Widget> stocks;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.all(6),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    if (subtitle != null)
                      Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              ...stocks,
            ],
          ),
          child,
        ],
      ),
    ),
  );
}

/// Highlight number (KPI) with label and detail.
class Indicator extends StatelessWidget {
  const Indicator(this.label, this.value, {super.key, this.detail, this.color, this.icone, this.width = 190});

  final String label;
  final String value;
  final String? detail;
  final Color? color;
  final IconData? icone;
  final double width;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SizedBox(
      width: width,
      child: Card(
        margin: const EdgeInsets.all(4),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [
              Row(
                spacing: 6,
                children: [
                  if (icone != null) Icon(icone, size: 16, color: Theme.of(context).colorScheme.outline),
                  Expanded(child: Text(label, style: t.labelMedium, overflow: TextOverflow.ellipsis)),
                ],
              ),
              Text(value, style: t.titleLarge?.copyWith(color: color, fontWeight: FontWeight.w600)),
              if (detail != null) Text(detail!, style: t.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ),
    );
  }
}

/// Grid of [Indicator]s taking the whole width: equal columns (min 2, max 6, never more than the
/// items), no leftover on the right nor squeezed cards on the phone.
class IndicatorGrid extends StatelessWidget {
  const IndicatorGrid({super.key, required this.children, this.minWidth = 170});

  final List<Widget> children;
  final double minWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final columns = (c.maxWidth / minWidth).floor().clamp(2, 6).clamp(1, children.isEmpty ? 1 : children.length).toInt();
      final width = (c.maxWidth / columns).floorToDouble();
      return Wrap(children: [for (final w in children) SizedBox(width: width, child: w)]);
    },
  );
}

/// Usage bar (0–100%+); over 100% it turns red.
class ProgressBar extends StatelessWidget {
  const ProgressBar(this.pct, {super.key, this.color});

  final double? pct;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final p = pct ?? 0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: LinearProgressIndicator(
        value: (p / 100).clamp(0, 1),
        minHeight: 8,
        backgroundColor: cs.surfaceContainerHighest,
        color: p > 100 ? cs.error : (p > 85 ? Colors.orange : (color ?? cs.primary)),
      ),
    );
  }
}

/// Chip pequeno colorido (status, veredito).
class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.outline;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      child: Text(text, style: TextStyle(color: c, fontSize: 12)),
    );
  }
}

Color verdictColor(String? v) => switch (v) {
  'apta para aporte' => Colors.green,
  'observar' => Colors.orange,
  'evitar' => Colors.red,
  _ => Colors.grey,
};

/// Two columns on a wide screen, one on the phone.
class Columns extends StatelessWidget {
  const Columns({super.key, required this.left, required this.right, this.cutoff = 900});

  final List<Widget> left;
  final List<Widget> right;
  final double cutoff;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) => c.maxWidth < cutoff
        ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...left, ...right])
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: left)),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: right)),
            ],
          ),
  );
}

/// Seletor "‹ out/2026 ›".
class MonthPicker extends StatelessWidget {
  const MonthPicker({super.key, required this.mes, required this.aoMudar});

  final DateTime mes;
  final ValueChanged<DateTime> aoMudar;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => aoMudar(addMonths(mes, -1))),
      TextButton(
        onPressed: () => aoMudar(DateTime(DateTime.now().year, DateTime.now().month)),
        child: Text(mesBr(mesIso(mes)), style: Theme.of(context).textTheme.titleMedium),
      ),
      IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => aoMudar(addMonths(mes, 1))),
    ],
  );
}

// --- generic form ---

enum FieldKind { text, longText, number, integer, data, option, boolean }

class FormFieldSpec {
  const FormFieldSpec(this.key, this.label, {this.type = FieldKind.text, this.options = const {}, this.isRequired = false, this.help});

  final String key;
  final String label;
  final FieldKind type;

  /// value → label, for [FieldKind.option].
  final Map<String, String> options;
  final bool isRequired;
  final String? help;
}

/// Create/edit dialog with the [fields]; returns only the fields (already converted) or null if cancelled.
Future<Doc?> form(BuildContext context, String title, List<FormFieldSpec> fields, [Doc current = const {}]) =>
    showDialog<Doc>(context: context, builder: (_) => _Form(title, fields, current));

class _Form extends StatefulWidget {
  const _Form(this.title, this.fields, this.current);

  final String title;
  final List<FormFieldSpec> fields;
  final Doc current;

  @override
  State<_Form> createState() => _FormState();
}

class _FormState extends State<_Form> {
  final _texts = <String, TextEditingController>{};
  final _values = <String, dynamic>{};
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final c in widget.fields) {
      final v = widget.current[c.key];
      switch (c.type) {
        case FieldKind.option:
          _values[c.key] = c.options.containsKey(v) ? v : c.options.keys.firstOrNull;
        case FieldKind.boolean:
          _values[c.key] = v ?? true;
        case FieldKind.number:
          _texts[c.key] = TextEditingController(text: v == null ? '' : number(v as num).replaceAll('.', ''));
        case FieldKind.data:
          _texts[c.key] = TextEditingController(text: v == null || v == '' ? '' : dataBr(v as String));
        default:
          _texts[c.key] = TextEditingController(text: v?.toString() ?? '');
      }
    }
  }

  @override
  void dispose() {
    for (final t in _texts.values) {
      t.dispose();
    }
    super.dispose();
  }

  String? _dataIso(String br) {
    final m = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})$').firstMatch(br.trim());
    if (m == null) return null;
    return iso(DateTime(int.parse(m[3]!), int.parse(m[2]!), int.parse(m[1]!)));
  }

  void _save() {
    final expense = <String, dynamic>{};
    for (final c in widget.fields) {
      final text = _texts[c.key]?.text.trim() ?? '';
      dynamic v;
      switch (c.type) {
        case FieldKind.option || FieldKind.boolean:
          v = _values[c.key];
        case FieldKind.number:
          v = readNumber(text);
          if (text.isNotEmpty && v == null) return setState(() => _error = '${c.label}: número inválido');
        case FieldKind.integer:
          v = int.tryParse(text);
          if (text.isNotEmpty && v == null) return setState(() => _error = '${c.label}: número inválido');
        case FieldKind.data:
          v = text.isEmpty ? null : _dataIso(text);
          if (text.isNotEmpty && v == null) return setState(() => _error = '${c.label}: use dd/mm/aaaa');
        default:
          v = text;
      }
      if (c.isRequired && (v == null || v == '')) return setState(() => _error = '${c.label} é obrigatório');
      if (v == null && (c.type == FieldKind.number || c.type == FieldKind.integer)) v = 0;
      expense[c.key] = v;
    }
    Navigator.pop(context, expense);
  }

  Future<void> _pickDate(FormFieldSpec c) async {
    final current = _dataIso(_texts[c.key]!.text);
    final d = await showDatePicker(
      context: context,
      initialDate: current == null ? DateTime.now() : DateTime.parse(current),
      firstDate: DateTime(1990),
      lastDate: DateTime(2100),
    );
    if (d != null) _texts[c.key]!.text = dataBr(iso(d));
  }

  Widget _input(FormFieldSpec c) => switch (c.type) {
    FieldKind.option => DropdownButtonFormField<String>(
      initialValue: _values[c.key] as String?,
      isExpanded: true,
      decoration: InputDecoration(labelText: c.label, helperText: c.help),
      items: [for (final e in c.options.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
      onChanged: (v) => _values[c.key] = v,
    ),
    FieldKind.boolean => SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(c.label),
      value: _values[c.key] as bool,
      onChanged: (v) => setState(() => _values[c.key] = v),
    ),
    _ => TextField(
      controller: _texts[c.key],
      maxLines: c.type == FieldKind.longText ? 5 : 1,
      keyboardType: switch (c.type) {
        FieldKind.number => const TextInputType.numberWithOptions(decimal: true, signed: true),
        FieldKind.integer => TextInputType.number,
        FieldKind.longText => TextInputType.multiline,
        _ => TextInputType.text,
      },
      decoration: InputDecoration(
        labelText: c.label + (c.isRequired ? ' *' : ''),
        helperText: c.help,
        hintText: c.type == FieldKind.data ? 'dd/mm/aaaa' : null,
        suffixIcon: c.type == FieldKind.data
            ? IconButton(icon: const Icon(Icons.calendar_today, size: 18), onPressed: () => _pickDate(c))
            : null,
      ),
      onSubmitted: c.type == FieldKind.longText ? null : (_) => _save(),
    ),
  };

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 10,
          children: [
            for (final c in widget.fields) _input(c),
            if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(onPressed: _save, child: const Text('Salvar')),
    ],
  );
}

/// Menu "editar / excluir" usado nas listas.
class MenuItem extends StatelessWidget {
  const MenuItem({super.key, required this.onEdit, required this.onDelete, this.extras = const {}});

  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final Map<String, VoidCallback> extras;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    onSelected: (v) => switch (v) {
      'editar' => onEdit(),
      'excluir' => onDelete(),
      _ => extras[v]?.call(),
    },
    itemBuilder: (_) => [
      for (final e in extras.keys) PopupMenuItem(value: e, child: Text(e)),
      const PopupMenuItem(value: 'editar', child: Text('Editar')),
      const PopupMenuItem(value: 'excluir', child: Text('Excluir')),
    ],
  );
}
