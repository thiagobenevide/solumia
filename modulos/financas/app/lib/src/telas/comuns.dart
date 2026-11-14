import 'package:flutter/material.dart';

import '../api_financas.dart';
import '../formato.dart';

/// Contas e categorias, usadas por quase todas as telas; recarrega e avisa quando mudam.
class Cadastros extends ChangeNotifier {
  Cadastros(this.api);

  final ApiFinancas api;
  List<Doc> contas = [];
  List<Doc> categorias = [];
  bool carregado = false;

  Future<void> carregar() async {
    final (c, k) = await (api.listar('contas'), api.listar('categorias')).wait;
    contas = c;
    categorias = k..sort((a, b) => '${a['tipo']}${a['nome']}'.compareTo('${b['tipo']}${b['nome']}'));
    carregado = true;
    notifyListeners();
  }

  Doc? conta(String? id) => contas.where((c) => c['id'] == id).firstOrNull;

  Doc? categoria(String? id) => categorias.where((c) => c['id'] == id).firstOrNull;

  Map<String, String> get opcoesContas => {'': '—', for (final c in contas) c['id'] as String: c['nome'] as String};

  Map<String, String> get opcoesCategorias => {
    '': 'Sem categoria',
    for (final c in categorias) c['id'] as String: '${c['nome']} · ${rotuloTipo[c['tipo']] ?? ''}',
  };
}

const rotuloTipo = {
  'receita': 'receita',
  'despesa': 'despesa',
  'investimento': 'investimento',
  'transferencia': 'transferência',
};

void avisar(BuildContext context, String texto) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(texto)));

/// Roda [acao] mostrando o erro num aviso; devolve se deu certo.
Future<bool> tentar(BuildContext context, Future<void> Function() acao, {String? ok}) async {
  try {
    await acao();
    if (ok != null && context.mounted) avisar(context, ok);
    return true;
  } catch (e) {
    if (context.mounted) avisar(context, 'Erro: $e');
    return false;
  }
}

Future<bool> confirmar(BuildContext context, String texto) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        content: Text(texto),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Confirmar')),
        ],
      ),
    ) ??
    false;

/// FutureBuilder com carregando, erro (com tentar de novo) e o conteúdo.
class Esperar<T> extends StatelessWidget {
  const Esperar({super.key, required this.futuro, required this.construir, this.recarregar});

  final Future<T> futuro;
  final Widget Function(T) construir;
  final VoidCallback? recarregar;

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
    future: futuro,
    builder: (context, s) {
      if (s.hasError) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              Text('Não carregou: ${s.error}', textAlign: TextAlign.center),
              if (recarregar != null) OutlinedButton(onPressed: recarregar, child: const Text('Tentar de novo')),
            ],
          ),
        );
      }
      // `connectionState`, não `hasData`: um Future<void> termina com null.
      if (s.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
      return construir(s.data as T);
    },
  );
}

/// Bloco com título e ações, usado no painel e nas abas.
class Secao extends StatelessWidget {
  const Secao({super.key, required this.titulo, required this.child, this.acoes = const [], this.subtitulo});

  final String titulo;
  final String? subtitulo;
  final Widget child;
  final List<Widget> acoes;

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
                    Text(titulo, style: Theme.of(context).textTheme.titleMedium),
                    if (subtitulo != null)
                      Text(subtitulo!, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              ...acoes,
            ],
          ),
          child,
        ],
      ),
    ),
  );
}

/// Número de destaque (KPI) com rótulo e detalhe.
class Indicador extends StatelessWidget {
  const Indicador(this.rotulo, this.valor, {super.key, this.detalhe, this.cor, this.icone, this.largura = 190});

  final String rotulo;
  final String valor;
  final String? detalhe;
  final Color? cor;
  final IconData? icone;
  final double largura;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SizedBox(
      width: largura,
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
                  Expanded(child: Text(rotulo, style: t.labelMedium, overflow: TextOverflow.ellipsis)),
                ],
              ),
              Text(valor, style: t.titleLarge?.copyWith(color: cor, fontWeight: FontWeight.w600)),
              if (detalhe != null) Text(detalhe!, style: t.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ),
    );
  }
}

/// Grade de [Indicador]es que ocupa toda a largura: colunas iguais (mínimo 2, máximo 6, nunca mais que os
/// itens), sem sobra à direita nem cartões espremidos no celular.
class GradeIndicadores extends StatelessWidget {
  const GradeIndicadores({super.key, required this.children, this.larguraMinima = 170});

  final List<Widget> children;
  final double larguraMinima;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final colunas = (c.maxWidth / larguraMinima).floor().clamp(2, 6).clamp(1, children.isEmpty ? 1 : children.length).toInt();
      final largura = (c.maxWidth / colunas).floorToDouble();
      return Wrap(children: [for (final w in children) SizedBox(width: largura, child: w)]);
    },
  );
}

/// Barra de uso (0–100%+); passa de 100% fica vermelha.
class BarraProgresso extends StatelessWidget {
  const BarraProgresso(this.pct, {super.key, this.cor});

  final double? pct;
  final Color? cor;

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
        color: p > 100 ? cs.error : (p > 85 ? Colors.orange : (cor ?? cs.primary)),
      ),
    );
  }
}

/// Chip pequeno colorido (status, veredito).
class Etiqueta extends StatelessWidget {
  const Etiqueta(this.texto, {super.key, this.cor});

  final String texto;
  final Color? cor;

  @override
  Widget build(BuildContext context) {
    final c = cor ?? Theme.of(context).colorScheme.outline;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      child: Text(texto, style: TextStyle(color: c, fontSize: 12)),
    );
  }
}

Color corVeredito(String? v) => switch (v) {
  'apta para aporte' => Colors.green,
  'observar' => Colors.orange,
  'evitar' => Colors.red,
  _ => Colors.grey,
};

/// Duas colunas na tela larga, uma no celular.
class Colunas extends StatelessWidget {
  const Colunas({super.key, required this.esquerda, required this.direita, this.corte = 900});

  final List<Widget> esquerda;
  final List<Widget> direita;
  final double corte;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) => c.maxWidth < corte
        ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...esquerda, ...direita])
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: esquerda)),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: direita)),
            ],
          ),
  );
}

/// Seletor "‹ out/2026 ›".
class SeletorMes extends StatelessWidget {
  const SeletorMes({super.key, required this.mes, required this.aoMudar});

  final DateTime mes;
  final ValueChanged<DateTime> aoMudar;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => aoMudar(somarMeses(mes, -1))),
      TextButton(
        onPressed: () => aoMudar(DateTime(DateTime.now().year, DateTime.now().month)),
        child: Text(mesBr(mesIso(mes)), style: Theme.of(context).textTheme.titleMedium),
      ),
      IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => aoMudar(somarMeses(mes, 1))),
    ],
  );
}

// --- formulário genérico ---

enum TipoCampo { texto, longo, numero, inteiro, data, opcao, booleano }

class Campo {
  const Campo(this.chave, this.rotulo, {this.tipo = TipoCampo.texto, this.opcoes = const {}, this.obrigatorio = false, this.ajuda});

  final String chave;
  final String rotulo;
  final TipoCampo tipo;

  /// valor → rótulo, para [TipoCampo.opcao].
  final Map<String, String> opcoes;
  final bool obrigatorio;
  final String? ajuda;
}

/// Diálogo de criar/editar com os [campos]; devolve só os campos (já convertidos) ou null se cancelou.
Future<Doc?> formulario(BuildContext context, String titulo, List<Campo> campos, [Doc atual = const {}]) =>
    showDialog<Doc>(context: context, builder: (_) => _Formulario(titulo, campos, atual));

class _Formulario extends StatefulWidget {
  const _Formulario(this.titulo, this.campos, this.atual);

  final String titulo;
  final List<Campo> campos;
  final Doc atual;

  @override
  State<_Formulario> createState() => _FormularioState();
}

class _FormularioState extends State<_Formulario> {
  final _textos = <String, TextEditingController>{};
  final _valores = <String, dynamic>{};
  String? _erro;

  @override
  void initState() {
    super.initState();
    for (final c in widget.campos) {
      final v = widget.atual[c.chave];
      switch (c.tipo) {
        case TipoCampo.opcao:
          _valores[c.chave] = c.opcoes.containsKey(v) ? v : c.opcoes.keys.firstOrNull;
        case TipoCampo.booleano:
          _valores[c.chave] = v ?? true;
        case TipoCampo.numero:
          _textos[c.chave] = TextEditingController(text: v == null ? '' : numero(v as num).replaceAll('.', ''));
        case TipoCampo.data:
          _textos[c.chave] = TextEditingController(text: v == null || v == '' ? '' : dataBr(v as String));
        default:
          _textos[c.chave] = TextEditingController(text: v?.toString() ?? '');
      }
    }
  }

  @override
  void dispose() {
    for (final t in _textos.values) {
      t.dispose();
    }
    super.dispose();
  }

  String? _dataIso(String br) {
    final m = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})$').firstMatch(br.trim());
    if (m == null) return null;
    return iso(DateTime(int.parse(m[3]!), int.parse(m[2]!), int.parse(m[1]!)));
  }

  void _salvar() {
    final saida = <String, dynamic>{};
    for (final c in widget.campos) {
      final texto = _textos[c.chave]?.text.trim() ?? '';
      dynamic v;
      switch (c.tipo) {
        case TipoCampo.opcao || TipoCampo.booleano:
          v = _valores[c.chave];
        case TipoCampo.numero:
          v = lerNumero(texto);
          if (texto.isNotEmpty && v == null) return setState(() => _erro = '${c.rotulo}: número inválido');
        case TipoCampo.inteiro:
          v = int.tryParse(texto);
          if (texto.isNotEmpty && v == null) return setState(() => _erro = '${c.rotulo}: número inválido');
        case TipoCampo.data:
          v = texto.isEmpty ? null : _dataIso(texto);
          if (texto.isNotEmpty && v == null) return setState(() => _erro = '${c.rotulo}: use dd/mm/aaaa');
        default:
          v = texto;
      }
      if (c.obrigatorio && (v == null || v == '')) return setState(() => _erro = '${c.rotulo} é obrigatório');
      if (v == null && (c.tipo == TipoCampo.numero || c.tipo == TipoCampo.inteiro)) v = 0;
      saida[c.chave] = v;
    }
    Navigator.pop(context, saida);
  }

  Future<void> _escolherData(Campo c) async {
    final atual = _dataIso(_textos[c.chave]!.text);
    final d = await showDatePicker(
      context: context,
      initialDate: atual == null ? DateTime.now() : DateTime.parse(atual),
      firstDate: DateTime(1990),
      lastDate: DateTime(2100),
    );
    if (d != null) _textos[c.chave]!.text = dataBr(iso(d));
  }

  Widget _campo(Campo c) => switch (c.tipo) {
    TipoCampo.opcao => DropdownButtonFormField<String>(
      initialValue: _valores[c.chave] as String?,
      isExpanded: true,
      decoration: InputDecoration(labelText: c.rotulo, helperText: c.ajuda),
      items: [for (final e in c.opcoes.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
      onChanged: (v) => _valores[c.chave] = v,
    ),
    TipoCampo.booleano => SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(c.rotulo),
      value: _valores[c.chave] as bool,
      onChanged: (v) => setState(() => _valores[c.chave] = v),
    ),
    _ => TextField(
      controller: _textos[c.chave],
      maxLines: c.tipo == TipoCampo.longo ? 5 : 1,
      keyboardType: switch (c.tipo) {
        TipoCampo.numero => const TextInputType.numberWithOptions(decimal: true, signed: true),
        TipoCampo.inteiro => TextInputType.number,
        TipoCampo.longo => TextInputType.multiline,
        _ => TextInputType.text,
      },
      decoration: InputDecoration(
        labelText: c.rotulo + (c.obrigatorio ? ' *' : ''),
        helperText: c.ajuda,
        hintText: c.tipo == TipoCampo.data ? 'dd/mm/aaaa' : null,
        suffixIcon: c.tipo == TipoCampo.data
            ? IconButton(icon: const Icon(Icons.calendar_today, size: 18), onPressed: () => _escolherData(c))
            : null,
      ),
      onSubmitted: c.tipo == TipoCampo.longo ? null : (_) => _salvar(),
    ),
  };

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.titulo),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 10,
          children: [
            for (final c in widget.campos) _campo(c),
            if (_erro != null) Text(_erro!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(onPressed: _salvar, child: const Text('Salvar')),
    ],
  );
}

/// Menu "editar / excluir" usado nas listas.
class MenuItem extends StatelessWidget {
  const MenuItem({super.key, required this.aoEditar, required this.aoExcluir, this.extras = const {}});

  final VoidCallback aoEditar;
  final VoidCallback aoExcluir;
  final Map<String, VoidCallback> extras;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    onSelected: (v) => switch (v) {
      'editar' => aoEditar(),
      'excluir' => aoExcluir(),
      _ => extras[v]?.call(),
    },
    itemBuilder: (_) => [
      for (final e in extras.keys) PopupMenuItem(value: e, child: Text(e)),
      const PopupMenuItem(value: 'editar', child: Text('Editar')),
      const PopupMenuItem(value: 'excluir', child: Text('Excluir')),
    ],
  );
}
