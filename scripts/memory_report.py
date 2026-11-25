#!/usr/bin/env python3
"""Parse a GNU ld .map file, print EWRAM/IWRAM/ROM usage, and enforce headroom limits."""

from __future__ import annotations

import argparse
import pathlib
import re
import struct
import sys

EXPECTED_REGIONS = ("EWRAM", "IWRAM", "ROM")
RAM_REGIONS = ("EWRAM", "IWRAM")
# The system stack grows down from IWRAM_END - 0x1c0 (src/crt0.s), and the m4a sound
# mixer uses it for sample buffers down to 0x03007900 (src/m4a_1.s stack_boundary_literal).
IWRAM_RESERVED_TOP_BYTES = 0x700
PT_LOAD = 1
ELF32_EHDR_SIZE = 52
ELF32_PHDR_MIN_SIZE = 32


def parse_elf_rom_used(elf_path: pathlib.Path, rom_origin: int, rom_length: int) -> int:
    with elf_path.open("rb") as fh:
        ehdr = fh.read(ELF32_EHDR_SIZE)
        if len(ehdr) < ELF32_EHDR_SIZE or ehdr[:4] != b"\x7fELF":
            raise ValueError(f"Not a valid ELF file: {elf_path}")
        if ehdr[4] != 1 or ehdr[5] != 1:
            raise ValueError(f"Expected 32-bit little-endian ELF: {elf_path}")

        _, _, _, _, e_phoff, _, _, _, e_phentsize, e_phnum, _, _, _ = struct.unpack_from(
            "<HHIIIIIHHHHHH", ehdr, 16
        )
        if not 0 < e_phnum < 0xFFFF or e_phentsize != ELF32_PHDR_MIN_SIZE or e_phoff < ELF32_EHDR_SIZE:
            raise ValueError(f"Invalid ELF program header table in {elf_path}")

        table_size = e_phnum * e_phentsize
        file_size = fh.seek(0, 2)
        if e_phoff + table_size > file_size:
            raise ValueError(f"Truncated ELF program header table in {elf_path}")
        fh.seek(e_phoff)
        table = fh.read(table_size)
        if len(table) < table_size:
            raise ValueError(f"Truncated ELF program header table in {elf_path}")

    rom_used = 0
    for idx in range(e_phnum):
        p_type, p_offset, _, p_paddr, p_filesz, p_memsz, _, _ = struct.unpack_from(
            "<IIIIIIII", table, idx * e_phentsize
        )
        if p_type != PT_LOAD or p_filesz == 0:
            continue
        if p_filesz > p_memsz:
            raise ValueError(f"Corrupt PT_LOAD segment (p_filesz > p_memsz) in {elf_path}")
        if p_offset + p_filesz > file_size:
            raise ValueError(f"Truncated PT_LOAD segment in {elf_path}")
        segment_end = p_paddr + p_filesz
        if segment_end <= rom_origin:
            raise ValueError(f"File-backed PT_LOAD segment ends before ROM in {elf_path}")
        # Only a segment that maps the ELF/program headers may start below ROM.
        if p_paddr < rom_origin and (p_offset != 0 or rom_origin - p_paddr < e_phoff + table_size):
            raise ValueError(f"Non-header PT_LOAD segment starts before ROM in {elf_path}")
        if p_paddr >= rom_origin + rom_length:
            raise ValueError(f"File-backed PT_LOAD segment starts beyond ROM in {elf_path}")
        rom_used = max(rom_used, segment_end - rom_origin)

    if rom_used == 0:
        raise ValueError(f"No file-backed ROM PT_LOAD segments found in {elf_path}")
    return rom_used


def parse_map(map_path: pathlib.Path, elf_path: pathlib.Path) -> dict[str, tuple[int, int]]:
    text = map_path.read_text(encoding="utf-8", errors="replace")

    cfg_match = re.search(
        r"Memory Configuration\s+Name\s+Origin\s+Length\s+Attributes\s*\n(.*?)\n\s*\n",
        text,
        re.DOTALL,
    )
    if not cfg_match:
        raise ValueError(f"Could not locate 'Memory Configuration' table in {map_path}")

    regions: dict[str, tuple[int, int]] = {}
    for line in cfg_match.group(1).splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[0] in EXPECTED_REGIONS:
            origin, length = int(parts[1], 16), int(parts[2], 16)
            if length <= 0:
                raise ValueError(f"Expected positive length for {parts[0]} in {map_path}")
            regions[parts[0]] = (origin, length)

    missing = [r for r in EXPECTED_REGIONS if r not in regions]
    if missing:
        raise ValueError(f"Missing expected memory regions in {map_path}: {', '.join(missing)}")

    marker = "Linker script and memory map"
    if marker not in text:
        raise ValueError(f"Could not locate '{marker}' section in {map_path}")
    body = text.split(marker, 1)[1]

    used: dict[str, int] = {r: 0 for r in EXPECTED_REGIONS}

    # Match top-level output sections (column 0), handling both single-line and
    # wrapped-line formats, using RAM VMAs for EWRAM/IWRAM accounting.
    section_re = re.compile(
        r"^(\S+)(?:[ \t]+|\n[ \t]+)(0x[0-9a-fA-F]+)[ \t]+(0x[0-9a-fA-F]+)",
        re.MULTILINE,
    )
    for m in section_re.finditer(body):
        addr = int(m.group(2), 16)
        size = int(m.group(3), 16)
        if size == 0:
            continue
        for region in RAM_REGIONS:
            origin, length = regions[region]
            if origin <= addr < origin + length:
                end = (addr + size) - origin
                if end > used[region]:
                    used[region] = end

    empty_ram = [r for r in RAM_REGIONS if used[r] == 0]
    if empty_ram:
        raise ValueError(f"No non-empty output sections found for {', '.join(empty_ram)} in {map_path}")

    used["IWRAM"] += IWRAM_RESERVED_TOP_BYTES
    rom_origin, rom_length = regions["ROM"]
    used["ROM"] = parse_elf_rom_used(elf_path, rom_origin, rom_length)

    return {r: (used[r], regions[r][1]) for r in EXPECTED_REGIONS}


def fmt_bytes(n: int) -> str:
    if n >= 1024 * 1024:
        return f"{n:,} B ({n / (1024 * 1024):.2f} MiB)"
    if n >= 1024:
        return f"{n:,} B ({n / 1024:.1f} KiB)"
    return f"{n:,} B"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("map_file", nargs="?", default="emerogue.map", type=pathlib.Path)
    parser.add_argument(
        "--elf",
        type=pathlib.Path,
        default=None,
        help="Matching ELF file for file-backed ROM load ranges (defaults to sibling .elf)",
    )
    parser.add_argument("--label", default="ROM", help="Build label for the Markdown heading")
    parser.add_argument("--summary", type=pathlib.Path, default=None, help="Append Markdown report to this file (e.g. $GITHUB_STEP_SUMMARY)")
    parser.add_argument("--max-ewram-pct", type=float, default=99.5)
    parser.add_argument("--max-iwram-pct", type=float, default=85.0)
    parser.add_argument("--max-rom-pct", type=float, default=99.5)
    args = parser.parse_args()

    for region in ("ewram", "iwram", "rom"):
        limit = getattr(args, f"max_{region}_pct")
        if not 0.0 < limit < 100.0:
            parser.error(f"--max-{region}-pct must be strictly between 0 and 100")

    elf_path = args.elf if args.elf is not None else args.map_file.with_suffix(".elf")
    limits = {
        "EWRAM": args.max_ewram_pct,
        "IWRAM": args.max_iwram_pct,
        "ROM": args.max_rom_pct,
    }

    try:
        if not args.map_file.is_file():
            print(f"FAIL: Linker map not found: {args.map_file}", file=sys.stderr)
            return 1
        if not elf_path.is_file():
            print(f"FAIL: Matching ELF not found: {elf_path}", file=sys.stderr)
            return 1
        stats = parse_map(args.map_file, elf_path)
    except (OSError, ValueError) as exc:
        print(f"FAIL: Could not read memory usage from {args.map_file}: {exc}", file=sys.stderr)
        return 1

    lines = [
        f"### Memory Usage ({args.label})",
        "",
        "| Region | Used | Limit | Free | % Used | Gate | Status |",
        "| --- | ---: | ---: | ---: | ---: | ---: | :---: |",
    ]

    failed = False
    for region in EXPECTED_REGIONS:
        used, capacity = stats[region]
        free = capacity - used
        pct = (used / capacity) * 100.0
        gate = limits[region]
        over = pct > gate
        if over:
            failed = True
        status = "FAIL" if over else "PASS"
        pct_display, gate_display = f"{pct:.2f}", f"{gate:g}"
        if (float(pct_display) > float(gate_display)) != over:
            pct_display, gate_display = str(pct), str(gate)
        lines.append(
            f"| `{region}` | {fmt_bytes(used)} | {fmt_bytes(capacity)} | "
            f"{fmt_bytes(free)} | **{pct_display}%** | <= {gate_display}% | {status} |"
        )

    report = "\n".join(lines) + "\n"
    print(report, end="")

    if args.summary is not None:
        try:
            args.summary.parent.mkdir(parents=True, exist_ok=True)
            with args.summary.open("a", encoding="utf-8") as fh:
                fh.write(report + "\n")
        except OSError as exc:
            print(f"FAIL: Could not write memory summary to {args.summary}: {exc}", file=sys.stderr)
            return 1

    if failed:
        print("FAIL: Memory headroom gate exceeded.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
