# Changelog

All notable changes to this project will be documented in this file.

## [1.6.1] - 2026-11-12

### Changed
- Picks up game-common 1.16.0: games for two readers (new Two readers
  category) and the shared Start / Join dialog.

## [1.6.0] - 2026-11-05

### Changed
- Every puzzle can now be solved by reasoning alone, without guessing. A new
  solver plays the puzzle the way a player does (each loop cell has two loop
  neighbours, the black and white circle rules, circles at edges, in corners
  and side by side, no loop closing early, the loop staying in one piece),
  and the generator only keeps loop shapes and circles it can finish. Before,
  puzzles were only checked to have one solution: about 1 in 3 8×8 grids
  (1 in 30 at 6×6) needed "try a cell and see if it breaks".
- The solver also proves the solution is unique, so generation is about as
  fast as before (under 0.04 s on a desktop, about 1 s on a Kobo).
- The Daily Challenge puzzle changes once with this version.

## [1.5.2] - 2026-11-04

### Fixed
- A game no longer crashes when an outdated plugin is installed alongside:
  shared modules left behind by an older plugin are replaced by this
  plugin's own copy instead of being used as they are.

## [1.5.1] - 2026-11-04

### Changed
- Uses less memory: the game loads when you open it, not when KOReader
  starts, so it no longer takes memory or startup time while unplayed.

## [1.5.0] - 2026-11-04

### Fixed
- 8×8 puzzles are always proven to have exactly one solution, and are the
  same on every device. Generation used to stop after 2 s of CPU time:
  even on a desktop 9 grids in 10 were shipped unproven, and a slower
  device (or the Daily Challenge on two devices) could end up with a
  different grid.

### Changed
- Much faster: 8×8 took over 2 s on a desktop (it hit that cap), now under
  0.02 s (about 0.5 s on a Kobo). The solution check applies the circles'
  rules as the loop is built instead of only at the end.
- White circles may now sit where only one neighbour of the loop turns
  (the rule itself is unchanged: at least one side must turn); circles are
  then taken away while the solution stays unique, down to about as many as
  before. Puzzles are new.
- A "Generating puzzle…" progress bar shows when a puzzle takes more than a
  moment. Needs game-common 1.12.0.

## [1.4.3] - 2026-11-03

### Changed
- Picks up game-common 1.11.0: the shared on-screen keyboard (where used)
  gives every key the same letter size, and the no-repeat history helper.

## [1.4.2] - 2026-11-02

### Changed
- Picks up game-common 1.10.0: the shared Tools → Games menu also lists
  the games' new "· multiplayer" entries under Party & quiz.

## [1.4.1] - 2026-11-02

### Changed
- Listed under **Tools → Games**, grouped by category, instead of its own
  entry in the Tools menu (game-common 1.9.1).

## [1.4.0] - 2026-10-30

### Added
- "Daily Challenge" in the menu, right after "New game": today's puzzle at
  your size and difficulty, the same grid for everyone playing it today.
  Needs game-common 1.7.0.

## [1.3.0] - 2026-10-30

### Added
- "New game" once the loop is solved: the action bar shows it in place of
  Clear and Hint, so the next puzzle no longer needs the menu. Showing the
  solution does not end the round, since it can be hidden again.

### Changed
- Redesigned play screen, in line with the other games: a full-width action
  bar, a larger board that fills the available room, and one frame around
  it. The status line reads "size · Pearls: n/m · Path: n" and wraps in
  landscape instead of being cut off.
- Title-bar menu in the same order as every other game, with the current
  values shown: "Size: …" (was "Grid: …") and "Show solution" / "Hide
  solution" (was a bare "Show" / "Hide").
- New README screenshot.

### Fixed
- Using Hint wiped the saved game: the board was saved as nothing. And when
  a hint fills the last cell, the status now shows the win message.
- The board's closing grid line was drawn just past its right and bottom
  edges.

## [1.2.2] - 2026-10-07

### Fixed
- The Tools menu entry is translated again. `main.lua` took `_` from
  KOReader's `gettext`, which knows nothing of this plugin's strings, so the
  menu label stayed English while the game's own screen, which goes through
  `i18n`, was translated. `_` now comes from `i18n` here too.


## [1.2.1] - 2026-10-01

### Fixed
- Picks up game-common v1.5.0. Play statistics were recorded under a key no
  tool could match: `ReaderUI`/`FileManager:registerModule()` rewrite a plugin
  instance's `name` to `reader<id>` / `filemanager<id>` right after it is
  built, so this game's sessions were split across two rows and neither
  carried its plugin id. Rows written under the old keys are merged back on
  first read. The same release brings the `stopPlugin()` /
  `deletePluginSettings()` hooks KOReader 2026.07 calls when a plugin is
  deleted from the device (PR #15240).

  No change to this plugin's own code -- it inherits all of it from the
  shared library.

## [1.2.0] - 2026-09-30

### Added
- **Hint** button, working in the loop rather than in cells. Two taps: the first names a cell the loop passes through, the second marks it.

## [1.1.10] - 2026-07-31

### Fixed
- `board_widget.lua` referenced Blitbuffer color constants that don't
  exist (COLOR_GRAY_C / COLOR_GRAY_8), which evaluated to `nil` and crashed the
  color-comparison in `paintTo()` as soon as the corresponding
  highlight was drawn. Now uses the correct constant name(s)
  (COLOR_DARK_GRAY / COLOR_LIGHT_GRAY).

## [1.1.7] - 2026-07-28

### Fixed
- The win-check never required the marked cells to form a *single*
  connected loop — only that they satisfy the pearl/degree rules as a
  union of cycles. This meant almost any generated puzzle admitted a
  completely unrelated valid marking elsewhere on the grid, even when
  every possible clue was revealed. Added single-loop-connectivity to the
  win-check and reworked generation to verify each puzzle's uniqueness
  before accepting it. 6×6 puzzles are now guaranteed to have a unique
  solution; 8×8 is a documented partial improvement (see README).
