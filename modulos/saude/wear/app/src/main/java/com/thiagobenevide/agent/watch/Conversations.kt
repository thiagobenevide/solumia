package com.thiagobenevide.agent.watch

import org.json.JSONArray
import org.json.JSONObject
import java.io.File

data class Speech(val role: String, val text: String)

/** A conversation tab with the coach; the title comes from the user's first speech. */
data class Conversation(val id: String, val createdMs: Long, val speeches: List<Speech> = emptyList()) {
    val title: String
        get() = speeches.firstOrNull { it.role == "usuario" }?.text?.trim()?.take(40)?.ifBlank { null } ?: "Nova conversa"
}

/**
 * Coach conversation tabs, kept on the watch (`conversas.json`): most recent first,
 * at most [MAXIMUM] (the oldest ones drop off on their own).
 */
class Conversas(private val file: File) {
    fun read(): List<Conversation> = runCatching { deJson(file.readText()) }.getOrDefault(emptyList())

    fun record(list: List<Conversation>) {
        runCatching { file.writeText(toJson(list.take(MAXIMUM))) }
    }

    companion object {
        const val MAXIMUM = 30

        fun fresh(nowMs: Long = System.currentTimeMillis()) = Conversation("c$nowMs", nowMs)

        fun toJson(list: List<Conversation>): String = JSONArray().apply {
            list.forEach { c ->
                put(
                    JSONObject().put("id", c.id).put("criada", c.createdMs).put(
                        "falas",
                        JSONArray().apply { c.speeches.forEach { put(JSONObject().put("papel", it.role).put("texto", it.text)) } },
                    ),
                )
            }
        }.toString()

        fun deJson(text: String): List<Conversation> {
            val l = JSONArray(text)
            return (0 until l.length()).map { i ->
                val o = l.getJSONObject(i)
                val f = o.getJSONArray("falas")
                Conversation(
                    o.getString("id"), o.getLong("criada"),
                    (0 until f.length()).map { f.getJSONObject(it).let { x -> Speech(x.getString("papel"), x.getString("texto")) } },
                )
            }
        }
    }
}
