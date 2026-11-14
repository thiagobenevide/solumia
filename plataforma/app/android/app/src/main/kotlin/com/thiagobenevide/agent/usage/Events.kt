package com.thiagobenevide.agent.usage

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * Local queue of events (search by category, block applied, violation) waiting for the sync.
 * Searches only go in with the matched category, never with the text. The plugin reads and clears it on sync.
 */
object Events {
    private const val PREFS = "consumo_eventos"
    private const val KEY = "fila"
    private const val LIMIT = 2000

    private fun prefs(ctx: Context) =
        ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    @Synchronized
    fun register(ctx: Context, kind: String, category: String, packageName: String) {
        val queue = read(ctx)
        // evita repetir a mesma categoria/tipo a cada segundo
        val now = System.currentTimeMillis()
        if (queue.length() > 0) {
            val last = queue.getJSONObject(queue.length() - 1)
            if (last.optString("tipo") == kind && last.optString("categoria") == category &&
                now - last.optLong("_ms") < 30_000
            ) return
        }
        queue.put(
            JSONObject()
                .put("id", UUID.randomUUID().toString().take(40))
                .put("quando", iso(now))
                .put("_ms", now)
                .put("tipo", kind)
                .put("categoria", category)
                .put("pacote", packageName)
        )
        while (queue.length() > LIMIT) queue.remove(0)
        prefs(ctx).edit().putString(KEY, queue.toString()).apply()
    }

    @Synchronized
    fun drain(ctx: Context): JSONArray {
        val queue = read(ctx)
        prefs(ctx).edit().remove(KEY).apply()
        // drops the internal _ms field before sending
        for (i in 0 until queue.length()) queue.getJSONObject(i).remove("_ms")
        return queue
    }

    private fun read(ctx: Context): JSONArray =
        prefs(ctx).getString(KEY, null)?.let { JSONArray(it) } ?: JSONArray()

    private fun iso(ms: Long): String {
        val f = java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", java.util.Locale.US)
        return f.format(java.util.Date(ms))
    }
}
