import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

String duration(double? seconds) {
  if (seconds == null) return '';
  final s = seconds.round();
  if (s < 60) return '${s}s';
  if (s < 3600) return '${s ~/ 60}m${(s % 60).toString().padLeft(2, '0')}s';
  return '${s ~/ 3600}h${(s % 3600 ~/ 60).toString().padLeft(2, '0')}m';
}

String _two(int n) => n.toString().padLeft(2, '0');

String hour(DateTime? t) => t == null ? '' : '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

String dayHour(DateTime? t) =>
    t == null ? '' : '${_two(t.day)}/${_two(t.month)} ${_two(t.hour)}:${_two(t.minute)}';

IconData iconOfState(String state) => switch (state) {
  'ok' => Icons.check_circle,
  'rodando' => Icons.autorenew,
  'na fila' => Icons.schedule,
  'erro' => Icons.error,
  'interrompido' => Icons.report,
  'cancelado' => Icons.cancel,
  _ => Icons.radio_button_unchecked,
};

class StatePill extends StatelessWidget {
  const StatePill(this.state, {super.key, this.texto});

  final String state;
  final String? texto;

  @override
  Widget build(BuildContext context) {
    final color = corDoEstado(Theme.of(context).colorScheme, state);
    return Chip(
      avatar: Icon(iconOfState(state), size: 16, color: color),
      label: Text(texto ?? state),
      side: BorderSide(color: color.withValues(alpha: 0.5)),
    );
  }
}

/// Runs a queue action and reports the result in a SnackBar.
Future<void> actionWithWarning(BuildContext context, Future<String> Function() acao) async {
  final aviso = ScaffoldMessenger.of(context);
  try {
    aviso.showSnackBar(SnackBar(content: Text(await acao())));
  } catch (e) {
    aviso.showSnackBar(SnackBar(content: Text('Falhou: $e')));
  }
}

class Empty extends StatelessWidget {
  const Empty(this.texto, {super.key, this.icone = Icons.inbox_outlined});

  final String texto;
  final IconData icone;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icone, size: 48, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(texto, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

/// Script text with markup: `*destaque*` (highlight color) and `**negrito**`.
class MarkedText extends StatelessWidget {
  const MarkedText(this.texto, {super.key, this.estilo});

  final String texto;
  final TextStyle? estilo;

  static final _mark = RegExp(r'\*\*(.+?)\*\*|\*(.+?)\*');

  @override
  Widget build(BuildContext context) {
    final highlight = TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600);
    final parts = <InlineSpan>[];
    var i = 0;
    for (final m in _mark.allMatches(texto)) {
      if (m.start > i) parts.add(TextSpan(text: texto.substring(i, m.start)));
      parts.add(
        m.group(1) != null
            ? TextSpan(
                text: m.group(1),
                style: const TextStyle(fontWeight: FontWeight.bold),
              )
            : TextSpan(text: m.group(2), style: highlight),
      );
      i = m.end;
    }
    if (i < texto.length) parts.add(TextSpan(text: texto.substring(i)));
    return Text.rich(TextSpan(children: parts), style: estilo);
  }
}

/// Opens the URL in a tab (PDF in the reader, page in the WebView; on desktop, page in the browser).
Future<void> openUrl(BuildContext context, String url) => abrirLink(context, url);

String dollars(num? v, {int places = 3}) => 'US\$ ${(v ?? 0).toStringAsFixed(places)}';

/// Who runs an operation: Python, local LLM, GPU or Claude (same colors across the module).
class EnginePill extends StatelessWidget {
  const EnginePill(this.engine, {super.key, this.label, this.fixedColor});

  final String engine;
  final String? label;

  /// Own color (e.g. the scene mood) instead of the engine color.
  final MaterialColor? fixedColor;

  static MaterialColor color(String engine) => switch (engine) {
    'local' => Colors.teal,
    'gpu' => Colors.orange,
    'claude' => Colors.purple,
    _ => Colors.blueGrey,
  };

  static String nome(String engine) => switch (engine) {
    'local' => 'LLM local',
    'gpu' => 'GPU',
    'claude' => 'Claude',
    _ => 'Python',
  };

  @override
  Widget build(BuildContext context) {
    final c = fixedColor ?? color(engine);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        border: Border.all(color: c.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label ?? nome(engine), style: TextStyle(fontSize: 11, color: c.shade200)),
    );
  }
}

class Section extends StatelessWidget {
  const Section(this.titulo, {super.key, this.acao});

  final String titulo;
  final Widget? acao;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 8),
    child: Row(
      children: [
        Expanded(child: Text(titulo, style: Theme.of(context).textTheme.titleMedium)),
        ?acao,
      ],
    ),
  );
}

/// Big number card (summaries at the top of the screens).
class Indicator extends StatelessWidget {
  const Indicator(this.label, this.valor, {super.key, this.sub, this.color});

  final String label;
  final String valor;
  final String? sub;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SizedBox(
      width: 180,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label.toUpperCase(), style: t.labelSmall),
              Text(
                valor,
                style: t.headlineSmall?.copyWith(color: color, fontWeight: FontWeight.w600),
              ),
              if (sub != null) Text(sub!, style: t.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}
