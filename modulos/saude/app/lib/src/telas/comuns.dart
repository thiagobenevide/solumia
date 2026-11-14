import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api_saude.dart';
import '../modelos.dart';

/// O que as vistas do calendário precisam da tela de treinos.
class Agenda {
  Agenda({
    required this.api,
    required this.itensDoDia,
    required this.exercicio,
    required this.soltar,
    required this.abrirItem,
    required this.alternarFeito,
    required this.abrirDia,
    required this.versaoImagem,
  });

  final ApiSaude api;
  final List<ItemAgenda> Function(DateTime dia) itensDoDia;
  final Exercicio? Function(String id) exercicio;
  final void Function(Arrasto arrasto, DateTime dia) soltar;
  final void Function(ItemAgenda item) abrirItem;
  final void Function(ItemAgenda item) alternarFeito;
  final void Function(DateTime dia) abrirDia;

  /// Muda quando uma foto é trocada, para as miniaturas recarregarem.
  final int Function(String exercicioId) versaoImagem;
}

/// Foto do exercício (ou um ícone, se não houver).
class ImagemExercicio extends StatelessWidget {
  const ImagemExercicio({super.key, required this.api, required this.exercicio, this.n = 0, this.versao = 0, this.tamanho});

  final ApiSaude api;
  final Exercicio? exercicio;
  final int n;
  final int versao;
  final double? tamanho;

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    final vazio = Container(
      width: tamanho,
      height: tamanho,
      color: cores.surfaceContainerHighest,
      child: Icon(Icons.fitness_center, color: cores.outline, size: (tamanho ?? 48) * 0.5),
    );
    final e = exercicio;
    if (e == null || !e.temImagem) return vazio;
    return Image.network(
      api.urlImagem(e.id, n: n, versao: versao).toString(),
      headers: api.cabecalhos,
      width: tamanho,
      height: tamanho,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => vazio,
    );
  }
}

/// Arrastar com o mouse começa no clique; no toque (Android), com toque longo, para não brigar
/// com a rolagem.
class Arrastavel extends StatelessWidget {
  const Arrastavel({super.key, required this.dado, required this.rotulo, required this.child});

  final Arrasto dado;
  final String rotulo;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final fantasma = Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(8),
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(rotulo, style: Theme.of(context).textTheme.labelLarge),
      ),
    );
    final toque = switch (defaultTargetPlatform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
    final apagado = Opacity(opacity: 0.4, child: child);
    return toque
        ? LongPressDraggable<Arrasto>(data: dado, feedback: fantasma, childWhenDragging: apagado, child: child)
        : Draggable<Arrasto>(data: dado, feedback: fantasma, childWhenDragging: apagado, child: child);
  }
}

/// Área de um dia que aceita exercícios e itens arrastados; fica destacada enquanto algo paira.
class AlvoDia extends StatelessWidget {
  const AlvoDia({super.key, required this.agenda, required this.dia, required this.child});

  final Agenda agenda;
  final DateTime dia;
  final Widget child;

  @override
  Widget build(BuildContext context) => DragTarget<Arrasto>(
    onAcceptWithDetails: (d) => agenda.soltar(d.data, dia),
    builder: (context, candidatos, _) => AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: BoxDecoration(
        color: candidatos.isEmpty ? null : Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
        border: candidatos.isEmpty ? null : Border.all(color: Theme.of(context).colorScheme.primary, width: 2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: child,
    ),
  );
}

/// Cartão de um exercício marcado: arrastável para outro dia, toque abre a edição.
class CartaoItem extends StatelessWidget {
  const CartaoItem({super.key, required this.agenda, required this.item, this.compacto = false});

  final Agenda agenda;
  final ItemAgenda item;
  final bool compacto;

  @override
  Widget build(BuildContext context) {
    final e = agenda.exercicio(item.exercicioId);
    final nome = e?.nome ?? item.exercicioId;
    final tema = Theme.of(context);
    final riscado = item.feito
        ? TextStyle(decoration: TextDecoration.lineThrough, color: tema.colorScheme.outline)
        : null;
    final Widget conteudo;
    if (compacto) {
      conteudo = Container(
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: item.feito ? tema.colorScheme.surfaceContainerHighest : tema.colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(nome, maxLines: 1, overflow: TextOverflow.ellipsis, style: tema.textTheme.labelSmall?.merge(riscado)),
      );
    } else {
      conteudo = LayoutBuilder(
        builder: (context, c) => c.maxWidth < 200 ? _empilhado(context, e, nome, riscado) : _emLinha(e, nome, riscado),
      );
    }
    return Arrastavel(
      dado: ArrastoItem(item),
      rotulo: nome,
      child: compacto ? GestureDetector(onTap: () => agenda.abrirItem(item), child: conteudo) : conteudo,
    );
  }

  /// Coluna estreita (semana no PC, janela pequena): imagem em cima, nome, séries e o "feito" embaixo,
  /// em vez de espremer tudo numa linha.
  Widget _empilhado(BuildContext context, Exercicio? e, String nome, TextStyle? riscado) {
    final tema = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => agenda.abrirItem(item),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 16 / 10,
              // Sem tamanho: a imagem preenche o espaço do AspectRatio (cover).
              child: ImagemExercicio(api: agenda.api, exercicio: e, versao: agenda.versaoImagem(item.exercicioId)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 0),
              child: Text(
                nome,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: tema.textTheme.labelMedium?.merge(riscado),
              ),
            ),
            Row(
              children: [
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    item.resumo,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tema.textTheme.labelSmall?.copyWith(color: tema.colorScheme.onSurfaceVariant),
                  ),
                ),
                SizedBox.square(
                  dimension: 32,
                  child: Checkbox(
                    value: item.feito,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: (_) => agenda.alternarFeito(item),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _emLinha(Exercicio? e, String nome, TextStyle? riscado) => Card(
        margin: const EdgeInsets.only(bottom: 6),
        child: ListTile(
          dense: true,
          contentPadding: const EdgeInsets.only(left: 6, right: 0),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: ImagemExercicio(
              api: agenda.api,
              exercicio: e,
              tamanho: 44,
              versao: agenda.versaoImagem(item.exercicioId),
            ),
          ),
          title: Text(nome, maxLines: 2, overflow: TextOverflow.ellipsis, style: riscado),
          subtitle: Text(item.resumo),
          trailing: Checkbox(value: item.feito, onChanged: (_) => agenda.alternarFeito(item)),
          onTap: () => agenda.abrirItem(item),
        ),
      );
}
