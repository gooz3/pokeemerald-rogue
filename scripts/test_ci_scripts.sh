#!/usr/bin/env bash
# Fast unit tests for CI helper scripts (memory_report.py and smoke_test.sh).
set -euo pipefail

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- 1. memory_report.py: wrapped section + RAM section loaded from ROM + gate fail ---
MAP="$TMPDIR/fixture.map"
cat > "$MAP" <<'EOF'
Memory Configuration

Name             Origin             Length             Attributes
EWRAM            0x02000000         0x00040000         xrw
IWRAM            0x03000000         0x00008000         xrw
ROM              0x08000000         0x02000000         xr
*default*        0x00000000         0xffffffff

Linker script and memory map

ewram           0x02000000    0x00020000
iwram           0x03000000    0x00004000
.text           0x08000000    0x01000000
.very_long_wrapped_section_name
                0x08100000    0x01000000
.ram_loaded_from_rom
                0x02020000    0x00010000 load address 0x09e00000
EOF

# Expected high-water marks:
# - EWRAM: 0x00030000 / 0x00040000 = 75.00%
# - IWRAM: (0x00004000 + 0x1c0) / 0x00008000 = 51.37%
# - ROM:   (0x09e00000 + 0x00010000 - 0x08000000) / 0x02000000 = 0x01e10000 / 0x02000000 = 93.95%
OUT=$(python3 "$REPO_ROOT/scripts/memory_report.py" "$MAP" --label "Fixture" \
  --max-ewram-pct 80 --max-iwram-pct 60 --max-rom-pct 95)

grep -q '| `EWRAM` |.*\*\*75\.00%\*\*.*| PASS |' <<<"$OUT" || { echo "FAIL: EWRAM mismatch"; echo "$OUT"; exit 1; }
grep -q '| `IWRAM` |.*\*\*51\.37%\*\*.*| PASS |' <<<"$OUT" || { echo "FAIL: IWRAM mismatch"; echo "$OUT"; exit 1; }
grep -q '| `ROM` |.*\*\*93\.95%\*\*.*| PASS |' <<<"$OUT" || { echo "FAIL: ROM load-address mismatch"; echo "$OUT"; exit 1; }

if python3 "$REPO_ROOT/scripts/memory_report.py" "$MAP" --max-rom-pct 93.9 >/dev/null 2>&1; then
  echo "FAIL: memory_report.py should have failed when ROM (93.95%) > 93.9%"
  exit 1
fi

# --- 2. smoke_test.sh: stub mGBA wrong breakpoint address (fail) vs matching address (pass) ---
STUB_BIN="$TMPDIR/bin"
mkdir -p "$STUB_BIN"

cat > "$STUB_BIN/arm-none-eabi-nm" <<'EOF'
#!/usr/bin/env bash
echo "0820bdb0 t Task_TitleScreenPhase3"
EOF

cat > "$STUB_BIN/arm-none-eabi-objcopy" <<'EOF'
#!/usr/bin/env bash
# Usage: arm-none-eabi-objcopy -O binary -- <elf> <out>
cp -- "$4" "$5"
EOF

cat > "$STUB_BIN/mgba" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo "Hit breakpoint 1 at ${STUB_HIT_ADDR}"
exit 0
EOF

chmod +x "$STUB_BIN/arm-none-eabi-nm" "$STUB_BIN/arm-none-eabi-objcopy" "$STUB_BIN/mgba"

printf 'FAKE_ROM_BYTES' > "$TMPDIR/test.gba"
cp "$TMPDIR/test.gba" "$TMPDIR/test.elf"

if PATH="$STUB_BIN:$PATH" STUB_HIT_ADDR="0x08001234" "$REPO_ROOT/scripts/smoke_test.sh" "$TMPDIR/test.gba" 10 >/dev/null 2>&1; then
  echo "FAIL: smoke_test.sh should reject breakpoint hit at wrong address"
  exit 1
fi

if ! PATH="$STUB_BIN:$PATH" STUB_HIT_ADDR="0x0820BDB0" "$REPO_ROOT/scripts/smoke_test.sh" "$TMPDIR/test.gba" 10 >/dev/null 2>&1; then
  echo "FAIL: smoke_test.sh should accept breakpoint hit at matching address"
  exit 1
fi

echo "PASS: CI helper script tests"
