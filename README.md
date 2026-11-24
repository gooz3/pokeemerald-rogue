# Pokémon Emerald Rogue — `gooz3` Fork (Expansion / Moka Base)

A personal bugfix, quality-of-life, and performance fork of **Pokémon Emerald Rogue EX**, maintained on the `gooz3-release` branch.

Built on top of [DepressoMocha/emerogue](https://github.com/DepressoMocha/emerogue) (`2.1+moka-dev`, Expansion base), which itself builds on [Pokabbie/pokeemerald-rogue](https://github.com/Pokabbie/pokeemerald-rogue), [rh-hideout/pokeemerald-expansion](https://github.com/rh-hideout/pokeemerald-expansion), and [pret/pokeemerald](https://github.com/pret/pokeemerald).

- **Release notes & history:** See [GitHub Releases](https://github.com/gooz3/pokeemerald-rogue/releases) (and [`Moka_Changelog.md`](Moka_Changelog.md) for inherited Moka changes).
- **ROM distribution:** No prebuilt `.gba` ROMs are distributed in this repository or its CI runs. Build from source using the instructions below.

## Fork Focus

This fork stays save-compatible with Moka 2.1/2.2 Expansion while focusing on stability, gameplay polish, and GBA performance:

- **Format- & gimmick-aware moveset recommendations:** The School moveset recommender, trainer sets, and Wild Dens respect active battle format (Singles / Doubles / Mixed) and enabled gimmicks (Mega Evolution, Z-Moves, Terastallization), with fast single-pass GBA scoring.
- **Safer run & encounter generation:** Bounded wild grass encounter selection (preventing stalls/cycles in small pools), 32-room adventure layout overflow protection, and accurate route replacement caps.
- **Correctness & memory safety:** Fixes across Safari eviction, history buffers, query bit-array bounds, stat recalculation after IV changes, large bag pockets (>255 stacks), Hardy/unset natures, custom palettes, and time-of-day getters (see [review notes](docs/reviews/2026-10-23-rom-review.md)).
- **Tooling & CI:** NixOS build environment (`shell.nix`), headless mGBA boot smoke tests, EWRAM/IWRAM/ROM headroom checks, in-game Rogue Utils debug helpers, and GitHub Actions CI.

## Save Compatibility

- **From Moka 2.1/2.2 (Expansion):** Compatible — `gRogueSaveBlock` layout is preserved.
- **From vanilla Emerald Rogue:** One-way compatible (inherited from Moka). Back up your save file before upgrading.
- **Savestates:** Avoid loading emulator savestates captured on a different ROM build; use in-game saves when updating.

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
make -j"$(nproc)" -O RELEASE=1                 # Release ROM -> emerogue.gba (use RELEASE=0 for Debug)
scripts/smoke_test.sh emerogue.gba             # Headless mGBA title-screen boot check
python3 scripts/memory_report.py emerogue.map  # EWRAM / IWRAM / ROM % usage
```

### NixOS

```bash
scripts/build_nix.sh                           # Release ROM -> emerogue.gba (default RELEASE=1)
scripts/build_nix.sh RELEASE=0                 # Debug ROM -> emerogue.gba
scripts/smoke_test_nix.sh                      # Headless mGBA title-screen boot check
python3 scripts/memory_report.py emerogue.map
nix-shell --run 'mgba-qt emerogue.gba'         # Launch in mGBA
```

For local dev quirks, branch remotes, and contributor guidelines, see [`AGENTS.md`](AGENTS.md).
