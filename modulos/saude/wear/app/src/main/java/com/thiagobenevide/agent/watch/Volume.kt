package com.thiagobenevide.agent.watch

import android.content.Context
import android.media.AudioManager
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf

/**
 * Watch media volume (the coach voice plays through it). Adjusts without the system bar:
 * the app shows its own level on the screen edge ([changedAt] says when to show it).
 */
object Volume {
    private const val FLOW = AudioManager.STREAM_MUSIC
    val level = mutableFloatStateOf(0f)
    val changedAt = mutableLongStateOf(0L)

    private fun audio(c: Context) = c.getSystemService(AudioManager::class.java)

    fun read(c: Context) {
        val a = audio(c) ?: return
        level.floatValue = a.getStreamVolume(FLOW) / a.getStreamMaxVolume(FLOW).coerceAtLeast(1).toFloat()
    }

    fun adjust(c: Context, upload: Boolean) {
        audio(c)?.adjustStreamVolume(FLOW, if (upload) AudioManager.ADJUST_RAISE else AudioManager.ADJUST_LOWER, 0)
        read(c)
        changedAt.longValue = System.currentTimeMillis()
    }
}
