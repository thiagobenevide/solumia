package com.thiagobenevide.agent.relogio

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.wear.compose.material3.ColorScheme
import androidx.wear.compose.material3.MaterialTheme

/** Cores da logo do Agent: gradiente do azul (canto de cima) ao roxo (canto de baixo). */
object Marca {
    val Azul = Color(0xFF356BEC)
    val Anil = Color(0xFF5557E8)
    val Roxo = Color(0xFF7543E5)
    val AzulClaro = Color(0xFF8AA8FF)
    val RoxoClaro = Color(0xFFB59BFF)
    val gradiente = listOf(Azul, Anil, Roxo)
    fun diagonal(lado: Float) = Brush.linearGradient(gradiente, Offset.Zero, Offset(lado, lado))

    /** Zonas de batimento (1 a 5), do leve ao máximo, como no Samsung Health. */
    val zonas = listOf(Color(0xFF8AA8FF), Color(0xFF4FC3F7), Color(0xFF5BD69B), Color(0xFFFFB547), Color(0xFFFF5C6C))
    val nomesZonas = listOf("Leve", "Aquecimento", "Aeróbico", "Anaeróbico", "Máximo")
}

/** Tema escuro do relógio (fundo preto para a tela OLED) com a paleta da logo. */
@Composable
fun TemaAgent(conteudo: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = ColorScheme(
            primary = Color(0xFF6E92F7),
            primaryDim = Marca.Azul,
            primaryContainer = Color(0xFF1F2F6E),
            onPrimary = Color.White,
            onPrimaryContainer = Color(0xFFDCE4FF),
            secondary = Color(0xFF9D80F5),
            secondaryDim = Marca.Roxo,
            secondaryContainer = Color(0xFF34236E),
            onSecondary = Color.White,
            onSecondaryContainer = Color(0xFFE8DFFF),
            tertiary = Color(0xFF7FD0FF),
            tertiaryDim = Color(0xFF4FA8E0),
            tertiaryContainer = Color(0xFF113A57),
            onTertiary = Color(0xFF00243A),
            onTertiaryContainer = Color(0xFFCDEBFF),
            surfaceContainerLow = Color(0xFF0E1120),
            surfaceContainer = Color(0xFF161A30),
            surfaceContainerHigh = Color(0xFF212642),
            onSurface = Color(0xFFEDEFFA),
            onSurfaceVariant = Color(0xFFA7AECF),
            outline = Color(0xFF5B6286),
            outlineVariant = Color(0xFF2E3454),
            background = Color.Black,
            onBackground = Color.White,
            error = Color(0xFFFF6B7A),
            errorDim = Color(0xFFE04A5C),
            errorContainer = Color(0xFF5C1520),
            onError = Color.White,
            onErrorContainer = Color(0xFFFFDADD),
        ),
        content = conteudo,
    )
}

/**
 * Logo do Agent (a mesma do app do celular): círculo em gradiente azul→roxo com o nó central ligado
 * a três nós. [respirar] faz a logo pulsar de leve (usado quando o app está pensando).
 */
@Composable
fun LogoAgent(tamanho: Dp = 40.dp, respirar: Boolean = false) {
    val escala = if (respirar) {
        val t = rememberInfiniteTransition(label = "logo")
        t.animateFloat(0.92f, 1.06f, infiniteRepeatable(tween(900, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "e").value
    } else {
        1f
    }
    Canvas(Modifier.size(tamanho).scale(escala)) {
        val l = size.width
        drawCircle(Marca.diagonal(l))
        // coordenadas do desenho original (256 × 256), centralizado no círculo
        fun p(x: Float, y: Float) = Offset(x / 256f * l, (y + 8f) / 256f * l)
        val branco = Color.White
        val haste = 11f / 256f * l
        val centro = p(128f, 128f)
        listOf(p(128f, 71f), p(73f, 167f), p(183f, 167f)).forEach {
            drawLine(branco, centro, it, haste, StrokeCap.Round)
            drawCircle(branco, 18f / 256f * l, it)
        }
        drawCircle(branco, 29f / 256f * l, centro)
    }
}

/**
 * Anel de progresso na borda redonda: trilho apagado e arco em gradiente da marca (ou [cor] fixa),
 * com a ponta arredondada. [progresso] de 0 a 1.
 */
@Composable
fun AnelProgresso(progresso: Float, modifier: Modifier, espessura: Dp = 7.dp, cor: Color? = null) {
    val trilho = MaterialTheme.colorScheme.surfaceContainerHigh
    Canvas(modifier) {
        val e = espessura.toPx()
        val lado = size.minDimension - e
        val canto = Offset((size.width - lado) / 2, (size.height - lado) / 2)
        val caixa = Size(lado, lado)
        drawArc(trilho, -90f, 360f, false, canto, caixa, style = Stroke(e, cap = StrokeCap.Round))
        val p = progresso.coerceIn(0f, 1f)
        if (p <= 0f) return@Canvas
        val pincel = cor?.let { androidx.compose.ui.graphics.SolidColor(it) }
            ?: Brush.sweepGradient(Marca.gradiente + Marca.Azul, Offset(size.width / 2, size.height / 2))
        rotate(-90f) { drawArc(pincel, 0f, 360f * p, false, canto, caixa, style = Stroke(e, cap = StrokeCap.Round)) }
    }
}

/** Coração que bate no ritmo do [bpm] (parado sem leitura). */
@Composable
fun Coracao(bpm: Int?, tamanho: Dp = 16.dp, cor: Color = Marca.zonas[4]) {
    val periodo = (60_000 / (bpm ?: 60).coerceIn(30, 220))
    val t = rememberInfiniteTransition(label = "coracao")
    val batida by t.animateFloat(
        1f, if (bpm != null) 1.22f else 1f,
        infiniteRepeatable(tween(periodo / 2, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "b",
    )
    Canvas(Modifier.size(tamanho).scale(batida)) {
        val w = size.width
        val h = size.height
        drawPath(
            Path().apply {
                moveTo(w * 0.5f, h * 0.9f)
                cubicTo(w * 0.05f, h * 0.6f, w * 0.0f, h * 0.25f, w * 0.27f, h * 0.15f)
                cubicTo(w * 0.4f, h * 0.1f, w * 0.48f, h * 0.2f, w * 0.5f, h * 0.3f)
                cubicTo(w * 0.52f, h * 0.2f, w * 0.6f, h * 0.1f, w * 0.73f, h * 0.15f)
                cubicTo(w * 1.0f, h * 0.25f, w * 0.95f, h * 0.6f, w * 0.5f, h * 0.9f)
                close()
            },
            cor,
        )
    }
}

/** Barras de equalizador animadas: a voz do cobrador tocando. */
@Composable
fun Equalizador(cor: Color = MaterialTheme.colorScheme.primary, altura: Dp = 18.dp) {
    val t = rememberInfiniteTransition(label = "eq")
    Row(horizontalArrangement = Arrangement.spacedBy(3.dp), verticalAlignment = Alignment.Bottom) {
        listOf(420, 300, 520, 360).forEachIndexed { i, ms ->
            val f by t.animateFloat(0.25f, 1f, infiniteRepeatable(tween(ms, easing = LinearEasing), RepeatMode.Reverse), label = "b$i")
            Box(Modifier.width(4.dp).height(altura * f).clip(RoundedCornerShape(2.dp)).background(cor))
        }
    }
}

/** Três pontos que sobem em sequência: "pensando…". */
@Composable
fun Pensando(cor: Color = MaterialTheme.colorScheme.onSurfaceVariant) {
    val t = rememberInfiniteTransition(label = "pontos")
    Row(horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
        repeat(3) { i ->
            val f by t.animateFloat(
                0f, 1f,
                infiniteRepeatable(tween(1200, easing = LinearEasing), RepeatMode.Restart), label = "p$i",
            )
            val fase = ((f * 3f - i) % 3f + 3f) % 3f
            val alto = if (fase < 1f) kotlin.math.sin(fase * Math.PI).toFloat() else 0f
            Box(Modifier.size(7.dp).scale(0.7f + 0.5f * alto).clip(RoundedCornerShape(50)).background(cor.copy(alpha = 0.4f + 0.6f * alto)))
        }
    }
}
