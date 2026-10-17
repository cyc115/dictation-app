package app.dictation.keyboard

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asExecutor
import kotlinx.coroutines.suspendCancellableCoroutine
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID

/** A failure with a message for the keyboard's status line. */
class DictationError(message: String) : Exception(message)

class HttpResponse(val status: Int, val body: String)

/** One HTTPS POST (a fake in tests). Cancelling the caller aborts the request. */
fun interface Http {
    suspend fun post(url: String, headers: Map<String, String>, body: ByteArray): HttpResponse
}

/** `Http` over HttpURLConnection: no dependencies; cancellation disconnects the socket. */
class UrlConnectionHttp(private val timeoutMs: Int = 60_000) : Http {
    override suspend fun post(url: String, headers: Map<String, String>, body: ByteArray): HttpResponse =
        suspendCancellableCoroutine { cont ->
            val conn = URL(url).openConnection() as HttpURLConnection
            cont.invokeOnCancellation { conn.disconnect() }
            Dispatchers.IO.asExecutor().execute {
                // A cancelled continuation ignores this resume.
                cont.resumeWith(runCatching {
                    conn.requestMethod = "POST"
                    conn.doOutput = true
                    conn.connectTimeout = timeoutMs
                    conn.readTimeout = timeoutMs
                    headers.forEach(conn::setRequestProperty)
                    conn.setFixedLengthStreamingMode(body.size)
                    conn.outputStream.use { it.write(body) }
                    val status = conn.responseCode
                    val stream = if (status in 200..299) conn.inputStream else conn.errorStream
                    HttpResponse(status, stream?.bufferedReader()?.use { it.readText() } ?: "")
                })
            }
        }
}

/**
 * OpenRouter's speech-to-text and chat endpoints, sent exactly as the Mac app sends them
 * (OpenRouterClient and OpenRouterPolish in the Mac app's OpenRouter.swift and PolishService.swift).
 */
class OpenRouter(private val http: Http, private val apiKey: String) {
    /** The transcript of a 16 kHz mono WAV, tidied (`cleanup`). */
    suspend fun transcribe(wav: ByteArray, model: String): String {
        val (body, boundary) = multipart(model, wav, "dictation.wav")
        val response = try {
            http.post(TRANSCRIPTIONS, headers("multipart/form-data; boundary=$boundary"), body)
        } catch (e: java.io.IOException) {
            throw DictationError("Network error: ${e.message ?: e.javaClass.simpleName}")
        }
        return parseTranscription(response.status, response.body)
    }

    /** `text` cleaned by `model` with `instructions` (the setup's polish prompt). */
    suspend fun polish(text: String, model: ModelSpec, instructions: String, wrap: Boolean): String {
        val body = polishBody(model, userMessage(text, wrap), instructions)
        val response = http.post(COMPLETIONS, headers("application/json"), body.toString().toByteArray())
        return parsePolish(response.status, response.body)
    }

    private fun headers(contentType: String) = mapOf(
        "Authorization" to "Bearer $apiKey",
        // Shows in OpenRouter's activity log, apart from the Mac app's "DictationApp".
        "X-Title" to "DictationApp Android",
        "Content-Type" to contentType,
    )

    companion object {
        const val TRANSCRIPTIONS = "https://openrouter.ai/api/v1/audio/transcriptions"
        const val COMPLETIONS = "https://openrouter.ai/api/v1/chat/completions"

        fun multipart(model: String, audio: ByteArray, filename: String): Pair<ByteArray, String> {
            val boundary = "DictationApp-${UUID.randomUUID().toString().uppercase()}"
            val body = ByteArrayOutputStream()
            fun add(s: String) = body.write(s.toByteArray())
            add("--$boundary\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n$model\r\n")
            add("--$boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"$filename\"\r\nContent-Type: audio/wav\r\n\r\n")
            body.write(audio)
            add("\r\n--$boundary--\r\n")
            return body.toByteArray() to boundary
        }

        fun parseTranscription(status: Int, body: String): String {
            val json = runCatching { JSONObject(body) }.getOrNull()
            if (status in 200..299 && json?.opt("text") is String) return cleanup(json.getString("text"))
            throw DictationError(when (status) {
                401 -> "The cloud service rejected the API key — check it in Settings."
                402 -> "The cloud account is out of credits."
                403 -> "The cloud account needs to be set up before this model can be used."
                else -> errorMessage(json) ?: "Transcription failed (HTTP $status)."
            })
        }

        /** Tidies model quirks, e.g. "meeting??" / "meeting?." → "meeting?". */
        fun cleanup(text: String): String = text.trim()
            .replace(Regex("([?!？！])[.。]"), "$1")
            .replace(Regex("([.?!。？！])\\1+"), "$1")

        /** The transcript as the model sees it: in tags, it's data, not a request to the model. */
        fun userMessage(text: String, wrap: Boolean) = if (wrap) "<transcript>\n$text\n</transcript>" else text

        /** Thinking adds seconds and nothing to a cleanup: off where the model allows it, else the lowest effort. */
        private val mustThink = listOf("openai/gpt-oss", "openai/gpt-5", "openai/gpt-6")
        fun reasoning(model: String): JSONObject =
            if (mustThink.any { model.startsWith(it) }) JSONObject().put("effort", "minimal") else JSONObject().put("enabled", false)

        fun polishBody(model: ModelSpec, text: String, instructions: String): JSONObject = JSONObject()
            .put("model", model.id)
            .put("temperature", 0)
            .put("reasoning", reasoning(model.id))
            .put("messages", JSONArray()
                .put(JSONObject().put("role", "system").put("content", instructions))
                .put(JSONObject().put("role", "user").put("content", text)))
            .apply {
                model.providers?.let { put("provider", JSONObject().put("order", JSONArray(it)).put("allow_fallbacks", false)) }
            }

        fun parsePolish(status: Int, body: String): String {
            val json = runCatching { JSONObject(body) }.getOrNull()
            val content = json?.optJSONArray("choices")?.optJSONObject(0)?.optJSONObject("message")?.opt("content")
            if (status in 200..299 && content is String) return content
            throw DictationError(errorMessage(json) ?: "Polish failed (HTTP $status).")
        }

        /** The `error.message` OpenRouter puts in a failed response. */
        private fun errorMessage(json: JSONObject?): String? =
            json?.optJSONObject("error")?.opt("message") as? String
    }
}
