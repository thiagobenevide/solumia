package com.thiagobenevide.agent.watch

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.compose.material3.Text
import kotlin.math.cos
import kotlin.math.sin
import kotlinx.coroutines.launch

private val confettiColors = listOf(
    Color(0xFF2F6FED), Color(0xFF14B8A6), Color(0xFF8B5CF6), Color(0xFFFFC107), Color(0xFFFF4081),
)

/**
 * Short celebration over the workout panel: a check that pops with a spring and, when [big]
 * (workout finished), confetti bursting from the center. Calls [done] at the end (~1.6 s).
 */
@Composable
fun Celebration(message: String, big: Boolean, done: () -> Unit) {
    val pop = remember { Animatable(0f) }
    val burst = remember { Animatable(0f) }
    val fade = remember { Animatable(1f) }
    val particles = remember {
        List(if (big) 36 else 14) { i -> Triple(i * 6.283f / (if (big) 36 else 14), 0.55f + (i % 5) * 0.12f, i % confettiColors.size) }
    }
    LaunchedEffect(Unit) {
        launch { pop.animateTo(1f, spring(dampingRatio = Spring.DampingRatioMediumBouncy, stiffness = Spring.StiffnessLow)) }
        burst.animateTo(1f, tween(if (big) 1300 else 700, easing = FastOutSlowInEasing))
        fade.animateTo(0f, tween(300))
        done()
    }
    Box(
        Modifier.fillMaxSize().alpha(fade.value).background(Color.Black.copy(alpha = if (big) 0.55f else 0.25f)),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.fillMaxSize()) {
            val t = burst.value
            val radius = size.minDimension / 2
            particles.forEach { (angle, speed, color) ->
                val distance = radius * speed * t
                val center = Offset(
                    size.width / 2 + cos(angle) * distance,
                    size.height / 2 + sin(angle) * distance + (if (big) radius * 0.35f * t * t else 0f),
                )
                drawCircle(confettiColors[color].copy(alpha = 1f - t * 0.6f), radius = (if (big) 5f else 3.5f) * (1f - t * 0.4f), center = center)
            }
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Box(
                Modifier.size(if (big) 64.dp else 52.dp).scale(pop.value).background(Mark.Azul, CircleShape),
                contentAlignment = Alignment.Center,
            ) { Icon(Symbol.CHECK, if (big) 34.dp else 28.dp, Color.White) }
            if (message.isNotEmpty()) {
                Text(
                    message, fontSize = if (big) 15.sp else 12.sp, fontWeight = FontWeight.Bold,
                    textAlign = TextAlign.Center, modifier = Modifier.padding(top = 8.dp).alpha(pop.value.coerceIn(0f, 1f)),
                )
            }
        }
    }
}
