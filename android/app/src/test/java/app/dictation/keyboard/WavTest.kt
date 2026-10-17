package app.dictation.keyboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class WavTest {
    @Test
    fun headerDeclaresTheRealLength() {
        val pcm = ByteArray(32_000) { (it % 7).toByte() }  // 1 s
        val wav = Wav.encode(pcm)
        val b = ByteBuffer.wrap(wav).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals("RIFF", String(wav, 0, 4))
        assertEquals(36 + pcm.size, b.getInt(4))
        assertEquals("WAVEfmt ", String(wav, 8, 8))
        assertEquals(1, b.getShort(20).toInt())   // PCM
        assertEquals(1, b.getShort(22).toInt())   // mono
        assertEquals(16_000, b.getInt(24))
        assertEquals(32_000, b.getInt(28))        // bytes per second
        assertEquals(16, b.getShort(34).toInt())  // bits
        assertEquals("data", String(wav, 36, 4))
        assertEquals(pcm.size, b.getInt(40))
        assertEquals(44 + pcm.size, wav.size)
    }

    @Test
    fun tooShortRecordingsAreNotSpeech() {
        assertFalse(Recording(ByteArray(9_000), false).isSpeech)  // 0.28 s
        assertTrue(Recording(ByteArray(9_600), false).isSpeech)   // 0.3 s
    }

    @Test
    fun levelMapsLoudnessToZeroToOne() {
        assertEquals(0f, AudioRecordMic.level(0.0))
        assertEquals(1f, AudioRecordMic.level(32768.0))
        assertTrue(AudioRecordMic.level(1000.0) in 0.3f..0.6f)
    }
}
