import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_esteira.dart';
import '../models.dart';
import '../screens/util.dart';
import 'studio_tab.dart' show color;
import 'piece_preview.dart';

part 'style_tabs.dart';

/// Style (Flow A) = channel template, in 5 tabs: Identity (colors, color rules, fonts, tone, motion),
/// Layouts and modes, Triggers (what is said becomes a scene: layout + piece + color), Pieces (adjustment of each kit piece) and Test
/// with a script (breakdown without AI or render). "Propor com o Claude" analyzes the references and rewrites the style (once);
/// when locked, it only changes after unlocking. "Publicar" saves the new version; "Duplicar" creates a new template.
class StyleScreen extends StatefulWidget {
  const StyleScreen({super.key, required this.api, required this.id});

  final ApiEsteira api;
  final String id;

  @override
  State<StyleScreen> createState() => _StyleScreenState();
}

class _StyleScreenState extends State<StyleScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: _tabSpecs.length, vsync: this);
  // the channel's sibling styles (Apresentador · Dark) and the first of another mode, to compare
  List<Json> _siblings = [];
  Json? _sibling;
  String _selTrigger = 'porcentagem';
  String _search = '';
  String _pieceSel = 'anel_percentual';
  String _pieceFormat = '16:9';
  String _layoutSel = 'split';
  String _previewTrigger = 'porcentagem';
  Json? _test;
  String _testEp = '';
  String _textTest = '';
  int _testScene = 0;
  String _testFormat = '16:9';
  final Set<int> _warningsIgnored = {};
  Future<List<dynamic>>? _eps;

  static const _inputs = {
    'fade_deslize': 'Fade + deslize',
    'fade': 'Fade',
    'escala': 'Escala',
    'revelar': 'Revelar',
    'mascara': 'Máscara',
    'desfoque': 'Desfoque',
  };
  static const _curves = {
    'suave': 'Ease-out suave',
    'firme': 'Ease-out firme',
    'elastica': 'Elástica',
    'linear': 'Linear',
  };
  static const _outputs = {'fade': 'Fade', 'deslize': 'Deslize', 'desfoque': 'Desfoque', 'corte': 'Corte seco'};
  static const _colorDesc = {
    'fundo': 'Fundo das peças',
    'fundo2': 'Cards, caixas, barras vazias',
    'texto': 'Texto comum',
    'destaque': 'Só números, palavra-chave, passo atual',
    'apoio': 'Ganho, positivo, faça isso',
    'acento': 'Dívida, perda, evite isso',
  };

  void _change(VoidCallback f) => setState(f);

  void _openSibling(String id) => Navigator.of(
    context,
  ).pushReplacement(MaterialPageRoute<void>(builder: (_) => StyleScreen(api: widget.api, id: id)));

  Json? _e;
  List<String> _refs = [];
  final _guide = TextEditingController();
  final _niche = TextEditingController();
  final Map<String, TextEditingController> _colors = {};

  static const _roles = ['fundo', 'fundo2', 'texto', 'destaque', 'apoio', 'acento'];
  static const _sourceRoles = {
    'fonte_destaque': 'Títulos e números',
    'fonte_texto': 'Texto',
    'fonte_tecnica': 'Rótulos',
    'fonte_legenda': 'Legenda',
    'fonte_editorial': 'Capítulos e citações',
  };
  static const _axes = {'sfx': 'Efeitos sonoros', 'motion': 'Motion graphics', 'efeitos': 'Efeitos visuais'};
  List<Json> _sources = [];
  Json _table = {};
  static final Set<String> _loaded = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _guide.dispose();
    _niche.dispose();
    for (final c in _colors.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final d = await widget.api.estilo(widget.id);
    if (_sources.isEmpty) {
      _sources = [for (final f in await widget.api.studioSources()) f as Json];
      _table = await widget.api.studioLevels();
      _loadSources();
    }
    final e = d['estilo'] as Json;
    // esteira still without the new fields (server not restarted): fills in the defaults so the screen does not break
    e['regras_cor'] ??= <String, dynamic>{'um_destaque': true, 'sem_mistura': true, 'inativos': 0.4, 'sentido': true};
    e['tamanhos'] ??= <String, dynamic>{};
    e['bloquear'] ??= <dynamic>[];
    e['movimento'] ??= <String, dynamic>{
      'curva': 'suave',
      'ritmo': [2.0, 4.0],
      'entrada': 'fade_deslize',
      'entrada_s': 0.4,
      'saida': 'fade',
      'saida_s': 0.25,
      'proibidos': <dynamic>['bounce', 'shake', 'glitch', '3D', 'som de dinheiro'],
    };
    e['layouts'] ??= <String, dynamic>{
      'split_lado': 'esquerda',
      'split_largura': 0.45,
      'painel_entrada': 'desliza',
      'painel_entrada_s': 0.4,
      'area_segura': 0.05,
      'vertical_peca': 'cima',
      'reservar_inferior': true,
      'legenda_terco': true,
      'peca_cheia_max_s': 6.0,
      'capitulo_s': [2.0, 3.0],
      'broll_max_s': 4.0,
    };
    e['presenca'] ??= <String, dynamic>{
      'fora_max_s': 6.0,
      'peca_parada_s': 5.0,
      'mudanca_s': [2.0, 4.0],
      'mudanca_vertical_s': [1.5, 3.0],
    };
    e['gatilhos'] ??= [
      for (final g in (_table['gatilhos_padrao'] as List?) ?? const []) Json.from(g as Json),
    ];
    e['pecas'] ??= <String, dynamic>{};
    if (_siblings.isEmpty) {
      try {
        _siblings = [for (final t in await widget.api.templates('${e['canal']}')) t as Json];
        final outro = _siblings.where((t) => t['id'] != e['id'] && t['modo'] != e['modo']).firstOrNull;
        if (outro != null) _sibling = (await widget.api.estilo('${outro['id']}'))['estilo'] as Json;
      } catch (_) {}
    }
    if (!mounted) return;
    final skin = e['pele'] as Json;
    setState(() {
      _e = e;
      _refs = [for (final r in d['referencias'] as List) '$r'];
      _guide.text = '${e['guia']}';
      for (final p in _roles) {
        (_colors[p] ??= TextEditingController()).text = '${skin[p]}';
      }
    });
  }

  Json get _rules => _e!['regras'] as Json;
  Json get _skin => _e!['pele'] as Json;
  Json get _caption => _rules['legenda_visual'] as Json;
  Json get _levels => _rules['niveis'] as Json;
  bool get _locked => _e!['travado'] == true;

  /// Preview: each catalog font is registered in the app as `Estudio-<nome>`.
  Future<void> _loadSources() async {
    for (final f in _sources) {
      final nome = '${f['nome']}';
      if (_loaded.contains(nome)) continue;
      try {
        final bytes = await widget.api.sourceFile('${(f['arquivos'] as List).first}');
        await (FontLoader('Estudio-$nome')..addFont(Future.value(ByteData.sublistView(bytes)))).load();
        _loaded.add(nome);
        if (mounted) setState(() {});
      } catch (_) {}
    }
  }

  /// Chosen level: fills the table numbers (the server does the same when saving).
  void _level(String axis, String level) => setState(() {
    _levels[axis] = level;
    final values = ((_table['niveis'] as Json?)?[axis] as Json?)?[level] as Json?;
    values?.forEach((k, v) => _rules[k] = v is Map ? Json.from(v) : v);
  });

  /// Fine tuning: the axis becomes "personalizado" (the level no longer overwrites the numbers).
  void _thin(String axis, VoidCallback change) => setState(() {
    change();
    _levels[axis] = 'personalizado';
  });

  Future<void> _sendSource() async {
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['ttf', 'otf']);
    if (files.isEmpty || !mounted) return;
    await actionWithWarning(context, () async {
      for (final a in files) {
        await widget.api.sendSource(a.name, await a.xFile.readAsBytes());
      }
      _sources = [for (final f in await widget.api.studioSources()) f as Json];
      await _loadSources();
      return '${files.length} fonte(s) enviada(s)';
    });
    if (mounted) setState(() {});
  }

  Future<void> _duplicate() async {
    final id = TextEditingController(text: '${widget.id}-2'),
        nome = TextEditingController(text: '${_e!['nome']} (cópia)');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Duplicar estilo (novo template)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: id,
              decoration: const InputDecoration(labelText: 'id (minúsculas, números e hífen)'),
            ),
            TextField(
              controller: nome,
              decoration: const InputDecoration(labelText: 'nome'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Duplicar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final nav = Navigator.of(context);
    await actionWithWarning(context, () async {
      final newItem = await widget.api.duplicateStyle(widget.id, id.text.trim(), nome.text.trim());
      nav.pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => StyleScreen(api: widget.api, id: '${newItem['id']}'),
        ),
      );
      return 'Estilo ${newItem['id']} criado';
    });
  }

  /// Each save becomes a new version (the previous ones stay stored); the version name is optional.
  Future<void> _save() async {
    final label = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Salvar como v${(_e!['versao'] as num) + 1}'),
        content: TextField(
          controller: label,
          autofocus: true,
          decoration: InputDecoration(labelText: 'Nome da versão (opcional)', hintText: '${_e!['nome']}'),
          onSubmitted: (_) => Navigator.pop(c, true),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Salvar versão')),
        ],
      ),
    );
    final versionName = label.text.trim();
    label.dispose();
    if (ok != true || !mounted) return;
    final e = Json.from(_e!);
    e['rotulo'] = versionName;
    e['guia'] = _guide.text;
    e['pele'] = {...(e['pele'] as Json), for (final p in _roles) p: _colors[p]!.text.trim()};
    await actionWithWarning(context, () async {
      final newItem = await widget.api.saveStyle(widget.id, e);
      return 'Estilo salvo (v${newItem['versao']})';
    });
    await _load();
  }

  Future<void> _sendRefs() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
    );
    if (files.isEmpty || !mounted) return;
    await actionWithWarning(context, () async {
      for (final a in files) {
        await widget.api.sendReference(widget.id, a.name, await a.xFile.readAsBytes());
      }
      return '${files.length} referência(s) enviada(s)';
    });
    await _load();
  }

  Map<String, Color> get _palette => {for (final p in _roles) p: color(_colors[p]?.text)};

  List<Widget> _blocksReferences(BuildContext context) => [
      _Block(
        icone: Icons.collections_outlined,
        titulo: 'Referências',
        subtitulo:
            'Thumbs, quadros de vídeos que você admira, sua marca. O Claude analisa as imagens e escreve cores, guia, '
            'regras e exemplos; depois cada vídeo roda na IA local seguindo este estilo.',
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final r in _refs)
              InputChip(
                avatar: const Icon(Icons.image_outlined, size: 18),
                label: Text(r),
                onDeleted: () async {
                  await widget.api.eraseReference(widget.id, r);
                  await _load();
                },
              ),
            ActionChip(
              avatar: const Icon(Icons.upload),
              label: const Text('Enviar referências'),
              onPressed: _sendRefs,
            ),
          ],
        ),
      ),
      _Block(
        icone: Icons.auto_awesome,
        titulo: 'Proposta do Claude',
        subtitulo: 'Feita uma vez por template; reescreve o estilo a partir das referências.',
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: TextField(
                controller: _niche,
                decoration: const InputDecoration(
                  labelText: 'Nicho, público e tom (opcional)',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.auto_awesome),
              label: const Text('Propor com o Claude'),
              onPressed: () => actionWithWarning(context, () async {
                await widget.api.proposeStyle(widget.id, _niche.text);
                return 'Na fila (pista do Claude). Acompanhe em Fila; ao terminar, reabra o estilo.';
              }),
            ),
          ],
        ),
      ),
  ];

  // ───────────────────────── Identidade ─────────────────────────

  static const _samples = {
    'fonte_destaque': '81,7% ENDIVIDADAS',
    'fonte_texto': 'Das famílias brasileiras',
    'fonte_tecnica': 'CNC · 2026',
    'fonte_legenda': 'Você já ouviu ESSE número?',
    'fonte_editorial': 'O cartão de crédito',
  };

  Widget _colorCard(String p) {
    final tema = Theme.of(context);
    final c = _palette[p]!;
    final highlight = p == 'destaque';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: highlight ? c : tema.colorScheme.outlineVariant, width: highlight ? 1.5 : 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: c,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: tema.colorScheme.outlineVariant),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.toUpperCase(), style: tema.textTheme.labelSmall?.copyWith(letterSpacing: 1.2)),
                TextField(
                  controller: _colors[p],
                  enabled: !_locked,
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(fontFamily: 'monospace'),
                  decoration: const InputDecoration(isDense: true, border: InputBorder.none),
                ),
                Text(_colorDesc[p] ?? '', style: tema.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sourceLine(String role, String label) {
    final current = '${_skin[role] ?? _skin['fonte_destaque']}';
    final names = [for (final f in _sources) '${f['nome']}'];
    final outside = names.isNotEmpty && !names.contains(current);
    final size = ((_e!['tamanhos'] as Json)[role] as List?) ?? const [];
    final dest = _palette['destaque']!;
    final sample = _samples[role]!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        spacing: 16,
        children: [
          SizedBox(width: 150, child: Text(label)),
          SizedBox(
            width: 230,
            child: DropdownButtonFormField<String>(
              initialValue: outside ? null : current,
              isExpanded: true,
              hint: Text('$current (fora do catálogo)'),
              decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
              items: [
                for (final f in _sources)
                  DropdownMenuItem(
                    value: '${f['nome']}',
                    child: Text('${f['nome']}', style: TextStyle(fontFamily: 'Estudio-${f['nome']}')),
                  ),
              ],
              onChanged: _locked ? null : (v) => setState(() => _skin[role] = v),
            ),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  for (final (i, part) in sample.split(RegExp(r'(?=ESSE)|(?<=ESSE)|(?=81,7%)|(?<=81,7%)')).indexed)
                    TextSpan(
                      text: part,
                      style: TextStyle(color: part == 'ESSE' || (part == '81,7%' && i == 0) ? dest : null),
                    ),
                ],
              ),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Estudio-$current',
                fontSize: role == 'fonte_destaque' ? 26 : 20,
                fontWeight: role == 'fonte_legenda' ? FontWeight.w800 : FontWeight.w500,
              ),
            ),
          ),
          SizedBox(
            width: 90,
            child: TextFormField(
              key: ValueKey('tam$role${_e!['versao']}'),
              initialValue: size.length == 2 ? '${size[0]}–${size[1]}' : '',
              enabled: !_locked,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
              onChanged: (v) {
                final n = RegExp(r'\d+').allMatches(v).map((m) => int.parse(m[0]!)).toList();
                if (n.length == 2) (_e!['tamanhos'] as Json)[role] = n;
              },
            ),
          ),
        ],
      ),
    );
  }

  static double _contrast(Color a, Color b) {
    final la = a.computeLuminance(), lb = b.computeLuminance();
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  Widget _check() {
    final p = _palette;
    final items = <(int, String)>[];
    for (final (role, nome) in const [('texto', 'Texto'), ('destaque', 'Destaque'), ('apoio', 'Apoio'), ('acento', 'Acento')]) {
      final r = _contrast(p[role]!, p['fundo']!);
      final txt = '$nome sobre fundo: ${r.toStringAsFixed(1).replaceAll('.', ',')}:1';
      items.add(r >= 4.5 ? (0, txt) : (r >= 3 ? (1, '$txt, só em números grandes') : (2, '$txt, ilegível')));
    }
    final names = {for (final f in _sources) '${f['nome']}'};
    final outside = [for (final k in _sourceRoles.keys) if (names.isNotEmpty && !names.contains(_skin[k])) '${_skin[k]}'];
    items.add(outside.isEmpty ? (0, 'Todas as fontes no catálogo') : (1, 'Fora do catálogo: ${outside.join(', ')}'));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        const _Label('Checagem automática'),
        for (final (n, t) in items)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              Icon(
                [Icons.check, Icons.priority_high, Icons.close][n],
                size: 16,
                color: [Colors.green, Colors.amber, Colors.redAccent][n],
              ),
              Expanded(child: Text(t, style: Theme.of(context).textTheme.bodySmall)),
            ],
          ),
      ],
    );
  }

  Widget _styleState() {
    final g = _triggers;
    final active = g.where((x) => x['ativo'] != false).length;
    final test = _test;
    final lines = [
      ('Identidade', _checkOk ? 'completo' : 'revisar', _checkOk ? Colors.green : Colors.amber),
      ('Layouts', '${_layoutsMode[_mode]!.length} de ${_layoutsMode[_mode]!.length}', null),
      ('Gatilhos', '$active de ${g.length}', active < g.length ? Colors.amber : null),
      ('Peças', '${((_rules['filtro'] as List?) ?? const []).length} fora do canal', null),
      (
        'Último teste',
        test == null
            ? '—'
            : '${_testEp.isEmpty ? 'trecho colado' : _testEp} · ${(test['avisos'] as List).length - _warningsIgnored.length} avisos',
        null,
      ),
    ];
    return _Panel(
      titulo: 'Estado do estilo',
      child: Column(
        spacing: 6,
        children: [
          for (final (k, v, c) in lines)
            Row(
              children: [
                Expanded(child: Text(k)),
                Text(v, style: TextStyle(fontFamily: 'monospace', color: c)),
              ],
            ),
        ],
      ),
    );
  }

  bool get _checkOk =>
      _roles.every((p) => RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(_colors[p]?.text.trim() ?? '')) &&
      _contrast(_palette['texto']!, _palette['fundo']!) >= 4.5;

  Widget _dropMov(String label, List<(String, String)> options, String current, ValueChanged<String> mudou) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _Label(label),
      DropdownButtonFormField<String>(
        initialValue: options.any((o) => o.$1 == current) ? current : options.first.$1,
        isExpanded: true,
        decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
        items: [for (final (v, t) in options) DropdownMenuItem(value: v, child: Text(t))],
        onChanged: _locked ? null : (v) => setState(() => mudou(v!)),
      ),
    ],
  );

  Widget _motion() {
    final m = _e!['movimento'] as Json;
    final proib = m['proibidos'] as List;
    String fmtN(num v) => v.toString().replaceAll('.', ',');
    final rhythms = [
      for (final r in const [[1.5, 3.0], [2.0, 4.0], [3.0, 5.0], [4.0, 7.0]])
        ('${r[0]}-${r[1]}', 'Muda a cada ${fmtN(r[0])}–${fmtN(r[1])} s'),
    ];
    final r = m['ritmo'] as List;
    return _Panel(
      titulo: 'Movimento',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            spacing: 12,
            children: [
              Expanded(
                child: _dropMov('Curva', [for (final e in _curves.entries) (e.key, e.value)], '${m['curva']}', (v) => m['curva'] = v),
              ),
              Expanded(
                child: _dropMov(
                  'Ritmo',
                  rhythms,
                  '${(r[0] as num).toDouble()}-${(r[1] as num).toDouble()}',
                  (v) => m['ritmo'] = [for (final x in v.split('-')) double.parse(x)],
                ),
              ),
            ],
          ),
          Row(
            spacing: 12,
            children: [
              Expanded(
                child: _dropMov(
                  'Entrada',
                  [
                    for (final e in _inputs.entries)
                      for (final d in const [0.25, 0.4, 0.6]) ('${e.key}|$d', '${e.value} · ${fmtN(d)} s'),
                  ],
                  '${m['entrada']}|${(m['entrada_s'] as num).toDouble()}',
                  (v) {
                    m['entrada'] = v.split('|')[0];
                    m['entrada_s'] = double.parse(v.split('|')[1]);
                  },
                ),
              ),
              Expanded(
                child: _dropMov(
                  'Saída',
                  [
                    for (final e in _outputs.entries)
                      for (final d in const [0.15, 0.25, 0.4]) ('${e.key}|$d', '${e.value} · ${fmtN(d)} s'),
                  ],
                  '${m['saida']}|${(m['saida_s'] as num).toDouble()}',
                  (v) {
                    m['saida'] = v.split('|')[0];
                    m['saida_s'] = double.parse(v.split('|')[1]);
                  },
                ),
              ),
            ],
          ),
          const _Label('Proibidos'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final x in ((_table['proibiveis'] as List?) ?? proib))
                FilterChip(
                  label: Text('$x'),
                  selected: proib.contains(x),
                  onSelected: _locked ? null : (s) => setState(() => s ? proib.add(x) : proib.remove(x)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Intensidade (som, motion, efeitos)'),
            children: [_intensidade(context)],
          ),
        ],
      ),
    );
  }

  Widget _identity(BuildContext context) {
    final tema = Theme.of(context);
    final colorRules = _e!['regras_cor'] as Json;
    final siblingsTxt = [for (final t in _siblings) '${t['nome']}'].join(' e ');
    final esquerda = <Widget>[
      if (_siblings.length > 1)
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: tema.colorScheme.outlineVariant),
          ),
          child: Row(
            spacing: 10,
            children: [
              _pill(context, 'Base do canal', color: tema.colorScheme.primary),
              Expanded(
                child: Text(
                  'Cores, fontes, tom e movimento valem para este estilo; $siblingsTxt são do mesmo canal '
                  '(edite cada um, ou duplique para manter igual).',
                  style: tema.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      _Panel(
        titulo: 'Cores',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              builder: (context, c) {
                final columns = (c.maxWidth / 260).floor().clamp(1, 3);
                final largura = (c.maxWidth - 12 * (columns - 1)) / columns;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [for (final p in _roles) SizedBox(width: largura, child: _colorCard(p))],
                );
              },
            ),
            const _Label('Regras que o motor aplica'),
            for (final (k, t) in const [
              ('um_destaque', 'No máximo 1 elemento em destaque por cena'),
              ('sem_mistura', 'Nunca destaque, apoio e acento juntos na mesma cena'),
              ('sentido', 'Apoio/acento só quando o dado tiver sentido positivo/negativo'),
            ])
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(t),
                value: colorRules[k] == true,
                onChanged: _locked ? null : (v) => setState(() => colorRules[k] = v),
              ),
            Row(
              spacing: 12,
              children: [
                const SizedBox(width: 8),
                const Text('Itens inativos (lista, barras secundárias) em texto a'),
                DropdownButton<double>(
                  value: (colorRules['inativos'] as num).toDouble(),
                  items: [
                    for (final v in const [0.3, 0.4, 0.5, 0.6])
                      DropdownMenuItem(value: v, child: Text('${(v * 100).round()}%')),
                  ],
                  onChanged: _locked ? null : (v) => setState(() => colorRules['inativos'] = v),
                ),
              ],
            ),
          ],
        ),
      ),
      _Panel(
        titulo: 'Fontes',
        acao: OutlinedButton(onPressed: _sendSource, child: const Text('Enviar fonte')),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Row(
              spacing: 16,
              children: [
                SizedBox(width: 150, child: _Label('Papel')),
                SizedBox(width: 230, child: _Label('Fonte')),
                Expanded(child: _Label('Amostra')),
                SizedBox(width: 90, child: _Label('Tamanho')),
              ],
            ),
            for (final MapEntry(key: k, value: label) in _sourceRoles.entries) _sourceLine(k, label),
            const SizedBox(height: 6),
            Text('Tamanhos em px para 1080p. O 9:16 usa a mesma escala relativa à largura.', style: tema.textTheme.bodySmall),
          ],
        ),
      ),
      LayoutBuilder(
        builder: (context, c) {
          final tom = _Panel(
            titulo: 'Tom e voz',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _Label('Descrição que a IA lê'),
                TextField(
                  controller: _guide,
                  minLines: 4,
                  maxLines: 10,
                  enabled: !_locked,
                  decoration: const InputDecoration(border: OutlineInputBorder()),
                ),
                const _Label('Bloquear na legenda e nos títulos'),
                _chipsEditable(_e!['bloquear'] as List, 'Palavra ou expressão', titulo: 'Bloquear'),
                if ((_e!['exemplos'] as List).isNotEmpty) ...[
                  const _Label('Exemplos aprovados'),
                  for (final x in _e!['exemplos'] as List)
                    Text('"${x['frase']}" → ${_pieceNames['${x['cena']}'] ?? x['cena']}', style: tema.textTheme.bodySmall),
                ],
              ],
            ),
          );
          final mov = _motion();
          return c.maxWidth < 900
              ? Column(spacing: 16, children: [tom, mov])
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 16,
                  children: [
                    Expanded(child: tom),
                    Expanded(child: mov),
                  ],
                );
        },
      ),
      _visual(),
      ..._blocksReferences(context),
    ];
    final g = _triggers.where((x) => x['id'] == _previewTrigger).firstOrNull ?? _triggers.firstOrNull;
    final right = <Widget>[
      _Panel(
        titulo: 'Prévia ao vivo',
        acao: PopupMenuButton<String>(
          tooltip: 'Gatilho da prévia',
          itemBuilder: (_) => [
            for (final x in _triggers)
              if ('${x['peca']}'.isNotEmpty) PopupMenuItem(value: '${x['id']}', child: Text('${x['nome']}')),
          ],
          onSelected: (v) => setState(() => _previewTrigger = v),
          child: _pill(context, '${g?['nome'] ?? '—'} ▾'),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            _preview('${g?['peca'] ?? ''}', layout: _layoutOf(g), color: '${g?['cor'] ?? 'destaque'}'),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 12,
              children: [
                SizedBox(
                  width: 110,
                  child: _preview('${g?['peca'] ?? ''}', layout: _layoutOf(g), format: '9:16', color: '${g?['cor'] ?? 'destaque'}'),
                ),
                Expanded(child: _check()),
              ],
            ),
          ],
        ),
      ),
      _styleState(),
    ];
    return LayoutBuilder(
      builder: (context, c) => c.maxWidth < 1100
          ? _Page(children: [...right, ...esquerda])
          : _Page(
              largura: 1500,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 16,
                  children: [
                    Expanded(flex: 7, child: Column(spacing: 16, children: esquerda)),
                    Expanded(flex: 3, child: Column(spacing: 16, children: right)),
                  ],
                ),
              ],
            ),
    );
  }

  Widget _captionTab(BuildContext context) {
    final controls = _Block(
      icone: Icons.closed_caption_outlined,
      titulo: 'Legenda',
      child: Column(
        children: [
          for (final f in ['16:9', '9:16'])
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Legenda no $f'),
              value: (_rules['legenda'] as Json)[f] == true,
              onChanged: _locked ? null : (v) => setState(() => (_rules['legenda'] as Json)[f] = v),
            ),
          _Slider(
            'Tamanho',
            (_caption['tamanho'] as num).toDouble(),
            (v) => setState(() => _caption['tamanho'] = v),
            active: !_locked,
            min: 0.6,
            max: 1.8,
            fmt: (v) => '${(v * 100).round()}%',
          ),
          _Options(
            'Posição',
            _caption,
            'posicao',
            const {'baixo': 'Embaixo', 'meio': 'Meio', 'rosto': 'Abaixo do rosto'},
            active: !_locked,
            mudou: () => setState(() {}),
          ),
          _Options(
            'Palavras por vez',
            _caption,
            'palavras',
            const {1: '1', 2: '2', 3: '3'},
            active: !_locked,
            mudou: () => setState(() {}),
          ),
          _Options(
            'Letras',
            _caption,
            'caixa',
            const {'normal': 'Normal', 'alta': 'CAIXA ALTA'},
            active: !_locked,
            mudou: () => setState(() {}),
          ),
          _Options(
            'Acabamento',
            _caption,
            'acabamento',
            const {'sombra': 'Sombra', 'contorno': 'Contorno', 'caixa': 'Fundo'},
            active: !_locked,
            mudou: () => setState(() {}),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Números e palavras-chave na cor de destaque'),
            value: _caption['destaque_chave'] == true,
            onChanged: _locked ? null : (v) => setState(() => _caption['destaque_chave'] = v),
          ),
        ],
      ),
    );
    final preview = _Block(
      icone: Icons.play_circle_outline,
      titulo: 'Prévia',
      child: _PreviewCaption(
        caption: _caption,
        on: _rules['legenda'] as Json,
        paleta: _palette,
        source: '${_skin['fonte_legenda'] ?? _skin['fonte_destaque']}',
      ),
    );
    return LayoutBuilder(
      builder: (context, c) => c.maxWidth < 900
          ? Column(spacing: 16, children: [preview, controls])
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 16,
              children: [
                Expanded(flex: 5, child: controls),
                Expanded(flex: 4, child: preview),
              ],
            ),
    );
  }

  Widget _intensidade(BuildContext context) => Column(
    spacing: 16,
    children: [
      _Block(
        icone: Icons.tune,
        titulo: 'Intensidade',
        subtitulo: 'Cada eixo puxa os números de um nível pronto.',
        child: Column(
          children: [
            for (final MapEntry(key: axis, value: label) in _axes.entries)
              _Options(
                label,
                _levels,
                axis,
                {
                  'baixa': 'Baixa',
                  'media': 'Média',
                  'alta': 'Alta',
                  if (_levels[axis] == 'personalizado') 'personalizado': 'Personalizado',
                },
                active: !_locked,
                mudou: () => _level(axis, '${_levels[axis]}'),
              ),
          ],
        ),
      ),
      _Block(
        icone: Icons.science_outlined,
        titulo: 'Avançado (ajuste fino)',
        subtitulo: 'Mexer aqui deixa o eixo como "personalizado".',
        child: Column(
          children: [
            _Slider(
              'Tempo máximo em cenas só de motion',
              (_rules['takeover_max'] as num).toDouble(),
              (v) => _thin('motion', () => _rules['takeover_max'] = v),
              active: !_locked,
            ),
            _Slider(
              'Algo novo a cada (s)',
              (_rules['trecho_max_s'] as num).toDouble(),
              (v) => _thin('motion', () => _rules['trecho_max_s'] = v),
              active: !_locked,
              min: 2,
              max: 10,
              fmt: (v) => '${v.toStringAsFixed(1)} s',
            ),
            _Slider(
              'Volume dos efeitos sonoros',
              (_rules['sfx_volume'] as num).toDouble(),
              (v) => _thin('sfx', () => _rules['sfx_volume'] = v),
              active: !_locked,
            ),
            _Slider(
              'Efeitos sonoros por segundo (teto)',
              (_rules['sfx_por_s'] as num).toDouble(),
              (v) => _thin('sfx', () => _rules['sfx_por_s'] = v),
              active: !_locked,
              min: 0.1,
              max: 2,
              fmt: (v) => v.toStringAsFixed(2),
            ),
            for (final MapEntry(key: k, value: label) in const {
              'flash': 'Flash',
              'zoom': 'Zoom e movimento',
              'brilho': 'Brilho',
              'grade': 'Grade do fundo',
            }.entries)
              _Slider(
                label,
                ((_rules['efeitos'] as Json)[k] as num).toDouble(),
                (v) => _thin('efeitos', () => (_rules['efeitos'] as Json)[k] = v),
                active: !_locked,
                max: 2,
                fmt: (v) => v == 0 ? 'desligado' : '${(v * 100).round()}%',
              ),
          ],
        ),
      ),
    ],
  );

  /// Kit variations (style data): the code alternates the entries along the video; no generated code.
  Widget _visual() {
    final v = _rules['visual'] as Json;
    final inputs = [for (final e in v['entradas'] as List) '$e'];
    return _Block(
      icone: Icons.animation,
      titulo: 'Visual das cenas',
      subtitulo: 'Variações do kit para este canal. As entradas marcadas se alternam de cena em cena.',
      child: Column(
        children: [
          Wrap(
            spacing: 8,
            children: [
              for (final MapEntry(:key, :value) in const {
                'desfoque': 'Desfoque',
                'deslizar': 'Deslizar',
                'revelar': 'Revelar',
                'escala': 'Escala',
              }.entries)
                FilterChip(
                  label: Text(value),
                  selected: inputs.contains(key),
                  onSelected: _locked
                      ? null
                      : (sel) => setState(() {
                          if (sel) {
                            inputs.add(key);
                          } else if (inputs.length > 1) {
                            inputs.remove(key);
                          }
                          v['entradas'] = inputs;
                        }),
                ),
            ],
          ),
          _Options(
            'Fundo das cenas de motion',
            v,
            'fundo',
            const {'veu': 'Véu sobre a mídia', 'solido': 'Sólido', 'gradiente': 'Gradiente'},
            active: !_locked,
            mudou: () => setState(() {}),
          ),
          _Options(
            'Alinhamento',
            v,
            'alinhamento',
            const {'centro': 'Centro', 'esquerda': 'Esquerda'},
            active: !_locked,
            mudou: () => setState(() {}),
          ),
          _Options(
            'Cartões e etiquetas',
            v,
            'cartao',
            const {'vidro': 'Vidro', 'contorno': 'Contorno', 'solido': 'Sólido'},
            active: !_locked,
            mudou: () => setState(() {}),
          ),
          _Slider(
            'Cantos',
            (v['cantos'] as num).toDouble(),
            (x) => setState(() => v['cantos'] = x),
            active: !_locked,
            min: 0,
            max: 3,
            fmt: (x) => x == 0 ? 'retos' : '${(x * 100).round()}%',
          ),
        ],
      ),
    );
  }

  static const _tabSpecs = [
    (Icons.palette_outlined, 'Identidade'),
    (Icons.view_quilt_outlined, 'Layouts e modos'),
    (Icons.bolt_outlined, 'Gatilhos'),
    (Icons.animation, 'Peças'),
    (Icons.fact_check_outlined, 'Testar com roteiro'),
  ];

  @override
  Widget build(BuildContext context) {
    final e = _e;
    final estreita = MediaQuery.sizeOf(context).width < 900;
    final siblings = _siblings;
    return DefaultTabController(
      length: _tabSpecs.length,
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 68,
          title: e == null
              ? Text(widget.id)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${e['nome']}'),
                    Text(
                      'v${e['versao']} publicada · '
                      '${e['travado'] == true ? 'travado' : 'editando rascunho v${(e['versao'] as num) + 1}'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
          actions: [
            if (e != null && siblings.length > 1 && !estreita)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: [
                    for (final t in siblings)
                      ButtonSegment(value: '${t['id']}', label: Text('${t['modo']}' == 'apresentador' ? 'Apresentador' : '${t['nome']}')),
                  ],
                  selected: {widget.id},
                  onSelectionChanged: (s) => s.first == widget.id ? null : _openSibling(s.first),
                ),
              ),
            if (e != null && !estreita)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: OutlinedButton(onPressed: () => _tabs.animateTo(4), child: const Text('Testar com roteiro')),
              ),
            if (e != null)
              IconButton(tooltip: 'Duplicar (novo template)', icon: const Icon(Icons.copy), onPressed: _duplicate),
            if (e != null)
              IconButton(
                tooltip: e['travado'] == true ? 'Destravar' : 'Travar (aprovado)',
                icon: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  transitionBuilder: (c, a) => RotationTransition(turns: a, child: c),
                  child: Icon(e['travado'] == true ? Icons.lock : Icons.lock_open, key: ValueKey(e['travado'])),
                ),
                onPressed: () async {
                  await widget.api.lockStyle(widget.id, e['travado'] != true);
                  await _load();
                },
              ),
            if (e != null && e['travado'] != true)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: estreita
                    ? IconButton.filled(tooltip: 'Publicar', onPressed: _save, icon: const Icon(Icons.publish))
                    : FilledButton(onPressed: _save, child: Text('Publicar v${(e['versao'] as num) + 1}')),
              ),
          ],
          bottom: e == null
              ? null
              : TabBar(
                  controller: _tabs,
                  isScrollable: estreita,
                  tabAlignment: estreita ? TabAlignment.start : TabAlignment.fill,
                  tabs: [
                    for (final (icone, label) in _tabSpecs)
                      estreita
                          ? Tab(icon: Icon(icone), text: label)
                          : Tab(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                spacing: 8,
                                children: [Icon(icone, size: 20), Text(label)],
                              ),
                            ),
                  ],
                ),
        ),
        body: e == null
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  AnimatedSize(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOutCubic,
                    child: _locked
                        ? MaterialBanner(
                            leading: const Icon(Icons.lock),
                            content: const Text('Estilo travado: é o aprovado para produção. Destrave para mudar.'),
                            actions: [
                              TextButton(
                                onPressed: () async {
                                  await widget.api.lockStyle(widget.id, false);
                                  await _load();
                                },
                                child: const Text('Destravar'),
                              ),
                            ],
                          )
                        : const SizedBox(width: double.infinity),
                  ),
                  Expanded(
                    child: TabBarView(
                      controller: _tabs,
                      physics: const NeverScrollableScrollPhysics(),
                      children: [
                        _identity(context),
                        _layoutsTab(context),
                        _triggersTab(context),
                        _piecesTab(context),
                        _testTab(context),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Content of a tab: centered with a max width and blocks entering in sequence.
class _Page extends StatelessWidget {
  const _Page({required this.children, this.largura = 960});

  final List<Widget> children;
  final double largura;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
    children: [
      Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: largura),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 16,
            children: [
              for (final (i, c) in children.indexed)
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: Duration(milliseconds: 280 + 80 * i),
                  curve: Curves.easeOutCubic,
                  builder: (_, t, child) => Opacity(
                    opacity: t,
                    child: Transform.translate(offset: Offset(0, 24 * (1 - t)), child: child),
                  ),
                  child: c,
                ),
            ],
          ),
        ),
      ),
    ],
  );
}

class _Block extends StatelessWidget {
  const _Block({required this.icone, required this.titulo, required this.child, this.subtitulo});

  final IconData icone;
  final String titulo;
  final String? subtitulo;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            Row(
              spacing: 12,
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: tema.colorScheme.primaryContainer,
                  child: Icon(icone, size: 20, color: tema.colorScheme.onPrimaryContainer),
                ),
                Expanded(child: Text(titulo, style: tema.textTheme.titleMedium)),
              ],
            ),
            if (subtitulo != null) Text(subtitulo!, style: tema.textTheme.bodySmall),
            child,
          ],
        ),
      ),
    );
  }
}

/// Fake video frame with the caption as it will come out: font, size, position, box, finish and highlight;
/// the words advance at the "palavras por vez" pace.
class _PreviewCaption extends StatefulWidget {
  const _PreviewCaption({required this.caption, required this.on, required this.paleta, required this.source});

  final Json caption;
  final Json on;
  final Map<String, Color> paleta;
  final String source;

  @override
  State<_PreviewCaption> createState() => _PreviewCaptionState();
}

class _PreviewCaptionState extends State<_PreviewCaption> {
  static const _sentence = 'A taxa do cheque especial chegou a 132% ao ano';
  String _format = '16:9';
  int _start = 0;
  Timer? _rhythm;

  @override
  void initState() {
    super.initState();
    _rhythm = Timer.periodic(const Duration(milliseconds: 900), (_) {
      final words = (widget.caption['palavras'] as num?)?.toInt() ?? 1;
      final total = _sentence.split(' ').length;
      setState(() => _start = _start + words >= total ? 0 : _start + words);
    });
  }

  @override
  void dispose() {
    _rhythm?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.caption;
    final p = widget.paleta;
    final words = (l['palavras'] as num?)?.toInt() ?? 1;
    final span = _sentence.split(' ').skip(_start).take(words).toList();
    final alta = l['caixa'] == 'alta';
    final acabamento = '${l['acabamento']}';
    final on = widget.on[_format] == true;
    final vertical = _format == '9:16';
    final alignment = switch (l['posicao']) {
      'meio' => Alignment.center,
      'rosto' => const Alignment(0, 0.3),
      _ => const Alignment(0, 0.82),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        Center(
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: '16:9', icon: Icon(Icons.crop_landscape), label: Text('16:9')),
              ButtonSegment(value: '9:16', icon: Icon(Icons.crop_portrait), label: Text('9:16')),
            ],
            selected: {_format},
            onSelectionChanged: (s) => setState(() => _format = s.first),
          ),
        ),
        Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeInOutCubic,
            constraints: BoxConstraints(maxWidth: vertical ? 260 : 640),
            child: AspectRatio(
              aspectRatio: vertical ? 9 / 16 : 16 / 9,
              child: LayoutBuilder(
                builder: (context, c) {
                  final tamanho = c.maxWidth * (vertical ? 0.085 : 0.05) * ((l['tamanho'] as num?)?.toDouble() ?? 1);
                  final estilo = TextStyle(
                    fontFamily: 'Estudio-${widget.source}',
                    fontSize: tamanho,
                    fontWeight: FontWeight.w800,
                    color: p['texto'],
                    shadows: switch (acabamento) {
                      'sombra' => const [Shadow(blurRadius: 8, offset: Offset(0, 3), color: Colors.black87)],
                      'contorno' => [
                        for (final (dx, dy) in const [(-1.5, -1.5), (1.5, -1.5), (-1.5, 1.5), (1.5, 1.5)])
                          Shadow(offset: Offset(dx, dy), color: Colors.black),
                      ],
                      _ => null,
                    },
                  );
                  final texto = Text.rich(
                    TextSpan(
                      children: [
                        for (final (i, w) in span.indexed)
                          TextSpan(
                            text: '${i > 0 ? ' ' : ''}${alta ? w.toUpperCase() : w}',
                            style: l['destaque_chave'] == true && w.contains(RegExp(r'\d'))
                                ? TextStyle(color: p['destaque'])
                                : null,
                          ),
                      ],
                    ),
                    key: ValueKey(_start),
                    textAlign: TextAlign.center,
                    style: estilo,
                  );
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 400),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [p['fundo']!, p['fundo2']!],
                        ),
                      ),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Align(
                            alignment: const Alignment(0, -0.25),
                            child: Icon(
                              Icons.person,
                              size: c.maxHeight * 0.45,
                              color: p['apoio']?.withValues(alpha: 0.6),
                            ),
                          ),
                          AnimatedOpacity(
                            duration: const Duration(milliseconds: 300),
                            opacity: on ? 1 : 0.15,
                            child: AnimatedAlign(
                              duration: const Duration(milliseconds: 450),
                              curve: Curves.easeOutBack,
                              alignment: alignment,
                              child: Padding(
                                padding: EdgeInsets.symmetric(horizontal: c.maxWidth * 0.06),
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 220),
                                  transitionBuilder: (child, a) => ScaleTransition(
                                    scale: Tween(
                                      begin: 0.8,
                                      end: 1.0,
                                    ).animate(CurvedAnimation(parent: a, curve: Curves.easeOutBack)),
                                    child: FadeTransition(opacity: a, child: child),
                                  ),
                                  child: acabamento == 'caixa'
                                      ? Container(
                                          key: ValueKey(_start),
                                          padding: EdgeInsets.symmetric(
                                            horizontal: tamanho * 0.4,
                                            vertical: tamanho * 0.15,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.black.withValues(alpha: 0.75),
                                            borderRadius: BorderRadius.circular(tamanho * 0.25),
                                          ),
                                          child: texto,
                                        )
                                      : texto,
                                ),
                              ),
                            ),
                          ),
                          if (!on)
                            const Center(
                              child: Chip(
                                avatar: Icon(Icons.subtitles_off_outlined),
                                label: Text('Legenda desligada neste formato'),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Slider extends StatelessWidget {
  const _Slider(this.label, this.valor, this.mudou, {required this.active, this.min = 0, this.max = 1, this.fmt});

  final String label;
  final double valor;
  final ValueChanged<double> mudou;
  final bool active;
  final double min, max;
  final String Function(double)? fmt;

  @override
  Widget build(BuildContext context) {
    final texto = fmt?.call(valor) ?? '${(valor * 100).round()}%';
    final slider = Slider(
      value: valor.clamp(min, max),
      min: min,
      max: max,
      divisions: 20,
      label: texto,
      onChanged: active ? mudou : null,
    );
    final textValue = Text(texto, style: Theme.of(context).textTheme.labelLarge);
    return LayoutBuilder(
      builder: (context, c) => c.maxWidth < 520
          ? Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(label)),
                      textValue,
                    ],
                  ),
                  slider,
                ],
              ),
            )
          : Row(
              children: [
                Expanded(flex: 2, child: Text(label)),
                Expanded(flex: 3, child: slider),
                SizedBox(width: 80, child: textValue),
              ],
            ),
    );
  }
}

/// Choice among a few options saved in `dados[chave]`.
class _Options<T extends Object> extends StatelessWidget {
  const _Options(this.label, this.dados, this.chave, this.options, {required this.active, required this.mudou});

  final String label;
  final Json dados;
  final String chave;
  final Map<T, String> options;
  final bool active;
  final VoidCallback mudou;

  @override
  Widget build(BuildContext context) {
    final buttons = SegmentedButton<T>(
      showSelectedIcon: false,
      segments: [for (final MapEntry(:key, :value) in options.entries) ButtonSegment(value: key, label: Text(value))],
      selected: {if (options.containsKey(dados[chave])) dados[chave] as T},
      emptySelectionAllowed: true,
      onSelectionChanged: active
          ? (s) {
              if (s.isEmpty) return;
              dados[chave] = s.first;
              mudou();
            }
          : null,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: LayoutBuilder(
        builder: (context, c) => c.maxWidth < 520
            ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 6, children: [Text(label), buttons])
            : Row(
                children: [
                  Expanded(child: Text(label)),
                  buttons,
                ],
              ),
      ),
    );
  }
}
