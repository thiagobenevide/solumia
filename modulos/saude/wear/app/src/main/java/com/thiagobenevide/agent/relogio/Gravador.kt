package com.thiagobenevide.agent.relogio

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread

/** Grava o microfone em WAV 16 kHz mono (o formato que o whisper do worker prefere), até 60 s. */
class Gravador {
    private var gravando = false
    private var linha: Thread? = null
    private val pcm = ByteArrayOutputStream()

    /** Volume da voz agora, de 0 a 1 (anima as ondas em volta do microfone). */
    @Volatile var nivel = 0f
        private set

    @SuppressLint("MissingPermission") // a tela pede RECORD_AUDIO antes
    fun iniciar() {
        if (gravando) return
        pcm.reset()
        val minimo = AudioRecord.getMinBufferSize(TAXA, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val rec = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION, TAXA, AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT, minimo * 2,
        )
        gravando = true
        rec.startRecording()
        linha = thread {
            val buf = ByteArray(minimo)
            while (gravando && pcm.size() < TAXA * 2 * 60) {
                val n = rec.read(buf, 0, buf.size)
                if (n > 0) {
                    pcm.write(buf, 0, n)
                    nivel = rms(buf, n)
                }
            }
            rec.stop()
            rec.release()
        }
    }

    /** Para e devolve o WAV (null se ficou curto demais para ser fala). */
    fun parar(): ByteArray? {
        gravando = false
        nivel = 0f
        linha?.join(2000)
        linha = null
        val dados = pcm.toByteArray()
        return if (dados.size < TAXA / 2) null else wav(dados)
    }

    companion object {
        const val TAXA = 16000

        /** Raiz da média dos quadrados do PCM 16 bits, normalizada (fala comum fica perto de 0,3–0,6). */
        fun rms(buf: ByteArray, n: Int): Float {
            var soma = 0.0
            var k = 0
            var i = 0
            while (i + 1 < n) {
                val v = (buf[i].toInt() and 0xFF) or (buf[i + 1].toInt() shl 8)
                soma += v.toDouble() * v
                k++
                i += 2
            }
            if (k == 0) return 0f
            return (kotlin.math.sqrt(soma / k) / 6000.0).toFloat().coerceIn(0f, 1f)
        }

        fun wav(pcm: ByteArray): ByteArray {
            val h = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
            h.put("RIFF".toByteArray()).putInt(36 + pcm.size).put("WAVE".toByteArray())
            h.put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(1).putInt(TAXA).putInt(TAXA * 2)
                .putShort(2).putShort(16)
            h.put("data".toByteArray()).putInt(pcm.size)
            return h.array() + pcm
        }
    }
}
