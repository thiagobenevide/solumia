import 'dart:convert';
import 'dart:io';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'health_api.dart';

/// Bridge to the Android plugin (`UsagePlugin.kt`) that applies the rules on this device: reads the time
/// per app (UsageStats). No accessibility, VPN or device admin. Outside Android it is a no-op.
///
/// Sync flow: collects the usage and the state of this device → sends to the backend → gets the
/// already built rules → the native side starts applying them.
class NativeUsage {
  static const _canal = MethodChannel('agent/saude/consumo');

  static bool get disponivel => !kIsWeb && Platform.isAndroid;

  /// Collects the local usage/events, sends them to the backend and hands the rules to apply back to the native side.
  /// Silent on purpose: runs every time the tab opens without bothering the user.
  static Future<void> sync(HealthApi api) async {
    if (!disponivel) return;
    try {
      final collection = await _canal.invokeMapMethod<String, dynamic>('coletar');
      if (collection == null) return;
      final rules = await api.syncUsage(Map<String, dynamic>.from(collection));
      // JSON string: the Android side keeps the nested maps when reparsing
      await _canal.invokeMethod('aplicar', jsonEncode(rules));
    } on PlatformException catch (e) {
      debugPrint('consumo nativo: $e');
    } on ApiErro catch (e) {
      debugPrint('consumo sincronizar: $e');
    }
  }

  /// Which sensitive permissions are still missing (only usage access), for the screen to request.
  static Future<Map<String, bool>> permissions() async {
    if (!disponivel) return const {};
    final r = await _canal.invokeMapMethod<String, dynamic>('permissoes');
    return {for (final e in (r ?? {}).entries) e.key: e.value == true};
  }

  /// Opens the system screen to grant [permission] (`uso`).
  static Future<void> requestPermission(String permission) async {
    if (!disponivel) return;
    await _canal.invokeMethod('pedir', {'permissao': permission});
  }
}
