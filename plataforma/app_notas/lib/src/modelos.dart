import 'package:flutter/material.dart';

List<String> _textos(dynamic v) => [for (final x in (v as List? ?? const [])) '$x'];

/// Alvo de um `[[link]]`, sem apelido nem seção.
final linkRe = RegExp(r'\[\[([^\[\]|#]+)(?:#[^\[\]|]*)?(?:\|[^\[\]]*)?\]\]');

IconData iconeDoTipo(String tipo) => switch (tipo) {
  'tarefa' => Icons.task_alt,
  'meta' => Icons.flag_outlined,
  'cobranca' => Icons.campaign_outlined,
  'projeto' => Icons.folder_outlined,
  'pessoa' => Icons.person_outline,
  _ => Icons.description_outlined,
};

/// Campo do formulário de um tipo: `texto`, `numero`, `data`, `opcoes` ou `link`.
class Campo {
  Campo.fromJson(Map<String, dynamic> j)
    : nome = j['nome'],
      rotulo = j['rotulo'],
      tipo = j['tipo'],
      opcoes = _textos(j['opcoes']);

  final String nome, rotulo, tipo;
  final List<String> opcoes;
}

class TipoNota {
  TipoNota.fromJson(Map<String, dynamic> j)
    : id = j['id'],
      nome = j['nome'],
      modelo = j['modelo'] ?? '',
      relacoes = _textos(j['relacoes']),
      campos = [for (final c in j['campos'] as List) Campo.fromJson(c)];

  final String id, nome, modelo;
  final List<String> relacoes;
  final List<Campo> campos;
}

class NotaResumo {
  NotaResumo.fromJson(Map<String, dynamic> j)
    : id = j['id'],
      titulo = j['titulo'],
      tipo = j['tipo'] ?? 'nota',
      tags = _textos(j['tags']),
      status = j['status'],
      prazo = j['prazo'] == null ? null : DateTime.tryParse(j['prazo']),
      atualizada = DateTime.tryParse(j['atualizada'] ?? ''),
      entradas = j['entradas'] ?? 0;

  final String id, titulo, tipo;
  final List<String> tags;
  final String? status;
  final DateTime? prazo, atualizada;
  final int entradas;
}

/// Uma ponta de relação: saída (`id` nulo = link sem nota), backlink ou menção sem link.
class Ligacao {
  Ligacao.fromJson(Map<String, dynamic> j)
    : tipo = j['tipo'],
      id = j['id'],
      titulo = j['titulo'],
      trecho = j['trecho'] ?? '';

  final String tipo, titulo, trecho;
  final String? id;
}

class Nota {
  Nota.fromJson(Map<String, dynamic> j)
    : id = j['id'],
      titulo = j['titulo'],
      tipo = j['tipo'] ?? 'nota',
      tags = _textos(j['tags']),
      aliases = _textos(j['aliases']),
      propriedades = Map<String, dynamic>.from(j['propriedades'] ?? const {}),
      corpo = j['corpo'] ?? '',
      saidas = _ligacoes(j['saidas']),
      entradas = _ligacoes(j['entradas']),
      mencoes = _ligacoes(j['mencoes']);

  final String id, titulo, tipo, corpo;
  final List<String> tags, aliases;
  final Map<String, dynamic> propriedades;
  final List<Ligacao> saidas, entradas, mencoes;

  static List<Ligacao> _ligacoes(dynamic v) => [for (final x in (v as List? ?? const [])) Ligacao.fromJson(x)];
}

class Analise {
  Analise.fromJson(Map<String, dynamic> j)
    : total = j['total'],
      abertas = j['abertas'],
      porTipo = Map<String, int>.from(j['por_tipo']),
      quebrados = Nota._ligacoes(j['quebrados']),
      orfas = _resumos(j['orfas']),
      hubs = _resumos(j['hubs']),
      vencidas = _resumos(j['vencidas']),
      aVencer = _resumos(j['a_vencer']),
      paradas = _resumos(j['paradas']);

  final int total, abertas;
  final Map<String, int> porTipo;
  final List<Ligacao> quebrados;
  final List<NotaResumo> orfas, hubs, vencidas, aVencer, paradas;

  static List<NotaResumo> _resumos(dynamic v) => [for (final x in v as List) NotaResumo.fromJson(x)];
}

String dataCurta(DateTime? d) =>
    d == null ? '' : '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
