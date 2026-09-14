# Dictator

Local dictation for Mac and iPhone. Hold `fn` on the Mac, tap the mic on the
phone, speak, get clean text where the cursor is. Replaces Wispr Flow at $15/mo.

Status: builds on both platforms, 1.0 (1) on TestFlight. See "Honest status"
at the bottom.

---

## The thesis

Wispr's iPhone keyboard cannot record audio, so it launches its own app to do it,
then tries to hand you back. That round trip is why tapping the mic sometimes
strands you in the Wispr app. Their own docs confirm the keyboard also needs a
network connection, so the audio is going to their servers either way.

Two seams to attack:

1. **Never leave the host app.** If our keyboard records in place, the app-switch
   bug cannot happen. This is the feature.
2. **On the Mac, never touch the network.** Parakeet on the Neural Engine is fast
   enough that local beats cloud on latency, not just on privacy.

| | Wispr Flow | Flow |
|---|---|---|
| iPhone recording | Bounces to their app | In the keyboard, no switch |
| Mac transcription | Their cloud | On device |
| Works offline | No | Mac yes, phone no |
| Vocabulary | Their UI | Yours, biases the decoder before it decodes |
| Tone per app | Opaque | Editable prompts you can read |
| Cost | $15/mo | About $1/mo |

---

## Decisions made, and why

**Native Swift, not Flutter.** iOS keyboard extensions get **48 MB of RAM, hard.**
React Native crashes on exactly this ([facebook/react-native#31910](https://github.com/facebook/react-native/issues/31910),
"IOS Allows only 48 MB ram for Keyboard") and the Flutter engine is the same
weight class; [Flutter's keyboard-extension issue](https://github.com/flutter/flutter/issues/59753)
closed without support. Android IMEs are native Kotlin too. Flutter would buy the
settings screen, which is the easy part, and cost a runtime where there is no room
for one.

**Mac transcribes locally, iPhone transcribes in the cloud.** That 48 MB also rules
out an on-device model in the keyboard: Parakeet EOU is 120M parameters, which does
not fit however it is quantized. The keyboard holds audio buffers (a few MB) and
posts to Groq. The Mac has no such limit and runs Parakeet TDT v3 on the ANE.

**Transcription is a protocol, not a hard-coded call.** `SpeechProvider` has two
implementations today and leaves room for a third: relaying audio to your own Mac
over Tailscale, which would give the phone local transcription without the memory
problem. Add it later without touching anything above the protocol.

**Apple only for now.** Android is a separate native IME. Later.

---

## Quickstart

```bash
cd ~/Documents/CODE/FLOW
./setup.sh
open Probe/MicProbe.xcodeproj
```

`setup.sh` installs XcodeGen if needed and generates both projects with every
target, App Group, entitlement and Info.plist key already wired, including the
`RequestsOpenAccess` flag that half the internet forgets. Pick your signing team
in Xcode once per target, or set `DEVELOPMENT_TEAM` in `project.yml` and
regenerate.

Do not commit the `.xcodeproj` files. `project.yml` is the source of truth, and
`xcodegen generate` rebuilds them from scratch any time the structure changes.

---

## SETTLED — iOS architecture, 2026-09-14

### The experiment

Control and treatment, same device (iPhone 16 Pro Max, iOS 26.6.2), same build,
microphone permission GRANTED via the container app:

| | Result |
|---|---|
| Record in the **container app** | **WORKS — 149,820 bytes** |
| Record in the **keyboard extension** | fails, all 6 configs, 3 API families |

The block is the extension, not the device, the build, or the configuration.

### Why, with a citation instead of a theory

Apple documented this in 2014 and has never changed it.
**QA1872, "Recording Audio from an App Extension":**
https://developer.apple.com/library/archive/qa/qa1872/_index.html

> App extensions are not allowed to record audio... AVAudioRecorder `record`,
> AVAudioEngine `startAndReturnError` **in cases where the inputNode object is
> used**, `AudioQueueStart()` when used with `AudioQueueNewInput()`,
> `AUGraphStart()` or `AudioOutputUnitStart()` if the input element on the
> Remote I/O (`kAudioUnitSubType_RemoteIO`) audio unit has been enabled.

All four API families. AudioQueue and RemoteIO are NOT an untested frontier;
they are on the same list. Do not try them.

The gate is in mediaserverd and states its own reason:

    CMSUtility_IsAllowedToStartRecording: ... was NOT allowed to start recording
    because it is an extension and doesn't have entitlements to record audio.

It fires at **IO start**, not at session activation. That is why `setCategory`
and `setActive(true)` succeed and `inputNode.outputFormat` returns 48000 Hz:
those are session-server operations that never touch record permission. The
48 kHz route was a route *description*, not a live stream. 2003329396 ('what')
is that refusal surfacing as a generic AudioUnit start failure.

**`hasDictationKey` is read-only system state, not a capability grant.**
Overriding it does nothing. The forum thread that suggested it (775077) ends
with the developer asking for confirmation and receiving no answer.

### Sources that are actually evidence

- `github.com/fmachta/WhisperBoard` — implemented in-extension capture, tested on
  device, reverted. Commit: *"Fix keyboard crash: remove AVAudioSession, delegate
  recording to main app"*, and the class doc now reads *"Keyboard extensions
  cannot use AVAudioSession - must use main app."*
- `github.com/getdictus/dictus-ios` — shipping, iOS 26 target. Zero occurrences of
  AVAudioEngine / AVAudioSession / AudioQueue / AudioUnit / installTap /
  AVAudioRecorder anywhere in the keyboard target. All audio in the container app.

**NOT evidence:** `github.com/asre1212/Dictation`. Its own feasibility doc states
it was "researched and written in a Linux container with no Xcode, no macOS and
no iPhone" and that the microphone claim is "inferred from public evidence, not
from a device." It was cited during this session as if it were a working
implementation. It is not.

---

## THE ARCHITECTURE (this is what we build)

Confirmed by Willow's own support documentation:

> Apple does not allow any third-party app or keyboard to start using the
> microphone in the background unless the app is active first... You only get
> pulled back into Willow **when background microphone access is first being
> turned on.** After it is already active, you can keep dictating in any app,
> press the microphone button from the keyboard, move between apps freely.

### Components

1. **Container app**
   - `UIBackgroundModes: ["audio"]`
   - `NSMicrophoneUsageDescription`
   - App Group `group.design.irons.dictator`
   - Live Activity so the session is visible and stoppable (Apple expects this,
     and users see the orange mic indicator regardless)

2. **The warm engine.** The app starts `AVAudioEngine` while foregrounded and
   **never stops it**. Stopping IO is what loses the right to restart in the
   background. Dictus's code comments this explicitly: stop collects samples,
   "no engine stop!"

3. **Keyboard triggers by Darwin notification, not by launching the app.**

   ```swift
   // App alive in background: it hears this and records. No app switch.
   DarwinNotificationCenter.post(.startRecording)

   // Cold start only: if nothing answers in 0.5s, launch via URL.
   DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
       guard self.status == .requested else { return }
       self.controller?.extensionContext?.open(URL(string: "dictator://dictate")!)
   }
   ```

   Use `extensionContext.open`, not SwiftUI `openURL`: the latter has no success
   result and fails silently in a keyboard extension. On current iOS a keyboard
   gets `false` back from `extensionContext.open` too, and nothing launches. The
   responder-chain `openURL:` walk that worked around this was removed on
   2026-09-14 ahead of App Store submission (it is private-API-adjacent), so a
   cold start now asks the user to open the app by hand. It is rare: the app
   stays resident by playing silence, so a cold start only follows a kill.

4. **Result path:** app writes transcript to the App Group, posts a Darwin
   notification back, keyboard reads it and calls `textDocumentProxy.insertText`.

### Known costs, stated plainly

- **The first dictation of a session bounces to the app.** Unavoidable for
  everyone, Wispr and Willow included. Our job is to make it happen once and
  make it fast, not to eliminate it.
- **iOS 26.4 broke auto-return.** A keyboard can no longer identify its host app;
  every method returns nil (Apple Forums 826851, FB22247647, no Apple reply).
  Wispr now instructs users to swipe back manually. Nobody has solved this.
- **Guideline 4.4.1** says a keyboard must not launch other apps. Willow and
  Wispr ship this anyway. Reviewer-dependent risk, not a settled allowance.
- **Background audio mode** on an app that is not playing audio invites review
  scrutiny. The Live Activity and the visible indicator are how shipping apps
  justify it.

---

## Do this first

`Probe/MicProbeKeyboard.swift` is a twenty-minute test that answers the one
question everything else rests on: **can a keyboard extension open the microphone
on your phone?** Instructions are in the file header. Run it before writing
another line.

- Green, engine running → build as specced.
- Red, 561145187 → in-process recording is unavailable on your OS, and you are
  stuck with the same App Group handoff that makes Wispr bounce. Worth knowing on
  day one rather than day four.

The `RequestsOpenAccess` + `hasDictationKey` pair comes from an Apple engineer on
[forum thread 775077](https://developer.apple.com/forums/thread/775077), but the
associated bug report is still open and Wispr evidently could not rely on it.
Treat it as unverified until the probe says otherwise.

---

## Layout

```
Package.swift                     SPM, depends on FluidAudio
Sources/DictationCore/
  SpeechProvider.swift            protocol + WAV encoder + silence trimming
  LocalParakeet.swift             Mac, on-device, via FluidAudio
  GroqTranscription.swift         iPhone, cloud, biases decoder with your vocab
  Cleanup.swift                   LLM pass, pluggable, degrades to raw on failure
  PersonalDictionary.swift        App Group + iCloud KV, learns from corrections
  ToneProfile.swift               per-app prompts, editable
  DictationSession.swift          one utterance start to finish, shared
  AudioRecorder.swift             mic to 16 kHz mono Float32
macOS/
  DictatorApp.swift                   menu bar agent + settings
  HotkeyMonitor.swift             CGEventTap on fn
  MacTextInserter.swift           accessibility, falling back to paste
iOS/DictatorApp/ContentView.swift     container: setup, API key, vocabulary
iOS/DictatorKeyboard/                 the keyboard itself
Probe/                            run this first
  project.yml                     standalone probe project
  Keyboard/KeyboardViewController.swift
project.yml                       XcodeGen spec for the real project
setup.sh                          generates both projects
```

`Sources/DictationCore/Transcriber.swift` is a tombstone from an earlier pass.
Delete it.

---

## The four things that will eat your week

### 1. The keyboard microphone
Covered above. Probe first.

### 2. The fn key
`fn` emits no keycode, only `.flagsChanged` carrying `.maskSecondaryFn`. Carbon's
`RegisterEventHotKey` cannot see it. You need a `CGEventTap` (or `IOHIDManager`),
which needs Accessibility permission, which does not take effect until relaunch.

Then: **macOS already owns fn.** Set System Settings › Keyboard › "Press 🌐 to" to
"Do Nothing" or you will fight the system dictation popup forever. `HotkeyMonitor`
offers Right Option as an uncontested alternative.

Re-enable the tap on `.tapDisabledByTimeout`. The system kills slow taps, and
without re-arming the hotkey dies silently after one hiccup. Already handled.

### 3. Text insertion
Accessibility (`kAXSelectedText`) is clean and leaves the clipboard alone but most
Electron apps ignore it. Pasteboard plus synthetic Cmd-V works everywhere and
clobbers the clipboard. `MacTextInserter` tries the first, falls back to the
second, and snapshots every pasteboard representation rather than only the string,
so copying an image then dictating does not destroy the image.

### 4. Keyboard memory
48 MB, and exceeding it kills the keyboard mid-sentence with no error. No model in
that process, ever. Watch it in Instruments with the Allocations template attached
to the extension, not the app.

---

## Build order

**Today.** Run the probe. Then the Mac path end to end with no cleanup:
fn → record → Parakeet → paste. That alone probably replaces Wispr for most of
your typing.

**Day 2.** Cleanup pass and tone profiles. Compare with and without; raw Parakeet
plus the dictionary may be good enough to skip the LLM entirely.

**Day 3.** iOS container app, App Group, keyboard UI, Groq path.

**Day 4.** Dictionary sync, learn-from-correction, undo.

**Later.** Mac relay as a third `SpeechProvider`. A "send to Maestro" action on the
keyboard, so dictating on the phone can create a vault item directly. Neither
Wispr nor anyone else does that.

---

## Xcode setup checklist

- Targets: Mac app, iOS app, keyboard extension, plus the `DictationCore` package
- App Group `group.design.irons.dictator` on all three app targets
- iCloud key-value store on the Mac and iOS app targets
- Mac: `LSUIElement = true`, `NSMicrophoneUsageDescription`, Accessibility prompt
- Keyboard: `RequestsOpenAccess = true`
- `NSMicrophoneUsageDescription` goes on the **container app**; the extension
  inherits it
- Groq key: Keychain on Mac, App Group defaults on iOS

---

## Cost

Mac transcription is free and offline. iPhone transcription on Groq
whisper-large-v3-turbo is roughly $0.04 per hour of audio. Cleanup, if you leave it
on, is about a cent an hour. Heavy use (30 min/day) lands near **$1/month**. Set
the cleanup provider to `nil` and the phone alone costs pennies.

---

## Honest status

Both targets compile (Xcode 26.0.1, Swift 6.2, FluidAudio 0.15.7) and the iOS
app is on TestFlight as 1.0 (1). Dictation works end to end on both platforms.

What is verified and what is not:

- `LocalParakeet.prepare()` compiles against the real FluidAudio API as of
  0.15.7 (`AsrModels.downloadAndLoad(version:)`, `AsrManager.loadModels`,
  `transcribe(_:decoderState:)`). It has not yet been watched loading on a Mac;
  the Groq fallback covers a failure. `from: 0.12.4` in `project.yml` floats to
  the newest 0.x, so the resolved checkout under DerivedData is the one to read
  when a signature is in doubt.
- Whether the orange mic indicator stays off between dictations, now that the
  session is `.playAndRecord` from warm-up, is unverified on device.
- The keyboard has never been seen at iPad width. `TARGETED_DEVICE_FAMILY` is
  still "1,2".

## Gotcha: the tap block that trapped on the first audio buffer

Symptom: the app asks for microphone permission, then the whole UI goes dead.
Nothing is tappable. Xcode shows `_dispatch_assert_queue_fail` on a thread named
for the realtime audio queue, with `BUG IN CLIENT OF LIBDISPATCH: Assertion
failed: Block was expected to execute on queue`.

Cause: a closure written inside a `@MainActor` method inherits main-actor
isolation. Under Swift 6 the compiler honours that by emitting a
`dispatch_assert_queue` at the top of the block. CoreAudio calls a tap block from
`AURemoteIO::IOThread` and never from the main queue, so the assertion fires on
the first buffer and the process traps. `@preconcurrency import AVFoundation`
silences the *warning* about this without removing the *check*, which is what
makes it look like a runtime mystery rather than a compile error.

Fix: form the tap block in a nonisolated context. `AudioTap` in
`BackgroundRecorder.swift` owns the converter, the target format and the sample
buffer, and hands back a block from `makeBlock()`. Nothing on the audio path
touches the main actor now. The level meter is polled at 20 Hz from a main-queue
timer instead of pushed, which also removes roughly twenty `Task` allocations a
second.

`AudioRecorder` (the Mac path) was never affected: its class is not main-actor
isolated, and its callback parameter is `@Sendable`, which does not inherit
isolation.

## Secrets

The Groq key lives in `Sources/DictationCore/Secrets.swift`, which is gitignored.
Locally, copy `Secrets.swift.example` to `Secrets.swift` and paste your key. In
Xcode Cloud, `ci_scripts/ci_post_clone.sh` writes the file from the
`GROQ_API_KEY` secret environment variable before generating the project.

On iOS, `seedAPIKeyIfNeeded()` in `ContentView.swift` copies `BuildSecrets.groqAPIKey`
into the App Group once, so the keyboard extension can read it. A key typed into
the settings screen replaces it. Check `git log --stat` before pushing anything
near this file.

## Gotcha: the Mac target and Swift 6

The Mac target rotted silently for a while because Xcode Cloud builds the iOS
scheme and nothing built the Mac one. When it was next compiled (2026-09-14)
Swift 6 language mode refused five things, all fixed now and worth knowing:

- A stored `static let` holding `UserDefaults` is "shared mutable state". Make it
  a computed property.
- `kAXTrustedCheckOptionPrompt` is a mutable C global and cannot be read from
  Swift 6. Its value is the fixed string `"AXTrustedCheckOptionPrompt"`.
- `HotkeyMonitor` is `@MainActor`: its tap source is on the main run loop, so
  the C callback enters it through `MainActor.assumeIsolated`. That closure can
  only return `Sendable` values, and `Unmanaged<CGEvent>` is not one, so the
  handler returns a `Bool` and the callback maps it to the event.
- The press and release handlers are deferred with `Task { @MainActor in }`
  rather than `DispatchQueue.main.async`, which cannot capture a non-Sendable
  self. The deferral matters: a slow tap callback gets the tap disabled.

## Versions

`MARKETING_VERSION` in `project.yml` is ratcheted by hand on every push
(0.1.x until the first App Store release), and Xcode Cloud supplies the build
number from `CI_BUILD_NUMBER`. The settings screen shows both at the bottom, so
"which build is this?" is answered on the phone. A push that does not bump the
version is a mistake.

## Housekeeping

`Flow.xcodeproj` is a leftover from the rename and should go.
