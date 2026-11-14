import 'package:flutter/material.dart';

List<String> _strings(dynamic v) => [for (final x in (v as List? ?? const [])) '$x'];

/// Target of a `[[link]]`, without alias or section.
final linkRe = RegExp(r'\[\[([^\[\]|#]+)(?:#[^\[\]|]*)?(?:\|[^\[\]]*)?\]\]');

IconData iconForType(String type) => switch (type) {
  'tarefa' => Icons.task_alt,
  'meta' => Icons.flag_outlined,
  'cobranca' => Icons.campaign_outlined,
  'projeto' => Icons.folder_outlined,
  'pessoa' => Icons.person_outline,
  _ => Icons.description_outlined,
};

/// Form field of a note type: `texto`, `numero`, `data`, `opcoes` or `link`.
class NoteField {
  NoteField.fromJson(Map<String, dynamic> j)
    : name = j['nome'],
      label = j['rotulo'],
      type = j['tipo'],
      options = _strings(j['opcoes']);

  final String name, label, type;
  final List<String> options;
}

class NoteType {
  NoteType.fromJson(Map<String, dynamic> j)
    : id = j['id'],
      name = j['nome'],
      template = j['modelo'] ?? '',
      relations = _strings(j['relacoes']),
      fields = [for (final c in j['campos'] as List) NoteField.fromJson(c)];

  final String id, name, template;
  final List<String> relations;
  final List<NoteField> fields;
}

class NoteSummary {
  NoteSummary.fromJson(Map<String, dynamic> j)
    : id = j['id'],
      title = j['titulo'],
      type = j['tipo'] ?? 'nota',
      tags = _strings(j['tags']),
      status = j['status'],
      due = j['prazo'] == null ? null : DateTime.tryParse(j['prazo']),
      updated = DateTime.tryParse(j['atualizada'] ?? ''),
      incoming = j['entradas'] ?? 0;

  final String id, title, type;
  final List<String> tags;
  final String? status;
  final DateTime? due, updated;
  final int incoming;
}

/// One end of a relation: outgoing (null `id` = link without a note), backlink or unlinked mention.
class NoteLink {
  NoteLink.fromJson(Map<String, dynamic> j)
    : type = j['tipo'],
      id = j['id'],
      title = j['titulo'],
      excerpt = j['trecho'] ?? '';

  final String type, title, excerpt;
  final String? id;
}

class Note {
  Note.fromJson(Map<String, dynamic> j)
    : id = j['id'],
      title = j['titulo'],
      type = j['tipo'] ?? 'nota',
      tags = _strings(j['tags']),
      aliases = _strings(j['aliases']),
      properties = Map<String, dynamic>.from(j['propriedades'] ?? const {}),
      body = j['corpo'] ?? '',
      outgoing = _links(j['saidas']),
      incoming = _links(j['entradas']),
      mentions = _links(j['mencoes']);

  final String id, title, type, body;
  final List<String> tags, aliases;
  final Map<String, dynamic> properties;
  final List<NoteLink> outgoing, incoming, mentions;

  static List<NoteLink> _links(dynamic v) => [for (final x in (v as List? ?? const [])) NoteLink.fromJson(x)];
}

class NoteAnalysis {
  NoteAnalysis.fromJson(Map<String, dynamic> j)
    : total = j['total'],
      openCount = j['abertas'],
      byType = Map<String, int>.from(j['por_tipo']),
      broken = Note._links(j['quebrados']),
      orphans = _summaries(j['orfas']),
      hubs = _summaries(j['hubs']),
      overdue = _summaries(j['vencidas']),
      dueSoon = _summaries(j['a_vencer']),
      stale = _summaries(j['paradas']);

  final int total, openCount;
  final Map<String, int> byType;
  final List<NoteLink> broken;
  final List<NoteSummary> orphans, hubs, overdue, dueSoon, stale;

  static List<NoteSummary> _summaries(dynamic v) => [for (final x in v as List) NoteSummary.fromJson(x)];
}

String shortDate(DateTime? d) =>
    d == null ? '' : '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
