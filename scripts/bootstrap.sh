#!/bin/bash
# Prepares a fresh checkout for Xcode: fetches the ostt helper, generates the git-ignored
# JustTranscribe.xcodeproj and copies the committed package pins into it.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/fetch-ostt.sh
xcodegen generate
mkdir -p JustTranscribe.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Package.resolved JustTranscribe.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
