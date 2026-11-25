#!/usr/bin/env bash
# Boot the ROM headless in mGBA (with blank flash & isolated config) and check it reaches the interactive title screen.
# Usage: scripts/smoke_test.sh [rom] [timeout_seconds]
set -euo pipefail

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
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

ELF=${ROM%.[gG][bB][aA]}.elf
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

for tool in arm-none-eabi-nm arm-none-eabi-objcopy; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "FAIL: $tool not found in PATH"
    exit 1
  fi
done

ADDR=$(arm-none-eabi-nm -- "$ELF" | awk -v symbol="$MILESTONE" '!found && $3 == symbol { print "0x" $1; found = 1 }')
if [ -z "$ADDR" ]; then
  echo "FAIL: $MILESTONE not found in $ELF"
  exit 1
fi
ADDR_HEX=$(printf '%x' "$ADDR")

# Boot a temp copy with isolated XDG config and savegamePath so user config/saves cannot affect the test.
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
TMP_ROM="$TMPDIR/$(basename -- "$ROM")"
cp -- "$ROM" "$TMP_ROM"

# Verify the ROM matches the ELF's binary image (either raw or padded via gbafix -p).
ELF_ROM=$(mktemp "$TMPDIR/elf-rom.XXXXXXXX")
if ! arm-none-eabi-objcopy -O binary -- "$ELF" "$ELF_ROM"; then
  echo "FAIL: could not extract ROM image from $ELF"
  exit 1
fi
GBAFIX=${GBAFIX:-"$REPO_ROOT/tools/gbafix/gbafix"}
if [ ! -s "$ELF_ROM" ]; then
  echo "FAIL: extracted ROM image is empty: $ELF"
  exit 1
fi
if ! cmp -s -- "$ELF_ROM" "$TMP_ROM"; then
  if ! cmp -s -n "$(wc -c < "$ELF_ROM")" -- "$ELF_ROM" "$TMP_ROM"; then
    echo "FAIL: ROM does not match ELF: $ROM and $ELF"
    exit 1
  fi
  if [ ! -x "$GBAFIX" ]; then
    echo "FAIL: cannot verify ROM padding: gbafix is not executable at $GBAFIX"
    exit 1
  fi
  if ! "$GBAFIX" "$ELF_ROM" -p --silent; then
    echo "FAIL: gbafix could not pad the ROM image extracted from $ELF"
    exit 1
  fi
  if ! cmp -s -- "$ELF_ROM" "$TMP_ROM"; then
    echo "FAIL: ROM does not match ELF: $ROM and $ELF"
    exit 1
  fi
fi

# mGBA's CLI debugger: break once the title screen is ready for input, run, and quit once hit.
if OUT=$(printf 'break %s\ncontinue\nquit\n' "$ADDR" |
  XDG_CONFIG_HOME="$TMPDIR" SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
    timeout --kill-after=5s -- "$TIMEOUT" "$MGBA" -C "savegamePath=$TMPDIR" -d "$TMP_ROM" 2>&1); then
  :
else
  status=$?
  if [ "$status" -eq 124 ]; then
    echo "FAIL: mGBA timed out after ${TIMEOUT}s waiting for $MILESTONE"
  elif [ "$status" -eq 137 ]; then
    echo "FAIL: mGBA was killed by SIGKILL while waiting for $MILESTONE (timeout escalation or external kill)"
  else
    echo "FAIL: mGBA exited with status $status"
  fi
  tail -20 <<<"$OUT"
  exit 1
fi

if grep -Eiq "^[[:blank:]]*(>[[:blank:]]*)?Hit breakpoint( [0-9]+)? at 0x0*${ADDR_HEX}([^[:xdigit:]]|$)" <<<"$OUT"; then
  echo "PASS: $ROM reached the title screen ($MILESTONE @ $ADDR)"
else
  echo "FAIL: $ROM exited before hitting $MILESTONE @ $ADDR"
  tail -20 <<<"$OUT"
  exit 1
fi
