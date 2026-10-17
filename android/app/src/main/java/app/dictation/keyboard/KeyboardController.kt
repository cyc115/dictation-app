package app.dictation.keyboard

enum class Shift { OFF, ONCE, LOCKED }

/** A choice in the candidate bar. */
data class Suggestion(val text: String, val kind: Kind, val consumed: Int = 0) {
    enum class Kind {
        /** Chinese for the first `consumed` letters of the pinyin. */
        PINYIN,
        /** Another reading of the word just swiped: replaces it. */
        ALTERNATIVE,
        /** Finishes the English word being typed. */
        COMPLETION,
    }
}

/** The word lists and decoders, loaded off the main thread once (null until then). */
class Dictionaries(
    val english: EnglishWords,
    val pinyin: PinyinEngine,
) {
    val englishSwipe = GestureDecoder(english.gestureEntries())
    val pinyinSwipe = GestureDecoder(pinyin.gestureEntries())

    fun setKeys(centers: Map<Char, Pair<Float, Float>>, keyWidth: Float, rowHeight: Float) {
        englishSwipe.setKeys(centers, keyWidth, rowHeight)
        pinyinSwipe.setKeys(centers, keyWidth, rowHeight)
    }
}

/**
 * What the keys, swipes, candidates and mode switch do to the text field: everything the keyboard
 * decides, with no views, so tests drive it with a real EditText.
 */
class KeyboardController(
    private val prefs: Prefs,
    private val dictionaries: () -> Dictionaries?,
    private val clock: () -> Long = { System.currentTimeMillis() },
) {
    lateinit var voice: VoiceSession
    var editor: Editor? = null
        private set
    var onChange: () -> Unit = {}

    var mode: Mode = Mode.VOICE
        private set
    var page = Layouts.LETTERS
        private set
    var shift = Shift.OFF
        private set
    /** Pinyin typed but not yet turned into Chinese (shown underlined in the field). */
    var composing = ""
        private set
    var suggestions: List<Suggestion> = emptyList()
        private set
    /** The mode to go back to after a dictation started from the mic key. */
    private var returnTo: Mode? = null
    /** The English word just swiped, as typed (with its leading space): an alternative replaces it. */
    private var swiped: String? = null
    private var lastShiftTap = 0L
    private var keyGeometry: Triple<Map<Char, Pair<Float, Float>>, Float, Float>? = null

    val fieldKind get() = editor?.kind ?: FieldKind.TEXT
    /** No dictation (audio to the cloud), suggestions or swipe in password fields. */
    val secure get() = fieldKind == FieldKind.PASSWORD

    fun startInput(editor: Editor) {
        this.editor = editor
        voice.clearMessage()  // a fresh field starts at "Tap to speak" (and re-checks Settings)
        composing = ""
        swiped = null
        returnTo = null
        suggestions = emptyList()
        page = if (editor.kind == FieldKind.NUMBER) Layouts.SYMBOLS else Layouts.LETTERS
        mode = when {
            editor.kind != FieldKind.TEXT -> Mode.ENGLISH
            else -> prefs.mode
        }
        if (shift != Shift.LOCKED) shift = Shift.OFF
        autoCaps()
        onChange()
    }

    fun finishInput() {
        if (voice.state is VoiceState.Listening) voice.cancel()  // the mic is never on with the keyboard hidden
        if (composing.isNotEmpty()) { editor?.finishComposing(); composing = "" }
        suggestions = emptyList()
        swiped = null
    }

    /** The cursor moved somewhere the keyboard didn't put it: in-progress pinyin stays as typed. */
    fun cursorMoved() {
        if (composing.isNotEmpty()) { editor?.finishComposing(); composing = "" }
        swiped = null
        suggestions = emptyList()
        onChange()
    }

    fun selectMode(mode: Mode) {
        if (mode == Mode.VOICE && secure) return
        commitComposing()
        if (this.mode == Mode.VOICE && mode != Mode.VOICE && voice.state is VoiceState.Listening) voice.cancel()
        this.mode = mode
        returnTo = null
        page = Layouts.LETTERS
        suggestions = emptyList()
        if (fieldKind == FieldKind.TEXT) prefs.mode = mode
        autoCaps()
        onChange()
    }

    /** The geometry of the letter keys, for swipe typing. */
    fun lettersLaidOut(centers: Map<Char, Pair<Float, Float>>, keyWidth: Float, rowHeight: Float) {
        keyGeometry = Triple(centers, keyWidth, rowHeight)
        relayKeys()
    }

    /** Gives the swipe decoders the keys' geometry (again, once the word lists have loaded). */
    fun relayKeys() {
        keyGeometry?.let { (centers, w, h) -> dictionaries()?.setKeys(centers, w, h) }
    }

    val swipeEnabled get() = page == Layouts.LETTERS && !secure && mode != Mode.VOICE

    fun onKey(key: Key) {
        val editor = editor ?: return
        when (val action = key.action) {
            is KeyAction.Text -> type(editor, action.text)
            KeyAction.Space -> {
                if (composing.isNotEmpty()) return pick(suggestions.firstOrNull() ?: Suggestion(composing, Suggestion.Kind.PINYIN, composing.length))
                editor.commit(" ")
                swiped = null
                suggestions = emptyList()
                autoCaps()
            }
            KeyAction.Delete -> delete(editor)
            KeyAction.Enter -> {
                if (composing.isNotEmpty()) {
                    editor.commit(composing)  // Enter keeps the letters as typed
                    composing = ""
                } else {
                    editor.enter()
                }
                swiped = null
                suggestions = emptyList()
                autoCaps()
            }
            KeyAction.Shift -> {
                val now = clock()
                shift = when (shift) {
                    Shift.OFF -> Shift.ONCE
                    Shift.ONCE -> if (now - lastShiftTap < DOUBLE_TAP_MS) Shift.LOCKED else Shift.OFF
                    Shift.LOCKED -> Shift.OFF
                }
                lastShiftTap = now
            }
            is KeyAction.Page -> page = action.page
            KeyAction.Mic -> dictateFromKeys()
        }
        onChange()
    }

    private fun type(editor: Editor, text: String) {
        val letter = text.singleOrNull()?.takeIf { it in 'a'..'z' }
        if (mode == Mode.PINYIN && letter != null && shift == Shift.OFF && page == Layouts.LETTERS) {
            composing += letter
            editor.setComposing(composing)
            suggestions = pinyinSuggestions()
            return
        }
        commitComposing()
        val out = if (letter != null && shift != Shift.OFF) text.uppercase() else text
        editor.commit(out)
        if (shift == Shift.ONCE) shift = Shift.OFF
        swiped = null
        suggestions = completions(editor)
        if (letter == null) autoCaps()
    }

    private fun delete(editor: Editor) {
        if (composing.isNotEmpty()) {
            composing = composing.dropLast(1)
            editor.setComposing(composing)
            if (composing.isEmpty()) editor.finishComposing()
            suggestions = pinyinSuggestions()
            return
        }
        val word = swiped
        if (word != null && editor.textBefore(word.length) == word) {
            editor.deleteBefore(word.length)  // a swiped word goes in one press
        } else {
            editor.deleteBackward()
        }
        swiped = null
        suggestions = completions(editor)
        autoCaps()
    }

    fun onSwipe(xs: FloatArray, ys: FloatArray) {
        val editor = editor ?: return
        val dicts = dictionaries() ?: return
        if (!swipeEnabled) return
        if (!dicts.englishSwipe.hasKeys) relayKeys()
        if (mode == Mode.PINYIN) {
            val matches = dicts.pinyinSwipe.decode(xs, ys)
            if (matches.isEmpty()) return
            val wasEmpty = composing.isEmpty()
            composing += matches.first().letters
            editor.setComposing(composing)
            val alternatives = if (!wasEmpty) emptyList() else matches.drop(1).mapNotNull { m ->
                dicts.pinyin.words(m.letters).firstOrNull()?.let { Suggestion(it.word, Suggestion.Kind.PINYIN, composing.length) }
            }
            val own = pinyinSuggestions()
            suggestions = (own.take(3) + alternatives + own.drop(3)).distinctBy { it.text }
        } else {
            val matches = dicts.englishSwipe.decode(xs, ys)
            if (matches.isEmpty()) return
            val words = matches.map { cased(it.word) }.distinct()
            val before = editor.textBefore(1)
            val space = if (before.isNotEmpty() && needsSpaceAfter(before.last())) " " else ""
            editor.commit(space + words.first())
            swiped = space + words.first()
            suggestions = words.map { Suggestion(it, Suggestion.Kind.ALTERNATIVE) }
            if (shift == Shift.ONCE) shift = Shift.OFF
        }
        onChange()
    }

    fun pick(suggestion: Suggestion) {
        val editor = editor ?: return
        when (suggestion.kind) {
            Suggestion.Kind.PINYIN -> {
                if (composing.isEmpty()) return
                composing = composing.drop(suggestion.consumed)
                editor.batch {
                    editor.commit(suggestion.text)  // replaces the pinyin…
                    if (composing.isNotEmpty()) editor.setComposing(composing)  // …and what's left stays in progress
                }
                suggestions = pinyinSuggestions()
            }
            Suggestion.Kind.ALTERNATIVE -> {
                val word = swiped ?: return
                if (editor.textBefore(word.length) != word) return
                val replacement = (if (word.startsWith(" ")) " " else "") + suggestion.text
                editor.batch { editor.deleteBefore(word.length); editor.commit(replacement) }
                swiped = replacement
            }
            Suggestion.Kind.COMPLETION -> {
                val typed = currentWord(editor)
                editor.batch { editor.deleteBefore(typed.length); editor.commit(suggestion.text + " ") }
                suggestions = emptyList()
                autoCaps()
            }
        }
        onChange()
    }

    /** The mic key: dictate now, then come back to these keys. */
    private fun dictateFromKeys() {
        if (secure) return
        commitComposing()
        returnTo = mode
        mode = Mode.VOICE
        voice.start()
    }

    fun micTapped() {
        if (secure) return
        commitComposing()
        voice.toggle()
        onChange()
    }

    /** A dictation's text: spaced from the word before it, then back to the keys it started from. */
    fun insertDictation(text: String) {
        val editor = editor ?: return
        commitComposing()
        val before = editor.textBefore(1)
        val first = text.first()
        val spaced = if (before.isNotEmpty() && needsSpaceAfter(before.last()) && first.isLetterOrDigit() && !isCJK(first)) " $text" else text
        editor.commit(spaced)
        swiped = null
        suggestions = emptyList()
        returnToKeys()
    }

    /** After a dictation from the mic key ends (typed or cancelled), the keys come back. */
    fun voiceStateChanged(state: VoiceState) {
        if (state == VoiceState.Idle) returnToKeys()
        onChange()
    }

    private fun returnToKeys() {
        returnTo?.let { mode = it; returnTo = null; autoCaps() }
    }

    private fun commitComposing() {
        if (composing.isEmpty()) return
        editor?.finishComposing()
        composing = ""
        suggestions = emptyList()
    }

    private fun pinyinSuggestions(): List<Suggestion> =
        dictionaries()?.pinyin?.candidates(composing)?.map { Suggestion(it.text, Suggestion.Kind.PINYIN, it.consumed) }.orEmpty()

    private fun completions(editor: Editor): List<Suggestion> {
        if (mode != Mode.ENGLISH || secure) return emptyList()
        val word = currentWord(editor)
        if (word.length < 2) return emptyList()
        return dictionaries()?.english?.completions(word)?.filter { it != word }
            ?.map { Suggestion(it, Suggestion.Kind.COMPLETION) }.orEmpty()
    }

    private fun currentWord(editor: Editor) = editor.textBefore(48).takeLastWhile { it.isLetter() || it == '\'' }

    private fun cased(word: String) = when (shift) {
        Shift.LOCKED -> word.uppercase()
        Shift.ONCE -> word.replaceFirstChar { it.uppercase() }
        Shift.OFF -> word
    }

    /** Shift for the first letter of a sentence (English only: Chinese has no capitals). */
    private fun autoCaps() {
        if (shift == Shift.LOCKED) return
        shift = if (mode != Mode.PINYIN && editor?.capsMode() == true) Shift.ONCE else Shift.OFF
    }

    companion object {
        const val DOUBLE_TAP_MS = 350L

        fun isCJK(c: Char) = c.code in 0x3000..0x303F || c.code in 0x3400..0x9FFF || c.code in 0xF900..0xFAFF || c.code in 0xFF00..0xFFEF

        /** A word typed after `c` gets a space first (not after a space, an opening bracket, or Chinese). */
        fun needsSpaceAfter(c: Char) = !c.isWhitespace() && c !in "([{\"'“‘/@#-" && !isCJK(c)
    }
}
