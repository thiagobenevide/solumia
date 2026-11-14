package com.thiagobenevide.agent.relogio

import org.json.JSONArray
import org.json.JSONObject
import java.io.File

data class Fala(val papel: String, val texto: String)

/** Uma aba de conversa com o cobrador; o título sai da primeira fala do usuário. */
data class Conversa(val id: String, val criadaMs: Long, val falas: List<Fala> = emptyList()) {
    val titulo: String
        get() = falas.firstOrNull { it.papel == "usuario" }?.texto?.trim()?.take(40)?.ifBlank { null } ?: "Nova conversa"
}

/**
 * Abas de conversa do cobrador, guardadas no relógio (`conversas.json`): a mais recente primeiro,
 * no máximo [MAXIMO] (as mais antigas saem sozinhas).
 */
class Conversas(private val arquivo: File) {
    fun ler(): List<Conversa> = runCatching { deJson(arquivo.readText()) }.getOrDefault(emptyList())

    fun gravar(lista: List<Conversa>) {
        runCatching { arquivo.writeText(paraJson(lista.take(MAXIMO))) }
    }

    companion object {
        const val MAXIMO = 30

        fun nova(agoraMs: Long = System.currentTimeMillis()) = Conversa("c$agoraMs", agoraMs)

        fun paraJson(lista: List<Conversa>): String = JSONArray().apply {
            lista.forEach { c ->
                put(
                    JSONObject().put("id", c.id).put("criada", c.criadaMs).put(
                        "falas",
                        JSONArray().apply { c.falas.forEach { put(JSONObject().put("papel", it.papel).put("texto", it.texto)) } },
                    ),
                )
            }
        }.toString()

        fun deJson(texto: String): List<Conversa> {
            val l = JSONArray(texto)
            return (0 until l.length()).map { i ->
                val o = l.getJSONObject(i)
                val f = o.getJSONArray("falas")
                Conversa(
                    o.getString("id"), o.getLong("criada"),
                    (0 until f.length()).map { f.getJSONObject(it).let { x -> Fala(x.getString("papel"), x.getString("texto")) } },
                )
            }
        }
    }
}
