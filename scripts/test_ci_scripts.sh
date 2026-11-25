#!/usr/bin/env bash
# Fast unit tests for CI helper scripts (memory_report.py and smoke_test.sh).
set -euo pipefail

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- 1. memory_report.py: wrapped IWRAM section + initialized RAM data + NOLOAD with ROM LMA + gate fail ---
MAP="$TMPDIR/fixture.map"
ELF="$TMPDIR/fixture.elf"
cat > "$MAP" <<'EOF'
Memory Configuration

Name             Origin             Length             Attributes
EWRAM            0x02000000         0x00040000         xrw
IWRAM            0x03000000         0x00008000         xrw
ROM              0x08000000         0x02000000         xr
*default*        0x00000000         0xffffffff

Linker script and memory map

ewram           0x02000000    0x00020000
iwram           0x03000000    0x00002000
.very_long_wrapped_section_name
                0x03002000    0x00002000
.text           0x08000000    0x01000000
.ram_loaded_from_rom
                0x02020000    0x00010000 load address 0x09e00000
.ram_noload_with_rom_lma
                0x02030000    0x00008000 load address 0x09f00000
EOF

python3 - "$ELF" <<'PY'
import pathlib, struct, sys

# Minimal valid 32-bit little-endian ELF with three PT_LOAD segments:
# 1. .text in ROM (file-backed)
# 2. .ram_loaded_from_rom: EWRAM VMA, ROM LMA 0x09e00000, file-backed 0x10000 -> counts in ROM
# 3. .ram_noload_with_rom_lma: EWRAM VMA, ROM LMA 0x09f00000, filesz 0, memsz 0x8000 -> ignored for ROM
phdrs = [
    (1, 0x100, 0x08000000, 0x08000000, 0x01000000, 0x01000000, 5, 4),
    (1, 0x01000100, 0x02020000, 0x09E00000, 0x00010000, 0x00010000, 6, 4),
    (1, 0, 0x02030000, 0x09F00000, 0x00000000, 0x00008000, 6, 4),
]
e_ident = b"\x7fELF\x01\x01\x01" + b"\x00" * 9
ehdr = e_ident + struct.pack("<HHIIIIIHHHHHH", 2, 40, 1, 0x08000000, 52, 0, 0, 52, 32, len(phdrs), 0, 0, 0)
body = b"".join(struct.pack("<IIIIIIII", *p) for p in phdrs)
file_size = max(p[1] + p[4] for p in phdrs if p[4])
with pathlib.Path(sys.argv[1]).open("wb") as fixture:
    fixture.write(ehdr + body)
    fixture.truncate(file_size)
with pathlib.Path(sys.argv[1]).with_name("truncated.elf").open("wb") as fixture:
    fixture.write(ehdr + body)
    fixture.truncate(file_size - 1)
PY

status=0
OUT=$(python3 "$REPO_ROOT/scripts/memory_report.py" "$MAP" --elf "$TMPDIR/truncated.elf" 2>&1) || status=$?
if [ "$status" -ne 1 ] || ! grep -q 'Truncated PT_LOAD segment' <<<"$OUT"; then
  echo "FAIL: expected truncated ELF payload to be rejected"
  echo "$OUT"
  exit 1
fi

# Expected high-water marks:
# - EWRAM: 0x00038000 / 0x00040000 = 87.50% (includes NOLOAD section)
# - IWRAM: (0x00004000 + 0x1c0) / 0x00008000 = 51.37% (includes wrapped section)
# - ROM:   (0x09e00000 + 0x00010000 - 0x08000000) / 0x02000000 = 93.95% (excludes NOLOAD ROM LMA 0x09f00000)
OUT=$(python3 "$REPO_ROOT/scripts/memory_report.py" "$MAP" --label "Fixture" \
  --max-ewram-pct 90 --max-iwram-pct 60 --max-rom-pct 95)

grep -q "| \`EWRAM\` |.*\\*\\*87\\.50%\\*\\*.*| PASS |" <<<"$OUT" || { echo "FAIL: EWRAM mismatch"; echo "$OUT"; exit 1; }
grep -q "| \`IWRAM\` |.*\\*\\*51\\.37%\\*\\*.*| PASS |" <<<"$OUT" || { echo "FAIL: IWRAM mismatch"; echo "$OUT"; exit 1; }
grep -q "| \`ROM\` |.*\\*\\*93\\.95%\\*\\*.*| PASS |" <<<"$OUT" || { echo "FAIL: ROM load-address mismatch"; echo "$OUT"; exit 1; }

status=0
OUT=$(python3 "$REPO_ROOT/scripts/memory_report.py" "$MAP" --max-rom-pct 93.9 2>&1) || status=$?
if [ "$status" -ne 1 ] || ! grep -q "| \`ROM\` |.*| FAIL |" <<<"$OUT"; then
  echo "FAIL: expected a ROM headroom failure (exit 1) when 93.95% > 93.9%"
  echo "$OUT"
  exit 1
fi

: > "$TMPDIR/empty.map"
cp "$ELF" "$TMPDIR/empty.elf"
status=0
OUT=$(python3 "$REPO_ROOT/scripts/memory_report.py" "$TMPDIR/empty.map" 2>&1) || status=$?
if [ "$status" -ne 1 ] || ! grep -q '^FAIL: Could not read memory usage from ' <<<"$OUT"; then
  echo "FAIL: expected clean FAIL message (exit 1) for empty map"
  echo "$OUT"
  exit 1
fi

# --- 2. smoke_test.sh: ELF match, gbafix -p fallback, debugger commands, timeout, exit status ---
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

cat > "$STUB_BIN/gbafix" <<'EOF'
#!/usr/bin/env bash
if [ "$#" -ne 3 ] || [ "$2" != "-p" ] || [ "$3" != "--silent" ]; then
  printf 'Unexpected gbafix args: %s\n' "$*" >&2
  exit 1
fi
printf 'PADDING' >> "$1"
EOF

cat > "$STUB_BIN/mgba" <<'EOF'
#!/usr/bin/env bash
if [[ $# -ne 4 || -z ${XDG_CONFIG_HOME:-} || $1 != -C || $2 != "savegamePath=$XDG_CONFIG_HOME" || $3 != -d || $4 != "$XDG_CONFIG_HOME/"* || ! -f $4 ]]; then
  printf 'Expected an isolated config, save directory, and ROM copy\n' >&2
  exit 1
fi
commands=$(cat)
if [[ "$commands" != $'break 0x0820bdb0\ncontinue\nquit' ]]; then
  printf 'Unexpected debugger commands:\n%s\n' "$commands" >&2
  exit 1
fi
if [[ ${STUB_HANG:-0} == 1 ]]; then
  exec sleep 3
fi
echo "Hit breakpoint 1 at ${STUB_HIT_ADDR}"
exit "${STUB_EXIT_STATUS:-0}"
EOF

chmod +x "$STUB_BIN/arm-none-eabi-nm" "$STUB_BIN/arm-none-eabi-objcopy" "$STUB_BIN/gbafix" "$STUB_BIN/mgba"

printf 'FAKE_ROM_BYTES' > "$TMPDIR/test.gba"
printf 'DIFFERENT_ELF_BYTES' > "$TMPDIR/test.elf"
status=0
OUT=$(PATH="$STUB_BIN:$PATH" GBAFIX="$TMPDIR/should-not-be-called" STUB_HIT_ADDR="0x0820BDB0" "$REPO_ROOT/scripts/smoke_test.sh" "$TMPDIR/test.gba" 10 2>&1) || status=$?
if [ "$status" -ne 1 ] || ! grep -q '^FAIL: ROM does not match ELF:' <<<"$OUT"; then
  echo "FAIL: smoke_test.sh should reject a mismatched ROM and ELF before running gbafix"
  echo "$OUT"
  exit 1
fi

cp "$TMPDIR/test.gba" "$TMPDIR/test.elf"

status=0
OUT=$(PATH="$STUB_BIN:$PATH" GBAFIX="$STUB_BIN/gbafix" STUB_HIT_ADDR="0x08001234" "$REPO_ROOT/scripts/smoke_test.sh" "$TMPDIR/test.gba" 10 2>&1) || status=$?
if [ "$status" -ne 1 ] || ! grep -q '^FAIL: .*exited before hitting Task_TitleScreenPhase3' <<<"$OUT"; then
  echo "FAIL: smoke_test.sh should reject breakpoint hit at wrong address"
  echo "$OUT"
  exit 1
fi

status=0
OUT=$(PATH="$STUB_BIN:$PATH" GBAFIX="$STUB_BIN/gbafix" STUB_HIT_ADDR="0x0820BDB0" STUB_HANG=1 "$REPO_ROOT/scripts/smoke_test.sh" "$TMPDIR/test.gba" 1 2>&1) || status=$?
if [ "$status" -ne 1 ] || ! grep -q '^FAIL: mGBA timed out after 1s waiting for Task_TitleScreenPhase3$' <<<"$OUT"; then
  echo "FAIL: smoke_test.sh should fail with timeout diagnostic when mGBA hangs"
  echo "$OUT"
  exit 1
fi

status=0
OUT=$(PATH="$STUB_BIN:$PATH" GBAFIX="$STUB_BIN/gbafix" STUB_HIT_ADDR="0x0820BDB0" STUB_EXIT_STATUS=42 "$REPO_ROOT/scripts/smoke_test.sh" "$TMPDIR/test.gba" 10 2>&1) || status=$?
if [ "$status" -ne 1 ] || ! grep -q '^FAIL: mGBA exited with status 42$' <<<"$OUT"; then
  echo "FAIL: smoke_test.sh should reject a failed emulator even after a matching breakpoint"
  echo "$OUT"
  exit 1
fi

if ! PATH="$STUB_BIN:$PATH" GBAFIX="$STUB_BIN/gbafix" STUB_HIT_ADDR="0x0820BDB0" "$REPO_ROOT/scripts/smoke_test.sh" "$TMPDIR/test.gba" 10 >/dev/null 2>&1; then
  echo "FAIL: smoke_test.sh should accept breakpoint hit at matching address"
  exit 1
fi

printf 'FAKE_ROM_BYTESPADDING' > "$TMPDIR/padded.gba"
printf 'FAKE_ROM_BYTES' > "$TMPDIR/padded.elf"
status=0
OUT=$(PATH="$STUB_BIN:$PATH" GBAFIX="$TMPDIR/missing-gbafix" STUB_HIT_ADDR="0x0820BDB0" "$REPO_ROOT/scripts/smoke_test.sh" "$TMPDIR/padded.gba" 10 2>&1) || status=$?
if [ "$status" -ne 1 ] || ! grep -q '^FAIL: cannot verify ROM padding:' <<<"$OUT"; then
  echo "FAIL: smoke_test.sh should report missing gbafix separately from ROM/ELF mismatch"
  echo "$OUT"
  exit 1
fi

if ! PATH="$STUB_BIN:$PATH" GBAFIX="$STUB_BIN/gbafix" STUB_HIT_ADDR="0x0820BDB0" "$REPO_ROOT/scripts/smoke_test.sh" "$TMPDIR/padded.gba" 10 >/dev/null 2>&1; then
  echo "FAIL: smoke_test.sh should accept padded ROM via gbafix -p fallback"
  exit 1
fi

echo "PASS: CI helper script tests"
