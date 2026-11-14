package com.thiagobenevide.agent.watch

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread

/** Records the microphone as 16 kHz mono WAV (the format the worker's whisper prefers), up to 60 s. */
class Recorder {
    private var gravando = false
    private var line: Thread? = null
    private val pcm = ByteArrayOutputStream()

    /** Voice volume right now, from 0 to 1 (animates the waves around the microphone). */
    @Volatile var level = 0f
        private set

    @SuppressLint("MissingPermission") // the screen asks for RECORD_AUDIO first
    fun begin() {
        if (gravando) return
        pcm.reset()
        val minimum = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val rec = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION, RATE, AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT, minimum * 2,
        )
        gravando = true
        rec.startRecording()
        line = thread {
            val buf = ByteArray(minimum)
            while (gravando && pcm.size() < RATE * 2 * 60) {
                val n = rec.read(buf, 0, buf.size)
                if (n > 0) {
                    pcm.write(buf, 0, n)
                    level = rms(buf, n)
                }
            }
            rec.stop()
            rec.release()
        }
    }

    /** Stops and returns the WAV (null if it was too short to be speech). */
    fun stop(): ByteArray? {
        gravando = false
        level = 0f
        line?.join(2000)
        line = null
        val data = pcm.toByteArray()
        return if (data.size < RATE / 2) null else wav(data)
    }

    companion object {
        const val RATE = 16000

        /** Root mean square of the 16-bit PCM, normalized (normal speech sits around 0.3–0.6). */
        fun rms(buf: ByteArray, n: Int): Float {
            var sum = 0.0
            var k = 0
            var i = 0
            while (i + 1 < n) {
                val v = (buf[i].toInt() and 0xFF) or (buf[i + 1].toInt() shl 8)
                sum += v.toDouble() * v
                k++
                i += 2
            }
            if (k == 0) return 0f
            return (kotlin.math.sqrt(sum / k) / 6000.0).toFloat().coerceIn(0f, 1f)
        }

        fun wav(pcm: ByteArray): ByteArray {
            val h = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
            h.put("RIFF".toByteArray()).putInt(36 + pcm.size).put("WAVE".toByteArray())
            h.put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(1).putInt(RATE).putInt(RATE * 2)
                .putShort(2).putShort(16)
            h.put("data".toByteArray()).putInt(pcm.size)
            return h.array() + pcm
        }
    }
}
