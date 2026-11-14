package com.thiagobenevide.agent.watch

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
 * The watch's own notifications: coach alerts (`/api/painel/disciplina`, every 15 min through
 * WorkManager, each text once a day) and an alarm at the start of each block of the day's agenda
 * (exact AlarmManager, redone on every watcher round).
 */
object Warnings {
    const val COACH_CHANNEL = "cobrador"
    const val CHANNEL_ALARM = "alarme"
    const val WORKOUT_CHANNEL = "treino"
    private const val PREFS = "avisos"

    fun channels(c: Context) {
        val nm = c.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(COACH_CHANNEL, "Cobrador", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Alertas de disciplina e agenda"
                vibrationPattern = longArrayOf(0, 300, 200, 300)
                enableVibration(true)
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(WORKOUT_CHANNEL, "Treino em andamento", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Série, descanso e batimentos com a tela apagada"
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ALARM, "Início de bloco", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Hora de começar o bloco da agenda"
                vibrationPattern = longArrayOf(0, 600, 250, 600, 250, 600)
                enableVibration(true)
            },
        )
    }

    /** Starts the periodic watcher and runs it once right away. */
    fun schedule(c: Context) {
        channels(c)
        val wm = WorkManager.getInstance(c)
        wm.enqueueUniquePeriodicWork(
            "vigia", ExistingPeriodicWorkPolicy.KEEP,
            PeriodicWorkRequestBuilder<Vigia>(15, TimeUnit.MINUTES).build(),
        )
        wm.enqueueUniqueWork("vigia-agora", ExistingWorkPolicy.REPLACE, OneTimeWorkRequestBuilder<Vigia>().build())
    }

    private fun open(c: Context, screen: String, code: Int): PendingIntent = PendingIntent.getActivity(
        c, code, Intent(c, MainActivity::class.java).putExtra("tela", screen),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    fun sendNotification(c: Context, id: Int, channel: String, title: String, text: String, screen: String, actions: List<Notification.Action> = emptyList()) {
        val n = Notification.Builder(c, channel)
            .setSmallIcon(R.drawable.ic_agent_mono)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setAutoCancel(true)
            .setCategory(if (channel == CHANNEL_ALARM) Notification.CATEGORY_ALARM else Notification.CATEGORY_REMINDER)
            .setContentIntent(open(c, screen, id))
        actions.forEach { n.addAction(it) }
        if (Build.VERSION.SDK_INT >= 33 &&
            c.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED
        ) return
        c.getSystemService(NotificationManager::class.java).notify(id, n.build())
    }

    /** New alerts of the day: returns the ones not shown yet and marks them as seen. */
    fun newAlerts(c: Context, day: String, texts: List<String>): List<String> {
        val p = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val seen = if (p.getString("dia", "") == day) p.getStringSet("vistos", emptySet())!!.toMutableSet() else mutableSetOf()
        val newOnes = texts.filter { seen.add(it) }
        p.edit().putString("dia", day).putStringSet("vistos", seen).apply()
        return newOnes
    }

    /** Redoes the alarms for today's blocks that have not started yet (cancels the old ones). */
    fun alarmes(c: Context, day: String, blocks: List<Triple<String, String, String>>) {
        val am = c.getSystemService(AlarmManager::class.java)
        val p = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        for (cod in p.getStringSet("alarmes", emptySet())!!) {
            am.cancel(pendingAlarm(c, cod.toInt(), Intent(c, AlarmReceiver::class.java)))
        }
        val now = LocalDateTime.now()
        val codigos = mutableSetOf<String>()
        for ((id, title, start) in blocks) {
            val hour = runCatching { LocalTime.parse(start) }.getOrNull() ?: continue
            val moment = LocalDateTime.of(LocalDate.parse(day), hour)
            if (!moment.isAfter(now)) continue
            val cod = id.hashCode()
            val intent = Intent(c, AlarmReceiver::class.java)
                .putExtra("bloco", id).putExtra("titulo", title).putExtra("inicio", start).putExtra("dia", day)
            val ms = moment.atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
            val pi = pendingAlarm(c, cod, intent)
            if (Build.VERSION.SDK_INT < 31 || am.canScheduleExactAlarms()) {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, ms, pi)
            } else {
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, ms, pi)
            }
            codigos.add(cod.toString())
        }
        p.edit().putStringSet("alarmes", codigos).apply()
    }

    private fun pendingAlarm(c: Context, cod: Int, intent: Intent): PendingIntent =
        PendingIntent.getBroadcast(c, cod, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
}

/** The watcher round: new alerts become notifications and the day's alarms are redone. */
class Vigia(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val c = applicationContext
        val api = Config.api(c) ?: return Result.success()
        return try {
            val d = api.subject()
            val day = d.getString("data")
            val alerts = d.getJSONArray("alertas")
            val byText = (0 until alerts.length()).associate {
                val a = alerts.getJSONObject(it)
                a.getString("texto") to a.getString("nivel")
            }
            for (text in Warnings.newAlerts(c, day, byText.keys.toList())) {
                val critico = byText[text] == "critico"
                Warnings.sendNotification(
                    c, text.hashCode(), Warnings.COACH_CHANNEL,
                    if (critico) "Cobrador: entrega em risco" else "Cobrador", text, "alertas",
                )
            }
            val workout = runCatching { api.active() }.getOrNull()
            if (workout != null && !Pulse.serviceActive.value && Warnings.newAlerts(c, day, listOf("treino:" + workout.id)).isNotEmpty()) {
                Warnings.sendNotification(
                    c, workout.id.hashCode(), Warnings.COACH_CHANNEL, "Treino em andamento",
                    "Toque para acompanhar no relógio (batimentos e descanso).", "treino",
                )
            }
            val blocks = api.agenda(day).getJSONArray("blocos")
            Warnings.alarmes(
                c, day,
                (0 until blocks.length()).map { blocks.getJSONObject(it) }.filter { !it.optBoolean("feito") }.map {
                    Triple(it.getString("id"), it.getString("titulo"), it.getString("inicio"))
                },
            )
            Result.success()
        } catch (e: ApiError) {
            Result.retry()
        }
    }
}

/** Fires the block alarm and handles the notification's "Feito" button. */
class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(c: Context, intent: Intent) {
        val block = intent.getStringExtra("bloco") ?: return
        val day = intent.getStringExtra("dia") ?: return
        val id = block.hashCode()
        if (intent.action == ACTION_DONE) {
            val pending = goAsync()
            CoroutineScope(Dispatchers.IO).launch {
                try {
                    Config.api(c)?.markBlock(day, block)
                    c.getSystemService(android.app.NotificationManager::class.java).cancel(id)
                } catch (_: ApiError) {
                    Warnings.sendNotification(c, id, Warnings.COACH_CHANNEL, "Não marquei", "Sem conexão: marque na Agenda.", "agenda")
                } finally {
                    pending.finish()
                }
            }
            return
        }
        Warnings.channels(c)
        val done = Notification.Action.Builder(
            null, "Feito",
            PendingIntent.getBroadcast(
                c, id + 1, Intent(intent).setClass(c, AlarmReceiver::class.java).setAction(ACTION_DONE),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            ),
        ).build()
        Warnings.sendNotification(
            c, id, Warnings.CHANNEL_ALARM, "Agora: ${intent.getStringExtra("titulo")}",
            "Bloco das ${intent.getStringExtra("inicio")}. Bora começar.", "agenda", listOf(done),
        )
    }

    companion object {
        const val ACTION_DONE = "com.thiagobenevide.agent.relogio.FEITO"
    }
}
