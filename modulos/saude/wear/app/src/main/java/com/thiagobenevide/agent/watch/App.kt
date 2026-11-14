package com.thiagobenevide.agent.watch

import android.Manifest
import android.content.pm.PackageManager
import android.media.MediaPlayer
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.wear.compose.foundation.lazy.TransformingLazyColumn
import androidx.wear.compose.foundation.lazy.TransformingLazyColumnScope
import androidx.wear.compose.foundation.lazy.TransformingLazyColumnState
import androidx.wear.compose.foundation.lazy.rememberTransformingLazyColumnState
import androidx.wear.compose.foundation.pager.HorizontalPager
import androidx.wear.compose.foundation.pager.rememberPagerState
import androidx.wear.compose.material3.AnimatedPage
import androidx.wear.compose.material3.AppScaffold
import androidx.wear.compose.material3.Button
import androidx.wear.compose.material3.ButtonDefaults
import androidx.wear.compose.material3.EdgeButton
import androidx.wear.compose.material3.FilledIconButton
import androidx.wear.compose.material3.HorizontalPagerScaffold
import androidx.wear.compose.material3.IconButton
import androidx.wear.compose.material3.IconButtonDefaults
import androidx.wear.compose.material3.ListHeader
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.ScreenScaffold
import androidx.wear.compose.material3.SurfaceTransformation
import androidx.wear.compose.material3.Text
import androidx.wear.compose.material3.lazy.TransformationSpec
import androidx.wear.compose.material3.lazy.rememberTransformationSpec
import androidx.wear.compose.material3.lazy.transformedHeight
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.math.roundToInt
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/** Watch pages, in this order, switched by swiping sideways (like the music player). */
private val pages = listOf("inicio", "treino", "corpo", "cobrador", "agenda", "alertas")

/**
 * Watch screens (Galaxy Watch 7: round 432/480 px screen): Home, Workout (player panel),
 * Body (sensors), Coach (voice), Agenda and Alerts, side by side. [homeScreen] comes from the notification.
 */
@Composable
fun App(api: Api?, homeScreen: String?, screenOn: (Boolean) -> Unit) {
    TemaAgent {
        AppScaffold {
            if (api == null) {
                Column(Modifier.fillMaxSize().padding(24.dp), Arrangement.Center, Alignment.CenterHorizontally) {
                    LogoAgent(48.dp)
                    Text("Configure pelo PC:\nmodulos/saude/wear/instalar", textAlign = TextAlign.Center, fontSize = 12.sp)
                }
                return@AppScaffold
            }
            WorkoutPulse()
            val context = LocalContext.current
            val pager = rememberPagerState { pages.size }
            val scope = rememberCoroutineScope()
            var activityOk by remember { mutableStateOf(Pulse.activityAuthorized(context)) }
            val askActivity = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { activityOk = it }
            DailySensors(activityOk)
            LaunchedEffect(homeScreen) {
                val i = pages.indexOf(homeScreen)
                if (i >= 0) pager.scrollToPage(i)
            }
            LaunchedEffect(Unit) { Volume.read(context) }
            Box(Modifier.fillMaxSize()) {
                HorizontalPagerScaffold(pagerState = pager) {
                    // every page stays alive: the coach conversation and the workout are not lost when swiping
                    HorizontalPager(state = pager, beyondViewportPageCount = pages.size - 1) { i ->
                        AnimatedPage(i, pager) {
                            when (pages[i]) {
                                "inicio" -> Start(api, activityOk) { destination ->
                                    val target = pages.indexOf(destination)
                                    if (target >= 0) scope.launch { pager.animateScrollToPage(target) }
                                }
                                "treino" -> WorkoutScreen(api, pager.currentPage == i, screenOn)
                                "corpo" -> BodyScreen(pager.currentPage == i, activityOk) { askActivity.launch(Pulse.ACTIVITY) }
                                "cobrador" -> CoachScreen(api)
                                "agenda" -> AgendaScreen(api)
                                else -> AlertsScreen(api)
                            }
                        }
                    }
                }
                VolumeLevel()
                UpdateScreen(api)
                var updated by remember { mutableStateOf(Update.justUpdated(context)) }
                AnimatedVisibility(updated != null, enter = fadeIn(), exit = fadeOut()) {
                    updated?.let { Updated(it) { updated = null } }
                }
            }
        }
    }
}

/**
 * Centered Wear list (like Samsung's workout screens): the middle item stays whole and the
 * edge ones shrink and fade when scrolling with the finger or the crown. [edgeButton] = curved button at the bottom.
 */
@Composable
fun List(
    state: TransformingLazyColumnState = rememberTransformingLazyColumnState(),
    edgeButton: (@Composable BoxScope.() -> Unit)? = null,
    content: TransformingLazyColumnScope.(TransformationSpec) -> Unit,
) {
    val spec = rememberTransformationSpec()
    if (edgeButton != null) {
        ScreenScaffold(scrollState = state, edgeButton = edgeButton) { espaco ->
            TransformingLazyColumn(state = state, contentPadding = espaco) { content(spec) }
        }
    } else {
        ScreenScaffold(scrollState = state) { espaco ->
            TransformingLazyColumn(state = state, contentPadding = espaco) { content(spec) }
        }
    }
}

/** Volume level on the left edge, for 2 s after each adjustment (crown or buttons). */
@Composable
private fun VolumeLevel() {
    val mudou = Volume.changedAt.longValue
    var visivel by remember { mutableStateOf(false) }
    LaunchedEffect(mudou) {
        if (mudou == 0L) return@LaunchedEffect
        visivel = true
        delay(2000)
        visivel = false
    }
    val level by animateFloatAsState(Volume.level.floatValue, tween(180), label = "volume")
    val color = MaterialTheme.colorScheme.primary
    val track = MaterialTheme.colorScheme.surfaceContainerHigh
    AnimatedVisibility(visivel, enter = fadeIn(), exit = fadeOut()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            // 100° arc stuck to the left edge of the round screen, filling from bottom to top
            Canvas(Modifier.fillMaxSize().padding(5.dp)) {
                val traco = 6.dp.toPx()
                val start = 130f
                val varredura = 100f
                val style = Stroke(traco, cap = androidx.compose.ui.graphics.StrokeCap.Round)
                val canto = Offset(traco / 2, traco / 2)
                val sizeDp = androidx.compose.ui.geometry.Size(size.width - traco, size.height - traco)
                drawArc(track, start, varredura, false, canto, sizeDp, style = style)
                if (level > 0f) drawArc(color, start, varredura * level, false, canto, sizeDp, style = style)
            }
            Row(
                Modifier.clip(RoundedCornerShape(50)).background(Color.Black.copy(alpha = 0.85f))
                    .padding(horizontal = 14.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Icon(if (level <= 0.001f) Symbol.VOICE_MUTE else Symbol.VOLUME_PLUS, 18.dp)
                Text("${(Volume.level.floatValue * 100).roundToInt()}%", fontSize = 18.sp, fontWeight = FontWeight.Bold)
            }
        }
    }
}

/**
 * Starts the [WorkoutService] (heartbeats and rest in the background) while a workout is in progress;
 * asks for the sensor permission the first time.
 */
@Composable
private fun WorkoutPulse() {
    val context = LocalContext.current
    val id = Pulse.activeSession.value
    var denied by remember { mutableStateOf(false) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        denied = !ok
        if (ok) Pulse.activeSession.value?.let { Pulse.enable(context, it) }
    }
    LaunchedEffect(id) {
        when {
            id == null -> Pulse.turnOff(context)
            Pulse.authorized(context) -> Pulse.enable(context, id)
            !denied -> ask.launch(Pulse.permission)
        }
    }
}

@Composable
private fun Start(api: Api, activityOk: Boolean, ir: (String) -> Unit) {
    var subject by remember { mutableStateOf<JSONObject?>(null) }
    var workout by remember { mutableStateOf<Session?>(null) }
    val context = LocalContext.current
    val newBuild = Update.newBuild.value
    // Repeats: the app stays open in the background for days and would not see a later publication.
    LaunchedEffect(Unit) {
        while (true) {
            runCatching { Update.newBuild.value = Update.newVersion(context, api) }
            delay(10 * 60_000L)
        }
    }
    LaunchedEffect(Unit) {
        while (true) {
            runCatching { subject = api.subject() }
            runCatching {
                workout = api.active()
                Pulse.update(workout)
            }
            delay(30_000)
        }
    }
    val d = subject
    val alerts = d?.optJSONArray("alertas")?.length() ?: 0
    val current = d?.optJSONObject("bloco_atual")
    val off = MaterialTheme.colorScheme.onSurfaceVariant
    val bpm = Pulse.bpm.value ?: Pulse.lastBpm.value?.first // live, otherwise the last one from the passive sensor

    fun update() {
        Update.stage.value = Stage.Oferta
    }

    List(
        edgeButton = if (newBuild != null) {
            {
                EdgeButton(
                    onClick = ::update,
                    colors = ButtonDefaults.buttonColors(containerColor = Mark.Azul, contentColor = Color.White),
                ) {
                    // icon spinning slowly: draws attention without blinking
                    val spin by rememberInfiniteTransition(label = "atualizar")
                        .animateFloat(0f, 360f, infiniteRepeatable(tween(3000, easing = LinearEasing)), label = "g")
                    Box(Modifier.rotate(spin)) { Icon(Symbol.UPDATE, 18.dp) }
                    Text("Atualizar", fontSize = 12.sp, modifier = Modifier.padding(start = 6.dp))
                }
            }
        } else {
            null
        },
    ) { spec ->
        item {
            Column(Modifier.fillMaxWidth().transformedHeight(this, spec), horizontalAlignment = Alignment.CenterHorizontally) {
                LogoAgent(40.dp)
                val index = d?.opt("indice")?.takeIf { it != JSONObject.NULL }
                Text(
                    if (index != null) "Disciplina $index" else "Solumia", fontWeight = FontWeight.Bold, fontSize = 16.sp,
                    modifier = Modifier.padding(top = 4.dp),
                )
                Text(
                    current?.let { "Agora: ${it.getString("titulo")}" } ?: "Deslize para os lados ‹ ›",
                    fontSize = 11.sp, color = off, textAlign = TextAlign.Center, maxLines = 2,
                )
            }
        }
        // summary of the day in three numbers, like the Samsung Health "Today" card
        item {
            Row(Modifier.fillMaxWidth().transformedHeight(this, spec), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Block("passos", Pulse.steps.value?.let { compact(it.toDouble()) } ?: "--", Modifier.weight(1f).clickable { ir("corpo") })
                Block("kcal", Pulse.dailyCalories.value?.let { compact(it) } ?: "--", Modifier.weight(1f).clickable { ir("corpo") })
                Block("bpm", bpm?.toString() ?: "--", Modifier.weight(1f).clickable { ir("corpo") }, color = Mark.zones[4])
            }
        }
        item {
            Shortcut(
                this, spec, Symbol.HALTER, "Treino",
                if (workout != null) "Em andamento${if (bpm != null) " · ♥$bpm" else ""}" else "Começar o de hoje",
                highlight = workout != null,
            ) { ir("treino") }
        }
        item { Shortcut(this, spec, Symbol.GRAPHIC, "Corpo", if (activityOk) "Batimentos e estatísticas" else "Sensores e estatísticas") { ir("corpo") } }
        item { Shortcut(this, spec, Symbol.MIC, "Cobrador", "Conversas por voz") { ir("cobrador") } }
        item { Shortcut(this, spec, Symbol.AGENDA, "Agenda", "Blocos de hoje") { ir("agenda") } }
        item {
            Shortcut(this, spec, Symbol.SINO, "Alertas", if (alerts > 0) "$alerts pendente(s)" else "Nada pendente", alert = alerts > 0) {
                ir("alertas")
            }
        }
    }
}

/** "1,2 mil" from 1000 on; below that, the whole number. */
private fun compact(v: Double): String =
    if (v >= 1000) "%.1f mil".format(v / 1000).replace('.', ',') else v.toInt().toString()

/** List button with an icon in a circle (brand gradient when highlighted), title and detail. */
@Composable
private fun Shortcut(
    scope: androidx.wear.compose.foundation.lazy.TransformingLazyColumnItemScope,
    spec: TransformationSpec,
    symbol: Symbol,
    title: String,
    detail: String,
    highlight: Boolean = false,
    alert: Boolean = false,
    onTap: () -> Unit,
) {
    Button(
        onClick = onTap,
        modifier = Modifier.fillMaxWidth().transformedHeight(scope, spec),
        transformation = with(scope) { SurfaceTransformation(spec) },
        colors = if (highlight) ButtonDefaults.filledTonalButtonColors(
            containerColor = MaterialTheme.colorScheme.primaryContainer,
        ) else ButtonDefaults.filledTonalButtonColors(),
        icon = {
            Box(
                Modifier.size(30.dp).clip(CircleShape).background(
                    when {
                        highlight -> Mark.diagonal(80f)
                        alert -> Brush.linearGradient(listOf(MaterialTheme.colorScheme.error, MaterialTheme.colorScheme.errorDim))
                        else -> Brush.linearGradient(listOf(MaterialTheme.colorScheme.surfaceContainerHigh, MaterialTheme.colorScheme.surfaceContainerHigh))
                    },
                ),
                contentAlignment = Alignment.Center,
            ) { Icon(symbol, 16.dp, if (highlight || alert) Color.White else MaterialTheme.colorScheme.primary) }
        },
        secondaryLabel = { Text(detail, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        label = { Text(title, fontWeight = FontWeight.Bold) },
    )
}

/**
 * Voice coach, in conversation tabs (kept on the watch): records, the worker transcribes, the
 * coach answers (and speaks, if on). The tab list creates a new one or deletes old ones.
 */
@Composable
private fun CoachScreen(api: Api) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val deposito = remember { Conversas(File(context.filesDir, "conversas.json")) }
    val conversas = remember { mutableStateListOf<Conversation>().apply { addAll(deposito.read()) } }
    var currentId by remember { mutableStateOf(conversas.firstOrNull()?.id) }
    var viewingTabs by remember { mutableStateOf(false) }
    val recorder = remember { Recorder() }
    var gravando by remember { mutableStateOf(false) }
    var thinking by remember { mutableStateOf(false) }
    var falando by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var speak by remember { mutableStateOf(Config.speakAnswers(context)) }
    var player by remember { mutableStateOf<MediaPlayer?>(null) }
    var warning by remember { mutableStateOf<String?>(null) }
    val speechQueue = remember { ArrayDeque<String>() }
    var speechJob by remember { mutableStateOf<Job?>(null) }

    fun save() = deposito.record(conversas)

    /** Open conversation (creates one if there is none). */
    fun current(): Conversation = conversas.firstOrNull { it.id == currentId } ?: Conversas.fresh().also {
        conversas.add(0, it)
        currentId = it.id
    }

    /** Appends a speech to conversation [id] and moves it to the top of the tabs. */
    fun attach(id: String, speech: Speech) {
        val i = conversas.indexOfFirst { it.id == id }
        if (i < 0) return
        val c = conversas.removeAt(i)
        conversas.add(0, c.copy(speeches = c.speeches + speech))
        save()
    }

    fun stop() {
        speechQueue.clear()
        speechJob?.cancel()
        speechJob = null
        player?.runCatching { stop(); release() }
        player = null
        falando = false
    }

    /** Plays a WAV and only returns when it ends (or the speech is cancelled). */
    suspend fun playToTheEnd(wav: ByteArray) = suspendCancellableCoroutine { cont ->
        val f = File(context.cacheDir, "fala${System.nanoTime()}.wav").apply { writeBytes(wav) }
        val mp = MediaPlayer()
        fun acabou() {
            runCatching { mp.release() }
            f.delete()
            if (player === mp) player = null
            if (cont.isActive) cont.resume(Unit)
        }
        mp.setOnCompletionListener { acabou() }
        mp.setOnErrorListener { _, _, _ -> acabou(); true }
        cont.invokeOnCancellation { runCatching { mp.stop() }; runCatching { mp.release() }; f.delete() }
        try {
            mp.setDataSource(f.path)
            mp.prepare()
            player = mp
            falando = true
            mp.start()
        } catch (e: Exception) {
            acabou()
        }
    }

    /** Speaks in chunks: plays the first as soon as it is ready and already asks for the next. */
    suspend fun speakInSpans(text: String) = coroutineScope {
        var i = 0
        var next = async { runCatching { api.speak(text, 0) }.getOrNull() }
        while (true) {
            val wav = next.await()
            if (wav == null || wav.isEmpty()) break
            i++
            next = async { runCatching { api.speak(text, i) }.getOrNull() }
            playToTheEnd(wav)
        }
        next.cancel()
    }

    /** Puts [text] in the voice queue: warnings and answer play in order, without one cutting the other. */
    fun speakAfter(text: String) {
        if (!speak || text.isBlank()) return
        speechQueue.addLast(text)
        if (speechJob?.isActive == true) return
        speechJob = scope.launch {
            try {
                while (speechQueue.isNotEmpty()) speakInSpans(speechQueue.removeFirst())
            } finally {
                falando = false
            }
        }
    }

    fun send(wav: ByteArray) {
        val conversation = current()
        thinking = true
        error = null
        warning = null
        scope.launch {
            try {
                val history = JSONArray().apply {
                    conversation.speeches.takeLast(20).forEach { put(JSONObject().put("papel", it.role).put("texto", it.text)) }
                }
                // eventos chegam conforme o servidor anda: fala o "estou consultando…" enquanto espera
                api.voiceFlow(wav, history).collect { ev ->
                    when (ev.optString("evento")) {
                        "transcricao" -> attach(conversation.id, Speech("usuario", ev.optString("texto")))
                        "aviso" -> ev.optString("texto").takeIf { it.isNotBlank() }?.let {
                            warning = it
                            speakAfter(it)
                        }
                        "fim" -> {
                            val answer = ev.optString("resposta")
                            val doneSteps = ev.optJSONArray("executadas")
                            val extra = (0 until (doneSteps?.length() ?: 0)).joinToString("") {
                                "\n• " + doneSteps!!.getJSONObject(it).optString("detalhe")
                            }
                            attach(conversation.id, Speech("assistente", answer + extra))
                            thinking = false
                            warning = null
                            speakAfter(answer)
                        }
                        "erro" -> error = ev.optString("detalhe").ifBlank { "Falha no servidor" }
                    }
                }
            } catch (e: ApiError) {
                error = e.message
            } catch (e: org.json.JSONException) {
                error = "Resposta inválida do servidor"
            } finally {
                thinking = false
                warning = null
            }
        }
    }

    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        if (ok) {
            recorder.begin()
            gravando = true
        } else {
            error = "Sem permissão do microfone"
        }
    }

    fun microfone() {
        if (gravando) {
            gravando = false
            recorder.stop()?.let(::send) ?: run { error = "Áudio curto demais" }
        } else if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            stop()
            error = null
            recorder.begin()
            gravando = true
        } else {
            permission.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    Box(Modifier.fillMaxSize()) {
        if (viewingTabs) {
            Tabs(
                conversas, currentId,
                open = {
                    currentId = it
                    viewingTabs = false
                },
                fresh = {
                    // reuses an empty tab instead of stacking several "Nova conversa"
                    val empty = conversas.firstOrNull { it.speeches.isEmpty() }
                    val c = empty ?: Conversas.fresh().also { conversas.add(0, it) }
                    currentId = c.id
                    save()
                    viewingTabs = false
                },
                delete = { id ->
                    conversas.removeAll { it.id == id }
                    if (currentId == id) currentId = conversas.firstOrNull()?.id
                    save()
                },
            )
        } else {
            val conversation = conversas.firstOrNull { it.id == currentId }
            val speeches = conversation?.speeches.orEmpty()
            val state = rememberTransformingLazyColumnState()
            LaunchedEffect(speeches.size, thinking) { if (speeches.isNotEmpty()) state.animateScrollToItem(speeches.size + 1) }
            List(
                state = state,
                edgeButton = {
                    EdgeButton(
                        onClick = ::microfone,
                        enabled = !thinking,
                        colors = ButtonDefaults.buttonColors(containerColor = Mark.Azul, contentColor = Color.White),
                    ) { Icon(Symbol.MIC, 22.dp) }
                },
            ) { spec ->
                item {
                    // header: tab title; tapping opens the conversation list
                    Row(
                        Modifier.transformedHeight(this, spec).clip(RoundedCornerShape(50))
                            .background(MaterialTheme.colorScheme.surfaceContainer)
                            .clickable { viewingTabs = true }.padding(horizontal = 12.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Icon(Symbol.LIST, 14.dp, MaterialTheme.colorScheme.primary)
                        Text(
                            conversation?.title ?: "Cobrador", fontSize = 12.sp, fontWeight = FontWeight.Bold,
                            maxLines = 1, overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
                if (speeches.isEmpty()) {
                    item {
                        Column(Modifier.fillMaxWidth().transformedHeight(this, spec).padding(top = 8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                            LogoAgent(44.dp, breathe = true)
                            Text(
                                "Toque no microfone e fale.", fontSize = 12.sp,
                                color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center,
                                modifier = Modifier.padding(top = 6.dp),
                            )
                        }
                    }
                }
                items(speeches.size) { k -> Balao(speeches[k], Modifier.transformedHeight(this, spec).animateItem()) }
                item {
                    Box(Modifier.fillMaxWidth().height(28.dp).transformedHeight(this, spec), contentAlignment = Alignment.Center) {
                        when {
                            thinking && warning != null -> Text(
                                warning!!, fontSize = 11.sp, color = MaterialTheme.colorScheme.primary,
                                textAlign = TextAlign.Center, maxLines = 2, overflow = TextOverflow.Ellipsis,
                            )
                            thinking -> Thinking()
                            falando -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Equalizer()
                                Text("Parar", fontSize = 11.sp, color = MaterialTheme.colorScheme.primary, modifier = Modifier.clickable { stop() })
                            }
                            error != null -> Text(error!!, fontSize = 11.sp, color = MaterialTheme.colorScheme.error, textAlign = TextAlign.Center)
                        }
                    }
                }
                item {
                    // voice volume and spoken answer on/off, like the player's bottom controls
                    Row(
                        Modifier.transformedHeight(this, spec),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        val off = MaterialTheme.colorScheme.onSurfaceVariant
                        IconButton(onClick = { Volume.adjust(context, false) }, modifier = Modifier.size(44.dp)) {
                            Icon(Symbol.VOLUME_MINUS, 20.dp, off)
                        }
                        FilledIconButton(
                            onClick = {
                                speak = !speak
                                Config.setSpeak(context, speak)
                                if (!speak) stop()
                            },
                            colors = if (speak) IconButtonDefaults.filledIconButtonColors()
                            else IconButtonDefaults.filledTonalIconButtonColors(),
                            modifier = Modifier.size(44.dp),
                        ) { Icon(if (speak) Symbol.VOLUME_PLUS else Symbol.VOICE_MUTE, 20.dp) }
                        IconButton(onClick = { Volume.adjust(context, true) }, modifier = Modifier.size(44.dp)) {
                            Icon(Symbol.VOLUME_PLUS, 20.dp, off)
                        }
                    }
                }
            }
        }
        AnimatedVisibility(gravando, enter = fadeIn() + scaleIn(initialScale = 0.9f), exit = fadeOut() + scaleOut(targetScale = 0.9f)) {
            Gravando(
                level = { recorder.level },
                send = ::microfone,
                cancel = {
                    gravando = false
                    recorder.stop()
                },
            )
        }
    }
}

/** Conversation bubble: the user on the right in brand gradient; the coach on the left, dark. */
@Composable
private fun Balao(f: Speech, modifier: Modifier) {
    val mine = f.role == "usuario"
    Box(modifier.fillMaxWidth(), contentAlignment = if (mine) Alignment.CenterEnd else Alignment.CenterStart) {
        Text(
            f.text,
            fontSize = 13.sp,
            color = if (mine) Color.White else MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.fillMaxWidth(0.88f)
                .clip(RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp, bottomStart = if (mine) 16.dp else 4.dp, bottomEnd = if (mine) 4.dp else 16.dp))
                .background(if (mine) Mark.diagonal(400f) else Brush.linearGradient(List(2) { MaterialTheme.colorScheme.surfaceContainer }))
                .padding(horizontal = 11.dp, vertical = 7.dp),
        )
    }
}

/**
 * Full-screen recording: waves around the microphone that grow with the voice (read from [level] every
 * frame), a big button to send and an X to discard.
 */
@Composable
private fun Gravando(level: () -> Float, send: () -> Unit, cancel: () -> Unit) {
    var suave by remember { mutableFloatStateOf(0f) }
    LaunchedEffect(Unit) {
        while (true) {
            suave += (level() - suave) * 0.35f
            delay(40)
        }
    }
    val t = rememberInfiniteTransition(label = "ondas")
    val onda by t.animateFloat(0f, 1f, infiniteRepeatable(tween(1600, easing = LinearEasing), RepeatMode.Restart), label = "o")
    val seconds = remember { System.currentTimeMillis() }
    var past by remember { mutableStateOf(0) }
    LaunchedEffect(Unit) {
        while (true) {
            past = ((System.currentTimeMillis() - seconds) / 1000).toInt()
            delay(250)
        }
    }
    val breath by animateFloatAsState(1f + suave * 0.25f, tween(80, easing = FastOutSlowInEasing), label = "r")
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.94f)), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            val c = Offset(size.width / 2, size.height / 2)
            val base = 46.dp.toPx()
            for (k in 0 until 3) {
                val f = (onda + k / 3f) % 1f
                drawCircle(
                    Mark.diagonal(size.width), base * breath + f * (size.minDimension / 2 - base) * (0.5f + suave),
                    c, alpha = (1f - f) * 0.5f, style = Stroke(3.dp.toPx()),
                )
            }
            drawCircle(Mark.diagonal(size.width), base * breath, c, alpha = 0.25f)
        }
        Text(
            watch(past), fontSize = 13.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.error,
            modifier = Modifier.align(Alignment.TopCenter).padding(top = 30.dp),
        )
        FilledIconButton(
            onClick = send,
            colors = IconButtonDefaults.filledIconButtonColors(containerColor = Mark.Azul, contentColor = Color.White),
            modifier = Modifier.size(72.dp),
        ) { Icon(Symbol.CHECK, 32.dp) }
        Column(Modifier.align(Alignment.BottomCenter).padding(bottom = 18.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            IconButton(onClick = cancel, modifier = Modifier.size(44.dp)) {
                Icon(Symbol.CLOSE, 18.dp, MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Text("Toque ✓ para enviar", fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** List of conversation tabs: new one on top; the trash asks for a second tap to delete. */
@Composable
private fun Tabs(
    conversas: List<Conversation>,
    currentId: String?,
    open: (String) -> Unit,
    fresh: () -> Unit,
    delete: (String) -> Unit,
) {
    var confirm by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(confirm) {
        if (confirm != null) {
            delay(3000)
            confirm = null
        }
    }
    val hour = remember { DateTimeFormatter.ofPattern("dd/MM HH:mm") }
    List(
        edgeButton = {
            EdgeButton(onClick = fresh, colors = ButtonDefaults.buttonColors(containerColor = Mark.Azul, contentColor = Color.White)) {
                Icon(Symbol.PLUS, 18.dp)
            }
        },
    ) { spec ->
        item {
            ListHeader(Modifier.transformedHeight(this, spec), transformation = SurfaceTransformation(spec)) {
                Text("Conversas", fontWeight = FontWeight.Bold)
            }
        }
        if (conversas.isEmpty()) {
            item {
                Text(
                    "Nenhuma conversa ainda.", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.transformedHeight(this, spec),
                )
            }
        }
        items(conversas.size, key = { conversas[it].id }) { k ->
            val c = conversas[k]
            val open = c.id == currentId
            val pedindo = confirm == c.id
            Row(
                Modifier.fillMaxWidth().transformedHeight(this, spec).animateItem(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Button(
                    onClick = { open(c.id) },
                    modifier = Modifier.weight(1f),
                    transformation = SurfaceTransformation(spec),
                    colors = if (open) ButtonDefaults.filledTonalButtonColors(containerColor = MaterialTheme.colorScheme.primaryContainer)
                    else ButtonDefaults.filledTonalButtonColors(),
                    secondaryLabel = {
                        Text(
                            "${c.speeches.size / 2} msg · " + hour.format(Instant.ofEpochMilli(c.createdMs).atZone(ZoneId.systemDefault())),
                            maxLines = 1,
                        )
                    },
                    label = { Text(c.title, maxLines = 1, overflow = TextOverflow.Ellipsis, fontSize = 13.sp) },
                )
                FilledIconButton(
                    onClick = { if (pedindo) delete(c.id) else confirm = c.id },
                    colors = if (pedindo) IconButtonDefaults.filledIconButtonColors(containerColor = MaterialTheme.colorScheme.error)
                    else IconButtonDefaults.filledTonalIconButtonColors(),
                    modifier = Modifier.size(40.dp),
                ) { Icon(Symbol.LIXO, 18.dp, if (pedindo) Color.White else MaterialTheme.colorScheme.onSurfaceVariant) }
            }
        }
        if (confirm != null) {
            item {
                Text(
                    "Toque de novo para excluir", fontSize = 11.sp, color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.transformedHeight(this, spec),
                )
            }
        }
    }
}

/** Today's blocks with the day's progress; tapping marks (or unmarks) as done. */
@Composable
private fun AgendaScreen(api: Api) {
    val scope = rememberCoroutineScope()
    val day = remember { LocalDate.now().toString() }
    var blocks by remember { mutableStateOf<List<JSONObject>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }

    suspend fun load() {
        try {
            val l = api.agenda(day).getJSONArray("blocos")
            blocks = (0 until l.length()).map { l.getJSONObject(it) }
            error = null
        } catch (e: ApiError) {
            error = e.message
        }
    }
    LaunchedEffect(Unit) { load() }

    val l = blocks
    val doneCount = l?.count { it.optBoolean("feito") } ?: 0
    val now = LocalTime.now().toString().take(5)
    // current block: the last one that already started and is not done
    val turn = l?.lastOrNull { !it.optBoolean("feito") && it.optString("inicio") <= now }?.optString("id")
    List { spec ->
        item {
            Column(Modifier.fillMaxWidth().transformedHeight(this, spec), horizontalAlignment = Alignment.CenterHorizontally) {
                Box(contentAlignment = Alignment.Center) {
                    val p by animateFloatAsState(if (l.isNullOrEmpty()) 0f else doneCount / l.size.toFloat(), tween(700), label = "dia")
                    ProgressRing(p, Modifier.size(52.dp), 5.dp)
                    Text("$doneCount/${l?.size ?: 0}", fontSize = 12.sp, fontWeight = FontWeight.Bold)
                }
                Text("Agenda de hoje", fontWeight = FontWeight.Bold, fontSize = 14.sp, modifier = Modifier.padding(top = 4.dp))
            }
        }
        error?.let { item { Text(it, fontSize = 11.sp, color = MaterialTheme.colorScheme.error, modifier = Modifier.transformedHeight(this, spec)) } }
        if (l == null && error == null) item { Thinking() }
        if (l != null && l.isEmpty()) item { Text("Sem blocos hoje", fontSize = 12.sp, modifier = Modifier.transformedHeight(this, spec)) }
        items(l?.size ?: 0) { k ->
            val b = l!![k]
            val done = b.optBoolean("feito")
            val vez = b.optString("id") == turn
            Button(
                onClick = {
                    scope.launch {
                        runCatching { api.markBlock(day, b.getString("id"), !done) }
                        load()
                    }
                },
                modifier = Modifier.fillMaxWidth().transformedHeight(this, spec),
                transformation = SurfaceTransformation(spec),
                colors = when {
                    vez -> ButtonDefaults.buttonColors()
                    done -> ButtonDefaults.filledTonalButtonColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)
                    else -> ButtonDefaults.filledTonalButtonColors()
                },
                icon = {
                    Box(
                        Modifier.size(24.dp).clip(CircleShape).background(
                            if (done) Mark.zones[2] else MaterialTheme.colorScheme.surfaceContainerHigh,
                        ),
                        contentAlignment = Alignment.Center,
                    ) { if (done) Icon(Symbol.CHECK, 14.dp, Color.Black) }
                },
                secondaryLabel = { Text(b.getString("inicio") + if (vez) " · agora" else "", maxLines = 1) },
                label = {
                    Text(
                        b.getString("titulo"), maxLines = 2, overflow = TextOverflow.Ellipsis,
                        color = if (done) MaterialTheme.colorScheme.onSurfaceVariant else Color.Unspecified,
                    )
                },
            )
        }
    }
}

@Composable
private fun AlertsScreen(api: Api) {
    var alerts by remember { mutableStateOf<List<JSONObject>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        try {
            val l = api.subject().getJSONArray("alertas")
            alerts = (0 until l.length()).map { l.getJSONObject(it) }
        } catch (e: ApiError) {
            error = e.message
        }
    }
    val l = alerts
    List { spec ->
        item {
            ListHeader(Modifier.transformedHeight(this, spec), transformation = SurfaceTransformation(spec)) {
                Icon(Symbol.SINO, 14.dp, MaterialTheme.colorScheme.primary)
                Text("Alertas", fontWeight = FontWeight.Bold, modifier = Modifier.padding(start = 6.dp))
            }
        }
        error?.let { item { Text(it, fontSize = 11.sp, color = MaterialTheme.colorScheme.error, modifier = Modifier.transformedHeight(this, spec)) } }
        if (l == null && error == null) item { Thinking() }
        if (l != null && l.isEmpty()) {
            item {
                Column(Modifier.fillMaxWidth().transformedHeight(this, spec), horizontalAlignment = Alignment.CenterHorizontally) {
                    LogoAgent(36.dp)
                    Text("Nada pendente.\nSegue o plano.", fontSize = 12.sp, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 6.dp))
                }
            }
        }
        items(l?.size ?: 0) { k ->
            val a = l!![k]
            val critico = a.optString("nivel") == "critico"
            val color = if (critico) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.secondary
            Row(
                Modifier.fillMaxWidth().transformedHeight(this, spec).clip(RoundedCornerShape(18.dp))
                    .background(MaterialTheme.colorScheme.surfaceContainer).padding(10.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Box(Modifier.size(width = 4.dp, height = 34.dp).clip(RoundedCornerShape(2.dp)).background(color))
                Text(a.getString("texto"), fontSize = 12.sp, color = if (critico) color else MaterialTheme.colorScheme.onSurface)
            }
        }
    }
}
