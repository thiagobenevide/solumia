import 'package:flutter/material.dart';

import '../modelos.dart';

/// Nome de cada pauta no caderno.
const rotulosPauta = {
  Fundo.linhas: 'Pautado',
  Fundo.pontos: 'Pontilhado',
  Fundo.grade: 'Quadriculado',
  Fundo.liso: 'Liso',
};

/// Tamanhos de folha (px lógicos a 96 dpi).
const tamanhosFolha = <String, Size>{
  'A4': Size(794, 1123),
  'A5': Size(559, 794),
  'Carta': Size(816, 1056),
  'Largo (16:9)': Size(1280, 720),
  'Quadrado': Size(900, 900),
};

const coresPapel = [Color(0xFFFFFFFF), Color(0xFFFBF5E6), Color(0xFFF1F4F8), Color(0xFFEFF7EE), Color(0xFF2B2F33)];

/// Edita o papel; devolve o novo e se vale para todas as folhas (null = cancelou).
Future<({Papel papel, bool todas})?> editarPapel(BuildContext context, Papel atual) =>
    showDialog(context: context, builder: (_) => _DialogoPapel(atual));

class _DialogoPapel extends StatefulWidget {
  const _DialogoPapel(this.inicial);

  final Papel inicial;

  @override
  State<_DialogoPapel> createState() => _DialogoPapelState();
}

class _DialogoPapelState extends State<_DialogoPapel> {
  late Papel _p = widget.inicial;
  var _todas = false;

  bool get _deitado => _p.largura > _p.altura;

  void _tamanho(Size s) => setState(() {
    final girar = _deitado != (s.width > s.height) && s.width != s.height;
    _p = _p.copia(largura: girar ? s.height : s.width, altura: girar ? s.width : s.height);
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
            SegmentedButton<Fundo>(
              segments: [
                for (final e in rotulosPauta.entries) ButtonSegment(value: e.key, label: Text(e.value)),
              ],
              selected: {_p.fundo},
              onSelectionChanged: (s) => setState(() => _p = _p.copia(fundo: s.first)),
            ),
            Text('Espaço entre linhas: ${_p.espaco.round()} px'),
            Slider(
              value: _p.espaco.clamp(12, 64),
              min: 12,
              max: 64,
              divisions: 26,
              onChanged: (v) => setState(() => _p = _p.copia(espaco: v)),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final e in tamanhosFolha.entries)
                  ChoiceChip(
                    label: Text(e.key),
                    selected: {e.value.width, e.value.height}.containsAll({_p.largura, _p.altura}),
                    onSelected: (_) => _tamanho(e.value),
                  ),
                ActionChip(
                  avatar: const Icon(Icons.screen_rotation_alt, size: 18),
                  label: Text(_deitado ? 'Deitada' : 'Em pé'),
                  onPressed: () => setState(() => _p = _p.copia(largura: _p.altura, altura: _p.largura)),
                ),
              ],
            ),
            Text('Largura: ${_p.largura.round()} px'),
            Slider(
              value: _p.largura.clamp(400, 2400),
              min: 400,
              max: 2400,
              onChanged: (v) => setState(() => _p = _p.copia(largura: v.roundToDouble())),
            ),
            Text('Altura: ${_p.altura.round()} px'),
            Slider(
              value: _p.altura.clamp(400, 3400),
              min: 400,
              max: 3400,
              onChanged: (v) => setState(() => _p = _p.copia(altura: v.roundToDouble())),
            ),
            Row(
              spacing: 8,
              children: [
                const Text('Cor:'),
                for (final c in coresPapel)
                  InkWell(
                    onTap: () => setState(() => _p = _p.copia(cor: c)),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(
                          width: _p.cor == c ? 3 : 1,
                          color: _p.cor == c ? Theme.of(context).colorScheme.primary : Colors.black26,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Margem e cabeçalho'),
              value: _p.margem,
              onChanged: (v) => setState(() => _p = _p.copia(margem: v)),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Aplicar a todas as folhas'),
              value: _todas,
              onChanged: (v) => setState(() => _todas = v ?? false),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(onPressed: () => Navigator.pop(context, (papel: _p, todas: _todas)), child: const Text('Aplicar')),
    ],
  );
}
