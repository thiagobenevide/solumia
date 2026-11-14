import 'dart:async';

import 'package:agent_core/agent_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'api_painel.dart';

/// Confere a disciplina de tempos em tempos e mostra cada alerta novo como notificação do sistema
/// (Linux e Android), com o app em qualquer módulo ou minimizado. Com o app fechado, quem cobra é o
/// push do servidor (ntfy). Cada texto de alerta notifica uma vez por dia.
class VigiaCobrador {
  VigiaCobrador(this.api, {this.intervalo = const Duration(minutes: 5)});

  final ApiPainel api;
  final Duration intervalo;
  final _plugin = FlutterLocalNotificationsPlugin();
  final _vistos = <String>{};
  String _dia = '';
  int _id = 0;
  Timer? _timer;

  static bool get suportado =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.linux || defaultTargetPlatform == TargetPlatform.android);

  Future<void> iniciar() async {
    if (!suportado || _timer != null) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        linux: LinuxInitializationSettings(defaultActionName: 'Abrir'),
      ),
    );
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    _timer = Timer.periodic(intervalo, (_) => verificar());
    // primeira olhada logo após abrir, sem disputar com o carregamento das telas
    Timer(const Duration(seconds: 20), verificar);
  }

  Future<void> verificar() async {
    try {
      final d = await api.disciplina();
      final hoje = DateTime.now().toIso8601String().substring(0, 10);
      if (hoje != _dia) {
        _dia = hoje;
        _vistos.clear();
      }
      for (final a in d.alertas) {
        if (!_vistos.add(a.texto)) continue;
        final critico = a.nivel == 'critico';
        await _plugin.show(
          id: _id++,
          title: critico ? 'Cobrador: entrega em risco' : 'Cobrador',
          body: a.texto,
          notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails(
              'cobrador',
              'Cobrador',
              channelDescription: 'Alertas de disciplina e agenda',
              importance: critico ? Importance.high : Importance.defaultImportance,
              priority: critico ? Priority.high : Priority.defaultPriority,
            ),
            linux: LinuxNotificationDetails(
              urgency: critico ? LinuxNotificationUrgency.critical : LinuxNotificationUrgency.normal,
            ),
          ),
        );
      }
    } on ApiErro {
      // servidor fora: tenta de novo no próximo ciclo
    } on Exception catch (e) {
      debugPrint('Vigia do cobrador: $e');
    }
  }

  void parar() {
    _timer?.cancel();
    _timer = null;
  }
}
