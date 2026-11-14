import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import 'api_saude.dart';
import 'datas.dart';
import 'health_connect.dart';

const _tarefa = 'saude.relogio.sincronizar';
const _nomeUnico = 'saude-relogio';

/// Lê os últimos [dias] do Health Connect em blocos de 30 e envia ao backend; devolve quantos dias
/// foram enviados. Não pede permissão: quem chama garante que já há (ou a tela pede antes).
Future<int> sincronizarRelogio(
  ApiSaude api,
  LeitorHealthConnect leitor, {
  required int dias,
  void Function(DateTime de, DateTime ate)? aoLer,
}) async {
  var ate = hoje();
  final limite = somarDias(ate, -(dias - 1));
  var enviados = 0;
  while (!ate.isBefore(limite)) {
    final inicio = somarDias(ate, -29);
    final de = inicio.isBefore(limite) ? limite : inicio;
    aoLer?.call(de, ate);
    final lote = await leitor.ler(de, ate);
    if (lote.isNotEmpty) await api.enviarDiasRelogio(lote);
    enviados += lote.length;
    ate = somarDias(de, -1);
  }
  return enviados;
}

/// Roda no processo de fundo do WorkManager (sem a tela): mesmo endereço e token da sessão que
/// agendou. Token vencido dá 401 e a tarefa só falha; o próximo login agenda de novo com o novo.
@pragma('vm:entry-point')
void despacharTarefasSaude() {
  Workmanager().executeTask((tarefa, dados) async {
    if (tarefa != _tarefa || dados == null) return true;
    final leitor = LeitorHealthConnect();
    try {
      if (await leitor.problema() != null || !await leitor.autorizado() || !await leitor.segundoPlanoAutorizado()) {
        return true; // nada a fazer até a pessoa autorizar na tela
      }
      await sincronizarRelogio(ApiSaude(dados['url'] as String, token: dados['token'] as String), leitor, dias: 3);
      return true;
    } catch (e) {
      debugPrint('Saúde: sincronização em segundo plano falhou: $e');
      return false; // o WorkManager tenta de novo mais tarde
    }
  });
}

bool _iniciado = false;

/// Agenda a leitura do Health Connect a cada hora, com internet, e faz uma agora (ao abrir o app).
/// Só no Android; no PC e na web não faz nada.
Future<void> agendarSincronizacao(String url, String token, ApiSaude api) async {
  if (!LeitorHealthConnect.disponivel || token.isEmpty) return;
  try {
    if (!_iniciado) {
      await Workmanager().initialize(despacharTarefasSaude);
      _iniciado = true;
    }
    await Workmanager().registerPeriodicTask(
      _nomeUnico,
      _tarefa,
      frequency: const Duration(hours: 1),
      inputData: {'url': url, 'token': token},
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    );
    final leitor = LeitorHealthConnect();
    if (await leitor.problema() == null && await leitor.autorizado()) {
      await sincronizarRelogio(api, leitor, dias: 3);
    }
  } catch (e) {
    debugPrint('Saúde: não deu para agendar a sincronização: $e');
  }
}
