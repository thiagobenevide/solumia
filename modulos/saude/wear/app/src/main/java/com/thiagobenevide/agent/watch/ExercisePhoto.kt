package com.thiagobenevide.agent.watch

import android.graphics.Bitmap
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.compose.material3.Button
import androidx.wear.compose.material3.ButtonDefaults
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.Text
import kotlinx.coroutines.delay

/**
 * How to do the current exercise, opened from the name in the workout panel: the two photos
 * (start and end of the movement) alternating like an animation, the coach's cue for the day and
 * the instructions. Scrolls with the finger; "Voltar" returns to the panel.
 */
@Composable
fun ExercisePhoto(api: Api, exercise: Exercise, close: () -> Unit) {
    var frames by remember(exercise.exerciseId) { mutableStateOf<List<Bitmap>>(emptyList()) }
    var loading by remember(exercise.exerciseId) { mutableStateOf(true) }
    var frame by remember { mutableIntStateOf(0) }

    LaunchedEffect(exercise.exerciseId) {
        val loaded = mutableListOf<Bitmap>()
        if (exercise.exerciseId.isNotEmpty()) {
            for (n in 0..1) api.exerciseImage(exercise.exerciseId, n)?.let { loaded.add(it) }
        }
        frames = loaded
        loading = false
    }
    LaunchedEffect(frames) {
        while (frames.size > 1) {
            delay(1200)
            frame = (frame + 1) % frames.size
        }
    }

    val off = MaterialTheme.colorScheme.onSurfaceVariant
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 26.dp, vertical = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(exercise.name, fontWeight = FontWeight.Bold, fontSize = 14.sp, textAlign = TextAlign.Center)
        Box(
            Modifier.fillMaxWidth().aspectRatio(1.4f).clip(RoundedCornerShape(12.dp)),
            contentAlignment = Alignment.Center,
        ) {
            when {
                frames.isNotEmpty() -> Crossfade(frames[frame % frames.size], animationSpec = tween(300), label = "foto") { bitmap ->
                    Image(
                        bitmap.asImageBitmap(), exercise.name,
                        contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize(),
                    )
                }
                loading -> Text("Carregando foto…", fontSize = 11.sp, color = off)
                else -> Text("Sem foto deste exercício", fontSize = 11.sp, color = off, textAlign = TextAlign.Center)
            }
        }
        if (exercise.cue.isNotBlank()) {
            Text(exercise.cue, fontSize = 12.sp, color = MaterialTheme.colorScheme.primary, textAlign = TextAlign.Center)
        }
        Text(
            "${exercise.planned} × ${exercise.repetitions} · ${load(exercise.load)}",
            fontSize = 11.sp, color = off,
        )
        if (exercise.instructions.isNotBlank()) {
            Text(exercise.instructions, fontSize = 12.sp, textAlign = TextAlign.Center)
        }
        Button(
            onClick = close,
            colors = ButtonDefaults.filledTonalButtonColors(),
            modifier = Modifier.padding(top = 4.dp),
            label = { Text("Voltar") },
        )
    }
}
