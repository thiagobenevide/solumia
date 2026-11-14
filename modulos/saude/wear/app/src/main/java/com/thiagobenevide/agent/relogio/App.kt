package com.thiagobenevide.agent.relogio

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

/** Páginas do relógio, nesta ordem, trocadas deslizando para os lados (como no player de música). */
private val paginas = listOf("inicio", "treino", "corpo", "cobrador", "agenda", "alertas")

/**
 * Telas do relógio (Galaxy Watch 7: tela redonda de 432/480 px): Início, Treino (painel de player),
 * Corpo (sensores), Cobrador (voz), Agenda e Alertas, lado a lado. [telaInicial] vem da notificação.
 */
@Composable
fun App(api: Api?, telaInicial: String?, telaAcesa: (Boolean) -> Unit) {
    TemaAgent {
        AppScaffold {
            if (api == null) {
                Column(Modifier.fillMaxSize().padding(24.dp), Arrangement.Center, Alignment.CenterHorizontally) {
                    LogoAgent(48.dp)
                    Text("Configure pelo PC:\nmodulos/saude/wear/instalar", textAlign = TextAlign.Center, fontSize = 12.sp)
                }
                return@AppScaffold
            }
            PulsoDoTreino()
            val contexto = LocalContext.current
            val pager = rememberPagerState { paginas.size }
            val escopo = rememberCoroutineScope()
            var atividadeOk by remember { mutableStateOf(Pulso.atividadeAutorizada(contexto)) }
            val pedirAtividade = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { atividadeOk = it }
            SensoresDoDia(atividadeOk)
            LaunchedEffect(telaInicial) {
                val i = paginas.indexOf(telaInicial)
                if (i >= 0) pager.scrollToPage(i)
            }
            LaunchedEffect(Unit) { Volume.ler(contexto) }
            Box(Modifier.fillMaxSize()) {
                HorizontalPagerScaffold(pagerState = pager) {
                    // todas as páginas ficam vivas: a conversa do cobrador e o treino não se perdem ao deslizar
                    HorizontalPager(state = pager, beyondViewportPageCount = paginas.size - 1) { i ->
                        AnimatedPage(i, pager) {
                            when (paginas[i]) {
                                "inicio" -> Inicio(api, atividadeOk) { destino ->
                                    val alvo = paginas.indexOf(destino)
                                    if (alvo >= 0) escopo.launch { pager.animateScrollToPage(alvo) }
                                }
                                "treino" -> TreinoTela(api, pager.currentPage == i, telaAcesa)
                                "corpo" -> CorpoTela(pager.currentPage == i, atividadeOk) { pedirAtividade.launch(Pulso.ATIVIDADE) }
                                "cobrador" -> CobradorTela(api)
                                "agenda" -> AgendaTela(api)
                                else -> AlertasTela(api)
                            }
                        }
                    }
                }
                NivelDoVolume()
                AtualizacaoTela(api)
                var atualizado by remember { mutableStateOf(Atualizacao.recemAtualizado(contexto)) }
                AnimatedVisibility(atualizado != null, enter = fadeIn(), exit = fadeOut()) {
                    atualizado?.let { Atualizado(it) { atualizado = null } }
                }
            }
        }
    }
}

/**
 * Lista centralizada do Wear (como as telas de treino da Samsung): o item do meio fica inteiro e os
 * das bordas encolhem e somem ao rolar com o dedo ou a coroa. [botaoBorda] = botão curvo na base.
 */
@Composable
fun Lista(
    estado: TransformingLazyColumnState = rememberTransformingLazyColumnState(),
    botaoBorda: (@Composable BoxScope.() -> Unit)? = null,
    conteudo: TransformingLazyColumnScope.(TransformationSpec) -> Unit,
) {
    val spec = rememberTransformationSpec()
    if (botaoBorda != null) {
        ScreenScaffold(scrollState = estado, edgeButton = botaoBorda) { espaco ->
            TransformingLazyColumn(state = estado, contentPadding = espaco) { conteudo(spec) }
        }
    } else {
        ScreenScaffold(scrollState = estado) { espaco ->
            TransformingLazyColumn(state = estado, contentPadding = espaco) { conteudo(spec) }
        }
    }
}

/** Nível do volume na borda esquerda, por 2 s depois de cada ajuste (coroa ou botões). */
@Composable
private fun NivelDoVolume() {
    val mudou = Volume.mudouEm.longValue
    var visivel by remember { mutableStateOf(false) }
    LaunchedEffect(mudou) {
        if (mudou == 0L) return@LaunchedEffect
        visivel = true
        delay(2000)
        visivel = false
    }
    val nivel by animateFloatAsState(Volume.nivel.floatValue, tween(180), label = "volume")
    val cor = MaterialTheme.colorScheme.primary
    val trilho = MaterialTheme.colorScheme.surfaceContainerHigh
    AnimatedVisibility(visivel, enter = fadeIn(), exit = fadeOut()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            // arco de 100° colado na borda esquerda da tela redonda, enchendo de baixo para cima
            Canvas(Modifier.fillMaxSize().padding(5.dp)) {
                val traco = 6.dp.toPx()
                val inicio = 130f
                val varredura = 100f
                val estilo = Stroke(traco, cap = androidx.compose.ui.graphics.StrokeCap.Round)
                val canto = Offset(traco / 2, traco / 2)
                val tamanho = androidx.compose.ui.geometry.Size(size.width - traco, size.height - traco)
                drawArc(trilho, inicio, varredura, false, canto, tamanho, style = estilo)
                if (nivel > 0f) drawArc(cor, inicio, varredura * nivel, false, canto, tamanho, style = estilo)
            }
            Row(
                Modifier.clip(RoundedCornerShape(50)).background(Color.Black.copy(alpha = 0.85f))
                    .padding(horizontal = 14.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Icone(if (nivel <= 0.001f) Simbolo.VOZ_MUDA else Simbolo.VOLUME_MAIS, 18.dp)
                Text("${(Volume.nivel.floatValue * 100).roundToInt()}%", fontSize = 18.sp, fontWeight = FontWeight.Bold)
            }
        }
    }
}

/**
 * Liga o [TreinoServico] (batimentos e descanso em segundo plano) enquanto houver treino em andamento;
 * pede a permissão do sensor na primeira vez.
 */
@Composable
private fun PulsoDoTreino() {
    val contexto = LocalContext.current
    val id = Pulso.sessaoAtiva.value
    var negado by remember { mutableStateOf(false) }
    val pedir = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        negado = !ok
        if (ok) Pulso.sessaoAtiva.value?.let { Pulso.ligar(contexto, it) }
    }
    LaunchedEffect(id) {
        when {
            id == null -> Pulso.desligar(contexto)
            Pulso.autorizado(contexto) -> Pulso.ligar(contexto, id)
            !negado -> pedir.launch(Pulso.permissao)
        }
    }
}

@Composable
private fun Inicio(api: Api, atividadeOk: Boolean, ir: (String) -> Unit) {
    var disciplina by remember { mutableStateOf<JSONObject?>(null) }
    var treino by remember { mutableStateOf<Sessao?>(null) }
    val contexto = LocalContext.current
    val novoBuild = Atualizacao.novoBuild.value
    // Repete: o app fica aberto em segundo plano por dias e não veria uma publicação posterior.
    LaunchedEffect(Unit) {
        while (true) {
            runCatching { Atualizacao.novoBuild.value = Atualizacao.novaVersao(contexto, api) }
            delay(10 * 60_000L)
        }
    }
    LaunchedEffect(Unit) {
        while (true) {
            runCatching { disciplina = api.disciplina() }
            runCatching {
                treino = api.ativa()
                Pulso.atualizar(treino)
            }
            delay(30_000)
        }
    }
    val d = disciplina
    val alertas = d?.optJSONArray("alertas")?.length() ?: 0
    val atual = d?.optJSONObject("bloco_atual")
    val apagado = MaterialTheme.colorScheme.onSurfaceVariant
    val bpm = Pulso.bpm.value ?: Pulso.ultimoBpm.value?.first // ao vivo, senão o último do sensor passivo

    fun atualizar() {
        Atualizacao.etapa.value = Etapa.Oferta
    }

    Lista(
        botaoBorda = if (novoBuild != null) {
            {
                EdgeButton(
                    onClick = ::atualizar,
                    colors = ButtonDefaults.buttonColors(containerColor = Marca.Azul, contentColor = Color.White),
                ) {
                    // ícone girando devagar: chama a atenção sem piscar
                    val giro by rememberInfiniteTransition(label = "atualizar")
                        .animateFloat(0f, 360f, infiniteRepeatable(tween(3000, easing = LinearEasing)), label = "g")
                    Box(Modifier.rotate(giro)) { Icone(Simbolo.ATUALIZAR, 18.dp) }
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
                val indice = d?.opt("indice")?.takeIf { it != JSONObject.NULL }
                Text(
                    if (indice != null) "Disciplina $indice" else "Agent", fontWeight = FontWeight.Bold, fontSize = 16.sp,
                    modifier = Modifier.padding(top = 4.dp),
                )
                Text(
                    atual?.let { "Agora: ${it.getString("titulo")}" } ?: "Deslize para os lados ‹ ›",
                    fontSize = 11.sp, color = apagado, textAlign = TextAlign.Center, maxLines = 2,
                )
            }
        }
        // resumo do dia em três números, como o cartão "Hoje" do Samsung Health
        item {
            Row(Modifier.fillMaxWidth().transformedHeight(this, spec), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Bloco("passos", Pulso.passos.value?.let { compacto(it.toDouble()) } ?: "--", Modifier.weight(1f).clickable { ir("corpo") })
                Bloco("kcal", Pulso.caloriasDia.value?.let { compacto(it) } ?: "--", Modifier.weight(1f).clickable { ir("corpo") })
                Bloco("bpm", bpm?.toString() ?: "--", Modifier.weight(1f).clickable { ir("corpo") }, cor = Marca.zonas[4])
            }
        }
        item {
            Atalho(
                this, spec, Simbolo.HALTER, "Treino",
                if (treino != null) "Em andamento${if (bpm != null) " · ♥$bpm" else ""}" else "Começar o de hoje",
                destaque = treino != null,
            ) { ir("treino") }
        }
        item { Atalho(this, spec, Simbolo.GRAFICO, "Corpo", if (atividadeOk) "Batimentos e estatísticas" else "Sensores e estatísticas") { ir("corpo") } }
        item { Atalho(this, spec, Simbolo.MIC, "Cobrador", "Conversas por voz") { ir("cobrador") } }
        item { Atalho(this, spec, Simbolo.AGENDA, "Agenda", "Blocos de hoje") { ir("agenda") } }
        item {
            Atalho(this, spec, Simbolo.SINO, "Alertas", if (alertas > 0) "$alertas pendente(s)" else "Nada pendente", alerta = alertas > 0) {
                ir("alertas")
            }
        }
    }
}

/** "1,2 mil" a partir de 1000; abaixo, o número inteiro. */
private fun compacto(v: Double): String =
    if (v >= 1000) "%.1f mil".format(v / 1000).replace('.', ',') else v.toInt().toString()

/** Botão de lista com ícone num círculo (gradiente da marca no destaque), título e detalhe. */
@Composable
private fun Atalho(
    escopo: androidx.wear.compose.foundation.lazy.TransformingLazyColumnItemScope,
    spec: TransformationSpec,
    simbolo: Simbolo,
    titulo: String,
    detalhe: String,
    destaque: Boolean = false,
    alerta: Boolean = false,
    aoTocar: () -> Unit,
) {
    Button(
        onClick = aoTocar,
        modifier = Modifier.fillMaxWidth().transformedHeight(escopo, spec),
        transformation = with(escopo) { SurfaceTransformation(spec) },
        colors = if (destaque) ButtonDefaults.filledTonalButtonColors(
            containerColor = MaterialTheme.colorScheme.primaryContainer,
        ) else ButtonDefaults.filledTonalButtonColors(),
        icon = {
            Box(
                Modifier.size(30.dp).clip(CircleShape).background(
                    when {
                        destaque -> Marca.diagonal(80f)
                        alerta -> Brush.linearGradient(listOf(MaterialTheme.colorScheme.error, MaterialTheme.colorScheme.errorDim))
                        else -> Brush.linearGradient(listOf(MaterialTheme.colorScheme.surfaceContainerHigh, MaterialTheme.colorScheme.surfaceContainerHigh))
                    },
                ),
                contentAlignment = Alignment.Center,
            ) { Icone(simbolo, 16.dp, if (destaque || alerta) Color.White else MaterialTheme.colorScheme.primary) }
        },
        secondaryLabel = { Text(detalhe, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        label = { Text(titulo, fontWeight = FontWeight.Bold) },
    )
}

/**
 * Cobrador por voz, em abas de conversa (guardadas no relógio): grava, o worker transcreve, o
 * cobrador responde (e fala, se ligado). A lista de abas cria uma nova ou exclui as antigas.
 */
@Composable
private fun CobradorTela(api: Api) {
    val contexto = LocalContext.current
    val escopo = rememberCoroutineScope()
    val deposito = remember { Conversas(File(contexto.filesDir, "conversas.json")) }
    val conversas = remember { mutableStateListOf<Conversa>().apply { addAll(deposito.ler()) } }
    var atualId by remember { mutableStateOf(conversas.firstOrNull()?.id) }
    var vendoAbas by remember { mutableStateOf(false) }
    val gravador = remember { Gravador() }
    var gravando by remember { mutableStateOf(false) }
    var pensando by remember { mutableStateOf(false) }
    var falando by remember { mutableStateOf(false) }
    var erro by remember { mutableStateOf<String?>(null) }
    var falar by remember { mutableStateOf(Config.falarRespostas(contexto)) }
    var tocador by remember { mutableStateOf<MediaPlayer?>(null) }
    var aviso by remember { mutableStateOf<String?>(null) }
    val filaFala = remember { ArrayDeque<String>() }
    var falaJob by remember { mutableStateOf<Job?>(null) }

    fun salvar() = deposito.gravar(conversas)

    /** Conversa aberta (cria uma se não houver nenhuma). */
    fun atual(): Conversa = conversas.firstOrNull { it.id == atualId } ?: Conversas.nova().also {
        conversas.add(0, it)
        atualId = it.id
    }

    /** Acrescenta uma fala na conversa [id] e a leva para o topo das abas. */
    fun anexar(id: String, fala: Fala) {
        val i = conversas.indexOfFirst { it.id == id }
        if (i < 0) return
        val c = conversas.removeAt(i)
        conversas.add(0, c.copy(falas = c.falas + fala))
        salvar()
    }

    fun parar() {
        filaFala.clear()
        falaJob?.cancel()
        falaJob = null
        tocador?.runCatching { stop(); release() }
        tocador = null
        falando = false
    }

    /** Toca um WAV e só volta quando ele termina (ou a fala é cancelada). */
    suspend fun tocarAteOFim(wav: ByteArray) = suspendCancellableCoroutine { cont ->
        val f = File(contexto.cacheDir, "fala${System.nanoTime()}.wav").apply { writeBytes(wav) }
        val mp = MediaPlayer()
        fun acabou() {
            runCatching { mp.release() }
            f.delete()
            if (tocador === mp) tocador = null
            if (cont.isActive) cont.resume(Unit)
        }
        mp.setOnCompletionListener { acabou() }
        mp.setOnErrorListener { _, _, _ -> acabou(); true }
        cont.invokeOnCancellation { runCatching { mp.stop() }; runCatching { mp.release() }; f.delete() }
        try {
            mp.setDataSource(f.path)
            mp.prepare()
            tocador = mp
            falando = true
            mp.start()
        } catch (e: Exception) {
            acabou()
        }
    }

    /** Fala por trechos: toca o primeiro assim que fica pronto e já pede o seguinte. */
    suspend fun falarEmTrechos(texto: String) = coroutineScope {
        var i = 0
        var proximo = async { runCatching { api.falar(texto, 0) }.getOrNull() }
        while (true) {
            val wav = proximo.await()
            if (wav == null || wav.isEmpty()) break
            i++
            proximo = async { runCatching { api.falar(texto, i) }.getOrNull() }
            tocarAteOFim(wav)
        }
        proximo.cancel()
    }

    /** Põe [texto] na fila da voz: avisos e resposta tocam em ordem, sem um cortar o outro. */
    fun falarDepois(texto: String) {
        if (!falar || texto.isBlank()) return
        filaFala.addLast(texto)
        if (falaJob?.isActive == true) return
        falaJob = escopo.launch {
            try {
                while (filaFala.isNotEmpty()) falarEmTrechos(filaFala.removeFirst())
            } finally {
                falando = false
            }
        }
    }

    fun enviar(wav: ByteArray) {
        val conversa = atual()
        pensando = true
        erro = null
        aviso = null
        escopo.launch {
            try {
                val historico = JSONArray().apply {
                    conversa.falas.takeLast(20).forEach { put(JSONObject().put("papel", it.papel).put("texto", it.texto)) }
                }
                // eventos chegam conforme o servidor anda: fala o "estou consultando…" enquanto espera
                api.vozFluxo(wav, historico).collect { ev ->
                    when (ev.optString("evento")) {
                        "transcricao" -> anexar(conversa.id, Fala("usuario", ev.optString("texto")))
                        "aviso" -> ev.optString("texto").takeIf { it.isNotBlank() }?.let {
                            aviso = it
                            falarDepois(it)
                        }
                        "fim" -> {
                            val resposta = ev.optString("resposta")
                            val feitas = ev.optJSONArray("executadas")
                            val extra = (0 until (feitas?.length() ?: 0)).joinToString("") {
                                "\n• " + feitas!!.getJSONObject(it).optString("detalhe")
                            }
                            anexar(conversa.id, Fala("assistente", resposta + extra))
                            pensando = false
                            aviso = null
                            falarDepois(resposta)
                        }
                        "erro" -> erro = ev.optString("detalhe").ifBlank { "Falha no servidor" }
                    }
                }
            } catch (e: ApiErro) {
                erro = e.message
            } catch (e: org.json.JSONException) {
                erro = "Resposta inválida do servidor"
            } finally {
                pensando = false
                aviso = null
            }
        }
    }

    val permissao = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        if (ok) {
            gravador.iniciar()
            gravando = true
        } else {
            erro = "Sem permissão do microfone"
        }
    }

    fun microfone() {
        if (gravando) {
            gravando = false
            gravador.parar()?.let(::enviar) ?: run { erro = "Áudio curto demais" }
        } else if (ContextCompat.checkSelfPermission(contexto, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            parar()
            erro = null
            gravador.iniciar()
            gravando = true
        } else {
            permissao.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    Box(Modifier.fillMaxSize()) {
        if (vendoAbas) {
            Abas(
                conversas, atualId,
                abrir = {
                    atualId = it
                    vendoAbas = false
                },
                nova = {
                    // reaproveita uma aba vazia em vez de empilhar várias "Nova conversa"
                    val vazia = conversas.firstOrNull { it.falas.isEmpty() }
                    val c = vazia ?: Conversas.nova().also { conversas.add(0, it) }
                    atualId = c.id
                    salvar()
                    vendoAbas = false
                },
                excluir = { id ->
                    conversas.removeAll { it.id == id }
                    if (atualId == id) atualId = conversas.firstOrNull()?.id
                    salvar()
                },
            )
        } else {
            val conversa = conversas.firstOrNull { it.id == atualId }
            val falas = conversa?.falas.orEmpty()
            val estado = rememberTransformingLazyColumnState()
            LaunchedEffect(falas.size, pensando) { if (falas.isNotEmpty()) estado.animateScrollToItem(falas.size + 1) }
            Lista(
                estado = estado,
                botaoBorda = {
                    EdgeButton(
                        onClick = ::microfone,
                        enabled = !pensando,
                        colors = ButtonDefaults.buttonColors(containerColor = Marca.Azul, contentColor = Color.White),
                    ) { Icone(Simbolo.MIC, 22.dp) }
                },
            ) { spec ->
                item {
                    // cabeçalho: título da aba; tocar abre a lista de conversas
                    Row(
                        Modifier.transformedHeight(this, spec).clip(RoundedCornerShape(50))
                            .background(MaterialTheme.colorScheme.surfaceContainer)
                            .clickable { vendoAbas = true }.padding(horizontal = 12.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Icone(Simbolo.LISTA, 14.dp, MaterialTheme.colorScheme.primary)
                        Text(
                            conversa?.titulo ?: "Cobrador", fontSize = 12.sp, fontWeight = FontWeight.Bold,
                            maxLines = 1, overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
                if (falas.isEmpty()) {
                    item {
                        Column(Modifier.fillMaxWidth().transformedHeight(this, spec).padding(top = 8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                            LogoAgent(44.dp, respirar = true)
                            Text(
                                "Toque no microfone e fale.", fontSize = 12.sp,
                                color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center,
                                modifier = Modifier.padding(top = 6.dp),
                            )
                        }
                    }
                }
                items(falas.size) { k -> Balao(falas[k], Modifier.transformedHeight(this, spec).animateItem()) }
                item {
                    Box(Modifier.fillMaxWidth().height(28.dp).transformedHeight(this, spec), contentAlignment = Alignment.Center) {
                        when {
                            pensando && aviso != null -> Text(
                                aviso!!, fontSize = 11.sp, color = MaterialTheme.colorScheme.primary,
                                textAlign = TextAlign.Center, maxLines = 2, overflow = TextOverflow.Ellipsis,
                            )
                            pensando -> Pensando()
                            falando -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Equalizador()
                                Text("Parar", fontSize = 11.sp, color = MaterialTheme.colorScheme.primary, modifier = Modifier.clickable { parar() })
                            }
                            erro != null -> Text(erro!!, fontSize = 11.sp, color = MaterialTheme.colorScheme.error, textAlign = TextAlign.Center)
                        }
                    }
                }
                item {
                    // volume da voz e liga/desliga a resposta falada, como os controles de baixo do player
                    Row(
                        Modifier.transformedHeight(this, spec),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        val apagado = MaterialTheme.colorScheme.onSurfaceVariant
                        IconButton(onClick = { Volume.ajustar(contexto, false) }, modifier = Modifier.size(44.dp)) {
                            Icone(Simbolo.VOLUME_MENOS, 20.dp, apagado)
                        }
                        FilledIconButton(
                            onClick = {
                                falar = !falar
                                Config.definirFalar(contexto, falar)
                                if (!falar) parar()
                            },
                            colors = if (falar) IconButtonDefaults.filledIconButtonColors()
                            else IconButtonDefaults.filledTonalIconButtonColors(),
                            modifier = Modifier.size(44.dp),
                        ) { Icone(if (falar) Simbolo.VOLUME_MAIS else Simbolo.VOZ_MUDA, 20.dp) }
                        IconButton(onClick = { Volume.ajustar(contexto, true) }, modifier = Modifier.size(44.dp)) {
                            Icone(Simbolo.VOLUME_MAIS, 20.dp, apagado)
                        }
                    }
                }
            }
        }
        AnimatedVisibility(gravando, enter = fadeIn() + scaleIn(initialScale = 0.9f), exit = fadeOut() + scaleOut(targetScale = 0.9f)) {
            Gravando(
                nivel = { gravador.nivel },
                enviar = ::microfone,
                cancelar = {
                    gravando = false
                    gravador.parar()
                },
            )
        }
    }
}

/** Balão da conversa: o usuário à direita em gradiente da marca; o cobrador à esquerda, escuro. */
@Composable
private fun Balao(f: Fala, modifier: Modifier) {
    val minha = f.papel == "usuario"
    Box(modifier.fillMaxWidth(), contentAlignment = if (minha) Alignment.CenterEnd else Alignment.CenterStart) {
        Text(
            f.texto,
            fontSize = 13.sp,
            color = if (minha) Color.White else MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.fillMaxWidth(0.88f)
                .clip(RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp, bottomStart = if (minha) 16.dp else 4.dp, bottomEnd = if (minha) 4.dp else 16.dp))
                .background(if (minha) Marca.diagonal(400f) else Brush.linearGradient(List(2) { MaterialTheme.colorScheme.surfaceContainer }))
                .padding(horizontal = 11.dp, vertical = 7.dp),
        )
    }
}

/**
 * Tela cheia de gravação: ondas em volta do microfone que crescem com a voz (lidas do [nivel] a cada
 * quadro), botão grande para enviar e um X para descartar.
 */
@Composable
private fun Gravando(nivel: () -> Float, enviar: () -> Unit, cancelar: () -> Unit) {
    var suave by remember { mutableFloatStateOf(0f) }
    LaunchedEffect(Unit) {
        while (true) {
            suave += (nivel() - suave) * 0.35f
            delay(40)
        }
    }
    val t = rememberInfiniteTransition(label = "ondas")
    val onda by t.animateFloat(0f, 1f, infiniteRepeatable(tween(1600, easing = LinearEasing), RepeatMode.Restart), label = "o")
    val segundos = remember { System.currentTimeMillis() }
    var passados by remember { mutableStateOf(0) }
    LaunchedEffect(Unit) {
        while (true) {
            passados = ((System.currentTimeMillis() - segundos) / 1000).toInt()
            delay(250)
        }
    }
    val respiro by animateFloatAsState(1f + suave * 0.25f, tween(80, easing = FastOutSlowInEasing), label = "r")
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.94f)), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            val c = Offset(size.width / 2, size.height / 2)
            val base = 46.dp.toPx()
            for (k in 0 until 3) {
                val f = (onda + k / 3f) % 1f
                drawCircle(
                    Marca.diagonal(size.width), base * respiro + f * (size.minDimension / 2 - base) * (0.5f + suave),
                    c, alpha = (1f - f) * 0.5f, style = Stroke(3.dp.toPx()),
                )
            }
            drawCircle(Marca.diagonal(size.width), base * respiro, c, alpha = 0.25f)
        }
        Text(
            relogio(passados), fontSize = 13.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.error,
            modifier = Modifier.align(Alignment.TopCenter).padding(top = 30.dp),
        )
        FilledIconButton(
            onClick = enviar,
            colors = IconButtonDefaults.filledIconButtonColors(containerColor = Marca.Azul, contentColor = Color.White),
            modifier = Modifier.size(72.dp),
        ) { Icone(Simbolo.CHECK, 32.dp) }
        Column(Modifier.align(Alignment.BottomCenter).padding(bottom = 18.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            IconButton(onClick = cancelar, modifier = Modifier.size(44.dp)) {
                Icone(Simbolo.FECHAR, 18.dp, MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Text("Toque ✓ para enviar", fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** Lista das abas de conversa: nova no topo; a lixeira pede um segundo toque para excluir. */
@Composable
private fun Abas(
    conversas: List<Conversa>,
    atualId: String?,
    abrir: (String) -> Unit,
    nova: () -> Unit,
    excluir: (String) -> Unit,
) {
    var confirmar by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(confirmar) {
        if (confirmar != null) {
            delay(3000)
            confirmar = null
        }
    }
    val hora = remember { DateTimeFormatter.ofPattern("dd/MM HH:mm") }
    Lista(
        botaoBorda = {
            EdgeButton(onClick = nova, colors = ButtonDefaults.buttonColors(containerColor = Marca.Azul, contentColor = Color.White)) {
                Icone(Simbolo.MAIS, 18.dp)
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
            val aberta = c.id == atualId
            val pedindo = confirmar == c.id
            Row(
                Modifier.fillMaxWidth().transformedHeight(this, spec).animateItem(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Button(
                    onClick = { abrir(c.id) },
                    modifier = Modifier.weight(1f),
                    transformation = SurfaceTransformation(spec),
                    colors = if (aberta) ButtonDefaults.filledTonalButtonColors(containerColor = MaterialTheme.colorScheme.primaryContainer)
                    else ButtonDefaults.filledTonalButtonColors(),
                    secondaryLabel = {
                        Text(
                            "${c.falas.size / 2} msg · " + hora.format(Instant.ofEpochMilli(c.criadaMs).atZone(ZoneId.systemDefault())),
                            maxLines = 1,
                        )
                    },
                    label = { Text(c.titulo, maxLines = 1, overflow = TextOverflow.Ellipsis, fontSize = 13.sp) },
                )
                FilledIconButton(
                    onClick = { if (pedindo) excluir(c.id) else confirmar = c.id },
                    colors = if (pedindo) IconButtonDefaults.filledIconButtonColors(containerColor = MaterialTheme.colorScheme.error)
                    else IconButtonDefaults.filledTonalIconButtonColors(),
                    modifier = Modifier.size(40.dp),
                ) { Icone(Simbolo.LIXO, 18.dp, if (pedindo) Color.White else MaterialTheme.colorScheme.onSurfaceVariant) }
            }
        }
        if (confirmar != null) {
            item {
                Text(
                    "Toque de novo para excluir", fontSize = 11.sp, color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.transformedHeight(this, spec),
                )
            }
        }
    }
}

/** Blocos de hoje com o progresso do dia; tocar marca (ou desmarca) como feito. */
@Composable
private fun AgendaTela(api: Api) {
    val escopo = rememberCoroutineScope()
    val dia = remember { LocalDate.now().toString() }
    var blocos by remember { mutableStateOf<List<JSONObject>?>(null) }
    var erro by remember { mutableStateOf<String?>(null) }

    suspend fun carregar() {
        try {
            val l = api.agenda(dia).getJSONArray("blocos")
            blocos = (0 until l.length()).map { l.getJSONObject(it) }
            erro = null
        } catch (e: ApiErro) {
            erro = e.message
        }
    }
    LaunchedEffect(Unit) { carregar() }

    val l = blocos
    val feitos = l?.count { it.optBoolean("feito") } ?: 0
    val agora = LocalTime.now().toString().take(5)
    // bloco da vez: o último que já começou e não foi feito
    val daVez = l?.lastOrNull { !it.optBoolean("feito") && it.optString("inicio") <= agora }?.optString("id")
    Lista { spec ->
        item {
            Column(Modifier.fillMaxWidth().transformedHeight(this, spec), horizontalAlignment = Alignment.CenterHorizontally) {
                Box(contentAlignment = Alignment.Center) {
                    val p by animateFloatAsState(if (l.isNullOrEmpty()) 0f else feitos / l.size.toFloat(), tween(700), label = "dia")
                    AnelProgresso(p, Modifier.size(52.dp), 5.dp)
                    Text("$feitos/${l?.size ?: 0}", fontSize = 12.sp, fontWeight = FontWeight.Bold)
                }
                Text("Agenda de hoje", fontWeight = FontWeight.Bold, fontSize = 14.sp, modifier = Modifier.padding(top = 4.dp))
            }
        }
        erro?.let { item { Text(it, fontSize = 11.sp, color = MaterialTheme.colorScheme.error, modifier = Modifier.transformedHeight(this, spec)) } }
        if (l == null && erro == null) item { Pensando() }
        if (l != null && l.isEmpty()) item { Text("Sem blocos hoje", fontSize = 12.sp, modifier = Modifier.transformedHeight(this, spec)) }
        items(l?.size ?: 0) { k ->
            val b = l!![k]
            val feito = b.optBoolean("feito")
            val vez = b.optString("id") == daVez
            Button(
                onClick = {
                    escopo.launch {
                        runCatching { api.marcarBloco(dia, b.getString("id"), !feito) }
                        carregar()
                    }
                },
                modifier = Modifier.fillMaxWidth().transformedHeight(this, spec),
                transformation = SurfaceTransformation(spec),
                colors = when {
                    vez -> ButtonDefaults.buttonColors()
                    feito -> ButtonDefaults.filledTonalButtonColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)
                    else -> ButtonDefaults.filledTonalButtonColors()
                },
                icon = {
                    Box(
                        Modifier.size(24.dp).clip(CircleShape).background(
                            if (feito) Marca.zonas[2] else MaterialTheme.colorScheme.surfaceContainerHigh,
                        ),
                        contentAlignment = Alignment.Center,
                    ) { if (feito) Icone(Simbolo.CHECK, 14.dp, Color.Black) }
                },
                secondaryLabel = { Text(b.getString("inicio") + if (vez) " · agora" else "", maxLines = 1) },
                label = {
                    Text(
                        b.getString("titulo"), maxLines = 2, overflow = TextOverflow.Ellipsis,
                        color = if (feito) MaterialTheme.colorScheme.onSurfaceVariant else Color.Unspecified,
                    )
                },
            )
        }
    }
}

@Composable
private fun AlertasTela(api: Api) {
    var alertas by remember { mutableStateOf<List<JSONObject>?>(null) }
    var erro by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        try {
            val l = api.disciplina().getJSONArray("alertas")
            alertas = (0 until l.length()).map { l.getJSONObject(it) }
        } catch (e: ApiErro) {
            erro = e.message
        }
    }
    val l = alertas
    Lista { spec ->
        item {
            ListHeader(Modifier.transformedHeight(this, spec), transformation = SurfaceTransformation(spec)) {
                Icone(Simbolo.SINO, 14.dp, MaterialTheme.colorScheme.primary)
                Text("Alertas", fontWeight = FontWeight.Bold, modifier = Modifier.padding(start = 6.dp))
            }
        }
        erro?.let { item { Text(it, fontSize = 11.sp, color = MaterialTheme.colorScheme.error, modifier = Modifier.transformedHeight(this, spec)) } }
        if (l == null && erro == null) item { Pensando() }
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
            val cor = if (critico) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.secondary
            Row(
                Modifier.fillMaxWidth().transformedHeight(this, spec).clip(RoundedCornerShape(18.dp))
                    .background(MaterialTheme.colorScheme.surfaceContainer).padding(10.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Box(Modifier.size(width = 4.dp, height = 34.dp).clip(RoundedCornerShape(2.dp)).background(cor))
                Text(a.getString("texto"), fontSize = 12.sp, color = if (critico) cor else MaterialTheme.colorScheme.onSurface)
            }
        }
    }
}
