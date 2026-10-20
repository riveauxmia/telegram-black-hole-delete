#!/usr/bin/env bash
# Builds and runs the UIKit demo in the iOS Simulator without an Xcode project:
#   Demo/build-demo.sh ["iPhone 18 Pro"]
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE="${1:-iPhone 18 Pro}"
OUT="${OUT:-build}"
APP="$OUT/BlackHoleDeleteDemo.app"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
ARCH="$(uname -m)"
rm -rf "$APP" && mkdir -p "$APP"

xcrun -sdk iphonesimulator metal -c BlackHoleDelete/Resources/BlackHole.metal -o "$OUT/BlackHole.air"
xcrun -sdk iphonesimulator metallib "$OUT/BlackHole.air" -o "$APP/default.metallib"
xcrun -sdk iphonesimulator swiftc -O -parse-as-library -module-name BlackHoleDeleteDemo -target "$ARCH-apple-ios17.0-simulator" -sdk "$SDK" \
  BlackHoleDelete/Sources/BlackHoleTimeline.swift BlackHoleDelete/Sources/BlackHoleDeleteAnimator.swift \
  Demo/DemoViewController.swift -o "$APP/BlackHoleDeleteDemo"
cp BlackHoleDelete/Resources/BlackHoleDisk.png "$APP/"
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>demo.blackholedelete.kit</string>
  <key>CFBundleExecutable</key><string>BlackHoleDeleteDemo</string>
  <key>CFBundleName</key><string>BlackHoleDelete</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>17.0</string>
  <key>UIDeviceFamily</key><array><integer>1</integer></array>
  <key>UILaunchScreen</key><dict/>
  <key>UIViewControllerBasedStatusBarAppearance</key><true/>
  <key>UIApplicationSceneManifest</key><dict>
    <key>UIApplicationSupportsMultipleScenes</key><false/>
  </dict>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch --terminate-running-process "$DEVICE" demo.blackholedelete.kit
