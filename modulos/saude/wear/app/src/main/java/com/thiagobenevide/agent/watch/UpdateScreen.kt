package com.thiagobenevide.agent.watch

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.compose.material3.Button
import androidx.wear.compose.material3.ButtonDefaults
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.Text
import androidx.wear.compose.material3.TextButton
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sin

/**
 * Full update screen, on top of everything: offer (logo with spinning halo) → downloading (ring with the
 * percentage) → installing (spinning arc) or failure (with try again).
 */
@Composable
fun UpdateScreen(api: Api) {
    val stage = Update.stage.value ?: return
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    fun launch() {
        scope.launch { Update.downloadAndInstall(context, api) }
    }
    fun close() {
        Update.stage.value = null
    }
    val build = Update.newBuild.value
    Box(Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
        AnimatedContent(
            stage::class,
            transitionSpec = {
                (fadeIn(tween(300)) + scaleIn(tween(300), initialScale = 0.85f)) togetherWith
                    (fadeOut(tween(200)) + scaleOut(tween(200), targetScale = 1.1f))
            },
            label = "etapa",
        ) { kind ->
            val current = Update.stage.value ?: stage
            when (kind) {
                Stage.Oferta::class -> Oferta(build, ::launch, ::close)
                Stage.Downloading::class -> Downloading((current as? Stage.Downloading)?.progress ?: 1f)
                Stage.Instalando::class -> Girando("Instalando…", "Confirme na tela do relógio")
                Stage.Authorize::class -> Warning(
                    Symbol.UPDATE, MaterialTheme.colorScheme.primary,
                    "Permita instalar apps do Agent e toque de novo", "Tentar de novo", ::launch, ::close,
                )
                else -> Warning(
                    Symbol.CLOSE, MaterialTheme.colorScheme.error,
                    (current as? Stage.Failed)?.reason ?: "Falhou", "Tentar de novo", ::launch, ::close,
                )
            }
        }
    }
}

@Composable
private fun Oferta(build: Long?, update: () -> Unit, after: () -> Unit) {
    Column(Modifier.fillMaxSize().padding(horizontal = 26.dp), Arrangement.Center, Alignment.CenterHorizontally) {
        Box(contentAlignment = Alignment.Center) {
            Halo(78.dp)
            LogoAgent(52.dp, breathe = true)
        }
        Text("Nova versão", fontSize = 16.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 6.dp))
        Text(
            build?.let { "Publicada em ${Update.label(it)}" } ?: "Pronta para instalar",
            fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center,
        )
        Button(
            onClick = update,
            colors = ButtonDefaults.buttonColors(containerColor = Mark.Azul, contentColor = Color.White),
            modifier = Modifier.padding(top = 8.dp),
            icon = { Icon(Symbol.UPDATE, 18.dp) },
            label = { Text("Atualizar agora", fontWeight = FontWeight.Bold) },
        )
        TextButton(onClick = after, modifier = Modifier.size(width = 90.dp, height = 36.dp)) {
            Text("Depois", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** Ring spinning in brand gradient behind the logo. */
@Composable
private fun Halo(sizeDp: Dp) {
    val t = rememberInfiniteTransition(label = "halo")
    val spin by t.animateFloat(0f, 360f, infiniteRepeatable(tween(2400, easing = LinearEasing)), label = "g")
    Canvas(Modifier.size(sizeDp).rotate(spin)) {
        drawCircle(
            Brush.sweepGradient(listOf(Color.Transparent, Mark.Azul, Mark.Roxo, Color.Transparent)),
            style = Stroke(4.dp.toPx(), cap = StrokeCap.Round),
        )
    }
}

@Composable
private fun Downloading(progress: Float) {
    val p by animateFloatAsState(progress, tween(250), label = "baixando")
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        ProgressRing(p, Modifier.fillMaxSize().padding(6.dp), 9.dp)
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            LogoAgent(34.dp, breathe = true)
            Text("${(p * 100).toInt()}%", fontSize = 34.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 4.dp))
            Text("Baixando a versão nova", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** Arc that spins and stretches, for stages without a percentage (the Android installer). */
@Composable
private fun Girando(title: String, detail: String) {
    val t = rememberInfiniteTransition(label = "girando")
    val spin by t.animateFloat(0f, 360f, infiniteRepeatable(tween(1100, easing = LinearEasing)), label = "g")
    val arc by t.animateFloat(40f, 260f, infiniteRepeatable(tween(900, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "a")
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize().padding(6.dp).rotate(spin)) {
            val e = 9.dp.toPx()
            val side = size.minDimension - e
            drawArc(
                Brush.sweepGradient(Mark.gradiente), 0f, arc, false, Offset(e / 2, e / 2), Size(side, side),
                style = Stroke(e, cap = StrokeCap.Round),
            )
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            LogoAgent(40.dp, breathe = true)
            Text(title, fontSize = 16.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 6.dp))
            Text(detail, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
        }
    }
}

@Composable
private fun Warning(symbol: Symbol, color: Color, text: String, button: String, action: () -> Unit, close: () -> Unit) {
    // small entry shake, like the watch's "no"
    val tremor = remember { Animatable(0f) }
    LaunchedEffect(Unit) {
        for (x in listOf(10f, -8f, 6f, -4f, 0f)) tremor.animateTo(x, tween(60))
    }
    Column(Modifier.fillMaxSize().padding(horizontal = 26.dp), Arrangement.Center, Alignment.CenterHorizontally) {
        Box(
            Modifier.padding(start = tremor.value.coerceAtLeast(0f).dp, end = (-tremor.value).coerceAtLeast(0f).dp)
                .size(48.dp).background(color.copy(alpha = 0.2f), androidx.compose.foundation.shape.CircleShape),
            contentAlignment = Alignment.Center,
        ) { Icon(symbol, 22.dp, color) }
        Text(text, fontSize = 13.sp, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 8.dp))
        Button(
            onClick = action,
            colors = ButtonDefaults.buttonColors(containerColor = Mark.Azul, contentColor = Color.White),
            modifier = Modifier.padding(top = 8.dp),
            label = { Text(button) },
        )
        TextButton(onClick = close, modifier = Modifier.size(width = 90.dp, height = 36.dp)) {
            Text("Fechar", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/**
 * Celebration on the first open after updating: the brand circle grows with a spring, the ✓ draws
 * itself, sparks fly from the center and the message appears; it goes away on its own in 4 s (or on tap).
 */
@Composable
fun Updated(build: Long, close: () -> Unit) {
    val circulo = remember { Animatable(0f) }
    val traco = remember { Animatable(0f) }
    val faiscas = remember { Animatable(0f) }
    val text = remember { Animatable(0f) }
    LaunchedEffect(Unit) {
        circulo.animateTo(1f, spring(dampingRatio = Spring.DampingRatioMediumBouncy, stiffness = Spring.StiffnessLow))
    }
    LaunchedEffect(Unit) {
        delay(250)
        launch { faiscas.animateTo(1f, tween(900, easing = FastOutSlowInEasing)) }
        traco.animateTo(1f, tween(450, easing = FastOutSlowInEasing))
        text.animateTo(1f, tween(350))
        delay(3000)
        close()
    }
    Box(Modifier.fillMaxSize().background(Color.Black).clickable(onClick = close), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            val c = Offset(size.width / 2, size.height / 2 - 18.dp.toPx())
            val raio = 34.dp.toPx()
            // sparks in two rounds, in the brand and zone colors
            val colors = Mark.gradiente + Mark.zones
            val f = faiscas.value
            if (f in 0.01f..0.99f) {
                for (k in 0 until 16) {
                    val ang = Math.toRadians(k * 22.5 + if (k % 2 == 0) 0.0 else 11.0)
                    val dist = raio + f * (size.minDimension / 2 - raio) * (if (k % 2 == 0) 0.9f else 0.65f)
                    val p = Offset(c.x + cos(ang).toFloat() * dist, c.y + sin(ang).toFloat() * dist)
                    drawCircle(colors[k % colors.size], (1f - f) * 4.dp.toPx() + 1f, p, alpha = 1f - f)
                }
            }
            drawCircle(Mark.diagonal(size.width), raio * circulo.value, c)
            // ✓ drawn little by little: first the short leg, then the long one
            val a = Offset(c.x - raio * 0.42f, c.y + raio * 0.02f)
            val b = Offset(c.x - raio * 0.1f, c.y + raio * 0.34f)
            val d = Offset(c.x + raio * 0.46f, c.y - raio * 0.3f)
            val l1 = hypot(b.x - a.x, b.y - a.y)
            val l2 = hypot(d.x - b.x, d.y - b.y)
            val done = traco.value * (l1 + l2)
            val e = 6.dp.toPx()
            if (done > 0f) {
                val t1 = (done / l1).coerceAtMost(1f)
                drawLine(Color.White, a, Offset(a.x + (b.x - a.x) * t1, a.y + (b.y - a.y) * t1), e, StrokeCap.Round)
                if (done > l1) {
                    val t2 = ((done - l1) / l2).coerceAtMost(1f)
                    drawLine(Color.White, b, Offset(b.x + (d.x - b.x) * t2, b.y + (d.y - b.y) * t2), e, StrokeCap.Round)
                }
            }
        }
        Column(
            Modifier.padding(top = 92.dp).scale(0.9f + 0.1f * text.value),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                "Atualizado!", fontSize = 18.sp, fontWeight = FontWeight.Bold,
                color = Color.White.copy(alpha = text.value),
            )
            Text(
                "Versão de ${Update.label(build)}", fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = text.value),
            )
        }
    }
}
