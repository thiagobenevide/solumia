package com.thiagobenevide.agent.relogio

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.health.services.client.HealthServices
import androidx.health.services.client.MeasureCallback
import androidx.health.services.client.data.Availability
import androidx.health.services.client.data.DataPointContainer
import androidx.health.services.client.data.DataType
import androidx.health.services.client.data.DataTypeAvailability
import androidx.health.services.client.data.DeltaDataType
import androidx.wear.compose.material3.Button
import androidx.wear.compose.material3.ButtonDefaults
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.SurfaceTransformation
import androidx.wear.compose.material3.Text
import androidx.wear.compose.material3.lazy.transformedHeight

/**
 * Totais do dia pelo sensor passivo do Health Services (o mesmo que alimenta o Samsung Health):
 * registra o [PassivoServico], que segue recebendo com o app fechado, e relê o que ele guardou.
 */
@Composable
fun SensoresDoDia(autorizado: Boolean) {
    val contexto = LocalContext.current
    LaunchedEffect(autorizado) {
        Passivo.carregar(contexto)
        if (autorizado) Passivo.registrar(contexto)
    }
}

/**
 * Medição avulsa de batimentos (fora do treino) enquanto [ligada]; no treino quem lê é o
 * [TreinoServico] e esta não registra nada.
 */
@Composable
private fun MedicaoAvulsa(ligada: Boolean) {
    val contexto = LocalContext.current
    DisposableEffect(ligada) {
        if (!ligada || Pulso.servicoAtivo.value || !Pulso.autorizado(contexto)) return@DisposableEffect onDispose {}
        val cliente = HealthServices.getClient(contexto).measureClient
        Pulso.zerar()
        Pulso.situacao.value = "procurando…"
        val cb = object : MeasureCallback {
            override fun onAvailabilityChanged(dataType: DeltaDataType<*, *>, availability: Availability) {
                Pulso.situacao.value = when (availability) {
                    DataTypeAvailability.AVAILABLE -> null
                    DataTypeAvailability.UNAVAILABLE_DEVICE_OFF_BODY -> "fora do pulso"
                    else -> "procurando…"
                }
            }

            override fun onDataReceived(data: DataPointContainer) {
                val agora = System.currentTimeMillis()
                data.getData(DataType.HEART_RATE_BPM).forEach { if (it.value >= 25) Pulso.registrar(agora, it.value.toInt()) }
            }
        }
        cliente.registerMeasureCallback(DataType.HEART_RATE_BPM, cb)
        onDispose {
            runCatching { cliente.unregisterMeasureCallbackAsync(DataType.HEART_RATE_BPM, cb) }
            if (!Pulso.servicoAtivo.value) {
                Pulso.bpm.value = null
                Pulso.situacao.value = null
            }
        }
    }
}

/**
 * Página Corpo: batimento ao vivo com a zona, gráfico dos últimos 5 min, média/mín/máx, tempo em
 * cada zona, calorias do treino e os totais do dia. [ativa] = página na tela (mede só nela).
 */
@Composable
fun CorpoTela(ativa: Boolean, atividadeOk: Boolean, pedirAtividade: () -> Unit) {
    val contexto = LocalContext.current
    // mede sozinho com a página na tela, como o Samsung Health; as permissões são pedidas uma vez
    var sensorOk by remember { mutableStateOf(Pulso.autorizado(contexto)) }
    var pediu by remember { mutableStateOf(false) }
    val pedirFundo = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { Passivo.registrar(contexto) }
    val pedirSensor = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        sensorOk = ok
        if (ok) Passivo.permissaoFundo?.let { if (!Passivo.fundoAutorizado(contexto)) pedirFundo.launch(it) }
    }
    LaunchedEffect(ativa) {
        if (ativa && !sensorOk && !pediu) {
            pediu = true
            pedirSensor.launch(Pulso.permissao)
        }
    }
    val medir = ativa && sensorOk
    MedicaoAvulsa(medir)
    Pulso.versao.intValue // relê a cada batimento
    val est = Pulso.estatisticas
    val bpm = Pulso.bpm.value ?: Pulso.ultimoBpm.value?.first
    val treino = Pulso.servicoAtivo.value
    val apagado = MaterialTheme.colorScheme.onSurfaceVariant

    Lista { spec ->
        item {
            Column(
                Modifier.fillMaxWidth().transformedHeight(this, spec),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                val zona = bpm?.let { est.zona(it) }
                val cor = zona?.let { Marca.zonas[it] } ?: MaterialTheme.colorScheme.primary
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Coracao(bpm, 22.dp, cor)
                    AnimatedContent(
                        bpm,
                        transitionSpec = {
                            (slideInVertically { -it / 2 } + fadeIn()) togetherWith (slideOutVertically { it / 2 } + fadeOut())
                        },
                        label = "bpm",
                    ) { v ->
                        Text(v?.toString() ?: "--", fontSize = 40.sp, fontWeight = FontWeight.Bold)
                    }
                    Text("bpm", fontSize = 12.sp, color = apagado, modifier = Modifier.padding(top = 14.dp))
                }
                Text(
                    when {
                        Pulso.situacao.value == "fora do pulso" -> "Relógio fora do pulso"
                        zona != null -> "Zona ${zona + 1} · ${Marca.nomesZonas[zona]} · ${(est.intensidade(bpm) * 100).toInt()}%"
                        treino || medir -> "Procurando o pulso…"
                        else -> "Batimentos e estatísticas"
                    },
                    fontSize = 11.sp, color = if (zona != null) cor else apagado, textAlign = TextAlign.Center,
                )
            }
        }
        if (!sensorOk) {
            item {
                Button(
                    onClick = { pedirSensor.launch(Pulso.permissao) },
                    modifier = Modifier.fillMaxWidth().transformedHeight(this, spec),
                    transformation = SurfaceTransformation(spec),
                    icon = { Icone(Simbolo.PLAY, 20.dp) },
                    label = { Text("Permitir batimentos") },
                )
            }
        }
        if (est.leituras > 1) {
            item {
                Grafico(est, Modifier.fillMaxWidth().height(70.dp).transformedHeight(this, spec))
            }
            item {
                Row(
                    Modifier.fillMaxWidth().transformedHeight(this, spec),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Bloco("Média", est.media?.toString() ?: "--", Modifier.weight(1f))
                    Bloco("Mín", est.minimo?.toString() ?: "--", Modifier.weight(1f))
                    Bloco("Máx", est.maximo?.toString() ?: "--", Modifier.weight(1f))
                }
            }
            item { Zonas(est, Modifier.fillMaxWidth().transformedHeight(this, spec)) }
        }
        Pulso.calorias.value?.let { kcal ->
            item {
                Bloco("Calorias do treino", "${kcal.toInt()} kcal", Modifier.fillMaxWidth().transformedHeight(this, spec))
            }
        }
        item {
            Column(
                Modifier.fillMaxWidth().transformedHeight(this, spec).clip(RoundedCornerShape(22.dp))
                    .background(MaterialTheme.colorScheme.surfaceContainer).padding(12.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text("Hoje", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.primary)
                if (!atividadeOk) {
                    Button(
                        onClick = pedirAtividade, modifier = Modifier.fillMaxWidth(),
                        colors = ButtonDefaults.filledTonalButtonColors(),
                        label = { Text("Permitir passos e calorias", fontSize = 12.sp) },
                    )
                } else {
                    Linha("Passos", Pulso.passos.value?.let { "%,d".format(it).replace(',', '.') })
                    Linha("Calorias", Pulso.caloriasDia.value?.let { "${it.toInt()} kcal" })
                    Linha("Distância", Pulso.distanciaDia.value?.let { "%.2f km".format(it / 1000).replace('.', ',') })
                    Linha("Andares", Pulso.andaresDia.value?.let { "${it.toInt()}" })
                }
            }
        }
    }
}

@Composable
private fun Linha(rotulo: String, valor: String?) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(rotulo, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(valor ?: "…", fontSize = 13.sp, fontWeight = FontWeight.Bold)
    }
}

/** Número em destaque com rótulo pequeno embaixo, num bloco arredondado. */
@Composable
fun Bloco(rotulo: String, valor: String, modifier: Modifier = Modifier, cor: Color = MaterialTheme.colorScheme.onSurface) {
    Column(
        modifier.clip(RoundedCornerShape(16.dp)).background(MaterialTheme.colorScheme.surfaceContainer).padding(vertical = 6.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(valor, fontSize = 15.sp, fontWeight = FontWeight.Bold, color = cor, maxLines = 1)
        Text(rotulo, fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
    }
}

/** Linha dos batimentos recentes, colorida pelas zonas, com preenchimento suave embaixo. */
@Composable
private fun Grafico(est: Estatisticas, modifier: Modifier) {
    val pontos = est.recentes.toList()
    Canvas(modifier.clip(RoundedCornerShape(16.dp)).background(MaterialTheme.colorScheme.surfaceContainer).padding(8.dp)) {
        if (pontos.size < 2) return@Canvas
        val t0 = pontos.first().first
        val dt = (pontos.last().first - t0).coerceAtLeast(1)
        val lo = (pontos.minOf { it.second } - 5).toFloat()
        val hi = (pontos.maxOf { it.second } + 5).toFloat()
        fun xy(p: Pair<Long, Int>) = Offset(
            (p.first - t0) / dt.toFloat() * size.width,
            size.height - (p.second - lo) / (hi - lo) * size.height,
        )
        val linha = Path().apply {
            moveTo(xy(pontos[0]).x, xy(pontos[0]).y)
            pontos.drop(1).forEach { lineTo(xy(it).x, xy(it).y) }
        }
        val area = Path().apply {
            addPath(linha)
            lineTo(size.width, size.height)
            lineTo(0f, size.height)
            close()
        }
        // gradiente vertical pelas zonas: o topo do gráfico com a cor da zona mais alta vista
        val cores = (est.zona(hi.toInt()) downTo est.zona(lo.toInt())).map { Marca.zonas[it] }
        val pincel = if (cores.size > 1) Brush.verticalGradient(cores) else Brush.verticalGradient(listOf(cores[0], cores[0]))
        drawPath(area, Brush.verticalGradient(listOf(cores[0].copy(alpha = 0.35f), Color.Transparent)))
        drawPath(linha, pincel, style = Stroke(2.5.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
        drawCircle(cores[0], 3.dp.toPx(), xy(pontos.last()))
    }
}

/** Barra empilhada com o tempo em cada zona e a legenda das que tiveram tempo. */
@Composable
private fun Zonas(est: Estatisticas, modifier: Modifier) {
    val total = est.zonasMs.sum().coerceAtLeast(1)
    Column(modifier, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(Modifier.fillMaxWidth().height(10.dp).clip(RoundedCornerShape(5.dp))) {
            est.zonasMs.forEachIndexed { i, ms ->
                if (ms > 0) Box(Modifier.weight(ms.toFloat()).height(10.dp).background(Marca.zonas[i]))
            }
            if (est.zonasMs.sum() == 0L) Box(Modifier.weight(1f).height(10.dp).background(MaterialTheme.colorScheme.surfaceContainerHigh))
        }
        est.zonasMs.withIndex().reversed().filter { it.value > 0 }.forEach { (i, ms) ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Box(Modifier.size(8.dp).clip(RoundedCornerShape(4.dp)).background(Marca.zonas[i]))
                Text(Marca.nomesZonas[i], fontSize = 11.sp, modifier = Modifier.weight(1f))
                Text("${relogio((ms / 1000).toInt())} · ${ms * 100 / total}%", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}
