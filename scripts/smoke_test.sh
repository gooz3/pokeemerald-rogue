#!/usr/bin/env bash
# Boot the ROM headless in mGBA (with blank flash) and check it reaches the interactive title screen.
# Usage: scripts/smoke_test.sh [rom] [timeout_seconds]
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
ROM=${1:-"$REPO_ROOT/emerogue.gba"}
case "$ROM" in
  /*) ;;
  *) ROM="$PWD/$ROM" ;;
esac

TIMEOUT=${2:-60}
if ! [[ "$TIMEOUT" =~ ^0*[1-9][0-9]*$ ]]; then
  echo "FAIL: timeout must be a positive integer number of seconds"
  exit 1
fi

ELF=${ROM%.gba}.elf
MILESTONE=Task_TitleScreenPhase3

if [ ! -f "$ROM" ]; then
  echo "FAIL: ROM not found: $ROM"
  exit 1
fi

if [ ! -f "$ELF" ]; then
  echo "FAIL: ELF not found: $ELF"
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

if ! command -v arm-none-eabi-nm >/dev/null 2>&1; then
  echo "FAIL: arm-none-eabi-nm not found in PATH"
  exit 1
fi

ADDR=$(arm-none-eabi-nm -- "$ELF" | awk -v symbol="$MILESTONE" '!found && $3 == symbol { print "0x" $1; found = 1 }')
if [ -z "$ADDR" ]; then
  echo "FAIL: $MILESTONE not found in $ELF"
  exit 1
fi

# Boot a temp copy with savegamePath pointed at TMPDIR so local saves cannot affect the test.
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
TMP_ROM="$TMPDIR/$(basename -- "$ROM")"
cp -- "$ROM" "$TMP_ROM"

# mGBA's CLI debugger: break once the title screen is ready for input, run, and quit once hit.
if OUT=$(printf 'break %s\ncontinue\nquit\n' "$ADDR" |
  SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy timeout --kill-after=5s -- "$TIMEOUT" "$MGBA" -C "savegamePath=$TMPDIR" -d "$TMP_ROM" 2>&1); then
  :
else
  status=$?
  if [ "$status" -eq 124 ]; then
    echo "FAIL: mGBA timed out after ${TIMEOUT}s waiting for $MILESTONE"
  else
    echo "FAIL: mGBA exited with status $status"
  fi
  tail -20 <<<"$OUT"
  exit 1
fi

if grep -q "Hit breakpoint" <<<"$OUT"; then
  echo "PASS: $ROM reached the title screen ($MILESTONE @ $ADDR)"
else
  echo "FAIL: $ROM exited before hitting $MILESTONE @ $ADDR"
  tail -20 <<<"$OUT"
  exit 1
fi
