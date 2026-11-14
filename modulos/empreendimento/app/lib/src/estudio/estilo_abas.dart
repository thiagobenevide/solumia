part of 'estilo_tela.dart';

// Abas Layouts e modos, Gatilhos, Peças e Testar com roteiro (wireframes do Estúdio). Tudo edita o JSON do estilo
// em memória (`_e`); "Publicar" grava a versão nova.

const _layoutsNome = {
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
const _layoutsModo = {
  'apresentador': ['camera', 'split', 'lateral', 'flutuante', 'solido', 'galeria', 'peca', 'capitulo', 'broll'],
  'dark': ['peca', 'lateral', 'flutuante', 'solido', 'galeria', 'tipografia', 'midia_overlay', 'broll', 'capitulo'],
};
const _pecasNome = {
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
const _gruposNome = {'credibilidade': 'Credibilidade e dados', 'estrutura': 'Estrutura', 'tom': 'Tom'};
const _camadas = {
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

/// Rótulo de seção em caixa alta, espaçado (como nos wireframes).
class _Rotulo extends StatelessWidget {
  const _Rotulo(this.texto);
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

/// Painel com título (cartão contornado).
class _Painel extends StatelessWidget {
  const _Painel({required this.titulo, required this.child, this.selo, this.acao});
  final String titulo;
  final Widget? selo;
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
              ?selo,
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

Widget _selo(BuildContext context, String texto, {Color? cor}) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
  decoration: BoxDecoration(
    borderRadius: BorderRadius.circular(99),
    border: Border.all(color: cor ?? Theme.of(context).colorScheme.outline),
  ),
  child: Text(texto, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: cor)),
);

/// Três colunas no desktop; empilha em tela estreita.
Widget _colunas(List<(int, Widget)> cols, {double minimo = 1100}) => LayoutBuilder(
  builder: (context, c) => c.maxWidth < minimo
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

extension _Abas on _EstiloTelaState {
  Json get _layouts => _e!['layouts'] as Json;
  Json get _presenca => _e!['presenca'] as Json;
  Json get _pecas => _e!['pecas'] as Json;
  List<Json> get _gatilhos => [for (final g in _e!['gatilhos'] as List) g as Json];
  String get _modo => '${_e!['modo']}' == 'apresentador' ? 'apresentador' : 'dark';
  Map<String, String> get _familias => {
    for (final p in _EstiloTelaState._papeisFonte.keys) p: 'Estudio-${_pele[p] ?? _pele['fonte_destaque']}',
  };
  Json? get _gatilhoAtual => _gatilhos.where((g) => g['id'] == _gatilhoSel).firstOrNull ?? _gatilhos.firstOrNull;

  /// Layout pedido no estilo dark não tem câmera: vira peça cheia.
  String _layoutDe(Json? g) {
    final l = '${g?['layout'] ?? 'split'}';
    if (_modo == 'dark' && (l == 'camera' || l == 'split')) return g?['peca'] == '' ? 'broll' : 'peca';
    return l;
  }

  Widget _previa(String peca, {String? layout, String formato = '16:9', String cor = 'destaque', String legenda = ''}) =>
      PreviaPeca(
        peca: peca,
        paleta: _paleta,
        fontes: _familias,
        layout: layout ?? (_modo == 'apresentador' ? 'split' : 'peca'),
        formato: formato,
        cor: cor,
        ladoApresentador: '${_layouts['split_lado']}',
        largura: (_layouts['split_largura'] as num).toDouble(),
        legenda: legenda,
      );

  // ───────────────────────── Layouts e modos ─────────────────────────

  Widget _miniLayout(String l, {bool selecionado = false, VoidCallback? toque, bool leitura = false}) {
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
                  child: PreviaPeca(
                    peca: l == 'capitulo' ? 'titulo_capitulo' : (l == 'tipografia' ? 'lettering' : (l == 'camera' ? '' : 'contador')),
                    paleta: _paleta,
                    fontes: _familias,
                    layout: l == 'tipografia' || l == 'capitulo' ? 'peca' : l,
                    largura: (_layouts['split_largura'] as num).toDouble(),
                    ladoApresentador: '${_layouts['split_lado']}',
                    tocando: false,
                  ),
                ),
                Text(_layoutsNome[l] ?? l, style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(_layoutsDesc[l] ?? '', style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _campoNum(Json dados, String chave, String sufixo, {int? indice}) {
    final valor = indice == null ? dados[chave] : (dados[chave] as List)[indice];
    return Row(
      spacing: 8,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 72,
          child: TextFormField(
            key: ValueKey('$chave$indice${_e!['versao']}'),
            initialValue: '$valor',
            enabled: !_travado,
            decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
            onChanged: (v) {
              final n = double.tryParse(v.replaceAll(',', '.'));
              if (n == null) return;
              if (indice == null) {
                dados[chave] = n;
              } else {
                (dados[chave] as List)[indice] = n;
              }
            },
          ),
        ),
        Text(sufixo),
      ],
    );
  }

  Widget _layoutsAba(BuildContext context) {
    final lista = _layoutsModo[_modo]!;
    final irmao = _irmao;
    final splitPainel = _Painel(
      titulo: _layoutsNome[_layoutSel] ?? _layoutSel,
      selo: _selo(context, 'usado por ${_gatilhos.where((g) => _layoutDe(g) == _layoutSel).length} gatilhos'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          const _Rotulo('16:9'),
          _previa('anel_percentual', layout: _layoutSel == 'tipografia' ? 'peca' : _layoutSel),
          if (const {'lateral', 'flutuante', 'solido', 'galeria'}.contains(_layoutSel)) ...[
            _Opcoes(
              'Lado dos dados',
              _layouts..putIfAbsent('lado_dados', () => 'auto'),
              'lado_dados',
              const {'auto': 'Auto (oposto ao rosto)', 'esquerda': 'Esquerda', 'direita': 'Direita'},
              ativo: !_travado,
              mudou: () => _mudar(() {}),
            ),
          ],
          TextFormField(
            key: ValueKey('selo-${_layouts['selo']}-$_travado'),
            initialValue: '${_layouts['selo'] ?? ''}',
            enabled: !_travado,
            maxLength: 40,
            decoration: const InputDecoration(
              labelText: 'Selo de progresso no canto (vazio = sem selo)',
              hintText: 'ex.: A IA EDITANDO',
            ),
            onFieldSubmitted: (v) => _mudar(() => _layouts['selo'] = v.trim()),
          ),
          if (_layoutSel == 'split') ...[
            _Opcoes(
              'Lado do apresentador',
              _layouts,
              'split_lado',
              const {'esquerda': 'Esquerda', 'direita': 'Direita'},
              ativo: !_travado,
              mudou: () => _mudar(() {}),
            ),
            _Deslizante(
              'Largura do apresentador',
              (_layouts['split_largura'] as num).toDouble(),
              (v) => _mudar(() => _layouts['split_largura'] = v),
              ativo: !_travado,
              min: 0.25,
              max: 0.6,
            ),
            _Opcoes(
              'Entrada do painel',
              _layouts,
              'painel_entrada',
              const {'desliza': 'Desliza', 'fade': 'Fade', 'corte': 'Corte'},
              ativo: !_travado,
              mudou: () => _mudar(() {}),
            ),
            _Deslizante(
              'Área segura',
              (_layouts['area_segura'] as num).toDouble(),
              (v) => _mudar(() => _layouts['area_segura'] = v),
              ativo: !_travado,
              max: 0.15,
            ),
            const _Rotulo('9:16 · como o split se adapta'),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 16,
              children: [
                SizedBox(width: 120, child: _previa('anel_percentual', layout: 'split', formato: '9:16')),
                Expanded(
                  child: Column(
                    children: [
                      _Opcoes(
                        'Peça',
                        _layouts,
                        'vertical_peca',
                        const {'cima': 'Em cima', 'baixo': 'Embaixo'},
                        ativo: !_travado,
                        mudou: () => _mudar(() {}),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Reservar 20% inferiores (UI do app)'),
                        value: _layouts['reservar_inferior'] == true,
                        onChanged: _travado ? null : (v) => _mudar(() => _layouts['reservar_inferior'] = v),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Legenda no terço central'),
                        value: _layouts['legenda_terco'] == true,
                        onChanged: _travado ? null : (v) => _mudar(() => _layouts['legenda_terco'] = v),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ] else if (_layoutSel == 'peca')
            _campoLinha('Peça cheia no máximo', _campoNum(_layouts, 'peca_cheia_max_s', 's'))
          else if (_layoutSel == 'capitulo')
            _campoLinha(
              'Cartela de capítulo',
              Row(
                children: [
                  _campoNum(_layouts, 'capitulo_s', '–', indice: 0),
                  _campoNum(_layouts, 'capitulo_s', 's', indice: 1),
                ],
              ),
            )
          else if (_layoutSel == 'broll' || _layoutSel == 'midia_overlay')
            _campoLinha('Mídia no máximo', _campoNum(_layouts, 'broll_max_s', 's'))
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
        _Painel(
          titulo: 'Layouts deste estilo',
          selo: _selo(context, 'modo $_modo'),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final l in lista)
                _miniLayout(l, selecionado: l == _layoutSel, toque: () => _mudar(() => _layoutSel = l)),
            ],
          ),
        ),
        if (irmao != null)
          _Painel(
            titulo: 'Layouts de ${irmao['nome']}',
            selo: _selo(context, 'só leitura aqui'),
            acao: OutlinedButton(onPressed: () => _abrirIrmao('${irmao['id']}'), child: const Text('Abrir estilo')),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 10,
              children: [
                Text(
                  'Mostrado lado a lado para comparar: o ${irmao['modo']} troca o apresentador por tipografia cinética e '
                  'mídia com overlay.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final l in _layoutsModo['${irmao['modo']}' == 'apresentador' ? 'apresentador' : 'dark']!)
                      _miniLayout(l, leitura: true),
                  ],
                ),
              ],
            ),
          ),
        _Painel(
          titulo: 'Regras de presença e ritmo',
          child: Wrap(
            spacing: 32,
            runSpacing: 12,
            children: [
              _campoLinha('Apresentador fora da tela', _campoNum(_presenca, 'fora_max_s', 's no máximo')),
              _campoLinha('Peça parada', _campoNum(_presenca, 'peca_parada_s', 's, depois acrescenta detalhe')),
              _campoLinha(
                'Mudança na tela',
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _campoNum(_presenca, 'mudanca_s', '–', indice: 0),
                    _campoNum(_presenca, 'mudanca_s', 's', indice: 1),
                  ],
                ),
              ),
            ],
          ),
        ),
        _legendaAba(context),
      ],
    );
    return _colunas([(6, esquerda), (4, splitPainel)]);
  }

  Widget _campoLinha(String rotulo, Widget campo) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [_Rotulo(rotulo), campo],
  );

  // ───────────────────────── Gatilhos ─────────────────────────

  Future<String?> _pedirTexto(String titulo, {String dica = ''}) async {
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

  Future<void> _novoGatilho({Json? base}) async {
    final nome = await _pedirTexto(base == null ? 'Novo gatilho' : 'Duplicar gatilho', dica: 'Nome (ex.: Meta financeira)');
    if (nome == null) return;
    var id = nome.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_|_$'), '');
    if (id.length < 2) id = 'gatilho';
    while (_gatilhos.any((g) => g['id'] == id)) {
      id = '${id}_2';
    }
    _mudar(() {
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
      _gatilhoSel = id;
    });
  }

  Widget _listaGatilhos(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    final busca = _busca.toLowerCase();
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
                    onChanged: (v) => _mudar(() => _busca = v),
                  ),
                ),
                IconButton.outlined(
                  tooltip: 'Novo gatilho',
                  onPressed: _travado ? null : _novoGatilho,
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
            for (final MapEntry(key: grupo, value: nomeGrupo) in _gruposNome.entries) ...[
              _Rotulo(nomeGrupo),
              for (final g in (_gatilhos.where((g) => g['grupo'] == grupo && '${g['nome']}'.toLowerCase().contains(busca)).toList()
                ..sort((a, b) => (a['prioridade'] as num).compareTo(b['prioridade'] as num))))
                Material(
                  color: g['id'] == _gatilhoSel ? cores.primaryContainer : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => _mudar(() => _gatilhoSel = '${g['id']}'),
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
                            '${g['peca']}'.isEmpty ? 'sem peça' : (_layoutsNome[_layoutDe(g)] ?? '').toLowerCase(),
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: '${g['peca']}'.isEmpty ? cor(_pele['destaque'] as String?) : null,
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

  Widget _chipsEditaveis(List lista, String dica, {bool mono = false, String titulo = 'Novo padrão'}) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final p in List.of(lista))
        InputChip(
          label: Text('$p', style: TextStyle(fontFamily: mono ? 'monospace' : null)),
          onDeleted: _travado ? null : () => _mudar(() => lista.remove(p)),
        ),
      ActionChip(
        avatar: const Icon(Icons.add, size: 16),
        label: const Text('adicionar'),
        onPressed: _travado
            ? null
            : () async {
                final v = await _pedirTexto(titulo, dica: dica);
                if (v != null) _mudar(() => lista.add(v));
              },
      ),
    ],
  );

  Widget _editorGatilho(BuildContext context, Json g) {
    final cat = (_tabela['condicoes'] as Json?) ?? const {};
    final pecas = (_tabela['pecas'] as Json?) ?? const {};
    final nao = g['nao_disparar'] as List;
    final irmaoG = ((_irmao?['gatilhos'] as List?) ?? const []).cast<Json>().where((x) => x['id'] == g['id']).firstOrNull;
    final dest = cor(_pele['destaque'] as String?);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 16,
      children: [
        _Painel(
          titulo: '${g['nome']}',
          selo: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 8,
            children: [
              PopupMenuButton<int>(
                enabled: !_travado,
                tooltip: 'Prioridade',
                itemBuilder: (_) => [for (var i = 0; i <= 12; i++) PopupMenuItem(value: i, child: Text('$i'))],
                onSelected: (v) => _mudar(() => g['prioridade'] = v),
                child: _selo(context, 'prioridade ${g['prioridade']}'),
              ),
              InkWell(
                onTap: _travado ? null : () => _mudar(() => g['ativo'] = g['ativo'] == false),
                child: _selo(
                  context,
                  g['ativo'] == false ? 'inativo' : 'ativo',
                  cor: g['ativo'] == false ? null : Colors.green,
                ),
              ),
            ],
          ),
          acao: OutlinedButton(onPressed: _travado ? null : () => _novoGatilho(base: g), child: const Text('Duplicar')),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _Rotulo('Como reconhecer na fala'),
              _chipsEditaveis(g['padroes'] as List, '{número}% · {n} em cada {m} · segundo {palavra} · re:regex', mono: true),
              const _Rotulo('Exemplos que devem disparar'),
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
                      if (!_travado)
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.close, size: 16),
                          onPressed: () => _mudar(() => (g['exemplos'] as List).remove(x)),
                        ),
                    ],
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _travado
                      ? null
                      : () async {
                          final v = await _pedirTexto('Exemplo que deve disparar', dica: 'Frase como é dita');
                          if (v != null) _mudar(() => (g['exemplos'] as List).add(v));
                        },
                  icon: const Icon(Icons.add),
                  label: const Text('Exemplo'),
                ),
              ),
              const _Rotulo('Não disparar quando'),
              for (final MapEntry(:key, :value) in cat.entries)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text('$value'),
                  value: nao.contains(key),
                  onChanged: _travado ? null : (v) => _mudar(() => v == true ? nao.add(key) : nao.remove(key)),
                ),
            ],
          ),
        ),
        _Painel(
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
                        _Rotulo('Neste estilo · $_modo'),
                        DropdownButtonFormField<String>(
                          key: ValueKey('lay${g['id']}'),
                          initialValue: '${g['layout']}',
                          decoration: const InputDecoration(labelText: 'Layout', isDense: true, border: OutlineInputBorder()),
                          items: [
                            for (final MapEntry(:key, :value) in _layoutsNome.entries)
                              DropdownMenuItem(value: key, child: Text(value)),
                          ],
                          onChanged: _travado ? null : (v) => _mudar(() => g['layout'] = v),
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
                                  for (final p in pecas.keys)
                                    if (p != 'midia') DropdownMenuItem(value: p, child: Text(_pecasNome[p] ?? p)),
                                ],
                                onChanged: _travado ? null : (v) => _mudar(() => g['peca'] = v ?? ''),
                              ),
                            ),
                            if ('${g['peca']}'.isNotEmpty)
                              TextButton(
                                onPressed: () => _mudar(() {
                                  _pecaSel = '${g['peca']}';
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
              if (_irmao != null)
                Expanded(
                  child: Card.outlined(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 4,
                        children: [
                          _Rotulo('Em ${_irmao!['nome']}'),
                          const _Rotulo('Layout'),
                          Text(irmaoG == null ? '—' : _layoutsNome['${irmaoG['layout']}'] ?? '${irmaoG['layout']}'),
                          const _Rotulo('Peça'),
                          Text(irmaoG == null ? 'sem esse gatilho' : _pecasNome['${irmaoG['peca']}'] ?? 'Sem peça'),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        _Painel(
          titulo: 'Cor',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text('Padrão'),
              _corChip(g, 'cor'),
              for (final r in (g['cor_regras'] as List).cast<Json>()) ...[
                const Text('· se a frase tiver'),
                for (final t in List.of(r['termos'] as List))
                  InputChip(
                    label: Text('$t'),
                    onDeleted: _travado ? null : () => _mudar(() => (r['termos'] as List).remove(t)),
                  ),
                ActionChip(
                  label: const Icon(Icons.add, size: 16),
                  onPressed: _travado
                      ? null
                      : () async {
                          final v = await _pedirTexto('Termo da frase', dica: 'endividad* · queda');
                          if (v != null) _mudar(() => (r['termos'] as List).add(v));
                        },
                ),
                const Text('usar'),
                _corChip(r, 'cor'),
              ],
              TextButton.icon(
                onPressed: _travado
                    ? null
                    : () => _mudar(() => (g['cor_regras'] as List).add({'termos': <String>[], 'cor': 'acento'})),
                icon: const Icon(Icons.add),
                label: const Text('Regra de cor'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Frase com números e trechos entre aspas na cor de destaque (o que o padrão pega).
  Widget _realce(String s, Color dest) {
    final partes = <TextSpan>[];
    s.splitMapJoin(
      RegExp(r'\d[\d.,]*\s*%?(?:\s+em cada\s+\d+)?'),
      onMatch: (m) {
        partes.add(TextSpan(text: m[0], style: TextStyle(color: dest)));
        return '';
      },
      onNonMatch: (t) {
        partes.add(TextSpan(text: t));
        return '';
      },
    );
    return Text.rich(TextSpan(children: partes));
  }

  Widget _corChip(Json dados, String chave) {
    final atual = '${dados[chave]}';
    return PopupMenuButton<String>(
      enabled: !_travado,
      tooltip: 'Cor',
      itemBuilder: (_) => [
        for (final c in const ['destaque', 'apoio', 'acento'])
          PopupMenuItem(
            value: c,
            child: Row(spacing: 8, children: [CircleAvatar(radius: 6, backgroundColor: _paleta[c]), Text(c)]),
          ),
      ],
      onSelected: (v) => _mudar(() => dados[chave] = v),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: _paleta[atual] ?? Colors.grey),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 6,
          children: [CircleAvatar(radius: 5, backgroundColor: _paleta[atual]), Text(atual)],
        ),
      ),
    );
  }

  Widget _gatilhosAba(BuildContext context) {
    final g = _gatilhoAtual;
    if (g == null) return const Center(child: Text('Sem gatilhos'));
    final exemplo = '${(g['exemplos'] as List).firstOrNull ?? ''}';
    final previa = _Painel(
      titulo: 'Prévia sincronizada',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          _previa('${g['peca']}', layout: _layoutDe(g), cor: '${g['cor']}', legenda: _layoutDe(g) == 'camera' ? exemplo : ''),
          const _Rotulo('Linha do tempo da fala'),
          _linhaTempo(context, exemplo, [
            ('Layout', 0.0, 1.0, cor(_pele['fundo2'] as String?)),
            ('Peça', 0.35, 0.85, _paleta['${g['cor']}'] ?? Colors.amber),
            ('Contexto', 0.45, 0.95, Colors.grey),
          ]),
          Text(
            'A peça entra ${-((_pecas['${g['peca']}'] as Json?)?['atraso_q'] ?? -3)} quadros antes da palavra-âncora e a '
            'contagem dura enquanto o número é falado.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
    return _colunas([(3, _listaGatilhos(context)), (5, _editorGatilho(context, g)), (4, previa)]);
  }

  /// Linhas do tempo simples: fala em palavras + barras (rótulo, início, fim em fração, cor).
  Widget _linhaTempo(BuildContext context, String fala, List<(String, double, double, Color)> barras) => Column(
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
                for (final p in fala.split(' ').take(10))
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: RegExp(r'\d').hasMatch(p)
                          ? cor(_pele['destaque'] as String?).withValues(alpha: .2)
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
      for (final (rot, de, ate, c) in barras)
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
                      width: k.maxWidth * (ate - de),
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

  // ───────────────────────── Peças ─────────────────────────

  Json _ajustePeca(String p) => (_pecas[p] ??= <String, dynamic>{
    'entrada': '',
    'atraso_q': -3,
    'contagem_s': 0.9,
    'curva': '',
    'fonte': 'fonte_destaque',
    'tamanho': 1.0,
    'cor': 'gatilho',
  }) as Json;

  Widget _pecasAba(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    final todas = [for (final p in ((_tabela['pecas'] as Json?) ?? const {}).keys) if (p != 'midia') p];
    // o canal guarda só o que NÃO usa (filtro); o cardápio é o resto
    final filtro = (_regras['filtro'] ??= <dynamic>[]) as List;
    final p = todas.contains(_pecaSel) ? _pecaSel : (todas.firstOrNull ?? 'contador');
    final aj = _ajustePeca(p);
    final usadas = _gatilhos.where((g) => g['peca'] == p).toList();
    final faixa = SizedBox(
      height: 118,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        children: [
          for (final x in todas)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: InkWell(
                onTap: () => _mudar(() => _pecaSel = x),
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
                        child: IgnorePointer(child: _previaFixa(x)),
                      ),
                      Text(
                        _pecasNome[x] ?? x,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: !filtro.contains(x) ? null : cores.onSurfaceVariant.withValues(alpha: .6),
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
    final camadas = Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Rotulo('Camadas e campos'),
            for (final (i, (nome, origem)) in (_camadas[p] ?? const [('Valor', 'da fala'), ('Título', 'da fala')]).indexed)
              ListTile(
                dense: true,
                selected: i == 0,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                leading: Icon(i == 0 ? Icons.diamond_outlined : Icons.layers_outlined, size: 16),
                title: Text(nome),
                trailing: Text(origem, style: Theme.of(context).textTheme.labelSmall),
              ),
            const ListTile(
              dense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 8),
              leading: Icon(Icons.crop_square, size: 16),
              title: Text('Fundo da peça'),
            ),
            const Divider(),
            const _Rotulo('Usada em'),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final g in usadas)
                  ActionChip(
                    label: Text('${g['nome']} · ${(_layoutsNome[_layoutDe(g)] ?? '').toLowerCase()}'),
                    onPressed: () => _mudar(() {
                      _gatilhoSel = '${g['id']}';
                      _tabs.animateTo(2);
                    }),
                  ),
                if (usadas.isEmpty) const Text('nenhum gatilho'),
              ],
            ),
            const SizedBox(height: 10),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('O canal usa esta peça'),
              subtitle: const Text('Desligada, entra no filtro do canal e a IA nunca a escolhe'),
              value: !filtro.contains(p),
              onChanged: _travado ? null : (v) => _mudar(() => v ? filtro.remove(p) : filtro.add(p)),
            ),
            Text(
              'Campos "da fala" são preenchidos pela IA local a partir do roteiro; ela nunca inventa número.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
    final centro = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        Row(
          children: [
            Expanded(child: Text(_pecasNome[p] ?? p, style: Theme.of(context).textTheme.titleLarge)),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [ButtonSegment(value: '16:9', label: Text('16:9')), ButtonSegment(value: '9:16', label: Text('9:16'))],
              selected: {_formatoPeca},
              onSelectionChanged: (s) => _mudar(() => _formatoPeca = s.first),
            ),
          ],
        ),
        Text('Dado de exemplo: ${exemplosPeca[p] ?? ''}', style: Theme.of(context).textTheme.bodySmall),
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: _formatoPeca == '9:16' ? 320 : 900),
            child: _previa(p, formato: _formatoPeca),
          ),
        ),
        Card.outlined(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: _linhaTempo(context, 'segundo a CNC, 81,7% das famílias estão endividadas', [
              ('Rótulo fonte', 0.05, 0.3, Colors.grey),
              ('Valor', 0.35 + (aj['atraso_q'] as num) / 100, 0.6 + (aj['contagem_s'] as num) / 10, cor(_pele['destaque'] as String?)),
              ('Peça', 0.35, 0.6 + (aj['contagem_s'] as num) / 10, cor(_pele['acento'] as String?)),
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
            const _Rotulo('Propriedades'),
            DropdownButtonFormField<String>(
              key: ValueKey('fonte$p'),
              initialValue: '${aj['fonte']}',
              decoration: const InputDecoration(labelText: 'Fonte', isDense: true, border: OutlineInputBorder()),
              items: [
                for (final MapEntry(:key, :value) in _EstiloTelaState._papeisFonte.entries)
                  if (key != 'fonte_legenda') DropdownMenuItem(value: key, child: Text(value)),
              ],
              onChanged: _travado ? null : (v) => _mudar(() => aj['fonte'] = v),
            ),
            _Deslizante(
              'Tamanho',
              (aj['tamanho'] as num).toDouble(),
              (v) => _mudar(() => aj['tamanho'] = v),
              ativo: !_travado,
              min: 0.5,
              max: 2,
            ),
            _Opcoes(
              'Cor',
              aj,
              'cor',
              const {'destaque': 'destaque', 'gatilho': 'regra do gatilho'},
              ativo: !_travado,
              mudou: () => _mudar(() {}),
            ),
            Text('Cores vêm da Identidade. Sem hex solto aqui.', style: Theme.of(context).textTheme.bodySmall),
            const Divider(),
            const _Rotulo('Animação'),
            DropdownButtonFormField<String>(
              key: ValueKey('entrada$p'),
              initialValue: '${aj['entrada']}',
              decoration: const InputDecoration(labelText: 'Entrada', isDense: true, border: OutlineInputBorder()),
              items: [
                const DropdownMenuItem(value: '', child: Text('Padrão do estilo')),
                for (final MapEntry(:key, :value) in _EstiloTelaState._entradas.entries)
                  DropdownMenuItem(value: key, child: Text(value)),
              ],
              onChanged: _travado ? null : (v) => _mudar(() => aj['entrada'] = v ?? ''),
            ),
            _Deslizante(
              'Atraso (quadros)',
              (aj['atraso_q'] as num).toDouble(),
              (v) => _mudar(() => aj['atraso_q'] = v.round()),
              ativo: !_travado,
              min: -12,
              max: 12,
              fmt: (v) => '${v.round()} f',
            ),
            _Deslizante(
              'Contagem',
              (aj['contagem_s'] as num).toDouble(),
              (v) => _mudar(() => aj['contagem_s'] = double.parse(v.toStringAsFixed(2))),
              ativo: !_travado,
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
                for (final MapEntry(:key, :value) in _EstiloTelaState._curvas.entries)
                  DropdownMenuItem(value: key, child: Text(value)),
              ],
              onChanged: _travado ? null : (v) => _mudar(() => aj['curva'] = v ?? ''),
            ),
          ],
        ),
      ),
    );
    return Column(
      children: [
        faixa,
        const Divider(height: 1),
        Expanded(child: _colunas([(2, camadas), (6, centro), (3, props)])),
      ],
    );
  }

  Widget _previaFixa(String p) => PreviaPeca(
    peca: p,
    paleta: _paleta,
    fontes: _familias,
    layout: 'peca',
    tocando: false,
  );

  // ───────────────────────── Testar com roteiro ─────────────────────────

  Future<void> _testar({String texto = '', String ep = ''}) async {
    final e = Json.from(_e!);
    e['guia'] = _guia.text;
    e['pele'] = {...(e['pele'] as Json), for (final p in _EstiloTelaState._papeis) p: _cores[p]!.text.trim()};
    try {
      final r = await widget.api.testarEstilo(widget.id, texto: texto, ep: ep, estilo: e);
      _mudar(() {
        _teste = r;
        _testeEp = ep;
        _testeTexto = texto;
        _testeCena = 0;
        _avisosIgnorados.clear();
      });
    } catch (x) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$x')));
    }
  }

  Future<void> _colarTrecho() async {
    final c = TextEditingController(text: _testeTexto);
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
    if (r != null && r.trim().isNotEmpty) await _testar(texto: r);
  }

  Color _corLayout(String l) => switch (l) {
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
                Expanded(child: ColoredBox(color: _corLayout('camera'))),
                Expanded(child: ColoredBox(color: _corLayout('peca'))),
              ],
            )
          : ColoredBox(color: _corLayout(l)),
    ),
  );

  Widget _testarAba(BuildContext context) {
    final r = _teste;
    final topo = Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 380,
            child: FutureBuilder<List<dynamic>>(
              future: _eps ??= widget.api.producoesEstudio('${_e!['canal']}'),
              builder: (_, s) => DropdownButtonFormField<String>(
                initialValue: _testeEp.isEmpty ? null : _testeEp,
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
                onChanged: (v) => v == null ? null : _testar(ep: v),
              ),
            ),
          ),
          OutlinedButton(onPressed: _colarTrecho, child: const Text('Colar trecho')),
          if (r != null)
            Text(
              'Rascunho v${(_e!['versao'] as num) + 1} · ${r['duracao']} s analisados · ${(r['cenas'] as List).length} cenas',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [ButtonSegment(value: '16:9', label: Text('16:9')), ButtonSegment(value: '9:16', label: Text('9:16'))],
            selected: {_testeFormato},
            onSelectionChanged: (s) => _mudar(() => _testeFormato = s.first),
          ),
        ],
      ),
    );
    if (r == null) {
      return Column(
        children: [
          topo,
          const Expanded(
            child: Center(
              child: Text('Escolha um episódio ou cole um trecho: o estilo decupa o roteiro pelos gatilhos, sem IA e sem render.'),
            ),
          ),
        ],
      );
    }
    final cenas = (r['cenas'] as List).cast<Json>();
    final avisos = [for (final (i, a) in (r['avisos'] as List).cast<Json>().indexed) if (!_avisosIgnorados.contains(i)) (i, a)];
    final sel = cenas.isEmpty ? null : cenas[_testeCena.clamp(0, cenas.length - 1)];
    final dest = cor(_pele['destaque'] as String?);
    final nomes = {for (final g in _gatilhos) '${g['id']}': '${g['nome']}'};
    final roteiro = Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 6,
          children: [
            const _Rotulo('Roteiro e gatilhos detectados'),
            for (final (i, c) in cenas.indexed)
              Card.outlined(
                margin: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(color: i == _testeCena ? Theme.of(context).colorScheme.primary : Colors.transparent),
                ),
                child: InkWell(
                  onTap: () => _mudar(() => _testeCena = i),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 6,
                      children: [
                        _realce('${c['frase']}', dest),
                        _selo(
                          context,
                          '${c['gatilho']}'.isEmpty
                              ? 'Sem gatilho · ficou na câmera'
                              : '${c['gatilho_nome']}${(c['perdeu'] as List).isEmpty ? '' : ' · venceu ${nomes[(c['perdeu'] as List).first] ?? (c['perdeu'] as List).first}'}',
                          cor: '${c['gatilho']}'.isEmpty ? dest : null,
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
    final ritmo = (r['ritmo'] as Json);
    final paradas = {for (final (_, a) in avisos) if (a['tipo'] == 'peca_parada') a['i']};
    final decup = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        const _Rotulo('Decupagem gerada'),
        for (final (i, c) in cenas.indexed)
          Card.outlined(
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(
                color: i == _testeCena ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outlineVariant,
                width: i == _testeCena ? 2 : 1,
              ),
            ),
            child: InkWell(
              onTap: () => _mudar(() => _testeCena = i),
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
                          _layoutsNome['${c['layout']}'] ?? '${c['layout']}',
                          if ('${c['peca']}'.isNotEmpty) _pecasNome['${c['peca']}'] ?? '${c['peca']}',
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
                const _Rotulo('Ritmo do vídeo'),
                SizedBox(
                  height: 28,
                  child: Row(
                    children: [
                      for (final (i, c) in cenas.indexed)
                        Expanded(
                          flex: (((c['ate'] as num) - (c['t'] as num)) * 10).round().clamp(1, 1000),
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 1),
                            decoration: BoxDecoration(
                              color: _corLayout('${c['layout']}'),
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
                    for (final MapEntry(:key, :value) in ritmo.entries)
                      Text('${_layoutsNome[key] ?? key} ${((value as num) * 100).round()}%'),
                    Text('Troca média a cada ${r['troca_media_s']} s'),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
    final direita = Column(
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
                  constraints: BoxConstraints(maxWidth: _testeFormato == '9:16' ? 260 : 600),
                  child: _previa(
                    '${sel['peca']}',
                    layout: '${sel['layout']}',
                    formato: _testeFormato,
                    cor: '${sel['cor']}'.isEmpty ? 'destaque' : '${sel['cor']}',
                    legenda: sel['layout'] == 'camera' ? '${sel['frase']}' : '',
                  ),
                ),
              ),
            ),
          ),
        _Painel(
          titulo: 'Avisos',
          selo: _selo(context, '${avisos.length}', cor: avisos.isEmpty ? Colors.green : dest),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 10,
            children: [
              if (avisos.isEmpty) const Text('Nenhum aviso: o roteiro respeita as regras do estilo.'),
              for (final (i, a) in avisos) _aviso(context, i, a, cenas),
            ],
          ),
        ),
      ],
    );
    return Column(
      children: [
        topo,
        Expanded(child: _colunas([(4, roteiro), (6, decup), (4, direita)])),
      ],
    );
  }

  Widget _aviso(BuildContext context, int i, Json a, List<Json> cenas) {
    final grave = a['tipo'] != 'sem_gatilho';
    final c = grave ? Colors.redAccent : cor(_pele['destaque'] as String?);
    final cena = cenas.where((x) => x['i'] == a['i']).firstOrNull;
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
                  onPressed: () => _acaoAviso(acao, i, a, cena),
                  child: Text(acao),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _acaoAviso(String acao, int i, Json a, Json? cena) async {
    switch (acao) {
      case 'Ignorar':
        _mudar(() => _avisosIgnorados.add(i));
      case 'Sim, neste estilo':
        // a frase vira padrão do gatilho de impacto e o teste roda de novo
        final g = _gatilhos.where((x) => x['id'] == 'impacto').firstOrNull;
        if (g == null || cena == null || _travado) return;
        final frase = '${cena['frase']}'.toLowerCase().replaceAll(RegExp(r'[.!?]+$'), '').trim();
        _mudar(() => (g['padroes'] as List).add(frase));
        await _testar(texto: _testeTexto, ep: _testeEp);
      case 'Avançar etapa por palavra':
        _mudar(() {
          _pecaSel = '${cena?['peca'] ?? 'passo_a_passo'}';
          _tabs.animateTo(3);
        });
      default: // Ajustar regra
        _mudar(() {
          if (a['tipo'] == 'peca_parada' || a['tipo'] == 'fora') {
            _tabs.animateTo(1);
          } else {
            if (cena != null && '${cena['gatilho']}'.isNotEmpty) _gatilhoSel = '${cena['gatilho']}';
            _tabs.animateTo(2);
          }
        });
    }
  }
}
