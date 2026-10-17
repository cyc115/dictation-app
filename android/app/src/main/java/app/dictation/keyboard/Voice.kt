package app.dictation.keyboard

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/** Where a dictation is, for the voice panel. */
sealed interface VoiceState {
    data object Idle : VoiceState
    /** `level`: 0…1, the latest loudness. */
    data class Listening(val level: Float) : VoiceState
    data object Transcribing : VoiceState
    data object Polishing : VoiceState
    /** Shown until the next dictation; `error` when nothing was typed. */
    data class Message(val text: String, val error: Boolean) : VoiceState
    /** No API key, or no microphone permission: the keyboard opens Settings. */
    data class NeedsSetup(val text: String) : VoiceState

    val busy get() = this is Listening || this is Transcribing || this is Polishing
}

/** What a dictation needs from Settings. */
class VoiceConfig(val setup: Setup, val apiKey: String, val polish: Boolean, val backupWhenSlow: Boolean)

/**
 * One tap to start, one to finish: records, then hands the audio to `Dictation` and types the
 * result. Runs on the main thread; `mic` levels arrive through `post`.
 */
class VoiceSession(
    private val mic: Mic,
    private val dictation: Dictation,
    private val scope: CoroutineScope,
    /** A failure saying why when a dictation can't start (no key, no permission). */
    private val config: () -> Result<VoiceConfig>,
    private val post: (() -> Unit) -> Unit,
    private val onText: (String) -> Unit,
    private val onState: (VoiceState) -> Unit,
) {
    var state: VoiceState = VoiceState.Idle
        private set(value) { field = value; onState(value) }
    private var job: Job? = null
    /** The settings the current recording will be transcribed with. */
    private var pending: VoiceConfig? = null

    /** Starts listening, or finishes and transcribes what was said. */
    fun toggle() {
        when (state) {
            is VoiceState.Listening -> finish()
            VoiceState.Transcribing, VoiceState.Polishing -> {}  // the pill shows progress; ✕ cancels
            else -> start()
        }
    }

    fun start() {
        if (state.busy) return  // never drop a dictation that's still being transcribed
        val config = config().getOrElse { state = VoiceState.NeedsSetup(it.message ?: ""); return }
        job?.cancel()
        if (!mic.start { level -> post { if (state is VoiceState.Listening) state = VoiceState.Listening(level) } }) {
            state = VoiceState.Message("Couldn't start the microphone. Another app may be using it.", error = true)
            return
        }
        pending = config
        state = VoiceState.Listening(0f)
    }

    private fun finish() {
        val config = pending ?: return cancel()
        val recording = mic.stop()
        when {
            recording.heardOnlySilence -> state = VoiceState.Message(SILENCE, error = true)
            !recording.isSpeech -> state = VoiceState.Idle  // too short to be speech
            else -> {
                state = VoiceState.Transcribing
                job = scope.launch {
                    try {
                        val result = dictation.run(Wav.encode(recording.pcm), config.setup, config.apiKey, config.polish,
                            config.backupWhenSlow, onPolishing = { state = VoiceState.Polishing })
                        if (result.text.isNotEmpty()) onText(result.text)
                        state = result.polishError?.let { VoiceState.Message("Not polished ($it): typed what you said.", error = false) }
                            ?: VoiceState.Idle
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        state = VoiceState.Message(e.message ?: "Transcription failed.", error = true)
                    }
                }
            }
        }
    }

    /** Stops listening or transcribing; nothing is typed. */
    fun cancel() {
        if (state is VoiceState.Listening) mic.cancel()
        job?.cancel()
        job = null
        state = VoiceState.Idle
    }

    /** Leaves a message or a finished state for a fresh "Tap to speak". */
    fun clearMessage() {
        if (!state.busy && state != VoiceState.Idle) state = VoiceState.Idle
    }

    companion object {
        const val SILENCE = "The microphone sent only silence. Check it isn't muted or blocked in Android's privacy settings."
    }
}
