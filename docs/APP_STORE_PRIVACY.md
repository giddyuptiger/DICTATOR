# App Privacy answers — Dictator (click-by-click)

The App Privacy questionnaire is a web form in App Store Connect, not something
fastlane fills. Answer it once; it's required before you can submit.

These answers match `docs/privacy-policy.md`. The short version of Dictator's
posture: **on-device tier sends nothing; cloud tier sends audio + text to Groq
(via our backend) only to produce your transcript, not retained, not linked to
you, and we do no tracking and no ads.** So everything below is "Data Not Linked
to You," used only for App Functionality.

## Where

1. https://appstoreconnect.apple.com → sign in
2. **Apps** → **Dictator**
3. Left sidebar → **App Privacy**
4. Under **Data Collection**, click **Get Started** (or **Edit**)

## Step 1 — "Do you or your third-party partners collect data from this app?"

Choose **Yes**. (The cloud tier sends audio and text to Groq to transcribe and
format it, so "Yes" is the honest answer even though it isn't retained.)

## Step 2 — Select the data types you collect

Check these three, and nothing else:

- **Audio Data** (under *User Content*) — the cloud tier sends your speech to Groq
  to transcribe. On-device tier does not, but since the app *can* send it, declare it.
- **Other User Content** (under *User Content*) — the transcribed text is sent to
  the cleanup step to fix punctuation/formatting.
- **User ID** (under *Identifiers*) — a random, per-install ID we generate so the
  backend can rate-limit abuse. It is not your Apple ID and isn't tied to who you
  are; declaring it is the conservative, safe choice.

Leave everything else **unchecked**: no Contacts, Location, Photos, Health,
Browsing History, Search History, Purchases, Financial Info, Contact Info,
Sensitive Info, Usage Data, or Diagnostics. (The activity log is local-only and
never transmitted, so it is *not* collected.)

## Step 3 — For EACH of the three types, answer the follow-ups the same way

- **How is this data used?** → check **App Functionality** only.
- **Is this data linked to the user's identity?** → **No** (not linked).
- **Do you use this data to track the user?** → **No**.

That places all three under **"Data Not Linked to You."**

## Step 4 — "Data Used to Track You"

**None.** Dictator does no tracking and shows no ads, so you do **not** need an App
Tracking Transparency prompt.

## Step 5 — Publish

Click **Publish** on the App Privacy page. You can edit it later if the app's data
behavior changes.

## When you add the premium subscription later

Once in-app purchases ship (Apple IAP + RevenueCat), come back and also declare:

- **Purchases** (under *Purchases*) — App Functionality, not linked, no tracking.
- If you add **Sign in with Apple** for cross-device subscription sync, you'll
  receive an anonymous identifier (and optionally a relay email); declare
  **User ID** (already declared) and, if you store the relay email, **Email
  Address** — both App Functionality, not linked, no tracking.

RevenueCat and Apple are then your third-party partners for that data; the form
lets you note third-party collection.

## Notes / honesty

- This is written from how the app actually works and mirrors the privacy policy.
  It is not legal advice; if you want to be bulletproof before charging money, have
  a lawyer glance at it.
- If Apple's reviewer asks why a keyboard needs Full Access, the answer is already
  in `fastlane/metadata/review_information/notes.txt`: network for the cloud
  cleanup step, and shared app-group storage to receive the transcript from the
  container app — no keystroke logging.
