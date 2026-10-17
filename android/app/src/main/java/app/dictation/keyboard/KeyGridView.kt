package app.dictation.keyboard

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import kotlin.math.hypot

/**
 * The key grid: draws a layout's keys, types on tap, and hands a path that runs from a letter key
 * across the others to swipe typing. A second finger landing types the first finger's key at once,
 * so fast two-thumb typing loses nothing.
 */
@SuppressLint("ViewConstructor")
class KeyGridView(context: Context, private val listener: Listener) : View(context) {
    interface Listener {
        fun onKey(key: Key)
        fun onSwipe(xs: FloatArray, ys: FloatArray)
        fun onLettersLaidOut(centers: Map<Char, Pair<Float, Float>>, keyWidth: Float, rowHeight: Float)
        val swipeEnabled: Boolean
    }

    private class Placed(val key: Key, val rect: RectF)

    var rows: List<List<Key>> = emptyList()
        set(value) { if (field != value) { field = value; placeKeys(); invalidate() } }
    var shift = Shift.OFF
        set(value) { if (field != value) { field = value; invalidate() } }
    var uppercase = false
        set(value) { if (field != value) { field = value; invalidate() } }
    var enterLabel = ""
        set(value) { if (field != value) { field = value; invalidate() } }
    var micEnabled = true
        set(value) { if (field != value) { field = value; invalidate() } }

    private val density = resources.displayMetrics.density
    private val rowHeight = 54 * density
    private val pad = 4 * density
    private val gap = 3 * density
    private var placed = emptyList<Placed>()
    private var keyWidth = 0f

    private val keyPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER }
    private val iconPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val trailPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE; strokeWidth = 6 * density; strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND; color = Palette.TRAIL
    }

    // The finger being tracked.
    private var pointerId = -1
    private var downKey: Key? = null
    private var downX = 0f
    private var downY = 0f
    private var swiping = false
    private val xs = ArrayList<Float>()
    private val ys = ArrayList<Float>()
    private val trail = Path()
    private var pressed: Key? = null

    private val repeat = Handler(Looper.getMainLooper())
    private val repeatDelete = object : Runnable {
        override fun run() {
            downKey?.takeIf { it.action == KeyAction.Delete }?.let { listener.onKey(it); repeat.postDelayed(this, REPEAT_MS) }
        }
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        setMeasuredDimension(width, (rows.size.coerceAtLeast(4) * rowHeight + 2 * pad).toInt())
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) = placeKeys()

    private fun placeKeys() {
        if (width == 0) return
        keyWidth = (width - 2 * pad) / 10f
        placed = rows.flatMapIndexed { r, row ->
            var x = pad + (10 - row.sumOf { it.width.toDouble() }.toFloat()) / 2 * keyWidth
            val top = pad + r * rowHeight
            row.map { key ->
                Placed(key, RectF(x, top, x + key.width * keyWidth, top + rowHeight)).also { x += key.width * keyWidth }
            }
        }
        val centers = placed.mapNotNull { p -> p.key.letter?.let { it to (p.rect.centerX() to p.rect.centerY()) } }.toMap()
        if (centers.size == 26) listener.onLettersLaidOut(centers, keyWidth, rowHeight)
    }

    /** Where a key is drawn (tests tap there): by its label, or "space". */
    fun centerOf(label: String): Pair<Float, Float>? =
        placed.firstOrNull { it.key.label == label || (label == "space" && it.key.action == KeyAction.Space) }
            ?.rect?.let { it.centerX() to it.centerY() }

    override fun onDraw(canvas: Canvas) {
        canvas.drawColor(Palette.BACKGROUND)
        for (p in placed) drawKey(canvas, p)
        if (swiping) canvas.drawPath(trail, trailPaint)
    }

    // Reused on every draw: a swipe redraws the grid each frame.
    private val box = RectF()
    private val icon = RectF()

    private fun drawKey(canvas: Canvas, p: Placed) {
        val key = p.key
        box.set(p.rect.left + gap, p.rect.top + gap, p.rect.right - gap, p.rect.bottom - gap)
        val special = key.action !is KeyAction.Text || key.action == KeyAction.Space
        val enter = key.action == KeyAction.Enter
        keyPaint.color = when {
            key == pressed -> Palette.KEY_PRESSED
            enter -> Palette.KEY_LIGHT
            key.action == KeyAction.Shift && shift != Shift.OFF -> Palette.KEY_PRESSED
            special && key.action != KeyAction.Space -> Palette.KEY_SPECIAL
            else -> Palette.KEY
        }
        canvas.drawRoundRect(box, 8 * density, 8 * density, keyPaint)
        icon.set(box.centerX() - 11 * density, box.centerY() - 11 * density, box.centerX() + 11 * density, box.centerY() + 11 * density)
        iconPaint.color = if (enter) Palette.TEXT_DARK else Palette.TEXT
        when (key.action) {
            KeyAction.Shift -> Icons.shift(canvas, icon, iconPaint, shift)
            KeyAction.Delete -> Icons.delete(canvas, icon, iconPaint)
            KeyAction.Mic -> { iconPaint.color = if (micEnabled) Palette.TEXT else Palette.TEXT_DIM; Icons.mic(canvas, icon, iconPaint) }
            KeyAction.Enter -> if (enterLabel.isEmpty()) Icons.enter(canvas, icon, iconPaint) else label(canvas, box, enterLabel, 16f, Palette.TEXT_DARK)
            KeyAction.Space -> label(canvas, box, key.label, 13f, Palette.TEXT_DIM)
            else -> {
                val text = if (uppercase && key.letter != null) key.label.uppercase() else key.label
                label(canvas, box, text, if (key.label.length > 1) 15f else 22f, Palette.TEXT)
            }
        }
    }

    private fun label(canvas: Canvas, box: RectF, text: String, sp: Float, color: Int) {
        textPaint.textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, sp, resources.displayMetrics)
        textPaint.color = color
        canvas.drawText(text, box.centerX(), box.centerY() - (textPaint.ascent() + textPaint.descent()) / 2, textPaint)
    }

    private fun keyAt(x: Float, y: Float): Key? =
        placed.firstOrNull { it.rect.contains(x, y) }?.key
            ?: placed.minByOrNull { hypot(it.rect.centerX() - x, it.rect.centerY() - y) }?.key  // the gaps and edges

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> track(event, 0)
            MotionEvent.ACTION_POINTER_DOWN -> {
                if (!swiping) release(typeIt = true)  // the first finger's key, now
                track(event, event.actionIndex)
            }
            MotionEvent.ACTION_MOVE -> {
                val i = event.findPointerIndex(pointerId)
                if (i >= 0) move(event.getX(i), event.getY(i))
            }
            MotionEvent.ACTION_POINTER_UP -> if (event.getPointerId(event.actionIndex) == pointerId) release(typeIt = true)
            MotionEvent.ACTION_UP -> if (event.getPointerId(event.actionIndex) == pointerId) release(typeIt = true)
            MotionEvent.ACTION_CANCEL -> release(typeIt = false)
        }
        return true
    }

    private fun track(event: MotionEvent, index: Int) {
        pointerId = event.getPointerId(index)
        downX = event.getX(index); downY = event.getY(index)
        val key = keyAt(downX, downY)
        downKey = key
        pressed = key
        swiping = false
        xs.clear(); ys.clear(); xs += downX; ys += downY
        trail.reset(); trail.moveTo(downX, downY)
        performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
        if (key?.action == KeyAction.Delete) {
            listener.onKey(key)
            repeat.postDelayed(repeatDelete, REPEAT_DELAY_MS)
        }
        invalidate()
    }

    private fun move(x: Float, y: Float) {
        if (downKey == null) return
        xs += x; ys += y
        trail.lineTo(x, y)
        if (!swiping && downKey?.letter != null && listener.swipeEnabled && hypot(x - downX, y - downY) > SWIPE_START * keyWidth) {
            swiping = true
            pressed = null
        }
        if (swiping) invalidate()
    }

    private fun release(typeIt: Boolean) {
        repeat.removeCallbacks(repeatDelete)
        val key = downKey
        val wasSwipe = swiping
        downKey = null; pressed = null; swiping = false; pointerId = -1
        if (typeIt) {
            if (wasSwipe) listener.onSwipe(xs.toFloatArray(), ys.toFloatArray())
            else if (key != null && key.action != KeyAction.Delete) listener.onKey(key)
        }
        invalidate()
    }

    companion object {
        /** A path counts as a swipe once it's this many key widths from where it started. */
        const val SWIPE_START = 0.6f
        const val REPEAT_DELAY_MS = 400L
        const val REPEAT_MS = 50L
    }
}
