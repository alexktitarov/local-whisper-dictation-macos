#!/usr/bin/env bash
# Builds LocalWhisper.app, signs it with your Apple Development identity (so macOS
# remembers the Mic/Accessibility grants across rebuilds) and installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="LocalWhisper"
BUNDLE_ID="com.local.whisper"
APP="build/${APP_NAME}.app"
INSTALL_DIR="/Applications"

swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
# SwiftPM resource bundles from dependencies (tokenizer data etc.)
find "$BIN_DIR" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Local Whisper</string>
    <key>CFBundleDisplayName</key><string>Local Whisper</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Local Whisper records your voice while you hold the hotkey and transcribes it on-device.</string>
</dict>
</plist>
PLIST

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')}"
IDENTITY="${IDENTITY:--}"   # fall back to ad-hoc
echo "Signing with: $IDENTITY"
codesign --force --deep --sign "$IDENTITY" "$APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x "$APP_NAME" 2>/dev/null || true
    while pgrep -x "$APP_NAME" >/dev/null; do sleep 0.2; done
    rm -rf "$INSTALL_DIR/${APP_NAME}.app"
    cp -R "$APP" "$INSTALL_DIR/"
    echo "Installed to $INSTALL_DIR/${APP_NAME}.app"
    open "$INSTALL_DIR/${APP_NAME}.app"
else
    echo "Built $APP  (run ./build.sh --install to install + launch)"
fi
