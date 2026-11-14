package com.thiagobenevide.agent.watch

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import androidx.health.services.client.HealthServices
import androidx.health.services.client.PassiveListenerService
import androidx.health.services.client.data.DataPointContainer
import androidx.health.services.client.data.DataType
import androidx.health.services.client.data.PassiveListenerConfig
import java.time.Instant
import java.time.LocalDate

/**
 * Health Services passive reading, the same one the watch already does all day for Samsung Health:
 * steps, calories, distance, floors and (with the background permission) heartbeat. It stays
 * registered in the system — it arrives with the app closed and the screen off — and the values go to
 * SharedPreferences, from where [Pulse] rereads them on open.
 */
object Passive {
    private const val PREFS = "passivo"

    /** Heartbeat with the app closed: BODY_SENSORS_BACKGROUND (Wear OS 4–5) or the Health Connect one (6). */
    val backgroundPermission: String? = when {
        Build.VERSION.SDK_INT >= 36 -> "android.permission.health.READ_HEALTH_DATA_IN_BACKGROUND"
        Build.VERSION.SDK_INT >= 33 -> Manifest.permission.BODY_SENSORS_BACKGROUND
        else -> null // up to Wear OS 3, BODY_SENSORS already works in the background
    }

    fun backgroundAuthorized(c: Context) =
        Pulse.authorized(c) && (backgroundPermission == null || c.checkSelfPermission(backgroundPermission) == PackageManager.PERMISSION_GRANTED)

    /** (Re)registers the service with what the permissions allow reading; called on app open and at boot. */
    fun register(c: Context) {
        if (!Pulse.activityAuthorized(c)) return
        val kinds = mutableSetOf<DataType<*, *>>(
            DataType.STEPS_DAILY, DataType.CALORIES_DAILY, DataType.DISTANCE_DAILY, DataType.FLOORS_DAILY,
        )
        if (backgroundAuthorized(c)) kinds += DataType.HEART_RATE_BPM
        val config = PassiveListenerConfig.builder().setDataTypes(kinds).build()
        runCatching {
            val cliente = HealthServices.getClient(c).passiveMonitoringClient
            cliente.setPassiveListenerServiceAsync(PassiveService::class.java, config)
            cliente.flushAsync()
        }
    }

    /** Stored values from today for [Pulse] (yesterday's totals no longer count). */
    fun load(c: Context) {
        val p = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (p.getString("dia", null) == LocalDate.now().toString()) {
            if (p.contains("passos")) Pulse.steps.value = p.getLong("passos", 0)
            if (p.contains("calorias")) Pulse.dailyCalories.value = p.getFloat("calorias", 0f).toDouble()
            if (p.contains("distancia")) Pulse.dailyDistance.value = p.getFloat("distancia", 0f).toDouble()
            if (p.contains("andares")) Pulse.dailyFloors.value = p.getFloat("andares", 0f).toDouble()
        }
        if (p.contains("bpm")) Pulse.lastBpm.value = p.getInt("bpm", 0) to p.getLong("bpm_ms", 0)
    }

    fun record(c: Context, data: DataPointContainer) {
        val p = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val e = p.edit()
        val today = LocalDate.now().toString()
        if (p.getString("dia", null) != today) {
            e.remove("passos").remove("calorias").remove("distancia").remove("andares")
        }
        e.putString("dia", today)
        data.getData(DataType.STEPS_DAILY).lastOrNull()?.let { e.putLong("passos", it.value); Pulse.steps.value = it.value }
        data.getData(DataType.CALORIES_DAILY).lastOrNull()?.let { e.putFloat("calorias", it.value.toFloat()); Pulse.dailyCalories.value = it.value }
        data.getData(DataType.DISTANCE_DAILY).lastOrNull()?.let { e.putFloat("distancia", it.value.toFloat()); Pulse.dailyDistance.value = it.value }
        data.getData(DataType.FLOORS_DAILY).lastOrNull()?.let { e.putFloat("andares", it.value.toFloat()); Pulse.dailyFloors.value = it.value }
        val boot = Instant.ofEpochMilli(System.currentTimeMillis() - SystemClock.elapsedRealtime())
        data.getData(DataType.HEART_RATE_BPM).filter { it.value >= 25 }.maxByOrNull { it.timeDurationFromBoot }?.let {
            val ms = it.getTimeInstant(boot).toEpochMilli()
            e.putInt("bpm", it.value.toInt()).putLong("bpm_ms", ms)
            Pulse.lastBpm.value = it.value.toInt() to ms
        }
        e.apply()
    }
}

/** Receives the passive sensor batches even with the app closed (the system wakes the service). */
class PassiveService : PassiveListenerService() {
    override fun onNewDataPointsReceived(dataPoints: DataPointContainer) = Passive.record(this, dataPoints)
}

/** The passive registration does not survive a watch restart: redo it at boot. */
class PassiveBootReceiver : BroadcastReceiver() {
    override fun onReceive(c: Context, i: Intent) {
        if (i.action == Intent.ACTION_BOOT_COMPLETED) Passive.register(c)
    }
}
