package com.thiagobenevide.agent.watch

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.Instant

class SessionTest {
    private fun json(paused: Boolean = false) = JSONObject(
        """
        {"id": "a", "data": "2026-11-10", "inicio": "2026-11-10T18:00:00Z", "fim": null,
         "estado": "andamento", "descanso_s": 60, "agora": "2026-11-10T18:10:00Z",
         "controle": {"fase": "descanso", "indice": 0, "inicio_serie": "2026-11-10T18:09:00Z",
           "descanso_ate": "2026-11-10T18:10:45Z", "descanso_restante_s": 20, "pausado": $paused,
           "pausado_em": ${if (paused) "\"2026-11-10T18:08:00Z\"" else "null"}, "pausa_total_s": 120},
         "exercicios": [{"nome": "Supino", "exercicio_id": "supino-barra", "instrucoes": "Desça a barra",
           "observacao": "2 s na descida", "planejado": {"series": 3, "repeticoes": "8-12", "carga_kg": 40},
           "meta": {"tempo_s": null, "min": 8, "max": 12}, "pulado": false,
           "sugestao": {"carga_kg": 42.5, "repeticoes": 8, "motivo": "x"},
           "series": [{"repeticoes": 11, "carga_kg": 40.0}]}]}
        """,
    )

    // wrist clock 1 h ahead: the math uses the server's
    private val local = Instant.parse("2026-11-10T19:10:00Z").toEpochMilli()

    @Test
    fun restUsesServerClock() {
        val s = Session.deJson(json(), local)
        assertEquals(45, s.remaining(local))
        assertEquals("exercicio", s.phase(local + 46_000))
        assertEquals(8 * 60, s.activeS(local))
        assertEquals(11, s.current!!.repsIniciais)
        assertEquals(40.0, s.current!!.load!!, 0.0)
        assertEquals("supino-barra", s.current!!.exerciseId)
        assertEquals("2 s na descida", s.current!!.cue)
    }

    @Test
    fun pausedFreezesRest() {
        val s = Session.deJson(json(paused = true), local)
        assertEquals(20, s.remaining(local + 300_000))
        assertEquals("descanso", s.phase(local))
    }

    @Test
    fun formats() {
        assertEquals("1:05", watch(65))
        assertEquals("1:02:03", watch(3723))
        assertEquals("22,5 kg", load(22.5))
        assertEquals("corpo", load(null))
        assertNull(Session.deJson(json(), local).remaining(local).takeIf { false })
    }

    @Test
    fun wavHeader() {
        val w = Recorder.wav(ByteArray(100))
        assertEquals(144, w.size)
        assertEquals("RIFF", String(w, 0, 4))
        assertEquals("WAVE", String(w, 8, 4))
        assertEquals(100, (w[40].toInt() and 0xff) or ((w[41].toInt() and 0xff) shl 8))
    }
}
