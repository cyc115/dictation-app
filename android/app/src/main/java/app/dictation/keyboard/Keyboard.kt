package app.dictation.keyboard

import android.content.Context
import android.os.Handler
import android.os.Looper
import kotlinx.coroutines.CoroutineScope
import kotlin.concurrent.thread

/**
 * Everything the keyboard is made of, wired together: settings, the controller, the dictation
 * session and the views. The service builds one with the real mic and network; tests with fakes.
 */
class Keyboard(
    private val context: Context,
    val prefs: Prefs,
    private val secrets: SecretStore,
    mic: Mic,
    http: Http,
    private val hasMicPermission: () -> Boolean,
    private val openSettings: () -> Unit,
    scope: CoroutineScope,
    /** For verdicts that outlive a dictation; needs a SupervisorJob (see `Dictation`). */
    judges: CoroutineScope,
) {
    private val main = Handler(Looper.getMainLooper())
    val setups: List<Setup> = Setups.load(::asset)
    @Volatile
    var dictionaries: Dictionaries? = null
        private set
    var ui: KeyboardUi? = null
        private set

    val controller = KeyboardController(prefs, { dictionaries })
    val voice = VoiceSession(
        mic = mic,
        dictation = Dictation(http, AdaptiveBackup(), judges),
        scope = scope,
        config = ::config,
        post = { main.post(it) },
        onText = { controller.insertDictation(it) },
        onState = { controller.voiceStateChanged(it) },
    )

    init {
        controller.voice = voice
        controller.onChange = { ui?.render() }
    }

    fun createUi(): KeyboardUi = KeyboardUi(context, controller, prefs, openSettings).also { ui = it }

    /** Reads the word lists (about a second on a phone), on a background thread unless `async` is false. */
    fun loadDictionaries(async: Boolean = true) {
        val load = {
            val loaded = Dictionaries(EnglishWords(asset("dict/en.txt")), PinyinEngine(asset("dict/zh.txt")))
            if (async) main.post { dictionaries = loaded; controller.relayKeys() } else dictionaries = loaded
        }
        if (async) thread(name = "dictionaries") { load() } else load()
    }

    private fun config(): Result<VoiceConfig> {
        val key = secrets.apiKey
        return when {
            !hasMicPermission() -> Result.failure(Exception("Allow the microphone: tap the button to open Settings."))
            key.isNullOrBlank() -> Result.failure(Exception("Add your OpenRouter API key: tap the button to open Settings."))
            else -> Result.success(VoiceConfig(prefs.setup(setups), key, prefs.polishEnabled, prefs.backupWhenSlow))
        }
    }

    private fun asset(path: String): String = context.assets.open(path).bufferedReader().use { it.readText() }
}
