package com.thiagobenevide.agent.relogio

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.time.LocalDate

class ApiErro(mensagem: String) : Exception(mensagem)

/** Rotas do backend usadas no pulso: guia de treino (`/api/saude/sessoes`) e cobrador (`/api/painel`). */
class Api(private val base: String, private val chave: String) {

    private suspend fun enviar(
        metodo: String,
        caminho: String,
        corpo: ByteArray? = null,
        tipo: String = "application/json",
        esperaS: Int = 15,
    ): ByteArray = withContext(Dispatchers.IO) {
        val con = URL(base.trimEnd('/') + "/" + caminho).openConnection() as HttpURLConnection
        try {
            con.requestMethod = metodo
            con.connectTimeout = 8000
            con.readTimeout = esperaS * 1000
            con.setRequestProperty("Authorization", "Bearer $chave")
            if (corpo != null) {
                con.doOutput = true
                con.setRequestProperty("Content-Type", tipo)
                con.outputStream.use { it.write(corpo) }
            }
            val codigo = con.responseCode
            val bytes = (if (codigo < 400) con.inputStream else con.errorStream)?.use { it.readBytes() } ?: ByteArray(0)
            if (codigo >= 400) {
                val detalhe = runCatching { JSONObject(String(bytes)).optString("detail") }.getOrNull()
                throw ApiErro(detalhe?.takeIf { it.isNotBlank() } ?: "Erro $codigo")
            }
            bytes
        } catch (e: IOException) {
            throw ApiErro("Sem conexão com o servidor")
        } finally {
            con.disconnect()
        }
    }

    private suspend fun json(metodo: String, caminho: String, corpo: JSONObject? = null): String =
        String(enviar(metodo, caminho, corpo?.toString()?.toByteArray()))

    // --- treino ---

    private suspend fun sessao(metodo: String, caminho: String, corpo: JSONObject? = null): Sessao =
        Sessao.deJson(JSONObject(json(metodo, caminho, corpo)))

    suspend fun ativa(): Sessao? {
        val texto = json("GET", "api/saude/sessoes/ativa").trim()
        return if (texto == "null" || texto.isEmpty()) null else Sessao.deJson(JSONObject(texto))
    }

    suspend fun iniciar(): Sessao =
        sessao("POST", "api/saude/sessoes", JSONObject().put("data", LocalDate.now().toString()))

    suspend fun comando(id: String, acao: String, dados: Map<String, Any?> = emptyMap()): Sessao {
        val corpo = JSONObject().put("acao", acao)
        dados.forEach { (k, v) -> if (v != null) corpo.put(k, v) }
        return sessao("POST", "api/saude/sessoes/$id/comando", corpo)
    }

    /** Lote de batimentos do sensor; devolve `estado` (parar de enviar se não for "andamento"). */
    suspend fun enviarFc(id: String, amostras: List<Pair<java.time.Instant, Double>>): JSONObject {
        val lista = JSONArray()
        amostras.forEach { (t, bpm) -> lista.put(JSONObject().put("em", t.toString()).put("bpm", bpm)) }
        return JSONObject(json("POST", "api/saude/sessoes/$id/fc", JSONObject().put("amostras", lista)))
    }

    suspend fun concluir(id: String): Sessao = sessao("POST", "api/saude/sessoes/$id/concluir", JSONObject())

    // --- cobrador ---

    suspend fun disciplina(): JSONObject = JSONObject(json("GET", "api/painel/disciplina"))

    suspend fun agenda(dia: String = LocalDate.now().toString()): JSONObject =
        JSONObject(json("GET", "api/painel/agenda/$dia"))

    suspend fun marcarBloco(dia: String, id: String, feito: Boolean = true) {
        json("POST", "api/painel/agenda/$dia/blocos/${URLEncoder.encode(id, "UTF-8")}/feito?feito=$feito")
    }

    /**
     * Áudio WAV → transcrição no worker → resposta do cobrador, em eventos conforme acontecem
     * (`/voz/fluxo`): `transcricao`, `aviso` (andamento: "consultando a internet…"), e `fim`
     * (`resposta`, `executadas`) ou `erro`. Linhas vazias são só para manter a conexão.
     */
    fun vozFluxo(wav: ByteArray, historico: JSONArray): Flow<JSONObject> = flow {
        val limite = "agent" + System.nanoTime()
        val corpo = java.io.ByteArrayOutputStream()
        fun campo(nome: String, valor: String) {
            corpo.write("--$limite\r\nContent-Disposition: form-data; name=\"$nome\"\r\n\r\n$valor\r\n".toByteArray())
        }
        campo("provedor", "local")
        campo("historico", historico.toString())
        campo("idioma", "pt")
        corpo.write(
            ("--$limite\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"voz.wav\"\r\n" +
                "Content-Type: audio/wav\r\n\r\n").toByteArray(),
        )
        corpo.write(wav)
        corpo.write("\r\n--$limite--\r\n".toByteArray())
        val con = URL(base.trimEnd('/') + "/api/painel/voz/fluxo").openConnection() as HttpURLConnection
        try {
            con.requestMethod = "POST"
            con.connectTimeout = 8000
            con.readTimeout = 60_000 // o servidor manda uma linha vazia a cada 10 s
            con.setRequestProperty("Authorization", "Bearer $chave")
            con.doOutput = true
            con.setRequestProperty("Content-Type", "multipart/form-data; boundary=$limite")
            con.outputStream.use { it.write(corpo.toByteArray()) }
            val codigo = con.responseCode
            if (codigo >= 400) {
                val bytes = con.errorStream?.use { it.readBytes() } ?: ByteArray(0)
                val detalhe = runCatching { JSONObject(String(bytes)).optString("detail") }.getOrNull()
                throw ApiErro(detalhe?.takeIf { it.isNotBlank() } ?: "Erro $codigo")
            }
            val leitor = con.inputStream.bufferedReader()
            while (true) {
                val linha = leitor.readLine() ?: break
                if (linha.isNotBlank()) emit(JSONObject(linha))
            }
        } catch (e: IOException) {
            throw ApiErro("Sem conexão com o servidor")
        } finally {
            con.disconnect()
        }
    }.flowOn(Dispatchers.IO)

    /** Resposta falada (WAV) sintetizada no worker. */
    // --- atualização do app ---

    suspend fun versaoPublicada(): JSONObject = JSONObject(json("GET", "api/atualizacoes"))

    /** Baixa o APK do relógio direto para [destino], avisando o andamento (0 a 1) a cada pedaço. */
    suspend fun baixarRelogio(destino: java.io.File, progresso: (Float) -> Unit) = withContext(Dispatchers.IO) {
        val con = URL(base.trimEnd('/') + "/api/atualizacoes/relogio").openConnection() as HttpURLConnection
        try {
            con.connectTimeout = 8000
            con.readTimeout = 60_000
            con.setRequestProperty("Authorization", "Bearer $chave")
            if (con.responseCode >= 400) throw ApiErro("Erro ${con.responseCode} ao baixar")
            val total = con.contentLengthLong
            var lidos = 0L
            con.inputStream.use { entrada ->
                destino.outputStream().use { saida ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = entrada.read(buf)
                        if (n < 0) break
                        saida.write(buf, 0, n)
                        lidos += n
                        if (total > 0) progresso(lidos / total.toFloat())
                    }
                }
            }
        } catch (e: IOException) {
            throw ApiErro("Sem conexão com o servidor")
        } finally {
            con.disconnect()
        }
    }

    /** Só o pedaço [trecho] da fala (vazio depois do último): toca um enquanto o próximo é gerado. */
    suspend fun falar(texto: String, trecho: Int): ByteArray = enviar(
        "POST",
        "api/painel/falar",
        JSONObject().put("texto", texto.take(4000)).put("trecho", trecho).toString().toByteArray(),
        esperaS = 60,
    )
}
