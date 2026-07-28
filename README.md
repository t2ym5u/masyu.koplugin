# masyu.koplugin

A Masyu puzzle plugin for [KOReader](https://github.com/koreader/koreader).

## Screenshot

*(Screenshot to be added.)*

## Rules

Draw a single closed loop passing through all pearl circles. **White pearl**: the loop goes straight through and must turn in at least one adjacent cell. **Black pearl**: the loop turns 90° here and must go straight through both adjacent cells. The loop cannot branch or cross itself.

## Features

- **Two grid sizes** — 6×6, 8×8
- **Reveal solution** — show the generated loop at any time
- **Auto-save** — puzzle state saved and restored on next launch

## Installation

1. Download `masyu.koplugin.zip` from the [latest release](../../releases/latest).
2. Extract into the `plugins/` folder of your KOReader data directory.
3. Restart KOReader.
4. Open the menu → **Tools** → **Masyu**.

## Controls

| Action | How |
|--------|-----|
| Toggle a cell in/out of the loop | Tap it |
| Reveal / hide the solution | Tap **Show** / **Hide** |
| Clear your path | Tap **Clear** |
| New puzzle | Tap **New game** |
| Change grid size | Tap **Grid** |
| Show rules | Tap **Rules** |

## Known limitations

At 6×6, every generated puzzle is guaranteed to have exactly one solution. At
8×8, most puzzles do too, but proving uniqueness there is computationally
expensive and generation is capped at a couple of seconds — occasionally an
8×8 puzzle ships without that guarantee (still fully valid and completable,
just not proven to be the only possible solution).

## License

GPL-3.0 — see [LICENSE](LICENSE).
