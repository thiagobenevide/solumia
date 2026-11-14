import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import 'notes_api.dart';
import 'screens/notes_screen.dart';

class NotesModule extends Modulo {
  NotesModule({required String url, String token = ''}) : api = NotesApi(url, token: token);

  final NotesApi api;

  @override
  String get id => 'notas';

  @override
  String get nome => 'Notas';

  @override
  String get descricao => 'Notas, links e relações (Obsidian)';

  @override
  IconData get icone => Icons.sticky_note_2_outlined;

  @override
  Widget construir(BuildContext context) => NotesScreen(api: api);
}
