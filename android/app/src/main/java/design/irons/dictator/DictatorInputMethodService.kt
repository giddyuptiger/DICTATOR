package design.irons.dictator

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.inputmethodservice.InputMethodService
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.SystemClock
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The Dictator keyboard for Android.
 *
 * PLATFORM NOTE: unlike iOS — where an app extension is forbidden from opening the
 * microphone (QA1872), forcing the iOS keyboard to hand off to its container app —
 * an Android InputMethodService CAN record audio directly, as long as RECORD_AUDIO
 * is granted. So there is no container-app / wake dance here: the keyboard records,
 * uploads, and inserts the result itself.
 *
 * The input view is intentionally a classic View hierarchy (not Compose): an IME's
 * input view is created/destroyed by the framework and lives outside a normal
 * Activity, which is exactly what the View system is built for. The setup screen
 * (MainActivity) is Compose.
 *
 * Pipeline on stop:
 *   AudioRecord (16 kHz mono PCM16) -> trim silence -> WAV -> POST /v1/dictate
 *   with the mode's system prompt + X-Device-Id -> {raw, text, cleaned}
 *   -> Cleaner.reconcile -> currentInputConnection.commitText(...)
 */
class DictatorInputMethodService : InputMethodService() {

    private enum class UiState { IDLE, RECORDING, WORKING, NO_PERMISSION }

    // Main-thread scope for UI updates; the network/audio work hops to Dispatchers.IO.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    // --- Recording state -----------------------------------------------------
    private var audioRecord: AudioRecord? = null
    private var recordThread: Thread? = null
    @Volatile private var recording = false
    private val chunks = ArrayList<ShortArray>()
    private var dictateJob: Job? = null

    // Distinguishes hold-to-talk from tap-to-toggle.
    private var pressDownAt = 0L
    private var wasRecordingBeforeDown = false
    private val holdThresholdMs = 220L

    // --- Views ---------------------------------------------------------------
    private lateinit var micButton: Button
    private lateinit var statusLabel: TextView
    private lateinit var modeButton: Button

    private var uiState = UiState.IDLE

    companion object {
        private const val SAMPLE_RATE = 16_000
    }

    // MARK: - View construction

    override fun onCreateInputView(): View {
        val density = resources.displayMetrics.density
        fun dp(v: Int) = (v * density).toInt()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(12), dp(16), dp(16))
            setBackgroundColor(Color.parseColor("#1C1C1E"))
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            )
        }

        // Top row: small mode indicator on the left, status hint on the right.
        val topRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            )
        }

        modeButton = Button(this).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            setTextColor(Color.WHITE)
            isAllCaps = false
            setPadding(dp(14), dp(6), dp(14), dp(6))
            background = pill(Color.parseColor("#3A3A3C"))
            setOnClickListener { cycleMode() }
        }
        topRow.addView(
            modeButton,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )

        statusLabel = TextView(this).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            setTextColor(Color.parseColor("#AEAEB2"))
            gravity = Gravity.END
            text = "Tap or hold to talk"
        }
        topRow.addView(
            statusLabel,
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
                marginStart = dp(12)
            },
        )

        root.addView(topRow)

        // The mic: the whole point of this keyboard. Big, prominent, records while
        // held or toggled with a tap.
        micButton = Button(this).apply {
            text = "🎤  Dictate" // 🎤
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
            setTextColor(Color.WHITE)
            isAllCaps = false
            background = pill(Color.parseColor("#2B4E9B"))
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                dp(96),
            ).apply { topMargin = dp(12) }
            setOnTouchListener(micTouchListener)
        }
        root.addView(micButton)

        return root
    }

    private fun pill(color: Int): GradientDrawable = GradientDrawable().apply {
        setColor(color)
        cornerRadius = 18f * resources.displayMetrics.density
    }

    override fun onStartInputView(info: android.view.inputmethod.EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        refreshModeLabel()
        // Re-evaluate the mic permission each time the keyboard appears (the user
        // may have granted it in the app since last time).
        uiState = if (hasMicPermission()) UiState.IDLE else UiState.NO_PERMISSION
        render()
    }

    // MARK: - Mic interaction (hold-to-talk + tap-to-toggle)

    private val micTouchListener = View.OnTouchListener { _, event ->
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                pressDownAt = SystemClock.elapsedRealtime()
                wasRecordingBeforeDown = recording
                if (uiState == UiState.WORKING) return@OnTouchListener true
                if (!recording) startRecording()
                true
            }

            MotionEvent.ACTION_UP -> {
                if (uiState == UiState.WORKING) return@OnTouchListener true
                val held = SystemClock.elapsedRealtime() - pressDownAt >= holdThresholdMs
                when {
                    // A tap while already recording (toggle) stops it.
                    wasRecordingBeforeDown -> stopRecordingAndDictate()
                    // A press-and-hold that just started recording stops on release.
                    held -> stopRecordingAndDictate()
                    // A quick tap that just started recording leaves it running
                    // (toggle mode armed); the next tap will stop it.
                    else -> { /* keep recording */ }
                }
                true
            }

            MotionEvent.ACTION_CANCEL -> {
                if (recording && !wasRecordingBeforeDown) stopRecordingAndDictate()
                true
            }

            else -> false
        }
    }

    // MARK: - Recording

    private fun startRecording() {
        if (!hasMicPermission()) {
            uiState = UiState.NO_PERMISSION
            render()
            return
        }

        val minBuffer = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuffer <= 0) {
            flash("Microphone unavailable")
            return
        }
        // A generous buffer (>= 0.5 s) so a busy main thread never drops audio.
        val bufferSize = maxOf(minBuffer, SAMPLE_RATE) // ~1 s of 16-bit mono

        val recorder = try {
            @Suppress("MissingPermission")
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                bufferSize,
            )
        } catch (e: Exception) {
            flash("Couldn't start microphone")
            return
        }

        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            recorder.release()
            flash("Couldn't start microphone")
            return
        }

        chunks.clear()
        audioRecord = recorder
        recording = true
        recorder.startRecording()

        // Warm the TLS connection while the user is still speaking, so the POST
        // that follows reuses it. Fire-and-forget on IO.
        scope.launch(Dispatchers.IO) { Backend.warmConnection() }

        // Read PCM on a dedicated thread; accumulate chunks and concatenate on stop.
        recordThread = Thread {
            val buf = ShortArray(bufferSize)
            while (recording) {
                val read = recorder.read(buf, 0, buf.size)
                if (read > 0) {
                    synchronized(chunks) { chunks.add(buf.copyOf(read)) }
                }
            }
        }.also { it.start() }

        uiState = UiState.RECORDING
        render()
    }

    private fun stopRecordingAndDictate() {
        if (!recording) return
        recording = false

        recordThread?.join(1000)
        recordThread = null

        audioRecord?.let { rec ->
            try {
                if (rec.recordingState == AudioRecord.RECORDSTATE_RECORDING) rec.stop()
            } catch (_: IllegalStateException) {
            }
            rec.release()
        }
        audioRecord = null

        val samples = synchronized(chunks) { concat(chunks) }
        chunks.clear()

        uiState = UiState.WORKING
        render()

        dictateJob?.cancel()
        dictateJob = scope.launch {
            val mode = ToneProfiles.currentMode(this@DictatorInputMethodService)
            val result = withContext(Dispatchers.IO) {
                try {
                    val trimmed = AudioUtil.trimSilence(samples)
                    val wav = WavEncoder.encode(trimmed)
                    val dictate = Backend.dictate(
                        context = this@DictatorInputMethodService,
                        wav = wav,
                        system = ToneProfiles.systemPrompt(mode),
                    )
                    // Safety net: never let a bad/empty/refusal cleanup replace the
                    // user's words. Falls back to the raw transcript when needed.
                    Result.success(Cleaner.reconcile(dictate.raw, dictate.cleaned, mode))
                } catch (e: EmptyAudioException) {
                    Result.failure(e)
                } catch (e: Exception) {
                    Result.failure(e)
                }
            }

            uiState = UiState.IDLE
            render()

            result.onSuccess { text ->
                if (text.isNotEmpty()) {
                    commit(text)
                } else {
                    flash("Nothing heard")
                }
            }.onFailure { e ->
                flash(
                    when (e) {
                        is EmptyAudioException -> "Nothing heard"
                        is BackendHttpException -> "Server error (${e.status})"
                        else -> "Dictation failed"
                    },
                )
            }
        }
    }

    /** Concatenate the recorded chunks into a single ShortArray. */
    private fun concat(parts: List<ShortArray>): ShortArray {
        val total = parts.sumOf { it.size }
        val out = ShortArray(total)
        var offset = 0
        for (p in parts) {
            System.arraycopy(p, 0, out, offset, p.size)
            offset += p.size
        }
        return out
    }

    // MARK: - Inserting the result

    private fun commit(text: String) {
        val ic = currentInputConnection ?: return
        // Add a leading space when the previous character is not whitespace and the
        // new text does not open with punctuation, so dictation appends cleanly to
        // an existing sentence (mirrors the iOS insert()).
        var out = text
        val before = ic.getTextBeforeCursor(1, 0)
        val prev = before?.lastOrNull()
        if (prev != null && !prev.isWhitespace() && !text.first().isPunctuation()) {
            out = " $out"
        }
        ic.commitText(out, 1)
    }

    private fun Char.isPunctuation(): Boolean =
        this in ".,!?;:)]}’\"'"

    // MARK: - Mode indicator

    private fun cycleMode() {
        ToneProfiles.advanceMode(this)
        refreshModeLabel()
    }

    private fun refreshModeLabel() {
        modeButton.text = ToneProfiles.currentMode(this).displayName
    }

    // MARK: - Rendering

    private fun render() {
        when (uiState) {
            UiState.IDLE -> {
                micButton.text = "🎤  Dictate"
                micButton.background = pill(Color.parseColor("#2B4E9B"))
                micButton.isEnabled = true
                statusLabel.text = "Tap or hold to talk"
            }
            UiState.RECORDING -> {
                micButton.text = "■  Listening…" // ■
                micButton.background = pill(Color.parseColor("#8A2C26"))
                micButton.isEnabled = true
                statusLabel.text = "Release, or tap to stop"
            }
            UiState.WORKING -> {
                micButton.text = "Transcribing…"
                micButton.background = pill(Color.parseColor("#3A3374"))
                micButton.isEnabled = false
                statusLabel.text = "Working"
            }
            UiState.NO_PERMISSION -> {
                micButton.text = "Enable microphone"
                micButton.background = pill(Color.parseColor("#6E4E12"))
                micButton.isEnabled = true
                statusLabel.text = "Open the Dictator app"
                // Tapping opens the setup screen to grant the permission.
                micButton.setOnClickListener { openSetup() }
            }
        }
        // Restore the record touch handler for the interactive states.
        if (uiState != UiState.NO_PERMISSION) {
            micButton.setOnClickListener(null)
            micButton.setOnTouchListener(micTouchListener)
        }
    }

    private fun openSetup() {
        val intent = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
    }

    /** Show a short message on the status line. */
    private fun flash(message: String) {
        statusLabel.text = message
    }

    private fun hasMicPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    override fun onDestroy() {
        super.onDestroy()
        recording = false
        recordThread?.join(500)
        audioRecord?.release()
        audioRecord = null
        scope.cancel()
    }
}
