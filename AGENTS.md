# Agent notes: pokeemerald-rogue (gooz3 fork)

Pokémon Emerald Rogue, a roguelike ROM hack built on the pret pokeemerald decomp.
This fork tracks DepressoMocha's "Moka" fork (`depresso` remote, branch `2.1+moka-dev`), which is based on upstream's **expansion** branch, not vanilla.
`INSTALL.md` is the stock pret doc and doesn't cover this fork's setup. See `README.md` for fork overview/changes and this file for NixOS and workflow specifics.

## Repo layout

- `origin` = `gooz3/pokeemerald-rogue` (our fork). Work on `gooz3-release` (the default branch) or feature branches off it.
- `depresso` = `DepressoMocha/emerogue`. To pull Moka's changes (which include upstream expansion): `git fetch depresso && git merge depresso/2.1+moka-dev`.
- `upstream` = `Pokabbie/pokeemerald-rogue`. To pull upstream changes directly, merge `upstream/expansion` (or `expansion-dev`) into `gooz3-release`.
- Rogue code is mostly `src/rogue_*.c`, `include/rogue*.h`, `include/constants/rogue.h`, and Poryscript in `data/scripts/Rogue/`.

## Build (NixOS)

The dev machine runs NixOS. `shell.nix` provides the toolchain and mGBA.

```bash
scripts/build_nix.sh             # release ROM -> emerogue.gba (Makefile defaults RELEASE ?= 1)
scripts/build_nix.sh RELEASE=0   # debug ROM
scripts/smoke_test_nix.sh        # headless mGBA boot; PASS = reached title screen
python3 scripts/memory_report.py emerogue.map  # EWRAM / IWRAM / ROM % usage
nix-shell --run 'mgba-qt emerogue.gba'   # play it
```

Quirks the scripts already handle. Keep them in mind if you build some other way:
- The Makefile defaults `MODERN ?= 1` and `RELEASE ?= 1`, so the game is compiled with `arm-none-eabi-gcc`. `DEVKITARM` must point at that toolchain; `shell.nix` sets it.
- The Makefile hardcodes `SHELL := /bin/bash`, which doesn't exist on NixOS. `build_nix.sh` overrides it.
- `hardeningDisable = [ "fortify" ]` in `shell.nix` is required. Without it, QueryBaker (`tools/Pokabbie/Build/QueryBaker`, which runs from the second build onward) loops forever because `BakeHelpers.h` defines `__attribute__` away.
- agbcc isn't used to compile, but its headers may be referenced if building with `MODERN=0`. On a fresh clone if ever needed:
  ```bash
  cd .. && git clone https://github.com/pret/agbcc && cd agbcc
  nix-shell ../pokeemerald-rogue/shell.nix --run 'unset DEVKITARM; export SHELL=$(command -v bash); ./build.sh && ./install.sh ../pokeemerald-rogue'
  ```
- The first build runs `./init_deps.sh`, which downloads Poryscript and the UPS patcher into `tools/`.
- Rootless podman can't pull images on this machine (no subuid/subgid ranges), so the CI container (`devkitpro/devkitarm`) isn't an option locally.

## Making changes

1. Edit, then run `scripts/build_nix.sh`, `scripts/smoke_test_nix.sh`, and `python3 scripts/memory_report.py emerogue.map`.
2. Play-test anything gameplay-related in mGBA. The smoke test only proves the game boots.
3. If you change save data layout (`gRogueSaveBlock`, the structs in `include/rogue.h`), bump the save version like upstream does, or old saves break.
4. Don't hand-edit generated files such as `src/data/rogue_bake_data.h` and `rogue_exported_stats.json`. QueryBaker regenerates them during the build.
5. The `vanilla` branch has no unit-test suite. `scripts/launch_build_test.sh` (`TEST=1`) is upstream's and isn't maintained for this fork.

## Git / GitHub

- `gh` defaults to the fork. Never push to `upstream`.
- If `git push` fails with `/usr/bin/gh: No such file or directory`, the global credential helper is stale. Run `gh auth setup-git`, or push once with:
  `git -c credential.helper= -c "credential.helper=!$(which gh) auth git-credential" push`
- CI (`.github/workflows/build.yml`) runs on pushes and PRs to `gooz3-release`: Release + Debug builds, headless mGBA title-screen smoke tests, EWRAM/IWRAM/ROM % headroom gates, and script/save-header checks. Never upload `.gba` ROMs as CI artifacts or Releases.
