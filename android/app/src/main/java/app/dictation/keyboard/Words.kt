package app.dictation.keyboard

import kotlin.math.ln

/** English words by frequency (assets/dict/en.txt): swipe entries and completions for the word being typed. */
class EnglishWords(text: String) {
    private class Word(val word: String, val lower: String, val freq: Int)

    private val words: List<Word> = text.lineSequence().mapNotNull { line ->
        val tab = line.indexOf('\t')
        if (tab <= 0) null else Word(line.substring(0, tab), line.substring(0, tab).lowercase(), line.substring(tab + 1).toInt())
    }.toList()
    private val maxFreq = words.maxOfOrNull { it.freq }?.coerceAtLeast(1) ?: 1
    /** Indices into `words`, sorted by lowercase spelling, for prefix lookups. */
    private val sorted: IntArray = words.indices.sortedBy { words[it].lower }.toIntArray()

    val size get() = words.size

    fun gestureEntries(): List<GestureDecoder.Entry> = words.mapNotNull { w ->
        val letters = w.lower.filter { it in 'a'..'z' }
        if (letters.isEmpty()) null else GestureDecoder.Entry(letters, w.word, w.freq.toFloat() / maxFreq)
    }

    /** The most frequent words starting with `prefix` (any case), the typed capitalization kept. */
    fun completions(prefix: String, limit: Int = 3): List<String> {
        if (prefix.isEmpty()) return emptyList()
        val lower = prefix.lowercase()
        var lo = 0; var hi = sorted.size
        while (lo < hi) { val mid = (lo + hi) / 2; if (words[sorted[mid]].lower < lower) lo = mid + 1 else hi = mid }
        val found = ArrayList<Word>()
        var i = lo
        while (i < sorted.size && words[sorted[i]].lower.startsWith(lower)) { found += words[sorted[i]]; i++ }
        return found.sortedByDescending { it.freq }.map { matchCase(it.word, prefix) }.distinct().take(limit)
    }

    companion object {
        /** "hel" → "hello", "Hel" → "Hello", "HEL" → "HELLO"; proper nouns ("John", "iPhone") as they are. */
        fun matchCase(word: String, typed: String): String = when {
            word != word.lowercase() -> word
            typed.length > 1 && typed.all { !it.isLetter() || it.isUpperCase() } -> word.uppercase()
            typed.first().isUpperCase() -> word.replaceFirstChar { it.uppercase() }
            else -> word
        }
    }
}

/**
 * Pinyin to Chinese from AOSP PinyinIME's word list (assets/dict/zh.txt): candidates for the pinyin
 * being typed, and the pinyin spellings swipe typing can produce.
 */
class PinyinEngine(text: String) {
    class Row(val word: String, val freq: Double, val key: String)

    /** A choice in the candidate bar: `text` replaces the first `consumed` letters of the pinyin. */
    data class Candidate(val text: String, val consumed: Int)

    private val byKey = HashMap<String, MutableList<Row>>()
    private val keys: Array<String>
    private val logTotal: Double
    val syllables: Set<String>

    init {
        val syllables = HashSet<String>()
        var total = 0.0
        for (line in text.lineSequence()) {
            val parts = line.split('\t')
            if (parts.size < 3) continue
            val spelled = parts[2].split(' ')
            syllables += spelled
            val row = Row(parts[0], parts[1].toDouble(), spelled.joinToString(""))
            byKey.getOrPut(row.key) { mutableListOf() } += row
            total += row.freq
        }
        byKey.values.forEach { rows -> rows.sortByDescending { it.freq } }
        keys = byKey.keys.sorted().toTypedArray()
        logTotal = ln(total)
        this.syllables = syllables
    }

    fun gestureEntries(): List<GestureDecoder.Entry> {
        val maxLog = ln(1 + byKey.values.maxOf { it.first().freq })
        return byKey.map { (key, rows) -> GestureDecoder.Entry(key, key, (ln(1 + rows.first().freq) / maxLog).toFloat()) }
    }

    fun hasKey(key: String) = byKey.containsKey(key)

    /** Words spelled exactly `key`, most common first. */
    fun words(key: String): List<Row> = byKey[key].orEmpty()

    /**
     * Choices for the typed pinyin, in order: the likeliest sentence for all of it, words spelled
     * exactly so, words it's the start of ("zhongg" → 中国), then words for its first syllables.
     */
    fun candidates(input: String, limit: Int = 60): List<Candidate> {
        val s = input.lowercase().filter { it in 'a'..'z' }
        if (s.isEmpty()) return emptyList()
        val out = LinkedHashMap<String, Candidate>()
        fun add(text: String, consumed: Int) { if (out.size < limit) out.putIfAbsent(text, Candidate(text, consumed)) }
        sentence(s)?.let { add(it, s.length) }
        words(s).forEach { add(it.word, s.length) }
        completions(s).forEach { add(it.word, s.length) }
        for (end in s.length - 1 downTo 1) words(s.substring(0, end)).take(if (end > 1) 12 else 30).forEach { add(it.word, end) }
        return out.values.toList()
    }

    /** The most common words with spellings that start with `prefix`, beyond it. */
    private fun completions(prefix: String, limit: Int = 8): List<Row> {
        var lo = keys.binarySearch(prefix).let { if (it < 0) -it - 1 else it + 1 }
        val rows = ArrayList<Row>()
        while (lo < keys.size && keys[lo].startsWith(prefix)) { rows += byKey.getValue(keys[lo]).first(); lo++ }
        return rows.sortedByDescending { it.freq }.take(limit)
    }

    /** The best split of all of `s` into words (by how common each is), when it takes two or more. */
    private fun sentence(s: String): String? {
        val n = s.length
        val best = DoubleArray(n + 1) { Double.NEGATIVE_INFINITY }
        val from = IntArray(n + 1) { -1 }
        best[0] = 0.0
        for (i in 1..n) for (j in maxOf(0, i - MAX_KEY) until i) {
            if (best[j] == Double.NEGATIVE_INFINITY) continue
            val top = byKey[s.substring(j, i)]?.first() ?: continue
            val score = best[j] + ln(top.freq) - logTotal
            if (score > best[i]) { best[i] = score; from[i] = j }
        }
        if (from[n] <= 0) return null  // no split, or one word (already listed)
        val parts = ArrayList<String>()
        var i = n
        while (i > 0) { parts += byKey.getValue(s.substring(from[i], i)).first().word; i = from[i] }
        return parts.reversed().joinToString("")
    }

    private companion object {
        const val MAX_KEY = 24
    }
}
