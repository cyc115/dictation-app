package app.dictation.keyboard

import android.icu.text.BreakIterator
import android.text.InputType
import android.view.KeyEvent
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection

/** The text field being typed into. */
interface Editor {
    fun textBefore(chars: Int): String
    fun commit(text: String)
    /** Shows `text` as in-progress input (pinyin), replacing the last; "" clears it. */
    fun setComposing(text: String)
    /** Keeps the in-progress input as typed. */
    fun finishComposing()
    fun deleteBefore(chars: Int)
    /** One press of the delete key (a selection, an emoji, a character). */
    fun deleteBackward()
    /** The field's action (Go, Send, Search…) or a new line. */
    fun enter()
    /** Whether the field wants a capital at the cursor (start of a sentence). */
    fun capsMode(): Boolean
    /** The enter key's label: the field's action, or "" for a plain return. */
    val enterLabel: String
    val kind: FieldKind
    /** Several edits that the app sees as one (no in-between cursor updates). */
    fun batch(edits: () -> Unit) = edits()
}

enum class FieldKind {
    TEXT,
    /** Numbers, phone, dates: open on the number keys. */
    NUMBER,
    /** Never dictated (audio would go to the cloud), never suggested from. */
    PASSWORD,
}

/** `Editor` over the focused field's InputConnection (re-read on every call: it changes with focus). */
class ConnectionEditor(
    private val connection: () -> InputConnection?,
    private val info: () -> EditorInfo?,
) : Editor {
    override fun textBefore(chars: Int) = connection()?.getTextBeforeCursor(chars, 0)?.toString() ?: ""

    override fun commit(text: String) { connection()?.commitText(text, 1) }

    override fun setComposing(text: String) { connection()?.setComposingText(text, 1) }

    override fun finishComposing() { connection()?.finishComposingText() }

    override fun deleteBefore(chars: Int) { connection()?.deleteSurroundingText(chars, 0) }

    /**
     * As AOSP's LatinIME: a selection is cleared, otherwise the last character (a whole emoji or
     * flag) is deleted through the connection; with nothing before the cursor, or in a field that
     * takes raw keys (terminals), the app gets the delete key itself (removing a chip, say).
     */
    override fun deleteBackward() {
        val ic = connection() ?: return
        val before = textBefore(16)
        when {
            !ic.getSelectedText(0).isNullOrEmpty() -> ic.commitText("", 1)
            before.isEmpty() || info()?.inputType == InputType.TYPE_NULL -> key(KeyEvent.KEYCODE_DEL)
            else -> {
                val characters = BreakIterator.getCharacterInstance().apply { setText(before) }
                val start = characters.run { last(); previous() }
                ic.deleteSurroundingText(if (start == BreakIterator.DONE) 1 else before.length - start, 0)
            }
        }
    }

    override fun enter() {
        val ic = connection() ?: return
        val options = info()?.imeOptions ?: 0
        val action = options and EditorInfo.IME_MASK_ACTION
        if (options and EditorInfo.IME_FLAG_NO_ENTER_ACTION == 0 &&
            action != EditorInfo.IME_ACTION_NONE && action != EditorInfo.IME_ACTION_UNSPECIFIED
        ) ic.performEditorAction(action) else key(KeyEvent.KEYCODE_ENTER)
    }

    override fun capsMode(): Boolean {
        val type = info()?.inputType ?: return false
        return type and InputType.TYPE_MASK_CLASS == InputType.TYPE_CLASS_TEXT &&
            (connection()?.getCursorCapsMode(type) ?: 0) != 0
    }

    override val enterLabel: String
        get() {
            val options = info()?.imeOptions ?: return ""
            if (options and EditorInfo.IME_FLAG_NO_ENTER_ACTION != 0) return ""
            return when (options and EditorInfo.IME_MASK_ACTION) {
                EditorInfo.IME_ACTION_GO -> "go"
                EditorInfo.IME_ACTION_SEARCH -> "search"
                EditorInfo.IME_ACTION_SEND -> "send"
                EditorInfo.IME_ACTION_NEXT -> "next"
                EditorInfo.IME_ACTION_DONE -> "done"
                EditorInfo.IME_ACTION_PREVIOUS -> "back"
                else -> ""
            }
        }

    override val kind: FieldKind
        get() {
            val type = info()?.inputType ?: return FieldKind.TEXT
            val variation = type and InputType.TYPE_MASK_VARIATION
            return when (type and InputType.TYPE_MASK_CLASS) {
                InputType.TYPE_CLASS_NUMBER ->
                    if (variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD) FieldKind.PASSWORD else FieldKind.NUMBER
                InputType.TYPE_CLASS_PHONE, InputType.TYPE_CLASS_DATETIME -> FieldKind.NUMBER
                InputType.TYPE_CLASS_TEXT -> when (variation) {
                    InputType.TYPE_TEXT_VARIATION_PASSWORD, InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
                    InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD -> FieldKind.PASSWORD
                    else -> FieldKind.TEXT
                }
                else -> FieldKind.TEXT
            }
        }

    override fun batch(edits: () -> Unit) {
        val ic = connection() ?: return edits()
        ic.beginBatchEdit()
        try { edits() } finally { ic.endBatchEdit() }
    }

    private fun key(code: Int) {
        val ic = connection() ?: return
        ic.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, code))
        ic.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, code))
    }
}
