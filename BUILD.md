# Dictator

Local dictation for Mac and iPhone. Hold `fn` on the Mac, tap the mic on the
phone, speak, get clean text where the cursor is. Replaces Wispr Flow at $15/mo.

Status: builds on both platforms, 1.0 (1) on TestFlight. See "Honest status"
at the bottom.

---

## Mac auto-release (signed + notarized DMG)

The Mac app can't use TestFlight (non-sandboxed, global hotkey + Accessibility),
so `.github/workflows/mac-release.yml` builds it on a macOS runner, signs it with
Developer ID, notarizes it, and publishes a `.dmg` to GitHub Releases.

**To cut a release:** push a tag, e.g. `git tag mac-v0.1.26 && git push origin
mac-v0.1.26` (or run the "Mac Release" workflow manually from the Actions tab).
The DMG appears under the repo's Releases; download it, drag Dictator to
/Applications. Because the signature is stable, the Accessibility grant survives
updates.

**One-time setup — add these five repo secrets** (Settings → Secrets and
variables → Actions → New repository secret):

1. `DEVELOPER_ID_CERT_P12_BASE64` and `DEVELOPER_ID_CERT_PASSWORD`
   - In Xcode: Settings → Accounts → (your Apple ID) → Manage Certificates → the
     "+" → **Developer ID Application**. (One-time; skip if you already have one.)
   - Open **Keychain Access**, find "Developer ID Application: … (W9K8HB89TY)",
     right-click → Export → save a `.p12`, set an export password.
   - Terminal: `base64 -i Certificates.p12 | pbcopy` → paste as
     `DEVELOPER_ID_CERT_P12_BASE64`. The export password goes in
     `DEVELOPER_ID_CERT_PASSWORD`.

2. `AC_API_KEY_ID`, `AC_API_ISSUER_ID`, `AC_API_KEY_P8_BASE64` (for notarization)
   - App Store Connect → **Users and Access → Integrations → App Store Connect
     API** → generate a key (Access: **Developer**). Download the
     `AuthKey_XXXXXX.p8` (you can only download it once).
   - The **Key ID** is on that row → `AC_API_KEY_ID`. The **Issuer ID** is at the
     top of the page → `AC_API_ISSUER_ID`.
   - Terminal: `base64 -i AuthKey_XXXXXX.p8 | pbcopy` → paste as
     `AC_API_KEY_P8_BASE64`.

Once the five secrets are in, tag `mac-v*` and the DMG builds itself. (I can't
test the workflow from a Linux environment, so the first run may need a tweak —
paste any failing step's log and it's usually a one-line fix.)

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
Tests/DictationCoreTests/         unit tests for the pure-logic core
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

`Tests/DictationCoreTests/` covers the pure-logic half of the pipeline: the WAV
container, silence trimming, the personal dictionary, tone selection, and every
cleanup fallback. No microphone, no network, no App Group. Run it with
`swift test`.

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

### 0.1.68 — cleanup: clean stutters/false starts, but don't gut content (2026-09-17)

Correction to 0.1.67, which over-swung: removing false starts and stutters is a
WANTED feature, not a bug (0.1.67 told the model to keep essentially everything).
The actual 0.1.67 problem was only that a small cloud model occasionally cut real
content. So this restores the good behavior with a balanced prompt: remove filler,
stutters, and false starts (keep the final intended version), but do not summarize,
paraphrase, or cut whole ideas/sentences/tangents the speaker meant to say. The
0.1.67 word-count safety net (fall back to raw if cleaned < half the words of a
≥12-word transcript) stays as a catastrophic-loss backstop only.

### 0.1.67 — never let cleanup drop the user's words (2026-09-17)

Device report: a rambling dictation came back "a lot nicer as a paragraph, but it
cut out what I said" — the cleanup LLM deleted repeated/rambling content ("blah blah
blah, day day day"). Inconsistent (sometimes kept it), i.e. the model editorializing.

For a dictation app, silently dropping content is a serious bug. Two fixes:

1. Prompt (ToneProfile base CLEANUP): removed the over-broad "remove false starts
   and self-corrections / keep only the final version" rule that invited the model
   to cut repetition. Now it removes only true disfluencies (um/uh) and a plain
   self-correction, with an explicit FIDELITY-IS-PARAMOUNT rule: never drop,
   shorten, summarize, or paraphrase; keep every substantive word, including
   repetition and tangents; when unsure, keep it.
2. Safety net (Cleaner.process): if the cleaned text is under half the word count of
   a non-trivial transcript (≥12 words), treat it as content-dropping and fall back
   to the raw transcript (dictionary-applied), alongside the existing empty/refusal
   guards. Removing filler trims a little; losing half the words means content was
   cut.

### 0.1.66 — on-device transcription (opt-in): the free-tier engine (2026-09-17)

First step of the business plan's free tier: wire the on-device Parakeet model
(via FluidAudio) into the iOS app so transcription can run locally — free, private,
offline — instead of only on Groq's cloud.

- **Cloud stays the DEFAULT.** On-device is opt-in via a new Transcription picker in
  the app (On-device / Cloud). This is deliberate: the on-device path is new and
  can't be verified without a real device, so we don't ship it as the default until
  it's proven. Flip it on to test; once it's good on device, a later build makes it
  the default.
- `project.yml`: DictatorIOS now links FluidAudio and includes LocalParakeet.swift
  (still excluded from the keyboard extension — 48 MB ceiling). Transcription runs
  in the container app, as it already did.
- iOS uses the **compact** Parakeet tier (~250 MB), not the 900 MB one, to fit a
  phone's memory budget. The model downloads once (into app storage) on first use;
  later loads are fast and fully offline.
- `BackgroundRecorder`: new `modelStatus` (idle/downloading/ready/failed) surfaced
  in the UI; the model is prepared on warm-up/wake when on-device is selected, and
  unloaded on idle-release / turn-off to free memory. Transcription picks the engine
  per request and **falls back to cloud** if on-device isn't ready yet and a key
  exists, so nothing breaks mid-download. Cleanup (punctuation/mode/paragraphs) runs
  on Groq when a key is present and degrades to the dictionary-only pass without one
  (on-device LLM cleanup is a later addition).
- Added `TranscriptionEngine` enum + `SharedStore.transcriptionEngine` setting.

Unverified without a device: FluidAudio's iOS build compatibility at deployment
target 17.0, and on-device accuracy/memory/latency on real phones. Cloud default
means the app still works regardless.

### 0.1.65 — spoken numbers make a numbered list, not bullets (2026-09-17)

User dictated "number one… number two… number three" and it came out as bullet
points. The STRUCTURE prompt lumped "first, second, third" and "one, two, three"
under the BULLETED-list rule. Fixed: when the speaker says the numbers out loud
("number one", "one, two, three", "first, second, third") the cleanup now produces
a NUMBERED list ("1. 2. 3.") matching the spoken numbers; bullets are reserved for
unordered groups with no spoken numbers.

### 0.1.64 — break long dictations into real paragraphs (2026-09-17)

User: dictating long paragraphs and wants them broken into multiple, nicely
formatted paragraphs instead of one wall of text.

The base cleanup prompt already mentioned "paragraph breaks" in passing, but it
was weak and buried, so long dictations came back as a single block. Added an
explicit PARAGRAPHS rule to the base prompt: a long, multi-topic dictation is
broken into paragraphs (blank line between) at topic/time/subject shifts and turn
signals ("another thing", "also", "so anyway"), ~2–4 sentences each — while
explicitly NOT over-splitting a short dictation, a run of sentences on one point,
or a brief chat message. Reinforced the messaging profile to keep chat messages
as one paragraph unless genuinely long and multi-topic, so texts don't get odd
blank lines.

### 0.1.63 — shorter swipe bar so its middle lands in the gesture zone (2026-09-17)

User: "Make the bar maybe half the height. You have to be really on the bottom of
the screen for the swipe to work, and the user is going to swipe in the MIDDLE of
the bar — we don't want the bar anywhere the swipe won't fire."

Right call: the system swipe-to-previous-app gesture only fires very near the
bottom edge, so a tall bar invites a swipe in its too-high middle where nothing
happens. Roughly halved the bar (~118pt → ~65pt): smaller label
(.subheadline), smaller fingertip/track (34 → 20), tighter padding (top 18 → 8,
bottom 34 → 14). The whole bar — and the fingertip line the eye follows — now sits
low, so a swipe through its middle lands in the zone where the gesture works.

### 0.1.62 — wake screen: fingertip that travels the swipe path; guaranteed no scroll (2026-09-17)

User: "Can we animate that bar and have it swipe along with you? Make it really
obvious." And: "If the page scrolls at all, the swipe back is next to impossible —
make sure the page doesn't scroll."

Both are the same underlying point — make the return gesture unmistakable and
unobstructed:

- New `SwipeHintBar`: the bottom bar now shows a white fingertip puck that glides
  the full width of the bar left→right, continuously, with a soft two-ghost motion
  trail and a faint dashed track it runs along. It fades in/out at each end so the
  loop never snaps. Driven by `TimelineView(.animation)` (frame-smooth, self-
  looping, stops when the screen goes away) and `GeometryReader` (travels the real
  bar width on any device). Replaces the little nudging arrow.
- Scroll conflict: a scroll view on the bottom edge fights the home-swipe gesture
  and makes iOS demand two swipes — that's the "impossible swipe" the user hit.
  The wake screen is a plain `ZStack` with NO scroll view, opaque, on top with
  `zIndex(1)`, so it fully covers the scrolling settings page and leaves the bottom
  edge clear. Documented the no-scroll requirement in the view so it isn't
  reintroduced.

### 0.1.61 — never touch the user's music: record over it, don't duck it (2026-09-17)

User's call, and the right one: "What Wispr Flow does is it just doesn't touch
the music — it records over the music playing. Maybe we just do that: leave the
music up, and people can turn their music down if they need to."

So Dictator now leaves other apps' audio completely alone:

- Removed ducking entirely (`AudioEngineHost.setDucking` and both calls). The iOS
  session stays `.playAndRecord` + `.mixWithOthers` the whole time, capturing
  included, so we never lower, pause, or re-route the user's music. The phone mic
  hears speech fine over background music; if it's too loud, turning the music
  down is the user's call, not ours.
- This deletes the whole "music stayed quiet after dictation / restarted paused
  music / hijacked the car route / crushed even when idle" family of bugs, since
  we no longer manipulate the session's ducking at all.
- Reverted 0.1.60's short mic-hold: its only justification was getting music back
  sooner, which no longer applies. Idle-release default is back to 30 minutes,
  picker back to 5 min / 30 min / 2 hours / Never, and the help text drops the
  music framing (the window is now purely battery vs. trips-back). A corrective
  one-time migration puts installs 0.1.60 forced to 1 minute back to 30, leaving a
  deliberately-chosen window untouched.

macOS (fn-hold via AudioRecorder/DictationSession) still ducks; that's a separate
context and out of scope for this iPhone-driven change.

### 0.1.60 — music: release the mic fast so other audio returns to full volume (2026-09-17)

Device report (0.1.58): "still crushes music volume even when not recording."

Root cause — and the honest one, after three prior music fixes chased different
bugs (route hijack 0.1.55, duck-during-capture 0.1.56, stuck-duck 0.1.57): iOS
holds other apps' audio at reduced volume the ENTIRE time an app keeps an active
recording session, regardless of `.mixWithOthers`. There is no flag to record and
leave other audio at full volume. Dictator keeps the mic hot for instant
background dictation, so while the mic is hot the user's music sits quieter — even
when idle. This is not the duck (that lifts correctly now); it's the baseline
record-session attenuation.

Fix: stop holding the mic hot so long. The idle-release window used to default to
30 minutes, so a single dictation left music quieter for up to half an hour. Now:

- Default idle window is 1 minute (was 30). Back-to-back dictations stay instant
  (the timer resets on each capture); once you stop, the mic releases within a
  minute and iOS restores other audio to full volume.
- Mic-hold picker is now 1 min / 5 min / 30 min / Never (dropped 2 hours), and its
  help text states the music trade-off plainly: a longer hold means fewer trips
  back to the app but quieter music for longer.
- One-time migration (`musicHoldMigratedV1`) resets an existing install's window to
  1 minute once, so the fix reaches users who were on the old 30-minute default;
  any later manual choice sticks.

Trade-off made explicit to the user: releasing the mic sooner means a lull longer
than the window costs a trip back to Dictator (the wake screen) to re-arm. A
future "stay resident so re-waking is instant" pass can shrink that cost further.

### 0.1.59 — Wispr-style wake screen: "swipe back to your app" (2026-09-17)

When the keyboard wakes Dictator to make it resident (dictator://dictate), the
old app dropped the user straight into the settings UI with a small green banner.
That's the wrong thing to look at: the user's goal is to get back to the app they
were typing in, not to read settings.

Now, exactly like Wispr Flow, waking the app shows a full-screen, mostly blank
WakeScreen: the Dictator logo mark (mic glyph on the brand-purple gradient), one
line — "Dictator is ready" / "Swipe back to the app you were in, then tap the mic
to dictate." — and a bright purple bar hugging the bottom home edge reading
"Swipe → back to your app", with the arrow nudging left-to-right to mime the
home-swipe gesture that iOS uses to jump to the previous app. A quiet "Stay in
Dictator" button dismisses it so the user is never trapped.

- New `WakeScreen` view in ContentView.swift, overlaid in a ZStack above the
  NavigationStack, gated on `recorder.wokeForDictation`, fading in/out.
- Removed the old `wakeReadyBanner` (the small in-scroll green pill it replaces).
- iOS cannot return you to the previous app programmatically (removed in iOS
  26.4; even Wispr lost it), so teaching the one sanctioned gesture — the
  bottom-edge swipe — is the honest, App-Store-safe answer.

### 0.1.58 — fix the flickering "Open Dictator" pill (mic-dead != app-alive) (2026-09-17)

Device report: the "Open Dictator once to restart the mic" pill flickered and
tapping it never opened the app; going back to the app then tapping cycled
"Starting" → "Open Dictator" → "Tap to talk" forever; only manually opening
Dictator worked. Log showed a tight loop: "start: mic not live; rebuilding
instead of capturing" + "resync deferred: backgrounded, keeping the app alive".

Root cause: the heartbeat stamped liveState = "warm" whenever the app was
resident, even when the MIC engine was dead (killed by a background interruption
and un-rebuildable until foreground). The keyboard reads liveState as "app ready
to record", so it showed "Tap to talk", the tap tried to record into a dead mic,
the app answered "open me", and the keyboard — treating that non-retryable error
as .ready — let the next tap record again. Infinite loop; the pill never reached
the .needsSession state whose tap actually OPENS the app.

Fix (app-side, one place): when warm-but-mic-dead, stamp liveState "cold" instead
of "warm". The keyboard then shows the wake pill, and a tap runs coldStart and
opens Dictator (foreground → mic rebuild → ready). No keyboard change needed.

Note: this loop was a two-session collision (both sessions editing the audio
state machine). Consolidating ownership is overdue.

### 0.1.57 — lift the duck properly (music was staying quiet) (2026-09-17)

Device report on 0.1.56: music ducks correctly when dictation starts, but never
comes back up — it stays quiet until Dictator is force-quit (which deactivates
the session). Also "music is down whenever the mic's been on recently" = a duck
from an earlier dictation that never lifted.

Cause: engaging .duckOthers via setCategory takes effect immediately, but
switching back to .mixWithOthers does NOT lift the duck without re-activating the
session. setDucking now calls setActive(true) after changing the options, which
applies them and lifts the duck. Re-activating with .mixWithOthers does not
resume hand-paused audio (only setActive(false) sends resume; mixWithOthers never
interrupts).

### 0.1.56 — duck the music while dictating; stop hijacking the car route (2026-09-17)

Device report (dictating over car Bluetooth): music jumped from the car to the
phone speaker, kept playing full-volume during dictation (mic couldn't hear the
user), and manually-paused music RESTARTED when dictation began.

- Removed .defaultToSpeaker from the idle category — that was forcing output to
  the phone speaker and yanking car/Bluetooth audio onto the phone. Audio now
  stays on whatever route the user is on.
- New setDucking(_:): on capture start switch the live session to .duckOthers
  (music drops to ~1/5 volume out of the mic's way), on capture end restore
  .mixWithOthers. Done via setCategory only (no setActive), so it does NOT resume
  audio the user paused by hand — which was the "restarts my music" bug.

Known limit: iOS ducks to ~20%, not 5% or a full pause. If car music still
bleeds into the transcript at that level, escalate to a true pause (needs the
interruption path, trickier, deferred until we see if ducking is enough).

### 0.1.55 — don't fight the user's music (mix, drop Bluetooth HFP) (2026-09-16)

The always-on .playAndRecord session was hostile to other audio:
- Without .mixWithOthers, activating (or rebuilding) the session INTERRUPTS other
  audio — it paused the user's music/podcast and never resumed it. Added
  .mixWithOthers so our session coexists; their audio plays the whole time
  Dictator is warm, and the silent keep-alive just mixes in silently.
- Dropped .allowBluetoothHFP. It forced AirPods to call-quality mono (HFP) the
  entire time Dictator was on — so music through AirPods went tinny — and its
  route switches were a source of the interruption-driven tap crash (0.1.54).
  Dictation now uses the phone mic; AirPods stay in full-quality A2DP for music.
  TRADE-OFF surfaced to the user: no Bluetooth-mic dictation (phone mic instead);
  revisit as a setting if wanted.

### 0.1.54 — THE crash fix: install the mic tap with nil format (2026-09-16)

Device CRASH log (build 55) finally pinned it:
  "com.apple.coreaudio.avfaudio: Failed to create tap due to format mismatch,
   <AVAudioFormat 1 ch, 48000 Hz, Float32>"
right after "audio interruption ended; rebuilding". installTap was given the
format read a moment earlier; after an interruption/route change the input
node's LIVE format differs, so installTap threw a hard ObjC exception. The app
crashed, relaunched, warmed, hit the same mismatch, crashed again — a crash LOOP
that also pegged the CPU and starved the keyboard extension (this is the typing
lag too: same root). The crash logger added in 0.1.42 is what captured it.

Fix: install the tap with format nil (uses the bus's own current format, so it
can never mismatch) and build the AVAudioConverter lazily in handle() from the
actual buffer format, rebuilding it if the format changes. Robust across
interruptions and route changes. Expect the crash loop — and much of the typing
lag it caused — to go away.

### 0.1.53 — fix the red archive: two statements welded onto one line (2026-09-16)

Build 54 failed, `xcodebuild archive` exit 65, six seconds in. A compile error,
not a signing or dependency problem.

0.1.50 stripped `UIDevice.current.playInputClick()` out of the keypress hot path
by deleting the lines, and the deletion joined the surrounding code instead of
closing the gap. In five places it welded a closing brace onto the previous
statement, which is ugly but legal. In one place it welded two statements
together:

    textDocumentProxy.deleteBackward()        deleteRepeat?.invalidate()

which is `error: consecutive statements on a line must be separated by ';'` and
is why nothing archived. Split, and the five brace lines restored to normal
formatting so the next reader is not looking at the same damage.

Nothing else in the file changed. The 0.1.50 decision to keep the keypress path
minimal stands.

**Two loose ends from 0.1.50, flagged not changed, because they are product
calls rather than bugs.** `showPreview(for:)`, `hidePreview()` and the
`keyPreview` label are now unreachable: nothing calls them. And with
`playInputClick()` gone from every key, the keyboard is silent — no click, no
pop-up preview, so a keypress now has no feedback at all except the key
changing colour under a thumb that is covering it. That is a real cost for the
latency it buys, and if the lag is actually the audio session (the stated
reason), the preview could come back on its own.

### 0.1.52 — Expressive: short enthusiastic one-liners get their "!" (2026-09-16)

0.1.49 dialled ! back to "rare / one per paragraph" — but that under-marked
short excited messages ("I love it", "that's a good one" came back on a flat
period). Split the rule: a SHORT message that is itself an enthusiastic/positive
reaction gets a "!"; a LONGER message stays sparing (about one per paragraph, on
the strongest beat). So one-liners feel alive without paragraphs getting sprayed.

### 0.1.51 — fix wake pill "flickers, does nothing" + duplicate "ready" (2026-09-16)

Two device reports:
- The wake pill flickered and did nothing when tapped, but worked after leaving
  and re-entering the app. Cause: the 0.1.46 "accidental brush" guard ignored a
  pill tap within 1.2 s of a keystroke — and the user types, THEN taps to wake, so
  the real wake tap got swallowed. Leaving/returning reset the typing timer, which
  is why it then worked. Removed the guard: coldStart only ever runs from a
  deliberate pill tap and nothing auto-opens the app, so the guard protected
  against a rare brush at the cost of the pill not working. Act on every tap.
- Two "Dictator is ready" sections showed at once (the post-wake banner and the
  status card). Renamed the banner headline to "Head back to your app" so it
  states its actual job instead of duplicating the status card.

### 0.1.50 — typing still laggy/drops keys: strip the keypress hot path (2026-09-16)

Touch-down insertion (0.1.41) fixed WHICH event inserts, but typing is still
laggy and drops letters on device — the symptom of the MAIN THREAD stalling
(iOS coalesces/drops touches while the main thread is busy). Two things ran on
every keypress and were removed from keyDown/keyUp:
- playInputClick(): the click sound routes through the audio system, which in
  THIS app is busy holding the always-on mic session — a per-keystroke stall a
  normal keyboard never has. Removed from every typing action.
- showPreview()/hidePreview(): a full convert + frame + bringSubviewToFront
  layout pass per press. No longer called (the pressed-colour is the feedback).
keyDown is now just insertText + press colour. If typing is STILL laggy after
this, the cause is systemic (keyboard-extension memory pressure, or the
container app churning/crashing loading the device) rather than the hot path.

### 0.1.49 — Expressive: about half as many exclamation points (2026-09-16)

User: a dictated paragraph came back with three exclamation points and one
period; wanted one or two. 0.1.39 over-corrected ("lean IN, be generous").
Dialled it back: exclamation points are now RARE — about one per paragraph, two
at most, reserved for the single strongest beat; most sentences end in a period.
Questions still get a question mark; ellipsis unchanged. (Rebased on top of the
parallel session's 0.1.47 audit + 0.1.48 residency work.)

### 0.1.48 — the real reason you wake it every other minute (2026-09-16)

Report: "I have to do it like every other minute, it's often." The 0.1.45 idle
timer cannot explain that — it is five minutes and every dictation pushes it
back. So the app was losing residency some other way. It was losing it three
ways, and two of them were self-inflicted.

**Nothing watched the thing that keeps the app alive.** The silent player is the
only reason iOS does not suspend a backgrounded Dictator. The 2 s heartbeat
checks `audio.isRunning`, which is the MICROPHONE engine. The mic can be
perfectly healthy while the player has stopped, and a few seconds after it stops
the process is suspended, the heartbeat stops stamping the App Group, and the
keyboard reports the app gone. The heartbeat now checks the keep-alive too and
restarts it, which is legal from the background because only starting mic INPUT
is refused. Rate limited to one attempt per 10 s, logged on transitions.

**`isSilenceRunning` could not see a stopped player.** It returned
`silenceRunning && silenceEngine.isRunning`, with no test of `silence.isPlaying`
— and a route change stops the PLAYER while leaving the engine up. The internal
repair path always checked both; the public read a health check would use did
not, so the new heartbeat check would have been lied to. Fixed first.

**Route changes were not observed at all.** Headphones in or out, a Bluetooth
device connecting or dropping, the system moving between speaker and receiver.
On a phone in a pocket these fire many times an hour and each one silently cost
the keep-alive. Now observed, and ONLY the keep-alive is restarted:
it is idempotent and background-safe, and the mic rebuild stays where it was, so
there is nothing for this notification to loop with. (AVAudioEngineConfiguration-
Change is still deliberately not observed, for the reason given in 0.1.22.)

**The worst one: the app destroyed its own residency on a dead mic.**
`beginCapture` falls back to `resync()` when the engine is not live. That call
had no foreground guard, and the keyboard triggers it FROM THE BACKGROUND.
`resync` then ran `teardownForRewarm()`, which calls `stopEverything()` and
stops the silent player, and then `warmUp()` — which iOS refuses in the
background. Net effect of one dead mic engine: keep-alive stopped, warm-up
refused, process suspended seconds later, and the next tap says "Open the
Dictator app to wake it". A mic problem was being upgraded into an app-is-gone
problem, every time. `resync` now refuses to tear down while backgrounded; it
protects the keep-alive and defers the rebuild to the next foreground, which
already calls it.

**Honest failure instead of a two-second guess.** When the mic is dead and we
are backgrounded, the tap is not going to record however long anyone waits, so
the app now says "Open Dictator once to restart the mic" immediately rather than
leaving the pill on "Starting" until it times out and blames the whole app. The
keyboard also cancels an in-flight capture wait when a result arrives; that
timer used to fire anyway a couple of seconds later and overwrite the result it
had just shown.

**The idle window is now a setting, defaulting to 30 minutes.** This is the one
honest trade in the product and it deserved to be visible rather than a
constant. iOS will not reopen the microphone from the background, so once
Dictator lets go, the next dictation costs a trip to the app and a manual swipe
back. Five minutes put that trip in the middle of ordinary use. Choices are 5
minutes, 30 minutes, 2 hours, and Never, with copy that says what each one
costs.

**On returning to the app you came from, since it keeps coming up.** There is no
API, public or private, to trigger the back swipe, and none to return to "the
last app" without naming it. Apple's DTS confirmed both on forum thread 826851:
no public way to identify the host, no public "return to source app". What
shipping keyboards do instead is swizzle `+enabled` on `_UIKeyboardArbiterClient`
to read `sourceBundleIdentifier` and `_hostProcessIdentifier`, keep a
pid-to-bundle table because the arbiter reads stale about a quarter of the time,
and then open the host by a curated URL-scheme catalogue
(getdictus/dictus-ios PR #538, whose own description says "This ships private
API, including one swizzle"). The supported path is the system back breadcrumb,
which is one tap and needs no host knowledge. Apple's suggested enhancement,
`UIApplication.returnToOpeningApplication(completion:)`, is FB24235692 and does
not exist yet. So the fix is not to make the round trip nicer; it is to stop
needing it, which is what everything above is for.

### 0.1.47 — audit pass: the polish bugs, not the crash bugs (2026-09-16)

The last ten releases each chased one reported failure. This one is a read of
the whole codebase looking for what was still wrong, including the quiet things
nobody files a bug about. Sixteen fixes, no behaviour removed.

**Text that came out wrong**

- **A stray newline after every cleaned dictation.** `Cleaner` trimmed the
  model's reply, tested the trimmed copy for a refusal, then inserted the
  UNTRIMMED original. Models end a reply with a newline as a matter of course,
  so in a chat box the caret dropped to a new line, and in some apps that sends
  the message. One word changed; it is the highest-impact fix here.
- **Undo left a space behind.** `insert` added a leading space as a SEPARATE
  `insertText` call and then told undo about the transcript only, so undo always
  deleted one character too few. `insert` now returns exactly what it inserted,
  in one call, and undo deletes that.
- **Holding backspace deleted one character too many.** The delete key fired on
  touch-down (the repeat) AND on touchUpInside, so lifting off after a hold cost
  an extra character. Delete is touch-down only now, like every other key.
- **Shift ignored the caret.** Nothing re-read the document context, so shift
  was whatever the last keystroke left it as: a capital offered mid-word, and no
  capital after a full stop. `textDidChange` now tracks it, requiring the
  terminal punctuation to be followed by a space so "hello.com" is left alone.

**Messages you could not read**

- **Transient errors never cleared.** `render()` only runs on a mode CHANGE, so
  "Nothing heard" set while the mode was already `.ready` stayed on the pill
  indefinitely under a blue Tap-to-talk. Worse, "Still working. Open Dictator to
  check." was set BEFORE a mode assignment and was wiped by that mode's render
  before anyone saw it. Both go through `flash()` now, which shows a message,
  announces it to VoiceOver, and restores the real state after a few seconds.
- The status label holds two lines instead of shrinking the honest failure copy
  to 70% on one.

**Things that were unreachable**

- **First-run Settings never opened on the Mac.** `AppDelegate.openSettings()`
  used `NSApp.sendAction(Selector(("showSettingsWindow:")))`, which does nothing
  in an LSUIElement app on macOS 14+ — the menu's own copy had already been
  fixed and left a comment saying so. Settings now opens through
  `@Environment(\.openSettings)` on the menu bar label, which is the one view
  that is always on screen.
- **A denied microphone killed the Mac hotkey permanently.** `bootstrap()`
  returned early, so no hotkey, no model, and no way to reach the screen that
  explains the fix. It now continues, watches for the grant, and corrects its
  own status line when you come back from System Settings.
- **Re-entering setup showed an empty Groq key field** with Next hidden, as
  though no key had ever been saved. It shows the saved one.
- Onboarding walked you to "Try it" after you tapped Don't Allow on the
  microphone. It stops and offers Settings.

**Races and leaks**

- **The listening indicator could hide itself right after showing.** `hide()`'s
  fade completion ordered the panel out unconditionally; dictating again inside
  that 0.18 s left you recording with no indicator. (`hideWorkItem` was meant to
  guard this and was never assigned anywhere.) A generation counter does it.
- **Two event taps, one keypress.** `startHotkey()` replaced `hotkey` without
  stopping the old monitor, and both `bootstrap()` and the Accessibility watcher
  can reach it.
- **The engine's `running` flag was read across threads with no lock** — written
  on the engine queue, read from the main actor by the very health check that
  exists to notice the engine dying. Now guarded by the lock the rest of that
  state already used.
- **`validateKey` leaked a URLSession per call**, the same leak fixed everywhere
  else in 0.1.43, on a path onboarding hits repeatedly.
- **An iCloud write per dictation.** `transcribe` called `mergeFromCloud()`,
  which re-encoded the dictionary and pushed it to the key-value store every
  time, on the latency path, for no change. It saves only on a real change, and
  the dictation path uses the cheap `load()`.
- **A Task per audio buffer on the Mac.** The tap hopped every 20 ms of audio
  onto the actor to append to an array. Samples land in a lock-guarded box now.
  (The iOS recorder fixed the same shape in 0.1.39.)

**Build and release**

- **The keyboard's version did not match the app's.** It was pinned to 1.0 (1)
  while the app shipped 0.1.46 with a build number from Xcode Cloud. App Store
  validation rejects that outright; it now uses the same build settings.
- **`swift build` and `swift test` failed on a fresh clone**: Package.swift has
  always declared a `DictationCoreTests` target and the directory did not exist.
  It exists now, with real tests for the WAV writer, silence trimming, the
  dictionary, tone selection, and every cleanup fallback — including one that
  fails if the trailing-newline bug above ever comes back.
- **A fresh clone did not compile at all**: `Secrets.swift` is gitignored and
  nothing created it, so `BuildSecrets` was undefined with no hint as to why.
  `setup.sh` seeds it.
- Deleted `Transcriber.swift`, a tombstone whose own comment said to delete it,
  and the unused Accessibility text-insert path whose doc comment described
  behaviour the app stopped having.

**Not changed, deliberately.** `SharedStore` still rebuilds its `UserDefaults`
on every access. Caching it is the obvious optimisation and it is the one place
where a stale App Group read breaks the entire keyboard-to-app handshake, which
cannot be verified from here. The container lookup is cheaper than that risk.

### 0.1.46 — never launch the app from an accidental pill brush while typing (2026-09-16)

User reported the keyboard "interrupted me to restart the app while I'm typing."
In current code coldStart() only fires from a deliberate micTapped, and the
garbled report text ("whattyPng", "torestart") shows the reporter is on a
pre-0.1.41 build (before touch-down typing and before the auto-coldStart removal
in waitForCapture) — i.e. all recent fixes are simply not on the device yet.

Added a belt-and-suspenders guard anyway: micTapped records lastKeyTime on every
keystroke and ignores the app-launch cases (.needsSession / .needsFullAccess /
.needsKey) if a character was typed in the last 1.2 s. So even an accidental
brush of the pill mid-typing can't take over the screen. Recording start/stop is
unaffected.

DELIVERY: the reporter keeps hitting already-fixed bugs, so the priority is
confirming TestFlight is actually delivering new builds (0.1.4x) to the device.

### 0.1.45 — idle auto-off: stop holding the mic (orange dot) open all day (2026-09-16)

User: "the mic just keeps being on randomly when it really doesn't need to be,
users won't appreciate it." True — the always-on mic is the cost of triggering
dictation from the background without opening the app each time (iOS forbids
STARTING the mic from the background, so it must already be open). Wispr avoids
the always-on mic only by opening the app for every dictation (the bouncing the
user dislikes). It is genuinely one or the other.

Middle ground shipped: idle auto-off. A 5-minute inactivity timer (bumpIdleTimer,
reset on every warm-up and every capture) releases the mic (stopEverything ->
orange dot off, state .cold) once there has been no dictation for the window AND
the app is backgrounded. If the app is on screen it stays warm. During an active
texting session the timer keeps getting pushed out, so it never releases
mid-session; only a real lull trips it. Re-waking after a release is one tap.
Window is a single constant (idleWindow) so it is easy to tune.

### 0.1.44 — stop dictating into a dead mic (the activity-log smoking gun) (2026-09-16)

The device activity log showed the real "stops mid-dictation" failure: an audio
interruption stopped the mic engine, the user kept talking for ~30 s, then got
"captured 0.0s → Didn't catch that". The engine cannot resume mid-capture, and
nothing was watching for it dying DURING a capture.

Two fixes in BackgroundRecorder:
- Heartbeat now checks the engine while .capturing, not only while .warm. If the
  mic dies mid-capture it ends the capture within one 2 s tick (the keyboard
  follows to a result and unsticks) and rebuilds, instead of recording 30 s of
  silence.
- beginCapture refuses to start on a dead engine (audio.isRunning == false):
  it rebuilds instead, so a re-tap a moment later records for real rather than
  yielding 0.0 s. This also covers "tap to wake → dictate immediately → nothing"
  (engine still rebuilding).

Note: the frequent engine deaths themselves are audio interruptions + the app
being suspended; the crash fix (0.1.42) and session-leak fix (0.1.43) remove the
biggest churn sources. These two changes make what remains recover fast instead
of eating a whole dictation.

### 0.1.43 — fix "getting slower and slower": one persistent Groq session (2026-09-16)

Device report: transcription "taking longer and longer," 5 s for half a
sentence, "something's getting worse." Root cause: GroqTranscription and
GroqCleanup each built a fresh URLSession on EVERY dictation and never
invalidated it. Un-invalidated sessions retain themselves plus their connection
pool and worker threads, so they accumulated over a session and dragged the
whole pipeline down — a leak that compounds exactly as "getting worse."

Fix: one shared, persistent URLSession (GroqHTTP.shared) for the app's lifetime,
used by both providers. Two wins: (1) no more per-dictation session leak; (2) the
TLS connection to api.groq.com stays warm between the transcribe and cleanup
calls (same host) and across dictations, saving a handshake each time — a real
latency cut on a weak connection. Per-request timeouts unchanged (transcription
scales with duration; cleanup pinned to 15 s per request).

Note on "tap to wake every minute" and "doesn't switch back": both are the app
not staying resident, and the biggest cause was the crash fixed in 0.1.42 (a
crashed app is a dead app -> tap to wake). Auto-return to the previous app is not
possible on iOS 26.4 (even Wispr lost it), so the fix is residency: when the app
stays alive the keyboard records in the background and you never leave your app.

### 0.1.42 — fix the app crash: serialize AVAudioEngine on one queue (2026-09-16)

Device report: the CONTAINER APP crashes ("Dictator: Voice to Text Crashed"),
intermittently, "gets so buggy." Root cause: AVAudioEngine is NOT thread-safe,
and we were mutating it from two threads. startWarm() runs on a BACKGROUND task
(via withWarmUpTimeout), while ensureSilenceAlive() (added 0.1.35) runs on the
MAIN thread from the audio-interruption / media-reset observers. When an
interruption fired during a warm-up (or resync churned), both touched the input
and silence engines at once → hard crash. This matches "crashes after a few
uses".

Fix: a single serial DispatchQueue (engineQ) now owns EVERY engine mutation.
Public startWarm/stopEverything/ensureSilenceAlive hop onto it (sync for the
first two, async for the keep-alive so it never blocks); `_`-prefixed impls do
the work and call each other directly without re-entering the queue (no
deadlock). Engine operations can no longer overlap.

Also added a crash logger: NSSetUncaughtExceptionHandler writes the exception
name + reason + top stack frames to the shared activity log before the app dies,
so any future crash is readable in Details → Report a problem instead of guessed
at. Catches the AVAudioEngine "required condition is false" family (NSExceptions).

### 0.1.41 — fix dropped/garbled fast typing + stop surprise app-opens (2026-09-16)

Device report: fast typing dropped letters and spaces and merged words
("chat tomorrow" -> "chattomorrow", "the countdown" -> "thcoUntdown"), and the
keyboard sometimes jumped to the Dictator app mid-typing.

- Dropped characters: letter keys and the space bar inserted on .touchUpInside.
  During fast "rolling" typing you press the next key before lifting the last, so
  the previous key never fires a clean touchUpInside and its character is dropped
  (and the stray capital came from the shift-once reset racing). Fix: insert on
  .touchDown, exactly like the system keyboard. keyDown now does the insert;
  space is rewired from touchUpInside to touchDown too. Special keys that rely on
  double-tap timing (shift caps-lock, return) stay on touchUpInside.
- Surprise app-open: waitForCapture's deadline branch used to AUTO-call
  coldStart() when a recording did not start (app not resident — common in Low
  Power Mode, note the red battery in the report), which yanked the user into the
  Dictator app mid-typing. Now it just shows the wake prompt; opening the app is
  only ever a deliberate pill tap.

### 0.1.40 — clean up the wake flow (warm, don't record; "ready, go back" banner) (2026-09-16)

Device report: waking the app works, but it doesn't return you to the app you
were dictating into. iOS has NO public API for an app to switch back to the
previous app (the private `suspend` trick is an App Store risk and lands on the
Home Screen anyway), so auto-return is not a real option. The right model is:
open Dictator ONCE, it becomes resident, and the keyboard reaches it in place
after that — no repeated bouncing.

Two fixes so that model actually feels right:
- onOpenURL (dictator://dictate) now only WARMS; it no longer starts recording
  inside Dictator (warmAndCapture removed). Recording in the foreground app was
  confusing since the user wanted to dictate in their other app.
- New one-time "Dictator is ready" banner (wokeForDictation flag) tells the user
  to tap the system "‹ back" button top-left and that this is a one-time step
  because the app now stays ready in the background. Cleared when the app next
  backgrounds (they've left, as intended).

### 0.1.39 — remove debug row, better Expressive punctuation, timing logs (2026-09-16)

Three things from a device session:
- Debug open-method row REMOVED. Method A (modern responder → UIApplication.open)
  is confirmed working on device and the pill already uses it, so the temporary
  A/B/C row is gone (it was confusing when it "popped up" on the wake screen).
  OpenMethod/attemptOpen stay; coldStart still tries best-first.
- Expressive mode + question marks. Base prompt now ALWAYS ends a question with
  "?" (including statement-form and tag questions), fixing missed question marks
  in every mode. Expressive mode rewritten to lean in: generous (not robotic)
  exclamation points for excitement/greetings/thanks/calls-to-action, "?" on all
  questions, ellipsis for trailing-off, optional combined "?!". Still keeps a
  period on flat factual lines and never adds/changes words.
- Speed: added per-stage timing to the Activity log ("timing: transcribe Xms ·
  cleanup Yms · total Zms") to pinpoint whether a slow dictation is the
  upload+transcription round trip (connection-bound) or the cleanup LLM, before
  optimizing the real bottleneck. (Weak signal / "5G E" makes the audio upload
  the prime suspect.)

### 0.1.38 — redo button (2026-09-15)

Undo already deleted the last inserted dictation. Added a redo button beside it
(arrow.uturn.forward) that puts the undone text back. Single-level history:
tapping undo stashes the removed text in lastUndone and swaps the undo button for
redo; redo re-inserts it and swaps back. A fresh dictation clears the redo state
(redoButton hidden, lastUndone nil). Undo and redo are mutually exclusive, so
only one shows at a time.

MILESTONE: 0.1.36 confirmed on device — the keyboard can now open the Dictator
app (modern UIApplication.open via responder chain). The core "stuck / couldn't
open" problem is solved.

### 0.1.37 — stop typing "thank you" on silence (Whisper hallucination) (2026-09-15)

Device report: tap talk, say nothing, tap stop → it types "thank you". This is
the classic Whisper silence-hallucination (it was trained on caption tracks, so
on silent/near-silent audio it emits "Thank you", "Thanks for watching", "Bye").
Groq runs Whisper, so it inherits it. Different bug from 0.1.24 (that was the
unzeroed keep-alive buffer bleeding noise); this is genuine quiet input.

Two-layer fix in BackgroundRecorder:
- SILENCE GATE before the network: energy(samples) computes rms, peak and the
  voiced-frame ratio (30 ms frames); isLikelySilence requires ALL three to be
  quiet (rms<0.012, peak<0.08, voiced<0.05) so real/quiet speech still passes.
  A silent clip is discarded as "Didn't catch that" and never sent to Groq.
- BACKSTOP after transcription: if the clip was low energy AND the result is a
  known hallucination phrase (isHallucinationPhrase), drop it. Gated on low
  energy so a genuine dictation of "thank you" into a text still goes through.

### 0.1.36 — open Dictator FROM the keyboard: modern method + debug row (2026-09-15)

The keyboard's launch code used the LEGACY perform("openURL:") responder-chain
selector, which iOS 18 deliberately broke (UIKit logs "migrate to the
non-deprecated UIApplication.open(_:options:completionHandler:)"). That is why
"Couldn't open Dictator" kept showing even with Full Access on.

Fix: attemptOpen(_:) now walks the responder chain to the real UIApplication and
calls the MODERN open(_:options:completionHandler:). coldStart() tries every
method best-first (modern → legacy → extensionContext). Per Apple's own review
guidance, a keyboard IS allowed to launch its OWN container app (only opening
arbitrary URLs is disallowed), so this is a sanctioned path, not a private hack.

Also added a temporary DEBUG ROW (three small buttons: "A: open()", "B:
openURL:", "C: extCtx") shown whenever the app is unreachable. Each tries one
method and reports whether Dictator actually came alive, so we can confirm on a
real device which technique works and then drop the losers. Remove the row once
the winner is confirmed.

### 0.1.35 — harden background residency (the "Couldn't open Dictator" root) (2026-09-15)

Device report: after granting Full Access, the keyboard ended on "Couldn't open
Dictator. Open it from your Home Screen." That is HONEST and correct — a keyboard
extension genuinely cannot launch its container app on iOS. The real problem is
the app not staying resident in the background; when it is not resident there is
nothing for the keyboard to wake.

Residency is kept by playing silent audio (audio background mode). Hardened it:
- startWarm now retries the silent keep-alive once if the first start loses a
  race (it was best-effort/one-shot before).
- New ensureSilenceAlive() restarts ONLY the keep-alive, and it is called from
  the interruption-ended and media-services-reset handlers even when
  BACKGROUNDED — because starting playback from the background is allowed (only
  starting mic INPUT is refused). So an interruption no longer silently ends
  residency until the next foreground.

Still to confirm with a device log (Details → Report a problem) whether the app
is being SUSPENDED (residency, this fix) or CRASHING (needs the log to pin down).

### 0.1.34 — stop the "Turn on Full Access" pill from flapping (2026-09-15)

Device report: the pill sat on "Turn on Full Access for Dictator", and tapping
it flashed "Waking Dictator" → "Tap to talk" → straight back to "Turn on Full
Access", so it did nothing. Cause: refreshMode() hard-gated on iOS's
`hasFullAccess` flag, which is UNRELIABLE — it flaps to false right after a
reinstall or a keyboard switch. The brief "Tap to talk" proved the keyboard had
actually reached the app through the App Group (which it went to .ready on), then
the 1 s modeWatch tick re-read hasFullAccess == false and slammed it back to
needsFullAccess.

The keyboard does NOT need Full Access: it talks to the app only via the App
Group and Darwin notifications, both of which work without it (Full Access only
gates network, and the keyboard does zero networking — the container app does
all transcription). So refreshMode() now trusts the empirical signal: if the app
is alive and reachable, go .ready and stay there; only fall back to
needsFullAccess/needsSession when the app genuinely is not answering.

### 0.1.33 — waking from the keyboard actually records (2026-09-15)

The keyboard's cold-start URL (dictator://dictate) launched the app and
immediately called beginCapture(), which no-ops unless the engine is already
.warm. On a cold launch it never is (warmUp is async), so waking from the
keyboard opened the app but recorded nothing. onOpenURL now calls a new
warmAndCapture(): resync/warm, wait up to ~2s for the engine to reach .warm,
then begin. So a wake genuinely starts a recording.

(Crash still open. The app has Details → "Report a problem", which dumps the
activity log that survives a crash — that's what will pin the crash down.)

### 0.1.32 — hold backspace to clear a lot, fast (2026-09-15)

Hold-to-repeat backspace existed since the first commit but ran a flat
~12 chars/sec that never accelerated, so clearing a paragraph crawled and felt
broken. Now it mirrors the system keyboard: single characters for the first
~1.5 s, then it switches to whole-word deletion (deleteWordBackward walks
documentContextBeforeInput, eats trailing whitespace then the word). Grace
before repeat shortened to 0.35 s. Secure fields that hide the context fall back
to single-character deletes.

(Crash + "stuck on tap to wake" still open — the app being jettisoned in the
background is the root; needs a device crash log / event-log to fix without
guessing. See chat.)

### 0.1.31 — the REAL fix for the "light board, dark keys" theme mix (2026-09-15)

The grey-board/dark-keys mix survived two earlier attempts (a cached bool in
0.1.16, dynamic colours in 0.1.19) because dynamic colours only help if every
view resolves its light/dark trait the same way — and in a keyboard extension
the root input view and the key buttons can resolve them DIFFERENTLY, so the
board came up light while the keys stayed dark. The fix is to stop leaving it to
per-view trait resolution: `applyTheme()` now pins
`view.overrideUserInterfaceStyle` to a single resolved appearance
(`resolveDark()` — from the host's requested `keyboardAppearance`, falling back
to the system trait), so every descendant inherits the same style and board,
keys, bar and glyphs can never end up on different themes. This only shows once
a build after 0.1.30 (build 33, first green after the Xcode 27 CI fix) reaches
TestFlight — the device was still running a stale pre-fix build before that.

### 0.1.30 — Swift 5 language mode to unbreak CI on Xcode 27 (2026-09-15)

Builds 29–32 all failed the iOS archive (exit 65) after Xcode Cloud updated to
Xcode 27 beta. Under Xcode 27's Swift 6 language mode, data-race / Sendable
issues that were warnings became hard errors (the OneShot @Sendable capture was
one; there were more). Rather than chase each one under a beta toolchain, set
SWIFT_VERSION to 5.0 (Swift 5 language mode) with SWIFT_STRICT_CONCURRENCY still
minimal — the concurrency code (actors, @Sendable, MainActor.assumeIsolated) all
compiles, the data-race issues drop back to warnings, and the archive builds. A
deliberate Swift 6 migration can happen later, not forced by a CI toolchain bump.

### 0.1.29 — Mac listening indicator (Wispr-style overlay) (2026-09-15)

A floating "I'm listening" overlay on the Mac (macOS/ListeningIndicator.swift):
a frosted HUD pill at bottom-centre with an animated waveform that reacts to the
live mic level while you hold the key, a gentle travelling shimmer while it
transcribes, and a fade-out when done. It is a non-activating panel that ignores
the mouse and floats over all spaces/fullscreen, so it never steals focus from
the app you are dictating into (the transcript still lands at the cursor). Wired
through the existing DictationSession level callback (which already existed but
was unused on Mac).

### 0.1.28 — fix red CI: OneShot must be Sendable on Xcode 27 (2026-09-15)

Xcode Cloud went red (archive exit 65). Cause: Xcode Cloud updated to Xcode 27
beta, and under Swift 6 mode there the "capture of non-Sendable OneShot in a
@Sendable closure" (the AVAudioConverter input block) is a hard error, not the
warning it was on the older toolchain — so the iOS archive stopped compiling.
Marked both OneShot classes (AudioRecorder.swift and BackgroundRecorder.swift)
`@unchecked Sendable`; it is accurate (each is created and consumed within one
synchronous convert() call on a single thread, never shared).

### 0.1.27 — keyboard typing latency (2026-09-15)

The custom keyboard felt laggy to type on. Two main-thread costs removed:
- Every letter key had a CALayer drop shadow with no shadowPath, so Core
  Animation rendered each of ~30 keys offscreen on every press and relayout. A
  KeyButton subclass now sets a shadowPath in layoutSubviews, turning the shadow
  into a cheap pre-rasterized rectangle.
- `mode`'s didSet re-rendered the pill on every assignment, and the 1 s modeWatch
  reassigns mode each tick — so the pill re-rendered once a second while typing.
  Now it renders only on an actual mode change, and the timer's redundant explicit
  render() is gone.

### 0.1.26 — Mac reliability: no more wedge after a few dictations (2026-09-15)

The "works for a few dictations then stuck on Listening, no result" bug on Mac,
two causes both fixed:
- DictationSession left state at .failed after any transcription error, and
  start() only ran from .idle — so ONE hiccup wedged the session permanently
  (every later dictation silently no-oped while the UI said "Listening"). Now a
  transcription error returns to .idle, and start() self-heals from any non-
  listening state (stops the recorder, resets, starts fresh).
- AudioRecorder reused one AVAudioEngine across every start/stop cycle, which
  wedges after a device/sample-rate change and stops delivering buffers. It now
  builds a fresh AVAudioEngine each session.

### 0.1.25 — spoken punctuation, with reference disambiguation (2026-09-15)

The cleanup prompt now handles spoken punctuation as commands — "period",
"comma", "question mark", "exclamation point/mark", "colon", "semicolon", "dash",
"open/close quote", "new line" — writing the mark instead of the words. Crucially
it distinguishes a command from a reference: "that's amazing exclamation point"
becomes "that's amazing!", while "I keep using exclamation points" or "put a
question mark after it" keep the words. Shared core, so iOS and Mac both get it.

Note surfaced this session: on Mac with no Groq key, cleanup is skipped ("0 ms
cleanup") so NO mode formatting is applied — Expressive/Emoji/spoken-punctuation
all need the cleanup pass. Transcription is local; the key powers the mode pass.

### Mac fixes — Settings window + Electron text insertion (2026-09-15)

Mac-only (no marketing-version bump; the Mac app is a local build, not TestFlight).
First real on-device Mac run surfaced two bugs; dictation itself worked (local
Parakeet, ~180 ms).

- *Settings window would not open* from the menu bar. `NSApp.sendAction(
  showSettingsWindow:)` silently no-ops for a menu-bar-only (LSUIElement) app on
  macOS 14+. Switched the menu's "Settings…"/"Vocabulary…" to the SwiftUI
  `@Environment(\.openSettings)` action.
- *Text did not insert in Electron apps* (Claude's desktop app; Slack/VS Code
  would be the same) while it worked in native apps like Messages. The
  Accessibility write reports success in Electron but inserts nothing, so we never
  fell back. Now paste + Cmd-V is the universal path (clipboard saved/restored),
  the paste is posted at the HID level (Electron ignores a session-level synthetic
  Cmd-V), and the clipboard restore waits 350 ms so a slow app finishes pasting
  first.

### 0.1.24 — fix speaker pops + "thank you" (unzeroed silence buffer) + loop-proof self-heal (2026-09-15)

Serious regression: constant pops and cracks from the speaker whenever the app is
"ready", and a long dictation coming back as "thank you".

Root cause: the silent keep-alive buffer was never zeroed. A freshly allocated
`AVAudioPCMBuffer` holds uninitialised memory, so looping it played GARBAGE
through the speaker (the pops/cracks), and that noise bled into the microphone, so
Whisper heard junk and returned its silence hallucination, "thank you". Now every
channel of the buffer is `memset` to zero, so the keep-alive is genuinely silent.

Also hardened the 0.1.22 self-heal so it can never become a rebuild loop (which
would churn the audio session — more pops, wrecked capture):
- Removed the `AVAudioEngineConfigurationChange` observer entirely: rebuilding the
  engine itself posts that notification, so reacting to it is a feedback loop.
- Added a rate limit — the engine rebuilds at most once every 8 s — so a flapping
  `isRunning` (from the heartbeat check or any event) cannot churn it.
- Kept the safe triggers: foreground `resync`, interruption-ended, media reset.

### 0.1.23 — Expressive mode (2026-09-15)

A fifth mode: Expressive. Casual base, but it punctuates for feeling — an
exclamation point where the speaker is genuinely excited or emphatic, an ellipsis
for a real trailing-off or pause — matched to the speaker's actual energy, without
changing any words or over-using either mark. Order is super casual · Casual ·
Formal · Expressive · Emoji. The emoji-mode blurb was also updated to reflect its
new "placed where it fits" behavior.

### 0.1.22 — self-healing engine (fix the "zombie, only force-quit revives it" bug) (2026-09-15)

The worst reliability bug, reproduced on a full battery so it was not Low Power
Mode: use it a few times, leave the app or just wait, and it says "wake" — and
returning to the app does nothing, only a force-quit revives it. Root cause: iOS
suspends or kills the audio engine while backgrounded (or an interruption stops
it), but `state` stayed `.warm`, so `warmUp()` no-oped (`guard state == .cold`)
and nothing ever rebuilt the engine. Returning to the app changed nothing because
nothing checked whether the engine was actually alive.

Fix — the engine now heals itself, three ways:
1. *On foreground.* The app calls `resync()` every time it becomes active: if it
   is nominally warm but the engine is not running, it tears down fully (timers,
   Darwin observers, audio host — clearing the `running` flag that made
   `startWarm` early-return) and warms again from scratch.
2. *On the events that kill it.* One-time observers for audio-session
   interruptions ending, engine configuration changes, and media-services resets
   rebuild immediately (while foregrounded).
3. *Heartbeat health check.* Every 2 s, if we think we are warm but the engine is
   not running and we are foregrounded, rebuild — catches a silent death that
   fires no notification ("just wait a while and it stops").

All rebuilds are guarded so they never race a warm-up already in flight.

### 0.1.21 — honest wake copy (a keyboard cannot launch its app) (2026-09-15)

Faced a hard platform limit honestly instead of tweaking around it. A keyboard
extension cannot reliably launch its container app on modern iOS: the sanctioned
`extensionContext.open` returns false for keyboards, and the responder-chain
`openURL` workaround is unreliable and increasingly blocked. Keyboards also can't
fire haptics or custom sounds. So "Tap to wake Dictator" promised three things
the keyboard physically can't do, which is why the button "did nothing".

The needs-session copy is now "Open the Dictator app to wake it" — an instruction,
not a false promise. The tap still attempts a launch (it works on some setups)
and still self-corrects to the same instruction on failure, but the words now set
the right expectation. The real answer is residency: opening the app once keeps it
alive in the background (silent keep-alive) so the wake state is rarely seen;
Low Power Mode / a near-empty battery makes iOS jettison the app far more
aggressively, which is when the wake state shows up.

### 0.1.20 — mode labels preview their output; smarter emoji placement (2026-09-15)

- Mode labels now preview the formatting: "Casual" and "Formal" are capitalised
  (properly-cased output), while "super casual" is written lowercase because that
  is exactly what it produces. Applies everywhere displayName shows (keyboard
  button, iOS segmented control, Mac menu).
- Emoji mode no longer always tacks one emoji on the end. It now places the
  single emoji at the most expressive spot inline (right after the word it plays
  off), falling back to the end only when the message builds to one final beat.

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
