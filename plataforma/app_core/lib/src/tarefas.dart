import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';

enum EstadoTarefa { rodando, pronta, erro, cancelada }

/// Trabalho demorado (download, importação) que roda sem prender a tela; aparece no sino.
class TarefaFundo {
  TarefaFundo._(this.titulo, this._dono);

  final String titulo;
  final Tarefas _dono;
  final inicio = DateTime.now();
  DateTime? fim;
  EstadoTarefa estado = EstadoTarefa.rodando;
  String detalhe = '';

  /// 0 a 1; nulo quando não dá para medir.
  double? progresso;
  String? erro;
  bool cancelada = false;

  /// "Abrir" no sino e no aviso de concluída (ex.: abre o documento baixado).
  Future<void> Function(BuildContext context)? abrir;

  void atualizar({String? detalhe, double? progresso}) {
    if (detalhe != null) this.detalhe = detalhe;
    this.progresso = progresso ?? this.progresso;
    _dono._mudou();
  }

  /// Progresso de um download (bytes recebidos de [total]).
  void bytes(int recebidos, int? total) => atualizar(
    detalhe: total == null ? _mb(recebidos) : '${_mb(recebidos)} de ${_mb(total)}',
    progresso: total == null || total == 0 ? null : recebidos / total,
  );

  static String _mb(int b) => '${(b / (1 << 20)).toStringAsFixed(1)} MB';

  void cancelar() {
    cancelada = true;
    _dono._mudou();
  }

  /// Para o trabalho na próxima checagem (usar entre etapas e nos downloads).
  void conferir() {
    if (cancelada) throw ApiErro(0, 'Cancelado.');
  }
}

/// Central das tarefas em segundo plano do app (uma só). O sino ([SinoTarefas]) mostra as que
/// estão rodando e o histórico da sessão; ao terminar, um aviso oferece "Abrir".
class Tarefas extends ChangeNotifier {
  Tarefas._();

  static final instancia = Tarefas._();

  /// Ligadas no `MaterialApp`: o aviso de concluída e o "Abrir" funcionam de qualquer tela.
  static final navegador = GlobalKey<NavigatorState>();
  static final mensagens = GlobalKey<ScaffoldMessengerState>();

  final lista = <TarefaFundo>[];

  /// Terminadas desde a última vez que o sino foi aberto.
  int novas = 0;

  int get rodando => lista.where((t) => t.estado == EstadoTarefa.rodando).length;

  void _mudou() => notifyListeners();

  /// Começa [trabalho] em segundo plano e devolve na hora. [abrir], se vier, recebe o resultado e
  /// vira o botão "Abrir".
  TarefaFundo rodar<T>(
    String titulo,
    Future<T> Function(TarefaFundo t) trabalho, {
    Future<void> Function(BuildContext context, T resultado)? abrir,
  }) {
    final t = TarefaFundo._(titulo, this);
    lista.insert(0, t);
    if (lista.length > 50) lista.removeLast();
    notifyListeners();
    unawaited(_executar(t, trabalho, abrir));
    return t;
  }

  Future<void> _executar<T>(
    TarefaFundo t,
    Future<T> Function(TarefaFundo t) trabalho,
    Future<void> Function(BuildContext context, T resultado)? abrir,
  ) async {
    try {
      final r = await trabalho(t);
      t.estado = t.cancelada ? EstadoTarefa.cancelada : EstadoTarefa.pronta;
      if (abrir != null) t.abrir = (c) => abrir(c, r);
    } catch (e) {
      t.estado = t.cancelada ? EstadoTarefa.cancelada : EstadoTarefa.erro;
      t.erro = e is ApiErro ? e.mensagem : '$e';
    }
    t.fim = DateTime.now();
    if (t.estado == EstadoTarefa.pronta) t.progresso = 1;
    if (t.estado != EstadoTarefa.cancelada) {
      novas++;
      _avisar(t);
    }
    notifyListeners();
  }

  void _avisar(TarefaFundo t) {
    final abrir = t.abrir;
    mensagens.currentState?.showSnackBar(
      SnackBar(
        content: Text(t.estado == EstadoTarefa.pronta
            ? 'Pronto: ${t.titulo}${t.detalhe.isEmpty ? '' : ' — ${t.detalhe}'}'
            : 'Falhou: ${t.titulo} — ${t.erro}'),
        action: abrir == null
            ? null
            : SnackBarAction(
                label: 'Abrir',
                onPressed: () {
                  final c = navegador.currentContext;
                  if (c != null) abrir(c);
                },
              ),
      ),
    );
  }

  void limparConcluidas() {
    lista.removeWhere((t) => t.estado != EstadoTarefa.rodando);
    notifyListeners();
  }

  void _visto() {
    novas = 0;
    notifyListeners();
  }
}

/// Sino da barra do app: número das tarefas rodando (ou um ponto quando alguma terminou) e, ao
/// tocar, a lista com andamento, cancelar e abrir.
class SinoTarefas extends StatelessWidget {
  const SinoTarefas({super.key});

  @override
  Widget build(BuildContext context) {
    final tarefas = Tarefas.instancia;
    return ListenableBuilder(
      listenable: tarefas,
      builder: (context, _) => IconButton(
        tooltip: 'Tarefas em segundo plano',
        onPressed: () => abrir(context),
        icon: Badge(
          isLabelVisible: tarefas.rodando > 0 || tarefas.novas > 0,
          label: tarefas.rodando > 0 ? Text('${tarefas.rodando}') : null,
          child: Icon(tarefas.rodando > 0 ? Icons.notifications_active_outlined : Icons.notifications_none),
        ),
      ),
    );
  }

  /// Folha com as tarefas da sessão (também aberta pela barra inferior do celular).
  static void abrir(BuildContext context) {
    final tarefas = Tarefas.instancia.._visto();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => ListenableBuilder(
        listenable: tarefas,
        builder: (c, _) => ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('Tarefas'),
                subtitle: Text(tarefas.rodando > 0 ? '${tarefas.rodando} em andamento' : 'Nada rodando agora'),
                trailing: TextButton(onPressed: tarefas.limparConcluidas, child: const Text('Limpar concluídas')),
              ),
              if (tarefas.lista.isEmpty)
                const Padding(padding: EdgeInsets.all(24), child: Text('Nenhuma tarefa nesta sessão.')),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [for (final t in tarefas.lista) _LinhaTarefa(t)],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LinhaTarefa extends StatelessWidget {
  const _LinhaTarefa(this.t);

  final TarefaFundo t;

  static String _hora(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    final (icone, cor) = switch (t.estado) {
      EstadoTarefa.rodando => (Icons.downloading, cores.primary),
      EstadoTarefa.pronta => (Icons.check_circle_outline, cores.primary),
      EstadoTarefa.erro => (Icons.error_outline, cores.error),
      EstadoTarefa.cancelada => (Icons.cancel_outlined, cores.outline),
    };
    final abrir = t.abrir;
    return ListTile(
      leading: Icon(icone, color: cor),
      title: Text(t.titulo, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 4,
        children: [
          Text(
            [
              _hora(t.inicio),
              switch (t.estado) {
                EstadoTarefa.rodando => t.detalhe,
                EstadoTarefa.pronta => 'concluída às ${_hora(t.fim!)}',
                EstadoTarefa.erro => t.erro ?? 'erro',
                EstadoTarefa.cancelada => 'cancelada',
              },
            ].where((s) => s.isNotEmpty).join(' · '),
          ),
          if (t.estado == EstadoTarefa.rodando) LinearProgressIndicator(value: t.progresso),
        ],
      ),
      trailing: switch (t.estado) {
        EstadoTarefa.rodando => IconButton(tooltip: 'Cancelar', icon: const Icon(Icons.close), onPressed: t.cancelar),
        EstadoTarefa.pronta when abrir != null => TextButton(
          onPressed: () {
            Navigator.pop(context);
            final c = Tarefas.navegador.currentContext ?? context;
            abrir(c);
          },
          child: const Text('Abrir'),
        ),
        _ => null,
      },
    );
  }
}
