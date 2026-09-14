import Foundation

/// Where speech becomes text. Swappable on purpose: the Mac runs Parakeet locally,
/// the iPhone keyboard posts to Groq because it has 48 MB to live in, and a relay
/// to your own Mac can slot in later without touching anything above this line.
public protocol SpeechProvider: Sendable {
    /// 16 kHz mono Float32 in, text out.
    func transcribe(samples: [Float]) async throws -> String

    /// Rough resident cost, so the keyboard can refuse a provider it cannot afford.
    var approximateMemoryFootprintMB: Int { get }

    /// Called at launch. Local models download here; cloud providers no-op.
    func prepare() async throws
}

public extension SpeechProvider {
    func prepare() async throws {}
}

// MARK: - WAV

/// Cloud speech APIs want a container, not raw floats. This is the smallest
/// correct 16-bit PCM WAV writer that will satisfy them.
public enum WAVEncoder {

    public static func encode(samples: [Float], sampleRate: Int = 16_000) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)

        let byteRate = sampleRate * 2          // mono, 16-bit
        let dataSize = samples.count * 2

        func append(_ string: String) {
            data.append(contentsOf: Array(string.utf8))
        }
        func append32(_ value: Int) {
            var v = UInt32(truncatingIfNeeded: value).littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        func append16(_ value: Int) {
            var v = UInt16(truncatingIfNeeded: value).littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }

        append("RIFF")
        append32(36 + dataSize)
        append("WAVE")

        append("fmt ")
        append32(16)          // PCM chunk size
        append16(1)           // PCM format
        append16(1)           // mono
        append32(sampleRate)
        append32(byteRate)
        append16(2)           // block align
        append16(16)          // bits per sample

        append("data")
        append32(dataSize)

        for sample in samples {
            // Clamp before scaling, otherwise a hot mic wraps around and clicks.
            let clamped = max(-1.0, min(1.0, sample))
            let scaled = Int16(clamped * 32767.0)
            var le = scaled.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        return data
    }
}

// MARK: - Trimming

public enum AudioUtil {

    /// Strip leading and trailing near-silence. Cuts upload size and stops the
    /// model hallucinating words out of room tone, which is the single most
    /// common source of phantom text.
    public static func trimSilence(
        _ samples: [Float],
        threshold: Float = 0.012,
        windowMS: Int = 30,
        sampleRate: Int = 16_000
    ) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let window = max(1, sampleRate * windowMS / 1000)

        func isLoud(_ range: Range<Int>) -> Bool {
            var sum: Float = 0
            for i in range { sum += samples[i] * samples[i] }
            return (sum / Float(range.count)).squareRoot() > threshold
        }

        var start = 0
        while start + window < samples.count, !isLoud(start..<(start + window)) {
            start += window
        }

        var end = samples.count
        while end - window > start, !isLoud((end - window)..<end) {
            end -= window
        }

        guard start < end else { return [] }

        // Leave a little air either side so the first phoneme is not clipped.
        let pad = sampleRate / 20   // 50 ms
        let lo = max(0, start - pad)
        let hi = min(samples.count, end + pad)
        return Array(samples[lo..<hi])
    }

    /// Root mean square, for a live level meter.
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}
