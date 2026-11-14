package com.thiagobenevide.agent.watch

import org.json.JSONObject
import java.time.Instant
import kotlin.math.ceil

/** Session exercise, only with what the watch shows. */
data class Exercise(
    val name: String,
    val planned: Int,
    val doneSteps: Int,
    val repetitions: String,
    val goalTime: Int?,
    val repsIniciais: Int,
    val load: Double?,
)

/**
 * Session from `/api/saude/sessoes` (the state lives on the server). Instants are in UTC ms; [offsetMs]
 * corrects the difference between the server clock and the wrist clock.
 */
data class Session(
    val id: String,
    val state: String,
    val serverPhase: String,
    val paused: Boolean,
    val index: Int,
    val restS: Int,
    val restUntilMs: Long?,
    val restRemainingS: Int?,
    val startMs: Long,
    val startSeriesMs: Long?,
    val pausedAtMs: Long?,
    val pauseTotalS: Int,
    val offsetMs: Long,
    val exercises: List<Exercise>,
) {
    val current: Exercise? get() = exercises.getOrNull(index)
    val seriesDone: Int get() = exercises.sumOf { it.doneSteps }
    val plannedSeries: Int get() = exercises.sumOf { it.planned }

    private fun server(localMs: Long) = localMs + offsetMs

    /** Rest seconds left (frozen when paused); null outside the rest. */
    fun remaining(localMs: Long): Int? {
        if (serverPhase != "descanso") return null
        if (paused) return restRemainingS ?: 0
        val until = restUntilMs ?: return 0
        return ceil((until - server(localMs)) / 1000.0).toInt().coerceAtLeast(0)
    }

    /** An expired rest already counts as the next set. */
    fun phase(localMs: Long): String =
        if (serverPhase == "descanso" && !paused && remaining(localMs) == 0) "exercicio" else serverPhase

    fun activeS(localMs: Long): Int {
        val now = server(localMs)
        var pause = pauseTotalS * 1000L
        if (paused && pausedAtMs != null) pause += now - pausedAtMs
        return ((now - startMs - pause) / 1000).toInt().coerceAtLeast(0)
    }

    fun seriesTime(localMs: Long): Int {
        val startAt = startSeriesMs ?: return 0
        val until = if (paused) pausedAtMs ?: server(localMs) else server(localMs)
        return ((until - startAt) / 1000).toInt().coerceAtLeast(0)
    }

    companion object {
        private fun instant(o: JSONObject, key: String): Long? =
            if (o.isNull(key)) null else Instant.parse(o.getString(key)).toEpochMilli()

        private fun whole(o: JSONObject, key: String): Int? = if (o.isNull(key)) null else o.getInt(key)

        /** [receivedAtMs]: local time when the answer arrived. */
        fun deJson(j: JSONObject, receivedAtMs: Long = System.currentTimeMillis()): Session {
            val c = j.getJSONObject("controle")
            val list = j.getJSONArray("exercicios")
            val exercises = (0 until list.length()).map { k ->
                val e = list.getJSONObject(k)
                val plan = e.getJSONObject("planejado")
                val meta = e.getJSONObject("meta")
                val series = e.getJSONArray("series")
                val sug = e.optJSONObject("sugestao")
                val last = if (series.length() > 0) series.getJSONObject(series.length() - 1) else null
                val reps = last?.let { whole(it, "repeticoes") }
                    ?: sug?.let { whole(it, "repeticoes") } ?: whole(meta, "max") ?: 10
                val load = when {
                    last != null -> if (last.isNull("carga_kg")) null else last.getDouble("carga_kg")
                    sug != null && sug.has("carga_kg") -> if (sug.isNull("carga_kg")) null else sug.getDouble("carga_kg")
                    plan.isNull("carga_kg") -> null
                    else -> plan.getDouble("carga_kg")
                }
                Exercise(
                    name = e.getString("nome"),
                    planned = plan.getInt("series"),
                    doneSteps = series.length(),
                    repetitions = plan.getString("repeticoes"),
                    goalTime = whole(meta, "tempo_s"),
                    repsIniciais = reps,
                    load = load,
                )
            }
            val now = instant(j, "agora") ?: receivedAtMs
            return Session(
                id = j.getString("id"),
                state = j.getString("estado"),
                serverPhase = c.getString("fase"),
                paused = c.getBoolean("pausado"),
                index = c.getInt("indice"),
                restS = j.getInt("descanso_s"),
                restUntilMs = instant(c, "descanso_ate"),
                restRemainingS = whole(c, "descanso_restante_s"),
                startMs = instant(j, "inicio")!!,
                startSeriesMs = instant(c, "inicio_serie"),
                pausedAtMs = instant(c, "pausado_em"),
                pauseTotalS = c.optInt("pausa_total_s", 0),
                offsetMs = now - receivedAtMs,
                exercises = exercises,
            )
        }
    }
}

/** "1:05" or "1:02:03". */
fun watch(seconds: Int): String {
    val h = seconds / 3600
    val m = seconds % 3600 / 60
    val s = seconds % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}

/** "40 kg", "22,5 kg" or "corpo". */
fun load(kg: Double?): String = when {
    kg == null -> "corpo"
    kg % 1.0 == 0.0 -> "${kg.toInt()} kg"
    else -> "$kg kg".replace('.', ',')
}
