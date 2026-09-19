using NAudio.Wave;

namespace Dictator;

/// <summary>
/// Microphone capture via NAudio's <see cref="WaveInEvent"/>. Captures directly at
/// 16 kHz / mono / 16-bit PCM by setting <c>WaveFormat(16000, 16, 1)</c> — Windows
/// (WASAPI/WaveIn) resamples the device's native format down for us, so we never
/// resample by hand and the bytes we collect are exactly what the backend wants.
///
/// WaveInEvent (rather than WaveIn) uses its own worker thread for callbacks, so it
/// works fine in a background tray app with no window of its own.
/// </summary>
public sealed class AudioRecorder : IDisposable
{
    private WaveInEvent? _waveIn;
    private MemoryStream _pcm = new();
    private TaskCompletionSource<bool>? _stopped;

    public bool IsRecording { get; private set; }

    /// <summary>Begin capturing. Throws if no capture device is available.</summary>
    public void Start()
    {
        if (IsRecording) return;

        _pcm = new MemoryStream();
        _stopped = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);

        _waveIn = new WaveInEvent
        {
            WaveFormat = new WaveFormat(16_000, 16, 1),
            BufferMilliseconds = 50,
        };
        _waveIn.DataAvailable += OnDataAvailable;
        _waveIn.RecordingStopped += OnRecordingStopped;

        _waveIn.StartRecording();
        IsRecording = true;
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        // BytesRecorded can be less than the buffer size; only take what was filled.
        _pcm.Write(e.Buffer, 0, e.BytesRecorded);
    }

    private void OnRecordingStopped(object? sender, StoppedEventArgs e)
    {
        _stopped?.TrySetResult(true);
    }

    /// <summary>
    /// Stop capturing and return the raw PCM16 bytes. Awaits RecordingStopped so any
    /// buffered DataAvailable is flushed before we read the stream.
    /// </summary>
    public async Task<byte[]> StopAsync()
    {
        if (!IsRecording || _waveIn is null) return Array.Empty<byte>();
        IsRecording = false;

        _waveIn.StopRecording();
        if (_stopped is not null)
            await _stopped.Task.ConfigureAwait(false);

        _waveIn.DataAvailable -= OnDataAvailable;
        _waveIn.RecordingStopped -= OnRecordingStopped;
        _waveIn.Dispose();
        _waveIn = null;

        return _pcm.ToArray();
    }

    /// <summary>Abandon a capture in progress without returning audio.</summary>
    public void Cancel()
    {
        if (_waveIn is null) return;
        IsRecording = false;
        try { _waveIn.StopRecording(); } catch { /* ignore */ }
        _waveIn.DataAvailable -= OnDataAvailable;
        _waveIn.RecordingStopped -= OnRecordingStopped;
        _waveIn.Dispose();
        _waveIn = null;
        _stopped?.TrySetResult(true);
    }

    public void Dispose()
    {
        _waveIn?.Dispose();
        _waveIn = null;
        _pcm.Dispose();
    }
}
