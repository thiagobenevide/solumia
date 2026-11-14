package com.thiagobenevide.agent.relogio

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZoneId
import java.util.concurrent.TimeUnit

/**
 * Notificações próprias do relógio: alertas do cobrador (`/api/painel/disciplina`, a cada 15 min pelo
 * WorkManager, cada texto uma vez por dia) e alarme no início de cada bloco da agenda do dia
 * (AlarmManager exato, refeito a cada rodada do vigia).
 */
object Avisos {
    const val CANAL_COBRADOR = "cobrador"
    const val CANAL_ALARME = "alarme"
    const val CANAL_TREINO = "treino"
    private const val PREFS = "avisos"

    fun canais(c: Context) {
        val nm = c.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CANAL_COBRADOR, "Cobrador", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Alertas de disciplina e agenda"
                vibrationPattern = longArrayOf(0, 300, 200, 300)
                enableVibration(true)
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(CANAL_TREINO, "Treino em andamento", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Série, descanso e batimentos com a tela apagada"
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(CANAL_ALARME, "Início de bloco", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Hora de começar o bloco da agenda"
                vibrationPattern = longArrayOf(0, 600, 250, 600, 250, 600)
                enableVibration(true)
            },
        )
    }

    /** Liga o vigia periódico e já roda uma vez. */
    fun agendar(c: Context) {
        canais(c)
        val wm = WorkManager.getInstance(c)
        wm.enqueueUniquePeriodicWork(
            "vigia", ExistingPeriodicWorkPolicy.KEEP,
            PeriodicWorkRequestBuilder<Vigia>(15, TimeUnit.MINUTES).build(),
        )
        wm.enqueueUniqueWork("vigia-agora", ExistingWorkPolicy.REPLACE, OneTimeWorkRequestBuilder<Vigia>().build())
    }

    private fun abrir(c: Context, tela: String, codigo: Int): PendingIntent = PendingIntent.getActivity(
        c, codigo, Intent(c, MainActivity::class.java).putExtra("tela", tela),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    fun notificar(c: Context, id: Int, canal: String, titulo: String, texto: String, tela: String, acoes: List<Notification.Action> = emptyList()) {
        val n = Notification.Builder(c, canal)
            .setSmallIcon(R.drawable.ic_agent_mono)
            .setContentTitle(titulo)
            .setContentText(texto)
            .setStyle(Notification.BigTextStyle().bigText(texto))
            .setAutoCancel(true)
            .setCategory(if (canal == CANAL_ALARME) Notification.CATEGORY_ALARM else Notification.CATEGORY_REMINDER)
            .setContentIntent(abrir(c, tela, id))
        acoes.forEach { n.addAction(it) }
        if (Build.VERSION.SDK_INT >= 33 &&
            c.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED
        ) return
        c.getSystemService(NotificationManager::class.java).notify(id, n.build())
    }

    /** Alertas novos do dia: devolve os que ainda não tinham sido mostrados e marca como vistos. */
    fun novosAlertas(c: Context, dia: String, textos: List<String>): List<String> {
        val p = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val vistos = if (p.getString("dia", "") == dia) p.getStringSet("vistos", emptySet())!!.toMutableSet() else mutableSetOf()
        val novos = textos.filter { vistos.add(it) }
        p.edit().putString("dia", dia).putStringSet("vistos", vistos).apply()
        return novos
    }

    /** Refaz os alarmes dos blocos de hoje que ainda não começaram (cancela os antigos). */
    fun alarmes(c: Context, dia: String, blocos: List<Triple<String, String, String>>) {
        val am = c.getSystemService(AlarmManager::class.java)
        val p = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        for (cod in p.getStringSet("alarmes", emptySet())!!) {
            am.cancel(pendenteAlarme(c, cod.toInt(), Intent(c, AlarmeReceiver::class.java)))
        }
        val agora = LocalDateTime.now()
        val codigos = mutableSetOf<String>()
        for ((id, titulo, inicio) in blocos) {
            val hora = runCatching { LocalTime.parse(inicio) }.getOrNull() ?: continue
            val quando = LocalDateTime.of(LocalDate.parse(dia), hora)
            if (!quando.isAfter(agora)) continue
            val cod = id.hashCode()
            val intent = Intent(c, AlarmeReceiver::class.java)
                .putExtra("bloco", id).putExtra("titulo", titulo).putExtra("inicio", inicio).putExtra("dia", dia)
            val ms = quando.atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
            val pi = pendenteAlarme(c, cod, intent)
            if (Build.VERSION.SDK_INT < 31 || am.canScheduleExactAlarms()) {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, ms, pi)
            } else {
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, ms, pi)
            }
            codigos.add(cod.toString())
        }
        p.edit().putStringSet("alarmes", codigos).apply()
    }

    private fun pendenteAlarme(c: Context, cod: Int, intent: Intent): PendingIntent =
        PendingIntent.getBroadcast(c, cod, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
}

/** A rodada do vigia: alertas novos viram notificação e os alarmes do dia são refeitos. */
class Vigia(contexto: Context, params: WorkerParameters) : CoroutineWorker(contexto, params) {
    override suspend fun doWork(): Result {
        val c = applicationContext
        val api = Config.api(c) ?: return Result.success()
        return try {
            val d = api.disciplina()
            val dia = d.getString("data")
            val alertas = d.getJSONArray("alertas")
            val porTexto = (0 until alertas.length()).associate {
                val a = alertas.getJSONObject(it)
                a.getString("texto") to a.getString("nivel")
            }
            for (texto in Avisos.novosAlertas(c, dia, porTexto.keys.toList())) {
                val critico = porTexto[texto] == "critico"
                Avisos.notificar(
                    c, texto.hashCode(), Avisos.CANAL_COBRADOR,
                    if (critico) "Cobrador: entrega em risco" else "Cobrador", texto, "alertas",
                )
            }
            val treino = runCatching { api.ativa() }.getOrNull()
            if (treino != null && !Pulso.servicoAtivo.value && Avisos.novosAlertas(c, dia, listOf("treino:" + treino.id)).isNotEmpty()) {
                Avisos.notificar(
                    c, treino.id.hashCode(), Avisos.CANAL_COBRADOR, "Treino em andamento",
                    "Toque para acompanhar no relógio (batimentos e descanso).", "treino",
                )
            }
            val blocos = api.agenda(dia).getJSONArray("blocos")
            Avisos.alarmes(
                c, dia,
                (0 until blocos.length()).map { blocos.getJSONObject(it) }.filter { !it.optBoolean("feito") }.map {
                    Triple(it.getString("id"), it.getString("titulo"), it.getString("inicio"))
                },
            )
            Result.success()
        } catch (e: ApiErro) {
            Result.retry()
        }
    }
}

/** Dispara o alarme do bloco e trata o botão "Feito" da notificação. */
class AlarmeReceiver : BroadcastReceiver() {
    override fun onReceive(c: Context, intent: Intent) {
        val bloco = intent.getStringExtra("bloco") ?: return
        val dia = intent.getStringExtra("dia") ?: return
        val id = bloco.hashCode()
        if (intent.action == ACAO_FEITO) {
            val pendente = goAsync()
            CoroutineScope(Dispatchers.IO).launch {
                try {
                    Config.api(c)?.marcarBloco(dia, bloco)
                    c.getSystemService(android.app.NotificationManager::class.java).cancel(id)
                } catch (_: ApiErro) {
                    Avisos.notificar(c, id, Avisos.CANAL_COBRADOR, "Não marquei", "Sem conexão: marque na Agenda.", "agenda")
                } finally {
                    pendente.finish()
                }
            }
            return
        }
        Avisos.canais(c)
        val feito = Notification.Action.Builder(
            null, "Feito",
            PendingIntent.getBroadcast(
                c, id + 1, Intent(intent).setClass(c, AlarmeReceiver::class.java).setAction(ACAO_FEITO),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            ),
        ).build()
        Avisos.notificar(
            c, id, Avisos.CANAL_ALARME, "Agora: ${intent.getStringExtra("titulo")}",
            "Bloco das ${intent.getStringExtra("inicio")}. Bora começar.", "agenda", listOf(feito),
        )
    }

    companion object {
        const val ACAO_FEITO = "com.thiagobenevide.agent.relogio.FEITO"
    }
}
