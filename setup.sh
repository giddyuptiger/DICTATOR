#!/usr/bin/env bash
# Generates both Xcode projects. Run from the repo root.
set -euo pipefail

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found. Installing with Homebrew…"
  brew install xcodegen
fi

# A fresh clone has no Secrets.swift: it is gitignored, and Xcode Cloud writes
# it from an environment variable. Without it the iOS app does not compile at
# all (BuildSecrets is undefined), which made "clone and build" fail for reasons
# the error message does not explain. Seed an empty one; a key typed in the app
# overrides it anyway.
SECRETS="Sources/DictationCore/Secrets.swift"
if [ ! -f "$SECRETS" ]; then
  echo "==> Creating $SECRETS from the example (no key set)"
  cp "$SECRETS.example" "$SECRETS"
fi

echo "==> Generating the probe project"
( cd Probe && xcodegen generate )

echo "==> Generating the Dictator project"
xcodegen generate

cat <<'MSG'

Done. Two projects:

  Probe/MicProbe.xcodeproj   <- run this FIRST, on a real device
  Dictator.xcodeproj             <- the real thing

Open the probe:      open Probe/MicProbe.xcodeproj
Open Dictator:           open Dictator.xcodeproj

In Xcode, pick your team under Signing & Capabilities for each target
(or set DEVELOPMENT_TEAM in project.yml and regenerate).

MSG
