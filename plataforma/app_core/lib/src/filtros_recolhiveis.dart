import 'package:flutter/material.dart';

import 'responsivo.dart';

/// Barra de busca/filtros que o usuário pode ocultar (no celular ela come metade da tela). Começa
/// recolhida no celular e aberta nas telas maiores; a escolha vale para a [chave] enquanto o app roda.
class FiltrosRecolhiveis extends StatefulWidget {
  const FiltrosRecolhiveis({super.key, required this.chave, required this.children, this.resumo});

  /// Identifica a tela, para lembrar se o usuário abriu ou fechou os filtros dela.
  final String chave;
  final List<Widget> children;

  /// Texto curto mostrado com os filtros ocultos (ex.: "PDF · Finanças").
  final String? resumo;

  @override
  State<FiltrosRecolhiveis> createState() => _FiltrosRecolhiveisState();
}

class _FiltrosRecolhiveisState extends State<FiltrosRecolhiveis> {
  static final _abertos = <String, bool>{};

  @override
  Widget build(BuildContext context) {
    final aberto = _abertos[widget.chave] ?? !Faixa.de(context).celular;
    final resumo = widget.resumo;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _abertos[widget.chave] = !aberto),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              spacing: 8,
              children: [
                const Icon(Icons.filter_list, size: 18),
                Expanded(
                  child: Text(
                    aberto || resumo == null || resumo.isEmpty ? 'Filtros' : 'Filtros: $resumo',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
                Icon(aberto ? Icons.expand_less : Icons.expand_more, size: 20),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          alignment: Alignment.topCenter,
          child: aberto
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: widget.children,
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}
