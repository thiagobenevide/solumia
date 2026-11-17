import 'package:flutter/material.dart';

import 'camera_pro.dart';
import 'receiver.dart';

const _whiteBalances = [
  ('auto', 'Auto'),
  ('daylight', 'Luz do dia'),
  ('cloudy', 'Nublado'),
  ('shade', 'Sombra'),
  ('fluorescent', 'Fluorescente'),
  ('incandescent', 'Incandescente'),
];

/// Pro mode of the phone camera driven from the PC: lens, exposure, focus, white balance, zoom and
/// image. Reads the state the phone reports and sends each change back on the video connection.
class PhoneProPanel extends StatelessWidget {
  const PhoneProPanel({super.key, required this.receiver});

  final Receiver receiver;

  @override
  Widget build(BuildContext context) {
    final phone = receiver.phone;
    if (phone == null) return const SizedBox.shrink();
    final raw = phone['camera'];
    final settings = phone['settings'];
    if (raw is! Map || settings is! Map) return const SizedBox.shrink();
    final camera = CameraInfo.fromJson(Map<String, dynamic>.from(raw));
    final values = Map<String, dynamic>.from(settings);
    final fps = phone['fps'] as int? ?? 30;
    final text = Theme.of(context).textTheme;
    final children = <Widget>[
      Text('Câmera do celular (modo Pro)', style: text.titleSmall),
      Text(_live(phone), style: text.bodySmall),
      const SizedBox(height: 8),
    ];
    children.addAll(_lenses(phone, text));
    children.addAll(_exposure(camera, values, fps, text));
    children.addAll(_focus(camera, values, text));
    children.addAll(_whiteBalance(camera, values, text));
    children.addAll(_image(camera, values, text));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  void _set(String key, Object? value) => receiver.setPhone({key: value});

  String _live(Map<String, dynamic> phone) {
    final live = phone['live'];
    if (live is! Map) return '';
    final iso = live['iso'];
    final exposure = live['exposureNs'];
    final shutter = exposure is num && exposure > 0 ? '1/${(1e9 / exposure).round()}' : '-';
    return 'Agora: ISO ${iso ?? '-'} · $shutter';
  }

  // ------------------------------------------------------------------ lens

  List<Widget> _lenses(Map<String, dynamic> phone, TextTheme text) {
    final lenses = phone['lenses'];
    if (lenses is! List || lenses.length < 2) return const [];
    final current = phone['lens'];
    final chips = <Widget>[];
    for (final lens in lenses) {
      if (lens is! Map) continue;
      final id = lens['id'] as String? ?? '';
      chips.add(ChoiceChip(
        label: Text(lens['label'] as String? ?? id),
        selected: id == current,
        onSelected: (_) => receiver.setLens(id),
      ));
    }
    return [
      _title('Lente', text),
      Wrap(spacing: 6, runSpacing: 6, children: chips),
      Text('Trocar a lente reinicia a transmissão por um instante.', style: text.bodySmall),
    ];
  }

  // ------------------------------------------------------------------ exposure

  List<Widget> _exposure(CameraInfo camera, Map<String, dynamic> v, int fps, TextTheme text) {
    final manual = v['manualExposure'] == true;
    final result = <Widget>[_title('Exposição', text)];
    result.add(SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: const Text('Manual (ISO e obturador)'),
      value: manual,
      onChanged: camera.manual ? (on) => _set('manualExposure', on) : null,
    ));
    if (manual) {
      final iso = (v['iso'] as num? ?? camera.isoMin).toDouble();
      result.add(_slider('ISO', '${iso.round()}', iso, camera.isoMin.toDouble(), camera.isoMax.toDouble(),
          (x) => _set('iso', (x / 10).round() * 10)));
      result.add(_shutter(camera, v, fps));
      return result;
    }
    if (camera.evMax > camera.evMin) {
      final ev = (v['compensation'] as num? ?? 0).toDouble();
      final label = (ev * camera.evStep).toStringAsFixed(1);
      result.add(_slider('Brilho (EV)', label, ev, camera.evMin.toDouble(), camera.evMax.toDouble(),
          (x) => _set('compensation', x.round()),
          divisions: camera.evMax - camera.evMin));
    }
    result.add(_switch('Travar exposição', v['lockAe'] == true, (on) => _set('lockAe', on)));
    return result;
  }

  Widget _shutter(CameraInfo camera, Map<String, dynamic> v, int fps) {
    final options = camera.shutterSpeeds(fps);
    if (options.isEmpty) return const SizedBox.shrink();
    final current = v['exposureNs'] as num? ?? options.last;
    var index = options.indexWhere((o) => o <= current);
    if (index < 0) index = options.length - 1;
    return _slider('Obturador', '1/${(1e9 / options[index]).round()}', index.toDouble(), 0,
        (options.length - 1).toDouble(), (x) => _set('exposureNs', options[x.round()]),
        divisions: options.length > 1 ? options.length - 1 : null);
  }

  // ------------------------------------------------------------------ focus

  List<Widget> _focus(CameraInfo camera, Map<String, dynamic> v, TextTheme text) {
    final manual = v['manualFocus'] == true;
    final result = <Widget>[_title('Foco', text)];
    result.add(SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: const Text('Manual (distância)'),
      value: manual,
      onChanged: camera.focusMin > 0 ? (on) => _set('manualFocus', on) : null,
    ));
    if (manual) {
      // diopters: 0 = infinity (far), focusMin = closest the lens can focus
      final focus = (v['focus'] as num? ?? 0).toDouble().clamp(0, camera.focusMin).toDouble();
      result.add(_slider('Distância', _distance(focus), focus, 0, camera.focusMin, (x) => _set('focus', x)));
      result.add(Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [Text('longe', style: text.bodySmall), Text('perto', style: text.bodySmall)],
      ));
    }
    if (camera.point) {
      final hasPoint = (v['pointX'] as num? ?? -1) >= 0;
      result.add(Row(
        children: [
          Expanded(
            child: Text(
              hasPoint ? 'Foco e medição no ponto escolhido' : 'Toque no vídeo para escolher onde focar',
              style: text.bodySmall,
            ),
          ),
          if (hasPoint)
            TextButton(onPressed: () => receiver.setPhone({'pointX': -1, 'pointY': -1}), child: const Text('Auto')),
        ],
      ));
    }
    return result;
  }

  String _distance(double diopters) {
    if (diopters <= 0.01) return '∞';
    final meters = 1 / diopters;
    return meters >= 1 ? '${meters.toStringAsFixed(1)} m' : '${(meters * 100).round()} cm';
  }

  // ------------------------------------------------------------------ white balance

  List<Widget> _whiteBalance(CameraInfo camera, Map<String, dynamic> v, TextTheme text) {
    final awb = v['awb'] as String? ?? 'auto';
    final chips = <Widget>[];
    for (final (key, label) in _whiteBalances) {
      chips.add(ChoiceChip(label: Text(label), selected: awb == key, onSelected: (_) => _set('awb', key)));
    }
    if (camera.kelvin) {
      chips.add(ChoiceChip(
        label: const Text('Manual (K)'),
        selected: awb == 'manual',
        onSelected: (_) => _set('awb', 'manual'),
      ));
    }
    final result = <Widget>[_title('Balanço de branco', text), Wrap(spacing: 6, runSpacing: 6, children: chips)];
    if (awb == 'manual') {
      final kelvin = (v['kelvin'] as num? ?? 5000).toDouble().clamp(2000, 10000).toDouble();
      result.add(_slider('Temperatura', '${kelvin.round()} K', kelvin, 2000, 10000,
          (x) => _set('kelvin', (x / 50).round() * 50),
          divisions: 160));
    }
    result.add(_switch('Travar branco', v['lockAwb'] == true, (on) => _set('lockAwb', on)));
    return result;
  }

  // ------------------------------------------------------------------ zoom and image

  List<Widget> _image(CameraInfo camera, Map<String, dynamic> v, TextTheme text) {
    final result = <Widget>[_title('Zoom e imagem', text)];
    final zoomMax = camera.zoomMax.clamp(camera.zoomMin, 10.0).toDouble();
    if (zoomMax > camera.zoomMin) {
      final zoom = (v['zoom'] as num? ?? 1).toDouble().clamp(camera.zoomMin, zoomMax).toDouble();
      result.add(_slider('Zoom', '${zoom.toStringAsFixed(1)}×', zoom, camera.zoomMin, zoomMax,
          (x) => _set('zoom', (x * 10).round() / 10)));
    }
    if (camera.eis) {
      result.add(_switch('Estabilização eletrônica (corta as bordas)', v['stabilization'] == true,
          (on) => _set('stabilization', on)));
    }
    result.add(_switch('Lanterna', v['torch'] == true, (on) => _set('torch', on)));
    result.add(_quality('Redução de ruído', v['noise'] as String? ?? 'fast', (q) => _set('noise', q)));
    result.add(_quality('Nitidez', v['edge'] as String? ?? 'fast', (q) => _set('edge', q)));
    return result;
  }

  Widget _quality(String title, String current, ValueChanged<String> change) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Expanded(child: Text(title)),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'off', label: Text('Off')),
              ButtonSegment(value: 'fast', label: Text('Rápido')),
              ButtonSegment(value: 'quality', label: Text('Máx.')),
            ],
            selected: {current},
            onSelectionChanged: (s) => change(s.first),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ helpers

  Widget _title(String title, TextTheme text) {
    return Padding(padding: const EdgeInsets.only(top: 12, bottom: 4), child: Text(title, style: text.labelLarge));
  }

  Widget _switch(String title, bool value, ValueChanged<bool> change) {
    return SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      value: value,
      onChanged: change,
    );
  }

  Widget _slider(
    String title,
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> change, {
    int? divisions,
  }) {
    final safeMax = max > min ? max : min + 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [Expanded(child: Text(title)), Text(label)]),
        Slider(min: min, max: safeMax, divisions: divisions, value: value.clamp(min, safeMax), onChanged: change),
      ],
    );
  }
}
