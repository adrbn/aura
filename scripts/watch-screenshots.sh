#!/bin/bash
# Pictures of the watch app, drawn on this Mac — no watch, no simulator.
#
#   scripts/watch-screenshots.sh [out.png]
#
# The watch app's real pages are compiled for macOS next to a few stand-ins
# (scripts/watch-screenshots/Shims.swift): a model holding made-up data instead of
# WatchConnectivity, and the look watchOS gives lists, buttons and the Crown's volume ring.
# Text styles are set to the watch's sizes in SF Compact. A close likeness, not a capture:
# spacing the watch decides for itself (list rows, safe areas) is approximated.
set -euo pipefail

OUT="${1:-${TMPDIR:-/tmp}/aura-watch.png}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
cd "$(dirname "$0")/.."
WORK="${TMPDIR:-/tmp}/aura-watch-shots"
rm -rf "$WORK" && mkdir -p "$WORK"

cp Aura/AuraWatch/WatchProtocol.swift Aura/AuraWatch/Backdrop.swift Aura/Aura/Components/MarqueeText.swift \
   Aura/Aura/Components/DayGlow.swift scripts/watch-screenshots/Shims.swift scripts/watch-screenshots/main.swift "$WORK/"

# The pages, with what only a watch has taken out and the watch's type sizes put in.
python3 - "$WORK" Aura/AuraWatch/NowPlayingPage.swift Aura/AuraWatch/LyricsPage.swift \
  Aura/AuraWatch/UpNextPage.swift Aura/AuraWatch/LibraryPage.swift <<'PY'
import re, sys, os
work, *pages = sys.argv[1:]
sizes = {"headline": "17, .semibold", "footnote": "14", "title3": "20", "title2": "22"}
for page in pages:
    s = open(page).read().replace("import WatchKit\n", "")
    s = re.sub(r"(?:Font)?\.system\(size: (\d+), weight: \.(\w+)\)", r"compact(\1, .\2)", s)
    s = re.sub(r"(?:Font)?\.system\(size: (\w+)\)", r"compact(\1)", s)
    s = re.sub(r"(font: |\.font\()\.(%s)\b" % "|".join(sizes), lambda m: m.group(1) + "compact(%s)" % sizes[m.group(2)], s)
    # Liquid Glass renders only on screen; the shims draw a likeness of it.
    s = re.sub(r"\.glassEffect\([^)]*\), in: \.circle\)", ".harnessGlass(in: Circle())", s)
    s = s.replace(".buttonStyle(.glassProminent)", ".buttonStyle(HarnessProminent())")
    s = s.replace(".buttonStyle(.glass)", ".buttonStyle(HarnessGlassButton())")
    open(os.path.join(work, os.path.basename(page)), "w").write(s)
PY

xcrun swiftc -target "$(uname -m)-apple-macos26" -o "$WORK/render" "$WORK"/*.swift
"$WORK/render" "$OUT" "$PWD"
