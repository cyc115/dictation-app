package app.dictation.keyboard

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.util.TypedValue
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import kotlin.math.hypot
import kotlin.math.min
import kotlin.math.sin

/**
 * The dictation panel: one big button to start and finish, the status above it, and the few keys
 * you need around a dictation (cancel, delete, AI polish, enter, space).
 */
@SuppressLint("ViewConstructor")
class VoicePanel(context: Context, private val listener: Listener) : View(context) {
    interface Listener {
        fun onMic()
        fun onCancel()
        fun onDelete()
        fun onPolishToggle()
        fun onEnter()
        fun onSpace()
    }

    enum class Button { MIC, CANCEL, DELETE, POLISH, ENTER, SPACE }

    var state: VoiceState = VoiceState.Idle
        set(value) {
            if (value is VoiceState.Listening) levels = levels.drop(1).toFloatArray() + value.level
            else if (field is VoiceState.Listening) levels = FloatArray(BARS)
            field = value
            invalidate()
        }
    var polishOn = true
        set(value) { field = value; invalidate() }
    var enterLabel = ""
        set(value) { field = value; invalidate() }

    private var levels = FloatArray(BARS)
    private val density = resources.displayMetrics.density
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val iconPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val textPaint = TextPaint(Paint.ANTI_ALIAS_FLAG)
    private var pressed: Button? = null
    private val repeat = Handler(Looper.getMainLooper())
    private val repeatDelete = object : Runnable {
        override fun run() { if (pressed == Button.DELETE) { listener.onDelete(); repeat.postDelayed(this, KeyGridView.REPEAT_MS) } }
    }

    private fun dp(v: Float) = v * density
    private fun sp(v: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, v, resources.displayMetrics)

    /** The status line above the button. */
    val status: String
        get() = when (val s = state) {
            VoiceState.Idle -> "Tap to speak"
            is VoiceState.Listening -> "Listening… tap to finish"
            VoiceState.Transcribing -> "Transcribing…"
            VoiceState.Polishing -> "Polishing…"
            is VoiceState.Message -> s.text
            is VoiceState.NeedsSetup -> s.text
        }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) =
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), MeasureSpec.getSize(heightMeasureSpec))

    /** Where each button is, for this size. */
    fun bounds(button: Button): RectF {
        val w = width.toFloat(); val h = height.toFloat()
        val side = dp(52f)
        fun circle(cx: Float, cy: Float) = RectF(cx - side / 2, cy - side / 2, cx + side / 2, cy + side / 2)
        return when (button) {
            Button.MIC -> {
                val pw = min(w * 0.4f, dp(190f)); val ph = dp(62f)
                RectF(w / 2 - pw / 2, h * 0.46f - ph / 2, w / 2 + pw / 2, h * 0.46f + ph / 2)
            }
            Button.CANCEL -> circle(dp(44f), h * 0.6f)
            Button.DELETE -> circle(w - dp(44f), h * 0.6f)
            Button.POLISH -> circle(dp(44f), h * 0.85f)
            Button.SPACE -> circle(w - dp(44f), h * 0.85f)
            Button.ENTER -> {
                val ew = min(w * 0.3f, dp(150f)); val eh = dp(48f)
                RectF(w / 2 - ew / 2, h * 0.85f - eh / 2, w / 2 + ew / 2, h * 0.85f + eh / 2)
            }
        }
    }

    private fun visible(button: Button) = button != Button.CANCEL || state.busy

    override fun onDraw(canvas: Canvas) {
        canvas.drawColor(Palette.BACKGROUND)
        drawStatus(canvas)
        drawMic(canvas, bounds(Button.MIC))
        if (visible(Button.CANCEL)) circleButton(canvas, Button.CANCEL, Palette.KEY_SPECIAL) { b -> Icons.close(canvas, b, iconPaint) }
        circleButton(canvas, Button.DELETE, Palette.KEY_SPECIAL) { b -> Icons.delete(canvas, b, iconPaint) }
        circleButton(canvas, Button.POLISH, if (polishOn) Palette.ACCENT else Palette.KEY_SPECIAL,
            if (polishOn) Palette.TEXT_DARK else Palette.TEXT_DIM) { b -> Icons.polish(canvas, b, iconPaint) }
        circleButton(canvas, Button.SPACE, Palette.KEY_SPECIAL) { b -> spaceIcon(canvas, b) }
        val enter = bounds(Button.ENTER)
        paint.color = if (pressed == Button.ENTER) Palette.KEY_PRESSED else Palette.KEY
        canvas.drawRoundRect(enter, enter.height() / 2, enter.height() / 2, paint)
        if (enterLabel.isEmpty()) {
            iconPaint.color = Palette.TEXT
            Icons.enter(canvas, inset(enter.centerX(), enter.centerY(), dp(11f)), iconPaint)
        } else {
            textPaint.textSize = sp(17f); textPaint.color = Palette.TEXT; textPaint.textAlign = Paint.Align.CENTER
            canvas.drawText(enterLabel, enter.centerX(), enter.centerY() - (textPaint.ascent() + textPaint.descent()) / 2, textPaint)
        }
    }

    private fun drawStatus(canvas: Canvas) {
        val s = state
        textPaint.textSize = sp(16f)
        textPaint.textAlign = Paint.Align.LEFT
        textPaint.color = when {
            s is VoiceState.Message && s.error -> Palette.ERROR
            s is VoiceState.NeedsSetup -> Palette.ACCENT
            else -> Palette.TEXT_DIM
        }
        val width = (width - dp(48f)).toInt().coerceAtLeast(1)
        val layout = StaticLayout.Builder.obtain(status, 0, status.length, textPaint, width)
            .setAlignment(Layout.Alignment.ALIGN_CENTER).setMaxLines(3).build()
        canvas.save()
        canvas.translate(dp(24f), height * 0.17f - layout.height / 2f)
        layout.draw(canvas)
        canvas.restore()
    }

    private fun drawMic(canvas: Canvas, box: RectF) {
        val s = state
        paint.color = when {
            s is VoiceState.Listening -> Palette.RECORDING
            s.busy -> Palette.KEY
            pressed == Button.MIC -> Palette.ACCENT
            else -> Palette.KEY_LIGHT
        }
        canvas.drawRoundRect(box, box.height() / 2, box.height() / 2, paint)
        iconPaint.color = if (s.busy) Palette.TEXT else Palette.TEXT_DARK
        when {
            s is VoiceState.Listening ->
                Icons.bars(canvas, RectF(box.centerX() - dp(30f), box.centerY() - dp(16f), box.centerX() + dp(30f), box.centerY() + dp(16f)), iconPaint, levels)
            s.busy -> {
                // Three dots wave while the models work.
                val t = SystemClock.uptimeMillis() / 160.0
                paint.color = Palette.TEXT
                for (i in 0..2) {
                    val dy = (sin(t - i) * dp(4f)).toFloat()
                    canvas.drawCircle(box.centerX() + (i - 1) * dp(14f), box.centerY() + dy, dp(4f), paint)
                }
                postInvalidateDelayed(32)
            }
            else -> Icons.mic(canvas, inset(box.centerX(), box.centerY(), dp(15f)), iconPaint)
        }
    }

    private inline fun circleButton(canvas: Canvas, button: Button, fill: Int, iconColor: Int = Palette.TEXT, icon: (RectF) -> Unit) {
        val b = bounds(button)
        paint.color = if (pressed == button) Palette.KEY_PRESSED else fill
        canvas.drawCircle(b.centerX(), b.centerY(), b.width() / 2, paint)
        iconPaint.color = iconColor
        icon(inset(b.centerX(), b.centerY(), dp(12f)))
    }

    private fun spaceIcon(canvas: Canvas, box: RectF) {
        iconPaint.style = Paint.Style.STROKE; iconPaint.strokeWidth = box.width() * 0.09f
        val y = box.centerY() + box.height() * 0.15f
        canvas.drawLine(box.left + box.width() * 0.1f, y - box.height() * 0.2f, box.left + box.width() * 0.1f, y, iconPaint)
        canvas.drawLine(box.left + box.width() * 0.1f, y, box.right - box.width() * 0.1f, y, iconPaint)
        canvas.drawLine(box.right - box.width() * 0.1f, y, box.right - box.width() * 0.1f, y - box.height() * 0.2f, iconPaint)
    }

    private fun inset(cx: Float, cy: Float, r: Float) = RectF(cx - r, cy - r, cx + r, cy + r)

    private fun buttonAt(x: Float, y: Float): Button? = Button.entries.firstOrNull { button ->
        if (!visible(button)) return@firstOrNull false
        val b = bounds(button)
        if (button == Button.MIC || button == Button.ENTER) b.contains(x, y)
        else hypot(b.centerX() - x, b.centerY() - y) <= b.width() / 2 + dp(6f)
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                pressed = buttonAt(event.x, event.y)
                if (pressed != null) performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                if (pressed == Button.DELETE) { listener.onDelete(); repeat.postDelayed(repeatDelete, KeyGridView.REPEAT_DELAY_MS) }
                invalidate()
            }
            MotionEvent.ACTION_UP -> {
                val button = pressed
                pressed = null
                repeat.removeCallbacks(repeatDelete)
                if (button != null && buttonAt(event.x, event.y) == button) press(button)
                invalidate()
            }
            MotionEvent.ACTION_CANCEL -> { pressed = null; repeat.removeCallbacks(repeatDelete); invalidate() }
        }
        return true
    }

    private fun press(button: Button) = when (button) {
        Button.MIC -> listener.onMic()
        Button.CANCEL -> listener.onCancel()
        Button.DELETE -> {}  // typed on touch down, repeated while held
        Button.POLISH -> listener.onPolishToggle()
        Button.ENTER -> listener.onEnter()
        Button.SPACE -> listener.onSpace()
    }

    private companion object {
        const val BARS = 5
    }
}
