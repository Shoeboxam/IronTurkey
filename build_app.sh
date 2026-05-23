#!/bin/bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
UI_DIR="$REPO_DIR/ui"
BUILD_DIR="$REPO_DIR/build"
APP_DIR="$BUILD_DIR/Frozen Turkey Locker.app"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
"http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Frozen Turkey Locker</string>
    <key>CFBundleIconFile</key>
    <string>Frozen Turkey</string>
    <key>CFBundleIdentifier</key>
    <string>local.frozenturkey.locker</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Frozen Turkey Locker</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

cat > "$APP_DIR/Contents/MacOS/Frozen Turkey Locker" <<'SH'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")/../Resources" && pwd)"
exec osascript "$SCRIPT_DIR/Frozen Turkey Locker.applescript"
SH

chmod +x "$APP_DIR/Contents/MacOS/Frozen Turkey Locker"

cp "$UI_DIR/Frozen Turkey Locker.applescript" "$APP_DIR/Contents/Resources/Frozen Turkey Locker.applescript"
cp "$UI_DIR/Frozen Turkey.icns" "$APP_DIR/Contents/Resources/Frozen Turkey.icns"

echo "Built app bundle at: $APP_DIR"
