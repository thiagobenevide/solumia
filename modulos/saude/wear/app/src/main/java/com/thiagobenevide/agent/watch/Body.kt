package com.thiagobenevide.agent.watch

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
 * Day totals from the Health Services passive sensor (the same one that feeds Samsung Health):
 * registers the [PassiveService], which keeps receiving with the app closed, and rereads what it stored.
 */
@Composable
fun DailySensors(authorized: Boolean) {
    val context = LocalContext.current
    LaunchedEffect(authorized) {
        Passive.load(context)
        if (authorized) Passive.register(context)
    }
}

/**
 * Spot heartbeat measurement (outside the workout) while [on]; during a workout the
 * [WorkoutService] reads and this one records nothing.
 */
@Composable
private fun SpotMeasurement(on: Boolean) {
    val context = LocalContext.current
    DisposableEffect(on) {
        if (!on || Pulse.serviceActive.value || !Pulse.authorized(context)) return@DisposableEffect onDispose {}
        val cliente = HealthServices.getClient(context).measureClient
        Pulse.reset()
        Pulse.status.value = "procurando…"
        val cb = object : MeasureCallback {
            override fun onAvailabilityChanged(dataType: DeltaDataType<*, *>, availability: Availability) {
                Pulse.status.value = when (availability) {
                    DataTypeAvailability.AVAILABLE -> null
                    DataTypeAvailability.UNAVAILABLE_DEVICE_OFF_BODY -> "fora do pulso"
                    else -> "procurando…"
                }
            }

            override fun onDataReceived(data: DataPointContainer) {
                val now = System.currentTimeMillis()
                data.getData(DataType.HEART_RATE_BPM).forEach { if (it.value >= 25) Pulse.register(now, it.value.toInt()) }
            }
        }
        cliente.registerMeasureCallback(DataType.HEART_RATE_BPM, cb)
        onDispose {
            runCatching { cliente.unregisterMeasureCallbackAsync(DataType.HEART_RATE_BPM, cb) }
            if (!Pulse.serviceActive.value) {
                Pulse.bpm.value = null
                Pulse.status.value = null
            }
        }
    }
}

/**
 * Body page: live heartbeat with its zone, chart of the last 5 min, average/min/max, time in
 * each zone, workout calories and the day totals. [active] = page on screen (only measures there).
 */
@Composable
fun BodyScreen(active: Boolean, activityOk: Boolean, askActivity: () -> Unit) {
    val context = LocalContext.current
    // measures on its own with the page on screen, like Samsung Health; permissions are asked once
    var sensorOk by remember { mutableStateOf(Pulse.authorized(context)) }
    var pediu by remember { mutableStateOf(false) }
    val askBackground = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { Passive.register(context) }
    val askSensor = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        sensorOk = ok
        if (ok) Passive.backgroundPermission?.let { if (!Passive.backgroundAuthorized(context)) askBackground.launch(it) }
    }
    LaunchedEffect(active) {
        if (active && !sensorOk && !pediu) {
            pediu = true
            askSensor.launch(Pulse.permission)
        }
    }
    val measure = active && sensorOk
    SpotMeasurement(measure)
    Pulse.version.intValue // rereads on every heartbeat
    val est = Pulse.statistics
    val bpm = Pulse.bpm.value ?: Pulse.lastBpm.value?.first
    val workout = Pulse.serviceActive.value
    val off = MaterialTheme.colorScheme.onSurfaceVariant

    List { spec ->
        item {
            Column(
                Modifier.fillMaxWidth().transformedHeight(this, spec),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                val zone = bpm?.let { est.zone(it) }
                val color = zone?.let { Mark.zones[it] } ?: MaterialTheme.colorScheme.primary
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Heart(bpm, 22.dp, color)
                    AnimatedContent(
                        bpm,
                        transitionSpec = {
                            (slideInVertically { -it / 2 } + fadeIn()) togetherWith (slideOutVertically { it / 2 } + fadeOut())
                        },
                        label = "bpm",
                    ) { v ->
                        Text(v?.toString() ?: "--", fontSize = 40.sp, fontWeight = FontWeight.Bold)
                    }
                    Text("bpm", fontSize = 12.sp, color = off, modifier = Modifier.padding(top = 14.dp))
                }
                Text(
                    when {
                        Pulse.status.value == "fora do pulso" -> "Relógio fora do pulso"
                        zone != null -> "Zona ${zone + 1} · ${Mark.zoneNames[zone]} · ${(est.intensidade(bpm) * 100).toInt()}%"
                        workout || measure -> "Procurando o pulso…"
                        else -> "Batimentos e estatísticas"
                    },
                    fontSize = 11.sp, color = if (zone != null) color else off, textAlign = TextAlign.Center,
                )
            }
        }
        if (!sensorOk) {
            item {
                Button(
                    onClick = { askSensor.launch(Pulse.permission) },
                    modifier = Modifier.fillMaxWidth().transformedHeight(this, spec),
                    transformation = SurfaceTransformation(spec),
                    icon = { Icon(Symbol.PLAY, 20.dp) },
                    label = { Text("Permitir batimentos") },
                )
            }
        }
        if (est.readings > 1) {
            item {
                Graphic(est, Modifier.fillMaxWidth().height(70.dp).transformedHeight(this, spec))
            }
            item {
                Row(
                    Modifier.fillMaxWidth().transformedHeight(this, spec),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Block("Média", est.average?.toString() ?: "--", Modifier.weight(1f))
                    Block("Mín", est.minimum?.toString() ?: "--", Modifier.weight(1f))
                    Block("Máx", est.maximum?.toString() ?: "--", Modifier.weight(1f))
                }
            }
            item { Zones(est, Modifier.fillMaxWidth().transformedHeight(this, spec)) }
        }
        Pulse.calories.value?.let { kcal ->
            item {
                Block("Calorias do treino", "${kcal.toInt()} kcal", Modifier.fillMaxWidth().transformedHeight(this, spec))
            }
        }
        item {
            Column(
                Modifier.fillMaxWidth().transformedHeight(this, spec).clip(RoundedCornerShape(22.dp))
                    .background(MaterialTheme.colorScheme.surfaceContainer).padding(12.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text("Hoje", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.primary)
                if (!activityOk) {
                    Button(
                        onClick = askActivity, modifier = Modifier.fillMaxWidth(),
                        colors = ButtonDefaults.filledTonalButtonColors(),
                        label = { Text("Permitir passos e calorias", fontSize = 12.sp) },
                    )
                } else {
                    Line("Passos", Pulse.steps.value?.let { "%,d".format(it).replace(',', '.') })
                    Line("Calorias", Pulse.dailyCalories.value?.let { "${it.toInt()} kcal" })
                    Line("Distância", Pulse.dailyDistance.value?.let { "%.2f km".format(it / 1000).replace('.', ',') })
                    Line("Andares", Pulse.dailyFloors.value?.let { "${it.toInt()}" })
                }
            }
        }
    }
}

@Composable
private fun Line(label: String, value: String?) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value ?: "…", fontSize = 13.sp, fontWeight = FontWeight.Bold)
    }
}

/** Highlighted number with a small label below, in a rounded block. */
@Composable
fun Block(label: String, value: String, modifier: Modifier = Modifier, color: Color = MaterialTheme.colorScheme.onSurface) {
    Column(
        modifier.clip(RoundedCornerShape(16.dp)).background(MaterialTheme.colorScheme.surfaceContainer).padding(vertical = 6.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(value, fontSize = 15.sp, fontWeight = FontWeight.Bold, color = color, maxLines = 1)
        Text(label, fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
    }
}

/** Line of recent heartbeats, colored by zone, with a soft fill below. */
@Composable
private fun Graphic(est: Statistics, modifier: Modifier) {
    val points = est.recent.toList()
    Canvas(modifier.clip(RoundedCornerShape(16.dp)).background(MaterialTheme.colorScheme.surfaceContainer).padding(8.dp)) {
        if (points.size < 2) return@Canvas
        val t0 = points.first().first
        val dt = (points.last().first - t0).coerceAtLeast(1)
        val lo = (points.minOf { it.second } - 5).toFloat()
        val hi = (points.maxOf { it.second } + 5).toFloat()
        fun xy(p: Pair<Long, Int>) = Offset(
            (p.first - t0) / dt.toFloat() * size.width,
            size.height - (p.second - lo) / (hi - lo) * size.height,
        )
        val line = Path().apply {
            moveTo(xy(points[0]).x, xy(points[0]).y)
            points.drop(1).forEach { lineTo(xy(it).x, xy(it).y) }
        }
        val area = Path().apply {
            addPath(line)
            lineTo(size.width, size.height)
            lineTo(0f, size.height)
            close()
        }
        // vertical gradient by zone: the top of the chart with the color of the highest zone seen
        val colors = (est.zone(hi.toInt()) downTo est.zone(lo.toInt())).map { Mark.zones[it] }
        val pincel = if (colors.size > 1) Brush.verticalGradient(colors) else Brush.verticalGradient(listOf(colors[0], colors[0]))
        drawPath(area, Brush.verticalGradient(listOf(colors[0].copy(alpha = 0.35f), Color.Transparent)))
        drawPath(line, pincel, style = Stroke(2.5.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
        drawCircle(colors[0], 3.dp.toPx(), xy(points.last()))
    }
}

/** Stacked bar with the time in each zone and the legend of the ones that had time. */
@Composable
private fun Zones(est: Statistics, modifier: Modifier) {
    val total = est.zonesMs.sum().coerceAtLeast(1)
    Column(modifier, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(Modifier.fillMaxWidth().height(10.dp).clip(RoundedCornerShape(5.dp))) {
            est.zonesMs.forEachIndexed { i, ms ->
                if (ms > 0) Box(Modifier.weight(ms.toFloat()).height(10.dp).background(Mark.zones[i]))
            }
            if (est.zonesMs.sum() == 0L) Box(Modifier.weight(1f).height(10.dp).background(MaterialTheme.colorScheme.surfaceContainerHigh))
        }
        est.zonesMs.withIndex().reversed().filter { it.value > 0 }.forEach { (i, ms) ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Box(Modifier.size(8.dp).clip(RoundedCornerShape(4.dp)).background(Mark.zones[i]))
                Text(Mark.zoneNames[i], fontSize = 11.sp, modifier = Modifier.weight(1f))
                Text("${watch((ms / 1000).toInt())} · ${ms * 100 / total}%", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}
