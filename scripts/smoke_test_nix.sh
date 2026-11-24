#!/usr/bin/env bash
# Boot the ROM headless in mGBA (via shell.nix) and check it reaches the title screen.
# Usage: scripts/smoke_test_nix.sh [rom] [timeout_seconds]
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [ $# -ge 1 ]; then
  ROM=$(realpath -m "$1")
else
  ROM="$REPO_ROOT/emerogue.gba"
fi
TIMEOUT=${2:-60}

cd "$REPO_ROOT"
nix-shell --run "$(printf 'scripts/smoke_test.sh %q %q' "$ROM" "$TIMEOUT")"
