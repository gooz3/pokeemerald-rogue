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
.iwram$very_long_wrapped_section
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
pathlib.Path(sys.argv[1]).with_name("truncated-table.elf").write_bytes(ehdr + body[:-1])

# Single PT_LOAD segment at rom_origin extending to 0x08100000 (3.125%).
overlap_phdr = struct.pack("<IIIIIIII", 1, 0x80, 0x08000000, 0x08000000, 0x00100000, 0x00100000, 5, 4)
overlap_ehdr = e_ident + struct.pack("<HHIIIIIHHHHHH", 2, 40, 1, 0x08000000, 52, 0, 0, 52, 32, 1, 0, 0, 0)
with pathlib.Path(sys.argv[1]).with_name("overlap.elf").open("wb") as fixture:
    fixture.write(overlap_ehdr + overlap_phdr)
    fixture.truncate(0x00100080)

# Header-bearing segment (offset 0) that starts below rom_origin and runs into ROM.
payload_phdr = struct.pack("<IIIIIIII", 1, 0, 0x07FFFF80, 0x07FFFF80, 0x00100080, 0x00100080, 5, 4)
with pathlib.Path(sys.argv[1]).with_name("pre-rom-payload.elf").open("wb") as fixture:
    fixture.write(overlap_ehdr + payload_phdr)
    fixture.truncate(0x00100100)

# One in-range ROM segment plus a file-backed segment starting at rom_origin + rom_length (0x0A000000).
beyond_phdrs = [
    (1, 0x100, 0x08000000, 0x08000000, 0x00100000, 0x00100000, 5, 4),
    (1, 0x00100100, 0x0A000000, 0x0A000000, 0x00001000, 0x00001000, 4, 4),
]
beyond_ehdr = e_ident + struct.pack("<HHIIIIIHHHHHH", 2, 40, 1, 0x08000000, 52, 0, 0, 52, 32, len(beyond_phdrs), 0, 0, 0)
beyond_body = b"".join(struct.pack("<IIIIIIII", *p) for p in beyond_phdrs)
with pathlib.Path(sys.argv[1]).with_name("beyond-rom.elf").open("wb") as fixture:
    fixture.write(beyond_ehdr + beyond_body)
    fixture.truncate(0x00101100)

# One in-range ROM segment plus a file-backed segment ending before rom_origin (0x08000000).
before_phdrs = [
    (1, 0x100, 0x08000000, 0x08000000, 0x00100000, 0x00100000, 5, 4),
    (1, 0x00100100, 0x02000000, 0x02000000, 0x00001000, 0x00001000, 6, 4),
]
before_ehdr = e_ident + struct.pack("<HHIIIIIHHHHHH", 2, 40, 1, 0x08000000, 52, 0, 0, 52, 32, len(before_phdrs), 0, 0, 0)
before_body = b"".join(struct.pack("<IIIIIIII", *p) for p in before_phdrs)
with pathlib.Path(sys.argv[1]).with_name("before-rom.elf").open("wb") as fixture:
    fixture.write(before_ehdr + before_body)
    fixture.truncate(0x00101100)
PY

status=0
OUT=$(python3 "$REPO_ROOT/scripts/memory_report.py" "$MAP" --elf "$TMPDIR/truncated-table.elf" 2>&1) || status=$?
if [ "$status" -ne 1 ] || ! grep -q 'Truncated ELF program header table' <<<"$OUT"; then
  echo "FAIL: expected truncated ELF program header table to be rejected"
  echo "$OUT"
  exit 1
fi

status=0
OUT=$(python3 "$REPO_ROOT/scripts/memory_report.py" "$MAP" --elf "$TMPDIR/truncated.elf" 2>&1) || status=$?
if [ "$status" -ne 1 ] || ! grep -q 'Truncated PT_LOAD segment' <<<"$OUT"; then
  echo "FAIL: expected truncated ELF payload to be rejected"
  echo "$OUT"
  exit 1
fi

status=0
OUT=$(python3 "$REPO_ROOT/scripts/memory_report.py" "$MAP" --elf "$TMPDIR/beyond-rom.elf" 2>&1) || status=$?
if [ "$status" -ne 1 ] || ! grep -q 'File-backed PT_LOAD segment starts beyond ROM' <<<"$OUT"; then
  echo "FAIL: expected file-backed PT_LOAD segment beyond ROM to be rejected"
  echo "$OUT"
  exit 1
fi

status=0
OUT=$(python3 "$REPO_ROOT/scripts/memory_report.py" "$MAP" --elf "$TMPDIR/before-rom.elf" 2>&1) || status=$?
if [ "$status" -ne 1 ] || ! grep -q 'File-backed PT_LOAD segment ends before ROM' <<<"$OUT"; then
  echo "FAIL: expected file-backed PT_LOAD segment before ROM to be rejected"
  echo "$OUT"
  exit 1
fi

OUT=$(python3 "$REPO_ROOT/scripts/memory_report.py" "$MAP" --elf "$TMPDIR/overlap.elf" \
  --max-ewram-pct 90 --max-iwram-pct 60 --max-rom-pct 10)
grep -q "| \`ROM\` |.*\\*\\*3\\.12%\\*\\*.*| PASS |" <<<"$OUT" || { echo "FAIL: ROM-origin segment mismatch"; echo "$OUT"; exit 1; }

status=0
OUT=$(python3 "$REPO_ROOT/scripts/memory_report.py" "$MAP" --elf "$TMPDIR/pre-rom-payload.elf" 2>&1) || status=$?
if [ "$status" -ne 1 ] || ! grep -q 'File-backed PT_LOAD segment starts before ROM' <<<"$OUT"; then
  echo "FAIL: expected a PT_LOAD segment starting below ROM to be rejected"
  echo "$OUT"
  exit 1
fi

sed '/^ROM[[:blank:]]/s/0x02000000/0x00000000/' "$MAP" > "$TMPDIR/zero-rom.map"
status=0
OUT=$(python3 "$REPO_ROOT/scripts/memory_report.py" "$TMPDIR/zero-rom.map" --elf "$TMPDIR/overlap.elf" 2>&1) || status=$?
if [ "$status" -ne 1 ] || ! grep -q 'Expected positive length for ROM' <<<"$OUT"; then
  echo "FAIL: expected zero-length ROM region to be rejected cleanly"
  echo "$OUT"
  exit 1
fi

# Expected high-water marks:
# - EWRAM: 0x00038000 / 0x00040000 = 87.50% (includes NOLOAD section)
# - IWRAM: (0x00004000 + 0x700) / 0x00008000 = 55.47% (includes wrapped section)
# - ROM:   (0x09e00000 + 0x00010000 - 0x08000000) / 0x02000000 = 93.95% (excludes NOLOAD ROM LMA 0x09f00000)
SUMMARY="$TMPDIR/summary.md"
OUT=$(python3 "$REPO_ROOT/scripts/memory_report.py" "$MAP" --label "Fixture" \
  --summary "$SUMMARY" --max-ewram-pct 90 --max-iwram-pct 60 --max-rom-pct 95)

printf '%s\n\n' "$OUT" | cmp -s - "$SUMMARY" || { echo "FAIL: summary does not match the memory report"; exit 1; }
grep -q "| \`EWRAM\` |.*\\*\\*87\\.50%\\*\\*.*| PASS |" <<<"$OUT" || { echo "FAIL: EWRAM mismatch"; echo "$OUT"; exit 1; }
grep -q "| \`IWRAM\` |.*\\*\\*55\\.47%\\*\\*.*| PASS |" <<<"$OUT" || { echo "FAIL: IWRAM mismatch"; echo "$OUT"; exit 1; }
grep -q "| \`ROM\` |.*\\*\\*93\\.95%\\*\\*.*| PASS |" <<<"$OUT" || { echo "FAIL: ROM load-address mismatch"; echo "$OUT"; exit 1; }

status=0
OUT=$(python3 "$REPO_ROOT/scripts/memory_report.py" "$MAP" --max-rom-pct 93.9 2>&1) || status=$?
if [ "$status" -ne 1 ] || ! grep -q "| \`ROM\` |.*| FAIL |" <<<"$OUT"; then
  echo "FAIL: expected a ROM headroom failure (exit 1) when 93.95% > 93.9%"
  echo "$OUT"
  exit 1
fi

status=0
OUT=$(python3 "$REPO_ROOT/scripts/memory_report.py" "$MAP" --elf "$TMPDIR/overlap.elf" \
  --max-ewram-pct 90 --max-iwram-pct 60 --max-rom-pct 3.12 2>&1) || status=$?
if [ "$status" -ne 1 ] || ! grep -q "| \`ROM\` |.*\\*\\*3\\.125%\\*\\*.*| <= 3\\.12% | FAIL |" <<<"$OUT"; then
  echo "FAIL: expected unrounded ROM percentage when rounding would hide failure"
  echo "$OUT"
  exit 1
fi

OUT=$(python3 "$REPO_ROOT/scripts/memory_report.py" "$MAP" --max-rom-pct 93.946)
if ! grep -q "| \`ROM\` |.*\\*\\*93\\.9453125%\\*\\*.*| <= 93\\.946% | PASS |" <<<"$OUT"; then
  echo "FAIL: expected unrounded ROM percentage when rounding would fake a failure"
  echo "$OUT"
  exit 1
fi

for gate in EWRAM:87 IWRAM:55; do
  region=${gate%:*}
  limit=${gate#*:}
  status=0
  OUT=$(python3 "$REPO_ROOT/scripts/memory_report.py" "$MAP" "--max-${region,,}-pct" "$limit" 2>&1) || status=$?
  if [ "$status" -ne 1 ] || ! grep -q "| \`$region\` |.*| FAIL |" <<<"$OUT"; then
    echo "FAIL: expected a $region headroom failure at a $limit% gate"
    echo "$OUT"
    exit 1
  fi
done

# Valid memory table but a RAM region with no (or only zero-sized) output sections: must fail closed, not report 0%.
sed '/^Linker script and memory map/,$ { /^ewram[[:blank:]]/d; /^\.ram_/{ N; d; }; }' "$MAP" > "$TMPDIR/missing-ewram.map"
sed '/^Linker script and memory map/,$ { /^iwram[[:blank:]]/d; /^\.iwram\$/{ N; d; }; }' "$MAP" > "$TMPDIR/missing-iwram.map"
cp "$TMPDIR/missing-ewram.map" "$TMPDIR/zero-size-ewram.map"
printf '%s\n' 'ewram           0x02001000    0x00000000' >> "$TMPDIR/zero-size-ewram.map"
cp "$TMPDIR/missing-ewram.map" "$TMPDIR/input-only-ewram.map"
printf '%s\n' ' .bss.fixture   0x02001000    0x00000004 fixture.o' >> "$TMPDIR/input-only-ewram.map"
for case in missing-ewram:EWRAM zero-size-ewram:EWRAM input-only-ewram:EWRAM missing-iwram:IWRAM; do
  fixture=${case%:*}
  region=${case#*:}
  status=0
  OUT=$(python3 "$REPO_ROOT/scripts/memory_report.py" "$TMPDIR/$fixture.map" --elf "$ELF" 2>&1) || status=$?
  if [ "$status" -ne 1 ] || ! grep -q "No non-empty output sections found for $region in" <<<"$OUT"; then
    echo "FAIL: expected $fixture.map to be rejected for $region"
    echo "$OUT"
    exit 1
  fi
done

# A zero-sized output section above the high-water mark is ignored, not counted or rejected.
cp "$MAP" "$TMPDIR/mixed-size-ewram.map"
printf '%s\n' '.ram_empty      0x0203f000    0x00000000' >> "$TMPDIR/mixed-size-ewram.map"
if ! OUT=$(python3 "$REPO_ROOT/scripts/memory_report.py" "$TMPDIR/mixed-size-ewram.map" --elf "$ELF" --max-ewram-pct 90 2>&1) ||
  ! grep -q "| \`EWRAM\` |.*\\*\\*87\\.50%\\*\\*.*| PASS |" <<<"$OUT"; then
  echo "FAIL: expected EWRAM to remain at 87.50% with a zero-sized section"
  echo "$OUT"
  exit 1
fi

# The smallest valid section (one byte at the region origin) is counted and accepted.
cp "$TMPDIR/missing-ewram.map" "$TMPDIR/one-byte-ewram.map"
printf '%s\n' 'ewram           0x02000000    0x00000001' >> "$TMPDIR/one-byte-ewram.map"
if ! OUT=$(python3 "$REPO_ROOT/scripts/memory_report.py" "$TMPDIR/one-byte-ewram.map" --elf "$ELF" 2>&1) ||
  ! grep -Fq "| \`EWRAM\` | 1 B |" <<<"$OUT"; then
  echo "FAIL: expected a one-byte EWRAM section to be counted and accepted"
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

status=0
OUT=$(python3 "$REPO_ROOT/scripts/memory_report.py" "$MAP" --summary "$TMPDIR" \
  --max-ewram-pct 90 --max-iwram-pct 60 --max-rom-pct 95 2>&1) || status=$?
if [ "$status" -ne 1 ] || ! grep -q '^FAIL: Could not write memory summary to ' <<<"$OUT"; then
  echo "FAIL: expected clean FAIL message (exit 1) for unwritable --summary path"
  echo "$OUT"
  exit 1
fi

# --- 2. smoke_test.sh: ELF match, gbafix -p fallback, debugger commands, timeout, exit status ---
unset DEVKITARM
STUB_BIN="$TMPDIR/bin"
mkdir -p "$STUB_BIN"

cat > "$STUB_BIN/arm-none-eabi-nm" <<'EOF'
#!/usr/bin/env bash
echo "0820bdb1 t Task_TitleScreenPhase3"
EOF

cat > "$STUB_BIN/arm-none-eabi-objcopy" <<'EOF'
#!/usr/bin/env bash
# Usage: arm-none-eabi-objcopy -O binary -- <elf> <out>
if [[ $# -ne 5 || $1 != -O || $2 != binary || $3 != -- ]]; then
  printf 'Unexpected objcopy args: %s\n' "$*" >&2
  exit 1
fi
cp -- "$4" "$5"
EOF

cat > "$STUB_BIN/gbafix" <<'EOF'
#!/usr/bin/env bash
if [ "$#" -ne 3 ] || [ "$2" != "-p" ] || [ "$3" != "--silent" ]; then
  printf 'Unexpected gbafix args: %s\n' "$*" >&2
  exit 1
fi
data=$(cat -- "$1")
data=${data/#RAW_/FIX_}
printf '%sPADDING' "$data" > "$1"
EOF

cat > "$STUB_BIN/mgba" <<'EOF'
#!/usr/bin/env bash
if [[ $# -ne 4 || -z ${XDG_CONFIG_HOME:-} || $1 != -C || $2 != "savegamePath=$XDG_CONFIG_HOME" || $3 != -d || $4 != "$XDG_CONFIG_HOME/"* || ! -f $4 ]]; then
  printf 'Expected an isolated config, save directory, and ROM copy\n' >&2
  exit 1
fi
if [[ ${SDL_VIDEODRIVER:-} != dummy || ${SDL_AUDIODRIVER:-} != dummy ]]; then
  printf 'Expected headless SDL dummy drivers\n' >&2
  exit 1
fi
commands=$(cat)
if [[ "$commands" != $'break 0x0820bdb0\ncontinue\nquit' ]]; then
  printf 'Unexpected debugger commands:\n%s\n' "$commands" >&2
  exit 1
fi
if [[ ${STUB_IGNORE_TERM:-0} == 1 ]]; then
  trap '' TERM
  exec sleep infinity
fi
if [[ ${STUB_HANG:-0} == 1 ]]; then
  exec sleep infinity
fi
echo "Hit breakpoint 1 at ${STUB_HIT_ADDR}"
exit "${STUB_EXIT_STATUS:-0}"
EOF

chmod +x "$STUB_BIN/arm-none-eabi-nm" "$STUB_BIN/arm-none-eabi-objcopy" "$STUB_BIN/gbafix" "$STUB_BIN/mgba"

printf 'FAKE_ROM_BYTES' > "$TMPDIR/test.gba"
printf 'DIFFERENT_ELF_BYTES' > "$TMPDIR/test.elf"
status=0
OUT=$(PATH="$STUB_BIN:$PATH" GBAFIX="$STUB_BIN/gbafix" STUB_HIT_ADDR="0x0820BDB0" "$REPO_ROOT/scripts/smoke_test.sh" "$TMPDIR/test.gba" 10 2>&1) || status=$?
if [ "$status" -ne 1 ] || ! grep -q '^FAIL: ROM does not match ELF:' <<<"$OUT"; then
  echo "FAIL: smoke_test.sh should reject a mismatched ROM and ELF"
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
OUT=$(PATH="$STUB_BIN:$PATH" GBAFIX="$STUB_BIN/gbafix" STUB_HIT_ADDR="0x0820BDB0" "$REPO_ROOT/scripts/smoke_test.sh" "$TMPDIR/test.gba" 0 2>&1) || status=$?
if [ "$status" -ne 1 ] || ! grep -q '^FAIL: timeout must be a positive integer number of seconds$' <<<"$OUT"; then
  echo "FAIL: smoke_test.sh should reject a zero timeout"
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
OUT=$(PATH="$STUB_BIN:$PATH" GBAFIX="$STUB_BIN/gbafix" STUB_HIT_ADDR="0x0820BDB0" STUB_IGNORE_TERM=1 "$REPO_ROOT/scripts/smoke_test.sh" "$TMPDIR/test.gba" 1 2>&1) || status=$?
if [ "$status" -ne 1 ] || ! grep -q '^FAIL: mGBA was killed by SIGKILL while waiting for Task_TitleScreenPhase3' <<<"$OUT"; then
  echo "FAIL: smoke_test.sh should report SIGKILL escalation when mGBA ignores SIGTERM"
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

printf 'FIX_ROM_BYTESPADDING' > "$TMPDIR/unpatched.gba"
printf 'RAW_ROM_BYTES' > "$TMPDIR/unpatched.elf"
if ! PATH="$STUB_BIN:$PATH" GBAFIX="$STUB_BIN/gbafix" STUB_HIT_ADDR="0x0820BDB0" "$REPO_ROOT/scripts/smoke_test.sh" "$TMPDIR/unpatched.gba" 10 >/dev/null 2>&1; then
  echo "FAIL: smoke_test.sh should accept ROM whose header and padding were normalized by gbafix -p"
  exit 1
fi

printf 'FAKE_ROM_BYTESJUNKPAD' > "$TMPDIR/padded.gba"
status=0
OUT=$(PATH="$STUB_BIN:$PATH" GBAFIX="$STUB_BIN/gbafix" STUB_HIT_ADDR="0x0820BDB0" "$REPO_ROOT/scripts/smoke_test.sh" "$TMPDIR/padded.gba" 10 2>&1) || status=$?
if [ "$status" -ne 1 ] || ! grep -q '^FAIL: ROM does not match ELF:' <<<"$OUT"; then
  echo "FAIL: smoke_test.sh should reject incorrect ROM padding"
  echo "$OUT"
  exit 1
fi

# Exercise repository-relative paths and argument quoting through the Nix wrapper.
cat > "$STUB_BIN/nix-shell" <<'EOF'
#!/usr/bin/env bash
[[ $# -eq 2 && $1 == --run ]] || exit 1
exec bash -c "$2"
EOF
chmod +x "$STUB_BIN/nix-shell"
WRAPPER_REPO="$TMPDIR/wrapper-repo"
mkdir -p "$WRAPPER_REPO/scripts" "$WRAPPER_REPO/fixtures" "$TMPDIR/caller"
cp -- "$REPO_ROOT/scripts/smoke_test.sh" "$REPO_ROOT/scripts/smoke_test_nix.sh" "$WRAPPER_REPO/scripts/"
cp -- "$TMPDIR/test.gba" "$WRAPPER_REPO/fixtures/wrapper test.gba"
cp -- "$TMPDIR/test.elf" "$WRAPPER_REPO/fixtures/wrapper test.elf"
if ! OUT=$(cd -- "$TMPDIR/caller" && PATH="$STUB_BIN:$PATH" STUB_HIT_ADDR="0x0820BDB0" \
  "$WRAPPER_REPO/scripts/smoke_test_nix.sh" 'fixtures/wrapper test.gba' 10 2>&1); then
  echo "FAIL: smoke_test_nix.sh should accept a repository-relative ROM path containing spaces"
  echo "$OUT"
  exit 1
fi

cat > "$STUB_BIN/arm-none-eabi-objcopy" <<'EOF'
#!/usr/bin/env bash
exit 42
EOF
chmod +x "$STUB_BIN/arm-none-eabi-objcopy"
status=0
OUT=$(PATH="$STUB_BIN:$PATH" STUB_HIT_ADDR="0x0820BDB0" "$REPO_ROOT/scripts/smoke_test.sh" "$TMPDIR/test.gba" 10 2>&1) || status=$?
if [ "$status" -ne 1 ] || ! grep -q '^FAIL: could not extract ROM image from ' <<<"$OUT"; then
  echo "FAIL: smoke_test.sh should reject an objcopy failure"
  echo "$OUT"
  exit 1
fi

cat > "$STUB_BIN/arm-none-eabi-nm" <<'EOF'
#!/usr/bin/env bash
echo "0820bdb1 t Task_TitleScreenPhase3"
exit 42
EOF
chmod +x "$STUB_BIN/arm-none-eabi-nm"
status=0
OUT=$(PATH="$STUB_BIN:$PATH" STUB_HIT_ADDR="0x0820BDB0" "$REPO_ROOT/scripts/smoke_test.sh" "$TMPDIR/test.gba" 10 2>&1) || status=$?
if [ "$status" -ne 1 ] || ! grep -q '^FAIL: could not read symbols from ' <<<"$OUT"; then
  echo "FAIL: smoke_test.sh should reject an arm-none-eabi-nm failure"
  echo "$OUT"
  exit 1
fi

cat > "$STUB_BIN/arm-none-eabi-nm" <<'STUB'
#!/usr/bin/env bash
echo "0820bdb1 t UnrelatedSymbol"
STUB
chmod +x "$STUB_BIN/arm-none-eabi-nm"
status=0
OUT=$(PATH="$STUB_BIN:$PATH" STUB_HIT_ADDR="0x0820BDB0" "$REPO_ROOT/scripts/smoke_test.sh" "$TMPDIR/test.gba" 10 2>&1) || status=$?
if [ "$status" -ne 1 ] || ! grep -q '^FAIL: Task_TitleScreenPhase3 not found in ' <<<"$OUT"; then
  echo "FAIL: smoke_test.sh should reject an ELF without the title-screen symbol"
  echo "$OUT"
  exit 1
fi

echo "PASS: CI helper script tests"
