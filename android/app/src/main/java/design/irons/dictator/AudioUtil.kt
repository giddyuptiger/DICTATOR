package design.irons.dictator

import kotlin.math.sqrt

/**
 * Audio helpers ported from `AudioUtil` in
 * Sources/DictationCore/SpeechProvider.swift, adapted from Float samples to the
 * ShortArray (PCM16) that Android's AudioRecord produces. RMS thresholds are
 * expressed in the normalized [-1, 1] range, so samples are scaled by 1/32768
 * before comparison — matching the iOS thresholds exactly.
 */
object AudioUtil {

    private const val FULL_SCALE = 32768.0f

    /**
     * Strip leading and trailing near-silence. Cuts upload size and stops the model
     * hallucinating words out of room tone (the single most common source of
     * phantom text). Leaves ~50 ms of air either side so the first phoneme is not
     * clipped.
     */
    fun trimSilence(
        samples: ShortArray,
        threshold: Float = 0.012f,
        windowMs: Int = 30,
        sampleRate: Int = 16_000,
    ): ShortArray {
        if (samples.isEmpty()) return samples
        val window = maxOf(1, sampleRate * windowMs / 1000)

        fun isLoud(from: Int, to: Int): Boolean {
            var sum = 0.0f
            for (i in from until to) {
                val v = samples[i] / FULL_SCALE
                sum += v * v
            }
            return sqrt(sum / (to - from)) > threshold
        }

        var start = 0
        while (start + window < samples.size && !isLoud(start, start + window)) {
            start += window
        }

        var end = samples.size
        while (end - window > start && !isLoud(end - window, end)) {
            end -= window
        }

        if (start >= end) return ShortArray(0)

        val pad = sampleRate / 20 // 50 ms
        val lo = maxOf(0, start - pad)
        val hi = minOf(samples.size, end + pad)
        return samples.copyOfRange(lo, hi)
    }
}
