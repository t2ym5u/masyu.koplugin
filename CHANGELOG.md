# Changelog

All notable changes to this project will be documented in this file.

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
