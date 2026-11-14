package com.thiagobenevide.agent.watch

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf

/**
 * Workout state shared by the screens and the [WorkoutService] (same process). The service is
 * the one that reads the sensor and vibrates; the screens only show and announce what changed.
 */
object Pulse {
    /** Last heartbeat read (null with no reading yet). */
    val bpm = mutableStateOf<Int?>(null)

    /** "fora do pulso", "procurando…" or null while reading. */
    val status = mutableStateOf<String?>(null)

    /** Workout in progress as seen by the screens or the service; the App starts and stops the service from it. */
    val activeSession = mutableStateOf<String?>(null)

    /** Service running: it vibrates at the end of the rest (the screen does not need to). */
    val serviceActive = mutableStateOf(false)

    /** Statistics of the current workout (or of the spot measurement); [version] notifies the screens on each reading. */
    val statistics = Statistics()
    val version = mutableIntStateOf(0)

    /** Exercise calories (Health Services; null without the activity permission). */
    val calories = mutableStateOf<Double?>(null)

    /** Day totals from the passive sensor: steps, calories, distance (m) and floors. */
    val steps = mutableStateOf<Long?>(null)
    val dailyCalories = mutableStateOf<Double?>(null)
    val dailyDistance = mutableStateOf<Double?>(null)
    val dailyFloors = mutableStateOf<Double?>(null)

    /** Last heartbeat from the passive sensor (value, ms): what the watch measured on its own, without the app open. */
    val lastBpm = mutableStateOf<Pair<Int, Long>?>(null)

    /** One heartbeat reading: screen state, statistics and chart series. */
    fun register(ms: Long, value: Int) {
        bpm.value = value
        status.value = null
        statistics.register(ms, value)
        version.intValue++
    }

    fun reset() {
        statistics.clean()
        calories.value = null
        version.intValue++
    }

    /** Steps/calories/distance permission (passive sensor and workout calories). */
    const val ACTIVITY = Manifest.permission.ACTIVITY_RECOGNITION

    fun activityAuthorized(c: Context) = c.checkSelfPermission(ACTIVITY) == PackageManager.PERMISSION_GRANTED

    /** End of the rest in wrist-watch ms (null outside the rest or paused). */
    @Volatile var restUntilMs: Long? = null

    /** Notification text: "Supino 2/4" or "Descanso". */
    @Volatile var stage: String = "Treino"

    /** BODY_SENSORS up to Wear OS 5; on 6 (API 36) the permission is the Health Connect one. */
    val permission: String =
        if (Build.VERSION.SDK_INT >= 36) "android.permission.health.READ_HEART_RATE" else Manifest.permission.BODY_SENSORS

    fun authorized(c: Context) = c.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    /** What the screens know about the session (a command just changed the rest, for example). */
    fun update(s: Session?) {
        activeSession.value = s?.id?.takeIf { s.state == "andamento" }
        restUntilMs = if (s != null && s.serverPhase == "descanso" && !s.paused) s.restUntilMs?.minus(s.offsetMs) else null
        stage = when {
            s == null -> "Treino"
            s.serverPhase == "descanso" -> "Descanso"
            else -> s.current?.let { "${it.name} ${it.doneSteps + 1}/${it.planned}" } ?: "Treino"
        }
    }

    fun enable(c: Context, id: String) {
        c.startForegroundService(Intent(c, WorkoutService::class.java).putExtra("id", id))
    }

    fun turnOff(c: Context) {
        c.stopService(Intent(c, WorkoutService::class.java))
    }
}
