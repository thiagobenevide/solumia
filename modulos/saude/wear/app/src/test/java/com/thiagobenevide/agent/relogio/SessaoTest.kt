package com.thiagobenevide.agent.relogio

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.Instant

class SessaoTest {
    private fun json(pausado: Boolean = false) = JSONObject(
        """
        {"id": "a", "data": "2026-11-10", "inicio": "2026-11-10T18:00:00Z", "fim": null,
         "estado": "andamento", "descanso_s": 60, "agora": "2026-11-10T18:10:00Z",
         "controle": {"fase": "descanso", "indice": 0, "inicio_serie": "2026-11-10T18:09:00Z",
           "descanso_ate": "2026-11-10T18:10:45Z", "descanso_restante_s": 20, "pausado": $pausado,
           "pausado_em": ${if (pausado) "\"2026-11-10T18:08:00Z\"" else "null"}, "pausa_total_s": 120},
         "exercicios": [{"nome": "Supino", "planejado": {"series": 3, "repeticoes": "8-12", "carga_kg": 40},
           "meta": {"tempo_s": null, "min": 8, "max": 12}, "pulado": false,
           "sugestao": {"carga_kg": 42.5, "repeticoes": 8, "motivo": "x"},
           "series": [{"repeticoes": 11, "carga_kg": 40.0}]}]}
        """,
    )

    // relógio do pulso 1 h adiantado: a conta usa o do servidor
    private val local = Instant.parse("2026-11-10T19:10:00Z").toEpochMilli()

    @Test
    fun descansoUsaRelogioDoServidor() {
        val s = Sessao.deJson(json(), local)
        assertEquals(45, s.restante(local))
        assertEquals("exercicio", s.fase(local + 46_000))
        assertEquals(8 * 60, s.ativoS(local))
        assertEquals(11, s.atual!!.repsIniciais)
        assertEquals(40.0, s.atual!!.carga!!, 0.0)
    }

    @Test
    fun pausadoCongelaDescanso() {
        val s = Sessao.deJson(json(pausado = true), local)
        assertEquals(20, s.restante(local + 300_000))
        assertEquals("descanso", s.fase(local))
    }

    @Test
    fun formatos() {
        assertEquals("1:05", relogio(65))
        assertEquals("1:02:03", relogio(3723))
        assertEquals("22,5 kg", carga(22.5))
        assertEquals("corpo", carga(null))
        assertNull(Sessao.deJson(json(), local).restante(local).takeIf { false })
    }

    @Test
    fun cabecalhoWav() {
        val w = Gravador.wav(ByteArray(100))
        assertEquals(144, w.size)
        assertEquals("RIFF", String(w, 0, 4))
        assertEquals("WAVE", String(w, 8, 4))
        assertEquals(100, (w[40].toInt() and 0xff) or ((w[41].toInt() and 0xff) shl 8))
    }
}
