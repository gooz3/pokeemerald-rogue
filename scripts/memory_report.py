#!/usr/bin/env python3
"""Parse a GNU ld .map file, print EWRAM/IWRAM/ROM usage, and enforce headroom limits."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

EXPECTED_REGIONS = ("EWRAM", "IWRAM", "ROM")


def parse_map(map_path: pathlib.Path) -> dict[str, tuple[int, int]]:
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
            regions[parts[0]] = (int(parts[1], 16), int(parts[2], 16))

    missing = [r for r in EXPECTED_REGIONS if r not in regions]
    if missing:
        raise ValueError(f"Missing expected memory regions in {map_path}: {', '.join(missing)}")

    marker = "Linker script and memory map"
    if marker not in text:
        raise ValueError(f"Could not locate '{marker}' section in {map_path}")
    body = text.split(marker, 1)[1]

    used: dict[str, int] = {r: 0 for r in EXPECTED_REGIONS}

    # Match top-level output sections (column 0), handling both single-line
    # and GNU ld wrapped-line formats (when the section name is long).
    section_re = re.compile(
        r"^([.\w-]+)(?:[ \t]+|\n[ \t]+)(0x[0-9a-fA-F]+)[ \t]+(0x[0-9a-fA-F]+)",
        re.MULTILINE,
    )
    for m in section_re.finditer(body):
        addr = int(m.group(2), 16)
        size = int(m.group(3), 16)
        if size == 0:
            continue
        for region, (origin, length) in regions.items():
            if origin <= addr < origin + length:
                end = (addr + size) - origin
                if end > used[region]:
                    used[region] = end

    empty = [r for r in EXPECTED_REGIONS if used[r] == 0]
    if empty:
        raise ValueError(f"No non-empty output sections found for {', '.join(empty)} in {map_path}")

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
    parser.add_argument("--label", default="ROM", help="Build label for the Markdown heading")
    parser.add_argument("--summary", type=pathlib.Path, default=None, help="Append Markdown report to this file (e.g. $GITHUB_STEP_SUMMARY)")
    parser.add_argument("--max-ewram-pct", type=float, default=99.5)
    parser.add_argument("--max-iwram-pct", type=float, default=90.0)
    parser.add_argument("--max-rom-pct", type=float, default=99.5)
    args = parser.parse_args()

    for region in ("ewram", "iwram", "rom"):
        limit = getattr(args, f"max_{region}_pct")
        if not 0.0 <= limit <= 100.0:
            parser.error(f"--max-{region}-pct must be between 0 and 100")

    if not args.map_file.is_file():
        print(f"FAIL: Linker map not found: {args.map_file}", file=sys.stderr)
        return 1

    limits = {
        "EWRAM": args.max_ewram_pct,
        "IWRAM": args.max_iwram_pct,
        "ROM": args.max_rom_pct,
    }

    stats = parse_map(args.map_file)

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
        over = pct >= 100.0 or pct > gate
        if over:
            failed = True
        status = "FAIL" if over else "PASS"
        lines.append(
            f"| `{region}` | {fmt_bytes(used)} | {fmt_bytes(capacity)} | "
            f"{fmt_bytes(free)} | **{pct:.2f}%** | <= {gate:.1f}% | {status} |"
        )

    report = "\n".join(lines) + "\n"
    print(report, end="")

    if args.summary is not None:
        args.summary.parent.mkdir(parents=True, exist_ok=True)
        with args.summary.open("a", encoding="utf-8") as fh:
            fh.write(report + "\n")

    if failed:
        print("FAIL: Memory headroom gate exceeded.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
