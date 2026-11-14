package com.thiagobenevide.agent.relogio

import android.content.Context
import android.media.AudioManager
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf

/**
 * Volume de mídia do relógio (é por ele que a voz do cobrador toca). Ajusta sem a barra do sistema:
 * o app mostra o próprio nível na borda da tela ([mudouEm] diz quando mostrar).
 */
object Volume {
    private const val FLUXO = AudioManager.STREAM_MUSIC
    val nivel = mutableFloatStateOf(0f)
    val mudouEm = mutableLongStateOf(0L)

    private fun audio(c: Context) = c.getSystemService(AudioManager::class.java)

    fun ler(c: Context) {
        val a = audio(c) ?: return
        nivel.floatValue = a.getStreamVolume(FLUXO) / a.getStreamMaxVolume(FLUXO).coerceAtLeast(1).toFloat()
    }

    fun ajustar(c: Context, subir: Boolean) {
        audio(c)?.adjustStreamVolume(FLUXO, if (subir) AudioManager.ADJUST_RAISE else AudioManager.ADJUST_LOWER, 0)
        ler(c)
        mudouEm.longValue = System.currentTimeMillis()
    }
}
