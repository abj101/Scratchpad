#!/bin/zsh
# Build the Debug app and (re)launch it.
# Usage: scripts/run.sh
set -e
cd "$(dirname "$0")/.."
xcodegen generate -q
if ! LOG=$(xcodebuild -scheme Scratchpad -derivedDataPath build build -quiet 2>&1); then
  echo "$LOG" | grep -E "\.swift:[0-9]+:[0-9]+: error:" >&2; exit 1
fi
pkill -x Scratchpad || true
while pgrep -x Scratchpad >/dev/null; do sleep 0.1; done
open build/Build/Products/Debug/Scratchpad.app
echo "Scratchpad (Debug) launched"
