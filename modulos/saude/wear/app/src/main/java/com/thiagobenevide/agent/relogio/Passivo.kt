package com.thiagobenevide.agent.relogio

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
 * Leitura passiva do Health Services, a mesma que o relógio já faz o dia todo para o Samsung Health:
 * passos, calorias, distância, andares e (com a permissão de segundo plano) o batimento. Fica
 * registrada no sistema — chega com o app fechado e a tela apagada — e os valores vão para
 * SharedPreferences, de onde o [Pulso] relê ao abrir.
 */
object Passivo {
    private const val PREFS = "passivo"

    /** Batimento com o app fechado: BODY_SENSORS_BACKGROUND (Wear OS 4–5) ou a do Health Connect (6). */
    val permissaoFundo: String? = when {
        Build.VERSION.SDK_INT >= 36 -> "android.permission.health.READ_HEALTH_DATA_IN_BACKGROUND"
        Build.VERSION.SDK_INT >= 33 -> Manifest.permission.BODY_SENSORS_BACKGROUND
        else -> null // até o Wear OS 3 o BODY_SENSORS já vale em segundo plano
    }

    fun fundoAutorizado(c: Context) =
        Pulso.autorizado(c) && (permissaoFundo == null || c.checkSelfPermission(permissaoFundo) == PackageManager.PERMISSION_GRANTED)

    /** (Re)registra o serviço com o que as permissões deixam ler; chamado ao abrir o app e no boot. */
    fun registrar(c: Context) {
        if (!Pulso.atividadeAutorizada(c)) return
        val tipos = mutableSetOf<DataType<*, *>>(
            DataType.STEPS_DAILY, DataType.CALORIES_DAILY, DataType.DISTANCE_DAILY, DataType.FLOORS_DAILY,
        )
        if (fundoAutorizado(c)) tipos += DataType.HEART_RATE_BPM
        val config = PassiveListenerConfig.builder().setDataTypes(tipos).build()
        runCatching {
            val cliente = HealthServices.getClient(c).passiveMonitoringClient
            cliente.setPassiveListenerServiceAsync(PassivoServico::class.java, config)
            cliente.flushAsync()
        }
    }

    /** Valores guardados de hoje para o [Pulso] (os totais de ontem não valem mais). */
    fun carregar(c: Context) {
        val p = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (p.getString("dia", null) == LocalDate.now().toString()) {
            if (p.contains("passos")) Pulso.passos.value = p.getLong("passos", 0)
            if (p.contains("calorias")) Pulso.caloriasDia.value = p.getFloat("calorias", 0f).toDouble()
            if (p.contains("distancia")) Pulso.distanciaDia.value = p.getFloat("distancia", 0f).toDouble()
            if (p.contains("andares")) Pulso.andaresDia.value = p.getFloat("andares", 0f).toDouble()
        }
        if (p.contains("bpm")) Pulso.ultimoBpm.value = p.getInt("bpm", 0) to p.getLong("bpm_ms", 0)
    }

    fun gravar(c: Context, dados: DataPointContainer) {
        val p = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val e = p.edit()
        val hoje = LocalDate.now().toString()
        if (p.getString("dia", null) != hoje) {
            e.remove("passos").remove("calorias").remove("distancia").remove("andares")
        }
        e.putString("dia", hoje)
        dados.getData(DataType.STEPS_DAILY).lastOrNull()?.let { e.putLong("passos", it.value); Pulso.passos.value = it.value }
        dados.getData(DataType.CALORIES_DAILY).lastOrNull()?.let { e.putFloat("calorias", it.value.toFloat()); Pulso.caloriasDia.value = it.value }
        dados.getData(DataType.DISTANCE_DAILY).lastOrNull()?.let { e.putFloat("distancia", it.value.toFloat()); Pulso.distanciaDia.value = it.value }
        dados.getData(DataType.FLOORS_DAILY).lastOrNull()?.let { e.putFloat("andares", it.value.toFloat()); Pulso.andaresDia.value = it.value }
        val boot = Instant.ofEpochMilli(System.currentTimeMillis() - SystemClock.elapsedRealtime())
        dados.getData(DataType.HEART_RATE_BPM).filter { it.value >= 25 }.maxByOrNull { it.timeDurationFromBoot }?.let {
            val ms = it.getTimeInstant(boot).toEpochMilli()
            e.putInt("bpm", it.value.toInt()).putLong("bpm_ms", ms)
            Pulso.ultimoBpm.value = it.value.toInt() to ms
        }
        e.apply()
    }
}

/** Recebe os lotes do sensor passivo mesmo com o app fechado (o sistema acorda o serviço). */
class PassivoServico : PassiveListenerService() {
    override fun onNewDataPointsReceived(dataPoints: DataPointContainer) = Passivo.gravar(this, dataPoints)
}

/** O registro passivo não sobrevive ao reinício do relógio: refaz no boot. */
class PassivoBootReceiver : BroadcastReceiver() {
    override fun onReceive(c: Context, i: Intent) {
        if (i.action == Intent.ACTION_BOOT_COMPLETED) Passivo.registrar(c)
    }
}
