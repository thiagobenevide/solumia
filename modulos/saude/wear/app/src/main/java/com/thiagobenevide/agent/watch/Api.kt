package com.thiagobenevide.agent.watch

import android.graphics.Bitmap
import android.graphics.BitmapFactory
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

class ApiError(message: String) : Exception(message)

/** Decodes with the largest power-of-2 sampling that keeps the long side >= [maxSide]. */
fun decodeSmall(bytes: ByteArray, maxSide: Int): Bitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    var sample = 1
    while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxSide) sample *= 2
    return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
}

/** Backend routes used on the wrist: workout guide (`/api/saude/sessoes`) and coach (`/api/painel`). */
class Api(private val base: String, private val key: String) {

    /** Exercise photos already downloaded in this run (a workout uses few). */
    private val images = java.util.concurrent.ConcurrentHashMap<String, Bitmap>()

    private suspend fun send(
        metodo: String,
        path: String,
        body: ByteArray? = null,
        kind: String = "application/json",
        waitS: Int = 15,
    ): ByteArray = withContext(Dispatchers.IO) {
        val con = URL(base.trimEnd('/') + "/" + path).openConnection() as HttpURLConnection
        try {
            con.requestMethod = metodo
            con.connectTimeout = 8000
            con.readTimeout = waitS * 1000
            con.setRequestProperty("Authorization", "Bearer $key")
            if (body != null) {
                con.doOutput = true
                con.setRequestProperty("Content-Type", kind)
                con.outputStream.use { it.write(body) }
            }
            val code = con.responseCode
            val bytes = (if (code < 400) con.inputStream else con.errorStream)?.use { it.readBytes() } ?: ByteArray(0)
            if (code >= 400) {
                val detail = runCatching { JSONObject(String(bytes)).optString("detail") }.getOrNull()
                throw ApiError(detail?.takeIf { it.isNotBlank() } ?: "Erro $code")
            }
            bytes
        } catch (e: IOException) {
            throw ApiError("Sem conexão com o servidor")
        } finally {
            con.disconnect()
        }
    }

    private suspend fun json(metodo: String, path: String, body: JSONObject? = null): String =
        String(send(metodo, path, body?.toString()?.toByteArray()))

    // --- treino ---

    private suspend fun session(metodo: String, path: String, body: JSONObject? = null): Session =
        Session.deJson(JSONObject(json(metodo, path, body)))

    suspend fun active(): Session? {
        val text = json("GET", "api/saude/sessoes/ativa").trim()
        return if (text == "null" || text.isEmpty()) null else Session.deJson(JSONObject(text))
    }

    suspend fun begin(): Session =
        session("POST", "api/saude/sessoes", JSONObject().put("data", LocalDate.now().toString()))

    suspend fun command(id: String, action: String, data: Map<String, Any?> = emptyMap()): Session {
        val body = JSONObject().put("acao", action)
        data.forEach { (k, v) -> if (v != null) body.put(k, v) }
        return session("POST", "api/saude/sessoes/$id/comando", body)
    }

    /** Batch of sensor heartbeats; returns `estado` (stop sending if it is not "andamento"). */
    suspend fun sendFc(id: String, samples: List<Pair<java.time.Instant, Double>>): JSONObject {
        val list = JSONArray()
        samples.forEach { (t, bpm) -> list.put(JSONObject().put("em", t.toString()).put("bpm", bpm)) }
        return JSONObject(json("POST", "api/saude/sessoes/$id/fc", JSONObject().put("amostras", list)))
    }

    /** Photo [n] (0 = start, 1 = end of the movement) scaled down for the wrist; null without one. */
    suspend fun exerciseImage(id: String, n: Int): Bitmap? {
        val key = "$id:$n"
        images[key]?.let { return it }
        val bytes = try {
            send("GET", "api/saude/exercicios/$id/imagem?n=$n", waitS = 20)
        } catch (e: ApiError) {
            return null
        }
        val bitmap = withContext(Dispatchers.Default) { decodeSmall(bytes, 360) } ?: return null
        images[key] = bitmap
        return bitmap
    }

    suspend fun finish(id: String): Session = session("POST", "api/saude/sessoes/$id/concluir", JSONObject())

    // --- cobrador ---

    suspend fun subject(): JSONObject = JSONObject(json("GET", "api/painel/disciplina"))

    suspend fun agenda(day: String = LocalDate.now().toString()): JSONObject =
        JSONObject(json("GET", "api/painel/agenda/$day"))

    suspend fun markBlock(day: String, id: String, done: Boolean = true) {
        json("POST", "api/painel/agenda/$day/blocos/${URLEncoder.encode(id, "UTF-8")}/feito?feito=$done")
    }

    /**
     * WAV audio → transcription on the worker → coach answer, as events while they happen
     * (`/voz/fluxo`): `transcricao`, `aviso` (andamento: "consultando a internet…"), e `fim`
     * (`resposta`, `executadas`) or `erro`. Empty lines only keep the connection alive.
     */
    fun voiceFlow(wav: ByteArray, history: JSONArray): Flow<JSONObject> = flow {
        val limit = "agent" + System.nanoTime()
        val body = java.io.ByteArrayOutputStream()
        fun field(name: String, value: String) {
            body.write("--$limit\r\nContent-Disposition: form-data; name=\"$name\"\r\n\r\n$value\r\n".toByteArray())
        }
        field("provedor", "local")
        field("historico", history.toString())
        field("idioma", "pt")
        body.write(
            ("--$limit\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"voz.wav\"\r\n" +
                "Content-Type: audio/wav\r\n\r\n").toByteArray(),
        )
        body.write(wav)
        body.write("\r\n--$limit--\r\n".toByteArray())
        val con = URL(base.trimEnd('/') + "/api/painel/voz/fluxo").openConnection() as HttpURLConnection
        try {
            con.requestMethod = "POST"
            con.connectTimeout = 8000
            con.readTimeout = 60_000 // the server sends an empty line every 10 s
            con.setRequestProperty("Authorization", "Bearer $key")
            con.doOutput = true
            con.setRequestProperty("Content-Type", "multipart/form-data; boundary=$limit")
            con.outputStream.use { it.write(body.toByteArray()) }
            val code = con.responseCode
            if (code >= 400) {
                val bytes = con.errorStream?.use { it.readBytes() } ?: ByteArray(0)
                val detail = runCatching { JSONObject(String(bytes)).optString("detail") }.getOrNull()
                throw ApiError(detail?.takeIf { it.isNotBlank() } ?: "Erro $code")
            }
            val leitor = con.inputStream.bufferedReader()
            while (true) {
                val line = leitor.readLine() ?: break
                if (line.isNotBlank()) emit(JSONObject(line))
            }
        } catch (e: IOException) {
            throw ApiError("Sem conexão com o servidor")
        } finally {
            con.disconnect()
        }
    }.flowOn(Dispatchers.IO)

    /** Spoken answer (WAV) synthesized on the worker. */
    // --- app update ---

    suspend fun publishedVersion(): JSONObject = JSONObject(json("GET", "api/atualizacoes"))

    /** Downloads the watch APK straight to [destination], reporting progress (0 to 1) on each chunk. */
    suspend fun downloadWatch(destination: java.io.File, progress: (Float) -> Unit) = withContext(Dispatchers.IO) {
        val con = URL(base.trimEnd('/') + "/api/atualizacoes/relogio").openConnection() as HttpURLConnection
        try {
            con.connectTimeout = 8000
            con.readTimeout = 60_000
            con.setRequestProperty("Authorization", "Bearer $key")
            if (con.responseCode >= 400) throw ApiError("Erro ${con.responseCode} ao baixar")
            val total = con.contentLengthLong
            var readCount = 0L
            con.inputStream.use { input ->
                destination.outputStream().use { output ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        output.write(buf, 0, n)
                        readCount += n
                        if (total > 0) progress(readCount / total.toFloat())
                    }
                }
            }
        } catch (e: IOException) {
            throw ApiError("Sem conexão com o servidor")
        } finally {
            con.disconnect()
        }
    }

    /** Only chunk [span] of the speech (empty after the last one): one plays while the next is generated. */
    suspend fun speak(text: String, span: Int): ByteArray = send(
        "POST",
        "api/painel/falar",
        JSONObject().put("texto", text.take(4000)).put("trecho", span).toString().toByteArray(),
        waitS = 60,
    )
}
