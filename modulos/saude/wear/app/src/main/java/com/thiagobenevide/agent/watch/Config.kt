package com.thiagobenevide.agent.watch

import android.content.Context

/** Backend address and client key, written once by `instalar` (intent extras). */
object Config {
    private fun prefs(c: Context) = c.getSharedPreferences("config", Context.MODE_PRIVATE)

    fun save(c: Context, url: String, key: String) {
        prefs(c).edit().putString("url", url).putString("chave", key).apply()
    }

    /**
     * Intent extras `url`/`chave` (`instalar` sends them over ADB). The activity is exported (it is the
     * icon one), so another app on the watch could also send them and divert the data to another
     * server: it only counts on the first configuration, with the same key or proving the current one
     * (`chave_atual`). HTTPS only.
     */
    fun configureFromIntent(c: Context, url: String, key: String, currentKey: String?) {
        if (!url.startsWith("https://")) return
        val current = prefs(c).getString("chave", null)
        if (current == null || current == key || current == currentKey) save(c, url, key)
    }

    fun api(c: Context): Api? {
        val p = prefs(c)
        val url = p.getString("url", null) ?: return null
        val key = p.getString("chave", null) ?: return null
        return Api(url, key)
    }

    fun speakAnswers(c: Context): Boolean = prefs(c).getBoolean("falar", true)

    fun setSpeak(c: Context, yes: Boolean) {
        prefs(c).edit().putBoolean("falar", yes).apply()
    }
}
