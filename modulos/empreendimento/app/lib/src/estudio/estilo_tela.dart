import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_esteira.dart';
import '../modelos.dart';
import '../telas/util.dart';
import 'estudio_aba.dart' show cor;
import 'previa_peca.dart';

part 'estilo_abas.dart';

/// Estilo (Fluxo A) = template do canal, em 5 abas: Identidade (cores, regras de cor, fontes, tom, movimento),
/// Layouts e modos, Gatilhos (o que dito vira cena: layout + peça + cor), Peças (ajuste de cada peça do kit) e Testar
/// com roteiro (decupagem sem IA nem render). "Propor com o Claude" analisa as referências e reescreve o estilo (uma
/// vez); travado, só muda destravando. "Publicar" grava a versão nova; "Duplicar" cria um template novo.
class EstiloTela extends StatefulWidget {
  const EstiloTela({super.key, required this.api, required this.id});

  final ApiEsteira api;
  final String id;

  @override
  State<EstiloTela> createState() => _EstiloTelaState();
}

class _EstiloTelaState extends State<EstiloTela> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: _abas.length, vsync: this);
  // estilos irmãos do canal (Apresentador · Dark) e o 1º de outro modo, para comparar
  List<Json> _irmaos = [];
  Json? _irmao;
  String _gatilhoSel = 'porcentagem';
  String _busca = '';
  String _pecaSel = 'anel_percentual';
  String _formatoPeca = '16:9';
  String _layoutSel = 'split';
  String _previaGatilho = 'porcentagem';
  Json? _teste;
  String _testeEp = '';
  String _testeTexto = '';
  int _testeCena = 0;
  String _testeFormato = '16:9';
  final Set<int> _avisosIgnorados = {};
  Future<List<dynamic>>? _eps;

  static const _entradas = {
    'fade_deslize': 'Fade + deslize',
    'fade': 'Fade',
    'escala': 'Escala',
    'revelar': 'Revelar',
    'mascara': 'Máscara',
    'desfoque': 'Desfoque',
  };
  static const _curvas = {
    'suave': 'Ease-out suave',
    'firme': 'Ease-out firme',
    'elastica': 'Elástica',
    'linear': 'Linear',
  };
  static const _saidas = {'fade': 'Fade', 'deslize': 'Deslize', 'desfoque': 'Desfoque', 'corte': 'Corte seco'};
  static const _descCor = {
    'fundo': 'Fundo das peças',
    'fundo2': 'Cards, caixas, barras vazias',
    'texto': 'Texto comum',
    'destaque': 'Só números, palavra-chave, passo atual',
    'apoio': 'Ganho, positivo, faça isso',
    'acento': 'Dívida, perda, evite isso',
  };

  void _mudar(VoidCallback f) => setState(f);

  void _abrirIrmao(String id) => Navigator.of(
    context,
  ).pushReplacement(MaterialPageRoute<void>(builder: (_) => EstiloTela(api: widget.api, id: id)));

  Json? _e;
  List<String> _refs = [];
  final _guia = TextEditingController();
  final _nicho = TextEditingController();
  final Map<String, TextEditingController> _cores = {};

  static const _papeis = ['fundo', 'fundo2', 'texto', 'destaque', 'apoio', 'acento'];
  static const _papeisFonte = {
    'fonte_destaque': 'Títulos e números',
    'fonte_texto': 'Texto',
    'fonte_tecnica': 'Rótulos',
    'fonte_legenda': 'Legenda',
    'fonte_editorial': 'Capítulos e citações',
  };
  static const _eixos = {'sfx': 'Efeitos sonoros', 'motion': 'Motion graphics', 'efeitos': 'Efeitos visuais'};
  List<Json> _fontes = [];
  Json _tabela = {};
  static final Set<String> _carregadas = {};

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _guia.dispose();
    _nicho.dispose();
    for (final c in _cores.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _carregar() async {
    final d = await widget.api.estilo(widget.id);
    if (_fontes.isEmpty) {
      _fontes = [for (final f in await widget.api.fontesEstudio()) f as Json];
      _tabela = await widget.api.niveisEstudio();
      _carregarFontes();
    }
    final e = d['estilo'] as Json;
    // esteira ainda sem os campos novos (servidor não reiniciado): completa com os padrões para a tela não quebrar
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
      for (final g in (_tabela['gatilhos_padrao'] as List?) ?? const []) Json.from(g as Json),
    ];
    e['pecas'] ??= <String, dynamic>{};
    if (_irmaos.isEmpty) {
      try {
        _irmaos = [for (final t in await widget.api.templates('${e['canal']}')) t as Json];
        final outro = _irmaos.where((t) => t['id'] != e['id'] && t['modo'] != e['modo']).firstOrNull;
        if (outro != null) _irmao = (await widget.api.estilo('${outro['id']}'))['estilo'] as Json;
      } catch (_) {}
    }
    if (!mounted) return;
    final pele = e['pele'] as Json;
    setState(() {
      _e = e;
      _refs = [for (final r in d['referencias'] as List) '$r'];
      _guia.text = '${e['guia']}';
      for (final p in _papeis) {
        (_cores[p] ??= TextEditingController()).text = '${pele[p]}';
      }
    });
  }

  Json get _regras => _e!['regras'] as Json;
  Json get _pele => _e!['pele'] as Json;
  Json get _legenda => _regras['legenda_visual'] as Json;
  Json get _niveis => _regras['niveis'] as Json;
  bool get _travado => _e!['travado'] == true;

  /// Prévia: cada fonte do catálogo é registrada no app como `Estudio-<nome>`.
  Future<void> _carregarFontes() async {
    for (final f in _fontes) {
      final nome = '${f['nome']}';
      if (_carregadas.contains(nome)) continue;
      try {
        final bytes = await widget.api.arquivoFonte('${(f['arquivos'] as List).first}');
        await (FontLoader('Estudio-$nome')..addFont(Future.value(ByteData.sublistView(bytes)))).load();
        _carregadas.add(nome);
        if (mounted) setState(() {});
      } catch (_) {}
    }
  }

  /// Nível escolhido: preenche os números da tabela (o servidor faz o mesmo ao salvar).
  void _nivel(String eixo, String nivel) => setState(() {
    _niveis[eixo] = nivel;
    final valores = ((_tabela['niveis'] as Json?)?[eixo] as Json?)?[nivel] as Json?;
    valores?.forEach((k, v) => _regras[k] = v is Map ? Json.from(v) : v);
  });

  /// Ajuste fino: o eixo passa a "personalizado" (o nível não sobrescreve mais os números).
  void _fino(String eixo, VoidCallback mudar) => setState(() {
    mudar();
    _niveis[eixo] = 'personalizado';
  });

  Future<void> _enviarFonte() async {
    final arquivos = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['ttf', 'otf']);
    if (arquivos.isEmpty || !mounted) return;
    await acaoComAviso(context, () async {
      for (final a in arquivos) {
        await widget.api.enviarFonte(a.name, await a.xFile.readAsBytes());
      }
      _fontes = [for (final f in await widget.api.fontesEstudio()) f as Json];
      await _carregarFontes();
      return '${arquivos.length} fonte(s) enviada(s)';
    });
    if (mounted) setState(() {});
  }

  Future<void> _duplicar() async {
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
    await acaoComAviso(context, () async {
      final novo = await widget.api.duplicarEstilo(widget.id, id.text.trim(), nome.text.trim());
      nav.pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => EstiloTela(api: widget.api, id: '${novo['id']}'),
        ),
      );
      return 'Estilo ${novo['id']} criado';
    });
  }

  /// Cada salvamento vira uma versão nova (as anteriores ficam guardadas); o nome da versão é opcional.
  Future<void> _salvar() async {
    final rotulo = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Salvar como v${(_e!['versao'] as num) + 1}'),
        content: TextField(
          controller: rotulo,
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
    final nomeVersao = rotulo.text.trim();
    rotulo.dispose();
    if (ok != true || !mounted) return;
    final e = Json.from(_e!);
    e['rotulo'] = nomeVersao;
    e['guia'] = _guia.text;
    e['pele'] = {...(e['pele'] as Json), for (final p in _papeis) p: _cores[p]!.text.trim()};
    await acaoComAviso(context, () async {
      final novo = await widget.api.salvarEstilo(widget.id, e);
      return 'Estilo salvo (v${novo['versao']})';
    });
    await _carregar();
  }

  Future<void> _enviarRefs() async {
    final arquivos = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
    );
    if (arquivos.isEmpty || !mounted) return;
    await acaoComAviso(context, () async {
      for (final a in arquivos) {
        await widget.api.enviarReferencia(widget.id, a.name, await a.xFile.readAsBytes());
      }
      return '${arquivos.length} referência(s) enviada(s)';
    });
    await _carregar();
  }

  Map<String, Color> get _paleta => {for (final p in _papeis) p: cor(_cores[p]?.text)};

  List<Widget> _blocosReferencias(BuildContext context) => [
      _Bloco(
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
                  await widget.api.apagarReferencia(widget.id, r);
                  await _carregar();
                },
              ),
            ActionChip(
              avatar: const Icon(Icons.upload),
              label: const Text('Enviar referências'),
              onPressed: _enviarRefs,
            ),
          ],
        ),
      ),
      _Bloco(
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
                controller: _nicho,
                decoration: const InputDecoration(
                  labelText: 'Nicho, público e tom (opcional)',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.auto_awesome),
              label: const Text('Propor com o Claude'),
              onPressed: () => acaoComAviso(context, () async {
                await widget.api.proporEstilo(widget.id, _nicho.text);
                return 'Na fila (pista do Claude). Acompanhe em Fila; ao terminar, reabra o estilo.';
              }),
            ),
          ],
        ),
      ),
  ];

  // ───────────────────────── Identidade ─────────────────────────

  static const _amostras = {
    'fonte_destaque': '81,7% ENDIVIDADAS',
    'fonte_texto': 'Das famílias brasileiras',
    'fonte_tecnica': 'CNC · 2026',
    'fonte_legenda': 'Você já ouviu ESSE número?',
    'fonte_editorial': 'O cartão de crédito',
  };

  Widget _cartaoCor(String p) {
    final tema = Theme.of(context);
    final c = _paleta[p]!;
    final destaque = p == 'destaque';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: destaque ? c : tema.colorScheme.outlineVariant, width: destaque ? 1.5 : 1),
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
                  controller: _cores[p],
                  enabled: !_travado,
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(fontFamily: 'monospace'),
                  decoration: const InputDecoration(isDense: true, border: InputBorder.none),
                ),
                Text(_descCor[p] ?? '', style: tema.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _linhaFonte(String papel, String rotulo) {
    final atual = '${_pele[papel] ?? _pele['fonte_destaque']}';
    final nomes = [for (final f in _fontes) '${f['nome']}'];
    final fora = nomes.isNotEmpty && !nomes.contains(atual);
    final tam = ((_e!['tamanhos'] as Json)[papel] as List?) ?? const [];
    final dest = _paleta['destaque']!;
    final amostra = _amostras[papel]!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        spacing: 16,
        children: [
          SizedBox(width: 150, child: Text(rotulo)),
          SizedBox(
            width: 230,
            child: DropdownButtonFormField<String>(
              initialValue: fora ? null : atual,
              isExpanded: true,
              hint: Text('$atual (fora do catálogo)'),
              decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
              items: [
                for (final f in _fontes)
                  DropdownMenuItem(
                    value: '${f['nome']}',
                    child: Text('${f['nome']}', style: TextStyle(fontFamily: 'Estudio-${f['nome']}')),
                  ),
              ],
              onChanged: _travado ? null : (v) => setState(() => _pele[papel] = v),
            ),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  for (final (i, parte) in amostra.split(RegExp(r'(?=ESSE)|(?<=ESSE)|(?=81,7%)|(?<=81,7%)')).indexed)
                    TextSpan(
                      text: parte,
                      style: TextStyle(color: parte == 'ESSE' || (parte == '81,7%' && i == 0) ? dest : null),
                    ),
                ],
              ),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Estudio-$atual',
                fontSize: papel == 'fonte_destaque' ? 26 : 20,
                fontWeight: papel == 'fonte_legenda' ? FontWeight.w800 : FontWeight.w500,
              ),
            ),
          ),
          SizedBox(
            width: 90,
            child: TextFormField(
              key: ValueKey('tam$papel${_e!['versao']}'),
              initialValue: tam.length == 2 ? '${tam[0]}–${tam[1]}' : '',
              enabled: !_travado,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
              onChanged: (v) {
                final n = RegExp(r'\d+').allMatches(v).map((m) => int.parse(m[0]!)).toList();
                if (n.length == 2) (_e!['tamanhos'] as Json)[papel] = n;
              },
            ),
          ),
        ],
      ),
    );
  }

  static double _contraste(Color a, Color b) {
    final la = a.computeLuminance(), lb = b.computeLuminance();
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  Widget _checagem() {
    final p = _paleta;
    final itens = <(int, String)>[];
    for (final (papel, nome) in const [('texto', 'Texto'), ('destaque', 'Destaque'), ('apoio', 'Apoio'), ('acento', 'Acento')]) {
      final r = _contraste(p[papel]!, p['fundo']!);
      final txt = '$nome sobre fundo: ${r.toStringAsFixed(1).replaceAll('.', ',')}:1';
      itens.add(r >= 4.5 ? (0, txt) : (r >= 3 ? (1, '$txt, só em números grandes') : (2, '$txt, ilegível')));
    }
    final nomes = {for (final f in _fontes) '${f['nome']}'};
    final fora = [for (final k in _papeisFonte.keys) if (nomes.isNotEmpty && !nomes.contains(_pele[k])) '${_pele[k]}'];
    itens.add(fora.isEmpty ? (0, 'Todas as fontes no catálogo') : (1, 'Fora do catálogo: ${fora.join(', ')}'));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        const _Rotulo('Checagem automática'),
        for (final (n, t) in itens)
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

  Widget _estadoEstilo() {
    final g = _gatilhos;
    final ativos = g.where((x) => x['ativo'] != false).length;
    final teste = _teste;
    final linhas = [
      ('Identidade', _checagemOk ? 'completo' : 'revisar', _checagemOk ? Colors.green : Colors.amber),
      ('Layouts', '${_layoutsModo[_modo]!.length} de ${_layoutsModo[_modo]!.length}', null),
      ('Gatilhos', '$ativos de ${g.length}', ativos < g.length ? Colors.amber : null),
      ('Peças', '${((_regras['filtro'] as List?) ?? const []).length} fora do canal', null),
      (
        'Último teste',
        teste == null
            ? '—'
            : '${_testeEp.isEmpty ? 'trecho colado' : _testeEp} · ${(teste['avisos'] as List).length - _avisosIgnorados.length} avisos',
        null,
      ),
    ];
    return _Painel(
      titulo: 'Estado do estilo',
      child: Column(
        spacing: 6,
        children: [
          for (final (k, v, c) in linhas)
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

  bool get _checagemOk =>
      _papeis.every((p) => RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(_cores[p]?.text.trim() ?? '')) &&
      _contraste(_paleta['texto']!, _paleta['fundo']!) >= 4.5;

  Widget _dropMov(String rotulo, List<(String, String)> opcoes, String atual, ValueChanged<String> mudou) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _Rotulo(rotulo),
      DropdownButtonFormField<String>(
        initialValue: opcoes.any((o) => o.$1 == atual) ? atual : opcoes.first.$1,
        isExpanded: true,
        decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
        items: [for (final (v, t) in opcoes) DropdownMenuItem(value: v, child: Text(t))],
        onChanged: _travado ? null : (v) => setState(() => mudou(v!)),
      ),
    ],
  );

  Widget _movimento() {
    final m = _e!['movimento'] as Json;
    final proib = m['proibidos'] as List;
    String fmtN(num v) => v.toString().replaceAll('.', ',');
    final ritmos = [
      for (final r in const [[1.5, 3.0], [2.0, 4.0], [3.0, 5.0], [4.0, 7.0]])
        ('${r[0]}-${r[1]}', 'Muda a cada ${fmtN(r[0])}–${fmtN(r[1])} s'),
    ];
    final r = m['ritmo'] as List;
    return _Painel(
      titulo: 'Movimento',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            spacing: 12,
            children: [
              Expanded(
                child: _dropMov('Curva', [for (final e in _curvas.entries) (e.key, e.value)], '${m['curva']}', (v) => m['curva'] = v),
              ),
              Expanded(
                child: _dropMov(
                  'Ritmo',
                  ritmos,
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
                    for (final e in _entradas.entries)
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
                    for (final e in _saidas.entries)
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
          const _Rotulo('Proibidos'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final x in ((_tabela['proibiveis'] as List?) ?? proib))
                FilterChip(
                  label: Text('$x'),
                  selected: proib.contains(x),
                  onSelected: _travado ? null : (s) => setState(() => s ? proib.add(x) : proib.remove(x)),
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

  Widget _identidade(BuildContext context) {
    final tema = Theme.of(context);
    final regrasCor = _e!['regras_cor'] as Json;
    final irmaosTxt = [for (final t in _irmaos) '${t['nome']}'].join(' e ');
    final esquerda = <Widget>[
      if (_irmaos.length > 1)
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: tema.colorScheme.outlineVariant),
          ),
          child: Row(
            spacing: 10,
            children: [
              _selo(context, 'Base do canal', cor: tema.colorScheme.primary),
              Expanded(
                child: Text(
                  'Cores, fontes, tom e movimento valem para este estilo; $irmaosTxt são do mesmo canal '
                  '(edite cada um, ou duplique para manter igual).',
                  style: tema.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      _Painel(
        titulo: 'Cores',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              builder: (context, c) {
                final colunas = (c.maxWidth / 260).floor().clamp(1, 3);
                final largura = (c.maxWidth - 12 * (colunas - 1)) / colunas;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [for (final p in _papeis) SizedBox(width: largura, child: _cartaoCor(p))],
                );
              },
            ),
            const _Rotulo('Regras que o motor aplica'),
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
                value: regrasCor[k] == true,
                onChanged: _travado ? null : (v) => setState(() => regrasCor[k] = v),
              ),
            Row(
              spacing: 12,
              children: [
                const SizedBox(width: 8),
                const Text('Itens inativos (lista, barras secundárias) em texto a'),
                DropdownButton<double>(
                  value: (regrasCor['inativos'] as num).toDouble(),
                  items: [
                    for (final v in const [0.3, 0.4, 0.5, 0.6])
                      DropdownMenuItem(value: v, child: Text('${(v * 100).round()}%')),
                  ],
                  onChanged: _travado ? null : (v) => setState(() => regrasCor['inativos'] = v),
                ),
              ],
            ),
          ],
        ),
      ),
      _Painel(
        titulo: 'Fontes',
        acao: OutlinedButton(onPressed: _enviarFonte, child: const Text('Enviar fonte')),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Row(
              spacing: 16,
              children: [
                SizedBox(width: 150, child: _Rotulo('Papel')),
                SizedBox(width: 230, child: _Rotulo('Fonte')),
                Expanded(child: _Rotulo('Amostra')),
                SizedBox(width: 90, child: _Rotulo('Tamanho')),
              ],
            ),
            for (final MapEntry(key: k, value: rotulo) in _papeisFonte.entries) _linhaFonte(k, rotulo),
            const SizedBox(height: 6),
            Text('Tamanhos em px para 1080p. O 9:16 usa a mesma escala relativa à largura.', style: tema.textTheme.bodySmall),
          ],
        ),
      ),
      LayoutBuilder(
        builder: (context, c) {
          final tom = _Painel(
            titulo: 'Tom e voz',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _Rotulo('Descrição que a IA lê'),
                TextField(
                  controller: _guia,
                  minLines: 4,
                  maxLines: 10,
                  enabled: !_travado,
                  decoration: const InputDecoration(border: OutlineInputBorder()),
                ),
                const _Rotulo('Bloquear na legenda e nos títulos'),
                _chipsEditaveis(_e!['bloquear'] as List, 'Palavra ou expressão', titulo: 'Bloquear'),
                if ((_e!['exemplos'] as List).isNotEmpty) ...[
                  const _Rotulo('Exemplos aprovados'),
                  for (final x in _e!['exemplos'] as List)
                    Text('"${x['frase']}" → ${_pecasNome['${x['cena']}'] ?? x['cena']}', style: tema.textTheme.bodySmall),
                ],
              ],
            ),
          );
          final mov = _movimento();
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
      ..._blocosReferencias(context),
    ];
    final g = _gatilhos.where((x) => x['id'] == _previaGatilho).firstOrNull ?? _gatilhos.firstOrNull;
    final direita = <Widget>[
      _Painel(
        titulo: 'Prévia ao vivo',
        acao: PopupMenuButton<String>(
          tooltip: 'Gatilho da prévia',
          itemBuilder: (_) => [
            for (final x in _gatilhos)
              if ('${x['peca']}'.isNotEmpty) PopupMenuItem(value: '${x['id']}', child: Text('${x['nome']}')),
          ],
          onSelected: (v) => setState(() => _previaGatilho = v),
          child: _selo(context, '${g?['nome'] ?? '—'} ▾'),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            _previa('${g?['peca'] ?? ''}', layout: _layoutDe(g), cor: '${g?['cor'] ?? 'destaque'}'),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 12,
              children: [
                SizedBox(
                  width: 110,
                  child: _previa('${g?['peca'] ?? ''}', layout: _layoutDe(g), formato: '9:16', cor: '${g?['cor'] ?? 'destaque'}'),
                ),
                Expanded(child: _checagem()),
              ],
            ),
          ],
        ),
      ),
      _estadoEstilo(),
    ];
    return LayoutBuilder(
      builder: (context, c) => c.maxWidth < 1100
          ? _Pagina(children: [...direita, ...esquerda])
          : _Pagina(
              largura: 1500,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 16,
                  children: [
                    Expanded(flex: 7, child: Column(spacing: 16, children: esquerda)),
                    Expanded(flex: 3, child: Column(spacing: 16, children: direita)),
                  ],
                ),
              ],
            ),
    );
  }

  Widget _legendaAba(BuildContext context) {
    final controles = _Bloco(
      icone: Icons.closed_caption_outlined,
      titulo: 'Legenda',
      child: Column(
        children: [
          for (final f in ['16:9', '9:16'])
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Legenda no $f'),
              value: (_regras['legenda'] as Json)[f] == true,
              onChanged: _travado ? null : (v) => setState(() => (_regras['legenda'] as Json)[f] = v),
            ),
          _Deslizante(
            'Tamanho',
            (_legenda['tamanho'] as num).toDouble(),
            (v) => setState(() => _legenda['tamanho'] = v),
            ativo: !_travado,
            min: 0.6,
            max: 1.8,
            fmt: (v) => '${(v * 100).round()}%',
          ),
          _Opcoes(
            'Posição',
            _legenda,
            'posicao',
            const {'baixo': 'Embaixo', 'meio': 'Meio', 'rosto': 'Abaixo do rosto'},
            ativo: !_travado,
            mudou: () => setState(() {}),
          ),
          _Opcoes(
            'Palavras por vez',
            _legenda,
            'palavras',
            const {1: '1', 2: '2', 3: '3'},
            ativo: !_travado,
            mudou: () => setState(() {}),
          ),
          _Opcoes(
            'Letras',
            _legenda,
            'caixa',
            const {'normal': 'Normal', 'alta': 'CAIXA ALTA'},
            ativo: !_travado,
            mudou: () => setState(() {}),
          ),
          _Opcoes(
            'Acabamento',
            _legenda,
            'acabamento',
            const {'sombra': 'Sombra', 'contorno': 'Contorno', 'caixa': 'Fundo'},
            ativo: !_travado,
            mudou: () => setState(() {}),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Números e palavras-chave na cor de destaque'),
            value: _legenda['destaque_chave'] == true,
            onChanged: _travado ? null : (v) => setState(() => _legenda['destaque_chave'] = v),
          ),
        ],
      ),
    );
    final previa = _Bloco(
      icone: Icons.play_circle_outline,
      titulo: 'Prévia',
      child: _PreviaLegenda(
        legenda: _legenda,
        ligada: _regras['legenda'] as Json,
        paleta: _paleta,
        fonte: '${_pele['fonte_legenda'] ?? _pele['fonte_destaque']}',
      ),
    );
    return LayoutBuilder(
      builder: (context, c) => c.maxWidth < 900
          ? Column(spacing: 16, children: [previa, controles])
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 16,
              children: [
                Expanded(flex: 5, child: controles),
                Expanded(flex: 4, child: previa),
              ],
            ),
    );
  }

  Widget _intensidade(BuildContext context) => Column(
    spacing: 16,
    children: [
      _Bloco(
        icone: Icons.tune,
        titulo: 'Intensidade',
        subtitulo: 'Cada eixo puxa os números de um nível pronto.',
        child: Column(
          children: [
            for (final MapEntry(key: eixo, value: rotulo) in _eixos.entries)
              _Opcoes(
                rotulo,
                _niveis,
                eixo,
                {
                  'baixa': 'Baixa',
                  'media': 'Média',
                  'alta': 'Alta',
                  if (_niveis[eixo] == 'personalizado') 'personalizado': 'Personalizado',
                },
                ativo: !_travado,
                mudou: () => _nivel(eixo, '${_niveis[eixo]}'),
              ),
          ],
        ),
      ),
      _Bloco(
        icone: Icons.science_outlined,
        titulo: 'Avançado (ajuste fino)',
        subtitulo: 'Mexer aqui deixa o eixo como "personalizado".',
        child: Column(
          children: [
            _Deslizante(
              'Tempo máximo em cenas só de motion',
              (_regras['takeover_max'] as num).toDouble(),
              (v) => _fino('motion', () => _regras['takeover_max'] = v),
              ativo: !_travado,
            ),
            _Deslizante(
              'Algo novo a cada (s)',
              (_regras['trecho_max_s'] as num).toDouble(),
              (v) => _fino('motion', () => _regras['trecho_max_s'] = v),
              ativo: !_travado,
              min: 2,
              max: 10,
              fmt: (v) => '${v.toStringAsFixed(1)} s',
            ),
            _Deslizante(
              'Volume dos efeitos sonoros',
              (_regras['sfx_volume'] as num).toDouble(),
              (v) => _fino('sfx', () => _regras['sfx_volume'] = v),
              ativo: !_travado,
            ),
            _Deslizante(
              'Efeitos sonoros por segundo (teto)',
              (_regras['sfx_por_s'] as num).toDouble(),
              (v) => _fino('sfx', () => _regras['sfx_por_s'] = v),
              ativo: !_travado,
              min: 0.1,
              max: 2,
              fmt: (v) => v.toStringAsFixed(2),
            ),
            for (final MapEntry(key: k, value: rotulo) in const {
              'flash': 'Flash',
              'zoom': 'Zoom e movimento',
              'brilho': 'Brilho',
              'grade': 'Grade do fundo',
            }.entries)
              _Deslizante(
                rotulo,
                ((_regras['efeitos'] as Json)[k] as num).toDouble(),
                (v) => _fino('efeitos', () => (_regras['efeitos'] as Json)[k] = v),
                ativo: !_travado,
                max: 2,
                fmt: (v) => v == 0 ? 'desligado' : '${(v * 100).round()}%',
              ),
          ],
        ),
      ),
    ],
  );

  /// Variações do kit (dado do estilo): o código alterna as entradas ao longo do vídeo; nada de código gerado.
  Widget _visual() {
    final v = _regras['visual'] as Json;
    final entradas = [for (final e in v['entradas'] as List) '$e'];
    return _Bloco(
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
                  selected: entradas.contains(key),
                  onSelected: _travado
                      ? null
                      : (sel) => setState(() {
                          if (sel) {
                            entradas.add(key);
                          } else if (entradas.length > 1) {
                            entradas.remove(key);
                          }
                          v['entradas'] = entradas;
                        }),
                ),
            ],
          ),
          _Opcoes(
            'Fundo das cenas de motion',
            v,
            'fundo',
            const {'veu': 'Véu sobre a mídia', 'solido': 'Sólido', 'gradiente': 'Gradiente'},
            ativo: !_travado,
            mudou: () => setState(() {}),
          ),
          _Opcoes(
            'Alinhamento',
            v,
            'alinhamento',
            const {'centro': 'Centro', 'esquerda': 'Esquerda'},
            ativo: !_travado,
            mudou: () => setState(() {}),
          ),
          _Opcoes(
            'Cartões e etiquetas',
            v,
            'cartao',
            const {'vidro': 'Vidro', 'contorno': 'Contorno', 'solido': 'Sólido'},
            ativo: !_travado,
            mudou: () => setState(() {}),
          ),
          _Deslizante(
            'Cantos',
            (v['cantos'] as num).toDouble(),
            (x) => setState(() => v['cantos'] = x),
            ativo: !_travado,
            min: 0,
            max: 3,
            fmt: (x) => x == 0 ? 'retos' : '${(x * 100).round()}%',
          ),
        ],
      ),
    );
  }

  static const _abas = [
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
    final irmaos = _irmaos;
    return DefaultTabController(
      length: _abas.length,
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
            if (e != null && irmaos.length > 1 && !estreita)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: [
                    for (final t in irmaos)
                      ButtonSegment(value: '${t['id']}', label: Text('${t['modo']}' == 'apresentador' ? 'Apresentador' : '${t['nome']}')),
                  ],
                  selected: {widget.id},
                  onSelectionChanged: (s) => s.first == widget.id ? null : _abrirIrmao(s.first),
                ),
              ),
            if (e != null && !estreita)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: OutlinedButton(onPressed: () => _tabs.animateTo(4), child: const Text('Testar com roteiro')),
              ),
            if (e != null)
              IconButton(tooltip: 'Duplicar (novo template)', icon: const Icon(Icons.copy), onPressed: _duplicar),
            if (e != null)
              IconButton(
                tooltip: e['travado'] == true ? 'Destravar' : 'Travar (aprovado)',
                icon: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  transitionBuilder: (c, a) => RotationTransition(turns: a, child: c),
                  child: Icon(e['travado'] == true ? Icons.lock : Icons.lock_open, key: ValueKey(e['travado'])),
                ),
                onPressed: () async {
                  await widget.api.travarEstilo(widget.id, e['travado'] != true);
                  await _carregar();
                },
              ),
            if (e != null && e['travado'] != true)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: estreita
                    ? IconButton.filled(tooltip: 'Publicar', onPressed: _salvar, icon: const Icon(Icons.publish))
                    : FilledButton(onPressed: _salvar, child: Text('Publicar v${(e['versao'] as num) + 1}')),
              ),
          ],
          bottom: e == null
              ? null
              : TabBar(
                  controller: _tabs,
                  isScrollable: estreita,
                  tabAlignment: estreita ? TabAlignment.start : TabAlignment.fill,
                  tabs: [
                    for (final (icone, rotulo) in _abas)
                      estreita
                          ? Tab(icon: Icon(icone), text: rotulo)
                          : Tab(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                spacing: 8,
                                children: [Icon(icone, size: 20), Text(rotulo)],
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
                    child: _travado
                        ? MaterialBanner(
                            leading: const Icon(Icons.lock),
                            content: const Text('Estilo travado: é o aprovado para produção. Destrave para mudar.'),
                            actions: [
                              TextButton(
                                onPressed: () async {
                                  await widget.api.travarEstilo(widget.id, false);
                                  await _carregar();
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
                        _identidade(context),
                        _layoutsAba(context),
                        _gatilhosAba(context),
                        _pecasAba(context),
                        _testarAba(context),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Conteúdo de uma aba: centralizado com largura máxima e blocos entrando em sequência.
class _Pagina extends StatelessWidget {
  const _Pagina({required this.children, this.largura = 960});

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
                  builder: (_, t, filho) => Opacity(
                    opacity: t,
                    child: Transform.translate(offset: Offset(0, 24 * (1 - t)), child: filho),
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

class _Bloco extends StatelessWidget {
  const _Bloco({required this.icone, required this.titulo, required this.child, this.subtitulo});

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

/// Quadro de vídeo fictício com a legenda como vai sair: fonte, tamanho, posição, caixa, acabamento e destaque;
/// as palavras avançam no ritmo de "palavras por vez".
class _PreviaLegenda extends StatefulWidget {
  const _PreviaLegenda({required this.legenda, required this.ligada, required this.paleta, required this.fonte});

  final Json legenda;
  final Json ligada;
  final Map<String, Color> paleta;
  final String fonte;

  @override
  State<_PreviaLegenda> createState() => _PreviaLegendaState();
}

class _PreviaLegendaState extends State<_PreviaLegenda> {
  static const _frase = 'A taxa do cheque especial chegou a 132% ao ano';
  String _formato = '16:9';
  int _inicio = 0;
  Timer? _ritmo;

  @override
  void initState() {
    super.initState();
    _ritmo = Timer.periodic(const Duration(milliseconds: 900), (_) {
      final palavras = (widget.legenda['palavras'] as num?)?.toInt() ?? 1;
      final total = _frase.split(' ').length;
      setState(() => _inicio = _inicio + palavras >= total ? 0 : _inicio + palavras);
    });
  }

  @override
  void dispose() {
    _ritmo?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.legenda;
    final p = widget.paleta;
    final palavras = (l['palavras'] as num?)?.toInt() ?? 1;
    final trecho = _frase.split(' ').skip(_inicio).take(palavras).toList();
    final alta = l['caixa'] == 'alta';
    final acabamento = '${l['acabamento']}';
    final ligada = widget.ligada[_formato] == true;
    final vertical = _formato == '9:16';
    final alinhamento = switch (l['posicao']) {
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
            selected: {_formato},
            onSelectionChanged: (s) => setState(() => _formato = s.first),
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
                    fontFamily: 'Estudio-${widget.fonte}',
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
                        for (final (i, w) in trecho.indexed)
                          TextSpan(
                            text: '${i > 0 ? ' ' : ''}${alta ? w.toUpperCase() : w}',
                            style: l['destaque_chave'] == true && w.contains(RegExp(r'\d'))
                                ? TextStyle(color: p['destaque'])
                                : null,
                          ),
                      ],
                    ),
                    key: ValueKey(_inicio),
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
                            opacity: ligada ? 1 : 0.15,
                            child: AnimatedAlign(
                              duration: const Duration(milliseconds: 450),
                              curve: Curves.easeOutBack,
                              alignment: alinhamento,
                              child: Padding(
                                padding: EdgeInsets.symmetric(horizontal: c.maxWidth * 0.06),
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 220),
                                  transitionBuilder: (filho, a) => ScaleTransition(
                                    scale: Tween(
                                      begin: 0.8,
                                      end: 1.0,
                                    ).animate(CurvedAnimation(parent: a, curve: Curves.easeOutBack)),
                                    child: FadeTransition(opacity: a, child: filho),
                                  ),
                                  child: acabamento == 'caixa'
                                      ? Container(
                                          key: ValueKey(_inicio),
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
                          if (!ligada)
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

class _Deslizante extends StatelessWidget {
  const _Deslizante(this.rotulo, this.valor, this.mudou, {required this.ativo, this.min = 0, this.max = 1, this.fmt});

  final String rotulo;
  final double valor;
  final ValueChanged<double> mudou;
  final bool ativo;
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
      onChanged: ativo ? mudou : null,
    );
    final valorTexto = Text(texto, style: Theme.of(context).textTheme.labelLarge);
    return LayoutBuilder(
      builder: (context, c) => c.maxWidth < 520
          ? Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(rotulo)),
                      valorTexto,
                    ],
                  ),
                  slider,
                ],
              ),
            )
          : Row(
              children: [
                Expanded(flex: 2, child: Text(rotulo)),
                Expanded(flex: 3, child: slider),
                SizedBox(width: 80, child: valorTexto),
              ],
            ),
    );
  }
}

/// Escolha entre poucas opções gravada em `dados[chave]`.
class _Opcoes<T extends Object> extends StatelessWidget {
  const _Opcoes(this.rotulo, this.dados, this.chave, this.opcoes, {required this.ativo, required this.mudou});

  final String rotulo;
  final Json dados;
  final String chave;
  final Map<T, String> opcoes;
  final bool ativo;
  final VoidCallback mudou;

  @override
  Widget build(BuildContext context) {
    final botoes = SegmentedButton<T>(
      showSelectedIcon: false,
      segments: [for (final MapEntry(:key, :value) in opcoes.entries) ButtonSegment(value: key, label: Text(value))],
      selected: {if (opcoes.containsKey(dados[chave])) dados[chave] as T},
      emptySelectionAllowed: true,
      onSelectionChanged: ativo
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
            ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 6, children: [Text(rotulo), botoes])
            : Row(
                children: [
                  Expanded(child: Text(rotulo)),
                  botoes,
                ],
              ),
      ),
    );
  }
}
