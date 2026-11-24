#!/usr/bin/env bash
# Boot the ROM headless in mGBA (via shell.nix) and check it reaches the title screen.
# Usage: scripts/smoke_test_nix.sh [rom] [timeout_seconds]
set -euo pipefail
cd "$(dirname "$0")/.."

ROM=${1:-emerogue.gba}
TIMEOUT=${2:-60}

nix-shell --run "$(printf 'scripts/smoke_test.sh %q %q' "$ROM" "$TIMEOUT")"
