#!/usr/bin/env bash
# Boot the ROM headless in mGBA and check it reaches the title screen.
# Usage: scripts/smoke_test.sh [rom] [timeout_seconds]
set -euo pipefail
cd "$(dirname "$0")/.."

ROM=${1:-emerogue.gba}
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

# mGBA's CLI debugger: break on the title screen, run, and quit once it's hit.
OUT=$(printf 'break %s\ncontinue\nquit\n' "$ADDR" |
  SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy timeout "$TIMEOUT" "$MGBA" -d "$ROM" 2>&1 || true)

if grep -q "Hit breakpoint" <<<"$OUT"; then
  echo "PASS: $ROM reached the title screen (CB2_InitTitleScreen @ $ADDR)"
else
  echo "FAIL: $ROM did not reach the title screen within ${TIMEOUT}s"
  tail -20 <<<"$OUT"
  exit 1
fi
