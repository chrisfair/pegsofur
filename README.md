# Pegs of Ur

An open-source ancient city-states dice and wooden pegboard strategy game for 1 to 4 Human or AI players, written in pure Nim (`gdext` GDExtension) for Godot 4.

## Toolchain & Commands (`mise` / `make`)

`mise.toml` pins Nim `2.2.2` (`asdf:asdf-community/asdf-nim`) and configures project-local `.nimble` paths and GCC `gcov` coverage thresholds:

```bash
mise trust
mise run test       # Compile and run headless Nim unit & AI simulation tests
mise run coverage   # Run GCC gcov-instrumented tests and enforce >= 85% line coverage
mise run build      # Compile libPegsOfUr.linux.*.x86_64.so GDExtension
mise run smoke      # Verify Godot 4 loads the Nim GDExtension and renders headlessly
mise run run        # Build and launch Pegs of Ur in Godot 4
mise run editor     # Build and open the project in the Godot 4 Editor
```

Equivalent `make` targets (`make test`, `make coverage`, `make report`, `make build`, `make smoke`, `make run`, `make clean`) are available in `Makefile`.

## Architecture

- `nim/src/sim/data.nim` — Six-faced wooden dice (`Grain`, `Ware`, `Wares + Omen`, `Builders`, `Grain / Builders`, `Silver`), 5 Trade Ware pegboard value ladders (`Timber`, `Alabaster`, `Ceramics`, `Linen`, `Ingots`), 7 Great Works (with 2P/3P player-count exclusions), and 13 Civic Advancements.
- `nim/src/sim/entropy.nim` — Direct TCG `TPM2_GetRandom` (`0x0000017B`) hardware entropy source over `/dev/tpmrm0` (or `/dev/tpm0`), buffered in 32-byte bursts with unbiased `b < 252` rejection sampling. Automatically falls back to seeding `std/random` from the high-resolution monotonic and wall-clock system timer (`monotimes` + `times` SplitMix64) if the user lacks read/write access to the TPM or no TPM device is present.
- `nim/src/sim/game.nim` — Turn state machine (`Roll`, `AssignChoices`, `Build`, `Buy`, `Discard`, `GameOver`), Omen locking, `Divination` single-die rerolls, 10-round Solo ruleset, sequential bottom-to-top Ware distribution, `Stonecutting`, `Plowshares`, `Scaffolding`, `Minting`, Settlement feeding & Starvation, Omen Calamities (`Blight`/`Canals`, `Plague`/`Herbalism`, `Raiders`/`Citadel Ramparts`, `Uprising`/`Priesthood`), `Timber Cranes` conversion, Build step undo snapshots, 32-subset optimal whole-track Ware solver + `Royal Silos`, `Merchant Fleets` storage exemption, equal-turns final round, `Urban Planning`/`Hegemony` bonuses, and Ware Silver tiebreaker.
- `nim/src/sim/ai.nim` — Step-by-step AI controller (`Easy`, `Normal`, `Hard`).
- `nim/src/sim/physics.nim` — 2D+height (`x, y, z, vx, vy, vz, angle, angVel`) wooden dice bounce, rail rebound, die-to-die wood collision, smooth pegboard lerp, and polyphonic audio event emission.
- `nim/src/sim/presenter.nim` — Responsive `1680x960` tabletop layout, hit-testing, custom payment drawer, scroll handling, and Setup / Rules / Standings modals.
- `nim/src/classes/pegs_of_ur_controller.nim` — Godot 4 `Node2D` GDExtension renderer & 14-voice `AudioStreamPlayer` hardwood audio pool.

## Licensing

- **Source Code**: MIT License (`LICENSE`).
- **Procedural Dice, Pegs, and Audio (`assets/dice/`, `assets/pegs/`, `assets/audio/`)**: Generated from first-principles geometry and physical-modeling modal hardwood synthesis; released under the MIT / CC0 license alongside the source code.
- **Surface Textures (`assets/textures/`)**: CC0 1.0 Public Domain photo scans from [Poly Haven](https://polyhaven.com/).
