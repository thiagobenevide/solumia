import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

String duracao(double? segundos) {
  if (segundos == null) return '';
  final s = segundos.round();
  if (s < 60) return '${s}s';
  if (s < 3600) return '${s ~/ 60}m${(s % 60).toString().padLeft(2, '0')}s';
  return '${s ~/ 3600}h${(s % 3600 ~/ 60).toString().padLeft(2, '0')}m';
}

String _dois(int n) => n.toString().padLeft(2, '0');

String hora(DateTime? t) => t == null ? '' : '${_dois(t.hour)}:${_dois(t.minute)}:${_dois(t.second)}';

String diaHora(DateTime? t) =>
    t == null ? '' : '${_dois(t.day)}/${_dois(t.month)} ${_dois(t.hour)}:${_dois(t.minute)}';

IconData iconeDoEstado(String estado) => switch (estado) {
  'ok' => Icons.check_circle,
  'rodando' => Icons.autorenew,
  'na fila' => Icons.schedule,
  'erro' => Icons.error,
  'interrompido' => Icons.report,
  'cancelado' => Icons.cancel,
  _ => Icons.radio_button_unchecked,
};

class SeloEstado extends StatelessWidget {
  const SeloEstado(this.estado, {super.key, this.texto});

  final String estado;
  final String? texto;

  @override
  Widget build(BuildContext context) {
    final cor = corDoEstado(Theme.of(context).colorScheme, estado);
    return Chip(
      avatar: Icon(iconeDoEstado(estado), size: 16, color: cor),
      label: Text(texto ?? estado),
      side: BorderSide(color: cor.withValues(alpha: 0.5)),
    );
  }
}

/// Executa uma ação da fila e avisa o resultado num SnackBar.
Future<void> acaoComAviso(BuildContext context, Future<String> Function() acao) async {
  final aviso = ScaffoldMessenger.of(context);
  try {
    aviso.showSnackBar(SnackBar(content: Text(await acao())));
  } catch (e) {
    aviso.showSnackBar(SnackBar(content: Text('Falhou: $e')));
  }
}

class Vazio extends StatelessWidget {
  const Vazio(this.texto, {super.key, this.icone = Icons.inbox_outlined});

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

/// Texto do roteiro com marcação: `*destaque*` (cor de destaque) e `**negrito**`.
class TextoMarcado extends StatelessWidget {
  const TextoMarcado(this.texto, {super.key, this.estilo});

  final String texto;
  final TextStyle? estilo;

  static final _marca = RegExp(r'\*\*(.+?)\*\*|\*(.+?)\*');

  @override
  Widget build(BuildContext context) {
    final destaque = TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600);
    final partes = <InlineSpan>[];
    var i = 0;
    for (final m in _marca.allMatches(texto)) {
      if (m.start > i) partes.add(TextSpan(text: texto.substring(i, m.start)));
      partes.add(
        m.group(1) != null
            ? TextSpan(
                text: m.group(1),
                style: const TextStyle(fontWeight: FontWeight.bold),
              )
            : TextSpan(text: m.group(2), style: destaque),
      );
      i = m.end;
    }
    if (i < texto.length) partes.add(TextSpan(text: texto.substring(i)));
    return Text.rich(TextSpan(children: partes), style: estilo);
  }
}

/// Abre a URL numa aba (PDF no leitor, página no WebView; no desktop, página no navegador).
Future<void> abrirUrl(BuildContext context, String url) => abrirLink(context, url);

String dolares(num? v, {int casas = 3}) => 'US\$ ${(v ?? 0).toStringAsFixed(casas)}';

/// Quem faz uma operação: Python, LLM local, GPU ou Claude (mesmas cores em todo o módulo).
class SeloMotor extends StatelessWidget {
  const SeloMotor(this.motor, {super.key, this.rotulo, this.corFixa});

  final String motor;
  final String? rotulo;

  /// Cor própria (ex.: clima da cena) no lugar da cor do motor.
  final MaterialColor? corFixa;

  static MaterialColor cor(String motor) => switch (motor) {
    'local' => Colors.teal,
    'gpu' => Colors.orange,
    'claude' => Colors.purple,
    _ => Colors.blueGrey,
  };

  static String nome(String motor) => switch (motor) {
    'local' => 'LLM local',
    'gpu' => 'GPU',
    'claude' => 'Claude',
    _ => 'Python',
  };

  @override
  Widget build(BuildContext context) {
    final c = corFixa ?? cor(motor);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        border: Border.all(color: c.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(rotulo ?? nome(motor), style: TextStyle(fontSize: 11, color: c.shade200)),
    );
  }
}

class Secao extends StatelessWidget {
  const Secao(this.titulo, {super.key, this.acao});

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

/// Cartão de número grande (resumos no topo das telas).
class Indicador extends StatelessWidget {
  const Indicador(this.rotulo, this.valor, {super.key, this.sub, this.cor});

  final String rotulo;
  final String valor;
  final String? sub;
  final Color? cor;

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
              Text(rotulo.toUpperCase(), style: t.labelSmall),
              Text(
                valor,
                style: t.headlineSmall?.copyWith(color: cor, fontWeight: FontWeight.w600),
              ),
              if (sub != null) Text(sub!, style: t.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}
