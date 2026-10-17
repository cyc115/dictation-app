package app.dictation.keyboard

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Recording → speech → polish, through the real OpenRouter requests with a scripted server (the Mac app's BackupTests). */
class DictationTest {
    private val flash = TestFiles.setups.first { it.id == "cloud-flash" }
    private val main = "qwen/qwen3-asr-1.7b"
    private val backupModel = "qwen/qwen3-asr-0.6b"
    private val polishModel = "deepseek/deepseek-v4.1-flash"
    private val wav = Wav.encode(ByteArray(32_000))

    /** A server answering each model after its delay; models without a script never answer. */
    private class Server(val scripts: Map<String, Pair<Long, HttpResponse>>) {
        val asked = mutableListOf<Pair<String, Long>>()
        fun http(scope: TestScope) = FakeHttp { _, model, _ ->
            asked += model to scope.currentTime
            val (ms, response) = scripts[model] ?: (Long.MAX_VALUE / 2 to HttpResponse(500, ""))
            delay(ms)
            response
        }
    }

    private suspend fun TestScope.dictate(server: Server, adaptive: AdaptiveBackup = AdaptiveBackup(clock = { currentTime / 1000.0 }),
                                          polish: Boolean = true, backupWhenSlow: Boolean = true): DictationResult {
        val judges = CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler))
        try {
            return Dictation(server.http(this), adaptive, judges).run(wav, flash, "sk", polish, backupWhenSlow)
        } finally {
            advanceTimeBy(10_000); runCurrent()
            judges.cancel()
        }
    }

    @Test
    fun transcribesThenPolishes() = runTest {
        val server = Server(mapOf(
            main to (400L to FakeHttp.transcript("um the file is in the docs folder no wait the assets folder")),
            polishModel to (300L to FakeHttp.chat("The file is in the assets folder.\n")),
        ))
        val r = dictate(server)
        assertEquals("The file is in the assets folder.", r.text)
        assertEquals("um the file is in the docs folder no wait the assets folder", r.raw)
        assertNull(r.polishError)
        assertEquals(listOf(main, polishModel), server.asked.map { it.first })
    }

    @Test
    fun polishOffTypesWhatWasHeard() = runTest {
        val server = Server(mapOf(main to (100L to FakeHttp.transcript("hello"))))
        assertEquals(DictationResult("hello", "hello"), dictate(server, polish = false))
        assertEquals(listOf(main), server.asked.map { it.first })
    }

    @Test
    fun polishFailureKeepsYourWordsAndSaysWhy() = runTest {
        val server = Server(mapOf(
            main to (100L to FakeHttp.transcript("hello there")),
            polishModel to (50L to HttpResponse(503, """{"error":{"message":"Provider down"}}""")),
        ))
        val r = dictate(server)
        assertEquals("hello there", r.text)
        assertEquals("Provider down", r.polishError)
    }

    @Test
    fun slowPolishGivesYourWordsAtTheDeadline() = runTest {
        val server = Server(mapOf(main to (100L to FakeHttp.transcript("hello there"))))  // polish never answers
        val r = dictate(server)
        assertEquals("hello there", r.text)
        assertEquals("No answer within 6 s.", r.polishError)
        assertEquals(listOf(main, polishModel, polishModel), server.asked.map { it.first })  // main host, then the backup host
    }

    @Test
    fun slowSpeechIsRacedByTheBackupAfterItsWait() = runTest {
        val server = Server(mapOf(
            main to (5_000L to FakeHttp.transcript("from 1.7b")),
            backupModel to (300L to FakeHttp.transcript("from 0.6b")),
        ))
        val adaptive = AdaptiveBackup(clock = { currentTime / 1000.0 })
        val r = dictate(server, adaptive, polish = false)
        assertEquals("from 0.6b", r.text)
        assertEquals(listOf(main to 0L, backupModel to 2_000L), server.asked)
        assertTrue("late: a slow spell starts", adaptive.inSlowSpell(main))
    }

    @Test
    fun inASpellBothAreAskedAtOnceAndAnOnTimeMainEndsIt() = runTest {
        val adaptive = AdaptiveBackup(clock = { currentTime / 1000.0 })
        adaptive.learn(main, onTime = false)
        val server = Server(mapOf(
            main to (1_200L to FakeHttp.transcript("from 1.7b")),
            backupModel to (200L to FakeHttp.transcript("from 0.6b")),
        ))
        val r = dictate(server, adaptive, polish = false)
        assertEquals("the first answer is still used", "from 0.6b", r.text)
        assertEquals(listOf(main to 0L, backupModel to 0L), server.asked)
        assertFalse("the main model answered within its wait: spell over", adaptive.inSlowSpell(main))
    }

    @Test
    fun backupOffAsksOnlyTheMainModel() = runTest {
        val server = Server(mapOf(main to (100L to HttpResponse(401, ""))))
        val e = runCatching { dictate(server, polish = false, backupWhenSlow = false) }.exceptionOrNull()
        assertEquals("The cloud service rejected the API key — check it in Settings.", e?.message)
        assertEquals(listOf(main), server.asked.map { it.first })
    }
}
