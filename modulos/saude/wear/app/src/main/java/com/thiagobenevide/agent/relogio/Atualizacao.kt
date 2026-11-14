package com.thiagobenevide.agent.relogio

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.provider.Settings
import androidx.compose.runtime.mutableStateOf
import androidx.core.content.IntentCompat
import java.io.File

/** Etapas da atualização mostradas na tela cheia ([AtualizacaoTela]). */
sealed interface Etapa {
    data object Oferta : Etapa
    data class Baixando(val progresso: Float) : Etapa
    data object Instalando : Etapa
    data object Autorizar : Etapa
    data class Falhou(val motivo: String) : Etapa
}

/**
 * Atualização pelo próprio relógio: o `publicar_app` põe na VPS o `relogio.apk` com o mesmo `build`
 * do `versao.json`; se for maior que o versionCode instalado, o Início mostra "Atualizar". Depois de
 * instalar, a primeira abertura mostra a comemoração ([recemAtualizado]).
 */
object Atualizacao {
    /** Tela de atualização aberta (null = fechada). */
    val etapa = mutableStateOf<Etapa?>(null)

    /** Build publicado mais novo que o instalado (null = em dia). */
    val novoBuild = mutableStateOf<Long?>(null)

    fun buildAtual(c: Context): Long = c.packageManager.getPackageInfo(c.packageName, 0).longVersionCode

    /** "12/11 às 05:56": o build é em minutos desde 1970 (ver `instalar`). */
    fun rotulo(build: Long): String = if (build < 1_000_000) "build $build" else
        java.time.Instant.ofEpochSecond(build * 60).atZone(java.time.ZoneId.systemDefault())
            .format(java.time.format.DateTimeFormatter.ofPattern("dd/MM 'às' HH:mm"))

    /** Build recém-instalado na primeira abertura depois de uma atualização (uma vez só). */
    fun recemAtualizado(c: Context): Long? {
        val p = c.getSharedPreferences("config", Context.MODE_PRIVATE)
        val atual = buildAtual(c)
        val visto = p.getLong("build_visto", 0)
        p.edit().putLong("build_visto", atual).apply()
        // sem build visto (versões antigas não gravavam): já configurado = veio de uma atualização
        return atual.takeIf { if (visto == 0L) p.contains("url") else visto < atual }
    }

    /** Build publicado para o relógio, ou null se não houver um mais novo que o instalado. */
    suspend fun novaVersao(c: Context, api: Api): Long? {
        val v = api.versaoPublicada()
        val plataformas = v.optJSONArray("plataformas") ?: return null
        val tem = (0 until plataformas.length()).any { plataformas.optString(it) == "relogio" }
        val build = v.optLong("build", 0)
        return build.takeIf { tem && it > buildAtual(c) }
    }

    /**
     * Baixa (com progresso) e entrega ao instalador do Android, que pede a confirmação na tela (e, na
     * primeira vez, a autorização de instalar apps desta fonte). O andamento vai para [etapa].
     */
    suspend fun baixarEInstalar(c: Context, api: Api) {
        if (!c.packageManager.canRequestPackageInstalls()) {
            val ajustes = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${c.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (runCatching { c.startActivity(ajustes) }.isSuccess) {
                etapa.value = Etapa.Autorizar
                return
            }
        }
        etapa.value = Etapa.Baixando(0f)
        val apk = File(c.cacheDir, "relogio.apk")
        try {
            api.baixarRelogio(apk) { etapa.value = Etapa.Baixando(it) }
            etapa.value = Etapa.Instalando
            val instalador = c.packageManager.packageInstaller
            val id = instalador.createSession(
                PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
            )
            instalador.openSession(id).use { s ->
                s.openWrite("relogio.apk", 0, apk.length()).use { saida ->
                    apk.inputStream().use { it.copyTo(saida) }
                    s.fsync(saida)
                }
                // FLAG_MUTABLE: o instalador preenche o status e o intent de confirmação nos extras.
                val aviso = PendingIntent.getBroadcast(
                    c, id, Intent(c, InstalacaoReceiver::class.java),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
                )
                s.commit(aviso.intentSender)
            }
        } catch (e: Exception) {
            etapa.value = Etapa.Falhou(e.message ?: "Falhou")
        } finally {
            apk.delete()
        }
    }
}

/** Recebe o andamento da instalação e abre a tela de confirmação do Android. */
class InstalacaoReceiver : BroadcastReceiver() {
    override fun onReceive(c: Context, i: Intent) {
        val status = i.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> Unit
            // sucesso: o Android encerra o app e a próxima abertura mostra "Atualizado"
            PackageInstaller.STATUS_SUCCESS -> return
            else -> {
                Atualizacao.etapa.value = Etapa.Falhou(
                    if (status == PackageInstaller.STATUS_FAILURE_ABORTED) "Instalação cancelada"
                    else i.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "O instalador recusou",
                )
                return
            }
        }
        val confirmar = IntentCompat.getParcelableExtra(i, Intent.EXTRA_INTENT, Intent::class.java) ?: return
        c.startActivity(confirmar.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
