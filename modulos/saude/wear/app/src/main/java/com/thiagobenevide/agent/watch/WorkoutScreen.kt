package com.thiagobenevide.agent.watch

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.wear.compose.material3.ButtonDefaults
import androidx.wear.compose.material3.IconButtonDefaults
import android.os.VibrationEffect
import android.os.Vibrator
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.compose.material3.Button
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.Text
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.rotary.onRotaryScrollEvent
import androidx.wear.compose.material3.FilledIconButton
import androidx.wear.compose.material3.IconButton
import kotlin.math.abs
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Workout guide on the wrist: the same session as the phone, reread every 3 s; [active] = page on screen. */
@Composable
fun WorkoutScreen(api: Api, active: Boolean, screenOn: (Boolean) -> Unit) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var session by remember { mutableStateOf<Session?>(null) }
    var carregou by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var reps by remember { mutableIntStateOf(10) }
    var seriesKey by remember { mutableStateOf("") }
    var warned by remember { mutableStateOf<Long?>(null) }
    var photoOpen by remember { mutableStateOf(false) }

    fun set(s: Session?) {
        session = s
        carregou = true
        error = null
        val key = "${s?.id}:${s?.index}:${s?.current?.doneSteps}"
        if (key != seriesKey) {
            seriesKey = key
            reps = s?.current?.repsIniciais ?: 10
        }
        screenOn(s?.state == "andamento")
        Pulse.update(s)
    }

    fun act(block: suspend () -> Session?) {
        if (busy) return
        busy = true
        scope.launch {
            try {
                set(block())
            } catch (e: ApiError) {
                error = e.message
            } finally {
                busy = false
            }
        }
    }

    fun cmd(action: String, data: Map<String, Any?> = emptyMap()) {
        val s = session ?: return
        act { api.command(s.id, action, data) }
    }

    DisposableEffect(Unit) { onDispose { screenOn(false) } }
    // rereads every 3 s: picks up what was done on the phone
    LaunchedEffect(Unit) {
        while (true) {
            if (!busy) {
                try {
                    set(api.active())
                } catch (e: ApiError) {
                    if (!carregou) error = e.message
                }
            }
            delay(3000)
        }
    }
    // screen clock and vibration at the end of the rest
    LaunchedEffect(Unit) {
        while (true) {
            now = System.currentTimeMillis()
            val s = session
            val until = s?.restUntilMs
            // with the service running, it is the one that vibrates (works with the screen off)
            if (!Pulse.serviceActive.value && s != null && !s.paused && until != null && s.remaining(now) == 0 && warned != until) {
                warned = until
                context.getSystemService(Vibrator::class.java)?.vibrate(
                    VibrationEffect.createWaveform(longArrayOf(0, 400, 150, 400), -1),
                )
            }
            delay(500)
        }
    }

    val s = session
    // crown = volume (like the music player); focus comes when this page is on screen
    val focus = remember { FocusRequester() }
    var spin by remember { mutableFloatStateOf(0f) }
    LaunchedEffect(active) { if (active) runCatching { focus.requestFocus() } }
    Box(
        Modifier.fillMaxSize()
            .onRotaryScrollEvent {
                spin += it.verticalScrollPixels
                if (abs(spin) >= 48f) {
                    Volume.adjust(context, spin > 0)
                    spin = 0f
                }
                true
            }
            .focusRequester(focus)
            .focusable(),
    ) {
        when {
            error != null && s == null -> Action(error!!, "Tentar de novo") { act { api.active() } }
            !carregou -> Message("Carregando…")
            s == null -> Action("Nenhum treino em andamento", "Treinar hoje") { act { api.begin() } }
            s.state == "concluida" -> Message("Treino concluído\n${s.seriesDone} séries")
            s.phase(now) == "fim" || s.current == null ->
                Action("Tudo feito!\n${watch(s.activeS(now))}", "Concluir") { act { api.finish(s.id) } }
            photoOpen && s.current != null -> ExercisePhoto(api, s.current!!) { photoOpen = false }
            else -> Player(s, now, reps, { reps = (reps + it).coerceAtLeast(0) }, ::cmd, { photoOpen = true }) {
                val e = s.current!!
                if (e.goalTime != null) cmd("concluir_serie", mapOf("tempo_s" to s.seriesTime(now)))
                else cmd("concluir_serie", mapOf("repeticoes" to reps))
            }
        }
        if (error != null && s != null) {
            Text(
                error!!, fontSize = 10.sp, color = MaterialTheme.colorScheme.error,
                modifier = Modifier.align(Alignment.BottomCenter).padding(8.dp),
            )
        }
    }
}

@Composable
fun Message(text: String) {
    Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
        Text(text, textAlign = TextAlign.Center)
    }
}

@Composable
fun Action(text: String, button: String, onTap: () -> Unit) {
    Column(
        Modifier.fillMaxSize().padding(20.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        LogoAgent(40.dp)
        Text(text, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 8.dp))
        Button(
            onClick = onTap, modifier = Modifier.padding(top = 10.dp),
            colors = ButtonDefaults.buttonColors(containerColor = Mark.Azul, contentColor = Color.White),
            label = { Text(button) },
        )
    }
}

/**
 * Music-player style panel: progress ring on the edge (rest or workout sets),
 * ⏮ undoes the set, the center button marks the set (during rest, skips), ⏭ skips the exercise (during
 * rest, +30 s); below, the wide pause/resume button. The crown adjusts the volume.
 */
@Composable
private fun Player(
    s: Session, now: Long, reps: Int, adjust: (Int) -> Unit,
    cmd: (String, Map<String, Any?>) -> Unit, openPhoto: () -> Unit, feita: () -> Unit,
) {
    val e = s.current!!
    val rest = s.phase(now) == "descanso"
    val remaining = s.remaining(now) ?: 0
    val target = when {
        rest -> remaining / maxOf(s.restS, remaining).coerceAtLeast(1).toFloat()
        e.goalTime != null -> (s.seriesTime(now) / e.goalTime.coerceAtLeast(1).toFloat()).coerceIn(0f, 1f)
        else -> s.seriesDone / s.plannedSeries.coerceAtLeast(1).toFloat()
    }
    val progress by animateFloatAsState(target, tween(600), label = "anel")
    val off = MaterialTheme.colorScheme.onSurfaceVariant
    val bpm = Pulse.bpm.value
    val zone = bpm?.let { Pulse.statistics.zone(it) }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        ProgressRing(
            progress, Modifier.fillMaxSize().padding(2.dp), 7.dp,
            color = when {
                s.paused -> MaterialTheme.colorScheme.outline
                rest -> MaterialTheme.colorScheme.tertiary
                else -> null
            },
        )
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
            modifier = Modifier.padding(horizontal = 22.dp, vertical = 14.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    when {
                        s.paused -> "PAUSADO"
                        rest -> "DESCANSO"
                        else -> watch(s.activeS(now))
                    },
                    fontSize = 11.sp, fontWeight = FontWeight.Bold,
                    color = when {
                        s.paused -> off
                        rest -> MaterialTheme.colorScheme.tertiary
                        else -> MaterialTheme.colorScheme.primary
                    },
                )
                if (bpm != null || Pulse.status.value != null) {
                    Heart(bpm, 11.dp, zone?.let { Mark.zones[it] } ?: off)
                    Text(
                        if (Pulse.status.value == "fora do pulso") "fora" else bpm?.toString() ?: "…",
                        fontSize = 11.sp, fontWeight = FontWeight.Bold, color = zone?.let { Mark.zones[it] } ?: off,
                    )
                }
            }
            AnimatedContent(
                (if (rest) "A seguir: " else "") + e.name,
                transitionSpec = { (slideInHorizontally { it / 3 } + fadeIn()) togetherWith (slideOutHorizontally { -it / 3 } + fadeOut()) },
                label = "nome",
            ) { name ->
                // tap on the name: photo of the movement and how to do it
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                    modifier = Modifier.clickable(onClick = openPhoto),
                ) {
                    Icon(Symbol.HALTER, 13.dp, MaterialTheme.colorScheme.primary)
                    Text(
                        name, fontWeight = FontWeight.Bold, fontSize = 15.sp,
                        textAlign = TextAlign.Center, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            Text(
                "Série ${e.doneSteps + 1} de ${e.planned} · ${load(e.load)}", fontSize = 11.sp, color = off,
                maxLines = 1,
            )
            when {
                rest -> Number(watch(remaining), 34)
                e.goalTime != null -> Number("${watch(s.seriesTime(now))} / ${watch(e.goalTime)}", 22)
                else -> Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = { adjust(-1) }, modifier = Modifier.size(36.dp)) {
                        Icon(Symbol.MINUS, 16.dp, off)
                    }
                    Box(Modifier.padding(horizontal = 4.dp)) { Number("$reps", 32) }
                    IconButton(onClick = { adjust(1) }, modifier = Modifier.size(36.dp)) {
                        Icon(Symbol.PLUS, 16.dp, off)
                    }
                }
            }
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                FilledIconButton(
                    onClick = { cmd("desfazer_serie", emptyMap()) },
                    colors = IconButtonDefaults.filledTonalIconButtonColors(),
                    modifier = Modifier.size(44.dp),
                ) { Icon(Symbol.PREVIOUS, 18.dp) }
                val central by animateFloatAsState(if (s.paused) 0.9f else 1f, label = "central")
                FilledIconButton(
                    onClick = {
                        when {
                            s.paused -> cmd("continuar", emptyMap())
                            rest -> cmd("pular_descanso", emptyMap())
                            else -> feita()
                        }
                    },
                    colors = IconButtonDefaults.filledIconButtonColors(containerColor = Mark.Azul, contentColor = Color.White),
                    modifier = Modifier.size(60.dp).scale(central),
                ) {
                    Icon(
                        when {
                            s.paused -> Symbol.PLAY
                            rest -> Symbol.NEXT
                            else -> Symbol.CHECK
                        },
                        28.dp,
                    )
                }
                if (rest) {
                    FilledIconButton(
                        onClick = { cmd("somar_descanso", mapOf("segundos" to 30)) },
                        colors = IconButtonDefaults.filledTonalIconButtonColors(),
                        modifier = Modifier.size(44.dp),
                    ) { Text("+30", fontSize = 12.sp, fontWeight = FontWeight.Bold) }
                } else {
                    FilledIconButton(
                        onClick = { cmd("pular_exercicio", emptyMap()) },
                        colors = IconButtonDefaults.filledTonalIconButtonColors(),
                        modifier = Modifier.size(44.dp),
                    ) { Icon(Symbol.NEXT, 18.dp) }
                }
            }
            // wide and tall pause: easy to hit with a sweaty finger in the middle of the workout
            Button(
                onClick = { cmd(if (s.paused) "continuar" else "pausar", emptyMap()) },
                colors = if (s.paused) ButtonDefaults.buttonColors(containerColor = Mark.Roxo, contentColor = Color.White)
                else ButtonDefaults.filledTonalButtonColors(),
                modifier = Modifier.padding(top = 6.dp).size(width = 116.dp, height = 44.dp),
                contentPadding = PaddingValues(horizontal = 10.dp),
                icon = { Icon(if (s.paused) Symbol.PLAY else Symbol.PAUSE, 16.dp) },
                label = { Text(if (s.paused) "Continuar" else "Pausar", fontSize = 13.sp, fontWeight = FontWeight.Bold) },
            )
        }
    }
}

/** Big number that slides up when it changes (reps, stopwatch). */
@Composable
private fun Number(text: String, sizeDp: Int) {
    AnimatedContent(
        text,
        transitionSpec = { (slideInVertically { -it / 3 } + fadeIn(tween(160))) togetherWith (slideOutVertically { it / 3 } + fadeOut(tween(120))) },
        label = "numero",
    ) { t -> Text(t, fontSize = sizeDp.sp, fontWeight = FontWeight.Bold) }
}
