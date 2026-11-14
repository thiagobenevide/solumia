package com.thiagobenevide.agent.usage

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar

/**
 * Saúde › Consumo module rules stored locally (coming from the backend through the sync). The
 * services (accessibility Watcher and DNS Filter) read from here to decide what to block. Searches
 * are never stored as text: only the matched category becomes an event.
 */
object Rules {
    private const val PREFS = "consumo_regras"
    private const val KEY = "json"

    private fun prefs(ctx: Context): SharedPreferences =
        ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun save(ctx: Context, rules: JSONObject) {
        prefs(ctx).edit().putString(KEY, rules.toString()).apply()
    }

    fun current(ctx: Context): JSONObject =
        prefs(ctx).getString(KEY, null)?.let { JSONObject(it) } ?: JSONObject()

    /** Category of an app package, or null if it is not watched. WhatsApp never shows up here. */
    fun appCategory(rules: JSONObject, packageName: String): String? {
        val apps = rules.optJSONObject("apps") ?: return null
        return if (apps.has(packageName)) apps.getString(packageName) else null
    }

    fun isento(rules: JSONObject, packageName: String): Boolean =
        rules.optJSONArray("apps_isentos").contem(packageName)

    /** Blocked domains of a category (default list + the user's, already merged on the backend). */
    fun domains(rules: JSONObject, category: String): List<String> {
        val m = rules.optJSONObject("dominios")?.optJSONArray(category) ?: return emptyList()
        return (0 until m.length()).map { m.getString(it).lowercase() }
    }

    fun exemptDomains(rules: JSONObject): List<String> {
        val a = rules.optJSONArray("dominios_isentos") ?: return emptyList()
        return (0 until a.length()).map { a.getString(it).lowercase() }
    }

    /** Words per category to classify a search (comparison only, the text is never stored). */
    fun words(rules: JSONObject): Map<String, List<String>> {
        val p = rules.optJSONObject("palavras") ?: return emptyMap()
        return p.keys().asSequence().associateWith { c ->
            p.getJSONArray(c).let { (0 until it.length()).map { i -> it.getString(i).lowercase() } }
        }
    }

    fun dns(rules: JSONObject): String = rules.optString("dns", "1.1.1.3").ifBlank { "1.1.1.3" }

    fun protection(rules: JSONObject): Boolean = rules.optBoolean("protecao", true)

    data class Decision(val block: Boolean, val reason: String)

    /**
     * Can app [packageName] (category [category]) stay open now? Considers blocked mode,
     * forbidden hours and the limit of minutes already spent today ([usedMin]).
     */
    fun decideApp(rules: JSONObject, category: String, usedMin: Int, now: Calendar): Decision {
        val r = rules.optJSONObject("regras")?.optJSONObject(category) ?: return Decision(false, "")
        when (r.optString("modo", "livre")) {
            "bloqueado" -> return Decision(true, "Categoria bloqueada")
            "limite" -> {
                val limit = r.optInt("limite_min", 0)
                if (limit in 1..usedMin) return Decision(true, "Limite de $limit min atingido")
            }
        }
        val horarios = r.optJSONArray("horarios") ?: JSONArray()
        val currentMinute = now.get(Calendar.HOUR_OF_DAY) * 60 + now.get(Calendar.MINUTE)
        for (i in 0 until horarios.length()) {
            val h = horarios.getJSONObject(i)
            if (inside(currentMinute, minutes(h.getString("inicio")), minutes(h.getString("fim")))) {
                return Decision(true, "Fora do horário (${h.getString("inicio")}–${h.getString("fim")})")
            }
        }
        return Decision(false, "")
    }

    private fun minutes(hhmm: String): Int {
        val (h, m) = hhmm.split(":").map { it.toInt() }
        return h * 60 + m
    }

    /** Interval that can cross midnight (e.g. 22:00–07:00). */
    private fun inside(now: Int, start: Int, end: Int): Boolean =
        if (start <= end) now in start until end else now >= start || now < end

    private fun JSONArray?.contem(valor: String): Boolean {
        if (this == null) return false
        for (i in 0 until length()) if (getString(i) == valor) return true
        return false
    }
}
