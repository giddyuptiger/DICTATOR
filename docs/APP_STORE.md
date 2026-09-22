# App Store Submission Pack — Dictator

Everything needed for the App Store Connect listing and review. Fill/adjust the
bracketed bits. Dated 2026-09-17.

> Copy reflects the real app today: **on-device transcription** (your voice stays on
> the phone) + cloud cleanup for formatting. Update if the tiers change.

---

## Basics
- **Name:** `DICTATOR: Speech To Text` (24 chars — fits the 30 limit)
- **Subtitle (≤30 chars):** `Private, on-device dictation` (28)
- **Primary category:** Productivity
- **Secondary category:** Utilities
- **Age rating:** 4+
- **Price:** Free (with premium subscription to follow)
- **Support URL:** https://giddyuptiger.github.io/DICTATOR/
- **Privacy Policy URL:** https://giddyuptiger.github.io/DICTATOR/privacy-policy.html
- **Bundle ID:** design.irons.dictator

> ⚠️ Confirm "DICTATOR: Speech To Text" is available in App Store Connect. Backups:
> "Dictator — Voice Keyboard", "Dictator: Voice Typing".

## Promotional text (≤170 chars)
> Dictate anywhere with a keyboard that turns speech into clean text — transcribed
> right on your iPhone, so your voice never leaves your device.

## Keywords (≤100 chars, comma-separated, no spaces)
`dictation,voice to text,speech to text,keyboard,transcribe,offline,private,voice typing,notes,voice`

## Description (≤4000 chars)

Dictator is a dictation keyboard that turns your voice into clean, formatted text in
any app — messages, email, notes, anywhere you can type.

WHAT MAKES IT DIFFERENT

• On-device transcription. Your speech is turned into text right on your iPhone, so
  your voice never has to leave your device. It even works offline.

• Actually clean text. Dictator doesn't just transcribe — it fixes punctuation and
  capitalization, drops the "um"s and false starts, and breaks long thoughts into
  real paragraphs. You get text you'd have typed, not a raw dump.

• Modes for how you want to sound. Super Casual, Casual, Formal, Expressive (with
  the punctuation that carries feeling), and Emoji. Pick the register; Dictator
  matches it.

• Your words, your way. Add names and terms to your vocabulary and Dictator spells
  them correctly every time.

• It respects your music. Dictator records over whatever you're listening to — it
  never pauses, ducks, or hijacks your music or car audio.

HOW IT WORKS

Tap the mic on the Dictator keyboard, speak, and your words appear where your cursor
is. Because iOS keyboards can't use the microphone directly, Dictator does the
listening in its app and keeps it ready in the background so dictation is instant.

PRIVACY FIRST

On the free tier your audio is transcribed on your device and never uploaded. The
text-cleanup step uses a fast cloud service to format your words; you can review
exactly what's sent in our privacy policy. No account required. No ads. No tracking.

Dictator is a fast, private alternative to the dictation tools that cost $15/month.

---

## App Privacy (data-disclosure answers)

- **Account required?** No.
- **Data collected:** None linked to identity.
- **Audio:**
  - On-device tier: NOT collected (processed on device, never leaves it).
  - Cloud/BYOK: audio is *sent for processing* to transcribe/format, **not stored**
    and **not linked** to the user. Declare under "Data Not Linked to You" →
    "Audio Data," used for **App Functionality** only. Not used for tracking.
- **Text/transcript:** processed to produce output; not stored by us server-side.
- **Payments:** handled by Apple (StoreKit); we don't receive payment data.
- **Tracking:** none. No third-party ad SDKs.
- **Privacy Manifest:** present in both targets (verify required-reason API
  declarations match usage before submitting).

## Reviewer notes (paste into App Review "Notes")

Dictator is a dictation keyboard. Two things reviewers should know:

1) HOW TO TEST DICTATION. iOS keyboard extensions cannot access the microphone, so
   recording happens in the Dictator container app. First launch: open Dictator,
   complete the short setup (enable the keyboard and Full Access in Settings), and
   turn Dictator on so the mic is ready. Then in any app, switch to the Dictator
   keyboard and tap the mic to dictate. If the app was evicted from memory, tapping
   the keyboard's mic opens Dictator to a "swipe back to your app" screen — this is
   expected (iOS removed automatic return-to-app in 26.4).

2) WHY FULL ACCESS. The keyboard needs Full Access for (a) network, for the cloud
   text-cleanup step, and (b) its shared app-group storage, to receive the transcript
   from the container app. We do not log or transmit keystrokes or text-field
   contents. This is explained in our privacy policy.

No account or login is required. On-device transcription needs a one-time model
download on first use (requires network once, then works offline).

## Screenshots plan (6.7" + 6.1" required; iPad optional)

Capture the raw phone screenshots on device, then compose the App Store cards
with the generator in `fastlane/screenshots/src/` (one command per card, see
`make.py`; it renders 1284×2778 and refuses any price word — guideline 2.3.7):
1. The keyboard mid-dictation (mic active, waveform) in Messages.
2. Before/after: raw speech vs. cleaned, formatted result.
3. The mode picker (Casual / Formal / Expressive / Emoji).
4. The main screen showing "Transcribing on your iPhone — private."
5. The "swipe back to your app" wake screen.
6. (Optional) Vocabulary screen.

Add a short caption bar to each (e.g. "Speak. Get clean text." / "Private,
on-device." / "Sound how you want."). Keep captions consistent.

## Pre-submit checklist
- [ ] Embedded API key removed from shipping build (LAUNCH BLOCKER — see BUSINESS.md).
- [ ] Legal placeholders reviewed; consider an LLC before charging money.
- [ ] Name availability confirmed in App Store Connect.
- [ ] Screenshots captured and uploaded.
- [ ] App Privacy answers entered to match this doc + the privacy manifest.
- [ ] Reviewer notes pasted.
- [ ] Test full flow on a clean device (install → onboarding → dictate → swipe back).
