package com.thiagobenevide.agent.relogio

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

/** Guia do treino no pulso: a mesma sessão do celular, relida a cada 3 s; [ativa] = página na tela. */
@Composable
fun TreinoTela(api: Api, ativa: Boolean, telaAcesa: (Boolean) -> Unit) {
    val escopo = rememberCoroutineScope()
    val contexto = LocalContext.current
    var sessao by remember { mutableStateOf<Sessao?>(null) }
    var carregou by remember { mutableStateOf(false) }
    var erro by remember { mutableStateOf<String?>(null) }
    var ocupado by remember { mutableStateOf(false) }
    var agora by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var reps by remember { mutableIntStateOf(10) }
    var chaveSerie by remember { mutableStateOf("") }
    var avisado by remember { mutableStateOf<Long?>(null) }

    fun definir(s: Sessao?) {
        sessao = s
        carregou = true
        erro = null
        val chave = "${s?.id}:${s?.indice}:${s?.atual?.feitas}"
        if (chave != chaveSerie) {
            chaveSerie = chave
            reps = s?.atual?.repsIniciais ?: 10
        }
        telaAcesa(s?.estado == "andamento")
        Pulso.atualizar(s)
    }

    fun agir(bloco: suspend () -> Sessao?) {
        if (ocupado) return
        ocupado = true
        escopo.launch {
            try {
                definir(bloco())
            } catch (e: ApiErro) {
                erro = e.message
            } finally {
                ocupado = false
            }
        }
    }

    fun cmd(acao: String, dados: Map<String, Any?> = emptyMap()) {
        val s = sessao ?: return
        agir { api.comando(s.id, acao, dados) }
    }

    DisposableEffect(Unit) { onDispose { telaAcesa(false) } }
    // relê a cada 3 s: pega o que foi feito no celular
    LaunchedEffect(Unit) {
        while (true) {
            if (!ocupado) {
                try {
                    definir(api.ativa())
                } catch (e: ApiErro) {
                    if (!carregou) erro = e.message
                }
            }
            delay(3000)
        }
    }
    // relógio da tela e vibração no fim do descanso
    LaunchedEffect(Unit) {
        while (true) {
            agora = System.currentTimeMillis()
            val s = sessao
            val ate = s?.descansoAteMs
            // com o serviço rodando, quem vibra é ele (funciona com a tela apagada)
            if (!Pulso.servicoAtivo.value && s != null && !s.pausado && ate != null && s.restante(agora) == 0 && avisado != ate) {
                avisado = ate
                contexto.getSystemService(Vibrator::class.java)?.vibrate(
                    VibrationEffect.createWaveform(longArrayOf(0, 400, 150, 400), -1),
                )
            }
            delay(500)
        }
    }

    val s = sessao
    // coroa = volume (como no player de música); o foco vem quando esta página está na tela
    val foco = remember { FocusRequester() }
    var giro by remember { mutableFloatStateOf(0f) }
    LaunchedEffect(ativa) { if (ativa) runCatching { foco.requestFocus() } }
    Box(
        Modifier.fillMaxSize()
            .onRotaryScrollEvent {
                giro += it.verticalScrollPixels
                if (abs(giro) >= 48f) {
                    Volume.ajustar(contexto, giro > 0)
                    giro = 0f
                }
                true
            }
            .focusRequester(foco)
            .focusable(),
    ) {
        when {
            erro != null && s == null -> Acao(erro!!, "Tentar de novo") { agir { api.ativa() } }
            !carregou -> Mensagem("Carregando…")
            s == null -> Acao("Nenhum treino em andamento", "Treinar hoje") { agir { api.iniciar() } }
            s.estado == "concluida" -> Mensagem("Treino concluído\n${s.seriesFeitas} séries")
            s.fase(agora) == "fim" || s.atual == null ->
                Acao("Tudo feito!\n${relogio(s.ativoS(agora))}", "Concluir") { agir { api.concluir(s.id) } }
            else -> Player(s, agora, reps, { reps = (reps + it).coerceAtLeast(0) }, ::cmd) {
                val e = s.atual!!
                if (e.tempoMeta != null) cmd("concluir_serie", mapOf("tempo_s" to s.tempoSerie(agora)))
                else cmd("concluir_serie", mapOf("repeticoes" to reps))
            }
        }
        if (erro != null && s != null) {
            Text(
                erro!!, fontSize = 10.sp, color = MaterialTheme.colorScheme.error,
                modifier = Modifier.align(Alignment.BottomCenter).padding(8.dp),
            )
        }
    }
}

@Composable
fun Mensagem(texto: String) {
    Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
        Text(texto, textAlign = TextAlign.Center)
    }
}

@Composable
fun Acao(texto: String, botao: String, aoTocar: () -> Unit) {
    Column(
        Modifier.fillMaxSize().padding(20.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        LogoAgent(40.dp)
        Text(texto, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 8.dp))
        Button(
            onClick = aoTocar, modifier = Modifier.padding(top = 10.dp),
            colors = ButtonDefaults.buttonColors(containerColor = Marca.Azul, contentColor = Color.White),
            label = { Text(botao) },
        )
    }
}

/**
 * Painel no estilo de player de música: anel de progresso na borda (descanso ou séries do treino),
 * ⏮ desfaz a série, o botão central marca a série (no descanso, pula), ⏭ pula o exercício (no
 * descanso, +30 s); embaixo, o botão largo de pausar/continuar. A coroa ajusta o volume.
 */
@Composable
private fun Player(
    s: Sessao, agora: Long, reps: Int, ajustar: (Int) -> Unit,
    cmd: (String, Map<String, Any?>) -> Unit, feita: () -> Unit,
) {
    val e = s.atual!!
    val descanso = s.fase(agora) == "descanso"
    val restante = s.restante(agora) ?: 0
    val alvo = when {
        descanso -> restante / maxOf(s.descansoS, restante).coerceAtLeast(1).toFloat()
        e.tempoMeta != null -> (s.tempoSerie(agora) / e.tempoMeta.coerceAtLeast(1).toFloat()).coerceIn(0f, 1f)
        else -> s.seriesFeitas / s.seriesPlanejadas.coerceAtLeast(1).toFloat()
    }
    val progresso by animateFloatAsState(alvo, tween(600), label = "anel")
    val apagado = MaterialTheme.colorScheme.onSurfaceVariant
    val bpm = Pulso.bpm.value
    val zona = bpm?.let { Pulso.estatisticas.zona(it) }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        AnelProgresso(
            progresso, Modifier.fillMaxSize().padding(2.dp), 7.dp,
            cor = when {
                s.pausado -> MaterialTheme.colorScheme.outline
                descanso -> MaterialTheme.colorScheme.tertiary
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
                        s.pausado -> "PAUSADO"
                        descanso -> "DESCANSO"
                        else -> relogio(s.ativoS(agora))
                    },
                    fontSize = 11.sp, fontWeight = FontWeight.Bold,
                    color = when {
                        s.pausado -> apagado
                        descanso -> MaterialTheme.colorScheme.tertiary
                        else -> MaterialTheme.colorScheme.primary
                    },
                )
                if (bpm != null || Pulso.situacao.value != null) {
                    Coracao(bpm, 11.dp, zona?.let { Marca.zonas[it] } ?: apagado)
                    Text(
                        if (Pulso.situacao.value == "fora do pulso") "fora" else bpm?.toString() ?: "…",
                        fontSize = 11.sp, fontWeight = FontWeight.Bold, color = zona?.let { Marca.zonas[it] } ?: apagado,
                    )
                }
            }
            AnimatedContent(
                (if (descanso) "A seguir: " else "") + e.nome,
                transitionSpec = { (slideInHorizontally { it / 3 } + fadeIn()) togetherWith (slideOutHorizontally { -it / 3 } + fadeOut()) },
                label = "nome",
            ) { nome ->
                Text(
                    nome, fontWeight = FontWeight.Bold, fontSize = 15.sp,
                    textAlign = TextAlign.Center, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
            }
            Text(
                "Série ${e.feitas + 1} de ${e.planejadas} · ${carga(e.carga)}", fontSize = 11.sp, color = apagado,
                maxLines = 1,
            )
            when {
                descanso -> Numero(relogio(restante), 34)
                e.tempoMeta != null -> Numero("${relogio(s.tempoSerie(agora))} / ${relogio(e.tempoMeta)}", 22)
                else -> Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = { ajustar(-1) }, modifier = Modifier.size(36.dp)) {
                        Icone(Simbolo.MENOS, 16.dp, apagado)
                    }
                    Box(Modifier.padding(horizontal = 4.dp)) { Numero("$reps", 32) }
                    IconButton(onClick = { ajustar(1) }, modifier = Modifier.size(36.dp)) {
                        Icone(Simbolo.MAIS, 16.dp, apagado)
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
                ) { Icone(Simbolo.ANTERIOR, 18.dp) }
                val central by animateFloatAsState(if (s.pausado) 0.9f else 1f, label = "central")
                FilledIconButton(
                    onClick = {
                        when {
                            s.pausado -> cmd("continuar", emptyMap())
                            descanso -> cmd("pular_descanso", emptyMap())
                            else -> feita()
                        }
                    },
                    colors = IconButtonDefaults.filledIconButtonColors(containerColor = Marca.Azul, contentColor = Color.White),
                    modifier = Modifier.size(60.dp).scale(central),
                ) {
                    Icone(
                        when {
                            s.pausado -> Simbolo.PLAY
                            descanso -> Simbolo.PROXIMO
                            else -> Simbolo.CHECK
                        },
                        28.dp,
                    )
                }
                if (descanso) {
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
                    ) { Icone(Simbolo.PROXIMO, 18.dp) }
                }
            }
            // pausa larga e alta: dá para acertar com o dedo suado no meio do treino
            Button(
                onClick = { cmd(if (s.pausado) "continuar" else "pausar", emptyMap()) },
                colors = if (s.pausado) ButtonDefaults.buttonColors(containerColor = Marca.Roxo, contentColor = Color.White)
                else ButtonDefaults.filledTonalButtonColors(),
                modifier = Modifier.padding(top = 6.dp).size(width = 116.dp, height = 44.dp),
                contentPadding = PaddingValues(horizontal = 10.dp),
                icon = { Icone(if (s.pausado) Simbolo.PLAY else Simbolo.PAUSA, 16.dp) },
                label = { Text(if (s.pausado) "Continuar" else "Pausar", fontSize = 13.sp, fontWeight = FontWeight.Bold) },
            )
        }
    }
}

/** Número grande que desliza para cima quando muda (reps, cronômetro). */
@Composable
private fun Numero(texto: String, tamanho: Int) {
    AnimatedContent(
        texto,
        transitionSpec = { (slideInVertically { -it / 3 } + fadeIn(tween(160))) togetherWith (slideOutVertically { it / 3 } + fadeOut(tween(120))) },
        label = "numero",
    ) { t -> Text(t, fontSize = tamanho.sp, fontWeight = FontWeight.Bold) }
}
