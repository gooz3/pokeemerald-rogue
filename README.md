# Pokémon Emerald Rogue — `gooz3` Fork (Expansion / Moka Base)

A personal bugfix, quality-of-life, and performance fork of **Pokémon Emerald Rogue EX**, tracked on the `gooz3-release` branch.

Built on top of [DepressoMocha/emerogue](https://github.com/DepressoMocha/emerogue) (`2.1+moka-dev`, Expansion base), which itself builds on [Pokabbie/pokeemerald-rogue](https://github.com/Pokabbie/pokeemerald-rogue), [rh-hideout/pokeemerald-expansion](https://github.com/rh-hideout/pokeemerald-expansion), and [pret/pokeemerald](https://github.com/pret/pokeemerald). For inherited Moka changes, see [`Moka_Changelog.md`](Moka_Changelog.md).

> **Note:** No prebuilt `.gba` ROMs are distributed in this repository or its CI runs. Build from source using the instructions below.

## Changes in This Fork

### Moveset Recommender & Competitive Presets ([#10](https://github.com/gooz3/pokeemerald-rogue/pull/10))
- **Battle-format filtering:** The School moveset recommender now prioritizes sets matching the active Singles/Doubles format (neutral in Mixed), and fixed three VGC tiers (`GEN6VGC2016`, `GEN8VGC2020`, `GEN9VGC2023REGULATIONE`) that previously mapped to Singles.
- **Active-gimmick filtering:** Avoids recommending Mega Stones, Z-Crystals, and `Tera Blast` sets when those gimmicks are inactive.
- **Recommender performance (~19x–49x faster on GBA hardware):** Unpacks the party Pokémon once into a stack snapshot and caches run-environment / item checks instead of repeatedly decrypting `BoxPokemon` per preset (e.g., Charizard's 108 sets dropped from ~1,001 ms to ~20.6 ms).
- **Bug fixes:** Fixed dead known-move scoring (`moveId += 2` -> `score += 2`), fixed `preset->ability == ITEM_NONE`, guarded against out-of-bounds party indices without softlocking the script, aligned trainer format preference and `Tera Blast` penalties, fixed the trainer Tera Black Sludge -> Leftovers no-op assignment, and kept Wild Den Pokémon itemless while avoiding disabled `Tera Blast` sets.

### Wild Encounters & Adventure Paths ([#7](https://github.com/gooz3/pokeemerald-rogue/pull/7), [#2](https://github.com/gooz3/pokeemerald-rogue/pull/2))
- **Bounded grass encounter selection:** Replaced unbounded wild grass rerolls with bounded candidate selection that relaxes the oldest history entries until at least two distinct species remain eligible, preventing stalls and deterministic cycles in small encounter pools.
- **Adventure layout overflow protection:** Enforced the 32-room layout cap during recursive path generation and added a connected straight-path fallback when oversized layouts occur.
- **Route replacement cap:** Fixed route replacement calculation (`min` instead of `max`) so adventure generation honors the configured replacement percentage.

### Correctness & Memory Safety ([#2](https://github.com/gooz3/pokeemerald-rogue/pull/2), [review notes](docs/reviews/2026-10-23-rom-review.md))
- **Safari eviction bounds:** Validates the randomly selected slot before evicting a custom Pokémon, preventing out-of-bounds writes into `safariMonCustomIds`.
- **History buffer underflow:** Fixed the off-by-one shift in `HistoryBufferPush` that read `buffer[-1]` and failed to evict the oldest entry.
- **Query bit-array bounds:** Padded and bounds-checked `gRogueQueryBits` word loads during query iteration.
- **Cached stat recalculation:** Refreshes stats after IV modifications (Hidden Power presets, roamers, wild dens, and custom-mon replacements) while preserving battle HP on caught custom Pokémon.
- **Large bag pockets:** Widened bag pocket capacity and menu swap positions past 255 stacks (`u8` -> `u16`).
- **Hardy & unset natures:** Applied `NATURE_HARDY` (`0`) presets instead of skipping them, and omitted the nature row in the recommender UI when a set has no nature.
- **Palette & time-of-day edge cases:** Added defined default hues when all reference colors are grayscale/dark, and recalculated time-of-day state in `IsDawn`/`IsDay`/`IsDusk`/`IsNight` getters so gameplay checks (such as Rockruff/Lycanroc forms) do not depend on cosmetic time visuals.

### Tooling, Debug Helpers & CI ([#6](https://github.com/gooz3/pokeemerald-rogue/pull/6))
- **NixOS build & GCC 15 support:** Added [`shell.nix`](shell.nix), [`scripts/build_nix.sh`](scripts/build_nix.sh), and a `<cstdint>` fix in `tools/mapjson/json11.cpp`.
- **Automated smoke test & memory reporting:** Added headless mGBA title-screen boot testing ([`scripts/smoke_test.sh`](scripts/smoke_test.sh), [`scripts/smoke_test_nix.sh`](scripts/smoke_test_nix.sh)), linker memory headroom reporting ([`scripts/memory_report.py`](scripts/memory_report.py)), and GitHub Actions CI ([`.github/workflows/build.yml`](.github/workflows/build.yml)).
- **Rogue Utils debug helpers:** Added in-game debug menu helpers in `src/debug.c` for exercising the review fixes, and fixed `customjson` Make dependency regeneration.

## Save Compatibility

- **From Moka 2.1/2.2 (Expansion):** Compatible — this fork has not altered `gRogueSaveBlock` layout.
- **From vanilla Emerald Rogue:** One-way compatible (inherited from Moka). Back up your save file before upgrading.
- **Savestates:** Avoid loading emulator savestates captured from a different ROM build; use in-game saves when updating.

## Inherited Moka Custom Settings

- **Difficulty reward:** Switches rewards to a multiplier based on active difficulty settings and curses carried into a run.
- **Show money:** Displays current money in the start menu during a run.
- **Quick route:** Generates a short route layout (refreshed on run entry / badge gain) for faster runs or shiny hunting.
- **Skip starter bag:** Skips the random starter bag prompt before starting a run.

## Building from Source

### Ubuntu / Debian Linux

```bash
sudo apt-get update
sudo apt-get install -y \
  gcc-arm-none-eabi binutils-arm-none-eabi libnewlib-arm-none-eabi \
  build-essential libpng-dev libelf-dev zlib1g-dev unzip wget mgba-sdl

./init_deps.sh
make -j"$(nproc)" -O RELEASE=1              # Release ROM -> emerogue.gba (use RELEASE=0 for Debug)
scripts/smoke_test.sh emerogue.gba          # Headless mGBA title-screen boot check
python3 scripts/memory_report.py emerogue.map
```

### NixOS

```bash
scripts/build_nix.sh                        # Release ROM -> emerogue.gba (default RELEASE=1)
scripts/build_nix.sh RELEASE=0              # Debug ROM -> emerogue.gba
scripts/smoke_test_nix.sh                   # Headless mGBA title-screen boot check
python3 scripts/memory_report.py emerogue.map
nix-shell --run 'mgba-qt emerogue.gba'      # Launch in mGBA
```

For development quirks, branch remotes, and contributor guidelines, see [`AGENTS.md`](AGENTS.md).
