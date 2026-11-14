import 'package:flutter/material.dart';

import '../controlador.dart';
import '../modelos.dart';

/// Relações da nota aberta: links de saída (por tipo), backlinks e menções sem link.
/// Link sem nota aparece em vermelho e cria a nota ao tocar.
class PainelRelacoes extends StatelessWidget {
  const PainelRelacoes({super.key, required this.aberta});

  final NotaAberta aberta;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: aberta,
    builder: (context, _) {
      final n = aberta.nota;
      if (n == null) return const Center(child: Text('Nenhuma nota aberta'));
      final cores = Theme.of(context).colorScheme;
      final porTipo = <String, List<Ligacao>>{};
      for (final s in n.saidas) {
        porTipo.putIfAbsent(s.tipo, () => []).add(s);
      }
      return ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _Titulo('Saídas', n.saidas.length, Icons.call_made),
          if (n.saidas.isEmpty) const _Dica('Escreva [[ no texto ou use o botão Relação.'),
          for (final MapEntry(key: tipo, value: lista) in porTipo.entries) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Text(tipo.replaceAll('_', ' '), style: Theme.of(context).textTheme.labelMedium),
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final s in lista)
                  ActionChip(
                    avatar: Icon(s.id == null ? Icons.add : Icons.link, size: 16),
                    label: Text(s.titulo),
                    labelStyle: s.id == null ? TextStyle(color: cores.error) : null,
                    tooltip: s.id == null ? 'Criar nota' : null,
                    onPressed: () => s.id == null ? aberta.abrirOuCriar(s.titulo) : aberta.abrir(s.id!),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          _Titulo('Backlinks', n.entradas.length, Icons.call_received),
          if (n.entradas.isEmpty) const _Dica('Nenhuma nota aponta para esta.'),
          for (final e in n.entradas) _item(context, e),
          if (n.mencoes.isNotEmpty) ...[
            const SizedBox(height: 16),
            _Titulo('Menções sem link', n.mencoes.length, Icons.link_off),
            for (final m in n.mencoes) _item(context, m),
          ],
        ],
      );
    },
  );

  Widget _item(BuildContext context, Ligacao l) => Card(
    margin: const EdgeInsets.only(top: 6),
    child: ListTile(
      dense: true,
      title: Text(l.titulo),
      subtitle: l.trecho.isEmpty ? null : Text(l.trecho, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: Text(l.tipo.replaceAll('_', ' '), style: Theme.of(context).textTheme.labelSmall),
      onTap: l.id == null ? null : () => aberta.abrir(l.id!),
    ),
  );
}

class _Titulo extends StatelessWidget {
  const _Titulo(this.texto, this.n, this.icone);

  final String texto;
  final int n;
  final IconData icone;

  @override
  Widget build(BuildContext context) => Row(
    spacing: 8,
    children: [
      Icon(icone, size: 18),
      Text('$texto ($n)', style: Theme.of(context).textTheme.titleSmall),
    ],
  );
}

class _Dica extends StatelessWidget {
  const _Dica(this.texto);

  final String texto;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Text(texto, style: TextStyle(color: Theme.of(context).colorScheme.outline)),
  );
}
