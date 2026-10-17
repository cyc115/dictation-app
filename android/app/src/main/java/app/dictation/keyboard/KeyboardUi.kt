package app.dictation.keyboard

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.util.TypedValue
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.TextView

/**
 * The whole keyboard: the top bar (name, then the voice / EN / 拼 switch), and below it either the
 * voice panel or the candidate bar over the keys. `render()` redraws it from the controller.
 */
@SuppressLint("ViewConstructor")
class KeyboardUi(
    context: Context,
    private val controller: KeyboardController,
    private val prefs: Prefs,
    private val openSettings: () -> Unit,
) : LinearLayout(context) {
    private val density = resources.displayMetrics.density
    private fun dp(v: Float) = (v * density).toInt()

    val topBar = TopBar(context) { mode -> controller.selectMode(mode) }
    val candidates = CandidateBar(context) { controller.pick(it) }
    val keys = KeyGridView(context, object : KeyGridView.Listener {
        override fun onKey(key: Key) = controller.onKey(key)
        override fun onSwipe(xs: FloatArray, ys: FloatArray) = controller.onSwipe(xs, ys)
        override fun onLettersLaidOut(centers: Map<Char, Pair<Float, Float>>, keyWidth: Float, rowHeight: Float) =
            controller.lettersLaidOut(centers, keyWidth, rowHeight)
        override val swipeEnabled get() = controller.swipeEnabled
    })
    val voice = VoicePanel(context, object : VoicePanel.Listener {
        override fun onMic() {
            if (controller.voice.state is VoiceState.NeedsSetup) openSettings() else controller.micTapped()
        }
        override fun onCancel() = controller.voice.cancel()
        override fun onDelete() = controller.onKey(Key("delete", KeyAction.Delete))
        override fun onPolishToggle() { prefs.polishEnabled = !prefs.polishEnabled; render() }
        override fun onEnter() = controller.onKey(Key("enter", KeyAction.Enter))
        override fun onSpace() = controller.onKey(Key("space", KeyAction.Space))
    })
    private val keysPanel = LinearLayout(context).apply {
        orientation = VERTICAL
        addView(candidates, LayoutParams(LayoutParams.MATCH_PARENT, dp(44f)))
        addView(keys, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
    }

    init {
        orientation = VERTICAL
        setBackgroundColor(Palette.BACKGROUND)
        topBar.onBrandTap = openSettings
        addView(topBar, LayoutParams(LayoutParams.MATCH_PARENT, dp(52f)))
        val content = FrameLayout(context)
        content.addView(keysPanel, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT))
        // Same height as the keys, so switching panels never resizes the app above.
        content.addView(voice, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, dp(44f + 4 * 54f + 8f)))
        addView(content, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        render()
    }

    fun render() {
        val mode = controller.mode
        topBar.mode = mode
        topBar.voiceEnabled = !controller.secure
        val voiceShown = mode == Mode.VOICE
        voice.visibility = if (voiceShown) VISIBLE else INVISIBLE
        keysPanel.visibility = if (voiceShown) INVISIBLE else VISIBLE
        voice.state = controller.voice.state
        voice.polishOn = prefs.polishEnabled
        val enterLabel = controller.editor?.enterLabel.orEmpty()
        voice.enterLabel = enterLabel
        keys.rows = Layouts.grid(if (mode == Mode.VOICE) Mode.ENGLISH else mode, controller.page)
        keys.shift = controller.shift
        keys.uppercase = controller.shift != Shift.OFF
        keys.enterLabel = enterLabel
        keys.micEnabled = !controller.secure
        candidates.show(controller.suggestions, highlightFirst = controller.composing.isNotEmpty() ||
            controller.suggestions.firstOrNull()?.kind == Suggestion.Kind.ALTERNATIVE)
    }
}

/** The name (tap: Settings) and the voice / EN / 拼 switch. */
@SuppressLint("ViewConstructor")
class TopBar(context: Context, private val onMode: (Mode) -> Unit) : View(context) {
    var mode = Mode.VOICE
        set(value) { field = value; invalidate() }
    var voiceEnabled = true
        set(value) { field = value; invalidate() }
    var onBrandTap: () -> Unit = {}

    private val density = resources.displayMetrics.density
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER }
    private val brandPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { typeface = Typeface.DEFAULT_BOLD; color = Palette.TEXT }

    private fun dp(v: Float) = v * density
    private fun sp(v: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, v, resources.displayMetrics)

    /** The switch's segment for each mode. */
    fun segment(mode: Mode): RectF {
        val segW = dp(52f); val h = dp(36f)
        val right = width - dp(12f)
        val i = Mode.entries.indexOf(mode)
        val left = right - segW * (Mode.entries.size - i)
        return RectF(left, height / 2f - h / 2, left + segW, height / 2f + h / 2)
    }

    override fun onDraw(canvas: Canvas) {
        canvas.drawColor(Palette.BACKGROUND)
        val icon = RectF(dp(14f), height / 2f - dp(10f), dp(34f), height / 2f + dp(10f))
        paint.color = Palette.TEXT
        Icons.bars(canvas, icon, paint)
        brandPaint.textSize = sp(18f)
        canvas.drawText("Dictation", dp(42f), height / 2f - (brandPaint.ascent() + brandPaint.descent()) / 2, brandPaint)

        val first = segment(Mode.entries.first()); val last = segment(Mode.entries.last())
        val track = RectF(first.left - dp(3f), first.top - dp(3f), last.right + dp(3f), last.bottom + dp(3f))
        paint.style = Paint.Style.FILL
        paint.color = Palette.KEY_SPECIAL
        canvas.drawRoundRect(track, track.height() / 2, track.height() / 2, paint)
        for (m in Mode.entries) {
            val seg = segment(m)
            if (m == mode) {
                paint.color = Palette.KEY_PRESSED
                canvas.drawRoundRect(seg, seg.height() / 2, seg.height() / 2, paint)
            }
            val color = when {
                m == Mode.VOICE && !voiceEnabled -> Palette.KEY
                m == mode -> Palette.TEXT
                else -> Palette.TEXT_DIM
            }
            if (m == Mode.VOICE) {
                paint.color = color
                Icons.bars(canvas, RectF(seg.centerX() - dp(11f), seg.centerY() - dp(9f), seg.centerX() + dp(11f), seg.centerY() + dp(9f)), paint)
                paint.style = Paint.Style.FILL
            } else {
                textPaint.textSize = sp(16f); textPaint.color = color
                canvas.drawText(if (m == Mode.ENGLISH) "EN" else "拼", seg.centerX(),
                    seg.centerY() - (textPaint.ascent() + textPaint.descent()) / 2, textPaint)
            }
        }
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked != MotionEvent.ACTION_UP) return true
        val tapped = Mode.entries.firstOrNull { segment(it).contains(event.x, event.y) }
        when {
            tapped != null -> { performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP); onMode(tapped) }
            event.x < dp(140f) -> onBrandTap()
        }
        return true
    }
}

/** Suggestions, swipe alternatives and Chinese candidates, scrolling sideways. */
@SuppressLint("ViewConstructor")
class CandidateBar(context: Context, private val onPick: (Suggestion) -> Unit) : HorizontalScrollView(context) {
    private val row = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
    var shown: List<Suggestion> = emptyList()
        private set

    init {
        isHorizontalScrollBarEnabled = false
        setBackgroundColor(Palette.BACKGROUND)
        addView(row, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.MATCH_PARENT))
    }

    fun show(suggestions: List<Suggestion>, highlightFirst: Boolean) {
        if (suggestions == shown) return
        shown = suggestions
        row.removeAllViews()
        suggestions.forEachIndexed { i, s ->
            row.addView(TextView(context).apply {
                text = s.text
                textSize = 18f
                setTextColor(if (i == 0 && highlightFirst) Palette.ACCENT else Palette.TEXT)
                gravity = Gravity.CENTER
                val pad = (14 * resources.displayMetrics.density).toInt()
                setPadding(pad, 0, pad, 0)
                setOnClickListener { performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP); onPick(s) }
            }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.MATCH_PARENT))
        }
        scrollTo(0, 0)
    }
}
