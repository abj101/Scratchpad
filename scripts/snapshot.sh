#!/bin/zsh
# Build, relaunch, and screenshot the Scratchpad window.
# Needs Screen Recording permission for the calling app.
# Usage: scripts/snapshot.sh [out.png]
set -e
cd "$(dirname "$0")/.."
OUT="${1:-$PWD/build/snapshot.png}"
xcodegen generate -q
if ! LOG=$(xcodebuild -scheme Scratchpad -derivedDataPath build build -quiet 2>&1); then
  echo "$LOG" | grep -E "\.swift:[0-9]+:[0-9]+: error:" >&2; exit 1
fi
pkill -x Scratchpad || true
while pgrep -x Scratchpad >/dev/null; do sleep 0.1; done
open build/Build/Products/Debug/Scratchpad.app
sleep 2.5
ID=$(swift scripts/winid.swift Scratchpad)
screencapture -x -o -l"$ID" "$OUT"
echo "$OUT"
