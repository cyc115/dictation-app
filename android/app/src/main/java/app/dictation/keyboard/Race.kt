package app.dictation.keyboard

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.launch
import kotlin.time.Duration.Companion.seconds

class Answer<T>(val value: T, val byBackup: Boolean)

class TimedOut(val seconds: Double) : Exception("No answer within ${"%g".format(seconds).trimEnd('0').trimEnd('.')} s.")

private sealed interface Event<out T> {
    class Answered<T>(val value: T, val byBackup: Boolean) : Event<T>
    class Failed(val error: Exception) : Event<Nothing>
    data object BackupDue : Event<Nothing>
    data object TimeUp : Event<Nothing>
}

/**
 * The first answer from `main`, or from `backup`, asked `backupAfter` seconds in (at once when 0)
 * or as soon as `main` fails. The first success wins and the other is cancelled; if both fail, the
 * first error is thrown; after `deadline` seconds, `TimedOut`. The Mac app's FirstAnswer.race.
 */
suspend fun <T> firstAnswer(
    main: suspend () -> T,
    backup: (suspend () -> T)? = null,
    backupAfter: Double = 0.0,
    deadline: Double? = null,
): Answer<T> = coroutineScope {
    val events = Channel<Event<T>>(Channel.UNLIMITED)
    fun ask(byBackup: Boolean, call: suspend () -> T) = launch {
        events.send(
            try {
                Event.Answered(call(), byBackup)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Event.Failed(e)
            }
        )
    }
    try {
        ask(false, main)
        if (deadline != null) launch { delay(deadline.seconds); events.send(Event.TimeUp) }
        var running = 1
        var backupAsked = false
        var firstError: Exception? = null
        fun askBackup() {
            if (backup == null || backupAsked) return
            backupAsked = true
            running += 1
            ask(true, backup)
        }
        if (backup != null) {
            if (backupAfter <= 0) askBackup() else launch { delay(backupAfter.seconds); events.send(Event.BackupDue) }
        }
        while (true) {
            when (val event = events.receive()) {
                is Event.Answered -> return@coroutineScope Answer(event.value, event.byBackup)
                is Event.Failed -> {
                    running -= 1
                    firstError = firstError ?: event.error
                    askBackup()  // don't wait out the delay after a failure
                    if (running == 0) throw firstError
                }
                Event.BackupDue -> askBackup()
                Event.TimeUp -> throw TimedOut(deadline ?: 0.0)
            }
        }
        @Suppress("UNREACHABLE_CODE")
        throw IllegalStateException()
    } finally {
        coroutineContext.cancelChildren()  // the loser and the timers stop
    }
}

/**
 * "Backup model when slow" (the Mac app's AdaptiveBackup): normally the backup speech model is
 * asked once the main one hasn't answered within its wait; after the main model was late, both are
 * asked at once for `spell`, since the next answers would likely be late too. The main model's own
 * answer within the wait decides late or on time, whoever won. One instance per keyboard, so a slow
 * spell carries over between dictations.
 */
class AdaptiveBackup(
    private val spell: Double = 5 * 60.0,
    private val clock: () -> Double = { System.nanoTime() / 1e9 },
) {
    private val lateAt = mutableMapOf<String, Double>()

    /** Seconds before asking the backup in a dictation with `model`: `wait`, or 0 in a slow spell. */
    @Synchronized
    fun delay(model: String, wait: Double): Double = if (inSlowSpell(model)) 0.0 else wait

    @Synchronized
    fun inSlowSpell(model: String): Boolean = lateAt[model]?.let { clock() - it < spell } ?: false

    /** Whether `model` answered within its wait; failing is late. */
    @Synchronized
    fun learn(model: String, onTime: Boolean) {
        if (onTime) lateAt.remove(model) else lateAt[model] = clock()
    }
}
