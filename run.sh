#!/bin/zsh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Stable install location. The login item (SMAppService) points at this path,
# so it must survive rebuilds: the .build tree is wiped by `swift package
# clean` and its layout changes across Swift versions.
INSTALL_DIR="${LAUNCH_BUDDY_HOME:-$HOME/Applications}"

# Build
swift build
BIN_DIR="$(swift build --show-bin-path)"

# If a previous copy is still running, terminate it first so `open` below
# starts the freshly installed bundle. SIGTERM is caught by the app's signal
# guard, which kills the script's process group before exiting.
pkill -x LaunchBuddy 2>/dev/null || true
sleep 1
pkill -9 -x LaunchBuddy 2>/dev/null || true

# Stage the .app bundle in-tree (unsigned).
STAGING="$SCRIPT_DIR/.build/debug/LaunchBuddy.app"
rm -rf "$STAGING"
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources"
cp "$BIN_DIR/LaunchBuddy" "$STAGING/Contents/MacOS/"
cp "$SCRIPT_DIR/Sources/LaunchBuddy/Info.plist" "$STAGING/Contents/"
printf 'APPL????' > "$STAGING/Contents/PkgInfo"
[ -f "$SCRIPT_DIR/Sources/LaunchBuddy/AppIcon.icns" ] && \
    cp "$SCRIPT_DIR/Sources/LaunchBuddy/AppIcon.icns" "$STAGING/Contents/Resources/"

# Install into the stable location.
APP_DIR="$INSTALL_DIR/LaunchBuddy.app"
mkdir -p "$INSTALL_DIR"
rm -rf "$APP_DIR"
cp -R "$STAGING" "$APP_DIR"

# Ad-hoc signing gives the bundle a stable identity, which the login item
# API (SMAppService) needs to register. Re-signing a registered bundle is
# safe: the registration survives.
codesign --force --sign - "$APP_DIR"

# Launch
open "$APP_DIR"
echo "Launch Buddy installed to $APP_DIR — check your menu bar for the 🧠 icon."
