using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Dictator;

/// <summary>
/// The combined result of one round trip to <c>/v1/dictate</c>: the raw transcript
/// and the server-cleaned text. Mirrors DictateResult in Backend.swift. The app runs
/// its own safety guards on the pair (<see cref="Cleaner"/>), so a bad server-side
/// cleanup can never overwrite the user's words.
/// </summary>
public readonly record struct DictateResult(string Raw, string Cleaned, bool DidClean);

/// <summary>
/// Talks to the Dictator backend — the same Cloudflare Worker the macOS/iOS apps use,
/// which holds the Groq key server-side. Base URL and the multipart contract are
/// ported verbatim from Sources/DictationCore/Backend.swift.
///
/// Cloud transcription + cleanup happen in a SINGLE round trip (the premium fast
/// path): the backend does both Groq calls and returns { raw, text, cleaned }.
/// </summary>
public sealed class Backend
{
    /// <summary>
    /// Deployed Worker base URL. Change here if the Worker is re-homed on a custom
    /// domain. Ported from Backend.baseURL in Backend.swift.
    /// </summary>
    public const string BaseUrl = "https://dictator-backend.jeremydirons.workers.dev";

    private const string TranscribeModel = "whisper-large-v3-turbo";

    // One shared HttpClient for the whole app: it pools connections, so the /healthz
    // warm-up below primes the exact TLS connection the POST rides on (same trick as
    // Backend.warmConnection in the Swift app). HttpClient is thread-safe.
    private static readonly HttpClient Http = new()
    {
        Timeout = TimeSpan.FromSeconds(150),
    };

    private readonly string _deviceId;

    public Backend(string deviceId) => _deviceId = deviceId;

    /// <summary>
    /// Open (and pool) a TLS connection ahead of time so the request that follows
    /// reuses a warm connection. Fire-and-forget; failure never affects dictation.
    /// Call this when a capture starts — the user is still speaking, so it happens in
    /// the dead time before there is anything to send.
    /// </summary>
    public void WarmConnection()
    {
        _ = Task.Run(async () =>
        {
            try
            {
                using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                using var resp = await Http.GetAsync($"{BaseUrl}/healthz", cts.Token).ConfigureAwait(false);
            }
            catch
            {
                // Ignored on purpose.
            }
        });
    }

    /// <summary>
    /// POST a WAV to <c>/v1/dictate</c> with the cleanup system prompt for the current
    /// mode, and parse { raw, text, cleaned }. <paramref name="wav"/> must already be a
    /// 16 kHz mono PCM16 WAV. <paramref name="biasTerms"/> is optional vocabulary bias.
    /// </summary>
    public async Task<DictateResult> DictateAsync(
        byte[] wav,
        string system,
        IReadOnlyList<string>? biasTerms = null,
        CancellationToken ct = default)
    {
        using var form = new MultipartFormDataContent($"Boundary-{Guid.NewGuid()}");

        var fileContent = new ByteArrayContent(wav);
        fileContent.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
        form.Add(fileContent, "file", "audio.wav");

        form.Add(new StringContent(TranscribeModel), "model");
        form.Add(new StringContent("en"), "language");
        form.Add(new StringContent(system), "system");

        if (biasTerms is { Count: > 0 })
        {
            // Same shape as the Swift app: cap at 80 terms so the prompt stays small.
            var terms = string.Join(", ", biasTerms.Take(80));
            form.Add(new StringContent($"Vocabulary: {terms}"), "prompt");
        }

        using var request = new HttpRequestMessage(HttpMethod.Post, $"{BaseUrl}/v1/dictate")
        {
            Content = form,
        };
        // Stable per-install id so the backend can rate-limit per device. Not PII.
        request.Headers.Add("X-Device-Id", _deviceId);

        using var response = await Http.SendAsync(request, ct).ConfigureAwait(false);
        var payload = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);

        if (!response.IsSuccessStatusCode)
            throw new BackendException((int)response.StatusCode, payload);

        DictateResponse? json;
        try
        {
            json = JsonSerializer.Deserialize<DictateResponse>(payload, JsonOptions);
        }
        catch (JsonException e)
        {
            throw new BackendException(-1, $"Unparseable response: {e.Message}");
        }
        if (json is null)
            throw new BackendException(-1, "Empty response.");

        var raw = (json.Raw ?? string.Empty).Trim();
        var text = (json.Text ?? string.Empty).Trim();
        var didClean = json.Cleaned;

        // Same normalization as the Swift app: `text` is the cleaned string, `raw` is
        // the transcript; if the server couldn't clean, it returns text == raw with
        // cleaned=false.
        return new DictateResult(
            Raw: raw.Length == 0 ? text : raw,
            Cleaned: text.Length == 0 ? raw : text,
            DidClean: didClean);
    }

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    private sealed class DictateResponse
    {
        [JsonPropertyName("raw")] public string? Raw { get; set; }
        [JsonPropertyName("text")] public string? Text { get; set; }
        [JsonPropertyName("cleaned")] public bool Cleaned { get; set; }
    }
}

public sealed class BackendException : Exception
{
    public int StatusCode { get; }
    public BackendException(int statusCode, string body)
        : base(statusCode >= 0 ? $"Server returned {statusCode}." : body)
    {
        StatusCode = statusCode;
    }
}
