package design.irons.dictator

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * The smallest correct 16-bit PCM WAV writer that Groq/Whisper accepts: 16 kHz,
 * mono, 16-bit little-endian PCM with the standard 44-byte header. Ported from
 * `WAVEncoder` in Sources/DictationCore/SpeechProvider.swift.
 *
 * Android's AudioRecord already hands us signed 16-bit PCM samples (ShortArray),
 * so — unlike the iOS Float pipeline — there is no float-to-int scaling step. We
 * just clamp is unnecessary (values are already Int16) and write each sample
 * little-endian after the header.
 */
object WavEncoder {

    /** Encode PCM16 mono samples into a WAV byte array. */
    fun encode(samples: ShortArray, sampleRate: Int = 16_000): ByteArray {
        val dataSize = samples.size * 2          // 2 bytes per 16-bit sample
        val byteRate = sampleRate * 2            // mono, 16-bit
        val out = ByteArrayOutputStream(44 + dataSize)

        fun ascii(s: String) = out.write(s.toByteArray(Charsets.US_ASCII))
        fun le32(v: Int) = out.write(
            ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(v).array()
        )
        fun le16(v: Int) = out.write(
            ByteBuffer.allocate(2).order(ByteOrder.LITTLE_ENDIAN).putShort(v.toShort()).array()
        )

        // RIFF header.
        ascii("RIFF")
        le32(36 + dataSize)
        ascii("WAVE")

        // fmt chunk.
        ascii("fmt ")
        le32(16)          // PCM chunk size
        le16(1)           // PCM format
        le16(1)           // mono
        le32(sampleRate)
        le32(byteRate)
        le16(2)           // block align (channels * bytesPerSample)
        le16(16)          // bits per sample

        // data chunk.
        ascii("data")
        le32(dataSize)

        // Samples, little-endian. Write straight through with one buffer for speed.
        val body = ByteBuffer.allocate(dataSize).order(ByteOrder.LITTLE_ENDIAN)
        for (s in samples) body.putShort(s)
        out.write(body.array())

        return out.toByteArray()
    }
}
