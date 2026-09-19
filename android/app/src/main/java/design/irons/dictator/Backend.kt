package design.irons.dictator

import android.content.Context
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.IOException
import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * The combined result of one round trip to `/v1/dictate`: the raw transcript and
 * the server-cleaned text. The keyboard still runs its own safety guards on the
 * pair (see [Cleaner.reconcile]), so a bad server-side cleanup can never overwrite
 * the user's words. Mirrors `DictateResult` in Backend.swift.
 */
data class DictateResult(
    val raw: String,
    val cleaned: String,
    val didClean: Boolean,
)

/** Thrown when the audio was empty/too short to bother uploading. */
class EmptyAudioException : IOException("Nothing was recorded.")

/** Thrown for a non-2xx response, carrying the status for the caller's message. */
class BackendHttpException(val status: Int, body: String) :
    IOException("Server returned $status. ${body.take(200)}")

/**
 * Cloud transcription + cleanup client for the Dictator Cloudflare Worker.
 *
 * Same base URL and the same `/v1/dictate` multipart contract as iOS/macOS
 * (Sources/DictationCore/Backend.swift): the Groq key lives only in the Worker, so
 * nothing sensitive ships in the app. Fields: file (wav), model, language, system
 * (the cleanup system prompt), optional prompt (vocabulary bias). Response JSON is
 * { raw, text, cleaned }. The stable per-install `X-Device-Id` header lets the
 * backend rate-limit per device.
 */
object Backend {

    /** Deployed Worker base URL. Identical to `Backend.baseURL` on iOS. */
    const val BASE_URL = "https://dictator-backend.jeremydirons.workers.dev"

    private const val PREFS = "dictator_prefs"
    private const val KEY_DEVICE_ID = "deviceID"

    private const val TRANSCRIBE_MODEL = "whisper-large-v3-turbo"
    private const val LANGUAGE = "en"

    // One shared client so the TLS connection stays warm/pooled between dictations,
    // the way the iOS app reuses a single URLSession. Read timeout is generous
    // because a long dictation is a large upload plus Whisper time.
    private val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(20, TimeUnit.SECONDS)
            .writeTimeout(150, TimeUnit.SECONDS)
            .readTimeout(150, TimeUnit.SECONDS)
            .build()
    }

    /**
     * A stable per-install id so the backend can rate-limit per device (not just
     * per IP). Not personally identifying — a random UUID created once and kept in
     * SharedPreferences. Mirrors `Backend.deviceID` (and reuses the same
     * "deviceID" key name used by the iOS app group).
     */
    fun deviceId(context: Context): String {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.getString(KEY_DEVICE_ID, null)?.let { if (it.isNotEmpty()) return it }
        val id = UUID.randomUUID().toString()
        prefs.edit().putString(KEY_DEVICE_ID, id).apply()
        return id
    }

    /**
     * Open a connection to the backend ahead of time so the real POST reuses a warm
     * TLS connection. Fire-and-forget: called when a capture starts (the user is
     * still speaking), and any failure here is ignored. Mirrors
     * `Backend.warmConnection`.
     */
    fun warmConnection() {
        val req = Request.Builder().url("$BASE_URL/healthz").get().build()
        try {
            client.newCall(req).execute().use { /* ignore body/result */ }
        } catch (_: Exception) {
            // Warming is best-effort; a failure never affects dictation.
        }
    }

    /**
     * Transcribe + clean up in ONE round trip. Blocking — call from a background
     * dispatcher (the service uses Dispatchers.IO). Returns [DictateResult] with the
     * raw transcript and the server-cleaned text; the caller runs [Cleaner] on the
     * pair.
     *
     * @param wav 16 kHz mono PCM16 WAV bytes (see [WavEncoder]).
     * @param system the cleanup system prompt (base + selected mode).
     * @param biasTerms optional vocabulary to bias transcription toward.
     */
    @Throws(IOException::class)
    fun dictate(
        context: Context,
        wav: ByteArray,
        system: String,
        biasTerms: List<String> = emptyList(),
    ): DictateResult {
        // ~1600 samples * 2 bytes = 3200 bytes of audio; below that there is
        // effectively nothing to send (mirrors the iOS guard on trimmed samples).
        if (wav.size <= 44 + 3200) throw EmptyAudioException()

        val bodyBuilder = MultipartBody.Builder()
            .setType(MultipartBody.FORM)
            .addFormDataPart(
                "file",
                "audio.wav",
                wav.toRequestBody("audio/wav".toMediaType()),
            )
            .addFormDataPart("model", TRANSCRIBE_MODEL)
            .addFormDataPart("language", LANGUAGE)
            .addFormDataPart("system", system)

        if (biasTerms.isNotEmpty()) {
            bodyBuilder.addFormDataPart(
                "prompt",
                "Vocabulary: " + biasTerms.take(80).joinToString(", "),
            )
        }

        val request = Request.Builder()
            .url("$BASE_URL/v1/dictate")
            .header("X-Device-Id", deviceId(context))
            .post(bodyBuilder.build())
            .build()

        client.newCall(request).execute().use { response ->
            val text = response.body?.string().orEmpty()
            if (!response.isSuccessful) {
                throw BackendHttpException(response.code, text)
            }
            val json = JSONObject(text)
            // `text` is the cleaned string; `raw` is the transcript. If the server
            // couldn't clean, it returns text == raw with cleaned=false.
            val raw = json.optString("raw").trim()
            val cleaned = json.optString("text").trim()
            val didClean = json.optBoolean("cleaned", false)
            return DictateResult(
                raw = if (raw.isEmpty()) cleaned else raw,
                cleaned = if (cleaned.isEmpty()) raw else cleaned,
                didClean = didClean,
            )
        }
    }
}
