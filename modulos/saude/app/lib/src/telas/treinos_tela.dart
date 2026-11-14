import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../api_saude.dart';
import '../datas.dart';
import '../modelos.dart';
import 'biblioteca_exercicios.dart';
import 'calendario.dart';
import 'comuns.dart';
import 'dialogos.dart';
import 'guia_treino_tela.dart';

enum Visao { dia, semana, mes }

/// Montagem do treino: calendário (dia, semana ou mês) e, à direita (ou embaixo no celular), a
/// biblioteca de exercícios por área do corpo para arrastar até o dia.
class TreinosTela extends StatefulWidget {
  const TreinosTela({super.key, required this.api});

  final ApiSaude api;

  @override
  State<TreinosTela> createState() => _TreinosTelaState();
}

class _TreinosTelaState extends State<TreinosTela> {
  ApiSaude get api => widget.api;

  List<String> _areas = const [];
  List<Exercicio> _exercicios = const [];
  Map<String, Exercicio> _porId = const {};
  List<ItemAgenda> _itens = const [];
  final _versoes = <String, int>{};
  Visao _visao = Visao.semana;
  DateTime _foco = hoje();
  bool _bibliotecaAberta = false;
  String? _erro;
  bool _carregando = true;

  @override
  void initState() {
    super.initState();
    _carregarTudo();
  }

  (DateTime, DateTime) get _janela => switch (_visao) {
    Visao.dia => (_foco, _foco),
    Visao.semana => (inicioSemana(_foco), somarDias(inicioSemana(_foco), 6)),
    Visao.mes => (gradeMes(_foco).first, gradeMes(_foco).last),
  };

  Future<void> _tentar(Future<void> Function() acao) async {
    try {
      await acao();
      if (_erro != null) setState(() => _erro = null);
    } on ApiErro catch (e) {
      if (!mounted) return;
      if (_carregando) {
        setState(() => _erro = '$e');
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted && _carregando) setState(() => _carregando = false);
    }
  }

  Future<void> _carregarTudo() => _tentar(() async {
    final (areas, exercicios) = await api.exercicios();
    _definirExercicios(areas, exercicios);
    await _carregarAgenda();
  });

  void _definirExercicios(List<String> areas, List<Exercicio> exercicios) => setState(() {
    _areas = areas;
    _exercicios = exercicios;
    _porId = {for (final e in exercicios) e.id: e};
  });

  Future<void> _recarregarExercicios() async {
    final (areas, exercicios) = await api.exercicios();
    _definirExercicios(areas, exercicios);
  }

  Future<void> _carregarAgenda() async {
    final (de, ate) = _janela;
    final itens = await api.agenda(de, ate);
    if (mounted) setState(() => _itens = itens);
  }

  void _navegar(DateTime foco, [Visao? visao]) {
    setState(() {
      _foco = dia(foco);
      _visao = visao ?? _visao;
    });
    _tentar(_carregarAgenda);
  }

  void _passo(int sentido) => _navegar(switch (_visao) {
    Visao.dia => somarDias(_foco, sentido),
    Visao.semana => somarDias(_foco, 7 * sentido),
    Visao.mes => DateTime(_foco.year, _foco.month + sentido),
  });

  List<ItemAgenda> _doDia(DateTime d) => [for (final i in _itens) if (mesmoDia(i.data, d)) i];

  void _trocarItem(ItemAgenda novo) => setState(() => _itens = [for (final i in _itens) i.id == novo.id ? novo : i]);

  Future<void> _marcar(Exercicio e, DateTime d) => _tentar(() async {
    final item = await api.marcar(d, e.id);
    setState(() => _itens = [..._itens, item]);
  });

  Future<void> _soltar(Arrasto a, DateTime d) => switch (a) {
    ArrastoExercicio(:final exercicio) => _marcar(exercicio, d),
    ArrastoItem(:final item) when mesmoDia(item.data, d) => Future.value(),
    ArrastoItem(:final item) => _tentar(() async {
      final ordem = _doDia(d).fold(-1, (m, i) => i.ordem > m ? i.ordem : m) + 1;
      _trocarItem(await api.editarItem(item.id, {'data': iso(d), 'ordem': ordem}));
    }),
  };

  Future<void> _alternarFeito(ItemAgenda i) =>
      _tentar(() async => _trocarItem(await api.editarItem(i.id, {'feito': !i.feito})));

  Future<void> _reordenar(List<String> ids) => _tentar(() async {
    final novos = await Future.wait([for (final (n, id) in ids.indexed) api.editarItem(id, {'ordem': n})]);
    setState(() {
      final porId = {for (final i in novos) i.id: i};
      _itens = [for (final i in _itens) porId[i.id] ?? i]..sort((a, b) => a.ordem.compareTo(b.ordem));
    });
  });

  Future<void> _abrirItem(ItemAgenda i) async {
    final r = await editarItem(context, i, _porId[i.exercicioId]);
    switch (r) {
      case ItemAlterado(:final dados):
        await _tentar(() async => _trocarItem(await api.editarItem(i.id, dados)));
      case ItemExcluido():
        await _tentar(() async {
          await api.desmarcar(i.id);
          setState(() => _itens = [for (final x in _itens) if (x.id != i.id) x]);
        });
      case null:
    }
  }

  Future<void> _enviarFoto(String id, Foto foto) async {
    await api.enviarImagem(id, foto.nome, foto.bytes);
    _versoes[id] = (_versoes[id] ?? 0) + 1;
  }

  Future<void> _criarExercicio() async {
    final r = await formularioExercicio(context, _areas);
    if (r == null) return;
    final (dados, foto) = r;
    await _tentar(() async {
      final novo = await api.criarExercicio(dados);
      if (foto != null) await _enviarFoto(novo.id, foto);
      await _recarregarExercicios();
    });
  }

  Future<void> _abrirExercicio(Exercicio e) async {
    final acao = await detalhesExercicio(context, api, e, _versoes[e.id] ?? 0);
    if (!mounted) return;
    switch (acao) {
      case AcaoExercicio.marcar:
        await _marcar(e, _foco);
      case AcaoExercicio.editar:
        final r = await formularioExercicio(context, _areas, atual: e);
        if (r == null) return;
        await _tentar(() async {
          await api.editarExercicio(e.id, r.$1);
          if (r.$2 != null) await _enviarFoto(e.id, r.$2!);
          await _recarregarExercicios();
        });
      case AcaoExercicio.trocarFoto:
        final foto = await escolherFoto();
        if (foto == null) return;
        await _tentar(() async {
          await _enviarFoto(e.id, foto);
          await _recarregarExercicios();
        });
      case AcaoExercicio.removerFoto:
        await _tentar(() async {
          await api.removerImagem(e.id);
          _versoes[e.id] = (_versoes[e.id] ?? 0) + 1;
          await _recarregarExercicios();
        });
      case AcaoExercicio.excluir:
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text('Excluir "${e.nome}"?'),
            content: const Text('Ele também sai de todos os dias em que estiver marcado.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Excluir')),
            ],
          ),
        );
        if (ok != true) return;
        await _tentar(() async {
          await api.excluirExercicio(e.id);
          await _recarregarExercicios();
          await _carregarAgenda();
        });
      case null:
    }
  }

  Future<void> _repetirNaProxima() => _tentar(() async {
    final (de, ate) = switch (_visao) {
      Visao.dia => (_foco, _foco),
      _ => (inicioSemana(_foco), somarDias(inicioSemana(_foco), 6)),
    };
    final destino = somarDias(de, _visao == Visao.dia ? 1 : 7);
    await api.copiar(de, ate, destino);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copiado para ${_visao == Visao.dia ? diaLongo(destino) : 'a semana de ${diaCurto(destino)}'}')),
    );
    await _carregarAgenda();
  });

  /// Guia do treino: do dia aberto na visão Dia, senão de hoje.
  Future<void> _treinar() async {
    final d = _visao == Visao.dia ? _foco : hoje();
    if (await abrirGuiaTreino(context, api, d, _porId)) await _tentar(_carregarAgenda);
  }

  String get _titulo => switch (_visao) {
    Visao.dia => diaLongo(_foco),
    Visao.semana => '${diaCurto(inicioSemana(_foco))} – ${diaCurto(somarDias(inicioSemana(_foco), 6))}',
    Visao.mes => mesAno(_foco),
  };

  @override
  Widget build(BuildContext context) {
    if (_carregando) return const Center(child: CircularProgressIndicator());
    if (_erro != null && _exercicios.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            Text(_erro!),
            FilledButton(
              onPressed: () {
                setState(() => _carregando = true);
                _carregarTudo();
              },
              child: const Text('Tentar de novo'),
            ),
          ],
        ),
      );
    }
    final agenda = Agenda(
      api: api,
      itensDoDia: _doDia,
      exercicio: (id) => _porId[id],
      soltar: _soltar,
      abrirItem: _abrirItem,
      alternarFeito: _alternarFeito,
      abrirDia: (d) => _navegar(d, Visao.dia),
      versaoImagem: (id) => _versoes[id] ?? 0,
    );
    final calendario = switch (_visao) {
      Visao.dia => VistaDia(agenda: agenda, foco: _foco, reordenar: _reordenar),
      Visao.semana => VistaSemana(agenda: agenda, foco: _foco),
      Visao.mes => VistaMes(agenda: agenda, foco: _foco),
    };
    return LayoutBuilder(
      builder: (context, c) {
        final largo = c.maxWidth >= 900;
        BibliotecaExercicios biblioteca({VoidCallback? fechar}) => BibliotecaExercicios(
          api: api,
          areas: _areas,
          exercicios: _exercicios,
          versaoImagem: (id) => _versoes[id] ?? 0,
          adicionar: (e) => _marcar(e, _foco),
          abrir: _abrirExercicio,
          criar: _criarExercicio,
          fechar: fechar,
        );
        final principal = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _cabecalho(c.maxWidth < 600, mostrarBiblioteca: !largo),
            Expanded(child: Padding(padding: const EdgeInsets.all(6), child: calendario)),
            // celular/tablet em pé: biblioteca embaixo, para arrastar até o calendário de cima
            if (!largo && _bibliotecaAberta)
              SizedBox(
                height: c.maxHeight * 0.45,
                child: biblioteca(fechar: () => setState(() => _bibliotecaAberta = false)),
              ),
          ],
        );
        if (!largo) return principal;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: principal),
            const VerticalDivider(width: 1),
            SizedBox(width: c.maxWidth >= 1300 ? 380 : 320, child: biblioteca()),
          ],
        );
      },
    );
  }

  Widget _cabecalho(bool estreito, {required bool mostrarBiblioteca}) {
    final tema = Theme.of(context);
    final navegacao = [
      IconButton(tooltip: 'Anterior', icon: const Icon(Icons.chevron_left), onPressed: () => _passo(-1)),
      IconButton(tooltip: 'Próximo', icon: const Icon(Icons.chevron_right), onPressed: () => _passo(1)),
      TextButton(onPressed: () => _navegar(hoje()), child: const Text('Hoje')),
    ];
    final titulo = InkWell(
      onTap: () async {
        final d = await showDatePicker(
          context: context,
          initialDate: _foco,
          firstDate: DateTime(2020),
          lastDate: DateTime(2100),
        );
        if (d != null) _navegar(d);
      },
      child: Text(_titulo, style: tema.textTheme.titleMedium, overflow: TextOverflow.ellipsis),
    );
    final visoes = SegmentedButton<Visao>(
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(value: Visao.dia, label: Text('Dia')),
        ButtonSegment(value: Visao.semana, label: Text('Semana')),
        ButtonSegment(value: Visao.mes, label: Text('Mês')),
      ],
      selected: {_visao},
      onSelectionChanged: (s) => _navegar(_foco, s.first),
    );
    final acoes = [
      estreito
          ? IconButton.filled(tooltip: 'Treinar agora', icon: const Icon(Icons.play_arrow), onPressed: _treinar)
          : FilledButton.icon(onPressed: _treinar, icon: const Icon(Icons.play_arrow), label: const Text('Treinar')),
      PopupMenuButton<String>(
        tooltip: 'Mais',
        onSelected: (v) => switch (v) {
          'repetir' => _repetirNaProxima(),
          'novo' => _criarExercicio(),
          _ => null,
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'repetir',
            child: Text(_visao == Visao.dia ? 'Repetir este dia amanhã' : 'Repetir esta semana na próxima'),
          ),
          const PopupMenuItem(value: 'novo', child: Text('Novo exercício')),
        ],
      ),
      if (mostrarBiblioteca)
        IconButton.filledTonal(
          tooltip: 'Exercícios',
          isSelected: _bibliotecaAberta,
          icon: const Icon(Icons.fitness_center),
          onPressed: () => setState(() => _bibliotecaAberta = !_bibliotecaAberta),
        ),
    ];
    if (estreito) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [...navegacao, Expanded(child: titulo)]),
            Row(children: [Expanded(child: visoes), ...acoes]),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Row(
        spacing: 4,
        children: [...navegacao, Expanded(child: titulo), visoes, ...acoes],
      ),
    );
  }
}
