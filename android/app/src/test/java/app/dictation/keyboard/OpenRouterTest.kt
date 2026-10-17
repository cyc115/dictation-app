package app.dictation.keyboard

import kotlinx.coroutines.test.runTest
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** Ported from the Mac app's TranscriptionTests and PolishTests: same requests, same answers. */
class OpenRouterTest {
    @Test
    fun cleanupFixesDoubledPunctuation() {
        assertEquals("from today's meeting?", OpenRouter.cleanup("from today's meeting??"))
        assertEquals("from today's meeting?", OpenRouter.cleanup("from today's meeting?."))
        assertEquals("好的。", OpenRouter.cleanup(" 好的。。 "))
        assertEquals("Version 1.0.14 works.", OpenRouter.cleanup("Version 1.0.14 works."))
    }

    @Test
    fun parsesTranscriptAndFriendlyErrors() {
        assertEquals("hello", OpenRouter.parseTranscription(200, """{"text":" hello "}"""))
        fun error(status: Int, body: String = "") =
            assertThrows(DictationError::class.java) { OpenRouter.parseTranscription(status, body) }.message
        assertEquals("The cloud service rejected the API key — check it in Settings.", error(401))
        assertEquals("The cloud account is out of credits.", error(402))
        assertEquals("The cloud account needs to be set up before this model can be used.", error(403))
        assertEquals("Rate limited", error(429, """{"error":{"message":"Rate limited"}}"""))
        assertEquals("Transcription failed (HTTP 500).", error(500, "<html>"))
    }

    @Test
    fun multipartBody() {
        val (body, boundary) = OpenRouter.multipart("qwen/qwen3-asr-1.7b", byteArrayOf(1, 2, 3), "d.wav")
        val text = String(body, Charsets.ISO_8859_1)
        assertTrue(text.startsWith("--$boundary\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nqwen/qwen3-asr-1.7b\r\n"))
        assertTrue(text.contains("name=\"file\"; filename=\"d.wav\"\r\nContent-Type: audio/wav\r\n\r\n\u0001\u0002\u0003\r\n--$boundary--\r\n"))
    }

    @Test
    fun polishRequestIsTheMacAppsRequest() = runTest {
        val http = FakeHttp { _, _, _ -> FakeHttp.chat(" Cleaned. ") }
        val setup = TestFiles.setups.first()
        val reply = OpenRouter(http, "sk-test").polish("um hi", setup.polish, setup.promptText, setup.wrap)
        assertEquals(" Cleaned. ", reply)  // trimmed by the caller, as in PolishService
        val (url, headers, body) = http.requests.single()
        assertEquals("https://openrouter.ai/api/v1/chat/completions", url)
        assertEquals("Bearer sk-test", headers["Authorization"])
        assertEquals("application/json", headers["Content-Type"])
        val json = JSONObject(String(body))
        assertEquals("deepseek/deepseek-v4.1-flash", json.getString("model"))
        assertEquals(0, json.getInt("temperature"))
        assertFalse(json.getJSONObject("reasoning").getBoolean("enabled"))
        assertEquals("Together", json.getJSONObject("provider").getJSONArray("order").getString(0))
        assertEquals("DeepInfra", json.getJSONObject("provider").getJSONArray("order").getString(1))
        assertFalse(json.getJSONObject("provider").getBoolean("allow_fallbacks"))
        val messages = json.getJSONArray("messages")
        assertEquals(setup.promptText, messages.getJSONObject(0).getString("content"))
        assertEquals("<transcript>\num hi\n</transcript>", messages.getJSONObject(1).getString("content"))
    }

    @Test
    fun reasoningIsOffOrMinimal() {
        assertFalse(OpenRouter.reasoning("deepseek/deepseek-v4.1-flash").getBoolean("enabled"))
        assertEquals("minimal", OpenRouter.reasoning("openai/gpt-oss-120b").getString("effort"))
    }

    @Test
    fun polishErrorsCarryOpenRoutersMessage() {
        assertEquals("No endpoints", assertThrows(DictationError::class.java) {
            OpenRouter.parsePolish(404, """{"error":{"message":"No endpoints"}}""")
        }.message)
        assertEquals("Polish failed (HTTP 502).", assertThrows(DictationError::class.java) { OpenRouter.parsePolish(502, "") }.message)
    }

    @Test
    fun networkFailuresBecomeAMessage() {
        val http = Http { _, _, _ -> throw java.net.UnknownHostException("openrouter.ai") }
        val error = assertThrows(DictationError::class.java) {
            kotlinx.coroutines.runBlocking { OpenRouter(http, "k").transcribe(byteArrayOf(), "m") }
        }
        assertEquals("Network error: openrouter.ai", error.message)
    }
}
