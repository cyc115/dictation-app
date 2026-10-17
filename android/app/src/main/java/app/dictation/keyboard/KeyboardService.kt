package app.dictation.keyboard

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.inputmethodservice.InputMethodService
import android.view.View
import android.view.inputmethod.EditorInfo
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel

/** The input method Android binds to: hands the system's callbacks to `Keyboard`. */
class KeyboardService : InputMethodService() {
    private val scope = MainScope()
    private val judges = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private lateinit var keyboard: Keyboard

    override fun onCreate() {
        super.onCreate()
        keyboard = Keyboard(
            context = this,
            prefs = Prefs(this),
            secrets = KeystoreSecretStore(this),
            mic = AudioRecordMic(),
            http = UrlConnectionHttp(),
            hasMicPermission = { checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED },
            openSettings = ::openSettings,
            scope = scope,
            judges = judges,
        )
        keyboard.loadDictionaries()
    }

    override fun onCreateInputView(): View = keyboard.createUi()

    override fun onStartInputView(info: EditorInfo, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        keyboard.controller.startInput(ConnectionEditor({ currentInputConnection }, { currentInputEditorInfo }))
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        keyboard.controller.finishInput()
        super.onFinishInputView(finishingInput)
    }

    override fun onUpdateSelection(oldSelStart: Int, oldSelEnd: Int, newSelStart: Int, newSelEnd: Int, candidatesStart: Int, candidatesEnd: Int) {
        super.onUpdateSelection(oldSelStart, oldSelEnd, newSelStart, newSelEnd, candidatesStart, candidatesEnd)
        // In-progress pinyin ends where the cursor is; anywhere else, you moved the cursor away from it.
        if (keyboard.controller.composing.isNotEmpty() && (newSelStart != candidatesEnd || newSelEnd != candidatesEnd)) {
            keyboard.controller.cursorMoved()
        }
    }

    override fun onEvaluateFullscreenMode() = false

    override fun onDestroy() {
        keyboard.voice.cancel()
        scope.cancel()
        judges.cancel()
        super.onDestroy()
    }

    private fun openSettings() {
        requestHideSelf(0)
        startActivity(Intent(this, SettingsActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
