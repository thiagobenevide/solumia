part of 'style_screen.dart';

// Layouts and modes, Triggers, Pieces and Test with a script tabs (Studio wireframes). Everything edits the style JSON
// in memory (`_e`); "Publicar" saves the new version.

const _layoutNames = {
  'camera': 'Câmera cheia',
  'split': 'Split',
  'peca': 'Peça cheia',
  'capitulo': 'Capítulo',
  'tipografia': 'Tipografia cinética',
  'broll': 'B-roll',
  'midia_overlay': 'Mídia + overlay',
  'lateral': 'Dados ao lado (transparente)',
  'flutuante': 'Card flutuante (vidro)',
  'solido': 'Card sobre fundo sólido',
  'galeria': 'Galeria de mídias',
};
const _layoutsDesc = {
  'camera': 'Impacto, pergunta · punch-in',
  'split': 'Número, lista, versus · padrão',
  'peca': 'Gráficos grandes · máx. 6 s',
  'capitulo': 'Cartela · 2–3 s',
  'tipografia': 'Impacto, pergunta',
  'broll': 'Dia a dia · máx. 4 s',
  'midia_overlay': 'Overlay 60%',
  'lateral': 'Sobre a imagem · lado oposto ao rosto',
  'flutuante': 'Vidro em perspectiva sobre a imagem',
  'solido': 'Fundo na cor do estilo · sem a imagem',
  'galeria': 'Cards com as mídias em volta do rosto',
};
const _layoutsMode = {
  'apresentador': ['camera', 'split', 'lateral', 'flutuante', 'solido', 'galeria', 'peca', 'capitulo', 'broll'],
  'dark': ['peca', 'lateral', 'flutuante', 'solido', 'galeria', 'tipografia', 'midia_overlay', 'broll', 'capitulo'],
};
const _pieceNames = {
  'contador': 'Número herói',
  'anel_percentual': 'Anel de %',
  'grade_proporcao': 'Grade 10 × 10',
  'versus': 'Versus',
  'barras_comparacao': 'Barras',
  'grafico_linha': 'Linha no tempo',
  'equacao': 'Equação',
  'lista_itens': 'Lista',
  'passo_a_passo': 'Etapas',
  'citacao_estudo': 'Card de estudo',
  'titulo_capitulo': 'Capítulo',
  'linha_do_tempo': 'Marcos no tempo',
  'ranking': 'Ranking',
  'termo_tecnico': 'Termo técnico',
  'alerta': 'Alerta / dica',
  'lettering': 'Tipografia cinética',
  'frase_destaque': 'Frase de impacto',
  'pergunta_destaque': 'Pergunta',
  'conceito_icone': 'Conceito + ícone',
  'cta': 'Chamada (CTA)',
  'riscado': 'Riscado',
  'carimbo': 'Carimbo',
};
const _groupNames = {'credibilidade': 'Credibilidade e dados', 'estrutura': 'Estrutura', 'tom': 'Tom'};
const _layers = {
  'anel_percentual': [('Valor', 'da fala'), ('Anel', '= valor'), ('Contexto', 'da fala'), ('Rótulo fonte', 'opcional')],
  'grade_proporcao': [('Valor', 'da fala'), ('Grade 10 × 10', '= valor'), ('Contexto', 'da fala')],
  'contador': [('Valor', 'da fala'), ('Rótulo', 'da fala'), ('Traço', ''), ('Fonte', 'opcional')],
  'equacao': [('Termos', 'da fala'), ('Operador', 'da frase'), ('Resultado', 'da fala')],
  'grafico_linha': [('Pontos', 'da fala'), ('Linha', '= pontos'), ('Último valor', 'conta')],
  'ranking': [('Itens', 'da fala'), ('Barras', '= valores'), ('Posição', 'ordem')],
  'termo_tecnico': [('Termo', 'da fala'), ('Definição', 'da IA'), ('Traço', '')],
  'alerta': [('Ícone', 'pela frase'), ('Frase', 'da fala')],
  'lettering': [('Linhas', 'da fala'), ('Marca-texto', 'palavra-chave')],
  'citacao_estudo': [('Fonte e ano', 'da fala'), ('Título', 'da fala'), ('Selo', 'link na descrição')],
};

String _mmss(num t) => '${(t ~/ 60).toString().padLeft(2, '0')}:${(t.toInt() % 60).toString().padLeft(2, '0')}';

/// Section label in uppercase, spaced (as in the wireframes).
class _Label extends StatelessWidget {
  const _Label(this.texto);
  final String texto;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 6),
    child: Text(
      texto.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(letterSpacing: 1.4, fontWeight: FontWeight.w700),
    ),
  );
}

/// Panel with a title (outlined card).
class _Panel extends StatelessWidget {
  const _Panel({required this.titulo, required this.child, this.pill, this.acao});
  final String titulo;
  final Widget? pill;
  final Widget? acao;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card.outlined(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          Row(
            spacing: 10,
            children: [
              Flexible(child: Text(titulo, style: Theme.of(context).textTheme.titleMedium)),
              ?pill,
              const Spacer(),
              ?acao,
            ],
          ),
          child,
        ],
      ),
    ),
  );
}

Widget _pill(BuildContext context, String texto, {Color? color}) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
  decoration: BoxDecoration(
    borderRadius: BorderRadius.circular(99),
    border: Border.all(color: color ?? Theme.of(context).colorScheme.outline),
  ),
  child: Text(texto, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color)),
);

/// Three columns on desktop; stacks on a narrow screen.
Widget _columns(List<(int, Widget)> cols, {double minimum = 1100}) => LayoutBuilder(
  builder: (context, c) => c.maxWidth < minimum
      ? ListView(
          padding: const EdgeInsets.all(16),
          children: [
            for (final (_, w) in cols) Padding(padding: const EdgeInsets.only(bottom: 16), child: w),
          ],
        )
      : Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 16,
            children: [
              for (final (flex, w) in cols) Expanded(flex: flex, child: SingleChildScrollView(child: w)),
            ],
          ),
        ),
);

extension _Tabs on _StyleScreenState {
  Json get _layouts => _e!['layouts'] as Json;
  Json get _presence => _e!['presenca'] as Json;
  Json get _pieces => _e!['pecas'] as Json;
  List<Json> get _triggers => [for (final g in _e!['gatilhos'] as List) g as Json];
  String get _mode => '${_e!['modo']}' == 'apresentador' ? 'apresentador' : 'dark';
  Map<String, String> get _families => {
    for (final p in _StyleScreenState._sourceRoles.keys) p: 'Estudio-${_skin[p] ?? _skin['fonte_destaque']}',
  };
  Json? get _currentTrigger => _triggers.where((g) => g['id'] == _selTrigger).firstOrNull ?? _triggers.firstOrNull;

  /// A layout requested in the dark style has no camera: it becomes a full piece.
  String _layoutOf(Json? g) {
    final l = '${g?['layout'] ?? 'split'}';
    if (_mode == 'dark' && (l == 'camera' || l == 'split')) return g?['peca'] == '' ? 'broll' : 'peca';
    return l;
  }

  Widget _preview(String piece, {String? layout, String format = '16:9', String color = 'destaque', String caption = ''}) =>
      PiecePreview(
        piece: piece,
        paleta: _palette,
        sources: _families,
        layout: layout ?? (_mode == 'apresentador' ? 'split' : 'peca'),
        format: format,
        color: color,
        sidePresenter: '${_layouts['split_lado']}',
        largura: (_layouts['split_largura'] as num).toDouble(),
        caption: caption,
      );

  // ───────────────────────── Layouts e modos ─────────────────────────

  Widget _miniLayout(String l, {bool selecionado = false, VoidCallback? toque, bool reading = false}) {
    final cores = Theme.of(context).colorScheme;
    return SizedBox(
      width: 168,
      child: Card.outlined(
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: selecionado ? cores.primary : cores.outlineVariant, width: selecionado ? 2 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: toque,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 6,
              children: [
                IgnorePointer(
                  child: PiecePreview(
                    piece: l == 'capitulo' ? 'titulo_capitulo' : (l == 'tipografia' ? 'lettering' : (l == 'camera' ? '' : 'contador')),
                    paleta: _palette,
                    sources: _families,
                    layout: l == 'tipografia' || l == 'capitulo' ? 'peca' : l,
                    largura: (_layouts['split_largura'] as num).toDouble(),
                    sidePresenter: '${_layouts['split_lado']}',
                    playing: false,
                  ),
                ),
                Text(_layoutNames[l] ?? l, style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(_layoutsDesc[l] ?? '', style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _numField(Json dados, String chave, String suffix, {int? index}) {
    final valor = index == null ? dados[chave] : (dados[chave] as List)[index];
    return Row(
      spacing: 8,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 72,
          child: TextFormField(
            key: ValueKey('$chave$index${_e!['versao']}'),
            initialValue: '$valor',
            enabled: !_locked,
            decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
            onChanged: (v) {
              final n = double.tryParse(v.replaceAll(',', '.'));
              if (n == null) return;
              if (index == null) {
                dados[chave] = n;
              } else {
                (dados[chave] as List)[index] = n;
              }
            },
          ),
        ),
        Text(suffix),
      ],
    );
  }

  Widget _layoutsTab(BuildContext context) {
    final list = _layoutsMode[_mode]!;
    final sibling = _sibling;
    final splitPanel = _Panel(
      titulo: _layoutNames[_layoutSel] ?? _layoutSel,
      pill: _pill(context, 'usado por ${_triggers.where((g) => _layoutOf(g) == _layoutSel).length} gatilhos'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          const _Label('16:9'),
          _preview('anel_percentual', layout: _layoutSel == 'tipografia' ? 'peca' : _layoutSel),
          if (const {'lateral', 'flutuante', 'solido', 'galeria'}.contains(_layoutSel)) ...[
            _Options(
              'Lado dos dados',
              _layouts..putIfAbsent('lado_dados', () => 'auto'),
              'lado_dados',
              const {'auto': 'Auto (oposto ao rosto)', 'esquerda': 'Esquerda', 'direita': 'Direita'},
              active: !_locked,
              mudou: () => _change(() {}),
            ),
          ],
          TextFormField(
            key: ValueKey('selo-${_layouts['selo']}-$_locked'),
            initialValue: '${_layouts['selo'] ?? ''}',
            enabled: !_locked,
            maxLength: 40,
            decoration: const InputDecoration(
              labelText: 'Selo de progresso no canto (vazio = sem selo)',
              hintText: 'ex.: A IA EDITANDO',
            ),
            onFieldSubmitted: (v) => _change(() => _layouts['selo'] = v.trim()),
          ),
          if (_layoutSel == 'split') ...[
            _Options(
              'Lado do apresentador',
              _layouts,
              'split_lado',
              const {'esquerda': 'Esquerda', 'direita': 'Direita'},
              active: !_locked,
              mudou: () => _change(() {}),
            ),
            _Slider(
              'Largura do apresentador',
              (_layouts['split_largura'] as num).toDouble(),
              (v) => _change(() => _layouts['split_largura'] = v),
              active: !_locked,
              min: 0.25,
              max: 0.6,
            ),
            _Options(
              'Entrada do painel',
              _layouts,
              'painel_entrada',
              const {'desliza': 'Desliza', 'fade': 'Fade', 'corte': 'Corte'},
              active: !_locked,
              mudou: () => _change(() {}),
            ),
            _Slider(
              'Área segura',
              (_layouts['area_segura'] as num).toDouble(),
              (v) => _change(() => _layouts['area_segura'] = v),
              active: !_locked,
              max: 0.15,
            ),
            const _Label('9:16 · como o split se adapta'),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 16,
              children: [
                SizedBox(width: 120, child: _preview('anel_percentual', layout: 'split', format: '9:16')),
                Expanded(
                  child: Column(
                    children: [
                      _Options(
                        'Peça',
                        _layouts,
                        'vertical_peca',
                        const {'cima': 'Em cima', 'baixo': 'Embaixo'},
                        active: !_locked,
                        mudou: () => _change(() {}),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Reservar 20% inferiores (UI do app)'),
                        value: _layouts['reservar_inferior'] == true,
                        onChanged: _locked ? null : (v) => _change(() => _layouts['reservar_inferior'] = v),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Legenda no terço central'),
                        value: _layouts['legenda_terco'] == true,
                        onChanged: _locked ? null : (v) => _change(() => _layouts['legenda_terco'] = v),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ] else if (_layoutSel == 'peca')
            _lineField('Peça cheia no máximo', _numField(_layouts, 'peca_cheia_max_s', 's'))
          else if (_layoutSel == 'capitulo')
            _lineField(
              'Cartela de capítulo',
              Row(
                children: [
                  _numField(_layouts, 'capitulo_s', '–', index: 0),
                  _numField(_layouts, 'capitulo_s', 's', index: 1),
                ],
              ),
            )
          else if (_layoutSel == 'broll' || _layoutSel == 'midia_overlay')
            _lineField('Mídia no máximo', _numField(_layouts, 'broll_max_s', 's'))
          else
            Text(
              _layoutSel == 'camera'
                  ? 'Punch-in base e de impacto ficam em Identidade → Intensidade.'
                  : 'Tipografia cinética usa a fonte de títulos e a curva do Movimento.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
    final esquerda = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 16,
      children: [
        _Panel(
          titulo: 'Layouts deste estilo',
          pill: _pill(context, 'modo $_mode'),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final l in list)
                _miniLayout(l, selecionado: l == _layoutSel, toque: () => _change(() => _layoutSel = l)),
            ],
          ),
        ),
        if (sibling != null)
          _Panel(
            titulo: 'Layouts de ${sibling['nome']}',
            pill: _pill(context, 'só leitura aqui'),
            acao: OutlinedButton(onPressed: () => _openSibling('${sibling['id']}'), child: const Text('Abrir estilo')),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 10,
              children: [
                Text(
                  'Mostrado lado a lado para comparar: o ${sibling['modo']} troca o apresentador por tipografia cinética e '
                  'mídia com overlay.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final l in _layoutsMode['${sibling['modo']}' == 'apresentador' ? 'apresentador' : 'dark']!)
                      _miniLayout(l, reading: true),
                  ],
                ),
              ],
            ),
          ),
        _Panel(
          titulo: 'Regras de presença e ritmo',
          child: Wrap(
            spacing: 32,
            runSpacing: 12,
            children: [
              _lineField('Apresentador fora da tela', _numField(_presence, 'fora_max_s', 's no máximo')),
              _lineField('Peça parada', _numField(_presence, 'peca_parada_s', 's, depois acrescenta detalhe')),
              _lineField(
                'Mudança na tela',
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _numField(_presence, 'mudanca_s', '–', index: 0),
                    _numField(_presence, 'mudanca_s', 's', index: 1),
                  ],
                ),
              ),
            ],
          ),
        ),
        _captionTab(context),
      ],
    );
    return _columns([(6, esquerda), (4, splitPanel)]);
  }

  Widget _lineField(String label, Widget campo) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [_Label(label), campo],
  );

  // ───────────────────────── Gatilhos ─────────────────────────

  Future<String?> _askText(String titulo, {String dica = ''}) async {
    final c = TextEditingController();
    final r = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(titulo),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: InputDecoration(hintText: dica),
          onSubmitted: (v) => Navigator.pop(d, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('Adicionar')),
        ],
      ),
    );
    c.dispose();
    return (r ?? '').trim().isEmpty ? null : r!.trim();
  }

  Future<void> _newTrigger({Json? base}) async {
    final nome = await _askText(base == null ? 'Novo gatilho' : 'Duplicar gatilho', dica: 'Nome (ex.: Meta financeira)');
    if (nome == null) return;
    var id = nome.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_|_$'), '');
    if (id.length < 2) id = 'gatilho';
    while (_triggers.any((g) => g['id'] == id)) {
      id = '${id}_2';
    }
    _change(() {
      (_e!['gatilhos'] as List).add({
        ...?base?.map((k, v) => MapEntry(k, v is List ? List.of(v) : v)),
        if (base == null) ...{
          'grupo': 'tom',
          'prioridade': 8,
          'ativo': true,
          'padroes': <String>[],
          'exemplos': <String>[],
          'nao_disparar': <String>[],
          'layout': 'split',
          'peca': 'frase_destaque',
          'cor': 'destaque',
          'cor_regras': <Json>[],
        },
        'id': id,
        'nome': nome,
      });
      _selTrigger = id;
    });
  }

  Widget _triggersList(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    final search = _search.toLowerCase();
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              spacing: 8,
              children: [
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: 'Buscar gatilho',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => _change(() => _search = v),
                  ),
                ),
                IconButton.outlined(
                  tooltip: 'Novo gatilho',
                  onPressed: _locked ? null : _newTrigger,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'O número é a prioridade (menor vence; 0 = estrutural, vence todos).',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            for (final MapEntry(key: group, value: groupName) in _groupNames.entries) ...[
              _Label(groupName),
              for (final g in (_triggers.where((g) => g['grupo'] == group && '${g['nome']}'.toLowerCase().contains(search)).toList()
                ..sort((a, b) => (a['prioridade'] as num).compareTo(b['prioridade'] as num))))
                Material(
                  color: g['id'] == _selTrigger ? cores.primaryContainer : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => _change(() => _selTrigger = '${g['id']}'),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                      child: Row(
                        spacing: 12,
                        children: [
                          SizedBox(
                            width: 18,
                            child: Text(
                              g['prioridade'] == 0 ? '–' : '${g['prioridade']}',
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              '${g['nome']}',
                              style: TextStyle(
                                decoration: g['ativo'] == false ? TextDecoration.lineThrough : null,
                              ),
                            ),
                          ),
                          Text(
                            '${g['peca']}'.isEmpty ? 'sem peça' : (_layoutNames[_layoutOf(g)] ?? '').toLowerCase(),
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: '${g['peca']}'.isEmpty ? color(_skin['destaque'] as String?) : null,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _chipsEditable(List list, String dica, {bool mono = false, String titulo = 'Novo padrão'}) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final p in List.of(list))
        InputChip(
          label: Text('$p', style: TextStyle(fontFamily: mono ? 'monospace' : null)),
          onDeleted: _locked ? null : () => _change(() => list.remove(p)),
        ),
      ActionChip(
        avatar: const Icon(Icons.add, size: 16),
        label: const Text('adicionar'),
        onPressed: _locked
            ? null
            : () async {
                final v = await _askText(titulo, dica: dica);
                if (v != null) _change(() => list.add(v));
              },
      ),
    ],
  );

  Widget _triggerEditor(BuildContext context, Json g) {
    final cat = (_table['condicoes'] as Json?) ?? const {};
    final pieces = (_table['pecas'] as Json?) ?? const {};
    final skip = g['nao_disparar'] as List;
    final siblingG = ((_sibling?['gatilhos'] as List?) ?? const []).cast<Json>().where((x) => x['id'] == g['id']).firstOrNull;
    final dest = color(_skin['destaque'] as String?);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 16,
      children: [
        _Panel(
          titulo: '${g['nome']}',
          pill: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 8,
            children: [
              PopupMenuButton<int>(
                enabled: !_locked,
                tooltip: 'Prioridade',
                itemBuilder: (_) => [for (var i = 0; i <= 12; i++) PopupMenuItem(value: i, child: Text('$i'))],
                onSelected: (v) => _change(() => g['prioridade'] = v),
                child: _pill(context, 'prioridade ${g['prioridade']}'),
              ),
              InkWell(
                onTap: _locked ? null : () => _change(() => g['ativo'] = g['ativo'] == false),
                child: _pill(
                  context,
                  g['ativo'] == false ? 'inativo' : 'ativo',
                  color: g['ativo'] == false ? null : Colors.green,
                ),
              ),
            ],
          ),
          acao: OutlinedButton(onPressed: _locked ? null : () => _newTrigger(base: g), child: const Text('Duplicar')),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _Label('Como reconhecer na fala'),
              _chipsEditable(g['padroes'] as List, '{número}% · {n} em cada {m} · segundo {palavra} · re:regex', mono: true),
              const _Label('Exemplos que devem disparar'),
              for (final x in List.of(g['exemplos'] as List))
                Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      Expanded(child: _realce('"$x"', dest)),
                      if (!_locked)
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.close, size: 16),
                          onPressed: () => _change(() => (g['exemplos'] as List).remove(x)),
                        ),
                    ],
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _locked
                      ? null
                      : () async {
                          final v = await _askText('Exemplo que deve disparar', dica: 'Frase como é dita');
                          if (v != null) _change(() => (g['exemplos'] as List).add(v));
                        },
                  icon: const Icon(Icons.add),
                  label: const Text('Exemplo'),
                ),
              ),
              const _Label('Não disparar quando'),
              for (final MapEntry(:key, :value) in cat.entries)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text('$value'),
                  value: skip.contains(key),
                  onChanged: _locked ? null : (v) => _change(() => v == true ? skip.add(key) : skip.remove(key)),
                ),
            ],
          ),
        ),
        _Panel(
          titulo: 'O que vira na tela',
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              Expanded(
                child: Card.outlined(
                  margin: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: Theme.of(context).colorScheme.primary, width: 2),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: 6,
                      children: [
                        _Label('Neste estilo · $_mode'),
                        DropdownButtonFormField<String>(
                          key: ValueKey('lay${g['id']}'),
                          initialValue: '${g['layout']}',
                          decoration: const InputDecoration(labelText: 'Layout', isDense: true, border: OutlineInputBorder()),
                          items: [
                            for (final MapEntry(:key, :value) in _layoutNames.entries)
                              DropdownMenuItem(value: key, child: Text(value)),
                          ],
                          onChanged: _locked ? null : (v) => _change(() => g['layout'] = v),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          spacing: 8,
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                key: ValueKey('peca${g['id']}'),
                                initialValue: '${g['peca']}',
                                isExpanded: true,
                                decoration: const InputDecoration(labelText: 'Peça', isDense: true, border: OutlineInputBorder()),
                                items: [
                                  const DropdownMenuItem(value: '', child: Text('Sem peça')),
                                  for (final p in pieces.keys)
                                    if (p != 'midia') DropdownMenuItem(value: p, child: Text(_pieceNames[p] ?? p)),
                                ],
                                onChanged: _locked ? null : (v) => _change(() => g['peca'] = v ?? ''),
                              ),
                            ),
                            if ('${g['peca']}'.isNotEmpty)
                              TextButton(
                                onPressed: () => _change(() {
                                  _pieceSel = '${g['peca']}';
                                  _tabs.animateTo(3);
                                }),
                                child: const Text('Editar ›'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_sibling != null)
                Expanded(
                  child: Card.outlined(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 4,
                        children: [
                          _Label('Em ${_sibling!['nome']}'),
                          const _Label('Layout'),
                          Text(siblingG == null ? '—' : _layoutNames['${siblingG['layout']}'] ?? '${siblingG['layout']}'),
                          const _Label('Peça'),
                          Text(siblingG == null ? 'sem esse gatilho' : _pieceNames['${siblingG['peca']}'] ?? 'Sem peça'),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        _Panel(
          titulo: 'Cor',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text('Padrão'),
              _colorChip(g, 'cor'),
              for (final r in (g['cor_regras'] as List).cast<Json>()) ...[
                const Text('· se a frase tiver'),
                for (final t in List.of(r['termos'] as List))
                  InputChip(
                    label: Text('$t'),
                    onDeleted: _locked ? null : () => _change(() => (r['termos'] as List).remove(t)),
                  ),
                ActionChip(
                  label: const Icon(Icons.add, size: 16),
                  onPressed: _locked
                      ? null
                      : () async {
                          final v = await _askText('Termo da frase', dica: 'endividad* · queda');
                          if (v != null) _change(() => (r['termos'] as List).add(v));
                        },
                ),
                const Text('usar'),
                _colorChip(r, 'cor'),
              ],
              TextButton.icon(
                onPressed: _locked
                    ? null
                    : () => _change(() => (g['cor_regras'] as List).add({'termos': <String>[], 'cor': 'acento'})),
                icon: const Icon(Icons.add),
                label: const Text('Regra de cor'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Sentence with numbers and quoted spans in the highlight color (what the pattern catches).
  Widget _realce(String s, Color dest) {
    final parts = <TextSpan>[];
    s.splitMapJoin(
      RegExp(r'\d[\d.,]*\s*%?(?:\s+em cada\s+\d+)?'),
      onMatch: (m) {
        parts.add(TextSpan(text: m[0], style: TextStyle(color: dest)));
        return '';
      },
      onNonMatch: (t) {
        parts.add(TextSpan(text: t));
        return '';
      },
    );
    return Text.rich(TextSpan(children: parts));
  }

  Widget _colorChip(Json dados, String chave) {
    final current = '${dados[chave]}';
    return PopupMenuButton<String>(
      enabled: !_locked,
      tooltip: 'Cor',
      itemBuilder: (_) => [
        for (final c in const ['destaque', 'apoio', 'acento'])
          PopupMenuItem(
            value: c,
            child: Row(spacing: 8, children: [CircleAvatar(radius: 6, backgroundColor: _palette[c]), Text(c)]),
          ),
      ],
      onSelected: (v) => _change(() => dados[chave] = v),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: _palette[current] ?? Colors.grey),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 6,
          children: [CircleAvatar(radius: 5, backgroundColor: _palette[current]), Text(current)],
        ),
      ),
    );
  }

  Widget _triggersTab(BuildContext context) {
    final g = _currentTrigger;
    if (g == null) return const Center(child: Text('Sem gatilhos'));
    final example = '${(g['exemplos'] as List).firstOrNull ?? ''}';
    final preview = _Panel(
      titulo: 'Prévia sincronizada',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          _preview('${g['peca']}', layout: _layoutOf(g), color: '${g['cor']}', caption: _layoutOf(g) == 'camera' ? example : ''),
          const _Label('Linha do tempo da fala'),
          _timeline(context, example, [
            ('Layout', 0.0, 1.0, color(_skin['fundo2'] as String?)),
            ('Peça', 0.35, 0.85, _palette['${g['cor']}'] ?? Colors.amber),
            ('Contexto', 0.45, 0.95, Colors.grey),
          ]),
          Text(
            'A peça entra ${-((_pieces['${g['peca']}'] as Json?)?['atraso_q'] ?? -3)} quadros antes da palavra-âncora e a '
            'contagem dura enquanto o número é falado.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
    return _columns([(3, _triggersList(context)), (5, _triggerEditor(context, g)), (4, preview)]);
  }

  /// Simple timelines: speech in words + bars (label, start, end as a fraction, color).
  Widget _timeline(BuildContext context, String speech, List<(String, double, double, Color)> bars) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 6,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(width: 90, child: Text('Fala')),
          Expanded(
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final p in speech.split(' ').take(10))
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: RegExp(r'\d').hasMatch(p)
                          ? color(_skin['destaque'] as String?).withValues(alpha: .2)
                          : Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(p, style: Theme.of(context).textTheme.labelSmall),
                  ),
              ],
            ),
          ),
        ],
      ),
      for (final (rot, de, until, c) in bars)
        Row(
          children: [
            SizedBox(width: 90, child: Text(rot, style: Theme.of(context).textTheme.bodySmall)),
            Expanded(
              child: LayoutBuilder(
                builder: (_, k) => Stack(
                  children: [
                    SizedBox(height: 14, width: k.maxWidth),
                    Positioned(
                      left: k.maxWidth * de,
                      width: k.maxWidth * (until - de),
                      height: 14,
                      child: DecoratedBox(
                        decoration: BoxDecoration(color: c.withValues(alpha: .6), borderRadius: BorderRadius.circular(3)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
    ],
  );

  // ───────────────────────── Pieces ─────────────────────────

  Json _pieceAdjustment(String p) => (_pieces[p] ??= <String, dynamic>{
    'entrada': '',
    'atraso_q': -3,
    'contagem_s': 0.9,
    'curva': '',
    'fonte': 'fonte_destaque',
    'tamanho': 1.0,
    'cor': 'gatilho',
  }) as Json;

  Widget _piecesTab(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    final all = [for (final p in ((_table['pecas'] as Json?) ?? const {}).keys) if (p != 'midia') p];
    // the channel only stores what it does NOT use (filter); the menu is the rest
    final filter = (_rules['filtro'] ??= <dynamic>[]) as List;
    final p = all.contains(_pieceSel) ? _pieceSel : (all.firstOrNull ?? 'contador');
    final aj = _pieceAdjustment(p);
    final used = _triggers.where((g) => g['peca'] == p).toList();
    final band = SizedBox(
      height: 118,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        children: [
          for (final x in all)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: InkWell(
                onTap: () => _change(() => _pieceSel = x),
                child: SizedBox(
                  width: 120,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 4,
                    children: [
                      DecoratedBox(
                        position: DecorationPosition.foreground,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: x == p ? cores.primary : Colors.transparent, width: 2),
                        ),
                        child: IgnorePointer(child: _fixedPreview(x)),
                      ),
                      Text(
                        _pieceNames[x] ?? x,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: !filter.contains(x) ? null : cores.onSurfaceVariant.withValues(alpha: .6),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    final layers = Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Label('Camadas e campos'),
            for (final (i, (nome, origin)) in (_layers[p] ?? const [('Valor', 'da fala'), ('Título', 'da fala')]).indexed)
              ListTile(
                dense: true,
                selected: i == 0,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                leading: Icon(i == 0 ? Icons.diamond_outlined : Icons.layers_outlined, size: 16),
                title: Text(nome),
                trailing: Text(origin, style: Theme.of(context).textTheme.labelSmall),
              ),
            const ListTile(
              dense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 8),
              leading: Icon(Icons.crop_square, size: 16),
              title: Text('Fundo da peça'),
            ),
            const Divider(),
            const _Label('Usada em'),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final g in used)
                  ActionChip(
                    label: Text('${g['nome']} · ${(_layoutNames[_layoutOf(g)] ?? '').toLowerCase()}'),
                    onPressed: () => _change(() {
                      _selTrigger = '${g['id']}';
                      _tabs.animateTo(2);
                    }),
                  ),
                if (used.isEmpty) const Text('nenhum gatilho'),
              ],
            ),
            const SizedBox(height: 10),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('O canal usa esta peça'),
              subtitle: const Text('Desligada, entra no filtro do canal e a IA nunca a escolhe'),
              value: !filter.contains(p),
              onChanged: _locked ? null : (v) => _change(() => v ? filter.remove(p) : filter.add(p)),
            ),
            Text(
              'Campos "da fala" são preenchidos pela IA local a partir do roteiro; ela nunca inventa número.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
    final center = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        Row(
          children: [
            Expanded(child: Text(_pieceNames[p] ?? p, style: Theme.of(context).textTheme.titleLarge)),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [ButtonSegment(value: '16:9', label: Text('16:9')), ButtonSegment(value: '9:16', label: Text('9:16'))],
              selected: {_pieceFormat},
              onSelectionChanged: (s) => _change(() => _pieceFormat = s.first),
            ),
          ],
        ),
        Text('Dado de exemplo: ${pieceExamples[p] ?? ''}', style: Theme.of(context).textTheme.bodySmall),
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: _pieceFormat == '9:16' ? 320 : 900),
            child: _preview(p, format: _pieceFormat),
          ),
        ),
        Card.outlined(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: _timeline(context, 'segundo a CNC, 81,7% das famílias estão endividadas', [
              ('Rótulo fonte', 0.05, 0.3, Colors.grey),
              ('Valor', 0.35 + (aj['atraso_q'] as num) / 100, 0.6 + (aj['contagem_s'] as num) / 10, color(_skin['destaque'] as String?)),
              ('Peça', 0.35, 0.6 + (aj['contagem_s'] as num) / 10, color(_skin['acento'] as String?)),
              ('Contexto', 0.45, 0.75, Colors.blueGrey),
              ('Saída', 0.9, 0.98, Colors.grey),
            ]),
          ),
        ),
      ],
    );
    final props = Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 10,
          children: [
            const _Label('Propriedades'),
            DropdownButtonFormField<String>(
              key: ValueKey('fonte$p'),
              initialValue: '${aj['fonte']}',
              decoration: const InputDecoration(labelText: 'Fonte', isDense: true, border: OutlineInputBorder()),
              items: [
                for (final MapEntry(:key, :value) in _StyleScreenState._sourceRoles.entries)
                  if (key != 'fonte_legenda') DropdownMenuItem(value: key, child: Text(value)),
              ],
              onChanged: _locked ? null : (v) => _change(() => aj['fonte'] = v),
            ),
            _Slider(
              'Tamanho',
              (aj['tamanho'] as num).toDouble(),
              (v) => _change(() => aj['tamanho'] = v),
              active: !_locked,
              min: 0.5,
              max: 2,
            ),
            _Options(
              'Cor',
              aj,
              'cor',
              const {'destaque': 'destaque', 'gatilho': 'regra do gatilho'},
              active: !_locked,
              mudou: () => _change(() {}),
            ),
            Text('Cores vêm da Identidade. Sem hex solto aqui.', style: Theme.of(context).textTheme.bodySmall),
            const Divider(),
            const _Label('Animação'),
            DropdownButtonFormField<String>(
              key: ValueKey('entrada$p'),
              initialValue: '${aj['entrada']}',
              decoration: const InputDecoration(labelText: 'Entrada', isDense: true, border: OutlineInputBorder()),
              items: [
                const DropdownMenuItem(value: '', child: Text('Padrão do estilo')),
                for (final MapEntry(:key, :value) in _StyleScreenState._inputs.entries)
                  DropdownMenuItem(value: key, child: Text(value)),
              ],
              onChanged: _locked ? null : (v) => _change(() => aj['entrada'] = v ?? ''),
            ),
            _Slider(
              'Atraso (quadros)',
              (aj['atraso_q'] as num).toDouble(),
              (v) => _change(() => aj['atraso_q'] = v.round()),
              active: !_locked,
              min: -12,
              max: 12,
              fmt: (v) => '${v.round()} f',
            ),
            _Slider(
              'Contagem',
              (aj['contagem_s'] as num).toDouble(),
              (v) => _change(() => aj['contagem_s'] = double.parse(v.toStringAsFixed(2))),
              active: !_locked,
              min: 0.2,
              max: 3,
              fmt: (v) => '${v.toStringAsFixed(1)} s',
            ),
            DropdownButtonFormField<String>(
              key: ValueKey('curva$p'),
              initialValue: '${aj['curva']}',
              decoration: const InputDecoration(labelText: 'Curva', isDense: true, border: OutlineInputBorder()),
              items: [
                const DropdownMenuItem(value: '', child: Text('Padrão do estilo')),
                for (final MapEntry(:key, :value) in _StyleScreenState._curves.entries)
                  DropdownMenuItem(value: key, child: Text(value)),
              ],
              onChanged: _locked ? null : (v) => _change(() => aj['curva'] = v ?? ''),
            ),
          ],
        ),
      ),
    );
    return Column(
      children: [
        band,
        const Divider(height: 1),
        Expanded(child: _columns([(2, layers), (6, center), (3, props)])),
      ],
    );
  }

  Widget _fixedPreview(String p) => PiecePreview(
    piece: p,
    paleta: _palette,
    sources: _families,
    layout: 'peca',
    playing: false,
  );

  // ───────────────────────── Test with a script ─────────────────────────

  Future<void> _runTest({String texto = '', String ep = ''}) async {
    final e = Json.from(_e!);
    e['guia'] = _guide.text;
    e['pele'] = {...(e['pele'] as Json), for (final p in _StyleScreenState._roles) p: _colors[p]!.text.trim()};
    try {
      final r = await widget.api.testStyle(widget.id, texto: texto, ep: ep, estilo: e);
      _change(() {
        _test = r;
        _testEp = ep;
        _textTest = texto;
        _testScene = 0;
        _warningsIgnored.clear();
      });
    } catch (x) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$x')));
    }
  }

  Future<void> _pasteSpan() async {
    final c = TextEditingController(text: _textTest);
    final r = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Colar trecho do roteiro'),
        content: SizedBox(
          width: 620,
          child: TextField(controller: c, minLines: 8, maxLines: 18, autofocus: true),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('Testar')),
        ],
      ),
    );
    c.dispose();
    if (r != null && r.trim().isNotEmpty) await _runTest(texto: r);
  }

  Color _colorLayout(String l) => switch (l) {
    'camera' => const Color(0xFF2B3B5C),
    'broll' || 'midia_overlay' => const Color(0xFF1E3326),
    _ => const Color(0xFF3B3322),
  };

  Widget _miniDecup(String l) => ClipRRect(
    borderRadius: BorderRadius.circular(4),
    child: SizedBox(
      width: 96,
      height: 54,
      child: l == 'split'
          ? Row(
              children: [
                Expanded(child: ColoredBox(color: _colorLayout('camera'))),
                Expanded(child: ColoredBox(color: _colorLayout('peca'))),
              ],
            )
          : ColoredBox(color: _colorLayout(l)),
    ),
  );

  Widget _testTab(BuildContext context) {
    final r = _test;
    final top = Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 380,
            child: FutureBuilder<List<dynamic>>(
              future: _eps ??= widget.api.studioProductions('${_e!['canal']}'),
              builder: (_, s) => DropdownButtonFormField<String>(
                initialValue: _testEp.isEmpty ? null : _testEp,
                isExpanded: true,
                hint: Text(s.hasData && s.data!.isEmpty ? 'Nenhum episódio com narração' : 'Episódio do canal'),
                decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                items: [
                  for (final p in s.data ?? const [])
                    DropdownMenuItem(
                      value: '${p['ep']}',
                      child: Text('${p['ep']} · ${p['titulo']}', overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => v == null ? null : _runTest(ep: v),
              ),
            ),
          ),
          OutlinedButton(onPressed: _pasteSpan, child: const Text('Colar trecho')),
          if (r != null)
            Text(
              'Rascunho v${(_e!['versao'] as num) + 1} · ${r['duracao']} s analisados · ${(r['cenas'] as List).length} cenas',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [ButtonSegment(value: '16:9', label: Text('16:9')), ButtonSegment(value: '9:16', label: Text('9:16'))],
            selected: {_testFormat},
            onSelectionChanged: (s) => _change(() => _testFormat = s.first),
          ),
        ],
      ),
    );
    if (r == null) {
      return Column(
        children: [
          top,
          const Expanded(
            child: Center(
              child: Text('Escolha um episódio ou cole um trecho: o estilo decupa o roteiro pelos gatilhos, sem IA e sem render.'),
            ),
          ),
        ],
      );
    }
    final scenes = (r['cenas'] as List).cast<Json>();
    final warnings = [for (final (i, a) in (r['avisos'] as List).cast<Json>().indexed) if (!_warningsIgnored.contains(i)) (i, a)];
    final sel = scenes.isEmpty ? null : scenes[_testScene.clamp(0, scenes.length - 1)];
    final dest = color(_skin['destaque'] as String?);
    final names = {for (final g in _triggers) '${g['id']}': '${g['nome']}'};
    final script = Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 6,
          children: [
            const _Label('Roteiro e gatilhos detectados'),
            for (final (i, c) in scenes.indexed)
              Card.outlined(
                margin: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(color: i == _testScene ? Theme.of(context).colorScheme.primary : Colors.transparent),
                ),
                child: InkWell(
                  onTap: () => _change(() => _testScene = i),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 6,
                      children: [
                        _realce('${c['frase']}', dest),
                        _pill(
                          context,
                          '${c['gatilho']}'.isEmpty
                              ? 'Sem gatilho · ficou na câmera'
                              : '${c['gatilho_nome']}${(c['perdeu'] as List).isEmpty ? '' : ' · venceu ${names[(c['perdeu'] as List).first] ?? (c['perdeu'] as List).first}'}',
                          color: '${c['gatilho']}'.isEmpty ? dest : null,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    final rhythm = (r['ritmo'] as Json);
    final paradas = {for (final (_, a) in warnings) if (a['tipo'] == 'peca_parada') a['i']};
    final decup = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        const _Label('Decupagem gerada'),
        for (final (i, c) in scenes.indexed)
          Card.outlined(
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(
                color: i == _testScene ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outlineVariant,
                width: i == _testScene ? 2 : 1,
              ),
            ),
            child: InkWell(
              onTap: () => _change(() => _testScene = i),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  spacing: 14,
                  children: [
                    Text(_mmss(c['t'] as num), style: const TextStyle(fontFamily: 'monospace')),
                    _miniDecup('${c['layout']}'),
                    Expanded(
                      child: Text(
                        [
                          _layoutNames['${c['layout']}'] ?? '${c['layout']}',
                          if ('${c['peca']}'.isNotEmpty) _pieceNames['${c['peca']}'] ?? '${c['peca']}',
                          if ('${c['trecho']}'.isNotEmpty) '"${c['trecho']}"',
                        ].join(' · '),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Card.outlined(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 10,
              children: [
                const _Label('Ritmo do vídeo'),
                SizedBox(
                  height: 28,
                  child: Row(
                    children: [
                      for (final (i, c) in scenes.indexed)
                        Expanded(
                          flex: (((c['ate'] as num) - (c['t'] as num)) * 10).round().clamp(1, 1000),
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 1),
                            decoration: BoxDecoration(
                              color: _colorLayout('${c['layout']}'),
                              borderRadius: BorderRadius.circular(4),
                              border: paradas.contains(i) ? Border.all(color: Colors.redAccent, width: 2) : null,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Wrap(
                  spacing: 20,
                  children: [
                    for (final MapEntry(:key, :value) in rhythm.entries)
                      Text('${_layoutNames[key] ?? key} ${((value as num) * 100).round()}%'),
                    Text('Troca média a cada ${r['troca_media_s']} s'),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
    final right = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 16,
      children: [
        if (sel != null)
          Card.outlined(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: _testFormat == '9:16' ? 260 : 600),
                  child: _preview(
                    '${sel['peca']}',
                    layout: '${sel['layout']}',
                    format: _testFormat,
                    color: '${sel['cor']}'.isEmpty ? 'destaque' : '${sel['cor']}',
                    caption: sel['layout'] == 'camera' ? '${sel['frase']}' : '',
                  ),
                ),
              ),
            ),
          ),
        _Panel(
          titulo: 'Avisos',
          pill: _pill(context, '${warnings.length}', color: warnings.isEmpty ? Colors.green : dest),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 10,
            children: [
              if (warnings.isEmpty) const Text('Nenhum aviso: o roteiro respeita as regras do estilo.'),
              for (final (i, a) in warnings) _warning(context, i, a, scenes),
            ],
          ),
        ),
      ],
    );
    return Column(
      children: [
        top,
        Expanded(child: _columns([(4, script), (6, decup), (4, right)])),
      ],
    );
  }

  Widget _warning(BuildContext context, int i, Json a, List<Json> scenes) {
    final grave = a['tipo'] != 'sem_gatilho';
    final c = grave ? Colors.redAccent : color(_skin['destaque'] as String?);
    final scene = scenes.where((x) => x['i'] == a['i']).firstOrNull;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.withValues(alpha: .6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 6,
        children: [
          Text('${a['titulo']}', style: Theme.of(context).textTheme.titleSmall),
          Text('${a['texto']}', style: Theme.of(context).textTheme.bodySmall),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final acao in (a['acoes'] as List).cast<String>())
                OutlinedButton(
                  onPressed: () => _actionWarning(acao, i, a, scene),
                  child: Text(acao),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _actionWarning(String acao, int i, Json a, Json? scene) async {
    switch (acao) {
      case 'Ignorar':
        _change(() => _warningsIgnored.add(i));
      case 'Sim, neste estilo':
        // the sentence becomes a pattern of the impact trigger and the test runs again
        final g = _triggers.where((x) => x['id'] == 'impacto').firstOrNull;
        if (g == null || scene == null || _locked) return;
        final sentence = '${scene['frase']}'.toLowerCase().replaceAll(RegExp(r'[.!?]+$'), '').trim();
        _change(() => (g['padroes'] as List).add(sentence));
        await _runTest(texto: _textTest, ep: _testEp);
      case 'Avançar etapa por palavra':
        _change(() {
          _pieceSel = '${scene?['peca'] ?? 'passo_a_passo'}';
          _tabs.animateTo(3);
        });
      default: // Ajustar regra
        _change(() {
          if (a['tipo'] == 'peca_parada' || a['tipo'] == 'fora') {
            _tabs.animateTo(1);
          } else {
            if (scene != null && '${scene['gatilho']}'.isNotEmpty) _selTrigger = '${scene['gatilho']}';
            _tabs.animateTo(2);
          }
        });
    }
  }
}
