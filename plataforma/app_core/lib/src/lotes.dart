import 'package:flutter/material.dart';

/// Ação em massa sobre listas: divide [itens] em lotes de [tamanho] e roda [acao] um lote por vez,
/// com uma janela de progresso ("120 de 800") e botão para parar entre um lote e outro. Assim
/// selecionar tudo e excluir/categorizar milhares de linhas não estoura o servidor nem trava o app.
/// Devolve quantos itens foram processados; um erro fecha a janela e sobe para quem chamou.
Future<int> executarEmLotes<T>(
  BuildContext context,
  String titulo,
  List<T> itens,
  Future<void> Function(List<T> lote) acao, {
  int tamanho = 100,
}) async {
  final feitos = ValueNotifier(0);
  var parar = false;
  final navegador = Navigator.of(context, rootNavigator: true);
  final janela = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(titulo),
        content: ValueListenableBuilder(
          valueListenable: feitos,
          builder: (_, n, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LinearProgressIndicator(value: itens.isEmpty ? null : n / itens.length),
              const SizedBox(height: 12),
              Text('$n de ${itens.length}'),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => parar = true, child: const Text('Parar'))],
      ),
    ),
  );
  try {
    for (var i = 0; i < itens.length && !parar; i += tamanho) {
      final lote = itens.sublist(i, (i + tamanho).clamp(0, itens.length));
      await acao(lote);
      feitos.value += lote.length;
    }
    return feitos.value;
  } finally {
    navegador.pop();
    await janela;
    feitos.dispose();
  }
}

/// Caixa "selecionar todos" para o cabeçalho de listas: marcada quando todos os [ids] estão em
/// [selecionados], traço quando só alguns; tocar marca todos ou limpa.
class MarcarTodos extends StatelessWidget {
  const MarcarTodos({super.key, required this.ids, required this.selecionados, required this.mudou});

  final Iterable<String> ids;
  final Set<String> selecionados;
  final void Function(Set<String> novos) mudou;

  @override
  Widget build(BuildContext context) {
    final todos = ids.toSet();
    final marcados = todos.where(selecionados.contains).length;
    final valor = marcados == 0 ? false : (marcados == todos.length ? true : null);
    return Checkbox(
      tristate: true,
      value: valor,
      onChanged: todos.isEmpty ? null : (_) => mudou(valor == true ? {} : todos),
    );
  }
}
