package com.thiagobenevide.agent.consumo

import android.app.Activity
import android.app.AppOpsManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Process
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale

/**
 * Liga o app Flutter ao controle do aparelho (canal `agent/saude/consumo`). `coletar` monta o uso por
 * app/hora, o estado da permissão e os eventos pendentes; `aplicar` guarda as regras do backend;
 * `permissoes`/`pedir` tratam só da leitura de uso (sem acessibilidade, VPN nem administrador).
 */
class ConsumoPlugin(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private val ctx: Context get() = activity.applicationContext

    fun handle(canal: MethodChannel) {
        canal.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, resultado: MethodChannel.Result) {
        when (call.method) {
            "coletar" -> resultado.success(coletar().toMap())
            "aplicar" -> {
                aplicar(JSONObject(call.arguments as? String ?: "{}"))
                resultado.success(null)
            }
            "permissoes" -> resultado.success(permissoes())
            "pedir" -> pedir(call.argument<String>("permissao") ?: "", resultado)
            else -> resultado.notImplemented()
        }
    }

    // --- coleta de uso ---

    private fun coletar(): JSONObject {
        val regras = Regras.atual(ctx)
        val dias = JSONArray()
        for (desloc in 0 downTo -1) { // hoje e ontem
            dias.put(usoDoDia(regras, desloc))
        }
        return JSONObject()
            .put("dispositivo", dispositivo())
            .put("dias", dias)
            .put("eventos", Eventos.drenar(ctx))
    }

    private fun usoDoDia(regras: JSONObject, deslocDias: Int): JSONObject {
        val cal = Calendar.getInstance().apply {
            add(Calendar.DAY_OF_YEAR, deslocDias)
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }
        val inicio = cal.timeInMillis
        val fim = minOf(inicio + 86_400_000L, System.currentTimeMillis())
        val data = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(cal.time)

        val usm = ctx.getSystemService(UsageStatsManager::class.java)
        val porApp = HashMap<String, LongArray>() // pacote -> [ms, aberturas]
        val porHoraCat = HashMap<String, DoubleArray>() // categoria -> 24 min
        var outrosMs = 0L

        if (usm != null) {
            val eventos = usm.queryEvents(inicio, fim)
            val emFrente = HashMap<String, Long>()
            val e = UsageEvents.Event()
            while (eventos.hasNextEvent()) {
                eventos.getNextEvent(e)
                val pacote = e.packageName ?: continue
                when (e.eventType) {
                    UsageEvents.Event.MOVE_TO_FOREGROUND, UsageEvents.Event.ACTIVITY_RESUMED -> {
                        emFrente[pacote] = e.timeStamp
                        porApp.getOrPut(pacote) { longArrayOf(0, 0) }[1]++
                    }
                    UsageEvents.Event.MOVE_TO_BACKGROUND, UsageEvents.Event.ACTIVITY_PAUSED -> {
                        val desde = emFrente.remove(pacote) ?: continue
                        contabilizar(regras, pacote, desde, e.timeStamp, porApp, porHoraCat) { outrosMs += it }
                    }
                }
            }
            // apps ainda em primeiro plano ao fim da janela
            for ((pacote, desde) in emFrente) {
                contabilizar(regras, pacote, desde, fim, porApp, porHoraCat) { outrosMs += it }
            }
        }

        val apps = JSONArray()
        val nomes = regras.optJSONObject("nomes")
        for ((pacote, v) in porApp) {
            if (Regras.isento(regras, pacote)) continue
            val categoria = Regras.categoriaDoApp(regras, pacote) ?: continue
            apps.put(
                JSONObject()
                    .put("pacote", pacote)
                    .put("nome", nomes?.optString(pacote, pacote) ?: pacote)
                    .put("categoria", categoria)
                    .put("minutos", v[0] / 60000.0)
                    .put("aberturas", v[1])
            )
        }
        val porHora = JSONObject()
        for ((cat, arr) in porHoraCat) porHora.put(cat, JSONArray(arr.toList()))
        return JSONObject()
            .put("data", data)
            .put("apps", apps)
            .put("outros_min", outrosMs / 60000.0)
            .put("por_hora", porHora)
    }

    private inline fun contabilizar(
        regras: JSONObject, pacote: String, desde: Long, ate: Long,
        porApp: HashMap<String, LongArray>, porHoraCat: HashMap<String, DoubleArray>, outros: (Long) -> Unit
    ) {
        val ms = (ate - desde).coerceAtLeast(0)
        if (ms == 0L) return
        if (Regras.isento(regras, pacote)) return
        val categoria = Regras.categoriaDoApp(regras, pacote)
        if (categoria == null) {
            outros(ms)
            return
        }
        porApp.getOrPut(pacote) { longArrayOf(0, 0) }[0] += ms
        val hora = Calendar.getInstance().apply { timeInMillis = desde }.get(Calendar.HOUR_OF_DAY)
        porHoraCat.getOrPut(categoria) { DoubleArray(24) }[hora] += ms / 60000.0
    }

    // --- estado e permissões ---

    private fun dispositivo(): JSONObject {
        @Suppress("HardwareIds")
        val id = Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ANDROID_ID) ?: "android"
        val p = permissoes()
        return JSONObject()
            .put("id", id)
            .put("nome", "${Build.MANUFACTURER} ${Build.MODEL}".trim())
            .put("estado", JSONObject(p as Map<*, *>))
    }

    private fun permissoes(): Map<String, Boolean> = mapOf(
        "uso" to temUso(),
    )

    private fun temUso(): Boolean {
        val ops = ctx.getSystemService(AppOpsManager::class.java) ?: return false
        val modo = if (Build.VERSION.SDK_INT >= 29) {
            ops.unsafeCheckOpNoThrow("android:get_usage_stats", Process.myUid(), ctx.packageName)
        } else {
            @Suppress("DEPRECATION")
            ops.checkOpNoThrow("android:get_usage_stats", Process.myUid(), ctx.packageName)
        }
        return modo == AppOpsManager.MODE_ALLOWED
    }

    // --- aplicar regras e autorizações ---

    private fun aplicar(regras: JSONObject) {
        Regras.salvar(ctx, regras)
    }

    private fun pedir(permissao: String, resultado: MethodChannel.Result) {
        if (permissao == "uso") {
            activity.startActivity(
                Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }
        resultado.success(null)
    }

    private fun JSONObject.toMap(): Map<String, Any?> =
        keys().asSequence().associateWith { chave ->
            when (val v = get(chave)) {
                is JSONObject -> v.toMap()
                is JSONArray -> v.toList()
                JSONObject.NULL -> null
                else -> v
            }
        }

    private fun JSONArray.toList(): List<Any?> = (0 until length()).map {
        when (val v = get(it)) {
            is JSONObject -> v.toMap()
            is JSONArray -> v.toList()
            JSONObject.NULL -> null
            else -> v
        }
    }
}
