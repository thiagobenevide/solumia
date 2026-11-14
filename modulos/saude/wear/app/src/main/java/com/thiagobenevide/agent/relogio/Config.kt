package com.thiagobenevide.agent.relogio

import android.content.Context

/** Endereço do backend e chave de cliente, gravados uma vez pelo `instalar` (extras do intent). */
object Config {
    private fun prefs(c: Context) = c.getSharedPreferences("config", Context.MODE_PRIVATE)

    fun salvar(c: Context, url: String, chave: String) {
        prefs(c).edit().putString("url", url).putString("chave", chave).apply()
    }

    /**
     * Extras `url`/`chave` do intent (o `instalar` manda por ADB). A activity é exportada (é a do
     * ícone), então outro app do relógio também poderia mandá-los e desviar os dados para outro
     * servidor: só vale na primeira configuração, com a mesma chave ou provando a atual
     * (`chave_atual`). Só HTTPS.
     */
    fun configurarPorIntent(c: Context, url: String, chave: String, chaveAtual: String?) {
        if (!url.startsWith("https://")) return
        val atual = prefs(c).getString("chave", null)
        if (atual == null || atual == chave || atual == chaveAtual) salvar(c, url, chave)
    }

    fun api(c: Context): Api? {
        val p = prefs(c)
        val url = p.getString("url", null) ?: return null
        val chave = p.getString("chave", null) ?: return null
        return Api(url, chave)
    }

    fun falarRespostas(c: Context): Boolean = prefs(c).getBoolean("falar", true)

    fun definirFalar(c: Context, sim: Boolean) {
        prefs(c).edit().putBoolean("falar", sim).apply()
    }
}
