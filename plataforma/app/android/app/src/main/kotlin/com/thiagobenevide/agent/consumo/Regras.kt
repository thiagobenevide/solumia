package com.thiagobenevide.agent.consumo

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar

/**
 * Regras do módulo Saúde › Consumo guardadas localmente (vindas do backend pela sincronização). Os
 * serviços (Vigia de acessibilidade e Filtro de DNS) leem daqui para decidir o que bloquear. Buscas
 * nunca são guardadas como texto: só a categoria casada vira evento.
 */
object Regras {
    private const val PREFS = "consumo_regras"
    private const val CHAVE = "json"

    private fun prefs(ctx: Context): SharedPreferences =
        ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun salvar(ctx: Context, regras: JSONObject) {
        prefs(ctx).edit().putString(CHAVE, regras.toString()).apply()
    }

    fun atual(ctx: Context): JSONObject =
        prefs(ctx).getString(CHAVE, null)?.let { JSONObject(it) } ?: JSONObject()

    /** Categoria de um pacote de app, ou null se não for vigiado. WhatsApp nunca aparece aqui. */
    fun categoriaDoApp(regras: JSONObject, pacote: String): String? {
        val apps = regras.optJSONObject("apps") ?: return null
        return if (apps.has(pacote)) apps.getString(pacote) else null
    }

    fun isento(regras: JSONObject, pacote: String): Boolean =
        regras.optJSONArray("apps_isentos").contem(pacote)

    /** Domínios bloqueados de uma categoria (lista padrão + a do usuário, já unidas no backend). */
    fun dominios(regras: JSONObject, categoria: String): List<String> {
        val m = regras.optJSONObject("dominios")?.optJSONArray(categoria) ?: return emptyList()
        return (0 until m.length()).map { m.getString(it).lowercase() }
    }

    fun dominiosIsentos(regras: JSONObject): List<String> {
        val a = regras.optJSONArray("dominios_isentos") ?: return emptyList()
        return (0 until a.length()).map { a.getString(it).lowercase() }
    }

    /** Palavras por categoria para classificar uma busca (comparação, nunca guarda o texto). */
    fun palavras(regras: JSONObject): Map<String, List<String>> {
        val p = regras.optJSONObject("palavras") ?: return emptyMap()
        return p.keys().asSequence().associateWith { c ->
            p.getJSONArray(c).let { (0 until it.length()).map { i -> it.getString(i).lowercase() } }
        }
    }

    fun dns(regras: JSONObject): String = regras.optString("dns", "1.1.1.3").ifBlank { "1.1.1.3" }

    fun protecao(regras: JSONObject): Boolean = regras.optBoolean("protecao", true)

    data class Decisao(val bloquear: Boolean, val motivo: String)

    /**
     * O app [pacote] (categoria [categoria]) pode ficar aberto agora? Considera modo bloqueado,
     * horário proibido e o limite de minutos já gastos hoje ([usadosMin]).
     */
    fun decidirApp(regras: JSONObject, categoria: String, usadosMin: Int, agora: Calendar): Decisao {
        val r = regras.optJSONObject("regras")?.optJSONObject(categoria) ?: return Decisao(false, "")
        when (r.optString("modo", "livre")) {
            "bloqueado" -> return Decisao(true, "Categoria bloqueada")
            "limite" -> {
                val limite = r.optInt("limite_min", 0)
                if (limite in 1..usadosMin) return Decisao(true, "Limite de $limite min atingido")
            }
        }
        val horarios = r.optJSONArray("horarios") ?: JSONArray()
        val minutoAtual = agora.get(Calendar.HOUR_OF_DAY) * 60 + agora.get(Calendar.MINUTE)
        for (i in 0 until horarios.length()) {
            val h = horarios.getJSONObject(i)
            if (dentro(minutoAtual, minutos(h.getString("inicio")), minutos(h.getString("fim")))) {
                return Decisao(true, "Fora do horário (${h.getString("inicio")}–${h.getString("fim")})")
            }
        }
        return Decisao(false, "")
    }

    private fun minutos(hhmm: String): Int {
        val (h, m) = hhmm.split(":").map { it.toInt() }
        return h * 60 + m
    }

    /** Intervalo que pode cruzar a meia-noite (ex.: 22:00–07:00). */
    private fun dentro(agora: Int, inicio: Int, fim: Int): Boolean =
        if (inicio <= fim) agora in inicio until fim else agora >= inicio || agora < fim

    private fun JSONArray?.contem(valor: String): Boolean {
        if (this == null) return false
        for (i in 0 until length()) if (getString(i) == valor) return true
        return false
    }
}
