package app.dictation.keyboard

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.time.Duration.Companion.seconds

/** What a dictation produced: the text to type, what the speech model heard, and why polish didn't run. */
data class DictationResult(val text: String, val raw: String, val polishError: String? = null)

/**
 * From a finished recording to the text to type, as the Mac app's cloud setups do it: speech model
 * (with "Backup model when slow"), then AI polish with its backup and deadline. Polish never holds
 * you up: when it fails or runs out of time, you get your unpolished words.
 *
 * `judges` runs the main speech model's late-or-on-time verdict, which can outlive a dictation the
 * backup won. It must have a SupervisorJob: a failed request there must not cancel the keyboard.
 */
class Dictation(
    private val http: Http,
    private val adaptive: AdaptiveBackup,
    private val judges: CoroutineScope,
) {
    suspend fun run(
        wav: ByteArray,
        setup: Setup,
        apiKey: String,
        polish: Boolean,
        backupWhenSlow: Boolean,
        onPolishing: () -> Unit = {},
    ): DictationResult {
        val client = OpenRouter(http, apiKey)
        val raw = transcribe(client, wav, setup, backupWhenSlow)
        if (!polish || raw.isEmpty()) return DictationResult(raw, raw)
        onPolishing()
        return try {
            DictationResult(polished(client, raw, setup), raw)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            DictationResult(raw, raw, e.message)
        }
    }

    /** The Mac app's UploadRace: the main model, and the backup after its wait (at once in a slow spell) or on failure. */
    private suspend fun transcribe(client: OpenRouter, wav: ByteArray, setup: Setup, backupWhenSlow: Boolean): String {
        val main = setup.speech.id
        val backup = setup.backup.takeIf { backupWhenSlow }
            ?: return client.transcribe(wav, main)
        val mainCall = judges.async { client.transcribe(wav, main) }
        judges.launch {
            val onTime = withTimeoutOrNull(setup.backupWait.seconds) {
                try {
                    mainCall.await(); true
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    false
                }
            } ?: false
            adaptive.learn(main, onTime)
            mainCall.cancel()  // judged: stop it if the backup's answer was used
        }
        return firstAnswer(
            main = { mainCall.await() },
            backup = { client.transcribe(wav, backup) },
            backupAfter = adaptive.delay(main, setup.backupWait),
        ).value
    }

    /** The Mac app's PolishService.answer: polish model, its backup, and the deadline. */
    private suspend fun polished(client: OpenRouter, text: String, setup: Setup): String {
        val reply = firstAnswer(
            main = { client.polish(text, setup.polish, setup.promptText, setup.wrap) },
            backup = setup.polishBackup?.let { model -> { client.polish(text, model, setup.promptText, setup.wrap) } },
            backupAfter = setup.polishBackupWait,
            deadline = setup.polishDeadline,
        ).value.trim()
        return reply.ifEmpty { text }
    }
}
