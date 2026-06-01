#!/bin/zsh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build/arm64-apple-macosx/debug"
APP_DIR="$SCRIPT_DIR/.build/debug/LaunchBuddy.app"

# Build
swift build

# Create .app bundle
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/LaunchBuddy" "$APP_DIR/Contents/MacOS/"
cp "$SCRIPT_DIR/Sources/LaunchBuddy/Info.plist" "$APP_DIR/Contents/"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

# Launch
open "$APP_DIR"
echo "Launch Buddy started — check your menu bar for the 🧠 icon."
