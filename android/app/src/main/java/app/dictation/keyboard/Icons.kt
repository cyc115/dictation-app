package app.dictation.keyboard

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF

/** The keyboard's colors: dark, like the system keyboards it sits among. */
object Palette {
    const val BACKGROUND = 0xFF2B2B2D.toInt()
    const val KEY = 0xFF464649.toInt()
    const val KEY_PRESSED = 0xFF5E5E62.toInt()
    const val KEY_SPECIAL = 0xFF39393C.toInt()
    const val KEY_LIGHT = 0xFFF2F2EF.toInt()
    const val TEXT = 0xFFF5F5F5.toInt()
    const val TEXT_DIM = 0xFFA8A8AD.toInt()
    const val TEXT_DARK = 0xFF1C1C1E.toInt()
    const val ACCENT = 0xFFC9B6FF.toInt()
    const val RECORDING = 0xFFE5484D.toInt()
    const val ERROR = 0xFFFF8A80.toInt()
    const val TRAIL = 0xCCC9B6FF.toInt()
}

/** Line icons drawn into a box, so they look the same on every phone (no font glyphs). */
object Icons {
    private fun stroke(paint: Paint, box: RectF) = paint.apply {
        style = Paint.Style.STROKE
        strokeWidth = box.width() * 0.09f
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }

    fun mic(canvas: Canvas, box: RectF, paint: Paint) {
        stroke(paint, box)
        val w = box.width(); val h = box.height()
        val capsule = RectF(box.centerX() - w * 0.17f, box.top + h * 0.05f, box.centerX() + w * 0.17f, box.top + h * 0.62f)
        paint.style = Paint.Style.FILL
        canvas.drawRoundRect(capsule, w * 0.17f, w * 0.17f, paint)
        paint.style = Paint.Style.STROKE
        val arc = RectF(box.centerX() - w * 0.32f, box.top + h * 0.22f, box.centerX() + w * 0.32f, box.top + h * 0.76f)
        canvas.drawArc(arc, 0f, 180f, false, paint)
        canvas.drawLine(box.centerX(), box.top + h * 0.76f, box.centerX(), box.bottom - h * 0.04f, paint)
    }

    fun delete(canvas: Canvas, box: RectF, paint: Paint) {
        stroke(paint, box)
        val w = box.width(); val h = box.height()
        val path = Path().apply {
            moveTo(box.left + w * 0.05f, box.centerY())
            lineTo(box.left + w * 0.32f, box.top + h * 0.2f)
            lineTo(box.right - w * 0.05f, box.top + h * 0.2f)
            lineTo(box.right - w * 0.05f, box.bottom - h * 0.2f)
            lineTo(box.left + w * 0.32f, box.bottom - h * 0.2f)
            close()
        }
        canvas.drawPath(path, paint)
        val cx = box.left + w * 0.6f; val r = w * 0.13f
        canvas.drawLine(cx - r, box.centerY() - r, cx + r, box.centerY() + r, paint)
        canvas.drawLine(cx - r, box.centerY() + r, cx + r, box.centerY() - r, paint)
    }

    fun shift(canvas: Canvas, box: RectF, paint: Paint, state: Shift) {
        stroke(paint, box)
        val w = box.width(); val h = box.height()
        val path = Path().apply {
            moveTo(box.centerX(), box.top + h * 0.08f)
            lineTo(box.right - w * 0.08f, box.top + h * 0.5f)
            lineTo(box.centerX() + w * 0.2f, box.top + h * 0.5f)
            lineTo(box.centerX() + w * 0.2f, box.bottom - h * 0.22f)
            lineTo(box.centerX() - w * 0.2f, box.bottom - h * 0.22f)
            lineTo(box.centerX() - w * 0.2f, box.top + h * 0.5f)
            lineTo(box.left + w * 0.08f, box.top + h * 0.5f)
            close()
        }
        if (state != Shift.OFF) { paint.style = Paint.Style.FILL_AND_STROKE }
        canvas.drawPath(path, paint)
        if (state == Shift.LOCKED) {
            paint.style = Paint.Style.STROKE
            canvas.drawLine(box.centerX() - w * 0.2f, box.bottom - h * 0.02f, box.centerX() + w * 0.2f, box.bottom - h * 0.02f, paint)
        }
    }

    fun enter(canvas: Canvas, box: RectF, paint: Paint) {
        stroke(paint, box)
        val w = box.width(); val h = box.height()
        val path = Path().apply {
            moveTo(box.right - w * 0.12f, box.top + h * 0.18f)
            lineTo(box.right - w * 0.12f, box.top + h * 0.62f)
            lineTo(box.left + w * 0.12f, box.top + h * 0.62f)
        }
        canvas.drawPath(path, paint)
        canvas.drawLine(box.left + w * 0.12f, box.top + h * 0.62f, box.left + w * 0.34f, box.top + h * 0.42f, paint)
        canvas.drawLine(box.left + w * 0.12f, box.top + h * 0.62f, box.left + w * 0.34f, box.top + h * 0.82f, paint)
    }

    fun close(canvas: Canvas, box: RectF, paint: Paint) {
        stroke(paint, box)
        val r = box.width() * 0.3f
        canvas.drawLine(box.centerX() - r, box.centerY() - r, box.centerX() + r, box.centerY() + r, paint)
        canvas.drawLine(box.centerX() - r, box.centerY() + r, box.centerX() + r, box.centerY() - r, paint)
    }

    /** A pen with a spark: AI polish. */
    fun polish(canvas: Canvas, box: RectF, paint: Paint) {
        stroke(paint, box)
        val w = box.width(); val h = box.height()
        canvas.drawLine(box.left + w * 0.2f, box.bottom - h * 0.15f, box.right - w * 0.3f, box.top + h * 0.35f, paint)
        canvas.drawLine(box.left + w * 0.2f, box.bottom - h * 0.15f, box.left + w * 0.15f, box.bottom - h * 0.05f, paint)
        spark(canvas, box.right - w * 0.2f, box.top + h * 0.18f, w * 0.16f, paint)
        spark(canvas, box.left + w * 0.28f, box.top + h * 0.25f, w * 0.09f, paint)
    }

    private fun spark(canvas: Canvas, x: Float, y: Float, r: Float, paint: Paint) {
        canvas.drawLine(x - r, y, x + r, y, paint)
        canvas.drawLine(x, y - r, x, y + r, paint)
    }

    /** Five bars, like a waveform: the dictation mode. `levels`, 0…1, sets their heights. */
    fun bars(canvas: Canvas, box: RectF, paint: Paint, levels: FloatArray = floatArrayOf(0.35f, 0.7f, 1f, 0.7f, 0.35f)) {
        stroke(paint, box)
        val step = box.width() / (levels.size + 1)
        for (i in levels.indices) {
            val x = box.left + step * (i + 1)
            val half = box.height() * 0.5f * levels[i].coerceIn(0.12f, 1f)
            canvas.drawLine(x, box.centerY() - half, x, box.centerY() + half, paint)
        }
    }
}
