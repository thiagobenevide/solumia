import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_estudos.dart';
import '../modelos.dart';

const _meses = ['jan', 'fev', 'mar', 'abr', 'mai', 'jun', 'jul', 'ago', 'set', 'out', 'nov', 'dez'];
const _dias = ['seg', 'ter', 'qua', 'qui', 'sex', 'sáb', 'dom'];

String _curta(DateTime d) => '${d.day} ${_meses[d.month - 1]}';
String _comAno(DateTime d) => '${_meses[d.month - 1]}/${d.year}';
DateTime _hoje() => DateUtils.dateOnly(DateTime.now());
DateTime _segunda(DateTime d) => DateTime(d.year, d.month, d.day - (d.weekday - 1));

/// Trilhas de idiomas: escolha o idioma, o nível de partida e o alvo, o ritmo; o servidor gera o
/// cronograma do dia e da semana. Marcar o dia como feito soma as horas e move os marcos A1–C2.
class IdiomasTela extends StatefulWidget {
  const IdiomasTela({super.key, required this.api, required this.opcoes});

  final ApiEstudos api;
  final Opcoes opcoes;

  @override
  State<IdiomasTela> createState() => _IdiomasTelaState();
}

class _IdiomasTelaState extends State<IdiomasTela> {
  ApiEstudos get api => widget.api;
  List<Trilha>? _trilhas;
  String? _selecionada;
  bool _semana = true;
  DateTime _foco = _hoje();
  List<DiaEstudo> _cronograma = const [];
  String? _erro;

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Trilha? get _trilha => _trilhas?.where((t) => t.id == _selecionada).firstOrNull;

  Future<void> _tentar(Future<void> Function() acao) async {
    try {
      await acao();
    } on ApiErro catch (e) {
      if (!mounted) return;
      if (_trilhas == null) {
        setState(() => _erro = '$e');
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _carregar() => _tentar(() async {
    final t = await api.trilhas();
    setState(() {
      _trilhas = t;
      _erro = null;
      if (_trilha == null) _selecionada = t.firstOrNull?.id;
    });
    await _carregarDias();
  });

  Future<void> _carregarDias() async {
    final t = _trilha;
    if (t == null) return setState(() => _cronograma = const []);
    final de = _semana ? _segunda(_foco) : _foco;
    final ate = _semana ? de.add(const Duration(days: 6)) : _foco;
    final dias = await api.cronograma(t.id, de, ate);
    if (mounted) setState(() => _cronograma = dias);
  }

  void _mover(int sentido) {
    setState(() => _foco = DateTime(_foco.year, _foco.month, _foco.day + sentido * (_semana ? 7 : 1)));
    _tentar(_carregarDias);
  }

  Future<void> _marcar(DiaEstudo d) => _tentar(() async {
    final t = await api.registrar(_selecionada!, d.data, d.feito ? 0 : d.minutos);
    setState(() => _trilhas = [for (final x in _trilhas!) x.id == t.id ? t : x]);
    await _carregarDias();
  });

  Future<void> _formulario([Trilha? atual]) async {
    final dados = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _FormularioTrilha(opcoes: widget.opcoes, atual: atual),
    );
    if (dados == null) return;
    await _tentar(() async {
      final t = atual == null ? await api.criarTrilha(dados) : await api.editarTrilha(atual.id, dados);
      _selecionada = t.id;
      await _carregar();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_erro != null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, spacing: 12, children: [Text(_erro!), FilledButton(onPressed: _carregar, child: const Text('Tentar de novo'))]));
    }
    final trilhas = _trilhas;
    if (trilhas == null) return const Center(child: CircularProgressIndicator());
    if (trilhas.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            const Text('Crie uma trilha (inglês, francês, espanhol ou português) para gerar o cronograma.'),
            FilledButton.icon(onPressed: _formulario, icon: const Icon(Icons.add), label: const Text('Nova trilha')),
          ],
        ),
      );
    }
    final t = _trilha!;
    final tema = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final x in trilhas)
              ChoiceChip(
                avatar: CircleAvatar(child: Text(x.idioma.toUpperCase(), style: const TextStyle(fontSize: 9))),
                label: Text('${x.nome} · ${x.nivelAtual}'),
                selected: x.id == _selecionada,
                onSelected: (_) {
                  setState(() => _selecionada = x.id);
                  _tentar(_carregarDias);
                },
              ),
            ActionChip(avatar: const Icon(Icons.add), label: const Text('Nova trilha'), onPressed: _formulario),
          ],
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${t.nome}: ${t.nivelAtual} → ${t.nivelAlvo} · ${t.horas.toStringAsFixed(1)} h estudadas',
                        style: tema.textTheme.titleMedium,
                      ),
                    ),
                    PopupMenuButton<String>(
                      onSelected: (v) async {
                        if (v == 'editar') return _formulario(t);
                        await _tentar(() async {
                          await api.excluirTrilha(t.id);
                          _selecionada = null;
                          await _carregar();
                        });
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'editar', child: Text('Editar ritmo e níveis')),
                        PopupMenuItem(value: 'excluir', child: Text('Excluir trilha')),
                      ],
                    ),
                  ],
                ),
                Text(
                  '${t.minutosPorDia} min/dia · ${[for (final d in t.diasSemana) _dias[d - 1]].join(', ')}',
                  style: tema.textTheme.bodySmall,
                ),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final m in t.marcos)
                      Chip(
                        avatar: Icon(m.concluido ? Icons.check_circle : Icons.flag_outlined, size: 18),
                        label: Text(
                          m.concluido
                              ? m.nivel
                              : '${m.nivel} · ${m.horasFaltando.round()} h · ${m.previsao == null ? '—' : _comAno(m.previsao!)}',
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        // Wrap: no celular o seletor Dia/Semana desce para a linha de baixo
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          runSpacing: 4,
          children: [
            IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => _mover(-1)),
            IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => _mover(1)),
            TextButton(
              onPressed: () {
                setState(() => _foco = _hoje());
                _tentar(_carregarDias);
              },
              child: const Text('Hoje'),
            ),
            Text(
              _semana ? 'Semana de ${_curta(_segunda(_foco))}' : '${_dias[_foco.weekday - 1]}, ${_curta(_foco)}',
              style: tema.textTheme.titleSmall,
            ),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Text('Dia')),
                ButtonSegment(value: true, label: Text('Semana')),
              ],
              selected: {_semana},
              onSelectionChanged: (s) {
                setState(() => _semana = s.first);
                _tentar(_carregarDias);
              },
            ),
          ],
        ),
        if (_cronograma.isEmpty)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('Sem estudo marcado neste período.'))),
        for (final d in _cronograma) _dia(d),
      ],
    );
  }

  Widget _dia(DiaEstudo d) {
    final tema = Theme.of(context);
    final ehHoje = DateUtils.isSameDay(d.data, _hoje());
    return Card(
      shape: ehHoje
          ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: tema.colorScheme.primary))
          : null,
      child: ExpansionTile(
        initiallyExpanded: !_semana || ehHoje,
        leading: Checkbox(value: d.feito, onChanged: (_) => _marcar(d)),
        title: Text('${_dias[d.data.weekday - 1]}, ${_curta(d.data)} · ${d.minutos} min'),
        subtitle: Text('${d.nivel} · ${d.tema}'),
        children: [
          for (final b in d.blocos)
            ListTile(
              dense: true,
              leading: Icon(_icone(b.habilidade)),
              title: Text('${b.titulo} · ${b.minutos} min'),
              subtitle: Text(b.descricao),
            ),
        ],
      ),
    );
  }

  static IconData _icone(String h) => switch (h) {
    'gramatica' => Icons.rule,
    'escuta' => Icons.headphones,
    'leitura' => Icons.chrome_reader_mode_outlined,
    'fala' => Icons.record_voice_over_outlined,
    'escrita' => Icons.edit_note,
    'imersao' => Icons.movie_outlined,
    'revisao' => Icons.replay,
    'flashcards' => Icons.style_outlined,
    _ => Icons.translate,
  };
}

class _FormularioTrilha extends StatefulWidget {
  const _FormularioTrilha({required this.opcoes, this.atual});

  final Opcoes opcoes;
  final Trilha? atual;

  @override
  State<_FormularioTrilha> createState() => _FormularioTrilhaState();
}

class _FormularioTrilhaState extends State<_FormularioTrilha> {
  late String _idioma = widget.atual?.idioma ?? widget.opcoes.idiomas.keys.first;
  late String _inicial = widget.atual?.nivelInicial ?? 'A1';
  late String _alvo = widget.atual?.nivelAlvo ?? 'C2';
  late double _minutos = (widget.atual?.minutosPorDia ?? 45).toDouble();
  late final Set<int> _diasSel = {...widget.atual?.diasSemana ?? const [1, 2, 3, 4, 5, 6]};
  late DateTime _inicio = widget.atual?.inicio ?? _hoje();

  @override
  Widget build(BuildContext context) {
    final niveis = widget.opcoes.niveis;
    return AlertDialog(
      title: Text(widget.atual == null ? 'Nova trilha de idioma' : 'Editar trilha'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 10,
            children: [
              if (widget.atual == null)
                DropdownButtonFormField<String>(
                  initialValue: _idioma,
                  decoration: const InputDecoration(labelText: 'Idioma'),
                  items: [
                    for (final e in widget.opcoes.idiomas.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (v) => setState(() => _idioma = v!),
                ),
              Row(
                spacing: 10,
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _inicial,
                      decoration: const InputDecoration(labelText: 'Começo no nível'),
                      items: [for (final n in niveis) DropdownMenuItem(value: n, child: Text(n))],
                      onChanged: (v) => setState(() {
                        _inicial = v!;
                        if (niveis.indexOf(_alvo) < niveis.indexOf(_inicial)) _alvo = _inicial;
                      }),
                    ),
                  ),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      key: ValueKey(_alvo),
                      initialValue: _alvo,
                      decoration: const InputDecoration(labelText: 'Quero chegar a'),
                      items: [
                        for (final n in niveis.skip(niveis.indexOf(_inicial))) DropdownMenuItem(value: n, child: Text(n)),
                      ],
                      onChanged: (v) => setState(() => _alvo = v!),
                    ),
                  ),
                ],
              ),
              Text('${_minutos.round()} minutos por dia'),
              Slider(
                value: _minutos,
                min: 15,
                max: 180,
                divisions: 33,
                label: '${_minutos.round()}',
                onChanged: (v) => setState(() => _minutos = v),
              ),
              const Text('Dias de estudo'),
              Wrap(
                spacing: 4,
                children: [
                  for (var d = 1; d <= 7; d++)
                    FilterChip(
                      label: Text(_dias[d - 1]),
                      selected: _diasSel.contains(d),
                      onSelected: (s) => setState(() => s ? _diasSel.add(d) : _diasSel.remove(d)),
                    ),
                ],
              ),
              TextButton.icon(
                icon: const Icon(Icons.event),
                label: Text('Início: ${_curta(_inicio)} ${_inicio.year}'),
                onPressed: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: _inicio,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2100),
                  );
                  if (d != null) setState(() => _inicio = d);
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          onPressed: _diasSel.isEmpty
              ? null
              : () => Navigator.pop(context, {
                  if (widget.atual == null) 'idioma': _idioma,
                  'nivel_inicial': _inicial,
                  'nivel_alvo': _alvo,
                  'minutos_por_dia': _minutos.round(),
                  'dias_semana': _diasSel.toList()..sort(),
                  'inicio': iso(_inicio),
                }),
          child: const Text('Salvar'),
        ),
      ],
    );
  }
}
