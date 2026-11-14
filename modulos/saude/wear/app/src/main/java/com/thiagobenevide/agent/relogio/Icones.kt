package com.thiagobenevide.agent.relogio

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.wear.compose.material3.LocalContentColor

/** Ícones desenhados à mão (sem depender de pacote de ícones): os do painel de controle do relógio. */
enum class Simbolo { PLAY, PAUSA, PROXIMO, ANTERIOR, CHECK, MIC, PARAR, VOLUME_MENOS, VOLUME_MAIS, VOZ_MUDA, MAIS, MENOS,
    LIXO, LISTA, AGENDA, SINO, GRAFICO, HALTER, FECHAR, ATUALIZAR }

@Composable
fun Icone(s: Simbolo, tamanho: Dp = 24.dp, cor: Color = LocalContentColor.current) {
    Canvas(Modifier.size(tamanho)) { desenhar(s, cor) }
}

private fun DrawScope.desenhar(s: Simbolo, cor: Color) {
    val w = size.width
    val h = size.height
    fun p(x: Float, y: Float) = Offset(x * w, y * h)
    fun poligono(vararg pts: Pair<Float, Float>) = drawPath(
        Path().apply {
            moveTo(pts[0].first * w, pts[0].second * h)
            pts.drop(1).forEach { lineTo(it.first * w, it.second * h) }
            close()
        },
        cor,
    )
    fun barra(x0: Float, y0: Float, x1: Float, y1: Float) = drawRoundRect(
        cor, p(x0, y0), Size((x1 - x0) * w, (y1 - y0) * h), CornerRadius(w * 0.04f),
    )
    fun linha(a: Offset, b: Offset, e: Float = 0.11f) = drawLine(cor, a, b, w * e, StrokeCap.Round)
    fun alto() = poligono(0.08f to 0.38f, 0.28f to 0.38f, 0.52f to 0.15f, 0.52f to 0.85f, 0.28f to 0.62f, 0.08f to 0.62f)

    when (s) {
        Simbolo.PLAY -> poligono(0.26f to 0.14f, 0.86f to 0.5f, 0.26f to 0.86f)
        Simbolo.PAUSA -> {
            barra(0.22f, 0.15f, 0.42f, 0.85f)
            barra(0.58f, 0.15f, 0.78f, 0.85f)
        }
        Simbolo.PROXIMO -> {
            poligono(0.16f to 0.16f, 0.66f to 0.5f, 0.16f to 0.84f)
            barra(0.68f, 0.16f, 0.82f, 0.84f)
        }
        Simbolo.ANTERIOR -> {
            poligono(0.84f to 0.16f, 0.34f to 0.5f, 0.84f to 0.84f)
            barra(0.18f, 0.16f, 0.32f, 0.84f)
        }
        Simbolo.CHECK -> {
            linha(p(0.18f, 0.52f), p(0.42f, 0.76f), 0.13f)
            linha(p(0.42f, 0.76f), p(0.84f, 0.28f), 0.13f)
        }
        Simbolo.MIC -> {
            drawRoundRect(cor, p(0.36f, 0.08f), Size(0.28f * w, 0.5f * h), CornerRadius(w * 0.14f))
            drawArc(cor, 0f, 180f, false, p(0.22f, 0.22f), Size(0.56f * w, 0.5f * h), style = Stroke(w * 0.08f, cap = StrokeCap.Round))
            linha(p(0.5f, 0.72f), p(0.5f, 0.88f), 0.08f)
            linha(p(0.34f, 0.9f), p(0.66f, 0.9f), 0.08f)
        }
        Simbolo.PARAR -> barra(0.22f, 0.22f, 0.78f, 0.78f)
        Simbolo.VOLUME_MENOS -> {
            alto()
            linha(p(0.64f, 0.5f), p(0.94f, 0.5f), 0.09f)
        }
        Simbolo.VOLUME_MAIS -> {
            alto()
            linha(p(0.64f, 0.5f), p(0.94f, 0.5f), 0.09f)
            linha(p(0.79f, 0.35f), p(0.79f, 0.65f), 0.09f)
        }
        Simbolo.VOZ_MUDA -> {
            alto()
            linha(p(0.66f, 0.36f), p(0.92f, 0.64f), 0.08f)
            linha(p(0.92f, 0.36f), p(0.66f, 0.64f), 0.08f)
        }
        Simbolo.MAIS -> {
            linha(p(0.2f, 0.5f), p(0.8f, 0.5f))
            linha(p(0.5f, 0.2f), p(0.5f, 0.8f))
        }
        Simbolo.MENOS -> linha(p(0.2f, 0.5f), p(0.8f, 0.5f))
        Simbolo.LIXO -> {
            linha(p(0.16f, 0.24f), p(0.84f, 0.24f), 0.09f)
            linha(p(0.4f, 0.12f), p(0.6f, 0.12f), 0.09f)
            drawRoundRect(cor, p(0.24f, 0.32f), Size(0.52f * w, 0.56f * h), CornerRadius(w * 0.07f))
        }
        Simbolo.LISTA -> {
            for (y in listOf(0.26f, 0.5f, 0.74f)) {
                drawCircle(cor, w * 0.06f, p(0.18f, y))
                linha(p(0.34f, y), p(0.86f, y), 0.1f)
            }
        }
        Simbolo.AGENDA -> {
            drawRoundRect(cor, p(0.12f, 0.2f), Size(0.76f * w, 0.68f * h), CornerRadius(w * 0.1f), style = Stroke(w * 0.09f))
            barra(0.12f, 0.2f, 0.88f, 0.38f)
            linha(p(0.32f, 0.1f), p(0.32f, 0.26f), 0.09f)
            linha(p(0.68f, 0.1f), p(0.68f, 0.26f), 0.09f)
            linha(p(0.34f, 0.62f), p(0.46f, 0.74f), 0.09f)
            linha(p(0.46f, 0.74f), p(0.68f, 0.5f), 0.09f)
        }
        Simbolo.SINO -> {
            poligono(0.5f to 0.12f, 0.74f to 0.3f, 0.78f to 0.68f, 0.9f to 0.78f, 0.1f to 0.78f, 0.22f to 0.68f, 0.26f to 0.3f)
            drawCircle(cor, w * 0.09f, p(0.5f, 0.88f))
        }
        Simbolo.GRAFICO -> {
            linha(p(0.1f, 0.62f), p(0.3f, 0.62f), 0.09f)
            linha(p(0.3f, 0.62f), p(0.42f, 0.22f), 0.09f)
            linha(p(0.42f, 0.22f), p(0.58f, 0.82f), 0.09f)
            linha(p(0.58f, 0.82f), p(0.7f, 0.5f), 0.09f)
            linha(p(0.7f, 0.5f), p(0.9f, 0.5f), 0.09f)
        }
        Simbolo.HALTER -> {
            barra(0.06f, 0.36f, 0.16f, 0.64f)
            barra(0.18f, 0.24f, 0.32f, 0.76f)
            barra(0.68f, 0.24f, 0.82f, 0.76f)
            barra(0.84f, 0.36f, 0.94f, 0.64f)
            barra(0.32f, 0.45f, 0.68f, 0.55f)
        }
        Simbolo.FECHAR -> {
            linha(p(0.24f, 0.24f), p(0.76f, 0.76f))
            linha(p(0.76f, 0.24f), p(0.24f, 0.76f))
        }
        Simbolo.ATUALIZAR -> {
            drawArc(cor, -60f, 290f, false, p(0.18f, 0.18f), Size(0.64f * w, 0.64f * h), style = Stroke(w * 0.1f, cap = StrokeCap.Round))
            poligono(0.66f to 0.06f, 0.9f to 0.26f, 0.6f to 0.36f)
        }
    }
}
