import 'dart:async';
import 'dart:math';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_saude.dart';
import '../datas.dart';

void _avisar(BuildContext context, Object e) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));

// ---------------------------------------------------------------- hábitos

/// Hábitos a construir ou evitar, com a sequência de dias cumpridos.
class HabitosTela extends StatefulWidget {
  const HabitosTela({super.key, required this.api});

  final ApiSaude api;

  @override
  State<HabitosTela> createState() => _HabitosTelaState();
}

class _HabitosTelaState extends State<HabitosTela> {
  List<Map<String, dynamic>>? _habitos;
  DateTime _semana = inicioSemana(hoje());

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Future<void> _carregar() async {
    try {
      final h = await widget.api.habitos(_semana, somarDias(_semana, 6));
      if (mounted) setState(() => _habitos = h);
    } on ApiErro catch (e) {
      if (mounted) _avisar(context, e);
    }
  }

  Future<void> _acao(Future<void> Function() f) async {
    try {
      await f();
      await _carregar();
    } on ApiErro catch (e) {
      if (mounted) _avisar(context, e);
    }
  }

  Future<void> _novo([Map<String, dynamic>? atual]) async {
    final nome = TextEditingController(text: atual?['nome'] as String?);
    final descricao = TextEditingController(text: atual?['descricao'] as String?);
    var tipo = atual?['tipo'] as String? ?? 'construir';
    final dias = <int>{...(atual?['dias_semana'] as List? ?? const [1, 2, 3, 4, 5, 6, 7]).cast<int>()};
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(atual == null ? 'Novo hábito' : 'Editar hábito'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 10,
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'construir', icon: Icon(Icons.trending_up), label: Text('Construir')),
                    ButtonSegment(value: 'evitar', icon: Icon(Icons.block), label: Text('Evitar')),
                  ],
                  selected: {tipo},
                  onSelectionChanged: (s) => setState(() => tipo = s.first),
                ),
                TextField(
                  controller: nome,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'Hábito',
                    hintText: tipo == 'evitar' ? 'ex.: celular na cama' : 'ex.: ler 20 páginas',
                  ),
                ),
                TextField(
                  controller: descricao,
                  decoration: const InputDecoration(labelText: 'Gatilho / plano (quando, onde, como)'),
                ),
                Wrap(
                  spacing: 4,
                  children: [
                    for (var d = 1; d <= 7; d++)
                      FilterChip(
                        label: Text(diasSemana[d - 1]),
                        selected: dias.contains(d),
                        onSelected: (s) => setState(() => s ? dias.add(d) : dias.remove(d)),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            if (atual != null)
              TextButton(
                onPressed: () async {
                  Navigator.pop(context, false);
                  await _acao(() => widget.api.excluirHabito(atual['id'] as String));
                },
                child: const Text('Excluir'),
              ),
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Salvar')),
          ],
        ),
      ),
    );
    if (ok != true || nome.text.trim().isEmpty || dias.isEmpty) return;
    final dados = {
      'nome': nome.text.trim(),
      'descricao': descricao.text.trim(),
      'tipo': tipo,
      'dias_semana': dias.toList()..sort(),
    };
    await _acao(() => atual == null ? widget.api.criarHabito(dados) : widget.api.editarHabito(atual['id'] as String, dados));
  }

  @override
  Widget build(BuildContext context) {
    final habitos = _habitos;
    if (habitos == null) return const Center(child: CircularProgressIndicator());
    final tema = Theme.of(context);
    final dias = [for (var i = 0; i < 7; i++) somarDias(_semana, i)];
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _novo,
        icon: const Icon(Icons.add),
        label: const Text('Hábito'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () {
                  setState(() => _semana = somarDias(_semana, -7));
                  _carregar();
                },
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: () {
                  setState(() => _semana = somarDias(_semana, 7));
                  _carregar();
                },
              ),
              Text('Semana de ${diaCurto(_semana)}', style: tema.textTheme.titleSmall),
            ],
          ),
          if (habitos.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Comece com um hábito pequeno e um gatilho claro: "depois do café, leio 10 páginas". '
                'Hábitos a evitar contam os dias em que você resistiu.',
                textAlign: TextAlign.center,
              ),
            ),
          for (final h in habitos)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InkWell(
                      onTap: () => _novo(h),
                      child: Row(
                        children: [
                          Icon(h['tipo'] == 'evitar' ? Icons.block : Icons.trending_up, size: 18),
                          const SizedBox(width: 6),
                          Expanded(child: Text(h['nome'] as String, style: tema.textTheme.titleSmall)),
                          Text('🔥 ${h['sequencia']}', style: tema.textTheme.titleSmall),
                        ],
                      ),
                    ),
                    if ((h['descricao'] as String? ?? '').isNotEmpty)
                      Text(h['descricao'] as String, style: tema.textTheme.bodySmall),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        for (final d in dias)
                          Expanded(child: _diaHabito(h, d)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _diaHabito(Map<String, dynamic> h, DateTime d) {
    final previsto = (h['dias_semana'] as List).contains(d.weekday);
    final feito = (h['feitos'] as List).contains(iso(d));
    final futuro = d.isAfter(hoje());
    return Column(
      children: [
        Text(diasSemana[d.weekday - 1], style: Theme.of(context).textTheme.labelSmall),
        Checkbox(
          value: feito,
          onChanged: !previsto || futuro
              ? null
              : (v) => _acao(() => widget.api.marcarHabito(h['id'] as String, d, v ?? false)),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- foco

/// Foco contra a procrastinação (pomodoro) e os minutos por dia.
class FocoTela extends StatefulWidget {
  const FocoTela({super.key, required this.api});

  final ApiSaude api;

  @override
  State<FocoTela> createState() => _FocoTelaState();
}

class _FocoTelaState extends State<FocoTela> {
  final _tarefa = TextEditingController();
  int _minutosFoco = 25;
  int _minutosPausa = 5;
  bool _pausa = false;
  int _restante = 25 * 60;
  int _distracoes = 0;
  DateTime? _inicio;
  Timer? _timer;
  Map<String, dynamic>? _dados;

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _tarefa.dispose();
    super.dispose();
  }

  Future<void> _carregar() async {
    try {
      final d = await widget.api.foco(somarDias(hoje(), -6), hoje());
      if (mounted) setState(() => _dados = d);
    } on ApiErro catch (e) {
      if (mounted) _avisar(context, e);
    }
  }

  bool get _rodando => _timer != null;

  void _iniciar() {
    _inicio ??= DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_restante <= 1) {
        _terminar();
      } else {
        setState(() => _restante--);
      }
    });
    setState(() {});
  }

  void _parar() {
    _timer?.cancel();
    setState(() => _timer = null);
  }

  Future<void> _registrar({required bool concluida}) async {
    final inicio = _inicio;
    if (inicio == null || _pausa) return;
    final minutos = concluida ? _minutosFoco : (DateTime.now().difference(inicio).inMinutes);
    if (minutos < 1) return;
    try {
      await widget.api.registrarFoco({
        'minutos': minutos,
        'tarefa': _tarefa.text.trim(),
        'concluida': concluida,
        'distracoes': _distracoes,
        'inicio': inicio.toIso8601String().substring(0, 19),
      });
      await _carregar();
    } on ApiErro catch (e) {
      if (mounted) _avisar(context, e);
    }
  }

  Future<void> _terminar() async {
    _parar();
    SystemSound.play(SystemSoundType.alert);
    HapticFeedback.heavyImpact();
    final eraFoco = !_pausa;
    if (eraFoco) await _registrar(concluida: true);
    if (!mounted) return;
    setState(() {
      _pausa = eraFoco;
      _restante = (eraFoco ? _minutosPausa : _minutosFoco) * 60;
      _inicio = null;
      _distracoes = 0;
    });
    _avisar(context, eraFoco ? 'Bloco concluído! Pausa de $_minutosPausa min.' : 'Pausa encerrada. Bora para o próximo bloco.');
  }

  Future<void> _cancelar() async {
    _parar();
    await _registrar(concluida: false);
    setState(() {
      _pausa = false;
      _restante = _minutosFoco * 60;
      _inicio = null;
      _distracoes = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final total = (_pausa ? _minutosPausa : _minutosFoco) * 60;
    final mm = (_restante ~/ 60).toString().padLeft(2, '0');
    final ss = (_restante % 60).toString().padLeft(2, '0');
    final porDia = (_dados?['minutos_por_dia'] as Map? ?? const {}).cast<String, int>();
    final sessoesHoje = [
      for (final s in (_dados?['sessoes'] as List? ?? const []).cast<Map<String, dynamic>>())
        if ((s['inicio'] as String).startsWith(iso(hoje()))) s,
    ];
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        TextField(
          controller: _tarefa,
          enabled: !_rodando,
          decoration: const InputDecoration(
            labelText: 'No que vou focar agora (o menor próximo passo)',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        if (!_rodando && _inicio == null)
          Wrap(
            spacing: 6,
            alignment: WrapAlignment.center,
            children: [
              for (final (f, p) in const [(15, 3), (25, 5), (50, 10)])
                ChoiceChip(
                  label: Text('$f / $p min'),
                  selected: _minutosFoco == f,
                  onSelected: (_) => setState(() {
                    _minutosFoco = f;
                    _minutosPausa = p;
                    _pausa = false;
                    _restante = f * 60;
                  }),
                ),
            ],
          ),
        const SizedBox(height: 12),
        Center(
          child: SizedBox(
            width: 220,
            height: 220,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CircularProgressIndicator(
                  value: 1 - _restante / total,
                  strokeWidth: 10,
                  color: _pausa ? Colors.green : tema.colorScheme.primary,
                ),
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('$mm:$ss', style: tema.textTheme.displayMedium),
                      Text(_pausa ? 'pausa' : 'foco'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          alignment: WrapAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: _rodando ? _parar : _iniciar,
              icon: Icon(_rodando ? Icons.pause : Icons.play_arrow),
              label: Text(_rodando ? 'Pausar' : (_inicio == null ? 'Começar' : 'Continuar')),
            ),
            if (_inicio != null || _pausa)
              OutlinedButton.icon(onPressed: _cancelar, icon: const Icon(Icons.stop), label: const Text('Encerrar')),
            if (_rodando && !_pausa)
              OutlinedButton.icon(
                onPressed: () => setState(() => _distracoes++),
                icon: const Icon(Icons.notifications_paused_outlined),
                label: Text('Me distraí ($_distracoes)'),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Text('Hoje: ${porDia[iso(hoje())] ?? 0} min de foco em ${sessoesHoje.where((s) => s['concluida'] == true).length} blocos',
            style: tema.textTheme.titleSmall),
        const SizedBox(height: 8),
        SizedBox(height: 90, child: _Barras(valores: {for (var i = 6; i >= 0; i--) somarDias(hoje(), -i): (porDia[iso(somarDias(hoje(), -i))] ?? 0).toDouble()})),
        for (final s in sessoesHoje.reversed)
          ListTile(
            dense: true,
            leading: Icon(s['concluida'] == true ? Icons.check_circle_outline : Icons.cancel_outlined),
            title: Text((s['tarefa'] as String).isEmpty ? 'Sem tarefa' : s['tarefa'] as String),
            subtitle: Text('${(s['inicio'] as String).substring(11, 16)} · ${s['minutos']} min · ${s['distracoes']} distrações'),
          ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Contra a procrastinação: comece pelo passo de 2 minutos; deixe o celular em outro cômodo; '
              'anote a distração em vez de segui-la; ao fim do bloco, levante e respire antes do próximo.',
              style: tema.textTheme.bodySmall,
            ),
          ),
        ),
      ],
    );
  }
}

/// Barras simples por dia (rótulo do dia embaixo).
class _Barras extends StatelessWidget {
  const _Barras({required this.valores, this.maximo});

  final Map<DateTime, double> valores;
  final double? maximo;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final teto = maximo ?? max(1, valores.values.fold<double>(0, max));
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final MapEntry(key: d, value: v) in valores.entries)
          Expanded(
            child: Tooltip(
              message: '${diaCurto(d)}: ${v.round()}',
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Flexible(
                    child: FractionallySizedBox(
                      heightFactor: (v / teto).clamp(0.02, 1),
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        decoration: BoxDecoration(
                          color: tema.colorScheme.primary,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
                  if (valores.length <= 14) Text(diasSemana[d.weekday - 1], style: tema.textTheme.labelSmall),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------- ansiedade e humor

/// Respiração para a ansiedade e o diário do dia (humor, ansiedade, gatilhos, gratidão).
class AnsiedadeTela extends StatefulWidget {
  const AnsiedadeTela({super.key, required this.api});

  final ApiSaude api;

  @override
  State<AnsiedadeTela> createState() => _AnsiedadeTelaState();
}

class _AnsiedadeTelaState extends State<AnsiedadeTela> {
  List<Map<String, dynamic>> _historico = const [];
  int? _humor;
  double _ansiedade = 3;
  final _gatilhos = TextEditingController();
  final _oQueFiz = TextEditingController();
  final _gratidao = TextEditingController();

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  @override
  void dispose() {
    for (final c in [_gatilhos, _oQueFiz, _gratidao]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _carregar() async {
    try {
      final h = await widget.api.diario(somarDias(hoje(), -29), hoje());
      if (!mounted) return;
      final dia = h.where((d) => d['data'] == iso(hoje())).firstOrNull;
      setState(() {
        _historico = h;
        if (dia != null) {
          _humor = dia['humor'] as int?;
          _ansiedade = ((dia['ansiedade'] as int?) ?? 3).toDouble();
          _gatilhos.text = dia['gatilhos'] as String? ?? '';
          _oQueFiz.text = dia['o_que_fiz'] as String? ?? '';
          _gratidao.text = dia['gratidao'] as String? ?? '';
        }
      });
    } on ApiErro catch (e) {
      if (mounted) _avisar(context, e);
    }
  }

  Future<void> _salvar() async {
    try {
      await widget.api.salvarDia(hoje(), {
        'humor': ?_humor,
        'ansiedade': _ansiedade.round(),
        'gatilhos': _gatilhos.text.trim(),
        'o_que_fiz': _oQueFiz.text.trim(),
        'gratidao': _gratidao.text.trim(),
      });
      await _carregar();
      if (mounted) _avisar(context, 'Registro de hoje salvo');
    } on ApiErro catch (e) {
      if (mounted) _avisar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final porData = {for (final d in _historico) d['data']: d};
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Respiração guiada', style: tema.textTheme.titleMedium),
                const SizedBox(height: 8),
                const _Respiracao(),
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                Text('Como estou hoje', style: tema.textTheme.titleMedium),
                SegmentedButton<int>(
                  emptySelectionAllowed: true,
                  showSelectedIcon: false,
                  segments: [
                    for (final (n, e) in const [(1, '😞'), (2, '🙁'), (3, '😐'), (4, '🙂'), (5, '😄')])
                      ButtonSegment(value: n, label: Text(e, style: const TextStyle(fontSize: 20))),
                  ],
                  selected: {?_humor},
                  onSelectionChanged: (s) => setState(() => _humor = s.firstOrNull),
                ),
                Text('Ansiedade: ${_ansiedade.round()} de 10'),
                Slider(value: _ansiedade, max: 10, divisions: 10, label: '${_ansiedade.round()}', onChanged: (v) => setState(() => _ansiedade = v)),
                TextField(controller: _gatilhos, decoration: const InputDecoration(labelText: 'O que disparou (gatilhos, pensamentos)')),
                TextField(controller: _oQueFiz, decoration: const InputDecoration(labelText: 'O que fiz a respeito')),
                TextField(controller: _gratidao, decoration: const InputDecoration(labelText: 'Três coisas pelas quais sou grato')),
                Align(alignment: Alignment.centerRight, child: FilledButton(onPressed: _salvar, child: const Text('Salvar'))),
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                Text('Ansiedade nos últimos 30 dias', style: tema.textTheme.titleMedium),
                SizedBox(
                  height: 90,
                  child: _Barras(
                    maximo: 10,
                    valores: {
                      for (var i = 29; i >= 0; i--)
                        somarDias(hoje(), -i): ((porData[iso(somarDias(hoje(), -i))]?['ansiedade'] as int?) ?? 0).toDouble(),
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Respiração em fases (caixa 4-4-4-4 ou 4-7-8), com o círculo crescendo na inspiração.
class _Respiracao extends StatefulWidget {
  const _Respiracao();

  @override
  State<_Respiracao> createState() => _RespiracaoState();
}

class _RespiracaoState extends State<_Respiracao> {
  static const _tecnicas = {
    'Caixa 4-4-4-4': [('Inspire', 4), ('Segure', 4), ('Expire', 4), ('Segure', 4)],
    '4-7-8': [('Inspire', 4), ('Segure', 7), ('Expire', 8)],
  };
  String _tecnica = 'Caixa 4-4-4-4';
  Timer? _timer;
  int _fase = 0;
  int _segundo = 0;
  int _ciclos = 0;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _alternar() {
    if (_timer != null) {
      _timer!.cancel();
      return setState(() => _timer = null);
    }
    setState(() {
      _fase = 0;
      _segundo = 0;
      _ciclos = 0;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final fases = _tecnicas[_tecnica]!;
      setState(() {
        _segundo++;
        if (_segundo >= fases[_fase].$2) {
          _segundo = 0;
          _fase = (_fase + 1) % fases.length;
          if (_fase == 0) _ciclos++;
          HapticFeedback.selectionClick();
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final fases = _tecnicas[_tecnica]!;
    final (rotulo, duracao) = fases[_fase];
    // tamanho do círculo: cresce ao inspirar, encolhe ao expirar, parado ao segurar
    final progresso = (_segundo + 1) / duracao;
    final tamanho = switch (rotulo) {
      'Inspire' => 0.4 + 0.6 * progresso,
      'Expire' => 1.0 - 0.6 * progresso,
      _ => _fase == 1 ? 1.0 : 0.4,
    };
    final ativo = _timer != null;
    final cor = Theme.of(context).colorScheme.primary;
    return Column(
      children: [
        Wrap(
          spacing: 6,
          children: [
            for (final t in _tecnicas.keys)
              ChoiceChip(
                label: Text(t),
                selected: _tecnica == t,
                onSelected: ativo ? null : (_) => setState(() => _tecnica = t),
              ),
          ],
        ),
        SizedBox(
          height: 180,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 950),
              curve: Curves.easeInOut,
              width: 160 * (ativo ? tamanho : 0.5),
              height: 160 * (ativo ? tamanho : 0.5),
              decoration: BoxDecoration(shape: BoxShape.circle, color: cor.withValues(alpha: 0.35), border: Border.all(color: cor, width: 2)),
              alignment: Alignment.center,
              child: Text(ativo ? '$rotulo\n${duracao - _segundo}' : '', textAlign: TextAlign.center),
            ),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 12,
          children: [
            FilledButton.icon(
              onPressed: _alternar,
              icon: Icon(ativo ? Icons.stop : Icons.air),
              label: Text(ativo ? 'Parar' : 'Começar'),
            ),
            Text('$_ciclos ciclos'),
          ],
        ),
      ],
    );
  }
}
