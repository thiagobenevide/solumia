package com.thiagobenevide.agent.watch

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class StatisticsTest {
    @Test
    fun zonesByPercentOfMax() {
        val e = Statistics(200)
        assertEquals(0, e.zone(80)) // 40%: below zone 1 counts as light
        assertEquals(0, e.zone(110)) // 55%
        assertEquals(1, e.zone(125)) // 62%
        assertEquals(2, e.zone(145)) // 72%
        assertEquals(3, e.zone(165)) // 82%
        assertEquals(4, e.zone(195)) // 97%
    }

    @Test
    fun averageExtremesAndTimeInZoneOfPreviousReading() {
        val e = Statistics(200)
        assertNull(e.average)
        e.register(0, 100)
        e.register(5_000, 180)
        e.register(65_000, 120) // 60 s gap: only 10 s count
        assertEquals(133, e.average)
        assertEquals(100, e.minimum)
        assertEquals(180, e.maximum)
        assertEquals(5_000L, e.zonesMs[0])
        assertEquals(10_000L, e.zonesMs[4])
    }

    @Test
    fun recentSeriesKeepsOnlyTheWindow() {
        val e = Statistics()
        e.register(0, 90)
        e.register(Statistics.WINDOW_MS + 1, 95)
        assertEquals(listOf(Statistics.WINDOW_MS + 1 to 95), e.recent.toList())
    }
}

class ConversasTest {
    @Test
    fun roundTripThroughJsonAndFirstSpeechTitle() {
        val c = Conversation("c1", 10, listOf(Speech("assistente", "Oi"), Speech("usuario", "Qual meu próximo bloco?")))
        val lap = Conversas.deJson(Conversas.toJson(listOf(c, Conversas.fresh(20))))
        assertEquals(c, lap[0])
        assertEquals("Qual meu próximo bloco?", lap[0].title)
        assertEquals("Nova conversa", lap[1].title)
    }
}
