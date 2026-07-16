#!/usr/bin/env bash
#
# Capture App Store screenshots for Aura at 6.9" (iPhone 16 Pro Max, 1320x2868).
#
# PREREQUISITE: a Subsonic/Navidrome server with content that the app can reach.
# Run this AFTER the demo server is up — that way the screenshots show exactly
# what the App Review reviewer will see with the demo credentials.
#
# This script boots the simulator, builds+installs the Debug app, and launches it.
# You then navigate manually to each screen and press RETURN to capture it.
# (Manual navigation is intentional — automating deep-link taps is brittle and the
#  6-8 marketing shots need a human eye for framing/timing anyway.)
#
# Usage:  ./scripts/capture_appstore_screenshots.sh
#
set -euo pipefail

DEVICE_NAME="iPhone 16 Pro Max"
RUNTIME="iOS26.1"                      # adjust if your installed runtime differs
BUNDLE_ID="com.aura.goldian"
SCHEME="Aura"                          # Debug scheme is fine for screenshots
OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/appstore_screenshots"
DD="/tmp/aura_dd_screens"

mkdir -p "$OUT_DIR"

echo "==> Ensuring simulator '$DEVICE_NAME' exists…"
UDID=$(xcrun simctl list devices | grep "$DEVICE_NAME (" | grep -oE '[0-9A-F-]{36}' | head -1 || true)
if [ -z "${UDID:-}" ]; then
  echo "    Creating…"
  UDID=$(xcrun simctl create "$DEVICE_NAME" \
    "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro-Max" \
    "com.apple.CoreSimulator.SimRuntime.${RUNTIME}")
fi
echo "    UDID: $UDID"

echo "==> Booting…"
xcrun simctl boot "$UDID" 2>/dev/null || true
open -a Simulator
xcrun simctl bootstatus "$UDID" -b

echo "==> Building (Debug) + installing…"
xcrun xcodebuild build \
  -project Aura/Aura.xcodeproj \
  -scheme "$SCHEME" -configuration Debug \
  -destination "id=$UDID" -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO >/dev/null
xcrun simctl install "$UDID" "$DD/Build/Products/Debug-iphonesimulator/Aura.app"
xcrun simctl launch "$UDID" "$BUNDLE_ID"

echo ""
echo "==> App launched. Add your demo server, then capture each screen."
echo "    (status bar is auto-overridden to a clean 9:41 / full battery / wifi)"
xcrun simctl status_bar "$UDID" override \
  --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularMode active --wifiBars 3 --cellularBars 4 2>/dev/null || true

SHOTS=( \
  "01_home"        "02_now_playing" "03_lyrics" "04_queue" \
  "05_instant_mix" "06_search"      "07_settings_eq" "08_offline" )

for name in "${SHOTS[@]}"; do
  read -r -p "  → Navigate to '$name' then press RETURN to capture (or 's' to skip)… " ans
  [ "$ans" = "s" ] && { echo "     skipped"; continue; }
  xcrun simctl io "$UDID" screenshot "$OUT_DIR/${name}.png"
  echo "     saved $OUT_DIR/${name}.png"
done

echo ""
echo "==> Done. Screenshots in: $OUT_DIR"
echo "    Verify each is 1320x2868 (6.9\") before uploading to App Store Connect:"
echo "    sips -g pixelWidth -g pixelHeight $OUT_DIR/*.png"
