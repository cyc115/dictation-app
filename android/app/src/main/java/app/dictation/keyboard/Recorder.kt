package app.dictation.keyboard

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.sqrt

/** A finished recording: 16-bit little-endian mono PCM at `Wav.SAMPLE_RATE`. */
class Recording(val pcm: ByteArray, val heardOnlySilence: Boolean) {
    val seconds: Double get() = pcm.size / 2.0 / Wav.SAMPLE_RATE
    /** Too short to be speech: not uploaded (the Mac app's DictationRecording.minimumSeconds). */
    val isSpeech: Boolean get() = seconds >= 0.3
}

/** The microphone while dictating (a fake in tests). */
interface Mic {
    /** Starts recording; `onLevel` gets 0…1 loudness from the recording thread. False if the mic can't start. */
    fun start(onLevel: (Float) -> Unit): Boolean
    fun stop(): Recording
    fun cancel()
}

/** Records 16 kHz mono 16-bit audio, the format cloud transcription expects, so no conversion is needed. */
class AudioRecordMic : Mic {
    @Volatile private var running = false
    private var thread: Thread? = null
    private var record: AudioRecord? = null
    private val pcm = ByteArrayOutputStream()
    @Volatile private var heard = false
    @Volatile private var samples = 0L

    @SuppressLint("MissingPermission")  // the keyboard checks RECORD_AUDIO before starting
    override fun start(onLevel: (Float) -> Unit): Boolean {
        cancel()
        val minBuffer = AudioRecord.getMinBufferSize(Wav.SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val chunk = Wav.SAMPLE_RATE / 10  // 100 ms
        val rec = try {
            AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, Wav.SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT, maxOf(minBuffer, chunk * 2 * 4))
        } catch (e: Exception) {
            return false
        }
        if (rec.state != AudioRecord.STATE_INITIALIZED) { rec.release(); return false }
        synchronized(pcm) { pcm.reset() }
        heard = false
        samples = 0
        rec.startRecording()
        record = rec
        running = true
        thread = Thread({
            val buffer = ShortArray(chunk)
            val bytes = ByteBuffer.allocate(chunk * 2).order(ByteOrder.LITTLE_ENDIAN)
            while (running) {
                val n = rec.read(buffer, 0, buffer.size)
                if (n <= 0) continue
                bytes.clear()
                var sum = 0.0
                for (i in 0 until n) {
                    val s = buffer[i]
                    bytes.putShort(s)
                    sum += s.toDouble() * s
                    if (s.toInt() != 0) heard = true
                }
                synchronized(pcm) { pcm.write(bytes.array(), 0, n * 2) }
                samples += n
                onLevel(level(sqrt(sum / n)))
            }
        }, "dictation-mic").apply { start() }
        return true
    }

    override fun stop(): Recording {
        finish()
        // All-zero audio for 0.5 s or more: the mic is blocked or muted, not quiet (the Mac app's heardOnlySilence).
        val silence = samples >= Wav.SAMPLE_RATE / 2 && !heard
        return Recording(synchronized(pcm) { pcm.toByteArray() }, silence)
    }

    override fun cancel() {
        finish()
        synchronized(pcm) { pcm.reset() }
    }

    private fun finish() {
        running = false
        record?.let { runCatching { it.stop() } }  // returns the recording thread's read() at once
        thread?.join(500)
        thread = null
        record?.release()
        record = null
    }

    companion object {
        /** RMS of 16-bit samples → 0…1, roughly −50 dBFS…0 dBFS. */
        fun level(rms: Double): Float {
            if (rms <= 0) return 0f
            val db = 20 * kotlin.math.log10(rms / 32768.0)
            return ((db + 50) / 50).toFloat().coerceIn(0f, 1f)
        }
    }
}

/** WAV container for PCM, with the header declaring the real length (strict providers reject 0-length headers). */
object Wav {
    const val SAMPLE_RATE = 16_000

    fun encode(pcm: ByteArray, sampleRate: Int = SAMPLE_RATE): ByteArray {
        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray()); putInt(36 + pcm.size); put("WAVE".toByteArray())
            put("fmt ".toByteArray()); putInt(16); putShort(1); putShort(1)  // PCM, mono
            putInt(sampleRate); putInt(sampleRate * 2); putShort(2); putShort(16)
            put("data".toByteArray()); putInt(pcm.size)
        }
        return header.array() + pcm
    }
}
