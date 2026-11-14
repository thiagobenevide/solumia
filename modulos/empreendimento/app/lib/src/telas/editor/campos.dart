import 'dart:convert';

import 'package:flutter/material.dart';

/// Campos do editor. Cada um recebe o valor inicial e avisa a mudança; quando o estado muda por fora
/// (assistente, desfazer, arrastar caixa), a tela recria os campos trocando a `key`.

class CampoTexto extends StatelessWidget {
  const CampoTexto(
    this.rotulo,
    this.valor,
    this.mudou, {
    super.key,
    this.linhas = 1,
    this.cor = false,
    this.ativo = true,
  });

  final String rotulo;
  final Object? valor;
  final ValueChanged<String> mudou;
  final int linhas;

  /// Cor em `#rrggbb`: mostra uma amostra ao lado.
  final bool cor;
  final bool ativo;

  @override
  Widget build(BuildContext context) => TextFormField(
    initialValue: valor == null ? '' : '$valor',
    enabled: ativo,
    minLines: linhas,
    maxLines: linhas == 1 ? 1 : linhas + 4,
    style: cor ? const TextStyle(fontFamily: 'monospace') : null,
    decoration: InputDecoration(
      labelText: rotulo,
      isDense: true,
      border: const OutlineInputBorder(),
      hintText: cor ? '#rrggbb' : null,
      suffixIcon: cor ? _Amostra('$valor') : null,
    ),
    onChanged: mudou,
  );
}

class _Amostra extends StatelessWidget {
  const _Amostra(this.hex);

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

class CampoNumero extends StatelessWidget {
  const CampoNumero(this.rotulo, this.valor, this.mudou, {super.key});

  final String rotulo;
  final num? valor;

  /// `null` quando o campo fica vazio.
  final ValueChanged<num?> mudou;

  @override
  Widget build(BuildContext context) => TextFormField(
    initialValue: valor == null ? '' : '$valor',
    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
    decoration: InputDecoration(labelText: rotulo, isDense: true, border: const OutlineInputBorder()),
    onChanged: (v) => mudou(v.trim().isEmpty ? null : num.tryParse(v.replaceAll(',', '.'))),
  );
}

class CampoOpcoes extends StatelessWidget {
  const CampoOpcoes(this.rotulo, this.valor, this.opcoes, this.mudou, {super.key});

  final String rotulo;
  final String? valor;
  final List<String> opcoes;
  final ValueChanged<String> mudou;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<String>(
    initialValue: opcoes.contains(valor) ? valor : null,
    isExpanded: true,
    decoration: InputDecoration(labelText: rotulo, isDense: true, border: const OutlineInputBorder()),
    items: [
      for (final o in opcoes)
        DropdownMenuItem(
          value: o,
          child: Text(o, overflow: TextOverflow.ellipsis),
        ),
    ],
    onChanged: (v) => v == null ? null : mudou(v),
  );
}

class CampoBool extends StatelessWidget {
  const CampoBool(this.rotulo, this.valor, this.mudou, {super.key});

  final String rotulo;
  final bool valor;
  final ValueChanged<bool> mudou;

  @override
  Widget build(BuildContext context) => _CampoBoolEstado(rotulo: rotulo, valor: valor, mudou: mudou);
}

class _CampoBoolEstado extends StatefulWidget {
  const _CampoBoolEstado({required this.rotulo, required this.valor, required this.mudou});

  final String rotulo;
  final bool valor;
  final ValueChanged<bool> mudou;

  @override
  State<_CampoBoolEstado> createState() => _CampoBoolEstadoState();
}

class _CampoBoolEstadoState extends State<_CampoBoolEstado> {
  late bool _v = widget.valor;

  @override
  Widget build(BuildContext context) => SwitchListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    title: Text(widget.rotulo),
    value: _v,
    onChanged: (v) {
      setState(() => _v = v);
      widget.mudou(v);
    },
  );
}

/// Valor estruturado (lista/objeto) dos dados de um modelo, editado como JSON; só avisa quando é válido.
class CampoJson extends StatefulWidget {
  const CampoJson(this.rotulo, this.valor, this.mudou, {super.key});

  final String rotulo;
  final Object? valor;
  final ValueChanged<Object?> mudou;

  @override
  State<CampoJson> createState() => _CampoJsonState();
}

class _CampoJsonState extends State<CampoJson> {
  String? _erro;

  @override
  Widget build(BuildContext context) => TextFormField(
    initialValue: const JsonEncoder.withIndent(' ').convert(widget.valor),
    minLines: 3,
    maxLines: 12,
    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
    decoration: InputDecoration(
      labelText: '${widget.rotulo} (JSON)',
      isDense: true,
      border: const OutlineInputBorder(),
      errorText: _erro,
    ),
    onChanged: (v) {
      try {
        widget.mudou(jsonDecode(v));
        setState(() => _erro = null);
      } on FormatException {
        setState(() => _erro = 'JSON inválido');
      }
    },
  );
}

/// Grade responsiva de campos: [colunas] por linha em telas largas, um por linha nas estreitas.
class GradeCampos extends StatelessWidget {
  const GradeCampos({super.key, required this.filhos, this.colunas = 3, this.largos = const {}});

  final List<Widget> filhos;
  final int colunas;

  /// Índices de [filhos] que ocupam a linha inteira.
  final Set<int> largos;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, area) {
      final n = area.maxWidth < 320 ? 1 : colunas;
      final largura = (area.maxWidth - 8 * (n - 1)) / n;
      return Wrap(
        spacing: 8,
        runSpacing: 10,
        children: [
          for (final (i, f) in filhos.indexed)
            SizedBox(width: largos.contains(i) ? area.maxWidth : largura, child: f),
        ],
      );
    },
  );
}
