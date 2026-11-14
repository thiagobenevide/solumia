package com.thiagobenevide.agent.relogio

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
 * Treino em segundo plano: serviço em primeiro plano (tipo health) com um exercício do Health
 * Services, que mantém o sensor de batimentos lendo com a tela apagada ou outro app na frente
 * (Spotify, etc.). A cada 10 s manda os batimentos e recebe a fase do treino; vibra no fim do
 * descanso e mostra a contagem na notificação e no mostrador (atividade em andamento). Para quando o
 * treino termina, inclusive se for concluído no celular.
 */
class TreinoServico : Service() {
    private val escopo = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val lote = mutableListOf<Pair<Instant, Double>>()
    private var id: String? = null
    private var api: Api? = null
    private var exercicioProprio = false
    private var medida: MeasureCallback? = null
    private var avisado: Long? = null
    private var ultimaNotificacao = ""

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val novo = intent?.getStringExtra("id")
        val a = Config.api(this)
        if (novo == null || a == null || !Pulso.autorizado(this)) {
            stopSelf()
            return START_NOT_STICKY
        }
        Avisos.canais(this)
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICACAO, notificacao(), ServiceInfo.FOREGROUND_SERVICE_TYPE_HEALTH)
        } else {
            startForeground(NOTIFICACAO, notificacao())
        }
        if (novo == id) return START_REDELIVER_INTENT
        id = novo
        api = a
        Pulso.zerar()
        Pulso.servicoAtivo.value = true
        Pulso.sessaoAtiva.value = novo
        escopo.launch { comecarSensor() }
        escopo.launch { cicloEnvio(a, novo) }
        escopo.launch { cicloDescanso() }
        return START_REDELIVER_INTENT
    }

    // --- sensor ---

    private fun receber(pontos: List<SampleDataPoint<Double>>) {
        val boot = Instant.ofEpochMilli(System.currentTimeMillis() - SystemClock.elapsedRealtime())
        for (p in pontos) {
            if (p.value < 25) continue // sensor ainda acertando
            val quando = p.getTimeInstant(boot)
            Pulso.registrar(quando.toEpochMilli(), p.value.toInt())
            synchronized(lote) { lote.add(quando to p.value) }
        }
    }

    private fun disponibilidade(availability: Availability) {
        Pulso.situacao.value = when (availability) {
            DataTypeAvailability.AVAILABLE -> null
            DataTypeAvailability.UNAVAILABLE_DEVICE_OFF_BODY -> "fora do pulso"
            else -> "procurando…"
        }
    }

    /** Exercício próprio (lê em segundo plano); se outro app já tem um exercício, usa a medição simples. */
    @SuppressLint("WrongConstant", "RestrictedApi") // falso positivo do lint nas constantes do companion
    private suspend fun comecarSensor() {
        Pulso.situacao.value = "procurando…"
        val cliente = HealthServices.getClient(this)
        val ex = cliente.exerciseClient
        try {
            val info = ex.getCurrentExerciseInfoAsync().await()
            val capacidades = ex.getCapabilitiesAsync().await()
            val tipos = capacidades.supportedExerciseTypes
            val tipo = listOf(ExerciseType.STRENGTH_TRAINING, ExerciseType.WEIGHTLIFTING, ExerciseType.WORKOUT)
                .firstOrNull { it in tipos }
            // calorias só com a permissão de atividade: sem ela o exercício inteiro seria recusado
            val dados = buildSet<DataType<*, *>> {
                add(DataType.HEART_RATE_BPM)
                val suportados = tipo?.let { capacidades.getExerciseTypeCapabilities(it).supportedDataTypes }.orEmpty()
                if (Pulso.atividadeAutorizada(this@TreinoServico) && DataType.CALORIES_TOTAL in suportados) {
                    add(DataType.CALORIES_TOTAL)
                }
            }
            if (info.exerciseTrackedStatus != ExerciseTrackedStatus.OTHER_APP_IN_PROGRESS && tipo != null) {
                ex.setUpdateCallback(object : ExerciseUpdateCallback {
                    override fun onExerciseUpdateReceived(update: ExerciseUpdate) {
                        receber(update.latestMetrics.getData(DataType.HEART_RATE_BPM))
                        update.latestMetrics.getData(DataType.CALORIES_TOTAL)?.let { Pulso.calorias.value = it.total }
                    }

                    override fun onAvailabilityChanged(dataType: DataType<*, *>, availability: Availability) =
                        disponibilidade(availability)

                    override fun onLapSummaryReceived(lapSummary: ExerciseLapSummary) {}
                    override fun onRegistered() {}
                    override fun onRegistrationFailed(throwable: Throwable) {}
                })
                if (info.exerciseTrackedStatus != ExerciseTrackedStatus.OWNED_EXERCISE_IN_PROGRESS) {
                    ex.startExerciseAsync(
                        ExerciseConfig.builder(tipo)
                            .setDataTypes(dados)
                            .setIsAutoPauseAndResumeEnabled(false)
                            .setIsGpsEnabled(false)
                            .build(),
                    ).await()
                }
                exercicioProprio = true
                return
            }
        } catch (_: Exception) {
            // sem suporte a exercício: cai na medição simples
        }
        val cb = object : MeasureCallback {
            override fun onAvailabilityChanged(dataType: DeltaDataType<*, *>, availability: Availability) =
                disponibilidade(availability)

            override fun onDataReceived(data: DataPointContainer) = receber(data.getData(DataType.HEART_RATE_BPM))
        }
        medida = cb
        cliente.measureClient.registerMeasureCallback(DataType.HEART_RATE_BPM, cb)
    }

    // --- servidor ---

    private suspend fun cicloEnvio(a: Api, sessao: String) {
        while (escopo.isActive) {
            val pendentes = synchronized(lote) { lote.toList().also { lote.clear() } }
            try {
                val r = a.enviarFc(sessao, pendentes)
                if (r.optString("estado") != "andamento") {
                    Pulso.sessaoAtiva.value = null
                    stopSelf()
                    return
                }
                aplicar(r)
            } catch (_: ApiErro) {
                // sem rede: devolve ao lote (até ~10 min) e tenta no próximo ciclo
                synchronized(lote) {
                    lote.addAll(0, pendentes)
                    while (lote.size > 600) lote.removeAt(0)
                }
            }
            delay(10_000)
        }
    }

    /** Fase e descanso que vieram com a resposta (o que foi feito no celular também chega aqui). */
    private fun aplicar(r: JSONObject) {
        val c = r.optJSONObject("controle") ?: return
        val recebida = System.currentTimeMillis()
        val offset = runCatching { Instant.parse(r.getString("agora")).toEpochMilli() - recebida }.getOrDefault(0)
        val descanso = c.optString("fase") == "descanso" && !c.optBoolean("pausado")
        Pulso.descansoAteMs = if (descanso && !c.isNull("descanso_ate")) {
            Instant.parse(c.getString("descanso_ate")).toEpochMilli() - offset
        } else {
            null
        }
        Pulso.etapa = when {
            c.optBoolean("pausado") -> "Pausado"
            c.optString("fase") == "descanso" -> "Descanso"
            else -> r.optString("atual").ifBlank { "Treino" }
        }
    }

    /** A cada segundo: vibra quando o descanso acaba e atualiza a notificação se algo mudou. */
    private suspend fun cicloDescanso() {
        while (escopo.isActive) {
            val ate = Pulso.descansoAteMs
            if (ate != null && System.currentTimeMillis() >= ate && avisado != ate) {
                avisado = ate
                getSystemService(Vibrator::class.java)?.vibrate(
                    VibrationEffect.createWaveform(longArrayOf(0, 500, 200, 500, 200, 500), -1),
                )
            }
            val chave = "${Pulso.etapa}|${ate?.takeIf { it > System.currentTimeMillis() }}|${Pulso.bpm.value}|${Pulso.situacao.value}"
            if (chave != ultimaNotificacao) {
                ultimaNotificacao = chave
                getSystemService(NotificationManager::class.java).notify(NOTIFICACAO, notificacao())
            }
            delay(1000)
        }
    }

    // --- notificação / mostrador ---

    private fun notificacao(): Notification {
        val ate = Pulso.descansoAteMs?.takeIf { it > System.currentTimeMillis() }
        val bpm = Pulso.bpm.value
        val texto = buildString {
            append(if (ate != null) "Descanso" else Pulso.etapa)
            when {
                Pulso.situacao.value == "fora do pulso" -> append(" · ♥ fora do pulso")
                bpm != null -> append(" · ♥$bpm")
            }
        }
        val toque = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).putExtra("tela", "treino"),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val b = NotificationCompat.Builder(this, Avisos.CANAL_TREINO)
            .setSmallIcon(R.drawable.ic_agent_mono)
            .setContentTitle("Treino")
            .setContentText(texto)
            .setCategory(NotificationCompat.CATEGORY_WORKOUT)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setContentIntent(toque)
        if (ate != null) b.setUsesChronometer(true).setChronometerCountDown(true).setWhen(ate)
        val status = Status.Builder().addTemplate("#t#").addPart("t", Status.TextPart(texto))
        OngoingActivity.Builder(applicationContext, NOTIFICACAO, b)
            .setStaticIcon(R.drawable.ic_agent_mono)
            .setTouchIntent(toque)
            .setStatus(status.build())
            .build()
            .apply(applicationContext)
        return b.build()
    }

    override fun onDestroy() {
        val cliente = HealthServices.getClient(this)
        if (exercicioProprio) {
            cliente.exerciseClient.endExerciseAsync()
        }
        medida?.let { cliente.measureClient.unregisterMeasureCallbackAsync(DataType.HEART_RATE_BPM, it) }
        // últimos batimentos ainda não enviados
        val a = api
        val sessao = id
        val pendentes = synchronized(lote) { lote.toList() }
        if (a != null && sessao != null && pendentes.isNotEmpty()) {
            CoroutineScope(Dispatchers.IO).launch { runCatching { a.enviarFc(sessao, pendentes) } }
        }
        escopo.cancel()
        Pulso.servicoAtivo.value = false
        Pulso.bpm.value = null
        Pulso.situacao.value = null
        super.onDestroy()
    }

    companion object {
        const val NOTIFICACAO = 7001
    }
}
