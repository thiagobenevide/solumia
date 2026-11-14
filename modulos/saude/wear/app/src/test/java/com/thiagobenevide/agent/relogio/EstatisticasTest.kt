package com.thiagobenevide.agent.relogio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class EstatisticasTest {
    @Test
    fun zonasPorPercentualDaMaxima() {
        val e = Estatisticas(200)
        assertEquals(0, e.zona(80)) // 40%: abaixo da zona 1 conta como leve
        assertEquals(0, e.zona(110)) // 55%
        assertEquals(1, e.zona(125)) // 62%
        assertEquals(2, e.zona(145)) // 72%
        assertEquals(3, e.zona(165)) // 82%
        assertEquals(4, e.zona(195)) // 97%
    }

    @Test
    fun mediaExtremosETempoNaZonaDaLeituraAnterior() {
        val e = Estatisticas(200)
        assertNull(e.media)
        e.registrar(0, 100)
        e.registrar(5_000, 180)
        e.registrar(65_000, 120) // lacuna de 60 s: só 10 s contam
        assertEquals(133, e.media)
        assertEquals(100, e.minimo)
        assertEquals(180, e.maximo)
        assertEquals(5_000L, e.zonasMs[0])
        assertEquals(10_000L, e.zonasMs[4])
    }

    @Test
    fun serieRecenteGuardaSoAJanela() {
        val e = Estatisticas()
        e.registrar(0, 90)
        e.registrar(Estatisticas.JANELA_MS + 1, 95)
        assertEquals(listOf(Estatisticas.JANELA_MS + 1 to 95), e.recentes.toList())
    }
}

class ConversasTest {
    @Test
    fun idaEVoltaPeloJsonETituloDaPrimeiraFala() {
        val c = Conversa("c1", 10, listOf(Fala("assistente", "Oi"), Fala("usuario", "Qual meu próximo bloco?")))
        val volta = Conversas.deJson(Conversas.paraJson(listOf(c, Conversas.nova(20))))
        assertEquals(c, volta[0])
        assertEquals("Qual meu próximo bloco?", volta[0].titulo)
        assertEquals("Nova conversa", volta[1].titulo)
    }
}
