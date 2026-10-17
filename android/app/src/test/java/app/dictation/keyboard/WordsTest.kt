package app.dictation.keyboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class WordsTest {
    private val english get() = SwipeTest.english
    private val pinyin get() = SwipeTest.pinyin

    @Test
    fun completesTheWordBeingTyped() {
        assertEquals("the", english.completions("th").first())
        assertTrue("because" in english.completions("becau"))
        assertEquals("Hello", english.completions("Hell").first { it.startsWith("Hello") })
        assertEquals(listOf<String>(), english.completions(""))
    }

    @Test
    fun keepsTheTypedCase() {
        assertEquals("Hello", EnglishWords.matchCase("hello", "He"))
        assertEquals("HELLO", EnglishWords.matchCase("hello", "HE"))
        assertEquals("iPhone", EnglishWords.matchCase("iPhone", "ip"))
        assertEquals("I", EnglishWords.matchCase("I", "i"))
    }

    @Test
    fun pinyinCandidates() {
        assertEquals(PinyinEngine.Candidate("你好", 5), pinyin.candidates("nihao").first())
        assertEquals("我们", pinyin.candidates("women").first().text)
        val xian = pinyin.candidates("xian").map { it.text }
        assertTrue("先 and 西安 share a spelling" , "先" in xian && "西安" in xian)
        assertEquals("中国", pinyin.candidates("zhongg").first { it.consumed == 6 }.text)  // finishes the last syllable
        assertTrue(pinyin.candidates("nihao").any { it.text == "你" && it.consumed == 2 })  // just the first syllable
    }

    @Test
    fun pinyinSentenceForSeveralWords() {
        val first = pinyin.candidates("wojintianhenmang").first()
        assertEquals(16, first.consumed)
        assertEquals("我今天很忙", first.text)
    }
}
