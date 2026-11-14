import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdados;
import 'package:timezone/timezone.dart' as tz;

import 'sessao.dart';

/// Treino com o app em segundo plano (Spotify na frente, tela apagada) no Android: notificação fixa
/// com a etapa e a contagem do descanso (o sistema conta sozinho) e um alarme exato no fim do
/// descanso, que toca e vibra mesmo com o app parado. Com o guia aberto na frente, o alarme sai
/// (quem avisa é a própria tela).
class AvisoTreino {
  static const _fixa = 9101;
  static const _alarme = 9102;
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _pronto = false;
  static String _ultima = '';

  /// Os testes desligam (não há plugin de notificação).
  @visibleForTesting
  static bool ligado = true;

  static bool get suportado => ligado && !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> _iniciar() async {
    if (_pronto) return;
    _pronto = true;
    tzdados.initializeTimeZones();
    await _plugin.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
    );
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
    if (await android?.canScheduleExactNotifications() == false) await android?.requestExactAlarmsPermission();
  }

  /// [segundoPlano]: o guia não está na frente, então o fim do descanso vira alarme.
  static Future<void> atualizar(SessaoTreino s, {required bool segundoPlano}) async {
    if (!suportado) return;
    if (s.estado != 'andamento') return limpar();
    final restante = s.restanteDescanso();
    final emDescanso = restante != null && restante > 0 && !s.pausado;
    final fim = emDescanso ? DateTime.now().add(Duration(seconds: restante)) : null;
    final e = s.atual;
    final etapa = s.pausado
        ? 'Treino pausado'
        : emDescanso
        ? 'Descanso · próximo: ${e?.nome ?? '—'}'
        : e == null
        ? 'Tudo feito: conclua o treino'
        : '${e.nome} · série ${e.series.length + 1} de ${e.planejadas}';
    final fc = s.fcAtual();
    final texto = fc == null ? etapa : '$etapa · ♥ $fc';
    // não refaz a notificação a cada sincronização se nada mudou
    final chave = '$texto|${fim == null ? '' : fim.millisecondsSinceEpoch ~/ 5000}|$segundoPlano';
    if (chave == _ultima) return;
    _ultima = chave;
    try {
      await _iniciar();
      await _plugin.show(
        id: _fixa,
        title: 'Treino · ${s.seriesFeitas}/${s.seriesPlanejadas} séries',
        body: texto,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'treino',
            'Treino em andamento',
            channelDescription: 'Etapa e contagem do descanso',
            importance: Importance.low,
            priority: Priority.low,
            ongoing: true,
            autoCancel: false,
            onlyAlertOnce: true,
            showWhen: fim != null,
            usesChronometer: fim != null,
            chronometerCountDown: fim != null,
            when: fim?.millisecondsSinceEpoch,
          ),
        ),
      );
      await _plugin.cancel(id: _alarme);
      if (fim != null && segundoPlano) {
        await _plugin.zonedSchedule(
          id: _alarme,
          title: 'Descanso acabou',
          body: e == null ? 'Bora!' : 'Agora: ${e.nome} · série ${e.series.length + 1} de ${e.planejadas}',
          scheduledDate: tz.TZDateTime.from(fim.toUtc(), tz.UTC),
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              'treino_descanso',
              'Fim do descanso',
              channelDescription: 'Toca e vibra quando o descanso acaba',
              importance: Importance.max,
              priority: Priority.max,
              category: AndroidNotificationCategory.alarm,
              enableVibration: true,
              audioAttributesUsage: AudioAttributesUsage.alarm,
            ),
          ),
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        );
      }
    } catch (erro) {
      // sem permissão ou plugin indisponível: o guia segue funcionando com a tela aberta
      debugPrint('Aviso do treino: $erro');
    }
  }

  static Future<void> limpar() async {
    if (!suportado || !_pronto) return;
    _ultima = '';
    await _plugin.cancel(id: _fixa);
    await _plugin.cancel(id: _alarme);
  }
}
