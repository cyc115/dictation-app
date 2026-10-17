package app.dictation.keyboard

/** The keyboard's panels, picked in its top bar: dictation, English keys, pinyin keys. */
enum class Mode { VOICE, ENGLISH, PINYIN }

/** What a key does. */
sealed interface KeyAction {
    /** Types `text` (a letter goes through swipe, suggestions and pinyin). */
    data class Text(val text: String) : KeyAction
    data object Shift : KeyAction
    data object Delete : KeyAction
    data object Enter : KeyAction
    data object Space : KeyAction
    /** Switches the key grid: letters, symbols, more symbols. */
    data class Page(val page: Int) : KeyAction
    /** Dictate now: one tap from any layout. */
    data object Mic : KeyAction
}

/** `width` in key units (a letter key is 1); a row is centered when it's narrower than 10. */
data class Key(val label: String, val action: KeyAction, val width: Float = 1f) {
    val letter: Char? get() = (action as? KeyAction.Text)?.text?.singleOrNull()?.takeIf { it in 'a'..'z' }
}

object Layouts {
    const val LETTERS = 0
    const val SYMBOLS = 1
    const val MORE_SYMBOLS = 2

    private fun keys(chars: String) = chars.map { Key(it.toString(), KeyAction.Text(it.toString())) }

    /** The key grid for `mode` (English or pinyin) and `page`. */
    fun grid(mode: Mode, page: Int): List<List<Key>> {
        val chinese = mode == Mode.PINYIN
        val comma = if (chinese) "，" else ","
        val period = if (chinese) "。" else "."
        val bottom = listOf(
            Key(if (page == LETTERS) "?123" else "ABC", KeyAction.Page(if (page == LETTERS) SYMBOLS else LETTERS), 1.5f),
            Key("mic", KeyAction.Mic),
            Key(comma, KeyAction.Text(comma)),
            Key(if (chinese) "拼音" else "English", KeyAction.Space, 4f),
            Key(period, KeyAction.Text(period)),
            Key("enter", KeyAction.Enter, 1.5f),
        )
        val delete = Key("delete", KeyAction.Delete, 1.5f)
        return when (page) {
            LETTERS -> listOf(
                keys("qwertyuiop"),
                keys("asdfghjkl"),
                listOf(Key("shift", KeyAction.Shift, 1.5f)) + keys("zxcvbnm") + delete,
                bottom,
            )
            SYMBOLS -> listOf(
                keys("1234567890"),
                keys(if (chinese) "@#¥%&-+（）" else "@#$%&-+()"),
                listOf(Key("=\\<", KeyAction.Page(MORE_SYMBOLS), 1.5f)) +
                    keys(if (chinese) "*“”：；！？" else "*\"':;!?") + delete,
                bottom,
            )
            else -> listOf(
                keys("~`|•√π÷×¶∆"),
                keys(if (chinese) "、…·《》【】_/" else "£€¥^°={}\\"),
                listOf(Key("?123", KeyAction.Page(SYMBOLS), 1.5f)) +
                    keys(if (chinese) "‘’「」『』~" else "©®™[]<>") + delete,
                bottom,
            )
        }
    }
}
