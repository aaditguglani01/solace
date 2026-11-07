#!/bin/bash
cd "$(dirname "$0")"
LOG="build.log"
{
echo "=== $(date) ==="
sw_vers
uname -m
if ! xcode-select -p >/dev/null 2>&1; then
  echo "NO_DEV_TOOLS — opening Apple's installer. Click Install, then double-click this file again when done."
  xcode-select --install
  exit 0
fi
echo "Dev tools: $(xcode-select -p)"
swift --version
./build.sh
echo "EXIT=$?"
} 2>&1 | tee "$LOG"
echo
echo "Finished. You can close this window."
