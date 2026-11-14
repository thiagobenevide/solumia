package com.thiagobenevide.agent.watch

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

/** Update stages shown on the full screen ([UpdateScreen]). */
sealed interface Stage {
    data object Oferta : Stage
    data class Downloading(val progress: Float) : Stage
    data object Instalando : Stage
    data object Authorize : Stage
    data class Failed(val reason: String) : Stage
}

/**
 * Update from the watch itself: `publicar_app` puts `relogio.apk` on the VPS with the same `build`
 * as `versao.json`; if it is greater than the installed versionCode, Home shows "Atualizar". After
 * installing, the first open shows the celebration ([justUpdated]).
 */
object Update {
    /** Update screen open (null = closed). */
    val stage = mutableStateOf<Stage?>(null)

    /** Published build newer than the installed one (null = up to date). */
    val newBuild = mutableStateOf<Long?>(null)

    fun currentBuild(c: Context): Long = c.packageManager.getPackageInfo(c.packageName, 0).longVersionCode

    /** "12/11 às 05:56": the build is in minutes since 1970 (see `instalar`). */
    fun label(build: Long): String = if (build < 1_000_000) "build $build" else
        java.time.Instant.ofEpochSecond(build * 60).atZone(java.time.ZoneId.systemDefault())
            .format(java.time.format.DateTimeFormatter.ofPattern("dd/MM 'às' HH:mm"))

    /** Build just installed, on the first open after an update (only once). */
    fun justUpdated(c: Context): Long? {
        val p = c.getSharedPreferences("config", Context.MODE_PRIVATE)
        val current = currentBuild(c)
        val visto = p.getLong("build_visto", 0)
        p.edit().putLong("build_visto", current).apply()
        // no build seen (old versions did not record it): already configured = came from an update
        return current.takeIf { if (visto == 0L) p.contains("url") else visto < current }
    }

    /** Build published for the watch, or null if there is none newer than the installed one. */
    suspend fun newVersion(c: Context, api: Api): Long? {
        val v = api.publishedVersion()
        val plataformas = v.optJSONArray("plataformas") ?: return null
        val has = (0 until plataformas.length()).any { plataformas.optString(it) == "relogio" }
        val build = v.optLong("build", 0)
        return build.takeIf { has && it > currentBuild(c) }
    }

    /**
     * Downloads (with progress) and hands it to the Android installer, which asks for confirmation on screen (and, the
     * first time, the permission to install apps from this source). The progress goes to [stage].
     */
    suspend fun downloadAndInstall(c: Context, api: Api) {
        if (!c.packageManager.canRequestPackageInstalls()) {
            val adjustments = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${c.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (runCatching { c.startActivity(adjustments) }.isSuccess) {
                stage.value = Stage.Authorize
                return
            }
        }
        stage.value = Stage.Downloading(0f)
        val apk = File(c.cacheDir, "relogio.apk")
        try {
            api.downloadWatch(apk) { stage.value = Stage.Downloading(it) }
            stage.value = Stage.Instalando
            val installer = c.packageManager.packageInstaller
            val id = installer.createSession(
                PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
            )
            installer.openSession(id).use { s ->
                s.openWrite("relogio.apk", 0, apk.length()).use { output ->
                    apk.inputStream().use { it.copyTo(output) }
                    s.fsync(output)
                }
                // FLAG_MUTABLE: the installer fills the status and the confirmation intent in the extras.
                val warning = PendingIntent.getBroadcast(
                    c, id, Intent(c, InstallReceiver::class.java),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
                )
                s.commit(warning.intentSender)
            }
        } catch (e: Exception) {
            stage.value = Stage.Failed(e.message ?: "Falhou")
        } finally {
            apk.delete()
        }
    }
}

/** Receives the installation progress and opens the Android confirmation screen. */
class InstallReceiver : BroadcastReceiver() {
    override fun onReceive(c: Context, i: Intent) {
        val status = i.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> Unit
            // success: Android closes the app and the next open shows "Atualizado"
            PackageInstaller.STATUS_SUCCESS -> return
            else -> {
                Update.stage.value = Stage.Failed(
                    if (status == PackageInstaller.STATUS_FAILURE_ABORTED) "Instalação cancelada"
                    else i.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "O instalador recusou",
                )
                return
            }
        }
        val confirm = IntentCompat.getParcelableExtra(i, Intent.EXTRA_INTENT, Intent::class.java) ?: return
        c.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
