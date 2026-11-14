package com.thiagobenevide.agent.watch

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import androidx.concurrent.futures.await
import androidx.core.app.NotificationCompat
import androidx.health.services.client.ExerciseUpdateCallback
import androidx.health.services.client.HealthServices
import androidx.health.services.client.MeasureCallback
import androidx.health.services.client.data.Availability
import androidx.health.services.client.data.DataPointContainer
import androidx.health.services.client.data.DataType
import androidx.health.services.client.data.DataTypeAvailability
import androidx.health.services.client.data.DeltaDataType
import androidx.health.services.client.data.ExerciseConfig
import androidx.health.services.client.data.ExerciseLapSummary
import androidx.health.services.client.data.ExerciseTrackedStatus
import androidx.health.services.client.data.ExerciseType
import androidx.health.services.client.data.ExerciseUpdate
import androidx.health.services.client.data.SampleDataPoint
import androidx.wear.ongoing.OngoingActivity
import androidx.wear.ongoing.Status
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.time.Instant

/**
 * Background workout: foreground service (health type) with a Health
 * Services exercise, which keeps the heartbeat sensor reading with the screen off or another app in front
 * (Spotify, etc.). Every 10 s it sends the heartbeats and receives the workout phase; vibrates at the end of the
 * rest and shows the countdown in the notification and on the watch face (ongoing activity). Stops when the
 * workout ends, including when it is finished on the phone.
 */
class WorkoutService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val batch = mutableListOf<Pair<Instant, Double>>()
    private var id: String? = null
    private var api: Api? = null
    private var ownExercise = false
    private var medida: MeasureCallback? = null
    private var warned: Long? = null
    private var lastNotification = ""

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val newItem = intent?.getStringExtra("id")
        val a = Config.api(this)
        if (newItem == null || a == null || !Pulse.authorized(this)) {
            stopSelf()
            return START_NOT_STICKY
        }
        Warnings.channels(this)
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_HEALTH)
        } else {
            startForeground(NOTIFICATION, notification())
        }
        if (newItem == id) return START_REDELIVER_INTENT
        id = newItem
        api = a
        Pulse.reset()
        Pulse.serviceActive.value = true
        Pulse.activeSession.value = newItem
        scope.launch { startSensor() }
        scope.launch { cycleEnvio(a, newItem) }
        scope.launch { restCycle() }
        return START_REDELIVER_INTENT
    }

    // --- sensor ---

    private fun receive(points: List<SampleDataPoint<Double>>) {
        val boot = Instant.ofEpochMilli(System.currentTimeMillis() - SystemClock.elapsedRealtime())
        for (p in points) {
            if (p.value < 25) continue // sensor ainda acertando
            val moment = p.getTimeInstant(boot)
            Pulse.register(moment.toEpochMilli(), p.value.toInt())
            synchronized(batch) { batch.add(moment to p.value) }
        }
    }

    private fun disponibilidade(availability: Availability) {
        Pulse.status.value = when (availability) {
            DataTypeAvailability.AVAILABLE -> null
            DataTypeAvailability.UNAVAILABLE_DEVICE_OFF_BODY -> "fora do pulso"
            else -> "procurando…"
        }
    }

    /** Own exercise (reads in the background); if another app already has an exercise, uses the simple measurement. */
    @SuppressLint("WrongConstant", "RestrictedApi") // lint false positive on the companion constants
    private suspend fun startSensor() {
        Pulse.status.value = "procurando…"
        val cliente = HealthServices.getClient(this)
        val ex = cliente.exerciseClient
        try {
            val info = ex.getCurrentExerciseInfoAsync().await()
            val capacidades = ex.getCapabilitiesAsync().await()
            val kinds = capacidades.supportedExerciseTypes
            val kind = listOf(ExerciseType.STRENGTH_TRAINING, ExerciseType.WEIGHTLIFTING, ExerciseType.WORKOUT)
                .firstOrNull { it in kinds }
            // calories only with the activity permission: without it the whole exercise would be refused
            val data = buildSet<DataType<*, *>> {
                add(DataType.HEART_RATE_BPM)
                val supported = kind?.let { capacidades.getExerciseTypeCapabilities(it).supportedDataTypes }.orEmpty()
                if (Pulse.activityAuthorized(this@WorkoutService) && DataType.CALORIES_TOTAL in supported) {
                    add(DataType.CALORIES_TOTAL)
                }
            }
            if (info.exerciseTrackedStatus != ExerciseTrackedStatus.OTHER_APP_IN_PROGRESS && kind != null) {
                ex.setUpdateCallback(object : ExerciseUpdateCallback {
                    override fun onExerciseUpdateReceived(update: ExerciseUpdate) {
                        receive(update.latestMetrics.getData(DataType.HEART_RATE_BPM))
                        update.latestMetrics.getData(DataType.CALORIES_TOTAL)?.let { Pulse.calories.value = it.total }
                    }

                    override fun onAvailabilityChanged(dataType: DataType<*, *>, availability: Availability) =
                        disponibilidade(availability)

                    override fun onLapSummaryReceived(lapSummary: ExerciseLapSummary) {}
                    override fun onRegistered() {}
                    override fun onRegistrationFailed(throwable: Throwable) {}
                })
                if (info.exerciseTrackedStatus != ExerciseTrackedStatus.OWNED_EXERCISE_IN_PROGRESS) {
                    ex.startExerciseAsync(
                        ExerciseConfig.builder(kind)
                            .setDataTypes(data)
                            .setIsAutoPauseAndResumeEnabled(false)
                            .setIsGpsEnabled(false)
                            .build(),
                    ).await()
                }
                ownExercise = true
                return
            }
        } catch (_: Exception) {
            // no exercise support: falls back to the simple measurement
        }
        val cb = object : MeasureCallback {
            override fun onAvailabilityChanged(dataType: DeltaDataType<*, *>, availability: Availability) =
                disponibilidade(availability)

            override fun onDataReceived(data: DataPointContainer) = receive(data.getData(DataType.HEART_RATE_BPM))
        }
        medida = cb
        cliente.measureClient.registerMeasureCallback(DataType.HEART_RATE_BPM, cb)
    }

    // --- servidor ---

    private suspend fun cycleEnvio(a: Api, session: String) {
        while (scope.isActive) {
            val pendingItems = synchronized(batch) { batch.toList().also { batch.clear() } }
            try {
                val r = a.sendFc(session, pendingItems)
                if (r.optString("estado") != "andamento") {
                    Pulse.activeSession.value = null
                    stopSelf()
                    return
                }
                apply(r)
            } catch (_: ApiError) {
                // no network: returns to the batch (up to ~10 min) and tries on the next cycle
                synchronized(batch) {
                    batch.addAll(0, pendingItems)
                    while (batch.size > 600) batch.removeAt(0)
                }
            }
            delay(10_000)
        }
    }

    /** Phase and rest that came with the answer (what was done on the phone also arrives here). */
    private fun apply(r: JSONObject) {
        val c = r.optJSONObject("controle") ?: return
        val recebida = System.currentTimeMillis()
        val offset = runCatching { Instant.parse(r.getString("agora")).toEpochMilli() - recebida }.getOrDefault(0)
        val rest = c.optString("fase") == "descanso" && !c.optBoolean("pausado")
        Pulse.restUntilMs = if (rest && !c.isNull("descanso_ate")) {
            Instant.parse(c.getString("descanso_ate")).toEpochMilli() - offset
        } else {
            null
        }
        Pulse.stage = when {
            c.optBoolean("pausado") -> "Pausado"
            c.optString("fase") == "descanso" -> "Descanso"
            else -> r.optString("atual").ifBlank { "Treino" }
        }
    }

    /** Every second: vibrates when the rest ends and updates the notification if something changed. */
    private suspend fun restCycle() {
        while (scope.isActive) {
            val until = Pulse.restUntilMs
            if (until != null && System.currentTimeMillis() >= until && warned != until) {
                warned = until
                getSystemService(Vibrator::class.java)?.vibrate(
                    VibrationEffect.createWaveform(longArrayOf(0, 500, 200, 500, 200, 500), -1),
                )
            }
            val key = "${Pulse.stage}|${until?.takeIf { it > System.currentTimeMillis() }}|${Pulse.bpm.value}|${Pulse.status.value}"
            if (key != lastNotification) {
                lastNotification = key
                getSystemService(NotificationManager::class.java).notify(NOTIFICATION, notification())
            }
            delay(1000)
        }
    }

    // --- notification / watch face ---

    private fun notification(): Notification {
        val until = Pulse.restUntilMs?.takeIf { it > System.currentTimeMillis() }
        val bpm = Pulse.bpm.value
        val text = buildString {
            append(if (until != null) "Descanso" else Pulse.stage)
            when {
                Pulse.status.value == "fora do pulso" -> append(" · ♥ fora do pulso")
                bpm != null -> append(" · ♥$bpm")
            }
        }
        val toque = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).putExtra("tela", "treino"),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val b = NotificationCompat.Builder(this, Warnings.WORKOUT_CHANNEL)
            .setSmallIcon(R.drawable.ic_agent_mono)
            .setContentTitle("Treino")
            .setContentText(text)
            .setCategory(NotificationCompat.CATEGORY_WORKOUT)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setContentIntent(toque)
        if (until != null) b.setUsesChronometer(true).setChronometerCountDown(true).setWhen(until)
        val status = Status.Builder().addTemplate("#t#").addPart("t", Status.TextPart(text))
        OngoingActivity.Builder(applicationContext, NOTIFICATION, b)
            .setStaticIcon(R.drawable.ic_agent_mono)
            .setTouchIntent(toque)
            .setStatus(status.build())
            .build()
            .apply(applicationContext)
        return b.build()
    }

    override fun onDestroy() {
        val cliente = HealthServices.getClient(this)
        if (ownExercise) {
            cliente.exerciseClient.endExerciseAsync()
        }
        medida?.let { cliente.measureClient.unregisterMeasureCallbackAsync(DataType.HEART_RATE_BPM, it) }
        // last heartbeats not sent yet
        val a = api
        val session = id
        val pendingItems = synchronized(batch) { batch.toList() }
        if (a != null && session != null && pendingItems.isNotEmpty()) {
            CoroutineScope(Dispatchers.IO).launch { runCatching { a.sendFc(session, pendingItems) } }
        }
        scope.cancel()
        Pulse.serviceActive.value = false
        Pulse.bpm.value = null
        Pulse.status.value = null
        super.onDestroy()
    }

    companion object {
        const val NOTIFICATION = 7001
    }
}
