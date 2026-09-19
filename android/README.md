# Dictator for Android

The Android version of Dictator, a dictation keyboard (IME). It mirrors the iOS
app's core function and reuses the **same Cloudflare backend** — no new backend,
no API key in the app.

Speak into any text field: the keyboard records your voice, uploads it to the
Dictator Worker for transcription + cleanup in a single round trip, and types the
finished text back into the field.

## Platform note (why this differs from iOS)

On iOS, an app extension **cannot** open the microphone, so the iOS keyboard hands
off to its container app to record. On Android, an `InputMethodService` **can**
record audio directly (with `RECORD_AUDIO` granted). So the Android keyboard
records, uploads, and inserts the result itself — there is no container-app / wake
dance.

## Project layout

```
android/
  settings.gradle.kts
  build.gradle.kts                 # root; plugin versions
  gradle.properties
  gradle/wrapper/…                 # wrapper config (see "Building")
  app/
    build.gradle.kts               # module; deps (OkHttp, Compose, coroutines)
    src/main/
      AndroidManifest.xml          # IME service + RECORD_AUDIO/INTERNET + MainActivity
      res/xml/method.xml           # IME metadata (android.view.im)
      res/values/…                 # strings, theme
      java/design/irons/dictator/
        DictatorInputMethodService.kt   # the keyboard: mic, recording, insert
        Backend.kt                       # /v1/dictate client + deviceId (SharedPreferences)
        WavEncoder.kt                    # 16 kHz mono PCM16 WAV writer
        AudioUtil.kt                     # silence trimming
        ToneProfiles.kt                  # ported prompts + DictationMode + persistence
        Cleaner.kt                       # cleanup safety net (empty/refusal/fidelity guards)
        MainActivity.kt                  # Compose setup screen
```

## Backend contract (shared with iOS/macOS)

- Base URL: `https://dictator-backend.jeremydirons.workers.dev` (same as
  `Backend.baseURL` in `Sources/DictationCore/Backend.swift`).
- `POST /v1/dictate`, `multipart/form-data`:
  - `file` — the WAV (16 kHz, mono, 16-bit PCM, little-endian, 44-byte header)
  - `model` — `whisper-large-v3-turbo`
  - `language` — `en`
  - `system` — the cleanup system prompt: `base + "\n\n" + mode.instructions`
  - `prompt` — optional vocabulary bias
  - header `X-Device-Id` — a stable random per-install UUID (rate limiting)
- Response JSON: `{ raw, text, cleaned }`. `text` is the cleaned string; `raw` is
  the transcript. If the server could not clean, `text == raw` and
  `cleaned == false`.

The keyboard then runs `Cleaner.reconcile(raw, cleaned, mode)`, which falls back
to `raw` if the cleaned text is empty or looks like a refusal, and (for
non-wording-transform modes) if it dropped/ballooned/diverged from the words said.
For `PATOIS` and `SHAKESPEAREAN` (`transformsWording == true`) the fidelity guards
are skipped, because those modes legitimately rewrite the words.

## Modes

All seven iOS modes are ported verbatim from `ToneProfile.swift`: `super casual`,
`Casual`, `Formal`, `Expressive`, `Emoji`, `Patois`, `Shakespearean`. The base
cleanup prompt is copied character-for-character so Android and iOS clean the same
way. The current mode is persisted in `SharedPreferences` and can be changed from
the setup screen or by tapping the style pill on the keyboard.

## Building

Open `android/` in Android Studio (Giraffe or newer) and let it sync, then Run, or
from the command line:

```bash
cd android
gradle wrapper          # first time only: generates ./gradlew + gradle-wrapper.jar
./gradlew assembleDebug
```

> The Gradle **wrapper jar** (`gradle/wrapper/gradle-wrapper.jar`) and the
> `gradlew` / `gradlew.bat` scripts are **not checked in** here (a binary jar).
> Run `gradle wrapper` once (any locally installed Gradle 8.x) to generate them;
> `gradle/wrapper/gradle-wrapper.properties` already pins the distribution
> (Gradle 8.9). Android Studio will also offer to set the wrapper up on first open.

Toolchain expectations:
- AGP 8.5.2, Kotlin 1.9.24, Compose compiler 1.5.14
- JDK 17
- compileSdk / targetSdk 34, minSdk 26

## Enabling the keyboard (on device)

1. Launch the **Dictator** app.
2. **Step 1** — open keyboard settings and switch Dictator on.
3. **Step 2** — grant the microphone permission (an IME cannot request runtime
   permissions itself, so it is granted here).
4. In any app, tap a text field, then the globe / keyboard-switch key, and pick
   **Dictator**.
5. Hold the mic and speak (release to send), or tap once to start and again to
   stop.

## What's stubbed / v1 scope

- **On-device transcription is not implemented.** v1 is **cloud-only**: every
  dictation posts to the backend, so an internet connection is required. iOS/macOS
  have an on-device Parakeet/Apple path; the Android equivalent (whisper.cpp or a
  TFLite/ONNX Whisper model) is a future add. There is no local-vs-cloud engine
  toggle yet.
- **No per-app ToneProfile.** iOS picks a profile from the frontmost app's bundle
  id and mixes in a personal-dictionary hint. Android v1 uses only the base prompt
  + the user-selected mode (the load-bearing part). App-aware profiles could key
  off `EditorInfo.packageName`.
- **No personal dictionary / vocabulary bias UI.** `Backend.dictate` accepts
  `biasTerms` and forwards them as the `prompt` field, but nothing populates them
  yet.
- **QWERTY fallback keys are not included.** v1 is a mic-first surface; there is a
  mic button + a style pill and no typing keys. Use the system keyboard's switch
  key to go back to a normal keyboard to edit. (Adding a full QWERTY layout, like
  the iOS `KeyboardViewController`, is the obvious next step.)
- **No undo/redo, no clipboard fallback** for hosts that ignore `commitText`
  (iOS has both).
- **No `/v1/transcribe` or `/v1/cleanup` paths** are used — only the combined
  `/v1/dictate` fast path.
- **BYOK (bring-your-own Groq key)** is not implemented; all traffic goes through
  the backend proxy.

## Known TODOs

- [ ] Generate/check in the Gradle wrapper (`gradlew`, wrapper jar).
- [ ] Add an on-device transcription engine (whisper.cpp / TFLite) and an
      engine toggle.
- [ ] Add a full QWERTY fallback layout for editing without switching keyboards.
- [ ] App-aware ToneProfiles from `EditorInfo.packageName`.
- [ ] Personal dictionary + vocabulary bias, wired into `biasTerms`.
- [ ] Undo/redo and a clipboard fallback for hosts that drop `commitText`.
- [ ] A live audio level meter while recording (`AudioUtil` has an RMS helper on
      iOS; add the Android equivalent).
- [ ] Real app icon / adaptive icon (none bundled yet).
