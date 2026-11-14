package com.thiagobenevide.agent.relogio

/**
 * Estatísticas dos batimentos de um treino (ou de uma medição avulsa): média, mínimo, máximo, tempo
 * em cada zona (% da [fcMaxima]) e a série dos últimos [JANELA_MS] para o gráfico.
 */
class Estatisticas(val fcMaxima: Int = 190) {
    private var soma = 0L
    var leituras = 0
        private set
    var minimo: Int? = null
        private set
    var maximo: Int? = null
        private set
    val zonasMs = LongArray(5)
    val recentes = ArrayDeque<Pair<Long, Int>>()
    private var anterior: Pair<Long, Int>? = null

    val media: Int? get() = if (leituras == 0) null else (soma / leituras).toInt()

    /** Zona 0..4 (leve, aquecimento, aeróbico, anaeróbico, máximo): faixas de 10% a partir de 60%. */
    fun zona(bpm: Int): Int = ((bpm * 100 / fcMaxima - 50) / 10).coerceIn(0, 4)

    /** Percentual da frequência máxima, de 0 a 1. */
    fun intensidade(bpm: Int): Float = (bpm / fcMaxima.toFloat()).coerceIn(0f, 1f)

    fun registrar(ms: Long, bpm: Int) {
        if (bpm < 25) return
        soma += bpm
        leituras++
        minimo = minOf(minimo ?: bpm, bpm)
        maximo = maxOf(maximo ?: bpm, bpm)
        // o tempo entre duas leituras conta na zona da anterior (lacunas longas = sensor fora, não contam)
        anterior?.let { (t, b) -> if (ms > t) zonasMs[zona(b)] += minOf(ms - t, LACUNA_MS) }
        anterior = ms to bpm
        recentes.addLast(ms to bpm)
        while (recentes.isNotEmpty() && recentes.first().first < ms - JANELA_MS) recentes.removeFirst()
    }

    fun limpar() {
        soma = 0
        leituras = 0
        minimo = null
        maximo = null
        zonasMs.fill(0)
        recentes.clear()
        anterior = null
    }

    companion object {
        const val JANELA_MS = 5 * 60_000L
        const val LACUNA_MS = 10_000L
    }
}
