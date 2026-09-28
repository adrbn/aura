#!/bin/bash
# Publishes a build the iPhone can install from anywhere — cellular included.
#
# No cable, no shared Wi-Fi, no Xcode on the phone's side: the .ipa is served over
# HTTPS on the tailnet, and iOS installs it through its own over-the-air mechanism
# (itms-services). All the phone needs is Tailscale switched on.
#
# devicectl can't do this: it only reaches a device it found over Bonjour on the local
# link, and iOS only listens for it on Wi-Fi. See docs/OTA.md.
#
# Local settings in scripts/ota.env (not versioned — personal infrastructure):
#   AURA_OTA_HOST  tailnet name of the serving machine (e.g. server.example.ts.net)
#   AURA_OTA_SSH   ssh target for that machine (e.g. root@server.example.ts.net)
#   AURA_OTA_DIR   directory served on that machine (default /opt/aura-ota)
#   DEVELOPER_DIR  optional — which Xcode builds it
#
# --here serves the build from this Mac instead, for as long as the script runs (Ctrl-C
# once installed): nothing is written to the server or kept in Tailscale's settings. The
# Mac has to stay awake until the phone has downloaded it.
set -euo pipefail

cd "$(dirname "$0")/.."
if [ -f scripts/ota.env ]; then set -a; . scripts/ota.env; set +a; fi
HERE=false
[ "${1:-}" = "--here" ] && HERE=true
if $HERE; then
  TS=$(command -v tailscale || echo /Applications/Tailscale.app/Contents/MacOS/Tailscale)
  PORT="${AURA_OTA_PORT:-8446}"
  HOST="$("$TS" status --json | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))'):$PORT"
else
  HOST="${AURA_OTA_HOST:?set AURA_OTA_HOST in scripts/ota.env}"
  TARGET="${AURA_OTA_SSH:?set AURA_OTA_SSH in scripts/ota.env}"
  DIR="${AURA_OTA_DIR:-/opt/aura-ota}"
fi
BASE="https://$HOST/aura"

WORK="${TMPDIR:-/tmp}/aura-ota"
ARCHIVE="$WORK/Aura.xcarchive"
EXPORT="$WORK/export"
STAGE="$WORK/stage"
LOG="$WORK/xcodebuild.log"

rm -rf "$WORK"
mkdir -p "$EXPORT" "$STAGE"

cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>debugging</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
  <key>stripSwiftSymbols</key><true/>
  <key>manifest</key><dict>
    <key>appURL</key><string>$BASE/Aura.ipa</string>
    <key>displayImageURL</key><string>$BASE/icon-57.png</string>
    <key>fullSizeImageURL</key><string>$BASE/icon-512.png</string>
  </dict>
</dict></plist>
PLIST

# The full xcodebuild output goes to a log; only its end is shown, and only on failure.
xcode() {
  xcodebuild "$@" >>"$LOG" 2>&1 || { tail -30 "$LOG" >&2; echo "FAILED — full log: $LOG" >&2; exit 1; }
}

echo "→ archive"
xcode archive -project Aura/Aura.xcodeproj -scheme Aura \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" -allowProvisioningUpdates

echo "→ export"
xcode -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$WORK/ExportOptions.plist" -exportPath "$EXPORT" \
  -allowProvisioningUpdates

VERSION=$(/usr/libexec/PlistBuddy -c \
  'Print :ApplicationProperties:CFBundleShortVersionString' "$ARCHIVE/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c \
  'Print :ApplicationProperties:CFBundleVersion' "$ARCHIVE/Info.plist")
COMMIT=$(git rev-parse --short HEAD)$(git diff --quiet HEAD -- Aura || echo "+")

cp "$EXPORT/Aura.ipa" "$EXPORT/manifest.plist" "$STAGE/"
ICON=aura-iOS-Default-1024x1024@1x.png
sips -Z 512 "$ICON" --out "$STAGE/icon-512.png" >/dev/null
sips -Z 57  "$ICON" --out "$STAGE/icon-57.png"  >/dev/null

cat > "$STAGE/index.html" <<HTML
<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Aura $VERSION ($BUILD)</title>
<style>
 :root{color-scheme:dark}
 body{font:17px/1.5 -apple-system,system-ui,sans-serif;margin:0;min-height:100vh;
      display:grid;place-content:center;gap:22px;text-align:center;padding:24px;
      background:#121212;color:#fff}
 img{width:96px;height:96px;border-radius:22px;justify-self:center}
 a{display:inline-block;padding:14px 30px;border-radius:14px;background:#fff;
   color:#121212;text-decoration:none;font-weight:600}
 p{color:#888;margin:0;font-size:15px}
</style>
<img src="icon-512.png" alt="">
<div><strong>Aura $VERSION</strong><br><p>build $BUILD · $COMMIT · $(date '+%d %b %H:%M')</p></div>
<a href="itms-services://?action=download-manifest&amp;url=$BASE/manifest.plist">Install</a>
<p>Then open Aura once, so Siri and Shortcuts find it again.</p>
</html>
HTML

if $HERE; then
  # The App Store build of Tailscale can't serve a folder, only proxy a port, so a
  # local server holds the files. Explicit types: iOS reads the manifest as XML.
  mkdir -p "$WORK/www" && ln -s "$STAGE" "$WORK/www/aura"
  python3 - "$WORK/www" <<'PY' &
import functools, http.server, sys
class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map,
                      ".plist": "text/xml", ".ipa": "application/octet-stream"}
http.server.ThreadingHTTPServer(("127.0.0.1", 8765),
    functools.partial(Handler, directory=sys.argv[1])).serve_forever()
PY
  SERVER=$!
  trap 'kill $SERVER 2>/dev/null' EXIT
  echo
  echo "Aura $VERSION (build $BUILD, $COMMIT) — $BASE/"
  echo "On the phone, Tailscale on, any network: open that link, tap Install, then open"
  echo "Aura once. Served from this Mac until Ctrl-C; keep it awake until then."
  "$TS" serve --https="$PORT" http://127.0.0.1:8765
  exit 0
fi

echo "→ upload to $TARGET:$DIR"
ssh -o ConnectTimeout=20 "$TARGET" "mkdir -p '$DIR'"
scp -q "$STAGE"/Aura.ipa "$STAGE"/manifest.plist "$STAGE"/icon-512.png \
       "$STAGE"/icon-57.png "$STAGE"/index.html "$TARGET:$DIR/"
ssh "$TARGET" "tailscale serve --bg --set-path /aura '$DIR'" >/dev/null

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$BASE/manifest.plist")
[ "$code" = 200 ] || { echo "FAILED: the manifest answers $code" >&2; exit 1; }

echo
echo "Aura $VERSION (build $BUILD, $COMMIT) published — $BASE/"
echo "On the phone, Tailscale on, any network: open that link, tap Install,"
echo "then open Aura once."
