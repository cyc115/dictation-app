package app.dictation.keyboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

/** Swipe typing on the real word lists, with paths drawn through the keys as a finger would, wobble included. */
class SwipeTest {
    companion object {
        const val KEY_WIDTH = 108f
        const val ROW_HEIGHT = 150f

        /** Key centers as the letter grid lays them out (rows centered; row 3 starts after a 1.5-wide shift). */
        val centers: Map<Char, Pair<Float, Float>> = buildMap {
            "qwertyuiop".forEachIndexed { i, c -> put(c, (i + 0.5f) * KEY_WIDTH to 0.5f * ROW_HEIGHT) }
            "asdfghjkl".forEachIndexed { i, c -> put(c, (i + 1.0f) * KEY_WIDTH to 1.5f * ROW_HEIGHT) }
            "zxcvbnm".forEachIndexed { i, c -> put(c, (i + 2.0f) * KEY_WIDTH to 2.5f * ROW_HEIGHT) }
        }

        val english by lazy { EnglishWords(TestFiles.asset("dict/en.txt")) }
        val pinyin by lazy { PinyinEngine(TestFiles.asset("dict/zh.txt")) }
        val englishDecoder by lazy { GestureDecoder(english.gestureEntries()).apply { setKeys(centers, KEY_WIDTH, ROW_HEIGHT) } }
        val pinyinDecoder by lazy { GestureDecoder(pinyin.gestureEntries()).apply { setKeys(centers, KEY_WIDTH, ROW_HEIGHT) } }

        /**
         * A finger's path through `letters`: points every few pixels, offset and wobbling by up to
         * `wobble` keys; `sloppy` also cuts corners (averages the path over about a key), as thumbs do.
         */
        fun swipe(letters: String, random: Random = Random(1), wobble: Float = 0.25f, sloppy: Boolean = false): Pair<FloatArray, FloatArray> {
            val xs = ArrayList<Float>(); val ys = ArrayList<Float>()
            val dx = (random.nextFloat() - 0.5f) * wobble * KEY_WIDTH
            val dy = (random.nextFloat() - 0.5f) * wobble * ROW_HEIGHT
            val points = letters.map { centers.getValue(it) }
            for (i in 1 until points.size) {
                val (x0, y0) = points[i - 1]; val (x1, y1) = points[i]
                val steps = maxOf(2, (kotlin.math.hypot(x1 - x0, y1 - y0) / 12).toInt())
                for (s in 0 until steps) {
                    val t = s.toFloat() / steps
                    xs += x0 + t * (x1 - x0) + dx + (random.nextFloat() - 0.5f) * wobble * KEY_WIDTH * 0.5f
                    ys += y0 + t * (y1 - y0) + dy + (random.nextFloat() - 0.5f) * wobble * ROW_HEIGHT * 0.5f
                }
            }
            xs += points.last().first + dx; ys += points.last().second + dy
            if (!sloppy) return xs.toFloatArray() to ys.toFloatArray()
            val window = 5  // ±5 points ≈ ±60 px: corners rounded off by about half a key
            fun smooth(v: List<Float>) = FloatArray(v.size) { i ->
                val from = maxOf(0, i - window); val to = minOf(v.size - 1, i + window)
                (from..to).map { v[it] }.average().toFloat()
            }
            return smooth(xs) to smooth(ys)
        }

        fun GestureDecoder.top(letters: String, random: Random = Random(1), sloppy: Boolean = false): List<String> {
            val (xs, ys) = swipe(letters, random, wobble = if (sloppy) 0.4f else 0.25f, sloppy = sloppy)
            return decode(xs, ys).map { it.word }
        }
    }

    @Test
    fun spellsEnglishWords() {
        for (word in listOf("hello", "world", "keyboard", "dictation", "the", "because", "thanks", "tomorrow", "meeting")) {
            assertEquals(word, englishDecoder.top(word).firstOrNull())
        }
    }

    @Test
    fun commonEnglishWordsComeOutFirst() {
        // The 300 most common words of 3+ letters, each swiped once with its own wobble.
        val words = english.gestureEntries().map { it.word }.filter { it.length >= 3 && it.all(Char::isLowerCase) }.take(300)
        val random = Random(42)
        val ranks = words.map { w -> englishDecoder.top(w.filter { it in 'a'..'z' }, random).indexOf(w) }
        val top1 = ranks.count { it == 0 } / words.size.toDouble()
        val top3 = ranks.count { it in 0..2 } / words.size.toDouble()
        println("English swipe: top-1 ${"%.1f".format(top1 * 100)}%, top-3 ${"%.1f".format(top3 * 100)}% of ${words.size}")
        assertTrue("top-1 $top1", top1 >= 0.85)
        assertTrue("top-3 $top3", top3 >= 0.95)
    }

    @Test
    fun sloppySwipesStillFindTheWord() {
        val words = english.gestureEntries().map { it.word }.filter { it.length >= 3 && it.all(Char::isLowerCase) }.take(300)
        val random = Random(7)
        val ranks = words.map { w -> englishDecoder.top(w, random, sloppy = true).indexOf(w) }
        val top1 = ranks.count { it == 0 } / words.size.toDouble()
        val top3 = ranks.count { it in 0..2 } / words.size.toDouble()
        println("English sloppy swipe: top-1 ${"%.1f".format(top1 * 100)}%, top-3 ${"%.1f".format(top3 * 100)}%; misses " +
            words.filterIndexed { i, _ -> ranks[i] != 0 }.take(15))
        assertTrue("top-1 $top1", top1 >= 0.75)
        assertTrue("top-3 $top3", top3 >= 0.90)
    }

    @Test
    fun decodingIsFastEnoughToFeelInstant() {
        val (xs, ys) = swipe("international")
        englishDecoder.decode(xs, ys)  // warm up: templates are cached after the first use
        val started = System.nanoTime()
        repeat(20) { englishDecoder.decode(swipe("something", Random(it)).first, swipe("something", Random(it)).second) }
        val ms = (System.nanoTime() - started) / 20 / 1e6
        println("decode: ${"%.1f".format(ms)} ms per swipe")
        assertTrue("$ms ms", ms < 50)
    }

    @Test
    fun spellsPinyinThenChinese() {
        for ((spelled, word) in listOf("nihao" to "你好", "women" to "我们", "zhongguo" to "中国", "xiexie" to "谢谢", "shijian" to "时间")) {
            val key = pinyinDecoder.top(spelled).first()
            assertEquals(spelled, key)
            assertEquals(word, pinyin.words(key).first().word)
        }
    }

    @Test
    fun aTapIsNotASwipe() {
        assertTrue(englishDecoder.decode(floatArrayOf(100f, 110f), floatArrayOf(70f, 75f)).isEmpty())
    }
}
