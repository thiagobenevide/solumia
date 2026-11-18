import 'package:flutter/widgets.dart';

import 'cena.dart';

/// Contrato de um módulo da plataforma. O app principal lista os módulos na navegação e mostra a
/// tela de [construir] do que estiver selecionado.
abstract class Modulo {
  const Modulo();

  String get id;
  String get nome;
  String get descricao;
  IconData get icone;

  /// `false`: o módulo aparece na navegação como "em breve".
  bool get disponivel => true;

  /// Largura máxima da tela do módulo, centralizada no ultrawide. `null`: ocupa tudo (grades,
  /// quadros, grafos e editores que aproveitam a largura).
  double? get larguraMaxima => null;

  /// Fundo de vidro (degradê com manchas de luz) na largura toda. Só em telas de painel; telas de
  /// leitura e edição (notas, arquivos, código) ficam com o fundo liso.
  bool get fundoVidro => false;

  /// Animação de entrada do módulo ([CenaEntrada]); o padrão forma o [icone] com estilhaços.
  TemaCena get cena => TemaCena.padrao;

  /// Submenu no menu lateral: atalhos para as seções (abas internas) da tela do módulo.
  List<SecaoModulo> get secoes => const [];

  /// Seção aberta na tela: o submenu escreve para trocar de aba e a tela escreve ao trocar.
  ValueNotifier<int>? get secaoAtual => null;

  Widget construir(BuildContext context);

  /// Chamado uma vez quando o app abre, antes de o módulo ser visitado (ex.: alertas em segundo
  /// plano). Padrão: nada.
  void iniciar() {}
}

/// Item do submenu de um módulo ([Modulo.secoes]).
class SecaoModulo {
  const SecaoModulo(this.nome, this.icone);

  final String nome;
  final IconData icone;
}
