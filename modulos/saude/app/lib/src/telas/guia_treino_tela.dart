import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../api_saude.dart';
import '../aviso_treino.dart';
import '../datas.dart';
import '../health_connect.dart';
import '../modelos.dart';
import '../sessao.dart';
import 'comuns.dart';

/// Abre o guia do treino de [dia] (ou continua o que estiver em andamento). Devolve true se o treino
/// foi concluído ou descartado (a agenda precisa recarregar).
Future<bool> abrirGuiaTreino(BuildContext context, ApiSaude api, DateTime dia, Map<String, Exercicio> porId) async {
  final mensageiro = ScaffoldMessenger.of(context);
  final navegador = Navigator.of(context);
  try {
    final s = await api.sessaoAtiva() ?? await api.iniciarSessao(dia);
    final r = await navegador.push<bool>(
      MaterialPageRoute(builder: (_) => GuiaTreinoTela(api: api, sessao: s, porId: porId)),
    );
    return r ?? false;
  } on ApiErro catch (e) {
    mensageiro.showSnackBar(SnackBar(content: Text('$e')));
    return false;
  }
}

/// O treino passo a passo: série atual com repetições e carga, descanso cronometrado (pausar,
/// somar, pular) e, no fim, o resumo com a frequência cardíaca do relógio. Todo comando vai ao
/// servidor, que guarda o estado; a tela relê a cada 5 s para pegar o que vier de outro aparelho.
class GuiaTreinoTela extends StatefulWidget {
  const GuiaTreinoTela({super.key, required this.api, required this.sessao, required this.porId});

  final ApiSaude api;
  final SessaoTreino sessao;
  final Map<String, Exercicio> porId;

  @override
  State<GuiaTreinoTela> createState() => _GuiaTreinoTelaState();
}

class _GuiaTreinoTelaState extends State<GuiaTreinoTela> with WidgetsBindingObserver {
  late SessaoTreino _s = widget.sessao;
  Timer? _tique;
  Timer? _sinc;
  bool _ocupado = false;
  String _chaveSerie = '';
  int _reps = 10;
  double? _carga;
  String? _descansoAvisado;
  int _ultimoBip = -1;
  bool _buscandoFc = false;
  bool _naFrente = true;

  ApiSaude get api => widget.api;

  @override
  void initState() {
    super.initState();
    _prepararSerie();
    _tique = Timer.periodic(const Duration(seconds: 1), (_) => _aCadaSegundo());
    _sinc = Timer.periodic(const Duration(seconds: 5), (_) => _sincronizar());
    WakelockPlus.enable().catchError((_) {});
    WidgetsBinding.instance.addObserver(this);
    AvisoTreino.atualizar(_s, segundoPlano: false);
  }

  /// Saiu da frente (outro app, tela apagada): o fim do descanso vira alarme do sistema.
  @override
  void didChangeAppLifecycleState(AppLifecycleState estado) {
    _naFrente = estado == AppLifecycleState.resumed;
    AvisoTreino.atualizar(_s, segundoPlano: !_naFrente);
    if (_naFrente) _sincronizar();
  }

  @override
  void dispose() {
    _tique?.cancel();
    _sinc?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    // fechou o guia com o treino em andamento: o aviso continua por fora
    AvisoTreino.atualizar(_s, segundoPlano: true);
    WakelockPlus.disable().catchError((_) {});
    super.dispose();
  }

  void _definir(SessaoTreino s) {
    if (!mounted) return;
    setState(() => _s = s);
    _prepararSerie();
    AvisoTreino.atualizar(s, segundoPlano: !_naFrente);
  }

  /// Repetições e carga voltam ao sugerido quando muda o exercício ou a série.
  void _prepararSerie() {
    final e = _s.atual;
    final chave = '${_s.indice}:${e?.series.length}';
    if (e == null || chave == _chaveSerie) return;
    _chaveSerie = chave;
    _reps = e.repsIniciais;
    _carga = e.cargaInicial;
  }

  void _aCadaSegundo() {
    if (!mounted || _s.estado != 'andamento') return;
    final restante = _s.restanteDescanso();
    final ate = _s.controle['descanso_ate'] as String?;
    // em segundo plano quem avisa é o alarme do sistema (AvisoTreino)
    if (_naFrente && restante != null && !_s.pausado && ate != null) {
      if (restante <= 3 && restante > 0 && restante != _ultimoBip) {
        _ultimoBip = restante;
        SystemSound.play(SystemSoundType.click);
      }
      if (restante == 0 && _descansoAvisado != ate) {
        _descansoAvisado = ate;
        SystemSound.play(SystemSoundType.alert);
        HapticFeedback.heavyImpact();
        _sincronizar();
      }
    }
    setState(() {});
  }

  Future<void> _sincronizar() async {
    if (_ocupado || _s.estado != 'andamento') return;
    try {
      _definir(await api.sessao(_s.id));
    } on ApiErro {
      // sem rede por um instante: o próximo ciclo tenta de novo
    }
  }

  Future<void> _cmd(String acao, [Map<String, dynamic> dados = const {}]) async {
    if (_ocupado) return;
    setState(() => _ocupado = true);
    try {
      _definir(await api.comandoSessao(_s.id, acao, dados));
    } on ApiErro catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  void _serieFeita(ExercicioSessao e) {
    HapticFeedback.mediumImpact();
    _cmd('concluir_serie', {
      if (e.tempoMeta == null) 'repeticoes': _reps,
      if (e.tempoMeta != null) 'tempo_s': _s.tempoSerie(),
      'carga_kg': ?_carga,
    });
  }

  // --- fim ---

  Future<void> _concluir() async {
    final r = await showDialog<(int, String)>(context: context, builder: (_) => const _Fechamento());
    if (r == null || !mounted) return;
    setState(() => _ocupado = true);
    try {
      _definir(await api.concluirSessao(_s.id, {'esforco': r.$1, if (r.$2.isNotEmpty) 'notas': r.$2}));
    } on ApiErro catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
    // medida ao vivo no relógio já vale; senão, lê o Health Connect
    if (_s.estado == 'concluida' && !_s.fcDoRelogio) await _buscarFrequencia(silencioso: true);
  }

  Future<void> _buscarFrequencia({bool silencioso = false}) async {
    if (!LeitorHealthConnect.disponivel) return;
    setState(() => _buscandoFc = true);
    String? aviso;
    try {
      final leitor = LeitorHealthConnect();
      if (!await leitor.autorizado()) {
        aviso = 'Autorize o Health Connect em Sono e corpo.';
      } else {
        final fim = DateTime.parse(_s.j['fim'] as String? ?? DateTime.now().toUtc().toIso8601String());
        final fc = await leitor.frequencia(_s.inicio.toLocal(), fim.toLocal());
        if (fc == null) {
          aviso = 'O relógio ainda não mandou a frequência. Tente de novo em alguns minutos.';
        } else {
          _definir(await api.editarSessao(_s.id, {'frequencia': fc}));
        }
      }
    } catch (e) {
      aviso = '$e';
    } finally {
      if (mounted) setState(() => _buscandoFc = false);
    }
    if (aviso != null && !silencioso && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(aviso)));
    }
  }

  Future<void> _descartar() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Descartar o treino?'),
        content: const Text('As séries registradas nesta sessão serão apagadas.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Descartar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await api.excluirSessao(_s.id);
      if (mounted) Navigator.pop(context, true);
    } on ApiErro catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _escolherDescanso() async {
    final s = await showDialog<int>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Descanso entre séries'),
        children: [
          for (final v in const [30, 45, 60, 90, 120, 180])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, v),
              child: Text(relogio(v), style: TextStyle(fontWeight: v == _s.descansoS ? FontWeight.bold : null)),
            ),
        ],
      ),
    );
    if (s != null) await _cmd('descanso_padrao', {'segundos': s});
  }

  // --- tela ---

  @override
  Widget build(BuildContext context) {
    final andamento = _s.estado == 'andamento';
    return Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Treino · ${diaCurto(_s.data)}'),
              Text(
                '${relogio(_s.ativo().inSeconds)}${_s.pausado ? ' · pausado' : ''}'
                '${_s.fcAtual() == null ? '' : ' · ♥ ${_s.fcAtual()} bpm'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            if (andamento)
              IconButton(
                tooltip: _s.pausado ? 'Continuar treino' : 'Pausar treino',
                icon: Icon(_s.pausado ? Icons.play_arrow : Icons.pause),
                onPressed: () => _cmd(_s.pausado ? 'continuar' : 'pausar'),
              ),
            if (andamento)
              PopupMenuButton<String>(
                onSelected: (v) => switch (v) {
                  'descanso' => _escolherDescanso(),
                  'pular' => _cmd('pular_exercicio'),
                  'desfazer' => _cmd('desfazer_serie'),
                  'concluir' => _concluir(),
                  'descartar' => _descartar(),
                  _ => null,
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'descanso', child: Text('Descanso: ${relogio(_s.descansoS)}')),
                  const PopupMenuItem(value: 'pular', child: Text('Pular este exercício')),
                  const PopupMenuItem(value: 'desfazer', child: Text('Desfazer última série')),
                  const PopupMenuItem(value: 'concluir', child: Text('Encerrar treino agora')),
                  const PopupMenuItem(value: 'descartar', child: Text('Descartar treino')),
                ],
              ),
          ],
        ),
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LinearProgressIndicator(
                value: _s.seriesPlanejadas == 0 ? 0 : _s.seriesFeitas / _s.seriesPlanejadas,
              ),
              if (andamento) _trilha(),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: ListView(padding: const EdgeInsets.all(16), children: _conteudo()),
                  ),
                ),
              ),
            ],
          ),
        ),
    );
  }

  /// Os exercícios do dia em fila; tocar leva até ele.
  Widget _trilha() => SizedBox(
    height: 48,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      children: [
        for (final e in _s.exercicios)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ChoiceChip(
              selected: e.indice == _s.indice,
              avatar: e.completo ? const Icon(Icons.check, size: 16) : null,
              label: Text('${e.nome} ${e.series.length}/${e.planejadas}'),
              onSelected: _ocupado || e.indice == _s.indice ? null : (_) => _cmd('ir_para', {'indice': e.indice}),
            ),
          ),
      ],
    ),
  );

  List<Widget> _conteudo() {
    if (_s.estado == 'concluida') return [_resumo()];
    final pausa = _s.pausado
        ? Card(
            color: Theme.of(context).colorScheme.tertiaryContainer,
            child: ListTile(
              leading: const Icon(Icons.pause_circle),
              title: const Text('Treino pausado'),
              trailing: FilledButton(onPressed: () => _cmd('continuar'), child: const Text('Continuar')),
            ),
          )
        : null;
    final corpo = switch (_s.fase()) {
      'descanso' => _descanso(),
      'fim' => _fim(),
      _ => _serie(),
    };
    return [?pausa, corpo];
  }

  Widget _descanso() {
    final tema = Theme.of(context);
    final restante = _s.restanteDescanso() ?? 0;
    final total = _s.descansoS < restante ? restante : _s.descansoS;
    final proximo = _s.atual;
    return Column(
      spacing: 16,
      children: [
        Text('Descanso', style: tema.textTheme.titleLarge),
        SizedBox.square(
          dimension: 220,
          child: Stack(
            fit: StackFit.expand,
            children: [
              CircularProgressIndicator(value: total == 0 ? 0 : restante / total, strokeWidth: 10),
              Center(child: Text(relogio(restante), style: tema.textTheme.displayMedium)),
            ],
          ),
        ),
        if (proximo != null)
          Text(
            'Próximo: ${proximo.nome} · série ${proximo.series.length + 1} de ${proximo.planejadas}',
            textAlign: TextAlign.center,
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 12,
          children: [
            OutlinedButton(onPressed: () => _cmd('somar_descanso', {'segundos': -15}), child: const Text('−15 s')),
            IconButton.filledTonal(
              iconSize: 32,
              tooltip: _s.pausado ? 'Continuar descanso' : 'Pausar descanso',
              icon: Icon(_s.pausado ? Icons.play_arrow : Icons.pause),
              onPressed: () => _cmd(_s.pausado ? 'continuar' : 'pausar'),
            ),
            OutlinedButton(onPressed: () => _cmd('somar_descanso', {'segundos': 30}), child: const Text('+30 s')),
          ],
        ),
        FilledButton.icon(
          onPressed: _ocupado ? null : () => _cmd('pular_descanso'),
          icon: const Icon(Icons.skip_next),
          label: const Text('Pular descanso'),
        ),
        _ultimasSeries(),
      ],
    );
  }

  Widget _serie() {
    final e = _s.atual;
    if (e == null) return _fim();
    final tema = Theme.of(context);
    final ex = widget.porId[e.exercicioId];
    final passo = (_carga ?? 0) >= 20 ? 2.5 : 1.0;
    final sug = e.sugestao;
    final anterior = e.anterior;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        if (ex != null && ex.temImagem)
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(height: 200, child: ImagemExercicio(api: api, exercicio: ex)),
          ),
        Text(e.nome, style: tema.textTheme.headlineSmall),
        Text(
          'Série ${e.series.length + 1} de ${e.planejadas} · meta ${e.repeticoes}'
          '${e.cargaPlanejada == null ? '' : ' · ${formatarCarga(e.cargaPlanejada!)} kg'}',
          style: tema.textTheme.titleMedium,
        ),
        if (anterior != null)
          Text(
            'Última vez (${diaCurto(DateTime.parse(anterior['data'] as String))}): '
            '${[for (final s in anterior['series'] as List) _textoSerie(s as Map<String, dynamic>)].join(' · ')}',
            style: tema.textTheme.bodySmall,
          ),
        if (sug != null && e.series.isEmpty)
          Card(
            color: tema.colorScheme.secondaryContainer,
            child: ListTile(
              leading: const Icon(Icons.trending_up),
              title: Text(sug['motivo'] as String),
              trailing: sug['carga_kg'] == null
                  ? null
                  : TextButton(
                      onPressed: () => setState(() => _carga = (sug['carga_kg'] as num).toDouble()),
                      child: Text('${formatarCarga((sug['carga_kg'] as num).toDouble())} kg'),
                    ),
            ),
          ),
        if (e.tempoMeta != null)
          Center(
            child: Text(
              '${relogio(_s.tempoSerie())} / ${relogio(e.tempoMeta!)}',
              style: tema.textTheme.displaySmall?.copyWith(
                color: _s.tempoSerie() >= e.tempoMeta! ? tema.colorScheme.primary : null,
              ),
            ),
          )
        else
          _Ajuste(
            rotulo: 'Repetições',
            valor: '$_reps',
            menos: _reps > 0 ? () => setState(() => _reps--) : null,
            mais: () => setState(() => _reps++),
          ),
        _Ajuste(
          rotulo: 'Carga',
          valor: _carga == null ? 'peso do corpo' : '${formatarCarga(_carga!)} kg',
          menos: _carga == null ? null : () => setState(() => _carga = _carga! - passo <= 0 ? null : _carga! - passo),
          mais: () => setState(() => _carga = (_carga ?? 0) + passo),
        ),
        if (e.instrucoes.isNotEmpty)
          ExpansionTile(
            title: const Text('Como fazer'),
            tilePadding: EdgeInsets.zero,
            children: [Text(e.instrucoes)],
          ),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(64)),
          onPressed: _ocupado || _s.pausado ? null : () => _serieFeita(e),
          icon: const Icon(Icons.check),
          label: const Text('Série feita'),
        ),
        _ultimasSeries(),
      ],
    );
  }

  Widget _fim() => Column(
    spacing: 16,
    children: [
      const Icon(Icons.emoji_events_outlined, size: 72),
      Text('Todos os exercícios feitos', style: Theme.of(context).textTheme.titleLarge),
      Text('${_s.seriesFeitas} séries em ${relogio(_s.ativo().inSeconds)}'),
      FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
        onPressed: _ocupado ? null : _concluir,
        icon: const Icon(Icons.flag),
        label: const Text('Concluir treino'),
      ),
      TextButton(onPressed: _ocupado ? null : () => _cmd('desfazer_serie'), child: const Text('Desfazer última série')),
    ],
  );

  Widget _resumo() {
    final tema = Theme.of(context);
    final r = _s.resumo ?? const {};
    final fc = _s.frequencia;
    String num(String k) => '${r[k] ?? '–'}'.replaceAll('.', ',');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        Text('Treino concluído', style: tema.textTheme.headlineSmall),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Chip(label: Text('${num('ativo_min')} min ativos')),
            Chip(label: Text('${r['series_feitas']}/${r['series_planejadas']} séries')),
            Chip(label: Text('${num('volume_kg')} kg de volume')),
            if (_s.j['esforco'] != null) Chip(label: Text('esforço ${_s.j['esforco']}/10')),
            if (fc != null) Chip(avatar: const Icon(Icons.favorite, size: 16), label: Text('FC média ${fc['media']} · máx ${fc['maxima']}')),
          ],
        ),
        for (final e in _s.exercicios)
          if (e.series.isNotEmpty)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(e.nome),
              subtitle: Text([for (final s in e.series) _textoSerie(s)].join(' · ')),
            ),
        if (LeitorHealthConnect.disponivel && fc == null)
          OutlinedButton.icon(
            onPressed: _buscandoFc ? null : _buscarFrequencia,
            icon: const Icon(Icons.watch),
            label: Text(_buscandoFc ? 'Lendo o relógio…' : 'Buscar frequência cardíaca do relógio'),
          ),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Fechar')),
      ],
    );
  }

  Widget _ultimasSeries() {
    final e = _s.atual;
    if (e == null || e.series.isEmpty) return const SizedBox.shrink();
    return Text(
      'Feitas: ${[for (final s in e.series) _textoSerie(s)].join(' · ')}',
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodySmall,
    );
  }
}

/// "10 × 40 kg", "12" ou "0:30".
String _textoSerie(Map<String, dynamic> s) {
  final carga = (s['carga_kg'] as num?)?.toDouble();
  final base = s['tempo_s'] != null ? relogio(s['tempo_s'] as int) : '${s['repeticoes'] ?? '?'}';
  final fc = s['fc_max'] == null ? '' : ' ♥${s['fc_max']}';
  return '${carga == null ? base : '$base × ${formatarCarga(carga)} kg'}$fc';
}

class _Ajuste extends StatelessWidget {
  const _Ajuste({required this.rotulo, required this.valor, this.menos, this.mais});

  final String rotulo;
  final String valor;
  final VoidCallback? menos;
  final VoidCallback? mais;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: Text(rotulo, style: Theme.of(context).textTheme.titleMedium)),
      IconButton.outlined(iconSize: 28, onPressed: menos, icon: const Icon(Icons.remove)),
      SizedBox(
        width: 130,
        child: Text(valor, textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
      ),
      IconButton.outlined(iconSize: 28, onPressed: mais, icon: const Icon(Icons.add)),
    ],
  );
}

/// Esforço percebido (1–10) e notas ao fechar o treino.
class _Fechamento extends StatefulWidget {
  const _Fechamento();

  @override
  State<_Fechamento> createState() => _FechamentoState();
}

class _FechamentoState extends State<_Fechamento> {
  double _esforco = 7;
  final _notas = TextEditingController();

  @override
  void dispose() {
    _notas.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Como foi o treino?'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Esforço: ${_esforco.round()}/10'),
        Slider(value: _esforco, min: 1, max: 10, divisions: 9, onChanged: (v) => setState(() => _esforco = v)),
        TextField(controller: _notas, decoration: const InputDecoration(labelText: 'Notas (opcional)'), maxLines: 3),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Voltar')),
      FilledButton(
        onPressed: () => Navigator.pop(context, (_esforco.round(), _notas.text.trim())),
        child: const Text('Concluir'),
      ),
    ],
  );
}
