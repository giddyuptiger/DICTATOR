# Fastlane — push the App Store listing without the ASC web forms

All your App Store text lives here as files. `fastlane deliver` uploads it to App
Store Connect for you, so you don't hand-type it into the website.

## What's here
- `metadata/en-US/*.txt` — name, subtitle, description, keywords, promo text,
  release notes, support/marketing/privacy URLs.
- `metadata/review_information/notes.txt` — the App Review notes (explains the
  keyboard mic-hop + Full Access so review doesn't bounce it).
- `screenshots/en-US/` — drop your PNG screenshots here (see below).
- `Appfile` / `Deliverfile` — config.

## One-time setup
1. Install fastlane: `brew install fastlane` (or `gem install fastlane`).
2. Create an **App Store Connect API key** (App Store Connect → Users and Access →
   Integrations → App Store Connect API → generate a key). Download the `.p8` and
   note the Key ID and Issuer ID. This is how fastlane authenticates without your
   password/2FA.
3. The app record must already exist in App Store Connect once (create it there:
   name "DICTATOR: Speech To Text", bundle id design.irons.dictator). fastlane
   updates it; it doesn't create the first record.

## Upload the metadata
From the repo root, with your API key exported:
```
export ASC_KEY_ID=xxxxxxxx
export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
export ASC_KEY_PATH=~/AuthKey_XXXX.p8

fastlane deliver \
  --api_key_path <(printf '{"key_id":"%s","issuer_id":"%s","key":"%s"}' \
    "$ASC_KEY_ID" "$ASC_ISSUER_ID" "$(cat $ASC_KEY_PATH)")
```
(Or add a small Fastfile lane later; this one-liner is enough to start.) It uploads
all the text above. `Deliverfile` has `submit_for_review(false)`, so it will NOT
submit — you review and hit Submit in ASC the first time.

## Screenshots (you capture these)
fastlane can't invent screenshots. Capture them from the app, then drop the PNGs in
`screenshots/en-US/` and set `skip_screenshots(false)` in `Deliverfile`.

Required sizes: **6.7"** (1290×2796, iPhone 15/16 Pro Max) and **6.1"**
(1179×2556). Easiest path: run the app in the iOS Simulator for those devices and
press Cmd+S for each shot, or take them on your iPhone. Shots to grab (from
docs/APP_STORE.md): keyboard mid-dictation, before/after clean-up, the mode picker,
the main "on-device / private" screen, the swipe-back wake screen.

## What fastlane still can't do for you
- Create the very first app record (do it once in ASC).
- Upload the build (that's Xcode Cloud → TestFlight already).
- Design the app icon (export the neon mark from your design tool; no text in it).
- Answer the App Privacy questionnaire (do it in ASC once; answers are in
  docs/APP_STORE.md).
