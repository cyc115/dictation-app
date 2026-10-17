package app.dictation.keyboard

import kotlinx.coroutines.delay
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Mac app's FirstAnswer tests (PolishTests), in virtual time. */
class RaceTest {
    private fun answer(ms: Long, value: String): suspend () -> String = { delay(ms); value }
    private fun failure(ms: Long, message: String): suspend () -> String = { delay(ms); throw DictationError(message) }

    @Test
    fun mainOnTimeNeverAsksTheBackup() = runTest {
        var backupAsked = false
        val a = firstAnswer(answer(500, "main"), { backupAsked = true; "backup" }, backupAfter = 0.8)
        assertEquals("main", a.value)
        assertFalse(a.byBackup)
        assertFalse(backupAsked)
    }

    @Test
    fun lateMainAsksTheBackupAndTheFirstAnswerWins() = runTest {
        val a = firstAnswer(answer(3_000, "main"), answer(300, "backup"), backupAfter = 0.8)
        assertEquals("backup", a.value)
        assertTrue(a.byBackup)
        assertEquals(1_100, currentTime)
    }

    @Test
    fun failedMainAsksTheBackupAtOnce() = runTest {
        val a = firstAnswer(failure(100, "down"), answer(200, "backup"), backupAfter = 0.8)
        assertEquals("backup", a.value)
        assertEquals(300, currentTime)
    }

    @Test
    fun bothFailingReportsTheFirstError() = runTest {
        val e = runCatching { firstAnswer(failure(100, "first"), failure(50, "second"), backupAfter = 0.8) }.exceptionOrNull()
        assertEquals("first", e?.message)
    }

    @Test
    fun deadlineGivesUpInsteadOfWaiting() = runTest {
        val e = runCatching { firstAnswer(answer(10_000, "main"), answer(10_000, "backup"), 0.8, deadline = 6.0) }.exceptionOrNull()
        assertTrue(e is TimedOut)
        assertEquals("No answer within 6 s.", e?.message)
        assertEquals(6_000, currentTime)
    }

    @Test
    fun noBackupOrDeadlineJustWaits() = runTest {
        assertEquals("slow", firstAnswer(answer(20_000, "slow")).value)
        assertThrows(DictationError::class.java) { kotlinx.coroutines.runBlocking { firstAnswer(failure(0, "x")) } }
    }

    @Test
    fun spellsLastFiveMinutesAndOnTimeEndsThemEarly() {
        var now = 0.0
        val backup = AdaptiveBackup(clock = { now })
        assertEquals(2.0, backup.delay("m", 2.0), 0.0)
        backup.learn("m", onTime = false)
        assertEquals(0.0, backup.delay("m", 2.0), 0.0)
        assertFalse(backup.inSlowSpell("other"))
        now = 299.0
        assertTrue(backup.inSlowSpell("m"))
        now = 301.0
        assertFalse(backup.inSlowSpell("m"))
        backup.learn("m", onTime = false)
        backup.learn("m", onTime = true)
        assertFalse(backup.inSlowSpell("m"))
    }
}
