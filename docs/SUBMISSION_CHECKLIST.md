# Dictator — App Store submission checklist

Everything code/infra-side is done. What's left is App Store Connect work. Do these
in order. Items marked **(you)** need a human in ASC or on a device — I can't do them
from here.

## 1. Fix the App Store Connect API key (one time) **(you)**

`fastlane deliver` needs an ASC API key. The earlier "invalid curve name
(OpenSSL::PKeyError)" was a malformed key file (mangled newlines). Rebuild it
cleanly from your downloaded `.p8`:

1. In ASC → **Users and Access → Integrations → App Store Connect API**, note your
   **Key ID** and **Issuer ID**, and download the `AuthKey_XXXXXX.p8` (once only).
2. Put the `.p8` in `~/DICTATOR/`, then run from there:

```
cd ~/DICTATOR
python3 - <<'PY'
import json, glob
p8 = glob.glob("AuthKey_*.p8")[0]
data = {
    "key_id":   "PASTE_KEY_ID",
    "issuer_id":"PASTE_ISSUER_ID",
    "key":      open(p8).read(),   # real newlines preserved -> no curve error
    "in_house": False,
}
open("asc_api_key.json","w").write(json.dumps(data))
print("wrote asc_api_key.json from", p8)
PY
```

`asc_api_key.json` is gitignored — it stays on your Mac.

## 2. Push the listing metadata **(you, one command)**

The copy (name, subtitle, description, keywords, promo, release notes, URLs) is
already written in `fastlane/metadata/`. Upload it:

```
cd ~/DICTATOR
fastlane deliver --api_key_path ./asc_api_key.json
```

This uploads **metadata only** (no binary, no screenshots) and does **not** submit —
all deliberate. It'll show a preview and proceed.

## 3. App Privacy questionnaire **(you)**

Follow `docs/APP_STORE_PRIVACY.md` — it's the exact click-by-click answer sheet.
~2 minutes. Required before submit.

## 4. Screenshots **(you — needs a device/simulator)**

App Store requires at least one 6.7" screenshot (1290 × 2796). Capture ~3–5 on a
simulator or your phone. Good set:
- Home tab with the big mic hero ("Ready to dictate")
- A finished dictation showing clean text
- The Style tab (the five registers)
- The Dictator keyboard open in Messages/Notes, mid-dictation

Drop the PNGs in `fastlane/screenshots/en-US/`, flip `skip_screenshots(true)` →
`false` in `fastlane/Deliverfile`, and re-run the deliver command in step 2 — or
just drag them into ASC directly. (Simplest for a first submission: drag into ASC.)

## 5. Pick the build & submit **(you)**

1. In ASC → Dictator → your version → **Build** → select the latest TestFlight build.
2. Fill **Export Compliance** if asked: uses standard encryption (HTTPS) → **exempt**.
3. **Age rating**, **category** (Productivity or Utilities), pricing (Free to start).
4. **Add for Review → Submit**.

The reviewer notes explaining the keyboard + Full Access are already in
`fastlane/metadata/review_information/notes.txt` and upload with the metadata.

## Before you scale wide (not a launch blocker)

- **App Attest** backend hardening — plan in `docs/APP_ATTEST.md`. Needs ~an hour with
  a real device to verify before flipping on. Do it before you push hard for volume;
  the rate limits + global spend cap cover a soft launch.

## Learned from the 1.0 (122) rejection (2026-09-22)

- **Permission pre-prompts (5.1.1(iv)).** Any screen shown before a system
  permission dialog (microphone, and Full Access if we ever prompt for it) must
  use a neutral button — "Continue" or "Next", never "Allow…" — and must always
  lead to the system prompt. No "Skip", "Later" or close button on that screen
  until the prompt has been answered. The app may explain why first; the user
  decides in Apple's dialog.
- **No price references in metadata (2.3.7).** Screenshots, previews, app name,
  subtitle and promotional text must not mention price — and "free", "no
  subscription" or "$15/month" all count as price references. The description
  is the one place price may be discussed. Check every screenshot caption
  before upload.
