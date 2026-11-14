package com.thiagobenevide.agent.consumo

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * Fila local de eventos (busca por categoria, bloqueio aplicado, violação) à espera da sincronização.
 * Buscas entram só com a categoria casada, nunca com o texto. O plugin lê e limpa ao sincronizar.
 */
object Eventos {
    private const val PREFS = "consumo_eventos"
    private const val CHAVE = "fila"
    private const val LIMITE = 2000

    private fun prefs(ctx: Context) =
        ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    @Synchronized
    fun registrar(ctx: Context, tipo: String, categoria: String, pacote: String) {
        val fila = ler(ctx)
        // evita repetir a mesma categoria/tipo a cada segundo
        val agora = System.currentTimeMillis()
        if (fila.length() > 0) {
            val ultimo = fila.getJSONObject(fila.length() - 1)
            if (ultimo.optString("tipo") == tipo && ultimo.optString("categoria") == categoria &&
                agora - ultimo.optLong("_ms") < 30_000
            ) return
        }
        fila.put(
            JSONObject()
                .put("id", UUID.randomUUID().toString().take(40))
                .put("quando", iso(agora))
                .put("_ms", agora)
                .put("tipo", tipo)
                .put("categoria", categoria)
                .put("pacote", pacote)
        )
        while (fila.length() > LIMITE) fila.remove(0)
        prefs(ctx).edit().putString(CHAVE, fila.toString()).apply()
    }

    @Synchronized
    fun drenar(ctx: Context): JSONArray {
        val fila = ler(ctx)
        prefs(ctx).edit().remove(CHAVE).apply()
        // tira o campo interno _ms antes de enviar
        for (i in 0 until fila.length()) fila.getJSONObject(i).remove("_ms")
        return fila
    }

    private fun ler(ctx: Context): JSONArray =
        prefs(ctx).getString(CHAVE, null)?.let { JSONArray(it) } ?: JSONArray()

    private fun iso(ms: Long): String {
        val f = java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", java.util.Locale.US)
        return f.format(java.util.Date(ms))
    }
}
