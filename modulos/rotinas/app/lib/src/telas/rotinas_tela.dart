import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_rotinas.dart';
import '../modelos.dart';
import 'assistente.dart';
import 'cartao_tarefa.dart';
import 'editor_tarefa.dart';

/// Kanban de rotinas. Celular (< 700): uma aba por coluna e o assistente em folha inferior.
/// Tablet/notebook: as três colunas lado a lado, com arrastar e soltar. PC (≥ 1200): o assistente
/// fica fixo à direita.
class RotinasTela extends StatefulWidget {
  const RotinasTela({super.key, required this.api});

  final ApiRotinas api;

  @override
  State<RotinasTela> createState() => _RotinasTelaState();
}

class _RotinasTelaState extends State<RotinasTela> {
  late final _conversa = ConversaAssistente(widget.api);
  List<Tarefa> _tarefas = [];
  Resumo? _resumo;
  DateTime _resumoEm = DateTime.now();
  String? _erro;
  bool _carregando = true;
  bool _assistenteAberto = true;
  DateTime _agora = DateTime.now();
  Timer? _relogio;

  @override
  void initState() {
    super.initState();
    _recarregar();
    _relogio = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_tarefas.any((t) => t.rodando)) setState(() => _agora = DateTime.now());
    });
  }

  @override
  void dispose() {
    _relogio?.cancel();
    _conversa.dispose();
    super.dispose();
  }

  Future<void> _recarregar() async {
    try {
      final (tarefas, resumo) = await (widget.api.listar(), widget.api.resumo()).wait;
      if (!mounted) return;
      setState(() {
        _tarefas = tarefas;
        _resumo = resumo;
        _resumoEm = _agora = DateTime.now();
        _erro = null;
        _carregando = false;
      });
    } on ParallelWaitError<(List<Tarefa>?, Resumo?), (AsyncError?, AsyncError?)> catch (e) {
      if (!mounted) return;
      setState(() {
        _erro = '${e.errors.$1?.error ?? e.errors.$2?.error}';
        _carregando = false;
      });
    }
  }

  /// Roda a ação na API e recarrega o quadro; falhas viram aviso.
  Future<void> _executar(Future<Object?> Function() acao) async {
    try {
      await acao();
    } on ApiErro catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
    await _recarregar();
  }

  Future<void> _nova([Coluna coluna = Coluna.pendente]) async {
    final dados = await editarTarefa(context);
    if (dados != null) await _executar(() => widget.api.criar({...dados, 'coluna': coluna.name}));
  }

  Future<void> _editar(Tarefa t) async {
    final dados = await editarTarefa(context, t);
    if (dados != null) await _executar(() => widget.api.salvar(t.id, dados));
  }

  Future<void> _excluir(Tarefa t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Excluir tarefa?'),
        content: Text(t.titulo),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Excluir')),
        ],
      ),
    );
    if (ok ?? false) await _executar(() => widget.api.excluir(t.id));
  }

  void _abrirAssistenteEmFolha() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (c) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(c).height * .8,
        child: Assistente(conversa: _conversa, aoFechar: () => Navigator.pop(c)),
      ),
    ),
  );

  List<Tarefa> _da(Coluna c) => [for (final t in _tarefas) if (t.coluna == c) t];

  Widget _cartao(Tarefa t) => CartaoTarefa(
    key: ValueKey(t.id),
    tarefa: t,
    agora: _agora,
    aoAlternarCronometro: () => _executar(() => widget.api.cronometro(t.id, t.rodando ? 'pausar' : 'iniciar')),
    aoEditar: () => _editar(t),
    aoMover: (c) => _executar(() => widget.api.mover(t.id, c)),
    aoZerar: () => _executar(() => widget.api.cronometro(t.id, 'zerar')),
    aoExcluir: () => _excluir(t),
  );

  @override
  Widget build(BuildContext context) {
    if (_carregando) return const Center(child: CircularProgressIndicator());
    if (_erro != null && _tarefas.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            Text(_erro!, textAlign: TextAlign.center),
            FilledButton.tonal(onPressed: _recarregar, child: const Text('Tentar de novo')),
          ],
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, c) {
        final celular = c.maxWidth < 700;
        final pc = c.maxWidth >= 1200;
        final barra = _Barra(
          resumo: _resumo,
          ativa: _tarefas.where((t) => t.rodando).firstOrNull,
          tempoHoje: _tempoHoje(),
          agora: _agora,
          compacta: celular,
          aoPausar: (t) => _executar(() => widget.api.cronometro(t.id, 'pausar')),
          aoNova: celular ? null : _nova,
          aoAssistente: pc ? () => setState(() => _assistenteAberto = !_assistenteAberto) : _abrirAssistenteEmFolha,
          aoRecarregar: _recarregar,
        );
        if (celular) return _celular(barra);
        return Column(
          children: [
            barra,
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final col in Coluna.values)
                    Expanded(
                      child: _ColunaKanban(
                        coluna: col,
                        tarefas: _da(col),
                        cartao: _cartao,
                        aoSoltar: (t, ordem) => _executar(() => widget.api.mover(t.id, col, ordem)),
                        aoNova: col == Coluna.concluida ? null : () => _nova(col),
                      ),
                    ),
                  if (pc && _assistenteAberto) ...[
                    const VerticalDivider(width: 1),
                    SizedBox(
                      width: 360,
                      child: Assistente(
                        conversa: _conversa,
                        aoFechar: () => setState(() => _assistenteAberto = false),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Duration _tempoHoje() {
    final hoje = _resumo?.tempoHoje ?? Duration.zero;
    return _tarefas.any((t) => t.rodando) ? hoje + _agora.difference(_resumoEm) : hoje;
  }

  Widget _celular(Widget barra) => DefaultTabController(
    length: Coluna.values.length,
    child: Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton(
        tooltip: 'Nova tarefa',
        onPressed: _nova,
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          barra,
          TabBar(
            // Rolável: "Em execução (12)" não cabe num terço dos 360 dp do celular.
            isScrollable: true,
            tabAlignment: TabAlignment.center,
            tabs: [
              for (final c in Coluna.values) Tab(text: '${c.rotulo} (${_resumo?.contagem[c] ?? _da(c).length})'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                for (final c in Coluna.values)
                  RefreshIndicator(
                    onRefresh: _recarregar,
                    child: _da(c).isEmpty
                        ? ListView(children: const [_Vazio()])
                        : ListView(
                            padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
                            children: [for (final t in _da(c)) _cartao(t)],
                          ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _Barra extends StatelessWidget {
  const _Barra({
    required this.resumo,
    required this.ativa,
    required this.tempoHoje,
    required this.agora,
    required this.compacta,
    required this.aoPausar,
    required this.aoNova,
    required this.aoAssistente,
    required this.aoRecarregar,
  });

  final Resumo? resumo;
  final Tarefa? ativa;
  final Duration tempoHoje;
  final DateTime agora;
  final bool compacta;
  final ValueChanged<Tarefa> aoPausar;
  final VoidCallback? aoNova;
  final VoidCallback aoAssistente;
  final VoidCallback aoRecarregar;

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    final a = ativa;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Chip(avatar: const Icon(Icons.today_outlined, size: 18), label: Text('Hoje: ${formatarDuracao(tempoHoje)}')),
                if (a != null)
                  InputChip(
                    avatar: Icon(Icons.timer, size: 18, color: cores.primary),
                    label: Text(
                      '${a.titulo} · ${formatarDuracao(a.tempoEm(agora), segundos: true)}',
                      overflow: TextOverflow.ellipsis,
                    ),
                    deleteIcon: const Icon(Icons.pause, size: 18),
                    deleteButtonTooltipMessage: 'Pausar',
                    onDeleted: () => aoPausar(a),
                  ),
              ],
            ),
          ),
          IconButton(tooltip: 'Atualizar', icon: const Icon(Icons.refresh), onPressed: aoRecarregar),
          if (compacta)
            IconButton(tooltip: 'Assistente', icon: const Icon(Icons.auto_awesome_outlined), onPressed: aoAssistente)
          else ...[
            OutlinedButton.icon(
              icon: const Icon(Icons.auto_awesome_outlined),
              label: const Text('Assistente'),
              onPressed: aoAssistente,
            ),
            const SizedBox(width: 8),
          ],
          if (aoNova != null)
            FilledButton.icon(icon: const Icon(Icons.add), label: const Text('Nova tarefa'), onPressed: aoNova),
        ],
      ),
    );
  }
}

class _ColunaKanban extends StatelessWidget {
  const _ColunaKanban({
    required this.coluna,
    required this.tarefas,
    required this.cartao,
    required this.aoSoltar,
    required this.aoNova,
  });

  final Coluna coluna;
  final List<Tarefa> tarefas;
  final Widget Function(Tarefa) cartao;

  /// Tarefa solta nesta coluna na posição dada (null = no fim).
  final void Function(Tarefa, int?) aoSoltar;
  final VoidCallback? aoNova;

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    // no toque (celular/tablet) o arraste começa com toque longo, para não brigar com a rolagem
    final toque = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
    return LayoutBuilder(
      builder: (context, c) => DragTarget<Tarefa>(
        onAcceptWithDetails: (d) => aoSoltar(d.data, null),
        builder: (context, candidatas, _) => Container(
          margin: const EdgeInsets.fromLTRB(8, 0, 0, 8),
          decoration: BoxDecoration(
            color: candidatas.isEmpty ? cores.surfaceContainerLowest : cores.primaryContainer.withValues(alpha: .25),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              ListTile(
                dense: true,
                title: Text(coluna.rotulo, style: Theme.of(context).textTheme.titleSmall),
                leading: Badge(label: Text('${tarefas.length}'), child: Icon(_icone, color: cores.primary)),
                trailing: aoNova == null
                    ? null
                    : IconButton(tooltip: 'Nova tarefa aqui', icon: const Icon(Icons.add), onPressed: aoNova),
              ),
              Expanded(
                child: tarefas.isEmpty
                    ? const _Vazio()
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(6, 0, 6, 24),
                        itemCount: tarefas.length,
                        itemBuilder: (context, i) {
                          final t = tarefas[i];
                          final arrastavel = _arrastavel(t, cartao(t), c.maxWidth - 28, toque);
                          return DragTarget<Tarefa>(
                            onWillAcceptWithDetails: (d) => d.data.id != t.id,
                            onAcceptWithDetails: (d) => aoSoltar(d.data, _ordemAoSoltar(d.data, i)),
                            builder: (context, sobre, _) => Column(
                              children: [
                                if (sobre.isNotEmpty)
                                  Container(height: 3, margin: const EdgeInsets.all(4), color: cores.primary),
                                arrastavel,
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Soltar sobre o cartão [i] coloca antes dele; na mesma coluna, quem vem de cima desconta a si mesma.
  int _ordemAoSoltar(Tarefa solta, int i) {
    final origem = tarefas.indexWhere((t) => t.id == solta.id);
    return origem >= 0 && origem < i ? i - 1 : i;
  }

  IconData get _icone => switch (coluna) {
    Coluna.pendente => Icons.inbox_outlined,
    Coluna.execucao => Icons.play_circle_outline,
    Coluna.concluida => Icons.task_alt,
  };

  Widget _arrastavel(Tarefa t, Widget filho, double largura, bool toque) {
    final fantasma = Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(width: largura, child: filho),
    );
    final apagado = Opacity(opacity: .35, child: filho);
    return toque
        ? LongPressDraggable<Tarefa>(data: t, feedback: fantasma, childWhenDragging: apagado, child: filho)
        : Draggable<Tarefa>(data: t, feedback: fantasma, childWhenDragging: apagado, child: filho);
  }
}

class _Vazio extends StatelessWidget {
  const _Vazio();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Text(
      'Nada aqui',
      textAlign: TextAlign.center,
      style: TextStyle(color: Theme.of(context).colorScheme.outline),
    ),
  );
}
