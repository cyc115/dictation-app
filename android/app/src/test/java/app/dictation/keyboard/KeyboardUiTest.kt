package app.dictation.keyboard

import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Looper
import android.os.SystemClock
import android.text.InputType
import android.view.MotionEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File
import java.time.Duration

/**
 * The keyboard as you'd use it: its real views, touched with MotionEvents, typing into a real
 * EditText through the InputConnection the service uses, with a fake mic and a scripted
 * OpenRouter. Each test also saves a screenshot to app/build/screenshots/.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w411dp-h891dp-xxhdpi")
class KeyboardUiTest {
    private val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
    private val mic = FakeMic()
    private val secrets = MemorySecrets("sk-or-test")
    private var settingsOpened = 0
    private val asked = mutableListOf<String>()
    private val http = FakeHttp { url, model, body ->
        asked += model
        if (url == OpenRouter.TRANSCRIPTIONS) FakeHttp.transcript("um so the file is in the docs folder no wait the assets folder")
        else {
            val transcript = JSONObject(String(body)).getJSONArray("messages").getJSONObject(1).getString("content")
            check(transcript.startsWith("<transcript>")) { "polish gets the wrapped transcript" }
            FakeHttp.chat("So the file is in the assets folder.")
        }
    }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val prefs = Prefs(activity.getSharedPreferences("ui-test", Context.MODE_PRIVATE))
    private val keyboard = Keyboard(activity, prefs, secrets, mic, http, { true }, { settingsOpened++ }, scope, scope)
    private lateinit var field: EditText
    private lateinit var ui: KeyboardUi

    init { keyboard.loadDictionaries(async = false) }

    private fun open(inputType: Int = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES, imeOptions: Int = 0) {
        field = EditText(activity).apply { this.inputType = inputType; this.imeOptions = imeOptions }
        ui = keyboard.createUi()
        activity.setContentView(LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            addView(field, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
            addView(ui)
        })
        field.requestFocus()  // the keyboard serves the focused field (key events go to it)
        idle()
        val info = EditorInfo()
        val connection = field.onCreateInputConnection(info)
        keyboard.controller.startInput(ConnectionEditor({ connection }, { info }))
        idle()
    }

    @After
    fun tearDown() = scope.cancel()

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    private val text get() = field.text.toString()

    // MARK: touching the views

    private fun touch(view: View, x: Float, y: Float, action: Int, downTime: Long) {
        val e = MotionEvent.obtain(downTime, SystemClock.uptimeMillis(), action, x, y, 0)
        view.dispatchTouchEvent(e)
        e.recycle()
    }

    private fun tap(view: View, x: Float, y: Float) {
        val t = SystemClock.uptimeMillis()
        touch(view, x, y, MotionEvent.ACTION_DOWN, t)
        touch(view, x, y, MotionEvent.ACTION_UP, t)
        idle()
    }

    private fun tapKey(label: String) {
        val (x, y) = ui.keys.centerOf(label) ?: error("no key $label")
        tap(ui.keys, x, y)
    }

    private fun typeKeys(letters: String) = letters.forEach { tapKey(it.toString()) }

    private fun tapButton(button: VoicePanel.Button) = ui.voice.bounds(button).let { tap(ui.voice, it.centerX(), it.centerY()) }

    private fun selectMode(mode: Mode) = ui.topBar.segment(mode).let { tap(ui.topBar, it.centerX(), it.centerY()) }

    /** A finger drawn through the letters' keys, as `SwipeTest` draws it but on the real layout. */
    private fun swipe(letters: String) {
        val points = letters.map { ui.keys.centerOf(it.toString())!! }
        val t = SystemClock.uptimeMillis()
        touch(ui.keys, points[0].first, points[0].second, MotionEvent.ACTION_DOWN, t)
        for (i in 1 until points.size) for (s in 1..8) {
            val f = s / 8f
            touch(ui.keys, points[i - 1].first + f * (points[i].first - points[i - 1].first),
                points[i - 1].second + f * (points[i].second - points[i - 1].second), MotionEvent.ACTION_MOVE, t)
        }
        touch(ui.keys, points.last().first, points.last().second, MotionEvent.ACTION_UP, t)
        idle()
    }

    private val candidateTexts get() = ui.candidates.shown.map { it.text }

    private fun tapCandidate(text: String) {
        val row = ui.candidates.getChildAt(0) as LinearLayout
        (0 until row.childCount).map { row.getChildAt(it) as TextView }.first { it.text == text }.performClick()
        idle()
    }

    private fun screenshot(name: String) {
        val bitmap = Bitmap.createBitmap(ui.width, ui.height, Bitmap.Config.ARGB_8888)
        ui.draw(Canvas(bitmap))
        TestFiles.screenshots.mkdirs()
        File(TestFiles.screenshots, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    // MARK: dictation

    @Test
    fun opensOnTapToSpeak() {
        open(imeOptions = EditorInfo.IME_ACTION_GO)
        assertEquals(Mode.VOICE, keyboard.controller.mode)
        assertEquals(View.VISIBLE, ui.voice.visibility)
        assertEquals("Tap to speak", ui.voice.status)
        assertEquals("go", ui.voice.enterLabel)
        screenshot("voice-idle")
    }

    @Test
    fun oneTapDictatesAndTypesThePolishedText() {
        open()
        tapButton(VoicePanel.Button.MIC)
        assertTrue(mic.listening)
        repeat(5) { mic.level(0.2f * it) }
        idle()
        assertEquals("Listening… tap to finish", ui.voice.status)
        screenshot("voice-listening")

        tapButton(VoicePanel.Button.MIC)
        idle()
        assertFalse(mic.listening)
        assertEquals("So the file is in the assets folder.", text)
        assertEquals(listOf("qwen/qwen3-asr-1.7b", "deepseek/deepseek-v4.1-flash"), asked)  // Cloud Flash, polish on by default
        assertEquals("Tap to speak", ui.voice.status)
    }

    @Test
    fun polishButtonTurnsPolishOff() {
        open()
        tapButton(VoicePanel.Button.POLISH)
        assertFalse(prefs.polishEnabled)
        tapButton(VoicePanel.Button.MIC); tapButton(VoicePanel.Button.MIC); idle()
        assertEquals("um so the file is in the docs folder no wait the assets folder", text)
        assertEquals(listOf("qwen/qwen3-asr-1.7b"), asked)
        screenshot("voice-polish-off")
    }

    @Test
    fun cancelTypesNothing() {
        open()
        tapButton(VoicePanel.Button.MIC)
        tapButton(VoicePanel.Button.CANCEL)
        assertEquals(1, mic.cancelled)
        assertEquals("", text)
        assertEquals(listOf<String>(), asked)
    }

    @Test
    fun silenceIsReportedNotUploaded() {
        open()
        mic.silent = true
        tapButton(VoicePanel.Button.MIC); tapButton(VoicePanel.Button.MIC)
        assertEquals(VoiceSession.SILENCE, ui.voice.status)
        assertEquals(listOf<String>(), asked)
        screenshot("voice-silence")
    }

    @Test
    fun withoutAnApiKeyTheButtonOpensSettings() {
        secrets.apiKey = null
        open()
        tapButton(VoicePanel.Button.MIC)
        assertFalse(mic.listening)
        assertTrue(ui.voice.status.startsWith("Add your OpenRouter API key"))
        screenshot("voice-needs-key")
        tapButton(VoicePanel.Button.MIC)
        assertEquals(1, settingsOpened)
    }

    @Test
    fun micKeyDictatesFromTheKeysAndComesBack() {
        open()
        selectMode(Mode.ENGLISH)
        typeKeys("ok")
        tapKey("mic")
        assertEquals(Mode.VOICE, keyboard.controller.mode)
        assertTrue(mic.listening)
        tapButton(VoicePanel.Button.MIC); idle()
        assertEquals("Ok So the file is in the assets folder.", text)  // a space before the dictation
        assertEquals(Mode.ENGLISH, keyboard.controller.mode)
        assertEquals(Mode.ENGLISH, prefs.mode)
    }

    @Test
    fun theMicKeyNeverDropsADictationStillBeingTranscribed() {
        val slow = Keyboard(activity, prefs, secrets, mic, { _, _, _ -> kotlinx.coroutines.awaitCancellation() },
            { true }, {}, scope, scope).apply { loadDictionaries(async = false) }
        val editor = ConnectionEditor({ null }, { null })
        slow.controller.startInput(editor)
        slow.voice.start(); slow.voice.toggle(); idle()
        assertEquals(VoiceState.Transcribing, slow.voice.state)
        slow.voice.start()
        assertEquals(VoiceState.Transcribing, slow.voice.state)
        assertFalse(mic.listening)
    }

    @Test
    fun hidingTheKeyboardStopsTheMic() {
        open()
        tapButton(VoicePanel.Button.MIC)
        keyboard.controller.finishInput(); idle()
        assertFalse(mic.listening)
        assertEquals(1, mic.cancelled)
    }

    @Test
    fun passwordFieldsNeverDictate() {
        open(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD)
        assertEquals(Mode.ENGLISH, keyboard.controller.mode)
        selectMode(Mode.VOICE)
        assertEquals(Mode.ENGLISH, keyboard.controller.mode)
        tapKey("mic")
        assertFalse(mic.listening)
        typeKeys("abc")
        assertEquals("abc", text)
        assertEquals(listOf<String>(), candidateTexts)  // no suggestions from what you type here
    }

    // MARK: English

    @Test
    fun typesWithACapitalAtTheStartAndCompletes() {
        open()
        selectMode(Mode.ENGLISH)
        typeKeys("becau")
        assertEquals("Becau", text)
        assertEquals("Because", candidateTexts.first())
        screenshot("english-typing")
        tapCandidate("Because")
        assertEquals("Because ", text)
        tapKey("delete"); tapKey("delete")
        assertEquals("Becaus", text)
    }

    @Test
    fun swipeTypesWordsWithSpacesBetween() {
        open()
        selectMode(Mode.ENGLISH)
        swipe("hello")
        swipe("world")
        assertEquals("Hello world", text)
        assertEquals("world", candidateTexts.first())
        screenshot("english-swipe")
        tapKey("delete")
        assertEquals("Hello", text)  // a swiped word goes in one press
    }

    @Test
    fun deleteRemovesAWholeEmojiAndASelection() {
        open(InputType.TYPE_CLASS_TEXT)
        selectMode(Mode.ENGLISH)
        field.setText("ok 👍🏽"); field.setSelection(field.length())
        tapKey("delete")
        assertEquals("ok ", text)
        field.setText("hello world"); field.setSelection(0, 6)
        tapKey("delete")
        assertEquals("world", text)
    }

    @Test
    fun anAlternativeReplacesTheSwipedWord() {
        open()
        selectMode(Mode.ENGLISH)
        swipe("thanks")
        val other = candidateTexts.drop(1).first()
        tapCandidate(other)
        assertEquals(other, text)
    }

    @Test
    fun shiftAndSymbols() {
        open(InputType.TYPE_CLASS_TEXT)  // no automatic capitals
        selectMode(Mode.ENGLISH)
        tapKey("shift"); typeKeys("ab")
        tapKey("?123"); tapKey("1"); tapKey("ABC"); tapKey("space"); tapKey("c")
        assertEquals("Ab1 c", text)
        tapKey("?123")
        screenshot("symbols")
    }

    // MARK: 拼音

    @Test
    fun pinyinTurnsIntoChinese() {
        open()
        selectMode(Mode.PINYIN)
        typeKeys("nihao")
        assertEquals("nihao", text)  // in progress, underlined in the field
        assertEquals("你好", candidateTexts.first())
        screenshot("pinyin")
        tapKey("space")
        assertEquals("你好", text)
        tapKey("，")
        assertEquals("你好，", text)
    }

    @Test
    fun pinyinPartsCanBeChosenOneAtATime() {
        open()
        selectMode(Mode.PINYIN)
        typeKeys("womenhao")
        tapCandidate("我们")
        assertEquals("我们hao", text)
        tapKey("space")
        assertEquals("我们好", text)
    }

    @Test
    fun pinyinSwipe() {
        open()
        selectMode(Mode.PINYIN)
        swipe("women")
        assertTrue(candidateTexts.toString(), "我们" in candidateTexts.take(3))
        screenshot("pinyin-swipe")
        tapCandidate("我们")
        assertEquals("我们", text)
    }

    @Test
    fun enterKeepsPinyinLettersAsTyped() {
        open()
        selectMode(Mode.PINYIN)
        typeKeys("abc")
        tapKey("enter")
        assertEquals("abc", text)
    }
}
