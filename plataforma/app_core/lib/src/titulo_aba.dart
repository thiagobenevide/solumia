import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Título da aba do app em que a tela está aberta. O app envolve cada aba com este widget; a tela
/// chama [definir] quando o conteúdo muda (ex.: a nota aberta) e a aba passa a mostrar o texto.
class TituloAba extends InheritedWidget {
  const TituloAba({super.key, required this.titulo, required super.child});

  final ValueNotifier<String?> titulo;

  /// `null` volta ao nome do módulo. Fora de uma aba (ex.: celular, testes) não faz nada.
  static void definir(BuildContext context, String? texto) {
    final alvo = context.getInheritedWidgetOfExactType<TituloAba>()?.titulo;
    if (alvo == null) return;
    // A barra de abas pode estar sendo montada no mesmo quadro: muda só depois dele.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => alvo.value = texto);
    } else {
      alvo.value = texto;
    }
  }

  @override
  bool updateShouldNotify(TituloAba oldWidget) => titulo != oldWidget.titulo;
}
