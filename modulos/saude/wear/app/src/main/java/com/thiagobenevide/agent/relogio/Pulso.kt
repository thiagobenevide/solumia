package com.thiagobenevide.agent.relogio

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf

/**
 * Estado do treino compartilhado entre as telas e o [TreinoServico] (mesmo processo). O serviço é
 * quem lê o sensor e vibra; as telas só mostram e avisam o que mudou.
 */
object Pulso {
    /** Último batimento lido (null sem leitura ainda). */
    val bpm = mutableStateOf<Int?>(null)

    /** "fora do pulso", "procurando…" ou null quando está lendo. */
    val situacao = mutableStateOf<String?>(null)

    /** Treino em andamento visto pelas telas ou pelo serviço; o App liga e desliga o serviço por ele. */
    val sessaoAtiva = mutableStateOf<String?>(null)

    /** Serviço rodando: ele vibra no fim do descanso (a tela não precisa). */
    val servicoAtivo = mutableStateOf(false)

    /** Estatísticas do treino atual (ou da medição avulsa); [versao] avisa as telas a cada leitura. */
    val estatisticas = Estatisticas()
    val versao = mutableIntStateOf(0)

    /** Calorias do exercício (Health Services; null sem a permissão de atividade). */
    val calorias = mutableStateOf<Double?>(null)

    /** Totais do dia vindos do sensor passivo: passos, calorias, distância (m) e andares. */
    val passos = mutableStateOf<Long?>(null)
    val caloriasDia = mutableStateOf<Double?>(null)
    val distanciaDia = mutableStateOf<Double?>(null)
    val andaresDia = mutableStateOf<Double?>(null)

    /** Último batimento do sensor passivo (valor, ms): o que o relógio mediu sozinho, sem o app aberto. */
    val ultimoBpm = mutableStateOf<Pair<Int, Long>?>(null)

    /** Uma leitura de batimento: estado da tela, estatísticas e série do gráfico. */
    fun registrar(ms: Long, valor: Int) {
        bpm.value = valor
        situacao.value = null
        estatisticas.registrar(ms, valor)
        versao.intValue++
    }

    fun zerar() {
        estatisticas.limpar()
        calorias.value = null
        versao.intValue++
    }

    /** Permissão de passos/calorias/distância (sensor passivo e calorias do treino). */
    const val ATIVIDADE = Manifest.permission.ACTIVITY_RECOGNITION

    fun atividadeAutorizada(c: Context) = c.checkSelfPermission(ATIVIDADE) == PackageManager.PERMISSION_GRANTED

    /** Fim do descanso em ms do relógio do pulso (null fora do descanso ou pausado). */
    @Volatile var descansoAteMs: Long? = null

    /** Texto da notificação: "Supino 2/4" ou "Descanso". */
    @Volatile var etapa: String = "Treino"

    /** BODY_SENSORS até o Wear OS 5; no 6 (API 36) a permissão é a do Health Connect. */
    val permissao: String =
        if (Build.VERSION.SDK_INT >= 36) "android.permission.health.READ_HEART_RATE" else Manifest.permission.BODY_SENSORS

    fun autorizado(c: Context) = c.checkSelfPermission(permissao) == PackageManager.PERMISSION_GRANTED

    /** O que as telas sabem da sessão (comando acabou de mudar o descanso, por exemplo). */
    fun atualizar(s: Sessao?) {
        sessaoAtiva.value = s?.id?.takeIf { s.estado == "andamento" }
        descansoAteMs = if (s != null && s.faseServidor == "descanso" && !s.pausado) s.descansoAteMs?.minus(s.offsetMs) else null
        etapa = when {
            s == null -> "Treino"
            s.faseServidor == "descanso" -> "Descanso"
            else -> s.atual?.let { "${it.nome} ${it.feitas + 1}/${it.planejadas}" } ?: "Treino"
        }
    }

    fun ligar(c: Context, id: String) {
        c.startForegroundService(Intent(c, TreinoServico::class.java).putExtra("id", id))
    }

    fun desligar(c: Context) {
        c.stopService(Intent(c, TreinoServico::class.java))
    }
}
