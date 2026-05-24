#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "Building ClaudeSwitch (Debug)..."
xcodebuild -project ClaudeSwitch.xcodeproj \
    -scheme ClaudeSwitch \
    -configuration Debug \
    -derivedDataPath build \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | tail -20

echo ""
echo "Build complete. App at: build/Debug/ClaudeSwitch.app"
