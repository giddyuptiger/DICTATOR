#!/bin/sh
# Xcode Cloud runs this immediately after cloning, before it looks for a project.
#
# That timing is the whole point: this repo has no .xcodeproj committed, because
# project.yml is the source of truth and the project is generated from it. Without
# this script Xcode Cloud clones the repo, finds no project, and fails before it
# starts.
set -e

echo "==> Installing XcodeGen"
brew install xcodegen

cd "$CI_PRIMARY_REPOSITORY_PATH"

# Build numbers must be unique and increasing for every upload. CI_BUILD_NUMBER is
# supplied by Xcode Cloud and increments on its own, so the committed value in
# project.yml is only ever a local placeholder.
if [ -n "$CI_BUILD_NUMBER" ]; then
  echo "==> Setting build number to $CI_BUILD_NUMBER"
  sed -i '' "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$CI_BUILD_NUMBER\"/" project.yml
fi

# The Groq key is NO LONGER embedded in the app — it lives only on the backend
# proxy (Cloudflare Worker). We still generate Secrets.swift for compatibility, but
# with an EMPTY key, so no secret is ever compiled into the binary. (BYOK users add
# their own key at runtime; everyone else routes through the backend.)
echo "==> Writing Secrets.swift (empty; key is on the backend, not in the app)"
cat > Sources/DictationCore/Secrets.swift <<SWIFT
import Foundation

/// Generated at build time. The Groq key is not embedded in the app anymore; it
/// lives on the backend proxy. Kept empty for compatibility.
enum BuildSecrets {
    static let groqAPIKey = ""
}
SWIFT

echo "==> Generating the Xcode project"
xcodegen generate

# Xcode Cloud disables Xcode's automatic package resolution and then requires a
# committed Package.resolved. This project has none, because the whole .xcodeproj
# and its workspace are generated fresh above and never committed. `xcodebuild
# -resolvePackageDependencies` does NOT help: with automatic resolution disabled
# it refuses to resolve and demands the very file we are missing.
#
# SwiftPM's own resolver is not gated by that Xcode flag, and this repo has a
# Package.swift that pulls the same FluidAudio dependency. So resolve with it,
# then place the resulting Package.resolved where the generated workspace expects
# it, so Xcode Cloud's own resolve step finds a valid file and does not try (and
# fail) to resolve. Without this the archive fails at "Could not resolve package
# dependencies" before a single line of Swift is compiled.
echo "==> Resolving Swift packages via SwiftPM (FluidAudio)"
swift package resolve

RESOLVED_DIR="Dictator.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$RESOLVED_DIR"
cp Package.resolved "$RESOLVED_DIR/Package.resolved"
echo "==> Placed Package.resolved at $RESOLVED_DIR"

# Hedge: also re-enable Xcode's automatic package resolution for any later
# xcodebuild in this build, in case the copied file alone is not accepted. No-op
# if the key is not what this Xcode uses.
defaults write com.apple.dt.Xcode IDEDisableAutomaticPackageResolution -bool NO 2>/dev/null || true

echo "==> Done"
