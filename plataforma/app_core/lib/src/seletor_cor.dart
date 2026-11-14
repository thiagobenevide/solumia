import 'package:flutter/material.dart';

/// Escolha de qualquer cor: [paleta] rápida, as recentes, matiz/saturação/brilho/opacidade e hexadecimal.
Future<Color?> escolherCor(
  BuildContext context,
  Color inicial,
  List<Color> recentes, {
  List<Color> paleta = const [],
}) => showDialog<Color>(context: context, builder: (_) => _SeletorCor(inicial, recentes, paleta));

class _SeletorCor extends StatefulWidget {
  const _SeletorCor(this.inicial, this.recentes, this.paleta);

  final Color inicial;
  final List<Color> recentes, paleta;

  @override
  State<_SeletorCor> createState() => _SeletorCorState();
}

class _SeletorCorState extends State<_SeletorCor> {
  late HSVColor _hsv = HSVColor.fromColor(widget.inicial);
  late final _hex = TextEditingController(text: _paraHex(widget.inicial));

  Color get _cor => _hsv.toColor();

  static String _paraHex(Color c) => c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase();

  void _definir(HSVColor hsv, {bool atualizarHex = true}) {
    setState(() => _hsv = hsv);
    if (atualizarHex) _hex.text = _paraHex(hsv.toColor());
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  Widget _amostra(Color c) => InkWell(
    onTap: () => _definir(HSVColor.fromColor(c)),
    customBorder: const CircleBorder(),
    child: Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: c,
        shape: BoxShape.circle,
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
    ),
  );

  Widget _faixa(String rotulo, double valor, double max, ValueChanged<double> mudar, List<Color> gradiente) => Row(
    children: [
      SizedBox(width: 72, child: Text(rotulo)),
      Expanded(
        child: Container(
          height: 28,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: LinearGradient(colors: gradiente),
          ),
          child: SliderTheme(
            data: SliderTheme.of(context)
                .copyWith(trackHeight: 0, activeTrackColor: Colors.transparent, inactiveTrackColor: Colors.transparent),
            child: Slider(value: valor, max: max, onChanged: mudar),
          ),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final puro = HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor();
    return AlertDialog(
      title: const Text('Cor'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              Wrap(spacing: 8, runSpacing: 8, children: [for (final c in widget.paleta) _amostra(c)]),
              if (widget.recentes.isNotEmpty) ...[
                const Text('Recentes'),
                Wrap(spacing: 8, runSpacing: 8, children: [for (final c in widget.recentes) _amostra(c)]),
              ],
              _faixa('Matiz', _hsv.hue, 360, (v) => _definir(_hsv.withHue(v)), [
                for (var h = 0; h <= 360; h += 60) HSVColor.fromAHSV(1, h.toDouble(), 1, 1).toColor(),
              ]),
              _faixa('Saturação', _hsv.saturation, 1, (v) => _definir(_hsv.withSaturation(v)), [Colors.white, puro]),
              _faixa('Brilho', _hsv.value, 1, (v) => _definir(_hsv.withValue(v)), [Colors.black, puro]),
              _faixa('Opacidade', _hsv.alpha, 1, (v) => _definir(_hsv.withAlpha(v)), [
                _cor.withValues(alpha: 0),
                _cor.withValues(alpha: 1),
              ]),
              Row(
                spacing: 12,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: _cor,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Theme.of(context).colorScheme.outline),
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _hex,
                      decoration: const InputDecoration(labelText: 'AARRGGBB', prefixText: '#'),
                      onChanged: (t) {
                        final limpo = t.replaceAll('#', '');
                        final v = int.tryParse(limpo.length == 6 ? 'FF$limpo' : limpo, radix: 16);
                        if (v != null && (limpo.length == 6 || limpo.length == 8)) {
                          _definir(HSVColor.fromColor(Color(v)), atualizarHex: false);
                        }
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(context, _cor), child: const Text('Usar')),
      ],
    );
  }
}
