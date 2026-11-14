/// Tab of the Código module: one conversation with the Claude Code on the PC.
class CodeTab {
  CodeTab({
    required this.id,
    required this.title,
    required this.state,
    required this.eventos,
    this.claudeSession,
  });

  factory CodeTab.fromJson(Map<String, dynamic> j) => CodeTab(
    id: j['id'] as String,
    title: j['titulo'] as String? ?? '',
    state: j['estado'] as String? ?? 'parada',
    eventos: j['eventos'] as int? ?? 0,
    claudeSession: j['claude_sessao'] as String?,
  );

  final String id;
  final String title;

  /// `parada`, `rodando` or `erro` (the last request failed).
  final String state;
  final int eventos;
  final String? claudeSession;

  bool get running => state == 'rodando';
}

/// A step of the tab: `pedido` (yours), `inicio`, `texto`, `ferramenta`, `resultado` or `fim`.
class SessionStep {
  SessionStep(this.data);

  final Map<String, dynamic> data;

  String get type => data['tipo'] as String? ?? '';
  String get text => data['texto'] as String? ?? '';
  String get name => data['nome'] as String? ?? '';
  String get summary => data['resumo'] as String? ?? '';
  bool get error => data['erro'] == true;
  bool get commit => data['commit'] == true;
  List<String> get images => [for (final i in data['imagens'] as List? ?? const []) i as String];
  DateTime? get em => DateTime.tryParse(data['em'] as String? ?? '')?.toLocal();

  /// Footer line of `fim`: turns, duration and equivalent cost.
  String get footer {
    final parts = <String>[
      if (data['turnos'] != null) '${data['turnos']} turnos',
      if (data['duracao_ms'] is num) duration(Duration(milliseconds: (data['duracao_ms'] as num).round())),
      if (data['custo_usd'] is num) 'US\$ ${(data['custo_usd'] as num).toStringAsFixed(2)}',
    ];
    return parts.join(' · ');
  }
}

String duration(Duration d) =>
    d.inMinutes > 0 ? '${d.inMinutes} min ${d.inSeconds % 60} s' : '${d.inSeconds} s';

/// What Claude is doing now, from the last step (for the top of the tab).
String activity(List<SessionStep> steps) {
  for (final e in steps.reversed) {
    switch (e.type) {
      case 'ferramenta':
        return '${e.name}: ${e.summary}';
      case 'resultado':
        return 'Analisando o resultado…';
      case 'texto':
        return 'Escrevendo…';
      case 'inicio':
        return 'Lendo o projeto…';
      case 'pedido':
        return 'Subindo o Claude Code no PC…';
      case 'fim':
        return '';
    }
  }
  return '';
}

/// Commit of the code browser list.
class CodeCommit {
  CodeCommit(Map<String, dynamic> j)
    : hash = j['hash'] as String? ?? '',
      short = j['curto'] as String? ?? '',
      subject = j['assunto'] as String? ?? '',
      author = j['autor'] as String? ?? '',
      data = DateTime.tryParse(j['data'] as String? ?? '');

  final String hash;
  final String short;
  final String subject;
  final String author;
  final DateTime? data;
}

/// Repository at a commit: every file and what the commit changed (`A` new, `M` changed, `D` removed…).
class CodeTree {
  CodeTree(Map<String, dynamic> j)
    : commit = j['commit'] as String? ?? '',
      commits = [for (final c in j['commits'] as List? ?? const []) CodeCommit(c as Map<String, dynamic>)],
      files = [for (final a in j['arquivos'] as List? ?? const []) a as String],
      changes = {
        for (final m in j['mudancas'] as List? ?? const []) (m as Map)['caminho'] as String: m['status'] as String,
      };

  final String commit;
  final List<CodeCommit> commits;
  final List<String> files;
  final Map<String, String> changes;

  /// The folder has some file changed in the commit (to highlight and open right away).
  bool folderChanged(String pasta) => changes.keys.any((c) => c.startsWith('$pasta/'));
}

/// File open in the browser: text and the lines (from 1 on) that the commit added.
class CodeFile {
  CodeFile(Map<String, dynamic> j)
    : path = j['caminho'] as String? ?? '',
      binary = j['binario'] as bool? ?? false,
      truncated = j['cortado'] as bool? ?? false,
      size = j['tamanho'] as int? ?? 0,
      text = j['texto'] as String? ?? '',
      novas = {for (final n in j['novas'] as List? ?? const []) n as int};

  final String path;
  final bool binary;
  final bool truncated;
  final int size;
  final String text;
  final Set<int> novas;
}
