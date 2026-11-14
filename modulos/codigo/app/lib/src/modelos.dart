/// Aba do módulo Código: uma conversa com o Claude Code no PC.
class AbaCodigo {
  AbaCodigo({
    required this.id,
    required this.titulo,
    required this.estado,
    required this.eventos,
    this.claudeSessao,
  });

  factory AbaCodigo.fromJson(Map<String, dynamic> j) => AbaCodigo(
    id: j['id'] as String,
    titulo: j['titulo'] as String? ?? '',
    estado: j['estado'] as String? ?? 'parada',
    eventos: j['eventos'] as int? ?? 0,
    claudeSessao: j['claude_sessao'] as String?,
  );

  final String id;
  final String titulo;

  /// `parada`, `rodando` ou `erro` (o último pedido falhou).
  final String estado;
  final int eventos;
  final String? claudeSessao;

  bool get rodando => estado == 'rodando';
}

/// Uma etapa da aba: `pedido` (seu), `inicio`, `texto`, `ferramenta`, `resultado` ou `fim`.
class Etapa {
  Etapa(this.dados);

  final Map<String, dynamic> dados;

  String get tipo => dados['tipo'] as String? ?? '';
  String get texto => dados['texto'] as String? ?? '';
  String get nome => dados['nome'] as String? ?? '';
  String get resumo => dados['resumo'] as String? ?? '';
  bool get erro => dados['erro'] == true;
  bool get commit => dados['commit'] == true;
  List<String> get imagens => [for (final i in dados['imagens'] as List? ?? const []) i as String];
  DateTime? get em => DateTime.tryParse(dados['em'] as String? ?? '')?.toLocal();

  /// Linha de rodapé do `fim`: turnos, duração e custo equivalente.
  String get rodape {
    final partes = <String>[
      if (dados['turnos'] != null) '${dados['turnos']} turnos',
      if (dados['duracao_ms'] is num) duracao(Duration(milliseconds: (dados['duracao_ms'] as num).round())),
      if (dados['custo_usd'] is num) 'US\$ ${(dados['custo_usd'] as num).toStringAsFixed(2)}',
    ];
    return partes.join(' · ');
  }
}

String duracao(Duration d) =>
    d.inMinutes > 0 ? '${d.inMinutes} min ${d.inSeconds % 60} s' : '${d.inSeconds} s';

/// O que o Claude está fazendo agora, a partir da última etapa (para o topo da aba).
String atividade(List<Etapa> etapas) {
  for (final e in etapas.reversed) {
    switch (e.tipo) {
      case 'ferramenta':
        return '${e.nome}: ${e.resumo}';
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

/// Commit da lista do navegador de código.
class CommitCodigo {
  CommitCodigo(Map<String, dynamic> j)
    : hash = j['hash'] as String? ?? '',
      curto = j['curto'] as String? ?? '',
      assunto = j['assunto'] as String? ?? '',
      autor = j['autor'] as String? ?? '',
      data = DateTime.tryParse(j['data'] as String? ?? '');

  final String hash;
  final String curto;
  final String assunto;
  final String autor;
  final DateTime? data;
}

/// Repositório num commit: todos os arquivos e o que o commit mudou (`A` novo, `M` alterado, `D` removido…).
class ArvoreCodigo {
  ArvoreCodigo(Map<String, dynamic> j)
    : commit = j['commit'] as String? ?? '',
      commits = [for (final c in j['commits'] as List? ?? const []) CommitCodigo(c as Map<String, dynamic>)],
      arquivos = [for (final a in j['arquivos'] as List? ?? const []) a as String],
      mudancas = {
        for (final m in j['mudancas'] as List? ?? const []) (m as Map)['caminho'] as String: m['status'] as String,
      };

  final String commit;
  final List<CommitCodigo> commits;
  final List<String> arquivos;
  final Map<String, String> mudancas;

  /// A pasta tem algum arquivo mudado no commit (para destacar e já abrir).
  bool pastaMudou(String pasta) => mudancas.keys.any((c) => c.startsWith('$pasta/'));
}

/// Arquivo aberto no navegador: texto e as linhas (de 1 em diante) que o commit adicionou.
class ArquivoCodigo {
  ArquivoCodigo(Map<String, dynamic> j)
    : caminho = j['caminho'] as String? ?? '',
      binario = j['binario'] as bool? ?? false,
      cortado = j['cortado'] as bool? ?? false,
      tamanho = j['tamanho'] as int? ?? 0,
      texto = j['texto'] as String? ?? '',
      novas = {for (final n in j['novas'] as List? ?? const []) n as int};

  final String caminho;
  final bool binario;
  final bool cortado;
  final int tamanho;
  final String texto;
  final Set<int> novas;
}
