#!/bin/bash
# Assembles Hush.app. No Xcode project — TCC just needs a signed bundle
# with the usage-description keys.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
[ -f AppIcon.icns ] || swift make-icon.swift

# Version comes from the latest tag so a release can't ship claiming an old one.
VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)
VERSION=${VERSION:-0.0.0}
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)

APP="Hush.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Hush "$APP/Contents/MacOS/"
cp AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Hush</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.cryonayes.hush</string>
    <key>CFBundleName</key><string>Hush</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Hush taps app audio so it can play it back at the volume you choose.</string>
</dict>
</plist>
PLIST

codesign --force --sign - --identifier com.cryonayes.hush "$APP"

if [ "${1:-}" = "--install" ]; then
    # A running copy holds its own bundle open; replace it cleanly.
    pkill -f "/Hush.app/Contents/MacOS/Hush" 2>/dev/null || true
    rm -rf /Applications/Hush.app
    cp -R "$APP" /Applications/
    open /Applications/Hush.app
    echo "Installed to /Applications/Hush.app and launched."
else
    echo "Built $APP — run ./build.sh --install to put it in /Applications."
fi
