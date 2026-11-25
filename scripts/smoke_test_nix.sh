#!/usr/bin/env bash
# Boot the ROM headless in mGBA (via shell.nix) and check it reaches the interactive title screen.
# Usage: scripts/smoke_test_nix.sh [rom] [timeout_seconds]
set -euo pipefail

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
if [ -n "${1:-}" ]; then
  case "$1" in
    /*) ROM=$1 ;;
    *) ROM="$REPO_ROOT/$1" ;;
  esac
else
  ROM="$REPO_ROOT/emerogue.gba"
fi
TIMEOUT=${2:-60}

cd -- "$REPO_ROOT"
nix-shell --run "$(printf 'scripts/smoke_test.sh %q %q' "$ROM" "$TIMEOUT")"
