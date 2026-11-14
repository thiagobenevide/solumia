import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'api_saude.dart';

/// Ponte com o plugin Android (`ConsumoPlugin.kt`) que aplica as regras neste aparelho: lê o tempo
/// por app (UsageStats). Sem acessibilidade, VPN nem administrador do aparelho. Fora do Android é no-op.
///
/// Fluxo da sincronização: coleta o uso e o estado deste aparelho → manda ao backend → recebe as
/// regras já montadas → o nativo passa a aplicá-las.
class ConsumoNativo {
  static const _canal = MethodChannel('agent/saude/consumo');

  static bool get disponivel => !kIsWeb && Platform.isAndroid;

  /// Coleta o uso/eventos locais, envia ao backend e devolve ao nativo as regras para aplicar.
  /// Silencioso de propósito: roda a cada abertura da aba sem atrapalhar o usuário.
  static Future<void> sincronizar(ApiSaude api) async {
    if (!disponivel) return;
    try {
      final coleta = await _canal.invokeMapMethod<String, dynamic>('coletar');
      if (coleta == null) return;
      final regras = await api.sincronizarConsumo(Map<String, dynamic>.from(coleta));
      // JSON string: o lado Android preserva os mapas aninhados ao reparsear
      await _canal.invokeMethod('aplicar', jsonEncode(regras));
    } on PlatformException catch (e) {
      debugPrint('consumo nativo: $e');
    } on ApiErro catch (e) {
      debugPrint('consumo sincronizar: $e');
    }
  }

  /// Quais permissões sensíveis ainda faltam (só a leitura de uso), para a tela pedir.
  static Future<Map<String, bool>> permissoes() async {
    if (!disponivel) return const {};
    final r = await _canal.invokeMapMethod<String, dynamic>('permissoes');
    return {for (final e in (r ?? {}).entries) e.key: e.value == true};
  }

  /// Abre a tela do sistema para conceder [permissao] (`uso`).
  static Future<void> pedirPermissao(String permissao) async {
    if (!disponivel) return;
    await _canal.invokeMethod('pedir', {'permissao': permissao});
  }
}
