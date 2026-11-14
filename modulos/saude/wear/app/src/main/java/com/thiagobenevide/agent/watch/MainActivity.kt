package com.thiagobenevide.agent.watch

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
 * Agent on the wrist. Address and key arrive once through `instalar` (extras `url` and `chave`) and stay
 * in the preferences; the `tela` extra (from notifications) opens straight on the right screen.
 */
class MainActivity : ComponentActivity() {
    private val screen = mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val url = intent.getStringExtra("url")
        val key = intent.getStringExtra("chave")
        if (!url.isNullOrBlank() && !key.isNullOrBlank()) {
            Config.configureFromIntent(this, url, key, intent.getStringExtra("chave_atual"))
        }
        screen.value = intent.getStringExtra("tela")
        val api = Config.api(this)
        if (api != null) {
            Warnings.schedule(this)
            if (Build.VERSION.SDK_INT >= 33 &&
                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
            ) {
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
            }
        }
        setContent { App(api, screen.value, ::screenOn) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.getStringExtra("tela")?.let { screen.value = it }
    }

    /** Screen kept on only while a workout is in progress (the rest has to show up and vibrate). */
    private fun screenOn(on: Boolean) {
        if (on) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }
}
