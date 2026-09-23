# Staying awake

**Why Dictator needs waking, everything we know about keeping it ready, and what to try next.**

_Written 2026-09-23 from the code, the build history (BUILD.md), the device logs Jeremy
sent, Apple's documentation and forums, and the help centres and source code of the
other iPhone dictation keyboards. Sections marked ▸ are the ones to update when a
device test settles a question._

---

## 0. The short version

1. **No app has a different trick.** Every third-party dictation keyboard on iPhone
   (Wispr Flow, Willow, Monologue, Superwhisper, Aqua Voice, Typeless, DictaFlow,
   VoiceInk, Spokenly, Voicenotes, and the open-source Muesli and Dictus) does what
   Dictator does: the keyboard cannot touch the microphone, so the container app opens
   the mic once in the foreground, keeps an audio session running in the background, the
   keyboard signals it, and text comes back through the App Group. When iOS kills the
   app, every one of them makes the user open the app and swipe back. Their help pages
   say so in almost the same words (section 5).
2. **Wispr Flow feels awake longer because of policy, not a primitive.** Its idle
   countdown only runs while the Flow keyboard is *not on screen*; showing the keyboard
   cancels it. Dictator's countdown runs from the last *dictation*, so someone who types
   with the Dictator keyboard all afternoon and dictated once at lunch gets released at
   the 30-minute mark. Wispr also offers "Never", and re-arming is a keyboard tap plus a
   swipe.
3. **The wall is documented and recent.** Apple's engineers said on the developer
   forums in January and February 2026 that a privacy block stops any app outside the
   call frameworks from *activating* a recording session in the background, whatever
   its audio category or background modes, and that this has been so since iOS 12. A
   recording started in the foreground may continue indefinitely, with the orange
   dot. So the mic is armed in the foreground or not at all, and every interruption
   (a call, Siri, another app's mic) ends the warm state until the app is opened.
4. **Most of Jeremy's wakes are still ours to prevent.** From the logs: the 30-minute
   idle release counted from the last dictation, not the last use of the keyboard;
   interruptions whose end iOS never announces, which leave the app believing a call
   is in progress; and a keep-alive that keeps a mic-less process resident for no
   benefit, at App Review risk.
5. **The plan** (section 8): pause the idle countdown while the keyboard is visible;
   probe for the end of interruptions; let the app go to sleep when its mic is dead
   and make the wake one tap and truthful; test whether the silent keep-alive is
   needed at all while the mic is live; a Live Activity as the session's face; and a
   memory budget, because Apple's guidance for an audio app to survive in the
   background is under 100 MB.

---

## 1. Vocabulary

These words are used precisely in the code, the logs and this document.

| Word | Meaning |
|---|---|
| **Resident** | The container app's process exists and is running (not suspended, not jettisoned). Only a resident app can hear the keyboard's Darwin notifications. |
| **Suspended** | iOS froze the process. It uses memory but runs no code. A Darwin notification posted to a suspended app is lost. |
| **Jettisoned / killed** | iOS ended the process (memory pressure, Low Power Mode, a crash). The next launch is a cold launch. |
| **Warm** | Dictator's state when the mic engine is running with the input tap installed. The keyboard can start a capture in place. The orange dot is on. |
| **Cold** | The mic engine is not running. A capture cannot start until the app is foregrounded. |
| **Keep-alive** | A looped buffer of silence played through a second `AVAudioEngine`. Audio output is what stops iOS from suspending a backgrounded app; the mic engine alone was not trusted for that (0.1.48). Restarting it is allowed from the background. |
| **Heartbeat** | A 2-second timer in the app that stamps `liveState` and a timestamp into the App Group. The keyboard treats a stale stamp as "the app is gone". |
| **liveState** | What the app tells the keyboard: warm, capturing, transcribing, or cold. Since 0.1.58 it says cold when the app is resident but the mic is dead, so the keyboard shows the wake pill instead of recording into nothing. |
| **Interruption** | `AVAudioSession.interruptionNotification`. Another audio session took the hardware non-mixably: a phone or FaceTime call, Siri, system dictation, Voice Memos, the Camera recording video, some games. Our mic engine stops. |
| **Idle release** | Dictator's own timer: after N minutes with no dictation while backgrounded, stop the mic and the keep-alive (orange dot off, state cold). Default 30 minutes; 5 / 30 / 120 / Never in Settings. |
| **Wake** | What the user does when the keyboard says "Open Dictator": open the app (the keyboard tries to launch it; the user can also tap the icon), the app warms the mic in the foreground, the user swipes back. |
| **Bounce** | Being pulled into the Dictator app and having to come back. Since 0.1.41 it only happens on a deliberate tap. |
| **Session** (Wispr, Willow, Monologue) | Their word for our warm state: a window of time in which the app holds the microphone. |

---

## 2. How it works today

The chain, in order:

1. **Warm-up (foreground only).** `warmUp()` requests mic permission if needed, sets
   the audio session to `.playAndRecord` with `.mixWithOthers`, `.defaultToSpeaker`,
   `.allowBluetoothA2DP`, starts the input engine with the tap installed (format `nil`,
   0.1.54), starts the silent keep-alive on a second engine, starts the 2-second
   heartbeat, and arms the idle timer. Log: `warmUp begin` → `mic: already granted` →
   `warm: starting mic engine (foreground)` → `warm: mic live, keep-alive on` →
   `listening for keyboard`.
2. **A dictation.** The keyboard posts `.startRecording` (Darwin). The app flips a flag
   so the already-running tap keeps its samples (no IO is started; that is the whole
   point of staying warm). `.stopRecording` ends it; the audio goes to the backend
   (or the on-device model), cleanup runs, the result lands in the App Group, the
   keyboard inserts it. Every capture resets the idle timer.
3. **While backgrounded.** The heartbeat keeps stamping. It also watches the keep-alive
   (`checkKeepAlive`) and restarts it if it stopped, which is legal from the background.
   It does **not** rebuild a dead mic from the background.
4. **An interruption begins.** `audioInterrupted = true`; every warm/rebuild path
   no-ops (0.1.94, so a call does not loop the wake screen). The mic engine is stopped
   by the system. The keep-alive is usually stopped too. Log: `audio interrupted (a call
   or another app has the mic)` then, a couple of ticks later, `keep-alive STOPPED; app
   can be suspended`.
5. **An interruption ends.** If iOS delivers `.ended`: the flag clears, the keep-alive
   is restarted (background-legal), and the mic is rebuilt **only if the app is in the
   foreground**. Log: `audio interruption ended; rebuilding`. If the app is
   backgrounded the mic stays dead and the heartbeat stamps `cold`; the keyboard shows
   the wake pill.
6. **Idle release.** `releaseIfIdle()` fires at the end of the window if the state is
   warm and the app is backgrounded: stops everything, unloads the on-device model,
   stamps cold. Log: `mic released after 30m idle`.
7. **Wake.** The keyboard's pill runs `coldStart()`: it walks the responder chain to
   `UIApplication` and calls `open(dictator://dictate)` (the modern call; iOS 18 broke
   the old `openURL:` selector, 0.1.36, verified on device), polls the App Group for
   three seconds, and shows "Couldn't open Dictator. Open it from your Home Screen" if
   nothing stamps. In the app, `warmForWake()` probes the session, warms, and shows the
   "swipe back to your app" screen. Returning to the host app has no public API on iOS
   26.4 and later; the swipe or the system back arrow is the way home.

The one thing the mic engine cannot do is **start** from the background. That was
established on device in 0.1.9 (`kAUStartIO 2003329396` on every keyboard-tapped start
after a warm-up whose session was active and playing silence) and it is what the whole
always-on design rests on. ▸ Section 7 asks whether that finding covers the
interruption-ended case; it was never tested there.

---

## 3. Why it gets woken so often

Every wake has a cause in the log. The causes seen in Jeremy's reports, ranked by how
often they appear and how much each one costs:

### 3.1 The idle release (policy)

`20:39:59  mic released after 30m idle`. Thirty minutes from the last *dictation*.
Typing with the Dictator keyboard for an hour does not count as activity. Wispr's
countdown, by contrast, "applies only to an open, idle session while Flow is
backgrounded and the Flow Keyboard is inactive. Opening Flow, activating its keyboard,
or starting dictation cancels the countdown." This is the single biggest difference
in felt behaviour and it is entirely ours to change.

### 3.2 Interruptions the app cannot recover from (platform)

`19:47:24 audio interrupted` → `19:53:08 audio interruption ended; rebuilding` (the
keep-alive only) → `20:09:58 resync: engine died while away; rebuilding` (at the next
foreground, sixteen minutes later). The mic was dead from 19:47 until Jeremy opened the
app. The code says the mic "can only restart in the foreground". That was an inference
from 0.1.9, which tested a fresh start of input from a backgrounded session; section
4.1 now backs it with Apple's own statements and a dated report of exactly this case
(a call ends, the app is backgrounded, reactivation fails until the app is opened).
The cost of a call is therefore a wake, for every app. What is ours is how cheap and
how honest that wake is, and whether the app sits stuck afterwards (3.3).

### 3.3 Interruptions that never end (platform behaviour)

`20:33:02 audio interrupted` → `20:36:31 audio interrupted` → no `ended` line at all,
then the idle release at 20:39. The code already knows this: `warmForWake` notes that
"the .ended notification is unreliable (with AirPods and other route changes it often
never arrives)". While `audioInterrupted` is set the heartbeat refuses to restart even
the keep-alive, so the process is suspended a few seconds later, and nothing runs
until the user opens the app. Two things are wrong at once: we wait for an event that
may never come, and we let residency lapse while waiting.

### 3.4 Suspension during the interruption itself (platform + design)

`keep-alive STOPPED; app can be suspended`. A call takes the hardware, both our
engines stop, iOS notices no audio is running and suspends the process within seconds.
A suspended process does not receive `.ended` when the call finishes; it receives it
the next time it runs, which is when the user opens the app. Only the keep-alive can
bridge this, and it cannot run during the call either.

### 3.5 Crashes and thrash (fixed, historically the main cause)

The AVAudioEngine thread-safety crash (0.1.42), the tap-format crash loop (0.1.54),
the resync that destroyed its own residency (0.1.48), the URLSession leak (0.1.43).
A crashed app is a dead app; these were the "every other minute" reports. They are
fixed, and the uncaught-exception handler writes to the shared log, so a crash now
shows up in Report a problem.

### 3.6 Low Power Mode, memory pressure, Not-enough-RAM devices (platform)

iOS jettisons backgrounded apps far more aggressively in Low Power Mode and under
memory pressure. Wispr's help documents the same thing: "When the Wispr Flow app has
closed in the background (common in Low Power Mode), the keyboard resets itself."
Dictator's on-device model is 900 MB on 6 GB phones; in on-device mode a resident
Dictator is the largest background process on the phone and the first to go. In cloud
mode (the "1-trip" lines in the log) the model is never loaded.

---

## 4. What iOS allows

▸ _Filled from the platform research; see section 9 for sources._

Legend: **documented** = Apple documentation; **DTS** = an Apple engineer on the
Developer Forums; **device** = verified on Jeremy's phone by a build; **reported** =
developers on the forums, dated; **folklore** = circulates, unconfirmed.

### 4.1 The rule that decides everything

| Claim | Status | Source |
|---|---|---|
| A recording session started in the foreground may continue in the background indefinitely, with the orange pill showing. | **DTS**, Apr 2025 | Quinn, forums thread 776949 |
| A recording session **cannot be activated from the background** by a non-communication app, whatever the category, options or background modes. Only CallKit, LiveCommunicationKit and PushToTalk can, and "they can't be used for any other purpose". | **DTS**, Feb 2026 | Kevin Elliott, thread 816408; history ("we disabled all background recording activation in late-iOS 12") in thread 812592, Jan 2026 |
| The refusal shows in the log as `CMSUtility_IsAllowedToStartRecording … is in the background and doesn't have the entitlement to start recording in the background`; the error is `'!rec'` 561145187 `cannotStartRecording`. | **documented / reported** 2019–2023 | AVAudioSession.ErrorCode; threads 120038, 674632, 725361 |
| Dictator saw the same refusal as `kAUStartIO 2003329396` on every background start in 0.1.9. | **device** | BUILD.md 0.1.9 |
| After a phone call, with the app in the background, `.ended` arrives but `setActive(true)` fails with `'!int'` 560557684; retries and a rebuilt recorder do not help; "reactivation only works after opening the app". | **reported**, Jan 2026, unanswered, consistent with the DTS rule | thread 813278 |
| Folklore says `.mixWithOthers` lets a session resume after a call in the background. DTS says `.mixWithOthers` *prevents* background activation in the Push-to-Talk path. | **folklore vs DTS** | sanenotes issue 86 vs thread 812592 |
| Incoming-call **ringing** alone interrupts a recording; Apple offered no configuration and asked for an enhancement request (FB18434531). | **DTS**, mid-2025 | thread 784782 |
| On iPhone 16e (iOS 18.4–18.7) the input tap silently stops after a call until the engine is torn down and rebuilt. | **reported**, Oct 2025 | thread 805735 |

So: the mic is armed in the foreground or not at all. Every interruption that stops
the input ends the warm state until the app is foregrounded. This is the wall every
app in section 5 stands behind, and the reason their help pages read alike.

### 4.2 Staying resident

| Claim | Status | Source |
|---|---|---|
| The `audio` background mode keeps the app awake **while its audio session is active and rendering**; that is "not quite the same as guaranteeing it will not be suspended". Audio apps still die when an interruption is not resumed, when the app "stopped playing audio for too long", on system maintenance, on reboot. | **DTS**, Sep 2024 | thread 764096 |
| Background memory guidance for an audio app to be safe from memory termination: **under 100 MB**. | **DTS**, Sep 2024 | thread 764096 |
| Playing silence to stay resident works technically and is a **documented App Review rejection pattern** under 2.5.4 ("background audio is intended for … audible content"). A 2025 rejection for using audio mode to keep a *recording* alive drew the DTS reply naming 2.5.4 and 2.5.14 as the risks. | **documented / DTS** | Guidelines 2.5.4, 2.5.14; threads 776949, 105443, 95216; audio_service issue 975 |
| Reverse-engineered jetsam priority puts "Audio and Accessory" processes above ordinary background apps. | **folklore** (reverse-engineered) | jetsamctl; newosxbook MemoryPressure |
| A Darwin notification is not delivered to a suspended app; if the app is terminated while suspended it is lost. | **DTS**, Dec 2024 | Quinn, thread 769398 |
| `beginBackgroundTask` gives about 30 seconds. | **DTS** | Quinn, thread 85066 |
| Background push: 2–3 per hour, 30 seconds each, discarded if the app was force-quit. | **documented** | "Pushing background updates to your app" |
| Picture in Picture keeps the process alive as long as real video plays; DTS calls using it as a keep-alive "a very serious mistake". | **DTS**, Jul 2025 | threads 793010, 791744 |
| Location updates keep the process alive with a blue indicator that cannot be hidden. | **documented** | CLBackgroundActivitySession |
| PushKit requires CallKit since iOS 13; failing to report a call terminates the app. | **documented** | "Responding to VoIP notifications from PushKit" |

### 4.3 App Intents, Live Activities, Controls, the Action button

| Claim | Status | Source |
|---|---|---|
| An intent from a widget, Live Activity or Control runs in the extension's process **unless** it is a `LiveActivityIntent`, `AudioPlaybackIntent`, `ForegroundContinuableIntent` or `PushToTalkTransmissionIntent`, or sets `openAppWhenRun`; those run **in the app's process**. iOS 27 adds `ExecutionTargets`. | **documented** | "Adding interactivity to widgets and Live Activities"; WWDC26 345 |
| A `LiveActivityIntent` "launches your app process without opening the app, performs the intent, and starts the Live Activity." | **documented** (iOS 17+) | LiveActivityIntent |
| `AudioRecordingIntent` (iOS 18+): "tell the system that your app records audio … you must start a Live Activity when you begin the audio recording … If you don't start a Live Activity, the audio recording stops." | **documented** | AudioRecordingIntent |
| Whether an `AudioRecordingIntent` can start the mic from a cold background state: a Feb 2026 attempt failed with "Live Activity start failed … Target is not foreground"; the same developer then got the DTS privacy-block answer; the open-source lock-screen recorder that uses it sets `openAppWhenRun = true`. | **reported / DTS** | threads 815725, 816408; wake-capture-ios source |
| What everyone agrees works: a Live Activity button can pause or resume an **already running** session through an intent in the app's process. | **reported**, community | thread 815725 |
| A keyboard extension cannot run an App Intent or a Shortcut; there is no "keyboard appeared" automation trigger. | **documented** (by absence) | App Intents; Shortcuts triggers |
| iOS 26 and 27 add `BGContinuedProcessingTask`, `supportedModes`, `LongRunningIntent`; nothing relaxes background mic activation. | **documented** | WWDC25 227, WWDC26 345 |

### 4.4 The keyboard extension

| Claim | Status | Source |
|---|---|---|
| Extensions have no microphone. Full Access does not add it. | **documented** | App Extension Programming Guide; "Configuring open access"; QA1872 |
| `NSExtensionContext.open` is documented only for Today widgets and iMessage apps; on keyboards it returns false. | **documented / device** | NSExtensionContext; BUILD.md 0.1.21 |
| The responder-chain walk to `UIApplication` is "very much unsupported" (Quinn); the selector form died in iOS 18; the modern `open(_:options:completionHandler:)` form works on iOS 18–26 with Full Access. | **DTS / device** | thread 65621; BUILD.md 0.1.36 |
| A SwiftUI `Link` inside the keyboard view opens the URL on iOS 18+ (KeyboardKit's fix; Muesli ships it). | **reported**, Sep 2024 | keyboardkit.com blog; muesli-ios source |
| Guideline 4.4.1 says keyboards "must not launch other apps besides Settings". Launching the keyboard's **own** app for voice input has shipped since Gboard in 2017 and is what every app in section 5 does. | **documented vs practice** | Guidelines 4.4.1; TechCrunch 2017 |
| No public API tells a keyboard which app hosts it, or returns the user there (iOS 26.4+). Enhancement requests FB22247647 and FB24235692 are open. | **DTS**, 2026 | thread 826851 |

### 4.5 The orange dot

The indicator is driven by the microphone input actually running. No configuration
records without it (the only known suppression is spyware with a full SpringBoard
compromise). Playback-only shows nothing. Guideline 2.5.14 separately requires "a
clear visual and/or audible indication when recording". Apple treats the pill as the
user's consent signal for the continue-indefinitely rule (thread 776949), which is why
Willow's help calls it "required by Apple and not something Willow can hide".

---

## 5. What the other keyboards do

_Research date 2026-09-23. Quotes are from the apps' own help centres unless noted;
the App Store and several help domains were unreachable from the sandbox, so some
quotes come from search-engine snippets of the named pages (close to verbatim, not
certified). Entitlements are unknown for every closed-source app._

| App | How dictation starts | Where recording runs | Keeping the session | Orange dot | When iOS kills it |
|---|---|---|---|---|---|
| **Wispr Flow** | Keyboard "Start Flow" (first use per session opens the app); six Shortcuts for Action Button, Back Tap, Control Center; Live Activity Stop | Container app, a "Flow Session" | "Disable Flow after": Never / 1 h / 15 min / 5 min (default) / Immediately. Countdown runs only while backgrounded **and the keyboard is inactive**; showing the keyboard cancels it | On while a session is open; a Live Activity pill "Wispr Flow · on" persists across a keyboard session | "the keyboard resets itself … Tap the mic again" (round trip) |
| **Willow** | Keyboard mic | Container app, "background microphone session" | "Audio Session Timeout" 30 s to 2 h | Documented as expected and not hideable; off via the Live Activity, an app toggle, or force-quit | "you will have to re-enable it by activating Willow" |
| **Monologue** | Keyboard "Start Monologue"; Action Button Shortcut; Live Activity and Control Center controls | Container app | "microphone session timeout" adjustable; manual off | Likely while active | "the next recording may need to open the Monologue app again" |
| **Superwhisper** | Keyboard record button → app → per-app "switchback" list | Container app | "Background Recording Timeout" setting | Unknown | Manual switchback on iOS 26.4+ |
| **Aqua Voice** | Keyboard mic; first use "will boot you into the Aqua Voice app itself, and you then have to tap back" | Container app | Unknown | Unknown | Round trip |
| **DictaFlow** | Keyboard; app opens "when the recorder needs to reconnect" | Container app | "Mic Auto-Off … 1 hour or 4 hours" | Yes while armed | "swipe back to the app you were typing in" |
| **Spokenly** | Keyboard; a "Background Dictation" Shortcut that needs Live Activities enabled | Container app | Lapses after "a couple of minutes" | Unknown | Round trip |
| **Muesli** (open source) | Keyboard button, a SwiftUI `Link` to `muesli://dictate`; Action Button intent | Container app, persistent standby input engine | Standby by default; "Turn mic off after each dictation" opt-out; Live Activity "Mic ready" with an off button | Yes while standby | Round trip |
| **Dictus** (open source) | Keyboard → URL-scheme cold start; auto-return via a private `_UIKeyboardArbiterClient` walk plus per-app URL schemes (fails 7–20%) | Container app | Cold-start "audio bridge"; swipe-back overlay | — | Round trip |
| **Gboard** | Hold the mic on the space bar → Gboard app screen | Container app, **foreground, every time** | None | No | n/a |
| **Dictator** | Keyboard pill (Darwin); URL cold start | Container app, warm engine + silent keep-alive | Idle release 5 / 30 (default) / 120 / Never, from the last dictation | Yes while warm | Wake pill → app → swipe back |

What they say about the limit, in their own words:

- Willow: "Apple does not allow any third-party app or keyboard to start using the
  microphone in the background unless the app is active first. So before Willow can
  power dictation inside another app, it must quickly activate the app first. Once the
  background microphone session is active, Willow can work anywhere on your phone."
- Monologue: "iOS does not let a third-party keyboard start and keep a microphone
  session entirely by itself."
- Wispr Flow, on iOS 26.4: "Apple changed how apps switch between each other, and Flow
  cannot override it." Their wake screen reads "Flow is on. You can start dictating
  now. Swipe right across the bottom edge to continue."
- Wispr Flow, on the dot: "An orange dot, mic icon, or Dynamic Island pill can remain
  after you finish speaking." The fix steps end with "force-quit and relaunch Flow if
  the orange dot persists."
- DictaFlow's developer, replying to a review: "To reduce how often this happens, open
  DictaFlow → Settings → Keyboard → Mic Auto-Off and set it to 1 hour or 4 hours to
  keep the recorder alive longer in the background."

What the best of them do that Dictator does not, yet:

1. **Keyboard visibility pauses the countdown** (Wispr; Muesli's "fresh heartbeat").
2. **The wake is one keyboard tap** that launches the app (all of them; Muesli uses a
   public SwiftUI `Link`, Dictus and Dictator the URL scheme).
3. **A Live Activity is the session's face**: status, an off switch (Willow, Muesli,
   Wispr), and a way to resume after an interruption without a round trip.
4. **The help text owns the trade-off**: the dot is expected, here is how to turn it
   off, here is the timeout setting.

Two claims about Wispr to be careful with: a third-party guide says battery went "from
roughly 40% per hour to approximately 5% per hour" across versions, which could not be
verified against Wispr's own text; and Wispr's changelog says it "now returns you to the
app you were typing in", so some auto-return still ships on 26.4+, presumably by the
same private host-detection technique Dictus documents, which fails a fifth of the time.

---

## 6. What we have tried

From BUILD.md, oldest first. Each of these is still in the app unless noted.

| Build | What | Outcome |
|---|---|---|
| 0.1.5–0.1.9 | Two engines with the mic closed between dictations; open it on tap | **Refused from the background** (`kAUStartIO 2003329396`). Replaced by one always-on input engine started in the foreground. |
| 0.1.10, 0.1.14 | Wake button launches the app via the `openURL:` selector | Worked, then iOS 18 killed the selector. |
| 0.1.21 | Honest copy: "Open the Dictator app to wake it" | Still the fallback wording. |
| 0.1.22–0.1.24 | Self-heal on foreground, on interruption-ended, and a heartbeat; zeroed silence buffer | Fixed the "zombie" warm state and the pops/"thank you". |
| 0.1.35 | Silent playback as the residency keep-alive, restartable from the background | Still the mechanism. |
| 0.1.36 | Responder chain → `UIApplication.open(_:options:completionHandler:)` | **Verified on device**: the keyboard launches the app on iOS 18+/26 (Full Access needed for the chain to reach `UIApplication`). |
| 0.1.40 | Open-URL only warms; "swipe back" banner | The model since: open once, then dictate in place. |
| 0.1.41 | No automatic app opens, ever | Ended the "bounces every minute". |
| 0.1.42–0.1.44 | Engine mutations on one serial queue; shared URLSession; end a capture whose mic died | Ended the crash-driven wakes. |
| 0.1.45 | Idle auto-off, 5 minutes | Orange dot no longer all day; more wakes. |
| 0.1.48 | Heartbeat watches the keep-alive; route changes restart it; resync refuses to tear down while backgrounded; idle window a setting, default 30 min | Ended the "every other minute". |
| 0.1.54 | Tap installed with `format: nil` | Ended the crash loop after interruptions. |
| 0.1.58 | `liveState` says cold when the mic is dead | Ended the flickering pill loop. |
| 0.1.59, 0.1.62 | Wispr-style wake screen with the fingertip | The wake costs one swipe. |
| 0.1.94 | `audioInterrupted` flag; no warm/rebuild during a call | Ended the wake-screen loop during calls. |
| 2026-09-14 | Private host-app walk removed | Auto-return gone by choice (App Store safety). |
| 0.1.122 | Shorter swipe-back bar | The swipe lands in the gesture zone. |

Things researched and deliberately not done: `UIApplication.suspend` (lands on the
Home Screen, not the previous app); any private host-detection (`_hostBundleID`, the
keyboard arbiter walk) for App Store safety; opening the app automatically on a
failed capture (0.1.41 removed it).

---

## 7. What we have not tried, and could

Ordered by expected payoff over cost. Each has a hypothesis, a test, and a risk.

### 7.1 Pause the idle countdown while the keyboard is visible ▸

**Hypothesis.** Most of the 30-minute releases happen while Jeremy is still using the
phone with the Dictator keyboard up. Wispr counts only keyboard-inactive time.

**Change.** The keyboard already posts `.keyboardShown` / `.keyboardHidden`. Make the
app treat a shown keyboard as activity: pause the idle timer on `keyboardShown`,
restart it on `keyboardHidden`. Belt and braces: the keyboard stamps a "visible"
timestamp into the App Group every few seconds while up (Muesli's heartbeat), and the
idle timer reads it before releasing.

**Test.** Type for 40 minutes with the keyboard up and no dictation; the log must not
show `mic released`. Cost: an afternoon. Risk: none; the dot stays on only while the
keyboard is on screen, which the user can see.

### 7.2 Try the background mic restart after an interruption ends, once, and log it ▸

**Expectation: refused.** The DTS statements in 4.1 say a recording session cannot be
activated from the background by an app like ours, and the one dated report of exactly
this case (a call, app backgrounded, `.ended` received) says reactivation fails until
the app is opened. The folklore about `.mixWithOthers` is contradicted by DTS.

**Why still do it.** It is one guarded call in the `.ended` handler, rate-limited, that
falls back to today's behaviour, and it turns a belief into a device fact for this
app on this iOS: `bg mic restart: ok` or `bg mic restart: refused <code>` in the log.
If it ever says ok, every call stops costing a wake. Cost: ten lines.

### 7.3 Probe for the end of an interruption instead of waiting for `.ended` ▸

The events at 20:33 and 20:36 never ended; the app sat interrupted until the idle
release. `warmForWake` already has the probe (`micAvailableNow()`). While
`audioInterrupted` is set, the heartbeat could probe every 10 seconds and clear the
flag on success.

**What it buys, honestly.** Not the mic: that still cannot restart in the background
(4.1). It buys a truthful `cold` stamp the moment the interruption is really over,
so the keyboard shows the wake pill immediately instead of after a failed tap, and it
stops the app from believing a call is in progress an hour later. Worth doing; small.

### 7.4 Residency during and after an interruption: what to keep alive, and why

During a call both engines stop, no audio renders, and iOS suspends the process
within seconds (`keep-alive STOPPED; app can be suspended`). A suspended process does
not receive `.ended`; it receives it when it next runs, which is when the user opens
the app. There is no sanctioned way to stay resident through a call (4.2), and a
resident process with a dead mic cannot do anything useful anyway, because the mic
cannot be restarted until the foreground (4.1).

**So the keep-alive without a mic is pure cost.** It keeps a process alive that can
serve no dictation, it is the "silence to stay resident" pattern App Review rejects
under 2.5.4, and it is the buffer whose garbage once produced the pops and the
"thank you" hallucination (LESSONS). Two experiments follow:

- **7.4a ▸ Is the keep-alive needed at all while the mic is live?** Apple's rule is
  that a foreground-started recording continues indefinitely; the input engine *is* an
  active, rendering session. 0.1.9 ran without the silent player; 0.1.35 added it back
  as "residency" without a recorded test that the input alone was insufficient. Test:
  warm, background, disable the keep-alive, leave the phone for two hours, read the
  heartbeat stamps. If the app stays resident, delete the silent player and the
  second engine, and the 2.5.4 exposure with them.
- **7.4b ▸ When the mic is dead, let go.** On an interruption that leaves the mic
  dead while backgrounded, stop the keep-alive too, stamp `cold`, and let iOS suspend
  the app. The URL open from the keyboard launches a suspended or terminated app just
  as well as a resident one, so the wake costs the same and the phone keeps its
  memory.

### 7.5 A Live Activity as the session's face

**Change.** Start a Live Activity when the mic warms: "Dictator · listening" with an
off button (a `LiveActivityIntent`, which runs in the app's process). On an
interruption it shows "paused; tap to resume". The resume button cannot restart the
mic from the background (4.1); give it `supportedModes: [.background, .foreground(.dynamic)]`
so it brings the app forward only when it must, which is every time the mic is dead.
That is the same trip as the keyboard pill, but reachable from the Dynamic Island on
any screen, and it is the surface Wispr, Willow, Monologue and Muesli all show.

**Also buys.** A visible reason for the background audio mode at App Review (2.5.4,
2.5.14 both want a visible recording state); a way to turn the mic off without
force-quitting; the status the keyboard already infers. Cost: a day. Risk: low; it is
additive. Keep it honest: the pill must say "paused" when the mic is dead.

### 7.6 Fewer interruptions in the first place ▸

`AVAudioSession.setPrefersNoInterruptionsFromSystemAlerts(true)` (iOS 14.5+) asks that
alarms, timers and similar system sounds not interrupt the session. A DTS thread from
2025 says an incoming call's ringing still interrupts recording and there is no
configuration for that (an enhancement request is open), so expect this to cover
alarms and timers, not calls. One line; test a timer going off and a declined call
with the phone in the pocket.

### 7.7 Make the wake one tap, always

The keyboard's responder-chain launch works when Full Access is on. Muesli launches
with a public SwiftUI `Link` inside the keyboard view, and the Maestro item about
`EnvironmentValues().openURL` is the same idea. Try both as the first two methods in
`coldStart()`; keep the responder chain as the third. If all fail, the message should
say exactly why (no Full Access) rather than "couldn't open".

### 7.8 Defaults and copy

Match the field: keep 30 minutes as the default but count keyboard-inactive time
(7.1); keep Never; add a help paragraph like Willow's ("the orange dot means Dictator
is ready to dictate inside other apps; here is how to turn it off"). Consider a
"Turn mic off after each dictation" option (Muesli) for people who want no dot at all
and accept the round trip.

### 7.9 Memory footprint in the background ▸

Apple's own guidance for an audio app to be safe from memory termination is **under
100 MB in the background** (4.2). Nobody has measured Dictator's. In on-device mode the
accurate model alone is about 900 MB; even in cloud mode the app carries a SwiftUI
scene, the swipe lexicon is in the keyboard (not here), and whatever the audio engines
hold. Measure with Xcode's memory gauge warm-and-backgrounded, in both modes. Then:
unload the model when the app backgrounds and the idle timer has run for two minutes
(reload from cache on the next capture or foreground); drop anything else that is
not needed to keep the tap running.

### 7.10 Things that look like loopholes and are not

- **CallKit.** Reporting a fake call would let the app start audio from the background;
  it also shows a green call bar and gets an app rejected. No.
- **Location background mode.** Keeps the process alive with a blue arrow and a
  privacy prompt about tracking. No.
- **Picture-in-picture.** A PiP window keeps the process alive; it does not let the mic
  start, and a floating video for a keyboard is absurd. No.
- **Silent pushes.** The backend could wake the app for 30 seconds, but the keyboard
  has no network to ask for one (by design), and the mic still could not start. No.
- **Push to Talk framework.** The system does unlock the mic in the background for a
  PTT transmission, and shows a blue pill. DTS: for communication apps only, "can't be
  used for any other purpose". No.
- **`AudioRecordingIntent` as a cold start.** It is the sanctioned surface for a
  recording app's Lock Screen and Action button controls, and it still needs the
  foreground to start the mic (4.3). Useful as a second entry point later, not as a
  keep-alive.
- **Recording from the keyboard.** QA1872; the extension has no entitlement, and the
  runtime says so (`CMSUtility_IsAllowedToStartRecording … NOT allowed`). No.
- **Auto-return to the host app.** No public API since iOS 26.4; the private walk
  fails 7–20% of the time even for Dictus. Not for the App Store build.

---

## 8. Recommended plan

The wall is real: the mic is armed in the foreground or not at all, and every
interruption ends the warm state. So the work is (a) stop ending it ourselves, (b) make
the unavoidable wake cheap and truthful, and (c) stop paying for residency that serves
nothing.

1. **0.1.124: the policy fixes and the instrumented experiments.** Pause the idle
   countdown while the keyboard is visible (7.1); `setPrefersNoInterruptionsFromSystemAlerts`
   (7.6); the one guarded background restart attempt after `.ended`, logged (7.2);
   the interruption probe (7.3); when the mic is dead in the background, stop the
   keep-alive and stamp cold (7.4b). Jeremy's next Report-a-problem log answers 7.2
   and 7.3 for free.
2. **The keep-alive test (7.4a).** One build with the silent player off while the mic
   is live, two hours in a pocket, read the stamps. If the app stays resident, delete
   the silent player.
3. **Then 7.5**, the Live Activity with status, off, and a resume that foregrounds
   only when it must.
4. **Then 7.7 and 7.8**, the `Link`-based one-tap wake as the first method and the
   help copy that owns the orange dot.
5. **7.9** as soon as the memory gauge has been read once.

What "done" looks like: a day of ordinary use with no `mic released` line except
after a real lull, a wake only after a call, Siri, or Low Power Mode, and that wake
being one tap and one swipe with the keyboard already saying so before you tap.

What it will never look like, on this platform, for any app: a keyboard tap that
starts the microphone when the app is not already holding it.

---

## 9. Sources

Apple documentation and engineers (DTS = Apple Developer Technical Support on the
forums; thread numbers are developer.apple.com/forums/thread/N):

- App Store Review Guidelines 2.5.4, 2.5.14, 4.4.1; QA1872; QA1924.
- App Extension Programming Guide, Custom Keyboard; "Configuring open access for a
  custom keyboard"; "Configuring a custom keyboard interface" (hasDictationKey).
- AVAudioSession.ErrorCode; setActive(_:options:); "Handling audio interruptions";
  "Configuring your app for media playback"; "Configuring background execution modes".
- "Adding interactivity to widgets and Live Activities"; LiveActivityIntent;
  AudioRecordingIntent; ForegroundContinuableIntent; AppIntent.supportedModes;
  "Displaying live data with Live Activities"; "Creating controls to perform actions
  across the system"; LongRunningIntent (iOS 27).
- "Pushing background updates to your app"; "Responding to VoIP notifications from
  PushKit"; CLBackgroundActivitySession; startMonitoringSignificantLocationChanges;
  "Extending your app's background execution time"; "Identifying high memory use with
  jetsam event reports".
- WWDC20 10063 (Background execution demystified); WWDC22 10117 (Push to Talk);
  WWDC24 10157 (Controls); WWDC25 227, 230, 251; WWDC26 345.
- DTS threads: 776949 (Quinn, Apr 2025: foreground-started recording continues
  indefinitely; 2.5.4/2.5.14 risk); 816408 (Kevin Elliott, Feb 2026: the privacy
  block on background recording activation); 812592 (Jan 2026: disabled since late
  iOS 12; mixWithOthers prevents background activation); 764096 (Sep 2024: audio
  mode "not quite" a guarantee; under 100 MB); 769398 (Quinn, Dec 2024: Darwin
  notifications and suspended apps); 85066 (Quinn: ~30 s background tasks); 652395
  (Aug 2020: resume playback in the foreground); 784782 (2025: ringing interrupts,
  FB18434531); 793010 and 791744 (Jul 2025: PiP is not a keep-alive); 826851 (2026:
  no host-app API, FB22247647, FB24235692); 65621 (Quinn: responder-chain launch is
  unsupported); 818467 (Mar 2026: intents may start Live Activities from the
  background).
- Reported (not Apple staff): 813278 (Jan 2026: after a call, reactivation only works
  after opening the app); 815725 (Feb 2026: AudioRecordingIntent from the
  background fails, "Target is not foreground"); 805735 (Oct 2025: iPhone 16e tap
  stops after a call); 120038, 674632, 725361, 742601, 775077, 800500.

Other apps (help centres and sources; several fetched only as search snippets because
the sandbox could not reach the domains):

- Wispr Flow: docs.wisprflow.ai articles 7453988911 (keyboard setup, "Disable Flow
  after", countdown rule), 3634682593 (orange dot), 6269634092 (iOS 26.4),
  4500510662 (Action button), 1986921789 (Shortcuts), 7971211038 (paste),
  4841123325 (20-minute sessions); wisprflow.ai/whats-new; 9to5Mac 2025-06-30;
  TechCrunch 2025-06-03.
- Willow: help.willowvoice.com articles 12855752, 12855770, 12845807.
- Monologue: help.monologue.to article 14483873. Superwhisper: App Store release
  notes, eiiis.substack.com. Aqua Voice: 9to5Mac 2026-04-17. DictaFlow, Typeless,
  VoiceInk, Spokenly, Voicenotes: App Store listings and reviews; spokenly.app/docs.
- Open source: github.com/Muesli-HQ/muesli-ios (README, Info.plist, PR #40,
  docs/keyboard-mic-session.md, KeyboardRootView.swift); github.com/getdictus/dictus-ios
  (issues #23, #281, #543; PR #538); github.com/philster/wake-capture-ios;
  KeyboardKit blog 2024-09-11 (iOS 18 and Link).
- Gboard: TechCrunch 2017-02-23; support.google.com/gboard/answer/2781851.

This repository: BUILD.md (0.1.5 to 0.1.122), Projects/Dictator/LESSONS.md (Maestro),
iOS/DictatorApp/BackgroundRecorder.swift, iOS/DictatorKeyboard/KeyboardViewController.swift,
and the three device logs of 2026-09-22/23 quoted in section 3.
