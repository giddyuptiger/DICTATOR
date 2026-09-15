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

## Warm-up can be refused by another app

`setActive(true)` at warm-up returns 560557684 (CannotInterruptOthers) when
another app is holding the microphone non-mixably at that instant, even in the
foreground. It is transient: the moment the other app finishes, warm-up
succeeds. Observed on device 2026-09-14 with the Claude app holding audio just
before Dictator launched. `warmUp()` therefore retries a few times, bounds each
attempt with a timeout so a wedged `setActive` cannot hang the app, and on final
failure lands in a state with a visible Try again button rather than a dead end.
Do NOT "fix" this with `.mixWithOthers`; that trades it for background suspension.

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

### 0.1.19 — dynamic-colour theme (kills the mix for good) + launch crash + ms UX (2026-09-15)

Three fixes.

1. *The "grey board, black keys" mix, killed structurally.* Two earlier attempts
   (a live appearance read, then a cached bool) both still let the board and the
   keys resolve to different themes. The keyboard now uses **dynamic UIColors**:
   every colour resolves against the view's trait at draw time, so the board, the
   keys and the glyphs are always the same theme — a mix is impossible, and it
   follows the system appearance automatically (per Jeremy: always follow system).
   No manual re-theming flag remains.
2. *Launch crash.* `readPending` bound `Data`'s raw buffer directly to `Float`,
   which assumes 4-byte alignment `Data` does not guarantee — undefined and able
   to crash, and it runs on launch precisely when recovering a file an earlier
   crash left behind (so: crashes on open, works after a restart). Now it copies
   into an aligned `[Float]` buffer with `copyBytes`.
3. *Milliseconds UX.* The Details "Last dictation → Time" showed raw "3101 ms";
   it now reads "3.1s".

### 0.1.18 — pastel highlights instead of neon (2026-09-15)

Cosmetic pass. The saturated system colours (neon blue/red/indigo/orange) read
as harsh. The mic pill now uses soft pastel grounds with a deep, same-hue ink
for its icon and label (blue ready/wake, rose recording, lavender busy, amber
needs-setup) — softer while staying legible and distinct by hue, and the pill
keeps its shadow so a pale pastel still lifts off the board. The app's status dot,
capture level bar, and setup checkmarks use the matching muted sage/rose/amber.
The keyboard still follows the system/host appearance (per Jeremy: always follow
system); the native Turn on/off and mode controls keep the platform's own accents.

### 0.1.17 — cleanup never destroys the words (refusal/empty fallback) (2026-09-15)

The real cause of "it fails badly on longer texts", from device logs: the mic,
capture and Whisper transcription were all fine, but the Groq *cleanup* LLM was
either returning an empty completion or treating the transcript as a request and
refusing it ("I'm sorry, but I can't help with that") — and we typed that empty
string or refusal straight into the user's document, destroying what they said.
Short dictations survived; longer/complex ones triggered it.

Three-part fix:
1. *Hardened cleanup prompt.* The system prompt now frames the transcript as
   DATA to reformat, never a message addressed to the model, and forbids
   refusing, apologising, moderating, or returning empty. If unsure, return the
   transcript unchanged.
2. *Empty routes to the next model.* An empty completion from one Groq model is
   treated like an unavailable model, so `clean()` tries the next one instead of
   giving up.
3. *The safety net (the important one).* If the cleanup result is still empty or
   reads as a refusal, `Cleaner` falls back to the raw transcript (dictionary-
   corrected) instead of the model's output. The user's words are never replaced
   by the model's failure; the Activity log records the fallback so it stays
   diagnosable. Trade-off: on a fallback the chosen mode/emoji is not applied
   (words beat formatting), but this only happens when cleanup failed anyway.

### 0.1.16 — fix the "grey board, dark keys" theme mix (2026-09-15)

The real cause of the keyboard looking wrong in light mode: `palette` was a
computed property that read the live keyboard appearance on *every* access, and
the board (set in `applyTheme`) and the keys (built in `rebuildKeys`, which also
runs on a plane switch and during initial layout) were read at different
lifecycle moments. A keyboard extension's appearance is not stable across those
moments — `keyboardAppearance` is commonly `.default` at load and resolves
later, and the trait settles after layout — so the board could come from one
theme and the keys from another, i.e. a light/grey board with dark keys.

Fix: resolve the theme once, in `applyTheme`, into a cached `resolvedDark`, and
have every element read that. `applyTheme` rebuilds the keys in the same pass, so
board and keys are always the same theme. Added a `viewDidAppear` re-apply for
the case where the appearance only finishes resolving once on screen. Also from
0.1.15: amber needs-setup states, indigo transcribing, a shadow under the mic
pill.

### 0.1.15 — crash-durable long recordings + auto-stop feedback (2026-09-15)

Follow-ups on the long-dictation work, plus a keyboard polish pass.

- *Crash mid-recording.* 0.1.14 spilled audio to disk only at the moment
  transcription started, so a crash while still recording a long dictation
  lost everything. Now the capture is flushed to disk every 20 s while it
  runs (`AudioEngineHost.snapshot()` + `persistPending`), bounding the
  worst-case loss to the last 20 seconds; the next launch recovers it.
- *Auto-stop at the 5-minute cap.* When the app ends a capture on its own at
  the cap, the keyboard now follows it into "Transcribing" with a warning
  haptic, so the user feels that it stopped and knows the words are being
  saved — instead of sitting on "Listening" while a result quietly arrives.
  The same watchdog catches the app dying mid-recording and points the user
  to reopen it (the audio was flushed).
- *Keyboard polish.* The muddy grey mic states are gone: needs-setup states
  are amber (attention), transcribing is indigo (busy), both distinct from
  the board. The mic pill gets a soft shadow so it reads as the one raised,
  tappable hero above the flat board. (The board itself is Apple's exact
  light-keyboard grey, on purpose, so Dictator matches the system keyboard
  beside it — a bigger visual direction is a separate decision.)

### 0.1.14 — reliable wake button + long-dictation safety (2026-09-15)

Two independent issues, both from the user's testing.

**Wake button "sometimes does nothing."** When the app has been jettisoned, the
keyboard offers to wake it, but the launch (responder-chain openURL from an
extension) can be silently refused — and the old code trusted it, set "Opening
Dictator…", and never corrected itself, so the button read as dead. Now every
wake tap gives haptic feedback and enters a `.waking` state that polls whether
the app actually starts stamping the App Group: it advances to ready on success
(with a success haptic), or says "Couldn't open Dictator. Open it from your Home
Screen" on failure. The common case — the app is actually alive but the
keyboard's liveness snapshot went stale — now self-heals within a couple of
seconds instead of stranding on a lying label.

**Long-dictation safety.** A five-minute dictation used to be fragile in four
ways; all four are addressed:

- *Truncation.* The capture cap was 2 minutes, so a long dictation was silently
  cut off. Raised to 5 minutes (still a hard backstop against a lost stop
  signal). ~19 MB in memory, fine.
- *Timeout.* The transcription request used a flat 20 s, which a ~10 MB upload
  plus Whisper time blows past on a slow connection, turning a good recording
  into a spurious "couldn't reach Groq". The timeout now scales with the
  recording (≈20 s + 0.4 s per second of audio, capped at 150 s).
- *The keyboard giving up too early.* It waited a flat 25 s for a result and then
  declared failure while the app was still working, stranding the transcript.
  Now it waits as long as the app keeps stamping the App Group — the real
  signals are a new result (done) or the app going silent (crashed) — and shows
  elapsed seconds so a long wait reads as progress, not a freeze.
- *Losing audio to a crash.* Captured audio was memory-only, so a crash or
  jettison mid-transcription lost the whole recording. The raw samples are now
  spilled to a file in the App Group before the network round trip and deleted
  only on a terminal outcome; the next warm-up transcribes any leftover and
  surfaces it in the app as a "Recovered dictation". The keyboard's crash
  message now says the recording was saved.

To confirm on device: (1) wake button always responds and ends in a truthful
state; (2) dictate ~3–5 minutes and confirm it isn't cut off and does transcribe;
(3) force-quit the app mid-transcription, reopen, and confirm the text appears
under "Recovered dictation".

### 0.1.13 — clean audio (two engines) + resilient cleanup model (2026-09-15)

Two bugs from the 0.1.12 device logs, both of which made dictation look
"completely broken": full sentences came back as fragments ("Bye. you You")
and modes/emoji never applied.

1. **The silent keep-alive was corrupting the mic.** 0.1.11 restored the silent
   player for background residency, but ran it through the *same* AVAudioEngine
   as the input tap. That makes the engine full-duplex, which quietly guts the
   capture: it recorded ~9 s and Whisper heard "Bye." Fix: split into two
   engines. `inputEngine` is now pure input (no player, no output connection) so
   the mic stays clean; a separate `silenceEngine` + `AVAudioPlayerNode` carries
   the silent keep-alive for residency, started best-effort during warm-up. The
   warm-up log now reports keep-alive state ("mic live, keep-alive on" vs
   "keep-alive OFF (residency at risk)") so the Activity log shows whether
   residency is protected.
2. **The Groq cleanup model was decommissioned.** `llama-3.3-70b-versatile`
   started returning "does not exist", so every cleanup call failed and degraded
   to raw — no mode, no emoji, silently. Fix: `GroqCleanup` now carries a spread
   of models across families, tries the last-known-good first (cached in the App
   Group as `cleanupModel`), and on a 4xx that names the model falls through to
   the next instead of failing. `CleanupResult.note` records why a pass degraded
   so "my mode/emoji did nothing" is answerable from the log.

**Reasoned and brace-checked; not yet watched on device.** To confirm: dictate a
full sentence and check it transcribes whole (not a fragment); toggle a mode or
emoji and check it applies; run several dictations in a row and check the app
survives.

### 0.1.5 — mic-start fix and the interface pass (2026-09-14)

The keyboard-triggered capture that failed on build 1.0 (2) with kAUStartIO
2003329396 was two AVAudioEngine instances each running a RemoteIO on one
session; the second start is refused with kAudioUnitErr_CannotDoInCurrentContext
('what'). `openMic` now stops the silence engine before starting the recorder
and `closeMic` restarts it, so only one engine runs at a time. This keeps the
property that the mic (and the orange dot) is open only during a capture. **This
is reasoned from the error code, not yet watched on device.** To confirm: run
`idevicesyslog -n` while tapping the mic from Notes and check that the
kAUStartIO refusal is gone.

### 0.1.12 — keyboard palette, cleanup diagnostics, bug report (2026-09-14)

Two dictations in a row now work on device, so residency holds. This pass:
- Keyboard light/dark palette retuned to sit beside Apple's keyboard (near-black
  board with mid-grey keys in dark; cool-grey board, white keys, ink glyphs in
  light). The theming reads keyboardAppearance and the trait collection.
- Modes and emoji: strengthened the mode prompts so Super casual, Casual and
  Formal read visibly different, and Emoji always ends with exactly one emoji
  (the old "if nothing fits, use none" escape hatch is gone). The cleanup pass
  applies these; it was failing silently to raw. Raised its timeout from 8s to
  15s and added an Activity-log line ("cleanup: applied" / "cleanup: NOT applied
  (...)") so a missing mode/emoji is diagnosable.
- Bug reporting: Details has a "Report a problem" button that shares the version,
  device and activity log via the share sheet.

### 0.1.11 — restore the silent player so the app survives past one dictation (2026-09-14)

0.1.9 removed the silent keep-alive player, betting a running input engine alone
would keep the backgrounded app resident. On device it did not: after the first
dictation iOS suspended the app, the engine stopped, the next capture came back
empty ("message too short" on a long message), and then the app died (keyboard
fell back to the wake button). Restored a silent AVAudioPlayerNode that plays
continuously alongside the always-on input, in the one engine. Input keeps the
mic startable; silent playback is what iOS counts as active background audio and
keeps the app alive between dictations. Also: a too-short capture now reports a
result to the keyboard instead of leaving it stuck at "Transcribing" for 25s.

### 0.1.10 — wake button launches the app again (2026-09-14)

The cold-start wake button ("Open Dictator once") did nothing when tapped,
because `extensionContext.open` returns false and won't launch an app from a
keyboard on current iOS. Re-added the responder-chain walk to
`UIApplication.openURL(_:)` in the keyboard's `coldStart`, which does launch the
container app. **This is private-API-adjacent and an App Store review risk.**
Jeremy chose to keep it for TestFlight (2026-09-14); remove or reconsider it
before any App Store submission. With 0.1.9's always-on mic the app usually stays
resident, so this path is only hit after the app is killed.

### 0.1.9 — the real mic-start fix: foreground-start, always-on input (2026-09-14)

Device logs from build 11 settled the kAUStartIO 2003329396 question for good.
warm-up succeeded (session active, silence playing), then every keyboard-tapped
capture failed with `engine(... kAUStartIO ...)`, even after the earlier fix that
stopped the silence engine first. Conclusion: **iOS refuses to START microphone
input from the background, full stop.** It is not about how many engines run; a
new input IO simply cannot start when the app is backgrounded.

So the two-engine "mic closed between dictations" design cannot work, and the
earlier "the mic opens on tap" copy was wrong. `AudioEngineHost` is now one
engine, started in the foreground during warm-up with the input tap installed,
and never stopped. A capture starts no IO; it flips a flag so the already-running
tap keeps its samples. `openMic`/`closeMic`/the silence keep-alive are gone.

The honest cost, restored in the app and onboarding copy: the microphone and the
orange dot are on the whole time Dictator is on, not only while dictating. Willow
and Wispr carry the same cost. This is the design the original BUILD.md described
("the app starts AVAudioEngine while foregrounded and never stops it").

### 0.1.8 — fix the Xcode Cloud package-resolution failure (2026-09-14)

Every Xcode Cloud build since the morning of 2026-09-14 failed at dependency
resolution, before any Swift compiled: "a resolved file is required when
automatic dependency resolution is disabled … Package.resolved … dependencies
were added: 'fluidaudio'". The `.xcodeproj` and its workspace are generated by
XcodeGen at build time and never committed, so no `Package.resolved` exists, and
Xcode Cloud disables Xcode's automatic resolution and then requires that file.

`xcodebuild -resolvePackageDependencies` does NOT help here: under the disabled
flag it refuses to resolve and demands the missing file (builds 9 and 10 both
died on exactly that). The fix in `ci_scripts/ci_post_clone.sh` is to resolve
with SwiftPM's own resolver instead, which is not gated by that flag and this
repo's `Package.swift` pulls the same FluidAudio dependency: `swift package
resolve`, then copy the resulting `Package.resolved` into
`Dictator.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/`, where Xcode
Cloud's own resolve step then finds a valid file. As a hedge the script also
re-enables automatic resolution via a defaults key.

If this ever regresses, the guaranteed fallback is to generate `Package.resolved`
in Xcode on the Mac once, commit it to a non-ignored path, and have the script
copy it into the workspace.

Note: because these builds never reached compilation, the 0.1.6 Swift changes
have not yet been compiled by any toolchain. The first green resolution step may
surface ordinary Swift errors to fix next.

### 0.1.6 — warm-up recovers from CannotInterruptOthers (2026-09-14)

Device logs showed a second, separate failure: warm-up's own `setActive`
returning 560557684 (AVAudioSessionErrorCodeCannotInterruptOthers) when another
app held a non-mixable audio session, after a long synchronous block on the
background thread. It is environment-dependent and clears once the other app
stops its audio, so it is recoverable, but the app dead-ended: a `.failed` state
hid the only start button. Fixes: warm-up now shows an honest, actionable
message ("Another app is using audio. Stop its sound, then tap Try again.") for
that code, keeps the raw OSStatus in the Activity log, and the home screen shows
a "Try again" button in `.failed` that resets and re-warms (`retryWarmUp`). The
audio calls were already off the main thread, so this was never a true hang. We
did not add `.mixWithOthers`, which would trade this for background suspension.

The rest of the 0.1.5 pass, from `Projects/dictation/docs/Design.md` §3–4:
honest mic-state copy in the app and the keyboard; keep the audio and offer a
retry on a Groq failure; keyboard dark mode, landscape, sentence-case modes with
a long-press picker, key pop-ups, no millisecond readout; a Vocabulary screen on
both platforms wired to `PersonalDictionary` and `learn`; a five-step iOS
onboarding with a validated Groq key step; the Mac tabbed settings and first-run
Setup guide; "Turn on / Turn off" instead of "session" everywhere. The App Store
and landing copy (Design.md §5) is still gated on the validation posts and is not
in this change.

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
