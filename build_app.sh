#!/bin/bash

set -euo pipefail
umask 077

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
UI_DIR="$REPO_DIR/ui"
BUILD_DIR="$REPO_DIR/build"
APP_DIR="$BUILD_DIR/Iron Turkey Locker.app"
ICON_SRC="$UI_DIR/Iron Turkey.icns"
SCRIPT_SRC="$UI_DIR/Iron Turkey Locker.applescript"
REVIEW_DIALOG_SRC="$UI_DIR/review_dialog.js"

rm -rf "$APP_DIR"
mkdir -p "$BUILD_DIR"

osacompile -o "$APP_DIR" "$SCRIPT_SRC"

cp "$ICON_SRC" "$APP_DIR/Contents/Resources/Iron Turkey.icns"
cp "$REVIEW_DIALOG_SRC" "$APP_DIR/Contents/Resources/review_dialog.js"

/usr/libexec/PlistBuddy -c "Set :CFBundleName Iron Turkey Locker" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Iron Turkey Locker" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.ironturkey.locker" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile Iron Turkey" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :LSUIElement" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true

echo "Built app bundle at: $APP_DIR"
