#!/bin/bash
# Assembles VolumeMixer.app. No Xcode project — TCC just needs a signed bundle
# with the usage-description keys.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
[ -f AppIcon.icns ] || swift make-icon.swift

APP="VolumeMixer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/VolumeMixer "$APP/Contents/MacOS/"
cp AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>VolumeMixer</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>local.volumemixer</string>
    <key>CFBundleName</key><string>Volume Mixer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>14.2</string>
    <key>LSUIElement</key><true/>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Volume Mixer taps app audio so it can play it back at your chosen volume.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Volume Mixer taps app audio so it can play it back at your chosen volume.</string>
</dict>
</plist>
PLIST

codesign --force --sign - --identifier local.volumemixer "$APP"
echo "Built $APP — open it, then look for the slider icon in the menu bar."
