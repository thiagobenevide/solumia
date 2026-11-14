package com.thiagobenevide.agent.relogio

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.mutableStateOf

/**
 * Agent no pulso. Endereço e chave chegam uma vez pelo `instalar` (extras `url` e `chave`) e ficam
 * nas preferências; o extra `tela` (das notificações) abre direto na tela certa.
 */
class MainActivity : ComponentActivity() {
    private val tela = mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val url = intent.getStringExtra("url")
        val chave = intent.getStringExtra("chave")
        if (!url.isNullOrBlank() && !chave.isNullOrBlank()) {
            Config.configurarPorIntent(this, url, chave, intent.getStringExtra("chave_atual"))
        }
        tela.value = intent.getStringExtra("tela")
        val api = Config.api(this)
        if (api != null) {
            Avisos.agendar(this)
            if (Build.VERSION.SDK_INT >= 33 &&
                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
            ) {
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
            }
        }
        setContent { App(api, tela.value, ::telaAcesa) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.getStringExtra("tela")?.let { tela.value = it }
    }

    /** Tela acesa só com o treino em andamento (o descanso precisa aparecer e vibrar). */
    private fun telaAcesa(ligada: Boolean) {
        if (ligada) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }
}
