import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

/// Módulos do documento de arquitetura que ainda não têm telas. Cada um sai daqui quando o pacote
/// `modulos/<id>/app` existir.
const modulosEmBreve = [
];

class ModuloEmBreve extends Modulo {
  const ModuloEmBreve(this.id, this.nome, this.descricao, this.icone);

  @override
  final String id;
  @override
  final String nome;
  @override
  final String descricao;
  @override
  final IconData icone;

  @override
  bool get disponivel => false;

  @override
  Widget construir(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      spacing: 12,
      children: [
        Icon(icone, size: 56, color: Theme.of(context).colorScheme.outline),
        Text(nome, style: Theme.of(context).textTheme.headlineSmall),
        Text(descricao),
        const Chip(label: Text('em breve')),
      ],
    ),
  );
}
