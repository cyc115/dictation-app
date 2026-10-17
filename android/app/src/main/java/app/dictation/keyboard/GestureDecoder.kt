package app.dictation.keyboard

import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/**
 * Swipe typing: which words a finger's path over the letter keys spells. Shape matching in the
 * style of SHARK² (Kristensson & Zhai, 2004): each word has an ideal path through its letters' key
 * centers, and the drawn path is compared with every plausible word's on where it runs (location)
 * and on its shape (scaled, so a small or offset swipe still matches), then weighted by how common
 * the word is. The same decoder spells English words and pinyin.
 *
 * Works in key units (x in key widths, y in row heights), so it doesn't care about screen size.
 */
class GestureDecoder(entries: List<Entry>) {
    /** `letters`: the a–z keys swiped through; `prior`: 0…1, how common the word is. */
    class Entry(val letters: String, val word: String, val prior: Float)

    data class Match(val word: String, val letters: String, val score: Float)

    private val byFirst: Array<List<Entry>> = Array(26) { mutableListOf() }

    init {
        for (e in entries) {
            val first = e.letters.firstOrNull() ?: continue
            if (first in 'a'..'z') (byFirst[first - 'a'] as MutableList<Entry>).add(e)
        }
    }

    private val cx = FloatArray(26) { Float.NaN }
    private val cy = FloatArray(26) { Float.NaN }
    private var keyWidth = 1f
    private var rowHeight = 1f
    private val templates = HashMap<Entry, FloatArray>()

    /** Where the letter keys are, in pixels (their centers), and one key's size. */
    fun setKeys(centers: Map<Char, Pair<Float, Float>>, keyWidth: Float, rowHeight: Float) {
        this.keyWidth = keyWidth
        this.rowHeight = rowHeight
        cx.fill(Float.NaN); cy.fill(Float.NaN)
        for ((c, p) in centers) if (c in 'a'..'z') { cx[c - 'a'] = p.first / keyWidth; cy[c - 'a'] = p.second / rowHeight }
        templates.clear()
    }

    val hasKeys: Boolean get() = !cx[0].isNaN()

    /**
     * The best words for a path in pixels, best first. Empty when it's too short to be a swipe or
     * nothing fits.
     */
    fun decode(xs: FloatArray, ys: FloatArray, limit: Int = 8): List<Match> {
        if (xs.size < 2 || !hasKeys) return emptyList()
        val ux = FloatArray(xs.size) { xs[it] / keyWidth }
        val uy = FloatArray(ys.size) { ys[it] / rowHeight }
        if (length(ux, uy) < MIN_SWIPE) return emptyList()
        val user = resample(ux, uy)
        val userShape = normalized(user)
        val starts = nearKeys(user[0], user[1])
        val ends = nearKeys(user[2 * N - 2], user[2 * N - 1])
        val found = ArrayList<Match>()
        for (first in starts) {
            for (entry in byFirst[first]) {
                val last = entry.letters.last() - 'a'
                if (last !in 0..25 || !ends.contains(last)) continue
                if (templates.size > MAX_TEMPLATES) templates.clear()  // ~3 MB; a swipe needs a few hundred
                val template = templates.getOrPut(entry) { template(entry.letters) ?: EMPTY }
                if (template === EMPTY) continue
                val location = meanDistance(user, template)
                if (location > MAX_LOCATION) continue
                val shape = meanDistance(userShape, normalized(template))
                val missed = missedKeys(entry.letters, user)
                val score = -(location * location) / (2 * SIGMA_LOCATION * SIGMA_LOCATION) -
                    (shape * shape) / (2 * SIGMA_SHAPE * SIGMA_SHAPE) - MISSED_WEIGHT * missed + PRIOR_WEIGHT * entry.prior
                found += Match(entry.word, entry.letters, score)
            }
        }
        found.sortByDescending { it.score }
        val seen = HashSet<String>()
        return found.filter { seen.add(it.word) }.take(limit)
    }

    /** Letters whose keys are within a key of the point, nearest first (at least the nearest). */
    private fun nearKeys(x: Float, y: Float): Set<Int> {
        val byDistance = (0 until 26).filter { !cx[it].isNaN() }.sortedBy { hypot(cx[it] - x, cy[it] - y) }
        return byDistance.filterIndexed { i, k -> i == 0 || hypot(cx[k] - x, cy[k] - y) <= NEAR }.toSet()
    }

    /** The word's ideal path through its key centers, resampled; null for a one-key word (a tap, not a swipe). */
    private fun template(letters: String): FloatArray? {
        val px = ArrayList<Float>(); val py = ArrayList<Float>()
        for (c in letters) {
            val k = c - 'a'
            if (k !in 0..25 || cx[k].isNaN()) return null
            if (px.isNotEmpty() && px.last() == cx[k] && py.last() == cy[k]) continue  // "ll", "oo": one key
            px += cx[k]; py += cy[k]
        }
        if (px.size < 2) return null
        return resample(px.toFloatArray(), py.toFloatArray())
    }

    /** How far the path stays from the word's keys: sum over its letters of the gap beyond the key's half-size, squared. */
    private fun missedKeys(letters: String, path: FloatArray): Float {
        var missed = 0f
        for (c in letters) {
            val k = c - 'a'
            var nearest = Float.MAX_VALUE
            for (i in 0 until N) nearest = min(nearest, hypot(path[2 * i] - cx[k], path[2 * i + 1] - cy[k]))
            val gap = max(0f, nearest - KEY_SLACK)
            missed += gap * gap
        }
        return missed
    }

    companion object {
        /** Points per resampled path. */
        const val N = 48
        /** Shorter than this (key units) is a tap. */
        const val MIN_SWIPE = 0.8f
        const val NEAR = 1.05f
        const val MAX_LOCATION = 1.3f
        const val SIGMA_LOCATION = 0.4f
        const val SIGMA_SHAPE = 0.22f
        const val KEY_SLACK = 0.55f
        const val MISSED_WEIGHT = 6f
        const val PRIOR_WEIGHT = 3f
        const val MAX_TEMPLATES = 8_000
        private val EMPTY = FloatArray(0)

        fun length(xs: FloatArray, ys: FloatArray): Float {
            var total = 0f
            for (i in 1 until xs.size) total += hypot(xs[i] - xs[i - 1], ys[i] - ys[i - 1])
            return total
        }

        /** N points evenly spaced along the path, as x0, y0, x1, y1, … */
        fun resample(xs: FloatArray, ys: FloatArray): FloatArray {
            val out = FloatArray(2 * N)
            val total = length(xs, ys)
            if (total == 0f) { for (i in 0 until N) { out[2 * i] = xs[0]; out[2 * i + 1] = ys[0] }; return out }
            val step = total / (N - 1)
            var seg = 1
            var segStart = 0f  // path length at xs[seg - 1]
            for (i in 0 until N) {
                val at = min(i * step, total)
                while (seg < xs.size - 1 && segStart + hypot(xs[seg] - xs[seg - 1], ys[seg] - ys[seg - 1]) < at) {
                    segStart += hypot(xs[seg] - xs[seg - 1], ys[seg] - ys[seg - 1]); seg++
                }
                val segLength = hypot(xs[seg] - xs[seg - 1], ys[seg] - ys[seg - 1])
                val t = if (segLength == 0f) 0f else ((at - segStart) / segLength).coerceIn(0f, 1f)
                out[2 * i] = xs[seg - 1] + t * (xs[seg] - xs[seg - 1])
                out[2 * i + 1] = ys[seg - 1] + t * (ys[seg] - ys[seg - 1])
            }
            return out
        }

        /** The path centered on its centroid and scaled so its larger side is 1. */
        fun normalized(path: FloatArray): FloatArray {
            var minX = Float.MAX_VALUE; var maxX = -Float.MAX_VALUE; var minY = Float.MAX_VALUE; var maxY = -Float.MAX_VALUE
            var sx = 0f; var sy = 0f
            for (i in 0 until N) {
                val x = path[2 * i]; val y = path[2 * i + 1]
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                sx += x; sy += y
            }
            val scale = max(max(maxX - minX, maxY - minY), 0.5f)
            val mx = sx / N; val my = sy / N
            return FloatArray(2 * N) { if (it % 2 == 0) (path[it] - mx) / scale else (path[it] - my) / scale }
        }

        fun meanDistance(a: FloatArray, b: FloatArray): Float {
            var total = 0f
            for (i in 0 until N) total += hypot(a[2 * i] - b[2 * i], a[2 * i + 1] - b[2 * i + 1])
            return total / N
        }
    }
}
