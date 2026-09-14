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

# The API key never lives in the repository. It is an Xcode Cloud environment
# variable marked secret, and is written into the gitignored file the app expects.
echo "==> Writing Secrets.swift"
cat > Sources/DictationCore/Secrets.swift <<SWIFT
import Foundation

/// Generated at build time. Never committed.
enum BuildSecrets {
    static let groqAPIKey = "${GROQ_API_KEY}"
}
SWIFT

echo "==> Generating the Xcode project"
xcodegen generate

echo "==> Done"
