#!/usr/bin/env bash
# Generates both Xcode projects. Run from the repo root.
set -euo pipefail

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found. Installing with Homebrew…"
  brew install xcodegen
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
