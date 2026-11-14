package com.thiagobenevide.agent.usage

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
 * Connects the Flutter app to the device controls (channel `agent/saude/consumo`). `coletar` builds the usage per
 * app/hour, the permission state and the pending events; `aplicar` stores the backend rules;
 * `permissoes`/`pedir` only handle the usage reading (no accessibility, VPN or device admin).
 */
class UsagePlugin(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private val ctx: Context get() = activity.applicationContext

    fun handle(channel: MethodChannel) {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "coletar" -> result.success(collect().toMap())
            "aplicar" -> {
                apply(JSONObject(call.arguments as? String ?: "{}"))
                result.success(null)
            }
            "permissoes" -> result.success(permissions())
            "pedir" -> ask(call.argument<String>("permissao") ?: "", result)
            else -> result.notImplemented()
        }
    }

    // --- usage collection ---

    private fun collect(): JSONObject {
        val rules = Rules.current(ctx)
        val days = JSONArray()
        for (desloc in 0 downTo -1) { // hoje e ontem
            days.put(dailyUsage(rules, desloc))
        }
        return JSONObject()
            .put("dispositivo", device())
            .put("dias", days)
            .put("eventos", Events.drain(ctx))
    }

    private fun dailyUsage(rules: JSONObject, dayOffset: Int): JSONObject {
        val cal = Calendar.getInstance().apply {
            add(Calendar.DAY_OF_YEAR, dayOffset)
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }
        val start = cal.timeInMillis
        val end = minOf(start + 86_400_000L, System.currentTimeMillis())
        val data = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(cal.time)

        val usm = ctx.getSystemService(UsageStatsManager::class.java)
        val byApp = HashMap<String, LongArray>() // pacote -> [ms, aberturas]
        val byHourCat = HashMap<String, DoubleArray>() // categoria -> 24 min
        var outrosMs = 0L

        if (usm != null) {
            val events = usm.queryEvents(start, end)
            val emFrente = HashMap<String, Long>()
            val e = UsageEvents.Event()
            while (events.hasNextEvent()) {
                events.getNextEvent(e)
                val packageName = e.packageName ?: continue
                when (e.eventType) {
                    UsageEvents.Event.MOVE_TO_FOREGROUND, UsageEvents.Event.ACTIVITY_RESUMED -> {
                        emFrente[packageName] = e.timeStamp
                        byApp.getOrPut(packageName) { longArrayOf(0, 0) }[1]++
                    }
                    UsageEvents.Event.MOVE_TO_BACKGROUND, UsageEvents.Event.ACTIVITY_PAUSED -> {
                        val since = emFrente.remove(packageName) ?: continue
                        tally(rules, packageName, since, e.timeStamp, byApp, byHourCat) { outrosMs += it }
                    }
                }
            }
            // apps still in the foreground at the end of the window
            for ((packageName, since) in emFrente) {
                tally(rules, packageName, since, end, byApp, byHourCat) { outrosMs += it }
            }
        }

        val apps = JSONArray()
        val names = rules.optJSONObject("nomes")
        for ((packageName, v) in byApp) {
            if (Rules.isento(rules, packageName)) continue
            val category = Rules.appCategory(rules, packageName) ?: continue
            apps.put(
                JSONObject()
                    .put("pacote", packageName)
                    .put("nome", names?.optString(packageName, packageName) ?: packageName)
                    .put("categoria", category)
                    .put("minutos", v[0] / 60000.0)
                    .put("aberturas", v[1])
            )
        }
        val byHour = JSONObject()
        for ((cat, arr) in byHourCat) byHour.put(cat, JSONArray(arr.toList()))
        return JSONObject()
            .put("data", data)
            .put("apps", apps)
            .put("outros_min", outrosMs / 60000.0)
            .put("por_hora", byHour)
    }

    private inline fun tally(
        rules: JSONObject, packageName: String, since: Long, ate: Long,
        byApp: HashMap<String, LongArray>, byHourCat: HashMap<String, DoubleArray>, outros: (Long) -> Unit
    ) {
        val ms = (ate - since).coerceAtLeast(0)
        if (ms == 0L) return
        if (Rules.isento(rules, packageName)) return
        val category = Rules.appCategory(rules, packageName)
        if (category == null) {
            outros(ms)
            return
        }
        byApp.getOrPut(packageName) { longArrayOf(0, 0) }[0] += ms
        val hour = Calendar.getInstance().apply { timeInMillis = since }.get(Calendar.HOUR_OF_DAY)
        byHourCat.getOrPut(category) { DoubleArray(24) }[hour] += ms / 60000.0
    }

    // --- state and permissions ---

    private fun device(): JSONObject {
        @Suppress("HardwareIds")
        val id = Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ANDROID_ID) ?: "android"
        val p = permissions()
        return JSONObject()
            .put("id", id)
            .put("nome", "${Build.MANUFACTURER} ${Build.MODEL}".trim())
            .put("estado", JSONObject(p as Map<*, *>))
    }

    private fun permissions(): Map<String, Boolean> = mapOf(
        "uso" to hasUsage(),
    )

    private fun hasUsage(): Boolean {
        val ops = ctx.getSystemService(AppOpsManager::class.java) ?: return false
        val mode = if (Build.VERSION.SDK_INT >= 29) {
            ops.unsafeCheckOpNoThrow("android:get_usage_stats", Process.myUid(), ctx.packageName)
        } else {
            @Suppress("DEPRECATION")
            ops.checkOpNoThrow("android:get_usage_stats", Process.myUid(), ctx.packageName)
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    // --- applying rules and authorizations ---

    private fun apply(rules: JSONObject) {
        Rules.save(ctx, rules)
    }

    private fun ask(permission: String, result: MethodChannel.Result) {
        if (permission == "uso") {
            activity.startActivity(
                Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }
        result.success(null)
    }

    private fun JSONObject.toMap(): Map<String, Any?> =
        keys().asSequence().associateWith { key ->
            when (val v = get(key)) {
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
