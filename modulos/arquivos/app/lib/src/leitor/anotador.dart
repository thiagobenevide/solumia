import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/foundation.dart';

import '../api_arquivos.dart';
import '../modelos.dart';
import '../offline.dart';
import '../telas/projetos_leitura.dart';

/// `noAparelho`: sem conexão, guardado no arquivo baixado; sobe quando a conexão voltar.
enum EstadoSalvamento { salvo, pendente, salvando, erro, noAparelho }

/// Dono das anotações de um arquivo aberto: edita, desfaz/refaz e salva sozinho pouco depois de
/// cada mudança. Se outro aparelho salvou no meio, busca as do servidor e mescla.
class Anotador extends ChangeNotifier {
  Anotador(this.api, this.arquivoId) {
    projetosAtivos.addListener(_aoMudarProjetos);
  }

  final ApiArquivos api;
  final String arquivoId;

  Anotacoes _atual = const Anotacoes();
  Anotacoes _sincronizada = const Anotacoes();
  final List<Anotacoes> _desfazer = [];
  final List<Anotacoes> _refazer = [];
  Timer? _espera;
  Future<void>? _salvando;
  EstadoSalvamento estado = EstadoSalvamento.salvo;
  String? erro;

  Anotacoes get atual => _atual;

  /// O que aparece no leitor: só o que não está em projeto nenhum e o que é de um projeto ativo.
  /// Marcações de outros projetos ficam guardadas, mas escondidas até o projeto ser escolhido.
  Anotacoes get visiveis {
    final ativos = projetosAtivos.value.toSet();
    bool ve(Elemento e) => e.projetos.isEmpty || e.projetos.any(ativos.contains);
    if (identical(_atual, _cacheBase) && identical(projetosAtivos.value, _cacheAtivos)) return _cache;
    _cacheBase = _atual;
    _cacheAtivos = projetosAtivos.value;
    return _cache = _atual.copiar(
      tracos: _atual.tracos.where(ve).toList(),
      destaques: _atual.destaques.where(ve).toList(),
      textos: _atual.textos.where(ve).toList(),
    );
  }

  Anotacoes _cache = const Anotacoes();
  Anotacoes? _cacheBase;
  List<String>? _cacheAtivos;

  void _aoMudarProjetos() => notifyListeners();
  bool get podeDesfazer => _desfazer.isNotEmpty;
  bool get podeRefazer => _refazer.isNotEmpty;
  bool get temPendencia => !identical(_atual, _sincronizada);

  /// Arquivo baixado para offline: cada salvamento também fica no aparelho.
  bool _local = false;

  Future<void> carregar() async {
    AcervoOffline.abertos.add(arquivoId);
    final local = await api.offline.anotacoes(arquivoId);
    _local = local != null;
    try {
      final servidor = await api.anotacoes(arquivoId);
      if (local != null && local.pendente) {
        // Anotado offline e ainda não enviado: junta com o servidor e sobe.
        _atual = Anotacoes.mesclar(local.base, local.atual, servidor);
        _sincronizada = servidor;
        _agendar();
      } else {
        _atual = _sincronizada = servidor;
      }
    } on ApiErro catch (e) {
      if (!semConexao(e) || local == null) rethrow;
      _sincronizada = local.base;
      _atual = local.atual;
      if (local.pendente) estado = EstadoSalvamento.noAparelho;
    }
    notifyListeners();
  }

  /// Outro aparelho anotou ([versao] do log de mudanças): traz as anotações dele, mesclando com
  /// o que ainda não foi salvo aqui.
  Future<void> atualizarDoServidor(int versao) async {
    if (versao <= _sincronizada.versao || _salvando != null) return;
    final servidor = await api.anotacoes(arquivoId);
    _atual = temPendencia ? Anotacoes.mesclar(_sincronizada, _atual, servidor) : servidor;
    _sincronizada = servidor;
    notifyListeners();
    if (temPendencia) _agendar();
  }

  void _mudar(Anotacoes nova) {
    _desfazer.add(_atual);
    if (_desfazer.length > 200) _desfazer.removeAt(0);
    _refazer.clear();
    _atual = nova;
    _agendar();
    notifyListeners();
  }

  /// O que nasce agora entra no(s) projeto(s) de leitura ativo(s).
  void adicionar(Elemento e) {
    final ativos = projetosAtivos.value;
    _mudar(_atual.adicionar(e.projetos.isEmpty && ativos.isNotEmpty ? e.comProjetos(ativos) : e));
  }

  /// Liga aos [projetos] tudo o que já foi anotado na [pagina] (traços, destaques e textos).
  int ligarPagina(int pagina, List<String> projetos) {
    final v = visiveis;
    final elementos = <Elemento>[...v.tracos, ...v.destaques, ...v.textos];
    var nova = _atual;
    var n = 0;
    for (final e in elementos) {
      if (e.pagina != pagina || projetos.every(e.projetos.contains)) continue;
      nova = nova.substituir(e.comProjetos({...e.projetos, ...projetos}.toList()));
      n++;
    }
    if (n > 0) _mudar(nova);
    return n;
  }

  void substituir(Elemento e) => _mudar(_atual.substituir(e));

  void remover(Set<String> ids) {
    if (ids.isNotEmpty) _mudar(_atual.remover(ids));
  }

  /// Apagar com a borracha arrastando: um só passo de desfazer para o gesto inteiro.
  Anotacoes? _antesDoGesto;

  void iniciarGesto() => _antesDoGesto = _atual;

  void removerNoGesto(Set<String> ids) {
    if (ids.isEmpty) return;
    _atual = _atual.remover(ids);
    notifyListeners();
  }

  void concluirGesto() {
    final antes = _antesDoGesto;
    _antesDoGesto = null;
    if (antes == null || identical(antes, _atual)) return;
    final depois = _atual;
    _atual = antes;
    _mudar(depois);
  }

  void desfazer() {
    if (_desfazer.isEmpty) return;
    _refazer.add(_atual);
    _atual = _desfazer.removeLast();
    _agendar();
    notifyListeners();
  }

  void refazer() {
    if (_refazer.isEmpty) return;
    _desfazer.add(_atual);
    _atual = _refazer.removeLast();
    _agendar();
    notifyListeners();
  }

  void _agendar() {
    estado = EstadoSalvamento.pendente;
    _espera?.cancel();
    _espera = Timer(const Duration(milliseconds: 1200), salvar);
  }

  /// Salva agora (também chamado ao sair do leitor).
  Future<void> salvar() async {
    _espera?.cancel();
    if (_salvando != null) return _salvando;
    if (!temPendencia) return;
    _salvando = _enviar();
    try {
      await _salvando;
    } finally {
      _salvando = null;
    }
  }

  Future<void> _enviar() async {
    estado = EstadoSalvamento.salvando;
    notifyListeners();
    final enviada = _atual;
    if (_local) await api.offline.guardarAnotacoes(arquivoId, _sincronizada, enviada, pendente: true);
    try {
      Anotacoes salva;
      try {
        salva = await api.salvarAnotacoes(arquivoId, enviada, _sincronizada.versao);
      } on ApiErro catch (e) {
        if (e.status != 409) rethrow;
        final servidor = await api.anotacoes(arquivoId);
        final mesclada = Anotacoes.mesclar(_sincronizada, enviada, servidor);
        salva = await api.salvarAnotacoes(arquivoId, mesclada, servidor.versao);
        if (identical(_atual, enviada)) _atual = mesclada;
      }
      // Mantém os mesmos objetos locais (o desfazer compara por identidade); só a versão muda.
      final sincronizada = identical(_atual, enviada) ? _atual.copiar(versao: salva.versao) : salva;
      if (identical(_atual, enviada)) _atual = sincronizada;
      _sincronizada = sincronizada;
      estado = temPendencia ? EstadoSalvamento.pendente : EstadoSalvamento.salvo;
      erro = null;
      if (_local) await api.offline.guardarAnotacoes(arquivoId, _sincronizada, _atual, pendente: temPendencia);
      if (temPendencia) _agendar();
    } catch (e) {
      estado = _local && semConexao(e) ? EstadoSalvamento.noAparelho : EstadoSalvamento.erro;
      erro = '$e';
      _espera = Timer(Duration(seconds: semConexao(e) ? 20 : 10), salvar);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    projetosAtivos.removeListener(_aoMudarProjetos);
    _espera?.cancel();
    AcervoOffline.abertos.remove(arquivoId);
    super.dispose();
  }
}
