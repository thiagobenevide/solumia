/// Trilhas de conhecimento (`/api/estudos/conhecimento`): etapas com as indicações de capítulos.
library;

List<String> _textos(dynamic v) => [for (final x in (v as List? ?? const [])) '$x'];

/// A leitura da aba Leituras ligada ao livro (onde fica o PDF para ler e grifar).
class LeituraLigada {
  LeituraLigada.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String,
      status = j['status'] as String? ?? '',
      arquivoId = j['arquivo_id'] as String?,
      paginaAtual = j['pagina_atual'] as int? ?? 0;

  final String id, status;
  final String? arquivoId;
  final int paginaAtual;
}

class LivroTrilha {
  LivroTrilha.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String,
      titulo = j['titulo'] as String,
      original = j['original'] as String? ?? '',
      autor = j['autor'] as String? ?? '',
      edicao = j['edicao'] as String? ?? '',
      tipo = j['tipo'] as String? ?? 'livro',
      url = j['url'] as String? ?? '',
      tenho = j['tenho'] as bool? ?? false,
      indicacoes = j['indicacoes'] as int? ?? 0,
      leitura = j['leitura'] == null ? null : LeituraLigada.fromJson(j['leitura']);

  final String id, titulo, original, autor, edicao, tipo, url;
  final bool tenho;
  final int indicacoes;
  final LeituraLigada? leitura;
}

class Indicacao {
  Indicacao.fromJson(Map<String, dynamic> j)
    : indice = j['indice'] as int,
      capitulos = j['capitulos'] as String,
      foco = j['foco'] as String? ?? '',
      feita = j['feita'] as String?,
      livro = LivroTrilha.fromJson(j['livro']);

  final int indice;
  final String capitulos, foco;

  /// Data em que foi lida (null = por ler).
  final String? feita;
  final LivroTrilha livro;
}

class EtapaTrilha {
  EtapaTrilha.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String,
      fase = j['fase'] as String,
      titulo = j['titulo'] as String,
      objetivo = j['objetivo'] as String? ?? '',
      pratica = j['pratica'] as String? ?? '',
      entregavel = j['entregavel'] as String? ?? '',
      frentes = _textos(j['frentes']),
      conceitos = _textos(j['conceitos']),
      leituras = [for (final x in j['leituras'] as List) Indicacao.fromJson(x)],
      praticaFeita = j['pratica_feita'] as String?,
      notaId = j['nota_id'] as String?,
      progresso = (j['progresso'] as num).toDouble(),
      concluida = j['concluida'] as bool;

  final String id, fase, titulo, objetivo, pratica, entregavel;
  final List<String> frentes, conceitos;
  final List<Indicacao> leituras;
  final String? praticaFeita, notaId;
  final double progresso;
  final bool concluida;
}

/// O que fazer agora: `leitura` (capítulo de livro que você tem), `conseguir` (livro que falta) ou `pratica`.
class Proxima {
  Proxima.fromJson(Map<String, dynamic> j)
    : tipo = j['tipo'] as String,
      etapaId = j['etapa_id'] as String,
      etapa = j['etapa'] as String,
      fase = j['fase'] as String,
      pratica = j['pratica'] as String? ?? '',
      indicacao = j['indicacao'] == null ? null : Indicacao.fromJson(j['indicacao']);

  final String tipo, etapaId, etapa, fase, pratica;
  final Indicacao? indicacao;
}

class TrilhaConhecimento {
  TrilhaConhecimento.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String,
      area = j['area'] as String? ?? '',
      titulo = j['titulo'] as String,
      descricao = j['descricao'] as String? ?? '',
      frentes = _textos(j['frentes']),
      frente = j['frente'] as String?,
      etapas = [for (final x in j['etapas'] as List? ?? const []) EtapaTrilha.fromJson(x)],
      totalEtapas = j['total_etapas'] as int? ?? 0,
      etapasConcluidas = j['etapas_concluidas'] as int? ?? 0,
      progresso = (j['progresso'] as num? ?? 0).toDouble(),
      proxima = j['proxima'] == null ? null : Proxima.fromJson(j['proxima']);

  final String id, area, titulo, descricao;
  final List<String> frentes;
  final String? frente;
  final List<EtapaTrilha> etapas;
  final int totalEtapas, etapasConcluidas;
  final double progresso;
  final Proxima? proxima;
}
