List<String> _textos(dynamic v) => [for (final x in (v as List? ?? const [])) '$x'];

/// Áreas, status, idiomas e níveis aceitos pelo backend (`/api/estudos/opcoes`).
class Opcoes {
  Opcoes.fromJson(Map<String, dynamic> j)
    : areas = _textos(j['areas']),
      status = _textos(j['status']),
      idiomas = {for (final e in (j['idiomas'] as Map).entries) '${e.key}': '${e.value}'},
      niveis = _textos(j['niveis']),
      tiposCitacao = _textos(j['tipos_citacao']),
      tiposConteudo = _textos(j['tipos_conteudo']),
      statusUso = _textos(j['status_uso']);

  final List<String> areas, status, niveis, tiposCitacao, tiposConteudo, statusUso;
  final Map<String, String> idiomas;
}

/// Livro ou artigo, com a nota de síntese (Obsidian) ligada por [notaId].
class Leitura {
  Leitura.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String,
      titulo = j['titulo'] as String,
      autor = j['autor'] as String? ?? '',
      tipo = j['tipo'] as String? ?? 'livro',
      area = j['area'] as String,
      status = j['status'] as String,
      paginas = j['paginas'] as int?,
      paginaAtual = j['pagina_atual'] as int? ?? 0,
      notaId = j['nota_id'] as String?,
      arquivoId = j['arquivo_id'] as String?,
      url = j['url'] as String? ?? '',
      tags = _textos(j['tags']);

  final String id, titulo, autor, tipo, area, status, url;
  final int? paginas;
  final int paginaAtual;
  final String? notaId;

  /// PDF da leitura nos Arquivos (a escrita da Linguagem pode partir dele).
  final String? arquivoId;
  final List<String> tags;

  double? get progresso => paginas == null ? null : (paginaAtual / paginas!).clamp(0, 1).toDouble();
}

class Marco {
  Marco.fromJson(Map<String, dynamic> j)
    : nivel = j['nivel'] as String,
      horasTotal = (j['horas_total'] as num).toDouble(),
      horasFaltando = (j['horas_faltando'] as num).toDouble(),
      concluido = j['concluido'] as bool,
      previsao = j['previsao'] == null ? null : DateTime.parse(j['previsao'] as String);

  final String nivel;
  final double horasTotal, horasFaltando;
  final bool concluido;
  final DateTime? previsao;
}

/// Trilha de um idioma: ritmo (minutos × dias da semana), nível e previsão de cada marco.
class Trilha {
  Trilha.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String,
      idioma = j['idioma'] as String,
      nome = j['nome'] as String,
      nivelInicial = j['nivel_inicial'] as String,
      nivelAlvo = j['nivel_alvo'] as String,
      nivelAtual = j['nivel_atual'] as String,
      minutosPorDia = j['minutos_por_dia'] as int,
      diasSemana = [for (final d in j['dias_semana'] as List) d as int],
      inicio = DateTime.parse(j['inicio'] as String),
      horas = (j['horas'] as num).toDouble(),
      marcos = [for (final m in j['marcos'] as List) Marco.fromJson(m)];

  final String id, idioma, nome, nivelInicial, nivelAlvo, nivelAtual;
  final int minutosPorDia;
  final List<int> diasSemana;
  final DateTime inicio;
  final double horas;
  final List<Marco> marcos;
}

class Bloco {
  Bloco.fromJson(Map<String, dynamic> j)
    : habilidade = j['habilidade'] as String,
      titulo = j['titulo'] as String,
      minutos = j['minutos'] as int,
      descricao = j['descricao'] as String;

  final String habilidade, titulo, descricao;
  final int minutos;
}

/// Um dia do cronograma gerado, com os blocos e os minutos já registrados.
class DiaEstudo {
  DiaEstudo.fromJson(Map<String, dynamic> j)
    : data = DateTime.parse(j['data'] as String),
      nivel = j['nivel'] as String,
      tema = j['tema'] as String,
      minutos = j['minutos'] as int,
      feitoMinutos = j['feito_minutos'] as int? ?? 0,
      blocos = [for (final b in j['blocos'] as List) Bloco.fromJson(b)];

  final DateTime data;
  final String nivel, tema;
  final int minutos, feitoMinutos;
  final List<Bloco> blocos;

  bool get feito => feitoMinutos > 0;
}

class NoGrafo {
  NoGrafo.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String,
      titulo = j['titulo'] as String,
      tipo = j['tipo'] as String? ?? 'nota',
      tags = _textos(j['tags']),
      grau = j['grau'] as int? ?? 0;

  final String id, titulo, tipo;
  final List<String> tags;
  final int grau;
}

class Aresta {
  Aresta.fromJson(Map<String, dynamic> j)
    : de = j['de'] as String,
      para = j['para'] as String,
      tipo = j['tipo'] as String;

  final String de, para, tipo;
}

/// Projeto de leitura (pré-TCC, vídeo…): reúne trechos, comentários e anotações à mão feitos no
/// módulo Arquivos com o projeto ativo (ou ligados pelo painel do destaque).
class ProjetoLeitura {
  ProjetoLeitura.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String,
      nome = j['nome'] as String,
      descricao = j['descricao'] as String? ?? '',
      cor = j['cor'] as int? ?? 0xFF3F51B5,
      secoes = _textos(j['secoes']),
      trechos = j['trechos'] as int? ?? 0,
      comentarios = j['comentarios'] as int? ?? 0,
      manuscritos = j['manuscritos'] as int? ?? 0,
      trabalhos = j['trabalhos'] as int? ?? 0,
      atualizado = DateTime.tryParse(j['atualizado'] as String? ?? '');

  final String id, nome, descricao;
  final int cor, trechos, comentarios, manuscritos, trabalhos;
  final List<String> secoes;
  final DateTime? atualizado;
}

/// Trabalho lido (artigo, livro…) com a ficha para citar; [codigo] = T001…
class TrabalhoMatriz {
  TrabalhoMatriz.fromJson(Map<String, dynamic> j)
    : codigo = j['codigo'] as String,
      arquivoId = j['arquivo_id'] as String,
      leituraId = j['leitura_id'] as String?,
      titulo = j['titulo'] as String? ?? '',
      autor = j['autor'] as String? ?? '',
      autorCitacao = j['autor_citacao'] as String? ?? '',
      ano = j['ano'] as String? ?? '',
      referencia = j['referencia'] as String? ?? '',
      tipoPublicacao = j['tipo_publicacao'] as String? ?? '',
      veiculo = j['veiculo'] as String? ?? '',
      doi = j['doi'] as String? ?? '',
      idioma = j['idioma'] as String? ?? '',
      trechos = j['trechos'] as int? ?? 0,
      usados = j['usados'] as int? ?? 0;

  final String codigo, arquivoId, titulo, autor, autorCitacao, ano, referencia, tipoPublicacao, veiculo, doi, idioma;
  final String? leituraId;
  final int trechos, usados;
}

/// Item da matriz: trecho marcado, comentário escrito na página ou anotação à mão (por página).
class ItemMatriz {
  ItemMatriz.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String,
      tipo = j['tipo'] as String,
      codigo = j['codigo'] as String? ?? '',
      trabalho = j['trabalho'] as String? ?? '',
      arquivoId = j['arquivo_id'] as String,
      arquivoTitulo = j['arquivo_titulo'] as String? ?? '',
      pagina = j['pagina'] as int? ?? 0,
      texto = j['texto'] as String? ?? '',
      traducao = j['traducao'] as String? ?? '',
      comentario = j['comentario'] as String? ?? '',
      cor = j['cor'] as int?,
      citacaoParentetica = j['citacao_parentetica'] as String? ?? '',
      citacaoNarrativa = j['citacao_narrativa'] as String? ?? '',
      tracos = [for (final t in j['tracos'] as List? ?? const []) TracoMao.fromJson(t as Map<String, dynamic>)],
      classificacao = {
        for (final e in (j['classificacao'] as Map? ?? const {}).entries) '${e.key}': '${e.value ?? ''}',
      };

  final String id, tipo, codigo, trabalho, arquivoId, arquivoTitulo, texto, traducao, comentario;
  final String citacaoParentetica, citacaoNarrativa;
  final int pagina;
  final int? cor;
  final List<TracoMao> tracos;
  final Map<String, String> classificacao;

  String campo(String nome) => classificacao[nome] ?? '';

  bool get usado => campo('status_uso') == 'Usado';

  /// Texto para busca: tudo o que aparece no cartão.
  String get busca =>
      [texto, traducao, comentario, arquivoTitulo, citacaoNarrativa, ...classificacao.values].join(' ').toLowerCase();
}

/// Traço à mão (pontos x, y, pressão em pontos PDF da página).
class TracoMao {
  TracoMao.fromJson(Map<String, dynamic> j)
    : cor = j['cor'] as int? ?? 0xFF111111,
      espessura = (j['espessura'] as num? ?? 2).toDouble(),
      marcador = j['pincel'] == 'marcador',
      pontos = [for (final v in j['pontos'] as List? ?? const []) (v as num).toDouble()];

  final int cor;
  final double espessura;
  final bool marcador;
  final List<double> pontos;
}

class Matriz {
  Matriz.fromJson(Map<String, dynamic> j)
    : projeto = ProjetoLeitura.fromJson(j['projeto'] as Map<String, dynamic>),
      trabalhos = [for (final t in j['trabalhos'] as List) TrabalhoMatriz.fromJson(t as Map<String, dynamic>)],
      itens = [for (final i in j['itens'] as List) ItemMatriz.fromJson(i as Map<String, dynamic>)];

  final ProjetoLeitura projeto;
  final List<TrabalhoMatriz> trabalhos;
  final List<ItemMatriz> itens;
}
