/// Platform notes. Other modules reuse the API, the controller and the panels
/// (e.g. the Painel/Cobrador module embeds [AnalysisPanel] and opens notes with [OpenNote]).
library;

export 'src/notes_api.dart';
export 'src/open_note.dart';
export 'src/models.dart';
export 'src/notes_module.dart';
export 'src/screens/note_editor.dart';
export 'src/screens/notes_screen.dart';
export 'src/screens/analysis_panel.dart';
export 'src/screens/relations_panel.dart';
