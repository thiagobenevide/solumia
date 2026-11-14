package com.thiagobenevide.agent.relogio

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
 * Tela cheia da atualização, por cima de tudo: oferta (logo com halo girando) → baixando (anel com a
 * porcentagem) → instalando (arco girando) ou falha (com tentar de novo).
 */
@Composable
fun AtualizacaoTela(api: Api) {
    val etapa = Atualizacao.etapa.value ?: return
    val contexto = LocalContext.current
    val escopo = rememberCoroutineScope()
    fun comecar() {
        escopo.launch { Atualizacao.baixarEInstalar(contexto, api) }
    }
    fun fechar() {
        Atualizacao.etapa.value = null
    }
    val build = Atualizacao.novoBuild.value
    Box(Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
        AnimatedContent(
            etapa::class,
            transitionSpec = {
                (fadeIn(tween(300)) + scaleIn(tween(300), initialScale = 0.85f)) togetherWith
                    (fadeOut(tween(200)) + scaleOut(tween(200), targetScale = 1.1f))
            },
            label = "etapa",
        ) { tipo ->
            val atual = Atualizacao.etapa.value ?: etapa
            when (tipo) {
                Etapa.Oferta::class -> Oferta(build, ::comecar, ::fechar)
                Etapa.Baixando::class -> Baixando((atual as? Etapa.Baixando)?.progresso ?: 1f)
                Etapa.Instalando::class -> Girando("Instalando…", "Confirme na tela do relógio")
                Etapa.Autorizar::class -> Aviso(
                    Simbolo.ATUALIZAR, MaterialTheme.colorScheme.primary,
                    "Permita instalar apps do Agent e toque de novo", "Tentar de novo", ::comecar, ::fechar,
                )
                else -> Aviso(
                    Simbolo.FECHAR, MaterialTheme.colorScheme.error,
                    (atual as? Etapa.Falhou)?.motivo ?: "Falhou", "Tentar de novo", ::comecar, ::fechar,
                )
            }
        }
    }
}

@Composable
private fun Oferta(build: Long?, atualizar: () -> Unit, depois: () -> Unit) {
    Column(Modifier.fillMaxSize().padding(horizontal = 26.dp), Arrangement.Center, Alignment.CenterHorizontally) {
        Box(contentAlignment = Alignment.Center) {
            Halo(78.dp)
            LogoAgent(52.dp, respirar = true)
        }
        Text("Nova versão", fontSize = 16.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 6.dp))
        Text(
            build?.let { "Publicada em ${Atualizacao.rotulo(it)}" } ?: "Pronta para instalar",
            fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center,
        )
        Button(
            onClick = atualizar,
            colors = ButtonDefaults.buttonColors(containerColor = Marca.Azul, contentColor = Color.White),
            modifier = Modifier.padding(top = 8.dp),
            icon = { Icone(Simbolo.ATUALIZAR, 18.dp) },
            label = { Text("Atualizar agora", fontWeight = FontWeight.Bold) },
        )
        TextButton(onClick = depois, modifier = Modifier.size(width = 90.dp, height = 36.dp)) {
            Text("Depois", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** Anel girando em gradiente da marca atrás da logo. */
@Composable
private fun Halo(tamanho: Dp) {
    val t = rememberInfiniteTransition(label = "halo")
    val giro by t.animateFloat(0f, 360f, infiniteRepeatable(tween(2400, easing = LinearEasing)), label = "g")
    Canvas(Modifier.size(tamanho).rotate(giro)) {
        drawCircle(
            Brush.sweepGradient(listOf(Color.Transparent, Marca.Azul, Marca.Roxo, Color.Transparent)),
            style = Stroke(4.dp.toPx(), cap = StrokeCap.Round),
        )
    }
}

@Composable
private fun Baixando(progresso: Float) {
    val p by animateFloatAsState(progresso, tween(250), label = "baixando")
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        AnelProgresso(p, Modifier.fillMaxSize().padding(6.dp), 9.dp)
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            LogoAgent(34.dp, respirar = true)
            Text("${(p * 100).toInt()}%", fontSize = 34.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 4.dp))
            Text("Baixando a versão nova", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** Arco que gira e estica, para etapas sem porcentagem (o instalador do Android). */
@Composable
private fun Girando(titulo: String, detalhe: String) {
    val t = rememberInfiniteTransition(label = "girando")
    val giro by t.animateFloat(0f, 360f, infiniteRepeatable(tween(1100, easing = LinearEasing)), label = "g")
    val arco by t.animateFloat(40f, 260f, infiniteRepeatable(tween(900, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "a")
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize().padding(6.dp).rotate(giro)) {
            val e = 9.dp.toPx()
            val lado = size.minDimension - e
            drawArc(
                Brush.sweepGradient(Marca.gradiente), 0f, arco, false, Offset(e / 2, e / 2), Size(lado, lado),
                style = Stroke(e, cap = StrokeCap.Round),
            )
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            LogoAgent(40.dp, respirar = true)
            Text(titulo, fontSize = 16.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 6.dp))
            Text(detalhe, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
        }
    }
}

@Composable
private fun Aviso(simbolo: Simbolo, cor: Color, texto: String, botao: String, acao: () -> Unit, fechar: () -> Unit) {
    // tremidinha de entrada, como o "não" do relógio
    val tremor = remember { Animatable(0f) }
    LaunchedEffect(Unit) {
        for (x in listOf(10f, -8f, 6f, -4f, 0f)) tremor.animateTo(x, tween(60))
    }
    Column(Modifier.fillMaxSize().padding(horizontal = 26.dp), Arrangement.Center, Alignment.CenterHorizontally) {
        Box(
            Modifier.padding(start = tremor.value.coerceAtLeast(0f).dp, end = (-tremor.value).coerceAtLeast(0f).dp)
                .size(48.dp).background(cor.copy(alpha = 0.2f), androidx.compose.foundation.shape.CircleShape),
            contentAlignment = Alignment.Center,
        ) { Icone(simbolo, 22.dp, cor) }
        Text(texto, fontSize = 13.sp, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 8.dp))
        Button(
            onClick = acao,
            colors = ButtonDefaults.buttonColors(containerColor = Marca.Azul, contentColor = Color.White),
            modifier = Modifier.padding(top = 8.dp),
            label = { Text(botao) },
        )
        TextButton(onClick = fechar, modifier = Modifier.size(width = 90.dp, height = 36.dp)) {
            Text("Fechar", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/**
 * Comemoração na primeira abertura depois de atualizar: o círculo da marca cresce com mola, o ✓ se
 * desenha, faíscas saem do centro e a mensagem aparece; some sozinha em 4 s (ou ao tocar).
 */
@Composable
fun Atualizado(build: Long, fechar: () -> Unit) {
    val circulo = remember { Animatable(0f) }
    val traco = remember { Animatable(0f) }
    val faiscas = remember { Animatable(0f) }
    val texto = remember { Animatable(0f) }
    LaunchedEffect(Unit) {
        circulo.animateTo(1f, spring(dampingRatio = Spring.DampingRatioMediumBouncy, stiffness = Spring.StiffnessLow))
    }
    LaunchedEffect(Unit) {
        delay(250)
        launch { faiscas.animateTo(1f, tween(900, easing = FastOutSlowInEasing)) }
        traco.animateTo(1f, tween(450, easing = FastOutSlowInEasing))
        texto.animateTo(1f, tween(350))
        delay(3000)
        fechar()
    }
    Box(Modifier.fillMaxSize().background(Color.Black).clickable(onClick = fechar), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            val c = Offset(size.width / 2, size.height / 2 - 18.dp.toPx())
            val raio = 34.dp.toPx()
            // faíscas em duas voltas, nas cores da marca e das zonas
            val cores = Marca.gradiente + Marca.zonas
            val f = faiscas.value
            if (f in 0.01f..0.99f) {
                for (k in 0 until 16) {
                    val ang = Math.toRadians(k * 22.5 + if (k % 2 == 0) 0.0 else 11.0)
                    val dist = raio + f * (size.minDimension / 2 - raio) * (if (k % 2 == 0) 0.9f else 0.65f)
                    val p = Offset(c.x + cos(ang).toFloat() * dist, c.y + sin(ang).toFloat() * dist)
                    drawCircle(cores[k % cores.size], (1f - f) * 4.dp.toPx() + 1f, p, alpha = 1f - f)
                }
            }
            drawCircle(Marca.diagonal(size.width), raio * circulo.value, c)
            // ✓ desenhado aos poucos: primeiro a perna curta, depois a longa
            val a = Offset(c.x - raio * 0.42f, c.y + raio * 0.02f)
            val b = Offset(c.x - raio * 0.1f, c.y + raio * 0.34f)
            val d = Offset(c.x + raio * 0.46f, c.y - raio * 0.3f)
            val l1 = hypot(b.x - a.x, b.y - a.y)
            val l2 = hypot(d.x - b.x, d.y - b.y)
            val feito = traco.value * (l1 + l2)
            val e = 6.dp.toPx()
            if (feito > 0f) {
                val t1 = (feito / l1).coerceAtMost(1f)
                drawLine(Color.White, a, Offset(a.x + (b.x - a.x) * t1, a.y + (b.y - a.y) * t1), e, StrokeCap.Round)
                if (feito > l1) {
                    val t2 = ((feito - l1) / l2).coerceAtMost(1f)
                    drawLine(Color.White, b, Offset(b.x + (d.x - b.x) * t2, b.y + (d.y - b.y) * t2), e, StrokeCap.Round)
                }
            }
        }
        Column(
            Modifier.padding(top = 92.dp).scale(0.9f + 0.1f * texto.value),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                "Atualizado!", fontSize = 18.sp, fontWeight = FontWeight.Bold,
                color = Color.White.copy(alpha = texto.value),
            )
            Text(
                "Versão de ${Atualizacao.rotulo(build)}", fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = texto.value),
            )
        }
    }
}
