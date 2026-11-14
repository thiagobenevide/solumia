package com.thiagobenevide.agent.relogio

import org.json.JSONObject
import java.time.Instant
import kotlin.math.ceil

/** Exercício da sessão, só com o que o relógio mostra. */
data class Exercicio(
    val nome: String,
    val planejadas: Int,
    val feitas: Int,
    val repeticoes: String,
    val tempoMeta: Int?,
    val repsIniciais: Int,
    val carga: Double?,
)

/**
 * Sessão de `/api/saude/sessoes` (o estado mora no servidor). Os instantes são em ms UTC; [offsetMs]
 * corrige a diferença entre o relógio do servidor e o do pulso.
 */
data class Sessao(
    val id: String,
    val estado: String,
    val faseServidor: String,
    val pausado: Boolean,
    val indice: Int,
    val descansoS: Int,
    val descansoAteMs: Long?,
    val descansoRestanteS: Int?,
    val inicioMs: Long,
    val inicioSerieMs: Long?,
    val pausadoEmMs: Long?,
    val pausaTotalS: Int,
    val offsetMs: Long,
    val exercicios: List<Exercicio>,
) {
    val atual: Exercicio? get() = exercicios.getOrNull(indice)
    val seriesFeitas: Int get() = exercicios.sumOf { it.feitas }
    val seriesPlanejadas: Int get() = exercicios.sumOf { it.planejadas }

    private fun servidor(localMs: Long) = localMs + offsetMs

    /** Segundos de descanso que faltam (parado quando pausado); null fora do descanso. */
    fun restante(localMs: Long): Int? {
        if (faseServidor != "descanso") return null
        if (pausado) return descansoRestanteS ?: 0
        val ate = descansoAteMs ?: return 0
        return ceil((ate - servidor(localMs)) / 1000.0).toInt().coerceAtLeast(0)
    }

    /** Descanso vencido já conta como a próxima série. */
    fun fase(localMs: Long): String =
        if (faseServidor == "descanso" && !pausado && restante(localMs) == 0) "exercicio" else faseServidor

    fun ativoS(localMs: Long): Int {
        val agora = servidor(localMs)
        var pausa = pausaTotalS * 1000L
        if (pausado && pausadoEmMs != null) pausa += agora - pausadoEmMs
        return ((agora - inicioMs - pausa) / 1000).toInt().coerceAtLeast(0)
    }

    fun tempoSerie(localMs: Long): Int {
        val ini = inicioSerieMs ?: return 0
        val ate = if (pausado) pausadoEmMs ?: servidor(localMs) else servidor(localMs)
        return ((ate - ini) / 1000).toInt().coerceAtLeast(0)
    }

    companion object {
        private fun instante(o: JSONObject, chave: String): Long? =
            if (o.isNull(chave)) null else Instant.parse(o.getString(chave)).toEpochMilli()

        private fun inteiro(o: JSONObject, chave: String): Int? = if (o.isNull(chave)) null else o.getInt(chave)

        /** [recebidaEmMs]: hora local em que a resposta chegou. */
        fun deJson(j: JSONObject, recebidaEmMs: Long = System.currentTimeMillis()): Sessao {
            val c = j.getJSONObject("controle")
            val lista = j.getJSONArray("exercicios")
            val exercicios = (0 until lista.length()).map { k ->
                val e = lista.getJSONObject(k)
                val plano = e.getJSONObject("planejado")
                val meta = e.getJSONObject("meta")
                val series = e.getJSONArray("series")
                val sug = e.optJSONObject("sugestao")
                val ultima = if (series.length() > 0) series.getJSONObject(series.length() - 1) else null
                val reps = ultima?.let { inteiro(it, "repeticoes") }
                    ?: sug?.let { inteiro(it, "repeticoes") } ?: inteiro(meta, "max") ?: 10
                val carga = when {
                    ultima != null -> if (ultima.isNull("carga_kg")) null else ultima.getDouble("carga_kg")
                    sug != null && sug.has("carga_kg") -> if (sug.isNull("carga_kg")) null else sug.getDouble("carga_kg")
                    plano.isNull("carga_kg") -> null
                    else -> plano.getDouble("carga_kg")
                }
                Exercicio(
                    nome = e.getString("nome"),
                    planejadas = plano.getInt("series"),
                    feitas = series.length(),
                    repeticoes = plano.getString("repeticoes"),
                    tempoMeta = inteiro(meta, "tempo_s"),
                    repsIniciais = reps,
                    carga = carga,
                )
            }
            val agora = instante(j, "agora") ?: recebidaEmMs
            return Sessao(
                id = j.getString("id"),
                estado = j.getString("estado"),
                faseServidor = c.getString("fase"),
                pausado = c.getBoolean("pausado"),
                indice = c.getInt("indice"),
                descansoS = j.getInt("descanso_s"),
                descansoAteMs = instante(c, "descanso_ate"),
                descansoRestanteS = inteiro(c, "descanso_restante_s"),
                inicioMs = instante(j, "inicio")!!,
                inicioSerieMs = instante(c, "inicio_serie"),
                pausadoEmMs = instante(c, "pausado_em"),
                pausaTotalS = c.optInt("pausa_total_s", 0),
                offsetMs = agora - recebidaEmMs,
                exercicios = exercicios,
            )
        }
    }
}

/** "1:05" ou "1:02:03". */
fun relogio(segundos: Int): String {
    val h = segundos / 3600
    val m = segundos % 3600 / 60
    val s = segundos % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}

/** "40 kg", "22,5 kg" ou "corpo". */
fun carga(kg: Double?): String = when {
    kg == null -> "corpo"
    kg % 1.0 == 0.0 -> "${kg.toInt()} kg"
    else -> "$kg kg".replace('.', ',')
}
