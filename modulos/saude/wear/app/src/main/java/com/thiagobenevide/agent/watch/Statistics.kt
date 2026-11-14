package com.thiagobenevide.agent.watch

/**
 * Heartbeat statistics of a workout (or of a spot measurement): average, minimum, maximum, time
 * in each zone (% of [maxHr]) and the series of the last [WINDOW_MS] for the chart.
 */
class Statistics(val maxHr: Int = 190) {
    private var sum = 0L
    var readings = 0
        private set
    var minimum: Int? = null
        private set
    var maximum: Int? = null
        private set
    val zonesMs = LongArray(5)
    val recent = ArrayDeque<Pair<Long, Int>>()
    private var previous: Pair<Long, Int>? = null

    val average: Int? get() = if (readings == 0) null else (sum / readings).toInt()

    /** Zone 0..4 (light, warm-up, aerobic, anaerobic, maximum): 10% bands starting at 60%. */
    fun zone(bpm: Int): Int = ((bpm * 100 / maxHr - 50) / 10).coerceIn(0, 4)

    /** Percent of the maximum heart rate, from 0 to 1. */
    fun intensidade(bpm: Int): Float = (bpm / maxHr.toFloat()).coerceIn(0f, 1f)

    fun register(ms: Long, bpm: Int) {
        if (bpm < 25) return
        sum += bpm
        readings++
        minimum = minOf(minimum ?: bpm, bpm)
        maximum = maxOf(maximum ?: bpm, bpm)
        // the time between two readings counts in the previous one's zone (long gaps = sensor off, they do not count)
        previous?.let { (t, b) -> if (ms > t) zonesMs[zone(b)] += minOf(ms - t, GAP_MS) }
        previous = ms to bpm
        recent.addLast(ms to bpm)
        while (recent.isNotEmpty() && recent.first().first < ms - WINDOW_MS) recent.removeFirst()
    }

    fun clean() {
        sum = 0
        readings = 0
        minimum = null
        maximum = null
        zonesMs.fill(0)
        recent.clear()
        previous = null
    }

    companion object {
        const val WINDOW_MS = 5 * 60_000L
        const val GAP_MS = 10_000L
    }
}
