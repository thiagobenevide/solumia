typedef Doc = Map<String, dynamic>;

String iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// `2027-01-24` → `24/01/2027` (curto: `24/01`).
String dataBr(String? isoData, {bool curta = false}) {
  if (isoData == null || isoData.length < 10) return '—';
  final p = isoData.substring(0, 10).split('-');
  return curta ? '${p[2]}/${p[1]}' : '${p[2]}/${p[1]}/${p[0]}';
}

class Prazo {
  Prazo.fromJson(Doc j)
    : id = j['id'] as String? ?? '',
      titulo = j['titulo'] as String,
      data = j['data'] as String,
      hora = j['hora'] as String? ?? '',
      tipo = j['tipo'] as String? ?? 'outro',
      detalhe = j['detalhe'] as String? ?? '',
      origem = j['origem'] as String? ?? 'edital';

  final String id, titulo, data, hora, tipo, detalhe, origem;
}

class Tarefa {
  Tarefa.fromJson(Doc j)
    : id = j['id'] as String,
      data = j['data'] as String,
      tipo = j['tipo'] as String,
      disciplina = j['disciplina'] as String? ?? '',
      titulo = j['titulo'] as String,
      detalhe = j['detalhe'] as String? ?? '',
      minutos = j['minutos'] as int,
      feito = j['feito'] as bool? ?? false,
      chave = j['chave'] as String?;

  final String id, data, tipo, disciplina, titulo, detalhe;
  final int minutos;
  final String? chave;
  bool feito;
}

class Topico {
  Topico.fromJson(Doc j)
    : titulo = j['titulo'] as String,
      conteudo = j['conteudo'] as String? ?? '',
      horas = (j['horas'] as num?)?.toDouble() ?? 0,
      prioridade = j['prioridade'] as String? ?? 'media';

  final String titulo, conteudo, prioridade;
  final double horas;
}

class Disciplina {
  Disciplina.fromJson(Doc j)
    : nome = j['nome'] as String,
      modulo = j['modulo'] as String? ?? '',
      questoes = j['questoes'] as int? ?? 0,
      topicos = [for (final t in j['topicos'] as List? ?? const []) Topico.fromJson(t as Doc)];

  final String nome, modulo;
  final int questoes;
  final List<Topico> topicos;
}

/// Item da listagem (`GET /api/concursos`).
class ResumoConcurso {
  ResumoConcurso.fromJson(Doc j)
    : id = j['id'] as String,
      nome = j['nome'] as String,
      banca = j['banca'] as String? ?? '',
      cargo = j['cargo'] as String? ?? '',
      dataProva = j['data_prova'] as String?,
      diasParaProva = j['dias_para_prova'] as int?,
      estado = j['estado'] as String,
      temEdital = j['tem_edital'] as bool? ?? false,
      tarefas = j['tarefas'] as int? ?? 0,
      feitas = j['feitas'] as int? ?? 0,
      atrasadas = j['atrasadas'] as int? ?? 0,
      proximoPrazo = j['proximo_prazo'] == null ? null : Prazo.fromJson(j['proximo_prazo'] as Doc);

  final String id, nome, banca, cargo, estado;
  final String? dataProva;
  final int? diasParaProva;
  final bool temEdital;
  final int tarefas, feitas, atrasadas;
  final Prazo? proximoPrazo;

  double get progresso => tarefas == 0 ? 0 : feitas / tarefas;
}

/// Concurso completo (`GET /api/concursos/{id}`).
class Concurso {
  Concurso.fromJson(Doc j)
    : id = j['id'] as String,
      nome = j['nome'] as String,
      banca = j['banca'] as String? ?? '',
      cargo = j['cargo'] as String? ?? '',
      dataProva = j['data_prova'] as String?,
      minutosUtil = j['minutos_util'] as int? ?? 120,
      minutosFds = j['minutos_fds'] as int? ?? 240,
      observacoes = j['observacoes'] as String? ?? '',
      editalNome = (j['edital'] as Doc?)?['nome'] as String?,
      estado = (j['geracao'] as Doc)['estado'] as String,
      erro = (j['geracao'] as Doc)['erro'] as String? ?? '',
      estrutura = j['estrutura'] as Doc?,
      resumoPlano = j['resumo_plano'] as Doc?,
      prazos = [for (final p in j['prazos'] as List) Prazo.fromJson(p as Doc)],
      tarefas = [for (final t in j['tarefas'] as List) Tarefa.fromJson(t as Doc)],
      situacao = ResumoConcurso.fromJson(j['situacao'] as Doc),
      radar = j['radar'] as Doc?;

  final String id, nome, banca, cargo, observacoes, estado, erro;
  final String? dataProva, editalNome;
  final int minutosUtil, minutosFds;
  final Doc? estrutura, resumoPlano;
  final List<Prazo> prazos;
  final List<Tarefa> tarefas;
  final ResumoConcurso situacao;

  /// Ficha do radar quando o concurso veio de lá: vaga, inscrições, local de prova mais próximo.
  final Doc? radar;

  bool get gerando => estado == 'gerando';

  List<Disciplina> get disciplinas => [
    for (final d in estrutura?['disciplinas'] as List? ?? const []) Disciplina.fromJson(d as Doc),
  ];

  List<String> get estrategia => [for (final s in estrutura?['estrategia'] as List? ?? const []) s as String];
}

class Alerta {
  Alerta.fromJson(Doc j)
    : nivel = j['nivel'] as String,
      texto = j['texto'] as String,
      concursoId = j['concurso_id'] as String?;

  final String nivel, texto;
  final String? concursoId;
}

/// Município com coordenadas; nos locais de prova, `km`/`horas` da rota desde a origem.
class Local {
  Local.fromJson(Doc j)
    : cidade = j['cidade'] as String? ?? '',
      uf = j['uf'] as String? ?? '',
      lat = (j['lat'] as num).toDouble(),
      lon = (j['lon'] as num).toDouble(),
      km = (j['km'] as num?)?.toInt(),
      kmReta = (j['km_reta'] as num?)?.toInt(),
      horas = (j['horas'] as num?)?.toDouble(),
      estimada = j['estimada'] as bool? ?? false,
      suposto = j['suposto'] as bool? ?? false;

  final String cidade, uf;
  final double lat, lon;
  final int? km, kmReta;
  final double? horas;
  final bool estimada, suposto;

  String get nome => '$cidade/$uf';
}

class VagaTI {
  VagaTI.fromJson(Doc j)
    : cargo = j['cargo'] as String,
      vagas = j['vagas'] as int? ?? 0,
      cadastroReserva = j['cadastro_reserva'] as bool? ?? false,
      salario = (j['salario'] as num?)?.toDouble() ?? 0,
      requisitos = j['requisitos'] as String? ?? '';

  final String cargo, requisitos;
  final int vagas;
  final bool cadastroReserva;
  final double salario;
}

/// Concurso de TI achado pelo radar (PCI + LLM local).
class ItemRadar {
  ItemRadar.fromJson(Doc j)
    : id = j['id'] as String,
      orgao = j['orgao'] as String,
      uf = j['uf'] as String? ?? '',
      url = j['url'] as String,
      banca = j['banca'] as String? ?? '',
      editalUrl = j['edital_url'] as String? ?? '',
      linkInscricao = j['link_inscricao'] as String? ?? '',
      inscricoesInicio = j['inscricoes_inicio'] as String? ?? '',
      inscricoesFim = (j['inscricoes_fim'] as String?) ?? (j['inscricao_ate'] as String? ?? ''),
      dataProva = j['data_prova'] as String? ?? '',
      horarioProva = j['horario_prova'] as String? ?? '',
      taxa = j['taxa'] as String? ?? '',
      resumo = j['resumo'] as String? ?? '',
      nivel = j['nivel'] as String? ?? '',
      situacao = j['situacao'] as String? ?? '',
      fonte = j['fonte'] as String? ?? 'pci',
      esfera = j['esfera'] as String? ?? '',
      vagas = [for (final v in j['vagas_ti'] as List? ?? const []) VagaTI.fromJson(v as Doc)],
      totalVagas = j['total_vagas_ti'] as int? ?? 0,
      salarioMax = (j['salario_max'] as num?)?.toDouble() ?? 0,
      sede = j['sede'] == null ? null : Local.fromJson(j['sede'] as Doc),
      locais = [for (final l in j['locais_prova'] as List? ?? const []) Local.fromJson(l as Doc)],
      maisProximo = j['mais_proximo'] == null ? null : Local.fromJson(j['mais_proximo'] as Doc);

  final String id, orgao, uf, url, banca, editalUrl, linkInscricao, inscricoesInicio, inscricoesFim;
  final String dataProva, horarioProva, taxa, resumo, nivel;

  /// `aberto` ou `previsto` (só nos achados pelo Claude); `fonte`: `pci` ou `claude`.
  final String situacao, fonte;

  /// `federal`, `estadual` ou `municipal`.
  final String esfera;
  final List<VagaTI> vagas;
  final int totalVagas;
  final double salarioMax;
  final Local? sede, maisProximo;
  final List<Local> locais;
}

class Radar {
  Radar.fromJson(Doc j)
    : atualizado = j['atualizado'] as String?,
      erro = j['erro'] as String? ?? '',
      coletando = j['coletando'] as bool? ?? false,
      pendentes = j['pendentes'] as int? ?? 0,
      falhas = j['falhas'] as int? ?? 0,
      pesquisandoClaude = j['pesquisando_claude'] as bool? ?? false,
      claudeEm = (j['claude'] as Doc?)?['em'] as String?,
      claudeAchados = (j['claude'] as Doc?)?['achados'] as int? ?? 0,
      claudeErro = (j['claude'] as Doc?)?['erro'] as String? ?? '',
      origem = j['origem'] == null ? null : Local.fromJson(j['origem'] as Doc),
      itens = [for (final i in j['itens'] as List) ItemRadar.fromJson(i as Doc)];

  Radar._com(Radar r, this.itens)
    : atualizado = r.atualizado,
      erro = r.erro,
      coletando = r.coletando,
      pendentes = r.pendentes,
      falhas = r.falhas,
      pesquisandoClaude = r.pesquisandoClaude,
      claudeEm = r.claudeEm,
      claudeAchados = r.claudeAchados,
      claudeErro = r.claudeErro,
      origem = r.origem;

  /// Só os concursos das [esferas] (vazio = todos).
  Radar soEsferas(Set<String> esferas) =>
      esferas.isEmpty ? this : Radar._com(this, [for (final i in itens) if (esferas.contains(i.esfera)) i]);

  final String? atualizado;
  final String erro;
  final bool coletando;
  final int pendentes;
  final int falhas;
  final bool pesquisandoClaude;
  final String? claudeEm;
  final int claudeAchados;
  final String claudeErro;
  final Local? origem;
  final List<ItemRadar> itens;
}

class Rota {
  Rota.fromJson(Doc j)
    : km = (j['km'] as num).toInt(),
      horas = (j['horas'] as num).toDouble(),
      estimada = j['estimada'] as bool? ?? false,
      pontos = [
        for (final p in j['linha'] as List) (((p as List)[0] as num).toDouble(), (p[1] as num).toDouble()),
      ];

  final int km;
  final double horas;
  final bool estimada;

  /// Pares (lat, lon) da estrada, da origem ao local de prova.
  final List<(double, double)> pontos;
}

/// `13994.78` → `R$ 13.994,78`.
String reais(double v) {
  final partes = v.toStringAsFixed(2).split('.');
  final inteiro = partes[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => '.');
  return 'R\$ $inteiro,${partes[1]}';
}

/// `2.5` horas → `2h30`.
String duracao(double horas) {
  final h = horas.floor();
  final m = ((horas - h) * 60).round();
  return m == 0 ? '${h}h' : '${h}h${m.toString().padLeft(2, '0')}';
}

class Questao {
  Questao.fromJson(Doc j)
    : n = j['n'] as int,
      disciplina = j['disciplina'] as String? ?? '',
      topico = j['topico'] as String? ?? '',
      enunciado = j['enunciado'] as String,
      alternativas = [for (final a in j['alternativas'] as List) a as String],
      correta = j['correta'] as int?,
      comentario = j['comentario'] as String?;

  final int n;
  final String disciplina, topico, enunciado;
  final List<String> alternativas;
  final int? correta;
  final String? comentario;
}

class Simulado {
  Simulado.fromJson(Doc j)
    : id = j['id'] as String,
      titulo = j['titulo'] as String,
      estado = j['estado'] as String,
      erro = j['erro'] as String? ?? '',
      minutos = j['minutos'] as int? ?? 0,
      criado = j['criado'] as String,
      questoes = [for (final q in j['questoes'] as List) Questao.fromJson(q as Doc)],
      respostas = (j['respostas'] as List?)?.cast<int?>(),
      resultado = j['resultado'] as Doc?;

  final String id, titulo, estado, erro, criado;
  final int minutos;
  final List<Questao> questoes;
  final List<int?>? respostas;
  final Doc? resultado;

  bool get respondido => respostas != null;
}

class MaterialEstudo {
  MaterialEstudo.fromJson(Doc j)
    : titulo = j['titulo'] as String,
      url = j['url'] as String,
      tipo = j['tipo'] as String? ?? 'outro',
      disciplina = j['disciplina'] as String? ?? '',
      descricao = j['descricao'] as String? ?? '';

  final String titulo, url, tipo, disciplina, descricao;
}

/// Novidade de um rumor acompanhado (vira notificação no dia em que é registrada).
class NovidadeRumor {
  NovidadeRumor.fromJson(Doc j)
    : texto = j['texto'] as String? ?? '',
      fase = j['fase'] as String? ?? '',
      fonte = FonteRumor.fromJson(j['fonte'] as Doc? ?? const {}),
      registradaEm = j['registrada_em'] as String? ?? '';

  final String texto;
  final String fase;
  final FonteRumor fonte;
  final String registradaEm;
}

class FonteRumor {
  FonteRumor.fromJson(Doc j) : nome = j['nome'] as String? ?? '', url = j['url'] as String? ?? '';

  final String nome;
  final String url;
}

/// Rumor/previsão de concurso de TI (ainda sem edital), com as fontes.
class Rumor {
  Rumor.fromJson(Doc j)
    : id = j['id'] as String,
      orgao = j['orgao'] as String? ?? '',
      uf = j['uf'] as String? ?? '',
      esfera = j['esfera'] as String? ?? '',
      fase = j['fase'] as String? ?? 'rumor',
      cargosTi = [for (final c in j['cargos_ti'] as List? ?? const []) c as String],
      vagasPrevistas = j['vagas_previstas'] as int? ?? 0,
      dataNoticia = j['data_noticia'] as String? ?? '',
      resumo = j['resumo'] as String? ?? '',
      acompanhado = j['acompanhado'] as bool? ?? false,
      fontes = [for (final f in j['fontes'] as List? ?? const []) FonteRumor.fromJson(f as Doc)],
      novidades = [for (final n in j['novidades'] as List? ?? const []) NovidadeRumor.fromJson(n as Doc)];

  final String id;
  final String orgao;
  final String uf;
  final String esfera;
  final String fase;
  final List<String> cargosTi;
  final int vagasPrevistas;
  final String dataNoticia;
  final String resumo;
  final bool acompanhado;
  final List<FonteRumor> fontes;
  final List<NovidadeRumor> novidades;
}

class Rumores {
  Rumores.fromJson(Doc j)
    : pesquisando = j['pesquisando'] as bool? ?? false,
      buscaEm = (j['busca'] as Doc?)?['em'] as String?,
      buscaErro = (j['busca'] as Doc?)?['erro'] as String? ?? '',
      itens = [for (final i in j['itens'] as List) Rumor.fromJson(i as Doc)];

  final bool pesquisando;
  final String? buscaEm;
  final String buscaErro;
  final List<Rumor> itens;
}
