#!/usr/bin/env bash
# Boot the ROM headless in mGBA (with blank flash) and check it reaches the title screen.
# Usage: scripts/smoke_test.sh [rom] [timeout_seconds]
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
ROM=${1:-"$REPO_ROOT/emerogue.gba"}
TIMEOUT=${2:-60}
MAP=${ROM%.gba}.map

if [ ! -f "$ROM" ]; then
  echo "FAIL: ROM not found: $ROM"
  exit 1
fi

if [ ! -f "$MAP" ]; then
  echo "FAIL: Linker map not found: $MAP"
  exit 1
fi

MGBA=""
for candidate in mgba /usr/games/mgba mgba-sdl /usr/games/mgba-sdl; do
  if command -v "$candidate" >/dev/null 2>&1; then
    MGBA=$(command -v "$candidate")
    break
  fi
done

if [ -z "$MGBA" ]; then
  echo "FAIL: mGBA executable not found in PATH or /usr/games"
  exit 1
fi

ADDR=$(awk '$2 == "CB2_InitTitleScreen" { print $1; exit }' "$MAP")
if [ -z "$ADDR" ]; then
  echo "FAIL: CB2_InitTitleScreen not found in $MAP"
  exit 1
fi

# Boot a temp copy so any adjacent .sav next to the ROM cannot affect the test.
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
TMP_ROM="$TMPDIR/$(basename "$ROM")"
cp "$ROM" "$TMP_ROM"

# mGBA's CLI debugger: break on the title screen, run, and quit once it's hit.
if OUT=$(printf 'break %s\ncontinue\nquit\n' "$ADDR" |
  SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy timeout --kill-after=5s -- "$TIMEOUT" "$MGBA" -d "$TMP_ROM" 2>&1); then
  :
else
  status=$?
  if [ "$status" -eq 124 ]; then
    echo "FAIL: mGBA timed out after ${TIMEOUT}s waiting for title screen"
  else
    echo "FAIL: mGBA exited with status $status"
  fi
  tail -20 <<<"$OUT"
  exit 1
fi

if grep -q "Hit breakpoint" <<<"$OUT"; then
  echo "PASS: $ROM reached the title screen (CB2_InitTitleScreen @ $ADDR)"
else
  echo "FAIL: $ROM exited before hitting CB2_InitTitleScreen @ $ADDR"
  tail -20 <<<"$OUT"
  exit 1
fi
