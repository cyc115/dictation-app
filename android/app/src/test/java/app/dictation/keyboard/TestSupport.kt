package app.dictation.keyboard

import java.io.File

/** Paths the build passes to tests (app/build.gradle.kts). */
object TestFiles {
    val repoRoot = File(System.getProperty("repoRoot")!!)
    val specDir = File(System.getProperty("specDir")!!)
    val screenshots = File(System.getProperty("screenshots")!!)
    val assets = File(repoRoot, "android/app/src/main/assets")

    /** Reads an asset as the app does: generated spec first, then the committed ones. */
    fun asset(path: String): String = File(specDir, path).takeIf { it.exists() }?.readText() ?: File(assets, path).readText()

    val setups: List<Setup> by lazy { Setups.load(::asset) }
}

/** Records requests and answers them from `respond` (by URL and model). */
class FakeHttp(private val respond: suspend (url: String, model: String, body: ByteArray) -> HttpResponse) : Http {
    val requests = mutableListOf<Triple<String, Map<String, String>, ByteArray>>()

    override suspend fun post(url: String, headers: Map<String, String>, body: ByteArray): HttpResponse {
        synchronized(requests) { requests += Triple(url, headers, body) }
        return respond(url, modelOf(body), body)
    }

    companion object {
        /** The model a request names: the multipart "model" field or the JSON "model". */
        fun modelOf(body: ByteArray): String {
            val text = String(body, Charsets.ISO_8859_1)
            Regex("name=\"model\"\r\n\r\n([^\r]+)").find(text)?.let { return it.groupValues[1] }
            // Android's org.json writes "/" as "\/" (valid JSON; OpenRouter reads it as "/").
            return Regex("\"model\":\"([^\"]+)\"").find(text)?.groupValues?.get(1)?.replace("\\/", "/") ?: ""
        }

        fun transcript(text: String) = HttpResponse(200, org.json.JSONObject().put("text", text).toString())

        fun chat(content: String) = HttpResponse(200, org.json.JSONObject().put("choices",
            org.json.JSONArray().put(org.json.JSONObject().put("message", org.json.JSONObject().put("content", content)))).toString())
    }
}

/** A microphone that "hears" a second of speech. */
class FakeMic : Mic {
    var listening = false
    var cancelled = 0
    var silent = false
    private var onLevel: ((Float) -> Unit)? = null

    override fun start(onLevel: (Float) -> Unit): Boolean {
        listening = true
        this.onLevel = onLevel
        return true
    }

    /** As the recording thread does, every 100 ms. */
    fun level(value: Float) = onLevel?.invoke(value)

    override fun stop(): Recording {
        listening = false
        return Recording(if (silent) ByteArray(32_000) else ByteArray(32_000) { (it % 50).toByte() }, heardOnlySilence = silent)
    }

    override fun cancel() {
        listening = false
        cancelled++
    }
}

class MemorySecrets(override var apiKey: String?) : SecretStore
