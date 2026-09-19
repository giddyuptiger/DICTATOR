# Privacy Policy — Dictator

**Effective date:** September 17, 2026
**Developer:** Jeremy Irons
**Contact:** support@trydictator.com

> ⚠️ **Draft.** This is a solid starting point written from how the app actually
> works, but it is not legal advice. Have it reviewed before you charge money or
> launch, and fill in every [BRACKETED] placeholder.

Dictator is a dictation keyboard for iPhone. This policy explains what it does and
does not do with your data. The short version: **the free tier transcribes
entirely on your device and sends nothing anywhere.**

## What Dictator processes

**Your voice (audio).**
- **On-device tier (free):** your speech is transcribed entirely on your iPhone
  using an on-device model. The audio never leaves your device and is not sent to
  us or any third party.
- **Cloud tier (premium):** your audio is sent, over an encrypted connection, to
  our transcription provider (**Groq**) to convert speech to text, and a short
  text-cleanup step is run to fix punctuation and formatting. The audio is used
  only to produce your transcript for that request and is not stored by us
  afterward.
- **Bring-your-own-key (optional):** if you supply your own Groq API key, your
  audio is sent directly from your device to Groq under your own account and
  their terms; it does not pass through our servers.

**Transcribed text.** The resulting text is inserted where your cursor is. Your
most recent transcript is cached locally on your device for convenience (copy,
correct) and is not transmitted to us.

**Personal vocabulary.** Words and names you add are stored locally on your device
(in the app's shared storage) so your transcripts are spelled your way. They are
not transmitted to us.

**Diagnostics.** An activity log is kept locally on your device to help you
troubleshoot. It is not transmitted anywhere unless you choose to share it with us.

**Payments (premium).** Subscriptions are processed by **Apple** through in-app
purchase; we never receive or store your payment details. We may use a
subscription-management provider (**RevenueCat**) to confirm your subscription
status. If you use Sign in with Apple, we receive only a stable anonymous
identifier (and, if you choose, a relay email) to keep your subscription across
devices.

## What Dictator does NOT collect

We do not collect your name, contacts, location, photos, browsing history, or
advertising identifiers, and we do not sell your data or use it for advertising.

## Full Access keyboard

Dictator's keyboard requires "Full Access" so it can reach the network (for cloud
transcription) and its own shared storage. A keyboard with Full Access is
technically able to access text in the field you're typing in; Dictator uses this
only to insert and edit your dictated text. We do not log, store, or transmit your
keystrokes or the contents of your text fields.

## Third-party services

- **Groq** — cloud speech-to-text and text cleanup (cloud tier / BYOK). See Groq's
  privacy policy.
- **Apple** — in-app purchases and, optionally, Sign in with Apple.
- **RevenueCat** — subscription status management (premium).

## Data retention

Cloud audio is processed transiently and not retained by us after your transcript
is returned. Local data (last transcript, vocabulary, logs, settings) stays on
your device until you delete it or uninstall the app.

## Security

Network requests use encrypted connections (HTTPS/TLS). On the cloud tier, our
transcription API key is held only on our servers, never in the app.

## Your rights

Because the free tier keeps your data on your device and we collect very little
otherwise, there is little for us to hold. To ask about, access, or delete any
data associated with a premium account, contact us at support@trydictator.com.
Depending on where you live (e.g. EEA/UK under GDPR, California under CCPA), you
may have rights to access or delete your data; we will honor applicable requests.

## Children

Dictator is not directed to children under 13 and does not knowingly collect data
from them.

## Changes

We may update this policy; we will post the new version with a new effective date.

## Contact

Jeremy Irons — support@trydictator.com
