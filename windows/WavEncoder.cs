namespace Dictator;

/// <summary>
/// Writes a minimal, correct 16-bit PCM WAV (44-byte header + samples). Mirrors
/// WAVEncoder in Sources/DictationCore/SpeechProvider.swift: 16 kHz, mono, 16-bit
/// PCM, little-endian. NAudio captures directly at this format (WaveFormat(16000,16,1))
/// so there is no resampling — the bytes it hands us are already PCM16 LE, and we
/// just wrap them in a header.
/// </summary>
public static class WavEncoder
{
    /// <param name="pcm16">Raw interleaved 16-bit little-endian PCM, mono.</param>
    public static byte[] Encode(byte[] pcm16, int sampleRate = 16_000)
    {
        const int channels = 1;
        const int bitsPerSample = 16;
        int byteRate = sampleRate * channels * bitsPerSample / 8; // mono, 16-bit
        int blockAlign = channels * bitsPerSample / 8;
        int dataSize = pcm16.Length;

        using var ms = new MemoryStream(44 + dataSize);
        using var w = new BinaryWriter(ms);

        // BinaryWriter is little-endian on all platforms .NET runs on, which matches
        // the WAV spec, so no manual byte swapping is needed.
        void Ascii(string s) => w.Write(System.Text.Encoding.ASCII.GetBytes(s));

        Ascii("RIFF");
        w.Write(36 + dataSize);        // ChunkSize
        Ascii("WAVE");

        Ascii("fmt ");
        w.Write(16);                   // PCM fmt chunk size
        w.Write((short)1);             // AudioFormat = PCM
        w.Write((short)channels);      // mono
        w.Write(sampleRate);
        w.Write(byteRate);
        w.Write((short)blockAlign);
        w.Write((short)bitsPerSample);

        Ascii("data");
        w.Write(dataSize);
        w.Write(pcm16);

        w.Flush();
        return ms.ToArray();
    }
}

/// <summary>
/// Audio helpers ported from AudioUtil in SpeechProvider.swift, operating on PCM16
/// bytes instead of Float32 samples.
/// </summary>
public static class AudioUtil
{
    /// <summary>
    /// Strip leading and trailing near-silence. Cuts upload size and stops the model
    /// hallucinating words out of room tone, which is the single most common source of
    /// phantom text. Operates on 16-bit little-endian mono PCM.
    /// </summary>
    public static byte[] TrimSilence(
        byte[] pcm16,
        float threshold = 0.012f,
        int windowMs = 30,
        int sampleRate = 16_000)
    {
        int sampleCount = pcm16.Length / 2;
        if (sampleCount == 0) return pcm16;

        int window = Math.Max(1, sampleRate * windowMs / 1000);

        float SampleAt(int i)
        {
            // Little-endian signed 16-bit -> normalized [-1, 1].
            short s = (short)(pcm16[i * 2] | (pcm16[i * 2 + 1] << 8));
            return s / 32768f;
        }

        bool IsLoud(int start, int len)
        {
            double sum = 0;
            for (int i = start; i < start + len; i++)
            {
                float v = SampleAt(i);
                sum += (double)v * v;
            }
            return Math.Sqrt(sum / len) > threshold;
        }

        int startIdx = 0;
        while (startIdx + window < sampleCount && !IsLoud(startIdx, window))
            startIdx += window;

        int endIdx = sampleCount;
        while (endIdx - window > startIdx && !IsLoud(endIdx - window, window))
            endIdx -= window;

        if (startIdx >= endIdx) return Array.Empty<byte>();

        // Leave a little air either side so the first phoneme is not clipped.
        int pad = sampleRate / 20; // 50 ms
        int lo = Math.Max(0, startIdx - pad);
        int hi = Math.Min(sampleCount, endIdx + pad);

        int byteStart = lo * 2;
        int byteLen = (hi - lo) * 2;
        var trimmed = new byte[byteLen];
        Array.Copy(pcm16, byteStart, trimmed, 0, byteLen);
        return trimmed;
    }
}
