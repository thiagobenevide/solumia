import 'package:flutter/foundation.dart';

import 'api_notas.dart';
import 'modelos.dart';

/// Nota aberta, compartilhada entre o editor e os painéis. [versao] sobe a cada mudança salva,
/// para a lista e a análise se atualizarem.
class NotaAberta extends ChangeNotifier {
  NotaAberta(this.api);

  final ApiNotas api;
  Nota? nota;
  bool carregando = false;
  String? erro;
  int versao = 0;

  /// O editor registra aqui o salvamento do que ainda não foi gravado; roda antes de trocar de nota.
  Future<void> Function()? pendente;

  Future<void> abrir(String id) async {
    await pendente?.call();
    return _rodar(() => api.obter(id));
  }

  Future<void> criar(Map<String, dynamic> dados) async {
    await pendente?.call();
    return _rodar(() => api.criar(dados), mudou: true);
  }

  /// Abre a nota de título [titulo]; se não existir, cria (link não resolvido → nota nova).
  Future<void> abrirOuCriar(String titulo, {String tipo = 'nota'}) async {
    final achadas = await api.listar(q: titulo);
    final igual = achadas.where((r) => r.titulo.toLowerCase() == titulo.toLowerCase()).firstOrNull;
    return igual != null ? abrir(igual.id) : criar({'titulo': titulo, 'tipo': tipo});
  }

  Future<void> salvar(Map<String, dynamic> dados) =>
      _rodar(() => api.salvar(nota!.id, dados), mudou: true);

  Future<void> excluir() async {
    await api.excluir(nota!.id);
    nota = null;
    versao++;
    notifyListeners();
  }

  void fechar() {
    nota = null;
    notifyListeners();
  }

  Future<void> _rodar(Future<Nota> Function() acao, {bool mudou = false}) async {
    carregando = true;
    erro = null;
    notifyListeners();
    try {
      nota = await acao();
      if (mudou) versao++;
    } catch (e) {
      erro = '$e';
    }
    carregando = false;
    notifyListeners();
  }
}
