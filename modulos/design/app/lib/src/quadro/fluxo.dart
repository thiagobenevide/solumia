import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../modelos.dart';

// ---------- texto com formatação ----------

/// Diálogo de texto com negrito, itálico, sublinhado e marcador: os botões envolvem o trecho
/// selecionado nas marcas que `textoFormatado` desenha (`**`, `*`, `__`, `==`). Com [formatar]
/// falso é só um campo de uma linha (rótulo de seta).
Future<String?> editarTextoFormatado(
  BuildContext context, {
  String titulo = 'Texto',
  String inicial = '',
  String confirmar = 'Inserir',
  bool formatar = true,
}) => showDialog<String>(
  context: context,
  builder: (_) => _DialogoTexto(titulo: titulo, inicial: inicial, confirmar: confirmar, formatar: formatar),
);

/// O controle do campo vive com o diálogo: descartá-lo logo depois do `showDialog` quebrava a
/// animação de fechar ("TextEditingController used after being disposed").
class _DialogoTexto extends StatefulWidget {
  const _DialogoTexto({required this.titulo, required this.inicial, required this.confirmar, required this.formatar});

  final String titulo, inicial, confirmar;
  final bool formatar;

  @override
  State<_DialogoTexto> createState() => _DialogoTextoState();
}

class _DialogoTextoState extends State<_DialogoTexto> {
  late final _controle = TextEditingController(text: widget.inicial);

  @override
  void dispose() {
    _controle.dispose();
    super.dispose();
  }

  void _envolver(String marca) {
    final sel = _controle.selection;
    final t = _controle.text;
    final ini = sel.isValid ? sel.start : t.length, fim = sel.isValid ? sel.end : t.length;
    _controle.value = TextEditingValue(
      text: t.replaceRange(ini, fim, '$marca${t.substring(ini, fim)}$marca'),
      selection: TextSelection(baseOffset: ini + marca.length, extentOffset: fim + marca.length),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.titulo),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.formatar)
            Row(
              children: [
                IconButton(tooltip: 'Negrito', onPressed: () => _envolver('**'), icon: const Icon(Icons.format_bold)),
                IconButton(tooltip: 'Itálico', onPressed: () => _envolver('*'), icon: const Icon(Icons.format_italic)),
                IconButton(
                  tooltip: 'Sublinhado',
                  onPressed: () => _envolver('__'),
                  icon: const Icon(Icons.format_underlined),
                ),
                IconButton(tooltip: 'Marcador', onPressed: () => _envolver('=='), icon: const Icon(Icons.border_color)),
              ],
            ),
          TextField(
            controller: _controle,
            autofocus: true,
            maxLines: widget.formatar ? 6 : 1,
            minLines: widget.formatar ? 2 : 1,
            onSubmitted: widget.formatar ? null : (v) => Navigator.pop(context, v),
          ),
          if (widget.formatar)
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
      FilledButton(onPressed: () => Navigator.pop(context, _controle.text), child: Text(widget.confirmar)),
    ],
  );
}

// ---------- fluxograma com IA ----------

enum ModoFluxo {
  descrever('Descrever'),
  codigo('A partir de código'),
  ajustar('Ajustar o atual');

  const ModoFluxo(this.rotulo);

  final String rotulo;
}

class PedidoFluxo {
  const PedidoFluxo(this.modo, this.pedido, this.provedor, {this.codigo = '', this.arquivo = ''});

  final ModoFluxo modo;
  final String pedido, provedor, codigo, arquivo;
}

/// Diálogo do "Fluxo com IA": descrever a regra, mandar um arquivo de código ou ajustar o fluxo que
/// já está no quadro ([temFluxo]).
Future<PedidoFluxo?> pedirFluxo(BuildContext context, {required bool temFluxo, required List<String> provedores}) =>
    showDialog<PedidoFluxo>(
      context: context,
      builder: (_) => _DialogoFluxo(temFluxo: temFluxo, provedores: provedores),
    );

class _DialogoFluxo extends StatefulWidget {
  const _DialogoFluxo({required this.temFluxo, required this.provedores});

  final bool temFluxo;
  final List<String> provedores;

  @override
  State<_DialogoFluxo> createState() => _DialogoFluxoState();
}

class _DialogoFluxoState extends State<_DialogoFluxo> {
  late ModoFluxo _modo = widget.temFluxo ? ModoFluxo.ajustar : ModoFluxo.descrever;
  late String _provedor = widget.provedores.first;
  final _pedido = TextEditingController();
  String _codigo = '', _arquivo = '';

  @override
  void dispose() {
    _pedido.dispose();
    super.dispose();
  }

  Future<void> _escolherCodigo() async {
    final a = (await FilePicker.pickFiles()).firstOrNull;
    if (a == null) return;
    final bytes = await a.xFile.readAsBytes();
    setState(() {
      _codigo = utf8.decode(bytes, allowMalformed: true);
      _arquivo = a.name;
    });
  }

  @override
  Widget build(BuildContext context) {
    final pronto = switch (_modo) {
      ModoFluxo.codigo => _codigo.isNotEmpty,
      _ => _pedido.text.trim().isNotEmpty,
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
            SegmentedButton<ModoFluxo>(
              segments: [
                for (final m in ModoFluxo.values)
                  if (m != ModoFluxo.ajustar || widget.temFluxo) ButtonSegment(value: m, label: Text(m.rotulo)),
              ],
              selected: {_modo},
              onSelectionChanged: (s) => setState(() => _modo = s.first),
            ),
            if (_modo == ModoFluxo.codigo)
              Row(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _escolherCodigo,
                    icon: const Icon(Icons.upload_file),
                    label: const Text('Escolher arquivo de código'),
                  ),
                  Expanded(
                    child: Text(
                      _arquivo.isEmpty ? 'Nenhum arquivo' : '$_arquivo (${_codigo.length} caracteres)',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            TextField(
              controller: _pedido,
              autofocus: true,
              minLines: 3,
              maxLines: 8,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: switch (_modo) {
                  ModoFluxo.descrever => 'Descreva a regra de negócio',
                  ModoFluxo.codigo => 'Foco (opcional): ex. "só a aprovação de crédito"',
                  ModoFluxo.ajustar => 'O que mudar: ex. "inclua a validação de estoque"',
                },
              ),
            ),
            if (widget.provedores.length > 1)
              Row(
                spacing: 8,
                children: [
                  const Text('IA:'),
                  SegmentedButton<String>(
                    segments: [
                      for (final p in widget.provedores)
                        ButtonSegment(value: p, label: Text(p == 'local' ? 'LLM local' : 'Claude')),
                    ],
                    selected: {_provedor},
                    onSelectionChanged: (s) => setState(() => _provedor = s.first),
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
                  PedidoFluxo(
                    _modo,
                    _pedido.text.trim(),
                    _provedor,
                    codigo: _modo == ModoFluxo.codigo ? _codigo : '',
                    arquivo: _arquivo,
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

/// Cores padrão dos blocos por tipo (o usuário recolore depois pela seleção).
const coresDoFluxo = {
  TipoNo.inicio: Color(0xFF2E7D32),
  TipoNo.fim: Color(0xFFC62828),
  TipoNo.processo: Color(0xFF1565C0),
  TipoNo.decisao: Color(0xFFEF6C00),
  TipoNo.dado: Color(0xFF6A1B9A),
  TipoNo.subprocesso: Color(0xFF00838F),
  TipoNo.quadrado: Color(0xFF455A64),
  TipoNo.circulo: Color(0xFF5D4037),
  TipoNo.documento: Color(0xFF283593),
  TipoNo.banco: Color(0xFF00695C),
  TipoNo.nota: Color(0xFFF9A825),
  TipoNo.hexagono: Color(0xFFAD1457),
  TipoNo.container: Color(0xFF607D8B),
};

/// Fluxo do servidor (`nos` com x/y/w/h, `ligacoes`) → elementos do quadro, com o canto de cima à
/// esquerda em [origem]. Os ids ficam `<fluxo>.<id do nó>`: ajustar o fluxo mantém os mesmos.
List<Elemento> elementosDoFluxo(Map<String, dynamic> fluxo, Offset origem, String idFluxo) {
  final nos = (fluxo['nos'] as List).cast<Map<String, dynamic>>();
  if (nos.isEmpty) return const [];
  double num_(Object? v) => (v as num? ?? 0).toDouble();
  final minX = nos.map((n) => num_(n['x'])).reduce((a, b) => a < b ? a : b);
  final minY = nos.map((n) => num_(n['y'])).reduce((a, b) => a < b ? a : b);
  final desloca = origem - Offset(minX, minY);
  final saida = <Elemento>[];
  for (final n in nos) {
    final tipo = TipoNo.de(n['tipo'] as String?);
    final a = Offset(num_(n['x']), num_(n['y'])) + desloca;
    saida.add(
      NoFluxo(
        '$idFluxo.${n['id']}',
        tipo: tipo,
        texto: '${n['texto'] ?? ''}',
        a: a,
        b: a + Offset(num_(n['w']), num_(n['h'])),
        cor: coresDoFluxo[tipo]!,
        fluxo: idFluxo,
      ),
    );
  }
  var i = 0;
  for (final l in (fluxo['ligacoes'] as List).cast<Map<String, dynamic>>()) {
    saida.add(
      Ligacao(
        '$idFluxo.l${i++}',
        de: '$idFluxo.${l['de']}',
        para: '$idFluxo.${l['para']}',
        a: Offset.zero,
        b: Offset.zero,
        cor: const Color(0xFF37474F),
        rotulo: '${l['rotulo'] ?? ''}',
        fluxo: idFluxo,
        ortogonal: true,
      ),
    );
  }
  return religar(saida);
}

/// O fluxo [idFluxo] do quadro no formato que a IA recebe para ajustar (ids sem o prefixo).
Map<String, dynamic> fluxoDoQuadro(List<Elemento> elementos, String idFluxo) {
  String curto(String id) => id.startsWith('$idFluxo.') ? id.substring(idFluxo.length + 1) : id;
  return {
    'nos': [
      for (final n in elementos.whereType<NoFluxo>())
        if (n.fluxo == idFluxo) {'id': curto(n.id), 'tipo': n.tipo.name, 'texto': n.texto},
    ],
    'ligacoes': [
      for (final l in elementos.whereType<Ligacao>())
        if (l.fluxo == idFluxo) {'de': curto(l.de), 'para': curto(l.para), 'rotulo': l.rotulo},
    ],
  };
}
